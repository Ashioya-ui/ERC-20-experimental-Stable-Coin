// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SelfApproaching} from "./libraries/SelfApproaching.sol";

/// @title  Leash
/// @notice One owner's money across two ERC-4626 vaults and idle. The planner declares an end
///         allocation; the agent may move the allocation only along a self-approaching path to
///         it. Every move is checked here:
///         1. the new point is ahead of every earlier segment with margin η:
///            (v − v_i)·(v_i − v_{i−1}) ≥ η·|v − v_i|·|v_i − v_{i−1}| (Lemma 8.1 with a margin,
///            docs/design/admissible-paths.md);
///         2. the declared end still passes test 1 after the move, so the agent can always finish
///            in one move and never takes the allocation further from the end;
///         3. a plan has at most 32 points.
///         Under one plan the path's length is at most 3.1297 times its largest distance from the
///         start (Theorem 4.2 with Lemma 2.1) and, closed with the end, at most 5.3332 times the
///         distance from the start to the end (Icking, Klein, Langetepe 1999). The agent cannot
///         withdraw: money moves only between the owner's two vaults and idle.
///
///         The leash is itself an ERC-4626 vault with one shareholder, `owner`, so anything that
///         holds an ERC-4626 vault (sUSD's AutonomousTreasury included) holds a leashed
///         allocation unchanged. The owner's deposits and withdrawals go pro rata, so they leave
///         the allocation where the agent put it.
/// @dev    Allocation = (value in vault A, value in vault B) in basis points of totalAssets;
///         idle is the rest. Shares do not transfer.
contract Leash is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_POINTS = 32;

    IERC4626 public immutable vaultA;
    IERC4626 public immutable vaultB;
    /// @notice The only shareholder: deposits and withdraws.
    address public immutable owner;
    /// @notice Declares the end, names or removes the agent, and can stop everything.
    address public immutable planner;

    address public agent;
    uint16 public endA;
    uint16 public endB;
    uint32 public etaNum;
    uint32 public etaDen;
    /// @notice Assets the agent's moves sent into or out of the vaults under the current plan.
    uint256 public moved;

    uint16[] private _xs;
    uint16[] private _ys;

    event Declared(
        uint16 endA, uint16 endB, address indexed agent, uint32 etaNum, uint32 etaDen, uint16 fromA, uint16 fromB
    );
    event AgentSet(address indexed agent);
    event Moved(uint16 a, uint16 b, uint256 assets, uint256 points);
    event Stopped(uint256 recovered);

    error ZeroAddress();
    error WrongVault();
    error NotOwner();
    error NotPlanner();
    error NotAgent();
    error NonTransferable();
    error BadAllocation();
    error BadMargin();
    error PathFull();
    error SamePoint();
    error NotApproaching();
    error EndUnreachable();

    constructor(
        IERC20 asset_,
        IERC4626 vaultA_,
        IERC4626 vaultB_,
        address owner_,
        address planner_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        if (owner_ == address(0) || planner_ == address(0)) revert ZeroAddress();
        if (
            address(vaultA_) == address(vaultB_) || vaultA_.asset() != address(asset_)
                || vaultB_.asset() != address(asset_)
        ) revert WrongVault();
        vaultA = vaultA_;
        vaultB = vaultB_;
        owner = owner_;
        planner = planner_;
        etaDen = 1;
        _xs.push(0);
        _ys.push(0);
    }

    // ------------------------------------------------------------------------------ planner

    /// @notice Start a new plan from the current allocation toward (a, b), moved by `agent_`,
    ///         with margin η = etaNum_ / etaDen_.
    function declare(uint16 a, uint16 b, address agent_, uint32 etaNum_, uint32 etaDen_) external {
        if (msg.sender != planner) revert NotPlanner();
        if (uint256(a) + b > BPS) revert BadAllocation();
        if (etaDen_ == 0 || etaNum_ > etaDen_) revert BadMargin();
        (uint16 x, uint16 y) = allocation();
        _restart(x, y);
        endA = a;
        endB = b;
        etaNum = etaNum_;
        etaDen = etaDen_;
        agent = agent_;
        emit Declared(a, b, agent_, etaNum_, etaDen_, x, y);
    }

    /// @notice Replace or remove the agent; the plan stays.
    function setAgent(address agent_) external {
        if (msg.sender != planner) revert NotPlanner();
        agent = agent_;
        emit AgentSet(agent_);
    }

    /// @notice Redeem what both vaults pay now, remove the agent, and end the plan where the
    ///         money is.
    function stop() external nonReentrant returns (uint256 recovered) {
        if (msg.sender != planner) revert NotPlanner();
        agent = address(0);
        recovered = _redeemAll(vaultA) + _redeemAll(vaultB);
        (uint16 x, uint16 y) = allocation();
        _restart(x, y);
        endA = x;
        endB = y;
        emit Stopped(recovered);
    }

    // -------------------------------------------------------------------------------- agent

    /// @notice Move the allocation to (a, b): basis points of value in vault A and in vault B.
    function move(uint16 a, uint16 b) external nonReentrant returns (uint256 assets) {
        address agent_ = agent;
        if (agent_ == address(0) || msg.sender != agent_) revert NotAgent();
        check(a, b);
        _xs.push(a);
        _ys.push(b);
        uint256 total = totalAssets();
        uint256 ta = Math.mulDiv(total, a, BPS);
        uint256 tb = Math.mulDiv(total, b, BPS);
        uint256 va = _value(vaultA);
        uint256 vb = _value(vaultB);
        if (va > ta) assets += _out(vaultA, va - ta);
        if (vb > tb) assets += _out(vaultB, vb - tb);
        if (ta > va) assets += _in(vaultA, ta - va);
        if (tb > vb) assets += _in(vaultB, tb - vb);
        moved += assets;
        emit Moved(a, b, assets, _xs.length);
    }

    /// @notice Reverts with the reason a move to (a, b) would be refused; returns if allowed.
    function check(uint16 a, uint16 b) public view {
        if (uint256(a) + b > BPS) revert BadAllocation();
        uint256 n = _xs.length;
        if (n >= MAX_POINTS) revert PathFull();
        if (a == _xs[n - 1] && b == _ys[n - 1]) revert SamePoint();
        int256 x = int256(uint256(a));
        int256 y = int256(uint256(b));
        (int256[] memory xs, int256[] memory ys) = _points(n, 0, 0, false);
        if (!SelfApproaching.canAppendWithMargin(xs, ys, x, y, etaNum, etaDen)) revert NotApproaching();
        (xs, ys) = _points(n, x, y, true);
        if (!SelfApproaching.canAppendWithMargin(xs, ys, int256(uint256(endA)), int256(uint256(endB)), etaNum, etaDen)) {
            revert EndUnreachable();
        }
    }

    // -------------------------------------------------------------------------------- views

    /// @notice The current allocation, in basis points of totalAssets.
    function allocation() public view returns (uint16 a, uint16 b) {
        uint256 total = totalAssets();
        if (total == 0) return (0, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        a = uint16(Math.mulDiv(_value(vaultA), BPS, total));
        // forge-lint: disable-next-line(unsafe-typecast)
        b = uint16(Math.mulDiv(_value(vaultB), BPS, total));
    }

    /// @notice The plan's points so far; the first is where it started.
    function path() external view returns (uint16[] memory a, uint16[] memory b) {
        return (_xs, _ys);
    }

    /// @notice The plan's length (rounded up), its largest distance from the start (rounded
    ///         down), in basis points, and whether length ≤ 3.1297 × distance (Theorem 4.2).
    function bound() external view returns (uint256 lengthUp, uint256 diameterDown, bool ok) {
        (int256[] memory xs, int256[] memory ys) = _points(_xs.length, 0, 0, false);
        return SelfApproaching.lengthBound(xs, ys);
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _value(vaultA) + _value(vaultB);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        return receiver == owner ? type(uint256).max : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return receiver == owner ? type(uint256).max : 0;
    }

    function maxWithdraw(address holder) public view override returns (uint256) {
        return Math.min(_convertToAssets(balanceOf(holder), Math.Rounding.Floor), _liquid());
    }

    function maxRedeem(address holder) public view override returns (uint256) {
        return Math.min(balanceOf(holder), _convertToShares(_liquid(), Math.Rounding.Floor));
    }

    // ---------------------------------------------------------------------------- internals

    /// @dev Deposits go into the vaults at the plan's current point; anything a vault will not
    ///      take stays idle.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        if (caller != owner || receiver != owner) revert NotOwner();
        super._deposit(caller, receiver, assets, shares);
        uint256 last = _xs.length - 1;
        _inUpTo(vaultA, Math.mulDiv(assets, _xs[last], BPS));
        _inUpTo(vaultB, Math.mulDiv(assets, _ys[last], BPS));
    }

    /// @dev Withdrawals come from idle and both vaults in proportion to what each holds; a
    ///      shortfall (a vault short of liquidity, rounding) comes from whatever can pay.
    function _withdraw(address caller, address receiver, address holder, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        uint256 total = totalAssets();
        if (assets > 0 && total > 0) {
            _outUpTo(vaultA, Math.mulDiv(assets, _value(vaultA), total));
            _outUpTo(vaultB, Math.mulDiv(assets, _value(vaultB), total));
            uint256 idle = IERC20(asset()).balanceOf(address(this));
            if (idle < assets) idle += _outUpTo(vaultA, assets - idle);
            if (idle < assets) _outUpTo(vaultB, assets - idle);
        }
        super._withdraw(caller, receiver, holder, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }

    function _restart(uint16 x, uint16 y) private {
        delete _xs;
        delete _ys;
        _xs.push(x);
        _ys.push(y);
        moved = 0;
    }

    function _points(uint256 n, int256 x, int256 y, bool extend)
        private
        view
        returns (int256[] memory xs, int256[] memory ys)
    {
        uint256 len = extend ? n + 1 : n;
        xs = new int256[](len);
        ys = new int256[](len);
        for (uint256 i; i < n; ++i) {
            xs[i] = int256(uint256(_xs[i]));
            ys[i] = int256(uint256(_ys[i]));
        }
        if (extend) {
            xs[n] = x;
            ys[n] = y;
        }
    }

    function _value(IERC4626 v) private view returns (uint256) {
        return v.previewRedeem(v.balanceOf(address(this)));
    }

    function _liquid() private view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + vaultA.maxWithdraw(address(this))
            + vaultB.maxWithdraw(address(this));
    }

    function _out(IERC4626 v, uint256 amount) private returns (uint256) {
        // slither-disable-next-line unused-return
        v.withdraw(amount, address(this), address(this));
        return amount;
    }

    function _in(IERC4626 v, uint256 amount) private returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (amount > idle) amount = idle;
        if (amount == 0) return 0;
        IERC20(asset()).forceApprove(address(v), amount);
        // slither-disable-next-line unused-return
        v.deposit(amount, address(this));
        return amount;
    }

    function _outUpTo(IERC4626 v, uint256 amount) private returns (uint256) {
        uint256 available = v.maxWithdraw(address(this));
        if (amount > available) amount = available;
        if (amount == 0) return 0;
        return _out(v, amount);
    }

    function _inUpTo(IERC4626 v, uint256 amount) private returns (uint256) {
        uint256 room = v.maxDeposit(address(this));
        if (amount > room) amount = room;
        return _in(v, amount);
    }

    function _redeemAll(IERC4626 v) private returns (uint256) {
        uint256 shares = Math.min(v.balanceOf(address(this)), v.maxRedeem(address(this)));
        return shares == 0 ? 0 : v.redeem(shares, address(this), address(this));
    }
}

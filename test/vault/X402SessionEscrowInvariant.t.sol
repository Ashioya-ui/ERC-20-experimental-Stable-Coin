// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {X402SessionEscrow} from "../../src/vault/X402SessionEscrow.sol";
import {EIP3009Mock} from "./mocks/EIP3009Mock.sol";

/// @dev Opens, funds, redeems, closes and lets sessions expire, at random.
contract SessionHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant AGENT_PK = 0xA6E7;

    X402SessionEscrow public immutable escrow;
    EIP3009Mock public immutable usdc;
    address public immutable funder;
    address public immutable agent;
    address[2] public merchants;
    bytes32[] public ids;
    mapping(bytes32 => uint256) public owed; // highest voucher signed so far, per session
    uint256 internal salt;

    constructor(X402SessionEscrow escrow_, EIP3009Mock usdc_, address funder_) {
        escrow = escrow_;
        usdc = usdc_;
        funder = funder_;
        agent = vm.addr(AGENT_PK);
        merchants = [makeAddr("merchant-0"), makeAddr("merchant-1")];
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function open(uint256 amount, uint256 who, uint256 duration) external {
        amount = bound(amount, 1, 10e6);
        if (usdc.balanceOf(funder) < amount) return;
        vm.prank(funder);
        ids.push(escrow.open(merchants[who % 2], address(usdc), agent,
            uint64(block.timestamp + bound(duration, 1 hours, 30 days)), bytes32(++salt), amount));
    }

    function topUp(uint256 pick, uint256 amount) external {
        if (ids.length == 0) return;
        bytes32 id = ids[pick % ids.length];
        X402SessionEscrow.Session memory s = escrow.session(id);
        amount = bound(amount, 1, 5e6);
        if (s.closed || block.timestamp > s.expiry || usdc.balanceOf(funder) < amount) return;
        vm.prank(funder);
        escrow.topUp(id, amount);
    }

    function pay(uint256 pick, uint256 calls) external {
        if (ids.length == 0) return;
        bytes32 id = ids[pick % ids.length];
        X402SessionEscrow.Session memory s = escrow.session(id);
        if (s.closed || block.timestamp > s.expiry) return;
        uint256 next = owed[id] + bound(calls, 1, 1_000) * 100;
        if (next > s.deposited) next = s.deposited;
        owed[id] = next;
    }

    function redeem(uint256 pick) external {
        if (ids.length == 0) return;
        bytes32 id = ids[pick % ids.length];
        X402SessionEscrow.Session memory s = escrow.session(id);
        uint256 c = owed[id];
        if (s.closed || block.timestamp > s.expiry || c <= s.claimed) return;
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(AGENT_PK, escrow.voucherDigest(id, c));
        escrow.redeem(id, c, abi.encodePacked(r, sig, v));
    }

    function closeEarly(uint256 pick) external {
        if (ids.length == 0) return;
        bytes32 id = ids[pick % ids.length];
        X402SessionEscrow.Session memory s = escrow.session(id);
        if (s.closed) return;
        vm.prank(s.payee);
        escrow.closeByPayee(id, 0, "");
    }

    function reclaim(uint256 pick) external {
        if (ids.length == 0) return;
        bytes32 id = ids[pick % ids.length];
        X402SessionEscrow.Session memory s = escrow.session(id);
        if (s.closed || block.timestamp <= s.expiry) return;
        escrow.reclaim(id);
    }

    function elapse(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 7 days));
    }
}

contract X402SessionEscrowInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000e6;
    X402SessionEscrow internal escrow;
    EIP3009Mock internal usdc;
    SessionHandler internal handler;
    address internal funder = makeAddr("funder");

    function setUp() public {
        vm.warp(1_800_000_000);
        escrow = new X402SessionEscrow();
        usdc = new EIP3009Mock();
        handler = new SessionHandler(escrow, usdc, funder);
        usdc.mint(funder, SUPPLY);
        vm.prank(funder);
        usdc.approve(address(escrow), type(uint256).max);

        bytes4[] memory actions = new bytes4[](7);
        actions[0] = SessionHandler.open.selector;
        actions[1] = SessionHandler.topUp.selector;
        actions[2] = SessionHandler.pay.selector;
        actions[3] = SessionHandler.redeem.selector;
        actions[4] = SessionHandler.closeEarly.selector;
        actions[5] = SessionHandler.reclaim.selector;
        actions[6] = SessionHandler.elapse.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    /// The escrow holds exactly the unclaimed deposits of its open sessions: never less (it could
    /// not pay), never more (something would be stuck).
    function invariant_escrowHoldsExactlyWhatOpenSessionsOwe() public view {
        uint256 owedOut;
        for (uint256 i; i < handler.idCount(); ++i) {
            X402SessionEscrow.Session memory s = escrow.session(handler.ids(i));
            assertLe(s.claimed, s.deposited, "claimed above deposit");
            if (!s.closed) owedOut += s.deposited - s.claimed;
        }
        assertEq(usdc.balanceOf(address(escrow)), owedOut);
    }

    /// Value is conserved: every unit is with the funder, in escrow, or with a merchant.
    function invariant_nothingIsCreatedOrLost() public view {
        uint256 total = usdc.balanceOf(funder) + usdc.balanceOf(address(escrow))
            + usdc.balanceOf(handler.merchants(0)) + usdc.balanceOf(handler.merchants(1));
        assertEq(total, SUPPLY);
    }
}

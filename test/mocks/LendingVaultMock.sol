// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice ERC-4626 stand-in for a lending vault (Aave static aToken, MetaMorpho) over any
///         ERC-20, including Circle's FiatToken. Yield = transfer the asset in. Knobs mirror
///         mainnet failure modes: realised losses, withdrawal liquidity (`maxWithdraw`),
///         supply caps (`maxDeposit`), pauses, and deposits that revert despite reported room.
///         Local rehearsals and tests only: every knob is permissionless.
contract LendingVaultMock is ERC4626 {
    using SafeERC20 for IERC20;

    address public constant LOSS_SINK = 0x000000000000000000000000000000000000dEaD;

    uint256 public liquidityCap = type(uint256).max;
    uint256 public depositCap = type(uint256).max;
    bool public paused;
    bool public failDeposits;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}

    /// @notice Bad debt or an exploit: part of the vault's assets disappear.
    function simulateLoss(uint256 assets) external {
        IERC20(asset()).safeTransfer(LOSS_SINK, assets);
    }

    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    function setDepositCap(uint256 cap) external {
        depositCap = cap;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setFailDeposits(bool f) external {
        failDeposits = f;
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused) return 0;
        uint256 m = super.maxDeposit(receiver);
        return m < depositCap ? m : depositCap;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (paused) return 0;
        return super.maxMint(receiver);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused) return 0;
        uint256 m = super.maxWithdraw(owner);
        return m < liquidityCap ? m : liquidityCap;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused) return 0;
        uint256 m = super.maxRedeem(owner);
        uint256 capShares = liquidityCap == type(uint256).max ? type(uint256).max : convertToShares(liquidityCap);
        return m < capShares ? m : capShares;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(!failDeposits, "LendingVaultMock: deposit failed");
        return super.deposit(assets, receiver);
    }
}

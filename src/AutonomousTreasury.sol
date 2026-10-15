// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  AutonomousTreasury
/// @notice Holds the sUSD reserve inside an external ERC-4626 vault (for example sDAI, or a
///         USDC lending vault) and reports its value.
///
/// @dev    This contract is an *adapter* around an ERC-4626 vault. It does not issue shares
///         of its own: sUSD holders are paid by redemption through the stabilizer.
///
///         Valuation is conservative: `reserveAssets()` is what the treasury would receive
///         if it redeemed every vault share now (`previewRedeem`, which includes withdrawal
///         fees), plus idle assets held directly. Pick vaults whose share price cannot be
///         moved by donations (virtual shares or offset) and that have deep withdrawal
///         liquidity. An external loss in the vault lowers `reserveAssets()`; the stabilizer
///         then absorbs it with a negative rebase.
///
///         Only the stabilizer can move funds out. Anyone can call `sweep()` to deposit idle
///         assets (donations, rounding dust) into the vault, where they count as surplus.
contract AutonomousTreasury is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice External ERC-4626 vault holding the reserve.
    IERC4626 public immutable vault;
    /// @notice Underlying collateral asset of the vault (e.g. USDC or DAI).
    IERC20 public immutable asset;
    /// @notice Account allowed to call `setStabilizer` exactly once.
    address public immutable deployer;
    /// @notice The only account allowed to deposit or withdraw reserve.
    address public stabilizer;

    event StabilizerSet(address indexed stabilizer);
    event ReserveDeposited(uint256 assets, uint256 shares);
    event ReserveWithdrawn(address indexed to, uint256 assets);

    error NotStabilizer();
    error NotDeployer();
    error StabilizerAlreadySet();
    error ZeroAddress();

    modifier onlyStabilizer() {
        if (msg.sender != stabilizer) revert NotStabilizer();
        _;
    }

    constructor(IERC4626 vault_) {
        if (address(vault_) == address(0)) revert ZeroAddress();
        vault = vault_;
        asset = IERC20(vault_.asset());
        deployer = msg.sender;
    }

    /// @notice Wire the stabilizer. Callable once by the deployer.
    function setStabilizer(address stabilizer_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (stabilizer_ == address(0)) revert ZeroAddress();
        if (stabilizer != address(0)) revert StabilizerAlreadySet();
        stabilizer = stabilizer_;
        emit StabilizerSet(stabilizer_);
    }

    /// @notice Deposit every idle asset into the vault. Permissionless.
    /// @return shares Vault shares received.
    function sweep() public nonReentrant returns (uint256 shares) {
        shares = _depositIdle();
    }

    /// @notice Deposit every idle asset into the vault (called by the stabilizer after it
    ///         transfers a minter's collateral here).
    function depositReserve() external onlyStabilizer nonReentrant returns (uint256 shares) {
        shares = _depositIdle();
    }

    /// @notice Send `assets` of collateral to `to`, using idle balance first, then the vault.
    function withdrawReserve(uint256 assets, address to) external onlyStabilizer nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 idle = asset.balanceOf(address(this));
        if (idle >= assets) {
            asset.safeTransfer(to, assets);
        } else {
            if (idle > 0) asset.safeTransfer(to, idle);
            vault.withdraw(assets - idle, to, address(this));
        }
        emit ReserveWithdrawn(to, assets);
    }

    /// @notice Conservative value of the reserve in asset units.
    function reserveAssets() public view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(address(this))) + asset.balanceOf(address(this));
    }

    /// @notice Assets that can be paid out right now (vault withdrawal limit plus idle).
    function liquidAssets() external view returns (uint256) {
        return vault.maxWithdraw(address(this)) + asset.balanceOf(address(this));
    }

    function _depositIdle() private returns (uint256 shares) {
        uint256 idle = asset.balanceOf(address(this));
        if (idle == 0) return 0;
        asset.forceApprove(address(vault), idle);
        shares = vault.deposit(idle, address(this));
        emit ReserveDeposited(idle, shares);
    }
}

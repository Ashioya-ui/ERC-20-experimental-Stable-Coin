// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  AutonomousTreasury
/// @notice Holds the sUSD reserve: an idle liquidity buffer of the reserve asset (USDC) in
///         front of one external ERC-4626 vault (e.g. Aave v3 waBasUSDC), and reports its value.
///
/// @dev    Adapter, not a vault. The treasury issues no shares; sUSD holders are paid by
///         redemption through the stabilizer.
///
///         Liquidity buffer. `liquidityBufferBps` of the reserve stays idle (0 yield), so
///         redemptions are paid instantly even when the vault's withdrawable liquidity is
///         exhausted (lending vaults cap `maxWithdraw` by unborrowed cash). Only the excess
///         above the target is deposited, and never more than `maxDeposit` allows; a vault
///         that refuses a deposit (paused, capped) leaves the funds idle instead of reverting.
///         Withdrawals use idle funds first and check `maxWithdraw`, failing with
///         `InsufficientLiquidity(available)` rather than an opaque vault error.
///
///         Valuation is conservative: `previewRedeem` of the vault shares plus idle funds.
///         Prefer vaults whose share price cannot be inflated by donations and whose price
///         realises losses (Aave static aTokens, MetaMorpho v1.0). Avoid vaults whose `max*`
///         functions return 0 (Morpho Vault v2) and vaults that hide bad debt (MetaMorpho
///         v1.1 `lostAssets`).
///
///         Emergencies and migration (driven by the stabilizer's roles):
///         - `exitVault` sets the buffer to 100% and redeems everything the vault will pay now;
///           it can be repeated as liquidity returns;
///         - `migrateVault` moves to a new vault (behind the stabilizer's 7-day timelock). Shares
///           the old vault cannot pay out are quarantined as `legacyVault`: they no longer
///           count as reserve (the loss is absorbed pro rata), and anyone can call
///           `recoverLegacy` later; recovered funds return as surplus. Nobody can take custody
///           of them.
contract AutonomousTreasury is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BPS = 10_000;
    /// @notice `rebalance` acts only when idle funds are this far (bps of reserve) off target.
    uint256 public constant REBALANCE_TOLERANCE_BPS = 100;
    /// @notice Old-vault shares worth at most this many asset units (0.001 USDC) are dust: a
    ///         migration leaves them behind instead of quarantining them, and they do not keep
    ///         `legacyVault` set (Phase 4, A12). Vault rounding leaves such dust: MetaMorpho's
    ///         `maxRedeem` can be a few hundred million shares (1e-12 USDC each) short of a
    ///         balance, and every recovery would otherwise end one step from empty.
    uint256 public constant LEGACY_DUST_ASSETS = 1_000;

    /// @notice Reserve asset (USDC). Every vault must use it.
    IERC20 public immutable asset;
    /// @notice The only account allowed to move funds out or change settings, fixed at
    ///         construction (Phase 4, A3).
    address public immutable stabilizer;

    /// @notice Current yield venue.
    IERC4626 public vault;
    /// @notice Target share of the reserve kept idle, in bps (10_000 = everything idle).
    uint256 public liquidityBufferBps;
    /// @notice Previous vault still holding shares that could not be redeemed at migration.
    IERC4626 public legacyVault;

    event StabilizerSet(address indexed stabilizer);
    event ReserveDeposited(address indexed vault, uint256 assets, uint256 shares);
    event DepositSkipped(address indexed vault, uint256 assets);
    event ReserveWithdrawn(address indexed to, uint256 assets);
    event Rebalanced(uint256 idleBefore, uint256 idleAfter);
    event LiquidityBufferSet(uint256 bps);
    event VaultExited(address indexed vault, uint256 assetsRecovered, uint256 sharesLeft);
    event VaultMigrated(address indexed oldVault, address indexed newVault, uint256 sharesQuarantined);
    event LegacyRecovered(address indexed legacyVault, uint256 assetsRecovered, uint256 sharesLeft);

    error NotStabilizer();
    error ZeroAddress();
    error InvalidBuffer();
    error AssetMismatch();
    error SameVault();
    error LegacyNotEmpty();
    error NewVaultIsLegacy();
    error InsufficientLiquidity(uint256 available);

    modifier onlyStabilizer() {
        if (msg.sender != stabilizer) revert NotStabilizer();
        _;
    }

    /// @param vault_              ERC-4626 vault over the reserve asset.
    /// @param liquidityBufferBps_ Share of the reserve kept idle (e.g. 1_500 = 15%).
    /// @param stabilizer_         The SpectralStabilizer, deployed after this contract at an
    ///                            address predicted from the deployer's nonce; its constructor
    ///                            checks that this treasury names it.
    constructor(IERC4626 vault_, uint256 liquidityBufferBps_, address stabilizer_) {
        if (address(vault_) == address(0) || stabilizer_ == address(0)) revert ZeroAddress();
        if (liquidityBufferBps_ > MAX_BPS) revert InvalidBuffer();
        vault = vault_;
        asset = IERC20(vault_.asset());
        stabilizer = stabilizer_;
        liquidityBufferBps = liquidityBufferBps_;
        emit StabilizerSet(stabilizer_);
    }

    // ---------------------------------------------------------------------- permissionless

    // Reentrancy: nonReentrant, and the legacy vault was an allowlisted vault (audit/slither.md).
    // slither-disable-start reentrancy-no-eth
    /// @notice Redeem quarantined shares of the previous vault as its liquidity returns.
    ///         Only ever adds idle funds, so anyone may call it.
    function recoverLegacy() external nonReentrant returns (uint256 recovered) {
        IERC4626 legacy = legacyVault;
        if (address(legacy) == address(0)) return 0;
        uint256 shares = Math.min(legacy.balanceOf(address(this)), legacy.maxRedeem(address(this)));
        if (shares > 0) recovered = legacy.redeem(shares, address(this), address(this));
        uint256 left = legacy.balanceOf(address(this));
        // Shares donated later only delay clearing until the next call, which redeems them.
        // slither-disable-next-line incorrect-equality
        if (left == 0 || legacy.previewRedeem(left) <= LEGACY_DUST_ASSETS) legacyVault = IERC4626(address(0));
        emit LegacyRecovered(address(legacy), recovered, left);
    }
    // slither-disable-end reentrancy-no-eth

    // ---------------------------------------------------------------------- stabilizer only
    //
    // Every call that moves funds into or out of the vault can lose a wei or two to vault
    // rounding, so they all go through the stabilizer, which re-syncs the index afterwards.

    /// @notice Deposit idle funds above the buffer target (donations, fees) into the vault.
    /// @return shares       Vault shares received.
    /// @return reserveAfter Reserve value afterwards, in asset units. Returned so the caller
    ///                      does not have to value the reserve again (Phase 4, B1).
    function sweep() external onlyStabilizer nonReentrant returns (uint256 shares, uint256 reserveAfter) {
        (shares, reserveAfter) = _depositExcess();
    }

    /// @notice Move funds between idle and the vault toward the buffer target.
    /// @return reserveAfter Reserve value afterwards, in asset units.
    function rebalance() external onlyStabilizer nonReentrant returns (uint256 reserveAfter) {
        uint256 reserve = reserveAssets();
        uint256 idle = asset.balanceOf(address(this));
        uint256 target = Math.mulDiv(reserve, liquidityBufferBps, MAX_BPS);
        uint256 tol = Math.mulDiv(reserve, REBALANCE_TOLERANCE_BPS, MAX_BPS);
        reserveAfter = reserve;
        if (idle > target + tol) {
            (, reserveAfter) = _depositExcess();
        } else if (idle + tol < target) {
            uint256 amount = Math.min(target - idle, vault.maxWithdraw(address(this)));
            if (amount > 0) {
                // The shares burned are not needed: the reserve is valued again below.
                // slither-disable-next-line unused-return
                vault.withdraw(amount, address(this), address(this));
                reserveAfter = reserveAssets();
            }
        }
        emit Rebalanced(idle, asset.balanceOf(address(this)));
    }

    /// @notice Deposit idle funds above the buffer target (called after a mint).
    /// @return shares       Vault shares received.
    /// @return reserveAfter Reserve value afterwards, in asset units.
    function depositReserve() external onlyStabilizer nonReentrant returns (uint256 shares, uint256 reserveAfter) {
        (shares, reserveAfter) = _depositExcess();
    }

    /// @notice Send `assets` to `to`: idle funds first, then the vault within `maxWithdraw`.
    /// @return reserveAfter Reserve value afterwards, in asset units.
    function withdrawReserve(uint256 assets, address to)
        external
        onlyStabilizer
        nonReentrant
        returns (uint256 reserveAfter)
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 idle = asset.balanceOf(address(this));
        if (idle >= assets) {
            asset.safeTransfer(to, assets);
        } else {
            uint256 need = assets - idle;
            uint256 available = vault.maxWithdraw(address(this));
            if (available < need) revert InsufficientLiquidity(idle + available);
            if (idle > 0) asset.safeTransfer(to, idle);
            // The shares burned are not needed: the reserve is valued again below.
            // slither-disable-next-line unused-return
            vault.withdraw(need, to, address(this));
        }
        emit ReserveWithdrawn(to, assets);
        reserveAfter = reserveAssets();
    }

    /// @notice Set the idle buffer target (bps of reserve).
    function setLiquidityBuffer(uint256 bps) external onlyStabilizer {
        if (bps > MAX_BPS) revert InvalidBuffer();
        liquidityBufferBps = bps;
        emit LiquidityBufferSet(bps);
    }

    /// @notice Emergency: keep everything idle from now on and pull out what the vault pays.
    function exitVault() external onlyStabilizer nonReentrant returns (uint256 recovered) {
        // (the caller re-values the reserve itself: an exit is rare and not a hot path)
        liquidityBufferBps = MAX_BPS;
        emit LiquidityBufferSet(MAX_BPS);
        uint256 shares = Math.min(vault.balanceOf(address(this)), vault.maxRedeem(address(this)));
        if (shares > 0) recovered = vault.redeem(shares, address(this), address(this));
        emit VaultExited(address(vault), recovered, vault.balanceOf(address(this)));
    }

    // Reentrancy: nonReentrant, stabilizer-only, and both vaults are on the stabilizer's
    // immutable allowlist (audit/slither.md).
    // slither-disable-start reentrancy-no-eth
    /// @notice Switch to `newVault`. Shares the old vault cannot redeem now are quarantined.
    function migrateVault(IERC4626 newVault) external onlyStabilizer nonReentrant {
        if (address(newVault) == address(0)) revert ZeroAddress();
        if (newVault.asset() != address(asset)) revert AssetMismatch();
        IERC4626 old = vault;
        if (address(newVault) == address(old)) revert SameVault();
        if (address(newVault) == address(legacyVault)) revert NewVaultIsLegacy();

        uint256 shares = old.balanceOf(address(this));
        uint256 redeemable = Math.min(shares, old.maxRedeem(address(this)));
        // The assets received are not needed: what is left is measured below.
        // slither-disable-next-line unused-return
        if (redeemable > 0) old.redeem(redeemable, address(this), address(this));
        uint256 left = old.balanceOf(address(this));
        // Dust that vault rounding leaves behind is abandoned, not quarantined: it is worth at
        // most LEGACY_DUST_ASSETS and the stabilizer re-syncs right after.
        if (left > 0 && old.previewRedeem(left) > LEGACY_DUST_ASSETS) {
            if (address(legacyVault) != address(0)) revert LegacyNotEmpty();
            legacyVault = old;
        }
        asset.forceApprove(address(old), 0);
        vault = newVault;
        emit VaultMigrated(address(old), address(newVault), left);
        _depositExcess();
    }
    // slither-disable-end reentrancy-no-eth

    // ---------------------------------------------------------------------- views

    /// @notice Conservative reserve value in asset units: vault position + idle funds.
    ///         Quarantined legacy shares are excluded.
    function reserveAssets() public view returns (uint256) {
        uint256 shares = vault.balanceOf(address(this));
        // A guard against valuing zero shares, not a balance check anyone can game.
        // slither-disable-next-line incorrect-equality
        uint256 invested = shares == 0 ? 0 : vault.previewRedeem(shares);
        return invested + asset.balanceOf(address(this));
    }

    /// @notice Assets payable right now: idle funds + what the vault lets us withdraw.
    function liquidAssets() external view returns (uint256) {
        return asset.balanceOf(address(this)) + vault.maxWithdraw(address(this));
    }

    /// @notice Idle funds held directly.
    function idleAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Idle target implied by the buffer setting.
    function targetIdle() external view returns (uint256) {
        return Math.mulDiv(reserveAssets(), liquidityBufferBps, MAX_BPS);
    }

    // ---------------------------------------------------------------------- internals

    /// @dev Deposits idle funds above the buffer target and returns the reserve value
    ///      afterwards, so callers in the same transaction do not have to value it again.
    function _depositExcess() private returns (uint256 shares, uint256 reserveAfter) {
        uint256 idle = asset.balanceOf(address(this));
        reserveAfter = reserveAssets();
        uint256 target = Math.mulDiv(reserveAfter, liquidityBufferBps, MAX_BPS);
        if (idle <= target) return (0, reserveAfter);
        IERC4626 v = vault;
        uint256 amount = Math.min(idle - target, v.maxDeposit(address(this)));
        // A guard: nothing to deposit (vault full or paused).
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return (0, reserveAfter);
        asset.forceApprove(address(v), amount);
        try v.deposit(amount, address(this)) returns (uint256 s) {
            shares = s;
            emit ReserveDeposited(address(v), amount, s);
            // The vault's own rounding can shave a wei off the conservative valuation.
            reserveAfter = reserveAssets();
        } catch {
            asset.forceApprove(address(v), 0);
            emit DepositSkipped(address(v), amount);
        }
    }
}

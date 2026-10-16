// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SpectralToken} from "./SpectralToken.sol";
import {AutonomousTreasury} from "./AutonomousTreasury.sol";
import {ISpectralEntropyOracle} from "./interfaces/ISpectralEntropyOracle.sol";

/// @title  SpectralStabilizer
/// @notice Monetary controller of sUSD: 1:1 mint and redemption against the reserve, fees
///         and expansion limits driven by spectral entropy, and bounded rebases that only
///         ever distribute surplus or absorb realised losses.
///
/// @dev    Where the peg comes from. sUSD is redeemable 1:1 (minus a small fee) for the
///         reserve asset held in `AutonomousTreasury`. The entropy signal never creates or
///         destroys backing. It only prices access (fees), rate-limits growth (expansion
///         cap), and sets how much surplus is kept as a buffer before a rebase.
///
///         Entropy semantics (see SpectralMath). Low H = homogeneous flow (cheap minting,
///         larger expansion cap, smaller buffer). High H = flow dominated by a few large swaps
///         (higher fees, tighter cap, larger buffer, smaller rebase steps). H is a heuristic
///         and cheap to move (for example with many equal-sized small swaps), so its effect
///         is limited to the bounded policy ranges below and never reaches the backing.
///
///         Reserve floor. Every state-changing entry point re-checks
///         `reserveValue() >= totalSupply()` and reverts otherwise. Protocol actions can
///         therefore never push the reserve ratio below 1. An external loss inside the
///         ERC-4626 vault can. `sync()` (also run at the start of every action) then lowers
///         the index so that supply equals the reserve again: the loss is shared pro rata.
///
///         Churn budget. Within a `CHURN_WINDOW` (a 7-day window that restarts at the first
///         index move after it expires), let L be the total variation of the index path and
///         D its range (max - min). A *positive* rebase is applied only if afterwards
///         L <= C_DIAM * D; otherwise it is deferred. Monotone paths (pure yield
///         distribution) always satisfy L = D. The budget binds only when gains and losses
///         alternate: with equal swings, the third upward leg in a window is deferred. Loss
///         absorption is never deferred.
///         C_DIAM = 2 + pi/3 is the conjectured sharp length-over-diameter ratio of
///         self-approaching plane curves (proven: 3.0472 <= C_diam <= 3.1356). Here it is a
///         design constant chosen by analogy. No stability property follows from the
///         geometry.
///
///         Guarded launch. `supplyCap` bounds total minting (rebases may exceed it); the admin
///         raises it as confidence grows. The daily expansion cap still applies under it.
///
///         Roles. DEFAULT_ADMIN_ROLE (a Safe): supply cap, liquidity buffer, vault migration
///         behind a 7-day timelock (holders can redeem before it executes). GUARDIAN_ROLE (a
///         faster Safe or monitored key, plus the admin): pause/unpause minting and rebasing,
///         emergency exit from the vault into idle funds, cancelling a pending migration.
///         Nobody can pause redemption or loss absorption, or move reserve funds to an
///         address of their choosing.
contract SpectralStabilizer is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------- roles

    /// @notice May pause minting and rebasing (never redemption or loss absorption).
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ---------------------------------------------------------------------- constants

    uint256 internal constant WAD = 1e18;

    /// @notice 2 + pi/3 in WAD (3.047197551196597746...).
    uint256 public constant C_DIAM_WAD = 3_047_197_551_196_597_746;

    /// @notice Minting fee at h = 0 and at h = 1 (WAD rates): 1 bp to 50 bp, quadratic in h.
    uint256 public constant MINT_FEE_MIN = 0.0001e18;
    uint256 public constant MINT_FEE_MAX = 0.0050e18;
    /// @notice Redemption fee at h = 0 and at h = 1: 1 bp to 10 bp, quadratic in h.
    ///         Kept low on purpose: cheap exits are what make the peg credible.
    uint256 public constant REDEEM_FEE_MIN = 0.0001e18;
    uint256 public constant REDEEM_FEE_MAX = 0.0010e18;

    /// @notice Net minting allowed per epoch (sUSD minted minus sUSD redeemed in the epoch,
    ///         floored at zero), as a fraction of supply at the start of the epoch: 20% at
    ///         h = 0 down to 2% at h = 1. Counting net flow means a mint-and-redeem round trip
    ///         in one transaction cannot use up other users' capacity (Phase 4, A1).
    uint256 public constant EPOCH = 1 days;
    uint256 public constant EXPANSION_CAP_LOW_H = 0.20e18;
    uint256 public constant EXPANSION_CAP_HIGH_H = 0.02e18;

    /// @notice Micro-rebases: at most one per hour, each at most 1 bp of supply at h = 0
    ///         (0.5 bp at h = 1). The step stays below the 2 bp round-trip fee floor, so
    ///         minting just before a rebase and redeeming just after cannot profit.
    uint256 public constant REBASE_INTERVAL = 1 hours;
    uint256 public constant REBASE_STEP_MAX = 0.0001e18;

    /// @notice Surplus kept as a buffer before anything is distributed: 0.5% to 5% of supply.
    uint256 public constant BUFFER_LOW_H = 0.005e18;
    uint256 public constant BUFFER_HIGH_H = 0.05e18;

    /// @notice Length of the churn-budget window.
    uint256 public constant CHURN_WINDOW = 7 days;

    /// @notice Delay between proposing and executing a vault migration.
    uint256 public constant VAULT_TIMELOCK = 7 days;

    /// @notice Smallest mint (credited value) or redemption, in sUSD wei. Keeps rounding of
    ///         the reserve asset (for USDC, 1 wei = 1e12 sUSD wei) below the fee floor.
    uint256 public constant MIN_AMOUNT = 1e18;

    // ---------------------------------------------------------------------- immutables

    SpectralToken public immutable token;
    AutonomousTreasury public immutable treasury;
    ISpectralEntropyOracle public immutable oracle;
    IERC20 public immutable asset;
    /// @notice 10^(18 - asset decimals): converts asset units to sUSD wei.
    uint256 public immutable scale;
    /// @notice Absolute expansion allowed per epoch regardless of supply (bootstrap).
    uint256 public immutable bootstrapCap;

    // ---------------------------------------------------------------------- state

    uint64 public epochStart;
    uint256 public epochSupply;
    uint256 public mintedInEpoch;

    uint64 public lastRebaseAt;

    uint64 public churnWindowStart;
    uint256 public churnLength;
    uint256 public churnMax;
    uint256 public churnMin;

    /// @notice Maximum total supply reachable by minting (guarded launch).
    uint256 public supplyCap;

    /// @notice Vault proposed for migration and the earliest execution time.
    IERC4626 public pendingVault;
    uint64 public pendingVaultEta;

    // ---------------------------------------------------------------------- events / errors

    /// @param amountOut sUSD minted to `receiver`.
    event Minted(
        address indexed payer, address indexed receiver, uint256 assetsIn, uint256 amountOut, uint256 fee, uint256 h
    );
    /// @param amountIn sUSD burned from `owner`.
    event Redeemed(
        address indexed owner, address indexed receiver, uint256 amountIn, uint256 assetsOut, uint256 fee, uint256 h
    );
    event Distributed(uint256 oldIndex, uint256 newIndex, uint256 supplyAdded, uint256 h);
    event RebaseDeferred(uint256 oldIndex, uint256 proposedIndex, uint256 churnLength, uint256 churnRange);
    event LossAbsorbed(uint256 oldIndex, uint256 newIndex, uint256 reserveValue, uint256 supplyBefore);
    event SupplyCapSet(uint256 supplyCap);
    event VaultProposed(address indexed vault, uint256 eta);
    event VaultProposalCanceled(address indexed vault);
    event VaultMigrationExecuted(address indexed oldVault, address indexed newVault);
    event EmergencyVaultExit(address indexed vault, uint256 assetsRecovered);

    error ZeroAddress();
    error AmountTooSmall();
    error Slippage();
    error ExpansionCapExceeded(uint256 remaining);
    error RebaseTooSoon();
    error NothingToDistribute();
    error ReserveFloorBreached(uint256 reserveValue, uint256 supply);
    error UnsupportedAsset();
    error SupplyCapExceeded(uint256 remaining);
    error AssetMismatch();
    error NoPendingVault();
    error VaultTimelockActive(uint256 eta);
    error WiringMismatch();

    // ---------------------------------------------------------------------- constructor

    /// @param admin        DEFAULT_ADMIN_ROLE and GUARDIAN_ROLE holder (use a Safe).
    /// @param guardian     Extra GUARDIAN_ROLE holder (address(0) for none).
    /// @param bootstrapCap_ Expansion allowed per epoch regardless of supply.
    /// @param supplyCap_   Maximum total supply reachable by minting.
    constructor(
        SpectralToken token_,
        AutonomousTreasury treasury_,
        ISpectralEntropyOracle oracle_,
        address admin,
        address guardian,
        uint256 bootstrapCap_,
        uint256 supplyCap_
    ) {
        if (
            address(token_) == address(0) || address(treasury_) == address(0) || address(oracle_) == address(0)
                || admin == address(0)
        ) revert ZeroAddress();
        // The token and the treasury were deployed first, naming this contract's predicted
        // address. Refuse to exist if either names someone else (Phase 4, A3).
        if (token_.stabilizer() != address(this) || treasury_.stabilizer() != address(this)) {
            revert WiringMismatch();
        }
        token = token_;
        treasury = treasury_;
        oracle = oracle_;
        asset = treasury_.asset();
        uint8 dec = IERC20Metadata(address(asset)).decimals();
        if (dec > 18) revert UnsupportedAsset();
        scale = 10 ** (18 - dec);
        bootstrapCap = bootstrapCap_;
        supplyCap = supplyCap_;
        emit SupplyCapSet(supplyCap_);

        epochStart = uint64(block.timestamp);
        churnWindowStart = uint64(block.timestamp);
        churnMax = WAD;
        churnMin = WAD;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
        if (guardian != address(0)) _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ---------------------------------------------------------------------- user actions

    /// @notice Deposit `assets` of collateral and mint sUSD to `receiver`.
    /// @dev    The credited value is the *measured* increase of the conservative reserve
    ///         valuation, so vault entry fees and rounding are borne by the minter.
    /// @param  minOut Minimum sUSD to receive (slippage guard against fee changes).
    function mint(uint256 assets, address receiver, uint256 minOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 out)
    {
        if (receiver == address(0)) revert ZeroAddress();
        _syncLoss();
        uint256 h = oracle.smoothedEntropy();

        treasury.sweep(); // donations become surplus before measuring
        uint256 before = treasury.reserveAssets();
        asset.safeTransferFrom(msg.sender, address(treasury), assets);
        treasury.depositReserve();
        uint256 afterValue = treasury.reserveAssets();
        uint256 credited = afterValue > before ? (afterValue - before) * scale : 0;
        if (credited < MIN_AMOUNT) revert AmountTooSmall();

        uint256 fee = Math.mulDiv(credited, mintFeeRate(h), WAD, Math.Rounding.Ceil);
        out = credited - fee;
        if (out < minOut) revert Slippage();
        _consumeExpansion(out, h);
        uint256 supply = token.totalSupply();
        if (supply + out > supplyCap) revert SupplyCapExceeded(supplyCap > supply ? supplyCap - supply : 0);

        token.mint(receiver, out);
        _assertSolvent();
        emit Minted(msg.sender, receiver, assets, out, fee, h);
    }

    /// @notice Burn `amount` sUSD from the caller and send collateral to `receiver`.
    /// @dev    Never pausable. Paid from the idle buffer first. If idle funds plus the
    ///         vault's `maxWithdraw` cannot cover it, reverts with
    ///         `AutonomousTreasury.InsufficientLiquidity(available)`; check
    ///         `treasury.liquidAssets()` and redeem a smaller amount.
    /// @param  amount       sUSD to burn; type(uint256).max redeems the caller's whole balance
    ///                      after any pending loss has been absorbed.
    /// @param  minAssetsOut Minimum collateral to receive.
    function redeem(uint256 amount, address receiver, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 assetsOut)
    {
        if (receiver == address(0)) revert ZeroAddress();
        _syncLoss();
        if (amount == type(uint256).max) amount = token.balanceOf(msg.sender);
        if (amount < MIN_AMOUNT) revert AmountTooSmall();
        uint256 h = oracle.smoothedEntropy();

        uint256 fee = Math.mulDiv(amount, redeemFeeRate(h), WAD, Math.Rounding.Ceil);
        assetsOut = (amount - fee) / scale;
        if (assetsOut < minAssetsOut) revert Slippage();

        token.burn(msg.sender, amount);
        _releaseExpansion(amount);
        treasury.withdrawReserve(assetsOut, receiver);
        _assertSolvent();
        emit Redeemed(msg.sender, receiver, amount, assetsOut, fee, h);
    }

    // ---------------------------------------------------------------------- keepers (permissionless)

    /// @notice Distribute part of the surplus above the buffer as one bounded micro-rebase.
    /// @return distributed False if a loss was absorbed instead, or the churn budget
    ///         deferred the step.
    function rebase() external nonReentrant whenNotPaused returns (bool distributed) {
        if (_syncLoss()) return false;
        if (block.timestamp < uint256(lastRebaseAt) + REBASE_INTERVAL) revert RebaseTooSoon();

        uint256 shares = token.totalShares();
        if (shares == 0) revert NothingToDistribute();
        uint256 supply = token.totalSupply();
        uint256 h = oracle.smoothedEntropy();

        uint256 maxSupply = Math.mulDiv(reserveValue(), WAD, WAD + bufferRate(h));
        if (maxSupply <= supply) revert NothingToDistribute();
        uint256 step = Math.min(maxSupply - supply, Math.mulDiv(supply, rebaseStepRate(h), WAD));

        uint256 oldIndex = token.index();
        uint256 dIndex = Math.mulDiv(step, WAD, shares);
        if (dIndex == 0) revert NothingToDistribute();
        uint256 newIndex = oldIndex + dIndex;

        (bool ok, uint256 len, uint256 range) = _churnAfter(oldIndex, newIndex);
        if (!ok) {
            emit RebaseDeferred(oldIndex, newIndex, len, range);
            return false;
        }
        _commitChurn(oldIndex, newIndex);
        token.setIndex(newIndex);
        lastRebaseAt = uint64(block.timestamp);
        _assertSolvent();
        emit Distributed(oldIndex, newIndex, token.totalSupply() - supply, h);
        return true;
    }

    /// @notice Absorb a realised reserve loss (if any) by lowering the index.
    /// @return absorbed True if the index was lowered.
    function sync() external nonReentrant returns (bool absorbed) {
        absorbed = _syncLoss();
    }

    /// @notice Move reserve funds toward the treasury's idle-buffer target (deposit the excess
    ///         or refill the buffer from the vault), then re-sync. Permissionless keeper call.
    function rebalanceReserve() external nonReentrant {
        treasury.rebalance();
        _syncLoss();
    }

    // ---------------------------------------------------------------------- guardian

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /// @notice Emergency: stop depositing and pull everything the vault pays now into idle
    ///         funds held by the treasury. Repeat as the vault's liquidity returns.
    function emergencyExitVault() external onlyRole(GUARDIAN_ROLE) nonReentrant returns (uint256 recovered) {
        recovered = treasury.exitVault();
        _syncLoss();
        emit EmergencyVaultExit(address(treasury.vault()), recovered);
    }

    /// @notice Cancel a pending vault migration.
    function cancelVaultMigration() external onlyRole(GUARDIAN_ROLE) {
        IERC4626 v = pendingVault;
        if (address(v) == address(0)) revert NoPendingVault();
        delete pendingVault;
        delete pendingVaultEta;
        emit VaultProposalCanceled(address(v));
    }

    // ---------------------------------------------------------------------- admin

    /// @notice Set the guarded-launch supply cap (sUSD wei). Lowering it only blocks mints.
    function setSupplyCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supplyCap = cap;
        emit SupplyCapSet(cap);
    }

    /// @notice Set the treasury's idle liquidity buffer (bps of reserve, 10_000 = all idle).
    function setLiquidityBuffer(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        treasury.setLiquidityBuffer(bps);
    }

    /// @notice Propose moving the reserve to `newVault`; executable after VAULT_TIMELOCK.
    function proposeVault(IERC4626 newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newVault) == address(0)) revert ZeroAddress();
        if (newVault.asset() != address(asset)) revert AssetMismatch();
        pendingVault = newVault;
        uint256 eta = block.timestamp + VAULT_TIMELOCK;
        // forge-lint: disable-next-line(unsafe-typecast)
        pendingVaultEta = uint64(eta);
        emit VaultProposed(address(newVault), eta);
    }

    /// @notice Execute the pending migration. Unredeemable old shares are quarantined and the
    ///         resulting loss is absorbed pro rata.
    function executeVaultMigration() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        IERC4626 v = pendingVault;
        if (address(v) == address(0)) revert NoPendingVault();
        if (block.timestamp < pendingVaultEta) revert VaultTimelockActive(pendingVaultEta);
        delete pendingVault;
        delete pendingVaultEta;
        address old = address(treasury.vault());
        _syncLoss();
        treasury.migrateVault(v);
        _syncLoss();
        emit VaultMigrationExecuted(old, address(v));
    }

    // ---------------------------------------------------------------------- policy (pure)

    /// @notice Minting fee rate (WAD) for entropy `h`: MIN + (MAX - MIN) h^2.
    function mintFeeRate(uint256 h) public pure returns (uint256) {
        h = _clamp(h);
        return MINT_FEE_MIN + Math.mulDiv(MINT_FEE_MAX - MINT_FEE_MIN, h * h, WAD * WAD);
    }

    /// @notice Redemption fee rate (WAD) for entropy `h`: MIN + (MAX - MIN) h^2.
    function redeemFeeRate(uint256 h) public pure returns (uint256) {
        h = _clamp(h);
        return REDEEM_FEE_MIN + Math.mulDiv(REDEEM_FEE_MAX - REDEEM_FEE_MIN, h * h, WAD * WAD);
    }

    /// @notice Per-epoch expansion cap as a fraction of epoch-start supply (WAD).
    function expansionCapRate(uint256 h) public pure returns (uint256) {
        h = _clamp(h);
        return EXPANSION_CAP_LOW_H - Math.mulDiv(EXPANSION_CAP_LOW_H - EXPANSION_CAP_HIGH_H, h, WAD);
    }

    /// @notice Reserve buffer kept before distributing (WAD fraction of supply).
    function bufferRate(uint256 h) public pure returns (uint256) {
        h = _clamp(h);
        return BUFFER_LOW_H + Math.mulDiv(BUFFER_HIGH_H - BUFFER_LOW_H, h, WAD);
    }

    /// @notice Maximum rebase step (WAD fraction of supply): halves from h = 0 to h = 1.
    function rebaseStepRate(uint256 h) public pure returns (uint256) {
        h = _clamp(h);
        return REBASE_STEP_MAX - Math.mulDiv(REBASE_STEP_MAX, h, 2 * WAD);
    }

    // ---------------------------------------------------------------------- views

    /// @notice Conservative reserve value in sUSD wei.
    function reserveValue() public view returns (uint256) {
        return treasury.reserveAssets() * scale;
    }

    /// @notice Reserve value / supply in WAD (max uint if supply is zero).
    function reserveRatio() external view returns (uint256) {
        uint256 supply = token.totalSupply();
        if (supply == 0) return type(uint256).max;
        return Math.mulDiv(reserveValue(), WAD, supply);
    }

    /// @notice Reserve value above supply, in sUSD wei (0 if under-reserved).
    function surplus() external view returns (uint256) {
        uint256 r = reserveValue();
        uint256 s = token.totalSupply();
        return r > s ? r - s : 0;
    }

    /// @notice Expansion still available in the current epoch, in sUSD wei.
    function expansionRemaining() external view returns (uint256) {
        (uint256 cap, uint256 used) = _epochState(oracle.smoothedEntropy());
        return cap > used ? cap - used : 0;
    }

    /// @notice Minting room left under the supply cap, in sUSD wei.
    function supplyCapRemaining() external view returns (uint256) {
        uint256 supply = token.totalSupply();
        return supplyCap > supply ? supplyCap - supply : 0;
    }

    /// @notice Approximate sUSD out for `assets` in (ignores vault rounding and entry fees).
    function quoteMint(uint256 assets) external view returns (uint256 out, uint256 fee) {
        uint256 credited = assets * scale;
        fee = Math.mulDiv(credited, mintFeeRate(oracle.smoothedEntropy()), WAD, Math.Rounding.Ceil);
        out = credited - fee;
    }

    /// @notice Collateral out for redeeming `amount` sUSD.
    function quoteRedeem(uint256 amount) external view returns (uint256 assetsOut, uint256 fee) {
        fee = Math.mulDiv(amount, redeemFeeRate(oracle.smoothedEntropy()), WAD, Math.Rounding.Ceil);
        assetsOut = (amount - fee) / scale;
    }

    // ---------------------------------------------------------------------- internals

    function _syncLoss() internal returns (bool absorbed) {
        uint256 supply = token.totalSupply();
        uint256 reserve = reserveValue();
        if (reserve >= supply) return false;
        uint256 shares = token.totalShares();
        uint256 oldIndex = token.index();
        uint256 newIndex = Math.mulDiv(reserve, WAD, shares); // floor => supply <= reserve
        if (newIndex == 0) newIndex = 1; // total loss: keep the index well-defined
        _commitChurn(oldIndex, newIndex);
        token.setIndex(newIndex);
        emit LossAbsorbed(oldIndex, newIndex, reserve, supply);
        return true;
    }

    function _consumeExpansion(uint256 out, uint256 h) internal {
        if (block.timestamp >= uint256(epochStart) + EPOCH) {
            epochStart = uint64(block.timestamp);
            epochSupply = token.totalSupply();
            mintedInEpoch = 0;
        }
        (uint256 cap, uint256 used) = _epochState(h);
        if (used + out > cap) revert ExpansionCapExceeded(cap > used ? cap - used : 0);
        mintedInEpoch = used + out;
    }

    /// @dev Redemptions in the current epoch free the capacity they return (floored at 0).
    ///      After the epoch has ended there is nothing to free: the next mint starts a new one.
    function _releaseExpansion(uint256 amount) internal {
        if (block.timestamp >= uint256(epochStart) + EPOCH) return;
        uint256 used = mintedInEpoch;
        mintedInEpoch = used > amount ? used - amount : 0;
    }

    function _epochState(uint256 h) internal view returns (uint256 cap, uint256 used) {
        bool expired = block.timestamp >= uint256(epochStart) + EPOCH;
        uint256 base = expired ? token.totalSupply() : epochSupply;
        used = expired ? 0 : mintedInEpoch;
        cap = Math.max(bootstrapCap, Math.mulDiv(base, expansionCapRate(h), WAD));
    }

    /// @dev Churn statistics after a hypothetical move oldIndex -> newIndex.
    function _churnAfter(uint256 oldIndex, uint256 newIndex)
        internal
        view
        returns (bool ok, uint256 len, uint256 range)
    {
        uint256 mx;
        uint256 mn;
        if (block.timestamp >= uint256(churnWindowStart) + CHURN_WINDOW) {
            len = 0;
            mx = oldIndex;
            mn = oldIndex;
        } else {
            len = churnLength;
            mx = churnMax;
            mn = churnMin;
        }
        len += newIndex > oldIndex ? newIndex - oldIndex : oldIndex - newIndex;
        if (newIndex > mx) mx = newIndex;
        if (newIndex < mn) mn = newIndex;
        range = mx - mn;
        ok = Math.mulDiv(len, WAD, 1) <= Math.mulDiv(C_DIAM_WAD, range, 1);
    }

    function _commitChurn(uint256 oldIndex, uint256 newIndex) internal {
        if (block.timestamp >= uint256(churnWindowStart) + CHURN_WINDOW) {
            churnWindowStart = uint64(block.timestamp);
            churnLength = 0;
            churnMax = oldIndex;
            churnMin = oldIndex;
        }
        churnLength += newIndex > oldIndex ? newIndex - oldIndex : oldIndex - newIndex;
        if (newIndex > churnMax) churnMax = newIndex;
        if (newIndex < churnMin) churnMin = newIndex;
    }

    function _assertSolvent() internal view {
        uint256 r = reserveValue();
        uint256 s = token.totalSupply();
        if (r < s) revert ReserveFloorBreached(r, s);
    }

    function _clamp(uint256 h) private pure returns (uint256) {
        return h > WAD ? WAD : h;
    }
}

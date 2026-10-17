// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {SpectralToken} from "./SpectralToken.sol";
import {AutonomousTreasury} from "./AutonomousTreasury.sol";
import {ISpectralEntropyOracle} from "./interfaces/ISpectralEntropyOracle.sol";
import {SpectralPolicy} from "./libraries/SpectralPolicy.sol";

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
///         larger expansion cap). High H = flow dominated by a few large swaps (higher fees,
///         tighter cap, larger buffer, smaller rebase steps). H is a heuristic that an
///         attacker can steer at some cost, so its effect is limited to the bounded policy
///         ranges below, never reaches the backing, and can only ever *raise* a safety margin:
///         the surplus buffer is floored at its neutral value whatever H reads (Phase 4, D4).
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
///         L <= CHURN_BUDGET * D; otherwise it is deferred. Monotone paths (pure yield
///         distribution) always satisfy L = D. The budget binds only when gains and losses
///         alternate: with equal swings, the third upward leg in a window is deferred. Loss
///         absorption is never deferred.
///         CHURN_BUDGET = 5*pi/6 + 2 sin(pi/12) = 3.1356... is the proven upper bound on the
///         length-over-diameter ratio of self-approaching plane curves (Theorem 4.3). Here it
///         is a design constant in a one-dimensional rule, and no stability property follows
///         from the geometry; see CHURN_BUDGET_WAD and docs/paper-map.md.
///
///         Guarded launch. `supplyCap` bounds total minting (rebases may exceed it); the admin
///         raises it as confidence grows. The daily expansion cap still applies under it.
///
///         Roles. DEFAULT_ADMIN_ROLE (a Safe): supply cap, liquidity buffer, vault migration
///         behind a 7-day timelock (holders can redeem before it executes). The admin role
///         itself transfers in two steps behind ADMIN_TRANSFER_DELAY (OpenZeppelin
///         AccessControlDefaultAdminRules), and it cannot be renounced in one call.
///         GUARDIAN_ROLE (a faster Safe or monitored key, plus the admin): pause/unpause
///         minting and rebasing, emergency exit from the vault into idle funds, cancelling a
///         pending migration. Nobody can pause redemption or loss absorption, or move reserve
///         funds to an address of their choosing.
///
///         Vault allowlist. The vaults the reserve may ever sit in are fixed at construction
///         (at most MAX_ALLOWED_VAULTS, all over the same asset). `proposeVault` rejects
///         anything else, so even a compromised admin cannot route the reserve into a contract
///         of its own; the worst it can do is move funds between vetted venues, after 7 days
///         in which holders can redeem (Phase 4, A5). The emergency exit to idle funds never
///         depends on the allowlist.
contract SpectralStabilizer is AccessControlDefaultAdminRules, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ---------------------------------------------------------------------- roles

    /// @notice May pause minting and rebasing (never redemption or loss absorption).
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ---------------------------------------------------------------------- constants

    uint256 internal constant WAD = 1e18;

    /// @notice The churn budget's ratio, 5*pi/6 + 2 sin(pi/12) = 3.135631968196535891 in WAD
    ///         (rounded up).
    /// @dev    From E. Langetepe and W. A. Ashioya, "The length-over-diameter ratio of
    ///         self-approaching curves", revised version 21 (October 2026), Theorem 4.3
    ///         (proven): a self-approaching plane curve is at most this many times as long as
    ///         its diameter. Until Phase 4 the budget used 2 + pi/3 = 3.0472, which curves
    ///         approach (Theorem 5.4) but which is only conjectured to be sharp (Conjecture
    ///         1.2, open). Since then no code depends on an open result.
    ///
    ///         Here it is a design constant in a one-dimensional rule. On a line a
    ///         self-approaching path is simply monotone, so none of the planar theorems applies
    ///         and no stability property follows from the geometry. See docs/paper-map.md.
    uint256 public constant CHURN_BUDGET_WAD = SpectralPolicy.CHURN_BUDGET_WAD;

    // The policy curves and their constants live in SpectralPolicy, so that the formal checks
    // run on exactly this code (Phase 4, A11). The constants are re-exported here.

    /// @notice Minting fee at h = 0 and at h = 1 (WAD rates): 1 bp to 25 bp, quadratic in h
    ///         (50 bp before Phase 4, D4).
    uint256 public constant MINT_FEE_MIN = SpectralPolicy.MINT_FEE_MIN;
    uint256 public constant MINT_FEE_MAX = SpectralPolicy.MINT_FEE_MAX;
    /// @notice Redemption fee at h = 0 and at h = 1: 1 bp to 10 bp, quadratic in h.
    ///         Kept low on purpose: cheap exits are what make the peg credible.
    uint256 public constant REDEEM_FEE_MIN = SpectralPolicy.REDEEM_FEE_MIN;
    uint256 public constant REDEEM_FEE_MAX = SpectralPolicy.REDEEM_FEE_MAX;

    /// @notice Net minting allowed per epoch (sUSD minted minus sUSD redeemed in the epoch,
    ///         floored at zero), as a fraction of supply at the start of the epoch: 20% at
    ///         h = 0 down to 2% at h = 1. Counting net flow means a mint-and-redeem round trip
    ///         in one transaction cannot use up other users' capacity (Phase 4, A1).
    uint256 public constant EPOCH = 1 days;
    uint256 public constant EXPANSION_CAP_LOW_H = SpectralPolicy.EXPANSION_CAP_LOW_H;
    uint256 public constant EXPANSION_CAP_HIGH_H = SpectralPolicy.EXPANSION_CAP_HIGH_H;

    /// @notice Micro-rebases: at most one per hour, each at most 1 bp of supply at h = 0
    ///         (0.5 bp at h = 1). The step stays below the 2 bp round-trip fee floor, so
    ///         minting just before a rebase and redeeming just after cannot profit.
    uint256 public constant REBASE_INTERVAL = 1 hours;
    uint256 public constant REBASE_STEP_MAX = SpectralPolicy.REBASE_STEP_MAX;

    /// @notice Surplus kept as a buffer before anything is distributed: 2.75% to 5% of supply.
    /// @dev    H may raise a safety margin but never lower it (Phase 4, D4), so the buffer is
    ///         floored at its neutral value, BUFFER_LOW_H + (BUFFER_HIGH_H - BUFFER_LOW_H)/2
    ///         with the pre-Phase-4 endpoints 0.5% and 5%. Steering H towards 0 can therefore
    ///         no longer drain the first-loss cushion; it can only fail to raise it.
    uint256 public constant BUFFER_LOW_H = SpectralPolicy.BUFFER_LOW_H;
    uint256 public constant BUFFER_HIGH_H = SpectralPolicy.BUFFER_HIGH_H;

    /// @notice Length of the churn-budget window.
    uint256 public constant CHURN_WINDOW = 7 days;

    /// @notice Delay between proposing and executing a vault migration.
    uint256 public constant VAULT_TIMELOCK = 7 days;

    /// @notice Delay on a transfer of DEFAULT_ADMIN_ROLE (two-step, OpenZeppelin rules).
    uint48 public constant ADMIN_TRANSFER_DELAY = 3 days;

    /// @notice Largest allowlist the constructor accepts.
    uint256 public constant MAX_ALLOWED_VAULTS = 4;

    /// @notice Smallest mint (credited value) or partial redemption, in sUSD wei.
    /// @dev    Derived, not round (Phase 4, A7). The worst case the minimum has to cover is one
    ///         wei of the reserve asset lost to vault rounding, which is `scale` sUSD wei
    ///         (1e12 for USDC). The minimum fee rate is REDEEM_FEE_MIN = 1 bp, so a redemption
    ///         of `a` pays at least `a / 10_000`; requiring that to reach `scale` gives
    ///         `a >= 10_000 * scale`, i.e. 0.01 sUSD for USDC. `minAmount()` computes it from
    ///         `scale`; MIN_AMOUNT is the USDC value and stays as the documented constant.
    ///         A holder whose whole balance is below the minimum can still exit in full
    ///         (`redeem` with their exact balance or the max sentinel), so no dust is trapped.
    uint256 public constant MIN_AMOUNT = 0.01e18;

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

    // Three timestamps in one slot (Phase 4, B3). Every amount below is bounded far under
    // 2^128: supply cannot exceed the reserve, and the reserve is USDC, whose total supply is
    // about 2^93 in sUSD wei; the index starts at 1e18 and grows by at most 1 bp an hour.
    uint64 public epochStart;
    uint64 public lastRebaseAt;
    uint64 public churnWindowStart;

    // One slot: supply at the start of the epoch and net minting inside it.
    uint128 public epochSupply;
    uint128 public mintedInEpoch;

    // One slot: the churn path's total variation and its running maximum.
    uint128 public churnLength;
    uint128 public churnMax;

    // One slot: the churn minimum and the pending migration's earliest execution time.
    uint128 public churnMin;
    uint64 public pendingVaultEta;

    /// @notice Maximum total supply reachable by minting (guarded launch).
    uint256 public supplyCap;

    /// @notice First-loss capital in sUSD wei: reserve value contributed through
    ///         `contributeCapital`, without minting. It is never distributed and nobody can
    ///         withdraw it; only the yield it earns is (Phase 4, B8).
    uint256 public protocolCapital;

    /// @notice Vault proposed for migration.
    IERC4626 public pendingVault;

    /// @dev Vaults the reserve may sit in, fixed at construction.
    address[] private _allowedVaults;

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
    /// @param credited Reserve value added, in sUSD wei (the measured increase).
    event CapitalContributed(address indexed from, uint256 assets, uint256 credited);
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
    error VaultNotAllowed(address vault);
    error BadVaultAllowlist();

    // ---------------------------------------------------------------------- constructor

    /// @param admin        DEFAULT_ADMIN_ROLE and GUARDIAN_ROLE holder (use a Safe).
    /// @param guardian     Extra GUARDIAN_ROLE holder (address(0) for none).
    /// @param bootstrapCap_ Expansion allowed per epoch regardless of supply.
    /// @param supplyCap_   Maximum total supply reachable by minting.
    /// @param allowedVaults_ Every vault the reserve may ever sit in, including the one the
    ///                     treasury starts with. 1 to MAX_ALLOWED_VAULTS entries, all over the
    ///                     treasury's asset, no duplicates.
    constructor(
        SpectralToken token_,
        AutonomousTreasury treasury_,
        ISpectralEntropyOracle oracle_,
        address admin,
        address guardian,
        uint256 bootstrapCap_,
        uint256 supplyCap_,
        address[] memory allowedVaults_
    ) AccessControlDefaultAdminRules(ADMIN_TRANSFER_DELAY, admin) {
        if (
            address(token_) == address(0) || address(treasury_) == address(0) || address(oracle_) == address(0)
                || admin == address(0)
        ) revert ZeroAddress();
        // Vaults the reserve may ever sit in, fixed here (Phase 4, A5).
        uint256 n = allowedVaults_.length;
        if (n == 0 || n > MAX_ALLOWED_VAULTS) revert BadVaultAllowlist();
        address reserveAsset = address(treasury_.asset());
        address current = address(treasury_.vault());
        bool startingVaultListed = false;
        for (uint256 i; i < n; ++i) {
            address v = allowedVaults_[i];
            if (v == address(0) || IERC4626(v).asset() != reserveAsset) revert BadVaultAllowlist();
            for (uint256 k; k < i; ++k) {
                if (allowedVaults_[k] == v) revert BadVaultAllowlist();
            }
            if (v == current) startingVaultListed = true;
            _allowedVaults.push(v);
        }
        if (!startingVaultListed) revert BadVaultAllowlist();

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

        epochStart = block.timestamp.toUint64();
        churnWindowStart = block.timestamp.toUint64();
        // WAD = 1e18 < 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        churnMax = uint128(WAD);
        // forge-lint: disable-next-line(unsafe-typecast)
        churnMin = uint128(WAD);

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
        // The reserve is valued once per state change and the value is carried forward, so a
        // mint makes 3 valuations instead of 6 (Phase 4, B1).
        _syncLossWith(reserveValue());
        uint256 h = oracle.smoothedEntropy();

        // Only the reserve values are needed from sweep and depositReserve, not the shares.
        // slither-disable-next-line unused-return
        (, uint256 before) = treasury.sweep(); // donations become surplus before measuring
        asset.safeTransferFrom(msg.sender, address(treasury), assets);
        // slither-disable-next-line unused-return
        (, uint256 afterValue) = treasury.depositReserve();
        uint256 credited = afterValue > before ? (afterValue - before) * scale : 0;
        if (credited < minAmount()) revert AmountTooSmall();

        uint256 fee = Math.mulDiv(credited, mintFeeRate(h), WAD, Math.Rounding.Ceil);
        out = credited - fee;
        if (out < minOut) revert Slippage();
        _consumeExpansion(out, h);
        uint256 supply = token.totalSupply();
        if (supply + out > supplyCap) revert SupplyCapExceeded(supplyCap > supply ? supplyCap - supply : 0);

        // slither-disable-next-line unused-return
        token.mint(receiver, out); // returns the shares minted, which are not needed here
        _assertSolventWith(afterValue * scale); // minting does not move the reserve
        emit Minted(msg.sender, receiver, assets, out, fee, h);
    }

    /// @notice Burn `amount` sUSD from the caller and send collateral to `receiver`.
    /// @dev    Never pausable. Paid from the idle buffer first. If idle funds plus the
    ///         vault's `maxWithdraw` cannot cover it, reverts with
    ///         `AutonomousTreasury.InsufficientLiquidity(available)`; check
    ///         `treasury.liquidAssets()` and redeem a smaller amount.
    /// @param  amount       sUSD to burn; type(uint256).max redeems the caller's whole balance
    ///                      after any pending loss has been absorbed. A full exit is allowed
    ///                      below `minAmount()`; a partial one is not (Phase 4, A7).
    /// @param  minAssetsOut Minimum collateral to receive.
    function redeem(uint256 amount, address receiver, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 assetsOut)
    {
        if (receiver == address(0)) revert ZeroAddress();
        _syncLossWith(reserveValue());
        uint256 balance = token.balanceOf(msg.sender);
        if (amount == type(uint256).max) amount = balance;
        if (amount < minAmount() && amount != balance) revert AmountTooSmall();
        uint256 h = oracle.smoothedEntropy();

        uint256 fee = Math.mulDiv(amount, redeemFeeRate(h), WAD, Math.Rounding.Ceil);
        assetsOut = (amount - fee) / scale;
        // slither-disable-next-line incorrect-equality
        if (assetsOut == 0) revert AmountTooSmall(); // nothing to pay out (a guard)
        if (assetsOut < minAssetsOut) revert Slippage();

        // slither-disable-next-line unused-return
        token.burn(msg.sender, amount); // returns the shares burned, which are not needed here
        _releaseExpansion(amount);
        uint256 reserveAfter = treasury.withdrawReserve(assetsOut, receiver);
        _assertSolventWith(reserveAfter * scale);
        emit Redeemed(msg.sender, receiver, amount, assetsOut, fee, h);
    }

    // Reentrancy: nonReentrant on every state-changing entry point (rebase reads the capital),
    // and the calls go to the immutable treasury and reserve asset (audit/slither.md).
    // slither-disable-start reentrancy-no-eth
    /// @notice Add `assets` of collateral to the reserve as protocol capital. No sUSD is
    ///         minted, and the amount can never be distributed or withdrawn: it is a first-loss
    ///         cushion. A loss up to the capital plus the surplus lowers no balance, so exiting
    ///         ahead of it gains nothing (Phase 4, A9). Rebases then distribute only what the
    ///         reserve holds above supply plus capital, so after such a loss distributions
    ///         pause until yield has rebuilt the capital. Anyone may contribute; nothing is
    ///         returned.
    /// @dev    Like a mint, the credited value is the measured increase of the conservative
    ///         reserve valuation, and earlier donations are swept into surplus first, so they
    ///         are not counted as capital. Not pausable: adding backing is always allowed.
    function contributeCapital(uint256 assets) external nonReentrant returns (uint256 credited) {
        _syncLossWith(reserveValue());
        // slither-disable-next-line unused-return
        (, uint256 before) = treasury.sweep();
        asset.safeTransferFrom(msg.sender, address(treasury), assets);
        // slither-disable-next-line unused-return
        (, uint256 afterValue) = treasury.depositReserve();
        credited = afterValue > before ? (afterValue - before) * scale : 0;
        if (credited == 0) revert AmountTooSmall();
        protocolCapital += credited;
        _assertSolventWith(afterValue * scale);
        emit CapitalContributed(msg.sender, assets, credited);
    }
    // slither-disable-end reentrancy-no-eth

    // ---------------------------------------------------------------------- keepers (permissionless)

    /// @notice Distribute part of the surplus above the buffer as one bounded micro-rebase.
    /// @return distributed False if a loss was absorbed instead, or the churn budget
    ///         deferred the step.
    function rebase() external nonReentrant whenNotPaused returns (bool distributed) {
        uint256 reserveWad = reserveValue(); // valued once; a rebase never moves the reserve
        if (_syncLossWith(reserveWad)) return false;
        if (block.timestamp < uint256(lastRebaseAt) + REBASE_INTERVAL) revert RebaseTooSoon();

        uint256 shares = token.totalShares();
        if (shares == 0) revert NothingToDistribute();
        uint256 supply = token.totalSupply();
        uint256 h = oracle.smoothedEntropy();

        // Supply may rise to the reserve less the buffer, and never into protocol capital
        // (Phase 4, B8): min(reserve / (1 + buffer), reserve - capital).
        uint256 maxSupply = Math.mulDiv(reserveWad, WAD, WAD + bufferRate(h));
        uint256 capital = protocolCapital;
        uint256 uncommitted = reserveWad > capital ? reserveWad - capital : 0;
        if (uncommitted < maxSupply) maxSupply = uncommitted;
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
        lastRebaseAt = block.timestamp.toUint64(); // effects before the call (checks-effects-interactions)
        token.setIndex(newIndex);
        _assertSolventWith(reserveWad);
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
        _syncLossWith(treasury.rebalance() * scale);
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
        if (!isAllowedVault(address(newVault))) revert VaultNotAllowed(address(newVault));
        pendingVault = newVault;
        uint256 eta = block.timestamp + VAULT_TIMELOCK;
        pendingVaultEta = eta.toUint64();
        emit VaultProposed(address(newVault), eta);
    }

    // Reentrancy: nonReentrant on every state-changing entry point, and the calls go to the
    // immutable token and treasury and, through it, to allowlisted vaults (audit/slither.md).
    // slither-disable-start reentrancy-no-eth
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
    // slither-disable-end reentrancy-no-eth

    // ---------------------------------------------------------------------- policy (pure)

    /// @notice Minting fee rate (WAD) for entropy `h`: MIN + (MAX - MIN) h^2.
    function mintFeeRate(uint256 h) public pure returns (uint256) {
        return SpectralPolicy.mintFeeRate(h);
    }

    /// @notice Redemption fee rate (WAD) for entropy `h`: MIN + (MAX - MIN) h^2.
    function redeemFeeRate(uint256 h) public pure returns (uint256) {
        return SpectralPolicy.redeemFeeRate(h);
    }

    /// @notice Per-epoch expansion cap as a fraction of epoch-start supply (WAD).
    function expansionCapRate(uint256 h) public pure returns (uint256) {
        return SpectralPolicy.expansionCapRate(h);
    }

    /// @notice Reserve buffer kept before distributing (WAD fraction of supply). Rises with H
    ///         from the neutral floor; never falls below it (Phase 4, D4).
    function bufferRate(uint256 h) public pure returns (uint256) {
        return SpectralPolicy.bufferRate(h);
    }

    /// @notice Maximum rebase step (WAD fraction of supply): halves from h = 0 to h = 1.
    function rebaseStepRate(uint256 h) public pure returns (uint256) {
        return SpectralPolicy.rebaseStepRate(h);
    }

    // ---------------------------------------------------------------------- views
    //
    // Convenience views (quotes, ratios, room under the caps) live in SpectrumLens, which is
    // derived entirely from the public state below (Phase 4, B6).

    /// @notice Smallest mint or partial redemption for this reserve asset, in sUSD wei:
    ///         `10_000 * scale`, the amount at which the 1 bp minimum fee still covers one wei
    ///         of vault rounding. 0.01 sUSD for a 6-decimal asset (Phase 4, A7).
    function minAmount() public view returns (uint256) {
        return 10_000 * scale;
    }

    /// @notice Conservative reserve value in sUSD wei.
    function reserveValue() public view returns (uint256) {
        return treasury.reserveAssets() * scale;
    }

    /// @notice True if `v` is on the immutable vault allowlist.
    function isAllowedVault(address v) public view returns (bool) {
        uint256 n = _allowedVaults.length;
        for (uint256 i; i < n; ++i) {
            if (_allowedVaults[i] == v) return true;
        }
        return false;
    }

    /// @notice Every vault the reserve may sit in, fixed at construction.
    function allowedVaults() external view returns (address[] memory) {
        return _allowedVaults;
    }

    // ---------------------------------------------------------------------- internals

    function _syncLoss() internal returns (bool absorbed) {
        return _syncLossWith(reserveValue());
    }

    /// @dev Absorb a loss given an already-computed reserve value (sUSD wei).
    function _syncLossWith(uint256 reserve) internal returns (bool absorbed) {
        uint256 supply = token.totalSupply();
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
            epochStart = block.timestamp.toUint64();
            epochSupply = token.totalSupply().toUint128();
            mintedInEpoch = 0;
        }
        (uint256 cap, uint256 used) = _epochState(h);
        if (used + out > cap) revert ExpansionCapExceeded(cap > used ? cap - used : 0);
        mintedInEpoch = (used + out).toUint128();
    }

    /// @dev Redemptions in the current epoch free the capacity they return (floored at 0).
    ///      After the epoch has ended there is nothing to free: the next mint starts a new one.
    function _releaseExpansion(uint256 amount) internal {
        if (block.timestamp >= uint256(epochStart) + EPOCH) return;
        uint256 used = mintedInEpoch;
        mintedInEpoch = (used > amount ? used - amount : 0).toUint128();
    }

    function _epochState(uint256 h) internal view returns (uint256 cap, uint256 used) {
        bool expired = block.timestamp >= uint256(epochStart) + EPOCH;
        uint256 base = expired ? token.totalSupply() : epochSupply;
        used = expired ? 0 : mintedInEpoch;
        cap = Math.max(bootstrapCap, Math.mulDiv(base, expansionCapRate(h), WAD));
    }

    /// @dev The churn window's statistics before the next move: restarted at `oldIndex` once
    ///      the window has expired. The index is far below 2^128 (it starts at 1e18), and
    ///      SafeCast keeps the churn step's input domain honest regardless.
    function _churnState(uint256 oldIndex) internal view returns (bool expired, uint128 len, uint128 mx, uint128 mn) {
        expired = block.timestamp >= uint256(churnWindowStart) + CHURN_WINDOW;
        if (expired) {
            uint128 start = oldIndex.toUint128();
            return (true, 0, start, start);
        }
        return (false, churnLength, churnMax, churnMin);
    }

    /// @dev Churn statistics after a hypothetical move oldIndex -> newIndex.
    function _churnAfter(uint256 oldIndex, uint256 newIndex)
        internal
        view
        returns (bool ok, uint256 len, uint256 range)
    {
        (, uint128 len0, uint128 mx, uint128 mn) = _churnState(oldIndex);
        (len,,, range, ok) = SpectralPolicy.churnStep(len0, mx, mn, oldIndex.toUint128(), newIndex.toUint128());
    }

    function _commitChurn(uint256 oldIndex, uint256 newIndex) internal {
        (bool expired, uint128 len0, uint128 mx0, uint128 mn0) = _churnState(oldIndex);
        if (expired) churnWindowStart = block.timestamp.toUint64();
        (uint256 len, uint256 mx, uint256 mn,,) =
            SpectralPolicy.churnStep(len0, mx0, mn0, oldIndex.toUint128(), newIndex.toUint128());
        churnLength = len.toUint128();
        churnMax = mx.toUint128();
        churnMin = mn.toUint128();
    }

    /// @dev The floor check against an already-computed reserve value (sUSD wei).
    function _assertSolventWith(uint256 r) internal view {
        uint256 s = token.totalSupply();
        if (r < s) revert ReserveFloorBreached(r, s);
    }

}

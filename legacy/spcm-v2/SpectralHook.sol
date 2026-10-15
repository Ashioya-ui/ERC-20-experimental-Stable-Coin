// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook}       from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks}          from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager}   from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}        from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta}   from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency}       from "v4-core/src/types/Currency.sol";

import "./SpectralEntropyOracle.sol";
import "./AutonomousTreasury.sol";

/**
 * @title  SpectralHook
 * @notice Uniswap V4 hook — spectral dynamic fees + entropy oracle feeding.
 *
 * PATCHES vs previous version:
 *   [CRITICAL] beforeSwap return: use BaseHook.beforeSwap.selector, not hardcoded
 *              0x00544c07 which was wrong and would cause every swap to revert.
 *   [HIGH]     afterSwap passes rawAmount directly to oracle.observe() without
 *              pre-dividing by 1e15. Oracle handles all normalization internally.
 *              Previous division caused USDC (6 decimals) to always hit bin 0.
 *   [HIGH]     _checkDrift consecutive threshold increased to 5 (was 3).
 *              Legitimate market volatility swings of 0.3–0.5 nats are normal
 *              and should not trigger drift alerts.
 *   [MEDIUM]   afterSwap records swap volume using hookData-decoded swapper address.
 *              In V4, afterSwap's `sender` is the PoolManager, not the actual user.
 *              We decode the real swapper from hookData (passed by the router).
 *              Falls back to tx.origin if hookData is empty (acceptable for EOAs).
 *
 * HOOK ADDRESS FLAGS REQUIRED (last 14 bits):
 *   BEFORE_SWAP_FLAG (bit 7) | AFTER_SWAP_FLAG (bit 6) = 0x00C0
 *   Mine with: forge script script/MineHookSalt.s.sol
 */
contract SpectralHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    SpectralEntropyOracle public immutable oracle;
    AutonomousTreasury    public           treasury;

    address public owner;

    // Drift detection state (SHOAL-derived)
    uint256 public lastEntropySnapshot;
    uint256 public consecutiveDriftCount;
    bool    public driftAlert;

    // [HIGH] Increased to 5 — prevents false alerts on legitimate volatility
    uint256 public constant DRIFT_CONSECUTIVE_THRESHOLD = 5;
    uint256 public constant DRIFT_DELTA_THRESHOLD       = 5e17; // 0.5 nats per observation

    uint256 public totalSwapsObserved;
    uint256 public totalDriftAlerts;

    event SpectralSwap(
        bytes32 indexed poolId,
        uint256 entropy,
        uint24  dynamicFee,
        bool    critical,
        int256  amountSpecified,
        address swapper
    );
    event DriftAlert(uint256 current, uint256 previous, uint256 consecutive);
    event DriftCleared();
    event TreasurySet(address treasury);

    error OnlyOwner();

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(
        IPoolManager _poolManager,
        address _oracle,
        address _owner
    ) BaseHook(_poolManager) {
        oracle = SpectralEntropyOracle(_oracle);
        owner  = _owner;
    }

    // ─── Hook permissions ────────────────────────────────────────────────────
    function getHookPermissions()
        public pure override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize:                 false,
            afterInitialize:                  false,
            beforeAddLiquidity:               false,
            afterAddLiquidity:                false,
            beforeRemoveLiquidity:            false,
            afterRemoveLiquidity:             false,
            beforeSwap:                       true,
            afterSwap:                        true,
            beforeDonate:                     false,
            afterDonate:                      false,
            beforeSwapReturnDelta:            false,
            afterSwapReturnDelta:             false,
            afterAddLiquidityReturnDelta:     false,
            afterRemoveLiquidityReturnDelta:  false
        });
    }

    // ─── beforeSwap ───────────────────────────────────────────────────────────
    /**
     * @notice Override pool fee with spectral dynamic fee.
     *         [CRITICAL] Return BaseHook.beforeSwap.selector — not hardcoded.
     */
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24 feeOverride)
    {
        (uint256 entropy, bool critical,,,) = oracle.getState();

        feeOverride = oracle.getDynamicFee();
        _checkDrift(entropy);
        if (driftAlert) feeOverride = 30000;   // 3% during confirmed drift attack

        emit SpectralSwap(
            PoolId.unwrap(key.toId()),
            entropy,
            feeOverride,
            critical,
            params.amountSpecified,
            address(0)   // swapper unknown at beforeSwap
        );

        // [CRITICAL] Correct selector via BaseHook — not hardcoded
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    // ─── afterSwap ────────────────────────────────────────────────────────────
    /**
     * @notice Feed swap amount into oracle; record activity to treasury.
     *
     * [HIGH] Passes rawAmount directly to oracle.observe() without pre-dividing.
     *        Oracle's _log2() handles all scales (USDC 1e6, ETH 1e18, etc.).
     *
     * [MEDIUM] Swapper address decoded from hookData if available.
     *          In V4, the first arg `sender` is the PoolManager contract, not the user.
     *          Routers should pass abi.encode(actualSwapper) as hookData.
     *          Falls back to tx.origin for direct EOA swaps.
     */
    function afterSwap(
        address,    // sender = PoolManager in V4, not the actual swapper
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    )
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        // [MEDIUM] Decode actual swapper from hookData, fallback to tx.origin
        address swapper;
        if (hookData.length >= 32) {
            swapper = abi.decode(hookData, (address));
        }
        if (swapper == address(0)) {
            swapper = tx.origin;   // acceptable for EOA direct swaps
        }

        // Pick the larger absolute delta — more representative of trade size
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 abs0 = uint256(int256(d0 < 0 ? -d0 : d0));
        uint256 abs1 = uint256(int256(d1 < 0 ? -d1 : d1));
        uint256 rawAmount = abs0 > abs1 ? abs0 : abs1;

        if (rawAmount == 0) {
            rawAmount = uint256(
                params.amountSpecified < 0
                    ? -params.amountSpecified
                    : params.amountSpecified
            );
        }

        // [HIGH] Pass rawAmount directly — oracle handles log2 bucketing
        if (rawAmount > 0) {
            oracle.observe(rawAmount);
        }

        // Record for treasury distribution
        if (address(treasury) != address(0) && rawAmount > 0) {
            try treasury.recordActivity(swapper, rawAmount) {} catch {}
        }

        totalSwapsObserved++;
        return (BaseHook.afterSwap.selector, 0);
    }

    // ─── Drift detection ─────────────────────────────────────────────────────

    /**
     * @notice [HIGH] Flag rapid entropy shifts (coordinated manipulation).
     *         Requires DRIFT_CONSECUTIVE_THRESHOLD (5) consecutive large shifts.
     *         Threshold raised from 3 to prevent false positives on normal volatility.
     */
    function _checkDrift(uint256 current) internal {
        if (lastEntropySnapshot == 0) {
            lastEntropySnapshot = current;
            return;
        }

        uint256 delta = current > lastEntropySnapshot
            ? current - lastEntropySnapshot
            : lastEntropySnapshot - current;

        if (delta > DRIFT_DELTA_THRESHOLD) {
            consecutiveDriftCount++;
            if (consecutiveDriftCount >= DRIFT_CONSECUTIVE_THRESHOLD) {
                if (!driftAlert) {
                    driftAlert = true;
                    totalDriftAlerts++;
                }
                emit DriftAlert(current, lastEntropySnapshot, consecutiveDriftCount);
            }
        } else {
            if (consecutiveDriftCount > 0) consecutiveDriftCount--;
            if (consecutiveDriftCount == 0 && driftAlert) {
                driftAlert = false;
                emit DriftCleared();
            }
        }

        lastEntropySnapshot = current;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────
    function setTreasury(address _treasury) external {
        if (msg.sender != owner) revert OnlyOwner();
        treasury = AutonomousTreasury(payable(_treasury));
        emit TreasurySet(_treasury);
    }

    function clearDriftAlert() external {
        if (msg.sender != owner) revert OnlyOwner();
        driftAlert            = false;
        consecutiveDriftCount = 0;
        emit DriftCleared();
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert OnlyOwner();
        owner = newOwner;
    }
}

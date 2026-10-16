// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {ISpectralEntropyOracle} from "./interfaces/ISpectralEntropyOracle.sol";

/// @title  SpectralHook
/// @notice Uniswap v4 hook that feeds the absolute size of one leg of every swap in one
///         designated pool into the SpectralEntropyOracle.
///
/// @dev    Which pool. The pool must pair wsUSD (the non-rebasing wrapper, see WrappedSUSD)
///         with the reserve asset, e.g. wsUSD/USDC. Never create a pool with raw, rebasing
///         sUSD. The measured leg is `measuredCurrency` (normally wsUSD, whose 18 decimals
///         match the oracle's dust threshold). Within the 8-block window the wsUSD/sUSD rate
///         is effectively constant, and the entropy is scale invariant, so no conversion is
///         done.
///
///         Permissions: `beforeInitialize` and `afterSwap` only. The deployed address must
///         carry exactly these flags in its low 14 bits (BEFORE_INITIALIZE_FLAG =
///         1 << 13, AFTER_SWAP_FLAG = 1 << 6; mine a CREATE2 salt). The constructor
///         validates this.
///
///         One pool only. The pool key is fixed at construction, and `beforeInitialize`
///         rejects every other pool. Nobody can attach this hook to a spam pool and write
///         into the oracle.
///
///         Starting price. `beforeInitialize` also requires the starting price to be within
///         `INIT_PRICE_TOLERANCE_BPS` of wsUSD's redemption value in the paired asset
///         (`convertToAssets` of the measured wrapper, with the paired asset at par with sUSD).
///         Once the hook is deployed its pool key is public, so without this check anyone
///         could initialise the pool off-peg before the deployer does (Phase 4, A2).
///
///         Oracle failures. The oracle call is wrapped in try/catch. A failure that carries
///         revert data (a bug or a guard in the oracle) is logged and skipped, so it never
///         bricks the pool. A failure without revert data means the call ran out of gas;
///         then the whole swap reverts (`OracleOutOfGas`). Otherwise a swapper could pick a
///         gas limit that starves the call and so choose not to be recorded. The oracle never
///         reverts without data: it uses custom errors and checked arithmetic (Panic data).
///         Gas: a window close with cold storage costs about 50k gas (see the tests); wallets
///         that size gas with eth_estimateGas include it automatically.
///
///         Implemented directly against `IHooks`. BaseHook is no longer part of
///         v4-periphery; it lives in OpenZeppelin's uniswap-hooks.
contract SpectralHook is IHooks {
    using PoolIdLibrary for PoolKey;

    /// @notice Largest allowed distance, in bp of price, between the pool's starting price and
    ///         wsUSD's redemption value.
    uint256 public constant INIT_PRICE_TOLERANCE_BPS = 50;
    uint256 internal constant Q96 = 1 << 96;

    IPoolManager public immutable poolManager;
    ISpectralEntropyOracle public immutable oracle;
    /// @notice The currency whose absolute swap delta is recorded (normally wsUSD).
    Currency public immutable measuredCurrency;
    /// @notice The only pool allowed to use this hook.
    PoolId public immutable allowedPoolId;
    /// @notice True if the measured currency is currency0 of the allowed pool.
    bool public immutable measuredIsCurrency0;
    /// @dev 10^decimals of the measured and of the paired currency.
    uint256 internal immutable measuredUnit;
    uint256 internal immutable otherUnit;

    event OracleRecordFailed(bytes reason);

    error NotPoolManager();
    error PoolNotAllowed();
    error HookNotImplemented();
    error OracleOutOfGas();
    error SameCurrency();
    error PriceOutOfBand(uint160 sqrtPriceX96, uint256 parPriceX96);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_  Uniswap v4 PoolManager.
    /// @param oracle_       Entropy oracle (must later register this hook via setHook).
    /// @param measured      Currency whose leg is recorded (wsUSD).
    /// @param other         The paired currency (e.g. USDC).
    /// @param fee           Pool LP fee of the designated pool.
    /// @param tickSpacing   Tick spacing of the designated pool.
    constructor(
        IPoolManager poolManager_,
        ISpectralEntropyOracle oracle_,
        Currency measured,
        Currency other,
        uint24 fee,
        int24 tickSpacing
    ) {
        if (Currency.unwrap(measured) == Currency.unwrap(other)) revert SameCurrency();
        poolManager = poolManager_;
        oracle = oracle_;
        measuredCurrency = measured;
        measuredIsCurrency0 = Currency.unwrap(measured) < Currency.unwrap(other);
        measuredUnit = 10 ** IERC20Metadata(Currency.unwrap(measured)).decimals();
        otherUnit = 10 ** IERC20Metadata(Currency.unwrap(other)).decimals();
        (Currency c0, Currency c1) = measuredIsCurrency0 ? (measured, other) : (other, measured);
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(address(this))});
        allowedPoolId = key.toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Hook permissions: beforeInitialize (pool allow-list) and afterSwap (feed).
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------- enabled hooks

    /// @inheritdoc IHooks
    /// @dev Only the allowed pool, and only at a starting price near par (see `priceWithinBand`).
    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(allowedPoolId)) revert PoolNotAllowed();
        if (!priceWithinBand(sqrtPriceX96)) revert PriceOutOfBand(sqrtPriceX96, parPriceX96());
        return IHooks.beforeInitialize.selector;
    }

    // ---------------------------------------------------------------------- price band (views)

    /// @notice Pool price, as raw units of currency1 per raw unit of currency0 in Q96, at which
    ///         one wsUSD trades at its redemption value (the paired asset at par with sUSD).
    function parPriceX96() public view returns (uint256) {
        // sUSD wei (18 decimals) redeemable for one whole wsUSD
        uint256 a = IERC4626(Currency.unwrap(measuredCurrency)).convertToAssets(measuredUnit);
        // one raw unit of wsUSD is worth a * otherUnit / (measuredUnit * 1e18) raw units of the pair
        if (measuredIsCurrency0) return Math.mulDiv(a * otherUnit, Q96, measuredUnit * 1e18);
        return Math.mulDiv(measuredUnit * 1e18, Q96, a * otherUnit);
    }

    /// @notice True if `sqrtPriceX96` is within INIT_PRICE_TOLERANCE_BPS of `parPriceX96()`.
    function priceWithinBand(uint160 sqrtPriceX96) public view returns (bool) {
        uint256 p = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        uint256 par = parPriceX96();
        uint256 tol = (par * INIT_PRICE_TOLERANCE_BPS) / 10_000;
        return p + tol >= par && p <= par + tol;
    }

    /// @inheritdoc IHooks
    /// @dev Records |delta| of the measured leg. An oracle failure with revert data is logged
    ///      and skipped; an out-of-gas failure (no revert data) reverts the swap.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        int128 d = Currency.unwrap(key.currency0) == Currency.unwrap(measuredCurrency)
            ? delta.amount0()
            : delta.amount1();
        // |d| fits in uint256 for every int128 (widened to int256 before negation).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = d < 0 ? uint256(-int256(d)) : uint256(int256(d));
        if (amount > 0) {
            try oracle.record(amount) {}
            catch (bytes memory reason) {
                if (reason.length == 0) revert OracleOutOfGas();
                emit OracleRecordFailed(reason);
            }
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------- disabled hooks

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}

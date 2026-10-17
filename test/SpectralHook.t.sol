// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Spectrum Protocol - SpectralHook on a real Uniswap v4 PoolManager
//
//  Section 8 of the suite, split out of SpectrumProtocol.t.sol in Phase 4 so that the rest of
//  the suite builds without v4-core's PoolManager: the mutation-testing profile skips this
//  file (audit/mutation.md). The tests are unchanged.
// =====================================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {SpectralToken} from "../src/SpectralToken.sol";
import {SpectralStabilizer} from "../src/SpectralStabilizer.sol";
import {AutonomousTreasury} from "../src/AutonomousTreasury.sol";
import {SpectralEntropyOracle} from "../src/SpectralEntropyOracle.sol";
import {SpectralHook} from "../src/SpectralHook.sol";
import {WrappedSUSD} from "../src/WrappedSUSD.sol";
import {SpectrumLens} from "../src/SpectrumLens.sol";
import {SpectralMath} from "../src/libraries/SpectralMath.sol";
import {ISpectralEntropyOracle} from "../src/interfaces/ISpectralEntropyOracle.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";
import {OracleGasMeter} from "./mocks/OracleGasMeter.sol";
import {RoundTripper} from "./mocks/RoundTripper.sol";
import {MathHarness, StabilizerHarness} from "./mocks/Harnesses.sol";
import {StabilizerHandler} from "./handlers/StabilizerHandler.sol";
import {SpectrumFixture} from "./utils/SpectrumFixture.sol";
import {ReferenceValues} from "./reference/ReferenceValues.sol";
import {SpectrumDeploy} from "../script/lib/SpectrumDeploy.sol";

// =====================================================================================
// 8. SpectralHook on a real Uniswap v4 PoolManager
// =====================================================================================

contract SpectralHookTest is Deployers {
    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

    MockUSDC internal usdc;
    MockVault internal vault;
    AutonomousTreasury internal treasury;
    SpectralToken internal token;
    SpectralEntropyOracle internal oracle;
    SpectralStabilizer internal stabilizer;
    WrappedSUSD internal wsusd;
    SpectrumLens internal lens;
    SpectralHook internal hook;
    Currency internal ws;
    Currency internal other;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.roll(1_000);
        deployFreshManagerAndRouters();

        // Monetary system with the real oracle.
        usdc = new MockUSDC();
        vault = new MockVault(usdc);
        address hookAt = address(FLAGS ^ (uint160(0x4444) << 144));
        address stabilizerAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        treasury = new AutonomousTreasury(IERC4626(address(vault)), 0, stabilizerAt);
        token = new SpectralToken(stabilizerAt);
        oracle = new SpectralEntropyOracle(hookAt, 1e18, 0.25e18, 1 hours, 1 hours);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        stabilizer = new SpectralStabilizer(
            token, treasury, oracle, address(this), address(0), 10_000_000e18, type(uint256).max, vaults
        );
        wsusd = new WrappedSUSD(token);
        lens = new SpectrumLens(stabilizer);

        // Liquidity: wrap minted sUSD into wsUSD; pair it with an 18-decimal test token.
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(stabilizer), type(uint256).max);
        stabilizer.mint(1_000_000e6, address(this), 0);
        token.approve(address(wsusd), type(uint256).max);
        wsusd.deposit(token.balanceOf(address(this)), address(this));
        wsusd.approve(address(swapRouter), type(uint256).max);
        wsusd.approve(address(modifyLiquidityRouter), type(uint256).max);
        ws = Currency.wrap(address(wsusd));
        other = deployMintAndApproveCurrency();

        hook = _deployHook(oracle, address(FLAGS ^ (uint160(0x4444) << 144)));
        key = _initPool(hook);
    }

    function _deployHook(ISpectralEntropyOracle o, address at) internal returns (SpectralHook) {
        deployCodeTo(
            "SpectralHook.sol:SpectralHook", abi.encode(manager, o, ws, other, uint24(3000), int24(60)), at
        );
        return SpectralHook(at);
    }

    function _initPool(SpectralHook h) internal returns (PoolKey memory k) {
        (Currency c0, Currency c1) =
            Currency.unwrap(ws) < Currency.unwrap(other) ? (ws, other) : (other, ws);
        k = PoolKey(c0, c1, 3000, 60, IHooks(address(h)));
        manager.initialize(k, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: 0}), ZERO_BYTES
        );
    }

    /// Exact-input sale of `amount` wsUSD: the measured leg equals `amount` exactly.
    function _sellWs(PoolKey memory k, uint256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = Currency.unwrap(k.currency0) == Currency.unwrap(ws);
        return swap(k, zeroForOne, -int256(amount), ZERO_BYTES);
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
    }

    // ------------------------------------------------------------------ deployment checks

    function test_permissionsAndAddressFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.afterSwap);
        assertFalse(p.beforeSwap || p.afterInitialize || p.beforeAddLiquidity || p.afterSwapReturnDelta);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertEq(Currency.unwrap(hook.measuredCurrency()), address(wsusd));
    }

    function test_constructorRejectsBadSetups() public {
        vm.expectRevert(SpectralHook.SameCurrency.selector);
        new SpectralHook(manager, oracle, ws, ws, 3000, 60);
        vm.expectRevert(); // ordinary CREATE address lacks the flag bits
        new SpectralHook(manager, oracle, ws, other, 3000, 60);
    }

    function test_onlyDesignatedPoolCanUseHook() public {
        PoolKey memory bad = key;
        bad.fee = 500;
        bad.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(bad, SQRT_PRICE_1_1);
    }

    /// A2: the one allowed pool can only start near wsUSD's redemption value, in either token
    /// order, so nobody can front-run the deployment with an off-peg initialisation.
    function test_initialisationPriceMustBeNearPar() public {
        address[2] memory places = [address(0x10000), address(0xFFFfFFfFfFFffFFfFFFffffFfFfFffFFfFFFFF00)];
        for (uint256 i; i < 2; ++i) {
            deployCodeTo("MockUSDC.sol:MockUSDC", "", places[i]);
            Currency usd = Currency.wrap(places[i]);
            address at = address(FLAGS ^ (uint160(0x6000 + i) << 144));
            deployCodeTo("SpectralHook.sol:SpectralHook", abi.encode(manager, oracle, ws, usd, uint24(100), int24(1)), at);
            (Currency c0, Currency c1) = Currency.unwrap(ws) < Currency.unwrap(usd) ? (ws, usd) : (usd, ws);
            PoolKey memory k = PoolKey(c0, c1, 100, 1, IHooks(at));
            uint160 par = SpectrumDeploy.parSqrtPriceX96(k);
            assertTrue(SpectralHook(at).priceWithinBand(par), "par is inside the band");
            assertFalse(SpectralHook(at).priceWithinBand(uint160((uint256(par) * 1003) / 1000)), "0.6% is outside");
            vm.expectRevert(); // a quarter of par: far outside the 50 bp band
            manager.initialize(k, par / 2);
            vm.expectRevert(); // 1% above par
            manager.initialize(k, uint160((uint256(par) * 1005) / 1000));
            manager.initialize(k, uint160((uint256(par) * 10_012) / 10_000)); // +0.24%: allowed
        }
    }

    function test_onlyPoolManagerCanCall() public {
        vm.expectRevert(SpectralHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.expectRevert(SpectralHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, sp, toBalanceDelta(-1e18, 1e18), ZERO_BYTES);
        vm.expectRevert(SpectralHook.HookNotImplemented.selector);
        hook.beforeSwap(address(this), key, sp, ZERO_BYTES);
    }

    /// A swapper cannot opt out of being recorded by starving the oracle call of gas.
    function test_starvingTheOracleRevertsTheSwap() public {
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0});
        vm.prank(address(manager));
        vm.expectRevert(SpectralHook.OracleOutOfGas.selector);
        hook.afterSwap{gas: 30_000}(address(this), key, sp, toBalanceDelta(-100e18, 99e18), ZERO_BYTES);

        vm.prank(address(manager));
        (bytes4 sel,) =
            hook.afterSwap{gas: 300_000}(address(this), key, sp, toBalanceDelta(-100e18, 99e18), ZERO_BYTES);
        assertEq(sel, IHooks.afterSwap.selector);
        // The measured leg is whichever currency wsUSD happens to be in this deployment.
        uint256 measured = Currency.unwrap(key.currency0) == address(wsusd) ? 100e18 : 99e18;
        assertEq(oracle.window()[7], measured);
    }

    // ------------------------------------------------------------------ data flow

    function test_swapsFeedOneSlotPerBlock() public {
        uint256[9] memory amounts = [uint256(100e18), 250e18, 75e18, 300e18, 120e18, 90e18, 60e18, 410e18, 33e18];
        for (uint256 i; i < 9; ++i) {
            _nextBlock();
            BalanceDelta d = _sellWs(key, amounts[i]);
            int128 leg = Currency.unwrap(key.currency0) == address(wsusd) ? d.amount0() : d.amount1();
            assertEq(uint256(int256(-leg)), amounts[i], "measured leg = exact input");
        }
        uint256[8] memory w = oracle.window();
        for (uint256 i; i < 8; ++i) {
            assertEq(w[i], amounts[i + 1], "window = last 8 blocks");
        }
        assertTrue(oracle.rawEma() != 0.5e18, "a closed window was folded");
    }

    function test_sameBlockSwapsAggregate() public {
        _nextBlock();
        _sellWs(key, 100e18);
        _sellWs(key, 200e18);
        assertEq(oracle.filled(), 1);
        assertEq(oracle.window()[7], 300e18);
    }

    function test_calmFlowThenWhale_endToEndFees() public {
        for (uint256 i; i < 9; ++i) {
            _nextBlock();
            _sellWs(key, 100e18);
        }
        assertEq(oracle.instantEntropy(), 0, "homogeneous flow");
        assertLt(oracle.smoothedEntropy(), 0.5e18, "the EMA has started to fall");
        for (uint256 i; i < 7; ++i) {
            _nextBlock();
            _sellWs(key, 100e18);
        }
        (, uint256 calmFee) = lens.quoteMint(1_000e6);
        _nextBlock();
        _sellWs(key, 5_000e18); // whale
        assertGt(oracle.instantEntropy(), 0.99e18, "concentrated flow");
        uint256 before = oracle.rawEma();
        // A6: the fold weight grows with time, so the whale window only moves the smoothed
        // signal materially once the pool has been quiet for a while (50 minutes here, which
        // is still inside the 1-hour staleness horizon).
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        _nextBlock();
        _sellWs(key, 100e18); // closes the whale window
        // One fold moves the EMA by at most emaAlphaMax (0.25) of the gap, whatever the wait.
        assertGt(oracle.rawEma(), before + 0.1e18);
        assertLt(oracle.rawEma(), before + 0.25e18, "one fold is capped at alphaMax");
        (, uint256 whaleFee) = lens.quoteMint(1_000e6);
        assertGt(whaleFee, calmFee, "minting gets more expensive after spiky flow");
    }

    function test_oracleFailureNeverBricksSwaps() public {
        MockOracle broken = new MockOracle();
        broken.setRevert(true);
        SpectralHook h2 = _deployHook(broken, address(FLAGS ^ (uint160(0x5555) << 144)));
        PoolKey memory k2 = _initPool(h2);
        _nextBlock();
        vm.expectEmit(false, false, false, false, address(h2));
        emit SpectralHook.OracleRecordFailed("");
        _sellWs(k2, 100e18);
    }
}

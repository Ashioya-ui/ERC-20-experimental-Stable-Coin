// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Spectrum Protocol - full Foundry test suite
//
//  1. SpectralMathTest          FWHT correctness, lnWad accuracy, entropy bounds/invariances
//  2. SpectralEntropyOracleTest per-block window, dust filter, EMA, warm-up, staleness, gas
//  3. SpectralTokenTest         rebasing accounting, EIP-2612, EIP-3009, ERC-1271
//  4. AutonomousTreasuryTest    adapter accounting around an ERC-4626 vault
//  5. WrappedSUSDTest           non-rebasing wrapper used by AMM pools
//  6. SpectralStabilizerTest    fees, caps, rebases, buffer, loss absorption, pause, MEV
//  7. ChurnBudgetTest           exact C_DIAM churn-budget arithmetic
//  8. SpectralHookTest          Uniswap v4 integration (real PoolManager)
//  9. SpectrumInvariantTest     100% reserve floor and accounting invariants
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
// 1. SpectralMath
// =====================================================================================

contract SpectralMathTest is Test {
    MathHarness internal m;

    /// lnWad: max absolute error against the 80-digit reference (wei), overall and for
    /// x < 2^60 (the range of every probability in an entropy computation).
    uint256 internal constant LN_TOL = 3;
    uint256 internal constant LN_TOL_SMALL = 1;
    /// Entropy: max absolute error allowed against the 80-digit reference (wei).
    uint256 internal constant H_TOL = 1_000;

    function setUp() public {
        m = new MathHarness();
    }

    // ------------------------------------------------------------------ helpers

    function _sign(uint256 k, uint256 j) internal pure returns (int256) {
        uint256 v = k & j;
        uint256 parity;
        while (v != 0) {
            parity ^= v & 1;
            v >>= 1;
        }
        return parity == 1 ? int256(-1) : int256(1);
    }

    function _naive(int256[8] memory x) internal pure returns (int256[8] memory y) {
        for (uint256 k; k < 8; ++k) {
            for (uint256 j; j < 8; ++j) {
                y[k] += _sign(k, j) * x[j];
            }
        }
    }

    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        return a >= b ? uint256(a - b) : uint256(b - a);
    }

    function _absDiffU(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    function _spikeWindow(uint256 base, uint256 slot, uint256 mult) internal pure returns (uint256[8] memory v) {
        for (uint256 i; i < 8; ++i) {
            v[i] = base;
        }
        v[slot % 8] = base * mult;
    }

    // ------------------------------------------------------------------ FWHT

    function test_fwht8_knownVectors() public view {
        int256[8] memory y = m.fwht8([int256(1), 2, 3, 4, 5, 6, 7, 8]);
        int256[8] memory e = [int256(36), -4, -8, 0, -16, 0, 0, 0];
        for (uint256 i; i < 8; ++i) {
            assertEq(y[i], e[i], "H8 [1..8]");
        }
        y = m.fwht8([int256(3), -1, 4, -1, 5, -9, 2, -6]);
        e = [int256(-3), 31, -1, 5, 13, -13, -1, -7];
        for (uint256 i; i < 8; ++i) {
            assertEq(y[i], e[i], "H8 mixed signs");
        }
        // Unit impulse -> all-ones row; constant -> energy in sequency 0 only.
        y = m.fwht8([int256(1), 0, 0, 0, 0, 0, 0, 0]);
        for (uint256 i; i < 8; ++i) {
            assertEq(y[i], 1, "impulse");
        }
        y = m.fwht8([int256(5), 5, 5, 5, 5, 5, 5, 5]);
        assertEq(y[0], 40);
        for (uint256 i = 1; i < 8; ++i) {
            assertEq(y[i], 0, "constant");
        }
    }

    function testFuzz_fwht8_matchesNaiveHadamard(int128[8] memory raw) public view {
        int256[8] memory x;
        for (uint256 i; i < 8; ++i) {
            x[i] = raw[i];
        }
        int256[8] memory fast = m.fwht8(x);
        int256[8] memory slow = _naive(x);
        for (uint256 k; k < 8; ++k) {
            assertEq(fast[k], slow[k], "FWHT != H8 * x");
        }
    }

    function testFuzz_fwht8_involution(int128[8] memory raw) public view {
        int256[8] memory x;
        for (uint256 i; i < 8; ++i) {
            x[i] = raw[i];
        }
        int256[8] memory twice = m.fwht8(m.fwht8(x));
        for (uint256 i; i < 8; ++i) {
            assertEq(twice[i], 8 * x[i], "H8 * H8 = 8 I");
        }
    }

    function testFuzz_fwht8_parseval(int96[8] memory raw) public view {
        int256[8] memory x;
        uint256 e1;
        for (uint256 i; i < 8; ++i) {
            x[i] = raw[i];
            e1 += uint256(x[i] * x[i]);
        }
        int256[8] memory y = m.fwht8(x);
        uint256 e2;
        for (uint256 k; k < 8; ++k) {
            e2 += uint256(y[k] * y[k]);
        }
        assertEq(e2, 8 * e1, "sum X^2 = 8 sum x^2");
    }

    // ------------------------------------------------------------------ lnWad

    function test_lnWad_referenceTable() public {
        uint256 maxErr;
        for (uint256 i; i < ReferenceValues.LN_CASES; ++i) {
            (uint256 x, int256 y) = ReferenceValues.lnCase(i);
            uint256 err = _absDiff(m.lnWad(x), y);
            if (err > maxErr) maxErr = err;
            assertLe(err, x < 2 ** 60 ? LN_TOL_SMALL : LN_TOL, string.concat("lnWad case ", vm.toString(i)));
        }
        emit log_named_uint("lnWad max |error| over reference table (wei)", maxErr);
    }

    function test_lnWad_exactPoints() public view {
        assertEq(m.lnWad(1e18), 0, "ln 1");
        assertEq(m.lnWad(0.125e18), -2_079_441_541_679_835_928, "ln 1/8");
        assertEq(m.lnWad(2e18), 693_147_180_559_945_309, "ln 2");
    }

    function test_lnWad_zeroReverts() public {
        vm.expectRevert(SpectralMath.LnOfZero.selector);
        m.lnWad(0);
    }

    function testFuzz_lnWad_productRule(uint256 a, uint256 b) public view {
        a = bound(a, 1e18, 1e30);
        b = bound(b, 1e18, 1e30);
        uint256 c = (a * b) / 1e18; // relative truncation < 1e-18
        uint256 err = _absDiff(m.lnWad(c), m.lnWad(a) + m.lnWad(b));
        assertLe(err, 3 * LN_TOL + 2, "ln(ab) = ln a + ln b");
    }

    function testFuzz_lnWad_strictlyMonotoneOnSeparatedPoints(uint256 x, uint256 bumpPpt) public view {
        x = bound(x, 1, type(uint256).max / 4);
        bumpPpt = bound(bumpPpt, 1, 1e12); // relative bump >= 1e-12
        uint256 y = x + (x / 1e12) * bumpPpt + bumpPpt;
        assertGt(m.lnWad(y), m.lnWad(x), "monotone");
    }

    function testFuzz_lnWad_sign(uint256 x) public view {
        x = bound(x, 1, type(uint256).max);
        int256 r = m.lnWad(x);
        if (x < 1e18) assertLe(r, 0);
        if (x > 1e18) assertGe(r, 0);
    }

    // ------------------------------------------------------------------ entropy

    function test_entropy_referenceTable() public {
        uint256 maxErr;
        for (uint256 i; i < ReferenceValues.ENTROPY_CASES; ++i) {
            (uint256[8] memory v, uint256 h) = ReferenceValues.entropyCase(i);
            uint256 err = _absDiffU(m.spectralEntropy8(v), h);
            if (err > maxErr) maxErr = err;
            assertLe(err, H_TOL, string.concat("entropy case ", vm.toString(i)));
        }
        emit log_named_uint("entropy max |error| over reference table (wei)", maxErr);
    }

    function test_entropy_semantics() public view {
        // Homogeneous flow: all energy in sequency 0.
        assertEq(m.spectralEntropy8([uint256(7), 7, 7, 7, 7, 7, 7, 7]), 0, "constant window -> 0");
        // A single isolated spike has a flat Walsh spectrum.
        assertEq(m.spectralEntropy8([uint256(0), 0, 0, 0, 0, 0, 0, 5]), 1e18, "spike -> 1");
        // No activity at all.
        assertEq(m.spectralEntropy8([uint256(0), 0, 0, 0, 0, 0, 0, 0]), 0, "zero window");
        // Pure Walsh patterns: 2 and 4 equal spectral lines.
        assertApproxEqAbs(m.spectralEntropy8([uint256(1), 0, 1, 0, 1, 0, 1, 0]), uint256(1e18) / 3, H_TOL);
        assertApproxEqAbs(m.spectralEntropy8([uint256(1), 0, 0, 0, 1, 0, 0, 0]), uint256(2e18) / 3, H_TOL);
    }

    function testFuzz_entropy_boundedInUnitInterval(uint128[8] memory raw) public view {
        uint256[8] memory v;
        for (uint256 i; i < 8; ++i) {
            v[i] = raw[i];
        }
        assertLe(m.spectralEntropy8(v), 1e18);
    }

    function testFuzz_entropy_boundedForFull256BitInputs(uint256[8] memory v) public view {
        assertLe(m.spectralEntropy8(v), 1e18);
    }

    function testFuzz_entropy_scaleInvariant(uint128[8] memory raw, uint64 c) public view {
        c = uint64(bound(c, 1, type(uint64).max));
        uint256[8] memory v;
        uint256[8] memory w;
        for (uint256 i; i < 8; ++i) {
            v[i] = raw[i];
            w[i] = uint256(raw[i]) * c;
        }
        assertEq(m.spectralEntropy8(v), m.spectralEntropy8(w), "H(c v) = H(v)");
    }

    /// Dyadic (XOR) shifts only flip signs of Walsh coefficients, so H is exactly invariant.
    /// Time reversal is the shift by 7.
    function testFuzz_entropy_dyadicShiftInvariant(uint128[8] memory raw, uint8 s) public view {
        s = uint8(bound(s, 0, 7));
        uint256[8] memory v;
        uint256[8] memory w;
        for (uint256 i; i < 8; ++i) {
            v[i] = raw[i];
        }
        for (uint256 i; i < 8; ++i) {
            w[i] = v[i ^ s];
        }
        assertEq(m.spectralEntropy8(v), m.spectralEntropy8(w), "H invariant under i -> i xor s");
    }

    /// A bigger whale on top of a calm flow can only raise H.
    function testFuzz_entropy_biggerWhaleRaisesEntropy(uint64 base, uint8 slot, uint16 m1, uint16 m2) public view {
        base = uint64(bound(base, 1e6, type(uint64).max));
        uint256 lo = bound(m1, 1, 5_000);
        uint256 hi = bound(m2, lo, 10_000);
        uint256 hLo = m.spectralEntropy8(_spikeWindow(base, slot, lo));
        uint256 hHi = m.spectralEntropy8(_spikeWindow(base, slot, hi));
        assertLe(hLo, hHi + 10, "monotone in whale size");
        if (hi >= 2) assertGt(hHi, 0.1e18);
    }

    function test_entropy_gas() public {
        (uint256 g,) = m.entropyGas([uint256(13e18), 2e18, 77e18, 4e18, 51e18, 6e18, 1e18, 99e18]);
        emit log_named_uint("spectralEntropy8 gas", g);
        (uint256 gl,) = m.lnGas(0.125e18);
        emit log_named_uint("lnWad gas", gl);
        emit log_named_uint("fwht8 gas", m.fwhtGas([int256(1), 2, 3, 4, 5, 6, 7, 8]));
        assertLt(g, 20_000, "B4 target");
    }
}

// =====================================================================================
// 2. SpectralEntropyOracle
// =====================================================================================

contract SpectralEntropyOracleTest is Test {
    SpectralEntropyOracle internal oracle;
    address internal owner = makeAddr("owner");
    address internal hook = makeAddr("hook");

    uint256 internal constant DUST = 10e18;
    uint256 internal constant ALPHA = 0.25e18;
    uint256 internal constant TAU = 1 hours;
    uint256 internal constant STALE = 1 hours;
    uint256 internal constant T0 = 1_700_000_000;

    function setUp() public {
        vm.roll(100);
        vm.warp(T0);
        oracle = new SpectralEntropyOracle(hook, DUST, ALPHA, TAU, STALE);
    }

    function _recordAt(uint256 blockNumber, uint256 amount) internal {
        // Positive deltas: the per-block net is the sum (see the net-flow tests for signs).
        vm.roll(blockNumber);
        vm.warp(T0 + 2 * (blockNumber - 100)); // 2-second blocks
        vm.prank(hook);
        oracle.record(int256(amount));
    }

    function test_constructor_validatesParameters() public {
        vm.expectRevert(SpectralEntropyOracle.InvalidParameter.selector);
        new SpectralEntropyOracle(hook, DUST, 0, TAU, STALE);
        vm.expectRevert(SpectralEntropyOracle.InvalidParameter.selector);
        new SpectralEntropyOracle(hook, DUST, 1e18 + 1, TAU, STALE);
        vm.expectRevert(SpectralEntropyOracle.InvalidParameter.selector);
        new SpectralEntropyOracle(hook, DUST, ALPHA, TAU, 0);
    }

    /// A3: the writer is fixed at construction. There is no owner and no setter, so neither a
    /// deployer key nor anyone else can redirect the data, during or after deployment.
    function test_hookFixedAtConstruction() public {
        vm.expectRevert(SpectralEntropyOracle.ZeroAddress.selector);
        new SpectralEntropyOracle(address(0), DUST, ALPHA, TAU, STALE);
        assertEq(oracle.hook(), hook);
        (bool hasOwner,) = address(oracle).call(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner, "no owner");
        (bool canSet,) = address(oracle).call(abi.encodeWithSignature("setHook(address)", owner));
        assertFalse(canSet, "no setter");
    }

    function test_record_onlyHook() public {
        vm.expectRevert(SpectralEntropyOracle.NotHook.selector);
        oracle.record(int256(100e18));
        vm.prank(owner); // nobody else has write access
        vm.expectRevert(SpectralEntropyOracle.NotHook.selector);
        oracle.record(int256(100e18));
    }

    function test_record_ignoresDust() public {
        vm.expectEmit(address(oracle));
        emit SpectralEntropyOracle.DustIgnored(int256(DUST) - 1);
        vm.prank(hook);
        oracle.record(int256(DUST) - 1);
        assertEq(oracle.filled(), 0);
    }

    function test_record_aggregatesPerBlock() public {
        _recordAt(101, 10e18);
        _recordAt(101, 20e18);
        _recordAt(101, 30e18);
        assertEq(oracle.filled(), 1);
        assertEq(oracle.window()[7], 60e18, "one slot per block");
        _recordAt(102, 40e18);
        assertEq(oracle.filled(), 2);
        uint256[8] memory w = oracle.window();
        assertEq(w[6], 60e18);
        assertEq(w[7], 40e18);
    }

    function test_window_ringBufferIsChronological() public {
        for (uint256 b = 101; b <= 110; ++b) {
            _recordAt(b, (b - 100) * 1e19);
        }
        uint256[8] memory w = oracle.window();
        for (uint256 i; i < 8; ++i) {
            assertEq(w[i], (i + 3) * 1e19, "oldest first, last 8 blocks");
        }
        assertEq(oracle.filled(), 8);
    }

    function test_warmup_isNeutral() public {
        for (uint256 b = 101; b <= 107; ++b) {
            _recordAt(b, 50e18);
        }
        assertEq(oracle.smoothedEntropy(), 0.5e18);
        assertEq(oracle.instantEntropy(), 0.5e18);
        _recordAt(108, 50e18); // window full, nothing folded yet
        assertEq(oracle.instantEntropy(), 0, "8 equal blocks");
        assertEq(oracle.smoothedEntropy(), 0.5e18, "EMA starts neutral");
    }

    /// A6: a fold carries weight min(alphaMax, dt/(dt + tau)), so folds packed into
    /// consecutive 2-second blocks barely move the EMA.
    function test_ema_foldWeightGrowsWithTime() public {
        for (uint256 b = 101; b <= 108; ++b) {
            _recordAt(b, 50e18);
        }
        uint256 dt = 16; // eight 2-second blocks since construction
        assertEq(oracle.foldWeight(), (dt * 1e18) / (dt + TAU));
        uint256 wAtFold = ((dt + 2) * 1e18) / (dt + 2 + TAU); // the fold lands one block later
        uint256 expected = 0.5e18 - ((0.5e18 * wAtFold) / 1e18); // towards h = 0
        vm.expectEmit(address(oracle));
        emit SpectralEntropyOracle.WindowClosed(108, 0, wAtFold, expected);
        _recordAt(109, 50e18);
        assertEq(oracle.rawEma(), expected);
        assertGt(oracle.rawEma(), 0.49e18, "one packed fold moves H by well under 1%");

        // After a quiet hour the next fold carries the full alphaMax.
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertEq(oracle.foldWeight(), ALPHA);
    }

    /// A6: the same eight calm blocks move H much further when they are spread over hours than
    /// when they are packed into consecutive blocks. Attacking the signal costs wall time.
    function test_ema_packedFoldsAreWeakerThanSpacedFolds() public {
        uint256 packed;
        {
            for (uint256 b = 101; b <= 140; ++b) {
                _recordAt(b, 50e18); // 2-second blocks, 40 of them
            }
            packed = oracle.rawEma();
        }
        SpectralEntropyOracle spaced = new SpectralEntropyOracle(hook, DUST, ALPHA, TAU, 10 days);
        uint256 b2 = 1_000;
        for (uint256 i; i < 40; ++i) {
            vm.roll(++b2);
            vm.warp(vm.getBlockTimestamp() + 20 minutes);
            vm.prank(hook);
            spaced.record(int256(50e18));
        }
        assertGt(packed, 0.4e18, "40 packed folds barely move H");
        assertLt(spaced.rawEma(), 0.05e18, "the same flow spread out drives H to 0");
    }

    /// A6: each slot holds the absolute *net* flow of its block, so a round trip inside one
    /// block records almost nothing however large its legs are.
    function test_netFlowPerBlockCancelsRoundTrips() public {
        vm.roll(101);
        vm.warp(T0 + 2);
        vm.startPrank(hook);
        oracle.record(int256(10_000e18)); // buy
        oracle.record(-int256(9_990e18)); // sell back in the same block
        vm.stopPrank();
        assertEq(oracle.currentNet(), int256(10e18));
        assertEq(oracle.window()[7], 10e18, "net, not gross");

        // Across blocks the flows stand on their own.
        _recordAt(102, 10_000e18);
        assertEq(oracle.window()[7], 10_000e18);
    }

    function test_staleness_returnsNeutral() public {
        for (uint256 b = 101; b <= 120; ++b) {
            _recordAt(b, 50e18);
        }
        assertFalse(oracle.isStale());
        vm.warp(vm.getBlockTimestamp() + STALE + 1);
        assertTrue(oracle.isStale());
        assertEq(oracle.smoothedEntropy(), 0.5e18);
    }

    function test_record_saturatesHugeAmounts() public {
        uint256 huge = uint256(type(uint128).max) + 1e18;
        _recordAt(101, huge);
        assertEq(oracle.window()[7], type(uint128).max, "clamped into the slot");
        _recordAt(102, huge);
        assertEq(oracle.window()[7], type(uint128).max);
    }

    /// Worst case for the hook's oracle call: a window close (full entropy computation)
    /// with every storage slot cold. Documents the gas a swap must budget.
    /// A8: the worst case for the hook's oracle call is a window close (a full entropy
    /// computation) with every storage slot cold. Measured from inside a contract call, as the
    /// hook pays it, and with a budget that holds in both normal and `--isolate` runs; the test
    /// used to fail under `--isolate`, which is what `--gas-report` turns on. The two modes
    /// still report different numbers, because isolation re-frames each top-level call as its
    /// own transaction; both are logged and recorded in REPORT_PHASE4.md.
    function test_record_worstCaseGasFitsHookBudget() public {
        OracleGasMeter meter = OracleGasMeter(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        SpectralEntropyOracle o = new SpectralEntropyOracle(address(meter), DUST, ALPHA, TAU, STALE);
        new OracleGasMeter(o);

        for (uint256 b = 101; b <= 108; ++b) {
            vm.roll(b);
            vm.warp(T0 + 2 * (b - 100));
            meter.record(int256((b * 37 + 11) * 1e18));
        }
        vm.roll(109);
        vm.warp(T0 + 20);
        vm.cool(address(o));
        meter.record(int256(123e18));
        uint256 used = meter.lastGas();
        emit log_named_uint("record() closing a window, cold storage (gas)", used);
        assertLt(used, 56_000, "oracle write stays cheap");
    }

    function testFuzz_signalsStayInUnitInterval(uint96[16] memory amounts, uint8[16] memory gaps) public {
        uint256 b = 100;
        for (uint256 i; i < 16; ++i) {
            b += gaps[i] % 3; // 0 = same block
            if (b == 100) b = 101;
            _recordAt(b, uint256(amounts[i]) + DUST);
            assertLe(oracle.smoothedEntropy(), 1e18);
            assertLe(oracle.instantEntropy(), 1e18);
        }
    }
}

// =====================================================================================
// 3. SpectralToken
// =====================================================================================

contract SpectralTokenTest is Test {
    SpectralToken internal token;
    MockERC1271Wallet internal wallet;

    uint256 internal constant ALICE_PK = 0xA11CE;
    address internal alice;
    address internal bob = makeAddr("bob");
    address internal relayer = makeAddr("relayer");

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        vm.warp(1_700_000_000);
        alice = vm.addr(ALICE_PK);
        token = new SpectralToken(address(this)); // this test acts as the stabilizer
        wallet = new MockERC1271Wallet(alice);
        token.mint(alice, 1_000e18);
        token.mint(address(wallet), 1_000e18);
    }

    // ------------------------------------------------------------------ helpers

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _authDigest(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes32) {
        return _digest(keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce)));
    }

    // ------------------------------------------------------------------ basics

    function test_metadataAndDomain() public view {
        assertEq(token.name(), "Spectrum Agentic USD");
        assertEq(token.symbol(), "sUSD");
        assertEq(token.decimals(), 18);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Spectrum Agentic USD")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    /// A3: the stabilizer is fixed at construction; there is no setter to race.
    function test_stabilizerFixedAtConstruction() public {
        vm.expectRevert(SpectralToken.ZeroAddress.selector);
        new SpectralToken(address(0));
        SpectralToken t = new SpectralToken(bob);
        assertEq(t.stabilizer(), bob);
        (bool canSet,) = address(t).call(abi.encodeWithSignature("setStabilizer(address)", address(this)));
        assertFalse(canSet, "no setter");
        assertEq(t.stabilizer(), bob);
    }

    function test_onlyStabilizerMintsBurnsRebases() public {
        vm.startPrank(bob);
        vm.expectRevert(SpectralToken.NotStabilizer.selector);
        token.mint(bob, 1e18);
        vm.expectRevert(SpectralToken.NotStabilizer.selector);
        token.burn(alice, 1e18);
        vm.expectRevert(SpectralToken.NotStabilizer.selector);
        token.setIndex(2e18);
        vm.stopPrank();
        vm.expectRevert(SpectralToken.InvalidIndex.selector);
        token.setIndex(0);
    }

    function test_rebaseMovesEveryBalance() public {
        token.setIndex(1.5e18);
        assertEq(token.balanceOf(alice), 1_500e18);
        assertEq(token.balanceOf(address(wallet)), 1_500e18);
        assertEq(token.totalSupply(), 3_000e18);
        assertEq(token.sharesOf(alice), 1_000e18, "shares unchanged");
        token.setIndex(0.9e18);
        assertEq(token.balanceOf(alice), 900e18);
    }

    function test_mintAndBurnRoundInReserveFavour() public {
        token.setIndex(3e18);
        uint256 s0 = token.totalSupply();
        token.mint(bob, 10); // floor(10 / 3) = 3 shares
        assertEq(token.sharesOf(bob), 3);
        assertLe(token.totalSupply() - s0, 10, "supply grows by <= amount");
        uint256 s1 = token.totalSupply();
        token.burn(bob, 1); // ceil(1 / 3) = 1 share
        assertEq(token.sharesOf(bob), 2);
        assertGe(s1 - token.totalSupply(), 1, "supply shrinks by >= amount");
        vm.expectRevert(SpectralToken.ZeroShares.selector);
        token.mint(bob, 2); // worth 0 shares
    }

    function testFuzz_transferNeverShortchangesRecipient(uint256 idx, uint256 amount) public {
        idx = bound(idx, 0.5e18, 5e18);
        token.setIndex(idx);
        amount = bound(amount, 0, token.balanceOf(alice));
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        uint256 shares = token.totalShares();
        vm.prank(alice);
        token.transfer(bob, amount);
        assertGe(token.balanceOf(bob) - bobBefore, amount, "recipient gets >= amount");
        assertGe(aliceBefore - token.balanceOf(alice), amount, "sender pays >= amount");
        assertEq(token.totalShares(), shares, "shares conserved");
        assertLe(
            token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(address(wallet)),
            token.totalSupply(),
            "sum of balances <= supply"
        );
    }

    function test_transferEntireBalanceAfterRebase() public {
        token.setIndex(1.337_133_713_371_337e18);
        uint256 bal = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, bal);
        assertEq(token.sharesOf(alice), 0);
        assertEq(token.balanceOf(bob), bal);
    }

    function test_transferRevertsAboveBalance() public {
        vm.prank(alice);
        vm.expectRevert(SpectralToken.InsufficientBalance.selector);
        token.transfer(bob, 1_000e18 + 1);
    }

    function test_transferFromAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100e18);
        vm.prank(bob);
        token.transferFrom(alice, bob, 60e18);
        assertEq(token.allowance(alice, bob), 40e18);
        vm.prank(bob);
        vm.expectRevert(SpectralToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 41e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 100e18);
        assertEq(token.allowance(alice, bob), type(uint256).max, "infinite allowance kept");
    }

    // ------------------------------------------------------------------ EIP-2612

    function test_permit_eoa() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = _digest(keccak256(abi.encode(PERMIT_TYPEHASH, alice, bob, 500e18, 0, deadline)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, d);
        token.permit(alice, bob, 500e18, deadline, v, r, s);
        assertEq(token.allowance(alice, bob), 500e18);
        assertEq(token.nonces(alice), 1);
        vm.expectRevert(SpectralToken.InvalidSignature.selector); // nonce moved on
        token.permit(alice, bob, 500e18, deadline, v, r, s);
    }

    function test_permit_rejectsExpiredAndForged() public {
        uint256 deadline = block.timestamp - 1;
        bytes32 d = _digest(keccak256(abi.encode(PERMIT_TYPEHASH, alice, bob, 1e18, 0, deadline)));
        bytes memory sig = _sig(ALICE_PK, d);
        vm.expectRevert(SpectralToken.PermitExpired.selector);
        token.permit(alice, bob, 1e18, deadline, sig);

        deadline = block.timestamp + 1;
        d = _digest(keccak256(abi.encode(PERMIT_TYPEHASH, alice, bob, 1e18, 0, deadline)));
        vm.expectRevert(SpectralToken.InvalidSignature.selector);
        token.permit(alice, bob, 1e18, deadline, _sig(0xB0B, d)); // wrong key
        vm.expectRevert(SpectralToken.InvalidSignature.selector);
        token.permit(alice, bob, 2e18, deadline, _sig(ALICE_PK, d)); // tampered value
    }

    function test_permit_erc1271SmartAccount() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = _digest(keccak256(abi.encode(PERMIT_TYPEHASH, address(wallet), bob, 7e18, 0, deadline)));
        token.permit(address(wallet), bob, 7e18, deadline, _sig(ALICE_PK, d));
        assertEq(token.allowance(address(wallet), bob), 7e18);
        // A signature by any other key is rejected by the wallet.
        d = _digest(keccak256(abi.encode(PERMIT_TYPEHASH, address(wallet), bob, 7e18, 1, deadline)));
        vm.expectRevert(SpectralToken.InvalidSignature.selector);
        token.permit(address(wallet), bob, 7e18, deadline, _sig(0xB0B, d));
    }

    // ------------------------------------------------------------------ EIP-3009 (x402 "exact")

    function test_3009_transferWithAuthorization_relayed() public {
        bytes32 nonce = keccak256("x402-payment-1");
        uint256 va = block.timestamp - 1;
        uint256 vb = block.timestamp + 5 minutes;
        bytes32 d =
            _authDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), alice, bob, 0.005e18, va, vb, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, d);

        vm.expectEmit(address(token));
        emit SpectralToken.AuthorizationUsed(alice, nonce);
        vm.prank(relayer); // the facilitator pays gas
        token.transferWithAuthorization(alice, bob, 0.005e18, va, vb, nonce, v, r, s);

        assertEq(token.balanceOf(bob), 0.005e18);
        assertTrue(token.authorizationState(alice, nonce));
        vm.prank(relayer);
        vm.expectRevert(SpectralToken.AuthorizationAlreadyUsed.selector);
        token.transferWithAuthorization(alice, bob, 0.005e18, va, vb, nonce, v, r, s);
    }

    function test_3009_validityWindow() public {
        bytes32 nonce = keccak256("n");
        bytes32 th = token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH();
        uint256 t = block.timestamp;
        bytes memory early = _sig(ALICE_PK, _authDigest(th, alice, bob, 1e18, t, t + 60, nonce));
        vm.expectRevert(SpectralToken.AuthorizationNotYetValid.selector);
        token.transferWithAuthorization(alice, bob, 1e18, t, t + 60, nonce, early);
        bytes memory late = _sig(ALICE_PK, _authDigest(th, alice, bob, 1e18, 0, t, nonce));
        vm.expectRevert(SpectralToken.AuthorizationExpired.selector);
        token.transferWithAuthorization(alice, bob, 1e18, 0, t, nonce, late);
    }

    function test_3009_rejectsForgedOrTampered() public {
        bytes32 nonce = keccak256("n");
        bytes32 th = token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH();
        uint256 vb = block.timestamp + 60;
        bytes32 d = _authDigest(th, alice, bob, 1e18, 0, vb, nonce);
        vm.expectRevert(SpectralToken.InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, 1e18, 0, vb, nonce, _sig(0xB0B, d));
        vm.expectRevert(SpectralToken.InvalidSignature.selector); // redirected payee
        token.transferWithAuthorization(alice, relayer, 1e18, 0, vb, nonce, _sig(ALICE_PK, d));
        vm.expectRevert(SpectralToken.InvalidSignature.selector); // raised amount
        token.transferWithAuthorization(alice, bob, 2e18, 0, vb, nonce, _sig(ALICE_PK, d));
    }

    function test_3009_receiveWithAuthorization_onlyPayee() public {
        bytes32 nonce = keccak256("r");
        uint256 vb = block.timestamp + 60;
        bytes memory sig =
            _sig(ALICE_PK, _authDigest(token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), alice, bob, 3e18, 0, vb, nonce));
        vm.prank(relayer);
        vm.expectRevert(SpectralToken.CallerMustBePayee.selector);
        token.receiveWithAuthorization(alice, bob, 3e18, 0, vb, nonce, sig);
        vm.prank(bob);
        token.receiveWithAuthorization(alice, bob, 3e18, 0, vb, nonce, sig);
        assertEq(token.balanceOf(bob), 3e18);
    }

    function test_3009_cancelAuthorization() public {
        bytes32 nonce = keccak256("c");
        bytes32 cd = _digest(keccak256(abi.encode(token.CANCEL_AUTHORIZATION_TYPEHASH(), alice, nonce)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, cd);
        vm.expectEmit(address(token));
        emit SpectralToken.AuthorizationCanceled(alice, nonce);
        token.cancelAuthorization(alice, nonce, v, r, s);
        assertTrue(token.authorizationState(alice, nonce));

        uint256 vb = block.timestamp + 60;
        bytes memory sig =
            _sig(ALICE_PK, _authDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), alice, bob, 1e18, 0, vb, nonce));
        vm.expectRevert(SpectralToken.AuthorizationAlreadyUsed.selector);
        token.transferWithAuthorization(alice, bob, 1e18, 0, vb, nonce, sig);
        vm.expectRevert(SpectralToken.AuthorizationAlreadyUsed.selector);
        token.cancelAuthorization(alice, nonce, v, r, s);
    }

    function test_3009_erc1271SmartAccount() public {
        bytes32 nonce = keccak256("sa");
        uint256 vb = block.timestamp + 60;
        bytes memory sig = _sig(
            ALICE_PK,
            _authDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), address(wallet), bob, 4e18, 0, vb, nonce)
        );
        token.transferWithAuthorization(address(wallet), bob, 4e18, 0, vb, nonce, sig);
        assertEq(token.balanceOf(bob), 4e18);
    }

    /// Authorizations are denominated in sUSD (not shares): a rebase between signing and
    /// settlement does not change what the payee receives.
    function test_3009_valueSurvivesRebase() public {
        bytes32 nonce = keccak256("rb");
        uint256 vb = block.timestamp + 60;
        bytes memory sig =
            _sig(ALICE_PK, _authDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), alice, bob, 10e18, 0, vb, nonce));
        token.setIndex(1.2e18);
        token.transferWithAuthorization(alice, bob, 10e18, 0, vb, nonce, sig);
        assertGe(token.balanceOf(bob), 10e18);
        assertLe(token.balanceOf(bob), 10e18 + 2);
    }
}

// =====================================================================================
// 4. AutonomousTreasury
// =====================================================================================

contract AutonomousTreasuryTest is Test {
    MockUSDC internal usdc;
    MockVault internal vault;
    AutonomousTreasury internal treasury;
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockVault(usdc);
        treasury = new AutonomousTreasury(IERC4626(address(vault)), 0, address(this));
        usdc.mint(address(treasury), 1_000e6);
        treasury.depositReserve();
    }

    /// A3: the stabilizer is fixed at construction; there is no setter to race.
    function test_wiring() public {
        assertEq(address(treasury.asset()), address(usdc));
        assertEq(treasury.stabilizer(), address(this));
        (bool canSet,) = address(treasury).call(abi.encodeWithSignature("setStabilizer(address)", bob));
        assertFalse(canSet, "no setter");
        vm.expectRevert(AutonomousTreasury.ZeroAddress.selector);
        new AutonomousTreasury(IERC4626(address(0)), 0, address(this));
        vm.expectRevert(AutonomousTreasury.ZeroAddress.selector);
        new AutonomousTreasury(IERC4626(address(vault)), 0, address(0));
    }

    function test_onlyStabilizerMovesFunds() public {
        vm.startPrank(bob);
        vm.expectRevert(AutonomousTreasury.NotStabilizer.selector);
        treasury.depositReserve();
        vm.expectRevert(AutonomousTreasury.NotStabilizer.selector);
        treasury.withdrawReserve(1e6, bob);
        vm.stopPrank();
    }

    function test_depositAndValue() public view {
        assertEq(treasury.reserveAssets(), 1_000e6);
        assertEq(vault.balanceOf(address(treasury)), 1_000e6);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_sweepDepositsDonationsAndIsStabilizerOnly() public {
        usdc.mint(address(treasury), 5e6); // donation
        assertEq(treasury.reserveAssets(), 1_005e6, "idle donations count at once");
        vm.prank(bob);
        vm.expectRevert(AutonomousTreasury.NotStabilizer.selector);
        treasury.sweep();
        treasury.sweep(); // this test contract is the stabilizer
        assertEq(usdc.balanceOf(address(treasury)), 0);
        assertEq(treasury.reserveAssets(), 1_005e6);
        vm.prank(bob);
        vm.expectRevert(AutonomousTreasury.NotStabilizer.selector);
        treasury.rebalance();
    }

    function test_withdrawUsesIdleFirst() public {
        usdc.mint(address(treasury), 10e6);
        treasury.withdrawReserve(15e6, bob);
        assertEq(usdc.balanceOf(bob), 15e6);
        assertEq(usdc.balanceOf(address(treasury)), 0);
        assertEq(vault.totalAssets(), 995e6);
    }

    function test_yieldAndLossReflected() public {
        vault.simulateYield(10e6);
        assertApproxEqAbs(treasury.reserveAssets(), 1_010e6, 1);
        assertLe(treasury.reserveAssets(), 1_010e6, "conservative");
        vault.simulateLoss(110e6);
        assertApproxEqAbs(treasury.reserveAssets(), 900e6, 1);
    }

    function test_liquidityLimitedByVault() public {
        vault.setLiquidityCap(100e6);
        assertEq(treasury.liquidAssets(), 100e6);
        vm.expectRevert();
        treasury.withdrawReserve(200e6, bob);
    }
}

// =====================================================================================
// 5. WrappedSUSD
// =====================================================================================

contract WrappedSUSDTest is SpectrumFixture {
    WrappedSUSD internal ws;

    function setUp() public {
        _deploySystem();
        ws = new WrappedSUSD(token);
        _mintFor(alice, 10_000e6);
        vm.startPrank(alice);
        token.approve(address(ws), type(uint256).max);
        ws.deposit(1_000e18, alice);
        vm.stopPrank();
    }

    function test_wrapperBalanceIsFixedWhileValueTracksIndex() public {
        uint256 shares = ws.balanceOf(alice);
        assertEq(shares, 1_000e18);
        vault.simulateYield(600e6); // above the 2.75% buffer on a 10,000 USDC reserve
        assertTrue(stabilizer.rebase());
        assertEq(ws.balanceOf(alice), shares, "wsUSD does not rebase");
        assertGt(ws.convertToAssets(shares), 1_000e18, "value accrues");

        _lossTo((token.totalSupply() * 95) / 100);
        stabilizer.sync();
        assertLt(ws.convertToAssets(shares), 1_000e18, "loss is shared");
    }

    function test_unwrapReturnsSUSD() public {
        vault.simulateYield(600e6);
        stabilizer.rebase();
        uint256 before = token.balanceOf(alice);
        uint256 shares = ws.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = ws.redeem(shares, alice, alice);
        assertGt(assets, 1_000e18);
        assertApproxEqAbs(token.balanceOf(alice) - before, assets, 2);
    }
}

// =====================================================================================
// 6. SpectralStabilizer
// =====================================================================================

contract SpectralStabilizerTest is SpectrumFixture {
    function setUp() public {
        _deploySystem();
    }

    function _rebaseAfter(uint256 secs) internal returns (bool) {
        vm.warp(vm.getBlockTimestamp() + secs);
        return stabilizer.rebase();
    }

    /// Lower the index by 1 bp through a realised vault loss, then sync.
    function _whipsawLoss() internal {
        uint256 s = token.totalSupply();
        _lossTo(s - s / 10_000);
        assertTrue(stabilizer.sync());
    }

    // ------------------------------------------------------------------ wiring

    function test_constructorWiring() public {
        assertEq(address(stabilizer.asset()), address(usdc));
        assertEq(stabilizer.scale(), SCALE);
        assertTrue(stabilizer.hasRole(stabilizer.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(stabilizer.hasRole(stabilizer.GUARDIAN_ROLE(), admin));
        assertEq(stabilizer.defaultAdminDelay(), stabilizer.ADMIN_TRANSFER_DELAY());
        // AccessControlDefaultAdminRules rejects a zero admin before the body runs.
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlInvalidDefaultAdmin(address)", address(0))
        );
        new SpectralStabilizer(
            token,
            treasury,
            ISpectralEntropyOracle(address(oracle)),
            address(0),
            address(0),
            1,
            type(uint256).max,
            _allowlist()
        );
    }

    /// A5: the allowlist must be non-empty, free of duplicates, over the treasury's asset, and
    /// must contain the vault the treasury starts with.
    function test_constructorValidatesVaultAllowlist() public {
        address[] memory list = new address[](0);
        vm.expectRevert(SpectralStabilizer.BadVaultAllowlist.selector);
        new SpectralStabilizer(
            token, treasury, ISpectralEntropyOracle(address(oracle)), admin, address(0), 1, 1, list
        );

        list = new address[](1);
        list[0] = address(new MockVault(usdc)); // valid asset, but not the starting vault
        vm.expectRevert(SpectralStabilizer.BadVaultAllowlist.selector);
        new SpectralStabilizer(
            token, treasury, ISpectralEntropyOracle(address(oracle)), admin, address(0), 1, 1, list
        );

        list = new address[](2);
        list[0] = address(vault);
        list[1] = address(vault);
        vm.expectRevert(SpectralStabilizer.BadVaultAllowlist.selector); // duplicate
        new SpectralStabilizer(
            token, treasury, ISpectralEntropyOracle(address(oracle)), admin, address(0), 1, 1, list
        );

        list[1] = address(new MockVault(new MockUSDC()));
        vm.expectRevert(SpectralStabilizer.BadVaultAllowlist.selector); // wrong asset
        new SpectralStabilizer(
            token, treasury, ISpectralEntropyOracle(address(oracle)), admin, address(0), 1, 1, list
        );
    }

    /// A3: a stabilizer refuses to exist unless the token and the treasury both name it, so a
    /// wrong address prediction (or a raced nonce) aborts the deployment.
    function test_constructorRejectsMiswiring() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        SpectralToken foreign = new SpectralToken(bob);
        vm.expectRevert(SpectralStabilizer.WiringMismatch.selector);
        new SpectralStabilizer(
            foreign, treasury, ISpectralEntropyOracle(address(oracle)), admin, address(0), 1, 1, _allowlist()
        );

        next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        SpectralToken mine = new SpectralToken(next);
        vm.expectRevert(SpectralStabilizer.WiringMismatch.selector); // the treasury names the old stabilizer
        new SpectralStabilizer(
            mine, treasury, ISpectralEntropyOracle(address(oracle)), admin, address(0), 1, 1, _allowlist()
        );
    }

    // ------------------------------------------------------------------ policy

    function test_policyEndpoints() public view {
        assertEq(stabilizer.mintFeeRate(0), 0.0001e18);
        assertEq(stabilizer.mintFeeRate(1e18), 0.0025e18); // 25 bp ceiling (D4; was 50 bp)
        assertEq(stabilizer.mintFeeRate(0.5e18), 0.0007e18); // 1 bp + 24 bp / 4
        assertEq(stabilizer.redeemFeeRate(0), 0.0001e18);
        assertEq(stabilizer.redeemFeeRate(1e18), 0.001e18);
        assertEq(stabilizer.expansionCapRate(0), 0.2e18);
        assertEq(stabilizer.expansionCapRate(1e18), 0.02e18);
        assertEq(stabilizer.bufferRate(0), 0.0275e18, "floored at the neutral buffer (D4)");
        assertEq(stabilizer.bufferRate(0.5e18), 0.0275e18);
        assertEq(stabilizer.bufferRate(0.75e18), 0.038_75e18);
        assertEq(stabilizer.bufferRate(1e18), 0.05e18);
        assertEq(stabilizer.rebaseStepRate(0), 0.0001e18);
        assertEq(stabilizer.rebaseStepRate(1e18), 0.00005e18);
        assertEq(stabilizer.mintFeeRate(7e18), stabilizer.mintFeeRate(1e18), "h is clamped");
    }

    function testFuzz_policyIsMonotoneInEntropy(uint256 h1, uint256 h2) public view {
        h1 = bound(h1, 0, 1.2e18);
        h2 = bound(h2, h1, 1.2e18);
        assertLe(stabilizer.mintFeeRate(h1), stabilizer.mintFeeRate(h2));
        assertLe(stabilizer.redeemFeeRate(h1), stabilizer.redeemFeeRate(h2));
        assertGe(stabilizer.expansionCapRate(h1), stabilizer.expansionCapRate(h2));
        assertLe(stabilizer.bufferRate(h1), stabilizer.bufferRate(h2));
        assertGe(stabilizer.rebaseStepRate(h1), stabilizer.rebaseStepRate(h2));
    }

    /// Anti-sandwich: one rebase step is always worth less than a mint + redeem round trip.
    function testFuzz_rebaseStepBelowRoundTripFees(uint256 h) public view {
        assertLt(
            stabilizer.REBASE_STEP_MAX(), stabilizer.MINT_FEE_MIN() + stabilizer.REDEEM_FEE_MIN(), "constants"
        );
        h = bound(h, 0, 1e18);
        assertLt(stabilizer.rebaseStepRate(h), stabilizer.mintFeeRate(h) + stabilizer.redeemFeeRate(h));
    }

    // ------------------------------------------------------------------ mint

    function test_mint_creditsReserveAndChargesFee() public {
        (uint256 qOut, uint256 qFee) = lens.quoteMint(1_000e6);
        uint256 out = _mintFor(alice, 1_000e6);
        assertEq(out, 999.9e18);
        assertEq(qOut, out);
        assertEq(qFee, 0.1e18);
        assertEq(token.balanceOf(alice), 999.9e18);
        assertEq(stabilizer.reserveValue(), 1_000e18);
        assertEq(lens.surplus(), 0.1e18, "fee stays in the reserve");
        assertGe(lens.reserveRatio(), 1e18);
    }

    function test_mint_feeRisesWithEntropy() public {
        oracle.setEntropy(1e18);
        assertEq(_mintFor(alice, 1_000e6), 997.5e18); // 25 bp at H = 1 (D4; 50 bp before)
    }

    function test_mint_guards() public {
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(stabilizer), type(uint256).max);
        vm.expectRevert(SpectralStabilizer.AmountTooSmall.selector);
        stabilizer.mint(0.005e6, alice, 0);
        vm.expectRevert(SpectralStabilizer.Slippage.selector);
        stabilizer.mint(1_000e6, alice, 999.95e18);
        vm.expectRevert(SpectralStabilizer.ZeroAddress.selector);
        stabilizer.mint(1_000e6, address(0), 0);
        vm.stopPrank();
    }

    function test_mint_donationBecomesSurplusNotCredit() public {
        usdc.mint(address(treasury), 50e6);
        assertEq(_mintFor(alice, 1_000e6), 999.9e18);
        assertEq(stabilizer.reserveValue(), 1_050e18);
        assertEq(lens.surplus(), 50.1e18);
    }

    function test_mint_bootstrapCap() public {
        _mintFor(alice, 900_000e6); // 899,910 sUSD
        assertEq(lens.expansionRemaining(), 100_090e18);
        usdc.mint(bob, 200_000e6);
        vm.startPrank(bob);
        usdc.approve(address(stabilizer), 200_000e6);
        vm.expectRevert(abi.encodeWithSelector(SpectralStabilizer.ExpansionCapExceeded.selector, 100_090e18));
        stabilizer.mint(200_000e6, bob, 0);
        vm.stopPrank();
    }

    /// A1: a mint-and-redeem round trip in one transaction (flash-loan funded) must not use up
    /// the epoch's mint capacity. The cap limits net growth, not gross flow.
    function test_mint_roundTripLeavesCapacityUnchanged() public {
        bootstrapCap = 10_000e18;
        _deploySystem();
        oracle.setEntropy(0); // minimum fees: the cheapest griefing case
        _mintFor(alice, 100e6);
        uint256 capacityBefore = lens.expansionRemaining();

        RoundTripper rt = new RoundTripper();
        uint256 assets = (capacityBefore * 10_000) / 9_999 / SCALE; // fills the cap after the 1 bp fee
        usdc.mint(address(rt), assets);
        rt.run(usdc, stabilizer, token, assets);

        assertEq(token.balanceOf(address(rt)), 0, "round trip completed");
        assertEq(lens.expansionRemaining(), capacityBefore, "capacity restored");
        assertEq(_mintFor(bob, 100e6), 99.99e18, "other minters are not blocked");
    }

    /// A1: net growth from minting within one epoch never exceeds the cap, whatever the
    /// order of mints and redemptions.
    function testFuzz_netGrowthPerEpochStaysCapped(uint64[8] memory amounts, bool[8] memory isMint) public {
        bootstrapCap = 10_000e18;
        _deploySystem();
        _mintFor(alice, 5_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 days); // fresh epoch, starting supply ~5,000
        _mintFor(alice, 1e6); // rolls the epoch
        uint256 start = token.totalSupply();
        for (uint256 i; i < 8; ++i) {
            if (isMint[i]) {
                uint256 room = lens.expansionRemaining() / SCALE;
                if (room < 2e6) continue;
                _mintFor(bob, bound(amounts[i], 1e6, room));
            } else {
                uint256 bal = token.balanceOf(bob);
                if (bal < stabilizer.minAmount()) continue;
                _redeemFor(bob, bound(amounts[i], stabilizer.minAmount(), bal));
            }
            uint256 supply = token.totalSupply();
            if (supply > start) assertLe(supply - start, 10_000e18, "net growth within the cap");
            assertLe(stabilizer.mintedInEpoch(), 10_000e18);
        }
    }

    function test_mint_capScalesWithSupplyAndEntropy() public {
        bootstrapCap = 1_000e18;
        _deploySystem();
        for (uint256 d; d < 6; ++d) {
            _mintFor(alice, 1_000e6); // 999.9 sUSD per epoch (bootstrap-bound)
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        uint256 supply = token.totalSupply(); // 5,999.4 sUSD
        assertEq(supply, 5_999.4e18);
        assertEq(lens.expansionRemaining(), (supply * 20) / 100, "20% of supply at h = 0");
        oracle.setEntropy(1e18);
        assertEq(lens.expansionRemaining(), 1_000e18, "2% of supply < bootstrap at h = 1");
    }

    // ------------------------------------------------------------------ redeem

    function test_redeem_paysCollateralMinusFee() public {
        _mintFor(alice, 1_000e6);
        (uint256 qAssets, uint256 qFee) = lens.quoteRedeem(500e18);
        uint256 out = _redeemFor(alice, 500e18);
        assertEq(out, 499.95e6);
        assertEq(qAssets, out);
        assertEq(qFee, 0.05e18);
        assertEq(usdc.balanceOf(alice), 499.95e6);
        assertEq(token.totalSupply(), 499.9e18);
        assertEq(stabilizer.reserveValue(), 500.05e18);
        _assertSolvent();
    }

    function test_redeem_guards() public {
        _mintFor(alice, 1_000e6);
        vm.startPrank(alice);
        vm.expectRevert(SpectralStabilizer.AmountTooSmall.selector);
        stabilizer.redeem(0.005e18, alice, 0);
        vm.expectRevert(SpectralStabilizer.Slippage.selector);
        stabilizer.redeem(100e18, alice, 100e6);
        vm.expectRevert(SpectralToken.InsufficientBalance.selector);
        stabilizer.redeem(1_000e18, alice, 0);
        vm.stopPrank();
    }

    function test_redeem_fullExitLeavesSurplusOnly() public {
        _mintFor(alice, 1_000e6);
        _redeemFor(alice, token.balanceOf(alice));
        assertEq(token.totalSupply(), 0);
        // mint fee 0.1 + redemption fee ceil(999.9 * 1 bp) = 0.09999
        assertEq(stabilizer.reserveValue(), 0.19999e18, "both fees remain");
    }

    /// A7: the minimum is derived from vault rounding, and a holder below it can still exit in
    /// full, so no balance is ever trapped.
    function test_minimumIsDerivedAndDustCanStillExit() public {
        assertEq(stabilizer.minAmount(), 10_000 * SCALE, "10,000 x one wei of USDC");
        assertEq(stabilizer.minAmount(), 0.01e18);
        // At the minimum the 1 bp fee still covers one wei of vault rounding.
        uint256 feeAtMin = Math.mulDiv(stabilizer.minAmount(), stabilizer.REDEEM_FEE_MIN(), 1e18, Math.Rounding.Ceil);
        assertGe(feeAtMin, SCALE, "fee >= worst-case rounding");

        _mintFor(alice, 1_000e6);
        vm.startPrank(alice);
        stabilizer.redeem(token.balanceOf(alice) - 0.005e18, alice, 0); // leave dust behind
        uint256 dust = token.balanceOf(alice);
        assertLt(dust, stabilizer.minAmount(), "below the minimum");
        assertGt(dust, 0);

        vm.expectRevert(SpectralStabilizer.AmountTooSmall.selector); // a partial redemption is not allowed
        stabilizer.redeem(dust / 2, alice, 0);
        uint256 out = stabilizer.redeem(type(uint256).max, alice, 0); // the whole balance is
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(token.balanceOf(alice), 0, "dust is not trapped");
        _assertSolvent();
    }

    function test_redeem_illiquidVaultRevertsCleanly() public {
        _mintFor(alice, 1_000e6);
        vault.setLiquidityCap(10e6);
        vm.prank(alice);
        vm.expectRevert();
        stabilizer.redeem(500e18, alice, 0);
        assertEq(token.balanceOf(alice), 999.9e18, "nothing burned");
    }

    // ------------------------------------------------------------------ pause

    function test_pause_blocksMintAndRebaseOnly() public {
        _mintFor(alice, 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, stabilizer.GUARDIAN_ROLE()
            )
        );
        vm.prank(bob);
        stabilizer.pause();

        vm.prank(admin);
        stabilizer.pause();
        usdc.mint(bob, 10e6);
        vm.startPrank(bob);
        usdc.approve(address(stabilizer), 10e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stabilizer.mint(10e6, bob, 0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stabilizer.rebase();
        vm.stopPrank();

        _lossTo(900e18);
        assertTrue(stabilizer.sync(), "loss absorption is never paused");
        assertGt(_redeemFor(alice, 100e18), 0, "redemption is never paused");
        _assertSolvent();
    }

    // ------------------------------------------------------------------ rebase

    function test_rebase_distributesSurplusInBoundedSteps() public {
        _mintFor(alice, 10_000e6); // 9,999 sUSD
        vault.simulateYield(400e6); // 4% > the 2.75% neutral buffer
        uint256 supply0 = token.totalSupply();

        vm.prank(bob); // permissionless keeper
        assertTrue(stabilizer.rebase());
        assertEq(token.index(), 1.0001e18, "exactly one 1 bp step");
        assertApproxEqAbs(token.totalSupply() - supply0, supply0 / 10_000, 1);

        vm.expectRevert(SpectralStabilizer.RebaseTooSoon.selector);
        stabilizer.rebase();

        uint256 i1 = token.index();
        assertTrue(_rebaseAfter(1 hours));
        assertGt(token.index(), i1);
        assertGe(lens.reserveRatio(), 1e18 + stabilizer.bufferRate(0) - 1, "buffer kept");
    }

    function test_rebase_keepsBuffer() public {
        _mintFor(alice, 10_000e6);
        vault.simulateYield(250e6); // 2.5% < the 2.75% buffer
        vm.expectRevert(SpectralStabilizer.NothingToDistribute.selector);
        stabilizer.rebase();
        vault.simulateYield(100e6); // 3.5% > buffer
        assertTrue(stabilizer.rebase());
    }

    function test_rebase_highEntropyHalvesStepAndRaisesBuffer() public {
        _mintFor(alice, 10_000e6);
        oracle.setEntropy(1e18);
        vault.simulateYield(400e6); // 4% < 5% buffer at h = 1
        vm.expectRevert(SpectralStabilizer.NothingToDistribute.selector);
        stabilizer.rebase();
        vault.simulateYield(200e6);
        assertTrue(stabilizer.rebase());
        assertEq(token.index(), 1.00005e18, "0.5 bp step at h = 1");
    }

    function test_rebase_requiresSupply() public {
        vm.expectRevert(SpectralStabilizer.NothingToDistribute.selector);
        stabilizer.rebase();
    }

    function test_rebase_monotoneYieldIsNeverDeferred() public {
        _mintFor(alice, 10_000e6);
        vault.simulateYield(500e6);
        for (uint256 i; i < 40; ++i) {
            assertTrue(_rebaseAfter(1 hours), "monotone path: L = D");
        }
        assertEq(stabilizer.churnLength(), stabilizer.churnMax() - stabilizer.churnMin());
    }

    // ------------------------------------------------------------------ losses

    function test_loss_syncSharesItProRata() public {
        _mintFor(alice, 1_000e6);
        _mintFor(bob, 3_000e6);
        uint256 a0 = token.balanceOf(alice);
        uint256 b0 = token.balanceOf(bob);
        vault.simulateLoss(400e6); // 10%
        assertLt(stabilizer.reserveValue(), token.totalSupply());

        vm.expectEmit(false, false, false, false, address(stabilizer));
        emit SpectralStabilizer.LossAbsorbed(0, 0, 0, 0);
        assertTrue(stabilizer.sync());

        _assertSolvent();
        assertApproxEqAbs(token.totalSupply(), stabilizer.reserveValue(), 1e9, "supply = reserve");
        assertApproxEqRel(token.balanceOf(alice) * 1e18 / a0, token.balanceOf(bob) * 1e18 / b0, 1e6, "pro rata");
        assertFalse(stabilizer.sync(), "nothing left to absorb");
    }

    function test_loss_redeemSyncsFirst() public {
        _mintFor(alice, 1_000e6);
        uint256 stale = token.balanceOf(alice);
        vault.simulateLoss(100e6);
        vm.prank(alice);
        vm.expectRevert(SpectralToken.InsufficientBalance.selector); // can't exit at the old price
        stabilizer.redeem(stale, alice, 0);

        stabilizer.sync();
        uint256 bal = token.balanceOf(alice);
        assertApproxEqRel(bal, 900e18, 1e15);
        _redeemFor(alice, bal);
        assertApproxEqRel(usdc.balanceOf(alice), 899.91e6, 1e15);
        _assertSolvent();
    }

    function test_loss_redeemAllSentinelHandlesPendingLoss() public {
        _mintFor(alice, 1_000e6);
        vault.simulateLoss(100e6); // not yet synced: alice's displayed balance is stale
        vm.prank(alice);
        uint256 out = stabilizer.redeem(type(uint256).max, alice, 0);
        assertApproxEqRel(out, 899.91e6, 1e15);
        assertEq(token.balanceOf(alice), 0);
        _assertSolvent();
    }

    function test_loss_newMinterIsNotDiluted() public {
        _mintFor(alice, 1_000e6);
        vault.simulateLoss(100e6); // not yet synced
        uint256 out = _mintFor(bob, 1_000e6);
        assertApproxEqAbs(out, 999.9e18, 2e12, "minted at par after the loss is absorbed");
        assertApproxEqRel(token.balanceOf(alice), 900e18, 1e15, "loss borne by existing holders");
        _assertSolvent();
    }

    function test_loss_rebaseAbsorbsInsteadOfDistributing() public {
        _mintFor(alice, 1_000e6);
        vault.simulateLoss(50e6);
        assertFalse(stabilizer.rebase());
        assertLt(token.index(), 1e18);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ churn budget (C_DIAM)

    function test_churn_defersThirdUpLegWhenWhipsawing() public {
        _mintFor(alice, 10_000e6);
        vault.simulateYield(400e6); // above the 2.75% buffer
        assertTrue(_rebaseAfter(1 hours), "up 1");
        _whipsawLoss(); // down 1
        vault.simulateYield(vault.totalAssets() / 25); // > 2.75% buffer after the whipsaw loss
        assertTrue(_rebaseAfter(1 hours), "up 2: L = 3D <= C_DIAM D");
        _whipsawLoss(); // down 2
        vault.simulateYield(vault.totalAssets() / 25); // > 2.75% buffer after the whipsaw loss

        uint256 idx = token.index();
        vm.expectEmit(false, false, false, false, address(stabilizer));
        emit SpectralStabilizer.RebaseDeferred(0, 0, 0, 0);
        assertFalse(_rebaseAfter(1 hours), "up 3: L = 5D > C_DIAM D");
        assertEq(token.index(), idx, "deferred, not applied");

        assertTrue(_rebaseAfter(7 days), "a fresh window resumes distribution");
        _assertSolvent();
    }

    // ------------------------------------------------------------------ MEV

    /// Mint just before a rebase and redeem just after: always a loss for the attacker.
    function testFuzz_rebaseSandwichIsUnprofitable(uint256 assets, uint256 h, uint256 yieldBps) public {
        _mintFor(alice, 100_000e6);
        yieldBps = bound(yieldBps, 1, 1_000);
        vault.simulateYield((vault.totalAssets() * yieldBps) / 10_000);
        oracle.setEntropy(bound(h, 0, 1e18));
        assets = bound(assets, 2e6, 800_000e6); // >= 1 sUSD left after a 25 bp fee

        address mev = makeAddr("mev");
        uint256 out = _mintFor(mev, assets);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        try stabilizer.rebase() {} catch {}
        uint256 bal = token.balanceOf(mev);
        assertGe(bal, out);
        uint256 back = _redeemFor(mev, bal);
        assertLt(back, assets, "round trip around a rebase loses money");
        _assertSolvent();
    }
}

// =====================================================================================
// 7. Churn budget arithmetic (harness)
// =====================================================================================

contract ChurnBudgetTest is SpectrumFixture {
    StabilizerHarness internal h;

    function _newStabilizer() internal override returns (SpectralStabilizer) {
        return new StabilizerHarness(
            token,
            treasury,
            ISpectralEntropyOracle(address(oracle)),
            admin,
            address(0),
            bootstrapCap,
            type(uint256).max,
            _allowlist()
        );
    }

    function setUp() public {
        _deploySystem();
        h = StabilizerHarness(address(stabilizer));
    }

    function test_exactBoundary() public {
        uint256 a = 1e16;
        uint256 i0 = 1e18;
        h.exposedCommitChurn(i0, i0 + a); // up
        h.exposedCommitChurn(i0 + a, i0); // down
        h.exposedCommitChurn(i0, i0 + a); // up    L = 3a, D = a
        uint256 d = 4e14;
        h.exposedCommitChurn(i0 + a, i0 + a - d); // small down
        // L <= C_DIAM * D  <=>  3a + d + u <= floor(3.047197551196597746 * 1e16)
        uint256 u = 71_975_511_965_977;
        (bool ok, uint256 len, uint256 range) = h.exposedChurnAfter(i0 + a - d, i0 + a - d + u);
        assertTrue(ok, "at the boundary");
        assertEq(len, 3 * a + d + u);
        assertEq(range, a);
        (ok,,) = h.exposedChurnAfter(i0 + a - d, i0 + a - d + u + 1);
        assertFalse(ok, "one wei past the boundary");
    }

    function test_windowResets() public {
        h.exposedCommitChurn(1e18, 1.01e18);
        h.exposedCommitChurn(1.01e18, 1e18);
        h.exposedCommitChurn(1e18, 1.01e18);
        h.exposedCommitChurn(1.01e18, 1e18);
        (bool ok,,) = h.exposedChurnAfter(1e18, 1.01e18);
        assertFalse(ok);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 len;
        uint256 range;
        (ok, len, range) = h.exposedChurnAfter(1e18, 1.01e18);
        assertTrue(ok);
        assertEq(len, 0.01e18);
        assertEq(range, 0.01e18);
    }

    /// The committed statistics always equal what the check predicted.
    function testFuzz_commitMatchesPrediction(uint64[12] memory steps, bool[12] memory ups) public {
        uint256 idx = 1e18;
        for (uint256 i; i < 12; ++i) {
            uint256 s = bound(steps[i], 1, 1e15);
            uint256 next = ups[i] ? idx + s : idx - s;
            (bool ok, uint256 len, uint256 range) = h.exposedChurnAfter(idx, next);
            if (!ups[i] || ok) {
                h.exposedCommitChurn(idx, next);
                assertEq(h.churnLength(), len);
                assertEq(h.churnMax() - h.churnMin(), range);
                if (ups[i]) {
                    assertLe(len * 1e18, h.C_DIAM_WAD() * range, "accepted up-moves respect the budget");
                }
                idx = next;
            }
        }
    }
}

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

// =====================================================================================
// 9. Invariants: the 100% reserve floor
// =====================================================================================

contract SpectrumInvariantTest is SpectrumFixture {
    StabilizerHandler internal handler;

    function setUp() public {
        liquidityBufferBps = 1_500;
        usdc = new MockUSDC();
        MockVault vaultB = new MockVault(usdc);
        allowedVaults.push(address(vaultB));
        _deploySystem();
        handler = new StabilizerHandler(token, stabilizer, treasury, usdc, vault, vaultB, oracle, admin);
        handler.mint(0, 50_000e6);
        handler.mint(1, 20_000e6);
        handler.fundAttacker(100_000e6); // A10: its own capital, on top of any flash loan

        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = StabilizerHandler.mint.selector;
        selectors[1] = StabilizerHandler.redeem.selector;
        selectors[2] = StabilizerHandler.transfer.selector;
        selectors[3] = StabilizerHandler.rebase.selector;
        selectors[4] = StabilizerHandler.accrueYield.selector;
        selectors[5] = StabilizerHandler.realiseLoss.selector;
        selectors[6] = StabilizerHandler.donate.selector;
        selectors[7] = StabilizerHandler.setEntropy.selector;
        selectors[8] = StabilizerHandler.warp.selector;
        selectors[9] = StabilizerHandler.rebase.selector; // weight keepers x2
        selectors[10] = StabilizerHandler.setBuffer.selector;
        selectors[11] = StabilizerHandler.rebalance.selector;
        selectors[12] = StabilizerHandler.emergencyExit.selector;
        selectors[13] = StabilizerHandler.migrate.selector;
        selectors[14] = StabilizerHandler.recoverLegacy.selector;
        selectors[15] = StabilizerHandler.attack.selector; // A10, weighted x2
        selectors[16] = StabilizerHandler.attack.selector;
        selectors[17] = StabilizerHandler.contributeCapital.selector; // B8
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_reserveFloor() public view {
        assertGe(stabilizer.reserveValue(), token.totalSupply(), "reserve >= supply");
    }

    /// @dev Every holder: the actors, then the attacker (A10).
    function _holders() internal view returns (address[] memory list) {
        uint256 n = handler.actorCount();
        list = new address[](n + 1);
        for (uint256 i; i < n; ++i) {
            list[i] = handler.actors(i);
        }
        list[n] = handler.attacker();
    }

    function invariant_shareAccounting() public view {
        address[] memory holders = _holders();
        uint256 sum;
        for (uint256 i; i < holders.length; ++i) {
            sum += token.sharesOf(holders[i]);
        }
        assertEq(sum, token.totalShares());
    }

    function invariant_balancesCoveredBySupply() public view {
        address[] memory holders = _holders();
        uint256 sum;
        for (uint256 i; i < holders.length; ++i) {
            sum += token.balanceOf(holders[i]);
        }
        assertLe(sum, token.totalSupply());
    }

    function invariant_everyoneCanExitAtOnce() public view {
        address[] memory holders = _holders();
        uint256 owed;
        for (uint256 i; i < holders.length; ++i) {
            uint256 bal = token.balanceOf(holders[i]);
            if (bal >= stabilizer.minAmount()) {
                (uint256 assetsOut,) = lens.quoteRedeem(bal);
                owed += assetsOut;
            }
        }
        assertLe(owed, treasury.liquidAssets());
    }

    /// A10: whatever it does, the attacker never ends above its start plus its pro-rata share
    /// of distributed surplus. Its sUSD is valued at par, with no exit fee, so this is an upper
    /// bound on what it could walk away with.
    function invariant_noFreeLunch() public view {
        assertLe(
            handler.attackerValue(),
            handler.attackerStart() + handler.attackerEntitlement(),
            "attacker gained more than its pro-rata share of distributions"
        );
    }

    /// B8: protocol capital only ever grows, only through contributions, and no distribution
    /// ever reaches into it.
    function invariant_protocolCapitalNeverDistributed() public view {
        assertEq(stabilizer.protocolCapital(), handler.ghostCapitalCredited(), "capital = sum of contributions");
        assertEq(handler.ghostCapitalDistributed(), 0, "a distribution reached into the capital");
    }

    /// A10: an atomic strategy that starts and ends with no sUSD never ends above its start,
    /// even counting the distributions it caught on the way (the rebase step is below the
    /// round-trip fees).
    function invariant_flatRoundTripsNeverProfit() public view {
        assertEq(handler.ghostFlatRoundTripProfits(), 0);
    }

    function invariant_redemptionsAndLossSyncNeverFail() public view {
        assertEq(handler.ghostUnexpectedRedeemFailures(), 0);
        assertEq(handler.ghostUnexpectedSyncFailures(), 0);
    }

    function invariant_treasuryGovernanceNeverFails() public view {
        assertEq(handler.ghostUnexpectedGovernanceFailures(), 0);
    }

    function invariant_legacySharesNeverCounted() public view {
        // reserveAssets() = current vault position + idle; quarantined shares are excluded.
        uint256 shares = treasury.vault().balanceOf(address(treasury));
        uint256 invested = shares == 0 ? 0 : treasury.vault().previewRedeem(shares);
        assertEq(treasury.reserveAssets(), invested + usdc.balanceOf(address(treasury)));
    }

    function invariant_churnBudgetHoldsAfterEveryDistribution() public view {
        assertEq(handler.ghostChurnViolations(), 0);
    }

    /// Net minting in the epoch (mints minus redemptions, floored at 0) never exceeds the cap
    /// (A1: redemptions free capacity, so round trips cannot exhaust it).
    function invariant_expansionWithinCap() public view {
        if (block.timestamp >= uint256(stabilizer.epochStart()) + stabilizer.EPOCH()) return;
        uint256 cap = stabilizer.epochSupply() * 20 / 100;
        if (cap < stabilizer.bootstrapCap()) cap = stabilizer.bootstrapCap();
        assertLe(stabilizer.mintedInEpoch(), cap);
    }

    function invariant_indexPositive() public view {
        assertGt(token.index(), 0);
    }

    /// End of every run: everybody redeems everything at once (a bank run). Every
    /// redemption must succeed and the floor must still hold.
    function afterInvariant() public {
        address[] memory holders = _holders();
        for (uint256 i; i < holders.length; ++i) {
            address a = holders[i];
            uint256 bal = token.balanceOf(a);
            if (bal >= stabilizer.minAmount() + 1) {
                vm.prank(a);
                stabilizer.redeem(i == 0 ? type(uint256).max : bal, a, 0); // also exercise "redeem all"
            }
        }
        assertGe(stabilizer.reserveValue(), token.totalSupply(), "floor after a bank run");
        assertLt(token.totalSupply(), holders.length * stabilizer.minAmount(), "only dust left");
        // After its own exit, at the real exit fee, the attacker is still within bounds.
        assertLe(handler.attackerValue(), handler.attackerStart() + handler.attackerEntitlement(), "no free lunch after exit");
        emit log_named_uint("attacks", handler.ghostAttacks());
        emit log_named_uint("atomic flat-to-flat attacks", handler.ghostFlatRoundTrips());
        emit log_named_decimal_uint("attacker start (sUSD)", handler.attackerStart(), 18);
        emit log_named_decimal_uint("attacker entitlement (sUSD)", handler.attackerEntitlement(), 18);
        emit log_named_decimal_int(
            "attacker net (sUSD, vs start + entitlement)",
            int256(handler.attackerValue()) - int256(handler.attackerStart() + handler.attackerEntitlement()),
            18
        );
        assertEq(handler.attackerShortfall(), 0, "every flash loan was repaid");
        emit log_named_uint("mints", handler.ghostMints());
        emit log_named_uint("redeems", handler.ghostRedeems());
        emit log_named_uint("rebases", handler.ghostRebases());
        emit log_named_uint("deferred", handler.ghostDeferred());
        emit log_named_uint("losses", handler.ghostLosses());
        emit log_named_uint("migrations", handler.ghostMigrations());
        emit log_named_uint("quarantines", handler.ghostQuarantines());
        emit log_named_uint("exits", handler.ghostExits());
    }
}

// =====================================================================================
// 10. Treasury liquidity buffer and vault failure modes
// =====================================================================================

contract TreasuryLiquidityTest is SpectrumFixture {
    function setUp() public {
        liquidityBufferBps = 1_500;
        _deploySystem();
    }

    function test_bufferKeepsShareOfReserveIdle() public {
        assertEq(_mintFor(alice, 10_000e6), 9_999e18);
        assertEq(treasury.idleAssets(), 1_500e6);
        assertEq(vault.totalAssets(), 8_500e6);
        assertEq(stabilizer.reserveValue(), 10_000e18);
        assertEq(treasury.targetIdle(), 1_500e6);
        _assertSolvent();
    }

    function test_redemptionsServedFromIdleWhileVaultIsIlliquid() public {
        _mintFor(alice, 10_000e6);
        vault.setLiquidityCap(0); // every dollar lent out
        assertEq(_redeemFor(alice, 1_000e18), 999.9e6);
        _assertSolvent();
    }

    function test_redeemBeyondLiquidityRevertsWithAvailableAmount() public {
        _mintFor(alice, 10_000e6);
        vault.setLiquidityCap(100e6);
        assertEq(treasury.liquidAssets(), 1_600e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AutonomousTreasury.InsufficientLiquidity.selector, 1_600e6));
        stabilizer.redeem(5_000e18, alice, 0);
        assertEq(_redeemFor(alice, 1_500e18), 1_499.85e6, "a smaller redemption goes through");
        _assertSolvent();
    }

    function test_pausedVaultKeepsMintAndRedeemWorking() public {
        _mintFor(alice, 1_000e6);
        vault.setPaused(true);
        assertEq(_mintFor(bob, 1_000e6), 999.9e18, "deposit skipped, mint still credited");
        assertEq(treasury.idleAssets(), 1_150e6);
        assertEq(_redeemFor(bob, 500e18), 499.95e6);
        _assertSolvent();
    }

    function test_revertingDepositIsSkippedNotFatal() public {
        _mintFor(alice, 1_000e6);
        vault.setFailDeposits(true);
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(stabilizer), 1_000e6);
        vm.expectEmit(address(treasury));
        emit AutonomousTreasury.DepositSkipped(address(vault), 850e6);
        stabilizer.mint(1_000e6, bob, 0);
        vm.stopPrank();
        assertEq(treasury.idleAssets(), 1_150e6);
        _assertSolvent();
    }

    function test_depositCapIsRespected() public {
        vault.setDepositCap(3_000e6);
        _mintFor(alice, 10_000e6);
        assertEq(vault.totalAssets(), 3_000e6);
        assertEq(treasury.idleAssets(), 7_000e6);
        _assertSolvent();
    }

    function test_rebalanceMovesFundsTowardTarget() public {
        _mintFor(alice, 10_000e6);
        vm.prank(admin);
        stabilizer.setLiquidityBuffer(4_000);
        vm.prank(bob); // permissionless keeper
        stabilizer.rebalanceReserve();
        assertEq(treasury.idleAssets(), 4_000e6);
        vm.prank(admin);
        stabilizer.setLiquidityBuffer(500);
        stabilizer.rebalanceReserve();
        assertEq(treasury.idleAssets(), 500e6);
        uint256 idle = treasury.idleAssets();
        usdc.mint(address(treasury), 50e6); // 0.5% drift: inside the 1% tolerance
        stabilizer.rebalanceReserve();
        assertEq(treasury.idleAssets(), idle + 50e6, "no churn inside tolerance");
        _assertSolvent();
    }

    function test_bufferSettingIsAdminOnlyAndBounded() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, bytes32(0)));
        stabilizer.setLiquidityBuffer(0);
        vm.prank(admin);
        vm.expectRevert(AutonomousTreasury.InvalidBuffer.selector);
        stabilizer.setLiquidityBuffer(10_001);
        vm.expectRevert(AutonomousTreasury.NotStabilizer.selector);
        treasury.setLiquidityBuffer(0);
        vm.expectRevert(AutonomousTreasury.InvalidBuffer.selector);
        new AutonomousTreasury(IERC4626(address(vault)), 10_001, address(this));
    }
}

// =====================================================================================
// 11. Vault emergencies and timelocked migration
// =====================================================================================

contract VaultGovernanceTest is SpectrumFixture {
    MockVault internal vault2;

    function setUp() public {
        liquidityBufferBps = 1_000;
        usdc = new MockUSDC();
        vault2 = new MockVault(usdc); // the allowlisted fallback, created before the system
        allowedVaults.push(address(vault2));
        _deploySystem();
        _mintFor(alice, 10_000e6); // idle 1,000 + vault 9,000
    }

    function _proposeAndWait(IERC4626 v) internal {
        vm.prank(admin);
        stabilizer.proposeVault(v);
        vm.warp(vm.getBlockTimestamp() + 7 days);
    }

    function test_emergencyExitPullsEverythingIdle() public {
        vm.prank(guardian);
        assertEq(stabilizer.emergencyExitVault(), 9_000e6);
        assertEq(treasury.liquidityBufferBps(), 10_000);
        assertEq(vault.balanceOf(address(treasury)), 0);
        assertEq(treasury.idleAssets(), 10_000e6);
        _mintFor(bob, 1_000e6);
        assertEq(vault.balanceOf(address(treasury)), 0, "new mints stay idle after an exit");
        _assertSolvent();
    }

    function test_emergencyExitIsPartialWhenIlliquidAndRepeatable() public {
        vault.setLiquidityCap(2_000e6);
        vm.prank(guardian);
        assertEq(stabilizer.emergencyExitVault(), 2_000e6);
        assertEq(vault.balanceOf(address(treasury)), 7_000e6);
        vault.setLiquidityCap(type(uint256).max);
        vm.prank(guardian);
        assertEq(stabilizer.emergencyExitVault(), 7_000e6);
        assertEq(vault.balanceOf(address(treasury)), 0);
        _assertSolvent();
    }

    function test_migrationNeedsAdminMatchingAssetAndTimelock() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, bytes32(0)));
        stabilizer.proposeVault(vault2);

        MockVault wrong = new MockVault(new MockUSDC());
        vm.prank(admin);
        vm.expectRevert(SpectralStabilizer.AssetMismatch.selector); // checked before the allowlist
        stabilizer.proposeVault(wrong);

        vm.prank(admin);
        stabilizer.proposeVault(vault2);
        uint256 eta = stabilizer.pendingVaultEta();
        assertEq(eta, vm.getBlockTimestamp() + 7 days);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SpectralStabilizer.VaultTimelockActive.selector, eta));
        stabilizer.executeVaultMigration();

        vm.prank(guardian);
        stabilizer.cancelVaultMigration();
        vm.warp(eta);
        vm.prank(admin);
        vm.expectRevert(SpectralStabilizer.NoPendingVault.selector);
        stabilizer.executeVaultMigration();
    }

    /// A5: the admin can only ever move the reserve to a vault fixed at deployment, so a
    /// compromised Safe cannot route 85% of the reserve into a contract of its own.
    function test_onlyAllowlistedVaultsCanBeProposed() public {
        MockVault rogue = new MockVault(usdc); // same asset, not on the allowlist
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SpectralStabilizer.VaultNotAllowed.selector, address(rogue)));
        stabilizer.proposeVault(rogue);

        assertTrue(stabilizer.isAllowedVault(address(vault)));
        assertTrue(stabilizer.isAllowedVault(address(vault2)));
        assertFalse(stabilizer.isAllowedVault(address(rogue)));
        address[] memory list = stabilizer.allowedVaults();
        assertEq(list.length, 2);

        vm.prank(admin);
        stabilizer.proposeVault(vault2); // the allowlisted fallback still works
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(admin);
        stabilizer.executeVaultMigration();
        assertEq(address(treasury.vault()), address(vault2));

        // The emergency exit never depends on the allowlist.
        vm.prank(guardian);
        stabilizer.emergencyExitVault();
        assertEq(treasury.liquidityBufferBps(), 10_000);
        _assertSolvent();
    }

    /// A5: the admin role transfers in two steps with a delay, so one leaked signature cannot
    /// hand control to an attacker instantly.
    function test_adminTransferIsTwoStepAndDelayed() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        stabilizer.beginDefaultAdminTransfer(newAdmin);
        (address pending, uint48 schedule) = stabilizer.pendingDefaultAdmin();
        assertEq(pending, newAdmin);
        assertEq(schedule, vm.getBlockTimestamp() + stabilizer.defaultAdminDelay());

        vm.prank(newAdmin);
        vm.expectRevert(); // too early
        stabilizer.acceptDefaultAdminTransfer();
        vm.warp(uint256(schedule) + 1);
        vm.prank(admin);
        vm.expectRevert(); // only the incoming admin may accept
        stabilizer.acceptDefaultAdminTransfer();
        vm.prank(newAdmin);
        stabilizer.acceptDefaultAdminTransfer();
        assertTrue(stabilizer.hasRole(stabilizer.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertFalse(stabilizer.hasRole(stabilizer.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_migrationMovesReserveToNewVault() public {
        _proposeAndWait(vault2);
        uint256 reserveBefore = stabilizer.reserveValue();
        vm.prank(admin);
        stabilizer.executeVaultMigration();
        assertEq(address(treasury.vault()), address(vault2));
        assertEq(vault.balanceOf(address(treasury)), 0);
        assertEq(vault2.totalAssets(), 9_000e6);
        assertEq(stabilizer.reserveValue(), reserveBefore);
        assertEq(address(treasury.legacyVault()), address(0));
        assertEq(_redeemFor(alice, 5_000e18), 4_999.5e6, "redemptions work on the new vault");
        _assertSolvent();
    }

    function test_illiquidOldVaultIsQuarantinedThenRecovered() public {
        vault.setLiquidityCap(3_000e6);
        _proposeAndWait(vault2);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(admin);
        stabilizer.executeVaultMigration();

        assertEq(address(treasury.legacyVault()), address(vault));
        assertEq(vault.balanceOf(address(treasury)), 6_000e6, "stuck shares quarantined");
        assertEq(stabilizer.reserveValue(), 4_000e18, "and excluded from the reserve");
        assertLe(token.totalSupply(), 4_000e18, "loss absorbed pro rata");
        assertGt(token.totalSupply(), (supplyBefore * 39) / 100);
        _assertSolvent();

        // Migrating back into the quarantined vault is refused.
        _proposeAndWait(vault);
        vm.prank(admin);
        vm.expectRevert(AutonomousTreasury.NewVaultIsLegacy.selector);
        stabilizer.executeVaultMigration();

        // Liquidity returns: anyone recovers the shares; value flows back as surplus.
        vault.setLiquidityCap(type(uint256).max);
        assertEq(treasury.recoverLegacy(), 6_000e6);
        assertEq(address(treasury.legacyVault()), address(0));
        assertGt(lens.surplus(), 5_999e18);
        assertTrue(stabilizer.rebase());
        _assertSolvent();
    }

    function test_treasuryGovernanceOnlyThroughStabilizer() public {
        vm.expectRevert(AutonomousTreasury.NotStabilizer.selector);
        treasury.exitVault();
        vm.expectRevert(AutonomousTreasury.NotStabilizer.selector);
        treasury.migrateVault(vault2);
    }

    function test_guardianCannotUseAdminPowers() public {
        vm.startPrank(guardian);
        stabilizer.pause();
        stabilizer.unpause();
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0));
        vm.expectRevert(denied);
        stabilizer.setSupplyCap(1);
        vm.expectRevert(denied);
        stabilizer.proposeVault(vault2);
        vm.expectRevert(denied);
        stabilizer.setLiquidityBuffer(0);
        vm.expectRevert(denied);
        stabilizer.executeVaultMigration();
        vm.stopPrank();
    }
}

// =====================================================================================
// 12. Guarded launch: supply cap
// =====================================================================================

contract SupplyCapTest is SpectrumFixture {
    function setUp() public {
        supplyCap = 5_000e18;
        _deploySystem();
    }

    function test_capBlocksMintingBeyondIt() public {
        _mintFor(alice, 4_000e6); // 3,999.6 sUSD
        assertEq(lens.supplyCapRemaining(), 1_000.4e18);
        usdc.mint(bob, 3_000e6);
        vm.startPrank(bob);
        usdc.approve(address(stabilizer), 3_000e6);
        vm.expectRevert(abi.encodeWithSelector(SpectralStabilizer.SupplyCapExceeded.selector, 1_000.4e18));
        stabilizer.mint(2_000e6, bob, 0);
        assertEq(stabilizer.mint(1_000e6, bob, 0), 999.9e18);
        vm.stopPrank();
    }

    function test_onlyAdminSetsCap() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, bytes32(0)));
        stabilizer.setSupplyCap(1e30);
        vm.expectEmit(address(stabilizer));
        emit SpectralStabilizer.SupplyCapSet(1e30);
        vm.prank(admin);
        stabilizer.setSupplyCap(1e30);
        assertEq(stabilizer.supplyCap(), 1e30);
    }

    function test_rebasesMayExceedTheCapButMintsMayNot() public {
        _mintFor(alice, 5_000e6); // 4,999.5 sUSD
        uint256 supplyNow = token.totalSupply();
        vm.prank(admin);
        stabilizer.setSupplyCap(supplyNow);
        vault.simulateYield(200e6);
        assertTrue(stabilizer.rebase());
        assertGt(token.totalSupply(), stabilizer.supplyCap());
        assertEq(lens.supplyCapRemaining(), 0);
        usdc.mint(bob, 10e6);
        vm.startPrank(bob);
        usdc.approve(address(stabilizer), 10e6);
        vm.expectRevert(abi.encodeWithSelector(SpectralStabilizer.SupplyCapExceeded.selector, 0));
        stabilizer.mint(10e6, bob, 0);
        vm.stopPrank();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  What does it cost to steer H?
//
//  H moves the mint fee (1-50 bp), the per-epoch expansion cap (20%-2% of supply) and the
//  surplus buffer. This file measures, against a real Uniswap v4 PoolManager, how many swaps,
//  blocks, gas and LP fees an attacker needs to drive the smoothed signal to either extreme,
//  and what that then changes. The numbers are reported in audit/oracle-manipulation.md.
//
//  The assertions are deliberately weak: they pin the properties the fixes must keep (an
//  attacker who packs swaps into few blocks moves H much less than one who waits; H can never
//  lower the surplus buffer below neutral). The cost itself is logged, not asserted, so the
//  file keeps working as a measuring instrument.
// =====================================================================================

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {SpectralToken} from "../src/SpectralToken.sol";
import {SpectralStabilizer} from "../src/SpectralStabilizer.sol";
import {AutonomousTreasury} from "../src/AutonomousTreasury.sol";
import {SpectralEntropyOracle} from "../src/SpectralEntropyOracle.sol";
import {SpectralHook} from "../src/SpectralHook.sol";
import {WrappedSUSD} from "../src/WrappedSUSD.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault} from "./mocks/MockVault.sol";

contract OracleManipulationTest is Deployers {
    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint256 internal constant DUST = 10e18; // mainnet setting: 10 wsUSD
    uint256 internal constant BLOCK_TIME = 2; // Base
    /// @dev How long an attacker is allowed to keep trying. Each block is a transaction under
    ///      `--isolate`, so this also keeps the measurement inside one test's gas budget.
    uint256 internal constant MAX_BLOCKS = 150;

    MockUSDC internal usdc;
    MockVault internal vault;
    AutonomousTreasury internal treasury;
    SpectralToken internal token;
    SpectralEntropyOracle internal oracle;
    SpectralStabilizer internal stabilizer;
    WrappedSUSD internal wsusd;
    SpectralHook internal hook;
    Currency internal ws;
    Currency internal other;

    function setUp() public {
        vm.warp(1_760_000_000);
        vm.roll(36_000_000);
        deployFreshManagerAndRouters();

        usdc = new MockUSDC();
        vault = new MockVault(usdc);
        address hookAt = address(FLAGS ^ (uint160(0x7777) << 144));
        address stabilizerAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        treasury = new AutonomousTreasury(IERC4626(address(vault)), 1_500, stabilizerAt);
        token = new SpectralToken(stabilizerAt);
        oracle = new SpectralEntropyOracle(hookAt, DUST, 0.25e18, 1 hours, 1 hours);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        stabilizer = new SpectralStabilizer(
            token, treasury, oracle, address(this), address(0), 10_000_000e18, type(uint256).max, vaults
        );
        wsusd = new WrappedSUSD(token);

        usdc.mint(address(this), 2_000_000e6);
        usdc.approve(address(stabilizer), type(uint256).max);
        stabilizer.mint(1_000_000e6, address(this), 0);
        token.approve(address(wsusd), type(uint256).max);
        wsusd.deposit(token.balanceOf(address(this)), address(this));
        wsusd.approve(address(swapRouter), type(uint256).max);
        wsusd.approve(address(modifyLiquidityRouter), type(uint256).max);
        ws = Currency.wrap(address(wsusd));
        other = deployMintAndApproveCurrency();

        deployCodeTo(
            "SpectralHook.sol:SpectralHook",
            abi.encode(manager, oracle, ws, other, uint24(100), int24(1)),
            hookAt
        );
        hook = SpectralHook(hookAt);
        (Currency c0, Currency c1) = Currency.unwrap(ws) < Currency.unwrap(other) ? (ws, other) : (other, ws);
        key = PoolKey(c0, c1, 100, 1, IHooks(hookAt));
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: 0}),
            ZERO_BYTES
        );
    }

    // ------------------------------------------------------------------ helpers

    bool internal sellNext = true;

    /// @dev Trade `amount` of wsUSD, alternating direction so the pool price stays near par
    ///      however long the attack runs. The oracle sees the size either way.
    function _tradeWs(uint256 amount) internal {
        bool wsIs0 = Currency.unwrap(key.currency0) == address(wsusd);
        bool zeroForOne = sellNext ? wsIs0 : !wsIs0;
        sellNext = !sellNext;
        swapRouter.swap(
            key,
            swapParams(zeroForOne, -int256(amount)),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function swapParams(bool zeroForOne, int256 amountSpecified)
        internal
        pure
        returns (SwapParams memory)
    {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
    }

    /// @dev Equal swaps, one per block, drive the Walsh entropy of the window to 0.
    function _pushLow(uint256 maxBlocks) internal returns (uint256 blocksUsed, uint256 gasUsed, uint256 volume) {
        uint256 g0 = gasleft();
        for (uint256 i; i < maxBlocks; ++i) {
            _nextBlock();
            _tradeWs(DUST);
            volume += DUST;
            ++blocksUsed;
            if (oracle.smoothedEntropy() <= 0.05e18) break;
        }
        gasUsed = g0 - gasleft();
    }

    /// @dev One block far larger than the rest drives the entropy of the window to 1.
    function _pushHigh(uint256 maxBlocks) internal returns (uint256 blocksUsed, uint256 gasUsed, uint256 volume) {
        uint256 g0 = gasleft();
        for (uint256 i; i < maxBlocks; ++i) {
            _nextBlock();
            uint256 amount = i % 8 == 0 ? 2_000e18 : DUST;
            _tradeWs(amount);
            volume += amount;
            ++blocksUsed;
            if (oracle.smoothedEntropy() >= 0.95e18) break;
        }
        gasUsed = g0 - gasleft();
    }

    // ------------------------------------------------------------------ measurements

    function test_measureCostToDriveEntropyLow() public {
        (uint256 blocksUsed, uint256 gasUsed, uint256 volume) = _pushLow(MAX_BLOCKS);
        emit log_named_uint("low: blocks", blocksUsed);
        emit log_named_uint("low: seconds", blocksUsed * BLOCK_TIME);
        emit log_named_uint("low: wsUSD traded (wei)", volume);
        emit log_named_uint("low: LP fees at 1 bp (wsUSD wei)", volume / 10_000);
        emit log_named_uint("low: gas", gasUsed);
        emit log_named_uint("low: smoothed H", oracle.smoothedEntropy());
        emit log_named_uint("low: mint fee on 1,000 USDC (sUSD wei)", _mintFee());
        emit log_named_uint("low: buffer rate", stabilizer.bufferRate(oracle.smoothedEntropy()));
    }

    function test_measureCostToDriveEntropyHigh() public {
        (uint256 blocksUsed, uint256 gasUsed, uint256 volume) = _pushHigh(MAX_BLOCKS);
        emit log_named_uint("high: blocks", blocksUsed);
        emit log_named_uint("high: seconds", blocksUsed * BLOCK_TIME);
        emit log_named_uint("high: wsUSD traded (wei)", volume);
        emit log_named_uint("high: LP fees at 1 bp (wsUSD wei)", volume / 10_000);
        emit log_named_uint("high: gas", gasUsed);
        emit log_named_uint("high: smoothed H", oracle.smoothedEntropy());
        emit log_named_uint("high: mint fee on 1,000 USDC (sUSD wei)", _mintFee());
        emit log_named_uint("high: buffer rate", stabilizer.bufferRate(oracle.smoothedEntropy()));
    }

    /// The patient attacker: wait long enough between folds that each carries the full
    /// emaAlphaMax. This is the residual cost after the A6 fixes, and it is wall time.
    function test_measureCostOfThePatientAttacker() public {
        uint256 folds;
        uint256 start = vm.getBlockTimestamp();
        uint256 volume;
        for (uint256 f; f < 40; ++f) {
            for (uint256 i; i < 9; ++i) {
                _nextBlock();
                _tradeWs(DUST);
                volume += DUST;
            }
            ++folds;
            if (oracle.smoothedEntropy() <= 0.05e18) break;
            vm.warp(vm.getBlockTimestamp() + 3 hours); // let the next fold weigh alphaMax
        }
        emit log_named_uint("patient: folds", folds);
        emit log_named_uint("patient: hours", (vm.getBlockTimestamp() - start) / 1 hours);
        emit log_named_uint("patient: wsUSD traded (wei)", volume);
        emit log_named_uint("patient: smoothed H", oracle.smoothedEntropy());
        emit log_named_uint("patient: mint fee on 1,000 USDC (sUSD wei)", _mintFee());
        emit log_named_uint("patient: buffer rate", stabilizer.bufferRate(oracle.smoothedEntropy()));
        assertEq(
            stabilizer.bufferRate(oracle.smoothedEntropy()),
            stabilizer.BUFFER_LOW_H(),
            "D4: driving H to 0 can never lower the buffer below neutral"
        );
    }

    /// A6: packing the same flow into consecutive blocks is far weaker than spacing it out.
    function test_packedFlowMovesEntropyFarLessThanPatientFlow() public {
        (,, uint256 volume) = _pushLow(MAX_BLOCKS);
        uint256 packedH = oracle.smoothedEntropy();
        assertGt(packedH, 0.3e18, "packing blocks leaves H near neutral");
        assertGt(volume, 0, "flow happened");
    }

    function _mintFee() internal view returns (uint256 fee) {
        (, fee) = stabilizer.quoteMint(1_000e6);
    }
}

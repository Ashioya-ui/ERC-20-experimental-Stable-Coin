// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Review finding S-01 (audit/review.md): starting the hook's pool.
//
//  The deployment used to call PoolManager.initialize with a hard-coded 1:1 price right after
//  creating the hook. Someone could start the pool first (inside the band), or donate 1 wei
//  of sUSD to the still-empty wrapper so that the hard-coded price fell outside the band;
//  either way the script stopped after seven transactions. The reviewer's proof of concept
//  showed both on the old code. Now the dead-share seed goes in first, and the deployment calls
//  `hook.initializePool()`, which reads the price on-chain and does nothing if the pool has
//  started. These tests show that neither griefing path stops it any more.
//
//  The setup mirrors SpectrumDeploy.deploy() up to the start of the pool: real v4 PoolManager,
//  mainnet parameters, and the wrapper still empty.
// =====================================================================================

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {SpectralToken} from "../src/SpectralToken.sol";
import {SpectralStabilizer} from "../src/SpectralStabilizer.sol";
import {AutonomousTreasury} from "../src/AutonomousTreasury.sol";
import {SpectralEntropyOracle} from "../src/SpectralEntropyOracle.sol";
import {SpectralHook} from "../src/SpectralHook.sol";
import {WrappedSUSD} from "../src/WrappedSUSD.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault} from "./mocks/MockVault.sol";

contract HookStartTest is Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
    // USDC below or above any CREATE address, so both token orders are exercised.
    address internal constant USDC_LOW = address(0x10000); // wsUSD = currency1
    address internal constant USDC_HIGH = address(0xFFFfFFfFfFFffFFfFFFffffFfFfFffFFfFFFFF00); // wsUSD = currency0

    MockUSDC internal usdc;
    SpectralToken internal token;
    SpectralStabilizer internal stabilizer;
    WrappedSUSD internal wsusd;
    SpectralHook internal hook;
    PoolKey internal k;
    address internal griefer = makeAddr("griefer");

    function _deployUpToTheStart(address usdcAt) internal {
        vm.warp(1_700_000_000);
        vm.roll(1_000);
        deployFreshManagerAndRouters();
        deployCodeTo("MockUSDC.sol:MockUSDC", "", usdcAt);
        usdc = MockUSDC(usdcAt);
        MockVault vault = new MockVault(usdc);

        address hookAt = address(FLAGS ^ (uint160(0x4444) << 144));
        address stabilizerAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        AutonomousTreasury treasury = new AutonomousTreasury(IERC4626(address(vault)), 1_500, stabilizerAt);
        token = new SpectralToken(stabilizerAt);
        SpectralEntropyOracle oracle = new SpectralEntropyOracle(hookAt, 10e18, 0.25e18, 1 hours, 1 hours);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        stabilizer = new SpectralStabilizer(
            token, treasury, oracle, makeAddr("safe"), address(0), 10_000e18, 25_000e18, vaults
        );
        require(address(stabilizer) == stabilizerAt, "stabilizer prediction");
        wsusd = new WrappedSUSD(token);
        deployCodeTo(
            "SpectralHook.sol:SpectralHook",
            abi.encode(manager, oracle, Currency.wrap(address(wsusd)), Currency.wrap(usdcAt), uint24(100), int24(1)),
            hookAt
        );
        hook = SpectralHook(hookAt);
        (address a0, address a1) = address(wsusd) < usdcAt ? (address(wsusd), usdcAt) : (usdcAt, address(wsusd));
        k = PoolKey(Currency.wrap(a0), Currency.wrap(a1), 100, 1, IHooks(hookAt));
    }

    function _donateOneWeiToEmptyWrapper() internal {
        usdc.mint(griefer, 1e6);
        vm.startPrank(griefer);
        usdc.approve(address(stabilizer), 1e6);
        stabilizer.mint(1e6, griefer, 0);
        token.transfer(address(wsusd), 1);
        vm.stopPrank();
    }

    /// (a) Someone starts the pool first, inside the band: the deployment's start is a no-op.
    function test_S01_frontRunStartDoesNotStopTheDeployment() public {
        _deployUpToTheStart(USDC_LOW);
        uint160 par = hook.parSqrtPriceX96();
        vm.prank(griefer);
        manager.initialize(k, uint160((uint256(par) * 10_012) / 10_000)); // +0.24%: allowed
        assertFalse(hook.initializePool(), "already started: nothing to do, and no revert");
    }

    /// (b) A donation that moves wsUSD's share price moves the starting price with it.
    function test_S01_donationMovesTheStartWithIt_wsIsCurrency1() public {
        _donationCase(USDC_LOW);
    }

    function test_S01_donationMovesTheStartWithIt_wsIsCurrency0() public {
        _donationCase(USDC_HIGH);
    }

    function _donationCase(address usdcAt) internal {
        _deployUpToTheStart(usdcAt);
        _donateOneWeiToEmptyWrapper();
        assertEq(wsusd.convertToAssets(1e18), 2e18, "the donor set wsUSD's share price");
        assertTrue(hook.initializePool(), "the start still succeeds");
        (uint160 sqrtP,,,) = manager.getSlot0(k.toId());
        assertEq(sqrtP, hook.parSqrtPriceX96(), "at the on-chain par");
        assertTrue(hook.priceWithinBand(sqrtP));
        assertFalse(hook.initializePool(), "a second call is a no-op");
    }

    /// Anyone may start the pool, and only ever at par: there is nothing to gain from it.
    function test_S01_anyoneStartsAtParOnly() public {
        _deployUpToTheStart(USDC_HIGH);
        vm.prank(griefer);
        assertTrue(hook.initializePool());
        (uint160 sqrtP,,,) = manager.getSlot0(k.toId());
        assertEq(sqrtP, hook.parSqrtPriceX96());
    }
}

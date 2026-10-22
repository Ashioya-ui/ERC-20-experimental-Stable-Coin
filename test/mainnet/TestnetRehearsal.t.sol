// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Phase 4, D1: the Base Sepolia dress rehearsal, run locally.
//
//  config/84532.json asks the deploy script to create two labelled TestnetVaults first,
//  because Base Sepolia has no USDC lending vault worth rehearsing against. This runs that exact
//  path (load the config, deploy the test vaults, preflight, deploy, post-deploy check) on a
//  local chain with chain id 84532, Circle's FiatToken v2.2 as USDC and a real v4
//  PoolManager standing in for the live Base Sepolia contracts.
// =====================================================================================

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SpectrumDeploy} from "../../script/lib/SpectrumDeploy.sol";
import {LocalEnv} from "../../script/lib/LocalEnv.sol";
import {IFiatToken} from "../../script/lib/IFiatToken.sol";
import {TestnetVault} from "../../script/lib/TestnetVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract TestnetRehearsalTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    LocalEnv.Env internal env;
    SpectrumDeploy.Config internal cfg;
    SpectrumDeploy.Deployment internal d;
    address internal admin = makeAddr("rehearsalAdmin");

    function setUp() public {
        vm.chainId(84_532);
        vm.warp(1_760_000_000);
        vm.roll(30_000_000);
        if (SpectrumDeploy.CREATE2_DEPLOYER.code.length == 0) {
            vm.etch(SpectrumDeploy.CREATE2_DEPLOYER, LocalEnv.CREATE2_PROXY_RUNTIME);
        }
        env = LocalEnv.deploy(address(this), makeAddr("usdcProxyAdmin"));

        cfg = SpectrumDeploy.loadConfig("config/84532.json");
        assertTrue(cfg.deployTestVaults, "the Sepolia config deploys its own vaults");
        assertEq(cfg.vault, address(0));
        cfg.poolManager = env.poolManager; // stand-ins for the live Base Sepolia contracts
        cfg.usdc = env.usdc;
        cfg.admin = admin;
        cfg.allowEoaAdmin = true; // a throwaway rehearsal admin

        IFiatToken(env.usdc).mint(address(this), cfg.seedUsdc + cfg.seedCapitalUsdc);
        SpectrumDeploy.Config memory c = cfg; // the script works on a memory config
        SpectrumDeploy.deployTestVaults(c);
        cfg = c;
        SpectrumDeploy.preflight(cfg, address(this));
        d = SpectrumDeploy.deploy(cfg, address(this));
        SpectrumDeploy.check(cfg, d, address(this));
    }

    function test_rehearsalDeploysAgainstLabelledTestVaults() public view {
        assertEq(address(d.treasury.vault()), cfg.vault);
        assertTrue(d.stabilizer.isAllowedVault(cfg.fallbackVault));
        assertEq(IERC4626(cfg.vault).asset(), env.usdc);
        assertEq(TestnetVault(cfg.vault).symbol(), "tvUSDC-A");
        assertApproxEqAbs(d.stabilizer.protocolCapital(), 5e18, 2e12, "5 test USDC of capital");
    }

    function test_mintRedeemOnTheRehearsal() public {
        address user = makeAddr("user");
        IFiatToken(env.usdc).mint(user, 10e6);
        vm.startPrank(user);
        IERC20(env.usdc).approve(address(d.stabilizer), 10e6);
        uint256 out = d.stabilizer.mint(10e6, user, 0);
        d.stabilizer.redeem(out / 2, user, 0);
        vm.stopPrank();
        assertGe(d.stabilizer.reserveValue(), d.token.totalSupply());
    }

    function test_testVaultRefusesBaseMainnet() public {
        vm.chainId(8453);
        vm.expectRevert(TestnetVault.TestnetOnly.selector);
        new TestnetVault(IERC20(env.usdc), "x", "x");
        vm.expectRevert(bytes("deployTestVaults: never on Base mainnet"));
        this.callDeployTestVaults();
    }

    /// Review S-01 (c): right after the deployment the pool has no liquidity, so anyone can walk
    /// its price anywhere with a zero-delta swap, for free and unrecorded. The post-deploy check
    /// must report that, not fail on it.
    function test_S01_checkSurvivesAnEmptyPoolWalkedOffPar() public {
        IPoolManager pm = IPoolManager(cfg.poolManager);
        (uint160 start,,,) = pm.getSlot0(d.key.toId());
        assertTrue(d.hook.priceWithinBand(start), "the deployment started the pool at par");
        assertEq(pm.getLiquidity(d.key.toId()), 0, "and nobody has added liquidity yet");

        PoolSwapTest router = new PoolSwapTest(pm);
        uint160 limit = uint160((uint256(start) * 90) / 100);
        vm.prank(makeAddr("griefer")); // holds no tokens
        router.swap(
            d.key,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint160 moved,,,) = pm.getSlot0(d.key.toId());
        assertEq(moved, limit, "price walked for free");
        assertFalse(d.hook.priceWithinBand(moved));
        SpectrumDeploy.check(cfg, d, address(this)); // reports, does not revert
    }

    function callDeployTestVaults() external {
        SpectrumDeploy.Config memory c = cfg;
        SpectrumDeploy.deployTestVaults(c);
    }
}

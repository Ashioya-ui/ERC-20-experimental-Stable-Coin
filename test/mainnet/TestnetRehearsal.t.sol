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

contract TestnetRehearsalTest is Test {
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

    function callDeployTestVaults() external {
        SpectrumDeploy.Config memory c = cfg;
        SpectrumDeploy.deployTestVaults(c);
    }
}

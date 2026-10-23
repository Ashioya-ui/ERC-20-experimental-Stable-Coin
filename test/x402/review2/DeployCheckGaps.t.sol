// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Independent review 2 (external audit of the live Base Sepolia deployment).
//
//  SpectrumDeploy.check() is what PostDeployCheck.s.sol runs against a live chain, and what
//  REPORT_X402.md and RUNBOOK_MAINNET.md point at as the evidence that a deployment is in the
//  state the config describes. These tests show what it does NOT check, by taking a correct
//  deployment, moving it to a state the config does not describe, and watching check() still
//  pass.
//
//  Nothing here is a contract bug. Each one is a gap between the invariant the documents
//  claim is verified and the invariant the script actually verifies.
//
//  Run:  forge test --match-path "test/x402/review2/*"
// =====================================================================================

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SpectrumDeploy} from "../../../script/lib/SpectrumDeploy.sol";
import {LocalEnv} from "../../../script/lib/LocalEnv.sol";
import {IFiatToken} from "../../../script/lib/IFiatToken.sol";

contract DeployCheckGapsTest is Test {
    SpectrumDeploy.Config internal cfg;
    SpectrumDeploy.Deployment internal d;
    address internal admin = makeAddr("reviewAdmin");

    function setUp() public {
        vm.chainId(84_532);
        vm.warp(1_760_000_000);
        vm.roll(30_000_000);
        if (SpectrumDeploy.CREATE2_DEPLOYER.code.length == 0) {
            vm.etch(SpectrumDeploy.CREATE2_DEPLOYER, LocalEnv.CREATE2_PROXY_RUNTIME);
        }
        LocalEnv.Env memory env = LocalEnv.deploy(address(this), makeAddr("usdcProxyAdmin"));

        cfg = SpectrumDeploy.loadConfig("config/84532.json");
        cfg.poolManager = env.poolManager;
        cfg.usdc = env.usdc;
        cfg.admin = admin;
        cfg.guardian = address(0); // exactly what the live Base Sepolia deployment shipped with
        cfg.allowEoaAdmin = true;

        IFiatToken(env.usdc).mint(address(this), cfg.seedUsdc + cfg.seedCapitalUsdc);
        SpectrumDeploy.Config memory c = cfg;
        SpectrumDeploy.deployTestVaults(c);
        cfg = c;
        SpectrumDeploy.preflight(cfg, address(this));
        d = SpectrumDeploy.deploy(cfg, address(this));
        SpectrumDeploy.check(cfg, d, address(this)); // the control: a fresh deployment passes
    }

    /// @dev check() asserts bootstrapCap but never supplyCap, so the guarded-launch cap the
    ///      config and the README promise ("25,000 sUSD at launch") can be removed entirely and
    ///      PostDeployCheck still prints POST-DEPLOY CHECK PASSED.
    /// Was a gap (live audit L-05): check() ignored the supply cap, which is the number the
    /// guarded launch is described by. Now a regression guard.
    /// `check` is an internal library function; expectRevert needs an external call boundary.
    function checkExternal() external view {
        SpectrumDeploy.check(cfg, d, address(this));
    }

    function test_checkCatchesTheGuardedLaunchSupplyCapBeingRemoved() public {
        assertEq(d.stabilizer.supplyCap(), cfg.supplyCap, "the cap starts where the config says");

        vm.prank(admin);
        d.stabilizer.setSupplyCap(type(uint256).max);

        vm.expectRevert(bytes("check: supply cap"));
        this.checkExternal();
    }

    /// @dev The same with the cap set to zero: minting is frozen for everyone and check() passes.
    function test_checkCatchesMintingFrozenByAZeroSupplyCap() public {
        vm.prank(admin);
        d.stabilizer.setSupplyCap(0);
        vm.expectRevert(bytes("check: supply cap"));
        this.callCheck(cfg);
    }

    /// @dev check() never reads `paused()`. A deployment whose minting and rebasing have been
    ///      halted indefinitely by the guardian reports as healthy.
    function test_checkCatchesAPausedProtocol() public {
        vm.prank(admin); // admin holds GUARDIAN_ROLE too
        d.stabilizer.pause();
        assertTrue(d.stabilizer.paused(), "paused");
        vm.expectRevert(bytes("check: protocol is paused"));
        this.callCheck(cfg);
    }

    /// @dev check() never reads the treasury's liquidity buffer, so the 15% the config asks for
    ///      can be set to anything (here 100%: the whole reserve pulled out of the vault, so it
    ///      earns nothing) and the check still passes.
    function test_checkCatchesAChangedLiquidityBuffer() public {
        assertEq(d.treasury.liquidityBufferBps(), cfg.liquidityBufferBps);
        vm.prank(admin);
        d.stabilizer.setLiquidityBuffer(10_000);
        assertEq(d.treasury.liquidityBufferBps(), 10_000);
        vm.expectRevert(bytes("check: liquidity buffer"));
        this.callCheck(cfg);
    }

    /// @dev With `roles.guardian` left at the zero address - which is what the live Base Sepolia
    ///      deployment did - check() silently skips the guardian assertion entirely, so a
    ///      deployment with no independent emergency role passes with no warning. The admin is
    ///      then the only account that can pause or exit the vault.
    function test_checkAcceptsADeploymentWithNoIndependentGuardian() public view {
        assertEq(cfg.guardian, address(0));
        bytes32 guardianRole = d.stabilizer.GUARDIAN_ROLE();
        assertTrue(d.stabilizer.hasRole(guardianRole, admin), "only the admin guards it");
        assertFalse(d.stabilizer.hasRole(guardianRole, address(this)), "the deployer kept nothing");
        SpectrumDeploy.check(cfg, d, address(this));
    }

    /// @dev The positive control: check() does catch what it does look at. If the live admin is
    ///      not the one the config names, it reverts.
    function test_checkDoesCatchAnAdminThatIsNotTheConfiguredOne() public {
        SpectrumDeploy.Config memory wrong = cfg;
        wrong.admin = makeAddr("someoneElse");
        vm.expectRevert(bytes("check: admin role"));
        this.callCheck(wrong);
    }

    /// @dev And the gap that bit the live deployment: config/84532.json as committed has
    ///      roles.admin = address(0), because the deploy workflow writes the admin into the file
    ///      on the runner and never commits it. Running PostDeployCheck from a clean clone
    ///      therefore fails on a deployment that is in fact correct.
    /// Was a gap (live audit L-06): the committed config named no admin, so the one command an
    /// auditor would run against the live deployment failed on a deployment that was correct.
    /// The config now records the admin the deployment granted. Guard against it regressing.
    function test_theCommittedConfigNamesTheLiveAdmin() public view {
        SpectrumDeploy.Config memory asCommitted = SpectrumDeploy.loadConfig("config/84532.json");
        assertTrue(asCommitted.admin != address(0), "the committed config must name the live admin");
    }

    function callCheck(SpectrumDeploy.Config memory c) external view {
        SpectrumDeploy.check(c, d, address(this));
    }
}

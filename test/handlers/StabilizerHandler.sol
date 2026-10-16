// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SpectralToken} from "../../src/SpectralToken.sol";
import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";
import {SpectrumLens} from "../../src/SpectrumLens.sol";
import {AutonomousTreasury} from "../../src/AutonomousTreasury.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Drives the monetary system through random but realistic sequences: mints,
///         redemptions, transfers, rebases, vault yield, vault losses (followed by a keeper
///         `sync`), donations, entropy changes, time jumps, liquidity-buffer changes,
///         rebalancing, emergency exits and timelocked vault migrations (sometimes with an
///         illiquid old vault, which quarantines shares), plus legacy recovery.
contract StabilizerHandler is Test {
    SpectralToken public immutable token;
    SpectralStabilizer public immutable stabilizer;
    SpectrumLens public immutable lens;
    AutonomousTreasury public immutable treasury;
    MockUSDC public immutable usdc;
    MockVault public immutable vaultA;
    MockVault public immutable vaultB;
    MockOracle public immutable oracle;
    address public immutable admin;

    address[] public actors;

    // ghost state
    uint256 public ghostMints;
    uint256 public ghostRedeems;
    uint256 public ghostRebases;
    uint256 public ghostDeferred;
    uint256 public ghostLosses;
    uint256 public ghostUnexpectedRedeemFailures;
    uint256 public ghostUnexpectedSyncFailures;
    uint256 public ghostChurnViolations; // accepted positive rebase with L > C_DIAM * D
    uint256 public ghostUsdcIn; // collateral deposited by actors
    uint256 public ghostUsdcOut; // collateral paid to actors
    uint256 public ghostMigrations;
    uint256 public ghostQuarantines;
    uint256 public ghostExits;
    uint256 public ghostUnexpectedGovernanceFailures;

    constructor(
        SpectralToken token_,
        SpectralStabilizer stabilizer_,
        AutonomousTreasury treasury_,
        MockUSDC usdc_,
        MockVault vaultA_,
        MockVault vaultB_,
        MockOracle oracle_,
        address admin_
    ) {
        token = token_;
        stabilizer = stabilizer_;
        lens = new SpectrumLens(stabilizer_);
        treasury = treasury_;
        usdc = usdc_;
        vaultA = vaultA_;
        vaultB = vaultB_;
        oracle = oracle_;
        admin = admin_;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _vault() internal view returns (MockVault) {
        return MockVault(address(treasury.vault()));
    }

    // ------------------------------------------------------------------ user actions

    function mint(uint256 actorSeed, uint256 assets) external {
        address a = _actor(actorSeed);
        uint256 room = lens.expansionRemaining() / stabilizer.scale();
        if (room < 2e6) return;
        assets = bound(assets, 1e6, room > 5_000_000e6 ? 5_000_000e6 : room);
        usdc.mint(a, assets);
        vm.startPrank(a);
        usdc.approve(address(stabilizer), assets);
        try stabilizer.mint(assets, a, 0) {
            ghostMints++;
            ghostUsdcIn += assets;
        } catch {
            // Allowed: cap boundary, AmountTooSmall after vault rounding.
            usdc.burn(a, assets);
        }
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 fractionBps) external {
        address a = _actor(actorSeed);
        uint256 bal = token.balanceOf(a);
        fractionBps = bound(fractionBps, 1, 10_000);
        uint256 amount = fractionBps == 10_000 ? bal : (bal * fractionBps) / 10_000;
        if (amount < stabilizer.minAmount()) return;
        uint256 before = usdc.balanceOf(a);
        vm.prank(a);
        try stabilizer.redeem(amount, a, 0) {
            ghostRedeems++;
            ghostUsdcOut += usdc.balanceOf(a) - before;
        } catch {
            // The mock vault is fully liquid, so a redemption of an owned balance must
            // never fail. A pending loss can shrink the balance first, so re-check.
            if (token.balanceOf(a) >= amount) ghostUnexpectedRedeemFailures++;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        vm.prank(from);
        token.transfer(to, amount);
    }

    // ------------------------------------------------------------------ keepers / environment

    function rebase(uint256 waitSeconds) external {
        vm.warp(vm.getBlockTimestamp() + bound(waitSeconds, 1 hours, 2 days));
        try stabilizer.rebase() returns (bool distributed) {
            if (distributed) {
                ghostRebases++;
                uint256 range = stabilizer.churnMax() - stabilizer.churnMin();
                if (stabilizer.churnLength() * 1e18 > stabilizer.C_DIAM_WAD() * range) ghostChurnViolations++;
            } else {
                ghostDeferred++;
            }
        } catch {}
    }

    function accrueYield(uint256 bps) external {
        MockVault vault = _vault();
        uint256 assets = vault.totalAssets();
        if (assets == 0) return;
        bps = bound(bps, 1, 300); // up to 3% per call
        vault.simulateYield((assets * bps) / 10_000);
    }

    function realiseLoss(uint256 bps) external {
        MockVault vault = _vault();
        uint256 assets = vault.totalAssets();
        if (assets == 0) return;
        bps = bound(bps, 1, 100); // up to 1% per call
        vault.simulateLoss((assets * bps) / 10_000);
        ghostLosses++;
        // A keeper absorbs the loss right away; sync must never revert.
        try stabilizer.sync() {}
        catch {
            ghostUnexpectedSyncFailures++;
        }
    }

    function donate(uint256 assets) external {
        assets = bound(assets, 1, 10_000e6);
        usdc.mint(address(treasury), assets);
    }

    /// A6: entropy is attacker-controlled, so the handler includes the extremes and sudden
    /// switches between them, not just values in between.
    function setEntropy(uint256 h) external {
        uint256 pick = h % 4;
        if (pick == 0) oracle.setEntropy(0);
        else if (pick == 1) oracle.setEntropy(1e18);
        else if (pick == 2) oracle.setEntropy(oracle.h() == 0 ? 1e18 : 0); // flip
        else oracle.setEntropy(bound(h, 0, 1e18));
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 3 days));
    }

    // ------------------------------------------------------------------ treasury governance

    function setBuffer(uint256 bps) external {
        vm.prank(admin);
        stabilizer.setLiquidityBuffer(bound(bps, 0, 10_000));
    }

    function rebalance() external {
        try stabilizer.rebalanceReserve() {}
        catch {
            ghostUnexpectedGovernanceFailures++;
        }
    }

    function emergencyExit() external {
        vm.prank(admin); // the admin also holds GUARDIAN_ROLE
        try stabilizer.emergencyExitVault() {
            ghostExits++;
        } catch {
            ghostUnexpectedGovernanceFailures++;
        }
    }

    function recoverLegacy() external {
        try treasury.recoverLegacy() {}
        catch {
            ghostUnexpectedGovernanceFailures++;
        }
    }

    /// Propose, wait out the timelock, execute. One time in three the old vault can only pay
    /// out half of the position, so the rest is quarantined as legacy shares.
    function migrate(uint256 seed) external {
        MockVault cur = _vault();
        MockVault next = cur == vaultA ? vaultB : vaultA;
        if (address(next) == address(treasury.legacyVault())) {
            treasury.recoverLegacy();
            if (address(treasury.legacyVault()) != address(0)) return;
        }
        bool illiquid = seed % 3 == 0 && address(treasury.legacyVault()) == address(0);
        if (illiquid) cur.setLiquidityCap(cur.maxWithdraw(address(treasury)) / 2);

        vm.prank(admin);
        stabilizer.proposeVault(next);
        vm.warp(vm.getBlockTimestamp() + stabilizer.VAULT_TIMELOCK());
        vm.prank(admin);
        try stabilizer.executeVaultMigration() {
            ghostMigrations++;
            if (address(treasury.legacyVault()) != address(0)) ghostQuarantines++;
        } catch {
            ghostUnexpectedGovernanceFailures++;
        }
        if (illiquid) cur.setLiquidityCap(type(uint256).max); // liquidity returns later
        // The buffer may have been set to 100% by an exit; keep some deposits flowing.
        if (seed % 2 == 0) {
            vm.prank(admin);
            stabilizer.setLiquidityBuffer(1_500);
        }
    }
}

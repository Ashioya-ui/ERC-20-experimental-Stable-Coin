// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Regression tests for the independent review's findings (audit/review.md).
//
//  S-04  Zero-net blocks must not shape H: a block whose net flow is below the dust threshold
//        takes no slot, round trips cannot keep a signal alive, and a stale signal starts over.
//        Each test fails on the code the review saw and passes after the fix.
//  S-05.1 A migration that abandons dust reports zero quarantined shares.
//  (S-01 is covered by test/HookStart.t.sol, which needs the new initializePool.)
// =====================================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SpectralEntropyOracle} from "../src/SpectralEntropyOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {SpectrumFixture} from "./utils/SpectrumFixture.sol";

/// @notice The oracle driven as its hook drives it, with config/8453.json's parameters.
contract OracleSteeringTest is Test {
    uint256 internal constant DUST = 10e18;
    SpectralEntropyOracle internal oracle;
    address internal hook = makeAddr("hook");

    function setUp() public {
        vm.roll(100);
        vm.warp(1_700_000_000);
        oracle = new SpectralEntropyOracle(hook, DUST, 0.25e18, 1 hours, 1 hours);
    }

    /// One block: a round trip of exactly the dust limit (net 0), or a one-way swap of `size`.
    function _block(bool roundTrip, uint256 size, uint256 wait) internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + wait);
        vm.startPrank(hook);
        oracle.record(int256(size));
        if (roundTrip) oracle.record(-int256(size));
        vm.stopPrank();
    }

    function test_S04_roundTripBlocksTakeNoSlot() public {
        for (uint256 i; i < 8; ++i) _block(true, DUST, 2);
        assertLe(oracle.filled(), 1, "round trips do not fill the window");
        assertEq(oracle.instantEntropy(), 0.5e18, "and so cannot read as a calm window");
        assertEq(oracle.smoothedEntropy(), 0.5e18);
    }

    function test_S04_oneSmallBlockAmongRoundTripsIsNotASpike() public {
        _block(false, DUST, 2);
        for (uint256 i; i < 7; ++i) _block(true, DUST, 2);
        assertLe(oracle.filled(), 2, "only the one-way block counts");
        assertEq(oracle.instantEntropy(), 0.5e18, "no spike reading from 10 wsUSD");
    }

    /// The review's schedule: round trips 20 minutes apart for 3h20m pinned H below 0.05.
    function test_S04_roundTripsCannotPinH() public {
        for (uint256 i; i < 8; ++i) _block(true, DUST, 2);
        for (uint256 i; i < 10; ++i) _block(true, DUST, 20 minutes);
        assertEq(oracle.rawEma(), 0.5e18, "no fold happened");
        assertEq(oracle.smoothedEntropy(), 0.5e18);
    }

    /// Steer H down with real one-way flow, then only round trips: they keep nothing alive.
    function test_S04_roundTripsDoNotKeepASteeredSignalAlive() public {
        for (uint256 i; i < 20; ++i) _block(false, 50e18, 20 minutes);
        uint256 steered = oracle.smoothedEntropy();
        assertLt(steered, 0.2e18, "real, even flow does move H");
        for (uint256 i; i < 4; ++i) _block(true, DUST, 30 minutes);
        assertEq(oracle.smoothedEntropy(), 0.5e18, "two hours of round trips: no signal left");
    }

    /// After a stale gap the signal starts over: one swap cannot bring back the steered value.
    function test_S04_staleSignalStartsOverFromNeutral() public {
        for (uint256 i; i < 20; ++i) _block(false, 50e18, 20 minutes);
        assertLt(oracle.rawEma(), 0.2e18);
        _block(false, 50e18, 2 hours);
        assertEq(oracle.filled(), 1, "a fresh window");
        assertEq(oracle.rawEma(), 0.5e18, "a neutral average");
        assertEq(oracle.smoothedEntropy(), 0.5e18);
        for (uint256 i; i < 7; ++i) _block(false, 50e18, 2);
        assertEq(oracle.smoothedEntropy(), 0.5e18, "warm-up again before anything is folded");
    }
}

/// @notice S-05.1: VaultMigrated reports what was quarantined, not dust that was abandoned.
contract MigrationEventTest is SpectrumFixture {
    MockVault internal vault2;

    function setUp() public {
        liquidityBufferBps = 1_000;
        usdc = new MockUSDC();
        vault2 = new MockVault(usdc);
        allowedVaults.push(address(vault2));
        _deploySystem();
        _mintFor(alice, 10_000e6); // idle 1,000 + vault 9,000
    }

    function test_S05_migrationReportsZeroQuarantinedForAbandonedDust() public {
        vm.prank(admin);
        stabilizer.proposeVault(IERC4626(address(vault2)));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 shares = vault.balanceOf(address(treasury));
        vault.setLiquidityCap(vault.convertToAssets(shares) - 500); // 500 USDC wei stay behind

        vm.recordLogs();
        vm.prank(admin);
        stabilizer.executeVaultMigration(1_000); // abandoned dust is at most LEGACY_DUST_ASSETS

        assertGt(vault.balanceOf(address(treasury)), 0, "dust stayed in the old vault");
        assertEq(address(treasury.legacyVault()), address(0), "and was not quarantined");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("VaultMigrated(address,address,uint256)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(treasury) && logs[i].topics[0] == sig) {
                assertEq(abi.decode(logs[i].data, (uint256)), 0, "nothing quarantined");
                seen = true;
            }
        }
        assertTrue(seen, "VaultMigrated emitted");
        _assertSolvent();
    }
}

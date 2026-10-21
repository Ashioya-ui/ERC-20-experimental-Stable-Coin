// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Phase 4, A9: loss front-running.
//
//  A holder who learns of a vault loss before it is realised on-chain can redeem at par first.
//  With supply S, surplus U (reserve - supply) and redemption fee rate f, a holder who exits
//  b sUSD ahead of a loss l shifts onto everyone who stays
//
//      shifted = b * max(0, (l - U) / S - f)        (if l > U + f b; zero otherwise)
//
//  which is exactly what the front-runner gains over sharing the loss pro rata. The cushion U
//  absorbs any loss up to its size: nobody loses and front-running gains nothing. See
//  audit/threat-model.md, section 5.1.
// =====================================================================================

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SpectrumFixture} from "./utils/SpectrumFixture.sol";

contract LossFrontRunningTest is SpectrumFixture {
    function setUp() public {
        _deploySystem();
    }

    /// A realised loss no larger than the surplus never lowers the index, whichever action
    /// meets it first.
    function testFuzz_lossWithinTheSurplusNeverLowersTheIndex(
        uint256 depositRaw,
        uint256 yieldRaw,
        uint256 lossRaw,
        uint8 action
    ) public {
        uint256 deposit = bound(depositRaw, 1_000e6, 600_000e6); // both mints fit the daily cap
        _mintFor(alice, deposit);
        _mintFor(bob, deposit / 3 + 1e6);
        vault.simulateYield(bound(yieldRaw, 2e6, deposit / 10));

        uint256 surplus = stabilizer.reserveValue() - token.totalSupply();
        uint256 lossAssets = bound(lossRaw, 0, surplus / SCALE - 1);
        if (lossAssets > 0) vault.simulateLoss(lossAssets);
        vm.assume(stabilizer.reserveValue() >= token.totalSupply()); // the loss fits the cushion

        uint256 indexBefore = token.index();
        uint256 which = action % 4;
        if (which == 0) {
            stabilizer.sync();
        } else if (which == 1) {
            _redeemFor(alice, token.balanceOf(alice) / 2);
        } else if (which == 2) {
            _mintFor(bob, 1_000e6);
        } else {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            try stabilizer.rebase() {} catch {} // may have nothing to distribute
        }
        assertGe(token.index(), indexBefore, "a loss inside the surplus never lowers the index");
        _assertSolvent();
    }

    /// Beyond the cushion, an early exit shifts b * ((l - U) / S - f) onto the holders who stay,
    /// to within vault rounding.
    function test_frontRunningShiftsTheExcessLossMinusTheFee() public {
        _mintFor(alice, 10_000e6);
        _mintFor(bob, 10_000e6);
        vault.simulateYield(100e6); // a cushion of about 0.5% of supply

        uint256 supply = token.totalSupply();
        uint256 reserve = stabilizer.reserveValue();
        uint256 cushion = reserve - supply;
        uint256 b = token.balanceOf(alice);
        uint256 f = stabilizer.redeemFeeRate(0); // the fixture runs at H = 0: 1 bp

        uint256 snap = vm.snapshotState();

        // A: nobody front-runs; the loss is shared pro rata.
        vault.simulateLoss(600e6); // 3% of supply
        uint256 loss = reserve - stabilizer.reserveValue(); // measured, in sUSD wei
        stabilizer.sync();
        uint256 bobShared = token.balanceOf(bob);
        uint256 aliceShared = token.balanceOf(alice);
        vm.revertToState(snap);

        // B: alice sees it coming and redeems everything first.
        uint256 paid = _redeemFor(alice, type(uint256).max);
        vault.simulateLoss(600e6);
        stabilizer.sync();
        uint256 bobAfter = token.balanceOf(bob);

        uint256 shifted = bobShared - bobAfter;
        uint256 predicted = Math.mulDiv(b, loss - cushion, supply) - Math.mulDiv(b, f, WAD);
        emit log_named_decimal_uint("cushion U (sUSD)", cushion, 18);
        emit log_named_decimal_uint("loss l (sUSD)", loss, 18);
        emit log_named_decimal_uint("shifted onto bob (sUSD)", shifted, 18);
        emit log_named_decimal_uint("predicted b((l - U)/S - f)", predicted, 18);
        uint256 aliceGain = paid * SCALE - aliceShared; // over holding through the loss
        emit log_named_decimal_uint("alice's gain over holding (sUSD)", aliceGain, 18);
        assertApproxEqAbs(shifted, predicted, 10 * SCALE, "the formula, to vault rounding");
        assertApproxEqAbs(aliceGain, shifted, 10 * SCALE, "zero-sum: her gain is what the others lose");
        _assertSolvent();
    }

    /// Inside the cushion nobody loses, and front-running only costs the front-runner the fee.
    function test_frontRunningGainsNothingInsideTheCushion() public {
        _mintFor(alice, 10_000e6);
        _mintFor(bob, 10_000e6);
        vault.simulateYield(100e6);
        uint256 bobBefore = token.balanceOf(bob);
        uint256 b = token.balanceOf(alice);

        uint256 snap = vm.snapshotState();
        vault.simulateLoss(80e6); // smaller than the cushion
        stabilizer.sync();
        assertEq(token.balanceOf(bob), bobBefore, "A: nobody loses");
        assertEq(token.balanceOf(alice), b, "A: nobody loses");
        vm.revertToState(snap);

        uint256 paid = _redeemFor(alice, type(uint256).max);
        vault.simulateLoss(80e6);
        stabilizer.sync();
        assertEq(token.balanceOf(bob), bobBefore, "B: the holder who stays loses nothing");
        assertLt(paid * SCALE, b, "B: the front-runner only paid the fee");
    }

    /// The more of the supply that leaves ahead of the loss, the larger the loss per unit for
    /// whoever stays: (l/S - U/S - f phi) / (1 - phi) for an exiting fraction phi.
    function test_lateHoldersBearAnAmplifiedLoss() public {
        address[4] memory early = [makeAddr("e1"), makeAddr("e2"), makeAddr("e3"), makeAddr("e4")];
        for (uint256 i; i < 4; ++i) {
            _mintFor(early[i], 4_500e6);
        }
        _mintFor(bob, 2_000e6); // bob holds 10% of supply
        uint256 bobBefore = token.balanceOf(bob);

        for (uint256 i; i < 4; ++i) {
            _redeemFor(early[i], type(uint256).max); // 90% of supply exits first
        }
        vault.simulateLoss(400e6); // 2% of the original supply
        stabilizer.sync();

        uint256 bobLossBps = ((bobBefore - token.balanceOf(bob)) * 10_000) / bobBefore;
        emit log_named_uint("bob's loss (bps) after 90% exited ahead of a 2% loss", bobLossBps);
        // (2% - 1 bp x 0.9) / 0.1 = 19.91%, less the mint fees left in the reserve.
        assertGt(bobLossBps, 1_900, "about ten times the pro-rata loss");
        assertLt(bobLossBps, 2_000);
        _assertSolvent();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Phase 4, B8: protocol capital.
//
//  `contributeCapital` adds reserve without minting. The amount is never distributed and nobody
//  can withdraw it; only the yield it earns is. A rebase may raise supply only up to
//  min(reserve / (1 + buffer(H)), reserve - protocolCapital). It is the first-loss cushion
//  that makes A9's loss front-running gain nothing on launch day, and it lets fees and yield
//  reach holders from day one instead of after the surplus buffer fills (D3).
// =====================================================================================

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SpectralStabilizer} from "../src/SpectralStabilizer.sol";
import {SpectrumFixture} from "./utils/SpectrumFixture.sol";

contract ProtocolCapitalTest is SpectrumFixture {
    address internal sponsor = makeAddr("sponsor");

    function setUp() public {
        _deploySystem();
    }

    function _contribute(address who, uint256 assets) internal returns (uint256 credited) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(stabilizer), assets);
        credited = stabilizer.contributeCapital(assets);
        vm.stopPrank();
    }

    function test_contributionMintsNothingAndIsRecorded() public {
        _mintFor(alice, 10_000e6);
        uint256 supply = token.totalSupply();
        uint256 reserve = stabilizer.reserveValue();
        uint256 credited = _contribute(sponsor, 500e6);
        assertEq(token.totalSupply(), supply, "no sUSD minted");
        assertEq(token.balanceOf(sponsor), 0);
        assertEq(stabilizer.protocolCapital(), credited);
        assertApproxEqAbs(credited, 500e18, SCALE, "the measured increase");
        assertApproxEqAbs(stabilizer.reserveValue(), reserve + 500e18, SCALE);
        _assertSolvent();
    }

    function test_earlierDonationsAreNotCountedAsCapital() public {
        _mintFor(alice, 10_000e6);
        usdc.mint(address(treasury), 77e6); // a donation is surplus, not capital
        uint256 credited = _contribute(sponsor, 500e6);
        assertApproxEqAbs(credited, 500e18, SCALE, "only the contribution itself");
    }

    function test_zeroContributionReverts() public {
        vm.prank(sponsor);
        vm.expectRevert(SpectralStabilizer.AmountTooSmall.selector);
        stabilizer.contributeCapital(0);
    }

    function test_contributionIsNotPausable() public {
        _mintFor(alice, 1_000e6);
        vm.prank(guardian);
        stabilizer.pause();
        assertTrue(stabilizer.paused());
        _contribute(sponsor, 100e6); // adding backing is always allowed
        assertGt(stabilizer.protocolCapital(), 0);
    }

    /// Fees and yield above the capital are distributed, step by step; the capital never is.
    function test_capitalIsNeverDistributed() public {
        _mintFor(alice, 10_000e6);
        _contribute(sponsor, 500e6); // 5% of supply: more than the 2.75% buffer
        vault.simulateYield(30e6);
        uint256 rebases;
        for (uint256 i; i < 400; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            try stabilizer.rebase() returns (bool distributed) {
                if (distributed) ++rebases;
            } catch {
                break;
            }
            assertLe(token.totalSupply() + stabilizer.protocolCapital(), stabilizer.reserveValue(), "capital intact");
        }
        assertGt(rebases, 25, "about 31 sUSD at 1 bp of supply per hour");
        uint256 left = stabilizer.reserveValue() - stabilizer.protocolCapital() - token.totalSupply();
        assertLt(left, 1e15, "everything above the capital went to holders");
    }

    /// The day-one difference (D3): without capital nothing is distributable until the surplus
    /// fills the 2.75% buffer; with it, the first fees are.
    function test_capitalLetsFeesAndYieldFlowFromDayOne() public {
        _mintFor(alice, 10_000e6);
        vault.simulateYield(10e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(SpectralStabilizer.NothingToDistribute.selector);
        stabilizer.rebase(); // 0.1% surplus is far below the buffer

        _contribute(sponsor, 500e6);
        assertTrue(stabilizer.rebase(), "with capital covering the buffer, the surplus is distributed");
    }

    function test_capitalCannotBeWithdrawnInABankRun() public {
        _mintFor(alice, 10_000e6);
        _mintFor(bob, 5_000e6);
        _contribute(sponsor, 750e6);
        _redeemFor(alice, type(uint256).max);
        _redeemFor(bob, type(uint256).max);
        assertEq(token.totalSupply(), 0, "everyone left");
        assertGe(stabilizer.reserveValue() + 2 * SCALE, 750e18, "the capital stays in the reserve");
    }

    /// A loss inside the capital lowers no balance. Distributions then pause until yield has
    /// rebuilt the capital, and resume after.
    function test_capitalAbsorbsALossBeforeHolders() public {
        _mintFor(alice, 10_000e6);
        _contribute(sponsor, 500e6);
        uint256 index0 = token.index();
        vault.simulateLoss(400e6); // 4% of supply
        stabilizer.sync();
        assertEq(token.index(), index0, "holders keep their balances");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(SpectralStabilizer.NothingToDistribute.selector);
        stabilizer.rebase();
        vault.simulateYield(450e6);
        assertTrue(stabilizer.rebase(), "resumes once the capital is rebuilt");
        _assertSolvent();
    }

    /// Beyond capital plus surplus, the remainder is shared pro rata as before.
    function test_aLossBeyondTheCushionIsSharedProRata() public {
        _mintFor(alice, 10_000e6);
        _contribute(sponsor, 500e6);
        uint256 supply = token.totalSupply();
        vault.simulateLoss(1_000e6); // 10%: twice the capital
        stabilizer.sync();
        assertEq(token.totalSupply(), stabilizer.reserveValue() - (stabilizer.reserveValue() - token.totalSupply()));
        assertApproxEqAbs(token.totalSupply(), stabilizer.reserveValue(), 1e6, "supply = reserve after the loss");
        assertLt(token.totalSupply(), supply);
        _assertSolvent();
    }

    /// A9 with the launch capital: a holder who exits ahead of a 4.9% loss gains nothing,
    /// and the holder who stays loses nothing.
    function test_frontRunningGainsNothingWithLaunchCapital() public {
        _mintFor(alice, 10_000e6);
        _mintFor(bob, 10_000e6);
        _contribute(sponsor, 1_000e6); // 5% of supply
        uint256 bobBefore = token.balanceOf(bob);
        uint256 b = token.balanceOf(alice);
        uint256 f = stabilizer.redeemFeeRate(0);

        uint256 paid = _redeemFor(alice, type(uint256).max);
        vault.simulateLoss(980e6); // 4.9% of the original supply
        stabilizer.sync();
        assertEq(token.balanceOf(bob), bobBefore, "the holder who stayed lost nothing");
        assertApproxEqAbs(paid * SCALE, b - Math.mulDiv(b, f, WAD, Math.Rounding.Ceil), SCALE, "par minus the fee");
        assertLe(paid * SCALE, b, "the early exit gained nothing over holding");
    }

    /// A pending loss is realised before the capital is counted, so capital never silently
    /// covers a loss that already belongs to holders.
    function test_contributionSyncsAPendingLossFirst() public {
        _mintFor(alice, 10_000e6);
        vault.simulateLoss(100e6);
        uint256 index0 = token.index();
        _contribute(sponsor, 500e6);
        assertLt(token.index(), index0, "the 1% loss was absorbed first");
        assertApproxEqAbs(stabilizer.protocolCapital(), 500e18, SCALE);
    }

    function testFuzz_rebaseNeverReachesTheCapital(uint256 capRaw, uint256 yieldRaw, uint256 hRaw) public {
        _mintFor(alice, 10_000e6);
        _contribute(sponsor, bound(capRaw, 1e6, 2_000e6));
        vault.simulateYield(bound(yieldRaw, 0, 500e6));
        oracle.setEntropy(bound(hRaw, 0, 1e18));
        for (uint256 i; i < 5; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            try stabilizer.rebase() {} catch {}
            assertLe(token.totalSupply() + stabilizer.protocolCapital(), stabilizer.reserveValue());
        }
        Pausable(address(stabilizer)); // silence an unused import in some compilers
    }
}

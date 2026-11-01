// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {X402SessionEscrow} from "../../../../src/vault/X402SessionEscrow.sol";
import {
    SessionGuardFixture, SessionParityWallet, SessionRotatingWallet, SessionWrappingDelegate
} from "./SessionReviewFixture.sol";

// Regression guards of the X402SessionEscrow review (audit/x402-session-escrow-review.md): each is
// its finding's PoC inverted, and passes now that the fix is in.

/// S-1: a voucher is an ECDSA signature by the session's key, and nothing else.
contract X402SessionReview_GuardS1Test is SessionGuardFixture {
    uint256 internal constant OWNER_PK = 0xB0B;

    /// RevocableVoucher.test_aSmartAccountSignerRevokesEveryVoucherTheMerchantHolds, inverted.
    function test_guardS1_aSmartAccountCannotSignVouchers() public {
        SessionRotatingWallet wallet = new SessionRotatingWallet(vm.addr(OWNER_PK));
        bytes32 id = _openFor(merchant, address(wallet), 10e6, uint64(_now() + 1 days), "g1");
        bytes memory v = _voucher(OWNER_PK, id, 1e6);
        (bool ok,) = escrow.checkVoucher(id, 1e6, v);
        assertFalse(ok, "a revocable signature is never reported valid");
        assertFalse(escrow.isVoucherSignedBy(address(wallet), id, 1e6, v));
        vm.expectRevert(X402SessionEscrow.InvalidVoucher.selector);
        escrow.redeem(id, 1e6, v);
    }

    /// RevocableVoucher.test_aBlockDependentSignerPassesTheSimulationAndBurnsTheRedemption, inverted.
    function test_guardS1_aBlockDependentSignerNeverPassesASimulation() public {
        SessionParityWallet wallet = new SessionParityWallet(vm.addr(OWNER_PK), 0, false);
        bytes32 id = _openFor(merchant, address(wallet), 10e6, uint64(_now() + 1 days), "g1-parity");
        bytes memory v = _voucher(OWNER_PK, id, 1e6);
        (bool ok,) = escrow.checkVoucher(id, 1e6, v);
        assertFalse(ok);
    }

    /// RevocableVoucher.test_aRedelegatedEoaRevokesTheVouchersItsDelegateValidated, inverted: only
    /// the account's own key signs, whatever its delegate accepts.
    function test_guardS1_aDelegatedEoaSignsWithItsOwnKeyOnly() public {
        vm.etch(agent, address(new SessionWrappingDelegate()).code);
        bytes32 id = _open(10e6, "g1-7702");
        bytes32 wrapped = keccak256(
            abi.encode(keccak256("ReplaySafe(address account,bytes32 hash)"), agent, escrow.voucherDigest(id, 1e6))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AGENT_PK, wrapped);
        (bool ok,) = escrow.checkVoucher(id, 1e6, abi.encodePacked(r, s, v));
        assertFalse(ok, "the delegate's wrapped form is not a voucher");
        bytes memory plain = _voucher(AGENT_PK, id, 1e6);
        escrow.redeem(id, 1e6, plain);
        assertEq(usdc.balanceOf(merchant), 1e6, "the account's own key signs");
    }
}

/// S-2: redeemMany pays every entry that can pay and leaves the others exactly as they were.
contract X402SessionReview_GuardS2Test is SessionGuardFixture {
    address[3] internal merchants;

    function setUp() public override {
        super.setUp();
        merchants = [makeAddr("merchant-0"), makeAddr("merchant-1"), makeAddr("merchant-2")];
    }

    function _batch() internal returns (bytes32[] memory ids, uint256[] memory cs, bytes[] memory sigs) {
        uint64 expiry = uint64(_now() + 1 days);
        ids = new bytes32[](3);
        cs = new uint256[](3);
        sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            ids[i] = _openFor(merchants[i], agent, 10e6, expiry, bytes32(i + 1));
            cs[i] = (i + 1) * 1e6;
            sigs[i] = _voucher(AGENT_PK, ids[i], cs[i]);
        }
    }

    /// BatchPoisoning.test_anAgentSettlingItsOwnSessionFirstSinksTheBatch, inverted.
    function test_guardS2_anEntrySettledFirstDoesNotSinkTheBatch() public {
        (bytes32[] memory ids, uint256[] memory cs, bytes[] memory sigs) = _batch();
        vm.prank(agent);
        escrow.redeem(ids[1], cs[1], sigs[1]);
        vm.prank(facilitator);
        escrow.redeemMany(ids, cs, sigs);
        assertEq(usdc.balanceOf(merchants[0]), cs[0]);
        assertEq(usdc.balanceOf(merchants[1]), cs[1]);
        assertEq(usdc.balanceOf(merchants[2]), cs[2]);
    }

    /// BatchPoisoning.test_aBlacklistedPayeeSinksTheBatch, inverted: the refused transfer is rolled
    /// back, its session untouched, and the same voucher pays once the payee can be paid.
    function test_guardS2_aBlacklistedPayeeIsSkippedAndItsSessionUntouched() public {
        (bytes32[] memory ids, uint256[] memory cs, bytes[] memory sigs) = _batch();
        usdc.blacklist(merchants[2]);
        escrow.redeemMany(ids, cs, sigs);
        assertEq(usdc.balanceOf(merchants[0]), cs[0]);
        assertEq(usdc.balanceOf(merchants[1]), cs[1]);
        assertEq(escrow.session(ids[2]).claimed, 0, "its claim rolled back");
        assertEq(usdc.balanceOf(address(escrow)), 30e6 - cs[0] - cs[1], "the escrow holds exactly what it owes");
        usdc.unBlacklist(merchants[2]);
        escrow.redeem(ids[2], cs[2], sigs[2]);
        assertEq(usdc.balanceOf(merchants[2]), cs[2]);
    }

    /// Closed, expired, unknown, above the deposit, not the signer's: each skipped, the live entry paid.
    function test_guardS2_everyKindOfDeadEntryIsSkipped() public {
        (bytes32[] memory ids, uint256[] memory cs, bytes[] memory sigs) = _batch();
        bytes32 brief = _openFor(merchants[0], agent, 10e6, uint64(_now() + 1 hours), "brief");
        vm.prank(merchants[1]);
        escrow.closeByPayee(ids[1], 0, "");
        bytes32[] memory all = new bytes32[](6);
        uint256[] memory amounts = new uint256[](6);
        bytes[] memory vouchers = new bytes[](6);
        (all[0], amounts[0], vouchers[0]) = (ids[0], cs[0], sigs[0]); // pays
        (all[1], amounts[1], vouchers[1]) = (ids[1], cs[1], sigs[1]); // closed by its payee
        (all[2], amounts[2], vouchers[2]) = (brief, 1e6, _voucher(AGENT_PK, brief, 1e6)); // expires below
        (all[3], amounts[3], vouchers[3]) = (keccak256("unknown"), 1e6, sigs[2]); // no such session
        (all[4], amounts[4], vouchers[4]) = (ids[2], 11e6, _voucher(AGENT_PK, ids[2], 11e6)); // above the deposit
        (all[5], amounts[5], vouchers[5]) = (ids[2], cs[2], _voucher(FUNDER_PK, ids[2], cs[2])); // not the signer's
        vm.warp(_now() + 1 hours + 1);
        escrow.redeemMany(all, amounts, vouchers);
        assertEq(usdc.balanceOf(merchants[0]), cs[0], "only the live entry paid");
        assertEq(usdc.balanceOf(merchants[2]), 0);
        assertEq(escrow.session(ids[2]).claimed, 0);
        assertEq(escrow.session(brief).claimed, 0);
    }
}

/// S-3: the id commits to the expiry, so a session of other terms cannot take the open's id.
contract X402SessionReview_GuardS3Test is SessionGuardFixture {
    /// PreemptedOpen.test_theFunderTakesTheIdWithAShortLivedSession, inverted.
    function test_guardS3_aShortLivedSessionCannotTakeTheOpensId() public {
        uint256 t0 = _now();
        GaslessOpen memory o = _gaslessOpen(uint64(t0 + 30 days), "g3", 5e6);
        uint64 oneHour = uint64(t0 + 1 hours);
        vm.prank(funder);
        bytes32 taken = escrow.open(merchant, address(usdc), agent, oneHour, "g3", 5e6);
        vm.prank(facilitator);
        bytes32 id = _submit(o);
        assertTrue(id != taken, "two sessions, two ids");
        assertEq(escrow.session(id).expiry, o.expiry, "the open's session has the open's expiry");
        bytes memory v = _voucher(AGENT_PK, id, 100);
        (bool ok,) = escrow.checkVoucher(taken, 100, v);
        assertFalse(ok, "and its vouchers are worthless on the other");
        (ok,) = escrow.checkVoucher(id, 100, v);
        assertTrue(ok);
    }
}

/// S-4: redeemable() quotes exactly what redeem() would pay.
contract X402SessionReview_GuardS4Test is SessionGuardFixture {
    /// RedeemableAboveDeposit.test_redeemableQuotesWhatRedeemRefuses, inverted.
    function test_guardS4_redeemableAgreesWithRedeem() public {
        bytes32 id = _open(1e6, "g4");
        assertEq(escrow.redeemable(id, 1e6 + 100), 0, "above the deposit redeem refuses, so 0");
        assertEq(escrow.redeemable(id, 1e6), 1e6);
        bytes memory v = _voucher(AGENT_PK, id, 4e5);
        escrow.redeem(id, 4e5, v);
        assertEq(escrow.redeemable(id, 4e5), 0);
        assertEq(escrow.redeemable(id, 5e5), 1e5);
    }
}

/// S-5: the escrow is never a session's payee.
contract X402SessionReview_GuardS5Test is SessionGuardFixture {
    /// EscrowAsPayee.test_aSessionPayingTheEscrowStrandsWhatItRedeems, inverted.
    function test_guardS5_theEscrowCannotBeThePayee() public {
        uint64 expiry = uint64(_now() + 1 days);
        vm.prank(funder);
        vm.expectRevert(bytes4(keccak256("EscrowAsPayee()")));
        escrow.open(address(escrow), address(usdc), agent, expiry, "g5", 1e6);
    }
}

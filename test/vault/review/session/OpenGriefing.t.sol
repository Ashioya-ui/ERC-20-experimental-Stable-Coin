// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {X402SessionEscrow} from "../../../../src/vault/X402SessionEscrow.sol";
import {SessionReviewFixture} from "./SessionReviewFixture.sol";

/// I-1 (Info).
///
/// A gasless open can pass the facilitator's eth_call and revert in the block it lands in, at no
/// cost to the funder beyond a signature: the funder cancels the EIP-3009 authorization (anyone may
/// submit the cancellation), or the open's expiry sits exactly on MIN_DURATION and the two seconds
/// to the next block push it under. Moving the balance away, or spending the nonce on a
/// transferWithAuthorization, do the same. The facilitator pays the gas. x402/facilitator.mjs
/// answers the first call only once the open is mined and requires expiry >= validBefore +
/// MIN_DURATION, so neither costs the merchant a served call. These tests PASS: they document
/// behaviour a facilitator must price in, not a contract bug.
contract X402SessionReview_OpenGriefingTest is SessionReviewFixture {
    function test_aCanceledAuthorizationRevertsTheOpenAfterACleanSimulation() public {
        GaslessOpen memory o = _gaslessOpen(uint64(_now() + 1 days), "i1-cancel", 5e6);
        bytes32 nonce = escrow.openNonce(o.payee, o.token, o.signer, o.expiry, o.salt);
        bytes32 cancelHash = keccak256(abi.encode(usdc.CANCEL_AUTHORIZATION_TYPEHASH(), funder, nonce));
        bytes memory cancel = _signUsdc(FUNDER_PK, cancelHash);

        uint256 snap = vm.snapshotState();
        vm.prank(facilitator);
        _submit(o);
        vm.revertToState(snap); // the simulation opens it

        usdc.cancelAuthorization(funder, nonce, cancel);
        _nextBlock();
        vm.prank(facilitator);
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        _submit(o);
    }

    function test_anExpiryOnTheMinimumPassesTheSimulationAndFailsOneBlockLater() public {
        uint64 expiry = uint64(_now() + 1 hours); // exactly MIN_DURATION at the facilitator's eth_call
        GaslessOpen memory o = _gaslessOpen(expiry, "i1-edge", 5e6);

        uint256 snap = vm.snapshotState();
        vm.prank(facilitator);
        _submit(o);
        vm.revertToState(snap);

        _nextBlock();
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.BadExpiry.selector, expiry));
        _submit(o);
    }
}

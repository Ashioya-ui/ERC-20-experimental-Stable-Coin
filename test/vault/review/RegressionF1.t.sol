// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {Mock1271Wallet} from "../mocks/VaultMocks.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";

/// Regression guard for F-1 (audit/vault-router-review.md, which this guard replaces the PoC of): the PoC inverted. It FAILS
/// against the unfixed router and PASSES once the F-1 fix is applied.
contract VaultPayRouterReview_RegressionF1Test is VaultPayRouterReviewFixture {
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("CancelIntent(address payer,bytes32 digest)");
    uint256 internal constant OWNER_PK = 0xC0FFEE;

    function _cancelSig(uint256 pk, address who, bytes32 digest) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(CANCEL_TYPEHASH, who, digest));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", router.domainSeparator(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// StaleIntent.test_aRetriedPaymentIsChargedTwice, inverted: the agent cancels attempt 1
    /// (gasless, submitted by the facilitator) and the merchant can no longer settle it.
    function test_F1_aCancelledAttemptCannotBeSettled() public {
        Mock1271Wallet wallet = new Mock1271Wallet(vm.addr(OWNER_PK));
        _deposit(vault, address(wallet), 100e6);
        vm.prank(vm.addr(OWNER_PK));
        wallet.execute(address(vault), abi.encodeCall(vault.approve, (address(router), type(uint256).max)));
        uint256 price = 20_000;
        VaultPayRouter.PayIntent memory first =
            _intentFor(address(wallet), address(vault), merchant, price, keccak256("attempt 1"));
        bytes memory firstSig = _sign(OWNER_PK, first);
        bytes32 firstDigest = router.intentDigest(first);
        VaultPayRouter.PayIntent memory retry =
            _intentFor(address(wallet), address(vault), merchant, price, keccak256("attempt 2"));
        bytes memory retrySig = _sign(OWNER_PK, retry);
        bytes memory cancelSig = _cancelSig(OWNER_PK, address(wallet), firstDigest);

        vm.prank(facilitator);
        router.cancelWithSignature(address(wallet), firstDigest, cancelSig);
        vm.prank(facilitator);
        router.pay(retry, retrySig, _noPermit());

        vm.warp(vm.getBlockTimestamp() + 30);
        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.IntentAlreadyUsed.selector, firstDigest));
        vm.prank(merchant);
        router.pay(first, firstSig, _noPermit());
        assertEq(usdc.balanceOf(merchant), price, "charged once");
    }

    /// StaleIntent.test_revokingOnlyPausesAStaleIntent, inverted: a cancel survives re-approval.
    function test_F1_aCancelSurvivesReapproval() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory stale =
            _intentFor(payer, address(vault), merchant, 1e6, keccak256("stale"));
        bytes memory staleSig = _sign(PAYER_PK, stale);
        bytes32 digest = router.intentDigest(stale);

        vm.prank(payer);
        router.cancel(digest);
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.IntentAlreadyUsed.selector, digest));
        vm.prank(merchant);
        router.pay(stale, staleSig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 0);
    }

    /// Cancellation is the payer's alone and happens once.
    function test_F1_cancelIsPayerScopedAndOneShot() public {
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("c"));
        bytes32 digest = router.intentDigest(it);
        bytes memory strangers = _cancelSig(0xB0B, payer, digest);
        bytes memory payers = _cancelSig(PAYER_PK, payer, digest);
        address stranger = makeAddr("stranger");

        vm.expectRevert(VaultPayRouter.InvalidSignature.selector);
        router.cancelWithSignature(payer, digest, strangers); // another key

        vm.prank(stranger);
        router.cancel(digest); // writes the stranger's own row only
        assertFalse(router.intentUsed(payer, digest), "a stranger cannot cancel the payer's intent");

        router.cancelWithSignature(payer, digest, payers);
        assertTrue(router.intentUsed(payer, digest));
        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.IntentAlreadyUsed.selector, digest));
        router.cancelWithSignature(payer, digest, payers); // no replay
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {Mock1271Wallet} from "../mocks/VaultMocks.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";

/// F-1 (audit/vault-router-review.md). A signed intent cannot be cancelled. When a payment does not
/// complete from the agent's point of view (the merchant withholds settlement and answers 402, or
/// the merchant gives up on a lost receipt), x402/agent.mjs retries with a fresh salt, and the first
/// intent stays live until validBefore. Whoever holds it, the merchant first of all, can settle
/// both. These tests PASS while the router has no per-intent cancellation.
contract VaultPayRouterReview_StaleIntentTest is VaultPayRouterReviewFixture {
    uint256 internal constant OWNER_PK = 0xC0FFEE;

    /// A smart-wallet payer, which must keep a standing approval: StataTokenV2's permit is
    /// ECDSA-only, and agent.mjs:231-234 refuses to sign permits for it. One request, two charges.
    function test_aRetriedPaymentIsChargedTwice() public {
        Mock1271Wallet wallet = new Mock1271Wallet(vm.addr(OWNER_PK));
        _deposit(vault, address(wallet), 100e6);
        vm.prank(vm.addr(OWNER_PK));
        wallet.execute(address(vault), abi.encodeCall(vault.approve, (address(router), type(uint256).max)));

        uint256 price = 20_000; // 0.02 USDC
        // Attempt 1 reaches the merchant, which keeps it and answers 402.
        VaultPayRouter.PayIntent memory first =
            _intentFor(address(wallet), address(vault), merchant, price, keccak256("attempt 1"));
        bytes memory firstSig = _sign(OWNER_PK, first);
        // The agent retries the request, and authorize() draws a fresh salt (agent.mjs:222).
        VaultPayRouter.PayIntent memory retry =
            _intentFor(address(wallet), address(vault), merchant, price, keccak256("attempt 2"));
        bytes memory retrySig = _sign(OWNER_PK, retry);

        vm.prank(facilitator);
        router.pay(retry, retrySig, _noPermit());
        assertEq(usdc.balanceOf(merchant), price, "the retry settles and the agent gets its 200");

        // Thirty seconds later the merchant settles attempt 1 itself. The router gives the payer
        // nothing to stop it with: no cancel, no nonce to bump.
        vm.warp(vm.getBlockTimestamp() + 30);
        vm.prank(merchant);
        router.pay(first, firstSig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 2 * price, "one request, charged twice");
    }

    /// Revoking the router is the payer's only lever, and it pauses a stale intent without killing
    /// it: the next approval, which any later payment needs, brings the stale intent back.
    function test_revokingOnlyPausesAStaleIntent() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        uint256 price = 1e6;
        VaultPayRouter.PayIntent memory stale =
            _intentFor(payer, address(vault), merchant, price, keccak256("stale"));
        bytes memory staleSig = _sign(PAYER_PK, stale);
        uint256 needed = vault.previewWithdraw(price);
        bytes32 digest = router.intentDigest(stale);

        vm.prank(payer);
        vault.approve(address(router), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, needed)
        );
        router.pay(stale, staleSig, _noPermit());
        assertFalse(router.intentUsed(payer, digest), "a failed payment leaves the intent live");

        vm.prank(payer);
        vault.approve(address(router), type(uint256).max); // to pay someone else later
        vm.prank(merchant);
        router.pay(stale, staleSig, _noPermit());
        assertEq(usdc.balanceOf(merchant), price, "the stale intent came back with the allowance");
    }

    /// An EOA is exposed up to its leftover allowance. After a 100 USDC payment with the permit
    /// agent.mjs signs (value = sharesToAuthorize, 1 bp headroom), the leftover covers several
    /// 0.001 USDC calls, and for those agent.mjs:231 attaches no permit at all.
    function test_anEoaLeftoverAllowanceCoversAStaleMicroPayment() public {
        VaultPayRouter.PayIntent memory big =
            _intentFor(payer, address(vault), makeAddr("another merchant"), 100e6, keccak256("big"));
        router.pay(big, _sign(PAYER_PK, big), _permit(PAYER_PK, vault, big.maxShares, big.validBefore));
        uint256 leftover = vault.allowance(payer, address(router));

        uint256 price = 1_000; // 0.001 USDC
        VaultPayRouter.PayIntent memory first =
            _intentFor(payer, address(vault), merchant, price, keccak256("micro 1"));
        VaultPayRouter.PayIntent memory retry =
            _intentFor(payer, address(vault), merchant, price, keccak256("micro 2"));
        assertGe(leftover, first.maxShares + retry.maxShares, "the leftover covers both attempts");

        router.pay(retry, _sign(PAYER_PK, retry), _noPermit());
        router.pay(first, _sign(PAYER_PK, first), _noPermit());
        assertEq(usdc.balanceOf(merchant), 2 * price, "charged twice out of the permit's headroom");
    }
}

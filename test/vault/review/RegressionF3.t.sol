// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {Mock1271Wallet} from "../mocks/VaultMocks.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";
import {BatchDelegate, WrappingDelegate} from "./Eip7702.t.sol";

/// Regression guard for F-3 (audit/vault-router-review.md, which this guard replaces the PoC of): the PoC inverted. It FAILS
/// against the unfixed router and PASSES once the F-3 fix is applied.
contract VaultPayRouterReview_RegressionF3Test is VaultPayRouterReviewFixture {
    uint256 internal constant OWNER_PK = 0xC0FFEE;

    /// Eip7702.test_aDelegatedEoaCannotPayWithItsOwnKey, inverted.
    function test_F3_aDelegatedEoaPaysWithItsOwnKey() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("7702"));
        bytes memory sig = _sign(PAYER_PK, it);
        vm.etch(payer, address(new BatchDelegate()).code);
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    /// Eip7702.test_aWrappingDelegateNeedsADifferentSignature, inverted: the plain signature pays.
    function test_F3_aWrappingDelegatePaysWithThePlainSignature() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("7739"));
        bytes memory sig = _sign(PAYER_PK, it);
        vm.etch(payer, address(new WrappingDelegate()).code);
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    /// The ECDSA branch opens nothing for contract wallets: a stranger's key still fails.
    function test_F3_aContractWalletStillRejectsAStrangersKey() public {
        Mock1271Wallet wallet = new Mock1271Wallet(vm.addr(OWNER_PK));
        _deposit(vault, address(wallet), 100e6);
        vm.prank(vm.addr(OWNER_PK));
        wallet.execute(address(vault), abi.encodeCall(vault.approve, (address(router), type(uint256).max)));
        VaultPayRouter.PayIntent memory it =
            _intentFor(address(wallet), address(vault), merchant, 1e6, keccak256("stranger"));
        bytes memory strangers = _sign(0xB0B, it);
        vm.expectRevert(VaultPayRouter.InvalidSignature.selector);
        router.pay(it, strangers, _noPermit());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";
import {SelfAssetVault} from "./SelfAssetVault.t.sol";

/// Regression guard for F-5 (audit/vault-router-review.md, which this guard replaces the PoC of): the PoC inverted. It FAILS
/// against the unfixed router and PASSES once the F-5 fix is applied.
contract VaultPayRouterReview_RegressionF5Test is VaultPayRouterReviewFixture {
    /// SelfAssetVault.test_aSelfReferentialVaultIsRefundedTwiceFromStrayBalance, inverted.
    function test_F5_aSelfReferentialVaultIsRefused() public {
        SelfAssetVault sv = new SelfAssetVault();
        address someoneElse = makeAddr("someone else");
        sv.mint(someoneElse, 5e6);
        vm.prank(someoneElse);
        require(sv.transfer(address(router), 5e6), "transfer failed");
        sv.mint(payer, 2e6);
        vm.prank(payer);
        sv.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(sv), merchant, 1e6, keccak256("self"));
        bytes memory sig = _sign(PAYER_PK, it);

        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.AssetIsShareToken.selector, address(sv)));
        router.pay(it, sig, _noPermit());
        assertEq(sv.balanceOf(address(router)), 5e6, "stray tokens untouched");
    }
}

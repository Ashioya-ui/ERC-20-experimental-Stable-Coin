// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {MockUSDC} from "../mocks/VaultMocks.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";
import {AssetSwitchVault} from "./AssetNotBound.t.sol";

/// Regression guard for F-2 (audit/vault-router-review.md, which this guard replaces the PoC of): AssetNotBound inverted. It needs the
/// F-2 struct (PayIntent.asset) and PASSES once the F-2 fix is applied.
contract VaultPayRouterReview_RegressionF2Test is VaultPayRouterReviewFixture {
    function test_F2_anAssetSwapAfterSigningReverts() public {
        MockUSDC lookalike = new MockUSDC();
        AssetSwitchVault hv = new AssetSwitchVault(usdc, lookalike, payer);
        usdc.mint(payer, 10e6);
        vm.startPrank(payer);
        usdc.approve(address(hv), 10e6);
        hv.deposit(10e6, payer);
        hv.approve(address(router), type(uint256).max);
        vm.stopPrank();

        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(hv), merchant, 1e6, keccak256("swap"));
        assertEq(it.asset, address(usdc), "the payer signs for USDC");
        bytes memory sig = _sign(PAYER_PK, it);
        bytes32 digest = router.intentDigest(it);

        vm.prank(payer);
        hv.setReported(address(lookalike));
        vm.expectRevert(
            abi.encodeWithSelector(VaultPayRouter.AssetMismatch.selector, address(lookalike), address(usdc))
        );
        router.pay(it, sig, _noPermit());
        assertEq(lookalike.balanceOf(merchant), 0, "no lookalike delivered");
        assertFalse(router.intentUsed(payer, digest), "nothing settled");

        // Pointed back at USDC, the same intent pays USDC, as signed.
        vm.prank(payer);
        hv.setReported(address(usdc));
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6);
    }
}

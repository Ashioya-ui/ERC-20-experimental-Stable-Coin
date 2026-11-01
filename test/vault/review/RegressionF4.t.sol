// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";

/// Regression guard for F-4 (audit/vault-router-review.md, which this guard replaces the PoC of): the PoC inverted. It FAILS
/// against the unfixed router and PASSES once the F-4 fix is applied.
contract VaultPayRouterReview_RegressionF4Test is VaultPayRouterReviewFixture {
    /// FacilitatorGrief.test_aPermitExpiringBeforeInclusionBurnsTheSubmittersGas, inverted: the
    /// facilitator's eth_call already fails, so nothing is sent; deadline = validBefore still pays.
    function test_F4_aPermitExpiringBeforeTheIntentFailsInSimulation() public {
        uint256 t0 = vm.getBlockTimestamp();
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("grief"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, it.maxShares, t0 + 1);
        vm.expectRevert(
            abi.encodeWithSelector(VaultPayRouter.PermitExpiresBeforeIntent.selector, t0 + 1, it.validBefore)
        );
        router.pay(it, sig, p);

        p = _permit(PAYER_PK, vault, it.maxShares, it.validBefore);
        router.pay(it, sig, p);
        assertEq(usdc.balanceOf(merchant), 1e6);
    }
}

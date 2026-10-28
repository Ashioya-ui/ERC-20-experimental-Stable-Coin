// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";

/// @dev A "vault" that names itself as its own asset. Withdrawing does nothing.
contract SelfAssetVault is ERC20 {
    constructor() ERC20("Self Asset Vault", "SELF") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function asset() external view returns (address) {
        return address(this);
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return 2 * assets;
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }
}

/// F-5 (audit/vault-router-review.md). With asset() == the share token, the two balance deltas the
/// router measures (lines 173 and 179) read the same balance. The payer is refunded twice, and the
/// second refund comes out of tokens someone else left in the router. This test PASSES while the
/// router accepts a vault whose asset is its own share token.
contract VaultPayRouterReview_SelfAssetVaultTest is VaultPayRouterReviewFixture {
    function test_aSelfReferentialVaultIsRefundedTwiceFromStrayBalance() public {
        SelfAssetVault sv = new SelfAssetVault();
        address someoneElse = makeAddr("someone else");
        sv.mint(someoneElse, 5e6);
        vm.prank(someoneElse);
        require(sv.transfer(address(router), 5e6), "transfer failed"); // left in the router by mistake
        sv.mint(payer, 2e6);
        vm.prank(payer);
        sv.approve(address(router), type(uint256).max);

        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(sv), merchant, 1e6, keccak256("self"));
        bytes memory sig = _sign(PAYER_PK, it);
        bytes32 digest = router.intentDigest(it);

        vm.expectEmit(address(router));
        emit VaultPayRouter.PaidFromVault(payer, merchant, digest, address(sv), 1e6, 1e6, 1e6, 1e6);
        router.pay(it, sig, _noPermit());

        assertEq(sv.balanceOf(merchant), 1e6, "merchant paid");
        assertEq(sv.balanceOf(payer), 2e6, "the payer ends where it started");
        assertEq(sv.balanceOf(address(router)), 4e6, "the payment came out of someone else's tokens");
    }
}

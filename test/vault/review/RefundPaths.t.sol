// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {MockVault} from "../mocks/VaultMocks.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";

/// @dev Delivers `bonus` more of the asset than a withdrawal asks for.
contract GenerousVault is MockVault {
    uint256 public bonus;

    constructor(IERC20 asset_) MockVault(asset_) {}

    function setBonus(uint256 bonus_) external {
        bonus = bonus_;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets + bonus, shares);
    }
}

/// @dev Quotes `extra` more shares than a withdrawal burns, which ERC-4626 allows.
contract OverquoteVault is MockVault {
    uint256 public extra;

    constructor(IERC20 asset_) MockVault(asset_) {}

    function setExtra(uint256 extra_) external {
        extra = extra_;
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil) + extra;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = _convertToShares(assets, Math.Rounding.Ceil);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }
}

/// Soundness checks, not findings (audit/vault-router-review.md, surface 4). The existing suite never
/// reaches lines 179-184 with a non-zero refund: every vault it uses burns exactly what it quotes and
/// delivers exactly what it is asked. Both refunds go to the payer, stray balances stay where they
/// are, and the return value and the event report what the payment really cost. These tests PASS
/// when the router is correct.
contract VaultPayRouterReview_RefundPathsTest is VaultPayRouterReviewFixture {
    address internal donor;

    function setUp() public override {
        super.setUp();
        donor = makeAddr("donor");
    }

    function test_extraAssetGoesBackToThePayerAndStraysStay() public {
        GenerousVault gv = new GenerousVault(usdc);
        _deposit(gv, payer, 100e6);
        _deposit(gv, donor, 10e6);
        vm.prank(donor);
        require(gv.transfer(address(router), 3e6), "transfer failed");
        usdc.mint(address(router), 7e6);
        gv.setBonus(250_000);

        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(gv), merchant, 1e6, keccak256("bonus"));
        uint256 needed = gv.previewWithdraw(1e6);
        uint256 sharesBefore = gv.balanceOf(payer);
        bytes32 digest = router.intentDigest(it);
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, gv, it.maxShares, it.validBefore);

        vm.expectEmit(address(router));
        emit VaultPayRouter.PaidFromVault(payer, merchant, digest, address(gv), 1e6, needed, 0, 250_000);
        uint256 spent = router.pay(it, sig, p);

        assertEq(spent, needed, "cost as quoted");
        assertEq(sharesBefore - gv.balanceOf(payer), needed, "and charged as reported");
        assertEq(usdc.balanceOf(merchant), 1e6, "exact price");
        assertEq(usdc.balanceOf(payer), 250_000, "the extra asset goes back to the payer");
        assertEq(gv.balanceOf(address(router)), 3e6, "stray shares untouched");
        assertEq(usdc.balanceOf(address(router)), 7e6, "stray asset untouched");
    }

    function test_overQuotedSharesGoBackAndTheCostIsWhatWasBurned() public {
        OverquoteVault ov = new OverquoteVault(usdc);
        _deposit(ov, payer, 100e6);
        _deposit(ov, donor, 10e6);
        vm.prank(donor);
        require(ov.transfer(address(router), 3e6), "transfer failed");
        ov.setExtra(7);

        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(ov), merchant, 1e6, keccak256("over"));
        uint256 quoted = ov.previewWithdraw(1e6);
        uint256 sharesBefore = ov.balanceOf(payer);
        bytes32 digest = router.intentDigest(it);
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, ov, it.maxShares, it.validBefore);

        vm.expectEmit(address(router));
        emit VaultPayRouter.PaidFromVault(payer, merchant, digest, address(ov), 1e6, quoted - 7, 7, 0);
        uint256 spent = router.pay(it, sig, p);

        assertEq(spent, quoted - 7, "the cost is what the vault burned");
        assertEq(sharesBefore - ov.balanceOf(payer), quoted - 7, "and that is all the payer gave up");
        assertEq(usdc.balanceOf(merchant), 1e6, "exact price");
        assertEq(ov.balanceOf(address(router)), 3e6, "stray shares untouched");
    }
}

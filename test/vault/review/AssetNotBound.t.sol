// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {MockUSDC} from "../mocks/VaultMocks.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";

/// @dev A 1:1 vault over USDC whose owner can repoint asset(). Once repointed, it pays out a
///      lookalike token instead of USDC.
contract AssetSwitchVault is ERC20 {
    IERC20 public immutable usdc;
    MockUSDC public immutable lookalike;
    address public immutable owner;
    address public reported;

    constructor(IERC20 usdc_, MockUSDC lookalike_, address owner_) ERC20("Switch Vault USDC", "swUSDC") {
        usdc = usdc_;
        lookalike = lookalike_;
        owner = owner_;
        reported = address(usdc_);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setReported(address asset_) external {
        require(msg.sender == owner, "not the owner");
        reported = asset_;
    }

    function asset() external view returns (address) {
        return reported;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        require(usdc.transferFrom(msg.sender, address(this), assets), "transfer failed");
        _mint(receiver, assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address holder) external returns (uint256) {
        if (msg.sender != holder) _spendAllowance(holder, msg.sender, assets);
        _burn(holder, assets);
        if (reported == address(usdc)) require(usdc.transfer(receiver, assets), "transfer failed");
        else lookalike.mint(receiver, assets);
        return assets;
    }
}

/// F-2 (audit/vault-router-review.md). The intent names the vault, not the asset. A vault the payer
/// controls answers asset() with USDC while it is checked and simulated, and with a lookalike when
/// the payment lands. pay() succeeds and emits the same PaidFromVault an honest payment emits; the
/// event has no asset field. This test PASSES while the asset is not part of the signed intent.
contract VaultPayRouterReview_AssetNotBoundTest is VaultPayRouterReviewFixture {
    function test_aPayerControlledVaultSwapsTheAssetAfterVerification() public {
        MockUSDC lookalike = new MockUSDC(); // name "USD Coin", symbol "USDC", 6 decimals
        AssetSwitchVault hv = new AssetSwitchVault(usdc, lookalike, payer); // the payer's own vault
        usdc.mint(payer, 10e6);
        vm.startPrank(payer);
        usdc.approve(address(hv), 10e6);
        hv.deposit(10e6, payer);
        hv.approve(address(router), type(uint256).max);
        vm.stopPrank();

        uint256 price = 1e6;
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(hv), merchant, price, keccak256("swap"));
        bytes memory sig = _sign(PAYER_PK, it);
        bytes32 digest = router.intentDigest(it);

        // Everything a facilitator can check says USDC: asset(), and the exact call, simulated.
        assertEq(hv.asset(), address(usdc));
        uint256 snap = vm.snapshotState();
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), price, "the simulation pays USDC");
        vm.revertToState(snap);

        // Between verify and settle: one storage write.
        vm.prank(payer);
        hv.setReported(address(lookalike));

        vm.expectEmit(address(router));
        emit VaultPayRouter.PaidFromVault(payer, merchant, digest, address(hv), price, price, 0, 0);
        router.pay(it, sig, _noPermit());

        assertEq(usdc.balanceOf(merchant), 0, "no USDC reached the merchant");
        assertEq(lookalike.balanceOf(merchant), price, "it holds a lookalike instead");
        assertEq(usdc.balanceOf(address(hv)), 10e6, "the payer's USDC never moved");
    }
}

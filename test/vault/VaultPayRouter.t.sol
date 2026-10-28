// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {VaultPayRouter} from "../../src/vault/VaultPayRouter.sol";
import {
    MockUSDC, MockVault, ShortVault, OverburnVault, ReentrantVault, Mock1271Wallet
} from "./mocks/VaultMocks.sol";

/// @dev Shared fixture: a payer holding shares of a USDC vault whose shares cost 1.05 USDC.
abstract contract VaultPayFixture is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 internal constant PAYER_PK = 0xA11CE;

    VaultPayRouter internal router;
    MockUSDC internal usdc;
    MockVault internal vault;
    address internal payer;
    address internal merchant;
    address internal facilitator;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        router = new VaultPayRouter();
        usdc = new MockUSDC();
        vault = new MockVault(usdc);
        payer = vm.addr(PAYER_PK);
        merchant = makeAddr("merchant");
        facilitator = makeAddr("facilitator");
        _deposit(vault, payer, 1_000e6);
        usdc.mint(address(vault), 50e6); // accrued yield: a share now costs 1.05 USDC
    }

    function _deposit(MockVault v, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(v), amount);
        v.deposit(amount, who);
        vm.stopPrank();
    }

    function _intent(address vault_, address payTo, uint256 assets, bytes32 salt)
        internal
        view
        returns (VaultPayRouter.PayIntent memory)
    {
        return VaultPayRouter.PayIntent({
            payer: payer,
            vault: vault_,
            payTo: payTo,
            assets: assets,
            maxShares: router.sharesToAuthorize(vault_, assets),
            salt: salt,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 60
        });
    }

    function _copy(VaultPayRouter.PayIntent memory a) internal pure returns (VaultPayRouter.PayIntent memory) {
        return VaultPayRouter.PayIntent(
            a.payer, a.vault, a.payTo, a.assets, a.maxShares, a.salt, a.validAfter, a.validBefore
        );
    }

    function _sign(uint256 pk, VaultPayRouter.PayIntent memory it) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, router.intentDigest(it));
        return abi.encodePacked(r, s, v);
    }

    function _permit(uint256 pk, MockVault v, uint256 value) internal view returns (VaultPayRouter.Permit memory p) {
        address owner = vm.addr(pk);
        uint256 deadline = block.timestamp + 60;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(router), value, v.nonces(owner), deadline));
        (p.v, p.r, p.s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", v.DOMAIN_SEPARATOR(), structHash)));
        p.value = value;
        p.deadline = deadline;
    }

    function _noPermit() internal pure returns (VaultPayRouter.Permit memory p) {}
}

contract VaultPayRouterTest is VaultPayFixture {
    // ------------------------------------------------------------------ the payment itself

    function test_pay_deliversExactPriceAndKeepsNothing() public {
        uint256 price = 50_000; // 0.05 USDC
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, price, keccak256("a"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, it.maxShares);
        uint256 needed = vault.previewWithdraw(price);
        uint256 sharesBefore = vault.balanceOf(payer);
        bytes32 digest = router.intentDigest(it);

        vm.prank(facilitator);
        uint256 spent = router.pay(it, sig, p);

        assertEq(usdc.balanceOf(merchant), price, "merchant receives exactly the price");
        assertEq(spent, needed, "costs what previewWithdraw quoted");
        assertEq(sharesBefore - vault.balanceOf(payer), needed, "payer charged exactly that");
        assertEq(vault.balanceOf(address(router)), 0, "router keeps no shares");
        assertEq(usdc.balanceOf(address(router)), 0, "router keeps no USDC");
        assertEq(usdc.balanceOf(facilitator), 0, "submitter receives nothing");
        assertTrue(router.intentUsed(payer, digest), "intent spent");
    }

    function test_pay_emitsPaidFromVault() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("e"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, it.maxShares);
        uint256 needed = vault.previewWithdraw(1e6);
        bytes32 digest = router.intentDigest(it);

        vm.expectEmit(address(router));
        emit VaultPayRouter.PaidFromVault(payer, merchant, digest, address(vault), 1e6, needed, 0, 0);
        router.pay(it, sig, p);
    }

    function test_pay_toSelfConvertsSharesToTheAsset() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), payer, 3e6, keccak256("self"));
        router.pay(it, _sign(PAYER_PK, it), _permit(PAYER_PK, vault, it.maxShares));
        assertEq(usdc.balanceOf(payer), 3e6);
    }

    function test_pay_usesAStandingAllowanceWithoutAPermit() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("n"));
        router.pay(it, _sign(PAYER_PK, it), _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    function test_pay_fromAnERC1271Wallet() public {
        uint256 ownerPk = 0xC0FFEE;
        Mock1271Wallet wallet = new Mock1271Wallet(vm.addr(ownerPk));
        _deposit(vault, address(wallet), 100e6);
        vm.prank(vm.addr(ownerPk));
        wallet.execute(address(vault), abi.encodeCall(vault.approve, (address(router), type(uint256).max)));

        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 2e6, keccak256("1271"));
        it.payer = address(wallet);
        router.pay(it, _sign(ownerPk, it), _noPermit());

        assertEq(usdc.balanceOf(merchant), 2e6);
        assertEq(vault.balanceOf(address(router)), 0);
    }

    // ------------------------------------------------------------------ authorisation

    function test_pay_rejectsReplay() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("r"));
        bytes memory sig = _sign(PAYER_PK, it);
        // A generous allowance, so that nothing but the replay guard can stop the second attempt.
        router.pay(it, sig, _permit(PAYER_PK, vault, 10 * it.maxShares));
        bytes32 digest = router.intentDigest(it);

        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.IntentAlreadyUsed.selector, digest));
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6, "paid once");
    }

    function test_pay_rejectsEveryTamperedField() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory signed = _intent(address(vault), merchant, 1e6, keccak256("t"));
        bytes memory sig = _sign(PAYER_PK, signed);
        MockVault other = new MockVault(usdc);

        VaultPayRouter.PayIntent memory t;
        t = _copy(signed);
        t.payTo = makeAddr("thief");
        _expectInvalidSignature(t, sig);
        t = _copy(signed);
        t.assets = 2e6;
        _expectInvalidSignature(t, sig);
        t = _copy(signed);
        t.maxShares += 1;
        _expectInvalidSignature(t, sig);
        t = _copy(signed);
        t.salt = keccak256("other");
        _expectInvalidSignature(t, sig);
        t = _copy(signed);
        t.validAfter -= 1;
        _expectInvalidSignature(t, sig);
        t = _copy(signed);
        t.validBefore += 1;
        _expectInvalidSignature(t, sig);
        t = _copy(signed);
        t.vault = address(other);
        _expectInvalidSignature(t, sig);
        t = _copy(signed);
        t.payer = makeAddr("someone else");
        _expectInvalidSignature(t, sig);

        router.pay(signed, sig, _noPermit()); // the intent as signed still works
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    function test_pay_rejectsAnotherKeysSignature() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("k"));
        _expectInvalidSignature(it, _sign(0xB0B, it));
    }

    function test_pay_respectsTheValidityWindow() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("w"));
        it.validAfter = block.timestamp; // valid strictly after now, so not yet
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, it.maxShares);

        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.NotYetValid.selector, it.validAfter));
        router.pay(it, sig, p);

        vm.warp(it.validBefore); // valid strictly before validBefore, so expired
        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.Expired.selector, it.validBefore));
        router.pay(it, sig, p);

        vm.warp(it.validAfter + 1);
        router.pay(it, sig, p);
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    function test_pay_failedPaymentLeavesTheIntentUnused() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("x"));
        bytes memory sig = _sign(PAYER_PK, it);
        uint256 needed = vault.previewWithdraw(1e6);
        bytes32 digest = router.intentDigest(it);

        // No permit and no allowance: the transfer fails, and with it the whole payment.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, needed)
        );
        router.pay(it, sig, _noPermit());
        assertFalse(router.intentUsed(payer, digest), "still usable");

        vm.prank(payer);
        vault.approve(address(router), needed);
        router.pay(it, sig, _noPermit()); // and it is
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    // ------------------------------------------------------------------ front-running

    function test_pay_survivesAFrontRunPermit() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("f"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, it.maxShares);

        // Someone lifts the permit out of the mempool and submits it first.
        vm.prank(makeAddr("griefer"));
        vault.permit(payer, address(router), p.value, p.deadline, p.v, p.r, p.s);

        router.pay(it, sig, p); // the permit inside now fails; the payment does not
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    function test_pay_aFrontRunSubmissionPaysExactlyAsSigned() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("s"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, it.maxShares);
        bytes32 digest = router.intentDigest(it);
        address frontRunner = makeAddr("front-runner");

        vm.prank(frontRunner);
        router.pay(it, sig, p);

        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.IntentAlreadyUsed.selector, digest));
        router.pay(it, sig, p);

        assertEq(usdc.balanceOf(merchant), 1e6, "merchant paid once, as signed");
        assertEq(usdc.balanceOf(frontRunner), 0, "the front-runner only paid the gas");
        assertEq(vault.balanceOf(frontRunner), 0);
    }

    // ------------------------------------------------------------------ the payer's protections

    function test_pay_refusesToSpendAboveTheCeiling() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("c"));
        uint256 needed = vault.previewWithdraw(1e6);
        it.maxShares = needed - 1;
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, needed);

        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.SharesAboveCeiling.selector, needed, needed - 1));
        router.pay(it, sig, p);
    }

    function test_pay_theCeilingProtectsThePayerFromALoss() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("loss"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, it.maxShares);

        usdc.burn(address(vault), usdc.balanceOf(address(vault)) / 10); // the vault loses 10% after signing
        uint256 needed = vault.previewWithdraw(1e6);
        assertGt(needed, it.maxShares, "the loss made the payment dearer than signed");

        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.SharesAboveCeiling.selector, needed, it.maxShares));
        router.pay(it, sig, p);
    }

    function test_pay_neverHandsAPayerSomeoneElsesTokens() public {
        address donor = makeAddr("donor");
        _deposit(vault, donor, 10e6);
        vm.prank(donor);
        vault.transfer(address(router), 3e6);
        usdc.mint(address(router), 7e6);

        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("stray"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, it.maxShares);
        uint256 needed = vault.previewWithdraw(1e6);
        uint256 sharesBefore = vault.balanceOf(payer);

        router.pay(it, sig, p);

        assertEq(sharesBefore - vault.balanceOf(payer), needed, "payer charged its own cost only");
        assertEq(usdc.balanceOf(payer), 0, "no stray USDC handed to the payer");
        assertEq(vault.balanceOf(address(router)), 3e6, "stray shares untouched");
        assertEq(usdc.balanceOf(address(router)), 7e6, "stray USDC untouched");
    }

    // ------------------------------------------------------------------ hostile vaults

    function test_pay_refusesAShortWithdrawal() public {
        ShortVault sv = new ShortVault(usdc);
        _deposit(sv, payer, 100e6);
        VaultPayRouter.PayIntent memory it = _intent(address(sv), merchant, 1e6, keccak256("short"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, sv, it.maxShares);

        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.ShortWithdrawal.selector, 1e6 - 1, 1e6));
        router.pay(it, sig, p);
    }

    function test_pay_aVaultCannotBurnSharesThePaymentDidNotBring() public {
        OverburnVault ov = new OverburnVault(usdc);
        _deposit(ov, payer, 100e6);
        address donor = makeAddr("donor");
        _deposit(ov, donor, 10e6);
        vm.prank(donor);
        ov.transfer(address(router), 5e6); // shares left in the router by someone else
        ov.setExtra(5e6); // which the vault will try to burn as well

        VaultPayRouter.PayIntent memory it = _intent(address(ov), merchant, 1e6, keccak256("over"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, ov, it.maxShares);

        vm.expectRevert(stdError.arithmeticError);
        router.pay(it, sig, p);
    }

    function test_pay_blocksReentry() public {
        ReentrantVault rv = new ReentrantVault(usdc);
        rv.setRouter(router);
        _deposit(rv, payer, 100e6);
        VaultPayRouter.PayIntent memory it = _intent(address(rv), merchant, 1e6, keccak256("re"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, rv, it.maxShares);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.pay(it, sig, p);
    }

    // ------------------------------------------------------------------ argument checks

    function test_pay_rejectsInvalidRecipients() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        address[3] memory bad = [address(0), address(router), address(vault)];
        for (uint256 i; i < bad.length; ++i) {
            VaultPayRouter.PayIntent memory it = _intent(address(vault), bad[i], 1e6, bytes32(i));
            bytes memory sig = _sign(PAYER_PK, it);
            vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.InvalidPayTo.selector, bad[i]));
            router.pay(it, sig, _noPermit());
        }
    }

    function test_pay_rejectsAZeroPrice() public {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 0, keccak256("z"));
        bytes memory sig = _sign(PAYER_PK, it);
        vm.expectRevert(VaultPayRouter.ZeroAmount.selector);
        router.pay(it, sig, _noPermit());
    }

    // ------------------------------------------------------------------ views

    function test_sharesToAuthorize_coversTodayWithOneBasisPoint() public view {
        uint256 cost = vault.previewWithdraw(1e6);
        uint256 ceiling = router.sharesToAuthorize(address(vault), 1e6);
        assertEq(router.sharesFor(address(vault), 1e6), cost);
        assertGe(ceiling, cost);
        assertLe(ceiling, cost + cost / 10_000 + 1);
    }

    function test_domainSeparator_isStandardEIP712() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("VaultPayRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
        assertEq(router.domainSeparator(), expected);
    }

    /// @dev What an off-chain signer (the agent client) computes must equal what the router checks.
    function test_intentDigest_matchesTheTypedDataSpec() public view {
        VaultPayRouter.PayIntent memory it = _intent(address(vault), merchant, 1e6, keccak256("d"));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PayIntent(address payer,address vault,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
                ),
                it.payer,
                it.vault,
                it.payTo,
                it.assets,
                it.maxShares,
                it.salt,
                it.validAfter,
                it.validBefore
            )
        );
        assertEq(router.PAY_INTENT_TYPEHASH(), keccak256(
            "PayIntent(address payer,address vault,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
        ));
        assertEq(
            router.intentDigest(it), keccak256(abi.encodePacked("\x19\x01", router.domainSeparator(), structHash))
        );
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Any deposit, any accrued yield, any affordable price: the merchant gets exactly the
    ///      price, the router ends empty, and the payer gives up the price plus at most the
    ///      rounding the vault keeps on a withdrawal.
    function testFuzz_pay_exactEmptyAndConserving(uint256 deposit, uint256 accrued, uint256 price) public {
        deposit = bound(deposit, 1e6, 1e15);
        accrued = bound(accrued, 0, deposit);
        MockVault v = new MockVault(usdc);
        _deposit(v, payer, deposit);
        usdc.mint(address(v), accrued);
        price = bound(price, 1, v.maxWithdraw(payer));

        VaultPayRouter.PayIntent memory it =
            _intent(address(v), merchant, price, keccak256(abi.encode(deposit, accrued, price)));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, v, it.maxShares);
        uint256 valueBefore = v.convertToAssets(v.balanceOf(payer)) + usdc.balanceOf(payer);
        uint256 merchantBefore = usdc.balanceOf(merchant);

        router.pay(it, sig, p);

        assertEq(usdc.balanceOf(merchant) - merchantBefore, price, "exact");
        assertEq(v.balanceOf(address(router)), 0, "no shares left behind");
        assertEq(usdc.balanceOf(address(router)), 0, "no asset left behind");
        uint256 valueAfter = v.convertToAssets(v.balanceOf(payer)) + usdc.balanceOf(payer);
        assertGe(valueBefore + 2, valueAfter + price, "payer gave up at least the price, less rounding");
        assertLe(valueBefore, valueAfter + price + v.convertToAssets(1) + 2, "and at most a share's rounding more");
    }

    // ------------------------------------------------------------------ helpers

    function _expectInvalidSignature(VaultPayRouter.PayIntent memory it, bytes memory sig) internal {
        vm.expectRevert(VaultPayRouter.InvalidSignature.selector);
        router.pay(it, sig, _noPermit());
    }
}

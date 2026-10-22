// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Phase 6: the sUSD-to-USDC pay router (src/periphery/SpectrumPayRouter.sol).
//
//  An agent keeps its working balance in sUSD and signs one EIP-3009 receive authorization;
//  a facilitator submits it; the merchant gets exactly the USDC price; the agent gets all the
//  change back; the router keeps nothing. Every way of misusing the signed authorization
//  (another recipient, another price, a replay, an expired window, too little value) must
//  move nothing and leave the authorization usable.
// =====================================================================================

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpectralToken} from "../../src/SpectralToken.sol";
import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";
import {AutonomousTreasury} from "../../src/AutonomousTreasury.sol";
import {SpectrumPayRouter} from "../../src/periphery/SpectrumPayRouter.sol";
import {SpectrumFixture} from "../utils/SpectrumFixture.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";

contract SpectrumPayRouterTest is SpectrumFixture {
    SpectrumPayRouter internal router;

    uint256 internal constant AGENT_PK = 0xA11CE;
    address internal agent;
    address internal merchant = makeAddr("merchant");
    address internal facilitator = makeAddr("facilitator");
    address internal attacker = makeAddr("attacker");

    struct Payment {
        address from;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        address payTo;
        uint256 assets;
        bytes32 salt;
        bytes signature;
    }

    function setUp() public {
        liquidityBufferBps = 1_000; // 10% idle
        _deploySystem();
        oracle.setEntropy(0.5e18);
        router = new SpectrumPayRouter(stabilizer);
        agent = vm.addr(AGENT_PK);
        _mintFor(agent, 1_000e6); // about 999.3 sUSD
        _mintFor(bob, 9_000e6); // other holders, so the agent is not the whole supply
    }

    // ------------------------------------------------------------------------------ helpers

    function _digest(address from, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, address(router), value, validAfter, validBefore, nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    /// The agent's signed intent: pay `assets` USDC to `payTo`, authorising `value` sUSD.
    function _signed(uint256 pk, address from, address payTo, uint256 assets, uint256 value, bytes32 salt)
        internal
        view
        returns (Payment memory p)
    {
        p = Payment(from, value, block.timestamp - 1, block.timestamp + 60, payTo, assets, salt, "");
        bytes32 nonce = router.intentNonce(payTo, assets, salt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(from, value, p.validAfter, p.validBefore, nonce));
        p.signature = abi.encodePacked(r, s, v);
    }

    function _intent(address payTo, uint256 assets) internal view returns (Payment memory) {
        return _signed(AGENT_PK, agent, payTo, assets, router.sUSDToAuthorize(assets), keccak256("salt-1"));
    }

    function _submit(Payment memory p) internal returns (uint256) {
        vm.prank(facilitator); // anyone may submit; the facilitator pays the gas
        return router.pay(p.from, p.value, p.validAfter, p.validBefore, p.payTo, p.assets, p.salt, p.signature);
    }

    /// A copy: `Payment memory q = p` would alias the same struct.
    function _copy(Payment memory p) internal pure returns (Payment memory) {
        return Payment(p.from, p.value, p.validAfter, p.validBefore, p.payTo, p.assets, p.salt, p.signature);
    }

    function _used(Payment memory p) internal view returns (bool) {
        return token.authorizationState(p.from, router.intentNonce(p.payTo, p.assets, p.salt));
    }

    function _assertRouterEmpty() internal view {
        assertEq(token.balanceOf(address(router)), 0, "router keeps no sUSD");
        assertEq(usdc.balanceOf(address(router)), 0, "router keeps no USDC");
    }

    // ------------------------------------------------------------------------------ happy path

    function test_paysTheExactPriceAndReturnsTheChange() public {
        uint256 assets = 5e6; // $5
        Payment memory p = _intent(merchant, assets);
        uint256 sUSDBefore = token.balanceOf(agent);
        uint256 needed = router.sUSDFor(assets);

        uint256 redeemed = _submit(p);

        assertEq(redeemed, needed, "redeems exactly what the current fee needs");
        assertEq(usdc.balanceOf(merchant), assets, "merchant gets exactly the price");
        assertApproxEqAbs(sUSDBefore - token.balanceOf(agent), redeemed, 2, "payer spends only what was redeemed");
        assertLe(usdc.balanceOf(agent), 1, "at most one USDC unit of change, returned");
        assertEq(token.balanceOf(facilitator), 0);
        assertTrue(_used(p));
        _assertRouterEmpty();
        _assertSolvent();
        // the fee is the stabilizer's redemption fee and nothing else
        assertApproxEqRel(redeemed, assets * SCALE, 0.000_33e18, "3.25 bp at neutral H, within rounding");
    }

    function test_payerCanConvertForItself() public {
        Payment memory p = _intent(agent, 20e6);
        _submit(p);
        assertGe(usdc.balanceOf(agent), 20e6, "the payer receives the USDC (and any change)");
        _assertRouterEmpty();
    }

    function test_smartAccountPayerSignsWithItsOwnerKey() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(agent);
        vm.prank(agent);
        token.transfer(address(wallet), 100e18);
        uint256 assets = 7e6;
        Payment memory p =
            _signed(AGENT_PK, address(wallet), merchant, assets, router.sUSDToAuthorize(assets), bytes32("w"));
        _submit(p);
        assertEq(usdc.balanceOf(merchant), assets);
        assertGt(token.balanceOf(address(wallet)), 92e18, "the change went back to the smart account");
        _assertRouterEmpty();
    }

    // ------------------------------------------------------------------------------ misuse moves nothing

    function test_changingTheRecipientPriceOrSaltBreaksTheSignature() public {
        Payment memory p = _intent(merchant, 5e6);
        uint256 before = token.balanceOf(agent);

        Payment memory q = _copy(p);
        q.payTo = attacker;
        vm.expectRevert(SpectralToken.InvalidSignature.selector);
        _submit(q);

        q = _copy(p);
        q.assets = 4e6;
        vm.expectRevert(SpectralToken.InvalidSignature.selector);
        _submit(q);

        q = _copy(p);
        q.salt = keccak256("other");
        vm.expectRevert(SpectralToken.InvalidSignature.selector);
        _submit(q);

        q = _copy(p);
        q.value = p.value * 2; // a larger value than signed
        vm.expectRevert(SpectralToken.InvalidSignature.selector);
        _submit(q);

        assertEq(token.balanceOf(agent), before, "nothing moved");
        assertEq(usdc.balanceOf(attacker), 0);
        assertFalse(_used(p), "and the real authorization is still usable");
        _submit(p);
        assertEq(usdc.balanceOf(merchant), 5e6);
    }

    function test_aTransferAuthorizationCannotBeUsedAsAReceive() public {
        // The payer signs a plain transferWithAuthorization to the router with the intent nonce:
        // the router only accepts receive authorizations, so it cannot be submitted through pay.
        uint256 assets = 5e6;
        uint256 value = router.sUSDToAuthorize(assets);
        bytes32 nonce = router.intentNonce(merchant, assets, bytes32("s"));
        bytes32 structHash = keccak256(
            abi.encode(
                token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
                agent,
                address(router),
                value,
                block.timestamp - 1,
                block.timestamp + 60,
                nonce
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(AGENT_PK, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
        vm.expectRevert(SpectralToken.InvalidSignature.selector);
        vm.prank(facilitator);
        router.pay(
            agent,
            value,
            block.timestamp - 1,
            block.timestamp + 60,
            merchant,
            assets,
            bytes32("s"),
            abi.encodePacked(r, s, v)
        );
    }

    function test_replayIsRejected() public {
        Payment memory p = _intent(merchant, 5e6);
        _submit(p);
        vm.expectRevert(SpectralToken.AuthorizationAlreadyUsed.selector);
        _submit(p);
        assertEq(usdc.balanceOf(merchant), 5e6, "paid once");
    }

    function test_timeWindowIsEnforced() public {
        Payment memory p = _intent(merchant, 5e6);
        vm.warp(p.validBefore);
        vm.expectRevert(SpectralToken.AuthorizationExpired.selector);
        _submit(p);

        vm.warp(1_800_000_000);
        p = _intent(merchant, 5e6);
        p.validAfter = block.timestamp + 10; // re-sign with a future start
        bytes32 nonce = router.intentNonce(p.payTo, p.assets, p.salt);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(AGENT_PK, _digest(agent, p.value, p.validAfter, p.validBefore, nonce));
        p.signature = abi.encodePacked(r, s, v);
        vm.expectRevert(SpectralToken.AuthorizationNotYetValid.selector);
        _submit(p);
    }

    function test_tooLittleValueRevertsAndTheAuthorizationStaysUsable() public {
        uint256 assets = 5e6;
        uint256 needed = router.sUSDFor(assets);
        Payment memory p = _signed(AGENT_PK, agent, merchant, assets, needed - 1, bytes32("x"));
        vm.expectRevert(abi.encodeWithSelector(SpectrumPayRouter.AuthorizationTooSmall.selector, needed, needed - 1));
        _submit(p);
        assertFalse(_used(p));
        assertEq(usdc.balanceOf(merchant), 0);
    }

    function test_recipientGuards() public {
        address[5] memory bad = [address(0), address(router), address(stabilizer), address(treasury), address(token)];
        for (uint256 i; i < bad.length; ++i) {
            Payment memory p = _intent(bad[i], 5e6);
            vm.expectRevert(abi.encodeWithSelector(SpectrumPayRouter.InvalidPayTo.selector, bad[i]));
            _submit(p);
        }
        Payment memory z = _intent(merchant, 0);
        vm.expectRevert(SpectrumPayRouter.ZeroAmount.selector);
        _submit(z);
    }

    // ------------------------------------------------------------------------------ the world moves

    /// The amount `sUSDToAuthorize` returns covers the price at any H, so a fee move between
    /// signing and settlement never makes the payment fail; the merchant still gets exactly
    /// the price and the payer only pays the fee in force at settlement.
    function testFuzz_authorizedValueCoversAnyFeeAtSettlement(uint256 hAtSign, uint256 hAtSettle, uint256 assets)
        public
    {
        oracle.setEntropy(bound(hAtSign, 0, 1e18));
        assets = bound(assets, 1, 900e6);
        Payment memory p = _intent(merchant, assets);
        oracle.setEntropy(bound(hAtSettle, 0, 1e18));
        uint256 needed = router.sUSDFor(assets);
        uint256 before = token.balanceOf(agent);
        _submit(p);
        assertEq(usdc.balanceOf(merchant), assets, "exactly the price");
        assertApproxEqAbs(before - token.balanceOf(agent), needed, 2, "only what the fee at settlement needs");
        _assertRouterEmpty();
        _assertSolvent();
    }

    function test_microPaymentRedeemsTheMinimumAndReturnsUsdcChange() public {
        uint256 assets = 1_000; // $0.001, a typical x402 micro-price
        assertEq(router.sUSDFor(assets), stabilizer.minAmount(), "below the minimum, the minimum is redeemed");
        Payment memory p = _intent(merchant, assets);
        _submit(p);
        assertEq(usdc.balanceOf(merchant), assets);
        assertApproxEqAbs(usdc.balanceOf(agent), 10_000 - 1_000 - 4, 4, "about $0.009 of USDC change");
        _assertRouterEmpty();
    }

    function test_cashCrunchRevertsAndThePaymentGoesThroughLater() public {
        _mintFor(agent, 5_000e6); // reserve $15,000, so about $1,500 sits idle
        uint256 assets = 3_000e6; // more than the idle buffer: the vault must pay the rest
        Payment memory p = _intent(merchant, assets);
        vault.setLiquidityCap(0); // the vault's market pays nothing today
        vm.expectRevert(abi.encodeWithSelector(AutonomousTreasury.InsufficientLiquidity.selector, treasury.idleAssets()));
        _submit(p);
        assertFalse(_used(p), "the authorization is still usable");
        vault.setLiquidityCap(type(uint256).max);
        _submit(p);
        assertEq(usdc.balanceOf(merchant), assets);
        _assertRouterEmpty();
    }

    function test_pendingLossIsAbsorbedBeforeMeasuring() public {
        uint256 assets = 50e6;
        Payment memory p = _intent(merchant, assets);
        vault.simulateLoss(vault.totalAssets() / 10); // a 10% vault loss nobody has synced yet
        uint256 idx = token.index();
        _submit(p);
        assertLt(token.index(), idx, "the loss was absorbed");
        assertEq(usdc.balanceOf(merchant), assets, "and the merchant still gets exactly the price");
        _assertRouterEmpty();
        _assertSolvent();
    }

    function test_rebaseBetweenSigningAndSettlement() public {
        Payment memory p = _intent(merchant, 5e6);
        vault.simulateYield(500e6);
        uint256 idx = token.index();
        stabilizer.rebase(); // the first rebase needs no interval
        assertGt(token.index(), idx, "balances grew after the agent signed");
        _submit(p);
        assertEq(usdc.balanceOf(merchant), 5e6);
        _assertRouterEmpty();
    }

    /// Whatever sits in the router (a mistaken transfer) goes to the next payer, so it never
    /// accumulates and nobody can lock value in it.
    function testFuzz_routerEndsEveryPaymentEmpty(uint256 assets, uint256 strayUsdc, uint256 straySUSD) public {
        assets = bound(assets, 1, 100e6);
        strayUsdc = bound(strayUsdc, 0, 1_000e6);
        straySUSD = bound(straySUSD, 0, 100e18);
        usdc.mint(address(router), strayUsdc);
        vm.prank(bob);
        token.transfer(address(router), straySUSD);
        Payment memory p = _intent(merchant, assets);
        _submit(p);
        assertEq(usdc.balanceOf(merchant), assets);
        _assertRouterEmpty();
    }
}

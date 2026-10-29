// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {X402SessionEscrow} from "../../../../src/vault/X402SessionEscrow.sol";
import {
    FiatTokenV22Mock, SessionFeeToken, SessionReentrantToken, SessionReviewFixture
} from "./SessionReviewFixture.sol";

/// The NatSpec's claims, and the surfaces that hold, checked directly: what the fixes must not
/// change.
contract X402SessionReview_SoundnessTest is SessionReviewFixture {
    /// redeem works at t == expiry and not after; reclaim works after and not at; the funder has no
    /// way to the deposit before expiry.
    function test_expiryEdges_andNoEarlyExitForTheFunder() public {
        uint64 expiry = uint64(_now() + 1 days);
        bytes32 id = _openFor(merchant, agent, 10e6, expiry, "edges");
        bytes memory v1 = _voucher(AGENT_PK, id, 1e6);
        bytes memory v2 = _voucher(AGENT_PK, id, 2e6);

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.NotPayee.selector, funder));
        escrow.closeByPayee(id, 0, "");

        vm.warp(expiry);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.NotExpired.selector, id, expiry));
        escrow.reclaim(id);
        (bool ok,) = escrow.checkVoucher(id, 1e6, v1);
        assertTrue(ok, "valid at t == expiry");
        escrow.redeem(id, 1e6, v1);

        vm.warp(uint256(expiry) + 1);
        (ok,) = escrow.checkVoucher(id, 2e6, v2);
        assertFalse(ok, "invalid one second later");
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.SessionExpired.selector, id));
        escrow.redeem(id, 2e6, v2);
        escrow.reclaim(id);
        assertEq(usdc.balanceOf(merchant), 1e6);
        assertEq(usdc.balanceOf(funder), 1_000e6 - 1e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// A redeemed voucher never pays again, not even after a top-up lifts the deposit above it.
    function test_anOldVoucherNeverCountsTwice_evenAfterATopUp() public {
        bytes32 id = _open(5e6, "twice");
        bytes memory v3 = _voucher(AGENT_PK, id, 3e6);
        bytes memory v8 = _voucher(AGENT_PK, id, 8e6);
        escrow.redeem(id, 3e6, v3);
        vm.prank(funder);
        escrow.topUp(id, 5e6);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.NothingNew.selector, uint256(3e6), uint256(3e6)));
        escrow.redeem(id, 3e6, v3);
        escrow.redeem(id, 8e6, v8);
        assertEq(usdc.balanceOf(merchant), 8e6, "exactly the highest voucher, once");
    }

    /// A stolen signer key overpays each session's own payee, up to that session's deposit, and
    /// reaches nothing else: the thief gets nothing; the funder's exposure is those deposits.
    function test_aStolenSignerKeyPaysOnlyEachSessionsOwnPayee() public {
        address other = makeAddr("other merchant");
        bytes32 a = _open(3e6, "key-a");
        bytes32 b = _openFor(other, agent, 4e6, uint64(_now() + 1 days), "key-b");
        bytes memory va = _voucher(AGENT_PK, a, 3e6);
        bytes memory vb = _voucher(AGENT_PK, b, 4e6);
        address thief = vm.addr(AGENT_PK);
        vm.startPrank(thief);
        escrow.redeem(a, 3e6, va);
        escrow.redeem(b, 4e6, vb);
        vm.stopPrank();
        assertEq(usdc.balanceOf(thief), 0);
        assertEq(usdc.balanceOf(merchant), 3e6);
        assertEq(usdc.balanceOf(other), 4e6);
        assertEq(usdc.balanceOf(funder), 1_000e6 - 7e6);
    }

    /// The escrow has one address on every chain; a voucher's domain carries the chain id, so it
    /// pays only on the chain it was signed for.
    function test_aVoucherDoesNotReplayOnAnotherChain() public {
        bytes32 id = _open(10e6, "chain");
        bytes memory v = _voucher(AGENT_PK, id, 1e6);
        // vm.getChainId(), not block.chainid: under via-IR the optimizer may re-read CHAINID after
        // vm.chainId() below, and `home` would then be the other chain.
        uint256 home = vm.getChainId();
        vm.chainId(home + 1);
        vm.expectRevert(X402SessionEscrow.InvalidVoucher.selector);
        escrow.redeem(id, 1e6, v);
        vm.chainId(home);
        escrow.redeem(id, 1e6, v);
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    /// The gasless open binds every term: the open nonce carries payee, token, signer, expiry and
    /// salt; USDC's signature carries funder, escrow, amount and window. Alter any one and it fails.
    function test_theOpenAuthorizationBindsEveryTerm() public {
        GaslessOpen memory o = _gaslessOpen(uint64(_now() + 1 days), "bind", 2e6);
        address other = makeAddr("other");
        address otherToken = address(new FiatTokenV22Mock());
        for (uint256 term; term < 8; ++term) {
            GaslessOpen memory altered = _alter(o, term, other, otherToken);
            vm.prank(facilitator);
            vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
            _submit(altered);
        }
        vm.prank(facilitator);
        bytes32 id = _submit(o);
        assertEq(escrow.session(id).deposited, 2e6, "the open as signed goes through");
    }

    /// @dev `o` with one term changed: payee, token, signer, expiry, salt, amount, window or funder.
    function _alter(GaslessOpen memory o, uint256 term, address other, address otherToken)
        internal
        pure
        returns (GaslessOpen memory a)
    {
        a.funder = o.funder;
        a.payee = o.payee;
        a.token = o.token;
        a.signer = o.signer;
        a.expiry = o.expiry;
        a.salt = o.salt;
        a.amount = o.amount;
        a.validAfter = o.validAfter;
        a.validBefore = o.validBefore;
        a.authorization = o.authorization;
        if (term == 0) a.payee = other;
        else if (term == 1) a.token = otherToken;
        else if (term == 2) a.signer = other;
        else if (term == 3) a.expiry = o.expiry + 1;
        else if (term == 4) a.salt = "bind-2";
        else if (term == 5) a.amount = o.amount + 1;
        else if (term == 6) a.validBefore = o.validBefore + 1;
        else a.funder = other;
    }

    /// Anyone who sees the authorization can submit it first: the session opens exactly as signed,
    /// the facilitator's copy reverts early and cheaply, and the racer gains nothing.
    function test_aRacedOpenIsTheSameSession() public {
        GaslessOpen memory o = _gaslessOpen(uint64(_now() + 1 days), "race", 2e6);
        address racer = makeAddr("racer");
        vm.prank(racer);
        bytes32 id = _submit(o);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.SessionExists.selector, id));
        _submit(o);
        X402SessionEscrow.Session memory s = escrow.session(id);
        assertEq(s.funder, funder);
        assertEq(s.payee, merchant);
        assertEq(s.signer, agent);
        assertEq(s.deposited, 2e6);
        assertEq(s.expiry, o.expiry);
        assertEq(usdc.balanceOf(racer), 0);
    }

    /// A top-up authorization is bound to its session; a third party's top-up belongs to the
    /// session, so what is unclaimed of it goes to the funder.
    function test_aTopUpAuthorizationIsBoundToItsSession() public {
        uint256 t0 = _now();
        bytes32 a = _open(1e6, "top-a");
        bytes32 b = _open(1e6, "top-b");
        uint256 donorPk = 0xD0;
        address donor = vm.addr(donorPk);
        usdc.mint(donor, 5e6);
        bytes32 nonce = escrow.topUpNonce(a, "t");
        bytes memory auth = _receiveAuth(donorPk, 5e6, t0 - 600, t0 + 60, nonce);
        vm.prank(facilitator);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        escrow.topUpWithAuthorization(b, donor, 5e6, t0 - 600, t0 + 60, "t", auth);
        vm.prank(facilitator);
        escrow.topUpWithAuthorization(a, donor, 5e6, t0 - 600, t0 + 60, "t", auth);
        assertEq(escrow.session(a).deposited, 6e6);
        vm.warp(t0 + 1 days + 1);
        escrow.reclaim(a);
        assertEq(usdc.balanceOf(funder), 1_000e6 - 2e6 + 6e6, "the donor's 5 USDC came home to the funder");
        assertEq(usdc.balanceOf(donor), 0);
    }

    /// Every state-changing entry point is nonReentrant: a token that calls back into the escrow in
    /// the middle of a payout is refused, and the payout with it.
    function test_aTokenHookCannotReenter() public {
        SessionReentrantToken hook = new SessionReentrantToken();
        hook.mint(funder, 10e6);
        uint64 expiry = uint64(_now() + 1 days);
        vm.startPrank(funder);
        hook.approve(address(escrow), type(uint256).max);
        bytes32 id = escrow.open(merchant, address(hook), agent, expiry, "hook", 10e6);
        vm.stopPrank();
        bytes memory v = _voucher(AGENT_PK, id, 1e6);
        hook.arm(merchant, address(escrow), abi.encodeWithSelector(escrow.reclaim.selector, id));
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        escrow.redeem(id, 1e6, v);
        assertEq(hook.balanceOf(merchant), 0);
    }

    /// A fee-on-transfer token cannot open: the deposit must arrive exactly.
    function test_aFeeOnTransferTokenCannotOpen() public {
        SessionFeeToken fee = new SessionFeeToken();
        fee.mint(funder, 10e6);
        uint64 expiry = uint64(_now() + 1 days);
        vm.startPrank(funder);
        fee.approve(address(escrow), type(uint256).max);
        vm.expectRevert(X402SessionEscrow.InexactTransfer.selector);
        escrow.open(merchant, address(fee), agent, expiry, "fee", 10e6);
        vm.stopPrank();
    }

    /// Amounts are held in uint128: a deposit that would not fit is refused before any transfer.
    function test_aDepositAboveUint128IsRefused() public {
        uint256 huge = uint256(type(uint128).max) + 1;
        usdc.mint(funder, huge);
        uint64 expiry = uint64(_now() + 1 days);
        vm.prank(funder);
        vm.expectRevert(X402SessionEscrow.AmountOverflow.selector);
        escrow.open(merchant, address(usdc), agent, expiry, "huge", huge);
    }

    /// closeByPayee with a final voucher that someone already redeemed still closes, without
    /// reverting and without paying twice.
    function test_closeByPayeeAfterItsVoucherWasRedeemed() public {
        bytes32 id = _open(10e6, "close-race");
        bytes memory v = _voucher(AGENT_PK, id, 7e6);
        escrow.redeem(id, 7e6, v); // the facilitator's redemption lands first
        vm.prank(merchant);
        escrow.closeByPayee(id, 7e6, v);
        assertEq(usdc.balanceOf(merchant), 7e6);
        assertEq(usdc.balanceOf(funder), 1_000e6 - 7e6);
        assertTrue(escrow.session(id).closed);
    }
}

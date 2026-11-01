// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {X402SessionEscrow} from "../../../../src/vault/X402SessionEscrow.sol";
import {SessionReviewFixture} from "./SessionReviewFixture.sol";

/// I-2 (Info).
///
/// What each of Circle's controls does to a session. These tests PASS against the escrow as it is
/// and with the review's patch: they document outcomes a merchant and a funder take on by using
/// USDC, which the escrow neither can nor should route around.
contract X402SessionReview_UsdcControlsTest is SessionReviewFixture {
    /// A blacklisted payee cannot be paid: its vouchers are worthless while the blacklisting lasts,
    /// and checkVoucher does not see it (simulate redeem instead). The deposit is not stuck: the
    /// payee can release it at once, and the funder reclaims it at expiry. Lifted before expiry, the
    /// same vouchers pay.
    function test_aBlacklistedPayee() public {
        bytes32 id = _open(10e6, "i2-payee");
        bytes memory v = _voucher(AGENT_PK, id, 4e6);
        usdc.blacklist(merchant);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        escrow.redeem(id, 4e6, v);
        (bool ok,) = escrow.checkVoucher(id, 4e6, v);
        assertTrue(ok, "checkVoucher does not see the token's controls");

        usdc.unBlacklist(merchant);
        escrow.redeem(id, 4e6, v);
        assertEq(usdc.balanceOf(merchant), 4e6);

        usdc.blacklist(merchant);
        vm.prank(merchant);
        escrow.closeByPayee(id, 0, "");
        assertEq(usdc.balanceOf(funder), 1_000e6 - 4e6, "the rest goes home at once");
    }

    /// A blacklisted funder can still be paid out of (redeem works) but not refunded: closeByPayee
    /// reverts on its refund leg even with a final voucher, so the payee settles with redeem; reclaim
    /// reverts, and the unclaimed rest stays in the escrow while the blacklisting lasts.
    function test_aBlacklistedFunder() public {
        uint64 expiry = uint64(_now() + 1 days);
        bytes32 id = _openFor(merchant, agent, 10e6, expiry, "i2-funder");
        bytes memory v3 = _voucher(AGENT_PK, id, 3e6);
        bytes memory v5 = _voucher(AGENT_PK, id, 5e6);
        usdc.blacklist(funder);
        vm.prank(merchant);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        escrow.closeByPayee(id, 3e6, v3);
        escrow.redeem(id, 5e6, v5);
        assertEq(usdc.balanceOf(merchant), 5e6, "the payee settles with redeem instead");
        vm.warp(uint256(expiry) + 1);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        escrow.reclaim(id);
        assertEq(usdc.balanceOf(address(escrow)), 5e6, "frozen with the funder");
    }

    /// A pause that outlasts the session voids every voucher the merchant held: nothing redeems
    /// while paused, and after expiry only reclaim works.
    function test_aPauseThatSpansExpiry() public {
        uint64 expiry = uint64(_now() + 1 days);
        bytes32 id = _openFor(merchant, agent, 10e6, expiry, "i2-pause");
        bytes memory v = _voucher(AGENT_PK, id, 4e6);
        usdc.pause();
        vm.expectRevert(bytes("Pausable: paused"));
        escrow.redeem(id, 4e6, v);
        vm.warp(uint256(expiry) + 1);
        usdc.unpause();
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.SessionExpired.selector, id));
        escrow.redeem(id, 4e6, v);
        escrow.reclaim(id);
        assertEq(usdc.balanceOf(merchant), 0);
        assertEq(usdc.balanceOf(funder), 1_000e6);
    }

    /// A blacklisted escrow freezes every session at once, and no new one can open.
    function test_aBlacklistedEscrow() public {
        bytes32 id = _open(10e6, "i2-escrow");
        bytes memory v = _voucher(AGENT_PK, id, 1e6);
        uint64 expiry = uint64(_now() + 1 days);
        usdc.blacklist(address(escrow));
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        escrow.redeem(id, 1e6, v);
        vm.prank(funder);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        escrow.open(merchant, address(usdc), agent, expiry, "i2-escrow-2", 1e6);
    }
}

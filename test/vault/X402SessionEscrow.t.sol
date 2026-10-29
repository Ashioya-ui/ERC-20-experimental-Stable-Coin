// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {X402SessionEscrow} from "../../src/vault/X402SessionEscrow.sol";
import {EIP3009Mock} from "./mocks/EIP3009Mock.sol";
import {Mock1271Wallet} from "./mocks/VaultMocks.sol";

/// @dev Shared fixture: a funder (the agent's owner), an agent key that signs vouchers, a merchant.
abstract contract SessionFixture is Test {
    uint256 internal constant FUNDER_PK = 0xF00D;
    uint256 internal constant AGENT_PK = 0xA6E7;

    X402SessionEscrow internal escrow;
    EIP3009Mock internal usdc;
    address internal funder;
    address internal agent;
    address internal merchant;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        escrow = new X402SessionEscrow();
        usdc = new EIP3009Mock();
        funder = vm.addr(FUNDER_PK);
        agent = vm.addr(AGENT_PK);
        merchant = makeAddr("merchant");
        usdc.mint(funder, 1_000e6);
        vm.prank(funder);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _open(uint256 amount, bytes32 salt) internal returns (bytes32 id) {
        vm.prank(funder);
        id = escrow.open(merchant, address(usdc), agent, uint64(block.timestamp + 1 days), salt, amount);
    }

    function _voucher(uint256 pk, bytes32 id, uint256 cumulative) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, escrow.voucherDigest(id, cumulative));
        return abi.encodePacked(r, s, v);
    }
}

contract X402SessionEscrowTest is SessionFixture {
    // ------------------------------------------------------------------ the session's life

    function test_open_holdsTheDepositUnderTheSessionsTerms() public {
        bytes32 id = _open(10e6, "s");
        X402SessionEscrow.Session memory s = escrow.session(id);
        assertEq(s.funder, funder);
        assertEq(s.payee, merchant);
        assertEq(s.signer, agent);
        assertEq(s.deposited, 10e6);
        assertEq(s.claimed, 0);
        assertEq(id, escrow.sessionIdOf(funder, merchant, address(usdc), agent, "s"), "id computable in advance");
        assertEq(usdc.balanceOf(address(escrow)), 10e6);
    }

    /// A thousand calls, one settlement. Each call the merchant checks the voucher off-chain and
    /// serves; only the last voucher ever reaches the chain.
    function test_aThousandCallsSettleInOneRedemption() public {
        bytes32 id = _open(10e6, "many");
        uint256 price = 100; // $0.0001 a call: a price per-payment settlement cannot charge
        bytes memory latest;
        for (uint256 i = 1; i <= 1_000; ++i) {
            latest = _voucher(AGENT_PK, id, i * price);
            assertEq(ECDSA.recover(escrow.voucherDigest(id, i * price), latest), agent); // the per-call check
        }
        escrow.redeem(id, 1_000 * price, latest);
        assertEq(usdc.balanceOf(merchant), 1_000 * price, "1,000 calls paid by one transaction");
    }

    function test_redeem_isIncremental_andAnOldVoucherCountsOnce() public {
        bytes32 id = _open(10e6, "inc");
        bytes memory v1 = _voucher(AGENT_PK, id, 3e6);
        bytes memory v2 = _voucher(AGENT_PK, id, 5e6);
        escrow.redeem(id, 3e6, v1);
        escrow.redeem(id, 5e6, v2);
        assertEq(usdc.balanceOf(merchant), 5e6);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.NothingNew.selector, 3e6, 5e6));
        escrow.redeem(id, 3e6, v1);
    }

    function test_anyoneMayRedeem_butOnlyThePayeeIsPaid() public {
        bytes32 id = _open(10e6, "any");
        bytes memory v = _voucher(AGENT_PK, id, 2e6);
        address facilitator = makeAddr("facilitator");
        vm.prank(facilitator);
        escrow.redeem(id, 2e6, v);
        assertEq(usdc.balanceOf(merchant), 2e6);
        assertEq(usdc.balanceOf(facilitator), 0);
    }

    function test_redeemMany_settlesSeveralSessionsInOneTransaction() public {
        bytes32[] memory ids = new bytes32[](3);
        uint256[] memory amounts = new uint256[](3);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            ids[i] = _open(1e6, bytes32(i));
            amounts[i] = (i + 1) * 1e5;
            sigs[i] = _voucher(AGENT_PK, ids[i], amounts[i]);
        }
        escrow.redeemMany(ids, amounts, sigs);
        assertEq(usdc.balanceOf(merchant), 6e5);
    }

    function test_reclaim_returnsTheUnclaimedAfterExpiry() public {
        bytes32 id = _open(10e6, "rc");
        escrow.redeem(id, 4e6, _voucher(AGENT_PK, id, 4e6));
        uint256 before = usdc.balanceOf(funder);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.NotExpired.selector, id, uint64(block.timestamp + 1 days)));
        escrow.reclaim(id);
        vm.warp(block.timestamp + 1 days + 1);
        escrow.reclaim(id);
        assertEq(usdc.balanceOf(funder) - before, 6e6, "everything unclaimed comes back");
        assertEq(usdc.balanceOf(address(escrow)), 0);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.SessionIsClosed.selector, id));
        escrow.reclaim(id);
    }

    function test_closeByPayee_settlesTheLastVoucherAndReleasesTheRest() public {
        bytes32 id = _open(10e6, "close");
        bytes memory v = _voucher(AGENT_PK, id, 7e6);
        uint256 before = usdc.balanceOf(funder);
        vm.prank(merchant);
        escrow.closeByPayee(id, 7e6, v);
        assertEq(usdc.balanceOf(merchant), 7e6);
        assertEq(usdc.balanceOf(funder) - before, 3e6);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.NotPayee.selector, funder));
        vm.prank(funder);
        escrow.closeByPayee(id, 0, "");
    }

    function test_topUp_extendsTheSession() public {
        bytes32 id = _open(1e6, "top");
        vm.prank(funder);
        escrow.topUp(id, 2e6);
        escrow.redeem(id, 3e6, _voucher(AGENT_PK, id, 3e6));
        assertEq(usdc.balanceOf(merchant), 3e6);
    }

    // ------------------------------------------------------------------ what cannot happen

    function test_redeem_neverExceedsTheDeposit() public {
        bytes32 id = _open(1e6, "cap");
        bytes memory v = _voucher(AGENT_PK, id, 1e6 + 1);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.AboveDeposit.selector, 1e6 + 1, 1e6));
        escrow.redeem(id, 1e6 + 1, v);
    }

    function test_redeem_onlyTheSessionSignerCanAuthorise() public {
        bytes32 id = _open(1e6, "who");
        bytes memory byFunder = _voucher(FUNDER_PK, id, 5e5); // the funder is not the signer
        vm.expectRevert(X402SessionEscrow.InvalidVoucher.selector);
        escrow.redeem(id, 5e5, byFunder);
    }

    function test_voucher_isBoundToItsSessionAndAmount() public {
        bytes32 a = _open(1e6, "a");
        bytes32 b = _open(1e6, "b");
        bytes memory forA = _voucher(AGENT_PK, a, 5e5);
        vm.expectRevert(X402SessionEscrow.InvalidVoucher.selector);
        escrow.redeem(b, 5e5, forA); // another session
        vm.expectRevert(X402SessionEscrow.InvalidVoucher.selector);
        escrow.redeem(a, 6e5, forA); // a larger amount
    }

    function test_aStolenAgentKeyCanOnlyOverpayTheNamedMerchant_upToTheDeposit() public {
        bytes32 id = _open(5e6, "theft");
        // The thief holds the agent key and signs the largest voucher it can.
        bytes memory v = _voucher(AGENT_PK, id, 5e6);
        address thief = vm.addr(AGENT_PK);
        vm.prank(thief);
        escrow.redeem(id, 5e6, v);
        assertEq(usdc.balanceOf(thief), 0, "nothing reaches the thief");
        assertEq(usdc.balanceOf(merchant), 5e6, "only the named merchant is paid");
        assertEq(usdc.balanceOf(funder), 995e6, "the funder's exposure is the deposit, not its wallet");
    }

    function test_redeem_endsAtExpiry() public {
        bytes32 id = _open(1e6, "late");
        bytes memory v = _voucher(AGENT_PK, id, 5e5);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.SessionExpired.selector, id));
        escrow.redeem(id, 5e5, v);
    }

    function test_open_rejectsBadTerms() public {
        vm.startPrank(funder);
        vm.expectRevert(X402SessionEscrow.ZeroAddress.selector);
        escrow.open(address(0), address(usdc), agent, uint64(block.timestamp + 1 days), "z", 1);
        vm.expectRevert(X402SessionEscrow.ZeroAddress.selector);
        escrow.open(merchant, address(usdc), address(0), uint64(block.timestamp + 1 days), "z", 1);
        uint64 tooSoon = uint64(block.timestamp + 59 minutes);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.BadExpiry.selector, tooSoon));
        escrow.open(merchant, address(usdc), agent, tooSoon, "z", 1);
        uint64 tooLate = uint64(block.timestamp + 366 days);
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.BadExpiry.selector, tooLate));
        escrow.open(merchant, address(usdc), agent, tooLate, "z", 1);
        vm.expectRevert(X402SessionEscrow.ZeroAmount.selector);
        escrow.open(merchant, address(usdc), agent, uint64(block.timestamp + 1 days), "z", 0);
        escrow.open(merchant, address(usdc), agent, uint64(block.timestamp + 1 days), "z", 1);
        bytes32 id = escrow.sessionIdOf(funder, merchant, address(usdc), agent, "z");
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.SessionExists.selector, id));
        escrow.open(merchant, address(usdc), agent, uint64(block.timestamp + 1 days), "z", 1);
        vm.stopPrank();
    }

    function test_unknownSession() public {
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.UnknownSession.selector, bytes32("nope")));
        escrow.reclaim("nope");
    }

    // ------------------------------------------------------------------ signers

    function test_anERC1271SignerCanSignVouchers() public {
        Mock1271Wallet wallet = new Mock1271Wallet(agent);
        vm.prank(funder);
        bytes32 id = escrow.open(merchant, address(usdc), address(wallet), uint64(block.timestamp + 1 days), "w", 1e6);
        escrow.redeem(id, 4e5, _voucher(AGENT_PK, id, 4e5)); // the wallet accepts its owner's signature
        assertEq(usdc.balanceOf(merchant), 4e5);
    }

    /// An EIP-7702 account has code, and its delegate may not implement ERC-1271. Its own key
    /// must still sign: ECDSA is tried first.
    function test_aDelegatedEoaSignsWithItsOwnKey() public {
        vm.etch(agent, hex"60006000f3"); // any code at the agent's address, as a 7702 delegation leaves
        bytes32 id = _open(1e6, "7702");
        escrow.redeem(id, 3e5, _voucher(AGENT_PK, id, 3e5));
        assertEq(usdc.balanceOf(merchant), 3e5);
    }

    // ------------------------------------------------------------------ gasless open (EIP-3009)

    function test_openWithAuthorization_isGaslessForTheFunder_andBindsTheTerms() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes32 nonce = escrow.openNonce(merchant, address(usdc), agent, expiry, "g");
        bytes memory auth = _receiveAuth(FUNDER_PK, address(escrow), 2e6, nonce);
        address facilitator = makeAddr("facilitator");

        // A submitter who changes the payee breaks the binding.
        vm.prank(facilitator);
        vm.expectRevert(bytes("invalid signature"));
        escrow.openWithAuthorization(funder, facilitator, address(usdc), agent, expiry, "g", 2e6, 0, block.timestamp + 60, auth);

        vm.prank(facilitator);
        bytes32 id = escrow.openWithAuthorization(
            funder, merchant, address(usdc), agent, expiry, "g", 2e6, 0, block.timestamp + 60, auth
        );
        assertEq(escrow.session(id).deposited, 2e6);
        assertEq(usdc.balanceOf(funder), 998e6);
    }

    // ------------------------------------------------------------------ fuzz

    /// Any deposit, any sequence of increasing vouchers redeemed in any subset: the merchant gets
    /// exactly the highest redeemed amount, the funder gets the rest back, the escrow ends empty.
    function testFuzz_settlesExactly(uint96 deposit, uint256[6] memory steps, uint8 redeemMask) public {
        deposit = uint96(bound(deposit, 1, 500e6));
        bytes32 id = _open(deposit, "fuzz");
        uint256 cumulative;
        uint256 lastRedeemed;
        for (uint256 i; i < steps.length; ++i) {
            cumulative += bound(steps[i], 0, deposit / 6 + 1);
            if (cumulative > deposit) cumulative = deposit;
            if ((redeemMask >> i) & 1 == 1 && cumulative > lastRedeemed) {
                escrow.redeem(id, cumulative, _voucher(AGENT_PK, id, cumulative));
                lastRedeemed = cumulative;
            }
        }
        vm.warp(block.timestamp + 1 days + 1);
        uint256 funderBefore = usdc.balanceOf(funder);
        escrow.reclaim(id);
        assertEq(usdc.balanceOf(merchant), lastRedeemed, "merchant gets exactly what was redeemed");
        assertEq(usdc.balanceOf(funder) - funderBefore, deposit - lastRedeemed, "funder gets the rest");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow ends empty");
    }

    // ------------------------------------------------------------------ helpers

    function _receiveAuth(uint256 pk, address to, uint256 value, bytes32 nonce) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), vm.addr(pk), to, value, 0, block.timestamp + 60, nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }
}

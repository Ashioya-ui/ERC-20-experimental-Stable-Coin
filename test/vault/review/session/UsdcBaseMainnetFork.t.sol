// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {X402SessionEscrow} from "../../../../src/vault/X402SessionEscrow.sol";

/// @dev The parts of Circle's FiatToken v2.2 the review relies on.
interface IFiatTokenV22 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function pauser() external view returns (address);
    function pause() external;
    function unpause() external;
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external;
}

/// The review's USDC behaviours, against Circle's live FiatToken v2.2 on Base. Runs when
/// BASE_RPC_URL is set; skipped otherwise.
///   test_fork_S2_*  the S-2 fix on real USDC: a blacklisted payee no longer sinks a batch.
///   test_fork_I1_*, test_fork_I2_*  confirm the Info notes.
contract X402SessionReview_UsdcBaseMainnetForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    X402SessionEscrow internal escrow;
    IFiatTokenV22 internal fiat;
    address internal funder;
    uint256 internal funderPk;
    address internal agent;
    uint256 internal agentPk;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        escrow = new X402SessionEscrow();
        fiat = IFiatTokenV22(USDC);
        (funder, funderPk) = makeAddrAndKey("x402-session-review-funder");
        (agent, agentPk) = makeAddrAndKey("x402-session-review-agent");
        // USDC asks an address with code for ERC-1271: clear any EIP-7702 delegation the key carries.
        vm.etch(funder, "");
        deal(USDC, funder, 100e6);
        vm.prank(funder);
        IERC20(USDC).approve(address(escrow), type(uint256).max);
    }

    function _open(address payee, uint64 expiry, bytes32 salt) internal returns (bytes32 id) {
        vm.prank(funder);
        id = escrow.open(payee, USDC, agent, expiry, salt, 10e6);
    }

    function _voucher(bytes32 id, uint256 cumulative) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, escrow.voucherDigest(id, cumulative));
        return abi.encodePacked(r, s, v);
    }

    function _usdcSigned(bytes32 structHash) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        (v, r, s) = vm.sign(funderPk, keccak256(abi.encodePacked("\x19\x01", fiat.DOMAIN_SEPARATOR(), structHash)));
    }

    /// @dev A one-day gasless open of 5 USDC to `payee`, its window the minute around `t`.
    function _openAuth(address payee, bytes32 salt, uint256 t) internal view returns (bytes memory) {
        bytes32 nonce = escrow.openNonce(payee, USDC, agent, uint64(t + 1 days), salt);
        bytes32 structHash = keccak256(abi.encode(RECEIVE_TYPEHASH, funder, address(escrow), 5e6, t - 600, t + 60, nonce));
        (uint8 v, bytes32 r, bytes32 s) = _usdcSigned(structHash);
        return abi.encodePacked(r, s, v);
    }

    function _submitOpen(address payee, bytes32 salt, uint256 t, bytes memory auth) internal returns (bytes32) {
        return escrow.openWithAuthorization(funder, payee, USDC, agent, uint64(t + 1 days), salt, 5e6, t - 600, t + 60, auth);
    }

    /// S-2 on real USDC, fixed: a blacklisted payee is skipped, its session left as it was, and the
    /// rest of the batch pays.
    function test_fork_S2_aBlacklistedPayeeIsSkippedAndTheRestPays() public {
        address payee0 = makeAddr("fork-merchant-0");
        address payee1 = makeAddr("fork-merchant-1");
        uint64 expiry = uint64(vm.getBlockTimestamp() + 1 days);
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory cs = new uint256[](2);
        bytes[] memory sigs = new bytes[](2);
        ids[0] = _open(payee0, expiry, "fork-0");
        ids[1] = _open(payee1, expiry, "fork-1");
        cs[0] = 1e6;
        cs[1] = 1e6;
        sigs[0] = _voucher(ids[0], 1e6);
        sigs[1] = _voucher(ids[1], 1e6);
        address blacklister = fiat.blacklister();
        vm.prank(blacklister);
        fiat.blacklist(payee1);
        assertEq(escrow.redeemMany(ids, cs, sigs), 1, "one entry paid");
        assertEq(IERC20(USDC).balanceOf(payee0), 1e6, "the payable entry paid");
        assertEq(escrow.session(ids[1]).claimed, 0, "the refused entry is left as it was");
        // The blacklisted payee can still release its deposit to the funder, at once.
        uint256 before = IERC20(USDC).balanceOf(funder);
        vm.prank(payee1);
        escrow.closeByPayee(ids[1], 0, "");
        assertEq(IERC20(USDC).balanceOf(funder) - before, 10e6);
    }

    function test_fork_I1_aCanceledAuthorizationRevertsTheOpenAfterACleanSimulation() public {
        address payee = makeAddr("fork-merchant");
        uint256 t = vm.getBlockTimestamp();
        bytes memory auth = _openAuth(payee, "fork-cancel", t);
        uint256 snap = vm.snapshotState();
        _submitOpen(payee, "fork-cancel", t, auth);
        vm.revertToState(snap); // the simulation opens it

        bytes32 nonce = escrow.openNonce(payee, USDC, agent, uint64(t + 1 days), "fork-cancel");
        (uint8 v, bytes32 r, bytes32 s) = _usdcSigned(keccak256(abi.encode(CANCEL_TYPEHASH, funder, nonce)));
        fiat.cancelAuthorization(funder, nonce, v, r, s);
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        _submitOpen(payee, "fork-cancel", t, auth);
    }

    function test_fork_I2_aPauseThatSpansExpiryVoidsHeldVouchers() public {
        address payee = makeAddr("fork-merchant");
        uint64 expiry = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes32 id = _open(payee, expiry, "fork-pause");
        bytes memory v = _voucher(id, 4e6);
        address pauser = fiat.pauser();
        vm.prank(pauser);
        fiat.pause();
        vm.expectRevert(bytes("Pausable: paused"));
        escrow.redeem(id, 4e6, v);
        vm.warp(uint256(expiry) + 1);
        vm.prank(pauser);
        fiat.unpause();
        vm.expectRevert(abi.encodeWithSelector(X402SessionEscrow.SessionExpired.selector, id));
        escrow.redeem(id, 4e6, v);
        uint256 before = IERC20(USDC).balanceOf(funder);
        escrow.reclaim(id);
        assertEq(IERC20(USDC).balanceOf(funder) - before, 10e6);
        assertEq(IERC20(USDC).balanceOf(payee), 0);
    }
}

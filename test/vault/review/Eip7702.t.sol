// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";

/// @dev A common shape of EIP-7702 delegate: batched calls, no ERC-1271.
contract BatchDelegate {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    function execute(Call[] calldata calls) external payable {
        require(msg.sender == address(this), "only the account itself");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            require(ok, "call failed");
        }
    }

    receive() external payable {}
}

/// @dev A delegate whose ERC-1271 checks the account's own key over a replay-safe wrapping of the
///      hash (the ERC-7739 idea; Coinbase Smart Wallet's replaySafeHash is one such scheme).
contract WrappingDelegate is IERC1271 {
    bytes32 internal constant WRAP_TYPEHASH = keccak256("ReplaySafe(address account,bytes32 hash)");

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        bytes32 wrapped = keccak256(abi.encode(WRAP_TYPEHASH, address(this), hash));
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(wrapped, signature);
        return err == ECDSA.RecoverError.NoError && signer == address(this)
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}

/// F-3 (audit/vault-router-review.md). OpenZeppelin 5.4 SignatureChecker sends every signer that has
/// code to ERC-1271, and an EIP-7702 account has code. The account's own key, which signed the
/// digest, is then never checked with ECDSA.
///
/// Delegated execution is modelled by etching the delegate's runtime code at the EOA: under EIP-7702
/// the router sees the same thing (EXTCODESIZE > 0, and a call runs the delegate's code with
/// address(this) == the EOA), and the test needs no hardfork switch. These tests PASS while the
/// router never tries ECDSA for a signer with code.
contract VaultPayRouterReview_Eip7702Test is VaultPayRouterReviewFixture {
    function setUp() public override {
        super.setUp();
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
    }

    function test_aDelegatedEoaCannotPayWithItsOwnKey() public {
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("7702"));
        bytes memory sig = _sign(PAYER_PK, it);
        assertEq(ECDSA.recover(router.intentDigest(it), sig), payer, "signed by the payer's own key");

        vm.etch(payer, address(new BatchDelegate()).code);
        assertGt(payer.code.length, 0, "the account has code now");
        vm.expectRevert(VaultPayRouter.InvalidSignature.selector);
        router.pay(it, sig, _noPermit());

        // The very same signature pays once the delegation is cleared: an intent signed before
        // delegating dies with the delegation and comes back with its removal.
        vm.etch(payer, "");
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    function test_aWrappingDelegateNeedsADifferentSignature() public {
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("7739"));
        bytes memory plain = _sign(PAYER_PK, it);
        bytes32 digest = router.intentDigest(it);
        vm.etch(payer, address(new WrappingDelegate()).code);

        // The plain EIP-712 signature agent.mjs produces is refused.
        vm.expectRevert(VaultPayRouter.InvalidSignature.selector);
        router.pay(it, plain, _noPermit());

        // Only a signature over the delegate's own wrapping is accepted.
        bytes32 wrapped =
            keccak256(abi.encode(keccak256("ReplaySafe(address account,bytes32 hash)"), payer, digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_PK, wrapped);
        router.pay(it, abi.encodePacked(r, s, v), _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6);
    }
}

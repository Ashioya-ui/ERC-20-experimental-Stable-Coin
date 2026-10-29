// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

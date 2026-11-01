// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {X402SessionEscrow} from "../../src/vault/X402SessionEscrow.sol";
import {X402SessionPaths} from "../../src/vault/X402SessionPaths.sol";

/// @notice Deploys X402SessionPaths over the escrow recorded in deployments/<chainId>-session-escrow.json,
///         through the deterministic CREATE2 deployer. Ownerless; the deploying key holds no role.
///         Idempotent: if the contract is already at its address, nothing is sent.
///
///   FOUNDRY_PROFILE=vault forge script script/vault/DeployX402SessionPaths.s.sol --rpc-url $RPC
///   (add --broadcast and a signer to deploy; run DeployX402SessionEscrow first)
contract DeployX402SessionPaths is Script {
    bytes32 public constant SALT = keccak256("spectrum.x402-session-paths.v1");

    function run() external returns (X402SessionPaths paths) {
        string memory chain = vm.toString(block.chainid);
        address escrow = vm.parseJsonAddress(vm.readFile(string.concat("deployments/", chain, "-session-escrow.json")), ".escrow");
        bytes memory init = abi.encodePacked(type(X402SessionPaths).creationCode, abi.encode(escrow));
        address predicted = vm.computeCreate2Address(SALT, keccak256(init));
        if (predicted.code.length == 0) {
            vm.startBroadcast();
            X402SessionPaths deployed = new X402SessionPaths{salt: SALT}(X402SessionEscrow(escrow));
            vm.stopBroadcast();
            require(address(deployed) == predicted, "deployed somewhere unexpected");
        } else {
            console2.log("already deployed at the predicted address; nothing sent");
        }
        paths = X402SessionPaths(predicted);
        require(address(paths.escrow()) == escrow, "escrow");
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("X402SessionPaths"),
                keccak256("1"),
                block.chainid,
                predicted
            )
        );
        require(paths.domainSeparator() == expected, "domain separator");
        console2.log("X402SessionPaths", predicted);
        console2.log("escrow          ", escrow);

        string memory o = "session-paths";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeBytes32(o, "salt", SALT);
        vm.serializeAddress(o, "escrow", escrow);
        string memory json = vm.serializeAddress(o, "paths", predicted);
        vm.writeJson(json, string.concat("deployments/", chain, "-session-paths.json"));
    }
}

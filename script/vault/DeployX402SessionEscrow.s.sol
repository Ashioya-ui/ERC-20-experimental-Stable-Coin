// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {X402SessionEscrow} from "../../src/vault/X402SessionEscrow.sol";

/// @notice Deploys X402SessionEscrow through the deterministic CREATE2 deployer: one address on
///         every chain the same bytecode reaches. Ownerless, so the deploying key holds no role
///         afterwards. Idempotent: if the escrow is already at its address, nothing is sent.
///
///   FOUNDRY_PROFILE=vault forge script script/vault/DeployX402SessionEscrow.s.sol --rpc-url $RPC
///   (add --broadcast and a signer to deploy)
contract DeployX402SessionEscrow is Script {
    bytes32 public constant SALT = keccak256("spectrum.x402-session-escrow.v1");

    function run() external returns (X402SessionEscrow escrow) {
        address predicted = vm.computeCreate2Address(SALT, keccak256(type(X402SessionEscrow).creationCode));
        if (predicted.code.length == 0) {
            vm.startBroadcast();
            X402SessionEscrow deployed = new X402SessionEscrow{salt: SALT}();
            vm.stopBroadcast();
            require(address(deployed) == predicted, "deployed somewhere unexpected");
        } else {
            console2.log("already deployed at the predicted address; nothing sent");
        }
        escrow = X402SessionEscrow(predicted);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("X402SessionEscrow"),
                keccak256("1"),
                block.chainid,
                predicted
            )
        );
        require(escrow.domainSeparator() == expected, "domain separator");
        console2.log("X402SessionEscrow", predicted);
        console2.log("chain id         ", block.chainid);

        string memory o = "session-escrow";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeBytes32(o, "salt", SALT);
        vm.serializeBytes32(o, "codehash", predicted.codehash);
        string memory json = vm.serializeAddress(o, "escrow", predicted);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), "-session-escrow.json"));
    }
}

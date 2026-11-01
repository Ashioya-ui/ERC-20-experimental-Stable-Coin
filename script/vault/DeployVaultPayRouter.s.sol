// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {VaultPayRouter} from "../../src/vault/VaultPayRouter.sol";

/// @notice Deploys VaultPayRouter through the deterministic CREATE2 deployer, so the router sits
///         at the same address on every chain the same bytecode reaches. The router has no owner:
///         the deploying key holds no role afterwards. Idempotent: if the router is already at
///         its address, nothing is sent.
///
///   FOUNDRY_PROFILE=vault forge script script/vault/DeployVaultPayRouter.s.sol --rpc-url $RPC
///   (add --broadcast and a signer to deploy)
contract DeployVaultPayRouter is Script {
    bytes32 public constant SALT = keccak256("spectrum.vault-pay-router.v1");

    function run() external returns (VaultPayRouter router) {
        address predicted = vm.computeCreate2Address(SALT, keccak256(type(VaultPayRouter).creationCode));

        if (predicted.code.length == 0) {
            vm.startBroadcast();
            VaultPayRouter deployed = new VaultPayRouter{salt: SALT}();
            vm.stopBroadcast();
            require(address(deployed) == predicted, "deployed somewhere unexpected");
        } else {
            console2.log("already deployed at the predicted address; nothing sent");
        }
        router = VaultPayRouter(predicted);

        // The deployment checks itself: its EIP-712 domain is bound to this chain and address.
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("VaultPayRouter"),
                keccak256("1"),
                block.chainid,
                predicted
            )
        );
        require(router.domainSeparator() == expected, "domain separator");

        console2.log("VaultPayRouter", predicted);
        console2.log("chain id      ", block.chainid);

        string memory o = "vault-router";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeBytes32(o, "salt", SALT);
        vm.serializeBytes32(o, "codehash", predicted.codehash);
        string memory json = vm.serializeAddress(o, "router", predicted);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), "-vault-router.json"));
    }
}

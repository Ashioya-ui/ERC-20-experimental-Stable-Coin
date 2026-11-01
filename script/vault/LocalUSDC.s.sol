// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IFiatToken, IFiatTokenProxy} from "../lib/IFiatToken.sol";

/// @notice Circle's FiatToken v2.2 as USDC on a fresh anvil chain, deployed from its real bytecode
///         (test/artifacts), so x402 sessions can be rehearsed without a fork. The deployer becomes
///         master minter and minter. Anvil only. Writes deployments/31337-usdc.json.
///
///   USDC_PROXY_ADMIN=<another anvil account> FOUNDRY_PROFILE=vault forge script \
///     script/vault/LocalUSDC.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender <deployer>
contract LocalUSDC is Script {
    function run() external returns (address usdc) {
        require(block.chainid == 31_337, "LocalUSDC: anvil only");
        address deployer = msg.sender;
        address proxyAdmin = vm.envAddress("USDC_PROXY_ADMIN"); // must differ from the deployer
        vm.startBroadcast(deployer);
        // FiatToken v2.2 links the external SignatureChecker library, as on mainnet.
        address sigLib = _create(vm.parseBytes(vm.readFile("test/artifacts/SignatureChecker.bin")));
        bytes memory impl = vm.parseBytes(vm.readFile("test/artifacts/FiatTokenV2_2.bin"));
        uint256[] memory offsets =
            vm.parseJsonUintArray(vm.readFile("test/artifacts/FiatTokenV2_2.linkrefs.json"), ".byteOffsets");
        bytes20 libBytes = bytes20(sigLib);
        for (uint256 i; i < offsets.length; ++i) {
            for (uint256 k; k < 20; ++k) {
                impl[offsets[i] + k] = libBytes[k];
            }
        }
        address implementation = _create(impl);
        usdc = _create(
            abi.encodePacked(vm.parseBytes(vm.readFile("test/artifacts/FiatTokenProxy.bin")), abi.encode(implementation))
        );
        IFiatTokenProxy(usdc).changeAdmin(proxyAdmin);
        IFiatToken t = IFiatToken(usdc);
        t.initialize("USD Coin", "USDC", "USD", 6, deployer, deployer, deployer, deployer);
        t.initializeV2("USD Coin");
        t.initializeV2_1(deployer);
        t.initializeV2_2(new address[](0), "USDC");
        t.configureMinter(deployer, type(uint256).max);
        vm.stopBroadcast();
        console2.log("USDC (FiatToken v2.2)", usdc);
        vm.writeJson(vm.serializeAddress("usdc", "usdc", usdc), "deployments/31337-usdc.json");
    }

    function _create(bytes memory code) private returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), "LocalUSDC: create failed");
    }
}

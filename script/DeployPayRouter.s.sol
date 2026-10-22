// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {SpectralStabilizer} from "../src/SpectralStabilizer.sol";
import {SpectrumPayRouter} from "../src/periphery/SpectrumPayRouter.sol";

/// @title  DeployPayRouter
/// @notice Deploys the sUSD-to-USDC pay router (Phase 6) next to an existing Spectrum deployment
///         and records it in deployments/<chainId>-router.json. The router has no owner and no
///         settings, so the deployer key keeps nothing after this script.
///
///   forge script script/DeployPayRouter.s.sol --rpc-url $RPC --broadcast --account <keystore>
contract DeployPayRouter is Script {
    function run() external returns (SpectrumPayRouter router) {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        SpectralStabilizer stabilizer = SpectralStabilizer(vm.parseJsonAddress(vm.readFile(path), ".stabilizer"));
        require(address(stabilizer).code.length > 0, "DeployPayRouter: no stabilizer at the recorded address");

        vm.startBroadcast();
        router = new SpectrumPayRouter(stabilizer);
        vm.stopBroadcast();

        require(address(router.sUSD()) == address(stabilizer.token()), "DeployPayRouter: wiring");
        require(router.treasury() == address(stabilizer.treasury()), "DeployPayRouter: wiring");

        string memory o = "router";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "stabilizer", address(stabilizer));
        string memory json = vm.serializeAddress(o, "router", address(router));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), "-router.json"));
        console2.log("SpectrumPayRouter", address(router));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SpectrumDeploy} from "./lib/SpectrumDeploy.sol";

/// @title  PostDeployCheck
/// @notice Read-only verification of a deployment against its config. Run at any time:
///           forge script script/PostDeployCheck.s.sol --rpc-url $BASE_RPC_URL
///         Reverts with the first failing check; prints a state report otherwise.
contract PostDeployCheck is Script {
    function run() external view {
        string memory configPath =
            vm.envOr("SPECTRUM_CONFIG", string.concat("config/", vm.toString(block.chainid), ".json"));
        string memory deploymentPath =
            vm.envOr("SPECTRUM_DEPLOYMENT", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        SpectrumDeploy.Config memory c = SpectrumDeploy.loadConfig(configPath);
        SpectrumDeploy.Deployment memory d = SpectrumDeploy.loadDeployment(deploymentPath);
        string memory j = vm.readFile(deploymentPath);
        address deployer = vm.parseJsonAddress(j, ".deployer");
        SpectrumDeploy.check(c, d, deployer);
        SpectrumDeploy.report(d);
        console2.log("POST-DEPLOY CHECK PASSED");
    }
}

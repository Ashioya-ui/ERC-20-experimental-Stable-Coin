// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SpectrumDeploy} from "./lib/SpectrumDeploy.sol";

/// @title  DeployBaseMainnet
/// @notice Deploys Spectrum to the chain named in config/<chainId>.json (Base mainnet: 8453).
///         The same code path runs in the local rehearsal (config/31337.json) and the fork
///         tests, through SpectrumDeploy.
///
///         Dry run against live Base state (no transactions):
///           forge script script/DeployBaseMainnet.s.sol --rpc-url $BASE_RPC_URL --sender $DEPLOYER
///         Deploy and verify (Ledger; or --account <keystore>):
///           forge script script/DeployBaseMainnet.s.sol --rpc-url $BASE_RPC_URL --ledger \
///             --sender $DEPLOYER --broadcast --slow --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
///         Use a fresh deployer key that sends nothing else while this runs: the hook salt is
///         mined for the addresses implied by the deployer's current nonce.
contract DeployBaseMainnet is Script {
    function run() external returns (SpectrumDeploy.Deployment memory d) {
        string memory configPath =
            vm.envOr("SPECTRUM_CONFIG", string.concat("config/", vm.toString(block.chainid), ".json"));
        string memory outPath =
            vm.envOr("SPECTRUM_DEPLOYMENT", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        SpectrumDeploy.Config memory c = SpectrumDeploy.loadConfig(configPath);
        address deployer = msg.sender;

        SpectrumDeploy.preflight(c, deployer);

        vm.startBroadcast(deployer);
        d = SpectrumDeploy.deploy(c, deployer);
        vm.stopBroadcast();

        SpectrumDeploy.check(c, d, deployer);
        SpectrumDeploy.writeDeployment(c, d, deployer, outPath);
        SpectrumDeploy.report(d);

        console2.log("== deployed ==");
        console2.log("AutonomousTreasury ", address(d.treasury));
        console2.log("SpectralToken sUSD ", address(d.token));
        console2.log("EntropyOracle      ", address(d.oracle));
        console2.log("SpectralStabilizer ", address(d.stabilizer));
        console2.log("WrappedSUSD wsUSD  ", address(d.wsusd));
        console2.log("SpectralHook       ", address(d.hook));
        console2.log("hook salt          ", vm.toString(d.hookSalt));
        console2.log("written to         ", outPath);
    }
}

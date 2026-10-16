// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {LocalEnv} from "../lib/LocalEnv.sol";
import {IFiatToken} from "../lib/IFiatToken.sol";

/// @title  LocalMainnetEnv (rehearsal step 1)
/// @notice Stands up a Base-shaped chain on anvil: Circle FiatToken v2.2 as USDC, a Uniswap v4
///         PoolManager, two lending-vault stand-ins, and v4 test routers for the scenario.
///         Writes config/31337.json (mainnet parameters from config/8453.json, local
///         addresses, anvil keys standing in for the Safe and guardian) and
///         deployments/31337-env.json. Anvil only.
contract LocalMainnetEnv is Script {
    function run() external {
        require(block.chainid == 31_337, "LocalMainnetEnv: anvil only");
        address deployer = msg.sender;
        address admin = vm.envAddress("REHEARSAL_ADMIN");
        address guardian = vm.envAddress("REHEARSAL_GUARDIAN");
        address payer = vm.envAddress("REHEARSAL_PAYER");
        address usdcProxyAdmin = vm.envAddress("REHEARSAL_USDC_PROXY_ADMIN");

        vm.startBroadcast(deployer);
        LocalEnv.Env memory e = LocalEnv.deploy(deployer, usdcProxyAdmin);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(e.poolManager));
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(e.poolManager));
        IFiatToken(e.usdc).mint(deployer, 100_000e6);
        IFiatToken(e.usdc).mint(payer, 10_000e6);
        vm.stopBroadcast();

        // config/31337.json: identical parameters to mainnet, local addresses.
        string memory main = vm.readFile("config/8453.json");
        string memory ext = "external";
        vm.serializeAddress(ext, "poolManager", e.poolManager);
        vm.serializeAddress(ext, "usdc", e.usdc);
        vm.serializeAddress(ext, "vault", e.vault);
        string memory extJson = vm.serializeAddress(ext, "fallbackVault", e.fallbackVault);
        string memory roles = "roles";
        vm.serializeAddress(roles, "admin", admin);
        vm.serializeAddress(roles, "guardian", guardian);
        string memory rolesJson = vm.serializeBool(roles, "allowEoaAdmin", true);
        string memory params = "params";
        string[10] memory keys = [
            "poolFeePips",
            "minObservationWsUSD",
            "emaAlphaMaxBps",
            "emaTauSeconds",
            "staleAfterSeconds",
            "bootstrapCapSUSD",
            "supplyCapSUSD",
            "liquidityBufferBps",
            "seedUSDC",
            "tickSpacing"
        ];
        string memory paramsJson;
        for (uint256 i; i < keys.length; ++i) {
            paramsJson = vm.serializeUint(params, keys[i], vm.parseJsonUint(main, string.concat(".params.", keys[i])));
        }
        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "network", "anvil-rehearsal");
        vm.serializeString(root, "external", extJson);
        vm.serializeString(root, "roles", rolesJson);
        string memory cfg = vm.serializeString(root, "params", paramsJson);
        vm.writeJson(cfg, "deployments/31337-config.json");

        string memory env = "env";
        vm.serializeAddress(env, "usdc", e.usdc);
        vm.serializeAddress(env, "poolManager", e.poolManager);
        vm.serializeAddress(env, "vault", e.vault);
        vm.serializeAddress(env, "fallbackVault", e.fallbackVault);
        vm.serializeAddress(env, "lpRouter", address(lpRouter));
        string memory envJson = vm.serializeAddress(env, "swapRouter", address(swapRouter));
        vm.writeJson(envJson, "deployments/31337-env.json");

        console2.log("USDC (FiatToken v2.2) ", e.usdc);
        console2.log("PoolManager           ", e.poolManager);
        console2.log("vault (Aave stand-in) ", e.vault);
        console2.log("fallback vault        ", e.fallbackVault);
        console2.log("config written to      deployments/31337-config.json");
    }
}

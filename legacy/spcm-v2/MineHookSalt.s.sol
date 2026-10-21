// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {HookMiner} from "v4-core/test/utils/HookMiner.sol";
import {Hooks}     from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import "../src/SpectralHook.sol";

/**
 * @title  MineHookSalt
 * @notice Finds a CREATE2 salt that gives SpectralHook the address flags
 *         required by Uniswap V4 (BEFORE_SWAP | AFTER_SWAP = 0x00C0).
 *
 * RUN:
 *   forge script script/MineHookSalt.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC \
 *     --private-key $PRIVATE_KEY
 *
 * This script does NOT broadcast — it just prints the salt and address.
 * Copy the salt into your .env as HOOK_SALT=0x... then run Deploy.s.sol.
 *
 * NOTE: Mining may take 10–60 seconds on a modern CPU.
 */
contract MineHookSalt is Script {
    address constant POOL_MANAGER =
        0x05E73354cFDd6745C338b50f4B7eB6e0A1b41863; // Base Sepolia

    function run() external view {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            address(0),   // oracle — placeholder; actual address not needed for salt
            deployer
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            flags,
            type(SpectralHook).creationCode,
            constructorArgs
        );

        console.log("=== HOOK SALT FOUND ===");
        console.log("Salt:           ", vm.toString(salt));
        console.log("Hook address:   ", hookAddress);
        console.log("");
        console.log("Add to .env:    HOOK_SALT=", vm.toString(salt));
        console.log("Then run:       forge script script/Deploy.s.sol ...");
    }
}

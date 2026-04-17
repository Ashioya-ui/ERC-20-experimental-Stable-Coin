// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}      from "v4-core/src/types/PoolKey.sol";
import {Currency}     from "v4-core/src/types/Currency.sol";
import {TickMath}     from "v4-core/src/libraries/TickMath.sol";

/**
 * @title  CreatePool
 * @notice Initialises the SPCM/WETH Uniswap V4 pool.
 *
 * SET ENV VARS before running:
 *   SPCM_ADDRESS   = your deployed SpectralToken address
 *   HOOK_ADDRESS   = your deployed SpectralHook address
 *
 * RUN (Sepolia):
 *   forge script script/CreatePool.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * RUN (Mainnet — change POOL_MANAGER):
 *   forge script script/CreatePool.s.sol \
 *     --rpc-url $BASE_MAINNET_RPC \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 */
contract CreatePool is Script {
    // Sepolia
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50f4B7eB6e0A1b41863;
    // Base Mainnet (swap above to mainnet):
    // address constant POOL_MANAGER = 0x498581ff718922c3f8e6a244956af099b2652b2b;

    // WETH on Base (both Sepolia and Mainnet)
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        address spcm = vm.envAddress("SPCM_ADDRESS");
        address hook = vm.envAddress("HOOK_ADDRESS");

        require(spcm != address(0), "SPCM_ADDRESS not set");
        require(hook != address(0), "HOOK_ADDRESS not set");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // V4 requires currency0 < currency1 (by address)
        address currency0 = WETH < spcm ? WETH : spcm;
        address currency1 = WETH < spcm ? spcm : WETH;

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(currency0),
            currency1:   Currency.wrap(currency1),
            fee:         500,          // 0.05% base (hook overrides dynamically)
            tickSpacing: 10,
            hooks:       IHooks(hook)
        });

        // sqrtPriceX96 for 1:1 price
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96, "");

        console.log("Pool initialised.");
        console.log("currency0:", currency0);
        console.log("currency1:", currency1);
        console.log("hook:     ", hook);
        console.log("");
        console.log("Next: add initial liquidity via Uniswap V4 interface or periphery.");

        vm.stopBroadcast();
    }
}

// Minimal IHooks interface needed here
interface IHooks { }

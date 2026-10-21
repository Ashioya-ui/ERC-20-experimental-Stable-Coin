// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/SpectralToken.sol";
import "../src/SpectralEntropyOracle.sol";
import "../src/SpectralStabilizer.sol";
import "../src/AutonomousTreasury.sol";
import "../src/SpectralHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title  Deploy — SPECTRUM Protocol v2 (post red-team)
 *
 * BEFORE RUNNING:
 *   1. forge script script/MineHookSalt.s.sol --rpc-url $BASE_SEPOLIA_RPC
 *   2. export HOOK_SALT=0x...  (from step 1 output)
 *   3. forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC \
 *        --private-key $PRIVATE_KEY --broadcast --verify \
 *        --etherscan-api-key $BASESCAN_API_KEY
 *
 * NETWORKS:
 *   Base Sepolia:  POOL_MANAGER = 0x05E73354cFDd6745C338b50f4B7eB6e0A1b41863
 *   Base Mainnet:  POOL_MANAGER = 0x498581ff718922c3f8e6a244956af099b2652b2b
 */
contract Deploy is Script {
    address constant POOL_MANAGER_SEPOLIA = 0x05E73354cFDd6745C338b50f4B7eB6e0A1b41863;
    address constant POOL_MANAGER_MAINNET = 0x498581ff718922c3f8e6a244956af099b2652b2b;

    // Deployment parameters
    uint256 constant INITIAL_SUPPLY   = 1_000_000;   // 1M SPCM
    uint256 constant ORACLE_WINDOW    = 500;          // [MEDIUM patch: was 200]
    uint256 constant MIN_VOL_THRESH   = 1e15;         // 0.001 token units (anti-dust)

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // Use Sepolia by default; override POOL_MANAGER env var for mainnet
        address poolManager = vm.envOr(
            "POOL_MANAGER",
            POOL_MANAGER_SEPOLIA
        );

        vm.startBroadcast(deployerKey);

        // ── 1. SpectralToken ──────────────────────────────────────────────────
        SpectralToken token = new SpectralToken(deployer, INITIAL_SUPPLY);
        console.log("SpectralToken (SPCM):", address(token));

        // ── 2. SpectralEntropyOracle ──────────────────────────────────────────
        SpectralEntropyOracle oracle = new SpectralEntropyOracle(deployer, ORACLE_WINDOW);
        console.log("SpectralEntropyOracle:", address(oracle));

        // ── 3. AutonomousTreasury ─────────────────────────────────────────────
        AutonomousTreasury treasury = new AutonomousTreasury(
            address(token),
            deployer,
            MIN_VOL_THRESH   // [HIGH patch: min volume threshold for participation]
        );
        console.log("AutonomousTreasury:", address(treasury));

        // ── 4. SpectralStabilizer ─────────────────────────────────────────────
        SpectralStabilizer stabilizer = new SpectralStabilizer(
            address(token),
            address(oracle),
            address(treasury),
            deployer
        );
        console.log("SpectralStabilizer:", address(stabilizer));

        // ── 5. SpectralHook (requires salt) ───────────────────────────────────
        bytes32 hookSalt = vm.envOr("HOOK_SALT", bytes32(0));
        address hookAddr = address(0);

        if (hookSalt != bytes32(0)) {
            SpectralHook hook = new SpectralHook{salt: hookSalt}(
                IPoolManager(poolManager),
                address(oracle),
                deployer
            );
            hookAddr = address(hook);
            console.log("SpectralHook:", hookAddr);
        } else {
            console.log("SpectralHook: SKIPPED (set HOOK_SALT env var)");
        }

        // ── 6. Wire: Token → Stabilizer ───────────────────────────────────────
        token.setStabilizer(address(stabilizer));
        console.log("token.stabilizer = stabilizer");

        // ── 7. Wire: Treasury → Stabilizer ───────────────────────────────────
        treasury.setStabilizer(address(stabilizer));
        console.log("treasury.stabilizer = stabilizer");

        // ── 8. Wire remaining (hook-dependent) ────────────────────────────────
        if (hookAddr != address(0)) {
            // [CRITICAL patch] setHook is one-time-only in oracle
            oracle.setHook(hookAddr);
            console.log("oracle.hook = hook (locked — cannot change)");

            // [CRITICAL patch] setHook is one-time-only in treasury
            treasury.setHook(hookAddr);
            console.log("treasury.hook = hook (locked — cannot change)");

            SpectralHook(hookAddr).setTreasury(address(treasury));
            console.log("hook.treasury = treasury");
        }

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Token:      ", address(token));
        console.log("Oracle:     ", address(oracle));
        console.log("Treasury:   ", address(treasury));
        console.log("Stabilizer: ", address(stabilizer));
        console.log("Hook:       ", hookAddr != address(0) ? hookAddr : address(0));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. If hook was skipped: mine salt, redeploy with HOOK_SALT set");
        console.log("2. Run CreatePool.s.sol to initialise SPCM/WETH pool");
        console.log("3. Add initial liquidity");
        console.log("4. Monitor with dashboard.html");
        console.log("");
        console.log("DO NOT transfer treasury.owner to stabilizer yet.");
        console.log("Wait 30 days on testnet first. See README.");
    }
}

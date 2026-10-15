// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {SpectralToken} from "../src/SpectralToken.sol";
import {SpectralStabilizer} from "../src/SpectralStabilizer.sol";
import {AutonomousTreasury} from "../src/AutonomousTreasury.sol";
import {SpectralEntropyOracle} from "../src/SpectralEntropyOracle.sol";
import {SpectralHook} from "../src/SpectralHook.sol";
import {WrappedSUSD} from "../src/WrappedSUSD.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockVault} from "../test/mocks/MockVault.sol";

/// @title  DeployLocal
/// @notice Deploys the whole protocol to a local anvil node, including mocks (open-mint USDC,
///         an ERC-4626 vault), a fresh Uniswap v4 PoolManager and test routers, mines the hook
///         address, seeds a wsUSD/USDC pool and runs nine demo swaps so the oracle fills.
///
///         anvil &
///         forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///             --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
///         (anvil's first default key; never use it anywhere else). Addresses are written to
///         deployments/31337.json for the Phase 2 server and client.
///
///         Local only: the script refuses to run on any chain other than 31337, because the
///         mocks have open mint functions.
contract DeployLocal is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint24 internal constant FEE = 500; // 0.05% LP fee, a stable pair
    int24 internal constant TICK_SPACING = 10;

    struct Deployment {
        MockUSDC usdc;
        MockVault vault;
        IPoolManager manager;
        PoolModifyLiquidityTest liquidityRouter;
        PoolSwapTest swapRouter;
        AutonomousTreasury treasury;
        SpectralToken token;
        SpectralEntropyOracle oracle;
        SpectralStabilizer stabilizer;
        WrappedSUSD wsusd;
        SpectralHook hook;
        PoolKey key;
    }

    function run() external returns (Deployment memory d) {
        require(block.chainid == 31_337, "DeployLocal: local anvil only");
        address me = msg.sender;
        vm.startBroadcast();

        // ---------------------------------------------------------------- core
        d.usdc = new MockUSDC();
        d.vault = new MockVault(d.usdc);
        d.manager = new PoolManager(me);
        d.liquidityRouter = new PoolModifyLiquidityTest(d.manager);
        d.swapRouter = new PoolSwapTest(d.manager);

        d.treasury = new AutonomousTreasury(IERC4626(address(d.vault)));
        d.token = new SpectralToken();
        d.oracle = new SpectralEntropyOracle(me, 1e18, 0.25e18, 1 hours);
        d.stabilizer = new SpectralStabilizer(d.token, d.treasury, d.oracle, me, 1_000_000e18);
        d.token.setStabilizer(address(d.stabilizer));
        d.treasury.setStabilizer(address(d.stabilizer));
        d.wsusd = new WrappedSUSD(d.token);

        // ---------------------------------------------------------------- hook (CREATE2, mined)
        Currency ws = Currency.wrap(address(d.wsusd));
        Currency usd = Currency.wrap(address(d.usdc));
        bytes memory args = abi.encode(d.manager, d.oracle, ws, usd, FEE, TICK_SPACING);
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(SpectralHook).creationCode, args);
        d.hook = new SpectralHook{salt: salt}(d.manager, d.oracle, ws, usd, FEE, TICK_SPACING);
        require(address(d.hook) == predicted, "hook address mismatch");
        d.oracle.setHook(address(d.hook));

        // ---------------------------------------------------------------- liquidity
        d.usdc.mint(me, 400_000e6);
        d.usdc.approve(address(d.stabilizer), type(uint256).max);
        d.stabilizer.mint(300_000e6, me, 0);
        d.token.approve(address(d.wsusd), type(uint256).max);
        d.wsusd.deposit(1e18, address(0xdead)); // dead shares against inflation attacks
        d.wsusd.deposit(150_000e18, me);

        (Currency c0, Currency c1) = address(d.wsusd) < address(d.usdc) ? (ws, usd) : (usd, ws);
        d.key = PoolKey(c0, c1, FEE, TICK_SPACING, IHooks(address(d.hook)));
        // 1 wsUSD (1e18 units) = 1 USDC (1e6 units)
        uint160 sqrtP = Currency.unwrap(c0) == address(d.usdc)
            ? uint160(uint256(1e6) << 96) // price 1e12
            : uint160((uint256(1) << 96) / 1e6); // price 1e-12
        d.manager.initialize(d.key, sqrtP);
        _addLiquidity(d, sqrtP);

        // ---------------------------------------------------------------- demo flow
        d.wsusd.approve(address(d.swapRouter), type(uint256).max);
        d.usdc.approve(address(d.swapRouter), type(uint256).max);
        bool wsIs0 = Currency.unwrap(c0) == address(d.wsusd);
        for (uint256 i; i < 9; ++i) {
            // Sell 100..900 wsUSD (exact input). Each tx is mined in its own anvil block.
            d.swapRouter.swap(
                d.key,
                SwapParams({
                    zeroForOne: wsIs0,
                    amountSpecified: -int256((i + 1) * 100e18),
                    sqrtPriceLimitX96: wsIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        vm.stopBroadcast();

        _log(d);
        _writeJson(d);
    }

    function _addLiquidity(Deployment memory d, uint160 sqrtP) internal {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 compressed = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) compressed--;
        int24 lower = (compressed - 100) * TICK_SPACING; // 1,000 ticks, about +-10% around par
        int24 upper = (compressed + 100) * TICK_SPACING;
        bool wsIs0 = Currency.unwrap(d.key.currency0) == address(d.wsusd);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            wsIs0 ? 100_000e18 : 100_000e6,
            wsIs0 ? 100_000e6 : 100_000e18
        );
        d.wsusd.approve(address(d.liquidityRouter), type(uint256).max);
        d.usdc.approve(address(d.liquidityRouter), type(uint256).max);
        d.liquidityRouter.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );
    }

    function _log(Deployment memory d) internal pure {
        console2.log("USDC (mock)       ", address(d.usdc));
        console2.log("ERC-4626 vault    ", address(d.vault));
        console2.log("PoolManager       ", address(d.manager));
        console2.log("SwapRouter (test) ", address(d.swapRouter));
        console2.log("AutonomousTreasury", address(d.treasury));
        console2.log("SpectralToken sUSD", address(d.token));
        console2.log("EntropyOracle     ", address(d.oracle));
        console2.log("Stabilizer        ", address(d.stabilizer));
        console2.log("WrappedSUSD wsUSD ", address(d.wsusd));
        console2.log("SpectralHook      ", address(d.hook));
    }

    function _writeJson(Deployment memory d) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "usdc", address(d.usdc));
        vm.serializeAddress(o, "vault", address(d.vault));
        vm.serializeAddress(o, "poolManager", address(d.manager));
        vm.serializeAddress(o, "swapRouter", address(d.swapRouter));
        vm.serializeAddress(o, "treasury", address(d.treasury));
        vm.serializeAddress(o, "sUSD", address(d.token));
        vm.serializeAddress(o, "oracle", address(d.oracle));
        vm.serializeAddress(o, "stabilizer", address(d.stabilizer));
        vm.serializeAddress(o, "wsUSD", address(d.wsusd));
        string memory json = vm.serializeAddress(o, "hook", address(d.hook));
        vm.writeJson(json, "deployments/31337.json");
    }
}

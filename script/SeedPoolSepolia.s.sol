// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {SpectrumDeploy} from "./lib/SpectrumDeploy.sol";

/// @title  SeedPoolSepolia
/// @notice Makes the spectral engine run on a public chain. Without pool liquidity the hook
///         records nothing, the oracle stays at its neutral warm-up constant, and no rebase can
///         ever happen -- which is the state the live-deployment audit found (finding L-10).
///
///         Seeds the wsUSD/USDC v4 pool, then swaps in alternating directions so the price
///         oscillates about par and the same inventory recycles; that needs far less capital
///         than walking the price one way. Each swap moves at least `oracle.minObservation()`
///         of the wsUSD leg, which is what the oracle requires before a block counts.
///
///         Sizing comes from the deployer's actual balance, so the script adapts to whatever
///         the faucet provided instead of assuming. It reports the shortfall and stops if there
///         is genuinely not enough.
///
///   SEED_SWAPS=9 forge script script/SeedPoolSepolia.s.sol --rpc-url $RPC --broadcast --slow
contract SeedPoolSepolia is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function run() external {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        SpectrumDeploy.Deployment memory d = SpectrumDeploy.loadDeployment(path);
        string memory j = vm.readFile(path);
        address usdc = vm.parseJsonAddress(j, ".usdc");
        IPoolManager pm = IPoolManager(vm.parseJsonAddress(j, ".poolManager"));

        uint256 swaps = vm.envOr("SEED_SWAPS", uint256(9));
        uint256 minObs = d.oracle.minObservation();
        address me = msg.sender;

        // One swap leg, at least the oracle's threshold with a little headroom so rounding in
        // the pool cannot drop a block below it. Kept tight: every wei above the threshold is
        // a wei of depth the position does not get, and depth is what keeps a swap from
        // exhausting the range and filling for less than the threshold -- which would move
        // tokens and still record nothing.
        uint256 leg = (minObs * 101) / 100;
        // A concentrated range placed entirely on one side of the spot price is funded by one
        // currency only -- v4 computes liquidity from amount0 alone above the range and from
        // amount1 alone below it. Put the range on the side that wants USDC and the position
        // needs no wsUSD at all, so the only minting this script does is the swap inventory.
        bool singleSided = vm.envOr("SEED_SINGLE_SIDED", true);
        uint256 lpLegs = vm.envOr("SEED_LP_LEGS", uint256(1));

        bool wsIs0 = Currency.unwrap(d.key.currency0) == address(d.wsusd);
        uint256 have = IERC20(usdc).balanceOf(me);

        uint256 wsForLp = singleSided ? 0 : leg * lpLegs;
        uint256 usdcForMint = ((leg + wsForLp) / 1e12) + 2; // mint fee eats a little
        // The floor: depth has to cover a whole leg, or the swap walks out of the range and
        // fills for less than the oracle counts.
        uint256 need = usdcForMint + (leg / 1e12) + 1;
        // Above that floor, the position takes everything left over. A fixed multiple would
        // leave USDC idle in the deployer while the range it is meant to defend runs thin.
        uint256 usdcForLp = singleSided && have > need
            ? have - usdcForMint - 1
            : ((leg * lpLegs) / 1e12) + 1;
        console2.log("minObservation (wsUSD wei)", minObs);
        console2.log("USDC needed (6dp)         ", need);
        console2.log("USDC for depth (6dp)      ", usdcForLp);
        console2.log("USDC held   (6dp)         ", have);
        if (have < need) {
            console2.log("SHORTFALL (6dp)           ", need - have);
            console2.log("Get test USDC from faucet.circle.com (20 per claim) and run again.");
            revert("SeedPoolSepolia: not enough test USDC");
        }

        (uint160 sqrtP, int24 tick,,) = pm.getSlot0(d.key.toId());
        int24 span = int24(int256(vm.envOr("SEED_TICKS", uint256(300))));
        int24 sp = d.key.tickSpacing;
        int24 lower;
        int24 upper;
        if (singleSided) {
            // Strictly one side of spot, so the position is funded in USDC alone. Which side
            // that is depends on the pool's currency order, and the first swap has to be the
            // one that consumes this liquidity: selling wsUSD moves the price towards the
            // USDC-only side, which is exactly the direction the swap loop starts in.
            if (wsIs0) {
                upper = ((tick - sp) / sp) * sp;
                lower = ((tick - span) / sp) * sp;
            } else {
                lower = ((tick + sp) / sp) * sp;
                upper = ((tick + span) / sp) * sp;
            }
            require(lower < upper, "SeedPoolSepolia: SEED_TICKS too narrow");
        } else {
            lower = ((tick - span) / sp) * sp;
            upper = ((tick + span) / sp) * sp;
        }

        vm.startBroadcast(me);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        PoolSwapTest router = new PoolSwapTest(pm);

        IERC20(usdc).approve(address(d.stabilizer), usdcForMint);
        d.stabilizer.mint(usdcForMint, me, 0);
        d.token.approve(address(d.wsusd), type(uint256).max);
        d.wsusd.deposit(d.token.balanceOf(me), me);

        d.wsusd.approve(address(lp), type(uint256).max);
        IERC20(usdc).approve(address(lp), type(uint256).max);
        d.wsusd.approve(address(router), type(uint256).max);
        IERC20(usdc).approve(address(router), type(uint256).max);

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            wsIs0 ? wsForLp : usdcForLp,
            wsIs0 ? usdcForLp : wsForLp
        );
        require(liq > 0, "SeedPoolSepolia: zero liquidity");
        lp.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liq)), salt: bytes32(0)}),
            ""
        );
        console2.log("liquidity added", uint256(liq));

        // Alternating direction, one transaction each so every swap lands in its own block.
        for (uint256 i; i < swaps; ++i) {
            bool zeroForOne = (i % 2 == 0) ? wsIs0 : !wsIs0;
            router.swap(
                d.key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(leg),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        vm.stopBroadcast();

        console2.log("oracle filled    ", d.oracle.filled());
        console2.log("smoothedEntropy  ", d.oracle.smoothedEntropy());
    }
}

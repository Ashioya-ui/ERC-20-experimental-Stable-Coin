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

import {SpectrumDeploy} from "../lib/SpectrumDeploy.sol";

/// @title  Scenario (rehearsal steps after deployment)
/// @notice Day-one flows against the rehearsal deployment, each broadcast as real
///         transactions on anvil (one block per transaction with --slow).
contract Scenario is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function _load() internal view returns (SpectrumDeploy.Deployment memory d, address usdc, address pm) {
        d = SpectrumDeploy.loadDeployment("deployments/31337.json");
        string memory env = vm.readFile("deployments/31337-env.json");
        usdc = vm.parseJsonAddress(env, ".usdc");
        pm = vm.parseJsonAddress(env, ".poolManager");
    }

    /// LP at par, then nine swaps (one block each) so the oracle fills and folds a window.
    function seedPoolAndSwap() external {
        (SpectrumDeploy.Deployment memory d, address usdc, address pm) = _load();
        string memory env = vm.readFile("deployments/31337-env.json");
        PoolModifyLiquidityTest lp = PoolModifyLiquidityTest(vm.parseJsonAddress(env, ".lpRouter"));
        PoolSwapTest router = PoolSwapTest(vm.parseJsonAddress(env, ".swapRouter"));
        bool wsIs0 = Currency.unwrap(d.key.currency0) == address(d.wsusd);
        (uint160 sqrtP, int24 tick,,) = IPoolManager(pm).getSlot0(d.key.toId());

        vm.startBroadcast(msg.sender);
        IERC20(usdc).approve(address(d.stabilizer), 3_000e6);
        d.stabilizer.mint(3_000e6, msg.sender, 0);
        d.token.approve(address(d.wsusd), type(uint256).max);
        d.wsusd.deposit(2_900e18, msg.sender);
        d.wsusd.approve(address(lp), type(uint256).max);
        IERC20(usdc).approve(address(lp), type(uint256).max);
        d.wsusd.approve(address(router), type(uint256).max);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(tick - 100),
            TickMath.getSqrtPriceAtTick(tick + 100),
            wsIs0 ? 2_000e18 : 2_000e6,
            wsIs0 ? 2_000e6 : 2_000e18
        );
        lp.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: tick - 100,
                tickUpper: tick + 100,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        );
        for (uint256 i; i < 9; ++i) {
            router.swap(
                d.key,
                SwapParams({
                    zeroForOne: wsIs0,
                    amountSpecified: -int256((i + 1) * 10e18),
                    sqrtPriceLimitX96: wsIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        vm.stopBroadcast();
    }

    /// The payer mints sUSD, signs an x402 "exact" EIP-3009 authorization; the facilitator
    /// submits it and pays the gas.
    function payWithSUSD() external {
        (SpectrumDeploy.Deployment memory d, address usdc,) = _load();
        uint256 payerPk = vm.envUint("REHEARSAL_PAYER_PK");
        uint256 facilitatorPk = vm.envUint("REHEARSAL_FACILITATOR_PK");
        address payer = vm.addr(payerPk);
        address merchant = vm.envAddress("REHEARSAL_MERCHANT");

        vm.startBroadcast(payerPk);
        IERC20(usdc).approve(address(d.stabilizer), 1_000e6);
        d.stabilizer.mint(1_000e6, payer, 0);
        vm.stopBroadcast();

        bytes32 nonce = keccak256(abi.encode("rehearsal-x402", block.timestamp));
        uint256 validBefore = block.timestamp + 600;
        uint256 value = 0.005e18;
        bytes32 structHash =
            keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, merchant, value, 0, validBefore, nonce));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(payerPk, keccak256(abi.encodePacked("\x19\x01", d.token.DOMAIN_SEPARATOR(), structHash)));

        vm.startBroadcast(facilitatorPk);
        d.token.transferWithAuthorization(payer, merchant, value, 0, validBefore, nonce, v, r, s);
        vm.stopBroadcast();
        console2.log("x402 sUSD payment settled; merchant balance (wei):", d.token.balanceOf(merchant));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Mainnet scenarios: the exact deployment procedure (SpectrumDeploy) followed by the
//  flows that matter on day one. Two environments run the same tests:
//
//  - LocalMainnetRehearsalTest: Circle FiatToken v2.2 bytecode as USDC, a real Uniswap v4
//    PoolManager, and lending-vault stand-ins. Always runs.
//  - BaseMainnetForkTest: a fork of Base mainnet with the addresses in config/8453.json
//    (native USDC, Uniswap v4 PoolManager, Aave waBasUSDC, Gauntlet USDC Prime).
//    Runs when BASE_RPC_URL is set; skipped otherwise.
// =====================================================================================

import {LendingVaultMock} from "../mocks/LendingVaultMock.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";
import {AutonomousTreasury} from "../../src/AutonomousTreasury.sol";
import {SpectrumDeploy} from "../../script/lib/SpectrumDeploy.sol";
import {LocalEnv} from "../../script/lib/LocalEnv.sol";
import {IFiatToken} from "../../script/lib/IFiatToken.sol";

abstract contract MainnetScenarios is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    SpectrumDeploy.Config internal cfg;
    SpectrumDeploy.Deployment internal d;

    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal merchant = makeAddr("merchant");
    address internal facilitator = makeAddr("facilitator");
    uint256 internal constant PAYER_PK = 0xA11CE5;
    address internal payer;

    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;

    // ------------------------------------------------------------------ environment hooks

    /// @dev Fill `cfg` (addresses from the environment, parameters from config/8453.json).
    function _setUpEnv() internal virtual;

    function _fundUSDC(address to, uint256 amount) internal virtual;

    /// @dev Make the vault position earn comfortably more than the 2.75% neutral buffer.
    function _accrueVaultYield() internal virtual;

    // ------------------------------------------------------------------ setup

    function setUp() public virtual {
        payer = vm.addr(PAYER_PK);
        _setUpEnv();
        cfg.chainId = block.chainid;
        cfg.admin = safe; // a Safe on mainnet; an address here
        cfg.guardian = guardian;
        cfg.allowEoaAdmin = true;

        _fundUSDC(address(this), cfg.seedUsdc + cfg.seedCapitalUsdc);
        SpectrumDeploy.preflight(cfg, address(this));
        d = SpectrumDeploy.deploy(cfg, address(this));
        SpectrumDeploy.check(cfg, d, address(this));

        lpRouter = new PoolModifyLiquidityTest(IPoolManager(cfg.poolManager));
        swapRouter = new PoolSwapTest(IPoolManager(cfg.poolManager));
    }

    // ------------------------------------------------------------------ helpers

    function _mintSUSD(address who, uint256 usdcAmount) internal returns (uint256 out) {
        _fundUSDC(who, usdcAmount);
        vm.startPrank(who);
        IERC20(cfg.usdc).approve(address(d.stabilizer), usdcAmount);
        out = d.stabilizer.mint(usdcAmount, who, 0);
        vm.stopPrank();
    }

    function _assertSolvent() internal view {
        assertGe(d.stabilizer.reserveValue(), d.token.totalSupply(), "reserve floor");
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
    }

    function _wsIs0() internal view returns (bool) {
        return Currency.unwrap(d.key.currency0) == address(d.wsusd);
    }

    /// @dev LP about 1,900 wsUSD + 1,900 USDC around par (+-1%); keeps 600 wsUSD to trade.
    function _seedPool() internal {
        _mintSUSD(address(this), 2_600e6);
        d.token.approve(address(d.wsusd), type(uint256).max);
        d.wsusd.deposit(2_500e18, address(this));
        _fundUSDC(address(this), 2_000e6);
        d.wsusd.approve(address(lpRouter), type(uint256).max);
        IERC20(cfg.usdc).approve(address(lpRouter), type(uint256).max);
        d.wsusd.approve(address(swapRouter), type(uint256).max);
        IERC20(cfg.usdc).approve(address(swapRouter), type(uint256).max);

        (uint160 sqrtP, int24 tick,,) = IPoolManager(cfg.poolManager).getSlot0(d.key.toId());
        int24 lower = tick - 100;
        int24 upper = tick + 100;
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            _wsIs0() ? 1_900e18 : 1_900e6,
            _wsIs0() ? 1_900e6 : 1_900e18
        );
        lpRouter.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _sellWs(uint256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = _wsIs0();
        return swapRouter.swap(
            d.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sign3009(bytes32 domainSeparator, address to, uint256 value, bytes32 nonce, uint256 validBefore)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, to, value, 0, validBefore, nonce));
        (v, r, s) = vm.sign(PAYER_PK, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
    }

    // ------------------------------------------------------------------ scenarios

    function test_deploymentMatchesConfig() public view {
        assertEq(d.oracle.smoothedEntropy(), 0.5e18, "neutral entropy at launch");
        assertEq(d.stabilizer.mintFeeRate(0.5e18), 0.0007e18, "7 bp mint fee at neutral entropy");
        assertEq(d.stabilizer.supplyCap(), 25_000e18);
        assertEq(d.treasury.liquidityBufferBps(), 1_500);
        assertEq(d.wsusd.balanceOf(SpectrumDeploy.DEAD), 1e18, "dead shares seeded");
        assertTrue(d.stabilizer.hasRole(d.stabilizer.DEFAULT_ADMIN_ROLE(), safe));
        assertFalse(d.stabilizer.hasRole(d.stabilizer.DEFAULT_ADMIN_ROLE(), address(this)));
        assertEq(d.key.fee, 100);
        assertEq(address(d.treasury.vault()), cfg.vault);
        // B8: 1,250 USDC of first-loss protocol capital, 5% of the 25,000 sUSD cap.
        assertApproxEqAbs(d.stabilizer.protocolCapital(), 1_250e18, 2e12, "protocol capital seeded");
        assertGe(d.stabilizer.reserveValue(), d.token.totalSupply() + 1_249e18, "the cushion is in the reserve");
    }

    function test_mintAndRedeemThroughVaultAndBuffer() public {
        uint256 out = _mintSUSD(payer, 1_000e6);
        assertApproxEqRel(out, 999.3e18, 1e14, "1,000 USDC at 7 bp");
        uint256 reserve = d.treasury.reserveAssets();
        assertApproxEqRel(d.treasury.idleAssets(), (reserve * 15) / 100, 1e15, "15% idle");
        assertGt(IERC4626(cfg.vault).balanceOf(address(d.treasury)), 0, "rest in the vault");
        _assertSolvent();

        uint256 before = IERC20(cfg.usdc).balanceOf(payer);
        vm.prank(payer);
        uint256 got = d.stabilizer.redeem(500e18, payer, 0);
        assertEq(IERC20(cfg.usdc).balanceOf(payer) - before, got);
        assertApproxEqRel(got, 499.8375e6, 1e14, "500 sUSD at 3.25 bp");
        vm.prank(payer);
        d.stabilizer.redeem(type(uint256).max, payer, 0);
        assertEq(d.token.balanceOf(payer), 0);
        _assertSolvent();
    }

    function test_x402PaymentInSUSD() public {
        _mintSUSD(payer, 100e6);
        bytes32 nonce = keccak256("x402-susd-1");
        uint256 validBefore = vm.getBlockTimestamp() + 60;
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(d.token.DOMAIN_SEPARATOR(), merchant, 0.005e18, nonce, validBefore);
        vm.prank(facilitator);
        d.token.transferWithAuthorization(payer, merchant, 0.005e18, 0, validBefore, nonce, v, r, s);
        assertGe(d.token.balanceOf(merchant), 0.005e18);
        vm.prank(facilitator);
        vm.expectRevert();
        d.token.transferWithAuthorization(payer, merchant, 0.005e18, 0, validBefore, nonce, v, r, s);
    }

    /// The report's recommended x402 asset: native USDC (FiatToken v2.2) via EIP-3009.
    function test_x402PaymentInUSDC() public {
        _fundUSDC(payer, 10e6);
        IFiatToken usdc = IFiatToken(cfg.usdc);
        bytes32 nonce = keccak256("x402-usdc-1");
        uint256 validBefore = vm.getBlockTimestamp() + 60;
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(usdc.DOMAIN_SEPARATOR(), merchant, 5_000, nonce, validBefore);
        uint256 before = usdc.balanceOf(merchant);
        vm.prank(facilitator);
        usdc.transferWithAuthorization(payer, merchant, 5_000, 0, validBefore, nonce, v, r, s);
        assertEq(usdc.balanceOf(merchant) - before, 5_000);
        assertTrue(usdc.authorizationState(payer, nonce));
    }

    function test_poolSwapsFeedOracleAndOtherPoolsAreRejected() public {
        _seedPool();
        for (uint256 i; i < 9; ++i) {
            _nextBlock();
            _sellWs((i + 1) * 10e18);
        }
        assertEq(d.oracle.filled(), 8);
        uint256[8] memory w = d.oracle.window();
        assertEq(w[7], 90e18, "per-block notional of the measured wsUSD leg");
        assertTrue(d.oracle.rawEma() != 0.5e18, "a closed window was folded into the EMA");

        PoolKey memory other = d.key;
        other.fee = 500;
        other.tickSpacing = 10;
        uint160 par = SpectrumDeploy.parSqrtPriceX96(other);
        vm.expectRevert();
        IPoolManager(cfg.poolManager).initialize(other, par);
    }

    /// B8 (spec change): with protocol capital covering the buffer, fees and yield reach
    /// holders from day one instead of after the buffer fills (about ten months at 4% APY).
    function test_yieldFlowsToHoldersFromDayOne() public {
        _mintSUSD(payer, 5_000e6);
        uint256 index0 = d.token.index();
        assertGt(d.lens.distributable(), 0, "mint fees are distributable at once");
        assertTrue(d.stabilizer.rebase(), "the first rebase distributes on launch day");
        uint256 index1 = d.token.index();
        assertGt(index1, index0);
        _accrueVaultYield();
        assertTrue(d.stabilizer.rebase(), "and vault yield after it");
        assertGt(d.token.index(), index1);
        assertGe(
            d.stabilizer.reserveValue(),
            d.token.totalSupply() + d.stabilizer.protocolCapital(),
            "distributions never reach the capital"
        );
        _assertSolvent();
    }

    function test_emergencyExitThenMigrationToFallbackVault() public {
        _mintSUSD(payer, 5_000e6);
        vm.prank(guardian);
        uint256 recovered = d.stabilizer.emergencyExitVault();
        assertGt(recovered, 4_000e6);
        assertEq(IERC4626(cfg.vault).balanceOf(address(d.treasury)), 0, "vault fully exited");
        _assertSolvent();

        vm.prank(safe);
        d.stabilizer.proposeVault(IERC4626(cfg.fallbackVault));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(safe);
        d.stabilizer.executeVaultMigration(1_000);
        vm.prank(safe);
        d.stabilizer.setLiquidityBuffer(1_500);
        d.stabilizer.rebalanceReserve();

        assertEq(address(d.treasury.vault()), cfg.fallbackVault);
        assertGt(IERC4626(cfg.fallbackVault).balanceOf(address(d.treasury)), 0, "reserve now earns in the fallback");
        vm.prank(payer);
        d.stabilizer.redeem(1_000e18, payer, 0);
        _assertSolvent();
    }

    function test_supplyCapGuardsTheLaunch() public {
        _mintSUSD(payer, 1_000e6);
        uint256 supply = d.token.totalSupply();
        vm.prank(safe);
        d.stabilizer.setSupplyCap(supply);
        _fundUSDC(payer, 10e6);
        vm.startPrank(payer);
        IERC20(cfg.usdc).approve(address(d.stabilizer), 10e6);
        vm.expectRevert(abi.encodeWithSelector(SpectralStabilizer.SupplyCapExceeded.selector, 0));
        d.stabilizer.mint(10e6, payer, 0);
        vm.stopPrank();
    }
}

/// @notice Mainnet-shaped local chain: Circle FiatToken v2.2 bytecode, real v4 PoolManager.
contract LocalMainnetRehearsalTest is MainnetScenarios {
    LocalEnv.Env internal env;

    function _setUpEnv() internal override {
        vm.warp(1_760_000_000); // a realistic clock (Oct 2025)
        vm.roll(36_000_000);
        if (SpectrumDeploy.CREATE2_DEPLOYER.code.length == 0) {
            vm.etch(SpectrumDeploy.CREATE2_DEPLOYER, LocalEnv.CREATE2_PROXY_RUNTIME);
        }
        env = LocalEnv.deploy(address(this), makeAddr("usdcProxyAdmin"));
        cfg = SpectrumDeploy.loadConfig("config/8453.json"); // mainnet parameters
        cfg.poolManager = env.poolManager;
        cfg.usdc = env.usdc;
        cfg.vault = env.vault;
        cfg.fallbackVault = env.fallbackVault;
    }

    function _fundUSDC(address to, uint256 amount) internal override {
        IFiatToken(env.usdc).mint(to, amount);
    }

    function _accrueVaultYield() internal override {
        uint256 assets = IERC4626(env.vault).totalAssets();
        IFiatToken(env.usdc).mint(env.vault, (assets * 6) / 100); // 6% on the vault position
        vm.warp(vm.getBlockTimestamp() + 1 hours);
    }

    /// A9 and B8: on launch day, a 4% vault loss lowers no balance, so exiting ahead of it
    /// gains nothing; distributions then pause until yield rebuilds the capital.
    function test_launchCapitalAbsorbsALoss() public {
        _mintSUSD(payer, 5_000e6);
        uint256 index0 = d.token.index();
        uint256 loss = (d.token.totalSupply() * 4) / 100 / 1e12; // 4% of supply, in USDC
        LendingVaultMock(env.vault).simulateLoss(loss);
        d.stabilizer.sync();
        assertEq(d.token.index(), index0, "the capital took the loss, not the holders");
        _assertSolvent();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(SpectralStabilizer.NothingToDistribute.selector);
        d.stabilizer.rebase(); // capital is rebuilt from yield before anything is distributed
    }

    function test_localUsesRealFiatTokenBytecode() public view {
        IFiatToken usdc = IFiatToken(env.usdc);
        assertEq(usdc.name(), "USD Coin");
        assertEq(usdc.version(), "2");
        assertEq(usdc.decimals(), 6);
    }
}

/// @notice Base mainnet fork. Set BASE_RPC_URL (an archive-capable endpoint) to run:
///         forge test --match-contract BaseMainnetForkTest -vv
contract BaseMainnetForkTest is MainnetScenarios {
    function _setUpEnv() internal override {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        cfg = SpectrumDeploy.loadConfig("config/8453.json");
        require(block.chainid == 8453, "BASE_RPC_URL is not Base mainnet");
    }

    function _fundUSDC(address to, uint256 amount) internal override {
        deal(cfg.usdc, to, IERC20(cfg.usdc).balanceOf(to) + amount);
    }

    function _accrueVaultYield() internal override {
        // Aave Base USDC has paid about 3.3-4.2% (report, Oct 2026); three years clears the
        // 2.75% neutral buffer on the 85% invested share with room to spare.
        vm.warp(vm.getBlockTimestamp() + 3 * 365 days);
    }
}

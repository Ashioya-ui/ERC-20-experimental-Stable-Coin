// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Phase 4, A12: the protocol against real vault code, without a Base RPC.
//
//  The Base fork suite (test/mainnet, BaseMainnetForkTest) needs BASE_RPC_URL, and this
//  workspace cannot reach Base. Gauntlet USDC Prime, the fallback vault in config/8453.json, is
//  a MetaMorpho v1.0 vault lending on Morpho Blue. Here both are the real contracts, compiled
//  from their GitHub sources at the v1.0.0 tags (test/artifacts/morpho, provenance in
//  test/artifacts/README.md), with Circle's FiatToken v2.2 as USDC and a real Uniswap v4
//  PoolManager, deployed through the same SpectrumDeploy procedure as mainnet.
//
//  Borrowers really borrow, interest really accrues, and liquidations really realise bad debt,
//  so liquidity squeezes and vault losses come from Morpho's own accounting, not from mock
//  knobs. Aave waBasUSDC (the primary vault) is exercised only by the fork job.
// =====================================================================================

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SpectrumDeploy} from "../../script/lib/SpectrumDeploy.sol";
import {LocalEnv} from "../../script/lib/LocalEnv.sol";
import {IFiatToken} from "../../script/lib/IFiatToken.sol";
import {AutonomousTreasury} from "../../src/AutonomousTreasury.sol";
import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorphoBlue {
    function enableIrm(address irm) external;
    function enableLltv(uint256 lltv) external;
    function createMarket(MarketParams memory marketParams) external;
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;
    function borrow(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);
    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256);
    function accrueInterest(MarketParams memory marketParams) external;
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}

interface IMetaMorphoV1 is IERC4626 {
    function submitCap(MarketParams memory marketParams, uint256 newSupplyCap) external;
    function acceptCap(MarketParams memory marketParams) external;
    function setSupplyQueue(bytes32[] calldata newSupplyQueue) external;
}

interface IOracleMock {
    function setPrice(uint256 newPrice) external;
}

interface IERC20Mock {
    function setBalance(address account, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

contract MorphoReplicaTest is Test {
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant PAR = 1e24; // 1 collateral (18 dp) = 1 USDC (6 dp), Morpho's 1e36 scale

    LocalEnv.Env internal env;
    SpectrumDeploy.Config internal cfg;
    SpectrumDeploy.Deployment internal d;

    IMorphoBlue internal morpho;
    IMetaMorphoV1 internal vaultA; // the vault the treasury starts in
    IMetaMorphoV1 internal vaultB; // the allowlisted fallback
    MarketParams internal mp;
    bytes32 internal marketId;
    address internal oracle;
    address internal collateral;

    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal holder = makeAddr("holder");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    // ------------------------------------------------------------------ setup

    function _deployBin(string memory name, bytes memory args) internal returns (address a) {
        bytes memory code =
            abi.encodePacked(vm.parseBytes(vm.readFile(string.concat("test/artifacts/morpho/", name, ".bin"))), args);
        assembly {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), string.concat("deploy failed: ", name));
    }

    function _newMetaMorpho(string memory name, string memory symbol) internal returns (IMetaMorphoV1 v) {
        v = IMetaMorphoV1(_deployBin("MetaMorpho", abi.encode(address(this), address(morpho), 1 days, env.usdc, name, symbol)));
        v.submitCap(mp, 1e15); // 1 billion USDC, behind MetaMorpho's own 1-day timelock
        vm.warp(vm.getBlockTimestamp() + 1 days);
        v.acceptCap(mp);
        bytes32[] memory queue = new bytes32[](1);
        queue[0] = marketId;
        v.setSupplyQueue(queue);
    }

    function setUp() public {
        vm.warp(1_760_000_000);
        vm.roll(36_000_000);
        if (SpectrumDeploy.CREATE2_DEPLOYER.code.length == 0) {
            vm.etch(SpectrumDeploy.CREATE2_DEPLOYER, LocalEnv.CREATE2_PROXY_RUNTIME);
        }
        env = LocalEnv.deploy(address(this), makeAddr("usdcProxyAdmin"));

        morpho = IMorphoBlue(_deployBin("Morpho", abi.encode(address(this))));
        address irm = _deployBin("IrmMock", ""); // x% utilisation = x% APR
        oracle = _deployBin("OracleMock", "");
        collateral = _deployBin("ERC20Mock", "");
        IOracleMock(oracle).setPrice(PAR);
        morpho.enableIrm(irm);
        morpho.enableLltv(LLTV);
        mp = MarketParams(env.usdc, collateral, oracle, irm, LLTV);
        marketId = keccak256(abi.encode(mp));
        morpho.createMarket(mp);
        vaultA = _newMetaMorpho("MetaMorpho USDC A (local)", "mmA");
        vaultB = _newMetaMorpho("MetaMorpho USDC B (local)", "mmB");

        cfg = SpectrumDeploy.loadConfig("config/8453.json"); // mainnet parameters
        cfg.chainId = block.chainid;
        cfg.poolManager = env.poolManager;
        cfg.usdc = env.usdc;
        cfg.vault = address(vaultA);
        cfg.fallbackVault = address(vaultB);
        cfg.admin = safe;
        cfg.guardian = guardian;
        cfg.allowEoaAdmin = true;
        _fund(address(this), cfg.seedUsdc + cfg.seedCapitalUsdc);
        SpectrumDeploy.preflight(cfg, address(this));
        d = SpectrumDeploy.deploy(cfg, address(this));
        SpectrumDeploy.check(cfg, d, address(this));
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address to, uint256 amount) internal {
        IFiatToken(env.usdc).mint(to, amount);
    }

    function _mint(address who, uint256 usdcAmount) internal returns (uint256 out) {
        _fund(who, usdcAmount);
        vm.startPrank(who);
        IERC20(env.usdc).approve(address(d.stabilizer), usdcAmount);
        out = d.stabilizer.mint(usdcAmount, who, 0);
        vm.stopPrank();
    }

    /// @dev Borrow `amount` USDC against 1.25x its value in collateral (80% LTV).
    function _borrow(uint256 amount) internal {
        uint256 coll = (amount * 1e12 * 125) / 100;
        IERC20Mock(collateral).setBalance(borrower, coll);
        vm.startPrank(borrower);
        IERC20Mock(collateral).approve(address(morpho), coll);
        morpho.supplyCollateral(mp, coll, borrower, "");
        morpho.borrow(mp, amount, 0, borrower, borrower);
        vm.stopPrank();
    }

    function _marketLiquidity() internal view returns (uint256) {
        (uint128 supplied,, uint128 borrowed,,,) = morpho.market(marketId);
        return supplied - borrowed;
    }

    function _assertSolvent() internal view {
        assertGe(d.stabilizer.reserveValue(), d.token.totalSupply(), "reserve floor");
    }

    // ------------------------------------------------------------------ scenarios

    function test_deploysIntoARealMetaMorphoVault() public view {
        assertEq(address(d.treasury.vault()), address(vaultA));
        assertTrue(d.stabilizer.isAllowedVault(address(vaultB)));
        assertGt(vaultA.balanceOf(address(d.treasury)), 0, "protocol capital is lent out through MetaMorpho");
        (uint256 supplyShares,,) = morpho.position(marketId, address(vaultA));
        assertGt(supplyShares, 0, "and MetaMorpho supplied it to the Morpho Blue market");
    }

    /// Gas of the user paths against the real vault, measured around each external call.
    function test_gasAgainstRealMetaMorpho() public {
        _fund(holder, 2_000e6);
        vm.startPrank(holder);
        IERC20(env.usdc).approve(address(d.stabilizer), type(uint256).max);
        d.stabilizer.mint(1_000e6, holder, 0); // warm-up: first deposit into the market position
        uint256 g = gasleft();
        d.stabilizer.mint(1_000e6, holder, 0);
        uint256 mintGas = g - gasleft();
        g = gasleft();
        d.stabilizer.redeem(400e18, holder, 0); // paid from the idle buffer
        uint256 redeemIdleGas = g - gasleft();
        g = gasleft();
        d.stabilizer.redeem(1_000e18, holder, 0); // needs the vault: MetaMorpho -> Morpho Blue
        uint256 redeemVaultGas = g - gasleft();
        vm.stopPrank();
        _borrow(500e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        g = gasleft();
        d.stabilizer.rebase();
        uint256 rebaseGas = g - gasleft();
        emit log_named_uint("mint, 1,000 USDC (MetaMorpho deposit)", mintGas);
        emit log_named_uint("redeem from the idle buffer", redeemIdleGas);
        emit log_named_uint("redeem through MetaMorpho", redeemVaultGas);
        emit log_named_uint("rebase (interest accrued)", rebaseGas);
        assertLt(mintGas, 400_000);
        assertLt(redeemVaultGas, 300_000);
        _assertSolvent();
    }

    /// Borrowers pay interest, MetaMorpho's share price rises, and holders receive it.
    function test_interestReachesHolders() public {
        _mint(holder, 10_000e6);
        _borrow(6_000e6);
        uint256 index0 = d.token.index();
        uint256 reserve0 = d.stabilizer.reserveValue();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        morpho.accrueInterest(mp);
        assertGt(d.stabilizer.reserveValue(), reserve0 + 30e18, "a month of interest at about 60% utilisation");
        for (uint256 i; i < 48; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            d.stabilizer.rebase();
        }
        assertGt(d.token.index(), index0, "interest distributed");
        assertGe(d.stabilizer.reserveValue(), d.token.totalSupply() + d.stabilizer.protocolCapital(), "capital kept");
        _assertSolvent();
    }

    /// Borrowers take all the market's cash: MetaMorpho's maxWithdraw falls to 0, redemptions
    /// are paid from the idle buffer, and beyond it they revert with the exact amount available.
    function test_liquiditySqueeze() public {
        _mint(holder, 10_000e6);
        _borrow(_marketLiquidity());
        assertEq(vaultA.maxWithdraw(address(d.treasury)), 0, "the vault is fully lent out");
        uint256 idle = d.treasury.idleAssets();
        assertGt(idle, 1_400e6, "15% idle");

        vm.prank(holder);
        d.stabilizer.redeem(1_000e18, holder, 0); // inside the buffer: paid
        uint256 left = d.treasury.idleAssets();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(AutonomousTreasury.InsufficientLiquidity.selector, left));
        d.stabilizer.redeem(left * 1e12 + 100e18, holder, 0);
        _assertSolvent();
    }

    /// The guardian's exit takes what the vault can pay now, and can be repeated as borrowers
    /// repay.
    function test_emergencyExitIsPartialThenComplete() public {
        _mint(holder, 10_000e6);
        uint256 liq = _marketLiquidity();
        _borrow((liq * 90) / 100);
        vm.prank(guardian);
        uint256 first = d.stabilizer.emergencyExitVault();
        assertGt(vaultA.balanceOf(address(d.treasury)), 0, "part of the position is stuck");
        assertApproxEqRel(first, (liq * 10) / 100, 0.02e18, "about the 10% of cash left");

        _fund(borrower, 20_000e6);
        vm.startPrank(borrower);
        IERC20(env.usdc).approve(address(morpho), type(uint256).max);
        (, uint128 borrowShares,) = morpho.position(marketId, borrower);
        morpho.repay(mp, 0, borrowShares, borrower, "");
        vm.stopPrank();

        vm.prank(guardian);
        d.stabilizer.emergencyExitVault();
        assertEq(vaultA.balanceOf(address(d.treasury)), 0, "fully out after the repayment");
        _assertSolvent();
    }

    /// The 7-day migration from one real MetaMorpho vault to the other keeps the reserve.
    function test_migrationBetweenTwoRealVaults() public {
        _mint(holder, 10_000e6);
        uint256 reserve0 = d.stabilizer.reserveValue();
        vm.prank(safe);
        d.stabilizer.proposeVault(vaultB);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(safe);
        d.stabilizer.executeVaultMigration();
        assertEq(address(d.treasury.vault()), address(vaultB));
        assertEq(vaultA.balanceOf(address(d.treasury)), 0, "nothing left behind");
        assertApproxEqAbs(d.stabilizer.reserveValue(), reserve0, 5e12, "reserve kept, to vault rounding");
        vm.prank(holder);
        d.stabilizer.redeem(5_000e18, holder, 0);
        _assertSolvent();
    }

    /// Migrating out of a fully lent-out vault quarantines the stuck shares, the capital covers
    /// the loss, and the shares come back as surplus once borrowers repay.
    function test_migrationFromAnIlliquidVaultQuarantinesThenRecovers() public {
        _mint(holder, 10_000e6);
        _borrow(_marketLiquidity());
        uint256 index0 = d.token.index();
        vm.prank(safe);
        d.stabilizer.proposeVault(vaultB);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(safe);
        d.stabilizer.executeVaultMigration();
        assertEq(address(d.treasury.legacyVault()), address(vaultA), "stuck shares quarantined");
        assertLt(d.token.index(), index0, "the quarantined value is a realised loss, shared pro rata");
        _assertSolvent();

        _fund(borrower, 20_000e6);
        vm.startPrank(borrower);
        IERC20(env.usdc).approve(address(morpho), type(uint256).max);
        (, uint128 borrowShares,) = morpho.position(marketId, borrower);
        morpho.repay(mp, 0, borrowShares, borrower, "");
        vm.stopPrank();
        uint256 recovered = d.treasury.recoverLegacy();
        // MetaMorpho's maxRedeem rounds a few hundred million shares (1e-12 USDC each) short
        // of the balance; without the dust rule this dust kept legacyVault set (A12 finding).
        assertLe(vaultA.previewRedeem(vaultA.balanceOf(address(d.treasury))), d.treasury.LEGACY_DUST_ASSETS());
        assertGt(recovered, 8_000e6, "the stuck position comes back");
        assertEq(address(d.treasury.legacyVault()), address(0));
        assertGt(d.stabilizer.reserveValue(), d.token.totalSupply() + d.stabilizer.protocolCapital(), "as surplus");
    }

    /// A liquidation that leaves bad debt is a real loss in Morpho Blue, which MetaMorpho v1.0
    /// passes on at once. Inside the cushion it lowers no balance.
    function test_badDebtInsideTheCushionLowersNoBalance() public {
        _mint(holder, 9_500e6);
        _borrow(1_000e6); // against 1,250 of collateral
        uint256 index0 = d.token.index();
        IOracleMock(oracle).setPrice(PAR * 40 / 100); // collateral now worth 500: about 520 of bad debt
        _liquidateAll();
        uint256 loss = d.token.totalSupply() + d.stabilizer.protocolCapital() - d.stabilizer.reserveValue();
        emit log_named_decimal_uint("bad debt passed to the reserve (sUSD)", loss, 18);
        d.stabilizer.sync();
        assertEq(d.token.index(), index0, "the capital and surplus absorbed it");
        _assertSolvent();
    }

    /// Bad debt beyond the cushion is shared pro rata, and nobody can redeem at the old price.
    function test_badDebtBeyondTheCushionIsSharedProRata() public {
        _mint(holder, 9_500e6);
        _borrow(6_000e6); // against 7,500 of collateral
        uint256 balance0 = d.token.balanceOf(holder);
        IOracleMock(oracle).setPrice(PAR / 2); // collateral now worth 3,750: about 2,400 of bad debt
        _liquidateAll();
        vm.prank(holder);
        d.stabilizer.redeem(1_000e18, holder, 0); // sync runs first: no exit at the old price
        uint256 lossBps = ((balance0 - d.token.balanceOf(holder) - 1_000e18) * 10_000) / balance0;
        emit log_named_uint("holder's loss (bps) after the cushion", lossBps);
        assertGt(lossBps, 1_000, "about 1,150 of bad debt beyond the 1,250 capital, on 9,500");
        assertLt(lossBps, 1_400);
        // supply = reserve after the loss, plus the 0.325 sUSD fee the redemption left behind
        assertApproxEqAbs(d.stabilizer.reserveValue(), d.token.totalSupply() + 0.325e18, 1e15, "supply = reserve");
        _assertSolvent();
    }

    function _liquidateAll() internal {
        (,, uint128 coll) = morpho.position(marketId, borrower);
        _fund(liquidator, 100_000e6);
        vm.startPrank(liquidator);
        IERC20(env.usdc).approve(address(morpho), type(uint256).max);
        morpho.liquidate(mp, borrower, coll, 0, "");
        vm.stopPrank();
    }
}

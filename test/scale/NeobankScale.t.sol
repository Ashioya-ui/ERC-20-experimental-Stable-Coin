// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Phase 5: Spectrum at neobank scale.
//
//  The figures this review starts from are EtherFi's: about $300m of stablecoin deposits,
//  about $1bn of cumulative card spend since 2024, more than 100,000 active cards. These tests
//  run the real stabilizer, treasury and token at that size against the mock lending vault
//  (yield, realised losses, withdrawal liquidity, deposit caps) with a settable H.
//  sim/scale.py runs the same rules over a year; REPORT_SCALE.md has both.
// =====================================================================================

import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";
import {AutonomousTreasury} from "../../src/AutonomousTreasury.sol";
import {SpectrumFixture} from "../utils/SpectrumFixture.sol";

contract NeobankScaleTest is SpectrumFixture {
    uint256 internal constant DEPOSITS = 300_000_000e6; // $300m, USDC units
    uint256 internal constant CAPITAL = 8_250_000e6; // 2.75% of the deposits: the neutral buffer
    uint256 internal constant SPEND_PER_HOUR = 68_493e6; // $600m of card spend a year
    uint256 internal constant HOURLY_YIELD_PPB = 5_570; // (1.05)^(1/8760) - 1 = 5.57e-6
    uint256 internal constant CONFIG_BOOTSTRAP = 10_000e18; // config/8453.json bootstrapCapSUSD

    address internal users = makeAddr("card users"); // the deposit base, as one account
    address internal settlement = makeAddr("card settlement"); // redeems what users spend
    address internal operator = makeAddr("operator"); // posts first-loss capital
    address internal whale = makeAddr("whale");

    function setUp() public {
        liquidityBufferBps = 1_000; // 10% idle
        supplyCap = type(uint256).max; // the admin raises the 25,000 sUSD launch cap for scale
        bootstrapCap = DEPOSITS * SCALE; // deposits arrive on day 0 (onboarding is tested apart)
        _deploySystem();
        oracle.setEntropy(0.5e18); // neutral
    }

    // ------------------------------------------------------------------------------ helpers

    function _seed() internal {
        _mintFor(users, DEPOSITS);
        usdc.mint(operator, CAPITAL);
        vm.startPrank(operator);
        usdc.approve(address(stabilizer), CAPITAL);
        stabilizer.contributeCapital(CAPITAL);
        vm.stopPrank();
        stabilizer.rebalanceReserve();
    }

    /// Largest mint (USDC units) the expansion and supply caps allow right now.
    function _roomAssets() internal view returns (uint256) {
        uint256 room = Math.min(lens.expansionRemaining(), lens.supplyCapRemaining());
        if (room <= 1) return 0;
        uint256 r = stabilizer.mintFeeRate(oracle.smoothedEntropy());
        return Math.mulDiv(room - 1, WAD, WAD - r) / SCALE;
    }

    function _vaultPosition() internal view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(address(treasury)));
    }

    /// Days of maximal net minting from launch to $300m, on a fresh deployment with the
    /// mainnet bootstrap cap and H held at `h`.
    function _onboardingDays(uint256 h) internal returns (uint256 days_) {
        bootstrapCap = CONFIG_BOOTSTRAP;
        liquidityBufferBps = 1_500;
        _deploySystem();
        oracle.setEntropy(h);
        while (token.totalSupply() < DEPOSITS * SCALE) {
            _mintFor(whale, _roomAssets());
            vm.warp(vm.getBlockTimestamp() + 1 days);
            ++days_;
        }
        _assertSolvent();
    }

    // ------------------------------------------------------------------------------ onboarding

    /// P5-01. H is steerable (about eight hours of paced trading, audit/oracle-manipulation.md),
    /// so it may tighten the daily expansion cap but must not loosen it: growth from launch to
    /// $300m must take as long with H steered to 0.05 as at neutral H.
    function test_P5_01_steeringHDownDoesNotSpeedGrowth() public {
        uint256 neutral = _onboardingDays(0.5e18);
        uint256 steered = _onboardingDays(0.05e18);
        uint256 high = _onboardingDays(1e18);
        console2.log("days to $300m, H neutral (0.5):    ", neutral);
        console2.log("days to $300m, H steered to 0.05:  ", steered);
        console2.log("days to $300m, H at 1:             ", high);
        assertEq(steered, neutral, "H below neutral must not loosen the expansion cap");
        assertGt(high, neutral, "high H still tightens it");
    }

    // ------------------------------------------------------------------------------ steady state

    /// Ninety days at $300m: card spend settled every four hours (the card program redeems what
    /// users paid with), the same amount topped up, 5% vault yield and a rebase every hour, a
    /// daily keeper. Every settlement must succeed, the floor must hold every hour, the index
    /// must only rise, and holders must earn about the model's rate. (Settling in batches is
    /// how card programs work; it also keeps the test inside the per-test gas limit under
    /// --isolate, where every call starts cold.)
    function test_ninetyDaysOfCardSpendAt300m() public {
        _seed();
        uint256 idx0 = token.index();
        uint256 rebases;
        uint256 seed = 7;
        uint256 settled;
        for (uint256 hr; hr < 90 * 24; ++hr) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.simulateYield((_vaultPosition() * HOURLY_YIELD_PPB) / 1e9);
            if (hr % 4 == 3) {
                // users pay with sUSD; the card program redeems four hours of it in USDC
                seed = uint256(keccak256(abi.encode(seed)));
                uint256 spend = (4 * SPEND_PER_HOUR * (80 + (seed % 41))) / 100; // +-20%
                vm.prank(users);
                token.transfer(settlement, spend * SCALE);
                uint256 before = usdc.balanceOf(settlement);
                _redeemFor(settlement, token.balanceOf(settlement));
                settled += usdc.balanceOf(settlement) - before;
                _mintFor(users, spend); // top-ups keep deposits flat
            }
            if (hr % 24 == 23) stabilizer.rebalanceReserve();
            try stabilizer.rebase() returns (bool ok) {
                if (ok) ++rebases;
            } catch {}
            assertGe(token.index(), idx0, "no loss, so the index never falls");
            _assertSolvent();
        }
        uint256 gainBps = ((token.index() - idx0) * 10_000) / idx0;
        uint256 idle = treasury.idleAssets();
        uint256 reserve = treasury.reserveAssets();
        console2.log("card spend settled over 90 days ($):", settled / 1e6);
        console2.log("rebases that distributed:           ", rebases);
        console2.log("holder return over 90 days (bp):    ", gainBps);
        console2.log("annualised (bp, simple):            ", (gainBps * 365) / 90);
        console2.log("idle share of the reserve (bp):     ", (idle * 10_000) / reserve);
        // 5% on the 90% invested (capital included) plus fees, over 90 days: about 120 bp.
        assertGe(gainBps, 105, "holders earn close to the vault rate");
        assertGe(
            stabilizer.reserveValue(),
            token.totalSupply() + stabilizer.protocolCapital(),
            "distributions never reach into the capital"
        );
        assertApproxEqRel(idle, (reserve * 1_000) / 10_000, 0.15e18, "idle stays near its 10% target");
    }

    // ------------------------------------------------------------------------------ losses

    /// A realised vault loss at $300m with the operator's capital in place: balances are cut
    /// only by what the surplus and the capital cannot cover, exactly.
    function test_vaultLossesAt300m() public {
        uint256[4] memory lossBps = [uint256(100), 300, 500, 1_000];
        for (uint256 i; i < lossBps.length; ++i) {
            _deploySystem();
            oracle.setEntropy(0.5e18);
            _seed();
            uint256 supply = token.totalSupply();
            uint256 reserve = stabilizer.reserveValue();
            uint256 lost = (_vaultPosition() * lossBps[i]) / 10_000;
            vault.simulateLoss(lost);
            uint256 after_ = stabilizer.reserveValue();
            uint256 idx = token.index();
            stabilizer.sync();
            uint256 cutPpm = ((idx - token.index()) * 1e6) / idx;
            uint256 expectedPpm = after_ >= supply ? 0 : ((supply - after_) * 1e6) / supply;
            console2.log("vault loss (bp) / reserve lost ($m):", lossBps[i], (reserve - after_) / 1e24);
            console2.log("   balances cut (ppm):              ", cutPpm);
            assertApproxEqAbs(cutPpm, expectedPpm, 1, "the cut is exactly what the cushion cannot cover");
            _assertSolvent();
            // and everyone can still leave at the new index
            uint256 out = _redeemFor(users, type(uint256).max);
            assertGt(out, 0);
            _assertSolvent();
        }
    }

    // ------------------------------------------------------------------------------ runs

    /// A run at $300m when the vault's market can pay only $50m today: exits are served in
    /// order until idle funds and the vault's liquidity are used up; the next one reverts with
    /// the exact amount available; nobody is paid less than par minus the fee; when liquidity
    /// returns everyone else exits in full.
    function test_runAt300mIsServedUpToLiquidityThenCompletes() public {
        address[30] memory holders;
        for (uint256 i; i < 30; ++i) {
            holders[i] = address(uint160(0xA000 + i));
            _mintFor(holders[i], 10_000_000e6);
        }
        stabilizer.rebalanceReserve();
        uint256 market = 50_000_000e6; // what the vault's market can pay out today
        vault.setLiquidityCap(market);

        uint256 served;
        uint256 refused;
        bool[30] memory out_;
        for (uint256 i; i < 30; ++i) {
            uint256 bal = token.balanceOf(holders[i]);
            (uint256 quote,) = lens.quoteRedeem(bal);
            uint256 vaultBefore = _vaultPosition();
            vm.prank(holders[i]);
            try stabilizer.redeem(type(uint256).max, holders[i], 0) returns (uint256 paid) {
                assertEq(paid, quote, "par minus the fee, no haircut");
                uint256 used = vaultBefore - _vaultPosition();
                market = market > used ? market - used : 0;
                vault.setLiquidityCap(market); // the market's free cash shrinks as we draw it
                out_[i] = true;
                ++served;
            } catch (bytes memory err) {
                assertEq(
                    err,
                    abi.encodeWithSelector(AutonomousTreasury.InsufficientLiquidity.selector, lens.liquidAssets()),
                    "reverts with exactly what is available"
                );
                ++refused;
            }
            _assertSolvent();
        }
        console2.log("exits served while the market pays $50m:", served);
        console2.log("exits refused until liquidity returns:   ", refused);
        assertEq(served, 8, "$30m idle + $50m from the vault pays eight $10m exits");

        // P5-02. The card program keeps settling during the crunch: a redemption sized to its
        // balance reverts, one sized with lens.maxRedeem pays out what is liquid.
        vm.prank(holders[29]);
        token.transfer(settlement, 1_000_000e18);
        uint256 owed = token.balanceOf(settlement);
        vm.prank(settlement);
        vm.expectPartialRevert(AutonomousTreasury.InsufficientLiquidity.selector);
        stabilizer.redeem(owed, settlement, 0);
        uint256 fits = lens.maxRedeem(settlement);
        console2.log("card settlement that fits now ($):       ", fits / 1e18);
        assertGt(fits, 0, "something is liquid");
        assertLt(fits, owed, "but not all of it");
        uint256 liquid = lens.liquidAssets();
        assertEq(_redeemFor(settlement, fits), liquid, "it takes what is liquid, to the unit");

        vault.setLiquidityCap(type(uint256).max); // utilisation falls, cash returns
        _redeemFor(settlement, type(uint256).max);
        for (uint256 i; i < 30; ++i) {
            if (out_[i]) continue;
            uint256 bal = token.balanceOf(holders[i]);
            (uint256 quote,) = lens.quoteRedeem(bal);
            assertEq(_redeemFor(holders[i], type(uint256).max), quote, "the rest exit at par minus the fee");
        }
        assertEq(token.totalSupply(), 0, "everyone is out");
        _assertSolvent();
    }

    // ------------------------------------------------------------------------------ migration

    function _proposeFallbackWhileIlliquid() internal returns (MockVault fallbackVault) {
        fallbackVault = new MockVault(usdc);
        allowedVaults.push(address(fallbackVault));
        _deploySystem();
        oracle.setEntropy(0.5e18);
        _seed();
        vault.setLiquidityCap(50_000_000e6); // the old vault's market can pay $50m today
        vm.prank(admin);
        stabilizer.proposeVault(IERC4626(address(fallbackVault)));
        vm.warp(vm.getBlockTimestamp() + 7 days);
    }

    /// P5-03. A migration executed while the old vault can pay out only part of the position
    /// quarantines the rest, and the index falls by that share at once: at $300m with $50m of
    /// vault liquidity, a cut of 73% for holders who could not exit first (review item 4 of
    /// audit/review.md; Phase 4 left it as an operational rule). The runbook's call now carries
    /// a rounding tolerance and is refused; the proposal waits until the vault is liquid.
    function test_P5_03_illiquidMigrationIsRefusedThenGoesThroughWhenLiquid() public {
        MockVault fallbackVault = _proposeFallbackWhileIlliquid();
        uint256 idx = token.index();

        vm.prank(admin);
        vm.expectPartialRevert(SpectralStabilizer.MigrationLossTooHigh.selector);
        stabilizer.executeVaultMigration(10);
        assertEq(token.index(), idx, "nothing moved, nothing cut");
        assertEq(address(stabilizer.pendingVault()), address(fallbackVault), "the proposal stays executable");

        vault.setLiquidityCap(type(uint256).max); // utilisation falls, cash returns
        vm.prank(admin);
        stabilizer.executeVaultMigration(10);
        assertEq(address(treasury.vault()), address(fallbackVault), "migrated");
        assertEq(address(treasury.legacyVault()), address(0), "nothing quarantined");
        assertEq(token.index(), idx, "and nobody's balance was cut");
        _assertSolvent();
    }

    /// The quarantine is still there for a vault that will not recover, as a deliberate bound.
    function test_P5_03_aDeliberateBoundStillAllowsTheQuarantine() public {
        _proposeFallbackWhileIlliquid();
        uint256 idx = token.index();
        uint256 reserve = treasury.reserveAssets();
        vm.prank(admin);
        stabilizer.executeVaultMigration(type(uint256).max);
        assertEq(address(treasury.legacyVault()), address(vault), "the stuck shares are quarantined");
        uint256 cutPpm = ((idx - token.index()) * 1e6) / idx;
        console2.log("index cut by an accepted quarantine (ppm):", cutPpm);
        console2.log("reserve moved to quarantine ($m):         ", (reserve - treasury.reserveAssets()) / 1e12);
        assertGt(cutPpm, 700_000, "about two thirds of the reserve was stuck");
        _assertSolvent();
    }

    // ------------------------------------------------------------------------------ the lens (P5-02)

    /// lens.maxRedeem is exactly the largest redemption that goes through: that amount pays,
    /// one wei more does not, whatever the liquidity, H and balance.
    function testFuzz_P5_02_maxRedeemIsTheLargestRedemptionThatFits(uint256 liquidity, uint256 h, uint256 assets)
        public
    {
        oracle.setEntropy(bound(h, 0, 1e18));
        _mintFor(bob, 5_000_000e6);
        _mintFor(alice, bound(assets, 1e6, 20_000_000e6));
        vault.setLiquidityCap(bound(liquidity, 0, 30_000_000e6));
        uint256 m = lens.maxRedeem(alice);
        uint256 bal = token.balanceOf(alice);
        assertLe(m, bal);
        uint256 snap = vm.snapshotState();
        if (m > 0) _redeemFor(alice, m); // must not revert
        vm.revertToState(snap);
        if (m < bal) {
            vm.prank(alice);
            vm.expectRevert();
            stabilizer.redeem(m + 1, alice, 0);
        }
    }

    /// After a loss that has not been absorbed yet, maxRedeem already counts the cut that
    /// `redeem` will apply first.
    function test_P5_02_maxRedeemCountsAPendingLoss() public {
        _mintFor(alice, 1_000_000e6);
        _mintFor(bob, 1_000_000e6);
        vault.simulateLoss(_vaultPosition() / 10); // more than the surplus: balances will be cut
        uint256 before = token.balanceOf(alice);
        uint256 m = lens.maxRedeem(alice);
        stabilizer.sync();
        assertLt(m, before, "below the pre-loss balance");
        assertEq(m, token.balanceOf(alice), "exactly the balance redeem will see");
        _redeemFor(alice, m);
        assertEq(token.balanceOf(alice), 0);
    }

    /// lens.maxMintAssets fits under the daily cap and is within 0.1% of the most that does.
    function testFuzz_P5_02_maxMintAssetsFits(uint256 h, uint256 first) public {
        bootstrapCap = CONFIG_BOOTSTRAP;
        _deploySystem();
        oracle.setEntropy(bound(h, 0, 1e18));
        _mintFor(alice, bound(first, 0, 9_000e6) + 1e6);
        uint256 m = lens.maxMintAssets();
        assertGt(m, 0);
        uint256 snap = vm.snapshotState();
        _mintFor(bob, m); // fits
        vm.revertToState(snap);
        usdc.mint(bob, m + m / 1_000 + 2);
        vm.startPrank(bob);
        usdc.approve(address(stabilizer), type(uint256).max);
        vm.expectPartialRevert(SpectralStabilizer.ExpansionCapExceeded.selector);
        stabilizer.mint(m + m / 1_000 + 2, bob, 0);
        vm.stopPrank();
        vm.prank(guardian);
        stabilizer.pause();
        assertEq(lens.maxMintAssets(), 0, "nothing while minting is paused");
    }

    /// When the room left is below the minimum mint, maxMintAssets says 0 rather than an
    /// amount that `mint` would refuse.
    function test_P5_02_maxMintAssetsIsZeroBelowTheMinimum() public {
        bootstrapCap = CONFIG_BOOTSTRAP;
        _deploySystem();
        oracle.setEntropy(0);
        uint256 room = lens.expansionRemaining(); // 10,000 sUSD on an empty system
        // Fill the day's room to within less than the 0.01 sUSD minimum (the fee is taken from
        // what is credited, so credit a little more than the sUSD wanted out).
        uint256 r = stabilizer.mintFeeRate(0);
        _mintFor(alice, Math.mulDiv(room - 0.005e18, WAD, WAD - r) / SCALE);
        assertLt(lens.expansionRemaining(), stabilizer.minAmount(), "less room than one minimum mint");
        assertEq(lens.maxMintAssets(), 0);
    }

    // ------------------------------------------------------------------------------ holders

    /// Ten thousand holders through yield, rebases and a loss: no account iterates anything,
    /// and the rounding gap between supply and the sum of balances stays below one wei per
    /// holder.
    function test_tenThousandHoldersStayExact() public {
        _seed();
        uint256 n = 10_000;
        uint256 seed = 11;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            vm.prank(users);
            token.transfer(address(uint160(0x100000 + i)), (1_000 + (seed % 9_000)) * 1e18 + (seed % 1e18));
        }
        for (uint256 k; k < 48; ++k) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.simulateYield((_vaultPosition() * HOURLY_YIELD_PPB) / 1e9);
            if (k == 24) vault.simulateLoss(_vaultPosition() / 20); // a 5% loss mid-way
            try stabilizer.rebase() {} catch {}
        }
        stabilizer.sync();
        uint256 sum = token.balanceOf(users) + token.balanceOf(settlement);
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(address(uint160(0x100000 + i)));
        }
        uint256 supply = token.totalSupply();
        console2.log("supply - sum of balances (wei):", supply - sum);
        assertLe(sum, supply, "balances never add up to more than supply");
        assertLe(supply - sum, n + 2, "the gap is at most one wei per holder");
        _assertSolvent();
    }

    // ------------------------------------------------------------------------------ bounds

    /// A trillion dollars in and out: no cast or product overflows (the state packs amounts in
    /// uint128; USDC's whole supply is under 2^93 sUSD wei).
    function test_trillionDollarAmountsDoNotOverflow() public {
        bootstrapCap = type(uint128).max;
        _deploySystem();
        uint256 assets = 1e18; // $1 trillion
        _mintFor(whale, assets);
        vault.simulateYield(assets / 20); // 5%: above the 2.75% buffer, so a rebase distributes
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        stabilizer.rebase();
        vault.simulateLoss(assets / 10);
        stabilizer.sync();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _mintFor(whale, assets / 10);
        _redeemFor(whale, token.balanceOf(whale) / 2);
        _assertSolvent();
        assertGt(token.balanceOf(whale), 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SpectralToken} from "../../src/SpectralToken.sol";
import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";
import {SpectrumLens} from "../../src/SpectrumLens.sol";
import {AutonomousTreasury} from "../../src/AutonomousTreasury.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Drives the monetary system through random but realistic sequences: mints,
///         redemptions, transfers, rebases, vault yield, vault losses (followed by a keeper
///         `sync`), donations, entropy changes, time jumps, liquidity-buffer changes,
///         rebalancing, emergency exits and timelocked vault migrations (sometimes with an
///         illiquid old vault, which quarantines shares), plus legacy recovery.
contract StabilizerHandler is Test {
    SpectralToken public immutable token;
    SpectralStabilizer public immutable stabilizer;
    SpectrumLens public immutable lens;
    AutonomousTreasury public immutable treasury;
    MockUSDC public immutable usdc;
    MockVault public immutable vaultA;
    MockVault public immutable vaultB;
    MockOracle public immutable oracle;
    address public immutable admin;

    address[] public actors;

    // ghost state
    uint256 public ghostMints;
    uint256 public ghostRedeems;
    uint256 public ghostRebases;
    uint256 public ghostDeferred;
    uint256 public ghostLosses;
    uint256 public ghostUnexpectedRedeemFailures;
    uint256 public ghostUnexpectedSyncFailures;
    uint256 public ghostChurnViolations; // accepted positive rebase with L > C_DIAM * D
    uint256 public ghostUsdcIn; // collateral deposited by actors
    uint256 public ghostUsdcOut; // collateral paid to actors
    uint256 public ghostMigrations;
    uint256 public ghostQuarantines;
    uint256 public ghostExits;
    uint256 public ghostUnexpectedGovernanceFailures;

    // ------------------------------------------------------------------ attacker (A10)
    //
    // One more holder, kept apart from `actors` so that nobody else ever gifts it sUSD. Each
    // `attack` call is one atomic strategy, as in a single transaction: flash-borrow USDC, then
    // up to six steps chosen from mint, redeem, transfer away, rebase, sync, rebalance, donate,
    // and moving H to an extreme for free (the worst case of steering the pool, A6), then
    // repay. Its value in sUSD wei is USDC x scale + sUSD at par (no exit fee, so an upper
    // bound). It may only ever gain its pro-rata share of distributed surplus.
    address public immutable attacker = makeAddr("attacker");
    uint256 public attackerStart; // value granted at the start, sUSD wei
    uint256 public attackerEntitlement; // pro-rata distributions it received, rounded up
    uint256 public attackerShortfall; // loans it could not repay, sUSD wei (only lowers its value)
    uint256 public ghostAttacks;
    uint256 public ghostFlatRoundTrips; // atomic calls that started and ended with no sUSD
    uint256 public ghostFlatRoundTripProfits; // ... and ended above their start

    constructor(
        SpectralToken token_,
        SpectralStabilizer stabilizer_,
        AutonomousTreasury treasury_,
        MockUSDC usdc_,
        MockVault vaultA_,
        MockVault vaultB_,
        MockOracle oracle_,
        address admin_
    ) {
        token = token_;
        stabilizer = stabilizer_;
        lens = new SpectrumLens(stabilizer_);
        treasury = treasury_;
        usdc = usdc_;
        vaultA = vaultA_;
        vaultB = vaultB_;
        oracle = oracle_;
        admin = admin_;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _vault() internal view returns (MockVault) {
        return MockVault(address(treasury.vault()));
    }

    // ------------------------------------------------------------------ user actions

    function mint(uint256 actorSeed, uint256 assets) external {
        address a = _actor(actorSeed);
        uint256 room = lens.expansionRemaining() / stabilizer.scale();
        if (room < 2e6) return;
        assets = bound(assets, 1e6, room > 5_000_000e6 ? 5_000_000e6 : room);
        usdc.mint(a, assets);
        vm.startPrank(a);
        usdc.approve(address(stabilizer), assets);
        try stabilizer.mint(assets, a, 0) {
            ghostMints++;
            ghostUsdcIn += assets;
        } catch {
            // Allowed: cap boundary, AmountTooSmall after vault rounding.
            usdc.burn(a, assets);
        }
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 fractionBps) external {
        address a = _actor(actorSeed);
        uint256 bal = token.balanceOf(a);
        fractionBps = bound(fractionBps, 1, 10_000);
        uint256 amount = fractionBps == 10_000 ? bal : (bal * fractionBps) / 10_000;
        if (amount < stabilizer.minAmount()) return;
        uint256 before = usdc.balanceOf(a);
        vm.prank(a);
        try stabilizer.redeem(amount, a, 0) {
            ghostRedeems++;
            ghostUsdcOut += usdc.balanceOf(a) - before;
        } catch {
            // The mock vault is fully liquid, so a redemption of an owned balance must
            // never fail. A pending loss can shrink the balance first, so re-check.
            if (token.balanceOf(a) >= amount) ghostUnexpectedRedeemFailures++;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        vm.prank(from);
        token.transfer(to, amount);
    }

    // ------------------------------------------------------------------ keepers / environment

    function rebase(uint256 waitSeconds) external {
        vm.warp(vm.getBlockTimestamp() + bound(waitSeconds, 1 hours, 2 days));
        _rebaseTracked();
    }

    /// @dev Every positive index move happens in `rebase`; credit the attacker's pro-rata part.
    function _rebaseTracked() internal {
        uint256 attackerShares = token.sharesOf(attacker);
        uint256 indexBefore = token.index();
        try stabilizer.rebase() returns (bool distributed) {
            if (distributed) {
                ghostRebases++;
                uint256 range = stabilizer.churnMax() - stabilizer.churnMin();
                if (stabilizer.churnLength() * 1e18 > stabilizer.C_DIAM_WAD() * range) ghostChurnViolations++;
            } else {
                ghostDeferred++;
            }
        } catch {}
        uint256 indexAfter = token.index();
        if (indexAfter > indexBefore) {
            attackerEntitlement += Math.mulDiv(attackerShares, indexAfter - indexBefore, 1e18, Math.Rounding.Ceil);
        }
    }

    // ------------------------------------------------------------------ attacker (A10)

    function fundAttacker(uint256 assets) external {
        usdc.mint(attacker, assets);
        attackerStart += assets * stabilizer.scale();
    }

    function attackerValue() public view returns (uint256) {
        return usdc.balanceOf(attacker) * stabilizer.scale() + token.balanceOf(attacker);
    }

    function attack(uint256 seed, uint256 loanRaw) external {
        ghostAttacks++;
        uint256 scale = stabilizer.scale();
        // Fees spent on earlier attempts are gone; an attacker that is nearly out of capital
        // brings more, which counts towards its start.
        if (attackerValue() < 10_000e18) {
            usdc.mint(attacker, 100_000e6);
            attackerStart += 100_000e18;
        }
        // A loan of up to 10x its own value: even six round trips at the highest fees (60 bp
        // each) can then be repaid, so no strategy is cut short by an unpayable loan.
        uint256 loan = bound(loanRaw, 0, Math.min(2_000_000e6, 10 * (attackerValue() / scale)));
        bool flatStart = token.balanceOf(attacker) == 0;
        uint256 valueBefore = attackerValue();
        uint256 entitlementBefore = attackerEntitlement;
        usdc.mint(attacker, loan); // flash-borrow

        for (uint256 k; k < 6; ++k) {
            uint256 step = (seed >> (k * 16)) & 0xffff;
            uint256 pick = step % 10;
            if (pick == 0) _attackerMint(step, false);
            else if (pick == 1) _attackerRedeem(step);
            else if (pick == 2) _attackerGift(step, loan);
            else if (pick == 3) _rebaseTracked(); // works only if an hour has passed
            else if (pick == 4) stabilizer.sync();
            else if (pick == 5) try stabilizer.rebalanceReserve() {} catch {}
            else if (pick == 6) _attackerDonate(step, loan);
            else if (pick == 7) oracle.setEntropy(step % 2 == 0 ? 0 : 1e18); // steer H for free
            else if (pick == 8) _attackerRedeem(10_000);
            else _attackerMint(step, true); // with the loan
        }

        // Repay the flash loan, redeeming sUSD if the USDC is short.
        uint256 cash = usdc.balanceOf(attacker);
        if (cash < loan) {
            _attackerRedeem(10_000);
            cash = usdc.balanceOf(attacker);
        }
        uint256 repaid = cash < loan ? cash : loan;
        usdc.burn(attacker, repaid);
        bool repaidInFull = repaid == loan;
        if (!repaidInFull) attackerShortfall += (loan - repaid) * scale;

        if (flatStart && token.balanceOf(attacker) == 0 && repaidInFull) {
            // Atomic, flat to flat: it held nothing before and nothing after, so even counting
            // the distributions it caught, it must not end above where it started.
            ghostFlatRoundTrips++;
            if (attackerValue() > valueBefore) ghostFlatRoundTripProfits++;
        }
        entitlementBefore; // the entitlement already includes what this call caught
    }

    function _attackerMint(uint256 step, bool all) internal {
        uint256 room = lens.expansionRemaining() / stabilizer.scale();
        uint256 cash = usdc.balanceOf(attacker);
        uint256 assets = all ? cash : (cash * (step % 10_000)) / 10_000;
        if (assets > room) assets = room;
        if (assets < 1e6) return;
        vm.startPrank(attacker);
        usdc.approve(address(stabilizer), assets);
        try stabilizer.mint(assets, attacker, 0) {} catch {}
        vm.stopPrank();
    }

    function _attackerRedeem(uint256 fractionBps) internal {
        uint256 bal = token.balanceOf(attacker);
        fractionBps = fractionBps % 10_001;
        uint256 amount = fractionBps >= 10_000 ? bal : (bal * fractionBps) / 10_000;
        if (amount == 0) return;
        if (amount < stabilizer.minAmount() && amount != bal) return;
        vm.prank(attacker);
        try stabilizer.redeem(amount, attacker, 0) {} catch {}
    }

    /// @dev Gives an actor up to 1% of its own value (never borrowed funds, so the loan can
    ///      always be repaid).
    function _attackerGift(uint256 step, uint256 loan) internal {
        uint256 bal = token.balanceOf(attacker);
        uint256 value = attackerValue();
        uint256 owed = loan * stabilizer.scale();
        if (bal == 0 || value <= owed) return;
        uint256 amount = ((value - owed) * (step % 100)) / 10_000;
        if (amount > bal) amount = bal;
        vm.prank(attacker);
        token.transfer(_actor(step), amount);
    }

    /// @dev Donates up to 0.1% of its own cash (never the loan): a donation is pure loss, and
    ///      a strategy that gives its capital away stops searching for anything else.
    function _attackerDonate(uint256 step, uint256 loan) internal {
        uint256 cash = usdc.balanceOf(attacker);
        uint256 own = cash > loan ? cash - loan : 0;
        uint256 assets = (own * (step % 10)) / 10_000;
        if (assets == 0) return;
        vm.prank(attacker);
        usdc.transfer(address(treasury), assets);
    }

    function accrueYield(uint256 bps) external {
        MockVault vault = _vault();
        uint256 assets = vault.totalAssets();
        if (assets == 0) return;
        bps = bound(bps, 1, 300); // up to 3% per call
        vault.simulateYield((assets * bps) / 10_000);
    }

    function realiseLoss(uint256 bps) external {
        MockVault vault = _vault();
        uint256 assets = vault.totalAssets();
        if (assets == 0) return;
        bps = bound(bps, 1, 100); // up to 1% per call
        vault.simulateLoss((assets * bps) / 10_000);
        ghostLosses++;
        // A keeper absorbs the loss right away; sync must never revert.
        try stabilizer.sync() {}
        catch {
            ghostUnexpectedSyncFailures++;
        }
    }

    function donate(uint256 assets) external {
        assets = bound(assets, 1, 10_000e6);
        usdc.mint(address(treasury), assets);
    }

    /// A6: entropy is attacker-controlled, so the handler includes the extremes and sudden
    /// switches between them, not just values in between.
    function setEntropy(uint256 h) external {
        uint256 pick = h % 4;
        if (pick == 0) oracle.setEntropy(0);
        else if (pick == 1) oracle.setEntropy(1e18);
        else if (pick == 2) oracle.setEntropy(oracle.h() == 0 ? 1e18 : 0); // flip
        else oracle.setEntropy(bound(h, 0, 1e18));
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 3 days));
    }

    // ------------------------------------------------------------------ treasury governance

    function setBuffer(uint256 bps) external {
        vm.prank(admin);
        stabilizer.setLiquidityBuffer(bound(bps, 0, 10_000));
    }

    function rebalance() external {
        try stabilizer.rebalanceReserve() {}
        catch {
            ghostUnexpectedGovernanceFailures++;
        }
    }

    function emergencyExit() external {
        vm.prank(admin); // the admin also holds GUARDIAN_ROLE
        try stabilizer.emergencyExitVault() {
            ghostExits++;
        } catch {
            ghostUnexpectedGovernanceFailures++;
        }
    }

    function recoverLegacy() external {
        try treasury.recoverLegacy() {}
        catch {
            ghostUnexpectedGovernanceFailures++;
        }
    }

    /// Propose, wait out the timelock, execute. One time in three the old vault can only pay
    /// out half of the position, so the rest is quarantined as legacy shares.
    function migrate(uint256 seed) external {
        MockVault cur = _vault();
        MockVault next = cur == vaultA ? vaultB : vaultA;
        if (address(next) == address(treasury.legacyVault())) {
            treasury.recoverLegacy();
            if (address(treasury.legacyVault()) != address(0)) return;
        }
        bool illiquid = seed % 3 == 0 && address(treasury.legacyVault()) == address(0);
        if (illiquid) cur.setLiquidityCap(cur.maxWithdraw(address(treasury)) / 2);

        vm.prank(admin);
        stabilizer.proposeVault(next);
        vm.warp(vm.getBlockTimestamp() + stabilizer.VAULT_TIMELOCK());
        vm.prank(admin);
        try stabilizer.executeVaultMigration() {
            ghostMigrations++;
            if (address(treasury.legacyVault()) != address(0)) ghostQuarantines++;
        } catch {
            ghostUnexpectedGovernanceFailures++;
        }
        if (illiquid) cur.setLiquidityCap(type(uint256).max); // liquidity returns later
        // The buffer may have been set to 100% by an exit; keep some deposits flowing.
        if (seed % 2 == 0) {
            vm.prank(admin);
            stabilizer.setLiquidityBuffer(1_500);
        }
    }
}

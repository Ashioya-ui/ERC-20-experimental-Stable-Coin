// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Symbolic properties for Halmos (Phase 4, A11).
//
//      halmos --match-contract Halmos --function check_      (see audit/formal.md)
//
//  Every check runs on production code: the token itself, SpectralPolicy (the library the
//  stabilizer's policy curves and churn step are compiled from) and SpectralMath.fwht8.
//  Halmos reports a counterexample only for a failed `assert`; other reverts end a path
//  silently. So "cannot revert" properties call through an external harness and assert in
//  the catch branch.
//
//  Inputs are typed as narrowly as the claim allows (uint64 for an entropy or an index,
//  uint128 for amounts), which keeps each solver query small without losing coverage.
//
//  lnWad and the entropy are nonlinear (a Taylor series and a logarithm): no claim about them
//  is made here. They stay fuzzed and checked against 80-digit reference values.
// =====================================================================================

import {Test} from "forge-std/Test.sol";
import {SpectralToken} from "../../src/SpectralToken.sol";
import {SpectralPolicy} from "../../src/libraries/SpectralPolicy.sol";
import {MathHarness} from "../mocks/Harnesses.sol";

/// @notice The token's share arithmetic. This contract is the token's stabilizer.
contract HalmosToken is Test {
    uint256 internal constant WAD = 1e18;

    SpectralToken internal token;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new SpectralToken(address(this));
    }

    /// @dev Index from 0.5 to 5 (a halving loss to a fivefold gain) and amounts up to 1e30
    ///      (a trillion sUSD): far beyond anything reachable, small enough for the solver.
    function _setUpBalances(uint64 idx, uint128 mintA, uint128 mintB) internal {
        vm.assume(idx >= 0.5e18 && idx <= 5e18);
        vm.assume(mintA >= idx && mintA <= 1e30);
        vm.assume(mintB <= 1e30);
        token.setIndex(idx);
        token.mint(alice, mintA);
        if (mintB >= idx) token.mint(bob, mintB);
    }

    /// The recipient's balance rises by at least `amount`, and the sender's falls by at least
    /// `amount`: rounding never favours the person moving funds.
    function check_transferNeverShortchangesRecipient(uint64 idx, uint128 mintA, uint128 mintB, uint128 amount)
        public
    {
        _setUpBalances(idx, mintA, mintB);
        uint256 balA = token.balanceOf(alice);
        uint256 balB = token.balanceOf(bob);
        vm.assume(amount <= balA);
        vm.prank(alice);
        token.transfer(bob, amount);
        assert(token.balanceOf(bob) - balB >= amount);
        assert(balA - token.balanceOf(alice) >= amount);
    }

    /// Transfers conserve total shares, and two balances never sum to more than the supply.
    function check_transferConservesSharesAndSupply(uint64 idx, uint128 mintA, uint128 mintB, uint128 amount)
        public
    {
        _setUpBalances(idx, mintA, mintB);
        uint256 shares = token.totalShares();
        uint256 supply = token.totalSupply();
        vm.assume(amount <= token.balanceOf(alice));
        vm.prank(alice);
        token.transfer(bob, amount);
        assert(token.totalShares() == shares);
        assert(token.totalSupply() == supply);
        assert(token.balanceOf(alice) + token.balanceOf(bob) <= token.totalSupply());
    }

    /// Minting `amount` raises the supply by at most `amount` (shares rounded down).
    function check_mintRoundsDown(uint64 idx, uint128 mintA, uint128 mintB, uint128 amount) public {
        _setUpBalances(idx, mintA, mintB);
        vm.assume(amount >= idx && amount <= 1e30);
        uint256 supply = token.totalSupply();
        uint256 balB = token.balanceOf(bob);
        token.mint(bob, amount);
        assert(token.totalSupply() - supply <= amount);
        assert(token.balanceOf(bob) - balB <= amount);
    }

    /// Burning `amount` lowers the supply by at least `amount` (shares rounded up).
    function check_burnRoundsUp(uint64 idx, uint128 mintA, uint128 mintB, uint128 amount) public {
        _setUpBalances(idx, mintA, mintB);
        vm.assume(amount > 0 && amount <= token.balanceOf(alice));
        uint256 supply = token.totalSupply();
        uint256 balA = token.balanceOf(alice);
        token.burn(alice, amount);
        assert(supply - token.totalSupply() >= amount);
        assert(balA - token.balanceOf(alice) >= amount);
    }
}

/// @notice External entry to the churn step, so that a revert can be caught and asserted on.
contract ChurnHarness {
    function churnStep(uint128 len, uint128 mx, uint128 mn, uint128 oldIndex, uint128 newIndex)
        external
        pure
        returns (uint256, uint256, uint256, uint256, bool)
    {
        return SpectralPolicy.churnStep(len, mx, mn, oldIndex, newIndex);
    }
}

/// @notice The stabilizer's policy curves and churn step (SpectralPolicy), for every input.
/// @dev    Each property is split so that every query has one symbolic input:
///         - monotonicity is checked locally, f(h) against f(h + 1) for every h < 1e18, which
///           on the integers is equivalent to f(h1) <= f(h2) for all h1 <= h2 <= 1e18;
///         - bounds are checked for every h <= 1e18;
///         - `check_curvesClampAboveOne` shows every h > 1e18 gives the value at 1e18.
///         Together they cover every uint256 input. (A two-input monotonicity query timed out
///         at 10 minutes; see audit/formal.md.)
contract HalmosPolicy is Test {
    uint256 internal constant WAD = 1e18;
    ChurnHarness internal harness;

    function setUp() public {
        harness = new ChurnHarness();
    }

    function check_curvesClampAboveOne(uint256 h) public pure {
        vm.assume(h > WAD);
        assert(SpectralPolicy.mintFeeRate(h) == SpectralPolicy.mintFeeRate(WAD));
        assert(SpectralPolicy.redeemFeeRate(h) == SpectralPolicy.redeemFeeRate(WAD));
        assert(SpectralPolicy.expansionCapRate(h) == SpectralPolicy.expansionCapRate(WAD));
        assert(SpectralPolicy.bufferRate(h) == SpectralPolicy.bufferRate(WAD));
        assert(SpectralPolicy.rebaseStepRate(h) == SpectralPolicy.rebaseStepRate(WAD));
    }

    function check_mintFeeLocallyMonotone(uint64 h) public pure {
        vm.assume(h < WAD);
        assert(SpectralPolicy.mintFeeRate(h) <= SpectralPolicy.mintFeeRate(uint256(h) + 1));
    }

    function check_mintFeeBounded(uint64 h) public pure {
        vm.assume(h <= WAD);
        uint256 f = SpectralPolicy.mintFeeRate(h);
        assert(f >= SpectralPolicy.MINT_FEE_MIN && f <= SpectralPolicy.MINT_FEE_MAX);
    }

    function check_redeemFeeLocallyMonotone(uint64 h) public pure {
        vm.assume(h < WAD);
        assert(SpectralPolicy.redeemFeeRate(h) <= SpectralPolicy.redeemFeeRate(uint256(h) + 1));
    }

    function check_redeemFeeBounded(uint64 h) public pure {
        vm.assume(h <= WAD);
        uint256 f = SpectralPolicy.redeemFeeRate(h);
        assert(f >= SpectralPolicy.REDEEM_FEE_MIN && f <= SpectralPolicy.REDEEM_FEE_MAX);
    }

    function check_expansionCapLocallyMonotone(uint64 h) public pure {
        vm.assume(h < WAD);
        assert(SpectralPolicy.expansionCapRate(h) >= SpectralPolicy.expansionCapRate(uint256(h) + 1));
    }

    function check_expansionCapBounded(uint64 h) public pure {
        vm.assume(h <= WAD);
        uint256 f = SpectralPolicy.expansionCapRate(h);
        assert(f <= SpectralPolicy.EXPANSION_CAP_LOW_H && f >= SpectralPolicy.EXPANSION_CAP_HIGH_H);
    }

    function check_bufferLocallyMonotone(uint64 h) public pure {
        vm.assume(h < WAD);
        assert(SpectralPolicy.bufferRate(h) <= SpectralPolicy.bufferRate(uint256(h) + 1));
    }

    /// Bounded, and D4: the buffer never falls below its neutral value, whatever H.
    function check_bufferBoundedAndFloored(uint256 h) public pure {
        uint256 f = SpectralPolicy.bufferRate(h);
        assert(f >= SpectralPolicy.bufferRate(0.5e18));
        assert(f >= SpectralPolicy.BUFFER_LOW_H && f <= SpectralPolicy.BUFFER_HIGH_H);
    }

    function check_rebaseStepLocallyMonotone(uint64 h) public pure {
        vm.assume(h < WAD);
        assert(SpectralPolicy.rebaseStepRate(h) >= SpectralPolicy.rebaseStepRate(uint256(h) + 1));
    }

    function check_rebaseStepBounded(uint64 h) public pure {
        vm.assume(h <= WAD);
        uint256 f = SpectralPolicy.rebaseStepRate(h);
        assert(f <= SpectralPolicy.REBASE_STEP_MAX && f >= SpectralPolicy.REBASE_STEP_MAX / 2);
    }

    /// Anti-sandwich: at every H, one rebase step is worth less than a mint-and-redeem round
    /// trip's fees, and so is the largest step against the smallest fees.
    function check_rebaseStepBelowRoundTripFees(uint256 h) public pure {
        assert(SpectralPolicy.REBASE_STEP_MAX < SpectralPolicy.MINT_FEE_MIN + SpectralPolicy.REDEEM_FEE_MIN);
        assert(SpectralPolicy.rebaseStepRate(h) < SpectralPolicy.mintFeeRate(h) + SpectralPolicy.redeemFeeRate(h));
    }

    /// For every input (uint128, as the stabilizer passes them) with the old index inside the
    /// window's range, the churn step never reverts, and its results are exact: the length
    /// grows by |newIndex - oldIndex|, the maximum and minimum take in the new index, the range
    /// is their difference, and `ok` is L * 1e18 <= CHURN_BUDGET_WAD * D over the integers
    /// (both sides are below 2^191, so the 256-bit comparison is the integer one).
    function check_churnStepNeverRevertsAndIsExact(
        uint128 len,
        uint128 mx,
        uint128 mn,
        uint128 oldIndex,
        uint128 newIndex
    ) public view {
        vm.assume(mn <= oldIndex && oldIndex <= mx); // the current index lies in the window's range
        try harness.churnStep(len, mx, mn, oldIndex, newIndex) returns (
            uint256 len2, uint256 mx2, uint256 mn2, uint256 range, bool ok
        ) {
            uint256 step = newIndex > oldIndex ? uint256(newIndex) - oldIndex : uint256(oldIndex) - newIndex;
            assert(len2 == uint256(len) + step && len2 < uint256(1) << 129);
            assert(mx2 == (newIndex > mx ? newIndex : mx) && mn2 == (newIndex < mn ? newIndex : mn));
            assert(mn2 <= mx2 && range == mx2 - mn2 && range < uint256(1) << 128);
            unchecked {
                // No wrap: len2 * 1e18 < 2^189 and CHURN_BUDGET_WAD * range < 2^190.
                assert(ok == (len2 * WAD <= SpectralPolicy.CHURN_BUDGET_WAD * range));
            }
        } catch {
            assert(false);
        }
    }

    /// A monotone path (pure yield distribution: L = D so far, moving up from the maximum) is
    /// never deferred by the churn budget.
    function check_monotonePathNeverDeferred(uint128 mn, uint128 mx, uint128 newIndex) public pure {
        vm.assume(mn <= mx && mx <= newIndex);
        (uint256 len2,,, uint256 range, bool ok) = SpectralPolicy.churnStep(mx - mn, mx, mn, mx, newIndex);
        assert(len2 == range);
        assert(ok);
    }
}

/// @notice The FWHT butterflies (SpectralMath.fwht8, inline assembly).
contract HalmosFwht is Test {
    MathHarness internal math;

    function setUp() public {
        math = new MathHarness();
    }

    function _bounded(int256[8] memory x) internal pure {
        int256 lim = int256(1) << 100;
        for (uint256 i; i < 8; ++i) {
            vm.assume(x[i] > -lim && x[i] < lim);
        }
    }

    /// Applying the transform twice gives 8x: H8 * H8 = 8 I (Sylvester), for |x_i| < 2^100.
    function check_fwhtIsAnInvolutionUpTo8(int256[8] memory x) public view {
        _bounded(x);
        int256[8] memory y = math.fwht8(math.fwht8(x));
        for (uint256 i; i < 8; ++i) {
            assert(y[i] == 8 * x[i]);
        }
    }

    /// The transform is linear: H(x + y) = H(x) + H(y), for |x_i|, |y_i| < 2^100.
    function check_fwhtIsLinear(int256[8] memory x, int256[8] memory y) public view {
        _bounded(x);
        _bounded(y);
        int256[8] memory s;
        for (uint256 i; i < 8; ++i) {
            s[i] = x[i] + y[i];
        }
        int256[8] memory hx = math.fwht8(x);
        int256[8] memory hy = math.fwht8(y);
        int256[8] memory hs = math.fwht8(s);
        for (uint256 k; k < 8; ++k) {
            assert(hs[k] == hx[k] + hy[k]);
        }
    }
}

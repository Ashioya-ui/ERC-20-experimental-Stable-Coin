// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SelfApproaching} from "./SelfApproaching.sol";

/// @title  SpectralPolicy
/// @notice The stabilizer's policy curves and churn-budget step, as pure functions.
/// @dev    Kept in one library so that the formal checks in test/halmos run on exactly the code
///         the stabilizer executes (internal functions are inlined), not on a copy (Phase 4,
///         A11). Every curve clamps h to [0, 1e18] first, so it is defined for any input.
///
///         Plain checked arithmetic, not `mulDiv`: after the clamp every product is far below
///         2^256 (the largest, (MINT_FEE_MAX - MINT_FEE_MIN) * h * h, is under 2.4e51), so
///         `(a * b) / c` is exactly the floor `mulDiv` would return, costs less gas, and keeps
///         the formulas simple enough for an SMT solver to prove things about.
library SpectralPolicy {
    uint256 internal constant WAD = 1e18;

    /// @dev Minting fee: 1 bp at h = 0 to 25 bp at h = 1, quadratic in h. The ceiling was 50 bp
    ///      until Phase 4 (D4): H is attacker-steerable, so the range it controls is kept to
    ///      what is worth defending (audit/parameters.md).
    uint256 internal constant MINT_FEE_MIN = 0.0001e18;
    uint256 internal constant MINT_FEE_MAX = 0.0025e18;
    /// @dev Redemption fee: 1 bp to 10 bp, quadratic in h.
    uint256 internal constant REDEEM_FEE_MIN = 0.0001e18;
    uint256 internal constant REDEEM_FEE_MAX = 0.0010e18;
    /// @dev Net minting per epoch as a fraction of epoch-start supply: 20% down to 2%.
    uint256 internal constant EXPANSION_CAP_LOW_H = 0.20e18;
    uint256 internal constant EXPANSION_CAP_HIGH_H = 0.02e18;
    /// @dev Largest rebase step, 1 bp of supply at h = 0, halving to 0.5 bp at h = 1.
    uint256 internal constant REBASE_STEP_MAX = 0.0001e18;
    /// @dev Surplus kept before distributing: 2.75% up to h = 0.5, rising to 5% at h = 1.
    uint256 internal constant BUFFER_LOW_H = 0.0275e18;
    uint256 internal constant BUFFER_HIGH_H = 0.05e18;
    /// @dev The churn budget's ratio: 5*pi/6 + 2 sin(pi/12) = 3.1356..., in WAD, rounded up.
    ///      Theorem 4.3 of the paper (proven). See SpectralStabilizer.CHURN_BUDGET_WAD.
    uint256 internal constant CHURN_BUDGET_WAD = SelfApproaching.C_SA_UPPER_WAD;

    function clamp(uint256 h) internal pure returns (uint256) {
        return h > WAD ? WAD : h;
    }

    /// @dev MIN + (MAX - MIN) h^2.
    function mintFeeRate(uint256 h) internal pure returns (uint256) {
        h = clamp(h);
        return MINT_FEE_MIN + ((MINT_FEE_MAX - MINT_FEE_MIN) * (h * h)) / (WAD * WAD);
    }

    /// @dev MIN + (MAX - MIN) h^2.
    function redeemFeeRate(uint256 h) internal pure returns (uint256) {
        h = clamp(h);
        return REDEEM_FEE_MIN + ((REDEEM_FEE_MAX - REDEEM_FEE_MIN) * (h * h)) / (WAD * WAD);
    }

    /// @dev LOW - (LOW - HIGH) h.
    function expansionCapRate(uint256 h) internal pure returns (uint256) {
        h = clamp(h);
        return EXPANSION_CAP_LOW_H - ((EXPANSION_CAP_LOW_H - EXPANSION_CAP_HIGH_H) * h) / WAD;
    }

    /// @dev Flat at the neutral floor up to h = 0.5, then linear up to HIGH (Phase 4, D4).
    function bufferRate(uint256 h) internal pure returns (uint256) {
        h = clamp(h);
        if (h <= 0.5e18) return BUFFER_LOW_H;
        return BUFFER_LOW_H + ((BUFFER_HIGH_H - BUFFER_LOW_H) * (2 * (h - 0.5e18))) / WAD;
    }

    /// @dev MAX - MAX h / 2.
    function rebaseStepRate(uint256 h) internal pure returns (uint256) {
        h = clamp(h);
        return REBASE_STEP_MAX - (REBASE_STEP_MAX * h) / (2 * WAD);
    }

    /// @notice One step of the churn budget: the window's total variation `len`, maximum `mx`
    ///         and minimum `mn` after the index moves from `oldIndex` to `newIndex`, its range,
    ///         and whether `len <= CHURN_BUDGET * range` afterwards.
    /// @dev    All arithmetic is in uint256. With every input below 2^128, `len` stays below
    ///         2^129 and both products below 2^191, so nothing can overflow (checked by Halmos).
    function churnStep(uint256 len, uint256 mx, uint256 mn, uint256 oldIndex, uint256 newIndex)
        internal
        pure
        returns (uint256 len2, uint256 mx2, uint256 mn2, uint256 range, bool ok)
    {
        len2 = len + (newIndex > oldIndex ? newIndex - oldIndex : oldIndex - newIndex);
        mx2 = newIndex > mx ? newIndex : mx;
        mn2 = newIndex < mn ? newIndex : mn;
        range = mx2 - mn2;
        ok = len2 * WAD <= CHURN_BUDGET_WAD * range;
    }
}

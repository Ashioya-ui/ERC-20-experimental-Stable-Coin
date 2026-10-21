// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  SelfApproaching
/// @notice Exact integer tests for self-approaching polygons, from E. Langetepe and
///         W. A. Ashioya, "The length-over-diameter ratio of self-approaching curves", revised
///         version 21 (October 2026). Theorem numbers below refer to that version.
///
/// @dev    A polygon is the vertex list (xs[i], ys[i]), i = 0..N, joined by segments. It is
///         self-approaching (eq. 1.1) if no point ever moves away from any later point.
///         - Lemma 7.1 reduces that condition on a continuum of triples to finitely many
///           inequalities, (v_j - v_i)·(v_i - v_{i-1}) >= 0 for all 1 <= i < j <= N. With
///           integer coordinates they are exact and need no tolerance. (Section 7.2 shows why
///           absolute tolerances are dangerous: microscopic zig-zags slip through them.)
///         - Lemma 2.1: the diameter is the largest distance from the first vertex.
///         - Theorem 4.3: the length is at most (5π/6 + 2 sin(π/12)) times the diameter.
///
///         Checking only sampled points is not enough (Section 7.5): a sequence can satisfy
///         the triple condition at its own points while its polygon is far longer than any
///         self-approaching curve in its region. Always test the polygon, as below.
///
///         Range. Coordinates must satisfy |x|, |y| <= 2^125. Then every difference is below
///         2^126, every product below 2^252 and every dot product below 2^253, so nothing
///         overflows int256.
///
///         Nothing in the deployed protocol calls this library yet: the monetary state is
///         one-dimensional, where a self-approaching path is just monotone. It is meant for the
///         first two-dimensional state (a reserve split across vaults); see
///         docs/design/reserve-allocation.md.
library SelfApproaching {
    /// @notice 5π/6 + 2 sin(π/12) = 3.13563196819653589008... in WAD, rounded up so that a check
    ///         `length * 1e18 <= C_SA_UPPER_WAD * diameter` never rejects a polygon the theorem
    ///         allows (Theorem 4.3, proven).
    uint256 internal constant C_SA_UPPER_WAD = 3_135_631_968_196_535_891;
    /// @notice 2 + π/3 = 3.04719755119659774615... in WAD, rounded down. Ratios this close are
    ///         attained (Theorem 5.4, proven); that none is larger is Conjecture 1.2 (open).
    uint256 internal constant C_SA_LOWER_WAD = 3_047_197_551_196_597_746;
    /// @notice Largest allowed absolute coordinate.
    int256 internal constant MAX_COORD = int256(1) << 125;

    error LengthMismatch();
    error CoordinateOutOfRange();

    /// @notice Lemma 7.1: true iff the polygon is self-approaching. O(N^2) dot products.
    function isSelfApproaching(int256[] memory xs, int256[] memory ys) internal pure returns (bool) {
        uint256 n = _validate(xs, ys);
        for (uint256 i = 1; i < n; ++i) {
            int256 dx = xs[i] - xs[i - 1];
            int256 dy = ys[i] - ys[i - 1];
            for (uint256 j = i + 1; j < n; ++j) {
                if ((xs[j] - xs[i]) * dx + (ys[j] - ys[i]) * dy < 0) return false;
            }
        }
        return true;
    }

    /// @notice True iff appending (x, y) to a self-approaching polygon keeps it
    ///         self-approaching: only the N new inequalities of Lemma 7.1 (the new vertex as
    ///         v_j against every earlier segment). O(N).
    /// @dev    Assumes the existing polygon is self-approaching, for example because it was
    ///         built by repeated `canAppend` calls.
    function canAppend(int256[] memory xs, int256[] memory ys, int256 x, int256 y) internal pure returns (bool) {
        uint256 n = _validate(xs, ys);
        _validateCoord(x);
        _validateCoord(y);
        for (uint256 i = 1; i < n; ++i) {
            if ((x - xs[i]) * (xs[i] - xs[i - 1]) + (y - ys[i]) * (ys[i] - ys[i - 1]) < 0) return false;
        }
        return true;
    }

    /// @notice Lemma 2.1: squared diameter of a self-approaching polygon, as the largest squared
    ///         distance from the first vertex. O(N). For other polygons it is only a lower bound.
    function diameterSqFromStart(int256[] memory xs, int256[] memory ys) internal pure returns (uint256 d2) {
        uint256 n = _validate(xs, ys);
        for (uint256 i = 1; i < n; ++i) {
            uint256 q = _dist2(xs[i] - xs[0], ys[i] - ys[0]);
            if (q > d2) d2 = q;
        }
    }

    /// @notice Theorem 4.3 as a check. Segment lengths are rounded up and the diameter down, so
    ///         `ok` implies length <= C_SA_UPPER * diameter exactly. A self-approaching polygon
    ///         with `ok == false` would contradict the theorem (up to one unit of rounding per
    ///         segment, negligible at the coordinate scales used in practice).
    function lengthBound(int256[] memory xs, int256[] memory ys)
        internal
        pure
        returns (uint256 lengthUp, uint256 diameterDown, bool ok)
    {
        uint256 n = _validate(xs, ys);
        for (uint256 i = 1; i < n; ++i) {
            lengthUp += Math.sqrt(_dist2(xs[i] - xs[i - 1], ys[i] - ys[i - 1]), Math.Rounding.Ceil);
        }
        diameterDown = Math.sqrt(diameterSqFromStart(xs, ys));
        ok = lengthUp * 1e18 <= C_SA_UPPER_WAD * diameterDown;
    }

    // ------------------------------------------------------------------------- internals

    function _validate(int256[] memory xs, int256[] memory ys) private pure returns (uint256 n) {
        n = xs.length;
        if (ys.length != n) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            _validateCoord(xs[i]);
            _validateCoord(ys[i]);
        }
    }

    function _validateCoord(int256 v) private pure {
        if (v > MAX_COORD || v < -MAX_COORD) revert CoordinateOutOfRange();
    }

    /// @dev |(dx, dy)|^2 for |dx|, |dy| < 2^126: below 2^253, so the cast is lossless.
    function _dist2(int256 dx, int256 dy) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(dx * dx + dy * dy);
    }
}

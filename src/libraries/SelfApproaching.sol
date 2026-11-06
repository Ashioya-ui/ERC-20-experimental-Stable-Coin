// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  SelfApproaching
/// @notice Exact integer tests for self-approaching polygons, from E. Langetepe and
///         W. A. Ashioya, "The length-over-diameter ratio of self-approaching curves" (November
///         2026). Theorem numbers below refer to that version.
///
/// @dev    A polygon is the vertex list (xs[i], ys[i]), i = 0..N, joined by segments. It is
///         self-approaching (eq. 1.1) if no point ever moves away from any later point.
///         - Lemma 8.1 reduces that condition on a continuum of triples to finitely many
///           inequalities, (v_j - v_i)·(v_i - v_{i-1}) >= 0 for all 1 <= i < j <= N. With
///           integer coordinates they are exact and need no tolerance. (Section 8.3 shows why
///           absolute tolerances are dangerous: microscopic zig-zags slip through them.)
///         - Lemma 2.1: the diameter is the largest distance from the first vertex.
///         - Theorem 4.2: the length is at most (2π/3 + 4 sin(π/12)) times the diameter.
///
///         Checking only sampled points is not enough (Section 8.4): a sequence can satisfy
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
    /// @notice 2π/3 + 4 sin(π/12) = 2π/3 + √6 − √2 = 3.12967128280327854170... in WAD, rounded up so
    ///         that a check `length * 1e18 <= C_SA_UPPER_WAD * diameter` never rejects a polygon the
    ///         theorem allows (Theorem 4.2, proven; Theorem 4.1's trimmed Reuleaux triangle attains
    ///         the hull bound, so no hull-only argument goes lower).
    uint256 internal constant C_SA_UPPER_WAD = 3_129_671_282_803_278_542;
    /// @notice 1 + 2π/3 = 3.09439510239319549230... in WAD, rounded down. Ratios this close are
    ///         attained (Theorem 1.1, Corollary 7.12, proven); whether none is larger is open
    ///         (Section 9, problem 1).
    uint256 internal constant C_SA_LOWER_WAD = 3_094_395_102_393_195_492;
    /// @notice 2 + π/3 = 3.04719755119659774615... in WAD, rounded up. A polygon that winds
    ///         monotonically about its end through at most π, then steps straight into it, has
    ///         length before that step plus twice that step at most this many times its diameter
    ///         (Proposition 7.14, proven). See `windingBound`.
    uint256 internal constant C_SA_WINDING_WAD = 3_047_197_551_196_597_747;
    /// @notice Largest allowed absolute coordinate.
    int256 internal constant MAX_COORD = int256(1) << 125;
    /// @notice Largest allowed absolute coordinate for `canAppendWithMargin`.
    int256 internal constant MAX_MARGIN_COORD = int256(1) << 62;

    error LengthMismatch();
    error CoordinateOutOfRange();
    error BadMargin();

    /// @notice Lemma 8.1: true iff the polygon is self-approaching. O(N^2) dot products.
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
    ///         self-approaching: only the N new inequalities of Lemma 8.1 (the new vertex as
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

    /// @notice Appending (x, y) with margin eta = etaNum/etaDen: every new inequality of Lemma 8.1
    ///         holds as (v - v_i)·(v_i - v_{i-1}) >= eta |v - v_i| |v_i - v_{i-1}|, condition (5.2).
    ///         A polygon built this way stays self-approaching when each vertex moves by at most
    ///         eta * m / 8, m its shortest distance between a vertex and a later one
    ///         (docs/design/admissible-paths.md): rounding and slippage below that cannot break it.
    ///         O(N). Exact: compares dot^2 den^2 >= num^2 |a|^2 |b|^2 through a 512-bit product.
    function canAppendWithMargin(
        int256[] memory xs,
        int256[] memory ys,
        int256 x,
        int256 y,
        uint256 etaNum,
        uint256 etaDen
    ) internal pure returns (bool) {
        if (etaDen == 0 || etaDen > type(uint32).max || etaNum > etaDen) revert BadMargin();
        uint256 n = _validate(xs, ys);
        for (uint256 i; i < n; ++i) {
            _validateMarginCoord(xs[i]);
            _validateMarginCoord(ys[i]);
        }
        _validateMarginCoord(x);
        _validateMarginCoord(y);
        for (uint256 i = 1; i < n; ++i) {
            int256 bx = xs[i] - xs[i - 1];
            int256 by = ys[i] - ys[i - 1];
            int256 ax = x - xs[i];
            int256 ay = y - ys[i];
            int256 dot = ax * bx + ay * by;
            if (dot < 0) return false;
            uint256 a2 = _dist2(ax, ay);
            if (a2 == 0) continue;
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 d = uint256(dot);
            if (Math.mulDiv(d * d, etaDen * etaDen, a2) < etaNum * etaNum * _dist2(bx, by)) return false;
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

    /// @notice Theorem 4.2 as a check. Segment lengths are rounded up and the diameter down, so
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

    /// @notice Proposition 7.14 as a check, for a polygon that is to end at f. `inSector` is true
    ///         iff no vertex is f and the argument about f is monotone (counter-clockwise if `ccw`)
    ///         and turns by at most π. For such a polygon that `canAppend` f, length plus twice
    ///         the last step into f is at most C_SA_WINDING times the diameter with f; `ok` reports
    ///         that with the length rounded up and the diameter down. O(N).
    function windingBound(int256[] memory xs, int256[] memory ys, int256 fx, int256 fy, bool ccw)
        internal
        pure
        returns (bool inSector, uint256 lengthUp, uint256 diameterDown, bool ok)
    {
        uint256 n = _validate(xs, ys);
        _validateCoord(fx);
        _validateCoord(fy);
        if (n == 0) return (false, 0, 0, false);
        int256 s = ccw ? int256(1) : int256(-1);
        int256 r0x = xs[0] - fx;
        int256 r0y = ys[0] - fy;
        inSector = r0x != 0 || r0y != 0;
        for (uint256 i = 1; i < n; ++i) {
            lengthUp += Math.sqrt(_dist2(xs[i] - xs[i - 1], ys[i] - ys[i - 1]), Math.Rounding.Ceil);
            if (!inSector) continue;
            int256 px = xs[i - 1] - fx;
            int256 py = ys[i - 1] - fy;
            int256 rx = xs[i] - fx;
            int256 ry = ys[i] - fy;
            int256 turn = s * (px * ry - py * rx);
            if ((rx == 0 && ry == 0) || turn < 0 || (turn == 0 && px * rx + py * ry < 0)) inSector = false;
            else if (s * (r0x * ry - r0y * rx) < 0) inSector = false;
        }
        lengthUp += 2 * Math.sqrt(_dist2(fx - xs[n - 1], fy - ys[n - 1]), Math.Rounding.Ceil);
        uint256 d2 = diameterSqFromStart(xs, ys);
        uint256 f2 = _dist2(fx - xs[0], fy - ys[0]);
        diameterDown = Math.sqrt(f2 > d2 ? f2 : d2);
        ok = inSector && lengthUp * 1e18 <= C_SA_WINDING_WAD * diameterDown;
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

    function _validateMarginCoord(int256 v) private pure {
        if (v > MAX_MARGIN_COORD || v < -MAX_MARGIN_COORD) revert CoordinateOutOfRange();
    }

    /// @dev |(dx, dy)|^2 for |dx|, |dy| < 2^126: below 2^253, so the cast is lossless.
    function _dist2(int256 dx, int256 dy) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(dx * dx + dy * dy);
    }
}

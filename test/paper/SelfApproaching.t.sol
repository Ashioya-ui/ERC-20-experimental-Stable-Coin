// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  The paper's proven results as test oracles (Phase 4, Track C).
//
//  Source: E. Langetepe and W. A. Ashioya, "The length-over-diameter ratio of
//  self-approaching curves", revised version 21 (October 2026).
//
//  Generators build polygons of several shapes. For every polygon the library accepts, the
//  theorems must hold; for every polygon it rejects, there must be a witness triple that
//  violates eq. (1.1). The Section 7.5 fixture (SampledConditions.t.sol) pins the one thing a
//  check made only at sampled points gets wrong.
// =====================================================================================

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SelfApproaching} from "../../src/libraries/SelfApproaching.sol";

contract SelfApproachingTest is Test {
    /// @dev Scale of the integer coordinate grid: 1e18 per unit, as the library expects.
    int256 internal constant ONE = 1e18;

    // ------------------------------------------------------------------ generators

    /// @dev A random walk with momentum: each step turns the previous direction a little.
    function _walk(uint256 seed, uint256 n) internal pure returns (int256[] memory xs, int256[] memory ys) {
        xs = new int256[](n);
        ys = new int256[](n);
        int256 dx = ONE;
        int256 dy = 0;
        for (uint256 i = 1; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            int256 turn = int256(seed % 2_000) - 1_000;
            int256 ndx = dx - (dy * turn) / 10_000;
            int256 ndy = dy + (dx * turn) / 10_000;
            dx = ndx;
            dy = ndy;
            xs[i] = xs[i - 1] + dx;
            ys[i] = ys[i - 1] + dy;
        }
    }

    /// @dev Extra shrink per spiral step, 1e-4 (see `_spiral`).
    int256 internal constant SPIRAL_SLACK = 1e14;

    /// @dev An inward spiral about a later point: the polygonal form of an arc, and the shape
    ///      the paper's own numerics converge to (Section 7.6). A polygon *inscribed* in a
    ///      circle is not self-approaching: mid-chord it passes closer to the centre than it
    ///      ends up, so it moves away from a later point. Here each segment ends just inside
    ///      the foot of the perpendicular from the centre: the radius shrinks by
    ///      cos(step) * (1 - SPIRAL_SLACK). Exactly at the foot point, the final chord into the
    ///      centre would sit on the boundary of Lemma 7.1's half-plane at every vertex, and the
    ///      rounding of the Taylor-series inputs would tip about half of those conditions the
    ///      wrong way. With the slack, every condition holds with a margin of about
    ///      cos(step) * 1e-4 * r^2, far above the rounding. The curve ends at the centre, the
    ///      point it approaches.
    function _spiral(uint256 steps, int256 totalMilliRad)
        internal
        pure
        returns (int256[] memory xs, int256[] memory ys)
    {
        return _spiralWad(steps, (totalMilliRad * 1e15) / int256(steps), SPIRAL_SLACK);
    }

    /// @dev `steps` spiral vertices at angles 0, step, 2 step, ... (radians in WAD), then the
    ///      centre. `slack` is the extra shrink per step in WAD.
    function _spiralWad(uint256 steps, int256 stepWad, int256 slack)
        internal
        pure
        returns (int256[] memory xs, int256[] memory ys)
    {
        xs = new int256[](steps + 1);
        ys = new int256[](steps + 1);
        (int256 cosStep,) = _cosSinWad(stepWad);
        int256 r = ONE;
        for (uint256 i; i < steps; ++i) {
            (int256 c, int256 s) = _cosSinWad(stepWad * int256(i));
            xs[i] = (r * c) / ONE;
            ys[i] = (r * s) / ONE;
            r = (r * cosStep) / ONE;
            r -= (r * slack) / ONE;
        }
        xs[steps] = 0; // the final chord into the centre
        ys[steps] = 0;
    }

    /// @dev A straight segment: the trivial self-approaching curve, L = D.
    function _segment(uint256 n) internal pure returns (int256[] memory xs, int256[] memory ys) {
        xs = new int256[](n);
        ys = new int256[](n);
        for (uint256 i; i < n; ++i) {
            xs[i] = int256(i) * ONE;
        }
    }

    /// @dev A cloud of random points: almost never self-approaching.
    function _cloud(uint256 seed, uint256 n) internal pure returns (int256[] memory xs, int256[] memory ys) {
        xs = new int256[](n);
        ys = new int256[](n);
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i, "cloud")));
            xs[i] = int256(seed % 2_000_000) - 1_000_000;
            ys[i] = int256((seed >> 32) % 2_000_000) - 1_000_000;
        }
    }

    /// @dev cos and sin of `milliRad` milliradians, scaled by 1e18.
    function _cosSin(int256 milliRad) internal pure returns (int256 c, int256 s) {
        return _cosSinWad(milliRad * 1e15);
    }

    /// @dev cos and sin of `a` radians (WAD), scaled by 1e18, from the Taylor series: accurate
    ///      to about 1e-16 at pi/3 and 2e-8 at 2.8. Only these test inputs are approximate; the
    ///      library itself is exact.
    function _cosSinWad(int256 a) internal pure returns (int256 c, int256 s) {
        int256 a2 = (a * a) / ONE;
        int256 t = ONE;
        c = ONE;
        for (int256 k = 2; k <= 16; k += 2) {
            t = -(t * a2) / ONE / (k * (k - 1));
            c += t;
        }
        t = a;
        s = a;
        for (int256 k = 3; k <= 17; k += 2) {
            t = -(t * a2) / ONE / (k * (k - 1));
            s += t;
        }
    }

    // ------------------------------------------------------------------ oracles

    /// @dev Brute-force diameter over all pairs, for checking Lemma 2.1.
    function _diameterSqAllPairs(int256[] memory xs, int256[] memory ys) internal pure returns (uint256 d2) {
        for (uint256 i; i < xs.length; ++i) {
            for (uint256 j = i + 1; j < xs.length; ++j) {
                int256 dx = xs[j] - xs[i];
                int256 dy = ys[j] - ys[i];
                uint256 q = uint256(dx * dx + dy * dy);
                if (q > d2) d2 = q;
            }
        }
    }

    /// @dev Lemma 2.2: from any vertex, any two later vertices are at most a right angle apart.
    function _rightAngleHolds(int256[] memory xs, int256[] memory ys) internal pure returns (bool) {
        for (uint256 i; i < xs.length; ++i) {
            for (uint256 j = i + 1; j < xs.length; ++j) {
                for (uint256 k = j; k < xs.length; ++k) {
                    int256 ax = xs[j] - xs[i];
                    int256 ay = ys[j] - ys[i];
                    int256 bx = xs[k] - xs[i];
                    int256 by = ys[k] - ys[i];
                    if (ax * bx + ay * by < 0) return false;
                }
            }
        }
        return true;
    }

    /// @dev Perimeter of the convex hull, rounded up, for Corollary 3.2 (Andrew's monotone
    ///      chain: sort by (x, y), then build the lower and the upper hull).
    function _hullPerimeterUp(int256[] memory xs, int256[] memory ys) internal pure returns (uint256 per) {
        uint256 n = xs.length;
        uint256[] memory order = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            order[i] = i;
        }
        for (uint256 i = 1; i < n; ++i) {
            uint256 cur = order[i];
            uint256 j = i;
            while (j > 0 && _less(xs, ys, cur, order[j - 1])) {
                order[j] = order[j - 1];
                --j;
            }
            order[j] = cur;
        }
        uint256[] memory hull = new uint256[](2 * n);
        uint256 h;
        for (uint256 pass; pass < 2; ++pass) {
            uint256 start = h;
            for (uint256 t; t < n; ++t) {
                uint256 idx = pass == 0 ? order[t] : order[n - 1 - t];
                while (h >= start + 2 && _cross(xs, ys, hull[h - 2], hull[h - 1], idx) <= 0) {
                    --h;
                }
                hull[h++] = idx;
            }
            --h; // this chain's last point starts the next one
        }
        if (h < 2) return 0; // every point identical
        for (uint256 i; i < h; ++i) {
            uint256 a = hull[i];
            uint256 b = hull[(i + 1) % h];
            int256 dx = xs[b] - xs[a];
            int256 dy = ys[b] - ys[a];
            per += Math.sqrt(uint256(dx * dx + dy * dy), Math.Rounding.Ceil);
        }
    }

    function _less(int256[] memory xs, int256[] memory ys, uint256 a, uint256 b) private pure returns (bool) {
        return xs[a] < xs[b] || (xs[a] == xs[b] && ys[a] < ys[b]);
    }

    function _cross(int256[] memory xs, int256[] memory ys, uint256 o, uint256 a, uint256 b)
        private
        pure
        returns (int256)
    {
        return (xs[a] - xs[o]) * (ys[b] - ys[o]) - (ys[a] - ys[o]) * (xs[b] - xs[o]);
    }

    // ------------------------------------------------------------------ properties

    function _checkAccepted(int256[] memory xs, int256[] memory ys) internal pure {
        // (1) Lemma 2.1: the diameter is the largest distance from the start.
        require(
            SelfApproaching.diameterSqFromStart(xs, ys) == _diameterSqAllPairs(xs, ys),
            "Lemma 2.1: diameter is the largest distance from the start"
        );
        // (2) Lemma 2.2: a right angle at every vertex.
        require(_rightAngleHolds(xs, ys), "Lemma 2.2: right angle");
        // (3) Corollary 3.2: length <= hull perimeter. Both sides round up, so allow one unit
        //     of rounding per segment.
        (uint256 lengthUp, uint256 diameterDown, bool ok) = SelfApproaching.lengthBound(xs, ys);
        require(lengthUp <= _hullPerimeterUp(xs, ys) + xs.length, "Corollary 3.2: length <= hull perimeter");
        // (4) Theorem 4.3: length <= 3.1356... x diameter.
        require(ok, "Theorem 4.3: length <= C_SA_UPPER x diameter");
        require(diameterDown > 0, "positive diameter");
    }

    /// @dev Every rejected polygon has a witness: a point just before v_i on its incoming
    ///      segment, together with v_i and v_j, violates eq. (1.1).
    function _checkRejected(int256[] memory xs, int256[] memory ys) internal pure {
        for (uint256 i = 1; i < xs.length; ++i) {
            for (uint256 j = i + 1; j < xs.length; ++j) {
                int256 dx = xs[i] - xs[i - 1];
                int256 dy = ys[i] - ys[i - 1];
                if ((xs[j] - xs[i]) * dx + (ys[j] - ys[i]) * dy >= 0) continue;
                int256 px = xs[i] - dx / 1024; // just before v_i on its incoming segment
                int256 py = ys[i] - dy / 1024;
                uint256 fromX = uint256((xs[j] - px) * (xs[j] - px) + (ys[j] - py) * (ys[j] - py));
                uint256 fromVi = uint256((xs[j] - xs[i]) * (xs[j] - xs[i]) + (ys[j] - ys[i]) * (ys[j] - ys[i]));
                if (fromVi > fromX) return; // the curve moved away from a later point
            }
        }
        revert("rejected polygon without a witness");
    }

    // ------------------------------------------------------------------ tests

    function test_segmentIsSelfApproaching() public pure {
        (int256[] memory xs, int256[] memory ys) = _segment(9);
        require(SelfApproaching.isSelfApproaching(xs, ys), "a straight line");
        _checkAccepted(xs, ys);
        (uint256 len, uint256 diam,) = SelfApproaching.lengthBound(xs, ys);
        require(len == diam, "a straight line has L = D");
    }

    function test_spiralAboutALaterPointIsSelfApproaching() public pure {
        (int256[] memory xs, int256[] memory ys) = _spiral(16, 2_800); // 2.8 rad < 0.9 pi
        require(SelfApproaching.isSelfApproaching(xs, ys), "spiral accepted");
        _checkAccepted(xs, ys);
    }

    /// Theorem 5.4's family in polygonal form: a spiral of pi/3 about the end point, then the
    /// chord into it. The paper doubles that last segment with a cycloidal cascade (Lemma 5.1),
    /// which a polygon reproduces only with many vertices per cycloid (Section 7.5); sampling
    /// the cascade does not give a self-approaching polygon (see the cascade test below). So
    /// this is the construction without the cascade, whose limit is 1 + pi/3.
    function test_theorem54FamilyIsAcceptedAndBounded() public {
        (int256[] memory xs, int256[] memory ys) = _spiral(24, 1_047); // pi/3
        require(SelfApproaching.isSelfApproaching(xs, ys), "construction accepted");
        _checkAccepted(xs, ys);
        (uint256 len, uint256 diam,) = SelfApproaching.lengthBound(xs, ys);
        uint256 ratio = (len * 1e18) / diam;
        emit log_named_uint("spiral + chord L/D (WAD)", ratio);
        assertGt(ratio, 1.9e18, "well above a straight line");
        assertLt(ratio, SelfApproaching.C_SA_UPPER_WAD, "inside the proven bound");
    }

    /// The limit curve of Theorem 5.4 without the cascade, a unit arc of pi/3 about its end
    /// point followed by the chord into it, has L/D = 1 + pi/3. Its spiral polygons converge to
    /// that value from below; the inward spiral costs about 0.84/N (Section 7.6).
    function test_theorem54LimitCurveConvergesFromBelow() public {
        uint256 onePlusPiOver3 = 2_047_197_551_196_597_746;
        uint256 piOver3 = 1_047_197_551_196_597_746;
        uint256[3] memory ns = [uint256(24), 96, 384];
        uint256 previous;
        for (uint256 k; k < 3; ++k) {
            uint256 n = ns[k];
            // n spiral vertices sweeping exactly pi/3, then the centre.
            (int256[] memory xs, int256[] memory ys) = _spiralWad(n, int256(piOver3 / (n - 1)), 1e9);
            require(SelfApproaching.isSelfApproaching(xs, ys), "spiral polygon accepted");
            (uint256 len, uint256 diam, bool ok) = SelfApproaching.lengthBound(xs, ys);
            require(ok, "Theorem 4.3");
            uint256 ratio = (len * 1e18) / diam;
            emit log_named_uint(string.concat("N = ", vm.toString(n), ": L/D (WAD)"), ratio);
            emit log_named_uint(string.concat("N = ", vm.toString(n), ": N x gap (WAD)"), n * (onePlusPiOver3 - ratio));
            assertLt(ratio, onePlusPiOver3, "below the limit curve");
            assertGt(ratio, previous, "increasing in N");
            previous = ratio;
        }
        assertLt(onePlusPiOver3 - previous, 0.003e18, "within 0.003 of 1 + pi/3 at N = 384");
    }

    /// Lemma 5.1: a cycloidal cascade on a segment of length w with n pieces has length 2w and
    /// stays within pi w / (2n) of the segment. The fixture samples the paper's own cascade
    /// (sa_fix/code/cascade.py) with m points per piece. Two lessons for on-chain checks:
    /// a band (shape) condition admits doubled length, and sampling a self-approaching curve
    /// does not give a self-approaching polygon. Lemma 7.1 rejects every sample, with a witness.
    function test_lemma51CascadeSamplesStayInTheBandAndAreRejected() public {
        string memory j = vm.readFile("test/paper/fixtures/cascade_lemma51.json");
        uint256 count = vm.parseJsonUint(j, ".count");
        for (uint256 p; p < count; ++p) {
            string memory key = string.concat(".polygons[", vm.toString(p), "]");
            uint256 pieces = vm.parseJsonUint(j, string.concat(key, ".pieces"));
            string[] memory xsStr = vm.parseJsonStringArray(j, string.concat(key, ".xs"));
            string[] memory ysStr = vm.parseJsonStringArray(j, string.concat(key, ".ys"));
            int256[] memory xs = new int256[](xsStr.length);
            int256[] memory ys = new int256[](ysStr.length);
            for (uint256 i; i < xs.length; ++i) {
                xs[i] = vm.parseInt(xsStr[i]);
                ys[i] = vm.parseInt(ysStr[i]);
            }
            // The band: pi r <= x <= 2 pi r with r = w / (2n), w = 1 (to 1e-15 for rounding).
            int256 piR = int256(3_141_592_653_589_793_238 / (2 * pieces));
            for (uint256 i; i < xs.length; ++i) {
                assertGe(xs[i], piR - 1e3, "inside the band");
                assertLe(xs[i], 2 * piR + 1e3, "inside the band");
            }
            // Length close to 2w, never more than the curve's 2w.
            (uint256 lengthUp,,) = SelfApproaching.lengthBound(xs, ys);
            assertGt(lengthUp, 1.95e18, "close to doubled length");
            assertLe(lengthUp, 2e18 + xs.length, "no longer than the cascade");
            // Not self-approaching as a polygon, and the rejection has a witness.
            assertFalse(SelfApproaching.isSelfApproaching(xs, ys), "sampled cascade rejected");
            _checkRejected(xs, ys);
        }
        emit log_named_uint("sampled cascades checked", count);
    }

    function test_cloudIsRejectedWithAWitness() public pure {
        (int256[] memory xs, int256[] memory ys) = _cloud(42, 10);
        require(!SelfApproaching.isSelfApproaching(xs, ys), "a random cloud is not self-approaching");
        _checkRejected(xs, ys);
    }

    function testFuzz_walksSatisfyEveryTheorem(uint256 seed, uint8 nRaw) public pure {
        uint256 n = _bound(nRaw, 3, 24);
        (int256[] memory xs, int256[] memory ys) = _walk(seed, n);
        if (SelfApproaching.isSelfApproaching(xs, ys)) {
            _checkAccepted(xs, ys);
        } else {
            _checkRejected(xs, ys);
        }
    }

    function testFuzz_spiralsOfAnyAngleUpToPiAreAccepted(uint16 milliRadRaw, uint8 stepsRaw) public pure {
        int256 milliRad = int256(_bound(milliRadRaw, 100, 2_800));
        uint256 steps = _bound(stepsRaw, 2, 20);
        (int256[] memory xs, int256[] memory ys) = _spiral(steps, milliRad);
        require(SelfApproaching.isSelfApproaching(xs, ys), "a spiral about a later point");
        _checkAccepted(xs, ys);
    }

    /// `canAppend` agrees with a full re-check on a valid prefix.
    function testFuzz_canAppendMatchesFullCheck(uint256 seed, uint8 nRaw) public pure {
        uint256 n = _bound(nRaw, 2, 16);
        (int256[] memory xs, int256[] memory ys) = _walk(seed, n);
        if (!SelfApproaching.isSelfApproaching(xs, ys)) return;
        int256 px = xs[n - 1] + int256(seed % 3_000_000) - 1_500_000;
        int256 py = ys[n - 1] + int256((seed >> 16) % 3_000_000) - 1_500_000;

        int256[] memory xs2 = new int256[](n + 1);
        int256[] memory ys2 = new int256[](n + 1);
        for (uint256 i; i < n; ++i) {
            xs2[i] = xs[i];
            ys2[i] = ys[i];
        }
        xs2[n] = px;
        ys2[n] = py;
        require(
            SelfApproaching.canAppend(xs, ys, px, py) == SelfApproaching.isSelfApproaching(xs2, ys2),
            "canAppend == full check on a valid prefix"
        );
    }

    function test_coordinateRangeIsEnforced() public {
        int256[] memory xs = new int256[](2);
        int256[] memory ys = new int256[](2);
        xs[1] = SelfApproaching.MAX_COORD + 1;
        vm.expectRevert(SelfApproaching.CoordinateOutOfRange.selector);
        this.callIsSelfApproaching(xs, ys);

        int256[] memory short_ = new int256[](1);
        vm.expectRevert(SelfApproaching.LengthMismatch.selector);
        this.callIsSelfApproaching(xs, short_);
    }

    function callIsSelfApproaching(int256[] memory xs, int256[] memory ys) external pure returns (bool) {
        return SelfApproaching.isSelfApproaching(xs, ys);
    }

    /// Gas for accepted polygons only, so `isSelfApproaching` runs its full O(N^2) pass rather
    /// than returning at the first violation.
    function test_gas() public {
        uint256[3] memory sizes = [uint256(8), 16, 32];
        for (uint256 s; s < 3; ++s) {
            (int256[] memory xs, int256[] memory ys) = _spiral(sizes[s] - 1, 2_000);
            uint256 g = gasleft();
            bool accepted = SelfApproaching.isSelfApproaching(xs, ys);
            emit log_named_uint(string.concat("isSelfApproaching, N = ", vm.toString(sizes[s])), g - gasleft());
            require(accepted, "gas is measured on an accepted polygon");
            g = gasleft();
            SelfApproaching.diameterSqFromStart(xs, ys);
            emit log_named_uint(string.concat("diameterSqFromStart, N = ", vm.toString(sizes[s])), g - gasleft());
            g = gasleft();
            SelfApproaching.lengthBound(xs, ys);
            emit log_named_uint(string.concat("lengthBound, N = ", vm.toString(sizes[s])), g - gasleft());
            g = gasleft();
            SelfApproaching.canAppend(xs, ys, xs[sizes[s] - 1], ys[sizes[s] - 1] + ONE);
            emit log_named_uint(string.concat("canAppend, N = ", vm.toString(sizes[s])), g - gasleft());
        }
    }
}

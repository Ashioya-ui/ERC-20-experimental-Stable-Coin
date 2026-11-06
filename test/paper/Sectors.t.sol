// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SelfApproaching} from "../../src/libraries/SelfApproaching.sol";

/// Admissible paths: a margin that survives rounding (condition (5.2)), collinear refinement that
/// changes nothing, and the winding sector of Proposition 7.14 with its tighter bound. Every
/// fixture below was first checked in exact integer arithmetic.
contract SectorsTest is Test {
    function _dyn(int256[11] memory a) internal pure returns (int256[] memory b) {
        b = new int256[](11);
        for (uint256 i; i < 11; ++i) {
            b[i] = a[i];
        }
    }

    function _dyn(int256[8] memory a) internal pure returns (int256[] memory b) {
        b = new int256[](8);
        for (uint256 i; i < 8; ++i) {
            b[i] = a[i];
        }
    }

    /// A spiral into its end f = (0, 0): counter-clockwise, turning 0.9π, radius falling by 0.8 a step.
    function _spiral() internal pure returns (int256[] memory xs, int256[] memory ys) {
        xs = _dyn(
            [int256(1_000_000), 768_235, 540_370, 338_592, 174_399, 51_260, -32_855, -83_288, -106_942, -111_009, -102_119]
        );
        ys = _dyn([int256(0), 223_193, 342_929, 384_057, 370_617, 323_646, 260_077, 192_467, 129_271, 75_442, 33_180]);
    }

    function _withMargin() internal pure returns (int256[] memory xs, int256[] memory ys) {
        xs = _dyn([int256(0), 72_071, 145_610, 211_727, 244_817, 288_564, 317_581, 355_722]);
        ys = _dyn([int256(0), 23_046, 53_455, 94_963, 118_937, 174_542, 221_684, 299_877]);
    }

    function test_aSpiralIntoItsEnd_isInTheSector_andWithinTheTighterBound() public pure {
        (int256[] memory xs, int256[] memory ys) = _spiral();
        assertTrue(SelfApproaching.isSelfApproaching(xs, ys));
        assertTrue(SelfApproaching.canAppend(xs, ys, 0, 0), "the end stays reachable");
        (bool inSector,,, bool ok) = SelfApproaching.windingBound(xs, ys, 0, 0, true);
        assertTrue(inSector);
        assertTrue(ok, "Proposition 7.14: L + 2|v_N - f| <= (2 + pi/3) D");
        (bool cw,,,) = SelfApproaching.windingBound(xs, ys, 0, 0, false);
        assertFalse(cw, "clockwise it is not monotone");
    }

    function test_turningBackOrPastPi_leavesTheSector() public pure {
        (int256[] memory xs, int256[] memory ys) = _spiral();
        (xs[5], xs[6]) = (xs[6], xs[5]);
        (ys[5], ys[6]) = (ys[6], ys[5]);
        (bool back,,,) = SelfApproaching.windingBound(xs, ys, 0, 0, true);
        assertFalse(back, "a step back in angle");
        (xs, ys) = _spiral();
        xs[10] = -90_000;
        ys[10] = -20_000;
        (bool past,,,) = SelfApproaching.windingBound(xs, ys, 0, 0, true);
        assertFalse(past, "a turn past pi");
    }

    function test_aMarginSurvivesRounding() public pure {
        (int256[] memory xs, int256[] memory ys) = _withMargin();
        for (uint256 k = 1; k < 8; ++k) {
            int256[] memory hx = new int256[](k);
            int256[] memory hy = new int256[](k);
            for (uint256 i; i < k; ++i) {
                (hx[i], hy[i]) = (xs[i], ys[i]);
            }
            assertTrue(SelfApproaching.canAppendWithMargin(hx, hy, xs[k], ys[k], 1, 4), "built with margin 1/4");
        }
        // Every vertex moved by (+-902, +-902), within eta*m/8 = 1276 of where it was planned.
        int256[8] memory sx = [int256(1), -1, -1, -1, 1, -1, -1, -1];
        int256[8] memory sy = [int256(1), 1, -1, -1, 1, 1, -1, -1];
        int256[] memory qx = new int256[](8);
        int256[] memory qy = new int256[](8);
        for (uint256 i; i < 8; ++i) {
            qx[i] = xs[i] + sx[i] * 902;
            qy[i] = ys[i] + sy[i] * 902;
        }
        assertTrue(SelfApproaching.isSelfApproaching(qx, qy), "rounding cannot break an admissible path");
    }

    function test_aSaturatedStaircase_hasNoMargin() public pure {
        int256[] memory xs = new int256[](3);
        int256[] memory ys = new int256[](3);
        (xs[1], ys[1]) = (10, 0);
        (xs[2], ys[2]) = (10, 10);
        assertTrue(SelfApproaching.canAppend(xs, ys, 20, 10));
        assertFalse(SelfApproaching.canAppendWithMargin(xs, ys, 20, 10, 1, 4), "a right angle has zero margin");
    }

    function test_collinearRefinement_changesNothing() public pure {
        (int256[] memory xs, int256[] memory ys) = _spiral();
        int256[] memory rx = new int256[](21);
        int256[] memory ry = new int256[](21);
        for (uint256 i; i < 11; ++i) {
            (xs[i], ys[i]) = (2 * xs[i], 2 * ys[i]);
            (rx[2 * i], ry[2 * i]) = (xs[i], ys[i]);
            if (i > 0) (rx[2 * i - 1], ry[2 * i - 1]) = ((xs[i - 1] + xs[i]) / 2, (ys[i - 1] + ys[i]) / 2);
        }
        assertTrue(SelfApproaching.isSelfApproaching(rx, ry), "splitting every step keeps the polygon");
        (uint256 l0, uint256 d0,) = SelfApproaching.lengthBound(xs, ys);
        (uint256 l1, uint256 d1, bool ok) = SelfApproaching.lengthBound(rx, ry);
        assertEq(d1, d0, "same diameter");
        assertApproxEqAbs(l1, l0, 10, "same length, up to one unit of rounding per new segment");
        assertTrue(ok);
        (bool inSector,,, bool wok) = SelfApproaching.windingBound(rx, ry, 0, 0, true);
        assertTrue(inSector && wok, "still in the sector");
    }
}

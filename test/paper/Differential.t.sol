// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  SelfApproaching.sol against the paper's own reference code (Phase 4, C3).
//
//  fixtures/differential_1000.json holds 1,000 integer polygons and, for each, what the
//  paper's Python (sa_fix/code/sapoly.py: pair_index, sa_residuals, length) computes: the
//  Lemma 7.1 verdict, the largest squared distance from the start (Lemma 2.1) and the rounded
//  length. Coordinates are below 2^20, so the paper's float64 arithmetic is exact and the
//  verdicts must agree on every polygon, borderline ones included (the generator re-checks
//  this in Python integers). Regenerate with fixtures/gen_differential.py.
// =====================================================================================

import {Test} from "forge-std/Test.sol";
import {SelfApproaching} from "../../src/libraries/SelfApproaching.sol";

contract DifferentialTest is Test {
    string internal constant FIXTURE = "test/paper/fixtures/differential_1000.json";

    uint256[] internal offsets;
    int256[] internal allX;
    int256[] internal allY;
    bool[] internal accepted;
    uint256[] internal d2;
    uint256[] internal lengthRounded;

    function setUp() public {
        string memory j = vm.readFile(FIXTURE);
        offsets = vm.parseJsonUintArray(j, ".offsets");
        allX = vm.parseJsonIntArray(j, ".xs");
        allY = vm.parseJsonIntArray(j, ".ys");
        accepted = vm.parseJsonBoolArray(j, ".accepted");
        string[] memory d2s = vm.parseJsonStringArray(j, ".d2");
        for (uint256 i; i < d2s.length; ++i) {
            d2.push(vm.parseUint(d2s[i]));
        }
        lengthRounded = vm.parseJsonUintArray(j, ".lengthRounded");
        assertEq(accepted.length, 1000, "1,000 polygons");
        assertEq(offsets.length, 1001);
    }

    function test_agreesWithThePaperOnPolygons0To249() public view {
        _check(0, 250);
    }

    function test_agreesWithThePaperOnPolygons250To499() public view {
        _check(250, 500);
    }

    function test_agreesWithThePaperOnPolygons500To749() public view {
        _check(500, 750);
    }

    function test_agreesWithThePaperOnPolygons750To999() public view {
        _check(750, 1000);
    }

    function _check(uint256 from, uint256 to) internal view {
        for (uint256 p = from; p < to; ++p) {
            (int256[] memory xs, int256[] memory ys) = _polygon(p);
            uint256 segments = xs.length - 1;

            // Lemma 7.1: identical verdicts, exact in both implementations.
            assertEq(SelfApproaching.isSelfApproaching(xs, ys), accepted[p], string.concat("verdict #", vm.toString(p)));

            // Lemma 2.1's quantity, exact in both.
            assertEq(SelfApproaching.diameterSqFromStart(xs, ys), d2[p], string.concat("d2 #", vm.toString(p)));

            // Length: the library rounds each segment up, the paper's float sum is rounded once.
            (uint256 lengthUp, uint256 diameterDown, bool ok) = SelfApproaching.lengthBound(xs, ys);
            assertGe(lengthUp + 1, lengthRounded[p], string.concat("length low #", vm.toString(p)));
            assertLe(lengthUp, lengthRounded[p] + segments + 1, string.concat("length high #", vm.toString(p)));

            // Theorem 4.3 holds for every accepted polygon, after sound rounding.
            if (accepted[p] && diameterDown > 0) {
                assertTrue(ok, string.concat("Theorem 4.3 #", vm.toString(p)));
            }
        }
    }

    function _polygon(uint256 p) internal view returns (int256[] memory xs, int256[] memory ys) {
        uint256 a = offsets[p];
        uint256 n = offsets[p + 1] - a;
        xs = new int256[](n);
        ys = new int256[](n);
        for (uint256 i; i < n; ++i) {
            xs[i] = allX[a + i];
            ys[i] = allY[a + i];
        }
    }
}

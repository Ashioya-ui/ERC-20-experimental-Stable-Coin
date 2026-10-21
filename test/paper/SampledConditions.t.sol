// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Section 7.5 of the paper, as a regression test: checks made only at sampled points are not
//  enough.
//
//  The fixture is the 31-point sequence the paper's own search found in the cap K. It passes
//  the self-approaching triple condition at its own points, but its polygon violates Lemma 7.1
//  in 68 places and is longer than per(K) = 1 + pi/3, which no self-approaching curve in K can
//  be (Corollary 3.2). Any on-chain check that samples instead of testing the polygon would
//  accept it.
// =====================================================================================

import {Test} from "forge-std/Test.sol";
import {SelfApproaching} from "../../src/libraries/SelfApproaching.sol";

contract SampledConditionsTest is Test {
    string internal constant FIXTURE = "test/paper/fixtures/self_contracted_cap_31.json";

    int256[] internal xs;
    int256[] internal ys;

    function setUp() public {
        string memory j = vm.readFile(FIXTURE);
        string[] memory xsStr = vm.parseJsonStringArray(j, ".xs");
        string[] memory ysStr = vm.parseJsonStringArray(j, ".ys");
        assertEq(xsStr.length, ysStr.length);
        for (uint256 i; i < xsStr.length; ++i) {
            xs.push(vm.parseInt(xsStr[i]));
            ys.push(vm.parseInt(ysStr[i]));
        }
    }

    /// The sequence satisfies |z_j - z_k| <= |z_i - z_k| at its own points (to 1e-9 relative),
    /// which is the condition a sampled check would test.
    function test_passesTheVertexOnlyTripleCheck() public view {
        uint256 n = xs.length;
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                for (uint256 k = j + 1; k < n; ++k) {
                    uint256 later = _dist2(j, k);
                    uint256 earlier = _dist2(i, k);
                    if (later <= earlier) continue;
                    // Allow a relative 1e-9 on the squared distances (the fixture is rounded
                    // to 1e-18 from the paper's float data).
                    assertLe((later - earlier) * 1e9, earlier, "vertex-only triple condition");
                }
            }
        }
    }

    /// Lemma 7.1 rejects it, in many places.
    function test_isRejectedByLemma71() public view {
        assertFalse(SelfApproaching.isSelfApproaching(xs, ys), "the polygon is not self-approaching");
        uint256 violations;
        for (uint256 i = 1; i < xs.length; ++i) {
            for (uint256 j = i + 1; j < xs.length; ++j) {
                int256 dot = (xs[j] - xs[i]) * (xs[i] - xs[i - 1]) + (ys[j] - ys[i]) * (ys[i] - ys[i - 1]);
                if (dot < 0) ++violations;
            }
        }
        assertEq(violations, 68, "the count the paper's data gives");
    }

    /// And it is longer than any self-approaching curve in the cap can be: per(K) = 1 + pi/3.
    function test_isLongerThanTheCapPerimeter() public view {
        (uint256 lengthUp,,) = SelfApproaching.lengthBound(xs, ys);
        uint256 perK = 2_047_197_551_196_597_746; // 1 + pi/3, in 1e18 units
        assertGt(lengthUp, perK, "longer than per(K): no curve in K can do this");
        assertLt(lengthUp, 2_091_000_000_000_000_000, "the paper's 2.0907");
    }

    /// The cap really does contain it: every point is in {y >= 0} and within the unit disc
    /// about a = (1/2, -sqrt(3)/2). So the length is not explained by leaving the region.
    function test_everyPointLiesInTheCap() public view {
        int256 ax = 500_000_000_000_000_000; // 0.5
        int256 ay = -866_025_403_784_438_647; // -sqrt(3)/2, rounded down in magnitude
        for (uint256 i; i < xs.length; ++i) {
            assertGe(ys[i], 0, "upper half plane");
            int256 dx = xs[i] - ax;
            int256 dy = ys[i] - ay;
            uint256 d2 = uint256(dx * dx + dy * dy);
            // (1 + 1e-9)^2 in 1e36 units, to absorb the fixture's rounding
            assertLe(d2, 1_000_000_002_000_000_000_000_000_000_000_000_000, "inside the unit disc about a");
        }
    }

    function _dist2(uint256 i, uint256 j) internal view returns (uint256) {
        int256 dx = xs[i] - xs[j];
        int256 dy = ys[i] - ys[j];
        return uint256(dx * dx + dy * dy);
    }
}

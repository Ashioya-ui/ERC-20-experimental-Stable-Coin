// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Phase 4, C3 (6): grow polygons one accepted vertex at a time and check Theorem 4.3.
//
//  The handler proposes a vertex by turning the current heading through a random angle and
//  stepping a random distance. It keeps the vertex only if SelfApproaching.canAppend accepts it
//  (Lemma 7.1, the N new constraints), and restarts now and then. After every call:
//    - the polygon kept so far passes the full O(N^2) check (canAppend is consistent);
//    - L <= C_SA_UPPER x D after sound rounding (Theorem 4.3, proven).
//  The best L/D found is logged at the end of each run (each run starts afresh).
// =====================================================================================

import {Test} from "forge-std/Test.sol";
import {SelfApproaching} from "../../src/libraries/SelfApproaching.sol";

contract PolygonHandler is Test {
    int256 internal constant ONE = 1e18;
    uint256 internal constant MAX_VERTICES = 32;

    int256[] internal xs;
    int256[] internal ys;
    int256 internal headX;
    int256 internal headY;

    uint256 public bestRatioWad;
    uint256 public accepted;
    uint256 public refused;
    uint256 public restarts;

    constructor() {
        _restart();
    }

    function polygon() external view returns (int256[] memory, int256[] memory) {
        return (xs, ys);
    }

    /// Propose a vertex: turn by -0.2 to +1.4 rad (biased left, so the polygons tend to spiral,
    /// which is where long self-approaching polygons live), step 1e-6 to 1 unit. About one call
    /// in 50 restarts instead, and so does a full polygon.
    function append(uint16 turnRaw, uint32 stepRaw) external {
        if (xs.length >= MAX_VERTICES || stepRaw % 50 == 0) {
            _restart();
            return;
        }
        int256 turn = int256(bound(turnRaw, 0, 1_600)) - 200; // milliradians
        (int256 c, int256 s) = _cosSin(turn);
        int256 hx = (headX * c - headY * s) / ONE;
        int256 hy = (headX * s + headY * c) / ONE;
        int256 step = int256(bound(stepRaw, 1, 1_000_000)) * 1e12;
        uint256 n = xs.length;
        int256 px = xs[n - 1] + (hx * step) / ONE;
        int256 py = ys[n - 1] + (hy * step) / ONE;

        if (!SelfApproaching.canAppend(xs, ys, px, py)) {
            ++refused;
            return;
        }
        xs.push(px);
        ys.push(py);
        headX = hx;
        headY = hy;
        ++accepted;

        (uint256 lengthUp, uint256 diameterDown,) = SelfApproaching.lengthBound(xs, ys);
        if (diameterDown > 0) {
            uint256 ratio = (lengthUp * 1e18) / diameterDown;
            if (ratio > bestRatioWad) bestRatioWad = ratio;
        }
    }

    function _restart() internal {
        delete xs;
        delete ys;
        xs.push(0);
        ys.push(0);
        headX = ONE;
        headY = 0;
        ++restarts;
    }

    function _cosSin(int256 milliRad) internal pure returns (int256 c, int256 s) {
        int256 a = milliRad * 1e15;
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
}

contract SelfApproachingInvariantTest is Test {
    PolygonHandler internal handler;

    function setUp() public {
        handler = new PolygonHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PolygonHandler.append.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 128
    /// forge-config: ci.invariant.runs = 256
    /// forge-config: ci.invariant.depth = 256
    function invariant_grownPolygonsObeyTheorem43() public view {
        (int256[] memory xs, int256[] memory ys) = handler.polygon();
        assertTrue(SelfApproaching.isSelfApproaching(xs, ys), "canAppend kept a polygon the full check rejects");
        (uint256 lengthUp, uint256 diameterDown, bool ok) = SelfApproaching.lengthBound(xs, ys);
        if (diameterDown > 0) assertTrue(ok, "Theorem 4.3: L <= C_SA_UPPER x D");
        assertLt(handler.bestRatioWad(), SelfApproaching.C_SA_UPPER_WAD, "best L/D stays below C_SA_UPPER");
        lengthUp;
    }

    function afterInvariant() external {
        emit log_named_uint("best L/D in this run (WAD)", handler.bestRatioWad());
        emit log_named_uint("vertices accepted", handler.accepted());
        emit log_named_uint("vertices refused", handler.refused());
        emit log_named_uint("restarts", handler.restarts());
    }
}

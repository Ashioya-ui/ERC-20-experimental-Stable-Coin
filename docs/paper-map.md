# The paper, result by result: what the code uses and what it does not

Source: E. Langetepe and W. A. Ashioya, "The length-over-diameter ratio of self-approaching
curves" (November 2026). Numbering follows that version.

A rectifiable plane curve is **self-approaching** if the distance to every later point is
non-increasing. `C_diam` is the supremum of length over diameter among such curves. The paper
proves `1 + 2π/3 ≤ C_diam ≤ 2π/3 + 4 sin(π/12)`, that is `3.0943… ≤ C_diam ≤ 3.1296…`
(Theorem 1.1). The bounds differ by `sec(π/12) − 1 = 0.0352…`; whether `C_diam = 1 + 2π/3` is
open (Section 9, problem 1).

## Results the code uses

| Result | Status | Where |
|---|---|---|
| **Lemma 8.1**: a polygon is self-approaching iff `(v_j − v_i)·(v_i − v_{i−1}) ≥ 0` for all `1 ≤ i < j ≤ N` | proven | `SelfApproaching.isSelfApproaching`, `canAppend`. Exact in integers, so no tolerance: Section 8.3 shows tolerances let microscopic zig-zags through. |
| **Lemma 2.1**: the diameter is the largest distance from the start | proven | `SelfApproaching.diameterSqFromStart`, checked against a brute-force diameter in the tests. |
| **Theorem 4.2**: `L ≤ (2π/3 + 4 sin(π/12)) · D` | proven | `SelfApproaching.C_SA_UPPER_WAD` and `lengthBound`, length rounded up and diameter down. Also the churn budget, `SpectralStabilizer.CHURN_BUDGET_WAD` (through `SpectralPolicy`): 3.1297, down from 3.1356 under version 21. |
| **Theorem 4.1**: among convex sets of diameter one with a right-angled corner, the trimmed Reuleaux triangle has the largest perimeter, `2π/3 + 4 sin(π/12)` (exact dual certificate) | proven | Why `C_SA_UPPER` is where it is: no argument from the hull alone goes lower (Remark 4.3). |
| **Lemma 2.2**: the rest of the curve lies in a wedge of opening at most `π/2` | proven | Test oracle: asserted for every accepted polygon. |
| **Theorem 3.1, Corollary 3.2**: `L = per(conv C) − ∫σ ≤ per(conv C)` | proven | Test oracle: asserted against a convex hull computed in the test. |
| **Theorem 1.1, Corollary 7.12**: ratios arbitrarily close to `1 + 2π/3` occur | proven | `SelfApproaching.C_SA_LOWER_WAD`, as what it provably is. No rule uses it. |
| **Section 5**: arc-and-cascade curves approach `2 + π/3` | proven | `test/paper/SelfApproaching.t.sol` builds the construction without its cascade; the polygons are accepted, obey Theorem 4.2 and converge from below. |
| **Lemma 5.1**: a cycloidal cascade on a segment of length `w` with `n` pieces has length `2w` and stays within `πw/(2n)` of it | proven | Fixture from the paper's code. Lemma 8.1 rejects every sampled cascade, with a witness: sampling a self-approaching curve does not give a self-approaching polygon. |
| **Theorem 4.2**, searched | proven | `test/paper/SelfApproachingInvariant.t.sol` grows polygons one accepted vertex at a time; after every call `L ≤ C_SA_UPPER · D`. |
| **Section 8.4**: a sampled check is not enough | numerical | `test/paper/SampledConditions.t.sol` plus the 31-point fixture: it passes a vertex-only triple check, fails Lemma 8.1, and is longer than `per(K)`. |
| **The paper's code** | reference implementation | `test/paper/Differential.t.sol`: on 1,000 integer polygons the library and the paper's code agree on every verdict, every diameter and every length to within rounding. |
| **Proposition 7.14**: monotone winding about the end, through at most `π`, then a last step into it: `L + 2|y − f| ≤ (2 + π/3) · D` | proven | `SelfApproaching.windingBound`, `C_SA_WINDING_WAD`: the sector bound, 3.0472 against 3.1297. |
| **Condition (5.2)**, the half-plane criterion with margin `η` | definition | `SelfApproaching.canAppendWithMargin`; Lemma A in `docs/design/admissible-paths.md` proves such polygons survive moves of `ηm/8`. |
| **Open problem 1**: is `C_diam = 1 + 2π/3`? | **open** | **Not used by any code.** |

## Results with no engineering use

| Result | Why not |
|---|---|
| **Theorem 6.3** (cut cascades, multiplicity `1 + cos Θ`) | Structure of extremal curves; nothing to compute on-chain. |
| **Section 7** (curves on the circle about their last diametral partner; Theorem 7.11, `κ = 1 + π/3`) | Gives the lower bound; no rule needs it. |
| **Corollary 7.15** (early exit, `2 + π/3 − α`) | A further sector; not implemented. |
| **Theorem 8.2** (a 362-segment polygon certified in exact rational arithmetic) | A finite check run by the paper's own program. |

## Where the proven bound becomes load-bearing

Only on a two-dimensional state. See `docs/design/reserve-allocation.md`: with the reserve split
across two vaults, Lemma 2.1 and Theorem 4.2 cap an epoch's rebalancing turnover at `3.1297 ×`
the furthest the allocation travels from where the epoch started.

## Do not

1. **No "self-approaching supply."** On a line, self-approaching means monotone. Supply is one
   number; the planar theorems constrain nothing about it.
2. **No stability claims from the geometry.** The churn budget is a design rule that uses one
   constant from the paper.
3. **Never treat open problem 1 as a guarantee.** A rule that needs the constant uses
   `C_SA_UPPER_WAD` (Theorem 4.2, proven).
4. **Never check self-approach by sampling.** Test the polygon with Lemma 8.1, in integers.

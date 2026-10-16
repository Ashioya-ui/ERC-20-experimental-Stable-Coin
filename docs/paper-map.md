# The paper, result by result: what the code uses and what it does not

Source: E. Langetepe and W. A. Ashioya, "The length-over-diameter ratio of self-approaching
curves", revised version 21 (October 2026). Numbering follows that version.

A rectifiable plane curve is **self-approaching** if the distance to every later point is
non-increasing. `C_diam` is the supremum of length over diameter among such curves. The paper
proves `2 + π/3 ≤ C_diam ≤ 5π/6 + 2 sin(π/12)`, that is `3.0471… ≤ C_diam ≤ 3.1356…`, and
conjectures that the lower bound is sharp.

## Results the code uses

| Result | Status | Where |
|---|---|---|
| **Lemma 7.1** — a polygon is self-approaching iff `(v_j − v_i)·(v_i − v_{i−1}) ≥ 0` for all `1 ≤ i < j ≤ N` | proven | `SelfApproaching.isSelfApproaching`, `canAppend`. Exact in integers, so no tolerance is needed — which matters, because Section 7.2 shows absolute tolerances let microscopic zig-zags through. |
| **Lemma 2.1** — the diameter is the largest distance from the start | proven | `SelfApproaching.diameterSqFromStart` (one pass instead of all pairs), checked against a brute-force diameter in the tests. |
| **Theorem 4.3** — `L ≤ (5π/6 + 2 sin(π/12)) · D` | proven | `SelfApproaching.C_SA_UPPER_WAD` and `lengthBound`, with the length rounded up and the diameter down so the check stays sound. |
| **Lemma 2.2** — from any point, two later points subtend at most a right angle | proven | Test oracle: asserted for every accepted polygon. |
| **Corollary 3.2** — `L ≤ perimeter(conv C)` | proven | Test oracle: asserted against a convex hull computed in the test. |
| **Theorem 5.4** — ratios arbitrarily close to `2 + π/3` occur | proven | The generator in `test/paper/SelfApproaching.t.sol` builds its polygonal form (a spiral about the end point, then the chord into it) and checks it is accepted and inside Theorem 4.3. |
| **Section 7.5** — a sampled check is not enough | numerical | `test/paper/SampledConditions.t.sol` plus the 31-point fixture: it passes a vertex-only triple check, fails Lemma 7.1 in 68 places, and is longer than `per(K) = 1 + π/3`. |
| **Section 7.1 code** — the paper's `sapoly.py` (`sa_residuals`, `length`) | reference implementation | `test/paper/Differential.t.sol`: on 1,000 integer polygons (walks, spirals, spirals exactly at their foot points, spirals past π, clouds, repeated and collinear vertices; 541 accepted, 459 rejected) the library and the paper's code agree on every verdict and every diameter, and on every length to within rounding. |
| **Section 7.6** — a polygon approximating an arc about a later point must spiral inwards | numerical | The test generator spirals: an inscribed polygon is *not* self-approaching, because mid-chord it passes closer to the centre than it ends up. |
| **Conjecture 1.2** — `C_diam = 2 + π/3` | **open** | `SpectralStabilizer.C_DIAM_WAD`, used as the churn budget's constant, with NatSpec saying it is attained (Theorem 5.4) but not proven sharp, and that no stability property follows. |

## Results with no engineering use

| Result | Why not |
|---|---|
| **Theorem 3.1** (hull identity) and the slack `σ` | The engine of the paper's upper bound. The code needs the bound, not its proof. |
| **Lemma 5.1** (cycloidal cascade) | A cascade doubles a segment's length inside an arbitrarily thin band. It cannot be drawn as a polygon (Lemma 6.8 makes it terminal), so it has no on-chain form; it is why the polygonal ratios in the tests stay near 2 rather than `2 + π/3`. |
| **Lemma 6.2, Proposition 6.3** (the class `A_α`, the bound `1 + 2π/3`) | About curves starting on the circle about their last diametral partner: a step towards the conjecture, not a usable bound. |
| **Lemmas 6.5, 6.6** (saturated arcs, contact points) | Structure of extremal curves. Nothing to compute. |
| **Lemma 6.8** (strips) | Justifies the paper's numerical model; the code does not build cascades. |
| **Conjectures 6.9, 6.10** (cap, early exit) | Open, and conditional on each other. Nothing may depend on them. |
| **Remark 4.4** (no hull-only argument goes below 3.1296) | Explains why `C_SA_UPPER` is where it is. Informative only. |
| **Section 7.1–7.4** (the optimiser, acceptance test, results) | Reproduced by the paper's own Python; not re-implemented here. |

## Where the proven bound would become load-bearing

Only on a two-dimensional state. See `docs/design/reserve-allocation.md`: with the reserve
split across two vaults, Lemma 2.1 and Theorem 4.3 cap an epoch's rebalancing turnover at
`3.1356 ×` the furthest the allocation travels from where the epoch started. That is a
*proven* limit with no tuned parameter. It is written down, not implemented, and the note
recommends a plain turnover cap first.

## Do not

1. **No "self-approaching supply."** On a line, self-approaching means monotone. Supply is one
   number; the planar theorems constrain nothing about it.
2. **No stability claims from the geometry.** The churn budget is a design rule that uses one
   constant from the paper. It does not inherit any property of self-approaching curves.
3. **Never treat Conjecture 1.2 as a guarantee.** If a safety property ever needs a constant,
   it must be `C_SA_UPPER_WAD` (Theorem 4.3, proven), never `C_DIAM_WAD`.
4. **Never check self-approach by sampling.** Section 7.5 is in the test suite precisely so
   this stays true: test the polygon with Lemma 7.1, in integers.

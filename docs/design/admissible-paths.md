# Admissible paths

Witten (arXiv:2611.05051, Section 3) works only with admissible lattice fields, plaquette
holonomies within ε of the identity, because exactly those have a continuum interpolation whose
topology is defined and stable; refinement keeps cells of bounded flatness (Freudenthal), while
barycentric subdivision does not. Self-approaching paths have the same three structures. The
proofs are below; `SelfApproaching` implements them and `test/paper/Sectors.t.sol` checks them on
fixtures first verified in exact integer arithmetic.

## 1. Margin: admissibility that survives rounding

**Lemma A.** Let `v_0, …, v_N` satisfy `(v_j − v_i)·(v_i − v_{i−1}) ≥ η |v_j − v_i| |v_i − v_{i−1}|`
for all `1 ≤ i < j ≤ N`, with `0 < η ≤ 1` (condition (5.2)), and let `m > 0` be the least of
`|v_j − v_i|` and `|v_i − v_{i−1}|` over those pairs. If every vertex moves by at most
`δ ≤ ηm/8`, the moved polygon satisfies (8.1), so it is self-approaching (Lemma 8.1).

*Proof.* Put `a = v_j − v_i`, `b = v_i − v_{i−1}`; the moved vectors are `a + e`, `b + g` with
`|e|, |g| ≤ 2δ`. By Cauchy–Schwarz, `(a + e)·(b + g) ≥ η|a||b| − 2δ|a| − 2δ|b| − 4δ²`. Since
`|a|, |b| ≥ m` and `δ ≤ ηm/8`: `2δ|a| ≤ (η/4)|a||b|`, `2δ|b| ≤ (η/4)|a||b|` and
`4δ² ≤ η²m²/16 ≤ (η/16)|a||b|`. So `(a + e)·(b + g) ≥ (7η/16)|a||b| > 0`. ∎

`canAppendWithMargin` builds such polygons exactly. A planned move accepted with margin η stays
valid if execution lands within `ηm/8` of the plan: rounding and slippage below that cannot break
the path.

## 2. Refinement: splitting a move changes nothing

**Lemma B.** Inserting `w = v_{i−1} + t(v_i − v_{i−1})`, `0 < t < 1`, into a polygon that
satisfies (8.1) keeps (8.1), the length and the diameter.

*Proof.* Let `b = v_i − v_{i−1}`. For the new segment `[v_{i−1}, w]` and a later vertex `u`:
`(u − w)·(w − v_{i−1}) = t[(u − v_i)·b + (1 − t)|b|²] ≥ 0`, using (8.1) at `i`, and it is
`t(1 − t)|b|²` for `u = v_i`. For `[w, v_i]`: `(u − v_i)·(v_i − w) = (1 − t)(u − v_i)·b ≥ 0`.
As a later point for an earlier segment `k < i`, `w` is a convex combination of `v_{i−1}` and
`v_i`, which both satisfy that segment's inequality. The length is unchanged because `w` is on
the segment, and the diameter because `|w − v_0| ≤ max(|v_{i−1} − v_0|, |v_i − v_0|)` (Lemma 2.1). ∎

An executor may split any accepted move into equal sub-moves (a TWAP) without leaving the class or
changing its bound. Moving a sub-step off the segment, the barycentric analogue, can break (8.1).

**Lemma B′.** Lemma B also keeps condition (5.2), with the same η.

*Proof.* For `[v_{i−1}, w]` and a later vertex `u`: `(u − w)·b = (u − v_i)·b + (1 − t)|b|² ≥
η|u − v_i||b| + (1 − t)|b|² ≥ η(|u − v_i| + (1 − t)|b|)|b| ≥ η|u − w||b|`, using `η ≤ 1` and
`|u − w| ≤ |u − v_i| + |v_i − w|`; multiply by `t`. For `[w, v_i]`: the inequality at `i`, times
`1 − t`. For `w` as a later point of an earlier segment with direction `c`:
`(w − v_k)·c = (1 − t)(v_{i−1} − v_k)·c + t(v_i − v_k)·c ≥ η|c|((1 − t)|v_{i−1} − v_k| + t|v_i − v_k|)
≥ η|c||w − v_k|`, by convexity of the norm. ∎

So a leash agent may split any accepted move into collinear pieces. Each piece passes both
on-chain checks, because the end `E` is a later vertex of the closed polygon. The 32-point cap
still applies.

## 3. Sectors: a class with a tighter bound

On an admissible path to a declared end `f` (no vertex at `f`), the argument about `f` is defined.
Paths whose argument is monotone and turns by at most `π` form a sector. Proposition 7.14 bounds
them: length before the last step plus twice that step is at most `(2 + π/3) · diameter`, against
`(2π/3 + 4 sin(π/12)) · diameter` for every self-approaching path (Theorem 4.2): 3.0472 against
3.1297. `windingBound` decides membership in O(N) with exact cross products (each step turns the
same way; no vertex passes `π` from the first) and checks the bound with the length rounded up and
the diameter down.

## 4. The margin sets the cap

**Lemma C.** A polygon that passes the leash's test with margin `η` (condition (5.2) at every
vertex, the end `E` included) is φ-self-approaching in the sense of Aichholzer, Aurenhammer,
Icking, Klein, Langetepe and Rote (*Generalized self-approaching curves*, Discrete Applied
Mathematics 109 (2001)), with `φ = min(π/2, 2 arccos η)`.

*Proof.* Let `α = arccos η` and let `p` lie on segment `i`, direction `b`. Every later vertex `v_j`
satisfies `∠(v_j − v_i, b) ≤ α` (the test), and `v_j − p = (v_j − v_i) + λb` with `λ ≥ 0`, so
`∠(v_j − p, b) ≤ α`. Later points on segments are convex combinations of later vertices, and a
cone of half-angle `α ≤ π/2` is convex, so the rest of the polygon lies in the cone of half-angle
`α` around `b`. It also lies in a right-angle wedge at `p` (Lemma 2.2), so it lies in their
intersection, whose angle is at most `min(2α, π/2)`. ∎

Their Theorem 7 bounds the length by `c(φ)` times the start-to-end distance, tightly, with `c`
strictly increasing, `c(0) = 1` and `c(π/2) ≈ 5.3331`. So for `η > 1/√2` the leash's cap is
`c(2 arccos η) < 5.3331`, and it tends to 1 as `η → 1`: the owner's margin sets the cap. The same
question for the diameter, a cap below 3.1297 for each `η > 0`, is open.

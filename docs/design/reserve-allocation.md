# Using the paper's bound on a two-dimensional reserve

Status: **design note, not implemented.** Phase 4 ships `SelfApproaching` as a library with
tests and nothing calls it on-chain. This is where it would be used, and why it is not used
yet.

## Why not today

The protocol's monetary state is one number: the sUSD index. A self-approaching path on a line
is simply a monotone one, so `L = D` always and the planar theorems say nothing. The churn
budget borrows the constant `2 + π/3` by analogy and nothing more; `C_DIAM_WAD`'s NatSpec and
`docs/paper-map.md` say so.

## Where it would become real

The first genuinely two-dimensional state is a reserve split across two venues. Write the
allocation as a point

    v = (a₁, a₂)

where `a₁` is the share in vault 1 and `a₂` the share in vault 2, both in basis points of the
reserve, so idle funds are `10_000 − a₁ − a₂`. Each rebalancing moves the allocation from one
point to another, and the sequence of allocations in an epoch is a polygon `v₀, v₁, …, v_N`.

## The rule

In each epoch:

1. Start from `v₀`, the allocation at the epoch boundary.
2. Accept a proposed allocation `v_{k+1}` only if `SelfApproaching.canAppend(xs, ys, x, y)`
   holds (Lemma 7.1, `O(N)` in the number of moves so far).
3. At the end of the epoch, `SelfApproaching.lengthBound` gives the total distance moved and
   the diameter of the allocation set.

Then Lemma 2.1 and Theorem 4.3, both **proven**, give a hard cap on turnover:

    total distance moved ≤ 3.1356 × (largest distance from the epoch's starting allocation)

No keeper, however many times it rebalances, can move more than about 3.14 times the furthest
the allocation ever travels from where it started. A keeper that oscillates between two venues
to farm fees, or to walk the reserve somewhere in small steps nobody alarms on, is stopped by
the geometry rather than by a counter someone has to tune.

What the rule costs: a rebalancing that would reverse direction is refused until the epoch
rolls over. That is the intended behaviour — it is the oscillation the bound exists to stop —
but it means an epoch boundary must be short enough (a day, say) that a genuine change of plan
is never blocked for long, and the guardian's emergency exit must bypass the rule entirely.

## Honest comparison

A plain turnover cap ("at most X% of the reserve may move per epoch") is simpler, needs no
geometry, and stops the same oscillation. Its weakness is that X is a number someone picks:
too low and legitimate rebalancing stalls, too high and the oscillation fits underneath. The
self-approaching rule has no such parameter — the constant is proven, not chosen — and it
adapts automatically: an allocation that genuinely needs to travel far is allowed to, in
proportion.

Against that, the rule is novel, and novelty is its own risk in a contract that cannot be
upgraded. **Recommendation: implement the plain turnover cap first, run the geometric rule
alongside it in monitoring for one quarter, and only then consider enforcing it on-chain.**

## Threats

| Threat | Effect |
|---|---|
| Keeper oscillates between vaults to earn referral or entry fees | Bounded: the third reversal in an epoch is refused. |
| Keeper walks the reserve to one venue in many small steps | Bounded by the same inequality: many small steps still add up in `L`. |
| Attacker proposes an allocation that makes future legitimate moves infeasible | Possible. It is why the epoch must roll over regularly and why the guardian's exit ignores the rule. |
| Integer precision | None: the test is exact in integers for coordinates up to 2^125, and bps allocations are far below that. |

## Gas

Measured by `test/paper/SelfApproaching.t.sol::test_gas` on accepted polygons with `N` vertices
(memory arrays, so excluding the storage reads an on-chain allocation history would add):

| N | `canAppend` | `isSelfApproaching` | `diameterSqFromStart` | `lengthBound` |
|---|---|---|---|---|
| 8 | 12,824 | 31,427 | 10,644 | 28,073 |
| 16 | 23,844 | 117,109 | 21,028 | 56,342 |
| 32 | 47,184 | 475,680 | 41,798 | 114,534 |

`canAppend` is linear in the number of moves so far and the full check is quadratic, so an
on-chain rule must check each move incrementally and cap the number of rebalancings per epoch
(16 is plenty for a daily epoch).

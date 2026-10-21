"""Differential fixture: the paper's own reference code against SelfApproaching.sol.

Generates 1,000 integer polygons and records, for each, what the paper's code
(sa_fix/code/sapoly.py: pair_index, sa_residuals, length) says about it:

  accepted       min over 1 <= i < j <= N of (v_j - v_i).(v_i - v_{i-1}) >= 0  (Lemma 7.1)
  d2             max_j |v_j - v_0|^2                                         (Lemma 2.1)
  lengthRounded  round(sum of segment lengths)

Coordinates are integers in [-2^20, 2^20], so every product and sum the residuals need is
below 2^53 and the paper's float64 arithmetic is exact: the verdicts must agree with the
Solidity library on every polygon, borderline (zero-residual) cases included.

Usage (from the repo root):
    python3 test/paper/fixtures/gen_differential.py /path/to/sa_fix/code \
        > test/paper/fixtures/differential_1000.json
"""
import json
import math
import sys

import numpy as np

sys.path.insert(0, sys.argv[1])
from sapoly import length, pair_index, sa_residuals  # noqa: E402  (the paper's code)

LIM = 1 << 20
rng = np.random.default_rng(20261016)


def clip(V):
    return np.clip(np.rint(V), -LIM, LIM).astype(np.int64)


def walk(n, turn):
    ang = rng.uniform(0, 2 * np.pi)
    step = rng.uniform(2_000, 40_000)
    V = [np.zeros(2)]
    for _ in range(n - 1):
        ang += rng.uniform(-turn, turn)
        V.append(V[-1] + step * np.array([np.cos(ang), np.sin(ang)]))
    return clip(np.array(V))


def spiral(n, total, slack):
    th = total / n
    r = rng.uniform(200_000, 900_000)
    V = []
    for i in range(n):
        V.append(r * np.array([np.cos(i * th), np.sin(i * th)]))
        r *= np.cos(th) * (1 - slack)
    V.append(np.zeros(2))
    return clip(np.array(V))


def cloud(n):
    return rng.integers(-LIM // 2, LIM // 2, size=(n, 2)).astype(np.int64)


def with_repeats(V):
    # repeat one vertex: a zero-length segment, which Lemma 7.1 treats as a no-op
    k = int(rng.integers(0, len(V)))
    return np.insert(V, k, V[k], axis=0)


def collinear(n):
    d = rng.integers(-3, 4, size=2)
    if not d.any():
        d = np.array([1, 0])
    t = np.sort(rng.integers(0, 200_000, size=n))
    if rng.random() < 0.5:
        k = int(rng.integers(1, n))
        t[k] = t[k - 1] - int(rng.integers(1, 50))  # one step backwards along the line
    return (np.outer(t, d)).astype(np.int64)


polys = []
kinds = []
while len(polys) < 1000:
    k = len(polys) % 8
    n = int(rng.integers(3, 25))
    if k == 0:
        V, kind = walk(n, rng.uniform(0.01, 0.4)), "walk"
    elif k == 1:
        V, kind = walk(n, rng.uniform(0.4, 1.6)), "wild walk"
    elif k == 2:
        V, kind = spiral(n, rng.uniform(0.2, 2.9), 1e-3), "spiral"
    elif k == 3:
        V, kind = spiral(n, rng.uniform(0.2, 2.9), 0.0), "spiral at the foot points"
    elif k == 4:
        V, kind = spiral(n, rng.uniform(3.2, 6.0), 1e-3), "spiral past pi"
    elif k == 5:
        V, kind = cloud(n), "cloud"
    elif k == 6:
        V, kind = with_repeats(walk(n, rng.uniform(0.01, 0.3))), "walk with a repeat"
    else:
        V, kind = collinear(n), "collinear"
    if len(V) > 26:
        continue
    polys.append(V)
    kinds.append(kind)

offsets, xs, ys, accepted, d2, lengths = [0], [], [], [], [], []
for V in polys:
    Vf = V.astype(np.float64)
    N = len(V) - 1
    I, J = pair_index(N)
    res = sa_residuals(Vf, I, J)
    accepted.append(bool(res.min() >= 0) if len(res) else True)
    d2.append(int(max(int((x - V[0][0]) ** 2 + (y - V[0][1]) ** 2) for x, y in V)))
    lengths.append(int(round(length(Vf))))
    xs.extend(int(x) for x in V[:, 0])
    ys.extend(int(y) for y in V[:, 1])
    offsets.append(len(xs))

# Exactness check of the float64 claim: recompute the verdicts in Python integers.
for p, V in enumerate(polys):
    exact = all(
        (int(V[j][0]) - int(V[i][0])) * (int(V[i][0]) - int(V[i - 1][0]))
        + (int(V[j][1]) - int(V[i][1])) * (int(V[i][1]) - int(V[i - 1][1]))
        >= 0
        for i in range(1, len(V))
        for j in range(i + 1, len(V))
    )
    assert exact == accepted[p], p

summary = {}
for kind, ok in zip(kinds, accepted):
    a, r = summary.get(kind, (0, 0))
    summary[kind] = (a + ok, r + (not ok))

json.dump(
    {
        "source": "sa_fix/code/sapoly.py (pair_index, sa_residuals, length), seed 20261016",
        "count": len(polys),
        "acceptedCount": sum(accepted),
        "byKind": {k: {"accepted": a, "rejected": r} for k, (a, r) in sorted(summary.items())},
        "offsets": offsets,
        "xs": xs,
        "ys": ys,
        "accepted": accepted,
        "d2": [str(v) for v in d2],
        "lengthRounded": lengths,
    },
    sys.stdout,
)

"""Lemma 5.1 fixture: sampled cycloidal cascades, from the paper's own code.

Uses sa_fix/code/cascade.py (cascade_canonical) with w = 1, r = w / (2n): n half-cycloid
pieces, m samples per piece. The cascade itself is self-approaching, has length 2w and stays
in the strip pi*r <= x <= 2*pi*r, of width pi*w/(2n), beside its base segment x = pi*r.

Coordinates are value * 1e18, rounded to integers, as decimal strings.

Usage (from the repo root):
    python3 test/paper/fixtures/gen_cascade.py /path/to/sa_fix/code \
        > test/paper/fixtures/cascade_lemma51.json
"""
import json
import sys
from decimal import Decimal, getcontext

sys.path.insert(0, sys.argv[1])
from cascade import cascade_canonical  # noqa: E402  (the paper's code)

getcontext().prec = 50
SCALE = Decimal(10) ** 18

polys = []
for n in (2, 4, 8):
    for m in (3, 5, 9, 17):
        r = 1.0 / (2 * n)
        P, L = cascade_canonical(n, r, m)
        xs = [str(int((Decimal(repr(float(x))) * SCALE).to_integral_value())) for x, _ in P]
        ys = [str(int((Decimal(repr(float(y))) * SCALE).to_integral_value())) for _, y in P]
        polys.append({"pieces": n, "samplesPerPiece": m, "curveLength": repr(L), "xs": xs, "ys": ys})

json.dump(
    {
        "source": "sa_fix/code/cascade.py (cascade_canonical), w = 1, r = 1/(2n)",
        "count": len(polys),
        "polygons": polys,
    },
    sys.stdout,
)

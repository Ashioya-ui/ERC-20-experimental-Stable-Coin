#!/usr/bin/env python3
"""The leash's move rule in exact integers, line for line with Leash.check and
SelfApproaching.canAppendWithMargin / lengthBound. It prints every decision of the live Base
Sepolia run; script/leash/live.mjs asserts that the chain makes the same ones."""
import math

BPS, MAX_POINTS = 10_000, 32
C_SA_UPPER_WAD = 3_129_671_282_803_278_542


def ahead(path, x, y, en, ed):
    """Every earlier segment sees (x, y) ahead of it with margin en/ed."""
    for (x0, y0), (x1, y1) in zip(path, path[1:]):
        bx, by, ax, ay = x1 - x0, y1 - y0, x - x1, y - y1
        dot = ax * bx + ay * by
        if dot < 0:
            return False
        a2 = ax * ax + ay * ay
        if a2 and (dot * dot * ed * ed) // a2 < en * en * (bx * bx + by * by):
            return False
    return True


def check(path, a, b, end, eta):
    if a + b > BPS:
        return 'BadAllocation'
    if len(path) >= MAX_POINTS:
        return 'PathFull'
    if (a, b) == path[-1]:
        return 'SamePoint'
    if not ahead(path, a, b, *eta):
        return 'NotApproaching'
    if not ahead(path + [(a, b)], *end, *eta):
        return 'EndUnreachable'
    return 'ok'


def length_bound(path):
    up = sum(math.isqrt((x1 - x0) ** 2 + (y1 - y0) ** 2 - 1) + 1 if (x1, y1) != (x0, y0) else 0
             for (x0, y0), (x1, y1) in zip(path, path[1:]))
    d2 = max(((x - path[0][0]) ** 2 + (y - path[0][1]) ** 2 for x, y in path), default=0)
    down = math.isqrt(d2)
    return up, down, up * 10**18 <= C_SA_UPPER_WAD * down


# (label, start, end, eta, steps); a step is (kind, a, b, expected): 'move' sends, 'check' must refuse.
SCENARIOS = [
    ('any two ERC-4626 vaults', (0, 0), (6000, 3000), (1, 10), [
        ('check', 7000, 3001, 'BadAllocation'),
        ('move', 3000, 1500, 'ok'),
        ('move', 4500, 1500, 'ok'),
        ('check', 2000, 1000, 'NotApproaching'),
        ('check', 7000, 3000, 'EndUnreachable'),
        ('move', 6000, 3000, 'ok'),
        ('check', 5000, 3000, 'NotApproaching'),
    ]),
    ("sUSD's reserve", (0, 0), (5000, 5000), (1, 10), [
        ('move', 2500, 2500, 'ok'),
        ('check', 1000, 4000, 'NotApproaching'),
        ('move', 5000, 5000, 'ok'),
    ]),
]

if __name__ == '__main__':
    for label, start, end, eta, steps in SCENARIOS:
        path = [start]
        print(f'{label}: start {start}, end {end}, margin {eta[0]}/{eta[1]}')
        for kind, a, b, want in steps:
            got = check(path, a, b, end, eta)
            assert got == want, (label, kind, a, b, got, want)
            if kind == 'move':
                path.append((a, b))
            print(f'  {kind} ({a}, {b}): {got}')
        up, down, ok = length_bound(path)
        dist_end = math.isqrt((end[0] - start[0]) ** 2 + (end[1] - start[1]) ** 2)
        print(f'  path {path}; length <= {up}, diameter >= {down}, length <= 3.1297 x diameter: {ok}; start-to-end {dist_end}')

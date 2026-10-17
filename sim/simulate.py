"""Spectrum parameter simulation (Phase 4, B8).

An hourly model of one year after launch, using the stabilizer's policy curves
(src/libraries/SpectralPolicy.sol), the rebase rule with protocol capital, loss absorption
and the churn budget. Python 3.11+, standard library only.

    python3 sim/simulate.py            # writes sim/results.csv and prints the summary tables

Model (deliberately simple, every assumption stated):
- Launch: supply ramps linearly from 0 to the 25,000 sUSD supply cap over the first 30 days.
  After that the cap binds, and holders turn over `turnover` of supply per day (redeem and
  re-mint), paying both fees.
- Reserve: `idle` of it sits idle at 0%, the rest earns `apy`, compounded hourly.
- Loss: one realised vault loss of `loss` of the reserve on day 90 (or none).
- Rebase: one attempt per hour. Supply may rise to min(reserve / (1 + buffer(H)),
  reserve - protocolCapital), by at most stepRate(H) of supply per hour, and positive moves
  respect the churn budget (L <= C_DIAM * D in a 7-day window).
- Loss absorption: whenever reserve < supply, the index drops so that supply = reserve.
- H: constant 0, 0.5 or 1, or "adversarial": the buffer and step of H = 1 (slowest
  distribution) with the fees of H = 0 (least fee income), the worst of both for holders.
"""
import csv
import itertools
import math
import os

WAD = 10**18
HOURS = 24 * 365
CAP = 25_000.0
RAMP_DAYS = 30
LOSS_DAY = 90
C_DIAM = 2 + math.pi / 3
CHURN_WINDOW_H = 7 * 24

# src/libraries/SpectralPolicy.sol (rates as fractions)
MINT_FEE_MIN, MINT_FEE_MAX = 0.0001, 0.0025
REDEEM_FEE_MIN, REDEEM_FEE_MAX = 0.0001, 0.0010
BUFFER_LOW, BUFFER_HIGH = 0.0275, 0.05
STEP_MAX = 0.0001


def mint_fee(h):
    return MINT_FEE_MIN + (MINT_FEE_MAX - MINT_FEE_MIN) * h * h


def redeem_fee(h):
    return REDEEM_FEE_MIN + (REDEEM_FEE_MAX - REDEEM_FEE_MIN) * h * h


def buffer_rate(h):
    return BUFFER_LOW if h <= 0.5 else BUFFER_LOW + (BUFFER_HIGH - BUFFER_LOW) * 2 * (h - 0.5)


def step_rate(h):
    return STEP_MAX - STEP_MAX * h / 2


def run(apy, idle, h_mode, loss, capital_frac, turnover):
    """One scenario; returns a dict of results."""
    if h_mode == "adversarial":
        h_fee, h_dist = 0.0, 1.0
    else:
        h_fee = h_dist = float(h_mode)
    hourly = (1 + apy) ** (1 / HOURS) - 1

    capital = capital_frac * CAP
    reserve = capital  # contributed at deployment, before any mint
    supply = 0.0
    index = 1.0
    first_dist_h = None
    neg_rebases = []
    distributed = 0.0
    deferred = 0
    # churn window over the index path
    w_start, w_len, w_max, w_min = 0, 0.0, 1.0, 1.0

    def churn_ok(old, new, t):
        nonlocal w_start, w_len, w_max, w_min
        if t - w_start >= CHURN_WINDOW_H:
            ln, mx, mn = 0.0, old, old
        else:
            ln, mx, mn = w_len, w_max, w_min
        ln += abs(new - old)
        mx, mn = max(mx, new), min(mn, new)
        return ln <= C_DIAM * (mx - mn) + 1e-15, ln, mx, mn

    def commit(old, new, t):
        nonlocal w_start, w_len, w_max, w_min
        if t - w_start >= CHURN_WINDOW_H:
            w_start, w_len, w_max, w_min = t, 0.0, old, old
        w_len += abs(new - old)
        w_max, w_min = max(w_max, new), min(w_min, new)

    for t in range(HOURS):
        day = t / 24
        # 1. yield on the invested part
        reserve += reserve * (1 - idle) * hourly
        # 2. flows
        if day < RAMP_DAYS:
            m = CAP / (RAMP_DAYS * 24)
            reserve += m
            supply += m * (1 - mint_fee(h_fee))
        else:
            turn = supply * turnover / 24
            reserve -= turn * (1 - redeem_fee(h_fee))  # redeem
            supply -= turn
            reserve += turn  # re-mint the same USDC
            supply += turn * (1 - mint_fee(h_fee))
        # 3. loss event
        if loss and t == LOSS_DAY * 24:
            reserve -= loss * reserve
        # 4. loss absorption (sync runs first in every action)
        if reserve < supply:
            new_index = index * reserve / supply
            neg_rebases.append(1 - reserve / supply)
            commit(index, new_index, t)
            index, supply = new_index, reserve
        # 5. hourly rebase
        max_supply = min(reserve / (1 + buffer_rate(h_dist)), max(reserve - capital, 0.0))
        if supply > 0 and max_supply > supply:
            step = min(max_supply - supply, supply * step_rate(h_dist))
            new_index = index * (1 + step / supply)
            ok, *_ = churn_ok(index, new_index, t)
            if ok:
                commit(index, new_index, t)
                index, supply = new_index, supply + step
                distributed += step
                if first_dist_h is None:
                    first_dist_h = t
            else:
                deferred += 1

    return {
        "apy": apy,
        "idle": idle,
        "h": h_mode,
        "loss": loss,
        "capital_pct_of_cap": capital_frac * 100,
        "turnover_per_day": turnover,
        "days_to_first_distribution": None if first_dist_h is None else round(first_dist_h / 24, 1),
        "holder_return_12m_pct": round((index - 1) * 100, 3),
        "negative_rebases": len(neg_rebases),
        "largest_negative_rebase_pct": round(max(neg_rebases) * 100, 3) if neg_rebases else 0.0,
        "distributed_sUSD": round(distributed, 2),
        "deferred_by_churn": deferred,
        "surplus_end_sUSD": round(reserve - supply, 2),
    }


def main():
    rows = []
    grid = itertools.product(
        [0.02, 0.04, 0.06],  # vault APY
        [0.10, 0.15, 0.20],  # idle buffer
        ["0", "0.5", "1", "adversarial"],
        [0.0, 0.005, 0.02],  # loss on day 90
        [0.0, 0.05],  # protocol capital as a fraction of the cap
        [0.0, 0.02],  # daily turnover after the ramp
    )
    for apy, idle, h, loss, cap, turn in grid:
        rows.append(run(apy, idle, h, loss, cap, turn))

    out = os.path.join(os.path.dirname(__file__), "results.csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    def pick(**kw):
        for r in rows:
            if all(r[k] == v for k, v in kw.items()):
                return r
        raise KeyError(kw)

    print(f"{len(rows)} scenarios -> {out}\n")
    print("Days to the first distribution and 12-month holder return (no loss, no turnover):")
    print("APY  idle  H            capital 0%                 capital 5% of cap")
    for apy in [0.02, 0.04, 0.06]:
        for idle in [0.10, 0.15, 0.20]:
            for h in ["0.5", "adversarial"]:
                a = pick(apy=apy, idle=idle, h=h, loss=0.0, capital_pct_of_cap=0.0, turnover_per_day=0.0)
                b = pick(apy=apy, idle=idle, h=h, loss=0.0, capital_pct_of_cap=5.0, turnover_per_day=0.0)
                print(
                    f"{apy:.0%}   {idle:.0%}   {h:<11}  "
                    f"day {a['days_to_first_distribution']!s:>6}, {a['holder_return_12m_pct']:6.3f}%    "
                    f"day {b['days_to_first_distribution']!s:>6}, {b['holder_return_12m_pct']:6.3f}%"
                )
    print("\nLoss on day 90 (APY 4%, idle 15%, neutral H, no turnover):")
    for loss in [0.005, 0.02]:
        for cap in [0.0, 5.0]:
            r = pick(apy=0.04, idle=0.15, h="0.5", loss=loss, capital_pct_of_cap=cap, turnover_per_day=0.0)
            print(
                f"loss {loss:.1%}, capital {cap:.0f}%: negative rebases {r['negative_rebases']}, "
                f"largest {r['largest_negative_rebase_pct']}%, 12-month return {r['holder_return_12m_pct']}%"
            )


if __name__ == "__main__":
    main()

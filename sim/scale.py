"""Spectrum at neobank scale (Phase 5): EtherFi-sized numbers through the protocol's rules.

An hourly model of one year with a $300m reserve: card-spend redemptions, top-up mints, vault
yield, hourly rebases, a keeper that keeps the idle buffer on target, and stress events (a
realised vault loss, a run, a frozen vault). It applies the stabilizer's policy curves
(src/libraries/SpectralPolicy.sol), its expansion cap and rebase rule, and the treasury's
payout order (src/AutonomousTreasury.sol: idle first, then the vault within what it can pay,
all or nothing). Python 3.11+, standard library only, deterministic.

    python3 sim/scale.py              # prints the tables in REPORT_SCALE.md, writes sim/scale.csv

Inputs from the public EtherFi figures this review starts from: about $300m of stablecoin
deposits, about $1bn of cumulative card spend since the 2024 launch, more than 100,000 active
cards. Everything else is an assumption, stated next to its constant.

The vault's market is modelled as a pool of `market` dollars of which `1 - util` is unborrowed
and can be withdrawn. Withdrawals use it up; it recovers toward its normal level by
`RECOVERY_PER_DAY` of the market a day, which is how lending markets answer a spike in
utilisation (rates jump, borrowers repay, lenders arrive). Left out: gas, MEV, the wsUSD pool,
changing APYs, and correlations beyond the named events.
"""
import csv
import math
import os
import random

HOURS = 24 * 365
DAY = 24

# --- src/libraries/SpectralPolicy.sol (fractions) -------------------------------------------
MINT_FEE_MIN, MINT_FEE_MAX = 0.0001, 0.0025
REDEEM_FEE_MIN, REDEEM_FEE_MAX = 0.0001, 0.0010
EXP_NEUTRAL, EXP_HIGH = 0.11, 0.02  # Phase 5 (P5-01): flat at 11% up to h = 0.5
EXP_LOW_FREEZE1 = 0.20  # audit-freeze-1: the line went on up to 20% at h = 0
BUFFER_LOW, BUFFER_HIGH = 0.0275, 0.05
STEP_MAX = 0.0001
C_BUDGET = 5 * math.pi / 6 + 2 * math.sin(math.pi / 12)  # Theorem 4.3, 3.1356...
CHURN_WINDOW_H = 7 * 24
REBALANCE_TOL = 0.01  # AutonomousTreasury.REBALANCE_TOLERANCE_BPS = 100
BOOTSTRAP_CAP = 10_000.0  # config/8453.json bootstrapCapSUSD

# --- assumptions ------------------------------------------------------------------------------
RESERVE0 = 300e6  # $300m of deposits at day 0 (how fast they can arrive is table 6)
RECOVERY_PER_DAY = 0.01  # unborrowed liquidity returns at 1% of the market a day after a spike
WEEKDAY = [1.00, 1.00, 1.00, 1.05, 1.20, 1.35, 0.90]  # card spend by weekday


def mint_fee(h):
    return MINT_FEE_MIN + (MINT_FEE_MAX - MINT_FEE_MIN) * h * h


def redeem_fee(h):
    return REDEEM_FEE_MIN + (REDEEM_FEE_MAX - REDEEM_FEE_MIN) * h * h


def exp_rate(h):
    """Expansion cap rate since Phase 5 (P5-01): H may tighten it, never loosen it past neutral."""
    return EXP_NEUTRAL if h <= 0.5 else EXP_NEUTRAL - (EXP_NEUTRAL - EXP_HIGH) * 2 * (h - 0.5)


def exp_rate_freeze1(h):
    """Expansion cap rate at audit-freeze-1: 20% at h = 0 down to 2% at h = 1."""
    return EXP_LOW_FREEZE1 - (EXP_LOW_FREEZE1 - EXP_HIGH) * h


def buffer_rate(h):
    return BUFFER_LOW if h <= 0.5 else BUFFER_LOW + (BUFFER_HIGH - BUFFER_LOW) * 2 * (h - 0.5)


def step_rate(h):
    return STEP_MAX - STEP_MAX * h / 2


class Scenario:
    def __init__(self, **kw):
        self.apy = 0.05  # vault APY
        self.idle = 0.15  # liquidityBufferBps / 10_000 (config/8453.json: 1500)
        self.capital = 1_250.0  # protocol capital, USD (config/8453.json: seedCapitalUSDC)
        self.spend = 600e6  # card spend a year (assumption: today's run rate behind $1bn cumulative)
        self.topup = 1.0  # mints as a multiple of redemptions (1.0 = deposits stay flat)
        self.h_fee = 0.5  # H seen by the fee curves and the expansion cap
        self.h_dist = 0.5  # H seen by the buffer and the rebase step
        self.market = 1_000e6  # the vault's market, total supplied (assumption)
        self.util = 0.85  # its normal utilisation (assumption)
        self.loss = 0.0  # realised vault loss, fraction of the vault position
        self.loss_day = 90
        self.crunch = None  # (start_day, days): the vault pays nothing (utilisation 100%)
        self.run = None  # (day, fraction of supply that asks to exit that day)
        self.seed = 7
        self.__dict__.update(kw)


def simulate(sc):
    rng = random.Random(sc.seed)
    hourly = (1 + sc.apy) ** (1 / HOURS) - 1
    supply = RESERVE0
    capital = sc.capital
    reserve = RESERVE0 + capital
    idle = reserve * sc.idle
    vault = reserve - idle
    index = 1.0
    normal_free = sc.market * (1 - sc.util)
    free = normal_free
    w_start, w_len, w_max, w_min = 0, 0.0, 1.0, 1.0

    out = dict(
        fees=0.0, idle_drag=0.0, distributed=0.0, first_dist_h=None, unserved=0.0,
        min_liquid_ratio=float("inf"), vault_withdrawals=0, neg_rebases=0, worst_neg=0.0,
        run_served_day1=None, run_days_to_clear=None, deferred=0, capped_mint=0.0,
    )
    run_total = run_left = 0.0
    run_start = None

    def frozen(t):
        return bool(sc.crunch) and sc.crunch[0] * DAY <= t < (sc.crunch[0] + sc.crunch[1]) * DAY

    def vault_payable(t):
        return 0.0 if frozen(t) else max(0.0, min(vault, free))

    def take(amount, t):
        """Move `amount` out of the reserve: idle first, then the vault. Caller checked it fits."""
        nonlocal idle, vault, reserve, free
        if amount > idle:
            need = amount - idle
            vault -= need
            free -= need
            idle = 0.0
            out["vault_withdrawals"] += 1
        else:
            idle -= amount
        reserve -= amount

    epoch_supply = supply
    minted_in_epoch = 0.0
    day_spend = 0.0
    for t in range(HOURS):
        day = t // DAY
        if t % DAY == 0:
            epoch_supply, minted_in_epoch = supply, 0.0
            base = sc.spend / 365 * WEEKDAY[day % 7] / (sum(WEEKDAY) / 7)
            day_spend = base * (0.8 + 0.4 * rng.random())
            if not frozen(t):  # the market recovers toward normal
                free = min(normal_free, free + RECOVERY_PER_DAY * sc.market)
        # 1. yield on the vault position; the idle part earns nothing
        y = vault * hourly
        vault += y
        reserve += y
        out["idle_drag"] += idle * hourly
        hf = sc.h_fee
        # 2. card spend: the hour's slice is redeemed to settle (all or nothing per redemption)
        a = day_spend / DAY
        assets = a * (1 - redeem_fee(hf))
        if assets <= idle + vault_payable(t):
            take(assets, t)
            supply -= a
            out["fees"] += a - assets
            minted_in_epoch = max(0.0, minted_in_epoch - a)
        else:
            out["unserved"] += a
        #    top-ups mint sUSD, under the daily expansion cap (net of redemptions)
        m = a * sc.topup
        mint_out = m * (1 - mint_fee(hf))
        cap = max(BOOTSTRAP_CAP, epoch_supply * exp_rate(hf))
        if minted_in_epoch + mint_out <= cap:
            minted_in_epoch += mint_out
            supply += mint_out
            idle += m
            reserve += m
            out["fees"] += m - mint_out
        else:
            out["capped_mint"] += m
        # 3. a run: exits sized to what is liquid each hour (integrators read liquidAssets)
        if sc.run and t == sc.run[0] * DAY:
            run_total = run_left = supply * sc.run[1]
            run_start = t
        if run_left > 0:
            liquid = idle + vault_payable(t)
            pay = min(run_left * (1 - redeem_fee(hf)), liquid)
            if pay > 0:
                burned = pay / (1 - redeem_fee(hf))
                take(pay, t)
                supply -= burned
                run_left -= burned
                out["fees"] += burned - pay
            if run_left <= 1e-6 * run_total:
                run_left = 0.0
                if out["run_days_to_clear"] is None:
                    out["run_days_to_clear"] = (t - run_start + 1) / DAY
        if run_start is not None and t == run_start + DAY - 1:
            out["run_served_day1"] = 1 - run_left / run_total
        # 4. a realised vault loss
        if sc.loss and t == sc.loss_day * DAY:
            lost = vault * sc.loss
            vault -= lost
            reserve -= lost
        # 5. loss absorption (sync runs first in every action)
        if reserve < supply:
            new_index = index * reserve / supply
            out["neg_rebases"] += 1
            out["worst_neg"] = max(out["worst_neg"], 1 - reserve / supply)
            if t - w_start >= CHURN_WINDOW_H:
                w_start, w_len, w_max, w_min = t, 0.0, index, index
            w_len += abs(new_index - index)
            w_max, w_min = max(w_max, new_index), min(w_min, new_index)
            index, supply = new_index, reserve
        # 6. keeper: rebalanceReserve toward the idle target (tolerance 1% of the reserve)
        target = reserve * sc.idle
        tol = reserve * REBALANCE_TOL
        if idle > target + tol:
            dep = idle - target
            vault += dep
            free += dep
            idle = target
        elif idle + tol < target:
            amt = min(target - idle, vault_payable(t))
            if amt > 0:
                vault -= amt
                free -= amt
                idle += amt
                out["vault_withdrawals"] += 1
        # 7. hourly rebase
        hd = sc.h_dist
        max_supply = min(reserve / (1 + buffer_rate(hd)), max(reserve - capital, 0.0))
        if supply > 0 and max_supply > supply:
            step = min(max_supply - supply, supply * step_rate(hd))
            new_index = index * (1 + step / supply)
            if t - w_start >= CHURN_WINDOW_H:
                ln, mx, mn = 0.0, index, index
            else:
                ln, mx, mn = w_len, w_max, w_min
            ln += abs(new_index - index)
            mx, mn = max(mx, new_index), min(mn, new_index)
            if ln <= C_BUDGET * (mx - mn) + 1e-15:
                if t - w_start >= CHURN_WINDOW_H:
                    w_start = t
                w_len, w_max, w_min = ln, mx, mn
                index, supply = new_index, supply + step
                out["distributed"] += step
                if out["first_dist_h"] is None:
                    out["first_dist_h"] = t
            else:
                out["deferred"] += 1
        out["min_liquid_ratio"] = min(out["min_liquid_ratio"], (idle + vault_payable(t)) / max(supply, 1.0))

    out.update(
        holder_return_pct=round((index - 1) * 100, 3),
        days_to_first_distribution=None if out["first_dist_h"] is None else round(out["first_dist_h"] / DAY, 1),
        surplus_end=round(reserve - supply, 0),
        supply_end=round(supply, 0),
    )
    return out


def onboarding_days(target, h, rule=exp_rate, bootstrap=BOOTSTRAP_CAP):
    """Days of maximal net minting needed to reach `target` supply from zero."""
    s, d = 0.0, 0
    while s < target:
        s += max(bootstrap, s * rule(h))
        d += 1
    return d


def exit_capacity(idle, market, util, position):
    """Same-day exit capacity as a share of supply: idle + what the vault's market can pay."""
    vault_pos = position * (1 - idle)
    return (position * idle + min(vault_pos, market * (1 - util))) / position


def m(x):
    return f"${x:,.0f}" if x < 1e6 else f"${x / 1e6:,.2f}m"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rows = []

    print("## 1. A year at $300m (APY 5%, card spend $600m a year, flat deposits, neutral H)\n")
    print("| Idle | Protocol capital | First distribution | Holder return, 12 months | "
          "Yield lost to idle | Fees to the reserve | Lowest same-day liquidity |")
    print("|---|---|---|---|---|---|---|")
    for idle in (0.05, 0.10, 0.15):
        for cap in (1_250.0, 3e6, 8.25e6):
            r = simulate(Scenario(idle=idle, capital=cap))
            rows.append(dict(table="year", idle=idle, capital=cap, **r))
            first = "not in year one" if r["days_to_first_distribution"] is None else f"day {r['days_to_first_distribution']:.0f}"
            print(f"| {idle:.0%} | {m(cap)} | {first} | {r['holder_return_pct']:.2f}% | "
                  f"{m(r['idle_drag'])} | {m(r['fees'])} | {r['min_liquid_ratio']:.1%} of supply |")

    print("\n## 2. Card spend and H (idle 10%, capital $8.25m, APY 5%)\n")
    print("| Card spend a year | H | Holder return | Fees to the reserve | Unserved card redemptions | "
          "Top-ups refused by the cap |")
    print("|---|---|---|---|---|---|")
    for spend in (300e6, 600e6, 1_000e6):
        for label, hf, hd in (("neutral 0.5", 0.5, 0.5), ("steered to 0.05", 0.05, 0.05),
                              ("steered to 1", 1.0, 1.0), ("worst for holders", 0.0, 1.0)):
            r = simulate(Scenario(idle=0.10, capital=8.25e6, spend=spend, h_fee=hf, h_dist=hd))
            rows.append(dict(table="spend", spend=spend, h=label, **r))
            print(f"| {m(spend)} | {label} | {r['holder_return_pct']:.2f}% | {m(r['fees'])} | "
                  f"{m(r['unserved'])} | {m(r['capped_mint'])} |")
    print("\nWith capital at 5% of supply ($15m), H held at 1 all year no longer holds back yield:\n")
    print("| Card spend a year | H | Capital | Holder return |")
    print("|---|---|---|---|")
    for label, hf, hd in (("neutral 0.5", 0.5, 0.5), ("steered to 1", 1.0, 1.0), ("worst for holders", 0.0, 1.0)):
        for cap in (8.25e6, 15e6):
            r = simulate(Scenario(idle=0.10, capital=cap, h_fee=hf, h_dist=hd))
            rows.append(dict(table="griefing", capital=cap, h=label, **r))
            print(f"| $600.00m | {label} | {m(cap)} | {r['holder_return_pct']:.2f}% |")

    print("\n## 3. A realised vault loss on day 90 (idle 10%, APY 5%, neutral H)\n")
    print("| Loss of the vault position | Capital $1,250: largest cut to balances | "
          "Capital $8.25m: largest cut | Capital $8.25m: 12-month return |")
    print("|---|---|---|---|")
    for loss in (0.01, 0.03, 0.05, 0.10):
        a = simulate(Scenario(idle=0.10, capital=1_250.0, loss=loss))
        b = simulate(Scenario(idle=0.10, capital=8.25e6, loss=loss))
        rows.append(dict(table="loss", loss=loss, capital=1_250.0, **a))
        rows.append(dict(table="loss", loss=loss, capital=8.25e6, **b))
        la = f"{a['worst_neg']:.2%}" if a["neg_rebases"] else "none"
        lb = f"{b['worst_neg']:.2%}" if b["neg_rebases"] else "none"
        print(f"| {loss:.0%} (about {m(loss * RESERVE0 * 0.9)}) | {la} | {lb} | {b['holder_return_pct']:.2f}% |")

    print("\n## 4. A run and a frozen vault (APY 5%, capital $8.25m, vault market $1bn)\n")
    print("| Event | Idle | Utilisation | Run served in 24 h | Days to clear | Card redemptions unserved |")
    print("|---|---|---|---|---|---|")
    for label, kw in (("30% of supply asks to exit on day 200", dict(run=(200, 0.30))),
                      ("vault pays nothing for 7 days from day 120", dict(crunch=(120, 7)))):
        for idle in (0.05, 0.10, 0.15):
            for util in (0.85, 0.95):
                r = simulate(Scenario(idle=idle, capital=8.25e6, util=util, **kw))
                rows.append(dict(table="run", idle=idle, util=util, event=label, **r))
                served = "—" if r["run_served_day1"] is None else f"{r['run_served_day1']:.0%}"
                d = r["run_days_to_clear"]
                clear = "—" if d is None else ("within the hour" if d <= 1 / 24 else f"{d:.1f}")
                print(f"| {label} | {idle:.0%} | {util:.0%} | {served} | {clear} | {m(r['unserved'])} |")

    print("\n## 5. Same-day exit capacity at $300m, share of supply (vault market utilisation 90%)\n")
    print("| Idle | Market $500m | Market $1bn | Market $2bn |")
    print("|---|---|---|---|")
    for idle in (0.05, 0.10, 0.15, 0.25):
        cells = [f"{exit_capacity(idle, mk, 0.90, RESERVE0):.1%}" for mk in (500e6, 1_000e6, 2_000e6)]
        print(f"| {idle:.0%} | " + " | ".join(cells) + " |")

    print("\n## 6. Onboarding: days of maximal net minting from launch to $300m\n")
    print("| H | audit-freeze-1 (20% → 2%) | Phase 5 (11%, H only tightens) |")
    print("|---|---|---|")
    for h in (0.0, 0.05, 0.5, 1.0):
        print(f"| {h} | {onboarding_days(RESERVE0, h, exp_rate_freeze1)} | {onboarding_days(RESERVE0, h)} |")

    print("\n## 7. What steering H down is worth at $300m (one day of maximal minting)\n")
    print("| | Neutral H = 0.5 | Steered H = 0.05 |")
    print("|---|---|---|")
    cap_n, cap_l = exp_rate(0.5) * RESERVE0, exp_rate_freeze1(0.05) * RESERVE0
    print(f"| Net minting allowed that day | {m(cap_n)} | {m(cap_l)} at audit-freeze-1; {m(exp_rate(0.05) * RESERVE0)} since P5-01 |")
    print(f"| Mint fee | {mint_fee(0.5) * 1e4:.2f} bp | {mint_fee(0.05) * 1e4:.2f} bp |")
    print(f"| Fee saved on {m(cap_n)} | — | {m((mint_fee(0.5) - mint_fee(0.05)) * cap_n)} |")

    with open(os.path.join(here, "scale.csv"), "w", newline="") as f:
        keys = sorted({k for r in rows for k in r})
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)


if __name__ == "__main__":
    main()

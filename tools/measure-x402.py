#!/usr/bin/env python3
"""Who holds the money in x402 on Base mainnet: the wallets that pay, or the wallets that get paid?

Public chain data only. Nothing is signed and nothing is sent.

Population. x402's "exact" scheme settles USDC with EIP-3009 transferWithAuthorization, which
emits AuthorizationUsed(authorizer, nonce) on the USDC contract. Those events are sampled across
the last WINDOW_DAYS days. A random sample of their receipts then shows who submitted each one
(the facilitators) and who was paid (the merchants), so the population is checked against x402
instead of assumed to be x402.

Measured, for payers and merchants alike: USDC held now, plus any USDC already parked in Aave
(aBasUSDC, waBasUSDC); distribution, concentration, the share that are contracts. And Aave's live
USDC supply rate on Base, read from the pool, which prices the idle balance.

Output: a JSON file and a plain-text report, both with every figure labelled measured or sampled.
"""
import json
import os
import random
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

RPCS = [u for u in os.environ.get("RPCS", "https://mainnet.base.org,https://base-rpc.publicnode.com").split(",") if u]
USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
WA_BAS_USDC = "0xc768c589647798a6ee01a91fde98ef2ed046dbd6"
WINDOW_DAYS = int(os.environ.get("WINDOW_DAYS", "7"))
SEGMENTS = int(os.environ.get("SEGMENTS", "48"))
SEGMENT_BLOCKS = int(os.environ.get("SEGMENT_BLOCKS", "300"))
RECEIPTS = int(os.environ.get("RECEIPTS", "1500"))
MAX_WALLETS = int(os.environ.get("MAX_WALLETS", "8000"))
MULTICALL3 = "0xca11bde05977b3631167028862be2a173976ca11"
BLOCKS_PER_DAY = 43_200  # Base: 2-second blocks
random.seed(int(os.environ.get("SEED", "8453")))

UA = {"content-type": "application/json", "accept": "application/json",
      "user-agent": "Mozilla/5.0 (compatible; spectrum-x402-measure/1.0)"}


def sh(*args):
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True).stdout.strip()


TOPIC_AUTH_USED = sh("keccak", "AuthorizationUsed(address,bytes32)")
TOPIC_TRANSFER = sh("keccak", "Transfer(address,address,uint256)")
SEL_BALANCE = sh("sig", "balanceOf(address)")
SEL_ATOKEN = sh("sig", "aToken()")
SEL_POOL = sh("sig", "POOL()")
SEL_RESERVE = sh("sig", "getReserveData(address)")

_n = 0


def _post(url, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def rpc(method, params):
    """One call, retried with backoff across endpoints: public endpoints rate-limit."""
    global _n
    last = None
    for attempt in range(8):
        url = RPCS[attempt % len(RPCS)]
        _n += 1
        try:
            out = _post(url, {"jsonrpc": "2.0", "id": _n, "method": method, "params": params})
            if "error" in out:
                last = RuntimeError(f"{url}: {out['error']}")
                if "limit" in str(out["error"]).lower() or "too many" in str(out["error"]).lower():
                    time.sleep(0.5 * 2 ** attempt)
                    continue
                raise last
            return out["result"]
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last = e
            time.sleep(0.5 * 2 ** attempt)
    raise last


def batch(calls, size=50):
    """JSON-RPC batch, falling back to single calls if an endpoint refuses batches."""
    out = [None] * len(calls)
    for i in range(0, len(calls), size):
        chunk = calls[i:i + size]
        payload = [{"jsonrpc": "2.0", "id": i + j, "method": m, "params": p} for j, (m, p) in enumerate(chunk)]
        done = False
        for attempt in range(6):
            try:
                res = _post(RPCS[attempt % len(RPCS)], payload)
                if isinstance(res, list) and all("result" in x for x in res):
                    for x in res:
                        out[x["id"]] = x["result"]
                    done = True
                    break
            except (urllib.error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError):
                pass
            time.sleep(0.5 * 2 ** attempt)
        if not done:
            for j, (m, p) in enumerate(chunk):
                out[i + j] = rpc(m, p)
    return out


h2i = lambda h: int(h, 16) if h and h != "0x" else 0
word = lambda data, k: data[2 + 64 * k: 2 + 64 * (k + 1)]
addr_topic = lambda t: "0x" + t[-40:]
pad = lambda a: a[2:].lower().rjust(64, "0")


def call(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])


def logs_between(lo, hi):
    """eth_getLogs for AuthorizationUsed on USDC, halving the range when a node caps results."""
    try:
        return rpc("eth_getLogs", [{"address": USDC, "topics": [TOPIC_AUTH_USED], "fromBlock": hex(lo), "toBlock": hex(hi)}])
    except RuntimeError as e:
        if hi > lo and any(k in str(e).lower() for k in ("more than", "too many", "range", "limit", "exceed")):
            mid = (lo + hi) // 2
            return logs_between(lo, mid) + logs_between(mid + 1, hi)
        raise


def multicall_balances(pairs, chunk=300):
    """balanceOf for (token, wallet) pairs through Multicall3.aggregate3, allowFailure on each.
    Hundreds of balances per eth_call keep a public endpoint's rate limit out of the way."""
    out = []
    for i in range(0, len(pairs), chunk):
        part = pairs[i:i + chunk]
        n = len(part)
        heads, tails, offset = [], [], n * 32
        for token, wallet in part:
            cd = bytes.fromhex(SEL_BALANCE[2:] + pad(wallet))
            padded = cd + b"\x00" * ((32 - len(cd) % 32) % 32)
            el = (bytes.fromhex(token[2:].rjust(64, "0")) + (1).to_bytes(32, "big") + (0x60).to_bytes(32, "big")
                  + len(cd).to_bytes(32, "big") + padded)
            heads.append(offset.to_bytes(32, "big"))
            tails.append(el)
            offset += len(el)
        body = (0x20).to_bytes(32, "big") + n.to_bytes(32, "big") + b"".join(heads) + b"".join(tails)
        res = bytes.fromhex(call(MULTICALL3, "0x82ad56cb" + body.hex())[2:])
        w = lambda o: int.from_bytes(res[o:o + 32], "big")
        arr = w(0)
        base = arr + 32
        for k in range(w(arr)):
            t = base + w(base + 32 * k)
            ok = w(t) == 1
            b0 = t + w(t + 32)
            ln = w(b0)
            out.append(int.from_bytes(res[b0 + 32:b0 + 64], "big") if ok and ln >= 32 else 0)
    return out


def dist(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n:
        return {}
    q = lambda p: xs[min(n - 1, int(p * n))]
    total = sum(xs)
    top = lambda f: sum(xs[n - max(1, int(n * f)):]) / total if total else 0
    return {
        "n": n, "sum": total, "mean": total / n, "median": statistics.median(xs), "p75": q(0.75),
        "p90": q(0.90), "p99": q(0.99), "max": xs[-1], "zero_share": sum(1 for x in xs if x == 0) / n,
        "share_held_by_top_1pct": top(0.01), "share_held_by_top_10pct": top(0.10),
    }


def main():
    latest = h2i(rpc("eth_blockNumber", []))
    start = latest - WINDOW_DAYS * BLOCKS_PER_DAY
    starts = sorted(random.sample(range(start, latest - SEGMENT_BLOCKS), SEGMENTS))
    logs = []
    for s in starts:
        logs += logs_between(s, s + SEGMENT_BLOCKS - 1)
    sampled_blocks = SEGMENTS * SEGMENT_BLOCKS
    per_day = len(logs) / sampled_blocks * BLOCKS_PER_DAY
    payers = {}
    for lg in logs:
        a = addr_topic(lg["topics"][1])
        payers[a] = payers.get(a, 0) + 1

    # Receipts: who submitted, who was paid, how much.
    txs = list({lg["transactionHash"] for lg in logs})
    random.shuffle(txs)
    receipts = [r for r in batch([("eth_getTransactionReceipt", [t]) for t in txs[:RECEIPTS]], size=25) if r]
    submitters, merchants, amounts, revenue = {}, {}, [], {}
    for r in receipts:
        submitters[r["from"].lower()] = submitters.get(r["from"].lower(), 0) + 1
        authorizers = {addr_topic(l["topics"][1]) for l in r["logs"]
                       if l["address"].lower() == USDC and l["topics"][0] == TOPIC_AUTH_USED}
        for l in r["logs"]:
            if l["address"].lower() == USDC and l["topics"][0] == TOPIC_TRANSFER and len(l["topics"]) == 3:
                frm, to = addr_topic(l["topics"][1]), addr_topic(l["topics"][2])
                if frm in authorizers:
                    merchants[to] = merchants.get(to, 0) + 1
                    amt = h2i(l["data"]) / 1e6
                    amounts.append(amt)
                    revenue[to] = revenue.get(to, 0) + amt

    # Aave: the tokens that mean "already earning", and the live supply rate. Guarded: a missing
    # rate costs one line of the report, not the run.
    a_token, pool, apr, apy = None, None, None, None
    try:
        a_token = "0x" + call(WA_BAS_USDC, SEL_ATOKEN)[-40:]
        pool = "0x" + call(a_token, SEL_POOL)[-40:]
        rd = call(pool, SEL_RESERVE + pad(USDC))
        apr = h2i(word(rd, 2)) / 1e27  # currentLiquidityRate, in ray
        secs = 365 * 24 * 3600
        apy = (1 + apr / secs) ** secs - 1
    except Exception as e:  # noqa: BLE001
        print(f"aave lookup failed: {e}", file=sys.stderr)
    tokens = [t for t in (USDC, a_token, WA_BAS_USDC) if t]

    def holdings(wallets):
        ws = list(wallets)
        if len(ws) > MAX_WALLETS:
            ws = random.sample(ws, MAX_WALLETS)
        res = multicall_balances([(t, w) for w in ws for t in tokens])
        k_ = len(tokens)
        usdc, parked, rows = [], 0, []
        for k, w in enumerate(ws):
            vals = res[k_ * k: k_ * (k + 1)]
            u, earning = vals[0], sum(vals[1:])
            usdc.append(u / 1e6)
            if earning:
                parked += 1
            rows.append((w, u / 1e6, earning / 1e6))
        sample = random.sample(ws, min(400, len(ws)))
        codes = batch([("eth_getCode", [w, "latest"]) for w in sample])
        eoa = sum(1 for c in codes if c in (None, "0x"))
        delegated = sum(1 for c in codes if c and c.startswith("0xef0100"))
        return {
            "measured_wallets": len(ws), "of": len(wallets), "usdc": dist(usdc),
            "holding_any_aave_usdc_share": parked / len(ws) if ws else 0,
            "code_sample": {"n": len(sample), "eoa": eoa, "eip7702_delegated": delegated,
                            "contract": len(sample) - eoa - delegated},
            "top_by_usdc": sorted(rows, key=lambda x: -x[1])[:25],
        }

    payer_h = holdings(payers)
    merchant_h = holdings(merchants)
    top_sub = sorted(submitters.items(), key=lambda x: -x[1])[:10]
    result = {
        "chain": "base-mainnet", "latest_block": latest, "window_days": WINDOW_DAYS,
        "sampled_blocks": sampled_blocks, "sampled_share_of_window": sampled_blocks / (WINDOW_DAYS * BLOCKS_PER_DAY),
        "authorizations_in_sample": len(logs), "authorizations_per_day_est": per_day,
        "receipts_sampled": len(receipts),
        "top_submitters": [{"address": a, "share": c / len(receipts)} for a, c in top_sub],
        "payment_usdc": dist(amounts),
        "payers": {"unique_in_sample": len(payers), **payer_h},
        "merchants": {"unique_in_receipt_sample": len(merchants), **merchant_h},
        "aave_usdc_supply": {"pool": pool, "aToken": a_token, "apr": apr, "apy": apy},
        "rpc_calls": _n,
    }
    yld = lambda d: d.get("sum", 0) * apy if apy is not None else None
    result["idle_yield_per_year_usd"] = {"payers_measured": yld(payer_h["usdc"]),
                                         "merchants_measured": yld(merchant_h["usdc"])}
    result["merchants_by_sampled_x402_revenue"] = [
        {"address": a, "usdc_received_in_sample": v, "payments_in_sample": merchants[a]}
        for a, v in sorted(revenue.items(), key=lambda x: -x[1])[:40]
    ]
    json.dump(result, open(sys.argv[1] if len(sys.argv) > 1 else "x402-measure.json", "w"), indent=2)

    f = lambda x: f"{x:,.2f}"
    p, m = payer_h["usdc"], merchant_h["usdc"]
    lines = [
        f"x402 on Base mainnet, measured at block {latest:,} (last {WINDOW_DAYS} days, {sampled_blocks:,} blocks sampled)",
        "",
        f"EIP-3009 authorizations in sample   {len(logs):,}   (~{per_day:,.0f} per day, extrapolated)",
        f"receipts inspected                  {len(receipts):,}",
        "top submitters (facilitators)       " + ", ".join(f"{a[:10]}.. {s:.0%}" for a, s in
                                                           [(x['address'], x['share']) for x in result['top_submitters'][:5]]),
        f"payment size, USDC                  median {f(result['payment_usdc'].get('median', 0))}, "
        f"mean {f(result['payment_usdc'].get('mean', 0))}, p90 {f(result['payment_usdc'].get('p90', 0))}",
        "",
        f"Aave USDC supply rate on Base       " + (f"{apy:.2%} APY (live, from the pool)" if apy is not None else "unavailable"),
        "",
        "                         PAYERS                MERCHANTS",
        f"wallets measured         {payer_h['measured_wallets']:<21,} {merchant_h['measured_wallets']:,}",
        f"USDC held, median        {f(p.get('median', 0)):<21} {f(m.get('median', 0))}",
        f"USDC held, mean          {f(p.get('mean', 0)):<21} {f(m.get('mean', 0))}",
        f"USDC held, p90           {f(p.get('p90', 0)):<21} {f(m.get('p90', 0))}",
        f"USDC held, total         {f(p.get('sum', 0)):<21} {f(m.get('sum', 0))}",
        f"held by top 10%          {p.get('share_held_by_top_10pct', 0):<21.0%} {m.get('share_held_by_top_10pct', 0):.0%}",
        f"holding zero USDC        {p.get('zero_share', 0):<21.0%} {m.get('zero_share', 0):.0%}",
        f"already in Aave          {payer_h['holding_any_aave_usdc_share']:<21.1%} {merchant_h['holding_any_aave_usdc_share']:.1%}",
        f"contracts (code sample)  {payer_h['code_sample']['contract']}/{payer_h['code_sample']['n']:<17} "
        f"{merchant_h['code_sample']['contract']}/{merchant_h['code_sample']['n']}",
        f"idle yield / year (USD)  {f(result['idle_yield_per_year_usd']['payers_measured'] or 0):<21} "
        f"{f(result['idle_yield_per_year_usd']['merchants_measured'] or 0)}",
        "",
        "Top merchants by USDC held (address, USDC, already in Aave, payments in receipt sample):",
    ]
    for w, u, a in merchant_h["top_by_usdc"][:20]:
        lines.append(f"  {w}  {u:>14,.2f}  {a:>10,.2f}  {merchants.get(w, 0)}")
    lines += ["", "Top merchants by x402 revenue in the receipt sample (address, USDC, payments):"]
    for x in result["merchants_by_sampled_x402_revenue"][:20]:
        lines.append(f"  {x['address']}  {x['usdc_received_in_sample']:>12,.4f}  {x['payments_in_sample']}")
    lines += ["", f"rpc calls: {_n}"]
    report = "\n".join(lines)
    print(report)
    open((sys.argv[2] if len(sys.argv) > 2 else "x402-measure.txt"), "w").write(report + "\n")


if __name__ == "__main__":
    main()

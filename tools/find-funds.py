#!/usr/bin/env python3
"""Find test USDC that was claimed but has not turned up where it is needed.

Reads only public chain state. No keys, no secrets, no writes to any chain.

For each chain it reports the deployer's native and USDC balance, then scans
ERC-20 Transfer logs addressed to the deployer. The scan carries no token
filter, so it finds a transfer of the wrong token as readily as the right one,
and it prints each sender -- which is how the funding accounts identify
themselves without anyone having to type their addresses.

Usage: find-funds.py <address> [<extra address> ...]
"""
import json
import sys
import urllib.request

TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

CHAINS = [
    {
        "name": "Base Sepolia",
        "id": 84532,
        "rpcs": ["https://sepolia.base.org",
                 "https://base-sepolia-rpc.publicnode.com"],
        "usdc": "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        # ~2s blocks: 43,200 a day. Scan back a week.
        "lookback": 302_400,
        "explorer": "https://sepolia.basescan.org",
    },
    {
        "name": "Ethereum Sepolia",
        "id": 11155111,
        "rpcs": ["https://ethereum-sepolia-rpc.publicnode.com",
                 "https://rpc.sepolia.org"],
        "usdc": "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
        # ~12s blocks: 7,200 a day. Scan back a week.
        "lookback": 50_400,
        "explorer": "https://sepolia.etherscan.io",
    },
]

# Tokens worth naming when one turns up.
KNOWN = {
    "0x036cbd53842c5426634e7929541ec2318f3dcf7e": ("USDC", 6, "Base Sepolia"),
    "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238": ("USDC", 6, "Ethereum Sepolia"),
    "0x5b0bb86566ca63b57b6be2138a66c1b3d74467d8": ("wsUSD", 18, "Spectrum"),
    "0x54de35ac7fd6756d49ea77ce7bbcd026fadc364a": ("sUSD", 18, "Spectrum"),
}


class Rpc:
    def __init__(self, urls):
        self.urls = list(urls)
        self.n = 0

    def __call__(self, method, params):
        last = None
        for url in self.urls:
            for _ in range(3):
                self.n += 1
                body = json.dumps({"jsonrpc": "2.0", "id": self.n,
                                   "method": method, "params": params}).encode()
                req = urllib.request.Request(
                    url, data=body, headers={"content-type": "application/json"})
                try:
                    with urllib.request.urlopen(req, timeout=45) as r:
                        out = json.loads(r.read())
                    if "error" in out:
                        last = RuntimeError(f"{url}: {out['error']}")
                        break          # a node-level refusal: try the next node
                    return out["result"]
                except Exception as e:  # noqa: BLE001 - any transport failure retries
                    last = e
        raise last


def hexint(x):
    return int(x, 16) if isinstance(x, str) else int(x)


def units(raw, dp):
    s = str(raw).rjust(dp + 1, "0")
    return f"{s[:-dp] or '0'}.{s[-dp:]}" if dp else str(raw)


def scan(rpc, deployer, start, end):
    """Transfer logs with `to` == deployer, chunked so a node's range cap cannot
    turn the whole scan into nothing."""
    topic_to = "0x" + deployer[2:].lower().rjust(64, "0")
    found, step, lo, capped = [], 9_000, start, False
    while lo <= end:
        hi = min(lo + step - 1, end)
        try:
            logs = rpc("eth_getLogs", [{
                "fromBlock": hex(lo), "toBlock": hex(hi),
                "topics": [TRANSFER, None, topic_to],
            }])
        except Exception:                      # noqa: BLE001
            if step > 500:
                step //= 4
                continue
            capped = True
            lo = hi + 1
            continue
        found.extend(logs)
        lo = hi + 1
    return found, capped


def main():
    who = [a.lower() for a in sys.argv[1:]]
    if not who:
        sys.exit("usage: find-funds.py <address> [<address> ...]")

    print(f"Looking for test funds belonging to {len(who)} address(es)\n")
    total_found = 0

    for c in CHAINS:
        print("=" * 72)
        print(f"{c['name']}  (chain {c['id']})")
        print("=" * 72)
        rpc = Rpc(c["rpcs"])
        try:
            latest = hexint(rpc("eth_blockNumber", []))
        except Exception as e:                 # noqa: BLE001
            print(f"  unreachable: {e}\n")
            continue
        start = max(0, latest - c["lookback"])
        print(f"  latest block {latest}; scanning from {start}\n")

        for addr in who:
            native = hexint(rpc("eth_getBalance", [addr, "latest"]))
            call = rpc("eth_call", [{"to": c["usdc"],
                                     "data": "0x70a08231" + addr[2:].rjust(64, "0")},
                                    "latest"])
            usdc = hexint(call) if call and call != "0x" else 0
            print(f"  {addr}")
            print(f"      ETH  {units(native, 18)}")
            print(f"      USDC {units(usdc, 6)}   ({c['usdc']})")
            if usdc:
                total_found += 1

            logs, capped = scan(rpc, addr, start, latest)
            if capped:
                print("      (part of the range could not be scanned)")
            if not logs:
                print("      no incoming token transfers in range")
            for lg in logs:
                token = lg["address"].lower()
                name, dp, _ = KNOWN.get(token, ("unknown token", 0, ""))
                sender = "0x" + lg["topics"][1][-40:]
                amount = hexint(lg["data"]) if lg.get("data", "0x") != "0x" else 0
                print(f"      IN  {units(amount, dp)} {name}"
                      f"  from {sender}"
                      f"  block {hexint(lg['blockNumber'])}")
                print(f"          {c['explorer']}/tx/{lg['transactionHash']}")
            print()

    print("=" * 72)
    print("no USDC found on either chain" if not total_found
          else "USDC located -- see the balances above")


if __name__ == "__main__":
    main()

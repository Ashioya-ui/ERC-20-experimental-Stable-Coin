# Phase 6 — the sUSD x402 payment rail

**Branch** `phase-6-x402` (merged to `main`) · **Date** 22 October 2026
**Tests** 246 Forge (15 on the router) + 47 Node = 293 · **CI** green on GitHub's runners
**Status** local chain and CI only. Not deployed to any public network. No professional audit.

## What was built

An agent that holds **one sUSD balance** can pay any x402 bill. No vault position, no USDC float,
no ETH for gas, and the balance earns between payments.

| Component | File |
|---|---|
| Pay router — immutable, ownerless, holds nothing between calls | `src/periphery/SpectrumPayRouter.sol` |
| Facilitator — x402 v2 `/verify`, `/settle`, `/supported`, plus `/convert` | `x402/facilitator.mjs` |
| Merchant — resource server with an agent marketplace | `x402/merchant.mjs` |
| Agent client and CLI with a spend policy | `x402/agent.mjs` |
| Deployment | `script/DeployPayRouter.s.sol`, `.github/workflows/deploy-sepolia-rail.yml` |
| Local rehearsal | `script/rehearsal/x402.sh` (`make x402`) |

Four payment paths, all gasless for the payer: priced in sUSD; priced in USDC and routed out of
sUSD; plain USDC passed through unchanged; and convert-then-pay for merchants that take only USDC.

Zero dependencies — Node 22 built-ins plus Foundry's `cast`. npm and PyPI were unreachable from
the build workspace, so the x402 SDKs could not be installed. `x402/lib/cast.mjs` is the only
module that touches the chain and swaps cleanly for viem.

## The property the design rests on

The EIP-3009 nonce **is** the payment intent:

```
nonce = keccak256(abi.encode(PAY_INTENT_TYPEHASH, payTo, assets, salt))
```

`pay()` recomputes it from its own arguments, so a submitter who changes the payee, the price or
the salt invalidates the signature. `receiveWithAuthorization` requires `msg.sender == to`, so
only the router can use an authorization naming it. Together: the authorization can make exactly
one payment, of `assets` USDC to `payTo`, with change returned. Neither the merchant, nor the
facilitator, nor anyone watching the mempool can redirect it.

## Measured, not modelled

Every figure is reproducible from the repository against the shipped code.

| | |
|---|---|
| Router cost, $0.01 to $10 | **flat 3.0–3.3 bps** (`x402/review/fee-curve.mjs`) |
| At x402's ~$0.13 mean payment | ~3.1 bps |
| Below $0.01 | the 0.01 sUSD minimum dominates; change returns as USDC |
| Settlement gas | router 217,858 · direct sUSD 89,997 · plain USDC 81,392 |
| Yield, one simulated day at 5% APY | $0.087333 on a $598.35 treasury, 24 rebases |
| Fee per routed payment | $0.000016 |
| **Break-even** | **5,374 payments/day — $268.72 of daily volume, ~45% treasury turnover** |

So an agent can turn over nearly half its treasury in payments every day before the rail costs
more than the balance earns. Because the fee is flat in the invoice size above the minimum, that
ratio holds across the range x402 actually sees.

Agent-to-agent, on the local chain: a worker agent published a deliverable behind an x402
paywall and was paid **15.000000 USDC** to its own wallet out of the buyer's interest-bearing
balance, in one transaction, the file returned byte-identical. The buyer spent 15.004869 sUSD and
held no USDC at any point.

## Security work

A **22-row threat model** (`docs/design/x402-rail.md`), each row mapped to the test that tries to
break it. Five defects were found and fixed during the phase, each reproduced before being
patched:

| | Defect | Severity |
|---|---|---|
| A-02 | Unvalidated `maxTimeoutSeconds` from an untrusted merchant reached `BigInt()` → HTTP 500; also unbounded | Low |
| A-04 | The agent preferred the router over USDC it already held, paying the fee again and stranding change — a micropayment agent bled its earning balance into dead USDC | Medium |
| §3 | `unconfirmed` never evicted; grows on a provokable error path | Medium |
| §4 | One hung `cast` subprocess parked **every** later settlement for ever | High |
| §5 | **The same authorization could be broadcast twice** when a receipt was unreadable | High |

§5 recurred in a second form: an ambiguous broadcast — `cast send` failing *after* the node
accepted the transaction — was reported as unsent, inviting the same double broadcast. The error
cannot distinguish the cases, so `send` now consults the sender's **nonce** instead.

`audit/x402-state-audit.md` is the full report. It was prompted by PHP2Shell
(CVE-2026-109618/109619, 21 October 2026), whose structural lesson — a long-lived worker whose
error paths leave global state inconsistent for the *next* request — describes the facilitator
exactly. Five of six questions came back vulnerable.

## Limitations

- **Local chain and CI only.** The build workspace cannot reach Base RPCs; every public endpoint
  tried returned 403 at the proxy. `deploy-sepolia-rail.yml` is ready and needs one secret, one
  variable and a funded throwaway wallet.
- **No professional audit.** Self-audited and reviewed by a separate agent; not the same thing.
- **Interoperability untested.** The format follows the v2 spec, but no x402 SDK or public
  facilitator has been run against it. Standard clients do not send `payload.spectrum.salt`, so
  they can use the sUSD and plain USDC paths but not the router.
- **One process, in memory.** Idempotency does not survive a restart; two facilitators on one key
  would race. Production needs shared storage and nonce management or several hot wallets.
- **No facilitator fee.** The operator pays the gas.
- **Legal.** A dollar token that pays holders interest is prohibited as a *payment stablecoin* in
  both the US (GENIUS, effective 18 January 2027) and the EU (MiCA Art. 50), and a German court
  upheld the regulator against Ethena on that point in May 2025. This design is on the right side
  of that line by construction — the earning instrument is never what the merchant receives, USDC
  is the payment leg, and the router is the boundary — but the yield instrument itself still needs
  counsel and an exemption before any public offering. See `RUNBOOK_MAINNET.md` §7.

## Reproducing it

```bash
make x402                     # chain, router, facilitator, merchant, demo, 47 tests (~1 min)
make x402-serve               # the same, left running
cd x402 && npm test           # the Node suite against a running rail
node x402/review/fee-curve.mjs        # the cost table above
node x402/review/unit-economics.mjs   # the break-even above
```

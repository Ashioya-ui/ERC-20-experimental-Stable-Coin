# Phase 6 — the sUSD x402 payment rail

**Branch** `phase-6-x402` (merged to `main`) · **Date** 22 October 2026
**Tests** 246 Forge (15 on the router) + 47 Node = 293 · **CI** green on GitHub's runners
**Status** **live on Base Sepolia** (chain 84532), block 48884064. No professional audit.

## Live on Base Sepolia

Deployed by GitHub Actions (`deploy-sepolia-rail.yml`) against Circle's real USDC and Uniswap
v4's PoolManager, then used to pay two real x402 invoices on the public chain. Explorer:
`https://sepolia.basescan.org/address/<address>`.

| Contract | Address |
|---|---|
| sUSD | `0x54De35aC7fd6756D49eA77ce7bbCd026faDC364a` |
| SpectrumPayRouter | `0x1783d46C349224992A5A3ab4C84fc7EBf71c056e` |
| SpectralStabilizer | `0x3940F5F444B1ec69bb0245062796896135B8f948` |
| AutonomousTreasury | `0x1af57BA60edaEDF91F5925A3A79F346cb50F12a6` |
| SpectralEntropyOracle | `0xC7A4b9E9A7DAef0cF2bb531CCda1a3a4a744B4BB` |
| SpectralHook | `0x7A4BB5720a158a22ae14297915aa21efbd1B6040` |
| SpectrumLens | `0x384768E8b0b9d992EE5F23701D21B1b880495285` |
| WrappedSUSD (wsUSD) | `0x5B0Bb86566cA63B57B6BE2138a66c1b3D74467d8` |
| USDC (Circle, existing) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

The hook address ends `6040` because Uniswap v4 encodes a hook's permissions in its address; it
was CREATE2-mined to land on exactly `beforeInitialize | afterSwap` on a live network.

**Source is verified.** All eight contracts are published on Sourcify, creation *and* runtime
bytecode matched, verified 2026-10-22T20:47:48Z (`verify-sepolia.yml`; results committed per run
to `deployments/84532-verification.txt`). Readable at
`https://base-sepolia.blockscout.com/address/<address>?tab=contract` and queryable at
`https://sourcify.dev/server/v2/contract/84532/<address>`.

Sourcify reports `match`, not `exact_match`, and that is the ceiling for this build:
`foundry.toml` sets `bytecode_hash = "none"`, so the deployed code carries no metadata hash to
pin an exact match to. The source still compiles to the deployed bytecode, which is what
verification is for. BaseScan verification needs an Etherscan API key and runs from the same
workflow once one exists.

The run paid an sUSD-priced invoice and a USDC-priced invoice routed out of sUSD. The agent held
no ETH: the facilitator submitted both and paid the gas. The whole deployment, the router, the
facilitator's gas float and both settlements came out of a single 0.01 test-ETH faucet drip.

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

- **Base Sepolia, not mainnet.** Deployed and exercised on a public testnet with valueless
  tokens. The build workspace itself cannot reach Base RPCs, so every public-network action runs
  through GitHub Actions.
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

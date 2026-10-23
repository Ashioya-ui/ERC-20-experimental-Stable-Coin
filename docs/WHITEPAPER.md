# Spectrum: an interest-bearing dollar an autonomous agent can spend

**William Alubokho Ashioya** · 23 October 2026 · v1.0, Base Sepolia

> **Status.** The payment rail is live on Base Sepolia (chain 84532, block 48884064) and has
> settled real payments. The spectral engine described in §3 has **not** run on a public chain:
> the pool carries no liquidity, so the oracle has recorded nothing and no rebase has occurred
> there. Mainnet deployment is blocked on legal structure (§8), not on engineering. There has
> been no professional audit. Figures are marked *measured* or *modelled*; nothing here is
> evidence that is not labelled as such.

---

## Abstract

An autonomous software agent that pays for its own inputs has a treasury problem nobody has
solved for it. To earn on idle cash it must hold a yield-bearing position; to pay an invoice it
must hold a stablecoin; and to do both it must move funds between them on a schedule, which is
precisely the kind of judgement one does not want to delegate to an unattended process.

Spectrum collapses the two into one balance. sUSD is a reserve-backed, rebasing dollar token
whose balance grows while it sits still. A payment router redeems exactly enough of that balance
at the moment of payment, hands the merchant the exact invoice in ordinary USDC, and returns all
change in the same transaction. The merchant is paid in Circle's USDC and never learns what the
payer held. The payer needs no ETH: a facilitator submits the transaction and pays its gas.

Two properties make this safe to automate. First, the EIP-3009 nonce *is* the payment intent —
`keccak256(payTo, assets, salt)`, recomputed inside the router — so a signed authorization can
make exactly one payment, to one payee, for one amount, and nobody in the path can redirect it.
Second, the router is immutable, ownerless, and holds nothing between calls.

Measured on Base Sepolia and in Forge, a routed payment costs **3.0–3.3 basis points at neutral
entropy**, flat from one cent to ten dollars. Against an assumed 5% yield, a model puts
break-even near **45% of treasury turned over per day** — the fee side of that is measured, the
yield side is not.

---

## 1. The problem

HTTP 402 Payment Required sat unused for thirty years. The x402 protocol revived it for machine
payments, and by June 2026 it had settled more than 160 million transactions, over 90% of them on
Base, more than 99.99% denominated in USDC, with a mean payment around $0.13.

Those payments come out of balances that earn nothing. An agent holding USDC to pay x402 invoices
is holding an asset with a zero real return, and the two obvious remedies both fail:

- **Hold a yield token and swap before paying.** Two transactions, slippage, a price oracle in the
  path, and an agent that must predict its own spending.
- **Hold both and rebalance.** A scheduled job with discretion over funds, which is an attack
  surface and an operational burden.

The large interest-bearing dollar tokens — sUSDS, USDY, sUSDe, syrupUSDC — are built for human
savers who hold for months. None of them spend. The x402 facilitators move USDC and pay no
interest. The intersection is empty.

## 2. sUSD

sUSD is an ERC-20 whose balance is `shares × index / 1e18`. Distribution raises `index`; loss
absorption lowers it. Every holder's balance moves together, so a payment is an ordinary transfer
and integrations need no claim step.

**Backing.** `mint` takes collateral into an autonomous treasury, which keeps a liquidity buffer
idle and batches the remainder into an ERC-4626 vault. The minter receives the *measured* increase
in conservatively-valued reserve, minus a fee. `redeem` burns sUSD and pays collateral, minus a
fee. **Redemption can never be paused.**

**Reserve floor.** Every state-changing entry point ends by asserting
`reserveValue() ≥ totalSupply()` and reverts otherwise. The reserve is valued at `previewRedeem`
of the vault shares plus the idle balance — never at par.

**Losses.** A realised vault loss can push the reserve below supply. `sync()` lowers the index
until supply equals the reserve, sharing the loss pro rata. It is permissionless, unpausable, and
runs first inside every mint, redeem and rebase, so nobody exits at the stale price.

**Protocol capital.** A tranche of the reserve is first-loss capital that can never be
distributed or withdrawn. On the live instance it is 5 USDC against a 2.947 sUSD supply.

## 3. The spectral engine

Fees and limits are not constants. They are functions of a measured signal, *H*, the spectral
entropy of recent order flow.

A Uniswap v4 hook, bound at construction to a single pool, records the absolute wsUSD leg of each
swap. The oracle keeps one slot per *block* — all swaps in a block are summed, empty blocks are
skipped — and folds the Walsh–Hadamard spectral entropy of the last eight active blocks into an
exponential moving average.

- Even, homogeneous flow → **H = 0**.
- One block dominating the window, a whale or an MEV spike → **H = 1**.

H is the neutral constant 0.5 during warm-up and after an hour without swaps. Each fold carries
weight `min(0.25, Δt / (Δt + 1 hour))`, so moving the signal costs wall-clock time, not a few
blocks of gas. **H can tighten a safety limit but never loosen one**: the surplus buffer never
drops below its neutral 2.75%, and the daily mint cap never rises above its neutral 11%.

| | H = 0 (calm) | H = 0.5 | H = 1 (spiky) |
|---|---|---|---|
| Mint fee | 1 bp | 7 bp | 25 bp |
| Redeem fee | 1 bp | 3.25 bp | 10 bp |
| Daily mint cap | 11% | 11% | 2% |
| Surplus buffer | 2.75% | 2.75% | 5% |
| Max rebase step | 1 bp | 0.75 bp | 0.5 bp |

**Distribution.** `rebase()` is permissionless, at most hourly, and raises balances by at most
1 bp of supply, only out of surplus above the buffer and above protocol capital. A rebase step is
always smaller than the minimum mint fee plus redeem fee, so a mint → rebase → redeem sandwich
always loses money.

**The churn budget.** Within a seven-day window let *L* be the index's total variation and *D* its
range. A positive rebase is deferred if afterwards *L > C · D*, where

$$C = \tfrac{5\pi}{6} + 2\sin\tfrac{\pi}{12} \approx 3.1356$$

This constant comes from the theory of **self-approaching curves**, from joint work with Elmar
Langetepe; it is the proven upper bound on the length-to-diameter ratio of such a curve. Monotone
yield distribution has *L = D* and is never blocked; an oscillating index is throttled. Loss
absorption is never deferred, and the step provably cannot revert.

**wsUSD.** A rebasing token must never sit in a `PoolManager`: anyone could capture positive
rebases between `sync` and `settle`, and negative rebases would strand the last LPs. Pools pair
**wsUSD**, an ERC-4626 wrapper, against USDC — the stETH/wstETH pattern.

## 4. The payment rail

```
agent                         merchant             facilitator            chain
  | GET /resource                |                      |                   |
  |----------------------------->| 402 + PAYMENT-REQUIRED                   |
  | salt := random                                                          |
  | nonce := router.intentNonce(payTo, assets, salt)                        |
  | sign ReceiveWithAuthorization(from, to=router, value, nonce)            |
  |---- GET + PAYMENT-SIGNATURE ->| /verify ----------->| checks + eth_call |
  |                               | handler runs        |                   |
  |                               | /settle ----------->| router.pay(...)   |
  |                               |                     |  sync; receive;   |
  |                               |                     |  redeem; pay USDC;|
  |                               |                     |  return change    |
  |<--- 200 + PAYMENT-RESPONSE ---|<--------------------|                   |
```

**Intent binding.** EIP-3009 signs `(from, to, value, validAfter, validBefore, nonce)`. It says
nothing about where the router should send the proceeds. So the payer sets

```
nonce = keccak256(abi.encode(PAY_INTENT_TYPEHASH, payTo, assets, salt))
```

and `pay()` recomputes it from its own arguments. Change the payee, the price or the salt and the
nonce changes, so the token rejects the signature. `receiveWithAuthorization` additionally
requires `msg.sender == to`, so only the router can use an authorization naming it. **One
authorization, one payment, one payee, one amount.**

**All or nothing.** If the authorization is invalid or spent, the value does not cover the price
at the current fee, or the treasury cannot pay out, the transaction reverts and the authorization
stays unused — the same signature can be submitted again later.

**Nothing to trust.** No owner, no settings, no fee, no balance between calls. Whatever the router
holds at the end of a payment goes back to that payer; this is fuzz-tested, not asserted.

**Sizing.** The agent authorises `sUSDToAuthorize(assets)`, computed at the 10 bp fee ceiling, so a
fee move between signing and settlement can never make the payment fail. The unused portion
returns in the same transaction.

**Four paths**, all gasless for the payer: priced in sUSD; priced in USDC and routed out of sUSD;
plain x402 USDC passed through unchanged; and convert-then-pay for merchants that take only USDC.

## 5. Economics

| | |
|---|---|
| Router cost, $0.01–$10, **at neutral entropy** | **3.0–3.3 bps** — *measured* |
| Across the policy curve | 1–10 bp, quadratic in H — *measured in Forge* |
| Settlement gas, Base Sepolia | router **216,976**; EIP-3009 sUSD **89,973** — *on-chain* |
| Yield, one day at 5% APY | $0.087333 on a $598 treasury — ***modelled*** |
| Break-even | 5,374 payments/day, ~45% treasury turnover — ***modelled*** |

The fee is flat in invoice size above the 0.01 sUSD redemption minimum; below it the minimum
dominates and change returns as USDC. The break-even figure assumes a 5% yield minted into a mock
vault on a local chain. **No reserve has yet earned anything.** Treat it as the shape of the unit
economics, not as evidence of them.

## 6. Security

A 22-row threat model maps each threat to the test that attacks it. Seven defects were found and
fixed during Phase 6, each reproduced before being patched — including two paths where the same
authorization could have been broadcast twice, and one where a hung subprocess parked every later
settlement permanently.

The facilitator was audited against the structural class behind **PHP2Shell**
(CVE-2026-109618/109619): a long-lived worker whose error paths leave global state inconsistent
for the *next* request. Five of six questions came back vulnerable and were fixed.

A separate independent review of the live deployment confirmed the deployer surrendered every
role, the supply cap is in force, redemption is unpausable, the reserve is backed 2.7×, and no
privileged path can move reserve funds to a caller's chosen address. It also corrected five
overstated claims in this project's own documents, which is why §5 is labelled the way it is.

Tooling: 293 passing tests, 10,000-run fuzzing, invariants at 1,024×256, Slither clean over 71
contracts and 102 detectors, Halmos proofs on the churn budget, and mutation testing.

## 7. Deployment

Live on Base Sepolia, source verified on Sourcify (creation and runtime bytecode matched):

| Contract | Address |
|---|---|
| sUSD | `0x54De35aC7fd6756D49eA77ce7bbCd026faDC364a` |
| SpectrumPayRouter | `0x1783d46C349224992A5A3ab4C84fc7EBf71c056e` |
| SpectralStabilizer | `0x3940F5F444B1ec69bb0245062796896135B8f948` |
| AutonomousTreasury | `0x1af57BA60edaEDF91F5925A3A79F346cb50F12a6` |
| SpectralEntropyOracle | `0xC7A4b9E9A7DAef0cF2bb531CCda1a3a4a744B4BB` |
| SpectralHook | `0x7A4BB5720a158a22ae14297915aa21efbd1B6040` |
| SpectrumLens | `0x384768E8b0b9d992EE5F23701D21B1b880495285` |
| WrappedSUSD | `0x5B0Bb86566cA63B57B6BE2138a66c1b3D74467d8` |

The hook address ends `6040` because Uniswap v4 encodes a hook's permissions in its address; it
was CREATE2-mined to land on exactly `beforeInitialize | afterSwap`.

The entire deployment — fourteen transactions, the router, the facilitator's gas float, and two
settled payments — was funded by a single 0.01 test-ETH faucet drip.

## 8. Regulatory position

A dollar token that pays its holders interest cannot be a compliant **payment stablecoin**. The
OCC's final GENIUS rule (21 October 2026, effective 18 January 2027) forbids a permitted issuer
from paying interest "solely in connection with the holding, use, or retention" of the coin. MiCA
Article 50 forbids it for e-money tokens in the EU, counting any benefit tied to holding duration
as interest, and offering one without authorisation is a criminal offence in Germany under § 46
KMAG. In May 2025 the Frankfurt administrative court upheld BaFin against Ethena on exactly this
point, treating a variable return paid in further tokens as the hallmark of a security.

**Spectrum is on the correct side of that line by construction, because the earning instrument is
never what the merchant receives.** USDC — issued by a licensed issuer — is the payment leg. sUSD
is a yield instrument, and the router is the boundary between them. The rule that forbids the
obvious design is the rule that makes this one coherent.

That resolves the payment-stablecoin question. It does not resolve the securities question: an
interest-bearing instrument offered to the public is an offering, and needs either an exemption
(Regulation D domestically, Regulation S offshore) or a licensed issuing partner. **No mainnet
offering should occur before counsel has signed off.** This is not legal advice.

## 9. Limitations

- The spectral engine has never run on a public chain; the Sepolia pool has no liquidity.
- No professional audit.
- No external users, no mainnet, no yield ever earned.
- Interoperability with third-party x402 clients is untested. Standard clients do not send
  `payload.spectrum.salt`, so they can use the sUSD and plain-USDC paths but not the router.
- The facilitator keeps idempotency state in one process's memory; two facilitators sharing a key
  would race. Production needs shared storage and nonce management.
- The facilitator earns no fee and pays all gas.
- An EIP-3009 authorization can be front-run by anyone who observes it. Funds still reach the
  payee, but settlement then fails and the merchant may answer 402 despite having been paid. This
  affects all EIP-3009 x402 payments.

## 10. References

1. x402 protocol specification, version 2.
2. EIP-3009, Transfer With Authorization.
3. EIP-1153, Transient Storage Opcodes (Uniswap v4).
4. Langetepe & Ashioya, *Self-approaching curves*, in preparation — source of the constant
   `5π/6 + 2 sin(π/12)`.
5. OCC final rule implementing the GENIUS Act, 21 October 2026.
6. Regulation (EU) 2023/1114 (MiCA), Articles 48 and 50.
7. VG Frankfurt am Main, 2 May 2025, 7 L 1257/25 (BaFin v. Ethena).
8. Wiz Research, *PHP2Shell*, CVE-2026-109618 / CVE-2026-109619.

*Repository, tests and audit reports: `REPORT_X402.md`, `docs/design/x402-rail.md`,
`audit/live-deployment-audit.md`, `audit/x402-state-audit.md`.*

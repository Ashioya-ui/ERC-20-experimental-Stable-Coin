# The sUSD x402 rail

Phase 6. An agent that holds one sUSD balance can pay any x402 bill. It does not need a vault
position, a USDC float or ETH for gas. Between payments the balance earns, because sUSD
rebases.

| Merchant prices in | Agent holds | How it pays | Merchant receives |
|---|---|---|---|
| sUSD | sUSD | EIP-3009 `transferWithAuthorization` on sUSD | the sUSD price |
| USDC, offers the router | sUSD | `receiveWithAuthorization` of sUSD to `SpectrumPayRouter`, which redeems and pays | exactly the USDC price |
| USDC only | sUSD | `/convert` (router, paying the agent itself), then a standard USDC authorization | exactly the USDC price |
| USDC | USDC | standard x402 USDC, passed through unchanged | exactly the USDC price |

Every path is gasless for the payer: the facilitator submits the transaction and pays its gas.

## Components

| Component | File | Role |
|---|---|---|
| Pay router | `src/periphery/SpectrumPayRouter.sol` | Immutable, ownerless, holds nothing between calls. `pay(...)` takes sUSD from a receive authorization, redeems exactly enough, pays the merchant `assets` USDC and returns all change to the payer |
| Facilitator | `x402/facilitator.mjs` | x402 v2 `/verify`, `/settle`, `/supported`, plus `/convert` |
| Merchant | `x402/merchant.mjs` | Example resource server: sUSD-, USDC+router- and USDC-only routes, and `/work/<id>` for a marketplace of agents' deliverables |
| Agent client | `x402/agent.mjs` | Library and CLI: picks the payment path, enforces a spend policy, signs with an encrypted keystore |
| Deploy | `script/DeployPayRouter.s.sol` | Deploys the router next to a Spectrum deployment and records it in `deployments/<chainId>-router.json` |
| Rehearsal | `script/rehearsal/x402.sh` | Local Base-shaped chain, full deployment, servers, demo, end-to-end tests |

The off-chain code has no dependencies. It uses Node 22 built-ins and Foundry's `cast` for ABI
encoding, EIP-712 signing and transactions. npm and PyPI could not be reached from the build
workspace, so the x402 SDKs, viem and ethers could not be installed. `x402/lib/cast.mjs` is the
only module that touches the chain; swapping it for viem changes nothing else.

## Wire format (x402 version 2)

- `402` responses carry `PAYMENT-REQUIRED`: base64 of `{x402Version: 2, error, resource, accepts: [requirement]}`.
- A requirement is `{scheme: "exact", network: "eip155:<chainId>", amount, asset, payTo, maxTimeoutSeconds, extra}`.
  `extra` carries the token's EIP-712 `name` and `version`. A USDC requirement that accepts the
  router also carries `extra.spectrumRouter` and `extra.payWith` (the sUSD address).
- The paid retry carries `PAYMENT-SIGNATURE`: base64 of `{x402Version: 2, resource, accepted, payload}`.
  `payload` is `{signature, authorization: {from, to, value, validAfter, validBefore, nonce}}`.
  Router payments add `payload.spectrum.salt`, which is a Spectrum extension.
- The `200` carries `PAYMENT-RESPONSE`: base64 of the facilitator's settlement
  `{success, payer, transaction, network}`.
- The merchant's order is verify, then run the handler, then settle, then deliver. If settlement
  fails, the merchant answers `402` and discards the handler's result.

## The router payment

```
agent                         merchant             facilitator                  chain
  | GET /premium                 |                      |                          |
  |----------------------------->| 402: 0.05 USDC to M, spectrumRouter R           |
  |<-----------------------------|                      |                          |
  | salt := random; nonce := R.intentNonce(M, 50000, salt)                          |
  | sign ReceiveWithAuthorization(from=A, to=R, value=R.sUSDToAuthorize(50000), nonce)
  | GET /premium + PAYMENT-SIGNATURE                    |                          |
  |----------------------------->| /verify ------------>| checks + eth_call R.pay  |
  |                              | handler runs         |                          |
  |                              | /settle ------------>| R.pay(A, value, ..., M, 50000, salt, sig)
  |                              |                      |   sync; receiveWithAuthorization (nonce must match);
  |                              |                      |   redeem sUSDFor(50000); USDC 50000 -> M; change -> A
  | 200 + PAYMENT-RESPONSE       |<---------------------|                          |
  |<-----------------------------|                      |                          |
```

### Intent binding

The EIP-3009 nonce is the payment intent:

```
nonce = keccak256(abi.encode(keccak256("SpectrumPayIntent(address payTo,uint256 assets,bytes32 salt)"), payTo, assets, salt))
```

The router recomputes the nonce from the `payTo`, `assets` and `salt` it is called with. If anyone
changes the payee or the amount, the nonce changes and the signature no longer verifies, so the
call reverts with `InvalidSignature`. A receive authorization can be used only by its `to`, which
is the router (`msg.sender == to`). Together these mean the authorization can make exactly one
payment: `assets` USDC to `payTo`, with the change going back to the payer. Neither the merchant,
nor the facilitator, nor anyone watching the mempool can redirect it.

### Fees and rounding

- The router calls `stabilizer.sync()` first, so a pending reserve loss is absorbed before the
  redemption is sized.
- It redeems `sUSDFor(assets) = ceil(assets * scale * 1e18 / (1e18 - r))`, where `r` is the
  redeem fee rate at the current entropy. The result is never below `minAmount()` (0.01 sUSD).
- The agent authorizes `sUSDToAuthorize(assets)`, which uses the maximum redeem fee (10 bp). That
  covers any fee the rate could reach by settlement. The unused part comes back in the same
  transaction.
- All change returns to the payer: sUSD that was not redeemed, and USDC above `assets`, which
  comes from rounding or from the 0.01 sUSD minimum. The router holds nothing afterwards; the
  tests check this, including when someone has sent the router tokens.
- At neutral entropy the payer pays the redeem fee of about 3.2 bp. In the rehearsal, a
  0.05 USDC bill cost 0.050016 sUSD.
- Bills under $0.01: the router redeems the 0.01 sUSD minimum, pays the merchant and refunds the
  rest in USDC. A $0.001 bill leaves about $0.009 USDC with the payer.

### Gas

The facilitator pays gas. In the Forge tests, `pay` costs about 206k–222k gas (median 217k).
That figure leaves out the 21k base cost and calldata. A plain sUSD `transfer` costs about 56k.
So a router payment costs roughly 4 times as much gas as a direct sUSD payment, and the
facilitator recovers it only if it charges for it. The on-chain figures from the rehearsal are in
`REPORT_X402.md`.

## Facilitator checks

`/verify` and `/settle` run the same checks, in this order, before anything is sent:

1. `x402Version` is 2, the scheme is `exact`, and the network is this chain.
2. The payload's `accepted` matches the requirement on asset, payTo and amount.
3. Every field is well formed: addresses, uint strings, a bytes32 nonce and a hex signature.
4. `payTo` is not a protocol contract (sUSD, stabilizer, treasury, router, USDC) and not zero.
   The amount is greater than zero.
5. Time window, measured in chain time: `validAfter <= now`, `now + 6 < validBefore`, and
   `validBefore <= now + maxTimeoutSeconds + 6`.
6. The path follows from the asset: sUSD direct; USDC to the router means the router path; any
   other USDC payment is a pass-through.
7. For direct and pass-through payments: `to == payTo`, `value == amount`, the nonce is unused,
   and the payer's balance covers `value`.
8. For router payments: `intentNonce(payTo, amount, salt) == nonce`, the nonce is unused,
   `value >= sUSDFor(amount)`, and the payer's balance covers `value`.
9. The exact transaction is simulated with `eth_call` from the facilitator's address.

`/settle` then:

- Keeps idempotency per (payer, nonce), bound to a fingerprint of the whole request. A retry of
  the same request gets the same answer. A request that reuses the authorization with other
  requirements is rejected as a replay.
- Sends one transaction at a time from its account, and simulates each again just before sending.
- Sends in two steps: broadcast and get the hash, then wait for the receipt. If the receipt is
  lost, the answer is `settlement_unconfirmed` with the transaction hash, never "not sent". A retry
  of the same request reads the receipt again. The merchant retries by itself.

## Threat model

Assets at risk: the payer's balance, the merchant's payment, and the facilitator's gas.
Adversaries: a malicious merchant, payer or facilitator, a third party who sees a payload, and a
lying 402.

| # | Threat | Mitigation | Tested |
|---|---|---|---|
| T1 | A facilitator or merchant changes `payTo` or `amount` of a router payment | Intent binding: the signature fails on-chain | forge `test_changingTheRecipientPriceOrSaltBreaksTheSignature`; node "router intent" |
| T2 | A third party uses the receive authorization outside the router | `receiveWithAuthorization` requires `msg.sender == to` | forge `test_aTransferAuthorizationCannotBeUsedAsAReceive` and the token's EIP-3009 suite |
| T3 | A 402 names a malicious router in `extra.spectrumRouter`. A receive authorization lets its `to` take the whole value | The agent uses only the router from its own deployment files and ignores the 402's | node "merchant-supplied router address is ignored" |
| T4 | Replay of a settled payment | EIP-3009 nonces on-chain; facilitator cache bound to the request fingerprint | forge `test_replayIsRejected`; node "replay", "idempotent" |
| T5 | A cached success is reused for another merchant's requirements | Fingerprint check; replay rejected | node "idempotent" |
| T6 | Underpaying, redirecting, a cheaper `accepted`, a forged signature | Checks 2, 7 and 9 | node "tampering" |
| T7 | Stale or not-yet-valid authorizations, or very long ones held for later | Check 5 | forge `test_timeWindowIsEnforced`; node "time window" |
| T8 | The payer spends or cancels between verify and settle | Settle re-checks and simulates; the merchant answers 402 and discards the work | node "settlement failure" |
| T9 | The redeem fee rises between signing and settlement | The authorization is sized at the maximum fee; otherwise `AuthorizationTooSmall`, and the merchant is never paid less than `assets` | forge `testFuzz_authorizedValueCoversAnyFeeAtSettlement`, `test_tooLittleValueRevertsAndTheAuthorizationStaysUsable` |
| T10 | A rebase or a loss between signing and settlement | `value` is in balance units; `sync()` runs before sizing | forge `test_rebaseBetweenSigningAndSettlement`, `test_pendingLossIsAbsorbedBeforeMeasuring`; node "rebase between signing and settlement" |
| T11 | The reserve's vault cannot pay out | The redeem reverts with `InsufficientLiquidity`; nothing moves; the agent can retry later | forge `test_cashCrunchRevertsAndThePaymentGoesThroughLater` |
| T12 | Funds stuck in the router | The router sweeps all balances to the payer in every call | forge `testFuzz_routerEndsEveryPaymentEmpty` |
| T13 | Paying protocol contracts | `InvalidPayTo` on-chain and `invalid_pay_to` in the facilitator (a PROMPTS.md Phase 2 hard rule) | forge `test_recipientGuards`; node "payTo guard" |
| T14 | Burning the facilitator's gas with payments that will fail | Simulation before every send, done again inside the send queue | node "settlement failure" |
| T15 | Lost receipts reported as failures, so a payer is charged and gets nothing | Two-step send, `settlement_unconfirmed` with the hash, idempotent retry | node "lost receipt" |
| T16 | An agent overspends | Per-request cap, budget and payee allow list, enforced before signing | node "spend policy" |
| T18 | A chain read throws and a later request inherits the failure from `inflight` (the PHP2Shell class) | `verify`/`settle` catch; `settle` never rejects | node `state` 1–4 |
| T19 | `unconfirmed` grows without bound on a provokable error path | TTL of 2×`MAX_TIMEOUT` plus a 1,000-entry cap | node `state` 5 |
| T20 | One hung send parks every later settlement for ever | `cast` runs under `CAST_TIMEOUT_MS` (SIGKILL); waiting for a turn is bounded by `FACILITATOR_QUEUE_WAIT_MS` | node `state` 6 |
| T21 | A retry **broadcasts the same authorization twice** when a receipt is unreadable (found live: `sends == 2`, because `parseJsonOutput` took the first JSON object without checking it was that hash's receipt) | `receipt()` validates `transactionHash` and `status`; the `unconfirmed` record is dropped only on a status the chain actually reported | node `state` 7, 8 |
| T22 | One awkward request ends the process (Node 22 exits on an unhandled rejection) | The handler's error path cannot itself throw | node `state` 10, 11 |
| T17 | Key exposure | Agent keys are encrypted keystores with a password file. The facilitator uses anvil's unlocked account or a keystore. No key appears in arguments, environment or logs | by construction |

### Known limitations

- **Front-running a transfer authorization.** Anyone who sees a sUSD or USDC
  `transferWithAuthorization` payload can submit it first. The funds still go to `payTo`, but the
  facilitator's settlement then fails and the merchant answers 402 even though it was paid. This
  is a denial of service, not theft, and it affects all EIP-3009 x402 payments. Router payments
  can also be front-run, because `pay` is permissionless, with the same result. Mitigation, not
  built yet: on `nonce_used`, look for the `AuthorizationUsed` event and the transfer to `payTo`,
  and report success.
- **Cancellation.** A payer can call `cancelAuthorization` after verify. The merchant has then
  done the work and is not paid. This is standard x402 behaviour; keep paid handlers cheap or
  verify late.
- **Interoperability is untested.** The format follows the v2 spec as written in PROMPTS.md. No
  x402 SDK or public facilitator has been run against it, because the package registries were
  unreachable. Test it with the official SDKs before relying on it. Standard clients will not send
  `payload.spectrum.salt`, so they can use the sUSD and plain USDC paths but not the router.
- **One process, in memory.** The idempotency cache does not survive a restart, and settlements
  are serialized from one account, so throughput is about one per block. Production needs a
  persistent store and nonce management or several hot wallets. Two facilitators sharing one key
  would race.
- **Operational limits** (`audit/x402-state-audit.md`): `CAST_TIMEOUT_MS` (default 120 s) bounds
  any single `cast` invocation, and `FACILITATOR_QUEUE_WAIT_MS` (default 120 s) bounds how long a
  settlement waits for its turn in the send queue. Waiting is bounded; a send already in flight is
  not, because the only honest answer then is the one it produces.
- **No facilitator fee.** The operator pays the gas.
- **Live on Base Sepolia; the engine is not.** The rail settled real payments on the public
  chain. The v4 pool has no liquidity, so the oracle has recorded nothing and no rebase has
  occurred there. The workspace itself cannot reach Base RPCs; public-network work runs in CI. The Base Sepolia steps are in
  `DEPLOY_AND_TEST.md`.
- **Yield and regulation.** A balance that earns while it pays is the point of the rail. It is
  also what the GENIUS Act's yield prohibition targets for US payment-stablecoin issuers (see
  RUNBOOK_MAINNET.md §7). Get legal review before offering it in any jurisdiction, and in
  particular to US persons.

## Running it

```
script/rehearsal/x402.sh            # chain, deployment, router, servers, demo, 47 tests (about 1 minute)
script/rehearsal/x402.sh --serve    # same set-up, then keeps serving for agents
source x402/.tmp/current/env.sh
node x402/agent.mjs balance         # with AGENT_KEYSTORE=$X402_WALLETS/client
node x402/agent.mjs pay $MERCHANT_URL/api/v1/premium
```

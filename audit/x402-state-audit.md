# Cross-request state audit of the x402 facilitator

**Date** 22 October 2026 · **Scope** `x402/facilitator.mjs`, `x402/merchant.mjs`, `x402/lib/cast.mjs`
**Guarding tests** `x402/test/state.test.mjs` (11), `x402/test/stub.mjs`, additions to `x402/test/unit.test.mjs`
**Result** 43/43 Node tests green.

## Why this audit

On 21 October 2026 the PHP project patched **PHP2Shell** (CVE-2026-109618 / CVE-2026-109619,
CVSS 9.2). The headline is memory corruption, but the structural cause is not memory safety:

> A long-lived worker serves many requests from untrusted callers. Mutable state at global scope
> outlives any one request. An **error path** unwinds without restoring invariants, leaving a
> global referring to state that belonged to a dead request. A **later** request then reads that
> stale global as if it were live.

The Spectrum facilitator has that exact shape. It is a long-lived Node process, it takes requests
from untrusted merchants and payers, it moves value on-chain, and it keeps `settled`, `inflight`
and `unconfirmed` maps plus a shared `queue` promise chain alive across every request. The
question is not whether our bug looks like theirs; it is whether our error paths restore our
invariants.

Error paths are hard to reach against a healthy chain, so the audit added **`x402/test/stub.mjs`**:
a chain whose every method can be hooked. `createFacilitator({ chain })` already accepted an
override, so a test can make exactly one call throw, hang, or lose a receipt, deterministically
and in milliseconds, with a fixed clock.

## Findings

| # | Question | Verdict | Severity | Guarding test |
|---|---|---|---|---|
| 1 | What survives a throw from `check()` or a chain read? | **VULNERABLE** → fixed | High | 1, 2 |
| 2 | Can a rejected promise in `inflight` reach a later request? | **VULNERABLE** → fixed | High | 3, 4 |
| 3 | Does `unconfirmed` evict? | **VULNERABLE** → fixed | Medium | 5 |
| 4 | Can the send queue be stalled permanently? | **VULNERABLE** → fixed | High | 6 |
| 5 | Is anything published to a shared map before it commits? | **SOUND** | — | 9 |
| 6 | Can one request kill the process? | **VULNERABLE** → fixed | High | 10, 11 |

### 1 & 2 — a throw escaped into the shared maps

`check()` performs several chain reads. A throw from any of them propagated out of `verify()` as
a 500, and out of `settle()` as a **rejected promise that had already been stored in `inflight`**.
Every later request for the same `payer:nonce` joined that promise and inherited the rejection —
a failure belonging to one request being served as the answer to another. This is the PHP2Shell
shape precisely.

Both now catch. A read that threw is not a verdict on the payment, so the answer is in the
protocol's own shape (`unexpected_verify_error` / `unexpected_settle_error`, or the mapped custom
error) with the payer taken from the request. `settle()` never rejects, so nothing poisonous is
ever parked in `inflight`.

### 3 — `unconfirmed` grew without bound

`settled` evicts at `MAX_SETTLED`; `unconfirmed` had no bound at all, and it grows **on an error
path** — exactly the memory-exhaustion-from-a-provokable-error pattern. Bounded now at 1,000
entries with a TTL of `2 × MAX_TIMEOUT`. The TTL is sound because `check()` refuses any
`validBefore` more than `MAX_TIMEOUT + SKEW` past chain time, so an older entry can no longer
let a retry broadcast anything. The count cap is the backstop for a burst.

### 4 — one hung send parked every later settlement

Settlements are serialised through one promise chain so the facilitator's account has no nonce
races. A `cast` subprocess whose RPC stops answering never returns, so one hung send parked every
later settlement **for ever**.

Fixed at both levels. `cast` now runs under a timeout (`CAST_TIMEOUT_MS`, default 120 s,
SIGKILL), turning a hang into an ordinary transient failure the existing handling already covers.
And a settlement that has waited `QUEUE_WAIT` for its *turn* gives up with
`settlement_queue_timeout` — but only while still waiting. Once the send has started, a
transaction may be in flight and the only honest answer is the one it produces.

### 5 — SOUND

Nothing is published to `settled` before the send commits. `succeed()` runs only after a receipt
with a success status. A receipt that is unreadable, or that says neither success nor reverted,
**keeps** the `unconfirmed` record — that record is the only thing stopping the next retry from
re-running `check()` and broadcasting the same authorization twice.

### 6 — one request could end the process

An exception escaping the HTTP handler is an unhandled rejection, and Node 22 exits on one, so a
single awkward request could take the facilitator down for everyone. The handler's own error path
can no longer throw: it checks `headersSent`, falls back to ending the response, and swallows a
dead connection.

## Also fixed

`parseJsonOutput` took the first JSON object in `cast` output. A provider's log line can itself be
JSON, in which case the first object is not the answer asked for. It now accepts a predicate so a
caller can say which object it recognises; a receipt lookup uses it.

## Limitations

- State lives in one process's memory. Restart clears idempotency; two facilitators on one key
  would race. Production needs shared storage and either nonce management or several hot wallets.
- `QUEUE_WAIT` bounds waiting for a turn, not a send already in flight. That half is bounded by
  `CAST_TIMEOUT_MS`.
- The stub exercises the facilitator's reaction to a misbehaving chain, not the chain itself.

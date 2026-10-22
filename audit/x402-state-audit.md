# x402 facilitator: cross-request state audit

**Scope** `x402/facilitator.mjs`, `x402/merchant.mjs`, `x402/lib/cast.mjs`, `x402/agent.mjs`
**Frame** the PHP2Shell class (CVE-2026-109618 / 109619): a long-lived worker whose module-scope
mutable state outlives a request, an error path that unwinds without restoring the invariant, and
a later request that reads the leftover as if it were live.
**Date** 2026-10-22 · Node 22.22.0 · local anvil (chain 31337) with Spectrum and the pay router.

The facilitator is one process holding, across every request from untrusted merchants and payers:
`settled`, `inflight` and `unconfirmed` (Maps keyed by `payer:nonce`), a `queue` promise chain that
serialises transaction sends, and `dep` / `errors` / `from` / `forbiddenPayTo` captured once at
startup. The last four are immutable after boot and are not discussed further.

## How each finding was reproduced

`createFacilitator({ chain })` already took a chain override. `x402/test/stub.mjs` supplies one
whose every method can be hooked; the defaults describe a healthy chain on which every payment is
good, so a test overrides only the call it wants to fail. That makes the RPC-misbehaving paths —
a read that throws, a send whose receipt is lost, a send that never returns — reachable
deterministically, in milliseconds, with no anvil.

The probe used throughout is side-effect free:

```js
// does any shared map still hold (payer, nonce)?
const holds = async (payer, nonce) => {
  const r = await f.settle(payment({ payer, nonce, amount: '0' }));  // same key, different fingerprint
  if (r.errorReason === 'invalid_exact_evm_payload_authorization_nonce_used') return true;
  if (r.errorReason === 'invalid_payment_requirements') return false;  // check() rejected amount 0
  throw new Error('unexpected');
};
```

Every finding below was reproduced against the code as it stood, the test was watched to fail, the
patch applied, and the test watched to pass. The four tests that already passed before the patch
are the controls for the SOUND verdicts.

---

## 1. If `check()` or a `chain.*` call throws, what is left behind, and what does the next request with the same key see?

**Verdict SOUND for the state, VULNERABLE for the answer. Severity: low.**

`settle()` wraps the await of `work` in `try { return await work } finally { inflight.delete(key) }`,
so a throw out of `check()` does not leave an entry in `inflight`. Reproduced: with
`chain.timestamp` throwing once, `holds()` returned false immediately afterwards and the identical
request settled normally on the next attempt. Nothing is written to `settled` or `unconfirmed`
before the send, so neither is touched either. The next request with the same key sees a clean
slate and re-runs `check()` — which is correct, because a read that threw decided nothing.

What was wrong is the *answer*. `check()` only catches throws around the final `eth_call`
simulation; `chain.timestamp()`, `chain.bool()` and `chain.uint()` propagate. `verify()` and
`settle()` then rejected, the HTTP handler's catch-all turned that into **`500 {"error":"internal
error"}`**, and a merchant parsing `settled.success` saw an undefined field. A flaky RPC made the
facilitator look broken rather than the payment look unsettled, and (see §2) the rejection was
shared with every request that joined the same key.

*Patch* — `x402/facilitator.mjs`: `verify()` and `settle()` now catch a throw out of `check()` and
answer `unexpected_verify_error` / `unexpected_settle_error` in the protocol's own shape, with the
payer filled in from the request. Those reasons already existed for simulation failures; this
extends them to any read that threw. `settle()` therefore never rejects at all — see §2.

*Tests* — `test/state.test.mjs`:
`a chain read that throws leaves nothing behind, and answers in the protocol, not a 500`,
`the HTTP surface answers 200 with an x402 body when a chain read throws`.

## 2. Can a rejected promise parked in `inflight` be handed to a later request?

**Verdict VULNERABLE (bounded). Severity: low.**

Yes, while it is pending. `settle()` publishes `inflight.set(key, { fp, result: work })` before
awaiting, and a second request with the same key and the same fingerprint takes the early return
`if (prior && prior.result) return prior.result`. Reproduced: with the first request's chain read
parked on a gate and then throwing, **both** callers received the same rejection, and both became
500s.

It is bounded: the `finally` removes the entry whether `work` resolves or rejects, so a *settled*
rejection is never read by a request that arrives later — `holds()` was false immediately after.
There is also no cross-key deletion: only the request that created an entry ever writes or deletes
it, because every other request with that key takes an early return before `inflight.set`.

The structural fix is in §1: with `check()`'s throws converted to answers, `settle()` cannot reject,
so nothing rejected can be parked in `inflight` in the first place. That property is now asserted
directly against a chain whose every method throws.

*Patch* — as §1.
*Tests* — `a request joining one in flight never inherits a rejection`,
`settle never rejects, whatever the chain does`.

## 3. `settled` evicts at MAX_SETTLED; does `unconfirmed` evict at all?

**Verdict VULNERABLE. Severity: medium.**

It did not evict, ever. `unconfirmed.set()` runs on the `UnconfirmedError` path — a transaction
broadcast whose receipt could not be read — and `unconfirmed.delete()` ran only when a later retry
read the receipt successfully. A settlement nobody retries, or whose receipt stays unreadable,
stayed in the Map for the life of the process. Reproduced: after one unconfirmed settlement and
2,000 more with distinct keys, `holds()` on the first still returned true.

What an attacker who can provoke many unconfirmed settlements achieves is unbounded memory growth
in the one process that moves the money — the writeup's "unbounded growth of a shared structure
that turns an error into resource exhaustion". Each entry carries the full request fingerprint
(~0.5 KB), and there is no ceiling and no expiry. `settled`, by contrast, was already capped at
`MAX_SETTLED` and is safe to evict because the chain, not the cache, is the source of truth for a
consumed nonce.

*Patch* — `x402/facilitator.mjs`: `MAX_UNCONFIRMED = 1_000` and a TTL of `2 × MAX_TIMEOUT` seconds,
applied by a new `rememberUnconfirmed()` that re-inserts (so the Map stays in age order) and then
drops from the oldest end. The TTL is the safe one to choose: `check()` refuses any `validBefore`
more than `MAX_TIMEOUT + SKEW` past chain time, so an entry older than that covers an authorization
that can no longer be settled by anyone, and forgetting it cannot cause the re-broadcast of §5.

*Test* — `` `unconfirmed` is bounded: many lost receipts cannot grow it for ever `` (1,100 entries;
the first must be gone).

## 4. Can the `queue` chain be poisoned or stalled so every later settlement hangs?

**Poisoned: no. Stalled: yes. Verdict VULNERABLE. Severity: high.**

Poisoning is handled: `queue = run.catch(() => {})` means the shared chain never carries a
rejection, and `queue.then(fn, fn)` runs the next settlement whether its predecessor resolved or
threw.

Stalling was total. `serial()` returned `queue.then(fn, fn)` with no bound on the wait, and nothing
in `lib/cast.mjs` bounded a subprocess: `execFile` was called with `maxBuffer` but no `timeout`, and
`cast receipt` blocks until a transaction is mined. One send that never comes back — a stuck RPC
connection, a transaction the node never mines — parks **every later settlement for ever**.
Reproduced: with one send returning a promise that never settles, an unrelated later settlement for
a different payer had still not been answered after 3 seconds, and five queued behind it were all
silent. `/verify`, `/supported` and `/health` kept answering, so the facilitator looks alive while
no money can move and merchants' sockets accumulate.

*Patch* — two halves, because the two halves of the hang are different.

- `x402/lib/cast.mjs`: every `cast` invocation now carries a timeout (`CAST_TIMEOUT_MS`, default
  120 s, `killSignal: 'SIGKILL'`). A killed subprocess reports `timed out`, which `TRANSIENT`
  already matches, so reads retry and sends — which are never given retries — do not. A hung send
  becomes an ordinary `UnconfirmedError`, which the facilitator already knows how to carry.
- `x402/facilitator.mjs`: `serial()` now bounds the *wait for a turn*, not the work. A settlement
  that has waited `QUEUE_WAIT` (`queueWaitMs` option or `FACILITATOR_QUEUE_WAIT_MS`, default 120 s)
  gives up before `fn` runs, so nothing was broadcast for it, and `settle()` answers
  `settlement_queue_timeout` — a plain failure the payer can retry with the same authorization.
  Once `fn` has started it is never abandoned: a transaction may be in flight and the only honest
  answer is the one `fn` produces. The abandoned callback still runs as a no-op so the queue moves
  on, and the stub records that no second transaction was sent.

*Test* — `one stuck send does not park every later settlement for ever` (asserts the answer, the
empty `transaction` field, and that the abandoned settlement is never sent).

## 5. Is anything published to a shared Map before the on-chain action commits, such that a failure between the two leaves a lie cached?

**Verdict VULNERABLE, in the mirror image. Severity: high.**

No false *success* is cached. `succeed()` is only reached after `chain.send` has returned a receipt
with status 1, or after a retry has read such a receipt; a send that reverts or throws returns
`fail()` and writes nothing. Reproduced and kept as a control test.

The defect is the opposite: **the record that a transaction *was* committed is destroyed by an error
path that cannot tell "it failed" from "I could not read the answer."** The retry branch read

```js
const receipt = await chain.receipt(prior.hash);
unconfirmed.delete(key);                                   // <- unconditional
const ok = ['0x1', '1', 'true'].includes(String(receipt.status));
```

`chain.receipt` is `parseJsonOutput(cast receipt --json …)`, and `parseJsonOutput` returned *the
first JSON object in the output*, with no check that it was the receipt for that hash. `cast` prints
provider log lines next to the JSON — the existing unit test at `test/unit.test.mjs` exists because
of exactly that — and a log line in JSON form parses into an object with no `status`. Then `ok` is
false, the entry is deleted as if the chain had reported a revert, and the only record that the
authorization had already been broadcast is gone.

Reproduced end to end: a settlement whose receipt was lost, then a retry whose receipt parsed to a
log record, then a third retry — **the same authorization was broadcast twice** (`sends == 2`), and
the second broadcast was reported to the merchant as the settlement. On a real chain the EIP-3009
nonce makes the second transaction revert, so no money moves twice; what is lost is the facilitator's
gas, and the truth: a payment that succeeded is reported `invalid_transaction_state`, then
`nonce_used` for ever after, so the payer paid and the merchant never delivers. This is the writeup's
"shared slot reused without revalidating identity" together with "cleanup that only runs on the
success path", in the one place where the invariant is worth money.

*Patch* — both ends, so neither layer has to trust the other.

- `x402/lib/cast.mjs`: `parseJsonOutput(out, accept)` takes a predicate and returns the first JSON
  object the caller recognises; `makeChain.receipt(hash)` passes one matching `transactionHash`, and
  rejects a receipt whose `status` is not one the chain actually reports. Not knowing is now an
  error, not a verdict — and an error is what `send()` turns into `UnconfirmedError` and the retry
  branch turns into `settlement_unconfirmed`, which are the correct answers.
- `x402/facilitator.mjs`: the retry branch narrows its `try` to the read, then deletes the
  `unconfirmed` entry **only** when the status is positively `ok` or positively `reverted`. Anything
  else keeps the record and answers `settlement_unconfirmed`.

*Tests* — `an unreadable receipt never drops the record that a transaction was broadcast` (asserts
`sends == 1` throughout and that the final success carries the first hash),
`a receipt that really says reverted does release the key` (the key must be reusable: a revert
consumed nothing), `success is only published once the send has committed`, and in
`test/unit.test.mjs` the `parseJsonOutput` predicate against a JSON-formatted log line.

## 6. Does an unhandled rejection kill the process — can one crafted request take the facilitator down?

**Verdict SOUND as far as I could drive it; one latent path hardened. Severity: low.**

I could not craft a request that kills the facilitator, and I tried: a client that vanishes mid-
settlement, a body over the 64 KB limit, a body that stops halfway, a socket reset after the
request line, non-JSON bodies, and the request targets `/settle?a=%zz`, `//evil.example/settle`,
`/%`, `http://x/settle` and `*`. All were answered or dropped cleanly and the process stayed up.
This is tested **in a child process with no listener of its own**, so Node 22's own response to an
unhandled rejection — ending the process — is what decides the test, not the runner's handler.

The latent path is real and one line from being reachable. `sendJson` throws `ERR_HTTP_HEADERS_SENT`
if the headers are already out (demonstrated directly), and both servers' catch-alls called
`sendJson` unconditionally; a throw there escapes an `async` handler as an unhandled rejection,
which Node 22 turns into a dead process. Today nothing in either handler writes before the final
`sendJson`, so it is unreachable — but it is the kind of thing a later edit makes reachable, and the
blast radius is the whole payment rail.

*Patch* — `x402/facilitator.mjs` and `x402/merchant.mjs`: the catch-all answers only if
`!res.headersSent`, ends the response if it cannot, and does the whole thing inside its own
`try`/`catch`.

*Tests* — `awkward requests do not take the process down (no handler to hide them)` (child process,
exit code checked), `the server keeps serving after an awkward request`.

---

## Observations not patched

> **Both of the defects below were patched after this report was written** (47 tests, see
> `an oversized body gets a 413, not a reset connection` and the two ambiguous-broadcast tests).
> The two SOUND entries that follow them stand as written.

- **An oversized body gets no answer.** *(PATCHED.)* `readJson` calls `req.destroy()` in the same tick as the
  413 rejection, so the handler writes the response to a dead socket and the client sees
  `ECONNRESET`, not `413`. Confirmed with a raw socket. Cosmetic, no state consequence; fixing it
  properly means either draining an attacker's body or closing the connection deliberately, and
  neither belongs in a state-audit patch.
- **An ambiguous broadcast is still reported as unsent.** *(PATCHED: `makeChain.send` now reads
  the sender's nonce before broadcasting and again if the call fails. If it advanced — or cannot
  be read — the transaction may exist, so it raises `UnconfirmedError` with an empty hash and the
  facilitator answers `settlement_unconfirmed` and refuses to send again. Only a nonce that
  definitely did not move is reported as a plain failure.)* If `cast send --async` fails *after* the
  node accepted the transaction, `makeChain.send` throws a `CastError`, not an `UnconfirmedError`,
  and `settle` answers `unexpected_settle_error` with no hash — a transaction may exist that the
  facilitator has no record of. Unlike §5 this cannot be fixed from the error alone; it needs a
  lookup by the facilitator's own account nonce. Out of scope, worth a design note.
- **`merchant.mjs` holds no mutable state across requests.** `routes` is built once and is
  immutable, the market file is read per request, and the retry loop's state is local. Its only
  cross-request coupling is the facilitator's idempotency, which §5 covers. SOUND.
- **`agent.mjs` is a client**, one process per agent, not a shared worker. Its `spent` counter and
  ledger are per-process and not reachable by an untrusted caller. Out of the frame.

## UNVERIFIED

- That an attacker can *force* many unconfirmed settlements (§3) rather than relying on RPC
  flakiness. The growth itself is reproduced and the bound is cheap, but I have no reproduction of
  an attacker-driven path to `UnconfirmedError` on a healthy node.
- That any request reaches the `ERR_HTTP_HEADERS_SENT` path in the shipped handlers (§6). The throw
  and its fatality are demonstrated; reachability is not.

## Changed files

| File | Change |
| --- | --- |
| `x402/facilitator.mjs` | `check()` throws become protocol answers (§1, §2); bounded `unconfirmed` with `rememberUnconfirmed` (§3); `serial()` bounds the wait for a turn, `settlement_queue_timeout` (§4); retry branch only drops the `unconfirmed` record on a status the chain actually reported (§5); guarded catch-all (§6). New option `queueWaitMs`. |
| `x402/lib/cast.mjs` | Subprocess timeout on every `cast` invocation (§4); `parseJsonOutput(out, accept)` predicate and a `receipt()` that validates `transactionHash` and `status` (§5). |
| `x402/merchant.mjs` | Guarded catch-all (§6). |
| `x402/test/stub.mjs` | The hookable chain stub, the payment builder, the `holds()` probe. |
| `x402/test/state.test.mjs` | New: 11 tests, one or more per question. |
| `x402/test/unit.test.mjs` | `parseJsonOutput` predicate against a JSON-formatted log line. |

## Regression gate

```
cd /home/claude/spectrum/x402 && source .tmp/current/env.sh && node --test --test-concurrency=1 "test/*.test.mjs"
# tests 43   pass 43   fail 0      (32 pre-existing + 11 new)
```

Seven of the eleven new tests were watched failing against the unpatched files
(`git show HEAD:x402/facilitator.mjs` and friends) before the patch; the other four are the controls
for the SOUND verdicts and pass either way. The patched servers were also smoke-tested over HTTP
from the CLI entry points: `node x402/facilitator.mjs` + `node x402/merchant.mjs` +
`node x402/agent.mjs pay`, which settled a real 0.005 sUSD payment on the local chain.

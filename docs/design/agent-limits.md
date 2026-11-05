# What the x402 agent proves about its own spending

The MCP server (`x402/mcp.mjs`) pays through one agent (`x402/agent.mjs`). This note states what the
agent guarantees whatever the merchant does and whatever the model asks it to do, and proves each
statement from the code. For an agent that pays from an owner's path, the contract adds a second,
independent layer, proved on-chain (last section).

Notation: `spent` is the agent's running total in USD (6 decimals); `budget`, `maxPerRequest`,
`maxPerMinute`, `maxUndelivered` and `breakerSeconds` are its limits. An **instrument** is anything
the agent signs that can move money: a session voucher, an EIP-3009 authorization (USDC, sUSD, the
router) or a vault pay intent. Its **value** is the most it can move: a voucher's increment over the
previous one, an authorization's amount, an intent's assets.

## Lemma 0. Paid calls do not interleave, in one process or across many

One wallet is often paid from by several processes at once: Claude Desktop starts one server, and
every Claude Code or Cursor session starts another, all with the same `~/.x402-sessions`.

`pay()` runs `payNow()` under `withLock('pay', …)`, which chains every call in the process on the
previous one's completion, and inside it under `withLedger(…)`, which holds the wallet's lock file
(`ledger.json.lock`, created with `O_EXCL`, so exactly one process holds it) for the whole call and
first reads the ledger afresh from disk. `reconcile()` takes the same two locks. So from the checks
in `choose()` to the last bookkeeping after the merchant's answer, no other paid call and no
reconciliation runs in any process, and the call starts from everything every process has counted.
The ledger is written whole to a temporary file and renamed over the old one, so a reader never
sees half a ledger. A lock left by a process that died is broken once its holder is gone (or after
five minutes); a waiter gives up after two minutes, before anything is signed.

0.3.0 held only the in-process lock. Two processes each read the ledger once at start, so each
checked the budget against its own count, and each overwrote the other's file: two servers with a
$0.004 budget both paid a $0.0025 call, and the ledger kept one of the two payments.

## Theorem 1. Budget

At every moment, the money that has left the agent through its instruments, plus the money that its
unexpired instruments can still move, is at most `spent`, and `spent ≤ budget`.

*Proof.* Every instrument is added to `spent` before it leaves the process: a voucher in
`authorizeSession()` at signing; an authorization (for a version 1 or a version 2 offer alike) or a
first-sent vault intent by `record()` before the request carrying it is made. A re-sent vault intent
is the same instrument and is not added again.
Each addition of value `v` happens only after `refusal()` found `spent + v ≤ budget` in the same
paid call (Lemma 0; the reopening of a dead session checks again before signing). Meanwhile `spent`
can only fall, so the inequality still holds when `v` is added. `spent` falls only in
`reconcile()`, and only by the value of an authorization whose `validBefore` is earlier than the
chain's latest block time and whose token reports it unused (`authorizationState` false). Such an
authorization can never be used, because the token rejects it at any later block. A session can pay
out at most its latest voucher, the sum of the increments that were counted. ∎

Consequence: a merchant that settles and then answers an error, or never answers, is charged like
any other. The budget can no longer be exceeded through failures.

## Theorem 2. Spending speed

For each capped window W (60 s with `maxPerMinute`; 24 h, 7 days and 30 days with `maxPerDay`,
`maxPerWeek` and `maxPerMonth`), the instruments signed in any interval of length W have total value at
most its cap. The proof below is written for the minute and holds word for word for every W: the
window's entries are kept in the ledger for 30 days, the longest W.

In any 60-second window, the instruments signed have total value at most `maxPerMinute`.

*Proof.* Each signature records `(time, value)` in the rate window, which is kept in the ledger and
so is shared by every process paying from the wallet. It is preceded in the same call by the check
that the values recorded in the previous 60 s plus the new value are at most `maxPerMinute`
(`refusal()`; Lemma 0). Take any window and its last signature at time `t`: every signature in the
window lies in `(t − 60 s, t]`, which that check covered. ∎

The MCP server sets `maxPerMinute` to five calls' worth (`5 × maxPerRequest`) unless
`AGENT_MAX_PER_MINUTE` says otherwise. A looping model cannot spend a $1 budget in seconds at
$0.10 a call; it can spend at most $0.50 in a minute.

## Theorem 3. Merchants that take payment without serving

After `maxUndelivered` paid calls in a row to the same `payTo` that were not served (any status but
2xx, or no answer in time), the agent signs nothing for that `payTo` for `breakerSeconds`.

*Proof.* `noteOutcome()` runs once per paid call, after the answer and before the next call (Lemma
0). It counts unserved calls, resets the count on a served one, and once the count reaches
`maxUndelivered` it sets `until = now + breakerSeconds`. While `until` is in the future,
`refusal()` rejects every option paying that `payTo`, and an instrument is signed only for an option
that passed `refusal()`. ∎

So a failing merchant receives at most `maxUndelivered × maxPerRequest` per pause, $0.20 with the
defaults. The count is per `payTo`, so a merchant that rotates addresses is bounded only by Theorems
1 and 2. On a path it cannot rotate: only named merchants can be paid (last section).

## Theorem 4. No call hangs

Every request `pay()` makes carries `AbortSignal.timeout(T)` (`AGENT_TIMEOUT_S`, 30 s by default).
Every JSON-RPC request carries a 30 s timeout, with at most `3u + 2` attempts over `u` endpoints. So a
call ends after a bounded number of bounded waits, plus the calls queued before it (Lemma 0). A
timeout after an instrument was sent returns `status 0` with the instrument counted (Theorem 1), and
is reported as "charged, not delivered".

## Theorem 5. A retry never pays twice for one call

`pay()` throws only before any instrument has left. After the request carrying an instrument, every
path returns:
- the request's own failure is caught;
- the receipt is parsed by `receiptOf()`, which cannot throw, and a 402's error by `errorOf()`,
  which catches;
- `saveLedger()` catches;
- reopening a dead session either returns its result or returns the first failure.

The CLI retries only calls that threw; the MCP server retries nothing; and the model is told "do
not retry this URL now" after a charged failure. ∎

## Owner approval past a limit

When a payment would break a number the owner set (the per-call limit, the budget, or a minute, day,
week or month cap), the MCP server can ask the owner to approve that one payment through the MCP
client's own prompt (elicitation). Theorems 1 and 2 then hold for every instrument except those the
owner approved one by one; each approved one is still counted, so every later check sees it.

*Why the agent cannot approve itself.* The prompt is a request from the server to the client, which
shows it to the person; the model sees neither the prompt nor its answer, and no tool result or
model output can produce one. A refusal, a cancel, or no answer within 110 seconds is a refusal.
An approval never passes an allow list or a paused merchant, never exceeds `approvalMax`
(`AGENT_APPROVAL_MAX`, $5 by default), and is asked only for an option the wallet can fund.

## Theorem 6. No payment the chain would reject is sent

Before a USDC authorization leaves, the agent runs it against the token itself: an `eth_call` of
`transferWithAuthorization` with the signed values at the latest block. If the call reverts
(balance, signature, domain, expiry, a blacklisted address, a paused token), `pay()` throws before
the request carrying it is made, so by Theorem 5 nothing has left and nothing is counted. If the
chain cannot be read, `pay()` also throws: not knowing is not a verdict.

## The most the agent can lose

Without the owner, the agent can move at most the smaller of its USDC balance and the budget left
(Theorem 1), at most each window's cap per window (Theorem 2), and at most `maxUndelivered` calls to
a merchant that does not serve (Theorem 3). `x402_wallet` shows that ceiling. It is a bound that
holds by construction, for every merchant and every model, not an insurance promise with terms.

## The path: proved on-chain

For an agent with `AGENT_PATH`, its key holds nothing. Every session it opens is a step in
`X402SessionPaths._step`, which reverts unless:
- the payee is named on the path (`capOf > 0`);
- the amount is positive;
- `committedTo + amount ≤ capOf`.

`committed` never decreases, and only `goHome` (the owner) takes money anywhere else. So, whatever
the agent's key signs:
- each merchant receives at most its cap;
- the path pays out at most `bound`, the sum of the caps;
- nothing reaches an unnamed address.

This holds even against a client with none of the theorems above
([`self-approaching-condition.md`](self-approaching-condition.md)).

`x402_wallet` reads the proved ceiling live from the chain rather than restating it:
- `path(id)` gives what the path holds (`free`), `committed` and `bound`; the path can still pay out
  at most `min(free, bound − committed)`.
- For each merchant, `capOf − committedTo` (capped by that) is the most it can still receive.

The contract keeps its merchants only as a hash, so the wallet lists those named in
`AGENT_PATH_MERCHANTS` and those already paid.

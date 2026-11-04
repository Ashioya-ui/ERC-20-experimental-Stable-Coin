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

## Lemma 0. Paid calls do not interleave

`pay()` runs `payNow()` under `withLock('pay', …)`, which chains every call on the previous one's
completion. So from the checks in `choose()` to the last bookkeeping after the merchant's answer,
no other paid call runs. Only `reconcile()` may run meanwhile, and it only lowers `spent`.

## Theorem 1. Budget

At every moment, the money that has left the agent through its instruments, plus the money that its
unexpired instruments can still move, is at most `spent`, and `spent ≤ budget`.

*Proof.* Every instrument is added to `spent` before it leaves the process: a voucher in
`authorizeSession()` at signing; an authorization or a first-sent vault intent by `record()` before
the request carrying it is made. A re-sent vault intent is the same instrument and is not added again.
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

In any 60-second window, the instruments signed have total value at most `maxPerMinute`.

*Proof.* Each signature records `(time, value)` in the rate window, and is preceded in the same call
by the check that the values recorded in the previous 60 s plus the new value are at most
`maxPerMinute` (`refusal()`; Lemma 0). Take any window and its last signature at time `t`: every
signature in the window lies in `(t − 60 s, t]`, which that check covered. ∎

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

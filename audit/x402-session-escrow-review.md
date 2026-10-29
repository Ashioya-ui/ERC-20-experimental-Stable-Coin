# X402SessionEscrow security review

> Independent review by a separate Claude Opus 5.5 agent, 2026-10-29, of `src/vault/X402SessionEscrow.sol`
> at `e3a2494`, its tests, `script/vault/DeployX402SessionEscrow.s.sol`, and the session code in `x402/`.
>
> **Status: all five fixes are applied** (`test/vault/review/session/fixes/combined.patch`), together with
> the off-chain changes they need: the session id carries the expiry in `x402/lib/session.mjs`, the
> facilitator and the agent, and the facilitator reads `claimed` back from the chain after a
> best-effort `redeemMany`. The PoCs of the fixed findings were removed; their inverted guards
> (`test/vault/review/session/SessionGuards.t.sol`) run unconditionally, beside `SessionSoundness`,
> `OpenGriefing`, `UsdcControls` and the real-USDC fork file. The reviewer wrote the tests without
> running them (the session's toolchain policy); CI runs them. Paths under /tmp refer to the
> reviewer's scratch copies.

## 1. Summary

1. **The contract as reviewed must not be deployed.**
   - **S-1 (High)** breaks the promise the scheme rests on: "a voucher the merchant holds is good
     until expiry". Any agent could sign through an ERC-1271 contract, then void every voucher it
     handed a merchant with one transaction.
   - With **S-2 (Medium)**, two such signers make every `redeemMany` a facilitator sends revert, for
     every merchant in the batch.
2. **Fixes are free before deployment and impossible after.** All five are small; any change moves
   the CREATE2 address; nothing hard-codes it (the script computes it and x402 reads
   `deployments/<chainId>-session-escrow.json`).
3. **No theft path exists.** The contract has exactly two outbound transfers: `_redeem` pays
   `s.payee` and `_close` refunds `s.funder`.

| ID | Severity | Finding | Fix |
|---|---|---|---|
| S-1 | High | ERC-1271 signers can revoke vouchers the merchant already served against; block-dependent signers pass simulation and fail once included | ECDSA-only vouchers |
| S-2 | Medium | `redeemMany` is all-or-nothing; one entry sinks the batch, and the revert does not say which | Best-effort `redeemMany` |
| S-3 | Low | The session id omits expiry, so the funder can take the gasless open's id with a short-lived session | Put expiry in the id |
| S-4 | Low | `redeemable()` quotes a payout that `redeem()` refuses above the deposit | Make the view agree |
| S-5 | Info | The escrow can be its own payee, and those payouts are stranded | Reject payee == escrow |
| I-1 | Info | A gasless open can pass simulation and revert once included | Facilitator policy (in place) |
| I-2 | Info | What USDC blacklist and pause do to a session | Documented |
| I-3 | Info | Direct transfers stranded, gas snapshot drift, fork-test key, optional settlement window | Notes |

**The NatSpec claims:**

| Claim | Verdict |
|---|---|
| Payee never gets more than the deposit or the signed amount | Holds |
| Old vouchers never count twice | Holds |
| Funder cannot pull the deposit before expiry | Holds (except a degenerate session where funder == payee) |
| A held voucher is good until expiry | Broken by S-1 (fixed). Also depends on USDC (I-2) and on settling in a block at or before expiry |
| A stolen key can only overpay the named payee, up to the deposit | Holds per session. A hot key shared across sessions exposes the sum of their deposits, each only to its own payee |
| The escrow holds exactly the unclaimed balance of open sessions | Broken by S-5 (fixed) and by any direct transfer; the NatSpec now says "at least" |

## 2. Findings

### S-1 (High): vouchers from ERC-1271 signers are revocable

**Location:** `_validSignature`, reached from `_redeem`, `checkVoucher` and `isVoucherSignedBy`.

**The problem:** for a signer with code, a voucher was valid only while `signer.isValidSignature`
said yes, and that answer belongs to the signer's owner: a key rotation is one transaction on Safe,
Coinbase Smart Wallet or Kernel, and an EIP-7702 account that re-delegates voids every voucher it
signed in its delegate's wrapped format. No `isVoucherSignedBy`, `checkVoucher` or simulated
`redeem` can tell a revocable voucher from a permanent one.

**Scenario A, direct loss:** an agent opens a 10 USDC session whose signer is its smart account,
makes 50,000 calls at $0.0001 (each voucher passes the facilitator's checks), rotates the account's
key before the next settlement, and every held voucher reverts `InvalidVoucher()`. At expiry
`reclaim` returns all 10 USDC to the funder; the merchant gets nothing for 5 USDC of service.

**Scenario B, settlement shutdown (with S-2):** a signer whose answer depends on the block passes
every eth_call and fails one block later, and can burn the submitter's gas on failure. Two such
sessions of opposite block parity make every batch revert with an `InvalidVoucher()` that names no
session; honest merchants in those batches stay unpaid until their funders reclaim. Cost to the
attacker: two refundable deposits.

**Fix (applied):** vouchers are verified with ECDSA only. An EIP-7702 account still signs with its
own key, which no delegation can revoke. The in-repo agent is unaffected: its signer is always its
EOA key, even when the funder is an ERC-1271 wallet (USDC checks the funder's signature, not the
escrow). `test_anERC1271SignerCanSignVouchers` became `test_anERC1271SignerCannotSignVouchers`.

**Guard:** `X402SessionReview_GuardS1Test` (3 tests).

### S-2 (Medium): `redeemMany` was all-or-nothing

**Location:** `redeemMany` called `_redeem`, which reverts on any failure; `NothingNew`,
`AboveDeposit` and `InvalidVoucher` carry no session id.

**Scenario:** a facilitator simulates 50 entries, then the batch, then sends it. Between that
eth_call and the block one entry changes: its agent redeems its own latest voucher first, a payee
closes, a session crosses expiry, USDC blacklists a payee, or a signer's answer depends on the block
(S-1). All 50 revert, the gas is burned, and if it happens in the last block before expiry the other
merchants are never paid.

**Fix (applied):** each entry is tried on its own; an entry that cannot pay is skipped with a
`VoucherSkipped` event; if USDC refuses the transfer, the claim is rolled back and the session is
untouched. `redeemMany` returns how many entries paid. Single `redeem` stays strict. Off-chain: the
facilitator reads `claimed` from `session(id)` after each batch instead of marking every entry
claimed.

**Guard:** `X402SessionReview_GuardS2Test` (3 tests); `test_fork_S2_aBlacklistedPayeeIsSkippedAndTheRestPays`
on Circle's live USDC.

### S-3 (Low): the session id did not commit to expiry

**Scenario:** the funder signs a 30-day gasless open; the facilitator simulates it; the funder lands
first with its own `open()` on the same funder, payee, token, signer, salt and deposit but a 1-hour
expiry, which produced the same id. The facilitator's open reverts `SessionExists`, and every
voucher is valid on the 1-hour session. A facilitator that reads `SessionExists` as "someone
submitted the same open" and settles on the offered schedule is too late. (The in-repo facilitator
re-reads session state and enforces remaining life on every call, so it was not caught.)

**Fix (applied):** `sessionIdOf(funder, payee, token, signer, expiry, salt)`; off-chain in
`x402/lib/session.mjs`, the facilitator and the agent.

**Guard:** `X402SessionReview_GuardS3Test`.

### S-4 (Low): `redeemable()` disagreed with `redeem()` above the deposit

`redeemable(id, deposit + 100)` reported the whole deposit as payable while `redeem` reverts
`AboveDeposit` for the same amount; an integrator keeping only the highest voucher and checking it
with `redeemable` could hold a voucher that pays nothing. **Fix (applied):** the view returns 0 for
any amount `redeem` would refuse. **Guard:** `X402SessionReview_GuardS4Test`.

### S-5 (Info): the escrow could be its own payee

Each redemption became a self-transfer that still counted as claimed; the funds then belonged to no
session and could never move. Only a misconfigured `payTo` reaches it, and the facilitator already
forbids the escrow as `payTo`. **Fix (applied):** `EscrowAsPayee()`; the facilitator maps it to
`invalid_pay_to`. **Guard:** `X402SessionReview_GuardS5Test`.

### I-1 (Info): a gasless open can pass simulation and revert once included

Ways: the funder cancels its EIP-3009 authorization (anyone may submit the cancellation), spends the
nonce on a `transferWithAuthorization`, moves its balance away, takes the id first, an expiry exactly
on `MIN_DURATION` pushed under by the next block, or an ERC-1271 funder changing its answer. Cost:
facilitator gas only. The facilitator answers the first call only after the open is mined and
requires `expiry >= validBefore + MIN_DURATION`, so the merchant loses no served call; the
facilitator's per-payer failure budget bounds repeats. Test: `OpenGriefing.t.sol`.

### I-2 (Info): what USDC's controls do to a session

1. **Blacklisted payee:** `redeem` reverts while `checkVoucher` still says valid (it ignores token
   state; simulate `redeem` instead, as the facilitator does). The deposit is not stuck: the payee
   can `closeByPayee` without a voucher, or the funder reclaims at expiry. If the blacklisting is
   lifted before expiry, the same vouchers pay.
2. **Blacklisted funder:** `redeem` still works, but `closeByPayee` reverts on its refund leg, so the
   payee must use `redeem`; `reclaim` reverts and the remainder stays frozen while the blacklisting
   lasts.
3. **Pause spanning expiry:** every held voucher dies; the funder reclaims after the unpause.
4. **Blacklisted escrow:** all sessions freeze and no new session can open.

The escrow cannot and should not route around Circle's controls; a merchant limits exposure by
settling on a threshold. Tests: `UsdcControls.t.sol`, and the pause test in the fork file.

### I-3 (Info): other notes

1. **Direct transfers are stranded forever** (no owner, no sweep). A client that mistakes the 402's
   escrow address for `payTo` loses its payment. The NatSpec now says "holds at least".
2. **Gas snapshot drift:** with S-1 every failed signature check skips a cold EXTCODESIZE; regenerate
   `.gas-snapshot` after the fix.
3. **Fork-test key:** the existing fork test funds `vm.addr(0xF00D)` on live Base; a well-known key can
   carry an EIP-7702 delegation there, and USDC v2.2 would then check the open through ERC-1271.
   `vm.etch(funder, "")` after `createSelectFork` (applied).
4. **Facilitator error table:** `EscrowAsPayee()` → `invalid_pay_to` (applied).
5. **Optional settlement window** (not applied): allow `redeem` until expiry + W and `reclaim` only
   after that, closing the last-block race. The facilitator already stops accepting vouchers 900 s
   before expiry and redeems when expiry comes within twice that.

## 3. Merchant protection: the checks a facilitator must make

1. **First call:** recompute the session id from the open's terms; escrow, asset and `payTo` are the
   expected ones; price ≤ voucher #1 ≤ deposit; the authorization window is valid;
   `expiry ≥ now + max(merchant minimum, margin)`, `expiry ≥ validBefore + MIN_DURATION`,
   `expiry ≤ now + MAX_DURATION`; `isVoucherSignedBy` passes and the open simulates; serve only
   after the open is mined.
2. **If the open reverts `SessionExists`:** re-read every term before serving.
3. **Every later call:** `session(id)` has the right payee and token, is open, and has enough life;
   cumulative ≥ max(accepted, claimed) + price; simulate `redeem` itself, since `checkVoucher` ignores
   USDC's controls.
4. **After each batch:** read `claimed` from the chain.
5. **Never rely on `redeemable`** for acceptance.

`x402/facilitator.mjs` does all of these.

## 4. Surface-by-surface conclusions

- **Theft, lock-up, paying the wrong party:** only `_redeem` (to the payee) and `_close` (to the
  funder) move tokens. Deposits get locked only by USDC's controls (I-2) or direct transfers (I-3).
  Every state-changing entry point is `nonReentrant`; a reentering token is refused.
- **Facilitator griefing:** a front-run `openWithAuthorization` with the same authorization is
  harmless (the session is identical; the facilitator's copy reverts early with `SessionExists`).
  Only the funder can create its own ids (`open` uses `msg.sender`, the gasless path needs the
  funder's USDC signature, and a fake token yields a different id).
- **Signatures:** malleability is irrelevant (vouchers are keyed by cumulative amount, and OZ rejects
  high-s and non-65-byte signatures). The voucher digest binds the chain id and the contract address,
  so the same CREATE2 address on another chain gives no replay. Open and top-up authorizations are
  bound by USDC's domain and by `to = escrow`; the open nonce carries payee, token, signer, expiry and
  salt, and USDC's signature carries funder, escrow, amount and window. Ids are never reused.
- **Boundaries:** `redeem` works at t == expiry, `reclaim` only at t > expiry; MIN/MAX duration are
  checked at inclusion; the uint128/uint64 casts are safe; the exact-arrival check rejects
  fee-on-transfer tokens; third-party top-ups refund to the funder; `closeByPayee` closes cleanly
  after someone else redeemed its final voucher.
- **Agent and funder exposure:** the funder risks at most the deposit plus top-ups, and the payee
  receives at most the highest signed cumulative; the deposit can stay locked until expiry (at most
  365 days) unless the payee closes. A compromised hot key exposes the sum of its open sessions'
  deposits, each payable only to its own payee.
- **Deploy script:** correct: computes the CREATE2 address, is idempotent, checks the domain
  separator, writes the deployments JSON. Anyone can deploy the unfixed bytecode at its own address on
  any chain; trust only the address the script writes for the fixed build.
- **Gaps the review closed:** nothing tested USDC's controls, a batch with one failing entry, a
  revocable signer or the open's griefing paths; the invariant handler never calls `redeemMany`,
  `openWithAuthorization`, third-party top-ups, or a signer with code.

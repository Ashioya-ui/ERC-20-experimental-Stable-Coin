# The x402 `session` scheme

A payment scheme for x402 v2 in which an agent pays a merchant per call without a transaction per
call. The agent deposits once into `X402SessionEscrow`; each call carries a voucher, the cumulative
amount owed so far signed by the session's key; the facilitator redeems the latest voucher in one
transaction whenever it likes, always before expiry.

Why: settling one x402 payment on Base mainnet costs a median $0.00129 of gas, a median 10% of the
payment (68% at p90); half of all payments lose more than a tenth of their value to settlement
(`tools/measure-x402.py`, 7 days to block 53,227,444). A session settles 1,000 calls in one open and
one redemption: 250,651 gas in all on a Base mainnet fork, 251 gas a call.

Reference implementation: `src/vault/X402SessionEscrow.sol`, `x402/facilitator.mjs`,
`x402/merchant.mjs`, `x402/agent.mjs`, `x402/lib/session.mjs`. End to end:
`script/rehearsal/x402-session.sh` (a fresh chain) and `--fork` (Base mainnet).

## The escrow

One ownerless, immutable contract per chain, at the same CREATE2 address everywhere (salt
`keccak256("spectrum.x402-session-escrow.v1")`). A session is
`keccak256(abi.encode(funder, payee, token, signer, salt))` and holds:

| field | meaning |
|---|---|
| `funder` | deposits; takes back what is unclaimed after expiry |
| `payee` | the only address that can ever be paid from the session |
| `token` | the payment token (USDC) |
| `signer` | signs vouchers: normally the agent's hot key, not the funder's |
| `deposited`, `claimed` | `claimed <= deposited` always |
| `expiry` | between 1 hour and 365 days after opening |

A voucher is EIP-712 `Voucher(bytes32 sessionId,uint256 cumulative)` on the domain
`X402SessionEscrow`, version `1`, the chain id and the escrow's address. Redeeming `cumulative`
pays the payee `cumulative - claimed` and sets `claimed = cumulative`, so an old voucher never
counts twice and the payee can never receive more than the deposit or more than was signed.

## Wire format

The merchant's `PAYMENT-REQUIRED` offers:

```json
{
  "scheme": "session",
  "network": "eip155:8453",
  "asset": "<USDC>",
  "payTo": "<merchant>",
  "amount": "100",
  "maxTimeoutSeconds": 60,
  "extra": {
    "name": "USD Coin", "version": "2",
    "escrow": "<X402SessionEscrow>",
    "minRemainingSeconds": "900",
    "suggestedDeposit": "1000000"
  }
}
```

`amount` is the price of one call in token units. `minRemainingSeconds` is the shortest remaining
session life the merchant accepts a voucher on. `suggestedDeposit` is a hint.

The agent's `PAYMENT-SIGNATURE` payload:

```json
{
  "session": {
    "escrow": "<X402SessionEscrow>",
    "sessionId": "0x…",
    "cumulative": "300",
    "voucher": "0x<65-byte signature>",
    "open": {
      "funder": "0x…", "signer": "0x…", "expiry": "…", "salt": "0x…", "amount": "1000000",
      "validAfter": "…", "validBefore": "…", "authorization": "0x<signature>"
    }
  }
}
```

`open` rides along until the session exists on-chain. It is an EIP-3009
`ReceiveWithAuthorization` of `amount` from `funder` to the escrow whose nonce is
`openNonce(payee, token, signer, expiry, salt) =
keccak256(abi.encode(keccak256("SessionOpen(address payee,address token,address signer,uint64 expiry,bytes32 salt)"), payee, token, signer, expiry, salt))`.
The submitter cannot alter any term without invalidating the authorization; the funder pays no gas.

## Facilitator rules

`/verify` and `/settle` accept the voucher when all of these hold:

1. The escrow is the facilitator's own, the asset is USDC, `payTo` is not a contract of the rail.
2. If the session exists on-chain: its payee is `payTo`, its token is the asset, it is open, and it
   has at least `max(minRemainingSeconds, facilitator margin)` of life left (the reference
   facilitator's margin is 900 s).
3. `cumulative >= max(highest accepted, claimed) + amount`: every call adds at least the price.
4. One `eth_call` of `redeem(sessionId, cumulative, voucher)` succeeds. This checks exactly what will
   pay the merchant later: the signature, the deposit, expiry, and the token's transfer to the
   payee (a blacklisted payee or a paused token fails here, not at redemption).
5. If the session does not exist: `sessionId` matches the open's terms, `amount <= deposit`, the
   authorization's window is current, `expiry` leaves the merchant its minimum and satisfies the
   escrow's bounds whenever the authorization lands, `isVoucherSignedBy(signer, …)` holds, and the
   exact `openWithAuthorization` transaction simulates.

`/settle` serialises per session, submits the open if the payload carries one (the only
transaction before redemption), and answers paid only after the voucher is written to durable
storage. The answer's `transaction` is the open's hash on the first call and empty afterwards.

Redemption: whenever a session's unredeemed amount reaches a threshold, has waited long enough, or
its expiry comes within twice the margin. Each voucher is simulated alone first, so one session that
can no longer pay never sinks a batch; then one `redeem` or `redeemMany` per batch.

## Agent rules

- Sign vouchers in order, one call at a time per session; a signed voucher is spent, served or not.
- Reuse an open session while it has the price left and enough life; otherwise open a new one.
- Retire a session the facilitator reports `session_closed`, `session_expiring`,
  `session_above_deposit` or `unknown_session`, and pay that call from a new one.
- Trust only the escrow from the agent's own configuration, never one named in a 402.

## Guarantees and limits

- The merchant can never be paid more than the deposit or than the signer authorised.
- The funder cannot withdraw before expiry, so an accepted voucher is good until then; after expiry
  anyone may return the unclaimed balance to the funder. The payee may close early, settling a last
  voucher and releasing the rest.
- A stolen signer key can overpay only the named payee, only up to the deposit.
- A merchant served by two facilitators that do not share voucher state can be shown the same
  cumulative twice; run one facilitator per payee, or share its store.

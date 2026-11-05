# Pay on delivery: loss cover by construction

MetaMask insures agent payments it judges safe, up to $10,000 a month, under terms. This note
covers the same risk without insurance: an agent on an x402 session never pays for a call it did
not receive, and the most anything can take from the owner is a number the owner chose.

## The risk an insurer covers

Insurance pays out after a loss. An agent paying per call meets two kinds of loss:

1. **Non-delivery.** The merchant takes the payment and does not serve the call.
2. **Over-spending.** The agent pays for things the owner did not want.

The second is bounded today without any payout. The agent cannot move more than the smaller of its
balance and the budget left (Theorem 1 of [agent-limits.md](agent-limits.md)). It cannot move more
than each window's cap per window (Theorem 2). On a path, no merchant receives more than its cap,
and nothing reaches an unnamed address
([self-approaching-condition.md](self-approaching-condition.md)). This note removes the first.

## The scheme: vouchers one call behind

A session voucher is the cumulative amount owed. In the scheme as deployed, the voucher sent with
call n covers calls 1..n, so the merchant holds payment for call n before serving it. With
`extra.payOnDelivery: true` in the merchant's session offer, the voucher sent with call n covers
calls 1..n−1, the calls already served. The merchant serves call n on credit, and the next request
pays for it. When the session ends, the agent's final voucher covers every call it received.

Nothing on-chain changes. `X402SessionEscrow` redeems the largest cumulative voucher and returns
the rest of the deposit to the funder; whether a voucher pays for the current call or the previous
one is a convention between the agent and the merchant's facilitator. The facilitator accepts a
first voucher of 0 and, after that, vouchers that rise by the price per served call.

## Theorem 7. The agent never pays for a call it did not receive

On a pay-on-delivery session, everything the merchant can redeem is at most the price times the
number of calls the agent received.

*Proof.* The merchant can redeem only a voucher the agent signed, and redemption is cumulative: the
largest signed amount is all it can take. The agent signs the cumulative `price × k` only after it
has received k responses: the voucher with call n is `price × (n − 1)`, and the closing voucher is
`price × m` after m received calls. So every signed amount, and the largest, is at most
`price × (calls received)`. ∎

## Theorem 8. The merchant's risk is one call per session

The merchant serves at most one call that no signed voucher covers.

*Proof.* The merchant serves call n only on receiving the voucher for calls 1..n−1. So at any
moment, every served call except the latest is covered. ∎

A merchant therefore extends at most one call of credit per open session: a fraction of a cent for
the APIs agents pay per call. In return it gets buyers who cannot be cheated, so they can buy without
checking each seller. Insurance cannot offer that.

## What the owner can lose

|  | The owner's ceiling |
|---|---|
| A merchant that does not serve | 0 on pay-on-delivery sessions (Theorem 7); otherwise at most `maxUndelivered` calls per pause (Theorem 3) |
| An agent that over-spends | The smaller of the balance and the budget left, and each window's cap (Theorems 1, 2) |
| A stolen agent key on a path | Each merchant's cap, `|E|_1` in all, to named merchants only (the path contract) |
| Past a limit | Only payments the owner approves, one at a time, each at most `approvalMax` |

Every row is a bound the code or the contract enforces, and none depends on a claim being paid.

## Status

- Built and proved: the bounds in the table above, except the first cell.
- Next: `payOnDelivery` in the agent, `merchant.mjs` and `facilitator.mjs`, behind the offer
  flag, so existing sessions behave as before.

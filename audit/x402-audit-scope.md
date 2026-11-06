# x402 sessions: audit scope

## Scope

| Contract | Code lines | Base mainnet (8453) |
|---|---|---|
| [`src/vault/X402SessionEscrow.sol`](../src/vault/X402SessionEscrow.sol) | 281 | [`0x175925a679f389D905686D7E484b030Ccd7992CB`](https://base.blockscout.com/address/0x175925a679f389D905686D7E484b030Ccd7992CB) |
| [`src/vault/X402SessionPaths.sol`](../src/vault/X402SessionPaths.sol) | 298 | [`0xa9BF003a805ef14161aab2482eFd2a9C64e5f3fF`](https://base.blockscout.com/address/0xa9BF003a805ef14161aab2482eFd2a9C64e5f3fF) |

- Commit: `6becbfc` (main). Solidity `^0.8.26`. Dependencies: OpenZeppelin `SafeERC20`, `EIP712`, `ECDSA`,
  `ReentrancyGuardTransient`.
- Token in production: Circle USDC (FiatToken v2.2) on Base, `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.
- Out of scope, for context: the Node client, facilitator, merchant and MCP server in [`x402/`](../x402).

## What they do

**X402SessionEscrow.** A session names a funder, a payee, a token, the key that signs vouchers and an expiry, and
holds a deposit. The payee redeems the largest cumulative amount the signer signed (ECDSA only). After expiry anyone
can return the unclaimed rest to the funder; the payee can close early. Opens and top-ups are also gasless through
EIP-3009 `receiveWithAuthorization`. No owner, no fee, no upgrade, no pause.

**X402SessionPaths.** An owner (home) escrows a budget for an agent and names the payees it may pay, each with a cap.
The agent's key can only open escrow sessions to those payees, within those caps. Refunds from closed sessions come
back to the path. Home can end the path at any time and take back everything not committed. No owner beyond each
path's home, no fee, no upgrade.

## Actors

| Actor | Can |
|---|---|
| Funder | Open and top up sessions; get the rest back after expiry |
| Voucher signer (agent key) | Sign cumulative vouchers; on a path, sign steps that open sessions |
| Payee (merchant) | Redeem vouchers; close its session early |
| Facilitator | Relay signed opens, steps and redemptions; no rights of its own |
| Home (path owner) | Declare a path; end it with `goHome` |
| Anyone | `reclaim` after expiry; `collect` a closed session's refund into its path |

## Properties to check

**Escrow**
1. A payee never receives more than the session's deposit (`claimed ≤ deposited`).
2. A payee never receives more than the largest cumulative amount the signer signed for that session.
3. Before expiry, nothing returns to the funder except through the payee's own close; after expiry,
   `deposited − claimed` returns to the funder exactly once.
4. The escrow holds at least what open sessions owe, per token, and exactly that absent direct transfers
   (`invariant_escrowHoldsExactlyWhatOpenSessionsOwe`); no token is created or lost (`invariant_nothingIsCreatedOrLost`).
5. A voucher is bound to one session on one chain and one escrow (session id in the digest; EIP-712 domain).
6. `redeemMany` skips an entry that cannot pay without touching the others; a refused transfer restores the claim.
7. Fee-on-transfer and rebasing tokens are refused (`InexactTransfer`).

**Paths**
8. The agent's key opens sessions only to payees named at declaration, each within its cap, and never beyond the
   path's budget.
9. A step signature cannot be replayed (`StaleStep`), redirected (payee, amount and salt are signed) or used after its
   deadline.
10. No session outlives its path (`SessionOutlivesPath`).
11. Home can end the path at any time and receives everything not committed; refunds from closed sessions reach home.

## Known issues and accepted risks

1. The independent review of the escrow ([`x402-session-escrow-review.md`](x402-session-escrow-review.md)) found
   S-1 (High: revocable ERC-1271 vouchers), S-2 (Medium: all-or-nothing `redeemMany`), S-3 and S-4 (Low) and S-5
   (Info). All five are fixed in the deployed code. I-1 to I-3 are informational.
2. Vouchers accept ECDSA signers only, by design: a contract signer could revoke every voucher a merchant holds.
3. USDC's admin powers (blacklist, pause) can freeze a session's funds (review I-2).
4. A gasless open can pass simulation and revert once included (review I-1).
5. `X402SessionPaths` has had no independent review.

## Tests in CI

| Suite | What |
|---|---|
| `test/vault/X402SessionEscrow.t.sol` | 21 unit and fuzz tests (fuzz at 10,000 runs) |
| `test/vault/X402SessionEscrowInvariant.t.sol` | Invariants at 1,024 runs × depth 256 |
| `test/vault/X402SessionPaths.t.sol` | 14 tests |
| `test/vault/X402SessionEscrowBaseMainnetFork.t.sol` | Against live USDC on a Base mainnet fork |
| `x402/test/session.e2e.mjs` | 1,000 paid calls end to end, on a local chain and on a Base mainnet fork |
| Slither | Every push |

```sh
FOUNDRY_PROFILE=vault forge test --match-path 'test/vault/*Session*'
script/rehearsal/x402-session.sh            # local chain; add --fork with BASE_RPC_URL for a Base fork
```

## Questions for the auditors

1. Can any sequence of opens, top-ups, redemptions, closes and reclaims move more than a session's deposit, or move
   it to anyone other than its payee and funder?
2. Can a path step open a session to an unnamed payee, beyond a cap, or with funds of another path?
3. Is the `uint128` packing safe at the boundaries (`AmountOverflow`)?
4. Is the EIP-712 encoding of `Voucher`, `SessionOpen`, `SessionTopUp` and the path step unambiguous?
5. Can `collect` and `goHome` interleave with escrow closes to strand or double-count a refund?

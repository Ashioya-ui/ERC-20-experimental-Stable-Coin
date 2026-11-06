# Leash: an owner's declared end for any on-chain allocation

The owner's money stays in the owner's own contract. The owner declares an end: a target
allocation across assets or venues. Whoever runs the owner's agent (a keeper, a bot, an AI) may
move the allocation, but only along a self-approaching path to that end. Every move is checked
on-chain (Lemma 8.1, with a margin), and the end must stay reachable (`canAppend`).

## Guarantees, all proven

1. Total turnover is at most 3.1297 times the furthest the allocation goes from where it started
   (Theorem 4.2); 3.0472 times in the winding sector (Proposition 7.14); exactly the L1 distance
   when one position moves at a time (the x402 session path).
2. A stolen agent key can only finish the owner's plan, early.
3. Slippage below `ηm/8` cannot break the rule (Lemma A), and splitting a move into a TWAP is free
   (Lemma B); see `admissible-paths.md`.
4. A public efficiency score: turnover divided by the perimeter of the path's convex hull, at most
   1 (Theorem 3.1, Corollary 3.2), computed from the public path alone.

The software never holds or moves money on its own, never picks the end, and issues nothing.

## Against the stocks list

| Idea | The leash version |
|---|---|
| 1. Tokenized-stock SDK in apps | A leash SDK: any app lets users hand rebalancing of tokens they already hold to an agent |
| 3. Extra yield on held stocks | The owner's own positions move between venues on a leash, turnover bounded |
| 4. One-click leverage | Self-approaching deleveraging: a keeper may only cut leverage toward the owner's target |
| 5. Stock AMM pools | Range moves toward a declared band, churn bounded |
| 6. Agent with a public diary | Every move provably approaches the declared portfolio; the efficiency score is public |
| 7. Stock baskets for DAO treasuries | A treasury module: the DAO declares the basket, any keeper rebalances on the leash |
| 8. Weekend price feed | An update is accepted only within a margin of the interpolation of the trades before it |

## Build order

1. `SelfApproaching`: margin and sector (done).
2. A two-vault leash for sUSD's reserve (`reserve-allocation.md`): the first two-dimensional
   state, where Theorem 4.2 becomes load-bearing.
3. The same contract with any two ERC-4626 vaults, for any owner.

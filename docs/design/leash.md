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

## Built: `src/Leash.sol`

One contract serves both builds.

1. **sUSD's reserve.** The leash is itself an ERC-4626 vault with one shareholder, so
   `AutonomousTreasury` holds it as its vault unchanged. The stabilizer's vault allowlist is fixed
   at deployment, so a running sUSD system adopts a leash only through a deployment that lists it.
2. **Any two ERC-4626 vaults, any owner.** The owner deposits and withdraws; the planner (usually
   the owner) declares the end `(a, b)` in basis points of value and names the agent; the agent
   calls `move(a, b)`.

Each move must pass, on-chain:

1. Lemma 8.1 with margin η against every earlier segment (`canAppendWithMargin`);
2. the same test for the declared end after the move, so the agent can always finish in one move
   and every move brings the allocation closer to the end;
3. at most 32 points per plan.

The polygon of a plan is therefore self-approaching. Its length is at most 3.1297 times its
largest distance from the start (Theorem 4.2, Lemma 2.1). Closed with `E`, it still satisfies
(8.1), so its length is also at most 5.3332 times the start-to-end distance (Icking, Klein and
Langetepe, *Self-approaching curves*, Math. Proc. Cambridge Philos. Soc. 125 (1999)). By Lemma
B′ (`admissible-paths.md`), the agent may split a move into collinear pieces. `bound()` returns both numbers from the stored path. The agent cannot
withdraw. The owner's deposits and withdrawals go pro rata, so they leave the allocation where it
is. `stop()` (planner) redeems both vaults and removes the agent.

## Checks

| What | How |
|---|---|
| Compiles, 18,431 bytes runtime | `python3 script/leash/build.py`: solc 0.8.26+commit.8a97fa7a, the repo's settings; the binary's sha256 matches `ethereum/solc-bin` |
| The move rule | `python3 script/leash/rule.py`: every decision of the live run, in exact integers |
| Real transactions | `node script/leash/live.mjs`: deploys both leashes on Base Sepolia against the two live ERC-4626 vaults over Circle's test USDC, and checks every step against the chain |

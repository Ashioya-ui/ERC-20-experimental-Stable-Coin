# Phase 4 findings

Review of commit 522881c (2026-10-16). Severity uses the usual scale:
- **High:** direct loss of funds.
- **Medium:** loss of a core function, or of funds under plausible conditions.
- **Low:** limited impact, or impact only under unlikely conditions.
- **Info:** no security impact.

Each fix landed test-first. The failing test, then the fix, are in the commit named
`phase4(<ID>)`.

| ID | Severity | Status | Finding | Test |
|---|---|---|---|---|
| A1 | Medium | Fixed | The daily mint cap counted gross minting, and redemptions never freed it. A one-transaction mint-and-redeem round trip (flash-loan funded) blocked all other minting for the rest of the epoch. Measured at H = 0 with a 10,000 sUSD bootstrap cap: the round trip cost 1.98 USDC and left 1e10 wei of capacity, and a following 100 USDC mint reverted. Fix: redemptions in the epoch reduce `mintedInEpoch`, floored at 0, so the cap bounds net growth. | `test_mint_roundTripLeavesCapacityUnchanged`, `testFuzz_netGrowthPerEpochStaysCapped`, `invariant_expansionWithinCap` |
| A2 | Low | Fixed | `beforeInitialize` checked the PoolId and ignored `sqrtPriceX96`. Once the hook was deployed, anyone could initialise its one pool at any price in the next block; the deploy script's `initialize` then reverted and the pool started off-peg. Fix: the starting price must be within 50 bp of wsUSD's redemption value in the paired asset (both token orders, any decimals; new views `parPriceX96` and `priceWithinBand`). The post-deploy check asserts the band until the first recorded swap and reports a deviation after that, since trading moves the price. | `test_initialisationPriceMustBeNearPar` (red before the fix) |

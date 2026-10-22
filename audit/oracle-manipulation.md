# What does it cost to steer H?

Measured by `test/OracleManipulation.t.sol` against a real Uniswap v4 PoolManager, with the
mainnet oracle settings (10 wsUSD dust filter, `emaAlphaMax` 0.25, `tau` 1 h, 1 h staleness),
a 1 bp pool and 2-second blocks. "Before" is commit 522881c; "after" is the A6 fixes.

Reproduce: `forge test --match-contract OracleManipulationTest -vv`.

## What H controls

| Setting | At H = 0 | At H = 0.5 (neutral) | At H = 1 |
|---|---|---|---|
| Mint fee | 1 bp | 7 bp | 25 bp (50 bp before D4) |
| Redemption fee | 1 bp | 3.25 bp | 10 bp |
| Expansion cap (fraction of supply per epoch) | 11% (20% before Phase 5, P5-01) | 11% | 2% |
| Surplus buffer | **2.75%** (was 0.5%) | 2.75% | 5% |
| Rebase step | 1 bp | 0.75 bp | 0.5 bp |

H never touches backing. After D4 the buffer is floored at its neutral 2.75%, so steering H
downwards can no longer shrink the first-loss cushion; it can only fail to raise it.

## Before the fixes

| Target | Blocks | Wall time | wsUSD traded | LP fees (1 bp) | Resulting H | Mint fee on 1,000 USDC |
|---|---|---|---|---|---|---|
| H ≤ 0.05 (calm) | 33 | 66 s | 330 | 0.033 | 0.0375 | 1.07 bp (from 13.25) |
| H ≥ 0.95 (spiky) | 17 | 34 s | 6,140 | 0.614 | 0.962 | 46.4 bp |

Half a minute of trading and a few cents in fees moved the signal from end to end. Driving H
to 0 also pulled the surplus buffer down to 0.67%, paying out most of the first-loss cushion.

## After the fixes

Three changes:
1. **Time-weighted folds.** A fold carries `w = min(emaAlphaMax, dt / (dt + tau))`, where `dt`
   is the time since the previous fold. On Base, back-to-back folds get `w ≈ 0.00055`.
2. **Net flow per block.** Each slot holds `|sum of signed deltas|` for its block, so a round
   trip inside one block records almost nothing however large its legs.
3. **Buffer floor** (D4): `bufferRate(h) >= bufferRate(0.5)` for every `h`.

| Attack | Blocks | Wall time | wsUSD traded | LP fees | Resulting H |
|---|---|---|---|---|---|
| Packed, towards 0 | 150 (gave up) | 5 min | 1,500 | 0.15 | 0.460 |
| Packed, towards 1 | 150 (gave up) | 5 min | 39,310 | 3.93 | 0.529 |
| Patient, towards 0 | 9 folds | **24 h** | 810 | 0.081 | 0.0487 |

Packing no longer works. The loop gives up after 150 blocks (it is bounded so the test also
runs under `--isolate`); an earlier 400-block run reached only 0.401 towards 0 and 0.463
towards 1, because every extra fold inside the hour is worth almost nothing.

## After the independent review (S-04)

The review found a cheaper route that the net-flow change itself opened: a same-block round
trip of dust size nets to a zero slot, so eight of them read as a perfectly calm window
(H = 0) and one small one-way block among them as a spike (H = 1). With one such block every 20
minutes, each fold carried the full 0.25 weight, and H reached 0.03 or 0.97 in 3h20m for about
0.002 USDC per block. After an idle hour, one swap brought the steered value back. Its proof of
concept reproduced all of this on the reviewed code (`audit/logs/review-red-run-6c4bf58.log`).

The fix (`SpectralEntropyOracle.record`):
1. **Dust per block, not only per swap.** A closed block whose *net* flow is below the dust
   threshold takes no slot. Round trips no longer enter the window at all.
2. **Only such blocks keep the signal live.** Round trips cannot hold off staleness.
3. **A stale signal starts over:** an empty window and a neutral average, so nothing recorded
   before an idle hour can return in one swap.

`OracleSteeringTest` pins these: each test failed on the reviewed code and passes now.

## The residual: the patient attacker

Wall time cannot be bought, but it is cheaper than this report first said. Before the review it
measured an attacker who waited 3 hours between folds: 24 hours and 810 wsUSD to reach H ≤ 0.05.
A fold already carries the full 0.25 weight after 20 minutes, so the cheapest pacing is one
dust-sized one-way block every 20 minutes, under the 1-hour staleness horizon. Measured now with
that pacing: H ≤ 0.05 after 25 folds, 501 minutes (8.4 hours) and 330 wsUSD of volume (smoothed H
0.0375). The test alternates buys and sells of 10 wsUSD, so the window is not perfectly
flat and it takes more than the nine folds a flat window would need. A 3-hour pacing now restarts the signal every time and gets nowhere. What steering
H to 0 buys:
- the mint fee falls from 7 bp to about 1.1 bp, a discount on the attacker's own minting that
  costs the protocol fee income, not backing;
- the expansion cap rises from 11% to 20% of supply per epoch, which is bounded by the
  25,000 sUSD supply cap at launch anyway;
- the surplus buffer **does not move** (D4), so the first-loss cushion is untouched;
- the rebase step rises from 0.75 bp to 1 bp per hour, still below the 2 bp round-trip fee
  floor, so the mint → rebase → redeem sandwich stays unprofitable
  (`testFuzz_rebaseSandwichIsUnprofitable`).

Eight hours of visible, paced trading to save about 6 bp on minting is not a profitable attack
at the launch cap, and every effect is bounded. Steering H towards 1 instead needs one large
one-way block among small ones in every window; it raises everyone's fees (redemption to at most
10 bp, minting to at most 25 bp) and halves the daily cap, which is griefing, not theft: the
fees go to holders as surplus. H remains a heuristic, not a security boundary;
that is why it only prices access and rate-limits growth.

## Monitoring

Alert when the smoothed H sits below 0.1 or above 0.9 for more than an hour, or when
`foldWeight()` is at `emaAlphaMax` while the pool has traded recently: both suggest someone is
pacing folds deliberately. The runbook lists this under day-0 monitoring.

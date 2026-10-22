# Launch parameters, day-one yield and protocol capital (Phase 4, B8)

Sources: `sim/simulate.py` (an hourly model of the first year, 432 scenarios, every row in
`sim/results.csv`), `test/ProtocolCapital.t.sol`, and the loss front-running analysis in
`audit/threat-model.md` §5.1 (A9). Reproduce with `python3 sim/simulate.py` (standard library
only, about 4 seconds).

## The model

- **Launch.** Supply ramps from 0 to the 25,000 sUSD supply cap over 30 days. After that the
  cap binds and holders turn over a fixed share of supply per day (redeem and re-mint), paying
  both fees.
- **Reserve.** The idle buffer earns nothing; the rest earns the vault APY, compounded hourly.
- **Loss.** One realised vault loss on day 90, or none.
- **Rebase.** One attempt per hour. Supply may rise to `min(reserve / (1 + buffer(H)),
  reserve − protocolCapital)`, by at most the step rate per hour, and positive moves respect the
  churn budget. Losses are absorbed first, exactly as `sync` does.
- **H.** Constant 0, 0.5 or 1, or *adversarial*: the buffer and step of H = 1 (slowest
  distribution) together with the fees of H = 0 (least fee income), the worst of both for
  holders.
- **Grid.** Vault APY 2, 4, 6%; idle buffer 10, 15, 20%; the four H settings; loss 0, 0.5%,
  2%; protocol capital 0 or 5% of the cap; turnover 0 or 2% of supply per day.

What it leaves out: changing APYs, gas, MEV, the pool price of wsUSD, and correlated events.
It models the protocol's own accounting faithfully and nothing around it.

## Results

### Without protocol capital, holders wait most of a year

Days to the first distribution and the 12-month return of a holder from day one (no loss, no
turnover):

| Vault APY | Idle | H | Capital 0 | Capital 5% of the cap |
|---|---|---|---|---|
| 2% | 15% | neutral | never in year one, 0.000% | day 0, 2.203% |
| 4% | 10% | neutral | day 288, 0.745% | day 0, 4.226% |
| 4% | 15% | neutral | day 304, 0.555% | day 0, 4.009% |
| 4% | 20% | neutral | day 322, 0.366% | day 0, 3.793% |
| 4% | 15% | adversarial | never in year one, 0.000% | day 0, 3.530% |
| 6% | 15% | neutral | day 210, 2.129% | day 0, 5.810% |
| 6% | 15% | adversarial | never in year one, 0.000% | day 0, 5.250% |

Without capital, the surplus must first fill the 2.75% buffer (5% at H = 1) from yield on 85%
of the reserve, which takes about ten months at 4%. With capital covering the buffer, fees and
yield are distributable from the first hour. Holders also earn the yield on the capital itself
(only the capital is retained), which is why the 4% / 15% row returns 4.0% rather than
4% × 85% = 3.4%.

### H, turnover and the adversarial case (vault APY 4%, idle 15%, no loss)

| | H = 0 | H = 0.5 | H = 1 | adversarial |
|---|---|---|---|---|
| Capital 0, no turnover | day 311, 0.50% | day 304, 0.56% | never, 0% | never, 0% |
| Capital 0, 2% daily turnover | day 299, 0.63% | day 254, 1.24% | day 309, 0.90% | never, 0% |
| Capital 5%, no turnover | day 0, 3.71% | day 0, 4.01% | day 0, 4.43% | day 0, 3.53% |
| Capital 5%, 2% daily turnover | day 0, 3.85% | day 0, 4.73% | day 0, 6.87% | day 0, 3.67% |

An attacker who could hold H wherever it hurts holders most (the adversarial column) delays
nothing once capital is in place; it only trims the return, to 3.5% here.

### Losses on day 90 (idle 15%, neutral H, no turnover)

| Vault APY | Loss | Capital 0: negative rebase, 12-month return | Capital 5%: negative rebase, 12-month return |
|---|---|---|---|
| 2% | 0.5% | 1 of 0.085%, −0.085% | none, 1.667% |
| 2% | 2% | 1 of 1.591%, −1.591% | none, 0.852% |
| 4% | 0.5% | none (the surplus absorbed it), 0.053% | none, 3.464% |
| 4% | 2% | 1 of 1.257%, −1.257% | none, 1.828% |
| 6% | 0.5% | none, 1.618% | none, 5.255% |
| 6% | 2% | 1 of 0.928%, +0.086% | none, 3.593% |

With capital, no loss up to 5% of the cap lowers any balance, so (A9) exiting ahead of one
gains nothing. The cost moves to future yield: distributions pause until yield has rebuilt
the capital, so a 2% loss at 4% APY trims the year's return from 4.0% to 1.8%.

The churn budget deferred no distribution in any of the 432 scenarios: one loss followed by a
recovery stays well inside L ≤ 3.047 D.

## Protocol capital (implemented)

`SpectralStabilizer.contributeCapital(assets)`:
- anyone may call it, it is not pausable, and it mints nothing;
- the credited amount is the measured increase of the conservative reserve valuation (like a
  mint), after earlier donations are swept into surplus and any pending loss is absorbed;
- `protocolCapital` only ever grows, and nobody can withdraw it;
- `rebase` may raise supply only up to `min(reserve / (1 + bufferRate(H)), reserve −
  protocolCapital)`, so the capital is never distributed; the yield it earns is.

A plain donation would not do this: it is surplus, and is paid out to the earliest holders at
up to 1 bp of supply per hour.

Tests: `test/ProtocolCapital.t.sol` (12 tests: recording, donations not counted, not pausable,
never distributed, day-one flow, bank run, loss inside and beyond the cushion, front-running
with launch capital, pending loss first, and a fuzz test across H) and
`invariant_protocolCapitalNeverDistributed` in the invariant suite.

## Recommended launch values

| Parameter | Value | Why |
|---|---|---|
| `seedCapitalUSDC` | **1,250** | 5% of the 25,000 sUSD cap. No loss up to 5% of supply lowers a balance, so front-running it gains nothing (A9), and fees and yield reach holders from day one (D3). The deployer must hold it; the preflight refuses to start otherwise. Set 0 only on purpose. |
| `supplyCapSUSD` | 25,000 | Unchanged. When raising it, add capital to keep it at 5% of the cap, or accept the exposure in the threat model's §5.1 table. |
| `liquidityBufferBps` | 1,500 | 10% would add about 0.2% a year to holders and 20% cost about the same; 15% keeps redemptions instant through a fully lent-out vault. |
| `bootstrapCapSUSD` | 10,000 | Unchanged. |
| Mint-fee ceiling (D4) | **25 bp** (was 50) | H is attacker-steerable, so the range it controls is narrowed to what is worth defending: holding H at 1 now costs other minters at most 25 bp. |
| `emaAlphaMaxBps`, `emaTauSeconds`, `staleAfterSeconds` | 2,500, 3,600, 3,600 | From A6. |

## Griefing costs after the fixes

- **A1, the daily mint cap.** Round trips no longer use capacity. To block other minters an
  attacker must hold the net new supply itself. Filling the 25,000 sUSD supply cap costs the
  mint fee (17.5 USDC at neutral H, 2.5 USDC at H = 0) and the redemption fee on the way out
  (about 8 USDC), and ties up 25,000 USDC for as long as it lasts. It blocks minting, not
  redemption, and the admin can raise the cap. Liveness only; no funds at risk.
- **A6, steering H** (`audit/oracle-manipulation.md`). Holding H near 0 takes about 24 hours
  and 810 wsUSD of volume (0.08 USDC of LP fees at 1 bp) and buys a 6 bp discount on the
  attacker's own minting (7 bp to 1.06 bp after D4); the buffer cannot move. Pushing H towards
  1 raises other users' mint fee to at most 25 bp (was 50), tightens the daily cap to 2% and
  raises the buffer, which only adds safety.

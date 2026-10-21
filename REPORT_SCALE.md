# Spectrum at neobank scale (Phase 5)

Branch `phase-5-scale`, on top of `audit-freeze-1`. Nothing has been broadcast to any public
network.

**In one paragraph.** On 6 October 2026 EtherFi announced ether.fi USD, a stablecoin built on
Ethena's white-label service: Ethena runs the reserves, minting, redemption and compliance, and
EtherFi earns on deposits it already holds. EtherFi reports more than $300m of stablecoin
deposits, about $1bn of cumulative card spend since 2024 and more than 100,000 active cards
([Blockhead](https://blockhead.co/2026/10/07/ether-fi-launches-dollar-stablecoin-with-ethena-running-the-reserves)).
This phase asks whether Spectrum could carry a book that size. We ran it through the real
contracts and a year-long model, assuming a hostile H, illiquid vaults, losses and runs. The
contracts hold at $300m and beyond: no overflow up to $1 trillion, rounding under one wei per
holder, no failed card settlement in 90 days of flows, and every loss cut exactly what
the cushion could not cover. Three things broke at scale and are fixed, each with a test that
failed first. The worst was a vault migration out of an illiquid vault, which cut every balance
by 73% at once (P5-03). What scale really changes is economic: holders get no yield for about
seven months unless the operator posts first-loss capital of 2.75% of deposits ($8.25m), and
the operator earns nothing from the reserve. **Still required before the 25,000 sUSD cap
rises: an external audit.**

## 1. Findings and fixes

Full text in `audit/findings.md` (Phase 5 section); the red runs in
`audit/logs/phase5-red-run.log`.

| ID | Severity | What broke at scale | Fix | Test |
|---|---|---|---|---|
| P5-01 | Low (economic) | Steering H below neutral (about eight hours of paced trading) loosened the daily expansion cap from 11% to as much as 20% of supply: $57m of net minting a day instead of $33m at $300m. | H may tighten the cap but not loosen it: flat at 11% up to H = 0.5, down to 2% at H = 1 (the D4 rule for the buffer, applied to the cap). | `test_P5_01_steeringHDownDoesNotSpeedGrowth` (red: 55 ≠ 87 days) |
| P5-02 | Low (integration) | `redeem` is all-or-nothing. During a liquidity crunch a card program redeeming its balance reverts, and nothing told it exactly what would fit. | `SpectrumLens.maxRedeem(owner)`: exactly the largest redemption that goes through (fee, minimum, pending loss). `maxMintAssets()` and `liquidityRatio()` alongside it. | fuzzed: that amount pays, one wei more reverts |
| P5-03 | Medium | Migrating while the old vault can pay only part of the position quarantined the rest: at $300m with $50m of vault liquidity, $227m left the reserve and every balance fell 73% at once. Later recoveries go to whoever holds sUSD then. | `executeVaultMigration(maxLoss)` reverts beyond the bound and the proposal stays executable; the runbook passes 10 USDC wei. A larger bound is a deliberate choice for a vault that will not recover. | `test_P5_03_illiquidMigrationIsRefusedThenGoesThroughWhenLiquid` (red: 730,394 ppm cut) |

## 2. The numbers at $300m

Two sources, which agree where they overlap:
- `test/scale/NeobankScale.t.sol`: the real stabilizer, treasury and token against the mock
  lending vault, at $300m.
- `sim/scale.py`: the same rules hour by hour over a year (`python3 sim/scale.py`).

The base case is $300m of deposits, card spend of $600m a year (the run rate behind $1bn
cumulative), top-ups that keep deposits flat, 5% vault APY, a $1bn vault market at 85%
utilisation, and neutral H. Apart from EtherFi's figures, every input is an assumption, stated
in the script.

### 2.1 Yield: the first-loss capital decides when holders are paid

| Idle buffer | Protocol capital | First distribution | Holder return, year one | Yield lost to idle funds |
|---|---|---|---|---|
| 15% (launch setting) | $1,250 (launch setting) | day 227 | 1.66% | $2.20m |
| 10% | $1,250 | day 215 | 1.91% | $1.47m |
| 10% | $3m (1%) | day 136 | 2.92% | $1.48m |
| 10% | **$8.25m (2.75%)** | **day 0** | **4.71%** | $1.51m |
| 5% | $8.25m | day 0 | 4.96% | $0.76m |

Rebases distribute only what the reserve holds above supply × 1.0275 (the surplus buffer) and
above the capital. At launch the reserve equals supply. Without capital, yield must first fill
2.75% of supply, which is $8.25m and seven months at 5%. Capital equal to the buffer fills it
on day one. Holders then earn the vault rate on the invested part, plus the yield on the capital
itself, plus fees. The Foundry run measures 121 bp over 90 days (4.9% a year) with $8.25m of
capital and 10% idle.

### 2.2 Losses: exactly what the cushion cannot cover

A realised loss of the vault position, measured on the contracts with $8.25m of capital in
place (`test_vaultLossesAt300m`), and over a year in the model:

| Loss of the vault position | Reserve lost | Balances cut (contracts) | Year-one return (model, loss on day 90) |
|---|---|---|---|
| 1% | $2.7m | none | 3.76% |
| 3% | $8.1m | none | 1.87% |
| 5% | $13.5m | 1.81% | −0.03% |
| 10% | $27.0m | 6.43% | −4.88% |

The surplus and the capital take losses up to about 3% of the vault position. Up to that size,
leaving early gains nothing (A9). Beyond it, the excess is shared pro rata, and a holder who
sees the loss coming can still exit at par first.

### 2.3 Runs and liquidity

The treasury pays from idle funds, then from the vault up to what the vault's market can pay.
On the contracts (`test_runAt300mIsServedUpToLiquidityThenCompletes`), thirty $10m holders
try to exit while the market can pay $50m:
- 8 exits are paid in full ($30m idle plus $50m from the vault);
- the 9th reverts with `InsufficientLiquidity(available)` and the exact amount;
- a card settlement sized with `lens.maxRedeem` takes exactly the $82,008 left;
- once liquidity returns, everyone else exits at par minus the fee.

Nobody is ever paid less than par minus the fee: illiquidity delays exits, it does not cut them.

How much can leave the same day, as a share of supply, at 90% market utilisation (model):

| Idle | Vault market $500m | $1bn | $2bn |
|---|---|---|---|
| 5% | 21.7% | 38.3% | 71.7% |
| 10% | 26.7% | 43.3% | 76.7% |
| 15% | 31.7% | 48.3% | 81.7% |

A run of 30% of supply in one day ($90m):

| Idle | Market utilisation | Served in 24 h | Days to clear | Card settlements that failed meanwhile |
|---|---|---|---|---|
| 5% | 95% | 73% | 3.0 | $5.12m |
| 10% | 95% | 89% | 1.0 | $1.47m |
| 15% | 95% | 100% | within the hour | none |
| any | 85% | 100% | within the hour | none |

A vault that pays nothing for seven days costs no card settlement at 5% idle or more: idle funds
cover a week of spend. The real exposure is a run in a tight market, when card settlement
competes with exits for the same liquidity. The fix belongs to the operator, not the protocol:
a USDC settlement float of a few days of spend.

### 2.4 H at scale

H moves fees, the expansion cap, the buffer and the rebase step within fixed bounds. At
$300m (model, idle 10%, capital $8.25m, card spend $600m a year):

| H held all year | Holder return | Fees to holders | With capital at 5% ($15m) |
|---|---|---|---|
| neutral 0.5 | 4.71% | $0.61m | 4.93% |
| steered to 0.05 | 4.54% | $0.12m | — |
| steered to 1 | 2.96% | $2.09m | 5.20% |
| worst case (H = 0 fees, H = 1 buffer) | 2.30% | $0.12m | 4.54% |

- **Steering down** buys the steerer a lower mint fee, 1.06 bp instead of 7 bp: about $20k on a
  $33m mint. Since P5-01 it no longer buys a larger daily cap.
- **Steering up** is the bigger threat at scale. Holding H at 1 raises the buffer to 5% and
  pauses distributions while it fills. Keeping it up costs about a dollar a day in pool fees and
  gas: the measured patient attack, one small swap every 20 minutes
  (`audit/oracle-manipulation.md`). The yield is held back, not lost, but for a neobank a
  griefer could make the coin pay 3% instead of 4.7% for as long as they bother.
- **The defence is capital.** With capital at 5% of supply, the buffer is covered whatever H
  reads, and holders earn about the vault rate.

### 2.5 Onboarding: about three months to $300m

The daily expansion cap is net minting of max(10,000 sUSD, 11% of supply), and the 10,000
bootstrap is immutable. From launch, with maximal minting every day:

| H | audit-freeze-1 | Phase 5 |
|---|---|---|
| 0 to 0.05 (steered or calm) | 53–55 days | 87 days |
| 0.5 (neutral) | 87 days | 87 days |
| 1 | 374 days | 374 days |

A partner moving $300m in cannot do it in a week. That is the cap working as designed. A faster
planned migration would need a new governance control, and this phase does not add one.

### 2.6 Precision and size

- $1 trillion in and out with no overflow; the packed state uses `uint128`, far above USDC's
  supply.
- 10,000 holders through yield, rebases and a 5% loss: supply minus the sum of balances is 5,001
  wei. Nothing in the protocol iterates over holders, so 100,000 cost the same.
- 2,160 consecutive hourly rebases at $300m all distributed; the floor held every hour.

### 2.7 The deployed system at $300m

`script/rehearsal/scale.sh` first runs the mainnet deployment script on the local Base-shaped
chain (Circle's FiatToken v2.2 as USDC, a real v4 PoolManager). It then drives the deployed
contracts with real transactions (`rehearsal/scale.log`):
- **Ramp.** The admin raises the supply cap to 400m sUSD. Minting `lens.maxMintAssets()` each
  day, deposits pass $300m on day 87 at neutral H, as the model and the tests predict.
- **No capital.** 24 hours of card spend ($1.64m settled) on the launch capital of 1,250 USDC:
  no rebase distributes, because the 2.75% buffer must fill first.
- **With capital.** The operator posts 2.75% of supply, $8.85m. The last mint took supply to
  $322m, so capital has to track supply, not a round number. Every hourly rebase then
  distributes:
  - 9.2 bp on the first day: the ramp's mint fees, held back until then;
  - 1.19 bp on the second day, 4.3% a year at the mainnet setting of 15% idle.
- **Crunch.** The vault's market can pay $50m:
  - a $60m exit is paid in full;
  - a $100m exit reverts with `InsufficientLiquidity` and the $39.7m available;
  - `lens.maxRedeem` sizes an exit to exactly that, leaving 0 USDC wei;
  - card settlement then waits (`maxRedeem` returns 0) until liquidity returns.
- **Migration.** With the vault able to pay only $50m, a migration is refused with
  `MigrationLossTooHigh`; $181.5m would have been quarantined, and the index does not move.
  Once the vault is liquid, the same call with a 10 USDC wei bound migrates without a cut.
- **Check.** The post-deploy check passes on the scaled system.

## 3. What a $300m deployment would need

| | Launch setting | At $300m | Why |
|---|---|---|---|
| Protocol capital | 1,250 USDC | $8.25m (2.75%); $15m (5%) to be immune to H griefing | §2.1, §2.4 |
| Idle buffer | 15% | 10% with a $1bn+ vault market; 15% if the market is under $500m | §2.3; each 5% costs about $0.75m a year |
| Card settlement float | — | 3–7 days of spend in USDC, held by the card program | §2.3 |
| Vault position | — | no more than about a quarter of the vault market's depth; check live utilisation | §2.3 |
| Supply cap | 25,000 sUSD | raised in steps behind the external audit | |
| Keepers | hourly `rebase`, `rebalanceReserve` as needed | the same; alert on `liquidityRatio()` below 25% and on vault utilisation above 90% | |
| Migration | runbook | `execute-migration` with the default 10 USDC wei bound | P5-03 |

## 4. Spectrum against the Ethena white-label model

| | ether.fi USD (Ethena white-label) | Spectrum sUSD |
|---|---|---|
| Reserve | not disclosed; the service offers USDe (hedged crypto), USDtb (issued by Anchorage Digital Bank, backed by traditional reserve assets) or other stablecoins | USDC, part idle, the rest in one allowlisted ERC-4626 lending vault (Aave or Morpho) |
| Who runs mint, redeem, reserves | Ethena | immutable contracts; anyone can mint and redeem on-chain, instantly up to the vault's liquidity |
| Compliance | Ethena | none at the token level; it would sit in the operator's app and card program |
| Who earns the reserve yield | the partner (EtherFi), split undisclosed | holders, by rebase; the operator earns nothing |
| Main risks | funding rates and derivatives venues if USDe-backed; custody and bank risk if USDtb | the lending vault: losses, liquidity, curator; first-loss capital decides how much holders feel |
| Trust | Ethena's operations | a Safe that sets caps and the idle buffer; a 7-day timelock and a two-vault allowlist for the reserve; redemption cannot be paused |

What this means for a neobank weighing Spectrum:
1. **It pays holders, not the operator.** EtherFi's model is to earn on balances it already
   holds. Spectrum gives the operator no cut of the reserve's yield.
   - A share of each distribution for an operator address would be a small change to `rebase`,
     but it is a change to the token's economics. It is not built here.
   - It also bears on regulation: the US GENIUS Act bars issuers of payment stablecoins from
     paying holders yield. Take counsel before either design.
2. **It has no compliance layer.** Freezing and screening would live in the operator's app
   and card program, not in the token.
3. **One vault.** At $300m the reserve should be split across venues.
   `docs/design/reserve-allocation.md` sketches how, and recommends a turnover cap first.
4. **It is unaudited.** Phase 4 and Phase 5 are internal hardening plus one independent review.

## 5. Not done

- **External audit:** required before the cap rises past 25,000 sUSD (`audit/README.md` is the
  package).
- **Base Sepolia rehearsal and the live Base fork suite:** both need your keys and RPC
  (`DEPLOY_AND_TEST.md`).
- **The vault-market assumptions:** depth, utilisation and how fast liquidity returns after a
  spike are assumptions in `sim/scale.py`. Check live Aave and Morpho figures before sizing the
  idle buffer.
- **Not built:** a multi-vault allocator and an operator revenue share.

## 6. Verification

| Check | Result |
|---|---|
| `forge test` | 231 pass, 1 skipped (the live Base fork suite, which needs an RPC) |
| `forge test --isolate` | 231 pass, 1 skipped |
| `test/scale/NeobankScale.t.sol` | 12 pass: the scale runs, the three findings' tests, and fuzzing of the new lens views (1,000 runs each) |
| `script/rehearsal/run.sh` | REHEARSAL PASSED: the mainnet script on the local Base-shaped chain, with the new migration call |
| `script/rehearsal/scale.sh` | SCALE REHEARSAL PASSED (`rehearsal/scale.log`) |
| `python3 sim/scale.py` | the tables in §2; every row in `sim/scale.csv` |
| Halmos (cvc5) | the expansion-cap checks pass, including the new `check_expansionCapNeverAboveNeutral` for every `uint256` input (`audit/logs/halmos-phase5-expansion.log`); 17 properties proven in all |
| Slither (`make analyze`) | 0 results with `--fail-medium`; the triage re-recorded for moved lines (`audit/slither.md`) |
| Gas snapshot | regenerated (`.gas-snapshot`); CI checks it |
| Sizes | `SpectralStabilizer` 22,045 bytes (2,531 free of 24,576); `SpectrumLens` 8,889; every contract keeps more than 1,024 bytes free |

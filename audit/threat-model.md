# Threat model

Scope: `src/` (SpectralStabilizer, SpectralToken, AutonomousTreasury, SpectralEntropyOracle,
SpectralHook, WrappedSUSD, SpectrumLens, SpectralMath, SpectralPolicy, SelfApproaching), the
deployment library and scripts
in `script/`, and the GitHub Actions workflows. Baseline: commit 522881c (2026-10-16); the
Phase 4 changes are listed in `audit/findings.md`, and this file describes the system after
them.

## 1. System in one paragraph

Users deposit USDC through `SpectralStabilizer.mint` and receive sUSD (`SpectralToken`), a
rebasing ERC-20 whose balances are `shares × index`. The USDC sits in `AutonomousTreasury`:
an idle buffer (15% at launch) plus shares of one ERC-4626 vault (Aave waBasUSDC). Holders
redeem 1:1 minus a small fee at any time, never pausable. A keeper calls `rebase` to pay out
surplus above a buffer (at most 1 bp of supply per hour) and `sync` to absorb a realised vault
loss by lowering the index. A Uniswap v4 hook records wsUSD swap flow into
`SpectralEntropyOracle`, which turns it into a bounded signal H that moves fees, the daily mint
cap and the surplus buffer within fixed ranges. H never touches backing.

## 2. Actors, powers and trust

| Actor | Can do | Trusted for |
|---|---|---|
| Holder | transfer, permit, EIP-3009 authorisations, redeem (never pausable) | nothing |
| Minter | deposit USDC and mint, subject to the supply cap and the daily cap | nothing |
| Swapper / LP | trade in the one wsUSD/USDC pool, which feeds H | nothing: H is treated as attacker-chosen |
| Keeper (anyone) | `rebase`, `sync`, `rebalanceReserve`, `recoverLegacy` | liveness only; every call is permissionless and bounded |
| x402 facilitator | submit someone's EIP-3009 authorisation and pay its gas | nothing: it can only execute exactly what was signed |
| Admin Safe (`DEFAULT_ADMIN_ROLE`) | set the supply cap and the liquidity buffer; propose a vault (from the allowlist, after Phase 4) and execute it after 7 days; grant and revoke roles (two-step, 3-day delay after Phase 4) | not to take funds: no admin path sends reserve funds to an address it chooses Executing a migration while the old vault is illiquid quarantines shares and cuts the index for holders who could not leave first (review S-05.4): the runbook allows it only as an announced emergency, and the guardian cancels otherwise. |
| Guardian (`GUARDIAN_ROLE`, also held by the admin) | pause and unpause minting and rebasing; emergency exit from the vault to idle funds; cancel a pending migration | bounded: cannot pause redemption or loss absorption, cannot move funds out |
| ERC-4626 vault | holds about 85% of the reserve | solvency, an honest `previewRedeem`, and liquidity through `maxWithdraw` |
| Uniswap v4 PoolManager | calls the hook | correct v4 semantics (audited deployment) |
| USDC issuer (Circle) | can pause USDC or blacklist an address | not to blacklist the treasury or stabilizer: if it does, minting and redemption stop |
| Deployer key | sends the deployment transactions | only during deployment; it ends with no role. After Phase 4, wiring is fixed in constructors, so the key has no setter to race |
| CI (GitHub Actions) | runs tests; the deploy workflow broadcasts with the deployer key | after Phase 4 the key reaches only the broadcast step; actions are pinned by commit |

## 3. Assets

1. The reserve: idle USDC in the treasury and vault shares.
2. Supply integrity: `index`, shares and the reserve floor (`reserve >= supply` after every
   protocol action).
3. The entropy signal H and the policy settings it moves.
4. Governance roles (admin, guardian).
5. Liveness: minting, redemption, loss absorption, rebasing.
6. Deployment integrity: which addresses the token, treasury, oracle and hook trust.
7. Secrets: the deployer key, the RPC URL and the Etherscan key in CI.

## 4. External entry points and their checks

| Contract.function | Caller | Checks | Notes |
|---|---|---|---|
| Stabilizer.mint | anyone | not paused; `nonReentrant`; loss synced first; credited value is the measured increase in reserve value; minimum amount; slippage; net daily cap; supply cap; floor at the end | rounding and vault entry fees fall on the minter |
| Stabilizer.redeem | holder | `nonReentrant`; never paused; loss synced first; minimum, or a whole balance of any size (paid from idle funds or the vault alike; a balance under one wei of USDC, 1e12 sUSD wei, pays out nothing and reverts, and right after a loss sync a dust redemption the vault serves can revert on the floor check by a wei or two of vault rounding, review S-05.2); slippage; floor at the end | idle funds first, then the vault within `maxWithdraw` |
| Stabilizer.rebase | anyone | not paused; once per hour; loss synced first; step ≤ min(surplus above the buffer and protocol capital, supply × stepRate(H)); churn budget; floor | |
| Stabilizer.sync | anyone | never paused | lowers the index so supply = reserve |
| Stabilizer.rebalanceReserve | anyone | treasury acts only outside a 1% tolerance band | then re-syncs |
| Stabilizer.contributeCapital | anyone | measured increase in reserve value | non-distributable first-loss capital (Phase 4, B8) |
| Stabilizer.pause / unpause / emergencyExitVault / cancelVaultMigration | guardian | role | |
| Stabilizer.setSupplyCap / setLiquidityBuffer / proposeVault / executeVaultMigration | admin | role; vault asset matches and is allowlisted; 7-day timelock | |
| Token.transfer / transferFrom / approve / permit | holder | balances, allowances, EIP-712 signatures (ECDSA or ERC-1271) | |
| Token.transferWithAuthorization / receiveWithAuthorization / cancelAuthorization | anyone / payee | validity window, unused nonce, signature | |
| Token.mint / burn / setIndex | stabilizer only | immutable stabilizer address | |
| Treasury.recoverLegacy | anyone | only redeems quarantined shares into idle funds | |
| Treasury fund-moving functions | stabilizer only | immutable stabilizer address; `nonReentrant` | |
| Oracle.record | hook only | immutable hook address; dust filter per swap and per block's net flow; a stale signal starts over (review S-04) | |
| Hook.beforeInitialize | PoolManager | only the one allowed PoolKey; starting price within 50 bp of wsUSD's redemption value (Phase 4, A2) | |
| Hook.afterSwap | PoolManager | records the signed delta of wsUSD; an oracle failure with revert data is logged, out of gas reverts the swap | |
| WrappedSUSD (ERC-4626) | anyone | OpenZeppelin virtual shares, dead-share seed at deployment | |

## 5. Threats considered

| Threat | Where handled |
|---|---|
| Mint → rebase → redeem sandwich | step ≤ 1 bp < 2 bp minimum round-trip fee; fuzz test `testFuzz_rebaseSandwichIsUnprofitable`; the attacker invariant (A10) |
| Steering H (wash trading, spikes) | bounded ranges; time-based EMA and per-block net flow (A6); H cannot lower the surplus buffer below neutral (D4); the invariant handler sets H adversarially |
| Griefing the daily mint cap with round trips | net accounting (A1) |
| Front-running pool initialisation | price band in `beforeInitialize` (A2) |
| Racing the deployment wiring | constructor wiring with predicted addresses; the script aborts on any mismatch (A3) |
| CI dependency stealing the deployer key | key only in the broadcast step; pinned actions (A4) |
| Admin moves the reserve to a malicious vault | immutable allowlist plus a 7-day timelock in which holders can exit (A5) |
| Vault loss | `sync` absorbs it pro rata; the surplus and protocol capital absorb small losses first; loss front-running: section 5.1 (A9) |
| Vault illiquidity (bank run) | idle buffer; `InsufficientLiquidity(available)`; emergency exit; quarantine of unredeemable shares on migration |
| Donations and inflation attacks | donations become surplus; measured-increase crediting; wsUSD virtual shares plus dead shares |
| Reentrancy, including read-only | `nonReentrant` on every state-changing path; the index changes only inside stabilizer calls; the only callbacks are to the vault and PoolManager, both trusted |
| Rounding | mint rounds shares down, burns and transfers round up; minimum amounts keep the fee above worst-case vault rounding (A7) |
| Oracle gas griefing | the worst-case `record()` cost is measured and bounded (A8, B4: 37,261 gas for a cold window close since the state packing); a deliberate gas starvation reverts the swap |
| Batched deposits leave funds idle | mints deposit only once idle funds exceed the target by 1% of the reserve; idle USDC still counts in the reserve, so nothing is mis-valued; the cost is at most 1% of the reserve earning nothing for a while; rebalance and migration still deposit everything above the target |
| Dust shares in an old vault block later migrations | shares worth at most `LEGACY_DUST_ASSETS` (0.001 USDC) are not quarantined and do not keep `legacyVault` set (A12) |
| The churn budget relying on an unproven constant | since Phase 4 it uses Theorem 4.3's proven bound; it is a design rule in any case, and no safety property depends on it. The step itself is proven never to revert, so it cannot block loss absorption (Halmos, `audit/formal.md`) |
| Protocol capital drained or distributed | it only grows (`contributeCapital`), has no withdrawal path, and rebases stop at reserve − capital (B8) |
| USDC blacklisting or pause | out of the protocol's control; documented in the runbook |
| Base sequencer downtime | no transactions while it is down; the oracle reads neutral after `staleAfter` |

### 5.1 Loss front-running (A9)

A holder who learns of a vault loss before it is realised on-chain can redeem at par first.
Once the loss is visible in the vault's share price, `sync` runs first in every mint, redeem and
rebase, so nobody can exit through the stabilizer at the old price after that. The wsUSD pool is
the exception until someone calls `sync`: wsUSD's share price still reflects the old index, so
selling wsUSD into the pool exits at the pre-loss price and the pool's liquidity providers carry
the difference (review S-05.3). `sync` is permissionless and the runbook's keeper calls it as
soon as a loss is visible (E4). On Base the sequencer keeps no public
mempool, so the realistic case is not a mempool race but information that arrives before the
loss lands: an exploit in progress, disclosed bad debt, a governance decision.

**What it shifts.** With supply `S`, surplus `U = reserve − supply` (the first-loss cushion,
which after B8 includes protocol capital) and redemption fee rate `f`, a holder who exits `b`
sUSD ahead of a loss `l` shifts onto everyone who stays

    shifted = b · max(0, (l − U)/S − f)

and gains exactly that over holding through the loss. A loss no larger than `U` lowers no
balance at all, so front-running it gains nothing and costs the fee. If a fraction `φ` of the
supply exits ahead of the loss, whoever stays loses `max(0, l/S − U/S − f φ) / (1 − φ)` per
unit: the late holder's loss is amplified by `1/(1 − φ)`.

Measured (`test/LossFrontRunning.t.sol`, H = 0, so `f` = 1 bp): with `S` = 20,000, `U` = 102,
`l` = 600 and `b` = 9,999, the shift onto the other holder is 248.0001 sUSD, equal to the
formula to 5e-15 sUSD. When 90% of the supply exits ahead of a 2% loss, the holder who stays
loses 19.81%, against 1.99% pro rata. A loss inside the cushion leaves every balance unchanged
in both orders (`test_frontRunningGainsNothingInsideTheCushion`), and a fuzz test checks that
a loss no larger than the surplus never lowers the index, whatever action meets it first.

Gain per sUSD front-run, `(l − U)/S − f` with `f` = 3.25 bp (neutral H):

| Cushion `U/S` | loss 0.5% | loss 2% | loss 5% | loss 10% |
|---|---|---|---|---|
| 0.13% (day one: accumulated mint fees only) | 0.34% | 1.84% | 4.84% | 9.84% |
| 2.75% (surplus buffer filled, neutral H) | 0 | 0 | 2.22% | 7.22% |
| 5.13% (5% protocol capital, B8, plus fees) | 0 | 0 | 0 | 4.84% |

**Decision.** The launch parameters do leave exposure beyond the cushion: on day one the
cushion is only the mint fees collected so far, and the surplus buffer takes months to fill
from yield (README, limitation 7). The remedy is B8's protocol capital, which the prompt already
makes the default: `params.seedCapitalUSDC` = 1,250 USDC gives a 5% cushion at the 25,000 sUSD
supply cap, so every loss up to 5% of supply lowers no balance and front-running it gains
nothing. When the admin raises the supply cap, keep protocol capital at 5% of it or accept
the exposure in the table. Nothing else is built. Delaying or pausing redemptions would swap
this risk for a run at the exit gate and remove the property the peg rests on (redeem at any
time), so redemption stays unpausable. The guardian's emergency exit can still move the reserve
to idle USDC when a loss is anticipated but not yet realised.

## 6. Invariants and the tests that enforce them

| Invariant | Test |
|---|---|
| reserve ≥ supply after every action | `SpectrumInvariantTest.invariant_reserveFloor`; `_assertSolvent()` in every unit test; `afterInvariant` bank run |
| Σ shares = totalShares | `invariant_shareAccounting` |
| Σ balances ≤ totalSupply | `invariant_balancesCoveredBySupply`; `testFuzz_transferNeverShortchangesRecipient`; Halmos `check_*` in `test/halmos` |
| Every holder can exit at once from liquid funds | `invariant_everyoneCanExitAtOnce`; `afterInvariant` |
| Redemption and loss sync never fail unexpectedly | `invariant_redemptionsAndLossSyncNeverFail` |
| Treasury governance calls never fail unexpectedly | `invariant_treasuryGovernanceNeverFails` |
| Quarantined shares never count as reserve | `invariant_legacySharesNeverCounted` |
| Churn budget holds after every distribution | `invariant_churnBudgetHoldsAfterEveryDistribution`; `ChurnBudgetTest` |
| Net expansion per epoch ≤ cap | `invariant_expansionWithinCap` (net definition after A1) |
| Index > 0 | `invariant_indexPositive` |
| A realised loss no larger than the surplus never lowers the index | `testFuzz_lossWithinTheSurplusNeverLowersTheIndex` (A9) |
| No actor ends with more than it put in plus its share of distributed surplus | `invariant_noFreeLunch` (A10): an attacker actor that flash-borrows up to 10x its own value and, in one call, mints, redeems, gifts, rebases, syncs, rebalances, donates and sets H to an extreme for free |
| An atomic strategy from no sUSD back to no sUSD never ends above its start, distributions caught included | `invariant_flatRoundTripsNeverProfit` (A10) |
| Protocol capital is never distributed | `invariant_protocolCapitalNeverDistributed` (B8) |
| H stays in [0, 1e18]; warm-up and stale periods read neutral | `SpectralEntropyOracleTest` |
| A rebase step is below the minimum round-trip fee | `testFuzz_rebaseStepBelowRoundTripFees`; Halmos `check_rebaseStepBelowRoundTripFees` (proven for every H) |
| Policy curves stay in their bounds and move monotonically with H; the buffer never falls below 2.75% | Halmos (proven for every input, except the monotonicity of the two quadratic fees, which times out); `testFuzz_policyIsMonotoneInEntropy`, `testFuzz_feeCurvesMonotoneOnAdjacentInputs` |
| The churn step never reverts and its results are exact, for every uint128 input with the old index in the window's range | Halmos `check_churnStepNeverRevertsAndIsExact` (proven) |

## 7. Out of scope

- The off-chain x402 facilitator and SDK (Phases 2 and 3).
- The economics of the vault itself (Aave and Morpho risk). The protocol limits exposure
  with the idle buffer, the allowlist, the emergency exit and loss absorption, but cannot
  remove it.
- Legal and regulatory status (see `RUNBOOK_MAINNET.md` §7).

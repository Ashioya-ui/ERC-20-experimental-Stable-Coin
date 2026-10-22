# Phase 4 report: security, optimization and the paper's proven results

Branch `phase-4-hardening`, frozen at tag `audit-freeze-1`. Nothing has been
broadcast to any public network.

**In one paragraph.** Every Track A finding is fixed or analysed with a test, and an independent
reviewer then went through the hardened code. It found no Critical, High or Medium issue in the
contracts. It found three Low and two informational issues, mostly in the deployment path. All
are fixed or documented, and every code fix came with a test that failed first. The hot paths
are cheaper (mint −46%, rebase −37%, sync −43%, the oracle's worst-case write −25%). The churn
budget now uses the paper's proven constant, so no code depends on an open conjecture, and
Halmos proves 16 properties of the policy and the transform. **Not done, and needed before the cap rises past
25,000 sUSD: an external audit.** Not done before the first broadcast: the Base Sepolia dress
rehearsal, which needs your keys and is described in `DEPLOY_AND_TEST.md`.

## 1. Findings

Full text, tests and commits in `audit/findings.md`; the review and the response in
`audit/review.md`.

| ID | Severity | Status | Finding (short) | Test |
|---|---|---|---|---|
| A1 | Medium | Fixed | A mint-and-redeem round trip could block the daily mint cap | `test_mint_roundTripLeavesCapacityUnchanged`, `invariant_expansionWithinCap` |
| A2 | Low | Fixed | The pool's starting price was not checked | `test_initialisationPriceMustBeNearPar` |
| A3 | Low | Fixed | Setter-based wiring after deployment could be raced | `test_wiring`, `test_constructorRejectsMiswiring`, the rehearsal |
| A4 | Medium | Fixed | The deploy workflow gave the key to every step; actions not pinned | `actionlint` |
| A4b | Low | Fixed | The key check interpolated the secret into a script | `actionlint` |
| A5 | Medium (trust) | Fixed | The admin could migrate to any vault after the timelock | `test_onlyAllowlistedVaultsCanBeProposed` |
| A6 | Medium (economic) | Fixed | H could be steered end to end in a minute | `OracleManipulationTest`, `test_ema_*` |
| A7 | Low | Fixed | Holders below 1 sUSD could not redeem | `test_minimumIsDerivedAndDustCanStillExit` |
| A8 | Info | Fixed | The oracle gas budget failed under `--isolate` | `test_record_worstCaseGasFitsHookBudget` (both modes) |
| A9 | Medium (economic) | Analysed; remedy B8 | Loss front-running shifts the excess loss onto those who stay | `test/LossFrontRunning.t.sol` |
| A10 | Property | Added | No free lunch for a flash-loan attacker who also controls H | `invariant_noFreeLunch`, `invariant_flatRoundTripsNeverProfit` |
| A11 | Tools | Done | Slither, Aderyn, Halmos, mutation, coverage | `audit/slither.md`, `audit/formal.md`, `audit/mutation.md`, `audit/coverage.md` |
| A12 | Low | Fixed | Legacy dust from MetaMorpho rounding blocked later migrations (found against real Morpho bytecode) | `test/realvault/MorphoReplica.t.sol` |
| A13 | Info | Done | Dependency pins documented and enforced in CI | `script/check-deps.sh` |
| S-01 | Low | Fixed | The deployment could be stopped at the pool's start | `test/HookStart.t.sol`, `test_S01_checkSurvivesAnEmptyPoolWalkedOffPar` |
| S-02 | Low | Fixed | The workflow's key isolation was incomplete | `actionlint`; pinned SHAs checked against GitHub |
| S-03 | Low | Fixed | `verify.sh` used the old stabilizer constructor | `bash -n` |
| S-04 | Info | Fixed | Zero-net blocks could pin H at either end cheaply | `OracleSteeringTest` (5) |
| S-05 | Info | Fixed / documented | An event that misreported dust; five documentation gaps | `MigrationEventTest` |

Beyond the findings, on your request: the churn budget's constant is now Theorem 4.3's proven
bound (it was the conjectured 2 + π/3); mints deposit into the vault in batches; the oracle's
state is packed into one slot; 1,250 USDC of protocol capital pays yield from day one and absorbs
first losses; `SECURITY.md`; and a Base Sepolia path with labelled test vaults.

## 2. Gas and sizes

Gas is measured by `test/Benchmarks.t.sol` from inside a contract call, against a mock vault, so
the same number holds in normal and isolated runs. "Before" is the start of Track B, with the
Track A fixes already in.

| Call | Before | After | Change |
|---|---:|---:|---:|
| `mint` (1,000 USDC) | 180,565 | 97,620 | −45.9% |
| `redeem` (1,000 sUSD) | 96,799 | 85,974 | −11.2% |
| `rebase` | 99,496 | 63,032 | −36.6% |
| `sync` (absorb a loss) | 54,533 | 31,255 | −42.7% |
| `rebalanceReserve` | 79,205 | 68,622 | −13.4% |
| `transfer` | 37,325 | 37,158 | −0.4% |
| `oracle.record`, cold window close | 50,352 | 37,638 | −25.3% |
| `spectralEntropy8` | 32,945 | 19,023 | −42.3% |

Against real MetaMorpho v1.0 bytecode: a mint inside the deposit band 72,373 gas, one that
crosses it 193,370, a redemption from the idle buffer 55,649, one through the vault 151,084,
a rebase 54,678. Targets: mint −25%, redeem −10%, rebase −15% and the oracle write ≤ 38,000 are
met; `transfer` (−10%) is not, because a cold zero-to-non-zero storage write dominates it
(`audit/gas.md`).

Runtime sizes in bytes (limit 24,576; every contract keeps at least 1,024 free):

| Contract | Phase 4 start | Now | Free |
|---|---:|---:|---:|
| SpectralStabilizer | 18,072 | 21,486 | 3,090 |
| AutonomousTreasury | 9,271 | 9,899 | 14,677 |
| SpectralToken | 9,534 | 9,194 | 15,382 |
| SpectralHook | 3,841 | 6,610 | 17,966 |
| SpectrumLens | — | 5,992 | 18,584 |
| SpectralEntropyOracle | 5,957 | 5,570 | 19,006 |
| WrappedSUSD | 5,352 | 5,352 | 19,224 |

The stabilizer grew with the Track A fixes (vault allowlist, two-step admin) and protocol
capital, after the views moved to the lens; the hook grew with the price band (A2) and
`initializePool` (S-01).

## 3. What is proven, what is tested, what is not

**Proven** (Halmos 0.3.3; cvc5 1.2.1 and Bitwuzla 0.8.1; `audit/formal.md`), for every input in
the stated domain:
- every policy curve stays in its bounds, and the buffer never falls below its neutral 2.75%;
- the buffer, expansion cap and rebase step move monotonically with H;
- at every H a rebase step is worth less than a mint-and-redeem round trip (anti-sandwich);
- the churn step never reverts and is exact, for all `uint128` inputs with the index inside
  the window, so it can never block loss absorption;
- a monotone index path is never deferred;
- the Walsh-Hadamard transform is linear and an involution up to 8.

**Not proven** (timeouts or out of the solvers' reach): that the two quadratic fees rise with H
(fuzzed on random pairs and on neighbouring inputs); the token's share arithmetic (four hours
without a result; fuzzed and covered by the invariants); `lnWad` and the entropy (fuzzed and checked against
80-digit references); the stabilizer's flows end to end.

**Tested.** 219 tests pass, and one more is skipped without a Base RPC (the live fork suite).
They include 13 invariants with an attacker actor, checked after every one of 32,768 calls by
default and 262,144 in CI, each run ending in a bank run; the real mainnet script rehearsed on a
Base-shaped chain; the same flows against real MetaMorpho bytecode, real FiatToken USDC and a
real v4 PoolManager; and the paper's theorems as test oracles. Isolated mode passes too.
Mutation testing: 9 of the first 10 sampled mutants killed, the survivor equivalent in
effect, the other 28 not yet run (`audit/mutation.md`). Coverage of `src/` (the hook's
suites aside, which need a PoolManager the coverage build cannot fit in 8 GB): 94% of lines,
93% of statements, 80% of branches (`audit/coverage.md`).

**Not tested here.** The live Base fork suite (no RPC reachable from this machine; CI runs it
when `BASE_RPC_URL` is set); a deployment to Base Sepolia (needs your keys); and the CI profile
(10,000 fuzz runs, 262,144 calls per invariant) on the final commit: it ran on earlier Phase 4
commits, and GitHub CI runs it on every push.

## 4. Residual risks

1. **The vault.** Its losses, liquidity and governance pass through to holders beyond the
   surplus and the capital. Mitigated by the idle buffer, the allowlist, the emergency exit and
   loss absorption; not removable.
2. **Loss front-running beyond the cushion** (A9). Redemption is unpausable by design.
3. **H is steerable within bounds.** With the review's fix it still takes about eight hours (330 wsUSD)
   of paced trading to move H to 0.05, which buys about a 6 bp discount on the attacker's own mint
   fee; H can never lower the buffer or touch backing.
4. **Admin and guardian powers.** A 7-day public timelock and a two-vault allowlist bound the
   admin; migrating while the old vault is illiquid is an operational rule, not a code rule
   (S-05.4).
5. **No external audit.** Phase 4 is internal hardening plus one independent review.
6. **Legal.** The US GENIUS Act bans yield on payment stablecoins; Kenya's VASP Act requires a
   licence to issue one. Launch as an experimental token and take counsel first.

## 5. The paper

Langetepe and Ashioya, *The length-over-diameter ratio of self-approaching curves*, revised
version 21 (October 2026). `docs/paper-map.md` maps every result.
- `src/libraries/SelfApproaching.sol` implements Lemma 7.1, Lemma 2.1 and Theorem 4.3 exactly in
  integers; nothing on-chain calls it yet.
- `test/paper/` uses the proven results as oracles on six polygon generators, keeps the Section
  7.5 counterexample as a regression test, and agrees with the paper's own Python on 1,000
  polygons.
- The churn budget uses Theorem 4.3's proven constant. No code depends on Conjecture 1.2.
- `docs/design/reserve-allocation.md` describes where the proven bound would become load-bearing
  (a reserve split across two vaults), and recommends a plain turnover cap first.

## 6. Go / no-go for the broadcast

| | Item | Status |
|---|---|---|
| ✅ | Every Track A finding fixed or analysed, each with a test | done |
| ✅ | Independent review run; every finding fixed or documented | done |
| ✅ | Suite green, also in isolated mode; rehearsal passes; Slither clean | 219 pass, 1 skipped (fork); REHEARSAL PASSED; 0 High, 0 Medium |
| ✅ | Sizes under the limit with 1,024 bytes to spare | done |
| ✅ | Audit freeze tagged | `audit-freeze-1` |
| ⬜ | Base Sepolia dress rehearsal through the workflow (`DEPLOY_AND_TEST.md`, level 2) | yours to run |
| ⬜ | The live Base fork suite with your RPC (`make fork-test`) | yours to run |
| ⬜ | Safe and guardian addresses in `config/8453.json` | yours |
| ⬜ | Legal advice on the experimental-token launch | yours |
| ⬜ | Fresh Ledger deployer with 1,252 USDC and 0.003 ETH | yours |
| ⬜ | External audit (`audit/README.md` is the package) | before raising the cap |

**Go** for the guarded launch once the unticked rows above the last one are done. **No-go**
for raising the 25,000 sUSD cap until the external audit is done.

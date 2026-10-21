# Independent review (Phase 4 final check)

**How it was run.** A fresh agent that had not seen the Phase 4 work was given three things
only: the diff from `base-mainnet-kit` to the hardened code (for `src/`, `script/`, `config/`,
`.github/`, `foundry.toml` and the `Makefile`), `audit/threat-model.md`, and the Track A list of
findings and requested fixes. It was told to break the changes. It could read the source,
tests and dependencies for context, but not `audit/` (apart from the threat model), `docs/`,
the README, the runbook, `PROMPTS.md` or any report, so that it would not lean on the authors'
claims. It was read-only and ran no builds. Its proofs of concept were run afterwards (see
"Response").

The report follows as delivered, then the response: what was fixed, how it was tested, and what
was accepted with a reason.

---

# Spectrum Protocol, Phase 4 hardening: independent security review

**Scope.** I reviewed `review/diff.patch` (`src/`, `script/`, `config/`, `.github/`, `foundry.toml`, `Makefile`), `review/threat-model.md` and `review/track-a.txt`. For context I read the current source in `src/`, `script/`, `config/`, `test/` and `lib/`.

**Not read.** `audit/` (other than the threat-model copy), `docs/`, `README.md`, `RUNBOOK_MAINNET.md`, `PROMPTS.md`, `SECURITY.md` and `REPORT*`.

**Method.** The review was read-only. I read every changed function end to end, together with its callers. I ran no build and no tests.

## Summary

I found no Critical, High or Medium issue in the contracts. The on-chain hardening holds up:

- The A1, A3, A5 and A7 fixes do what Track A asked.
- The single reserve valuation (B1), the storage packing and casts, protocol capital (B8), the batched deposits and the new unchecked `SpectralPolicy` arithmetic are correct as far as I can see.

The weak points are elsewhere:

- the Track A items that touch deployment and CI (A2, A4);
- what A6 can achieve at all.

| ID | Severity | Title |
|---|---|---|
| S-01 | Low | A2: a third party can still block the deployment at `initialize`. A 1-wei donation moves the price band, and an empty pool's price moves for free. |
| S-02 | Low | A4: the deployer key still shares a process with dependency code that is not pin-checked. Secrets are repository-scoped, and the RPC secret is visible to every step. |
| S-03 | Low | `script/verify.sh` encodes the old 7-argument stabilizer constructor, and never verifies the lens. |
| S-04 | Info | A6: zero-net blocks pin H at either extreme for about 0.002 USDC per block. The switch from stale back to live skips the time weighting. |
| S-05 | Info | Smaller gaps between the threat model or comments and the code. |

---

## S-01 [Low] A2: the deployment can still be blocked at `initialize`; the band follows a 1-wei donation; an empty pool's price moves for free

**Severity.** Low. It affects deployment liveness and wsUSD's starting share price only. No reserve funds are at risk, and A2 itself was rated Low.

**Where.**
- `script/lib/SpectrumDeploy.sol:215-233`: wsUSD is created at nonce n+4. `initialize` uses the hard-coded 1:1 `parSqrtPriceX96` (line 225). The dead-share seed is deposited only after it (lines 227-233).
- `script/lib/SpectrumDeploy.sol:269-277`: the price assertion in `check`.
- `src/SpectralHook.sol:142-172`: `beforeInitialize`, `parPriceX96`, `priceWithinBand`.
- `src/WrappedSUSD.sol:24-26`: OpenZeppelin ERC-4626 with decimals offset 0.

**Scenario.** The broadcast runs with `--slow`, so each transaction waits for the previous receipt. Once the hook's CREATE2 transaction lands (the seventh), anyone watching the deployer address has a block before the script's `initialize`. Three things can happen in that window, or after it:

- **(a) Front-run inside the band.** Someone initialises the pool first at a price inside the band, for example +0.24%. The script's `initialize` then reverts with `PoolAlreadyInitialized`.
  - This is the denial of service described in the A2 finding itself.
  - The fix added the band but left the script unable to continue past an existing pool.
- **(b) Donate 1 wei to the empty wrapper.** Someone mints 1 USDC worth of sUSD (the stabilizer is live and unpaused) and sends 1 wei of sUSD to the still-empty wrapper.
  - `convertToAssets(1e18)` becomes `1e18·(1+1)/(0+1) = 2e18`, so the hook's par doubles.
  - The script's hard-coded 1:1 start now falls outside the band and reverts with `PriceOutOfBand`.
  - The donor has also fixed wsUSD's share price: k−1 wei donated gives k sUSD per share. A larger donation creates the first-depositor rounding problem that the dead shares are meant to prevent.
  - The donor can then take the initialisation at the price it chose.
  - This is not mispricing: after the donation a wsUSD share really is worth 2 sUSD. The harm is that the script cannot start the pool, because its price is hard-coded instead of read from the hook.
- **(c) Move the empty pool's price.** After any initialisation the pool has no liquidity, so a 1-wei exact-input swap moves the price to any limit at no cost.
  - The swap's delta is zero, so the hook records nothing (`afterSwap` skips `d == 0`), and `oracle.filled()` stays 0.
  - `SpectrumDeploy.check` then reverts on its band `require`. It runs in `PostDeployCheck` and in the deploy workflow right after the broadcast.
  - The band therefore constrains only the `initialize` call. It gives the first liquidity provider no protection.

**Impact.**
- The deployment stops after seven transactions: treasury, token, oracle, stabilizer, wsUSD, lens and hook.
- No dead shares are deposited and no protocol capital is contributed.
- The script has no resume path. The operator must finish by hand or redeploy with a fresh key.
- The griefer's cost is about 1 USDC plus gas.

**Fix.**
- Make starting the pool atomic with creating the hook. Use a one-shot deployment helper that, in a single transaction:
  1. CREATE2s the hook through the same proxy;
  2. reads `hook.parPriceX96()` on-chain;
  3. initialises at `sqrt(parPriceX96 << 96)`;
  4. adds the first liquidity with amount maxima.
- Deposit wsUSD's dead shares in the same transaction that creates wsUSD, or in that helper before `initialize`.
- Make `deploy()` able to resume: if slot0 is already set and inside the band, skip `initialize` and continue with the seed and capital steps.
- Turn the price `require` in `check` into a warning, or apply it only immediately after the script's own `initialize`.

**PoC.** `review/poc/PocA2PriceBand.t.sol` uses a real v4 PoolManager. All four tests should pass:

| Test | Shows |
|---|---|
| `test_A2_inBandFrontRunStillAbortsTheScript` | (a) |
| `test_A2_oneWeiDonationBlocksScriptStart_wsIsCurrency1` | (b), wsUSD as currency1 |
| `test_A2_oneWeiDonationBlocksScriptStart_wsIsCurrency0` | (b), wsUSD as currency0 |
| `test_A2_emptyPoolPriceMovesForFreeAndUnrecorded` | (c) |

**Confidence.** Confirmed by reading the script, hook, wrapper and v4-core `Pool.initialize` / `Pool.swap`. The PoC has not been run.

---

## S-02 [Low] A4: the key's isolation is incomplete

**Severity.** Low.
- After A3, a leaked deployer key is worth about what it holds at deploy time: roughly 1,252 USDC plus ETH, and a nonce race that makes forge abort.
- The larger risk is dependency code that is not pin-checked running in the broadcast step. That code can change what gets broadcast without needing the key.

**Where.**
- `.github/workflows/deploy-base-mainnet.yml`:
  - lines 9-18: the setup comment (repository secrets, one key for both networks, a reviewer on base-mainnet only);
  - line 66: environment selection;
  - line 67: one 45-minute timeout;
  - lines 70-79: job-level env, including the `RPC_URL` secret;
  - lines 124-130: two full test runs in the same job;
  - lines 147-160: the broadcast step.
- `.github/workflows/test.yml:28-29` (the only place `check-deps.sh` runs) and `:56-58`.

**Scenario and impact.**
1. **Key and dependency code in one process.** The broadcast step compiles and runs the script, including forge-std, OpenZeppelin and v4-core code, with `DEPLOYER_PRIVATE_KEY` in its environment.
   - Any imported dependency can call `vm.envString("DEPLOYER_PRIVATE_KEY")` and then `vm.createSelectFork("https://…/<key>")` to send the key out.
   - This is exactly the A4 exfiltration path. It now runs in one step instead of four.
2. **No pin check before deploying.** The deploy workflow never runs `script/check-deps.sh`, and `workflow_dispatch` runs the workflow from whichever ref the dispatcher picks.
   - The A13 dependency pins are enforced only in `test.yml`, and the deploy does not depend on it.
   - A ref with moved submodule pointers deploys without any check.
3. **Repository-scoped, shared secrets.** The setup comment has `DEPLOYER_PRIVATE_KEY`, `BASE_RPC_URL` and `ETHERSCAN_API_KEY` created as **repository** secrets, uses the same key for Sepolia and mainnet, and puts a required reviewer on base-mainnet only.
   - Repository secrets are readable by any workflow on any branch a collaborator pushes.
   - A base-sepolia run, which needs no approval, also receives them.
   - The mainnet reviewer gate therefore does not protect the key.
4. **RPC secret visible to tests.** `RPC_URL` is a secret (threat model §3, asset 7), but it sits in the job-level env.
   - `forge test` and `forge test --isolate` therefore see it. Both run all dependency code, fork tests included.
   - `test.yml`'s base-fork job does the same with `BASE_RPC_URL`.
5. **Timeout during broadcast.** Two full test runs, the preflight, `--broadcast --slow` and `--verify` all share one 45-minute timeout.
   - A timeout during the broadcast leaves a partial deployment.
   - Nothing in the workflow resumes it.

**Fix.**
- Split the workflow into two jobs:
  - a `test` job with no environment and no secrets, which runs `check-deps.sh` first;
  - a `deploy` job with `needs: test`.
- Make every secret an environment secret, with a separate key per network. Put required reviewers and "deployment branches: main" on both environments.
- In the broadcast step, keep the key out of forge's environment, for example `KEY=$DEPLOYER_PRIVATE_KEY; unset DEPLOYER_PRIVATE_KEY; forge script … --private-key "$KEY"`. Better still, sign with a keystore (`--account` with `--password-file`) or a KMS signer (`--aws` or `--gcp`).
- Pass the RPC URL only to the steps that need it.
- Give the deploy job its own timeout, and use `--resume` when retrying.

**Steps to reproduce.** Read the cited lines; there is no on-chain PoC for this.

**Confidence.** Confirmed by reading. I could not check offline that the pinned action SHAs match the tags named in their comments.

---

## S-03 [Low] `verify.sh` still uses the old stabilizer constructor

**Severity.** Low. This is operational, but it affects whether the most privileged contract can be publicly verified.

**Where.**
- `script/verify.sh:41-42`, compared with `src/SpectralStabilizer.sol:249-258`.
- `script/lib/SpectrumDeploy.sol:339-373`: `writeDeployment` does not record the allowlist.
- `Makefile:105-109`.

**Scenario.**
- `make verify-base-mainnet` is the documented way to re-verify. It encodes `constructor(address,address,address,address,address,uint256,uint256)`.
- A5 added an eighth argument, `address[] allowedVaults_`, so verifying the stabilizer fails on any explorer.
- The script's `|| true` hides the failure.
- `SpectrumLens`, which the script deploys, is never verified. Neither are the Sepolia TestnetVaults.

**Impact.** If `--verify` fails during the broadcast (explorer outages are common), this fallback cannot verify the stabilizer. Users then cannot check its allowlist, roles or caps against the source.

**Fix.**
- Write the allowlist into the deployment JSON.
- Encode `constructor(address,address,address,address,address,uint256,uint256,address[])`.
- Add the lens (`constructor(address)`) and the test vaults.
- Report failures instead of swallowing them.

**Steps to reproduce.** Compare `verify.sh:42` with the constructor, or run `script/verify.sh 8453 etherscan` against any deployment.

**Confidence.** Confirmed by reading.

---

## S-04 [Info] A6 residual: zero-net blocks pin H at either extreme for pennies

**Severity.** Info. The threat model already treats H as attacker-chosen, and D4 removed the lever that drained the buffer. This finding records what A6 does and does not achieve, and corrects one claim in a code comment.

**Where.**
- `src/SpectralEntropyOracle.sol`: lines 10-14 (the claim), 101-124 (`record`), 164-167 (the staleness fallback).
- `src/libraries/SpectralMath.sol:162`: an all-zero window returns 0.
- `src/SpectralHook.sol:177-196`.

**Scenario.** The parameters are those of `config/8453.json`. An "attacker block" is one of two things:
- a same-block round trip of exactly the 10 wsUSD dust limit: two swaps, each passing the per-swap filter, net 0;
- a single one-way swap of 10 wsUSD.

What follows:
1. **H = 0 from round trips.** Eight round-trip blocks make an all-zero window. `spectralEntropy8` reads that as H = 0, the most permissive policy, instead of as "no information".
2. **H ≈ 1 from one spike.** One one-way block in every eight, with round trips in between, keeps exactly one "spike" in every window, so H ≈ 1.
3. **Pinning takes hours, not money.** With one block every 20 minutes, each fold carries the full 0.25 weight.
   - Smoothed H moves from 0.5 to about 0.03, or to about 0.97, in 3 h 20 min.
   - That is 10 folds and about 28 swaps of 10 wsUSD.
   - The cost is roughly 0.002 USDC of 1 bp pool fees per block, plus gas.
4. **Policy effect.**
   - At H ≈ 0.97, every redemption pays about 9.5 bp (3.25 bp at neutral) and every mint about 23.6 bp (7 bp at neutral).
   - At H ≈ 0, the expansion cap is 20% a day.
5. **Stale-to-live jump.** After an idle hour H reads neutral (0.5). One round trip then restores the steered value at once; the time weighting does not apply to that switch.
6. **Real spikes vanish too.** Organic whale trades that arbitrage reverses within the same block also net to about 0, so the "spike" signal largely disappears.

**Impact.**
- Fee and cap griefing within the bounds the threat model allows.
- The comment's claim that net flow "makes wash trading an expensive way to shape the signal" is inaccurate. Same-block round trips are now the cheapest way to shape it.
- A6 bought wall time, not cost.

**Fix.** None of these makes steering expensive; they remove the degenerate readings.
- Treat an all-zero window, or one whose net is below dust, as neutral.
- Apply the dust filter to each block's net flow rather than to each swap, so round-trip blocks do not take window slots.
- When leaving the stale state, restart from neutral, or require a fresh full window.
- Correct the comment.

**PoC.** `review/poc/PocA6NetFlowSteering.t.sol` has five tests. All should pass and log the steered H and the resulting fees.

**Confidence.** Confirmed by reading. The PoC has not been run.

---

## S-05 [Info] Smaller gaps

1. **An event that misreports.** `migrateVault` emits `VaultMigrated(old, new, left)`. The third field is named `sharesQuarantined` (`AutonomousTreasury.sol:77, 228-237`).
   - It is emitted with that value even when `left` was dust that the migration abandoned, and `legacyVault` was never set.
   - Emit 0 in that case, or use a separate event.
2. **A7: the threat model and the code differ.**
   - The threat model §4 says a whole-balance redemption below the minimum is paid "from idle funds". `SpectralStabilizer.sol:366` does not check this, so such a redemption can reach the vault, where its fee (under one USDC wei) does not cover withdrawal rounding.
   - The stated worst case is one wei. An Aave static-aToken share is worth more than one USDC wei, so a withdrawal plus the rounded-down valuation can cost about 2 wei.
   - Right after a loss is synced, the surplus is about 0. Such a redemption, or a partial one of 0.01–0.02 sUSD served from the vault, can then revert with `ReserveFloorBreached`.
   - Balances under 1e12 wei cannot exit at all, because of the `assetsOut == 0` guard (line 372). That contradicts "no dust is trapped".
   - The amounts are negligible. This is plausible but untested.
3. **Threat model §5.1 overstates.** It says "nobody can exit at the old price". Until someone calls `sync`, the wsUSD pool is an exit at the pre-loss price, and the AMM liquidity providers absorb the difference.
4. **Admin trust under A5 (pre-existing mechanism).** The admin can run `executeVaultMigration` at any moment after the timelock, including while the old vault is illiquid. This is the most material item in this list.
   - Doing so quarantines shares and cuts the index for holders who could not exit first, since redemptions beyond idle funds revert while the vault is illiquid.
   - Surplus later returned by `recoverLegacy` goes to whoever holds sUSD at that time, including minters who joined at par after the cut.
   - So the "7 days in which holders can redeem" protection quietly assumes the vault is liquid.
   - Consider refusing to execute unless the old vault can redeem, say, 99% of the position, and leave `emergencyExitVault` for real emergencies.
   - Plausible; not tested.
5. **Mint-cap griefing after A1.**
   - Flash loans no longer work. Anyone with about 25,000 USDC can still fill the guarded-launch supply cap for the cost of the mint fee, and hold it (earning yield) until the admin raises the cap.
   - Steering H to 1 shrinks the daily cap to max(bootstrap, 2% of supply).
   - This is by design, but it deserves a line in the runbook.
6. **A3 caveat.** The constructors' cross-checks (`WiringMismatch`) catch only honest mismatches.
   - Someone holding the deployer key could place a contract at a predicted address that answers those checks correctly.
   - Safety therefore relies on forge aborting when the on-chain nonce moves.
   - If a broadcast ever aborts on a nonce error, discard every address that key produced and redeploy with a fresh key. Do not resume.

---

## What I checked and found sound

**Track A fixes**
- **A1.** `_releaseExpansion` floors each step at zero, so net growth within an epoch never exceeds the cap, in any order of mints and redemptions.
  - A same-transaction round trip restores capacity to within a wei.
  - Epoch roll-over is handled correctly.
  - No new revert reaches `redeem`.
- **A3.** The token, treasury and oracle wiring is immutable, and no setters remain.
  - The stabilizer refuses a token or treasury that names a different stabilizer.
  - The hook's address commits to the oracle and wsUSD addresses through its init code.
  - See the caveat in S-05.6.
- **A5.** The vault allowlist is fixed in the constructor.
  - It holds at most 4 entries, each is checked against the reserve asset, and it must include the starting vault.
  - `proposeVault` enforces it, and nothing else changes `treasury.vault`.
  - The emergency exit does not depend on it.
  - `DEFAULT_ADMIN_ROLE` cannot be granted or revoked directly; it transfers in two steps behind the 3-day delay.

**Accounting and economics**
- **B1 (single reserve valuation).** Every reserve value carried forward equals a fresh valuation at the point where it is used. I checked mint, redeem, `contributeCapital`, rebase and `rebalanceReserve`, including the paths where the vault deposit is skipped or the vault is full.
- **B8 (protocol capital).**
  - The credited amount is the measured increase in the reserve, and earlier donations are excluded.
  - Capital is never distributed.
  - A contribution can neither block nor unlock distributions, because reserve and capital rise together.
- **Batched deposits.** The vault rounding on a batch is charged to the minter whose deposit triggers it, through the measured credit. No path credits more than was added.
- **Rebase sandwich.**
  - The rebase step is at most 1 bp, below the 2 bp minimum round-trip fee at every H.
  - With capital covering the buffer, fees and yield become distributable at once, but still at no more than 1 bp an hour.
- **Unpausable paths.** Redemption and `sync` remain unpausable, with no new revert path apart from S-05.2.

**Code-level checks**
- **Arithmetic, packing and casts.**
  - The oracle's packed slot is 200 bits. Its uint40 block numbers and timestamps are fine, and the moving average stays at or below 1e18.
  - The stabilizer's uint128 and uint64 fields are packed correctly and go through SafeCast.
  - `SpectralPolicy`'s unchecked products stay below 2^191.
  - `churnStep` cannot revert as long as mn ≤ oldIndex ≤ mx, which every `setIndex` path maintains.
  - The unrolled `lnWad` and the unchecked `spectralEntropy8` stay in bounds (|X_k| ≤ 8e18).
- **Token.** The `_sharesToDebit` refactor is equivalent to the previous balance check.
- **Reentrancy.** Transient guards cover every entry point that moves funds. External calls go only to USDC (no callbacks), allowlisted vaults, and PoolManager → hook → oracle. None of them re-enters the stabilizer.

**Deployment and CI**
- **Test vaults cannot reach mainnet.**
  - `TestnetVault` and `deployTestVaults` both refuse chain 8453.
  - The mainnet allowlist comes from `config/8453.json`.
  - The workflow checks that the RPC's chain id matches the selected network.
- **Workflow inputs.**
  - They reach the shell only through environment variables, and addresses are normalised with `cast to-check-sum-address` before being written to `GITHUB_ENV`. I found no expression injection.
  - `permissions: {}` with per-job `contents: read`, and `persist-credentials: false`, are in place.
- **Dependency pins.** `check-deps.sh` matches the commit recorded for every submodule.

## Running the proofs of concept

1. Copy `review/poc/*.t.sol` to `test/poc/`.
2. Run `forge test --match-path 'test/poc/*' -vv`.
3. Expect all 9 tests to pass: 4 in `PocA2PriceBand`, 5 in `PocA6NetFlowSteering`.

Imports are written relative to the project root (`src/…`, `test/…`, `script/…`). If your setup does not resolve those, use `../../src/`, `../mocks/` and `../../script/` from `test/poc/` instead.

---

# Response

All five findings were accepted. **Red, then green.** On the commit the reviewer saw
(`6c4bf58`), its nine proofs of concept all passed, which confirmed every scenario, and the seven
new regression tests below all failed. With the fixes, the regression tests pass and the suite
is green. The pinned action SHAs the reviewer could not check offline were checked against
GitHub (`git ls-remote`): `actions/checkout` v5.0.0, `foundry-rs/foundry-toolchain` v1.9.1,
`actions/upload-artifact` v5.0.0 and `actions/setup-python` v6.0.0 all match their comments.

| ID | Decision | What changed | Tests |
|---|---|---|---|
| S-01 | Fixed | (a), (b): the hook gained `initializePool()`, which starts the pool at wsUSD's redemption value read on-chain in the same call and does nothing if the pool has started. The deployment deposits wsUSD's dead shares first, then calls it, so neither a front-running start nor a donation can stop the deployment, and the wrapper is never empty when the price is read. (c): `SpectrumDeploy.check` reports a pool price outside the band, and whether the pool is still empty, instead of failing. Not adopted: a helper that also adds the first liquidity in the same transaction. Seeding liquidity stays a separate, manual step, protected by the position's price range and slippage limits (runbook, Day 0). | `test/HookStart.t.sol` (4 tests); `TestnetRehearsalTest.test_S01_checkSurvivesAnEmptyPoolWalkedOffPar` (red on 6c4bf58) |
| S-02 | Fixed | The workflow has a `test` job with no environment and no secrets that checks the dependency pins first, and a `deploy` job that needs it and checks them again. Secrets are environment secrets, one deployer key per network, with reviewers and branch rules on both environments. The RPC URL reaches only the steps that talk to the chain. The broadcast step takes the private key, the Etherscan key and the RPC URL out of the environment before forge starts and passes them as arguments. The deploy job has its own 60-minute timeout, and its artifact, including `run-latest.json`, is uploaded even after a failed broadcast. | `actionlint` clean |
| S-03 | Fixed | `verify.sh` encodes the stabilizer's eight constructor arguments (the deployment JSON now records the allowlist), also verifies the lens and the Sepolia test vaults, and exits non-zero with the list of what failed. | `bash -n`; to be run against the Sepolia deployment |
| S-04 | Fixed | The dust filter also applies to each closed block's net flow: a block that nets out below `minObservation` takes no slot, and the next block reuses it. Only such blocks keep the signal live, and a stale signal starts over with an empty window and a neutral average. The NatSpec claim about wash trading is corrected. What remains is the A6 residual: steering H with real one-way flow costs time and pool fees, and moves only the bounded settings (`audit/oracle-manipulation.md`). | `OracleSteeringTest` (5 tests, red on 6c4bf58) |
| S-05.1 | Fixed | `VaultMigrated` reports 0 quarantined shares when what was left behind was abandoned as dust. | `MigrationEventTest` (red on 6c4bf58) |
| S-05.2 | Documented | The threat model now says what the code does. A whole-balance redemption below the minimum is not limited to idle funds. Right after a loss is synced, a dust redemption served by the vault can revert on the floor check by a wei or two of vault rounding. Balances below one wei of USDC (1e12 sUSD wei) cannot be redeemed, only transferred. All of this is below a millionth of a dollar, and the floor check failing safe is the intended behaviour. | — |
| S-05.3 | Documented | Threat model §5.1: until someone calls `sync`, the wsUSD pool is an exit at the pre-loss price, and its liquidity providers carry the difference. `sync` is permissionless; the runbook's keeper and E4 call it as soon as a loss is visible. | — |
| S-05.4 | Documented; code unchanged, with a reason | The admin can execute a migration while the old vault is illiquid, which quarantines shares and cuts the index for holders who could not leave. Requiring the old vault to pay 99% before a migration would also block moving away from a vault that is permanently impaired, which is the case quarantine exists for. So the rule goes into the runbook instead: execute only when the old vault can pay out the position, or else as an announced emergency, and the guardian cancels any migration that does not meet that. The threat model's admin trust row says so. | — |
| S-05.5 | Documented | Runbook §4: anyone with about 25,000 USDC can fill the guarded-launch supply cap and hold it. The response is to raise the cap. | — |
| S-05.6 | Documented | Runbook §2: if a broadcast stops on a nonce error, discard every address that key produced and redeploy with a fresh key. Resume (`--resume`) only after a timeout or RPC failure, when the deployer's nonce is exactly where the broadcast stopped. | — |

The reviewer's proofs of concept were not added to the suite: they assert the old behaviour and
now fail, as they should. The regression tests above replace them.


# Spectrum Protocol

> **Status: hardened (Phases 4 and 5), **live on Base Sepolia** (block 48884064), not on mainnet, not externally audited.** Phase 4 is
> frozen at tag `audit-freeze-1`; [`REPORT_PHASE4.md`](REPORT_PHASE4.md) has the findings, the
> measurements and a go/no-go checklist. Phase 5 ran the protocol at neobank scale ($300m,
> card-spend flows, 100,000 holders) and fixed what broke: [`REPORT_SCALE.md`](REPORT_SCALE.md). It launches guarded: a 25,000 sUSD supply cap,
> 1,250 USDC of protocol capital, a Safe as admin, and a 7-day timelock on moving the reserve.
> Treat sUSD as an **experimental token, not a stablecoin**; see
> [`RUNBOOK_MAINNET.md`](RUNBOOK_MAINNET.md) §7.

Spectrum Agentic USD (**sUSD**) is a reserve-backed, redeemable, rebasing ERC-20 built for
machine-to-machine payments. It supports EIP-3009 `transferWithAuthorization`, the format used by
the x402 "exact" payment scheme, and verifies smart-account (ERC-1271) signatures.

Monetary policy settings (fees, the daily mint cap, the surplus buffer and the rebase step size)
move with **H**. H is a Walsh-Hadamard spectral entropy computed on-chain from swap flow in one
Uniswap v4 pool. **H never creates or removes backing.** It only adjusts those settings, always
within fixed bounds.

The previous SPCM v2 files are kept unchanged in [`legacy/spcm-v2/`](legacy/spcm-v2/).
[`PROMPTS.md`](PROMPTS.md) holds the engineering prompts for Phases 1–4 and explains what
changed and why. Phase 4 (security, optimization, and the paper's proven results) is done:
[`REPORT_PHASE4.md`](REPORT_PHASE4.md) summarises it and [`audit/`](audit/) holds the evidence.
Phase 5 (scale) is in [`REPORT_SCALE.md`](REPORT_SCALE.md), with `test/scale/`, `sim/scale.py`
and `script/rehearsal/scale.sh`.
[`RUNBOOK_MAINNET.md`](RUNBOOK_MAINNET.md) is the deployment and operations runbook for Base, and
[`SECURITY.md`](SECURITY.md) says how to report a vulnerability.

## Deploying to Base mainnet

**First time? Start with [`DEPLOY_AND_TEST.md`](DEPLOY_AND_TEST.md):** run the tests, deploy to
Base Sepolia and try it, in that order, from a computer or from GitHub.

```bash
cp .env.example .env            # BASE_RPC_URL, BASE_SEPOLIA_RPC_URL, ETHERSCAN_API_KEY, DEPLOYER
# set roles.admin (your Safe) and roles.guardian in config/8453.json
make test rehearsal             # 257 tests, then the exact mainnet script on a Base-shaped anvil
make deploy-base-sepolia        # dress rehearsal on Base Sepolia, with labelled test vaults
make fork-test                  # the same scenarios on a fork of Base mainnet
make preflight                  # the whole deployment simulated against live Base state
make deploy-base-mainnet        # broadcast + Basescan verification + post-deploy check
```

The deployer needs about 0.003 ETH and 1,252 USDC on Base: 2 USDC seed wsUSD's dead shares and
1,250 USDC become protocol capital (7 test USDC on Sepolia). You can also deploy without a local
setup: run **Actions → deploy-base-mainnet** in GitHub with `network=base-sepolia` first and
`network=base` after, each as a dry-run and then a broadcast (RUNBOOK_MAINNET.md §1A and §2B).
On every push, CI runs the full suite (also in isolated mode), Slither, the gas-snapshot check,
the dependency pins, the anvil rehearsal and the Base fork scenarios.

The reserve vault is Aave v3 waBasUSDC (StataTokenV2), with Gauntlet USDC Prime as the
fallback. That choice and every address in `config/8453.json` come from the October 2026
research report; the runbook lists the sources.

---

## Quick start

```bash
git submodule update --init --recursive   # forge-std v1.17.0, OpenZeppelin v5.4.0, v4-periphery (+ v4-core);
                                          # re-run it if a nested fetch times out
forge build                               # first build takes about 2 min (via-IR, v4-core PoolManager)
forge test                                # 257 tests (the Base fork suite skips without BASE_RPC_URL)
FOUNDRY_PROFILE=ci forge test             # 10k fuzz runs; invariants 1,024 runs x 256 calls
script/rehearsal/run.sh                   # mainnet rehearsal on anvil -> rehearsal/latest.log

# quick local playground: mocks, PoolManager, mined hook, wsUSD/USDC pool, 9 demo swaps
anvil &
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --slow \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil key #0
```

Toolchain used to produce the results below: Foundry 1.5.1, solc 0.8.26, EVM `cancun`, via-IR,
optimizer runs 44,444,444. v4-core needs these optimizer settings: lower values hit
stack-too-deep in `PoolManager` under via-IR.

## Layout

| Path | What |
|---|---|
| `src/libraries/SpectralMath.sol` | FWHT-8 (Yul butterflies), `lnWad`, `spectralEntropy8` |
| `src/libraries/SpectralPolicy.sol` | The policy curves and the churn-budget step as pure functions, formally checked (`audit/formal.md`) |
| `src/libraries/SelfApproaching.sol` | The paper's proven results in exact integer arithmetic (a library; nothing on-chain calls it yet) |
| `src/SpectralEntropyOracle.sol` | 8-block ring buffer, dust filter, EMA, warm-up and staleness fallbacks |
| `src/SpectralToken.sol` | sUSD: share-based rebasing ERC-20, EIP-2612, EIP-3009, ERC-1271 |
| `src/AutonomousTreasury.sol` | Reserve adapter: idle USDC buffer in front of one ERC-4626 vault, emergency exit, migration with legacy-share quarantine |
| `src/SpectralStabilizer.sol` | Mint/redeem, fees, caps (daily and total), buffer, micro-rebases, loss absorption, churn budget, vault governance |
| `src/WrappedSUSD.sol` | wsUSD: non-rebasing ERC-4626 wrapper. Pools must use it, never raw sUSD |
| `src/SpectralHook.sol` | Uniswap v4 hook (`beforeInitialize` + `afterSwap`) that feeds the oracle |
| `src/SpectrumLens.sol` | Read-only views: quotes, surplus, distributable, remaining caps, liquid assets |
| `test/SpectrumProtocol.t.sol` | The main suite, including the invariants and the attacker actor |
| `test/SpectralHook.t.sol`, `test/OracleManipulation.t.sol` | The hook on a real v4 PoolManager; measured cost of steering H |
| `test/LossFrontRunning.t.sol`, `test/ProtocolCapital.t.sol`, `test/Benchmarks.t.sol` | Loss front-running (A9), protocol capital (B8), gas benchmarks |
| `test/paper/`, `test/halmos/` | The paper's theorems as test oracles; symbolic properties for Halmos |
| `test/realvault/` | The same flows against real MetaMorpho v1.1 bytecode |
| `test/mainnet/MainnetScenarios.t.sol` | Day-one scenarios run through the real deploy procedure: locally on a Base-shaped chain, and on a Base fork |
| `test/handlers/`, `test/mocks/`, `test/utils/` | Invariant handler, mocks, shared fixture |
| `test/reference/` | 80-digit Python reference values for `lnWad` and the entropy, plus their generator |
| `test/artifacts/` | Circle FiatToken v2.2 bytecode (real USDC code for local rehearsals), with provenance |
| `config/8453.json`, `config/84532.json` | Base mainnet and Base Sepolia addresses and launch parameters |
| `script/lib/SpectrumDeploy.sol` | The single deploy, check and record procedure used by every script and test |
| `script/DeployBaseMainnet.s.sol`, `script/PostDeployCheck.s.sol` | Mainnet deployment and read-only verification |
| `script/rehearsal/` | Base-shaped anvil environment, scenario transactions, `run.sh` |
| `script/verify.sh`, `script/safe-tx.sh` | Explorer verification with explicit constructor arguments; Safe Transaction Builder batches |
| `Makefile`, `.env.example`, `RUNBOOK_MAINNET.md` | Operator interface |
| `script/lib/TestnetVault.sol` | The labelled no-yield test vault for Base Sepolia; it refuses chain 8453 |
| `script/DeployLocal.s.sol` | Quick local playground (anvil only) |
| `audit/`, `docs/`, `sim/` | Threat model, findings, tool reports, gas, formal checks; the paper map and design notes; the parameter simulation |
| `legacy/spcm-v2/` | Previous design, unchanged |

## How it works

1. **Backing.** `mint` takes collateral (e.g. USDC) into the treasury, which keeps a liquidity
   buffer idle and deposits the rest in the ERC-4626 vault in batches, once idle funds exceed the
   target by 1% of the reserve. The minter receives the *measured* increase in reserve value
   minus a fee.
   `redeem` burns sUSD and pays collateral 1:1 minus a fee. Redemption cannot be paused.
2. **Reserve floor.** Every state-changing entry point ends with
   `reserveValue() >= totalSupply()` and reverts if it fails. The reserve is valued
   conservatively: `previewRedeem` of the vault shares, plus idle balance.
3. **Losses.** A realised loss inside the vault can push the reserve below supply. `sync()`
   lowers the index so that supply equals the reserve, sharing the loss pro rata. `sync()` is
   permissionless, cannot be paused, and runs first in every mint, redeem and rebase, so nobody
   can exit at the old price.
4. **Distributing surplus.** Fees and vault yield create surplus. `rebase()` is permissionless
   and allowed at most once an hour. It raises every balance by at most 1 bp of supply (0.5 bp at
   H = 1), and only out of surplus above an H-dependent buffer and the protocol capital: supply
   may rise to at most min(reserve / (1 + buffer), reserve − capital). A rebase step is always smaller
   than the minimum mint fee plus redeem fee, so a mint → rebase → redeem sandwich always loses
   money (fuzz-tested).
5. **Entropy H.** The oracle keeps one slot per *block*: all swaps in a block are summed, and
   blocks with no swaps are skipped. When a new block starts, it folds the Walsh-Hadamard spectral
   entropy of the last 8 active blocks into an EMA. Semantics:
   - an even, homogeneous flow gives H = 0;
   - one block dominating the window (a whale or MEV spike) gives H = 1.

   (The original prompt had this backwards.) H is neutral (0.5) during warm-up and after one hour
   without swaps. Each block contributes its **net** flow, and each fold of the moving average
   carries weight `min(0.25, dt / (dt + 1 hour))`, so steering the signal costs wall time rather
   than a few blocks of gas (`audit/oracle-manipulation.md`). H can tighten a safety limit but
   never loosen one: the surplus buffer never falls below its neutral 2.75%, and the daily mint
   cap never rises above its neutral 11% (Phase 5, P5-01).
6. **Policy (all bounded):**

   | | H = 0 (calm) | H = 0.5 | H = 1 (spiky) |
   |---|---|---|---|
   | Mint fee | 1 bp | 7 bp | 25 bp |
   | Redeem fee | 1 bp | 3.25 bp | 10 bp |
   | Daily mint cap (share of supply, or the bootstrap cap if larger) | 11% (20% before Phase 5) | 11% | 2% |
   | Surplus buffer kept before distributing | 2.75% | 2.75% | 5% |
   | Max rebase step | 1 bp | 0.75 bp | 0.5 bp |

7. **Churn budget (`CHURN_BUDGET_WAD`).** Within a 7-day window, let L be the index's total
   variation (sum of all moves) and D its range (max minus min). A positive rebase is deferred if
   afterwards L > 3.1356 × D. Monotone yield distribution always has L = D, so it is never
   blocked. With equal-sized gains and losses alternating, the third upward step in a window is
   deferred. Loss absorption is never deferred, and the step can never revert (proven with
   Halmos).
8. **Hook.** The hook is restricted to one pool, fixed at construction (`beforeInitialize`
   rejects every other pool). It records the absolute wsUSD leg of each swap.
   - If the oracle call fails with revert data, the hook logs it and the swap proceeds, so the
     oracle can never brick the pool.
   - If the oracle call fails *without* revert data (it ran out of gas), the swap reverts.
     Otherwise a swapper could set a gas limit that starves the call and avoid being recorded.
9. **Reserve and liquidity.** The treasury keeps `liquidityBufferBps` of the reserve (15% at
   launch) as idle USDC in front of the vault, as the research report recommends:
   - redemptions are paid from idle funds first, then from the vault within its `maxWithdraw`;
   - if both fall short, the redemption fails with `InsufficientLiquidity(available)`;
   - deposits respect `maxDeposit`, and a vault that refuses a deposit leaves the funds idle
     instead of blocking mints;
   - mints deposit in batches: most mints never touch the vault, which saves its deposit gas and
     rounding, at the cost of up to 1% of the reserve sitting idle for a while.

   The guardian can pull everything out of the vault at once (`emergencyExitVault`). The admin
   can move the reserve to another vault after a 7-day timelock. Shares the old vault cannot pay
   are quarantined: they stop counting as reserve, and anyone can recover them later.
10. **Guarded launch.** `supplyCap` (25,000 sUSD at launch) bounds total minting, on top of the
    daily expansion cap. `redeem(type(uint256).max, …)` redeems a whole balance even if a loss
    is pending.
11. **wsUSD.** sUSD rebases, so a Uniswap v4 `PoolManager` must never hold it:
   - anyone could capture the pool's positive rebases by calling `rebase()` between `sync` and
     `settle`;
   - negative rebases would leave the last LPs short.

   Pools pair wsUSD, an ERC-4626 wrapper over sUSD (the stETH/wstETH pattern), with USDC.
12. **Protocol capital.** `contributeCapital` adds collateral that is never paid out: the
    deployment contributes 1,250 USDC, enough to cover the largest surplus buffer (5%) at the
    25,000 sUSD cap. Fees and yield are therefore distributable from day one instead of after
    about ten months, small vault losses lower no balance, and redeeming ahead of a known loss
    gains nothing while the loss fits in the cushion (A9). Holders earn the yield on it.

## The x402 payment rail (Phase 6)

An agent that holds one sUSD balance can pay any x402 bill. It needs no vault position, no USDC
float and no ETH for gas, and the balance earns between payments.

| | |
|---|---|
| `src/periphery/SpectrumPayRouter.sol` | Immutable, ownerless, holds nothing between calls. Redeems exactly enough sUSD, pays the merchant the exact USDC price, returns all change in the same transaction |
| `x402/facilitator.mjs` | x402 v2 `/verify`, `/settle`, `/supported`, plus `/convert` |
| `x402/merchant.mjs` | Example resource server, including an agent marketplace |
| `x402/agent.mjs` | Agent client and CLI with a spend policy |

The EIP-3009 nonce *is* the payment intent — `keccak256(payTo, assets, salt)`, recomputed inside
`pay()` — so a submitter who changes the payee, the price or the salt invalidates the signature.
Measured cost is **3.0–3.3 bps at neutral entropy** from $0.01 upward (1–10 bp across the policy
curve; the agent authorises at 10 bp and gets the difference back). A model of the unit economics
puts break-even near 45% of treasury turned over per day, using an assumed 5% APY — the fee side
is measured, the yield side is not (`x402/review/fee-curve.mjs`,
`x402/review/unit-economics.mjs`).

```bash
make x402          # chain, router, facilitator, merchant, demo and tests, about a minute
make x402-serve    # the same, left running for agents
```

Design and threat model: `docs/design/x402-rail.md`. Cross-request state audit:
`audit/x402-state-audit.md`. Base Sepolia walkthrough: `DEPLOY_AND_TEST.md`.

## The paper

The geometry comes from E. Langetepe and W. A. Ashioya, *The length-over-diameter ratio of
self-approaching curves*, revised version 21 (October 2026). [`docs/paper-map.md`](docs/paper-map.md)
lists every result, its status (proven, numerical, or open) and where the code uses it.

- `src/libraries/SelfApproaching.sol` implements the proven results exactly, in integers:
  Lemma 7.1 (a polygon is self-approaching iff `(v_j − v_i)·(v_i − v_{i−1}) ≥ 0`), Lemma 2.1
  (the diameter is the largest distance from the start) and Theorem 4.3
  (`L ≤ (5π/6 + 2 sin(π/12))·D = 3.1356…·D`).
- `test/paper/` uses the proven results as test oracles, keeps the paper's Section 7.5
  counterexample (sampled checks are not enough) as a regression test, and checks the library
  against the paper's own Python on 1,000 polygons: every verdict, diameter and length agrees.
- The churn budget's constant is Theorem 4.3's **proven** bound, 3.1356… Until Phase 4 it was
  2 + π/3, whose sharpness is Conjecture 1.2 (open). No code depends on an open result now. It
  is a design constant in a one-dimensional rule: no safety property depends on it.
- Nothing on-chain calls `SelfApproaching` yet. [`docs/design/reserve-allocation.md`](docs/design/reserve-allocation.md)
  describes where the proven bound would become load-bearing (a reserve split across two vaults)
  and why a plain turnover cap should come first.

## Verified properties (test suite)

1. FWHT matches the naive Hadamard product (fuzz), is an involution up to 8x, and satisfies Parseval.
2. `lnWad` is within 1 wei of the correctly rounded value for x < 2^60, which covers every
   probability in an entropy computation. It is within 3 wei for any x. The test uses 92
   reference points computed at 80 digits; a bit-exact Python emulation over 300k random inputs
   agrees.
3. Entropy: constant window → 0 and spike → 1, exactly. H stays in [0, 1] for full 256-bit
   inputs. It is exactly invariant under scaling and under dyadic (XOR) time shifts, and it grows
   with whale size. It is within 38 wei of the 80-digit reference.
4. Oracle: per-block aggregation, ring buffer order, dust, saturation, warm-up, staleness and the
   EMA update are each checked. The worst-case write (window close, cold storage) costs 37,261
   gas.
5. Token: rebasing accounting, rounding in the reserve's favour, and EIP-2612 permit and EIP-3009
   transfer/receive/cancel from both EOAs and an ERC-1271 smart account. Also checked: replay,
   validity windows, forged or tampered signatures, and value surviving a rebase.
6. Stabilizer: fees, caps, bootstrap, donations, slippage guards, pause scope, bounded rebases,
   buffer, loss absorption (sync, redeem, mint, rebase), an exact churn-budget boundary test
   (1 wei either side), and the unprofitable sandwich.
7. Uniswap v4 integration on a real `PoolManager`:
   - the hook address flags are correct and other pools are rejected;
   - only the PoolManager can call the hook;
   - swaps fill one slot per block and same-block swaps aggregate;
   - calm flow followed by a whale raises the mint fee;
   - a broken oracle does not brick swaps, and starving the oracle of gas reverts the swap.
8. Invariants (256 x 128 by default; CI 1,024 x 256, 262,144 calls each):
   - no free lunch: an attacker that flash-borrows, mints, redeems, gifts, donates, rebases and
     sets H at will never ends above its start plus its share of distributed surplus (A10);
   - reserve ≥ supply;
   - share accounting is consistent;
   - balances never exceed supply;
   - everyone can exit at once;
   - redemptions and `sync` never fail unexpectedly;
   - the churn budget holds after every distribution;
   - the mint cap holds.

   - treasury governance (buffer changes, rebalancing, emergency exits, migrations, legacy
     recovery) never fails unexpectedly;
   - quarantined legacy shares are never counted as reserve.

   After every run, all holders redeem everything (a bank run) and the floor must still hold.
9. Treasury hardening, tested separately:
   - the 15% buffer, and redemptions paid from it while the vault is fully lent out;
   - the exact `InsufficientLiquidity` amount;
   - paused vaults, reverting deposits, and deposit caps;
   - rebalancing tolerance;
   - emergency exits, partial and repeated;
   - migration access control, asset checks, the timelock and cancellation;
   - quarantine and recovery of legacy shares;
   - guardian and admin separation;
   - supply-cap behaviour.
10. Mainnet scenarios (`test/mainnet`), run through the same deployment procedure as the
    mainnet script:
    - every post-deploy check;
    - mint and redeem through the buffer and the vault;
    - an x402 payment in sUSD and one in **real FiatToken v2.2 USDC** (EIP-3009);
    - swaps feeding the oracle, and other pools rejected;
    - yield reaching holders after the buffer fills;
    - an emergency exit, then a 7-day migration to the fallback vault;
    - the supply cap.

    Locally these run against Circle's FiatToken v2.2 bytecode and a real v4 PoolManager. With
    `BASE_RPC_URL` set, they run against Base mainnet itself.
11. Rehearsal (`script/rehearsal/run.sh`, log in `rehearsal/latest.log`): the mainnet script
    broadcast to anvil, followed by the post-deploy check and the runbook's own `cast` commands
    for keeper, guardian and admin actions. The Base Sepolia path runs locally too
    (`test/mainnet/TestnetRehearsal.t.sol`).
12. Formal checks (Halmos, `audit/formal.md`): 16 properties proven for every input in their domain (cvc5 1.2.1 or
    Bitwuzla 0.8.1): every policy curve's bounds and the buffer floor; monotonicity of the buffer,
    expansion cap and rebase step; the anti-sandwich inequality at every H; the churn step's freedom
    from reverts and its exactness; and the FWHT's linearity and involution. The two quadratic
    fees' monotonicity times out and stays fuzzed; the token's share arithmetic did not finish.
13. The paper (`test/paper/`): the library agrees with the paper's Python on 1,000 polygons, the
    proven theorems hold on every accepted polygon from six generators, and the Section 7.5
    counterexample is rejected.
14. Static analysis, mutation and coverage: Slither and Aderyn findings are triaged in
    `audit/slither.md`; Gambit mutants: 9 of the first 10 killed, the survivor equivalent in effect, 28 still to run
    (`audit/mutation.md`); coverage of `src/` without the hook (whose suites need a PoolManager the coverage build
    cannot fit in 8 GB) is 94% of lines and 80% of branches (`audit/coverage.md`).

Contract sizes (runtime bytes, limit 24,576): Stabilizer 21,486, Treasury 9,899, Token 9,194,
Hook 6,610, Lens 5,992, Oracle 5,570, wsUSD 5,352. Gas, measured from inside a call with a
mock vault: mint 97,620, redeem 85,974, rebase 63,032, sync 31,255, transfer 37,158; the oracle's
worst-case write 37,638. Against real MetaMorpho bytecode, a mint inside the deposit band costs
72,373 and one that crosses it 193,370. Details in `audit/gas.md`.

## Known limitations: read before deploying

1. **Vault risk is the real risk.** Losses, withdrawal limits and share-price manipulation of the
   chosen ERC-4626 vault pass straight through to holders, beyond what the surplus and the
   protocol capital absorb. Pick a vault with:
   - donation-resistant accounting;
   - deep withdrawal liquidity;
   - share prices below 100 asset wei per share wei (rounding is covered by the 1 bp fee floor
     only up to that point).

   If the vault cannot pay, redemptions revert until it can.
2. **Loss front-running.** A holder who learns of a vault loss before it is realised can redeem
   at par first and leave the excess over the cushion to those who stay (A9, threat model §5.1).
   With capital at 5% of the cap, a loss of up to 5% of the cap lowers no balance and exiting
   early gains nothing. Redemption cannot be paused, by design, so this cannot be closed without
   giving up instant exits.
3. **Yield depends on the protocol capital.** Without it, the surplus must first fill the
   2.75–5% buffer from yield, about ten months at 4%. Keep capital at 5% of the cap or more when
   raising the cap (RUNBOOK_MAINNET.md §4). Batched deposits keep up to 1% of the reserve idle
   above the 15% buffer, about 0.04% a year of yield at 4%.
4. **H is steerable, within bounds.** Since Phase 4 steering it costs time rather than money:
   about eight hours of paced trading (one 10 wsUSD trade every 20 minutes, 330 wsUSD in all)
   moves H to about 0.05, which cuts the attacker's own mint fee by about 6 bp; since Phase 5 it
   no longer raises the daily mint cap (P5-01). Pushing H towards 1 raises everyone's fees within
   their caps, tightens the cap and holds back distributions while the buffer rises toward 5%;
   protocol capital of 5% of supply keeps yield flowing whatever H reads (REPORT_SCALE.md).
   Same-block round trips no longer count at all (review S-04). H can never
   lower the surplus buffer below 2.75% and never touches the backing. Treat H as a heuristic,
   not a security signal (`audit/oracle-manipulation.md`).
5. **Admin powers.**
   - The guardian can pause minting and rebasing indefinitely, pull the reserve out of the vault
     into idle USDC, and cancel a migration.
   - The admin (a Safe) can set the supply cap and the liquidity buffer, and can migrate the
     reserve to the other allowlisted vault (Aave waBasUSDC or Gauntlet USDC Prime, fixed at
     deployment) after a 7-day public timelock. Watch `VaultProposed`. The execution names the
     largest fall of the reserve it accepts and reverts beyond it, so a migration out of an
     illiquid vault cannot quarantine most of the reserve by accident (Phase 5, P5-03). The admin
     role moves only in two steps with a 3-day delay.
   - Redemption and loss absorption cannot be paused, and no role can send reserve funds to an
     address of its choosing.
   - Nothing is upgradeable: a bug means a new deployment and moving holders.
6. **Dust.** Redemptions below 0.01 sUSD revert unless they redeem a whole balance, so a holder
   with dust can always exit in full.
7. **Gas.** The first swap of each block pays for the oracle's window close (about 37k gas).
   Size gas with `eth_estimateGas`: a fixed-multiplier estimate taken in the wrong block can run
   short, and the swap then reverts with `OracleOutOfGas`.
8. **The churn budget is a design rule.** Its constant is a proven bound for plane curves, used
   by analogy in a one-dimensional rule. No stability property follows from the geometry; any
   constant near 3 would behave the same.
9. **Not externally audited, no funded bug bounty.** Phase 4 is internal hardening plus an
   independent review (`REPORT_PHASE4.md`). Halmos proves properties of the policy curves, the
   churn step and the FWHT, not the stabilizer's flows (`audit/formal.md`). Report
   vulnerabilities as `SECURITY.md` describes. The research report found two legal constraints:
   - the US GENIUS Act bans yield on payment stablecoins;
   - Kenya's VASP Act requires a Central Bank of Kenya licence to issue a stablecoin.

   Launch as an experimental token and take counsel before inviting the public
   (RUNBOOK_MAINNET.md §7).

## Differences from SPCM v2 (legacy)

1. The token now has a reserve and 1:1 redemption. SPCM v2 was explicitly "not a stablecoin" and
   distributed 80% of fees to swappers.
2. Entropy: SPCM v2 used a 64-bin log2 histogram of single swaps, in nats, with a target band
   of 1.8–2.8. This version uses the Walsh spectrum of per-block aggregates, normalised to [0, 1],
   with the semantics described above.
3. The oracle accepts writes only from a hook that is set once (red-team CRITICAL-1 stays closed).
   The hook is restricted to one pool.
4. The legacy `AutonomousTreasury.distribute()` deleted the participant records before paying
   out, then read the payee from the deleted records. Every transfer therefore targeted
   `address(0)`, reverted inside a `try`, and nobody was ever paid. That code is gone.
5. The legacy scripts hard-code Base Sepolia PoolManager `0x05E7…1863`. Uniswap's deployment page
   lists `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`. They also call the old 3-argument
   `initialize`. `script/DeployBaseMainnet.s.sol` replaces these scripts.

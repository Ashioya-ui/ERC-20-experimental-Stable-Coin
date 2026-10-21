# Mutation testing (Phase 4, A11)

Gambit 1.0.6 (`github.com/Certora/gambit` release binary, sha256 in `audit/tools.md`) generated
a random sample of mutants with seed 0: 5 in `SpectralPolicy`, 12 in `SpectralStabilizer`, 8 in
`AutonomousTreasury`, 8 in `SpectralToken` and 5 in `SpectralEntropyOracle` (38 in all;
`WrappedSUSD` has no logic of its own to mutate). Each mutant replaced its file in a copy of the
repository, and the core suites ran against it with `--fail-fast`: `SpectrumProtocol.t.sol`
(including the invariants), `LossFrontRunning.t.sol` and `ProtocolCapital.t.sol`. A mutant is
killed when any test fails.

The copy compiles with a lighter optimizer profile (200 runs, minimal Yul steps), which takes 85
seconds per mutant instead of seven minutes; it leaves the code's behaviour unchanged but not its
gas, so the two gas-budget tests (`test_record_worstCaseGasFitsHookBudget`, `test_entropy_gas`)
are excluded from every run, the baseline included. The baseline passes.

Script: `audit/logs/scripts/run-mutation.sh`.

## Results (partial)

The run covered the first 10 mutants on commit `6c4bf58` before the session that ran it
stopped; the other 28 have not run yet.

| Mutant | Change | Result | Killed by |
|---|---|---|---|
| policy-1 | mint fee divides by `WAD / WAD` instead of `WAD * WAD` | killed | `test_mint_feeRisesWithEntropy` (overflow) |
| policy-2 | buffer uses `2 % (h − 0.5)` instead of `2 * (h − 0.5)` | killed | `test_policyEndpoints` |
| policy-3 | churn length `len * step` instead of `len + step` | killed | `test_rebase_monotoneYieldIsNeverDeferred` |
| policy-4 | churn range forced to 0 | killed | `test_rebase_distributesSurplusInBoundedSteps` |
| policy-5 | churn verdict forced to false | killed | `test_rebase_distributesSurplusInBoundedSteps` |
| stabilizer-1 | the constructor's `dec > 18` check removed | **survived** | — |
| stabilizer-2 | redemption payout `scale / (amount − fee)` | killed | `test_loss_redeemAllSentinelHandlesPendingLoss` |
| stabilizer-3 | mint credit forced to 0 | killed | (first failing test not captured) |
| stabilizer-4 | rebase interval check always reverts | killed | `test_rebase_distributesSurplusInBoundedSteps` |
| stabilizer-5 | `oldIndex − dIndex` instead of `+` | killed | `test_rebase_distributesSurplusInBoundedSteps` |

**Kill rate so far: 9 of 10.**

**The survivor is equivalent in effect.** Without the `dec > 18` check, a reserve asset with
more than 18 decimals still cannot be used: the next line computes `10 ** (18 − dec)`, which
underflows and reverts the constructor. Only the revert reason changes, from `UnsupportedAsset`
to a panic. No test asserts that reason, and none is added: it guards a deployment-time
mistake that the deployment script's checks also catch, and the outcome is the same.

## To finish

Generate the mutants again for the current code (the oracle, treasury and hook changed after
the review) and run all of them. With the light profile that is about 55 minutes on 2 CPUs:

    gambit mutate --filename src/<file> --num_mutants <n> --seed 0 --solc <solc 0.8.26> \
      --solc_evm_version cancun --solc_remappings <the entries of remappings.txt>
    audit/logs/scripts/run-mutation.sh

# Baseline (commit 522881c, before Phase 4)

- `sizes.txt`: `forge build --sizes`, protocol contracts only.
- `gas-report.txt`: `forge test --gas-report --no-match-contract "Invariant|BaseMainnetFork"`
  (isolated mode, so every call includes 21,000 intrinsic gas; mock vault). One test fails
  in this mode: `test_record_worstCaseGasFitsHookBudget` (77,228 against a 70,000 limit),
  finding A8.
- `slither.txt`: Slither 0.11.6 on `src/` (`--filter-paths "lib/|test/|script/"`): 0 High,
  23 Medium, 12 Low, 3 Informational. Triage of the final run is in `audit/slither.md`.

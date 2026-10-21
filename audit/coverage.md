# Coverage (Phase 4, A11)

`forge coverage --ir-minimum` over the whole project runs out of memory on the 8 GB machine
that ran Phase 4: solc is killed while compiling Uniswap v4-core's `PoolManager` without the
optimizer. The numbers below therefore come from the suites that do not deploy a PoolManager:
`SpectrumProtocol.t.sol` (unit tests and invariants), `LossFrontRunning.t.sol`,
`ProtocolCapital.t.sol`, `ReviewFindings.t.sol` and `test/paper/`
(`audit/logs/scripts/coverage-lite.sh`). The hook and the deployment library are exercised by
the suites left out (`SpectralHook.t.sol`, `HookStart.t.sol`, `test/mainnet/`,
`test/realvault/`), so their figures here understate them. On a machine with 16 GB,
`make coverage` runs the whole project.

Final code (`audit-freeze-1`), 169 tests from the light suites:

| File | Lines | Statements | Branches | Functions |
|---|---:|---:|---:|---:|
| `src/SpectralStabilizer.sol` | 97.7% (211/216) | 95.9% (281/293) | 80.5% (33/41) | 100% (33/33) |
| `src/AutonomousTreasury.sol` | 99.0% (103/104) | 94.5% (137/145) | 75.0% (21/28) | 100% (15/15) |
| `src/SpectralToken.sol` | 95.7% (111/116) | 92.9% (105/113) | 80.0% (16/20) | 93.9% (31/33) |
| `src/SpectralEntropyOracle.sol` | 100% (70/70) | 98.0% (98/100) | 86.7% (13/15) | 100% (13/13) |
| `src/SpectrumLens.sol` | 77.3% (34/44) | 72.1% (44/61) | 0% (0/2) | 80.0% (8/10) |
| `src/libraries/SpectralPolicy.sol` | 100% (24/24) | 100% (29/29) | 100% (1/1) | 100% (7/7) |
| `src/libraries/SelfApproaching.sol` | 100% (36/36) | 100% (63/63) | 100% (5/5) | 100% (7/7) |
| `src/libraries/SpectralMath.sol` | 76.5% (62/81) | 80.4% (78/97) | 85.7% (6/7) | 75.0% (3/4) |
| `src/SpectralHook.sol` | not exercised by these suites | | | |
| **Total without the hook** | **94.2%** (651/691) | **92.7%** (835/901) | **79.8%** (95/119) | **95.9%** (117/122) |

Reading it:
- The stabilizer, treasury, token and oracle are covered almost line for line; the branches
  left are mostly defensive reverts (zero addresses, overflow casts, vault calls that cannot
  fail with the mock vault).
- `SpectralMath`'s figure is the least reliable: under `--ir-minimum` the source mapping of its
  inline assembly is approximate (forge warns about this). Its functions are fuzzed and checked
  against 80-digit references, and the FWHT is proven with Halmos (`audit/formal.md`).
- The lens's uncovered lines are views the light suites do not call; the mainnet scenarios do.
- The hook is tested by `test/SpectralHook.t.sol`, `test/HookStart.t.sol` and the mainnet
  scenarios, all on a real PoolManager, which this run leaves out.

The two gas-budget tests are skipped here: instrumentation inflates gas (a cold window close
reads 144,485 under coverage against 37,638 uninstrumented).

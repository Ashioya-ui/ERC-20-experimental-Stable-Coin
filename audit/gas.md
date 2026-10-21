# Gas and contract sizes

Measured by `test/Benchmarks.t.sol` (`make bench`), one fixed scenario per hot path, taken
from inside a contract call so the number is the same in normal and `--isolate` runs and is
what a real caller pays, including the CALL. The vault is a mock, so these are a **relative**
measure for comparing commits; the Base-fork suite measures the same calls against the real
waBasUSDC and Gauntlet USDC Prime.

"Before" is the Phase 4 starting point with the Track A fixes already in, so the figures
isolate the Track B work. `.gas-snapshot` is committed and CI fails on drift.

## Hot paths

Final numbers are for the frozen code (after the review fixes); "before" is the start of
Track B.

| Call | Before | After | Change | Target |
|---|---:|---:|---:|---|
| `mint` (1,000 USDC) | 180,565 | 97,620 | −45.9% | −25% ✓ (batched deposits) |
| `redeem` (1,000 sUSD) | 96,799 | 85,974 | −11.2% | −10% ✓ |
| `rebase` | 99,496 | 63,032 | −36.6% | −15% ✓ |
| `sync` (absorb a loss) | 54,533 | 31,255 | −42.7% | — |
| `rebalanceReserve` | 79,205 | 68,622 | −13.4% | — |
| `transfer` | 37,325 | 37,158 | −0.4% | −10% (not met, see below) |
| `reserveAssets` (view) | 22,667 | 22,688 | +0.1% | — |

| Library call | Before | After | Change | Target |
|---|---:|---:|---:|---|
| `spectralEntropy8` | 32,945 | 19,023 | −42.3% | ≤ 20,000 ✓ (stretch 15,000 not met) |
| `lnWad` | 2,297 | 1,105 | −51.9% | — |
| `fwht8` | 563 | 563 | — | — |
| `oracle.record` closing a window, cold storage | 50,352 | 37,638 | −25.3% | ≤ 38,000 ✓ |

Against real MetaMorpho v1.0 bytecode (`test/realvault/MorphoReplica.t.sol`, normal mode):

| Call | Gas |
|---|---:|
| mint 50 USDC, inside the deposit band (no vault call) | 72,373 |
| mint 500 USDC, crossing the band (batched MetaMorpho deposit) | 193,370 |
| redeem from the idle buffer | 55,649 |
| redeem through MetaMorpho | 151,084 |
| rebase with interest accrued | 54,678 |

## What changed

- **B1.** The reserve is valued once per state change and the value carried forward. The
  treasury's `sweep`, `depositReserve`, `withdrawReserve` and `rebalance` return the reserve
  value they already computed, and the stabilizer has `_syncLossWith` and `_assertSolventWith`
  that take it. A mint now makes 3 valuations instead of 6, each of which was three external
  calls (`vault.balanceOf`, `vault.previewRedeem`, `USDC.balanceOf` through the FiatToken
  proxy). No value is ever reused across a state change.
- **B2.** `ReentrancyGuardTransient` (EIP-1153, live on Base) in the stabilizer and treasury.
- **B3.** State packed: the three timestamps share one slot; `epochSupply`/`mintedInEpoch`
  share one; `churnLength`/`churnMax` share one; `churnMin`/`pendingVaultEta` share one.
  Amounts are `uint128` with `SafeCast` at every entry, and the bounds are in the comments:
  supply cannot exceed the reserve, and USDC's total supply is about 2^93 in sUSD wei.
- **B4.** In `spectralEntropy8`, everything after the normalisation uses plain arithmetic
  (the bounds are proved in the NatSpec: a squared coefficient is at most 6.4e37), the squares
  are recomputed instead of stored in a memory array, and the accumulation loops are
  `unchecked`. In `lnWad` the 12-term series is unrolled with constant divisors. The 80-digit
  reference tables for both `lnWad` and the entropy pass unchanged, as does the 1-wei accuracy
  bound.
- **B5.** `_sharesToDebit` costs one `mulDiv` on the common path; the balance is only
  recomputed when the ceiling lands above the holder's shares, which means they are sending
  everything or overdrawing.
- **B6.** `SpectrumLens` holds the convenience views (`quoteMint`, `quoteRedeem`,
  `reserveRatio`, `surplus`, `expansionRemaining`, `supplyCapRemaining`, `liquidAssets`). It
  is derived entirely from public state and has no privileges.
- **B7.** `.gas-snapshot` committed; `make snapshot`; CI runs `forge snapshot --check
  --tolerance 1`.

## Targets not met, and why

- **`mint`: met after Track B.** Track B alone reached −15.2%; the batched deposits that came
  with the limitation fixes skip the vault call on most mints (only a mint that takes idle funds
  more than 1% of the reserve above the target deposits, and then everything above the target
  at once), which brings the benchmark to −45.9%. A mint that crosses the band still pays the
  vault deposit: 193,370 gas against real MetaMorpho.
- **`transfer` −0.4% against a −10% target.** The scenario sends to an address with no shares,
  so a 22,100-gas cold `SSTORE` (zero to non-zero) dominates and no arithmetic change can move
  it. The second `mulDiv` that B5 removed is about 150 gas. A transfer to an existing holder
  costs about 20,000 less, and that part did improve.
- **`record`: met after the state packing.** Block number, timestamps and the average now
  share one slot, and the per-swap events are gone: 37,638 gas for a cold window close,
  including the review's block-level dust check (S-04). The hook's budget assertion stays at
  56,000 so that it also holds under `--isolate`.
- **`spectralEntropy8` 19,023 against a 15,000 stretch.** Eight `lnWad` calls at 1,105 each
  are 8,840 of it; the rest is the normalisation `mulDiv` (which must stay, because the
  library accepts any `uint256` input) and the two passes over the spectrum.

## Contract sizes

Limit 24,576 bytes; every contract keeps at least 1,024 bytes free (B6).

| Contract | Runtime | Free |
|---|---:|---:|
| SpectralStabilizer | 21,486 | 3,090 |
| AutonomousTreasury | 9,899 | 14,677 |
| SpectralToken | 9,194 | 15,382 |
| SpectralHook | 6,610 | 17,966 |
| SpectrumLens | 5,992 | 18,584 |
| SpectralEntropyOracle | 5,570 | 19,006 |
| WrappedSUSD | 5,352 | 19,224 |

The stabilizer grew during Track A (the vault allowlist, `AccessControlDefaultAdminRules`) and
came back down when the views moved to the lens. 3,090 bytes is the tightest margin; anything
substantial added to it should go to the lens or a new contract instead.

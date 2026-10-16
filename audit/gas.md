# Gas and contract sizes

Measured by `test/Benchmarks.t.sol` (`make bench`), one fixed scenario per hot path, taken
from inside a contract call so the number is the same in normal and `--isolate` runs and is
what a real caller pays, including the CALL. The vault is a mock, so these are a **relative**
measure for comparing commits; the Base-fork suite measures the same calls against the real
waBasUSDC and Gauntlet USDC Prime.

"Before" is the Phase 4 starting point with the Track A fixes already in, so the figures
isolate the Track B work. `.gas-snapshot` is committed and CI fails on drift.

## Hot paths

| Call | Before | After | Change | Target |
|---|---:|---:|---:|---|
| `mint` (1,000 USDC) | 180,565 | 153,108 | −15.2% | −25% (not met, see below) |
| `redeem` (1,000 sUSD) | 96,799 | 86,119 | −11.0% | −10% ✓ |
| `rebase` | 99,496 | 60,076 | −39.6% | −15% ✓ |
| `sync` (absorb a loss) | 54,533 | 30,560 | −44.0% | — |
| `rebalanceReserve` | 79,205 | 68,600 | −13.4% | — |
| `transfer` | 37,325 | 37,158 | −0.4% | −10% (not met, see below) |
| `reserveAssets` (view) | 22,667 | 22,666 | 0% | — |

| Library call | Before | After | Change | Target |
|---|---:|---:|---:|---|
| `spectralEntropy8` | 32,945 | 19,023 | −42.3% | ≤ 20,000 ✓ (stretch 15,000 not met) |
| `lnWad` | 2,297 | 1,105 | −51.9% | — |
| `fwht8` | 563 | 563 | — | — |
| `oracle.record` closing a window, cold storage | 50,352 | 41,121 | −18.3% | ≤ 38,000 (not met) |

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

- **`mint` −15.2% against a −25% target.** What is left is irreducible without changing what
  minting does: a USDC `transferFrom`, a vault `deposit`, an sUSD mint, and three reserve
  valuations that each have to read the vault after a state change. Dropping to two would mean
  reusing a valuation across the deposit, which is exactly the thing B1 forbids, since the
  vault's own rounding can move it.
- **`transfer` −0.4% against a −10% target.** The scenario sends to an address with no shares,
  so a 22,100-gas cold `SSTORE` (zero to non-zero) dominates and no arithmetic change can move
  it. The second `mulDiv` that B5 removed is about 150 gas. A transfer to an existing holder
  costs about 20,000 less, and that part did improve.
- **`record` closing a window at 41,121 against a 38,000 target.** The remaining cost is one
  cold `SSTORE` to the ring-buffer slot, the EMA slot, `lastFoldTime`, and the entropy
  computation itself at 19,023. Reaching 38,000 would mean a shorter logarithm series, which
  would break the 1-wei accuracy the reference tests pin. The budget the hook must carry is
  now asserted at 56,000 (41,121 normal, 54,821 isolated), down from 70,000.
- **`spectralEntropy8` 19,023 against a 15,000 stretch.** Eight `lnWad` calls at 1,105 each
  are 8,840 of it; the rest is the normalisation `mulDiv` (which must stay, because the
  library accepts any `uint256` input) and the two passes over the spectrum.

## Contract sizes

Limit 24,576 bytes; every contract keeps at least 1,024 bytes free (B6).

| Contract | Runtime | Free |
|---|---:|---:|
| SpectralStabilizer | 21,990 | 2,586 |
| AutonomousTreasury | 9,249 | 15,327 |
| SpectralToken | 9,194 | 15,382 |
| SpectralEntropyOracle | 5,329 | 19,247 |
| WrappedSUSD | 5,352 | 19,224 |
| SpectrumLens | 5,208 | 19,368 |
| SpectralHook | 5,184 | 19,392 |

The stabilizer grew during Track A (the vault allowlist, `AccessControlDefaultAdminRules`) and
came back down when the views moved to the lens. 2,586 bytes is the tightest margin; anything
substantial added to it should go to the lens or a new contract instead.

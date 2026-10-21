# Static analysis: Slither and Aderyn (Phase 4, A11)

Tools and provenance: `audit/tools.md`. Raw reports: `audit/reports/`.

## Slither 0.11.6

Command (the CI job runs exactly this; it fails on any untriaged Medium or High):

    slither . --filter-paths "lib/|test/|script/" --exclude-dependencies \
      --triage-database audit/slither.db.json --fail-medium

| Run | High | Medium | Low | Informational |
|---|---|---|---|---|
| Baseline, commit 522881c (`audit/baseline/slither.txt`) | 0 | 23 | 12 | 3 |
| Phase 4 code before triage | 0 | 36 | 18 | 4 |
| After the fixes and inline triage below | **0** | **0** | 18 | 4 |
| CI command (with `audit/slither.db.json`) | 0 | 0 | 0 | 0 shown, exit 0 |
| Final code, after the review fixes (audit-freeze-1) | **0** | **0** | 20 | 4 |
| CI command on the final code (database refreshed) | 0 | 0 | 0 | 0 shown, exit 0 |

The review fixes added four Mediums, all handled like the earlier ones: an uninitialized local
in `migrateVault` (now `= 0`), and three `unused-return` reports on deliberate partial tuple
reads (`initializePool` needs only the price from `getSlot0`; `_churnAfter` and `_commitChurn`
each need only part of `churnStep`'s results), each with an inline reason. The triage database
was regenerated because the review fixes moved the Low and Informational findings' source
lines; their categories are the ones triaged below.

The 13 extra Mediums come from B4 unrolling the `lnWad` series (each unrolled step is a
separate divide-before-multiply report) and from the new `SelfApproaching` and protocol-capital
code.

### Fixed in code

| Detector | Where | Fix |
|---|---|---|
| reentrancy-no-eth | `SpectralStabilizer.rebase` wrote `lastRebaseAt` after `token.setIndex` | Reordered: effects before the call. |
| uninitialized-local (4) | `spectralEntropy8` (`vmax`, `total`, `hRaw`), the stabilizer constructor (`startingVaultListed`) | Explicit `= 0` / `= false`; same bytecode under via-IR. |

### Triaged with an inline, reasoned `slither-disable` comment

Every suppression sits next to the code with its reason, so it moves with the code instead of
going stale in a database keyed by line numbers.

| Detector | Count | Where | Why it is not a bug |
|---|---|---|---|
| divide-before-multiply | 15 | `lnWad` series (14), `spectralEntropy8` (1) | Intended fixed-point arithmetic: each term is truncated on purpose and the total error is bounded and tested against 80-digit references (`lnWad` within 1 wei below 2^60, entropy within 38 wei). |
| incorrect-equality | 5 | `recoverLegacy` (`left == 0`), `reserveAssets` (`shares == 0`), `_depositExcess` (`amount == 0`), the oracle's per-block check, `redeem` (`assetsOut == 0`) | Guards, not balance checks an attacker can steer. Donated legacy shares only delay clearing until the next call, which redeems them as surplus (and dust below `LEGACY_DUST_ASSETS` no longer blocks clearing, A12). |
| reentrancy-no-eth | 4 | `executeVaultMigration`, `contributeCapital`, treasury `migrateVault` and `recoverLegacy` | `nonReentrant` on every state-changing entry point of both contracts; the calls go to the immutable token and treasury and, through them, to allowlisted vaults. |
| unused-return | 9 | `mint` (`sweep`, `depositReserve`, `token.mint`), `redeem` (`token.burn`), `contributeCapital` (`sweep`, `depositReserve`), treasury `rebalance` / `withdrawReserve` (`vault.withdraw`), `migrateVault` (`old.redeem`) | Only the reserve value is needed and it is re-measured right after; the share counts are not used. |
| uninitialized-local | 1 | `spectralEntropy8` memory array `x` | Zeroed memory; every element is written before it is read. |

### Accepted Lows and Informationals (in `audit/slither.db.json`)

| Detector | Count | Why |
|---|---|---|
| timestamp | 14 | Intended: epochs, the rebase interval, timelocks, the EMA weight, permit and EIP-3009 windows. The sequencer can skew `block.timestamp` by seconds; every comparison tolerates that. |
| reentrancy-benign | 2 | `nonReentrant`; the state written after the calls is the caller's own accounting. |
| reentrancy-events | 1 | Event order only: the hook logs `OracleRecordFailed` after the call it reports on. |
| calls-loop | 1 | Constructor only, at most `MAX_ALLOWED_VAULTS` = 4 `asset()` calls. |
| assembly | 2 | `fwht8`'s butterflies; fuzzed against the naive Hadamard product and checked by Halmos. |
| cyclomatic-complexity | 1 | The stabilizer constructor's validation; every branch is a revert tested on its own. |
| naming-convention | 1 | `DOMAIN_SEPARATOR()` is the name EIP-2612 requires. |

## Aderyn 0.6.8

Command: `aderyn . --src src`. Aderyn resolves compilers through `binaries.soliditylang.org`,
which this workspace's network policy refuses (403), so it was given the same solc 0.8.26
binary the build uses (verified against solc-bin, `audit/tools.md`). Report:
`audit/reports/aderyn.md`.

| Finding | Instances | Assessment |
|---|---|---|
| H-1 State change after external call | 25 | **No issue.** 14 are constructors, which cannot be re-entered (the contract has no code yet) and only make view calls. 5 are in `rebase` and `proposeVault` after `view` calls, which compile to STATICCALL and cannot change state. The rest are `recoverLegacy` and `migrateVault`, covered above (`nonReentrant`, stabilizer-only, allowlisted vaults). |
| L-1 Centralization risk | 8 | By design and documented: the admin Safe and the guardian (`RUNBOOK_MAINNET.md`, README limitation 4). Redemption and loss absorption cannot be paused, and no role can send reserve funds to an address of its choosing. |
| L-2 Internal function used once | 3 | Kept for readability. |
| L-3 Large numeric literal; L-4 literal instead of constant | 3; 21 | Fixed-point constants and table indices, commented in place. |
| L-5 `nonReentrant` not the first modifier | 8 | The modifiers before it (`onlyStabilizer`, `onlyRole`) make no external calls, so the order cannot matter. |
| L-6 PUSH0 opcode | 10 | Base supports Shanghai and Cancun. |
| L-7 Loop containing revert | 1 | `lnWad` inside the entropy loop reverts only for 0, which the loop skips. |
| L-8 State variable could be immutable | 1 | `_allowedVaults` is a dynamic array, which cannot be immutable. It is written only in the constructor. |
| L-9 Unchecked return; L-10 uninitialized local | 12; 7 | The same sites as Slither's unused-return and uninitialized-local, triaged above. |
| L-11 Floating pragma | 10 | Every build, test and deployment pins solc 0.8.26 in `foundry.toml`, and verification uses that exact version. |
| L-12 Public function not used internally | several | Style only. |

## Result

No High or Medium finding remains open in either tool. The CI job fails on any new Medium or
High until it is fixed or triaged here.

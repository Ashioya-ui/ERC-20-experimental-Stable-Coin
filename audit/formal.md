# Formal checks (Phase 4, A11)

What Halmos proved about the production code, over which inputs and with which solver, and
what it did not prove. "PASS" below means the solver showed that no input in the stated domain
violates the assertion, on every execution path Halmos explored: a proof, relative to Halmos's
model of the EVM and to the solver being correct. "TIMEOUT" means no answer within the limit,
which is neither a proof nor a counterexample.

## Setup

| | |
|---|---|
| Tool | Halmos 0.3.3 (`github.com/a16z/halmos` at `ba94bdc`), symbolic execution of the compiled bytecode |
| Solvers | cvc5 1.2.1 in integer mode (Halmos's `cvc5-int`: `--solve-bv-as-int=iand --iand-mode=bitwise`); Bitwuzla 0.8.1 with abstraction (`bitwuzla-abs`). Both are fetched by Halmos from their GitHub releases and checked against the sha256 pinned in Halmos's `solvers.py`. z3 4.12.6 decides path feasibility. |
| Options | `--loop 9`, `--solver-timeout-assertion 10m` (per query) |
| Compiler | the production settings: solc 0.8.26, via-IR, optimizer 44,444,444 runs, EVM cancun |
| Code under test | `SpectralToken` deployed as is; `SpectralPolicy` (the library the stabilizer's curves and churn step compile from) and `SpectralMath.fwht8` through thin harnesses |
| Checks | `test/halmos/Properties.t.sol` |
| Machine | 2 CPUs, shared with other jobs; times are indicative |

Each check runs with the solver that finishes it. cvc5 turns bit-vector arithmetic into integer
arithmetic and settles linear divisions by constants in milliseconds; Bitwuzla bit-blasts and is
the one that finishes the quadratic fee curves. A PASS from either is a proof.

    make formal          # both passes; see the Makefile

## Results

### SpectralPolicy: the policy curves and the churn step

| Check | Property | Inputs | Solver | Result | Time |
|---|---|---|---|---|---|
| `check_curvesClampAboveOne` | every curve gives its h = 1 value for every h > 1e18 | all `uint256` | cvc5 | PASS | 0.01 s |
| `check_bufferBoundedAndFloored` | 2.75% <= buffer <= 5%, and never below its value at h = 0.5 (D4) | all `uint256` | cvc5 | PASS | 0.16 s |
| `check_bufferLocallyMonotone` | buffer(h) <= buffer(h + 1) | h < 1e18 | cvc5 | PASS | 0.28 s |
| `check_expansionCapBounded` | 2% <= cap <= 11% (20% before Phase 5) | h <= 1e18 | cvc5 | PASS | 1.82 s (Phase 5) |
| `check_expansionCapLocallyMonotone` | cap(h) >= cap(h + 1) | h < 1e18 | cvc5 | PASS | 0.38 s (Phase 5) |
| `check_expansionCapNeverAboveNeutral` | cap(h) <= cap(0.5): H can tighten the cap, never loosen it (Phase 5, P5-01) | all `uint256` | cvc5 | PASS | 0.16 s |
| `check_rebaseStepBounded` | 0.5 bp <= step <= 1 bp | h <= 1e18 | cvc5 | PASS | 0.17 s |
| `check_rebaseStepLocallyMonotone` | step(h) >= step(h + 1) | h < 1e18 | cvc5 | PASS | 0.17 s |
| `check_mintFeeBounded` | 1 bp <= mint fee <= 25 bp | h <= 1e18 | Bitwuzla | PASS | 26 s |
| `check_redeemFeeBounded` | 1 bp <= redeem fee <= 10 bp | h <= 1e18 | Bitwuzla | PASS | 125 s |
| `check_rebaseStepBelowRoundTripFees` | at every H a rebase step is worth less than a mint-and-redeem round trip's fees (anti-sandwich) | all `uint256` | Bitwuzla | PASS | 7.5 s |
| `check_churnStepNeverRevertsAndIsExact` | with the old index inside the window's range, the step never reverts, and its length, maximum, minimum, range and verdict are exact | all `uint128` (5 inputs) | cvc5 | PASS | 0.89 s |
| `check_monotonePathNeverDeferred` | a monotone path (L = D) is never deferred | all `uint128` (3 inputs) | cvc5 | PASS | 0.67 s |
| `check_mintFeeLocallyMonotone` | fee(h) <= fee(h + 1) | h < 1e18 | Bitwuzla, cvc5 | **TIMEOUT** | 600 s |
| `check_redeemFeeLocallyMonotone` | fee(h) <= fee(h + 1) | h < 1e18 | Bitwuzla | **TIMEOUT** | 600 s |

**Why these cover every input.** On the integers, f(h) <= f(h + 1) for every h < 1e18 is the
same statement as f(h1) <= f(h2) for all h1 <= h2 <= 1e18 (induction on h2 - h1). Together with
`check_curvesClampAboveOne`, which shows that every h above 1e18 behaves exactly like 1e18, the
monotonicity and bounds hold for all of `uint256`. One-input queries are used because the
two-input form (h1 <= h2) timed out at 10 minutes even for the linear curves.

**The churn step.** The stabilizer keeps the current index inside the window's range: the
window starts at the current index and every move widens the range to include the new index.
Under that condition the step cannot revert, so loss absorption (`sync`, which records every
index move) can never be blocked by it. The remaining casts in `_commitChurn` revert only if the
window's total movement exceeds 2^128, about 3.4e20 times the starting index.

**The two timeouts.** The mint and redeem fees are quadratic in h. That they never decrease is
elementary: (MAX - MIN) * h^2 grows with h, the floor of a quotient by a constant grows with its
numerator, and after the clamp nothing can wrap (the largest intermediate value is 2.4e51,
below 2^172). Neither solver confirmed it within 10 minutes. The fuzz tests
`testFuzz_policyIsMonotoneInEntropy` (random pairs) and `testFuzz_feeCurvesMonotoneOnAdjacentInputs`
(neighbouring inputs, where flooring would show first) cover it at 1,000 runs, 10,000 in CI.

### SpectralMath: the Walsh-Hadamard transform

| Check | Property | Inputs | Solver | Result | Time |
|---|---|---|---|---|---|
| `check_fwhtIsAnInvolutionUpTo8` | H8(H8(x)) = 8x | `int256[8]`, each \|x_i\| < 2^100 | Bitwuzla | PASS | 0.39 s |
| `check_fwhtIsLinear` | H8(x + y) = H8(x) + H8(y) | two `int256[8]`, \|x_i\|, \|y_i\| < 2^100 | Bitwuzla | PASS | 0.80 s |

The bound 2^100 keeps every butterfly sum far from overflow; the oracle feeds the transform
saturated `uint128` volumes, so real inputs are below 2^128 and the transform's own NatSpec
covers the rest.

### SpectralToken: share arithmetic

| Check | Property | Inputs | Solver | Result |
|---|---|---|---|---|
| `check_transferNeverShortchangesRecipient` | the recipient gains at least `amount`, the sender loses at least `amount` | index 0.5–5, amounts up to 1e30 | Bitwuzla | **not finished** |
| `check_transferConservesSharesAndSupply` | total shares and supply unchanged; two balances never exceed supply | same | Bitwuzla | **not finished** |
| `check_mintRoundsDown` | supply rises by at most `amount` | same | Bitwuzla | **not finished** |
| `check_burnRoundsUp` | supply falls by at least `amount` | same | Bitwuzla | **not finished** |

The four checks ran together for about four hours without a result. The token's conversions go
through OpenZeppelin's 512-bit `mulDiv`, whose symbolic form (a `mulmod`, then Newton
iterations for the inverse) is beyond what these solvers settle at this width. The same
properties are fuzzed (`testFuzz_transferNeverShortchangesRecipient` and the token suite) and
checked as invariants after every call (`invariant_shareAccounting`,
`invariant_balancesCoveredBySupply`), and the reserve floor is enforced on-chain after every
value-moving call. A future attempt could run them one at a time with cvc5 and a tighter index
range.

## What changed to make these provable

Solidity's checked multiplication `a * b` compiles to a guard that tests `b == (a * b) / a`.
When `a` is a variable, the solver query divides by a variable, and none of Bitwuzla, cvc5 or
Yices settled such queries within 10 minutes: the quadratic fees (`h * h`) and the churn step
(`len2 * WAD`) all timed out. Commit `fce6ec5` therefore:

- computes every curve in an `unchecked` block after the clamp, with the bound written next to
  each line (every product is below 2.4e51 and every subtraction is of a smaller value);
- types the churn step's inputs as `uint128` (the window's statistics already live in uint128
  slots, and the stabilizer converts the indices with SafeCast), so its two products, below
  2^191, are unchecked too. Additions and subtractions stay checked.

No reachable input behaves differently: 207 tests pass unchanged, and the checks above now
finish in seconds.

## What is not proven

- `lnWad` and `spectralEntropy8`: a Taylor series and a logarithm, beyond what these solvers
  handle. They are fuzzed and checked against values computed with 80-digit arithmetic
  (`lnWad` within 1 wei at 92 reference points, the entropy within 38 wei), and `lnWad` is
  emulated bit-exactly in Python over 300,000 random inputs.
- The stabilizer's flows end to end (mint, redeem, rebase, sync, migration). Solvency is
  enforced on-chain instead: every call that moves value ends with
  `reserveValue() >= totalSupply()` and reverts otherwise, and `sync` lowers the index so that
  supply is at most the reserve (`floor`). The invariant suite checks the floor, share
  accounting, the caps, the churn budget and the attacker's no-free-lunch bound after every one
  of 262,144 calls per invariant in CI, and ends each run with a bank run.
- The treasury and its ERC-4626 vault: covered by unit tests, the real MetaMorpho bytecode
  (`test/realvault/`) and the Base fork suite.
- The two fee-monotonicity checks and the four token checks above.

## Earlier attempts, for the record

| Configuration | Outcome |
|---|---|
| z3 as assertion solver | segmentation fault |
| Yices 2.6.4, two-input monotonicity | timeout |
| Bitwuzla with abstraction, two-input monotonicity | timeout (600 s) |
| Checked arithmetic, one-input buffer monotonicity | Bitwuzla-abs 600 s, plain Bitwuzla and Yices 120 s: timeout; cvc5-int: PASS in 0.26 s |
| Checked arithmetic, churn step with `uint256` inputs | cvc5-int 10 min per query, Bitwuzla, cvc5 and Yices 60 s: timeout |

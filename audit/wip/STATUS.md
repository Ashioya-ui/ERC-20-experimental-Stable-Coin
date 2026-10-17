# Phase 4: where it stands (paused 2026-10-17)

Branch `phase-4-hardening`. Work stopped here to save credits; resume on Wednesday.

## Done and committed

- Track A: A0–A10, A12, A13 and the static part of A11 (`audit/findings.md`, `audit/slither.md`).
- Track B: B1–B8, including protocol capital (1,250 USDC at launch).
- Track C: C1–C5. The churn budget now uses Theorem 4.3's **proven** constant
  (3.135631968196535891); no code depends on Conjecture 1.2 any more.
- Limitations fixed: batched vault deposits, packed oracle state (`record()` window close
  37,261 gas), dust exits, legacy-dust rules, SECURITY.md.
- D1/D5: Base Sepolia config (`config/84532.json`), labelled test vaults that refuse chain
  8453, and a `network` input on the deploy workflow.
- A11 (formal): the policy library computes unchecked after the clamp, and the churn step
  takes uint128 inputs, so the SMT solvers can finish (commit `fce6ec5`).
- Tests on `fce6ec5`: 207 passed, 1 skipped (the Base fork suite needs `BASE_RPC_URL`).
  `.gas-snapshot` refreshed on that commit.
- Sizes (runtime bytes, limit 24,576): Stabilizer 21,486 (3,090 free), Treasury 9,880,
  Token 9,194, Lens 5,992, wsUSD 5,352, Oracle 5,270, Hook 5,184.

## Halmos so far (`audit/wip/halmos/`)

Halmos 0.3.3, `--loop 9`, 10-minute limit per solver query. cvc5 1.2.1 in integer mode
(`cvc5-int`) and Bitwuzla 0.8.1 with abstraction (`bitwuzla-abs`); each check ran with the
solver that finishes it (`audit/wip/scripts/run-halmos3.sh`).

| Result | Checks |
|---|---|
| PASS (16) | FWHT involution and linearity; every policy curve clamps above 1; buffer bounded, floored and monotone; expansion cap bounded and monotone; rebase step bounded and monotone; rebase step below round-trip fees; mint fee bounded; redeem fee bounded; churn step never reverts and is exact (uint128 inputs); a monotone path is never deferred |
| TIMEOUT (2) | mint fee and redeem fee locally monotone (quadratic in h): fuzzed only for now |
| Unfinished | HalmosToken (4 share-arithmetic checks) ran about 4 hours with bitwuzla-abs without a result. Next try: cvc5-int, or tighter bounds |

Not attempted: `lnWad` and the entropy (nonlinear; covered by fuzzing and 80-digit references),
and the stabilizer flows end to end (covered by the invariants and the on-chain floor check).

## Still to do, in order

1. **Independent review.** Brief: `audit/wip/review/PROMPT.md`. Give it to a fresh agent that
   has not seen this work, read-only. The first attempt hit the usage limit before reporting
   and changed nothing. Fix what it finds (failing test first) and save `audit/review.md`.
2. `audit/formal.md` from the results above; switch the Makefile's `formal` target to the
   two-solver split.
3. Mutation testing (38 Gambit mutants; `audit/wip/scripts/run-mutation.sh`) and `make coverage`.
4. Final checks on the final commit: `FOUNDRY_PROFILE=ci forge test`, `forge test --isolate`,
   Slither (`make analyze`), sizes, lint, actionlint, `script/check-deps.sh`, the rehearsal
   (commit `rehearsal/latest.log`).
5. Docs. **The README is stale:** it still lists "C_diam is a conjecture" as limitation 1, the
   50 bp mint-fee ceiling (now 25 bp), 135 tests and old gas and size figures. Also
   RUNBOOK_MAINNET.md (Sepolia section, 14 deploy transactions or 16 on Sepolia, 1,252 USDC
   for the deployer), `audit/gas.md`, new rows in `audit/findings.md`, the threat model,
   `audit/README.md` (D2) and the PROMPTS.md status.
6. `REPORT_PHASE4.md`, then tag `audit-freeze-1`.

## Not before mainnet

- Steps 1–6 done, and every review finding fixed or written up.
- The Sepolia dress rehearsal through the workflow (`network = base-sepolia`): dry run first,
  then broadcast.
- Your Safe and guardian addresses in `config/8453.json`.
- Legal advice (the US GENIUS Act bans yield on payment stablecoins; Kenya's VASP Act requires
  a licence to issue one). Launch only as the guarded, experimental token.
- An external audit before raising the 25,000 sUSD cap.

The scripts in `audit/wip/scripts/` use absolute paths from the machine that ran them; adjust
them before reuse.

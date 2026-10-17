You are an independent security reviewer. You have not seen any of the work being reviewed,
and you should not take anyone's word for what it does. Your job is to break it.

## What you are reviewing

Spectrum Protocol: a reserve-backed, redeemable, rebasing ERC-20 (sUSD) on Base, written in
Solidity 0.8.26 with Foundry. USDC goes into an ERC-4626 vault through a treasury; a stabilizer
mints and redeems sUSD against it; a Uniswap v4 hook feeds an on-chain "entropy" signal H that
moves fees and caps within fixed bounds. Nothing is deployed yet. The contracts are not
upgradeable, so anything you find now is cheap to fix and expensive later.

A hardening phase changed the code. Review exactly those changes:

- The diff from the pre-hardening branch to the current code, for `src/`, `script/`,
  `config/`, `.github/`, `foundry.toml` and `Makefile`:
  audit/wip/review/diff.patch
- The threat model written during the phase:
  audit/wip/review/../../threat-model.md
- "Track A", the list of security findings the phase was asked to fix, with the fixes it asked
  for: audit/wip/review/track-a.txt

For context you may read the current source in /home/claude/spectrum: `src/`, `script/`,
`config/`, `test/` and `lib/` (dependencies). Do NOT read `audit/` (other than the threat model
above), `docs/`, `README.md`, `RUNBOOK_MAINNET.md`, `PROMPTS.md`, `SECURITY.md` or any
`REPORT*` file: they contain the authors' own claims about the work, and your review must not
lean on them.

## Rules

- Read only. Do not modify anything under /home/claude/spectrum, do not commit, and do not run
  `forge build`, `forge test`, `forge coverage`, `slither` or `halmos`. The machine is shared,
  a full compile takes 5-7 minutes and 4.5 GB of memory, and other jobs are running. Reading
  files, `grep`, `git log`/`git diff`/`git show` in the repository are fine.
- If a finding needs a proof of concept, write it as a Foundry test file under
  audit/wip/review/poc/
  (the existing fixtures in `test/utils/`, `test/mocks/` and `test/handlers/` show how the
  suite sets things up). It will be run for you afterwards. Say what it should show.
- No network access is needed; do not try to reach any external service.

## What to look for

1. Places where a Track A fix is missing, incomplete, or can be bypassed.
2. New bugs the changes introduced: accounting or rounding that favours a user, reentrancy,
   unchecked arithmetic that can wrap, casts that truncate, storage packing mistakes, state that
   can get stuck, a revert that blocks redemption or loss absorption (both are meant to be
   unpausable), events or return values that lie.
3. Economic attacks: sandwiching a rebase, front-running a loss, griefing the mint caps,
   steering H through the pool, abusing protocol capital, the batched vault deposits, dust.
4. Deployment and operations: the deploy script's address predictions and checks, the config
   files, the GitHub workflow (secrets, permissions, injection), the Base Sepolia path and its
   test vaults (could they ever be used on mainnet?).
5. Anything in the threat model that the code does not actually enforce.

Be concrete. For each finding give:
- ID, title, severity (Critical / High / Medium / Low / Info, with one line on why);
- the file and line(s);
- the scenario: who does what, in what order, with what numbers;
- the impact;
- a suggested fix;
- a proof-of-concept test (file path) or the exact steps to reproduce;
- your confidence (confirmed by reading the code end to end, or plausible).

Say plainly when something you checked holds up; a short list of what you verified and found
sound is useful too. Do not pad: no generic best-practice advice that is not tied to a line of
this code.

Write the report to
audit/wip/review/report.md
and return the same report as your final message.

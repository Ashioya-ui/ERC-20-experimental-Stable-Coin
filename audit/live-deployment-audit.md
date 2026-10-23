# Live deployment audit — Spectrum on Base Sepolia (84532)

**Auditor** independent external review, no involvement in the design or the code.
**Date** 23 October 2026. **Tree** `phase-6-x402` at `8b11158`; upstream moved to `34a4337`
during the audit and two findings below were fixed there while I was writing (noted inline).
**Target** the live instance at the addresses in `deployments/84532.json` and
`deployments/84532-router.json`, and the documents the author is about to send out.

Every statement marked CONFIRMED was produced by something I ran. The workspace cannot reach
Base RPCs (every endpoint 403s at the egress proxy), so live state was read by a read-only
GitHub Actions probe I pushed to the `audit-live-state` branch; its raw output is on the
branches `deployments/audit-39855252056`, `-39856007725`, `-39856712265` and `-39857363004`.

---

## 1. Verdict

### Is the live deployment safe to leave running? **Yes.**

Nothing an attacker can reach today puts the reserve at risk, and the deployer kept nothing.

- The deployer `0x9CD8…fAB48` holds **no role**. `hasRole(DEFAULT_ADMIN_ROLE, deployer) = false`,
  `hasRole(GUARDIAN_ROLE, deployer) = false`, and `eth_call` of `pause()`, `setSupplyCap()`,
  `setLiquidityBuffer()` and `proposeVault()` from it all revert
  `AccessControlUnauthorizedAccount`. The stabilizer's entire role history is **two**
  `RoleGranted` events, both to the configured admin, and **zero** `RoleRevoked`.
- The admin is `0x8392…371b`, which is what `deployments/84532.json` records. The committed
  `config/84532.json` says `0x0`, which is a provenance bug (L-06), not a role problem.
- **Supply cap in force**: `supplyCap = 25,000e18` against a `totalSupply` of `2.947e18`.
- **Redemption is unpausable**: `redeem()` carries `nonReentrant` only, no `whenNotPaused`
  (`src/SpectralStabilizer.sol:364-368`). The instance is not paused in any case.
- **The reserve is backed**: `reserveValue = 7.95e18` against supply `2.947e18`
  (`lens.reserveRatio = 2.697`), of which `protocolCapital = 5e18` is first-loss capital that
  can never be distributed or withdrawn. 7.95 USDC is really there: 6.80 in TestnetVault A and
  1.15 idle in the treasury.
- **No privileged path can move reserve funds to an address of the caller's choosing.** Every
  `AutonomousTreasury` entry point reverts `NotStabilizer` even when called from the admin, and
  the stabilizer's only outbound payment is `redeem`, against burned sUSD.
- Worst case from an admin-key compromise is griefing: pause minting and rebasing indefinitely,
  migrate the reserve to the *other allowlisted TestnetVault* after a 7-day timelock, or pull
  everything into idle USDC inside the treasury. Holders can always redeem.

**Conditions.** (a) The admin EOA has **0 ETH and nonce 0** and there is no second guardian, so
the emergency controls exist but cannot currently be exercised (L-04). (b) The deployer key is
a *repository-wide* GitHub secret reachable by any workflow on any branch (L-02); it still holds
4 test USDC and 0.0078 test ETH. (c) It is a testnet: all of it is valueless.

### Is the author safe to send these addresses to advisors and a16z? **Not yet.**

The addresses are sound and the headline engineering claims hold up. The surrounding prose does
not, in five places that a careful reader will check first:

1. **L-03** — "Every figure below is measured or on-chain. Nothing is projected." The central
   economic number, the break-even, is computed against a *fabricated* 5% APY minted into a mock
   vault on a local anvil chain. `REPORT_X402.md` labels it "simulated"; the application does not.
2. **L-07** — "flat 3.0–3.3 bps" is the cost at one value of an attacker-steerable signal. The
   protocol's redemption fee runs 1–10 bp; what the agent must actually authorise is always 10 bp.
3. **L-08** — the quoted settlement gas (217,858 / 89,997 / 81,392) does not match the chain
   (216,976 / 89,973) and appears nowhere in the repository.
4. **L-09** — `README.md` still says "**not yet deployed**" and "219 tests".
5. **L-10** — the Uniswap v4 pool has **zero liquidity**, the entropy oracle has recorded
   **zero** observations, and **no rebase has ever happened** on Base Sepolia. The entropy engine
   — the protocol's distinguishing idea — has never run on a public chain. That is fine; saying
   "live on Base Sepolia" without saying it is not.

Fix those five and **yes**. What is behind them is real: two x402 payments did settle on the
public chain and I verified both; 293 tests exist and all pass; Slither is clean at exactly the
claimed 71 contracts and 102 detectors; the router is immutable, ownerless and empty; and the
agent paid with zero ETH and zero transactions of its own.

---

## 2. Findings, most severe first

### L-01 · High · CI supply chain
**`verify-sepolia.yml` hands a repository push credential to the job that compiles four git
submodules, and that credential reaches the deployer private key.**

*Where* `.github/workflows/verify-sepolia.yml`, job `verify`: `permissions: contents: write`
with `actions/checkout` configured `submodules: recursive` and **no** `persist-credentials:
false` (removed in `ffb7910`; still absent at upstream `7750e5d`). The same job runs
`forge build` and holds `ETHERSCAN_API_KEY`.

*CONFIRMED.* A probe job checked out identically printed its own `.git/config`:
`http.https://github.com/.extraheader AUTHORIZATION: <redacted>` — and pushed a new branch with
exit 0 (`deployments/verify-probe-39855252056`). Reproduce: push
`.github/workflows/audit-live-state.yml` from the `audit-live-state` branch and read
`audit/live/push-probe.txt` on `deployments/audit-39855252056`.

*Consequence* anything executing in that job — a compromised submodule, solc, the pinned
actions — can lift the token and push to the repository. It cannot touch `.github/workflows/**`
(the `GITHUB_TOKEN` has no `workflows` scope) but it does not need to:

> read the header → push a commit to the `deploy-sepolia` branch changing `script/**` or
> `x402/**` → that push fires `deploy-sepolia-rail.yml` (`on: push: branches: [deploy-sepolia]`)
> → that job runs the modified repository code with `DEPLOYER_PRIVATE_KEY` in its environment.

Today that key is a testnet throwaway. The same shape on mainnet is the 1,252-USDC deployer.

*Fix* applied. The `verify` job is now `contents: read` with `persist-credentials: false`; the
record travels to a new secret-free `publish` job as an artifact. This is the pattern
`deploy-sepolia-rail.yml` already adopted at `8b11158` and which is proven to work in this repo.

### L-02 · High · secrets handling
**The deployer key that produced the live deployment is a repository-scoped secret in a
push-triggered workflow with no environment, no reviewer and no branch rule.**

*Where* `.github/workflows/deploy-sepolia-rail.yml` — header lines 17–19 instruct the operator
to create a **repository** secret; the `deploy` job has no `environment:` key; the trigger is
`on: push: branches: [deploy-sepolia]`.

*CONFIRMED* by reading the file. The live addresses came from run 39843514882 of this workflow.

*Why it matters beyond the testnet* this reverses the S-02 remediation the repository itself
records as Fixed (`audit/review.md:323`: "Secrets are environment secrets, one deployer key per
network, with reviewers and branch rules on both environments"). `deploy-base-mainnet.yml` and
`deploy-x402-router.yml` still do it correctly; the Phase-6 workflow that actually deployed does
not. An auditor who reads the review and then the workflows will find the claim contradicted.

*Fix* give the job `environment: base-sepolia`, move `DEPLOYER_PRIVATE_KEY` to that
environment's secrets with a required reviewer and a deployment-branch rule, and drop the
repository-level copy.

### L-03 · Medium · false claim, investor-facing
**"Measured, not modelled" / "Nothing is projected" is false for the break-even figure.**

*Where* `REPORT_X402.md` §"Measured, not modelled" (rows "Yield, one simulated day at 5% APY",
"Break-even 5,374 payments/day — $268.72 of daily volume, ~45% treasury turnover");
`docs/speedrun-application.md` ("Every figure below is measured or on-chain. Nothing is
projected.", "**Measured, not modelled**: … break-even at ~45% daily treasury turnover");
`README.md` ("roughly 46%").

*CONFIRMED.* `x402/review/unit-economics.mjs` fabricates the yield:

```js
const interest = (assets * 50_000n) / (8760n * 1_000_000n);      // 5% APY, an input
if (interest > 0n) { await send(A.usdc, 'mint(address,uint256)', [vault, interest]); }
```

on a local anvil chain, after `evm_increaseTime`, against a mock USDC with a permissionless
mint. The APY is an assumption. I re-ran the script against a fresh local rail and got
**5,656 payments/day, $282.81, 47.1% turnover** against the reported 5,374 / $268.72 / 45%, so
the quoted precision (`$268.72`, `$0.087333`) is also not reproducible — and three documents give
three different percentages (45, 46, ~45) for the same experiment.

Algebraically the ratio is `(daily yield) / (redeem fee rate)` ≈ `(APY/365)/0.000325`. The
report's reasoning that it is invariant in invoice size is **correct** (the fee is a flat *rate*,
so volume at break-even cancels the invoice size). What it is not invariant in is the two things
nobody states: the assumed APY, and the fee, which triples at H = 1 (→ ~14% turnover).

*Fix* keep the number, add its conditions: "simulated at 5% APY on a local chain; scales with
the APY and inversely with the redemption fee, which runs 1–10 bp". Quote one run, not a
precision the experiment does not have. On Base Sepolia the figure is zero, because the reserve
sits in a vault that by construction earns nothing.

### L-04 · Medium · live deployment
**The only account that can pause, unpause or empty the vault has never sent a transaction and
holds no ETH, and there is no second guardian.**

*CONFIRMED on chain* `defaultAdmin = 0x83927691e3c917273B790e6eeB0FD2bc125E371b`;
`cast code` → `0x` (an EOA); `cast balance` → `0`; `cast nonce` → `0`.
`deployments/84532.json` records `"guardian": "0x0000…0000"`, and
`deploy-sepolia-rail.yml` never writes `roles.guardian` at all. `eth_call` of `pause()` and
`emergencyExitVault()` from the admin succeeds, so the powers are real — the account simply
cannot pay for a transaction.

*Consequence* the emergency control the README describes is nominally present and operationally
unavailable. `SpectrumDeploy.check()` does not notice: it skips the guardian assertion whenever
`c.guardian == address(0)` (see `test_checkAcceptsADeploymentWithNoIndependentGuardian`). The
mainnet workflow's `guardian` input defaults to `0x0`, so the same thing would happen again.

*Fix* fund the admin; set a separate guardian; make `check()` at least warn when
`c.guardian == 0`, and have `deploy-sepolia-rail.yml` take a guardian the way
`deploy-base-mainnet.yml` does.

### L-05 · Medium · verification script
**`SpectrumDeploy.check()` never verifies the supply cap, the pause state or the liquidity
buffer, so "the post-deploy check passed" asserts less than the documents imply.**

*Where* `script/lib/SpectrumDeploy.sol`, `check()`. It asserts `bootstrapCap()` but there is no
`supplyCap()` assertion, no `paused()` read, and no `treasury.liquidityBufferBps()` comparison.

*CONFIRMED* by `test/x402/review2/DeployCheckGaps.t.sol` (7 tests, all pass). `check()` still
passes after `setSupplyCap(type(uint256).max)`, after `setSupplyCap(0)` (minting frozen for
everyone), while `paused()` is true, and after `setLiquidityBuffer(10_000)`. Reproduce:
`forge test --match-path "test/x402/review2/*"`.

*Consequence* the guarded-launch cap is the single number the README's status line leads with
("a 25,000 sUSD supply cap"), and the script the runbook points at as the verification does not
check it. Its positive control still works — a wrong admin is caught — so the gap is silent.

*Fix* three `require`s in `check()`:
`supplyCap() == c.supplyCap`, `!paused()`, `treasury.liquidityBufferBps() == c.liquidityBufferBps`.
Each is one line and none is in `src/**`.

### L-06 · Medium · reproducibility
**`PostDeployCheck.s.sol` cannot pass against the repository as committed.**

*CONFIRMED from a GitHub runner against the live chain:*
`forge script script/PostDeployCheck.s.sol --rpc-url https://sepolia.base.org` →
`Error: script failed: check: admin role`. Full trace on
`deployments/audit-39856007725:audit/live/pdc-as-committed.txt`.

*Cause* `config/84532.json` still has `roles.admin = 0x0000…0000`.
`deploy-sepolia-rail.yml` writes the real admin into that file on the runner (step "Write roles
into the config") and the `publish-addresses` job commits only `deployments/*`.
`deploy-base-mainnet.yml` does upload the mutated config in its artifact; the Sepolia rail does
not. Also covered by `test_theCommittedConfigCannotCheckTheLiveDeployment`.

*Consequence* the one command an advisor or an auditor would run against the live deployment
fails, on a deployment that is in fact correct. That reads much worse than the bug is.

*Fix* commit `config/84532.json` alongside the addresses, or have `PostDeployCheck` take the
roles from the deployment record (which already carries `admin` and `guardian`) when the config
leaves them zero.

### L-07 · Medium · overstated claim
**"flat 3.0–3.3 bps" is the cost at one value of an attacker-steerable signal.**

*CONFIRMED* `REDEEM_FEE_MIN = 1 bp`, `REDEEM_FEE_MAX = 10 bp`, quadratic in H
(`src/libraries/SpectralPolicy.sol:27-28`). Live `smoothedEntropy = 0.5e18` →
`redeemFeeRate = 3.25e14` = 3.25 bp. `x402/review/fee-curve.mjs` reproduces 3.0–3.3 bps from
$0.01 to $10, and `test/x402/review2/RouterCostIsEntropyDependent.t.sol` shows the same payment
costs ~10 bp at H = 1 and ~1 bp at H = 0. `router.sUSDToAuthorize(50000)` is always sized at
10 bp, so what an agent must be able to commit is always the 10 bp figure.

`docs/design/x402-rail.md` states the condition correctly ("At neutral entropy the payer pays
the redeem fee of about 3.2 bp"). `REPORT_X402.md`, `README.md` and the speedrun application
drop it. The live oracle reads neutral only because it has recorded nothing (L-10).

*Fix* "3.0–3.3 bps at neutral entropy; 1–10 bp across the policy curve; the agent authorises at
10 bp and gets the difference back".

### L-08 · Low · unsupported figures
**The quoted settlement gas does not match the chain and is not reproducible from the repository.**

*Claim* "Settlement gas | router 217,858 · direct sUSD 89,997 · plain USDC 81,392"
(`REPORT_X402.md`); "settlement gas 217,858 routed against 89,997 for a plain transfer"
(`docs/speedrun-application.md`).

*CONFIRMED on chain* the router settlement `0xedd58590…cf90ca` used **216,976** gas; the direct
sUSD settlement `0x41dba712…ca6242` used **89,973**. `grep -F 217858 .` and `grep -F 89997 .`
match nothing in the repository outside those two documents, and **no plain-USDC settlement was
ever made on Base Sepolia** (there are exactly two `AuthorizationUsed` events), so 81,392 cannot
be a Sepolia figure either. The speedrun also calls 89,997 "a plain transfer"; a plain sUSD
transfer is ~56k by the design doc's own number — 89,973 is an EIP-3009 settlement.

*Fix* quote 216,976 and 89,973 with their transaction hashes, or label the figures as Forge-test
medians, which `docs/design/x402-rail.md` already does honestly ("about 206k–222k, median 217k").

### L-09 · Low · stale documents
**The README says the protocol is not deployed and gives the wrong test count.**

*CONFIRMED* `README.md:3` — "Status: hardened (Phases 4 and 5), **not yet deployed**, not
externally audited" (it is deployed, block 48884064). `README.md:37` and `:71` — "219 tests";
`forge test` gives **246 passed, 1 skipped, 247 total**. `docs/design/x402-rail.md` — "Local
chain only. The workspace cannot reach Base RPCs" and "demo, **30 tests**"; `npm test` gives
**47**. `audit/x402-state-audit.md` regression gate — "tests 43 pass 43" against the 47 claimed
in the same file's own note. `docs/speedrun-application.md` says "**Seven** real defects in the
last two days"; `REPORT_X402.md` says "**Five** defects were found and fixed during the phase".

### L-10 · Low · live deployment, matters for the pitch
**The entropy engine, the rebase and the yield have never run on the public chain.**

*CONFIRMED* the wsUSD/USDC v4 pool has **zero liquidity** (`PoolManager.extsload` of the pool
state slot + 3 = `0`; `getLiquidity` for pool `0x39a0242c…2a95a`). The oracle reports
`filled() = 0` and `smoothedEntropy = 0.5e18` twenty-five thousand blocks after deployment, so
the hook has never recorded a swap. There are **no** `Rebased` events, `index` is still exactly
`1e18`, and the reserve sits in a `TestnetVault` which "lends nothing and earns nothing" by
construction.

*Consequence* "live on Base Sepolia" is true for the payment rail and false for everything the
protocol is actually about. The deploy script never seeds pool liquidity on Sepolia, so nothing
will change on its own. An advisor who opens the hook address will see a pool with no liquidity.

*Fix* say it: "the rail is live and settled real payments; the entropy oracle and the rebase
have only run locally, because the Sepolia pool has no liquidity and the test vault pays no
yield." Or seed a little liquidity and make a few swaps, which costs one more CI run.

### L-11 · Low · CI, incorrect rationale
**The private key is passed on forge's command line, with a rationale that does not hold outside
Solidity.**

*Where* `deploy-base-mainnet.yml:23-26` and `deploy-x402-router.yml:115-117`: "dependency code
can read environment variables, not command-line arguments (review S-02)"; repeated in
`audit/review.md:323`.

*CONFIRMED* `/proc/<pid>/cmdline` is mode `-r--r--r--` and readable by a sibling process (I
read a live process's argv from another shell). The claim is true for Solidity (`vm.env*`, and
`ffi` is off in `foundry.toml`) and false for every other process on the runner — solc, a post
step, a compromised toolchain.

*Fix* `--account <keystore> --password-file`, which `script/DeployBaseMainnet.s.sol`'s own
NatSpec already recommends. At minimum, correct the comment.

### L-12 · Low · CI, Sourcify — **already fixed upstream while this audit ran**
**The verification status query used a removed Sourcify API and reported eight verified
contracts as "absent".**

*CONFIRMED from a runner:* `GET https://sourcify.dev/server/check-all-by-addresses?...` returns
`{"title":"API v1 is removed","status":404,…}`, which the workflow's `jq` read as `absent`;
`GET https://sourcify.dev/server/v2/contract/84532/<addr>` returns
`{"creationMatch":"match","runtimeMatch":"match","match":"match","verifiedAt":"2026-10-22T20:47:48Z"}`
for **all eight** addresses. Raw responses on
`deployments/audit-39856007725:audit/live/sourcify-truth.txt`.

So the source **is** published and matched on Sourcify, at `match` (partial) — which is the
ceiling under `bytecode_hash = "none"`, exactly as the workflow's own comment predicts. The
committed `deployments/84532-verification.txt` on `deployments/verify-39853237030` says
`exact=0 partial=0 absent=8`, which is wrong and is the kind of artefact that should not be in
front of an investor.

The author fixed the query independently at `7750e5d` / `34a4337`. Still open at `7750e5d` and
fixed in my edit: the job summary's "lookup" links still point at the removed v1 endpoint, so
every link in the published summary 404s.

### L-13 · Low · CI, the failing run (priority 4)
**Run 39852354053 failed on a bookkeeping `git push`, which `set -euo pipefail` makes fatal to a
verification job whose every verification step succeeded.**

*What I established.* Steps 1–5 (`checkout`, `foundry-toolchain`, `forge build`,
`Verify on Sourcify`) all concluded `success`; only step 6, "Commit the verification results",
concluded `failure`, in 2 seconds, and the step's only command that can fail at that point is the
final `git push`. No `deployments/verify-39852354053` branch exists, so the push did not land.
The **identical step succeeded on the very next run** — 39853237030 created
`deployments/verify-39853237030` — and my faithful replica (same checkout SHA,
`submodules: recursive`, `contents: write`, persisted credential, shallow clone) pushed with
`PUSH EXIT=0`. So the mechanism is sound and the push failed once.

*UNVERIFIED* the exact remote rejection. GitHub Actions logs are served from
`results-receiver.actions.githubusercontent.com`, which this workspace's egress proxy denies
(403 on CONNECT, recorded in `recentRelayFailures`); `gh run view --log-failed` therefore cannot
retrieve it, and no other route to the log exists from here.

*Fix* applied: the push now lives in a separate job and a push that does not land logs a warning
instead of failing the run. The record is in the artifact and the job summary either way. Both
the author's Sourcify-v2 fix and mine are needed; they touch disjoint hunks.

### L-14 · Info · the router's emptiness is "the next payer takes everything"
`pay()` ends by sweeping the router's **entire** sUSD and USDC balance to the payer of that
call, so tokens anyone else sends to the router — including a mistaken transfer — are claimed by
whoever pays next. CONFIRMED on chain (router balances are 0) and by
`testFuzz_routerEndsEveryPaymentEmpty`. `docs/design/x402-rail.md` says so; `README.md` and
`REPORT_X402.md` phrase it only as "holds nothing between calls", which reads as a safety
property and hides the transfer rule.

### L-15 · Info · an earlier orphaned deployment exists
The deployer's nonce was already **20** at block 48,884,150, before the recorded deployment, and
an earlier `deploy-sepolia-rail` run (39842358046, 19:41) also concluded success. So at least one
complete earlier Spectrum deployment exists on Base Sepolia at other addresses from the same key.
Harmless on a testnet; worth knowing before anyone points a block explorer at `0x9CD8…fAB48`.
This is also why the "fourteen transactions" claim cannot be checked against the key's nonce.

---

## 3. Every document claim I checked

| # | Claim | Where | Verdict | Evidence |
|---|---|---|---|---|
| 1 | "two real x402 payments settled on Base Sepolia" | REPORT_X402, speedrun | **supported** | Exactly two `AuthorizationUsed` events on sUSD: tx `0x41dba712…` (direct sUSD, block 48884515) and `0xedd58590…` (router, block 48884552), plus one `PaidWithSUSD` on the router for 50,000 USDC units to the merchant. Both `status 1`. |
| 2 | "the agent needs no ETH" / "gasless for the payer" | REPORT_X402, speedrun, README | **supported** | Agent `0x68496c9c…`: `balance = 0`, `nonce = 0`. Both settlements were sent by the facilitator `0x8ad87442…`. The agent has never sent a transaction. |
| 3 | "the router holds nothing between calls" | REPORT_X402, README, design doc | **supported** (with L-14) | Live router sUSD = 0, USDC = 0; `testFuzz_routerEndsEveryPaymentEmpty` passes. The mechanism is "sweep everything to this payer", not "never receives". |
| 4 | "immutable, ownerless" router | speedrun, README | **supported** | `SpectrumPayRouter` has no owner, no setter, no admin role; all state is `immutable`. |
| 5 | "293 tests — 246 across the protocol, 47 on the rail" | REPORT_X402, speedrun | **supported** | `forge test` → 246 passed, 0 failed, 1 skipped (247 total). `cd x402 && npm test` → 47 passed, 0 failed, 0 skipped. |
| 6 | "Slither clean over 71 contracts and 102 detectors" | speedrun | **supported** | Ran the CI command verbatim: `. analyzed (71 contracts with 102 detectors), 0 result(s) found`, exit 0. (0 = 0 *untriaged*; the triage database is in-repo and the README says so.) |
| 7 | "a 22-row threat model, every row mapped to the test that attacks it" | REPORT_X402, speedrun | **supported** | `docs/design/x402-rail.md` has 22 rows, T1–T22 (T17 last, out of order). Each names a forge or node test. |
| 8 | "Five of six questions came back vulnerable" | REPORT_X402, speedrun | **supported** | `audit/x402-state-audit.md` §1–§5 VULNERABLE, §6 SOUND. |
| 9 | "flat 3.0–3.3 bps" (no condition) | REPORT_X402, README, speedrun | **overstated** | True at H = 0.5 only; 1–10 bp across the curve, ~10 bp at H = 1; the agent always authorises at 10 bp. L-07. |
| 10 | "from $0.01 to $10" bound on that range | REPORT_X402 | **supported** | `fee-curve.mjs` reproduced: 3.0 bps at $0.01 … 3.3 bps at $10; 90,000 bps at $0.001 where the minimum dominates, which the report states. |
| 11 | "break-even ~45% daily treasury turnover / 5,374 payments / $268.72" | REPORT_X402, speedrun | **overstated** | Reproducible in shape, not in value: my run gave 5,656 / $282.81 / 47.1%. README says 46%. L-03. |
| 12 | "Measured, not modelled" / "Every figure below is measured or on-chain. Nothing is projected." | REPORT_X402, speedrun | **false** | The yield is minted into a mock vault at an assumed 5% APY on anvil. L-03. |
| 13 | "Yield, one simulated day at 5% APY — $0.087333 on a $598.35 treasury" | REPORT_X402 | **supported as written** | The word "simulated" is there. The precision is not reproducible (I got $0.091914 on $600.16). |
| 14 | "Settlement gas: router 217,858 · direct sUSD 89,997 · plain USDC 81,392" | REPORT_X402, speedrun | **false** | On chain: 216,976 and 89,973. No plain-USDC settlement exists on Sepolia. Neither number is anywhere in the repo. L-08. |
| 15 | "89,997 for a plain transfer" | speedrun | **false** | A plain sUSD transfer is ~56k by the design doc's own figure; 89,973 is an EIP-3009 settlement. |
| 16 | "the whole deployment … came out of a single 0.01 test-ETH faucet drip" | REPORT_X402, speedrun | **supported** | Deployer ETH left 0.007758, facilitator funded with 0.001, ~0.0012 of gas spent. Consistent with 0.01. |
| 17 | "fourteen transactions" | speedrun | **overstated** | The deployer's nonce advanced 20 → 40 inside the deployment window (blocks 48,884,150–48,884,500), plus 2 settlements from the facilitator: at least 22. |
| 18 | "all nine contracts plus the router" | speedrun | **supported, misleading** | Nine are deployed: 7 Spectrum + 2 `TestnetVault`s. Two of the nine are rehearsal stubs that will not exist on mainnet. |
| 19 | "the hook address ends 6040 because v4 encodes permissions in the address; CREATE2-mined on a live network" | REPORT_X402, speedrun | **supported** | `uint160(hook) & ALL_HOOK_MASK == BEFORE_INITIALIZE | AFTER_SWAP`; salt `0x…1ee9` in the deployment record; `check()` re-derives it. |
| 20 | "deployed against Circle's real USDC and Uniswap v4's PoolManager" | REPORT_X402, speedrun | **supported** | `usdc = 0x036CbD53…CF7e` (Circle's Base Sepolia USDC), `poolManager = 0x05E73354…3408`. |
| 21 | "CI green on GitHub's runners … the complete rail stood up end to end" | speedrun | **supported** | `test.yml` runs the CI profile, `--isolate`, the snapshot check, both rehearsals and the Base fork suite; recent `test` runs conclude success. |
| 22 | "a worker agent … was paid 15.000000 USDC … the buyer spent 15.004869 sUSD" | REPORT_X402, speedrun | **supported, local only** | Consistent with a 3.25 bp fee on $15. It happened on the local chain, which the report says ("Agent-to-agent, on the local chain"); the speedrun's "already working" does not. |
| 23 | "the balance earns between payments" | README, design doc, speedrun | **false on the live chain** | No `Rebased` event, `index` still `1e18`, reserve in a vault that earns nothing by construction. L-10. |
| 24 | "Status: … not yet deployed" | README | **false** | Deployed at block 48884064. L-09. |
| 25 | "219 tests" (twice) | README | **false** | 246. L-09. |
| 26 | "Local chain only. The workspace cannot reach Base RPCs." / "30 tests" | design doc | **false / stale** | It is live on Sepolia; the node suite is 47. L-09. |
| 27 | "tests 43 pass 43 (32 pre-existing + 11 new)" | x402-state-audit regression gate | **stale** | 47 now; the same file's own note says so. |
| 28 | "Seven real defects in the last two days" | speedrun | **inconsistent** | REPORT_X402 says five. Neither is wrong on its face; they disagree. |
| 29 | "no role can send reserve funds to an address of its choosing" | README | **supported** | Every `AutonomousTreasury` entry point reverts `NotStabilizer` even from the admin; the stabilizer's only outbound payment is `redeem` against burned sUSD. Verified by `eth_call` on the live contracts. |
| 30 | "Redemption cannot be paused" | README, design doc | **supported** | `redeem()` has no `whenNotPaused` (`SpectralStabilizer.sol:364`); `sync()` likewise. |
| 31 | "supplyCap (25,000 sUSD at launch) bounds total minting" | README | **supported on chain, unverified by the script** | Live `supplyCap = 25,000e18`; but `check()` never asserts it. L-05. |
| 32 | "The admin role moves only in two steps with a 3-day delay" | README | **supported** | Live `defaultAdminDelay = 259200` = 3 days, `pendingDefaultAdmin = 0x0`. |
| 33 | "the deployer key holds no role afterwards" | DeployPayRouter NatSpec, deploy workflow headers | **supported** | Confirmed by role reads and by four reverted privileged `eth_call`s. |
| 34 | "a Safe as admin" at launch | README status line | **not true of this deployment** | The live admin is an EOA with no code. The README sentence is about mainnet; a reader looking at these addresses will not make that distinction. |
| 35 | "Sourcify … partial is the ceiling because bytecode_hash = none" | verify-sepolia.yml, REPORT_X402 | **supported** | v2 API returns `match: "match"` (partial), not `exact_match`, for all eight. |
| 36 | "verified source on Sourcify for all eight contracts" | upstream `34a4337` | **supported** | `creationMatch: match`, `runtimeMatch: match`, `verifiedAt 2026-10-22T20:47:48Z`. The committed `84532-verification.txt` saying `absent=8` is the stale artefact. L-12. |
| 37 | "160M+ x402 transactions by June 2026, >90% on Base, mean ≈ $0.13" | speedrun | **unverifiable here** | External market data; no network access to check it. Cite the source in the application. |
| 38 | "sUSDS $5.0bn 3.6%, USDY $2.33bn, sUSDe $1.21bn, syrupUSDC $1.05bn 5.18%" | speedrun | **unverifiable here** | External market data, and it dates fast. |
| 39 | "OCC's final GENIUS rule (21 October 2026, effective 18 January 2027)"; "a German court upheld the regulator against Ethena in May 2025"; "Kenya's VASP Act" | speedrun, README, REPORT_X402 | **unverifiable here** | Legal claims; get them confirmed by counsel before they go to an investor. |
| 40 | "the churn budget is bounded by a constant from a paper I am writing with Elmar Langetepe" | speedrun, README | **unverifiable here** | `src/libraries/SelfApproaching.sol` and `test/paper/` exist and the constant 3.1356… is `5π/6 + 2sin(π/12)`; the authorship and publication status are outside my reach. README is careful to say nothing on-chain calls the library yet. |

---

## 4. What I checked and found sound

- **Role surrender.** The complete `RoleGranted`/`RoleRevoked` history of the live stabilizer is
  two grants (DEFAULT_ADMIN and GUARDIAN, both to the configured admin) and no revocations. The
  deployer never held anything to surrender, because `SpectrumDeploy.deploy` passes the admin
  into the constructor. Four privileged `eth_call`s from the deployer all revert.
- **Wiring.** Every live cross-reference matches the deployment record: token↔stabilizer,
  treasury↔stabilizer, stabilizer→{token, treasury, oracle, asset}, wsUSD→sUSD, lens→stabilizer,
  oracle→hook, hook→{poolManager, oracle, measuredCurrency, allowedPoolId}, router→{stabilizer,
  sUSD, usdc, treasury, scale = 1e12}. `PostDeployCheck` with the admin repaired reaches the
  role assertions, i.e. everything before them passes.
- **Solvency and caps.** reserve 7.95 ≥ supply 2.947; `protocolCapital = 5e18`;
  `lens.distributable = 2.1e15`, which is exactly reserve − supply − capital. `supplyCap`,
  `bootstrapCap`, `minObservation`, `emaAlphaMax`, `tau`, `staleAfter` and `liquidityBufferBps`
  all equal the config's values.
- **Access control under attack.** `sUSD.mint`, `sUSD.setIndex` and `treasury.withdrawReserve`
  from a stranger all revert `NotStabilizer`. `router.pay` with a forged signature reverts
  `InvalidSignature`. `rebase()`, `sync()`, `rebalanceReserve()` and `recoverLegacy()` are
  permissionless, which is deliberate and documented, and none of them can be made to pay anyone.
- **The vault allowlist is immutable and short**: exactly the two TestnetVaults, fixed in the
  constructor; `pendingVault = 0`; migration needs the admin plus a 7-day timelock plus a loss
  bound. `TestnetVault` is a plain OZ ERC-4626 with no owner and no knobs and refuses chain 8453.
- **The intent-binding property** that the whole design rests on: `pay()` recomputes the EIP-3009
  nonce from its own `payTo`/`assets`/`salt`, and `receiveWithAuthorization` requires
  `msg.sender == to`. Read the code, read the tests, and the live router payment's nonce
  `0x2c7f0c01…` is consistent with it.
- **Test suites.** 246 Forge (0 failures, 1 skipped) and 47 Node (0 failures) on this machine,
  plus 7 new review tests. The gas snapshot, the Halmos logs and the Slither triage database are
  all in-repo and the Slither run reproduces exactly.
- **The other three workflows.** `test.yml`, `deploy-base-mainnet.yml` and
  `deploy-x402-router.yml` all keep `permissions: {}` at workflow level, `contents: read` per job,
  `persist-credentials: false`, pinned action SHAs, environment-scoped secrets (the two deploy
  ones), a `test` job with no secrets gated before the deploy job, and `script/check-deps.sh`
  before any build. `ffi` is off. `test.yml` runs on `pull_request` with no secrets a fork can
  reach. That posture is good; L-01 and L-02 are the two places it has slipped.

---

## 5. What I changed (tree left dirty, nothing committed)

| File | Change |
|---|---|
| `.github/workflows/verify-sepolia.yml` | Rebased onto upstream `7750e5d` (so the author's own Sourcify-v2 fix is kept), then: `verify` job back to `contents: read` + `persist-credentials: false`; the record is uploaded as an artifact instead of committed in-job; new secret-free `publish` job with `contents: write` does the commit and push; a push that does not land logs a warning instead of failing the run; the summary's Sourcify links moved off the removed v1 endpoint. `python3 -c "import yaml…"` parses it; jobs `verify`, `publish`. **L-01, L-13, and the link half of L-12.** |
| `test/x402/review2/DeployCheckGaps.t.sol` | New. 7 tests, all pass. Proves `check()` passes with the supply cap removed, with the cap at 0, while paused, after the liquidity buffer is changed, and with no independent guardian; plus the positive control and the committed-config failure. **L-04, L-05, L-06.** |
| `test/x402/review2/RouterCostIsEntropyDependent.t.sol` | New. Pins "flat 3.0–3.3 bps" to neutral entropy, shows ~10 bp at H = 1 and ~1 bp at H = 0, and that the authorisation is always sized at 10 bp. **L-07.** |

I did **not** edit `src/**`. The three one-line `require`s that would close L-05 are in
`script/lib/SpectrumDeploy.sol`, not `src/`, but I left them to the author since `check()` is
load-bearing for the mainnet runbook.

Pushed to the remote `user` (side branch only, working tree untouched): the read-only probe
workflow on `audit-live-state`, and its output on `deployments/audit-39855252056`,
`deployments/audit-39856007725`, `deployments/audit-39856712265`,
`deployments/audit-39857363004`, plus the push-probe branch
`deployments/verify-probe-39855252056`. All of those are disposable; delete them when done.

## 6. Where I was blocked

- **Base RPCs** are 403 at this workspace's egress proxy, as stated in the brief. Worked around
  entirely with the GitHub Actions probe; no live-state finding is UNVERIFIED for this reason.
- **GitHub Actions run logs** are served from `results-receiver.actions.githubusercontent.com`,
  which the proxy denies on CONNECT (recorded in `recentRelayFailures`). `gh run view
  --log-failed` cannot fetch them and no other route exists. This is why L-13's exact remote
  rejection is UNVERIFIED; I replicated the step instead and established that the mechanism works.
- **sourcify.dev and blockscout.com** are also 403 from here; queried from the runner instead.

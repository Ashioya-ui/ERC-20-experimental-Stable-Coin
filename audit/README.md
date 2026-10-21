# Audit package

Prepared for an external audit (Phase 4, D2). Nobody has been contacted yet.

Spectrum Agentic USD (sUSD) is a reserve-backed, redeemable, rebasing ERC-20 on Base. USDC goes
into a treasury that keeps a liquidity buffer idle and deposits the rest in one ERC-4626 vault;
the stabilizer mints and redeems sUSD against the measured reserve value; a Uniswap v4 hook feeds
an on-chain entropy signal H that moves fees, caps, the surplus buffer and the rebase step within
fixed bounds. Nothing is upgradeable. Section 1 of `audit/threat-model.md` has the one-paragraph
system description; the README has the mechanics.

## Frozen code

| | |
|---|---|
| Tag | `audit-freeze-1` |
| Commit | `git rev-parse audit-freeze-1` |
| Branch | `phase-4-hardening` |
| Toolchain | Foundry 1.5.1, solc 0.8.26, via-IR, optimizer 44,444,444 runs, EVM cancun, `bytecode_hash = none` |
| Dependencies | OpenZeppelin v5.4.0, Uniswap v4-core v4.0.0 + 12 commits, v4-periphery at an untagged commit (tests and scripts only), forge-std v1.17.0; `audit/dependencies.md` |

## Scope

Lines are physical lines; nSLOC counts lines with code, without comments or blank lines.

| File | Lines | nSLOC | Deployed |
|---|---:|---:|---|
| `src/SpectralStabilizer.sol` | 678 | 370 | yes |
| `src/SpectralToken.sol` | 365 | 254 | yes (sUSD) |
| `src/AutonomousTreasury.sol` | 297 | 163 | yes |
| `src/SpectralHook.sol` | 270 | 179 | yes (CREATE2, mined salt) |
| `src/SpectralEntropyOracle.sol` | 204 | 103 | yes |
| `src/SpectrumLens.sol` | 103 | 68 | yes (views only, no privileges) |
| `src/WrappedSUSD.sol` | 26 | 7 | yes (wsUSD, OpenZeppelin ERC-4626) |
| `src/libraries/SpectralMath.sol` | 203 | 107 | inlined |
| `src/libraries/SpectralPolicy.sol` | 115 | 62 | inlined |
| `src/libraries/SelfApproaching.sol` | 121 | 62 | no: a library nothing calls on-chain yet |
| `src/interfaces/ISpectralEntropyOracle.sol` | 19 | 6 | interface |
| **Total** | 2,401 | 1,381 | |

Also worth reading, as they decide what gets deployed and with which addresses:
`script/lib/SpectrumDeploy.sol` (the one deploy, check and record procedure),
`script/DeployBaseMainnet.s.sol`, `script/PostDeployCheck.s.sol`, `config/8453.json` and
`.github/workflows/deploy-base-mainnet.yml`.

Out of scope: `lib/`, `test/`, the rest of `script/`, `legacy/`, the ERC-4626 vaults themselves
(Aave waBasUSDC, Gauntlet USDC Prime) and USDC.

## Build and run

```bash
git checkout audit-freeze-1
git submodule update --init --recursive
forge build --sizes
forge test                        # 219 pass; 1 skips without BASE_RPC_URL (the fork suite)
FOUNDRY_PROFILE=ci forge test     # 10,000 fuzz runs; invariants 1,024 runs x 256 calls
forge test --isolate              # every call in its own transaction
script/rehearsal/run.sh           # the mainnet script on a Base-shaped anvil
make analyze formal coverage      # Slither, Halmos, coverage
BASE_RPC_URL=<rpc> make fork-test # the scenarios on a Base mainnet fork
```

The first build takes 5–7 minutes and about 4.5 GB of memory (v4-core's PoolManager under
via-IR).

## What to read

| Document | What it holds |
|---|---|
| `audit/threat-model.md` | Actors, trust, assets, every external entry point with its checks, threats, and every invariant mapped to the test that enforces it |
| `audit/findings.md` | Every Phase 4 finding with severity, status and the test that shows it, including the independent review's |
| `audit/review.md` | The independent review: a fresh reviewer given only the diff, the threat model and the list of known issues |
| `audit/formal.md` | What Halmos proved, over which inputs, and what it did not |
| `audit/slither.md` | Slither and Aderyn results and their triage |
| `audit/mutation.md`, `audit/coverage.md` | Mutation testing and coverage |
| `audit/oracle-manipulation.md` | Measured cost of steering H |
| `audit/parameters.md` | Launch parameters, protocol capital and the simulation behind them |
| `audit/gas.md` | Gas and sizes before and after Phase 4 |
| `audit/dependencies.md`, `audit/tools.md` | Dependency pins; every tool with its source and checksum |
| `RUNBOOK_MAINNET.md` | Deployment and operations, emergency procedures |
| `docs/paper-map.md` | Which results of the geometry paper the code uses, and the do-not list |

## Invariants

The protocol must keep these after every successful call (threat model §6 maps each to its
test):

1. `reserveValue() >= totalSupply()`; a realised vault loss is absorbed by `sync`, which runs
   first in every mint, redeem and rebase.
2. Redemption and loss absorption can never be paused or blocked by the policy (the churn step
   is proven never to revert).
3. Every holder can exit at once from liquid funds, up to the vault's own liquidity.
4. Share accounting is exact: balances never exceed supply; mints round down; burns and
   transfers round up.
5. Protocol capital is never distributed: rebases raise supply only up to
   min(reserve / (1 + buffer), reserve − capital).
6. Net minting per epoch stays under the daily cap; total minting stays under the supply cap.
7. No role can send reserve funds to an address of its choosing; a vault migration needs an
   allowlisted vault and 7 days' notice.
8. No free lunch: an attacker with flash loans and free control of H never ends above its start
   plus its pro-rata share of distributed surplus.

## Known and accepted

The README's "Known limitations" lists them: vault risk passes through to holders; loss
front-running beyond the cushion (A9); H is steerable within bounds; the admin and guardian
powers; dust; the gas of the first swap in a block; yield depends on protocol capital; the churn
budget is a design rule, not a theorem about the protocol.

## Where we would most like scrutiny

1. Valuation and rounding across the vault boundary: the measured credit in `mint`, payouts from
   idle funds and then the vault in `redeem`, batched deposits, and where the floor check sits.
2. Loss absorption: `sync` ordering, the index computation (`floor(reserve * 1e18 / shares)`),
   the total-loss edge case, and the interaction with protocol capital.
3. The treasury's migration, quarantine and legacy-dust rules.
4. The hook: the pool restriction, the price band at initialisation, gas starvation of the
   oracle call.
5. The token: EIP-2612, EIP-3009 and ERC-1271 signatures on a rebasing balance.
6. The deploy procedure's address predictions (deployer nonces and the mined CREATE2 salt) and
   constructor wiring.

# Spectrum on Base mainnet: runbook

Everything here is a command you can run. Variables used below:

```bash
export RPC=$BASE_RPC_URL
export S=$(jq -r .stabilizer deployments/8453.json)   # SpectralStabilizer
export T=$(jq -r .treasury   deployments/8453.json)   # AutonomousTreasury
export O=$(jq -r .oracle     deployments/8453.json)   # SpectralEntropyOracle
export K=$(jq -r .sUSD       deployments/8453.json)   # sUSD
export H=$(jq -r .hook       deployments/8453.json)   # SpectralHook
export W=$(jq -r .wsUSD      deployments/8453.json)   # wsUSD
export L=$(jq -r .lens       deployments/8453.json)   # SpectrumLens (read-only views)
```

Status: not externally audited. Phase 4 hardened the code and an independent review checked it
(`REPORT_PHASE4.md`, frozen at tag `audit-freeze-1`). Guarded launch: 25,000 sUSD supply cap and
1,250 USDC of protocol capital. Launch and describe sUSD as an **experimental token, not a
stablecoin**. Section 7 explains why.

---

## 0. One-time setup

1. **Admin Safe on Base.** Create it at app.safe.global; 2-of-3 or stricter is a sensible start.
   Put its address in `config/8453.json` → `roles.admin`. The deploy script refuses a zero or EOA
   admin. The admin role transfers in two steps with a 3-day delay
   (`beginDefaultAdminTransfer`, then `acceptDefaultAdminTransfer` from the new Safe), and it
   cannot be renounced in one call.
2. **Guardian.** A second, faster Safe (1-of-2) or a monitored hardware-wallet address. Put it in
   `roles.guardian`. The guardian can pause minting and rebasing, pull funds out of the vault,
   and cancel a pending vault migration. Nothing else.
3. **Deployer.** A fresh Ledger account with about 0.003 ETH and **1,252 USDC** on Base: 2 USDC
   seed wsUSD's dead shares (`params.seedUSDC`) and 1,250 USDC become protocol capital
   (`params.seedCapitalUSDC`). Protocol capital is never paid out: it covers the largest surplus
   buffer (5% of the 25,000 cap), so yield is distributable from day one, and it absorbs the first
   losses (`audit/parameters.md`). The deployer ends with **no roles**. Use it for nothing else
   while the deployment runs, because the hook salt is mined for its current nonce.
4. **Keys and services.** `cp .env.example .env`, then fill in `BASE_RPC_URL` (provider endpoint),
   `ETHERSCAN_API_KEY` (an Etherscan API V2 key, which covers Basescan) and `DEPLOYER`.
5. **Toolchain.** Foundry 1.5.x, then `git submodule update --init --recursive`.

## 1. Pre-flight (no transactions)

| Command | What it proves |
|---|---|
| `make test` | Unit, fuzz, invariant, attacker and paper-oracle tests, plus the mainnet scenarios on a Base-shaped local chain (counts in the README) |
| `make test-isolate` | The same suite with every call in its own transaction, as on-chain |
| `make rehearsal` | The **exact** mainnet script deployed on anvil, with Circle FiatToken v2.2 as USDC and a real v4 PoolManager. Then the post-deploy check, swaps, an x402 payment, keeper rebase, emergency exit and 7-day migration. Output goes to `rehearsal/latest.log` |
| `make fork-test` | The same scenarios on a fork of Base mainnet: real USDC, PoolManager, Aave waBasUSDC and Gauntlet USDC Prime |
| `make preflight` | The whole deployment simulated against live Base state from your deployer address. It prints live vault data |

Re-check the vault on deploy day (the report's advice): `make preflight` prints `totalAssets`,
the share price, `maxDeposit` and a 1,000 USDC round trip. Also run:

```bash
V=0xC768c589647798a6EE01A91FdE98EF2ed046DBD6   # Aave v3 waBasUSDC (StataTokenV2)
cast call $V "totalAssets()(uint256)" --rpc-url $RPC
cast call $V "maxDeposit(address)(uint256)" $DEPLOYER --rpc-url $RPC
cast call $V "convertToAssets(uint256)(uint256)" 1000000 --rpc-url $RPC
```

## 1A. Dress rehearsal on Base Sepolia (do this first)

The same script and checks, on Base Sepolia, with Circle's test USDC. Sepolia has no USDC
lending vault worth testing against, so `config/84532.json` sets `deployTestVaults`: the script
first deploys two plain OpenZeppelin ERC-4626 vaults labelled "Spectrum TEST vault (no yield,
testnet)". They pay no yield, and both they and the script refuse to run on chain 8453.

1. An admin address on Base Sepolia. `config/84532.json` sets `allowEoaAdmin`, so a plain
   wallet you control works; use a Safe (app.safe.global supports Base Sepolia) if you want to
   rehearse the Safe flows too. Mainnet always requires a Safe.
2. A fresh deployer with test ETH (any Base Sepolia faucet) and **7 test USDC** (faucet.circle.com:
   2 for the seed, 5 of protocol capital).
3. Either `make deploy-base-sepolia` (needs `BASE_SEPOLIA_RPC_URL` in `.env`), or the workflow
   below with `network=base-sepolia`: first `mode=dry-run`, then `mode=broadcast`.
4. Then `make post-deploy-check-sepolia`, mint and redeem a few test USDC through the stabilizer,
   and keep `deployments/84532.json`.

You will confirm 16 transactions: the two test vaults plus the 14 of the mainnet deployment.

## 2. Deploy

Use one of two routes. The steps are the same either way.

**A. From your machine (Ledger):**

```bash
make deploy-base-mainnet      # type 'deploy'; confirm each transaction on the Ledger
```

**B. From GitHub Actions** (`.github/workflows/deploy-base-mainnet.yml`):
1. Settings → Environments: create `base-sepolia` and `base-mainnet`. On each, add yourself as
   required reviewer and limit deployment branches to the branch you release from.
2. In **each** environment (not as repository secrets, which every workflow on every branch can
   read), add the secrets `RPC_URL`, `ETHERSCAN_API_KEY` and `DEPLOYER_PRIVATE_KEY`, and the
   variable `DEPLOYER` holding that key's address. Use a different fresh key per network, funded
   just before the run (0.003 ETH and 1,252 USDC on Base; test ETH and 7 test USDC on Sepolia);
   it ends with no roles. Only the broadcast step receives the key: it checks the key against
   `DEPLOYER`, removes it from the environment and passes it to forge as an argument, so no
   dependency code can read it. A Ledger (route A) keeps the key out of GitHub altogether.
3. Go to Actions → deploy-base-mainnet → Run workflow, then, for `network=base-sepolia` first
   and `network=base` after it:
   - first with `mode=dry-run` and `admin=<your Safe on that network>`;
   - then with `mode=broadcast` and `confirm=DEPLOY`.

The workflow:
- runs the dependency-pin check and the tests in a job that holds no secrets, first;
- rejects an RPC for the wrong chain, and an admin that is not a deployed contract (a plain
  wallet is accepted on Sepolia, where `config/84532.json` allows it);
- runs every test, and the Base fork scenarios when the network is `base`;
- simulates the deployment against live Base state;
- broadcasts, verifies on Basescan, runs the post-deploy check;
- uploads `deployments/<chain id>.json` as an artifact.

You will confirm 14 transactions: treasury, token, oracle, stabilizer, wsUSD, lens, the hook
(through the CREATE2 proxy), the seed (USDC approve, mint, sUSD approve, wsUSD deposit to
`0xdead`), the pool's start (`hook.initializePool()`, which reads wsUSD's redemption value
on-chain and does nothing if someone started the pool already) and the protocol capital (USDC
approve, `contributeCapital`). There are no wiring transactions: each contract receives the
addresses it trusts in its constructor, predicted from the deployer's nonce and the hook's mined
salt. The script aborts if a prediction is wrong, and the stabilizer's constructor refuses a
token or treasury that names another stabilizer. Send nothing else from the deployer key while
the script runs.

**If a broadcast stops part-way.** Look at why before you run anything again:
- It stopped on a timeout or an RPC error, and the deployer's nonce is exactly where the
  broadcast left it (`cast nonce $DEPLOYER` equals the last sent nonce + 1): re-run the same
  command with `--resume`. It sends only the remaining transactions.
- It stopped on a nonce error, or anything else was sent from the deployer key in between:
  discard every address that key produced and deploy again from a new key. Do not resume. The
  constructors' cross-checks catch honest mismatches, not someone holding the key who placed
  look-alike contracts at the predicted addresses.

When it finishes:
- `deployments/8453.json` holds the addresses, the hook salt and the constructor arguments.
  Commit it.
- Contracts are verified on Basescan through `--verify`. If any failed, run
  `make verify-base-mainnet`. That script passes the constructor arguments explicitly, which the
  hook needs because it was created by the CREATE2 proxy. A second explorer:
  `make verify-blockscout`.
- `make post-deploy-check` runs automatically. Re-run it any time. It checks every link, every
  role, the hook flags, that the hook address equals CREATE2(salt, init code), that the pool is
  initialised (and warns if its price is more than 50 bp from par), neutral entropy (0.5e18)
  during warm-up, the parameters, and reserve ≥ supply.

## 3. Day 0

1. **Seed liquidity.** Open `https://app.uniswap.org/positions/create/v4?hook=$H`, then:
   - pick wsUSD/USDC, fee 0.01% (100 pips), tick spacing 1, a tight range around 1.00;
   - sign from the deployer or the Safe (WalletConnect).

   An empty pool's price can be moved by anyone for free, so check it first. The post-deploy
   check prints a warning if it is more than 50 bp from par. Your range and the interface's
   slippage limits protect the position, but if the price is off, a 1-wei swap back to par
   (free while the pool is empty) makes the interface's numbers sensible again.

   To get wsUSD: mint sUSD (`mint(uint256,address,uint256)` on `$S`), then call `deposit` on `$W`.
   Never put raw sUSD in any pool.
2. **Ask Uniswap to allowlist the hook.** Swaps are routed to hooked pools only after that; until
   then, assume about zero volume. Our hook is the easiest kind to approve: `beforeInitialize` +
   `afterSwap`, a static fee, and no return deltas. See developers.uniswap.org/docs/protocols/v4/concepts/hook-routing.
   Until then the oracle mostly sees no swaps, and H stays neutral at 0.5.
3. **Keeper.** The keeper needs no role, just a hot key holding a little ETH:
   ```cron
   5 * * * *  cast send $S "rebase()"           --rpc-url $RPC --account spectrum-keeper --password-file ~/.kp
   15 3 * * * cast send $S "rebalanceReserve()" --rpc-url $RPC --account spectrum-keeper --password-file ~/.kp
   ```
   `cast send` estimates gas first, so a `rebase()` with nothing to distribute costs nothing.
4. **Monitoring.** Run every few minutes and alert on the conditions in the table:
   ```bash
   cast call $L "reserveRatio()(uint256)"        --rpc-url $RPC   # alert if < 1.0e18 (L = lens)
   cast call $T "liquidAssets()(uint256)"        --rpc-url $RPC   # USDC payable now
   cast call $T "idleAssets()(uint256)"          --rpc-url $RPC
   cast call $L "supplyCapRemaining()(uint256)"  --rpc-url $RPC
   cast call $S "pendingVault()(address)"        --rpc-url $RPC   # alert if != 0x0
   cast call $S "protocolCapital()(uint256)"     --rpc-url $RPC   # first-loss capital, sUSD wei
   cast call $L "distributable()(uint256)"       --rpc-url $RPC   # what the next rebases can pay
   cast call $O "isStale()(bool)"                --rpc-url $RPC
   cast call $O "smoothedEntropy()(uint256)"     --rpc-url $RPC   # alert outside [0.1e18, 0.9e18] for an hour
   cast logs --rpc-url $RPC --address $S "VaultProposed(address,uint256)"
   cast logs --rpc-url $RPC --address $S "LossAbsorbed(uint256,uint256,uint256,uint256)"
   cast logs --rpc-url $RPC --address $S "CapitalContributed(address,uint256,uint256)"
   cast logs --rpc-url $RPC --address $H "OracleRecordFailed(bytes)"
   ```

   | Signal | Meaning | Action |
   |---|---|---|
   | `VaultProposed` you did not expect | Admin key misuse | Guardian cancels (E6); rotate admin signers |
   | `LossAbsorbed` | Vault loss recognised; balances lowered pro rata | E4 |
   | `liquidAssets` < expected redemptions | Vault utilisation high | E3 |
   | `reserveRatio` < 1e18 | Unsynced loss | `cast send $S "sync()"` (anyone) |
   | `OracleRecordFailed` | Oracle bug (swaps still work) | Investigate; H falls back to neutral when stale |

5. **x402 payments** (the report's recommendation): take payments in **USDC** through the Coinbase
   CDP facilitator. It settles EIP-3009 on Base for free; the x402.org facilitator is testnet only.
   Convert to sUSD server-side if you want to. To accept **sUSD** directly, self-host a
   facilitator (Phase 2). `payTo` must be an operator address, **never** the treasury or the
   stabilizer: tokens sent there are stuck.

## 4. Guarded launch: raising limits

- **Supply cap**, initially 25,000 sUSD. Raise it from the Safe:
  `script/safe-tx.sh set-supply-cap 100000`, then upload the generated JSON in the Safe app
  (Apps → Transaction Builder) and execute.
- **Protocol capital moves with the cap.** Keep it at 5% of the cap or more, so the largest
  buffer stays covered and small losses never lower a balance. Before raising the cap to
  100,000, add 3,750 USDC (5,000 in total): approve the stabilizer, then
  `cast send $S "contributeCapital(uint256)" <assets in USDC units>` from the Safe or any
  account. Capital can never be withdrawn or distributed; holders earn the yield on it.
- **Daily expansion cap**: 10,000 sUSD per day, or 2–20% of supply once that is larger. It is
  immutable; redeploy if you need a different bootstrap value.
- **Someone may fill the cap.** Anyone with about 25,000 USDC can mint up to the cap and hold
  it, paying only the mint fee (the daily cap spreads that over a few days). Nobody loses
  money, but new users cannot mint until you raise the cap.
- Suggested gates before each raise:
  - 2+ weeks without incidents;
  - `reserveRatio` ≥ 1;
  - vault liquidity at least 10× the cap increase;
  - keeper and monitoring running;
  - external audit before going past 100k.

## 5. Emergency procedures

Admin actions go through the Safe. Generate the batch with `script/safe-tx.sh <action>` and drop
it into Transaction Builder. If the guardian is a hardware-wallet address instead of a Safe, it
can send directly: `cast send $S "<fn>" --ledger --rpc-url $RPC`.

- **E0. Stop new minting and rebases.** `script/safe-tx.sh pause` (guardian); later `unpause`.
  Redemption and `sync()` keep working. No role can stop them.
- **E1. Vault incident** (exploit, pause, governance change). `script/safe-tx.sh emergency-exit`
  (guardian):
  - the buffer goes to 100%, new mints stay idle, and the treasury pulls out everything the vault
    pays now;
  - repeat as liquidity returns;
  - check: `cast call $T "idleAssets()(uint256)"` and `cast call <vault> "balanceOf(address)(uint256)" $T`.
- **E2. Move to another vault.** Run `script/safe-tx.sh propose-vault 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61`
  (Gauntlet USDC Prime, the report's fallback). Only vaults on the allowlist fixed at deployment
  can be proposed: Aave waBasUSDC and Gauntlet USDC Prime. `cast call $S "allowedVaults()(address[])"`
  shows them, and nothing can add to the list afterwards, so moving to a third venue needs a new
  deployment. Announce the migration; holders have **7 days** to redeem if they disagree. That
  protection assumes the old vault is liquid: redemptions beyond the idle buffer need it. Since
  Phase 5 (P5-03) the execution carries the largest fall of the reserve it accepts, in USDC wei,
  and reverts beyond it: the default of 10 covers rounding, so a migration out of a vault that
  cannot pay the whole position is refused, nothing moves, and the proposal stays executable
  until `cast call <old vault> "maxWithdraw(address)(uint256)" $T` covers the position. Pass a
  larger bound only for a vault that will not recover, as an emergency you have announced: the
  shares it cannot pay are then quarantined and every balance is cut by their share at once.
  Then:
  1. `script/safe-tx.sh execute-migration` (or `execute-migration <max loss in USDC wei>`)
  2. `script/safe-tx.sh set-buffer 1500`
  3. `cast send $S "rebalanceReserve()"`

  Shares the old vault cannot pay out are quarantined:
  - they no longer count in the reserve, and the loss is absorbed pro rata;
  - `cast send $T "recoverLegacy()"` (anyone) brings them back as surplus later.

  Vault checklist, from the report:
  - plain ERC-4626 with working `max*` functions (Morpho Vault v2 returns 0, so reject it);
  - loss-realising share price (MetaMorpho v1.1 hides bad debt, so avoid it);
  - no entry or exit fees;
  - share price near 1 asset per share;
  - deep withdrawable liquidity;
  - curator powers behind timelocks;
  - audits.

  Rejected by the report: Steakhouse High Yield (83% in one USDe market), Steakhouse Prime
  (legacy), Noon sUSN (cooldown exits), Spark sUSDC (PSM-dependent).
- **E3. Liquidity crunch.** Redemptions fail with `InsufficientLiquidity(available)`, which shows
  what can be paid now. Raise the buffer (`script/safe-tx.sh set-buffer 3000`, then
  `rebalanceReserve()` as liquidity frees up) and tell holders to redeem at most `liquidAssets`.
  `redeem(type(uint256).max, ...)` redeems a whole balance safely.
- **E4. Realised vault loss.** `cast send $S "sync()"` (anyone). Every action also syncs first,
  so nobody exits at the old price. Communicate the index change: `cast call $K "index()(uint256)"`.
- **E5. Entropy oddities.** H only moves fees, caps, buffer and rebase step within fixed bounds,
  and never touches backing. A stale oracle reads as neutral, and H can never lower the surplus
  buffer below 2.75%. Steering it takes about a day of continuous, visible trading
  (`audit/oracle-manipulation.md`). Alert if the smoothed H stays below 0.1 or above 0.9 for
  more than an hour; no on-chain action is needed.
- **E6. Cancel a pending migration.** `script/safe-tx.sh cancel-migration` (guardian).
- **E7. Key compromise.**
  - Guardian: the admin runs `script/safe-tx.sh revoke-guardian <addr>`.
  - Admin Safe: the worst it can do is propose a malicious vault, which is visible on-chain for
    7 days. Watch `VaultProposed`; the guardian cancels it, and holders can redeem meanwhile.

## 6. Realistic numbers (report, 15 Oct 2026)

| Item | Figure |
|---|---|
| Aave Base USDC supply APY | 3.74% 30-day average, 3.31% 6-month, 4.16% spot |
| Reserve yield after the 15% idle buffer | about 2.8–3.6% gross |
| Surplus kept before the first rebase | 2.75% of supply at neutral H (5% at H = 1), covered by protocol capital |
| Time to the first distribution | **day one** with 1,250 USDC of capital; about 10 months without it |
| LP fee income on wsUSD/USDC | about 0% until the hook is routed (report: 0–0.7%) |
| Gemini's "3.98–9.05% APY" | Not supported: 9% needs Noon, which is not an instantly redeemable USDC vault |
| Gemini's "8 bp dynamic fee, 5.8% LP APR" | Not applicable: our fee is static, stable pools on Base charge 0.05–0.2 bp, and the volume assumes routing |

The surplus buffer and rebase step are contract constants. Protocol capital is what lets yield
flow from day one without lowering the buffer; `audit/parameters.md` has the simulation (12-month
returns with and without capital, and after losses).

## 7. Legal (read before opening to the public)

**Update, 22 October 2026: the US rules are final.** On 21 October 2026 the OCC issued its final
rule implementing the GENIUS Act. The framework takes effect on **18 January 2027**. From then:
- only a permitted payment stablecoin issuer (a bank subsidiary, an OCC-approved nonbank, or a
  state-qualified issuer) may issue a payment stablecoin in the United States;
- reserves must be at least 1:1, in cash, bank deposits, short-dated Treasuries, Treasury
  repos or government money market funds;
- redemptions generally within two business days;
- no interest or yield to holders "solely in connection with the holding, use, or retention"
  of the coin. The OCC dropped a proposed presumption about payments through affiliates and
  third parties: it will judge those case by case and act against evasion.
Knowing violations of the Act carry fines of up to $1 million per violation and up to five years
in prison. In Kenya, stablecoin issuance is a licensed activity under the VASP Regulations 2026,
with KES 300 million of paid-up capital; existing operators have until 4 November 2026 to
comply, and the draft rules put reserves in Kenyan bank accounts and short government
securities. sUSD as designed fails each of these tests: it pays holders yield by rebase, its
reserve is USDC in a lending vault, and nobody behind it is licensed.

The research report found:
- The US GENIUS Act forbids a permitted payment-stablecoin issuer from paying yield, so a
  rebasing, yield-passing sUSD cannot be a compliant US payment stablecoin.
- Kenya's VASP Act 2025 requires a Central Bank of Kenya licence (KES 300M paid-up capital) to
  issue a stablecoin, and Aave or Morpho vaults are not eligible reserve assets.

What follows:
- launch as an experimental DeFi token and do not market it as a stablecoin;
- geo-restrict US persons;
- avoid any government imagery;
- take counsel in Kenya and the US before inviting outside users;
- until then, use Base Sepolia (`DEPLOY_AND_TEST.md`, level 2): it is free, and its tokens have no
  value.

## 8. Addresses (Base, chain 8453; verified 2026-10-15)

| Contract | Address |
|---|---|
| Uniswap v4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Uniswap v4 PositionManager | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` |
| Uniswap v4 StateView | `0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDC (Circle FiatToken v2.2) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Reserve vault: Aave v3 waBasUSDC (StataTokenV2) | `0xC768c589647798a6EE01A91FdE98EF2ed046DBD6` |
| Fallback vault: Gauntlet USDC Prime (MetaMorpho v1.0) | `0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61` |
| CREATE2 deployer (Arachnid) | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |

Sources: developers.uniswap.org/docs/protocols/v4/deployments; developers.circle.com/stablecoins/usdc-contract-addresses;
basescan.org (each address); aavescan.com/base-v3/usdc; app.morpho.org (Gauntlet USDC Prime);
support.uniswap.org article "How do custom hooks work in the Labs interface?"; docs.x402.org/faq;
CRS IF13174 (GENIUS Act §4(a)(11)); Kenya VASP Regulations 2026 (LN 134 of 2026); OCC final rule of
21 October 2026 (cointelegraph.com/news/occ-finalizes-genius-act-rules-stablecoin-issuers-custody,
bpi.com/occ-genius-act-rule-leaves-room-for-ambiguity-on-yield); mofo.com GENIUS Act summary
(penalties); spencer-west.com on the Kenya VASP Regulations 2026.

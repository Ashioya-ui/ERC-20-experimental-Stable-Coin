# Deploy and test Spectrum yourself

Three levels, each a step closer to mainnet. Do them in order. Nothing here touches real money
until level 3.

| Level | Where | What you need | Time |
|---|---|---|---|
| 1. Run every test | your computer, or GitHub | Foundry, or a GitHub repository | 15 min |
| 2. Deploy to Base Sepolia | GitHub Actions, or your computer | a fresh wallet with test ETH and 7 test USDC (free faucets) | 30 min |
| 3. Mainnet guarded launch | your computer with a Ledger | a Safe, 1,252 USDC and 0.003 ETH, legal advice first | 1 h |

---

## Level 1: run every test

### On your computer (Linux, macOS, or Windows with WSL; 8 GB of memory)

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup   # built and tested with Foundry 1.5.1
cd spectrum                     # this folder: the dependencies are already in lib/
forge test                      # first build 5–10 minutes; then 231 tests pass (1 skips: it needs a Base RPC)
script/rehearsal/run.sh         # the real mainnet script on a local copy of Base; ends REHEARSAL PASSED
script/rehearsal/scale.sh       # the same, then run at $300m (REPORT_SCALE.md); ends SCALE REHEARSAL PASSED
```

If `forge test` says a library is missing, run `git submodule update --init --recursive` once.

### On GitHub (works from a phone)

1. Push this folder to a GitHub repository (or open a new Claude Code session on the repository,
   attach the zip and ask it to push to `main`). Route A of level 2 uses environment secrets,
   which GitHub offers on public repositories on every plan, and on private ones only with
   GitHub Pro or above. The workflows must be on the default branch to show **Run workflow**.
2. Open the **Actions** tab. The `test` workflow runs by itself on every push: the dependency
   pins, the full suite with 10,000 fuzz runs, the suite in isolated mode, the gas check, the
   local mainnet rehearsal and Slither. All green means level 1 is done. (The Base fork job
   also runs if you add a `BASE_RPC_URL` repository secret; it is skipped otherwise.)

---

## Level 2: deploy to Base Sepolia (testnet)

**Prepare a throwaway wallet** (never your main wallet):
1. Create a new account in any wallet app and copy its address and private key.
2. Get Base Sepolia test ETH from a faucet (search "Base Sepolia faucet"; Coinbase and Alchemy
   run free ones). 0.01 ETH is plenty.
3. Get **7 test USDC** from faucet.circle.com (choose Base Sepolia).
4. Get a free Etherscan API key at etherscan.io/apis (one key covers Basescan).

### Route A: GitHub Actions (no install)

1. Repository **Settings → Environments → New environment** `base-sepolia`. In it add:
   - secrets `RPC_URL` = `https://sepolia.base.org`, `ETHERSCAN_API_KEY`, and
     `DEPLOYER_PRIVATE_KEY` = the throwaway wallet's key;
   - variable `DEPLOYER` = the throwaway wallet's address.
2. **Actions → deploy-base-mainnet → Run workflow**:
   - `network` = `base-sepolia`, `admin` = an address you control other than the deployer
     (any wallet works on Sepolia), `mode` = `dry-run`. Wait for green.
   - Run again with `mode` = `broadcast` and `confirm` = `DEPLOY`.
3. The run's summary shows `deployments/84532.json`: every contract address, all verified on
   sepolia.basescan.org.

### Route B: your computer

```bash
cp .env.example .env    # set BASE_SEPOLIA_RPC_URL=https://sepolia.base.org, ETHERSCAN_API_KEY,
                        # DEPLOYER=<throwaway address>, SIGNER=--account spectrum-deployer
cast wallet import spectrum-deployer --interactive    # paste the throwaway key once
# put an address you control (not the deployer) in config/84532.json -> roles.admin
make deploy-base-sepolia
```

### Test it on Sepolia

Open the stabilizer address from `deployments/84532.json` on sepolia.basescan.org, tab
**Contract → Write contract**, and connect the wallet that holds test USDC:

1. On the USDC contract (`0x036CbD53842c5426634e7929541eC2318f3dCF7e`), `approve` the
   stabilizer for `1000000` (1 USDC; USDC has 6 decimals).
2. On the stabilizer, `mint(assets = 1000000, to = <your address>, minOut = 0)`. You receive
   about 0.9993 sUSD (the 7 bp mint fee at neutral H).
3. `redeem(amount = 500000000000000000, to = <your address>, minOut = 0)` returns about 0.5 USDC.
4. On the lens (also in the JSON), **Read contract → reserveRatio**: 1e18 or more means fully
   backed.

Or with cast:

```bash
S=$(jq -r .stabilizer deployments/84532.json); U=0x036CbD53842c5426634e7929541eC2318f3dCF7e
cast send $U "approve(address,uint256)" $S 1000000 --rpc-url $BASE_SEPOLIA_RPC_URL --account spectrum-deployer
cast send $S "mint(uint256,address,uint256)" 1000000 $DEPLOYER 0 --rpc-url $BASE_SEPOLIA_RPC_URL --account spectrum-deployer
make post-deploy-check-sepolia
```

---

## Level 3: mainnet (guarded launch)

Only after levels 1 and 2 are green, and after you have taken legal advice. The US rules became
final on 21 October 2026 (effective 18 January 2027), and Kenya licenses stablecoin issuers:
`RUNBOOK_MAINNET.md` §7 explains why sUSD, as designed, is not a compliant payment stablecoin in
either. Follow `RUNBOOK_MAINNET.md` from §0. In short:
a Safe as admin in `config/8453.json`, a fresh Ledger account with 1,252 USDC and 0.003 ETH,
then `make preflight` and `make deploy-base-mainnet`. Launch it as an experimental token with
the 25,000 sUSD cap, and get an external audit (`audit/README.md` is the package) before
raising the cap.

## If something fails

Copy the exact error (the last 20 lines) and the command you ran into the chat. The common ones:

| Message | Cause | Fix |
|---|---|---|
| `admin ... has no code` | mainnet needs a Safe as admin | create the Safe on Base first |
| `the RPC is not chain 84532` | wrong RPC URL | `https://sepolia.base.org` for Sepolia |
| `DEPLOYER_PRIVATE_KEY does not match the DEPLOYER variable` | key and address differ | copy both from the same wallet |
| `ERC20: transfer amount exceeds balance` or a revert in `mint` | the deployer lacks test USDC | 7 test USDC from faucet.circle.com |
| `insufficient funds for gas` | no test ETH | a Base Sepolia faucet |
| a revert with `nonce` in it | something else used the deployer key | start over with a new key (runbook §2) |

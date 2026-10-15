# Spectrum Protocol: corrected 3-phase engineering prompts

Revision: 2026-10-15. This replaces the "Complete 3-Phase Production Engineering Prompts"
document.

Run the phases in order. Each prompt is self-contained and model-agnostic: paste it into any
capable coding agent. **Phase 1 is already implemented in this repository.** Its prompt below
is the spec of record and matches the code, so an auditor, or an agent regenerating the code,
works from the same text.

**Status, 2026-10-16.**
- **Done:** Phase 1, and the deployment half of Phase 3, for Base mainnet as a guarded launch
  (`RUNBOOK_MAINNET.md`, `make deploy-base-mainnet`). It follows the October 2026 research
  report:
  - reserve in Aave waBasUSDC behind a 15% idle USDC buffer, with Gauntlet USDC Prime as the
    fallback;
  - a static 1 bp pool fee;
  - x402 payments taken in USDC through the CDP facilitator;
  - a 25,000 sUSD supply cap;
  - a Safe as admin.
- **Still open:** Phase 2 (self-hosted sUSD facilitator) and the Phase 3 SDK.

Facts that change over time are marked *(verified 2026-10-15)*: addresses, SDK versions, header
names. Re-verify them before any deployment. Sources are listed at the end.

---

## What changed and why

1. **Model names removed.** "Claude 3.5 Sonnet / Gemini 2.0 Pro" is outdated, and the prompts do
   not depend on a particular model.
2. **Broken structure repaired.** In the original, the Phase 2 prompt stopped mid-sentence ("Node.js/")
   and was followed by a second copy of Phase 1.
3. **C_diam is described as conjectural.** 2 + π/3 ≈ 3.0472 is the *conjectured* sharp
   length-over-diameter ratio of self-approaching plane curves; the proven bounds are
   3.0472 ≤ C_diam ≤ 3.1356. The original called it "optimal" and built the monetary engine
   around it. A one-dimensional quantity such as supply cannot be "self-approaching" in any
   useful sense (a self-approaching path in 1-D is just monotone), so no stability property
   follows. The new prompts use it only as the named constant in a precisely defined churn
   budget, and say so.
4. **Entropy semantics fixed.** For a Walsh-Hadamard power spectrum, a homogeneous flow puts all
   energy in sequency 0, so **H = 0**. A single spike has a flat spectrum, so **H = 1**. The
   original had this backwards ("H → 1 = organic, H → 0 = whale").
5. **"Stablecoin" versus "elastic supply" resolved.** A 100% reserve floor, an elastic
   algorithmic supply and "compute-backed" cannot all hold at once. The legacy repository's own
   manual says "SPCM is NOT a stablecoin". The new design is reserve-backed and redeemable 1:1:
   - rebases only distribute realised surplus or absorb realised losses;
   - nothing is "compute-backed";
   - the regulatory question is flagged, not hidden.
6. **Manipulation of an 8-swap buffer.** Eight raw swaps can be produced in one transaction. The
   oracle now aggregates per block, filters dust, smooths with an EMA, falls back to neutral
   during warm-up and when stale, accepts writes only from a hook set once, and the hook serves
   exactly one pool. Even so, H stays cheap to game, so it may only move bounded policy settings.
7. **Numerics specified.**
   - Normalise by the window maximum before the transform: squaring raw 128-bit deltas would
     overflow int256.
   - Use `ln m = 2·atanh((m−1)/(m+1))` after range reduction: a plain Taylor series of
     ln(1+x) converges far too slowly for small probabilities.
   - State precision targets and test them.
8. **"Vanishing cycloidal micro-rebases" replaced** by concrete, testable rules: at most one rebase
   per hour, at most 1 bp of supply each, only from surplus above a buffer, and a step smaller
   than the minimum round-trip fee, so a mint → rebase → redeem sandwich loses money.
9. **ERC-4626 described as an adapter, with honest wording.** No vault "guarantees" a reserve
   floor. The code enforces `reserve ≥ supply` after every action and absorbs external vault
   losses with a negative rebase. Vault risk is stated, not hidden.
10. **Uniswap v4 updated to the current API.**
    - `BaseHook` left v4-periphery (it now lives in OpenZeppelin uniswap-hooks), so the hook
      implements `IHooks` directly.
    - `SwapParams` and `ModifyLiquidityParams` live in `types/PoolOperation.sol`;
      `initialize` takes no hookData.
    - Hook flags are mined into the address.
    - **Rebasing tokens must not sit in a PoolManager:** anyone could capture its rebases between
      `sync` and `settle`, and negative rebases make it insolvent. Pools therefore use a
      non-rebasing wrapper, wsUSD.
11. **"AA paymaster spending" replaced by EIP-3009.** The x402 "exact" scheme on EVM uses EIP-3009
    `transferWithAuthorization`. The facilitator submits it and pays the gas, so agents need no
    ETH and no paymaster. ERC-1271 verification lets smart accounts pay too: ERC-4337 accounts,
    and EIP-7702 accounts whose delegate implements ERC-1271.
12. **Tests made realistic.**
    - Invariant handlers include vault losses, donations, time and entropy changes, plus a
      bank run.
    - Reference values come from an 80-digit computation.
    - Uniswap integration uses a real PoolManager.
    - "Formally verify" was dropped: nothing was formally verified, so nothing claims it.
13. **"Production-ready" became "audit-ready".** Mainnet is gated on an external audit.
14. **Phase 2 rebuilt on x402 v2.**
    - Uses the `PAYMENT-REQUIRED`, `PAYMENT-SIGNATURE` and `PAYMENT-RESPONSE` headers
      (base64 JSON), CAIP-2 networks, and a facilitator with `/verify`, `/settle` and `/supported`.
      This replaces the invented `X-402-*` headers.
    - **The server-side `recordAgentTransaction()` write to the oracle is removed:** it re-opens
      the entropy-spoofing hole closed as red-team CRITICAL-1.
    - `payTo` must be an operator address, never `AutonomousTreasury`: tokens sent there are
      stuck.
15. **Phase 3 corrected.**
    - There are no "minter / rebaser / paymaster roles" to assign: the stabilizer is the only
      minter by construction.
    - Keys come from a keystore or hardware wallet instead of raw private keys.
    - Addresses come from official sources. The legacy scripts hard-code the Base Sepolia
      PoolManager as `0x05E7…1863`, but Uniswap lists `0x05E7…3408`.
    - Verification flags are spelled out.
    - Framework versions are pinned.
    - "Treasury refinancing" goes through a human, not an autonomous pull.

---

## Phase 1: core contracts and spectral engine (spec of record, implemented)

```text
ROLE
You are a senior Solidity engineer (Foundry, Yul, Uniswap v4 hooks, ERC-4626). Write audit-ready
code: explicit invariants, minimal privileges, NatSpec on every external function, and an honest
"Known limitations" section. Never describe the result as production-ready.

PRODUCT
Spectrum Agentic USD (sUSD) is a reserve-backed, redeemable, rebasing ERC-20 for
machine-to-machine payments. sUSD is minted 1:1 against a reserve asset (e.g. USDC) held in one
external ERC-4626 vault and is always redeemable 1:1 minus a small fee. A Walsh-Hadamard
spectral-entropy signal H, computed on-chain from swap flow in one Uniswap v4 pool, adjusts
fees, a daily mint cap, a surplus buffer and the rebase step, always within fixed bounds.
H never creates or destroys backing.

ABOUT C_DIAM (state this in NatSpec)
C_DIAM = 2 + pi/3 ~= 3.047197551196597746 is the conjectured sharp length-over-diameter ratio of
self-approaching plane curves (proven: 3.0472 <= C_diam <= 3.1356). Use it only as the constant
of the churn budget defined below. Do not claim any stability property follows from it.

TOOLCHAIN
Foundry; solc 0.8.26; evm_version cancun; via_ir = true; optimizer_runs = 44_444_444 (v4-core's
setting; lower values hit stack-too-deep in PoolManager). Dependencies: OpenZeppelin Contracts
v5.4.0, forge-std, Uniswap v4-periphery (with its nested v4-core). BaseHook is no longer in
v4-periphery: implement IHooks directly. SwapParams/ModifyLiquidityParams are in
v4-core/src/types/PoolOperation.sol. No upgradeability. Enable `forge lint` and keep it clean.

CONTRACTS
1. libraries/SpectralMath.sol
   - fwht8(int256[8]): in-place unnormalised FWHT (Sylvester H8), 3 stages of butterflies in
     Yul ("memory-safe"); applying it twice gives 8x.
   - lnWad(uint256 x) -> int256: ln(x/1e18)*1e18. Range-reduce x = m*2^k with m in
     [1/sqrt2, sqrt2), then ln m = 2*atanh(z), z = (m-1)/(m+1), odd series up to z^25 computed
     with 36 decimals; k*ln2 with a 36-decimal ln2. Revert on 0. Target accuracy: within 1 wei
     of the correctly rounded value for x < 2^60, within 3 wei for all x.
   - spectralEntropy8(uint256[8] v) -> uint256 in [0, 1e18]: if max(v) = 0 return 0;
     normalise x_i = v_i*1e18/max(v) (no overflow, exact scale invariance); FWHT; P_k =
     X_k^2/sum X^2; H = -sum P_k ln P_k / ln 8 (skip P_k = 0); clamp to 1e18.
   - Semantics: constant window -> 0; single spike -> 1; invariant under scaling and under
     dyadic shifts i -> i xor s. LOW H = homogeneous flow, HIGH H = concentrated flow.
2. SpectralEntropyOracle.sol (Ownable2Step)
   - Ring buffer of the last 8 blocks with activity (uint128 per slot, saturating). All swaps
     in one block are summed into one slot. Ignore amounts below minObservation (dust).
   - When the first swap of a new block arrives and the window is full, fold
     spectralEntropy8(window, oldest first) into an EMA: e += alpha*(h - e).
   - smoothedEntropy(): neutral 0.5e18 during warm-up (< 8 blocks) and when no swap was
     recorded for staleAfter seconds; otherwise the EMA. instantEntropy(): current window.
   - record() callable only by the hook; setHook() once by the owner, irreversible. The owner
     has no other power (keeps red-team CRITICAL-1 closed).
3. SpectralToken.sol (sUSD, 18 decimals)
   - Share accounting: balance = shares*index/1e18. Only the stabilizer (set once by the
     deployer) may mint, burn or setIndex.
   - Rounding favours the reserve: mints round shares down, burns and transfers round up
     (capped at the holder's shares); a recipient always receives >= the amount.
   - EIP-2612 permit (v,r,s and bytes overloads).
   - EIP-3009 transferWithAuthorization, receiveWithAuthorization (payee-only),
     cancelAuthorization, authorizationState (v,r,s and bytes overloads). Values are in sUSD
     units, not shares. Validity: validAfter < now < validBefore; nonces per authorizer.
   - All signatures verified with OpenZeppelin SignatureChecker (EOA and ERC-1271).
   - EIP-712 domain: name "Spectrum Agentic USD", version "1".
4. AutonomousTreasury.sol: adapter around one ERC-4626 vault (no shares of its own).
   - reserveAssets() = vault.previewRedeem(shares) + idle (conservative).
   - withdrawReserve() and depositReserve() are stabilizer-only (set once); withdrawals use
     idle balance first. sweep() is permissionless.
5. SpectralStabilizer.sol (AccessControl, Pausable, ReentrancyGuard)
   - mint(assets, receiver, minOut): sync losses; sweep; credited = measured increase of
     reserve value; fee = ceil(credited * mintFee(H)); enforce the daily gross mint cap; mint;
     assert the floor.
   - redeem(amount, receiver, minAssetsOut): never pausable; sync losses; fee; burn; pay out;
     assert the floor. Minimum amount 1 sUSD (keeps vault rounding below the 1 bp fee floor).
   - rebase(): permissionless, at most once per hour; sync losses first. step =
     min(reserve/(1+buffer(H)) - supply, supply*stepRate(H)); apply via the index.
   - sync(): permissionless, never pausable; if reserve < supply, set index = reserve/shares.
   - Policy, all quadratic or linear in H and clamped:
     mint fee 1 -> 50 bp (quadratic); redeem fee 1 -> 10 bp (quadratic);
     daily cap max(bootstrapCap, epochStartSupply * (20% -> 2%));
     buffer 0.5% -> 5%; stepRate 1 bp -> 0.5 bp.
     Require REBASE_STEP_MAX < MINT_FEE_MIN + REDEEM_FEE_MIN (anti-sandwich).
   - Churn budget: within a 7-day window, L = total variation of the index, D = max - min. A
     positive rebase is deferred (event, return false) if afterwards L > C_DIAM * D. Loss
     absorption is never deferred.
   - Reserve floor: every state-changing function ends with reserveValue() >= totalSupply().
   - The guardian may pause mint and rebase only.
6. WrappedSUSD.sol (wsUSD): OpenZeppelin ERC-4626 over sUSD. Pools pair wsUSD, never raw sUSD.
7. SpectralHook.sol (implements IHooks)
   - Permissions: beforeInitialize + afterSwap only; validate them in the constructor (the
     address is mined via CREATE2).
   - The constructor fixes the single allowed PoolKey (measured currency = wsUSD, other =
     USDC, fee, tickSpacing); beforeInitialize rejects any other pool.
   - afterSwap records |delta of the measured currency| via try/catch. A failure with revert
     data is emitted as an event and the swap continues. A failure without revert data (out of
     gas) reverts the swap, so swappers cannot opt out of being recorded. All other hook
     functions revert.

TESTS (single file test/SpectrumProtocol.t.sol; mocks, handler, fixture in subfolders)
- SpectralMath:
  - FWHT against the naive Hadamard product (fuzz), involution, Parseval;
  - lnWad against reference values computed with 80-digit arithmetic (commit the generator);
  - entropy reference table, exact 0 and 1 cases, bounds for full 256-bit inputs, exact scale
    and XOR-shift invariance, monotonicity in whale size, gas.
- Oracle: access control, dust, per-block aggregation, ring order, warm-up, EMA on rollover,
  staleness, saturation, worst-case cold-storage gas of record().
- Token: rebasing math and rounding; permit and EIP-3009 from an EOA and from an ERC-1271
  wallet; replay; validity windows; forged or tampered signatures; payee-only receive;
  cancellation; value preserved across a rebase.
- Treasury and wsUSD basics.
- Stabilizer: policy endpoints and monotonicity, fees, caps (bootstrap and supply-based),
  donations, slippage, pause scope, bounded rebases, buffer, loss absorption via sync, redeem,
  mint and rebase, churn deferral in a realistic whipsaw, an exact 1-wei churn boundary
  (harness), and a fuzzed mint -> rebase -> redeem sandwich that must lose money.
- v4 integration with a real PoolManager (v4-core test Deployers + deployCodeTo at a flagged
  address): flags, other pools rejected, onlyPoolManager, per-block slots, same-block
  aggregation, calm-then-whale raises the mint fee, a broken oracle does not brick swaps, gas
  starvation reverts the swap.
- Invariants (handler: mint, redeem, transfer, rebase, yield, vault loss + sync, donation,
  entropy changes, time):
  - reserve >= supply;
  - sum of shares = totalShares;
  - sum of balances <= supply;
  - all holders can exit at once;
  - redeem and sync never fail unexpectedly;
  - the churn budget holds after every distribution;
  - the mint cap holds.

  afterInvariant: every holder redeems everything; the floor still holds.

ALSO DELIVER
- script/DeployLocal.s.sol (anvil only): mocks, PoolManager, mined hook, wsUSD/USDC pool at par,
  demo swaps, deployments/31337.json.
- README with layout, how it works, the verified properties, and "Known limitations": the C_diam
  conjecture; H cheap to manipulate (bounded impact); vault risk; admin powers; dust minimum;
  gas; not audited.

ACCEPTANCE
forge build clean (no lint warnings in src); forge test green under the default and a CI profile
(10k fuzz runs; invariants 1,024 x 256); contract sizes < 24,576 bytes; the local deployment runs
end to end.
```

---

## Phase 2: x402 v2 payment rail for sUSD

```text
ROLE
You are a senior backend engineer for web3 payments (Python 3.11+, FastAPI, web3.py v7,
eth-account, EIP-712, EIP-3009, x402).

GOAL
Build an HTTP 402 payment rail so AI agents pay per request in sUSD, gaslessly, using the x402
protocol version 2 with the "exact" scheme on EVM. Run it end to end against the Phase 1 local
deployment (anvil, chain id 31337) and make it configurable for Base Sepolia (eip155:84532).

INPUTS
- Phase 1 repository; addresses from deployments/<chainId>.json (sUSD, wsUSD, stabilizer, ...).
- sUSD supports EIP-3009 transferWithAuthorization / receiveWithAuthorization with v,r,s and
  bytes signatures, verified via ERC-1271 for smart accounts. EIP-712 domain: name
  "Spectrum Agentic USD", version "1", the chain id, verifyingContract = sUSD. 18 decimals.

PROTOCOL (x402 v2, verified 2026-10-15; re-check the spec before coding)
- No/invalid payment -> HTTP 402 with header PAYMENT-REQUIRED = base64(JSON PaymentRequired):
    { "x402Version": 2, "error": "...", "resource": {"url","description","mimeType"},
      "accepts": [ { "scheme": "exact", "network": "eip155:<chainId>",
                     "amount": "<atomic units, string>", "asset": "<sUSD address>",
                     "payTo": "<operator address>", "maxTimeoutSeconds": 60,
                     "extra": {"name": "Spectrum Agentic USD", "version": "1"} } ] }
- Client retries with header PAYMENT-SIGNATURE = base64(JSON PaymentPayload):
    { "x402Version": 2, "resource": {...}, "accepted": <the chosen requirements>,
      "payload": { "signature": "0x...", "authorization": { "from","to","value",
                   "validAfter","validBefore","nonce" (32 random bytes) } } }
- Success -> 200 with header PAYMENT-RESPONSE = base64(JSON SettlementResponse):
    { "success": true, "transaction": "0x...", "network": "eip155:<chainId>", "payer": "0x..." }
- Facilitator API: POST /verify and POST /settle with {x402Version, paymentPayload,
  paymentRequirements}; GET /supported.
  /verify returns {isValid, invalidReason?, payer?}; /settle returns
  {success, errorReason?, payer?, transaction, network}.
- Legacy v1 headers (X-PAYMENT, X-PAYMENT-RESPONSE) are optional and off by default.

USE THE OFFICIAL SDK WHERE IT FITS
pip install "x402[fastapi,httpx,evm]" (Python SDK 2.25.x, Sep 2026). Client: x402Client +
ExactEvmScheme. Server: x402ResourceServer + HTTPFacilitatorClient + ExactEvmServerScheme.
Facilitator: x402Facilitator + ExactEvmFacilitatorScheme. Pin exact versions. Public
facilitators may not support sUSD, so SELF-HOST the facilitator. If the SDK cannot be pointed at
a custom EIP-3009 asset with this EIP-712 domain, implement /verify and /settle yourself,
following the spec's steps:
1. check the signature (EIP-712; ERC-1271 for contract payers);
2. check the payer's balance;
3. require value == amount exactly;
4. check validAfter < now < validBefore, and validBefore <= now + maxTimeoutSeconds;
5. require to == payTo, asset and network as required, and an unused nonce;
6. simulate transferWithAuthorization (eth_call), then submit it and wait for the receipt.

DELIVERABLES
1. server/ (FastAPI resource server): a dependency or middleware gating /api/v1/compute (price
   from config, e.g. 0.005 sUSD = "5000000000000000"). Order: verify -> run the handler ->
   settle -> respond. If settlement fails, return 402 and discard the result.
2. facilitator/ (FastAPI): /verify, /settle, /supported.
   - The settlement key holds only ETH for gas, comes from a keystore or env, and is never
     logged.
   - Settlement is idempotent per (payer, nonce), with in-flight locking and a configurable
     number of confirmations.
3. agent_client.py: request -> 402 -> decode PAYMENT-REQUIRED -> choose the "exact" sUSD
   option -> enforce a client spend policy (max per payment and per session, in atomic sUSD
   units; the SDK's built-in spend control is a USD ceiling, so set an explicit sUSD limit) ->
   sign EIP-3009 -> retry with
   PAYMENT-SIGNATURE -> print the result and the decoded PAYMENT-RESPONSE.
4. A smart-account payer path: an ERC-1271 wallet (the Phase 1 MockERC1271Wallet on anvil) pays
   with an owner-key signature.
5. Makefile or docker-compose: anvil, forge script DeployLocal, fund the agent with sUSD (mint via
   the stabilizer), facilitator, server, demo. .env.example (anvil keys only, marked as such).
6. pytest suite: happy path; replay of the same nonce; wrong amount; wrong payTo; expired and
   not-yet-valid; tampered signature; insufficient balance; smart-account payer; settlement
   failure -> 402; a rebase between signing and settlement (the payee still receives >= value).

HARD RULES
- Do NOT write to the entropy oracle or the hook from any off-chain component. The oracle
  accepts writes only from the Uniswap v4 hook; an off-chain write path would let anyone spoof H
  (legacy red-team CRITICAL-1).
- payTo is an operator-controlled EOA or Safe. Never AutonomousTreasury or the stabilizer:
  sUSD sent there is stuck.
- No paymaster is needed: the facilitator submits transferWithAuthorization and pays the gas.
  ERC-4337 smart accounts pay through ERC-1271 signatures. So do EIP-7702-delegated EOAs, but
  only if their delegate implements ERC-1271: SignatureChecker sends every address that has
  code down the ERC-1271 path. Counterfactual (ERC-6492) wallets must be deployed first, unless
  you add a vetted factory allowlist.
- Amounts are sUSD units (18 decimals), not shares; sUSD rebases, wsUSD does not.
- No private keys in code, prompts, logs or tool arguments.

ACCEPTANCE
`make demo` shows: 402 with a decodable PAYMENT-REQUIRED; a paid retry; 200 with
PAYMENT-RESPONSE; the on-chain sUSD transfer; replay rejected. pytest is green.
```

---

## Phase 3: testnet deployment, verification and agent SDK

```text
ROLE
You are a senior DevOps and agent-tools engineer (Foundry scripting, Safe multisig, Python
packaging, LangChain / LlamaIndex / AutoGen tool interfaces).

GOAL
Deploy the Phase 1 contracts to Base Sepolia (chain 84532), verify them, wire the Phase 2
facilitator and server to the deployment, and ship a Python SDK that lets agents pay x402
endpoints in sUSD. Mainnet only as a guarded launch: a supply cap, a Safe as admin, and a
timelocked vault migration. Get an external audit before raising caps far.

1. script/DeploySpectrum.s.sol (reads config/<chainId>.json; refuses unknown chain ids)
   Config: poolManager, usdc, vault (or deployMockVault: true on testnets only), admin (Safe),
   bootstrapCap, oracle {minObservation, emaAlpha, staleAfter}, pool {fee, tickSpacing},
   seed liquidity.
   Addresses (verified 2026-10-15; still check `cast code <addr>` is non-empty on-chain):
     Base Sepolia PoolManager  0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408
     Base Sepolia PositionManager 0x4b2c77d209d3405f41a037ec6c77f7f5b8e2ca80
     Base Sepolia USDC         0x036CbD53842c5426634e7929541eC2318f3dCF7e
     Permit2                   0x000000000022D473030F116dDEE9F6B43aC78BA3
     CREATE2 deployer          0x4e59b44847b379578588920cA78FbF26c0B4956C
   (The legacy scripts' PoolManager 0x05E7...1863 does not match the official list. Do not
   use it.)
   Steps:
   a. Deploy AutonomousTreasury(vault), SpectralToken, SpectralEntropyOracle,
      SpectralStabilizer(admin = Safe), WrappedSUSD.
   b. token.setStabilizer and treasury.setStabilizer (the deployer, once).
   c. Mine the hook salt for the CREATE2 deployer (flags BEFORE_INITIALIZE | AFTER_SWAP) and
      deploy SpectralHook for the wsUSD/USDC key; oracle.setHook(hook); then
      oracle.renounceOwnership() (the owner has no further purpose).
   d. Seed wsUSD with dead shares; initialise the wsUSD/USDC pool at par (wsUSD 18 decimals,
      USDC 6: sqrtPriceX96 depends on the token order); add liquidity through the official
      PositionManager with Permit2 approvals. Never deploy v4 test routers to public networks.
   e. Write deployments/<chainId>.json. At the end, assert the wiring with require(): hook
      flags, oracle.hook, token.stabilizer, treasury.stabilizer, and roles held only by the
      Safe.
   There are NO minter, rebaser or paymaster roles to grant: the stabilizer is the only minter
   and rebaser by construction, and x402 needs no paymaster.

   Vault due diligence (record it in docs/vault.md): ERC-4626 compliance; donation-resistant
   share price; withdrawal liquidity; fees; share price < 100 asset wei per share wei; admin
   powers; audits. If no suitable USDC vault exists on Base Sepolia, deploy a plain,
   clearly labelled OpenZeppelin ERC-4626 vault over testnet USDC, and simulate yield by
   transferring USDC into it. Never deploy the test mocks (MockUSDC, MockVault) to a public
   network: their mint, loss and liquidity knobs are permissionless.

2. Commands (document them exactly; keys never on the command line)
   cast wallet import spectrum-deployer --interactive        # or use --ledger / --trezor
   forge script script/DeploySpectrum.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
     --account spectrum-deployer --sender $DEPLOYER --broadcast --slow \
     --verify --etherscan-api-key $ETHERSCAN_API_KEY
   (Etherscan API V2: one key for all supported chains. Alternative:
    --verifier blockscout --verifier-url https://base-sepolia.blockscout.com/api/)
   Post-deploy smoke test with cast: mint 10 USDC -> sUSD, redeem 5, one swap, then read
   oracle.window() and stabilizer.reserveRatio().
   Faucets: Base Sepolia ETH; Circle testnet USDC.

3. Operations
   - A keeper calls rebase() hourly and sync() on vault loss (idempotent; any scheduler).
   - Monitoring and alerts:
     - Minted / Redeemed / Distributed / RebaseDeferred / LossAbsorbed / OracleRecordFailed;
     - reserveRatio() < 1 + bufferRate(H);
     - vault liquidity (treasury.liquidAssets());
     - oracle staleness.
   - Incident runbook: guardian pause (mint and rebase only), communication, unpause criteria.

4. spectrum_agent_sdk (Python >= 3.11, pinned dependencies)
   - Core (framework-agnostic):
     - balance and allowance views;
     - an x402 v2 client built on the official `x402` SDK;
     - EIP-3009 signing;
     - a spend policy (per payment, per session, per day; allow-listed payTo and networks);
     - structured exceptions: InsufficientBalance, SpendLimitExceeded, PaymentRejected,
       SettlementFailed, PaymentTimeout.
   - Keys: one low-balance hot wallet per agent (the "session key"), or a smart account with a
     session-key module; load keys from a keystore or KMS, never from tool arguments or prompts.
   - Adapters (thin; verify each framework's current tool API and pin versions):
     LangChain (langchain-core tool / StructuredTool), LlamaIndex (FunctionTool),
     Microsoft AutoGen >= 0.4 (autogen-core FunctionTool, used by autogen-agentchat agents)
     and, optionally, AG2.
   - Low balance: raise InsufficientBalance with a structured "refinance request" (amount,
     reason, payTo). A human or the Safe approves it; the SDK never pulls funds
     autonomously.
   - Tests: unit tests with a fake facilitator; an integration test against the Phase 2 local
     stack.

5. run_agent_demo.py
   A LangChain agent (model provider configurable via env; no vendor lock-in) calls a
   402-gated endpoint through SpectrumPaymentTool. It runs on the local Phase 2 stack by default,
   and on Base Sepolia with --network base-sepolia.

ACCEPTANCE
Contracts deployed and verified on Base Sepolia; deployments/84532.json committed; the smoke
test passes; the SDK's unit and integration tests are green; the demo pays and prints the
settlement transaction hash. A README states that the system is unaudited, that H is a bounded
heuristic, that C_diam is a conjecture used as a design constant, and that mainnet requires an
audit and legal review.
```

---

## Sources

- x402 v2 HTTP transport (headers, payload examples): https://github.com/coinbase/x402/blob/main/specs/transports-v2/http.md
- x402 v2 specification (schemas, facilitator API, EVM exact scheme): https://github.com/coinbase/x402/blob/main/specs/x402-specification-v2.md
- x402 repository (now under the x402 Foundation): https://github.com/coinbase/x402
- x402 Python SDK 2.25.0 (Sep 29, 2026): https://pypi.org/project/x402/
- x402 wallet compatibility (EOA, ERC-4337, ERC-6492, EIP-7702; EIP-3009 vs Permit2): https://docs.x402.org/advanced-concepts/wallet-compatibility
- Uniswap v4 deployments (Base Sepolia and Base addresses): https://developers.uniswap.org/docs/protocols/v4/deployments.md
- Circle USDC addresses: https://developers.circle.com/stablecoins/usdc-contract-addresses
- Foundry deploying and verifying: https://getfoundry.sh/forge/deploying
- Etherscan API V2 (one key, many chains): https://docs.etherscan.io/etherscan-v2/contract-verification/verify-with-foundry

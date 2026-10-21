# Spectrum Protocol: engineering prompts (Phases 1–4)

Revision: 2026-10-16. This replaces the "Complete 3-Phase Production Engineering Prompts"
document and adds Phase 4.

Each prompt is self-contained. Phases 1–3 are model-agnostic: paste them into any capable
coding agent. Phase 4 is written for Claude Code: it uses a subagent for the final review.
**Phase 1 is already implemented in this repository.** Its prompt below is the spec of record
and matches the code, so an auditor, or an agent regenerating the code, works from the same
text.

**Status, 2026-10-17.**
- **Done: Phase 4** on branch `phase-4-hardening`, frozen at tag `audit-freeze-1`
  (`REPORT_PHASE4.md`). Every Track A finding is fixed or analysed, Track B is measured, the
  paper's proven results are implemented and tested, and an independent review has run
  (`audit/review.md`). The churn budget now uses the proven constant: no code depends on an open
  conjecture. Recommendation D4 changed the mint-fee ceiling to 25 bp, and B8 added 1,250 USDC of
  protocol capital, so the deployer needs 1,252 USDC.
- **Done:** Phase 1, and the deployment half of Phase 3, for Base mainnet as a guarded launch
  (`RUNBOOK_MAINNET.md`, `make deploy-base-mainnet`). The kit is ready but **not yet
  broadcast**. It follows the October 2026 research report:
  - reserve in Aave waBasUSDC behind a 15% idle USDC buffer, with Gauntlet USDC Prime as the
    fallback;
  - a static 1 bp pool fee;
  - x402 payments taken in USDC through the CDP facilitator;
  - a 25,000 sUSD supply cap;
  - a Safe as admin.
- **Next:** the Base Sepolia dress rehearsal of the deploy workflow (`network=base-sepolia`,
  `RUNBOOK_MAINNET.md` §1A), then the guarded mainnet broadcast, then an external audit before
  the supply cap rises past 25,000 sUSD. Phase 2 (self-hosted sUSD facilitator) and the Phase 3
  SDK come after the launch.

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

## Phase 4: optimization, security, and the paper's proven results (done, 2026-10-17)

Claude reviewed `base-mainnet-kit` at commit 522881c on 2026-10-16. The review covered the
contracts, the deploy workflow, a gas report, and the paper (Langetepe and Ashioya, revised
version 21). The prompt below fixes what it found, makes the hot paths cheaper, and uses the
paper's proven results where they actually hold.

**What the review found.** None of these lets an outsider take reserve funds from a correctly
deployed system. A1–A4 touch minting or the deployment itself, so fix them before the broadcast.

| ID | Severity | Finding |
|---|---|---|
| A1 | Medium | The daily mint cap counts gross minting, and redemptions don't free it. A flash-loan mint-and-redeem round trip in one transaction uses up the cap for the rest of the day. Measured: a 9,901 USDC round trip cost 1.98 USDC and left 0.00000001 sUSD of capacity; the next 100 USDC mint reverted. |
| A2 | Low | `beforeInitialize` ignores the starting price. Once the hook is on-chain, anyone can initialise its pool at any price before the deploy script does. |
| A3 | Medium | `setStabilizer` runs in a later transaction than the token and treasury deployments. Whoever holds the deployer key in between can make itself the sole minter. |
| A4 | Medium | The deploy workflow gives the deployer key to every step, including `forge test`, which runs dependency code. Actions are not pinned to commits. |
| A5 | Medium (trust) | After the 7-day timelock, the admin Safe can move about 85% of the reserve into any contract that reports USDC as its asset. |
| A6 | Medium (economic) | About 16 small swaps in 16 blocks (about 30 seconds on Base) move H to 0 or to 1. H sets the mint fee (1–50 bp), the supply-based daily cap (20%–2%) and the surplus buffer (0.5%–5%). |
| A7 | Low | Balances under 1 sUSD can't be redeemed. |
| A8 | Info | A gas test fails under `--gas-report` (77,228 against a 70,000 limit), though it passes in normal mode (50,352). |

**The paper.** The code uses one number from it, 2 + π/3, as a design constant in a
one-dimensional rule (the churn budget). The paper proves that ratio is approached, but only
conjectures it is the maximum. On a line a self-approaching path is just monotone, so the
planar theorems constrain nothing there. None of the proven results is used yet. Phase 4 puts
them to work where they hold:
1. Lemma 7.1 becomes an exact integer test of whether a polygon is self-approaching.
2. Lemma 2.1 and Theorem 4.3 give that polygon's diameter in one pass and a proven bound:
   length ≤ 3.1356 × diameter.
3. Lemma 2.2, Corollary 3.2, Theorem 5.4 and Lemma 5.1 become test oracles and adversarial
   generators.
4. Section 7.5 becomes a regression test. A check made only at sampled points accepts a
   sequence longer than any self-approaching curve in its region could be (fixture in
   `test/paper/fixtures/`).

The proven results stay out of the money logic until the reserve becomes two-dimensional (two
vaults plus idle funds). There the bound becomes a proven limit on rebalancing turnover.

**Claude's recommendations.** Track D of the prompt applies them as defaults.
1. Run Phase 4 before the broadcast. The contracts can't be upgraded, so a later fix means a
   new token and moving every holder.
2. If you broadcast first anyway, deploy with the Ledger and ship A2's price check in the hook.
   The Ledger removes A4 and the key-leak path in A3.
3. After Phase 4, tag an audit freeze and run the deploy workflow once on Base Sepolia. Then
   broadcast the guarded launch. Get an external audit before raising the 25,000 sUSD cap.
4. Pay yield from day one with protocol capital that is never paid out and absorbs first
   losses, instead of shrinking the buffer. About 1,250 USDC covers the largest buffer at the
   25,000 cap.
5. H may raise safety margins but never lower them. Keep the surplus buffer at or above its
   neutral 2.75% whatever H reads.
6. Fix the list of allowed vaults at deployment: Aave waBasUSDC and Gauntlet USDC Prime.

**How to run it.**
1. Open Claude Code at the repository root, on `base-mainnet-kit` (or `main` once you have
   pushed the kit there).
2. For the fork items, export a read-only `BASE_RPC_URL`.
   - Slither and Halmos need Python 3.11 with network access.
   - Aderyn and the mutation tester need Rust.
   - Anything that can't be installed is marked BLOCKED, and the rest continues.
3. Say `Execute Phase 4 from PROMPTS.md.`, or paste the block below. The result is branch
   `phase-4-hardening` plus `REPORT_PHASE4.md`.

```text
ROLE
You are Claude in Claude Code, the lead security and performance engineer for Spectrum Protocol
(Foundry, Solidity 0.8.26, Uniswap v4 hooks, ERC-4626, Base). You also turn theorems from
convex geometry into exact integer code and tests. Work like an auditor who ships the fixes:
every claim is backed by a test, a measurement or a machine-checked proof, and every
limitation is written down.

STARTING POINT (2026-10-16)
- Branch base-mainnet-kit (or main, if the kit was pushed there), commit 522881c or later.
  Create branch phase-4-hardening from it. Read README.md, RUNBOOK_MAINNET.md and PROMPTS.md
  (Phase 1 is the spec of record) before changing anything.
- Nothing is deployed on a public network. 135 tests pass; the Base fork suite is skipped
  without BASE_RPC_URL. script/rehearsal/run.sh passes.
- Runtime sizes in bytes: SpectralStabilizer 18,072; SpectralToken 9,534; AutonomousTreasury
  9,271; SpectralEntropyOracle 5,957; WrappedSUSD 5,352; SpectralHook 3,841.
- Gas from forge test --gas-report (isolated, so it includes 21k intrinsic gas; mock vault):
  - mint: median 259,986, max 305,884
  - redeem: 140,436 / 178,096
  - rebase: 74,819 / 135,319
  - sync: 81,187
  - transfer: 56,179
  - oracle.record: 36,608 / 87,435
  In normal mode, record() closing a window with cold storage costs 50,352, of which
  spectralEntropy8 is 32,945.
- Toolchain: Foundry 1.5.1; solc 0.8.26; via_ir; optimizer_runs 44,444,444; evm cancun;
  bytecode_hash none. Change these only for a measured reason.

RULES
1. Autonomy. Work through the items in order without asking. Stop and ask only before removing
   a documented safety property or changing who can move reserve funds. Nothing is broadcast
   in this phase, to testnet or mainnet.
2. Red, then green. For every fix, first write a test that fails on the current code, then make
   the fix. Never weaken, skip or delete a test or invariant to get green. Where this prompt
   changes a spec (A1, A3, A6, B8), update the tests of the old spec in the same commit and say
   so in the message.
3. Self-correct. When something fails, find the cause before retrying. If a tool cannot be
   installed (no network, policy block), mark the item BLOCKED with the exact error and go on.
   Never disable TLS verification or proxies.
4. One commit per item, with the message "phase4(<ID>): <what>". Keep script/, config/, the
   rehearsal, CI and the docs in step with every interface or constructor change.
5. Measure. Gas comes from forge (say which mode) and, when BASE_RPC_URL is set, from the Base
   fork against the real vaults. Sizes come from forge build --sizes.
6. Honesty. Never write "production-ready". Say "proven" only for what a named tool proved,
   with its bounds. A conjecture is never used as a guarantee.
7. No private keys in code, logs, prompts, tool arguments or commits. Fork access is read-only.
8. Keep every item in your task list. Order:
   1. A0, then a Slither baseline;
   2. A1-A8;
   3. B1-B7;
   4. C1-C5;
   5. A9-A13;
   6. B8;
   7. D1-D7;
   8. the final checks.

TRACK A: SECURITY
Each item states what the review found. Confirm it with a failing test first. If it is not
real, record why in audit/findings.md and move on.

A0  Threat model, in audit/threat-model.md:
    - actors: holders, minters, swappers, keepers, admin Safe, guardian, vault, PoolManager,
      x402 facilitator, deployer, CI;
    - assets and trust assumptions;
    - every external entry point with its checks;
    - every invariant, mapped to the test that enforces it.

A1  [Medium] Mint-cap griefing.
    Finding: _consumeExpansion counts gross minting per epoch, and redeem never frees
    capacity. A round trip in one transaction (flash-borrow USDC, mint the remaining cap,
    redeem, repay) blocks all other minting for the rest of the epoch. Measured with H = 0 and
    a 10,000 sUSD bootstrap cap: a 9,901 USDC round trip cost 1.98 USDC and left 1e10 wei of
    capacity, and a following 100 USDC mint reverted.
    Fix: count net expansion (redemptions in the epoch reduce mintedInEpoch, floored at 0), or
    a design you show is at least as good.
    Tests: the same-transaction round trip leaves capacity unchanged; net growth per epoch
    stays capped; the "mint cap holds" invariant uses the net definition.

A2  [Low] Pool initialisation price.
    Finding: beforeInitialize checks the PoolId and ignores sqrtPriceX96. Once the hook exists,
    anyone can initialise its pool at any price; the deploy script's initialize then reverts,
    and the pool starts off-peg.
    Fix: require the price to be within 50 bp of wsUSD's redemption value at that moment, that
    is convertToAssets(1e18) of the measured currency. wsUSD has 18 decimals and USDC 6;
    handle both token orders. PostDeployCheck asserts that the live pool price is inside the
    same band.
    Tests: with the real PoolManager (v4-core Deployers) and on the Base fork.

A3  [Medium] Wiring window.
    Finding: SpectralToken and AutonomousTreasury let `deployer` call setStabilizer once, in a
    later transaction, and the oracle's owner calls setHook later too. Whoever holds the
    deployer key in between can make itself the sole minter or the oracle's only writer.
    Fix: wire everything in the constructors.
    - Predict CREATE addresses from the deployer's nonce (vm.computeCreateAddress).
    - Predict the hook's CREATE2 address from the mined salt. Its init code contains the
      oracle's predicted address, so there is no cycle.
    - Remove setStabilizer, setHook, the deployer immutables and the oracle's Ownable.
    - The script aborts if any prediction is wrong.
    The deployment loses its four wiring transactions (setStabilizer twice, setHook,
    renounceOwnership).

A4  [Medium] CI secrets (.github/workflows/deploy-base-mainnet.yml).
    Finding: DEPLOYER_PRIVATE_KEY is in the job-level env, so every step can read it. That
    includes `forge test`, which executes dependency code: vm.envString plus a fork call to an
    attacker's URL would leak it.
    Fix:
    - The deployer address becomes a non-secret input or repository variable.
    - Only the broadcast step receives the key, and it first checks that the key matches that
      address.
    - Pin every action to a full commit SHA, in test.yml too.
    - checkout with persist-credentials: false.
    - Top-level permissions: {} with per-job grants.
    - timeout-minutes on every job.
    actionlint stays clean.

A5  [Medium, trust] Vault governance.
    Finding: after the 7-day timelock the admin can migrate to any contract whose asset() is
    USDC. migrateVault then deposits all idle funds above the buffer target into it, about 85%
    of the reserve.
    Fix (default):
    - an immutable allowlist of at most 4 vaults, set in the constructor; in config/8453.json
      these are Aave waBasUSDC and Gauntlet USDC Prime;
    - proposeVault rejects any other vault;
    - emergencyExitVault to idle funds always works.
    Also move the stabilizer to OpenZeppelin AccessControlDefaultAdminRules (two-step admin
    transfer, 3-day delay).
    Tests for both, including on the fork.

A6  [Medium, economic] Entropy is cheap to steer.
    Finding: the EMA folds once per active block with alpha 0.25. About 16 swaps above the
    10 wsUSD dust limit, in 16 consecutive blocks (about 30 s on Base), move H 99% of the way
    to 0 or to 1. H sets the mint fee (1 to 50 bp), the supply-based daily cap (20% to 2%) and
    the surplus buffer (0.5% to 5%). Holding H at 0 pays out the first-loss cushion down to
    0.5%.
    Do:
    a) Measure on the Base fork the swaps, blocks, gas and pool fees needed to move the
       smoothed H from 0.5 to <= 0.05 and to >= 0.95. Write audit/oracle-manipulation.md.
    b) Time-based smoothing. Each fold gets weight w = min(ALPHA_MAX, dt / (dt + TAU)), where
       dt is the time since the previous fold, TAU is an immutable (default 1 hour) and
       ALPHA_MAX is 0.25. Folds packed into seconds then carry almost no weight, and the first
       fold after a quiet period moves the EMA at most 25%.
    c) Net flow per block. The hook passes the signed delta of the measured currency, and each
       slot holds |sum of signed deltas| for its block. Same-block round trips, sandwiches
       included, then add almost nothing. The dust filter stays per swap.
    d) Apply D4: H never lowers the buffer below its neutral value.
    e) Re-measure (a). Add H = 0, H = 1e18 and sudden switches between them to the invariant
       handler.

A7  [Low] Dust cannot exit.
    Finding: MIN_AMOUNT = 1 sUSD exists only to keep the fee above vault rounding, which is a
    few USDC wei (a few 1e12 sUSD wei).
    Fix: derive the smallest safe minimum from that bound, and test fee >= worst-case rounding
    at that minimum. Let a holder redeem a whole balance below it when idle funds can pay.

A8  [Info] The gas test depends on the mode.
    Finding: test_record_worstCaseGasFitsHookBudget measures 50,352 normally and 77,228 under
    --isolate (which --gas-report turns on), against a 70,000 limit.
    Fix: measure the call itself (vm.lastCallGas or vm.snapshotGasLastCall) so the budget
    means the same in every mode. Add forge test --isolate to CI.

A9  Loss front-running. A holder who sees a vault loss coming can redeem at par first.
    - Quantify how much that shifts onto the other holders, as a function of the surplus (the
      first-loss cushion) and the fees.
    - Test that a loss smaller than the surplus never lowers the index.
    - Record the result in the threat model.
    Build nothing more unless the launch parameters leave exposure beyond the cushion.

A10 "No free lunch" invariant. Add an attacker actor to the handler. Within one call it can
    mint, redeem, transfer, rebase, sync, rebalance, donate, swap in the pool (moving H) and
    flash-borrow. Ghost-account its value in USDC, and assert it never ends above its start
    plus its pro-rata share of distributed surplus. Run it under the CI profile.

A11 Tools.
    - Slither: no unresolved High or Medium; triage everything in audit/slither.md. Run Aderyn
      too if it installs.
    - Halmos (test/halmos, check_* functions):
      - token share math: the recipient gets >= amount; mint rounds down and burn rounds up;
        two balances sum to <= totalSupply; transfers conserve totalShares;
      - each policy curve is monotone and within its bounds for every h;
      - REBASE_STEP_MAX < MINT_FEE_MIN + REDEEM_FEE_MIN;
      - churn arithmetic cannot overflow for index < 2^128;
      - fwht8 is linear, and fwht8(fwht8(x)) = 8x for |x_i| < 2^100.
      lnWad and the entropy are nonlinear: keep them fuzzed and checked against reference
      values, and claim no proof for them. audit/formal.md lists, for each property, the tool
      version, bounds, result and time.
    - Mutation testing (gambit or vertigo-rs) on src/, with the kill rate per contract in
      audit/mutation.md. Every surviving non-equivalent mutant in the stabilizer, treasury or
      token gets a test or a written reason.
    - Coverage: forge coverage --ir-minimum, reporting line and branch coverage of src/.

A12 Base fork. Needs BASE_RPC_URL; without it the item is BLOCKED. Extend BaseMainnetForkTest
    with:
    - gas for mint, redeem and rebase against the real waBasUSDC and Gauntlet USDC Prime;
    - a liquidity squeeze: borrow Aave's USDC down on the fork. Redemptions are paid from idle
      funds first, then revert with InsufficientLiquidity(available);
    - emergency exit, and migration between the two real vaults;
    - A2's front-run attempt against the real PoolManager.

A13 Dependencies.
    - Current pins: v4-periphery 9969eec, an untagged main commit from 2026-09-19; v4-core
      59d3ecf (v4.0.0-12); OpenZeppelin v5.4.0 (c64a1ed); forge-std v1.17.0.
    - Pin v4-periphery to a release tag, or justify the commit.
    - audit/dependencies.md lists each dependency with its version, commit and the reason.
    - CI fails if a submodule commit drifts.

TRACK B: OPTIMIZATION
Measure every target the same way before and after. If a target can't be met without breaking a
test or a property, stop at the best safe value and say why.

B1  Value the reserve once per step. mint calls treasury.reserveAssets() six times: in
    _syncLoss, sweep, before, depositReserve, after and _assertSolvent. Each of those makes
    three external calls (vault.balanceOf, vault.previewRedeem, and USDC.balanceOf through the
    FiatToken proxy).
    Fix: have the treasury return the values it computes and pass them on. Never reuse a value
    across a state change.
    Targets: mint -25% on mocks and -15% on the fork; redeem -10%; rebase -15%.
B2  OpenZeppelin ReentrancyGuardTransient in the stabilizer and the treasury. EIP-1153 is live
    on Base.
B3  Pack the epoch and churn state into the fewest storage slots: uint64 times, uint128 amounts
    and index statistics, and SafeCast where values enter. Write the bounds in comments and
    test them.
B4  The oracle hot path, after A6.
    - Targets: spectralEntropy8 <= 20,000 gas (stretch 15,000); record() closing a window with
      cold storage <= 38,000.
    - Allowed:
      - plain arithmetic where operands are provably small (inputs <= 2^128 before
        normalising, powers <= 6.4e37);
      - fewer memory arrays;
      - multiplying by 1/ln 8;
      - dropping the per-swap Observed and DustIgnored events, since the PoolManager's Swap
        event carries the same data.
    - A faster logarithm is allowed only if the 80-digit reference tests pass unchanged.
B5  Token. Use one mulDiv instead of two in _sharesToDebit on the common path. Use unchecked
    arithmetic only where a bound is stated and tested. Target: transfer -10%.
B6  After Track A, every contract is under 24,576 bytes with at least 1,024 bytes to spare. If
    the stabilizer doesn't fit, move quoteMint, quoteRedeem, reserveRatio, surplus,
    expansionRemaining and supplyCapRemaining to a SpectrumLens contract.
B7  Commit .gas-snapshot. CI runs forge snapshot --check --tolerance 1.
B8  Parameters and day-one yield (sim/, in Python 3.11 or Foundry).
    - Scenarios: vault APY 2, 4 and 6%; idle buffer 10, 15 and 20%; H at 0, 0.5, 1 and
      adversarial; losses of 0.5% and 2%.
    - Report: days to the first distribution; holder APY over 12 months; the size and
      frequency of negative rebases; the griefing cost of A1 and A6 after the fixes.
    - Then implement protocol capital (the default):
      - contributeCapital(assets) lets anyone add reserve without minting;
      - the amount is never distributed, and nobody can withdraw it;
      - rebase may raise supply only up to
        min(reserve / (1 + bufferRate(H)), reserve - protocolCapital).
      A plain donation would not work: it is surplus, and gets paid out to the earliest
      holders at up to 1 bp of supply per hour.
    - Config: params.seedCapitalUSDC (default 0), contributed by the deploy script. Recommend
      values in audit/parameters.md; 1,250 USDC covers a 5% buffer at the 25,000 sUSD cap.
B9  Optional, and only if B6 leaves room: mintWithAuthorization, a one-transaction mint for
    agents through USDC's EIP-3009 receiveWithAuthorization, with the stabilizer as payee.

TRACK C: THE PAPER'S PROVEN RESULTS
Source: E. Langetepe and W. A. Ashioya, "The length-over-diameter ratio of self-approaching
curves", revised version 21 (October 2026). Attach the PDF if you have it; everything needed
is below. A polygon is v_0..v_N, L is its length and D its diameter.
  Lemma 7.1      v_0..v_N is self-approaching iff (v_j - v_i)·(v_i - v_{i-1}) >= 0 for all
                 1 <= i < j <= N. It is exact: integer coordinates need no tolerance.
  Lemma 2.1      For a self-approaching curve, D = max over t of |C(0) - C(t)|.
  Lemma 2.2      Seen from any point x of the curve, any two later points z1 and z2 satisfy
                 (z1 - x)·(z2 - x) >= 0, an angle of at most 90 degrees.
  Corollary 3.2  L <= the perimeter of the convex hull.
  Theorem 4.3    (proven) L <= (5π/6 + 2 sin(π/12)) D = 3.13563196819653589... D.
  Theorem 5.4    (proven) ratios L/D arbitrarily close to 2 + π/3 = 3.04719755119659774...
                 occur, so no smaller constant is a valid bound.
  Conjecture 1.2 (open) 2 + π/3 is the exact supremum.
  Lemma 5.1      A cycloidal cascade on a segment of length w with n pieces has length 2w
                 and stays within πw/(2n) of the segment. A shape condition alone therefore
                 allows doubled length in an arbitrarily thin band.
  Section 7.5    Checks at sampled points are not enough. A 31-point sequence in the cap K
                 satisfies the triple condition at its own points, but its polygon violates
                 Lemma 7.1 and has length 2.0907 > per(K) = 1 + π/3 = 2.0472
                 (test/paper/fixtures/self_contracted_cap_31.json).
  Section 7.2    Absolute tolerances let microscopic zig-zags through; the scale-invariant
                 test cos(angle(v_j - v_i, v_i - v_{i-1})) >= -1e-6 does not.
Today the code uses one number from the paper, C_DIAM = 2 + π/3, as a design constant in a
one-dimensional rule (the churn budget). On a line a self-approaching path is monotone
(L = D), so the planar theorems say nothing there. None of the proven results above is used.

C1  Constants and citations.
    - Add C_SA_UPPER_WAD = 3_135_631_968_196_535_891 (Theorem 4.3, rounded up so that checks
      stay sound).
    - Keep C_DIAM_WAD in the churn budget as a design constant. Its NatSpec says it is
      attained (Theorem 5.4), conjectured sharp (Conjecture 1.2), and that no stability
      property follows.
    - Cite the paper with its version-21 numbering in NatSpec and the README.
C2  src/libraries/SelfApproaching.sol: pure functions, exact in integers for coordinates with
    absolute value <= 2^125 (every dot product then fits in int256):
    - isSelfApproaching(xs, ys): Lemma 7.1, O(N^2);
    - canAppend(xs, ys, x, y): only the N new constraints of Lemma 7.1, O(N);
    - diameterSqFromStart(xs, ys): Lemma 2.1, O(N);
    - lengthBound(xs, ys) returns (lengthUp, diameterDown, ok). Segment lengths are rounded up
      and the diameter down; ok = lengthUp * 1e18 <= C_SA_UPPER_WAD * diameterDown.
    NatSpec names the result behind each function. Report gas for N = 8, 16 and 32.
C3  test/paper/: the theorems as test oracles.
    Generators:
    - random walks with momentum;
    - arcs of angle <= 0.9π about a later point;
    - the limit curve of Theorem 5.4: a unit arc of angle π/3 about its end point f, then the
      chord to f (ratio 1 + π/3);
    - spirals about the end point;
    - polygonal cycloid cascades built from the Lemma 5.1 formulas;
    - random clouds.
    For every accepted polygon, assert:
    (1) diameterSqFromStart equals the brute-force O(N^2) diameter (Lemma 2.1);
    (2) the angle condition of Lemma 2.2 holds at every vertex;
    (3) L <= the perimeter of the convex hull, with directed rounding (Corollary 3.2);
    (4) lengthBound(...).ok (Theorem 4.3).
    For every rejected polygon:
    (5) build a witness. A point just before v_i on its incoming segment, v_i and v_j violate
        eq. (1.1).
    Also:
    (6) an invariant handler that appends random points accepted by canAppend and restarts now
        and then. It logs the best L/D found and asserts it stays below C_SA_UPPER.
    (7) The Section 7.5 fixture passes a vertex-only triple check (relative tolerance 1e-9),
        fails isSelfApproaching, and has length above 1 + π/3.
    (8) Optional: agreement with the paper's Python model (sapoly.py) on 1,000 polygons kept
        clear of the boundary (|cos| > 1e-6).
C4  On-chain use: the library only, in this phase. The first two-dimensional state will be a
    reserve split across two vaults and idle funds. Write docs/design/reserve-allocation.md:
    - In each epoch, accept a new allocation only if canAppend holds.
    - Lemma 2.1 and Theorem 4.3 then cap the epoch's total turnover at C_SA_UPPER times the
      largest distance from the epoch's starting allocation.
    - Include the threat analysis, and compare with a plain turnover cap, which may be enough.
    Do not wire it into the core contracts.
C5  docs/paper-map.md: for each result of the paper, where it is implemented or tested, or why
    it is not used. Proposition 6.3, Remark 4.4, Lemmas 6.5, 6.6 and 6.8, and Conjectures 6.9
    and 6.10 have no engineering use. End with the do-not list:
    - no "self-approaching supply";
    - no stability claims from geometry;
    - no conjecture used as a guarantee.

TRACK D: RECOMMENDATIONS
Apply these as defaults. Change one only with a written reason.
D1  The order after this phase:
    1. Tag audit-freeze-1.
    2. Dress-rehearse the deploy workflow on Base Sepolia. Prepare config/84532.json, using a
       plain, clearly labelled OpenZeppelin ERC-4626 vault over Circle's test USDC that the
       script deploys on testnets only, and add a network input to the workflow. The user
       runs it.
    3. The guarded mainnet launch.
    Update RUNBOOK_MAINNET.md and the PROMPTS.md status.
D2  Prepare audit/README.md for an external audit: scope (src/, with line counts), the frozen
    commit, build steps, threat model, invariants, known issues and the A11 reports. Contact
    nobody.
D3  Day-one yield comes from protocol capital (B8), not from a smaller buffer.
D4  H may raise safety margins but never lower them: bufferRate(h) >= bufferRate(0.5e18) for
    every h. After B8, narrow any H-controlled range that is worth griefing, for example the
    50 bp mint-fee ceiling.
D5  Deploy from a hardware wallet (make deploy-base-mainnet with --ledger). If GitHub Actions is
    used instead, A4 applies, and the key is fresh and funded just before the run.
D6  No features beyond this list: the x402 facilitator is Phase 2, the SDK is Phase 3, and
    multi-vault allocation comes after the audit.
D7  Keep the README's "Known limitations", the experimental-token label and the legal note
    true.

FINAL CHECKS (report each)
- forge build with no lint warnings in src; forge test; FOUNDRY_PROFILE=ci forge test;
  forge test --isolate.
- The Base fork suite with BASE_RPC_URL, or BLOCKED with the reason.
- script/rehearsal/run.sh ends with REHEARSAL PASSED; commit rehearsal/latest.log.
- Every contract under 24,576 bytes with at least 1,024 bytes to spare.
- Slither triaged; Halmos results in audit/formal.md; mutation and coverage reports.
- Independent review. Start a fresh subagent that has not seen your work. Give it only the diff
  from base-mainnet-kit, audit/threat-model.md and Track A, and ask it to break the changes.
  Fix what it finds (red, then green) and save its report as audit/review.md.

DELIVER
- Branch phase-4-hardening, one commit per item.
- REPORT_PHASE4.md:
  - findings (ID, severity, status, test);
  - gas and sizes, before and after;
  - what is proven (tool, bounds), what is fuzzed, and what is untested;
  - residual risks;
  - the paper map;
  - a go/no-go checklist for the broadcast.
```

---

## Sources

- Phase 4: E. Langetepe and W. A. Ashioya, "The length-over-diameter ratio of self-approaching
  curves", manuscript, revised version 21 (October 2026). The numbering above follows that
  version.

- x402 v2 HTTP transport (headers, payload examples): https://github.com/coinbase/x402/blob/main/specs/transports-v2/http.md
- x402 v2 specification (schemas, facilitator API, EVM exact scheme): https://github.com/coinbase/x402/blob/main/specs/x402-specification-v2.md
- x402 repository (now under the x402 Foundation): https://github.com/coinbase/x402
- x402 Python SDK 2.25.0 (Sep 29, 2026): https://pypi.org/project/x402/
- x402 wallet compatibility (EOA, ERC-4337, ERC-6492, EIP-7702; EIP-3009 vs Permit2): https://docs.x402.org/advanced-concepts/wallet-compatibility
- Uniswap v4 deployments (Base Sepolia and Base addresses): https://developers.uniswap.org/docs/protocols/v4/deployments.md
- Circle USDC addresses: https://developers.circle.com/stablecoins/usdc-contract-addresses
- Foundry deploying and verifying: https://getfoundry.sh/forge/deploying
- Etherscan API V2 (one key, many chains): https://docs.etherscan.io/etherscan-v2/contract-verification/verify-with-foundry

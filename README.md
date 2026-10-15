# Spectrum Protocol: Phase 1 smart contracts

> **Status: audit-ready draft.** Not audited, not formally verified, not production-ready.
> Deploy to testnets only until an external audit is done.

Spectrum Agentic USD (**sUSD**) is a reserve-backed, redeemable, rebasing ERC-20 built for
machine-to-machine payments. It supports EIP-3009 `transferWithAuthorization`, the format used by
the x402 "exact" payment scheme, and verifies smart-account (ERC-1271) signatures.

Monetary policy settings (fees, the daily mint cap, the surplus buffer and the rebase step size)
move with **H**. H is a Walsh-Hadamard spectral entropy computed on-chain from swap flow in one
Uniswap v4 pool. **H never creates or removes backing.** It only adjusts those settings, always
within fixed bounds.

The previous SPCM v2 files are kept unchanged in [`legacy/spcm-v2/`](legacy/spcm-v2/).
[`PROMPTS.md`](PROMPTS.md) holds the corrected 3-phase engineering prompts and explains what
changed and why.

---

## Quick start

```bash
git submodule update --init --recursive   # forge-std v1.17.0, OpenZeppelin v5.4.0, v4-periphery (+ v4-core);
                                          # re-run it if a nested fetch times out
forge build                               # first build takes about 2 min (via-IR, v4-core PoolManager)
forge test                                # 97 unit/fuzz tests + 8 invariants (256 runs x 128 calls)
FOUNDRY_PROFILE=ci forge test             # 10k fuzz runs; invariants 1,024 runs x 256 calls

# full local deployment: mocks, PoolManager, mined hook, wsUSD/USDC pool, 9 demo swaps
anvil &
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --slow \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil key #0
cat deployments/31337.json                # addresses for the Phase 2 server and client
```

Toolchain used to produce the results below: Foundry 1.5.1, solc 0.8.26, EVM `cancun`, via-IR,
optimizer runs 44,444,444. v4-core needs these optimizer settings: lower values hit
stack-too-deep in `PoolManager` under via-IR.

## Layout

| Path | What |
|---|---|
| `src/libraries/SpectralMath.sol` | FWHT-8 (Yul butterflies), `lnWad`, `spectralEntropy8` |
| `src/SpectralEntropyOracle.sol` | 8-block ring buffer, dust filter, EMA, warm-up and staleness fallbacks |
| `src/SpectralToken.sol` | sUSD: share-based rebasing ERC-20, EIP-2612, EIP-3009, ERC-1271 |
| `src/AutonomousTreasury.sol` | Adapter that holds the reserve in one external ERC-4626 vault |
| `src/SpectralStabilizer.sol` | Mint/redeem, fees, mint cap, buffer, micro-rebases, loss absorption, churn budget |
| `src/WrappedSUSD.sol` | wsUSD: non-rebasing ERC-4626 wrapper. Pools must use it, never raw sUSD |
| `src/SpectralHook.sol` | Uniswap v4 hook (`beforeInitialize` + `afterSwap`) that feeds the oracle |
| `test/SpectrumProtocol.t.sol` | The full suite (9 test contracts) |
| `test/handlers/`, `test/mocks/`, `test/utils/` | Invariant handler, mocks, shared fixture |
| `test/reference/` | 80-digit Python reference values for `lnWad` and the entropy, plus their generator |
| `script/DeployLocal.s.sol` | One-shot local deployment (anvil only) |
| `legacy/spcm-v2/` | Previous design, unchanged |

## How it works

1. **Backing.** `mint` takes collateral (e.g. USDC) into the treasury, which deposits it in the
   ERC-4626 vault. The minter receives the *measured* increase in reserve value minus a fee.
   `redeem` burns sUSD and pays collateral 1:1 minus a fee. Redemption cannot be paused.
2. **Reserve floor.** Every state-changing entry point ends with
   `reserveValue() >= totalSupply()` and reverts if it fails. The reserve is valued
   conservatively: `previewRedeem` of the vault shares, plus idle balance.
3. **Losses.** A realised loss inside the vault can push the reserve below supply. `sync()`
   lowers the index so that supply equals the reserve, sharing the loss pro rata. `sync()` is
   permissionless, cannot be paused, and runs first in every mint, redeem and rebase, so nobody
   can exit at the old price.
4. **Distributing surplus.** Fees and vault yield create surplus. `rebase()` is permissionless
   and allowed at most once an hour. It raises every balance by at most 1 bp of supply (0.5 bp at
   H = 1), and only out of surplus above an H-dependent buffer. A rebase step is always smaller
   than the minimum mint fee plus redeem fee, so a mint → rebase → redeem sandwich always loses
   money (fuzz-tested).
5. **Entropy H.** The oracle keeps one slot per *block*: all swaps in a block are summed, and
   blocks with no swaps are skipped. When a new block starts, it folds the Walsh-Hadamard spectral
   entropy of the last 8 active blocks into an EMA. Semantics:
   - an even, homogeneous flow gives H = 0;
   - one block dominating the window (a whale or MEV spike) gives H = 1.

   (The original prompt had this backwards.) H is neutral (0.5) during warm-up and after one hour
   without swaps.
6. **Policy (all bounded):**

   | | H = 0 (calm) | H = 0.5 | H = 1 (spiky) |
   |---|---|---|---|
   | Mint fee | 1 bp | 13.25 bp | 50 bp |
   | Redeem fee | 1 bp | 3.25 bp | 10 bp |
   | Daily mint cap (share of supply, or the bootstrap cap if larger) | 20% | 11% | 2% |
   | Surplus buffer kept before distributing | 0.5% | 2.75% | 5% |
   | Max rebase step | 1 bp | 0.75 bp | 0.5 bp |

7. **Churn budget (`C_DIAM`).** Within a 7-day window, let L be the index's total variation
   (sum of all moves) and D its range (max minus min). A positive rebase is deferred if afterwards
   L > C_DIAM × D. Monotone yield distribution always has L = D, so it is never blocked. With
   equal-sized gains and losses alternating, the third upward step in a window is deferred. Loss
   absorption is never deferred.
8. **Hook.** The hook is restricted to one pool, fixed at construction (`beforeInitialize`
   rejects every other pool). It records the absolute wsUSD leg of each swap.
   - If the oracle call fails with revert data, the hook logs it and the swap proceeds, so the
     oracle can never brick the pool.
   - If the oracle call fails *without* revert data (it ran out of gas), the swap reverts.
     Otherwise a swapper could set a gas limit that starves the call and avoid being recorded.
9. **wsUSD.** sUSD rebases, so a Uniswap v4 `PoolManager` must never hold it:
   - anyone could capture the pool's positive rebases by calling `rebase()` between `sync` and
     `settle`;
   - negative rebases would leave the last LPs short.

   Pools pair wsUSD, an ERC-4626 wrapper over sUSD (the stETH/wstETH pattern), with USDC.

## Verified properties (test suite)

1. FWHT matches the naive Hadamard product (fuzz), is an involution up to 8x, and satisfies Parseval.
2. `lnWad` is within 1 wei of the correctly rounded value for x < 2^60, which covers every
   probability in an entropy computation. It is within 3 wei for any x. The test uses 92
   reference points computed at 80 digits; a bit-exact Python emulation over 300k random inputs
   agrees.
3. Entropy: constant window → 0 and spike → 1, exactly. H stays in [0, 1] for full 256-bit
   inputs. It is exactly invariant under scaling and under dyadic (XOR) time shifts, and it grows
   with whale size. It is within 38 wei of the 80-digit reference.
4. Oracle: per-block aggregation, ring buffer order, dust, saturation, warm-up, staleness and the
   EMA update are each checked. The worst-case write (window close, cold storage) costs about
   50k gas.
5. Token: rebasing accounting, rounding in the reserve's favour, and EIP-2612 permit and EIP-3009
   transfer/receive/cancel from both EOAs and an ERC-1271 smart account. Also checked: replay,
   validity windows, forged or tampered signatures, and value surviving a rebase.
6. Stabilizer: fees, caps, bootstrap, donations, slippage guards, pause scope, bounded rebases,
   buffer, loss absorption (sync, redeem, mint, rebase), an exact churn-budget boundary test
   (1 wei either side), and the unprofitable sandwich.
7. Uniswap v4 integration on a real `PoolManager`:
   - the hook address flags are correct and other pools are rejected;
   - only the PoolManager can call the hook;
   - swaps fill one slot per block and same-block swaps aggregate;
   - calm flow followed by a whale raises the mint fee;
   - a broken oracle does not brick swaps, and starving the oracle of gas reverts the swap.
8. Invariants (256 x 128 by default; CI 1,024 x 256, 262,144 calls each):
   - reserve ≥ supply;
   - share accounting is consistent;
   - balances never exceed supply;
   - everyone can exit at once;
   - redemptions and `sync` never fail unexpectedly;
   - the churn budget holds after every distribution;
   - the mint cap holds.

   After every run, all holders redeem everything (a bank run) and the floor must still hold.

Contract sizes (runtime bytes): Stabilizer 14,404, Token 9,534, Oracle 5,957, wsUSD 5,352,
Hook 3,841, Treasury 3,805. All are under the 24,576-byte limit. Typical gas: mint about 211k
(including the vault deposit), redeem about 126k, rebase about 95k, transfer about 55k.

## Known limitations: read before deploying

1. **C_diam is a conjecture, used only by analogy.** 2 + π/3 ≈ 3.0472 is the conjectured sharp
   length-over-diameter ratio of self-approaching plane curves. The proven bounds are
   3.0472 ≤ C_diam ≤ 3.1356. The churn budget borrows the number as a design constant. No
   stability property follows from the geometry. Any constant around 3 would behave the same.
2. **H is cheap to manipulate.** About 80 equal-sized small swaps push the EMA toward 0, which
   means minimum fees and the maximum mint cap. One large swap in a window pushes it up. This is
   acceptable only because H is bounded to the settings in the table above and never touches the
   backing. Treat H as a heuristic, not a security signal.
3. **Vault risk is the real risk.** Losses, withdrawal limits and share-price manipulation of the
   chosen ERC-4626 vault pass straight through to holders. Pick a vault with:
   - donation-resistant accounting;
   - deep withdrawal liquidity;
   - share prices below 100 asset wei per share wei (rounding is covered by the 1 bp fee floor
     only up to that point).

   If the vault cannot pay, redemptions revert until it can.
4. **Admin powers.** The guardian can pause minting and rebasing indefinitely; redemption and
   loss absorption stay open. `DEFAULT_ADMIN_ROLE` manages the guardian role. Use a multisig.
   Nothing is upgradeable.
5. **Dust.** Redemptions below 1 sUSD revert (`MIN_AMOUNT`), so dust has to be transferred or
   sold.
6. **Gas.** The first swap of each block pays for the oracle's window close (about 50k gas).
   Size gas with `eth_estimateGas`: a fixed-multiplier estimate taken in the wrong block can run
   short, and the swap then reverts with `OracleOutOfGas`.
7. **Not audited, not formally verified, no bug bounty.** The name "USD" and the
   redemption promise may have regulatory consequences; get legal review before any mainnet use.

## Differences from SPCM v2 (legacy)

1. The token now has a reserve and 1:1 redemption. SPCM v2 was explicitly "not a stablecoin" and
   distributed 80% of fees to swappers.
2. Entropy: SPCM v2 used a 64-bin log2 histogram of single swaps, in nats, with a target band
   of 1.8–2.8. This version uses the Walsh spectrum of per-block aggregates, normalised to [0, 1],
   with the semantics described above.
3. The oracle accepts writes only from a hook that is set once (red-team CRITICAL-1 stays closed).
   The hook is restricted to one pool.
4. The legacy `AutonomousTreasury.distribute()` deleted the participant records before paying
   out, then read the payee from the deleted records. Every transfer therefore targeted
   `address(0)`, reverted inside a `try`, and nobody was ever paid. That code is gone.
5. The legacy scripts hard-code Base Sepolia PoolManager `0x05E7…1863`. Uniswap's deployment page
   lists `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`. They also call the old 3-argument
   `initialize`. Phase 3 replaces these scripts.

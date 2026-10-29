# VaultPayRouter security review

> Independent review by a separate Claude Opus 5.5 agent, 2026-10-29. Status: all five fixes below are
> applied (combined patch), the fixed findings' PoCs are replaced by `test/vault/review/RegressionF1-5.t.sol`,
> and the x402 agent and facilitator changes are in (signed asset, retry reuses the unsettled intent,
> permit-deadline check, per-payer failure budget). The paths under /tmp refer to the reviewer's
> scratch copies and are not part of the repository.

**Target.** `src/vault/VaultPayRouter.sol`: 227 lines, sha256 `219c33a8cba3003d7b29bf69bd2fa823235e0239a30a21b9169ec79802f99780`. Built on OpenZeppelin 5.4.0 with solc 0.8.26 (via-IR, Cancun). It is to be deployed on Base mainnet through the CREATE2 deployer, paying from Aave waBasUSDC (StataTokenV2, `0xC768c589647798a6EE01A91FdE98EF2ed046DBD6`) in Circle USDC (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`).

**Scope.**
1. The router itself.
2. The OpenZeppelin code it relies on: SignatureChecker, ECDSA, EIP712, ERC4626, ERC20Permit, ReentrancyGuardTransient and SafeERC20.
3. The deploy script and the existing tests.
4. StataTokenV2 and the Aave pool withdrawal path, read from source.
5. The x402 agent, facilitator and merchant, wherever they decide how intents are signed, verified, retried and settled.

## Verdict

No path lets anyone move a payer's shares or redirect a payment without the payer's signature. Nothing a vault does can reach other payers' funds.

The defects are of two kinds:
1. What a signed intent can still do after the payer considers it dead (F-1).
2. What a facilitator ends up paying for (F-4).

Do not deploy this bytecode. Apply the combined patch below, together with the agent and facilitator changes, then deploy. The patch adds:
1. Cancellation.
2. A permit-deadline guard.
3. Asset binding.
4. An ECDSA-first signature check.
5. An asset-is-share-token guard.

Every one of these changes the init code, and with it the CREATE2 address. The router is immutable, so all of them must land before the single deployment.

## Verification status

1. **PoCs: CI-VERIFIED.** The coordinator reports that CI ran the committed PoCs and all passed:
   - StaleIntent 3/3
   - FacilitatorGrief 2/2
   - AssetNotBound 1/1
   - Eip7702 2/2
   - SelfAssetVault 1/1
   - RefundPaths 2/2

   I reproduced the same 11/11 locally with forge 1.5.1-stable, the version CI pins. The VaultPayRouter suites (unit, invariant and review) gave 37 passed and 1 skipped. The skip is the fork suite, which needs an RPC. That run predates the X402SessionEscrow files (item 6).
2. **RefundPaths is not a finding.** It is a soundness check that passes because the refund branches are correct (surface 4). The other nine tests demonstrate F-1 to F-5. A passing PoC confirms the mechanics; it does not change a severity.
3. **Fixes: verified.** Each diff below was applied to an isolated copy of the project; the repository was not touched. Each copy was run with the full existing VaultPayRouter suite, all PoCs and that finding's regression guard:
   - F-1 alone: 40 passed, 0 failed. The StaleIntent PoCs still pass because they model a payer that never cancels (see F-1).
   - F-2, F-3, F-4 and F-5 alone: exactly that finding's PoC fails, its guard passes, and everything else passes. For F-2 this includes the struct update to the tests and the fork file, which compiles.
   - Combined patch: 41 passed, 1 skipped (fork), 5 failed. The five failures are exactly the PoCs of the fixed findings: AssetNotBound, both Eip7702 tests, the FacilitatorGrief permit test and SelfAssetVault.
   - Every diff applies cleanly to the current file (`patch --dry-run -p1`).
4. **F-3 under real EIP-7702.** Scratch runs under Prague used real `0xef0100 || delegate` designators, both through `vm.etch` and through `vm.signAndAttachDelegation`. They give the same results as the committed PoC:
   - EXTCODESIZE is 23.
   - Without the fix, the payer's own-key signature is refused.
   - With the fix, it pays.
5. **The fork suite was not run here.** This session's egress policy denies `mainnet.base.org` (the proxy returns 403). StataTokenV2 behaviour comes from the aave-dao/aave-v3-origin source at commit `8305565` (2026-09-09). The waBasUSDC proxy may run an older implementation, so CI's fork run is the live-state check.
6. **The repository changed during the review.** All of these were edited by others:
   - `x402/lib/protocol.mjs` changed at 06:37: escrow voucher helpers were added. `PAY_INTENT_FIELDS` and the router's domain are unchanged.
   - `src/vault/X402SessionEscrow.sol` and its tests are new. They are outside this review and unreviewed. The same vault-profile deploy gate compiles and runs them.
   - Every other file cited here predates the review.

## Findings

The IDs match the headers of the committed PoC files. The table is ordered by severity.

| Rank | ID | Severity | Title | Location | PoC (CI-VERIFIED) |
|---|---|---|---|---|---|
| 1 | F-1 | Medium | A signed intent cannot be cancelled; a retried payment is charged twice | `VaultPayRouter.sol:90`, `:140-143`; no cancel entry point | `test/vault/review/StaleIntent.t.sol` (3) |
| 2 | F-4 | Medium | Zero-cost facilitator gas griefing: intents that simulate cleanly and revert once included | `VaultPayRouter.sol:154-160`, `:168`, `:141` | `test/vault/review/FacilitatorGrief.t.sol` (2) |
| 3 | F-2 | Low | The asset is not part of the intent: a payer-controlled vault pays a lookalike after verification | `VaultPayRouter.sol:52-54`, `:68-77`, `:147`, `:95-104` | `test/vault/review/AssetNotBound.t.sol` (1) |
| 4 | F-3 | Low | EIP-7702-delegated EOAs cannot pay with their own key | `VaultPayRouter.sol:141`, via `SignatureChecker.sol:32-38` | `test/vault/review/Eip7702.t.sol` (2) |
| 5 | F-5 | Info | A vault whose asset is its own share token is refunded twice out of stray balance | `VaultPayRouter.sol:162-163`, `:173`, `:179-182` | `test/vault/review/SelfAssetVault.t.sol` (1) |

There is no Critical or High finding.

Byte-exact copies of every patch are in `/tmp/claude-0/-home-claude/c90d58fd-1930-5dd9-a7a1-c28eb862692d/scratchpad/variants/`: `F1.patch`, `F2.patch`, `F3.patch`, `F4.patch`, `F5.patch`, `ALL.patch` and `F2-tests.patch`. Apply them with `patch -p1` from the repository root. If a copy-pasted diff below loses the single space on its blank context lines, use those files.

---

## F-1 (Medium): a signed intent cannot be cancelled, so a retried payment is charged twice

**Location.**
1. `VaultPayRouter.sol:90`: `intentUsed`, which only a successful `pay` writes (line 143).
2. `VaultPayRouter.sol:140-143`: the replay check and the write.
3. Nothing in the contract (lines 124-226) can retire an intent.

The integration makes it reachable:
- `x402/agent.mjs:222` signs a fresh `salt: rand32()` on every attempt.
- `x402/agent.mjs:231-234` requires smart-wallet payers to hold a standing approval.
- `x402/merchant.mjs:141-145` answers 402 after three `settlement_unconfirmed` results.

**Mechanism.**
1. Unless it settles, an intent stays executable by anyone until `validBefore`.
2. A failed settlement leaves it live; NatSpec lines 40-42 say so explicitly.
3. The payer's only levers are revoking the whole router allowance or moving its shares. Either one also stops every legitimate payment, and the next approval brings the stale intent back.

EIP-3009, which x402 builds on, has `cancelAuthorization` for exactly this case.

**Exploit by a malicious merchant.**
1. The agent is a smart wallet with a standing approval. It requests a 0.02 USDC resource and signs intent I1: salt s1, `validBefore` up to 600 s ahead (`agent.mjs:137`).
2. The merchant keeps I1, does not settle it, and answers 402.
3. The agent retries, and `agent.mjs` signs I2 with a fresh salt. The merchant settles I2 and serves the resource.
4. Within the validity window, the merchant calls `pay(I1, sig1, none)` itself.

The agent is charged twice for one request. Its ledger records only settled responses (`agent.mjs:350`), so the budget policy under-counts the spend.

**Benign trigger.**
1. A receipt is lost, and the facilitator returns `settlement_unconfirmed`.
2. The merchant gives up and answers 402.
3. The agent retries with a new salt.
4. The first transaction lands anyway.

The agent pays twice with no malice involved.

**Exposure.**
1. Smart-wallet payers: up to the whole position per stale intent. StataTokenV2's permit is ECDSA-only, so these payers must keep a standing approval.
2. EOA payers: bounded by the leftover allowance, about 1 bp of the last permitted payment. After a 100 USDC payment the leftover is 9,524 shares (about 0.01 USDC). That covers nine stale 0.001 USDC calls, and `agent.mjs:231` attaches no permit to those calls, so they draw on the leftover.

**PoC** (`StaleIntent.t.sol`, CI-VERIFIED).
1. `test_aRetriedPaymentIsChargedTwice`: the merchant ends with twice the price.
2. `test_revokingOnlyPausesAStaleIntent`: after `approve(0)` and a re-approve, the stale intent settles.
3. `test_anEoaLeftoverAllowanceCoversAStaleMicroPayment`: the EOA case.

**Fix.** A cancel scoped to the payer, both direct and gasless; agents hold no ETH. The existing `intentUsed[payer][digest]` layout makes this a write to the caller's own row.

```diff
--- a/src/vault/VaultPayRouter.sol
+++ b/src/vault/VaultPayRouter.sol
@@ -53,6 +53,9 @@
         "PayIntent(address payer,address vault,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
     );
 
+    /// @notice EIP-712 type a payer signs to cancel one of its intents without sending a transaction.
+    bytes32 public constant CANCEL_INTENT_TYPEHASH = keccak256("CancelIntent(address payer,bytes32 digest)");
+
     /// @notice Headroom `sharesToAuthorize` adds on top of today's cost, in basis points.
     uint256 public constant AUTHORIZE_HEADROOM_BPS = 1;
 
@@ -112,6 +115,9 @@
     error SharesAboveCeiling(uint256 needed, uint256 maxShares);
     error ShortWithdrawal(uint256 received, uint256 assets);
 
+    /// @notice `payer` gave up the intent with this digest without paying it.
+    event IntentCancelled(address indexed payer, bytes32 indexed digest);
+
     constructor() EIP712("VaultPayRouter", "1") {}
 
     // ---------------------------------------------------------------------- pay
@@ -185,6 +191,26 @@
         emit PaidFromVault(it.payer, it.payTo, digest, it.vault, it.assets, sharesSpent, sharesBack, assetsBack);
     }
 
+    // ---------------------------------------------------------------------- cancel
+
+    /// @notice Spend `digest` without paying: the caller's intent with this digest can never settle.
+    function cancel(bytes32 digest) external {
+        _cancel(msg.sender, digest);
+    }
+
+    /// @notice The same, gasless: anyone may submit the payer's EIP-712 CancelIntent signature.
+    function cancelWithSignature(address payer, bytes32 digest, bytes calldata signature) external {
+        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(CANCEL_INTENT_TYPEHASH, payer, digest)));
+        if (!SignatureChecker.isValidSignatureNow(payer, hash, signature)) revert InvalidSignature();
+        _cancel(payer, digest);
+    }
+
+    function _cancel(address payer, bytes32 digest) private {
+        if (intentUsed[payer][digest]) revert IntentAlreadyUsed(digest);
+        intentUsed[payer][digest] = true;
+        emit IntentCancelled(payer, digest);
+    }
+
     // ---------------------------------------------------------------------- views
 
     /// @notice The EIP-712 digest the payer signs for `it`.
```

When this is applied together with F-3, `cancelWithSignature` calls `_isValidSignature` (see the combined patch).

**Also required off-chain.** The router change gives the payer the tool; the client has to use it.
1. `x402/agent.mjs` must retry a failed request with the same signed intent. Same digest means it settles at most once.
2. It must sign a new salt only after cancelling the old digest through `cancelWithSignature`, or once the old `validBefore` has passed.
3. Signed but unsettled intents must count against the budget until they settle, expire or are cancelled.

**Regression guard.** Replace the StaleIntent test contract with this guard. After the fix, the original StaleIntent tests still pass because they model a payer that never cancels; keeping them would record the attack as expected behaviour.

How the PoCs are inverted:
1. Insert the cancel step.
2. Where the PoC asserted a second payment, expect `IntentAlreadyUsed(firstDigest)`.
3. Assert the merchant was paid once.

```solidity
contract VaultPayRouterReview_RegressionF1Test is VaultPayRouterReviewFixture {
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("CancelIntent(address payer,bytes32 digest)");
    uint256 internal constant OWNER_PK = 0xC0FFEE;

    function _cancelSig(uint256 pk, address who, bytes32 digest) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(CANCEL_TYPEHASH, who, digest));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", router.domainSeparator(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// StaleIntent.test_aRetriedPaymentIsChargedTwice, inverted: the agent cancels attempt 1
    /// (gasless, submitted by the facilitator) and the merchant can no longer settle it.
    function test_F1_aCancelledAttemptCannotBeSettled() public {
        Mock1271Wallet wallet = new Mock1271Wallet(vm.addr(OWNER_PK));
        _deposit(vault, address(wallet), 100e6);
        vm.prank(vm.addr(OWNER_PK));
        wallet.execute(address(vault), abi.encodeCall(vault.approve, (address(router), type(uint256).max)));
        uint256 price = 20_000;
        VaultPayRouter.PayIntent memory first =
            _intentFor(address(wallet), address(vault), merchant, price, keccak256("attempt 1"));
        bytes memory firstSig = _sign(OWNER_PK, first);
        bytes32 firstDigest = router.intentDigest(first);
        VaultPayRouter.PayIntent memory retry =
            _intentFor(address(wallet), address(vault), merchant, price, keccak256("attempt 2"));
        bytes memory retrySig = _sign(OWNER_PK, retry);
        bytes memory cancelSig = _cancelSig(OWNER_PK, address(wallet), firstDigest);

        vm.prank(facilitator);
        router.cancelWithSignature(address(wallet), firstDigest, cancelSig);
        vm.prank(facilitator);
        router.pay(retry, retrySig, _noPermit());

        vm.warp(vm.getBlockTimestamp() + 30);
        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.IntentAlreadyUsed.selector, firstDigest));
        vm.prank(merchant);
        router.pay(first, firstSig, _noPermit());
        assertEq(usdc.balanceOf(merchant), price, "charged once");
    }

    /// StaleIntent.test_revokingOnlyPausesAStaleIntent, inverted: a cancel survives re-approval.
    function test_F1_aCancelSurvivesReapproval() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory stale =
            _intentFor(payer, address(vault), merchant, 1e6, keccak256("stale"));
        bytes memory staleSig = _sign(PAYER_PK, stale);
        bytes32 digest = router.intentDigest(stale);

        vm.prank(payer);
        router.cancel(digest);
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.IntentAlreadyUsed.selector, digest));
        vm.prank(merchant);
        router.pay(stale, staleSig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 0);
    }

    /// Cancellation is the payer's alone and happens once.
    function test_F1_cancelIsPayerScopedAndOneShot() public {
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("c"));
        bytes32 digest = router.intentDigest(it);
        bytes memory strangers = _cancelSig(0xB0B, payer, digest);
        bytes memory payers = _cancelSig(PAYER_PK, payer, digest);
        address stranger = makeAddr("stranger");

        vm.expectRevert(VaultPayRouter.InvalidSignature.selector);
        router.cancelWithSignature(payer, digest, strangers); // another key

        vm.prank(stranger);
        router.cancel(digest); // writes the stranger's own row only
        assertFalse(router.intentUsed(payer, digest), "a stranger cannot cancel the payer's intent");

        router.cancelWithSignature(payer, digest, payers);
        assertTrue(router.intentUsed(payer, digest));
        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.IntentAlreadyUsed.selector, digest));
        router.cancelWithSignature(payer, digest, payers); // no replay
    }
}
```

---

## F-4 (Medium): zero-cost facilitator gas griefing

**Location.**
1. `VaultPayRouter.sol:154-160` swallows a failed permit, so the payment reverts later, at line 168.
2. `VaultPayRouter.sol:141` accepts ERC-1271 answers that can depend on the block. OZ SignatureChecker forwards all gas to that staticcall.

On the facilitator side:
- `x402/facilitator.mjs:224` checks the permit deadline only as a number.
- `:204-213` checks only the intent's window.
- `:253` and `:410` simulate with `cast call` against `latest` (`x402/lib/cast.mjs:171`).
- `:415` sends.

**Variant A: permit deadline (EOA).**
1. The payer holds shares and no allowance. It signs an intent with `validBefore = now + 60`, which passes `windowError`, and a permit with `deadline = latest.timestamp + 1`.
2. `/verify` and the in-queue re-simulation both run at `latest`. The permit is valid there, and the payment simulates cleanly.
3. The transaction lands one Base block (2 s) later. The permit reverts with `ERC2612ExpiredSignature`, the router swallows it, and `transferFrom` reverts with `ERC20InsufficientAllowance`.
4. Measured: 45,039 gas of execution per attempt. A real transaction adds 21,000 intrinsic gas plus calldata.

The payer pays nothing and the intent stays unused, so it repeats with fresh salts.

**Variant B: block-dependent ERC-1271 (smart wallet or EIP-7702 delegate).**
1. `isValidSignature` returns valid on even blocks. On odd blocks it burns the gas it was given, then refuses.
2. Simulation at `latest` (an even block) pays. Inclusion one block later (odd) reverts with `InvalidSignature`.
3. Measured: 291,310 of a 300,000 gas limit burned per attempt.

**Impact.** No user funds move, but:
1. The facilitator pays for every failed attempt.
2. Each attempt holds the facilitator's single serialized send queue (`facilitator.mjs:133-155`) for a full send-and-receipt round trip, pushing honest settlements toward the 120 s queue timeout.
3. The attacker's cost per attempt is zero.

**PoC** (`FacilitatorGrief.t.sol`, CI-VERIFIED).
1. `test_aPermitExpiringBeforeInclusionBurnsTheSubmittersGas`
2. `test_aWalletKeyedOnBlockParityBurnsTheGasLimit`

**Fix for variant A.** Refuse a permit that can lapse while the intent is still valid. The facilitator's `eth_call` then fails and nothing is sent. The agent is unaffected because it signs `deadline = validBefore` (`agent.mjs:239-242`).

```diff
--- a/src/vault/VaultPayRouter.sol
+++ b/src/vault/VaultPayRouter.sol
@@ -111,6 +111,7 @@
     error InvalidSignature();
     error SharesAboveCeiling(uint256 needed, uint256 maxShares);
     error ShortWithdrawal(uint256 received, uint256 assets);
+    error PermitExpiresBeforeIntent(uint256 deadline, uint256 validBefore);
 
     constructor() EIP712("VaultPayRouter", "1") {}
 
@@ -135,6 +136,11 @@
         if (block.timestamp <= it.validAfter) revert NotYetValid(it.validAfter);
         // slither-disable-next-line timestamp
         if (block.timestamp >= it.validBefore) revert Expired(it.validBefore);
+        // The intent is valid while t <= validBefore - 1, the permit while t <= deadline. A permit
+        // that lapses first turns a clean simulation into a revert the submitter pays for.
+        if (permit.deadline != 0 && permit.deadline < it.validBefore - 1) {
+            revert PermitExpiresBeforeIntent(permit.deadline, it.validBefore);
+        }
 
         bytes32 digest = intentDigest(it);
         if (intentUsed[it.payer][digest]) revert IntentAlreadyUsed(digest);
```

**Variant B has no router-level fix** short of dropping ERC-1271. Before the facilitator accepts payers with code, it needs:
1. A check that `pm.deadline >= it.validBefore - 1` in `checkVault`, as defense in depth for variant A.
2. For a payer with code, a trace of the ERC-1271 staticcall during simulation. Refuse validation that reads NUMBER, TIMESTAMP, GASPRICE, GAS, PREVRANDAO, COINBASE or BLOCKHASH, as ERC-7562 does for ERC-4337 bundlers.
3. Throttling or a ban for a payer, and its code hash, after one on-chain failure.

**Regression guard.** This inverts the permit PoC:
1. The simulation step itself must revert.
2. The agent's convention, `deadline = validBefore`, must still pay.

```solidity
contract VaultPayRouterReview_RegressionF4Test is VaultPayRouterReviewFixture {
    /// FacilitatorGrief.test_aPermitExpiringBeforeInclusionBurnsTheSubmittersGas, inverted: the
    /// facilitator's eth_call already fails, so nothing is sent; deadline = validBefore still pays.
    function test_F4_aPermitExpiringBeforeTheIntentFailsInSimulation() public {
        uint256 t0 = vm.getBlockTimestamp();
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("grief"));
        bytes memory sig = _sign(PAYER_PK, it);
        VaultPayRouter.Permit memory p = _permit(PAYER_PK, vault, it.maxShares, t0 + 1);
        vm.expectRevert(
            abi.encodeWithSelector(VaultPayRouter.PermitExpiresBeforeIntent.selector, t0 + 1, it.validBefore)
        );
        router.pay(it, sig, p);

        p = _permit(PAYER_PK, vault, it.maxShares, it.validBefore);
        router.pay(it, sig, p);
        assertEq(usdc.balanceOf(merchant), 1e6);
    }
}
```

Keep `test_aWalletKeyedOnBlockParityBurnsTheGasLimit` as a documented known limitation. It still passes after the fix (verified).

---

## F-2 (Low): the asset is not part of the intent

**Location.**
1. `VaultPayRouter.sol:52-54` and `:68-77`: the intent names the vault, not the asset.
2. `:147`: the asset is whatever the payer-chosen vault reports at settlement.
3. `:95-104`: `PaidFromVault` has no asset field.

**Exploit.**
1. The payer deploys a 1:1 vault over USDC whose `asset()` it can repoint. It deposits and approves the router.
2. A facilitator checks `asset() == USDC` and simulates the exact call. The simulation shows the merchant receiving USDC.
3. With one storage write, the payer repoints `asset()` to a lookalike token named "USD Coin" with symbol "USDC" and 6 decimals.
4. Settlement succeeds and emits a `PaidFromVault` identical to an honest payment. The merchant receives the lookalike and no USDC; the payer's USDC never moves.

**Reachability.** The attack needs a facilitator that settles for vaults it did not choose.
1. This deployment is not exposed. The in-repo facilitator allowlists vaults (`facilitator.mjs:233`, with only waBasUSDC configured) and checks `asset()` (`:240`).
2. A third-party facilitator that integrates this public, ownerless router generically is exposed.
3. The fix changes the signed schema, so it can only be taken before the immutable deployment.

**PoC.** `AssetNotBound.t.sol::test_aPayerControlledVaultSwapsTheAssetAfterVerification`. CI-VERIFIED.

**Fix.** Bind the asset in the signed intent and check it against the vault at settlement. The balance-delta check at line 174 then runs on the token the payer signed for, so `payTo` is guaranteed that token.

```diff
--- a/src/vault/VaultPayRouter.sol
+++ b/src/vault/VaultPayRouter.sol
@@ -50,7 +50,7 @@
 
     /// @notice EIP-712 type of the payment intent.
     bytes32 public constant PAY_INTENT_TYPEHASH = keccak256(
-        "PayIntent(address payer,address vault,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
+        "PayIntent(address payer,address vault,address asset,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
     );
 
     /// @notice Headroom `sharesToAuthorize` adds on top of today's cost, in basis points.
@@ -58,6 +58,7 @@
 
     /// @param payer       Signer of the intent, and owner of the shares spent.
     /// @param vault       ERC-4626 vault whose shares pay; the price is in `vault.asset()`.
+    /// @param asset       The token `payTo` receives; must be `vault.asset()` when the payment settles.
     /// @param payTo       Recipient of the asset.
     /// @param assets      Exact amount of the asset `payTo` receives.
     /// @param maxShares   Most shares the payment may cost; the payer's protection against a
@@ -68,6 +69,7 @@
     struct PayIntent {
         address payer;
         address vault;
+        address asset;
         address payTo;
         uint256 assets;
         uint256 maxShares;
@@ -111,6 +113,7 @@
     error InvalidSignature();
     error SharesAboveCeiling(uint256 needed, uint256 maxShares);
     error ShortWithdrawal(uint256 received, uint256 assets);
+    error AssetMismatch(address vaultAsset, address signedAsset);
 
     constructor() EIP712("VaultPayRouter", "1") {}
 
@@ -145,6 +148,7 @@
         IERC4626 vault = IERC4626(it.vault);
         IERC20 shares = IERC20(it.vault);
         IERC20 asset = IERC20(vault.asset());
+        if (address(asset) != it.asset) revert AssetMismatch(address(asset), it.asset);
 
         // ERC-4626 requires previewWithdraw to be no fewer than the shares the same withdrawal
         // burns in the same transaction, so taking this many always covers it.
@@ -195,6 +199,7 @@
                     PAY_INTENT_TYPEHASH,
                     it.payer,
                     it.vault,
+                    it.asset,
                     it.payTo,
                     it.assets,
                     it.maxShares,
```

**Companion changes.** The test diff below was verified with the patch:
1. Tests add the field. The diff also adds an asset-tamper case to `test_pay_rejectsEveryTamperedField`.
2. `x402/lib/protocol.mjs`, `PAY_INTENT_FIELDS`: add `{ name: 'asset', type: 'address' }` after `vault`. The facilitator's `INTENT_TYPE` is derived from it.
3. `x402/agent.mjs`, `authorize()`: set `asset: lc(r.asset)`.
4. `x402/facilitator.mjs`, `checkVault`: refuse unless `lc(it.asset) === lc(r.asset)`.

```diff
--- a/test/vault/VaultPayRouter.t.sol
+++ b/test/vault/VaultPayRouter.t.sol
@@ -51,6 +51,7 @@
         return VaultPayRouter.PayIntent({
             payer: payer,
             vault: vault_,
+            asset: address(usdc),
             payTo: payTo,
             assets: assets,
             maxShares: router.sharesToAuthorize(vault_, assets),
@@ -62,7 +63,7 @@
 
     function _copy(VaultPayRouter.PayIntent memory a) internal pure returns (VaultPayRouter.PayIntent memory) {
         return VaultPayRouter.PayIntent(
-            a.payer, a.vault, a.payTo, a.assets, a.maxShares, a.salt, a.validAfter, a.validBefore
+            a.payer, a.vault, a.asset, a.payTo, a.assets, a.maxShares, a.salt, a.validAfter, a.validBefore
         );
     }
 
@@ -193,6 +194,9 @@
         t.vault = address(other);
         _expectInvalidSignature(t, sig);
         t = _copy(signed);
+        t.asset = address(other);
+        _expectInvalidSignature(t, sig);
+        t = _copy(signed);
         t.payer = makeAddr("someone else");
         _expectInvalidSignature(t, sig);
 
@@ -417,10 +421,11 @@
         bytes32 structHash = keccak256(
             abi.encode(
                 keccak256(
-                    "PayIntent(address payer,address vault,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
+                    "PayIntent(address payer,address vault,address asset,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
                 ),
                 it.payer,
                 it.vault,
+                it.asset,
                 it.payTo,
                 it.assets,
                 it.maxShares,
@@ -430,7 +435,7 @@
             )
         );
         assertEq(router.PAY_INTENT_TYPEHASH(), keccak256(
-            "PayIntent(address payer,address vault,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
+            "PayIntent(address payer,address vault,address asset,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
         ));
         assertEq(
             router.intentDigest(it), keccak256(abi.encodePacked("\x19\x01", router.domainSeparator(), structHash))
--- a/test/vault/VaultPayRouterInvariant.t.sol
+++ b/test/vault/VaultPayRouterInvariant.t.sol
@@ -39,6 +39,7 @@
         VaultPayRouter.PayIntent memory it = VaultPayRouter.PayIntent({
             payer: payer,
             vault: address(vault),
+            asset: address(usdc),
             payTo: merchants[who % 3],
             assets: price,
             maxShares: router.sharesToAuthorize(address(vault), price),
--- a/test/vault/VaultPayRouterBaseMainnetFork.t.sol
+++ b/test/vault/VaultPayRouterBaseMainnetFork.t.sol
@@ -112,6 +112,7 @@
         return VaultPayRouter.PayIntent({
             payer: payer,
             vault: WA_BAS_USDC,
+            asset: USDC,
             payTo: payTo,
             assets: assets,
             maxShares: router.sharesToAuthorize(WA_BAS_USDC, assets),
--- a/test/vault/review/ReviewFixture.sol
+++ b/test/vault/review/ReviewFixture.sol
@@ -2,6 +2,7 @@
 pragma solidity ^0.8.26;
 
 import {Test} from "forge-std/Test.sol";
+import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
 
 import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
 import {MockUSDC, MockVault} from "../mocks/VaultMocks.sol";
@@ -54,6 +55,7 @@
         return VaultPayRouter.PayIntent({
             payer: who,
             vault: vault_,
+            asset: IERC4626(vault_).asset(),
             payTo: payTo,
             assets: assets,
             maxShares: router.sharesToAuthorize(vault_, assets),
```

**Regression guard.** This inverts the PoC:
1. Settlement after the swap must revert with `AssetMismatch(lookalike, usdc)`, deliver nothing, and leave the intent unused.
2. Once the vault is repointed back, the same intent pays USDC.

```solidity
contract VaultPayRouterReview_RegressionF2Test is VaultPayRouterReviewFixture {
    function test_F2_anAssetSwapAfterSigningReverts() public {
        MockUSDC lookalike = new MockUSDC();
        AssetSwitchVault hv = new AssetSwitchVault(usdc, lookalike, payer);
        usdc.mint(payer, 10e6);
        vm.startPrank(payer);
        usdc.approve(address(hv), 10e6);
        hv.deposit(10e6, payer);
        hv.approve(address(router), type(uint256).max);
        vm.stopPrank();

        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(hv), merchant, 1e6, keccak256("swap"));
        assertEq(it.asset, address(usdc), "the payer signs for USDC");
        bytes memory sig = _sign(PAYER_PK, it);
        bytes32 digest = router.intentDigest(it);

        vm.prank(payer);
        hv.setReported(address(lookalike));
        vm.expectRevert(
            abi.encodeWithSelector(VaultPayRouter.AssetMismatch.selector, address(lookalike), address(usdc))
        );
        router.pay(it, sig, _noPermit());
        assertEq(lookalike.balanceOf(merchant), 0, "no lookalike delivered");
        assertFalse(router.intentUsed(payer, digest), "nothing settled");

        // Pointed back at USDC, the same intent pays USDC, as signed.
        vm.prank(payer);
        hv.setReported(address(usdc));
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6);
    }
}
```

---

## F-3 (Low): EIP-7702-delegated EOAs cannot pay with their own key

**Location.** `VaultPayRouter.sol:141`, through `lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol:32-38`. That function sends every signer with code to ERC-1271 and never tries ECDSA.

**Mechanism.** An EIP-7702 account has code: the designator `0xef0100 || delegate`, with EXTCODESIZE 23. Base supports EIP-7702.
1. If the delegate has no ERC-1271 (a batch executor, for example), the payer cannot pay at all.
2. If the delegate implements ERC-1271 over ERC-7739-style wrapped hashes, it refuses the plain EIP-712 signature that `agent.mjs` produces.
3. An intent signed before delegating stops working. Clearing the delegation brings it back while it is still in its window.

**Does the ERC-1271 path open anything?** No.
1. The ERC-1271 path only accepts what the delegate already authorizes.
2. The fix cannot open anything either: no private key exists for a contract address, and a 7702 EOA's own key already controls the account.

**PoC** (`Eip7702.t.sol`, CI-VERIFIED, and confirmed under Prague with real designators; see Verification status, item 4).
1. `test_aDelegatedEoaCannotPayWithItsOwnKey`
2. `test_aWrappingDelegateNeedsADifferentSignature`

**Fix.** ECDSA first, then ERC-1271 for a signer with code.

```diff
--- a/src/vault/VaultPayRouter.sol
+++ b/src/vault/VaultPayRouter.sol
@@ -7,6 +7,7 @@
 import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
 import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
 import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
+import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
 import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
 import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
 
@@ -138,7 +139,7 @@
 
         bytes32 digest = intentDigest(it);
         if (intentUsed[it.payer][digest]) revert IntentAlreadyUsed(digest);
-        if (!SignatureChecker.isValidSignatureNow(it.payer, digest, signature)) revert InvalidSignature();
+        if (!_isValidSignature(it.payer, digest, signature)) revert InvalidSignature();
         // Spent before any external call: a reentrant or repeated submission finds it used.
         intentUsed[it.payer][digest] = true;
 
@@ -185,6 +186,19 @@
         emit PaidFromVault(it.payer, it.payTo, digest, it.vault, it.assets, sharesSpent, sharesBack, assetsBack);
     }
 
+    /// @dev ECDSA first, then ERC-1271 for a signer with code. A contract address has no private
+    ///      key, so the ECDSA branch only ever accepts an EOA, including one delegated under
+    ///      EIP-7702, whose own key already controls the account.
+    function _isValidSignature(address signer, bytes32 hash, bytes calldata signature)
+        private
+        view
+        returns (bool)
+    {
+        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
+        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
+        return signer.code.length != 0 && SignatureChecker.isValidERC1271SignatureNow(signer, hash, signature);
+    }
+
     // ---------------------------------------------------------------------- views
 
     /// @notice The EIP-712 digest the payer signs for `it`.
```

**Regression guard.** This inverts both PoCs:
1. Both drop `expectRevert` and assert that the payment goes through.
2. A third test pins that a contract wallet still rejects a stranger's key.

```solidity
contract VaultPayRouterReview_RegressionF3Test is VaultPayRouterReviewFixture {
    uint256 internal constant OWNER_PK = 0xC0FFEE;

    /// Eip7702.test_aDelegatedEoaCannotPayWithItsOwnKey, inverted.
    function test_F3_aDelegatedEoaPaysWithItsOwnKey() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("7702"));
        bytes memory sig = _sign(PAYER_PK, it);
        vm.etch(payer, address(new BatchDelegate()).code);
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    /// Eip7702.test_aWrappingDelegateNeedsADifferentSignature, inverted: the plain signature pays.
    function test_F3_aWrappingDelegatePaysWithThePlainSignature() public {
        vm.prank(payer);
        vault.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(vault), merchant, 1e6, keccak256("7739"));
        bytes memory sig = _sign(PAYER_PK, it);
        vm.etch(payer, address(new WrappingDelegate()).code);
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6);
    }

    /// The ECDSA branch opens nothing for contract wallets: a stranger's key still fails.
    function test_F3_aContractWalletStillRejectsAStrangersKey() public {
        Mock1271Wallet wallet = new Mock1271Wallet(vm.addr(OWNER_PK));
        _deposit(vault, address(wallet), 100e6);
        vm.prank(vm.addr(OWNER_PK));
        wallet.execute(address(vault), abi.encodeCall(vault.approve, (address(router), type(uint256).max)));
        VaultPayRouter.PayIntent memory it =
            _intentFor(address(wallet), address(vault), merchant, 1e6, keccak256("stranger"));
        bytes memory strangers = _sign(0xB0B, it);
        vm.expectRevert(VaultPayRouter.InvalidSignature.selector);
        router.pay(it, strangers, _noPermit());
    }
}
```

---

## F-5 (Info): a self-referential vault is refunded twice out of stray balance

**Location.** `VaultPayRouter.sol:162-163`, `:173` and `:179-182`.

**Mechanism.** When `asset() == vault`:
1. `sharesBefore` and `assetsBefore` read the same balance.
2. `sharesBack` and `assetsBack` measure the same surplus.
3. The payer is refunded twice, and the second refund comes out of tokens someone else left in the router.

NatSpec lines 45-47 ("no payer ever receives tokens that someone else sent here") are false for this class of vault.

**Exploit.**
1. Take a SELF token whose `asset()` is itself, with `previewWithdraw(a) = 2a` and a `withdraw` that does nothing.
2. Someone leaves 5 SELF in the router.
3. A payer holding 2 SELF pays 1 SELF.
4. The merchant receives 1 SELF, the payer still holds 2, and the router is down to 4.

**Impact.** Only stray balances of a self-referential token are reachable, and such a token is the attacker's own. No realistic value is at risk.

**PoC.** `SelfAssetVault.t.sol::test_aSelfReferentialVaultIsRefundedTwiceFromStrayBalance`. CI-VERIFIED.

**Fix.**

```diff
--- a/src/vault/VaultPayRouter.sol
+++ b/src/vault/VaultPayRouter.sol
@@ -111,6 +111,7 @@
     error InvalidSignature();
     error SharesAboveCeiling(uint256 needed, uint256 maxShares);
     error ShortWithdrawal(uint256 received, uint256 assets);
+    error AssetIsShareToken(address vault);
 
     constructor() EIP712("VaultPayRouter", "1") {}
 
@@ -145,6 +146,7 @@
         IERC4626 vault = IERC4626(it.vault);
         IERC20 shares = IERC20(it.vault);
         IERC20 asset = IERC20(vault.asset());
+        if (address(asset) == it.vault) revert AssetIsShareToken(it.vault);
 
         // ERC-4626 requires previewWithdraw to be no fewer than the shares the same withdrawal
         // burns in the same transaction, so taking this many always covers it.
```

**Regression guard.** This inverts the PoC: the payment must revert with `AssetIsShareToken(sv)`, and the stray tokens stay where they are.

```solidity
contract VaultPayRouterReview_RegressionF5Test is VaultPayRouterReviewFixture {
    /// SelfAssetVault.test_aSelfReferentialVaultIsRefundedTwiceFromStrayBalance, inverted.
    function test_F5_aSelfReferentialVaultIsRefused() public {
        SelfAssetVault sv = new SelfAssetVault();
        address someoneElse = makeAddr("someone else");
        sv.mint(someoneElse, 5e6);
        vm.prank(someoneElse);
        require(sv.transfer(address(router), 5e6), "transfer failed");
        sv.mint(payer, 2e6);
        vm.prank(payer);
        sv.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory it = _intentFor(payer, address(sv), merchant, 1e6, keccak256("self"));
        bytes memory sig = _sign(PAYER_PK, it);

        vm.expectRevert(abi.encodeWithSelector(VaultPayRouter.AssetIsShareToken.selector, address(sv)));
        router.pay(it, sig, _noPermit());
        assertEq(sv.balanceOf(address(router)), 5e6, "stray tokens untouched");
    }
}
```

---

## Combined patch (verified)

Each per-finding diff above applies on its own to the current file. To take all of them, use this single patch instead; in it, F-1's `cancelWithSignature` calls F-3's helper. Together with the F-2 test diff, forge 1.5.1 reports:
- 41 passed
- 1 skipped (fork)
- 5 failed: exactly the PoCs listed in Verification status, item 3

```diff
--- a/src/vault/VaultPayRouter.sol
+++ b/src/vault/VaultPayRouter.sol
@@ -7,6 +7,7 @@
 import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
 import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
 import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
+import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
 import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
 import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
 
@@ -50,14 +51,18 @@
 
     /// @notice EIP-712 type of the payment intent.
     bytes32 public constant PAY_INTENT_TYPEHASH = keccak256(
-        "PayIntent(address payer,address vault,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
+        "PayIntent(address payer,address vault,address asset,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
     );
 
+    /// @notice EIP-712 type a payer signs to cancel one of its intents without sending a transaction.
+    bytes32 public constant CANCEL_INTENT_TYPEHASH = keccak256("CancelIntent(address payer,bytes32 digest)");
+
     /// @notice Headroom `sharesToAuthorize` adds on top of today's cost, in basis points.
     uint256 public constant AUTHORIZE_HEADROOM_BPS = 1;
 
     /// @param payer       Signer of the intent, and owner of the shares spent.
     /// @param vault       ERC-4626 vault whose shares pay; the price is in `vault.asset()`.
+    /// @param asset       The token `payTo` receives; must be `vault.asset()` when the payment settles.
     /// @param payTo       Recipient of the asset.
     /// @param assets      Exact amount of the asset `payTo` receives.
     /// @param maxShares   Most shares the payment may cost; the payer's protection against a
@@ -68,6 +73,7 @@
     struct PayIntent {
         address payer;
         address vault;
+        address asset;
         address payTo;
         uint256 assets;
         uint256 maxShares;
@@ -111,6 +117,12 @@
     error InvalidSignature();
     error SharesAboveCeiling(uint256 needed, uint256 maxShares);
     error ShortWithdrawal(uint256 received, uint256 assets);
+    error AssetIsShareToken(address vault);
+    error PermitExpiresBeforeIntent(uint256 deadline, uint256 validBefore);
+    error AssetMismatch(address vaultAsset, address signedAsset);
+
+    /// @notice `payer` gave up the intent with this digest without paying it.
+    event IntentCancelled(address indexed payer, bytes32 indexed digest);
 
     constructor() EIP712("VaultPayRouter", "1") {}
 
@@ -135,16 +147,23 @@
         if (block.timestamp <= it.validAfter) revert NotYetValid(it.validAfter);
         // slither-disable-next-line timestamp
         if (block.timestamp >= it.validBefore) revert Expired(it.validBefore);
+        // The intent is valid while t <= validBefore - 1, the permit while t <= deadline. A permit
+        // that lapses first turns a clean simulation into a revert the submitter pays for.
+        if (permit.deadline != 0 && permit.deadline < it.validBefore - 1) {
+            revert PermitExpiresBeforeIntent(permit.deadline, it.validBefore);
+        }
 
         bytes32 digest = intentDigest(it);
         if (intentUsed[it.payer][digest]) revert IntentAlreadyUsed(digest);
-        if (!SignatureChecker.isValidSignatureNow(it.payer, digest, signature)) revert InvalidSignature();
+        if (!_isValidSignature(it.payer, digest, signature)) revert InvalidSignature();
         // Spent before any external call: a reentrant or repeated submission finds it used.
         intentUsed[it.payer][digest] = true;
 
         IERC4626 vault = IERC4626(it.vault);
         IERC20 shares = IERC20(it.vault);
         IERC20 asset = IERC20(vault.asset());
+        if (address(asset) == it.vault) revert AssetIsShareToken(it.vault);
+        if (address(asset) != it.asset) revert AssetMismatch(address(asset), it.asset);
 
         // ERC-4626 requires previewWithdraw to be no fewer than the shares the same withdrawal
         // burns in the same transaction, so taking this many always covers it.
@@ -185,6 +204,39 @@
         emit PaidFromVault(it.payer, it.payTo, digest, it.vault, it.assets, sharesSpent, sharesBack, assetsBack);
     }
 
+    /// @dev ECDSA first, then ERC-1271 for a signer with code. A contract address has no private
+    ///      key, so the ECDSA branch only ever accepts an EOA, including one delegated under
+    ///      EIP-7702, whose own key already controls the account.
+    function _isValidSignature(address signer, bytes32 hash, bytes calldata signature)
+        private
+        view
+        returns (bool)
+    {
+        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
+        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
+        return signer.code.length != 0 && SignatureChecker.isValidERC1271SignatureNow(signer, hash, signature);
+    }
+
+    // ---------------------------------------------------------------------- cancel
+
+    /// @notice Spend `digest` without paying: the caller's intent with this digest can never settle.
+    function cancel(bytes32 digest) external {
+        _cancel(msg.sender, digest);
+    }
+
+    /// @notice The same, gasless: anyone may submit the payer's EIP-712 CancelIntent signature.
+    function cancelWithSignature(address payer, bytes32 digest, bytes calldata signature) external {
+        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(CANCEL_INTENT_TYPEHASH, payer, digest)));
+        if (!_isValidSignature(payer, hash, signature)) revert InvalidSignature();
+        _cancel(payer, digest);
+    }
+
+    function _cancel(address payer, bytes32 digest) private {
+        if (intentUsed[payer][digest]) revert IntentAlreadyUsed(digest);
+        intentUsed[payer][digest] = true;
+        emit IntentCancelled(payer, digest);
+    }
+
     // ---------------------------------------------------------------------- views
 
     /// @notice The EIP-712 digest the payer signs for `it`.
@@ -195,6 +247,7 @@
                     PAY_INTENT_TYPEHASH,
                     it.payer,
                     it.vault,
+                    it.asset,
                     it.payTo,
                     it.assets,
                     it.maxShares,
```

**Where the guards go.** Each guard above is a complete contract.
1. Put each one in `test/vault/review/RegressionF<n>.t.sol`, under the header below, in the same change that applies the fix.
2. The guards import the helper contracts from the PoC files. Keep those helpers (`AssetSwitchVault`, `BatchDelegate`, `WrappingDelegate`, `SelfAssetVault`, `ParityWallet`) and remove only the PoC test contracts named in the Deploy-gate note.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {Mock1271Wallet, MockUSDC} from "../mocks/VaultMocks.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";
import {AssetSwitchVault} from "./AssetNotBound.t.sol";
import {BatchDelegate, WrappingDelegate} from "./Eip7702.t.sol";
import {SelfAssetVault} from "./SelfAssetVault.t.sol";
```

## Deploy-gate note

The committed PoCs live under `test/vault`. The gate in `.github/workflows/deploy-vault-rail-mainnet.yml:61-65` runs `FOUNDRY_PROFILE=vault forge test`, so it runs them.

1. Today they pass, so they do not block a deploy of the unfixed router.
2. After the fix, five PoC tests fail by design (verified):
   - `VaultPayRouterReview_AssetNotBoundTest`
   - `VaultPayRouterReview_Eip7702Test` (both tests)
   - the permit test in `VaultPayRouterReview_FacilitatorGriefTest`
   - `VaultPayRouterReview_SelfAssetVaultTest`

   Replace them with the guards in the same change, or the gate blocks.
3. `VaultPayRouterReview_StaleIntentTest` keeps passing after the fix. Replace it with the F-1 guard.
4. Keep `VaultPayRouterReview_RefundPathsTest` (soundness) and `test_aWalletKeyedOnBlockParityBurnsTheGasLimit` (a known limitation).
5. The fixes change the init code, and with it the CREATE2 address. In one change, update:
   - `deployments/`
   - the router address in `config/`
   - the agent's and facilitator's router address
   - the x402 signing schema (F-2)

## Surface-by-surface conclusions

### 1. Authorisation: sound, apart from F-1 and F-3
1. The typehash string matches the struct and the `abi.encode` order field for field (lines 52-54, 68-77 and 194-204). All members are static types with canonical names, and the string contains no spaces. The JS signer (`x402/lib/protocol.mjs`, `PAY_INTENT_FIELDS`) uses the same order and domain.
2. The domain is name, version, chainId and verifyingContract. OZ EIP712 rebuilds the separator if the chain id changes.
3. Replay is blocked across:
   - payers: payer is in the struct and in the signer check;
   - chains: chainId is in the domain, even though the CREATE2 address is the same everywhere;
   - routers: verifyingContract is in the domain;
   - vaults: vault is in the struct.

   Existing tests cover every tampered field.
4. The replay key is the digest, not the signature, so signature malleability cannot replay a payment. OZ also rejects high-s and any v outside {27, 28}.
5. `payer = address(0)` cannot validate, because tryRecover never returns 0 without an error. `payer = router` cannot either: the router has no `isValidSignature` and no fallback.
6. ABI decoding of the calldata struct rejects dirty address bits.
7. ERC-1271 signatures bind to the digest, which includes `payer`. A raw-ECDSA wallet's signature therefore cannot be replayed onto another account of the same owner.

### 2. Permit: sound
1. Owner is fixed to `it.payer` and spender to `address(this)`. Only a permit the payer signed for this router on this vault can run. A front-run only sets the same allowance early (an existing test covers this).
2. A permit for another spender or another value fails the vault's signature check and is swallowed. The share transfer then decides the outcome.
3. Nobody can use a leftover allowance:
   - The only `transferFrom` (line 168) uses `from = it.payer`, behind a verified intent from that payer.
   - Nothing else spends allowances.
   - A hostile vault can neither reenter `pay` nor act as the router.
4. Notes:
   - A permit in the payload overwrites a standing allowance; it does not add to it.
   - Concurrent payments that each carry a permit share one nonce, so only the first permit applies. This is a liveness issue only.
   - The leftover allowance is what extends F-1 to EOAs.
   - The deadline is F-4.

### 3. Hostile vaults: harm stays with the payer who chose the vault, apart from F-2, F-4 and F-5
1. Other payers' funds are unreachable, because `from` is always the signer.
2. Stray balances in the router are unreachable through the balance deltas. The checked subtraction at line 179 reverts an over-burn (existing OverburnVault test). F-5 is the aliasing exception.
3. Reentrancy into `pay` is blocked by the transient guard (existing test). `asset()`, `previewWithdraw` and `balanceOf` are staticcalls.
4. A withdraw that delivers more than asked, and a `previewWithdraw` that over-quotes, are both refunded to the payer (RefundPaths).
5. These all revert, through the vault's own balance check or the checked subtractions at lines 179 and 184:
   - under-quoting;
   - fee-on-transfer shares;
   - a vault that credits shares to the router during withdraw.
6. `asset()` is read once per call. Changing it between verification and settlement is F-2.
7. While a hostile vault's code runs, `tx.origin` is the facilitator's key. That key must not authorize anything through `tx.origin`; the facilitator's vault allowlist also covers this.

### 4. Accounting: sound whenever the asset is not the share token
1. `needed = previewWithdraw` rounds up, as ERC-4626 requires, so it covers the burn.
2. `sharesSpent = needed - sharesBack`, which is at most `needed`, which is at most `maxShares`. The return value and all event fields are exact, including when the router holds stray balances. An existing test covers strays. RefundPaths covers non-zero refunds, which no existing test reached.
3. Tokens sent to the router by mistake cannot be recovered. This is by design: there is no owner and no sweep.

### 5. waBasUSDC (StataTokenV2): no assumption broken
1. Settlement is exact, so `sharesBack = assetsBack = 0`:
   - `withdraw` burns exactly `previewWithdraw(assets)`, using the same function at the same rate within the transaction.
   - The rate is `getReserveNormalizedIncome`. It depends on `block.timestamp` and on reserve storage, and nothing between the router's preview and the vault's withdraw touches either.
   - `Pool.withdraw` delivers exactly `assets` USDC (`SupplyLogic.executeWithdraw` sets `amountToWithdraw = params.amount`).
2. `maxWithdraw(router) = floor(needed * rate / RAY)`, which is at least `assets` because `needed = ceil(assets * RAY / rate)`.
3. The rate never decreases, so a signed `maxShares` never falls short over time. The 1 bp headroom covers rounding.
4. Three conditions make `pay` revert cleanly. In each case the intent stays live and can settle once the condition clears (F-1):
   - pausing: StataTokenV2's `_update` is `whenNotPaused`, controlled by EMERGENCY_ADMIN;
   - an inactive or paused reserve: `maxRedeem` returns 0;
   - low liquidity, measured by the reserve's virtual balance.
5. The permit is OZ `ERC20PermitUpgradeable`, which accepts ECDSA only. Smart wallets must therefore approve, and that is what makes F-1 unbounded for them.
6. Other properties:
   - Rescue, by the ACL admin, reaches only the StataToken's own excess.
   - The rewards hook accrues nothing to the router, because the timestamp does not move within the transaction.
   - waBasUSDC and USDC are both upgradeable.
   - A USDC blacklist on `payTo` or on the router makes payments revert.

### 6. Facilitator DoS: F-4, plus limits inherent to pull payments
1. Front-running `pay` with the same intent costs the front-runner a full payment. The facilitator only pays for an early `IntentAlreadyUsed` revert, so this is not a grief.
2. Tricks with the validity window are closed by `windowError` (`validBefore >= now + 7`) and the in-queue re-simulation.
3. Two griefs are inherent to pull payments:
   - one `approve(router, 0)` invalidates every in-flight intent of a payer;
   - a double-spend of the same shares across facilitators makes all settlements but one revert.

   Per-payer failure throttling bounds both.

### 7. Deployment: sound
1. The CREATE2 address commits to the init code. The constructor takes no arguments and assigns no roles, so whoever deploys first deploys the identical ownerless contract. Front-running or squatting the address is therefore harmless.
2. The script is idempotent: it checks for existing code, checks the address, and checks the domain separator.
3. The EIP-712 immutables come from the CREATE2 address and the chain id at construction. The router has the same address on every chain and a distinct domain on each.
4. `bytecode_hash = "none"` makes the init code reproducible. The Cancun opcodes it uses (TLOAD/TSTORE) are live on Base.
5. The deploy key holds no role afterwards. `deploy-vault-rail-mainnet.yml:9-10` reuses one key on every chain; that matters for the facilitator and merchant roles the key also plays in that run, not for the router.

## Appendix: reproduction

1. PoCs against the current router. Build output goes to a scratch directory, so the repository stays untouched:
   ```
   FOUNDRY_PROFILE=vault forge test --offline --match-path 'test/vault/review/*' -vv --out <scratch>/out --cache-path <scratch>/cache
   ```
2. Fix verification, all outside the repository:
   - Variant routers and patches: `/tmp/claude-0/-home-claude/c90d58fd-1930-5dd9-a7a1-c28eb862692d/scratchpad/variants/`
   - Regression guard files: `/tmp/claude-0/-home-claude/c90d58fd-1930-5dd9-a7a1-c28eb862692d/scratchpad/regress/`
   - Variant generator: `/tmp/claude-0/-home-claude/c90d58fd-1930-5dd9-a7a1-c28eb862692d/scratchpad/scripts/make_variants.py`
   - Runner: `/tmp/claude-0/-home-claude/c90d58fd-1930-5dd9-a7a1-c28eb862692d/scratchpad/scripts/verify.sh`
   - Run logs: `/tmp/claude-0/-home-claude/c90d58fd-1930-5dd9-a7a1-c28eb862692d/scratchpad/verify/`

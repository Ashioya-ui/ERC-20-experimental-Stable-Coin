// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title  VaultPayRouter
/// @notice Pays an exact price in a vault's underlying asset out of the payer's ERC-4626 shares,
///         in one transaction, gasless for the payer. An agent keeps its working balance in a
///         yield-bearing vault -- on Base, Aave's waBasUSDC, which holds USDC -- and a merchant
///         prices an API in USDC. The agent signs one payment intent and anyone, normally an x402
///         facilitator, submits it here. The router takes exactly the shares the price costs,
///         withdraws exactly the price, pays the merchant, and returns everything else to the
///         payer, in the same transaction.
///
///         Issues nothing. The router mints no token and holds no reserve. The yield belongs to
///         the vault and is earned on shares the payer already owns; the router only turns the
///         payer's own shares into a payment the payer signed for.
///
/// @dev    Authorisation is up to two signatures from the payer, both made off-chain.
///
///         The PayIntent (EIP-712, this contract's domain) names the vault, the recipient, the
///         exact amount, a ceiling on the shares it may cost, a salt and a validity window. It is
///         what binds the payment: a submitter who changes any field changes the digest and the
///         signature no longer verifies. EOAs and ERC-1271 smart wallets can both sign it.
///
///         The permit (EIP-2612, on the vault's shares) is optional and grants this router an
///         allowance. It runs inside a try/catch because anyone can front-run a public permit,
///         and doing so only sets the same allowance early; a failed permit is not a failed
///         payment. A wallet that has already approved the router sends no permit (deadline 0).
///         An allowance on its own moves nothing: shares leave the payer only through `pay`, and
///         `pay` only acts on an intent the payer signed, and only once.
///
///         All or nothing. If the intent is invalid, used, early or expired, if the price costs
///         more shares than the ceiling allows, if the payer lacks the shares or the allowance,
///         or if the vault cannot pay out, the transaction reverts and the intent stays unused.
///
///         Nothing to trust. No owner, no settings, no fee, no upgrade path. The router holds
///         nothing between calls. A payment's leftovers go back to that payment's payer, measured
///         as balance changes across the call, so no payer ever receives tokens that someone else
///         sent here.
contract VaultPayRouter is EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice EIP-712 type of the payment intent.
    bytes32 public constant PAY_INTENT_TYPEHASH = keccak256(
        "PayIntent(address payer,address vault,address asset,address payTo,uint256 assets,uint256 maxShares,bytes32 salt,uint256 validAfter,uint256 validBefore)"
    );

    /// @notice EIP-712 type a payer signs to cancel one of its intents without sending a transaction.
    bytes32 public constant CANCEL_INTENT_TYPEHASH = keccak256("CancelIntent(address payer,bytes32 digest)");

    /// @notice Headroom `sharesToAuthorize` adds on top of today's cost, in basis points.
    uint256 public constant AUTHORIZE_HEADROOM_BPS = 1;

    /// @param payer       Signer of the intent, and owner of the shares spent.
    /// @param vault       ERC-4626 vault whose shares pay; the price is in `vault.asset()`.
    /// @param asset       The token `payTo` receives; must be `vault.asset()` when the payment settles.
    /// @param payTo       Recipient of the asset.
    /// @param assets      Exact amount of the asset `payTo` receives.
    /// @param maxShares   Most shares the payment may cost; the payer's protection against a
    ///                    share-price move between signing and settlement.
    /// @param salt        The payer's random salt, so identical payments have distinct intents.
    /// @param validAfter  Valid strictly after this timestamp.
    /// @param validBefore Valid strictly before this timestamp.
    struct PayIntent {
        address payer;
        address vault;
        address asset;
        address payTo;
        uint256 assets;
        uint256 maxShares;
        bytes32 salt;
        uint256 validAfter;
        uint256 validBefore;
    }

    /// @notice An EIP-2612 permit on the vault's shares, granting this router `value`.
    ///         `deadline` 0 means none: the existing allowance is used.
    struct Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Whether `payer` has already spent the intent with this digest.
    mapping(address payer => mapping(bytes32 digest => bool)) public intentUsed;

    /// @param sharesSpent    Shares the payment cost the payer.
    /// @param sharesReturned Shares taken but not needed, returned to the payer.
    /// @param assetsReturned Asset delivered beyond the price by the vault, returned to the payer.
    event PaidFromVault(
        address indexed payer,
        address indexed payTo,
        bytes32 indexed digest,
        address vault,
        uint256 assets,
        uint256 sharesSpent,
        uint256 sharesReturned,
        uint256 assetsReturned
    );

    error ZeroAmount();
    error InvalidPayTo(address payTo);
    error NotYetValid(uint256 validAfter);
    error Expired(uint256 validBefore);
    error IntentAlreadyUsed(bytes32 digest);
    error InvalidSignature();
    error SharesAboveCeiling(uint256 needed, uint256 maxShares);
    error ShortWithdrawal(uint256 received, uint256 assets);
    error AssetIsShareToken(address vault);
    error PermitExpiresBeforeIntent(uint256 deadline, uint256 validBefore);
    error AssetMismatch(address vaultAsset, address signedAsset);

    /// @notice `payer` gave up the intent with this digest without paying it.
    event IntentCancelled(address indexed payer, bytes32 indexed digest);

    constructor() EIP712("VaultPayRouter", "1") {}

    // ---------------------------------------------------------------------- pay

    /// @notice Pay `it.assets` of the vault's asset to `it.payTo` out of `it.payer`'s shares.
    /// @param  it        The payer's intent.
    /// @param  signature The payer's EIP-712 signature of `it` (65-byte ECDSA, or ERC-1271 data).
    /// @param  permit    An optional permit on the vault's shares; deadline 0 for none.
    /// @return sharesSpent Shares the payment cost the payer.
    function pay(PayIntent calldata it, bytes calldata signature, Permit calldata permit)
        external
        nonReentrant
        returns (uint256 sharesSpent)
    {
        if (it.assets == 0) revert ZeroAmount();
        if (it.payTo == address(0) || it.payTo == address(this) || it.payTo == it.vault) {
            revert InvalidPayTo(it.payTo);
        }
        // EIP-3009's window, which x402 already uses: strictly after, strictly before.
        // slither-disable-next-line timestamp
        if (block.timestamp <= it.validAfter) revert NotYetValid(it.validAfter);
        // slither-disable-next-line timestamp
        if (block.timestamp >= it.validBefore) revert Expired(it.validBefore);
        // The intent is valid while t <= validBefore - 1, the permit while t <= deadline. A permit
        // that lapses first turns a clean simulation into a revert the submitter pays for.
        if (permit.deadline != 0 && permit.deadline < it.validBefore - 1) {
            revert PermitExpiresBeforeIntent(permit.deadline, it.validBefore);
        }

        bytes32 digest = intentDigest(it);
        if (intentUsed[it.payer][digest]) revert IntentAlreadyUsed(digest);
        if (!_isValidSignature(it.payer, digest, signature)) revert InvalidSignature();
        // Spent before any external call: a reentrant or repeated submission finds it used.
        intentUsed[it.payer][digest] = true;

        IERC4626 vault = IERC4626(it.vault);
        IERC20 shares = IERC20(it.vault);
        IERC20 asset = IERC20(vault.asset());
        if (address(asset) == it.vault) revert AssetIsShareToken(it.vault);
        if (address(asset) != it.asset) revert AssetMismatch(address(asset), it.asset);

        // ERC-4626 requires previewWithdraw to be no fewer than the shares the same withdrawal
        // burns in the same transaction, so taking this many always covers it.
        uint256 needed = vault.previewWithdraw(it.assets);
        if (needed > it.maxShares) revert SharesAboveCeiling(needed, it.maxShares);

        if (permit.deadline != 0) {
            // Anyone may submit a public permit first; that sets the same allowance early and
            // makes this call revert. Either way the transfer below is what decides.
            try IERC20Permit(it.vault).permit(
                it.payer, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s
            ) {} catch {}
        }

        uint256 sharesBefore = shares.balanceOf(address(this));
        uint256 assetsBefore = asset.balanceOf(address(this));

        // `it.payer` is not caller-chosen in effect: the intent signature verified above proves
        // the payer authorised this exact payment, once.
        // slither-disable-next-line arbitrary-send-erc20,arbitrary-send-erc20-permit
        shares.safeTransferFrom(it.payer, address(this), needed);
        // The vault's return value is not trusted; the balance changes below are.
        // slither-disable-next-line unused-return
        vault.withdraw(it.assets, address(this), address(this));

        uint256 received = asset.balanceOf(address(this)) - assetsBefore;
        if (received < it.assets) revert ShortWithdrawal(received, it.assets);
        asset.safeTransfer(it.payTo, it.assets);

        // Checked subtraction: a vault that burned more than this payment brought in reverts the
        // whole payment and cannot reach shares that were here before it.
        uint256 sharesBack = shares.balanceOf(address(this)) - sharesBefore;
        uint256 assetsBack = received - it.assets;
        if (sharesBack > 0) shares.safeTransfer(it.payer, sharesBack);
        if (assetsBack > 0) asset.safeTransfer(it.payer, assetsBack);

        sharesSpent = needed - sharesBack;
        emit PaidFromVault(it.payer, it.payTo, digest, it.vault, it.assets, sharesSpent, sharesBack, assetsBack);
    }

    /// @dev ECDSA first, then ERC-1271 for a signer with code. A contract address has no private
    ///      key, so the ECDSA branch only ever accepts an EOA, including one delegated under
    ///      EIP-7702, whose own key already controls the account.
    function _isValidSignature(address signer, bytes32 hash, bytes calldata signature)
        private
        view
        returns (bool)
    {
        // The third return value only describes a failure; recovered and err decide.
        // slither-disable-next-line unused-return
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
        return signer.code.length != 0 && SignatureChecker.isValidERC1271SignatureNow(signer, hash, signature);
    }

    // ---------------------------------------------------------------------- cancel

    /// @notice Spend `digest` without paying: the caller's intent with this digest can never settle.
    function cancel(bytes32 digest) external {
        _cancel(msg.sender, digest);
    }

    /// @notice The same, gasless: anyone may submit the payer's EIP-712 CancelIntent signature.
    function cancelWithSignature(address payer, bytes32 digest, bytes calldata signature) external {
        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(CANCEL_INTENT_TYPEHASH, payer, digest)));
        if (!_isValidSignature(payer, hash, signature)) revert InvalidSignature();
        _cancel(payer, digest);
    }

    function _cancel(address payer, bytes32 digest) private {
        if (intentUsed[payer][digest]) revert IntentAlreadyUsed(digest);
        intentUsed[payer][digest] = true;
        emit IntentCancelled(payer, digest);
    }

    // ---------------------------------------------------------------------- views

    /// @notice The EIP-712 digest the payer signs for `it`.
    function intentDigest(PayIntent calldata it) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PAY_INTENT_TYPEHASH,
                    it.payer,
                    it.vault,
                    it.asset,
                    it.payTo,
                    it.assets,
                    it.maxShares,
                    it.salt,
                    it.validAfter,
                    it.validBefore
                )
            )
        );
    }

    /// @notice Shares a payment of `assets` costs right now.
    function sharesFor(address vault, uint256 assets) external view returns (uint256) {
        return IERC4626(vault).previewWithdraw(assets);
    }

    /// @notice A `maxShares` to sign for `assets`: today's cost plus AUTHORIZE_HEADROOM_BPS,
    ///         rounded up. A yield-bearing vault's shares only get cheaper to spend as yield
    ///         accrues, so the headroom covers rounding and a small loss, not ordinary drift.
    function sharesToAuthorize(address vault, uint256 assets) external view returns (uint256) {
        return Math.mulDiv(
            IERC4626(vault).previewWithdraw(assets), 10_000 + AUTHORIZE_HEADROOM_BPS, 10_000, Math.Rounding.Ceil
        );
    }

    /// @notice This router's EIP-712 domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}

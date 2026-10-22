// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {SpectralStabilizer} from "../SpectralStabilizer.sol";
import {SpectralToken} from "../SpectralToken.sol";
import {ISpectralEntropyOracle} from "../interfaces/ISpectralEntropyOracle.sol";

/// @title  SpectrumPayRouter
/// @notice Pays a USDC price out of an sUSD balance in one transaction, gasless for the payer.
///         The payer signs one EIP-3009 `receiveWithAuthorization` of sUSD to this router, and
///         anyone (normally an x402 facilitator) submits it with `pay`. The router redeems just
///         enough sUSD for the price, pays the recipient exactly that much USDC, and returns
///         all the change to the payer in the same transaction. This is how an agent that keeps
///         its working balance in sUSD pays an API priced in USDC (Phase 6, docs/design/x402-rail.md).
///
/// @dev    Intent binding. EIP-3009 signs (from, to, value, validAfter, validBefore, nonce); it
///         does not say where the router should send the USDC. So the payer sets the nonce to
///         `intentNonce(payTo, assets, salt)`, and `pay` recomputes it from its own arguments: a
///         submitter who changes the recipient, the price or the salt changes the nonce, and the
///         token rejects the signature. Only this router can use a receive authorization naming
///         it, because `receiveWithAuthorization` requires msg.sender == to.
///
///         All or nothing. If the authorization is invalid or used, the value does not cover the
///         price at the current fee, or the treasury cannot pay out right now, the transaction
///         reverts and the authorization stays unused: nothing moves, and the same signed
///         authorization can be submitted again later.
///
///         Nothing to trust. No owner, no settings, no fee. The router holds no balance between
///         calls: whatever it holds at the end of a payment goes back to that payer.
///
///         Amounts. `assets` is in USDC units (6 decimals); `value` is in sUSD wei (18
///         decimals). A redemption below `stabilizer.minAmount()` (0.01 sUSD for USDC) is
///         refused, so for a smaller price the router redeems that minimum and returns the USDC
///         change: the payer must authorise at least the minimum. Authorise
///         `sUSDToAuthorize(assets)`, sized at the highest fee H can set, and a fee move between
///         signing and settlement cannot make the payment fail.
contract SpectrumPayRouter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;

    /// @notice Type of the intent hashed into the EIP-3009 nonce.
    bytes32 public constant PAY_INTENT_TYPEHASH =
        keccak256("SpectrumPayIntent(address payTo,uint256 assets,bytes32 salt)");

    SpectralStabilizer public immutable stabilizer;
    SpectralToken public immutable sUSD;
    IERC20 public immutable usdc;
    ISpectralEntropyOracle public immutable oracle;
    address public immutable treasury;
    /// @notice 10^(18 - USDC decimals), as the stabilizer uses it.
    uint256 public immutable scale;

    /// @param assets         USDC paid to `payTo`.
    /// @param sUSDRedeemed   sUSD redeemed for it.
    /// @param sUSDReturned   Unspent sUSD returned to the payer.
    /// @param assetsReturned USDC above the price returned to the payer.
    event PaidWithSUSD(
        address indexed payer,
        address indexed payTo,
        bytes32 indexed nonce,
        uint256 assets,
        uint256 sUSDRedeemed,
        uint256 sUSDReturned,
        uint256 assetsReturned
    );

    error ZeroAddress();
    error ZeroAmount();
    error InvalidPayTo(address payTo);
    error AuthorizationTooSmall(uint256 needed, uint256 authorized);

    constructor(SpectralStabilizer stabilizer_) {
        if (address(stabilizer_) == address(0)) revert ZeroAddress();
        stabilizer = stabilizer_;
        sUSD = stabilizer_.token();
        usdc = IERC20(address(stabilizer_.asset()));
        oracle = stabilizer_.oracle();
        treasury = address(stabilizer_.treasury());
        scale = stabilizer_.scale();
    }

    // ---------------------------------------------------------------------- pay

    /// @notice Pay `assets` USDC to `payTo` out of `from`'s sUSD.
    /// @param  from        The payer, who signed the authorization (an EOA or an ERC-1271 wallet).
    /// @param  value       sUSD the payer authorised (wei). Everything not needed comes back.
    /// @param  validAfter  The authorization's validAfter.
    /// @param  validBefore The authorization's validBefore.
    /// @param  payTo       Recipient of the USDC (a merchant, or the payer itself to convert).
    /// @param  assets      USDC to deliver, in USDC units.
    /// @param  salt        The payer's random salt; the nonce is `intentNonce(payTo, assets, salt)`.
    /// @param  signature   The payer's EIP-712 signature of the receive authorization.
    /// @return redeemed    sUSD redeemed for the payment.
    function pay(
        address from,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        address payTo,
        uint256 assets,
        bytes32 salt,
        bytes calldata signature
    ) external nonReentrant returns (uint256 redeemed) {
        if (assets == 0) revert ZeroAmount();
        if (
            payTo == address(0) || payTo == address(this) || payTo == address(stabilizer) || payTo == treasury
                || payTo == address(sUSD)
        ) revert InvalidPayTo(payTo);

        // Absorb a pending vault loss first, so that `value` and the redemption below are measured
        // at the same index (the redemption would absorb it anyway, after the transfer).
        // slither-disable-next-line unused-return
        stabilizer.sync();

        bytes32 nonce = intentNonce(payTo, assets, salt);
        sUSD.receiveWithAuthorization(from, address(this), value, validAfter, validBefore, nonce, signature);

        redeemed = sUSDFor(assets);
        if (redeemed > value) revert AuthorizationTooSmall(redeemed, value);
        // slither-disable-next-line unused-return
        stabilizer.redeem(redeemed, address(this), assets); // reverts unless it pays >= assets
        usdc.safeTransfer(payTo, assets);

        // The change, and anything else the router holds, goes back to this payer.
        uint256 sUSDBack = sUSD.balanceOf(address(this));
        if (sUSDBack > 0) IERC20(address(sUSD)).safeTransfer(from, sUSDBack);
        uint256 assetsBack = usdc.balanceOf(address(this));
        if (assetsBack > 0) usdc.safeTransfer(from, assetsBack);
        emit PaidWithSUSD(from, payTo, nonce, assets, redeemed, sUSDBack, assetsBack);
    }

    // ---------------------------------------------------------------------- views

    /// @notice The EIP-3009 nonce a payer signs for paying `assets` USDC to `payTo`.
    function intentNonce(address payTo, uint256 assets, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(PAY_INTENT_TYPEHASH, payTo, assets, salt));
    }

    /// @notice sUSD `pay` redeems for `assets` at the current fee: the least amount whose
    ///         redemption pays at least `assets`, and never less than the minimum redemption.
    function sUSDFor(uint256 assets) public view returns (uint256) {
        return _sUSDFor(assets, stabilizer.redeemFeeRate(oracle.smoothedEntropy()));
    }

    /// @notice sUSD a payer should authorise for `assets`: enough at the highest redemption fee
    ///         H can set, so a fee move between signing and settlement cannot make the payment
    ///         fail. `pay` returns whatever is not needed.
    function sUSDToAuthorize(uint256 assets) external view returns (uint256) {
        return _sUSDFor(assets, stabilizer.REDEEM_FEE_MAX());
    }

    /// @dev A redemption of `a` pays floor((a - ceil(a * rate / WAD)) / scale). For
    ///      a = ceil(assets * scale * WAD / (WAD - rate)): a * (WAD - rate) / WAD >= assets * scale,
    ///      and a - ceil(a * rate / WAD) > a * (WAD - rate) / WAD - 1 >= assets * scale - 1, so
    ///      (both sides being integers) the redemption pays at least `assets`.
    function _sUSDFor(uint256 assets, uint256 rate) internal view returns (uint256 a) {
        a = Math.mulDiv(assets * scale, WAD, WAD - rate, Math.Rounding.Ceil);
        uint256 floor_ = stabilizer.minAmount();
        if (a < floor_) a = floor_;
    }
}

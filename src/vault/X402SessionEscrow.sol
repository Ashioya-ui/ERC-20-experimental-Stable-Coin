// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice USDC's EIP-3009 receive authorization, as the escrow uses it to open a session gaslessly.
interface IERC3009Receive {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

/// @title  X402SessionEscrow
/// @notice Sessions for x402: an agent pays a merchant thousands of times and the chain settles once.
///
///         Per-payment settlement puts a floor under every x402 price. On Base, settling one
///         payment costs about $0.0013 in gas, which is 10% of the median x402 payment and more
///         than the whole of a sub-cent one. A session removes that floor:
///
///         1. A funder deposits into a session that names one merchant (the payee), one token, an
///            expiry, and the key that will sign for it -- normally the agent's hot key.
///         2. Each call, the agent sends the merchant a voucher: an EIP-712 signature over the
///            session and the cumulative amount owed so far. The merchant checks it locally and
///            serves at once. Nothing touches the chain.
///         3. Whenever it likes, the merchant -- or a facilitator on its behalf -- redeems the
///            latest voucher. One transaction settles every call since the last one, and
///            claimMany settles many sessions in one transaction.
///         4. After expiry the funder takes back whatever was never claimed.
///
///         Safety, both ways. The merchant can never receive more than the deposit or more than the
///         signer authorised, and vouchers are cumulative, so an old one can never be counted
///         twice. The funder cannot pull the deposit back before expiry, so a voucher the merchant
///         holds is good until then. A stolen signing key can only overpay the one merchant the
///         session names, and only up to the deposit: a per-merchant spending cap for agent keys,
///         enforced by the chain.
///
///         Nothing to trust. No owner, no fee, no upgrade path, no oracle. Ownerless and immutable;
///         the escrow holds exactly the unclaimed balance of its open sessions.
contract X402SessionEscrow is EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice EIP-712 type of a voucher: `cumulative` is everything owed in `sessionId` so far.
    bytes32 public constant VOUCHER_TYPEHASH = keccak256("Voucher(bytes32 sessionId,uint256 cumulative)");
    /// @notice Hashed into the EIP-3009 nonce of a gasless open, binding the session's terms.
    bytes32 public constant OPEN_TYPEHASH =
        keccak256("SessionOpen(address payee,address token,address signer,uint64 expiry,bytes32 salt)");
    /// @notice Hashed into the EIP-3009 nonce of a gasless top-up.
    bytes32 public constant TOP_UP_TYPEHASH = keccak256("SessionTopUp(bytes32 sessionId,bytes32 salt)");

    /// @notice A session must leave the payee at least this long to settle.
    uint64 public constant MIN_DURATION = 1 hours;
    /// @notice And may not lock a deposit away for longer than this.
    uint64 public constant MAX_DURATION = 365 days;

    struct Session {
        address funder; // deposits, and takes back what is unclaimed after expiry
        address payee; // the only address that can ever be paid from this session
        address token;
        address signer; // signs vouchers: normally the agent's key, not the funder's
        uint128 deposited;
        uint128 claimed;
        uint64 expiry;
        bool closed;
    }

    mapping(bytes32 sessionId => Session) private _sessions;

    event SessionOpened(
        bytes32 indexed sessionId,
        address indexed funder,
        address indexed payee,
        address token,
        address signer,
        uint256 amount,
        uint64 expiry
    );
    event SessionToppedUp(bytes32 indexed sessionId, uint256 amount, uint256 deposited);
    event VoucherRedeemed(bytes32 indexed sessionId, address indexed payee, uint256 amount, uint256 cumulative);
    event SessionClosed(bytes32 indexed sessionId, uint256 claimed, uint256 refunded);

    error ZeroAddress();
    error ZeroAmount();
    error BadExpiry(uint64 expiry);
    error SessionExists(bytes32 sessionId);
    error UnknownSession(bytes32 sessionId);
    error SessionIsClosed(bytes32 sessionId);
    error SessionExpired(bytes32 sessionId);
    error NotExpired(bytes32 sessionId, uint64 expiry);
    error NotPayee(address caller);
    error AboveDeposit(uint256 cumulative, uint256 deposited);
    error NothingNew(uint256 cumulative, uint256 claimed);
    error InvalidVoucher();
    error AmountOverflow();
    error InexactTransfer();
    error LengthMismatch();

    constructor() EIP712("X402SessionEscrow", "1") {}

    // ---------------------------------------------------------------------- open and fund

    /// @notice Open a session funded by the caller.
    /// @return sessionId keccak256(funder, payee, token, signer, salt): computable before opening.
    function open(address payee, address token, address signer, uint64 expiry, bytes32 salt, uint256 amount)
        external
        nonReentrant
        returns (bytes32 sessionId)
    {
        sessionId = _create(msg.sender, payee, token, signer, expiry, salt);
        _credit(sessionId, amount, true);
        _pullExact(IERC20(token), msg.sender, amount);
    }

    /// @notice Open a session gaslessly: the funder signs one EIP-3009 receive authorization of the
    ///         token to this escrow, and anyone (normally a facilitator) submits it. Its nonce must
    ///         be openNonce(payee, token, signer, expiry, salt), which this function recomputes, so
    ///         a submitter who alters any term of the session invalidates the authorization.
    function openWithAuthorization(
        address funder,
        address payee,
        address token,
        address signer,
        uint64 expiry,
        bytes32 salt,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata authorization
    ) external nonReentrant returns (bytes32 sessionId) {
        sessionId = _create(funder, payee, token, signer, expiry, salt);
        _credit(sessionId, amount, true);
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC3009Receive(token).receiveWithAuthorization(
            funder, address(this), amount, validAfter, validBefore, openNonce(payee, token, signer, expiry, salt),
            authorization
        );
        _checkArrived(IERC20(token), before, amount);
    }

    /// @notice Add funds to an open session. Anyone may; the funds become the session's.
    function topUp(bytes32 sessionId, uint256 amount) external nonReentrant {
        Session storage s = _live(sessionId);
        _credit(sessionId, amount, false);
        _pullExact(IERC20(s.token), msg.sender, amount);
    }

    /// @notice Add funds gaslessly with an EIP-3009 receive authorization whose nonce is
    ///         topUpNonce(sessionId, salt).
    function topUpWithAuthorization(
        bytes32 sessionId,
        address from,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 salt,
        bytes calldata authorization
    ) external nonReentrant {
        Session storage s = _live(sessionId);
        _credit(sessionId, amount, false);
        uint256 before = IERC20(s.token).balanceOf(address(this));
        IERC3009Receive(s.token).receiveWithAuthorization(
            from, address(this), amount, validAfter, validBefore, topUpNonce(sessionId, salt), authorization
        );
        _checkArrived(IERC20(s.token), before, amount);
    }

    // ---------------------------------------------------------------------- settle

    /// @notice Pay the payee everything `cumulative` covers beyond what it has already claimed.
    ///         Anyone may submit; the funds only ever go to the session's payee.
    function redeem(bytes32 sessionId, uint256 cumulative, bytes calldata signature) external nonReentrant {
        _redeem(sessionId, cumulative, signature);
    }

    /// @notice Redeem many sessions in one transaction: how a facilitator settles for its
    ///         merchants at the cost of one.
    function redeemMany(bytes32[] calldata sessionIds, uint256[] calldata cumulatives, bytes[] calldata signatures)
        external
        nonReentrant
    {
        if (sessionIds.length != cumulatives.length || sessionIds.length != signatures.length) revert LengthMismatch();
        for (uint256 i; i < sessionIds.length; ++i) {
            _redeem(sessionIds[i], cumulatives[i], signatures[i]);
        }
    }

    // ---------------------------------------------------------------------- close

    /// @notice After expiry, return everything unclaimed to the funder. Anyone may trigger it.
    function reclaim(bytes32 sessionId) external nonReentrant {
        Session storage s = _known(sessionId);
        if (s.closed) revert SessionIsClosed(sessionId);
        // slither-disable-next-line timestamp
        if (block.timestamp <= s.expiry) revert NotExpired(sessionId, s.expiry);
        _close(sessionId, s);
    }

    /// @notice The payee ends a session early: optionally redeems a final voucher, then releases
    ///         the rest to the funder. Only the payee, since it gives up every later claim.
    function closeByPayee(bytes32 sessionId, uint256 cumulative, bytes calldata signature) external nonReentrant {
        Session storage s = _known(sessionId);
        if (msg.sender != s.payee) revert NotPayee(msg.sender);
        if (signature.length != 0 && cumulative > s.claimed) _redeem(sessionId, cumulative, signature);
        if (s.closed) revert SessionIsClosed(sessionId);
        _close(sessionId, s);
    }

    // ---------------------------------------------------------------------- views

    function session(bytes32 sessionId) external view returns (Session memory) {
        return _sessions[sessionId];
    }

    /// @notice What a voucher for `cumulative` could still pay right now (0 if closed or expired).
    function redeemable(bytes32 sessionId, uint256 cumulative) external view returns (uint256) {
        Session storage s = _sessions[sessionId];
        // slither-disable-next-line timestamp
        if (s.funder == address(0) || s.closed || block.timestamp > s.expiry) return 0;
        uint256 capped = cumulative < s.deposited ? cumulative : s.deposited;
        return capped > s.claimed ? capped - s.claimed : 0;
    }

    function sessionIdOf(address funder, address payee, address token, address signer, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(funder, payee, token, signer, salt));
    }

    function voucherDigest(bytes32 sessionId, uint256 cumulative) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(VOUCHER_TYPEHASH, sessionId, cumulative)));
    }

    function openNonce(address payee, address token, address signer, uint64 expiry, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(OPEN_TYPEHASH, payee, token, signer, expiry, salt));
    }

    function topUpNonce(bytes32 sessionId, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(TOP_UP_TYPEHASH, sessionId, salt));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------- internals

    function _create(address funder, address payee, address token, address signer, uint64 expiry, bytes32 salt)
        internal
        returns (bytes32 sessionId)
    {
        if (funder == address(0) || payee == address(0) || token == address(0) || signer == address(0)) {
            revert ZeroAddress();
        }
        // slither-disable-next-line timestamp
        if (expiry < block.timestamp + MIN_DURATION || expiry > block.timestamp + MAX_DURATION) revert BadExpiry(expiry);
        sessionId = sessionIdOf(funder, payee, token, signer, salt);
        if (_sessions[sessionId].funder != address(0)) revert SessionExists(sessionId);
        _sessions[sessionId] = Session({
            funder: funder,
            payee: payee,
            token: token,
            signer: signer,
            deposited: 0,
            claimed: 0,
            expiry: expiry,
            closed: false
        });
    }

    /// @dev Effects first: the session is credited before any token moves, and the transfer must
    ///      then deliver exactly that amount. A fee-on-transfer or rebasing token cannot be used,
    ///      which keeps every session's balance an exact claim on the escrow's.
    function _pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        _checkArrived(token, before, amount);
    }

    function _checkArrived(IERC20 token, uint256 before, uint256 amount) internal view {
        if (token.balanceOf(address(this)) - before != amount) revert InexactTransfer();
    }

    function _credit(bytes32 sessionId, uint256 amount, bool opening) internal {
        if (amount == 0) revert ZeroAmount();
        Session storage s = _sessions[sessionId];
        uint256 total = uint256(s.deposited) + amount;
        if (total > type(uint128).max) revert AmountOverflow();
        s.deposited = uint128(total);
        if (opening) emit SessionOpened(sessionId, s.funder, s.payee, s.token, s.signer, amount, s.expiry);
        else emit SessionToppedUp(sessionId, amount, total);
    }

    function _redeem(bytes32 sessionId, uint256 cumulative, bytes calldata signature) internal {
        Session storage s = _live(sessionId);
        if (cumulative > s.deposited) revert AboveDeposit(cumulative, s.deposited);
        if (cumulative <= s.claimed) revert NothingNew(cumulative, s.claimed);
        if (!_validSignature(s.signer, voucherDigest(sessionId, cumulative), signature)) revert InvalidVoucher();
        uint256 amount = cumulative - s.claimed;
        s.claimed = uint128(cumulative); // cumulative <= deposited <= type(uint128).max
        IERC20(s.token).safeTransfer(s.payee, amount);
        emit VoucherRedeemed(sessionId, s.payee, amount, cumulative);
    }

    function _close(bytes32 sessionId, Session storage s) internal {
        s.closed = true;
        uint256 refund = s.deposited - s.claimed;
        if (refund > 0) IERC20(s.token).safeTransfer(s.funder, refund);
        emit SessionClosed(sessionId, s.claimed, refund);
    }

    function _known(bytes32 sessionId) internal view returns (Session storage s) {
        s = _sessions[sessionId];
        if (s.funder == address(0)) revert UnknownSession(sessionId);
    }

    function _live(bytes32 sessionId) internal view returns (Session storage s) {
        s = _known(sessionId);
        if (s.closed) revert SessionIsClosed(sessionId);
        // slither-disable-next-line timestamp
        if (block.timestamp > s.expiry) revert SessionExpired(sessionId);
    }

    /// @dev ECDSA first, then ERC-1271. OpenZeppelin 5.4's SignatureChecker sends any signer that
    ///      has code straight to ERC-1271, which strands an EIP-7702 account whose delegate does not
    ///      implement it: its own key would never be checked. A contract address has no private
    ///      key, so trying ECDSA first cannot let anyone sign for one.
    function _validSignature(address signer, bytes32 digest, bytes calldata signature) internal view returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
        return signer.code.length != 0 && SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature);
    }
}

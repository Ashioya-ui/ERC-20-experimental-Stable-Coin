// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IERC3009Receive, X402SessionEscrow} from "./X402SessionEscrow.sol";

/// @title  X402SessionPaths
/// @notice The self-approaching condition, as the treasury of an x402 agent.
///
///         An agent's money does not sit behind its hot key. It sits in a path, declared once from
///         the owner's own device (home, the third act beside the agent and the merchant): an end E
///         that names each merchant the agent may pay and the most that merchant may ever receive
///         through the path, a budget, and an expiry. The agent's key can do one thing with it: step
///         toward E, by opening an X402SessionEscrow session to a named merchant for an amount that
///         keeps that merchant within its cap.
///
///         The path's state x, what is committed to each merchant, therefore only grows, one
///         coordinate per step, inside the box [0, E]. Such a path is self-approaching to E: for any
///         three acts i < j < k, |x_k - x_j| <= |x_k - x_i| in every norm, and its length, everything
///         ever committed, is at most |E|_1. Checking that costs O(1) per step: over the whole
///         history the three-act condition reduces to "a named merchant, a positive amount, no
///         overshoot", because coordinatewise monotone moves inside the box satisfy it and every
///         other single-coordinate move breaks it.
///
///         That is the defence, and it is structural: no watcher, no oracle, no off-chain policy.
///         Whoever holds the agent's key, the agent itself, a compromised machine submitting
///         valid-looking requests, or someone replaying a pile of pre-signed steps until one
///         matches, can only do what the path already allows: pay the owner's named merchants, up
///         to the owner's named amounts. Every attack of that family collapses into progress along
///         the owner's own plan. A signed step names the exact state it moves from, so it is valid at
///         one point of the path only, and the path never returns to a point it has left: the state
///         is the nonce.
///
///         Money leaves a path only into sessions to named merchants, or to home. Only home widens
///         the end, by declaring a new path. Refunds from sessions come back to the path and never
///         raise what can be committed. No owner, no fee, no upgrade path.
contract X402SessionPaths is EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Hashed into the EIP-3009 nonce of a gasless declaration, binding every term of the path.
    bytes32 public constant DECLARE_TYPEHASH =
        keccak256("PathDeclare(address agent,address token,uint64 expiry,bytes32 ends,bytes32 salt)");
    /// @notice EIP-712 type of a step the agent signs for someone else, normally a facilitator, to submit.
    ///         `committed` is what the payee had been committed before the step: the state it moves from.
    bytes32 public constant STEP_TYPEHASH = keccak256(
        "PathStep(bytes32 pathId,address payee,address signer,uint64 expiry,bytes32 salt,uint256 amount,uint256 committed,uint256 deadline)"
    );
    /// @notice EIP-712 type of home's gasless order to end a path and send what it holds home.
    bytes32 public constant END_TYPEHASH = keccak256("PathEnd(bytes32 pathId,uint256 deadline)");

    /// @notice A path names at most this many merchants, so declaring it has a bounded cost.
    uint256 public constant MAX_PAYEES = 32;
    /// @notice A path must outlive at least one session (the escrow's MIN_DURATION) with room to spare.
    uint64 public constant MIN_DURATION = 2 hours;
    /// @notice And may not hold a budget for longer than this.
    uint64 public constant MAX_DURATION = 365 days;

    /// @notice The escrow every session of every path is opened in.
    X402SessionEscrow public immutable escrow;

    struct Path {
        address home; // declared the end; the only place money leaves to besides the named merchants
        address agent; // the hot key: may only step toward the end
        address token;
        uint64 expiry; // no step after it; after it anyone may send what is left home
        bool ended; // home ended it, or it was sent home after expiry
        uint128 free; // held for this path and in no session
        uint128 committed; // the path's length so far: everything ever committed, at most `bound`
        uint128 bound; // |E|_1: the sum of the caps
    }

    mapping(bytes32 pathId => Path) private _paths;
    /// @notice E: the most `payee` may ever be committed through the path. Zero means not on the path.
    mapping(bytes32 pathId => mapping(address payee => uint256)) public capOf;
    /// @notice x: what `payee` has been committed so far. It never decreases.
    mapping(bytes32 pathId => mapping(address payee => uint256)) public committedTo;
    /// @notice The path that funded each session this contract opened.
    mapping(bytes32 sessionId => bytes32 pathId) public pathOf;
    /// @notice Whether a closed session's refund has been credited back to its path.
    mapping(bytes32 sessionId => bool) public collected;

    event PathDeclared(
        bytes32 indexed pathId,
        address indexed home,
        address indexed agent,
        address token,
        uint64 expiry,
        uint256 budget,
        uint256 bound
    );
    event Stepped(bytes32 indexed pathId, address indexed payee, bytes32 indexed sessionId, uint256 amount, uint256 committed);
    event Collected(bytes32 indexed pathId, bytes32 indexed sessionId, uint256 refund);
    event WentHome(bytes32 indexed pathId, address indexed home, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error AmountOverflow();
    error BadExpiry(uint64 expiry);
    error BadEnds();
    error ForbiddenPayee(address payee);
    error DuplicatePayee(address payee);
    error PathExists(bytes32 pathId);
    error UnknownPath(bytes32 pathId);
    error PathEnded(bytes32 pathId);
    error PathExpired(bytes32 pathId);
    error NotAgent(address caller);
    error NotHome(address caller);
    error NotOnPath(address payee);
    error BeyondEnd(address payee, uint256 committed, uint256 cap);
    error ShortOfFunds(uint256 amount, uint256 free);
    error SessionOutlivesPath(uint64 sessionExpiry, uint64 pathExpiry);
    error StaleStep(uint256 signedAt, uint256 pathAt);
    error SignatureExpired(uint256 deadline);
    error InvalidSignature();
    error UnknownSession(bytes32 sessionId);
    error NotClosed(bytes32 sessionId);
    error AlreadyCollected(bytes32 sessionId);
    error SessionMismatch(bytes32 expected, bytes32 opened);
    error InexactTransfer();

    constructor(X402SessionEscrow escrow_) EIP712("X402SessionPaths", "1") {
        if (address(escrow_) == address(0)) revert ZeroAddress();
        escrow = escrow_;
    }

    // ---------------------------------------------------------------------- declare (home)

    /// @notice Declare a path funded by the caller, who becomes its home.
    /// @return pathId pathIdOf(home, agent, token, expiry, endsOf(payees, caps), salt).
    function declare(
        address agent,
        address token,
        uint64 expiry,
        bytes32 salt,
        address[] calldata payees,
        uint256[] calldata caps,
        uint256 budget
    ) external nonReentrant returns (bytes32 pathId) {
        (pathId,) = _declare(msg.sender, agent, token, expiry, salt, payees, caps, budget);
        IERC20 t = IERC20(token);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), budget);
        _checkArrived(t, before, budget);
    }

    /// @notice Declare a path gaslessly: home signs one EIP-3009 receive authorization of `budget` to
    ///         this contract whose nonce is declareNonce(agent, token, expiry, ends, salt), and anyone
    ///         submits it. A submitter who alters any term of the path invalidates the authorization.
    function declareWithAuthorization(
        address home,
        address agent,
        address token,
        uint64 expiry,
        bytes32 salt,
        address[] calldata payees,
        uint256[] calldata caps,
        uint256 budget,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata authorization
    ) external nonReentrant returns (bytes32 pathId) {
        bytes32 ends;
        (pathId, ends) = _declare(home, agent, token, expiry, salt, payees, caps, budget);
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC3009Receive(token).receiveWithAuthorization(
            home, address(this), budget, validAfter, validBefore, declareNonce(agent, token, expiry, ends, salt), authorization
        );
        _checkArrived(IERC20(token), before, budget);
    }

    // ---------------------------------------------------------------------- step (agent)

    /// @notice The agent opens a session toward the end, paying its own gas.
    function step(bytes32 pathId, address payee, address signer, uint64 sessionExpiry, bytes32 salt, uint256 amount)
        external
        nonReentrant
        returns (bytes32 sessionId)
    {
        Path storage p = _live(pathId);
        if (msg.sender != p.agent) revert NotAgent(msg.sender);
        sessionId = _step(pathId, p, payee, signer, sessionExpiry, salt, amount);
    }

    /// @notice A step the agent signed, submitted by anyone (normally the merchant's facilitator, so
    ///         the agent needs no ETH). The signature names the state the step moves from; it is valid
    ///         at that state only, and the state never comes back.
    function stepWithSig(
        bytes32 pathId,
        address payee,
        address signer,
        uint64 sessionExpiry,
        bytes32 salt,
        uint256 amount,
        uint256 committed,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant returns (bytes32 sessionId) {
        Path storage p = _live(pathId);
        // slither-disable-next-line timestamp
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        uint256 here = committedTo[pathId][payee];
        if (committed != here) revert StaleStep(committed, here);
        bytes32 digest = stepDigest(pathId, payee, signer, sessionExpiry, salt, amount, committed, deadline);
        if (!_signedBy(p.agent, digest, signature)) revert InvalidSignature();
        sessionId = _step(pathId, p, payee, signer, sessionExpiry, salt, amount);
    }

    // ---------------------------------------------------------------------- refunds and home

    /// @notice Credit a closed session's refund back to its path. The escrow sends a session's
    ///         unclaimed balance to its funder, this contract, when the session closes (the payee's
    ///         close, or anyone's reclaim after expiry); this says whose it is. It raises what the path
    ///         holds, never what it may commit. Anyone may call it.
    function collect(bytes32 sessionId) external nonReentrant returns (uint256 refund) {
        bytes32 pathId = pathOf[sessionId];
        if (pathId == bytes32(0)) revert UnknownSession(sessionId);
        if (collected[sessionId]) revert AlreadyCollected(sessionId);
        X402SessionEscrow.Session memory s = escrow.session(sessionId);
        if (!s.closed) revert NotClosed(sessionId);
        collected[sessionId] = true;
        refund = uint256(s.deposited) - s.claimed;
        _paths[pathId].free += uint128(refund); // refund <= deposited <= type(uint128).max
        emit Collected(pathId, sessionId, refund);
    }

    /// @notice End the path and send what it holds home. Home may at any time; after the path's
    ///         expiry anyone may. It can be called again later, for refunds collected since.
    function goHome(bytes32 pathId) external nonReentrant returns (uint256 amount) {
        Path storage p = _known(pathId);
        // slither-disable-next-line timestamp
        if (msg.sender != p.home && block.timestamp <= p.expiry) revert NotHome(msg.sender);
        amount = _goHome(pathId, p);
    }

    /// @notice Home's gasless order to end the path: signed on home's device, submitted by anyone.
    ///         The owner's way to stop an agent at once, without holding ETH.
    function goHomeWithSig(bytes32 pathId, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 amount)
    {
        Path storage p = _known(pathId);
        // slither-disable-next-line timestamp
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        if (!_signedBy(p.home, endDigest(pathId, deadline), signature)) revert InvalidSignature();
        amount = _goHome(pathId, p);
    }

    // ---------------------------------------------------------------------- views

    function path(bytes32 pathId) external view returns (Path memory) {
        return _paths[pathId];
    }

    /// @notice What `payee` may still be committed through the path.
    function remaining(bytes32 pathId, address payee) external view returns (uint256) {
        return capOf[pathId][payee] - committedTo[pathId][payee];
    }

    /// @notice The hash of a path's end: the named merchants and their caps, in order.
    function endsOf(address[] calldata payees, uint256[] calldata caps) public pure returns (bytes32) {
        return keccak256(abi.encode(payees, caps));
    }

    function pathIdOf(address home, address agent, address token, uint64 expiry, bytes32 ends, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(home, agent, token, expiry, ends, salt));
    }

    function declareNonce(address agent, address token, uint64 expiry, bytes32 ends, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DECLARE_TYPEHASH, agent, token, expiry, ends, salt));
    }

    function stepDigest(
        bytes32 pathId,
        address payee,
        address signer,
        uint64 sessionExpiry,
        bytes32 salt,
        uint256 amount,
        uint256 committed,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(STEP_TYPEHASH, pathId, payee, signer, sessionExpiry, salt, amount, committed, deadline))
        );
    }

    function endDigest(bytes32 pathId, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(END_TYPEHASH, pathId, deadline)));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------- internals

    function _declare(
        address home,
        address agent,
        address token,
        uint64 expiry,
        bytes32 salt,
        address[] calldata payees,
        uint256[] calldata caps,
        uint256 budget
    ) internal returns (bytes32 pathId, bytes32 ends) {
        if (home == address(0) || agent == address(0) || token == address(0)) revert ZeroAddress();
        if (budget == 0) revert ZeroAmount();
        if (budget > type(uint128).max) revert AmountOverflow();
        // slither-disable-next-line timestamp
        if (expiry < block.timestamp + MIN_DURATION || expiry > block.timestamp + MAX_DURATION) revert BadExpiry(expiry);
        uint256 n = payees.length;
        if (n == 0 || n > MAX_PAYEES || n != caps.length) revert BadEnds();
        ends = endsOf(payees, caps);
        pathId = pathIdOf(home, agent, token, expiry, ends, salt);
        Path storage p = _paths[pathId];
        if (p.home != address(0)) revert PathExists(pathId);
        uint256 bound = 0;
        for (uint256 i = 0; i < n; ++i) {
            address payee = payees[i];
            if (payee == address(0) || payee == address(this) || payee == address(escrow)) revert ForbiddenPayee(payee);
            if (caps[i] == 0) revert ZeroAmount();
            if (capOf[pathId][payee] != 0) revert DuplicatePayee(payee);
            capOf[pathId][payee] = caps[i];
            bound += caps[i];
        }
        if (bound > type(uint128).max) revert AmountOverflow();
        p.home = home;
        p.agent = agent;
        p.token = token;
        p.expiry = expiry;
        p.free = uint128(budget); // budget <= type(uint128).max, checked above
        p.bound = uint128(bound); // checked above
        emit PathDeclared(pathId, home, agent, token, expiry, budget, bound);
    }

    /// @dev The self-approaching condition, in O(1): one named coordinate, a positive move, no
    ///      overshoot of its cap. Effects before the escrow is called; the session id is computed
    ///      here and checked against what the escrow returns.
    function _step(
        bytes32 pathId,
        Path storage p,
        address payee,
        address signer,
        uint64 sessionExpiry,
        bytes32 salt,
        uint256 amount
    ) internal returns (bytes32 sessionId) {
        if (amount == 0) revert ZeroAmount();
        uint256 cap = capOf[pathId][payee];
        if (cap == 0) revert NotOnPath(payee);
        uint256 next = committedTo[pathId][payee] + amount;
        if (next > cap) revert BeyondEnd(payee, next, cap);
        if (amount > p.free) revert ShortOfFunds(amount, p.free);
        if (sessionExpiry > p.expiry) revert SessionOutlivesPath(sessionExpiry, p.expiry);

        committedTo[pathId][payee] = next;
        p.committed += uint128(amount); // committed <= bound <= type(uint128).max
        p.free -= uint128(amount); // amount <= free
        address token = p.token;
        sessionId = keccak256(abi.encode(address(this), payee, token, signer, sessionExpiry, salt));
        pathOf[sessionId] = pathId;
        emit Stepped(pathId, payee, sessionId, amount, next);

        IERC20(token).forceApprove(address(escrow), amount);
        bytes32 opened = escrow.open(payee, token, signer, sessionExpiry, salt, amount);
        if (opened != sessionId) revert SessionMismatch(sessionId, opened);
    }

    function _goHome(bytes32 pathId, Path storage p) internal returns (uint256 amount) {
        p.ended = true;
        amount = p.free;
        p.free = 0;
        address home = p.home;
        emit WentHome(pathId, home, amount);
        if (amount > 0) IERC20(p.token).safeTransfer(home, amount);
    }

    function _known(bytes32 pathId) internal view returns (Path storage p) {
        p = _paths[pathId];
        if (p.home == address(0)) revert UnknownPath(pathId);
    }

    function _live(bytes32 pathId) internal view returns (Path storage p) {
        p = _known(pathId);
        if (p.ended) revert PathEnded(pathId);
        // slither-disable-next-line timestamp
        if (block.timestamp > p.expiry) revert PathExpired(pathId);
    }

    function _checkArrived(IERC20 token, uint256 before, uint256 amount) internal view {
        if (token.balanceOf(address(this)) - before != amount) revert InexactTransfer();
    }

    /// @dev ECDSA only, as for the escrow's vouchers: a contract's ERC-1271 answer could change
    ///      after the fact, and an EIP-7702 account still signs with its own key.
    function _signedBy(address who, bytes32 digest, bytes calldata signature) internal pure returns (bool) {
        // The third return value only describes a failure; recovered and err decide.
        // slither-disable-next-line unused-return
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        return err == ECDSA.RecoverError.NoError && recovered == who;
    }
}

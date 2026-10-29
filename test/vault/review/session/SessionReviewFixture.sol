// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {X402SessionEscrow} from "../../../../src/vault/X402SessionEscrow.sol";

// Shared world of the X402SessionEscrow review tests (test/vault/review/session).

/// @dev Circle's FiatToken v2.2 as the escrow meets it on Base, reduced to what a session touches:
///      six decimals; v2.2's blacklist and pause modifiers, with its revert strings, on approve,
///      transfer, transferFrom and the EIP-3009 functions; receiveWithAuthorization,
///      transferWithAuthorization and cancelAuthorization taking `bytes signature`, verified the
///      way v2.2's SignatureChecker does (ECDSA for an address without code, ERC-1271 for one with
///      code); one nonce space per authorizer, shared by all three. Anyone may blacklist or pause:
///      the tests play Circle. UsdcBaseMainnetFork.t.sol checks the behaviours used here against
///      the real token.
contract FiatTokenV22Mock is ERC20, EIP712 {
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    bool public paused;
    mapping(address account => bool) public isBlacklisted;
    mapping(address authorizer => mapping(bytes32 nonce => bool)) public authorizationState;

    constructor() ERC20("USD Coin", "USDC") EIP712("USD Coin", "2") {}

    modifier whenNotPaused() {
        require(!paused, "Pausable: paused");
        _;
    }

    modifier notBlacklisted(address account) {
        require(!isBlacklisted[account], "Blacklistable: account is blacklisted");
        _;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blacklist(address account) external {
        isBlacklisted[account] = true;
    }

    function unBlacklist(address account) external {
        isBlacklisted[account] = false;
    }

    function pause() external {
        paused = true;
    }

    function unpause() external {
        paused = false;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function approve(address spender, uint256 value)
        public
        override
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(spender)
        returns (bool)
    {
        return super.approve(spender, value);
    }

    function transfer(address to, uint256 value)
        public
        override
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(to)
        returns (bool)
    {
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(from)
        notBlacklisted(to)
        returns (bool)
    {
        return super.transferFrom(from, to, value);
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external whenNotPaused notBlacklisted(from) notBlacklisted(to) {
        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        _useAuthorization(from, nonce, validAfter, validBefore, structHash, signature);
        _transfer(from, to, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external whenNotPaused notBlacklisted(from) notBlacklisted(to) {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        _useAuthorization(from, nonce, validAfter, validBefore, structHash, signature);
        _transfer(from, to, value);
    }

    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) external whenNotPaused {
        require(!authorizationState[authorizer][nonce], "FiatTokenV2: authorization is used or canceled");
        _requireValidSignature(
            authorizer, keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)), signature
        );
        authorizationState[authorizer][nonce] = true;
    }

    function _useAuthorization(
        address authorizer,
        bytes32 nonce,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 structHash,
        bytes memory signature
    ) internal {
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        require(!authorizationState[authorizer][nonce], "FiatTokenV2: authorization is used or canceled");
        _requireValidSignature(authorizer, structHash, signature);
        authorizationState[authorizer][nonce] = true;
    }

    function _requireValidSignature(address signer, bytes32 structHash, bytes memory signature) internal view {
        require(
            SignatureChecker.isValidSignatureNow(signer, _hashTypedDataV4(structHash), signature),
            "FiatTokenV2: invalid signature"
        );
    }
}

/// @dev A smart account that signs with whichever key owns it now, and lets that key hand it to
///      another: Safe's swapOwner, Coinbase Smart Wallet's removeOwnerAtIndex and a Kernel
///      validator change are each this one transaction.
contract SessionRotatingWallet is IERC1271 {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function rotate(address newOwner) external {
        require(msg.sender == owner, "not the owner");
        owner = newOwner;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && signer == owner
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}

/// @dev An EIP-7702 delegate whose ERC-1271 checks the account's own key over a replay-safe
///      wrapping of the hash (the ERC-7739 idea), which is what smart-account SDKs sign.
contract SessionWrappingDelegate is IERC1271 {
    bytes32 public constant WRAP_TYPEHASH = keccak256("ReplaySafe(address account,bytes32 hash)");

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        bytes32 wrapped = keccak256(abi.encode(WRAP_TYPEHASH, address(this), hash));
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(wrapped, signature);
        return err == ECDSA.RecoverError.NoError && signer == address(this)
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}

/// @dev An ERC-1271 account whose owner's signatures hold only on blocks of one parity. On the
///      other parity it answers no, and with `burn` set it first burns the gas it was given. A
///      view function can do both.
contract SessionParityWallet is IERC1271 {
    address public immutable owner;
    uint256 public immutable parity;
    bool public immutable burn;

    constructor(address owner_, uint256 parity_, bool burn_) {
        owner = owner_;
        parity = parity_;
        burn = burn_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (block.number % 2 != parity) {
            if (burn) {
                while (gasleft() > 5_000) {}
            }
            return bytes4(0xffffffff);
        }
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && signer == owner
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}

/// @dev Delivers one unit less than it is asked to move: a fee-on-transfer token.
contract SessionFeeToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }
        super._update(from, address(uint160(0xFEE)), 1);
        super._update(from, to, value - 1);
    }
}

/// @dev Calls `target` with `data` whenever it pays `trigger`, as a token with transfer hooks
///      (ERC-777, ERC-1363) lets a recipient do, and bubbles any revert.
contract SessionReentrantToken is ERC20 {
    address public trigger;
    address public target;
    bytes public data;

    constructor() ERC20("Hook Token", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address trigger_, address target_, bytes calldata data_) external {
        trigger = trigger_;
        target = target_;
        data = data_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (trigger == address(0) || to != trigger) return;
        bytes memory payload = data;
        (bool ok, bytes memory ret) = target.call(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @dev The world of the session review: the escrow; FiatTokenV22Mock as USDC; a funder (the
///      agent's owner) holding 1,000 USDC with a standing approval to the escrow; the agent's key,
///      which signs vouchers; a merchant and a facilitator; Base-like time and height. Time and
///      height are read through the vm, never block.timestamp: under via-IR a test function may
///      not see its own vm.warp through block.timestamp.
abstract contract SessionReviewFixture is Test {
    uint256 internal constant FUNDER_PK = 0xF00D;
    uint256 internal constant AGENT_PK = 0xA6E7;

    X402SessionEscrow internal escrow;
    FiatTokenV22Mock internal usdc;
    address internal funder;
    address internal agent;
    address internal merchant;
    address internal facilitator;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(30_000_000);
        escrow = new X402SessionEscrow();
        usdc = new FiatTokenV22Mock();
        funder = vm.addr(FUNDER_PK);
        agent = vm.addr(AGENT_PK);
        merchant = makeAddr("merchant");
        facilitator = makeAddr("facilitator");
        usdc.mint(funder, 1_000e6);
        vm.prank(funder);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    /// @dev The next Base block: two seconds and one block on.
    function _nextBlock() internal {
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _openFor(address payee, address signer, uint256 amount, uint64 expiry, bytes32 salt)
        internal
        returns (bytes32 id)
    {
        vm.prank(funder);
        id = escrow.open(payee, address(usdc), signer, expiry, salt, amount);
    }

    /// @dev A one-day session from the funder to the merchant, signed for by the agent's key.
    function _open(uint256 amount, bytes32 salt) internal returns (bytes32) {
        return _openFor(merchant, agent, amount, uint64(_now() + 1 days), salt);
    }

    function _voucher(uint256 pk, bytes32 id, uint256 cumulative) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, escrow.voucherDigest(id, cumulative));
        return abi.encodePacked(r, s, v);
    }

    /// @dev An EIP-3009 ReceiveWithAuthorization from vm.addr(pk) to the escrow.
    function _receiveAuth(uint256 pk, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typehash = usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH();
        bytes32 structHash =
            keccak256(abi.encode(typehash, vm.addr(pk), address(escrow), value, validAfter, validBefore, nonce));
        return _signUsdc(pk, structHash);
    }

    function _signUsdc(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev A gasless open: its terms and the funder's EIP-3009 authorization of its deposit.
    struct GaslessOpen {
        address funder;
        address payee;
        address token;
        address signer;
        uint64 expiry;
        bytes32 salt;
        uint256 amount;
        uint256 validAfter;
        uint256 validBefore;
        bytes authorization;
    }

    /// @dev The funder's gasless open to the merchant for the agent's key, authorized from ten
    ///      minutes ago until a minute from now, as x402 clients sign it.
    function _gaslessOpen(uint64 expiry, bytes32 salt, uint256 amount) internal view returns (GaslessOpen memory o) {
        o.funder = funder;
        o.payee = merchant;
        o.token = address(usdc);
        o.signer = agent;
        o.expiry = expiry;
        o.salt = salt;
        o.amount = amount;
        o.validAfter = vm.getBlockTimestamp() - 600;
        o.validBefore = vm.getBlockTimestamp() + 60;
        bytes32 nonce = escrow.openNonce(o.payee, o.token, o.signer, o.expiry, o.salt);
        o.authorization = _receiveAuth(FUNDER_PK, o.amount, o.validAfter, o.validBefore, nonce);
    }

    /// @dev Submits `o` as it stands: one external call and none before it, so a vm.prank or a
    ///      vm.expectRevert placed just before this helper applies to the open.
    function _submit(GaslessOpen memory o) internal returns (bytes32) {
        return escrow.openWithAuthorization(
            o.funder, o.payee, o.token, o.signer, o.expiry, o.salt, o.amount, o.validAfter, o.validBefore, o.authorization
        );
    }
}

/// @dev Base of the regression guards (SessionGuards.t.sol): each is a finding's PoC inverted, and
///      passes now that its fix is in.
abstract contract SessionGuardFixture is SessionReviewFixture {}

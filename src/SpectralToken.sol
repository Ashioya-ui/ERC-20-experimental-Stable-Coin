// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  SpectralToken: Spectrum Agentic USD (sUSD)
/// @notice Reserve-backed, rebasing ERC-20 with gasless approvals and transfers.
///
/// @dev    Accounting. Holders own *shares*. `balanceOf = shares * index / 1e18`. A rebase
///         changes `index` and therefore every balance at once. Only the stabilizer can mint,
///         burn or change the index. The stabilizer only expands the index to distribute
///         reserve surplus (yield and fees) and only contracts it to absorb a realised
///         reserve loss. Supply never exceeds reserves through a protocol action.
///
///         Rounding. Transfers move `ceil(amount / index)` shares (capped at the sender's
///         shares), so the recipient receives at least `amount` unless the sender sends
///         their entire balance. Mints round shares down and burns round shares up, both in
///         the reserve's favour. Balances can differ from naive sums by 1 wei after a rebase,
///         as with every share-based rebasing token.
///
///         Gasless flows:
///         - EIP-2612 `permit` (v,r,s and bytes overloads);
///         - EIP-3009 `transferWithAuthorization`, `receiveWithAuthorization` and
///           `cancelAuthorization` (v,r,s and bytes overloads). This is the authorization
///           format used by the x402 "exact" payment scheme.
///         Signatures are verified with OpenZeppelin `SignatureChecker`, so both EOAs
///         (ECDSA) and ERC-4337 smart accounts (ERC-1271) can sign.
contract SpectralToken is IERC20, IERC20Metadata, IERC20Permit, EIP712, Nonces {
    // ---------------------------------------------------------------------- constants

    uint256 private constant WAD = 1e18;

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    // ---------------------------------------------------------------------- storage

    /// @notice Account allowed to call `setStabilizer` exactly once.
    address public immutable deployer;
    /// @notice Sole minter, burner and rebaser (set once).
    address public stabilizer;
    /// @notice sUSD per share, WAD. Starts at 1e18.
    uint256 public index = WAD;

    uint256 private _totalShares;
    mapping(address => uint256) private _shares;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => mapping(bytes32 => bool)) private _authorizationUsed;

    // ---------------------------------------------------------------------- events / errors

    event StabilizerSet(address indexed stabilizer);
    event Rebased(uint256 oldIndex, uint256 newIndex, uint256 totalSupply);
    event TransferShares(address indexed from, address indexed to, uint256 shares);
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    error NotStabilizer();
    error NotDeployer();
    error StabilizerAlreadySet();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroShares();
    error InvalidIndex();
    error PermitExpired();
    error InvalidSignature();
    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error CallerMustBePayee();

    modifier onlyStabilizer() {
        if (msg.sender != stabilizer) revert NotStabilizer();
        _;
    }

    constructor() EIP712("Spectrum Agentic USD", "1") {
        deployer = msg.sender;
    }

    /// @notice Wire the stabilizer. Callable once by the deployer.
    function setStabilizer(address stabilizer_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (stabilizer_ == address(0)) revert ZeroAddress();
        if (stabilizer != address(0)) revert StabilizerAlreadySet();
        stabilizer = stabilizer_;
        emit StabilizerSet(stabilizer_);
    }

    // ---------------------------------------------------------------------- ERC-20 metadata

    function name() external pure override returns (string memory) {
        return "Spectrum Agentic USD";
    }

    function symbol() external pure override returns (string memory) {
        return "sUSD";
    }

    function decimals() external pure override returns (uint8) {
        return 18;
    }

    // ---------------------------------------------------------------------- ERC-20 views

    function totalSupply() public view override returns (uint256) {
        return Math.mulDiv(_totalShares, index, WAD);
    }

    function balanceOf(address account) public view override returns (uint256) {
        return Math.mulDiv(_shares[account], index, WAD);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    function sharesOf(address account) external view returns (uint256) {
        return _shares[account];
    }

    /// @notice Shares worth `amount` at the current index, rounded down.
    function sharesForAmount(uint256 amount) public view returns (uint256) {
        return Math.mulDiv(amount, WAD, index);
    }

    /// @notice sUSD value of `shares` at the current index, rounded down.
    function amountForShares(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, index, WAD);
    }

    // ---------------------------------------------------------------------- ERC-20 actions

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                _approve(from, msg.sender, allowed - amount);
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------- EIP-2612

    /// @inheritdoc IERC20Permit
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        permit(owner, spender, value, deadline, abi.encodePacked(r, s, v));
    }

    /// @notice EIP-2612 permit with a raw signature; accepts ERC-1271 smart-account signatures.
    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature)
        public
    {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline))
        );
        if (!SignatureChecker.isValidSignatureNow(owner, digest, signature)) revert InvalidSignature();
        _approve(owner, spender, value);
    }

    /// @inheritdoc IERC20Permit
    function nonces(address owner) public view override(IERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @inheritdoc IERC20Permit
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------- EIP-3009

    /// @notice True if `nonce` has been used or canceled by `authorizer`.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationUsed[authorizer][nonce];
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        transferWithAuthorization(from, to, value, validAfter, validBefore, nonce, abi.encodePacked(r, s, v));
    }

    /// @notice EIP-3009 transfer authorised by `from`'s signature (EOA or ERC-1271).
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) public {
        _useAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
        _transfer(from, to, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        receiveWithAuthorization(from, to, value, validAfter, validBefore, nonce, abi.encodePacked(r, s, v));
    }

    /// @notice EIP-3009 receive: like `transferWithAuthorization` but only the payee may submit,
    ///         which prevents front-running of the authorization by a third party.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) public {
        if (msg.sender != to) revert CallerMustBePayee();
        _useAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
        _transfer(from, to, value);
    }

    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        cancelAuthorization(authorizer, nonce, abi.encodePacked(r, s, v));
    }

    /// @notice Cancel an unused EIP-3009 authorization.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) public {
        if (_authorizationUsed[authorizer][nonce]) revert AuthorizationAlreadyUsed();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)));
        if (!SignatureChecker.isValidSignatureNow(authorizer, digest, signature)) revert InvalidSignature();
        _authorizationUsed[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _useAuthorization(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (_authorizationUsed[from][nonce]) revert AuthorizationAlreadyUsed();
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce)));
        if (!SignatureChecker.isValidSignatureNow(from, digest, signature)) revert InvalidSignature();
        _authorizationUsed[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
    }

    // ---------------------------------------------------------------------- stabilizer only

    /// @notice Mint `amount` sUSD (rounded down to whole shares) to `to`.
    /// @return shares Shares created.
    function mint(address to, uint256 amount) external onlyStabilizer returns (uint256 shares) {
        if (to == address(0)) revert ZeroAddress();
        shares = sharesForAmount(amount);
        if (shares == 0) revert ZeroShares();
        _totalShares += shares;
        _shares[to] += shares;
        emit TransferShares(address(0), to, shares);
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn `amount` sUSD from `from`, rounding shares up (capped at the full balance).
    /// @return shares Shares destroyed.
    function burn(address from, uint256 amount) external onlyStabilizer returns (uint256 shares) {
        shares = _sharesToDebit(from, amount);
        _shares[from] -= shares;
        _totalShares -= shares;
        emit TransferShares(from, address(0), shares);
        emit Transfer(from, address(0), amount);
    }

    /// @notice Set a new index (rebase). Bounds are enforced by the stabilizer.
    function setIndex(uint256 newIndex) external onlyStabilizer {
        if (newIndex == 0) revert InvalidIndex();
        uint256 old = index;
        index = newIndex;
        emit Rebased(old, newIndex, totalSupply());
    }

    // ---------------------------------------------------------------------- internals

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 shares = _sharesToDebit(from, amount);
        _shares[from] -= shares;
        _shares[to] += shares;
        emit TransferShares(from, to, shares);
        emit Transfer(from, to, amount);
    }

    /// @dev ceil(amount / index) shares, capped at the holder's shares when `amount` equals
    ///      (up to rounding) the whole balance, so "send everything" always works.
    function _sharesToDebit(address from, uint256 amount) private view returns (uint256 shares) {
        uint256 held = _shares[from];
        if (amount > Math.mulDiv(held, index, WAD)) revert InsufficientBalance();
        shares = Math.mulDiv(amount, WAD, index, Math.Rounding.Ceil);
        if (shares > held) shares = held;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

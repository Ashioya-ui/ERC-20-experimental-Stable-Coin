// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  SpectralToken (SPCM)
 * @notice Entropy-governed elastic token. NOT a stablecoin.
 *
 * PATCHES vs previous version:
 *   [MEDIUM] increaseAllowance / decreaseAllowance added — ERC-20 approval
 *            front-running race mitigation.
 *   [LOW]    constructor reverts on initialSupplyTokens == 0.
 */
contract SpectralToken {

    string  public constant name     = "Spectrum";
    string  public constant symbol   = "SPCM";
    uint8   public constant decimals = 18;

    uint256 public constant MAX_SUPPLY = 21_000_000 * 1e18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    address public pendingOwner;
    address public stabilizer;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event StabilizerSet(address indexed stabilizer);
    event OwnershipTransferStarted(address indexed pendingOwner);
    event OwnershipAccepted(address indexed newOwner);

    error Unauthorized();
    error MaxSupplyExceeded();
    error InsufficientBalance();
    error InsufficientAllowance();
    error AllowanceUnderflow();
    error ZeroAddress();
    error ZeroInitialSupply();

    modifier onlyOwner()      { if (msg.sender != owner)      revert Unauthorized(); _; }
    modifier onlyStabilizer() { if (msg.sender != stabilizer) revert Unauthorized(); _; }

    constructor(address _owner, uint256 initialSupplyTokens) {
        if (_owner == address(0))     revert ZeroAddress();
        if (initialSupplyTokens == 0) revert ZeroInitialSupply();   // [LOW] patch
        owner = _owner;
        uint256 genesis = initialSupplyTokens * 1e18;
        if (genesis > MAX_SUPPLY) revert MaxSupplyExceeded();
        totalSupply       = genesis;
        balanceOf[_owner] = genesis;
        emit Transfer(address(0), _owner, genesis);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice [MEDIUM] Atomic allowance increase — prevents front-running race.
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        uint256 newAllowance = allowance[msg.sender][spender] + addedValue;
        allowance[msg.sender][spender] = newAllowance;
        emit Approval(msg.sender, spender, newAllowance);
        return true;
    }

    /// @notice [MEDIUM] Atomic allowance decrease — reverts if underflow.
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        if (current < subtractedValue) revert AllowanceUnderflow();
        uint256 next = current - subtractedValue;
        allowance[msg.sender][spender] = next;
        emit Approval(msg.sender, spender, next);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function mint(address to, uint256 amount) external onlyStabilizer {
        if (totalSupply + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        totalSupply   += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyStabilizer {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        totalSupply     -= amount;
        emit Transfer(from, address(0), amount);
    }

    function setStabilizer(address _stabilizer) external onlyOwner {
        if (_stabilizer == address(0)) revert ZeroAddress();
        stabilizer = _stabilizer;
        emit StabilizerSet(_stabilizer);
    }

    function transferOwnership(address _pending) external onlyOwner {
        pendingOwner = _pending;
        emit OwnershipTransferStarted(_pending);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        owner        = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipAccepted(owner);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

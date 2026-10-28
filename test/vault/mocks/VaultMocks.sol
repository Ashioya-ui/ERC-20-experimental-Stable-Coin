// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";

/// @dev Six-decimal stand-in for USDC.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev An honest ERC-4626 vault with EIP-2612 permit on its shares, as waBasUSDC has.
contract MockVault is ERC4626, ERC20Permit {
    constructor(IERC20 asset_) ERC20("Mock Vault USDC", "mvUSDC") ERC4626(asset_) ERC20Permit("Mock Vault USDC") {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }
}

/// @dev Reports a full withdrawal but delivers one unit less than asked.
contract ShortVault is MockVault {
    constructor(IERC20 asset_) MockVault(asset_) {}

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets - 1, shares);
    }
}

/// @dev Burns more shares than the withdrawal costs, reaching into whatever else the owner holds.
contract OverburnVault is MockVault {
    uint256 public extra;

    constructor(IERC20 asset_) MockVault(asset_) {}

    function setExtra(uint256 extra_) external {
        extra = extra_;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets) + extra;
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }
}

/// @dev Calls back into the router in the middle of a withdrawal.
contract ReentrantVault is MockVault {
    VaultPayRouter public router;

    constructor(IERC20 asset_) MockVault(asset_) {}

    function setRouter(VaultPayRouter router_) external {
        router = router_;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        VaultPayRouter.PayIntent memory it;
        VaultPayRouter.Permit memory p;
        router.pay(it, "", p);
        return super.withdraw(assets, receiver, owner);
    }
}

/// @dev A smart wallet that accepts its owner's ECDSA signature through ERC-1271.
contract Mock1271Wallet is IERC1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && signer == owner
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "not the owner");
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }
}

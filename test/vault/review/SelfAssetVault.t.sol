// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A "vault" that names itself as its own asset. Withdrawing does nothing.
contract SelfAssetVault is ERC20 {
    constructor() ERC20("Self Asset Vault", "SELF") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function asset() external view returns (address) {
        return address(this);
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return 2 * assets;
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title  TestnetVault
/// @notice A plain OpenZeppelin ERC-4626 vault over testnet USDC, for the Base Sepolia dress
///         rehearsal only (Phase 4, D1): Base Sepolia has no USDC lending vault worth
///         rehearsing against. It lends nothing and earns nothing; yield is simulated by
///         transferring USDC into it. It has no owner and no knobs, unlike the test mocks,
///         whose permissionless mint, loss and liquidity switches must never reach a public
///         network. It refuses to be deployed on Base mainnet.
contract TestnetVault is ERC4626 {
    error TestnetOnly();

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {
        if (block.chainid == 8453) revert TestnetOnly();
    }
}

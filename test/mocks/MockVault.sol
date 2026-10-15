// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice OpenZeppelin ERC-4626 vault over MockUSDC with knobs for yield, loss and
///         withdrawal liquidity (tests and local deployments only).
contract MockVault is ERC4626 {
    /// @notice Max assets any owner can withdraw right now (type(uint256).max = unlimited).
    uint256 public liquidityCap = type(uint256).max;

    constructor(MockUSDC usdc) ERC20("Mock USDC Vault", "mvUSDC") ERC4626(IERC20(address(usdc))) {}

    /// @notice Interest accrues: the vault's assets grow without new shares.
    function simulateYield(uint256 assets) external {
        MockUSDC(asset()).mint(address(this), assets);
    }

    /// @notice A realised loss (bad debt, exploit): the vault's assets shrink.
    function simulateLoss(uint256 assets) external {
        MockUSDC(asset()).burn(address(this), assets);
    }

    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 m = super.maxWithdraw(owner);
        return m < liquidityCap ? m : liquidityCap;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 m = super.maxRedeem(owner);
        uint256 capShares = liquidityCap == type(uint256).max ? type(uint256).max : convertToShares(liquidityCap);
        return m < capShares ? m : capShares;
    }
}

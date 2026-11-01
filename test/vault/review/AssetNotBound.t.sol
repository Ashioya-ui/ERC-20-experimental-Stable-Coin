// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockUSDC} from "../mocks/VaultMocks.sol";

/// @dev Kept for RegressionF2.t.sol, which replaced the F-2 PoC once the asset became part of the
///      signed intent. A 1:1 vault over USDC whose owner can repoint asset(). Once repointed, it pays out a
///      lookalike token instead of USDC.
contract AssetSwitchVault is ERC20 {
    IERC20 public immutable usdc;
    MockUSDC public immutable lookalike;
    address public immutable owner;
    address public reported;

    constructor(IERC20 usdc_, MockUSDC lookalike_, address owner_) ERC20("Switch Vault USDC", "swUSDC") {
        usdc = usdc_;
        lookalike = lookalike_;
        owner = owner_;
        reported = address(usdc_);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setReported(address asset_) external {
        require(msg.sender == owner, "not the owner");
        reported = asset_;
    }

    function asset() external view returns (address) {
        return reported;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        require(usdc.transferFrom(msg.sender, address(this), assets), "transfer failed");
        _mint(receiver, assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address holder) external returns (uint256) {
        if (msg.sender != holder) _spendAllowance(holder, msg.sender, assets);
        _burn(holder, assets);
        if (reported == address(usdc)) require(usdc.transfer(receiver, assets), "transfer failed");
        else lookalike.mint(receiver, assets);
        return assets;
    }
}

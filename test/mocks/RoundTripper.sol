// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";
import {SpectralToken} from "../../src/SpectralToken.sol";

/// @notice Mints and redeems in one transaction, as a flash-loan-funded attacker would.
contract RoundTripper {
    function run(IERC20 usdc, SpectralStabilizer stabilizer, SpectralToken token, uint256 assets) external {
        usdc.approve(address(stabilizer), assets);
        stabilizer.mint(assets, address(this), 0);
        stabilizer.redeem(token.balanceOf(address(this)), address(this), 0);
    }
}

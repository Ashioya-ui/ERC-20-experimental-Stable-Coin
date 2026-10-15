// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title  WrappedSUSD (wsUSD)
/// @notice Non-rebasing ERC-4626 wrapper around sUSD, for AMMs, lending markets and bridges.
///
/// @dev    sUSD rebases (every balance moves with the index). Contracts that keep their own
///         accounting of token balances break on rebasing tokens. A Uniswap v4 PoolManager
///         holding raw sUSD would (a) let anyone capture its positive rebases by calling
///         `rebase()` between `sync` and `settle`, and (b) become short of sUSD after a
///         negative rebase, so the last LPs could not withdraw. Pools must therefore pair
///         wsUSD, never raw sUSD.
///
///         wsUSD balances are fixed. Its price in sUSD (`convertToAssets(1e18)`) rises with
///         positive rebases and falls if a reserve loss is absorbed, exactly like the sUSD
///         index (up to rounding). This is the stETH / wstETH pattern, built on
///         OpenZeppelin's ERC-4626 with its virtual-share protection against the
///         first-depositor inflation attack. Deployers should still seed the wrapper with a
///         small deposit sent to a dead address.
contract WrappedSUSD is ERC4626 {
    constructor(IERC20 susd) ERC20("Wrapped Spectrum Agentic USD", "wsUSD") ERC4626(susd) {}
}

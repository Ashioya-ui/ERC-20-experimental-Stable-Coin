// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Calls another contract and records what that call cost, measured inside the EVM.
/// @dev    Used by the benchmarks. Measuring from inside a contract keeps the number the same
///         in normal and `--isolate` runs, and it is the cost a real caller pays, including
///         the CALL itself. The meter acts as the user, so it holds the balances it needs.
contract GasMeter {
    uint256 public lastGas;

    error CallFailed(bytes reason);

    function measure(address target, bytes calldata data) external returns (bytes memory out) {
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = target.call(data);
        lastGas = g - gasleft();
        if (!ok) revert CallFailed(ret);
        out = ret;
    }
}

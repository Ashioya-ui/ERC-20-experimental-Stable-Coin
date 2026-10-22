// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISpectralEntropyOracle} from "../../src/interfaces/ISpectralEntropyOracle.sol";

/// @notice Stands in for the hook and measures `record()` from inside the EVM.
/// @dev    Phase 4, A8. Measuring with `gasleft()` in a test body gives different numbers in
///         normal and `--isolate` runs, because isolation turns each top-level call into its
///         own transaction and so adds intrinsic gas to the measured frame. `vm.lastCallGas()`
///         cannot be used with this toolchain: forge-std v1.17's `Gas` struct has six fields
///         and Foundry 1.5.1's cheatcode returns five, so decoding it reverts. Measuring from
///         inside a contract call is unaffected by either, and matches what the real hook pays.
contract OracleGasMeter {
    ISpectralEntropyOracle public immutable oracle;
    uint256 public lastGas;

    constructor(ISpectralEntropyOracle oracle_) {
        oracle = oracle_;
    }

    function record(int256 amount) external {
        uint256 g = gasleft();
        oracle.record(amount);
        lastGas = g - gasleft();
    }
}

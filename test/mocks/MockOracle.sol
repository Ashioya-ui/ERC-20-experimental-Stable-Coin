// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISpectralEntropyOracle} from "../../src/interfaces/ISpectralEntropyOracle.sol";

/// @notice Entropy source with a settable value, plus failure modes for hook tests.
contract MockOracle is ISpectralEntropyOracle {
    uint256 public h = 0.5e18;
    bool public shouldRevert;
    uint256 public burnGas;
    int256 public recorded;
    uint256 public calls;

    function setEntropy(uint256 h_) external {
        h = h_;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function setBurnGas(uint256 g) external {
        burnGas = g;
    }

    function record(int256 amount) external override {
        if (shouldRevert) revert("oracle down");
        uint256 start = gasleft();
        while (start - gasleft() < burnGas) {}
        recorded += amount;
        calls += 1;
    }

    function smoothedEntropy() external view override returns (uint256) {
        return h;
    }

    function instantEntropy() external view override returns (uint256) {
        return h;
    }
}

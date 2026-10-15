// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  ISpectralEntropyOracle
/// @notice Read/write surface of the Walsh-Hadamard spectral entropy oracle.
interface ISpectralEntropyOracle {
    /// @notice Record one swap's notional (in sUSD wei). Only the registered hook may call.
    function record(uint256 amount) external;

    /// @notice Smoothed spectral entropy in WAD, in [0, 1e18]. Returns the neutral value
    ///         during warm-up (fewer than 8 recorded blocks) and when the data is stale.
    function smoothedEntropy() external view returns (uint256);

    /// @notice Entropy of the current 8-block window (including the open block), in WAD.
    ///         Returns the neutral value during warm-up.
    function instantEntropy() external view returns (uint256);
}

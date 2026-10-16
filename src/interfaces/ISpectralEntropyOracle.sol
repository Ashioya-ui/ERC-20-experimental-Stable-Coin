// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  ISpectralEntropyOracle
/// @notice Read/write surface of the Walsh-Hadamard spectral entropy oracle.
interface ISpectralEntropyOracle {
    /// @notice Record one swap's *signed* delta of the measured currency (sUSD wei): negative
    ///         when the pool receives it, positive when it pays it out. The oracle keeps the
    ///         net per block, so a round trip inside one block nets out. Only the hook may call.
    function record(int256 amount) external;

    /// @notice Smoothed spectral entropy in WAD, in [0, 1e18]. Returns the neutral value
    ///         during warm-up (fewer than 8 recorded blocks) and when the data is stale.
    function smoothedEntropy() external view returns (uint256);

    /// @notice Entropy of the current 8-block window (including the open block), in WAD.
    ///         Returns the neutral value during warm-up.
    function instantEntropy() external view returns (uint256);
}

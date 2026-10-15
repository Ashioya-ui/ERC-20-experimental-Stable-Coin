// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SpectralMath} from "../../src/libraries/SpectralMath.sol";
import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";
import {SpectralToken} from "../../src/SpectralToken.sol";
import {AutonomousTreasury} from "../../src/AutonomousTreasury.sol";
import {ISpectralEntropyOracle} from "../../src/interfaces/ISpectralEntropyOracle.sol";

/// @notice Exposes SpectralMath's internal functions.
contract MathHarness {
    function fwht8(int256[8] memory x) external pure returns (int256[8] memory) {
        SpectralMath.fwht8(x);
        return x;
    }

    function lnWad(uint256 x) external pure returns (int256) {
        return SpectralMath.lnWad(x);
    }

    function spectralEntropy8(uint256[8] memory v) external pure returns (uint256) {
        return SpectralMath.spectralEntropy8(v);
    }

    function entropyGas(uint256[8] memory v) external view returns (uint256 gasUsed, uint256 h) {
        uint256 g = gasleft();
        h = SpectralMath.spectralEntropy8(v);
        gasUsed = g - gasleft();
    }
}

/// @notice Exposes the stabilizer's churn-budget arithmetic.
contract StabilizerHarness is SpectralStabilizer {
    constructor(
        SpectralToken token_,
        AutonomousTreasury treasury_,
        ISpectralEntropyOracle oracle_,
        address admin,
        uint256 bootstrapCap_
    ) SpectralStabilizer(token_, treasury_, oracle_, admin, bootstrapCap_) {}

    function exposedChurnAfter(uint256 oldIndex, uint256 newIndex)
        external
        view
        returns (bool ok, uint256 len, uint256 range)
    {
        return _churnAfter(oldIndex, newIndex);
    }

    function exposedCommitChurn(uint256 oldIndex, uint256 newIndex) external {
        _commitChurn(oldIndex, newIndex);
    }
}

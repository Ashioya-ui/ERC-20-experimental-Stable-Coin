// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SpectralStabilizer} from "./SpectralStabilizer.sol";
import {SpectralToken} from "./SpectralToken.sol";
import {AutonomousTreasury} from "./AutonomousTreasury.sol";
import {ISpectralEntropyOracle} from "./interfaces/ISpectralEntropyOracle.sol";

/// @title  SpectrumLens
/// @notice Read-only convenience views over a Spectrum deployment: quotes, ratios and the room
///         left under each cap.
///
/// @dev    These views were part of SpectralStabilizer until Phase 4 (B6). They are derived
///         entirely from public state, they are never called by the protocol itself, and
///         keeping them out leaves the stabilizer comfortably under the 24,576-byte limit. The
///         lens holds no state and no privileges; deploying another one is harmless.
contract SpectrumLens {
    uint256 private constant WAD = 1e18;

    SpectralStabilizer public immutable stabilizer;
    SpectralToken public immutable token;
    AutonomousTreasury public immutable treasury;
    ISpectralEntropyOracle public immutable oracle;
    /// @notice 10^(18 - asset decimals), as the stabilizer uses it.
    uint256 public immutable scale;

    constructor(SpectralStabilizer stabilizer_) {
        stabilizer = stabilizer_;
        token = stabilizer_.token();
        treasury = stabilizer_.treasury();
        oracle = stabilizer_.oracle();
        scale = stabilizer_.scale();
    }

    /// @notice Conservative reserve value in sUSD wei.
    function reserveValue() public view returns (uint256) {
        return stabilizer.reserveValue();
    }

    /// @notice Reserve value / supply in WAD (max uint if supply is zero).
    function reserveRatio() external view returns (uint256) {
        uint256 supply = token.totalSupply();
        if (supply == 0) return type(uint256).max;
        return Math.mulDiv(reserveValue(), WAD, supply);
    }

    /// @notice Reserve value above supply, in sUSD wei (0 if under-reserved).
    function surplus() external view returns (uint256) {
        uint256 r = reserveValue();
        uint256 s = token.totalSupply();
        return r > s ? r - s : 0;
    }

    /// @notice How far a rebase could raise supply right now, ignoring the per-step limit, the
    ///         hourly interval and the churn budget: min(reserve / (1 + buffer(H)),
    ///         reserve - protocolCapital) - supply, or 0. In sUSD wei.
    function distributable() external view returns (uint256) {
        uint256 r = reserveValue();
        uint256 s = token.totalSupply();
        uint256 maxSupply = Math.mulDiv(r, WAD, WAD + stabilizer.bufferRate(oracle.smoothedEntropy()));
        uint256 capital = stabilizer.protocolCapital();
        uint256 uncommitted = r > capital ? r - capital : 0;
        if (uncommitted < maxSupply) maxSupply = uncommitted;
        return maxSupply > s ? maxSupply - s : 0;
    }

    /// @notice Net expansion still available in the current epoch, in sUSD wei.
    function expansionRemaining() external view returns (uint256) {
        uint256 h = oracle.smoothedEntropy();
        bool expired = block.timestamp >= uint256(stabilizer.epochStart()) + stabilizer.EPOCH();
        uint256 base = expired ? token.totalSupply() : stabilizer.epochSupply();
        uint256 used = expired ? 0 : stabilizer.mintedInEpoch();
        uint256 cap = Math.max(stabilizer.bootstrapCap(), Math.mulDiv(base, stabilizer.expansionCapRate(h), WAD));
        return cap > used ? cap - used : 0;
    }

    /// @notice Minting room left under the supply cap, in sUSD wei.
    function supplyCapRemaining() external view returns (uint256) {
        uint256 supply = token.totalSupply();
        uint256 cap = stabilizer.supplyCap();
        return cap > supply ? cap - supply : 0;
    }

    /// @notice Approximate sUSD out for `assets` in (ignores vault rounding and entry fees).
    function quoteMint(uint256 assets) external view returns (uint256 out, uint256 fee) {
        uint256 credited = assets * scale;
        fee = Math.mulDiv(credited, stabilizer.mintFeeRate(oracle.smoothedEntropy()), WAD, Math.Rounding.Ceil);
        out = credited - fee;
    }

    /// @notice Collateral out for redeeming `amount` sUSD.
    function quoteRedeem(uint256 amount) external view returns (uint256 assetsOut, uint256 fee) {
        fee = Math.mulDiv(amount, stabilizer.redeemFeeRate(oracle.smoothedEntropy()), WAD, Math.Rounding.Ceil);
        assetsOut = (amount - fee) / scale;
    }

    /// @notice Assets the treasury can pay out right now (idle + the vault's `maxWithdraw`).
    function liquidAssets() external view returns (uint256) {
        return treasury.liquidAssets();
    }
}

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
    function expansionRemaining() public view returns (uint256) {
        uint256 h = oracle.smoothedEntropy();
        bool expired = block.timestamp >= uint256(stabilizer.epochStart()) + stabilizer.EPOCH();
        uint256 base = expired ? token.totalSupply() : stabilizer.epochSupply();
        uint256 used = expired ? 0 : stabilizer.mintedInEpoch();
        uint256 cap = Math.max(stabilizer.bootstrapCap(), Math.mulDiv(base, stabilizer.expansionCapRate(h), WAD));
        return cap > used ? cap - used : 0;
    }

    /// @notice Minting room left under the supply cap, in sUSD wei.
    function supplyCapRemaining() public view returns (uint256) {
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

    // ------------------------------------------------------------------ integrators at scale
    //
    // Phase 5 (P5-02). `redeem` is all-or-nothing, and a card program or exchange that settles
    // around the clock needs to know what fits before it sends a transaction, above all during
    // a liquidity crunch, when a redemption sized to the balance reverts.

    /// @notice The most sUSD `owner` can redeem in one call right now: the whole balance, or
    ///         less when the treasury cannot pay that much at once (idle funds plus the vault's
    ///         `maxWithdraw`). Accounts for a loss not yet absorbed (`redeem` syncs first), the
    ///         fee at the current H and the minimum partial redemption. 0 if nothing fits.
    function maxRedeem(address owner) external view returns (uint256) {
        uint256 balance = _balanceAfterSync(owner);
        // A guard for an empty account, not a balance check anyone can game (a view).
        // slither-disable-next-line incorrect-equality
        if (balance == 0) return 0;
        uint256 rate = stabilizer.redeemFeeRate(oracle.smoothedEntropy());
        // A redemption of `a` pays (a - ceil(a * rate / WAD)) / scale, which must not exceed
        // the liquid assets L, i.e. a - ceil(a * rate / WAD) <= t with t = (L + 1) * scale - 1.
        // The left side never decreases in `a` and lies in (a (1 - r) - 1, a (1 - r)], so the
        // largest such `a` is below (t + 1) / (1 - r) + 1; search down from there (at most a
        // few steps, since 1 / (1 - r) < 1.002).
        uint256 t = (treasury.liquidAssets() + 1) * scale - 1;
        uint256 a = Math.min(balance, Math.mulDiv(t + 1, WAD, WAD - rate) + 1);
        while (a > 0 && _netOf(a, rate) > t) {
            --a;
        }
        // A full exit is allowed below the minimum; a partial one is not. Either must pay out
        // at least one unit of the asset, as `redeem` requires (a guard, in a view).
        // slither-disable-next-line incorrect-equality
        if (_netOf(a, rate) / scale == 0) return 0;
        if (a < balance && a < stabilizer.minAmount()) return 0;
        return a;
    }

    /// @notice The most reserve-asset units one `mint` can take right now under the daily
    ///         expansion cap and the supply cap, at the current H. 0 while minting is paused, and
    ///         0 when even that much would be below the minimum mint. Vault rounding can only
    ///         lower what a mint is credited, so a mint of this size fits.
    function maxMintAssets() external view returns (uint256) {
        if (stabilizer.paused()) return 0;
        uint256 room = Math.min(expansionRemaining(), supplyCapRemaining());
        uint256 rate = stabilizer.mintFeeRate(oracle.smoothedEntropy());
        // Credited c pays out c - ceil(c * rate / WAD) <= c (1 - rate); c <= room / (1 - rate)
        // keeps that within the room.
        // Dividing to whole reserve-asset units first is deliberate: `mint` takes units, not sUSD
        // wei, so the truncated figure is the real ceiling and rounding down keeps it inside the
        // room. Scaling it back up re-expresses that same truncated amount for the minimum check,
        // so no precision is lost that the caller could have used.
        // slither-disable-next-line divide-before-multiply
        uint256 assets = Math.mulDiv(room, WAD, WAD - rate) / scale;
        return assets * scale < stabilizer.minAmount() ? 0 : assets;
    }

    /// @notice What the treasury can pay out right now as a share of supply, WAD (max uint if
    ///         supply is zero). The run-readiness number to alert on at scale.
    function liquidityRatio() external view returns (uint256) {
        uint256 supply = token.totalSupply();
        if (supply == 0) return type(uint256).max;
        return Math.mulDiv(treasury.liquidAssets() * scale, WAD, supply);
    }

    /// @dev `owner`'s balance after the loss absorption `redeem` would run first.
    function _balanceAfterSync(address owner) private view returns (uint256) {
        uint256 r = reserveValue();
        if (r >= token.totalSupply()) return token.balanceOf(owner);
        uint256 newIndex = Math.mulDiv(r, WAD, token.totalShares());
        if (newIndex == 0) newIndex = 1;
        return Math.mulDiv(token.sharesOf(owner), newIndex, WAD);
    }

    /// @dev What a redemption of `a` keeps after the fee, in sUSD wei.
    function _netOf(uint256 a, uint256 rate) private pure returns (uint256) {
        return a - Math.mulDiv(a, rate, WAD, Math.Rounding.Ceil);
    }
}

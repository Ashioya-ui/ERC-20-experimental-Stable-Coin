// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SpectralMath} from "./libraries/SpectralMath.sol";
import {ISpectralEntropyOracle} from "./interfaces/ISpectralEntropyOracle.sol";

/// @title  SpectralEntropyOracle
/// @notice Walsh-Hadamard spectral entropy H_WHT of recent sUSD swap flow.
///
/// @dev    Window. A ring buffer of the last 8 *blocks* of activity. All swaps in one block
///         are summed into one slot, so filling the window takes 8 distinct blocks, not 8
///         swaps in one transaction. Swaps below `minObservation` are ignored (dust filter).
///
///         Signal. H_WHT in [0, 1e18] is the normalised Shannon entropy of the Walsh power
///         spectrum of the window, oldest block first (see SpectralMath). A homogeneous flow
///         (every block about the same size) gives H near 0. A flow dominated by one block
///         (a whale or MEV spike) gives H near 1. Consumers should treat LOW H as calm,
///         organic flow and HIGH H as concentrated, spiky flow.
///
///         Smoothing. When the first swap of a new block arrives, the entropy of the full
///         window (8 closed blocks) is folded into an exponential moving average with weight
///         `emaAlpha`. Consumers read the EMA through `smoothedEntropy()`.
///
///         Fallbacks. `NEUTRAL_ENTROPY` (0.5) is returned until 8 blocks have been seen, and
///         whenever no swap has been recorded for `staleAfter` seconds.
///
///         Trust. Only the hook may write, and the hook can be set exactly once. After that
///         the owner has no power over the data. (The previous SPCM oracle's red-team
///         finding CRITICAL-1, an owner able to spoof entropy, stays closed.)
contract SpectralEntropyOracle is ISpectralEntropyOracle, Ownable2Step {
    /// @notice Window length (number of block slots).
    uint256 public constant WINDOW = 8;
    /// @notice Value reported when no meaningful signal exists.
    uint256 public constant NEUTRAL_ENTROPY = 0.5e18;

    /// @notice Smallest swap notional (sUSD wei) that is recorded.
    uint256 public immutable minObservation;
    /// @notice EMA weight of the newest window entropy, WAD (e.g. 0.25e18).
    uint256 public immutable emaAlpha;
    /// @notice Seconds without any recorded swap after which the signal is neutral.
    uint256 public immutable staleAfter;

    /// @notice The only address allowed to call `record` (set once).
    address public hook;

    uint128[8] private _volumes; // per-block summed notional, ring buffer
    uint8 public head; // slot of the newest block
    uint8 public filled; // number of slots holding data (<= 8)
    uint64 public currentBlock; // block number of _volumes[head]
    uint64 public lastObservationTime; // timestamp of the latest recorded swap
    uint256 private _ema; // smoothed entropy, WAD

    event HookSet(address indexed hook);
    event Observed(uint256 amount, uint256 indexed blockNumber, uint8 slot);
    event WindowClosed(uint256 indexed blockNumber, uint256 entropy, uint256 ema);
    event DustIgnored(uint256 amount);

    error NotHook();
    error ZeroAddress();
    error HookAlreadySet();
    error InvalidParameter();

    /// @param owner_          Account allowed to call `setHook` once (Ownable2Step).
    /// @param minObservation_ Dust threshold in sUSD wei, e.g. 10e18.
    /// @param emaAlpha_       EMA weight in WAD, 0 < alpha <= 1e18.
    /// @param staleAfter_     Staleness horizon in seconds, > 0.
    constructor(address owner_, uint256 minObservation_, uint256 emaAlpha_, uint256 staleAfter_)
        Ownable(owner_)
    {
        if (emaAlpha_ == 0 || emaAlpha_ > 1e18 || staleAfter_ == 0) revert InvalidParameter();
        minObservation = minObservation_;
        emaAlpha = emaAlpha_;
        staleAfter = staleAfter_;
        _ema = NEUTRAL_ENTROPY;
    }

    // ----------------------------------------------------------------------- admin

    /// @notice Register the Uniswap v4 hook. Callable once; irreversible.
    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
        emit HookSet(hook_);
    }

    // ----------------------------------------------------------------------- write

    /// @inheritdoc ISpectralEntropyOracle
    function record(uint256 amount) external override {
        if (msg.sender != hook) revert NotHook();
        if (amount < minObservation || amount == 0) {
            emit DustIgnored(amount);
            return;
        }
        // Saturating casts: the values are clamped to uint128 first.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 a = amount > type(uint128).max ? type(uint128).max : uint128(amount);

        if (filled != 0 && block.number == currentBlock) {
            uint256 sum = uint256(_volumes[head]) + a;
            // forge-lint: disable-next-line(unsafe-typecast)
            _volumes[head] = sum > type(uint128).max ? type(uint128).max : uint128(sum);
        } else {
            // A new block starts: the previous block is now closed.
            if (filled == WINDOW) _foldWindowIntoEma();
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 next = filled == 0 ? 0 : uint8((uint256(head) + 1) % WINDOW); // < 8
            _volumes[next] = a;
            head = next;
            if (filled < WINDOW) filled += 1;
            // forge-lint: disable-next-line(unsafe-typecast)
            currentBlock = uint64(block.number);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        lastObservationTime = uint64(block.timestamp);
        emit Observed(amount, block.number, head);
    }

    function _foldWindowIntoEma() private {
        uint256 h = SpectralMath.spectralEntropy8(_chronological());
        uint256 e = _ema;
        // e += alpha * (h - e), written without signed arithmetic
        e = h >= e ? e + ((h - e) * emaAlpha) / 1e18 : e - ((e - h) * emaAlpha) / 1e18;
        _ema = e;
        emit WindowClosed(currentBlock, h, e);
    }

    // ----------------------------------------------------------------------- read

    /// @inheritdoc ISpectralEntropyOracle
    function smoothedEntropy() external view override returns (uint256) {
        if (filled < WINDOW || isStale()) return NEUTRAL_ENTROPY;
        return _ema;
    }

    /// @inheritdoc ISpectralEntropyOracle
    function instantEntropy() external view override returns (uint256) {
        if (filled < WINDOW) return NEUTRAL_ENTROPY;
        return SpectralMath.spectralEntropy8(_chronological());
    }

    /// @notice Raw EMA state (no warm-up or staleness substitution).
    function rawEma() external view returns (uint256) {
        return _ema;
    }

    /// @notice True if no swap has been recorded for `staleAfter` seconds.
    function isStale() public view returns (bool) {
        return block.timestamp > uint256(lastObservationTime) + staleAfter;
    }

    /// @notice The window, oldest block first. Unfilled slots are zero.
    function window() external view returns (uint256[8] memory) {
        return _chronological();
    }

    function _chronological() private view returns (uint256[8] memory v) {
        uint256 n = filled;
        if (n == 0) return v;
        // newest at `head`; oldest at head - (n-1)
        for (uint256 i; i < n; ++i) {
            uint256 slot = (uint256(head) + WINDOW - (n - 1) + i) % WINDOW;
            v[WINDOW - n + i] = _volumes[slot];
        }
    }
}

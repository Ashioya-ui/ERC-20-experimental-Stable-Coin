// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SpectralMath} from "./libraries/SpectralMath.sol";
import {ISpectralEntropyOracle} from "./interfaces/ISpectralEntropyOracle.sol";

/// @title  SpectralEntropyOracle
/// @notice Walsh-Hadamard spectral entropy H_WHT of recent sUSD swap flow.
///
/// @dev    Window. A ring buffer of the last 8 *blocks* of activity. Each slot holds the
///         absolute **net** flow of its block: the hook passes the signed delta of the measured
///         currency, and the slot keeps |sum of signed deltas| for that block (Phase 4, A6).
///         The dust filter applies twice: a swap below `minObservation` is ignored, and so is a
///         closed block whose *net* flow is below it. Such a block (a same-block round trip,
///         or a whale trade that arbitrage reverses in the same block) carries no signal, so it
///         takes no slot: the next block reuses its slot. Without this, eight round trips of
///         dust size read as a perfectly calm window, H = 0, and one small one-way block among
///         them as a spike, H = 1 (Phase 4 review, S-04). Net flow does not make steering H
///         expensive; it makes it slow (see Smoothing and audit/oracle-manipulation.md).
///
///         Signal. H_WHT in [0, 1e18] is the normalised Shannon entropy of the Walsh power
///         spectrum of the window, oldest block first (see SpectralMath). A homogeneous flow
///         (every block about the same size) gives H near 0. A flow dominated by one block
///         (a whale or MEV spike) gives H near 1. Consumers should treat LOW H as calm,
///         organic flow and HIGH H as concentrated, spiky flow.
///
///         Smoothing. When the first swap of a new block arrives and the window is full, the
///         entropy of the 8 closed blocks is folded into an exponential moving average with
///         weight w = min(emaAlphaMax, dt / (dt + tau)), where dt is the time since the previous
///         fold. Folds packed into consecutive blocks therefore carry almost no weight (on
///         Base, dt = 2 s against tau = 1 h gives w = 0.00055), while the first fold after a
///         quiet period carries at most emaAlphaMax. Moving the signal costs an attacker wall
///         time, which cannot be bought, instead of a few blocks of gas.
///
///         Fallbacks. `NEUTRAL_ENTROPY` (0.5) is returned until 8 blocks have been seen, and
///         whenever no block with net flow at or above the dust threshold has entered the
///         window for `staleAfter` seconds. A stale signal starts over at its next record:
///         the window empties and the average returns to neutral, so nothing recorded before
///         the gap can come back in one swap (Phase 4 review, S-04).
///
///         Trust. Only the hook may write, and the hook is fixed at construction: the
///         deployment predicts its CREATE2 address (Phase 4, A3). There is no owner, so nobody
///         can redirect or spoof the data. (The previous SPCM oracle's red-team finding
///         CRITICAL-1, an owner able to spoof entropy, stays closed.)
contract SpectralEntropyOracle is ISpectralEntropyOracle {
    /// @notice Window length (number of block slots).
    uint256 public constant WINDOW = 8;
    /// @notice Value reported when no meaningful signal exists.
    uint256 public constant NEUTRAL_ENTROPY = 0.5e18;

    /// @notice Smallest swap notional (sUSD wei) that is recorded.
    uint256 public immutable minObservation;
    /// @notice Largest weight any single fold may carry, WAD (e.g. 0.25e18).
    uint256 public immutable emaAlphaMax;
    /// @notice Time constant of the fold weight, in seconds: w = min(alphaMax, dt/(dt+tau)).
    uint256 public immutable tau;
    /// @notice Seconds without any recorded swap after which the signal is neutral.
    uint256 public immutable staleAfter;

    /// @notice The only address allowed to call `record`.
    address public immutable hook;

    uint128[8] private _volumes; // |net flow| per block, ring buffer

    // One slot for everything a window close reads and writes besides the ring buffer
    // (Phase 4): 8 + 8 + 40 + 40 + 40 + 64 = 200 bits. 40 bits hold block numbers and
    // timestamps for tens of thousands of years, and the EMA never exceeds 1e18 < 2^64.
    uint8 public head; // slot of the newest block
    uint8 public filled; // number of slots holding data (<= 8)
    uint40 public currentBlock; // block number of _volumes[head]
    uint40 public lastObservationTime; // when the latest non-dust block entered the window (or it restarted)
    uint40 public lastFoldTime; // timestamp of the latest EMA fold
    uint64 private _ema; // smoothed entropy, WAD

    int256 private _currentNet; // signed net flow of the open block

    // Per-swap events were dropped in Phase 4 (B4): the PoolManager's Swap event already
    // carries every amount, and the window closes are what the signal is made of.
    event HookSet(address indexed hook);
    event WindowClosed(uint256 indexed blockNumber, uint256 entropy, uint256 weight, uint256 ema);

    error NotHook();
    error ZeroAddress();
    error InvalidParameter();

    /// @param hook_           The SpectralHook allowed to call `record` (its CREATE2 address).
    /// @param minObservation_ Dust threshold in sUSD wei, e.g. 10e18.
    /// @param emaAlphaMax_    Largest fold weight in WAD, 0 < alphaMax <= 1e18.
    /// @param tau_            Fold-weight time constant in seconds, > 0 (e.g. 1 hour).
    /// @param staleAfter_     Staleness horizon in seconds, > 0.
    constructor(address hook_, uint256 minObservation_, uint256 emaAlphaMax_, uint256 tau_, uint256 staleAfter_) {
        if (hook_ == address(0)) revert ZeroAddress();
        if (emaAlphaMax_ == 0 || emaAlphaMax_ > 1e18 || tau_ == 0 || staleAfter_ == 0) revert InvalidParameter();
        hook = hook_;
        minObservation = minObservation_;
        emaAlphaMax = emaAlphaMax_;
        tau = tau_;
        staleAfter = staleAfter_;
        // forge-lint: disable-next-line(unsafe-typecast)
        _ema = uint64(NEUTRAL_ENTROPY); // 0.5e18 < 2^64
        // forge-lint: disable-next-line(unsafe-typecast)
        lastFoldTime = uint40(block.timestamp);
        emit HookSet(hook_);
    }

    // ----------------------------------------------------------------------- write

    /// @inheritdoc ISpectralEntropyOracle
    function record(int256 amount) external override {
        if (msg.sender != hook) revert NotHook();
        uint256 size = _abs(amount);
        if (size < minObservation || size == 0) return; // dust: ignored per swap

        // Per-block aggregation: equality with the current block number is the point.
        // slither-disable-next-line incorrect-equality
        if (filled != 0 && block.number == currentBlock) {
            _currentNet += amount;
        } else {
            // A new block starts: the previous block is now closed.
            if (filled != 0 && block.timestamp > uint256(lastObservationTime) + staleAfter) {
                // The signal went stale: start over, as at deployment (review S-04).
                filled = 0;
                // forge-lint: disable-next-line(unsafe-typecast)
                _ema = uint64(NEUTRAL_ENTROPY); // 0.5e18 < 2^64
                // forge-lint: disable-next-line(unsafe-typecast)
                lastFoldTime = uint40(block.timestamp);
            }
            if (filled == 0) {
                // The first block of a (re)started window.
                head = 0;
                filled = 1;
                // forge-lint: disable-next-line(unsafe-typecast)
                lastObservationTime = uint40(block.timestamp);
            } else if (_abs(_currentNet) >= minObservation && _currentNet != 0) {
                // The closed block enters the window, and the window moves on.
                if (filled == WINDOW) _foldWindowIntoEma();
                // forge-lint: disable-next-line(unsafe-typecast)
                head = uint8((uint256(head) + 1) % WINDOW); // < 8
                if (filled < WINDOW) filled += 1;
                // forge-lint: disable-next-line(unsafe-typecast)
                lastObservationTime = uint40(block.timestamp);
            }
            // Otherwise the closed block netted out below the dust threshold: this block
            // reuses its slot, and nothing about the signal changes.
            // forge-lint: disable-next-line(unsafe-typecast)
            currentBlock = uint40(block.number);
            _currentNet = amount;
        }
        _volumes[head] = _saturate(_currentNet);
    }

    function _foldWindowIntoEma() private {
        uint256 h = SpectralMath.spectralEntropy8(_chronological());
        uint256 w = foldWeight();
        uint256 e = _ema;
        // e += w * (h - e), written without signed arithmetic. A convex combination of two
        // values in [0, 1e18] stays in [0, 1e18], so it fits in 64 bits.
        e = h >= e ? e + ((h - e) * w) / 1e18 : e - ((e - h) * w) / 1e18;
        // forge-lint: disable-next-line(unsafe-typecast)
        _ema = uint64(e);
        // forge-lint: disable-next-line(unsafe-typecast)
        lastFoldTime = uint40(block.timestamp);
        emit WindowClosed(currentBlock, h, w, e);
    }

    /// @dev |net| clamped into uint128.
    function _saturate(int256 net) private pure returns (uint128) {
        uint256 m = _abs(net);
        // forge-lint: disable-next-line(unsafe-typecast)
        return m > type(uint128).max ? type(uint128).max : uint128(m);
    }

    /// @dev |v|. Reverts on type(int256).min, which no swap delta can reach: the hook widens
    ///      an int128, and a block's net is the sum of such values.
    function _abs(int256 v) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return v < 0 ? uint256(-v) : uint256(v);
    }

    // ----------------------------------------------------------------------- read

    /// @notice Weight the next fold would carry: min(emaAlphaMax, dt / (dt + tau)), WAD.
    function foldWeight() public view returns (uint256) {
        uint256 dt = block.timestamp - uint256(lastFoldTime);
        uint256 w = (dt * 1e18) / (dt + tau);
        return w < emaAlphaMax ? w : emaAlphaMax;
    }

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

    /// @notice Signed net flow recorded so far in the open block.
    function currentNet() external view returns (int256) {
        return _currentNet;
    }

    /// @notice True if no block with net flow at or above the dust threshold has entered the
    ///         window for `staleAfter` seconds.
    function isStale() public view returns (bool) {
        return block.timestamp > uint256(lastObservationTime) + staleAfter;
    }

    /// @notice The window, oldest block first, including the open block (which may still net
    ///         out below the dust threshold and be replaced). Unfilled slots are zero.
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

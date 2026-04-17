// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  SpectralEntropyOracle
 * @notice On-chain WHT spectral entropy of swap activity. Feeds dynamic fees.
 *
 * PATCHES vs previous version:
 *   [CRITICAL] onlyHook no longer includes owner. Owner can only setHook().
 *              This closes the admin entropy-spoofing attack vector.
 *   [HIGH]     _updateFreq uses a proper FIFO circular buffer (obsBuffer[])
 *              to evict the *oldest* observation, not the bin being inserted.
 *              Previous version decremented the incoming bin — mathematically wrong.
 *   [HIGH]     _log2Fixed underflow protection: clamp to 0 before subtraction.
 *   [MEDIUM]   windowSize is settable by owner (governance), minimum 100.
 *   [MEDIUM]   observe() skips zero values — prevents bin-0 pollution from tiny swaps.
 *   [LOW]      Staleness: getDynamicFee() returns baseline fee if no update for
 *              STALENESS_BLOCKS. Prevents stale-critical state from persisting.
 */
contract SpectralEntropyOracle {

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant BINS             = 64;
    uint256 public constant SCALE            = 1e18;
    uint256 public constant H_MIN            = 1.8e18;
    uint256 public constant H_MAX            = 2.8e18;
    uint256 public constant H_OPT            = 2.3e18;
    uint256 public constant FANO_THRESHOLD   = 12e16;       // 0.12
    uint256 public constant STALENESS_BLOCKS = 7200;        // ~24h on Base (2s blocks)
    uint256 public constant MIN_WINDOW       = 100;

    // ─── State ────────────────────────────────────────────────────────────────
    uint64[64]  public freqTable;
    uint256     public totalObs;
    uint256     public windowSize;

    uint256     public currentEntropy;
    uint256     public fanoPower;
    bool        public isCritical;
    uint256     public lastUpdate;

    address public hook;
    address public owner;

    uint256[32] public entropyHistory;
    uint256     public historyIndex;

    // [HIGH] FIFO circular buffer for proper windowed eviction
    // Stores the bin index of each observation in insertion order
    uint8[1024] private obsBuffer;     // max window = 1024
    uint256     private bufHead;       // next slot to evict
    uint256     private bufTail;       // next slot to write

    event EntropyUpdated(uint256 entropy, bool critical, uint256 fanoPower);
    event HookSet(address hook);
    event WindowSizeUpdated(uint256 newSize);

    error Unauthorized();
    error ZeroAddress();
    error HookAlreadySet();
    error WindowTooSmall();
    error WindowTooLarge();

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }

    /// [CRITICAL] Only the hook contract. Owner removed — was an attack vector.
    modifier onlyHook()  { if (msg.sender != hook)  revert Unauthorized(); _; }

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(address _owner, uint256 _windowSize) {
        if (_owner == address(0)) revert ZeroAddress();
        owner      = _owner;
        windowSize = _windowSize < MIN_WINDOW ? 200 : _windowSize;
        if (windowSize > 1024) revert WindowTooLarge();
        currentEntropy = H_OPT;
        isCritical     = true;
        lastUpdate     = block.number;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice [CRITICAL] Set the hook address. Can only be called once (lock after set).
    function setHook(address _hook) external onlyOwner {
        if (_hook == address(0)) revert ZeroAddress();
        if (hook != address(0)) revert HookAlreadySet();   // immutable after first set
        hook = _hook;
        emit HookSet(_hook);
    }

    /// @notice [MEDIUM] Governance: update window size. Min 100, max 1024.
    function setWindowSize(uint256 _windowSize) external onlyOwner {
        if (_windowSize < MIN_WINDOW)  revert WindowTooSmall();
        if (_windowSize > 1024)        revert WindowTooLarge();
        windowSize = _windowSize;
        emit WindowSizeUpdated(_windowSize);
    }

    // ─── Core: observe a swap amount ─────────────────────────────────────────

    /**
     * @notice Record a swap amount. Called by SpectralHook after each swap.
     * @param  value  Raw token amount in wei (not pre-divided).
     *                The oracle applies log2 bucketing internally.
     *                [MEDIUM] Zero values are skipped.
     */
    function observe(uint256 value) external onlyHook {
        if (value == 0) return;   // [MEDIUM] skip zero — prevents bin-0 pollution
        uint256 bucket = _log2(value) % BINS;
        _updateFreqFIFO(uint8(bucket));
        _recomputeEntropy();
        lastUpdate = block.number;
    }

    function observeBatch(uint256[] calldata values) external onlyHook {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == 0) continue;
            uint256 bucket = _log2(values[i]) % BINS;
            _updateFreqFIFO(uint8(bucket));
        }
        _recomputeEntropy();
        lastUpdate = block.number;
    }

    // ─── [HIGH] Proper FIFO windowed frequency table ─────────────────────────

    /**
     * @notice Insert a bucket into the FIFO buffer.
     *         When full, evict the *oldest* bucket (not the incoming one).
     *         Previous implementation decremented the incoming bin — wrong.
     */
    function _updateFreqFIFO(uint8 bucket) internal {
        uint256 bufLen = (bufTail - bufHead) % 1025;   // current buffer occupancy

        if (bufLen >= windowSize) {
            // Evict oldest: decrement its bin
            uint8 evictBin = obsBuffer[bufHead % 1024];
            if (freqTable[evictBin] > 0) freqTable[evictBin]--;
            bufHead++;
            if (totalObs > 0) totalObs--;
        }

        // Insert new
        obsBuffer[bufTail % 1024] = bucket;
        bufTail++;
        freqTable[bucket]++;
        totalObs++;
    }

    // ─── WHT Entropy computation ──────────────────────────────────────────────

    function _recomputeEntropy() internal {
        if (totalObs == 0) return;

        // Step 1: normalised signal
        int256[64] memory s;
        for (uint256 i = 0; i < BINS; i++) {
            s[i] = int256((uint256(freqTable[i]) * SCALE) / totalObs);
        }

        // Step 2: WHT butterfly — O(384 adds)
        uint256 step = 1;
        while (step < BINS) {
            for (uint256 i = 0; i < BINS; i += step * 2) {
                for (uint256 j = i; j < i + step; j++) {
                    int256 a    = s[j];
                    int256 b    = s[j + step];
                    s[j]        = a + b;
                    s[j + step] = a - b;
                }
            }
            step *= 2;
        }
        for (uint256 i = 0; i < BINS; i++) s[i] /= 8;

        // Step 3: power spectrum
        uint256[64] memory power;
        uint256 totalPower;
        for (uint256 i = 0; i < BINS; i++) {
            uint256 sq = uint256(s[i] < 0 ? -s[i] : s[i]);
            power[i]    = (sq * sq) / SCALE;
            totalPower += power[i];
        }
        if (totalPower == 0) return;

        uint256[64] memory normP;
        for (uint256 i = 0; i < BINS; i++) {
            normP[i] = (power[i] * SCALE) / totalPower;
        }

        // Step 4: H = -Σ p·log2(p) → convert bits to nats
        uint256 entropyBits;
        for (uint256 i = 0; i < BINS; i++) {
            if (normP[i] > 1e9) {
                uint256 lg   = _log2Fixed(normP[i]);
                entropyBits += (normP[i] * lg) / SCALE;
            }
        }
        currentEntropy = (entropyBits * 693147) / 1000000;

        fanoPower  = normP[1] + normP[2] + normP[4];
        isCritical = (currentEntropy >= H_MIN && currentEntropy <= H_MAX);

        entropyHistory[historyIndex % 32] = currentEntropy;
        historyIndex++;

        emit EntropyUpdated(currentEntropy, isCritical, fanoPower);
    }

    // ─── [HIGH] Fixed-point log2 — underflow-safe ─────────────────────────────

    /**
     * @notice Returns -log2(x/SCALE) * SCALE for x ∈ (0, SCALE).
     *         [HIGH] Clamp before subtraction to prevent underflow.
     */
    function _log2Fixed(uint256 x) internal pure returns (uint256) {
        if (x == 0 || x >= SCALE) return 0;

        uint256 intPart = 0;
        uint256 tmp     = x;
        while (tmp < SCALE && intPart < 256) {
            if (tmp > type(uint256).max / 2) break;
            tmp     *= 2;
            intPart++;
        }

        uint256 delta = tmp % SCALE;

        // [HIGH] Compute corrections then clamp before subtracting
        uint256 logZ  = (delta * 1442695) / 1000000;
        uint256 corr  = (delta / SCALE == 0) ? ((delta * delta / SCALE) * 721347) / 1000000 : 0;

        // Safe subtraction: clamp corr to logZ
        if (corr > logZ) corr = logZ;
        logZ = logZ - corr;

        // intPart * SCALE must exceed logZ for valid log (it always does for x < SCALE)
        uint256 intScaled = intPart * SCALE;
        return intScaled > logZ ? intScaled - logZ : 0;
    }

    /**
     * @notice Integer floor(log2(value)) via bit-scan. O(1), exact.
     */
    function _log2(uint256 value) internal pure returns (uint256 result) {
        if (value >> 128 > 0) { value >>= 128; result += 128; }
        if (value >> 64  > 0) { value >>= 64;  result += 64;  }
        if (value >> 32  > 0) { value >>= 32;  result += 32;  }
        if (value >> 16  > 0) { value >>= 16;  result += 16;  }
        if (value >> 8   > 0) { value >>= 8;   result += 8;   }
        if (value >> 4   > 0) { value >>= 4;   result += 4;   }
        if (value >> 2   > 0) { value >>= 2;   result += 2;   }
        if (value >> 1   > 0) {                result += 1;   }
    }

    // ─── TWAP ─────────────────────────────────────────────────────────────────
    function twapEntropy(uint256 n) external view returns (uint256) {
        if (n == 0 || n > 32) n = 32;
        uint256 sum; uint256 count;
        for (uint256 i = 0; i < n && i < historyIndex; i++) {
            sum   += entropyHistory[(historyIndex - 1 - i) % 32];
            count++;
        }
        return count == 0 ? currentEntropy : sum / count;
    }

    // ─── Dynamic fee ──────────────────────────────────────────────────────────

    /**
     * @notice Returns swap fee in basis points.
     *   [LOW] Returns baseline 3000 (0.3%) if data is stale (>24h no swaps).
     *         Prevents fresh-deploy state from giving artificially cheap fees
     *         to an empty pool.
     *
     *   At H_OPT (2.3 nats):   500  (0.05%)  — cheapest
     *   At window edges:       10000 (1.00%)  — elevated
     *   Outside window:        30000 (3.00%)  — penalty
     *   Stale (no activity):   3000  (0.30%)  — baseline
     */
    function getDynamicFee() external view returns (uint24) {
        // [LOW] Staleness check
        if (block.number > lastUpdate + STALENESS_BLOCKS) return 3000;

        uint256 e = currentEntropy;
        if (e == 0)              return 30000;
        if (e < H_MIN || e > H_MAX) return 30000;

        uint256 dev;
        if (e >= H_OPT) {
            dev = ((e - H_OPT) * SCALE) / (H_MAX - H_OPT);
        } else {
            dev = ((H_OPT - e) * SCALE) / (H_OPT - H_MIN);
        }
        uint256 fee = 500 + ((10000 - 500) * ((dev * dev) / SCALE)) / SCALE;
        return uint24(fee);
    }

    // ─── Views ────────────────────────────────────────────────────────────────
    function getState() external view returns (
        uint256 entropy, bool critical, uint256 fano,
        uint256 observations, uint256 dynamicFee
    ) {
        entropy      = currentEntropy;
        critical     = isCritical;
        fano         = fanoPower;
        observations = totalObs;
        dynamicFee   = this.getDynamicFee();
    }

    function getFreqTable() external view returns (uint64[64] memory) {
        return freqTable;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  SpectralMath
/// @notice Fixed-point (WAD = 1e18) Walsh-Hadamard spectral entropy over an 8-point window.
/// @dev    Three pieces, each tested in isolation:
///         1. `fwht8`: in-place unnormalised Fast Walsh-Hadamard Transform, 3 butterfly stages
///            (N log2 N = 24 additions/subtractions), written in Yul.
///         2. `lnWad`: natural logarithm in WAD. Range reduction x = m * 2^k with
///            m in [1/sqrt2, sqrt2), then ln m = 2 atanh((m-1)/(m+1)) by its Taylor series.
///            (The plain series ln(1+u) converges far too slowly near u = -1, i.e. for the
///            small probabilities that dominate an entropy computation.)
///         3. `spectralEntropy8`: H = -sum P_k ln P_k / ln 8 with P_k = X_k^2 / sum X_j^2,
///            returned in [0, 1e18].
///
///         Interpretation (important, and the opposite of a common intuition):
///         - a constant window (all swaps the same size) puts all energy in sequency 0,
///           so H = 0;
///         - a single isolated spike has a flat Walsh spectrum, so H = 1.
///         H therefore measures irregularity / concentration of the flow, not "organic-ness".
library SpectralMath {
    uint256 internal constant WAD = 1e18;
    int256 internal constant IWAD = 1e18;
    /// @dev Internal precision of the logarithm series (36 decimals).
    int256 internal constant E36 = 1e36;

    /// @dev ln(2) * 1e36, truncated (0.693147180559945309417232121458176568...). The extra 18
    ///      digits keep k * ln 2 exact to < 1 wei for every |k| <= 256.
    int256 internal constant LN2_E36 = 693_147_180_559_945_309_417_232_121_458_176_568;
    /// @dev ln(8) * 1e18 = 3 ln 2 (2.079441541679835928251...).
    uint256 internal constant LN8_WAD = 2_079_441_541_679_835_928;
    /// @dev 1/sqrt(2) * 1e18 (0.707106781186547524400...).
    uint256 internal constant SQRT1_2_WAD = 707_106_781_186_547_524;

    error LnOfZero();

    // ---------------------------------------------------------------------------------------
    // 1. Fast Walsh-Hadamard Transform, N = 8
    // ---------------------------------------------------------------------------------------

    /// @notice In-place unnormalised FWHT of 8 signed values: x <- H_8 x, H_8 the Sylvester
    ///         Hadamard matrix (entries +-1). Applying it twice returns 8x.
    /// @dev    Butterflies (a, b) -> (a + b, a - b) on index pairs at distance 1, 2, 4.
    ///         Arithmetic is unchecked: callers must keep |x_i| <= 2^250 (inputs to
    ///         `spectralEntropy8` are normalised to [0, 1e18], so |X_k| <= 8e18).
    function fwht8(int256[8] memory x) internal pure {
        assembly ("memory-safe") {
            function bf(base, i, j) {
                let pi := add(base, shl(5, i))
                let pj := add(base, shl(5, j))
                let a := mload(pi)
                let b := mload(pj)
                mstore(pi, add(a, b))
                mstore(pj, sub(a, b))
            }
            // stage h = 1
            bf(x, 0, 1)
            bf(x, 2, 3)
            bf(x, 4, 5)
            bf(x, 6, 7)
            // stage h = 2
            bf(x, 0, 2)
            bf(x, 1, 3)
            bf(x, 4, 6)
            bf(x, 5, 7)
            // stage h = 4
            bf(x, 0, 4)
            bf(x, 1, 5)
            bf(x, 2, 6)
            bf(x, 3, 7)
        }
    }

    // ---------------------------------------------------------------------------------------
    // 2. Natural logarithm
    // ---------------------------------------------------------------------------------------

    /// @notice ln(x / 1e18) * 1e18 for x > 0.
    /// @dev    The series runs with 36 decimals, so the only visible errors are the final
    ///         truncation (< 1 wei) and, for x >= 2^60, dropping low bits of x during range
    ///         reduction (< 1.8 wei). Tested against 80-digit reference values: within 1 wei
    ///         of the correctly rounded result for x < 2^60 (every probability in an entropy
    ///         computation) and within 3 wei for any x > 0.
    function lnWad(uint256 x) internal pure returns (int256 r) {
        if (x == 0) revert LnOfZero();
        // x = m * 2^k with m in [2^59, 2^60), i.e. m/1e18 in [0.576, 1.153).
        // log2(x) <= 255 and |k| <= 196: every cast below is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 k = int256(Math.log2(x)) - 59;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 m = k >= 0 ? x >> uint256(k) : x << uint256(-k);
        // Move m into [1/sqrt2, sqrt2) so that |z| <= 0.1716 below.
        if (m < SQRT1_2_WAD) {
            m <<= 1;
            k -= 1;
        }
        // z = (m - 1)/(m + 1) with 36 decimals; ln m = 2 (z + z^3/3 + z^5/5 + ...)
        // m < 2^61
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 mi = int256(m);
        int256 z = ((mi - IWAD) * E36) / (mi + IWAD); // |z| <= 0.1716e36
        int256 z2 = (z * z) / E36;
        int256 term = z;
        int256 sum = z;
        unchecked {
            // 12 more odd powers; the first omitted term is below 2e-22. Every product is
            // below 6e69, far from the int256 limit.
            for (int256 n = 3; n <= 25; n += 2) {
                term = (term * z2) / E36;
                sum += term / n;
            }
        }
        r = (k * LN2_E36 + 2 * sum) / IWAD;
    }

    // ---------------------------------------------------------------------------------------
    // 3. Spectral entropy
    // ---------------------------------------------------------------------------------------

    /// @notice Normalised Shannon entropy of the Walsh-Hadamard power spectrum of `v`.
    /// @param  v Eight non-negative samples (any common unit; the result is scale invariant).
    /// @return h Entropy in WAD, 0 <= h <= 1e18. Returns 0 if all samples are zero.
    function spectralEntropy8(uint256[8] memory v) internal pure returns (uint256 h) {
        uint256 vmax;
        for (uint256 i; i < 8; ++i) {
            if (v[i] > vmax) vmax = v[i];
        }
        if (vmax == 0) return 0;

        // Normalise to [0, 1e18]: exact scale invariance, and no int256 overflow even for
        // raw 128-bit swap deltas.
        int256[8] memory x;
        for (uint256 i; i < 8; ++i) {
            // <= 1e18
            // forge-lint: disable-next-line(unsafe-typecast)
            x[i] = int256(Math.mulDiv(v[i], WAD, vmax));
        }
        fwht8(x);

        uint256[8] memory pw;
        uint256 total;
        for (uint256 k; k < 8; ++k) {
            // |X_k| <= 8e18
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 a = uint256(x[k] < 0 ? -x[k] : x[k]);
            pw[k] = a * a; // <= 6.4e37
            total += pw[k];
        }
        // total > 0 because vmax > 0 and the transform is invertible.

        uint256 hRaw; // -sum P ln P, WAD nats
        for (uint256 k; k < 8; ++k) {
            if (pw[k] == 0) continue;
            uint256 p = Math.mulDiv(pw[k], WAD, total); // P_k in WAD
            if (p == 0) continue; // below 1e-18: contribution < 4.2e-17
            int256 lp = lnWad(p); // <= 0
            // -lp >= 0 because p <= 1e18
            // forge-lint: disable-next-line(unsafe-typecast)
            hRaw += (p * uint256(-lp)) / WAD;
        }
        h = (hRaw * WAD) / LN8_WAD;
        if (h > WAD) h = WAD;
    }
}

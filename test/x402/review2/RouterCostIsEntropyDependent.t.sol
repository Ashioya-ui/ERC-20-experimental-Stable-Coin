// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Independent review 2: what "flat 3.0-3.3 bps" is and is not.
//
//  REPORT_X402.md ("Router cost, $0.01 to $10 | flat 3.0-3.3 bps"), README.md and
//  docs/speedrun-application.md ("Measured cost: flat 3.0-3.3 basis points from $0.01 to $10")
//  all quote one number with no condition attached. The number is real, but it is the cost at
//  ONE value of the entropy signal - the neutral H = 0.5 the oracle reports during warm-up,
//  which is exactly where the live Base Sepolia oracle sits because it has never recorded a
//  swap (filled() == 0 at block 48,909,993).
//
//  These tests pin both halves: flat in invoice size (true, and worth saying), and a function
//  of H that triples at H = 1 (true, and currently unsaid).
//
//  Run:  forge test --match-path "test/x402/review2/*"
// =====================================================================================

import {SpectrumPayRouter} from "../../../src/periphery/SpectrumPayRouter.sol";
import {SpectrumFixture} from "../../utils/SpectrumFixture.sol";

contract RouterCostIsEntropyDependentTest is SpectrumFixture {
    SpectrumPayRouter internal router;

    function setUp() public {
        liquidityBufferBps = 1_000;
        _deploySystem();
        oracle.setEntropy(0.5e18);
        router = new SpectrumPayRouter(stabilizer);
    }

    /// @dev Overhead in hundredths of a basis point, so 325 == 3.25 bps.
    function _overheadCentiBps(uint256 assets) internal view returns (uint256) {
        uint256 redeemed6 = router.sUSDFor(assets) / SCALE; // sUSD wei -> 6dp
        return ((redeemed6 - assets) * 1_000_000) / assets;
    }

    /// @notice Flat in invoice size: this half of the claim holds.
    function test_theQuotedRangeHoldsAcrossInvoiceSizesAtNeutralEntropy() public view {
        uint256[6] memory sizes = [uint256(10_000), 13_000, 50_000, 100_000, 1_000_000, 10_000_000];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 centiBps = _overheadCentiBps(sizes[i]);
            assertGe(centiBps, 300, "below the quoted 3.0 bps");
            assertLe(centiBps, 330, "above the quoted 3.3 bps");
        }
    }

    /// @notice Not flat in H. At the top of the policy curve the same payment costs about
    ///         10 bps - three times the quoted figure - and no document says so.
    function test_theQuotedRangeIsOnlyTrueAtNeutralEntropy() public {
        uint256 atNeutral = _overheadCentiBps(50_000);
        assertApproxEqAbs(atNeutral, 325, 5, "3.25 bps at H = 0.5");

        oracle.setEntropy(1e18);
        uint256 atMax = _overheadCentiBps(50_000);
        assertGt(atMax, 990, "about 10 bps at H = 1");
        assertGt(atMax, 3 * atNeutral - 10, "roughly three times the quoted cost");

        oracle.setEntropy(0);
        uint256 atMin = _overheadCentiBps(50_000);
        assertLt(atMin, 110, "about 1 bp at H = 0");
    }

    /// @notice What an agent must be able to commit is always the 10 bp figure, whatever the
    ///         quoted cost is, because the authorization is sized at REDEEM_FEE_MAX.
    function test_whatTheAgentMustAuthoriseIsAlwaysSizedAtTenBasisPoints() public view {
        uint256 authorized = router.sUSDToAuthorize(50_000);
        assertGt(authorized, router.sUSDFor(50_000), "the agent commits more than the current price");
        uint256 centiBps = ((authorized / SCALE - 50_000) * 1_000_000) / 50_000;
        assertApproxEqAbs(centiBps, 1_000, 10, "10 bps, REDEEM_FEE_MAX");
    }

    /// @notice Below the 0.01 sUSD minimum the rail stops being a 3 bps rail: most of the
    ///         redemption comes back as idle USDC. REPORT_X402.md says this; the speedrun
    ///         application's "flat 3.0-3.3 bps from $0.01 to $10" quietly depends on it.
    function test_belowTheMinimumTheMinimumDominates() public view {
        uint256 redeemed = router.sUSDFor(1_000); // a $0.001 invoice
        assertEq(redeemed, stabilizer.minAmount(), "the 0.01 sUSD minimum is redeemed");
        assertGt(redeemed / SCALE, 9_000, "most of it returns to the payer as USDC, not sUSD");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SpectralToken} from "../../src/SpectralToken.sol";
import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";
import {SpectrumLens} from "../../src/SpectrumLens.sol";
import {AutonomousTreasury} from "../../src/AutonomousTreasury.sol";
import {ISpectralEntropyOracle} from "../../src/interfaces/ISpectralEntropyOracle.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Monetary system wired to a settable entropy source (MockOracle).
abstract contract SpectrumFixture is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SCALE = 1e12; // USDC (6 dp) -> sUSD (18 dp)
    uint256 internal constant BOOTSTRAP_CAP = 1_000_000e18;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal guardian = makeAddr("guardian");

    /// @dev Parameters used by the next `_deploySystem()` call.
    uint256 internal bootstrapCap = BOOTSTRAP_CAP;
    uint256 internal supplyCap = type(uint256).max;
    uint256 internal liquidityBufferBps = 0;

    MockUSDC internal usdc;
    MockVault internal vault;
    AutonomousTreasury internal treasury;
    SpectralToken internal token;
    MockOracle internal oracle;
    SpectralStabilizer internal stabilizer;
    SpectrumLens internal lens;

    function _deploySystem() internal {
        vm.warp(1_700_000_000);
        if (address(usdc) == address(0)) usdc = new MockUSDC(); // a test may have made one already
        vault = new MockVault(usdc);
        // Wiring is fixed in constructors: the stabilizer is the 4th contract created below.
        address stabilizerAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        treasury = new AutonomousTreasury(IERC4626(address(vault)), liquidityBufferBps, stabilizerAt);
        token = new SpectralToken(stabilizerAt);
        oracle = new MockOracle();
        stabilizer = _newStabilizer();
        require(address(stabilizer) == stabilizerAt, "fixture: stabilizer address prediction");
        lens = new SpectrumLens(stabilizer);
        // After the predicted creations: an interleaved call would shift the nonce under
        // --isolate, where every top-level call is its own transaction.
        oracle.setEntropy(0);
    }

    /// @dev Vaults the stabilizer will allow. Tests that migrate add their second vault here
    ///      before `_deploySystem()`.
    address[] internal allowedVaults;

    /// @dev Overridden by tests that need a harness.
    function _newStabilizer() internal virtual returns (SpectralStabilizer) {
        return new SpectralStabilizer(
            token,
            treasury,
            ISpectralEntropyOracle(address(oracle)),
            admin,
            guardian,
            bootstrapCap,
            supplyCap,
            _allowlist()
        );
    }

    /// @dev The vault the treasury starts with, plus anything a test added.
    function _allowlist() internal view returns (address[] memory list) {
        list = new address[](allowedVaults.length + 1);
        list[0] = address(vault);
        for (uint256 i; i < allowedVaults.length; ++i) {
            list[i + 1] = allowedVaults[i];
        }
    }

    function _mintFor(address who, uint256 assets) internal returns (uint256 out) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(stabilizer), assets);
        out = stabilizer.mint(assets, who, 0);
        vm.stopPrank();
    }

    function _redeemFor(address who, uint256 amount) internal returns (uint256 assetsOut) {
        vm.prank(who);
        assetsOut = stabilizer.redeem(amount, who, 0);
    }

    /// @dev Make the vault realise a loss so that the reserve value becomes `targetValue`
    ///      (sUSD wei, rounded to whole USDC units).
    function _lossTo(uint256 targetValue) internal {
        uint256 r = stabilizer.reserveValue();
        require(targetValue < r, "not a loss");
        vault.simulateLoss((r - targetValue) / SCALE);
    }

    function _assertSolvent() internal view {
        assertGe(stabilizer.reserveValue(), token.totalSupply(), "reserve floor");
    }
}

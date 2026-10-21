// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
//  Gas benchmarks (Phase 4, Track B).
//
//  One fixed scenario per hot path, measured from inside a contract call so the figure is the
//  same in normal and `--isolate` runs and is what a real caller pays. The numbers are
//  committed in .gas-snapshot; CI fails if they drift (`forge snapshot --check`).
//
//  The vault here is a mock, so these numbers are a *relative* measure: use them to compare
//  commits, not to predict mainnet. The Base-fork suite measures the same calls against the
//  real waBasUSDC and Gauntlet USDC Prime.
// =====================================================================================

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SpectralToken} from "../src/SpectralToken.sol";
import {SpectralStabilizer} from "../src/SpectralStabilizer.sol";
import {AutonomousTreasury} from "../src/AutonomousTreasury.sol";
import {ISpectralEntropyOracle} from "../src/interfaces/ISpectralEntropyOracle.sol";
import {SpectrumFixture} from "./utils/SpectrumFixture.sol";
import {GasMeter} from "./mocks/GasMeter.sol";

contract BenchmarksTest is SpectrumFixture {
    GasMeter internal meter;

    function setUp() public {
        liquidityBufferBps = 1_500; // the mainnet setting
        _deploySystem();
        meter = new GasMeter();
        usdc.mint(address(meter), 1_000_000e6);
        // Warm the paths a real user would find warm: supply exists, the vault holds shares.
        _mintFor(alice, 100_000e6);
        _meter(address(usdc), abi.encodeCall(usdc.approve, (address(stabilizer), type(uint256).max)));
        _meter(address(stabilizer), abi.encodeCall(stabilizer.mint, (10_000e6, address(meter), 0)));
    }

    function _meter(address target, bytes memory data) internal returns (bytes memory) {
        return meter.measure(target, data);
    }

    function _report(string memory name) internal {
        emit log_named_uint(name, meter.lastGas());
    }

    function test_gas_mint() public {
        _meter(address(stabilizer), abi.encodeCall(stabilizer.mint, (1_000e6, address(meter), 0)));
        _report("mint 1,000 USDC");
    }

    function test_gas_redeem() public {
        _meter(address(stabilizer), abi.encodeCall(stabilizer.redeem, (1_000e18, address(meter), 0)));
        _report("redeem 1,000 sUSD");
    }

    function test_gas_rebase() public {
        vault.simulateYield(5_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _meter(address(stabilizer), abi.encodeCall(stabilizer.rebase, ()));
        _report("rebase");
    }

    function test_gas_sync() public {
        _lossTo((token.totalSupply() * 99) / 100);
        _meter(address(stabilizer), abi.encodeCall(stabilizer.sync, ()));
        _report("sync (absorb a loss)");
    }

    function test_gas_transfer() public {
        _meter(address(token), abi.encodeCall(token.transfer, (bob, 100e18)));
        _report("transfer");
    }

    function test_gas_rebalanceReserve() public {
        vm.prank(admin);
        stabilizer.setLiquidityBuffer(3_000);
        _meter(address(stabilizer), abi.encodeCall(stabilizer.rebalanceReserve, ()));
        _report("rebalanceReserve");
    }

    function test_gas_reserveAssets() public {
        _meter(address(treasury), abi.encodeCall(treasury.reserveAssets, ()));
        _report("reserveAssets (view)");
    }
}

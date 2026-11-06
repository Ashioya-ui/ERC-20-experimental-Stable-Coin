// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SpectrumFixture} from "./utils/SpectrumFixture.sol";
import {WrappedSUSD} from "../src/WrappedSUSD.sol";
import {X402SessionEscrow} from "../src/vault/X402SessionEscrow.sol";
import {X402SessionPaths} from "../src/vault/X402SessionPaths.sol";

/// sUSD on an x402 session path. sUSD rebases, so the path and the escrow hold wrapped sUSD:
/// shares that never rebase, worth more or less sUSD as the index moves. Every account they keep
/// stays exact in shares through any rebase; value is read only when home unwraps.
contract SUSDOnPathsTest is SpectrumFixture {
    uint256 internal constant AGENT_PK = 0xA6E7;

    WrappedSUSD internal ws;
    X402SessionEscrow internal escrow;
    X402SessionPaths internal paths;
    address internal agent;
    address internal home;
    address internal merchant = makeAddr("merchant");
    address internal merchant2 = makeAddr("merchant2");

    function setUp() public {
        _deploySystem();
        ws = new WrappedSUSD(token);
        escrow = new X402SessionEscrow();
        paths = new X402SessionPaths(escrow);
        agent = vm.addr(AGENT_PK);
        home = alice;
        _mintFor(home, 10_000e6);
        vm.startPrank(home);
        token.approve(address(ws), type(uint256).max);
        ws.deposit(1_000e18, home);
        ws.approve(address(paths), type(uint256).max);
        vm.stopPrank();
    }

    function _voucher(bytes32 sessionId, uint256 cumulative) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AGENT_PK, escrow.voucherDigest(sessionId, cumulative));
        return abi.encodePacked(r, s, v);
    }

    function _escrowIsExact(bytes32 sessionId) internal view {
        X402SessionEscrow.Session memory s = escrow.session(sessionId);
        assertEq(ws.balanceOf(address(escrow)), uint256(s.deposited) - uint256(s.claimed), "escrow holds exactly what it owes");
    }

    function test_sUSDWalksAPath_andEveryAccountStaysExactThroughRebases() public {
        assertEq(ws.balanceOf(home), 1_000e18);
        address[] memory payees = new address[](2);
        uint256[] memory caps = new uint256[](2);
        payees[0] = merchant;
        payees[1] = merchant2;
        caps[0] = 600e18;
        caps[1] = 400e18;
        vm.prank(home);
        bytes32 pathId = paths.declare(agent, address(ws), uint64(block.timestamp + 7 days), "susd", payees, caps, 1_000e18);
        assertEq(ws.balanceOf(address(paths)), 1_000e18, "the path holds the wrapped budget");

        vm.prank(agent);
        bytes32 sessionId = paths.step(pathId, merchant, agent, uint64(block.timestamp + 1 days), "s1", 200e18);
        escrow.redeem(sessionId, 50e18, _voucher(sessionId, 50e18));
        assertEq(ws.balanceOf(merchant), 50e18);
        _escrowIsExact(sessionId);

        uint256 before = ws.convertToAssets(50e18);
        vault.simulateYield(600e6);
        assertTrue(stabilizer.rebase(), "a positive rebase");
        assertGt(ws.convertToAssets(50e18), before, "the merchant's shares are worth more sUSD");
        _escrowIsExact(sessionId);

        escrow.redeem(sessionId, 120e18, _voucher(sessionId, 120e18));
        assertEq(ws.balanceOf(merchant), 120e18);

        uint256 high = ws.convertToAssets(80e18);
        _lossTo((token.totalSupply() * 95) / 100);
        stabilizer.sync();
        assertLt(ws.convertToAssets(80e18), high, "a loss is shared by the shares");
        _escrowIsExact(sessionId);

        vm.prank(merchant);
        escrow.closeByPayee(sessionId, 0, "");
        assertEq(paths.collect(sessionId), 80e18, "the unspent 80 returns to the path");
        X402SessionPaths.Path memory p = paths.path(pathId);
        assertEq(p.committed, 200e18, "committed never falls, so a refund cannot be committed again");
        assertEq(p.free, 880e18);

        vm.prank(home);
        assertEq(paths.goHome(pathId), 880e18);
        assertEq(ws.balanceOf(home), 880e18);
        assertEq(ws.balanceOf(merchant) + ws.balanceOf(home), 1_000e18, "every share is accounted for");

        uint256 value = ws.convertToAssets(880e18);
        uint256 held = token.balanceOf(home);
        vm.prank(home);
        uint256 out = ws.redeem(880e18, home, home);
        assertEq(out, value);
        assertApproxEqAbs(token.balanceOf(home) - held, out, 2, "home unwraps to sUSD");
    }
}

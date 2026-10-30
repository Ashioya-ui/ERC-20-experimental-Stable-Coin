// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {X402SessionEscrow} from "../../src/vault/X402SessionEscrow.sol";
import {X402SessionPaths} from "../../src/vault/X402SessionPaths.sol";
import {EIP3009Mock} from "./mocks/EIP3009Mock.sol";

/// @dev The owner's phone (home), an agent's hot key, two merchants the owner names, and an attacker.
abstract contract PathFixture is Test {
    uint256 internal constant HOME_PK = 0x40E;
    uint256 internal constant AGENT_PK = 0xA6E7;
    uint256 internal constant ATTACKER_PK = 0xBAD;

    X402SessionEscrow internal escrow;
    X402SessionPaths internal paths;
    EIP3009Mock internal usdc;
    address internal home;
    address internal agent;
    address internal attacker;
    address internal merchant;
    address internal merchant2;
    address internal facilitator;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        escrow = new X402SessionEscrow();
        paths = new X402SessionPaths(escrow);
        usdc = new EIP3009Mock();
        home = vm.addr(HOME_PK);
        agent = vm.addr(AGENT_PK);
        attacker = vm.addr(ATTACKER_PK);
        merchant = makeAddr("merchant");
        merchant2 = makeAddr("merchant2");
        facilitator = makeAddr("facilitator");
        usdc.mint(home, 1_000e6);
        vm.prank(home);
        usdc.approve(address(paths), type(uint256).max);
    }

    function _ends() internal view returns (address[] memory payees, uint256[] memory caps) {
        payees = new address[](2);
        caps = new uint256[](2);
        payees[0] = merchant;
        payees[1] = merchant2;
        caps[0] = 6e5;
        caps[1] = 4e5;
    }

    /// A path to merchant (cap 0.60) and merchant2 (cap 0.40), with a budget of 1.00.
    function _declare(bytes32 salt) internal returns (bytes32 pathId) {
        (address[] memory payees, uint256[] memory caps) = _ends();
        vm.prank(home);
        pathId = paths.declare(agent, address(usdc), uint64(block.timestamp + 7 days), salt, payees, caps, 1e6);
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    struct Step {
        bytes32 pathId;
        address payee;
        address signer;
        uint64 expiry;
        bytes32 salt;
        uint256 amount;
        uint256 committed;
        uint256 deadline;
    }

    function _stepFor(bytes32 pathId, address payee, uint256 amount, bytes32 salt) internal view returns (Step memory s) {
        s = Step({
            pathId: pathId,
            payee: payee,
            signer: agent,
            expiry: uint64(block.timestamp + 1 days),
            salt: salt,
            amount: amount,
            committed: paths.committedTo(pathId, payee),
            deadline: block.timestamp + 60
        });
    }

    function _signStep(uint256 pk, Step memory s) internal view returns (bytes memory) {
        return _sig(
            pk, paths.stepDigest(s.pathId, s.payee, s.signer, s.expiry, s.salt, s.amount, s.committed, s.deadline)
        );
    }

    function _submit(Step memory s, bytes memory sig) internal returns (bytes32) {
        return paths.stepWithSig(s.pathId, s.payee, s.signer, s.expiry, s.salt, s.amount, s.committed, s.deadline, sig);
    }

    /// Submits the step as a facilitator would, reporting whether it went through.
    function _try(Step memory s, bytes memory sig) internal returns (bool ok) {
        vm.prank(facilitator);
        try paths.stepWithSig(s.pathId, s.payee, s.signer, s.expiry, s.salt, s.amount, s.committed, s.deadline, sig)
        returns (bytes32) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _voucher(bytes32 id, uint256 cumulative) internal view returns (bytes memory) {
        return _sig(AGENT_PK, escrow.voucherDigest(id, cumulative));
    }

    function _receiveAuth(uint256 pk, address to, uint256 value, bytes32 nonce, uint256 validBefore)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), vm.addr(pk), to, value, uint256(0), validBefore, nonce)
        );
        return _sig(pk, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
    }
}

contract X402SessionPathsTest is PathFixture {
    // ------------------------------------------------------------------ declaring the end

    function test_declare_holdsTheBudgetUnderTheEnd() public {
        bytes32 id = _declare("p");
        X402SessionPaths.Path memory p = paths.path(id);
        assertEq(p.home, home);
        assertEq(p.agent, agent);
        assertEq(p.token, address(usdc));
        assertEq(p.free, 1e6);
        assertEq(p.bound, 1e6, "|E|_1 is the sum of the caps");
        assertEq(p.committed, 0);
        assertFalse(p.ended);
        assertEq(paths.capOf(id, merchant), 6e5);
        assertEq(paths.capOf(id, merchant2), 4e5);
        assertEq(paths.capOf(id, attacker), 0, "anyone else is off the path");
        assertEq(usdc.balanceOf(address(paths)), 1e6);
        (address[] memory payees, uint256[] memory caps) = _ends();
        assertEq(
            id,
            paths.pathIdOf(home, agent, address(usdc), uint64(block.timestamp + 7 days), paths.endsOf(payees, caps), "p"),
            "the id is computable in advance"
        );
    }

    function test_declare_rejectsAnEndThatCannotBeWalked() public {
        address[] memory payees = new address[](2);
        uint256[] memory caps = new uint256[](2);
        uint64 expiry = uint64(block.timestamp + 7 days);
        vm.startPrank(home);

        payees[0] = merchant;
        payees[1] = merchant;
        caps[0] = 1;
        caps[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.DuplicatePayee.selector, merchant));
        paths.declare(agent, address(usdc), expiry, "a", payees, caps, 1e6);

        payees[1] = address(escrow);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.ForbiddenPayee.selector, address(escrow)));
        paths.declare(agent, address(usdc), expiry, "b", payees, caps, 1e6);

        payees[1] = address(paths);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.ForbiddenPayee.selector, address(paths)));
        paths.declare(agent, address(usdc), expiry, "c", payees, caps, 1e6);

        payees[1] = merchant2;
        caps[1] = 0;
        vm.expectRevert(X402SessionPaths.ZeroAmount.selector);
        paths.declare(agent, address(usdc), expiry, "d", payees, caps, 1e6);

        caps[1] = 1;
        vm.expectRevert(X402SessionPaths.ZeroAmount.selector);
        paths.declare(agent, address(usdc), expiry, "e", payees, caps, 0);

        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.BadExpiry.selector, uint64(block.timestamp + 1 hours)));
        paths.declare(agent, address(usdc), uint64(block.timestamp + 1 hours), "f", payees, caps, 1e6);

        vm.expectRevert(X402SessionPaths.BadEnds.selector);
        paths.declare(agent, address(usdc), expiry, "g", payees, new uint256[](1), 1e6);

        vm.expectRevert(X402SessionPaths.BadEnds.selector);
        paths.declare(agent, address(usdc), expiry, "h", new address[](33), new uint256[](33), 1e6);

        vm.expectRevert(X402SessionPaths.ZeroAddress.selector);
        paths.declare(address(0), address(usdc), expiry, "i", payees, caps, 1e6);
        vm.stopPrank();
    }

    function test_declareWithAuthorization_isGaslessForHome_andBindsEveryTerm() public {
        (address[] memory payees, uint256[] memory caps) = _ends();
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 validBefore = block.timestamp + 60;
        bytes32 ends = paths.endsOf(payees, caps);
        bytes32 nonce = paths.declareNonce(agent, address(usdc), expiry, ends, "g");
        bytes memory auth = _receiveAuth(HOME_PK, address(paths), 1e6, nonce, validBefore);

        // A submitter who changes the agent, the end or the budget invalidates the authorization.
        vm.startPrank(facilitator);
        vm.expectRevert(bytes("invalid signature"));
        paths.declareWithAuthorization(
            home, attacker, address(usdc), expiry, "g", payees, caps, 1e6, 0, validBefore, auth
        );
        uint256[] memory widened = new uint256[](2);
        widened[0] = 6e5;
        widened[1] = 9e5;
        vm.expectRevert(bytes("invalid signature"));
        paths.declareWithAuthorization(
            home, agent, address(usdc), expiry, "g", payees, widened, 1e6, 0, validBefore, auth
        );
        address[] memory redirected = new address[](2);
        redirected[0] = merchant;
        redirected[1] = attacker;
        vm.expectRevert(bytes("invalid signature"));
        paths.declareWithAuthorization(
            home, agent, address(usdc), expiry, "g", redirected, caps, 1e6, 0, validBefore, auth
        );

        uint256 homeEth = home.balance;
        bytes32 id = paths.declareWithAuthorization(
            home, agent, address(usdc), expiry, "g", payees, caps, 1e6, 0, validBefore, auth
        );
        vm.stopPrank();
        assertEq(paths.path(id).home, home);
        assertEq(paths.path(id).free, 1e6);
        assertEq(home.balance, homeEth, "home paid no gas");
    }

    // ------------------------------------------------------------------ stepping toward it

    function test_step_opensASessionTowardTheEnd() public {
        bytes32 id = _declare("p");
        Step memory s = _stepFor(id, merchant, 2e5, "s1");
        bytes memory sig1 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        bytes32 sessionId = _submit(s, sig1);

        X402SessionEscrow.Session memory session = escrow.session(sessionId);
        assertEq(session.funder, address(paths), "the path funds the session");
        assertEq(session.payee, merchant);
        assertEq(session.signer, agent);
        assertEq(session.deposited, 2e5);
        assertEq(paths.committedTo(id, merchant), 2e5);
        assertEq(paths.remaining(id, merchant), 4e5);
        assertEq(paths.path(id).free, 8e5);
        assertEq(paths.path(id).committed, 2e5);
        assertEq(paths.pathOf(sessionId), id);
        assertEq(usdc.balanceOf(agent), 0, "the agent never holds the money");

        // The agent may also step itself, paying its own gas.
        vm.prank(agent);
        paths.step(id, merchant2, agent, uint64(block.timestamp + 1 days), "s2", 1e5);
        assertEq(paths.committedTo(id, merchant2), 1e5);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.NotAgent.selector, attacker));
        paths.step(id, merchant2, agent, uint64(block.timestamp + 1 days), "s3", 1e5);
    }

    /// The whole point. Whoever holds the agent's key can only walk the owner's path: no merchant the
    /// owner did not name, no more than the owner named, no way to send money anywhere else.
    function test_aStolenAgentKeyCanOnlyWalkTheOwnersPath() public {
        bytes32 id = _declare("p");

        Step memory s = _stepFor(id, attacker, 1e5, "steal");
        bytes memory sig2 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.NotOnPath.selector, attacker));
        _submit(s, sig2);

        s = _stepFor(id, merchant, 6e5 + 1, "overshoot");
        bytes memory sig3 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.BeyondEnd.selector, merchant, 6e5 + 1, 6e5));
        _submit(s, sig3);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.NotHome.selector, agent));
        paths.goHome(id);

        // The most the key can do: commit every cap to the named merchants, and sign vouchers that
        // pay them. That is the owner's plan, done early.
        s = _stepFor(id, merchant, 6e5, "all1");
        bytes memory sig4 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        bytes32 a = _submit(s, sig4);
        s = _stepFor(id, merchant2, 4e5, "all2");
        bytes memory sig5 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        bytes32 b = _submit(s, sig5);
        escrow.redeem(a, 6e5, _voucher(a, 6e5));
        escrow.redeem(b, 4e5, _voucher(b, 4e5));

        assertEq(usdc.balanceOf(merchant), 6e5);
        assertEq(usdc.balanceOf(merchant2), 4e5);
        assertEq(usdc.balanceOf(attacker), 0, "nothing reached anyone off the path");
        assertEq(paths.path(id).committed, paths.path(id).bound, "the path's length never exceeds |E|_1");
        s = _stepFor(id, merchant, 1, "more");
        bytes memory sig6 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.BeyondEnd.selector, merchant, 6e5 + 1, 6e5));
        _submit(s, sig6);
    }

    /// The decompiled Binance pattern: fifty authorizations pre-signed for sequential states, all
    /// fired at once, in the hope that one matches. Here every one is bound to the state it moves
    /// from. A step matches only the state the path is in, moves it, and is dead from then on; the
    /// ones that chain can only walk the path to its end, to the named merchant, and stop.
    function test_aSprayOfPreSignedStepsOnlyEverWalksThePathToItsEnd() public {
        bytes32 id = _declare("p");
        uint256 unit = 1e5; // merchant's cap is 6 units
        Step[] memory spray = new Step[](50);
        bytes[] memory sigs = new bytes[](50);
        for (uint256 k = 0; k < 50; ++k) {
            spray[k] = Step({
                pathId: id,
                payee: merchant,
                signer: agent,
                expiry: uint64(block.timestamp + 1 days),
                salt: keccak256(abi.encode("spray", k)),
                amount: unit,
                committed: k * unit,
                deadline: block.timestamp + 60
            });
            sigs[k] = _signStep(AGENT_PK, spray[k]);
        }

        // Fired newest first: only the step for the current state lands.
        uint256 landed = 0;
        for (uint256 k = 50; k > 0; --k) {
            if (_try(spray[k - 1], sigs[k - 1])) ++landed;
        }
        assertEq(landed, 1, "one pass, one state, one match");

        // Fired again in order: they chain, but only up to the end the owner named.
        for (uint256 k = 0; k < 50; ++k) {
            if (_try(spray[k], sigs[k])) ++landed;
        }
        assertEq(landed, 6, "the cap, and not one step more");
        assertEq(paths.committedTo(id, merchant), 6e5);
        assertEq(paths.committedTo(id, merchant2), 0, "a step for one merchant never moves another");

        // A third pass finds every one of them dead: the path never returns to a state it has left.
        for (uint256 k = 0; k < 50; ++k) {
            assertFalse(_try(spray[k], sigs[k]));
        }
        // And the same spray aimed at the attacker never lands at all.
        for (uint256 k = 0; k < 10; ++k) {
            Step memory s = spray[k];
            s.payee = attacker;
            s.committed = 0;
            assertFalse(_try(s, _signStep(AGENT_PK, s)));
        }
        assertEq(usdc.balanceOf(attacker), 0);
    }

    function test_stepWithSig_bindsEveryTerm() public {
        bytes32 id = _declare("p");
        Step memory s = _stepFor(id, merchant, 1e5, "t");
        bytes memory sig = _signStep(AGENT_PK, s);

        Step memory t = _stepFor(id, merchant, 2e5, "t"); // a larger amount than signed
        vm.prank(facilitator);
        vm.expectRevert(X402SessionPaths.InvalidSignature.selector);
        _submit(t, sig);

        t = _stepFor(id, merchant2, 1e5, "t"); // another named merchant than signed
        vm.prank(facilitator);
        vm.expectRevert(X402SessionPaths.InvalidSignature.selector);
        _submit(t, sig);

        t = _stepFor(id, merchant, 1e5, "t");
        t.signer = attacker; // a voucher key the agent did not choose
        vm.prank(facilitator);
        vm.expectRevert(X402SessionPaths.InvalidSignature.selector);
        _submit(t, sig);

        bytes memory strangers = _signStep(ATTACKER_PK, s);
        vm.prank(facilitator);
        vm.expectRevert(X402SessionPaths.InvalidSignature.selector);
        _submit(s, strangers); // anyone else's key

        vm.warp(s.deadline + 1);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.SignatureExpired.selector, s.deadline));
        _submit(s, sig);
    }

    function test_aStepIsValidAtOneStateOnly() public {
        bytes32 id = _declare("p");
        Step memory early = _stepFor(id, merchant, 1e5, "early");
        bytes memory earlySig = _signStep(AGENT_PK, early);
        Step memory now_ = _stepFor(id, merchant, 1e5, "now");
        bytes memory sig7 = _signStep(AGENT_PK, now_);
        vm.prank(facilitator);
        _submit(now_, sig7);

        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.StaleStep.selector, 0, 1e5));
        _submit(early, earlySig);
    }

    // ------------------------------------------------------------------ refunds and home

    function test_refundsComeBackToThePath_andNeverRaiseWhatCanBeCommitted() public {
        bytes32 id = _declare("p");
        Step memory s = _stepFor(id, merchant, 5e5, "r");
        bytes memory sig8 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        bytes32 sessionId = _submit(s, sig8);

        // A thousand calls' worth is redeemed, then the merchant closes and releases the rest.
        bytes memory last = _voucher(sessionId, 1e5);
        vm.prank(merchant);
        escrow.closeByPayee(sessionId, 1e5, last);
        assertEq(usdc.balanceOf(merchant), 1e5);
        assertEq(usdc.balanceOf(address(paths)), 5e5 + 4e5, "the refund is back in the paths contract");

        assertEq(paths.collect(sessionId), 4e5);
        assertEq(paths.path(id).free, 5e5 + 4e5);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.AlreadyCollected.selector, sessionId));
        paths.collect(sessionId);

        // The refund is money the path holds, not room: merchant had 0.60 and was committed 0.50.
        assertEq(paths.committedTo(id, merchant), 5e5, "committed never goes back");
        s = _stepFor(id, merchant, 2e5, "r2");
        bytes memory sig9 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.BeyondEnd.selector, merchant, 7e5, 6e5));
        _submit(s, sig9);
    }

    function test_collect_onlyClosedSessionsOfThisContract() public {
        bytes32 id = _declare("p");
        Step memory s = _stepFor(id, merchant, 1e5, "c");
        bytes memory sig10 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        bytes32 sessionId = _submit(s, sig10);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.NotClosed.selector, sessionId));
        paths.collect(sessionId);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.UnknownSession.selector, bytes32("other")));
        paths.collect(bytes32("other"));

        // After expiry anyone reclaims it in the escrow, and anyone credits the refund to the path.
        vm.warp(s.expiry + 1);
        escrow.reclaim(sessionId);
        assertEq(paths.collect(sessionId), 1e5);
        assertEq(paths.path(id).free, 1e6);
    }

    function test_goHome_isTheOnlyWayOut_otherThanTheNamedMerchants() public {
        bytes32 id = _declare("p");
        Step memory s = _stepFor(id, merchant, 3e5, "h");
        bytes memory sig11 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        bytes32 sessionId = _submit(s, sig11);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.NotHome.selector, attacker));
        paths.goHome(id);

        uint256 before = usdc.balanceOf(home);
        vm.prank(home);
        assertEq(paths.goHome(id), 7e5);
        assertEq(usdc.balanceOf(home) - before, 7e5);
        assertTrue(paths.path(id).ended);

        // Ended: no more steps, even ones signed before.
        s = _stepFor(id, merchant, 1e5, "late");
        bytes memory sig12 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402SessionPaths.PathEnded.selector, id));
        _submit(s, sig12);

        // The open session still pays its merchant; what it never claims comes home later.
        escrow.redeem(sessionId, 1e5, _voucher(sessionId, 1e5));
        vm.prank(merchant);
        escrow.closeByPayee(sessionId, 0, "");
        paths.collect(sessionId);
        vm.warp(block.timestamp + 8 days); // past the path's expiry: anyone may send it home
        vm.prank(attacker);
        assertEq(paths.goHome(id), 2e5);
        assertEq(usdc.balanceOf(home) - before, 9e5);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(address(paths)), 0, "the contract keeps nothing");
    }

    function test_goHomeWithSig_isTheOwnersGaslessStop() public {
        bytes32 id = _declare("p");
        uint256 deadline = block.timestamp + 60;
        bytes memory forged = _sig(AGENT_PK, paths.endDigest(id, deadline));
        vm.prank(facilitator);
        vm.expectRevert(X402SessionPaths.InvalidSignature.selector);
        paths.goHomeWithSig(id, deadline, forged);

        bytes memory order = _sig(HOME_PK, paths.endDigest(id, deadline));
        uint256 homeEth = home.balance;
        vm.prank(facilitator);
        assertEq(paths.goHomeWithSig(id, deadline, order), 1e6);
        assertEq(usdc.balanceOf(home), 1_000e6, "everything home");
        assertEq(home.balance, homeEth, "without home holding ETH");
        assertTrue(paths.path(id).ended);
    }

    function test_aSessionMayNotOutliveItsPath() public {
        bytes32 id = _declare("p");
        Step memory s = _stepFor(id, merchant, 1e5, "o");
        s.expiry = uint64(block.timestamp + 8 days);
        bytes memory sig13 = _signStep(AGENT_PK, s);
        vm.prank(facilitator);
        vm.expectRevert(
            abi.encodeWithSelector(
                X402SessionPaths.SessionOutlivesPath.selector, s.expiry, uint64(block.timestamp + 7 days)
            )
        );
        _submit(s, sig13);
    }

    // ------------------------------------------------------------------ the condition, under fuzzing

    /// Any sequence of steps, by anyone, to anyone, of any size: the path stays in the box [0, E],
    /// its length stays within |E|_1, money reaches only the named merchants, and the contract holds
    /// exactly what the paths own.
    function testFuzz_anySequenceStaysInsideTheBox(uint256 seed) public {
        bytes32 id = _declare("f");
        address[3] memory who = [merchant, merchant2, attacker];
        uint256 opened = 0;
        for (uint256 i = 0; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            Step memory s = _stepFor(id, who[r % 3], 1 + ((r >> 8) % 4e5), bytes32(i));
            if ((r >> 64) % 5 == 0) s.committed += 1; // a step signed for some other state
            uint256 pk = (r >> 96) % 7 == 0 ? ATTACKER_PK : AGENT_PK;
            if (_try(s, _signStep(pk, s))) ++opened;
            assertLe(paths.committedTo(id, merchant), 6e5);
            assertLe(paths.committedTo(id, merchant2), 4e5);
            assertEq(paths.committedTo(id, attacker), 0);
            X402SessionPaths.Path memory p = paths.path(id);
            assertEq(p.committed, paths.committedTo(id, merchant) + paths.committedTo(id, merchant2));
            assertLe(p.committed, p.bound);
            assertEq(usdc.balanceOf(address(paths)), p.free, "the contract holds exactly what the path has free");
            assertEq(usdc.balanceOf(address(escrow)), p.committed, "and the escrow exactly what it committed");
        }
        assertEq(usdc.balanceOf(attacker), 0);
        assertLe(opened, 24);
    }
}

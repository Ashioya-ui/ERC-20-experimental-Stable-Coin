// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {X402SessionEscrow} from "../../src/vault/X402SessionEscrow.sol";

interface IFiatToken {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice The session escrow against Circle's real USDC on Base: a gasless open from a real
///         EIP-3009 receive authorization, then many calls settled by one redemption.
///         Runs when BASE_RPC_URL is set; skipped otherwise.
contract X402SessionEscrowBaseMainnetForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    uint256 internal constant FUNDER_PK = 0xF00D;
    uint256 internal constant AGENT_PK = 0xA6E7;

    X402SessionEscrow internal escrow;
    address internal funder;
    address internal agent;
    address internal merchant;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        escrow = new X402SessionEscrow();
        funder = vm.addr(FUNDER_PK);
        // A well-known test key may carry an EIP-7702 delegation on live Base, and USDC v2.2 would
        // then check the open through ERC-1271: clear it, so the test is about the escrow alone.
        vm.etch(funder, "");
        agent = vm.addr(AGENT_PK);
        merchant = makeAddr("merchant");
        deal(USDC, funder, 10e6); // USDC only: the funder never holds ETH
    }

    function test_fork_gaslessOpenThenAThousandCallsInOneSettlement() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes32 nonce = escrow.openNonce(merchant, USDC, agent, expiry, "fork");
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, funder, address(escrow), 5e6, 0, block.timestamp + 60, nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            FUNDER_PK, keccak256(abi.encodePacked("\x19\x01", IFiatToken(USDC).DOMAIN_SEPARATOR(), structHash))
        );

        uint256 funderEth = funder.balance; // a well-known test key may hold dust on mainnet
        vm.prank(makeAddr("facilitator"));
        uint256 g = gasleft();
        bytes32 id = escrow.openWithAuthorization(
            funder, merchant, USDC, agent, expiry, "fork", 5e6, 0, block.timestamp + 60, abi.encodePacked(r, s, v)
        );
        emit log_named_uint("gas: openWithAuthorization on real USDC", g - gasleft());
        assertEq(escrow.session(id).deposited, 5e6);
        assertEq(funder.balance, funderEth, "the funder spent no ETH");

        // A thousand calls at $0.0001, settled once.
        uint256 owed = 1_000 * 100;
        (v, r, s) = vm.sign(AGENT_PK, escrow.voucherDigest(id, owed));
        g = gasleft();
        escrow.redeem(id, owed, abi.encodePacked(r, s, v));
        uint256 redeemGas = g - gasleft();
        emit log_named_uint("gas: redeem, covering 1,000 calls", redeemGas);
        emit log_named_uint("gas per call at 1,000 calls per redemption", redeemGas / 1_000);
        assertEq(IERC20(USDC).balanceOf(merchant), owed);

        vm.warp(expiry + 1);
        escrow.reclaim(id);
        assertEq(IERC20(USDC).balanceOf(funder), 10e6 - owed, "everything unspent came back");
        assertEq(IERC20(USDC).balanceOf(address(escrow)), 0);
    }
}

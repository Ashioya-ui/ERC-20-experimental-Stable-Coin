// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {VaultPayRouter} from "../../src/vault/VaultPayRouter.sol";

/// @notice The router against real Base mainnet state: Circle's USDC and Aave's waBasUSDC
///         (Aave v3 Base USDC static aToken, StataTokenV2), as config/8453.json names them.
///         Runs when BASE_RPC_URL is set; skipped otherwise. The contract name matches the main
///         CI's gas-snapshot exclusion, since fork gas depends on live state.
contract VaultPayRouterBaseMainnetForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WA_BAS_USDC = 0xC768c589647798a6EE01A91FdE98EF2ed046DBD6;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 internal constant PAYER_PK = 0xA11CE;

    VaultPayRouter internal router;
    IERC20 internal usdc = IERC20(USDC);
    IERC4626 internal vault = IERC4626(WA_BAS_USDC);
    IERC20 internal shares = IERC20(WA_BAS_USDC);
    address internal payer;
    address internal merchant;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        router = new VaultPayRouter();
        payer = vm.addr(PAYER_PK);
        merchant = makeAddr("merchant");

        assertEq(vault.asset(), USDC, "waBasUSDC holds Base USDC");
        // The agent's treasury: 100 USDC parked in Aave through the static aToken.
        deal(USDC, payer, 100e6);
        vm.startPrank(payer);
        usdc.approve(WA_BAS_USDC, 100e6);
        vault.deposit(100e6, payer);
        vm.stopPrank();
    }

    /// The gasless claim stands on this: an off-chain permit must set the router's allowance.
    function test_fork_waBasUSDCAcceptsAPermit() public {
        VaultPayRouter.Permit memory p = _permit(123);
        IERC20Permit(WA_BAS_USDC).permit(payer, address(router), 123, p.deadline, p.v, p.r, p.s);
        assertEq(shares.allowance(payer, address(router)), 123);
    }

    /// Five cents to a merchant out of an Aave position, with permit, as an x402 payment would.
    function test_fork_paysFiveCentsFromAnAavePosition() public {
        uint256 price = 50_000;
        VaultPayRouter.PayIntent memory it = _intent(merchant, price, keccak256("five cents"));
        bytes memory sig = _sign(it);
        VaultPayRouter.Permit memory p = _permit(it.maxShares);
        uint256 sharesBefore = shares.balanceOf(payer);

        uint256 g = gasleft();
        uint256 spent = router.pay(it, sig, p);
        emit log_named_uint("gas: pay() with permit on waBasUSDC", g - gasleft());

        assertEq(usdc.balanceOf(merchant), price, "merchant paid exactly");
        assertEq(sharesBefore - shares.balanceOf(payer), spent, "payer charged what was spent");
        assertEq(shares.balanceOf(address(router)), 0, "router keeps no shares");
        assertEq(usdc.balanceOf(address(router)), 0, "router keeps no USDC");
    }

    /// The same with a standing allowance, as a smart wallet that cannot sign EIP-2612 would pay.
    function test_fork_paysWithAStandingAllowance() public {
        vm.prank(payer);
        shares.approve(address(router), type(uint256).max);
        VaultPayRouter.PayIntent memory it = _intent(merchant, 1e6, keccak256("standing"));
        bytes memory sig = _sign(it);
        VaultPayRouter.Permit memory none;

        uint256 g = gasleft();
        router.pay(it, sig, none);
        emit log_named_uint("gas: pay() without permit on waBasUSDC", g - gasleft());

        assertEq(usdc.balanceOf(merchant), 1e6);
        assertEq(shares.balanceOf(address(router)), 0);
    }

    /// An agent can spend its whole position: what is left afterwards is under one share.
    function test_fork_spendsAWholePosition() public {
        uint256 everything = vault.maxWithdraw(payer);
        VaultPayRouter.PayIntent memory it = _intent(merchant, everything, keccak256("all"));
        bytes memory sig = _sign(it);
        VaultPayRouter.Permit memory p = _permit(it.maxShares);

        router.pay(it, sig, p);

        assertEq(usdc.balanceOf(merchant), everything);
        assertLe(vault.convertToAssets(shares.balanceOf(payer)), 1, "dust only");
        assertEq(shares.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // ------------------------------------------------------------------ helpers

    function _intent(address payTo, uint256 assets, bytes32 salt)
        internal
        view
        returns (VaultPayRouter.PayIntent memory)
    {
        return VaultPayRouter.PayIntent({
            payer: payer,
            vault: WA_BAS_USDC,
            asset: USDC,
            payTo: payTo,
            assets: assets,
            maxShares: router.sharesToAuthorize(WA_BAS_USDC, assets),
            salt: salt,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 60
        });
    }

    function _sign(VaultPayRouter.PayIntent memory it) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_PK, router.intentDigest(it));
        return abi.encodePacked(r, s, v);
    }

    function _permit(uint256 value) internal view returns (VaultPayRouter.Permit memory p) {
        uint256 deadline = block.timestamp + 60;
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH, payer, address(router), value, IERC20Permit(WA_BAS_USDC).nonces(payer), deadline
            )
        );
        (p.v, p.r, p.s) = vm.sign(
            PAYER_PK, keccak256(abi.encodePacked("\x19\x01", IERC20Permit(WA_BAS_USDC).DOMAIN_SEPARATOR(), structHash))
        );
        p.value = value;
        p.deadline = deadline;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {VaultPayRouter} from "../../src/vault/VaultPayRouter.sol";
import {MockUSDC, MockVault} from "./mocks/VaultMocks.sol";

/// @dev Drives random payments, yield, top-ups and the passage of time. Not a Test itself, so
///      the runner never mistakes it for a suite.
contract VaultPayHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant PAYER_PK = 0xA11CE;

    VaultPayRouter public immutable router;
    MockUSDC public immutable usdc;
    MockVault public immutable vault;
    address public immutable payer;
    address[3] public merchants;

    uint256 public ghostPaid;
    uint256 public ghostPayments;
    uint256 internal salt;

    constructor(VaultPayRouter router_, MockUSDC usdc_, MockVault vault_) {
        router = router_;
        usdc = usdc_;
        vault = vault_;
        payer = vm.addr(PAYER_PK);
        merchants = [makeAddr("merchant-0"), makeAddr("merchant-1"), makeAddr("merchant-2")];
    }

    function pay(uint256 price, uint256 who) external {
        uint256 affordable = vault.maxWithdraw(payer);
        if (affordable == 0) return;
        price = bound(price, 1, affordable);
        VaultPayRouter.PayIntent memory it = VaultPayRouter.PayIntent({
            payer: payer,
            vault: address(vault),
            asset: address(usdc),
            payTo: merchants[who % 3],
            assets: price,
            maxShares: router.sharesToAuthorize(address(vault), price),
            salt: bytes32(++salt),
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 60
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_PK, router.intentDigest(it));
        VaultPayRouter.Permit memory none; // the payer holds a standing allowance
        router.pay(it, abi.encodePacked(r, s, v), none);
        ghostPaid += price;
        ++ghostPayments;
    }

    function accrue(uint256 amount) external {
        usdc.mint(address(vault), bound(amount, 0, 1e9));
    }

    function topUp(uint256 amount) external {
        amount = bound(amount, 1, 1e12);
        usdc.mint(payer, amount);
        vm.startPrank(payer);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, payer);
        vm.stopPrank();
    }

    function elapse(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 1 days));
    }

    function merchantTotal() external view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) total += usdc.balanceOf(merchants[i]);
    }
}

contract VaultPayRouterInvariantTest is Test {
    VaultPayRouter internal router;
    MockUSDC internal usdc;
    MockVault internal vault;
    VaultPayHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        router = new VaultPayRouter();
        usdc = new MockUSDC();
        vault = new MockVault(usdc);
        handler = new VaultPayHandler(router, usdc, vault);

        address payer = handler.payer();
        usdc.mint(payer, 1e9);
        vm.startPrank(payer);
        usdc.approve(address(vault), 1e9);
        vault.deposit(1e9, payer);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();

        bytes4[] memory actions = new bytes4[](4);
        actions[0] = VaultPayHandler.pay.selector;
        actions[1] = VaultPayHandler.accrue.selector;
        actions[2] = VaultPayHandler.topUp.selector;
        actions[3] = VaultPayHandler.elapse.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    /// The router never keeps anything: not a share, not a unit of the asset.
    function invariant_routerHoldsNothing() public view {
        assertEq(vault.balanceOf(address(router)), 0, "shares left in the router");
        assertEq(usdc.balanceOf(address(router)), 0, "asset left in the router");
    }

    /// Merchants have received exactly the sum of the prices paid, no more and no less.
    function invariant_merchantsReceiveExactlyWhatWasPaid() public view {
        assertEq(handler.merchantTotal(), handler.ghostPaid());
    }

    /// Guards against a vacuous run: the campaign must actually have made payments.
    function afterInvariant() public view {
        assertGt(handler.ghostPayments(), 0, "no payment ever succeeded");
    }
}

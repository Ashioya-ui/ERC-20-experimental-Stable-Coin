// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {MockUSDC, MockVault} from "../mocks/VaultMocks.sol";

/// @dev Shared world for the review PoCs (audit/vault-router-review.md). The same state as
///      test/vault/VaultPayRouter.t.sol: a payer with 1,000 USDC in a vault whose shares cost
///      1.05 USDC. Intents are built the way x402/agent.mjs builds them: validAfter = now - 600,
///      validBefore = now + 60, maxShares = router.sharesToAuthorize, a fresh salt per attempt.
///      Time is read through vm.getBlockTimestamp(): under via-IR a test function may not see its
///      own vm.warp through block.timestamp.
abstract contract VaultPayRouterReviewFixture is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 internal constant PAYER_PK = 0xA11CE;

    VaultPayRouter internal router;
    MockUSDC internal usdc;
    MockVault internal vault;
    address internal payer;
    address internal merchant;
    address internal facilitator;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(30_000_000);
        router = new VaultPayRouter();
        usdc = new MockUSDC();
        vault = new MockVault(usdc);
        payer = vm.addr(PAYER_PK);
        merchant = makeAddr("merchant");
        facilitator = makeAddr("facilitator");
        _deposit(vault, payer, 1_000e6);
        usdc.mint(address(vault), 50e6); // accrued yield: a share now costs 1.05 USDC
    }

    function _deposit(MockVault v, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(v), amount);
        v.deposit(amount, who);
        vm.stopPrank();
    }

    function _intentFor(address who, address vault_, address payTo, uint256 assets, bytes32 salt)
        internal
        view
        returns (VaultPayRouter.PayIntent memory)
    {
        uint256 t = vm.getBlockTimestamp();
        return VaultPayRouter.PayIntent({
            payer: who,
            vault: vault_,
            asset: IERC4626(vault_).asset(),
            payTo: payTo,
            assets: assets,
            maxShares: router.sharesToAuthorize(vault_, assets),
            salt: salt,
            validAfter: t - 600,
            validBefore: t + 60
        });
    }

    function _sign(uint256 pk, VaultPayRouter.PayIntent memory it) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, router.intentDigest(it));
        return abi.encodePacked(r, s, v);
    }

    function _permit(uint256 pk, MockVault v, uint256 value, uint256 deadline)
        internal
        view
        returns (VaultPayRouter.Permit memory p)
    {
        address holder = vm.addr(pk);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, holder, address(router), value, v.nonces(holder), deadline));
        (p.v, p.r, p.s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", v.DOMAIN_SEPARATOR(), structHash)));
        p.value = value;
        p.deadline = deadline;
    }

    function _noPermit() internal pure returns (VaultPayRouter.Permit memory p) {}

    /// @dev pay() as a raw call with `gasLimit`: whether it succeeded, its return or revert data, and
    ///      the gas the call consumed. Measured from inside a contract call: `gasleft()` in the test
    ///      body reads nearly nothing under
    ///      `forge test --isolate` (the call becomes its own transaction), and `vm.lastCallGas()`
    ///      cannot be decoded with this toolchain (see test/mocks/OracleGasMeter.sol). `pay` is
    ///      permissionless, so the meter submitting it in `from`'s place changes nothing measured.
    function _payRaw(
        address from,
        VaultPayRouter.PayIntent memory it,
        bytes memory sig,
        VaultPayRouter.Permit memory p,
        uint256 gasLimit
    ) internal returns (bool ok, bytes memory ret, uint256 used) {
        bytes memory data = abi.encodeWithSelector(VaultPayRouter.pay.selector, it, sig, p);
        CallMeter meter = new CallMeter();
        vm.prank(from);
        (ok, ret, used) = meter.callWithGas(address(router), data, gasLimit);
    }
}

/// @dev Makes one call with a fixed gas limit and reports the gas it consumed, measured inside the EVM.
contract CallMeter {
    function callWithGas(address target, bytes calldata data, uint256 gasLimit)
        external
        returns (bool ok, bytes memory ret, uint256 used)
    {
        uint256 g = gasleft();
        (ok, ret) = target.call{gas: gasLimit}(data);
        used = g - gasleft();
    }
}

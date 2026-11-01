// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {VaultPayRouter} from "../../../src/vault/VaultPayRouter.sol";
import {VaultPayRouterReviewFixture} from "./ReviewFixture.sol";

/// @dev An ERC-1271 wallet whose signatures hold on even blocks only. On odd blocks it burns the
///      gas it was given before answering no. A view function can do both.
contract ParityWallet is IERC1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (block.number % 2 == 1) {
            while (gasleft() > 5_000) {}
            return bytes4(0xffffffff);
        }
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && signer == owner
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "not the owner");
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }
}

/// F-4 (audit/vault-router-review.md). A payer can hand a facilitator an intent that simulates
/// cleanly against the latest block, which is what x402/facilitator.mjs does twice before sending,
/// and that reverts once included. It costs the payer nothing and can be repeated with fresh salts.
/// The permit half is fixed (PermitExpiresBeforeIntent; guarded in RegressionF4.t.sol). What is
/// left is a known limitation, kept as a test: a signature whose validity depends on the block,
/// which no router can rule out. This test PASSES while that remains true; the facilitator's
/// per-payer failure budget is what bounds it.
contract VaultPayRouterReview_FacilitatorGriefTest is VaultPayRouterReviewFixture {
    /// An ERC-1271 wallet (or an EIP-7702 delegate) keyed on block parity: valid in the simulation
    /// at the latest block, invalid one block later, after burning nearly all the gas the submitter
    /// allowed for the transaction.
    function test_aWalletKeyedOnBlockParityBurnsTheGasLimit() public {
        uint256 ownerPk = 0xC0FFEE;
        ParityWallet wallet = new ParityWallet(vm.addr(ownerPk));
        _deposit(vault, address(wallet), 100e6);
        vm.prank(vm.addr(ownerPk));
        wallet.execute(address(vault), abi.encodeCall(vault.approve, (address(router), type(uint256).max)));
        VaultPayRouter.PayIntent memory it =
            _intentFor(address(wallet), address(vault), merchant, 1e6, keccak256("parity"));
        bytes memory sig = _sign(ownerPk, it);

        vm.roll(30_000_000); // the latest block: even
        uint256 snap = vm.snapshotState();
        router.pay(it, sig, _noPermit());
        assertEq(usdc.balanceOf(merchant), 1e6, "the simulation pays");
        vm.revertToState(snap);

        vm.roll(30_000_001); // included one block later: odd
        uint256 gasLimit = 300_000; // about what eth_estimateGas returns for the success path
        (bool ok, bytes memory ret, uint256 used) = _payRaw(facilitator, it, sig, _noPermit(), gasLimit);
        assertFalse(ok, "reverts once included");
        assertEq(ret, abi.encodeWithSelector(VaultPayRouter.InvalidSignature.selector));
        assertGt(used, (gasLimit * 9) / 10, "nearly the whole gas limit is gone");
        emit log_named_uint("gas the submitter pays for nothing", used);
        assertEq(usdc.balanceOf(merchant), 0, "nobody was paid");
    }
}

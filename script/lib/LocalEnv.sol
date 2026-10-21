// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

import {LendingVaultMock} from "../../test/mocks/LendingVaultMock.sol";
import {IFiatToken, IFiatTokenProxy} from "./IFiatToken.sol";

/// @title  LocalEnv
/// @notice A mainnet-shaped stand-in for Base on a local chain: Circle's real FiatToken v2.2
///         bytecode as USDC (test/artifacts), a real Uniswap v4 PoolManager built from source,
///         and two lending-vault stand-ins (primary and fallback). Local use only.
library LocalEnv {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev runtime code of the Arachnid CREATE2 proxy (for in-memory test EVMs that lack it)
    bytes internal constant CREATE2_PROXY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    struct Env {
        address usdc;
        address poolManager;
        address vault;
        address fallbackVault;
    }

    /// @param deployer   Caller of every transaction; becomes USDC master minter and minter.
    /// @param proxyAdmin Admin of the USDC proxy (must differ from the deployer).
    function deploy(address deployer, address proxyAdmin) internal returns (Env memory e) {
        e.usdc = deployFiatToken(deployer, proxyAdmin);
        e.poolManager = address(new PoolManager(deployer));
        e.vault = address(new LendingVaultMock(IERC20(e.usdc), "Aave-like USDC vault (local)", "laUSDC"));
        e.fallbackVault = address(new LendingVaultMock(IERC20(e.usdc), "Morpho-like USDC vault (local)", "lmUSDC"));
    }

    function deployFiatToken(address deployer, address proxyAdmin) internal returns (address proxy) {
        // FiatToken v2.2 links the external SignatureChecker library (as on mainnet).
        address sigLib = _create(vm.parseBytes(vm.readFile("test/artifacts/SignatureChecker.bin")));
        bytes memory impl = vm.parseBytes(vm.readFile("test/artifacts/FiatTokenV2_2.bin"));
        uint256[] memory offsets =
            vm.parseJsonUintArray(vm.readFile("test/artifacts/FiatTokenV2_2.linkrefs.json"), ".byteOffsets");
        for (uint256 i; i < offsets.length; ++i) {
            bytes20 libBytes = bytes20(sigLib);
            for (uint256 k; k < 20; ++k) {
                impl[offsets[i] + k] = libBytes[k];
            }
        }
        address implementation = _create(impl);
        bytes memory proxyCode =
            abi.encodePacked(vm.parseBytes(vm.readFile("test/artifacts/FiatTokenProxy.bin")), abi.encode(implementation));
        proxy = _create(proxyCode);
        IFiatTokenProxy(proxy).changeAdmin(proxyAdmin);
        IFiatToken usdc = IFiatToken(proxy);
        usdc.initialize("USD Coin", "USDC", "USD", 6, deployer, deployer, deployer, deployer);
        usdc.initializeV2("USD Coin");
        usdc.initializeV2_1(deployer);
        usdc.initializeV2_2(new address[](0), "USDC");
        usdc.configureMinter(deployer, type(uint256).max);
    }

    function _create(bytes memory code) private returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), "LocalEnv: create failed");
    }
}

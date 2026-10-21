# Dependencies (Phase 4, A13)

Every dependency is a git submodule pinned to one commit. `script/check-deps.sh` fails CI if
any of them moves away from the commit listed here, so a pin can only change together with
this document.

## Libraries compiled into the protocol

| Dependency | Version | Commit | Used for | Why this pin |
|---|---|---|---|---|
| OpenZeppelin Contracts | v5.4.0 (tag) | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` | ERC-20/2612/4626, `AccessControlDefaultAdminRules`, `Pausable`, `ReentrancyGuardTransient`, `SafeERC20`, `Math`, `SafeCast`, `ECDSA`/`SignatureChecker`, `Nonces` | Latest release with the audited transient reentrancy guard (EIP-1153 is live on Base). |
| Uniswap v4-core | v4.0.0 + 12 commits ("1.0.2") | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` | `IHooks`, `IPoolManager`, `Hooks`, `PoolKey`, `PoolId`, `Currency`, `BalanceDelta`, `TickMath`, `StateLibrary`, `LPFeeLibrary`; the real `PoolManager` in tests | See below: identical in logic and ABI to the v4.0.0 PoolManager deployed on Base. |

**v4-core after the tag.** The 12 commits after `v4.0.0` change nothing the hook depends on:
in `src/` outside `src/test`, the only edits move `ModifyLiquidityParams` and `SwapParams` from
`IPoolManager` into `types/PoolOperation.sol` and update the signatures that use them. The
structs and function selectors are unchanged, so the hook compiled here is ABI-compatible with
the PoolManager on Base (`0x498581fF718922c3f8e6A244956aF099B2652b2b`), and the local tests run
the same pool logic. Checked with `git diff v4.0.0 59d3ecf -- src/libraries src/interfaces
src/PoolManager.sol src/types`.

## Test and script dependencies (nothing from them is deployed)

| Dependency | Version | Commit | Used for | Why this pin |
|---|---|---|---|---|
| forge-std | v1.17.0 (tag) | `f3dae6e6ee381f25eb6a246f7da9b85c91a68219` | tests and scripts | Latest release. Note: its `Gas` struct has six fields and Foundry 1.5.1's `lastCallGas` returns five, so `vm.lastCallGas()` reverts; the gas tests measure from inside a contract instead (A8). |
| Uniswap v4-periphery | `main`, 2026-09-19 (untagged) | `9969eec44cfdf07e24b41de47f40276a58401976` | `LiquidityAmounts` (pool seeding in tests and the rehearsal), `HookMiner` (one test); it also carries v4-core as its submodule | Justified rather than retagged: v4-periphery publishes no release tags, nothing from it reaches the deployed bytecode, and the v4-core it pins is reviewed above. |

The nested submodules of OpenZeppelin and v4-periphery (their own forge-std, permit2, solmate,
erc4626-tests, halmos-cheatcodes) are used only by those projects' tests. None is compiled into
the protocol.

## Toolchain

| Tool | Version | Source and verification |
|---|---|---|
| Foundry (forge, cast, anvil) | 1.5.1 | GitHub release; CI installs the same version through `foundry-rs/foundry-toolchain` pinned by commit. |
| solc | 0.8.26 | GitHub release `solc-static-linux`, sha256 `d5f23436…f149ef`, equal to the value in `github.com/ethereum/solc-bin` `linux-amd64/list.json`. |

The security tools used in Phase 4 and their provenance are in `audit/tools.md`.

## Vendored bytecode

| Artifact | Source | Verification |
|---|---|---|
| `test/artifacts/FiatToken*.bin`, `SignatureChecker.bin` | Circle FiatToken v2.2 | `test/artifacts/README.md` |
| `test/artifacts/morpho/*.bin` | Morpho Blue v1.0.0 (`55d2d99`) and MetaMorpho v1.0.0 (`f5faa9c`), built by `script/vendor/build-morpho-artifacts.sh` with solc 0.8.19 and 0.8.21, both checked against solc-bin's sha256 | `test/artifacts/README.md` |

Local tests only; none of it is deployed.

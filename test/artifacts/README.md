# Third-party bytecode used by the local mainnet rehearsal

These files let the rehearsal run the real Circle USDC contract (FiatToken v2.2, the version
deployed as native USDC on Base) without a network connection to Base.

| File | Contract |
|---|---|
| `FiatTokenV2_2.bin` | `contracts/v2/FiatTokenV2_2.sol:FiatTokenV2_2` (creation bytecode) |
| `FiatTokenProxy.bin` | `contracts/v1/FiatTokenProxy.sol:FiatTokenProxy` (creation bytecode, constructor arg appended at deploy) |
| `SignatureChecker.bin` | `contracts/util/SignatureChecker.sol:SignatureChecker`, the external library FiatToken v2.2 links to (as on mainnet) |
| `FiatTokenV2_2.linkrefs.json` | Byte offsets where the library address is written; in `FiatTokenV2_2.bin` the solc link placeholder `__$7151…$__` is zeroed |

Provenance (rebuild to check):

- Source: https://github.com/circlefin/stablecoin-evm at commit `fc85788bc7c23cefe3df1a757133048bfddadeaa`
- OpenZeppelin Contracts v3.4.2 (commit `8e0296096449d9b1cd7c5631e917330635244c37`) for `@openzeppelin/contracts/`
- Compiler: solc 0.6.12+commit.27d51765, optimizer on, 10,000,000 runs (Circle's setting)

```bash
solc-0.6.12 --optimize --optimize-runs 10000000 --combined-json abi,bin,bin-runtime \
  @openzeppelin/contracts/=<oz-3.4.2>/contracts/ --allow-paths <root> \
  contracts/v2/FiatTokenV2_2.sol contracts/v1/FiatTokenProxy.sol
# then zero the SignatureChecker placeholder in FiatTokenV2_2 and record its byte offsets
```

Licence: Apache-2.0 (Circle), MIT (OpenZeppelin). Used for local testing only; nothing here is
deployed to a public network.

# Morpho Blue and MetaMorpho v1.0 (Phase 4, A12)

`morpho/` holds the creation bytecode of the real Morpho Blue and MetaMorpho v1.0 contracts,
so `test/realvault/MorphoReplica.t.sol` can run the protocol against the code behind Gauntlet
USDC Prime (the fallback vault in `config/8453.json`) without a Base RPC.

| File | Contract | sha256 |
|---|---|---|
| `morpho/Morpho.bin` | Morpho Blue `src/Morpho.sol:Morpho` | `73224b3d5fa7cb807e1894b2be8123262aeafbaa95efbcc5dbec2a3288be2192` |
| `morpho/MetaMorpho.bin` | MetaMorpho `src/MetaMorpho.sol:MetaMorpho` | `7e5523907eb5a215bd7bd8ae04edd41000484fc36a81271188c8a5a885d656d7` |
| `morpho/IrmMock.bin` | Morpho Blue `src/mocks/IrmMock.sol` (x% utilisation = x% APR) | `56dd933205cf6c3865b284d5479b4a9e011a44667d0b9fdfcf03a64b9bdff868` |
| `morpho/OracleMock.bin` | Morpho Blue `src/mocks/OracleMock.sol` | `7aa3d8affd994067ce4b6091bd95c8093bc1bda1054eb465b84e9ae229cb1beb` |
| `morpho/ERC20Mock.bin` | Morpho Blue `src/mocks/ERC20Mock.sol` (the collateral token) | `a72ef4342313e39307947ee1fdc92eaf14e40cc9c4837649fdaf5c733ad84fdf` |

Provenance (rebuild to check: `script/vendor/build-morpho-artifacts.sh <work-dir>`):

- Morpho Blue: https://github.com/morpho-org/morpho-blue tag `v1.0.0`, commit
  `55d2d99304fb3fb930c688462ae2ccabb1d533ad`; solc 0.8.19, via-IR, 999,999 runs, EVM paris.
- MetaMorpho: https://github.com/morpho-org/metamorpho tag `v1.0.0`, commit
  `f5faa9c21b1396c291b471a6a5ad9407d23486a9`, with its pinned submodules (OpenZeppelin
  `932fddf69a699a9a80fd2396fd1a2ab91cdda123`, Morpho Blue `55d2d99`); solc 0.8.21, via-IR, 200
  runs (its `hardhat.config.ts`), EVM paris.
- Compilers: the `solc-static-linux` assets of the Solidity GitHub releases v0.8.19 and
  v0.8.21, sha256 `7a5c1d3d…cd9eb48` and `f2857a89…f145a81df`, equal to the values in
  `github.com/ethereum/solc-bin` `linux-amd64/list.json`.

Built with each project's release settings, but not byte-compared with the contracts deployed
on Base (that needs a Base RPC): the metadata hash at least differs, since it covers local
paths. Licence: GPL-2.0-or-later (Morpho). Local testing only; nothing here is deployed.

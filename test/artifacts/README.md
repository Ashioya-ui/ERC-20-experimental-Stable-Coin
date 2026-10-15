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

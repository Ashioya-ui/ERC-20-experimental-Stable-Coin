# Tools used in Phase 4, and where they came from

The workspace that ran Phase 4 reaches GitHub (git and release assets) but not PyPI,
crates.io, npm, `binaries.soliditylang.org` or any Base RPC: those return HTTP 403 from the
network policy. Nothing was routed around a refusal. Every tool was installed from its
official GitHub source or release instead, pinned and, where a checksum is published, verified.

| Tool | Version | Source | Verification |
|---|---|---|---|
| Foundry (forge, cast, anvil) | 1.5.1 | GitHub release | CI installs the same version through `foundry-rs/foundry-toolchain` pinned by commit |
| solc | 0.8.26 | Solidity GitHub release, `solc-static-linux` | sha256 `d5f23436f443edb85d8e76906d12f0a86ce0490e7663a9e608efeb7a93f149ef`, equal to `github.com/ethereum/solc-bin` `linux-amd64/list.json` |
| solc (Morpho artifacts only) | 0.8.19, 0.8.21 | Solidity GitHub releases | sha256 `7a5c1d3d…cd9eb48`, `f2857a89…f145a81df`, equal to solc-bin's list |
| Slither | 0.11.6 | `github.com/crytic/slither` at `050cc0a094e77bfd58e8228ae3bb6aa15c65edb4` | pinned commit; CI installs `slither-analyzer==0.11.6` from PyPI |
| crytic-compile | 0.4.2 | `github.com/crytic/crytic-compile` at `b4f7d296d141ee8fb806cb573daaf3369e9bd125` | pinned commit |
| Halmos | 0.3.3 | `github.com/a16z/halmos` at `ba94bdc232c746b61f12eeacef6136eace81c7c2` | pinned commit |
| z3 (Halmos's branching checks) | 4.12.6 | `z3_solver-4.12.6.0` wheel from the `z3-4.12.6` GitHub release | sha256 `dca097b9a3026a63019eba65fe7ad120dcccec847cc33a7c0e548cfe324680fc` |
| Bitwuzla (Halmos's assertion solver) | 0.8.1 | GitHub release, fetched by Halmos | Halmos checks the sha256 pinned in its `solvers.py` (`d88ca19b…bb1d8`) |
| Yices | 2.6.4 | GitHub release, fetched by Halmos | sha256 pinned in Halmos (`84118450…601a4`); used only for a first trial run |
| Gambit (mutation testing) | 1.0.6 | `github.com/Certora/gambit` release binary | sha256 `76321d84564ff4d8222bfb359f1fe67eae69f21e689dbc9c23760257a94864fa` |
| Aderyn | 0.6.8 | `github.com/Cyfrin/aderyn` release `aderyn-v0.6.8` | sha256 `ffd6ca658962e211a3ac821c646f69c8e14bf1b1001cbfe091bcd4535a691e46` |
| actionlint | 1.7.12 | `github.com/rhysd/actionlint` release | sha256 `8aca8db9…` (see the release's checksums file) |

Python packages Slither and Halmos need, built from their GitHub sources into one virtual
environment:

| Package | Version | Commit |
|---|---|---|
| solc-select | v1.1.0 | `0ec2946474fed4523bf91cb1f11f0b75a3a4bc76` |
| cbor2 | 5.9.0 | `93c598838d50b554e242920902aada82d32d55bc` |
| pycryptodome | v4.0.0 | `b60bcd5d04813b9fcc86b76d12f26ea4dd1f286e` |
| prettytable | 3.18.0 | `069405f00ea1075e28dc738b8c52fd3bff173520` |
| wcwidth | 0.9.2 | `f1793abb4ebace173e307294fc15d8eb0d8fdb88` |
| sortedcontainers | v2.4.0 | `a1f52d6713dd2c2713a881d4f4d86ed68ff71cab` |
| eth-hash | v0.8.0 | `b599a9632c696d0fb63b1903e79b0608f302e4d2` |
| rich | v14.0.0 | `72e3bb33d44fd96881f7742b77137983907a942f` |
| markdown-it-py | v4.2.0 | `36c5f547144df2d01970a5792d68c71a3380b227` |
| mdurl | 0.1.2 | `596bf1c8752de45fa576a52c315d6d8cc5bb1a4e` |
| pygments | 2.21.0 | `a43b45dcf081b6010c6ab4428f149f7f6d2499c4` |
| python-dotenv | v1.2.4 | `a565c2cc41599c48eabc6b7b7f5b826d43c5a6d7` |
| psutil | release-7.2.2 | `9eea97dd6f1d16ea33f5144c8925f1ce7a0688e1` |
| xxhash | v3.8.1 | `0a1adf7b6a5f26b821272985a0a987cca5446c23` |

## Reproducing the analyses

    slither . --filter-paths "lib/|test/|script/" --exclude-dependencies \
      --triage-database audit/slither.db.json --fail-medium
    aderyn . --src src
    FOUNDRY_OUT=out-halmos FOUNDRY_CACHE_PATH=cache-halmos halmos --forge-build-out out-halmos \
      --match-contract Halmos --function check_ --loop 9 --solver bitwuzla-abs \
      --solver-timeout-assertion 10m
    gambit mutate ...           # see audit/mutation.md
    forge coverage --ir-minimum --report summary

Halmos uses its own build directory because it needs the AST, which a normal `forge build`
does not keep, and Foundry's cache does not tell the two builds apart.

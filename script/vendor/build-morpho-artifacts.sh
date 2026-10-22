#!/usr/bin/env bash
# Rebuild test/artifacts/morpho/*.bin: the creation bytecode of the real Morpho Blue and
# MetaMorpho v1.0 contracts, compiled from their GitHub sources at pinned tags, for the
# local real-vault tests (test/realvault/MorphoReplica.t.sol, Phase 4 A12).
#
# Gauntlet USDC Prime, the fallback vault in config/8453.json, is a MetaMorpho v1.0 vault on
# Morpho Blue. This lets the protocol run against that code without a Base RPC.
#
# Usage: script/vendor/build-morpho-artifacts.sh <work-dir>
# Needs: git, sha256sum, and network access to github.com only.
set -euo pipefail

WORK="${1:?usage: $0 <work-dir>}"
OUT="$(cd "$(dirname "$0")/../.." && pwd)/test/artifacts/morpho"
mkdir -p "$WORK" "$OUT"
WORK="$(cd "$WORK" && pwd)"

MORPHO_BLUE_TAG=v1.0.0     # commit 55d2d99304fb3fb930c688462ae2ccabb1d533ad
METAMORPHO_TAG=v1.0.0      # commit f5faa9c21b1396c291b471a6a5ad9407d23486a9

# Official solc static builds from the GitHub releases, checked against the sha256 values
# published in github.com/ethereum/solc-bin (linux-amd64/list.json).
declare -A SOLC_SHA256=(
  [0.8.19]=7a5c1d3dc9a8eba62bb2ec37192c9178ae5fe8a54a56e5573fd3c9c17cd9eb48
  [0.8.21]=f2857a898be15c69e8de5598dcd3f3e169e94964a0ce9a0bbb1b111f145a81df
)
for v in 0.8.19 0.8.21; do
  f="$WORK/solc-$v"
  [[ -f "$f" ]] || curl -sSL -o "$f" "https://github.com/ethereum/solidity/releases/download/v$v/solc-static-linux"
  echo "${SOLC_SHA256[$v]}  $f" | sha256sum -c -
  chmod +x "$f"
done

[[ -d "$WORK/morpho-blue" ]] || git clone -q --depth 1 --branch "$MORPHO_BLUE_TAG" https://github.com/morpho-org/morpho-blue.git "$WORK/morpho-blue"
[[ -d "$WORK/metamorpho" ]] || {
  git clone -q --depth 1 --branch "$METAMORPHO_TAG" https://github.com/morpho-org/metamorpho.git "$WORK/metamorpho"
  git -C "$WORK/metamorpho" submodule update -q --init --depth 1 lib/openzeppelin-contracts lib/morpho-blue
}
test "$(git -C "$WORK/morpho-blue" rev-parse HEAD)" = 55d2d99304fb3fb930c688462ae2ccabb1d533ad
test "$(git -C "$WORK/metamorpho" rev-parse HEAD)" = f5faa9c21b1396c291b471a6a5ad9407d23486a9
test "$(git -C "$WORK/metamorpho/lib/morpho-blue" rev-parse HEAD)" = 55d2d99304fb3fb930c688462ae2ccabb1d533ad

# Each repository's own release settings: via-IR and EVM paris; Morpho Blue with 999,999
# optimizer runs (its foundry.toml), MetaMorpho with 200 (its hardhat.config.ts; its
# foundry.toml spells the key "optimization_runs", which Foundry ignores, so 200 there too,
# and 999,999 would take it over the 24,576-byte limit).
# solc runs from outside the cloned repositories and reads them as plain files.
build() { # <solc> <runs> <root> <source> <out-subdir>
  "$1" --base-path "$3" --via-ir --optimize --optimize-runs "$2" --evm-version paris \
    --bin --overwrite -o "$WORK/build/$5" "$3/$4" >/dev/null
}
build "$WORK/solc-0.8.19" 999999 "$WORK/morpho-blue" src/Morpho.sol blue
build "$WORK/solc-0.8.19" 999999 "$WORK/morpho-blue" src/mocks/IrmMock.sol mocks
build "$WORK/solc-0.8.19" 999999 "$WORK/morpho-blue" src/mocks/OracleMock.sol mocks
build "$WORK/solc-0.8.19" 999999 "$WORK/morpho-blue" src/mocks/ERC20Mock.sol mocks
build "$WORK/solc-0.8.21" 200 "$WORK/metamorpho" src/MetaMorpho.sol metamorpho

for pair in blue/Morpho mocks/IrmMock mocks/OracleMock mocks/ERC20Mock metamorpho/MetaMorpho; do
  name="${pair#*/}"
  printf '0x%s' "$(tr -d '\n' < "$WORK/build/$pair.bin")" > "$OUT/$name.bin"
  echo "$name.bin  $(sha256sum "$OUT/$name.bin" | cut -d' ' -f1)"
done

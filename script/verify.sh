#!/usr/bin/env bash
# Verify every Spectrum contract on an explorer with explicit constructor arguments.
# Reads deployments/<chainId>.json written by DeployBaseMainnet.s.sol.
#
#   script/verify.sh [chainId] [etherscan|blockscout|sourcify]
#   (default: 8453 etherscan; needs ETHERSCAN_API_KEY for etherscan)
#
# Run from the same commit and foundry.toml as the deployment (solc 0.8.26, via-IR,
# optimizer runs 44,444,444, evm cancun, bytecode_hash none), or the bytecode won't match.
# Exits non-zero if any contract fails to verify, after trying all of them.
set -euo pipefail
cd "$(dirname "$0")/.."
CHAIN="${1:-8453}"
VERIFIER="${2:-etherscan}"
D="deployments/${CHAIN}.json"
[[ -f "$D" ]] || { echo "missing $D"; exit 1; }
j() { python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$D" "$1"; }
# A JSON array of addresses in the form cast expects: [0xa,0xb]
jarr() { python3 -I -c "import json,sys; print('[' + ','.join(json.load(open(sys.argv[1]))[sys.argv[2]]) + ']')" "$D" "$1"; }
jbool() { python3 -I -c "import json,sys; print(str(json.load(open(sys.argv[1])).get(sys.argv[2], False)).lower())" "$D" "$1"; }

case "$VERIFIER" in
  etherscan)  VFLAGS=(--verifier etherscan --etherscan-api-key "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY}") ;;
  blockscout) VFLAGS=(--verifier blockscout --verifier-url "${BLOCKSCOUT_URL:-https://base.blockscout.com/api/}") ;;
  sourcify)   VFLAGS=(--verifier sourcify) ;;
  *) echo "unknown verifier $VERIFIER"; exit 1 ;;
esac

FAILED=()
verify() {
  local addr="$1" target="$2" args="$3"
  echo "== $target @ $addr"
  if forge verify-contract "$addr" "$target" --chain "$CHAIN" "${VFLAGS[@]}" --constructor-args "$args" --watch; then
    echo "   verified"
  else
    echo "   FAILED"
    FAILED+=("$target @ $addr")
  fi
}

verify "$(j treasury)" src/AutonomousTreasury.sol:AutonomousTreasury \
  "$(cast abi-encode 'constructor(address,uint256,address)' "$(j vault)" "$(j liquidityBufferBps)" "$(j stabilizer)")"
verify "$(j sUSD)" src/SpectralToken.sol:SpectralToken \
  "$(cast abi-encode 'constructor(address)' "$(j stabilizer)")"
verify "$(j oracle)" src/SpectralEntropyOracle.sol:SpectralEntropyOracle \
  "$(cast abi-encode 'constructor(address,uint256,uint256,uint256,uint256)' "$(j hook)" "$(j minObservation)" "$(j emaAlphaMax)" "$(j emaTau)" "$(j staleAfter)")"
# Eight arguments since Phase 4 (A5): the vault allowlist is the last one.
verify "$(j stabilizer)" src/SpectralStabilizer.sol:SpectralStabilizer \
  "$(cast abi-encode 'constructor(address,address,address,address,address,uint256,uint256,address[])' "$(j sUSD)" "$(j treasury)" "$(j oracle)" "$(j admin)" "$(j guardian)" "$(j bootstrapCap)" "$(j supplyCap)" "$(jarr allowedVaults)")"
verify "$(j wsUSD)" src/WrappedSUSD.sol:WrappedSUSD \
  "$(cast abi-encode 'constructor(address)' "$(j sUSD)")"
verify "$(j lens)" src/SpectrumLens.sol:SpectrumLens \
  "$(cast abi-encode 'constructor(address)' "$(j stabilizer)")"
# The hook was created through the CREATE2 proxy: explorers cannot extract its arguments.
verify "$(j hook)" src/SpectralHook.sol:SpectralHook \
  "$(cast abi-encode 'constructor(address,address,address,address,uint24,int24)' "$(j poolManager)" "$(j oracle)" "$(j wsUSD)" "$(j usdc)" "$(j poolFee)" "$(j tickSpacing)")"
if [[ "$(jbool testVaults)" == "true" ]]; then
  verify "$(j vault)" script/lib/TestnetVault.sol:TestnetVault \
    "$(cast abi-encode 'constructor(address,string,string)' "$(j usdc)" 'Spectrum TEST vault A (no yield, testnet)' 'tvUSDC-A')"
  verify "$(j fallbackVault)" script/lib/TestnetVault.sol:TestnetVault \
    "$(cast abi-encode 'constructor(address,string,string)' "$(j usdc)" 'Spectrum TEST vault B (no yield, testnet)' 'tvUSDC-B')"
fi

if (( ${#FAILED[@]} )); then
  echo "Not verified:"; printf '  %s\n' "${FAILED[@]}"
  exit 1
fi
echo "All verified. Re-run with 'blockscout' or 'sourcify' for a second explorer if you like."

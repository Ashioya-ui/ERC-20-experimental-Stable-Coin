#!/usr/bin/env bash
# Verify every Spectrum contract on an explorer with explicit constructor arguments.
# Reads deployments/<chainId>.json written by DeployBaseMainnet.s.sol.
#
#   script/verify.sh [chainId] [etherscan|blockscout|sourcify]
#   (default: 8453 etherscan; needs ETHERSCAN_API_KEY for etherscan)
#
# Run from the same commit and foundry.toml as the deployment (solc 0.8.26, via-IR,
# optimizer runs 44,444,444, evm cancun, bytecode_hash none), or the bytecode won't match.
set -euo pipefail
cd "$(dirname "$0")/.."
CHAIN="${1:-8453}"
VERIFIER="${2:-etherscan}"
D="deployments/${CHAIN}.json"
[[ -f "$D" ]] || { echo "missing $D"; exit 1; }
j() { python3 -c "import json;print(json.load(open('$D'))['$1'])"; }

case "$VERIFIER" in
  etherscan)  VFLAGS=(--verifier etherscan --etherscan-api-key "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY}") ;;
  blockscout) VFLAGS=(--verifier blockscout --verifier-url "${BLOCKSCOUT_URL:-https://base.blockscout.com/api/}") ;;
  sourcify)   VFLAGS=(--verifier sourcify) ;;
  *) echo "unknown verifier $VERIFIER"; exit 1 ;;
esac

verify() {
  local addr="$1" target="$2" args="$3"
  echo "== $target @ $addr"
  if [[ -n "$args" ]]; then
    forge verify-contract "$addr" "$target" --chain "$CHAIN" "${VFLAGS[@]}" --constructor-args "$args" --watch || true
  else
    forge verify-contract "$addr" "$target" --chain "$CHAIN" "${VFLAGS[@]}" --watch || true
  fi
}

verify "$(j treasury)" src/AutonomousTreasury.sol:AutonomousTreasury \
  "$(cast abi-encode 'constructor(address,uint256)' "$(j vault)" "$(j liquidityBufferBps)")"
verify "$(j sUSD)" src/SpectralToken.sol:SpectralToken ""
verify "$(j oracle)" src/SpectralEntropyOracle.sol:SpectralEntropyOracle \
  "$(cast abi-encode 'constructor(address,uint256,uint256,uint256)' "$(j deployer)" "$(j minObservation)" "$(j emaAlpha)" "$(j staleAfter)")"
verify "$(j stabilizer)" src/SpectralStabilizer.sol:SpectralStabilizer \
  "$(cast abi-encode 'constructor(address,address,address,address,address,uint256,uint256)' "$(j sUSD)" "$(j treasury)" "$(j oracle)" "$(j admin)" "$(j guardian)" "$(j bootstrapCap)" "$(j supplyCap)")"
verify "$(j wsUSD)" src/WrappedSUSD.sol:WrappedSUSD \
  "$(cast abi-encode 'constructor(address)' "$(j sUSD)")"
# The hook was created through the CREATE2 proxy: explorers cannot extract its arguments.
verify "$(j hook)" src/SpectralHook.sol:SpectralHook \
  "$(cast abi-encode 'constructor(address,address,address,address,uint24,int24)' "$(j poolManager)" "$(j oracle)" "$(j wsUSD)" "$(j usdc)" "$(j poolFee)" "$(j tickSpacing)")"

echo "Done. Re-run with 'blockscout' or 'sourcify' as a second verifier if you like."

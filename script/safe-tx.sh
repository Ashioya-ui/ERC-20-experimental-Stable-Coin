#!/usr/bin/env bash
# Build a Safe Transaction Builder batch (JSON) for a Spectrum governance action.
# Upload the file in the Safe app: Apps -> Transaction Builder -> drag and drop.
#
#   script/safe-tx.sh <action> [args]      (reads deployments/${CHAIN_ID:-8453}.json)
#
# Actions (role needed):
#   pause | unpause                          GUARDIAN
#   emergency-exit                           GUARDIAN
#   cancel-migration                         GUARDIAN
#   set-supply-cap <whole sUSD>              ADMIN
#   set-buffer <bps>                         ADMIN   (1500 = 15% of the reserve idle)
#   propose-vault <vault address>            ADMIN   (executable after 7 days)
#   execute-migration                        ADMIN
#   grant-guardian <address>                 ADMIN
#   revoke-guardian <address>                ADMIN
set -euo pipefail
cd "$(dirname "$0")/.."
CHAIN="${CHAIN_ID:-8453}"
D="deployments/${CHAIN}.json"
[[ -f "$D" ]] || { echo "missing $D"; exit 1; }
STAB=$(python3 -c "import json;print(json.load(open('$D'))['stabilizer'])")
GUARDIAN_ROLE=$(cast keccak "GUARDIAN_ROLE")
ACTION="${1:-}"; shift || true

case "$ACTION" in
  pause)             DATA=$(cast calldata "pause()") ;;
  unpause)           DATA=$(cast calldata "unpause()") ;;
  emergency-exit)    DATA=$(cast calldata "emergencyExitVault()") ;;
  cancel-migration)  DATA=$(cast calldata "cancelVaultMigration()") ;;
  set-supply-cap)    DATA=$(cast calldata "setSupplyCap(uint256)" "$(cast to-wei "${1:?whole sUSD}")") ;;
  set-buffer)        DATA=$(cast calldata "setLiquidityBuffer(uint256)" "${1:?bps}") ;;
  propose-vault)     DATA=$(cast calldata "proposeVault(address)" "${1:?vault}") ;;
  execute-migration) DATA=$(cast calldata "executeVaultMigration()") ;;
  grant-guardian)    DATA=$(cast calldata "grantRole(bytes32,address)" "$GUARDIAN_ROLE" "${1:?address}") ;;
  revoke-guardian)   DATA=$(cast calldata "revokeRole(bytes32,address)" "$GUARDIAN_ROLE" "${1:?address}") ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac

mkdir -p safe-tx
OUT="safe-tx/${CHAIN}-${ACTION}-$(date -u +%Y%m%dT%H%M%SZ).json"
cat > "$OUT" <<JSON
{
  "version": "1.0",
  "chainId": "${CHAIN}",
  "createdAt": $(date +%s)000,
  "meta": { "name": "Spectrum: ${ACTION} ${*:-}", "description": "SpectralStabilizer ${STAB}" },
  "transactions": [ { "to": "${STAB}", "value": "0", "data": "${DATA}" } ]
}
JSON
echo "to:   $STAB"
echo "data: $DATA"
echo "file: $OUT  (Safe app -> Transaction Builder -> drop the file)"

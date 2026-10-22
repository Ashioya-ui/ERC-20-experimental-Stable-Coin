#!/usr/bin/env bash
set -uo pipefail
D=deployments/84532.json
for a in $(jq -r '[.sUSD,.treasury,.oracle,.stabilizer,.wsUSD,.lens,.hook]|.[]' $D) $(jq -r .router deployments/84532-router.json); do
  echo "=== $a"
  echo -n "  v1 check-all-by-addresses: "
  curl -sS --max-time 30 "https://sourcify.dev/server/check-all-by-addresses?addresses=$a&chainIds=84532" | head -c 400; echo
  echo -n "  v2 /v2/contract/84532/:     "
  curl -sS --max-time 30 "https://sourcify.dev/server/v2/contract/84532/$a" | head -c 400; echo
  echo -n "  v1 /files/any/84532/:       "
  curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "https://sourcify.dev/server/files/any/84532/$a"; echo
  echo -n "  blockscout verified?:       "
  curl -sS --max-time 30 "https://base-sepolia.blockscout.com/api/v2/smart-contracts/$a" | head -c 300; echo
done

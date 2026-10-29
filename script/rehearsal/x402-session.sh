#!/usr/bin/env bash
# x402 sessions end to end on anvil: X402SessionEscrow deployed through the CREATE2 deployer exactly
# as it will be on mainnet, then a facilitator, a merchant and an agent that never holds ETH making
# SESSION_CALLS (default 1000) paid calls at 0.0001 USDC each. Asserts one open and one redemption.
#
#   script/rehearsal/x402-session.sh            a fresh anvil with Circle's FiatToken v2.2 bytecode as USDC
#   script/rehearsal/x402-session.sh --fork     a fork of Base mainnet, Circle's live USDC (BASE_RPC_URL)
#
# Transactions come from anvil's unlocked accounts (local only) or keystores made for the run.
set -euo pipefail
cd "$(dirname "$0")/../.."

MODE=${1:-local}
PORT=${SESSION_PORT:-8548}
RPC=http://127.0.0.1:$PORT
# anvil's default accounts 0 and 9: unlocked on anvil only, never used anywhere else
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
USDC_PROXY_ADMIN=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then echo "port $PORT is in use; stop that node first"; exit 1; fi
if [ "$MODE" = --fork ]; then
  anvil --silent --block-time 2 --port "$PORT" --fork-url "${BASE_RPC_URL:?set BASE_RPC_URL to a Base mainnet endpoint}" >/dev/null 2>&1 &
else
  anvil --silent --block-time 2 --port "$PORT" >/dev/null 2>&1 &
fi
ANVIL=$!
TMP=$(mktemp -d)
trap 'kill "$ANVIL" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 1 90); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
CHAIN=$(cast chain-id --rpc-url "$RPC")

if [ "$MODE" = --fork ]; then
  [ "$CHAIN" = 8453 ] || { echo "the fork is not Base mainnet"; exit 1; }
  echo "fork of Base mainnet at block $(cast block-number --rpc-url "$RPC")"
else
  USDC_PROXY_ADMIN=$USDC_PROXY_ADMIN FOUNDRY_PROFILE=vault forge script script/vault/LocalUSDC.s.sol \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" >"$TMP/usdc.log" 2>&1 || { tail -30 "$TMP/usdc.log"; exit 1; }
  USDC=$(python3 -c "import json;print(json.load(open('deployments/31337-usdc.json'))['usdc'])")
  echo "{\"external\":{\"usdc\":\"$USDC\"}}" >"$TMP/network.json"
  # This chain has only USDC and the escrow: no stale Spectrum deployment file may be read for it.
  export NETWORK_CONFIG=$TMP/network.json DEPLOYMENT=$TMP/none.json
  echo "local chain $CHAIN, FiatToken v2.2 USDC at $USDC"
fi

FOUNDRY_PROFILE=vault forge script script/vault/DeployX402SessionEscrow.s.sol \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" >"$TMP/escrow.log" 2>&1 || { tail -30 "$TMP/escrow.log"; exit 1; }
cat "deployments/$CHAIN-session-escrow.json"; echo

(cd x402 && RPC_URL=$RPC SESSION_E2E=1 node --test --test-concurrency=1 --test-reporter=spec test/session.e2e.mjs)

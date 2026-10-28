#!/usr/bin/env bash
# Rehearses the Base mainnet x402 rail on an anvil fork of Base mainnet: VaultPayRouter deployed
# onto the fork through the CREATE2 deployer exactly as it will be on mainnet, then a facilitator,
# a merchant and an agent paying real x402 invoices out of a real Aave position (waBasUSDC), in
# real Circle USDC. Nothing leaves the fork.
#
#   BASE_RPC_URL=https://mainnet.base.org script/rehearsal/x402-vault-fork.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

FORK_URL=${BASE_RPC_URL:?set BASE_RPC_URL to a Base mainnet endpoint}
PORT=${VAULT_FORK_PORT:-8547}
RPC=http://127.0.0.1:$PORT
# anvil's default account 0: unlocked on anvil only, never used anywhere else
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then echo "port $PORT is in use; stop that node first"; exit 1; fi
anvil --silent --port "$PORT" --fork-url "$FORK_URL" >/dev/null 2>&1 &
ANVIL=$!
trap 'kill "$ANVIL" 2>/dev/null || true' EXIT
for _ in $(seq 1 90); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC")" = 8453 ] || { echo "the fork is not Base mainnet"; exit 1; }
echo "fork of Base mainnet at block $(cast block-number --rpc-url "$RPC")"

FOUNDRY_PROFILE=vault forge script script/vault/DeployVaultPayRouter.s.sol \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER"
cat deployments/8453-vault-router.json; echo

(cd x402 && RPC_URL=$RPC VAULT_FORK=1 node --test --test-concurrency=1 --test-reporter=spec test/vault-fork.e2e.mjs)

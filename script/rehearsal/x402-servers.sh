#!/usr/bin/env bash
# (Re)start the facilitator and the merchant against the chain that `x402.sh --serve` set up,
# e.g. after editing their code. Runs in the foreground until stopped.
#
# Usage: script/rehearsal/x402-servers.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source x402/.tmp/current/env.sh

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
wait_http() { for _ in $(seq 1 100); do curl -sf "$1" >/dev/null 2>&1 && return 0; sleep 0.2; done; echo "no answer from $1"; exit 1; }

FAC_PORT="${FACILITATOR_URL##*:}"
MER_PORT="${MERCHANT_URL##*:}"
FACILITATOR_PORT=$FAC_PORT FACILITATOR_SIGNER="unlocked:$X402_FACILITATOR_ACCOUNT" \
  node x402/facilitator.mjs >> "$X402_RUN/facilitator.log" 2>&1 &
PIDS+=($!)
wait_http "$FACILITATOR_URL/health"
MERCHANT_PORT=$MER_PORT MERCHANT_PAYTO=$MERCHANT node x402/merchant.mjs >> "$X402_RUN/merchant.log" 2>&1 &
PIDS+=($!)
wait_http "$MERCHANT_URL/health"
echo "facilitator $FACILITATOR_URL and merchant $MERCHANT_URL are up (logs in $X402_RUN)"
wait

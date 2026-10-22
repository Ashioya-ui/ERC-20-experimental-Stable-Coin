#!/usr/bin/env bash
# The x402 rail on a local, Base-shaped chain (anvil, chain 31337, 2-second blocks).
#
#   1. FiatToken v2.2 USDC, Uniswap v4 PoolManager, vault stand-ins   (LocalMainnetEnv.s.sol)
#   2. Spectrum, with the mainnet deployment script                    (DeployBaseMainnet.s.sol)
#   3. LP and swaps so the entropy oracle is live                       (Scenario.s.sol)
#   4. The sUSD-to-USDC pay router                                      (DeployPayRouter.s.sol)
#   5. Encrypted keystores for the agents, funded with test money
#   6. Facilitator and merchant as local HTTP servers
#   7. Demo: an agent that holds only sUSD pays a sUSD API, a USDC API through the router and a
#      USDC-only API by converting, then earns while idle
#   8. Node end-to-end tests (x402/test)
#
# Transactions come from anvil's unlocked accounts or from keystores made for this run; no
# private key appears on a command line. Test money on a local chain only.
#
# Usage: script/rehearsal/x402.sh           run everything, then stop the chain and servers
#        script/rehearsal/x402.sh --serve   set up steps 1-6 and keep serving (for agents);
#                                           `source x402/.tmp/current/env.sh` to use it
# Output: rehearsal/x402.log
set -euo pipefail
cd "$(dirname "$0")/../.."

MODE="${1:-run}"
PORT="${X402_RPC_PORT:-8545}"
RPC="http://127.0.0.1:$PORT"
FAC_PORT="${FACILITATOR_PORT:-4020}"
MER_PORT="${MERCHANT_PORT:-4021}"

# anvil's default accounts, unlocked on anvil only (never use them anywhere else)
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export REHEARSAL_ADMIN=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export REHEARSAL_GUARDIAN=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
export REHEARSAL_PAYER=0x90F79bf6EB2c4f870365E785982E1f101E93b906
export REHEARSAL_USDC_PROXY_ADMIN=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
FACILITATOR=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65   # pays the settlement gas

mkdir -p rehearsal deployments x402/.tmp
LOG=rehearsal/x402.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

RUN="$PWD/x402/.tmp/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN/wallets"
chmod 700 "$RUN" "$RUN/wallets"
ln -sfn "$RUN" x402/.tmp/current

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

step() { printf '\n==== %s ====\n' "$*"; }
jget() { python3 -c "import json,sys;print(json.load(open('$1'))$2)"; }
send() { cast send --rpc-url "$RPC" --unlocked --from "$DEPLOYER" "$@" >/dev/null; }
fscript() { # forge script with the deployer unlocked; output kept in the run folder
  local name="$1"; shift
  if ! forge script "$@" --rpc-url "$RPC" --broadcast --slow --unlocked --sender "$DEPLOYER" > "$RUN/$name.log" 2>&1; then
    tail -40 "$RUN/$name.log"; echo "FAILED: $name"; exit 1
  fi
}
wait_http() { for _ in $(seq 1 100); do curl -sf "$1" >/dev/null 2>&1 && return 0; sleep 0.2; done; echo "no answer from $1"; exit 1; }

step "0. anvil: chain 31337, a block every 2 seconds, transactions mined on arrival"
if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then echo "port $PORT is in use; stop that node first"; exit 1; fi
anvil --silent --port "$PORT" --chain-id 31337 --block-time 2 --mixed-mining >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

step "1-3. USDC (FiatToken v2.2), v4 PoolManager, Spectrum (mainnet script), oracle live"
fscript env script/rehearsal/LocalMainnetEnv.s.sol
SPECTRUM_CONFIG=deployments/31337-config.json fscript deploy script/DeployBaseMainnet.s.sol
fscript seed script/rehearsal/Scenario.s.sol --sig "seedPoolAndSwap()"
D=deployments/31337.json
STAB=$(jget $D "['stabilizer']"); SUSD=$(jget $D "['sUSD']"); USDC=$(jget $D "['usdc']")
TREAS=$(jget $D "['treasury']"); ORACLE=$(jget $D "['oracle']")
echo "sUSD $SUSD   stabilizer $STAB   USDC $USDC"
echo "oracle filled: $(cast call "$ORACLE" 'filled()(uint8)' --rpc-url "$RPC")"

step "4. SpectrumPayRouter"
fscript router script/DeployPayRouter.s.sol
ROUTER=$(jget deployments/31337-router.json "['router']")
echo "router $ROUTER"
echo "sUSD to pay 0.05 USDC: $(cast call "$ROUTER" 'sUSDFor(uint256)(uint256)' 50000 --rpc-url "$RPC")"

step "5. Agent wallets: encrypted keystores, test money"
PW="$RUN/wallets/password"
(umask 077; head -c 32 /dev/urandom | base64 | tr -d '\n' > "$PW")
mkwallet() {
  CAST_PASSWORD="$(cat "$PW")" cast wallet new "$RUN/wallets" "$1" --json \
    | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['address'])"
  chmod 600 "$RUN/wallets/$1"
}
mint_susd() { # $1 receiver, $2 USDC (6 decimals) to deposit
  send "$USDC" "mint(address,uint256)" "$DEPLOYER" "$2"
  send "$USDC" "approve(address,uint256)" "$STAB" "$2"
  send "$STAB" "mint(uint256,address,uint256)" "$2" "$1" 0
}
CLIENT=$(mkwallet client); MERCHANT=$(mkwallet merchant); REVIEWER=$(mkwallet reviewer); REDTEAM=$(mkwallet redteam)
mint_susd "$CLIENT" 600000000    # the client agent's treasury: 600 USDC deposited, held as sUSD
mint_susd "$REDTEAM" 25000000    # a 25 USDC float in sUSD for the red-team agent's own x402 bills
echo "client   $CLIENT   sUSD $(cast call "$SUSD" 'balanceOf(address)(uint256)' "$CLIENT" --rpc-url "$RPC")"
echo "redteam  $REDTEAM   sUSD $(cast call "$SUSD" 'balanceOf(address)(uint256)' "$REDTEAM" --rpc-url "$RPC")"
echo "reviewer $REVIEWER   merchant $MERCHANT"
echo '{"items":[]}' > "$RUN/market.json"
cat > "$RUN/env.sh" <<EOF
# x402 rail on the local chain ($(date -u +%FT%TZ)); test money only
export RPC_URL=$RPC
export FACILITATOR_URL=http://127.0.0.1:$FAC_PORT
export MERCHANT_URL=http://127.0.0.1:$MER_PORT
export X402_RUN=$RUN
export X402_WALLETS=$RUN/wallets
export AGENT_PASSWORD_FILE=$PW
export MARKET_FILE=$RUN/market.json
export CLIENT=$CLIENT MERCHANT=$MERCHANT REVIEWER=$REVIEWER REDTEAM=$REDTEAM
export SUSD=$SUSD USDC=$USDC STABILIZER=$STAB TREASURY=$TREAS ROUTER=$ROUTER
export X402_FUNDER=$DEPLOYER X402_FACILITATOR_ACCOUNT=$FACILITATOR
EOF

step "6. Facilitator (:$FAC_PORT) and merchant (:$MER_PORT)"
RPC_URL=$RPC FACILITATOR_PORT=$FAC_PORT FACILITATOR_SIGNER="unlocked:$FACILITATOR" \
  node x402/facilitator.mjs > "$RUN/facilitator.log" 2>&1 &
PIDS+=($!)
wait_http "http://127.0.0.1:$FAC_PORT/health"
RPC_URL=$RPC MERCHANT_PORT=$MER_PORT FACILITATOR_URL="http://127.0.0.1:$FAC_PORT" MERCHANT_PAYTO=$MERCHANT \
  MARKET_FILE="$RUN/market.json" node x402/merchant.mjs > "$RUN/merchant.log" 2>&1 &
PIDS+=($!)
wait_http "http://127.0.0.1:$MER_PORT/health"
cat "$RUN/facilitator.log" "$RUN/merchant.log"
curl -s "http://127.0.0.1:$FAC_PORT/supported" > "$RUN/supported.json"
python3 -c "import json;d=json.load(open('$RUN/supported.json'));[print('  kind:', k['extra']) for k in d['kinds']];print('  extensions:', d['extensions'])"

if [[ "$MODE" == "--serve" ]]; then
  step "SERVING: source x402/.tmp/current/env.sh (Ctrl-C or kill to stop)"
  wait
  exit 0
fi

step "7. Demo: one sUSD balance pays every kind of x402 bill, and earns while idle"
# shellcheck disable=SC1091
source "$RUN/env.sh"
node x402/demo.mjs

step "8. Node end-to-end tests"
(cd x402 && RPC_URL=$RPC X402_FUNDER=$DEPLOYER X402_FACILITATOR_ACCOUNT=$FACILITATOR \
  node --test --test-concurrency=1 --test-reporter=spec "test/*.test.mjs")

step "X402 REHEARSAL PASSED"

#!/usr/bin/env bash
# Full mainnet rehearsal on a local, Base-shaped chain.
#
# Runs the exact mainnet deployment script (script/DeployBaseMainnet.s.sol) against anvil
# with Circle FiatToken v2.2 as USDC and a real Uniswap v4 PoolManager, then the
# post-deploy check, day-one flows, keeper calls, an emergency vault exit and a 7-day
# timelocked migration, all with the same cast commands as RUNBOOK_MAINNET.md.
#
# Usage: script/rehearsal/run.sh            (needs forge, cast, anvil on PATH)
# Output: rehearsal/latest.log
set -euo pipefail
cd "$(dirname "$0")/../.."

RPC="${REHEARSAL_RPC:-http://127.0.0.1:8545}"
mkdir -p rehearsal deployments
LOG="rehearsal/latest.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

# anvil's well-known default accounts (never use these keys anywhere else)
PK_DEPLOYER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PK_ADMIN=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d   # stands in for the Safe
export REHEARSAL_ADMIN=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
PK_GUARDIAN=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
export REHEARSAL_GUARDIAN=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
export REHEARSAL_PAYER_PK=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
export REHEARSAL_PAYER=0x90F79bf6EB2c4f870365E785982E1f101E93b906
export REHEARSAL_FACILITATOR_PK=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
PK_KEEPER=$REHEARSAL_FACILITATOR_PK
export REHEARSAL_MERCHANT=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
export REHEARSAL_USDC_PROXY_ADMIN=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720

ANVIL_PID=""
if [[ -z "${REHEARSAL_RPC:-}" ]]; then
  anvil --silent --port 8545 --chain-id 31337 >/dev/null 2>&1 &
  ANVIL_PID=$!
  trap '[[ -n "$ANVIL_PID" ]] && kill $ANVIL_PID 2>/dev/null || true' EXIT
  for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
fi

step() { printf '\n==== %s ====\n' "$*"; }
jget() { python3 -c "import json,sys;print(json.load(open('$1'))$2)"; }
warp() { cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null; }
expect_revert() { if "$@" >/dev/null 2>&1; then echo "EXPECTED A REVERT: $*"; exit 1; else echo "reverted as expected"; fi; }

step "1. Base-shaped chain: FiatToken v2.2 USDC, v4 PoolManager, vault stand-ins"
forge script script/rehearsal/LocalMainnetEnv.s.sol --rpc-url "$RPC" --broadcast --slow \
  --private-key "$PK_DEPLOYER" | grep -E "USDC|PoolManager|vault|config written|ONCHAIN" || true

step "2. Mainnet deployment script (identical to Base), config = mainnet parameters"
SPECTRUM_CONFIG=deployments/31337-config.json forge script script/DeployBaseMainnet.s.sol \
  --rpc-url "$RPC" --broadcast --slow --private-key "$PK_DEPLOYER" --sender "$DEPLOYER" \
  | sed -n '/== Logs ==/,$p' | grep -vE "^\s*$" | head -60

D=deployments/31337.json
STAB=$(jget $D "['stabilizer']"); TOKEN=$(jget $D "['sUSD']"); ORACLE=$(jget $D "['oracle']")
LENS=$(jget $D "['lens']")
TREAS=$(jget $D "['treasury']"); HOOK=$(jget $D "['hook']")
USDC=$(jget deployments/31337-env.json "['usdc']"); VAULT=$(jget deployments/31337-env.json "['vault']")
FALLBACK=$(jget deployments/31337-env.json "['fallbackVault']")

step "3. Post-deploy check (read-only, same script as mainnet)"
SPECTRUM_CONFIG=deployments/31337-config.json forge script script/PostDeployCheck.s.sol --rpc-url "$RPC" \
  | sed -n '/== Logs ==/,$p' | grep -vE "^\s*$"

step "4. Hook address carries exactly beforeInitialize|afterSwap (0x2040)"
python3 -c "a=int('$HOOK',16); f=a & 0x3fff; print(hex(f)); assert f==0x2040"

step "5. LP at par and nine swaps, one block each: the oracle fills and folds"
forge script script/rehearsal/Scenario.s.sol --sig "seedPoolAndSwap()" --rpc-url "$RPC" --broadcast --slow \
  --private-key "$PK_DEPLOYER" --sender "$DEPLOYER" | grep -E "ONCHAIN|Error" || true
echo "oracle filled:   $(cast call $ORACLE 'filled()(uint8)' --rpc-url $RPC)"
echo "oracle window:   $(cast call $ORACLE 'window()(uint256[8])' --rpc-url $RPC)"
echo "smoothed H:      $(cast call $ORACLE 'smoothedEntropy()(uint256)' --rpc-url $RPC)"

step "6. x402 payment in sUSD (EIP-3009), settled by a facilitator that pays gas"
forge script script/rehearsal/Scenario.s.sol --sig "payWithSUSD()" --rpc-url "$RPC" --broadcast --slow \
  | grep -E "x402|ONCHAIN|Error" || true
echo "merchant sUSD:   $(cast call $TOKEN 'balanceOf(address)(uint256)' $REHEARSAL_MERCHANT --rpc-url $RPC)"

step "7. Keeper: protocol capital covers the buffer, so fees and yield are distributable from day one"
echo "protocol capital: $(cast call $STAB 'protocolCapital()(uint256)' --rpc-url $RPC)"
echo "distributable:    $(cast call $LENS 'distributable()(uint256)' --rpc-url $RPC)"
warp 3601
echo "index before:     $(cast call $TOKEN 'index()(uint256)' --rpc-url $RPC)"
cast send "$STAB" "rebase()" --private-key "$PK_KEEPER" --rpc-url "$RPC" >/dev/null
echo "index after fees: $(cast call $TOKEN 'index()(uint256)' --rpc-url $RPC)"
VA=$(cast call "$VAULT" 'totalAssets()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
cast send "$USDC" "mint(address,uint256)" "$VAULT" $((VA * 6 / 100)) --private-key "$PK_DEPLOYER" --rpc-url "$RPC" >/dev/null
warp 3601
cast send "$STAB" "rebase()" --private-key "$PK_KEEPER" --rpc-url "$RPC" >/dev/null
echo "index after yield: $(cast call $TOKEN 'index()(uint256)' --rpc-url $RPC)"
expect_revert cast send "$STAB" "rebase()" --private-key "$PK_KEEPER" --rpc-url "$RPC"   # once an hour
cast send "$STAB" "rebalanceReserve()" --private-key "$PK_KEEPER" --rpc-url "$RPC" >/dev/null
echo "reserve ratio:    $(cast call $LENS 'reserveRatio()(uint256)' --rpc-url $RPC)"

step "8. Guardian: emergency exit from the vault (runbook E1)"
cast send "$STAB" "emergencyExitVault()" --private-key "$PK_GUARDIAN" --rpc-url "$RPC" >/dev/null
echo "vault shares:    $(cast call $VAULT 'balanceOf(address)(uint256)' $TREAS --rpc-url $RPC)"
echo "idle USDC:       $(cast call $TREAS 'idleAssets()(uint256)' --rpc-url $RPC)"
echo "buffer bps:      $(cast call $TREAS 'liquidityBufferBps()(uint256)' --rpc-url $RPC)"

step "9. Admin (Safe): timelocked migration to the fallback vault (runbook E2)"
cast send "$STAB" "proposeVault(address)" "$FALLBACK" --private-key "$PK_ADMIN" --rpc-url "$RPC" >/dev/null
expect_revert cast send "$STAB" "executeVaultMigration()" --private-key "$PK_ADMIN" --rpc-url "$RPC"
warp 604801
cast send "$STAB" "executeVaultMigration()" --private-key "$PK_ADMIN" --rpc-url "$RPC" >/dev/null
cast send "$STAB" "setLiquidityBuffer(uint256)" 1500 --private-key "$PK_ADMIN" --rpc-url "$RPC" >/dev/null
cast send "$STAB" "rebalanceReserve()" --private-key "$PK_KEEPER" --rpc-url "$RPC" >/dev/null
echo "treasury vault:  $(cast call $TREAS 'vault()(address)' --rpc-url $RPC)  (fallback: $FALLBACK)"
echo "fallback shares: $(cast call $FALLBACK 'balanceOf(address)(uint256)' $TREAS --rpc-url $RPC)"

step "10. Guardian cannot use admin powers; nobody can pause redemptions"
expect_revert cast send "$STAB" "setSupplyCap(uint256)" 1 --private-key "$PK_GUARDIAN" --rpc-url "$RPC"
cast send "$STAB" "pause()" --private-key "$PK_GUARDIAN" --rpc-url "$RPC" >/dev/null
cast send "$STAB" "redeem(uint256,address,uint256)" 100000000000000000000 "$REHEARSAL_PAYER" 0 \
  --private-key "$REHEARSAL_PAYER_PK" --rpc-url "$RPC" >/dev/null && echo "redeem while paused: ok"
cast send "$STAB" "unpause()" --private-key "$PK_GUARDIAN" --rpc-url "$RPC" >/dev/null

step "11. Post-deploy check again after migration"
SPECTRUM_CONFIG=deployments/31337-config.json forge script script/PostDeployCheck.s.sol --rpc-url "$RPC" \
  | sed -n '/== Logs ==/,$p' | grep -vE "^\s*$"

step "REHEARSAL PASSED"

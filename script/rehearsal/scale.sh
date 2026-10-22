#!/usr/bin/env bash
# Neobank-scale rehearsal (Phase 5): the deployed system at EtherFi size, on the local
# Base-shaped chain, with real transactions.
#
# 1. script/rehearsal/run.sh: the mainnet deployment script, the post-deploy check and the
#    runbook steps (FiatToken v2.2 USDC, a real v4 PoolManager, lending-vault stand-ins).
# 2. On the same chain: the admin raises the supply cap; deposits ramp to $300m under the daily
#    expansion cap, sized each day with lens.maxMintAssets; three days of hourly card spend
#    ($600m a year) with top-ups, 5% vault yield and hourly rebases, first without and then with
#    the operator's first-loss capital; a liquidity crunch with a large exit, an exit sized with
#    lens.maxRedeem and card settlement waiting for liquidity; a migration refused by its loss
#    bound while the vault is illiquid and executed once it is liquid; the post-deploy check.
#
# Usage: script/rehearsal/scale.sh        (needs forge, cast, anvil on PATH; about 5 minutes)
# Output: rehearsal/scale.log (and rehearsal/latest.log from step 1)
set -euo pipefail
cd "$(dirname "$0")/../.."

RPC=http://127.0.0.1:8545
mkdir -p rehearsal
anvil --silent --port 8545 --chain-id 31337 >/dev/null 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

REHEARSAL_RPC=$RPC script/rehearsal/run.sh >/dev/null
exec > >(tee rehearsal/scale.log) 2>&1
echo "step 1: deployment and runbook rehearsal: $(tail -1 rehearsal/latest.log)"

# anvil's well-known default accounts (never use these keys anywhere else)
PK_DEPLOYER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # USDC minter here
PK_ADMIN=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d      # stands in for the Safe
PK_KEEPER=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
USERS=0x976EA74026E726554dB657fA54763abd0C3a0aa9                                  # the card users' deposits
PK_USERS=0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
SETTLE=0x14dC79964da2C08b23698B3D3cc7Ca32193d9955                                 # the card program
PK_SETTLE=0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
HOLDER=0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f                                 # a large holder
PK_HOLDER=0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97

jget() { python3 -c "import json;print(json.load(open('$1'))$2)"; }
py() { python3 -c "print($1)"; }
send() { cast send "$@" --rpc-url "$RPC" >/dev/null; }
call() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
warp() { cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null; }
usd() { python3 -c "print(f'\${$1 / 10**$2:,.0f}')"; }
step() { printf '\n==== %s ====\n' "$*"; }
reverts() { # run a send that must revert; print the decoded custom error
  local out data name
  if out=$(cast send "$@" --rpc-url "$RPC" 2>&1); then echo "EXPECTED A REVERT"; exit 1; fi
  data=$(echo "$out" | grep -oE '0x[0-9a-fA-F]{8,}' | tail -1)
  for name in "InsufficientLiquidity(uint256)" "MigrationLossTooHigh(uint256,uint256)"; do
    if [[ "${data:0:10}" == "$(cast sig "$name")" ]]; then
      echo "reverted: ${name%%(*}($(cast calldata-decode "$name" "$data" | awk '{print $1}' | paste -sd, -))"
      return
    fi
  done
  echo "reverted: $(echo "$out" | grep -oE 'execution reverted[^,]*' | head -1)"
}

D=deployments/31337.json
STAB=$(jget $D "['stabilizer']"); TOKEN=$(jget $D "['sUSD']"); LENS=$(jget $D "['lens']"); TREAS=$(jget $D "['treasury']")
ORACLE=$(jget $D "['oracle']")
USDC=$(jget deployments/31337-env.json "['usdc']")
PRIMARY=$(jget deployments/31337-env.json "['vault']")
MAXU=$(py "2**256-1")
E18=1000000000000000000

step "S1. The admin raises the supply cap for scale (25,000 -> 400m sUSD)"
send "$STAB" "setSupplyCap(uint256)" "$(py "400_000_000 * 10**18")" --private-key "$PK_ADMIN"
echo "supply cap: $(usd "$(call "$STAB" 'supplyCap()(uint256)')" 18)"

step "S2. Deposits ramp to \$300m under the daily expansion cap (lens.maxMintAssets each day)"
send "$USDC" "approve(address,uint256)" "$STAB" "$MAXU" --private-key "$PK_USERS"
TARGET=$(py "300_000_000 * 10**18")
days=0
while [[ $(py "int($(call "$TOKEN" 'totalSupply()(uint256)') < $TARGET)") == 1 ]]; do
  room=$(call "$LENS" "maxMintAssets()(uint256)")
  send "$USDC" "mint(address,uint256)" "$USERS" "$room" --private-key "$PK_DEPLOYER"
  send "$STAB" "mint(uint256,address,uint256)" "$room" "$USERS" 0 --private-key "$PK_USERS"
  warp 86400
  days=$((days + 1))
  if (( days % 20 == 0 )); then echo "day $days: supply $(usd "$(call "$TOKEN" 'totalSupply()(uint256)')" 18)"; fi
done
echo "day $days: supply $(usd "$(call "$TOKEN" 'totalSupply()(uint256)')" 18): \$300m reached in $days days of maximal minting at H = $(py "$(call "$ORACLE" 'smoothedEntropy()(uint256)') / 10**18")"

card_hours() { # $1 hours of card spend, top-ups, 5% yield and a rebase attempt each hour
  local dist=0 h vault pos
  for h in $(seq 1 "$1"); do
    warp 3600
    vault=$(call "$TREAS" "vault()(address)")
    pos=$(call "$vault" "previewRedeem(uint256)(uint256)" "$(call "$vault" "balanceOf(address)(uint256)" "$TREAS")")
    send "$USDC" "mint(address,uint256)" "$vault" "$(py "$pos * 5570 // 10**9")" --private-key "$PK_DEPLOYER"
    send "$TOKEN" "transfer(address,uint256)" "$SETTLE" "$(py "68_493 * 10**18")" --private-key "$PK_USERS"
    send "$STAB" "redeem(uint256,address,uint256)" "$MAXU" "$SETTLE" 0 --private-key "$PK_SETTLE"
    send "$USDC" "mint(address,uint256)" "$USERS" "$(py "68_493 * 10**6")" --private-key "$PK_DEPLOYER"
    send "$STAB" "mint(uint256,address,uint256)" "$(py "68_493 * 10**6")" "$USERS" 0 --private-key "$PK_USERS"
    if cast send "$STAB" "rebase()" --private-key "$PK_KEEPER" --rpc-url "$RPC" >/dev/null 2>&1; then dist=$((dist + 1)); fi
  done
  send "$STAB" "rebalanceReserve()" --private-key "$PK_KEEPER"
  echo "rebases that distributed: $dist of $1"
}

step "S3a. 24 hours of card spend (\$600m a year) with only the launch capital (1,250 USDC)"
i0=$(call "$TOKEN" "index()(uint256)")
card_hours 24
i1=$(call "$TOKEN" "index()(uint256)")
echo "card spend settled in USDC: $(usd "$(call "$USDC" 'balanceOf(address)(uint256)' "$SETTLE")" 6)"
echo "index change: $(py "$i1 - $i0") wei (the 2.75% buffer must fill first)"
echo "distributable now: $(usd "$(call "$LENS" 'distributable()(uint256)')" 18)"

# Capital must cover the 2.75% buffer of the supply as it is, not of a round $300m: the last
# day's mint overshoots, and with too little capital nothing is distributed.
CAPITAL=$(py "-(-$(call "$TOKEN" 'totalSupply()(uint256)') * 275 // 10_000 // 10**12)")
step "S3b. The operator posts first-loss capital of 2.75% of supply ($(usd "$CAPITAL" 6)), then two more days"
send "$USDC" "mint(address,uint256)" "$(cast wallet address --private-key "$PK_DEPLOYER")" "$CAPITAL" --private-key "$PK_DEPLOYER"
send "$USDC" "approve(address,uint256)" "$STAB" "$MAXU" --private-key "$PK_DEPLOYER"
send "$STAB" "contributeCapital(uint256)" "$CAPITAL" --private-key "$PK_DEPLOYER"
echo "protocol capital: $(usd "$(call "$STAB" 'protocolCapital()(uint256)')" 18)"
i2=$(call "$TOKEN" "index()(uint256)")
card_hours 24
i3=$(call "$TOKEN" "index()(uint256)")
echo "first day: $(py "round(($i3 - $i2) / $i2 * 1e4, 2)") bp (mostly the ramp's mint fees, held back until the buffer was covered)"
card_hours 24
i4=$(call "$TOKEN" "index()(uint256)")
echo "second day: $(py "round(($i4 - $i3) / $i3 * 1e4, 3)") bp, about $(py "round(($i4 - $i3) / $i3 * 365 * 100, 2)")% a year (5% on the 85% invested, the capital's yield, card-spend fees)"
echo "reserve ratio: $(py "$(call "$LENS" 'reserveRatio()(uint256)') / 10**18")   liquidity ratio: $(py "round($(call "$LENS" 'liquidityRatio()(uint256)') / 10**18, 4)")"

step "S4. Liquidity crunch: the vault's market can pay \$50m today"
VAULT=$(call "$TREAS" "vault()(address)")
send "$VAULT" "setLiquidityCap(uint256)" "$(py "50_000_000 * 10**6")" --private-key "$PK_DEPLOYER"
echo "liquid now: $(usd "$(call "$LENS" 'liquidAssets()(uint256)')" 6) (idle + what the vault pays)"
send "$TOKEN" "transfer(address,uint256)" "$HOLDER" "$(py "60_000_000 * 10**18")" --private-key "$PK_USERS"
p0=$(call "$VAULT" "previewRedeem(uint256)(uint256)" "$(call "$VAULT" "balanceOf(address)(uint256)" "$TREAS")")
send "$STAB" "redeem(uint256,address,uint256)" "$MAXU" "$HOLDER" 0 --private-key "$PK_HOLDER"
p1=$(call "$VAULT" "previewRedeem(uint256)(uint256)" "$(call "$VAULT" "balanceOf(address)(uint256)" "$TREAS")")
echo "a \$60m exit is paid in full: $(usd "$(call "$USDC" 'balanceOf(address)(uint256)' "$HOLDER")" 6)"
CAP1=$(py "50_000_000 * 10**6 - ($p0 - $p1)")
send "$VAULT" "setLiquidityCap(uint256)" "$CAP1" --private-key "$PK_DEPLOYER" # the market's free cash shrank
echo "a \$100m exit now:"
reverts "$STAB" "redeem(uint256,address,uint256)" "$(py "100_000_000 * 10**18")" "$USERS" 0 --private-key "$PK_USERS"
fits=$(call "$LENS" "maxRedeem(address)(uint256)" "$USERS")
echo "lens.maxRedeem says $(usd "$fits" 18) fits; redeeming exactly that:"
send "$STAB" "redeem(uint256,address,uint256)" "$fits" "$USERS" 0 --private-key "$PK_USERS"
p2=$(call "$VAULT" "previewRedeem(uint256)(uint256)" "$(call "$VAULT" "balanceOf(address)(uint256)" "$TREAS")")
send "$VAULT" "setLiquidityCap(uint256)" "$(py "max(0, $CAP1 - ($p1 - $p2))")" --private-key "$PK_DEPLOYER"
echo "liquid left: $(call "$LENS" 'liquidAssets()(uint256)') USDC wei"
send "$TOKEN" "transfer(address,uint256)" "$SETTLE" "$(py "68_493 * 10**18")" --private-key "$PK_USERS"
echo "card settlement while nothing is liquid: maxRedeem = $(call "$LENS" 'maxRedeem(address)(uint256)' "$SETTLE"):"
reverts "$STAB" "redeem(uint256,address,uint256)" "$MAXU" "$SETTLE" 0 --private-key "$PK_SETTLE"
send "$VAULT" "setLiquidityCap(uint256)" "$MAXU" --private-key "$PK_DEPLOYER" # utilisation falls, cash returns
send "$STAB" "redeem(uint256,address,uint256)" "$MAXU" "$SETTLE" 0 --private-key "$PK_SETTLE"
echo "liquidity back: the settlement went through; reserve ratio $(py "$(call "$LENS" 'reserveRatio()(uint256)') / 10**18")"

step "S5. A migration while the vault is illiquid is refused by its loss bound (P5-03)"
send "$VAULT" "setLiquidityCap(uint256)" "$(py "50_000_000 * 10**6")" --private-key "$PK_DEPLOYER"
send "$STAB" "proposeVault(address)" "$PRIMARY" --private-key "$PK_ADMIN"
warp 604801
idx=$(call "$TOKEN" "index()(uint256)")
reverts "$STAB" "executeVaultMigration(uint256)" 10 --private-key "$PK_ADMIN"
echo "index unchanged: $([[ $(call "$TOKEN" 'index()(uint256)') == "$idx" ]] && echo yes || echo NO)"
send "$VAULT" "setLiquidityCap(uint256)" "$MAXU" --private-key "$PK_DEPLOYER"
send "$STAB" "executeVaultMigration(uint256)" 10 --private-key "$PK_ADMIN"
send "$STAB" "rebalanceReserve()" --private-key "$PK_KEEPER"
echo "migrated to $(call "$TREAS" 'vault()(address)') (primary $PRIMARY); index unchanged: $([[ $(call "$TOKEN" 'index()(uint256)') == "$idx" ]] && echo yes || echo NO)"

step "S6. Post-deploy check on the scaled system"
SPECTRUM_CONFIG=deployments/31337-config.json forge script script/PostDeployCheck.s.sol --rpc-url "$RPC" \
  | sed -n '/== Logs ==/,$p' | grep -vE "^\s*$"

step "SCALE REHEARSAL PASSED"

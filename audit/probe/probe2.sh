#!/usr/bin/env bash
set -uo pipefail
D=deployments/84532.json
SUSD=$(jq -r .sUSD $D);        STAB=$(jq -r .stabilizer $D)
TREAS=$(jq -r .treasury $D);   ORACLE=$(jq -r .oracle $D)
HOOK=$(jq -r .hook $D);        LENS=$(jq -r .lens $D)
WSUSD=$(jq -r .wsUSD $D);      USDC=$(jq -r .usdc $D)
VA=$(jq -r .vault $D);         VB=$(jq -r .fallbackVault $D)
DEPLOYER=$(jq -r .deployer $D);ADMIN=$(jq -r .admin $D)
ROUTER=$(jq -r .router deployments/84532-router.json)
PM=$(jq -r .poolManager $D); POOLID=$(jq -r .poolId $D)
START=$(jq -r .blockNumber $D)
q() { echo -n "$1 = "; timeout 40 cast call "$2" "$3" "${@:4}" --rpc-url "$RPC" 2>&1 | tr '\n' ' '; echo; }
scan() { # addr, event, name
  echo "--- $3 ---"
  local b=$((START-10))
  for i in $(seq 0 8); do
    timeout 40 cast logs --from-block $b --to-block $((b+199)) --address "$1" "$2" --rpc-url "$RPC" 2>&1 \
      | grep -vE '^$' | sed "s/^/[$b] /"
    b=$((b+200))
  done
}
echo "### probe2 $(date -u +%FT%TZ)  latest=$(cast block-number --rpc-url $RPC)  deployBlock=$START"
echo
echo "## stabilizer state"
q "paused"          "$STAB" 'paused()(bool)'
q "supplyCap"       "$STAB" 'supplyCap()(uint256)'
q "bootstrapCap"    "$STAB" 'bootstrapCap()(uint256)'
q "protocolCapital" "$STAB" 'protocolCapital()(uint256)'
q "reserveValue"    "$STAB" 'reserveValue()(uint256)'
q "allowedVaults"   "$STAB" 'allowedVaults()(address[])'
q "pendingVault"    "$STAB" 'pendingVault()(address)'
q "pendingVaultEta" "$STAB" 'pendingVaultEta()(uint64)'
q "token"           "$STAB" 'token()(address)'
q "treasuryAddr"    "$STAB" 'treasury()(address)'
q "oracleAddr"      "$STAB" 'oracle()(address)'
q "assetAddr"       "$STAB" 'asset()(address)'
q "minAmount"       "$STAB" 'minAmount()(uint256)'
q "REDEEM_FEE_MIN"  "$STAB" 'REDEEM_FEE_MIN()(uint256)'
q "REDEEM_FEE_MAX"  "$STAB" 'REDEEM_FEE_MAX()(uint256)'
q "MINT_FEE_MIN"    "$STAB" 'MINT_FEE_MIN()(uint256)'
q "MINT_FEE_MAX"    "$STAB" 'MINT_FEE_MAX()(uint256)'
q "REBASE_STEP_MAX" "$STAB" 'REBASE_STEP_MAX()(uint256)'
q "redeemFeeRate(now)" "$STAB" 'redeemFeeRate(uint256)(uint256)' "$(timeout 40 cast call $ORACLE 'smoothedEntropy()(uint256)' --rpc-url $RPC | awk '{print $1}')"
echo
echo "## token"
q "totalSupply"   "$SUSD" 'totalSupply()(uint256)'
q "totalShares"   "$SUSD" 'totalShares()(uint256)'
q "index"         "$SUSD" 'index()(uint256)'
q "tok.stabilizer" "$SUSD" 'stabilizer()(address)'
q "bal(deployer)" "$SUSD" 'balanceOf(address)(uint256)' "$DEPLOYER"
q "bal(admin)"    "$SUSD" 'balanceOf(address)(uint256)' "$ADMIN"
q "bal(router)"   "$SUSD" 'balanceOf(address)(uint256)' "$ROUTER"
q "bal(wsUSD)"    "$SUSD" 'balanceOf(address)(uint256)' "$WSUSD"
echo
echo "## treasury"
q "tre.stabilizer" "$TREAS" 'stabilizer()(address)'
q "vault"          "$TREAS" 'vault()(address)'
q "legacyVault"    "$TREAS" 'legacyVault()(address)'
q "tre.asset"      "$TREAS" 'asset()(address)'
q "reserveAssets"  "$TREAS" 'reserveAssets()(uint256)'
q "idleAssets"     "$TREAS" 'idleAssets()(uint256)'
q "liquidAssets"   "$TREAS" 'liquidAssets()(uint256)'
q "liquidityBufferBps" "$TREAS" 'liquidityBufferBps()(uint256)'
echo
echo "## oracle / hook / lens / wsUSD / router"
q "oracle.hook"      "$ORACLE" 'hook()(address)'
q "smoothedEntropy"  "$ORACLE" 'smoothedEntropy()(uint256)'
q "filled"           "$ORACLE" 'filled()(uint256)'
q "WINDOW"           "$ORACLE" 'WINDOW()(uint256)'
q "minObservation"   "$ORACLE" 'minObservation()(uint256)'
q "staleAfter"       "$ORACLE" 'staleAfter()(uint256)'
q "emaAlphaMax"      "$ORACLE" 'emaAlphaMax()(uint256)'
q "tau"              "$ORACLE" 'tau()(uint256)'
q "hook.oracle"      "$HOOK" 'oracle()(address)'
q "hook.poolManager" "$HOOK" 'poolManager()(address)'
q "hook.allowedPoolId" "$HOOK" 'allowedPoolId()(bytes32)'
q "lens.stabilizer"  "$LENS" 'stabilizer()(address)'
q "lens.reserveRatio" "$LENS" 'reserveRatio()(uint256)'
q "lens.distributable" "$LENS" 'distributable()(uint256)'
q "wsUSD.asset"      "$WSUSD" 'asset()(address)'
q "wsUSD.totalAssets" "$WSUSD" 'totalAssets()(uint256)'
q "wsUSD.totalSupply" "$WSUSD" 'totalSupply()(uint256)'
q "router.stabilizer" "$ROUTER" 'stabilizer()(address)'
q "router.sUSD"      "$ROUTER" 'sUSD()(address)'
q "router.usdc"      "$ROUTER" 'usdc()(address)'
q "router.treasury"  "$ROUTER" 'treasury()(address)'
q "router.scale"     "$ROUTER" 'scale()(uint256)'
q "router USDC bal"  "$USDC" 'balanceOf(address)(uint256)' "$ROUTER"
q "sUSDFor(50000)"   "$ROUTER" 'sUSDFor(uint256)(uint256)' 50000
q "sUSDToAuthorize(50000)" "$ROUTER" 'sUSDToAuthorize(uint256)(uint256)' 50000
echo
echo "## vaults"
for V in "$VA" "$VB"; do
  q "vault $V name"           "$V" 'name()(string)'
  q "vault $V totalAssets"    "$V" 'totalAssets()(uint256)'
  q "vault $V totalSupply"    "$V" 'totalSupply()(uint256)'
  q "vault $V treasuryShares" "$V" 'balanceOf(address)(uint256)' "$TREAS"
done
q "USDC held by treasury directly" "$USDC" 'balanceOf(address)(uint256)' "$TREAS"
q "poolLiquidity" "$PM" 'getLiquidity(bytes32)(uint128)' "$POOLID"
echo
echo "## EVENTS"
scan "$STAB" 'RoleGranted(bytes32,address,address)' "RoleGranted (stabilizer)"
scan "$STAB" 'RoleRevoked(bytes32,address,address)' "RoleRevoked (stabilizer)"
scan "$ROUTER" 'PaidWithSUSD(address,address,bytes32,uint256,uint256,uint256,uint256)' "PaidWithSUSD (router) -- PROOF OF x402 ROUTER PAYMENT"
scan "$STAB" 'Minted(address,address,uint256,uint256,uint256,uint256)' "Minted"
scan "$STAB" 'Redeemed(address,address,uint256,uint256,uint256,uint256)' "Redeemed"
scan "$SUSD" 'AuthorizationUsed(address,bytes32)' "AuthorizationUsed (EIP-3009) -- PROOF OF GASLESS SETTLEMENT"
scan "$SUSD" 'Rebased(uint256,uint256,uint256)' "Rebased"
scan "$STAB" 'CapitalContributed(address,uint256,uint256)' "CapitalContributed"
echo "END-OF-STATE"

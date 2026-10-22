#!/usr/bin/env bash
set -uo pipefail
D=deployments/84532.json
STAB=$(jq -r .stabilizer $D); DEP=$(jq -r .deployer $D); ADM=$(jq -r .admin $D)
TRE=$(jq -r .treasury $D);    VA=$(jq -r .vault $D); USDC=$(jq -r .usdc $D)
SUSD=$(jq -r .sUSD $D); ROUTER=$(jq -r .router deployments/84532-router.json)
AGENT=0x68496c9c52aa9f9d0f278994bcb262c18d8f53c8
MERCH=0x1f31983648e550b57a777c94a5cacd7526d03c3e
echo "## WHO SUBMITTED THE TWO x402 SETTLEMENTS (claim: the facilitator, not the agent)"
for h in 0x41dba7120d788c054a4aeb4a2293109db39d38914fde2716012da6c401ca6242 \
         0xedd58590afd99285c2eee1540b2c5a34737d693704473fbd5c184a6432cf90ca; do
  echo "--- tx $h"
  cast tx "$h" --rpc-url "$RPC" 2>&1 | grep -iE '^(from|to|gas |gasPrice|blockNumber|value)' 
  echo -n "  gasUsed/status: "; cast receipt "$h" --rpc-url "$RPC" 2>&1 | grep -iE '^(gasUsed|status|effectiveGasPrice)' | tr '\n' ' '; echo
done
echo
echo "## AGENT HELD NO ETH (claim: gasless)"
echo "agent ETH   = $(cast balance $AGENT --rpc-url $RPC 2>&1)"
echo "agent nonce = $(cast nonce $AGENT --rpc-url $RPC 2>&1)   (0 => it never sent a transaction)"
echo "agent sUSD  = $(cast call $SUSD 'balanceOf(address)(uint256)' $AGENT --rpc-url $RPC 2>&1)"
echo "agent USDC  = $(cast call $USDC 'balanceOf(address)(uint256)' $AGENT --rpc-url $RPC 2>&1)"
echo "merchant sUSD = $(cast call $SUSD 'balanceOf(address)(uint256)' $MERCH --rpc-url $RPC 2>&1)"
echo "merchant USDC = $(cast call $USDC 'balanceOf(address)(uint256)' $MERCH --rpc-url $RPC 2>&1)"
echo
echo "## DEPLOYER KEY (lives in a GitHub secret): what it still controls"
echo "deployer ETH   = $(cast balance $DEP --rpc-url $RPC 2>&1)"
echo "deployer nonce = $(cast nonce $DEP --rpc-url $RPC 2>&1)"
echo "deployer USDC  = $(cast call $USDC 'balanceOf(address)(uint256)' $DEP --rpc-url $RPC 2>&1)"
echo "deployer sUSD  = $(cast call $SUSD 'balanceOf(address)(uint256)' $DEP --rpc-url $RPC 2>&1)"
echo "admin ETH      = $(cast balance $ADM --rpc-url $RPC 2>&1)"
echo "admin nonce    = $(cast nonce $ADM --rpc-url $RPC 2>&1)"
echo
echo "## ATTACK PROBES (eth_call only)"
p() { echo "-- $1"; shift; cast call "$@" --rpc-url "$RPC" 2>&1 | head -3; }
p "pause() from deployer (want revert)"            "$STAB" 'pause()' --from "$DEP"
p "setSupplyCap(max) from deployer (want revert)"  "$STAB" 'setSupplyCap(uint256)' 115792089237316195423570985008687907853269984665640564039457584007913129639935 --from "$DEP"
p "proposeVault from deployer (want revert)"       "$STAB" 'proposeVault(address)' "$VA" --from "$DEP"
p "setLiquidityBuffer(10000) from deployer"        "$STAB" 'setLiquidityBuffer(uint256)' 10000 --from "$DEP"
p "pause() from ADMIN (want success)"              "$STAB" 'pause()' --from "$ADM"
p "setSupplyCap(0) from ADMIN (want success)"      "$STAB" 'setSupplyCap(uint256)' 0 --from "$ADM"
p "emergencyExitVault() from ADMIN (want success)" "$STAB" 'emergencyExitVault()(uint256)' --from "$ADM"
p "treasury.withdrawReserve from stranger"         "$TRE" 'withdrawReserve(uint256,address)(uint256)' 1 0x00000000000000000000000000000000DeaDBeef --from 0x00000000000000000000000000000000DeaDBeef
p "sUSD.mint from stranger"                        "$SUSD" 'mint(address,uint256)(uint256)' 0x00000000000000000000000000000000DeaDBeef 1000000000000000000 --from 0x00000000000000000000000000000000DeaDBeef
p "sUSD.setIndex from stranger"                    "$SUSD" 'setIndex(uint256)' 2000000000000000000 --from 0x00000000000000000000000000000000DeaDBeef
p "rebase() from stranger (permissionless)"        "$STAB" 'rebase()(bool)' --from 0x00000000000000000000000000000000DeaDBeef
p "sync() from stranger (permissionless)"          "$STAB" 'sync()(bool)' --from 0x00000000000000000000000000000000DeaDBeef
p "rebalanceReserve() from stranger"               "$STAB" 'rebalanceReserve()' --from 0x00000000000000000000000000000000DeaDBeef
p "treasury.recoverLegacy() from stranger"         "$TRE" 'recoverLegacy()(uint256)' --from 0x00000000000000000000000000000000DeaDBeef
p "router.pay with a bogus signature"              "$ROUTER" 'pay(address,uint256,uint256,uint256,address,uint256,bytes32,bytes)(uint256)' "$AGENT" 100000000000000000 0 99999999999 0x00000000000000000000000000000000DeaDBeef 1000 0x0000000000000000000000000000000000000000000000000000000000000001 0x00 --from 0x00000000000000000000000000000000DeaDBeef
echo
echo "## HOW MANY TRANSACTIONS DID THE DEPLOYMENT COST? (claim: fourteen)"
echo "deployer nonce now = $(cast nonce $DEP --rpc-url $RPC 2>&1) (nonce 0 at the start if the key was fresh)"
echo
echo "## POOL"
echo -n "slot0 (extsload) = "; cast call 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 'extsload(bytes32)(bytes32)' "$(cast keccak $(cast abi-encode 'f(bytes32,uint256)' $(jq -r .poolId $D) 6))" --rpc-url "$RPC" 2>&1 | head -2
echo "END-OF-PROBE3"

#!/usr/bin/env bash
set -uo pipefail
D=deployments/84532.json
PM=0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408
POOLID=$(jq -r .poolId $D); DEP=$(jq -r .deployer $D)
BASE=$(cast keccak "$(cast abi-encode 'f(bytes32,uint256)' $POOLID 6)")
echo "pool state slot base = $BASE"
echo "slot0        = $(cast call $PM 'extsload(bytes32)(bytes32)' $BASE --rpc-url $RPC)"
echo "feeGrowth0   = $(cast call $PM 'extsload(bytes32)(bytes32)' $(cast to-uint256 $(( 0 )) >/dev/null; python3 -c "print(hex(int('${BASE#0x}',16)+1))") --rpc-url $RPC)"
LIQSLOT=$(python3 -c "print('0x%064x' % (int('${BASE#0x}',16)+3))")
echo "liquidity slot $LIQSLOT"
echo "POOL LIQUIDITY = $(cast call $PM 'extsload(bytes32)(uint256)' $LIQSLOT --rpc-url $RPC)"
echo
echo "## deployer nonce across the deployment run (claim: fourteen transactions)"
for b in 48884150 48884200 48884250 48884300 48884400 48884500 48884600 48884700; do
  echo "  nonce at block $b = $(cast nonce $DEP --block $b --rpc-url $RPC 2>&1 | head -1)"
done
echo "  nonce now = $(cast nonce $DEP --rpc-url $RPC)"
echo
echo "## admin can it actually act? (it has 0 ETH, nonce 0)"
echo "  admin ETH = $(cast balance $(jq -r .admin $D) --rpc-url $RPC)"
echo
echo "## can an admin drain the reserve anywhere? try the obvious calls from the admin"
STAB=$(jq -r .stabilizer $D); TRE=$(jq -r .treasury $D); ADM=$(jq -r .admin $D)
echo -n "  treasury.withdrawReserve from admin (want NotStabilizer): "
cast call $TRE 'withdrawReserve(uint256,address)(uint256)' 1000000 $ADM --from $ADM --rpc-url $RPC 2>&1 | head -1
echo -n "  treasury.setLiquidityBuffer from admin direct (want NotStabilizer): "
cast call $TRE 'setLiquidityBuffer(uint256)' 10000 --from $ADM --rpc-url $RPC 2>&1 | head -1
echo -n "  treasury.migrateVault from admin direct (want NotStabilizer): "
cast call $TRE 'migrateVault(address)' $(jq -r .fallbackVault $D) --from $ADM --rpc-url $RPC 2>&1 | head -1
echo -n "  stabilizer.executeVaultMigration from admin (want NoPendingVault): "
cast call $STAB 'executeVaultMigration(uint256)' 0 --from $ADM --rpc-url $RPC 2>&1 | head -1
echo "END-OF-PROBE4"

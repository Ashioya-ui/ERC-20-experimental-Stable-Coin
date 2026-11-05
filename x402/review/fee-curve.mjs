import { makeChain, first } from '../lib/cast.mjs';
import { loadDeployment } from '../lib/config.mjs';
import { createAgent, formatUnits } from '../agent.mjs';

const E = process.env;
const chain = makeChain(E.RPC_URL);
const dep = await loadDeployment(chain);
const A = dep.addresses;
const agent = await createAgent({ rpcUrl: E.RPC_URL, facilitatorUrl: E.FACILITATOR_URL,
  signer: { kind: 'keystore', path: `${E.X402_WALLETS}/client`, passwordFile: E.AGENT_PASSWORD_FILE } });

const sizes = [1_000n, 5_000n, 10_000n, 13_000n, 50_000n, 100_000n, 500_000n, 1_000_000n, 10_000_000n];
const rows = [];
for (const assets of sizes) {
  const quoted = await chain.uint(A.router, 'sUSDFor(uint256)(uint256)', [String(assets)]);
  const authorize = await chain.uint(A.router, 'sUSDToAuthorize(uint256)(uint256)', [String(assets)]);
  const netCostUsd6 = quoted / 10n ** 12n;
  const changeUsd6 = netCostUsd6 > assets ? netCostUsd6 - assets : 0n;
  const effective = netCostUsd6 - changeUsd6;
  const feeBps = Number(((netCostUsd6 - assets) * 1_000_000n) / assets) / 100;
  rows.push({
    invoice: '$' + formatUnits(assets, 6),
    sUSDredeemed: formatUnits(quoted, 18).slice(0, 12),
    authorized: formatUnits(authorize, 18).slice(0, 12),
    USDCchange: '$' + formatUnits(changeUsd6, 6),
    grossOverhead_bps: feeBps.toFixed(1),
  });
}
console.table(rows);
console.log('minAmount (smallest redeemable):', formatUnits(await chain.uint(A.stabilizer, 'minAmount()(uint256)'), 18), 'sUSD');
console.log('redeem fee now:', formatUnits(await chain.uint(A.stabilizer, 'redeemFeeRate(uint256)(uint256)', [String(await chain.uint(A.oracle ?? A.stabilizer, 'minAmount()(uint256)'))]) , 18));

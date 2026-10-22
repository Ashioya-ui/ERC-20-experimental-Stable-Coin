// Experiment: does an agent treasury actually come out ahead?
// Yield accrues on the whole balance; the router fee is charged per payment on the payment
// amount. So there is a daily spend rate at which fees cancel the yield. Measure it.
import { makeChain, first } from '../lib/cast.mjs';
import { loadDeployment } from '../lib/config.mjs';
import { createAgent, formatUnits } from '../agent.mjs';

const E = process.env;
const chain = makeChain(E.RPC_URL);
const dep = await loadDeployment(chain);
const A = dep.addresses;
const send = (to, sig, args = []) => chain.send(to, sig, args.map(String), { kind: 'unlocked', address: E.X402_FUNDER });
const rpc = (m, ...p) => import('../lib/cast.mjs').then(({ cast }) => cast(['rpc', '--rpc-url', E.RPC_URL, m, ...p.map(String)]));

const agent = await createAgent({ rpcUrl: E.RPC_URL, facilitatorUrl: E.FACILITATOR_URL,
  signer: { kind: 'keystore', path: `${E.X402_WALLETS}/client`, passwordFile: E.AGENT_PASSWORD_FILE } });

// Fees and yield are only comparable if the yield measured is ONE day's interest and not a
// backlog. Surplus accumulates whenever nobody calls rebase, so drain it first: without this the
// measurement silently reports whatever had piled up and the break-even comes out several times
// too generous.
async function drain(maxHours = 96) {
  let n = 0;
  while (n < maxHours && (await chain.uint(A.lens, 'distributable()(uint256)')) > 0n) {
    await rpc('evm_increaseTime', 3600); await rpc('evm_mine');
    try { await send(A.stabilizer, 'rebase()'); n++; } catch { break; }
  }
  return n;
}

const INVOICE = 50_000n;           // the price /api/v1/premium actually charges
const N = 12;                      // payments in the measured window
const bal = () => chain.uint(A.sUSD, 'balanceOf(address)(uint256)', [agent.address]);
const usdc = () => chain.uint(A.usdc, 'balanceOf(address)(uint256)', [agent.address]);

const drained = await drain();
console.log(`drained ${drained} hourly rebase(s) of accumulated surplus first, so the day below is interest alone\n`);
const t0 = await bal(), u0 = await usdc();
let routed = 0, paidUsdc = 0;
for (let i = 0; i < N; i++) {
  const r = await agent.pay(`${E.MERCHANT_URL}/api/v1/premium`);
  if (!r.paid) throw new Error(`payment ${i}: ${r.error}`);
  r.mode === 'router' ? routed++ : paidUsdc++;
}
const t1 = await bal(), u1 = await usdc();
const spentSUSD = t0 - t1, spentUSDC = u0 > u1 ? u0 - u1 : 0n;
const totalInvoiced = BigInt(N) * INVOICE;

// Now let a day of yield accrue on what remains, hourly, at 5% APY.
const vault = first(await chain.call(A.treasury, 'vault()(address)'));
let credited = 0n, rebases = 0;
for (let h = 0; h < 24; h++) {
  await rpc('evm_increaseTime', 3600); await rpc('evm_mine');
  const assets = await chain.uint(vault, 'totalAssets()(uint256)');
  const interest = (assets * 50_000n) / (8760n * 1_000_000n);
  if (interest > 0n) { await send(A.usdc, 'mint(address,uint256)', [vault, interest]); credited += interest; }
  try { await send(A.stabilizer, 'rebase()'); rebases++; } catch {}
}
const t2 = await bal();
const earned = t2 > t1 ? t2 - t1 : 0n;
const feePaid = spentSUSD / 10n ** 12n > totalInvoiced ? spentSUSD / 10n ** 12n - totalInvoiced : 0n;

console.log(`treasury at start      ${formatUnits(t0, 18)} sUSD`);
console.log(`${N} invoices of $${formatUnits(INVOICE,6)}   routed ${routed}, paid from idle USDC ${paidUsdc}`);
console.log(`  invoiced total       $${formatUnits(totalInvoiced, 6)}`);
console.log(`  sUSD spent           ${formatUnits(spentSUSD, 18)}`);
console.log(`  fee component        $${formatUnits(feePaid, 6)}`);
console.log(`one day of 5% APY      +${formatUnits(earned, 18)} sUSD over ${rebases} rebases`);
console.log(`treasury at end        ${formatUnits(t2, 18)} sUSD`);
console.log('');
const dailyYield = Number(formatUnits(earned, 18));
const perPaymentFee = Number(formatUnits(feePaid, 6)) / Math.max(routed, 1);
console.log(`yield for one day      $${dailyYield.toFixed(6)}`);
console.log(`fee per routed payment $${perPaymentFee.toFixed(6)}`);
console.log(`break-even             ${perPaymentFee > 0 ? Math.floor(dailyYield / perPaymentFee) : 'n/a'} routed payments/day before fees cancel the yield`);
console.log(`  = $${(perPaymentFee > 0 ? (dailyYield / perPaymentFee) * 0.05 : 0).toFixed(4)} of daily payment volume on a $${Number(formatUnits(t0, 18)).toFixed(2)} treasury`);

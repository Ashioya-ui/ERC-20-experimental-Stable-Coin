#!/usr/bin/env node
// Demo of the x402 rail on the local chain, and the helpers of the agent-economy run.
// Needs the environment from `script/rehearsal/x402.sh --serve` (source x402/.tmp/current/env.sh).
//
//   demo.mjs                          the client agent pays all three kinds of x402 bill from
//                                     one sUSD balance, then earns while idle
//   demo.mjs balances                 sUSD and USDC of every wallet of the run
//   demo.mjs list <id> <price> <asset> <wallet> <file> <title...>
//                                     put a deliverable on the marketplace (/work/<id>),
//                                     payable to <wallet> (a wallet name of the run)
//   demo.mjs idle <days> [apy]        let <days> pass: hourly vault interest at <apy> (default
//                                     0.05) and hourly keeper rebases
//   demo.mjs drain                    hourly rebases until no surplus is waiting
//
// Test money on a local chain only.

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { cast, first, makeChain } from './lib/cast.mjs';
import { loadDeployment } from './lib/config.mjs';
import { createAgent, formatUnits } from './agent.mjs';

const env = process.env;
for (const k of ['RPC_URL', 'MERCHANT_URL', 'FACILITATOR_URL', 'X402_WALLETS', 'AGENT_PASSWORD_FILE', 'MARKET_FILE', 'X402_FUNDER']) {
  if (!env[k]) throw new Error(`${k} is not set: source x402/.tmp/current/env.sh first`);
}
const chain = makeChain(env.RPC_URL);
const dep = await loadDeployment(chain);
const A = dep.addresses;
const funder = { kind: 'unlocked', address: env.X402_FUNDER };
const send = (to, sig, args = []) => chain.send(to, sig, args.map(String), funder);
const rpc = (method, ...params) => cast(['rpc', '--rpc-url', env.RPC_URL, method, ...params.map(String)]);
const signer = (name) => ({ kind: 'keystore', path: join(env.X402_WALLETS, name), passwordFile: env.AGENT_PASSWORD_FILE });
const wallets = () =>
  readdirSync(env.X402_WALLETS).filter((f) => f !== 'password' && !f.startsWith('.')).sort();
const addressOf = async (name) => lc(first(await cast(['wallet', 'address', '--keystore', join(env.X402_WALLETS, name), '--password-file', env.AGENT_PASSWORD_FILE])));
const lc = (s) => String(s).toLowerCase();
const usd = (x, d) => formatUnits(x, d);
const fmt = (x, d, places = 6) => {
  const s = formatUnits(x, d);
  const [i, f = ''] = s.split('.');
  return `${i}.${(f + '0'.repeat(places)).slice(0, places)}`;
};

async function balancesOf(address) {
  return {
    sUSD: await chain.uint(A.sUSD, 'balanceOf(address)(uint256)', [address]),
    usdc: await chain.uint(A.usdc, 'balanceOf(address)(uint256)', [address]),
  };
}

async function table() {
  const rows = [];
  for (const name of wallets()) {
    const address = await addressOf(name);
    const b = await balancesOf(address);
    rows.push({ wallet: name, address, sUSD: fmt(b.sUSD, 18), USDC: fmt(b.usdc, 6) });
  }
  console.table(rows);
  return rows;
}

/** Hourly keeper rebases until the surplus already waiting (fees, earlier interest) is paid out. */
async function drain(maxHours = 72) {
  const waiting = await chain.uint(A.lens, 'distributable()(uint256)');
  let rebases = 0;
  while (rebases < maxHours && (await chain.uint(A.lens, 'distributable()(uint256)')) > 0n) {
    await rpc('evm_increaseTime', 3600);
    await rpc('evm_mine');
    try {
      await send(A.stabilizer, 'rebase()');
      rebases++;
    } catch {
      break;
    }
  }
  return { waiting, rebases };
}

/**
 * Let `days` pass the way they would on mainnet: every hour the lending vault earns an hour of
 * interest at `apy` (simulated by crediting it USDC) and a keeper calls the permissionless
 * rebase. Returns what was credited and how far the index rose.
 */
async function idle(days, apy = 0.05) {
  const vault = first(await chain.call(A.treasury, 'vault()(address)'));
  const apyE6 = BigInt(Math.round(apy * 1e6));
  const supply0 = await chain.uint(A.sUSD, 'totalSupply()(uint256)');
  const i0 = await chain.uint(A.sUSD, 'index()(uint256)');
  const vaultAssets = await chain.uint(vault, 'totalAssets()(uint256)');
  const reserve = await chain.uint(A.treasury, 'reserveAssets()(uint256)');
  let credited = 0n;
  let rebases = 0;
  const hours = Math.max(1, Math.round(days * 24));
  for (let h = 0; h < hours; h++) {
    await rpc('evm_increaseTime', 3600);
    await rpc('evm_mine');
    const assets = await chain.uint(vault, 'totalAssets()(uint256)');
    const interest = (assets * apyE6) / (8760n * 1_000_000n); // one hour at `apy`
    if (interest > 0n) {
      await send(A.usdc, 'mint(address,uint256)', [vault, interest]);
      credited += interest;
    }
    try {
      await send(A.stabilizer, 'rebase()');
      rebases++;
    } catch {
      /* nothing to distribute this hour */
    }
  }
  const i1 = await chain.uint(A.sUSD, 'index()(uint256)');
  const growth = Number(((i1 - i0) * 10n ** 12n) / i0) / 1e12;
  return { vault, vaultAssets, reserve, credited, supply0, rebases, hours, i0, i1, growth, apy: (growth * 365 * 24) / hours };
}

async function demo() {
  const client = await createAgent({
    rpcUrl: env.RPC_URL, signer: signer('client'), facilitatorUrl: env.FACILITATOR_URL,
  });
  const merchant = lc(env.MERCHANT);
  const line = (s) => console.log(s);
  const b0 = await client.balances();
  line(`client agent ${client.address}`);
  line(`  holds ${fmt(b0.sUSD, 18)} sUSD and ${fmt(b0.usdc, 6)} USDC; no ETH, no vault position, no USDC float\n`);

  const bills = [
    ['/api/v1/compute', 'priced in sUSD'],
    ['/api/v1/premium', 'priced in USDC, router offered'],
    ['/api/v1/usdc-only', 'priced in plain USDC only'],
  ];
  for (const [path, what] of bills) {
    const before = await client.balances();
    const m0 = await balancesOf(merchant);
    const r = await client.pay(`${env.MERCHANT_URL}${path}`);
    const after = await client.balances();
    const m1 = await balancesOf(merchant);
    if (!r.paid) throw new Error(`${path}: ${r.status} ${r.error}`);
    line(`${path} (${what})`);
    line(`  paid by: ${r.mode}${r.conversion ? ` (conversion tx ${r.conversion.transaction.slice(0, 12)}...)` : ''}   settlement tx ${r.settlement.transaction.slice(0, 12)}...`);
    line(`  merchant received: ${m1.sUSD !== m0.sUSD ? `${fmt(m1.sUSD - m0.sUSD, 18)} sUSD` : `${fmt(m1.usdc - m0.usdc, 6)} USDC`}`);
    line(`  agent spent: ${fmt(before.sUSD - after.sUSD, 18)} sUSD${after.usdc !== before.usdc ? `, USDC change ${fmt(after.usdc - before.usdc, 6)}` : ''}\n`);
  }

  const d = await drain();
  if (d.waiting > 0n) {
    line(`a keeper first pays out the ${fmt(d.waiting, 18)} sUSD of fees already waiting (${d.rebases} hourly rebases),`);
    line(`so the day below measures interest alone`);
  }
  const s0 = (await client.balances()).sUSD;
  const y = await idle(1);
  const s1 = (await client.balances()).sUSD;
  line(`idle for 1 day: the lending vault holds ${fmt(y.vaultAssets, 6)} of the ${fmt(y.reserve, 6)} USDC reserve and earns 5% APY,`);
  line(`  credited hourly (${fmt(y.credited, 6)} USDC); a keeper rebased ${y.rebases} of ${y.hours} hours; index ${y.i0} -> ${y.i1}`);
  line(`  client sUSD ${fmt(s0, 18)} -> ${fmt(s1, 18)}  (+${fmt(s1 - s0, 18)}: ${(y.apy * 100).toFixed(2)}% a year at this rate)`);
  line(`  the same balance keeps paying bills: no claim, no unstake, no top-up\n`);
  const r = await client.pay(`${env.MERCHANT_URL}/api/v1/premium`);
  line(`after idling, /api/v1/premium again: ${r.paid ? `paid by ${r.mode}` : `FAILED ${r.error}`}`);
  if (!r.paid) process.exitCode = 1;
}

const [cmd, ...args] = process.argv.slice(2);
if (!cmd) await demo();
else if (cmd === 'balances') await table();
else if (cmd === 'idle') {
  const y = await idle(Number(args[0] || 1), Number(args[1] || 0.05));
  console.log(JSON.stringify({
    ...y, credited: usd(y.credited, 6), vaultAssets: usd(y.vaultAssets, 6), reserve: usd(y.reserve, 6),
    supply0: usd(y.supply0, 18), i0: String(y.i0), i1: String(y.i1),
  }, null, 2));
} else if (cmd === 'drain') {
  const d = await drain();
  console.log(JSON.stringify({ waiting: usd(d.waiting, 18), rebases: d.rebases }));
} else if (cmd === 'list') {
  const [id, price, asset, walletName, file, ...title] = args;
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(id || '') || !/^\d+$/.test(price || '') || !['sUSD', 'USDC'].includes(asset)) {
    throw new Error('usage: demo.mjs list <id> <price in token units> <sUSD|USDC> <wallet> <file> <title...>');
  }
  const payTo = await addressOf(walletName);
  const m = JSON.parse(readFileSync(env.MARKET_FILE, 'utf8'));
  m.items = m.items.filter((i) => i.id !== id);
  m.items.push({ id, title: title.join(' ') || id, price, asset, payTo, file });
  writeFileSync(env.MARKET_FILE, JSON.stringify(m, null, 2));
  console.log(`listed ${env.MERCHANT_URL}/work/${id}: ${asset === 'USDC' ? usd(BigInt(price), 6) : usd(BigInt(price), 18)} ${asset} to ${walletName} (${payTo})`);
} else {
  console.error('usage: demo.mjs [balances | drain | idle <days> [apy] | list <id> <price> <asset> <wallet> <file> <title...>]');
  process.exitCode = 64;
}

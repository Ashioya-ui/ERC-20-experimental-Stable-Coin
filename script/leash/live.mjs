#!/usr/bin/env node
// Both leashes on Base Sepolia, driven by real transactions; every result is read back from the
// chain and compared with the rule (script/leash/rule.py makes the same decisions in integers).
//   node script/leash/live.mjs             deploy and run (needs RPC access to Base Sepolia)
//   node script/leash/live.mjs --offline   keys, addresses, signer and calldata only, no network
// Env: RPC_URL (default https://sepolia.base.org); DEPLOYER_KEYSTORE and DEPLOYER_PASSWORD_FILE
// (default audit/wallets/core and core.pw); LEASH_USDC, test USDC per leash (default 1).
// The agent key is made once in ~/.leash/agent.key; the deployer gives it test ETH for gas.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { scryptSync, createDecipheriv } from 'node:crypto';
import {
  keccak256, signDigest, recoverAddress, addressOfKey, newKey, calldata, encodeTypes, decodeTypes,
  parseSignature, makeJsChain,
} from '../../x402/lib/evm.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const OFFLINE = process.argv.includes('--offline');
const RPC = process.env.RPC_URL || 'https://sepolia.base.org';
const CHAIN_ID = 84532n;
const EXPLORER = 'https://base-sepolia.blockscout.com';
const art = JSON.parse(readFileSync(join(ROOT, 'script/leash/artifacts.json'), 'utf8'));
const dep = JSON.parse(readFileSync(join(ROOT, 'deployments/84532.json'), 'utf8'));
const USDC = dep.usdc;
const [VA, VB] = dep.allowedVaults;
const AMOUNT = BigInt(Math.round(Number(process.env.LEASH_USDC || '1') * 1e6));
const LEASH_ARGS = ['address', 'address', 'address', 'address', 'address', 'string', 'string'];

// The same steps and expected answers as script/leash/rule.py.
const GENERIC = { end: [6000, 3000], steps: [
  ['check', 7000, 3001, 'BadAllocation'],
  ['move', 3000, 1500, 'ok'],
  ['move', 4500, 1500, 'ok'],
  ['check', 2000, 1000, 'NotApproaching'],
  ['check', 7000, 3000, 'EndUnreachable'],
  ['move', 6000, 3000, 'ok'],
  ['check', 5000, 3000, 'NotApproaching'],
] };
const RESERVE = { end: [5000, 5000], steps: [
  ['move', 2500, 2500, 'ok'],
  ['check', 1000, 4000, 'NotApproaching'],
  ['move', 5000, 5000, 'ok'],
] };

const buf = (h) => Buffer.from(String(h).replace(/^0x/, ''), 'hex');
const hx = (b) => `0x${Buffer.from(b).toString('hex')}`;
const minimal = (n) => {
  const b = buf(BigInt(n).toString(16).padStart(64, '0'));
  let i = 0;
  while (i < b.length && b[i] === 0) i++;
  return b.subarray(i);
};
function rlp(x) {
  const head = (len, off) => {
    if (len < 56) return Buffer.from([off + len]);
    const l = minimal(len);
    return Buffer.concat([Buffer.from([off + 55 + l.length]), l]);
  };
  if (Array.isArray(x)) {
    const body = Buffer.concat(x.map(rlp));
    return Buffer.concat([head(body.length, 0xc0), body]);
  }
  const b = Buffer.from(x);
  return b.length === 1 && b[0] < 0x80 ? b : Buffer.concat([head(b.length, 0x80), b]);
}
const createAddress = (from, nonce) => hx(keccak256(rlp([buf(from), minimal(nonce)])).subarray(12));
const usd = (n) => (Number(n) / 1e6).toFixed(6);
const eth = (n) => (Number(n) / 1e18).toFixed(6);
const ERRORS = ['BadAllocation', 'PathFull', 'SamePoint', 'NotApproaching', 'EndUnreachable', 'NotAgent', 'NotPlanner',
  'NotOwner', 'BadMargin', 'NonTransferable', 'WrongVault', 'ZeroAddress'];
const SELECTOR = Object.fromEntries(ERRORS.map((e) => [hx(keccak256(Buffer.from(`${e}()`))).slice(0, 10), e]));

function keystoreKey(file, pwFile) {
  const c = JSON.parse(readFileSync(file, 'utf8')).crypto;
  const p = c.kdfparams;
  const ct = buf(c.ciphertext);
  const raw = readFileSync(pwFile, 'utf8');
  for (const pw of [raw, raw.replace(/\r?\n$/, '')]) {
    const dk = scryptSync(Buffer.from(pw, 'utf8'), buf(p.salt), p.dklen, { N: p.n, r: p.r, p: p.p, maxmem: 2 ** 28 });
    if (hx(keccak256(Buffer.concat([dk.subarray(16, 32), ct]))) !== `0x${c.mac.replace(/^0x/, '')}`) continue;
    const d = createDecipheriv('aes-128-ctr', dk.subarray(0, 16), buf(c.cipherparams.iv));
    return hx(Buffer.concat([d.update(ct), d.final()]));
  }
  throw new Error(`${file}: the password in ${pwFile} does not open it`);
}

function agentKey() {
  const f = join(homedir(), '.leash', 'agent.key');
  if (!existsSync(f)) {
    mkdirSync(dirname(f), { recursive: true, mode: 0o700 });
    writeFileSync(f, `${newKey()}\n`, { mode: 0o600 });
  }
  return readFileSync(f, 'utf8').trim();
}

const deployData = (name, types, args) => art[name].bytecode + Buffer.from(encodeTypes(types, args)).toString('hex');

function signTx(key, { nonce, tip, maxFee, gas, to, value, data }) {
  const fields = [minimal(CHAIN_ID), minimal(nonce), minimal(tip), minimal(maxFee), minimal(gas),
    to ? buf(to) : Buffer.alloc(0), minimal(value), buf(data), []];
  const digest = keccak256(Buffer.concat([Buffer.from([2]), rlp(fields)]));
  const sig = buf(signDigest(digest, key));
  const raw = Buffer.concat([Buffer.from([2]), rlp([...fields, minimal(sig[64] - 27),
    minimal(BigInt(hx(sig.subarray(0, 32)))), minimal(BigInt(hx(sig.subarray(32, 64))))])]);
  return { raw: hx(raw), digest, sig: hx(sig) };
}

const chain = makeJsChain(RPC);
const rpc = (m, p) => chain.rpc(m, p);
const log = [];
const nonces = new Map();

async function read(to, sig, args = []) {
  const { outputs } = parseSignature(sig);
  return decodeTypes(outputs, buf(await rpc('eth_call', [{ to, data: calldata(sig, args) }, 'latest'])));
}

async function refusal(to, sig, args, from) {
  try {
    await rpc('eth_call', [{ from, to, data: calldata(sig, args) }, 'latest']);
    return 'ok';
  } catch (e) {
    const d = String(typeof e.data === 'object' && e.data ? e.data.data ?? '' : e.data ?? '');
    return SELECTOR[d.slice(0, 10)] ?? `reverted ${d.slice(0, 10) || e.message}`;
  }
}

async function send(key, to, data, value, label) {
  const from = addressOfKey(key);
  if (!nonces.has(from)) nonces.set(from, BigInt(await rpc('eth_getTransactionCount', [from, 'pending'])));
  const nonce = nonces.get(from);
  const gas = (BigInt(await rpc('eth_estimateGas', [{ from, ...(to ? { to } : {}), data, value: `0x${value.toString(16)}` }])) * 125n) / 100n;
  const block = await rpc('eth_getBlockByNumber', ['latest', false]);
  let tip;
  try {
    tip = BigInt(await rpc('eth_maxPriorityFeePerGas', []));
  } catch {
    tip = 1_000_000n;
  }
  const { raw } = signTx(key, { nonce, tip, maxFee: 2n * BigInt(block.baseFeePerGas) + tip, gas, to, value, data });
  const hash = await rpc('eth_sendRawTransaction', [raw]);
  nonces.set(from, nonce + 1n);
  for (let i = 0; i < 80; i++) {
    const r = await rpc('eth_getTransactionReceipt', [hash]);
    if (r) {
      if (r.status !== '0x1') throw new Error(`${label}: ${EXPLORER}/tx/${hash} reverted`);
      log.push({ step: label, tx: hash, link: `${EXPLORER}/tx/${hash}`, gasUsed: Number(BigInt(r.gasUsed)) });
      console.log(`  ${label}: ${EXPLORER}/tx/${hash}`);
      return r;
    }
    await new Promise((s) => setTimeout(s, 1500));
  }
  throw new Error(`${label}: ${hash} was not mined in 120 s`);
}

const near = (x, y, tol) => (x > y ? x - y : y - x) <= tol;

async function allocation(L) {
  const [a, b] = await read(L, 'allocation()(uint16,uint16)');
  return [a, b];
}

async function drive(L, key, plan) {
  const G = addressOfKey(key);
  for (const [kind, a, b, want] of plan.steps) {
    const got = await refusal(L, 'check(uint16,uint16)', [a, b], G);
    if (got !== want) throw new Error(`check(${a}, ${b}) on ${L}: the chain says ${got}, the rule says ${want}`);
    if (kind === 'check') {
      console.log(`  refused (${a}, ${b}): ${got}`);
      log.push({ step: `agent asks for (${a}, ${b})`, refused: got });
      continue;
    }
    await send(key, L, calldata('move(uint16,uint16)', [a, b]), 0n, `agent moves to (${a}, ${b})`);
    const [x, y] = await allocation(L);
    if (!near(x, BigInt(a), 1n) || !near(y, BigInt(b), 1n)) throw new Error(`allocation (${x}, ${y}) after moving to (${a}, ${b})`);
  }
  const [xs, ys] = await read(L, 'path()(uint16[],uint16[])');
  const [up, down, ok] = await read(L, 'bound()(uint256,uint256,bool)');
  const [moved] = await read(L, 'moved()(uint256)');
  const pts = xs.map((x, i) => `(${x}, ${ys[i]})`).join(' -> ');
  console.log(`  path ${pts}; length <= ${up} bps, diameter >= ${down} bps, within 3.1297x: ${ok}; agent moved $${usd(moved)}`);
  if (!ok) throw new Error('bound() is false');
  log.push({ step: 'plan read back', path: pts, lengthUp: Number(up), diameterDown: Number(down), boundOk: ok, movedUsdc: usd(moved) });
}

async function main() {
  const deployerKey = keystoreKey(
    process.env.DEPLOYER_KEYSTORE || join(ROOT, 'audit/wallets/core'),
    process.env.DEPLOYER_PASSWORD_FILE || join(ROOT, 'audit/wallets/core.pw'),
  );
  const D = addressOfKey(deployerKey);
  const agent = agentKey();
  const G = addressOfKey(agent);
  console.log(`deployer ${D}\nagent    ${G}\nvaults   ${VA} and ${VB} (ERC-4626 over ${USDC})`);

  if (OFFLINE) {
    const probe = signTx(deployerKey, { nonce: 7n, tip: 1n, maxFee: 2n, gas: 21_000n, to: G, value: 1n, data: '0x' });
    const signer = recoverAddress(probe.digest, probe.sig);
    console.log(`signer recovers to the deployer: ${signer.toLowerCase() === D.toLowerCase()}`);
    console.log(`approve selector ${calldata('approve(address,uint256)', [G, 1n]).slice(0, 10)} (want 0x095ea7b3)`);
    console.log(`CREATE(deployer, 0) = ${createAddress(D, 0n)}`);
    console.log(`Leash initcode ${(deployData('Leash', LEASH_ARGS, [USDC, VA, VB, D, D, 'Leash USDC', 'lUSDC']).length - 2) / 2} bytes, runtime ${art.Leash.runtimeSize}`);
    console.log(`errors ${JSON.stringify(SELECTOR)}`);
    return;
  }

  const id = BigInt(await rpc('eth_chainId', []));
  if (id !== CHAIN_ID) throw new Error(`chain ${id}: this run is for Base Sepolia (84532)`);
  const ethD = BigInt(await rpc('eth_getBalance', [D, 'latest']));
  const [usdcD] = await read(USDC, 'balanceOf(address)(uint256)', [D]);
  console.log(`deployer holds ${eth(ethD)} test ETH and ${usd(usdcD)} test USDC`);
  if (usdcD < 2n * AMOUNT) throw new Error(`needs ${usd(2n * AMOUNT)} test USDC at ${D} (faucet.circle.com, Base Sepolia)`);
  if (ethD < 500_000_000_000_000n) throw new Error(`needs 0.0005 test ETH at ${D}`);
  if (BigInt(await rpc('eth_getBalance', [G, 'latest'])) < 100_000_000_000_000n) {
    await send(deployerKey, G, '0x', 200_000_000_000_000n, 'deployer gives the agent 0.0002 test ETH for gas');
  }

  console.log('\n1. Any two ERC-4626 vaults. Owner and planner: the deployer.');
  const L1 = (await send(deployerKey, null, deployData('Leash', LEASH_ARGS, [USDC, VA, VB, D, D, 'Leash USDC', 'lUSDC']), 0n, 'deploy Leash')).contractAddress;
  await send(deployerKey, USDC, calldata('approve(address,uint256)', [L1, AMOUNT]), 0n, 'owner approves USDC');
  await send(deployerKey, L1, calldata('deposit(uint256,address)', [AMOUNT, D]), 0n, `owner deposits ${usd(AMOUNT)} USDC`);
  const stranger = await refusal(L1, 'move(uint16,uint16)', [3000, 1500], D);
  if (stranger !== 'NotAgent') throw new Error(`a move from the owner's key: ${stranger}`);
  console.log('  refused a move from a key that is not the agent: NotAgent');
  await send(deployerKey, L1, calldata('declare(uint16,uint16,address,uint32,uint32)', [...GENERIC.end, G, 1, 10]), 0n, 'planner declares end (6000, 3000), margin 1/10');
  await drive(L1, agent, GENERIC);
  const before = await allocation(L1);
  await send(deployerKey, L1, calldata('withdraw(uint256,address,address)', [AMOUNT / 4n, D, D]), 0n, `owner withdraws ${usd(AMOUNT / 4n)} USDC`);
  const after = await allocation(L1);
  if (!near(after[0], before[0], 2n) || !near(after[1], before[1], 2n)) throw new Error(`a withdrawal moved the allocation: (${before}) -> (${after})`);
  console.log(`  allocation after the withdrawal: (${after[0]}, ${after[1]}), unchanged`);
  await send(deployerKey, L1, calldata('stop()', []), 0n, 'planner stops: both vaults redeemed, agent removed');
  const [sharesLeft] = await read(L1, 'balanceOf(address)(uint256)', [D]);
  await send(deployerKey, L1, calldata('redeem(uint256,address,address)', [sharesLeft, D, D]), 0n, 'owner redeems everything');
  const [left] = await read(L1, 'totalAssets()(uint256)');
  console.log(`  left in the leash: ${usd(left)} USDC`);

  console.log("\n2. sUSD's reserve. AutonomousTreasury holds the leash as its vault; the deployer holds the stabilizer role.");
  const nonce = nonces.get(D) ?? BigInt(await rpc('eth_getTransactionCount', [D, 'pending']));
  const T = createAddress(D, nonce + 1n);
  const L2 = (await send(deployerKey, null, deployData('Leash', LEASH_ARGS, [USDC, VA, VB, T, D, 'Leashed sUSD reserve', 'lRES']), 0n, 'deploy reserve Leash (owner = treasury)')).contractAddress;
  const T2 = (await send(deployerKey, null, deployData('AutonomousTreasury', ['address', 'uint256', 'address'], [L2, 1500n, D]), 0n, 'deploy AutonomousTreasury (vault = leash, buffer 15%)')).contractAddress;
  if (T2.toLowerCase() !== T.toLowerCase()) throw new Error(`treasury at ${T2}, predicted ${T}`);
  await send(deployerKey, USDC, calldata('transfer(address,uint256)', [T, AMOUNT]), 0n, `fund the treasury with ${usd(AMOUNT)} USDC`);
  await send(deployerKey, T, calldata('depositReserve()', []), 0n, 'stabilizer: depositReserve (85% into the leash)');
  await send(deployerKey, L2, calldata('declare(uint16,uint16,address,uint32,uint32)', [...RESERVE.end, G, 1, 10]), 0n, 'planner declares end (5000, 5000), margin 1/10');
  await drive(L2, agent, RESERVE);
  const r0 = await allocation(L2);
  await send(deployerKey, T, calldata('withdrawReserve(uint256,address)', [AMOUNT / 2n, D]), 0n, `stabilizer: withdrawReserve ${usd(AMOUNT / 2n)} USDC`);
  const r1 = await allocation(L2);
  if (!near(r1[0], r0[0], 2n) || !near(r1[1], r0[1], 2n)) throw new Error(`a reserve withdrawal moved the allocation: (${r0}) -> (${r1})`);
  console.log(`  leash allocation after the reserve withdrawal: (${r1[0]}, ${r1[1]}), unchanged`);
  await send(deployerKey, T, calldata('exitVault()', []), 0n, 'stabilizer: exitVault');
  const [rest] = await read(T, 'reserveAssets()(uint256)');
  await send(deployerKey, T, calldata('withdrawReserve(uint256,address)', [rest, D]), 0n, `stabilizer: withdraw the remaining ${usd(rest)} USDC`);

  const [usdcEnd] = await read(USDC, 'balanceOf(address)(uint256)', [D]);
  console.log(`\ndeployer USDC: ${usd(usdcD)} before, ${usd(usdcEnd)} after`);
  const report = { chainId: 84532, at: new Date().toISOString(), deployer: D, agent: G, usdc: USDC, vaults: [VA, VB],
    leash: L1, reserveLeash: L2, reserveTreasury: T, usdcBefore: usd(usdcD), usdcAfter: usd(usdcEnd), steps: log };
  writeFileSync(join(ROOT, 'deployments/84532-leash.json'), `${JSON.stringify(report, null, 2)}\n`);
  console.log('wrote deployments/84532-leash.json');
}

main().catch((e) => {
  console.error(`stopped: ${e.message}`);
  if (log.length) writeFileSync(join(ROOT, 'deployments/84532-leash.partial.json'), `${JSON.stringify(log, null, 2)}\n`);
  process.exit(1);
});

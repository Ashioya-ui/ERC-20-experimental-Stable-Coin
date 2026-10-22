// Test world for the x402 rail: a running chain with Spectrum and the pay router deployed
// (script/rehearsal/x402.sh sets one up), an in-process facilitator and merchant on ephemeral
// ports, and agents with fresh encrypted keystores funded from anvil's unlocked account.

import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { cast, first, makeChain, newKeystore, parseJsonOutput, signTypedData } from '../lib/cast.mjs';
import { loadDeployment } from '../lib/config.mjs';
import { X402_VERSION, HEADER, encode, decode, authorizationTypedData } from '../lib/protocol.mjs';
import { createFacilitator } from '../facilitator.mjs';
import { createMerchant } from '../merchant.mjs';
import { createAgent } from '../agent.mjs';

export const RPC = process.env.RPC_URL || 'http://127.0.0.1:8545';
// anvil accounts 0 (deployer, USDC minter) and 4; unlocked on anvil only
const FUNDER = (process.env.X402_FUNDER || '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266').toLowerCase();
const FACILITATOR = (process.env.X402_FACILITATOR_ACCOUNT || '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65').toLowerCase();
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

export const ATTACKER = '0x000000000000000000000000000000000000a77a';

/** true, or why the suite cannot run. */
export async function available() {
  try {
    const dep = await loadDeployment(makeChain(RPC));
    return dep.addresses.router ? true : 'the pay router is not deployed';
  } catch (e) {
    return e.message.split('\n')[0];
  }
}

const listen = (server) =>
  new Promise((res) => server.listen(0, '127.0.0.1', () => res(`http://127.0.0.1:${server.address().port}`)));

export const absDiff = (a, b) => (a > b ? a - b : b - a);
export const reasonOf = (res) => decode(res.headers.get(HEADER.required)).error;
export const submit = (url, paymentPayload) => fetch(url, { headers: { [HEADER.signature]: encode(paymentPayload) } });

export async function setup() {
  const chain = makeChain(RPC);
  const dep = await loadDeployment(chain);
  const A = dep.addresses;
  const dir = mkdtempSync(join(tmpdir(), 'x402-test-'));
  const passwordFile = join(dir, 'password');
  writeFileSync(passwordFile, randomBytes(24).toString('base64'), { mode: 0o600 });
  const funder = { kind: 'unlocked', address: FUNDER };

  const facilitator = await createFacilitator({ rpcUrl: RPC, signer: { kind: 'unlocked', address: FACILITATOR } });
  const facilitatorUrl = await listen(facilitator.server);
  const merchantKey = await newKeystore(dir, 'merchant', passwordFile);
  const marketFile = join(dir, 'market.json');
  writeFileSync(marketFile, JSON.stringify({ items: [] }));
  const resultFile = join(dir, 'result.md');
  writeFileSync(resultFile, '# A paid result\n\nDelivered after settlement.\n');
  const merchant = await createMerchant({ rpcUrl: RPC, facilitatorUrl, payTo: merchantKey.address, marketFile, testRoutes: true });
  const merchantUrl = await listen(merchant.server);

  const send = (to, sig, args = []) => chain.send(to, sig, args.map(String), funder);
  const rpc = (method, ...params) => cast(['rpc', '--rpc-url', RPC, method, ...params.map(String)]);

  async function fundUSDC(to, amount) {
    await send(A.usdc, 'mint(address,uint256)', [to, amount]);
  }
  /** Deposit `assets` USDC (6 decimals) and mint the sUSD to `to`. */
  async function fundSUSD(to, assets) {
    await fundUSDC(FUNDER, assets);
    await send(A.usdc, 'approve(address,uint256)', [A.stabilizer, assets]);
    const r = await send(A.stabilizer, 'mint(uint256,address,uint256)', [assets, to, 0]);
    if (!r.ok) throw new Error('sUSD mint failed');
  }
  const bal = {
    sUSD: (a) => chain.uint(A.sUSD, 'balanceOf(address)(uint256)', [a]),
    usdc: (a) => chain.uint(A.usdc, 'balanceOf(address)(uint256)', [a]),
    eth: async (a) => BigInt(await cast(['balance', '--rpc-url', RPC, a])),
  };

  let n = 0;
  const keystore = (name) => newKeystore(dir, name, passwordFile);
  async function agent({ sUSD = 0n, usdc = 0n, policy, payer, signer, facilitator: withFacilitator = true } = {}) {
    const key = signer || (await keystore(`agent${++n}`));
    const holder = payer || key.address;
    if (sUSD) await fundSUSD(holder, sUSD);
    if (usdc) await fundUSDC(holder, usdc);
    const a = await createAgent({
      rpcUrl: RPC, signer: key, payer, policy, tmpDir: dir, facilitatorUrl: withFacilitator ? facilitatorUrl : undefined,
    });
    a.key = key;
    return a;
  }

  /** Sign an EIP-3009 authorization with explicit fields (to build invalid or odd payments). */
  async function signAuthorization(signer, { token, primaryType = 'TransferWithAuthorization', message }) {
    const domain = token === A.sUSD ? dep.domains.sUSD : dep.domains.usdc;
    const typed = authorizationTypedData({ primaryType, ...domain, chainId: dep.chainId, verifyingContract: token, message });
    return signTypedData(typed, signer, dir);
  }

  /** The 402 of `url` and a signed payment for it, not yet sent. */
  async function signedFor(a, url, prefer) {
    const required = decode((await fetch(url)).headers.get(HEADER.required));
    const o = await a.choose(required.accepts, prefer);
    const payload = await a.authorize(o);
    return { required, o, paymentPayload: { x402Version: X402_VERSION, resource: required.resource, accepted: o.r, payload } };
  }

  async function post(path, body) {
    const r = await fetch(`${facilitatorUrl}${path}`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
    });
    return r.json();
  }

  async function warp(seconds) {
    await rpc('evm_increaseTime', seconds);
    await rpc('evm_mine');
  }
  const now = () => chain.timestamp();
  const index = () => chain.uint(A.sUSD, 'index()(uint256)');

  /** Deploy MockERC1271Wallet(owner) from the forge build output. */
  async function deploy1271(owner) {
    const artifact = join(ROOT, 'out', 'MockERC1271Wallet.sol', 'MockERC1271Wallet.json');
    if (!existsSync(artifact)) throw new Error('build output missing: run forge build');
    const code = JSON.parse(readFileSync(artifact, 'utf8')).bytecode.object;
    const args = (await cast(['abi-encode', 'constructor(address)', owner])).slice(2);
    const out = parseJsonOutput(await cast(['send', '--rpc-url', RPC, '--unlocked', '--from', FUNDER, '--json', '--create', code + args]));
    return out.contractAddress.toLowerCase();
  }

  /** A second facilitator (on `chainOverride`, e.g. a wrapped chain) and a merchant that uses it. */
  const extra = [];
  async function stack(chainOverride) {
    const f = await createFacilitator({ rpcUrl: RPC, signer: { kind: 'unlocked', address: FACILITATOR }, chain: chainOverride });
    const fUrl = await listen(f.server);
    const m = await createMerchant({ rpcUrl: RPC, facilitatorUrl: fUrl, payTo: merchantKey.address, marketFile, testRoutes: true });
    const mUrl = await listen(m.server);
    extra.push(f.server, m.server);
    return { facilitatorUrl: fUrl, merchantUrl: mUrl };
  }

  function addMarketItem(item) {
    const m = JSON.parse(readFileSync(marketFile, 'utf8'));
    m.items.push(item);
    writeFileSync(marketFile, JSON.stringify(m));
  }

  async function close() {
    for (const server of [facilitator.server, merchant.server, ...extra]) await new Promise((r) => server.close(r));
  }

  return {
    chain, dep, A, dir, passwordFile, facilitator, facilitatorUrl, merchant, merchantUrl,
    merchantAddress: merchantKey.address, marketFile, resultFile, funder, send, rpc, fundUSDC, fundSUSD, bal, agent, keystore,
    signAuthorization, signedFor, post, warp, now, index, deploy1271, addMarketItem, stack, close, first,
  };
}

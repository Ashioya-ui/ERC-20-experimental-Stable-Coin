// End to end: an agent pays an x402 merchant out of an Aave position, through VaultPayRouter, on
// an anvil fork of Base mainnet -- Circle's real USDC, Aave's real waBasUSDC, the router deployed
// onto the fork. This is the Base mainnet rail exactly, minus the real chain.
//
// Run by script/rehearsal/x402-vault-fork.sh, which starts the fork and deploys the router. Kept
// out of the *.test.mjs glob, and skipped anywhere that is not such a fork.
//
// Env: RPC_URL (the fork), VAULT_FORK=1.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { cast, first, makeChain, newKeystore } from '../lib/cast.mjs';
import { loadDeployment } from '../lib/config.mjs';
import { HEADER, encode, decode } from '../lib/protocol.mjs';
import { createFacilitator } from '../facilitator.mjs';
import { createMerchant } from '../merchant.mjs';
import { createAgent } from '../agent.mjs';

const RPC = process.env.RPC_URL || 'http://127.0.0.1:8545';
// anvil's default accounts 0 and 4: unlocked on anvil only, never used anywhere else
const FUNDER = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';
const FACILITATOR = '0x15d34aaf54267db7d7c367839aaf71a00a2c6a65';

const chain = makeChain(RPC);
let skip = false;
let dep, A, world;

const listen = (server) =>
  new Promise((res) => server.listen(0, '127.0.0.1', () => res(`http://127.0.0.1:${server.address().port}`)));
const bal = (token, who) => chain.uint(token, 'balanceOf(address)(uint256)', [who]);
const rpc = (method, ...params) => cast(['rpc', '--rpc-url', RPC, method, ...params.map(String)]);
const send = (to, sig, args) => chain.send(to, sig, args.map(String), { kind: 'unlocked', address: FUNDER });

/** Give `who` `amount` USDC by writing its balance slot, found by probing rather than assumed. */
async function dealUSDC(who, amount) {
  const probe = '0x' + randomBytes(20).toString('hex');
  for (let slot = 0; slot < 32; slot++) {
    const key = await cast(['index', 'address', probe, String(slot)]);
    await rpc('anvil_setStorageAt', A.usdc, key, await cast(['to-uint256', '4242']));
    const seen = await bal(A.usdc, probe);
    await rpc('anvil_setStorageAt', A.usdc, key, await cast(['to-uint256', '0']));
    if (seen === 4242n) {
      const target = await cast(['index', 'address', who, String(slot)]);
      await rpc('anvil_setStorageAt', A.usdc, target, await cast(['to-uint256', String(amount)]));
      assert.equal(await bal(A.usdc, who), BigInt(amount), 'USDC balance written');
      return;
    }
  }
  throw new Error('USDC balance slot not found');
}

before(async () => {
  try {
    if (process.env.VAULT_FORK !== '1') throw new Error('VAULT_FORK is not set');
    dep = await loadDeployment(chain);
    A = dep.addresses;
    if (dep.chainId !== 8453) throw new Error(`chain ${dep.chainId} is not a Base mainnet fork`);
    if (!A.vaultRouter || !A.vaults.length) throw new Error('VaultPayRouter is not deployed on this fork');
  } catch (e) {
    skip = e.message;
    return;
  }
  const dir = mkdtempSync(join(tmpdir(), 'x402-vault-'));
  const passwordFile = join(dir, 'password');
  writeFileSync(passwordFile, randomBytes(24).toString('base64'), { mode: 0o600 });
  const vault = A.vaults[0];

  const facilitator = await createFacilitator({ rpcUrl: RPC, signer: { kind: 'unlocked', address: FACILITATOR } });
  const facilitatorUrl = await listen(facilitator.server);
  const merchantAddress = (await newKeystore(dir, 'merchant', passwordFile)).address;
  const merchant = await createMerchant({ rpcUrl: RPC, facilitatorUrl, payTo: merchantAddress });
  const merchantUrl = await listen(merchant.server);

  // The agent: a fresh key, no ETH ever, and a treasury of 25 USDC parked in Aave. The deposit is
  // made for it by someone else, as an agent's owner would fund it.
  const agentKey = await newKeystore(dir, 'agent', passwordFile);
  await dealUSDC(FUNDER, 25_000_000n);
  await send(A.usdc, 'approve(address,uint256)', [vault, 25_000_000n]);
  await send(vault, 'deposit(uint256,address)', [25_000_000n, agentKey.address]);
  const agent = await createAgent({ rpcUrl: RPC, signer: agentKey, facilitatorUrl, tmpDir: dir });

  world = { facilitator, facilitatorUrl, merchant, merchantUrl, merchantAddress, agent, vault, dir };
});

after(async () => {
  if (!world) return;
  for (const s of [world.facilitator.server, world.merchant.server]) await new Promise((r) => s.close(r));
});

test('the facilitator offers the vault router, and only for the vault it trusts', async (t) => {
  if (skip) return t.skip(skip);
  const res = await fetch(`${world.facilitatorUrl}/supported`);
  const body = await res.json();
  const kind = body.kinds.find((k) => k.extra?.vaultRouter);
  assert.ok(kind, 'vault router advertised');
  assert.equal(kind.extra.vaultRouter, A.vaultRouter);
  assert.deepEqual(kind.extra.vaults, A.vaults);
  assert.ok(!body.kinds.some((k) => k.extra?.spectrumRouter), 'no sUSD router where Spectrum is not deployed');
  assert.ok(body.extensions.includes('spectrum-vault-router'));
});

test('an agent with no ETH pays an x402 invoice from its Aave position', async (t) => {
  if (skip) return t.skip(skip);
  const { agent, merchantUrl, merchantAddress, vault } = world;
  const sharesBefore = await bal(vault, agent.address);
  const merchantBefore = await bal(A.usdc, merchantAddress);
  assert.equal(await chain.uint(A.usdc, 'balanceOf(address)(uint256)', [agent.address]), 0n, 'agent holds no USDC');
  assert.equal(BigInt(first(await cast(['balance', '--rpc-url', RPC, agent.address]))), 0n, 'agent holds no ETH');

  const r = await agent.pay(`${merchantUrl}/api/v1/premium`);

  assert.equal(r.status, 200, r.error);
  assert.equal(r.paid, true);
  assert.equal(r.mode, 'vault');
  assert.ok(r.paymentPayload.payload.vaultPay.permit, 'first payment carries a permit');
  assert.equal((await bal(A.usdc, merchantAddress)) - merchantBefore, 50_000n, 'merchant received exactly the price');
  assert.ok((await bal(vault, agent.address)) < sharesBefore, 'paid from the position');
  assert.equal(await bal(vault, A.vaultRouter), 0n, 'router keeps no shares');
  assert.equal(await bal(A.usdc, A.vaultRouter), 0n, 'router keeps no USDC');
  assert.equal(await bal(A.usdc, agent.address), 0n, 'no stray USDC left with the agent');
  const receipt = await chain.receipt(r.settlement.transaction);
  assert.ok(['0x1', '1', 'true'].includes(String(receipt.status)), 'settled on chain');
});

test('a second payment works too, signing a fresh permit at the next nonce', async (t) => {
  if (skip) return t.skip(skip);
  const { agent, merchantUrl, merchantAddress } = world;
  const before = await bal(A.usdc, merchantAddress);
  // usdc-only advertises no router, and the agent holds no USDC: no way to pay it, and it says so
  // before signing anything.
  await assert.rejects(agent.pay(`${merchantUrl}/api/v1/usdc-only`), /insufficient funds/);
  const r = await agent.pay(`${merchantUrl}/api/v1/premium`);
  assert.equal(r.paid, true, r.error);
  assert.equal(r.mode, 'vault');
  assert.equal((await bal(A.usdc, merchantAddress)) - before, 50_000n);
});

test('a replayed payment is refused before it reaches the chain', async (t) => {
  if (skip) return t.skip(skip);
  const { agent, merchantUrl, merchantAddress } = world;
  const r = await agent.pay(`${merchantUrl}/api/v1/premium`);
  assert.equal(r.paid, true, r.error);
  const before = await bal(A.usdc, merchantAddress);
  const again = await fetch(`${merchantUrl}/api/v1/premium`, { headers: { [HEADER.signature]: encode(r.paymentPayload) } });
  assert.equal(again.status, 402);
  assert.equal(decode(again.headers.get(HEADER.required)).error, 'invalid_exact_evm_payload_authorization_nonce_used');
  assert.equal(await bal(A.usdc, merchantAddress), before, 'paid once');
});

test('a tampered intent is refused: checked fields locally, signed fields by simulation', async (t) => {
  if (skip) return t.skip(skip);
  const { agent, merchantUrl, merchantAddress } = world;
  const first402 = await fetch(`${merchantUrl}/api/v1/premium`);
  const required = decode(first402.headers.get(HEADER.required));
  const option = await agent.choose(required.accepts);
  assert.equal(option.mode, 'vault');
  const payload = await agent.authorize(option);
  const wrap = (p) => encode({ x402Version: 2, resource: required.resource, accepted: option.r, payload: p });
  const before = await bal(A.usdc, merchantAddress);

  // A different recipient: refused by the facilitator's own check against the requirement.
  const redirected = structuredClone(payload);
  redirected.vaultPay.intent.payTo = '0x000000000000000000000000000000000000a77a';
  let res = await fetch(`${merchantUrl}/api/v1/premium`, { headers: { [HEADER.signature]: wrap(redirected) } });
  assert.equal(res.status, 402);
  assert.equal(decode(res.headers.get(HEADER.required)).error, 'invalid_exact_evm_payload_recipient_mismatch');

  // A larger share ceiling: every local check passes, the router's signature check does not.
  const loosened = structuredClone(payload);
  loosened.vaultPay.intent.maxShares = String(BigInt(loosened.vaultPay.intent.maxShares) * 2n);
  res = await fetch(`${merchantUrl}/api/v1/premium`, { headers: { [HEADER.signature]: wrap(loosened) } });
  assert.equal(res.status, 402);
  assert.equal(decode(res.headers.get(HEADER.required)).error, 'invalid_exact_evm_payload_signature');

  assert.equal(await bal(A.usdc, merchantAddress), before, 'nothing moved');
});

test("an owner sweeps the agent's whole position home, through the facilitator's checks", async (t) => {
  if (skip) return t.skip(skip);
  const { agent, vault } = world;
  const home = '0x' + randomBytes(20).toString('hex');
  const position = await chain.uint(vault, 'maxWithdraw(address)(uint256)', [agent.address]);
  assert.ok(position > 0n, 'something to sweep');

  const out = await agent.sweep(home);

  assert.equal(out.length, 1);
  assert.equal(await bal(A.usdc, home), position, 'the whole position arrived as USDC');
  assert.ok((await chain.uint(vault, 'maxWithdraw(address)(uint256)', [agent.address])) <= 1n, 'dust only');
  assert.equal(await bal(vault, A.vaultRouter), 0n, 'router keeps no shares');
  assert.equal(await bal(A.usdc, A.vaultRouter), 0n, 'router keeps no USDC');
  assert.deepEqual(await agent.sweep(home), [], 'nothing left to sweep');
});

// End to end: x402 sessions. An agent that never holds ETH makes SESSION_CALLS paid calls (default
// 1,000) to a merchant at 0.0001 USDC each. The chain sees one open, submitted by the facilitator,
// and one redemption; the payee then closes the session and the rest of the deposit goes home.
//
// Run by script/rehearsal/x402-session.sh, on a fresh anvil with Circle's FiatToken v2.2 bytecode or
// on a fork of Base mainnet with Circle's live USDC. Skipped anywhere else.
//
// Env: RPC_URL, SESSION_E2E=1, SESSION_CALLS.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { cast, first, makeChain, newKeystore, signTypedData } from '../lib/cast.mjs';
import { loadDeployment } from '../lib/config.mjs';
import { HEADER, encode, decode, voucherTypedData, pathStepTypedData, lc } from '../lib/protocol.mjs';
import { readPath, readSession } from '../lib/session.mjs';
import { createFacilitator } from '../facilitator.mjs';
import { createMerchant } from '../merchant.mjs';
import { createAgent } from '../agent.mjs';

const RPC = process.env.RPC_URL || 'http://127.0.0.1:8545';
const CALLS = Number(process.env.SESSION_CALLS || 1000);
const PRICE = 100n; // 0.0001 USDC
const DEPOSIT = 200_000n; // 0.20 USDC
// anvil's default account 4: unlocked on anvil only, never used anywhere else
const FACILITATOR = '0x15d34aaf54267db7d7c367839aaf71a00a2c6a65';

const chain = makeChain(RPC);
let skip = false;
let A, world;

const listen = (server) =>
  new Promise((res) => server.listen(0, '127.0.0.1', () => res(`http://127.0.0.1:${server.address().port}`)));
const bal = (who) => chain.uint(A.usdc, 'balanceOf(address)(uint256)', [who]);
const eth = async (who) => BigInt(first(await cast(['balance', '--rpc-url', RPC, who])));
const rpc = (method, ...params) => cast(['rpc', '--rpc-url', RPC, method, ...params.map(String)]);
const reasonOf = (res) => decode(res.headers.get(HEADER.required)).error;

/** Give `who` `amount` USDC by writing its balance slot, found by probing rather than assumed. */
async function dealUSDC(who, amount) {
  const probe = '0x' + randomBytes(20).toString('hex');
  for (let slot = 0; slot < 32; slot++) {
    const key = await cast(['index', 'address', probe, String(slot)]);
    await rpc('anvil_setStorageAt', A.usdc, key, await cast(['to-uint256', '4242']));
    const seen = await bal(probe);
    await rpc('anvil_setStorageAt', A.usdc, key, await cast(['to-uint256', '0']));
    if (seen === 4242n) {
      await rpc('anvil_setStorageAt', A.usdc, await cast(['index', 'address', who, String(slot)]), await cast(['to-uint256', String(amount)]));
      assert.equal(await bal(who), BigInt(amount), 'USDC balance written');
      return;
    }
  }
  throw new Error('USDC balance slot not found');
}

before(async () => {
  try {
    if (process.env.SESSION_E2E !== '1') throw new Error('SESSION_E2E is not set');
    A = (await loadDeployment(chain)).addresses;
    if (!A.sessionEscrow) throw new Error('X402SessionEscrow is not deployed on this chain');
  } catch (e) {
    skip = e.message;
    return;
  }
  const dir = mkdtempSync(join(tmpdir(), 'x402-session-'));
  const passwordFile = join(dir, 'password');
  writeFileSync(passwordFile, randomBytes(24).toString('base64'), { mode: 0o600 });
  const sessionsFile = join(dir, 'sessions.json');

  const facilitator = await createFacilitator({
    rpcUrl: RPC, signer: { kind: 'unlocked', address: FACILITATOR }, sessionsFile, redeemEveryMs: 0, admin: true,
  });
  const facilitatorUrl = await listen(facilitator.server);
  const merchantKey = await newKeystore(dir, 'merchant', passwordFile);
  const merchant = await createMerchant({
    rpcUrl: RPC, facilitatorUrl, payTo: merchantKey.address, tickPrice: String(PRICE), sessionDeposit: String(DEPOSIT),
  });
  const merchantUrl = await listen(merchant.server);

  // The agent: a fresh key, 1 USDC, no ETH, ever.
  const agentKey = await newKeystore(dir, 'agent', passwordFile);
  await dealUSDC(agentKey.address, 1_000_000n);
  const agent = await createAgent({
    rpcUrl: RPC, signer: agentKey, facilitatorUrl, tmpDir: dir, ledgerFile: join(dir, 'ledger.json'),
    policy: { maxSessionDeposit: DEPOSIT },
  });
  world = { dir, sessionsFile, facilitator, facilitatorUrl, merchant, merchantUrl, merchantKey, agentKey, agent };
});

after(async () => {
  if (!world) return;
  for (const s of [world.facilitator.server, world.merchant.server]) await new Promise((r) => s.close(r));
});

test('the facilitator offers sessions on its own escrow', async (t) => {
  if (skip) return t.skip(skip);
  const body = await (await fetch(`${world.facilitatorUrl}/supported`)).json();
  const kind = body.kinds.find((k) => k.scheme === 'session');
  assert.ok(kind, 'session scheme advertised');
  assert.equal(kind.extra.escrow, A.sessionEscrow);
  assert.equal(kind.extra.asset, A.usdc);
  assert.ok(body.extensions.includes('spectrum-session'));
});

test(`${CALLS} paid calls cost one open and one redemption, and the agent never holds ETH`, async (t) => {
  if (skip) return t.skip(skip);
  const { agent, facilitator, merchantUrl, merchantKey } = world;
  const payee = merchantKey.address;
  const nonce0 = await chain.nonce(FACILITATOR);
  const escrow0 = await bal(A.sessionEscrow);
  assert.equal(await eth(agent.address), 0n, 'agent holds no ETH');

  const started = Date.now();
  let opened = null;
  for (let i = 1; i <= CALLS; i++) {
    const r = await agent.pay(`${merchantUrl}/api/v1/tick`);
    assert.equal(r.status, 200, `call ${i}: ${r.error}`);
    assert.equal(r.paid, true);
    assert.equal(r.mode, 'session');
    assert.equal(JSON.parse(r.body).tick, i);
    if (i === 1) {
      assert.match(r.settlement.transaction, /^0x[0-9a-f]{64}$/, 'the first call opens the session on-chain');
      assert.ok(r.paymentPayload.payload.session.open, 'and carries the open');
      opened = r;
    } else {
      assert.equal(r.settlement.transaction, '', `call ${i} touched the chain`);
      assert.equal(r.paymentPayload.payload.session.open, undefined, `call ${i} still carries the open`);
    }
  }
  const seconds = (Date.now() - started) / 1000;
  t.diagnostic(`${CALLS} calls in ${seconds.toFixed(1)} s (${((seconds * 1000) / CALLS).toFixed(1)} ms a call)`);

  const id = opened.session.id;
  assert.equal(await chain.nonce(FACILITATOR) - nonce0, 1n, 'one transaction so far: the open');
  assert.equal(await bal(payee), 0n, 'nothing redeemed yet');
  assert.equal(await bal(A.sessionEscrow) - escrow0, DEPOSIT, 'the escrow holds the deposit');
  assert.equal(await bal(agent.address), 1_000_000n - DEPOSIT);
  const s0 = await readSession(chain, A.sessionEscrow, id);
  assert.equal(s0.funder, agent.address);
  assert.equal(s0.payee, payee);
  assert.equal(s0.signer, agent.owner);
  assert.equal(s0.deposited, DEPOSIT);
  assert.equal(s0.claimed, 0n);

  // Restarted from its file, a facilitator still holds every voucher it accepted.
  const restarted = await createFacilitator({
    rpcUrl: RPC, signer: { kind: 'unlocked', address: FACILITATOR }, sessionsFile: world.sessionsFile, redeemEveryMs: 0,
  });
  assert.equal(restarted.sessions().find((x) => x.id === id).accepted, String(PRICE * BigInt(CALLS)));

  const out = await facilitator.redeemDue({ force: true });
  assert.equal(out.transactions.length, 1, 'one redemption');
  assert.equal(out.transactions[0].ok, true);
  assert.equal(await chain.nonce(FACILITATOR) - nonce0, 2n, 'two transactions in all: open and redemption');
  assert.equal(await bal(payee), PRICE * BigInt(CALLS), 'the merchant has every call');
  assert.equal((await readSession(chain, A.sessionEscrow, id)).claimed, PRICE * BigInt(CALLS));
  assert.deepEqual((await facilitator.redeemDue({ force: true })).transactions, [], 'nothing left to redeem');
  assert.equal(await eth(agent.address), 0n, 'the agent still holds no ETH');
  world.sessionId = id;
});

test('an old voucher is refused, and so is one above the deposit or signed by another key', async (t) => {
  if (skip) return t.skip(skip);
  const { agent, merchantUrl, merchantKey, agentKey, dir, sessionId } = world;
  const r = await agent.pay(`${merchantUrl}/api/v1/tick`);
  assert.equal(r.paid, true, r.error);
  const payee = merchantKey.address;
  const before = await bal(payee);

  // the very same payment again
  let res = await fetch(`${merchantUrl}/api/v1/tick`, { headers: { [HEADER.signature]: encode(r.paymentPayload) } });
  assert.equal(res.status, 402);
  assert.equal(reasonOf(res), 'session_voucher_stale');

  const sign = (cumulative, key = agentKey) =>
    signTypedData(voucherTypedData({ chainId: agent.deployment.chainId, escrow: A.sessionEscrow, sessionId, cumulative }), key, dir);
  const forged = async (cumulative, key) => {
    const p = structuredClone(r.paymentPayload);
    p.payload.session.cumulative = String(cumulative);
    p.payload.session.voucher = await sign(cumulative, key);
    return fetch(`${merchantUrl}/api/v1/tick`, { headers: { [HEADER.signature]: encode(p) } });
  };
  res = await forged(DEPOSIT + 1n);
  assert.equal(res.status, 402);
  assert.equal(reasonOf(res), 'session_above_deposit');

  const stranger = await newKeystore(dir, 'stranger', join(dir, 'password'));
  res = await forged(BigInt(r.session.cumulative) + PRICE, stranger);
  assert.equal(res.status, 402);
  assert.equal(reasonOf(res), 'invalid_session_voucher');

  // A voucher for less than one more call.
  res = await forged(BigInt(r.session.cumulative) + PRICE - 1n);
  assert.equal(res.status, 402);
  assert.equal(reasonOf(res), 'session_voucher_stale');
  assert.equal(await bal(payee), before, 'nothing moved');
});

test('the payee closes the session: its last calls are paid and the rest of the deposit goes home', async (t) => {
  if (skip) return t.skip(skip);
  const { agent, facilitator, merchantKey, sessionId } = world;
  const s = await readSession(chain, A.sessionEscrow, sessionId);
  const owed = BigInt(agent.sessions()[Object.keys(agent.sessions())[0]].cumulative);
  assert.ok(owed > s.claimed, 'a call is still unredeemed');
  const accepted = facilitator.sessions().find((x) => x.id === sessionId);
  await rpc('anvil_setBalance', merchantKey.address, '0xde0b6b3a7640000'); // gas for the payee's own close
  const agentBefore = await bal(agent.address);
  const escrowBefore = await bal(A.sessionEscrow);

  const listed = (await (await fetch(`${world.facilitatorUrl}/sessions`)).json()).find((x) => x.id === sessionId);
  assert.equal(listed.accepted, accepted.accepted);
  // The payee settles the last voucher the facilitator accepted and releases the rest in one call.
  const saved = JSON.parse(readFileSync(world.sessionsFile, 'utf8')).sessions[sessionId];
  const sent = await chain.send(A.sessionEscrow, 'closeByPayee(bytes32,uint256,bytes)', [sessionId, saved.accepted, saved.voucher], merchantKey);
  assert.ok(sent.ok, 'closed');

  const after = await readSession(chain, A.sessionEscrow, sessionId);
  assert.equal(after.closed, true);
  assert.equal(after.claimed, BigInt(saved.accepted));
  assert.equal(await bal(merchantKey.address), BigInt(saved.accepted), 'the payee has everything it accepted');
  assert.equal(await bal(agent.address) - agentBefore, DEPOSIT - BigInt(saved.accepted), 'the rest of the deposit went home');
  assert.equal(escrowBefore - await bal(A.sessionEscrow), DEPOSIT - s.claimed, 'the escrow keeps nothing of it');
  assert.equal(await eth(agent.address), 0n, 'and the agent never needed ETH');
});

test('after the close, the agent retires the session and pays from a new one', async (t) => {
  if (skip) return t.skip(skip);
  const { agent, merchantUrl, sessionId } = world;
  const r = await agent.pay(`${merchantUrl}/api/v1/tick`);
  assert.equal(r.paid, true, r.error);
  assert.notEqual(r.session.id, sessionId, 'a new session');
  assert.match(r.settlement.transaction, /^0x[0-9a-f]{64}$/, 'opened on-chain');
  assert.equal(agent.ledger().retired.at(-1).sessionId, sessionId);
  assert.equal(agent.ledger().retired.at(-1).retiredBecause, 'session_closed');
});

test("the owner takes the agent's free USDC home, gaslessly", async (t) => {
  if (skip) return t.skip(skip);
  const { agent } = world;
  const home = '0x' + randomBytes(20).toString('hex');
  const cash = await bal(agent.address);
  assert.ok(cash > 0n, 'the refund and the untouched balance are there');
  const out = await agent.sweep(home);
  assert.equal(out.length, 1);
  assert.equal(await bal(home), cash, 'all of it arrived');
  assert.equal(await bal(agent.address), 0n);
  assert.equal(await eth(agent.address), 0n, 'without the agent ever holding ETH');
  assert.deepEqual(await agent.sweep(home), [], 'nothing left');
});

// The self-approaching condition, end to end. The owner (home) declares a path for a fresh agent:
// one named merchant, a cap of 0.05 USDC. The agent holds nothing and opens its session as a signed
// step on the path. Then the agent's own key turns attacker, the way a compromised machine would:
// a step off the path, a step past the end, and a replay of a step already taken. All three are
// refused by the path itself, and the rest of the money goes home.
test("a path: the agent holds nothing, and its key can only walk the owner's path", async (t) => {
  if (skip) return t.skip(skip);
  if (!A.sessionPaths) return t.skip('X402SessionPaths is not deployed on this chain');
  const { dir, facilitator, facilitatorUrl, merchantUrl, merchantKey } = world;
  const HOME = '0x70997970c51812dc3a010c7d01b50e0d17dc79c8'; // anvil's default account 1: unlocked on anvil only
  const home = { kind: 'unlocked', address: HOME };
  const merchant = merchantKey.address;
  const agentKey = await newKeystore(dir, 'path-agent', join(dir, 'password'));
  await dealUSDC(HOME, 1_000_000n);
  const homeBefore = await bal(HOME);
  const expiry = String((await chain.timestamp()) + 86_400n);
  const salt = '0x' + randomBytes(32).toString('hex');
  const payees = `[${merchant}]`;
  const caps = '[50000]';
  assert.ok((await chain.send(A.usdc, 'approve(address,uint256)', [A.sessionPaths, '50000'], home)).ok);
  const declared = await chain.send(
    A.sessionPaths, 'declare(address,address,uint64,bytes32,address[],uint256[],uint256)',
    [agentKey.address, A.usdc, expiry, salt, payees, caps, '50000'], home,
  );
  assert.ok(declared.ok, 'declared');
  const ends = first(await chain.call(A.sessionPaths, 'endsOf(address[],uint256[])(bytes32)', [payees, caps]));
  const pathId = lc(first(await chain.call(
    A.sessionPaths, 'pathIdOf(address,address,address,uint64,bytes32,bytes32)(bytes32)',
    [HOME, agentKey.address, A.usdc, expiry, ends, salt],
  )));
  assert.equal((await readPath(chain, A.sessionPaths, pathId)).free, 50_000n);

  const agent = await createAgent({
    rpcUrl: RPC, signer: agentKey, facilitatorUrl, tmpDir: dir, ledgerFile: join(dir, 'path-ledger.json'), path: pathId,
  });
  let firstStep = null;
  for (let i = 1; i <= 20; i++) {
    const r = await agent.pay(`${merchantUrl}/api/v1/tick`);
    assert.equal(r.paid, true, `call ${i}: ${r.error}`);
    if (i === 1) {
      firstStep = r.paymentPayload.payload.session.pathStep;
      assert.ok(firstStep, 'the first call opens the session as a step on the path');
      assert.match(r.settlement.transaction, /^0x[0-9a-f]{64}$/);
    }
  }
  assert.equal(await bal(agentKey.address), 0n, 'the agent never holds the money');
  assert.equal(await eth(agentKey.address), 0n, 'nor any ETH');
  const sessionId = Object.values(agent.sessions())[0].sessionId;
  const opened = await readSession(chain, A.sessionEscrow, sessionId);
  assert.equal(opened.funder, A.sessionPaths, 'the path funded the session');
  assert.equal(opened.deposited, 50_000n, 'the whole cap: everything the owner allowed this merchant');

  // The agent's key turns attacker. Each step is simulated exactly as a facilitator would submit it.
  const STEP = 'stepWithSig(bytes32,address,address,uint64,bytes32,uint256,uint256,uint256,bytes)';
  const now = await chain.timestamp();
  const sign = (step) => signTypedData(pathStepTypedData({ chainId: agent.deployment.chainId, paths: A.sessionPaths, step }), agentKey, dir);
  const refusedWith = async (step, signature, error) => {
    const sel = lc(await cast(['sig', error]));
    const args = [pathId, step.payee, step.signer, step.expiry, step.salt, step.amount, step.committed, step.deadline, signature];
    await assert.rejects(
      chain.call(A.sessionPaths, STEP, args, { from: FACILITATOR }),
      (e) => `${e.message}\n${e.stderr}`.toLowerCase().includes(sel.slice(2)),
      `expected ${error}`,
    );
  };
  const base = {
    pathId, signer: agentKey.address, expiry: String(now + 7_200n), amount: '1', deadline: String(now + 60n),
  };
  const off = { ...base, payee: '0x' + randomBytes(20).toString('hex'), committed: '0', salt: '0x' + randomBytes(32).toString('hex') };
  await refusedWith(off, await sign(off), 'NotOnPath(address)');
  const past = { ...base, payee: merchant, committed: '50000', salt: '0x' + randomBytes(32).toString('hex') };
  await refusedWith(past, await sign(past), 'BeyondEnd(address,uint256,uint256)');
  const replay = { ...firstStep, payee: merchant };
  await refusedWith(replay, firstStep.signature, 'StaleStep(uint256,uint256)');

  // Settle: one redemption pays the twenty calls; the payee closes; the refund returns to the path,
  // and from the path only home can take it.
  await facilitator.redeemDue({ force: true });
  assert.equal((await readSession(chain, A.sessionEscrow, sessionId)).claimed, 20n * PRICE);
  assert.ok((await chain.send(A.sessionEscrow, 'closeByPayee(bytes32,uint256,bytes)', [sessionId, '0', '0x'], merchantKey)).ok);
  assert.ok((await chain.send(A.sessionPaths, 'collect(bytes32)', [sessionId], home)).ok);
  assert.ok((await chain.send(A.sessionPaths, 'goHome(bytes32)', [pathId], home)).ok);
  assert.equal(await bal(HOME), homeBefore - 20n * PRICE, 'home got back everything the merchant did not earn');
  assert.equal((await readPath(chain, A.sessionPaths, pathId)).free, 0n);
  assert.ok((await readPath(chain, A.sessionPaths, pathId)).ended);
  assert.equal(await bal(agentKey.address), 0n);
});

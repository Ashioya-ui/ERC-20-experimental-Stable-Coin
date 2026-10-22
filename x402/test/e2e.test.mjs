// End-to-end tests of the x402 rail against a live chain: merchant -> facilitator -> chain,
// with agents that hold sUSD, USDC, or an ERC-1271 smart account.
//
//   script/rehearsal/x402.sh            sets up the chain and runs this suite
//   RPC_URL=... npm test                against a chain that is already set up (from x402/)

import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { HEADER, decode } from '../lib/protocol.mjs';
import { PolicyError } from '../agent.mjs';
import { makeChain } from '../lib/cast.mjs';
import { available, setup, absDiff, reasonOf, submit, ATTACKER, RPC } from './helpers.mjs';

const ready = await available();
const skip = ready === true ? false : `no Spectrum deployment with the pay router at ${RPC} (${ready}); run script/rehearsal/x402.sh`;

const COMPUTE = 5_000_000_000_000_000n; // 0.005 sUSD
const PREMIUM = 50_000n; // 0.05 USDC
const USDC_ONLY = 20_000n; // 0.02 USDC
const rand32 = () => '0x' + randomBytes(32).toString('hex');

describe('x402 rail', { skip }, () => {
  let w;
  let url;
  before(async () => {
    w = await setup();
    url = (path) => `${w.merchantUrl}${path}`;
  });
  after(async () => w?.close());

  // ------------------------------------------------------------------ the protocol surface

  test('a protected route answers 402 with a decodable PAYMENT-REQUIRED', async () => {
    const res = await fetch(url('/api/v1/compute'));
    assert.equal(res.status, 402);
    const required = decode(res.headers.get(HEADER.required));
    assert.equal(required.x402Version, 2);
    assert.equal(required.resource.url, url('/api/v1/compute'));
    const [a] = required.accepts;
    assert.deepEqual(
      { scheme: a.scheme, network: a.network, asset: a.asset, payTo: a.payTo, amount: a.amount, name: a.extra.name, version: a.extra.version },
      { scheme: 'exact', network: w.dep.network, asset: w.A.sUSD, payTo: w.merchantAddress, amount: String(COMPUTE), name: 'Spectrum Agentic USD', version: '1' },
    );
    const premium = decode((await fetch(url('/api/v1/premium'))).headers.get(HEADER.required)).accepts[0];
    assert.equal(premium.asset, w.A.usdc);
    assert.equal(premium.extra.spectrumRouter, w.A.router);
    assert.equal(premium.extra.payWith, w.A.sUSD);
    const plain = decode((await fetch(url('/api/v1/usdc-only'))).headers.get(HEADER.required)).accepts[0];
    assert.equal(plain.extra.spectrumRouter, undefined);
  });

  test('/supported lists sUSD, USDC and the router kind', async () => {
    const s = await (await fetch(`${w.facilitatorUrl}/supported`)).json();
    const assets = s.kinds.map((k) => `${k.extra.asset}:${k.extra.spectrumRouter || ''}`);
    assert.deepEqual(assets, [`${w.A.sUSD}:`, `${w.A.usdc}:`, `${w.A.usdc}:${w.A.router}`]);
    assert.deepEqual(s.extensions, ['spectrum-router', 'spectrum-convert']);
    assert.ok(s.kinds.every((k) => k.x402Version === 2 && k.scheme === 'exact' && k.network === w.dep.network));
  });

  test('a garbage PAYMENT-SIGNATURE gets a 402, not a crash', async () => {
    const res = await fetch(url('/api/v1/compute'), { headers: { [HEADER.signature]: 'not base64 json' } });
    assert.equal(res.status, 402);
    assert.equal(reasonOf(res), 'invalid PAYMENT-SIGNATURE header');
  });

  // ------------------------------------------------------------------ the four ways to pay

  test('sUSD direct: exact amount to the merchant, gasless for the agent', async () => {
    const a = await w.agent({ sUSD: 10_000_000n });
    const m0 = await w.bal.sUSD(w.merchantAddress);
    const a0 = await w.bal.sUSD(a.address);
    const r = await a.pay(url('/api/v1/compute'));
    assert.equal(r.status, 200);
    assert.equal(r.paid, true);
    assert.equal(r.mode, 'sUSD');
    assert.equal(JSON.parse(r.body).result, 42);
    assert.match(r.settlement.transaction, /^0x[0-9a-f]{64}$/);
    assert.equal(r.settlement.payer, a.address);
    assert.ok(absDiff((await w.bal.sUSD(w.merchantAddress)) - m0, COMPUTE) <= 2n, 'merchant got the price');
    assert.ok(absDiff(a0 - (await w.bal.sUSD(a.address)), COMPUTE) <= 2n, 'agent paid the price');
    assert.equal(await w.bal.eth(a.address), 0n, 'the agent never needed gas');
  });

  test('router: an agent holding only sUSD pays a USDC price; the merchant gets exact USDC', async () => {
    const a = await w.agent({ sUSD: 10_000_000n });
    assert.equal(await w.bal.usdc(a.address), 0n);
    const m0 = await w.bal.usdc(w.merchantAddress);
    const s0 = await w.bal.sUSD(a.address);
    const quoted = await w.chain.uint(w.A.router, 'sUSDFor(uint256)(uint256)', [String(PREMIUM)]);
    const r = await a.pay(url('/api/v1/premium'));
    assert.equal(r.paid, true, r.error);
    assert.equal(r.mode, 'router');
    assert.equal((await w.bal.usdc(w.merchantAddress)) - m0, PREMIUM, 'exactly the USDC price');
    const spent = s0 - (await w.bal.sUSD(a.address));
    assert.ok(absDiff(spent, quoted) <= 2n, `spent ${spent}, router quoted ${quoted}`);
    const authorized = BigInt(r.paymentPayload.payload.authorization.value);
    assert.ok(authorized >= spent, 'the authorization was an upper bound; the change came back');
    assert.equal(await w.bal.sUSD(w.A.router), 0n, 'router keeps no sUSD');
    assert.equal(await w.bal.usdc(w.A.router), 0n, 'router keeps no USDC');
  });

  test('USDC: standard x402 USDC passes through unchanged', async () => {
    const a = await w.agent({ usdc: 1_000_000n });
    const m0 = await w.bal.usdc(w.merchantAddress);
    const r = await a.pay(url('/api/v1/usdc-only'));
    assert.equal(r.paid, true, r.error);
    assert.equal(r.mode, 'USDC');
    assert.equal((await w.bal.usdc(w.merchantAddress)) - m0, USDC_ONLY);
    assert.equal(await w.bal.usdc(a.address), 1_000_000n - USDC_ONLY);
  });

  test('convert: a USDC-only merchant is paid from sUSD by converting just enough first', async () => {
    const a = await w.agent({ sUSD: 5_000_000n });
    const m0 = await w.bal.usdc(w.merchantAddress);
    const r = await a.pay(url('/api/v1/usdc-only'));
    assert.equal(r.paid, true, r.error);
    assert.equal(r.mode, 'convert');
    assert.match(r.conversion.transaction, /^0x[0-9a-f]{64}$/);
    assert.equal((await w.bal.usdc(w.merchantAddress)) - m0, USDC_ONLY);
    assert.ok((await w.bal.usdc(a.address)) < USDC_ONLY, 'only rounding dust of USDC is left over');
  });

  test('/convert alone: sUSD to exact USDC for the agent itself', async () => {
    const a = await w.agent({ sUSD: 5_000_000n });
    await a.convert(1_000_000n);
    const usdc = await w.bal.usdc(a.address);
    assert.ok(usdc >= 1_000_000n && usdc < 1_000_100n, `got ${usdc}`);
  });

  test('marketplace micro-payment: $0.001 through the router redeems the 0.01 sUSD minimum and refunds the rest in USDC', async () => {
    w.addMarketItem({ id: 'micro', title: 'A tiny result', price: '1000', asset: 'USDC', payTo: w.merchantAddress, file: w.resultFile });
    const a = await w.agent({ sUSD: 1_000_000n });
    const m0 = await w.bal.usdc(w.merchantAddress);
    const s0 = await w.bal.sUSD(a.address);
    const r = await a.pay(url('/work/micro'));
    assert.equal(r.paid, true, r.error);
    assert.equal(r.mode, 'router');
    assert.equal((await w.bal.usdc(w.merchantAddress)) - m0, 1_000n);
    const spent = s0 - (await w.bal.sUSD(a.address));
    assert.ok(absDiff(spent, 10_000_000_000_000_000n) <= 2n, `spent ${spent}`);
    const change = await w.bal.usdc(a.address);
    assert.ok(change > 8_900n && change < 9_000n, `USDC change ${change}`);
    assert.match(r.body, /A paid result/);
  });

  test('a smart account (ERC-1271) pays in sUSD and through the router', async () => {
    const owner = await w.keystore('owner1271');
    const wallet = await w.deploy1271(owner.address);
    const a = await w.agent({ signer: owner, payer: wallet, sUSD: 5_000_000n });
    assert.equal(a.address, wallet);
    const s0 = await w.bal.sUSD(wallet);
    const r1 = await a.pay(url('/api/v1/compute'));
    assert.equal(r1.paid, true, r1.error);
    assert.ok(absDiff(s0 - (await w.bal.sUSD(wallet)), COMPUTE) <= 2n);
    const m0 = await w.bal.usdc(w.merchantAddress);
    const r2 = await a.pay(url('/api/v1/premium'));
    assert.equal(r2.paid, true, r2.error);
    assert.equal(r2.mode, 'router');
    assert.equal((await w.bal.usdc(w.merchantAddress)) - m0, PREMIUM);
  });

  // ------------------------------------------------------------------ what must fail

  test('replay: a settled payment cannot be used again', async () => {
    const a = await w.agent({ sUSD: 10_000_000n });
    const r = await a.pay(url('/api/v1/compute'));
    assert.equal(r.paid, true, `${r.status} ${r.error}`);
    const m0 = await w.bal.sUSD(w.merchantAddress);
    const again = await submit(url('/api/v1/compute'), r.paymentPayload);
    assert.equal(again.status, 402);
    assert.equal(reasonOf(again), 'invalid_exact_evm_payload_authorization_nonce_used');
    assert.equal(await w.bal.sUSD(w.merchantAddress), m0);
  });

  test('tampering: lower amount, other recipient, lower advertised price, broken signature', async () => {
    const a = await w.agent({ sUSD: 10_000_000n });
    const { paymentPayload: pp } = await w.signedFor(a, url('/api/v1/compute'));
    const copy = () => JSON.parse(JSON.stringify(pp));

    const underpay = copy();
    underpay.payload.authorization.value = String(COMPUTE - 1n);
    let res = await submit(url('/api/v1/compute'), underpay);
    assert.equal(res.status, 402);
    assert.equal(reasonOf(res), 'invalid_exact_evm_payload_authorization_value');

    const redirect = copy();
    redirect.payload.authorization.to = ATTACKER;
    res = await submit(url('/api/v1/compute'), redirect);
    assert.equal(reasonOf(res), 'invalid_exact_evm_payload_recipient_mismatch');

    const cheap = copy();
    cheap.accepted.amount = '1';
    res = await submit(url('/api/v1/compute'), cheap);
    assert.equal(reasonOf(res), 'no matching payment option');

    const forged = copy();
    const sig = forged.payload.signature;
    forged.payload.signature = sig.slice(0, 20) + (sig[20] === 'a' ? 'b' : 'a') + sig.slice(21);
    res = await submit(url('/api/v1/compute'), forged);
    assert.equal(reasonOf(res), 'invalid_exact_evm_payload_signature');

    // after all that, the honest payment still goes through
    res = await submit(url('/api/v1/compute'), pp);
    assert.equal(res.status, 200);
  });

  test('time window: a stale authorization and a not-yet-valid one are refused', async () => {
    const a = await w.agent({ sUSD: 10_000_000n });
    const { paymentPayload: stale } = await w.signedFor(a, url('/api/v1/compute'));
    await w.warp(70); // past maxTimeoutSeconds (60)
    let res = await submit(url('/api/v1/compute'), stale);
    assert.equal(res.status, 402);
    assert.equal(reasonOf(res), 'invalid_exact_evm_payload_authorization_valid_before');

    const now = await w.now();
    const message = {
      from: a.address, to: w.merchantAddress, value: String(COMPUTE),
      validAfter: String(now + 30n), validBefore: String(now + 60n), nonce: rand32(),
    };
    const signature = await w.signAuthorization(a.key, { token: w.A.sUSD, message });
    const early = JSON.parse(JSON.stringify(stale));
    early.payload = { signature, authorization: message };
    res = await submit(url('/api/v1/compute'), early);
    assert.equal(reasonOf(res), 'invalid_exact_evm_payload_authorization_valid_after');
  });

  test('a signed payment from an empty account is refused before anything is sent', async () => {
    const key = await w.keystore('empty');
    const now = await w.now();
    const message = {
      from: key.address, to: w.merchantAddress, value: String(COMPUTE),
      validAfter: String(now - 600n), validBefore: String(now + 60n), nonce: rand32(),
    };
    const signature = await w.signAuthorization(key, { token: w.A.sUSD, message });
    const required = decode((await fetch(url('/api/v1/compute'))).headers.get(HEADER.required));
    const res = await submit(url('/api/v1/compute'), {
      x402Version: 2, resource: required.resource, accepted: required.accepts[0], payload: { signature, authorization: message },
    });
    assert.equal(res.status, 402);
    assert.equal(reasonOf(res), 'insufficient_funds');
    const broke = await w.agent({});
    await assert.rejects(broke.pay(url('/api/v1/compute')), /insufficient funds/);
  });

  test('router intent: the authorization cannot be redirected to another payee, amount or salt', async () => {
    const a = await w.agent({ sUSD: 10_000_000n });
    const { paymentPayload: pp, o } = await w.signedFor(a, url('/api/v1/premium'));
    assert.equal(o.mode, 'router');
    const check = (mutate) => {
      const p = JSON.parse(JSON.stringify(pp));
      const r = JSON.parse(JSON.stringify(o.r));
      mutate(p, r);
      p.accepted = r;
      return w.post('/verify', { x402Version: 2, paymentPayload: p, paymentRequirements: r });
    };
    assert.equal((await check((p, r) => { r.payTo = ATTACKER; })).invalidReason, 'invalid_spectrum_router_intent');
    assert.equal((await check((p, r) => { r.amount = '1'; })).invalidReason, 'invalid_spectrum_router_intent');
    assert.equal((await check((p) => { p.payload.spectrum.salt = rand32(); })).invalidReason, 'invalid_spectrum_router_intent');
    assert.equal((await check((p) => { p.payload.authorization.value = '1'; })).invalidReason, 'spectrum_authorization_too_small');
    assert.equal((await check(() => {})).isValid, true);
  });

  test('payTo guard: the facilitator never pays protocol contracts', async () => {
    const a = await w.agent({ sUSD: 1_000_000n });
    for (const target of [w.A.stabilizer, w.A.treasury, w.A.sUSD, w.A.router]) {
      const now = await w.now();
      const message = { from: a.address, to: target, value: '1000', validAfter: String(now - 600n), validBefore: String(now + 60n), nonce: rand32() };
      const signature = await w.signAuthorization(a.key, { token: w.A.sUSD, message });
      const r = { scheme: 'exact', network: w.dep.network, asset: w.A.sUSD, payTo: target, amount: '1000', maxTimeoutSeconds: 60 };
      const v = await w.post('/verify', { x402Version: 2, paymentPayload: { x402Version: 2, accepted: r, payload: { signature, authorization: message } }, paymentRequirements: r });
      assert.equal(v.invalidReason, 'invalid_pay_to', target);
    }
  });

  test('version and network must match', async () => {
    const a = await w.agent({ sUSD: 1_000_000n });
    const { paymentPayload: pp, o } = await w.signedFor(a, url('/api/v1/compute'));
    assert.equal((await w.post('/verify', { x402Version: 1, paymentPayload: pp, paymentRequirements: o.r })).invalidReason, 'invalid_x402_version');
    const r = { ...o.r, network: 'eip155:8453' };
    assert.equal((await w.post('/verify', { x402Version: 2, paymentPayload: { ...pp, accepted: r }, paymentRequirements: r })).invalidReason, 'invalid_network');
  });

  test('a hostile maxTimeoutSeconds is rejected cleanly, never a 500, and cannot stretch the window (A-02)', async () => {
    const a = await w.agent({ sUSD: 10_000_000n });
    const { paymentPayload: pp, o } = await w.signedFor(a, url('/api/v1/compute'));
    for (const t of ['abc', 1.5, -1, '1e9', {}, [], '0x3c']) {
      const r = { ...o.r, maxTimeoutSeconds: t };
      const v = await w.post('/verify', { x402Version: 2, paymentPayload: { ...pp, accepted: r }, paymentRequirements: r });
      assert.equal(v.isValid, false, `maxTimeoutSeconds=${JSON.stringify(t)}`);
      assert.ok(v.invalidReason, `no invalidReason for ${JSON.stringify(t)} (a 500 leaked instead)`);
    }
    // null and undefined mean "not specified", so they fall back to the 60 s default.
    for (const t of [null, undefined]) {
      const r = { ...o.r, maxTimeoutSeconds: t };
      assert.equal((await w.post('/verify', { x402Version: 2, paymentPayload: { ...pp, accepted: r }, paymentRequirements: r })).isValid, true);
    }
    // An absurd timeout must not let a far-future authorization through: it is capped.
    const far = JSON.parse(JSON.stringify(pp));
    const now = await w.now();
    far.payload.authorization.validBefore = String(now + 86_400n);
    far.payload.authorization.nonce = '0x' + randomBytes(32).toString('hex');
    far.payload.signature = await w.signAuthorization(a.key, { token: w.A.sUSD, message: far.payload.authorization });
    const wide = { ...o.r, maxTimeoutSeconds: '99999999999' };
    const v = await w.post('/verify', { x402Version: 2, paymentPayload: { ...far, accepted: wide }, paymentRequirements: wide });
    assert.equal(v.invalidReason, 'invalid_exact_evm_payload_authorization_valid_before');
    // The honest requirement still verifies.
    assert.equal((await w.post('/verify', { x402Version: 2, paymentPayload: pp, paymentRequirements: o.r })).isValid, true);
  });

  test('a merchant-supplied router address is ignored by the agent', async () => {
    const a = await w.agent({ sUSD: 1_000_000n });
    const premium = decode((await fetch(url('/api/v1/premium'))).headers.get(HEADER.required)).accepts[0];
    const evil = { ...premium, extra: { ...premium.extra, spectrumRouter: ATTACKER } };
    const o = await a.choose([evil]);
    assert.equal(o.mode, 'convert', 'falls back to converting through its own facilitator');
    const offline = await w.agent({ sUSD: 1_000_000n, facilitator: false });
    await assert.rejects(offline.choose([evil]), /insufficient funds/);
  });

  test('settlement failure: work done, payment failed, nothing delivered (402)', async () => {
    const a = await w.agent({ sUSD: 1_000_000n });
    const r = await a.pay(url('/api/v1/race'));
    assert.equal(r.status, 402);
    assert.equal(r.paid, false);
    assert.equal(r.error, 'insufficient_funds');
    assert.ok(!r.body.includes('shouldNotBeDelivered'));
  });

  // ------------------------------------------------------------------ agent policy

  test('spend policy: per-request limit, budget and allow list stop the agent before it signs', async () => {
    const m0 = await w.bal.sUSD(w.merchantAddress);
    const capped = await w.agent({ sUSD: 1_000_000n, policy: { maxPerRequest: 1_000n } }); // $0.001
    await assert.rejects(capped.pay(url('/api/v1/compute')), (e) => e instanceof PolicyError && /per-request limit/.test(e.message));

    const budgeted = await w.agent({ sUSD: 1_000_000n, policy: { budget: 8_000n } }); // $0.008
    assert.equal((await budgeted.pay(url('/api/v1/compute'))).paid, true);
    await assert.rejects(budgeted.pay(url('/api/v1/compute')), (e) => e instanceof PolicyError && /budget exhausted/.test(e.message));
    assert.equal(budgeted.spent, 5_000n);

    const listed = await w.agent({ sUSD: 1_000_000n, policy: { allowedPayTo: [ATTACKER] } });
    await assert.rejects(listed.pay(url('/api/v1/compute')), (e) => e instanceof PolicyError && /allow list/.test(e.message));
    assert.ok(absDiff((await w.bal.sUSD(w.merchantAddress)) - m0, COMPUTE) <= 2n, 'only the one allowed payment went through');
  });

  // ------------------------------------------------------------------ rebasing and settlement

  test('a rebase between signing and settlement does not break either payment kind', async () => {
    const a = await w.agent({ sUSD: 20_000_000n });
    await w.warp(3601); // a rebase is due
    const vault = w.first(await w.chain.call(w.A.treasury, 'vault()(address)'));
    await w.fundUSDC(vault, 1_000_000n); // a little vault interest, so there is surplus to distribute
    const direct = await w.signedFor(a, url('/api/v1/compute'));
    const routed = await w.signedFor(a, url('/api/v1/premium'));
    const i0 = await w.index();
    const rebased = await w.send(w.A.stabilizer, 'rebase()');
    assert.equal(rebased.ok, true);
    assert.ok((await w.index()) > i0, 'the index rose between signing and settlement');
    const m0 = await w.bal.usdc(w.merchantAddress);
    assert.equal((await submit(url('/api/v1/compute'), direct.paymentPayload)).status, 200);
    assert.equal((await submit(url('/api/v1/premium'), routed.paymentPayload)).status, 200);
    assert.equal((await w.bal.usdc(w.merchantAddress)) - m0, PREMIUM);
  });

  test('settle is idempotent per request, and a cached success is never reused for other requirements', async () => {
    const a = await w.agent({ sUSD: 10_000_000n });
    const { paymentPayload: pp, o } = await w.signedFor(a, url('/api/v1/compute'));
    const body = { x402Version: 2, paymentPayload: pp, paymentRequirements: o.r };
    const m0 = await w.bal.sUSD(w.merchantAddress);
    const [s1, s2] = await Promise.all([w.post('/settle', body), w.post('/settle', body)]);
    assert.equal(s1.success, true);
    assert.equal(s2.success, true);
    assert.equal(s1.transaction, s2.transaction);
    assert.equal((await w.post('/settle', body)).transaction, s1.transaction);
    assert.ok(absDiff((await w.bal.sUSD(w.merchantAddress)) - m0, COMPUTE) <= 2n, 'paid once');

    const other = { ...o.r, payTo: ATTACKER };
    const s4 = await w.post('/settle', { x402Version: 2, paymentPayload: { ...pp, accepted: other }, paymentRequirements: other });
    assert.equal(s4.success, false);
    assert.equal(s4.errorReason, 'invalid_exact_evm_payload_authorization_nonce_used');
  });

  test('a lost receipt is reported as unconfirmed with its hash; a retry confirms it, and it was paid once', async () => {
    const real = makeChain(RPC);
    let lose = 1;
    const flaky = Object.create(real);
    flaky.receipt = async (hash) => {
      if (lose > 0) {
        lose--;
        throw new Error('receipt lost');
      }
      return real.receipt(hash);
    };
    const s = await w.stack(flaky);
    const settle = (b) =>
      fetch(`${s.facilitatorUrl}/settle`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b) }).then((r) => r.json());

    const a = await w.agent({ sUSD: 10_000_000n });
    const { paymentPayload: pp, o } = await w.signedFor(a, url('/api/v1/compute'));
    const body = { x402Version: 2, paymentPayload: pp, paymentRequirements: o.r };
    const m0 = await w.bal.sUSD(w.merchantAddress);
    const s1 = await settle(body);
    assert.equal(s1.success, false);
    assert.equal(s1.errorReason, 'settlement_unconfirmed');
    assert.match(s1.transaction, /^0x[0-9a-f]{64}$/, 'the hash of what was sent is reported');
    const s2 = await settle(body);
    assert.equal(s2.success, true);
    assert.equal(s2.transaction, s1.transaction);
    assert.ok(absDiff((await w.bal.sUSD(w.merchantAddress)) - m0, COMPUTE) <= 2n, 'paid exactly once');

    lose = 1; // through a merchant: it asks again by itself and delivers
    const r = await a.pay(`${s.merchantUrl}/api/v1/compute`);
    assert.equal(r.paid, true, r.error);
  });
});

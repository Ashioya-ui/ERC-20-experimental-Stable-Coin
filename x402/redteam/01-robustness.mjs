// Attack class: malformed / oversized / type-confused input to the facilitator.
// Goal: structured errors, never a 500 / crash / hang. We probe fields that reach code paths
// that are NOT behind the isUint/isAddress validators.
import { FAC, MER, post, makeRedteamAgent } from './lib.mjs';
import { makeChain } from '../lib/cast.mjs';

const chain = makeChain(process.env.RPC_URL);
const now = await chain.timestamp();
const SUSD = (process.env.SUSD || '').toLowerCase();
const MERCHANT = (process.env.MERCHANT || '').toLowerCase();

// A body that passes every validator up to the maxTimeoutSeconds handling.
function wellFormed(overrides = {}) {
  const auth = {
    from: '0x9c98c320f674f0b380a15e189b06b790ed6267dc',
    to: MERCHANT,
    value: '5000000000000000',
    validAfter: '0',
    validBefore: String(now + 100000n),
    nonce: '0x' + '11'.repeat(32),
    ...(overrides.auth || {}),
  };
  const r = {
    scheme: 'exact', network: 'eip155:31337', asset: SUSD, payTo: MERCHANT,
    amount: '5000000000000000', maxTimeoutSeconds: 60, ...(overrides.r || {}),
  };
  delete overrides.auth; delete overrides.r;
  return {
    x402Version: 2,
    paymentPayload: { x402Version: 2, accepted: r, payload: { signature: '0x00', authorization: auth } },
    paymentRequirements: r,
    ...overrides,
  };
}

const cases = [
  ['maxTimeoutSeconds = non-numeric string', wellFormed({ r: { maxTimeoutSeconds: 'abc', scheme: 'exact', network: 'eip155:31337', asset: SUSD, payTo: MERCHANT, amount: '5000000000000000' } })],
  ['maxTimeoutSeconds = float', wellFormed({ r: { maxTimeoutSeconds: 1.5, scheme: 'exact', network: 'eip155:31337', asset: SUSD, payTo: MERCHANT, amount: '5000000000000000' } })],
  ['maxTimeoutSeconds = huge-string', wellFormed({ r: { maxTimeoutSeconds: '99999999999999999999', scheme: 'exact', network: 'eip155:31337', asset: SUSD, payTo: MERCHANT, amount: '5000000000000000' } })],
  ['maxTimeoutSeconds = object', wellFormed({ r: { maxTimeoutSeconds: {}, scheme: 'exact', network: 'eip155:31337', asset: SUSD, payTo: MERCHANT, amount: '5000000000000000' } })],
  ['maxTimeoutSeconds = null', wellFormed({ r: { maxTimeoutSeconds: null, scheme: 'exact', network: 'eip155:31337', asset: SUSD, payTo: MERCHANT, amount: '5000000000000000' } })],
  ['amount = array', wellFormed({ r: { amount: ['5000000000000000'], scheme: 'exact', network: 'eip155:31337', asset: SUSD, payTo: MERCHANT, maxTimeoutSeconds: 60 } })],
  ['auth.value = number not string', wellFormed({ auth: { value: 5000000000000000 } })],
  ['nonce = short', wellFormed({ auth: { nonce: '0xdead' } })],
  ['from = flaggy "--rpc-url"', wellFormed({ auth: { from: '--rpc-url' } })],
  ['signature = odd hex', wellFormed({ payload: { signature: '0x0', authorization: wellFormed().paymentPayload.payload.authorization } })],
  ['missing paymentPayload', { x402Version: 2, paymentRequirements: wellFormed().paymentRequirements }],
  ['null body-ish', {}],
  ['deeply nested arrays', { x402Version: 2, paymentPayload: { x402Version: 2, accepted: [[[[]]]], payload: [[[]]] }, paymentRequirements: [[[]]] }],
];

for (const ep of ['/verify', '/settle']) {
  for (const [name, body] of cases) {
    try {
      const r = await post(FAC, ep, body);
      const flag = r.status >= 500 ? '  <-- 500!' : (r.status !== 200 ? `  <-- ${r.status}` : '');
      console.log(`${ep} | ${name} -> ${r.status} ${JSON.stringify(r.json ?? r.text).slice(0, 160)}${flag}`);
    } catch (e) {
      console.log(`${ep} | ${name} -> THREW ${e.message}`);
    }
  }
}

// /convert odd bodies
for (const [name, body] of [
  ['convert amount=abc', { amount: 'abc', payload: { authorization: { from: '0x9c98c320f674f0b380a15e189b06b790ed6267dc' } } }],
  ['convert maxTimeoutSeconds=abc', { amount: '10000', maxTimeoutSeconds: 'abc', payload: { authorization: { from: '0x9c98c320f674f0b380a15e189b06b790ed6267dc', to: process.env.ROUTER, value: '1', validAfter: '0', validBefore: String(now + 1000n), nonce: '0x' + '22'.repeat(32) }, signature: '0x00' }, spectrum: { salt: '0x' + '00'.repeat(32) } }],
  ['convert payload missing', { amount: '10000' }],
]) {
  try {
    const r = await post(FAC, '/convert', body);
    const flag = r.status >= 500 ? '  <-- 500!' : '';
    console.log(`/convert | ${name} -> ${r.status} ${JSON.stringify(r.json ?? r.text).slice(0, 160)}${flag}`);
  } catch (e) {
    console.log(`/convert | ${name} -> THREW ${e.message}`);
  }
}

// Oversized body (> 64KiB limit in readJson)
{
  const big = 'x'.repeat(70 * 1024);
  const r = await post(FAC, '/verify', null, { raw: JSON.stringify({ pad: big, x402Version: 2 }) });
  console.log(`/verify | oversized 70KiB body -> ${r.status} ${JSON.stringify(r.json ?? r.text).slice(0, 120)}`);
}
// Invalid JSON
{
  const r = await post(FAC, '/verify', null, { raw: '{not json' });
  console.log(`/verify | invalid JSON -> ${r.status} ${JSON.stringify(r.json ?? r.text).slice(0, 120)}`);
}

// Health after the barrage
const h = await fetch(`${FAC}/health`).then((x) => x.json()).catch((e) => ({ err: e.message }));
console.log('facilitator /health after barrage:', JSON.stringify(h));
const hm = await fetch(`${MER}/health`).then((x) => x.json()).catch((e) => ({ err: e.message }));
console.log('merchant /health after barrage:', JSON.stringify(hm));

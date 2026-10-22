// Merchant robustness to bad PAYMENT-SIGNATURE, facilitator payTo guard (T13), and the
// router-vs-facilitator payTo guard consistency (router allows payTo==USDC; facilitator forbids it).
import { FAC, MER, post, makeRedteamAgent } from './lib.mjs';
import { makeChain } from '../lib/cast.mjs';

const chain = makeChain(process.env.RPC_URL);
const agent = await makeRedteamAgent();
const now = await chain.timestamp();
const A = { router: (process.env.ROUTER||'').toLowerCase(), susd: (process.env.SUSD||'').toLowerCase(), usdc: (process.env.USDC||'').toLowerCase(), stab: (process.env.STABILIZER||'').toLowerCase(), treas: (process.env.TREASURY||'').toLowerCase(), merchant: (process.env.MERCHANT||'').toLowerCase() };
const log = (...a) => console.log(...a);

// ---- 1. Merchant with malformed PAYMENT-SIGNATURE headers: must be clean 402, never 500 ----
for (const [name, hv] of [
  ['not base64 (!!!)', '!!!!not base64!!!'],
  ['base64 of non-JSON', Buffer.from('hello not json').toString('base64')],
  ['base64 of JSON array', Buffer.from('[1,2,3]').toString('base64')],
  ['base64 of {}', Buffer.from('{}').toString('base64')],
  ['base64 of null', Buffer.from('null').toString('base64')],
  ['huge nested string', Buffer.from(JSON.stringify({ accepted: { x: 'A'.repeat(4000) } })).toString('base64')],
]) {
  const res = await fetch(`${MER}/api/v1/compute`, { headers: { 'PAYMENT-SIGNATURE': hv } });
  log('[merchant bad header: %s] -> %s%s', name, res.status, res.status >= 500 ? '  <-- 500!' : '');
}

// ---- 2. Facilitator payTo guard: direct /verify to protocol contracts + zero ----
function body(payTo) {
  const auth = { from: agent.address, to: payTo, value: '5000000000000000', validAfter: '0', validBefore: String(now + 50n), nonce: '0x' + 'ab'.repeat(32) };
  const r = { scheme: 'exact', network: 'eip155:31337', asset: A.susd, payTo, amount: '5000000000000000', maxTimeoutSeconds: 60 };
  return { x402Version: 2, paymentPayload: { x402Version: 2, accepted: r, payload: { signature: '0x00', authorization: auth } }, paymentRequirements: r };
}
for (const [name, addr] of [['router', A.router], ['sUSD', A.susd], ['USDC', A.usdc], ['stabilizer', A.stab], ['treasury', A.treas], ['zero', '0x' + '0'.repeat(40)]]) {
  const r = await post(FAC, '/verify', body(addr));
  log('[payTo guard %s] isValid=%s reason=%s', name, r.json?.isValid, r.json?.invalidReason);
}

// ---- 3. Router pay() payTo guard directly on-chain: does it forbid USDC like the facilitator? ----
// We do NOT send; we only eth_call to see which payTo values the router itself rejects.
async function routerAllows(payTo) {
  // Use a dummy, unsigned call; InvalidPayTo reverts BEFORE signature checks, so a revert
  // naming InvalidPayTo => rejected; any other revert => the payTo guard let it through.
  try {
    await chain.call(A.router, 'pay(address,uint256,uint256,uint256,address,uint256,bytes32,bytes)',
      [agent.address, '1000000000000000000', '0', String(now + 50n), payTo, '1', '0x' + '00'.repeat(32), '0x00'], { from: agent.address });
    return 'no-revert';
  } catch (e) {
    const m = (e.stderr || e.message || '');
    if (/InvalidPayTo/i.test(m)) return 'InvalidPayTo (rejected)';
    return 'other-revert (payTo accepted): ' + m.replace(/\s+/g, ' ').slice(0, 70);
  }
}
for (const [name, addr] of [['USDC', A.usdc], ['router', A.router], ['treasury', A.treas], ['merchant', A.merchant], ['zero', '0x' + '0'.repeat(40)]]) {
  log('[router.pay payTo=%s] %s', name, await routerAllows(addr));
}

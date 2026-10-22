// /convert abuse, facilitator gas accounting, time-window enforcement, sUSD-path front-run.
import { FAC, MER, post, payMerchant, makeRedteamAgent, HEADER } from './lib.mjs';
import { makeChain, parseSigner } from '../lib/cast.mjs';
import { decode } from '../lib/protocol.mjs';

const chain = makeChain(process.env.RPC_URL);
const signer = parseSigner(`keystore:${process.env.X402_WALLETS}/redteam`, process.env.AGENT_PASSWORD_FILE);
const agent = await makeRedteamAgent();
const A = { router: (process.env.ROUTER||'').toLowerCase(), susd: (process.env.SUSD||'').toLowerCase(), usdc: (process.env.USDC||'').toLowerCase(), merchant: (process.env.MERCHANT||'').toLowerCase() };
const FACACC = (process.env.X402_FACILITATOR_ACCOUNT||'').toLowerCase();
const log = (...a) => console.log(...a);
const eth = (who) => chain.uint('0x0000000000000000000000000000000000000000', '', []).catch(()=>0n); // placeholder
const ethBal = async (who) => BigInt(await (await import('../lib/cast.mjs')).cast(['balance', who, '--rpc-url', process.env.RPC_URL]));
const usdc = async (who) => chain.uint(A.usdc, 'balanceOf(address)(uint256)', [who]);
const susd = async (who) => chain.uint(A.susd, 'balanceOf(address)(uint256)', [who]);

// ---- 1. Legit /convert, quantify facilitator gas spend (the operator pays gas; is it bounded?) ----
{
  const facEthBefore = await ethBal(FACACC);
  const meUsdcBefore = await usdc(agent.address);
  const out = await agent.convert(10000n); // 0.01 USDC
  const facEthAfter = await ethBal(FACACC);
  const meUsdcAfter = await usdc(agent.address);
  log('[convert 0.01] tx=%s  me USDC +%s  facilitator ETH spent(gas)=%s wei',
    out.transaction, (meUsdcAfter - meUsdcBefore).toString(), (facEthBefore - facEthAfter).toString());
}

// ---- 2. /convert cannot be aimed at a merchant: present a router auth signed for payTo=merchant ----
{
  const res = await fetch(`${MER}/api/v1/premium`);
  const required = decode(res.headers.get(HEADER.required));
  const o = await agent.choose(required.accepts, 'router');   // nonce commits to payTo=merchant
  const payload = await agent.authorize(o);
  const r = await post(FAC, '/convert', { amount: o.r.amount, payload, maxTimeoutSeconds: 120 });
  log('[convert aimed at merchant auth] success=%s reason=%s (merchant must NOT be paid)', r.json?.success, r.json?.errorReason);
}

// ---- 3. /convert beyond balance: clean failure, no tx sent (no gas burned) ----
{
  const facEthBefore = await ethBal(FACACC);
  let err = null;
  try { await agent.convert(1_000_000_000000n); } catch (e) { err = e.message; } // 1,000,000 USDC
  const facEthAfter = await ethBal(FACACC);
  log('[convert 1e6 USDC > balance] threw=%s  facilitator gas burned=%s wei (want 0)', (err||'').slice(0,60), (facEthBefore-facEthAfter).toString());
}

// ---- 4. Time window enforced via the merchant (T7) ----
async function craftCompute(mut) {
  const res = await fetch(`${MER}/api/v1/compute`);
  const required = decode(res.headers.get(HEADER.required));
  const o = await agent.choose(required.accepts);
  const payload = await agent.authorize(o);
  mut(payload.authorization);
  // re-sign is impossible without matching fields; we only need the facilitator to reject on the window,
  // which it checks BEFORE the signature simulation.
  return { x402Version: 2, resource: required.resource, accepted: o.r, payload };
}
{
  const now = await chain.timestamp();
  const future = await craftCompute((a) => { a.validAfter = String(now + 100000n); });
  const r1 = await payMerchant('/api/v1/compute', future);
  log('[window validAfter in future] status=%s err=%s', r1.status, (()=>{try{return JSON.parse(r1.body).error}catch{return '?'}})());
  const longlived = await craftCompute((a) => { a.validBefore = String(now + 100000n); });
  const r2 = await payMerchant('/api/v1/compute', longlived);
  log('[window validBefore too far] status=%s err=%s', r2.status, (()=>{try{return JSON.parse(r2.body).error}catch{return '?'}})());
}

// ---- 5. sUSD-path front-run (compute): transferWithAuthorization is permissionless ----
{
  const res = await fetch(`${MER}/api/v1/compute`);
  const required = decode(res.headers.get(HEADER.required));
  const o = await agent.choose(required.accepts);
  const payload = await agent.authorize(o);
  const pp = { x402Version: 2, resource: required.resource, accepted: o.r, payload };
  const a = payload.authorization;
  const mBefore = await susd(A.merchant);
  // submit the transfer myself (front-runner)
  const sent = await chain.send(A.susd, 'transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)',
    [a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, payload.signature], signer);
  const mAfter = await susd(A.merchant);
  log('[sUSD frontrun] ok=%s merchant sUSD +%s', sent.ok, (mAfter - mBefore).toString());
  const r = await payMerchant('/api/v1/compute', pp);
  log('[sUSD frontrun then honest] status=%s err=%s (paid, content=%s)', r.status, (()=>{try{return JSON.parse(r.body).error}catch{return '?'}})(), r.status===200);
}

const b = await agent.balances();
log('[redteam balances] sUSD=%s USDC=%s', b.sUSD.toString(), b.usdc.toString());

import { FAC, MER, post, payMerchant, makeRedteamAgent, encode, HEADER } from './lib.mjs';

const agent = await makeRedteamAgent();
const log = (...a) => console.log(...a);

const r1 = await agent.pay(`${MER}/api/v1/compute`);
log('[baseline] compute paid=%s status=%s mode=%s tx=%s body=%s',
  r1.paid, r1.status, r1.mode, r1.settlement?.transaction, (r1.body || '').slice(0, 80));
const settledPayload = r1.paymentPayload;
const settleBody = { x402Version: 2, paymentPayload: settledPayload, paymentRequirements: settledPayload.accepted };

const replayM = await payMerchant('/api/v1/compute', settledPayload);
log('[replay@merchant] status=%s settlement=%s body=%s', replayM.status, JSON.stringify(replayM.settlement), replayM.body.slice(0, 120));

const idem = await post(FAC, '/settle', settleBody);
log('[idempotent@settle] success=%s tx=%s (orig tx=%s) same=%s',
  idem.json?.success, idem.json?.transaction, r1.settlement?.transaction, idem.json?.transaction === r1.settlement?.transaction);

const tamperedFp = JSON.parse(JSON.stringify(settleBody));
tamperedFp.paymentRequirements = { ...tamperedFp.paymentRequirements, payTo: agent.address };
tamperedFp.paymentPayload = { ...tamperedFp.paymentPayload, accepted: { ...tamperedFp.paymentPayload.accepted, payTo: agent.address } };
const rep2 = await post(FAC, '/settle', tamperedFp);
log('[replay@settle diff-fp, redirect payTo->me] success=%s reason=%s', rep2.json?.success, rep2.json?.errorReason);

const v = await post(FAC, '/verify', settleBody);
log('[verify settled again] isValid=%s reason=%s', v.json?.isValid, v.json?.invalidReason);

async function freshCompute() {
  const res = await fetch(`${MER}/api/v1/compute`);
  const required = (await import('../lib/protocol.mjs')).decode(res.headers.get(HEADER.required));
  const o = await agent.choose(required.accepts);
  const payload = await agent.authorize(o);
  return { required, o, paymentPayload: { x402Version: 2, resource: required.resource, accepted: o.r, payload } };
}

{
  const f = await freshCompute();
  f.paymentPayload.accepted = { ...f.paymentPayload.accepted, amount: '1' };
  const res = await payMerchant('/api/v1/compute', f.paymentPayload);
  log('[tamper accepted.amount=1] status=%s body=%s', res.status, res.body.slice(0, 100));
}
{
  const f = await freshCompute();
  f.paymentPayload.payload.authorization = { ...f.paymentPayload.payload.authorization, value: '1' };
  const res = await payMerchant('/api/v1/compute', f.paymentPayload);
  log('[tamper auth.value=1] status=%s settlement=%s body=%s', res.status, JSON.stringify(res.settlement), res.body.slice(0, 120));
}
{
  const f = await freshCompute();
  f.paymentPayload.payload.authorization = { ...f.paymentPayload.payload.authorization, to: agent.address };
  const res = await payMerchant('/api/v1/compute', f.paymentPayload);
  log('[tamper auth.to=me] status=%s settlement=%s body=%s', res.status, JSON.stringify(res.settlement), res.body.slice(0, 120));
}

{
  const f = await freshCompute();
  const res = await payMerchant('/api/v1/premium', f.paymentPayload);
  log('[cross-route reuse compute->premium] status=%s body=%s', res.status, res.body.slice(0, 100));
}

const b = await agent.balances();
log('[balances] sUSD=%s USDC=%s', b.sUSD.toString(), b.usdc.toString());

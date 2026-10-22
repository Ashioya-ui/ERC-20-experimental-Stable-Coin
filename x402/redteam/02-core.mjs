// Core attacks: baseline legit payment, replay (merchant + facilitator), idempotency, tampering.
import { FAC, MER, post, payMerchant, makeRedteamAgent, encode, HEADER } from './lib.mjs';

const agent = await makeRedteamAgent();
const log = (...a) => console.log(...a);

// ---- 1. Baseline: a legitimate sUSD payment to /api/v1/compute ----
const r1 = await agent.pay(`${MER}/api/v1/compute`);
log('[baseline] compute paid=%s status=%s mode=%s tx=%s body=%s',
  r1.paid, r1.status, r1.mode, r1.settlement?.transaction, (r1.body || '').slice(0, 80));
const settledPayload = r1.paymentPayload;                    // the exact payload that just settled
const settleBody = { x402Version: 2, paymentPayload: settledPayload, paymentRequirements: settledPayload.accepted };

// ---- 2. Replay the settled payload at the merchant (fresh HTTP request) ----
const replayM = await payMerchant('/api/v1/compute', settledPayload);
log('[replay@merchant] status=%s settlement=%s body=%s', replayM.status, JSON.stringify(replayM.settlement), replayM.body.slice(0, 120));

// ---- 3. Idempotency: resend the IDENTICAL body to /settle -> same answer, not a new charge ----
const idem = await post(FAC, '/settle', settleBody);
log('[idempotent@settle] success=%s tx=%s (orig tx=%s) same=%s',
  idem.json?.success, idem.json?.transaction, r1.settlement?.transaction, idem.json?.transaction === r1.settlement?.transaction);

// ---- 4. Replay with a DIFFERENT fingerprint but same (payer,nonce): must be rejected as replay ----
const tamperedFp = JSON.parse(JSON.stringify(settleBody));
tamperedFp.paymentRequirements = { ...tamperedFp.paymentRequirements, payTo: agent.address }; // redirect money to me
tamperedFp.paymentPayload = { ...tamperedFp.paymentPayload, accepted: { ...tamperedFp.paymentPayload.accepted, payTo: agent.address } };
const rep2 = await post(FAC, '/settle', tamperedFp);
log('[replay@settle diff-fp, redirect payTo->me] success=%s reason=%s', rep2.json?.success, rep2.json?.errorReason);

// ---- 5. Re-verify a settled authorization on-chain: should be nonce_used ----
const v = await post(FAC, '/verify', settleBody);
log('[verify settled again] isValid=%s reason=%s', v.json?.isValid, v.json?.invalidReason);

// ---- 6. Tampering at the merchant: craft a valid payload, then mutate fields ----
async function freshCompute() {
  const res = await fetch(`${MER}/api/v1/compute`);
  const required = (await import('../lib/protocol.mjs')).decode(res.headers.get(HEADER.required));
  const o = await agent.choose(required.accepts);
  const payload = await agent.authorize(o);
  return { required, o, paymentPayload: { x402Version: 2, resource: required.resource, accepted: o.r, payload } };
}

// 6a. Lower the amount in `accepted` (pay less): merchant should find no matching option
{
  const f = await freshCompute();
  f.paymentPayload.accepted = { ...f.paymentPayload.accepted, amount: '1' };
  const res = await payMerchant('/api/v1/compute', f.paymentPayload);
  log('[tamper accepted.amount=1] status=%s body=%s', res.status, res.body.slice(0, 100));
}
// 6b. accepted matches, but the signed authorization pays only 1 wei
{
  const f = await freshCompute();
  f.paymentPayload.payload.authorization = { ...f.paymentPayload.payload.authorization, value: '1' };
  const res = await payMerchant('/api/v1/compute', f.paymentPayload);
  log('[tamper auth.value=1] status=%s settlement=%s body=%s', res.status, JSON.stringify(res.settlement), res.body.slice(0, 120));
}
// 6c. accepted matches, but authorization.to = attacker (sUSD should still go to merchant payTo)
{
  const f = await freshCompute();
  f.paymentPayload.payload.authorization = { ...f.paymentPayload.payload.authorization, to: agent.address };
  const res = await payMerchant('/api/v1/compute', f.paymentPayload);
  log('[tamper auth.to=me] status=%s settlement=%s body=%s', res.status, JSON.stringify(res.settlement), res.body.slice(0, 120));
}

// ---- 7. Spend-less: present the compute payload (0.005 sUSD) at /api/v1/premium (0.05 USDC) ----
{
  const f = await freshCompute(); // an sUSD authorization for compute's payTo/amount
  const res = await payMerchant('/api/v1/premium', f.paymentPayload);
  log('[cross-route reuse compute->premium] status=%s body=%s', res.status, res.body.slice(0, 100));
}

const b = await agent.balances();
log('[balances] sUSD=%s USDC=%s', b.sUSD.toString(), b.usdc.toString());

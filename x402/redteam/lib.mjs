// Red-team helpers. No existing file is modified; this only reads deployment + builds requests.
import { parseSigner } from '../lib/cast.mjs';
import { createAgent } from '../agent.mjs';
import { encode, decode, HEADER, X402_VERSION } from '../lib/protocol.mjs';

export const RPC = process.env.RPC_URL || 'http://127.0.0.1:8545';
export const FAC = process.env.FACILITATOR_URL || 'http://127.0.0.1:4020';
export const MER = process.env.MERCHANT_URL || 'http://127.0.0.1:4021';

export async function makeRedteamAgent() {
  const signer = parseSigner(`keystore:${process.env.AGENT_KEYSTORE || process.env.X402_WALLETS + '/redteam'}`, process.env.AGENT_PASSWORD_FILE);
  return createAgent({ rpcUrl: RPC, signer, facilitatorUrl: FAC });
}

export async function post(base, path, body, { raw } = {}) {
  const res = await fetch(`${base}${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: raw != null ? raw : JSON.stringify(body),
  });
  let j = null, t = null;
  t = await res.text();
  try { j = JSON.parse(t); } catch { /* keep text */ }
  return { status: res.status, json: j, text: t };
}

export async function get402(path) {
  const res = await fetch(`${MER}${path}`);
  const h = res.headers.get(HEADER.required);
  const required = h ? decode(h) : await res.json();
  return { status: res.status, required };
}

// Pay the merchant directly with a crafted PAYMENT-SIGNATURE payload object.
export async function payMerchant(path, paymentPayload, { method = 'GET' } = {}) {
  const res = await fetch(`${MER}${path}`, {
    method, redirect: 'manual',
    headers: { [HEADER.signature]: encode(paymentPayload) },
  });
  const body = await res.text();
  const rh = res.headers.get(HEADER.response);
  return { status: res.status, body, settlement: rh ? decode(rh) : null, header: rh };
}

export { encode, decode, HEADER, X402_VERSION };

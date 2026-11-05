#!/usr/bin/env node
// The funding endpoint: M-Pesa or a card in, USDC on Base straight into an agent's wallet, through a
// licensed on-ramp partner (Kotani Pay). It holds the partner's API key, which must never ship in
// the npm package, and nothing else: no wallet, no key of any agent, no money.
//
//   POST /fund   { method: "mpesa" | "card", phone, name, amount (KES), address (the agent's wallet) }
//                -> { ok, message, redirectUrl?, referenceId }
//   GET  /fund/<referenceId>   the last status the partner reported for that order
//   POST /webhook/kotani       the partner's status callback
//   GET  /health
//
// Env: KOTANI_API_KEY (required), KOTANI_API_URL (default: the sandbox), PUBLIC_URL (this service's
// own https URL, for the partner's callback), PORT (8080), FUNDING_MIN_KES (100), FUNDING_MAX_KES (20000).
//
// Abuse: an M-Pesa order sends a payment prompt to a phone, so one phone gets at most one order every
// two minutes and one caller at most ten an hour; amounts stay between the minimum and the maximum.

import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { isMain } from './lib/cli.mjs';

const env = process.env;
const KOTANI = (env.KOTANI_API_URL || 'https://sandbox-api.kotanipay.com/api/v3').replace(/\/$/, '');
const MIN = Number(env.FUNDING_MIN_KES || 100);
const MAX = Number(env.FUNDING_MAX_KES || 20000);
const isAddress = (a) => /^0x[0-9a-fA-F]{40}$/.test(String(a ?? ''));

/** A Kenyan mobile number as +2547XXXXXXXX or +2541XXXXXXXX, or null. */
export function kenyanPhone(p) {
  const d = String(p ?? '').replace(/[\s()-]/g, '');
  const m = /^(?:\+?254|0)([17]\d{8})$/.exec(d);
  return m ? `+254${m[1]}` : null;
}

/** The partner request for one order (exported so it can be checked without a network). */
export function kotaniOrder({ method, phone, name, amount, address, referenceId, callbackUrl }) {
  return {
    ...(method === 'mpesa'
      ? { mobileMoney: { phoneNumber: phone, accountName: name, providerNetwork: 'MPESA' } }
      : { bankCheckout: { fullName: name, phoneNumber: phone, paymentMethod: 'CARD' } }),
    fiatAmount: amount, currency: 'KES', country: 'KE', chain: 'BASE', token: 'USDC',
    receiverAddress: address, referenceId, ...(callbackUrl ? { callbackUrl } : {}),
  };
}

export function createFunding({ apiKey = env.KOTANI_API_KEY, publicUrl = env.PUBLIC_URL, fetchImpl = fetch } = {}) {
  const lastByPhone = new Map();
  const byCaller = new Map();
  const status = new Map();
  const limited = (caller, phone) => {
    const now = Date.now();
    if (now - (lastByPhone.get(phone) ?? 0) < 120_000) return 'this phone had an order in the last two minutes';
    const recent = (byCaller.get(caller) ?? []).filter((t) => now - t < 3_600_000);
    if (recent.length >= 10) return 'too many orders from this caller in the last hour';
    lastByPhone.set(phone, now);
    byCaller.set(caller, [...recent, now]);
    return null;
  };

  async function fund(body, caller) {
    const method = String(body?.method ?? '');
    if (method !== 'mpesa' && method !== 'card') return [400, { ok: false, message: 'method must be mpesa or card' }];
    const phone = kenyanPhone(body?.phone);
    if (!phone) return [400, { ok: false, message: 'phone must be a Kenyan mobile number, like 0712 345 678' }];
    const name = String(body?.name ?? '').trim().slice(0, 80);
    if (name.length < 2) return [400, { ok: false, message: 'name is required: the name on the M-Pesa or card account' }];
    const amount = Math.round(Number(body?.amount));
    if (!Number.isFinite(amount) || amount < MIN || amount > MAX) {
      return [400, { ok: false, message: `amount must be between KES ${MIN} and KES ${MAX}` }];
    }
    if (!isAddress(body?.address)) return [400, { ok: false, message: 'address must be the agent wallet address (0x and 40 hex digits)' }];
    if (!apiKey) return [503, { ok: false, message: 'funding is not switched on: the partner key is not set' }];
    const why = limited(caller, phone);
    if (why) return [429, { ok: false, message: why }];
    const referenceId = randomUUID();
    const order = kotaniOrder({
      method, phone, name, amount, address: body.address, referenceId,
      callbackUrl: publicUrl ? `${publicUrl.replace(/\/$/, '')}/webhook/kotani` : undefined,
    });
    let res;
    let out;
    try {
      res = await fetchImpl(`${KOTANI}/onramp`, {
        method: 'POST', headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json' },
        body: JSON.stringify(order), signal: AbortSignal.timeout(30_000),
      });
      out = await res.json().catch(() => ({}));
    } catch (e) {
      return [502, { ok: false, message: `the payment partner did not answer: ${e.message}` }];
    }
    if (!res.ok || out?.success === false) {
      return [502, { ok: false, message: `the payment partner refused the order: ${out?.message || `HTTP ${res.status}`}` }];
    }
    status.set(referenceId, { state: 'created', at: new Date().toISOString(), method, amount });
    const redirectUrl = out?.data?.redirectUrl || null;
    const message = method === 'mpesa'
      ? `M-Pesa: approve the payment prompt for KES ${amount} on ${phone}. The USDC goes straight to ${body.address} on Base.`
      : `Card: pay KES ${amount} at the checkout link. The USDC goes straight to ${body.address} on Base.`;
    return [200, { ok: true, message: redirectUrl ? `${message} Checkout: ${redirectUrl}` : message, redirectUrl, referenceId }];
  }

  return http.createServer(async (req, res) => {
    const send = (code, obj) => {
      res.writeHead(code, { 'content-type': 'application/json' });
      res.end(JSON.stringify(obj));
    };
    const url = new URL(req.url, 'http://x');
    try {
      if (req.method === 'GET' && url.pathname === '/health') return send(200, { ok: true, partner: Boolean(apiKey) });
      if (req.method === 'GET' && url.pathname.startsWith('/fund/')) {
        return send(200, status.get(url.pathname.slice(6)) ?? { state: 'unknown' });
      }
      let raw = '';
      for await (const c of req) {
        raw += c;
        if (raw.length > 16_384) return send(413, { ok: false, message: 'body too large' });
      }
      const body = raw ? JSON.parse(raw) : {};
      if (req.method === 'POST' && url.pathname === '/fund') {
        const caller = String(req.headers['x-forwarded-for'] ?? req.socket.remoteAddress ?? '').split(',')[0].trim();
        const [code, out] = await fund(body, caller);
        return send(code, out);
      }
      if (req.method === 'POST' && url.pathname === '/webhook/kotani') {
        const ref = body?.referenceId ?? body?.data?.referenceId;
        if (ref && status.has(ref)) status.set(ref, { ...status.get(ref), state: String(body?.status ?? body?.data?.status ?? 'updated'), at: new Date().toISOString() });
        return send(200, { ok: true });
      }
      return send(404, { ok: false, message: 'not found' });
    } catch {
      return send(400, { ok: false, message: 'bad request' });
    }
  });
}

if (isMain(import.meta.url)) {
  const port = Number(env.PORT || 8080);
  createFunding().listen(port, () => console.log(`funding endpoint on :${port} (partner key ${env.KOTANI_API_KEY ? 'set' : 'missing'})`));
}

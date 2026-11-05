#!/usr/bin/env node
// M-Pesa for x402: top up through Daraja (M-Pesa Express or a Ratiba standing order), then pay each call with a signed running total.

import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { isMain } from './lib/cli.mjs';
import { hashTypedData, recoverAddress } from './lib/evm.mjs';
import {
  HEADER, KES_UNIT, MPESA_NETWORK, X402_VERSION, creditTypedData, decode, encode, isAddress, isUint, lc, refundTypedData,
  sameRequirement, sendJson,
} from './lib/protocol.mjs';

export const SANDBOX = {
  url: 'https://sandbox.safaricom.co.ke', shortcode: '174379',
  passkey: 'bfb279f9aa9bdbcf158e97dd71a467cd2e0c893059b10f78e6b72ada1ed2c919',
};
const FREQUENCY = { day: 2, week: 3, month: 4 };

export const msisdn = (p) => {
  const m = /^(?:\+?254|0)?([17]\d{8})$/.exec(String(p ?? '').replace(/[\s()-]/g, ''));
  return m ? `254${m[1]}` : null;
};
export const kes = (micro) => {
  const v = BigInt(micro);
  const a = v < 0n ? -v : v;
  return `${v < 0n ? '-' : ''}${a / KES_UNIT}.${String(a % KES_UNIT).padStart(6, '0').slice(0, 2)}`;
};
export function toMicro(amount) {
  const m = /^(\d{1,9})(?:\.(\d{1,6}))?$/.exec(String(amount).trim());
  if (!m) throw new Error(`bad KES amount ${amount}`);
  return BigInt(m[1]) * KES_UNIT + BigInt((m[2] ?? '').padEnd(6, '0') || '0');
}
const eat = (d = new Date()) => new Date(d.getTime() + 3 * 3_600_000).toISOString();
export const darajaTimestamp = (d) => eat(d).replace(/\D/g, '').slice(0, 14);
const yyyymmdd = (d) => eat(d).slice(0, 10).replace(/-/g, '');

export function createDaraja({ url = SANDBOX.url, key, secret, shortcode = SANDBOX.shortcode, passkey = SANDBOX.passkey, till, fetchImpl = fetch } = {}) {
  if (!key || !secret) throw new Error('the Daraja consumer key and secret are required');
  const base = String(url).replace(/\/$/, '');
  const payee = String(till || shortcode);
  let cached = null;
  async function token() {
    if (cached && cached.until > Date.now()) return cached.token;
    const r = await fetchImpl(`${base}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { authorization: `Basic ${Buffer.from(`${key}:${secret}`).toString('base64')}` }, signal: AbortSignal.timeout(20_000),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.access_token) throw new Error(`Daraja refused the app key and secret: ${j.errorMessage || `HTTP ${r.status}`}`);
    cached = { token: j.access_token, until: Date.now() + (Number(j.expires_in) || 3599) * 1000 - 60_000 };
    return cached.token;
  }
  async function call(path, body) {
    const r = await fetchImpl(`${base}${path}`, {
      method: 'POST', headers: { authorization: `Bearer ${await token()}`, 'content-type': 'application/json' },
      body: JSON.stringify(body), signal: AbortSignal.timeout(30_000),
    });
    return { httpStatus: r.status, ...(await r.json().catch(() => ({}))) };
  }
  const password = (ts) => Buffer.from(`${shortcode}${passkey}${ts}`).toString('base64');
  return {
    payee,
    stkPush({ phone, amount, reference, callbackUrl }) {
      const ts = darajaTimestamp();
      return call('/mpesa/stkpush/v1/processrequest', {
        BusinessShortCode: String(shortcode), Password: password(ts), Timestamp: ts,
        TransactionType: till ? 'CustomerBuyGoodsOnline' : 'CustomerPayBillOnline', Amount: amount, PartyA: phone, PartyB: payee,
        PhoneNumber: phone, CallBackURL: callbackUrl, AccountReference: reference, TransactionDesc: 'x402 credit',
      });
    },
    stkQuery(checkoutRequestId) {
      const ts = darajaTimestamp();
      return call('/mpesa/stkpushquery/v1/query', {
        BusinessShortCode: String(shortcode), Password: password(ts), Timestamp: ts, CheckoutRequestID: checkoutRequestId,
      });
    },
    ratiba({ phone, amount, frequency, start, end, name, reference, callbackUrl }) {
      return call('/standingorder/v1/createStandingOrderExternal', {
        StandingOrderName: name, StartDate: start, EndDate: end, BusinessShortCode: payee,
        TransactionType: till ? 'Standing Order Customer Pay Marchant' : 'Standing Order Customer Pay Bill',
        ReceiverPartyIdentifierType: till ? '2' : '4', Amount: String(amount), PartyA: phone, CallBackURL: callbackUrl,
        AccountReference: reference, TransactionDesc: 'x402 budget', Frequency: String(frequency),
      });
    },
    registerC2B({ confirmationUrl, validationUrl }) {
      return call('/mpesa/c2b/v1/registerurl', { ShortCode: payee, ResponseType: 'Completed', ConfirmationURL: confirmationUrl, ValidationURL: validationUrl });
    },
    b2c({ phone, amount, initiator, credential, resultUrl, timeoutUrl }) {
      return call('/mpesa/b2c/v1/paymentrequest', {
        InitiatorName: initiator, SecurityCredential: credential, CommandID: 'BusinessPayment', Amount: amount,
        PartyA: String(shortcode), PartyB: phone, Remarks: 'x402 refund', QueueTimeOutURL: timeoutUrl, ResultURL: resultUrl, Occasion: 'refund',
      });
    },
  };
}

export function createMpesa({
  daraja, file, publicUrl, callbackBase, secret, b2c = null, routes = [], minKes = 10, maxKes = 10_000, callbackIps = null, trustProxy = false,
}) {
  const state = file && existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {};
  for (const k of ['accounts', 'pending', 'refs', 'receipts', 'orders', 'refunds']) state[k] ??= {};
  state.secret = secret || state.secret || randomBytes(16).toString('hex');
  const save = () => {
    if (!file) return;
    const tmp = `${file}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
    renameSync(tmp, file);
  };
  save();
  const base = () => String(publicUrl || '').replace(/\/$/, '');
  const hookBase = String(callbackBase ?? (/^https:\/\//.test(base()) ? base() : 'https://x402.invalid')).replace(/\/$/, '');
  const hook = (name) => `${hookBase}/hooks/${state.secret}/${name}`;
  const darajaDown = (e) => [502, { ok: false, message: `M-Pesa did not answer: ${e.message}` }];
  const refOf = (address) => `x402${lc(address).slice(2, 10)}`;
  const accountOf = (address) => state.accounts[lc(address)];
  const open = (address) => (state.accounts[lc(address)] ??= { credited: '0', spent: '0', voucher: null, phone: null });
  const available = (a) => BigInt(a.credited) - BigInt(a.spent);
  const lastByPhone = new Map();
  const byCaller = new Map();
  const inflight = new Set();

  function credit(address, wholeKes, receipt, phone) {
    if (state.receipts[receipt]) return false;
    const a = open(address);
    a.credited = String(BigInt(a.credited) + BigInt(wholeKes) * KES_UNIT);
    if (phone) a.phone = phone;
    state.receipts[receipt] = lc(address);
    save();
    return true;
  }
  function limited(caller, phone) {
    const now = Date.now();
    if (now - (lastByPhone.get(phone) ?? 0) < 60_000) return 'this phone had a prompt in the last minute';
    const recent = (byCaller.get(caller) ?? []).filter((t) => now - t < 3_600_000);
    if (recent.length >= 10) return 'too many prompts from this caller in the last hour';
    lastByPhone.set(phone, now);
    byCaller.set(caller, [...recent, now]);
    return null;
  }
  function checkTopup({ address, phone, amount }) {
    if (!isAddress(address)) return 'address must be the agent wallet address (0x and 40 hex digits)';
    if (!msisdn(phone)) return 'phone must be a Safaricom number, like 0712 345 678';
    const n = Number(amount);
    if (!Number.isInteger(n) || n < minKes || n > maxKes) return `amount must be whole shillings between KES ${minKes} and KES ${maxKes}`;
    return null;
  }

  async function topup(body, caller) {
    const bad = checkTopup(body ?? {});
    if (bad) return [400, { ok: false, message: bad }];
    const phone = msisdn(body.phone);
    const why = limited(caller, phone);
    if (why) return [429, { ok: false, message: why }];
    const ref = refOf(body.address);
    state.refs[ref] = lc(body.address);
    const out = await daraja.stkPush({ phone, amount: Number(body.amount), reference: ref, callbackUrl: hook('stk') });
    if (String(out.ResponseCode) !== '0' || !out.CheckoutRequestID) {
      return [502, { ok: false, message: `M-Pesa refused the request: ${out.errorMessage || out.ResponseDescription || `HTTP ${out.httpStatus}`}` }];
    }
    state.pending[out.CheckoutRequestID] = { address: lc(body.address), phone, amount: Number(body.amount), at: Date.now() };
    save();
    return [200, { ok: true, id: out.CheckoutRequestID, message: `Approve the M-Pesa prompt for KES ${body.amount} on ${phone}.` }];
  }

  async function confirm(id, receipt) {
    const p = state.pending[id];
    if (!p) return state.orders[id] ?? { state: 'unknown' };
    const q = await daraja.stkQuery(id);
    const code = q.ResultCode === undefined || q.ResultCode === null ? null : String(q.ResultCode);
    if (code === '0') {
      delete state.pending[id];
      credit(p.address, p.amount, `stk:${id}`, p.phone);
      state.orders[id] = { state: 'paid', amount: p.amount, address: p.address, receipt: receipt || null, at: new Date().toISOString() };
    } else if (code !== null) {
      delete state.pending[id];
      state.orders[id] = { state: 'failed', reason: q.ResultDesc || `result ${code}` };
    } else if (Date.now() - p.at > 15 * 60_000) {
      delete state.pending[id];
      state.orders[id] = { state: 'failed', reason: 'no answer from M-Pesa in 15 minutes' };
    } else return { state: 'pending' };
    save();
    return state.orders[id];
  }

  async function ratiba(body, caller) {
    const bad = checkTopup(body ?? {});
    if (bad) return [400, { ok: false, message: bad }];
    const frequency = FREQUENCY[body.every];
    if (!frequency) return [400, { ok: false, message: 'every must be day, week or month' }];
    const end = body.until ? new Date(body.until) : new Date(Date.now() + 90 * 86_400_000);
    if (!(end.getTime() > Date.now())) return [400, { ok: false, message: 'until must be a date in the future' }];
    const phone = msisdn(body.phone);
    const why = limited(caller, phone);
    if (why) return [429, { ok: false, message: why }];
    const ref = refOf(body.address);
    state.refs[ref] = lc(body.address);
    const out = await daraja.ratiba({
      phone, amount: Number(body.amount), frequency, start: yyyymmdd(), end: yyyymmdd(end),
      name: `x402 ${ref} ${Date.now().toString(36)}`, reference: ref, callbackUrl: hook('ratiba'),
    });
    const code = out.ResponseHeader?.responseCode ?? out.responseHeader?.responseCode ?? out.ResponseCode;
    if (String(code) !== '200' && String(code) !== '0') {
      return [502, { ok: false, message: `M-Pesa refused the standing order: ${out.errorMessage || out.ResponseHeader?.responseDescription || `HTTP ${out.httpStatus}`}` }];
    }
    return [200, {
      ok: true,
      message: `Approve the M-Pesa prompt on ${phone}: KES ${body.amount} every ${body.every} until ${yyyymmdd(end)}, `
        + 'credited here each time it is paid. Cancel it any time from the M-Pesa menu (Ratiba).',
    }];
  }

  function voucherCheck(payload, requirement) {
    const v = payload?.payload;
    if (!v || !isAddress(v.account) || !isUint(v.cumulative) || typeof v.signature !== 'string') return { error: 'invalid_payload' };
    if (String(requirement.payTo) !== daraja.payee) return { error: 'wrong_payee' };
    let signer;
    try {
      signer = recoverAddress(hashTypedData(creditTypedData({ shortcode: daraja.payee, account: v.account, cumulative: v.cumulative })), v.signature);
    } catch {
      return { error: 'invalid_signature' };
    }
    if (lc(signer) !== lc(v.account)) return { error: 'invalid_signature' };
    const a = accountOf(v.account);
    const next = BigInt(v.cumulative);
    if (!a || next > BigInt(a.credited)) return { error: `insufficient_credit: KES ${kes(a ? available(a) : 0n)} left` };
    if (next < BigInt(a.spent) + BigInt(requirement.amount)) return { error: `stale_total: the last signed total is ${a.spent}` };
    return { a, next, v };
  }

  async function refund(body) {
    const a = isAddress(body?.address) ? accountOf(body.address) : null;
    if (!a?.phone) return [404, { ok: false, message: 'no M-Pesa credit for this address' }];
    const typed = refundTypedData({ shortcode: daraja.payee, account: lc(body.address), phone: a.phone, credited: a.credited });
    let signer = '';
    try {
      signer = recoverAddress(hashTypedData(typed), String(body.signature ?? ''));
    } catch {
    }
    if (lc(signer) !== lc(body.address)) return [401, { ok: false, message: 'the refund must be signed by the agent key' }];
    const whole = available(a) / KES_UNIT;
    if (whole < 10n) return [400, { ok: false, message: `KES ${kes(available(a))} left: refunds start at KES 10` }];
    if (!b2c) return [503, { ok: false, message: 'refunds by M-Pesa are not switched on here' }];
    const out = await daraja.b2c({ phone: a.phone, amount: Number(whole), ...b2c, resultUrl: hook('b2c'), timeoutUrl: hook('b2c-timeout') });
    if (String(out.ResponseCode) !== '0') return [502, { ok: false, message: `M-Pesa refused the refund: ${out.errorMessage || out.ResponseDescription || `HTTP ${out.httpStatus}`}` }];
    a.credited = String(BigInt(a.credited) - whole * KES_UNIT);
    state.refunds[out.ConversationID || out.OriginatorConversationID] = { address: lc(body.address), amount: String(whole), state: 'sent' };
    save();
    return [200, { ok: true, message: `KES ${whole} is on its way back to ${a.phone} by M-Pesa.` }];
  }

  const offer = (route) => ({
    scheme: 'mpesa', network: MPESA_NETWORK, asset: 'KES', amount: String(toMicro(route.priceKes)), payTo: daraja.payee,
    maxTimeoutSeconds: 60, extra: { name: 'X402MpesaCredit', version: '1', credit: `${base()}/credit`, topup: `${base()}/topup`, ratiba: `${base()}/ratiba` },
  });

  async function hookCall(name, body, res) {
    const ok = () => sendJson(res, 200, { ResultCode: 0, ResultDesc: 'Accepted' });
    if (name === 'stk') {
      const cb = body?.Body?.stkCallback;
      const items = Object.fromEntries((cb?.CallbackMetadata?.Item ?? []).map((i) => [i.Name, i.Value]));
      if (cb?.CheckoutRequestID && state.pending[cb.CheckoutRequestID]) await confirm(cb.CheckoutRequestID, items.MpesaReceiptNumber);
      return ok();
    }
    if (name === 'c2b-validation') {
      return sendJson(res, 200, state.refs[body?.BillRefNumber] ? { ResultCode: '0', ResultDesc: 'Accepted' } : { ResultCode: 'C2B00012', ResultDesc: 'Rejected' });
    }
    if (name === 'c2b-confirmation') {
      const address = state.refs[body?.BillRefNumber];
      const whole = Math.floor(Number(body?.TransAmount));
      if (address && body?.TransID && whole > 0) credit(address, whole, `c2b:${body.TransID}`, null);
      return ok();
    }
    if (name === 'b2c' || name === 'b2c-timeout') {
      const r = body?.Result;
      const k = r?.ConversationID || r?.OriginatorConversationID;
      const f = state.refunds[k];
      if (f && f.state === 'sent' && (name === 'b2c-timeout' || String(r?.ResultCode) !== '0')) {
        const a = open(f.address);
        a.credited = String(BigInt(a.credited) + BigInt(f.amount) * KES_UNIT);
        f.state = 'returned';
        save();
      } else if (f) {
        f.state = 'paid';
        save();
      }
      return ok();
    }
    return ok();
  }

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://x');
      const socket = String(req.socket.remoteAddress ?? '').replace(/^::ffff:/, '');
      const caller = trustProxy ? String(req.headers['x-forwarded-for'] ?? socket).split(',')[0].trim() : socket;
      if (req.method === 'GET' && url.pathname === '/health') return sendJson(res, 200, { ok: true, shortcode: daraja.payee });
      const hk = /^\/hooks\/([0-9a-f]{32})\/([a-z0-9-]+)$/.exec(url.pathname);
      let raw = '';
      if (req.method === 'POST') {
        for await (const c of req) {
          raw += c;
          if (raw.length > 32_768) return sendJson(res, 413, { ok: false, message: 'body too large' });
        }
      }
      const body = raw ? JSON.parse(raw) : {};
      if (hk && req.method === 'POST') {
        if (hk[1] !== state.secret || (callbackIps && !callbackIps.includes(caller))) return sendJson(res, 404, { error: 'not found' });
        return await hookCall(hk[2], body, res);
      }
      const cr = /^\/credit\/(0x[0-9a-fA-F]{40})$/.exec(url.pathname);
      if (cr && req.method === 'GET') {
        const a = accountOf(cr[1]) ?? { credited: '0', spent: '0', voucher: null };
        return sendJson(res, 200, {
          shortcode: daraja.payee, account: lc(cr[1]), credited: a.credited, spent: a.spent, voucher: a.voucher,
          kes: { credited: kes(a.credited), spent: kes(a.spent), available: kes(available(a)) },
        });
      }
      const tq = /^\/topup\/([A-Za-z0-9_-]{6,80})$/.exec(url.pathname);
      if (tq && req.method === 'GET') return sendJson(res, 200, await confirm(tq[1]).catch((e) => ({ state: 'pending', note: e.message })));
      if (req.method === 'POST' && url.pathname === '/topup') return sendJson(res, ...(await topup(body, caller).catch(darajaDown)));
      if (req.method === 'POST' && url.pathname === '/ratiba') return sendJson(res, ...(await ratiba(body, caller).catch(darajaDown)));
      if (req.method === 'POST' && url.pathname === '/refund') return sendJson(res, ...(await refund(body).catch(darajaDown)));

      const route = routes.find((r) => r.path === url.pathname);
      if (!route || req.method !== 'GET') return sendJson(res, 404, { error: 'not found' });
      const resource = { url: `${base() || `http://${req.headers.host}`}${url.pathname}`, description: route.description, mimeType: 'application/json' };
      const accepts = [offer(route)];
      const required = (error) => {
        const r = { x402Version: X402_VERSION, error, resource, accepts };
        return sendJson(res, 402, r, { [HEADER.required]: encode(r) });
      };
      const header = req.headers[HEADER.signature.toLowerCase()];
      if (!header) return required('payment required');
      let payload;
      try {
        payload = decode(header);
      } catch {
        return required('invalid PAYMENT-SIGNATURE header');
      }
      const requirement = accepts.find((a) => sameRequirement(a, payload?.accepted));
      if (!requirement) return required('no matching payment option');
      const c = voucherCheck(payload, requirement);
      if (c.error) return required(c.error);
      const key = lc(c.v.account);
      if (inflight.has(key)) return required('busy: one paid call at a time per account');
      inflight.add(key);
      try {
        const result = await route.handler(payload);
        const again = voucherCheck(payload, requirement);
        if (again.error) return required(again.error);
        again.a.spent = String(again.next);
        again.a.voucher = { cumulative: String(again.next), signature: again.v.signature };
        save();
        const settled = {
          success: true, network: MPESA_NETWORK, payer: key, transaction: `${daraja.payee}:${key}:${again.next}`,
          remaining: String(available(again.a)),
        };
        res.writeHead(200, { 'content-type': 'application/json', [HEADER.response]: encode(settled), 'access-control-expose-headers': HEADER.response });
        return res.end(JSON.stringify(result));
      } finally {
        inflight.delete(key);
      }
    } catch (e) {
      if (!res.headersSent) sendJson(res, e instanceof SyntaxError ? 400 : 500, { ok: false, message: e instanceof SyntaxError ? 'bad request' : 'internal error' });
      else if (!res.writableEnded) res.end();
    }
  });
  return { server, state, hook, payee: daraja.payee, confirm };
}

if (isMain(import.meta.url)) {
  const env = process.env;
  const sandbox = !env.DARAJA_URL || env.DARAJA_URL.includes('sandbox');
  const daraja = createDaraja({
    url: env.DARAJA_URL || SANDBOX.url, key: env.DARAJA_KEY, secret: env.DARAJA_SECRET, till: env.DARAJA_TILL,
    shortcode: env.DARAJA_SHORTCODE || (sandbox ? SANDBOX.shortcode : undefined),
    passkey: env.DARAJA_PASSKEY || (sandbox ? SANDBOX.passkey : undefined),
  });
  const port = Number(env.PORT || 4022);
  const publicUrl = env.MPESA_PUBLIC_URL || `http://127.0.0.1:${port}`;
  let ticks = 0;
  const m = createMpesa({
    daraja, publicUrl, file: env.MPESA_FILE || join(homedir(), '.x402-mpesa.json'),
    secret: /^[0-9a-f]{32}$/.test(env.MPESA_HOOK_SECRET || '') ? env.MPESA_HOOK_SECRET : undefined,
    b2c: env.MPESA_B2C_INITIATOR && env.MPESA_B2C_CREDENTIAL ? { initiator: env.MPESA_B2C_INITIATOR, credential: env.MPESA_B2C_CREDENTIAL } : null,
    callbackIps: env.DARAJA_CALLBACK_IPS ? env.DARAJA_CALLBACK_IPS.split(',').map((x) => x.trim()) : null,
    trustProxy: env.MPESA_TRUST_PROXY === '1',
    routes: [{
      path: '/api/v1/tick', priceKes: env.MPESA_PRICE_KES || '0.5', description: 'One metered call, paid from M-Pesa credit',
      handler: async () => ({ tick: ++ticks, priceKes: env.MPESA_PRICE_KES || '0.5', servedAt: new Date().toISOString() }),
    }],
  });
  m.server.listen(port, env.HOST || '127.0.0.1', async () => {
    console.log(`M-Pesa x402 on ${publicUrl} (shortcode ${m.payee}${sandbox ? ', Daraja sandbox' : ''}); paid route ${publicUrl}/api/v1/tick`);
    if (env.MPESA_PUBLIC_URL && env.MPESA_REGISTER_C2B === '1') {
      const r = await daraja.registerC2B({ confirmationUrl: m.hook('c2b-confirmation'), validationUrl: m.hook('c2b-validation') }).catch((e) => ({ errorMessage: e.message }));
      console.log(`C2B URLs: ${r.ResponseDescription || r.errorMessage || `HTTP ${r.httpStatus}`}`);
    }
  });
}

#!/usr/bin/env node
// x402 client for an agent whose treasury is one sUSD balance: it earns while idle and pays
// x402 bills directly. The agent never manages a vault or a USDC float.
//
// For each 402 the client picks the first option that fits the balances and the spend policy:
//   sUSD     the merchant prices in sUSD: sign an EIP-3009 transfer to payTo
//   router   the merchant prices in USDC and offers the Spectrum router: sign a receive
//            authorization of sUSD to the router. Its nonce commits to (payTo, amount, salt), so
//            only that payment can be made with it. The merchant gets exact USDC and the change
//            comes back.
//   USDC     the agent holds USDC: a standard x402 USDC authorization
//   convert  the merchant takes only plain USDC: convert just enough sUSD to USDC through the
//            facilitator's /convert, then pay in USDC
//
// Trust: token, router and EIP-712 domain come from the agent's own deployment files, never
// from the merchant's 402. A merchant-supplied router address is ignored unless it is the known
// router, because a receive authorization lets its `to` move the whole value.
//
// Library: createAgent({ rpcUrl, signer, payer?, facilitatorUrl?, policy? }).
// CLI:     agent.mjs address | balance | pay <url> [--prefer <mode>] [--out <file>] | convert <usd>
//          Env: RPC_URL, AGENT_KEYSTORE, AGENT_PASSWORD_FILE, AGENT_PAYER (an ERC-1271 account
//          the key controls), FACILITATOR_URL, AGENT_MAX_PER_REQUEST and AGENT_BUDGET (USD),
//          AGENT_ALLOWED_PAYTO (comma-separated), AGENT_LEDGER (a JSON file that keeps the
//          amount spent across runs).

import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { first, makeChain, signTypedData, signerAddress } from './lib/cast.mjs';
import { loadDeployment } from './lib/config.mjs';
import { X402_VERSION, HEADER, encode, decode, lc, isAddress, isUint, authorizationTypedData } from './lib/protocol.mjs';

export class PolicyError extends Error {
  constructor(message) {
    super(message);
    this.name = 'PolicyError';
  }
}

const SCALE = 10n ** 12n; // sUSD has 18 decimals, USDC 6
const MODES = ['sUSD', 'router', 'USDC', 'convert'];

/** "1.25" (US dollars) -> 1_250_000n (6 decimals). */
export function parseUsd(s) {
  const m = /^(\d+)(?:\.(\d{1,6}))?$/.exec(String(s).trim());
  if (!m) throw new Error(`not a dollar amount: ${s}`);
  return BigInt(m[1]) * 1_000_000n + BigInt((m[2] || '').padEnd(6, '0'));
}

/** 1_250_000n with 6 decimals -> "1.25". */
export function formatUnits(x, decimals) {
  const neg = x < 0n;
  const v = neg ? -x : x;
  const base = 10n ** BigInt(decimals);
  const frac = (v % base).toString().padStart(decimals, '0').replace(/0+$/, '');
  return `${neg ? '-' : ''}${v / base}${frac ? '.' + frac : ''}`;
}

const rand32 = () => '0x' + randomBytes(32).toString('hex');

export async function createAgent({ rpcUrl, signer, payer, facilitatorUrl, policy = {}, ledgerFile, tmpDir }) {
  const chain = makeChain(rpcUrl);
  const dep = await loadDeployment(chain);
  const A = dep.addresses;
  const owner = await signerAddress(signer);
  const from = lc(payer || owner);
  if (!isAddress(from)) throw new Error(`bad payer address ${payer}`);
  const work = tmpDir || mkdtempSync(join(tmpdir(), 'x402-agent-'));

  const limits = {
    maxPerRequest: policy.maxPerRequest ?? null, // bigint, USD with 6 decimals
    budget: policy.budget ?? null, // bigint, USD with 6 decimals
    allowedPayTo: policy.allowedPayTo ? new Set(policy.allowedPayTo.map(lc)) : null,
  };
  const ledger = ledgerFile && existsSync(ledgerFile) ? JSON.parse(readFileSync(ledgerFile, 'utf8')) : { spent: '0', payments: [] };
  let spent = BigInt(ledger.spent);

  const usdOf = (mode, cost) => (mode === 'USDC' ? cost : (cost + SCALE - 1n) / SCALE);

  async function balances() {
    return {
      sUSD: await chain.uint(A.sUSD, 'balanceOf(address)(uint256)', [from]),
      usdc: await chain.uint(A.usdc, 'balanceOf(address)(uint256)', [from]),
    };
  }

  async function timeWindow(maxTimeoutSeconds) {
    const now = await chain.timestamp(); // chain time: the clock the token contract checks
    const t = BigInt(Math.max(10, Math.min(Number(maxTimeoutSeconds ?? 60), 600)));
    return { validAfter: String(now > 600n ? now - 600n : 0n), validBefore: String(now + t) };
  }

  function sign(primaryType, token, message) {
    const domain = token === A.sUSD ? dep.domains.sUSD : dep.domains.usdc;
    const typed = authorizationTypedData({
      primaryType, name: domain.name, version: domain.version, chainId: dep.chainId, verifyingContract: token, message,
    });
    return signTypedData(typed, signer, work);
  }

  /** The ways this agent could pay each requirement, cheapest-to-run first. */
  async function options(accepts) {
    const bal = await balances();
    const out = [];
    for (const r of Array.isArray(accepts) ? accepts : []) {
      if (r?.scheme !== 'exact' || r.network !== dep.network || !isAddress(r.payTo) || !isUint(r.amount)) continue;
      const amount = BigInt(r.amount);
      if (amount === 0n) continue;
      const asset = lc(r.asset);
      if (asset === A.sUSD) {
        out.push({ mode: 'sUSD', r, cost: amount, have: bal.sUSD >= amount });
      } else if (asset === A.usdc) {
        out.push({ mode: 'USDC', r, cost: amount, have: bal.usdc >= amount });
        if (A.router) {
          const value = await chain.uint(A.router, 'sUSDToAuthorize(uint256)(uint256)', [r.amount]);
          if (lc(r.extra?.spectrumRouter) === A.router) out.push({ mode: 'router', r, cost: value, have: bal.sUSD >= value });
          if (facilitatorUrl) out.push({ mode: 'convert', r, cost: value, have: bal.sUSD >= value });
        }
      }
    }
    return out.map((o) => ({ ...o, usd: usdOf(o.mode, o.cost) }));
  }

  function refusal(o) {
    if (limits.allowedPayTo && !limits.allowedPayTo.has(lc(o.r.payTo))) return `payTo ${o.r.payTo} is not on the allow list`;
    if (limits.maxPerRequest != null && o.usd > limits.maxPerRequest) {
      return `price $${formatUnits(o.usd, 6)} is above the per-request limit of $${formatUnits(limits.maxPerRequest, 6)}`;
    }
    if (limits.budget != null && spent + o.usd > limits.budget) {
      return `budget exhausted: $${formatUnits(spent, 6)} of $${formatUnits(limits.budget, 6)} spent`;
    }
    return null;
  }

  /** Pick how to pay: the first mode in preference order that is funded and allowed. */
  async function choose(accepts, prefer) {
    const all = await options(accepts);
    if (!all.length) throw new Error('no payment option this agent understands');
    const order = prefer ? [prefer, ...MODES.filter((m) => m !== prefer)] : MODES;
    const reasons = [];
    for (const mode of order) {
      for (const o of all.filter((x) => x.mode === mode)) {
        const why = refusal(o);
        if (why) reasons.push(why);
        else if (o.have) return o;
      }
    }
    if (reasons.length && all.every((o) => refusal(o))) throw new PolicyError(reasons[0]);
    throw new Error('insufficient funds for every payment option');
  }

  /** Sign the authorization for option `o` (no network call except chain reads). */
  async function authorize(o) {
    const { r } = o;
    const w = await timeWindow(r.maxTimeoutSeconds);
    if (o.mode === 'sUSD' || o.mode === 'USDC') {
      const token = o.mode === 'sUSD' ? A.sUSD : A.usdc;
      const authorization = { from, to: lc(r.payTo), value: String(r.amount), ...w, nonce: rand32() };
      return { signature: await sign('TransferWithAuthorization', token, authorization), authorization };
    }
    // Router: the nonce is the payment intent, so the authorization can only pay `amount` USDC
    // to `payTo`. The router address is the one from the agent's own deployment files.
    const salt = rand32();
    const nonce = lc(first(await chain.call(A.router, 'intentNonce(address,uint256,bytes32)(bytes32)', [r.payTo, r.amount, salt])));
    const authorization = { from, to: A.router, value: String(o.cost), ...w, nonce };
    return { signature: await sign('ReceiveWithAuthorization', A.sUSD, authorization), authorization, spectrum: { salt } };
  }

  function record(entry) {
    spent += entry.usd;
    ledger.spent = String(spent);
    ledger.payments.push({ ...entry, usd: formatUnits(entry.usd, 6), at: new Date().toISOString() });
    if (ledgerFile) writeFileSync(ledgerFile, JSON.stringify(ledger, null, 2));
  }

  /** Convert sUSD to exactly `amount` USDC (6 decimals) for this agent, through /convert. */
  async function convert(amount) {
    if (!facilitatorUrl || !A.router) throw new Error('convert needs a facilitator and the router');
    const value = await chain.uint(A.router, 'sUSDToAuthorize(uint256)(uint256)', [String(amount)]);
    const payload = await authorize({ mode: 'router', r: { payTo: from, amount: String(amount), maxTimeoutSeconds: 120 }, cost: value });
    const res = await fetch(`${facilitatorUrl}/convert`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ payload, amount: String(amount), maxTimeoutSeconds: 120 }),
    });
    const out = await res.json();
    if (!out.success) throw new Error(`convert failed: ${out.errorReason}`);
    return out;
  }

  /** The PAYMENT-REQUIRED object of a 402 (header first, body as fallback). */
  async function requiredOf(res) {
    const h = res.headers.get(HEADER.required);
    if (h) return decode(h);
    return res.json();
  }

  /**
   * GET (or `method`) `url`, paying if the server answers 402.
   * Resolves { status, paid, mode, requirement, settlement, body, error }.
   */
  async function pay(url, { prefer, method = 'GET', headers = {} } = {}) {
    const initial = await fetch(url, { method, headers });
    const payUrl = initial.url || url; // after any redirects of the unpaid request
    if (initial.status !== 402) return { status: initial.status, paid: false, body: await initial.text() };
    const required = await requiredOf(initial);
    if (required?.x402Version !== X402_VERSION) throw new Error(`unsupported x402 version ${required?.x402Version}`);

    const chosen = await choose(required.accepts, prefer);
    let o = chosen;
    let conversion = null;
    if (o.mode === 'convert') {
      conversion = await convert(o.r.amount); // USDC lands in this account; pay as plain USDC next
      o = { ...o, mode: 'USDC', cost: BigInt(o.r.amount) };
    }
    const payload = await authorize(o);
    const paymentPayload = { x402Version: X402_VERSION, resource: required.resource, accepted: o.r, payload };
    // The signed payment goes to the URL that asked for it and nowhere else: no redirects.
    const res = await fetch(payUrl, { method, redirect: 'manual', headers: { ...headers, [HEADER.signature]: encode(paymentPayload) } });
    const body = await res.text();
    const receipt = res.headers.get(HEADER.response);
    const settlement = receipt ? decode(receipt) : null;
    const paid = res.status === 200 && settlement?.success === true;
    let error;
    if (!paid && res.status === 402) {
      try {
        error = (await requiredOf(new Response(body, { headers: res.headers }))).error;
      } catch {
        error = 'payment rejected';
      }
    }
    if (paid || conversion) {
      // The budget is charged the most this payment could have cost (for the router: the
      // authorized sUSD, of which the change came back).
      record({
        url, mode: chosen.mode, payTo: o.r.payTo, asset: o.r.asset, amount: o.r.amount, usd: chosen.usd,
        transaction: settlement?.transaction || '', conversion: conversion?.transaction || undefined, delivered: paid,
      });
    }
    return { status: res.status, paid, mode: chosen.mode, requirement: o.r, settlement, conversion, body, error, paymentPayload };
  }

  return {
    address: from, owner, deployment: dep, balances, pay, convert, choose, authorize,
    get spent() { return spent; }, ledger: () => ledger,
  };
}

// ------------------------------------------------------------------------------------------- CLI

async function main(argv) {
  const { parseSigner } = await import('./lib/cast.mjs');
  const [cmd, ...rest] = argv;
  const flag = (name) => {
    const i = rest.indexOf(`--${name}`);
    return i >= 0 ? rest[i + 1] : undefined;
  };
  const env = process.env;
  const signer = parseSigner(`keystore:${env.AGENT_KEYSTORE}`, env.AGENT_PASSWORD_FILE);
  const agent = await createAgent({
    rpcUrl: env.RPC_URL || 'http://127.0.0.1:8545',
    signer,
    payer: env.AGENT_PAYER,
    facilitatorUrl: env.FACILITATOR_URL,
    ledgerFile: env.AGENT_LEDGER,
    policy: {
      maxPerRequest: env.AGENT_MAX_PER_REQUEST ? parseUsd(env.AGENT_MAX_PER_REQUEST) : null,
      budget: env.AGENT_BUDGET ? parseUsd(env.AGENT_BUDGET) : null,
      allowedPayTo: env.AGENT_ALLOWED_PAYTO ? env.AGENT_ALLOWED_PAYTO.split(',') : null,
    },
  });
  const show = (o) => console.log(JSON.stringify(o, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
  const bal = async () => {
    const b = await agent.balances();
    return { sUSD: formatUnits(b.sUSD, 18), USDC: formatUnits(b.usdc, 6) };
  };
  if (cmd === 'address') return show({ address: agent.address, owner: agent.owner });
  if (cmd === 'balance') return show({ address: agent.address, ...(await bal()), spentUSD: formatUnits(agent.spent, 6) });
  if (cmd === 'convert') {
    const out = await agent.convert(parseUsd(rest[0]));
    return show({ converted: rest[0], transaction: out.transaction, balances: await bal() });
  }
  if (cmd === 'pay') {
    const url = rest[0];
    const before = await bal();
    const r = await agent.pay(url, { prefer: flag('prefer') });
    const outFile = flag('out');
    if (outFile && r.paid) writeFileSync(outFile, r.body);
    show({
      url, status: r.status, paid: r.paid, mode: r.mode, price: r.requirement && { asset: r.requirement.asset, amount: r.requirement.amount, payTo: r.requirement.payTo },
      transaction: r.settlement?.transaction, error: r.error, before, after: await bal(),
      ...(outFile && r.paid ? { savedTo: outFile } : { body: r.paid ? r.body.slice(0, 400) : undefined }),
    });
    if (!r.paid) process.exitCode = 2;
    return;
  }
  console.error('usage: agent.mjs address | balance | pay <url> [--prefer sUSD|router|USDC|convert] [--out <file>] | convert <usd>');
  process.exitCode = 64;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2)).catch((e) => {
    console.error(`${e.name}: ${e.message}`);
    process.exitCode = e instanceof PolicyError ? 3 : 1;
  });
}

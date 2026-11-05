#!/usr/bin/env node
// x402-sessions MCP server (stdio): x402_wallet, x402_fetch, x402_discover, x402_fund.

console.log = console.info = console.debug = (...a) => console.error(...a);

import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { createAgent, formatUnits, parseUsd, policyFromEnv, PolicyError } from './agent.mjs';
import { isMain } from './lib/cli.mjs';
import { addressOfKey, newKey } from './lib/evm.mjs';

const PKG = (() => {
  try {
    return JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  } catch {
    return {};
  }
})();
const VERSION = String(PKG.name || '').endsWith('x402-sessions') ? PKG.version : 'dev';
const PROTOCOLS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const DEFAULT_RPC = 'https://mainnet.base.org,https://base-rpc.publicnode.com';
const MAX_BODY = 20_000;

const env = Object.fromEntries(
  Object.entries(process.env)
    .map(([k, v]) => [k, String(v ?? '').trim()])
    .filter(([, v]) => v !== '' && v !== 'undefined' && v !== 'null' && !/^\$\{[^}]*\}$/.test(v)),
);
const HOME = env.X402_HOME || join(homedir(), '.x402-sessions');
const usd = (units) => `$${formatUnits(units, 6)}`;

const problems = [];
function dollars(name, fallback) {
  const raw = env[name];
  if (raw === undefined) return parseUsd(fallback);
  const s = raw.replace(/^\$/, '').trim();
  try {
    return parseUsd(s);
  } catch {
    const n = Number(s);
    if (Number.isFinite(n) && n >= 0 && n < 1e15) return parseUsd(n.toFixed(6));
    problems.push(`${name} is "${raw}", which is not a dollar amount, so nothing is paid until it is fixed`);
    return 0n;
  }
}

const INSTRUCTIONS = [
  'x402_fetch fetches a URL and, when the server answers 402 Payment Required (the x402 protocol),',
  "pays it in USDC on Base from this agent's wallet, within the owner's per-call limit and total budget.",
  'Payments are real money. x402_wallet shows the balance, the limits, and the address to fund.',
].join(' ');

const TOOLS = [
  {
    name: 'x402_fetch',
    title: 'Fetch a URL, paying with x402 if asked',
    description:
      "Fetch a URL. If the server answers 402 Payment Required with an x402 offer, pay it in USDC on Base from this agent's wallet, " +
      "within its owner's limits, and return the response. Where the server offers a session, the agent deposits once and then " +
      'pays each call with a signed voucher, settled on-chain later in one transaction.',
    inputSchema: {
      type: 'object',
      properties: {
        url: { type: 'string', description: 'The http(s) URL to fetch.' },
        method: { type: 'string', enum: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'], description: 'HTTP method. Default GET.' },
        headers: { type: 'object', additionalProperties: { type: 'string' }, description: 'Extra request headers.' },
        body: { type: 'string', description: 'Request body, for POST, PUT and PATCH.' },
        prefer: {
          type: 'string', enum: ['session', 'USDC'], description: 'Which payment to use when the server offers both. Default session.',
        },
      },
      required: ['url'],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  {
    name: 'x402_fund',
    title: 'Add money to the wallet',
    description:
      'Add money to this agent\'s wallet, straight to its address on Base, the way the owner picks: "mpesa" (an M-Pesa prompt ' +
      'on their phone; needs their Kenyan number, the name on the account and an amount in KES), "card" (a card checkout ' +
      'link; same details), "yellowcard" (Yellow Card\'s checkout) or "metamask" (one-tap links from a MetaMask wallet). ' +
      'Ask the owner which before calling it; never call it without them asking to add money.',
    inputSchema: {
      type: 'object',
      properties: {
        method: { type: 'string', enum: ['mpesa', 'card', 'yellowcard', 'metamask'], description: 'How the owner pays.' },
        amount_kes: { type: 'number', description: 'For mpesa and card: the amount in Kenyan shillings.' },
        amount_usd: { type: 'number', description: 'For metamask: the amount in US dollars (default: what the budget still allows).' },
        phone: { type: 'string', description: 'For mpesa and card: the owner\'s Kenyan mobile number.' },
        name: { type: 'string', description: 'For mpesa and card: the name on the M-Pesa or card account.' },
      },
      required: ['method'],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  {
    name: 'x402_discover',
    title: 'Find paid APIs',
    description:
      'Search the x402 Bazaar, the public directory of APIs that agents can pay per call, for services matching a need ' +
      '(for example "flight prices", "web search", "weather"). Returns each API\'s URL, price per call in USDC on Base, how ' +
      'much it is used, and, when the server publishes it, an example of the inputs it needs. Free: nothing is paid.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'What the API should do, in a few words.' },
        max_price_usd: { type: 'number', description: "Highest price per call to show. Default: the owner's per-call limit." },
        limit: { type: 'number', description: 'How many results, 1 to 20. Default 8.' },
      },
      required: ['query'],
    },
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
  {
    name: 'x402_wallet',
    title: 'Show the x402 wallet',
    description:
      "Show this agent's x402 wallet: its address on Base, its USDC balance, its spending limits, what it has spent, its open " +
      'sessions, and one-tap links to fund it. Balances change: call it again for a fresh reading, never answer from an earlier one.',
    inputSchema: { type: 'object', properties: {} },
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
];

function wallet() {
  mkdirSync(HOME, { recursive: true, mode: 0o700 });
  const path = join(HOME, 'agent.key');
  if (!existsSync(path)) writeFileSync(path, `${newKey()}\n`, { mode: 0o600, flag: 'wx' });
  chmodSync(path, 0o600);
  return { kind: 'key', path, address: addressOfKey(readFileSync(path, 'utf8').trim()) };
}

const policy = {
  budget: dollars('AGENT_BUDGET', '1'),
  maxPerRequest: dollars('AGENT_MAX_PER_REQUEST', '0.10'),
  sessionDeposit: dollars('AGENT_SESSION_DEPOSIT', '0.20'),
  approvalMax: dollars('AGENT_APPROVAL_MAX', '5'),
};
const hardening = { ...env };
for (const k of ['AGENT_TIMEOUT_S', 'AGENT_MAX_UNDELIVERED', 'AGENT_BREAKER_SECONDS']) {
  try {
    policyFromEnv({ [k]: env[k] });
  } catch (e) {
    problems.push(`${e.message}, so its default applies`);
    delete hardening[k];
  }
}
for (const k of ['AGENT_MAX_PER_MINUTE', 'AGENT_MAX_PER_DAY', 'AGENT_MAX_PER_WEEK', 'AGENT_MAX_PER_MONTH', 'AGENT_APPROVAL_MAX']) delete hardening[k];
Object.assign(policy, { ...policyFromEnv(hardening), approvalMax: policy.approvalMax });
if (env.AGENT_MAX_PER_MINUTE) policy.maxPerMinute = dollars('AGENT_MAX_PER_MINUTE', '0');
if (env.AGENT_MAX_PER_DAY) policy.maxPerDay = dollars('AGENT_MAX_PER_DAY', '0');
if (env.AGENT_MAX_PER_WEEK) policy.maxPerWeek = dollars('AGENT_MAX_PER_WEEK', '0');
if (env.AGENT_MAX_PER_MONTH) policy.maxPerMonth = dollars('AGENT_MAX_PER_MONTH', '0');
policy.maxPerMinute ??= policy.maxPerRequest * 5n;
const pathId = env.AGENT_PATH && /^0x[0-9a-fA-F]{64}$/.test(env.AGENT_PATH) ? env.AGENT_PATH : undefined;
if (env.AGENT_PATH && !pathId) problems.push(`AGENT_PATH is "${env.AGENT_PATH}", which is not a path id (0x and 64 hex digits), so it is ignored`);
const settingsNote = () => (problems.length ? [`Settings to fix: ${problems.join('; ')}.`] : []);

let agentPromise = null;
function agent() {
  agentPromise ??= createAgent({
    rpcUrl: env.RPC_URL || DEFAULT_RPC,
    signer: wallet(),
    ledgerFile: env.AGENT_LEDGER || join(HOME, 'ledger.json'),
    path: pathId,
    policy,
    userAgent: `x402-sessions/${VERSION} (+https://www.npmjs.com/package/@pyzratio/x402-sessions)`,
  }).catch((e) => {
    agentPromise = null;
    throw e;
  });
  return agentPromise;
}

const reason = (e) => (e?.code === 'RPC_UNREACHABLE' ? `could not reach Base right now (${e.message})` : e?.message ?? String(e));

function fundingLines(a, want) {
  if (a.path) return [`Payments come from path ${a.path}, which its owner funds and can recall at any time.`];
  const lines = [`To fund it, send USDC on Base to ${a.address}. It needs no ETH: a payment is a signature, and the seller pays the gas.`];
  if (FUNDING_URL || YELLOWCARD_KEY) lines.push(`Or pay with ${[FUNDING_URL && 'M-Pesa or a card', YELLOWCARD_KEY && 'Yellow Card'].filter(Boolean).join(' or ')}: ask to add money (x402_fund), and it lands here directly.`);
  const usdc = a.deployment?.addresses?.usdc;
  const chainId = Number(a.deployment?.chainId);
  if (usdc && chainId && want > 0n) {
    const dollarsWanted = Math.max(1, Math.ceil(Number(want) / 1e6));
    lines.push(
      `One tap with MetaMask (a filled-in send of ${usd(want)} USDC on Base, to confirm in the app): `
        + `https://link.metamask.io/send/${usdc}@${chainId}/transfer?address=${a.address}&uint256=${want}`,
      `No USDC yet? Pay by card, or a local method where MetaMask offers one, in MetaMask's Buy (USDC on Base, $${dollarsWanted} filled in): `
        + `https://link.metamask.io/buy?chainId=${chainId}&address=${usdc}&amount=${dollarsWanted} then use the one-tap link above.`,
      `Any other wallet can scan this payment request: ethereum:${usdc}@${chainId}/transfer?address=${a.address}&uint256=${want}`,
    );
  }
  return lines;
}
const fundingLine = (a, want = 0n) => fundingLines(a, want).join('\n');
const stamp = () => `Checked ${new Date().toISOString().slice(0, 19).replace('T', ' ')} UTC.`;
const hhmm = (unixSeconds) => `${new Date(Number(unixSeconds) * 1000).toISOString().slice(11, 16)} UTC`;

async function walletText() {
  const w = wallet();
  let a;
  let b;
  let path;
  try {
    a = await agent();
    await a.reconcile();
    b = await a.balances();
    path = await a.pathState();
  } catch (e) {
    return [
      `Address: ${w.address} (Base)`,
      `USDC: unknown: ${reason(e)}. Ask again in a minute.`,
      `Limits: ${usd(policy.budget)} budget; at most ${usd(policy.maxPerRequest)} a call.`,
      ...settingsNote(),
      pathId
        ? `Payments come from path ${pathId}, which its owner funds and can recall at any time.`
        : `To fund it, send USDC on Base to ${w.address}. It needs no ETH: a payment is a signature, and the seller pays the gas.`,
      `The key is in ${w.path}.`,
    ].join('\n');
  }
  const sessions = Object.values(a.sessions());
  const paused = Object.entries(a.breakers()).filter(([, x]) => x.until > Date.now());
  const held = a.ledger().payments.filter((p) => p.pending);
  const heldUsd = held.reduce((s, p) => s + parseUsd(p.usd), 0n);
  const releases = held.reduce((m, p) => (BigInt(p.pending.validBefore) > m ? BigInt(p.pending.validBefore) : m), 0n);
  const room = policy.budget - a.spent;
  const want = room > b.usdc ? room - b.usdc : 0n;
  return [
    `Address: ${a.address} (${a.deployment.network === 'eip155:8453' ? 'Base' : a.deployment.network})`,
    `USDC: ${formatUnits(b.usdc, 6)}`,
    `Spent: ${usd(a.spent)} of a ${usd(policy.budget)} budget; at most ${usd(policy.maxPerRequest)} a call.`,
    ...a.windows().filter((w) => w.name !== 'minute').map((w) => `Signed ${w.what}: ${usd(w.spent)} of a ${usd(w.cap)} ${w.name} cap.`),
    `Most it can move from here without you: ${usd(room > 0n ? (room < b.usdc ? room : b.usdc) : 0n)} (the smaller of the balance and the budget left). `
      + (clientCaps?.elicitation
        ? `Past a limit, it asks you to approve each payment (at most ${usd(policy.approvalMax)}); the agent cannot approve itself.`
        : 'This client cannot ask you to approve a payment past a limit, so none is made.'),
    ...(heldUsd > 0n
      ? [`Of that, ${usd(heldUsd)} is signed but not collected by the server (the balance above still holds it); it is released by ${hhmm(releases)} if never used.`]
      : []),
    ...settingsNote(),
    ...(path ? [
      `Path: it can still pay out at most ${usd(path.canStillPay)}; ${usd(path.committed)} committed of ${usd(path.bound)}.`,
      ...(path.merchants.length
        ? [`Per merchant, at most still: ${path.merchants.map((m) => `${m.payee} ${usd(m.remaining)} (cap ${usd(m.cap)})`).join('; ')}`]
        : []),
    ] : []),
    ...(paused.length ? [`Paused merchants (paid, did not serve): ${paused.map(([k, x]) => `${k} until ${new Date(x.until).toISOString()}`).join('; ')}`] : []),
    sessions.length
      ? `Open sessions: ${sessions.map((s) => `${s.payee} (${usd(BigInt(s.cumulative))} used of ${usd(BigInt(s.deposit))})`).join('; ')}`
      : 'Open sessions: none.',
    ...fundingLines(a, want),
    `The key is in ${join(HOME, 'agent.key')}.`,
    stamp(),
  ].join('\n');
}

async function fetchText({ url, method = 'GET', headers = {}, body, prefer = 'session' }) {
  if (!/^https?:\/\//i.test(String(url ?? ''))) throw new Error('url must start with http:// or https://');
  const a = await agent();
  const before = a.spent;
  const r = await a.pay(String(url), {
    prefer, method: String(method).toUpperCase(), headers: Object.fromEntries(Object.entries(headers ?? {}).map(([k, v]) => [k, String(v)])),
    body: body === undefined ? undefined : String(body),
    approve: clientCaps?.elicitation ? (q) => approve({ ...q, url }) : undefined,
  });
  const cost = r.charged ?? a.spent - before;
  const head = [r.status === 0 ? 'no answer' : `HTTP ${r.status}`];
  if (r.approved) head.push(`approved by the owner past this limit: ${r.approved}`);
  if (r.paid) {
    head.push(`paid ${usd(cost)} by ${r.mode === 'USDC' ? 'a USDC transfer' : r.mode}${r.mode !== 'session' && !r.settlement ? ' (the server sent no settlement receipt)' : ''}`);
    if (r.simulated) head.push('simulated against the USDC contract before it was sent');
    if (r.settlement?.transaction) head.push(`transaction ${r.settlement.transaction}`);
  }
  const undelivered = !r.delivered && r.charged > 0n;
  const auth = r.paymentPayload?.payload?.authorization;
  const collected = r.settlement?.success === true;
  if (undelivered && auth && !collected) {
    head.push(`not served, and the ${usd(r.charged)} payment was signed but not collected: the server did not settle it, `
      + `so it stays counted until ${hhmm(auth.validBefore)} and is released then if unused`);
  } else if (undelivered) head.push(`charged ${usd(r.charged)}, not delivered`);
  if (r.paid || r.mode) head.push(`spent ${usd(a.spent)} of ${usd(policy.budget)}`);
  if (r.error) head.push(`${r.status === 402 ? 'payment refused' : 'error'}: ${r.error}`);
  if (undelivered && r.status >= 400 && r.status < 500 && r.status !== 402) {
    head.push('the server rejected the request itself: fix the request (see its answer below) before paying again');
  } else if (undelivered) head.push('do not retry this URL now: the merchant was paid and did not serve the call');
  const text = String(r.body ?? '');
  const shown = text.length > MAX_BODY ? `${text.slice(0, MAX_BODY)}\n[... ${text.length - MAX_BODY} more characters]` : text;
  return { text: `${head.join(', ')}\n\n${shown}`, isError: (r.status === 402 && !r.paid) || undelivered };
}

const DISCOVERY = env.X402_DISCOVERY_URL || 'https://api.cdp.coinbase.com/platform/v2/x402/discovery/search';
const FUNDING_URL = (env.X402_FUNDING_URL || '').replace(/\/$/, '');
const YELLOWCARD_KEY = env.X402_YELLOWCARD_KEY || '';
const BASE_USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const fundingMethods = () => ['metamask', ...(FUNDING_URL ? ['mpesa', 'card'] : []), ...(YELLOWCARD_KEY ? ['yellowcard'] : [])];

async function fundText({ method, amount_kes: kes, amount_usd: usdAmount, phone, name }) {
  const w = wallet();
  if (pathId) return `Payments come from path ${pathId}: its owner funds the path, not this wallet.`;
  const offered = fundingMethods();
  if (!offered.includes(method)) {
    return `"${method}" is not set up in this installation. Ways to add money here: ${offered.join(', ')}.`;
  }
  if (method === 'metamask') {
    const want = usdAmount !== undefined && Number(usdAmount) > 0 ? parseUsd(Number(usdAmount).toFixed(6)) : policy.budget;
    const a = { address: w.address, deployment: { chainId: 8453, addresses: { usdc: BASE_USDC } } };
    return fundingLines(a, want).join('\n');
  }
  if (method === 'yellowcard') {
    return [
      `Yellow Card checkout: https://widget.yellowcard.io/landing/${encodeURIComponent(YELLOWCARD_KEY)}`,
      `Choose USDC on the Base network, pay with M-Pesa, bank or card, and send it to this wallet: ${w.address}`,
    ].join('\n');
  }
  const res = await fetch(`${FUNDING_URL}/fund`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'user-agent': `x402-sessions/${VERSION}` },
    body: JSON.stringify({ method, phone, name, amount: kes, address: w.address }), signal: AbortSignal.timeout(40_000),
  });
  const out = await res.json().catch(() => ({}));
  if (!out?.ok) throw new Error(out?.message || `the funding service answered HTTP ${res.status}`);
  return `${out.message}\nAsk "Show my x402 wallet" in a minute or two to see it arrive.`;
}

async function discoverText({ query, max_price_usd: maxPrice, limit = 8 }) {
  const q = String(query ?? '').trim().slice(0, 400);
  if (!q) throw new Error('query is required: say what the API should do');
  const cap = maxPrice !== undefined && Number.isFinite(Number(maxPrice)) && Number(maxPrice) >= 0
    ? Number(maxPrice).toFixed(6) : formatUnits(policy.maxPerRequest, 6);
  const n = Math.max(1, Math.min(20, Math.floor(Number(limit) || 8)));
  const url = `${DISCOVERY}?${new URLSearchParams({ query: q, network: 'eip155:8453', maxUsdPrice: cap, limit: String(n) })}`;
  const res = await fetch(url, {
    headers: { accept: 'application/json', 'user-agent': `x402-sessions/${VERSION}` }, signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new Error(`the x402 Bazaar answered HTTP ${res.status}; try again shortly`);
  const body = await res.json();
  const items = Array.isArray(body?.resources) ? body.resources : Array.isArray(body?.items) ? body.items : [];
  const usdcBase = (r) => (r?.network === 'eip155:8453' || r?.network === 'base')
    && String(r?.asset ?? '').toLowerCase() === '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913';
  const rows = [];
  for (const it of items) {
    const offer = (Array.isArray(it?.accepts) ? it.accepts : []).find(usdcBase);
    if (!offer || !/^https?:\/\//i.test(String(it.resource ?? ''))) continue;
    const price = BigInt(String(offer.amount ?? offer.maxAmountRequired ?? '0').replace(/\D/g, '') || '0');
    const example = it.extensions?.bazaar?.info?.input?.queryParams;
    const callAs = example && typeof example === 'object' && Object.keys(example).length
      ? `${it.resource}${it.resource.includes('?') ? '&' : '?'}${new URLSearchParams(example)}` : it.resource;
    const used = it.quality?.l30DaysTotalCalls !== undefined
      ? `; ${it.quality.l30DaysTotalCalls} paid calls from ${it.quality.l30DaysUniquePayers ?? '?'} payers in 30 days` : '';
    rows.push(`${rows.length + 1}. ${it.serviceName || new URL(it.resource).hostname}: ${usd(price)} a call${used}\n`
      + `   ${String(it.description ?? '').replace(/\s+/g, ' ').slice(0, 200)}\n   Call: ${callAs}`);
  }
  if (!rows.length) return `No paid API on the x402 Bazaar matched "${q}" at or under $${cap} a call in USDC on Base.`;
  return [`Paid APIs for "${q}" (x402 Bazaar, USDC on Base, at most $${cap} a call). Nothing was paid to search.`, '', ...rows,
    '', 'To use one, call x402_fetch with its URL; fill in the inputs it needs first.'].join('\n');
}

async function callTool(name, args) {
  try {
    if (name === 'x402_discover') return { content: [{ type: 'text', text: await discoverText(args ?? {}) }] };
    if (name === 'x402_fund') return { content: [{ type: 'text', text: await fundText(args ?? {}) }] };
    if (name === 'x402_wallet') return { content: [{ type: 'text', text: await walletText() }] };
    if (name === 'x402_fetch') {
      const { text, isError } = await fetchText(args ?? {});
      return { content: [{ type: 'text', text }], isError };
    }
    return { content: [{ type: 'text', text: `unknown tool ${name}` }], isError: true };
  } catch (e) {
    let text = e instanceof PolicyError
      ? `Not paid: ${e.message}. The owner sets the limits (budget, per call, per minute, day, week and month caps).`
      : e?.name === 'TimeoutError' ? 'Error: the server did not answer in time. Nothing was paid; the call may be tried again.'
        : `Error: ${reason(e)}.${name === 'x402_fetch' ? ' Nothing was paid.' : ''}`;
    if (problems.length) text += `\n${settingsNote()[0]}`;
    if (/insufficient|balance|exceeds/i.test(e.message) && agentPromise) {
      try {
        const ag = await agentPromise;
        text += `\n${fundingLine(ag, policy.budget > ag.spent ? policy.budget - ag.spent : 0n)}`;
      } catch {
      }
    }
    return { content: [{ type: 'text', text }], isError: true };
  }
}

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);

let clientCaps = {};
const asked = new Map();
let askId = 0;
function ask(method, params, timeoutMs) {
  const id = `x402-${++askId}`;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      asked.delete(id);
      resolve({ timedOut: true });
    }, timeoutMs);
    asked.set(id, (m) => {
      clearTimeout(timer);
      asked.delete(id);
      resolve(m);
    });
    send({ jsonrpc: '2.0', id, method, params });
  });
}

const APPROVAL_SECONDS = 110;
async function approve({ usd: amount, payTo, reason: why, url }) {
  const host = (() => {
    try {
      return new URL(url).host;
    } catch {
      return String(url ?? '');
    }
  })();
  const answer = await ask('elicitation/create', {
    message: `x402: approve one payment past your limit?\n\n${usd(amount)} USDC on Base to ${host} (pays ${payTo}).\nLimit reached: ${why}.\n\n`
      + `Only you can approve this; the agent cannot. It is declined after ${APPROVAL_SECONDS} seconds without an answer.`,
    requestedSchema: {
      type: 'object',
      properties: { approve: { type: 'boolean', title: `Pay ${usd(amount)} this once`, description: 'Approve this one payment.' } },
      required: ['approve'],
    },
  }, APPROVAL_SECONDS * 1000);
  return answer?.result?.action === 'accept' && answer.result.content?.approve === true;
}

async function handle(m) {
  if (m && typeof m === 'object' && typeof m.method !== 'string' && asked.has(m.id)) return asked.get(m.id)(m);
  if (!m || typeof m !== 'object' || typeof m.method !== 'string') return;
  const { id, method, params } = m;
  const isRequest = id !== undefined && id !== null;
  const reply = (result) => isRequest && send({ jsonrpc: '2.0', id, result });
  switch (method) {
    case 'initialize':
      clientCaps = params?.capabilities ?? {};
      return reply({
        protocolVersion: PROTOCOLS.includes(params?.protocolVersion) ? params.protocolVersion : PROTOCOLS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'x402-sessions', title: 'x402 payments', version: VERSION },
        instructions: INSTRUCTIONS,
      });
    case 'ping':
      return reply({});
    case 'tools/list':
      return reply({ tools: TOOLS });
    case 'tools/call':
      return reply(await callTool(params?.name, params?.arguments));
    default:
      if (isRequest) send({ jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } });
  }
}

export function serve(input = process.stdin) {
  const lines = createInterface({ input, crlfDelay: Infinity });
  lines.on('line', (line) => {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } });
      return;
    }
    for (const m of Array.isArray(message) ? message : [message]) {
      handle(m).catch((e) => {
        if (m?.id !== undefined && m?.id !== null) send({ jsonrpc: '2.0', id: m.id, error: { code: -32603, message: e.message } });
      });
    }
  });
  return lines;
}

if (isMain(import.meta.url)) serve();

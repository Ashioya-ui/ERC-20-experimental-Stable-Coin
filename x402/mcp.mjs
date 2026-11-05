#!/usr/bin/env node
// x402 payments for any agent: an MCP server (Model Context Protocol, stdio) that Claude, Cursor,
// VS Code and any other MCP client can add with one line. It needs Node.js and nothing else. The
// first time it is used it makes the agent a wallet on Base; every payment then stays inside the
// limits its owner set.
//
//   npx -y @pyzratio/x402-sessions
//
// Settings, all optional, from the environment:
//   AGENT_BUDGET           the most the agent may spend in total, in dollars (default 1)
//   AGENT_MAX_PER_REQUEST  the most one call may cost, in dollars (default 0.10)
//   AGENT_SESSION_DEPOSIT  what a session escrows when it opens, in dollars (default 0.20)
//   AGENT_PATH             an X402SessionPaths path id, when an owner holds the money instead
//   RPC_URL                Base JSON-RPC endpoints, comma-separated (default: two public ones)
//   X402_HOME              where the wallet key and the spending ledger live (default ~/.x402-sessions)
//   AGENT_TIMEOUT_S        the longest one paid request may take (default 30)
//   AGENT_MAX_PER_MINUTE   the most the agent may spend in any minute, in dollars (default: 5 calls'
//                          worth, five times AGENT_MAX_PER_REQUEST)
//   AGENT_MAX_UNDELIVERED  paid calls in a row a merchant may leave unserved before it is paused (2)
//   AGENT_MAX_PER_DAY, AGENT_MAX_PER_WEEK, AGENT_MAX_PER_MONTH  the most signed in any 24 hours, 7 days
//                          or 30 days, in dollars (no cap unless set)
//   AGENT_APPROVAL_MAX     the most one payment past a limit may be when the owner approves it (default 5)
//   X402_DISCOVERY_URL     the x402 Bazaar search x402_discover uses (default: Coinbase's public one)
//   AGENT_PATH_MERCHANTS   the path's merchants, comma-separated, to show what each can still receive

// stdout carries the protocol and nothing else; anything printed goes to stderr.
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

// Settings arrive as environment variables from many hosts. A host that has no value for an
// optional setting may pass an empty string, "undefined", "null" or its own unreplaced template
// (Claude Desktop's ${user_config.x}); each of those means "not set".
const env = Object.fromEntries(
  Object.entries(process.env)
    .map(([k, v]) => [k, String(v ?? '').trim()])
    .filter(([, v]) => v !== '' && v !== 'undefined' && v !== 'null' && !/^\$\{[^}]*\}$/.test(v)),
);
const HOME = env.X402_HOME || join(homedir(), '.x402-sessions');
const usd = (units) => `$${formatUnits(units, 6)}`;

// A setting that cannot be read never stops the server: it is reported in every answer, and the
// limit it was meant to set pays nothing until it is fixed.
const problems = [];
/** A dollar setting: "1", "0.10", "$2", "1e-3" (rounded to the cent's ten-thousandth, 6 decimals). */
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

/** The agent's key file, made on first use (0600, in a 0700 directory). */
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
  approvalMax: dollars('AGENT_APPROVAL_MAX', '5'), // the most one owner-approved payment may be
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
for (const k of ['AGENT_MAX_PER_MINUTE', 'AGENT_MAX_PER_DAY', 'AGENT_MAX_PER_WEEK', 'AGENT_MAX_PER_MONTH', 'AGENT_APPROVAL_MAX']) delete hardening[k]; // dollar settings, read below
Object.assign(policy, { ...policyFromEnv(hardening), approvalMax: policy.approvalMax });
if (env.AGENT_MAX_PER_MINUTE) policy.maxPerMinute = dollars('AGENT_MAX_PER_MINUTE', '0');
if (env.AGENT_MAX_PER_DAY) policy.maxPerDay = dollars('AGENT_MAX_PER_DAY', '0');
if (env.AGENT_MAX_PER_WEEK) policy.maxPerWeek = dollars('AGENT_MAX_PER_WEEK', '0');
if (env.AGENT_MAX_PER_MONTH) policy.maxPerMonth = dollars('AGENT_MAX_PER_MONTH', '0');
policy.maxPerMinute ??= policy.maxPerRequest * 5n; // a loop of failing calls cannot drain the budget in seconds
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
    agentPromise = null; // a failed start (an RPC down) is tried again on the next call
    throw e;
  });
  return agentPromise;
}

/** "could not reach Base" for an RPC failure, the message itself otherwise. */
const reason = (e) => (e?.code === 'RPC_UNREACHABLE' ? `could not reach Base right now (${e.message})` : e?.message ?? String(e));

/**
 * How to fund the wallet, shortest first. `want` is what to suggest sending (USDC units): a
 * filled-in MetaMask send (one tap on a phone; a QR code from a desktop browser), and the same
 * payment request as an EIP-681 link any wallet can scan.
 */
function fundingLines(a, want) {
  if (a.path) return [`Payments come from path ${a.path}, which its owner funds and can recall at any time.`];
  const lines = [`To fund it, send USDC on Base to ${a.address}. It needs no ETH: a payment is a signature, and the seller pays the gas.`];
  const usdc = a.deployment?.addresses?.usdc;
  const chainId = Number(a.deployment?.chainId);
  if (usdc && chainId && want > 0n) {
    const dollarsWanted = Math.max(1, Math.ceil(Number(want) / 1e6)); // the on-ramp takes whole dollars
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
  // The address comes from the key file alone, so it is always shown, even when Base cannot be read.
  const w = wallet();
  let a;
  let b;
  let path;
  try {
    a = await agent();
    await a.reconcile(); // payments that expired unused stop counting against the budget
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
  // Signed payments the server has not collected: they count until they expire unused.
  const held = a.ledger().payments.filter((p) => p.pending);
  const heldUsd = held.reduce((s, p) => s + parseUsd(p.usd), 0n);
  const releases = held.reduce((m, p) => (BigInt(p.pending.validBefore) > m ? BigInt(p.pending.validBefore) : m), 0n);
  // Suggest topping the wallet up to what the budget still allows.
  const room = policy.budget - a.spent;
  const want = room > b.usdc ? room - b.usdc : 0n;
  return [
    `Address: ${a.address} (${a.deployment.network === 'eip155:8453' ? 'Base' : a.deployment.network})`,
    `USDC: ${formatUnits(b.usdc, 6)}`,
    `Spent: ${usd(a.spent)} of a ${usd(policy.budget)} budget; at most ${usd(policy.maxPerRequest)} a call.`,
    ...a.windows().filter((w) => w.name !== 'minute').map((w) => `Signed ${w.what}: ${usd(w.spent)} of a ${usd(w.cap)} ${w.name} cap.`),
    // The proved ceiling (docs/design/agent-limits.md): the most this agent can still move on its own.
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
    // Owner approval past a limit, where the client can ask its user (MCP elicitation).
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
  // A one-off payment the server did not settle has not left the wallet: it is held until it expires.
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

/** Paid APIs from the x402 Bazaar that this wallet can pay: USDC on Base, within the per-call limit. */
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
        // the funding hint is best effort
      }
    }
    return { content: [{ type: 'text', text }], isError: true };
  }
}

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);

// Requests this server sends the client (elicitation), by id, until the client answers.
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

/**
 * One-tap owner approval of a payment past a limit the owner set, through the MCP client's own
 * prompt (elicitation). The client shows it to the person, not to the model, so the agent cannot
 * approve itself. No answer within APPROVAL_SECONDS is a refusal.
 */
const APPROVAL_SECONDS = 110; // under the wallet lock's 120 s wait, so other windows are not starved
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
  if (m && typeof m === 'object' && typeof m.method !== 'string' && asked.has(m.id)) return asked.get(m.id)(m); // an answer to our request
  if (!m || typeof m !== 'object' || typeof m.method !== 'string') return; // responses and junk
  const { id, method, params } = m;
  const isRequest = id !== undefined && id !== null;
  const reply = (result) => isRequest && send({ jsonrpc: '2.0', id, result });
  switch (method) {
    case 'initialize':
      clientCaps = params?.capabilities ?? {};
      return reply({
        // The client's version when this server speaks it, otherwise the latest this server speaks (MCP lifecycle rule).
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

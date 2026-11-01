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

// stdout carries the protocol and nothing else; anything printed goes to stderr.
console.log = console.info = console.debug = (...a) => console.error(...a);

import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { createAgent, formatUnits, parseUsd, PolicyError } from './agent.mjs';
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

const env = process.env;
const HOME = env.X402_HOME || join(homedir(), '.x402-sessions');
const usd = (units) => `$${formatUnits(units, 6)}`;

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
    name: 'x402_wallet',
    title: 'Show the x402 wallet',
    description:
      "Show this agent's x402 wallet: its address on Base, its USDC balance, its spending limits, what it has spent, and its open " +
      'sessions. To fund it, send USDC on Base to the address.',
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
  budget: parseUsd(env.AGENT_BUDGET || '1'),
  maxPerRequest: parseUsd(env.AGENT_MAX_PER_REQUEST || '0.10'),
  sessionDeposit: parseUsd(env.AGENT_SESSION_DEPOSIT || '0.20'),
};

let agentPromise = null;
function agent() {
  agentPromise ??= createAgent({
    rpcUrl: env.RPC_URL || DEFAULT_RPC,
    signer: wallet(),
    ledgerFile: env.AGENT_LEDGER || join(HOME, 'ledger.json'),
    path: env.AGENT_PATH || undefined,
    policy,
  }).catch((e) => {
    agentPromise = null; // a failed start (an RPC down) is tried again on the next call
    throw e;
  });
  return agentPromise;
}

function fundingLine(a) {
  return a.path
    ? `Payments come from path ${a.path}, which its owner funds and can recall at any time.`
    : `To fund it, send USDC on Base to ${a.address}. It needs no ETH: a payment is a signature, and the seller pays the gas.`;
}

async function walletText() {
  const a = await agent();
  const b = await a.balances();
  const sessions = Object.values(a.sessions());
  return [
    `Address: ${a.address} (${a.deployment.network === 'eip155:8453' ? 'Base' : a.deployment.network})`,
    `USDC: ${formatUnits(b.usdc, 6)}`,
    `Spent: ${usd(a.spent)} of a ${usd(policy.budget)} budget; at most ${usd(policy.maxPerRequest)} a call.`,
    sessions.length
      ? `Open sessions: ${sessions.map((s) => `${s.payee} (${usd(BigInt(s.cumulative))} used of ${usd(BigInt(s.deposit))})`).join('; ')}`
      : 'Open sessions: none.',
    fundingLine(a),
    `The key is in ${join(HOME, 'agent.key')}.`,
  ].join('\n');
}

async function fetchText({ url, method = 'GET', headers = {}, body, prefer = 'session' }) {
  if (!/^https?:\/\//i.test(String(url ?? ''))) throw new Error('url must start with http:// or https://');
  const a = await agent();
  const before = a.spent;
  const r = await a.pay(String(url), {
    prefer, method: String(method).toUpperCase(), headers: Object.fromEntries(Object.entries(headers ?? {}).map(([k, v]) => [k, String(v)])),
    body: body === undefined ? undefined : String(body),
  });
  const cost = a.spent - before;
  const head = [`HTTP ${r.status}`];
  if (r.paid) head.push(`paid ${usd(cost)} by ${r.mode === 'USDC' ? 'a USDC transfer' : r.mode}`);
  if (r.paid || r.mode) head.push(`spent ${usd(a.spent)} of ${usd(policy.budget)}`);
  if (r.error) head.push(`payment refused: ${r.error}`);
  const text = String(r.body ?? '');
  const shown = text.length > MAX_BODY ? `${text.slice(0, MAX_BODY)}\n[... ${text.length - MAX_BODY} more characters]` : text;
  return { text: `${head.join(', ')}\n\n${shown}`, isError: r.status === 402 && !r.paid };
}

async function callTool(name, args) {
  try {
    if (name === 'x402_wallet') return { content: [{ type: 'text', text: await walletText() }] };
    if (name === 'x402_fetch') {
      const { text, isError } = await fetchText(args ?? {});
      return { content: [{ type: 'text', text }], isError };
    }
    return { content: [{ type: 'text', text: `unknown tool ${name}` }], isError: true };
  } catch (e) {
    let text = e instanceof PolicyError ? `Not paid: ${e.message}. The owner sets the limits (AGENT_BUDGET, AGENT_MAX_PER_REQUEST).` : `Error: ${e.message}`;
    if (/insufficient|balance|exceeds/i.test(e.message) && agentPromise) {
      try {
        text += `\n${fundingLine(await agentPromise)}`;
      } catch {
        // the funding hint is best effort
      }
    }
    return { content: [{ type: 'text', text }], isError: true };
  }
}

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);

async function handle(m) {
  if (!m || typeof m !== 'object' || typeof m.method !== 'string') return; // responses and junk
  const { id, method, params } = m;
  const isRequest = id !== undefined && id !== null;
  const reply = (result) => isRequest && send({ jsonrpc: '2.0', id, result });
  switch (method) {
    case 'initialize':
      return reply({
        protocolVersion: PROTOCOLS.includes(params?.protocolVersion) ? params.protocolVersion : PROTOCOLS[1],
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

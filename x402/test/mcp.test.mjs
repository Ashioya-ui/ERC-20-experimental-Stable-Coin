
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { available, setup, RPC } from './helpers.mjs';

const SERVER = fileURLToPath(new URL('../mcp.mjs', import.meta.url));

function client(env) {
  const child = spawn(process.execPath, [SERVER], { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'inherit'] });
  const pending = new Map();
  let buffer = '';
  let id = 0;
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    for (let i = buffer.indexOf('\n'); i >= 0; i = buffer.indexOf('\n')) {
      const message = JSON.parse(buffer.slice(0, i));
      buffer = buffer.slice(i + 1);
      pending.get(message.id)?.(message);
      pending.delete(message.id);
    }
  });
  const write = (m) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...m })}\n`);
  const request = (method, params) => new Promise((resolve) => {
    const n = ++id;
    pending.set(n, resolve);
    write({ id: n, method, params });
  });
  return {
    request,
    notify: (method, params) => write({ method, params }),
    call: async (name, args = {}) => (await request('tools/call', { name, arguments: args })).result,
    close: () => child.kill(),
  };
}

const start = client;

describe('MCP server', () => {
  let c;
  let home;
  before(() => {
    home = mkdtempSync(join(tmpdir(), 'x402-mcp-'));
    c = start({ X402_HOME: home, RPC_URL: 'http://127.0.0.1:9' });
  });
  after(() => c?.close());

  test('initializes and lists its two tools', async () => {
    const init = await c.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' } });
    assert.equal(init.result.protocolVersion, '2025-06-18');
    assert.equal(init.result.serverInfo.name, 'x402-sessions');
    assert.ok(init.result.capabilities.tools);
    c.notify('notifications/initialized');
    const { result } = await c.request('tools/list');
    assert.deepEqual(result.tools.map((t) => t.name).sort(), ['x402_discover', 'x402_fetch', 'x402_fund', 'x402_wallet']);
    for (const t of result.tools) assert.equal(t.inputSchema.type, 'object');
  });

  test('answers unknown methods and bad input as errors, never by exiting', async () => {
    assert.equal((await c.request('resources/list')).error.code, -32601);
    const bad = await c.call('x402_fetch', { url: 'file:///etc/passwd' });
    assert.equal(bad.isError, true);
    assert.match(bad.content[0].text, /http:\/\/ or https:\/\//);
    assert.deepEqual((await c.request('ping')).result, {});
  });

  test('makes its wallet key on first use, readable by its owner only', async () => {
    await c.call('x402_wallet');
    assert.equal(statSync(join(home, 'agent.key')).mode & 0o777, 0o600);
    assert.equal(statSync(home).mode & 0o777, 0o700);
  });
});

const ready = await available();
describe('MCP server on the rail', { skip: ready === true ? false : `no rail at ${RPC} (${ready})` }, () => {
  let w;
  let c;
  before(async () => {
    w = await setup();
    c = start({ X402_HOME: mkdtempSync(join(tmpdir(), 'x402-mcp-')), RPC_URL: RPC, AGENT_MAX_PER_REQUEST: '0.03', AGENT_BUDGET: '0.5' });
    await c.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' } });
  });
  after(async () => {
    c?.close();
    await w?.close();
  });

  test('a wallet the server made, once funded, pays a merchant through x402_fetch', async () => {
    const wallet = await c.call('x402_wallet');
    assert.equal(wallet.isError, undefined, wallet.content[0].text);
    const address = wallet.content[0].text.match(/Address: (0x[0-9a-f]{40})/)[1];
    await w.fundUSDC(address, 1_000_000n);
    const m0 = await w.bal.usdc(w.merchantAddress);
    const r = await c.call('x402_fetch', { url: `${w.merchantUrl}/api/v1/usdc-only`, prefer: 'USDC' });
    assert.equal(r.isError, false, r.content[0].text);
    assert.match(r.content[0].text, /^HTTP 200, paid \$0\.02 by a USDC transfer, simulated against the USDC contract before it was sent, transaction 0x[0-9a-f]{64}, spent \$0\.02 of \$0\.5\n/);
    assert.equal((await w.bal.usdc(w.merchantAddress)) - m0, 20_000n);
    assert.match((await c.call('x402_wallet')).content[0].text, /USDC: 0\.98/);
  });

  test('the owner limits hold: a call over the per-call limit is refused before anything is signed', async () => {
    const r = await c.call('x402_fetch', { url: `${w.merchantUrl}/api/v1/premium`, prefer: 'USDC' });
    assert.equal(r.isError, true);
    assert.match(r.content[0].text, /Not paid/);
  });
});

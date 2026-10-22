#!/usr/bin/env node
// An x402-protected API (resource server), x402 version 2.
//
// Order for a paid request: decode PAYMENT-SIGNATURE -> facilitator /verify -> run the handler ->
// facilitator /settle -> 200 with PAYMENT-RESPONSE. If settlement fails, answer 402 and discard
// the handler's result (PROMPTS.md, Phase 2).
//
// Routes:
//   GET /api/v1/compute     0.005 sUSD, paid in sUSD
//   GET /api/v1/premium     0.05 USDC, paid in USDC or, by an sUSD holder, through the router
//   GET /api/v1/usdc-only   0.02 USDC, plain x402 USDC (what any public facilitator offers)
//   GET /work/<id>          an item of the agent marketplace (MARKET_FILE), priced and paid to
//                           the agent that made it
//   GET /api/v1/race        test only (MERCHANT_TEST_ROUTES=1): the handler empties the payer's
//                           balance before settlement, so settlement fails and the result is
//                           discarded
//
// Env: RPC_URL, FACILITATOR_URL, MERCHANT_PORT (4021), MERCHANT_PAYTO, MARKET_FILE (optional).

import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { cast, first, makeChain } from './lib/cast.mjs';
import { loadDeployment } from './lib/config.mjs';
import { X402_VERSION, HEADER, encode, decode, sameRequirement, sendJson } from './lib/protocol.mjs';

export async function createMerchant({ rpcUrl, facilitatorUrl, payTo, marketFile, testRoutes = false }) {
  const chain = makeChain(rpcUrl);
  const dep = await loadDeployment(chain);
  const A = dep.addresses;

  const sUSD = (amount, to = payTo) => ({
    scheme: 'exact', network: dep.network, amount: String(amount), asset: A.sUSD, payTo: to,
    maxTimeoutSeconds: 60, extra: { ...dep.domains.sUSD },
  });
  const usdc = (amount, { router = true, to = payTo } = {}) => ({
    scheme: 'exact', network: dep.network, amount: String(amount), asset: A.usdc, payTo: to,
    maxTimeoutSeconds: 60,
    extra: { ...dep.domains.usdc, ...(router && A.router ? { spectrumRouter: A.router, payWith: A.sUSD } : {}) },
  });

  const json = (body) => ({ type: 'application/json', body: JSON.stringify(body) });
  const routes = [
    {
      path: '/api/v1/compute', description: 'Compute job, priced in sUSD', mimeType: 'application/json',
      accepts: () => [sUSD('5000000000000000')],
      handler: async () => json({ job: 'compute', result: 6 * 7, servedAt: new Date().toISOString() }),
    },
    {
      path: '/api/v1/premium', description: 'Premium data, priced in USDC; sUSD holders pay through the Spectrum router',
      mimeType: 'application/json',
      accepts: () => [usdc('50000')],
      handler: async () => json({ data: 'premium', price: '0.05 USDC', servedAt: new Date().toISOString() }),
    },
    {
      path: '/api/v1/usdc-only', description: 'Plain x402 USDC, as any public facilitator offers it', mimeType: 'application/json',
      accepts: () => [usdc('20000', { router: false })],
      handler: async () => json({ data: 'usdc-only', servedAt: new Date().toISOString() }),
    },
  ];
  if (testRoutes) {
    routes.push({
      path: '/api/v1/race', description: 'Test: the payer spends its balance before settlement', mimeType: 'application/json',
      accepts: () => [sUSD('5000000000000000')],
      handler: async (payload) => {
        // anvil only: move the payer's whole balance away while the work is being done
        const payer = payload.payload.authorization.from;
        const bal = first(await chain.call(A.sUSD, 'balanceOf(address)(uint256)', [payer]));
        await cast(['rpc', '--rpc-url', rpcUrl, 'anvil_setBalance', payer, '0xde0b6b3a7640000']);
        await cast(['rpc', '--rpc-url', rpcUrl, 'anvil_impersonateAccount', payer]);
        try {
          await chain.send(A.sUSD, 'transfer(address,uint256)', ['0x000000000000000000000000000000000000dEaD', bal], { kind: 'unlocked', address: payer });
        } finally {
          await cast(['rpc', '--rpc-url', rpcUrl, 'anvil_stopImpersonatingAccount', payer]);
        }
        return json({ shouldNotBeDelivered: true });
      },
    });
  }

  function marketRoute(pathname) {
    const m = /^\/work\/([A-Za-z0-9_-]{1,64})$/.exec(pathname);
    if (!m || !marketFile || !existsSync(marketFile)) return null;
    const item = (JSON.parse(readFileSync(marketFile, 'utf8')).items || []).find((i) => i.id === m[1]);
    if (!item) return null;
    const req = item.asset === 'USDC' ? usdc(item.price, { to: item.payTo }) : sUSD(item.price, item.payTo);
    return {
      path: pathname, description: item.title, mimeType: 'text/markdown',
      accepts: () => [req],
      handler: async () => ({ type: 'text/markdown; charset=utf-8', body: readFileSync(item.file, 'utf8') }),
    };
  }

  async function post(path, body) {
    const r = await fetch(`${facilitatorUrl}${path}`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
    });
    return r.json();
  }

  function paymentRequired(res, resource, accepts, error) {
    const required = { x402Version: X402_VERSION, error, resource, accepts };
    return sendJson(res, 402, required, { [HEADER.required]: encode(required) });
  }

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://x');
      if (req.method === 'GET' && url.pathname === '/health') return sendJson(res, 200, { ok: true, network: dep.network });
      const route = routes.find((r) => r.path === url.pathname) || marketRoute(url.pathname);
      if (!route || req.method !== 'GET') return sendJson(res, 404, { error: 'not found' });

      const resource = { url: `http://${req.headers.host}${url.pathname}`, description: route.description, mimeType: route.mimeType };
      const accepts = route.accepts();
      const header = req.headers[HEADER.signature.toLowerCase()];
      if (!header) return paymentRequired(res, resource, accepts, 'payment required');

      let payload;
      try {
        payload = decode(header);
      } catch {
        return paymentRequired(res, resource, accepts, 'invalid PAYMENT-SIGNATURE header');
      }
      const requirement = accepts.find((a) => sameRequirement(a, payload?.accepted));
      if (!requirement) return paymentRequired(res, resource, accepts, 'no matching payment option');

      const body = { x402Version: X402_VERSION, paymentPayload: payload, paymentRequirements: requirement };
      const verified = await post('/verify', body);
      if (!verified.isValid) return paymentRequired(res, resource, accepts, verified.invalidReason || 'payment invalid');

      const result = await route.handler(payload, requirement); // do the work, deliver only if paid
      let settled = await post('/settle', body);
      // Sent but the receipt was lost: /settle is idempotent, so ask again before giving up.
      for (let i = 0; i < 3 && settled.errorReason === 'settlement_unconfirmed'; i++) {
        await new Promise((r) => setTimeout(r, 1000));
        settled = await post('/settle', body);
      }
      if (!settled.success) return paymentRequired(res, resource, accepts, settled.errorReason || 'settlement failed');

      res.writeHead(200, {
        'content-type': result.type,
        [HEADER.response]: encode(settled),
        'access-control-expose-headers': HEADER.response,
      });
      return res.end(result.body);
    } catch (e) {
      // Answering must not throw in turn: an exception escaping this handler is an unhandled
      // rejection, which Node 22 turns into a dead process.
      try {
        if (!res.headersSent) sendJson(res, 500, { error: 'internal error' });
        else if (!res.writableEnded) res.end();
      } catch {
        /* the connection is already gone */
      }
    }
  });

  return { server, deployment: dep };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.MERCHANT_PORT || 4021);
  const m = await createMerchant({
    rpcUrl: process.env.RPC_URL || 'http://127.0.0.1:8545',
    facilitatorUrl: process.env.FACILITATOR_URL || 'http://127.0.0.1:4020',
    payTo: process.env.MERCHANT_PAYTO,
    marketFile: process.env.MARKET_FILE,
    testRoutes: process.env.MERCHANT_TEST_ROUTES === '1',
  });
  m.server.listen(port, '127.0.0.1', () => console.log(`merchant on http://127.0.0.1:${port} (${m.deployment.network})`));
}

// Self-audit probes. Read-only against the live rail; creates no new on-chain state
// beyond the payments it makes. Run: node x402/review/self-audit.mjs
import { createAgent } from '../agent.mjs';
import { HEADER, encode, decode, X402_VERSION } from '../lib/protocol.mjs';
import { readFileSync, writeFileSync } from 'node:fs';

const E = process.env;
const MER = E.MERCHANT_URL, FAC = E.FACILITATOR_URL;
const agent = await createAgent({
  rpcUrl: E.RPC_URL, facilitatorUrl: FAC,
  signer: { kind: 'keystore', path: `${E.X402_WALLETS}/client`, passwordFile: E.AGENT_PASSWORD_FILE },
});
const post = (p, b) => fetch(`${FAC}${p}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b) }).then(r => r.json());
const get = (u, pp) => fetch(u, pp ? { headers: { [HEADER.signature]: encode(pp) } } : undefined);

// A-01 probe: two listings, same price, same payTo, different resource.
const m = JSON.parse(readFileSync(E.MARKET_FILE, 'utf8'));
m.items = m.items.filter(i => !['dup-a', 'dup-b'].includes(i.id));
for (const id of ['dup-a', 'dup-b']) {
  m.items.push({ id, title: `resource ${id}`, price: '2000000', asset: 'USDC',
    payTo: E.MERCHANT, file: `/home/claude/spectrum/x402/review/${id}.txt` });
  writeFileSync(`/home/claude/spectrum/x402/review/${id}.txt`, `SECRET CONTENT OF ${id}\n`);
}
writeFileSync(E.MARKET_FILE, JSON.stringify(m, null, 2));

const req = decode((await get(`${MER}/work/dup-a`)).headers.get(HEADER.required));
const o = await agent.choose(req.accepts);
const payload = await agent.authorize(o);
const pp = { x402Version: X402_VERSION, resource: req.resource, accepted: o.r, payload };

const a = await get(`${MER}/work/dup-a`, pp);
const bodyA = await a.text();
const b = await get(`${MER}/work/dup-b`, pp);   // SAME payload, different resource
const bodyB = await b.text();
const recA = a.headers.get(HEADER.response) ? decode(a.headers.get(HEADER.response)) : null;
const recB = b.headers.get(HEADER.response) ? decode(b.headers.get(HEADER.response)) : null;
console.log('A-01 dup-a :', a.status, JSON.stringify(bodyA.trim()), 'tx', recA?.transaction?.slice(0, 12));
console.log('A-01 dup-b :', b.status, JSON.stringify(bodyB.trim()), 'tx', recB?.transaction?.slice(0, 12));
console.log('A-01 VERDICT:', a.status === 200 && b.status === 200 && recA?.transaction === recB?.transaction
  ? 'BROKEN - two resources delivered, one payment, same tx reused' : 'held');

// A-02 probe: unbounded / malformed maxTimeoutSeconds reaching BigInt()
for (const t of ['abc', 1.5, -1, 99999999999]) {
  const r2 = { ...o.r, maxTimeoutSeconds: t };
  const v = await post('/verify', { x402Version: 2, paymentPayload: { ...pp, accepted: r2 }, paymentRequirements: r2 });
  console.log(`A-02 maxTimeoutSeconds=${JSON.stringify(t)} ->`, JSON.stringify(v).slice(0, 110));
}

// A-03 probe: cast flag injection through validated fields
for (const bad of ['--rpc-url', '-0x1', '--private-key']) {
  const r3 = { ...o.r, payTo: bad };
  const v = await post('/verify', { x402Version: 2, paymentPayload: { ...pp, accepted: r3 }, paymentRequirements: r3 });
  console.log(`A-03 payTo=${bad} ->`, v.invalidReason || JSON.stringify(v).slice(0, 80));
}

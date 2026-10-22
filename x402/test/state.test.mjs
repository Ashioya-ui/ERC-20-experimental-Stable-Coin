// What the facilitator's shared state does when the chain misbehaves.
//
// The facilitator is one long-lived process holding `settled`, `inflight`, `unconfirmed` and a
// send queue across every request from untrusted merchants and payers. These tests drive the
// error paths with a chain stub (test/stub.mjs) and ask the question that matters for a
// long-lived worker: after a request has gone wrong, what does the NEXT request see?

import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { join } from 'node:path';
import net from 'node:net';
import { UnconfirmedError } from '../lib/cast.mjs';
import { stubAvailable, stubFacilitator, rand32, randAddress, NOW } from './stub.mjs';

const ready = await stubAvailable();
const skip = ready === true ? false : `the stub facilitator could not start (${ready})`;

describe('facilitator state across requests', { skip }, () => {
  const made = [];
  const world = async (hooks, options) => {
    const w = await stubFacilitator(hooks, options);
    made.push(w);
    return w;
  };
  after(async () => {
    for (const w of made) await w.close();
  });

  // ------------------------------------------------------------------ 1. a read that throws

  test('a chain read that throws leaves nothing behind, and answers in the protocol, not a 500', async () => {
    let broken = true;
    const w = await world({ timestamp: () => { if (broken) throw new Error('error sending request'); return NOW; } });
    const payer = randAddress();
    const nonce = rand32();
    const b = w.payment({ payer, nonce });

    const v = await w.f.verify(b);
    assert.equal(v.isValid, false);
    assert.equal(v.invalidReason, 'unexpected_verify_error', 'a failed read is not a verdict on the payment');
    assert.equal(v.payer, payer);

    const s = await w.f.settle(b);
    assert.equal(s.success, false);
    assert.equal(s.errorReason, 'unexpected_settle_error');
    assert.equal(s.transaction, '', 'nothing was sent');

    // Nothing of the dead request may outlive it: the key must be forgotten, so the very same
    // authorization still settles once the chain comes back.
    assert.equal(await w.holds(payer, nonce), false, 'the key was left in a shared map');
    broken = false;
    const again = await w.f.settle(b);
    assert.equal(again.success, true, 'the payer was locked out of their own authorization');
  });

  test('the HTTP surface answers 200 with an x402 body when a chain read throws', async () => {
    const w = await world({ timestamp: () => { throw new Error('error sending request'); } });
    const url = await w.listen();
    const post = (path) =>
      fetch(`${url}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(w.payment()) });
    for (const path of ['/verify', '/settle']) {
      const res = await post(path);
      assert.equal(res.status, 200, `${path} leaked a ${res.status}`);
      const body = await res.json();
      assert.ok(body.invalidReason || body.errorReason, `${path} answered ${JSON.stringify(body)}`);
    }
  });

  // ------------------------------------------------------------------ 2. inflight promises

  test('a request joining one in flight never inherits a rejection', async () => {
    let release;
    const held = new Promise((r) => { release = r; });
    const w = await world({ timestamp: async () => { await held; throw new Error('error sending request'); } });
    const payer = randAddress();
    const nonce = rand32();
    const b = w.payment({ payer, nonce });

    const first = w.f.settle(b);
    await new Promise((r) => setImmediate(r)); // let it reach the chain read and park in `inflight`
    const second = w.f.settle(b); // joins the same promise
    release();
    for (const [name, p] of [['first', first], ['second', second]]) {
      const out = await p.then((v) => v, (e) => ({ threw: e.message }));
      assert.equal(out.threw, undefined, `the ${name} caller got a rejection: ${out.threw}`);
      assert.equal(out.success, false);
    }
    assert.equal(await w.holds(payer, nonce), false);
  });

  test('settle never rejects, whatever the chain does', async () => {
    const boom = () => { throw new Error('chain is gone'); };
    const w = await world({ timestamp: boom, bool: boom, uint: boom, call: boom, send: boom, receipt: boom });
    const out = await w.f.settle(w.payment()).then((v) => v, (e) => ({ threw: e.message }));
    assert.equal(out.threw, undefined, 'settle rejected, so `inflight` can hold a rejected promise');
    assert.equal(out.success, false);
  });

  // ------------------------------------------------------------------ 3. unbounded growth

  test('`unconfirmed` is bounded: many lost receipts cannot grow it for ever', async () => {
    let n = 0;
    const w = await world({
      send: () => { throw new UnconfirmedError('0x' + String(++n).padStart(64, '0'), new Error('receipt lost')); },
    });
    const first = { payer: randAddress(), nonce: rand32() };
    assert.equal((await w.f.settle(w.payment(first))).errorReason, 'settlement_unconfirmed');
    assert.equal(await w.holds(first.payer, first.nonce), true, 'the broadcast was not recorded at all');

    for (let i = 0; i < 1_100; i++) await w.f.settle(w.payment());
    assert.equal(
      await w.holds(first.payer, first.nonce),
      false,
      '`unconfirmed` still holds the oldest of 1100 entries: an attacker who can provoke lost receipts grows it without limit',
    );
  });

  // ------------------------------------------------------------------ 4. the send queue

  test('one stuck send does not park every later settlement for ever', async () => {
    let stuck = true;
    const w = await world(
      { send: () => (stuck ? new Promise(() => {}) : { hash: '0x' + 'cd'.repeat(32), ok: true }) },
      { queueWaitMs: 250 },
    );
    w.f.settle(w.payment()).catch(() => {}); // never comes back
    await new Promise((r) => setTimeout(r, 30));
    stuck = false;

    const later = await Promise.race([
      w.f.settle(w.payment()),
      new Promise((r) => setTimeout(() => r({ hung: true }), 3_000)),
    ]);
    assert.equal(later.hung, undefined, 'a later settlement hung behind the stuck one');
    assert.equal(later.success, false);
    assert.equal(later.errorReason, 'settlement_queue_timeout');
    assert.equal(later.transaction, '', 'a settlement that never ran must not claim a transaction');
    assert.equal(w.chain.sends.length, 1, 'the abandoned settlement must not be sent later');
  });

  // ------------------------------------------------------------------ 5. published before commit

  test('an unreadable receipt never drops the record that a transaction was broadcast', async () => {
    // A JSON log line parses into an object with no `status`. Reading that as "the transaction
    // failed" used to delete the `unconfirmed` entry, and the next retry then went through
    // check() and broadcast the same authorization a second time.
    const hash = '0x' + 'ab'.repeat(32);
    let readable = false;
    const w = await world({
      send: () => { throw new UnconfirmedError(hash, new Error('receipt lost')); },
      receipt: async (h) => (readable ? { status: '0x1', transactionHash: h } : { level: 'ERROR', message: 'failed to fetch block' }),
    });
    const payer = randAddress();
    const nonce = rand32();
    const b = w.payment({ payer, nonce });

    assert.equal((await w.f.settle(b)).errorReason, 'settlement_unconfirmed');
    const second = await w.f.settle(b);
    assert.equal(second.errorReason, 'settlement_unconfirmed', 'an unreadable receipt was taken for a failure');
    assert.equal(w.chain.sends.length, 1, 'the same authorization was broadcast twice');
    assert.equal(await w.holds(payer, nonce), true, 'the record of the broadcast was dropped');

    readable = true;
    const third = await w.f.settle(b);
    assert.equal(third.success, true);
    assert.equal(third.transaction, hash, 'the hash of the one transaction that was sent');
    assert.equal(w.chain.sends.length, 1);
  });

  test('a receipt that really says reverted does release the key', async () => {
    const w = await world({
      send: () => { throw new UnconfirmedError('0x' + 'ef'.repeat(32), new Error('receipt lost')); },
      receipt: async (h) => ({ status: '0x0', transactionHash: h }),
    });
    const payer = randAddress();
    const nonce = rand32();
    const b = w.payment({ payer, nonce });
    await w.f.settle(b);
    assert.equal((await w.f.settle(b)).errorReason, 'invalid_transaction_state');
    assert.equal(await w.holds(payer, nonce), false, 'a reverted transaction consumed nothing: the key is free again');
  });

  test('success is only published once the send has committed', async () => {
    const w = await world({ send: () => { throw new Error('execution reverted'); } });
    const payer = randAddress();
    const nonce = rand32();
    const r = await w.f.settle(w.payment({ payer, nonce }));
    assert.equal(r.success, false);
    assert.equal(await w.holds(payer, nonce), false, 'a failed send left a cached answer behind');
  });

  // ------------------------------------------------------------------ 6. staying alive

  test('awkward requests do not take the process down (no handler to hide them)', async () => {
    // In a child, so Node 22's own answer to an unhandled rejection -- ending the process --
    // is what decides this, rather than the test runner's listener.
    const src = `
      import net from 'node:net';
      import { stubFacilitator } from ${JSON.stringify(join(import.meta.dirname, 'stub.mjs'))};
      const w = await stubFacilitator({ send: () => { throw new Error('execution reverted'); } });
      const url = await w.listen();
      const port = Number(url.split(':').pop());
      const body = JSON.stringify(w.payment());
      const raw = (head, tail = '') => new Promise((resolve) => {
        const s = net.connect(port, '127.0.0.1', () => { s.write(head); if (tail) s.write(tail); });
        setTimeout(() => { try { s.resetAndDestroy(); } catch {} resolve(); }, 40);
        s.on('error', () => resolve());
      });
      // a client that vanishes mid-request
      await raw(\`POST /settle HTTP/1.1\\r\\nHost: x\\r\\ncontent-length: \${Buffer.byteLength(body)}\\r\\n\\r\\n\${body}\`);
      // a body over the limit, then one that stops halfway, then odd request targets
      await raw('POST /settle HTTP/1.1\\r\\nHost: x\\r\\ncontent-length: 200000\\r\\n\\r\\n', 'x'.repeat(200000));
      await raw('POST /settle HTTP/1.1\\r\\nHost: x\\r\\ncontent-length: 500\\r\\n\\r\\n{"a":');
      for (const t of ['/settle?a=%zz', '//evil.example/settle', '/%', '*']) {
        await fetch(\`http://127.0.0.1:\${port}\${t}\`).then((r) => r.text()).catch(() => {});
      }
      await fetch(\`http://127.0.0.1:\${port}/settle\`, { method: 'POST', body: 'not json' }).then((r) => r.text()).catch(() => {});
      await new Promise((r) => setTimeout(r, 300));
      await w.close();
      console.log('alive');
    `;
    const out = await new Promise((resolve) => {
      execFile(process.execPath, ['--input-type=module', '-e', src], { cwd: join(import.meta.dirname, '..') },
        (err, stdout, stderr) => resolve({ err, stdout, stderr }));
    });
    assert.equal(out.err, null, `the facilitator died: ${out.stderr}`);
    assert.match(out.stdout, /alive/);
  });

  test('the server keeps serving after an awkward request', async () => {
    const w = await world();
    const url = await w.listen();
    const port = Number(url.split(':').pop());
    await new Promise((resolve) => {
      const s = net.connect(port, '127.0.0.1', () => {
        s.write('POST /settle HTTP/1.1\r\nHost: x\r\ncontent-length: 200000\r\n\r\n');
        s.write('x'.repeat(200_000));
      });
      s.on('close', resolve);
      s.on('error', () => resolve());
      setTimeout(() => { try { s.resetAndDestroy(); } catch { /* gone */ } resolve(); }, 500);
    });
    assert.equal((await (await fetch(`${url}/health`)).json()).ok, true);
    assert.equal((await w.f.settle(w.payment())).success, true);
  });

  // ------------------------------------------------- audit observation 1: oversized body

  test('an oversized body gets a 413, not a reset connection', async () => {
    // readJson used to req.destroy() in the same tick as the rejection, so the handler wrote
    // 413 to a dead socket and the caller saw ECONNRESET -- indistinguishable from the server
    // falling over. The answer must arrive first; the connection closes after it.
    const w = await world();
    const url = await w.listen();
    const port = Number(url.split(':').pop());
    const body = 'x'.repeat(200_000);
    const reply = await new Promise((resolve) => {
      let got = '';
      const s = net.connect(port, '127.0.0.1', () => {
        s.write(`POST /settle HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: ${body.length}\r\n\r\n`);
        s.write(body);
      });
      s.on('data', (d) => { got += d.toString(); });
      s.on('close', () => resolve(got));
      s.on('error', () => resolve(got));
      setTimeout(() => { try { s.destroy(); } catch { /* gone */ } resolve(got); }, 3000);
    });
    assert.match(reply, /^HTTP\/1\.1 413 /, `expected a 413 status line, got: ${JSON.stringify(reply.slice(0, 120))}`);
    assert.match(reply, /body too large/);
    assert.equal((await (await fetch(`${url}/health`)).json()).ok, true, 'and the server is still up');
  });

  // --------------------------------------------- audit observation 2: ambiguous broadcast

  test('a broadcast whose hash we never learned is never reported as unsent, and never retried', async () => {
    // makeChain raises UnconfirmedError with an empty hash when the node may have accepted the
    // transaction before the send call failed. The facilitator must record it and refuse to
    // send again: re-broadcasting the same authorization is the one unacceptable outcome.
    const w = await world({ send: () => { throw new UnconfirmedError('', new Error('connection reset')); } });
    const b = w.payment();
    const first = await w.f.settle(b);
    assert.equal(first.success, false);
    assert.equal(first.errorReason, 'settlement_unconfirmed', 'not a plain failure');

    const before = w.chain.sends.length;
    const again = await w.f.settle(b);
    assert.equal(again.errorReason, 'settlement_unconfirmed');
    assert.equal(w.chain.sends.length, before, 'the retry broadcast nothing');
  });
});

// --------------------------------------- audit observation 2, at the makeChain level

describe('makeChain.send decides sent-or-not from the nonce, not the error', () => {
  const fakeCast = async (script) => {
    const { mkdtemp, writeFile, chmod } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const dir = await mkdtemp(join(tmpdir(), 'fakecast-'));
    const bin = join(dir, 'cast');
    await writeFile(bin, script);
    await chmod(bin, 0o755);
    return bin;
  };
  // cast.mjs reads CAST_BIN once at module load, so each case imports a fresh copy.
  const freshChain = async (bin) => {
    process.env.CAST_BIN = bin;
    const mod = await import(`../lib/cast.mjs?fake=${encodeURIComponent(bin)}`);
    return { makeChain: mod.makeChain, UnconfirmedError: mod.UnconfirmedError };
  };
  const signer = { kind: 'unlocked', address: '0x' + '22'.repeat(20) };

  test('send fails but the nonce advanced: the node took it, so UnconfirmedError', async () => {
    const bin = await fakeCast(`#!/bin/sh
case "$1" in
  nonce)  if [ -f "$TMPDIR_N/bumped" ]; then echo 8; else echo 7; fi ;;
  send)   touch "$TMPDIR_N/bumped"; echo "error sending request for url" >&2; exit 1 ;;
  wallet) echo 0x2222222222222222222222222222222222222222 ;;
  *)      echo 0 ;;
esac
`);
    const { join: j } = await import('node:path');
    const { mkdtemp } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    process.env.TMPDIR_N = await mkdtemp(j(tmpdir(), 'noncestate-'));
    const { makeChain, UnconfirmedError: UE } = await freshChain(bin);
    await assert.rejects(
      makeChain('http://127.0.0.1:1').send('0x' + '33'.repeat(20), 'f()', [], signer),
      (e) => e instanceof UE && e.hash === '',
    );
  });

  test('send fails and the nonce did not move: nothing went out, so a plain failure', async () => {
    const bin = await fakeCast(`#!/bin/sh
case "$1" in
  nonce)  echo 7 ;;
  send)   echo "execution reverted" >&2; exit 1 ;;
  wallet) echo 0x2222222222222222222222222222222222222222 ;;
  *)      echo 0 ;;
esac
`);
    const { makeChain, UnconfirmedError: UE } = await freshChain(bin);
    await assert.rejects(
      makeChain('http://127.0.0.1:1').send('0x' + '33'.repeat(20), 'f()', [], signer),
      (e) => !(e instanceof UE),
    );
  });
});

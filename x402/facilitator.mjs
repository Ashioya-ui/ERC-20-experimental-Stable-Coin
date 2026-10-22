#!/usr/bin/env node
// Spectrum x402 facilitator (x402 version 2, "exact" scheme on EVM).
//
// Three ways to pay, all gasless for the payer (the facilitator submits and pays the gas):
//   sUSD    the requirement's asset is sUSD: an EIP-3009 transferWithAuthorization to payTo.
//   USDC    the requirement's asset is USDC: a standard EIP-3009 USDC authorization (pass-through,
//           so a merchant that switches to this facilitator still takes plain USDC).
//   router  the requirement's asset is USDC but the payer holds sUSD: a receiveWithAuthorization
//           of sUSD to the SpectrumPayRouter whose nonce commits to (payTo, amount, salt). The router
//           redeems, pays the merchant exactly `amount` USDC and returns the change.
// Plus POST /convert (a Spectrum extension): the same router call with payTo = the payer, so an
// agent holding sUSD can get USDC for any merchant on any facilitator.
//
// Every check runs before anything is sent, and the exact transaction is simulated with eth_call
// first. Settlement is idempotent per (payer, nonce), with in-flight locking.
//
// Env: RPC_URL, FACILITATOR_PORT (4020), FACILITATOR_SIGNER (unlocked:<address> on anvil, or
// keystore:<path> with FACILITATOR_PASSWORD_FILE), DEPLOYMENT / ROUTER_DEPLOYMENT (optional).

import http from 'node:http';
import { cast, first, makeChain, parseSigner, signerAddress, UnconfirmedError } from './lib/cast.mjs';
import { loadDeployment } from './lib/config.mjs';
import { X402_VERSION, lc, isAddress, isBytes32, isHex, isUint, readJson, sendJson } from './lib/protocol.mjs';

const SKEW = 6n; // seconds of clock slack allowed beyond maxTimeoutSeconds
// A requirement comes from the resource server, which is not trusted: its maxTimeoutSeconds is
// validated like any other input, and capped, so a hostile or careless merchant cannot talk the
// facilitator into accepting an authorization that stays spendable for days (A-02).
const MAX_TIMEOUT = 3600n;

/** Raised when a settlement waited for its turn in the send queue and never got one. */
class QueueTimeout extends Error {
  constructor(message) {
    super(message);
    this.name = 'QueueTimeout';
  }
}

export async function createFacilitator({ rpcUrl, signer, chain: chainOverride, queueWaitMs }) {
  const chain = chainOverride || makeChain(rpcUrl); // tests may pass a wrapped chain
  // How long a settlement may wait for its turn in the send queue before giving up (see serial).
  const QUEUE_WAIT = Number(queueWaitMs ?? process.env.FACILITATOR_QUEUE_WAIT_MS ?? 120_000);
  const dep = await loadDeployment(chain);
  const A = dep.addresses;
  const from = await signerAddress(signer);

  // Custom-error selectors of the contracts the facilitator calls, mapped to x402 reasons.
  const errors = {};
  const map = {
    'InvalidSignature()': 'invalid_exact_evm_payload_signature',
    'AuthorizationExpired()': 'invalid_exact_evm_payload_authorization_valid_before',
    'AuthorizationNotYetValid()': 'invalid_exact_evm_payload_authorization_valid_after',
    'AuthorizationAlreadyUsed()': 'invalid_exact_evm_payload_authorization_nonce_used',
    'InsufficientBalance()': 'insufficient_funds',
    'InsufficientLiquidity(uint256)': 'spectrum_insufficient_liquidity',
    'AuthorizationTooSmall(uint256,uint256)': 'spectrum_authorization_too_small',
    'InvalidPayTo(address)': 'invalid_pay_to',
    'AmountTooSmall()': 'spectrum_amount_too_small',
    'ReserveFloorBreached(uint256,uint256)': 'spectrum_reserve_floor',
  };
  for (const [sig, reason] of Object.entries(map)) errors[(await cast(['sig', sig])).toLowerCase()] = reason;
  const fiatReasons = [
    [/invalid signature/i, 'invalid_exact_evm_payload_signature'],
    [/authorization is expired/i, 'invalid_exact_evm_payload_authorization_valid_before'],
    [/not yet valid/i, 'invalid_exact_evm_payload_authorization_valid_after'],
    [/used or canceled/i, 'invalid_exact_evm_payload_authorization_nonce_used'],
    [/exceeds balance/i, 'insufficient_funds'],
  ];
  const reasonOf = (e) => {
    const text = `${e?.message || ''}\n${e?.stderr || ''}`;
    for (const [sel, reason] of Object.entries(errors)) if (text.toLowerCase().includes(sel)) return reason;
    for (const [re, reason] of fiatReasons) if (re.test(text)) return reason;
    return null;
  };

  const forbiddenPayTo = new Set([A.sUSD, A.stabilizer, A.treasury, A.router, A.usdc, '0x' + '0'.repeat(40)].filter(Boolean));
  // Idempotency per (payer, nonce). Each entry keeps a fingerprint of the whole request, so a
  // cached success is returned only for the identical request, never for the same
  // authorization presented with other requirements.
  const settled = new Map(); // key -> { fp, result }
  const inflight = new Map(); // key -> { fp, result: Promise }
  const unconfirmed = new Map(); // key -> { fp, hash, payer, at }: sent, receipt not yet read
  const MAX_SETTLED = 10_000;
  // `unconfirmed` grows on an error path, so it needs a bound of its own: an error an untrusted
  // caller can provoke must not be a way to exhaust memory. An entry is only useful while the
  // authorization it covers could still be settled, and check() refuses any validBefore more
  // than MAX_TIMEOUT + SKEW past chain time, so one older than that can no longer let a retry
  // broadcast anything and is safe to forget. The count cap is the backstop for a burst.
  const MAX_UNCONFIRMED = 1_000;
  const UNCONFIRMED_TTL_MS = Number(MAX_TIMEOUT) * 2 * 1000;

  /** Record that `key` was broadcast, dropping entries too old or too many to be worth keeping. */
  const rememberUnconfirmed = (key, entry) => {
    unconfirmed.delete(key); // re-insert, so the map stays in age order
    unconfirmed.set(key, { ...entry, at: Date.now() });
    const cutoff = Date.now() - UNCONFIRMED_TTL_MS;
    for (const [old, v] of unconfirmed) {
      if (old === key) break; // never evict the one just recorded
      if (unconfirmed.size <= MAX_UNCONFIRMED && v.at >= cutoff) break; // Map iterates oldest first
      unconfirmed.delete(old);
    }
  };

  // One transaction at a time from the facilitator's account: no nonce races, and each
  // settlement is simulated again against the state its predecessor left.
  //
  // The queue is shared by every caller, so a send that never comes back would park all of
  // them for ever. A settlement that has waited QUEUE_WAIT for its turn gives up instead --
  // but only while it is still waiting. Once fn has started, a transaction may be in flight
  // and the only honest answer is the one fn produces, however long it takes; cast's own
  // timeout is what bounds that half.
  let queue = Promise.resolve();
  const serial = (fn) => {
    let started = false;
    let abandoned = false;
    const start = () => {
      if (abandoned) return undefined; // its caller is gone: send nothing, let the queue move on
      started = true;
      return fn();
    };
    const run = queue.then(start, start);
    queue = run.catch(() => {});
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (started) return;
        abandoned = true;
        reject(new QueueTimeout('the settlement queue did not come round'));
      }, QUEUE_WAIT);
      run.then(
        (v) => { clearTimeout(timer); if (!abandoned) resolve(v); },
        (e) => { clearTimeout(timer); if (!abandoned) reject(e); },
      );
    });
  };

  const bad = (invalidReason, payer) => ({ isValid: false, invalidReason, ...(payer ? { payer } : {}) });
  // The payer named by a request, for answers produced before check() got far enough to find it.
  const payerOf = (body) => {
    const from = body?.paymentPayload?.payload?.authorization?.from;
    return isAddress(from) ? lc(from) : undefined;
  };
  const fingerprint = (body) => {
    const p = body?.paymentPayload;
    const r = body?.paymentRequirements;
    const a = p?.payload?.authorization || {};
    return JSON.stringify([
      r?.network, lc(r?.asset), lc(r?.payTo), String(r?.amount), lc(a.from), lc(a.to), String(a.value),
      String(a.validAfter), String(a.validBefore), lc(a.nonce), lc(p?.payload?.signature), lc(p?.payload?.spectrum?.salt),
    ]);
  };

  /** Everything /verify checks; on success also returns the exact transaction /settle sends. */
  async function check(body) {
    const { x402Version, paymentPayload: p, paymentRequirements: r } = body ?? {};
    if (x402Version !== X402_VERSION || p?.x402Version !== X402_VERSION) return bad('invalid_x402_version');
    if (r?.scheme !== 'exact' || p?.accepted?.scheme !== 'exact') return bad('unsupported_scheme');
    if (r.network !== dep.network || p.accepted.network !== dep.network) return bad('invalid_network');
    for (const k of ['asset', 'payTo', 'amount']) {
      if (lc(p.accepted[k]) !== lc(r[k])) return bad('invalid_payment_requirements');
    }
    const auth = p.payload?.authorization;
    const signature = p.payload?.signature;
    if (
      !auth || !isAddress(auth.from) || !isAddress(auth.to) || !isUint(auth.value) || !isUint(auth.validAfter) ||
      !isUint(auth.validBefore) || !isBytes32(auth.nonce) || !isHex(signature) || !isAddress(r.payTo) || !isUint(r.amount)
    ) return bad('invalid_payload');
    const payer = lc(auth.from);
    const payTo = lc(r.payTo);
    if (forbiddenPayTo.has(payTo)) return bad('invalid_pay_to', payer);
    if (BigInt(r.amount) === 0n) return bad('invalid_payment_requirements', payer);

    // Chain time, not the server clock: it is the clock the token contract checks. validBefore
    // must leave SKEW seconds for the transaction to land.
    const now = await chain.timestamp();
    if (BigInt(auth.validAfter) > now) return bad('invalid_exact_evm_payload_authorization_valid_after', payer);
    if (!(now + SKEW < BigInt(auth.validBefore))) return bad('invalid_exact_evm_payload_authorization_valid_before', payer);
    const rawTimeout = r.maxTimeoutSeconds ?? 60;
    if (!isUint(rawTimeout)) return bad('invalid_payment_requirements', payer);
    const timeout = BigInt(rawTimeout) > MAX_TIMEOUT ? MAX_TIMEOUT : BigInt(rawTimeout);
    if (BigInt(auth.validBefore) > now + timeout + SKEW) {
      return bad('invalid_exact_evm_payload_authorization_valid_before', payer);
    }

    const asset = lc(r.asset);
    let mode;
    if (asset === A.sUSD) mode = 'sUSD';
    else if (asset === A.usdc) mode = A.router && lc(auth.to) === A.router ? 'router' : 'USDC';
    else return bad('unsupported_asset', payer);

    let tx;
    if (mode === 'sUSD' || mode === 'USDC') {
      const token = mode === 'sUSD' ? A.sUSD : A.usdc;
      if (lc(auth.to) !== payTo) return bad('invalid_exact_evm_payload_recipient_mismatch', payer);
      if (BigInt(auth.value) !== BigInt(r.amount)) return bad('invalid_exact_evm_payload_authorization_value', payer);
      if (await chain.bool(token, 'authorizationState(address,bytes32)(bool)', [auth.from, auth.nonce])) {
        return bad('invalid_exact_evm_payload_authorization_nonce_used', payer);
      }
      if ((await chain.uint(token, 'balanceOf(address)(uint256)', [auth.from])) < BigInt(auth.value)) {
        return bad('insufficient_funds', payer);
      }
      tx = {
        to: token,
        sig: 'transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)',
        args: [auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, signature],
      };
    } else {
      const salt = p.payload?.spectrum?.salt;
      if (!isBytes32(salt)) return bad('invalid_payload', payer);
      const intent = first(await chain.call(A.router, 'intentNonce(address,uint256,bytes32)(bytes32)', [r.payTo, r.amount, salt]));
      if (lc(intent) !== lc(auth.nonce)) return bad('invalid_spectrum_router_intent', payer);
      if (await chain.bool(A.sUSD, 'authorizationState(address,bytes32)(bool)', [auth.from, auth.nonce])) {
        return bad('invalid_exact_evm_payload_authorization_nonce_used', payer);
      }
      const needed = await chain.uint(A.router, 'sUSDFor(uint256)(uint256)', [r.amount]);
      if (BigInt(auth.value) < needed) return bad('spectrum_authorization_too_small', payer);
      if ((await chain.uint(A.sUSD, 'balanceOf(address)(uint256)', [auth.from])) < BigInt(auth.value)) {
        return bad('insufficient_funds', payer);
      }
      tx = {
        to: A.router,
        sig: 'pay(address,uint256,uint256,uint256,address,uint256,bytes32,bytes)',
        args: [auth.from, auth.value, auth.validAfter, auth.validBefore, r.payTo, r.amount, salt, signature],
      };
    }

    // Simulate exactly what /settle would send, from the facilitator's address.
    try {
      await chain.call(tx.to, tx.sig, tx.args, { from });
    } catch (e) {
      return bad(reasonOf(e) || 'unexpected_verify_error', payer);
    }
    return { isValid: true, payer, mode, tx, key: `${payer}:${lc(auth.nonce)}` };
  }

  async function verify(body) {
    let v;
    try {
      v = await check(body);
    } catch (e) {
      // A chain read that threw is not a verdict on the payment. Answering in the protocol's
      // own shape keeps a flaky RPC from looking like a broken facilitator, and -- because
      // settle() shares check() -- keeps a rejected promise out of the in-flight map.
      return bad(reasonOf(e) || 'unexpected_verify_error', payerOf(body));
    }
    return v.isValid ? { isValid: true, payer: v.payer } : v;
  }

  async function settle(body) {
    const auth = body?.paymentPayload?.payload?.authorization;
    const key = auth && isAddress(auth.from) && isBytes32(auth.nonce) ? `${lc(auth.from)}:${lc(auth.nonce)}` : null;
    const fp = fingerprint(body);
    const fail = (errorReason, payer, transaction = '') => ({ success: false, errorReason, payer: payer ?? '', transaction, network: dep.network });
    const prior = key && (settled.get(key) || inflight.get(key) || unconfirmed.get(key));
    if (prior && prior.fp !== fp) {
      // Anything other than the identical request that reuses the authorization is a replay.
      return fail('invalid_exact_evm_payload_authorization_nonce_used', lc(auth.from));
    }
    if (prior && prior.result) return prior.result; // a retry gets the same answer
    const succeed = (payer, transaction) => {
      const response = { success: true, payer, transaction, network: dep.network };
      settled.set(key, { fp, result: response });
      if (settled.size > MAX_SETTLED) settled.delete(settled.keys().next().value);
      return response;
    };
    const work = prior
      ? (async () => {
          // A transaction was sent for this request but its receipt was lost: look again.
          let receipt;
          try {
            receipt = await chain.receipt(prior.hash);
          } catch {
            return fail('settlement_unconfirmed', prior.payer, prior.hash);
          }
          const status = String(receipt?.status ?? '');
          const ok = ['0x1', '1', 'true'].includes(status);
          const reverted = ['0x0', '0', 'false'].includes(status);
          if (!ok && !reverted) {
            // The chain did not say either way. Keep the record of the broadcast: it is the only
            // thing stopping the next retry from running check() and sending the same
            // authorization a second time.
            return fail('settlement_unconfirmed', prior.payer, prior.hash);
          }
          unconfirmed.delete(key);
          return ok ? succeed(prior.payer, prior.hash) : fail('invalid_transaction_state', prior.payer, prior.hash);
        })()
      : (async () => {
          let v;
          try {
            v = await check(body);
          } catch (e) {
            // As in verify(): a read that threw decided nothing, and settle() must not reject,
            // or the promise parked in `inflight` would hand the rejection to every later
            // request that joins it.
            return fail(reasonOf(e) || 'unexpected_settle_error', payerOf(body));
          }
          if (!v.isValid) return fail(v.invalidReason, v.payer);
          try {
            return await serial(async () => {
              try {
                await chain.call(v.tx.to, v.tx.sig, v.tx.args, { from }); // again, against the latest state
              } catch (e) {
                return fail(reasonOf(e) || 'unexpected_settle_error', v.payer);
              }
              try {
                const sent = await chain.send(v.tx.to, v.tx.sig, v.tx.args, signer);
                if (!sent.ok) return fail('invalid_transaction_state', v.payer, sent.hash);
                return succeed(v.payer, sent.hash);
              } catch (e) {
                if (e instanceof UnconfirmedError) {
                  // Sent, outcome unknown: never report it as failed-and-unsent. A retry of the
                  // same request looks the receipt up again.
                  rememberUnconfirmed(key, { fp, hash: e.hash, payer: v.payer });
                  return fail('settlement_unconfirmed', v.payer, e.hash);
                }
                return fail(reasonOf(e) || 'unexpected_settle_error', v.payer);
              }
            });
          } catch (e) {
            // Its turn never came, so nothing was broadcast for it: a plain failure the payer
            // can retry with the same authorization.
            if (e instanceof QueueTimeout) return fail('settlement_queue_timeout', v.payer);
            throw e;
          }
        })();
    if (key) inflight.set(key, { fp, result: work });
    try {
      return await work;
    } finally {
      if (key) inflight.delete(key);
    }
  }

  /** Spectrum extension: convert the payer's own sUSD to USDC through the router (payTo = payer). */
  async function convert(body) {
    const auth = body?.payload?.authorization;
    if (!auth || !isAddress(auth.from) || !isUint(body?.amount)) {
      return { success: false, errorReason: 'invalid_payload', transaction: '', network: dep.network };
    }
    const requirement = {
      scheme: 'exact', network: dep.network, asset: A.usdc, payTo: auth.from, amount: String(body.amount),
      maxTimeoutSeconds: Number(body.maxTimeoutSeconds ?? 120),
    };
    return settle({
      x402Version: X402_VERSION,
      paymentPayload: { x402Version: X402_VERSION, accepted: requirement, payload: body.payload },
      paymentRequirements: requirement,
    });
  }

  function supported() {
    const kinds = [
      { x402Version: X402_VERSION, scheme: 'exact', network: dep.network, extra: { asset: A.sUSD, ...dep.domains.sUSD } },
      { x402Version: X402_VERSION, scheme: 'exact', network: dep.network, extra: { asset: A.usdc, ...dep.domains.usdc } },
    ];
    if (A.router) {
      kinds.push({ x402Version: X402_VERSION, scheme: 'exact', network: dep.network, extra: { asset: A.usdc, spectrumRouter: A.router, payWith: A.sUSD } });
    }
    return { kinds, extensions: A.router ? ['spectrum-router', 'spectrum-convert'] : [], signers: { [dep.network]: [from] } };
  }

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://x');
      if (req.method === 'GET' && url.pathname === '/supported') return sendJson(res, 200, supported());
      if (req.method === 'GET' && url.pathname === '/health') return sendJson(res, 200, { ok: true, network: dep.network });
      if (req.method === 'POST' && url.pathname === '/verify') return sendJson(res, 200, await verify(await readJson(req)));
      if (req.method === 'POST' && url.pathname === '/settle') return sendJson(res, 200, await settle(await readJson(req)));
      if (req.method === 'POST' && url.pathname === '/convert') return sendJson(res, 200, await convert(await readJson(req)));
      return sendJson(res, 404, { error: 'not found' });
    } catch (e) {
      // Answering must not throw in turn: an exception escaping this handler is an unhandled
      // rejection, and Node 22 ends the process on one, so a single awkward request would take
      // the facilitator down for everybody.
      try {
        if (!res.headersSent) sendJson(res, e.status || 500, { error: e.status ? e.message : 'internal error' });
        else if (!res.writableEnded) res.end();
      } catch {
        /* the connection is already gone */
      }
    }
  });

  return { server, verify, settle, convert, supported, deployment: dep, address: from };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const signer = parseSigner(process.env.FACILITATOR_SIGNER, process.env.FACILITATOR_PASSWORD_FILE);
  const port = Number(process.env.FACILITATOR_PORT || 4020);
  const f = await createFacilitator({ rpcUrl: process.env.RPC_URL || 'http://127.0.0.1:8545', signer });
  f.server.listen(port, '127.0.0.1', () => {
    console.log(`facilitator on http://127.0.0.1:${port} (${f.deployment.network}), gas paid by ${f.address}`);
  });
}

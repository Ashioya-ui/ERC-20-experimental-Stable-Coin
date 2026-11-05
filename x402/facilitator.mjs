#!/usr/bin/env node
// x402 facilitator: /verify, /settle, /supported, session redemption.

import http from 'node:http';
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { cast, first, makeChain, parseSigner, signerAddress, UnconfirmedError } from './lib/cast.mjs';
import { isMain } from './lib/cli.mjs';
import { loadDeployment } from './lib/config.mjs';
import {
  X402_VERSION, lc, isAddress, isBytes32, isHex, isUint, readJson, sendJson, closeAfter, PAY_INTENT_FIELDS, intentTuple,
  permitTuple,
} from './lib/protocol.mjs';
import { MAX_DURATION, MIN_DURATION, UINT128_MAX, list, readPath, readSession, sessionIdOf, wellFormed } from './lib/session.mjs';

const SKEW = 6n;
const MAX_TIMEOUT = 3600n;
const INTENT_TYPE = `(${PAY_INTENT_FIELDS.map((f) => f.type).join(',')})`;
const PERMIT_TYPE = '(uint256,uint256,uint8,bytes32,bytes32)';

class QueueTimeout extends Error {
  constructor(message) {
    super(message);
    this.name = 'QueueTimeout';
  }
}

export async function createFacilitator({
  rpcUrl, signer, chain: chainOverride, queueWaitMs, sessionsFile = null, redeemEveryMs, admin = false, clockTtlMs = 15_000,
}) {
  const chain = chainOverride || makeChain(rpcUrl);
  const QUEUE_WAIT = Number(queueWaitMs ?? process.env.FACILITATOR_QUEUE_WAIT_MS ?? 120_000);
  const dep = await loadDeployment(chain);
  const A = dep.addresses;
  const from = await signerAddress(signer);

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
    'IntentAlreadyUsed(bytes32)': 'invalid_exact_evm_payload_authorization_nonce_used',
    'NotYetValid(uint256)': 'invalid_exact_evm_payload_authorization_valid_after',
    'Expired(uint256)': 'invalid_exact_evm_payload_authorization_valid_before',
    'SharesAboveCeiling(uint256,uint256)': 'vault_shares_above_ceiling',
    'ShortWithdrawal(uint256,uint256)': 'vault_short_withdrawal',
    'ZeroAmount()': 'invalid_payment_requirements',
    'AssetMismatch(address,address)': 'unsupported_asset',
    'AssetIsShareToken(address)': 'unsupported_vault',
    'PermitExpiresBeforeIntent(uint256,uint256)': 'vault_permit_expires_first',
    'ERC20InsufficientAllowance(address,uint256,uint256)': 'vault_insufficient_allowance',
    'ERC20InsufficientBalance(address,uint256,uint256)': 'insufficient_funds',
    'BadExpiry(uint64)': 'invalid_session_expiry',
    'SessionExists(bytes32)': 'session_exists',
    'UnknownSession(bytes32)': 'unknown_session',
    'SessionIsClosed(bytes32)': 'session_closed',
    'SessionExpired(bytes32)': 'session_expiring',
    'AboveDeposit(uint256,uint256)': 'session_above_deposit',
    'NothingNew(uint256,uint256)': 'session_voucher_stale',
    'InvalidVoucher()': 'invalid_session_voucher',
    'InexactTransfer()': 'unsupported_asset',
    'AmountOverflow()': 'invalid_payload',
    'ZeroAddress()': 'invalid_payload',
    'EscrowAsPayee()': 'invalid_pay_to',
    'NotOnPath(address)': 'path_payee_not_on_path',
    'BeyondEnd(address,uint256,uint256)': 'path_beyond_end',
    'StaleStep(uint256,uint256)': 'path_step_stale',
    'ShortOfFunds(uint256,uint256)': 'insufficient_funds',
    'SessionOutlivesPath(uint64,uint64)': 'invalid_session_expiry',
    'PathEnded(bytes32)': 'path_ended',
    'PathExpired(bytes32)': 'path_ended',
    'UnknownPath(bytes32)': 'unknown_path',
    'SignatureExpired(uint256)': 'invalid_exact_evm_payload_authorization_valid_before',
    'SessionMismatch(bytes32,bytes32)': 'invalid_session_id',
    'NotAgent(address)': 'invalid_payload',
    'LengthMismatch()': 'invalid_payload',
  };
  for (const [sig, reason] of Object.entries(map)) errors[(await cast(['sig', sig])).toLowerCase()] = reason;
  const fiatReasons = [
    [/invalid signature/i, 'invalid_exact_evm_payload_signature'],
    [/authorization is expired/i, 'invalid_exact_evm_payload_authorization_valid_before'],
    [/not yet valid/i, 'invalid_exact_evm_payload_authorization_valid_after'],
    [/used or canceled/i, 'invalid_exact_evm_payload_authorization_nonce_used'],
    [/exceeds balance/i, 'insufficient_funds'],
    [/blacklisted/i, 'blacklisted'],
    [/paused/i, 'token_paused'],
  ];
  const reasonOf = (e) => {
    const text = `${e?.message || ''}\n${e?.stderr || ''}`;
    for (const [sel, reason] of Object.entries(errors)) if (text.toLowerCase().includes(sel)) return reason;
    for (const [re, reason] of fiatReasons) if (re.test(text)) return reason;
    return null;
  };

  const forbiddenPayTo = new Set(
    [A.sUSD, A.stabilizer, A.treasury, A.router, A.usdc, A.vaultRouter, A.sessionEscrow, A.sessionPaths, ...A.vaults, '0x' + '0'.repeat(40)]
      .filter(Boolean),
  );
  const SESSION_MARGIN = BigInt(process.env.FACILITATOR_SESSION_MARGIN ?? 900);
  const REDEEM_THRESHOLD = BigInt(process.env.FACILITATOR_REDEEM_THRESHOLD ?? 100_000);
  const REDEEM_MAX_AGE_MS = Number(process.env.FACILITATOR_REDEEM_MAX_AGE_MS ?? 3_600_000);
  const REDEEM_EVERY_MS = Number(redeemEveryMs ?? process.env.FACILITATOR_REDEEM_EVERY_MS ?? 30_000);
  const MAX_BATCH = 50;
  const BIG = ['deposited', 'claimed', 'expiry', 'accepted'];
  const sessions = new Map();
  const opening = new Map();
  if (sessionsFile && existsSync(sessionsFile)) {
    const saved = JSON.parse(readFileSync(sessionsFile, 'utf8'));
    if (A.sessionEscrow && lc(saved.escrow) !== A.sessionEscrow) {
      throw new Error(`${sessionsFile} holds vouchers for escrow ${saved.escrow}, not ${A.sessionEscrow}`);
    }
    for (const [id, rec] of Object.entries(saved.sessions || {})) {
      const r = { ...rec };
      for (const k of BIG) r[k] = BigInt(rec[k]);
      sessions.set(id, r);
    }
  }
  function persist() {
    if (!sessionsFile) return;
    const out = {};
    for (const [id, rec] of sessions) {
      out[id] = Object.fromEntries(Object.entries(rec).map(([k, v]) => [k, typeof v === 'bigint' ? v.toString() : v]));
    }
    const tmp = `${sessionsFile}.tmp`;
    writeFileSync(tmp, JSON.stringify({ version: 1, escrow: A.sessionEscrow, sessions: out }), { mode: 0o600 });
    renameSync(tmp, sessionsFile);
  }
  let clock = null;
  const chainNow = async () => {
    if (!clock || Date.now() - clock.at > clockTtlMs) clock = { t: await chain.timestamp(), at: Date.now() };
    return clock.t + BigInt(Math.floor((Date.now() - clock.at) / 1000));
  };
  const minRemainingOf = (r) => {
    const raw = r?.extra?.minRemainingSeconds;
    const asked = isUint(raw) ? BigInt(raw) : 0n;
    const capped = asked > MAX_DURATION ? MAX_DURATION : asked;
    return capped > SESSION_MARGIN ? capped : SESSION_MARGIN;
  };

  const settled = new Map();
  const inflight = new Map();
  const unconfirmed = new Map();
  const MAX_SETTLED = 10_000;
  const MAX_UNCONFIRMED = 1_000;
  const UNCONFIRMED_TTL_MS = Number(MAX_TIMEOUT) * 2 * 1000;

  const rememberUnconfirmed = (key, entry) => {
    unconfirmed.delete(key);
    unconfirmed.set(key, { ...entry, at: Date.now() });
    const cutoff = Date.now() - UNCONFIRMED_TTL_MS;
    for (const [old, v] of unconfirmed) {
      if (old === key) break;
      if (unconfirmed.size <= MAX_UNCONFIRMED && v.at >= cutoff) break;
      unconfirmed.delete(old);
    }
  };

  let queue = Promise.resolve();
  const serial = (fn) => {
    let started = false;
    let abandoned = false;
    const start = () => {
      if (abandoned) return undefined;
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
  const FAILURE_BUDGET = 3;
  const FAILURE_WINDOW_MS = 3_600_000;
  const failures = new Map();
  const recentFailures = (payer) => {
    const xs = (failures.get(payer) || []).filter((t) => Date.now() - t < FAILURE_WINDOW_MS);
    if (xs.length) failures.set(payer, xs);
    else failures.delete(payer);
    return xs.length;
  };
  const chargeFailure = (payer) => {
    if (!payer) return;
    failures.set(payer, [...(failures.get(payer) || []), Date.now()]);
    if (failures.size > 10_000) failures.delete(failures.keys().next().value);
  };
  const payerOf = (body) => {
    const pl = body?.paymentPayload?.payload;
    let from;
    if (pl?.session !== undefined) {
      const known = isBytes32(pl.session?.sessionId) ? sessions.get(lc(pl.session.sessionId)) : null;
      from = known?.funder ?? pl.session?.open?.funder;
    } else from = pl?.vaultPay !== undefined ? pl.vaultPay?.intent?.payer : pl?.authorization?.from;
    return isAddress(from) ? lc(from) : undefined;
  };
  const keyOf = (body) => {
    const pl = body?.paymentPayload?.payload;
    if (pl?.vaultPay !== undefined) {
      const vp = pl.vaultPay;
      return isAddress(vp?.router) && isAddress(vp?.intent?.payer) && isBytes32(vp?.intent?.salt)
        ? `${lc(vp.intent.payer)}:vault:${lc(vp.router)}:${lc(vp.intent.salt)}`
        : null;
    }
    const auth = pl?.authorization;
    return auth && isAddress(auth.from) && isBytes32(auth.nonce) ? `${lc(auth.from)}:${lc(auth.nonce)}` : null;
  };
  const fingerprint = (body) => {
    const p = body?.paymentPayload;
    const r = body?.paymentRequirements;
    const vp = p?.payload?.vaultPay;
    if (vp !== undefined) {
      const it = vp?.intent || {};
      const pm = vp?.permit;
      return JSON.stringify([
        'vault', r?.network, lc(r?.asset), lc(r?.payTo), String(r?.amount), lc(vp?.router),
        ...PAY_INTENT_FIELDS.map(({ name }) => lc(String(it[name] ?? ''))), lc(vp?.signature),
        pm ? [String(pm.value), String(pm.deadline), String(pm.v), lc(pm.r), lc(pm.s)] : null,
      ]);
    }
    const a = p?.payload?.authorization || {};
    return JSON.stringify([
      r?.network, lc(r?.asset), lc(r?.payTo), String(r?.amount), lc(a.from), lc(a.to), String(a.value),
      String(a.validAfter), String(a.validBefore), lc(a.nonce), lc(p?.payload?.signature), lc(p?.payload?.spectrum?.salt),
    ]);
  };

  async function windowError(validAfter, validBefore, r, payer, at) {
    const now = at ?? (await chain.timestamp());
    if (BigInt(validAfter) > now) return bad('invalid_exact_evm_payload_authorization_valid_after', payer);
    if (!(now + SKEW < BigInt(validBefore))) return bad('invalid_exact_evm_payload_authorization_valid_before', payer);
    const rawTimeout = r.maxTimeoutSeconds ?? 60;
    if (!isUint(rawTimeout)) return bad('invalid_payment_requirements', payer);
    const timeout = BigInt(rawTimeout) > MAX_TIMEOUT ? MAX_TIMEOUT : BigInt(rawTimeout);
    if (BigInt(validBefore) > now + timeout + SKEW) return bad('invalid_exact_evm_payload_authorization_valid_before', payer);
    return null;
  }

  async function checkVault(vp, r) {
    const it = vp?.intent;
    const pm = vp?.permit ?? null;
    if (
      !it || !isAddress(vp.router) || !isHex(vp.signature) || !isAddress(it.payer) || !isAddress(it.vault) ||
      !isAddress(it.asset) || !isAddress(it.payTo) || !isUint(it.assets) || !isUint(it.maxShares) || !isBytes32(it.salt) ||
      !isUint(it.validAfter) || !isUint(it.validBefore) || !isAddress(r.payTo) || !isUint(r.amount)
    ) return bad('invalid_payload');
    if (pm !== null && !(isUint(pm.value) && isUint(pm.deadline) && isUint(pm.v) && isBytes32(pm.r) && isBytes32(pm.s))) {
      return bad('invalid_payload');
    }
    const payer = lc(it.payer);
    const payTo = lc(r.payTo);
    const vault = lc(it.vault);
    if (!A.vaultRouter || lc(vp.router) !== A.vaultRouter) return bad('unsupported_vault_router', payer);
    if (!A.vaults.includes(vault)) return bad('unsupported_vault', payer);
    if (forbiddenPayTo.has(payTo)) return bad('invalid_pay_to', payer);
    if (BigInt(r.amount) === 0n) return bad('invalid_payment_requirements', payer);
    if (lc(it.payTo) !== payTo) return bad('invalid_exact_evm_payload_recipient_mismatch', payer);
    if (lc(it.asset) !== lc(r.asset)) return bad('unsupported_asset', payer);
    if (BigInt(it.assets) !== BigInt(r.amount)) return bad('invalid_exact_evm_payload_authorization_value', payer);
    if (pm !== null && BigInt(pm.deadline) + 1n < BigInt(it.validBefore)) return bad('vault_permit_expires_first', payer);
    const late = await windowError(it.validAfter, it.validBefore, r, payer);
    if (late) return late;
    if (lc(first(await chain.call(vault, 'asset()(address)'))) !== lc(r.asset)) return bad('unsupported_asset', payer);

    const intent = intentTuple(it);
    const digest = lc(first(await chain.call(A.vaultRouter, `intentDigest(${INTENT_TYPE})(bytes32)`, [intent])));
    if (await chain.bool(A.vaultRouter, 'intentUsed(address,bytes32)(bool)', [it.payer, digest])) {
      return bad('invalid_exact_evm_payload_authorization_nonce_used', payer);
    }
    const needed = await chain.uint(A.vaultRouter, 'sharesFor(address,uint256)(uint256)', [vault, it.assets]);
    if (needed > BigInt(it.maxShares)) return bad('vault_shares_above_ceiling', payer);
    if ((await chain.uint(vault, 'balanceOf(address)(uint256)', [it.payer])) < needed) return bad('insufficient_funds', payer);

    const tx = { to: A.vaultRouter, sig: `pay(${INTENT_TYPE},bytes,${PERMIT_TYPE})`, args: [intent, vp.signature, permitTuple(pm)] };
    try {
      await chain.call(tx.to, tx.sig, tx.args, { from });
    } catch (e) {
      return bad(reasonOf(e) || 'unexpected_verify_error', payer);
    }
    return { isValid: true, payer, mode: 'vault', tx, digest };
  }

  async function checkSession(sp, r) {
    if (!wellFormed(sp) || !isAddress(r.payTo) || !isUint(r.amount)) return bad('invalid_payload');
    const id = lc(sp.sessionId);
    const known = sessions.get(id);
    const hint = known?.funder ?? (sp.open ? lc(sp.open.funder) : undefined);
    if (!A.sessionEscrow || lc(sp.escrow) !== A.sessionEscrow) return bad('unsupported_session_escrow', hint);
    if (lc(r.asset) !== A.usdc) return bad('unsupported_asset', hint);
    const payTo = lc(r.payTo);
    if (forbiddenPayTo.has(payTo)) return bad('invalid_pay_to', hint);
    const price = BigInt(r.amount);
    if (price === 0n) return bad('invalid_payment_requirements', hint);
    const cumulative = BigInt(sp.cumulative);
    if (cumulative > UINT128_MAX) return bad('session_above_deposit', hint);
    const minRemaining = minRemainingOf(r);
    const voucher = lc(sp.voucher);

    const s = known ?? (await readSession(chain, A.sessionEscrow, id));
    if (s) {
      const payer = s.funder;
      if (s.payee !== payTo) return bad('invalid_session_payee', payer);
      if (s.token !== A.usdc) return bad('invalid_session_asset', payer);
      if (s.closed) return bad('session_closed', payer);
      if (s.expiry < (await chainNow()) + minRemaining) return bad('session_expiring', payer);
      const floor = (s.accepted ?? 0n) > s.claimed ? s.accepted : s.claimed;
      if (cumulative < floor + price) return bad('session_voucher_stale', payer);
      try {
        await chain.call(A.sessionEscrow, 'redeem(bytes32,uint256,bytes)', [id, String(cumulative), voucher], { from });
      } catch (e) {
        const reason = reasonOf(e) || 'invalid_session_voucher';
        if (known && reason === 'session_closed') known.closed = true;
        return bad(reason, payer);
      }
      return { isValid: true, payer, mode: 'session', id, cumulative, voucher, snapshot: s };
    }

    if (sp.pathStep !== undefined) return checkPathStep(sp, r, { id, payTo, price, cumulative, minRemaining, voucher, hint });
    const o = sp.open;
    if (!o) return bad('unknown_session', hint);
    const payer = lc(o.funder);
    const signerAddress = lc(o.signer);
    const expiry = BigInt(o.expiry);
    const deposit = BigInt(o.amount);
    if (deposit === 0n || deposit > UINT128_MAX || expiry >= 1n << 64n) return bad('invalid_payload', payer);
    const expected = await sessionIdOf({
      funder: payer, payee: payTo, token: A.usdc, signer: signerAddress, expiry, salt: lc(o.salt),
    });
    if (expected !== id) return bad('invalid_session_id', payer);
    if (cumulative < price) return bad('session_voucher_stale', payer);
    if (cumulative > deposit) return bad('session_above_deposit', payer);
    const now = await chain.timestamp();
    const late = await windowError(o.validAfter, o.validBefore, r, payer, now);
    if (late) return late;
    if (expiry < now + minRemaining || expiry < BigInt(o.validBefore) + MIN_DURATION || expiry > now + MAX_DURATION) {
      return bad('invalid_session_expiry', payer);
    }
    const signed = await chain.bool(A.sessionEscrow, 'isVoucherSignedBy(address,bytes32,uint256,bytes)(bool)', [
      signerAddress, id, String(cumulative), voucher,
    ]);
    if (!signed) return bad('invalid_session_voucher', payer);
    const tx = {
      to: A.sessionEscrow,
      sig: 'openWithAuthorization(address,address,address,address,uint64,bytes32,uint256,uint256,uint256,bytes)',
      args: [
        payer, payTo, A.usdc, signerAddress, String(expiry), lc(o.salt), String(deposit), String(o.validAfter),
        String(o.validBefore), o.authorization,
      ],
    };
    try {
      await chain.call(tx.to, tx.sig, tx.args, { from });
    } catch (e) {
      return bad(reasonOf(e) || 'unexpected_verify_error', payer);
    }
    return {
      isValid: true, payer, mode: 'session', id, cumulative, voucher, tx, validBefore: BigInt(o.validBefore),
      opening: {
        funder: payer, payee: payTo, token: A.usdc, signer: signerAddress, deposited: deposit, claimed: 0n, expiry, closed: false,
      },
    };
  }

  async function checkPathStep(sp, r, c) {
    const ps = sp.pathStep;
    if (!A.sessionPaths) return bad('unsupported_session_paths', c.hint);
    const path = await readPath(chain, A.sessionPaths, lc(ps.pathId));
    if (!path) return bad('unknown_path', c.hint);
    const payer = path.agent;
    if (path.token !== A.usdc) return bad('invalid_session_asset', payer);
    const signerAddress = lc(ps.signer);
    const expiry = BigInt(ps.expiry);
    const deposit = BigInt(ps.amount);
    if (deposit === 0n || deposit > UINT128_MAX || expiry >= 1n << 64n) return bad('invalid_payload', payer);
    const expected = await sessionIdOf({
      funder: A.sessionPaths, payee: c.payTo, token: A.usdc, signer: signerAddress, expiry, salt: lc(ps.salt),
    });
    if (expected !== c.id) return bad('invalid_session_id', payer);
    if (c.cumulative < c.price) return bad('session_voucher_stale', payer);
    if (c.cumulative > deposit) return bad('session_above_deposit', payer);
    const now = await chain.timestamp();
    const late = await windowError('0', ps.deadline, r, payer, now);
    if (late) return late;
    if (expiry < now + c.minRemaining || expiry < BigInt(ps.deadline) + MIN_DURATION || expiry > path.expiry) {
      return bad('invalid_session_expiry', payer);
    }
    const signed = await chain.bool(A.sessionEscrow, 'isVoucherSignedBy(address,bytes32,uint256,bytes)(bool)', [
      signerAddress, c.id, String(c.cumulative), c.voucher,
    ]);
    if (!signed) return bad('invalid_session_voucher', payer);
    const tx = {
      to: A.sessionPaths,
      sig: 'stepWithSig(bytes32,address,address,uint64,bytes32,uint256,uint256,uint256,bytes)',
      args: [
        lc(ps.pathId), c.payTo, signerAddress, String(expiry), lc(ps.salt), String(deposit), String(ps.committed),
        String(ps.deadline), ps.signature,
      ],
    };
    try {
      await chain.call(tx.to, tx.sig, tx.args, { from });
    } catch (e) {
      return bad(reasonOf(e) || 'unexpected_verify_error', payer);
    }
    return {
      isValid: true, payer, mode: 'session', id: c.id, cumulative: c.cumulative, voucher: c.voucher, tx,
      validBefore: BigInt(ps.deadline),
      opening: {
        funder: A.sessionPaths, payee: c.payTo, token: A.usdc, signer: signerAddress, deposited: deposit, claimed: 0n,
        expiry, closed: false,
      },
    };
  }

  const sessionLocks = new Map();
  const withSessionLock = (id, fn) => {
    const run = (sessionLocks.get(id) || Promise.resolve()).then(fn, fn);
    const tail = run.then(() => {}, () => {});
    sessionLocks.set(id, tail);
    tail.then(() => {
      if (sessionLocks.get(id) === tail) sessionLocks.delete(id);
    });
    return run;
  };

  async function openOutcome(pending) {
    if (!pending.hash) return 'unknown';
    try {
      const status = String((await chain.receipt(pending.hash)).status);
      if (['0x1', '1', 'true'].includes(status)) return 'ok';
      if (['0x0', '0', 'false'].includes(status)) return 'reverted';
    } catch {
    }
    return 'unknown';
  }

  async function settleSession(body) {
    const fail = (errorReason, payer, transaction = '') => ({ success: false, errorReason, payer: payer ?? '', transaction, network: dep.network });
    const sp = body?.paymentPayload?.payload?.session;
    if (!isBytes32(sp?.sessionId)) return fail('invalid_payload', payerOf(body));
    const id = lc(sp.sessionId);
    return withSessionLock(id, async () => {
      const pending = opening.get(id);
      if (pending) {
        if ((await openOutcome(pending)) === 'unknown') {
          const exists = await readSession(chain, A.sessionEscrow, id).catch(() => null);
          if (!exists && (await chain.timestamp()) <= pending.validBefore) {
            return fail('settlement_unconfirmed', pending.payer, pending.hash);
          }
        }
        opening.delete(id);
      }
      let v;
      try {
        v = await check(body);
      } catch (e) {
        return fail(reasonOf(e) || 'unexpected_settle_error', payerOf(body));
      }
      if (!v.isValid) return fail(v.invalidReason, v.payer);
      if (v.mode !== 'session' || v.id !== id) return fail('invalid_payload', v.payer);

      let transaction = '';
      let s = sessions.get(id);
      if (v.tx) {
        try {
          const sent = await serial(async () => {
            await chain.call(v.tx.to, v.tx.sig, v.tx.args, { from });
            return chain.send(v.tx.to, v.tx.sig, v.tx.args, signer);
          });
          if (!sent.ok) {
            chargeFailure(v.payer);
            return fail('invalid_transaction_state', v.payer, sent.hash);
          }
          transaction = sent.hash;
        } catch (e) {
          if (e instanceof UnconfirmedError) {
            opening.set(id, { hash: e.hash, payer: v.payer, validBefore: v.validBefore });
            return fail('settlement_unconfirmed', v.payer, e.hash);
          }
          if (e instanceof QueueTimeout) return fail('settlement_queue_timeout', v.payer);
          return fail(reasonOf(e) || 'unexpected_settle_error', v.payer);
        }
        s = { ...v.opening, accepted: 0n, voucher: null, pendingSince: null, openTx: transaction };
      } else if (!s) {
        s = { ...v.snapshot, accepted: 0n, voucher: null, pendingSince: null, openTx: '' };
      }
      const before = { accepted: s.accepted, voucher: s.voucher, pendingSince: s.pendingSince };
      s.accepted = v.cumulative;
      s.voucher = v.voucher;
      s.pendingSince ??= Date.now();
      sessions.set(id, s);
      try {
        persist();
      } catch (e) {
        Object.assign(s, before);
        return fail('unexpected_settle_error', v.payer, transaction);
      }
      return { success: true, payer: v.payer, transaction, network: dep.network, session: { id, cumulative: String(v.cumulative) } };
    });
  }

  let redeeming = Promise.resolve();
  function redeemDue({ force = false } = {}) {
    const run = redeeming.then(() => redeemPass(force));
    redeeming = run.then(() => {}, () => {});
    return run;
  }
  async function redeemPass(force) {
    if (!A.sessionEscrow) return { transactions: [], redeemed: [], skipped: [] };
    const now = await chain.timestamp();
    const ready = [];
    const skipped = [];
    for (const [id, s] of sessions) {
      if (s.closed || !s.voucher || s.accepted <= s.claimed || s.expiry < now) continue;
      const urgent = s.expiry <= now + 2n * SESSION_MARGIN;
      const old = s.pendingSince !== null && Date.now() - s.pendingSince >= REDEEM_MAX_AGE_MS;
      if (!(force || urgent || old || s.accepted - s.claimed >= REDEEM_THRESHOLD)) continue;
      const item = { id, cumulative: s.accepted, voucher: s.voucher };
      try {
        await chain.call(A.sessionEscrow, 'redeem(bytes32,uint256,bytes)', [id, String(item.cumulative), item.voucher], { from });
        ready.push(item);
      } catch (e) {
        const fresh = await readSession(chain, A.sessionEscrow, id).catch(() => null);
        if (fresh) {
          if (fresh.claimed > s.claimed) s.claimed = fresh.claimed;
          s.closed = fresh.closed;
          s.deposited = fresh.deposited;
        }
        skipped.push({ id, reason: reasonOf(e) || 'redeem_simulation_failed' });
      }
    }
    if (skipped.length) persist();
    const transactions = [];
    for (let i = 0; i < ready.length; i += MAX_BATCH) {
      const batch = ready.slice(i, i + MAX_BATCH);
      const tx = batch.length === 1
        ? { sig: 'redeem(bytes32,uint256,bytes)', args: [batch[0].id, String(batch[0].cumulative), batch[0].voucher] }
        : {
            sig: 'redeemMany(bytes32[],uint256[],bytes[])',
            args: [list(batch.map((b) => b.id)), list(batch.map((b) => b.cumulative)), list(batch.map((b) => b.voucher))],
          };
      let sent = null;
      try {
        sent = await serial(async () => {
          await chain.call(A.sessionEscrow, tx.sig, tx.args, { from });
          return chain.send(A.sessionEscrow, tx.sig, tx.args, signer);
        });
      } catch (e) {
        if (e instanceof UnconfirmedError) transactions.push({ hash: e.hash, ok: null, sessions: batch.length });
        continue;
      }
      if (!sent.ok) {
        transactions.push({ hash: sent.hash, ok: false, sessions: batch.length, paid: 0 });
        continue;
      }
      let paid = 0;
      for (const b of batch) {
        const s = sessions.get(b.id);
        const fresh = batch.length === 1 ? null : await readSession(chain, A.sessionEscrow, b.id).catch(() => null);
        const claimed = fresh ? fresh.claimed : b.cumulative;
        if (claimed >= b.cumulative) paid += 1;
        if (claimed > s.claimed) s.claimed = claimed;
        if (fresh) s.closed = fresh.closed;
        s.pendingSince = s.accepted > s.claimed ? Date.now() : null;
      }
      transactions.push({ hash: sent.hash, ok: true, sessions: batch.length, paid });
      persist();
    }
    return {
      transactions,
      redeemed: ready.map((b) => ({ id: b.id, cumulative: String(b.cumulative) })),
      skipped,
    };
  }

  function sessionList() {
    return [...sessions].map(([id, s]) => ({
      id, funder: s.funder, payee: s.payee, signer: s.signer, deposited: String(s.deposited), accepted: String(s.accepted),
      claimed: String(s.claimed), expiry: String(s.expiry), closed: s.closed, openTx: s.openTx,
    }));
  }

  async function check(body) {
    const { x402Version, paymentPayload: p, paymentRequirements: r } = body ?? {};
    if (x402Version !== X402_VERSION || p?.x402Version !== X402_VERSION) return bad('invalid_x402_version');
    const scheme = r?.scheme;
    if ((scheme !== 'exact' && scheme !== 'session') || p?.accepted?.scheme !== scheme) return bad('unsupported_scheme');
    if (r.network !== dep.network || p.accepted.network !== dep.network) return bad('invalid_network');
    for (const k of ['asset', 'payTo', 'amount']) {
      if (lc(p.accepted[k]) !== lc(r[k])) return bad('invalid_payment_requirements');
    }
    if (scheme === 'session') {
      if (p.payload?.authorization !== undefined || p.payload?.vaultPay !== undefined) return bad('invalid_payload');
      return checkSession(p.payload?.session, r);
    }
    if (p.payload?.session !== undefined) return bad('invalid_payload');
    if (p.payload?.vaultPay !== undefined) {
      if (p.payload?.authorization !== undefined) return bad('invalid_payload');
      return checkVault(p.payload.vaultPay, r);
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

    const late = await windowError(auth.validAfter, auth.validBefore, r, payer);
    if (late) return late;

    const asset = lc(r.asset);
    let mode;
    if (A.sUSD && asset === A.sUSD) mode = 'sUSD';
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

    try {
      await chain.call(tx.to, tx.sig, tx.args, { from });
    } catch (e) {
      return bad(reasonOf(e) || 'unexpected_verify_error', payer);
    }
    return { isValid: true, payer, mode, tx, key: `${payer}:${lc(auth.nonce)}` };
  }

  async function verify(body) {
    const who = payerOf(body);
    if (who && recentFailures(who) >= FAILURE_BUDGET) return bad('payer_throttled', who);
    let v;
    try {
      v = await check(body);
    } catch (e) {
      return bad(reasonOf(e) || 'unexpected_verify_error', payerOf(body));
    }
    return v.isValid ? { isValid: true, payer: v.payer } : v;
  }

  async function settle(body) {
    const who = payerOf(body);
    if (who && recentFailures(who) >= FAILURE_BUDGET) {
      return { success: false, errorReason: 'payer_throttled', payer: who, transaction: '', network: dep.network };
    }
    if (body?.paymentRequirements?.scheme === 'session') return settleSession(body);
    const key = keyOf(body);
    const fp = fingerprint(body);
    const fail = (errorReason, payer, transaction = '') => ({ success: false, errorReason, payer: payer ?? '', transaction, network: dep.network });
    const prior = key && (settled.get(key) || inflight.get(key) || unconfirmed.get(key));
    if (prior && prior.fp !== fp) {
      return fail('invalid_exact_evm_payload_authorization_nonce_used', payerOf(body));
    }
    if (prior && prior.result) return prior.result;
    const succeed = (payer, transaction) => {
      const response = { success: true, payer, transaction, network: dep.network };
      settled.set(key, { fp, result: response });
      if (settled.size > MAX_SETTLED) settled.delete(settled.keys().next().value);
      return response;
    };
    const work = prior
      ? (async () => {
          if (!prior.hash) return fail('settlement_unconfirmed', prior.payer);
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
            return fail(reasonOf(e) || 'unexpected_settle_error', payerOf(body));
          }
          if (!v.isValid) return fail(v.invalidReason, v.payer);
          try {
            return await serial(async () => {
              try {
                await chain.call(v.tx.to, v.tx.sig, v.tx.args, { from });
              } catch (e) {
                return fail(reasonOf(e) || 'unexpected_settle_error', v.payer);
              }
              try {
                const sent = await chain.send(v.tx.to, v.tx.sig, v.tx.args, signer);
                if (!sent.ok) {
                  chargeFailure(v.payer);
                  return fail('invalid_transaction_state', v.payer, sent.hash);
                }
                return succeed(v.payer, sent.hash);
              } catch (e) {
                if (e instanceof UnconfirmedError) {
                  rememberUnconfirmed(key, { fp, hash: e.hash, payer: v.payer });
                  return fail('settlement_unconfirmed', v.payer, e.hash);
                }
                return fail(reasonOf(e) || 'unexpected_settle_error', v.payer);
              }
            });
          } catch (e) {
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

  async function convert(body) {
    if (!A.router) return { success: false, errorReason: 'unsupported', transaction: '', network: dep.network };
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
    const kind = (extra) => ({ x402Version: X402_VERSION, scheme: 'exact', network: dep.network, extra });
    const kinds = [];
    if (A.sUSD) kinds.push(kind({ asset: A.sUSD, ...dep.domains.sUSD }));
    kinds.push(kind({ asset: A.usdc, ...dep.domains.usdc }));
    if (A.router) kinds.push(kind({ asset: A.usdc, spectrumRouter: A.router, payWith: A.sUSD }));
    if (A.vaultRouter && A.vaults.length) kinds.push(kind({ asset: A.usdc, vaultRouter: A.vaultRouter, vaults: A.vaults }));
    if (A.sessionEscrow) {
      kinds.push({
        x402Version: X402_VERSION, scheme: 'session', network: dep.network,
        extra: {
          asset: A.usdc, escrow: A.sessionEscrow, ...dep.domains.usdc, minRemainingSeconds: String(SESSION_MARGIN),
          ...(A.sessionPaths ? { paths: A.sessionPaths } : {}),
        },
      });
    }
    const extensions = [
      ...(A.router ? ['spectrum-router', 'spectrum-convert'] : []),
      ...(A.vaultRouter ? ['spectrum-vault-router'] : []),
      ...(A.sessionEscrow ? ['spectrum-session'] : []),
    ];
    return { kinds, extensions, signers: { [dep.network]: [from] } };
  }

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://x');
      if (req.method === 'GET' && url.pathname === '/supported') return sendJson(res, 200, supported());
      if (req.method === 'GET' && url.pathname === '/health') return sendJson(res, 200, { ok: true, network: dep.network });
      if (req.method === 'POST' && url.pathname === '/verify') return sendJson(res, 200, await verify(await readJson(req)));
      if (req.method === 'POST' && url.pathname === '/settle') return sendJson(res, 200, await settle(await readJson(req)));
      if (req.method === 'POST' && url.pathname === '/convert') return sendJson(res, 200, await convert(await readJson(req)));
      if (admin && req.method === 'GET' && url.pathname === '/sessions') return sendJson(res, 200, sessionList());
      if (admin && req.method === 'POST' && url.pathname === '/sessions/redeem') {
        return sendJson(res, 200, await redeemDue({ force: true }));
      }
      return sendJson(res, 404, { error: 'not found' });
    } catch (e) {
      try {
        if (e.status === 413) closeAfter(req, res);
        if (!res.headersSent) sendJson(res, e.status || 500, { error: e.status ? e.message : 'internal error' });
        else if (!res.writableEnded) res.end();
      } catch {
      }
    }
  });

  let timer = null;
  if (A.sessionEscrow && REDEEM_EVERY_MS > 0) {
    timer = setInterval(() => {
      redeemDue().catch((e) => console.error(`session redemption pass failed: ${e.message}`));
    }, REDEEM_EVERY_MS);
    timer.unref();
  }
  server.on('close', () => timer && clearInterval(timer));

  return {
    server, verify, settle, convert, supported, redeemDue, sessions: sessionList, deployment: dep, address: from,
  };
}

if (isMain(import.meta.url)) {
  const signer = parseSigner(process.env.FACILITATOR_SIGNER, process.env.FACILITATOR_PASSWORD_FILE);
  const port = Number(process.env.FACILITATOR_PORT || 4020);
  const f = await createFacilitator({
    rpcUrl: process.env.RPC_URL || 'http://127.0.0.1:8545',
    signer,
    sessionsFile: process.env.FACILITATOR_SESSIONS_FILE || 'x402-sessions.json',
    admin: process.env.FACILITATOR_ADMIN === '1',
  });
  f.server.listen(port, '127.0.0.1', () => {
    console.log(`facilitator on http://127.0.0.1:${port} (${f.deployment.network}), gas paid by ${f.address}`);
  });
}

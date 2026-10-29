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
//   vault   the requirement's asset is USDC and the payer holds shares of an ERC-4626 vault over
//           it (on Base: Aave's waBasUSDC): a PayIntent signed for VaultPayRouter, plus an optional
//           EIP-2612 permit on the shares. The router withdraws exactly `amount`, pays the merchant
//           and returns the rest. Nothing is issued; this mode needs no Spectrum deployment at all.
//   session the requirement's scheme is "session": a voucher on an X402SessionEscrow session, the
//           cumulative amount owed so far, signed by the session's key. The first call also carries a
//           gasless open (an EIP-3009 receive authorization whose nonce binds every term of the
//           session), which is the only transaction it costs. Every later call is checked with one
//           simulated redemption and answered at once; nothing is sent per call. Accepted vouchers
//           are kept on disk and redeemed in batches (redeemMany), always before expiry.
// Plus POST /convert (a Spectrum extension): the same router call with payTo = the payer, so an
// agent holding sUSD can get USDC for any merchant on any facilitator.
//
// Every check runs before anything is sent, and the exact transaction is simulated with eth_call
// first. Settlement is idempotent per (payer, nonce), with in-flight locking.
//
// Env: RPC_URL, FACILITATOR_PORT (4020), FACILITATOR_SIGNER (unlocked:<address> on anvil, or
// keystore:<path> with FACILITATOR_PASSWORD_FILE), DEPLOYMENT / ROUTER_DEPLOYMENT (optional),
// FACILITATOR_SESSIONS_FILE (accepted vouchers; default x402-sessions.json), FACILITATOR_REDEEM_EVERY_MS
// (30000), FACILITATOR_REDEEM_THRESHOLD (100000 = 0.10 USDC), FACILITATOR_REDEEM_MAX_AGE_MS (3600000),
// FACILITATOR_SESSION_MARGIN (900 s), FACILITATOR_ADMIN=1 (enables GET /sessions, POST /sessions/redeem).

import http from 'node:http';
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { cast, first, makeChain, parseSigner, signerAddress, UnconfirmedError } from './lib/cast.mjs';
import { loadDeployment } from './lib/config.mjs';
import {
  X402_VERSION, lc, isAddress, isBytes32, isHex, isUint, readJson, sendJson, closeAfter, PAY_INTENT_FIELDS, intentTuple,
  permitTuple,
} from './lib/protocol.mjs';
import { MAX_DURATION, MIN_DURATION, UINT128_MAX, list, readSession, sessionIdOf, wellFormed } from './lib/session.mjs';

const SKEW = 6n; // seconds of clock slack allowed beyond maxTimeoutSeconds
// A requirement comes from the resource server, which is not trusted: its maxTimeoutSeconds is
// validated like any other input, and capped, so a hostile or careless merchant cannot talk the
// facilitator into accepting an authorization that stays spendable for days (A-02).
const MAX_TIMEOUT = 3600n;
// VaultPayRouter's ABI tuples, as cast takes them.
const INTENT_TYPE = `(${PAY_INTENT_FIELDS.map((f) => f.type).join(',')})`;
const PERMIT_TYPE = '(uint256,uint256,uint8,bytes32,bytes32)';

/** Raised when a settlement waited for its turn in the send queue and never got one. */
class QueueTimeout extends Error {
  constructor(message) {
    super(message);
    this.name = 'QueueTimeout';
  }
}

export async function createFacilitator({
  rpcUrl, signer, chain: chainOverride, queueWaitMs, sessionsFile = null, redeemEveryMs, admin = false, clockTtlMs = 15_000,
}) {
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
    // VaultPayRouter, and the OpenZeppelin ERC-20 errors its vault raises
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
    // X402SessionEscrow
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
    [A.sUSD, A.stabilizer, A.treasury, A.router, A.usdc, A.vaultRouter, A.sessionEscrow, ...A.vaults, '0x' + '0'.repeat(40)]
      .filter(Boolean),
  );
  // Sessions. `sessions` holds every session this facilitator has accepted a voucher on (so each
  // exists on-chain): the highest voucher it accepted, and what it knows was claimed. That record is
  // money the merchant has already served against, so it is written to disk before any call is
  // answered as paid.
  const SESSION_MARGIN = BigInt(process.env.FACILITATOR_SESSION_MARGIN ?? 900); // life a session must have left
  const REDEEM_THRESHOLD = BigInt(process.env.FACILITATOR_REDEEM_THRESHOLD ?? 100_000); // 0.10 USDC
  const REDEEM_MAX_AGE_MS = Number(process.env.FACILITATOR_REDEEM_MAX_AGE_MS ?? 3_600_000);
  const REDEEM_EVERY_MS = Number(redeemEveryMs ?? process.env.FACILITATOR_REDEEM_EVERY_MS ?? 30_000);
  const MAX_BATCH = 50;
  const BIG = ['deposited', 'claimed', 'expiry', 'accepted'];
  const sessions = new Map(); // sessionId -> { funder, payee, token, signer, deposited, claimed, expiry, closed, accepted, voucher, pendingSince, openTx }
  const opening = new Map(); // sessionId -> { hash, payer, validBefore }: an open sent whose receipt was not read
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
    renameSync(tmp, sessionsFile); // atomic: a crash leaves the old file or the new one, never half of one
  }
  // Chain time for voucher checks, read at most every clockTtlMs and carried forward by the local
  // clock in between: a voucher costs one RPC (its simulated redemption), not two. Opens and
  // redemptions read the chain's clock directly.
  let clock = null;
  const chainNow = async () => {
    if (!clock || Date.now() - clock.at > clockTtlMs) clock = { t: await chain.timestamp(), at: Date.now() };
    return clock.t + BigInt(Math.floor((Date.now() - clock.at) / 1000));
  };
  // The merchant's minimum remaining life for a session, never below the facilitator's own margin
  // for getting a redemption included before expiry. Its requirement is untrusted input.
  const minRemainingOf = (r) => {
    const raw = r?.extra?.minRemainingSeconds;
    const asked = isUint(raw) ? BigInt(raw) : 0n;
    const capped = asked > MAX_DURATION ? MAX_DURATION : asked;
    return capped > SESSION_MARGIN ? capped : SESSION_MARGIN;
  };

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
  // A payment that simulates cleanly and then reverts once included costs this facilitator its gas
  // and the payer nothing. Each such revert is charged to the payer whose signature was verified,
  // and a payer with FAILURE_BUDGET of them inside FAILURE_WINDOW_MS is refused until they age out.
  const FAILURE_BUDGET = 3;
  const FAILURE_WINDOW_MS = 3_600_000;
  const failures = new Map(); // payer -> timestamps of reverted settlements
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
  // The payer named by a request, for answers produced before check() got far enough to find it.
  const payerOf = (body) => {
    const pl = body?.paymentPayload?.payload;
    let from;
    if (pl?.session !== undefined) {
      const known = isBytes32(pl.session?.sessionId) ? sessions.get(lc(pl.session.sessionId)) : null;
      from = known?.funder ?? pl.session?.open?.funder;
    } else from = pl?.vaultPay !== undefined ? pl.vaultPay?.intent?.payer : pl?.authorization?.from;
    return isAddress(from) ? lc(from) : undefined;
  };
  // The idempotency key, taken from the same field check() dispatches on, so that the key and the
  // path that was checked can never describe two different payments. For a vault intent it is
  // (payer, router, salt): a payer's salts are its nonces, and the router's own replay guard is the
  // backstop on-chain.
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

  /**
   * The validity window, against chain time (the clock the contracts check): validBefore must
   * leave SKEW seconds for the transaction to land, and may not reach further than the
   * requirement's (capped) maxTimeoutSeconds. null when the window is acceptable.
   */
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

  /** The vault path of check(): a PayIntent for VaultPayRouter and an optional share permit. */
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
    // Only the router this facilitator knows, and only vaults it has chosen: it pays the gas for
    // every attempt, so it does not take a contract a payer picked.
    if (!A.vaultRouter || lc(vp.router) !== A.vaultRouter) return bad('unsupported_vault_router', payer);
    if (!A.vaults.includes(vault)) return bad('unsupported_vault', payer);
    if (forbiddenPayTo.has(payTo)) return bad('invalid_pay_to', payer);
    if (BigInt(r.amount) === 0n) return bad('invalid_payment_requirements', payer);
    if (lc(it.payTo) !== payTo) return bad('invalid_exact_evm_payload_recipient_mismatch', payer);
    if (lc(it.asset) !== lc(r.asset)) return bad('unsupported_asset', payer);
    if (BigInt(it.assets) !== BigInt(r.amount)) return bad('invalid_exact_evm_payload_authorization_value', payer);
    // A permit that lapses before the intent would simulate cleanly and revert once included; the
    // router refuses it too, but here it costs nothing to say so.
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
      await chain.call(tx.to, tx.sig, tx.args, { from }); // exactly what /settle would send
    } catch (e) {
      return bad(reasonOf(e) || 'unexpected_verify_error', payer);
    }
    return { isValid: true, payer, mode: 'vault', tx, digest };
  }

  /**
   * The session path of check(). A voucher on a session that exists is checked by simulating its
   * redemption, which is exactly what will pay the merchant later: signature, deposit, expiry and
   * the token's own transfer to the payee. A voucher on a session that does not exist yet must come
   * with the open, which is simulated instead, and the voucher is checked against the key the open
   * names.
   */
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
      // Each call must add at least the price to everything already accepted or claimed.
      const floor = (s.accepted ?? 0n) > s.claimed ? s.accepted : s.claimed;
      if (cumulative < floor + price) return bad('session_voucher_stale', payer);
      try {
        await chain.call(A.sessionEscrow, 'redeem(bytes32,uint256,bytes)', [id, String(cumulative), voucher], { from });
      } catch (e) {
        const reason = reasonOf(e) || 'invalid_session_voucher';
        if (known && reason === 'session_closed') known.closed = true; // the payee closed it: never redeem it again
        return bad(reason, payer);
      }
      return { isValid: true, payer, mode: 'session', id, cumulative, voucher, snapshot: s };
    }

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
    // Useful to the merchant once open, and within the escrow's bounds whenever the authorization
    // lands (as late as validBefore).
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
      await chain.call(tx.to, tx.sig, tx.args, { from }); // exactly what /settle sends
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

  // One settlement at a time per session, so two calls carrying vouchers on the same session are
  // compared against each other, never both against the same old state.
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

  /** What became of an open whose receipt was not read: 'ok', 'reverted' or 'unknown'. */
  async function openOutcome(pending) {
    if (!pending.hash) return 'unknown';
    try {
      const status = String((await chain.receipt(pending.hash)).status);
      if (['0x1', '1', 'true'].includes(status)) return 'ok';
      if (['0x0', '0', 'false'].includes(status)) return 'reverted';
    } catch {
      /* not known yet */
    }
    return 'unknown';
  }

  /**
   * /settle for a session voucher. Opens the session if this call carries the open (the only
   * transaction a session costs before redemption), then records the voucher. Answers paid only
   * once the voucher is on disk.
   */
  async function settleSession(body) {
    const fail = (errorReason, payer, transaction = '') => ({ success: false, errorReason, payer: payer ?? '', transaction, network: dep.network });
    const sp = body?.paymentPayload?.payload?.session;
    if (!isBytes32(sp?.sessionId)) return fail('invalid_payload', payerOf(body));
    const id = lc(sp.sessionId);
    return withSessionLock(id, async () => {
      // An open broadcast earlier whose outcome was never read: resolve it before anything else, and
      // never broadcast the same authorization again while it might still be included.
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
            await chain.call(v.tx.to, v.tx.sig, v.tx.args, { from }); // again, against the latest state
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
        Object.assign(s, before); // not on disk, so not accepted: the merchant must not serve it
        return fail('unexpected_settle_error', v.payer, transaction);
      }
      return { success: true, payer: v.payer, transaction, network: dep.network, session: { id, cumulative: String(v.cumulative) } };
    });
  }

  /**
   * Redeem what is due: every session whose unredeemed vouchers reach REDEEM_THRESHOLD, have waited
   * REDEEM_MAX_AGE_MS, or whose expiry is near; everything when `force`. Each voucher is simulated on
   * its own first, so one session that can no longer pay never sinks a batch. One transaction per
   * MAX_BATCH sessions. Passes run one at a time.
   */
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
        // Claimed by someone else already, closed by the payee, or refused by the token: take the
        // chain's word for the session's state, and try again on a later pass if it is still due.
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
        // Unconfirmed: the next pass simulates again, and a voucher the chain already paid fails
        // that simulation instead of being sent twice. Anything else: nothing was sent.
        if (e instanceof UnconfirmedError) transactions.push({ hash: e.hash, ok: null, sessions: batch.length });
        continue;
      }
      if (!sent.ok) {
        transactions.push({ hash: sent.hash, ok: false, sessions: batch.length, paid: 0 });
        continue;
      }
      // redeemMany is best effort: an entry that could not pay in the block is skipped, not
      // reverted, so what was claimed is read back from the chain, never assumed.
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

  /** Everything /verify checks; on success also returns the exact transaction /settle sends. */
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
      // One payment per payload: a payload that is both an authorization and an intent could be
      // keyed as one and checked as the other.
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

    // Simulate exactly what /settle would send, from the facilitator's address.
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
      // A chain read that threw is not a verdict on the payment. Answering in the protocol's
      // own shape keeps a flaky RPC from looking like a broken facilitator, and -- because
      // settle() shares check() -- keeps a rejected promise out of the in-flight map.
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
      // Anything other than the identical request that reuses the authorization is a replay.
      return fail('invalid_exact_evm_payload_authorization_nonce_used', payerOf(body));
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
          // Unless we never learned its hash -- an ambiguous broadcast, where the node may have
          // accepted the transaction before the send call failed. There is nothing to look up,
          // and the one thing that must not happen is a retry broadcasting it again, so the
          // record is kept and the answer stays unconfirmed until an operator reconciles it
          // against the facilitator's account nonce.
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
                if (!sent.ok) {
                  chargeFailure(v.payer);
                  return fail('invalid_transaction_state', v.payer, sent.hash);
                }
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
        extra: { asset: A.usdc, escrow: A.sessionEscrow, ...dep.domains.usdc, minRemainingSeconds: String(SESSION_MARGIN) },
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
      // Operator only, and off by default: the server listens on 127.0.0.1, and redemption spends gas.
      if (admin && req.method === 'GET' && url.pathname === '/sessions') return sendJson(res, 200, sessionList());
      if (admin && req.method === 'POST' && url.pathname === '/sessions/redeem') {
        return sendJson(res, 200, await redeemDue({ force: true }));
      }
      return sendJson(res, 404, { error: 'not found' });
    } catch (e) {
      // Answering must not throw in turn: an exception escaping this handler is an unhandled
      // rejection, and Node 22 ends the process on one, so a single awkward request would take
      // the facilitator down for everybody.
      try {
        if (e.status === 413) closeAfter(req, res); // answer first, then close the connection
        if (!res.headersSent) sendJson(res, e.status || 500, { error: e.status ? e.message : 'internal error' });
        else if (!res.writableEnded) res.end();
      } catch {
        /* the connection is already gone */
      }
    }
  });

  // Redemption runs on its own clock, so vouchers are settled whether or not calls keep coming.
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

if (import.meta.url === `file://${process.argv[1]}`) {
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

#!/usr/bin/env node
// x402 client for an agent whose treasury is one sUSD balance: it earns while idle and pays
// x402 bills directly. The agent never manages a vault or a USDC float.
//
// For each 402 the client picks the first option that fits the balances and the spend policy:
//   sUSD     the merchant prices in sUSD: sign an EIP-3009 transfer to payTo
//   router   the merchant prices in USDC and offers the Spectrum router: sign a receive
//            authorization of sUSD to the router. Its nonce commits to (payTo, amount, salt), so
//            only that payment can be made with it. The merchant gets exact USDC and the change
//            comes back.
//   USDC     the agent holds USDC: a standard x402 USDC authorization
//   vault    the merchant prices in USDC and offers VaultPayRouter, and the agent holds shares of
//            a vault over USDC (on Base, Aave's waBasUSDC): sign a PayIntent, plus an EIP-2612
//            permit on the shares when the standing allowance falls short. The router withdraws
//            exactly the price, pays the merchant, returns the rest. Nothing is issued.
//   convert  the merchant takes only plain USDC: convert just enough sUSD to USDC through the
//            facilitator's /convert, then pay in USDC
//   session  the merchant offers an x402 session on X402SessionEscrow: deposit once (a gasless
//            EIP-3009 open the facilitator submits), then send a voucher with each call, the
//            cumulative amount owed so far. A session already open with that merchant pays without
//            a single chain read. Every signed voucher counts against the budget at once, served or
//            not: it is money the merchant could redeem.
//
// Trust: token, routers, vaults and EIP-712 domains come from the agent's own deployment files,
// never from the merchant's 402. A merchant-supplied router address is ignored unless it is the
// known router, because a receive authorization lets its `to` move the whole value.
//
// Library: createAgent({ rpcUrl, signer, payer?, facilitatorUrl?, policy? }).
// CLI:     agent.mjs address | balance | sessions | pay <url> [--prefer <mode>] [--out <file>] [--times <n>]
//                    | convert <usd> | sweep <to>
//          Env: RPC_URL, AGENT_KEYSTORE, AGENT_PASSWORD_FILE, AGENT_PAYER (an ERC-1271 account
//          the key controls), FACILITATOR_URL, AGENT_MAX_PER_REQUEST and AGENT_BUDGET (USD),
//          AGENT_ALLOWED_PAYTO (comma-separated), AGENT_LEDGER (a JSON file that keeps the
//          amount spent and the open sessions across runs), AGENT_SESSION_DEPOSIT and
//          AGENT_MAX_SESSION_DEPOSIT (USD), AGENT_SESSION_SECONDS, AGENT_PATH (an X402SessionPaths path
//          id: the agent then holds no money, and opens every session as a step on its owner's path),
//          AGENT_TIMEOUT_S (seconds one HTTP request may take, default 30), AGENT_MAX_PER_MINUTE (USD
//          spent in any minute), AGENT_MAX_UNDELIVERED (paid calls in a row a merchant may fail before
//          it is paused, default 2), AGENT_BREAKER_SECONDS (how long, default 600) and
//          AGENT_PATH_MERCHANTS (the path's merchants, comma-separated, for the per-merchant ceiling).
//
// Signed is spent, in every mode: a voucher or an EIP-3009 authorization counts against the budget
// when it is signed, whatever the merchant answers. A one-off authorization that expires unused is
// released again by reconcile(). A merchant that is paid and does not serve (any status other than
// 2xx, or no answer before the timeout) is paused after AGENT_MAX_UNDELIVERED such calls in a row.

import { randomBytes } from 'node:crypto';
import {
  closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync, writeSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { abiEncode, first, keccak, makeChain, signTypedData, signerAddress } from './lib/cast.mjs';
import { isMain } from './lib/cli.mjs';
import { loadDeployment } from './lib/config.mjs';
import {
  X402_VERSION, HEADER, HEADER_V1, V1_NETWORKS, encode, decode, lc, isAddress, isUint, authorizationTypedData,
  vaultIntentTypedData, permitTypedData, splitSignature, voucherTypedData, pathStepTypedData, isBytes32,
} from './lib/protocol.mjs';
import { MAX_DURATION, MIN_DURATION, openNonce, readPath, readSession, sessionIdOf } from './lib/session.mjs';

export class PolicyError extends Error {
  constructor(message) {
    super(message);
    this.name = 'PolicyError';
  }
}

const SCALE = 10n ** 12n; // sUSD has 18 decimals, USDC 6
// Preference order. USDC the agent already holds is spent before the router is used: that
// change is idle, non-earning money, and spending it costs no redeem fee, whereas routing
// redeems more of the earning balance and hands back yet more idle change. Routing comes before
// convert because it is one transaction instead of two (A-04).
// A vault position is spent after idle USDC, for the same reason, and before the sUSD router.
// A new session comes last: it locks a deposit, which a one-off call does not justify. A session
// that is already open with the merchant comes first (see choose()).
const MODES = ['sUSD', 'USDC', 'vault', 'router', 'convert', 'session'];

/** "1.25" (US dollars) -> 1_250_000n (6 decimals). */
export function parseUsd(s) {
  const m = /^(\d+)(?:\.(\d{1,6}))?$/.exec(String(s).trim());
  if (!m) throw new Error(`not a dollar amount: ${s}`);
  return BigInt(m[1]) * 1_000_000n + BigInt((m[2] || '').padEnd(6, '0'));
}

/** 1_250_000n with 6 decimals -> "1.25". */
export function formatUnits(x, decimals) {
  const neg = x < 0n;
  const v = neg ? -x : x;
  const base = 10n ** BigInt(decimals);
  const frac = (v % base).toString().padStart(decimals, '0').replace(/0+$/, '');
  return `${neg ? '-' : ''}${v / base}${frac ? '.' + frac : ''}`;
}

const rand32 = () => '0x' + randomBytes(32).toString('hex');
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

// One spending ledger per wallet, shared by every process that pays from it (Claude Desktop and any
// number of Claude Code or Cursor sessions start one server each). A paid call holds the ledger's
// lock file from its first check to its last bookkeeping and reads the ledger afresh under it.
const LOCK_WAIT_MS = 120_000; // longer than one paid call can last (two requests of AGENT_TIMEOUT_S, plus reads)
const LOCK_STALE_MS = 300_000; // a lock older than this was left by a process that died holding it
const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e?.code === 'EPERM';
  }
};

/** The ledger as stored, with every field this agent keeps; an unreadable file stops all payments. */
function readLedger(file) {
  let l = { spent: '0', payments: [] };
  if (file && existsSync(file)) {
    try {
      l = JSON.parse(readFileSync(file, 'utf8'));
    } catch (e) {
      throw new Error(`the spending ledger ${file} cannot be read (${e.message}); nothing is paid until it is repaired or removed`);
    }
  }
  l.spent ??= '0';
  l.payments ??= [];
  l.sessions ??= {}; // open sessions, by escrow:payee:token
  l.retired ??= []; // sessions replaced by a newer one; what is left in them returns at expiry
  l.breakers ??= {}; // merchants paused after failing calls they were paid for, by payTo
  l.recent ??= []; // what was charged in the last 30 days, for the minute, day, week and month caps
  return l;
}

/**
 * The hardening settings, read the same way by the CLI, the MCP server and the service:
 * AGENT_TIMEOUT_S, AGENT_MAX_PER_MINUTE (USD), AGENT_MAX_UNDELIVERED, AGENT_BREAKER_SECONDS and
 * AGENT_PATH_MERCHANTS.
 */
export function policyFromEnv(env = process.env) {
  const num = (k, d) => {
    if (env[k] === undefined || env[k] === '') return d;
    const n = Number(env[k]);
    if (!Number.isFinite(n) || n <= 0) throw new Error(`${k} must be a positive number, not ${env[k]}`);
    return n;
  };
  return {
    timeoutMs: num('AGENT_TIMEOUT_S', 30) * 1000,
    maxPerMinute: env.AGENT_MAX_PER_MINUTE ? parseUsd(env.AGENT_MAX_PER_MINUTE) : null,
    maxPerDay: env.AGENT_MAX_PER_DAY ? parseUsd(env.AGENT_MAX_PER_DAY) : null,
    maxPerWeek: env.AGENT_MAX_PER_WEEK ? parseUsd(env.AGENT_MAX_PER_WEEK) : null,
    maxPerMonth: env.AGENT_MAX_PER_MONTH ? parseUsd(env.AGENT_MAX_PER_MONTH) : null,
    maxUndelivered: num('AGENT_MAX_UNDELIVERED', 2),
    breakerSeconds: num('AGENT_BREAKER_SECONDS', 600),
    pathMerchants: env.AGENT_PATH_MERCHANTS ? env.AGENT_PATH_MERCHANTS.split(',').map((x) => x.trim()).filter(Boolean) : null,
  };
}

export async function createAgent({
  rpcUrl, signer, payer, facilitatorUrl, policy = {}, ledgerFile, tmpDir, path, chain: given, userAgent,
}) {
  // A key-file signer needs no Foundry: it signs in JavaScript and reads over JSON-RPC. Tests pass
  // their own `chain`.
  const chain = given || makeChain(rpcUrl, { js: signer?.kind === 'key' ? true : undefined });
  const dep = await loadDeployment(chain);
  const A = dep.addresses;
  const owner = await signerAddress(signer);
  const from = lc(payer || owner);
  if (!isAddress(from)) throw new Error(`bad payer address ${payer}`);
  const work = tmpDir || mkdtempSync(join(tmpdir(), 'x402-agent-'));
  // The agent's X402SessionPaths path, if its owner keeps its money in one: then this key holds
  // nothing, and every session it opens is a step toward the end the owner declared.
  if (path !== undefined && path !== null && !isBytes32(path)) throw new Error(`bad path id ${path}`);
  const pathId = path ? lc(path) : null;

  const limits = {
    maxPerRequest: policy.maxPerRequest ?? null, // bigint, USD with 6 decimals
    budget: policy.budget ?? null, // bigint, USD with 6 decimals
    allowedPayTo: policy.allowedPayTo ? new Set(policy.allowedPayTo.map(lc)) : null,
    sessionDeposit: policy.sessionDeposit ?? null, // bigint, USDC units: overrides the merchant's suggestion
    maxSessionDeposit: policy.maxSessionDeposit ?? null, // bigint, USDC units
    sessionSeconds: policy.sessionSeconds ?? 86_400n, // bigint
    timeoutMs: policy.timeoutMs ?? 30_000, // number: the longest one HTTP request may take
    maxPerMinute: policy.maxPerMinute ?? null, // bigint, USD with 6 decimals: spent in any 60 s
    maxPerDay: policy.maxPerDay ?? null, // bigint: signed in any 24 hours
    maxPerWeek: policy.maxPerWeek ?? null, // bigint: signed in any 7 days
    maxPerMonth: policy.maxPerMonth ?? null, // bigint: signed in any 30 days
    maxUndelivered: policy.maxUndelivered ?? 2, // paid calls in a row a merchant may leave unserved
    breakerSeconds: policy.breakerSeconds ?? 600, // how long such a merchant is paused
    pathMerchants: policy.pathMerchants ?? null, // payees to show in pathState(), besides those paid
  };
  if (ledgerFile) mkdirSync(dirname(ledgerFile), { recursive: true, mode: 0o700 });
  const ledger = readLedger(ledgerFile);
  let spent = BigInt(ledger.spent);
  /** Replace the ledger in memory with the one on disk (under the lock: see withLedger). */
  const reloadLedger = () => {
    const fresh = readLedger(ledgerFile);
    for (const k of Object.keys(ledger)) delete ledger[k];
    Object.assign(ledger, fresh);
    spent = BigInt(ledger.spent);
  };
  // What was charged in the last minute, for the spend-rate limit. It lives in the ledger, so the
  // limit holds for the wallet across processes, like the budget.
  const charge = (usd) => {
    ledger.recent.push({ at: Date.now(), usd: String(usd) });
  };
  const MINUTE = 60_000;
  const DAY = 86_400_000;
  // Rolling windows over every instrument signed (released ones included: the caps bound how fast
  // the agent signs, the budget bounds what it spends).
  const WINDOWS = [
    ['minute', MINUTE, () => limits.maxPerMinute, 'in the last minute'],
    ['day', DAY, () => limits.maxPerDay, 'in the last 24 hours'],
    ['week', 7 * DAY, () => limits.maxPerWeek, 'in the last 7 days'],
    ['month', 30 * DAY, () => limits.maxPerMonth, 'in the last 30 days'],
  ];
  const spentWithin = (ms) => {
    const since = Date.now() - ms;
    return ledger.recent.reduce((a, x) => (x.at >= since ? a + BigInt(x.usd) : a), 0n);
  };
  const spentLastMinute = () => spentWithin(MINUTE);
  /** Spent in each capped window: [{ name, spent, cap, what }]. */
  const windows = () => WINDOWS.filter(([, , cap]) => cap() != null)
    .map(([name, ms, cap, what]) => ({ name, spent: spentWithin(ms), cap: cap(), what }));
  /**
   * Run `fn` holding the wallet's ledger lock, with the ledger read afresh from disk: every check
   * and every count in `fn` then sees what all processes paying from this wallet have spent.
   */
  async function withLedger(fn) {
    if (!ledgerFile) return fn();
    const lock = `${ledgerFile}.lock`;
    const started = Date.now();
    for (;;) {
      try {
        const fd = openSync(lock, 'wx');
        try {
          writeSync(fd, JSON.stringify({ pid: process.pid, at: Date.now() }));
        } finally {
          closeSync(fd);
        }
        break;
      } catch (e) {
        if (e?.code !== 'EEXIST') throw e;
        let holder = null;
        let age = 0;
        try {
          holder = JSON.parse(readFileSync(lock, 'utf8'));
          age = Date.now() - statSync(lock).mtimeMs;
        } catch {
          // being written or just released: look again
        }
        if (age > LOCK_STALE_MS || (Number.isInteger(holder?.pid) && holder.pid !== process.pid && !alive(holder.pid))) {
          try {
            unlinkSync(lock);
          } catch {
            // another process broke it first
          }
          continue;
        }
        if (Date.now() - started > LOCK_WAIT_MS) {
          throw new Error('another process is paying from this wallet and has not finished; nothing was paid, try again shortly');
        }
        await pause(25 + Math.floor(Math.random() * 75));
      }
    }
    try {
      reloadLedger();
      return await fn();
    } finally {
      try {
        unlinkSync(lock);
      } catch {
        // already gone
      }
    }
  }
  // A paid call is served (2xx) or it is not: any other status, or no answer in time. Unserved
  // calls in a row pause the merchant; a served one resets the count.
  const noteOutcome = (payTo, outcome) => {
    const k = lc(payTo);
    if (outcome === 'delivered') {
      if (ledger.breakers[k]) {
        delete ledger.breakers[k];
        saveLedger();
      }
      return;
    }
    const b = (ledger.breakers[k] ??= { failed: 0, until: 0 });
    b.failed += 1;
    if (b.failed >= limits.maxUndelivered) b.until = Date.now() + limits.breakerSeconds * 1000;
    saveLedger();
  };
  const outcomeOf = (status) => (status >= 200 && status < 300 ? 'delivered' : 'failed');
  const timeoutError = (phase) => `no answer within ${limits.timeoutMs / 1000} s ${phase}`;
  // Never throws: the ledger in memory is the authority, and an error here (a full disk) must not
  // turn a payment that already left into an exception a caller would retry.
  // Written whole to a temporary file and renamed over the old one, so a crash mid-write never
  // leaves a ledger that cannot be read.
  const saveLedger = () => {
    if (!ledgerFile) return;
    try {
      const keep = Date.now() - 30 * DAY; // the longest window
      ledger.recent = ledger.recent.filter((x) => x.at >= keep);
      const tmp = `${ledgerFile}.${process.pid}.tmp`;
      writeFileSync(tmp, JSON.stringify(ledger, null, 2), { mode: 0o600 });
      renameSync(tmp, ledgerFile);
    } catch (e) {
      console.error(`could not save the ledger: ${e.message}`);
    }
  };

  const usdOf = (mode, cost) => (mode === 'USDC' || mode === 'vault' || mode === 'session' ? cost : (cost + SCALE - 1n) / SCALE);

  async function balances() {
    const vaults = {};
    for (const v of A.vaults) {
      vaults[v] = {
        shares: await chain.uint(v, 'balanceOf(address)(uint256)', [from]),
        usdc: await chain.uint(v, 'maxWithdraw(address)(uint256)', [from]),
      };
    }
    return {
      sUSD: A.sUSD ? await chain.uint(A.sUSD, 'balanceOf(address)(uint256)', [from]) : 0n,
      usdc: await chain.uint(A.usdc, 'balanceOf(address)(uint256)', [from]),
      vaults,
    };
  }

  // A vault's EIP-712 domain, rebuilt from its ERC-5267 eip712Domain() and accepted only if it
  // hashes to the vault's own DOMAIN_SEPARATOR(): a permit signed over any other domain would not
  // verify, so it is never signed.
  const domains = new Map();
  async function vaultDomain(vault) {
    if (domains.has(vault)) return domains.get(vault);
    const out = (await chain.call(vault, 'eip712Domain()(bytes1,string,string,uint256,address,bytes32,uint256[])'))
      .split('\n').map((l) => l.trim());
    const unq = (x) => String(x).replace(/^"|"$/g, '');
    const [fields, name, version, chainId, verifying] = [out[0], unq(out[1]), unq(out[2]), first(out[3]), lc(out[4])];
    if (lc(fields) !== '0x0f' || BigInt(chainId) !== BigInt(dep.chainId) || verifying !== vault) {
      throw new Error(`vault ${vault} uses an EIP-712 domain this agent does not sign for`);
    }
    const typeHash = keccak('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');
    const encoded = abiEncode('f(bytes32,bytes32,bytes32,uint256,address)', [
      typeHash, keccak(name), keccak(version), String(dep.chainId), vault,
    ]);
    const rebuilt = lc(keccak(encoded));
    if (rebuilt !== lc(first(await chain.call(vault, 'DOMAIN_SEPARATOR()(bytes32)')))) {
      throw new Error(`could not reproduce the EIP-712 domain of vault ${vault}`);
    }
    const d = { name, version };
    domains.set(vault, d);
    return d;
  }

  async function timeWindow(maxTimeoutSeconds) {
    const now = await chain.timestamp(); // chain time: the clock the token contract checks
    const t = BigInt(Math.max(10, Math.min(Number(maxTimeoutSeconds ?? 60), 600)));
    return { validAfter: String(now > 600n ? now - 600n : 0n), validBefore: String(now + t) };
  }

  function sign(primaryType, token, message) {
    const domain = token === A.sUSD ? dep.domains.sUSD : dep.domains.usdc;
    const typed = authorizationTypedData({
      primaryType, name: domain.name, version: domain.version, chainId: dep.chainId, verifyingContract: token, message,
    });
    return signTypedData(typed, signer, work);
  }

  // ------------------------------------------------------------------------------------- sessions

  /** A session requirement this agent can pay: its own escrow, in USDC, on this chain. */
  const sessionRequirement = (r) =>
    r?.scheme === 'session' && r.network === dep.network && isAddress(r.payTo) && isUint(r.amount) && BigInt(r.amount) > 0n &&
    !!A.sessionEscrow && lc(r.extra?.escrow) === A.sessionEscrow && lc(r.asset) === A.usdc;
  const sessionKey = (r) => `${A.sessionEscrow}:${lc(r.payTo)}:${lc(r.asset)}`;
  // The shortest remaining life the merchant accepts (and never under the 15 minutes facilitators
  // keep for getting a redemption in before expiry), plus a minute so the voucher is not refused on
  // the way.
  const minRemainingOf = (r) => {
    const asked = isUint(r?.extra?.minRemainingSeconds) ? BigInt(r.extra.minRemainingSeconds) : 0n;
    return (asked > 900n ? asked : 900n) + 60n;
  };
  // Answers that mean the session itself can take no more calls: closed by the payee, too near its
  // expiry, unknown on-chain, or spent.
  const DEAD_SESSION = new Set([
    'session_closed', 'session_expiring', 'unknown_session', 'session_above_deposit', 'invalid_session_payee', 'invalid_session_asset',
    'path_step_stale',
  ]);

  // Chain time, read at most every 15 s and carried forward by the local clock in between, so a
  // call on an open session costs no chain read at all.
  let clock = null;
  const chainNow = async () => {
    if (!clock || Date.now() - clock.at > 15_000) clock = { t: await chain.timestamp(), at: Date.now() };
    return clock.t + BigInt(Math.floor((Date.now() - clock.at) / 1000));
  };

  // Vault payments sent but not settled, by what they pay for, and the ledger row that counts each
  // (see pay()).
  const unsettled = new Map();
  const vaultRows = new Map();

  // Calls on one session go out one at a time: vouchers are cumulative, so they must arrive in order.
  const locks = new Map();
  const withLock = (key, fn) => {
    const run = (locks.get(key) || Promise.resolve()).then(fn, fn);
    const tail = run.then(() => {}, () => {});
    locks.set(key, tail);
    tail.then(() => {
      if (locks.get(key) === tail) locks.delete(key);
    });
    return run;
  };

  /** The open session that can pay `r` now, or null if a new one is needed. */
  async function usableSession(r) {
    const s = ledger.sessions[sessionKey(r)];
    if (!s) return null;
    const now = await chainNow();
    if (BigInt(s.deposit) - BigInt(s.cumulative) < BigInt(r.amount)) return null;
    if (BigInt(s.expiry) < now + minRemainingOf(r)) return null;
    const pending = s.open ?? s.pathStep ?? null;
    if (pending && BigInt(s.open ? s.open.validBefore : s.pathStep.deadline) <= now + 15n) {
      // The open is about to lapse. If the facilitator did open the session, carry on with it; if
      // not, it never can now, and a new session is needed.
      if (!(await readSession(chain, s.escrow, s.sessionId))) return null;
      s.open = null;
      s.pathStep = null;
      saveLedger();
    }
    return s;
  }

  /** A new session opened from the agent's path: a step toward the owner's end, signed by this key. */
  async function newPathSession(r) {
    const price = BigInt(r.amount);
    const payee = lc(r.payTo);
    if (!A.sessionPaths) throw new Error('this chain has no X402SessionPaths deployment');
    const p = await readPath(chain, A.sessionPaths, pathId);
    if (!p || p.ended) throw new PolicyError("this agent's path is not open");
    if (p.agent !== owner) throw new Error(`the path's agent is ${p.agent}, not this key`);
    if (p.token !== A.usdc) throw new Error('the path holds another token');
    const cap = await chain.uint(A.sessionPaths, 'capOf(bytes32,address)(uint256)', [pathId, payee]);
    if (cap === 0n) throw new PolicyError(`${payee} is not on this agent's path`);
    const committed = await chain.uint(A.sessionPaths, 'committedTo(bytes32,address)(uint256)', [pathId, payee]);
    let deposit = limits.sessionDeposit ?? (isUint(r.extra?.suggestedDeposit) ? BigInt(r.extra.suggestedDeposit) : price * 1000n);
    if (limits.maxSessionDeposit != null && deposit > limits.maxSessionDeposit) deposit = limits.maxSessionDeposit;
    if (deposit > cap - committed) deposit = cap - committed;
    if (deposit > p.free) deposit = p.free;
    if (limits.budget != null && deposit > limits.budget - spent) deposit = limits.budget - spent;
    if (deposit < price) throw new PolicyError(`the path has no room left for ${payee}`);
    const w = await timeWindow(r.maxTimeoutSeconds);
    const now = BigInt(w.validBefore) - BigInt(Math.max(10, Math.min(Number(r.maxTimeoutSeconds ?? 60), 600)));
    let expiry = now + limits.sessionSeconds;
    const floor = BigInt(w.validBefore) + MIN_DURATION + 300n;
    if (expiry < floor) expiry = floor;
    if (expiry < now + minRemainingOf(r) + 600n) expiry = now + minRemainingOf(r) + 600n;
    if (expiry > p.expiry) expiry = p.expiry;
    if (expiry < floor || expiry < now + minRemainingOf(r)) throw new PolicyError('the path ends too soon for a new session');
    const salt = rand32();
    const sessionId = await sessionIdOf({ funder: A.sessionPaths, payee, token: A.usdc, signer: owner, expiry, salt });
    const step = {
      pathId, payee, signer: owner, expiry: String(expiry), salt, amount: String(deposit), committed: String(committed),
      deadline: w.validBefore,
    };
    const signature = await signTypedData(pathStepTypedData({ chainId: dep.chainId, paths: A.sessionPaths, step }), signer, work);
    const s = {
      sessionId, escrow: A.sessionEscrow, payee, token: A.usdc, funder: A.sessionPaths, signer: owner, salt, path: pathId,
      expiry: String(expiry), deposit: String(deposit), cumulative: '0', calls: 0, served: 0, openedAt: new Date().toISOString(),
      pathStep: { ...step, signature },
    };
    delete s.pathStep.payee; // the payee is the requirement's payTo
    const key = sessionKey(r);
    if (ledger.sessions[key]) ledger.retired.push(ledger.sessions[key]);
    ledger.sessions[key] = s;
    saveLedger();
    return s;
  }

  /** Sign the open of a new session with the merchant of `r`: a deposit, an expiry, this agent's key. */
  async function newSession(r) {
    if (pathId) return newPathSession(r);
    const price = BigInt(r.amount);
    const payee = lc(r.payTo);
    let deposit = limits.sessionDeposit ?? (isUint(r.extra?.suggestedDeposit) ? BigInt(r.extra.suggestedDeposit) : price * 1000n);
    if (limits.maxSessionDeposit != null && deposit > limits.maxSessionDeposit) deposit = limits.maxSessionDeposit;
    if (limits.budget != null && deposit > limits.budget - spent) deposit = limits.budget - spent; // never lock more than it may spend
    const held = await chain.uint(A.usdc, 'balanceOf(address)(uint256)', [from]);
    if (deposit > held) deposit = held;
    if (deposit < price) {
      if (held < price) throw new Error('insufficient funds for a session deposit');
      throw new PolicyError(`policy allows no session deposit of at least $${formatUnits(price, 6)}`);
    }
    const w = await timeWindow(r.maxTimeoutSeconds);
    const now = BigInt(w.validBefore) - BigInt(Math.max(10, Math.min(Number(r.maxTimeoutSeconds ?? 60), 600)));
    // Long enough for the merchant's minimum and for the escrow's MIN_DURATION at the latest moment
    // the open can land (validBefore), and never beyond MAX_DURATION.
    let expiry = now + limits.sessionSeconds;
    const floor = BigInt(w.validBefore) + MIN_DURATION + 300n;
    if (expiry < floor) expiry = floor;
    if (expiry < now + minRemainingOf(r) + 600n) expiry = now + minRemainingOf(r) + 600n;
    if (expiry > now + MAX_DURATION - 600n) expiry = now + MAX_DURATION - 600n;
    const salt = rand32();
    const sessionId = await sessionIdOf({ funder: from, payee, token: A.usdc, signer: owner, expiry, salt });
    const nonce = await openNonce({ payee, token: A.usdc, signer: owner, expiry, salt });
    const authorization = await sign('ReceiveWithAuthorization', A.usdc, {
      from, to: A.sessionEscrow, value: String(deposit), validAfter: w.validAfter, validBefore: w.validBefore, nonce,
    });
    const s = {
      sessionId, escrow: A.sessionEscrow, payee, token: A.usdc, funder: from, signer: owner, salt,
      expiry: String(expiry), deposit: String(deposit), cumulative: '0', calls: 0, served: 0, openedAt: new Date().toISOString(),
      open: {
        funder: from, signer: owner, expiry: String(expiry), salt, amount: String(deposit), validAfter: w.validAfter,
        validBefore: w.validBefore, authorization,
      },
    };
    const key = sessionKey(r);
    if (ledger.sessions[key]) ledger.retired.push(ledger.sessions[key]);
    ledger.sessions[key] = s;
    saveLedger();
    return s;
  }

  /** The next voucher on the session for `o.r` (opening one first if none can pay). */
  async function authorizeSession(o) {
    const price = BigInt(o.r.amount);
    const s = (await usableSession(o.r)) ?? (await newSession(o.r));
    const cumulative = BigInt(s.cumulative) + price;
    const voucher = await signTypedData(
      voucherTypedData({ chainId: dep.chainId, escrow: s.escrow, sessionId: s.sessionId, cumulative }), signer, work,
    );
    // Signed is spent: the merchant may redeem this voucher whether or not it serves the call.
    s.cumulative = String(cumulative);
    s.calls += 1;
    spent += price;
    charge(price);
    ledger.spent = String(spent);
    saveLedger();
    return {
      session: {
        escrow: s.escrow, sessionId: s.sessionId, cumulative: String(cumulative), voucher, ...(s.open ? { open: s.open } : {}),
        ...(s.pathStep ? { pathStep: s.pathStep } : {}),
      },
    };
  }

  /** The ways this agent could pay each requirement, cheapest-to-run first. */
  async function options(accepts) {
    const bal = await balances();
    const out = [];
    for (const r of Array.isArray(accepts) ? accepts : []) {
      if (sessionRequirement(r)) {
        const live = !!(await usableSession(r));
        // A path agent holds nothing itself: its path funds the session, and refuses what it cannot.
        out.push({ mode: 'session', r, cost: BigInt(r.amount), live, have: live || !!pathId || bal.usdc >= BigInt(r.amount) });
        continue;
      }
      if (r?.scheme !== 'exact' || r.network !== dep.network || !isAddress(r.payTo) || !isUint(r.amount)) continue;
      const amount = BigInt(r.amount);
      if (amount === 0n) continue;
      const asset = lc(r.asset);
      if (asset === A.sUSD) {
        out.push({ mode: 'sUSD', r, cost: amount, have: bal.sUSD >= amount });
      } else if (asset === A.usdc) {
        out.push({ mode: 'USDC', r, cost: amount, have: bal.usdc >= amount });
        if (A.router) {
          const value = await chain.uint(A.router, 'sUSDToAuthorize(uint256)(uint256)', [r.amount]);
          if (lc(r.extra?.spectrumRouter) === A.router) out.push({ mode: 'router', r, cost: value, have: bal.sUSD >= value });
          if (facilitatorUrl) out.push({ mode: 'convert', r, cost: value, have: bal.sUSD >= value });
        }
        // Only the agent's own router, and only vaults both sides accept.
        if (A.vaultRouter && lc(r.extra?.vaultRouter) === A.vaultRouter) {
          const offered = Array.isArray(r.extra?.vaults) ? r.extra.vaults.map(lc) : [];
          for (const vault of A.vaults.filter((v) => offered.includes(v))) {
            out.push({ mode: 'vault', r, vault, cost: amount, have: bal.vaults[vault].usdc >= amount });
          }
        }
      }
    }
    return out.map((o) => ({ ...o, usd: usdOf(o.mode, o.cost) }));
  }

  function refusal(o) {
    if (limits.allowedPayTo && !limits.allowedPayTo.has(lc(o.r.payTo))) return `payTo ${o.r.payTo} is not on the allow list`;
    if (limits.maxPerRequest != null && o.usd > limits.maxPerRequest) {
      return `price $${formatUnits(o.usd, 6)} is above the per-request limit of $${formatUnits(limits.maxPerRequest, 6)}`;
    }
    if (limits.budget != null && spent + o.usd > limits.budget) {
      return `budget exhausted: $${formatUnits(spent, 6)} of $${formatUnits(limits.budget, 6)} spent`;
    }
    const b = ledger.breakers[lc(o.r.payTo)];
    if (b?.until > Date.now()) {
      return `merchant ${o.r.payTo} is paused until ${new Date(b.until).toISOString()}: it was paid for calls in a row it did not serve`;
    }
    for (const w of windows()) {
      if (w.spent + o.usd > w.cap) {
        return `${w.name === 'minute' ? 'spend rate limit' : `${w.name} cap`}: $${formatUnits(w.spent, 6)} spent ${w.what}, at most $${formatUnits(w.cap, 6)}`;
      }
    }
    return null;
  }

  /**
   * Pick how to pay: the first mode in preference order that is funded and allowed. `only`, if
   * given, is the set of modes the offer's protocol can carry (version 1: a plain token transfer).
   */
  async function choose(accepts, prefer, only = null) {
    // A session already open with this merchant pays first, and without reading any balance.
    if ((!prefer || prefer === 'session') && (!only || only.has('session'))) {
      for (const r of Array.isArray(accepts) ? accepts : []) {
        if (!sessionRequirement(r)) continue;
        const o = { mode: 'session', r, cost: BigInt(r.amount), usd: BigInt(r.amount), live: true, have: true };
        if (!refusal(o) && (await usableSession(r))) return o;
      }
    }
    const all = (await options(accepts)).filter((o) => !only || only.has(o.mode));
    if (!all.length) {
      const offered = (Array.isArray(accepts) ? accepts : []).map((r) => `${r?.scheme} on ${r?.network}`).join(', ');
      throw new Error(`no payment option this agent can pay: it pays USDC on Base, and the server offered ${offered || 'nothing'}`);
    }
    const order = prefer ? [prefer, ...MODES.filter((m) => m !== prefer)] : MODES;
    const reasons = [];
    for (const mode of order) {
      for (const o of all.filter((x) => x.mode === mode)) {
        const why = refusal(o);
        if (why) reasons.push(why);
        else if (o.have) return o;
      }
    }
    if (reasons.length && all.every((o) => refusal(o))) throw new PolicyError(reasons[0]);
    throw new Error('insufficient funds for every payment option');
  }

  /** Sign the authorization for option `o` (no network call except chain reads). */
  async function authorize(o) {
    if (o.mode === 'session') return authorizeSession(o);
    const { r } = o;
    const w = await timeWindow(r.maxTimeoutSeconds);
    if (o.mode === 'sUSD' || o.mode === 'USDC') {
      const token = o.mode === 'sUSD' ? A.sUSD : A.usdc;
      const authorization = { from, to: lc(r.payTo), value: String(r.amount), ...w, nonce: rand32() };
      return { signature: await sign('TransferWithAuthorization', token, authorization), authorization };
    }
    if (o.mode === 'vault') {
      // The intent binds vault, recipient, exact amount and a ceiling on shares; a submitter who
      // changes any of them invalidates the signature.
      const maxShares = await chain.uint(A.vaultRouter, 'sharesToAuthorize(address,uint256)(uint256)', [o.vault, r.amount]);
      const intent = {
        payer: from, vault: o.vault, asset: lc(r.asset), payTo: lc(r.payTo), assets: String(r.amount),
        maxShares: String(maxShares), salt: rand32(), validAfter: w.validAfter, validBefore: w.validBefore,
      };
      const signature = await signTypedData(
        vaultIntentTypedData({ chainId: dep.chainId, router: A.vaultRouter, intent }), signer, work,
      );
      // A permit only when the standing allowance falls short, and only for the exact ceiling: it
      // raises the allowance to what this payment may cost and no further.
      let permit = null;
      const allowance = await chain.uint(o.vault, 'allowance(address,address)(uint256)', [from, A.vaultRouter]);
      if (allowance < maxShares) {
        if (from !== owner) {
          throw new Error('a smart-wallet payer must approve the router once: EIP-2612 permits are signed by an EOA');
        }
        const { name, version } = await vaultDomain(o.vault);
        const nonce = await chain.uint(o.vault, 'nonces(address)(uint256)', [from]);
        const typed = permitTypedData({
          name, version, chainId: dep.chainId, verifyingContract: o.vault, owner: from, spender: A.vaultRouter,
          value: maxShares, nonce, deadline: w.validBefore,
        });
        const { v, r: pr, s } = splitSignature(await signTypedData(typed, signer, work));
        permit = { value: String(maxShares), deadline: w.validBefore, v: String(v), r: pr, s };
      }
      return { vaultPay: { router: A.vaultRouter, intent, signature, permit } };
    }
    // Router: the nonce is the payment intent, so the authorization can only pay `amount` USDC
    // to `payTo`. The router address is the one from the agent's own deployment files.
    const salt = rand32();
    const nonce = lc(first(await chain.call(A.router, 'intentNonce(address,uint256,bytes32)(bytes32)', [r.payTo, r.amount, salt])));
    const authorization = { from, to: A.router, value: String(o.cost), ...w, nonce };
    return { signature: await sign('ReceiveWithAuthorization', A.sUSD, authorization), authorization, spectrum: { salt } };
  }

  function record(entry) {
    spent += entry.usd;
    charge(entry.usd);
    ledger.spent = String(spent);
    const row = { ...entry, usd: formatUnits(entry.usd, 6), at: new Date().toISOString() };
    ledger.payments.push(row);
    saveLedger();
    return row;
  }

  /**
   * One-off EIP-3009 authorizations count against the budget from the moment they are sent, since
   * the merchant can settle them until validBefore whatever it answered. Once one has expired, the
   * token says whether it was used: unused ones are released, used ones stay spent.
   */
  function reconcile() {
    return withLock('pay', () => withLedger(reconcileNow));
  }

  async function reconcileNow() {
    let now = null;
    let released = 0n;
    for (const row of ledger.payments) {
      const q = row.pending;
      if (!q) continue;
      now ??= await chain.timestamp();
      if (BigInt(q.validBefore) >= now) continue;
      if (await chain.bool(q.token, 'authorizationState(address,bytes32)(bool)', [q.authorizer, q.nonce])) {
        row.settled = true;
      } else {
        const usd = parseUsd(row.usd);
        spent -= usd;
        released += usd;
        row.released = true;
      }
      delete row.pending;
    }
    if (now !== null) {
      ledger.spent = String(spent);
      saveLedger();
    }
    return released;
  }

  /** The settlement receipt of a paid answer (either protocol version), or null if there is none or it does not parse. */
  function receiptOf(res) {
    try {
      const h = res.headers.get(HEADER.response) ?? res.headers.get(HEADER_V1.response);
      return h ? decode(h) : null;
    } catch {
      return null;
    }
  }

  /**
   * What the offer itself says this request lacks. A v2 offer may carry the x402 bazaar extension:
   * the JSON schema of the inputs the server accepts. A request missing a required query parameter
   * or body field, or giving a value outside a listed set, would be paid for and then refused, so it
   * is not paid for. Returns null when the offer has no schema or the request satisfies it.
   */
  function inputProblem(required, url, body) {
    const input = required?.extensions?.bazaar?.schema?.properties?.input?.properties;
    if (!input || typeof input !== 'object') return null;
    const wrong = [];
    const check = (schema, values, where) => {
      if (!schema || typeof schema !== 'object') return;
      for (const k of Array.isArray(schema.required) ? schema.required : []) {
        if (values[k] === undefined || values[k] === '') wrong.push(`missing ${where} ${k}`);
      }
      for (const [k, s] of Object.entries(schema.properties ?? {})) {
        if (values[k] !== undefined && Array.isArray(s?.enum) && !s.enum.map(String).includes(String(values[k]))) {
          wrong.push(`${where} ${k}=${values[k]} is not one of ${s.enum.join(', ')}`);
        }
      }
    };
    try {
      check(input.queryParams, Object.fromEntries(new URL(url).searchParams), 'query parameter');
    } catch {
      return null;
    }
    if (input.body && body) {
      try {
        const json = JSON.parse(body);
        if (json && typeof json === 'object') check(input.body, json, 'body field');
      } catch {
        // not JSON: nothing to check against
      }
    }
    if (!wrong.length) return null;
    const example = required?.extensions?.bazaar?.info?.input?.queryParams;
    const hint = example && typeof example === 'object' && Object.keys(example).length
      ? `; the server's own example is ?${new URLSearchParams(example)}` : '';
    return `the server's offer says this request would be refused (${wrong.join('; ')})${hint}`;
  }

  /**
   * A version 1 offer in this agent's terms: `exact`, on this chain, priced in `amount`. The
   * original stays attached (`v1`) for the paid retry, which names the network the v1 way.
   */
  function fromV1(r) {
    if (r?.scheme !== 'exact' || V1_NETWORKS[r.network] !== Number(dep.chainId)) return null;
    return {
      scheme: 'exact', network: dep.network, amount: String(r.maxAmountRequired ?? ''), asset: r.asset, payTo: r.payTo,
      maxTimeoutSeconds: r.maxTimeoutSeconds, extra: r.extra, v1: r,
    };
  }
  const V1_MODES = new Set(['USDC', 'sUSD']);

  /** The `error` of a 402 answer to a paid request. */
  async function errorOf(res, body) {
    try {
      return (await requiredOf(new Response(body, { headers: res.headers }))).error;
    } catch {
      return 'payment rejected';
    }
  }

  /**
   * One call paid on a session: the next voucher, sent to the URL that asked for it. If the answer
   * says the session can take no more calls, it is retired and the call is paid once more from a
   * new session.
   */
  async function paySession(url, payUrl, required, o, method, headers, body, retried = false) {
    const payload = await authorize(o);
    const s = ledger.sessions[sessionKey(o.r)];
    const paymentPayload = { x402Version: X402_VERSION, resource: required.resource, accepted: o.r, payload };
    const charged = BigInt(o.r.amount);
    let res;
    let text;
    try {
      res = await fetch(payUrl, {
        method, body, redirect: 'manual', headers: { ...headers, [HEADER.signature]: encode(paymentPayload) },
        signal: AbortSignal.timeout(limits.timeoutMs),
      });
      text = await res.text();
    } catch (e) {
      // The voucher may have arrived: it stays spent, and the call counts as failed.
      noteOutcome(o.r.payTo, 'failed');
      return {
        status: 0, paid: false, delivered: false, charged, mode: 'session', requirement: o.r, body: '', paymentPayload,
        error: e?.name === 'TimeoutError' ? timeoutError('after the voucher was sent') : `no answer after the voucher was sent: ${e.message}`,
        code: 'timeout', session: { id: s.sessionId, cumulative: s.cumulative, deposit: s.deposit },
      };
    }
    const settlement = receiptOf(res); // never throws: the payment has already gone
    const paid = res.status === 200 && settlement?.success === true;
    const error = !paid && res.status === 402 ? await errorOf(res, text) : undefined;
    const delivered = res.status >= 200 && res.status < 300;
    if (!(res.status === 402 && !retried && DEAD_SESSION.has(error))) noteOutcome(o.r.payTo, outcomeOf(res.status));
    if (paid) {
      s.open = null; // the facilitator accepts a voucher only once the session is open on-chain
      s.pathStep = null;
      s.served += 1;
      saveLedger();
    } else if (!retried && DEAD_SESSION.has(error)) {
      const key = sessionKey(o.r);
      if (ledger.sessions[key] === s) {
        ledger.retired.push({ ...s, retiredBecause: error });
        delete ledger.sessions[key];
        saveLedger();
      }
      // The new session signs a new voucher, so it passes the same checks as any payment.
      const why = refusal(o);
      if (why) {
        return {
          status: res.status, paid: false, delivered: false, charged, mode: 'session', requirement: o.r, settlement, body: text, paymentPayload,
          error: `${error}; not paid again: ${why}`, session: { id: s.sessionId, cumulative: s.cumulative, deposit: s.deposit },
        };
      }
      try {
        return await paySession(url, payUrl, required, o, method, headers, body, true);
      } catch (e) {
        // The first voucher has left: answer, never throw (a thrown call may be retried).
        return {
          status: res.status, paid: false, delivered: false, charged, mode: 'session', requirement: o.r, settlement, body: text, paymentPayload,
          error: `${error}; a new session could not be opened: ${e.message}`,
          session: { id: s.sessionId, cumulative: s.cumulative, deposit: s.deposit },
        };
      }
    }
    return {
      status: res.status, paid, delivered, charged, mode: 'session', requirement: o.r, settlement, body: text, error, paymentPayload,
      session: { id: s.sessionId, cumulative: s.cumulative, deposit: s.deposit },
    };
  }

  /** Convert sUSD to exactly `amount` USDC (6 decimals) for this agent, through /convert. */
  async function convert(amount) {
    if (!facilitatorUrl || !A.router) throw new Error('convert needs a facilitator and the router');
    const value = await chain.uint(A.router, 'sUSDToAuthorize(uint256)(uint256)', [String(amount)]);
    const payload = await authorize({ mode: 'router', r: { payTo: from, amount: String(amount), maxTimeoutSeconds: 120 }, cost: value });
    const res = await fetch(`${facilitatorUrl}/convert`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ payload, amount: String(amount), maxTimeoutSeconds: 120 }),
    });
    const out = await res.json();
    if (!out.success) throw new Error(`convert failed: ${out.errorReason}`);
    return out;
  }

  /**
   * Take this agent's treasury home: its whole position in each trusted vault, then any plain USDC
   * it holds (a session's refund lands there), each paid to `to` through the facilitator's /settle
   * and so through every check it applies. Gasless: the facilitator submits. What stays behind is
   * less than one share of rounding.
   */
  async function sweep(to) {
    if (!facilitatorUrl) throw new Error('sweep needs a facilitator');
    if (!isAddress(to)) throw new Error(`bad address ${to}`);
    const settle = async (r, payload, what) => {
      const res = await fetch(`${facilitatorUrl}/settle`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          x402Version: X402_VERSION, paymentPayload: { x402Version: X402_VERSION, accepted: r, payload }, paymentRequirements: r,
        }),
      });
      const result = await res.json();
      if (!result.success) throw new Error(`sweep of ${what} failed: ${result.errorReason}`);
      return result.transaction;
    };
    const out = [];
    for (const vault of A.vaultRouter ? A.vaults : []) {
      const amount = await chain.uint(vault, 'maxWithdraw(address)(uint256)', [from]);
      if (amount === 0n) continue;
      const r = {
        scheme: 'exact', network: dep.network, asset: A.usdc, payTo: lc(to), amount: String(amount), maxTimeoutSeconds: 120,
      };
      const payload = await authorize({ mode: 'vault', r, vault, cost: amount });
      out.push({ vault, amount: String(amount), transaction: await settle(r, payload, vault) });
    }
    const cash = await chain.uint(A.usdc, 'balanceOf(address)(uint256)', [from]);
    if (cash > 0n) {
      const r = { scheme: 'exact', network: dep.network, asset: A.usdc, payTo: lc(to), amount: String(cash), maxTimeoutSeconds: 120 };
      const payload = await authorize({ mode: 'USDC', r, cost: cash });
      out.push({ asset: A.usdc, amount: String(cash), transaction: await settle(r, payload, 'USDC') });
    }
    return out;
  }

  /** The PAYMENT-REQUIRED object of a 402 (header first, body as fallback). */
  async function requiredOf(res) {
    const h = res.headers.get(HEADER.required);
    if (h) return decode(h);
    return res.json();
  }

  /**
   * GET (or `method`, with `body`) `url`, paying if the server answers 402.
   * Resolves { status, paid, mode, requirement, settlement, body, error }.
   */
  /**
   * One paid call at a time per agent: the budget, rate and merchant checks in choose() and the
   * counting at signing then never interleave with another call, so concurrent calls cannot pass
   * the same check twice.
   */
  function pay(url, options = {}) {
    return withLock('pay', () => withLedger(() => payNow(url, options)));
  }

  async function payNow(url, { prefer, method = 'GET', headers: given = {}, body } = {}) {
    const headers = { ...(userAgent && !Object.keys(given).some((k) => lc(k) === 'user-agent') ? { 'user-agent': userAgent } : {}), ...given };
    // Nothing is signed yet, so a timeout here throws and the call can safely be tried again.
    const initial = await fetch(url, { method, headers, body, signal: AbortSignal.timeout(limits.timeoutMs) });
    const payUrl = initial.url || url; // after any redirects of the unpaid request
    if (initial.status !== 402) {
      const text = await initial.text();
      return { status: initial.status, paid: false, delivered: initial.status >= 200 && initial.status < 300, charged: 0n, body: text };
    }
    let required;
    try {
      required = await requiredOf(initial);
    } catch {
      throw new Error('the server answered 402 Payment Required without an x402 offer this agent can read');
    }
    const version = required?.x402Version;
    if (version !== 1 && version !== X402_VERSION) throw new Error(`unsupported x402 version ${version}`);
    const accepts = version === 1 ? (Array.isArray(required.accepts) ? required.accepts : []).map(fromV1).filter(Boolean) : required.accepts;
    if (version === 1 && !accepts.length) {
      const offered = (Array.isArray(required.accepts) ? required.accepts : []).map((r) => `${r?.scheme} on ${r?.network}`).join(', ');
      throw new Error(`no payment option this agent can pay: it pays USDC on Base, and the server offered ${offered || 'nothing'}`);
    }

    // Nothing is signed for a request the server's own offer says it will refuse.
    const problem = version === X402_VERSION ? inputProblem(required, url, body) : null;
    if (problem) throw new Error(problem);

    const chosen = await choose(accepts, version === 1 ? 'USDC' : prefer, version === 1 ? V1_MODES : null);
    if (chosen.mode === 'session') {
      return withLock(sessionKey(chosen.r), () => paySession(url, payUrl, required, chosen, method, headers, body));
    }
    let o = chosen;
    let conversion = null;
    if (o.mode === 'convert') {
      conversion = await convert(o.r.amount); // USDC lands in this account; pay as plain USDC next
      o = { ...o, mode: 'USDC', cost: BigInt(o.r.amount) };
    }
    // A vault intent that was not settled stays good until its validBefore, and the merchant still
    // holds it. Paying the same thing again inside that window re-sends that same intent, so a
    // merchant that held the first back can settle it once, never twice (review F-1).
    const retryKey = o.mode === 'vault' ? `${payUrl}|${lc(o.r.payTo)}|${o.r.amount}|${o.vault}` : null;
    const prior = retryKey ? unsettled.get(retryKey) : null;
    const payload = prior && BigInt(prior.vaultPay.intent.validBefore) > (await chain.timestamp()) + 15n
      ? prior
      : await authorize(o);
    const paymentPayload = version === 1
      ? { x402Version: 1, scheme: 'exact', network: o.r.v1.network, payload }
      : { x402Version: X402_VERSION, resource: required.resource, accepted: o.r, payload };
    const signatureHeader = version === 1 ? HEADER_V1.signature : HEADER.signature;
    // Signed is spent: every instrument counts against the budget before it leaves, whatever the
    // merchant answers. An EIP-3009 authorization can be settled until validBefore (for the router:
    // the authorized sUSD, of which the change comes back); reconcile() releases it if it expires
    // unused. A vault intent counts when first sent; an unsettled one is re-sent, never re-signed, by
    // the next call for the same thing, and is not counted twice.
    const auth = payload.authorization;
    const resent = payload === prior;
    const row = resent ? null : record({
      id: rand32().slice(2, 18), url, mode: chosen.mode, x402Version: version, payTo: o.r.payTo, asset: o.r.asset,
      amount: o.r.amount, usd: chosen.usd, transaction: '', conversion: conversion?.transaction || undefined, delivered: false,
      ...(auth && !conversion ? {
        pending: { token: o.mode === 'USDC' ? A.usdc : A.sUSD, authorizer: auth.from, nonce: auth.nonce, validBefore: auth.validBefore },
      } : {}),
    });
    if (retryKey && row) vaultRows.set(retryKey, row.id);
    // The ledger is read afresh for every call, so the row is found again by its id.
    const counted = row ?? (retryKey ? ledger.payments.find((x) => x.id === vaultRows.get(retryKey)) ?? null : null);
    const charged = row ? chosen.usd : 0n;
    let res;
    let text;
    try {
      // The signed payment goes to the URL that asked for it and nowhere else: no redirects.
      res = await fetch(payUrl, {
        method, body, redirect: 'manual', headers: { ...headers, [signatureHeader]: encode(paymentPayload) },
        signal: AbortSignal.timeout(limits.timeoutMs),
      });
      text = await res.text();
    } catch (e) {
      if (retryKey) unsettled.set(retryKey, payload);
      if (counted) {
        counted.error = 'no answer';
        saveLedger();
      }
      noteOutcome(o.r.payTo, 'failed');
      return {
        status: 0, paid: false, delivered: false, charged, mode: chosen.mode, requirement: o.r, conversion, body: '', paymentPayload, code: 'timeout',
        error: e?.name === 'TimeoutError' ? timeoutError('after the payment was sent') : `no answer after the payment was sent: ${e.message}`,
      };
    }
    const settlement = receiptOf(res); // never throws: the payment has already gone
    const delivered = res.status >= 200 && res.status < 300;
    // Served after the payment went, and not reported as failed: paid. A merchant that sends no
    // receipt still holds the authorization; reconcile() finds out whether it was used.
    const paid = delivered && settlement?.success !== false;
    const error = !paid && res.status === 402 ? await errorOf(res, text) : undefined;
    if (retryKey) {
      if (settlement?.success === true) {
        unsettled.delete(retryKey);
        vaultRows.delete(retryKey);
      } else unsettled.set(retryKey, payload);
    }
    if (counted) {
      counted.status = res.status;
      counted.delivered = delivered;
      if (settlement?.success === true) {
        counted.transaction = settlement.transaction || '';
        delete counted.pending; // settled: spent for good
      }
      if (error) counted.error = error;
      saveLedger();
    }
    noteOutcome(o.r.payTo, outcomeOf(res.status));
    return {
      status: res.status, paid, delivered, charged, mode: chosen.mode, requirement: o.r, settlement, conversion, body: text, error, paymentPayload,
      x402Version: version,
    };
  }

  /**
   * The path's numbers, for an agent that pays from one (null otherwise): what it can still pay out
   * in all, and per merchant the cap left on-chain (capOf - committedTo), never more than the
   * path still holds. The path keeps its merchants only as a hash, so the merchants shown are
   * those this agent has paid and those listed in policy.pathMerchants.
   */
  async function pathState() {
    if (!pathId) return null;
    const p = await readPath(chain, A.sessionPaths, pathId);
    if (!p) return null;
    const room = p.bound - p.committed;
    const canStillPay = p.free < room ? p.free : room;
    const known = new Set([
      ...(limits.pathMerchants ?? []), ...Object.values(ledger.sessions).map((x) => x.payee), ...ledger.retired.map((x) => x.payee),
    ].filter(isAddress).map(lc));
    const merchants = [];
    for (const payee of known) {
      const cap = await chain.uint(A.sessionPaths, 'capOf(bytes32,address)(uint256)', [pathId, payee]);
      if (cap === 0n) continue; // not on this path
      const committed = await chain.uint(A.sessionPaths, 'committedTo(bytes32,address)(uint256)', [pathId, payee]);
      const left = cap - committed;
      merchants.push({ payee, cap, committed, remaining: left < canStillPay ? left : canStillPay });
    }
    return { ...p, canStillPay, merchants };
  }

  return {
    address: from, owner, deployment: dep, balances, pay, convert, sweep, choose, authorize, reconcile, pathState,
    sessions: () => ledger.sessions,
    breakers: () => ledger.breakers,
    resetBreaker(payTo) {
      if (payTo) delete ledger.breakers[lc(payTo)];
      else ledger.breakers = {};
      saveLedger();
    },
    spentLastMinute,
    windows,
    limits: { ...limits },
    path: pathId,
    get spent() { return spent; }, ledger: () => ledger,
  };
}

// ------------------------------------------------------------------------------------------- CLI

async function main(argv) {
  const { parseSigner } = await import('./lib/cast.mjs');
  const [cmd, ...rest] = argv;
  const help = ['help', '--help', '-h'].includes(cmd);
  if (help || !['address', 'balance', 'sessions', 'pay', 'convert', 'sweep'].includes(cmd)) {
    console[help ? 'log' : 'error'](
      `usage: ${basename(process.argv[1])} address | balance | sessions | pay <url> [--prefer session|USDC|vault|router|convert|sUSD]`
        + ' [--out <file>] [--times <n>] | convert <usd> | sweep <to>',
    );
    if (!help) process.exitCode = 64;
    return;
  }
  const flag = (name) => {
    const i = rest.indexOf(`--${name}`);
    return i >= 0 ? rest[i + 1] : undefined;
  };
  const env = process.env;
  const signer = parseSigner(`keystore:${env.AGENT_KEYSTORE}`, env.AGENT_PASSWORD_FILE);
  const agent = await createAgent({
    rpcUrl: env.RPC_URL || 'http://127.0.0.1:8545',
    signer,
    payer: env.AGENT_PAYER,
    facilitatorUrl: env.FACILITATOR_URL,
    ledgerFile: env.AGENT_LEDGER,
    path: env.AGENT_PATH || undefined,
    policy: {
      maxPerRequest: env.AGENT_MAX_PER_REQUEST ? parseUsd(env.AGENT_MAX_PER_REQUEST) : null,
      budget: env.AGENT_BUDGET ? parseUsd(env.AGENT_BUDGET) : null,
      allowedPayTo: env.AGENT_ALLOWED_PAYTO ? env.AGENT_ALLOWED_PAYTO.split(',') : null,
      sessionDeposit: env.AGENT_SESSION_DEPOSIT ? parseUsd(env.AGENT_SESSION_DEPOSIT) : null,
      maxSessionDeposit: env.AGENT_MAX_SESSION_DEPOSIT ? parseUsd(env.AGENT_MAX_SESSION_DEPOSIT) : null,
      sessionSeconds: env.AGENT_SESSION_SECONDS ? BigInt(env.AGENT_SESSION_SECONDS) : undefined,
      ...policyFromEnv(env),
    },
  });
  const show = (o) => console.log(JSON.stringify(o, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
  const bal = async () => {
    const b = await agent.balances();
    const vaults = Object.fromEntries(Object.entries(b.vaults).map(([v, x]) => [v, formatUnits(x.usdc, 6)]));
    return { sUSD: formatUnits(b.sUSD, 18), USDC: formatUnits(b.usdc, 6), ...(Object.keys(vaults).length ? { vaults } : {}) };
  };
  if (cmd === 'address') return show({ address: agent.address, owner: agent.owner });
  if (cmd === 'balance') return show({ address: agent.address, ...(await bal()), spentUSD: formatUnits(agent.spent, 6) });
  if (cmd === 'convert') {
    const out = await agent.convert(parseUsd(rest[0]));
    return show({ converted: rest[0], transaction: out.transaction, balances: await bal() });
  }
  if (cmd === 'sweep') return show({ sweptTo: rest[0], payments: await agent.sweep(rest[0]), balances: await bal() });
  if (cmd === 'sessions') return show({ address: agent.address, sessions: agent.sessions(), spentUSD: formatUnits(agent.spent, 6) });
  if (cmd === 'pay' && flag('times')) {
    // Many calls in a row (a metered API): the summary, not every body.
    const url = rest[0];
    const n = Number(flag('times'));
    if (!Number.isInteger(n) || n < 1) throw new Error('--times takes a positive whole number');
    const before = await bal();
    const started = Date.now();
    let paid = 0;
    let retries = 0;
    let last;
    const modes = {};
    for (let i = 0; i < n; i++) {
      // A public RPC drops requests now and then. A call that failed before any payment was sent
      // (pay() threw) is tried again after a pause. A call that got as far as sending a payment is
      // not: the merchant may hold it, and paying again would only feed a merchant that takes
      // payment without serving.
      for (let attempt = 0; ; attempt++) {
        try {
          last = await agent.pay(url, { prefer: flag('prefer') });
        } catch (e) {
          if (e instanceof PolicyError || attempt >= 4) throw e;
          last = { paid: false, error: e.message };
        }
        if (last.paid || attempt >= 4 || last.status !== undefined) break;
        retries += 1;
        await new Promise((r) => setTimeout(r, 1000 * 2 ** attempt));
      }
      if (!last.paid) break;
      paid += 1;
      modes[last.mode] = (modes[last.mode] || 0) + 1;
    }
    show({
      url, calls: n, paid, retries, modes, seconds: (Date.now() - started) / 1000, lastStatus: last?.status, error: last?.error,
      session: last?.session, spentUSD: formatUnits(agent.spent, 6), before, after: await bal(),
    });
    if (paid !== n) process.exitCode = 2;
    return;
  }
  if (cmd === 'pay') {
    const url = rest[0];
    const before = await bal();
    const r = await agent.pay(url, { prefer: flag('prefer') });
    const outFile = flag('out');
    if (outFile && r.paid) writeFileSync(outFile, r.body);
    show({
      url, status: r.status, paid: r.paid, mode: r.mode, price: r.requirement && { asset: r.requirement.asset, amount: r.requirement.amount, payTo: r.requirement.payTo },
      transaction: r.settlement?.transaction, error: r.error, before, after: await bal(),
      ...(outFile && r.paid ? { savedTo: outFile } : { body: r.paid ? r.body.slice(0, 400) : undefined }),
    });
    if (!r.paid) process.exitCode = 2;
  }
}

if (isMain(import.meta.url)) {
  main(process.argv.slice(2)).catch((e) => {
    console.error(`${e.name}: ${e.message}`);
    process.exitCode = e instanceof PolicyError ? 3 : 1;
  });
}

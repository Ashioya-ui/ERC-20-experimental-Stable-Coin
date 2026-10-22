// Thin, dependency-free access to the chain through Foundry's `cast`.
//
// Everything that needs Keccak or secp256k1 (ABI encoding, EIP-712 signing, transaction signing)
// goes through `cast`, so this package carries no cryptography of its own. Swap this module for
// viem or ethers when a package registry is available; nothing else depends on how it works.
//
// Keys never appear in arguments, environment variables or logs: signers are either anvil's
// unlocked accounts (local chain only) or encrypted keystores with a password file.

import { execFile } from 'node:child_process';

const CAST = process.env.CAST_BIN || 'cast';

export class CastError extends Error {
  constructor(message, stderr) {
    super(message);
    this.name = 'CastError';
    this.stderr = stderr || '';
  }
}

// cast's own log lines (e.g. a provider's "failed to fetch block") can land on stdout and break
// JSON output, so they are off unless RUST_LOG asks for them.
const BASE_ENV = { ...process.env, RUST_LOG: process.env.RUST_LOG ?? 'off' };
const TRANSIENT = /error sending request|connection (reset|closed|refused)|timed out|operation timed out/i;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// No cast invocation may hang for ever. A `cast` whose RPC connection stops answering never
// returns on its own, and the facilitator sends transactions one at a time through a promise
// chain, so one hung subprocess would park every later settlement permanently. Killing it turns
// the hang into an ordinary transient failure, which the callers above already know how to
// handle (a read retries, a send becomes UnconfirmedError and is looked up again).
const DEFAULT_TIMEOUT_MS = Number(process.env.CAST_TIMEOUT_MS || 120_000);

function run(args, env, timeoutMs) {
  return new Promise((resolve, reject) => {
    const opts = {
      maxBuffer: 16 * 1024 * 1024,
      env: env ? { ...BASE_ENV, ...env } : BASE_ENV,
      timeout: timeoutMs > 0 ? timeoutMs : undefined,
      killSignal: 'SIGKILL',
    };
    execFile(CAST, args.map(String), opts, (err, stdout, stderr) => {
      if (err) {
        // `killed` means the timeout fired. Say so in the message: TRANSIENT matches it, so a
        // read retries and a send does not (sends are never given retries).
        const line = err.killed
          ? `cast ${args[0]} timed out after ${timeoutMs} ms`
          : String(stderr || '').split('\n').find((l) => /error/i.test(l)) || err.message;
        reject(new CastError(line.trim(), String(stderr || '')));
      } else {
        resolve(String(stdout).trim());
      }
    });
  });
}

/**
 * Run `cast` with `args`; resolve with trimmed stdout, reject with a CastError carrying stderr.
 * `env` adds variables for this one process (e.g. CAST_PASSWORD when creating a keystore).
 * `retries` re-runs a command that failed on a transient connection error: only for reads,
 * never for anything that broadcasts.
 */
export async function cast(args, { env, retries = 0, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await run(args, env, timeoutMs);
    } catch (e) {
      if (attempt >= retries || !TRANSIENT.test(`${e.message}\n${e.stderr}`)) throw e;
      await sleep(150 * (attempt + 1));
    }
  }
}

/**
 * The first JSON object in `out` (tolerates stray log lines around it).
 * `accept` narrows that to the first object the caller recognises: a provider's log line can
 * itself be JSON, and then "the first JSON object" is not the answer that was asked for.
 */
export function parseJsonOutput(out, accept) {
  const text = String(out).trim();
  const usable = (v) => v !== null && typeof v === 'object' && (!accept || accept(v));
  try {
    const whole = JSON.parse(text);
    if (usable(whole)) return whole;
  } catch {
    /* not one object: look line by line */
  }
  for (const line of text.split('\n')) {
    const l = line.trim();
    if (!l.startsWith('{')) continue;
    try {
      const v = JSON.parse(l);
      if (usable(v)) return v;
    } catch {
      /* next line */
    }
  }
  throw new CastError('no JSON object in cast output', text.slice(0, 500));
}

/** First token of a `cast call` result line ("1000 [1e3]" -> "1000"). */
export const first = (out) => String(out).trim().split(/\s+/)[0];

/**
 * A signer description:
 *   { kind: 'unlocked', address }                    anvil's unlocked accounts (local chain only)
 *   { kind: 'keystore', path, passwordFile }         an encrypted JSON keystore
 */
export function signerArgs(signer) {
  if (!signer) throw new Error('no signer configured');
  if (signer.kind === 'unlocked') return ['--unlocked', '--from', signer.address];
  if (signer.kind === 'keystore') return ['--keystore', signer.path, '--password-file', signer.passwordFile];
  throw new Error(`unknown signer kind ${signer.kind}`);
}

/** Parse "unlocked:0x..." or "keystore:<path>" (password file from a second argument). */
export function parseSigner(spec, passwordFile) {
  if (!spec) return null;
  const [kind, value] = [spec.slice(0, spec.indexOf(':')), spec.slice(spec.indexOf(':') + 1)];
  if (kind === 'unlocked') return { kind, address: value };
  if (kind === 'keystore') {
    if (!passwordFile) throw new Error('a keystore signer needs a password file');
    return { kind, path: value, passwordFile };
  }
  throw new Error(`signer must be unlocked:<address> or keystore:<path>, got ${spec}`);
}

/**
 * Create the encrypted keystore `<dir>/<name>`, encrypted with the password in `passwordFile`.
 * Resolves its signer. The key itself is generated and stored by cast and never seen here.
 */
export async function newKeystore(dir, name, passwordFile) {
  const { readFileSync, chmodSync } = await import('node:fs');
  const { join } = await import('node:path');
  const password = readFileSync(passwordFile, 'utf8').trim();
  const out = parseJsonOutput(await cast(['wallet', 'new', dir, name, '--json'], { env: { CAST_PASSWORD: password } }));
  const path = join(dir, name);
  chmodSync(path, 0o600);
  return { kind: 'keystore', path, passwordFile, address: String(out[0].address).toLowerCase() };
}

/** The address of a signer. */
export async function signerAddress(signer) {
  if (signer.kind === 'unlocked') return signer.address.toLowerCase();
  return (await cast(['wallet', 'address', ...signerArgs(signer)])).toLowerCase();
}

// The statuses a receipt may carry, across cast versions and RPC providers.
const STATUS = new Set(['0x1', '1', 'true', '0x0', '0', 'false']);

/** Raised when a transaction was broadcast but its receipt could not be read. */
export class UnconfirmedError extends Error {
  constructor(hash, cause) {
    super(hash
      ? `transaction ${hash} sent but not confirmed: ${cause?.message || cause}`
      : `a transaction was broadcast but its hash is unknown: ${cause?.message || cause}`);
    this.name = 'UnconfirmedError';
    this.hash = hash || '';
  }
}

/** Chain access over one RPC endpoint. */
export function makeChain(rpcUrl) {
  const rpc = ['--rpc-url', rpcUrl];
  const READ = { retries: 3 };
  return {
    rpcUrl,
    /** eth_call of `sig` (with return types, e.g. "balanceOf(address)(uint256)"). */
    call(to, sig, args = [], { from } = {}) {
      return cast(['call', ...rpc, ...(from ? ['--from', from] : []), to, sig, ...args], READ);
    },
    async uint(to, sig, args = []) {
      return BigInt(first(await this.call(to, sig, args)));
    },
    async bool(to, sig, args = []) {
      return first(await this.call(to, sig, args)) === 'true';
    },
    /**
     * Send a transaction and wait for its receipt. Resolves { hash, ok }.
     * Two steps, so a lost receipt never hides a transaction that was sent: broadcast and get
     * the hash (a failure here means nothing was sent), then wait for the receipt (a failure
     * here raises UnconfirmedError carrying the hash).
     */
    async send(to, sig, args, signer) {
      // The sender's nonce before broadcasting. If the broadcast call fails we cannot tell from
      // the error whether the node accepted the transaction first, and guessing "unsent" is the
      // dangerous guess: the caller would retry and broadcast it a second time. The nonce is the
      // chain's own answer to that question.
      const sender = await signerAddress(signer);
      let nonceBefore;
      try {
        nonceBefore = await this.nonce(sender);
      } catch {
        nonceBefore = null; // could not read it; fall back to treating a failure as ambiguous
      }
      let out;
      try {
        out = await cast(['send', ...rpc, '--async', ...signerArgs(signer), to, sig, ...args]);
      } catch (e) {
        let advanced = nonceBefore === null;
        if (nonceBefore !== null) {
          try {
            advanced = (await this.nonce(sender)) > nonceBefore;
          } catch {
            advanced = true; // cannot tell: assume something went out
          }
        }
        // Something was broadcast, or we cannot rule it out. UnconfirmedError with no hash, so
        // the facilitator records it and answers settlement_unconfirmed rather than letting a
        // retry send the same authorization again. Only a definite "nothing left" is a failure.
        if (advanced) throw new UnconfirmedError('', e);
        throw e;
      }
      const hash = (String(out).match(/0x[0-9a-fA-F]{64}/) || [])[0];
      if (!hash) throw new UnconfirmedError('', new CastError('no transaction hash in cast output', out));
      let receipt;
      try {
        receipt = await this.receipt(hash);
      } catch (e) {
        throw new UnconfirmedError(hash.toLowerCase(), e);
      }
      const status = String(receipt.status);
      return { hash: hash.toLowerCase(), ok: status === '0x1' || status === '1' || status === 'true', receipt };
    },
    /**
     * The receipt of `hash`, waiting for it to be mined.
     *
     * The answer is checked to be the receipt that was asked for and to carry a status the
     * chain actually reported. `cast` can print provider log lines next to the JSON, and a log
     * line in JSON form parses into an object with no `status`; reading that as "no status, so
     * the transaction failed" would report a payment that went through as failed and throw away
     * the record that it was ever broadcast. Not knowing is an error, not a verdict.
     */
    async receipt(hash) {
      const want = String(hash).toLowerCase();
      const out = await cast(['receipt', ...rpc, '--json', hash], { retries: 5 });
      const r = parseJsonOutput(out, (v) => String(v.transactionHash ?? '').toLowerCase() === want);
      if (!STATUS.has(String(r.status))) {
        throw new CastError(`receipt for ${hash} carries no usable status`, out.slice(0, 500));
      }
      return r;
    },
    /** The sender's next transaction nonce. */
    async nonce(address) {
      return BigInt(first(await cast(['nonce', ...rpc, address], READ)));
    },
    async timestamp() {
      return BigInt(await cast(['block', 'latest', '--field', 'timestamp', ...rpc], READ));
    },
    async chainId() {
      return Number(await cast(['chain-id', ...rpc], READ));
    },
  };
}

/** EIP-712 signature of `typedData` by `signer` (keystore only: an unlocked account cannot sign here). */
export async function signTypedData(typedData, signer, tmpDir) {
  const { mkdtemp, writeFile, rm } = await import('node:fs/promises');
  const { join } = await import('node:path');
  const dir = await mkdtemp(join(tmpDir, 'sign-'));
  const file = join(dir, 'typed.json');
  try {
    await writeFile(file, JSON.stringify(typedData), { mode: 0o600 });
    return await cast(['wallet', 'sign', '--data', '--from-file', file, ...signerArgs(signer)]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

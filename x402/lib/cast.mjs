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

function run(args, env) {
  return new Promise((resolve, reject) => {
    const opts = { maxBuffer: 16 * 1024 * 1024, env: env ? { ...BASE_ENV, ...env } : BASE_ENV };
    execFile(CAST, args.map(String), opts, (err, stdout, stderr) => {
      if (err) {
        const line = String(stderr || '').split('\n').find((l) => /error/i.test(l)) || err.message;
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
export async function cast(args, { env, retries = 0 } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await run(args, env);
    } catch (e) {
      if (attempt >= retries || !TRANSIENT.test(`${e.message}\n${e.stderr}`)) throw e;
      await sleep(150 * (attempt + 1));
    }
  }
}

/** The first JSON object in `out` (tolerates stray log lines around it). */
export function parseJsonOutput(out) {
  const text = String(out).trim();
  try {
    return JSON.parse(text);
  } catch {
    for (const line of text.split('\n')) {
      const l = line.trim();
      if (!l.startsWith('{')) continue;
      try {
        return JSON.parse(l);
      } catch {
        /* next line */
      }
    }
    throw new CastError('no JSON object in cast output', text.slice(0, 500));
  }
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

/** Raised when a transaction was broadcast but its receipt could not be read. */
export class UnconfirmedError extends Error {
  constructor(hash, cause) {
    super(`transaction ${hash} sent but not confirmed: ${cause?.message || cause}`);
    this.name = 'UnconfirmedError';
    this.hash = hash;
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
      const out = await cast(['send', ...rpc, '--async', ...signerArgs(signer), to, sig, ...args]);
      const hash = (String(out).match(/0x[0-9a-fA-F]{64}/) || [])[0];
      if (!hash) throw new CastError('no transaction hash in cast output', out);
      let receipt;
      try {
        receipt = await this.receipt(hash);
      } catch (e) {
        throw new UnconfirmedError(hash.toLowerCase(), e);
      }
      const status = String(receipt.status);
      return { hash: hash.toLowerCase(), ok: status === '0x1' || status === '1' || status === 'true', receipt };
    },
    /** The receipt of `hash`, waiting for it to be mined. */
    async receipt(hash) {
      return parseJsonOutput(await cast(['receipt', ...rpc, '--json', hash], { retries: 5 }));
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

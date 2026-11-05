// Chain access through Foundry cast, or the pure-JS client.
import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { addressOfKey, makeJsChain, signTypedDataWithKey } from './evm.mjs';

export { abiEncode, keccak } from './evm.mjs';

const CAST = process.env.CAST_BIN || 'cast';

export class CastError extends Error {
  constructor(message, stderr) {
    super(message);
    this.name = 'CastError';
    this.stderr = stderr || '';
  }
}

const BASE_ENV = { ...process.env, RUST_LOG: process.env.RUST_LOG ?? 'off' };
const TRANSIENT = /error sending request|connection (reset|closed|refused)|timed out|operation timed out|429|too many requests|rate limit/i;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
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

export async function cast(args, { env, retries = 0, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await run(args, env, timeoutMs);
    } catch (e) {
      if (attempt >= retries || !TRANSIENT.test(`${e.message}\n${e.stderr}`)) throw e;
      await sleep(300 * 2 ** attempt);
    }
  }
}

export function parseJsonOutput(out, accept) {
  const text = String(out).trim();
  const usable = (v) => v !== null && typeof v === 'object' && (!accept || accept(v));
  try {
    const whole = JSON.parse(text);
    if (usable(whole)) return whole;
  } catch {
  }
  for (const line of text.split('\n')) {
    const l = line.trim();
    if (!l.startsWith('{')) continue;
    try {
      const v = JSON.parse(l);
      if (usable(v)) return v;
    } catch {
    }
  }
  throw new CastError('no JSON object in cast output', text.slice(0, 500));
}

export const first = (out) => String(out).trim().split(/\s+/)[0];

export function signerArgs(signer) {
  if (!signer) throw new Error('no signer configured');
  if (signer.kind === 'unlocked') return ['--unlocked', '--from', signer.address];
  if (signer.kind === 'keystore') return ['--keystore', signer.path, '--password-file', signer.passwordFile];
  if (signer.kind === 'key') throw new Error('a key-file signer signs in JavaScript; it cannot send through cast');
  throw new Error(`unknown signer kind ${signer.kind}`);
}

export function parseSigner(spec, passwordFile) {
  if (!spec) return null;
  const [kind, value] = [spec.slice(0, spec.indexOf(':')), spec.slice(spec.indexOf(':') + 1)];
  if (kind === 'unlocked') return { kind, address: value };
  if (kind === 'keystore') {
    if (!passwordFile) throw new Error('a keystore signer needs a password file');
    return { kind, path: value, passwordFile };
  }
  if (kind === 'key') return { kind, path: value };
  throw new Error(`signer must be unlocked:<address>, keystore:<path> or key:<path>, got ${spec}`);
}

const keyOf = (signer) => readFileSync(signer.path, 'utf8').trim();

export async function newKeystore(dir, name, passwordFile) {
  const { readFileSync, chmodSync } = await import('node:fs');
  const { join } = await import('node:path');
  const password = readFileSync(passwordFile, 'utf8').trim();
  const out = parseJsonOutput(await cast(['wallet', 'new', dir, name, '--json'], { env: { CAST_PASSWORD: password } }));
  const path = join(dir, name);
  chmodSync(path, 0o600);
  return { kind: 'keystore', path, passwordFile, address: String(out[0].address).toLowerCase() };
}

export async function signerAddress(signer) {
  if (signer.kind === 'unlocked') return signer.address.toLowerCase();
  if (signer.kind === 'key') return addressOfKey(keyOf(signer));
  return (await cast(['wallet', 'address', ...signerArgs(signer)])).toLowerCase();
}

const STATUS = new Set(['0x1', '1', 'true', '0x0', '0', 'false']);

export class UnconfirmedError extends Error {
  constructor(hash, cause) {
    super(hash
      ? `transaction ${hash} sent but not confirmed: ${cause?.message || cause}`
      : `a transaction was broadcast but its hash is unknown: ${cause?.message || cause}`);
    this.name = 'UnconfirmedError';
    this.hash = hash || '';
  }
}

export function makeChain(rpcUrl, { js } = {}) {
  if (js ?? process.env.X402_EVM === 'js') return makeJsChain(rpcUrl);
  const rpc = ['--rpc-url', rpcUrl];
  const READ = { retries: 3 };
  return {
    rpcUrl,
    call(to, sig, args = [], { from } = {}) {
      return cast(['call', ...rpc, ...(from ? ['--from', from] : []), to, sig, ...args], READ);
    },
    async uint(to, sig, args = []) {
      return BigInt(first(await this.call(to, sig, args)));
    },
    async bool(to, sig, args = []) {
      return first(await this.call(to, sig, args)) === 'true';
    },
    async send(to, sig, args, signer) {
      const sender = await signerAddress(signer);
      let nonceBefore;
      try {
        nonceBefore = await this.nonce(sender);
      } catch {
        nonceBefore = null;
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
            advanced = true;
          }
        }
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
    async receipt(hash) {
      const want = String(hash).toLowerCase();
      const out = await cast(['receipt', ...rpc, '--json', hash], { retries: 5 });
      const r = parseJsonOutput(out, (v) => String(v.transactionHash ?? '').toLowerCase() === want);
      if (!STATUS.has(String(r.status))) {
        throw new CastError(`receipt for ${hash} carries no usable status`, out.slice(0, 500));
      }
      return r;
    },
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

export async function signTypedData(typedData, signer, tmpDir) {
  if (signer.kind === 'key') return signTypedDataWithKey(typedData, keyOf(signer));
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

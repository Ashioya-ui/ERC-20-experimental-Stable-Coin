// Pure-JavaScript access to an EVM chain: Keccak-256, secp256k1 signatures, EIP-712, the ABI the
// client reads, and JSON-RPC over fetch. With it an agent runs on Node.js alone. The facilitator,
// which sends transactions, still goes through Foundry's cast.
//
// The curve arithmetic is plain BigInt and not constant-time. It signs on the agent's own machine,
// where anyone placed to time it could read the key file instead.

import { createHmac, randomBytes } from 'node:crypto';

const hex = (buf) => `0x${Buffer.from(buf).toString('hex')}`;
const isHexString = (s) => typeof s === 'string' && /^0x([0-9a-fA-F]{2})*$/.test(s);
export const toBytes = (v) => (Buffer.isBuffer(v) || v instanceof Uint8Array ? Buffer.from(v) : Buffer.from(String(v).slice(2), 'hex'));
const be32 = (n) => Buffer.from(n.toString(16).padStart(64, '0'), 'hex');

// ---------------------------------------------------------------------------------- Keccak-256

const MASK64 = (1n << 64n) - 1n;
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
// Rotation of lane (x, y), at index x + 5y.
const ROT = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14].map(BigInt);
const rotl = (v, n) => (n === 0n ? v : ((v << n) | (v >> (64n - n))) & MASK64);

function keccakF(s) {
  const c = new Array(5);
  const b = new Array(25);
  for (let round = 0; round < 24; round++) {
    for (let x = 0; x < 5; x++) c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20];
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1n);
      for (let y = 0; y < 25; y += 5) s[x + y] ^= d;
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], ROT[x + 5 * y]);
    }
    for (let y = 0; y < 25; y += 5) {
      for (let x = 0; x < 5; x++) s[x + y] = b[x + y] ^ (~b[((x + 1) % 5) + y] & MASK64 & b[((x + 2) % 5) + y]);
    }
    s[0] ^= RC[round];
  }
}

/** Keccak-256 (Ethereum's, not NIST SHA3-256) of bytes. */
export function keccak256(data) {
  const input = Buffer.from(data);
  const rate = 136;
  const padded = Buffer.alloc((Math.floor(input.length / rate) + 1) * rate);
  input.copy(padded);
  padded[input.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const s = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) s[i] ^= padded.readBigUInt64LE(off + 8 * i);
    keccakF(s);
  }
  const out = Buffer.alloc(32);
  for (let i = 0; i < 4; i++) out.writeBigUInt64LE(s[i], 8 * i);
  return out;
}

/** As `cast keccak`: 0x-hex input is hashed as bytes, anything else as UTF-8 text. */
export const keccak = (input) => hex(keccak256(isHexString(input) ? toBytes(input) : Buffer.from(String(input), 'utf8')));

// ----------------------------------------------------------------------------------- secp256k1

const P = (1n << 256n) - (1n << 32n) - 977n;
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const G = [
  0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n,
  0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n,
  1n,
];
const mod = (a, m) => {
  const r = a % m;
  return r < 0n ? r + m : r;
};
function inv(a, m) {
  let [lm, hm, low, high] = [1n, 0n, mod(a, m), m];
  if (low === 0n) throw new Error('no inverse of zero');
  while (low > 1n) {
    const r = high / low;
    [lm, hm] = [hm - lm * r, lm];
    [low, high] = [high - low * r, low];
  }
  return mod(lm, m);
}
// Jacobian coordinates; a point with y = 0 is the point at infinity (secp256k1 has no point of
// order two, so no finite point has y = 0).
function dbl([x, y, z]) {
  if (y === 0n) return [0n, 0n, 0n];
  const ysq = mod(y * y, P);
  const s = mod(4n * x * ysq, P);
  const m = mod(3n * x * x, P);
  const nx = mod(m * m - 2n * s, P);
  return [nx, mod(m * (s - nx) - 8n * ysq * ysq, P), mod(2n * y * z, P)];
}
function add(p, q) {
  if (p[1] === 0n) return q;
  if (q[1] === 0n) return p;
  const pz2 = mod(p[2] * p[2], P);
  const qz2 = mod(q[2] * q[2], P);
  const u1 = mod(p[0] * qz2, P);
  const u2 = mod(q[0] * pz2, P);
  const s1 = mod(p[1] * qz2 * q[2], P);
  const s2 = mod(q[1] * pz2 * p[2], P);
  if (u1 === u2) return s1 === s2 ? dbl(p) : [0n, 0n, 0n];
  const h = mod(u2 - u1, P);
  const r = mod(s2 - s1, P);
  const h2 = mod(h * h, P);
  const h3 = mod(h * h2, P);
  const u1h2 = mod(u1 * h2, P);
  const nx = mod(r * r - h3 - 2n * u1h2, P);
  return [nx, mod(r * (u1h2 - nx) - s1 * h3, P), mod(h * p[2] * q[2], P)];
}
function mul(k, point) {
  let acc = [0n, 0n, 0n];
  let addend = point;
  for (let e = k; e > 0n; e >>= 1n) {
    if (e & 1n) acc = add(acc, addend);
    addend = dbl(addend);
  }
  return acc;
}
function affine([x, y, z]) {
  if (y === 0n) throw new Error('point at infinity');
  const zi = inv(z, P);
  const zi2 = mod(zi * zi, P);
  return [mod(x * zi2, P), mod(y * zi2 * zi, P)];
}
const mulG = (k) => affine(mul(k, G));
const addressOfPoint = ([x, y]) => hex(keccak256(Buffer.concat([be32(x), be32(y)])).subarray(12));

function scalarOf(key) {
  const k = String(key).trim();
  if (!/^0x[0-9a-fA-F]{64}$/.test(k)) throw new Error('a private key is 0x and 64 hex digits');
  const d = BigInt(k);
  if (d <= 0n || d >= N) throw new Error('private key out of range');
  return d;
}

/** A fresh random private key, 0x-hex. */
export function newKey() {
  for (;;) {
    const b = randomBytes(32);
    const d = BigInt(hex(b));
    if (d > 0n && d < N) return hex(b);
  }
}

/** The Ethereum address of a private key, lowercase. */
export function addressOfKey(key) {
  return addressOfPoint(mulG(scalarOf(key)));
}

/** The address that signed `digest`, from a 65-byte r || s || v signature (ecrecover). */
export function recoverAddress(digest, signature) {
  const b = toBytes(signature);
  if (b.length !== 65) throw new Error('a signature is 65 bytes');
  const r = BigInt(hex(b.subarray(0, 32)));
  const s = BigInt(hex(b.subarray(32, 64)));
  const v = b[64] >= 27 ? b[64] - 27 : b[64];
  if (r <= 0n || r >= N || s <= 0n || s >= N || v > 1) throw new Error('malformed signature');
  const ysq = mod(r * r * r + 7n, P);
  let y = 1n;
  for (let e = (P + 1n) / 4n, base = ysq; e > 0n; e >>= 1n, base = mod(base * base, P)) if (e & 1n) y = mod(y * base, P);
  if (mod(y * y, P) !== ysq) throw new Error('r is not on the curve');
  if (Number(y & 1n) !== v) y = P - y;
  const z = BigInt(hex(digest));
  const ri = inv(r, N);
  const q = add(mul(mod(s * ri, N), [r, y, 1n]), mul(mod(-z * ri, N), G));
  return addressOfPoint(affine(q));
}

// Deterministic nonces (RFC 6979, HMAC-SHA256), so a signature never depends on a random source.
function* nonces(d, digest) {
  const x = be32(d);
  const h = be32(mod(BigInt(hex(digest)), N));
  const mac = (k, ...parts) => createHmac('sha256', k).update(Buffer.concat(parts)).digest();
  let v = Buffer.alloc(32, 1);
  let k = Buffer.alloc(32, 0);
  k = mac(k, v, Buffer.from([0]), x, h);
  v = mac(k, v);
  k = mac(k, v, Buffer.from([1]), x, h);
  v = mac(k, v);
  for (;;) {
    v = mac(k, v);
    const t = BigInt(hex(v));
    if (t > 0n && t < N) yield t;
    k = mac(k, v, Buffer.from([0]));
    v = mac(k, v);
  }
}

/** The 65-byte signature r || s || v (v = 27 or 28, s in the lower half) of a 32-byte digest. */
export function signDigest(digest, key) {
  const d = scalarOf(key);
  const z = BigInt(hex(digest));
  for (const k of nonces(d, digest)) {
    const [rx, ry] = mulG(k);
    const r = mod(rx, N);
    if (r === 0n) continue;
    let s = mod(inv(k, N) * (z + r * d), N);
    if (s === 0n) continue;
    let recovery = Number(ry & 1n);
    if (rx >= N) continue; // recovery id 2 or 3: astronomically rare, and Ethereum cannot express it
    if (s > N >> 1n) {
      s = N - s;
      recovery ^= 1;
    }
    return hex(Buffer.concat([be32(r), be32(s), Buffer.from([27 + recovery])]));
  }
  throw new Error('unreachable');
}

// --------------------------------------------------------------------------------------- ABI

const isDynamic = (t) => t === 'string' || t === 'bytes' || t.endsWith('[]');

function encodeWord(t, v) {
  if (t === 'address') {
    if (!/^0x[0-9a-fA-F]{40}$/.test(String(v))) throw new Error(`not an address: ${v}`);
    return be32(BigInt(v));
  }
  if (t === 'bool') return be32(v === true || v === 'true' || v === 1 || v === '1' ? 1n : 0n);
  let m = t.match(/^(u?)int(\d*)$/);
  if (m) {
    const bits = BigInt(m[2] || 256);
    const n = BigInt(v);
    if (m[1]) {
      if (n < 0n || n >= 1n << bits) throw new Error(`${v} does not fit ${t}`);
      return be32(n);
    }
    if (n < -(1n << (bits - 1n)) || n >= 1n << (bits - 1n)) throw new Error(`${v} does not fit ${t}`);
    return be32(n < 0n ? (1n << 256n) + n : n);
  }
  m = t.match(/^bytes(\d+)$/);
  if (m) {
    const b = toBytes(v);
    if (b.length !== Number(m[1])) throw new Error(`${v} is not ${t}`);
    return Buffer.concat([b, Buffer.alloc(32 - b.length)]);
  }
  throw new Error(`unsupported ABI type ${t}`);
}

function encodeTail(t, v) {
  if (t === 'string' || t === 'bytes') {
    const b = t === 'string' ? Buffer.from(String(v), 'utf8') : toBytes(v);
    return Buffer.concat([be32(BigInt(b.length)), b, Buffer.alloc((32 - (b.length % 32)) % 32)]);
  }
  const inner = t.slice(0, -2);
  return Buffer.concat([be32(BigInt(v.length)), encodeTypes(v.map(() => inner), v)]);
}

/** ABI encoding of `values` as `types` (static types, string, bytes and T[]). */
export function encodeTypes(types, values) {
  if (types.length !== values.length) throw new Error(`${types.length} types, ${values.length} values`);
  const heads = [];
  const tails = [];
  let offset = 32 * types.length;
  types.forEach((t, i) => {
    if (/\[\d+\]$/.test(t) || t.startsWith('(')) throw new Error(`unsupported ABI type ${t}`);
    if (isDynamic(t)) {
      const tail = encodeTail(t, values[i]);
      heads.push(be32(BigInt(offset)));
      tails.push(tail);
      offset += tail.length;
    } else {
      heads.push(encodeWord(t, values[i]));
    }
  });
  return Buffer.concat([...heads, ...tails]);
}

function decodeWord(t, w) {
  if (t === 'address') return hex(w.subarray(12));
  if (t === 'bool') return BigInt(hex(w)) !== 0n;
  let m = t.match(/^(u?)int(\d*)$/);
  if (m) {
    const n = BigInt(hex(w));
    const bits = BigInt(m[2] || 256);
    return !m[1] && n >= 1n << (bits - 1n) ? n - (1n << 256n) : n;
  }
  m = t.match(/^bytes(\d+)$/);
  if (m) return hex(w.subarray(0, Number(m[1])));
  throw new Error(`unsupported ABI type ${t}`);
}

/** Decode `data` as `types`. */
export function decodeTypes(types, data, base = 0) {
  const b = Buffer.from(data);
  const word = (at) => {
    if (at + 32 > b.length) throw new Error('ABI data too short');
    return b.subarray(at, at + 32);
  };
  return types.map((t, i) => {
    if (!isDynamic(t)) return decodeWord(t, word(base + 32 * i));
    const at = base + Number(BigInt(hex(word(base + 32 * i))));
    const len = Number(BigInt(hex(word(at))));
    if (t === 'string' || t === 'bytes') {
      if (at + 32 + len > b.length) throw new Error('ABI data too short');
      const content = b.subarray(at + 32, at + 32 + len);
      return t === 'string' ? content.toString('utf8') : hex(content);
    }
    return decodeTypes(Array(len).fill(t.slice(0, -2)), b, at + 32);
  });
}

/** "name(t1,t2)(r1,r2)" -> { name, inputs, outputs }. */
export function parseSignature(sig) {
  const m = String(sig).replace(/\s+/g, '').match(/^([A-Za-z_$][\w$]*)\(([^()]*)\)(?:\(([^()]*)\))?$/);
  if (!m) throw new Error(`unsupported function signature ${sig}`);
  const list = (s) => (s ? s.split(',') : []);
  return { name: m[1], inputs: list(m[2]), outputs: list(m[3]) };
}

/** As `cast abi-encode "f(types)" args...`: the 0x-hex encoding of the arguments. */
export function abiEncode(sig, args) {
  return hex(encodeTypes(parseSignature(sig).inputs, args));
}

/** Calldata for `sig` with `args`. */
export function calldata(sig, args) {
  const { name, inputs } = parseSignature(sig);
  return hex(Buffer.concat([keccak256(Buffer.from(`${name}(${inputs.join(',')})`)).subarray(0, 4), encodeTypes(inputs, args)]));
}

// A value as `cast call` prints it, so callers that parse cast's output read this the same way.
function castFormat(t, v) {
  if (t.endsWith('[]')) return `[${v.map((x) => castFormat(t.slice(0, -2), x)).join(', ')}]`;
  if (t === 'string') return JSON.stringify(v);
  if (t === 'bool') return v ? 'true' : 'false';
  return String(v);
}

// ------------------------------------------------------------------------------------- EIP-712

function encodeType(primary, types) {
  const deps = new Set();
  const walk = (t) => {
    const base = t.replace(/(\[\d*\])+$/, '');
    if (!types[base] || deps.has(base)) return;
    deps.add(base);
    for (const f of types[base]) walk(f.type);
  };
  walk(primary);
  deps.delete(primary);
  return [primary, ...[...deps].sort()].map((t) => `${t}(${types[t].map((f) => `${f.type} ${f.name}`).join(',')})`).join('');
}

function encodeField(type, value, types) {
  if (types[type]) return hashStruct(type, value, types);
  const arr = type.match(/^(.*)\[\d*\]$/);
  if (arr) return keccak256(Buffer.concat(value.map((v) => encodeField(arr[1], v, types))));
  if (type === 'string') return keccak256(Buffer.from(String(value), 'utf8'));
  if (type === 'bytes') return keccak256(toBytes(value));
  return encodeWord(type, value);
}

function hashStruct(type, data, types) {
  const fields = types[type].map((f) => encodeField(f.type, data[f.name], types));
  return keccak256(Buffer.concat([keccak256(Buffer.from(encodeType(type, types), 'utf8')), ...fields]));
}

/** The EIP-712 digest of typed data in the eth_signTypedData_v4 shape. */
export function hashTypedData({ types, primaryType, domain, message }) {
  if (!types.EIP712Domain) throw new Error('typed data must list its EIP712Domain type');
  const parts = [Buffer.from([0x19, 0x01]), hashStruct('EIP712Domain', domain, types)];
  if (primaryType !== 'EIP712Domain') parts.push(hashStruct(primaryType, message, types));
  return keccak256(Buffer.concat(parts));
}

/** The 65-byte EIP-712 signature of `typed` by `key`, as `cast wallet sign --data` prints it. */
export function signTypedDataWithKey(typed, key) {
  const digest = hashTypedData(typed);
  const signature = signDigest(digest, key);
  // Every signature is checked before it leaves: an arithmetic fault can only stop a payment.
  if (recoverAddress(digest, signature) !== addressOfKey(key)) throw new Error('signature self-check failed');
  return signature;
}

// ------------------------------------------------------------------------------------ JSON-RPC

class Transient extends Error {}
const TRANSIENT = /limit|rate|too many|timeout|timed out|temporar|unavailable|busy|overload|header not found|ECONNRESET|fetch failed/i;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const first = (out) => String(out).trim().split(/\s+/)[0];

/**
 * Chain access over JSON-RPC, with the read side of cast.mjs's makeChain: call, uint, bool, nonce,
 * timestamp and chainId. `rpcUrl` may list several endpoints, comma-separated; a rate-limited or
 * failing one hands the request to the next. It never sends a transaction.
 */
export function makeJsChain(rpcUrl) {
  const urls = String(rpcUrl).split(',').map((u) => u.trim()).filter(Boolean);
  if (!urls.length) throw new Error('no RPC URL');
  let at = 0;
  let id = 0;
  async function rpc(method, params) {
    let last;
    for (let attempt = 0; attempt < 3 * urls.length + 2; attempt++) {
      const url = urls[at % urls.length];
      try {
        const res = await fetch(url, {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'user-agent': 'x402-sessions' },
          body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }),
          signal: AbortSignal.timeout(30_000),
        });
        if (res.status === 429 || res.status >= 500) throw new Transient(`${url} answered HTTP ${res.status}`);
        const text = await res.text();
        let body;
        try {
          body = JSON.parse(text);
        } catch {
          throw new Transient(`${url} answered HTTP ${res.status} with no JSON`);
        }
        if (body.error) {
          const message = `${method}: ${body.error.message || JSON.stringify(body.error)}`;
          if (TRANSIENT.test(message)) throw new Transient(message);
          const e = new Error(message);
          e.data = body.error.data;
          throw e;
        }
        return body.result;
      } catch (e) {
        if (!(e instanceof Transient) && !TRANSIENT.test(String(e?.cause?.code || e?.name || e?.message))) throw e;
        last = e;
        at += 1;
        await sleep(Math.min(8000, 250 * 2 ** attempt));
      }
    }
    throw new Error(`no RPC endpoint answered ${method} (${urls.join(', ')}): ${last?.message}`);
  }
  return {
    rpcUrl: urls[0],
    rpc,
    async call(to, sig, args = [], { from } = {}) {
      const { outputs } = parseSignature(sig);
      const data = await rpc('eth_call', [{ to, data: calldata(sig, args), ...(from ? { from } : {}) }, 'latest']);
      const values = decodeTypes(outputs, toBytes(data));
      return values.map((v, i) => castFormat(outputs[i], v)).join('\n');
    },
    async uint(to, sig, args = []) {
      return BigInt(first(await this.call(to, sig, args)));
    },
    async bool(to, sig, args = []) {
      return first(await this.call(to, sig, args)) === 'true';
    },
    async send() {
      throw new Error('this client only reads and signs; sending a transaction needs Foundry (cast)');
    },
    async receipt() {
      throw new Error('this client only reads and signs; receipts need Foundry (cast)');
    },
    async nonce(address) {
      return BigInt(await rpc('eth_getTransactionCount', [address, 'latest']));
    },
    async timestamp() {
      return BigInt((await rpc('eth_getBlockByNumber', ['latest', false])).timestamp);
    },
    async chainId() {
      return Number(BigInt(await rpc('eth_chainId', [])));
    },
  };
}

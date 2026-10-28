// x402 version 2 wire format, as specified in PROMPTS.md (Phase 2) and the x402 v2 spec:
// headers PAYMENT-REQUIRED (402 response), PAYMENT-SIGNATURE (paid retry), PAYMENT-RESPONSE
// (settlement receipt), each base64 of a JSON object; facilitator /verify, /settle, /supported.

export const X402_VERSION = 2;

export const HEADER = {
  required: 'PAYMENT-REQUIRED',
  signature: 'PAYMENT-SIGNATURE',
  response: 'PAYMENT-RESPONSE',
};

export const encode = (obj) => Buffer.from(JSON.stringify(obj), 'utf8').toString('base64');
export const decode = (b64) => JSON.parse(Buffer.from(String(b64), 'base64').toString('utf8'));

export const networkOf = (chainId) => `eip155:${chainId}`;

export const lc = (a) => String(a ?? '').toLowerCase();
export const isAddress = (a) => /^0x[0-9a-fA-F]{40}$/.test(String(a ?? ''));
export const isBytes32 = (h) => /^0x[0-9a-fA-F]{64}$/.test(String(h ?? ''));
export const isHex = (h) => /^0x([0-9a-fA-F]{2})+$/.test(String(h ?? ''));
export const isUint = (n) => /^[0-9]{1,78}$/.test(String(n ?? ''));

/** The EIP-3009 typed data for a transfer or receive authorization. */
export function authorizationTypedData({ primaryType, name, version, chainId, verifyingContract, message }) {
  const fields = [
    { name: 'from', type: 'address' },
    { name: 'to', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'validAfter', type: 'uint256' },
    { name: 'validBefore', type: 'uint256' },
    { name: 'nonce', type: 'bytes32' },
  ];
  return {
    types: {
      EIP712Domain: [
        { name: 'name', type: 'string' },
        { name: 'version', type: 'string' },
        { name: 'chainId', type: 'uint256' },
        { name: 'verifyingContract', type: 'address' },
      ],
      [primaryType]: fields,
    },
    primaryType,
    domain: { name, version, chainId, verifyingContract },
    message,
  };
}

/** The EIP-712 domain fields every typed-data object here uses. */
const DOMAIN_FIELDS = [
  { name: 'name', type: 'string' },
  { name: 'version', type: 'string' },
  { name: 'chainId', type: 'uint256' },
  { name: 'verifyingContract', type: 'address' },
];

/** Field order of VaultPayRouter's PayIntent; it must match PAY_INTENT_TYPEHASH exactly. */
export const PAY_INTENT_FIELDS = [
  { name: 'payer', type: 'address' },
  { name: 'vault', type: 'address' },
  { name: 'payTo', type: 'address' },
  { name: 'assets', type: 'uint256' },
  { name: 'maxShares', type: 'uint256' },
  { name: 'salt', type: 'bytes32' },
  { name: 'validAfter', type: 'uint256' },
  { name: 'validBefore', type: 'uint256' },
];

/** The typed data a payer signs to pay through VaultPayRouter at `router` on `chainId`. */
export function vaultIntentTypedData({ chainId, router, intent }) {
  const message = {};
  for (const { name } of PAY_INTENT_FIELDS) message[name] = String(intent[name]);
  return {
    types: { EIP712Domain: DOMAIN_FIELDS, PayIntent: PAY_INTENT_FIELDS },
    primaryType: 'PayIntent',
    domain: { name: 'VaultPayRouter', version: '1', chainId: Number(chainId), verifyingContract: router },
    message,
  };
}

/** The EIP-2612 typed data for a permit on `verifyingContract` (a vault's shares). */
export function permitTypedData({ name, version, chainId, verifyingContract, owner, spender, value, nonce, deadline }) {
  return {
    types: {
      EIP712Domain: DOMAIN_FIELDS,
      Permit: [
        { name: 'owner', type: 'address' },
        { name: 'spender', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
      ],
    },
    primaryType: 'Permit',
    domain: { name, version, chainId: Number(chainId), verifyingContract },
    message: { owner, spender, value: String(value), nonce: String(nonce), deadline: String(deadline) },
  };
}

/** A 65-byte r||s||v signature as the { v, r, s } a permit takes (v normalised to 27/28). */
export function splitSignature(sig) {
  const h = String(sig ?? '');
  if (!/^0x[0-9a-fA-F]{130}$/.test(h)) throw new Error('expected a 65-byte signature');
  let v = parseInt(h.slice(130, 132), 16);
  if (v < 27) v += 27;
  if (v !== 27 && v !== 28) throw new Error(`bad signature v ${v}`);
  return { r: '0x' + h.slice(2, 66), s: '0x' + h.slice(66, 130), v };
}

/** The cast argument for a PayIntent tuple, in PAY_INTENT_FIELDS order. */
export const intentTuple = (it) => `(${PAY_INTENT_FIELDS.map(({ name }) => String(it[name])).join(',')})`;

/** The cast argument for a Permit tuple; deadline 0 means none. */
export const permitTuple = (p) =>
  p ? `(${p.value},${p.deadline},${p.v},${p.r},${p.s})` : `(0,0,0,0x${'0'.repeat(64)},0x${'0'.repeat(64)})`;

/** Same requirement (the fields that decide what is paid, to whom, on which chain). */
export function sameRequirement(a, b) {
  return (
    a && b &&
    a.scheme === b.scheme &&
    a.network === b.network &&
    lc(a.asset) === lc(b.asset) &&
    lc(a.payTo) === lc(b.payTo) &&
    String(a.amount) === String(b.amount)
  );
}

/** Read a JSON request body (at most `limit` bytes). */
export function readJson(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    let over = false;
    const chunks = [];
    req.on('data', (c) => {
      if (over) return; // already rejected: drop the rest rather than buffer it
      size += c.length;
      if (size > limit) {
        // Do NOT destroy the socket here. Destroying in the same tick as the rejection means
        // the handler writes 413 to a dead socket and the caller sees ECONNRESET instead of the
        // status, which is indistinguishable from the server having fallen over. Stop buffering,
        // let the handler answer, and close once the answer is out (see closeAfter).
        over = true;
        chunks.length = 0;
        reject(Object.assign(new Error('body too large'), { status: 413 }));
      } else chunks.push(c);
    });
    req.on('end', () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {});
      } catch {
        reject(Object.assign(new Error('invalid JSON'), { status: 400 }));
      }
    });
    req.on('error', reject);
  });
}

/**
 * End `req` once `res` has been flushed. For a request whose body was refused: the caller gets
 * its status, and only then is the connection closed, so an attacker still uploading does not
 * get to keep the socket either.
 */
export function closeAfter(req, res) {
  const shut = () => {
    if (!req.destroyed) req.destroy();
  };
  res.on('finish', shut);
  res.on('close', shut);
}

export function sendJson(res, status, body, headers = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text), ...headers });
  res.end(text);
}

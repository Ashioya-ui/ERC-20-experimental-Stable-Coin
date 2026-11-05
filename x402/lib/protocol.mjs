// x402 wire format (v1 and v2) and typed-data builders.
export const X402_VERSION = 2;

export const HEADER = {
  required: 'PAYMENT-REQUIRED',
  signature: 'PAYMENT-SIGNATURE',
  response: 'PAYMENT-RESPONSE',
};

export const HEADER_V1 = { signature: 'X-PAYMENT', response: 'X-PAYMENT-RESPONSE' };
export const V1_NETWORKS = { base: 8453, 'base-sepolia': 84532 };

export const encode = (obj) => Buffer.from(JSON.stringify(obj), 'utf8').toString('base64');
export const decode = (b64) => JSON.parse(Buffer.from(String(b64), 'base64').toString('utf8'));

export const networkOf = (chainId) => `eip155:${chainId}`;

export const lc = (a) => String(a ?? '').toLowerCase();
export const isAddress = (a) => /^0x[0-9a-fA-F]{40}$/.test(String(a ?? ''));
export const isBytes32 = (h) => /^0x[0-9a-fA-F]{64}$/.test(String(h ?? ''));
export const isHex = (h) => /^0x([0-9a-fA-F]{2})+$/.test(String(h ?? ''));
export const isUint = (n) => /^[0-9]{1,78}$/.test(String(n ?? ''));

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

const DOMAIN_FIELDS = [
  { name: 'name', type: 'string' },
  { name: 'version', type: 'string' },
  { name: 'chainId', type: 'uint256' },
  { name: 'verifyingContract', type: 'address' },
];

export const PAY_INTENT_FIELDS = [
  { name: 'payer', type: 'address' },
  { name: 'vault', type: 'address' },
  { name: 'asset', type: 'address' },
  { name: 'payTo', type: 'address' },
  { name: 'assets', type: 'uint256' },
  { name: 'maxShares', type: 'uint256' },
  { name: 'salt', type: 'bytes32' },
  { name: 'validAfter', type: 'uint256' },
  { name: 'validBefore', type: 'uint256' },
];

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

export function splitSignature(sig) {
  const h = String(sig ?? '');
  if (!/^0x[0-9a-fA-F]{130}$/.test(h)) throw new Error('expected a 65-byte signature');
  let v = parseInt(h.slice(130, 132), 16);
  if (v < 27) v += 27;
  if (v !== 27 && v !== 28) throw new Error(`bad signature v ${v}`);
  return { r: '0x' + h.slice(2, 66), s: '0x' + h.slice(66, 130), v };
}

export const intentTuple = (it) => `(${PAY_INTENT_FIELDS.map(({ name }) => String(it[name])).join(',')})`;

export const permitTuple = (p) =>
  p ? `(${p.value},${p.deadline},${p.v},${p.r},${p.s})` : `(0,0,0,0x${'0'.repeat(64)},0x${'0'.repeat(64)})`;

export function voucherTypedData({ chainId, escrow, sessionId, cumulative }) {
  return {
    types: {
      EIP712Domain: DOMAIN_FIELDS,
      Voucher: [
        { name: 'sessionId', type: 'bytes32' },
        { name: 'cumulative', type: 'uint256' },
      ],
    },
    primaryType: 'Voucher',
    domain: { name: 'X402SessionEscrow', version: '1', chainId: Number(chainId), verifyingContract: escrow },
    message: { sessionId, cumulative: String(cumulative) },
  };
}

export const PATH_STEP_FIELDS = [
  { name: 'pathId', type: 'bytes32' },
  { name: 'payee', type: 'address' },
  { name: 'signer', type: 'address' },
  { name: 'expiry', type: 'uint64' },
  { name: 'salt', type: 'bytes32' },
  { name: 'amount', type: 'uint256' },
  { name: 'committed', type: 'uint256' },
  { name: 'deadline', type: 'uint256' },
];

export function pathStepTypedData({ chainId, paths, step }) {
  const message = {};
  for (const { name } of PATH_STEP_FIELDS) message[name] = String(step[name]);
  return {
    types: { EIP712Domain: DOMAIN_FIELDS, PathStep: PATH_STEP_FIELDS },
    primaryType: 'PathStep',
    domain: { name: 'X402SessionPaths', version: '1', chainId: Number(chainId), verifyingContract: paths },
    message,
  };
}

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

export function readJson(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    let over = false;
    const chunks = [];
    req.on('data', (c) => {
      if (over) return;
      size += c.length;
      if (size > limit) {
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

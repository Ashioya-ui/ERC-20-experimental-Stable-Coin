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
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(Object.assign(new Error('body too large'), { status: 413 }));
        req.destroy();
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

export function sendJson(res, status, body, headers = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text), ...headers });
  res.end(text);
}

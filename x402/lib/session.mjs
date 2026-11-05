// X402SessionEscrow and X402SessionPaths helpers.
import { abiEncode, first, keccak } from './cast.mjs';
import { lc, isAddress, isBytes32, isHex, isUint } from './protocol.mjs';

export const MIN_DURATION = 3600n;
export const MAX_DURATION = 365n * 86400n;
export const UINT128_MAX = (1n << 128n) - 1n;

const OPEN_TYPE = 'SessionOpen(address payee,address token,address signer,uint64 expiry,bytes32 salt)';
let openTypehash = null;

export async function sessionIdOf({ funder, payee, token, signer, expiry, salt }) {
  const enc = abiEncode('f(address,address,address,address,uint64,bytes32)', [funder, payee, token, signer, String(expiry), salt]);
  return lc(keccak(enc));
}

export async function openNonce({ payee, token, signer, expiry, salt }) {
  openTypehash ??= keccak(OPEN_TYPE);
  const enc = abiEncode('f(bytes32,address,address,address,uint64,bytes32)', [openTypehash, payee, token, signer, String(expiry), salt]);
  return lc(keccak(enc));
}

export async function readSession(chain, escrow, sessionId) {
  const out = (await chain.call(escrow, 'session(bytes32)(address,address,address,address,uint128,uint128,uint64,bool)', [sessionId]))
    .split('\n')
    .map((l) => first(l.trim()));
  if (out.length < 8) throw new Error(`unexpected session() output for ${sessionId}`);
  const funder = lc(out[0]);
  if (/^0x0{40}$/.test(funder)) return null;
  return {
    funder,
    payee: lc(out[1]),
    token: lc(out[2]),
    signer: lc(out[3]),
    deposited: BigInt(out[4]),
    claimed: BigInt(out[5]),
    expiry: BigInt(out[6]),
    closed: out[7] === 'true',
  };
}

export function wellFormed(sp) {
  if (!sp || !isAddress(sp.escrow) || !isBytes32(sp.sessionId) || !isUint(sp.cumulative) || !isHex(sp.voucher)) return false;
  if (sp.open !== undefined && sp.pathStep !== undefined) return false;
  if (sp.open !== undefined) {
    const o = sp.open;
    return (
      !!o && isAddress(o.funder) && isAddress(o.signer) && isUint(o.expiry) && isBytes32(o.salt) && isUint(o.amount) &&
      isUint(o.validAfter) && isUint(o.validBefore) && isHex(o.authorization)
    );
  }
  if (sp.pathStep !== undefined) {
    const s = sp.pathStep;
    return (
      !!s && isBytes32(s.pathId) && isAddress(s.signer) && isUint(s.expiry) && isBytes32(s.salt) && isUint(s.amount) &&
      isUint(s.committed) && isUint(s.deadline) && isHex(s.signature)
    );
  }
  return true;
}

export async function readPath(chain, paths, pathId) {
  const out = (await chain.call(paths, 'path(bytes32)(address,address,address,uint64,bool,uint128,uint128,uint128)', [pathId]))
    .split('\n')
    .map((l) => first(l.trim()));
  if (out.length < 8) throw new Error(`unexpected path() output for ${pathId}`);
  const home = lc(out[0]);
  if (/^0x0{40}$/.test(home)) return null;
  return {
    home,
    agent: lc(out[1]),
    token: lc(out[2]),
    expiry: BigInt(out[3]),
    ended: out[4] === 'true',
    free: BigInt(out[5]),
    committed: BigInt(out[6]),
    bound: BigInt(out[7]),
  };
}

export const list = (xs) => `[${xs.map(String).join(',')}]`;

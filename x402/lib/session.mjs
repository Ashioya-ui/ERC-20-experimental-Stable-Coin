// The x402 "session" scheme on X402SessionEscrow, shared by the facilitator and the agent.
//
// A session is a deposit in the escrow that names one payee, one token, an expiry and the key that
// signs for it. Each paid call carries a voucher: an EIP-712 signature over the session and the
// cumulative amount owed so far. Nothing touches the chain per call; the facilitator redeems the
// latest voucher in batches, always before expiry.
//
// Wire format (inside the x402 v2 PAYMENT-SIGNATURE payload):
//   payload.session = {
//     escrow, sessionId, cumulative, voucher,
//     open?: { funder, signer, expiry, salt, amount, validAfter, validBefore, authorization }
//   }
// `open` rides along until the session exists on-chain: an EIP-3009 ReceiveWithAuthorization of
// `amount` from `funder` to the escrow whose nonce is openNonce(payee, token, signer, expiry, salt),
// so the facilitator opens the session gaslessly for the funder and cannot alter any of its terms.
//
// Hashes are computed locally by cast (no RPC).

import { cast, first } from './cast.mjs';
import { lc, isAddress, isBytes32, isHex, isUint } from './protocol.mjs';

export const MIN_DURATION = 3600n; // X402SessionEscrow.MIN_DURATION
export const MAX_DURATION = 365n * 86400n; // X402SessionEscrow.MAX_DURATION
export const UINT128_MAX = (1n << 128n) - 1n;

const OPEN_TYPE = 'SessionOpen(address payee,address token,address signer,uint64 expiry,bytes32 salt)';
let openTypehash = null;

/** keccak256(abi.encode(funder, payee, token, signer, salt)), as X402SessionEscrow.sessionIdOf. */
export async function sessionIdOf({ funder, payee, token, signer, salt }) {
  const enc = await cast(['abi-encode', 'f(address,address,address,address,bytes32)', funder, payee, token, signer, salt]);
  return lc(await cast(['keccak', enc]));
}

/** The EIP-3009 nonce that binds a gasless open to its terms, as X402SessionEscrow.openNonce. */
export async function openNonce({ payee, token, signer, expiry, salt }) {
  openTypehash ??= await cast(['keccak', OPEN_TYPE]);
  const enc = await cast([
    'abi-encode', 'f(bytes32,address,address,address,uint64,bytes32)', openTypehash, payee, token, signer, String(expiry), salt,
  ]);
  return lc(await cast(['keccak', enc]));
}

/** A session's on-chain state, or null if it does not exist. */
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

/** Shape check of payload.session; true when every field present has the right form. */
export function wellFormed(sp) {
  if (!sp || !isAddress(sp.escrow) || !isBytes32(sp.sessionId) || !isUint(sp.cumulative) || !isHex(sp.voucher)) return false;
  if (sp.open === undefined) return true;
  const o = sp.open;
  return (
    !!o && isAddress(o.funder) && isAddress(o.signer) && isUint(o.expiry) && isBytes32(o.salt) && isUint(o.amount) &&
    isUint(o.validAfter) && isUint(o.validBefore) && isHex(o.authorization)
  );
}

/** The cast argument for a list, e.g. ["0xa", "0xb"] -> "[0xa,0xb]". */
export const list = (xs) => `[${xs.map(String).join(',')}]`;

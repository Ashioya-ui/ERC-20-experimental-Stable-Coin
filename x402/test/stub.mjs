// A chain stub for the facilitator, so the error paths can be driven on purpose.
//
// Everything the facilitator does to the chain goes through one `chain` object, and
// createFacilitator({ chain }) takes an override. Replacing it with this stub makes the paths
// that only happen when the RPC misbehaves -- a read that throws, a send whose receipt is lost,
// a send that never returns -- reachable in a test, deterministically and in milliseconds.
// No anvil is needed; `cast sig` (for the custom-error selectors) and the deployment JSON are.

import { randomBytes } from 'node:crypto';
import { createFacilitator } from '../facilitator.mjs';

const SIGNER = { kind: 'unlocked', address: '0x15d34aaf54267db7d7c367839aaf71a00a2c6a65' };
export const NOW = 1_800_000_000n; // the stub chain's clock, fixed so time never flakes
export const rand32 = () => '0x' + randomBytes(32).toString('hex');
export const randAddress = () => '0x' + randomBytes(20).toString('hex');

/**
 * A chain whose every method can be overridden. The defaults describe a healthy chain on which
 * every payment is good: the clock is NOW, no nonce is used, every balance is ample, every
 * simulation passes and every send is mined successfully.
 */
export function stubChain(hooks = {}) {
  let n = 0;
  return {
    rpcUrl: 'stub://',
    hooks,
    sends: [],
    async chainId() {
      return 31337;
    },
    async call(to, sig, args = [], opts = {}) {
      // loadDeployment reads the USDC EIP-712 domain off the chain before anything else.
      if (sig === 'name()(string)') return '"USD Coin"';
      if (sig === 'version()(string)') return '"2"';
      return hooks.call ? hooks.call(to, sig, args, opts) : '0x';
    },
    async uint(to, sig, args) {
      return hooks.uint ? hooks.uint(to, sig, args) : 10n ** 30n;
    },
    async bool(to, sig, args) {
      return hooks.bool ? hooks.bool(to, sig, args) : false;
    },
    async timestamp() {
      return hooks.timestamp ? hooks.timestamp() : NOW;
    },
    async send(to, sig, args, signer) {
      this.sends.push({ to, sig, args });
      if (hooks.send) return hooks.send(to, sig, args);
      return { hash: '0x' + String(++n).padStart(64, '0'), ok: true };
    },
    async receipt(hash) {
      return hooks.receipt ? hooks.receipt(hash) : { status: '0x1', transactionHash: hash };
    },
  };
}

/** A facilitator on a stub chain, plus the helpers a test needs to talk to it. */
export async function stubFacilitator(hooks = {}) {
  const chain = stubChain(hooks);
  const f = await createFacilitator({ rpcUrl: 'stub://', signer: SIGNER, chain });
  const A = f.deployment.addresses;
  const PAYTO = '0x' + '11'.repeat(20);

  /** A well-formed sUSD payment the healthy stub accepts. */
  const payment = ({ payer = randAddress(), nonce = rand32(), amount = '1000', payTo = PAYTO } = {}) => {
    const authorization = {
      from: payer, to: payTo, value: amount,
      validAfter: '0', validBefore: String(NOW + 50n), nonce,
    };
    const r = {
      scheme: 'exact', network: f.deployment.network, asset: A.sUSD, payTo, amount, maxTimeoutSeconds: 60,
    };
    return {
      x402Version: 2,
      paymentPayload: { x402Version: 2, accepted: r, payload: { signature: '0x' + 'ab'.repeat(65), authorization } },
      paymentRequirements: r,
    };
  };

  /**
   * Does any of the facilitator's maps still hold (payer, nonce)?
   * Asking with a body that carries the same key but a different fingerprint separates the two
   * answers without side effects: a remembered key answers "nonce used", a forgotten one falls
   * through to check(), which rejects amount 0 on its own.
   */
  const holds = async (payer, nonce) => {
    const r = await f.settle(payment({ payer, nonce, amount: '0' }));
    if (r.errorReason === 'invalid_exact_evm_payload_authorization_nonce_used') return true;
    if (r.errorReason === 'invalid_payment_requirements') return false;
    throw new Error(`the probe got an unexpected answer: ${JSON.stringify(r)}`);
  };

  const listen = async () => {
    await new Promise((r) => f.server.listen(0, '127.0.0.1', r));
    return `http://127.0.0.1:${f.server.address().port}`;
  };
  const close = () => new Promise((r) => f.server.close(r));

  return { f, chain, A, payTo: PAYTO, payment, holds, listen, close };
}

/** true, or why the stub suite cannot run (it needs `cast` and the deployment files, not a chain). */
export async function stubAvailable() {
  try {
    await stubFacilitator();
    return true;
  } catch (e) {
    return e.message.split('\n')[0];
  }
}

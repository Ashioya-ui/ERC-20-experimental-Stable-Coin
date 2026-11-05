
import { randomBytes } from 'node:crypto';
import { createFacilitator } from '../facilitator.mjs';

const SIGNER = { kind: 'unlocked', address: '0x15d34aaf54267db7d7c367839aaf71a00a2c6a65' };
export const NOW = 1_800_000_000n;
export const rand32 = () => '0x' + randomBytes(32).toString('hex');
export const randAddress = () => '0x' + randomBytes(20).toString('hex');

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

export async function stubFacilitator(hooks = {}, options = {}) {
  const chain = stubChain(hooks);
  const f = await createFacilitator({ rpcUrl: 'stub://', signer: SIGNER, chain, ...options });
  const A = f.deployment.addresses;
  const PAYTO = '0x' + '11'.repeat(20);

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

export async function stubAvailable() {
  try {
    await stubFacilitator();
    return true;
  } catch (e) {
    return e.message.split('\n')[0];
  }
}

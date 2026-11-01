// The pure-JavaScript EVM module (lib/evm.mjs): against published vectors everywhere; against
// Foundry's cast where cast is installed; and, on a live rail, an agent whose key is a plain file
// (no cast anywhere in its path) pays a merchant end to end.

import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  abiEncode, addressOfKey, hashTypedData, keccak, makeJsChain, newKey, recoverAddress, signDigest, signTypedDataWithKey,
} from '../lib/evm.mjs';
import { authorizationTypedData, pathStepTypedData, voucherTypedData } from '../lib/protocol.mjs';
import { makeChain } from '../lib/cast.mjs';
import { available, setup, RPC } from './helpers.mjs';

const run = promisify(execFile);
const castVersion = await run('cast', ['--version']).then(() => true, () => false);
const rand = (n) => `0x${[...Array(n)].map(() => Math.floor(Math.random() * 256).toString(16).padStart(2, '0')).join('')}`;

// The EIP-712 specification's own example, with its published digest and signature.
const MAIL = {
  types: {
    EIP712Domain: [
      { name: 'name', type: 'string' }, { name: 'version', type: 'string' },
      { name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' },
    ],
    Person: [{ name: 'name', type: 'string' }, { name: 'wallet', type: 'address' }],
    Mail: [{ name: 'from', type: 'Person' }, { name: 'to', type: 'Person' }, { name: 'contents', type: 'string' }],
  },
  primaryType: 'Mail',
  domain: { name: 'Ether Mail', version: '1', chainId: 1, verifyingContract: '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC' },
  message: {
    from: { name: 'Cow', wallet: '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826' },
    to: { name: 'Bob', wallet: '0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB' },
    contents: 'Hello, Bob!',
  },
};

// The typed data this client signs for real: EIP-3009 authorizations, vouchers and path steps.
function samples() {
  const chainId = 8453;
  const usdc = '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913';
  const message = {
    from: rand(20), to: rand(20), value: '123456', validAfter: '0', validBefore: '1900000000', nonce: rand(32),
  };
  return [
    authorizationTypedData({ primaryType: 'TransferWithAuthorization', name: 'USD Coin', version: '2', chainId, verifyingContract: usdc, message }),
    authorizationTypedData({ primaryType: 'ReceiveWithAuthorization', name: 'USD Coin', version: '2', chainId, verifyingContract: usdc, message }),
    voucherTypedData({ chainId, escrow: rand(20), sessionId: rand(32), cumulative: 1000n }),
    pathStepTypedData({
      chainId,
      paths: rand(20),
      step: {
        pathId: rand(32), payee: rand(20), signer: rand(20), expiry: '1900000000', salt: rand(32),
        amount: '200000', committed: '0', deadline: '1900000000',
      },
    }),
  ];
}

describe('evm.mjs against published vectors', () => {
  test('Keccak-256', () => {
    assert.equal(keccak(''), '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
    assert.equal(keccak('abc'), '0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45');
    assert.equal(keccak('Transfer(address,address,uint256)'), '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef');
    assert.equal(keccak('0x'), keccak(''), '0x-hex input is bytes, as with cast keccak');
  });

  test('addresses of keys', () => {
    assert.equal(addressOfKey(`0x${'0'.repeat(63)}1`), '0x7e5f4552091a69125d5dfcb7b8c2659029395bdf');
    assert.equal(addressOfKey('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'), '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266');
    assert.throws(() => addressOfKey(`0x${'0'.repeat(64)}`), /out of range/);
    assert.throws(() => addressOfKey('0x1234'), /64 hex digits/);
  });

  test("EIP-712: the specification's Mail example, digest and signature", () => {
    const key = keccak('cow');
    assert.equal(addressOfKey(key), '0xcd2a3d9f938e13cd947ec05abc7fe734df8dd826');
    assert.equal(`0x${hashTypedData(MAIL).toString('hex')}`, '0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2');
    assert.equal(
      signTypedDataWithKey(MAIL, key),
      '0x4355c47d63924e8a72e509b65029052eb6c299d53a04e167c5775fd466751c9d07299936d304c153f6443dfa05f40ff007d72911b6f72307f996231605b915621c',
    );
  });

  test('signatures recover to their signer and always carry a low s', () => {
    const half = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0n;
    for (let i = 0; i < 64; i++) {
      const key = newKey();
      const digest = Buffer.from(keccak(`message ${i}`).slice(2), 'hex');
      const sig = signDigest(digest, key);
      assert.equal(recoverAddress(digest, sig), addressOfKey(key));
      assert.ok(BigInt(`0x${sig.slice(66, 130)}`) <= half);
      assert.ok(['1b', '1c'].includes(sig.slice(130)));
    }
  });
});

describe('evm.mjs against cast', { skip: castVersion ? false : 'Foundry cast is not installed' }, () => {
  const cast = async (...args) => (await run('cast', args.map(String))).stdout.trim();
  // anvil's first account: a publicly known test key that never holds real money
  const KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

  test('the signatures this client makes are byte for byte the ones cast makes', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'evm-'));
    for (const typed of samples()) {
      const file = join(dir, 'typed.json');
      writeFileSync(file, JSON.stringify(typed));
      assert.equal(signTypedDataWithKey(typed, KEY), await cast('wallet', 'sign', '--data', '--from-file', file, '--private-key', KEY), typed.primaryType);
    }
  });

  test('keccak and abi-encode agree with cast', async () => {
    for (const s of ['', 'SessionOpen(address payee,address token,address signer,uint64 expiry,bytes32 salt)', rand(77)]) {
      assert.equal(keccak(s), await cast('keccak', s));
    }
    const args = [rand(20), rand(20), rand(20), rand(20), '1900000000', rand(32)];
    const sig = 'f(address,address,address,address,uint64,bytes32)';
    assert.equal(abiEncode(sig, args), await cast('abi-encode', sig, ...args));
  });
});

const ready = await available();
describe('a key-file agent on the rail, with no cast in its path', { skip: ready === true ? false : `no rail at ${RPC} (${ready})` }, () => {
  let w;
  before(async () => {
    w = await setup();
  });
  after(async () => w?.close());

  test('JSON-RPC reads print exactly as cast prints them', async () => {
    const js = makeJsChain(RPC);
    const viaCast = makeChain(RPC);
    const usdc = w.A.usdc;
    assert.equal(await js.chainId(), await viaCast.chainId());
    for (const [sig, args] of [['name()(string)', []], ['version()(string)', []], ['balanceOf(address)(uint256)', [w.merchantAddress]]]) {
      const [a, b] = [await js.call(usdc, sig, args), await viaCast.call(usdc, sig, args)];
      assert.equal(a.split(/\s+/)[0], b.split(/\s+/)[0], sig);
    }
  });

  test('pays a USDC price end to end', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'keyfile-'));
    const path = join(dir, 'agent.key');
    const key = newKey();
    writeFileSync(path, `${key}\n`, { mode: 0o600 });
    const a = await w.agent({ usdc: 1_000_000n, signer: { kind: 'key', path, address: addressOfKey(key) } });
    const m0 = await w.bal.usdc(w.merchantAddress);
    const r = await a.pay(`${w.merchantUrl}/api/v1/usdc-only`);
    assert.equal(r.paid, true, r.error);
    assert.equal(r.mode, 'USDC');
    assert.equal((await w.bal.usdc(w.merchantAddress)) - m0, 20_000n);
  });
});

// Unit tests of the pure parts of the x402 rail (no chain needed).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  encode, decode, sameRequirement, authorizationTypedData, isAddress, isBytes32, isHex, isUint, PAY_INTENT_FIELDS,
  vaultIntentTypedData, permitTypedData, splitSignature, intentTuple, permitTuple,
} from '../lib/protocol.mjs';
import { parseJsonOutput, parseSigner, first } from '../lib/cast.mjs';
import { parseUsd, formatUnits } from '../agent.mjs';

test('headers are base64 JSON both ways', () => {
  const obj = { x402Version: 2, accepts: [{ amount: '5000', payTo: '0xabc' }], s: 'ü' };
  assert.deepEqual(decode(encode(obj)), obj);
  assert.throws(() => decode('not base64 json'));
});

test('sameRequirement compares what is paid, to whom, on which chain', () => {
  const r = { scheme: 'exact', network: 'eip155:8453', asset: '0xAbC', payTo: '0xDeF', amount: '5', extra: { a: 1 } };
  assert.ok(sameRequirement(r, { ...r, asset: '0xabc', payTo: '0xdef', amount: 5, extra: {} }));
  for (const k of ['scheme', 'network', 'asset', 'payTo', 'amount']) assert.ok(!sameRequirement(r, { ...r, [k]: 'x' }), k);
  assert.ok(!sameRequirement(r, undefined));
});

test('EIP-3009 typed data has the six fields in order and the right domain', () => {
  const t = authorizationTypedData({
    primaryType: 'ReceiveWithAuthorization', name: 'Spectrum Agentic USD', version: '1', chainId: 8453,
    verifyingContract: '0x0000000000000000000000000000000000000001', message: {},
  });
  assert.deepEqual(t.types.ReceiveWithAuthorization.map((f) => f.name), ['from', 'to', 'value', 'validAfter', 'validBefore', 'nonce']);
  assert.deepEqual(t.domain, { name: 'Spectrum Agentic USD', version: '1', chainId: 8453, verifyingContract: '0x0000000000000000000000000000000000000001' });
  assert.equal(t.primaryType, 'ReceiveWithAuthorization');
});

test('validators', () => {
  assert.ok(isAddress('0x' + 'a'.repeat(40)) && !isAddress('0x' + 'a'.repeat(39)) && !isAddress(undefined));
  assert.ok(isBytes32('0x' + '0'.repeat(64)) && !isBytes32('0x' + '0'.repeat(63)));
  assert.ok(isHex('0xab') && !isHex('0xa') && !isHex('ab'));
  assert.ok(isUint('0') && isUint('123') && !isUint('-1') && !isUint('1.5') && !isUint('9'.repeat(79)));
});

test('cast output: JSON is found even with stray log lines around it (seen on a busy anvil)', () => {
  const receipt = '{"status":"0x1","transactionHash":"0x' + '1'.repeat(64) + '"}';
  const log = '\u001b[2m2026-10-22T04:04:08Z\u001b[0m ERROR alloy_provider::blocks: failed to fetch block number=846';
  assert.equal(parseJsonOutput(receipt).status, '0x1');
  assert.equal(parseJsonOutput(`${receipt}\n${log}`).status, '0x1');
  assert.equal(parseJsonOutput(`${log}\n${receipt}`).status, '0x1');
  assert.throws(() => parseJsonOutput(log), /no JSON object/);
  assert.equal(first('5000000 [5e6]'), '5000000');

  // A log line can itself be JSON, and then "the first JSON object" is not the answer that was
  // asked for. makeChain.receipt passes a predicate so it cannot mistake one for a receipt:
  // reading a log record as a receipt with no status would report a payment that went through
  // as failed, and throw away the record that it was ever broadcast.
  const jsonLog = '{"level":"ERROR","target":"alloy_provider","message":"failed to fetch block"}';
  const isReceipt = (v) => 'transactionHash' in v;
  assert.equal(parseJsonOutput(`${jsonLog}\n${receipt}`).level, 'ERROR', 'without a predicate, the log line wins');
  assert.equal(parseJsonOutput(`${jsonLog}\n${receipt}`, isReceipt).status, '0x1');
  assert.throws(() => parseJsonOutput(jsonLog, isReceipt), /no JSON object/);
});

test('signer specs', () => {
  assert.deepEqual(parseSigner('unlocked:0xabc'), { kind: 'unlocked', address: '0xabc' });
  assert.deepEqual(parseSigner('keystore:/k/agent', '/k/pw'), { kind: 'keystore', path: '/k/agent', passwordFile: '/k/pw' });
  assert.throws(() => parseSigner('keystore:/k/agent'), /password file/);
  assert.throws(() => parseSigner('privatekey:0x01'), /unlocked:<address> or keystore:<path>/);
});

test('dollar amounts', () => {
  assert.equal(parseUsd('1.25'), 1_250_000n);
  assert.equal(parseUsd('0.000001'), 1n);
  assert.equal(parseUsd('10'), 10_000_000n);
  assert.throws(() => parseUsd('1.0000001'));
  assert.throws(() => parseUsd('-1'));
  assert.equal(formatUnits(1_250_000n, 6), '1.25');
  assert.equal(formatUnits(5_000_000_000_000_000n, 18), '0.005');
  assert.equal(formatUnits(0n, 6), '0');
  assert.equal(formatUnits(-1n, 6), '-0.000001');
});

// ------------------------------------------------------------------------------------ vault router

test('PayIntent fields reproduce the Solidity typehash string exactly', () => {
  const sol = readFileSync(new URL('../../src/vault/VaultPayRouter.sol', import.meta.url), 'utf8');
  const m = /"(PayIntent\([^"]+\))"/.exec(sol);
  assert.ok(m, 'PAY_INTENT_TYPEHASH string not found in VaultPayRouter.sol');
  const js = `PayIntent(${PAY_INTENT_FIELDS.map((f) => `${f.type} ${f.name}`).join(',')})`;
  assert.equal(js, m[1]);
});

test('vault intent typed data', () => {
  const intent = {
    payer: '0x' + '1'.repeat(40), vault: '0x' + '2'.repeat(40), payTo: '0x' + '3'.repeat(40), assets: 50_000n,
    maxShares: 47_620, salt: '0x' + 'ab'.repeat(32), validAfter: 1, validBefore: 99, extra: 'ignored',
  };
  const td = vaultIntentTypedData({ chainId: 8453, router: '0x' + '4'.repeat(40), intent });
  assert.equal(td.primaryType, 'PayIntent');
  assert.deepEqual(td.domain, { name: 'VaultPayRouter', version: '1', chainId: 8453, verifyingContract: '0x' + '4'.repeat(40) });
  assert.deepEqual(Object.keys(td.message), PAY_INTENT_FIELDS.map((f) => f.name), 'only the signed fields, in order');
  assert.equal(td.message.assets, '50000', 'uint256 values travel as decimal strings');
  assert.deepEqual(td.types.PayIntent, PAY_INTENT_FIELDS);
});

test('permit typed data', () => {
  const td = permitTypedData({
    name: 'Wrapped Aave Base USDC', version: '1', chainId: 8453, verifyingContract: '0x' + '5'.repeat(40),
    owner: '0x' + '6'.repeat(40), spender: '0x' + '7'.repeat(40), value: 10n, nonce: 0n, deadline: 123,
  });
  assert.equal(td.primaryType, 'Permit');
  assert.deepEqual(td.types.Permit.map((f) => f.name), ['owner', 'spender', 'value', 'nonce', 'deadline']);
  assert.deepEqual(td.message, {
    owner: '0x' + '6'.repeat(40), spender: '0x' + '7'.repeat(40), value: '10', nonce: '0', deadline: '123',
  });
});

test('splitting a signature for a permit', () => {
  const r = 'aa'.repeat(32);
  const s = 'bb'.repeat(32);
  assert.deepEqual(splitSignature(`0x${r}${s}1b`), { r: `0x${r}`, s: `0x${s}`, v: 27 });
  assert.deepEqual(splitSignature(`0x${r}${s}01`), { r: `0x${r}`, s: `0x${s}`, v: 28 }, 'v 0/1 is normalised');
  assert.throws(() => splitSignature(`0x${r}${s}`), /65-byte/);
  assert.throws(() => splitSignature(`0x${r}${s}05`), /bad signature v/);
});

test('cast tuples for the router call', () => {
  const it = {
    payer: '0xP', vault: '0xV', payTo: '0xT', assets: 1, maxShares: 2, salt: '0xS', validAfter: 3, validBefore: 4,
  };
  assert.equal(intentTuple(it), '(0xP,0xV,0xT,1,2,0xS,3,4)');
  assert.equal(permitTuple({ value: 9, deadline: 8, v: 27, r: '0xR', s: '0xS' }), '(9,8,27,0xR,0xS)');
  assert.equal(permitTuple(null), `(0,0,0,0x${'0'.repeat(64)},0x${'0'.repeat(64)})`, 'deadline 0 means no permit');
});

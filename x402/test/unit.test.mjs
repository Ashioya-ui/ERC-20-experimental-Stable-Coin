// Unit tests of the pure parts of the x402 rail (no chain needed).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encode, decode, sameRequirement, authorizationTypedData, isAddress, isBytes32, isHex, isUint } from '../lib/protocol.mjs';
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

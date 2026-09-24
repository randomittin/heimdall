// node --test suite for relay/scripts/fake-hmd.mjs and its lib/ modules.
// Deliberately node:test + node:assert, not vitest: this exercises a plain
// dev-tool script, not the Workers runtime the rest of relay/'s vitest suite
// targets (same "needs a real filesystem" reasoning as
// scripts/check-no-logged-urls.mjs -- see that file's own header comment).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { x25519 } from '@noble/curves/ed25519.js';

import { deriveSessionKey, seal, open, RelayCryptoError } from '../lib/relay-crypto.mjs';
import {
  encodeHmdEnvelope,
  decodeEnvelope,
  base64Encode,
  base64Decode,
  base64UrlEncode,
  base64UrlDecode,
} from '../lib/envelope.mjs';
import {
  parseArgs,
  resolveStatePath,
  decodeSendMessageCommand,
  buildAckPayload,
  resolvePhonePubkey,
  nextBackoffMs,
  runStreamWithReconnect,
  FatalStreamError,
  BACKOFF_BASE_MS,
  BACKOFF_CAP_MS,
} from '../fake-hmd.mjs';

const HERE = fileURLToPath(new URL('.', import.meta.url)); // .../relay/scripts/__tests__/
const REPO_ROOT = join(HERE, '..', '..', '..');
const SHARED_VECTORS_PATH = join(REPO_ROOT, 'src/relay/__tests__/fixtures/vectors.json');

function toHex(bytes) {
  return Buffer.from(bytes).toString('hex');
}

function fromHex(hex) {
  return new Uint8Array(Buffer.from(hex, 'hex'));
}

// --- relay-crypto.mjs against the shared golden vector -----------------

test('relay-crypto.mjs reproduces the shared golden vector (src/relay/__tests__/fixtures/vectors.json)', () => {
  assert.ok(
    existsSync(SHARED_VECTORS_PATH),
    `expected the app's committed fixture at ${SHARED_VECTORS_PATH} (brief: "if present")`
  );
  const golden = JSON.parse(readFileSync(SHARED_VECTORS_PATH, 'utf8'));

  const hmd = x25519.keygen(fromHex(golden.hmdSeedHex));
  const phn = x25519.keygen(fromHex(golden.phnSeedHex));
  assert.equal(toHex(hmd.publicKey), golden.hmdPublicKeyHex);
  assert.equal(toHex(phn.publicKey), golden.phnPublicKeyHex);

  const hmdSessionKey = deriveSessionKey(hmd.secretKey, phn.publicKey, golden.sessionId);
  const phnSessionKey = deriveSessionKey(phn.secretKey, hmd.publicKey, golden.sessionId);
  assert.equal(toHex(hmdSessionKey), toHex(phnSessionKey));
  assert.equal(toHex(hmdSessionKey), golden.sessionKeyHex);

  const plaintext = fromHex(golden.plaintextHex);
  const sealed = seal(hmdSessionKey, golden.senderTag, golden.seq, plaintext);
  assert.equal(sealed.seq, golden.seq);
  assert.equal(toHex(sealed.ciphertext), golden.ciphertextHex);

  const opened = open(phnSessionKey, golden.senderTag, { seq: golden.seq, ciphertext: fromHex(golden.ciphertextHex) }, 0);
  assert.equal(Buffer.from(opened).toString('utf8'), Buffer.from(plaintext).toString('utf8'));
});

test('relay-crypto.mjs seal/open round-trips independently of the golden vector', () => {
  const a = x25519.keygen(new Uint8Array(32).fill(0x33));
  const b = x25519.keygen(new Uint8Array(32).fill(0x44));
  const keyA = deriveSessionKey(a.secretKey, b.publicKey, 'self-test-session');
  const keyB = deriveSessionKey(b.secretKey, a.publicKey, 'self-test-session');
  assert.equal(toHex(keyA), toHex(keyB));

  const plaintext = new TextEncoder().encode('fake-hmd self-test plaintext');
  const sealed = seal(keyA, 'hmd', 1, plaintext);
  const opened = open(keyB, 'hmd', sealed, 0);
  assert.equal(Buffer.from(opened).toString('utf8'), 'fake-hmd self-test plaintext');
});

test('relay-crypto.mjs open() rejects a non-increasing seq (INV-14/15)', () => {
  const a = x25519.keygen(new Uint8Array(32).fill(0x55));
  const b = x25519.keygen(new Uint8Array(32).fill(0x66));
  const key = deriveSessionKey(a.secretKey, b.publicKey, 'replay-test-session');
  const sealed = seal(key, 'hmd', 5, new TextEncoder().encode('x'));
  assert.throws(() => open(key, 'hmd', sealed, 5), RelayCryptoError);
  assert.throws(() => open(key, 'hmd', sealed, 6), RelayCryptoError);
});

// --- envelope.mjs --------------------------------------------------------

test('encodeHmdEnvelope -> decodeEnvelope round-trips a state frame', () => {
  const ciphertext = new Uint8Array([1, 2, 3, 4, 5]);
  const line = encodeHmdEnvelope({ sessionId: 'sess-1', seq: 3, type: 'state', ciphertext });
  const decoded = decodeEnvelope(line);
  assert.ok(decoded);
  assert.equal(decoded.v, 1);
  assert.equal(decoded.session_id, 'sess-1');
  assert.equal(decoded.seq, 3);
  assert.equal(decoded.sender, 'hmd');
  assert.equal(decoded.type, 'state');
  assert.deepEqual(Array.from(decoded.ciphertext), Array.from(ciphertext));
  assert.equal(typeof decoded.nonce, 'string');
});

test('encodeHmdEnvelope\'s displayed nonce matches the real seal() nonce layout', () => {
  const key = new Uint8Array(32).fill(0x77);
  const plaintext = new TextEncoder().encode('nonce-display-check');
  const sealed = seal(key, 'hmd', 9, plaintext);
  const line = encodeHmdEnvelope({ sessionId: 's', seq: 9, type: 'ack', ciphertext: sealed.ciphertext });
  const decoded = decodeEnvelope(line);
  const nonceBytes = base64Decode(decoded.nonce);
  assert.equal(nonceBytes.length, 12);
  assert.deepEqual(Array.from(nonceBytes.slice(0, 4)), [0x68, 0x6d, 0x64, 0x00]); // "hmd\0"
  assert.equal(new DataView(nonceBytes.buffer, nonceBytes.byteOffset).getBigUint64(4, false), 9n);
});

test('decodeEnvelope decodes a device_bound control frame with a payload', () => {
  const line = JSON.stringify({
    v: 1,
    session_id: 'sess-2',
    seq: 0,
    sender: 'relay',
    type: 'device_bound',
    nonce: null,
    ciphertext: null,
    payload: { device_token: 'opaque-reconnect-credential', device_pubkey: base64Encode(new Uint8Array(32).fill(9)) },
  });
  const decoded = decodeEnvelope(line);
  assert.ok(decoded);
  assert.equal(decoded.type, 'device_bound');
  assert.equal(decoded.ciphertext, null);
  assert.equal(typeof decoded.payload.device_token, 'string');
});

test('decodeEnvelope is fail-closed on structural mismatches', () => {
  assert.equal(decodeEnvelope('not json'), null);
  assert.equal(decodeEnvelope('null'), null);
  assert.equal(decodeEnvelope('[]'), null);
  assert.equal(decodeEnvelope(JSON.stringify({ v: 2, session_id: 's', seq: 0, sender: 'hmd', type: 'state', nonce: null, ciphertext: 'AA==' })), null);
  assert.equal(decodeEnvelope(JSON.stringify({ v: 1, session_id: 's', seq: -1, sender: 'hmd', type: 'state', ciphertext: 'AA==' })), null);
  assert.equal(decodeEnvelope(JSON.stringify({ v: 1, session_id: 's', seq: 0, sender: 'nobody', type: 'state', ciphertext: 'AA==' })), null);
  assert.equal(decodeEnvelope(JSON.stringify({ v: 1, session_id: 's', seq: 0, sender: 'hmd', type: 'unknown-type', ciphertext: 'AA==' })), null);
  assert.equal(decodeEnvelope(JSON.stringify({ v: 1, session_id: 's', seq: 0, sender: 'hmd', type: 'state', ciphertext: 'not-base64!!' })), null);
  assert.equal(decodeEnvelope(JSON.stringify({ v: 1, session_id: 's', seq: 0, sender: 'hmd', type: 'state' })), null); // missing ciphertext
});

test('base64Encode/base64Decode round-trip and reject malformed input', () => {
  const bytes = new Uint8Array([0, 1, 2, 253, 254, 255]);
  const encoded = base64Encode(bytes);
  const decoded = base64Decode(encoded);
  assert.deepEqual(Array.from(decoded), Array.from(bytes));
  assert.equal(base64Decode('not base64!!'), null);
  assert.equal(base64Decode('AB'), null); // not a multiple of 4
});

test('base64UrlEncode/base64UrlDecode round-trip and reject malformed input', () => {
  const bytes = new Uint8Array([0, 1, 2, 253, 254, 255]);
  const encoded = base64UrlEncode(bytes);
  assert.doesNotMatch(encoded, /[+/=]/);
  const decoded = base64UrlDecode(encoded);
  assert.deepEqual(Array.from(decoded), Array.from(bytes));
  assert.equal(base64UrlDecode('not base64url!!'), null);
  assert.equal(base64UrlDecode('a'), null); // length % 4 === 1, no valid encoding
});

// --- fake-hmd.mjs: parseArgs / resolveStatePath / command+ack codecs ----

test('parseArgs requires --relay', () => {
  assert.throws(() => parseArgs([]), /--relay <url> is required/);
});

test('parseArgs accepts --help without requiring --relay', () => {
  const args = parseArgs(['--help']);
  assert.equal(args.help, true);
});

test('parseArgs captures --relay, --state, --phone-pubkey', () => {
  const args = parseArgs(['--relay', 'https://example.workers.dev', '--state', 'foo.json', '--phone-pubkey', 'abcd']);
  assert.equal(args.relay, 'https://example.workers.dev');
  assert.equal(args.state, 'foo.json');
  assert.equal(args.phonePubkey, 'abcd');
  assert.equal(args.help, false);
});

test('parseArgs rejects an unrecognized flag', () => {
  assert.throws(() => parseArgs(['--relay', 'https://x', '--bogus']), /unrecognized argument: --bogus/);
});

test('parseArgs rejects a flag missing its value', () => {
  assert.throws(() => parseArgs(['--relay']), /--relay requires a value/);
});

test('resolveStatePath defaults to docs/samples/state.json under the repo root', () => {
  const resolved = resolveStatePath(undefined);
  assert.equal(resolved, join(REPO_ROOT, 'docs/samples/state.json'));
  assert.ok(existsSync(resolved), `expected the real sample fixture to exist at ${resolved}`);
});

test('resolveStatePath resolves a relative --state against the repo root, not cwd', () => {
  const resolved = resolveStatePath('docs/samples/state.json');
  assert.equal(resolved, join(REPO_ROOT, 'docs/samples/state.json'));
});

test('resolveStatePath passes an absolute --state through untouched', () => {
  const resolved = resolveStatePath('/tmp/some-state.json');
  assert.equal(resolved, '/tmp/some-state.json');
});

test('decodeSendMessageCommand round-trips a send-message action', () => {
  const bytes = new TextEncoder().encode(JSON.stringify({ action: 'send-message', params: { text: 'hello from phone' } }));
  const decoded = decodeSendMessageCommand(bytes);
  assert.deepEqual(decoded, { action: 'send-message', params: { text: 'hello from phone' } });
});

test('decodeSendMessageCommand is fail-closed on structural mismatches', () => {
  const enc = (v) => new TextEncoder().encode(typeof v === 'string' ? v : JSON.stringify(v));
  assert.equal(decodeSendMessageCommand(enc('not json')), null);
  assert.equal(decodeSendMessageCommand(enc([])), null);
  assert.equal(decodeSendMessageCommand(enc({ action: 'save-checkpoint', params: {} })), null);
  assert.equal(decodeSendMessageCommand(enc({ action: 'send-message', params: {} })), null);
  assert.equal(decodeSendMessageCommand(enc({ action: 'send-message', params: { text: 42 } })), null);
});

test('buildAckPayload omits detail on success and includes it on failure', () => {
  assert.equal(buildAckPayload(3, true), JSON.stringify({ of_seq: 3, ok: true }));
  assert.equal(buildAckPayload(3, false, 'malformed-command'), JSON.stringify({ of_seq: 3, ok: false, detail: 'malformed-command' }));
});

test('resolvePhonePubkey prefers --phone-pubkey over the payload when both are present', () => {
  const override = new Uint8Array(32).fill(1);
  const payload = new Uint8Array(32).fill(2);
  const envelope = { payload: { device_pubkey: base64UrlEncode(payload) } };
  const resolved = resolvePhonePubkey(envelope, base64UrlEncode(override));
  assert.deepEqual(Array.from(resolved), Array.from(override));
});

test('resolvePhonePubkey falls back to payload.device_pubkey when no override is given', () => {
  const payload = new Uint8Array(32).fill(3);
  const envelope = { payload: { device_pubkey: base64UrlEncode(payload) } };
  const resolved = resolvePhonePubkey(envelope, undefined);
  assert.deepEqual(Array.from(resolved), Array.from(payload));
});

test('resolvePhonePubkey decodes a base64url device_pubkey containing bytes standard base64 would render as +///= (live-relay regression)', () => {
  const pubkey = new Uint8Array(32);
  pubkey.fill(0xfb, 0, 16);
  pubkey.fill(0xff, 16, 32);
  const encoded = base64UrlEncode(pubkey);
  assert.match(encoded, /^[A-Za-z0-9_-]{43}$/);
  const envelope = { payload: { device_pubkey: encoded } };
  const resolved = resolvePhonePubkey(envelope, undefined);
  assert.deepEqual(Array.from(resolved), Array.from(pubkey));
});

test('resolvePhonePubkey returns null when neither override nor payload is present', () => {
  assert.equal(resolvePhonePubkey({ payload: undefined }, undefined), null);
  assert.equal(resolvePhonePubkey({ payload: { bound_at: 123 } }, undefined), null);
});

// --- keepalive control frame ---------------------------------------------

test('decodeEnvelope accepts the relay keepalive control frame', () => {
  const line = JSON.stringify({
    v: 1,
    session_id: 'sess-keepalive',
    seq: 0,
    sender: 'relay',
    type: 'keepalive',
    nonce: null,
    ciphertext: null,
    payload: { ts: 1758700000 },
  });
  const decoded = decodeEnvelope(line);
  assert.ok(decoded, 'a keepalive must decode, not be dropped as a malformed line');
  assert.equal(decoded.type, 'keepalive');
  assert.equal(decoded.ciphertext, null);
  assert.equal(decoded.payload.ts, 1758700000);
});

test('decodeEnvelope accepts a keepalive with no payload at all', () => {
  const decoded = decodeEnvelope(
    JSON.stringify({ v: 1, session_id: 's', seq: 0, sender: 'relay', type: 'keepalive', nonce: null, ciphertext: null })
  );
  assert.ok(decoded);
  assert.equal(decoded.type, 'keepalive');
});

// --- reconnect loop ------------------------------------------------------
//
// Cloudflare closed a live 5-minute-idle GET /stream on 2026-09-24 and this
// tool treated it as fatal. The loop below is what makes that survivable;
// the fakes here drive it without a relay, a socket, or a real clock.

/** Records what the loop asked to sleep for, and never actually waits.
 *  `outcomes` is consumed one per `runOnce` call, the last one repeating.
 *  The two stop knobs are separate on purpose: `stopAfterSleeps` walks a
 *  fixed length of the backoff ladder, while `stopAfterCalls` models a stop
 *  (Ctrl-C) landing while a stream is being served, before any wait. */
function makeFakes({ outcomes, stopAfterSleeps = Infinity, stopAfterCalls = Infinity }) {
  const slept = [];
  const reconnectFlags = [];
  let calls = 0;
  return {
    slept,
    reconnectFlags,
    callCount: () => calls,
    sleep: async (ms) => {
      slept.push(ms);
    },
    isStopped: () => slept.length >= stopAfterSleeps || calls >= stopAfterCalls,
    runOnce: async (isReconnect) => {
      reconnectFlags.push(isReconnect);
      const outcome = outcomes[calls] ?? outcomes[outcomes.length - 1];
      calls += 1;
      if (outcome instanceof Error) throw outcome;
      return outcome;
    },
  };
}

test('nextBackoffMs doubles from the base and caps at BACKOFF_CAP_MS', () => {
  assert.equal(BACKOFF_BASE_MS, 1000);
  assert.equal(BACKOFF_CAP_MS, 30000);
  assert.equal(nextBackoffMs(BACKOFF_BASE_MS), 2000);
  assert.equal(nextBackoffMs(2000), 4000);
  assert.equal(nextBackoffMs(16000), 30000);
  assert.equal(nextBackoffMs(30000), 30000);
});

test('nextBackoffMs floors a missing or nonsensical previous delay at the base', () => {
  assert.equal(nextBackoffMs(undefined), BACKOFF_BASE_MS);
  assert.equal(nextBackoffMs(null), BACKOFF_BASE_MS);
  assert.equal(nextBackoffMs(0), BACKOFF_BASE_MS);
  assert.equal(nextBackoffMs(-5), BACKOFF_BASE_MS);
  assert.equal(nextBackoffMs(Number.NaN), BACKOFF_BASE_MS);
});

test('runStreamWithReconnect reopens the stream after a close instead of exiting', async () => {
  const fakes = makeFakes({ outcomes: ['closed', 'closed', 'session-ended'] });
  const result = await runStreamWithReconnect(fakes);
  assert.equal(result, 'session-ended');
  assert.equal(fakes.callCount(), 3);
  // First attempt is an open, the two after it are reconnects.
  assert.deepEqual(fakes.reconnectFlags, [false, true, true]);
});

test('runStreamWithReconnect escalates the delay across consecutive failures to open', async () => {
  const fakes = makeFakes({ outcomes: ['open-failed'], stopAfterSleeps: 6 });
  const result = await runStreamWithReconnect(fakes);
  assert.equal(result, 'stopped');
  assert.deepEqual(fakes.slept, [1000, 2000, 4000, 8000, 16000, 30000]);
});

test('runStreamWithReconnect caps the escalating delay at 30s no matter how long it fails', async () => {
  const fakes = makeFakes({ outcomes: ['open-failed'], stopAfterSleeps: 11 });
  await runStreamWithReconnect(fakes);
  assert.equal(Math.max(...fakes.slept), BACKOFF_CAP_MS);
  assert.deepEqual(fakes.slept.slice(-3), [30000, 30000, 30000]);
});

test('runStreamWithReconnect resets the delay after a stream that actually opened', async () => {
  // Two failures to open escalate to 4s; then a stream opens and closes, and
  // the ladder starts over at 1s -- the observed 5-minute cut must not creep
  // the reconnect delay upward over a long session.
  const fakes = makeFakes({
    outcomes: ['open-failed', 'open-failed', 'closed', 'closed'],
    stopAfterSleeps: 4,
  });
  await runStreamWithReconnect(fakes);
  assert.deepEqual(fakes.slept, [1000, 2000, 1000, 1000]);
});

test('runStreamWithReconnect stops without sleeping once the session ends', async () => {
  const fakes = makeFakes({ outcomes: ['session-ended'] });
  assert.equal(await runStreamWithReconnect(fakes), 'session-ended');
  assert.deepEqual(fakes.slept, []);
});

test('runStreamWithReconnect stops when isStopped() flips (Ctrl-C / revoke)', async () => {
  const fakes = makeFakes({ outcomes: ['closed'], stopAfterCalls: 1 });
  assert.equal(await runStreamWithReconnect(fakes), 'stopped');
  assert.equal(fakes.callCount(), 1);
  assert.deepEqual(fakes.slept, []); // no pointless wait after the stop
});

test('runStreamWithReconnect never starts when already stopped', async () => {
  const fakes = makeFakes({ outcomes: ['closed'], stopAfterCalls: 0 });
  assert.equal(await runStreamWithReconnect(fakes), 'stopped');
  assert.equal(fakes.callCount(), 0);
});

test('runStreamWithReconnect propagates a FatalStreamError instead of retrying it', async () => {
  const fakes = makeFakes({ outcomes: [new FatalStreamError('bearer rejected (HTTP 401)')] });
  await assert.rejects(() => runStreamWithReconnect(fakes), FatalStreamError);
  assert.equal(fakes.callCount(), 1);
  assert.deepEqual(fakes.slept, []);
});

test('runStreamWithReconnect retries an ordinary error thrown by runOnce', async () => {
  // undici raises a bare TypeError('terminated') when the response body is
  // cut mid-stream -- the exact 2026-09-24 failure. It must not be fatal.
  const fakes = makeFakes({ outcomes: [new TypeError('terminated'), 'session-ended'] });
  assert.equal(await runStreamWithReconnect(fakes), 'session-ended');
  assert.equal(fakes.callCount(), 2);
  assert.deepEqual(fakes.slept, [1000]);
});

// --- end-to-end: seal a command as the phone would, open+ack as hmd does -

test('end-to-end: phone-side seal of a command opens and acks correctly on the hmd side', () => {
  const hmd = x25519.keygen(new Uint8Array(32).fill(0xaa));
  const phone = x25519.keygen(new Uint8Array(32).fill(0xbb));
  const sessionId = 'e2e-session';
  const hmdKey = deriveSessionKey(hmd.secretKey, phone.publicKey, sessionId);
  const phoneKey = deriveSessionKey(phone.secretKey, hmd.publicKey, sessionId);
  assert.equal(toHex(hmdKey), toHex(phoneKey));

  // Phone seals a send-message command under its own tag ('phn'), same as
  // src/transport/RelayTransport.ts's `seal(this.sessionKey, 'phn', seq, ...)`.
  const commandPlaintext = new TextEncoder().encode(JSON.stringify({ action: 'send-message', params: { text: 'ping' } }));
  const sealedCommand = seal(phoneKey, 'phn', 1, commandPlaintext);

  // hmd side (fake-hmd.mjs) opens it with the 'phn' tag and lastSeq=0.
  const openedCommand = open(hmdKey, 'phn', sealedCommand, 0);
  const command = decodeSendMessageCommand(openedCommand);
  assert.deepEqual(command, { action: 'send-message', params: { text: 'ping' } });

  // hmd acks under its own tag ('hmd'), the phone opens it back.
  const ackPlaintext = new TextEncoder().encode(buildAckPayload(sealedCommand.seq, true));
  const sealedAck = seal(hmdKey, 'hmd', 1, ackPlaintext);
  const openedAck = open(phoneKey, 'hmd', sealedAck, 0);
  assert.deepEqual(JSON.parse(Buffer.from(openedAck).toString('utf8')), { of_seq: 1, ok: true });
});

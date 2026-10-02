// Unit coverage for phone-sim.mjs's pure helpers -- the parts reachable
// without a live relay/heimdall socket. Live-socket behavior (device_bound
// handshake, ack routing, --reconnect/--dual-socket/--replay-seq probes) is
// exercised by hand against a real relay + real heimdall-relay-client per
// docs/HANDOFF-TO-HEIMDALL-relay-send-ack.md, the same division
// phone-leg-interop.test.mjs (wire-codec proof) and
// heimdall-client-interop.test.mjs (opt-in, HMD_RELAY_INTEROP=1, live
// process) already draw for this script's siblings.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { x25519 } from '@noble/curves/ed25519.js';

import { deriveSessionKey, open } from '../lib/relay-crypto.mjs';
import { decodeEnvelope } from '../lib/envelope.mjs';
import { decodeSendMessageCommand } from '../fake-hmd.mjs';
import { decodeRelayFrame } from '../../../src/relay/protocol.ts';
import { isDeviceFrame } from '../../src/types.ts';
import {
  redact,
  parseArgs,
  validatePayload,
  buildWsUrl,
  buildCommandWire,
  INITIAL_SEQ,
} from '../phone-sim.mjs';

// Deterministic filler bytes, not credentials (CLAUDE.md: "no secret-shaped
// literals") -- same seeding convention phone-leg-interop.test.mjs uses.
const HMD = x25519.keygen(new Uint8Array(32).fill(0xaa));
const PHONE = x25519.keygen(new Uint8Array(32).fill(0xbb));
const SESSION_ID = 'phone-sim-test-session';
const HMD_KEY = deriveSessionKey(HMD.secretKey, PHONE.publicKey, SESSION_ID);
const PHONE_KEY = deriveSessionKey(PHONE.secretKey, HMD.publicKey, SESSION_ID);

const VALID_PAYLOAD = {
  v: 1,
  relay: 'https://hmd-relay.example.workers.dev',
  session_id: SESSION_ID,
  pairing_code: 'a-one-time-code-not-a-real-secret',
  hmd_pubkey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
};

test('redact masks any 24+ char base64url-ish run, leaves shorter runs alone', () => {
  const long = 'x'.repeat(24);
  const short = 'y'.repeat(23);
  const line = `device_token=${long} pairing_code=${short} plain text stays`;
  const out = redact(line);
  assert.ok(!out.includes(long), 'the 24-char run must not survive redaction');
  assert.ok(out.includes(`<redacted:24ch>`), 'redaction marker must record the masked length');
  assert.ok(out.includes(short), 'a run shorter than 24 chars must be left alone');
  assert.ok(out.includes('plain text stays'), 'non-matching text must be untouched');
});

test('redact is a no-op on text with no long runs', () => {
  const line = '[phone-sim] sockA sent seq=1 text="hello"';
  assert.equal(redact(line), line);
});

test('parseArgs applies defaults when only --payload is given', () => {
  const args = parseArgs(['--payload', '/tmp/qr.json']);
  assert.equal(args.payload, '/tmp/qr.json');
  assert.equal(args.count, 3);
  assert.equal(args.text, 'phone-sim ping');
  assert.equal(args.deviceName, 'phone-sim');
  assert.equal(args.ackTimeoutMs, 10000);
  assert.equal(args.reconnect, false);
  assert.equal(args.dualSocket, false);
  assert.equal(args.replaySeq, undefined);
});

test('parseArgs parses every flag, including the diagnostic probes', () => {
  const args = parseArgs([
    '--payload-json',
    '{}',
    '--count',
    '5',
    '--text',
    'hi',
    '--device-name',
    'test-phone',
    '--ack-timeout-ms',
    '2500',
    '--reconnect',
    '--dual-socket',
    '--replay-seq',
    '0',
    '--out',
    '/tmp/out.json',
  ]);
  assert.equal(args.payloadJson, '{}');
  assert.equal(args.count, 5);
  assert.equal(args.text, 'hi');
  assert.equal(args.deviceName, 'test-phone');
  assert.equal(args.ackTimeoutMs, 2500);
  assert.equal(args.reconnect, true);
  assert.equal(args.dualSocket, true);
  assert.equal(args.replaySeq, 0);
  assert.equal(args.out, '/tmp/out.json');
});

test('parseArgs requires --payload or --payload-json', () => {
  assert.throws(() => parseArgs([]), /--payload/);
});

test('parseArgs rejects an unrecognized flag', () => {
  assert.throws(() => parseArgs(['--payload', 'x', '--bogus']), /unrecognized argument/);
});

test('parseArgs --help needs no payload', () => {
  const args = parseArgs(['--help']);
  assert.equal(args.help, true);
});

test('validatePayload accepts a well-formed QR payload', () => {
  const result = validatePayload(VALID_PAYLOAD);
  assert.equal(result.ok, true);
});

test('validatePayload rejects a non-https relay URL', () => {
  const result = validatePayload({ ...VALID_PAYLOAD, relay: 'http://insecure.example' });
  assert.equal(result.ok, false);
  assert.match(result.error, /https/);
});

for (const field of ['session_id', 'pairing_code', 'hmd_pubkey']) {
  test(`validatePayload rejects a missing ${field}`, () => {
    const { [field]: _omit, ...rest } = VALID_PAYLOAD;
    const result = validatePayload(rest);
    assert.equal(result.ok, false);
  });
}

test('buildWsUrl on a fresh claim carries pairing_code + device_name, not device_token', () => {
  const url = new URL(
    buildWsUrl(VALID_PAYLOAD, { deviceToken: null, devicePubkeyB64u: 'abc123', deviceName: 'phone-sim' })
  );
  assert.equal(url.protocol, 'wss:');
  assert.equal(url.pathname, `/session/${SESSION_ID}/ws`);
  assert.equal(url.searchParams.get('device_pubkey'), 'abc123');
  assert.equal(url.searchParams.get('pairing_code'), VALID_PAYLOAD.pairing_code);
  assert.equal(url.searchParams.get('device_name'), 'phone-sim');
  assert.equal(url.searchParams.has('device_token'), false);
});

test('buildWsUrl on a reconnect carries device_token, not pairing_code/device_name', () => {
  const url = new URL(
    buildWsUrl(VALID_PAYLOAD, { deviceToken: 'sometoken', devicePubkeyB64u: 'abc123', deviceName: 'phone-sim' })
  );
  assert.equal(url.searchParams.get('device_pubkey'), 'abc123');
  assert.equal(url.searchParams.get('device_token'), 'sometoken');
  assert.equal(url.searchParams.has('pairing_code'), false);
  assert.equal(url.searchParams.has('device_name'), false);
});

test('buildCommandWire output passes the relay device-leg gate (isDeviceFrame)', () => {
  const wire = buildCommandWire(PHONE_KEY, SESSION_ID, INITIAL_SEQ, 'hello from phone-sim');
  assert.ok(isDeviceFrame(JSON.parse(wire)), 'the relay would drop this frame at webSocketMessage');
});

test('buildCommandWire output decodes on hmd GET /stream and opens back to the original text', () => {
  const wire = buildCommandWire(PHONE_KEY, SESSION_ID, 7, 'ship it via phone-sim');
  const envelope = decodeEnvelope(wire);
  assert.notEqual(envelope, null);
  assert.equal(envelope.type, 'command');
  assert.equal(envelope.sender, 'device');
  assert.equal(envelope.seq, 7);
  const plaintext = open(HMD_KEY, 'phn', { seq: envelope.seq, ciphertext: envelope.ciphertext }, 0);
  assert.deepEqual(decodeSendMessageCommand(plaintext), {
    action: 'send-message',
    params: { text: 'ship it via phone-sim' },
  });
});

test('buildCommandWire also round-trips through the app-side decoder (decodeRelayFrame)', () => {
  // phone-sim.mjs itself only ever decodes incoming ack/state/device_bound
  // frames with decodeRelayFrame, never its own outgoing command frame -- but
  // proving this direction too pins buildCommandWire's shape against the
  // exact module phone-sim.mjs imports, not just the hmd-leg's independent
  // copy above.
  const wire = buildCommandWire(PHONE_KEY, SESSION_ID, 2, 'round trip');
  const frame = decodeRelayFrame(wire);
  assert.notEqual(frame, null);
  assert.equal(frame.type, 'command');
  assert.equal(frame.seq, 2);
});

test('a non-increasing seq is what heimdall\'s guard rejects: open() itself already enforces it', () => {
  // Documents the exact condition --replay-seq is built to force against a
  // real heimdall-relay-client: seq <= lastSeq. relay-crypto.mjs's own open()
  // throws 'replay' for this case; the diagnostic question --replay-seq
  // answers is what heimdall's own guard does when *it* sees this, since its
  // check runs before decrypt (see docs/HANDOFF-TO-HEIMDALL-relay-send-ack.md).
  const wire = buildCommandWire(PHONE_KEY, SESSION_ID, 0, 'replayed');
  const envelope = decodeEnvelope(wire);
  assert.throws(
    () => open(HMD_KEY, 'phn', { seq: envelope.seq, ciphertext: envelope.ciphertext }, 0),
    (err) => err.reason === 'replay'
  );
});

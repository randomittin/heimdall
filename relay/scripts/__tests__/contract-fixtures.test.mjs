// node --test suite: the sealed frames in relay/contract/wire.json, checked with the JS crypto and
// envelope codec (scripts/lib/relay-crypto.mjs, scripts/lib/envelope.mjs -- the same @noble
// primitives the phone app is built on).
//
// The fixture's bytes were produced by bin/heimdall-relay-client and its pure-python E2E module;
// heimdall's test/relay-contract-fixtures.test.sh replays them on that side. A pass here is the
// cross-language proof the contract exists for: what python sealed opens in JS, what JS seals is
// byte-identical to what python sealed, and the envelope codec accepts every line the wire carries.
// (relay/test/contract.spec.ts covers the other half: the real Worker driven with the same file.)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { x25519 } from '@noble/curves/ed25519.js';

import { deriveSessionKey, seal, open } from '../lib/relay-crypto.mjs';
import { base64Decode, base64Encode, base64UrlEncode, buildDisplayNonce, decodeEnvelope } from '../lib/envelope.mjs';

const CONTRACT_DIR = join(fileURLToPath(new URL('.', import.meta.url)), '..', '..', 'contract');
const wire = JSON.parse(readFileSync(join(CONTRACT_DIR, 'wire.json'), 'utf8'));
const vectors = JSON.parse(readFileSync(join(CONTRACT_DIR, 'vectors.json'), 'utf8'));

const fromHex = (hex) => new Uint8Array(Buffer.from(hex, 'hex'));
const hmd = x25519.keygen(fromHex(vectors.hmdSeedHex));
const phn = x25519.keygen(fromHex(vectors.phnSeedHex));
const sessionId = wire.bindings.session_id.example;
const hmdKey = deriveSessionKey(hmd.secretKey, phn.publicKey, sessionId);
const phnKey = deriveSessionKey(phn.secretKey, hmd.publicKey, sessionId);

const computed = {
  device_pubkey_b64url: base64UrlEncode(phn.publicKey),
  hmd_pubkey_b64: base64Encode(hmd.publicKey),
};

/** `$name` placeholders -> their example (or computed) values; a whole-string placeholder keeps its type. */
function instantiate(node) {
  const valueOf = (name) => {
    const binding = wire.bindings[name];
    return 'computed' in binding ? computed[binding.computed] : binding.example;
  };
  if (typeof node === 'string') {
    const whole = /^\$([a-z_]+)$/.exec(node);
    if (whole) return valueOf(whole[1]);
    return node.replace(/\$([a-z_]+)/g, (_m, name) => String(valueOf(name)));
  }
  if (Array.isArray(node)) return node.map(instantiate);
  if (node !== null && typeof node === 'object') {
    return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, instantiate(v)]));
  }
  return node;
}

// The wire says sender "device"; the crypto's nonce tag for that direction is "phn" (INV-13).
const tagOf = (sender) => (sender === 'hmd' ? 'hmd' : 'phn');

for (const [name, frame] of Object.entries(wire.frames)) {
  const { seq, sender, type } = frame.wire;
  const sealerKey = sender === 'hmd' ? hmdKey : phnKey;
  const openerKey = sender === 'hmd' ? phnKey : hmdKey;
  const plaintext = new TextEncoder().encode(JSON.stringify(frame.plaintext));

  test(`sealed frame ${name}: JS seal() is byte-identical to what python sealed`, () => {
    const sealed = seal(sealerKey, tagOf(sender), seq, plaintext);
    assert.equal(base64Encode(sealed.ciphertext), frame.wire.ciphertext);
    assert.equal(buildDisplayNonce(tagOf(sender), seq), frame.wire.nonce);
  });

  test(`sealed frame ${name}: opens in JS on the receiving side`, () => {
    const opened = open(openerKey, tagOf(sender), { seq, ciphertext: base64Decode(frame.wire.ciphertext) }, 0);
    assert.deepEqual(JSON.parse(Buffer.from(opened).toString('utf8')), frame.plaintext);
  });

  test(`sealed frame ${name}: the envelope codec accepts the exact wire line`, () => {
    const decoded = decodeEnvelope(JSON.stringify(frame.wire));
    assert.ok(decoded, 'a frame the clients put on the wire must decode');
    assert.equal(decoded.seq, seq);
    assert.equal(decoded.sender, sender);
    assert.equal(decoded.type, type);
    assert.equal(decoded.session_id, sessionId);
  });
}

test('a tampered fixture frame does not open (the check above is not vacuous)', () => {
  const frame = wire.frames.state;
  const tampered = base64Decode(frame.wire.ciphertext);
  tampered[0] ^= 0x01;
  assert.throws(() => open(phnKey, 'hmd', { seq: frame.wire.seq, ciphertext: tampered }, 0));
});

test('every relay-minted hmd-leg line in the fixture decodes as a control frame', () => {
  for (const [name, template] of Object.entries(wire.stream.lines)) {
    const decoded = decodeEnvelope(JSON.stringify(instantiate(template)));
    assert.ok(decoded, `${name} must decode`);
    assert.equal(decoded.sender, 'relay');
    assert.equal(decoded.ciphertext, null);
  }
});

test('the phone-leg device_bound and revoke frames decode as control frames too', () => {
  for (const template of [wire.phone.device_bound, wire.phone.revoked.session_ended]) {
    const decoded = decodeEnvelope(JSON.stringify(instantiate(template)));
    assert.ok(decoded);
    assert.equal(decoded.sender, 'relay');
  }
});

test('hmd WebSocket leg: device_bound is the NDJSON line\'s envelope and decodes as a relay control frame', () => {
  const message = wire.stream_ws.messages.device_bound;
  assert.deepEqual(message, wire.stream.lines.device_bound, 'a WebSocket message is an NDJSON line without its newline');
  const decoded = decodeEnvelope(JSON.stringify(instantiate(message)));
  assert.ok(decoded, 'stream_ws device_bound must decode');
  assert.equal(decoded.sender, 'relay');
  assert.equal(decoded.type, 'device_bound');
  assert.equal(decoded.ciphertext, null);
  assert.equal(decoded.payload.device_pubkey, computed.device_pubkey_b64url);
});

test('hmd WebSocket leg: ping and pong are plain text, never an envelope', () => {
  for (const text of [wire.stream_ws.messages.client_ping, wire.stream_ws.messages.relay_pong]) {
    assert.equal(typeof text, 'string');
    assert.equal(decodeEnvelope(text), null, `${text} must not decode as an envelope`);
  }
});

/** The payload of one unfragmented RFC 6455 text frame, unmasked when the mask bit is set. */
function textFramePayload(hex) {
  const bytes = fromHex(hex);
  assert.equal(bytes[0], 0x81, 'FIN set, text opcode');
  const length = bytes[1] & 0x7f;
  assert.ok(length < 126, 'a short payload');
  const mask = (bytes[1] & 0x80) === 0 ? null : bytes.subarray(2, 6);
  const payload = bytes.subarray(mask === null ? 2 : 6);
  assert.equal(payload.length, length, 'the frame is exactly its header and payload');
  return Buffer.from(payload.map((byte, i) => (mask === null ? byte : byte ^ mask[i % 4]))).toString('utf8');
}

test('hmd WebSocket leg: the pinned ping and pong octets are RFC 6455 text frames of the fixture\'s messages', () => {
  const { frames, messages } = wire.stream_ws;
  assert.equal(textFramePayload(frames.client_ping.hex), messages.client_ping);
  assert.equal(frames.client_ping.hex.slice(4, 12), frames.client_ping.mask, 'the pinned mask is the one in the frame');
  assert.equal(textFramePayload(frames.relay_pong.hex), messages.relay_pong);
});

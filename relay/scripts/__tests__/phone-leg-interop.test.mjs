// Cross-boundary WIRE-CODEC interop, phone -> relay -> hmd.
//
// Every module on this path already had its own tests, and all of them were
// green while a real phone's Chat send died at the relay with a 10s ack
// timeout (live, 2026-09-24): each side was tested against its own idea of
// the wire, and nothing tested them against each other. fake-hmd.test.mjs's
// "end-to-end: phone-side seal of a command opens and acks correctly on the
// hmd side" crosses the CRYPTO boundary but hands `open()` the in-memory
// sealed object, so the encode -> validate -> decode leg it never touches is
// exactly where the frame was being dropped.
//
// So this file imports the three real implementations, unmocked, and runs a
// frame through all of them in the order the live path does:
//
//   src/relay/protocol.ts       encodeEncryptedFrame   (the app, phone leg)
//     -> relay/src/types.ts     isEnvelope             (the relay's gate in
//                                                       session.ts's
//                                                       webSocketMessage)
//     -> relay/scripts/lib/envelope.mjs decodeEnvelope (hmd's GET /stream)
//     -> relay/scripts/fake-hmd.mjs decodeSendMessageCommand
//
// The two `.ts` imports run on Node's native type stripping (Node >= 22.6;
// both files are import-free, erasable-syntax-only modules). That is the
// point: no fixture, no hand-copied shape, no second implementation to drift
// -- if either side changes its wire shape unilaterally again, this test goes
// red instead of a phone going silent.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { x25519 } from '@noble/curves/ed25519.js';

import { deriveSessionKey, seal, open } from '../lib/relay-crypto.mjs';
import { decodeEnvelope, buildDisplayNonce } from '../lib/envelope.mjs';
import { decodeSendMessageCommand } from '../fake-hmd.mjs';
import { encodeEncryptedFrame, encodeSendMessageCommand } from '../../../src/relay/protocol.ts';
import { isEnvelope } from '../../src/types.ts';

// Deterministic filler bytes, not credentials (CLAUDE.md: "no secret-shaped
// literals") -- the same 0xaa/0xbb seeds fake-hmd.test.mjs's own end-to-end
// case uses.
const HMD = x25519.keygen(new Uint8Array(32).fill(0xaa));
const PHONE = x25519.keygen(new Uint8Array(32).fill(0xbb));
const SESSION_ID = 'interop-session';
const HMD_KEY = deriveSessionKey(HMD.secretKey, PHONE.publicKey, SESSION_ID);
const PHONE_KEY = deriveSessionKey(PHONE.secretKey, HMD.publicKey, SESSION_ID);

/** Builds the wire string the app really puts on the socket for one Chat
 *  send -- `RelayTransport.send`'s two lines (seal, then encode), verbatim. */
function phoneCommandWire(text, seq) {
  const sealed = seal(PHONE_KEY, 'phn', seq, encodeSendMessageCommand(text));
  return encodeEncryptedFrame({
    sessionId: SESSION_ID,
    sender: 'device',
    type: 'command',
    seq: sealed.seq,
    ciphertext: sealed.ciphertext,
  });
}

test("the app's outbound command frame passes the relay's isEnvelope gate", () => {
  // relay/src/session.ts's webSocketMessage drops anything isEnvelope
  // rejects, silently and before any logging -- the live failure.
  const wire = phoneCommandWire('hello from the phone', 1);
  assert.ok(
    isEnvelope(JSON.parse(wire)),
    `the relay would drop this frame: ${Object.keys(JSON.parse(wire)).join(',')}`
  );
});

test("the app's outbound command frame decodes on hmd's GET /stream", () => {
  // The relay forwards the accepted envelope byte-identical (INV-18), so the
  // line hmd reads is the app's own bytes plus a newline.
  const wire = phoneCommandWire('hello from the phone', 1);
  const envelope = decodeEnvelope(wire);
  assert.notEqual(envelope, null, 'fake-hmd would log "dropped malformed stream line"');
  assert.equal(envelope.type, 'command');
  assert.equal(envelope.sender, 'device');
  assert.equal(envelope.session_id, SESSION_ID);
  assert.equal(envelope.seq, 1);
});

test('a phone command opens under the phn tag and yields the original text', () => {
  const wire = phoneCommandWire('ship it', 4);
  const envelope = decodeEnvelope(wire);
  const plaintext = open(HMD_KEY, 'phn', { seq: envelope.seq, ciphertext: envelope.ciphertext }, 0);
  assert.deepEqual(decodeSendMessageCommand(plaintext), {
    action: 'send-message',
    params: { text: 'ship it' },
  });
});

test('the wire nonce matches the one hmd-leg envelope.mjs derives independently', () => {
  // Two independent implementations of INV-13's `sender tag || be64(seq)`
  // layout: the app's (protocol.ts) and the hmd leg's (envelope.mjs). No
  // decoder trusts a wire nonce -- both sides rebuild it from (tag, seq) --
  // but a client that reads the field must not be handed filler.
  const wire = JSON.parse(phoneCommandWire('nonce check', 9));
  assert.equal(wire.nonce, buildDisplayNonce('phn', 9));
});

test("an hmd-sender frame carries the hmd tag's nonce, not the phone's", () => {
  // The same encoder builds the fixtures that stand in for hmd's side of the
  // wire (src/transport/__tests__/RelayTransport.test.ts), so the sender ->
  // crypto-tag mapping has to hold in both directions.
  const sealed = seal(HMD_KEY, 'hmd', 3, new TextEncoder().encode('{}'));
  const wire = JSON.parse(
    encodeEncryptedFrame({
      sessionId: SESSION_ID,
      sender: 'hmd',
      type: 'state',
      seq: sealed.seq,
      ciphertext: sealed.ciphertext,
    })
  );
  assert.equal(wire.sender, 'hmd');
  assert.equal(wire.nonce, buildDisplayNonce('hmd', 3));
  assert.ok(isEnvelope(wire));
});

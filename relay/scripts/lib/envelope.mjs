// hmd-leg outer `Envelope` wire codec (relay/README.md "Envelope (wire shape,
// both directions)"), independent of src/relay/protocol.ts's phone-leg inner
// frame codec (`{type, seq, ciphertext}`, no v/session_id/sender/nonce --
// those are implicit on a single WebSocket connection). hmd's leg has no
// persistent connection (POST /frames, GET /stream are separate HTTP
// exchanges), so the wire shape carries session_id/sender explicitly.
//
// `nonce` is populated on encode for wire completeness only. Per
// src/relay/crypto.ts's own `open()` doc comment, the nonce is reconstructed
// "from expectedSenderTag and envelope.seq -- a wire-supplied nonce, if any,
// is never trusted" (INV-13): decodeEnvelope below never uses `.nonce` for
// anything beyond a structural shape check; every real decrypt goes through
// relay-crypto.mjs's seal/open, which derive the true nonce internally. This
// module only ever builds frames where sender="hmd" (fake-hmd.mjs never
// originates a "device" frame -- that is the phone's job), so the crypto
// sender tag ('hmd'|'phn', src/relay/crypto.ts's SenderTag) and the wire
// `sender` string share the literal "hmd" here; they diverge only for
// phone-originated frames (wire sender "device" vs crypto tag 'phn'), which
// this module only ever decodes, never encodes, so no encode-side mapping is
// needed for that direction.
//
// No I/O, no module-level state -- pure encode/decode, same fail-closed
// house style as protocol.ts/relayPayload.ts: any structural mismatch on
// decode returns `null`, never throws, never partially populates.
import { Buffer } from 'node:buffer';

const SENDER_TAG_BYTES = {
  hmd: new Uint8Array([0x68, 0x6d, 0x64, 0x00]), // "hmd\0"
  phn: new Uint8Array([0x70, 0x68, 0x6e, 0x00]), // "phn\0"
};

const FRAME_SENDERS = new Set(['hmd', 'device', 'relay']);
const FRAME_TYPES = new Set(['state', 'command', 'ack', 'device_bound', 'session_ended']);
const ENCRYPTED_TYPES = new Set(['state', 'command', 'ack']);

// Standard base64 (with padding): groups of 4 chars, optional trailing
// `=`/`==` on the final group only -- matches relayPayload.ts's
// HMD_PUBKEY_PATTERN alphabet.
const BASE64_SHAPE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

export function base64Encode(bytes) {
  return Buffer.from(bytes).toString('base64');
}

/** Fail-closed: anything that doesn't look like well-formed base64 returns
 *  `null` rather than handing `Buffer.from`'s lenient (silently-truncating)
 *  decode a value it would otherwise accept. */
export function base64Decode(value) {
  if (typeof value !== 'string' || !BASE64_SHAPE.test(value)) return null;
  return new Uint8Array(Buffer.from(value, 'base64'));
}

/** Mirrors src/relay/crypto.ts's private `buildNonce` exactly (same 4-byte
 *  tag + 8-byte big-endian seq layout, INV-13) so the wire `nonce` field
 *  carries real, correct data -- never a placeholder -- even though no
 *  decoder anywhere trusts a wire-supplied nonce back (see module doc). */
export function buildDisplayNonce(senderTag, seq) {
  const nonce = new Uint8Array(12);
  nonce.set(SENDER_TAG_BYTES[senderTag], 0);
  new DataView(nonce.buffer).setBigUint64(4, BigInt(seq), false);
  return base64Encode(nonce);
}

/** Encodes an outgoing `state`/`ack` envelope. fake-hmd.mjs is always the
 *  sender ("hmd") on every frame it originates. */
export function encodeHmdEnvelope({ sessionId, seq, type, ciphertext }) {
  return JSON.stringify({
    v: 1,
    session_id: sessionId,
    seq,
    sender: 'hmd',
    type,
    nonce: buildDisplayNonce('hmd', seq),
    ciphertext: base64Encode(ciphertext),
  });
}

/** Decodes one NDJSON line from `GET /session/:id/stream` into a typed
 *  Envelope, or `null` on any structural mismatch. Never throws -- a
 *  malformed line is dropped by the caller, not crashed on. */
export function decodeEnvelope(line) {
  let parsed;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null;

  const { v, session_id: sessionId, seq, sender, type } = parsed;
  if (v !== 1) return null;
  if (typeof sessionId !== 'string') return null;
  if (typeof seq !== 'number' || !Number.isInteger(seq) || seq < 0) return null;
  if (!FRAME_SENDERS.has(sender)) return null;
  if (!FRAME_TYPES.has(type)) return null;

  if (type === 'device_bound' || type === 'session_ended') {
    const { payload } = parsed;
    if (payload !== undefined && (typeof payload !== 'object' || payload === null || Array.isArray(payload))) {
      return null;
    }
    return { v: 1, session_id: sessionId, seq, sender, type, nonce: null, ciphertext: null, payload };
  }

  if (ENCRYPTED_TYPES.has(type)) {
    if (typeof parsed.ciphertext !== 'string') return null;
    const ciphertext = base64Decode(parsed.ciphertext);
    if (ciphertext === null) return null;
    const nonce = typeof parsed.nonce === 'string' ? parsed.nonce : null;
    return { v: 1, session_id: sessionId, seq, sender, type, nonce, ciphertext, payload: undefined };
  }

  return null;
}

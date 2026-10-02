// Byte-exact plain-Node port of src/relay/crypto.ts (X25519 ECDH, HKDF-SHA256
// session-key derivation, ChaCha20-Poly1305 seal/open with a deterministic
// seq-derived nonce). Same constants, same function signatures, same
// @noble/* primitives -- verified against the same shared golden vector
// (src/relay/__tests__/fixtures/vectors.json) in
// relay/scripts/__tests__/fake-hmd.test.mjs.
//
// Reimplemented rather than imported because src/relay/crypto.ts imports
// `@/relay/randomBytes`, a React Native/Hermes-only shim
// (react-native-get-random-values) that does not exist in a plain Node
// process -- this module uses node:crypto's randomBytes instead. Everything
// else (constants, nonce layout, derivation, error shape) is a direct copy.
//
// Spec of record: relay/docs/2026-09-21-hmd-relay-design.md §2.1-2.3
// Invariants:      relay/docs/INVARIANTS.md INV-11..INV-19
//
// No I/O, no module-level state -- pure crypto, same division of labour as
// the file it mirrors.
import { randomBytes as nodeRandomBytes } from 'node:crypto';
import { x25519 } from '@noble/curves/ed25519.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { chacha20poly1305 } from '@noble/ciphers/chacha.js';

/** Relay never buffers or forwards a larger envelope (spec §2.3, INV-16). */
export const MAX_ENVELOPE_BYTES = 1048576;

/** ChaCha20-Poly1305 auth tag length appended to the plaintext (RFC 8439). */
const TAG_BYTES = 16;

/** Nonce layout per INV-13: 4-byte sender tag || 8-byte big-endian seq. */
const SENDER_TAG_BYTES = {
  hmd: new Uint8Array([0x68, 0x6d, 0x64, 0x00]), // "hmd\0"
  phn: new Uint8Array([0x70, 0x68, 0x6e, 0x00]), // "phn\0"
};

export class RelayCryptoError extends Error {
  constructor(reason, message) {
    super(message);
    this.name = 'RelayCryptoError';
    this.reason = reason;
  }
}

/** Generates a fresh X25519 ephemeral key pair from secure randomness. */
export function generateEphemeralKeyPair() {
  const seed = nodeRandomBytes(32);
  const { secretKey, publicKey } = x25519.keygen(seed);
  return { secretKey, publicKey };
}

/**
 * Derives the 32-byte session key (INV-11):
 * `HKDF-SHA256(ikm=ECDH(myPriv, theirPub), salt=sessionId, info="hmd-relay-v1", len=32)`.
 */
export function deriveSessionKey(myPriv, theirPub, sessionId) {
  const ikm = x25519.getSharedSecret(myPriv, theirPub);
  const salt = new TextEncoder().encode(sessionId);
  const info = new TextEncoder().encode('hmd-relay-v1');
  return hkdf(sha256, ikm, salt, info, 32);
}

function assertValidSeq(seq) {
  if (!Number.isInteger(seq) || seq < 0 || seq > Number.MAX_SAFE_INTEGER) {
    throw new RelayCryptoError(
      'invalid-seq',
      `seq must be a non-negative safe integer, got ${seq}`
    );
  }
}

function buildNonce(tag, seq) {
  assertValidSeq(seq);
  const nonce = new Uint8Array(12);
  nonce.set(SENDER_TAG_BYTES[tag], 0);
  new DataView(nonce.buffer).setBigUint64(4, BigInt(seq), false); // big-endian
  return nonce;
}

/**
 * Seals `plaintext` under `key` for `senderTag` at sequence `seq`. The nonce
 * is always derived deterministically from (senderTag, seq) per INV-13 --
 * callers never supply or see it directly.
 */
export function seal(key, senderTag, seq, plaintext) {
  if (plaintext.byteLength + TAG_BYTES > MAX_ENVELOPE_BYTES) {
    throw new RelayCryptoError(
      'oversized',
      `plaintext (${plaintext.byteLength}B + ${TAG_BYTES}B tag) exceeds MAX_ENVELOPE_BYTES (${MAX_ENVELOPE_BYTES})`
    );
  }
  const nonce = buildNonce(senderTag, seq);
  const ciphertext = chacha20poly1305(key, nonce).encrypt(plaintext);
  return { seq, ciphertext };
}

/**
 * Opens `envelope`, reconstructing the nonce from `expectedSenderTag` and
 * `envelope.seq` -- a wire-supplied nonce, if any, is never trusted. Rejects
 * a seq that does not strictly exceed `lastSeq` (INV-14/15) before
 * attempting decryption, and rejects an oversized ciphertext (INV-16).
 * Throws `RelayCryptoError` on any failure, including AEAD auth failure
 * (tamper) and replay/regression.
 */
export function open(key, expectedSenderTag, envelope, lastSeq) {
  if (envelope.ciphertext.byteLength > MAX_ENVELOPE_BYTES) {
    throw new RelayCryptoError(
      'oversized',
      `ciphertext (${envelope.ciphertext.byteLength}B) exceeds MAX_ENVELOPE_BYTES (${MAX_ENVELOPE_BYTES})`
    );
  }
  assertValidSeq(envelope.seq);
  if (envelope.seq <= lastSeq) {
    throw new RelayCryptoError(
      'replay',
      `seq ${envelope.seq} does not exceed lastSeq ${lastSeq}`
    );
  }
  const nonce = buildNonce(expectedSenderTag, envelope.seq);
  try {
    return chacha20poly1305(key, nonce).decrypt(envelope.ciphertext);
  } catch (err) {
    throw new RelayCryptoError(
      'auth-failed',
      `AEAD verification failed: ${err instanceof Error ? err.message : String(err)}`
    );
  }
}

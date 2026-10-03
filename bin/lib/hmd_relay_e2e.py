#!/usr/bin/env python3
"""hmd_relay_e2e.py -- stdlib-only end-to-end crypto for hmd's relay channel.

WHY THIS EXISTS
The Cloudflare relay (`hmd app connect --relay`, bin/heimdall-relay-client)
carries paired-device traffic through a server hmd does not run and should
not have to trust. Everything that crosses it is sealed here first, so the
relay only ever sees ciphertext. This module is the entire crypto surface
for that channel -- X25519 key agreement, HKDF-SHA256 key derivation, and
ChaCha20-Poly1305 AEAD sealing -- implemented from RFC pseudocode against
Python's stdlib alone (hashlib, hmac, secrets, base64). No `cryptography`,
no `pynacl`, nothing pip-installs: the relay client has to run on whatever
bare python3 a paired device happens to have, with no guarantee a wheel
with compiled extensions will build there.

Read-only inputs this module was built against (sibling repo, never edited
from here):
  - /Users/rj/Downloads/hmdapp/docs/HANDOFF-TO-HEIMDALL-relay.md
    (sections "bin/lib/hmd_relay_e2e.py" and "Envelope" -- the contract this
    module's public API and wire format satisfy)
  - /Users/rj/Downloads/hmdapp/docs/superpowers/specs/relay/INVARIANTS.md
    (INV-11 through INV-16: session key derivation, pubkey-never-via-relay,
    deterministic seq-derived nonces, seq monotonicity, replay rejection,
    envelope size cap -- this module is what a caller relies on to hold them)

TAG ALIGNMENT (2026-09-24 -- resolves the naming discrepancy this section
used to document under the old "dev\x00" device-side tag)
INVARIANTS.md's INV-13 names the device-side nonce sender tag as the 4 bytes
"phn" plus a trailing zero byte (as in "phone") -- see _SENDER_TAGS below.
Earlier revisions of this module used "dev\x00" instead, reasoning that the
relay client called nonce_for_seq() with the sender string "device" and so
should get a "dev"-derived tag; hmdapp's own relay stack (RelayTransport,
fake-hmd.mjs) was already shipping "phn\x00" for this exact direction, so
that mismatch broke cross-language interop rather than being cosmetic -- two
processes computing DIFFERENT nonces for what both call the SAME (seq,
sender) pair. Aligned to INV-13 and hmdapp in both directions, permanently.

PRIMITIVES (each implemented directly from its RFC's normative text)
  - X25519 scalar multiplication        RFC 7748 S5 (Montgomery ladder, u-only)
  - HKDF-SHA256 extract-and-expand      RFC 5869 (HMAC-based, via hashlib/hmac)
  - ChaCha20 stream cipher              RFC 8439 S2.3/S2.4 (20-round ARX, LE)
  - Poly1305 one-time authenticator     RFC 8439 S2.5 (mod 2**130-5)
  - AEAD_CHACHA20_POLY1305 construction RFC 8439 S2.8 (poly1305_key_gen +
                                         MAC over aad||pad||ct||pad||lens)

Every self-test below reproduces a named vector from the RFC that defines
that primitive and asserts byte-exact equality; e2e_available() is true
only when every implemented self-test agrees with its RFC. Vector
provenance: fetched verbatim from rfc-editor.org (rfc7748.txt, rfc5869.txt,
rfc8439.txt) rather than typed from memory, per this task's brief.

PUBLIC API (signatures are load-bearing -- bin/heimdall-relay-client imports
these by name):
  E2EError(Exception)
  e2e_available() -> bool
  generate_keypair() -> (priv: bytes[32], pub: bytes[32])
  pub_b64(pub: bytes) -> str
  pub_from_b64(s: str) -> bytes[32]
  derive_session_key(priv, peer_pub, session_id: str) -> bytes[32]
  nonce_for_seq(seq: int, sender: str) -> bytes[12]
  seal(key, seq, sender, plaintext: bytes, aad: bytes = b"") -> (nonce_b64, ciphertext_b64)
  open_(key, seq, sender, nonce_b64, ciphertext_b64, aad: bytes = b"") -> bytes
  hmd_caps(extra=()) -> list[str]
  normalize_caps(value) -> frozenset[str]
  compress_envelope(plaintext: bytes) -> bytes
  pack_plaintext(plaintext: bytes, caps, min_bytes: int = COMPRESS_MIN_BYTES) -> bytes
  unpack_plaintext(plaintext: bytes, max_bytes: int = MAX_INFLATED_BYTES) -> bytes
  canonical_state_json(state) -> str
  state_digest(state) -> str

FRAME COMPRESSION, CAPABILITIES, RESYNC DIGEST (the FINAL wire of hmdapp's
docs/HANDOFF-TO-HEIMDALL-zero-lag-sync.md Ask 5; hmdapp's
docs/HANDBACK-FROM-HEIMDALL-zlib-frames.md records what hmd does with it)
Compression happens BEFORE seal -- ciphertext is incompressible -- and is a framing step on the
plaintext, not part of the AEAD: seal()/open_() never see it. A sealed `state` plaintext is either
    {"state": {...}, "caps": [...]}                             plain -- what every app reads
    {"z":"zlib","d":"<standard base64 of zlib.compress(P)>"}  P = the plain plaintext above
The envelope is produced only when the phone's most recent `resync` command listed "z-zlib"
(pack_plaintext's `caps`), the frame is at least COMPRESS_MIN_BYTES long and the envelope is
genuinely smaller. hmd's own tokens ride in EVERY state frame's `caps` (hmd_caps()).
unpack_plaintext() is the inverse, with the app's hard output cap (MAX_INFLATED_BYTES) and strict
about everything the spec calls malformed -- the reference decoder for anything on the hmd side that
ever reads a compressed frame, and what test/hmd-relay-zlib-frames.test.sh decodes with.
state_digest() is the resync digest (spec 5.4): sha256 of the state object's canonical JSON, an
integral float hashed as the int it is.

FAIL-CLOSED BY DESIGN
e2e_available() is the ONE function in this module allowed to swallow an
exception into a bool -- every other public function raises E2EError
loudly on malformed input, a length mismatch, an unknown sender tag, or (in
open_) any nonce/tag mismatch. There is no silent-degrade path: a caller
that gets a return value from seal/open_/derive_session_key got a value
that passed every check this module knows how to make.

CLI
    python3 hmd_relay_e2e.py selftest      run all self-tests, exit 0/1
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import sys

try:
    import zlib
except ImportError:  # a python3 built without zlib: frames are simply never compressed
    zlib = None


class E2EError(Exception):
    """Raised by every public function in this module except
    e2e_available() on malformed input, a length/type mismatch, an unknown
    sender tag, or (in open_) a nonce or authentication-tag mismatch. Never
    swallowed internally -- see FAIL-CLOSED BY DESIGN in the module
    docstring."""


# ─────────────────────────────────────────────────────────────────────────
# X25519 -- RFC 7748 section 5 (Montgomery ladder over GF(2**255 - 19))
# ─────────────────────────────────────────────────────────────────────────

_P = 2 ** 255 - 19
_A24 = 121665  # (486662 - 2) / 4, RFC 7748 section 5


def _cswap(swap: int, x2: int, x3: int) -> tuple[int, int]:
    """Branchless conditional swap (RFC 7748 section 5's cswap). Python's
    arbitrary-precision integers make `-1 & X == X` and `0 & X == 0` exact
    for any non-negative X, so no explicit bit-width mask is needed."""
    mask = -(swap & 1)
    dummy = mask & (x2 ^ x3)
    return x2 ^ dummy, x3 ^ dummy


def _decode_scalar(k: bytes) -> int:
    """Clamp + decode a 32-byte scalar per RFC 7748 section 5:
    k[0] &= 248; k[31] &= 127; k[31] |= 64; then little-endian decode."""
    kk = bytearray(k)
    kk[0] &= 248
    kk[31] &= 127
    kk[31] |= 64
    return int.from_bytes(bytes(kk), "little")


def _decode_u(u: bytes) -> int:
    """Decode a 32-byte u-coordinate per RFC 7748 section 5: X25519 (unlike
    X448) MUST mask the most significant bit of the final byte before use."""
    uu = bytearray(u)
    uu[31] &= 127
    return int.from_bytes(bytes(uu), "little")


def _encode_u(u: int) -> bytes:
    return (u % _P).to_bytes(32, "little")


def _x25519(k: int, u: int) -> int:
    """RFC 7748 section 5 Montgomery ladder. `k` is an already-decoded,
    already-clamped scalar (see _decode_scalar); `u` is an already-decoded
    u-coordinate (see _decode_u), or the raw integer 9 for the base point.
    Local variable names (a/aa/b/bb/e/c/d/da/cb) mirror the RFC's own
    A/AA/B/BB/E/C/D/DA/CB for direct pseudocode traceability."""
    x1 = u
    x2, z2 = 1, 0
    x3, z3 = u, 1
    swap = 0
    for t in range(254, -1, -1):
        k_t = (k >> t) & 1
        swap ^= k_t
        x2, x3 = _cswap(swap, x2, x3)
        z2, z3 = _cswap(swap, z2, z3)
        swap = k_t

        a = (x2 + z2) % _P
        aa = (a * a) % _P
        b = (x2 - z2) % _P
        bb = (b * b) % _P
        e = (aa - bb) % _P
        c = (x3 + z3) % _P
        d = (x3 - z3) % _P
        da = (d * a) % _P
        cb = (c * b) % _P
        x3 = pow((da + cb) % _P, 2, _P)
        z3 = (x1 * pow((da - cb) % _P, 2, _P)) % _P
        x2 = (aa * bb) % _P
        z2 = (e * ((aa + _A24 * e) % _P)) % _P

    x2, x3 = _cswap(swap, x2, x3)
    z2, z3 = _cswap(swap, z2, z3)
    return (x2 * pow(z2, _P - 2, _P)) % _P


def generate_keypair() -> tuple[bytes, bytes]:
    """Fresh (private, public) pair, both 32 bytes. The private key is
    pre-clamped RFC-fashion (clamping is idempotent, so this is equivalent
    to clamping only inside _decode_scalar, but matches the common
    convention of storing an already-clamped secret key)."""
    priv = bytearray(secrets.token_bytes(32))
    priv[0] &= 248
    priv[31] &= 127
    priv[31] |= 64
    priv = bytes(priv)
    pub = _encode_u(_x25519(_decode_scalar(priv), 9))
    return priv, pub


def pub_b64(pub: bytes) -> str:
    return base64.b64encode(pub).decode("ascii")


def pub_from_b64(s: str) -> bytes:
    """Accepts both alphabets this module actually receives: standard, padded
    base64 (this module's own pub_b64() output, e.g. hmd's pubkey as decoded
    back by test/lib/fake-relay.py's `device envelope` helper) and URL-safe,
    unpadded base64 -- the wire shape of a real device_pubkey, which the app
    encodes via protocol.ts's base64UrlEncode (query strings can't safely
    carry '+'/'/'/'=') and the relay forwards byte-for-byte into device_bound.
    A 32-byte value always has exactly one trailing '=' in standard form
    (32 % 3 == 2), so every real device_pubkey arrives URL-safe *and*
    unpadded -- not a rare edge case, the only shape a real device ever sends.
    Swapping the two differing characters back before padding is safe for
    already-standard input too: '-'/'_' never appear there, so the replace
    is a no-op and padding-if-needed is idempotent on already-padded input."""
    if not isinstance(s, str):
        raise E2EError(f"pub_from_b64: expected str, got {type(s).__name__}")
    normalized = s.replace("-", "+").replace("_", "/")
    padded = normalized + "=" * (-len(normalized) % 4)
    try:
        raw = base64.b64decode(padded, validate=True)
    except (ValueError, TypeError) as exc:
        raise E2EError(f"pub_from_b64: invalid base64: {exc}") from exc
    if len(raw) != 32:
        raise E2EError(f"pub_from_b64: expected 32 bytes, got {len(raw)}")
    return raw


# ─────────────────────────────────────────────────────────────────────────
# HKDF-SHA256 -- RFC 5869 (HMAC-based Extract-and-Expand Key Derivation)
# ─────────────────────────────────────────────────────────────────────────

def _hmac_sha256(key: bytes, msg: bytes) -> bytes:
    return hmac.new(key, msg, hashlib.sha256).digest()


def _hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    """RFC 5869 sections 2.2 (Extract) and 2.3 (Expand)."""
    prk = _hmac_sha256(salt, ikm)
    t = b""
    okm = b""
    counter = 1
    while len(okm) < length:
        t = _hmac_sha256(prk, t + info + bytes([counter]))
        okm += t
        counter += 1
    return okm[:length]


def derive_session_key(priv: bytes, peer_pub: bytes, session_id: str) -> bytes:
    """X25519(priv, peer_pub) -> HKDF-SHA256(shared, salt=session_id,
    info=b"hmd-relay-v1", 32). See INV-11 (session key derivation) and
    INV-12 (pubkey material never crosses the relay in the clear -- this
    function is what turns it into a key; it isn't what protects
    transport, seal/open_ are)."""
    if not (isinstance(priv, (bytes, bytearray)) and len(priv) == 32):
        raise E2EError("derive_session_key: priv must be 32 bytes")
    if not (isinstance(peer_pub, (bytes, bytearray)) and len(peer_pub) == 32):
        raise E2EError("derive_session_key: peer_pub must be 32 bytes")
    if not isinstance(session_id, str) or not session_id:
        raise E2EError("derive_session_key: session_id must be a non-empty str")
    shared = _encode_u(_x25519(_decode_scalar(bytes(priv)), _decode_u(bytes(peer_pub))))
    if shared == b"\x00" * 32:
        # RFC 7748 section 6.1: reject the all-zero output -- it means
        # peer_pub was a low-order point, so "shared" carries no entropy
        # from either side's scalar.
        raise E2EError("derive_session_key: shared secret is all-zero (low-order peer_pub)")
    return _hkdf_sha256(shared, session_id.encode("utf-8"), b"hmd-relay-v1", 32)


# ─────────────────────────────────────────────────────────────────────────
# ChaCha20 -- RFC 8439 sections 2.3 (block function) / 2.4 (encryption)
# ─────────────────────────────────────────────────────────────────────────

_CHACHA_CONSTANTS = (0x61707865, 0x3320646E, 0x79622D32, 0x6B206574)
_MASK32 = 0xFFFFFFFF


def _rotl32(x: int, n: int) -> int:
    x &= _MASK32
    return ((x << n) | (x >> (32 - n))) & _MASK32


def _qr(s: list[int], a: int, b: int, c: int, d: int) -> None:
    """RFC 8439 section 2.1 quarter round, applied in place to state list s."""
    s[a] = (s[a] + s[b]) & _MASK32; s[d] ^= s[a]; s[d] = _rotl32(s[d], 16)
    s[c] = (s[c] + s[d]) & _MASK32; s[b] ^= s[c]; s[b] = _rotl32(s[b], 12)
    s[a] = (s[a] + s[b]) & _MASK32; s[d] ^= s[a]; s[d] = _rotl32(s[d], 8)
    s[c] = (s[c] + s[d]) & _MASK32; s[b] ^= s[c]; s[b] = _rotl32(s[b], 7)


def _chacha20_block(key: bytes, counter: int, nonce: bytes) -> bytes:
    """RFC 8439 section 2.3: one 64-byte keystream block for (key, counter,
    12-byte nonce)."""
    state = [
        _CHACHA_CONSTANTS[0], _CHACHA_CONSTANTS[1], _CHACHA_CONSTANTS[2], _CHACHA_CONSTANTS[3],
        *[int.from_bytes(key[i:i + 4], "little") for i in range(0, 32, 4)],
        counter & _MASK32,
        *[int.from_bytes(nonce[i:i + 4], "little") for i in range(0, 12, 4)],
    ]
    working = list(state)
    for _ in range(10):  # 20 rounds == 10x (column round + diagonal round)
        _qr(working, 0, 4, 8, 12)
        _qr(working, 1, 5, 9, 13)
        _qr(working, 2, 6, 10, 14)
        _qr(working, 3, 7, 11, 15)
        _qr(working, 0, 5, 10, 15)
        _qr(working, 1, 6, 11, 12)
        _qr(working, 2, 7, 8, 13)
        _qr(working, 3, 4, 9, 14)
    out = bytearray(64)
    for i in range(16):
        word = (working[i] + state[i]) & _MASK32
        out[i * 4:i * 4 + 4] = word.to_bytes(4, "little")
    return bytes(out)


def _chacha20_encrypt(key: bytes, counter: int, nonce: bytes, data: bytes) -> bytes:
    """RFC 8439 section 2.4: XOR `data` with the ChaCha20 keystream starting
    at block `counter`. Symmetric -- the same call decrypts."""
    out = bytearray(len(data))
    for block_index in range((len(data) + 63) // 64):
        ks = _chacha20_block(key, counter + block_index, nonce)
        start = block_index * 64
        chunk = data[start:start + 64]
        out[start:start + len(chunk)] = bytes(x ^ y for x, y in zip(chunk, ks))
    return bytes(out)


# ─────────────────────────────────────────────────────────────────────────
# Poly1305 -- RFC 8439 section 2.5 (one-time authenticator, mod 2**130-5)
# ─────────────────────────────────────────────────────────────────────────

_POLY1305_P = (1 << 130) - 5
_POLY1305_CLAMP = 0x0FFFFFFC0FFFFFFC0FFFFFFC0FFFFFFF


def _poly1305_mac(msg: bytes, key: bytes) -> bytes:
    """RFC 8439 section 2.5.1. `key` is the 32-byte one-time Poly1305 key
    (r || s); see _poly1305_key_gen for how AEAD derives it per-nonce."""
    r = int.from_bytes(key[0:16], "little") & _POLY1305_CLAMP
    s = int.from_bytes(key[16:32], "little")
    acc = 0
    for i in range(0, len(msg), 16):
        block = msg[i:i + 16]
        n = int.from_bytes(block, "little") | (1 << (8 * len(block)))
        acc = ((acc + n) * r) % _POLY1305_P
    acc = (acc + s) & ((1 << 128) - 1)
    return acc.to_bytes(16, "little")


# ─────────────────────────────────────────────────────────────────────────
# AEAD_CHACHA20_POLY1305 -- RFC 8439 section 2.8
# ─────────────────────────────────────────────────────────────────────────

def _pad16(data: bytes) -> bytes:
    return b"\x00" * ((-len(data)) % 16)


def _poly1305_key_gen(key: bytes, nonce: bytes) -> bytes:
    """RFC 8439 section 2.6: the first 32 bytes of the ChaCha20 block
    generated with counter=0 for this (key, nonce) are the one-time
    Poly1305 key."""
    return _chacha20_block(key, 0, nonce)[:32]


def _aead_mac_data(aad: bytes, ciphertext: bytes) -> bytes:
    """RFC 8439 section 2.8: aad || pad16(aad) || ct || pad16(ct) ||
    len(aad) as 8-byte LE || len(ct) as 8-byte LE."""
    return (
        aad + _pad16(aad)
        + ciphertext + _pad16(ciphertext)
        + len(aad).to_bytes(8, "little")
        + len(ciphertext).to_bytes(8, "little")
    )


# ─────────────────────────────────────────────────────────────────────────
# Nonces -- deterministic, seq-derived, direction-separated (INV-13, INV-14)
# ─────────────────────────────────────────────────────────────────────────

# See the TAG ALIGNMENT note in the module docstring: both directions now
# match INV-13 and hmdapp's RelayTransport/fake-hmd.mjs exactly.
_SENDER_TAGS = {
    "hmd": b"hmd\x00",
    "device": b"phn\x00",
}


def nonce_for_seq(seq: int, sender: str) -> bytes:
    """12-byte nonce = 4-byte sender tag || 8-byte big-endian seq. Same
    (seq, sender) always produces the same nonce (INV-13); the two senders'
    tags keep their nonce spaces disjoint so a seq replayed from the other
    direction can never collide (INV-14 depends on this)."""
    if not isinstance(sender, str) or sender not in _SENDER_TAGS:
        raise E2EError(f"nonce_for_seq: unknown sender {sender!r}, expected one of {sorted(_SENDER_TAGS)}")
    if not isinstance(seq, int) or isinstance(seq, bool):
        raise E2EError(f"nonce_for_seq: seq must be an int, got {type(seq).__name__}")
    try:
        seq_bytes = seq.to_bytes(8, "big")
    except (OverflowError, ValueError) as exc:
        raise E2EError(f"nonce_for_seq: seq {seq} does not fit in 8 bytes: {exc}") from exc
    return _SENDER_TAGS[sender] + seq_bytes


# ─────────────────────────────────────────────────────────────────────────
# Public seal/open -- compose the primitives above into the wire format
# ─────────────────────────────────────────────────────────────────────────

def seal(key: bytes, seq: int, sender: str, plaintext: bytes, aad: bytes = b"") -> tuple[str, str]:
    """AEAD-seal `plaintext`. Returns (nonce_b64, ciphertext_b64) where
    ciphertext_b64 decodes to ciphertext || 16-byte tag."""
    if not (isinstance(key, (bytes, bytearray)) and len(key) == 32):
        raise E2EError("seal: key must be 32 bytes")
    if not isinstance(plaintext, (bytes, bytearray)):
        raise E2EError("seal: plaintext must be bytes")
    if not isinstance(aad, (bytes, bytearray)):
        raise E2EError("seal: aad must be bytes")
    nonce = nonce_for_seq(seq, sender)
    otk = _poly1305_key_gen(key, nonce)
    ciphertext = _chacha20_encrypt(key, 1, nonce, bytes(plaintext))
    tag = _poly1305_mac(_aead_mac_data(bytes(aad), ciphertext), otk)
    return (
        base64.b64encode(nonce).decode("ascii"),
        base64.b64encode(ciphertext + tag).decode("ascii"),
    )


def open_(key: bytes, seq: int, sender: str, nonce_b64: str, ciphertext_b64: str, aad: bytes = b"") -> bytes:
    """Verify + decrypt a seal() output. Raises E2EError on ANY mismatch --
    wrong key, wrong seq/sender (so the wrong nonce was expected), a wire
    nonce that doesn't match what (seq, sender) derives, or a bad tag --
    before returning a single byte of plaintext. The wire nonce is checked
    against the expected one via constant-time compare, but decryption
    always uses the EXPECTED (seq-derived) nonce, never the wire value,
    even after they match. Caller-side seq tracking (monotonicity, replay
    rejection -- INV-13/INV-15) is a contract this module can't enforce by
    itself; what open_ guarantees is that a given seq can only ever decrypt
    under the ONE nonce that seq derives to."""
    if not (isinstance(key, (bytes, bytearray)) and len(key) == 32):
        raise E2EError("open_: key must be 32 bytes")
    if not isinstance(aad, (bytes, bytearray)):
        raise E2EError("open_: aad must be bytes")
    expected_nonce = nonce_for_seq(seq, sender)
    try:
        wire_nonce = base64.b64decode(nonce_b64, validate=True)
    except (ValueError, TypeError) as exc:
        raise E2EError(f"open_: invalid nonce base64: {exc}") from exc
    if not hmac.compare_digest(wire_nonce, expected_nonce):
        raise E2EError("open_: nonce does not match (seq, sender)")
    try:
        blob = base64.b64decode(ciphertext_b64, validate=True)
    except (ValueError, TypeError) as exc:
        raise E2EError(f"open_: invalid ciphertext base64: {exc}") from exc
    if len(blob) < 16:
        raise E2EError(f"open_: ciphertext too short to hold a tag ({len(blob)} bytes)")
    ciphertext, tag = blob[:-16], blob[-16:]
    otk = _poly1305_key_gen(key, expected_nonce)
    expected_tag = _poly1305_mac(_aead_mac_data(bytes(aad), ciphertext), otk)
    if not hmac.compare_digest(tag, expected_tag):
        raise E2EError("open_: authentication tag mismatch")
    return _chacha20_encrypt(key, 1, expected_nonce, ciphertext)


# ─────────────────────────────────────────────────────────────────────────
# Frame compression, capabilities and the resync digest -- the FINAL wire of hmdapp's
# docs/HANDOFF-TO-HEIMDALL-zero-lag-sync.md Ask 5 (see FRAME COMPRESSION in the module docstring).
# Plaintext framing around seal()/open_(); no key material here.
# ─────────────────────────────────────────────────────────────────────────

CAP_ZLIB = "z-zlib"    # capability token: this side can emit / read the {"z":"zlib","d":...} envelope
CAP_RESYNC = "resync"  # capability token: hmd understands the phone's `resync` command
ENC_ZLIB = "zlib"      # the envelope's `z` value: zlib.compress output, RFC 1950 (header + Adler-32)
# Level 1, as the spec's own reference encoder ("the measured choice"): on the real state frames
# measured (22 KB from this repo, 103 KB from hmdapp) it gives 40.7% / 8.3% of the plaintext in
# ~0.4 ms; level 6 trims 4 / 1.3 points more for 2-3x the time. The level never reaches the wire:
# any level yields a stream every decoder reads.
ZLIB_LEVEL = 1
# Below this a frame is sent plain -- the spec's reference threshold ("should [send plain] for small
# ones"): the saving is under a kilobyte, less than one HTTP request's headers, and the receiver
# would still pay an inflate and a second parse for it. Every real state frame is ~10 KB or more
# (the hooks slice alone is 8.7 KB).
COMPRESS_MIN_BYTES = 2048
# The most a compressed frame may inflate to: the app's own cap (spec 5.2) and ours. pack_plaintext
# never compresses a frame longer than this, so the app never has to refuse one, and
# unpack_plaintext never returns more. ~20x the largest real state frame measured, while a zlib bomb
# (1000:1) would otherwise turn a 1 MiB envelope into a gigabyte.
MAX_INFLATED_BYTES = 2 * 1024 * 1024
MAX_CAPS = 32  # at most this many entries of an advertised capability list are read
MAX_CAP_LEN = 32


def hmd_caps() -> list:
    """The capability tokens hmd lists in EVERY state frame's wrapper (`{"state": ..., "caps": [...]}`,
    spec 5.1): `resync` always -- the relay client answers the phone's resync command -- and `z-zlib`
    only when this python can really compress. Sorted, as in the spec's examples."""
    return sorted([CAP_RESYNC] + ([CAP_ZLIB] if zlib is not None else []))


def normalize_caps(value) -> frozenset:
    """The capability set a phone advertised: the string entries of a JSON array, nothing else; a
    token this code does not know is just never acted on. Absent, null, a bare string, an object, a
    number -- all the EMPTY set, never an error and never a guess, so a phone that says nothing is
    treated as the oldest one and gets plain frames."""
    if not isinstance(value, (list, tuple)):
        return frozenset()
    return frozenset(c for c in value[:MAX_CAPS] if isinstance(c, str) and 0 < len(c) <= MAX_CAP_LEN)


def compress_envelope(plaintext: bytes) -> bytes:
    """The spec 5.2 envelope for `plaintext`, unconditionally:
    `{"z":"zlib","d":"<standard base64 of zlib.compress(plaintext, ZLIB_LEVEL)>"}`, compact JSON.
    pack_plaintext decides WHETHER to send it; this is the encoding itself, what the vectors pin."""
    if zlib is None:
        raise E2EError("compress_envelope: this python has no zlib")
    data = base64.b64encode(zlib.compress(plaintext, ZLIB_LEVEL)).decode("ascii")
    return json.dumps({"z": ENC_ZLIB, "d": data}, separators=(",", ":")).encode("ascii")


def pack_plaintext(plaintext: bytes, caps, min_bytes: int = COMPRESS_MIN_BYTES) -> bytes:
    """The bytes to seal for `plaintext` (the plain JSON of a state frame): the envelope
    `{"z":"zlib","d":"<base64 of zlib.compress(plaintext)>"}` when `caps` -- the phone's capability
    set, a set/list/tuple of tokens -- holds "z-zlib", `plaintext` is at least `min_bytes` and at
    most MAX_INFLATED_BYTES long, and the envelope is strictly smaller than it -- otherwise
    `plaintext` itself, unchanged, which is what every phone reads."""
    if zlib is None or not isinstance(caps, (set, frozenset, list, tuple)) or CAP_ZLIB not in caps:
        return plaintext
    if not min_bytes <= len(plaintext) <= MAX_INFLATED_BYTES:
        return plaintext
    envelope = compress_envelope(plaintext)
    return envelope if len(envelope) < len(plaintext) else plaintext


def _is_envelope(blob: bytes) -> bool:
    """True when `blob` is a JSON object with a top-level "z" key (a nested "z" is data)."""
    try:
        obj = json.loads(blob)
    except (ValueError, RecursionError):
        return False
    return isinstance(obj, dict) and "z" in obj


def unpack_plaintext(plaintext: bytes, max_bytes: int = MAX_INFLATED_BYTES) -> bytes:
    """Inverse of pack_plaintext: the inner plaintext of an envelope, `plaintext` itself when it is
    not one (not JSON, not an object, no top-level "z"). Fails closed with E2EError on everything
    spec 5.2 calls malformed -- a `z` other than "zlib", a missing or non-string `d`, `d` that is not
    standard base64 of a COMPLETE zlib stream (header and checksum included, nothing after it), an
    empty or longer-than-`max_bytes` result, or an envelope inside the envelope (one level only).
    The inflate is bounded by `max_bytes` + 1 as it runs, so a bomb costs at most that much memory,
    never its full size."""
    try:
        obj = json.loads(plaintext)
    except (ValueError, RecursionError):
        return plaintext
    if not isinstance(obj, dict) or "z" not in obj:
        return plaintext
    if obj["z"] != ENC_ZLIB:
        raise E2EError(f"unpack_plaintext: unsupported frame encoding z={obj['z']!r}")
    data = obj.get("d")
    if not isinstance(data, str) or not data:
        raise E2EError("unpack_plaintext: z=zlib frame without a string `d`")
    if zlib is None:
        raise E2EError("unpack_plaintext: this python has no zlib")
    try:
        compressed = base64.b64decode(data, validate=True)
    except ValueError as exc:
        raise E2EError(f"unpack_plaintext: `d` is not standard base64: {exc}") from exc
    inflater = zlib.decompressobj()
    try:
        out = inflater.decompress(compressed, max_bytes + 1)
    except zlib.error as exc:
        raise E2EError(f"unpack_plaintext: `d` is not a zlib stream: {exc}") from exc
    if len(out) > max_bytes:
        raise E2EError(f"unpack_plaintext: inflated output exceeds the {max_bytes}-byte cap")
    if not inflater.eof:
        raise E2EError("unpack_plaintext: zlib stream is truncated")
    if inflater.unused_data:
        raise E2EError("unpack_plaintext: bytes after the end of the zlib stream")
    if not out:
        raise E2EError("unpack_plaintext: the compressed frame inflates to nothing")
    if _is_envelope(out):
        raise E2EError("unpack_plaintext: an envelope inside an envelope (one level only)")
    return out


def _normalize(value):
    """JavaScript cannot tell 1.0 from 1, so an integral float is hashed as the int it is (spec 5.4)."""
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, list):
        return [_normalize(item) for item in value]
    if isinstance(value, dict):
        return {key: _normalize(item) for key, item in value.items()}
    return value


def canonical_state_json(state) -> str:
    """json.dumps(state, sort_keys=True, separators=(",", ":"), ensure_ascii=False) with every
    integral float written as its int (spec 5.4) -- the text the digest hashes."""
    return json.dumps(_normalize(state), sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def state_digest(state) -> str:
    """The resync digest of a state object (spec 5.4): sha256 hex of canonical_state_json(state),
    UTF-8 encoded. Over the state exactly as sent (the object inside the {"state": ...} wrapper,
    `ts` included) -- deliberately NOT sentinels/hmd-ui.py's digest_of(), which drops `ts`, panel
    `updated_at` and `inbox.oldest_age_s` so the poller stays quiet; a resync must name the exact
    frame a phone holds. A lone surrogate in a string (a JSON file may carry one as \\ud800) is
    encoded as its own three bytes rather than raising, so one such string cannot wedge every later
    state send, and two different strings still hash differently."""
    return hashlib.sha256(canonical_state_json(state).encode("utf-8", "surrogatepass")).hexdigest()


# ─────────────────────────────────────────────────────────────────────────
# Self-tests -- each reproduces one RFC-published vector byte-for-byte.
# Vectors were fetched verbatim (rfc-editor.org, direct download of the
# plaintext RFC, not a summarized/paraphrased intermediary -- see
# PRIMITIVES in the module docstring for provenance detail). All five
# primitives (X25519, HKDF, ChaCha20 block, Poly1305, and the composed
# AEAD_CHACHA20_POLY1305 construction) have a verified self-test below;
# e2e_available() is the AND of all five.
# ─────────────────────────────────────────────────────────────────────────

def _selftest_x25519() -> bool:
    """RFC 7748 section 6.1 -- Alice/Bob Diffie-Hellman example."""
    try:
        alice_priv = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        alice_pub_expected = bytes.fromhex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        bob_priv = bytes.fromhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        bob_pub_expected = bytes.fromhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        shared_expected = bytes.fromhex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

        alice_pub = _encode_u(_x25519(_decode_scalar(alice_priv), 9))
        bob_pub = _encode_u(_x25519(_decode_scalar(bob_priv), 9))
        if alice_pub != alice_pub_expected or bob_pub != bob_pub_expected:
            return False

        alice_shared = _encode_u(_x25519(_decode_scalar(alice_priv), _decode_u(bob_pub_expected)))
        bob_shared = _encode_u(_x25519(_decode_scalar(bob_priv), _decode_u(alice_pub_expected)))
        return alice_shared == shared_expected and bob_shared == shared_expected
    except Exception:
        return False


def _selftest_hkdf() -> bool:
    """RFC 5869 Appendix A.1 and A.2 (SHA-256 test cases 1 and 2)."""
    try:
        ikm1 = bytes.fromhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
        salt1 = bytes.fromhex("000102030405060708090a0b0c")
        info1 = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9")
        okm1_expected = bytes.fromhex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        if _hkdf_sha256(ikm1, salt1, info1, 42) != okm1_expected:
            return False

        ikm2 = bytes.fromhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f")
        salt2 = bytes.fromhex("606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
        info2 = bytes.fromhex("b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        okm2_expected = bytes.fromhex("b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87")
        return _hkdf_sha256(ikm2, salt2, info2, 82) == okm2_expected
    except Exception:
        return False


def _selftest_chacha20() -> bool:
    """RFC 8439 section 2.3.2 -- ChaCha20 block function test vector:
    key = the 32 sequential bytes 00..1f, nonce =
    00:00:00:09:00:00:00:4a:00:00:00:00, block counter = 1."""
    try:
        key = bytes(range(32))
        nonce = bytes.fromhex("000000090000004a00000000")
        expected = bytes.fromhex(
            "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4"
            "ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e"
        )
        return _chacha20_block(key, 1, nonce) == expected
    except Exception:
        return False


def _selftest_poly1305() -> bool:
    """RFC 8439 section 2.5.2 -- Poly1305 example and test vector: the
    34-byte ASCII message "Cryptographic Forum Research Group" under a
    given 32-byte one-time key, producing a 16-byte tag."""
    try:
        key = bytes.fromhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
        msg = b"Cryptographic Forum Research Group"
        expected_tag = bytes.fromhex("a8061dc1305136c6c22b8baf0c0127a9")
        return _poly1305_mac(msg, key) == expected_tag
    except Exception:
        return False


def _selftest_aead() -> bool:
    """RFC 8439 section 2.8.2 -- the full AEAD_CHACHA20_POLY1305 worked
    example ("Ladies and Gentlemen of the class of '99..." plaintext under
    sender id=7). Exercises the exact composition seal()/open_() use
    (_poly1305_key_gen at counter 0, _chacha20_encrypt at counter 1,
    _aead_mac_data, _poly1305_mac) against externally-published ciphertext
    and tag, so a bug in how those primitives are WIRED TOGETHER -- not just
    a bug in one of them alone -- would fail this even if
    _selftest_chacha20/_selftest_poly1305 above both still pass."""
    try:
        plaintext = bytes.fromhex(
            "4c616469657320616e642047656e746c656d656e206f662074686520636c61"
            "7373206f66202739393a204966204920636f756c64206f6666657220796f75"
            "206f6e6c79206f6e652074697020666f7220746865206675747572652c2073"
            "756e73637265656e20776f756c642062652069742e"
        )
        aad = bytes.fromhex("50515253c0c1c2c3c4c5c6c7")
        key = bytes.fromhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        # 12-byte nonce = 4-byte "32-bit fixed-common part" (07 00 00 00)
        # followed by the 8-byte IV (40 41 42 43 44 45 46 47), per how the
        # RFC's own "Setup for generating Poly1305 one-time key (sender
        # id=7)" state matrix packs words 13-15 -- NOT this module's own
        # nonce_for_seq() scheme, which has no bearing on this vector.
        nonce = bytes.fromhex("070000004041424344454647")
        expected_ciphertext = bytes.fromhex(
            "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d"
            "63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b"
            "3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d"
            "7bc3ff4def08e4b7a9de576d26586cec64b6116"
        )
        expected_tag = bytes.fromhex("1ae10b594f09e26a7e902ecbd0600691")

        otk = _poly1305_key_gen(key, nonce)
        ciphertext = _chacha20_encrypt(key, 1, nonce, plaintext)
        if ciphertext != expected_ciphertext:
            return False
        tag = _poly1305_mac(_aead_mac_data(aad, ciphertext), otk)
        return tag == expected_tag
    except Exception:
        return False


def e2e_available() -> bool:
    """True iff every self-test implemented so far reproduces its RFC
    vector byte-exact. The ONE function in this module allowed to swallow
    an exception into a bool -- see FAIL-CLOSED BY DESIGN in the module
    docstring."""
    return (
        _selftest_x25519()
        and _selftest_hkdf()
        and _selftest_chacha20()
        and _selftest_poly1305()
        and _selftest_aead()
    )


def _main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "selftest":
        if e2e_available():
            print("hmd_relay_e2e: selftest OK")
            return 0
        print("hmd_relay_e2e: selftest FAILED", file=sys.stderr)
        return 1
    print("usage: hmd_relay_e2e.py selftest", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))

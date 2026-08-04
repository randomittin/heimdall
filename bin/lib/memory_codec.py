#!/usr/bin/env python3
# memory_codec.py — the MemoryCodec seam (§8): the storage-codec attachment point
# BENEATH verified-memory, the case corpus, context-branch payloads, and session
# summaries.
#
# WHAT THIS IS. One place where hmd's durable payloads are turned into their stored
# wire form and back again. A codec SHRINKS STORAGE AND TRANSPORT — nothing else.
# hmd continues to own ALL truth semantics: the git-decidable proofs live in
# vm_gitcheck, the verification state lives in verified_memory. It must be
# IMPOSSIBLE for a codec to change a verdict, and this module is built so that it
# is — not by convention, by construction.
#
# BACKEND SELECTION (detect-if-present, NEVER a hard dependency):
#   • headroom — when the library is importable AND exposes a compatible
#                storage-codec entrypoint. hmd's base install stays near-stdlib;
#                `headroom-ai[all]` pulls Rust/ONNX/HuggingFace and must never
#                become required. We never import it eagerly and never install it.
#   • plain    — otherwise. Identity passthrough: the stored bytes are exactly the
#                bytes hmd would have written with no codec at all, so a machine
#                without the library has a byte-for-byte unchanged store.
#
# THREE INVARIANTS, each mechanically enforced here, each tested in
# test/memory-codec.test.sh:
#
#   1. ROUND-TRIP FIDELITY. What comes out of the seam is byte-identical to what
#      went in. Enforced twice over:
#        (a) WRITE-SIDE SELF-CHECK — encode_text() re-decodes its own output and
#            compares before returning any wire form. A codec that loses a single
#            byte fails the check and that payload falls back to plain, so the
#            store keeps the literal text. A lossy codec therefore CANNOT PERSIST.
#        (b) READ-SIDE DIGEST — the envelope carries a short sha256 of the
#            original. A decode that does not reproduce it raises CodecCorruption,
#            and the store's existing corrupt-line policy applies (skip the line,
#            never serve it). Corrupted memory is therefore NEVER SERVED.
#
#   2. THE CODEC NEVER TOUCHES GATE / VERIFIER INPUTS. The gates-read-raw invariant
#      (bin/lib/hmd-gate-endpoint.sh — "generation may run compressed; judgment may
#      not") extends from the model endpoint to storage. Compression in a judge's
#      input corrupts the judge, and a corrupted judge emits false greens. Two
#      independent guards:
#        (a) STRUCTURAL — decode happens at the store-read boundary
#            (verified_memory._read_raw), strictly BEFORE any consumer exists. By
#            the time vm_gitcheck.verify() sees an entry, no wire form remains.
#        (b) FIELD ALLOWLIST — encode_entry() only ever touches PAYLOAD_FIELDS and
#            refuses VERIFIER_FIELDS outright. _assert_disjoint() below is a
#            LOAD-TIME check, so a future edit that widens the payload set into a
#            verifier input fails loudly at import, not silently at a verdict.
#      There is deliberately NO environment variable that selects a codec: a
#      routing var is exactly how a compressing proxy hijacks a judge, and this
#      seam refuses to offer that lever. A backend arrives by import detection or
#      by an explicit in-process register_backend() call, never from the ambient
#      environment.
#
#   3. CODEC ABSENCE DEGRADES TO PLAIN, SILENTLY. No feature may depend on any
#      codec being installed. Detection failure, an incompatible library version, a
#      backend that raises mid-encode — every one of them lands on plain, with the
#      reason recorded for diagnostics and nothing printed to a user. The only
#      user-visible surface is ONE optional hint, at most once per store (see
#      maybe_hint).
#
# SECURITY ORDERING (verified_memory §7): the telemetry _scrub secret/shape gate
# runs at WRITE, BEFORE this seam is reached. A codec can therefore never smuggle a
# credential past the gate — by the time a payload arrives here it has already been
# accepted as secret-free. Note the honest trade-off a non-plain backend makes: an
# encoded payload is no longer literal text for `gitleaks detect` to read. The write
# gate, not the store's readability, is what keeps the store clean; on plain (the
# default, and the state of a base install) the store stays literal either way.
#
# This is a LIBRARY with a thin CLI (`status`) used by the tests and by ops.

from __future__ import annotations

import base64
import hashlib
import importlib
import importlib.util
import json
import os
import sys

# ── backend names ─────────────────────────────────────────────────────────────

PLAIN = "plain"
HEADROOM = "headroom"

# ── the field partition that makes invariant 2 structural ─────────────────────

# The fields a codec may NEVER touch. These are the gate / verifier inputs: every
# value vm_gitcheck._classify(), _cache_key() and weight_for() read to DECIDE a
# status, plus the derived verdict fields verify() writes. A codec that could reach
# any of these could change a verdict, which is the one thing it must never be able
# to do.
VERIFIER_FIELDS = frozenset({
    "id",              # identity — the fold key; a codec must not blur two entries
    "commit_ref",      # _classify step 1: does this commit resolve in the repo
    "refs",            # _classify step 2: path + symbol presence at HEAD
    "status",          # the derived verdict (live | stale | conflicted)
    "weight",          # the derived read-time readout
    "verified_at",     # when the check ran
    "reason",          # the verdict's one-line explanation
    "provenance",      # measured | estimated | null — a truth-provenance label
    "schema_version",  # the entry shape the engine pins
    "cache",           # the read-time cache stats block
})

# The fields a codec MAY compress: free-text payloads that no verdict is derived
# from. `claim` is verified-memory's payload; the rest are the payload keys the case
# corpus, context-branch payloads and session summaries carry, so those stores
# attach to this seam without having to widen it later.
PAYLOAD_FIELDS = ("claim", "summary", "body", "text", "content")

# The envelope keys. `$hmdc` marks a wire form; anything without it is literal.
_ENV_TAG = "$hmdc"     # backend name that produced this wire form
_ENV_ENC = "e"         # "raw" (codec returned str) | "b64" (codec returned bytes)
_ENV_BODY = "b"        # the wire body
_ENV_DIGEST = "h"      # sha256 of the ORIGINAL text, first 16 hex chars

# Emit the hint only once a store is genuinely heavy. Rotation happens at 5 MiB
# (verified_memory._ROTATE_BYTES), so 1 MiB is "this is getting big" while there is
# still a point in compressing it.
HEAVY_STORE_BYTES = 1024 * 1024

# The ONE user-facing sentence, verbatim, at most once per store. A hint that
# repeats gets muted, and then the one that matters gets muted too.
HINT = "hmd can compress its memory stores via Headroom if installed — optional."

_HINT_MARKER = ".codec-hint-shown"


class CodecCorruption(Exception):
    """A stored wire form did not decode back to the text its digest names. The
    payload is unrecoverable, so it is treated exactly like any other corrupt store
    line: skipped by the reader, never served. Raised by decode_text; caught at the
    store-read boundary (verified_memory._read_raw)."""


def _assert_disjoint():
    """Load-time guard for invariant 2: no payload field may also be a verifier
    input. This runs at import so a future edit that widens PAYLOAD_FIELDS into a
    verdict-bearing field fails immediately and loudly, rather than quietly letting
    a codec reach the judge. A wrong verdict discovered months later is exactly the
    failure this project exists to prevent."""
    overlap = VERIFIER_FIELDS.intersection(PAYLOAD_FIELDS)
    if overlap:
        raise RuntimeError(
            "memory_codec: PAYLOAD_FIELDS overlaps VERIFIER_FIELDS on %s — a codec "
            "must never be able to reach a gate/verifier input" % sorted(overlap)
        )


_assert_disjoint()


# ── backend registry ──────────────────────────────────────────────────────────

# name → (encode, decode). `plain` is always present and is always the fallback.
_BACKENDS = {}

# Cached detection: (name, reason). Populated on first use; cleared by reset_state().
_DETECTED = None


def _plain_encode(text):
    """The plain backend's encode: identity. The stored bytes are exactly the bytes
    hmd would write with no codec at all."""
    return text


def _plain_decode(wire):
    """The plain backend's decode: identity."""
    return wire


_BACKENDS[PLAIN] = (_plain_encode, _plain_decode)


def register_backend(name, encode, decode):
    """Register a storage codec under `name`. This is the ONLY way a non-detected
    backend enters the seam — deliberately in-process and explicit, never ambient
    (invariant 2: no environment lever may move a codec near a judge).

    `encode(text: str) -> str | bytes` and `decode(wire: str | bytes) -> str`. The
    pair does NOT need to be trusted: encode_text self-checks every payload before
    persisting it, so a lossy or raising backend degrades that payload to plain
    rather than corrupting the store.

    Registering `plain` is refused — plain is the guaranteed fallback and must stay
    the identity function, otherwise "degrade to plain" would mean nothing."""
    if name == PLAIN:
        raise ValueError(
            "memory_codec: the plain backend is the guaranteed identity fallback "
            "and cannot be replaced"
        )
    if not callable(encode) or not callable(decode):
        raise TypeError("memory_codec: encode and decode must both be callable")
    _BACKENDS[name] = (encode, decode)
    reset_state()


def unregister_backend(name):
    """Remove a registered backend, returning True if one was removed. Used by ops
    and by the tests to return the seam to its detected state. `plain` is never
    removable."""
    if name == PLAIN:
        return False
    removed = _BACKENDS.pop(name, None) is not None
    reset_state()
    return removed


def reset_state():
    """Drop the cached backend detection so the next call re-resolves. Called
    whenever the registry changes."""
    global _DETECTED
    _DETECTED = None


# ── headroom detection (detect-if-importable; NEVER a hard dependency) ────────

# The entrypoints a Headroom install may expose for storage coding, in preference
# order. We probe for a (module, encode-name, decode-name) triple that is actually
# present and callable; nothing else about the library is assumed, and nothing is
# imported until the cheap find_spec probe says the package exists at all.
_HEADROOM_ENTRYPOINTS = (
    ("headroom.codec", "encode", "decode"),
    ("headroom.storage", "encode", "decode"),
    ("headroom", "compress", "decompress"),
)


def _headroom_present():
    """True iff a `headroom` package is importable, WITHOUT importing it.
    importlib.util.find_spec inspects the finders only — no module executes, so an
    absent library costs a path probe and a heavy library costs no import time on
    the read path. Any exception from a broken meta-path finder means "treat it as
    absent": absence must never be an error."""
    try:
        return importlib.util.find_spec("headroom") is not None
    except (ImportError, ValueError, AttributeError):
        return False


def _resolve_headroom():
    """Resolve Headroom's storage-codec entrypoint. Returns (name, reason):
    (HEADROOM, None) when a compatible pair was found and registered, or
    (PLAIN, reason) when the library is absent or exposes nothing this seam can
    use. Degrading is always silent to the user — the reason is diagnostics only."""
    if not _headroom_present():
        return PLAIN, "headroom is not importable — using the plain codec"

    errors = []
    for modname, enc_name, dec_name in _HEADROOM_ENTRYPOINTS:
        try:
            mod = importlib.import_module(modname)
        except Exception as exc:  # noqa: BLE001 — an optional lib must never crash hmd
            errors.append("%s: %s" % (modname, exc))
            continue
        enc = getattr(mod, enc_name, None)
        dec = getattr(mod, dec_name, None)
        if callable(enc) and callable(dec):
            _BACKENDS[HEADROOM] = (enc, dec)
            return HEADROOM, None

    detail = ("; ".join(errors)) if errors else "no compatible entrypoint"
    return PLAIN, (
        "headroom is importable but exposes no storage-codec entrypoint this seam "
        "understands (%s) — using the plain codec" % detail
    )


def _detect():
    """Resolve the active backend name once and cache it. An explicitly registered
    backend wins over detection (register_backend is a deliberate act); otherwise we
    probe for headroom; otherwise plain."""
    global _DETECTED
    if _DETECTED is not None:
        return _DETECTED

    explicit = [n for n in _BACKENDS if n not in (PLAIN, HEADROOM)]
    if explicit:
        _DETECTED = (sorted(explicit)[0], None)
        return _DETECTED

    try:
        _DETECTED = _resolve_headroom()
    except Exception as exc:  # noqa: BLE001 — invariant 3: absence is never an error
        _DETECTED = (PLAIN, "codec detection failed (%s) — using the plain codec" % exc)
    return _DETECTED


def backend_name():
    """The active backend's name: "headroom" when the library is importable and
    usable, an explicitly registered name, else "plain"."""
    return _detect()[0]


def available():
    """True iff a real (non-plain) codec is active. False means every payload is
    stored literally — a fully supported state, not a degraded one."""
    return backend_name() != PLAIN


def status():
    """A diagnostics readout of the seam. Never raises."""
    name, reason = _detect()
    return {
        "backend": name,
        "available": name != PLAIN,
        "headroom_importable": _headroom_present(),
        "registered": sorted(_BACKENDS),
        "reason": reason,
        "verifier_fields": sorted(VERIFIER_FIELDS),
        "payload_fields": list(PAYLOAD_FIELDS),
    }


# ── the text seam: encode / decode ONE payload string ─────────────────────────


def _digest(text):
    """A short sha256 over the original text — the read-side fidelity check."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _envelope(name, body, enc, text):
    return {
        _ENV_TAG: name,
        _ENV_ENC: enc,
        _ENV_BODY: body,
        _ENV_DIGEST: _digest(text),
    }


def is_wire(value):
    """True iff `value` is a codec envelope rather than literal text."""
    return isinstance(value, dict) and _ENV_TAG in value


def encode_text(text):
    """Encode ONE payload string to its stored wire form.

    Returns the text UNCHANGED (a plain str) when the active backend is plain, when
    the payload is not a string, when the backend cannot losslessly reproduce THIS
    payload, or when the envelope would not actually be smaller. Otherwise returns
    an envelope dict.

    INVARIANT 1(a), the write-side self-check: before returning any wire form we run
    the backend's own decode over its own output and compare to the input. A codec
    that loses a byte — or raises, or returns the wrong type — never reaches the
    store; that payload is stored literally instead. This is why a lossy codec
    cannot corrupt hmd's memory: it is caught at the moment of writing, per payload,
    against the actual bytes being written. Never raises."""
    if not isinstance(text, str):
        return text

    name = backend_name()
    if name == PLAIN:
        return text

    pair = _BACKENDS.get(name)
    if pair is None:
        return text
    encode, _decode = pair

    try:
        raw = encode(text)
    except Exception:  # noqa: BLE001 — invariant 3: a backend fault degrades to plain
        return text

    if isinstance(raw, bytes):
        body, enc = base64.b64encode(raw).decode("ascii"), "b64"
    elif isinstance(raw, str):
        body, enc = raw, "raw"
    else:
        return text  # a backend returning neither str nor bytes is unusable here

    env = _envelope(name, body, enc, text)

    # THE SELF-CHECK. Decode our own envelope and demand byte-identity.
    try:
        if decode_text(env) != text:
            return text
    except Exception:  # noqa: BLE001 — a decode that cannot run is a failed check
        return text

    # An envelope no smaller than the literal text is pure overhead — the codec
    # exists to shrink storage, so keep the literal in that case.
    if len(json.dumps(env, separators=(",", ":"))) >= len(json.dumps(text)):
        return text

    return env


def decode_text(value):
    """Decode ONE stored payload back to its original string.

    Literal text (anything without the envelope tag) is returned unchanged, so a
    store written before any codec existed — or on a machine with no codec — reads
    identically. Raises CodecCorruption when an envelope does not decode back to the
    text its digest names (invariant 1(b)): the payload is unrecoverable, and the
    reader's corrupt-line policy (skip, never serve) is the honest response. A
    truncated memory served as whole would be a lie about what was remembered."""
    if not is_wire(value):
        return value

    name = value.get(_ENV_TAG)
    pair = _BACKENDS.get(name)
    if pair is None:
        raise CodecCorruption(
            "stored payload needs the %r codec, which is not available here" % name
        )
    _encode, decode = pair

    body = value.get(_ENV_BODY)
    if not isinstance(body, str):
        raise CodecCorruption("codec envelope carries no string body")

    try:
        if value.get(_ENV_ENC) == "b64":
            wire = base64.b64decode(body.encode("ascii"))
        else:
            wire = body
        text = decode(wire)
    except Exception as exc:  # noqa: BLE001 — a failed decode is corruption, not a crash
        raise CodecCorruption(
            "codec %r failed to decode a stored payload: %s" % (name, exc)
        )

    if not isinstance(text, str):
        raise CodecCorruption(
            "codec %r decoded a payload to %s, not text" % (name, type(text).__name__)
        )

    want = value.get(_ENV_DIGEST)
    if want and _digest(text) != want:
        raise CodecCorruption(
            "decoded payload does not match its stored digest — the round-trip was "
            "lossy or the store is corrupt; refusing to serve it"
        )
    return text


# ── the entry seam: encode / decode a whole record ────────────────────────────


def encode_entry(entry, fields=PAYLOAD_FIELDS):
    """Return a copy of `entry` with its payload fields encoded to wire form.

    INVARIANT 2(b), the field allowlist: only `fields` are considered, and any field
    that is also a VERIFIER_FIELD is skipped outright. Every gate/verifier input
    comes out of this function bit-identical to the way it went in, whatever the
    codec does. Never raises — a non-dict is returned unchanged."""
    if not isinstance(entry, dict):
        return entry
    out = dict(entry)
    for key in fields:
        if key in VERIFIER_FIELDS:
            continue  # a verdict-bearing field is never the codec's to touch
        if key not in out:
            continue
        out[key] = encode_text(out[key])
    return out


def decode_entry(entry, fields=PAYLOAD_FIELDS):
    """Return a copy of `entry` with every payload field decoded back to text.

    This is the STRUCTURAL half of invariant 2: it runs at the store-read boundary,
    so by the time any consumer — vm_gitcheck.verify() above all — sees an entry, no
    wire form remains anywhere in it. Propagates CodecCorruption so the reader can
    skip an unrecoverable line rather than serve a corrupted memory."""
    if not isinstance(entry, dict):
        return entry
    out = None
    for key in fields:
        if key in VERIFIER_FIELDS:
            continue
        value = entry.get(key)
        if not is_wire(value):
            continue
        if out is None:
            out = dict(entry)  # copy only when there is actually something to decode
        out[key] = decode_text(value)
    return entry if out is None else out


def verifier_fields_intact(encoded, original):
    """True iff `encoded` preserves every verifier input of `original` EXACTLY. The
    mechanical statement of invariant 2, exposed so callers and tests can assert it
    against real records instead of trusting the code path. Never raises."""
    if not isinstance(encoded, dict) or not isinstance(original, dict):
        return encoded == original
    for key in VERIFIER_FIELDS:
        if (key in encoded) != (key in original):
            return False
        if key in original and encoded[key] != original[key]:
            return False
    return True


# ── the ONE user-facing hint, at most once per store ──────────────────────────


def maybe_hint(store_path, heavy_bytes=HEAVY_STORE_BYTES):
    """Return the one-line codec hint the FIRST time a store grows heavy with no
    codec installed, and None every other time.

    Silent when a codec is already active (nothing to suggest), when the store is
    still small, and when this store has been hinted before — the marker file next
    to the store makes "once" durable across processes and sessions. One hint that
    lands beats a repeated hint that gets muted, taking the hint that matters down
    with it. Never raises: any IO problem simply means no hint."""
    if available():
        return None
    try:
        if os.path.getsize(store_path) < heavy_bytes:
            return None
        marker = os.path.join(os.path.dirname(store_path), _HINT_MARKER)
        if os.path.exists(marker):
            return None
        with open(marker, "w", encoding="utf-8") as fh:
            fh.write(HINT + "\n")
    except OSError:
        return None
    return HINT


# ── thin CLI (status) ─────────────────────────────────────────────────────────


def _cli(argv):
    """CLI core. Subcommand:
      status [--json]
    Prints which storage codec is active and why. Exit 0 always — "no codec" is a
    supported state, not a failure, and this command must never be the thing that
    makes a script fall over."""
    import argparse

    p = argparse.ArgumentParser(prog="memory_codec", add_help=True)
    p.add_argument("subcommand", nargs="?", default="status")
    p.add_argument("--json", action="store_true", dest="as_json")
    args = p.parse_args(argv)

    if args.subcommand != "status":
        sys.stderr.write("memory_codec: unknown subcommand: %s\n" % args.subcommand)
        return 2

    st = status()
    if args.as_json:
        sys.stdout.write(json.dumps(st, indent=2, sort_keys=True) + "\n")
    else:
        sys.stdout.write("backend: %s\n" % st["backend"])
        sys.stdout.write("available: %s\n" % ("yes" if st["available"] else "no"))
        if st["reason"]:
            sys.stdout.write("reason: %s\n" % st["reason"])
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))

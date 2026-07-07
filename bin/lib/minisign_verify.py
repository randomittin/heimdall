#!/usr/bin/env python3
"""minisign_verify.py — bundled, pure-python verifier for minisign signatures.

The reference `minisign` binary is preferred by heimdall-verify.sh; this is the fallback
so a client WITHOUT that binary (but with python3 + cryptography|pynacl, which heimdall
already depends on) can still verify a release signature instead of trusting it blindly.

It re-implements exactly what `minisign -V` checks for a detached signature:

  public key file  : `untrusted comment: ...\\n<base64>\\n`
                     base64 -> sig_alg(2) | key_id(8) | ed25519_public_key(32)   [42 bytes]
  signature file   : `untrusted comment: ...\\n<b64 sig>\\ntrusted comment: <tc>\\n<b64 global>\\n`
                     b64 sig    -> sig_alg(2) | key_id(8) | ed25519_sig(64)      [74 bytes]
                     b64 global -> ed25519_sig(64)

  sig_alg 'ED' = prehashed  -> the signature covers BLAKE2b-512(message)
  sig_alg 'Ed' = legacy     -> the signature covers the message bytes verbatim

Checks (ALL must hold, matching minisign):
  1. the signature's key_id equals the public key's key_id   (right key)
  2. ed25519_verify(pk, sig, signed_bytes)                   (artifact authentic)
  3. ed25519_verify(pk, global_sig, sig || trusted_comment)  (trusted comment bound)

Exit 0 = valid. Any non-zero = REFUSE (missing/corrupt/tampered/wrong-key). Fail-closed:
a parse error, an unsupported algorithm, or a crypto failure all exit non-zero.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import sys


def _die(msg):
    sys.stderr.write("minisign_verify: %s\n" % msg)
    raise SystemExit(1)


def _verify_pynacl(public_key, signature, message):
    try:
        import nacl.exceptions
        import nacl.signing
    except ImportError:
        return _die("no Ed25519 backend (install cryptography or pynacl)")
    try:
        nacl.signing.VerifyKey(public_key).verify(message, signature)
        return True
    except nacl.exceptions.BadSignatureError:
        return False


def _ed25519_verify(public_key, signature, message):
    """True iff `signature` is a valid Ed25519 signature of `message` under `public_key`.
    Prefers cryptography, falls back to pynacl. Any verification failure returns False;
    a total absence of a backend is a hard fail-closed error."""
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError:
        return _verify_pynacl(public_key, signature, message)
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, message)
        return True
    except InvalidSignature:
        return False


def _parse_pubkey(path):
    with open(path, "r", encoding="utf-8", errors="strict") as fh:
        lines = [ln.rstrip("\n") for ln in fh]
    b64 = next((ln for ln in lines if ln and not ln.startswith("untrusted comment:")), None)
    if not b64:
        _die("public key file has no key line")
    raw = base64.b64decode(b64, validate=True)
    if len(raw) != 42:
        _die("public key wrong length (%d, expected 42)" % len(raw))
    return raw[0:2], raw[2:10], raw[10:42]  # alg, key_id, ed25519 pubkey


def _parse_sig(path):
    with open(path, "rb") as fh:
        text = fh.read().decode("utf-8", errors="strict")
    lines = text.split("\n")
    # Line layout: [untrusted comment], <b64 sig>, [trusted comment: <tc>], <b64 global>
    if len(lines) < 4:
        _die("signature file too short")
    sig_b64 = lines[1].strip()
    tc_line = lines[2]
    global_b64 = lines[3].strip()
    if not tc_line.startswith("trusted comment:"):
        _die("signature missing trusted comment line")
    trusted_comment = tc_line[len("trusted comment:"):]
    if trusted_comment.startswith(" "):
        trusted_comment = trusted_comment[1:]

    sig_raw = base64.b64decode(sig_b64, validate=True)
    if len(sig_raw) != 74:
        _die("signature blob wrong length (%d, expected 74)" % len(sig_raw))
    global_raw = base64.b64decode(global_b64, validate=True)
    if len(global_raw) != 64:
        _die("global signature wrong length (%d, expected 64)" % len(global_raw))

    return sig_raw[0:2], sig_raw[2:10], sig_raw[10:74], global_raw, trusted_comment.encode("utf-8")


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--pubkey", required=True)
    ap.add_argument("--artifact", required=True)
    ap.add_argument("--sig", required=True)
    args = ap.parse_args()

    _pk_alg, pk_key_id, pk = _parse_pubkey(args.pubkey)
    sig_alg, sig_key_id, signature, global_sig, trusted_comment = _parse_sig(args.sig)

    # 1) the signature must name THIS key.
    if sig_key_id != pk_key_id:
        _die("key id mismatch (signature was made by a different key)")

    with open(args.artifact, "rb") as fh:
        data = fh.read()

    # 2) primary signature over the artifact (prehashed 'ED' or legacy 'Ed').
    if sig_alg == b"ED":
        signed = hashlib.blake2b(data, digest_size=64).digest()
    elif sig_alg == b"Ed":
        signed = data
    else:
        _die("unsupported signature algorithm %r" % sig_alg)

    if not _ed25519_verify(pk, signature, signed):
        _die("artifact signature does not verify (tampered artifact or wrong key)")

    # 3) global signature binds the trusted comment to the primary signature.
    if not _ed25519_verify(pk, global_sig, signature + trusted_comment):
        _die("trusted-comment signature does not verify")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:  # fail-closed on ANY unexpected error
        sys.stderr.write("minisign_verify: %s\n" % exc)
        raise SystemExit(1)

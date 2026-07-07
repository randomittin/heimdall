#!/usr/bin/env bash
# heimdall-verify.sh — sourceable release-signature verification (the auto-update trust root).
#
# ONE job: prove a downloaded release artifact (install.sh) was signed by the holder of the
# heimdall signing key, BEFORE bin/heimdall-autoupdate ever executes it. The public half of
# that key ships in-repo (release/heimdall-signing.pub) — the LOCAL, already-trusted copy is
# the trust anchor, never a key fetched alongside the artifact. Fail-closed everywhere: any
# doubt (no verifier, no key, no signature, bad signature) → non-zero → the caller REFUSES.
#
# Signatures are minisign (Ed25519, tiny, no infrastructure). Verification prefers the
# `minisign` binary (the reference implementation); when it is absent we fall back to a
# BUNDLED pure-python verifier (bin/lib/minisign_verify.py) that re-implements the same check
# with cryptography|pynacl — so a client without the minisign binary still verifies rather
# than silently trusting. If NEITHER backend exists we refuse (rc 5): we never apply code we
# could not verify.
#
# API:
#   heimdall_verify_release <artifact> <sig> <pubkey>
#     rc 0  valid signature
#     rc 2  missing/empty signature      (cardinal: an unsigned release is NOT applied)
#     rc 3  missing/empty public key     (no trust root configured)
#     rc 4  missing artifact
#     rc 5  no verifier available        (need the minisign binary OR python3 + cryptography/pynacl)
#     rc 6  INVALID signature            (tampered artifact, wrong key, or corrupt signature)
#   heimdall_verify_reason <rc>          → a human-readable one-liner for logs/messages
#
# Backend override (test seam): HEIMDALL_VERIFY_BACKEND=auto|minisign|python (default auto).

_hv_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

heimdall_verify_reason() {
  case "${1:-}" in
    0) printf 'valid signature' ;;
    2) printf 'missing signature (unsigned release)' ;;
    3) printf 'missing public key (no trust root)' ;;
    4) printf 'missing artifact' ;;
    5) printf 'no signature verifier available (need the minisign binary or python3 + cryptography/pynacl)' ;;
    6) printf 'INVALID signature (tampered artifact, wrong key, or corrupt signature)' ;;
    *) printf 'unknown verification error (%s)' "${1:-?}" ;;
  esac
}

# True (0) when a python interpreter with an Ed25519 backend (cryptography|pynacl) is present.
_hv_have_python_crypto() {
  local py; py="$(command -v python3 || command -v python || true)"
  [ -n "$py" ] || return 1
  "$py" - <<'PY' >/dev/null 2>&1
import sys
ok = False
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey  # noqa: F401
    ok = True
except ImportError:
    try:
        import nacl.signing  # noqa: F401
        ok = True
    except ImportError:
        ok = False
sys.exit(0 if ok else 1)
PY
}

heimdall_verify_release() {
  local artifact="${1:-}" sig="${2:-}" pubkey="${3:-}"

  # Precondition ladder — distinct codes so the caller can log a precise, honest reason.
  [ -n "$artifact" ] && [ -f "$artifact" ] || return 4
  [ -n "$pubkey" ]   && [ -s "$pubkey" ]   || return 3
  [ -n "$sig" ]      && [ -s "$sig" ]      || return 2

  # Resolve the backend. 'auto' prefers the reference binary, else the bundled python verifier.
  local backend="${HEIMDALL_VERIFY_BACKEND:-auto}" use=""
  case "$backend" in
    minisign) command -v minisign >/dev/null 2>&1 && use="minisign" ;;
    python)   _hv_have_python_crypto && use="python" ;;
    auto|*)
      if command -v minisign >/dev/null 2>&1; then use="minisign"
      elif _hv_have_python_crypto; then use="python"
      fi ;;
  esac
  [ -n "$use" ] || return 5   # no verifier → fail-closed, never "assume valid".

  if [ "$use" = "minisign" ]; then
    minisign -Vq -p "$pubkey" -m "$artifact" -x "$sig" >/dev/null 2>&1 && return 0
    return 6
  fi

  local py; py="$(command -v python3 || command -v python)"
  "$py" "$_hv_dir/minisign_verify.py" \
    --pubkey "$pubkey" --artifact "$artifact" --sig "$sig" >/dev/null 2>&1 && return 0
  return 6
}

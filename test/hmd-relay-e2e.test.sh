#!/usr/bin/env bash
# test/hmd-relay-e2e.test.sh
#
# Oracle for bin/lib/hmd_relay_e2e.py -- the stdlib-only X25519 + HKDF-SHA256
# + ChaCha20-Poly1305 crypto module bin/heimdall-relay-client imports BY PATH
# for the relay's end-to-end channel (see that module's own docstring for the
# full design rationale). test/heimdall-app-relay.test.sh is the
# integration-level acceptance this module's presence unlocks -- its claims
# 2/3/4 reach the real Wave-1 handshake (seal/open_/derive_session_key) this
# module implements, and are SKIPPED there whenever this module is absent.
#
# RFC vector provenance: every hex constant asserted below is exercised via
# this module's own `_selftest_*()` functions, which embed vectors fetched
# verbatim from a direct, unsummarized download of rfc-editor.org's plaintext
# RFC text (see PRIMITIVES in the module's docstring for exactly how/where).
# Case 8 (AEAD RFC 8439 S2.8.2) additionally asserts, by source inspection,
# that e2e_available() actually calls _selftest_aead() -- so a future
# refactor that silently dropped that conjunct from the AND-chain (while
# leaving _selftest_aead() itself intact and still returning True) would
# still be caught here, not just a "trust the boolean" check.
#
# Cases:
#   1.  python3 -m py_compile is clean
#   2.  e2e_available() is True
#   3.  `python3 hmd_relay_e2e.py selftest` CLI exits 0
#   4.  RFC 7748 S6.1 X25519 Alice/Bob vector (_selftest_x25519)
#   5.  RFC 5869 A.1+A.2 HKDF-SHA256 vectors (_selftest_hkdf)
#   6.  RFC 8439 S2.3.2 ChaCha20 block vector (_selftest_chacha20)
#   7.  RFC 8439 S2.5.2 Poly1305 MAC vector (_selftest_poly1305)
#   8.  RFC 8439 S2.8.2 AEAD_CHACHA20_POLY1305 vector (_selftest_aead), and
#       confirmed wired into e2e_available()'s AND-chain
#   9.  seal()/open_() round-trip (fresh X25519-derived key, both directions
#       of derive_session_key agree)
#   10. open_() with the wrong key -> E2EError
#   11. open_() with a flipped ciphertext byte -> E2EError
#   12. open_() with a flipped tag byte -> E2EError
#   13. open_() with the wrong seq -> E2EError
#   14. open_() with the wrong sender -> E2EError
#   15. derive_session_key() with an all-zero (low-order) peer_pub -> E2EError
#   16. pub_from_b64() rejects a 31-byte key -> E2EError
#   17. nonce_for_seq() uniqueness: seq 0..1000 x {hmd,device} -> 2002 unique
#   18. 64 KiB seal()+open_() round-trip completes in < 5000ms (loose bound)
#   19. pub_from_b64() accepts URL-safe, unpadded base64 -- the real
#       device_pubkey wire shape (app's protocol.ts base64UrlEncode, forwarded
#       byte-for-byte by the relay into device_bound), not just this module's
#       own standard/padded pub_b64() output
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$REPO/bin/lib/hmd_relay_e2e.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "hmd-relay-e2e (stdlib X25519 + HKDF-SHA256 + ChaCha20-Poly1305 oracle)"

if [ ! -f "$MOD" ]; then
  printf '  SKIP %s is absent\n' "$MOD"
  printf '\n0 passed, 0 failed, 1 skipped (hmd-relay-e2e: module not landed)\n'
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf '  FAIL required tool missing: python3\n'
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ═══ 1. compiles clean ══════════════════════════════════════════════════════
if python3 -m py_compile "$MOD" 2>"$TMPROOT/case1.err"; then
  ok "1. python3 -m py_compile bin/lib/hmd_relay_e2e.py is clean"
else
  bad "1. py_compile failed:"
  sed 's/^/       | /' "$TMPROOT/case1.err"
fi

# ═══ 2. e2e_available() True ════════════════════════════════════════════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case2.err"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)
sys.exit(0 if e2e.e2e_available() is True else 1)
PYEOF
then
  ok "2. e2e_available() is True"
else
  bad "2. e2e_available() is not True:"
  sed 's/^/       | /' "$TMPROOT/case2.err"
fi

# ═══ 3. selftest CLI exit 0 ═════════════════════════════════════════════════
SELFTEST_OUT="$(python3 "$MOD" selftest 2>&1)"
SELFTEST_RC=$?
if [ "$SELFTEST_RC" -eq 0 ] && printf '%s' "$SELFTEST_OUT" | grep -q 'selftest OK'; then
  ok "3. \`python3 hmd_relay_e2e.py selftest\` exits 0 ($SELFTEST_OUT)"
else
  bad "3. selftest CLI: rc=$SELFTEST_RC output=$SELFTEST_OUT"
fi

# ═══ 4-7. embedded RFC vectors (X25519 / HKDF / ChaCha20 / Poly1305) ═══════
check_embedded_vector() {
  local num="$1" fn="$2" desc="$3"
  if python3 - "$MOD" "$fn" <<'PYEOF' 2>"$TMPROOT/case$num.err"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)
fn = getattr(e2e, sys.argv[2])
sys.exit(0 if fn() is True else 1)
PYEOF
  then
    ok "$num. $desc"
  else
    bad "$num. $desc:"
    sed 's/^/       | /' "$TMPROOT/case$num.err"
  fi
}
check_embedded_vector 4 _selftest_x25519   "RFC 7748 S6.1 X25519 Alice/Bob vector (_selftest_x25519)"
check_embedded_vector 5 _selftest_hkdf     "RFC 5869 A.1+A.2 HKDF-SHA256 vectors (_selftest_hkdf)"
check_embedded_vector 6 _selftest_chacha20 "RFC 8439 S2.3.2 ChaCha20 block vector (_selftest_chacha20)"
check_embedded_vector 7 _selftest_poly1305 "RFC 8439 S2.5.2 Poly1305 MAC vector (_selftest_poly1305)"

# ═══ 8. AEAD RFC 8439 S2.8.2 vector, and wired into e2e_available() ════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case8.err"
import importlib.util, sys, inspect
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

assert e2e._selftest_aead() is True, "_selftest_aead() did not return True"
wiring_src = inspect.getsource(e2e.e2e_available)
assert "_selftest_aead()" in wiring_src, "e2e_available() does not call _selftest_aead()"
sys.exit(0)
PYEOF
then
  ok "8. RFC 8439 S2.8.2 AEAD_CHACHA20_POLY1305 vector, wired into e2e_available()"
else
  bad "8. AEAD self-test / wiring check failed:"
  sed 's/^/       | /' "$TMPROOT/case8.err"
fi

# ═══ 9. seal()/open_() round-trip ══════════════════════════════════════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case9.err"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

priv_a, pub_a = e2e.generate_keypair()
priv_b, pub_b = e2e.generate_keypair()
key_a = e2e.derive_session_key(priv_a, pub_b, "sess-roundtrip")
key_b = e2e.derive_session_key(priv_b, pub_a, "sess-roundtrip")
assert key_a == key_b, "derived session keys disagree between the two sides"

nonce_b64, ct_b64 = e2e.seal(key_a, 3, "hmd", b"the plaintext body", aad=b"ctx1")
plaintext = e2e.open_(key_b, 3, "hmd", nonce_b64, ct_b64, aad=b"ctx1")
assert plaintext == b"the plaintext body", "round-trip plaintext mismatch"
sys.exit(0)
PYEOF
then
  ok "9. seal()/open_() round-trip (X25519-derived key, both directions agree)"
else
  bad "9. seal/open round-trip failed:"
  sed 's/^/       | /' "$TMPROOT/case9.err"
fi

# ═══ 10. wrong key -> E2EError ══════════════════════════════════════════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case10.err"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

priv_a, pub_a = e2e.generate_keypair()
priv_b, pub_b = e2e.generate_keypair()
key = e2e.derive_session_key(priv_a, pub_b, "sess-negtest")
other_key = e2e.secrets.token_bytes(32)
nonce_b64, ct_b64 = e2e.seal(key, 1, "hmd", b"payload", aad=b"")
try:
    e2e.open_(other_key, 1, "hmd", nonce_b64, ct_b64, aad=b"")
    sys.exit(1)
except e2e.E2EError:
    sys.exit(0)
PYEOF
then
  ok "10. open_() with the wrong key -> E2EError"
else
  bad "10. wrong key did not raise E2EError as expected:"
  sed 's/^/       | /' "$TMPROOT/case10.err"
fi

# ═══ 11. flipped ciphertext byte -> E2EError ════════════════════════════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case11.err"
import importlib.util, sys, base64
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

priv_a, pub_a = e2e.generate_keypair()
priv_b, pub_b = e2e.generate_keypair()
key = e2e.derive_session_key(priv_a, pub_b, "sess-negtest")
nonce_b64, ct_b64 = e2e.seal(key, 1, "hmd", b"payload bytes here", aad=b"")
raw = bytearray(base64.b64decode(ct_b64))
raw[0] ^= 0x01  # flip a byte inside the ciphertext portion, not the trailing 16-byte tag
flipped_b64 = base64.b64encode(bytes(raw)).decode("ascii")
try:
    e2e.open_(key, 1, "hmd", nonce_b64, flipped_b64, aad=b"")
    sys.exit(1)
except e2e.E2EError:
    sys.exit(0)
PYEOF
then
  ok "11. open_() with a flipped ciphertext byte -> E2EError"
else
  bad "11. flipped ciphertext byte did not raise E2EError as expected:"
  sed 's/^/       | /' "$TMPROOT/case11.err"
fi

# ═══ 12. flipped tag byte -> E2EError ════════════════════════════════════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case12.err"
import importlib.util, sys, base64
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

priv_a, pub_a = e2e.generate_keypair()
priv_b, pub_b = e2e.generate_keypair()
key = e2e.derive_session_key(priv_a, pub_b, "sess-negtest")
nonce_b64, ct_b64 = e2e.seal(key, 1, "hmd", b"payload bytes here", aad=b"")
raw = bytearray(base64.b64decode(ct_b64))
raw[-1] ^= 0x01  # flip the last byte, inside the trailing 16-byte Poly1305 tag
flipped_b64 = base64.b64encode(bytes(raw)).decode("ascii")
try:
    e2e.open_(key, 1, "hmd", nonce_b64, flipped_b64, aad=b"")
    sys.exit(1)
except e2e.E2EError:
    sys.exit(0)
PYEOF
then
  ok "12. open_() with a flipped tag byte -> E2EError"
else
  bad "12. flipped tag byte did not raise E2EError as expected:"
  sed 's/^/       | /' "$TMPROOT/case12.err"
fi

# ═══ 13. wrong seq -> E2EError ═══════════════════════════════════════════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case13.err"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

priv_a, pub_a = e2e.generate_keypair()
priv_b, pub_b = e2e.generate_keypair()
key = e2e.derive_session_key(priv_a, pub_b, "sess-negtest")
nonce_b64, ct_b64 = e2e.seal(key, 1, "hmd", b"payload", aad=b"")
try:
    e2e.open_(key, 2, "hmd", nonce_b64, ct_b64, aad=b"")
    sys.exit(1)
except e2e.E2EError:
    sys.exit(0)
PYEOF
then
  ok "13. open_() with the wrong seq -> E2EError"
else
  bad "13. wrong seq did not raise E2EError as expected:"
  sed 's/^/       | /' "$TMPROOT/case13.err"
fi

# ═══ 14. wrong sender -> E2EError ════════════════════════════════════════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case14.err"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

priv_a, pub_a = e2e.generate_keypair()
priv_b, pub_b = e2e.generate_keypair()
key = e2e.derive_session_key(priv_a, pub_b, "sess-negtest")
nonce_b64, ct_b64 = e2e.seal(key, 1, "hmd", b"payload", aad=b"")
try:
    e2e.open_(key, 1, "device", nonce_b64, ct_b64, aad=b"")
    sys.exit(1)
except e2e.E2EError:
    sys.exit(0)
PYEOF
then
  ok "14. open_() with the wrong sender -> E2EError"
else
  bad "14. wrong sender did not raise E2EError as expected:"
  sed 's/^/       | /' "$TMPROOT/case14.err"
fi

# ═══ 15. all-zero shared secret (low-order peer_pub) -> E2EError ════════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case15.err"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

priv_a, _ = e2e.generate_keypair()
zero_peer_pub = b"\x00" * 32
try:
    e2e.derive_session_key(priv_a, zero_peer_pub, "sess-zero")
    sys.exit(1)
except e2e.E2EError:
    sys.exit(0)
PYEOF
then
  ok "15. derive_session_key() with all-zero peer_pub (low-order point) -> E2EError"
else
  bad "15. all-zero shared secret did not raise E2EError as expected:"
  sed 's/^/       | /' "$TMPROOT/case15.err"
fi

# ═══ 16. pub_from_b64() rejects a 31-byte key -> E2EError ═══════════════════
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case16.err"
import importlib.util, sys, base64
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

b64_31 = base64.b64encode(b"\x01" * 31).decode("ascii")
try:
    e2e.pub_from_b64(b64_31)
    sys.exit(1)
except e2e.E2EError:
    sys.exit(0)
PYEOF
then
  ok "16. pub_from_b64() rejects a 31-byte key -> E2EError"
else
  bad "16. pub_from_b64 31-byte rejection failed:"
  sed 's/^/       | /' "$TMPROOT/case16.err"
fi

# ═══ 17. nonce_for_seq() uniqueness: seq 0..1000 x both senders ═════════════
NONCE_COUNT="$(python3 - "$MOD" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

nonces = set()
for seq in range(0, 1001):
    nonces.add(e2e.nonce_for_seq(seq, "hmd"))
    nonces.add(e2e.nonce_for_seq(seq, "device"))
print(len(nonces))
PYEOF
)"
if [ "$NONCE_COUNT" = "2002" ]; then
  ok "17. nonce_for_seq() uniqueness: seq 0..1000 x {hmd,device} -> 2002/2002 unique"
else
  bad "17. nonce uniqueness: got $NONCE_COUNT unique nonces, expected 2002"
fi

# ═══ 18. 64 KiB seal()+open_() round-trip timing (< 5000ms, loose) ══════════
TIMING_OUT="$(python3 - "$MOD" <<'PYEOF'
import importlib.util, sys, time, secrets
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

priv_a, pub_a = e2e.generate_keypair()
priv_b, pub_b = e2e.generate_keypair()
key = e2e.derive_session_key(priv_a, pub_b, "sess-timing")
data = secrets.token_bytes(65536)
t0 = time.time()
nonce_b64, ct_b64 = e2e.seal(key, 42, "hmd", data)
plaintext = e2e.open_(key, 42, "hmd", nonce_b64, ct_b64)
elapsed_ms = (time.time() - t0) * 1000.0
passed = (plaintext == data) and (elapsed_ms < 5000.0)
print("%.1f %s" % (elapsed_ms, "OK" if passed else "FAIL"))
PYEOF
)"
TIMING_MS="${TIMING_OUT%% *}"
TIMING_STATUS="${TIMING_OUT##* }"
if [ "$TIMING_STATUS" = "OK" ]; then
  ok "18. 64 KiB seal()+open_() round-trip in ${TIMING_MS}ms (< 5000ms)"
else
  bad "18. 64 KiB seal/open timing or correctness failed: $TIMING_OUT"
fi

# ═══ 19. pub_from_b64() accepts the real device_pubkey wire shape: URL-safe, ═
# ═══     unpadded base64 -- not just this module's own standard/padded form ═
if python3 - "$MOD" <<'PYEOF' 2>"$TMPROOT/case19.err"
import importlib.util, sys, base64
spec = importlib.util.spec_from_file_location("hmd_relay_e2e", sys.argv[1])
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

# A 32-byte value always has exactly one trailing '=' in standard base64
# (32 % 3 == 2), so every real device_pubkey -- URL-safe-encoded and
# padding-stripped by the app's protocol.ts:base64UrlEncode, then forwarded
# byte-for-byte by the relay into device_bound's payload -- arrives unpadded.
# A leading 0xFF also forces a '/' in the standard encoding, so this fixture
# exercises the alphabet swap, not just the padding restoration.
raw = bytes([0xFF]) + bytes(31)
std_padded = base64.b64encode(raw).decode("ascii")
urlsafe_unpadded = std_padded.replace("+", "-").replace("/", "_").rstrip("=")
if "_" not in urlsafe_unpadded or urlsafe_unpadded.endswith("="):
    sys.exit(2)  # fixture itself is wrong, not the thing under test

from_std = e2e.pub_from_b64(std_padded)
from_urlsafe = e2e.pub_from_b64(urlsafe_unpadded)
sys.exit(0 if (from_std == raw and from_urlsafe == raw) else 1)
PYEOF
then
  ok "19. pub_from_b64() accepts URL-safe unpadded base64 (real device_pubkey wire shape), still matches standard-padded decode"
else
  bad "19. pub_from_b64 url-safe/unpadded decode failed:"
  sed 's/^/       | /' "$TMPROOT/case19.err"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] && exit 0 || exit 1

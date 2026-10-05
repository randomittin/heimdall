#!/usr/bin/env bash
# test/hmd-relay-ws.test.sh -- oracle for bin/lib/hmd_relay_ws.py, the stdlib RFC 6455 client hmd's relay
# leg speaks over a hibernatable WebSocket (relay/contract/wire.json `stream_ws`; the client that uses it is
# bin/heimdall-relay-client, whose acceptance lives in test/heimdall-app-relay.test.sh).
#
# test/lib/relay_ws_cases.py holds the cases. They check the module against frames and handshakes that file
# builds and reads ITSELF, from RFC 6455's own text (section 1.3's handshake sample, section 5.7's masking
# examples), so the codec is never graded by its own encoder. The cases that need real sockets run on
# loopback; the rest play a script into the module's socket.
#
# Falsifiable by construction: the same cases are also run against deliberately broken copies of the module
# and must go red on each -- a codec case that can no longer fail is itself a failing suite.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$REPO/bin/lib/hmd_relay_ws.py"
CASES="$REPO/test/lib/relay_ws_cases.py"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "hmd-relay-ws (bin/lib/hmd_relay_ws.py vs RFC 6455, no network)"

for f in "$MOD" "$CASES"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FATAL: python3 missing\n' >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ── 1. the module compiles ───────────────────────────────────────────────────
if python3 -m py_compile "$MOD" 2>"$TMPROOT/compile.err"; then
  ok "python3 -m py_compile bin/lib/hmd_relay_ws.py is clean"
else
  bad "py_compile bin/lib/hmd_relay_ws.py: $(cat "$TMPROOT/compile.err")"
fi

# ── 2. every case passes against the real module ─────────────────────────────
OUT="$TMPROOT/cases.out"
python3 "$CASES" >"$OUT" 2>&1
rc=$?
tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$OUT" | tail -1)"
if [ "$rc" -eq 0 ] && [ -n "$tally" ] && printf '%s' "$tally" | grep -q ' 0 failed$'; then
  ok "the codec cases against the real module: $tally"
else
  bad "the codec cases failed (exit $rc, tally '${tally:-none}')"
  grep -E 'FAIL|Traceback|Error' -A2 "$OUT" | head -30
fi

# ── 3. the cases are not vacuous: a broken module must turn them red ─────────
# mutant NAME OLD NEW -- copies the module, replaces the one occurrence of OLD with NEW, runs the cases on the
# copy. Red (non-zero exit and a FAIL line) is the pass; a mutant whose OLD text is no longer in the module
# (it was refactored away) is itself a failure, so a mutant cannot rot into testing nothing.
mutant() {
  local name="$1" old="$2" new="$3" path="$TMPROOT/$1.py" out="$TMPROOT/$1.out"
  python3 - "$MOD" "$path" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("expected exactly one occurrence of %r, found %d" % (old, text.count(old)))
open(dst, "w", encoding="utf-8").write(text.replace(old, new))
PY
  if [ $? -ne 0 ]; then bad "mutant $name could not be built"; return; fi
  HMD_RELAY_WS_MODULE="$path" python3 "$CASES" >"$out" 2>&1
  local mrc=$?
  if [ "$mrc" -ne 0 ] && grep -q '  FAIL ' "$out"; then
    ok "a broken module turns the cases red: $name ($(grep -c '  FAIL ' "$out") cases failed)"
  else
    bad "a broken module is NOT caught: $name (exit $mrc)"
  fi
}

mutant client-frames-unmasked \
  'return head + mask_key + _apply_mask(payload, mask_key)' \
  'return head + mask_key + payload'
mutant accept-never-checked \
  'if (resp.getheader("Sec-WebSocket-Accept") or "").strip() != accept_for(key):' \
  'if False:'
mutant masked-server-frame-accepted \
  'if second & 0x80:' \
  'if False:'
mutant reserved-bits-ignored \
  'if first & 0x70:' \
  'if False:'
mutant message-cap-checked-after-the-payload \
  'elif self._fragment_bytes + length > self.max_message:' \
  'elif False:'
mutant connection-total-unbounded \
  'if self.max_total is not None and self.total_bytes > self.max_total:' \
  'if False:'
mutant timeout-drops-the-partial-frame \
  '        self.sock.settimeout(timeout)
        data = self.sock.recv(_RECV_BYTES)' \
  '        self.sock.settimeout(timeout)
        self._buf.clear()
        data = self.sock.recv(_RECV_BYTES)'
mutant ping-never-answered \
  'self._send(OP_PONG, payload)' \
  'None'
mutant text-not-checked-as-utf8 \
  'body.decode("utf-8")' \
  'body.decode("utf-8", "replace")'
mutant head-read-ahead \
  'stock, self.fp = self.fp, sock.makefile("rb", 1)' \
  'stock, self.fp = self.fp, sock.makefile("rb")'

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# test/hmd-session-code.test.sh
#
# Oracle for bin/lib/hmd_session_code.py -- the deterministic 5-char code that
# identifies an hmd session on the statusline (Row1 identity) and in
# sentinels/hmd-ui.py's /api/state.identity.session_code. Both readers load
# this ONE file (sentinels/hmd-statusline.py's `_session_code()`,
# sentinels/hmd-ui.py's `collect_session_code()`), so a passing case here is a
# guarantee those two surfaces can never show different codes for the same
# input.
#
# Context: the companion app (hmdapp, a separate repo) shows this SAME 5-char
# code as a tab label a person types to pair with a running `hmd ui` backend
# (src/sessioncode/SessionCodeEntry.tsx). The app's own code today
# (src/sessioncode/code.ts's generateSessionCode()) is pure crypto-random with
# collision retry -- there is no input it derives FROM, so there is nothing
# for this module to "match" behaviourally beyond its ALPHABET (CODE_ALPHABET
# below is copied character-for-character from that file). hmd's code is
# authoritative; see the coder's report for the one-line change the app needs
# to read it instead of minting its own.
#
# Cases 1-9 need only python3; 10-11 additionally launch a real `hmd ui`
# (curl+jq) and are SKIPped, not failed, if that binary or those tools are
# unavailable -- mirroring the "structural vs live" split test/hmd-qr.test.sh
# already documents in its own header.
#
# Cases:
#   1.  python3 -m py_compile is clean
#   2.  determinism: same --session-id run twice -> identical code
#   3.  alphabet: output contains only CODE_ALPHABET characters (no 0/1/I/O)
#   4.  length: exactly 5 characters
#   5.  distinct inputs -> distinct codes: 50 inputs, zero collisions (probabilistic)
#   6.  --repo fallback (no --session-id) -> source="repo"
#   7.  --session-id wins over --repo when both given -> source="session_id"
#   8.  --json output is valid JSON with exactly {code, source} keys
#   9.  neither flag given -> exit 1, clean stderr, no traceback
#   10. live hmd-ui server (loopback): /api/state.identity.session_code matches
#       the direct CLI --repo output for that same repo
#   11. public mode (--allow-host): identity.session_code is identical/unscrubbed
#       vs loopback -- a 5-char alphanumeric code is neither email- nor path-shaped
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$REPO/bin/lib/hmd_session_code.py"
UI="${HEIMDALL_UI_BIN:-$REPO/bin/heimdall-ui}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "hmd-session-code (deterministic 5-char session code oracle)"

if [ ! -f "$SC" ]; then
  printf '  SKIP %s is absent\n' "$SC"
  printf '\n0 passed, 0 failed, 1 skipped (hmd-session-code: author not landed)\n'
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf '  FAIL required tool missing: python3\n'
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

# ── sandbox ─────────────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# ═══ 1. compiles clean ══════════════════════════════════════════════════════
if python3 -m py_compile "$SC" 2>"$TMPROOT/pycompile.err"; then
  ok "1. python3 -m py_compile bin/lib/hmd_session_code.py is clean"
else
  bad "1. py_compile failed:"
  sed 's/^/       | /' "$TMPROOT/pycompile.err"
fi

# ═══ 2. determinism ══════════════════════════════════════════════════════════
C1="$(python3 "$SC" --session-id fixture-session-abc)"
C2="$(python3 "$SC" --session-id fixture-session-abc)"
if [ -n "$C1" ] && [ "$C1" = "$C2" ]; then
  ok "2. determinism: same --session-id run twice -> identical code ($C1)"
else
  bad "2. determinism: first=$C1 second=$C2"
fi

# ═══ 3/4. alphabet + length ═════════════════════════════════════════════════
if printf '%s' "$C1" | grep -Eq '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]+$'; then
  ok "3. alphabet: '$C1' uses only CODE_ALPHABET chars (no 0/1/I/O)"
else
  bad "3. alphabet: '$C1' contains a character outside CODE_ALPHABET"
fi
if [ "${#C1}" = 5 ]; then
  ok "4. length: '$C1' is exactly 5 characters"
else
  bad "4. length: '$C1' is ${#C1} characters, expected 5"
fi

# ═══ 5. distinct inputs -> distinct codes (50 inputs, no collision) ═════════
COLLISIONS="$(python3 - "$SC" <<'PYEOF'
import importlib.util as u, sys
spec = u.spec_from_file_location("hmd_session_code", sys.argv[1])
mod = u.module_from_spec(spec)
spec.loader.exec_module(mod)
codes = [mod.session_code_for(session_id=f"fixture-session-{i}")[0] for i in range(50)]
print(len(codes) - len(set(codes)))
PYEOF
)"
if [ "$COLLISIONS" = "0" ]; then
  ok "5. distinct inputs: 50 session ids -> 50 distinct codes (0 collisions)"
else
  bad "5. distinct inputs: $COLLISIONS collision(s) across 50 session ids"
fi

# ═══ 6/7. --repo fallback + --session-id precedence ═════════════════════════
REPO_JSON="$(python3 "$SC" --repo "$TMPROOT" --json)"
REPO_SRC="$(printf '%s' "$REPO_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["source"])')"
if [ "$REPO_SRC" = "repo" ]; then
  ok "6. --repo (no --session-id) -> source=\"repo\" ($REPO_JSON)"
else
  bad "6. --repo fallback: source=$REPO_SRC, expected \"repo\" ($REPO_JSON)"
fi

BOTH_JSON="$(python3 "$SC" --session-id fixture-session-abc --repo "$TMPROOT" --json)"
BOTH_SRC="$(printf '%s' "$BOTH_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["source"])')"
BOTH_CODE="$(printf '%s' "$BOTH_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["code"])')"
if [ "$BOTH_SRC" = "session_id" ] && [ "$BOTH_CODE" = "$C1" ]; then
  ok "7. --session-id wins over --repo when both given (source=session_id, code=$BOTH_CODE matches case 2)"
else
  bad "7. precedence: source=$BOTH_SRC code=$BOTH_CODE, expected session_id/$C1"
fi

# ═══ 8. --json shape ═════════════════════════════════════════════════════════
if printf '%s' "$REPO_JSON" | python3 -c 'import json,sys
d = json.load(sys.stdin)
assert isinstance(d, dict)
assert set(d.keys()) == {"code", "source"}
assert isinstance(d["code"], str) and len(d["code"]) == 5
assert d["source"] in ("session_id", "repo")
' 2>"$TMPROOT/json-shape.err"; then
  ok "8. --json output is valid JSON with exactly {code, source} keys"
else
  bad "8. --json shape check failed:"
  sed 's/^/       | /' "$TMPROOT/json-shape.err"
fi

# ═══ 9. neither flag -> clean error, no traceback ═══════════════════════════
NOARGS_OUT="$(python3 "$SC" 2>&1)"
NOARGS_RC=$?
if [ "$NOARGS_RC" != "0" ] && printf '%s' "$NOARGS_OUT" | grep -q '^error:' && ! printf '%s' "$NOARGS_OUT" | grep -q "Traceback"; then
  ok "9. neither --session-id nor --repo -> exit $NOARGS_RC, clean 'error: ...' message, no traceback"
else
  bad "9. no-args behavior: rc=$NOARGS_RC out=$NOARGS_OUT"
fi

# ═══ 10/11. live hmd-ui server: /api/state carries identity.session_code ════
if [ ! -x "$UI" ]; then
  printf '  SKIP 10/11 bin/heimdall-ui is absent or not executable (%s)\n' "$UI"
  printf '\n%d passed, %d failed, 1 skipped (heimdall-ui not landed)\n' "$PASS" "$FAIL"
  [ "$FAIL" = 0 ] && exit 0 || exit 1
fi
MISSING_TOOL=""
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || MISSING_TOOL="$tool"
done
if [ -n "$MISSING_TOOL" ]; then
  printf '  SKIP 10/11 required tool missing: %s\n' "$MISSING_TOOL"
  printf '\n%d passed, %d failed, 1 skipped (missing %s)\n' "$PASS" "$FAIL" "$MISSING_TOOL"
  [ "$FAIL" = 0 ] && exit 0 || exit 1
fi

export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
FIX="$TMPROOT/fixture-repo"
mkdir -p "$HOME/.claude" "$FIX"
FIX_REAL="$(cd "$FIX" && pwd -P)"
EXPECT_CODE="$(python3 "$SC" --repo "$FIX_REAL")"

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# Launch one `hmd ui` on a fresh port with the given extra flags; on success sets
# the globals PORT/TOKEN/BASE/AUTH/OUT for the caller to copy out immediately.
# CLAUDE_SESSION_ID/SESSION_ID are unset in the launched process so the ambient
# Claude Code session this test is itself running inside can never leak in and
# make collect_session_code() pick session_id over the repo path -- EXPECT_CODE
# above was computed with --repo, so the cross-check below needs repo-scoping
# on the server side too. Modeled on launch_server() in
# test/heimdall-ui-allowhost.test.sh.
launch() {
  local label="$1"; shift
  PORT="$(free_port)"
  OUT="$TMPROOT/srv-$label.out"
  ( unset CLAUDE_SESSION_ID SESSION_ID
    cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" --repo "$FIX" --port "$PORT" --no-open "$@" ) \
    >"$OUT" 2>&1 &
  SRV_PID=$!
  PIDS+=("$SRV_PID")
  local url_re="^http://127\.0\.0\.1:$PORT/\?(t|token)=[A-Za-z0-9_-]+\$"
  if ! wait_for "$OUT" "$url_re" 10; then
    bad "$label: server did not print a URL line within 10s"
    sed 's/^/       | /' "$OUT"
    return 1
  fi
  local url q tp
  url="$(grep -E "$url_re" "$OUT" | head -1)"
  q="${url#*\?}"
  tp="${q%%=*}"
  TOKEN="${q#*=}"
  BASE="http://127.0.0.1:$PORT"
  AUTH="$tp=$TOKEN"
  return 0
}

if launch loopback; then
  BODY_N="$TMPROOT/state-loopback.json"
  rc_n="$(curl -s -o "$BODY_N" -w '%{http_code}' "$BASE/api/state?$AUTH")"
  GOT_N="$(jq -r '.identity.session_code // empty' "$BODY_N" 2>/dev/null)"
  if [ "$rc_n" = "200" ] && [ -n "$GOT_N" ] && [ "$GOT_N" = "$EXPECT_CODE" ]; then
    ok "10. loopback /api/state.identity.session_code == direct CLI --repo output ($GOT_N)"
  else
    bad "10. loopback session_code: rc=$rc_n got=$GOT_N expected=$EXPECT_CODE"
  fi
else
  bad "10. loopback server failed to launch"
fi

if launch pubmode --allow-host demo.tail1234.ts.net; then
  BODY_H="$TMPROOT/state-public.json"
  rc_h="$(curl -s -o "$BODY_H" -w '%{http_code}' -H "Host: demo.tail1234.ts.net" "$BASE/api/state?$AUTH")"
  GOT_H="$(jq -r '.identity.session_code // empty' "$BODY_H" 2>/dev/null)"
  if [ "$rc_h" = "200" ] && [ -n "$GOT_H" ] && [ "$GOT_H" = "$EXPECT_CODE" ]; then
    ok "11. public mode (--allow-host) identity.session_code unscrubbed, identical to loopback ($GOT_H)"
  else
    bad "11. public mode session_code: rc=$rc_h got=$GOT_H expected=$EXPECT_CODE"
  fi
else
  bad "11. public-mode server failed to launch"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] && exit 0 || exit 1

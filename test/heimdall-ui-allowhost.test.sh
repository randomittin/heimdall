#!/usr/bin/env bash
# test/heimdall-ui-allowhost.test.sh
#
# Oracle for Wave 1.1 of .planning/plans/PLAN-hmd-app-connect.md -- making `hmd ui`
# safe behind a Tailscale Funnel reverse proxy while keeping the 127.0.0.1 bind.
# Independent of sentinels/hmd-ui.py's own source: every assertion below cites the
# PLAN/brief requirement it is derived from.
#
# Contract under test:
#   - --allow-host <name> (repeatable): extends the Host allowlist so NAME (bare) and
#     NAME:<any numeric port> match exactly, case-insensitive, no wildcard/suffix
#     matching; bind stays 127.0.0.1; default (no flag) behaviour is byte-for-byte
#     unchanged                                                                (D3)
#   - --trust-proxy: per-IP accounting (backoff) uses X-Forwarded-For's first value
#     ONLY when the flag is set AND the header is present; otherwise the socket
#     peer, with X-Forwarded-* ignored entirely when the flag is absent        (D2/D3)
#   - per-IP backoff: 5 auth failures (401 from a presented-but-wrong token, or any
#     403) inside a rolling 60s window -> 429 + `Retry-After: 30` header + body
#     {"error":"backoff","retry_after_s":30}, on EVERY route incl. /api/send and
#     /api/events; a successful auth resets the count                          (D2)
#   - /api/state gains "transport": {"bind":"loopback","public_host":<name>|null,
#     "trust_proxy":bool}, additive only
#   - the startup banner names the allowed public hostname + an exposure warning
#     when --allow-host is set, and prints neither when it is not
#
# Hermetic: HOME/HEIMDALL_HOME redirected to a temp dir. Every server this file
# starts is its OWN process on its OWN port -- in-memory backoff state must never
# leak between test groups, so each group that needs a clean failure count gets a
# fresh launch. Every background process is reaped on EXIT. No `timeout` on macOS
# -- every wait is a bounded sleep-0.2 poll. The bad token used throughout is a
# fixed, obviously-fake, low-entropy literal (never derived from the real
# per-launch token), so nothing here is gitleaks-secret-shaped.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="${HEIMDALL_UI_BIN:-$REPO/bin/heimdall-ui}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-ui-allowhost (--allow-host / --trust-proxy / per-IP backoff oracle)"

if [ ! -x "$UI" ]; then
  printf '  SKIP bin/heimdall-ui is absent or not executable (%s)\n' "$UI"
  printf '\n0 passed, 0 failed, 1 skipped (heimdall-ui not landed)\n'
  exit 0
fi
if ! grep -q -- '--allow-host' "$REPO/sentinels/hmd-ui.py" 2>/dev/null; then
  printf '  SKIP --allow-host is not wired into sentinels/hmd-ui.py yet\n'
  printf '\n0 passed, 0 failed, 1 skipped (Wave 1.1: author not landed)\n'
  exit 0
fi
for tool in curl jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '  FAIL required tool missing: %s\n' "$tool"
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

# ── sandbox ─────────────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d)"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
FIX="$TMPROOT/fixture-repo"
mkdir -p "$HOME/.claude" "$FIX"

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

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}

# Poll a file for a regex, up to $3 seconds (0.2s steps). Exit 0 on match.
wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

code_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

BADTOK="notavalidtoken-0000000000000000000000"

# Launch one `hmd ui` on a fresh port with the given extra flags; on success sets
# the globals PORT/TOKEN/BASE/AUTH/OUT for the caller to copy out immediately.
# Each call is its own process, so in-memory backoff state never leaks between
# test groups -- that isolation is the reason six servers exist below, not one.
launch_server() {
  local label="$1"; shift
  PORT="$(free_port)"
  OUT="$TMPROOT/srv-$label.out"
  ( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" --repo "$FIX" --port "$PORT" --no-open "$@" ) \
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

# ═══ Group A -- Host allowlist precision (SRV_HOST) ═════════════════════════
# --allow-host demo.tail1234.ts.net --allow-host second.tail1234.ts.net
launch_server host --allow-host demo.tail1234.ts.net --allow-host second.tail1234.ts.net || exit 1
PORT_H="$PORT"; BASE_H="$BASE"; AUTH_H="$AUTH"

rc="$(code_of -H "Host: demo.tail1234.ts.net" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "200" ]; then ok "1. Host: demo.tail1234.ts.net (bare, --allow-host) -> 200"
else bad "1. Host: demo.tail1234.ts.net -> $rc, expected 200"; fi

rc="$(code_of -H "Host: demo.tail1234.ts.net:443" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "200" ]; then ok "2. Host: demo.tail1234.ts.net:443 -> 200"
else bad "2. Host: demo.tail1234.ts.net:443 -> $rc, expected 200"; fi

rc="$(code_of -H "Host: DEMO.TAIL1234.TS.NET" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "200" ]; then ok "3. Host: DEMO.TAIL1234.TS.NET (case-insensitive) -> 200"
else bad "3. Host: DEMO.TAIL1234.TS.NET -> $rc, expected 200"; fi

rc="$(code_of -H "Host: evil.example" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "403" ]; then ok "4. Host: evil.example (unrelated host) -> 403"
else bad "4. Host: evil.example -> $rc, expected 403"; fi

rc="$(code_of -H "Host: demo.tail1234.ts.net.evil.com" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "403" ]; then ok "5. Host: demo.tail1234.ts.net.evil.com (allowed name as a PREFIX) -> 403, no suffix matching"
else bad "5. Host: demo.tail1234.ts.net.evil.com -> $rc, expected 403"; fi

rc="$(code_of -H "Host: evil-demo.tail1234.ts.net" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "403" ]; then ok "6. Host: evil-demo.tail1234.ts.net (allowed name as a SUFFIX) -> 403, no wildcard matching"
else bad "6. Host: evil-demo.tail1234.ts.net -> $rc, expected 403"; fi

rc="$(code_of -H "Host: second.tail1234.ts.net" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "200" ]; then ok "7. Host: second.tail1234.ts.net (2nd --allow-host value) -> 200"
else bad "7. Host: second.tail1234.ts.net -> $rc, expected 200"; fi

rc="$(code_of -H "Host: second.tail1234.ts.net:443" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "200" ]; then ok "8. Host: second.tail1234.ts.net:443 -> 200"
else bad "8. Host: second.tail1234.ts.net:443 -> $rc, expected 200"; fi

rc="$(code_of -H "Host: demo.tail1234.ts.net:8443" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "200" ]; then ok "8b. Host: demo.tail1234.ts.net:8443 (non-443 Funnel port) -> 200, any numeric port"
else bad "8b. Host: demo.tail1234.ts.net:8443 -> $rc, expected 200"; fi

rc="$(code_of -H "Host: demo.tail1234.ts.net:10000" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "200" ]; then ok "8c. Host: demo.tail1234.ts.net:10000 (another Funnel port) -> 200, any numeric port"
else bad "8c. Host: demo.tail1234.ts.net:10000 -> $rc, expected 200"; fi

rc="$(code_of -H "Host: demo.tail1234.ts.net:abc" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "403" ]; then ok "8d. Host: demo.tail1234.ts.net:abc (non-numeric port) -> 403, exact match only"
else bad "8d. Host: demo.tail1234.ts.net:abc -> $rc, expected 403"; fi

rc="$(code_of -H "Host: demo.tail1234.ts.net:" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "403" ]; then ok "8e. Host: demo.tail1234.ts.net: (empty port) -> 403, exact match only"
else bad "8e. Host: demo.tail1234.ts.net: -> $rc, expected 403"; fi

rc="$(code_of -H "Host: 127.0.0.1:$PORT_H" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "200" ]; then ok "9. Host: 127.0.0.1:<port> still works with --allow-host set (loopback never removed)"
else bad "9. Host: 127.0.0.1:<port> -> $rc, expected 200"; fi

rc="$(code_of -H "Host: localhost:$PORT_H" "$BASE_H/api/state?$AUTH_H")"
if [ "$rc" = "200" ]; then ok "10. Host: localhost:<port> still works with --allow-host set (loopback never removed)"
else bad "10. Host: localhost:<port> -> $rc, expected 200"; fi

# ═══ Group B -- no flags: default behaviour byte-for-byte unchanged (SRV_NOHOST) ═
launch_server nohost || exit 1
PORT_N="$PORT"; BASE_N="$BASE"; AUTH_N="$AUTH"; OUT_N="$OUT"

rc="$(code_of -H "Host: demo.tail1234.ts.net" "$BASE_N/api/state?$AUTH_N")"
if [ "$rc" = "403" ]; then ok "11. no --allow-host: the SAME hostname another server allowed is refused -> 403 (per-launch, not global)"
else bad "11. no --allow-host: Host: demo.tail1234.ts.net -> $rc, expected 403"; fi

BODY="$TMPROOT/state-n.json"
rc="$(curl -s -o "$BODY" -w '%{http_code}' "$BASE_N/api/state?$AUTH_N")"
if [ "$rc" = "200" ] && jq -e '.transport == {"bind":"loopback","public_host":null,"trust_proxy":false}' "$BODY" >/dev/null 2>&1; then
  ok "12. /api/state.transport with no flags: {bind:loopback, public_host:null, trust_proxy:false}"
else
  bad "12. /api/state.transport (no flags): rc=$rc transport=$(jq -c '.transport' "$BODY" 2>/dev/null)"
fi

if grep -qi 'public hostname allowed' "$OUT_N"; then
  bad "13. no --allow-host: banner unexpectedly names a public hostname"
else
  ok "13. no --allow-host: no public-hostname banner line printed"
fi

# ═══ Group C -- transport shape+banner with flags; trust-proxy XFF attribution ══
launch_server trustproxy --allow-host demo.tail1234.ts.net --trust-proxy || exit 1
PORT_T="$PORT"; BASE_T="$BASE"; AUTH_T="$AUTH"; OUT_T="$OUT"

BODY="$TMPROOT/state-t.json"
rc="$(curl -s -o "$BODY" -w '%{http_code}' -H "Host: demo.tail1234.ts.net" "$BASE_T/api/state?$AUTH_T")"
if [ "$rc" = "200" ] && jq -e '.transport == {"bind":"loopback","public_host":"demo.tail1234.ts.net","trust_proxy":true}' "$BODY" >/dev/null 2>&1; then
  ok "14. /api/state.transport with --allow-host+--trust-proxy: exact shape"
else
  bad "14. /api/state.transport (with flags): rc=$rc transport=$(jq -c '.transport' "$BODY" 2>/dev/null)"
fi

if grep -q 'hmd ui: public hostname allowed: demo.tail1234.ts.net' "$OUT_T" && grep -qi 'warning' "$OUT_T"; then
  ok "15. banner names the public hostname + an exposure WARNING line"
else
  bad "15. banner missing/wrong; server output:"; sed 's/^/       | /' "$OUT_T"
fi

# 5 bad-token attempts carrying a spoofed XFF chain; under --trust-proxy the FIRST
# XFF value (10.9.8.7) is what gets accounted, not the real peer.
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.7, 127.0.0.1" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16a. XFF-attributed bad-token attempt 1 -> 401"
else bad "16a. XFF-attributed bad-token attempt 1 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.7, 127.0.0.1" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16b. XFF-attributed bad-token attempt 2 -> 401"
else bad "16b. XFF-attributed bad-token attempt 2 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.7, 127.0.0.1" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16c. XFF-attributed bad-token attempt 3 -> 401"
else bad "16c. XFF-attributed bad-token attempt 3 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.7, 127.0.0.1" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16d. XFF-attributed bad-token attempt 4 -> 401"
else bad "16d. XFF-attributed bad-token attempt 4 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.7, 127.0.0.1" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16e. XFF-attributed bad-token attempt 5 -> 401"
else bad "16e. XFF-attributed bad-token attempt 5 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.7, 127.0.0.1" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "429" ]; then ok "16f. 6th XFF-attributed bad-token attempt -> 429 (ip=10.9.8.7 locked, --trust-proxy)"
else bad "16f. 6th XFF-attributed bad-token attempt -> $rc, expected 429"; fi

rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.7, 127.0.0.1" "$BASE_T/api/state?$AUTH_T")"
if [ "$rc" = "429" ]; then ok "17. locked XFF ip=10.9.8.7: even a GOOD token -> 429 while locked"
else bad "17. locked XFF ip + good token -> $rc, expected 429"; fi

rc="$(code_of -H "Host: demo.tail1234.ts.net" "$BASE_T/api/state?$AUTH_T")"
if [ "$rc" = "200" ]; then ok "18. same server, request WITHOUT X-Forwarded-For (real peer 127.0.0.1) still passes -> 200"
else bad "18. request without XFF (real peer) -> $rc, expected 200 (only the XFF-named ip is locked)"; fi

# ═══ Group D -- core backoff contract (SRV_LOCKOUT1, no flags) ══════════════
launch_server lockout1 || exit 1
PORT_L1="$PORT"; BASE_L1="$BASE"; AUTH_L1="$AUTH"

rc="$(code_of "$BASE_L1/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "19a. bad-token attempt 1 -> 401"
else bad "19a. bad-token attempt 1 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_L1/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "19b. bad-token attempt 2 -> 401"
else bad "19b. bad-token attempt 2 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_L1/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "19c. bad-token attempt 3 -> 401"
else bad "19c. bad-token attempt 3 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_L1/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "19d. bad-token attempt 4 -> 401"
else bad "19d. bad-token attempt 4 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_L1/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "19e. bad-token attempt 5 -> 401"
else bad "19e. bad-token attempt 5 -> $rc, expected 401"; fi

HDR="$TMPROOT/l1-6.hdr"; BODY="$TMPROOT/l1-6.json"
rc="$(curl -s -D "$HDR" -o "$BODY" -w '%{http_code}' "$BASE_L1/api/state?token=$BADTOK")"
if [ "$rc" = "429" ] && grep -qi '^retry-after: *30' "$HDR" \
   && jq -e '.error=="backoff" and .retry_after_s==30' "$BODY" >/dev/null 2>&1; then
  ok "19f. 6th bad-token attempt -> 429, Retry-After: 30, body {\"error\":\"backoff\",\"retry_after_s\":30}"
else
  bad "19f. 6th bad-token attempt: rc=$rc hdr=$(tr -d '\r' <"$HDR" | grep -i retry-after) body=$(cat "$BODY" 2>/dev/null)"
fi

rc="$(code_of "$BASE_L1/api/state?$AUTH_L1")"
if [ "$rc" = "429" ]; then ok "20. locked out: even a VALID token -> 429 (lockout blocks everyone, not just guessers)"
else bad "20. locked out + good token -> $rc, expected 429"; fi

rc="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
      -d '{"text":"x"}' "$BASE_L1/api/send?$AUTH_L1")"
if [ "$rc" = "429" ]; then ok "21. POST /api/send while locked out -> 429 (same gate, every route)"
else bad "21. /api/send while locked out -> $rc, expected 429"; fi

rc="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE_L1/api/events?$AUTH_L1")"
if [ "$rc" = "429" ]; then ok "22. GET /api/events while locked out -> 429 (same gate, every route)"
else bad "22. /api/events while locked out -> $rc, expected 429"; fi

# ═══ Group E -- XFF ignored entirely without --trust-proxy (SRV_LOCKOUT_NOTRUST) ═
launch_server lockout-notrust || exit 1
PORT_L2="$PORT"; BASE_L2="$BASE"; AUTH_L2="$AUTH"

rc="$(code_of -H "X-Forwarded-For: 10.9.8.7" "$BASE_L2/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "23a. bad-token+XFF (no --trust-proxy) attempt 1 -> 401"
else bad "23a. bad-token+XFF attempt 1 -> $rc, expected 401"; fi
rc="$(code_of -H "X-Forwarded-For: 10.9.8.7" "$BASE_L2/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "23b. bad-token+XFF (no --trust-proxy) attempt 2 -> 401"
else bad "23b. bad-token+XFF attempt 2 -> $rc, expected 401"; fi
rc="$(code_of -H "X-Forwarded-For: 10.9.8.7" "$BASE_L2/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "23c. bad-token+XFF (no --trust-proxy) attempt 3 -> 401"
else bad "23c. bad-token+XFF attempt 3 -> $rc, expected 401"; fi
rc="$(code_of -H "X-Forwarded-For: 10.9.8.7" "$BASE_L2/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "23d. bad-token+XFF (no --trust-proxy) attempt 4 -> 401"
else bad "23d. bad-token+XFF attempt 4 -> $rc, expected 401"; fi
rc="$(code_of -H "X-Forwarded-For: 10.9.8.7" "$BASE_L2/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "23e. bad-token+XFF (no --trust-proxy) attempt 5 -> 401"
else bad "23e. bad-token+XFF attempt 5 -> $rc, expected 401"; fi
rc="$(code_of -H "X-Forwarded-For: 10.9.8.7" "$BASE_L2/api/state?token=$BADTOK")"
if [ "$rc" = "429" ]; then ok "23f. 6th bad-token+XFF attempt -> 429 (counting still works with XFF present but untrusted)"
else bad "23f. 6th bad-token+XFF attempt -> $rc, expected 429"; fi

rc="$(code_of "$BASE_L2/api/state?$AUTH_L2")"
if [ "$rc" = "429" ]; then ok "24. without --trust-proxy, XFF was ignored: the real peer (127.0.0.1) got locked, not the fake XFF ip -- a good token with NO XFF header still gets 429"
else bad "24. without --trust-proxy, real peer should be locked -> $rc, expected 429"; fi

# ═══ Group F -- a successful auth resets the counter (SRV_RESET, no flags) ══
launch_server reset || exit 1
PORT_R="$PORT"; BASE_R="$BASE"; AUTH_R="$AUTH"

rc="$(code_of "$BASE_R/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "25a. pre-reset bad-token attempt 1 -> 401"
else bad "25a. pre-reset bad-token attempt 1 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_R/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "25b. pre-reset bad-token attempt 2 -> 401"
else bad "25b. pre-reset bad-token attempt 2 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_R/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "25c. pre-reset bad-token attempt 3 -> 401"
else bad "25c. pre-reset bad-token attempt 3 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_R/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "25d. pre-reset bad-token attempt 4 -> 401"
else bad "25d. pre-reset bad-token attempt 4 -> $rc, expected 401"; fi

rc="$(code_of "$BASE_R/api/state?$AUTH_R")"
if [ "$rc" = "200" ]; then ok "25e. 4 failures then a good token -> 200 (not yet locked, threshold is 5) and resets the count"
else bad "25e. good token after 4 failures -> $rc, expected 200"; fi

rc="$(code_of "$BASE_R/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "26a. post-reset bad-token attempt 1 -> 401"
else bad "26a. post-reset bad-token attempt 1 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_R/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "26b. post-reset bad-token attempt 2 -> 401"
else bad "26b. post-reset bad-token attempt 2 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_R/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "26c. post-reset bad-token attempt 3 -> 401"
else bad "26c. post-reset bad-token attempt 3 -> $rc, expected 401"; fi
rc="$(code_of "$BASE_R/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "26d. post-reset bad-token attempt 4 -> still plain 401, NOT 429 (proves the reset in 25e actually happened -- had it not, cumulative failures would be 4+4=8 and this request would already be locked)"
else bad "26d. post-reset bad-token attempt 4 -> $rc, expected 401 (reset must have failed)"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

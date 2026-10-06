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
#   - --trust-proxy: per-IP accounting (backoff) uses X-Forwarded-For's LAST value --
#     the one the trusted hop itself appended -- ONLY when the flag is set AND the
#     header is present; otherwise the socket peer, with X-Forwarded-* ignored
#     entirely when the flag is absent                                     (D2/D3, A1)
#   - per-IP backoff: 5 auth failures (401 from a presented-but-wrong token, or any
#     403) inside a rolling 60s window -> 429 + `Retry-After: 30` header + body
#     {"error":"backoff","retry_after_s":30}, on EVERY route incl. /api/send and
#     /api/events. A request presenting the CORRECT token is NEVER denied by this,
#     even while its ip is presently locked -- lockout exists to slow a guesser, not
#     to lock out the legitimate phone behind a shared carrier NAT, a spoofed XFF, or
#     a --trust-proxy-off peer collision; a successful auth also resets the count
#                                                                             (D2, A7)
#   - /api/state gains "transport": {"bind":"loopback","public_host":<name>|null,
#     "trust_proxy":bool}, additive only
#   - the startup banner names the allowed public hostname + an exposure warning
#     when --allow-host is set, and prints neither when it is not
#   - A2: UIHandler.timeout=10s bounds the pre-auth header read (an idle connection
#     that sends nothing is closed within it); MAX_CONNECTIONS=64 caps concurrent
#     connections server-wide; MAX_SSE_STREAMS=8 caps concurrent /api/events streams
#     specifically -> 503 + `Retry-After: 5` past that narrower cap; the listen backlog
#     (UIServer.request_queue_size) is MAX_CONNECTIONS, so a burst that size is queued
#     in the kernel and accepted, never refused at the TCP layer before auth/caps run
#   - A9: when --allow-host is set, /api/state.repo and out-of-repo edits.paths
#     entries become basenames, and every roster/ledger.team string is scrubbed of
#     email-shaped substrings and absolute paths; loopback output is byte-for-byte
#     unaffected (the redaction is gated strictly on transport.public_host)
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR redirected to a temp dir -- TMPDIR matters
#   as much as HOME here: sentinels/hmd-ui.py's collect_parallelism() falls back to
#   the most-recently-touched *.state file under $TMPDIR/heimdall-parallel when no
#   session id is set (which is always true for the server this file launches), so
#   an unpinned TMPDIR reads whichever REAL Claude Code session on the machine last
#   made a tool call -- live counters that keep changing for reasons having nothing
#   to do with this fixture. No case here diffs two /api/state snapshots the way
#   heimdall-ui-panels.test.sh's case 9c does, so this leak was not observed to flip
#   an assertion in this file, but it was reproduced breaking that panels case under
#   3-way concurrent load (same server, same leak) -- pinned here too so this file
#   can never become the next one to grow a snapshot/idle assertion that trips on it.
#   HEIMDALL_FALLBACK_ASSUME_REACHABLE is pinned for the same class of reason:
#   collect_fallback() (sentinels/hmd-ui.py) shells out to `heimdall-fallback status
#   --json` on every GET and every poll tick, and that command's own preflight makes
#   a REAL network probe to its configured (default, loopback) endpoint regardless of
#   state. Unpinned, every server here depends on whatever is or isn't listening on
#   that real port on this real machine, and how fast it answers under however much
#   load the sweep's sibling suites put on the same port at the same time -- exactly
#   what turned this suite into an hours-long intermittent hang under contention
#   before this pin plus collect_fallback()'s own bounded timeout landed
#   (FALLBACK_CMD_TIMEOUT_S). Group J below proves the timeout side directly, with a
#   stub heimdall-fallback that never answers at all.
#   Every server this file
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
# TMPDIR before HOME: parallelism-tracker (see Hermetic note above) is keyed off
# $TMPDIR, not $HOME -- without this, this server's /api/state.parallelism reads
# whatever real, concurrently-running Claude Code session most recently touched
# $TMPDIR/heimdall-parallel, which is never stable across a test run.
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
# See "Hermetic" note above: short-circuits heimdall-fallback's own real network
# probe with no I/O at all (bin/heimdall-fallback; established pattern, see
# test/heimdall-fallback.test.sh) -- 0 (not 1) since nothing here configures a real
# gateway and "unreachable" is the honest answer for this sandbox.
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
FIX="$TMPROOT/fixture-repo"
mkdir -p "$HOME/.claude" "$FIX"
# hmd-ui's resolve_root() canonicalises via os.path.realpath, which on macOS resolves
# /var (and /tmp) through their /private symlink; comparing a raw $FIX would then
# never match a real "repo" field even on an entirely unredacted, correct response.
FIX_REAL="$(cd "$FIX" && pwd -P)"

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

# 6 bad-token attempts carrying a spoofed XFF chain whose FIRST value (attacker-
# controlled) changes on every request; under --trust-proxy only the LAST value
# (9.9.9.9 -- the one a real single trusted hop would itself append) is what gets
# accounted (A1). If the first value were still trusted, each of these would look
# like a distinct, never-before-seen ip and none of them would ever lock.
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.7, 9.9.9.9" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16a. XFF-attributed bad-token attempt 1 (first hop 10.9.8.7) -> 401"
else bad "16a. XFF-attributed bad-token attempt 1 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.8, 9.9.9.9" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16b. XFF-attributed bad-token attempt 2 (first hop varied to 10.9.8.8) -> 401"
else bad "16b. XFF-attributed bad-token attempt 2 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.9, 9.9.9.9" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16c. XFF-attributed bad-token attempt 3 (first hop varied to 10.9.8.9) -> 401"
else bad "16c. XFF-attributed bad-token attempt 3 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.10, 9.9.9.9" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16d. XFF-attributed bad-token attempt 4 (first hop varied to 10.9.8.10) -> 401"
else bad "16d. XFF-attributed bad-token attempt 4 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.11, 9.9.9.9" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "401" ]; then ok "16e. XFF-attributed bad-token attempt 5 (first hop varied to 10.9.8.11) -> 401"
else bad "16e. XFF-attributed bad-token attempt 5 -> $rc, expected 401"; fi
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.12, 9.9.9.9" "$BASE_T/api/state?token=$BADTOK")"
if [ "$rc" = "429" ]; then ok "16f. 6th XFF-attributed bad-token attempt (first hop varied again, 10.9.8.12) -> 429 (ip=9.9.9.9 locked on the LAST value, despite 6 different first values)"
else bad "16f. 6th XFF-attributed bad-token attempt -> $rc, expected 429"; fi

# A7: a CORRECT token on an allowed Host is never denied by backoff, even while the
# ip it maps to (9.9.9.9, the trusted last-hop value) is presently locked out.
rc="$(code_of -H "Host: demo.tail1234.ts.net" -H "X-Forwarded-For: 10.9.8.7, 9.9.9.9" "$BASE_T/api/state?$AUTH_T")"
if [ "$rc" = "200" ]; then ok "17. locked XFF ip=9.9.9.9: a GOOD token -> 200 despite the lockout (A7)"
else bad "17. locked XFF ip + good token -> $rc, expected 200 (A7: correct token bypasses backoff)"; fi

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

# A7: the failure path is untouched -- a BAD token on an ip that is still locked must
# still be refused by backoff, on every route. Checked BEFORE any good-token request
# below touches this ip: a successful auth always resets the count (it did before A7
# too), so proving this AFTER 20/21/22 would only be exercising a fresh, already-
# unlocked counter, not the lockout these two are meant to test.
rc="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
      -d '{"text":"x"}' "$BASE_L1/api/send?token=$BADTOK")"
if [ "$rc" = "429" ]; then ok "19g. POST /api/send while locked out, BAD token -> 429 (failure path gated on every route)"
else bad "19g. /api/send bad-token while locked -> $rc, expected 429"; fi

rc="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE_L1/api/events?token=$BADTOK")"
if [ "$rc" = "429" ]; then ok "19h. GET /api/events while locked out, BAD token -> 429 (failure path gated on every route)"
else bad "19h. /api/events bad-token while locked -> $rc, expected 429"; fi

# A7: reversed from the old "lockout blocks everyone" semantics -- a request
# presenting the CORRECT token must NEVER be denied by backoff, since backoff exists
# to slow a guesser, not to lock out the legitimate phone sharing an ip with one.
rc="$(code_of "$BASE_L1/api/state?$AUTH_L1")"
if [ "$rc" = "200" ]; then ok "20. locked out ip, but a VALID token -> 200 (A7: correct token is never denied by backoff)"
else bad "20. locked out + good token -> $rc, expected 200 (A7)"; fi

# A7, same gate on /api/send -- by this point 20's successful auth already reset this
# ip's count (a successful auth always does, so the lockout genuinely is gone now),
# which is exactly why 19g proved the failure path on this same route FIRST: this
# shows the route was never itself what gated it, not that this ip is still locked.
rc="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
      -d '{"text":"x"}' "$BASE_L1/api/send?$AUTH_L1")"
if [ "$rc" = "202" ]; then ok "21. POST /api/send with a good token -> 202 (A7: same gate, every route)"
else bad "21. /api/send with a good token -> $rc, expected 202 (A7)"; fi

rc="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE_L1/api/events?$AUTH_L1")"
if [ "$rc" = "200" ]; then ok "22. GET /api/events with a good token -> 200 (A7: same gate, every route)"
else bad "22. /api/events with a good token -> $rc, expected 200 (A7)"; fi

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

# A7: same bypass as test 20, reached via a different route -- --trust-proxy is OFF
# here, so the real peer (127.0.0.1) is what got locked (XFF was never trusted), but
# a request presenting the CORRECT token is still never denied by that lockout.
rc="$(code_of "$BASE_L2/api/state?$AUTH_L2")"
if [ "$rc" = "200" ]; then ok "24. without --trust-proxy, real peer (127.0.0.1) is locked, but a good token with NO XFF header -> 200 (A7)"
else bad "24. without --trust-proxy, good token should bypass the peer's lockout -> $rc, expected 200 (A7)"; fi

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

# ═══ Group G -- A2: connection/stream caps + pre-auth header-read timeout ═══
launch_server caps || exit 1
PORT_G="$PORT"; BASE_G="$BASE"; AUTH_G="$AUTH"

# Hold MAX_SSE_STREAMS(8) concurrent /api/events connections open; a 9th, while all
# 8 are still held, must be refused with 503 + Retry-After: 5 instead of queued or
# left to hang -- a cap strictly narrower than the server-wide connection cap.
#
# "Held" is CONFIRMED, never assumed. Each held stream dumps its response headers to its
# own file and the 9th is sent only once all 8 show a 200 status line: the server writes
# that line strictly AFTER it has taken a semaphore slot (_serve_events), so a 200 here
# means a slot is genuinely occupied. A fixed sleep cannot stand in for this -- the 8
# curls are separate processes the OS must fork, exec and connect, which under machine
# load takes arbitrarily long for any one of them; a 9th sent while fewer than 8 were up
# was then CORRECTLY admitted (rc=200), failing this check for a reason that was never
# the cap. (A held stream refused at the TCP layer instead is what 27a below pins.)
SSE_PIDS=()
sse_i=1
while [ "$sse_i" -le 8 ]; do
  curl -s -N --max-time 90 -D "$TMPROOT/sse-held-$sse_i.hdr" -o /dev/null "$BASE_G/api/events?$AUTH_G" 2>/dev/null &
  SSE_PIDS+=("$!")
  sse_i=$((sse_i + 1))
done
PIDS+=("${SSE_PIDS[@]}")

sse_live=0
sse_i=1
while [ "$sse_i" -le 8 ]; do
  wait_for "$TMPROOT/sse-held-$sse_i.hdr" '^HTTP/[0-9.]+ 200' 30 && sse_live=$((sse_live + 1))
  sse_i=$((sse_i + 1))
done

HDR9="$TMPROOT/sse-9.hdr"; BODY9="$TMPROOT/sse-9.json"
if [ "$sse_live" -ne 8 ]; then
  bad "27. only $sse_live of 8 held /api/events streams came up (200) within 30s each -- the 9th cannot be measured against a full cap"
else
  # --max-time 8: defensive bound only. A 9th that is wrongly accepted becomes a real
  # 200 SSE stream (infinite by design) instead of the expected 503 -- without a
  # timeout that turns into an indefinite hang instead of a fast, diagnosable "bad".
  rc9="$(curl -s --max-time 8 -D "$HDR9" -o "$BODY9" -w '%{http_code}' "$BASE_G/api/events?$AUTH_G")"
  if [ "$rc9" = "503" ] && grep -qi '^retry-after: *5' "$HDR9" \
     && jq -e '.error=="too-many-streams" and .retry_after_s==5' "$BODY9" >/dev/null 2>&1; then
    ok "27. 9th concurrent /api/events past MAX_SSE_STREAMS(8) -> 503, Retry-After: 5, body {\"error\":\"too-many-streams\",\"retry_after_s\":5}"
  else
    bad "27. 9th concurrent /api/events: rc=$rc9 hdr=$(tr -d '\r' <"$HDR9" 2>/dev/null | grep -i retry-after) body=$(cat "$BODY9" 2>/dev/null)"
  fi
fi

# Kill SSE streams promptly instead of waiting for timeout
for p in "${SSE_PIDS[@]}"; do kill "$p" 2>/dev/null; done
for p in "${SSE_PIDS[@]}"; do wait "$p" 2>/dev/null; done

# A2: the listen backlog must hold a burst as large as MAX_CONNECTIONS. Deterministic, no
# timing: build the real UIServer (bind + listen) but never serve_forever(), so nothing
# ever accept()s, then connect MAX_CONNECTIONS clients back to back -- every connect has to
# complete in the kernel queue. socketserver's default backlog of 5 refuses the 7th or so
# (ECONNREFUSED on macOS, a dropped SYN on Linux): exactly how 8 simultaneous streams lost
# members before any slot was taken. Stops at the first failure so the RED case is quick.
BURST="$(python3 - "$REPO/sentinels/hmd-ui.py" 2>&1 <<'PYEOF'
import importlib.util, socket, sys
spec = importlib.util.spec_from_file_location("hmd_ui_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["hmd_ui_under_test"] = mod
spec.loader.exec_module(mod)
srv = mod.UIServer(0, "burst-probe-token", None)
n, up, socks = mod.MAX_CONNECTIONS, 0, []
try:
    for _ in range(n):
        s = socket.socket()
        s.settimeout(2)
        socks.append(s)
        try:
            s.connect(("127.0.0.1", srv.port))
        except OSError:
            break
        up += 1
finally:
    for s in socks:
        s.close()
    srv.server_close()
print("%d %d" % (up, n))
PYEOF
)"
BURST_UP="${BURST%% *}"; BURST_N="${BURST##* }"
if [ "$BURST_UP" = "$BURST_N" ] && [ "$BURST_N" -gt 0 ] 2>/dev/null; then
  ok "27a. listen backlog queues a burst of MAX_CONNECTIONS($BURST_N) connects before any accept() -- none refused at the TCP layer"
else
  bad "27a. burst of MAX_CONNECTIONS connects before accept(): ${BURST_UP:-?} of ${BURST_N:-?} queued, the rest refused by the kernel (UIServer.request_queue_size too small); probe said: $(printf '%s' "$BURST" | tail -3)"
fi

# A2: a pre-auth connection that sends nothing at all must not park a thread
# forever -- UIHandler.timeout (10s) bounds the header read, so the socket is closed
# by the server itself well inside a generous margin above it. Measured with a raw
# socket that never sends an HTTP request line at all.
IDLE_ELAPSED="$(python3 - "$PORT_G" <<'PYEOF'
import socket, sys, time
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=12)
s.settimeout(12)
start = time.monotonic()
try:
    data = s.recv(1)   # blocks until the server closes it (EOF -> b"") or we time out
except socket.timeout:
    data = None
elapsed = time.monotonic() - start
s.close()
print(elapsed if data == b"" else -1)
PYEOF
)"
if python3 -c "import sys; v=float('$IDLE_ELAPSED'); sys.exit(0 if 0 <= v <= 12 else 1)" 2>/dev/null; then
  ok "28. idle pre-auth connection (no request ever sent) closed by the server within 12s (elapsed=${IDLE_ELAPSED}s) -- slow-loris bound"
else
  bad "28. idle pre-auth connection: elapsed=${IDLE_ELAPSED}s (expected a server-initiated close, 0-12s)"
fi

# ═══ Group H -- A9: public-mode redaction of /api/state (SRV_HOST, --allow-host) ═
# A roster row whose "handle" is email-shaped and whose "project" is an absolute
# path -- exactly the two shapes _scrub_public_string exists to strip -- so 29-31
# exercise the real redaction logic rather than an incidentally-empty roster.
mkdir -p "$FIX/.heimdall"
cat > "$FIX/.heimdall/roster-cache.json" <<'JSON'
[{"haid":"haid:fixture.box-0001","handle":"alice@example.com","branch":"main",
  "project":"/Users/alice/work/fixture-repo","state":"active","verdict":"pass",
  "online":true,"age_seconds":1.0}]
JSON

BODY="$TMPROOT/state-h-public.json"
rc="$(curl -s -o "$BODY" -w '%{http_code}' -H "Host: demo.tail1234.ts.net" "$BASE_H/api/state?$AUTH_H")"
REPO_PUB="$(jq -r '.repo // empty' "$BODY" 2>/dev/null)"
if [ "$rc" = "200" ] && [ -n "$REPO_PUB" ] && ! printf '%s' "$REPO_PUB" | grep -q '/'; then
  ok "29. public mode (--allow-host): /api/state.repo is a basename, no '/' (repo=$REPO_PUB) (A9)"
else
  bad "29. public mode .repo: rc=$rc repo=$REPO_PUB"
fi

ROSTER_PUB="$(jq -c '.roster' "$BODY" 2>/dev/null)"
if [ "$rc" = "200" ] && ! printf '%s' "$ROSTER_PUB" | grep -q '@'; then
  ok "30. public mode (--allow-host): no '@' appears anywhere in /api/state.roster (roster=$ROSTER_PUB) (A9)"
else
  bad "30. public mode .roster: rc=$rc roster=$ROSTER_PUB"
fi

EDITS_PUB="$(jq -r '.edits.paths[]? // empty' "$BODY" 2>/dev/null)"
if [ "$rc" = "200" ] && ! printf '%s\n' "$EDITS_PUB" | grep -q '^/'; then
  ok "31. public mode (--allow-host): /api/state.edits.paths has no leading '/' entries (A9)"
else
  bad "31. public mode .edits.paths: rc=$rc paths=$(jq -c '.edits.paths' "$BODY" 2>/dev/null)"
fi

# Loopback (no --allow-host) must be byte-for-byte unaffected by A9 -- SRV_NOHOST's
# own repo is the real, absolute $FIX path and its roster keeps its '@' verbatim.
BODY="$TMPROOT/state-n-loopback.json"
rc="$(curl -s -o "$BODY" -w '%{http_code}' "$BASE_N/api/state?$AUTH_N")"
if [ "$rc" = "200" ] && [ "$(jq -r '.repo' "$BODY" 2>/dev/null)" = "$FIX_REAL" ]; then
  ok "32. loopback (no --allow-host): /api/state.repo is still the full absolute path, unredacted (A9 is gated on public_host)"
else
  bad "32. loopback .repo should be unredacted: rc=$rc repo=$(jq -r '.repo' "$BODY" 2>/dev/null), expected $FIX_REAL"
fi

if [ "$rc" = "200" ] && jq -r '.roster[0].handle // empty' "$BODY" 2>/dev/null | grep -q '@'; then
  ok "33. loopback (no --allow-host): /api/state.roster is still unredacted (handle keeps its '@') (A9 is gated on public_host)"
else
  bad "33. loopback roster should be unredacted: rc=$rc roster=$(jq -c '.roster' "$BODY" 2>/dev/null)"
fi

# ═══ Group I -- N4: recursion covers EVERY string leaf, not a 4-key allowlist ══
# Before N4, _redact_state_for_public only ever touched repo/edits.paths/roster/
# ledger.team -- panels, checkpoint, sweep_receipt, identity.handle and every
# other string-valued field reached a --allow-host listener unscrubbed. 34-40
# publish a panel whose TITLE is nothing but an absolute path and whose kv data
# carries an email plus a ~/-relative path, and a CHECKPOINT.md whose Branch
# field is an absolute path while its Open warnings field EMBEDS one mid-
# sentence -- proving a path token is stripped wherever it sits, not only when
# the whole value is nothing but a path. Shares $FIX with every server above, so
# the same fixture is read by both the public (SRV_HOST) and loopback (SRV_
# NOHOST) servers already running.
DATA_JSON="$TMPROOT/panel-secret-data.json"
cat > "$DATA_JSON" <<'JSON'
{"rows":[["contact","someone@example.com"],["home","~/private-notes"]]}
JSON
# N4 CLI-usage note: `panel set` has no --repo of its OWN (only the top-level
# `panel` command does, and only BEFORE the subcommand -- see PLAN L450-452 /
# heimdall-ui-panels.test.sh:45); passing --repo AFTER `set ...` lands in the
# "set" subparser, which doesn't recognize it, so argparse exits 2 with
# "unrecognized arguments" -- silently, under this line's own 2>&1. HEIMDALL_
# WATCH_ROOT (same env var launch_server already sets for the server itself)
# is the established pattern every other test in heimdall-ui-panels.test.sh uses.
HEIMDALL_WATCH_ROOT="$FIX" "$UI" panel set secret-panel --type kv --title "/Users/rj/secret/project" \
      --data-json "$DATA_JSON" >/dev/null 2>&1

mkdir -p "$FIX/.planning"
cat > "$FIX/.planning/CHECKPOINT.md" <<'MD'
<!-- heimdall-auto-checkpoint:begin -->
## Auto-checkpoint — 2026-09-21T00:00:00Z

> Written automatically at session end (mechanical, no LLM).

- **Branch:** /Users/rj/secret/branch-info
- **HEAD:** f1x7u4e0
- **Phase:** fixture-phase
- **Active goal:** none
- **Uncommitted files:** 2
- **Open warnings:** push gate blocked by /Users/rj/secret/dirty-file

### What must never be lost (the resume contract)
- **In progress:** none
<!-- heimdall-auto-checkpoint:end -->
MD

# Panel files are picked up by /api/state's OWN fresh collect_state() call (no
# poll-interval staleness there -- see sentinels/hmd-ui.py's "/api/state" route,
# "Always a FRESH collection"), but polling instead of a single shot costs
# nothing on the fast path and removes any dependency on exactly how fast the
# CLI process above has exited and flushed its rename(2) before this line runs.
# Deadline 6s, 0.2s steps (matches wait_for()'s cadence elsewhere in this file).
BODY="$TMPROOT/state-i-public.json"
POLL_I=0
while [ "$POLL_I" -lt 30 ]; do
  rc="$(curl -s -o "$BODY" -w '%{http_code}' -H "Host: demo.tail1234.ts.net" "$BASE_H/api/state?$AUTH_H")"
  if [ "$rc" = "200" ] && grep -q '"secret-panel"' "$BODY" 2>/dev/null; then
    break
  fi
  sleep 0.2; POLL_I=$((POLL_I + 1))
done
RAW="$(cat "$BODY" 2>/dev/null)"

if [ "$rc" = "200" ] && ! printf '%s' "$RAW" | grep -q '/Users/'; then
  ok "34. public mode: /api/state has NO '/Users/' substring anywhere in the whole body (N4: recursive, not a 4-key allowlist)"
else
  bad "34. public mode: '/Users/' still present somewhere in /api/state body: rc=$rc"
fi

if [ "$rc" = "200" ] && ! printf '%s' "$RAW" | grep -q '@example.com'; then
  ok "35. public mode: /api/state has NO '@example.com' substring anywhere in the whole body (N4)"
else
  bad "35. public mode: '@example.com' still present somewhere in /api/state body: rc=$rc"
fi

TITLE_PUB="$(jq -r '.panels[]? | select(.id=="secret-panel") | .title' "$BODY" 2>/dev/null)"
if [ "$rc" = "200" ] && [ "$TITLE_PUB" = "project" ]; then
  ok "36. public mode: panel title '/Users/rj/secret/project' -> 'project' (N4: panels were never one of the old 4 keys)"
else
  bad "36. public mode: panel title -> '$TITLE_PUB', expected 'project'"
fi

HOME_PUB="$(jq -r '.panels[]? | select(.id=="secret-panel") | .data.rows[]? | select(.[0]=="home") | .[1]' "$BODY" 2>/dev/null)"
if [ "$rc" = "200" ] && [ "$HOME_PUB" = "private-notes" ]; then
  ok "37. public mode: panel kv value '~/private-notes' -> 'private-notes' (N4: ~/ token, not just os.path.isabs)"
else
  bad "37. public mode: panel kv 'home' value -> '$HOME_PUB', expected 'private-notes'"
fi

BRANCH_PUB="$(jq -r '.checkpoint.branch // empty' "$BODY" 2>/dev/null)"
if [ "$rc" = "200" ] && [ "$BRANCH_PUB" = "branch-info" ]; then
  ok "38. public mode: checkpoint.branch (absolute path) -> basename 'branch-info' (N4: checkpoint was never one of the old 4 keys)"
else
  bad "38. public mode: checkpoint.branch -> '$BRANCH_PUB', expected 'branch-info'"
fi

WARN_PUB="$(jq -r '.checkpoint.push_gate_open_warning // empty' "$BODY" 2>/dev/null)"
if [ "$rc" = "200" ] && printf '%s' "$WARN_PUB" | grep -q 'push gate' \
   && printf '%s' "$WARN_PUB" | grep -q 'dirty-file' \
   && ! printf '%s' "$WARN_PUB" | grep -q '/Users/'; then
  ok "39. public mode: checkpoint.push_gate_open_warning keeps its prose, embedded path token -> basename ('$WARN_PUB')"
else
  bad "39. public mode: checkpoint.push_gate_open_warning -> '$WARN_PUB'"
fi

# /api/events' first frame is built from the exact same collect_state() call as
# /api/state (StateCache.refresh() redacts before digest_of()) -- 40 proves that
# in practice, not just by reading the code. Checked via the panel's OWN title
# field (jq), not a bare `grep -q '"project"'`: Group H's roster fixture already
# puts a literal `"project"` JSON KEY on the wire unredacted (N4 never touches
# keys), so a substring grep would pass even if this panel never arrived.
SSE_OUT="$TMPROOT/sse-public.out"
curl -s -N --max-time 2 -H "Host: demo.tail1234.ts.net" "$BASE_H/api/events?$AUTH_H" -o "$SSE_OUT" 2>/dev/null
SSE_JSON="$(grep '^data: ' "$SSE_OUT" 2>/dev/null | head -1 | sed 's/^data: //')"
SSE_TITLE="$(printf '%s' "$SSE_JSON" | jq -r '.panels[]? | select(.id=="secret-panel") | .title' 2>/dev/null)"
if [ -n "$SSE_JSON" ] && [ "$SSE_TITLE" = "project" ] \
   && ! printf '%s' "$SSE_JSON" | grep -q '/Users/' && ! printf '%s' "$SSE_JSON" | grep -q '@example.com'; then
  ok "40. public mode: /api/events first frame is equally redacted (same source as /api/state) (N4)"
else
  bad "40. public mode: /api/events frame not redacted as expected (panel title in frame: '$SSE_TITLE')"; sed 's/^/       | /' "$SSE_OUT" 2>/dev/null | head -5
fi

# Loopback (no --allow-host), SAME underlying panel+checkpoint fixtures (shared
# $FIX): N4 must never fire when transport.public_host is unset.
BODY="$TMPROOT/state-i-loopback.json"
rc="$(curl -s -o "$BODY" -w '%{http_code}' "$BASE_N/api/state?$AUTH_N")"
TITLE_LOOP="$(jq -r '.panels[]? | select(.id=="secret-panel") | .title' "$BODY" 2>/dev/null)"
BRANCH_LOOP="$(jq -r '.checkpoint.branch // empty' "$BODY" 2>/dev/null)"
if [ "$rc" = "200" ] && [ "$TITLE_LOOP" = "/Users/rj/secret/project" ] \
   && [ "$BRANCH_LOOP" = "/Users/rj/secret/branch-info" ]; then
  ok "41. loopback (no --allow-host): panel title and checkpoint.branch stay full absolute paths, unredacted (N4 gated on public_host)"
else
  bad "41. loopback should be unredacted: title=$TITLE_LOOP branch=$BRANCH_LOOP"
fi

# ═══ Group J -- collect_fallback's own bounded timeout (product-side fix) ══════
# _run() (sentinels/hmd-ui.py) resolves every SOURCE_COMMANDS binary, including
# heimdall-fallback, against hmd-ui's OWN bin/ -- never PATH (see _run's docstring:
# "the target repo's PATH never decides which hmd tool answers") -- so the only way
# to substitute a stub heimdall-fallback is a sandboxed copy of bin/+sentinels/ with
# heimdall-fallback swapped out. bin/heimdall-ui itself must be a real file COPY, not
# a symlink: its own launcher resolves its location via `readlink -f "$0"`, which
# would resolve a symlink straight back to this repo's real bin/, defeating the
# sandbox. sentinels/*.py and bin/lib/ CAN be symlinked -- __file__ (Python) and
# module imports are never realpath()'d the way that bash launcher resolves itself.
SANDBOX="$TMPROOT/sandbox"
mkdir -p "$SANDBOX/bin" "$SANDBOX/sentinels"
for f in "$REPO"/bin/*; do
  name="$(basename "$f")"
  case "$name" in
    heimdall-ui|heimdall-fallback) continue ;;
  esac
  ln -s "$f" "$SANDBOX/bin/$name"
done
cp "$REPO/bin/heimdall-ui" "$SANDBOX/bin/heimdall-ui"
chmod +x "$SANDBOX/bin/heimdall-ui"
for f in "$REPO"/sentinels/*; do
  ln -s "$f" "$SANDBOX/sentinels/$(basename "$f")"
done
cat > "$SANDBOX/bin/heimdall-fallback" <<'STUB'
#!/usr/bin/env bash
# Wedged heimdall-fallback double for test 42 -- `exec` replaces this shell with
# `sleep` (same PID) so a SIGKILL from the caller's own subprocess timeout ends the
# sleep directly, leaving no orphaned grandchild behind.
exec sleep 30
STUB
chmod +x "$SANDBOX/bin/heimdall-fallback"

REAL_UI="$UI"
UI="$SANDBOX/bin/heimdall-ui"
launch_server hungfallback || exit 1
UI="$REAL_UI"
BASE_HF="$BASE"; AUTH_HF="$AUTH"

SECONDS=0
BODY="$TMPROOT/state-hf.json"
rc="$(curl -s -m 10 -o "$BODY" -w '%{http_code}' "$BASE_HF/api/state?$AUTH_HF")"
ELAPSED="$SECONDS"

if [ "$rc" = "200" ] && [ "$ELAPSED" -le 6 ] \
   && jq -e '.fallback.state == null and .fallback.target_provider == null
             and .fallback.status == "unknown" and .fallback.reason == "timeout"' "$BODY" >/dev/null 2>&1; then
  ok "42. wedged heimdall-fallback (stub sleeps 30s): /api/state answers in ${ELAPSED}s with fallback={state:null,target_provider:null,status:unknown,reason:timeout} -- never blocks on it (product fix: FALLBACK_CMD_TIMEOUT_S)"
else
  bad "42. wedged heimdall-fallback: rc=$rc elapsed=${ELAPSED}s fallback=$(jq -c '.fallback' "$BODY" 2>/dev/null)"
fi

# ═══ Group K -- A5: the E2E relay's repo-relative profile is NOT reachable over HTTP ═══
# test/heimdall-ui-relay-paths.test.sh proves the relay profile itself. bin/heimdall-relay-client
# builds its OWN transport ({"bind":"relay",...}) in-process; THIS server's transport is built
# from argv alone, so nothing a caller sends -- query, header, Host -- can select that profile,
# and nothing can switch the public profile off. The probe is a string leaf holding an absolute
# path BELOW the served repo (the checkpoint's open-warning text): the relay profile would keep
# "src/app/x.ts", the public profile keeps only "x.ts". Overwrites the Group I checkpoint
# fixture -- every assertion that read it has already run.
cat > "$FIX/.planning/CHECKPOINT.md" <<MD
<!-- heimdall-auto-checkpoint:begin -->
## Auto-checkpoint — 2026-10-01T00:00:00Z

- **Branch:** main
- **HEAD:** a5a5a5a5
- **Phase:** fixture-phase
- **Uncommitted files:** 1
- **Open warnings:** push gate blocked by $FIX_REAL/src/app/x.ts

### What must never be lost (the resume contract)
- **In progress:** none
<!-- heimdall-auto-checkpoint:end -->
MD

KN=0
# k_attempt LABEL HOST-HEADER QUERY-SUFFIX [extra curl args...] -- against the PUBLIC server.
k_attempt() {
  local label="$1" host="$2" qs="$3" f="$TMPROOT/state-k.json" code warn handle
  shift 3
  KN=$((KN + 1))
  code="$(curl -s -o "$f" -w '%{http_code}' -H "Host: $host" "$@" "$BASE_H/api/state?$AUTH_H$qs")"
  warn="$(jq -r '.checkpoint.push_gate_open_warning // empty' "$f" 2>/dev/null)"
  handle="$(jq -r '.roster[0].handle // empty' "$f" 2>/dev/null)"
  if [ "$code" = "200" ] && [ "$warn" = "push gate blocked by x.ts" ] && [ "$handle" = "[email]" ] \
     && jq -e '.transport.bind == "loopback" and .transport.public_host == "demo.tail1234.ts.net"' "$f" >/dev/null 2>&1; then
    ok "K$KN. $label -> public profile unchanged (basename 'x.ts', email scrubbed, transport still loopback + public_host)"
  else
    bad "K$KN. $label -> rc=$code warning='$warn' handle='$handle' transport=$(jq -c '.transport' "$f" 2>/dev/null) (a caller must not select the relay profile nor switch redaction off)"
  fi
}
k_attempt "plain Funnel request" demo.tail1234.ts.net ""
k_attempt "?transport=relay" demo.tail1234.ts.net "&transport=relay"
k_attempt "?bind=relay&profile=relay&relay=1" demo.tail1234.ts.net "&bind=relay&profile=relay&relay=1"
k_attempt "?redact=0&public=0" demo.tail1234.ts.net "&redact=0&public=0"
k_attempt "X-Hmd-Transport / X-Heimdall-Transport / X-Transport: relay" demo.tail1234.ts.net "" \
  -H "X-Hmd-Transport: relay" -H "X-Heimdall-Transport: relay" -H "X-Transport: relay"
k_attempt "X-Forwarded-For: 127.0.0.1" demo.tail1234.ts.net "" -H "X-Forwarded-For: 127.0.0.1"
k_attempt "Host: 127.0.0.1:<port> (a loopback origin presented to a public server)" "127.0.0.1:$PORT_H" ""

SSE_K="$TMPROOT/sse-k.out"
curl -s -N --max-time 2 -H "Host: demo.tail1234.ts.net" -H "X-Hmd-Transport: relay" \
  "$BASE_H/api/events?$AUTH_H&transport=relay" -o "$SSE_K" 2>/dev/null
SSE_K_WARN="$(grep '^data: ' "$SSE_K" 2>/dev/null | head -1 | sed 's/^data: //' | jq -r '.checkpoint.push_gate_open_warning // empty' 2>/dev/null)"
if [ "$SSE_K_WARN" = "push gate blocked by x.ts" ]; then
  ok "K$((KN + 1)). /api/events frame with the same opt-in attempts -> public profile unchanged ('x.ts')"
else
  bad "K$((KN + 1)). /api/events frame with opt-in attempts -> warning='$SSE_K_WARN', expected 'push gate blocked by x.ts'"
fi

BODY="$TMPROOT/state-k-loopback.json"
rc="$(curl -s -o "$BODY" -w '%{http_code}' "$BASE_N/api/state?$AUTH_N")"
if [ "$rc" = "200" ] \
   && [ "$(jq -r '.checkpoint.push_gate_open_warning // empty' "$BODY" 2>/dev/null)" = "push gate blocked by $FIX_REAL/src/app/x.ts" ] \
   && [ "$(jq -r '.roster[0].handle // empty' "$BODY" 2>/dev/null)" = "alice@example.com" ]; then
  ok "K$((KN + 2)). loopback server (no --allow-host): the same fixture stays fully unredacted -- neither profile applies"
else
  bad "K$((KN + 2)). loopback server should be unredacted: rc=$rc warning=$(jq -r '.checkpoint.push_gate_open_warning' "$BODY" 2>/dev/null) handle=$(jq -r '.roster[0].handle' "$BODY" 2>/dev/null)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

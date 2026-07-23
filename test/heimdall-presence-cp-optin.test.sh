#!/usr/bin/env bash
# heimdall-presence-cp-optin.test.sh — CONTROL-PLANE OPT-IN (fail-safe DEFAULT OFF).
#
# Pointing presence at the LIVE public control plane is now behind a ONE-TIME, persisted
# opt-in. This suite gates that gate — every ON assertion paired with the OFF assertion that
# would flip if the guard were removed:
#
#   1. PERSISTENCE — connect writes {decision:connected,url}; disconnect writes
#      {decision:declined}; cp-status reflects each. (~/.heimdall/cp-consent.json, 0600.)
#   2. FAIL-SAFE DEFAULT OFF — UNDECIDED + no url override => a beat is a stat-only no-op
#      (NO enroll-attempt stamp: it never reaches the network/bootstrap) and roster is empty.
#   3. OPT-IN AUTO-CONNECTS NEXT SESSION — after connect, a FRESH beat with NO url flag/env
#      resolves the persisted url and POSTs to it (wire-observed on a recording server).
#   4. OPT-OUT NEVER RE-PROMPTS — after disconnect, connect-prompt (even forced) is silent and
#      leaves the decision untouched; a beat stays a no-op.
#   5. UNDECIDED + NON-INTERACTIVE — connect-prompt prints ONE throttled hint, persists NOTHING
#      (undecided stays undecided), never blocks. A second call is throttled (silent).
#   6. UNDECIDED + INTERACTIVE (forced) — [y/N] routes: y => connect (persists the canonical
#      default url); n => decline.
#   7. EXPLICIT OVERRIDE — an undecided dev with $HEIMDALL_CP_URL set is NOT prompted (already
#      connected) and connect-prompt persists nothing.
#   8. SINGLE SOURCE OF TRUTH — the canonical CP URL literal appears in EXACTLY ONE file in bin/.
#
# Hermetic: throwaway HOME + repo dirs; the wire server is localhost-only; no real GCP/network.
# Exit 0 = every proof holds.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="$REPO/bin/heimdall-presence"
LIB="$REPO/bin/lib"
CONSENT_LIB="$LIB/cp-consent.sh"
export LIB REPO

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing/not executable" >&2; exit 2; }
[ -f "$CONSENT_LIB" ] || { echo "FATAL: $CONSENT_LIB missing" >&2; exit 2; }

# The canonical URL, read from the single source of truth (never re-typed here).
CANONICAL_URL="$(. "$CONSENT_LIB"; printf '%s' "$HEIMDALL_DEFAULT_CP_URL")"
[ -n "$CANONICAL_URL" ] || { echo "FATAL: HEIMDALL_DEFAULT_CP_URL empty in $CONSENT_LIB" >&2; exit 2; }

# Ed25519 backend present? The enroll-attempt-stamp falsifier (sections 2-4) needs it — keygen
# runs BEFORE the stamp is written, so a missing backend would make ON and OFF both stampless.
CRYPTO="$(LIB="$LIB" "$PY" - <<'PYEOF' 2>/dev/null
import os,sys; sys.path.insert(0,os.environ["LIB"])
try:
    import cp_auth as K; sys.stdout.write("1" if K.crypto_available() else "0")
except Exception: sys.stdout.write("0")
PYEOF
)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMP="$(mktemp -d -t hmd-cpoptin)"
cleanup() { [ -n "${WIRE_PID:-}" ] && kill "$WIRE_PID" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# 1. PERSISTENCE — connect / disconnect / cp-status
# ══════════════════════════════════════════════════════════════════════════════
echo "1. connect/disconnect/cp-status persist + read back the durable decision"
H1="$TMP/home1"; mkdir -p "$H1"
CONSENT="$H1/.heimdall/cp-consent.json"
# HMD_CP_CONNECT_NO_BEAT: assert persistence without a live network beat.
p1() { HOME="$H1" HMD_HAID="haid:c1" HMD_CP_CONNECT_NO_BEAT=1 "$BIN" "$@"; }

p1 connect --url "http://127.0.0.1:1" >/dev/null 2>&1
if [ -f "$CONSENT" ] && grep -q '"decision": "connected"' "$CONSENT" && grep -q '127.0.0.1:1' "$CONSENT"; then
  ok "1a connect -> cp-consent.json {decision:connected, url} (persisted for next session)"
else
  bad "1a connect did not persist {connected,url} -- $(cat "$CONSENT" 2>/dev/null)"
fi

# 0600 perms (a per-user decision, not world-readable)
PERM="$(stat -f '%Lp' "$CONSENT" 2>/dev/null || stat -c '%a' "$CONSENT" 2>/dev/null || echo '?')"
[ "$PERM" = "600" ] && ok "1b cp-consent.json is mode 0600" || bad "1b cp-consent.json perms not 600 (got $PERM)"

CPS="$(p1 cp-status 2>/dev/null)"
if printf '%s' "$CPS" | grep -q "decision:  connected" && printf '%s' "$CPS" | grep -q "127.0.0.1:1"; then
  ok "1c cp-status shows connected + the resolved url"
else
  bad "1c cp-status wrong while connected -- $CPS"
fi

p1 disconnect >/dev/null 2>&1
if grep -q '"decision": "declined"' "$CONSENT"; then
  ok "1d disconnect -> {decision:declined} (persisted opt-out)"
else
  bad "1d disconnect did not persist declined -- $(cat "$CONSENT" 2>/dev/null)"
fi

CPS2="$(p1 cp-status 2>/dev/null)"
if printf '%s' "$CPS2" | grep -q "decision:  declined" && printf '%s' "$CPS2" | grep -qi "LOCAL/offline"; then
  ok "1e cp-status shows declined + LOCAL/offline (not contacting the control plane)"
else
  bad "1e cp-status wrong while declined -- $CPS2"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. FAIL-SAFE DEFAULT OFF — undecided beat never reaches the network
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "2. undecided + no override => a beat is a stat-only no-op (fail-safe DEFAULT OFF)"
H2="$TMP/home2"; R2="$TMP/repo2"; mkdir -p "$H2" "$R2"
# NO cp-consent.json, NO HEIMDALL_CP_URL, NO --url: the gate must yield NO url -> beat no-op.
beat2() { env -u HEIMDALL_CP_URL -u BASE_URL HOME="$H2" HEIMDALL_PRESENCE_DIR="$R2/.heimdall" \
          HMD_ENROLL_THROTTLE=0 HMD_HAID="haid:t2" HMD_PROJECT="acme/widget" "$BIN" beat; }

if [ "$CRYPTO" = "1" ]; then
  rm -rf "$H2/.heimdall/pki"
  BR=0; beat2 >/dev/null 2>&1 || BR=$?
  if ! ls "$H2"/.heimdall/pki/*.enroll-attempt >/dev/null 2>&1 && [ "$BR" -eq 0 ]; then
    ok "2a UNDECIDED beat: exit 0, NO enroll-attempt stamp -- never phoned home (gate off)"
  else
    bad "2a UNDECIDED beat leaked to bootstrap (stamp present) or non-zero exit ($BR) -- FAIL-SAFE BROKEN"
  fi
else
  ok "2a (skipped: no Ed25519 backend — enroll-attempt falsifier needs crypto)"
fi

# roster degrades to an empty wall (exit 0), even undecided.
RO="$(env -u HEIMDALL_CP_URL HOME="$H2" HEIMDALL_PRESENCE_DIR="$R2/.heimdall" HMD_HAID="haid:t2" \
      HMD_PROJECT="acme/widget" "$BIN" roster 2>/dev/null)"; RR=$?
if [ "$RR" -eq 0 ] && printf '%s' "$RO" | grep -q "no teammates online"; then
  ok "2b UNDECIDED roster: clean empty wall, exit 0 (offline is normal, not an error)"
else
  bad "2b UNDECIDED roster did not degrade cleanly (rc=$RR) -- $RO"
fi

# cp-status names the fail-safe
CPS3="$(env -u HEIMDALL_CP_URL HOME="$H2" HMD_HAID="haid:t2" "$BIN" cp-status 2>/dev/null)"
if printf '%s' "$CPS3" | grep -q "decision:  undecided" && printf '%s' "$CPS3" | grep -qi "default off"; then
  ok "2c cp-status (undecided) says default OFF"
else
  bad "2c cp-status undecided did not say default off -- $CPS3"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. OPT-IN AUTO-CONNECTS NEXT SESSION — wire-observed on a recording server
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "3. after connect, a FRESH beat with NO url resolves the persisted url + POSTs to it"
if [ "$CRYPTO" != "1" ]; then
  ok "3* (skipped: no Ed25519 backend — the wire beat cannot sign)"
else
  REC="$TMP/rec"; mkdir -p "$REC"
  cat >"$TMP/recsrv.py" <<'PYEOF'
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
REC = os.environ["REC_DIR"]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): return
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        raw = self._body(); p = self.path.split("?")[0]
        if p == "/enroll": return self._send(200, {"enrolled": True})
        if p == "/presence":
            with open(os.path.join(REC,"presence.jsonl"),"ab") as fh: fh.write(raw+b"\n")
            return self._send(200, {"recorded": True})
        return self._send(404, {"error":"nf"})
    def do_GET(self):
        if self.path.split("?")[0] == "/roster": return self._send(200, {"roster": []})
        return self._send(404, {"error":"nf"})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(REC,"port"),"w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
  REC_DIR="$REC" "$PY" "$TMP/recsrv.py" &
  WIRE_PID=$!
  for _ in $(seq 1 40); do [ -s "$REC/port" ] && break; "$PY" -c "import time;time.sleep(0.1)"; done
  PORT="$(cat "$REC/port" 2>/dev/null || true)"
  H3="$TMP/home3"; R3="$TMP/repo3"; mkdir -p "$H3" "$R3"
  if [ -z "$PORT" ]; then
    bad "3* recording server never bound a port"
  else
    # SESSION A: connect (persist the recording url). No beat here (NO_BEAT) — prove it is the
    # NEXT session's beat that auto-resolves the url, not this connect.
    env -u HEIMDALL_CP_URL HOME="$H3" HEIMDALL_PRESENCE_DIR="$R3/.heimdall" HMD_HAID="haid:t3" \
      HMD_CP_CONNECT_NO_BEAT=1 "$BIN" connect --url "http://127.0.0.1:$PORT" >/dev/null 2>&1
    : > "$REC/presence.jsonl"
    # SESSION B: a bare beat, NO --url, NO env url — the consent gate must supply the url.
    env -u HEIMDALL_CP_URL -u BASE_URL HOME="$H3" HEIMDALL_PRESENCE_DIR="$R3/.heimdall" \
      HMD_ENROLL_THROTTLE=0 HMD_HAID="haid:t3" HMD_PROJECT="acme/widget" \
      "$BIN" beat --handle t3 --verdict building --file src/app.py >/dev/null 2>&1
    if [ -s "$REC/presence.jsonl" ]; then
      ok "3a next-session bare beat auto-resolved the persisted url + POSTed /presence (auto-connect)"
    else
      bad "3a next-session bare beat did NOT reach the persisted url -- opt-in did not auto-set the url"
    fi
  fi
  kill "$WIRE_PID" >/dev/null 2>&1 || true; wait "$WIRE_PID" 2>/dev/null || true; WIRE_PID=""
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. OPT-OUT NEVER RE-PROMPTS
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "4. after disconnect: connect-prompt is silent + a beat stays a no-op (never nag)"
H4="$TMP/home4"; R4="$TMP/repo4"; mkdir -p "$H4" "$R4"
env -u HEIMDALL_CP_URL HOME="$H4" HMD_HAID="haid:t4" "$BIN" disconnect >/dev/null 2>&1
# forced-interactive prompt MUST NOT fire once a decision exists.
PR="$(env -u HEIMDALL_CP_URL HOME="$H4" HMD_HAID="haid:t4" HMD_CP_PROMPT_FORCE=1 \
      "$BIN" connect-prompt </dev/null 2>&1)"; PRC=$?
if [ "$PRC" -eq 0 ] && [ -z "$PR" ] && grep -q '"decision": "declined"' "$H4/.heimdall/cp-consent.json"; then
  ok "4a declined: connect-prompt (even forced) is SILENT + leaves the decision declined (no re-prompt)"
else
  bad "4a declined dev was re-prompted or decision mutated (rc=$PRC out='$PR')"
fi
if [ "$CRYPTO" = "1" ]; then
  rm -rf "$H4/.heimdall/pki"
  env -u HEIMDALL_CP_URL -u BASE_URL HOME="$H4" HEIMDALL_PRESENCE_DIR="$R4/.heimdall" \
    HMD_ENROLL_THROTTLE=0 HMD_HAID="haid:t4" HMD_PROJECT="acme/widget" "$BIN" beat >/dev/null 2>&1
  ! ls "$H4"/.heimdall/pki/*.enroll-attempt >/dev/null 2>&1 \
    && ok "4b declined beat: NO enroll-attempt stamp (still local-only after opt-out)" \
    || bad "4b declined dev still beat to the network -- opt-out not enforced"
else
  ok "4b (skipped: no Ed25519 backend)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. UNDECIDED + NON-INTERACTIVE — one throttled hint, persist nothing, never block
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "5. undecided + non-interactive: one throttled hint, no persist, no block"
H5="$TMP/home5"; mkdir -p "$H5"
prompt5() { env -u HEIMDALL_CP_URL HOME="$H5" HMD_HAID="haid:t5" "$BIN" connect-prompt </dev/null; }
OUT5A="$(prompt5 2>/dev/null)"; RC5A=$?
if [ "$RC5A" -eq 0 ] && printf '%s' "$OUT5A" | grep -q "hmd presence connect" \
   && [ ! -f "$H5/.heimdall/cp-consent.json" ]; then
  ok "5a first call: prints the opt-in HINT, exit 0, persists NOTHING (undecided stays undecided)"
else
  bad "5a non-interactive hint wrong (rc=$RC5A persisted=$([ -f "$H5/.heimdall/cp-consent.json" ] && echo yes || echo no)) -- $OUT5A"
fi
OUT5B="$(prompt5 2>/dev/null)"
if [ -z "$OUT5B" ]; then
  ok "5b second call is THROTTLED (silent) -- a per-session hook never nags"
else
  bad "5b hint was not throttled (re-printed) -- $OUT5B"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. UNDECIDED + INTERACTIVE (forced) — [y/N] routes both ways
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "6. undecided + interactive (forced): y => connect (canonical url); n => decline"
H6Y="$TMP/home6y"; mkdir -p "$H6Y"
printf 'y\n' | env -u HEIMDALL_CP_URL HOME="$H6Y" HMD_HAID="haid:t6" HMD_CP_PROMPT_FORCE=1 \
  HMD_CP_CONNECT_NO_BEAT=1 "$BIN" connect-prompt >/dev/null 2>&1
C6Y="$H6Y/.heimdall/cp-consent.json"
if grep -q '"decision": "connected"' "$C6Y" 2>/dev/null && grep -qF "$CANONICAL_URL" "$C6Y" 2>/dev/null; then
  ok "6a 'y' -> connect persists {connected} with the CANONICAL default url (single source of truth)"
else
  bad "6a 'y' did not connect with the canonical url -- $(cat "$C6Y" 2>/dev/null)"
fi
H6N="$TMP/home6n"; mkdir -p "$H6N"
printf 'n\n' | env -u HEIMDALL_CP_URL HOME="$H6N" HMD_HAID="haid:t6" HMD_CP_PROMPT_FORCE=1 \
  "$BIN" connect-prompt >/dev/null 2>&1
if grep -q '"decision": "declined"' "$H6N/.heimdall/cp-consent.json" 2>/dev/null; then
  ok "6b 'n' -> persists {declined} (default no — never online-by-default)"
else
  bad "6b 'n' did not persist declined -- $(cat "$H6N/.heimdall/cp-consent.json" 2>/dev/null)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7. EXPLICIT OVERRIDE — an env url is consent; not prompted, not persisted
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "7. explicit \$HEIMDALL_CP_URL override: connect-prompt is silent, persists nothing"
H7="$TMP/home7"; mkdir -p "$H7"
OUT7="$(HOME="$H7" HEIMDALL_CP_URL="http://127.0.0.1:1" HMD_HAID="haid:t7" HMD_CP_PROMPT_FORCE=1 \
        "$BIN" connect-prompt </dev/null 2>&1)"; RC7=$?
if [ "$RC7" -eq 0 ] && [ -z "$OUT7" ] && [ ! -f "$H7/.heimdall/cp-consent.json" ]; then
  ok "7a env-url dev is NOT prompted (already connected) + no consent file written (override IS consent)"
else
  bad "7a env-url dev was prompted or a consent file appeared (rc=$RC7 out='$OUT7')"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 8. SINGLE SOURCE OF TRUTH — the canonical literal lives in exactly one bin/ file
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "8. the canonical CP URL literal is not duplicated across bin/"
N="$(grep -rlF "$CANONICAL_URL" "$REPO/bin" 2>/dev/null | wc -l | tr -d ' ')"
ONLY="$(grep -rlF "$CANONICAL_URL" "$REPO/bin" 2>/dev/null)"
if [ "$N" = "1" ] && [ "$ONLY" = "$CONSENT_LIB" ]; then
  ok "8a the literal appears in EXACTLY ONE bin/ file: bin/lib/cp-consent.sh (single source of truth)"
else
  bad "8a the canonical url is duplicated across bin/ (count=$N):
$ONLY"
fi

echo
echo "============================================================"
printf "heimdall-presence-cp-optin: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

#!/usr/bin/env bash
# test/dashboard-login.test.sh — the local side of the Option-B device-flow
# dashboard login (bin/heimdall-dashboard `login <device_code>`).
#
# WHAT THIS GATES. `hmd dashboard login <device_code>` must:
#   1. Resolve the enrolled HAID + its 0600 signing seed; refuse cleanly when not enrolled.
#   2. Read the GitHub username from `gh api user --jq .login`; refuse cleanly when gh is
#      missing / not authenticated (never sign, never POST).
#   3. Build the EXACT canonical assertion cp_session.assertion_message() builds
#      ("heimdall-dashboard-login-v1\n<haid>\n<gh_user>\n<device_code>\n<nonce>"),
#      sign it with the enrolled Ed25519 HAID seed (the SAME primitive cp_auth.sign uses),
#      and POST {haid, gh_user, device_code, nonce, sig} to /dashboard/session/approve.
#   4. Print the success line on 200; a clear rejection on 401.
#   5. Use a FRESH random nonce every run (unforgeable + non-replayable).
#   6. NEVER print the signing seed to stdout/stderr.
# Plus a routing contract: `hmd dashboard login X` must exec bin/heimdall-dashboard.
#
# NO LIVE NETWORK: the CP endpoint is a local 127.0.0.1 mock that records the POST body.
#
# EXIT: 0 = all assertions pass (or a clean SKIP when the Ed25519 backend is absent); 1 = FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
DASH_BIN="$REPO/bin/heimdall-dashboard"
PY="$(command -v python3 || command -v python || true)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -n "$PY" ] || { echo "  SKIP: no python interpreter"; exit 0; }
[ -x "$DASH_BIN" ] || { bad "bin/heimdall-dashboard missing or not executable ($DASH_BIN)"; printf "\n  Results: %d passed, %d failed\n" "$PASS" "$FAIL"; exit 1; }

# Ed25519 backend guard — a signing test is meaningless without a crypto backend.
if ! LIB="$LIB" "$PY" - <<'PYEOF' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth
sys.exit(0 if cp_auth.crypto_available() else 1)
PYEOF
then
  echo "  SKIP: no Ed25519 backend (pip install cryptography) — cannot exercise signing"
  exit 0
fi

WORK="$(mktemp -d /tmp/test-dash-login-XXXXXX)"
HOME_DIR="$WORK/home"
PKI_DIR="$HOME_DIR/.heimdall/pki"
mkdir -p "$PKI_DIR"

HAID="haid:test.box-abcd"
# The seed-file slug MUST match heimdall-presence's keying: tr '/:' '__'.
HAID_SLUG="${HAID//\//_}"; HAID_SLUG="${HAID_SLUG//:/_}"
SEED_FILE="$PKI_DIR/$HAID_SLUG.seed"

# Generate an Ed25519 keypair; persist the seed 0600; keep the pubkey for verify.
KEYS="$(LIB="$LIB" "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth
priv, pub = cp_auth.generate_keypair()
sys.stdout.write(priv + "\n" + pub + "\n")
PYEOF
)"
SEED_B64="$(printf '%s\n' "$KEYS" | sed -n '1p')"
PUB_B64="$(printf '%s\n' "$KEYS" | sed -n '2p')"
umask 077; printf '%s' "$SEED_B64" > "$SEED_FILE"

# ── local mock CP endpoint (records POST bodies; status is env-configurable) ──
CAPTURE="$WORK/capture.ndjson"; : > "$CAPTURE"
SERVER_PY="$WORK/mock_cp.py"
cat > "$SERVER_PY" <<'PYEOF'
import http.server, os, sys
cap = os.environ["CAPTURE"]
status = int(os.environ.get("RESP_STATUS", "200"))
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        with open(cap, "ab") as f:
            f.write(self.path.encode() + b"\t" + body + b"\n")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if 200 <= status < 300:
            self.wfile.write(b'{"status":"ready","exp":9999999999}')
        else:
            self.wfile.write(b'{"error":"bad_signature"}')
    def log_message(self, *a):
        return
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
sys.stdout.write(str(srv.server_address[1]) + "\n"); sys.stdout.flush()
srv.serve_forever()
PYEOF

SERVER_PID=""; PORT=""; PORTFILE="$WORK/port"
# Sets PORT + SERVER_PID in the CURRENT shell (not a subshell) so stop_server can reap it.
start_server() {  # $1 = response status
  : > "$PORTFILE"
  RESP_STATUS="$1" CAPTURE="$CAPTURE" "$PY" "$SERVER_PY" > "$PORTFILE" 2>/dev/null &
  SERVER_PID=$!
  local tries=0
  while [ ! -s "$PORTFILE" ] && [ "$tries" -lt 100 ]; do tries=$((tries+1)); sleep 0.05; done
  PORT="$(sed -n '1p' "$PORTFILE")"
}
stop_server() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; wait "${SERVER_PID:-}" 2>/dev/null; SERVER_PID=""; }

# ── gh stubs ──
GH_OK_DIR="$WORK/gh-ok"; mkdir -p "$GH_OK_DIR"
cat > "$GH_OK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
# emulate `gh api user --jq .login`
if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then echo "octocat-test"; exit 0; fi
exit 0
EOF
chmod +x "$GH_OK_DIR/gh"

GH_UNAUTH_DIR="$WORK/gh-unauth"; mkdir -p "$GH_UNAUTH_DIR"
cat > "$GH_UNAUTH_DIR/gh" <<'EOF'
#!/usr/bin/env bash
# emulate an unauthenticated gh: every api call fails, no login on stdout.
echo "gh: To get started with GitHub CLI, please run: gh auth login" >&2
exit 1
EOF
chmod +x "$GH_UNAUTH_DIR/gh"

# A PATH with only bash + python (the tools the bin genuinely needs) and NO gh — for the
# gh-not-installed case. `command -v gh` must come back empty so the bin errors cleanly.
MINI_BIN="$WORK/mini-bin"; mkdir -p "$MINI_BIN"
ln -s "$PY" "$MINI_BIN/python3" 2>/dev/null || true
ln -s "$PY" "$MINI_BIN/python" 2>/dev/null || true
ln -s "$(command -v bash)" "$MINI_BIN/bash" 2>/dev/null || true
ln -s "$(command -v dirname)" "$MINI_BIN/dirname" 2>/dev/null || true

cleanup() { stop_server; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

DEVICE_CODE="dc-0123456789abcdef"

# ══════════════════════════════════════════════════════════════════════════════
# 1. HAPPY PATH — signs the exact assertion + POSTs the right body; prints success.
# ══════════════════════════════════════════════════════════════════════════════
start_server 200
: > "$CAPTURE"
OUT="$(HOME="$HOME_DIR" PATH="$GH_OK_DIR:$PATH" \
  bash "$DASH_BIN" login "$DEVICE_CODE" --yes --haid "$HAID" --url "http://127.0.0.1:$PORT" 2>"$WORK/err1")"
RC=$?
stop_server

if [ "$RC" -eq 0 ]; then ok "login exits 0 on a 200 approve"; else bad "login exits 0 on a 200 approve (rc=$RC)"; cat "$WORK/err1" >&2; fi
if printf '%s' "$OUT" | grep -q "approved"; then ok "prints the success line (approved — return to your browser)"; else bad "prints the success line"; printf 'stdout=%s\n' "$OUT" >&2; fi

# The recorded POST: correct path + body fields + a signature that verifies over the
# byte-identical cp_session.assertion_message.
VERDICT="$(LIB="$LIB" CAPTURE="$CAPTURE" EXP_HAID="$HAID" PUB="$PUB_B64" DEVICE_CODE="$DEVICE_CODE" "$PY" - <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_session
lines = open(os.environ["CAPTURE"], "rb").read().splitlines()
if not lines:
    print("NO_POST"); sys.exit()
path, _, body = lines[-1].partition(b"\t")
if path.decode() != "/dashboard/session/approve":
    print("BAD_PATH:" + path.decode()); sys.exit()
d = json.loads(body)
need = {"haid", "gh_user", "device_code", "nonce", "sig"}
if set(d) != need:
    print("BAD_FIELDS:" + ",".join(sorted(d))); sys.exit()
if d["haid"] != os.environ["EXP_HAID"]: print("BAD_HAID"); sys.exit()
if d["device_code"] != os.environ["DEVICE_CODE"]: print("BAD_DC"); sys.exit()
if not d["gh_user"]: print("NO_GHUSER"); sys.exit()
msg = cp_session.assertion_message(d["haid"], d["gh_user"], d["device_code"], d["nonce"])
if cp_auth.verify_raw(os.environ["PUB"], msg, d["sig"]):
    print("OK:" + d["gh_user"] + ":" + d["nonce"])
else:
    print("BAD_SIG")
PYEOF
)"
case "$VERDICT" in
  OK:octocat-test:*) ok "POST body {haid,gh_user,device_code,nonce,sig} to /dashboard/session/approve; sig verifies over cp_session.assertion_message" ;;
  *) bad "POST body / signature contract ($VERDICT)" ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# 2. NONCE RANDOMNESS — a second run uses a different nonce (and thus a different sig).
# ══════════════════════════════════════════════════════════════════════════════
start_server 200
: > "$CAPTURE"
HOME="$HOME_DIR" PATH="$GH_OK_DIR:$PATH" bash "$DASH_BIN" login "$DEVICE_CODE" --yes --haid "$HAID" --url "http://127.0.0.1:$PORT" >/dev/null 2>&1
HOME="$HOME_DIR" PATH="$GH_OK_DIR:$PATH" bash "$DASH_BIN" login "$DEVICE_CODE" --yes --haid "$HAID" --url "http://127.0.0.1:$PORT" >/dev/null 2>&1
stop_server
NONCES="$(LIB="$LIB" CAPTURE="$CAPTURE" "$PY" - <<'PYEOF'
import json, os
rows = open(os.environ["CAPTURE"], "rb").read().splitlines()
ns = []
for r in rows:
    _p, _, body = r.partition(b"\t")
    ns.append(json.loads(body)["nonce"])
print("DIFF" if len(ns) >= 2 and len(set(ns)) == len(ns) else "SAME")
PYEOF
)"
if [ "$NONCES" = "DIFF" ]; then ok "nonce is fresh/random per run"; else bad "nonce reused across runs ($NONCES)"; fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. 401 — signature/enrollment rejected → clear error, non-zero exit.
# ══════════════════════════════════════════════════════════════════════════════
start_server 401
: > "$CAPTURE"
ERR="$(HOME="$HOME_DIR" PATH="$GH_OK_DIR:$PATH" bash "$DASH_BIN" login "$DEVICE_CODE" --yes --haid "$HAID" --url "http://127.0.0.1:$PORT" 2>&1 >/dev/null)"
RC=$?
stop_server
if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qi "reject"; then ok "401 → clear rejection message + non-zero exit"; else bad "401 handling (rc=$RC, err=$ERR)"; fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. NOT ENROLLED — no seed for this HAID → clear error, no POST.
# ══════════════════════════════════════════════════════════════════════════════
start_server 200
: > "$CAPTURE"
ERR="$(HOME="$HOME_DIR" PATH="$GH_OK_DIR:$PATH" bash "$DASH_BIN" login "$DEVICE_CODE" --yes --haid "haid:not.enrolled-9999" --url "http://127.0.0.1:$PORT" 2>&1 >/dev/null)"
RC=$?
stop_server
if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qiE "enroll|not enrolled|signing key"; then ok "not-enrolled → clear error"; else bad "not-enrolled handling (rc=$RC, err=$ERR)"; fi
if [ ! -s "$CAPTURE" ]; then ok "not-enrolled makes NO POST"; else bad "not-enrolled must not POST"; fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. gh NOT AUTHENTICATED — no login → clear error, no signing, no POST.
# ══════════════════════════════════════════════════════════════════════════════
start_server 200
: > "$CAPTURE"
ERR="$(HOME="$HOME_DIR" PATH="$GH_UNAUTH_DIR:$PATH" bash "$DASH_BIN" login "$DEVICE_CODE" --yes --haid "$HAID" --url "http://127.0.0.1:$PORT" 2>&1 >/dev/null)"
RC=$?
stop_server
if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qi "gh auth"; then ok "gh unauthenticated → 'gh auth login' error"; else bad "gh-unauth handling (rc=$RC, err=$ERR)"; fi
if [ ! -s "$CAPTURE" ]; then ok "gh-unauth makes NO POST"; else bad "gh-unauth must not POST"; fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. gh NOT INSTALLED — gh absent from PATH → clear error, no POST.
# ══════════════════════════════════════════════════════════════════════════════
start_server 200
: > "$CAPTURE"
ERR="$(HOME="$HOME_DIR" PATH="$MINI_BIN" bash "$DASH_BIN" login "$DEVICE_CODE" --yes --haid "$HAID" --url "http://127.0.0.1:$PORT" 2>&1 >/dev/null)"
RC=$?
stop_server
if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qi "gh"; then ok "gh not installed → clear error"; else bad "gh-missing handling (rc=$RC, err=$ERR)"; fi
if [ ! -s "$CAPTURE" ]; then ok "gh-missing makes NO POST"; else bad "gh-missing must not POST"; fi

# ══════════════════════════════════════════════════════════════════════════════
# 7. SECRET HYGIENE — the signing seed never appears on stdout/stderr.
# ══════════════════════════════════════════════════════════════════════════════
start_server 200
BOTH="$(HOME="$HOME_DIR" PATH="$GH_OK_DIR:$PATH" bash "$DASH_BIN" login "$DEVICE_CODE" --yes --haid "$HAID" --url "http://127.0.0.1:$PORT" 2>&1)"
stop_server
if printf '%s' "$BOTH" | grep -qF "$SEED_B64"; then bad "the signing seed LEAKED to output"; else ok "signing seed never printed"; fi

# ══════════════════════════════════════════════════════════════════════════════
# 7b. CONSENT SAFETY — no --yes and a non-interactive stdin MUST refuse (never hang,
#     never approve unasked). stdin < /dev/null makes `[ -t 0 ]` false.
# ══════════════════════════════════════════════════════════════════════════════
start_server 200
: > "$CAPTURE"
ERR="$(HOME="$HOME_DIR" PATH="$GH_OK_DIR:$PATH" bash "$DASH_BIN" login "$DEVICE_CODE" --haid "$HAID" --url "http://127.0.0.1:$PORT" </dev/null 2>&1 >/dev/null)"
RC=$?
stop_server
if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qi -- "--yes"; then ok "no --yes + non-interactive → refuses (points at --yes)"; else bad "consent-refuse handling (rc=$RC, err=$ERR)"; fi
if [ ! -s "$CAPTURE" ]; then ok "unconfirmed login makes NO POST"; else bad "unconfirmed login must not POST"; fi

# ══════════════════════════════════════════════════════════════════════════════
# 8. ROUTING — `hmd dashboard login X` execs bin/heimdall-dashboard, args forwarded.
# ══════════════════════════════════════════════════════════════════════════════
FAKE_DIR="$(mktemp -d /tmp/test-dash-route-XXXXXX)"
FAKE_BIN="$FAKE_DIR/bin"; FAKE_HOME="$FAKE_DIR/home"
mkdir -p "$FAKE_BIN" "$FAKE_HOME" "$FAKE_DIR/.claude-plugin"
cp "$REPO/bin/heimdall" "$FAKE_BIN/heimdall"; chmod +x "$FAKE_BIN/heimdall"
touch "$FAKE_HOME/setup-done"
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/claude"
ROUTE_OUT="$FAKE_DIR/out"
cat > "$FAKE_BIN/heimdall-dashboard" <<EOF
#!/usr/bin/env bash
printf 'heimdall-dashboard ARGS: %s\n' "\$*" >> "$ROUTE_OUT"
exit 0
EOF
chmod +x "$FAKE_BIN/heimdall-dashboard"
: > "$ROUTE_OUT"
PATH="$FAKE_BIN:$PATH" HEIMDALL_HOME="$FAKE_HOME" HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 \
  bash "$FAKE_BIN/heimdall" dashboard login "dc-routed-xyz" >/dev/null 2>&1 || true
if grep -q "heimdall-dashboard ARGS:" "$ROUTE_OUT" 2>/dev/null && grep -qF "login dc-routed-xyz" "$ROUTE_OUT" 2>/dev/null; then
  ok "hmd dashboard login X routes to bin/heimdall-dashboard (args forwarded)"
else
  bad "hmd dashboard routing"; cat "$ROUTE_OUT" >&2
fi
rm -rf "$FAKE_DIR" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# 9. Syntax check.
# ══════════════════════════════════════════════════════════════════════════════
if bash -n "$DASH_BIN" 2>/dev/null; then ok "bin/heimdall-dashboard passes bash -n"; else bad "bin/heimdall-dashboard syntax error"; bash -n "$DASH_BIN" >&2; fi

printf "\n  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
# heimdall-god-cli.test.sh — proves the `hmd god` CLI + the owner-grant mechanism, end to end,
# against a MOCKED GATED endpoint (no live GCP, no real deploy). Two parts:
#
#   PART A (owner-grant unit) — cp_auth.promote_owners flips owner=True on an ENROLLED HAID's
#     binding (preserving pubkey), is idempotent, skips a HAID with no binding, and — the
#     oracle-gate for the grant — a HAID NOT in the configured list stays owner=False and is
#     STILL refused 401 not_owner by the REAL cp_god owner gate. So the grant escalates ONLY
#     the declared identity; INV-GOD G3 is untouched.
#
#   PART B (CLI integration) — a mock gated CP (a stdlib http.server that runs the REAL
#     cp_auth.verify_identity + cp_god handlers in-process, and RECORDS request headers)
#     proves the shipped bin/heimdall-god:
#       * request SHAPING — attaches Authorization: Bearer <id-token> (the Cloud Run IAM edge)
#         + X-Heimdall-HAID + X-Heimdall-Signature (the app-layer owner signature), and signs
#         the FULL canonical GET path (empty body).
#       * OWNER path — a signed OWNER identity -> 200 + the cross-team roster/logs.
#       * FALSIFIER — a signed NON-owner identity -> 401 not_owner, non-zero exit.
#
# stdlib-only python, LOCAL backend, ZERO real GCP. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
GOD_BIN="$REPO/bin/heimdall-god"

for f in cp_auth cp_god cp_presence cp_audit cp_approval cp_state cp_server; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$GOD_BIN" ] || { echo "FATAL: $GOD_BIN missing/not executable" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

WORK="$(mktemp -d -t hmd-god-cli.XXXXXX)"
CP_HOME="$WORK/cp"        # the mock control plane's HEIMDALL_HOME (registry/presence/audit).
HOME_T="$WORK/home"       # the CLI's $HOME (holds the enrolled 0600 seed files).
mkdir -p "$CP_HOME" "$HOME_T/.heimdall/pki"
HANDSHAKE="$WORK/handshake.json"
HEADERS_LOG="$WORK/headers.ndjson"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

export LIB CP_HOME HOME_T HANDSHAKE HEADERS_LOG

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# ════════════════════════════════════════════════════════════════════════════════════════
# PART A — the owner-grant mechanism (cp_auth.promote_owners) + the G3 oracle-gate.
# ════════════════════════════════════════════════════════════════════════════════════════
echo "PART A — owner grant (cp_auth.promote_owners)"
A_HOME="$WORK/grant"; mkdir -p "$A_HOME"
GRANT_HOME="$A_HOME" "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
HOME = os.environ["GRANT_HOME"]
import cp_auth, cp_god

P = F = 0
def ok(m):
    global P; P += 1; print("  \033[32mPASS\033[0m " + m)
def bad(m):
    global F; F += 1; print("  \033[31mFAIL\033[0m " + m)
def check(c, m): ok(m) if c else bad(m)

# two ENROLLED devs (owner=False, exactly as cp_enroll binds them) + valid keypairs
priv_rj, pub_rj = cp_auth.generate_keypair()
priv_ally, pub_ally = cp_auth.generate_keypair()
RJ = "haid:rj.rishabhs-macbook-air-4d6d"
ALLY = "haid:ally.teammate"
cp_auth.register_key(RJ, pub_rj, owner=False, team_id="t-rj", project="rj/app", home=HOME)
cp_auth.register_key(ALLY, pub_ally, owner=False, team_id="t-ally", project="ally/svc", home=HOME)

check(not cp_auth.is_owner(RJ, home=HOME), "pre: RJ enrolled owner=False (as cp_enroll binds)")
check(not cp_auth.is_owner(ALLY, home=HOME), "pre: teammate enrolled owner=False")

# configured_owner_haids parses the env list (comma/space, de-duped)
os.environ["HEIMDALL_CP_OWNER_HAIDS"] = "%s, %s ,%s" % (RJ, RJ, "haid:ghost.never-enrolled")
parsed = cp_auth.configured_owner_haids()
check(parsed == [RJ, "haid:ghost.never-enrolled"], "configured_owner_haids parses+dedupes (%s)" % parsed)

# promote: RJ (enrolled) -> promoted; ghost (no binding) -> skipped_absent; ally untouched
res = cp_auth.promote_owners(home=HOME)
check(res["promoted"] == [RJ], "promote: RJ promoted (%s)" % res["promoted"])
check(res["skipped_absent"] == ["haid:ghost.never-enrolled"],
      "promote: unenrolled HAID skipped_absent, never fabricated (%s)" % res["skipped_absent"])
check(cp_auth.is_owner(RJ, home=HOME), "post: RJ is now owner=True")
check(cp_auth.registered_pubkey(RJ, home=HOME) == pub_rj, "post: RJ pubkey PRESERVED across promotion")
check(cp_auth.registered_team(RJ, home=HOME) == "t-rj", "post: RJ team_id preserved")
check(not cp_auth.is_owner(ALLY, home=HOME), "post: non-listed teammate STILL owner=False")

# idempotent: a second promote is a no-op write, RJ counts as already-owner
res2 = cp_auth.promote_owners(home=HOME)
check(res2["already"] == [RJ] and res2["promoted"] == [], "promote idempotent (already=%s)" % res2["already"])

# THE G3 ORACLE-GATE for the grant: the promoted owner passes the REAL cp_god owner gate,
# the non-listed teammate is STILL refused 401 not_owner (the grant did not weaken G3).
r_owner = cp_god.roster_route(cp_auth.Identity(RJ, owner=cp_auth.is_owner(RJ, home=HOME)), {}, home=HOME)
check(r_owner.status == 200, "grant: promoted owner -> cp_god 200 (%s)" % r_owner.status)
r_non = cp_god.roster_route(cp_auth.Identity(ALLY, owner=cp_auth.is_owner(ALLY, home=HOME)), {}, home=HOME)
check(r_non.status == 401 and r_non.body.get("error") == "not_owner",
      "grant G3: non-listed teammate STILL 401 not_owner (%s/%s)" % (r_non.status, r_non.body.get("error")))

# env unset => promote is a no-op (default single-owner deploy is byte-for-byte unchanged)
del os.environ["HEIMDALL_CP_OWNER_HAIDS"]
res3 = cp_auth.promote_owners(home=HOME)
check(res3 == {"promoted": [], "already": [], "skipped_absent": []},
      "promote no-op when HEIMDALL_CP_OWNER_HAIDS unset")

print("PART-A: %d passed, %d failed" % (P, F))
sys.exit(1 if F else 0)
PYEOF
rc=$?
[ "$rc" -eq 0 ] && ok "part A (owner grant) held" || bad "part A (owner grant) had failures"

# ════════════════════════════════════════════════════════════════════════════════════════
# PART B — the CLI against a MOCK GATED endpoint (real cp_auth + cp_god gate, header recorder).
# ════════════════════════════════════════════════════════════════════════════════════════
echo "PART B — hmd god CLI vs mock gated endpoint"

# The mock server seeds the CP state (owner + non-owner enrolled), writes both 0600 seed files
# into $HOME_T/.heimdall/pki/, records every request's headers, and runs the REAL owner gate.
"$PY" - <<'PYEOF' &
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.environ["LIB"])
HOME = os.environ["CP_HOME"]
HOME_T = os.environ["HOME_T"]
HANDSHAKE = os.environ["HANDSHAKE"]
HEADERS_LOG = os.environ["HEADERS_LOG"]

import cp_auth, cp_god, cp_presence, cp_audit

def seed_slug(haid):
    return haid.replace("/", "_").replace(":", "_")

# owner + non-owner, both ENROLLED (registered pubkey); seeds persisted 0600 like heimdall-presence
priv_o, pub_o = cp_auth.generate_keypair()
priv_n, pub_n = cp_auth.generate_keypair()
HAID_O = "haid:rj.owner-mac"
HAID_N = "haid:mallory.nonowner"
cp_auth.register_key(HAID_O, pub_o, owner=True, team_id="tid-owner", project="rj/god", home=HOME)
cp_auth.register_key(HAID_N, pub_n, owner=False, team_id="tid-a", project="alice/app", home=HOME)
# a second team so the god roster visibly crosses tenants
priv_b, pub_b = cp_auth.generate_keypair()
cp_auth.register_key("haid:bob.dev", pub_b, owner=False, team_id="tid-b", project="bob/svc", home=HOME)

for haid, priv in ((HAID_O, priv_o), (HAID_N, priv_n)):
    p = os.path.join(HOME_T, ".heimdall", "pki", seed_slug(haid) + ".seed")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(priv)
    os.chmod(p, 0o600)

# cross-team presence + audit so the aggregates are non-empty
import time
now = time.time()
cp_presence.record_presence(HAID_N, project="alice/app", team_id="tid-a", handle="alice",
                            verdict="PROVEN", file="app.py", home=HOME, ts=now)
cp_presence.record_presence("haid:bob.dev", project="bob/svc", team_id="tid-b", handle="bob",
                            verdict="BLOCKED", file="svc.go", home=HOME, ts=now)
cp_audit.write("approval", actor_haid=HAID_O, action_type="run-suite", decision="approved",
               outcome="ok", home=HOME)
cp_audit.write("dispatch", actor_haid=HAID_N, action_type="fix-issue", outcome="ok", home=HOME)
cp_audit.write("auth_fail", actor_haid="haid:intruder", outcome="refused", home=HOME)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # silence the default stderr access log
        return
    def do_GET(self):
        # RECORD the request shaping (headers the CLI must attach).
        rec = {
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "haid": self.headers.get("X-Heimdall-HAID"),
            "signature_present": bool(self.headers.get("X-Heimdall-Signature")),
        }
        with open(HEADERS_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
        # Build the §3 request dict and run the REAL auth chokepoint + owner gate.
        request = {
            "method": "GET",
            "path": self.path,
            "route_path": self.path.split("?", 1)[0],
            "body": b"",
            "haid": self.headers.get("X-Heimdall-HAID"),
            "signature": self.headers.get("X-Heimdall-Signature"),
        }
        try:
            identity = cp_auth.verify_identity(request, home=HOME, enforce_revocation=False)
        except cp_auth.AuthError as err:
            self._send(401, {"error": err.reason}); return
        route_path = request["route_path"]
        if route_path == "/god/roster":
            resp = cp_god.roster_route(identity, request, home=HOME)
        elif route_path == "/god/logs":
            resp = cp_god.logs_route(identity, request, home=HOME)
        else:
            self._send(404, {"error": "no_such_route"}); return
        self._send(resp.status, resp.body)
    def _send(self, status, body):
        raw = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

srv = HTTPServer(("127.0.0.1", 0), H)
port = srv.server_address[1]
with open(HANDSHAKE, "w", encoding="utf-8") as fh:
    json.dump({"port": port, "owner": HAID_O, "nonowner": HAID_N}, fh)
srv.serve_forever()
PYEOF
SERVER_PID=$!

# wait for the handshake (server ready)
for _ in $(seq 1 50); do [ -s "$HANDSHAKE" ] && break; sleep 0.1; done
[ -s "$HANDSHAKE" ] || { bad "mock server did not start"; echo "god-cli: $PASS passed, $FAIL failed"; exit 1; }
PORT="$("$PY" -c 'import json,os;print(json.load(open(os.environ["HANDSHAKE"]))["port"])')"
OWNER="$("$PY" -c 'import json,os;print(json.load(open(os.environ["HANDSHAKE"]))["owner"])')"
NONOWNER="$("$PY" -c 'import json,os;print(json.load(open(os.environ["HANDSHAKE"]))["nonowner"])')"
URL="http://127.0.0.1:$PORT"

# ── OWNER roster -> 200 + cross-team wall ────────────────────────────────────────
OUT="$(HOME="$HOME_T" HEIMDALL_GOD_ID_TOKEN="test-iam-token" \
       "$GOD_BIN" roster --url "$URL" --haid "$OWNER" --json 2>"$WORK/err.owner")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "owner roster -> exit 0"; else bad "owner roster exit $rc (err: $(cat "$WORK/err.owner"))"; fi
echo "$OUT" | grep -q "tid-a" && echo "$OUT" | grep -q "tid-b" \
  && ok "owner roster crosses tenants (tid-a + tid-b present)" \
  || bad "owner roster missing cross-team data: $OUT"

# request SHAPING: the LAST recorded request carried the IAM bearer + signature + haid
SHAPE="$("$PY" - <<'PYEOF'
import json, os
recs = [json.loads(l) for l in open(os.environ["HEADERS_LOG"]) if l.strip()]
r = recs[-1]
print("OK" if (r["authorization"] == "Bearer test-iam-token"
               and r["haid"] and r["signature_present"]
               and r["path"] == "/god/roster") else "NO:%s" % r)
PYEOF
)"
[ "$SHAPE" = "OK" ] && ok "request shaping: Authorization Bearer + HAID + signature on GET /god/roster" \
  || bad "request shaping wrong: $SHAPE"

# ── OWNER logs -> 200, sections present; --kind filters ──────────────────────────
LOGS="$(HOME="$HOME_T" HEIMDALL_GOD_ID_TOKEN="t" "$GOD_BIN" logs --url "$URL" --haid "$OWNER" --json 2>/dev/null)"; rc=$?
echo "$LOGS" | grep -q '"enrollments"' && echo "$LOGS" | grep -q '"security"' && [ "$rc" -eq 0 ] \
  && ok "owner logs -> 200 with enroll/verdicts/runs/security sections" \
  || bad "owner logs missing sections (rc=$rc)"
KLOG="$(HOME="$HOME_T" HEIMDALL_GOD_ID_TOKEN="t" "$GOD_BIN" logs --kind security --url "$URL" --haid "$OWNER" 2>/dev/null)"
echo "$KLOG" | grep -qi "SECURITY SIGNALS" && echo "$KLOG" | grep -q "auth_fail" \
  && ok "logs --kind security prints the security section (auth_fail row)" \
  || bad "logs --kind security wrong: $KLOG"

# ── FALSIFIER: signed NON-owner -> 401 not_owner, non-zero exit ──────────────────
NOUT="$(HOME="$HOME_T" HEIMDALL_GOD_ID_TOKEN="t" \
        "$GOD_BIN" roster --url "$URL" --haid "$NONOWNER" 2>"$WORK/err.non")"; rc=$?
[ "$rc" -ne 0 ] && ok "FALSIFIER: non-owner roster -> non-zero exit ($rc)" \
  || bad "FALSIFIER BREACH: non-owner got exit 0 (out: $NOUT)"
grep -q "not_owner" "$WORK/err.non" \
  && ok "FALSIFIER: non-owner refused with 401 not_owner (the exact G3 refusal)" \
  || bad "FALSIFIER: non-owner refusal did not name not_owner: $(cat "$WORK/err.non")"

echo
echo "god-cli: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mALL PROOFS HELD\033[0m — hmd god CLI + owner grant + non-owner falsifier\n'
  exit 0
fi
printf '\033[31mFAILURES\033[0m — see above\n'
exit 1

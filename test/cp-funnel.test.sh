#!/usr/bin/env bash
# cp-funnel.test.sh — SERVER-SIDE launch-funnel stamps (derived facts, ZERO new client egress).
#
# THE GOVERNING CONSTRAINT THIS SUITE GATES. IDENTITY.md:32-38 is a signed, dated boundary: the
# signed heartbeat is "the ONLY thing sent home; no analytics, no tracking, no third parties",
# and DATA.md:15 publicly commits that telemetry is "Not in this release. Written to a LOCAL
# spool only." A NEW payload sent from the client BREAKS that claim. A fact DERIVED server-side
# from data the heartbeat ALREADY lawfully delivered does not. Every stamp gated here is in the
# second category, and section 4 is the falsifiable proof of it.
#
# WHAT THIS GATES (cp_funnel + its two call sites, cp_enroll and cp_presence):
#
#   1. TEAM-2+ (the K-factor numerator) — the 1 -> 2 member edge stamps
#      funnel/team_grew/<team_id_hash>.json {first_second_member_at} EXACTLY ONCE. A 2 -> 3
#      enroll NEVER overwrites it (lose the write-once and you lose the cohort date). The doc
#      is keyed by the ONE-WAY pmr.team_id_hash projection, NEVER the raw team_id.
#   2. ENROLL (the denominator) — (a) a read surface over the EXISTING key registry bucketed by
#      enrolled_at, and (b) an APPEND-ONLY funnel/enroll/<day>.ndjson counter written at the
#      enroll site, because cp_registry_hygiene EVICTS idle bindings and the registry-derived
#      number would silently decay to zero. Both are asserted across a real eviction.
#   3. FIRST-VERDICT (the activation event) — the first non-empty `verdict` on a heartbeat
#      stamps funnel/first_verdict/<haid_hash>.json {first_verdict_at}; a later verdict does NOT
#      overwrite it; and the stamp SURVIVES presence reaping because `funnel` is NOT a TTL-
#      eligible Firestore root (the presence record it is derived from is reaped; the stamp is
#      not). `verdict` is already named in IDENTITY.md's sanctioned heartbeat payload.
#   4. NO-EGRESS (the cardinal privacy proof) — with the control plane SEVERED, a beat + roster
#      reach a localhost recording server ZERO times, and NO new outbound call exists anywhere
#      in the touched server modules. Mirrors test/heimdall-presence-cp-optin.test.sh section 2d.
#
# Hermetic: throwaway HOME + external store dir, local StateBackend, localhost-only wire server,
# no real GCP / no network. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_funnel cp_enroll cp_presence cp_auth cp_state cp_registry_hygiene pmr_corpus; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t cp-funnel)"
WIRE_PID=""
cleanup() { [ -n "$WIRE_PID" ] && kill "$WIRE_PID" >/dev/null 2>&1 || true; rm -rf "$EXT"; }
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# 1. TEAM-2+ — the 1 -> 2 edge stamps ONCE; 2 -> 3 never overwrites  [FALSIFIABLE]
# ══════════════════════════════════════════════════════════════════════════════
echo "1. team-2+: the 1->2 member edge stamps first_second_member_at exactly once"
H1="$EXT/home1"; mkdir -p "$H1"
OUT1="$(HEIMDALL_HOME="$H1" HEIMDALL_ENROLL_OPEN=1 LIB="$LIB" "$PY" - <<'PYEOF' 2>&1
import base64, json, os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_enroll, cp_funnel, cp_state
import pmr_corpus as pmr

SECRET = "team-secret-for-the-funnel-gate-0123456789abcdef"
TEAM = cp_auth.derive_team_id(SECRET)
HASH = pmr.team_id_hash(TEAM)
REL = cp_funnel.team_grew_rel(TEAM)
backend = cp_state.get_backend()

def pub(seed):
    return base64.b64encode(bytes([seed]) * 32).decode("ascii")

def enroll(haid, seed):
    return cp_enroll.enroll(haid, pub(seed), provided_token=None, team_secret=SECRET)

out = {"team_id": TEAM, "hash": HASH, "rel": REL}

# member 1 — the 0 -> 1 edge is NOT the K-factor event; nothing may be stamped yet.
out["r1"] = enroll("haid:m1", 1)
out["after_1"] = backend.get_record(REL)

# member 2 — THE 1 -> 2 edge. This is the stamp.
time.sleep(1.05)
out["r2"] = enroll("haid:m2", 2)
rec2 = backend.get_record(REL)
out["after_2"] = rec2

# member 3 — the 2 -> 3 edge must NEVER overwrite the cohort date.
time.sleep(1.05)
out["r3"] = enroll("haid:m3", 3)
out["after_3"] = backend.get_record(REL)
out["members"] = cp_auth.team_member_count(TEAM)

# THE RE-CROSSED EDGE (what actually isolates write-once). cp_registry_hygiene EVICTS idle
# bindings, so a team can fall BACK to one member and then cross 1 -> 2 a SECOND time. The
# members_before guard does NOT protect the stamp here -- it is satisfied again -- so only
# write-once keeps the original cohort date. Drop write-once and this overwrites.
cp_auth.remove_keys(["haid:m2", "haid:m3"], home=None)
out["members_after_evict"] = cp_auth.team_member_count(TEAM)
time.sleep(1.05)
out["r4"] = enroll("haid:m4", 4)
out["members_recrossed"] = cp_auth.team_member_count(TEAM)
out["after_recross"] = backend.get_record(REL)
print(json.dumps(out, sort_keys=True))
PYEOF
)"
R1="$?"

if [ "$R1" -eq 0 ] && printf '%s' "$OUT1" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
assert d["members"] == 3, d["members"]
assert d["after_1"] is None, "0->1 must NOT stamp"
a2, a3 = d["after_2"], d["after_3"]
assert isinstance(a2, dict) and isinstance(a2.get("first_second_member_at"), (int, float)), a2
assert a3 == a2, "2->3 OVERWROTE the cohort date"
assert d["members_after_evict"] == 1, d
assert d["members_recrossed"] == 2, d
assert d["after_recross"] == a2, "a RE-CROSSED 1->2 edge OVERWROTE the cohort date"
' >/dev/null 2>&1; then
  ok "1a 1->2 stamps first_second_member_at; 0->1 does not; 2->3 does NOT overwrite; a RE-CROSSED 1->2 (post-eviction) does NOT overwrite (write-once)"
else
  bad "1a team_grew stamp wrong (rc=$R1) -- $OUT1"
fi

# 1b the doc is keyed by the ONE-WAY hash, never the raw team_id (no join back to a team).
if printf '%s' "$OUT1" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
assert d["hash"] in d["rel"], d
assert d["team_id"] not in d["rel"], "RAW team_id leaked into the funnel key"
assert d["rel"].startswith("funnel/"), d["rel"]
' >/dev/null 2>&1; then
  ok "1b the key is funnel/team_grew/<pmr.team_id_hash> -- the RAW team_id never appears"
else
  bad "1b funnel key leaked the raw team_id -- $OUT1"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. ENROLL — the append-only day counter SURVIVES a real cp_registry_hygiene eviction
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "2. enroll denominator: append-only counter survives registry eviction"
H2="$EXT/home2"; mkdir -p "$H2"
OUT2="$(HEIMDALL_HOME="$H2" HEIMDALL_ENROLL_OPEN=1 LIB="$LIB" "$PY" - <<'PYEOF' 2>&1
import base64, json, os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_enroll, cp_funnel, cp_registry_hygiene
import cp_state

SECRET = "team-secret-for-the-funnel-gate-0123456789abcdef"
TEAM = cp_auth.derive_team_id(SECRET)
NOW = time.time()
DAY = cp_funnel.day_key(NOW)

def pub(seed):
    return base64.b64encode(bytes([seed]) * 32).decode("ascii")

for i in range(1, 4):
    cp_enroll.enroll("haid:e%d" % i, pub(i), provided_token=None, team_secret=SECRET)

out = {"day": DAY}
out["spool_before"] = cp_funnel.enroll_count(day=DAY)
out["registry_before"] = cp_funnel.enrolled_by_day()

# Age every binding past the idle window so the REAL hygiene job evicts them, then run it.
reg = cp_auth._load_keys(None)
for entry in reg["keys"].values():
    entry["enrolled_at"] = int(NOW - 400 * 86400)
cp_state.get_backend().put_record(cp_auth._KEYS_REL, reg)

plan = cp_registry_hygiene.evict_stale(apply=True)
out["evicted"] = sorted(plan["evicted"])
out["registry_after"] = cp_funnel.enrolled_by_day()
out["spool_after"] = cp_funnel.enroll_count(day=DAY)
out["spool_total"] = cp_funnel.enroll_count()
print(json.dumps(out, sort_keys=True))
PYEOF
)"
R2="$?"

if [ "$R2" -eq 0 ] && printf '%s' "$OUT2" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
assert d["spool_before"] == 3, d
assert d["registry_before"].get(d["day"]) == 3, d
assert len(d["evicted"]) == 3, d
assert d["registry_after"].get(d["day"], 0) == 0, "registry read surface should decay to 0"
assert d["spool_after"] == 3, "the append-only counter DECAYED with the eviction"
assert d["spool_total"] == 3, d
' >/dev/null 2>&1; then
  ok "2a 3 enrolls -> spool=3 AND registry=3; after eviction registry DECAYS to 0 but the spool still reads 3"
else
  bad "2a enroll counter did not survive eviction (rc=$R2) -- $OUT2"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. FIRST-VERDICT — stamps once, never overwritten, survives presence reaping
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "3. first-verdict: stamps on the first non-empty verdict, write-once, reap-proof"
H3="$EXT/home3"; mkdir -p "$H3"
OUT3="$(HEIMDALL_HOME="$H3" LIB="$LIB" "$PY" - <<'PYEOF' 2>&1
import json, os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_funnel, cp_presence, cp_state
import cp_state_firestore as fs

HAID = "haid:v1"
PROJ = "acme/widget"
TEAM = "0123456789abcdef0123456789abcdef"
REL = cp_funnel.first_verdict_rel(HAID)
backend = cp_state.get_backend()
out = {"rel": REL, "haid": HAID}

def beat(verdict):
    return cp_presence.record_presence(HAID, project=PROJ, team_id=TEAM, verdict=verdict)

# a beat with NO verdict is not an activation — nothing may be stamped.
beat(None)
out["after_none"] = backend.get_record(REL)
beat("")
out["after_empty"] = backend.get_record(REL)

# the FIRST non-empty verdict IS the activation.
time.sleep(1.05)
beat("building")
out["after_first"] = backend.get_record(REL)

# a LATER verdict must not move the activation instant.
time.sleep(1.05)
beat("testing")
out["after_second"] = backend.get_record(REL)

# REAPING: drop the presence record entirely (what the reaper does) — the stamp survives
# because it lives on its own durable doc, not on the reaped presence doc.
presence_rel = cp_presence._record_rel(PROJ, TEAM, HAID)
os.remove(backend.path(presence_rel))
out["presence_after_reap"] = backend.get_record(presence_rel)
out["after_reap"] = backend.get_record(REL)

# the DURABILITY proof under firestore: `funnel` is not a TTL-eligible root, so no ttl_at is
# ever attached to a funnel doc (reaping a presence doc can never take the stamp with it).
# NB: no apostrophes in this heredoc -- bash 3.2 (the macOS default) mis-parses a bare
# single quote inside a heredoc nested in a $( ) command substitution.
out["funnel_ttl"] = fs._ttl_at_for(REL)
out["ttl_roots"] = sorted(fs._TTL_ELIGIBLE_ROOTS)
print(json.dumps(out, sort_keys=True, default=str))
PYEOF
)"
R3="$?"

if [ "$R3" -eq 0 ] && printf '%s' "$OUT3" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
assert d["after_none"] is None, "a verdict-less beat must NOT stamp"
assert d["after_empty"] is None, "an EMPTY verdict must NOT stamp"
f = d["after_first"]
assert isinstance(f, dict) and isinstance(f.get("first_verdict_at"), (int, float)), f
assert d["after_second"] == f, "a LATER verdict OVERWROTE first_verdict_at"
' >/dev/null 2>&1; then
  ok "3a first non-empty verdict stamps first_verdict_at; verdict-less/empty beats do not; a later verdict does NOT overwrite"
else
  bad "3a first_verdict_at stamping wrong (rc=$R3) -- $OUT3"
fi

if printf '%s' "$OUT3" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
assert d["presence_after_reap"] is None, "the presence record was not actually reaped"
assert d["after_reap"] == d["after_first"], "the stamp EVAPORATED with the presence record"
assert d["funnel_ttl"] is None, "a funnel doc carries ttl_at -- firestore will reap the stamp"
assert "funnel" not in d["ttl_roots"], d["ttl_roots"]
' >/dev/null 2>&1; then
  ok "3b the stamp SURVIVES presence reaping -- funnel is not a TTL-eligible root, so no ttl_at is ever attached"
else
  bad "3b the stamp did not survive reaping -- $OUT3"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. NO-EGRESS — the cardinal privacy proof (IDENTITY.md:32-38 / DATA.md:15)
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "4. NO-EGRESS: severed => zero requests; no new client emit anywhere in the change"
REC="$EXT/rec"; mkdir -p "$REC"
cat >"$EXT/recsrv.py" <<'PYEOF'
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
REC = os.environ["REC_DIR"]
def rec(line):
    with open(os.path.join(REC, "requests.log"), "a") as fh:
        fh.write(line + "\n")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        return
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        self._body(); rec("POST " + self.path.split("?")[0])
        return self._send(200, {"ok": True})
    def do_GET(self):
        rec("GET " + self.path.split("?")[0])
        return self._send(200, {"roster": []})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(REC, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
REC_DIR="$REC" "$PY" "$EXT/recsrv.py" &
WIRE_PID=$!
for _ in $(seq 1 40); do [ -s "$REC/port" ] && break; "$PY" -c "import time;time.sleep(0.1)"; done
PORT="$(cat "$REC/port" 2>/dev/null || true)"

H4="$EXT/home4"; R4="$EXT/repo4"; mkdir -p "$H4" "$R4"
if [ -z "$PORT" ]; then
  bad "4a recording server never bound a port -- cannot prove no-egress"
else
  pres4() { env -u HEIMDALL_CP_URL -u BASE_URL HOME="$H4" HEIMDALL_PRESENCE_DIR="$R4/.heimdall" \
            HEIMDALL_DEFAULT_CP_URL="http://127.0.0.1:$PORT" HMD_ENROLL_THROTTLE=0 \
            HMD_HAID="haid:t4" HMD_PROJECT="acme/widget" "$REPO/bin/heimdall-presence" "$@"; }
  # SEVER the control plane (the opt-out nulls the CP URL) THEN clear the log, so only
  # post-sever traffic is observed. Any funnel work routed through its own endpoint would
  # escape this opt-out and show up here.
  pres4 sever >/dev/null 2>&1
  : > "$REC/requests.log"
  B4=0; pres4 beat --handle t4 --verdict building --file src/app.py >/dev/null 2>&1 || B4=$?
  O4=0; pres4 roster >/dev/null 2>&1 || O4=$?
  if [ ! -s "$REC/requests.log" ] && [ "$B4" -eq 0 ] && [ "$O4" -eq 0 ]; then
    ok "4a SEVERED: a beat + a roster produce ZERO requests -- the funnel adds no egress that escapes the opt-out"
  else
    bad "4a funnel LEAKED past the sever (beat=$B4 roster=$O4) -- log: $(cat "$REC/requests.log" 2>/dev/null)"
  fi
fi
kill "$WIRE_PID" >/dev/null 2>&1 || true; wait "$WIRE_PID" 2>/dev/null || true; WIRE_PID=""

# 4b SOURCE DISCIPLINE: an OUTBOUND primitive is the thing that would break the claim. The
#    pattern is deliberately scoped to primitives that OPEN a connection -- urllib.parse (an
#    INBOUND query-string parser cp_presence already used) is not one and must not be matched.
#    (i) cp_funnel.py carries none at all; (ii) NO ADDED LINE anywhere in this change introduces
#    one. A stamp is a store write on a fact the heartbeat already delivered, never a call home.
EGRESS_RX='urllib\.request|urlopen|http\.client|httplib|requests\.(get|post|put|request)|socket\.(socket|create_connection)|subprocess.*curl|\bcurl\b'
LEAK="$(grep -nE "$EGRESS_RX" "$LIB/cp_funnel.py" 2>/dev/null || true)"
ADDED="$(cd "$REPO" && git diff -U0 HEAD -- bin/ 2>/dev/null | grep '^+' | grep -vE '^\+\+\+' \
         | grep -E "$EGRESS_RX" || true)"
if [ -z "$LEAK" ] && [ -z "$ADDED" ]; then
  ok "4b cp_funnel.py has ZERO outbound primitives, and no ADDED line in bin/ introduces one"
else
  bad "4b an outbound call appeared:
$LEAK
$ADDED"
fi

# 4c THE CLIENT IS UNTOUCHED: no client-side emitter was added. The client egress surface
#    (bin/heimdall-presence, install.sh, bin/lib/funnel.py) must carry ZERO diff.
DIRTY="$(cd "$REPO" && git diff --name-only HEAD -- bin/heimdall-presence install.sh bin/lib/funnel.py bin/lib/cp_corpus.py 2>/dev/null)"
if [ -z "$DIRTY" ]; then
  ok "4c the client egress surface is UNCHANGED (no new emit in heimdall-presence/install.sh/funnel.py, no /corpus caller)"
else
  bad "4c a client egress file was modified:
$DIRTY"
fi

# 4d funnel.py keeps its NO-TRANSPORT design -- it was never given a way home.
if ! grep -qE 'urllib|http\.client|requests\.|cp_url|CP_URL' "$LIB/funnel.py" 2>/dev/null; then
  ok "4d bin/lib/funnel.py still has NO transport (it was not wired up -- the claim-breaking path)"
else
  bad "4d bin/lib/funnel.py gained a transport -- that BREAKS the IDENTITY.md claim"
fi

echo
echo "============================================================"
printf "cp-funnel: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

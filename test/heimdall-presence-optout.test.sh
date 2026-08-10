#!/usr/bin/env bash
# heimdall-presence-optout.test.sh — PRESENCE OPT-OUT (the consent surface, LAUNCH-BLOCKER).
#
# Server presence was always-on: any open session broadcast {handle, verdict, current file}
# with no off switch. This suite gates the opt-out: per-repo + global toggles, a retire beat
# that ACTIVELY drops the dev off teammates' walls (not just stops updating), a --no-files
# privacy sub-toggle, and a statusline "you're invisible" hint. Every proof is falsifiable —
# each ON assertion is paired with the OFF assertion that would flip if the guard were removed.
#
#   1. CLI TOGGLES + STORAGE — off/on/status write the durable local state (per-repo
#      .heimdall/presence.json + global ~/.heimdall/presence-off) and read it back.
#   2. OFF = ZERO BEATS (bash guard, falsifiable) — a `beat` while off never reaches the
#      network/bootstrap (no enroll-attempt stamp); ON does (the stamp appears) — the guard
#      short-circuits BEFORE run_client. A cron/hook can't leak a beat around the toggle.
#   3. RETIRE at the READ AUTHORITY (cp_presence module, falsifiable) — a retired dev is
#      DROPPED from a fresh roster read (server-honored, not cosmetic); the SAME dev with a
#      normal beat (retired absent) reappears — the `retired` flag decides, not the data (RED
#      if roster ignored the flag). Re-opt-in restores presence.
#   4. SCOPE — repo-off in repo A does NOT silence repo B; global-off silences BOTH; `on`
#      restores each scope independently (CLI status) + retirement is per-(project,team)
#      (module).
#   5. WIRE BEHAVIOR (real signed HTTP to a recording server) — a normal beat sends the file;
#      `on --no-files` sends file:null with handle+verdict present; `off` POSTs a retire beat
#      to /presence-retire; a subsequent `beat` while off sends NOTHING.
#   6. OPT-OUT VISIBILITY (falsifiable) — the v1 statusline is a FIXED 4-row layout (see
#      heimdall-statusline-width.test.sh) with NO per-render tease row, so its opt-out proof is
#      the .beat-stamp: an ON render ARMS a beat (stamp written), an OFF render writes NONE. The
#      solo invite tease was RELOCATED to the session-end farewell (sentinels/hmd-farewell.sh) —
#      a solo, presence-ON farewell shows "hmd invite"; an opted-out farewell SUPPRESSES it (an
#      invite would be a lie when no one can see the dev).
#   7. GITIGNORE — .heimdall/presence.json is gitignored (one dev's choice never commits into
#      a teammate's repo), asserted against the real shipped .gitignore.
#
# Hermetic: throwaway HOME + repo dirs; the wire server is localhost-only; no real GCP, no
# network off-box. Exit 0 = every proof holds.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="$REPO/bin/heimdall-presence"
LIB="$REPO/bin/lib"
SL="$REPO/sentinels/hmd-statusline.py"
export LIB REPO
# DEFAULT-ON egress guard: pin the baked-in CP default at a dead port so no un-pinned presence
# call (e.g. `off`, which emits a retire beat) resolves the REAL production control plane under
# an undecided consent. Explicit per-invocation HEIMDALL_CP_URL/--url pins still win.
. "$REPO/test/lib/net-default-guard.sh"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing/not executable" >&2; exit 2; }
[ -f "$LIB/cp_presence.py" ] || { echo "FATAL: cp_presence.py missing" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMP="$(mktemp -d -t hmd-optout)"
cleanup() { [ -n "${WIRE_PID:-}" ] && kill "$WIRE_PID" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# 1. CLI TOGGLES + STORAGE
# ══════════════════════════════════════════════════════════════════════════════
echo "1. CLI toggles write + read back the durable local state"
H1="$TMP/home1"; R1="$TMP/repo1"; mkdir -p "$H1" "$R1"
STATE_DIR="$R1/.heimdall"
run1() { HOME="$H1" HEIMDALL_PRESENCE_DIR="$STATE_DIR" HEIMDALL_CP_URL="http://127.0.0.1:1" \
         HMD_HAID="haid:t1" "$BIN" "$@"; }

run1 off >/dev/null 2>&1
if [ -f "$STATE_DIR/presence.json" ] && grep -q '"enabled": false' "$STATE_DIR/presence.json"; then
  ok "1a off -> per-repo .heimdall/presence.json {\"enabled\": false}"
else
  bad "1a off did not write presence.json {enabled:false}"
fi

run1 on >/dev/null 2>&1
if grep -q '"enabled": true' "$STATE_DIR/presence.json" && ! grep -q '"files": false' "$STATE_DIR/presence.json"; then
  ok "1b on -> {\"enabled\": true} (repo re-enabled, no file-withhold)"
else
  bad "1b on did not re-enable the repo"
fi

run1 on --no-files >/dev/null 2>&1
if grep -q '"files": false' "$STATE_DIR/presence.json" && grep -q '"enabled": true' "$STATE_DIR/presence.json"; then
  ok "1c on --no-files -> {\"enabled\": true, \"files\": false} (present, file detail withheld)"
else
  bad "1c on --no-files did not set files:false"
fi

run1 off --global >/dev/null 2>&1
if [ -f "$H1/.heimdall/presence-off" ]; then
  ok "1d off --global -> ~/.heimdall/presence-off exists (machine-wide kill switch)"
else
  bad "1d off --global did not create the global stamp"
fi

run1 on --global >/dev/null 2>&1
if [ ! -f "$H1/.heimdall/presence-off" ]; then
  ok "1e on --global -> global stamp removed"
else
  bad "1e on --global did not remove the global stamp"
fi

# status prints the asymmetry ("you can SEE the team; the team cannot see you")
run1 off >/dev/null 2>&1
STAT="$(run1 status 2>/dev/null)"
if grep -q "effective: OFF" <<<"$STAT" \
   && grep -qi "you can still SEE the team; the team cannot see you" <<<"$STAT"; then
  ok "1f status shows effective OFF + the SEE/see-you asymmetry note"
else
  bad "1f status missing effective-OFF or the asymmetry note -- got: $STAT"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. OFF = ZERO BEATS (bash guard, falsifiable via the enroll-attempt stamp)
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "2. off = zero beats: a beat never reaches bootstrap/network when off (falsifiable)"
H2="$TMP/home2"; R2="$TMP/repo2"; mkdir -p "$H2" "$R2"
beat2() { HOME="$H2" HEIMDALL_PRESENCE_DIR="$R2/.heimdall" HMD_ENROLL_THROTTLE=0 \
          "$BIN" beat --haid haid:t2 --project acme/widget --url http://127.0.0.1:1 --handle t2; }

# ON: the beat reaches _bootstrap_seed, which writes an enroll-attempt stamp BEFORE the
# (unreachable) enroll -> the stamp is the observable proof the network path was entered.
rm -rf "$H2/.heimdall/pki"
beat2 >/dev/null 2>&1
if ls "$H2"/.heimdall/pki/*.enroll-attempt >/dev/null 2>&1; then
  ok "2a ON: a beat enters bootstrap (enroll-attempt stamp written) -- the network path runs"
else
  bad "2a ON: no enroll-attempt stamp -- the ON beat never attempted (test setup wrong)"
fi

# OFF: the early stat-only guard no-ops the beat BEFORE run_client -> NO enroll-attempt stamp.
# FALSIFIER: remove the `_pres_off && beat_noop` guard and this stamp reappears -> RED.
rm -rf "$H2/.heimdall/pki"
: > "$H2/.heimdall/presence-off"   # global off
mkdir -p "$H2/.heimdall" && : > "$H2/.heimdall/presence-off"
BEAT_RC=0; beat2 >/dev/null 2>&1 || BEAT_RC=$?
if ! ls "$H2"/.heimdall/pki/*.enroll-attempt >/dev/null 2>&1 && [ "$BEAT_RC" -eq 0 ]; then
  ok "2b OFF: the beat is a stat-only no-op (exit 0, NO enroll-attempt stamp) -- can't leak around the toggle"
else
  bad "2b OFF: the beat still hit bootstrap (stamp present) or non-zero exit ($BEAT_RC)"
fi
rm -f "$H2/.heimdall/presence-off"

# ══════════════════════════════════════════════════════════════════════════════
# 3. RETIRE at the READ AUTHORITY (cp_presence module) — the beat-stamp falsifier
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "3. retire -> gone from a fresh roster read (server read-authority, falsifiable)"
H3="$TMP/home3"; mkdir -p "$H3"
HEIMDALL_HOME="$H3" HEIMDALL_STATE_BACKEND=local "$PY" - > "$TMP/r3.out" 2>"$TMP/r3.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = "acme/widget"; tid = "0123456789abcdef0123456789abcdef"; a = "haid:rj.a"
P.record_presence(a, project=proj, team_id=tid, handle="rj", verdict="building", file="src/app.py")
before = [x.get("haid") for x in P.roster(proj, tid)]
P.record_retire(a, project=proj, team_id=tid)                       # opt-out tombstone
after = [x.get("haid") for x in P.roster(proj, tid)]
# the tombstone IS durably stored (retired flag) -- the roster filter is what hides it:
rec = P._backend(None).get_record(P._record_rel(proj, tid, a))
stored_retired = bool(rec and rec.get("retired"))
P.record_presence(a, project=proj, team_id=tid, handle="rj", verdict="building", file="src/app.py")
reopt = [x.get("haid") for x in P.roster(proj, tid)]                # re-opt-in beat
print(json.dumps({"before": before, "after": after, "stored_retired": stored_retired, "reopt": reopt}))
PYEOF
R3_OUT="$(cat "$TMP/r3.out")"
if [ -s "$TMP/r3.err" ]; then bad "3 module raised: $(cat "$TMP/r3.err")"; fi
b_has=$(printf '%s' "$R3_OUT" | "$PY" -c "import json,sys;print('haid:rj.a' in json.load(sys.stdin)['before'])" 2>/dev/null)
a_has=$(printf '%s' "$R3_OUT" | "$PY" -c "import json,sys;print('haid:rj.a' in json.load(sys.stdin)['after'])" 2>/dev/null)
stored=$(printf '%s' "$R3_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['stored_retired'])" 2>/dev/null)
re_has=$(printf '%s' "$R3_OUT" | "$PY" -c "import json,sys;print('haid:rj.a' in json.load(sys.stdin)['reopt'])" 2>/dev/null)
[ "$b_has" = "True" ]  && ok "3a a live-beating dev IS on the roster" || bad "3a dev missing before retire -- $R3_OUT"
[ "$a_has" = "False" ] && ok "3b after retire the dev is GONE from a fresh roster (prompt disappearance, no TTL wait)" || bad "3b retired dev STILL on the roster -- read-authority not enforced (RED) -- $R3_OUT"
[ "$stored" = "True" ] && ok "3c FALSIFIER: the tombstone {retired:true} IS in the store -- roster's filter, not deletion, hides it (drop the filter -> reappears -> RED)" || bad "3c tombstone not stored with retired flag -- $R3_OUT"
[ "$re_has" = "True" ] && ok "3d re-opt-in: a normal beat overwrites the tombstone -> the dev REAPPEARS" || bad "3d re-opt-in did not restore presence -- $R3_OUT"

# ══════════════════════════════════════════════════════════════════════════════
# 4. SCOPE — per-repo does not silence elsewhere; global silences both
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "4. scope: repo-off != elsewhere; global-off = everywhere; on restores each scope"
H4="$TMP/home4"; RA="$TMP/repoA"; RB="$TMP/repoB"; mkdir -p "$H4" "$RA" "$RB"
eff() { HOME="$H4" HEIMDALL_PRESENCE_DIR="$1/.heimdall" HEIMDALL_CP_URL="http://127.0.0.1:1" \
        HMD_HAID="haid:t4" "$BIN" status 2>/dev/null | sed -n 's/.*effective: \([A-Z]*\).*/\1/p'; }
setoff() { HOME="$H4" HEIMDALL_PRESENCE_DIR="$1/.heimdall" HMD_HAID="haid:t4" "$BIN" "${@:2}" >/dev/null 2>&1; }

setoff "$RA" off                                   # repo A off, repo B untouched
[ "$(eff "$RA")" = "OFF" ] && [ "$(eff "$RB")" = "ON" ] \
  && ok "4a repo-off in A does NOT silence B (A=OFF, B=ON)" \
  || bad "4a per-repo scope leaked (A=$(eff "$RA") B=$(eff "$RB"))"

HOME="$H4" mkdir -p "$H4/.heimdall" && : > "$H4/.heimdall/presence-off"   # global off
[ "$(eff "$RA")" = "OFF" ] && [ "$(eff "$RB")" = "OFF" ] \
  && ok "4b global-off silences BOTH repos (A=OFF, B=OFF)" \
  || bad "4b global-off did not silence both (A=$(eff "$RA") B=$(eff "$RB"))"

rm -f "$H4/.heimdall/presence-off"                 # global back on
setoff "$RA" on                                    # A re-enabled
[ "$(eff "$RA")" = "ON" ] && [ "$(eff "$RB")" = "ON" ] \
  && ok "4c on restores each scope independently (A=ON, B=ON)" \
  || bad "4c on did not restore scopes (A=$(eff "$RA") B=$(eff "$RB"))"

# module: retirement is per-(project,team) — retiring in project P1 leaves P2 visible.
HEIMDALL_HOME="$TMP/home4b" HEIMDALL_STATE_BACKEND=local "$PY" - > "$TMP/s4.out" 2>/dev/null <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
tid="0123456789abcdef0123456789abcdef"; a="haid:rj.a"
P.record_presence(a, project="p1", team_id=tid, handle="rj", verdict="x", file="f")
P.record_presence(a, project="p2", team_id=tid, handle="rj", verdict="x", file="f")
P.record_retire(a, project="p1", team_id=tid)
print(json.dumps({"p1":[x["haid"] for x in P.roster("p1",tid)], "p2":[x["haid"] for x in P.roster("p2",tid)]}))
PYEOF
S4="$(cat "$TMP/s4.out")"
p1=$(printf '%s' "$S4" | "$PY" -c "import json,sys;print('haid:rj.a' in json.load(sys.stdin)['p1'])" 2>/dev/null)
p2=$(printf '%s' "$S4" | "$PY" -c "import json,sys;print('haid:rj.a' in json.load(sys.stdin)['p2'])" 2>/dev/null)
[ "$p1" = "False" ] && [ "$p2" = "True" ] \
  && ok "4d retirement is per-project: retire in p1 -> gone from p1, still present in p2" \
  || bad "4d retirement scope wrong (p1=$p1 p2=$p2) -- $S4"

# ══════════════════════════════════════════════════════════════════════════════
# 5. WIRE BEHAVIOR — real signed HTTP to a recording server
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "5. wire: --no-files sends file:null; off POSTs a retire beat; off-beat sends nothing"
REC="$TMP/rec"; mkdir -p "$REC"
cat >"$TMP/recsrv.py" <<'PYEOF'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
REC = os.environ["REC_DIR"]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): return
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _rec(self, name, raw):
        with open(os.path.join(REC, name), "ab") as fh: fh.write(raw + b"\n")
    def do_POST(self):
        raw = self._body(); path = self.path.split("?")[0]
        if path == "/enroll": return self._send(200, {"enrolled": True})
        if path == "/presence": self._rec("presence.jsonl", raw); return self._send(200, {"recorded": True})
        if path == "/presence-retire": self._rec("retire.jsonl", raw); return self._send(200, {"retired": True})
        return self._send(404, {"error": "nf"})
    def do_GET(self):
        if self.path.split("?")[0] == "/roster": return self._send(200, {"roster": []})
        return self._send(404, {"error": "nf"})
srv = HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(REC, "port"), "w") as fh: fh.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
REC_DIR="$REC" "$PY" "$TMP/recsrv.py" &
WIRE_PID=$!
for _ in $(seq 1 40); do [ -s "$REC/port" ] && break; "$PY" -c "import time;time.sleep(0.1)"; done
PORT="$(cat "$REC/port" 2>/dev/null || true)"
HW="$TMP/homeW"; RW="$TMP/repoW"; mkdir -p "$HW" "$RW"
wire() { HOME="$HW" HEIMDALL_PRESENCE_DIR="$RW/.heimdall" HMD_ENROLL_THROTTLE=0 \
         "$BIN" "$@" --haid haid:tw --project acme/widget --url "http://127.0.0.1:$PORT"; }
wtoggle() { HOME="$HW" HEIMDALL_PRESENCE_DIR="$RW/.heimdall" HMD_ENROLL_THROTTLE=0 \
            "$BIN" "$@" --haid haid:tw --project acme/widget --url "http://127.0.0.1:$PORT"; }

if [ -z "$PORT" ]; then
  bad "5* recording server never bound a port -- skipping wire assertions"
else
  # a normal beat carries the file field
  wire beat --handle tw --verdict building --file src/app.py >/dev/null 2>&1
  LAST_FILE="$(tail -n1 "$REC/presence.jsonl" 2>/dev/null | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('file'))" 2>/dev/null)"
  [ "$LAST_FILE" = "src/app.py" ] \
    && ok "5a a normal beat sends the current file (file='src/app.py')" \
    || bad "5a normal beat file wrong (got '$LAST_FILE')"

  # on --no-files -> the beat body has file:null but handle+verdict present
  wtoggle on --no-files >/dev/null 2>&1
  wire beat --handle tw --verdict building --file src/app.py >/dev/null 2>&1
  NF="$(tail -n1 "$REC/presence.jsonl" 2>/dev/null | "$PY" -c "import json,sys;d=json.load(sys.stdin);print('%s|%s|%s'%(d.get('file'),d.get('handle'),d.get('verdict')))" 2>/dev/null)"
  [ "$NF" = "None|tw|building" ] \
    && ok "5b --no-files: beat body is file:null with handle+verdict PRESENT ($NF)" \
    || bad "5b --no-files beat body wrong (want None|tw|building, got '$NF')"

  # off emits ONE retire beat to /presence-retire (active disappearance)
  wtoggle on >/dev/null 2>&1                         # back on so the seed is live
  : > "$REC/retire.jsonl"
  wtoggle off >/dev/null 2>&1
  RETIRED_PROJ="$(tail -n1 "$REC/retire.jsonl" 2>/dev/null | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('project'))" 2>/dev/null)"
  [ "$RETIRED_PROJ" = "acme/widget" ] \
    && ok "5c off POSTs a signed retire beat to /presence-retire (project='acme/widget')" \
    || bad "5c off did not emit a retire beat (got '$RETIRED_PROJ')"

  # while off, a subsequent beat sends NOTHING (defense in depth, wire-observed)
  BEFORE_N="$(wc -l < "$REC/presence.jsonl" 2>/dev/null | tr -d ' ')"
  wire beat --handle tw --verdict building --file src/app.py >/dev/null 2>&1
  AFTER_N="$(wc -l < "$REC/presence.jsonl" 2>/dev/null | tr -d ' ')"
  [ "$BEFORE_N" = "$AFTER_N" ] \
    && ok "5d while off, a beat sends NOTHING over the wire (no new /presence line)" \
    || bad "5d an off beat still POSTed /presence ($BEFORE_N -> $AFTER_N)"
fi
kill "$WIRE_PID" >/dev/null 2>&1 || true; WIRE_PID=""

# ══════════════════════════════════════════════════════════════════════════════
# 6. OPT-OUT VISIBILITY — the statusline .beat-stamp consent gate + the farewell invite tease
# ══════════════════════════════════════════════════════════════════════════════
# The v1 statusline (feat(statusline): rewrite to the v1 full-bleed 3-row layout) is a FIXED
# 4-row render — heimdall-statusline-width.test.sh pins EXACTLY 4 non-empty rows — so a
# per-render tease/off-hint row was RETIRED by design (it would break the row invariant). The
# statusline's falsifiable opt-out proof is therefore the .beat-stamp: an ON render ARMS a beat
# (stamp written), an OFF render writes NONE (the toggle short-circuits the fork). The solo
# invite tease was RELOCATED to the session-end farewell (sentinels/hmd-farewell.sh, which even
# comments "mirrors the statusline solo tease"); we prove the tease + its opt-out suppression
# there — its real home now.
echo
echo "6. opt-out visibility: statusline .beat-stamp gate + the farewell invite tease (relocated)"
HS="$TMP/homeS"; mkdir -p "$HS/.heimdall"
render() {  # $1 = workspace dir
  env -i PATH="$PATH" HOME="$HS" HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS=120 \
    LANG=en_US.UTF-8 "$PY" "$SL" <<EOF
{"workspace":{"current_dir":"$1"}}
EOF
}
FARE="$REPO/sentinels/hmd-farewell.sh"
farewell() {  # $1 = a NON-git workspace dir -> the farewell resolves HMD_REPO_DIR to $1/.heimdall
  ( cd "$1" && env -i PATH="$PATH" HOME="$HS" HEIMDALL_HOME="$HS/.heimdall" \
      TERM=dumb NO_COLOR=1 HEIMDALL_NO_INTRO=1 bash "$FARE" 2>/dev/null )
}

# ON render (no presence.json): the beat is ARMED — a .beat-stamp IS written.
RON_DIR="$TMP/slon"; mkdir -p "$RON_DIR/.heimdall"
render "$RON_DIR" >/dev/null 2>&1
if [ -f "$RON_DIR/.heimdall/.beat-stamp" ]; then
  ok "6a FALSIFIER: ON render WRITES .beat-stamp (the beat is armed when present)"
else
  bad "6a ON render did not write .beat-stamp -- the beat-stamp falsifier is inert"
fi

# OFF render (presence.json {enabled:false}): NO beat-stamp is written (zero beats).
ROFF_DIR="$TMP/sloff"; mkdir -p "$ROFF_DIR/.heimdall"
printf '{"enabled": false}\n' > "$ROFF_DIR/.heimdall/presence.json"
render "$ROFF_DIR" >/dev/null 2>&1
if [ ! -f "$ROFF_DIR/.heimdall/.beat-stamp" ]; then
  ok "6b OFF render writes NO .beat-stamp (zero beats; drop the guard -> stamp appears -> RED)"
else
  bad "6b OFF render wrote a .beat-stamp -- the off dev still beats (RED)"
fi

# The invite tease's REAL home (relocated off the statusline): a SOLO, presence-ON farewell
# prints "invite your team · hmd invite" (the growth beat); an OPTED-OUT farewell SUPPRESSES it.
FARE_ON="$TMP/fare_on"; mkdir -p "$FARE_ON/.heimdall"
FOUT_ON="$(farewell "$FARE_ON")"
if grep -q "hmd invite" <<<"$FOUT_ON"; then
  ok "6c a solo, presence-ON farewell shows the invite tease (hmd invite) — the tease's real home"
else
  bad "6c solo-ON farewell missing the invite tease -- $(printf '%s' "$FOUT_ON" | tail -n2)"
fi
FARE_OFF="$TMP/fare_off"; mkdir -p "$FARE_OFF/.heimdall"
printf '{"enabled": false}\n' > "$FARE_OFF/.heimdall/presence.json"
FOUT_OFF="$(farewell "$FARE_OFF")"
if ! grep -q "hmd invite" <<<"$FOUT_OFF"; then
  ok "6d FALSIFIER: an OPTED-OUT farewell SUPPRESSES the invite (an invite would be a lie when invisible)"
else
  bad "6d opted-out farewell still showed the invite tease -- the dev is invisible, the invite lies"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7. GITIGNORE — presence.json never commits into a teammate's repo
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "7. .heimdall/presence.json is gitignored (shipped .gitignore)"
if git -C "$REPO" check-ignore .heimdall/presence.json >/dev/null 2>&1; then
  ok "7a .heimdall/presence.json is gitignored (one dev's opt-out never lands in a teammate's repo)"
else
  bad "7a .heimdall/presence.json is NOT gitignored -- a dev's opt-out could be committed"
fi

echo
echo "============================================================"
printf "heimdall-presence-optout: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

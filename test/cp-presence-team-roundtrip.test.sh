#!/usr/bin/env bash
# cp-presence-team-roundtrip.test.sh — BUG2 REGRESSION GATE: an enrolled client's signed BEAT
# must appear in the SAME (team_secret, project) it reads back from GET /roster-team, within the
# TTL. The FALSIFIED root cause (the "viral-loop gate"): the WRITE partition was derived from the
# enroll-time registry binding (cp_auth.registered_team(haid)) while the READ partition
# (roster-team) is derived from the PRESENTED team.json secret (cp_auth.derive_team_id(secret)).
# For a LEGACY binding (no team_id) or a STALE binding (enrolled under a different/older secret),
# those two partitions DIFFER, so a valid beat lands in a black-hole partition the roster read
# never enumerates → the beater is INVISIBLE to its own team roster.
#
# THE FIX under test: the beat (and retire, and the signed self /roster) resolve their partition
# from the PRESENTED team_secret (the X-Heimdall-Team-Secret header cp_server lifts to
# request["team_secret"]) — the SAME capability the browser /roster-team read hashes — falling
# back to the registry binding ONLY when no secret is presented. Write-partition == read-partition
# ⇒ the round-trip closes on ONE derived partition.
#
# PROOFS (hermetic — the LOCAL state backend, NO firestore, NO live creds, NO network):
#   A. ROUND-TRIP: a LEGACY-bound dev (binding has NO team_id) beats WITH the team secret →
#      roster-team(project, SAME secret) SHOWS the dev (NOT empty). This is the exact BUG2 case.
#   B. ISOLATION FALSIFIER: beat under secret S, then roster-team(project, DIFFERENT secret S2) →
#      empty (no cross-team leak — the presented capability, not the identity, scopes the read).
#   C. BACK-COMPAT: a beat with NO secret presented falls back to the enroll binding
#      (registered_team) → a dev enrolled under S still round-trips via roster-team(S).
#   D. RETIRE symmetry: a retire WITH the secret tombstones the SAME partition the beat wrote,
#      so the dev drops from roster-team(S) on the next read.
#   E. LOUD FAILURE: `bin/heimdall-presence beat` whose POST cannot be delivered no longer fakes
#      success — it surfaces a one-line diagnostic on stderr, and exits NONZERO under
#      HMD_PRESENCE_STRICT=1 (while the default statusline path stays exit 0, stdout clean).
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
PRESENCE_CLI="$REPO/bin/heimdall-presence"
export LIB REPO

for f in cp_auth cp_presence cp_publicsurface cp_server cp_state; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$PRESENCE_CLI" ] || { echo "FATAL: $PRESENCE_CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "cp-presence-rt.XXXXXX")"
export HEIMDALL_HOME="$EXT/home"
mkdir -p "$HEIMDALL_HOME"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

PROJECT="acme/widget"
SECRET="team-secret-RTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"   # >= 32 chars (the client mints 43).
OTHER="team-secret-RTZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
export PROJECT SECRET OTHER

echo "============================================================"
echo "BUG2 viral-loop gate — beat<->roster-team round-trip on ONE derived partition"
echo "  home=$HEIMDALL_HOME  (local backend)"
echo "============================================================"
echo

# ──────────────────────────────────────────────────────────────────────────────
# A. ROUND-TRIP — a LEGACY-bound dev beats WITH the secret → roster-team(SAME secret) SHOWS it.
# ──────────────────────────────────────────────────────────────────────────────
echo "A. a LEGACY-bound (no team_id) dev's signed beat WITH the secret appears in roster-team(SAME secret)"
A_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>"$EXT/a.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence as P
HOME = os.environ["HEIMDALL_HOME"]
haid = "haid:rj.mbp-legacy"
_, pub = cp_auth.generate_keypair()
cp_auth.register_key(haid, pub, owner=False)                 # LEGACY binding: NO team_id field.
# The signed beat, WITH the team secret in the lifted header slot (request["team_secret"]).
req = {"team_secret": os.environ["SECRET"],
       "body": json.dumps({"project": os.environ["PROJECT"], "handle": "rj",
                           "verdict": "building", "file": "x.py"})}
beat = P.beat_route(cp_auth.Identity(haid), req, home=HOME)
# roster-team reads the partition derived from the SAME secret.
rt = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
                          "query": {"project": os.environ["PROJECT"]},
                          "team_secret": os.environ["SECRET"], "peer_ip": "10.0.0.1"}, home=HOME)
online = rt.body.get("online", [])
print(json.dumps({"beat_status": beat.status,
                  "beat_team": beat.body.get("team_id"),
                  "rt_status": rt.status,
                  "haids": [r.get("haid") for r in online]}))
PYEOF
)"
A_SEEN="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print('haid:rj.mbp-legacy' in d['haids'] and d['rt_status']==200)" 2>/dev/null)"
if [ "$A_SEEN" = "True" ]; then
  ok "A1 the legacy-bound dev's beat is VISIBLE in roster-team(same secret) — write==read partition ($A_OUT)"
else
  bad "A1 the beat was INVISIBLE to its own roster-team (BUG2 not fixed) — out=$A_OUT"; cat "$EXT/a.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# B. ISOLATION FALSIFIER — a DIFFERENT secret on the same project → empty (no cross-team leak).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "B. ISOLATION: beat under S, then roster-team(project, DIFFERENT secret) → empty (no cross-team)"
B_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence as P
HOME = os.environ["HEIMDALL_HOME"]
rt = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
                          "query": {"project": os.environ["PROJECT"]},
                          "team_secret": os.environ["OTHER"], "peer_ip": "10.0.0.2"}, home=HOME)
print(json.dumps({"status": rt.status, "online": rt.body.get("online")}))
PYEOF
)"
B_EMPTY="$(printf '%s' "$B_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d['status']==200 and d['online']==[])" 2>/dev/null)"
[ "$B_EMPTY" = "True" ] \
  && ok "B1 a DIFFERENT secret sees NONE of team S's beats (isolation holds — out=$B_OUT)" \
  || bad "B1 a different secret leaked team S's roster (out=$B_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# C. BACK-COMPAT — a beat with NO secret falls back to the enroll binding (registered_team).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "C. BACK-COMPAT: a beat with NO secret uses the enroll binding; roster-team(enroll secret) shows it"
C_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence as P
HOME = os.environ["HEIMDALL_HOME"]
haid = "haid:rj.mbp-bound"
_, pub = cp_auth.generate_keypair()
# Enrolled UNDER the secret: the binding team_id equals derive_team_id(SECRET).
cp_auth.register_key(haid, pub, owner=False, team_id=cp_auth.derive_team_id(os.environ["SECRET"]))
# Beat with NO team_secret presented → must fall back to registered_team(haid).
beat = P.beat_route(cp_auth.Identity(haid),
                    {"body": json.dumps({"project": os.environ["PROJECT"], "handle": "bound"})},
                    home=HOME)
rt = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
                          "query": {"project": os.environ["PROJECT"]},
                          "team_secret": os.environ["SECRET"], "peer_ip": "10.0.0.3"}, home=HOME)
print(json.dumps({"beat_status": beat.status,
                  "seen": any(r.get("haid") == haid for r in rt.body.get("online", []))}))
PYEOF
)"
C_OK="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d['beat_status']==200 and d['seen'])" 2>/dev/null)"
[ "$C_OK" = "True" ] \
  && ok "C1 a secret-less beat still lands in the enroll-bound team (fallback intact — out=$C_OUT)" \
  || bad "C1 the secret-less fallback broke (out=$C_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# D. RETIRE symmetry — a retire WITH the secret drops the dev from roster-team(same secret).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "D. RETIRE(secret) tombstones the SAME partition the beat wrote → dropped from roster-team(S)"
D_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence as P
HOME = os.environ["HEIMDALL_HOME"]
haid = "haid:rj.mbp-legacy"   # the same dev from A (beat under SECRET).
ret = P.retire_route(cp_auth.Identity(haid),
                     {"team_secret": os.environ["SECRET"],
                      "body": json.dumps({"project": os.environ["PROJECT"]})},
                     home=HOME)
rt = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
                          "query": {"project": os.environ["PROJECT"]},
                          "team_secret": os.environ["SECRET"], "peer_ip": "10.0.0.4"}, home=HOME)
print(json.dumps({"retire_status": ret.status,
                  "still_present": any(r.get("haid") == haid for r in rt.body.get("online", []))}))
PYEOF
)"
D_OK="$(printf '%s' "$D_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d['retire_status']==200 and not d['still_present'])" 2>/dev/null)"
[ "$D_OK" = "True" ] \
  && ok "D1 a retire(secret) drops the dev from roster-team(same secret) — retire==beat partition (out=$D_OUT)" \
  || bad "D1 retire did not tombstone the beat's partition (out=$D_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# E. LOUD FAILURE — a beat whose POST cannot be delivered surfaces on stderr; nonzero under STRICT.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "E. LOUD FAILURE: an undeliverable beat surfaces on stderr (nonzero under HMD_PRESENCE_STRICT=1)"
# Drive the REAL client: a provided seed skips enroll; an unreachable URL forces a transport drop.
# Isolate HOME + team dir so the client neither reads global toggles nor writes into the repo.
BEAT_HOME="$EXT/client-home"; mkdir -p "$BEAT_HOME"
TEAM_DIR="$EXT/client-team"; mkdir -p "$TEAM_DIR"
SEED="$("$PY" -c "import os,sys;sys.path.insert(0,os.environ['LIB']);import cp_auth;print(cp_auth.generate_keypair()[0])")"
common_env=(HOME="$BEAT_HOME" HEIMDALL_TEAM_DIR="$TEAM_DIR" HEIMDALL_PRESENCE_DIR="$TEAM_DIR"
            HMD_PRESENCE_SEED="$SEED" HMD_HAID="haid:loud.test"
            HMD_PROJECT="loud/proj" HMD_HANDLE="loud"
            HEIMDALL_CP_URL="http://127.0.0.1:9")   # port 9 (discard) → connection refused.

# STRICT: must exit nonzero AND emit a diagnostic on stderr.
set +e
STRICT_ERR="$(env "${common_env[@]}" HMD_PRESENCE_STRICT=1 "$PRESENCE_CLI" beat 2>&1 1>/dev/null)"
STRICT_RC=$?
set -e
if [ "$STRICT_RC" -ne 0 ] && printf '%s' "$STRICT_ERR" | grep -qi "beat"; then
  ok "E1 STRICT: an undeliverable beat exits nonzero ($STRICT_RC) with a stderr diagnostic ($STRICT_ERR)"
else
  bad "E1 STRICT: the undeliverable beat faked success (rc=$STRICT_RC, err='$STRICT_ERR')"
fi

# DEFAULT (statusline path): exit 0, stdout CLEAN, but the diagnostic still reaches stderr.
set +e
DEF_ERR="$(env "${common_env[@]}" "$PRESENCE_CLI" beat 2>"$EXT/def.err" 1>"$EXT/def.out")"
DEF_RC=$?
set -e
DEF_STDERR="$(cat "$EXT/def.err")"
DEF_STDOUT="$(cat "$EXT/def.out")"
if [ "$DEF_RC" -eq 0 ] && [ -z "$DEF_STDOUT" ] && printf '%s' "$DEF_STDERR" | grep -qi "beat"; then
  ok "E2 DEFAULT: exit 0 + clean stdout (statusline-safe) yet the drop is NAMED on stderr ($DEF_STDERR)"
else
  bad "E2 DEFAULT: expected exit0/clean-stdout/stderr-diagnostic (rc=$DEF_RC, out='$DEF_STDOUT', err='$DEF_STDERR')"
fi

echo
echo "============================================================"
printf "cp-presence-team-roundtrip: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

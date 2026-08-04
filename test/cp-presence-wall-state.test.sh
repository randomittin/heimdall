#!/usr/bin/env bash
# cp-presence-wall-state.test.sh — FALSIFIER: the ACTIVE / IDLE / OFFLINE wall-state model.
#
# THE MODEL (wave 1, additive + backward-compatible). A beat carries ONE new optional field,
# `activity_ts` (epoch seconds — client-owned, bumped by the edit hook + an active verdict).
# The server DERIVES a per-dev wall state from two clocks, with NO privacy shift:
#
#   • OFFLINE — the heartbeat `ts` is older than the online TTL (~45s). The dev is DROPPED
#     from the roster entirely (unchanged from the prior model).
#   • ACTIVE  — online (ts within TTL) AND `activity_ts` is within the ACTIVITY window
#     (recent real work — an edit/verdict). Rendered ● active.
#   • IDLE    — online (ts within TTL) but activity_ts is stale OR absent (beating — a keeper
#     or daemon heartbeat — but not actively working). Rendered ○ idle. THE POINT: an idle
#     beater STAYS ON THE WALL (it does not drop); the model only DEMOTES it to idle.
#
# RED-WITHOUT-FIX: every proof reads `roster(...)[i]["state"]` and calls
# cp_presence.derive_state(...). On the pre-fix store there is no derive_state and no "state"
# key on a roster view → KeyError / AttributeError → the proofs FAIL. With the fix the state is
# derived from the injected clock (now) + the record's two timestamps, deterministically.
#
# INJECTED-CLOCK TRACE (not a fixed yield): C proves the SAME record flips active→idle purely by
# advancing `now` past the activity window while STAYING inside the online TTL — the clock, not
# the data, decides the state, and the dev never drops off the wall across that flip.
#
# HERMETIC: the LOCAL StateBackend (NDJSON under HEIMDALL_HOME), no firestore, no CP, no network.
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO
[ -f "$LIB/cp_presence.py" ] || { echo "FATAL: cp_presence.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMP="$(mktemp -d -t "presence-wallstate.XXXXXX")"
export HEIMDALL_HOME="$TMP/home"; mkdir -p "$HEIMDALL_HOME"
export HEIMDALL_STATE_BACKEND="local"
trap 'rm -rf "$TMP"' EXIT

PROJECT="acme/widget"
TEAM_ID="0123456789abcdef0123456789abcdef"
export PROJECT TEAM_ID

echo "============================================================"
echo "PRESENCE WALL-STATE falsifier — active / idle / offline derivation"
echo "  home=$HEIMDALL_HOME  (local backend, injected clock)"
echo "============================================================"
echo

# The one hermetic driver: seed three devs with distinct (ts, activity_ts) shapes, then read
# the roster at an INJECTED now (+ TTL) and report each dev's derived state. Also exercises
# derive_state() directly on a single record so the unit is falsifiable in isolation.
OUT="$(TTL=45 ACT=120 "$PY" - <<'PYEOF' 2>"$TMP/err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P

proj, tid = os.environ["PROJECT"], os.environ["TEAM_ID"]
home = os.environ["HEIMDALL_HOME"]
ttl, act = float(os.environ["TTL"]), float(os.environ["ACT"])
NOW = 10_000.0

# devA — ACTIVE: beating now, edited 5s ago (well inside the activity window).
P.record_presence("haid:a", project=proj, team_id=tid, handle="a", verdict="working",
                  file="x.py", ts=NOW - 5, activity_ts=NOW - 5, home=home)
# devB — IDLE: beating now (10s old ts, inside TTL) but last activity 300s ago (past window).
P.record_presence("haid:b", project=proj, team_id=tid, handle="b", verdict="watching",
                  file="-", ts=NOW - 10, activity_ts=NOW - 300, home=home)
# devC — IDLE via ABSENT activity_ts (backward-compat: an old client / bare keeper beat).
P.record_presence("haid:c", project=proj, team_id=tid, handle="c", verdict="working",
                  file="y.py", ts=NOW - 8, home=home)
# devD — OFFLINE: ts 500s old (> the 45s TTL) but well inside the 7-day wall window, so it
# stays on the roster carrying the explicit "offline" state. It must NOT read active/idle.
P.record_presence("haid:d", project=proj, team_id=tid, handle="d", verdict="working",
                  file="z.py", ts=NOW - 500, activity_ts=NOW - 500, home=home)
# devE — GONE: ts 8 days old, past the wall window entirely. Must not appear at all.
P.record_presence("haid:e", project=proj, team_id=tid, handle="e", verdict="working",
                  file="w.py", ts=NOW - 8 * 86400, activity_ts=NOW - 8 * 86400, home=home)

def states(now):
    r = P.roster(proj, tid, home=home, now=now, ttl=ttl, activity_ttl=act)
    return {row["haid"]: row.get("state") for row in r}

s_now = states(NOW)

# INJECTED-CLOCK TRACE: advance now so devA's activity (NOW-5) is now 200s old (past the 120s
# activity window) but its ts (NOW-5) is only 200s... that would also breach the 45s TTL. To
# keep devA ONLINE while its activity ages out, re-beat devA's TS forward (a keeper heartbeat
# with NO fresh activity) and advance the clock: ts fresh, activity stale => active -> idle.
P.record_presence("haid:a", project=proj, team_id=tid, handle="a", verdict="working",
                  file="x.py", ts=NOW + 190, home=home)   # keeper beat, NO activity_ts bump
s_later = states(NOW + 200)   # devA: ts 10s old (online) but last activity 205s ago (idle)

# derive_state() unit — the window decides, both directions, on ONE record.
recA = {"haid": "u", "ts": NOW, "activity_ts": NOW - 5}
unit_active = P.derive_state(recA, now=NOW, activity_ttl=act)
unit_idle   = P.derive_state(recA, now=NOW + 300, activity_ttl=act)   # same record, later clock

print(json.dumps({
    "now": s_now,
    "later_a": s_later.get("haid:a"),
    "on_now": sorted(s_now.keys()),
    "unit_active": unit_active,
    "unit_idle": unit_idle,
}))
PYEOF
)"
[ -s "$TMP/err" ] && { echo "  python stderr:"; sed 's/^/    /' "$TMP/err"; }

get() { printf '%s' "$OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

# A. ACTIVE — fresh ts + fresh activity_ts.
[ "$(get "d['now']['haid:a']")" = "active" ] \
  && ok "A devA (beating + edited 5s ago) derives ACTIVE" \
  || bad "A devA is not ACTIVE (out=$OUT)"

# B. IDLE — beating but activity is stale (devB) OR absent (devC). Crucially STILL on the wall.
B_ON="$(get "'haid:b' in d['on_now'] and 'haid:c' in d['on_now']")"
if [ "$B_ON" = "True" ] \
   && [ "$(get "d['now']['haid:b']")" = "idle" ] \
   && [ "$(get "d['now']['haid:c']")" = "idle" ]; then
  ok "B IDLE-SHOWS-NOT-DROPS: devB (stale activity) + devC (no activity_ts) stay on the wall as IDLE"
else
  bad "B an idle beater dropped or mis-derived (on_now/states wrong — out=$OUT)"
fi

# C. OFFLINE — ts past the TTL but inside the 7-day wall window => STAYS on the roster under
# the explicit "offline" state. Erasing them is what made a quiet team and a broken wall look
# identical; the one thing that must never happen is offline reading as active/idle.
C_ON="$(get "'haid:d' in d['on_now']")"
C_STATE="$(get "d['now'].get('haid:d')")"
if [ "$C_ON" = "True" ] && [ "$C_STATE" = "offline" ]; then
  ok "C devD (ts > TTL, inside the window) stays on the wall as OFFLINE — greyed, not erased"
else
  bad "C devD did not read OFFLINE on the wall (on=$C_ON state=$C_STATE — out=$OUT)"
fi
[ "$C_STATE" != "active" ] && [ "$C_STATE" != "idle" ] \
  && ok "C2 FALSIFIABLE: an offline dev never derives active/idle (never a false-online)" \
  || bad "C2 an offline dev derived a LIVE state ($C_STATE) — reads as present"

# C3. The outer bound still bites: past the 7-day window a dev leaves the wall for good.
[ "$(get "'haid:e' in d['on_now']")" = "False" ] \
  && ok "C3 devE (8 days stale) is DROPPED — the wall is bounded, not a graveyard" \
  || bad "C3 a dev past the 7-day window lingered on the roster (out=$OUT)"

# C-trace. INJECTED CLOCK: devA flips active->idle by advancing `now` past the activity window
# while a keeper heartbeat keeps its ts inside the TTL — the clock decides, and it never drops.
[ "$(get "d['later_a']")" = "idle" ] \
  && ok "C-trace devA flips ACTIVE->IDLE as the clock advances past the activity window (still online, never dropped)" \
  || bad "C-trace devA did not demote to idle on the advanced clock (out=$OUT)"

# D. derive_state() unit — the same record reads ACTIVE then IDLE purely by advancing now.
if [ "$(get "d['unit_active']")" = "active" ] && [ "$(get "d['unit_idle']")" = "idle" ]; then
  ok "D derive_state() is clock-driven: one record => active now, idle 300s later (falsifiable both ways)"
else
  bad "D derive_state() not clock-driven (active=$(get "d['unit_active']") idle=$(get "d['unit_idle']"))"
fi

echo
echo "============================================================"
printf "cp-presence-wall-state: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

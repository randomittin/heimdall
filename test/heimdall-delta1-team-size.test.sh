#!/usr/bin/env bash
# heimdall-delta1-team-size.test.sh — LOCKS the Δ1 STANDING DESIGN INVARIANT:
#
#   LIVE PRESENCE + THE WALL ARE FREE AT ANY TEAM SIZE, FOREVER.
#
# No feature may gate PRESENCE, the BEAT, or ROSTER MEMBERSHIP/VISIBILITY on team size.
# A team with MANY members must see EVERY member on the wall — the server/roster API returns
# the FULL set, never a size-capped page. See docs/design-invariants.md (Δ1).
#
# WHY THIS GATE EXISTS. Δ1 is a STANDING assumption that survives the revenue deferral (revenue
# is parked behind ★1,000 stars). If presence ever assumed a team-size limit, two things break:
#   1. the AUTO-JOIN VIRAL LOOP — a teammate past the cap silently never appears on the wall, so
#      the "everyone on the project shows up live" promise (the growth engine) dies at N;
#   2. a REFACTOR TAX when revenue opens — revenue must gate on FEATURES (history/analytics),
#      NEVER on presence/size; a size cap baked into the read path would have to be ripped out.
# This test is the FALSIFIABLE lock: bake a MAX_TEAM_MEMBERS cap into the roster read and it
# goes RED (section D), so a future violation cannot land green.
#
# THE DISTINCTION Δ1 draws (this test encodes it):
#   • DISPLAY caps (the client renders K glyphs + "+k more") — FINE. The SERVER still returns the
#     FULL set; the overflow is a pure client computation over the complete roster (section E).
#   • ABUSE throttles (per-IP / per-window RATE limits) — FINE, that is cost-governance, not a
#     team-size cap (covered by cp-ratelimit / cp-roster-team's rate-limit case, not here).
#   • MEMBERSHIP / VISIBILITY caps (hide or refuse a REAL teammate past a team-size threshold) —
#     FORBIDDEN. Sections A/B/C prove the presence/beat/roster path has none; D is the falsifier.
#
# SCOPE. This locks the PRESENCE surface (cp_presence: record_presence / roster / roster_team_route)
# — the beat, the roster fold, and the team-private browser read. It uses the LOCAL StateBackend
# (default) because Δ1 is a property of the FOLD LOGIC, not the persistence backend; the firestore
# durability of the same fold is proven by cp-presence / cp-roster-team.
#
# Exit 0 = every proof holds. Deps: bash + python3 only (no network, no GCP, no node/jq).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

[ -f "$LIB/cp_presence.py" ] || { echo "FATAL: $LIB/cp_presence.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "delta1-team-size.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

# The LOCAL backend (default) — the fold logic is backend-independent; unset any inherited
# firestore selection so this gate is hermetic and fast.
unset HEIMDALL_STATE_BACKEND
export HEIMDALL_HOME="$HOME_T"
# A high per-IP read cap so the single team-read in C/D/E is NEVER throttled — this gate is about
# the SIZE of the returned set, not the RATE of reads (abuse throttles are a separate, FINE class).
export HEIMDALL_ROSTER_IP_LIMIT=100000

# MANY members — well above any "small team" intuition, one shared (project, team) partition.
BIG_N=50
export BIG_N

PROJECT="acme/widget"
TEAM_SECRET="delta1-team-secret-AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
export PROJECT TEAM_SECRET
TEAM_ID="$(TEAM_SECRET="$TEAM_SECRET" "$PY" -c "import os,sys;sys.path.insert(0,os.environ['LIB']);import cp_auth;print(cp_auth.derive_team_id(os.environ['TEAM_SECRET']))")"
export TEAM_ID

echo "============================================================"
echo "Δ1 — LIVE PRESENCE + WALL FREE AT ANY TEAM SIZE (N=$BIG_N members, LOCAL backend)"
echo "  home=$HEIMDALL_HOME  team_id=${TEAM_ID:0:8}…"
echo "============================================================"
echo

# ──────────────────────────────────────────────────────────────────────────────
# A. MEMBERSHIP — N distinct online beats into ONE (project, team) partition; the roster fold
#    returns ALL N, no size cap DROPS a member. (The core Δ1 property.)
# B. THE BEAT PATH — every one of the N beats is accepted (ok:True); NONE is refused for being
#    "too many" (there is no team_full / size gate in record_presence — the auto-join/beat path).
# ──────────────────────────────────────────────────────────────────────────────
echo "A/B. $BIG_N distinct beats into one team -> roster returns ALL $BIG_N; no beat refused for size"
AB_OUT="$("$PY" - <<'PYEOF' 2>"$EXT/ab.err"
import json, os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PROJECT"]; tid = os.environ["TEAM_ID"]; n = int(os.environ["BIG_N"])
now = time.time()
beats_ok = 0
refused_for_size = 0
seeded = set()
for i in range(n):
    haid = "haid:dev-%03d.box" % i
    seeded.add(haid)
    r = P.record_presence(haid, project=proj, team_id=tid, handle="dev%03d" % i,
                          verdict="building", file="src/mod_%03d.py" % i, ts=now)
    if r.get("ok"):
        beats_ok += 1
    # a hypothetical size gate would surface as a NON-ok result with a "full"/"max"/"size" reason.
    reason = str(r.get("reason") or "")
    if any(tok in reason for tok in ("full", "max", "size", "too_many", "limit", "cap")):
        refused_for_size += 1
roster = P.roster(proj, tid, now=now)
haids = sorted(r.get("haid") for r in roster)
print(json.dumps({
    "beats_ok": beats_ok,
    "refused_for_size": refused_for_size,
    "roster_len": len(roster),
    "all_present": sorted(seeded) == haids,
    "distinct": len(set(haids)) == len(haids),
}))
PYEOF
)"
AB_BEATS_OK="$(printf '%s' "$AB_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['beats_ok'])" 2>/dev/null)"
AB_REFUSED="$(printf '%s' "$AB_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['refused_for_size'])" 2>/dev/null)"
AB_LEN="$(printf '%s' "$AB_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['roster_len'])" 2>/dev/null)"
AB_ALL="$(printf '%s' "$AB_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['all_present'])" 2>/dev/null)"
AB_DISTINCT="$(printf '%s' "$AB_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['distinct'])" 2>/dev/null)"
if [ "$AB_LEN" = "$BIG_N" ] && [ "$AB_ALL" = "True" ] && [ "$AB_DISTINCT" = "True" ]; then
  ok "A1 roster() returns ALL $BIG_N members (no size cap DROPS a real teammate — Δ1 membership)"
else
  bad "A1 roster did not return all $BIG_N members (len=$AB_LEN all=$AB_ALL out=$AB_OUT)"; cat "$EXT/ab.err" >&2
fi
if [ "$AB_BEATS_OK" = "$BIG_N" ] && [ "$AB_REFUSED" = "0" ]; then
  ok "B1 every one of the $BIG_N beats was accepted; NONE refused for team size (beat/auto-join path has no size gate)"
else
  bad "B1 a beat was refused for size (ok=$AB_BEATS_OK refused=$AB_REFUSED out=$AB_OUT)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# C. THE SERVER/ROSTER API — the team-private browser read (GET /roster-team) returns the FULL
#    set of N members, not a truncated page. This is the wall's data source; it must be complete.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "C. the /roster-team server read returns the FULL $BIG_N-member set (not a size-capped page)"
C_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>"$EXT/c.err"
import json, os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PROJECT"]; tid = os.environ["TEAM_ID"]; n = int(os.environ["BIG_N"])
now = time.time()
for i in range(n):
    P.record_presence("haid:dev-%03d.box" % i, project=proj, team_id=tid,
                      handle="dev%03d" % i, verdict="building", file="-", ts=now)
resp = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
        "query": {"project": proj}, "team_secret": os.environ["TEAM_SECRET"],
        "peer_ip": "10.0.0.1"})
online = resp.body.get("online", []) if isinstance(resp.body, dict) else []
print(json.dumps({"status": resp.status, "online_len": len(online),
                  "distinct": len({r.get("haid") for r in online}) == len(online)}))
PYEOF
)"
C_STATUS="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
C_LEN="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['online_len'])" 2>/dev/null)"
C_DISTINCT="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['distinct'])" 2>/dev/null)"
if [ "$C_STATUS" = "200" ] && [ "$C_LEN" = "$BIG_N" ] && [ "$C_DISTINCT" = "True" ]; then
  ok "C1 GET /roster-team returns ALL $BIG_N members (the wall's data source is COMPLETE, un-paged)"
else
  bad "C1 /roster-team returned a truncated set (status=$C_STATUS len=$C_LEN out=$C_OUT)"; cat "$EXT/c.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# D. THE FALSIFIER — bake a MAX_TEAM_MEMBERS cap INTO the roster read and prove the gate goes RED.
#    We monkeypatch cp_presence.roster with a size-capped variant (out[:MAX]) — EXACTLY the class
#    of change Δ1 forbids — and confirm /roster-team then returns fewer than N. Because C asserts
#    len == N, that future violation would flip this gate RED. This is what makes the lock real
#    (the assertion is NOT green-by-construction — a membership cap is caught).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "D. FALSIFIER: a MAX_TEAM_MEMBERS cap in the roster read TRUNCATES the wall -> would go RED"
D_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>"$EXT/d.err"
import json, os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PROJECT"]; tid = os.environ["TEAM_ID"]; n = int(os.environ["BIG_N"])
now = time.time()
for i in range(n):
    P.record_presence("haid:dev-%03d.box" % i, project=proj, team_id=tid,
                      handle="dev%03d" % i, verdict="building", file="-", ts=now)

# The uncapped truth first (what C locks): the full set.
real = P.roster_team_route({"method": "GET", "route_path": "/roster-team", "query": {"project": proj},
        "team_secret": os.environ["TEAM_SECRET"], "peer_ip": "10.0.0.2"})
real_len = len(real.body.get("online", []))

# INTRODUCE THE VIOLATION: wrap roster() with a hard team-size cap (a membership cap, Δ1-forbidden).
_MAX_TEAM_MEMBERS = 10
_real_roster = P.roster
def _capped_roster(project, team_id, **kw):
    return _real_roster(project, team_id, **kw)[:_MAX_TEAM_MEMBERS]
P.roster = _capped_roster  # roster_team_route resolves the module-global -> the cap is now live.

capped = P.roster_team_route({"method": "GET", "route_path": "/roster-team", "query": {"project": proj},
        "team_secret": os.environ["TEAM_SECRET"], "peer_ip": "10.0.0.3"})
capped_len = len(capped.body.get("online", []))
P.roster = _real_roster  # restore.

print(json.dumps({"real_len": real_len, "capped_len": capped_len, "cap": _MAX_TEAM_MEMBERS,
                  "would_go_red": (real_len == n and capped_len < n and capped_len == _MAX_TEAM_MEMBERS)}))
PYEOF
)"
D_RED="$(printf '%s' "$D_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['would_go_red'])" 2>/dev/null)"
D_REAL="$(printf '%s' "$D_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['real_len'])" 2>/dev/null)"
D_CAP="$(printf '%s' "$D_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['capped_len'])" 2>/dev/null)"
if [ "$D_RED" = "True" ]; then
  ok "D1 FALSIFIER: uncapped=$D_REAL, MAX_TEAM_MEMBERS-capped=$D_CAP — a membership cap TRUNCATES the wall (C would flip RED). The lock is real."
else
  bad "D1 the falsifier did not demonstrate truncation (real=$D_REAL capped=$D_CAP out=$D_OUT)"; cat "$EXT/d.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# E. DISPLAY-vs-MEMBERSHIP — a client DISPLAY cap ("show K glyphs + +k more") is PERMITTED because
#    it is a pure computation OVER the complete server set: the server hands back all N, the client
#    chooses how many glyphs to draw. This proves a "+k" overflow is a CLIENT concern, never a
#    server-side membership drop — the FINE side of the distinction Δ1 draws.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "E. a DISPLAY cap (K glyphs + \"+k more\") is derivable from the FULL server set (client concern, FINE)"
E_OUT="$("$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PROJECT"]; tid = os.environ["TEAM_ID"]; n = int(os.environ["BIG_N"])
now = time.time()
for i in range(n):
    P.record_presence("haid:dev-%03d.box" % i, project=proj, team_id=tid,
                      handle="dev%03d" % i, verdict="idle", file="-", ts=now)
full = P.roster(proj, tid, now=now)             # the SERVER returns the complete set …
K = 8                                            # … the CLIENT chooses to draw 8 glyphs …
glyphs = full[:K]                                # … a pure display slice …
overflow = max(0, len(full) - K)                 # … and a "+k" overflow count over the full set.
print(json.dumps({"server_len": len(full), "glyphs": len(glyphs), "overflow": overflow,
                  "overflow_correct": overflow == n - K}))
PYEOF
)"
E_SERVER="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['server_len'])" 2>/dev/null)"
E_OVERFLOW="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['overflow_correct'])" 2>/dev/null)"
if [ "$E_SERVER" = "$BIG_N" ] && [ "$E_OVERFLOW" = "True" ]; then
  ok "E1 the server returns all $BIG_N; a K-glyph + \"+k\" overflow is a CLIENT slice over the full set (display cap FINE, membership uncapped)"
else
  bad "E1 the display-cap distinction did not hold (server_len=$E_SERVER overflow=$E_OVERFLOW out=$E_OUT)"
fi

echo
echo "============================================================"
printf "heimdall-delta1-team-size: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

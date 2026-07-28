#!/usr/bin/env bash
# heimdall-presence-keeper.test.sh — FALSIFIER: a live-but-IDLE session stays on the wall.
#
# THE BUG (presence dies on idle). Presence had only two beat sources and BOTH stop on an
# idle-but-live session: (1) the v2.0.20 SessionStart auto-beat is a ONE-SHOT — it ages out
# past the ~45s server TTL and never fires again; (2) the statusline beat is RENDER-GATED — it
# only fires when Claude Code REDRAWS. So a session that is alive but not re-rendering stops
# beating → the dev silently vanishes from teammates' walls. THE FIX: a DURABLE periodic
# beat-keeper — one detached loop spawned at SessionStart that re-beats on a timer (under the
# TTL), independent of renders, until keeper-stop reaps it at SessionEnd.
#
# RED-WITHOUT-FIX: every proof drives the NEW `keeper-start` / `keeper-stop` / `keeper-loop`
# subcommands. On the pre-fix bin those are unknown subcommands (exit 2, no loop, no beats) →
# the roster stays empty, no keeper pid is ever written → proofs A/B/D FAIL. With the fix the
# keeper beats repeatedly with NO render between beats → the caller stays on the roster.
#
# HERMETIC (mirrors heimdall-watch-beat / cp-presence-team-roundtrip): the LOCAL StateBackend
# (NDJSON under HEIMDALL_HOME), NO firestore, NO live CP, NO network. The beat path is INJECTED
# via HMD_KEEPER_BEAT_BIN — a stub that records presence THROUGH the real cp_presence seam
# (record_presence keyed by (project, team_id, haid)) AND tallies each beat, so we assert both
# "the keeper keeps beating" and "the beats land where the team roster reads them back".
#
#   A. DURABILITY (RED-without-fix): driving the keeper's beat cycle N=2 times — simulating
#      elapsed time with NO statusline render and NO manual beat between cycles — beats EXACTLY
#      twice and leaves the caller ON the team roster (a one-shot would beat once then age out).
#   B. STOP reaps the loop: a real detached keeper is alive + beating; keeper-stop kills it (no
#      beat after stop) and reaps its pidfile (no leaked process across sessions).
#   C. CONSENT OFF → NO keeper: with presence globally off, keeper-start spawns NOTHING (no
#      pidfile, no process) — consent is honored, mirroring the off beat gate.
#   D. DOUBLE-START → SINGLE keeper: a second keeper-start for the same session does NOT spawn a
#      second loop — the pid is unchanged (idempotent; never leaks a duplicate loop).
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-presence"
LIB="$REPO/bin/lib"
# DEFAULT-ON egress guard: pin the baked-in CP default at a dead port so no un-pinned presence
# call in this suite resolves the REAL production control plane. Explicit per-invocation pins win.
. "$REPO/test/lib/net-default-guard.sh"
export LIB REPO

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing/not executable" >&2; exit 2; }
[ -f "$LIB/cp_presence.py" ] || { echo "FATAL: cp_presence.py missing" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMP="$(mktemp -d -t "presence-keeper.XXXXXX")"
export HEIMDALL_HOME="$TMP/home"          # cp_presence local backend home
export HEIMDALL_KEEPER_DIR="$TMP/keeper"  # keeper pidfile home (never ~/.heimdall in tests)
mkdir -p "$HEIMDALL_HOME" "$HEIMDALL_KEEPER_DIR"
# HOME is a throwaway so a stray global presence-off/config never bleeds in from the dev box.
export HOME="$TMP/fakehome"; mkdir -p "$HOME/.heimdall"
cleanup() {
  # best-effort: kill any keeper this test may have left, then remove the tree.
  for pf in "$HEIMDALL_KEEPER_DIR"/*.pid; do
    [ -f "$pf" ] || continue
    p="$(cat "$pf" 2>/dev/null || true)"
    case "$p" in ''|*[!0-9]*) : ;; *) kill "$p" 2>/dev/null || true ;; esac
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

PROJECT="acme/widget"
HAID="haid:rj.mbp-keeper"
SECRET="team-secret-KPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
COUNTER="$TMP/beats.log"; : > "$COUNTER"
export PROJECT HAID SECRET COUNTER

echo "============================================================"
echo "PRESENCE-KEEPER falsifier — a live-but-idle session stays on the wall"
echo "  home=$HEIMDALL_HOME  keeper_dir=$HEIMDALL_KEEPER_DIR  (local backend)"
echo "============================================================"
echo

# ── the injected beat path: a stub `heimdall-presence beat` that (1) records THIS caller's
#    presence into the real StateBackend in the partition derived from the presented secret,
#    and (2) tallies the beat. This stands in for the CP write a real beat performs, so the
#    assertion isolates "did the keeper keep beating" (not the transport). Pure-local, no socket.
BEAT_STUB="$TMP/beat-stub"
cat > "$BEAT_STUB" <<SH
#!/usr/bin/env bash
[ "\$1" = "beat" ] || exit 0
echo "beat" >> "$COUNTER"
LIB="$LIB" HEIMDALL_HOME="$HEIMDALL_HOME" HMD_HAID="$HAID" \\
HMD_PROJECT="$PROJECT" WB_SECRET="$SECRET" "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence as P
haid = os.environ.get("HMD_HAID") or ""
secret = os.environ.get("WB_SECRET") or ""
if not haid or not secret:
    sys.exit(0)
team_id = cp_auth.derive_team_id(secret)
P.record_presence(haid, project=os.environ.get("HMD_PROJECT") or "",
                  team_id=team_id, handle="rj", verdict="working", file="-",
                  home=os.environ["HEIMDALL_HOME"])
PYEOF
exit 0
SH
chmod +x "$BEAT_STUB"
export HMD_KEEPER_BEAT_BIN="$BEAT_STUB"

# roster reader — the real cp_presence.roster_team_route, scoped to a presented secret.
read_roster() {  # $1 = team secret to present
  HEIMDALL_PUBLIC_SURFACE=1 WB_READ_SECRET="$1" "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
resp = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
                            "query": {"project": os.environ["PROJECT"]},
                            "team_secret": os.environ["WB_READ_SECRET"],
                            "peer_ip": "10.0.0.1"},
                           home=os.environ["HEIMDALL_HOME"])
print(json.dumps({"status": resp.status,
                  "haids": [r.get("haid") for r in resp.body.get("online", [])]}))
PYEOF
}
roster_has() {  # $1 = roster json -> True/False whether HAID is present
  printf '%s' "$1" | HAID="$HAID" "$PY" -c "import json,os,sys;print(os.environ['HAID'] in json.load(sys.stdin)['haids'])" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# A. DURABILITY — the keeper's beat cycle, driven N=2 times with NO render between,
#    beats twice and keeps the caller on the roster (RED-without-fix).
# ══════════════════════════════════════════════════════════════════════════════
echo "A. driving the keeper loop N=2 (no render, no manual beat between) keeps the caller present"
A0="$(read_roster "$SECRET")"
[ "$(roster_has "$A0")" = "True" ] && bad "A0 caller already on roster before any keeper beat — proof would be vacuous (out=$A0)" \
  || ok "A0 negative control: caller ABSENT before the keeper beats (out=$A0)"

: > "$COUNTER"
# keeper-loop is the deterministic in-process cycle driver: N=2, interval 0 == "two ticks of
# the timer" with zero real wait. This is the elapsed-time simulation: two independent
# timer-driven beats, NOT one render-driven beat.
HMD_KEEPER_MAX_CYCLES=2 "$BIN" keeper-loop --pidfile "$TMP/A.pid" --interval 0 \
  --project "$PROJECT" --session A >/dev/null 2>&1
A_BEATS="$(wc -l < "$COUNTER" | tr -d ' ')"
if [ "$A_BEATS" = "2" ]; then
  ok "A1 the keeper emitted EXACTLY 2 timer-driven beats (a one-shot would emit 1) — periodic, not render-gated"
else
  bad "A1 the keeper did not beat twice (beats=$A_BEATS) — keeper-loop absent/broken (RED on the pre-fix bin)"
fi
A1="$(read_roster "$SECRET")"
A_STATUS="$(printf '%s' "$A1" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
if [ "$A_STATUS" = "200" ] && [ "$(roster_has "$A1")" = "True" ]; then
  ok "A2 after 2 keeper cycles the caller is ON the team roster (the record stays fresh — out=$A1)"
else
  bad "A2 the caller is NOT on the roster after the keeper ran (idle presence still dies — out=$A1)"
fi
[ -f "$TMP/A.pid" ] && bad "A3 keeper-loop left a stale pidfile (should self-reap on exit)" \
  || ok "A3 keeper-loop self-reaped its pidfile on natural exit (no leak)"

# ══════════════════════════════════════════════════════════════════════════════
# B. STOP reaps the loop — a live keeper is killed by keeper-stop (no beat after, pid reaped).
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "B. keeper-stop kills a live keeper (no beat after stop) and reaps its pidfile"
: > "$COUNTER"
"$BIN" keeper-start --session B --project "$PROJECT" --interval 1 >/dev/null 2>&1
"$PY" -c "import time;time.sleep(1.3)"   # let it beat at least once
PF_B="$HEIMDALL_KEEPER_DIR/acme_widget__B.pid"
PID_B="$(cat "$PF_B" 2>/dev/null || true)"
if [ -n "$PID_B" ] && kill -0 "$PID_B" 2>/dev/null && [ "$(wc -l < "$COUNTER" | tr -d ' ')" -ge 1 ]; then
  ok "B1 keeper-start spawned ONE live, beating detached loop (pid $PID_B)"
else
  bad "B1 keeper-start did not produce a live beating keeper (pid='$PID_B', beats=$(wc -l < "$COUNTER"|tr -d ' '))"
fi
"$BIN" keeper-stop --session B --project "$PROJECT" >/dev/null 2>&1
"$PY" -c "import time;time.sleep(0.3)"
if [ -n "$PID_B" ] && ! kill -0 "$PID_B" 2>/dev/null; then
  ok "B2 keeper-stop KILLED the loop (pid $PID_B is gone — no process leaked across sessions)"
else
  bad "B2 the keeper survived keeper-stop (pid $PID_B still alive — leaked loop, RED)"
fi
[ -f "$PF_B" ] && bad "B3 keeper-stop left the pidfile behind (pid not reaped)" \
  || ok "B3 keeper-stop reaped the pidfile"
N_AFTER1="$(wc -l < "$COUNTER" | tr -d ' ')"
"$PY" -c "import time;time.sleep(1.3)"   # a full interval later: a killed loop must NOT beat
N_AFTER2="$(wc -l < "$COUNTER" | tr -d ' ')"
[ "$N_AFTER1" = "$N_AFTER2" ] \
  && ok "B4 no beat lands after stop (a full interval later the tally is unchanged: $N_AFTER1)" \
  || bad "B4 a beat landed AFTER stop ($N_AFTER1 -> $N_AFTER2) — the loop was not truly killed"

# ══════════════════════════════════════════════════════════════════════════════
# C. CONSENT OFF → NO keeper (global kill switch honored, falsifiable).
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "C. consent OFF -> keeper-start spawns NOTHING (no pidfile, no loop)"
: > "$HOME/.heimdall/presence-off"        # machine-wide kill switch
C_RC=0; "$BIN" keeper-start --session C --project "$PROJECT" --interval 1 >/dev/null 2>&1 || C_RC=$?
"$PY" -c "import time;time.sleep(0.3)"
PF_C="$HEIMDALL_KEEPER_DIR/acme_widget__C.pid"
if [ ! -f "$PF_C" ] && [ "$C_RC" -eq 0 ]; then
  ok "C1 OFF: keeper-start wrote NO pidfile and exited 0 (no keeper spawned — consent honored)"
else
  bad "C1 OFF: keeper-start spawned a keeper anyway (pidfile='$PF_C' exists=$([ -f "$PF_C" ] && echo yes||echo no), rc=$C_RC) — RED"
fi
rm -f "$HOME/.heimdall/presence-off"

# ══════════════════════════════════════════════════════════════════════════════
# D. DOUBLE-START → SINGLE keeper (idempotent, no duplicate loop).
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "D. a second keeper-start for the same session does NOT spawn a second loop"
"$BIN" keeper-start --session D --project "$PROJECT" --interval 5 >/dev/null 2>&1
"$PY" -c "import time;time.sleep(0.3)"
PF_D="$HEIMDALL_KEEPER_DIR/acme_widget__D.pid"
PID_D1="$(cat "$PF_D" 2>/dev/null || true)"
"$BIN" keeper-start --session D --project "$PROJECT" --interval 5 >/dev/null 2>&1
"$PY" -c "import time;time.sleep(0.3)"
PID_D2="$(cat "$PF_D" 2>/dev/null || true)"
if [ -n "$PID_D1" ] && [ "$PID_D1" = "$PID_D2" ] && kill -0 "$PID_D1" 2>/dev/null; then
  ok "D1 the second start is a no-op: ONE keeper, pid unchanged ($PID_D1) — no duplicate loop"
else
  bad "D1 double-start changed/duplicated the keeper (pid $PID_D1 -> $PID_D2) — not idempotent (RED)"
fi
NPIDS="$(ls "$HEIMDALL_KEEPER_DIR"/acme_widget__D.pid 2>/dev/null | wc -l | tr -d ' ')"
[ "$NPIDS" = "1" ] && ok "D2 exactly ONE pidfile for the session" || bad "D2 expected 1 pidfile, found $NPIDS"
"$BIN" keeper-stop --session D --project "$PROJECT" >/dev/null 2>&1

echo
echo "============================================================"
printf "heimdall-presence-keeper: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

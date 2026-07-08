#!/usr/bin/env bash
# heimdall-watch-beat.test.sh — FALSIFIER: opening the wall marks you present.
#
# THE BUG (a launch-demo footgun): `hmd watch` was READ-ONLY — it renders the local
# roster cache but NEVER beats. A teammate who installed but has no LIVE `claude`
# session in the repo therefore never beats → is INVISIBLE on the presence wall, even
# while literally staring at it. THE FIX: `hmd watch` emits a lightweight presence beat
# on open (and, in the TUI, on a TTL-live interval) through the EXISTING beat path
# (heimdall-presence beat), so simply watching the wall marks you present.
#
# RED-WITHOUT-FIX: this test drives the REAL one-shot watch path (bin/heimdall-watch-tui
# --once) and then asserts the caller's HAID is in the team roster afterwards. On the
# old read-only watch NO beat is dispatched → the roster stays EMPTY → the primary proof
# (B) FAILS. With the fix, watch shells `heimdall-presence beat` → the HAID appears → PASS.
#
# HERMETIC (mirrors cp-presence-team-roundtrip): the LOCAL StateBackend (NDJSON under
# HEIMDALL_HOME), NO firestore, NO live CP, NO network. We INJECT the beat path via
# HEIMDALL_PRESENCE_BIN — a stub that records presence THROUGH the real cp_presence
# StateBackend seam (record_presence keyed by (project, team_id, haid)), exactly where a
# real beat lands. The roster is then read back with the SAME team secret via the real
# cp_presence.roster_team_route. A negative control (A) proves the roster is empty until
# watch beats; an isolation proof (D) proves the beat lands ONLY in the caller's own team.
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
WATCH_BIN="$REPO/bin/heimdall-watch-tui"
export LIB REPO

for f in cp_auth cp_presence cp_publicsurface cp_server cp_state; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$WATCH_BIN" ] || chmod +x "$WATCH_BIN" 2>/dev/null || true
[ -f "$WATCH_BIN" ] || { echo "FATAL: $WATCH_BIN missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "watch-beat.XXXXXX")"
export HEIMDALL_HOME="$EXT/home"
mkdir -p "$HEIMDALL_HOME"
WATCH_ROOT="$EXT/repo"; mkdir -p "$WATCH_ROOT/.heimdall"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

PROJECT="acme/widget"
HAID="haid:rj.mbp-watcher"
# High-entropy team secret (>= 32 chars). The beat lands in derive_team_id(secret); the
# roster read derives the SAME partition from the SAME secret.
SECRET="team-secret-WBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
OTHER="team-secret-WBZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
export PROJECT HAID SECRET OTHER

echo "============================================================"
echo "WATCH-BEAT falsifier — opening the wall == you're on the wall"
echo "  home=$HEIMDALL_HOME  (local backend)  watch=$WATCH_BIN"
echo "============================================================"
echo

# ── inject the beat path: a stub `heimdall-presence` that records THIS caller's presence
#    into the real StateBackend, in the partition derived from the presented team secret.
#    This stands in for the CP write a real `heimdall-presence beat` performs. Pure-local:
#    no socket, so the assertion isolates "did watch dispatch the beat", not the transport.
BEAT_STUB="$EXT/heimdall-presence"
cat > "$BEAT_STUB" <<SH
#!/usr/bin/env bash
[ "\$1" = "beat" ] || exit 0
LIB="$LIB" HEIMDALL_HOME="$HEIMDALL_HOME" HMD_HAID="\${HMD_HAID:-}" \\
HMD_PROJECT="\${HMD_PROJECT:-}" HMD_HANDLE="\${HMD_HANDLE:-}" \\
WB_SECRET="\${WB_SECRET:-}" "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence as P
haid = os.environ.get("HMD_HAID") or ""
secret = os.environ.get("WB_SECRET") or ""
if not haid or not secret:
    sys.exit(0)
team_id = cp_auth.derive_team_id(secret)
P.record_presence(haid, project=os.environ.get("HMD_PROJECT") or "",
                  team_id=team_id, handle=os.environ.get("HMD_HANDLE") or "watcher",
                  verdict="watching", file="-", home=os.environ["HEIMDALL_HOME"])
PYEOF
exit 0
SH
chmod +x "$BEAT_STUB"

# roster reader — the real cp_presence.roster_team_route on the public surface, scoped to a
# presented secret's derived partition. Echoes the HAIDs it sees.
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

# drive the REAL one-shot watch path with the injected beat bin.
run_watch_once() {
  HEIMDALL_WATCH_ROOT="$WATCH_ROOT" HEIMDALL_HOME="$HEIMDALL_HOME" \
  HEIMDALL_PRESENCE_BIN="$BEAT_STUB" \
  HMD_HAID="$HAID" HMD_PROJECT="$PROJECT" HMD_HANDLE="rj" WB_SECRET="$SECRET" \
  NO_COLOR=1 HEIMDALL_STATUSLINE_MODE=mono \
    "$WATCH_BIN" --once >/dev/null 2>&1
}

# ── A. NEGATIVE CONTROL — before watch runs, the caller is NOT on the roster ─────────
A="$(read_roster "$SECRET")"
A_ABSENT="$(printf '%s' "$A" | HAID="$HAID" "$PY" -c "import json,os,sys;print(os.environ['HAID'] not in json.load(sys.stdin)['haids'])" 2>/dev/null)"
[ "$A_ABSENT" = "True" ] \
  && ok "A the caller is ABSENT from the team roster before watch opens (no pre-seed — out=$A)" \
  || bad "A the caller was already on the roster before watch — the proof would be vacuous (out=$A)"

# ── B. PRIMARY (RED-without-fix) — opening the one-shot wall marks the caller present ─
run_watch_once
B="$(read_roster "$SECRET")"
B_STATUS="$(printf '%s' "$B" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
B_PRESENT="$(printf '%s' "$B" | HAID="$HAID" "$PY" -c "import json,os,sys;print(os.environ['HAID'] in json.load(sys.stdin)['haids'])" 2>/dev/null)"
if [ "$B_STATUS" = "200" ] && [ "$B_PRESENT" = "True" ]; then
  ok "B invoking \`hmd watch --once\` put the caller's HAID on the team roster (open == present — out=$B)"
else
  bad "B watch --once did NOT self-include on the roster (read-only watch — the invisible-beat footgun) — out=$B"
fi

# ── C. IDEMPOTENT — a second open beats again but adds NO duplicate roster row ────────
run_watch_once
C="$(read_roster "$SECRET")"
C_COUNT="$(printf '%s' "$C" | HAID="$HAID" "$PY" -c "import json,os,sys;print(sum(1 for h in json.load(sys.stdin)['haids'] if h==os.environ['HAID']))" 2>/dev/null)"
[ "$C_COUNT" = "1" ] \
  && ok "C a second watch open re-beats but the roster holds exactly ONE row for the caller (upsert keyed by HAID — out=$C)" \
  || bad "C a re-beat duplicated the caller's roster row (append, not upsert) — count=$C_COUNT (out=$C)"

# ── D. ISOLATION — the beat lands ONLY in the caller's own team, never cross-tenant ──
D="$(read_roster "$OTHER")"
D_STATUS="$(printf '%s' "$D" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
D_ABSENT="$(printf '%s' "$D" | HAID="$HAID" "$PY" -c "import json,os,sys;print(os.environ['HAID'] not in json.load(sys.stdin)['haids'])" 2>/dev/null)"
if [ "$D_STATUS" = "200" ] && [ "$D_ABSENT" = "True" ]; then
  ok "D a DIFFERENT team secret sees NONE of the watcher's beat (multi-tenant isolation holds — out=$D)"
else
  bad "D the watch beat leaked across teams (a different secret saw the caller) — out=$D"
fi

echo
echo "============================================================"
printf "heimdall-watch-beat: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

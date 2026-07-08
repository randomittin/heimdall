#!/usr/bin/env bash
# heimdall-team-clone-join.test.sh — END-TO-END FALSIFIER for AUTOMATIC private-repo
# team presence: clone a PRIVATE repo (which carries a COMMITTED team.json) and START
# A SESSION → the teammate appears on the owner's presence roster with ZERO manual
# commands. Proves the whole chain the "automatic presence for private-repo teams"
# feature promises:
#
#   PRIVATE repo  ->  team.json is COMMITTED (git add -f past .gitignore)  ->  a
#   teammate's clone ALREADY HAS team.json (clone == join)  ->  SessionStart BEATS
#   automatically  ->  the beat lands in derive_team_id(team.json.secret)  ->  the
#   owner's roster (same secret) SHOWS the teammate. No `hmd team join`, no manual
#   `heimdall-presence beat`, no separate `hmd watch` session.
#
# RED-WITHOUT-FIX. The falsifiable link is the SessionStart hook BEATING. Before the
# fix the SessionStart hook only ran `heimdall-team auto` (ensured/joined a team) but
# never dispatched a presence beat — so a freshly-cloned teammate joined the team yet
# stayed INVISIBLE until they manually beat or opened the wall. This test drives the
# REAL SessionStart hook command (extracted from hooks/hooks.json) in a cloned private
# repo and asserts the teammate lands on the owner's roster. With no beat wired into
# SessionStart the roster stays EMPTY → proof B FAILS. With the beat wired → the
# teammate appears → PASS.
#
# HERMETIC (mirrors cp-presence-team-roundtrip / heimdall-watch-beat): the LOCAL
# StateBackend (NDJSON under HEIMDALL_HOME), NO firestore, NO live CP, NO network. The
# beat path is INJECTED as a temp-plugin `bin/heimdall-presence` stub that records
# presence THROUGH the real cp_presence StateBackend seam (record_presence keyed by
# (project, team_id, haid)) — exactly where a real beat lands — resolving the team
# secret FROM THE CLONE'S committed team.json (proving the clone delivered the joining
# capability). The roster is read back with the SAME secret via the real
# cp_presence.roster_team_route.
#
# THE SECURITY FAIL-SAFE (cardinal control, also proven here in the clone-join framing):
# a PUBLIC / privacy-unverifiable repo MUST NOT commit team.json — so a clone of a public
# repo carries NO secret and NO one auto-joins. Proof F drives the REAL `heimdall-team
# share` against a mocked-PUBLIC gh and asserts team.json is neither committed nor staged
# and the secret is absent from the tree.
#
# All secrets are OBVIOUSLY FAKE (low-entropy, hyphenated) so the heimdall repo's own
# secret-scan / gitleaks stays clean; every committed secret lands ONLY in a throwaway
# temp repo rm -rf'd on exit.
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
TEAM_CLI="$REPO/bin/heimdall-team"
HOOKS_JSON="$REPO/hooks/hooks.json"
export LIB REPO

for f in cp_auth cp_presence cp_publicsurface cp_server cp_state; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$TEAM_CLI" ] || { echo "FATAL: $TEAM_CLI missing/!exec" >&2; exit 2; }
[ -f "$HOOKS_JSON" ] || { echo "FATAL: $HOOKS_JSON missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "clone-join.XXXXXX")"
export HEIMDALL_HOME="$EXT/home"
mkdir -p "$HEIMDALL_HOME"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

PROJECT="acme/private-widget"
TEAMMATE_HAID="haid:teammate.laptop"
# OBVIOUSLY-FAKE team secret (>=32 chars, low entropy) — never a real credential.
FAKE_SECRET="FAKE-PRIVATE-TEAM-SECRET-000000000-not-real"
OTHER_SECRET="FAKE-OTHER-TEAM-SECRET-00000000000-not-real"
export PROJECT TEAMMATE_HAID FAKE_SECRET OTHER_SECRET

echo "============================================================"
echo "CLONE-JOIN falsifier — clone a private repo + start a session == on the wall"
echo "  home=$HEIMDALL_HOME  (local backend)"
echo "============================================================"
echo

# ── a mocked gh: answers `gh api repos/... --jq .private` per $MOCK_GH_MODE ───────
MOCKBIN="$EXT/mockbin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_GH_MODE:-private}" in
  private) echo "true" ;;
  public)  echo "false" ;;
  *)       echo "mock gh: unknown mode" >&2; exit 1 ;;
esac
EOF
chmod +x "$MOCKBIN/gh"

# ── a temp PLUGIN dir whose bin/heimdall-presence RECORDS a beat through the real
#    StateBackend seam, and whose bin/heimdall-team is a NO-OP (team.json already
#    ships in the clone; `auto` is irrelevant to the beat we are isolating). Every
#    OTHER $PLUGIN/bin/* the SessionStart command references is intentionally ABSENT
#    so its `[ -x ]` guard skips it — only these two stubs run. ──
PLUGINDIR="$EXT/plugin"; mkdir -p "$PLUGINDIR/bin"

cat > "$PLUGINDIR/bin/heimdall-team" <<'SH'
#!/usr/bin/env bash
# no-op: the clone already carries a committed team.json; `auto` would only
# (re)commit/gitignore — orthogonal to the presence beat this falsifier isolates.
exit 0
SH
chmod +x "$PLUGINDIR/bin/heimdall-team"

# The beat recorder: on `beat`, resolve the team secret FROM THE CWD's committed
# team.json (the capability the clone delivered), derive its team_id, and record the
# teammate present exactly where a real `heimdall-presence beat` would land. A marker
# file makes "did the beat fire at all" observable independently of the roster.
cat > "$PLUGINDIR/bin/heimdall-presence" <<SH
#!/usr/bin/env bash
[ "\$1" = "beat" ] || exit 0
: > "$EXT/beat-fired"    # observable marker: SessionStart dispatched a beat
LIB="$LIB" HEIMDALL_HOME="$HEIMDALL_HOME" HMD_HAID="\${HMD_HAID:-}" \\
HMD_PROJECT="\${HMD_PROJECT:-}" HMD_HANDLE="\${HMD_HANDLE:-teammate}" \\
CJ_TEAM_FILE="\$PWD/.heimdall/team.json" "$PY" - <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence as P
haid = os.environ.get("HMD_HAID") or ""
try:
    secret = (json.load(open(os.environ["CJ_TEAM_FILE"])).get("team_secret") or "")
except Exception:
    secret = ""
if not haid or not secret:
    sys.exit(0)
team_id = cp_auth.derive_team_id(secret)
P.record_presence(haid, project=os.environ.get("HMD_PROJECT") or "",
                  team_id=team_id, handle=os.environ.get("HMD_HANDLE") or "teammate",
                  verdict="working", file="-", home=os.environ["HEIMDALL_HOME"])
PYEOF
exit 0
SH
chmod +x "$PLUGINDIR/bin/heimdall-presence"

# ── read a roster back: the real cp_presence.roster_team_route on the public surface,
#    scoped to a presented secret's derived partition. Echoes the HAIDs it sees. ──
read_roster() {  # $1 = team secret to present
  HEIMDALL_PUBLIC_SURFACE=1 CJ_READ_SECRET="$1" "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
resp = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
                            "query": {"project": os.environ["PROJECT"]},
                            "team_secret": os.environ["CJ_READ_SECRET"],
                            "peer_ip": "10.0.0.1"},
                           home=os.environ["HEIMDALL_HOME"])
print(json.dumps({"status": resp.status,
                  "haids": [r.get("haid") for r in resp.body.get("online", [])]}))
PYEOF
}
roster_has() {  # $1=secret $2=haid -> 0 if present
  printf '%s' "$(read_roster "$1")" | HAID="$2" "$PY" -c \
    "import json,os,sys;print(os.environ['HAID'] in json.load(sys.stdin)['haids'])" 2>/dev/null \
    | grep -q True
}

# ── the REAL SessionStart hook command (extracted verbatim from hooks/hooks.json) ──
SS_CMD="$(HMD_HOOKS="$HOOKS_JSON" "$PY" - <<'PYEOF'
import json, os
d = json.load(open(os.environ["HMD_HOOKS"]))
print(d["hooks"]["SessionStart"][0]["hooks"][0]["command"], end="")
PYEOF
)"
[ -n "$SS_CMD" ] || { echo "FATAL: could not extract SessionStart command from hooks.json" >&2; exit 2; }

# ══════════════════════════════════════════════════════════════════════════════════
# OWNER: a PRIVATE repo whose team.json is COMMITTED (the clone == join substrate).
# ══════════════════════════════════════════════════════════════════════════════════
OWNER="$EXT/owner"
mkdir -p "$OWNER"
git -C "$OWNER" init -q
git -C "$OWNER" config user.email "owner@heimdall.local"
git -C "$OWNER" config user.name "Heimdall Owner"
git -C "$OWNER" remote add origin "https://github.com/fakeorg/private-widget.git"
git -C "$OWNER" commit -q --allow-empty -m "init"
OWNER_TD="$OWNER/.heimdall"
# Seed a fake team secret, then COMMIT it via the REAL private-repo path (mock gh=private).
HEIMDALL_TEAM_DIR="$OWNER_TD" "$TEAM_CLI" join "$FAKE_SECRET" >/dev/null 2>&1
( cd "$OWNER" && PATH="$MOCKBIN:$PATH" MOCK_GH_MODE=private HEIMDALL_TEAM_DIR="$OWNER_TD" \
    "$TEAM_CLI" share ) >/dev/null 2>"$EXT/share.err"
OWNER_TRACKED="$(git -C "$OWNER" ls-files -- .heimdall/team.json 2>/dev/null)"
if [ -n "$OWNER_TRACKED" ]; then
  ok "S1 owner's PRIVATE repo COMMITTED team.json (clone == join substrate is in place)"
else
  bad "S1 owner's team.json was not committed on a private repo — clone-join has nothing to deliver"; cat "$EXT/share.err" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════════
# TEAMMATE: git clone the owner repo → the clone ALREADY HAS the committed team.json.
# ══════════════════════════════════════════════════════════════════════════════════
CLONE="$EXT/teammate-clone"
git clone -q "$OWNER" "$CLONE" 2>/dev/null
CLONE_TJ="$CLONE/.heimdall/team.json"
CLONE_TRACKED="$(git -C "$CLONE" ls-files -- .heimdall/team.json 2>/dev/null)"
CLONE_SECRET="$(HMD_F="$CLONE_TJ" "$PY" -c "import json,os;print(json.load(open(os.environ['HMD_F'])).get('team_secret') or '')" 2>/dev/null || true)"
if [ -f "$CLONE_TJ" ] && [ -n "$CLONE_TRACKED" ] && [ "$CLONE_SECRET" = "$FAKE_SECRET" ]; then
  ok "S2 the teammate's CLONE carries the committed team.json (auto-join capability delivered by clone)"
else
  bad "S2 the clone did NOT carry team.json (tracked='$CLONE_TRACKED' secret_match=$([ "$CLONE_SECRET" = "$FAKE_SECRET" ]&&echo y||echo n))"
fi

# ── A. NEGATIVE CONTROL — before the session starts, the teammate is NOT on the roster.
A_ABSENT="False"; roster_has "$FAKE_SECRET" "$TEAMMATE_HAID" || A_ABSENT="True"
[ "$A_ABSENT" = "True" ] \
  && ok "A the teammate is ABSENT from the owner's roster before their first session (no pre-seed)" \
  || bad "A the teammate was already on the roster before their session — the proof would be vacuous"

# ── B. PRIMARY (RED-without-fix) — starting a session in the clone (the REAL SessionStart
#      hook) beats automatically → the teammate lands on the owner's roster. ──
( cd "$CLONE" && CLAUDE_PLUGIN_ROOT="$PLUGINDIR" HEIMDALL_HOME="$HEIMDALL_HOME" \
    HMD_HAID="$TEAMMATE_HAID" HMD_PROJECT="$PROJECT" HMD_HANDLE="teammate" \
    bash -c "$SS_CMD" ) >/dev/null 2>&1
# The hook backgrounds (team auto; beat); poll the roster within a bounded window.
B_PRESENT="no"; i=0
while [ "$i" -lt 50 ]; do
  if roster_has "$FAKE_SECRET" "$TEAMMATE_HAID"; then B_PRESENT="yes"; break; fi
  sleep 0.1; i=$((i+1))
done
B="$(read_roster "$FAKE_SECRET")"
if [ "$B_PRESENT" = "yes" ]; then
  ok "B the clone's FIRST SessionStart beat automatically → the teammate is on the owner's roster (out=$B)"
else
  bad "B the teammate never appeared on the owner's roster — SessionStart did NOT beat (the invisible-clone-join gap). beat_marker=$([ -f "$EXT/beat-fired" ]&&echo fired||echo none) out=$B"
fi

# ── C. ISOLATION — the beat lands ONLY in the owner's team, never cross-tenant. ──
C_ABSENT="False"; roster_has "$OTHER_SECRET" "$TEAMMATE_HAID" || C_ABSENT="True"
C="$(read_roster "$OTHER_SECRET")"
[ "$C_ABSENT" = "True" ] \
  && ok "C a DIFFERENT team secret sees NONE of the teammate's beat (multi-tenant isolation holds — out=$C)" \
  || bad "C the clone-join beat leaked across teams (a different secret saw the teammate) — out=$C"

# ══════════════════════════════════════════════════════════════════════════════════
# F. SECURITY FAIL-SAFE — a PUBLIC repo must NOT commit team.json, so a clone of it
#    carries NO secret and NOBODY auto-joins. (the cardinal leak guard, clone framing).
# ══════════════════════════════════════════════════════════════════════════════════
PUB="$EXT/public-owner"
mkdir -p "$PUB"
git -C "$PUB" init -q
git -C "$PUB" config user.email "owner@heimdall.local"
git -C "$PUB" config user.name "Heimdall Owner"
git -C "$PUB" remote add origin "https://github.com/fakeorg/public-widget.git"
git -C "$PUB" commit -q --allow-empty -m "init"
PUB_TD="$PUB/.heimdall"
HEIMDALL_TEAM_DIR="$PUB_TD" "$TEAM_CLI" join "$FAKE_SECRET" >/dev/null 2>&1
F_OUT="$( cd "$PUB" && PATH="$MOCKBIN:$PATH" MOCK_GH_MODE=public HEIMDALL_TEAM_DIR="$PUB_TD" \
          "$TEAM_CLI" share 2>"$EXT/pub.err"; echo "RC=$?" )"
F_RC="${F_OUT##*RC=}"
F_TRACKED="$(git -C "$PUB" ls-files -- .heimdall/team.json 2>/dev/null)"
F_TREE_HIT="$(git -C "$PUB" grep -lF "$FAKE_SECRET" 2>/dev/null || true)"
if [ "$F_RC" -ne 0 ] && [ -z "$F_TRACKED" ] && [ -z "$F_TREE_HIT" ]; then
  ok "F1 a PUBLIC repo HARD-REFUSED committing team.json (exit $F_RC): not tracked, secret NOT in the tree → a clone auto-joins NOBODY"
else
  bad "F1 a public repo should refuse to commit the secret (rc=$F_RC tracked='$F_TRACKED' tree_hit='$F_TREE_HIT')"; cat "$EXT/pub.err" >&2
fi
if grep -qi "public" "$EXT/pub.err" && grep -qiE "refus|expose|leak" "$EXT/pub.err"; then
  ok "F2 the public-repo refusal is LOUD (names PUBLIC + the leak risk)"
else
  bad "F2 the public refusal was not loud enough:"; cat "$EXT/pub.err" >&2
fi

echo
echo "============================================================"
printf "heimdall-team-clone-join: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

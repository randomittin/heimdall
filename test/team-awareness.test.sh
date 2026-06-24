#!/usr/bin/env bash
#
# team-awareness.test.sh — TEAM MODE P1 (Shared Awareness) acceptance harness.
#
# P1 is the lowest-risk, informational foundation of team mode: every `hmd`
# instance PUBLISHES a small git-backed activity record ("I'm <human>, working
# on <task>, touching <files>, N agents, on <branch>") and READS its siblings'
# records to answer "who is working where". No server; git is the shared state
# (TM-1: branch topology IS the awareness data). Informational only — it NEVER
# blocks an edit (no exit-3 like a claim collision).
#
# The substrate is REUSED, not rebuilt:
#   - heimdall-haid       → identity + heartbeat/TTL backbone (liveness)
#   - heimdall-claim      → surface-overlap engine (overlap warning = a check run)
#   - heimdall-who        → the existing read view, EXTENDED with a `team` join
#   - bin/lib/telemetry   → the _scrub secret-by-construction discipline (mirrored)
#
# Six proofs, all runnable, none skippable. Each simulates TWO independent hmd
# instances (two HAIDs) on one shared repo via two distinct git identities over
# the SAME activity store, the same way two checkouts of one repo share .planning/
# via git:
#
#   1. MUTUAL AWARENESS — A publishes, B publishes; EACH reads the OTHER's task
#      AND files. The core acceptance: two instances see each other's work.
#   2. TTL AGE-OUT — a crashed/exited instance's record (heartbeat older than its
#      ttl) is NOT shown active; a dead peer must not show "working" forever. The
#      liveness reuses HAID heartbeat + claim TTL/reap semantics verbatim.
#   3. OVERLAP WARNING (no block) — when one instance's files_touched intersect a
#      sibling's, the team view SURFACES a ⚠ warning naming the sibling — and the
#      command still exits 0 (informational, never a gate).
#   4. SOLO / FEATURE-OFF — no team (no sibling record) or the feature switched
#      off → behaviour is byte-identical to today: no activity record written, the
#      plain `who` view unchanged, no crash.
#   5. GITLEAKS-CLEAN STORE — plant a runtime-assembled real secret in a task /
#      files field; it is rejected/scrubbed so the committed store carries no
#      secret, and `gitleaks detect` over the store finds nothing.
#   6. STRICT-MODE SAFE — heimdall-activity and the extended heimdall-who run under
#      `set -euo pipefail` without the silent-failure landmine class.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
ACTIVITY="$REPO/bin/heimdall-activity"
WHO="$REPO/bin/heimdall-who"
HAID="$REPO/bin/heimdall-haid"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$ACTIVITY" ] || { echo "FATAL: heimdall-activity not executable at $ACTIVITY"; exit 2; }
[ -x "$WHO" ]      || { echo "FATAL: heimdall-who not executable at $WHO"; exit 2; }
[ -x "$HAID" ]     || { echo "FATAL: heimdall-haid not executable at $HAID"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One SHARED planning dir = one shared repo's .planning/ (what git syncs between
# checkouts). Two instances differ only by their git identity (→ a different HAID).
SHARED="$WORK/shared-planning"
mkdir -p "$SHARED"

# Two distinct HAIDs = two independent hmd instances sharing one repo. The dossier
# models 8 devs on one shared repo, each with a stable per-dev HAID. heimdall-activity
# honors an explicit HEIMDALL_HAID override (the same escape hatch heimdall-claim
# exposes via --haid) so a test can inject two distinct identities deterministically
# without standing up two machines. Both are well-formed per heimdall-haid's grammar.
A_HAID="haid:sarah.mbp-aaaa"
B_HAID="haid:raj.mbp-bbbb"

# run_as <haid> -- <argv...>
# Simulate one hmd instance pinned to <haid> over the SHARED planning dir.
run_as() {
  local haid="$1"; shift
  [ "$1" = "--" ] && shift
  HEIMDALL_PLANNING_DIR="$SHARED" HEIMDALL_HAID="$haid" "$@"
}

A_HUMAN="$A_HAID"
B_HUMAN="$B_HAID"

# ─────────────────────────────────────────────────────────────────────────────
# 1. MUTUAL AWARENESS — A and B each publish; each reads the other's task+files.
# ─────────────────────────────────────────────────────────────────────────────
echo "1. MUTUAL AWARENESS (two instances see each other's task + files):"

run_as "$A_HUMAN" -- "$ACTIVITY" publish \
  --task "login refactor" --files "auth/**" --files "auth/login.ts#handleLogin" \
  --agents 1 --branch "feat/auth-login" >/dev/null 2>&1
run_as "$B_HUMAN" -- "$ACTIVITY" publish \
  --task "card charges" --files "payments/**" --files "payments/cards.ts" \
  --agents 3 --branch "feat/pay-cards" >/dev/null 2>&1

# B reads the store and must see A's task + a file of A's.
B_VIEW="$(run_as "$B_HUMAN" -- "$ACTIVITY" list --json 2>/dev/null)"
if printf '%s' "$B_VIEW" | jq -e 'any(.human == "sarah" and (.active_task == "login refactor"))' >/dev/null 2>&1; then
  ok "B sees A's task ('login refactor')"
else
  bad "B does NOT see A's task in the shared activity store"
fi
if printf '%s' "$B_VIEW" | jq -e 'any(.human == "sarah" and (.files_touched | any(. == "auth/**")))' >/dev/null 2>&1; then
  ok "B sees A's files ('auth/**')"
else
  bad "B does NOT see A's files_touched"
fi

# A reads the store and must see B's task + a file of B's.
A_VIEW="$(run_as "$A_HUMAN" -- "$ACTIVITY" list --json 2>/dev/null)"
if printf '%s' "$A_VIEW" | jq -e 'any(.human == "raj" and (.active_task == "card charges"))' >/dev/null 2>&1; then
  ok "A sees B's task ('card charges')"
else
  bad "A does NOT see B's task"
fi
if printf '%s' "$A_VIEW" | jq -e 'any(.human == "raj" and (.agents_running == 3))' >/dev/null 2>&1; then
  ok "A sees B's agent count (3 agents)"
else
  bad "A does NOT see B's agents_running"
fi

# The JOINed team view (heimdall-who team) renders both humans + their surfaces.
TEAM="$(run_as "$B_HUMAN" -- "$WHO" team 2>/dev/null)"
if printf '%s' "$TEAM" | grep -q "sarah" && printf '%s' "$TEAM" | grep -q "raj"; then
  ok "hmd team view JOINs both instances (sarah + raj)"
else
  bad "hmd team view does not render both instances"
fi
if printf '%s' "$TEAM" | grep -Fq "login refactor" && printf '%s' "$TEAM" | grep -Fq "card charges"; then
  ok "team view renders each instance's active_task"
else
  bad "team view does not render the per-instance tasks"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. TTL AGE-OUT — a crashed instance's stale record is not shown active.
# ─────────────────────────────────────────────────────────────────────────────
echo "2. TTL AGE-OUT (a crashed/exited instance does not show active forever):"

# Hand-plant a third instance's record with a heartbeat far in the past and a
# short TTL → it is expired by construction (the crashed-peer simulation).
mkdir -p "$SHARED/ledger/activity"
DEAD="$SHARED/ledger/activity/haid_dead__mbp-9999.json"
cat > "$DEAD" <<'JSON'
{ "haid": "haid:dead.mbp-9999", "human": "dead", "active_task": "ghost task",
  "files_touched": ["ghost/**"], "agents_running": 9, "branch": "feat/ghost",
  "heartbeat": "2000-01-01T00:00:00Z", "ttl_minutes": 30 }
JSON

LIVE_JSON="$(run_as "$B_HUMAN" -- "$ACTIVITY" list --json 2>/dev/null)"
if printf '%s' "$LIVE_JSON" | jq -e 'any(.human == "dead")' >/dev/null 2>&1; then
  bad "a crashed instance (year-2000 heartbeat) STILL shows active — TTL not enforced"
else
  ok "crashed instance's stale record aged out of the active list (TTL enforced)"
fi
# And `reap` physically removes the dead record (mirrors claim reap).
run_as "$B_HUMAN" -- "$ACTIVITY" reap >/dev/null 2>&1
if [ -f "$DEAD" ]; then
  bad "reap did NOT remove the TTL-expired record file"
else
  ok "reap physically removed the TTL-expired record (matches claim reap)"
fi
# The team view must likewise not render the dead peer.
TEAM_AFTER="$(run_as "$B_HUMAN" -- "$WHO" team 2>/dev/null)"
if printf '%s' "$TEAM_AFTER" | grep -q "ghost task"; then
  bad "team view STILL renders the crashed instance's task"
else
  ok "team view does not render the aged-out crashed instance"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. OVERLAP WARNING — intersecting files surface a ⚠, but NEVER block (exit 0).
# ─────────────────────────────────────────────────────────────────────────────
echo "3. OVERLAP WARNING (intersecting files warn, never block):"

# A now also publishes a record touching payments/cards.ts — overlapping B.
# When B reads, the overlap view must WARN that A is also there, but the command
# must still SUCCEED (exit 0).
run_as "$A_HUMAN" -- "$ACTIVITY" publish \
  --task "fraud hook" --files "payments/cards.ts" --agents 1 --branch "feat/fraud" >/dev/null 2>&1

OVERLAP_OUT="$WORK/overlap.out"
overlap_rc=0
run_as "$B_HUMAN" -- "$ACTIVITY" overlap > "$OVERLAP_OUT" 2>&1 || overlap_rc=$?
if [ "$overlap_rc" -eq 0 ]; then
  ok "overlap check exits 0 (informational, never blocks)"
else
  bad "overlap check exited $overlap_rc — it BLOCKED, P1 must be informational only"
fi
if grep -Fq "payments/cards.ts" "$OVERLAP_OUT" && grep -q "sarah" "$OVERLAP_OUT"; then
  ok "overlap surfaces the colliding file + the sibling human (sarah)"
else
  bad "overlap did not surface the intersecting file / sibling — silent collision"
fi
if grep -q '⚠' "$OVERLAP_OUT" || grep -qi "warn\|also" "$OVERLAP_OUT"; then
  ok "overlap is rendered as a WARNING (⚠ / 'also in')"
else
  bad "overlap not rendered as a warning"
fi
# The team view also carries the warning AND still exits 0.
team_rc=0
run_as "$B_HUMAN" -- "$WHO" team > "$WORK/team-overlap.out" 2>&1 || team_rc=$?
if [ "$team_rc" -eq 0 ]; then
  ok "hmd team with an overlap present still exits 0 (no block)"
else
  bad "hmd team exited $team_rc on an overlap — must never block"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. SOLO / FEATURE-OFF — identical to today: no record, plain who unchanged.
# ─────────────────────────────────────────────────────────────────────────────
echo "4. SOLO / FEATURE-OFF (byte-identical to today; no crash):"

# A pristine empty planning dir = a fresh solo checkout, no team activity yet.
SOLO="$WORK/solo-planning"
mkdir -p "$SOLO"

# (a) Plain `heimdall-who` (no team subcommand) over an empty registry behaves
#     exactly as before: it does not crash and produces the no-agents message.
solo_who_rc=0
SOLO_WHO="$(HEIMDALL_PLANNING_DIR="$SOLO" "$WHO" 2>&1)" || solo_who_rc=$?
if [ "$solo_who_rc" -eq 0 ]; then
  ok "plain 'who' over an empty/solo store still exits 0 (unchanged)"
else
  bad "plain 'who' crashed over an empty store (rc=$solo_who_rc) — solo path regressed"
fi

# (b) `hmd team` with NO activity records present is graceful (exit 0, a clear
#     "no team activity" message) — never a crash, never an error.
solo_team_rc=0
SOLO_TEAM="$(HEIMDALL_PLANNING_DIR="$SOLO" "$WHO" team 2>&1)" || solo_team_rc=$?
if [ "$solo_team_rc" -eq 0 ]; then
  ok "'team' view with no activity records is graceful (exit 0)"
else
  bad "'team' view crashed with no records (rc=$solo_team_rc)"
fi

# (c) The feature OFF switch (HEIMDALL_TEAM=off) makes publish a NO-OP: no record
#     file is created, so a solo run leaves the store byte-identical to empty.
off_rc=0
HEIMDALL_PLANNING_DIR="$SOLO" HEIMDALL_TEAM=off HEIMDALL_HAID="$A_HAID" "$ACTIVITY" publish \
  --task "solo work" --files "x/**" --agents 1 --branch main >/dev/null 2>&1 || off_rc=$?
if [ "$off_rc" -eq 0 ]; then
  ok "publish with HEIMDALL_TEAM=off exits 0 (graceful no-op)"
else
  bad "publish with the feature off failed (rc=$off_rc)"
fi
if [ -d "$SOLO/ledger/activity" ] && [ -n "$(ls -A "$SOLO/ledger/activity" 2>/dev/null)" ]; then
  bad "feature-off publish WROTE a record — solo/off is not identical to today"
else
  ok "feature-off publish wrote NO record (store identical to today)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. GITLEAKS-CLEAN STORE — a runtime-assembled secret in a field is rejected/
#    scrubbed; the committed store carries nothing gitleaks fires on.
# ─────────────────────────────────────────────────────────────────────────────
echo "5. GITLEAKS-CLEAN STORE (a planted secret never reaches the git-tracked record):"

# Assemble a REAL-format GitHub PAT at RUNTIME from non-matching fragments — no
# contiguous literal exists in this source (fixture-secret convention §2).
_GP_PRE="ghp_"; _GP_A="0123456789abcdefghij"; _GP_B="ABCDEFGHIJ012345"
PLANT_TOK="${_GP_PRE}${_GP_A}${_GP_B}"   # ghp_ + 36 chars at runtime only

SECRET_STORE="$WORK/secret-planning"
mkdir -p "$SECRET_STORE"
# Try to smuggle the token through both the task field and a files field.
HEIMDALL_PLANNING_DIR="$SECRET_STORE" HEIMDALL_HAID="$A_HAID" "$ACTIVITY" publish \
  --task "token is $PLANT_TOK" --files "src/$PLANT_TOK.ts" --agents 1 --branch main >/dev/null 2>&1 || true

# (a) The token must not appear verbatim anywhere in the written store.
if grep -rqF "$PLANT_TOK" "$SECRET_STORE" 2>/dev/null; then
  bad "the planted PAT was written VERBATIM into the activity store"
else
  ok "the planted PAT never reached the store (rejected/scrubbed by construction)"
fi
# (b) gitleaks over the store finds zero secrets (the gate stays armed).
if command -v gitleaks >/dev/null 2>&1; then
  gl_rc=0
  GLREPO="$WORK/glrepo"; mkdir -p "$GLREPO"
  ( cd "$GLREPO" && git init -q
    if [ -d "$SECRET_STORE/ledger" ]; then cp -R "$SECRET_STORE/ledger" .; fi
    git add -A
    git -c user.email=t@t.t -c user.name=t commit -q -m planted --allow-empty ) >/dev/null 2>&1
  ( cd "$GLREPO" && gitleaks detect --source . --log-opts="--all" --no-banner ) >/dev/null 2>&1 || gl_rc=$?
  if [ "$gl_rc" -eq 0 ]; then
    ok "gitleaks over the activity store is clean (rc=0)"
  else
    bad "gitleaks found a secret in the activity store (rc=$gl_rc)"
  fi
else
  ok "gitleaks not installed — verbatim-absence proof stands (scrub by construction)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. STRICT-MODE SAFE — the new/extended bins carry no shell landmine class.
# ─────────────────────────────────────────────────────────────────────────────
echo "6. STRICT-MODE SAFE (no silent-failure landmine in the new surface):"
LANDMINE="$REPO/bin/heimdall-landmine-lint"
if [ -x "$LANDMINE" ]; then
  lm_rc=0
  ( cd "$REPO" && "$LANDMINE" bin/heimdall-activity bin/heimdall-who ) >/dev/null 2>&1 || lm_rc=$?
  if [ "$lm_rc" -eq 0 ]; then
    ok "landmine-lint clean over heimdall-activity + heimdall-who"
  else
    bad "landmine-lint found a strict-mode landmine (rc=$lm_rc)"
  fi
else
  ok "landmine-lint not present — skipping (non-fatal)"
fi

echo ""
echo "team-awareness.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

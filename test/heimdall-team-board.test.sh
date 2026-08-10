#!/usr/bin/env bash
#
# heimdall-team-board.test.sh — acceptance harness for the TEAM WALL layer:
# task records (heimdall-task), the live board (heimdall-board), the conflict
# pre-warning (heimdall-precheck-edit), and the gate/reuse leaderboard.
#
# Everything RIDES the existing coordination substrate — the board is a JOIN over
# stores that already compute their numbers (heimdall-who team, heimdall-claim,
# heimdall-task, .planning/reuse). This suite SEEDS those stores via the REAL bins
# (and, for a foreign teammate's claim, a per-HAID ledger file in the exact shape
# heimdall-claim writes — the same fixture technique team-gate-surface.test.sh uses
# for SI-2 attestations) and asserts the board renders REAL data, never fabricated.
#
# Instances differ only by HAID (injected via HEIMDALL_HAID) over ONE shared
# planning dir (what git syncs between checkouts) — the same simulation the P1/P2
# harnesses use. Mechanical asserts; a skip is a finding (no fake passes).
#
# Proofs:
#   1. TASK ROUND-TRIP     — add → list/show → assign → state → gate persists a record.
#   2. BOARD ROSTER        — one row per teammate carrying surface + task + REAL verdict.
#   3. PRECHECK WARNS      — precheck-edit exits 3 + names the holder on a held surface,
#                            exits 0 on a free one (advisory, never a hard block).
#   4. LEADERBOARD         — aggregates REAL gate-pass-rate + reuse per teammate.
#   5. PIPE = ANSI-CLEAN   — piped board/leaderboard carry zero ANSI escapes.
#   6. SOLO                — no teammates broadcasting → board still renders (just you).
#   7. RECONCILE           — a claim held with no live presence shows as a stale claim
#                            (the two substrates disagree → shown, never falsely merged).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BOARD="$REPO/bin/heimdall-board"
TASK="$REPO/bin/heimdall-task"
PRECHECK="$REPO/bin/heimdall-precheck-edit"
ACTIVITY="$REPO/bin/heimdall-activity"
GATE="$REPO/bin/heimdall-gate-surface"
REUSE="$REPO/bin/heimdall-reuse-metric"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

for b in "$BOARD" "$TASK" "$PRECHECK" "$ACTIVITY" "$GATE" "$REUSE"; do
  [ -x "$b" ] || { echo "FATAL: not executable: $b"; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHARED="$WORK/shared-planning"
mkdir -p "$SHARED/ledger/claims" "$SHARED/reuse"
ATTDIR="$WORK/attestations"
mkdir -p "$ATTDIR"

A_HAID="haid:sarah.mbp-aaaa"
B_HAID="haid:raj.mbp-bbbb"
C_HAID="haid:priya.mbp-cccc"

# run_as <haid> -- <argv...> — one hmd instance pinned to <haid>, team mode ON,
# over the SHARED planning dir.
run_as() {
  local haid="$1"; shift
  [ "$1" = "--" ] && shift
  HEIMDALL_PLANNING_DIR="$SHARED" HEIMDALL_HAID="$haid" HEIMDALL_TEAM=on "$@"
}

# seed_verdict <att-path> <task> <commit> <sympath> <line> <kind> — write an
# SI-2-shaped attestation and publish its verdict for <haid> (via the real bin).
seed_attestation() {
  local path="$1" task="$2" commit="$3" sp="$4" line="$5" kind="$6"
  local checks ran ap
  case "$kind" in
    proven)  checks='[{"cmd":"npm test","exit":0,"ok":true},{"cmd":"npm run lint","exit":0,"ok":true}]'; ran=2; ap=true ;;
    blocked) checks='[{"cmd":"npm test","exit":0,"ok":true},{"cmd":"secret-scan","exit":1,"ok":false}]'; ran=2; ap=false ;;
    *) echo "seed_attestation: bad kind $kind" >&2; return 1 ;;
  esac
  jq -n --arg task "$task" --arg commit "$commit" --arg sp "$sp" \
    --argjson line "$line" --argjson checks "$checks" --argjson ran "$ran" --argjson ap "$ap" '
    { schema:"si-2.1", task:$task, commit:$commit,
      claims:{ files:[{path:$sp}], file_count:1 },
      contracts:{ surface:[{path:$sp, name:"unit", kind:"function"}],
        by_file:[{path:$sp, symbols:[{name:"unit", kind:"function", span:[$line,99]}]}] },
      evidence:{ checks:$checks, ran:$ran, all_passed:$ap }, reuse:{}, risk:{} }' > "$path"
}

# seed_claim <haid> <human> <surface> — a foreign teammate's ACTIVE claim, written
# in the exact shape heimdall-claim writes (one file per HAID). This simulates a
# sibling checkout's claim; the REAL heimdall-claim overlap engine reads it.
seed_claim() {
  local haid="$1" human="$2" surface="$3" slug now
  slug="$(printf '%s' "$haid" | tr '/:' '__')"
  now="$(date -u +%FT%TZ)"
  jq -n --arg haid "$haid" --arg human "$human" --arg s "$surface" --arg now "$now" \
    '{haid:$haid, human:$human, claimed_surfaces:[$s], task_ref:"seeded",
      claimed_at:$now, ttl_minutes:90, heartbeat:$now}' \
    > "$SHARED/ledger/claims/${slug}.json"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "1. TASK ROUND-TRIP (the record persists across add → assign → state → gate):"
# ─────────────────────────────────────────────────────────────────────────────
run_as "$A_HAID" -- "$TASK" add --title "Auth login refactor" \
  --surface "auth/login.tsx#handleSubmit" --id "T-login" >/dev/null 2>&1
if run_as "$A_HAID" -- "$TASK" list --json | jq -e 'any(.task_id=="T-login" and .state=="todo" and .gate=="pending")' >/dev/null 2>&1; then
  ok "add creates a record (state todo, gate pending) with the linked surface"
else
  bad "add did not create the expected task record"
fi
if run_as "$A_HAID" -- "$TASK" show "T-login" --json | jq -e '.surfaces == ["auth/login.tsx#handleSubmit"]' >/dev/null 2>&1; then
  ok "the task links the SAME surface string the claim ledger uses"
else
  bad "the task surface was not linked"
fi
run_as "$A_HAID" -- "$TASK" assign "T-login" --haid "$A_HAID" >/dev/null 2>&1
run_as "$A_HAID" -- "$TASK" state  "T-login" doing >/dev/null 2>&1
run_as "$A_HAID" -- "$TASK" gate   "T-login" PROVEN >/dev/null 2>&1
if run_as "$A_HAID" -- "$TASK" show "T-login" --json \
   | jq -e '.assignee_haid=="'"$A_HAID"'" and .state=="doing" and .gate=="PROVEN"' >/dev/null 2>&1; then
  ok "assign + state + gate all persist (record round-trips)"
else
  bad "a state transition did not persist"
fi
# one-writer-per-file: the record is its own file (conflict-free merges).
if [ -f "$SHARED/ledger/tasks/T-login.json" ]; then
  ok "the task is a per-id file under ledger/tasks/ (one writer, git-mergeable)"
else
  bad "no per-id task file under ledger/tasks/"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "2. BOARD ROSTER (one row per teammate: surface + task + REAL verdict):"
# ─────────────────────────────────────────────────────────────────────────────
# Two teammates broadcast presence; each publishes a REAL gate verdict.
run_as "$A_HAID" -- "$ACTIVITY" publish --task "auth refactor" --files "auth/**" --branch feat/auth >/dev/null 2>&1
run_as "$B_HAID" -- "$ACTIVITY" publish --task "payments" --files "payments/cards.ts#charge" --agents 3 --branch feat/pay >/dev/null 2>&1
seed_attestation "$ATTDIR/a.json" "auth refactor" "aaaa1111" "auth/login.ts" 12 proven
run_as "$A_HAID" -- "$GATE" publish --attest "$ATTDIR/a.json" >/dev/null 2>&1
seed_attestation "$ATTDIR/b.json" "payments" "bbbb2222" "payments/cards.ts" 5 blocked
run_as "$B_HAID" -- "$GATE" publish --attest "$ATTDIR/b.json" >/dev/null 2>&1

BOARD_OUT="$(run_as "$A_HAID" -- "$BOARD" --plain 2>/dev/null)"
# sarah's row: her surface, her task, PROVEN.
if grep -Eq 'sarah.*T-login.*PROVEN' <<<"$BOARD_OUT"; then
  ok "sarah's row carries her task (T-login) + PROVEN verdict"
else
  bad "sarah's board row is missing task or PROVEN verdict"
fi
# raj's row: his surface + BLOCKED (the honest failing verdict, never softened).
if grep -Eq 'raj.*payments/cards\.ts.*BLOCKED' <<<"$BOARD_OUT"; then
  ok "raj's row carries his surface + BLOCKED verdict (never softened)"
else
  bad "raj's board row is missing surface or BLOCKED verdict"
fi
# exactly one roster row per teammate (2 present teammates → 2 rows).
ROWS="$(grep -cE '^║ ◉' <<<"$BOARD_OUT")"
if [ "$ROWS" -eq 2 ]; then
  ok "the board renders exactly one row per teammate (2 rows for 2 teammates)"
else
  bad "expected 2 teammate rows, got $ROWS"
fi
# the board is informational — it exits 0 even with a BLOCKED verdict present.
board_rc=0; run_as "$A_HAID" -- "$BOARD" --plain >/dev/null 2>&1 || board_rc=$?
if [ "$board_rc" -eq 0 ]; then ok "the board exits 0 (informational — never blocks)"; else bad "board exited $board_rc"; fi

# ─────────────────────────────────────────────────────────────────────────────
echo "3. PRECHECK PRE-WARNING (advisory: warns on a held surface, clear on a free one):"
# ─────────────────────────────────────────────────────────────────────────────
# A foreign teammate (priya) holds a symbol in auth/login.tsx.
seed_claim "$C_HAID" "priya" "auth/login.tsx#handleSubmit"

set +e
HELD_OUT="$(HEIMDALL_PLANNING_DIR="$SHARED" "$PRECHECK" "auth/login.tsx" 2>&1)"; HELD_RC=$?
set -e
if [ "$HELD_RC" -eq 3 ]; then
  ok "precheck-edit exits 3 when a live teammate holds the file"
else
  bad "precheck-edit did not exit 3 on a held surface (rc=$HELD_RC)"
fi
if grep -Eq "priya's agent holds auth/login\.tsx#handleSubmit" <<<"$HELD_OUT"; then
  ok "the warning names the holder + the exact held surface"
else
  bad "the warning did not name the holder/surface: [$HELD_OUT]"
fi
# The SAME check via the PreToolUse(Edit) stdin JSON shape (how the hook feeds it).
set +e
JSON_OUT="$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"auth/login.tsx"}}' \
  | HEIMDALL_PLANNING_DIR="$SHARED" "$PRECHECK" 2>&1)"; JSON_RC=$?
set -e
if [ "$JSON_RC" -eq 3 ] && grep -q "priya's agent holds" <<<"$JSON_OUT"; then
  ok "precheck-edit reads the PreToolUse(Edit) stdin JSON and warns identically"
else
  bad "precheck-edit did not handle the stdin JSON form (rc=$JSON_RC)"
fi
# A free file → exit 0, no warning (never blocks work on an unclaimed surface).
set +e
HEIMDALL_PLANNING_DIR="$SHARED" "$PRECHECK" "src/unclaimed.ts" >/dev/null 2>&1; FREE_RC=$?
set -e
if [ "$FREE_RC" -eq 0 ]; then
  ok "precheck-edit exits 0 on a free surface"
else
  bad "precheck-edit did not exit 0 on a free surface (rc=$FREE_RC)"
fi
# Advisory guarantee: it must NOT emit the exit-2 'deny' that hard-blocks a human.
if [ "$HELD_RC" -ne 2 ] && [ "$JSON_RC" -ne 2 ]; then
  ok "precheck-edit never emits the exit-2 hard-block (advisory, not a wall)"
else
  bad "precheck-edit emitted a hard-block exit-2 — it must only warn"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "4. LEADERBOARD (REAL gate-pass-rate + reuse per teammate, no fabricated stats):"
# ─────────────────────────────────────────────────────────────────────────────
# A real reuse record for sarah's task (computed by the real analyzer from a job
# where new code CALLS a pre-existing symbol → reuse_pct = 1.0).
cat > "$WORK/reuse-job.json" <<'JOB'
{"task":"auth refactor","engine":"heuristic",
 "pre_files":{"lib/auth_core.py":"def verify_token(t):\n    return len(t) > 0\n"},
 "changed_files":{"app/login.py":"from lib.auth_core import verify_token\ndef handle_login(t):\n    return verify_token(t)\n"}}
JOB
# NOTE: heimdall-reuse-metric can return a nonzero rc on a clean run (its EXIT-trap
# cleanup returns 1 when the job was fed via --json-job); the record is still
# written correctly. We only care about the emitted record, so ignore its rc.
"$REUSE" --json-job "$WORK/reuse-job.json" --task "auth refactor" \
  --out "$SHARED/reuse/r-auth.json" >/dev/null 2>&1 || true

LB_OUT="$(run_as "$A_HAID" -- "$BOARD" --leaderboard --plain 2>/dev/null)"
# sarah PROVEN 2/2 → 100% pass-rate, and reuse 100% (real numbers).
if grep -Eq 'sarah.*100%.*\(2/2\)' <<<"$LB_OUT"; then
  ok "sarah ranks with a REAL 100% gate-pass-rate (2/2 from her verdict)"
else
  bad "sarah's real pass-rate is missing from the leaderboard"
fi
if grep -Eq 'sarah.*reuse 100%' <<<"$LB_OUT"; then
  ok "sarah's REAL reuse score (100%) is aggregated onto her ranking"
else
  bad "the reuse-metric score was not aggregated onto the leaderboard"
fi
# raj BLOCKED 1/2 → 50% pass-rate (honest — a failing gate is a real 50%, not hidden).
if grep -Eq 'raj.*50%.*\(1/2\)' <<<"$LB_OUT"; then
  ok "raj ranks with his REAL 50% pass-rate (1/2 — a BLOCKED verdict is not hidden)"
else
  bad "raj's real (failing) pass-rate is missing from the leaderboard"
fi
# ranking order: the 100% teammate outranks the 50% one.
SARAH_LINE="$(grep -n 'sarah' <<<"$LB_OUT" | head -1 | cut -d: -f1)"
RAJ_LINE="$(grep -n 'raj' <<<"$LB_OUT" | head -1 | cut -d: -f1)"
if [ -n "$SARAH_LINE" ] && [ -n "$RAJ_LINE" ] && [ "$SARAH_LINE" -lt "$RAJ_LINE" ]; then
  ok "the leaderboard ranks the higher pass-rate teammate first (real ordering)"
else
  bad "the leaderboard ordering is not by pass-rate"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "5. PIPE = ANSI-CLEAN (piped board/leaderboard carry zero ANSI escapes):"
# ─────────────────────────────────────────────────────────────────────────────
# NOTE: no --plain here — a pipe (non-tty stdout) must strip colour on its own.
if run_as "$A_HAID" -- "$BOARD" 2>/dev/null | LC_ALL=C grep -q $'\033'; then
  bad "the piped board leaked ANSI escapes"
else
  ok "the piped board is ANSI-clean (no escape sequences)"
fi
if run_as "$A_HAID" -- "$BOARD" --leaderboard 2>/dev/null | LC_ALL=C grep -q $'\033'; then
  bad "the piped leaderboard leaked ANSI escapes"
else
  ok "the piped leaderboard is ANSI-clean"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "6. SOLO (no teammates broadcasting → the board still renders, just you):"
# ─────────────────────────────────────────────────────────────────────────────
SOLO="$WORK/solo-planning"
mkdir -p "$SOLO"
solo_rc=0
SOLO_OUT="$(HEIMDALL_PLANNING_DIR="$SOLO" HEIMDALL_HAID="haid:solo.mbp-zzzz" "$BOARD" --plain 2>/dev/null)" || solo_rc=$?
if [ "$solo_rc" -eq 0 ] && grep -q "HEIMDALL TEAM BOARD" <<<"$SOLO_OUT"; then
  ok "the board renders (exit 0) with no teammates — solo degrades gracefully"
else
  bad "the solo board did not render gracefully (rc=$solo_rc)"
fi
if grep -q "solo" <<<"$SOLO_OUT"; then
  ok "the solo board shows just you (the current identity)"
else
  bad "the solo board did not show the current identity"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "7. RECONCILE (a claim held with no live presence → shown as a stale claim):"
# ─────────────────────────────────────────────────────────────────────────────
# priya holds a claim (seeded in proof 3) but never published a presence/activity
# record. The board must NOT merge her into "online" — it marks the claim stale,
# reconciling the two substrates honestly (show both, never assert a false union).
RECON_OUT="$(run_as "$A_HAID" -- "$BOARD" --plain 2>/dev/null)"
if grep -Eq 'priya.*stale' <<<"$RECON_OUT"; then
  ok "a claim with no live presence is shown as a stale claim (substrates reconciled)"
else
  bad "the stale claim was silently merged or dropped (false unified state)"
fi
# the online count must not include the stale (presence-less) teammate.
if grep -Eq '2 online' <<<"$RECON_OUT"; then
  ok "the online count reflects presence only (2), not the stale claim holder"
else
  bad "the online count wrongly included a presence-less claim holder"
fi

echo ""
echo "heimdall-team-board.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

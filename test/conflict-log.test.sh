#!/usr/bin/env bash
# test/conflict-log.test.sh — the conflict-reflection quality gate must be
# FALSIFIABLE: logging a conflict must be able to fail the gate it exists to
# feed, and reflecting on it must be able to pass the gate again.
#
# THE BUG THIS GUARDS. bin/heimdall-state ships default
# quality_gates.conflict_reflection_done = true, and — before this fix —
# cmd_add_conflict() never set it false. Only bin/conflict-log's reflect-all
# ever touched the flag (and only back to true). So the flag could go
# true -> true forever: heimdall-state check-quality-gates could NEVER
# observe an unresolved conflict, no matter how many were logged via
# `conflict-log add`. A gate that cannot fail is not a gate. This test proves
# add flips it false and reflect-all flips it back — both directions, both
# falsifiable, matching the existing pattern already used the other way round
# in bin/conflict-log's own cmd_reflect_all.
#
# Hermetic: HEIMDALL_STATE_FILE points at a throwaway file in a mktemp dir;
# PATH is prepended with this repo's bin/ so conflict-log resolves OUR
# heimdall-state, not any other one on the host. No network, no model call.
#
# EXIT: 0 = all assertions pass; 1 = any FAIL.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -x "$ROOT/bin/conflict-log" ]   || { echo "FATAL: bin/conflict-log not executable"   >&2; exit 2; }
[ -x "$ROOT/bin/heimdall-state" ] || { echo "FATAL: bin/heimdall-state not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/conflict-log-test-XXXXXX")" || { echo "FATAL: no workdir" >&2; exit 2; }
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

export PATH="$ROOT/bin:$PATH"
export HEIMDALL_STATE_FILE="$WORK/heimdall-state.json"

# ══════════════════════════════════════════════════════════════════════════
# Setup: fresh state, bypass the tests/lint gates so only reflection is live
# ══════════════════════════════════════════════════════════════════════════
heimdall-state init >/dev/null 2>&1
heimdall-state set '.quality_gates.tests_passing' true >/dev/null 2>&1
heimdall-state set '.quality_gates.lint_clean' true >/dev/null 2>&1

# ── 1. baseline: fresh state passes the gate (default reflection = true) ───
if heimdall-state check-quality-gates >/dev/null 2>&1; then
  ok "fresh state (no conflicts yet) passes check-quality-gates"
else
  bad "fresh state should pass check-quality-gates before any conflict is logged"
fi

# ── 2. conflict-log add MUST invalidate conflict_reflection_done ───────────
conflict-log add "skill-a" "skill-b" "contradictory guidance on X" "chose skill-a because Y" >/dev/null 2>&1

reflected_flag="$(jq -r '.quality_gates.conflict_reflection_done' "$HEIMDALL_STATE_FILE")"
if [ "$reflected_flag" = "false" ]; then
  ok "conflict-log add flips quality_gates.conflict_reflection_done to false"
else
  bad "conflict-log add left conflict_reflection_done=$reflected_flag — the gate cannot be failed (THE BUG)"
fi

logged_count="$(jq '.conflict_log | length' "$HEIMDALL_STATE_FILE")"
[ "$logged_count" -eq 1 ] && ok "conflict_log has exactly 1 entry after one add" \
                           || bad "expected 1 conflict_log entry, got $logged_count"

# ── 3. check-quality-gates MUST now fail, citing reflection specifically ───
err_out="$(heimdall-state check-quality-gates 2>&1 1>/dev/null)"
rc=0
heimdall-state check-quality-gates >/dev/null 2>/dev/null || rc=$?
if [ "$rc" -eq 2 ]; then
  ok "check-quality-gates exits 2 once an unresolved conflict is logged"
else
  bad "check-quality-gates should exit 2 with an unresolved conflict, got rc=$rc"
fi
case "$err_out" in
  *"Conflict reflection not done"*) ok "check-quality-gates names the real failed gate" ;;
  *) bad "check-quality-gates stderr missing 'Conflict reflection not done': $err_out" ;;
esac

# ── 4. unresolved lists exactly the unreflected entry ──────────────────────
unresolved_count="$(conflict-log unresolved 2>/dev/null | jq 'length')"
[ "$unresolved_count" -eq 1 ] && ok "conflict-log unresolved lists the 1 unreflected entry" \
                              || bad "expected 1 unresolved entry, got $unresolved_count"

# ── 5. reflect-all flips it back to true, and the gate passes again ────────
conflict-log reflect-all >/dev/null 2>&1

reflected_flag2="$(jq -r '.quality_gates.conflict_reflection_done' "$HEIMDALL_STATE_FILE")"
[ "$reflected_flag2" = "true" ] && ok "conflict-log reflect-all restores conflict_reflection_done=true" \
                                 || bad "reflect-all left conflict_reflection_done=$reflected_flag2"

if heimdall-state check-quality-gates >/dev/null 2>&1; then
  ok "check-quality-gates passes again after reflect-all"
else
  bad "check-quality-gates should pass after reflect-all resolves the conflict"
fi

still_unresolved="$(conflict-log unresolved 2>/dev/null | jq 'length')"
[ "$still_unresolved" -eq 0 ] && ok "no unresolved conflicts remain after reflect-all" \
                              || bad "expected 0 unresolved after reflect-all, got $still_unresolved"

# ── 6. mark-reflected marks one entry WITHOUT touching the aggregate flag ──
# (existing, unchanged contract — regression guard, not the bug this file fixes)
conflict-log add "skill-c" "skill-d" "second contradiction" "chose skill-c because Z" >/dev/null 2>&1
conflict-log mark-reflected 1 >/dev/null 2>&1   # index 1 = the 2nd entry (0-based)

entry1_reflected="$(jq -r '.conflict_log[1].reflected' "$HEIMDALL_STATE_FILE")"
[ "$entry1_reflected" = "true" ] && ok "mark-reflected <idx> flips that entry's own reflected flag" \
                                  || bad "mark-reflected did not flip conflict_log[1].reflected"

# ── summary ──────────────────────────────────────────────────────────────
printf "\n  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

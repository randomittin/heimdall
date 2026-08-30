#!/usr/bin/env bash
# test/heimdall-metric-compliance.test.sh
#
# Verifies bin/heimdall-metric-compliance: a read-only audit tool that measures
# the gap between "tasks the orchestrator plausibly completed" (distinct
# TodoWrite items ever marked completed in a session transcript) and
# "orchestrator-sourced heimdall-metric records" (the same qualifying filter
# hooks/heimdall-metric-reminder.sh already uses), correlated by transcript
# timestamp window because heimdall-metric's `session` field is structurally
# dead in this harness (every real row carries "default"). Synthetic fixtures
# only, hand-verified counts, hermetic $TMPDIR sandbox -- NEVER touches the
# real .planning/metrics.jsonl, same convention as
# test/heimdall-caveman-compliance.test.sh.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-metric-compliance"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

get() { python3 -c "import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])" "$OUT" "$1"; }

if [ -x "$TOOL" ]; then
  ok "bin/heimdall-metric-compliance is executable"
else
  bad "bin/heimdall-metric-compliance is executable"
fi

# ---------------------------------------------------------------------------
# Fixture: a session transcript with 4 TodoWrite snapshots.
#   snap1 (T1): task-a in_progress, task-b pending               -> 0 completed
#   snap2 (T2): task-a completed,   task-b in_progress            -> +task-a
#   snap3 (T4): task-a completed, task-b completed, task-c pending -> +task-b
#                (task-a repeats -- must dedup, not double count)
#   snap4 (T6): task-c completed ONLY (task-a/b dropped from the list --
#               list churn must not un-count a prior completion)  -> +task-c
# A non-TodoWrite tool_use (Bash) and a plain text turn are interleaved and
# must be ignored. Window = min/max top-level "timestamp" across all lines
# = T0 .. T6 = 2026-08-30T10:00:00 .. 2026-08-30T10:04:00 (whole seconds,
# fractional part truncated).
# Expected: todo_writes_seen=4, plausibly_completed=3 (task-a, task-b, task-c).
# ---------------------------------------------------------------------------
SESSION="$TMPDIR/session.jsonl"
cat > "$SESSION" <<'JSONL'
{"type":"user","timestamp":"2026-08-30T10:00:00.100Z","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
{"type":"assistant","timestamp":"2026-08-30T10:01:00.100Z","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"task-a","status":"in_progress"},{"content":"task-b","status":"pending"}]}}]}}
{"type":"assistant","timestamp":"2026-08-30T10:02:00.100Z","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"task-a","status":"completed"},{"content":"task-b","status":"in_progress"}]}}]}}
{"type":"assistant","timestamp":"2026-08-30T10:02:30.100Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
{"type":"assistant","timestamp":"2026-08-30T10:03:00.100Z","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"task-a","status":"completed"},{"content":"task-b","status":"completed"},{"content":"task-c","status":"pending"}]}}]}}
{"type":"assistant","timestamp":"2026-08-30T10:03:30.100Z","message":{"content":[{"type":"text","text":"almost done"}]}}
{not valid json at all
{"type":"assistant","message":{"content":"not-a-list"}}
{"type":"assistant","timestamp":"2026-08-30T10:04:00.100Z","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"task-c","status":"completed"}]}}]}}
JSONL

# ---------------------------------------------------------------------------
# Fixture: metrics.jsonl with rows in every relevant bucket:
#   (a) IN window, fully qualifying (source=orchestrator, task_type set,
#       outcome=pass)                                    -> 2026-08-30T10:01:30Z
#   (b) IN window, fully qualifying, outcome=fail (fail must count same as
#       pass)                                             -> 2026-08-30T10:03:45Z
#   (c) BEFORE window (qualifying otherwise)               -> 2026-08-30T09:59:00Z
#   (d) AFTER window (qualifying otherwise)                -> 2026-08-30T10:10:00Z
#   (e) IN window, wrong source (subagentstop)             -> 2026-08-30T10:02:15Z
#   (f) IN window, missing outcome                         -> 2026-08-30T10:02:20Z
#   (g) IN window, missing task_type                       -> 2026-08-30T10:02:25Z
#   (h) IN window, gate source                             -> 2026-08-30T10:02:35Z
#   (i) malformed line
# Expected qualifying_orchestrator_records == 2 (only a, b).
# Expected gap = plausibly_completed(3) - 2 = 1.
# session field is "default" on every row (realistic) -- the transcript's own
# derived session id slugs to "session" (from session.jsonl), which != "default",
# so session_field_exact_matches must read 0 even though 2 rows truly qualify --
# that pairing is the whole point of this tool's existence.
# ---------------------------------------------------------------------------
METRICS="$TMPDIR/metrics.jsonl"
cat > "$METRICS" <<'JSONL'
{"ts":"2026-08-30T10:01:30Z","session":"default","metric":"task","task_type":"code","source":"orchestrator","outcome":"pass"}
{"ts":"2026-08-30T10:03:45Z","session":"default","metric":"task","task_type":"review","source":"orchestrator","outcome":"fail"}
{"ts":"2026-08-30T09:59:00Z","session":"default","metric":"task","task_type":"code","source":"orchestrator","outcome":"pass"}
{"ts":"2026-08-30T10:10:00Z","session":"default","metric":"task","task_type":"code","source":"orchestrator","outcome":"pass"}
{"ts":"2026-08-30T10:02:15Z","session":"default","metric":"task","task_type":"code","source":"subagentstop","outcome":"pass"}
{"ts":"2026-08-30T10:02:20Z","session":"default","metric":"task","task_type":"code","source":"orchestrator","outcome":null}
{"ts":"2026-08-30T10:02:25Z","session":"default","metric":"task","task_type":"","source":"orchestrator","outcome":"pass"}
{"ts":"2026-08-30T10:02:35Z","session":"default","metric":"task","task_type":null,"source":"gate-pre-commit","outcome":"pass"}
{garbage not json
JSONL

OUT="$(python3 "$TOOL" "$SESSION" --metrics-file "$METRICS" --json)"
RC=$?
[ "$RC" -eq 0 ] && ok "tool exits 0 on well-formed session+metrics fixture" || bad "tool exits 0 on well-formed session+metrics fixture (rc=$RC)"

val="$(get todo_writes_seen)"
[ "$val" = "4" ] && ok "todo_writes_seen == 4 (got $val)" || bad "todo_writes_seen == 4 (got $val)"

val="$(get plausibly_completed)"
[ "$val" = "3" ] && ok "plausibly_completed == 3, dedup across snapshots + churn-safe (got $val)" || bad "plausibly_completed == 3 (got $val)"

val="$(get session_id)"
[ "$val" = "session" ] && ok "session_id derived from filename == 'session' (got $val)" || bad "session_id derived from filename (got $val)"

val="$(get qualifying_orchestrator_records)"
[ "$val" = "2" ] && ok "qualifying_orchestrator_records == 2, window+predicate both applied (got $val)" || bad "qualifying_orchestrator_records == 2 (got $val)"

val="$(get gap)"
[ "$val" = "1" ] && ok "gap == plausibly_completed - qualifying == 1 (got $val)" || bad "gap == 1 (got $val)"

val="$(get session_field_exact_matches)"
[ "$val" = "0" ] && ok "session_field_exact_matches == 0 despite 2 true qualifiers -- proves the session-field degeneracy (got $val)" || bad "session_field_exact_matches == 0 (got $val)"

val="$(get metrics_file_found)"
[ "$val" = "True" ] && ok "metrics_file_found == True (got $val)" || bad "metrics_file_found == True (got $val)"

# ---------------------------------------------------------------------------
# Positive control for session_field_exact_matches: name a transcript so its
# derived id slugs to something a metrics row's `session` field can actually
# match, and confirm the counter fires. This is the ONE code path real data
# never exercises (every real row is "default") -- worth proving it works.
# ---------------------------------------------------------------------------
SESSION2="$TMPDIR/abc123.jsonl"
cat > "$SESSION2" <<'JSONL'
{"type":"assistant","timestamp":"2026-08-30T11:00:00.000Z","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"x","status":"completed"}]}}]}}
JSONL
METRICS2="$TMPDIR/metrics2.jsonl"
cat > "$METRICS2" <<'JSONL'
{"ts":"2026-08-30T11:00:00Z","session":"abc123","metric":"task","task_type":"code","source":"orchestrator","outcome":"pass"}
JSONL
OUT="$(python3 "$TOOL" "$SESSION2" --metrics-file "$METRICS2" --json)"
val="$(get session_field_exact_matches)"
[ "$val" = "1" ] && ok "session_field_exact_matches == 1 when session id truly matches (got $val)" || bad "session_field_exact_matches == 1 positive control (got $val)"

# ---------------------------------------------------------------------------
# Metrics file ABSENT: a certain zero, not null/unknown. gap == plausibly_completed.
# ---------------------------------------------------------------------------
ABSENT="$TMPDIR/no-such-metrics.jsonl"
OUT="$(python3 "$TOOL" "$SESSION" --metrics-file "$ABSENT" --json)"
RC=$?
[ "$RC" -eq 0 ] && ok "absent metrics file still exits 0" || bad "absent metrics file still exits 0 (rc=$RC)"
val="$(get metrics_file_found)"
[ "$val" = "False" ] && ok "absent metrics file: metrics_file_found == False (got $val)" || bad "metrics_file_found == False (got $val)"
val="$(get qualifying_orchestrator_records)"
[ "$val" = "0" ] && ok "absent metrics file: qualifying_orchestrator_records == 0, a certain zero (got $val)" || bad "qualifying_orchestrator_records == 0 on absence (got $val)"
val="$(get gap)"
[ "$val" = "3" ] && ok "absent metrics file: gap == plausibly_completed == 3 (got $val)" || bad "gap == 3 on absent metrics (got $val)"

# ---------------------------------------------------------------------------
# Metrics file UNREADABLE (exists, permission denied): unknown, NOT zero.
# Same "absence is a fact, unreadable is not" rule as the reminder hook.
# (Not root-guarded -- test/heimdall-metric-reminder.test.sh's own unreadable-
# ledger case follows the same convention.)
# ---------------------------------------------------------------------------
UNREADABLE="$TMPDIR/unreadable-metrics.jsonl"
cp "$METRICS" "$UNREADABLE"
chmod 000 "$UNREADABLE"
OUT="$(python3 "$TOOL" "$SESSION" --metrics-file "$UNREADABLE" --json)"
RC=$?
chmod 644 "$UNREADABLE"
if [ ! -r "$UNREADABLE" ] || [ "$(id -u)" != "0" ]; then
  : # best-effort: only assert when the chmod actually blocked this process
fi
val="$(get qualifying_orchestrator_records)"
if [ "$(id -u)" = "0" ]; then
  ok "unreadable-metrics case skipped assertion under root (chmod 000 has no effect)"
else
  [ "$val" = "None" ] && ok "unreadable metrics file: qualifying_orchestrator_records == null, not 0 (got $val)" || bad "qualifying_orchestrator_records == null when unreadable (got $val)"
  val="$(get gap)"
  [ "$val" = "None" ] && ok "unreadable metrics file: gap == null (got $val)" || bad "gap == null when metrics unreadable (got $val)"
fi
[ "$RC" -eq 0 ] && ok "unreadable metrics file still exits 0" || bad "unreadable metrics file still exits 0 (rc=$RC)"

# ---------------------------------------------------------------------------
# Missing session transcript (typo'd path, not a missing ARGUMENT): fail-open,
# exit 0, reports an error field.
# ---------------------------------------------------------------------------
OUT="$(python3 "$TOOL" "$TMPDIR/does-not-exist.jsonl" --metrics-file "$METRICS" --json)"
RC=$?
[ "$RC" -eq 0 ] && ok "missing session transcript still exits 0 (fail-open)" || bad "missing session transcript still exits 0 (rc=$RC)"
case "$OUT" in
  *'"error"'*'no such session transcript'*) ok "missing session transcript reports the specific error" ;;
  *) bad "missing session transcript reports the specific error (got: $OUT)" ;;
esac

# ---------------------------------------------------------------------------
# --all aggregate mode: 2 readable transcripts (2 + 3 = 5 completed) plus one
# UNREADABLE transcript that must be skipped, not fatal. Metrics file carries
# 2 qualifying rows total (one with a timestamp WAY outside any transcript's
# own window, proving --all does NOT time-filter) + 1 non-qualifying row.
# Expected: transcripts_scanned=2, transcripts_skipped=1,
# plausibly_completed_total=5, qualifying_orchestrator_records_total=2, gap=3.
# ---------------------------------------------------------------------------
ALLDIR="$TMPDIR/alldir"
mkdir -p "$ALLDIR"
cat > "$ALLDIR/one.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-08-30T09:00:00.000Z","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"p","status":"completed"},{"content":"q","status":"completed"}]}}]}}
JSONL
cat > "$ALLDIR/two.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-08-30T20:00:00.000Z","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"r","status":"completed"},{"content":"s","status":"completed"},{"content":"t","status":"completed"}]}}]}}
JSONL
cat > "$ALLDIR/three-unreadable.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-08-30T21:00:00.000Z","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"z","status":"completed"}]}}]}}
JSONL
chmod 000 "$ALLDIR/three-unreadable.jsonl"

ALLMETRICS="$TMPDIR/all-metrics.jsonl"
cat > "$ALLMETRICS" <<'JSONL'
{"ts":"2026-08-30T09:30:00Z","session":"default","metric":"task","task_type":"code","source":"orchestrator","outcome":"pass"}
{"ts":"1999-01-01T00:00:00Z","session":"default","metric":"task","task_type":"code","source":"orchestrator","outcome":"fail"}
{"ts":"2026-08-30T09:30:05Z","session":"default","metric":"task","task_type":"code","source":"subagentstop","outcome":"pass"}
JSONL

if [ "$(id -u)" = "0" ]; then
  ok "--all unreadable-skip assertions skipped under root (chmod 000 has no effect)"
else
  OUT="$(python3 "$TOOL" --all "$ALLDIR" --metrics-file "$ALLMETRICS" --json)"
  RC=$?
  [ "$RC" -eq 0 ] && ok "--all mode exits 0" || bad "--all mode exits 0 (rc=$RC)"
  val="$(get transcripts_scanned)"
  [ "$val" = "2" ] && ok "--all transcripts_scanned == 2 (got $val)" || bad "--all transcripts_scanned == 2 (got $val)"
  val="$(get transcripts_skipped)"
  [ "$val" = "1" ] && ok "--all transcripts_skipped == 1, unreadable file skipped not fatal (got $val)" || bad "--all transcripts_skipped == 1 (got $val)"
  val="$(get plausibly_completed_total)"
  [ "$val" = "5" ] && ok "--all plausibly_completed_total == 5 (got $val)" || bad "--all plausibly_completed_total == 5 (got $val)"
  val="$(get qualifying_orchestrator_records_total)"
  [ "$val" = "2" ] && ok "--all qualifying_orchestrator_records_total == 2, no time-window filtering (got $val)" || bad "--all qualifying_orchestrator_records_total == 2 (got $val)"
  val="$(get gap)"
  [ "$val" = "3" ] && ok "--all gap == 5 - 2 == 3 (got $val)" || bad "--all gap == 3 (got $val)"
fi
chmod 644 "$ALLDIR/three-unreadable.jsonl" 2>/dev/null

# ---------------------------------------------------------------------------
# --all with a nonexistent directory: fail-open, exit 0, error field.
# ---------------------------------------------------------------------------
OUT="$(python3 "$TOOL" --all "$TMPDIR/no-such-dir" --json)"
RC=$?
[ "$RC" -eq 0 ] && ok "--all on missing dir still exits 0" || bad "--all on missing dir still exits 0 (rc=$RC)"
case "$OUT" in
  *'"error"'*) ok "--all on missing dir reports an error field" ;;
  *) bad "--all on missing dir reports an error field (got: $OUT)" ;;
esac

# ---------------------------------------------------------------------------
# --repo / HEIMDALL_PLANNING_DIR default metrics-file resolution (mirrors
# bin/heimdall-metric's own _metrics_path convention).
# ---------------------------------------------------------------------------
FAKEREPO="$TMPDIR/fakerepo"
mkdir -p "$FAKEREPO/.planning"
cat > "$FAKEREPO/.planning/metrics.jsonl" <<'JSONL'
{"ts":"2026-08-30T10:01:30Z","session":"default","metric":"task","task_type":"code","source":"orchestrator","outcome":"pass"}
JSONL
OUT="$(python3 "$TOOL" "$SESSION" --repo "$FAKEREPO" --json)"
val="$(get metrics_file)"
[ "$val" = "$FAKEREPO/.planning/metrics.jsonl" ] && ok "--repo resolves default metrics_file path (got $val)" || bad "--repo resolves default metrics_file path (got $val)"
val="$(get qualifying_orchestrator_records)"
[ "$val" = "1" ] && ok "--repo-resolved metrics file is actually read (got $val)" || bad "--repo-resolved metrics file is read (got $val)"

OUT="$(HEIMDALL_PLANNING_DIR="$FAKEREPO/.planning" python3 "$TOOL" "$SESSION" --json)"
val="$(get metrics_file)"
[ "$val" = "$FAKEREPO/.planning/metrics.jsonl" ] && ok "HEIMDALL_PLANNING_DIR overrides default metrics_file path (got $val)" || bad "HEIMDALL_PLANNING_DIR override (got $val)"

# ---------------------------------------------------------------------------
# Usage errors: no args at all -> non-zero exit, never a traceback. --help ->
# usage text, exit 0.
# ---------------------------------------------------------------------------
python3 "$TOOL" >"$TMPDIR/noargs.out" 2>&1
RC=$?
[ "$RC" -ne 0 ] && ok "no-args invocation exits non-zero (rc=$RC)" || bad "no-args invocation exits non-zero (rc=$RC)"
case "$(cat "$TMPDIR/noargs.out")" in
  *Traceback*) bad "no-args invocation must not print a Python traceback" ;;
  *) ok "no-args invocation prints no traceback" ;;
esac

HELP_OUT="$(python3 "$TOOL" --help)"
RC=$?
[ "$RC" -eq 0 ] && ok "--help exits 0" || bad "--help exits 0 (rc=$RC)"
case "$HELP_OUT" in
  *"Usage:"*) ok "--help prints usage text" ;;
  *) bad "--help prints usage text (got: $HELP_OUT)" ;;
esac

# ---------------------------------------------------------------------------
# Human-readable mode (no --json): must not crash, must surface the headline
# numbers a human needs, including the honest exact-matches caveat.
# ---------------------------------------------------------------------------
HUMAN_OUT="$(python3 "$TOOL" "$SESSION" --metrics-file "$METRICS")"
RC=$?
[ "$RC" -eq 0 ] && ok "human-readable mode exits 0" || bad "human-readable mode exits 0 (rc=$RC)"
case "$HUMAN_OUT" in
  *"plausibly completed (todos)"*"3"*) ok "human-readable mode prints plausibly-completed == 3" ;;
  *) bad "human-readable mode prints plausibly-completed (got: $HUMAN_OUT)" ;;
esac
case "$HUMAN_OUT" in
  *"measured gap"*"1"*) ok "human-readable mode prints the measured gap" ;;
  *) bad "human-readable mode prints the measured gap (got: $HUMAN_OUT)" ;;
esac
case "$HUMAN_OUT" in
  *"expected ~0"*) ok "human-readable mode carries the session-field caveat inline" ;;
  *) bad "human-readable mode carries the session-field caveat inline" ;;
esac

# ---------------------------------------------------------------------------
# Direct execution via shebang (not `python3 <path>`) -- this is how
# bin/heimdall's metric-audit subcommand actually invokes it (`exec`).
# ---------------------------------------------------------------------------
"$TOOL" --help >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "direct shebang execution works (rc=$RC)" || bad "direct shebang execution works (rc=$RC)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

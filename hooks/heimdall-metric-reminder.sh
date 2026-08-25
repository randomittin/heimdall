#!/usr/bin/env bash
# heimdall-metric-reminder — Stop-hook nudge for the one signal
# heimdall-self-improve/heimdall-dream cannot get any other way: a typed,
# outcome-bearing heimdall-metric record from the one place that actually
# knows both task_type and first-try pass/fail — the orchestrator itself.
#
# THE GAP THIS CLOSES. heimdall-self-improve/heimdall-dream implement a real
# bounded routing experiment (20-observation floor per (task_type, model),
# see bin/heimdall-dream's MIN_SAMPLES_FLOOR) but it has never fired for
# real — the ledger has sat at a handful of records from one burst, because
# being told to log outcomes in prose (agents/heimdall.md) has not been
# enough (measured: 130 hook-wired parallelism-tracker records vs 5
# prose-instructed heimdall-metric records over the same 83-day window — a
# 26x gap). Two other hooks already try to bridge this and structurally
# cannot:
#   - bin/heimdall-metric-hook (SubagentStop): fires on every subagent spawn,
#     but a subagent cannot know its own task_type in the caller's
#     vocabulary or whether the FIRST try passed, so it only ever emits a
#     mechanical --source subagentstop row with outcome=null (or, at most, a
#     verified --outcome fail from a SIGKILL marker — never pass).
#   - bin/heimdall-gate-run (git hook): emits a real pass/fail, but a bare
#     git hook cannot know task_type either, so it records null --source
#     gate-$PHASE, which heimdall-self-improve's own truthy-task_type filter
#     structurally excludes from aggregation.
# Only a hook that fires IN THE ORCHESTRATOR'S OWN CONTEXT can close this.
#
# WHY Stop, NOT SubagentStop. Verified directly against the pinned CLI
# binary (not assumed, not taken on a prior doc's word):
#   strings -a "$CLAUDE_CODE_EXECPATH" | grep 'delivered to the'
# run against both this session's own pinned 2.1.241 and the separately
# installed 2.1.243 — identical wording on both:
#   Stop:         "additionalContext is non-error feedback delivered to the
#                  model; the conversation continues so the model can act on it."
#   SubagentStop: "additionalContext is non-error feedback delivered to the
#                  subagent; the subagent continues so it can act on it."
# SubagentStop's context dies with the subagent it fired for and never
# reaches the orchestrator. Stop's reaches whichever conversation just ended
# a turn — for the orchestrator's own session, that IS the orchestrator.
# (Every agent-team member — orchestrator and every subagent — is its own
# session with its own session_id and its own Stop lifecycle; this hook
# fires in all of them, and the per-session-id marker below is what keeps
# that harmless rather than turning into N nags for one logical task.)
#
# WHAT COUNTS AS "ALREADY LOGGED THIS SESSION". source=="orchestrator" AND a
# real (non-empty) task_type AND outcome in {pass,fail} — the exact
# convention agents/heimdall.md:319 already documents (`--source
# orchestrator`), not invented here. A mechanical subagentstop row can have
# a real task_type but never source=orchestrator; a gate-* row can have a
# real outcome but never a real task_type AND never source=orchestrator
# either — so neither can satisfy this filter, on purpose. This is
# intentionally STRICTER than bin/heimdall-self-improve's own
# _task_records() filter (truthy task_type + model, no source/outcome
# check) — that one powers broad usage stats; this one gates a user-facing
# nudge and must not go quiet just because SOME row happens to exist.
#
# ONE NUDGE PER SESSION, NEVER PER TURN. Stop fires every time a session
# ends a turn — for a long session that's many times. Silence is required
# unless there's something to say, and even then, say it once: after the
# first reminder for a given session_id, stay silent for the rest of that
# session's life, regardless of whether a qualifying record later shows up.
# Marker: $REPO/.heimdall/stop-hook/reminded-<session_id> — repo-local
# runtime state, already covered by the blanket `.heimdall/*` gitignore
# entry, same directory bin/heimdall-gate-run already uses for its own
# verdict.json/gate-metric-state.json bookkeeping.
#
# NEVER FABRICATE. This hook never invents or defaults a task_type or
# outcome on anyone's behalf, and never will — it only counts whether a REAL
# one was already recorded. The reminder text itself says not to guess.
#
# FAIL OPEN, ALWAYS, ON PURPOSE. Every guard below falls through to a silent
# `exit 0` the moment it cannot PROVE a reminder is warranted: no
# session_id, no jq, no heimdall-metric binary, an unreadable ledger, a
# malformed payload. An unreadable ledger in particular must NOT read as
# "zero records" — that would fabricate a negative from a state that is
# actually just unknown, exactly the kind of guess this hook exists to
# refuse. Only a ledger that is provably ABSENT counts as a certain zero.
set -uo pipefail

SELF="$0"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
fi
HOOKS_DIR="$(cd "$(dirname "$SELF")" && pwd)"
PLUGIN_DIR="$(cd "$HOOKS_DIR/.." && pwd)"
METRIC_BIN="$PLUGIN_DIR/bin/heimdall-metric"

REPO="${CLAUDE_PROJECT_DIR:-.}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-$REPO}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -d "$REPO" ] || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$session_id" ] || exit 0

# Filename-safe projection of session_id. Defensive rather than because
# session_id is expected to be hostile: a marker path is built from it and
# must never land outside the marker directory.
safe_session="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_-' '_')"
[ -n "$safe_session" ] || exit 0

marker_dir="$REPO/.heimdall/stop-hook"
marker="$marker_dir/reminded-$safe_session"
[ -e "$marker" ] && exit 0   # already nudged this session — stay silent, forever, for this session

[ -x "$METRIC_BIN" ] || exit 0

planning_dir="${HEIMDALL_PLANNING_DIR:-$REPO/.planning}"
metrics_file="$planning_dir/metrics.jsonl"

# Bound the work regardless of how large the ledger has grown over the
# project's life — mirrors bin/heimdall-metric-hook's own
# HMD_METRIC_HOOK_TRANSCRIPT_TAIL_BYTES bounded-tail-read convention.
# Override exists for tests only.
tail_bytes="${HMD_METRIC_REMINDER_TAIL_BYTES:-262144}"

if [ -f "$metrics_file" ]; then
  # Unreadable is NOT the same fact as absent: absent means zero records for
  # certain; unreadable means unknown. Only the former may proceed silently
  # toward "no qualifying record found" — the latter must stop here, exit 0,
  # and never guess which way an unreadable file would have gone.
  [ -r "$metrics_file" ] || exit 0
  qualifies=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if printf '%s' "$line" | jq -e '
          (.metric? == "task")
      and (.source? == "orchestrator")
      and ((.task_type? // "") != "")
      and (.outcome? == "pass" or .outcome? == "fail")
        ' >/dev/null 2>&1
    then
      qualifies=1
      break
    fi
  done < <(tail -c "$tail_bytes" "$metrics_file" 2>/dev/null)
  [ "$qualifies" = 1 ] && exit 0
fi
# else: no ledger file at all -> zero records is a certain fact, not a
# guess -> fall through to the reminder below.

mkdir -p "$marker_dir" 2>/dev/null && : > "$marker" 2>/dev/null || true

jq -n '{
  hookSpecificOutput: {
    hookEventName: "Stop",
    additionalContext: (
      "heimdall: no orchestrator-sourced heimdall-metric record found this session. " +
      "If a task just finished, log its real outcome now (never guess --type or " +
      "--outcome — a missing record beats a fabricated one): " +
      "heimdall-metric task --type <type> --model <haiku|sonnet|opus> " +
      "--outcome pass|fail --source orchestrator   (full flag reference: agents/heimdall.md)"
    )
  }
}' 2>/dev/null || true

exit 0

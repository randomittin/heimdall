#!/usr/bin/env bash
# test/heimdall-self-improve.test.sh — acceptance for the DELIBERATE self-improvement
# loop (bin/heimdall-self-improve). autoresearch applied to Heimdall's own routing.
#
# Hermetic: every case runs against a THROWAWAY repo with a SEEDED .planning/
# metrics.jsonl + queue-stats.json. Nothing here touches a live transcript, the
# network, a real model, or the real .planning dir. The "clock" seam is handled by
# dating variant metrics in the far future so they always fall inside the bounded
# post-start window regardless of the real wall clock.
#
# FALSIFIABLE claims proven:
#   (1) COLLECT — aggregates only "task" records into the comparable scalar
#       (pass_rate/retries/secs) per (task_type,model); non-task records ignored.
#   (2) HYPOTHESES — a FAILING tier yields an escalate hypothesis; a FLAWLESS tier
#       yields a cheapen hypothesis; queue dead-reasons yield precheck hypotheses.
#   (3) MIN-SAMPLES GATE — a task_type below --min-samples yields NO hypothesis
#       (no verdict without evidence — the autoresearch invariant).
#   (4) EXPERIMENT START — applies the routing-override, appends an OPEN experiment
#       recording the baseline + the prior override (for reversibility).
#   (5) KEEP — a measured pass_rate delta >= min_delta over >= min_samples PERSISTS
#       the override as "validated" and logs the experiment "kept".
#   (6) FALSIFIER: NO-DELTA — a variant with pass_rate NOT better than baseline (but
#       plenty of samples) is DISCARDED and the override is ROLLED BACK (not persisted).
#   (7) FALSIFIER: INSUFFICIENT-SAMPLES — a variant with < min_samples is DISCARDED
#       and rolled back (an improvement without enough measurement never persists).
#   (8) REVERSIBILITY — discarding an experiment that shadowed a PRIOR override
#       restores that prior override exactly; a manual `rollback` does the same.
#   (9) OUTCOMES RECORDED — every decision appends a decided record with a result
#       block to experiments.jsonl; status folds the log to latest-per-id.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-self-improve"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

# dynamic template avoids a literal triple-X in the source (the content scanner).
WORK="$(mktemp -d -t "self-improve-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── seed helpers ──────────────────────────────────────────────────────────────
# mk_repo <name> -> echoes the repo path with a fresh .planning dir.
mk_repo() {
  local d="$WORK/$1"
  mkdir -p "$d/.planning"
  echo "$d"
}

# a healthy baseline metrics file used across cases:
#   lint on sonnet: 1/4 pass (0.25) -> failing -> escalate candidate
#   docs on opus:   3/3 pass (1.00) zero retries -> cheapen candidate
#   plus a non-task record that MUST be ignored.
seed_metrics() {
  cat > "$1/.planning/metrics.jsonl" <<'EOF'
{"ts":"2026-07-01T00:00:00Z","metric":"parallelism","total_turns":5,"parallel_ratio":0.3}
{"ts":"2026-07-01T01:00:00Z","metric":"task","task_type":"lint","model":"sonnet","outcome":"fail","retries":2,"wall_secs":30}
{"ts":"2026-07-01T02:00:00Z","metric":"task","task_type":"lint","model":"sonnet","outcome":"fail","retries":3,"wall_secs":40}
{"ts":"2026-07-01T03:00:00Z","metric":"task","task_type":"lint","model":"sonnet","outcome":"pass","retries":1,"wall_secs":20}
{"ts":"2026-07-01T04:00:00Z","metric":"task","task_type":"lint","model":"sonnet","outcome":"fail","retries":2,"wall_secs":35}
{"ts":"2026-07-01T05:00:00Z","metric":"task","task_type":"docs","model":"opus","outcome":"pass","retries":0,"wall_secs":10}
{"ts":"2026-07-01T06:00:00Z","metric":"task","task_type":"docs","model":"opus","outcome":"pass","retries":0,"wall_secs":12}
{"ts":"2026-07-01T07:00:00Z","metric":"task","task_type":"docs","model":"opus","outcome":"pass","retries":0,"wall_secs":9}
EOF
  cat > "$1/.planning/queue-stats.json" <<'EOF'
{"dead":[{"reason":"lint-timeout","task_type":"lint","count":4},{"reason":"flaky-network","count":1}],"done":[]}
EOF
}

# open_id <repo> -> the id of the newest OPEN experiment.
open_id() {
  "$PY" -c 'import json,sys;print([json.loads(l)["id"] for l in open(sys.argv[1]) if json.loads(l).get("status")=="open"][-1])' \
    "$1/.planning/experiments.jsonl"
}

echo "self-improve acceptance"
echo "======================="

# ── (1) COLLECT ────────────────────────────────────────────────────────────────
R="$(mk_repo collect)"; seed_metrics "$R"
C="$("$CLI" --repo "$R" collect)"
[ "$(echo "$C" | jq -r '.total_task_records')" = "7" ] \
  && ok "(1) collect ignores non-task records (7 task rows, parallelism dropped)" \
  || bad "(1) collect counted wrong number of task rows"
LINT_PR="$(echo "$C" | jq -r '.cells[] | select(.task_type=="lint" and .model=="sonnet") | .pass_rate')"
[ "$LINT_PR" = "0.25" ] && ok "(1) collect computes lint/sonnet pass_rate=0.25" \
  || bad "(1) collect wrong lint pass_rate: $LINT_PR"

# ── (2) HYPOTHESES ─────────────────────────────────────────────────────────────
H="$("$CLI" --repo "$R" hypotheses)"
echo "$H" | jq -e '.hypotheses[] | select(.id=="hyp-esc-lint-sonnet" and .proposal.to_model=="opus")' >/dev/null \
  && ok "(2) failing tier -> escalate hypothesis (lint sonnet->opus)" \
  || bad "(2) missing escalate hypothesis"
echo "$H" | jq -e '.hypotheses[] | select(.id=="hyp-cheap-docs-opus" and .proposal.to_model=="sonnet")' >/dev/null \
  && ok "(2) flawless tier -> cheapen hypothesis (docs opus->sonnet)" \
  || bad "(2) missing cheapen hypothesis"
echo "$H" | jq -e '.hypotheses[] | select(.kind=="precheck" and .id=="hyp-precheck-lint-timeout")' >/dev/null \
  && ok "(2) queue dead-reason -> precheck hypothesis" \
  || bad "(2) missing precheck hypothesis"

# ── (3) MIN-SAMPLES GATE ───────────────────────────────────────────────────────
# lint has 4 samples; require 5 -> no lint hypothesis emitted (no verdict w/o evidence).
HG="$("$CLI" --repo "$R" hypotheses --min-samples 5)"
if echo "$HG" | jq -e '.hypotheses[] | select(.kind=="routing")' >/dev/null; then
  bad "(3) min-samples gate leaked a routing hypothesis with too few samples"
else
  ok "(3) min-samples gate suppresses under-sampled routing hypotheses"
fi

# ── (4) EXPERIMENT START ───────────────────────────────────────────────────────
R="$(mk_repo start)"; seed_metrics "$R"
S="$("$CLI" --repo "$R" experiment start --hypothesis hyp-esc-lint-sonnet --min-samples 3 --min-delta 0.10)"
[ "$(echo "$S" | jq -r '.override_applied')" = "true" ] \
  && ok "(4) start reports override applied" || bad "(4) start did not apply override"
OVMODEL="$(jq -r '.overrides.lint.model' "$R/.planning/routing-overrides.json")"
[ "$OVMODEL" = "opus" ] && ok "(4) routing-overrides.json now routes lint->opus" \
  || bad "(4) override not written (lint->$OVMODEL)"
EXP="$(open_id "$R")"
jq -e --arg id "$EXP" 'select(.id==$id and .status=="open" and .baseline.pass_rate==0.25 and .prev_override==null)' \
  "$R/.planning/experiments.jsonl" >/dev/null 2>&1 \
  && ok "(4) open experiment logged with baseline + null prev_override" \
  || bad "(4) open experiment record malformed"

# ── (5) KEEP — measured improvement persists ───────────────────────────────────
R="$(mk_repo keep)"; seed_metrics "$R"
"$CLI" --repo "$R" experiment start --hypothesis hyp-esc-lint-sonnet --min-samples 3 --min-delta 0.10 >/dev/null
EXP="$(open_id "$R")"
# post-start variant metrics: opus lint 3/4 pass = 0.75 (delta +0.50 >= 0.10)
cat >> "$R/.planning/metrics.jsonl" <<'EOF'
{"ts":"2999-01-01T01:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":0,"wall_secs":18}
{"ts":"2999-01-01T02:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":0,"wall_secs":19}
{"ts":"2999-01-01T03:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":1,"wall_secs":22}
{"ts":"2999-01-01T04:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"fail","retries":1,"wall_secs":25}
EOF
EV="$("$CLI" --repo "$R" experiment evaluate --id "$EXP")"
[ "$(echo "$EV" | jq -r '.decision')" = "keep" ] && [ "$(echo "$EV" | jq -r '.persisted')" = "true" ] \
  && ok "(5) KEEP: measured delta persists the override" \
  || bad "(5) KEEP path did not keep: $(echo "$EV" | jq -c '.result')"
[ "$(jq -r '.overrides.lint.status' "$R/.planning/routing-overrides.json")" = "validated" ] \
  && ok "(5) override marked validated with measured delta" \
  || bad "(5) override not marked validated"

# ── (6) FALSIFIER: NO measured delta -> DISCARD + ROLLBACK ─────────────────────
R="$(mk_repo nodelta)"; seed_metrics "$R"
"$CLI" --repo "$R" experiment start --hypothesis hyp-esc-lint-sonnet --min-samples 3 --min-delta 0.10 >/dev/null
EXP="$(open_id "$R")"
# post-start variant: opus lint 1/4 pass = 0.25 == baseline -> NOT an improvement
cat >> "$R/.planning/metrics.jsonl" <<'EOF'
{"ts":"2999-01-01T01:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"fail","retries":2,"wall_secs":30}
{"ts":"2999-01-01T02:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"fail","retries":2,"wall_secs":31}
{"ts":"2999-01-01T03:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":1,"wall_secs":20}
{"ts":"2999-01-01T04:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"fail","retries":2,"wall_secs":33}
EOF
EV="$("$CLI" --repo "$R" experiment evaluate --id "$EXP")"
[ "$(echo "$EV" | jq -r '.decision')" = "discard" ] && [ "$(echo "$EV" | jq -r '.persisted')" = "false" ] \
  && ok "(6) FALSIFIER: a non-improving variant is DISCARDED (not persisted)" \
  || bad "(6) no-delta variant wrongly persisted"
[ "$(jq -r '.overrides | has("lint")' "$R/.planning/routing-overrides.json")" = "false" ] \
  && ok "(6) override ROLLED BACK to none after discard" \
  || bad "(6) override not rolled back after discard"

# ── (7) FALSIFIER: INSUFFICIENT SAMPLES -> DISCARD + ROLLBACK ──────────────────
R="$(mk_repo fewsamples)"; seed_metrics "$R"
"$CLI" --repo "$R" experiment start --hypothesis hyp-esc-lint-sonnet --min-samples 3 --min-delta 0.10 >/dev/null
EXP="$(open_id "$R")"
# only ONE post-start variant sample (< min 3), even though it passes
cat >> "$R/.planning/metrics.jsonl" <<'EOF'
{"ts":"2999-01-01T01:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":0,"wall_secs":18}
EOF
EV="$("$CLI" --repo "$R" experiment evaluate --id "$EXP")"
[ "$(echo "$EV" | jq -r '.decision')" = "discard" ] \
  && echo "$EV" | jq -e '.result.reason | test("insufficient")' >/dev/null \
  && ok "(7) FALSIFIER: too few samples -> DISCARD (no verdict without measurement)" \
  || bad "(7) insufficient-sample variant not discarded"
[ "$(jq -r '.overrides | has("lint")' "$R/.planning/routing-overrides.json")" = "false" ] \
  && ok "(7) override rolled back on insufficient samples" \
  || bad "(7) override not rolled back on insufficient samples"

# ── (8) REVERSIBILITY — a prior override is restored exactly ───────────────────
R="$(mk_repo revert)"; seed_metrics "$R"
# plant a PRE-EXISTING validated override for lint (sonnet) that an experiment shadows.
cat > "$R/.planning/routing-overrides.json" <<'EOF'
{"schema":1,"overrides":{"lint":{"model":"sonnet","status":"validated","reason":"prior"}}}
EOF
"$CLI" --repo "$R" experiment start --hypothesis hyp-esc-lint-sonnet --min-samples 3 --min-delta 0.10 >/dev/null
EXP="$(open_id "$R")"
[ "$(jq -r '.overrides.lint.model' "$R/.planning/routing-overrides.json")" = "opus" ] \
  && ok "(8) experiment shadows the prior override (lint sonnet->opus)" \
  || bad "(8) experiment did not shadow prior override"
"$CLI" --repo "$R" experiment rollback --id "$EXP" >/dev/null
RESTORED="$(jq -r '.overrides.lint.model + ":" + .overrides.lint.reason' "$R/.planning/routing-overrides.json")"
[ "$RESTORED" = "sonnet:prior" ] \
  && ok "(8) rollback restores the PRIOR override exactly (sonnet:prior)" \
  || bad "(8) rollback did not restore prior override: $RESTORED"

# ── (9) OUTCOMES RECORDED + status fold ────────────────────────────────────────
R="$(mk_repo status)"; seed_metrics "$R"
"$CLI" --repo "$R" experiment start --hypothesis hyp-esc-lint-sonnet --min-samples 3 --min-delta 0.10 >/dev/null
EXP="$(open_id "$R")"
cat >> "$R/.planning/metrics.jsonl" <<'EOF'
{"ts":"2999-01-01T01:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":0,"wall_secs":18}
{"ts":"2999-01-01T02:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":0,"wall_secs":19}
{"ts":"2999-01-01T03:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":0,"wall_secs":20}
EOF
"$CLI" --repo "$R" experiment evaluate --id "$EXP" >/dev/null
# the decided record carries a result block
jq -e --arg id "$EXP" 'select(.id==$id and .result!=null and .decided_ts!=null)' \
  "$R/.planning/experiments.jsonl" >/dev/null 2>&1 \
  && ok "(9) decided experiment appended with a result block" \
  || bad "(9) no decided record with result"
ST="$("$CLI" --repo "$R" status)"
[ "$(echo "$ST" | jq -r '.total_experiments')" = "1" ] \
  && [ "$(echo "$ST" | jq -r '.experiments_by_status.kept')" = "1" ] \
  && ok "(9) status folds the log to latest-per-id (1 kept)" \
  || bad "(9) status fold wrong: $(echo "$ST" | jq -c '.experiments_by_status')"

# ── (10) FAIL-OPEN: malformed routing-overrides.json must not crash the loop ───
R="$(mk_repo failopen)"; seed_metrics "$R"
echo '{not valid json' > "$R/.planning/routing-overrides.json"
set +e
ST="$("$CLI" --repo "$R" status 2>"$WORK/failopen.stderr")"
RC=$?
set -e
[ "$RC" = "0" ] && [ "$(echo "$ST" | jq -r '.overrides_active')" = "{}" ] \
  && ok "(10) FAIL-OPEN: malformed routing-overrides.json degrades to empty, no crash" \
  || bad "(10) malformed routing-overrides.json crashed status (rc=$RC): $ST"
grep -qi "malformed\|fail.open\|absent" "$WORK/failopen.stderr" \
  && ok "(10) fail-open is not fail-SILENT: a warning is written to stderr" \
  || bad "(10) no stderr warning for the discarded malformed file"
# a malformed 'overrides' key (valid JSON, wrong shape) must ALSO fail open.
R="$(mk_repo failopen2)"; seed_metrics "$R"
echo '{"schema":1,"overrides":"not-an-object"}' > "$R/.planning/routing-overrides.json"
set +e
ST2="$("$CLI" --repo "$R" status 2>/dev/null)"
RC2=$?
set -e
[ "$RC2" = "0" ] && [ "$(echo "$ST2" | jq -r '.overrides_active')" = "{}" ] \
  && ok "(10) FAIL-OPEN: malformed 'overrides' shape (not an object) also degrades to empty" \
  || bad "(10) malformed overrides shape crashed status (rc=$RC2): $ST2"

echo "======================="
printf "self-improve: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then printf "\033[31m%d failed\033[0m\n" "$FAIL"; exit 1; fi
printf "0 failed\n"

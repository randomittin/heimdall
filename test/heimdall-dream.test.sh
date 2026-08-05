#!/usr/bin/env bash
# test/heimdall-dream.test.sh — acceptance for the OVERNIGHT /dream loop
# (bin/heimdall-dream): autoresearch self-improve + a maintainer sweep -> a dated
# MORNING REPORT with three sections, honest when there is no evidence, and NEVER
# pushing.
#
# Hermetic: every case runs against a THROWAWAY repo with a SEEDED .planning/
# metrics.jsonl + queue-stats.json. Nothing touches a live transcript, the network,
# a real model, or the real .planning dir. `dream` shells out to the REAL sibling
# bin/heimdall-self-improve — so the keep-gate under test is the production one, not
# a copy. Variant metrics are dated in the far future so they fall inside the bounded
# post-start window regardless of the wall clock.
#
# FALSIFIABLE claims proven:
#   (1) WITH EVIDENCE — a dated report file is written at .planning/dream/<date>.md
#       carrying the THREE sections (suggested changes / issues+fixes / improvements).
#   (2) SUGGESTED CHANGES are REAL — the report cites the actual escalate hypothesis
#       (hyp-esc-lint-sonnet) sourced from the real self-improve hypotheses output.
#   (3) ISSUES+FIXES are REAL — a recurring dead-reason cluster (lint-timeout) is
#       raised as an issue WITH a proposed fix (sourced from the real precheck hypo).
#   (4) IMPROVEMENTS KEPT reuse the KEEP-GATE — an OPEN experiment whose variant beats
#       baseline is EVALUATED by dream, KEPT (validated), and reported as measured
#       (delta >= min_delta over >= min_samples) — dream adds no keep logic of its own.
#   (5) FALSIFIER: NO FABRICATION — with NO evidence (empty metrics) the report says
#       "Nothing to suggest" and contains NONE of the hypothesis ids.
#   (6) AGENT-NEVER-PUSHES — the summary reports pushed:false and the bin source runs
#       no `git push` / `gh pr` / merge; the report states no changes were pushed.
#   (7) SHADOW-FIRST — a routing suggestion is SURFACED, NOT auto-applied: with no
#       --start-experiment, routing-overrides.json is NOT created by the run.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-dream"
SI="$ROOT/bin/heimdall-self-improve"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }
[ -x "$SI" ]  || { echo "FATAL: $SI not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "dream-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

mk_repo() { local d="$WORK/$1"; mkdir -p "$d/.planning"; echo "$d"; }

# The same RATIOS the self-improve suite uses, at a sample count that clears the
# SAMPLE-SIZE FLOOR in bin/heimdall-dream (MIN_SAMPLES_FLOOR): dream refuses a
# routing verdict below 20 observations per (task_type, model), because at a
# handful of samples a pass-rate is noise — a variant that is truly no better
# clears a 0.10 delta ~73% of the time at n=3. Only the COUNT is raised here; every
# rate below is identical to the original seed, so the measured deltas are too.
#   lint/sonnet  5/20 pass (0.25) -> failing -> escalate suggestion
#   docs/opus   20/20 pass (1.00) zero retries -> cheapen suggestion
#   queue dead lint-timeout x4 -> a precheck issue with a proposed fix
seed_metrics() {
  {
    printf '%s\n' '{"ts":"2026-07-01T00:00:00Z","metric":"parallelism","total_turns":5,"parallel_ratio":0.3}'
    i=0
    while [ "$i" -lt 20 ]; do
      if [ "$i" -lt 5 ]; then o=pass; else o=fail; fi
      printf '{"ts":"2026-07-01T01:%02d:00Z","metric":"task","task_type":"lint","model":"sonnet","outcome":"%s","retries":2,"wall_secs":30}\n' "$i" "$o"
      printf '{"ts":"2026-07-01T02:%02d:00Z","metric":"task","task_type":"docs","model":"opus","outcome":"pass","retries":0,"wall_secs":10}\n' "$i"
      i=$((i+1))
    done
  } > "$1/.planning/metrics.jsonl"
  cat > "$1/.planning/queue-stats.json" <<'EOF'
{"dead":[{"reason":"lint-timeout","task_type":"lint","count":4}],"done":[]}
EOF
}

echo "dream acceptance"
echo "================"

# ── (1)(2)(3)(4)(6)(7) WITH EVIDENCE ────────────────────────────────────────────
R="$(mk_repo evid)"; seed_metrics "$R"
DATE="2026-07-11"
# plant an OPEN experiment for lint whose post-start variant BEATS baseline, so the
# keep-gate will KEEP it when dream evaluates.
"$SI" --repo "$R" experiment start --hypothesis hyp-esc-lint-sonnet --min-samples 3 --min-delta 0.10 >/dev/null
cat >> "$R/.planning/metrics.jsonl" <<'EOF'
{"ts":"2999-01-01T01:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":0,"wall_secs":18}
{"ts":"2999-01-01T02:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":0,"wall_secs":19}
{"ts":"2999-01-01T03:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"pass","retries":1,"wall_secs":22}
{"ts":"2999-01-01T04:00:00Z","metric":"task","task_type":"lint","model":"opus","outcome":"fail","retries":1,"wall_secs":25}
EOF

SUM="$("$CLI" --repo "$R" run --date "$DATE" --json)"
REP="$R/.planning/dream/$DATE.md"

[ -f "$REP" ] && ok "(1) dated report written at .planning/dream/$DATE.md" \
  || bad "(1) report file not written"

grep -q "## 1. Suggested changes" "$REP" \
  && grep -q "## 2. Issues raised & proposed fixes" "$REP" \
  && grep -q "## 3. Improvements kept" "$REP" \
  && ok "(1) report carries all three sections" \
  || bad "(1) report missing one of the three sections"

grep -q "hyp-esc-lint-sonnet" "$REP" \
  && grep -qi "sonnet" "$REP" \
  && ok "(2) suggested change cites the REAL escalate hypothesis (lint sonnet->opus)" \
  || bad "(2) escalate hypothesis not surfaced in the report"

grep -q "hyp-precheck-lint-timeout" "$REP" \
  && grep -qi "proposed fix" "$REP" \
  && ok "(3) dead-reason cluster raised as an issue WITH a proposed fix" \
  || bad "(3) precheck issue+fix not surfaced"

# (4) the KEEP came from the real keep-gate — kept in summary AND measured in report.
[ "$(echo "$SUM" | jq -r '.counts.improvements_kept')" = "1" ] \
  && ok "(4) exactly one improvement KEPT via the reused keep-gate" \
  || bad "(4) keep-gate did not keep the winning experiment: $(echo "$SUM" | jq -c '.counts')"
grep -q "KEPT" "$REP" && grep -Eq "delta \*\*\+0\.(5|50)" "$REP" \
  && ok "(4) kept improvement is measured better-than-baseline (delta +0.50 reported)" \
  || bad "(4) kept improvement not reported with a measured delta"
# and the override is now validated on disk (the gate persisted it, dream did not)
[ "$(jq -r '.overrides.lint.status' "$R/.planning/routing-overrides.json")" = "validated" ] \
  && ok "(4) winning override persisted as validated by the self-improve gate" \
  || bad "(4) override not validated on disk"

# (6) agent-never-pushes
[ "$(echo "$SUM" | jq -r '.pushed')" = "false" ] \
  && ok "(6) summary reports pushed:false" || bad "(6) summary claims a push"
grep -q "never pushes or merges" "$REP" \
  && ok "(6) report states no changes were pushed" || bad "(6) report missing no-push statement"
# behavioral falsifier: shim git+gh on PATH; if dream shells out to either, a
# sentinel file appears. Stronger than a source grep (comments mention the invariant).
SHIM="$WORK/shim"; mkdir -p "$SHIM"
for tool in git gh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/PUSHED"\nexit 0\n' "$tool" "$WORK" > "$SHIM/$tool"
  chmod +x "$SHIM/$tool"
done
RG="$(mk_repo nopush)"; seed_metrics "$RG"
PATH="$SHIM:$PATH" "$CLI" --repo "$RG" run --date "$DATE" --start-experiment >/dev/null
if [ -f "$WORK/PUSHED" ]; then
  bad "(6) dream invoked git/gh: $(cat "$WORK/PUSHED")"
else
  ok "(6) dream never invokes git or gh (no push/PR/merge, even with --start-experiment)"
fi

# (7) shadow-first: a run WITHOUT --start-experiment must NOT create a new override.
R2="$(mk_repo shadow)"; seed_metrics "$R2"
"$CLI" --repo "$R2" run --date "$DATE" >/dev/null
if [ -f "$R2/.planning/routing-overrides.json" ]; then
  bad "(7) shadow-first violated: a routing override was auto-applied without --start-experiment"
else
  ok "(7) shadow-first: routing suggestions surfaced, no override auto-applied"
fi
# but the report still SURFACED the suggestion for review
grep -q "hyp-esc-lint-sonnet" "$R2/.planning/dream/$DATE.md" \
  && ok "(7) suggestion surfaced in the report for human review" \
  || bad "(7) suggestion not surfaced"

# ── (5) FALSIFIER: NO EVIDENCE -> honest, no fabrication ─────────────────────────
R3="$(mk_repo empty)"   # .planning exists, but NO metrics/queue files
SUM3="$("$CLI" --repo "$R3" run --date "$DATE" --json)"
REP3="$R3/.planning/dream/$DATE.md"
[ "$(echo "$SUM3" | jq -r '.honest_empty')" = "true" ] \
  && ok "(5) no-evidence run marked honest_empty" || bad "(5) empty run not flagged honest"
grep -qi "Nothing to suggest" "$REP3" \
  && ok "(5) empty report says 'Nothing to suggest' honestly" \
  || bad "(5) empty report missing the honest statement"
if grep -q "hyp-" "$REP3"; then
  bad "(5) FABRICATION: empty report invented a hypothesis id"
else
  ok "(5) FALSIFIER: empty report fabricates NO hypotheses"
fi
[ "$(echo "$SUM3" | jq -r '.counts.improvements_kept')" = "0" ] \
  && ok "(5) empty run keeps nothing" || bad "(5) empty run wrongly kept something"

echo "================"
printf "dream: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then printf "\033[31m%d failed\033[0m\n" "$FAIL"; exit 1; fi
printf "0 failed\n"

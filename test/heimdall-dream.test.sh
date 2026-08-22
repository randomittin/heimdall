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

# HERMETIC: dream keeps its state under $HEIMDALL_HOME (bin/lib/dream_data.py), because
# the nightly LaunchAgent cannot read a repo inside a TCC-protected folder. Left
# unredirected, every case below would write its throwaway corpus into the OPERATOR'S
# real ~/.heimdall/data — which is exactly how this suite once overwrote his live
# LaunchAgent plist. The state dir is a seam precisely so a test can own it; point it at
# the throwaway tree, which the trap above already reclaims.
export HEIMDALL_HOME="$WORK/heimdall-home"
mkdir -p "$HEIMDALL_HOME"

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
# and the override is now validated on disk (the gate persisted it, dream did not).
# The overrides file lives in dream's RELOCATED state dir, not <repo>/.planning: the
# nightly job cannot read a TCC-protected repo, so the self-improve loop it drives keeps
# its four state files under $HEIMDALL_HOME. Ask the module where that is rather than
# rebuilding the hashed path here, so this assertion cannot drift from the derivation.
STATE="$("$PY" "$ROOT/bin/lib/dream_data.py" planning --repo "$R")"
[ "$(jq -r '.overrides.lint.status' "$STATE/routing-overrides.json")" = "validated" ] \
  && ok "(4) winning override persisted as validated by the self-improve gate" \
  || bad "(4) override not validated on disk ($STATE/routing-overrides.json)"

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

# ── (8) POLICY-GUARD INTEROP: auto-start SKIPS a policy-blocked candidate and
#     starts the next testable one instead — proves dream's existing
#     testable-only picker (`h.get("testable")` in cmd_run) needs NO changes to
#     honor heimdall-self-improve's policy guard; self-improve's cmd_hypotheses
#     already marks a blocked candidate testable:false, and the picker already
#     skips non-testable candidates.
#     Fixture: review/opus flawless 20/20 (adjudication task_type -> a cheapen
#     candidate is POLICY-BLOCKED off opus, and "review" sorts alphabetically
#     BEFORE "test") + test/sonnet failing 5/20 (an ordinary, ALLOWED escalate
#     candidate). If skip-and-continue were broken, auto-start would either
#     silently start nothing this cycle or wrongly start the blocked one.
R8="$(mk_repo policyskip)"
{
  i=0
  while [ "$i" -lt 20 ]; do
    if [ "$i" -lt 5 ]; then o=pass; else o=fail; fi
    printf '{"ts":"2026-07-01T01:%02d:00Z","metric":"task","task_type":"test","model":"sonnet","outcome":"%s","retries":2,"wall_secs":30}\n' "$i" "$o"
    printf '{"ts":"2026-07-01T02:%02d:00Z","metric":"task","task_type":"review","model":"opus","outcome":"pass","retries":0,"wall_secs":10}\n' "$i"
    i=$((i+1))
  done
} > "$R8/.planning/metrics.jsonl"
echo '{"dead":[],"done":[]}' > "$R8/.planning/queue-stats.json"
"$CLI" --repo "$R8" run --date "$DATE" --start-experiment --json >/dev/null
STATE8="$("$PY" "$ROOT/bin/lib/dream_data.py" planning --repo "$R8")"
[ "$(jq -r '.overrides.test.model' "$STATE8/routing-overrides.json" 2>/dev/null)" = "opus" ] \
  && ok "(8) auto-start SKIPPED the policy-blocked review candidate and started test->opus" \
  || bad "(8) auto-start did not skip-and-continue correctly: $(cat "$STATE8/routing-overrides.json" 2>/dev/null || echo MISSING)"
[ "$(jq -r '.overrides | has("review")' "$STATE8/routing-overrides.json" 2>/dev/null)" = "false" ] \
  && ok "(8) policy-blocked review candidate was never started" \
  || bad "(8) review candidate was wrongly auto-started despite the policy block"
# and the report still surfaces the blocked candidate for a human (not silently dropped).
REP8="$R8/.planning/dream/$DATE.md"
grep -q "hyp-cheap-review-opus" "$REP8" \
  && ok "(8) policy-blocked candidate still surfaced in the report for human review" \
  || bad "(8) policy-blocked candidate silently dropped from the report"

# ── (9) MIN-DELTA FLOOR: --min-delta below the floor is CLAMPED UP, never honored ──
# mirrors the existing --min-samples floor clamp; an unclamped --min-delta 0.01 would
# silently reopen the false-keep risk this file's docstring spends ~30 lines quantifying.
R9="$(mk_repo mindeltafloor)"; seed_metrics "$R9"
SUM9="$("$CLI" --repo "$R9" run --date "$DATE" --min-delta 0.01 --json)"
[ "$(echo "$SUM9" | jq -r '.min_delta')" = "0.15" ] \
  && ok "(9) --min-delta below the floor is clamped up to 0.15, not honored at 0.01" \
  || bad "(9) min-delta floor not enforced: $(echo "$SUM9" | jq -r '.min_delta')"
[ "$(echo "$SUM9" | jq -r '.min_delta_floor_enforced')" = "true" ] \
  && ok "(9) summary flags min_delta_floor_enforced:true" \
  || bad "(9) summary did not flag the min-delta clamp"
REP9="$R9/.planning/dream/$DATE.md"
grep -qi "min-delta.*clamp\|clamp.*min-delta" "$REP9" \
  && ok "(9) report explains the min-delta clamp to a human" \
  || bad "(9) report silent about the min-delta clamp"
# a caller asking for a STRICTER floor (above 0.15) must still be honored (raise-only).
SUM9B="$("$CLI" --repo "$R9" run --date "$DATE" --min-delta 0.30 --json)"
[ "$(echo "$SUM9B" | jq -r '.min_delta')" = "0.3" ] \
  && ok "(9) a stricter --min-delta (above the floor) is honored, not overridden" \
  || bad "(9) stricter min-delta was not honored: $(echo "$SUM9B" | jq -r '.min_delta')"

echo "================"
printf "dream: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then printf "\033[31m%d failed\033[0m\n" "$FAIL"; exit 1; fi
printf "0 failed\n"

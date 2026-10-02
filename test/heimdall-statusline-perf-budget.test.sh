#!/usr/bin/env bash
#
# heimdall-statusline-perf-budget.test.sh — dedicated perf regression gate for
# bin/heimdall-statusline's render time.
#
# WHY THIS EXISTS: a prior defect measured cold renders at 2.35-4.09s against
# Cursor CLI's statusLine timeoutMs (2000ms at the time; the registration default is
# now 3000ms — see bin/heimdall-statusline-register-cursor), which silently killed the
# in-flight process and produced NO status line at all. This suite is the regression
# net: nothing else in test/ asserts a render-time ceiling as a hard, dedicated gate.
# It stays a pure three-assertion TIMING suite (heimdall-statusline-agents-cache.test.sh
# proves the cache mechanism; this proves the clock).
#
# WHY IT WAS RED UNDER LOAD, AND WHAT FIXED IT (measured, not guessed). It failed at
# load 34 (median 1004ms vs the 1000ms budget) and at load 76 (a render of 1802ms and a
# SIGALRM). Two independent causes, fixed at their own layers:
#   PRODUCT — one render launched python3 NINE times for the Cursor fixture (ELEVEN for a
#     Claude Code payload): hmd_python's validation probe, the render-width probe,
#     ctx-meter's four `$(hmd_python)` + four parses, the Cursor host-label normalizer, the
#     watchman, the CTX-honesty post-process. At ~56ms apiece idle and several times that
#     under contention, that was the render. It now launches it TWICE (the watchman, which
#     does the width / host-label / CTX corrections itself under --host-boundary, and one
#     ctx-meter parse): same hermetic fixture, interleaved A/B, 15 reps, idle box (load ~8):
#       wall median 597ms -> 245ms   CPU median 545ms -> 222ms   output byte-identical.
#   TEST — the suite was not hermetic: the fixture's `cwd` is the REAL repo and no
#     HMD_AGENT_CWD was set, so the timed renders spawned `heimdall-agents count` and the
#     presence/roster refresh against the real repo's .heimdall (73 transcripts, 31MB) as
#     detached children that burnt CPU through the next renders — and were still writing
#     into the temp HOME when its `rm -rf` ran. test/lib/statusline_sandbox.py closes the
#     timed region (private HOME/TMPDIR/HMD_AGENT_CWD, payload cwd rewritten, every refresh
#     throttle pre-seeded fresh in the future) and proves it stayed closed.
#
# THE ASSERTIONS, and why each is judged the way it is:
#   1. HARD KILL BACKSTOP — 5 renders under a real `perl alarm 2; exec` (SIGALRM kill,
#      the stand-in for Cursor's original 2000ms timeoutMs; macOS has no timeout(1)).
#      Judged on the MEDIAN, not the first sample: a lone sample is exactly what lost to a
#      load spike. Median-of-N against a fixed budget is the existing pattern for this noise
#      (heimdall-team-default.test.sh, commit 8251b982). A true hang/regression kills EVERY
#      sample, so the median still catches it. Sample 1 is a cold HOME (bytecode caches
#      empty) and is printed, but the median is what is judged.
#   2. SOFT BUDGET, WALL — median of 15 warm renders < 1000ms, half of Cursor's 2000ms.
#      Measured post-fix: 245ms idle. Observed contention on this box scaled the old render
#      1.8x at load 34 and 3.3x at load 76, which puts this one near 440ms / 810ms there —
#      so 1000ms keeps real headroom at the worst load seen while still being a gross-
#      regression backstop. Wall time cannot also be a tight gate: the same code spans 245ms
#      to ~800ms with load alone.
#   3. SOFT BUDGET, CPU — median child-tree CPU (user+sys) of the same 15 renders < 450ms.
#      CPU does not inflate with contention the way wall does, so THIS is the load-proof
#      regression net: post-fix 222-229ms (2x headroom); the nine-launch render it replaced
#      measured 545-818ms, i.e. reintroducing even most of those launches fails it at any
#      load. (It replaces the old `max < 2000ms` check: a single-sample extreme, the same
#      criterion as assertion 1 judged on one render, and the flaky half of the old suite.)
#
# FALSIFIER, built in (set PERF_BUDGET_INJECT_SLEEP=<seconds>; it builds a throwaway copy of
# the wrapper with `sleep N` injected right after its HERE= line and judges THAT through this
# suite's own measurement logic — a real RED, reproducible by anyone, no hand-editing):
#     PERF_BUDGET_INJECT_SLEEP=1.5  -> assertion 2 goes RED (median ~1.75s > 1000ms)
#     PERF_BUDGET_INJECT_SLEEP=3    -> assertion 1 goes RED (every sample dies at the alarm)
# The real, unmodified bin/heimdall-statusline passes all three (see the commit message for
# the quoted runs).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-statusline"
FIXTURE="$ROOT/test/fixtures/cursor-real-payload.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 unavailable"
  echo "heimdall-statusline-perf-budget: 0 passed, 0 failed (SKIPPED — python3 unavailable)"
  exit 0
}
command -v perl >/dev/null 2>&1 || {
  echo "SKIP: perl unavailable"
  echo "heimdall-statusline-perf-budget: 0 passed, 0 failed (SKIPPED — perl unavailable)"
  exit 0
}
[ -x "$CLI" ]     || { echo "FATAL: $CLI missing/not executable"; echo "heimdall-statusline-perf-budget: 0 passed, 1 failed"; exit 1; }
[ -f "$FIXTURE" ] || { echo "FATAL: $FIXTURE missing"; echo "heimdall-statusline-perf-budget: 0 passed, 1 failed"; exit 1; }

ALARM_S=2          # the hard-kill ceiling, in whole seconds (perl alarm() truncates)
ALARM_N=5          # samples under the alarm; the median is judged
SOFT_N=15          # warm renders for the soft budgets
SOFT_MED_MS=1000   # wall median budget
SOFT_CPU_MS=450    # CPU median budget

# One measurement pass (test/lib/statusline_perf_measure.py): both sections share ONE hermetic
# sandbox, so the identity / gitcount caches behave as they do in a real session, and the
# machine-readable lines it prints are what the assertions below read.
MEASURED="$(ROOT="$ROOT" CLI="$CLI" FIXTURE="$FIXTURE" ALARM_S="$ALARM_S" ALARM_N="$ALARM_N" \
            SOFT_N="$SOFT_N" INJECT="${PERF_BUDGET_INJECT_SLEEP:-}" PYTHONPATH="$HERE/lib" \
            python3 "$HERE/lib/statusline_perf_measure.py" 2>&1)"

printf '%s\n' "$MEASURED" | grep '^NOTE' || true

echo "== 1) HARD KILL BACKSTOP: median of $ALARM_N renders must survive a ${ALARM_S}s perl alarm (Cursor's original timeoutMs) =="
ALARM_LINE="$(printf '%s\n' "$MEASURED" | grep '^ALARM ')"
read -r _ SURVIVED TOTAL ALARM_TIMES <<<"$ALARM_LINE"
echo "  renders under the ${ALARM_S}s alarm (ms, sample 1 is a cold HOME): ${ALARM_TIMES:-?}  -> $SURVIVED/$TOTAL survived"
NEED=$(( (ALARM_N + 2) / 2 ))
if [ -n "${SURVIVED:-}" ] && [ "$SURVIVED" -ge "$NEED" ]; then
  ok "median render completes within the ${ALARM_S}s hard-kill alarm ($SURVIVED/$TOTAL survived, >=$NEED needed)"
else
  bad "median render did not complete within ${ALARM_S}s — only ${SURVIVED:-0}/$ALARM_N survived (need >=$NEED): SIGALRM fired on the majority"
fi

echo "== 2+3) SOFT BUDGETS: median wall + median CPU over $SOFT_N warm renders of the real fixture (hermetic sandbox) =="
SOFT_LINE="$(printf '%s\n' "$MEASURED" | grep '^SOFT ')"
read -r _ MED MX CPU LOAD <<<"$SOFT_LINE"
echo "  render (real fixture, $SOFT_N reps): wall median=${MED}ms max=${MX}ms, cpu median=${CPU}ms (box load ${LOAD}) — budgets: wall<${SOFT_MED_MS}ms cpu<${SOFT_CPU_MS}ms"
python3 -c "import sys; sys.exit(0 if float('${MED:-99999}') < $SOFT_MED_MS else 1)" \
  && ok "median wall ${MED}ms < ${SOFT_MED_MS}ms soft budget" \
  || bad "median wall ${MED:-?}ms exceeds the ${SOFT_MED_MS}ms soft budget — perf regression"
python3 -c "import sys; sys.exit(0 if float('${CPU:-99999}') < $SOFT_CPU_MS else 1)" \
  && ok "median CPU ${CPU}ms < ${SOFT_CPU_MS}ms (load-insensitive regression net)" \
  || bad "median CPU ${CPU:-?}ms exceeds ${SOFT_CPU_MS}ms — a render is doing more work (extra launches?)"

REFRESHED="$(printf '%s\n' "$MEASURED" | sed -n 's/^REFRESHED //p')"
[ "$REFRESHED" = "-" ] || echo "  WARNING: hermeticity not proven — a refresh child ran inside the sandbox ($REFRESHED); the numbers above include its CPU"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

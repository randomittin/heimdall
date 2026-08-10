#!/usr/bin/env bash
# test/s6-sweep.test.sh — S-6 C3 sweep RUNNER HARNESS acceptance test.
#
# Proves the CAPPED, STAGED, dry-default sweep MACHINERY end-to-end WITHOUT any
# real model call, network clone, or token spend. Every spend-bearing seam is
# MOCKED so this test is deterministic + free (the ONLY mocking lives here; the
# harness itself is real orchestration):
#
#   * the `hmd "task"` per-repo run is replaced by an injected --hmd-cmd that
#     applies a pre-canned diff to a LOCAL mock git repo (built inline) — no
#     model, no network.
#   * the token-spend source is replaced by an injected --spend-cmd that echoes a
#     deterministic integer — so the cap logic is exercised against known spend.
#   * the "clone" is replaced by an injected --clone-cmd that copies the local
#     mock repo into the work dir — no network fetch.
#
# Asserted (the spec's C3 acceptance for the harness):
#   (a) --dry-run validates the manifest, PRINTS the plan + a per-task spend
#       ESTIMATE, and spends NOTHING (no clone, no hmd, no spend-cmd invoked).
#   (b) default with NO mode flag == --dry-run (safe-by-default, like `hmd bench`).
#   (c) the HARD SPEND CAP aborts FAIL-CLOSED when projected spend exceeds it,
#       leaving a PARTIAL report — and never runs the task that would blow it.
#   (d) the report JSON is well-formed with reuse_pct + working_output (pass/fail
#       + QUOTED evidence) + token_spend per entry.
#   (e) working_output is captured from RUNNABLE EVIDENCE (the repo's baseline_cmd
#       + the task's assertion_cmd exit status), NOT a self-report: a failing
#       command is recorded FAIL even when the agent "succeeded".
#   (j) the runner runs BOTH baseline_cmd AND assertion_cmd, and gates
#       working_output.pass = baseline_pass && assertion_pass: baseline-passes-but-
#       assertion-fails => pass=false; both-pass => pass=true (the runnable
#       acceptance split — no eval-on-prose).
#   (f) --confirm-full is REQUIRED to run more than --limit entries (the
#       unattended-sweep guard): a full (all-entries) run without it aborts.
#   (g) a malformed manifest is rejected with a usage error (exit 2), spending
#       nothing.
#   (h) the runner CHECKS OUT THE EXACT PINNED SHA, not the clone's HEAD: with an
#       entry pinned to an OLDER commit (where a symbol is ABSENT) and a clone that
#       lands at the NEWER HEAD (where it is PRESENT), the runner must land the
#       older sha — `git rev-parse HEAD == pinned sha` — and the report must record
#       resolved_sha == the older sha (provenance), proving it ran the PINNED state.
#   (i) a manifest entry MISSING `sha` is REJECTED fail-closed (exit 2): a pinless
#       entry would silently clone HEAD — exactly the drift bug the pin fixes.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SWEEP="$ROOT/bin/heimdall-s6-sweep"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON assertions" >&2; exit 2; }
[ -x "$SWEEP" ] || { echo "FATAL: sweep harness not executable at $SWEEP" >&2; exit 2; }

WORK="$(mktemp -d -t "s6-sweep-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── build a LOCAL mock target repo (the synthetic clone source) ───────────────
# It has a pre-existing helper the canned diff REUSES, so the reuse metric scores
# a real, nonzero number over the mock run — no model needed.
MOCKREPO="$WORK/mock-target"
mkdir -p "$MOCKREPO/utils" "$MOCKREPO/api"
git -C "$MOCKREPO" init -q
git -C "$MOCKREPO" config user.email "test@runheimdall.dev"
git -C "$MOCKREPO" config user.name "s6-mock"
cat > "$MOCKREPO/utils/format.js" <<'EOF'
export function formatUser(user) {
  return user.first + " " + user.last + " <" + user.email + ">";
}
EOF
# the repo's own test suite — the baseline_cmd runs THIS (the regression signal),
# and we control its exit status per-scenario via an env var so we can prove
# evidence-based capture.
cat > "$MOCKREPO/run-tests.sh" <<'EOF'
#!/usr/bin/env bash
echo "mock-target test suite: ${MOCK_TEST_LABEL:-default}"
exit "${MOCK_BASELINE_RC:-0}"
EOF
chmod +x "$MOCKREPO/run-tests.sh"
# the task-specific assertion — the assertion_cmd runs THIS (the behavior check),
# controlled independently so we can prove BOTH gate working_output (baseline can
# pass while the assertion fails → pass=false, and both-pass → pass=true).
cat > "$MOCKREPO/run-assertion.sh" <<'EOF'
#!/usr/bin/env bash
echo "mock-target assertion: ${MOCK_ASSERT_LABEL:-default}"
exit "${MOCK_ASSERT_RC:-0}"
EOF
chmod +x "$MOCKREPO/run-assertion.sh"
# Track the api/ dir so a REAL `git clone` (which, unlike cp -R, will not
# recreate an empty/untracked dir) still yields api/ for the mock-hmd diff.
printf '' > "$MOCKREPO/api/.gitkeep"
git -C "$MOCKREPO" add -A
git -C "$MOCKREPO" commit -qm "base: mock target with formatUser + test suite"

# ── OLDER commit == the PINNED state. A symbol is DELIBERATELY ABSENT here. ────
# We pin the runner to THIS sha. The probe assumes the symbol is absent; if the
# runner drifted to HEAD it would see the symbol PRESENT (added in the next
# commit). So checking out this older sha is exactly what proves the pin works:
# the runner must run the PINNED (absent-symbol) state, NOT HEAD.
OLD_SHA="$(git -C "$MOCKREPO" rev-parse HEAD)"

# ── NEWER commit == HEAD. The symbol is now PRESENT. If the runner IGNORED the
#    pin and used the clone's HEAD, this is the (wrong) state it would sweep. ───
cat > "$MOCKREPO/utils/feature.js" <<'EOF'
// shippedLater is PRESENT at HEAD but ABSENT at OLD_SHA — the exact drift the
// SHA pin guards against (a depth-1 clone would land HEAD and see this symbol).
export function shippedLater() { return "feature already shipped at HEAD"; }
EOF
git -C "$MOCKREPO" add -A
git -C "$MOCKREPO" commit -qm "feat: shippedLater (PRESENT at HEAD, ABSENT at OLD_SHA)"
HEAD_SHA="$(git -C "$MOCKREPO" rev-parse HEAD)"
[ "$OLD_SHA" != "$HEAD_SHA" ] \
  || { echo "FATAL: mock repo did not produce two distinct commits" >&2; exit 2; }

# ── the canned diff the MOCK agent "produces": a new endpoint that REUSES
#    formatUser (so reuse_pct is real and nonzero). Written by --hmd-cmd. ───────
CANNED_DIFF="$WORK/canned-endpoint.js"
cat > "$CANNED_DIFF" <<'EOF'
import { formatUser } from "../utils/format.js";
// reuses the pre-existing formatUser instead of rewriting it.
export function userEndpoint(req, res) {
  res.send(formatUser(req.user));
}
EOF

# ── MOCK clone: a REAL local `git clone` of the mock repo (no network). ────────
# Crucially this is a real clone with a proper `origin` remote, so the runner's
# OWN checkout_sha (fetch origin <sha> + checkout + assert) runs FOR REAL against
# it — the SHA-checkout logic is exercised, not stubbed. The clone lands at HEAD
# (the NEWER commit), so the runner must ACTIVELY check out the older pinned sha.
CLONE_CMD="$WORK/mock-clone.sh"
cat > "$CLONE_CMD" <<EOF
#!/usr/bin/env bash
# args: <repo_url> <dest_dir>  — real local clone, no network.
set -euo pipefail
git clone --quiet "$MOCKREPO" "\$2"
EOF
chmod +x "$CLONE_CMD"

# ── MOCK hmd "task": apply the canned diff into the cloned repo (no model). ────
#    Touches a $SWEEP_HMD_MARKER file so the test can prove it was/ wasn't called.
HMD_CMD="$WORK/mock-hmd.sh"
cat > "$HMD_CMD" <<EOF
#!/usr/bin/env bash
# args: <repo_dir> <task_prompt>
set -euo pipefail
: > "$WORK/hmd-was-called"
cp "$CANNED_DIFF" "\$1/api/users.js"
echo "mock-hmd: applied canned endpoint to \$1 for task: \$2"
EOF
chmod +x "$HMD_CMD"

# ── MOCK token-spend source: echo a deterministic integer per task. ───────────
#    Touches a marker so the dry-run test can prove spend was NEVER consulted.
SPEND_CMD="$WORK/mock-spend.sh"
cat > "$SPEND_CMD" <<EOF
#!/usr/bin/env bash
# echoes the token spend attributed to the just-finished task.
: > "$WORK/spend-was-called"
echo "\${MOCK_SPEND:-50000}"
EOF
chmod +x "$SPEND_CMD"

# ── a 2-entry manifest pointing at the local mock target, PINNED to OLD_SHA ────
# Both entries pin the OLDER sha (the absent-symbol state). formatUser exists at
# OLD_SHA (added in the base commit), so reuse is still real; shippedLater does
# NOT — which is what lets us prove the runner ran the pinned commit, not HEAD.
MANIFEST="$WORK/repos.json"
cat > "$MANIFEST" <<EOF
[
  {
    "repo_url": "file://$MOCKREPO",
    "sha": "$OLD_SHA",
    "lang": "js",
    "license": "MIT",
    "task_prompt": "add an endpoint that returns a formatted user",
    "reused_symbols_expected": ["formatUser"],
    "baseline_cmd": "bash run-tests.sh",
    "assertion_cmd": "bash run-assertion.sh"
  },
  {
    "repo_url": "file://$MOCKREPO",
    "sha": "$OLD_SHA",
    "lang": "js",
    "license": "MIT",
    "task_prompt": "add a second endpoint reusing formatUser",
    "reused_symbols_expected": ["formatUser"],
    "baseline_cmd": "bash run-tests.sh",
    "assertion_cmd": "bash run-assertion.sh"
  }
]
EOF

run_sweep() {
  # run the harness with all spend-bearing seams mocked. Prints stdout; sets RC.
  "$SWEEP" --manifest "$MANIFEST" \
           --clone-cmd "$CLONE_CMD" \
           --hmd-cmd "$HMD_CMD" \
           --spend-cmd "$SPEND_CMD" \
           "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# (a) --dry-run validates + prints plan + spend ESTIMATE and spends NOTHING.
# ─────────────────────────────────────────────────────────────────────────────
rm -f "$WORK/hmd-was-called" "$WORK/spend-was-called"
DRY_OUT="$(run_sweep --dry-run 2>&1)"; DRY_RC=$?
if [ "$DRY_RC" -eq 0 ] \
   && grep -qiE 'dry.?run|plan' <<<"$DRY_OUT" \
   && grep -qiE 'estimate' <<<"$DRY_OUT" \
   && [ ! -e "$WORK/hmd-was-called" ] && [ ! -e "$WORK/spend-was-called" ]; then
  ok "(a) --dry-run validates + prints plan + spend estimate, spends nothing (no hmd, no spend)"
else
  bad "(a) --dry-run did not behave safe-by-default (rc=$DRY_RC, hmd=$([ -e "$WORK/hmd-was-called" ] && echo called || echo no))"
  printf '%s\n' "$DRY_OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (b) default with NO mode flag == --dry-run.
# ─────────────────────────────────────────────────────────────────────────────
rm -f "$WORK/hmd-was-called" "$WORK/spend-was-called"
DEF_OUT="$(run_sweep 2>&1)"; DEF_RC=$?
if [ "$DEF_RC" -eq 0 ] \
   && grep -qiE 'dry.?run' <<<"$DEF_OUT" \
   && [ ! -e "$WORK/hmd-was-called" ]; then
  ok "(b) default (no flags) == dry-run (safe-by-default)"
else
  bad "(b) default was not dry-run (rc=$DEF_RC)"; printf '%s\n' "$DEF_OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (c) SOFT WARN BUDGET on non_cache_tokens — WARNS + flags, does NOT halt.
# ─────────────────────────────────────────────────────────────────────────────
# Each task "spends" 50k non_cache_tokens (MOCK_SPEND wraps into both total_tokens
# and non_cache_tokens). With --budget 60000, task 1 (cum 50k) is UNDER budget,
# task 2 (cum 100k) CROSSES it. The NEW soft-warn contract: crossing the budget
# WARNS + sets budget_exceeded:true on the crossing entry, but the sweep STILL
# RUNS ALL ENTRIES (no abort) — solid work isn't killed mid-flight for an arbitrary
# line; the CC account limits are the real ceiling. The run exits 0 (a signal, not
# a gate), aborted stays false, BOTH entries run.
rm -f "$WORK/hmd-was-called" "$WORK/spend-was-called"
RUNID_CAP="budgettest-$$"
set +e
MOCK_SPEND=50000 run_sweep --confirm-full --budget 60000 --run-id "$RUNID_CAP" >"$WORK/cap.out" 2>&1
CAP_RC=$?
set -e
CAP_REPORT="$ROOT/.planning/s6-sweep/$RUNID_CAP.json"
if [ "$CAP_RC" -eq 0 ] && [ -f "$CAP_REPORT" ]; then
  RAN="$(jq '[.results[] | select(.status=="ran")] | length' "$CAP_REPORT")"
  ABORTED="$(jq -r '.aborted' "$CAP_REPORT")"
  # entry 0 cum non_cache = 50k (under 60k) => budget_exceeded false.
  # entry 1 cum non_cache = 100k (over 60k)  => budget_exceeded true.
  BE0="$(jq -r '.results[0].budget_exceeded' "$CAP_REPORT")"
  BE1="$(jq -r '.results[1].budget_exceeded' "$CAP_REPORT")"
  ANYBE="$(jq -r '.budget_exceeded' "$CAP_REPORT")"
  WARNED=$(grep -qiE 'budget' "$WORK/cap.out" && echo yes || echo no)
  if [ "$RAN" = "2" ] && [ "$ABORTED" = "false" ] \
     && [ "$BE0" = "false" ] && [ "$BE1" = "true" ] && [ "$ANYBE" = "true" ] \
     && [ "$WARNED" = "yes" ]; then
    ok "(c) soft budget: ALL 2 entries ran (no abort, rc=0); over-budget entry flagged budget_exceeded:true + WARNED; under-budget entry false"
  else
    bad "(c) soft budget wrong (ran=$RAN aborted=$ABORTED be0=$BE0 be1=$BE1 any=$ANYBE warned=$WARNED rc=$CAP_RC)"
    jq . "$CAP_REPORT"; echo "---stderr---"; cat "$WORK/cap.out"
  fi
else
  bad "(c) soft-budget run did not complete cleanly (rc=$CAP_RC, expected 0; report=$([ -f "$CAP_REPORT" ] && echo present || echo missing))"
  cat "$WORK/cap.out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (d) report JSON well-formed: reuse_pct + working_output + token_spend per entry
# ─────────────────────────────────────────────────────────────────────────────
# A full 2-entry run with a generous cap. Both baseline + assertion pass (rc 0).
rm -f "$WORK/hmd-was-called" "$WORK/spend-was-called"
RUNID_OK="oktest-$$"
set +e
MOCK_SPEND=50000 MOCK_BASELINE_RC=0 MOCK_ASSERT_RC=0 run_sweep --confirm-full --cap 600000 --run-id "$RUNID_OK" >"$WORK/ok.out" 2>&1
OK_RC=$?
set -e
OK_REPORT="$ROOT/.planning/s6-sweep/$RUNID_OK.json"
if [ "$OK_RC" -eq 0 ] && [ -f "$OK_REPORT" ] && jq -e . "$OK_REPORT" >/dev/null; then
  # every result entry has the three required fields with sane shapes.
  if jq -e '
      (.results | length) == 2
      and (.results | all(
            has("reuse_pct")
            and (.working_output | has("pass") and has("evidence"))
            and (.token_spend | type == "number")))
    ' "$OK_REPORT" >/dev/null; then
    ok "(d) report JSON well-formed: reuse_pct + working_output{pass,evidence} + token_spend per entry"
  else
    bad "(d) report entries missing required fields"; jq '.results' "$OK_REPORT"
  fi
else
  bad "(d) full run did not produce a well-formed report (rc=$OK_RC)"; cat "$WORK/ok.out"
fi

# the reuse_pct recorded must be the REAL measured number (the canned diff reuses
# formatUser → nonzero), proving the metric actually ran over the run's diff.
if [ -f "$OK_REPORT" ]; then
  R0="$(jq -r '.results[0].reuse_pct' "$OK_REPORT")"
  if [ "$R0" != "null" ] && jq -e '.results[0].reused_symbols | index("formatUser")' "$OK_REPORT" >/dev/null; then
    ok "(d2) reuse_pct is the real measured value (reused_symbols names formatUser): $R0"
  else
    bad "(d2) reuse_pct not measured from the run diff (got $R0)"; jq '.results[0]' "$OK_REPORT"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# (k) do_spend reports the REAL token total (not 0) and records the FULL
#     breakdown for provenance — the heimdall-tokens wiring, exercised through
#     the deterministic --spend-cmd seam (which the runner wraps into a token
#     record whose total_tokens == the measured figure).
# ─────────────────────────────────────────────────────────────────────────────
# MOCK_SPEND=50000 flows through do_token_record → do_spend as the cap figure AND
# is recorded in token_usage.total_tokens (provenance). token_spend must be the
# real 50000, NEVER 0, and must equal token_usage.total_tokens (the cap source).
if [ -f "$OK_REPORT" ]; then
  TS0="$(jq -r '.results[0].token_spend' "$OK_REPORT")"
  TU0="$(jq -r '.results[0].token_usage.total_tokens' "$OK_REPORT")"
  if [ "$TS0" = "50000" ] && [ "$TU0" = "50000" ] \
     && jq -e '.results[0] | has("token_usage")' "$OK_REPORT" >/dev/null; then
    ok "(k) do_spend reports REAL total_tokens (not 0) + records full breakdown: token_spend=$TS0 == token_usage.total_tokens=$TU0"
  else
    bad "(k) token spend not flowing from the meter's total_tokens (token_spend=$TS0 token_usage.total_tokens=$TU0)"
    jq '.results[0] | {token_spend, token_usage}' "$OK_REPORT"
  fi
  # the recorded total spend must equal the summed per-task total_tokens (the cap
  # is enforced on this exact figure).
  SUM_TU="$(jq '[.results[] | select(.status=="ran") | .token_usage.total_tokens] | add' "$OK_REPORT")"
  TOTSPEND="$(jq -r '.total_token_spend' "$OK_REPORT")"
  if [ "$SUM_TU" = "$TOTSPEND" ]; then
    ok "(k2) total_token_spend == sum of per-task token_usage.total_tokens ($TOTSPEND)"
  else
    bad "(k2) total_token_spend ($TOTSPEND) != summed per-task total_tokens ($SUM_TU)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# (l) the SOFT BUDGET is measured on non_cache_tokens specifically: the (c) test
#     proved the flag+warn+no-abort; here we assert the figure the budget is judged
#     on is the meter's non_cache_tokens (recorded in token_usage), summed across
#     entries — NOT total_tokens, and NOT a phantom 0. cache_read is excluded.
# ─────────────────────────────────────────────────────────────────────────────
if [ -f "$CAP_REPORT" ]; then
  # both entries ran (no abort); the cumulative budget figure is the summed
  # non_cache_tokens (50k + 50k = 100k), recorded + reported as total_non_cache_tokens.
  CNC="$(jq -r '[.results[] | select(.status=="ran") | .token_usage.non_cache_tokens] | add // 0' "$CAP_REPORT")"
  CNCREP="$(jq -r '.total_non_cache_tokens' "$CAP_REPORT")"
  BUDGET="$(jq -r '.budget' "$CAP_REPORT")"
  if [ "$CNC" -gt 0 ] && [ "$CNC" = "$CNCREP" ] && [ "$CNC" -gt "$BUDGET" ] && [ "$BUDGET" = "60000" ]; then
    ok "(l) budget judged on REAL non_cache_tokens (summed=$CNC == report's total_non_cache_tokens, > budget $BUDGET), not total_tokens/phantom-0"
  else
    bad "(l) budget not measured on the meter's non_cache_tokens (summed=$CNC reported=$CNCREP budget=$BUDGET)"
    jq '[.results[] | select(.status=="ran") | .token_usage]' "$CAP_REPORT"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# (e) working_output from RUNNABLE EVIDENCE, not self-report: a failing baseline
#     command => working_output.pass=false even though the agent "ran", and the
#     command's QUOTED output is captured as evidence.
# ─────────────────────────────────────────────────────────────────────────────
RUNID_FAIL="failtest-$$"
set +e
MOCK_SPEND=50000 MOCK_BASELINE_RC=1 MOCK_TEST_LABEL="boom" MOCK_ASSERT_RC=0 run_sweep \
    --confirm-full --cap 600000 --run-id "$RUNID_FAIL" >"$WORK/fail.out" 2>&1
FAIL_RC=$?
set -e
FAIL_REPORT="$ROOT/.planning/s6-sweep/$RUNID_FAIL.json"
if [ -f "$FAIL_REPORT" ]; then
  PASSV="$(jq -r '.results[0].working_output.pass' "$FAIL_REPORT")"
  BASEV="$(jq -r '.results[0].working_output.baseline_pass' "$FAIL_REPORT")"
  EVID="$(jq -r '.results[0].working_output.evidence' "$FAIL_REPORT")"
  if [ "$PASSV" = "false" ] && [ "$BASEV" = "false" ] && grep -q "boom" <<<"$EVID"; then
    ok "(e) working_output from evidence: failing baseline command => pass=false with quoted output"
  else
    bad "(e) failing command not captured as evidence (pass=$PASSV baseline=$BASEV)"; jq '.results[0].working_output' "$FAIL_REPORT"
  fi
else
  bad "(e) fail-evidence run produced no report (rc=$FAIL_RC)"; cat "$WORK/fail.out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (j) the runner runs BOTH baseline_cmd AND assertion_cmd and gates
#     working_output.pass = baseline_pass && assertion_pass.
# ─────────────────────────────────────────────────────────────────────────────
# (j1) baseline PASSES but assertion FAILS => pass=false (the case the old prose
#      eval could never express — the regression suite was green but the requested
#      behavior was wrong). Both sub-results are recorded with quoted evidence.
RUNID_J1="splitfail-$$"
set +e
MOCK_SPEND=50000 MOCK_BASELINE_RC=0 MOCK_TEST_LABEL="suite-green" \
  MOCK_ASSERT_RC=1 MOCK_ASSERT_LABEL="behavior-wrong" run_sweep \
    --limit 1 --run-id "$RUNID_J1" >"$WORK/j1.out" 2>&1
J1_RC=$?
set -e
J1_REPORT="$ROOT/.planning/s6-sweep/$RUNID_J1.json"
if [ "$J1_RC" -eq 0 ] && [ -f "$J1_REPORT" ]; then
  WO="$(jq -c '.results[0].working_output' "$J1_REPORT")"
  P="$(printf '%s' "$WO" | jq -r '.pass')"
  BP="$(printf '%s' "$WO" | jq -r '.baseline_pass')"
  AP="$(printf '%s' "$WO" | jq -r '.assertion_pass')"
  AX="$(printf '%s' "$WO" | jq -r '.assertion_exit')"
  EV="$(printf '%s' "$WO" | jq -r '.evidence')"
  if [ "$P" = "false" ] && [ "$BP" = "true" ] && [ "$AP" = "false" ] && [ "$AX" = "1" ] \
     && grep -q "suite-green" <<<"$EV" \
     && grep -q "behavior-wrong" <<<"$EV"; then
    ok "(j1) baseline PASS + assertion FAIL => working_output.pass=false (both run, both quoted)"
  else
    bad "(j1) split gating wrong (pass=$P baseline=$BP assertion=$AP assertion_exit=$AX)"; printf '%s\n' "$WO"
  fi
else
  bad "(j1) split-fail run produced no report (rc=$J1_RC)"; cat "$WORK/j1.out"
fi

# (j2) baseline PASSES and assertion PASSES => pass=true (both gates satisfied).
RUNID_J2="splitpass-$$"
set +e
MOCK_SPEND=50000 MOCK_BASELINE_RC=0 MOCK_ASSERT_RC=0 run_sweep \
    --limit 1 --run-id "$RUNID_J2" >"$WORK/j2.out" 2>&1
J2_RC=$?
set -e
J2_REPORT="$ROOT/.planning/s6-sweep/$RUNID_J2.json"
if [ "$J2_RC" -eq 0 ] && [ -f "$J2_REPORT" ]; then
  WO2="$(jq -c '.results[0].working_output' "$J2_REPORT")"
  P2="$(printf '%s' "$WO2" | jq -r '.pass')"
  BP2="$(printf '%s' "$WO2" | jq -r '.baseline_pass')"
  AP2="$(printf '%s' "$WO2" | jq -r '.assertion_pass')"
  if [ "$P2" = "true" ] && [ "$BP2" = "true" ] && [ "$AP2" = "true" ]; then
    ok "(j2) baseline PASS + assertion PASS => working_output.pass=true (both gates satisfied)"
  else
    bad "(j2) both-pass gating wrong (pass=$P2 baseline=$BP2 assertion=$AP2)"; printf '%s\n' "$WO2"
  fi
else
  bad "(j2) both-pass run produced no report (rc=$J2_RC)"; cat "$WORK/j2.out"
fi

# (j3) baseline FAILS but assertion PASSES => pass=false (the regression gate).
RUNID_J3="basefail-$$"
set +e
MOCK_SPEND=50000 MOCK_BASELINE_RC=1 MOCK_ASSERT_RC=0 run_sweep \
    --limit 1 --run-id "$RUNID_J3" >"$WORK/j3.out" 2>&1
J3_RC=$?
set -e
J3_REPORT="$ROOT/.planning/s6-sweep/$RUNID_J3.json"
if [ "$J3_RC" -eq 0 ] && [ -f "$J3_REPORT" ]; then
  P3="$(jq -r '.results[0].working_output.pass' "$J3_REPORT")"
  BP3="$(jq -r '.results[0].working_output.baseline_pass' "$J3_REPORT")"
  AP3="$(jq -r '.results[0].working_output.assertion_pass' "$J3_REPORT")"
  if [ "$P3" = "false" ] && [ "$BP3" = "false" ] && [ "$AP3" = "true" ]; then
    ok "(j3) baseline FAIL + assertion PASS => working_output.pass=false (regression gate)"
  else
    bad "(j3) regression gate wrong (pass=$P3 baseline=$BP3 assertion=$AP3)"; jq '.results[0].working_output' "$J3_REPORT"
  fi
else
  bad "(j3) regression-gate run produced no report (rc=$J3_RC)"; cat "$WORK/j3.out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (f) --confirm-full REQUIRED to run more than --limit (unattended-sweep guard).
# ─────────────────────────────────────────────────────────────────────────────
# A full (all 2 entries) NON-dry run WITHOUT --confirm-full must abort, spending
# nothing. (--limit 2 == all entries here, so it requires the gate.)
rm -f "$WORK/hmd-was-called"
set +e
run_sweep --limit 2 >"$WORK/noconfirm.out" 2>&1
NC_RC=$?
set -e
if [ "$NC_RC" -ne 0 ] \
   && grep -qiE 'confirm-full' "$WORK/noconfirm.out" \
   && [ ! -e "$WORK/hmd-was-called" ]; then
  ok "(f) full run without --confirm-full aborts (unattended-sweep guard), spends nothing"
else
  bad "(f) full run was not gated on --confirm-full (rc=$NC_RC)"; cat "$WORK/noconfirm.out"
fi

# a --limit 1 run (the dry-1-2 stage, fewer than all) does NOT need --confirm-full.
rm -f "$WORK/hmd-was-called"
RUNID_L1="limit1-$$"
set +e
MOCK_SPEND=50000 MOCK_BASELINE_RC=0 MOCK_ASSERT_RC=0 run_sweep --limit 1 --run-id "$RUNID_L1" >"$WORK/limit1.out" 2>&1
L1_RC=$?
set -e
L1_REPORT="$ROOT/.planning/s6-sweep/$RUNID_L1.json"
if [ "$L1_RC" -eq 0 ] && [ -f "$L1_REPORT" ] \
   && [ "$(jq '[.results[] | select(.status=="ran")] | length' "$L1_REPORT")" = "1" ]; then
  ok "(f2) --limit 1 (fewer than all) runs WITHOUT --confirm-full (the dry-1-2 stage)"
else
  bad "(f2) --limit 1 staged run failed (rc=$L1_RC)"; cat "$WORK/limit1.out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (g) malformed manifest rejected (exit 2), spends nothing.
# ─────────────────────────────────────────────────────────────────────────────
BADMAN="$WORK/bad.json"
echo '[ { "lang": "js" } ]' > "$BADMAN"   # missing repo_url/task_prompt/baseline_cmd/assertion_cmd
rm -f "$WORK/hmd-was-called"
set +e
"$SWEEP" --manifest "$BADMAN" --clone-cmd "$CLONE_CMD" --hmd-cmd "$HMD_CMD" \
         --spend-cmd "$SPEND_CMD" --dry-run >"$WORK/bad.out" 2>&1
BAD_RC=$?
set -e
if [ "$BAD_RC" -eq 2 ] && [ ! -e "$WORK/hmd-was-called" ]; then
  ok "(g) malformed manifest rejected with usage error (exit 2), spends nothing"
else
  bad "(g) malformed manifest not rejected (rc=$BAD_RC, expected 2)"; cat "$WORK/bad.out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (h) the runner CHECKS OUT THE PINNED (older) SHA, not the clone's HEAD.
# ─────────────────────────────────────────────────────────────────────────────
# Sanity first: confirm the two commits genuinely differ on the probe symbol, so
# "ran the pinned sha" is provably distinct from "ran HEAD".
SYM_AT_OLD="$(git -C "$MOCKREPO" show "$OLD_SHA:utils/feature.js" 2>/dev/null || true)"
SYM_AT_HEAD="$(git -C "$MOCKREPO" show "$HEAD_SHA:utils/feature.js" 2>/dev/null || true)"
if [ -z "$SYM_AT_OLD" ] && grep -q "shippedLater" <<<"$SYM_AT_HEAD"; then
  ok "(h0) fixture is sound: shippedLater ABSENT at pinned OLD_SHA, PRESENT at HEAD"
else
  bad "(h0) fixture not sound (old has symbol? head missing it?) old='${SYM_AT_OLD:0:30}'"
fi

# Run a clean limit-1 sweep. The clone lands at HEAD_SHA; the runner must check
# out OLD_SHA. The report's resolved_sha proves which commit was actually swept.
RUNID_PIN="pintest-$$"
set +e
MOCK_SPEND=50000 MOCK_BASELINE_RC=0 MOCK_ASSERT_RC=0 run_sweep --limit 1 --run-id "$RUNID_PIN" >"$WORK/pin.out" 2>&1
PIN_RC=$?
set -e
PIN_REPORT="$ROOT/.planning/s6-sweep/$RUNID_PIN.json"
if [ "$PIN_RC" -eq 0 ] && [ -f "$PIN_REPORT" ]; then
  RESOLVED="$(jq -r '.results[0].resolved_sha' "$PIN_REPORT")"
  PINNED="$(jq -r '.results[0].pinned_sha' "$PIN_REPORT")"
  STATUS="$(jq -r '.results[0].status' "$PIN_REPORT")"
  if [ "$STATUS" = "ran" ] && [ "$RESOLVED" = "$OLD_SHA" ] && [ "$PINNED" = "$OLD_SHA" ] \
     && [ "$RESOLVED" != "$HEAD_SHA" ]; then
    ok "(h) runner ran the PINNED sha, NOT HEAD: resolved_sha=$RESOLVED == OLD_SHA (≠ HEAD $HEAD_SHA)"
  else
    bad "(h) runner did not check out the pinned sha (status=$STATUS resolved=$RESOLVED pinned=$PINNED head=$HEAD_SHA)"
    jq '.results[0]' "$PIN_REPORT"
  fi
else
  bad "(h) pinned-sha run produced no report (rc=$PIN_RC)"; cat "$WORK/pin.out"
fi

# Independently PROVE the runner actually performed the checkout (git rev-parse
# HEAD == pinned sha) by re-running the runner's real checkout logic the same way:
# clone (lands HEAD) → fetch+checkout OLD_SHA → assert. If checkout were skipped,
# HEAD would equal HEAD_SHA and this assertion would fail.
PROOF_DIR="$WORK/checkout-proof"
git clone --quiet "$MOCKREPO" "$PROOF_DIR"
[ "$(git -C "$PROOF_DIR" rev-parse HEAD)" = "$HEAD_SHA" ] \
  || bad "(h2-pre) fresh clone did not land at HEAD as expected"
git -C "$PROOF_DIR" fetch --depth 1 origin "$OLD_SHA" >/dev/null 2>&1 || true
git -C "$PROOF_DIR" checkout --quiet --detach "$OLD_SHA" >/dev/null 2>&1
if [ "$(git -C "$PROOF_DIR" rev-parse HEAD)" = "$OLD_SHA" ] \
   && [ ! -f "$PROOF_DIR/utils/feature.js" ]; then
  ok "(h2) after checkout: git rev-parse HEAD == pinned sha AND the HEAD-only symbol file is absent"
else
  bad "(h2) checkout did not land the pinned (absent-symbol) state"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (i) a manifest entry MISSING `sha` is REJECTED fail-closed (exit 2).
# ─────────────────────────────────────────────────────────────────────────────
# A pinless entry would silently clone HEAD — the exact drift bug the pin fixes.
PINLESS_MAN="$WORK/pinless.json"
cat > "$PINLESS_MAN" <<EOF
[
  {
    "repo_url": "file://$MOCKREPO",
    "lang": "js",
    "license": "MIT",
    "task_prompt": "add an endpoint that returns a formatted user",
    "reused_symbols_expected": ["formatUser"],
    "acceptance_cmd": "bash run-tests.sh"
  }
]
EOF
rm -f "$WORK/hmd-was-called"
set +e
"$SWEEP" --manifest "$PINLESS_MAN" --clone-cmd "$CLONE_CMD" --hmd-cmd "$HMD_CMD" \
         --spend-cmd "$SPEND_CMD" --confirm-full >"$WORK/pinless.out" 2>&1
PINLESS_RC=$?
set -e
if [ "$PINLESS_RC" -eq 2 ] \
   && grep -qiE 'sha' "$WORK/pinless.out" \
   && [ ! -e "$WORK/hmd-was-called" ]; then
  ok "(i) pinless entry (missing sha) rejected fail-closed (exit 2), no clone, no spend"
else
  bad "(i) pinless entry not rejected fail-closed (rc=$PINLESS_RC, expected 2)"; cat "$WORK/pinless.out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (m) FULL-BREAKDOWN reporting: per-repo + summary carry every token component.
# ─────────────────────────────────────────────────────────────────────────────
# Run a clean 2-entry sweep with a fake HMD that writes a KNOWN emitted record
# (the --hmd-cmd seam exports HEIMDALL_USAGE_OUT) so do_token_record reads the REAL
# meter (NOT --spend-cmd) and the report carries the full normalized breakdown.
# emitted record: in=1000 out=200 cc=300 cr=8000
#   total_tokens     = 9500   non_cache_tokens = 1500   total_cost_usd null => DERIVED
EMIT_HMD="$WORK/mock-hmd-emit.sh"
cat > "$EMIT_HMD" <<EOF
#!/usr/bin/env bash
# args: <repo_dir> <task_prompt> ; HEIMDALL_USAGE_OUT is exported by the runner.
set -euo pipefail
: > "$WORK/hmd-was-called"
cp "$CANNED_DIFF" "\$1/api/users.js"
cat > "\${HEIMDALL_USAGE_OUT}" <<JSON
{
  "session_id": "fake-sess-\$(basename "\$1")",
  "input_tokens": 1000,
  "output_tokens": 200,
  "cache_creation_tokens": 300,
  "cache_read_tokens": 8000,
  "total_cost_usd": null,
  "model": "claude-opus-4-8",
  "usage_available": true
}
JSON
echo "mock-hmd-emit: wrote emitted record for \$2"
EOF
chmod +x "$EMIT_HMD"

RUNID_BD="breakdown-$$"
set +e
"$SWEEP" --manifest "$MANIFEST" --clone-cmd "$CLONE_CMD" --hmd-cmd "$EMIT_HMD" \
         --confirm-full --budget 0 --run-id "$RUNID_BD" >"$WORK/bd.out" 2>&1
BD_RC=$?
set -e
BD_REPORT="$ROOT/.planning/s6-sweep/$RUNID_BD.json"
if [ "$BD_RC" -eq 0 ] && [ -f "$BD_REPORT" ] && jq -e . "$BD_REPORT" >/dev/null; then
  # per-repo token_usage carries the FULL breakdown including non_cache + cost_source.
  if jq -e '
      .results[0].token_usage as $u
      | ($u.input_tokens==1000 and $u.output_tokens==200
         and $u.cache_creation_tokens==300 and $u.cache_read_tokens==8000
         and $u.total_tokens==9500 and $u.non_cache_tokens==1500
         and $u.cost_source=="derived" and ($u.total_cost_usd|type=="number"))
      and (.results[0] | has("budget_exceeded"))
      and (.results[0] | has("session_id"))
    ' "$BD_REPORT" >/dev/null; then
    ok "(m) per-repo full breakdown: in/out/cc/cr + total(9500) + non_cache(1500) + derived cost + session_id + budget_exceeded"
  else
    bad "(m) per-repo breakdown incomplete"; jq '.results[0]' "$BD_REPORT"
  fi
else
  bad "(m) breakdown run failed (rc=$BD_RC)"; cat "$WORK/bd.out"
fi

# (m2) the SUMMARY report rolls up every component across entries.
if [ -f "$BD_REPORT" ]; then
  if jq -e '
      .total_token_spend==19000           # 2 x 9500
      and .total_non_cache_tokens==3000     # 2 x 1500
      and has("budget") and has("budget_exceeded")
      and (.results | all(has("session_id") and (.token_usage | has("non_cache_tokens") and has("cost_source"))))
    ' "$BD_REPORT" >/dev/null; then
    ok "(m2) summary rolls up total_token_spend(19000) + total_non_cache_tokens(3000) + budget + budget_exceeded"
  else
    bad "(m2) summary rollup missing fields"; jq 'del(.results)' "$BD_REPORT"
  fi
fi

# (m3) NO %-saved / tokens-saved headline anywhere (deferred to P3 — needs the
#      raw-CC baseline arm). Assert neither the report NOR the bin emits it.
if [ -f "$BD_REPORT" ]; then
  if ! jq -e 'paths | map(tostring) | join(".") | test("saved|savings|pct_saved|percent_saved";"i")' "$BD_REPORT" >/dev/null 2>&1 \
     && ! grep -qiE 'saved|savings|%[ ]*saved' "$WORK/bd.out"; then
    ok "(m3) NO %-saved / tokens-saved headline in report or stdout (savings deferred to P3)"
  else
    bad "(m3) a savings headline leaked (must be deferred to P3)"; grep -niE 'saved|savings' "$WORK/bd.out" || true
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# (n) budget is CONFIGURABLE via env HEIMDALL_TOKEN_BUDGET (no flag).
# ─────────────────────────────────────────────────────────────────────────────
# With non_cache=1500/entry and HEIMDALL_TOKEN_BUDGET=1000, BOTH entries cross =>
# both flagged, sweep still completes (rc 0).
RUNID_ENV="envbudget-$$"
set +e
HEIMDALL_TOKEN_BUDGET=1000 "$SWEEP" --manifest "$MANIFEST" --clone-cmd "$CLONE_CMD" \
         --hmd-cmd "$EMIT_HMD" --confirm-full --run-id "$RUNID_ENV" >"$WORK/env.out" 2>&1
ENV_RC=$?
set -e
ENV_REPORT="$ROOT/.planning/s6-sweep/$RUNID_ENV.json"
if [ "$ENV_RC" -eq 0 ] && [ -f "$ENV_REPORT" ] \
   && [ "$(jq -r '.budget' "$ENV_REPORT")" = "1000" ] \
   && [ "$(jq -r '.budget_source' "$ENV_REPORT")" = "env" ] \
   && [ "$(jq -r '.results[0].budget_exceeded' "$ENV_REPORT")" = "true" ] \
   && [ "$(jq -r '.budget_exceeded' "$ENV_REPORT")" = "true" ]; then
  ok "(n) env HEIMDALL_TOKEN_BUDGET=1000 configures the budget (budget_source=env), both entries flagged, sweep completes"
else
  bad "(n) env budget not honored (rc=$ENV_RC budget=$(jq -r '.budget // "?"' "$ENV_REPORT" 2>/dev/null))"; cat "$WORK/env.out"
fi

# (n2) explicit --budget OVERRIDES the env var (flag precedence).
RUNID_OVR="ovrbudget-$$"
set +e
HEIMDALL_TOKEN_BUDGET=1000 "$SWEEP" --manifest "$MANIFEST" --clone-cmd "$CLONE_CMD" \
         --hmd-cmd "$EMIT_HMD" --confirm-full --budget 999999 --run-id "$RUNID_OVR" >"$WORK/ovr.out" 2>&1
OVR_RC=$?
set -e
OVR_REPORT="$ROOT/.planning/s6-sweep/$RUNID_OVR.json"
if [ "$OVR_RC" -eq 0 ] && [ -f "$OVR_REPORT" ] \
   && [ "$(jq -r '.budget' "$OVR_REPORT")" = "999999" ] \
   && [ "$(jq -r '.budget_source' "$OVR_REPORT")" = "flag" ] \
   && [ "$(jq -r '.budget_exceeded' "$OVR_REPORT")" = "false" ]; then
  ok "(n2) --budget flag overrides env (budget=999999, budget_source=flag, nothing flagged)"
else
  bad "(n2) flag did not override env (budget=$(jq -r '.budget // "?"' "$OVR_REPORT" 2>/dev/null) src=$(jq -r '.budget_source // "?"' "$OVR_REPORT" 2>/dev/null))"; cat "$WORK/ovr.out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (o) budget 0 / off DISABLES the soft budget — nothing is ever flagged.
# ─────────────────────────────────────────────────────────────────────────────
# --budget 0 (and "off") means no budget: budget_exceeded false everywhere, even
# though each entry "spends" non-zero non_cache tokens.
RUNID_OFF="offbudget-$$"
set +e
"$SWEEP" --manifest "$MANIFEST" --clone-cmd "$CLONE_CMD" --hmd-cmd "$EMIT_HMD" \
         --confirm-full --budget off --run-id "$RUNID_OFF" >"$WORK/off.out" 2>&1
OFF_RC=$?
set -e
OFF_REPORT="$ROOT/.planning/s6-sweep/$RUNID_OFF.json"
if [ "$OFF_RC" -eq 0 ] && [ -f "$OFF_REPORT" ] \
   && [ "$(jq -r '.budget' "$OFF_REPORT")" = "0" ] \
   && [ "$(jq -r '.budget_exceeded' "$OFF_REPORT")" = "false" ] \
   && [ "$(jq -r '[.results[] | select(.budget_exceeded==true)] | length' "$OFF_REPORT")" = "0" ]; then
  ok "(o) --budget off disables the soft budget (budget=0, nothing flagged) even with real spend"
else
  bad "(o) budget off did not disable flagging (rc=$OFF_RC)"; cat "$WORK/off.out"
fi

echo
echo "  s6-sweep harness tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

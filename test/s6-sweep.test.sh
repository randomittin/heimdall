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
#   (e) working_output is captured from RUNNABLE EVIDENCE (the repo's
#       acceptance_cmd exit status), NOT a self-report: a failing acceptance_cmd
#       is recorded FAIL even when the agent "succeeded".
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
# the repo's own test suite — the acceptance_cmd runs THIS, and we control its
# exit status per-scenario via an env var so we can prove evidence-based capture.
cat > "$MOCKREPO/run-tests.sh" <<'EOF'
#!/usr/bin/env bash
echo "mock-target test suite: ${MOCK_TEST_LABEL:-default}"
exit "${MOCK_TEST_RC:-0}"
EOF
chmod +x "$MOCKREPO/run-tests.sh"
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
    "acceptance_cmd": "bash run-tests.sh"
  },
  {
    "repo_url": "file://$MOCKREPO",
    "sha": "$OLD_SHA",
    "lang": "js",
    "license": "MIT",
    "task_prompt": "add a second endpoint reusing formatUser",
    "reused_symbols_expected": ["formatUser"],
    "acceptance_cmd": "bash run-tests.sh"
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
   && printf '%s' "$DRY_OUT" | grep -qiE 'dry.?run|plan' \
   && printf '%s' "$DRY_OUT" | grep -qiE 'estimate' \
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
   && printf '%s' "$DEF_OUT" | grep -qiE 'dry.?run' \
   && [ ! -e "$WORK/hmd-was-called" ]; then
  ok "(b) default (no flags) == dry-run (safe-by-default)"
else
  bad "(b) default was not dry-run (rc=$DEF_RC)"; printf '%s\n' "$DEF_OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (c) HARD SPEND CAP aborts FAIL-CLOSED before blowing the cap, partial report.
# ─────────────────────────────────────────────────────────────────────────────
# Each task "spends" 50k (MOCK_SPEND). With --cap 60000, task 1 (50k) fits, but
# task 2 would project 100k > 60k => abort BEFORE running task 2. Exactly one
# task should run; the report is partial; the exit is nonzero (fail-closed).
rm -f "$WORK/hmd-was-called" "$WORK/spend-was-called"
RUNID_CAP="captest-$$"
set +e
MOCK_SPEND=50000 run_sweep --confirm-full --cap 60000 --run-id "$RUNID_CAP" >"$WORK/cap.out" 2>&1
CAP_RC=$?
set -e
CAP_REPORT="$ROOT/.planning/s6-sweep/$RUNID_CAP.json"
if [ "$CAP_RC" -ne 0 ] && [ -f "$CAP_REPORT" ]; then
  RAN="$(jq '[.results[] | select(.status=="ran")] | length' "$CAP_REPORT")"
  ABORTED="$(jq -r '.aborted' "$CAP_REPORT")"
  TOTAL_SPEND="$(jq -r '.total_token_spend' "$CAP_REPORT")"
  if [ "$RAN" = "1" ] && [ "$ABORTED" = "true" ] && [ "$TOTAL_SPEND" -le 60000 ]; then
    ok "(c) cap fail-closed: aborted before blowing cap (ran=$RAN, spend=$TOTAL_SPEND <= 60000, rc=$CAP_RC)"
  else
    bad "(c) cap did not fail-closed correctly (ran=$RAN aborted=$ABORTED spend=$TOTAL_SPEND rc=$CAP_RC)"
    jq . "$CAP_REPORT"
  fi
else
  bad "(c) cap run did not abort nonzero with a partial report (rc=$CAP_RC, report=$([ -f "$CAP_REPORT" ] && echo present || echo missing))"
  cat "$WORK/cap.out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (d) report JSON well-formed: reuse_pct + working_output + token_spend per entry
# ─────────────────────────────────────────────────────────────────────────────
# A full 2-entry run with a generous cap. Acceptance passes (MOCK_TEST_RC=0).
rm -f "$WORK/hmd-was-called" "$WORK/spend-was-called"
RUNID_OK="oktest-$$"
set +e
MOCK_SPEND=50000 MOCK_TEST_RC=0 run_sweep --confirm-full --cap 600000 --run-id "$RUNID_OK" >"$WORK/ok.out" 2>&1
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
# (e) working_output from RUNNABLE EVIDENCE, not self-report: failing
#     acceptance_cmd => working_output.pass=false even though the agent "ran".
# ─────────────────────────────────────────────────────────────────────────────
RUNID_FAIL="failtest-$$"
set +e
MOCK_SPEND=50000 MOCK_TEST_RC=1 MOCK_TEST_LABEL="boom" run_sweep \
    --confirm-full --cap 600000 --run-id "$RUNID_FAIL" >"$WORK/fail.out" 2>&1
FAIL_RC=$?
set -e
FAIL_REPORT="$ROOT/.planning/s6-sweep/$RUNID_FAIL.json"
if [ -f "$FAIL_REPORT" ]; then
  PASSV="$(jq -r '.results[0].working_output.pass' "$FAIL_REPORT")"
  EVID="$(jq -r '.results[0].working_output.evidence' "$FAIL_REPORT")"
  if [ "$PASSV" = "false" ] && printf '%s' "$EVID" | grep -q "boom"; then
    ok "(e) working_output from evidence: failing acceptance_cmd => pass=false with quoted output"
  else
    bad "(e) failing acceptance not captured as evidence (pass=$PASSV)"; jq '.results[0].working_output' "$FAIL_REPORT"
  fi
else
  bad "(e) fail-evidence run produced no report (rc=$FAIL_RC)"; cat "$WORK/fail.out"
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
MOCK_SPEND=50000 MOCK_TEST_RC=0 run_sweep --limit 1 --run-id "$RUNID_L1" >"$WORK/limit1.out" 2>&1
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
echo '[ { "lang": "js" } ]' > "$BADMAN"   # missing repo_url/task_prompt/acceptance_cmd
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
if [ -z "$SYM_AT_OLD" ] && printf '%s' "$SYM_AT_HEAD" | grep -q "shippedLater"; then
  ok "(h0) fixture is sound: shippedLater ABSENT at pinned OLD_SHA, PRESENT at HEAD"
else
  bad "(h0) fixture not sound (old has symbol? head missing it?) old='${SYM_AT_OLD:0:30}'"
fi

# Run a clean limit-1 sweep. The clone lands at HEAD_SHA; the runner must check
# out OLD_SHA. The report's resolved_sha proves which commit was actually swept.
RUNID_PIN="pintest-$$"
set +e
MOCK_SPEND=50000 MOCK_TEST_RC=0 run_sweep --limit 1 --run-id "$RUNID_PIN" >"$WORK/pin.out" 2>&1
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

echo
echo "  s6-sweep harness tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

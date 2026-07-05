#!/usr/bin/env bash
# test/issue-loop-claude-fix.test.sh — THE bug #20 acceptance: the fix cycle must (a)
# DRIVE the headless coder so a REAL edit lands in the workspace (non-empty diff), and
# (b) EXTRACT the runnable acceptance command from the ISSUE BODY / repo conventions so
# the SI-2 gate has real evidence to run — turning the honest-but-useless GATE_FAILED
# ("0 files, 0 evidence commands") into a PASS on MERIT, WITHOUT weakening the gate.
#
# HERMETIC: a FAKE `claude` binary (writes a real edit; NO model, NO network, NO auth)
# via HEIMDALL_CLAUDE_BIN + a FAKE `gh` on PATH (records the PR-create; NO live GitHub).
# `git`/comprehend/attest run FOR REAL against a throwaway repo.
#
#   (1) PASS: fix edit lands (app.py gains FIXED) -> non-empty diff; ./run_tests.sh is
#       extracted from the body AND repo convention -> gate runs it -> all_passed true
#       -> PR_OPEN, and the FAKE gh records a `pr create` (the PR path fired).
#   (2) FALSIFIER — no-edit claude: the SAME body/repo, but the fake claude writes
#       NOTHING -> ./run_tests.sh stays red -> GATE_FAILED, flagged, NO gh pr create.
#   (3) FALSIFIER — evidence command fails: the edit lands, but ./run_tests.sh always
#       exits 1 -> gate FAILS (a real recorded non-zero exit) -> GATE_FAILED. The gate
#       is honest: an unproven change is never PR'd.
#   (4) SECURITY: a shell-injected acceptance line ("... && rm ...") is DROPPED by the
#       sanitizer — it never reaches evidence_cmds and never runs.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-issue-loop"
QCMD="$ROOT/bin/heimdall-issue-queue"
LIB="$ROOT/bin/lib/issue_loop.py"
EV_LIB="$ROOT/bin/lib/issue_evidence.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
for f in "$CMD" "$QCMD"; do [ -x "$f" ] || { echo "FATAL: $f not executable" >&2; exit 2; }; done
for f in "$LIB" "$EV_LIB"; do [ -f "$f" ] || { echo "FATAL: $f missing" >&2; exit 2; }; done
PY="$(command -v python3 || command -v python)"

WORK="$(mktemp -d -t "issue-loop-claude-fix.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

export PYTHONPATH="$ROOT/bin/lib:${PYTHONPATH:-}"

# ── FAKE claude binaries (no model). The FIX one appends FIXED to app.py in its CWD
#    (the loop invokes claude with cwd=<workspace>); the NOOP one edits nothing. ──────
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude-fix" <<'FIXEOF'
#!/usr/bin/env bash
# fake headless coder: prove the invocation flags arrive AND write a real edit into the
# workspace (cwd). NO model, NO network. Appends a marker the acceptance script greps for.
printf 'FIXED by fake claude\n' >> app.py
echo "fake-claude: wrote edit to app.py"
exit 0
FIXEOF
chmod +x "$FAKEBIN/claude-fix"
cat > "$FAKEBIN/claude-noop" <<'NOOPEOF'
#!/usr/bin/env bash
# fake coder that changes NOTHING (the empty-diff falsifier).
echo "fake-claude: made no changes"
exit 0
NOOPEOF
chmod +x "$FAKEBIN/claude-noop"

# ── FAKE gh (records the PR-create argv; NO live GitHub). ──────────────────────
GH_LOG="$WORK/gh.log"; : > "$GH_LOG"
cat > "$FAKEBIN/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
# emit a fake PR url for \`pr create\` so gh_bot_runner records a url.
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "create" ]; then
  echo "https://github.com/acme/widget/pull/1"
fi
exit 0
GHEOF
chmod +x "$FAKEBIN/gh"

# ── build a throwaway repo with an executable acceptance script gating on the edit ────
new_repo() {
  # $1 = name ; $2 = run_tests body. Prints the repo path.
  local name="$1" rt="$2"
  local repo="$WORK/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" config commit.gpgsign false
  printf 'app v1\n' > "$repo/app.py"
  printf '%s' "$rt" > "$repo/run_tests.sh"
  chmod +x "$repo/run_tests.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

# acceptance that PASSES iff app.py contains FIXED (the edit the fake fix writes).
RT_GATED='#!/usr/bin/env bash
grep -q FIXED app.py
'
# acceptance that ALWAYS fails (the evidence-fails falsifier).
RT_RED='#!/usr/bin/env bash
exit 1
'

seed() {
  # $1 = repo ; $2 = issue number ; $3 = body. Resets that repo's queue first.
  local repo="$1" num="$2" body="$3"
  rm -f "$repo/.heimdall/issues/queue.json"
  local raw
  raw="$("$PY" -c 'import json,sys; print(json.dumps({"repo":"acme/widget","number":int(sys.argv[1]),"title":"make the range inclusive","body":sys.argv[2],"labels":[{"name":"bug"}],"created_at":"2020-06-01T00:00:00Z"}))' "$num" "$body")"
  HEIMDALL_HOME="$repo/.heimdall" "$QCMD" ingest --source github --raw "$raw" --repo "$repo" >/dev/null
}

# the issue body names the acceptance command the conventional way (bug #20's live shape).
BODY='The final element is excluded.

Acceptance (must go green): ./run_tests.sh
Gating test (red today): tests/test_sum_range.py::SumRangeTest::test_inclusive_of_the_final_element
'

run_once() {
  # $1 = repo ; $2 = claude bin. Drives run-once with the headless fix ENABLED, a fake
  # gh on PATH, and a bot token so gh_bot_runner actually invokes the (fake) gh.
  local repo="$1" claudebin="$2"
  ( cd "$repo" && env \
      HEIMDALL_HOME="$repo/.heimdall" \
      PATH="$FAKEBIN:$PATH" \
      HEIMDALL_FIX_WITH_CLAUDE=1 \
      HEIMDALL_CLAUDE_BIN="$claudebin" \
      HEIMDALL_PR_BOT_TOKEN="ghs_FAKEbottoken000000000000000000000000" \
      "$CMD" run-once --repo "$repo" --print 2>/dev/null )
}

echo "── (1) PASS: fix edit lands (non-empty diff) + ./run_tests.sh extracted -> gate PASS ─"
R1="$(new_repo pass_repo "$RT_GATED")"
seed "$R1" 20 "$BODY"
: > "$GH_LOG"
OUT="$(run_once "$R1" "$FAKEBIN/claude-fix")" || true
# the edit actually landed in the workspace (the empty-diff root cause is closed).
if grep -q FIXED "$R1/app.py"; then
  ok "the fake headless coder WROTE a real edit into the workspace (app.py gained FIXED)"
else
  bad "no edit landed — the fix invocation did not write to the workspace"
fi
if printf '%s' "$OUT" | jq -e '.fix.fix_attempt.invoked == true and (.fix.fix_attempt.files_changed // 0) >= 1' >/dev/null 2>&1; then
  ok "the fix cycle RECORDS the claude call (invoked + files_changed>=1) — instrumented"
else
  bad "fix_attempt not recorded / files_changed==0 ($(printf '%s' "$OUT" | jq -c '.fix.fix_attempt'))"
fi
# ./run_tests.sh was EXTRACTED (from the body AND/OR the repo convention) into evidence.
if printf '%s' "$OUT" | jq -e '.evidence_cmds | index("./run_tests.sh") != null' >/dev/null 2>&1; then
  ok "./run_tests.sh was extracted into the gate's evidence commands"
else
  bad "./run_tests.sh NOT extracted ($(printf '%s' "$OUT" | jq -c '.evidence_cmds'))"
fi
# the gate RAN the evidence (ran>=1) and it PASSED on merit.
if printf '%s' "$OUT" | jq -e '(.attestation.evidence.ran // 0) >= 1 and .gate.all_passed == true' >/dev/null 2>&1; then
  ok "the gate RAN the evidence (ran>=1) and all_passed==true (proven fix)"
else
  bad "gate did not run evidence / did not pass ($(printf '%s' "$OUT" | jq -c '.attestation.evidence'))"
fi
if printf '%s' "$OUT" | jq -e '.state == "PR_OPEN" and .pr_ready == true and .pr_opened == true' >/dev/null 2>&1; then
  ok "the issue reached PR_OPEN (pr_ready + real PR layer fired)"
else
  bad "did not reach PR_OPEN ($(printf '%s' "$OUT" | jq -c '.state,.pr_ready,.pr_opened'))"
fi
if grep -q 'pr create' "$GH_LOG"; then
  ok "the PR path was INVOKED — the fake gh recorded a \`pr create\`"
else
  bad "the fake gh recorded no \`pr create\` (PR path not invoked): $(cat "$GH_LOG")"
fi

echo "── (2) FALSIFIER — no-edit claude -> ./run_tests.sh red -> GATE_FAILED, NO PR ────────"
R2="$(new_repo noedit_repo "$RT_GATED")"
seed "$R2" 21 "$BODY"
: > "$GH_LOG"
OUT="$(run_once "$R2" "$FAKEBIN/claude-noop")" || true
if ! grep -q FIXED "$R2/app.py"; then
  ok "the no-edit coder changed nothing (empty diff — the falsifier precondition holds)"
else
  bad "the no-edit falsifier unexpectedly edited the workspace"
fi
if printf '%s' "$OUT" | jq -e '.state == "GATE_FAILED" and .pr_ready == false and .pr_opened == false' >/dev/null 2>&1; then
  ok "no-edit -> GATE_FAILED, NO pr_ready, NO PR (honest gate holds)"
else
  bad "no-edit did NOT fail the gate ($(printf '%s' "$OUT" | jq -c '.state,.gate.all_passed'))"
fi
if ! grep -q 'pr create' "$GH_LOG"; then
  ok "no \`pr create\` on a gate-FAIL (the PR path never fired — falsifiable observable)"
else
  bad "a PR was created on a gate-FAIL — CARDINAL RULE VIOLATED"
fi
if "$QCMD" status --repo "$R2" | jq -e '.flagged >= 1 and .resolved == 0' >/dev/null 2>&1; then
  ok "the issue is flagged (out of the resolved path)"
else
  bad "the gate-failed issue was not flagged"
fi

echo "── (3) FALSIFIER — evidence command fails (edit lands, ./run_tests.sh exits 1) ───────"
R3="$(new_repo redtest_repo "$RT_RED")"
seed "$R3" 22 "$BODY"
: > "$GH_LOG"
OUT="$(run_once "$R3" "$FAKEBIN/claude-fix")" || true
if grep -q FIXED "$R3/app.py"; then
  ok "the edit landed (a non-empty diff) — isolating the EVIDENCE failure"
else
  bad "the edit did not land in the evidence-fails case"
fi
if printf '%s' "$OUT" | jq -e '.state == "GATE_FAILED" and .gate.all_passed == false and .pr_opened == false' >/dev/null 2>&1; then
  ok "a failing evidence command -> GATE_FAILED even with a non-empty diff (gate not weakened)"
else
  bad "a failing evidence command did NOT fail the gate ($(printf '%s' "$OUT" | jq -c '.state,.gate.all_passed'))"
fi

echo "── (4) SECURITY — a shell-injected acceptance line is DROPPED, never runs ────────────"
R4="$(new_repo inject_repo "$RT_GATED")"
INJ_BODY='Acceptance: touch '"$WORK"'/PWNED && ./run_tests.sh
'
seed "$R4" 23 "$INJ_BODY"
OUT="$(run_once "$R4" "$FAKEBIN/claude-fix")" || true
# the injected line (contains &&) must NOT appear as an evidence command...
if printf '%s' "$OUT" | jq -e '[.evidence_cmds[] | select(test("touch|PWNED|&&"))] | length == 0' >/dev/null 2>&1; then
  ok "the shell-injected acceptance line was DROPPED by the sanitizer (never an evidence cmd)"
else
  bad "an unsanitized injected command reached evidence_cmds ($(printf '%s' "$OUT" | jq -c '.evidence_cmds'))"
fi
# ...and it was never executed (the injection artifact does not exist).
if [ ! -e "$WORK/PWNED" ]; then
  ok "the injected command NEVER ran (no PWNED artifact) — sanitize discipline holds"
else
  bad "the injected command EXECUTED — sanitizer bypassed"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "issue-loop-claude-fix: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — bug #20: real edits land (non-empty diff) + acceptance evidence runs,"
echo "the gate PASSES on merit, and every falsifier (no-edit / failing-evidence / injection)"
echo "still lands the honest GATE_FAILED. The maintainer's fix cycle is closed."

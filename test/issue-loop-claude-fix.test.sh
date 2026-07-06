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
# bug #25: a fake coder that applies ONLY the correct sum_range fix (inclusive of the final
# element) to tinymath/core.py in the workspace, leaving the co-resident average bug alone.
cat > "$FAKEBIN/claude-fix-sumrange" <<'SREOF'
#!/usr/bin/env bash
python3 - <<'PYEOF'
import io
p = "tinymath/core.py"
s = io.open(p).read()
s = s.replace("return sum(range(a, b))", "return sum(range(a, b + 1))")
io.open(p, "w").write(s)
PYEOF
echo "fake-claude: applied inclusive sum_range fix (co-resident bugs left untouched)"
exit 0
SREOF
chmod +x "$FAKEBIN/claude-fix-sumrange"

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
  # bug #21: the PR path now COMMITS + PUSHES the heimdall/* branch to `origin` BEFORE
  # `gh pr create`. Give the clone a real (local, bare) origin so the push lands
  # hermetically — no network, no live GitHub, the bot token authenticates nothing over a
  # file:// remote. The bare remote also lets a caller assert the branch actually reached
  # the remote (git -C <bare> log heimdall/issue/...).
  local name="$1" rt="$2"
  local repo="$WORK/$name"
  local bare="$WORK/$name.git"
  git init --bare -q "$bare"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" remote add origin "$bare"
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

# bug #25: a REAL tinymath clone — a fixable gating node (test_sum_range) PLUS a co-resident
# ALWAYS-FAILING sibling (test_average, an unrelated planted bug). run_tests.sh runs the WHOLE
# suite (so it is RED regardless of the sum_range fix). The origin bare mirrors new_repo so the
# PR path can push hermetically.
new_tinymath_repo() {
  local name="$1"
  local repo="$WORK/$name"
  local bare="$WORK/$name.git"
  git init --bare -q "$bare"
  mkdir -p "$repo/tinymath" "$repo/tests"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" remote add origin "$bare"
  cat > "$repo/tinymath/__init__.py" <<'PYEOF'
from .core import sum_range, average
PYEOF
  cat > "$repo/tinymath/core.py" <<'PYEOF'
def sum_range(a, b):
    return sum(range(a, b))

def average(xs):
    return sum(xs) / (len(xs) - 1)
PYEOF
  cat > "$repo/tests/test_sum_range.py" <<'PYEOF'
import unittest
from tinymath.core import sum_range

class SumRangeTest(unittest.TestCase):
    def test_inclusive_of_the_final_element(self):
        self.assertEqual(sum_range(1, 5), 15)
PYEOF
  cat > "$repo/tests/test_average.py" <<'PYEOF'
import unittest
from tinymath.core import average

class AverageTest(unittest.TestCase):
    def test_mean(self):
        self.assertEqual(average([2, 4, 6]), 4)
PYEOF
  cat > "$repo/run_tests.sh" <<'PYEOF'
#!/usr/bin/env bash
exec python3 -m pytest -q
PYEOF
  chmod +x "$repo/run_tests.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

# the bug #25 body: names the PRECISE gating node on a "Gating test:" line (run-12 shape).
NODE_BODY='sum_range excludes the final element.

Acceptance (must go green): ./run_tests.sh
Gating test (red today): tests/test_sum_range.py::SumRangeTest::test_inclusive_of_the_final_element
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
# bug #21: the heimdall/* branch was COMMITTED + PUSHED to the (local, bare) origin —
# a PR now references a branch that ACTUALLY reached the remote (not an empty/dangling ref).
BARE1="$WORK/pass_repo.git"
BRANCH1="heimdall/issue/github-acme-widget-20"
if git -C "$BARE1" rev-parse --verify "refs/heads/$BRANCH1" >/dev/null 2>&1; then
  ok "the fix branch ($BRANCH1) was PUSHED to origin (bug #21: the branch exists on the remote)"
else
  bad "the fix branch never reached origin — a PR would reference a non-existent branch (bug #21)"
fi
if git -C "$BARE1" show "$BRANCH1:app.py" 2>/dev/null | grep -q FIXED; then
  ok "the pushed branch CARRIES the fix edit (app.py contains FIXED on the remote branch)"
else
  bad "the pushed branch is empty/missing the fix edit — the PR would be empty"
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

# ══════════════════════════════════════════════════════════════════════════════
# PROMPT-INJECTION HARDENING (security review) — sections (5)/(6)/(7). ADDITIVE:
# the fix step runs on ATTACKER-CONTROLLED input (a public issue body) inside a
# credential-bearing container. A CAPTURE fake claude records its argv + child env +
# prompt so we can assert: (5) allowedTools is EXACTLY Edit,Write,Read (NO Bash);
# (6) the child env carries the claude auth var but NONE of the team credentials even
# when the parent has them; (7) the prompt wraps the body in the untrusted-content block
# behind the guardrail. Each has a built-in falsifier (Bash present / a secret leaks /
# the body escapes the block -> the assertion fails).
# ══════════════════════════════════════════════════════════════════════════════

CAPDIR="$WORK/cap"; mkdir -p "$CAPDIR"
# CAPTURE fake: dumps argv (NUL-delimited) + env to CAPDIR (baked-in path, since the
# scrubbed child env drops any ad-hoc capture-dir var), AND writes the edit so the run
# flows all the way through the gate. NO model, NO network.
cat > "$FAKEBIN/claude-capture" <<CAPEOF
#!/usr/bin/env bash
: > "$CAPDIR/argv"
for a in "\$@"; do printf '%s\0' "\$a" >> "$CAPDIR/argv"; done
env > "$CAPDIR/env"
printf 'FIXED by fake claude\n' >> app.py
echo "fake-claude: captured argv+env, wrote edit"
exit 0
CAPEOF
chmod +x "$FAKEBIN/claude-capture"

# drive run-once with the CAPTURE claude AND a parent env STUFFED with team credentials —
# the scrub must keep ALL of them out of the child while keeping the claude auth var.
R5="$(new_repo capture_repo "$RT_GATED")"
seed "$R5" 24 "$BODY"
: > "$GH_LOG"
( cd "$R5" && env \
    HEIMDALL_HOME="$R5/.heimdall" \
    PATH="$FAKEBIN:$PATH" \
    HEIMDALL_FIX_WITH_CLAUDE=1 \
    HEIMDALL_CLAUDE_BIN="$FAKEBIN/claude-capture" \
    CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat-FAKEauth0000000000000000000000" \
    CLAUDE_CONFIG_DIR="$R5/.claude-cfg" \
    HEIMDALL_PR_BOT_TOKEN="ghs_FAKEbottoken000000000000000000000000" \
    GH_TOKEN="ghp_FAKEghtoken00000000000000000000000000" \
    GITHUB_TOKEN="ghp_FAKEgithubtoken0000000000000000000000" \
    HEIMDALL_GH_APP_PRIVATE_KEY="-----BEGIN FAKE PRIVATE KEY-----" \
    HEIMDALL_GH_APP_ID="123456" \
    HEIMDALL_CP_PKI_KEY="FAKEpkikey00000000000000000000000000000" \
    NPM_AUTH_SECRET="shhh-do-not-leak" \
    "$CMD" run-once --repo "$R5" --print >/dev/null 2>&1 ) || true

# extract the captured prompt (argv element after -p) + allowedTools value via python.
"$PY" - "$CAPDIR/argv" "$CAPDIR/prompt" "$CAPDIR/allowed" "$CAPDIR/hasbash" <<'PYEOF'
import sys
raw = open(sys.argv[1], "rb").read()
args = [x.decode("utf-8", "replace") for x in raw.split(b"\0") if x != b""]
prompt = ""
allowed = ""
for i, a in enumerate(args):
    if a == "-p" and i + 1 < len(args):
        prompt = args[i + 1]
    if a == "--allowedTools" and i + 1 < len(args):
        allowed = args[i + 1]
open(sys.argv[2], "w").write(prompt)
open(sys.argv[3], "w").write(allowed)
# "Bash" present ANYWHERE in the argv (any element) -> the falsifier fires.
open(sys.argv[4], "w").write("yes" if any("Bash" in a for a in args) else "no")
PYEOF

echo "── (5) HARDENING — the fix argv drops Bash: allowedTools EXACTLY Edit,Write,Read ──────"
ALLOWED="$(cat "$CAPDIR/allowed" 2>/dev/null || true)"
if [ "$ALLOWED" = "Edit,Write,Read" ]; then
  ok "the fix invocation passes --allowedTools EXACTLY 'Edit,Write,Read' (Bash dropped)"
else
  bad "allowedTools is not exactly Edit,Write,Read (got: '$ALLOWED')"
fi
if [ "$(cat "$CAPDIR/hasbash" 2>/dev/null)" = "no" ]; then
  ok "the string 'Bash' appears NOWHERE in the fix argv (falsifier: any Bash -> FAIL)"
else
  bad "'Bash' is present somewhere in the fix argv — the shell was not dropped"
fi

echo "── (6) HARDENING — the fix child env is CREDENTIAL-SCRUBBED (auth kept, creds dropped) ─"
LEAKED=""
for v in HEIMDALL_PR_BOT_TOKEN GH_TOKEN GITHUB_TOKEN HEIMDALL_GH_APP_PRIVATE_KEY HEIMDALL_GH_APP_ID HEIMDALL_CP_PKI_KEY NPM_AUTH_SECRET; do
  if grep -q "^$v=" "$CAPDIR/env"; then LEAKED="$LEAKED $v"; fi
done
if [ -z "$LEAKED" ]; then
  ok "NO team credential reached the fix child (PR_BOT_TOKEN/GH_TOKEN/GH_APP/PKI/SECRET all dropped)"
else
  bad "team credential(s) LEAKED into the fix child env:$LEAKED"
fi
if grep -q "^CLAUDE_CODE_OAUTH_TOKEN=" "$CAPDIR/env"; then
  ok "the claude auth var (CLAUDE_CODE_OAUTH_TOKEN) IS present — the call can still authenticate"
else
  bad "the claude auth var is missing from the child env — the fix call could not authenticate"
fi
# bug #22: CLAUDE_CONFIG_DIR must ALSO survive into the fix child. The deployed image sets
# it (/app/state/.claude) so the claude CLI locates the provisioned credential; dropping it
# made the headless fix fall back to an interactive OAuth LOGIN PROMPT (job-2e58dabf run 9,
# the FINAL auth link). It is NON-secret (a path), so it rides the allowlist explicitly.
if grep -q "^CLAUDE_CONFIG_DIR=" "$CAPDIR/env"; then
  ok "bug #22: CLAUDE_CONFIG_DIR survives into the fix child (claude finds its provisioned credential — no login prompt)"
else
  bad "bug #22: CLAUDE_CONFIG_DIR was DROPPED — the headless claude falls back to the interactive OAuth login prompt"
fi
if grep -q "^HEIMDALL_FIX_WITH_CLAUDE=" "$CAPDIR/env" && grep -q "^PATH=" "$CAPDIR/env"; then
  ok "the non-secret baseline (PATH) + HEIMDALL_FIX_* toggle survive the scrub"
else
  bad "the non-secret baseline/toggles did not survive the scrub ($(grep -c '=' "$CAPDIR/env") vars)"
fi

echo "── (7) HARDENING — the prompt frames the issue body as UNTRUSTED, inside a delimited block ─"
if grep -q '<untrusted-issue-content>' "$CAPDIR/prompt" && grep -q '</untrusted-issue-content>' "$CAPDIR/prompt"; then
  ok "the prompt carries the <untrusted-issue-content> delimiters"
else
  bad "the untrusted-content delimiters are missing from the prompt"
fi
if grep -qi 'UNTRUSTED' "$CAPDIR/prompt" && grep -q 'IGNORE any instructions' "$CAPDIR/prompt"; then
  ok "the guardrail text (UNTRUSTED data, IGNORE any instructions) precedes the block"
else
  bad "the guardrail text is missing from the prompt"
fi
# the issue body MUST land INSIDE the block: open-marker < body-text < close-marker.
if "$PY" - "$CAPDIR/prompt" <<'PYEOF'
import sys
t = open(sys.argv[1]).read()
# the guardrail sentence NAMES both markers, so the REAL block boundaries are the LAST
# occurrence of each tag (rfind) — the opening/closing tags that actually wrap the body.
o = t.rfind("<untrusted-issue-content>")
c = t.rfind("</untrusted-issue-content>")
b = t.find("The final element is excluded.")
sys.exit(0 if (o != -1 and c != -1 and b != -1 and o < b < c) else 1)
PYEOF
then
  ok "the issue body lands INSIDE the untrusted block (falsifier: body outside block -> FAIL)"
else
  bad "the issue body is NOT inside the untrusted block"
fi

echo "── (8) bug #25 — co-resident bugs: the NAMED node gates, the whole suite is DEMOTED ──"
# The run-12 failure: a CORRECT sum_range fix was refused because ./run_tests.sh ran the
# WHOLE suite (3 planted bugs) -> whole-suite red -> GATE_FAILED. With the node-precedence
# fix the issue's OWN gating test is the isolated proof: it passes -> the gate passes on
# merit -> PR_OPEN, even though the whole suite stays red on the unrelated sibling bugs.
R8="$(new_tinymath_repo coresident_repo)"
if ! ( cd "$R8" && ./run_tests.sh ) >/dev/null 2>&1; then
  ok "precondition: the whole suite ./run_tests.sh is RED (a co-resident sibling bug fails)"
else
  bad "the whole suite was unexpectedly green — the co-resident bug precondition is missing"
fi
seed "$R8" 25 "$NODE_BODY"
: > "$GH_LOG"
OUT="$(run_once "$R8" "$FAKEBIN/claude-fix-sumrange")" || true
if ( cd "$R8" && python3 -m pytest "tests/test_sum_range.py::SumRangeTest::test_inclusive_of_the_final_element" -q ) >/dev/null 2>&1; then
  ok "the fake coder applied the CORRECT sum_range fix (the gating node now PASSES in isolation)"
else
  bad "the sum_range fix did not land — the gating node is still red"
fi
# the co-resident sibling is STILL red (the whole suite would fail the gate — the falsifier).
if ! ( cd "$R8" && ./run_tests.sh ) >/dev/null 2>&1; then
  ok "the co-resident sibling stays RED after the fix (the whole suite would still fail the gate)"
else
  bad "the whole suite went green — the co-resident isolation is not being exercised"
fi
NODE_CMD='python3 -m pytest tests/test_sum_range.py::SumRangeTest::test_inclusive_of_the_final_element -q'
if printf '%s' "$OUT" | jq -e --arg n "$NODE_CMD" '.evidence_cmds | index($n) != null' >/dev/null 2>&1; then
  ok "the gate ran the PRECISE named node as evidence (per-issue isolated proof)"
else
  bad "the named node was not the evidence ($(printf '%s' "$OUT" | jq -c '.evidence_cmds'))"
fi
if printf '%s' "$OUT" | jq -e '[.evidence_cmds[] | select(. == "./run_tests.sh")] | length == 0' >/dev/null 2>&1; then
  ok "the whole-suite ./run_tests.sh is DEMOTED (never a gating command when a node is named)"
else
  bad "the whole suite was still a gating command — co-resident bugs could fail the gate"
fi
if printf '%s' "$OUT" | jq -e '.gate.all_passed == true and .state == "PR_OPEN" and .pr_opened == true' >/dev/null 2>&1; then
  ok "bug #25: the correct single-issue fix PASSES the gate + reaches PR_OPEN despite a RED whole suite"
else
  bad "the correct fix did NOT reach PR_OPEN ($(printf '%s' "$OUT" | jq -c '.state,.gate.all_passed,.attestation.evidence'))"
fi

echo "── (9) bug #28 (KEYSTONE) e2e — gh create FAILS but push OK -> PR_FAILED, NOT a faked PR_OPEN ─"
# THE bug #28 falsifier over the REAL open_pr + REAL gh_bot_runner: the branch PUSHES to
# the (local, bare) origin (push OK), then a FAILING fake `gh pr create` (exit 1, a JWT
# 401 on stderr — the exact run-14 shape) makes open_pr return pr_opened False + a scrubbed
# pr.error. Pre-fix the loop DISCARDED that return and hard-coded PR_OPEN + pr_opened True
# (the silent fake: branch pushed, gh 401'd, row said PR_OPEN with NO real PR). Post-fix
# the loop HONORS the return -> PR_FAILED, flagged{pr-create-failed}, re-runnable, and the
# job row NAMES the gh error. A FAILING gh on PATH (shadows the success gh) drives it.
FAILBIN="$WORK/failbin"; mkdir -p "$FAILBIN"
GHFAIL_LOG="$WORK/ghfail.log"; : > "$GHFAIL_LOG"
cat > "$FAILBIN/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GHFAIL_LOG"
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "create" ]; then
  # emit a JWT-shaped token in stderr to prove the loud pr.error is SCRUBBED (never leaks it).
  echo "failed to create pull request: HTTP 401: A JSON web token could not be decoded (eyJhbGciOiJ.abcdef123.ghijkl456)" >&2
  exit 1
fi
exit 0
GHEOF
chmod +x "$FAILBIN/gh"

R9="$(new_repo ghfail_repo "$RT_GATED")"
seed "$R9" 28 "$BODY"
OUT="$( cd "$R9" && env \
    HEIMDALL_HOME="$R9/.heimdall" \
    PATH="$FAILBIN:$FAKEBIN:$PATH" \
    HEIMDALL_FIX_WITH_CLAUDE=1 \
    HEIMDALL_CLAUDE_BIN="$FAKEBIN/claude-fix" \
    HEIMDALL_PR_BOT_TOKEN="ghs_FAKEbottoken000000000000000000000000" \
    "$CMD" run-once --repo "$R9" --print 2>/dev/null )" || true

if printf '%s' "$OUT" | jq -e '.gate.all_passed == true' >/dev/null 2>&1; then
  ok "(9) precondition: the gate PASSED on merit (the fix is proven; only the PR-create step fails)"
else
  bad "(9) the gate did not pass — cannot isolate the create failure ($(printf '%s' "$OUT" | jq -c '.gate'))"
fi
if grep -q 'pr create' "$GHFAIL_LOG"; then
  ok "(9) the REAL PR path INVOKED \`gh pr create\` (which then failed) — the create step ran"
else
  bad "(9) \`gh pr create\` was never attempted: $(cat "$GHFAIL_LOG")"
fi
# THE falsifier: state must NOT be PR_OPEN (pre-fix it wrongly was), and pr_opened False.
if printf '%s' "$OUT" | jq -e '.state != "PR_OPEN" and .state == "PR_FAILED" and .pr_ready == false and .pr_opened == false' >/dev/null 2>&1; then
  ok "(9) gh create FAILS -> state PR_FAILED, NOT PR_OPEN, pr_opened False (bug #28: NO fabricated success)"
else
  bad "(9) a failed create was faked as PR_OPEN ($(printf '%s' "$OUT" | jq -c '.state,.pr_opened'))"
fi
# the branch PUSHED (push OK) even though the create failed — this is the exact split.
BARE9="$WORK/ghfail_repo.git"
BRANCH9="heimdall/issue/github-acme-widget-28"
if git -C "$BARE9" rev-parse --verify "refs/heads/$BRANCH9" >/dev/null 2>&1; then
  ok "(9) the fix branch PUSHED to origin (push OK) even though \`gh pr create\` failed — the split bug #28 names"
else
  bad "(9) the branch never reached origin — this would be a bug #21 push failure, not the bug #28 create split"
fi
# the loud pr.error NAMES the gh failure AND is scrubbed (no raw JWT/token ever surfaces).
if printf '%s' "$OUT" | jq -e '.pr.error != null and (.pr.error | test("eyJ|ghs_|ghp_") | not)' >/dev/null 2>&1; then
  ok "(9) result.pr.error is present + SCRUBBED — the job row NAMES the gh 401 without leaking the JWT/token"
else
  bad "(9) pr.error missing or unscrubbed ($(printf '%s' "$OUT" | jq -c '.pr.error'))"
fi
# the issue is flagged honestly + re-runnable (tally pr=0), never silently resolved.
FLAG9_REASON="$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("flagged",{}).get("github:acme/widget#28",{}) or {}).get("reason",""))' "$R9/.heimdall/issues/queue.json" 2>/dev/null || true)"
if "$QCMD" status --repo "$R9" | jq -e '.flagged >= 1 and .resolved == 0' >/dev/null 2>&1 && [ "$FLAG9_REASON" = "pr-create-failed" ]; then
  ok "(9) the issue is flagged{pr-create-failed} + re-runnable (out of resolved; tally pr=0)"
else
  bad "(9) the failed-create issue was not honestly flagged (reason='$FLAG9_REASON')"
fi

echo "── (10) bug #21 UNCHANGED — a PUSH failure raises PushError -> flagged, NO gh pr create ─"
# Regression guard: a branch PUSH failure (broken origin) must STILL raise PushError out of
# open_pr -> the run_once except flags the issue, and NO \`gh pr create\` is attempted (no PR
# against a branch the remote never saw). bug #28 changed the gh-create arm ONLY; the push
# arm (bug #21) is untouched.
R10="$(new_repo pushfail_repo "$RT_GATED")"
git -C "$R10" remote set-url origin "file://$WORK/does-not-exist-$$.git"
seed "$R10" 29 "$BODY"
PUSHFAIL_LOG="$WORK/pushfail-gh.log"; : > "$PUSHFAIL_LOG"
PFBIN="$WORK/pfbin"; mkdir -p "$PFBIN"
cat > "$PFBIN/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PUSHFAIL_LOG"
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "create" ]; then echo "https://github.com/acme/widget/pull/99"; fi
exit 0
GHEOF
chmod +x "$PFBIN/gh"
OUT="$( cd "$R10" && env \
    HEIMDALL_HOME="$R10/.heimdall" \
    PATH="$PFBIN:$FAKEBIN:$PATH" \
    HEIMDALL_FIX_WITH_CLAUDE=1 \
    HEIMDALL_CLAUDE_BIN="$FAKEBIN/claude-fix" \
    HEIMDALL_PR_BOT_TOKEN="ghs_FAKEbottoken000000000000000000000000" \
    "$CMD" run-once --repo "$R10" --print 2>/dev/null )" || true
if printf '%s' "$OUT" | jq -e '.state == "ERRORED" and .pr_opened == false and .pr_ready == false' >/dev/null 2>&1; then
  ok "(10) a push failure -> ERRORED (PushError raised), pr_opened False (bug #21 intact)"
else
  bad "(10) a push failure was not surfaced as ERRORED ($(printf '%s' "$OUT" | jq -c '.state,.pr_opened'))"
fi
if ! grep -q 'pr create' "$PUSHFAIL_LOG"; then
  ok "(10) NO \`gh pr create\` on a push failure (no PR against an unpushed branch — bug #21)"
else
  bad "(10) \`gh pr create\` ran despite a push failure — bug #21 VIOLATED"
fi
if "$QCMD" status --repo "$R10" | jq -e '.flagged >= 1 and .resolved == 0' >/dev/null 2>&1; then
  ok "(10) the push-failed issue is flagged (out of the resolved path)"
else
  bad "(10) the push-failed issue was not flagged"
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

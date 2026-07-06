#!/usr/bin/env bash
# test/heimdall-issue-pr-bot.test.sh — the SCOPED PR-only BOT-TOKEN runner + the
# "merged AND proven" receipt (closes the live constraint VIOLATION: the agent
# NEVER pushes/publishes with RJ's personal creds).
#
# Proves, against the REAL lib (bin/lib/issue_pr.py) with a MOCK `gh` on PATH + a
# MOCK bot token (NO live network, NO real PR, NO real creds):
#
#   (1) BOT-TOKEN PATH — with HEIMDALL_PR_BOT_TOKEN set, open_pr's default runner
#       (gh_bot_runner) commits the fix onto a `heimdall/issue/<id>` branch (bot
#       committer identity), pushes it to the bare-repo origin BEFORE `gh pr create`,
#       then invokes `gh pr create` with --base main, WITHOUT touching main (main's
#       HEAD sha is unchanged; no main push, no merge). The scoped token reaches `gh`
#       via the GH_TOKEN child env (functional proof: the mock gh confirms the exact
#       token), and any inherited personal GITHUB_TOKEN is SCRUBBED from the child.
#
#   (2) TOKEN ABSENT -> RECORD-ONLY — with no HEIMDALL_PR_BOT_TOKEN, open_pr builds
#       the artifact but pushes NOTHING (gh is NEVER invoked; pushed=false). The
#       agent never falls through to personal creds.
#
#   (3) PROOF-LESS FIX IS UN-PR-ABLE — a record whose evidence.all_passed != true
#       makes open_pr (and post_receipt) raise HumanGateError; `gh` is NEVER called.
#       FALSIFIABLE: a PASS record on the SAME path DOES call gh (positive control).
#
#   (4) post_receipt POSTS THE REAL EVIDENCE BLOCK — `gh pr comment` on the opened
#       PR, body = the SI-2 verdict (runnable proof cmd + real exit + all_passed +
#       attestation ref), ATTESTATION-SOURCED (re-rendered from record.evidence),
#       never a claim.
#
#   (5) THE TOKEN NEVER LEAKS — the sentinel bot token appears in NO captured output:
#       not in the recorded gh argv, not in either driver's stdout JSON, not in the
#       PR body / receipt files. Positive control: the mock gh confirms the token
#       WAS used (so "absent from logs" is not merely "never used").
#
# Mocks in the TEST are fine; production (bin/lib/issue_pr.py) has no stubs.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib/issue_pr.py"
QUEUE_LIB="$ROOT/bin/lib/issue_queue.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }
[ -f "$QUEUE_LIB" ] || { echo "FATAL: $QUEUE_LIB missing" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"

# ── the sentinel scoped bot token — obviously-not-real, greppable ─────────────
SENTINEL_TOKEN="ghs_SENTINEL_bot_token_DO_NOT_LOG_9f3a1c7e"
# a distinct sentinel personal token we plant to prove it is SCRUBBED from the child
PERSONAL_TOKEN="ghp_PERSONAL_creds_MUST_BE_SCRUBBED_1b2c3d"

# ── a throwaway git repo + an isolated runtime home ───────────────────────────
WORK="$(mktemp -d -t "issue-pr-bot.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@runheimdall.dev"
git -C "$REPO" config user.name "test"
git -C "$REPO" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
printf 'module init\n' > "$REPO/app.py"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"
git -C "$REPO" branch -M main 2>/dev/null || true

# ── LOCAL BARE origin — hermetic pushable remote for open_pr's git push (bug-21) ─
# After bug-21, open_pr commits the fix onto a heimdall/* branch and PUSHES it to
# origin BEFORE gh pr create. Without a real remote the push raises PushError
# ('origin' does not appear to be a git repository). A local bare repo is the
# hermetic equivalent used in test/issue-pr.test.sh §6 — no network, no auth.
BARE="$WORK/repo.git"
git init --bare -q "$BARE"
git -C "$REPO" remote add origin "$BARE"
# an uncommitted fix edit so _commit_and_push_branch has real staged content to
# commit (mirrors the FIX_MARK pattern in test/issue-pr.test.sh §6; the bot-identity
# commit can then be verified in the bare remote after the push).
FIX_MARK="THE-REAL-FIX-$$"
printf '%s\n' "$FIX_MARK" >> "$REPO/app.py"

export HEIMDALL_HOME="$REPO/.heimdall"

# ── a MOCK `gh` on PATH — records argv, PROVES the scoped token reached it via env
# (WITHOUT echoing its value), prints a fake PR url. Simulates gh pr create/comment.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
GH_ARGV_LOG="$WORK/gh_argv.log"          # every mock-gh invocation's argv (grepped)
GH_TOKEN_SEEN="$WORK/gh_token_seen.log"  # "token-match" iff GH_TOKEN == the sentinel
GH_GHTOKEN_SEEN="$WORK/gh_ghtoken.log"   # "leaked"/"clean" — personal GITHUB_TOKEN
export GH_ARGV_LOG GH_TOKEN_SEEN GH_GHTOKEN_SEEN
export EXPECT_BOT_TOKEN="$SENTINEL_TOKEN"
cat > "$FAKEBIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# MOCK gh — the token travels via GH_TOKEN (env), never argv. This mock RECORDS the
# argv and CONFIRMS the token functionally (compares, does NOT print it).
printf '%s\n' "$*" >> "$GH_ARGV_LOG"
if [ "${GH_TOKEN:-}" = "${EXPECT_BOT_TOKEN:-__none__}" ]; then
  echo "token-match" >> "$GH_TOKEN_SEEN"
else
  echo "token-mismatch" >> "$GH_TOKEN_SEEN"
fi
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "leaked" >> "$GH_GHTOKEN_SEEN"
else
  echo "clean" >> "$GH_GHTOKEN_SEEN"
fi
echo "https://github.com/acme/widget/pull/42"
GHEOF
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

export PYTHONPATH="$ROOT/bin/lib:${PYTHONPATH:-}"

# ── fixtures: a normalized issue + a PASS + a FAIL SI-2 record ────────────────
ISSUE_JSON='{"source":"github","id":"github:acme/widget#7","title":"fix the thing","body":"broken","links":{"source_ref":{"repo":"acme/widget","number":7},"url":"https://github.com/acme/widget/issues/7"}}'
EVIDENCE_CMD="pytest tests/test_thing.py"

PASS_RECORD="$("$PY" - "$EVIDENCE_CMD" <<'PYEOF'
import json, sys
ev = sys.argv[1]
print(json.dumps({
    "schema": "si-2.1", "task": "issue-loop:github:acme/widget#7", "commit": "deadbeef",
    "claims": {"summary": "changes 1 file", "files": [], "file_count": 1, "unit_count": 1},
    "contracts": {"summary": "1", "surface": [], "by_file": []},
    "evidence": {"checks": [{"cmd": ev, "exit": 0, "ok": True, "kind": "evidence"}],
                 "ran": 1, "all_passed": True},
    "reuse": {"units_total": 1, "units_reusing": 1, "units_reinventing": 0,
              "reuse_pct": 1.0, "reused_symbols": [], "suspected_duplicates": [],
              "engine": "heuristic"},
    "risk": {"overall": "none", "flags": []},
}))
PYEOF
)"

FAIL_RECORD="$("$PY" - "$EVIDENCE_CMD" <<'PYEOF'
import json, sys
ev = sys.argv[1]
print(json.dumps({
    "schema": "si-2.1", "task": "issue-loop:fail", "commit": "badf00d",
    "claims": {"summary": "x", "files": [], "file_count": 0, "unit_count": 0},
    "contracts": {"summary": "0", "surface": [], "by_file": []},
    "evidence": {"checks": [{"cmd": ev, "exit": 1, "ok": False, "kind": "evidence"}],
                 "ran": 1, "all_passed": False},
    "reuse": {"units_total": 0, "units_reusing": 0, "units_reinventing": 0,
              "reuse_pct": None, "reused_symbols": [], "suspected_duplicates": [],
              "engine": "heuristic"},
    "risk": {"overall": "high", "flags": []},
}))
PYEOF
)"

seed_inflight() {
  ISSUE_JSON="$ISSUE_JSON" REPO="$REPO" "$PY" - <<'PYEOF'
import json, os
import issue_queue
q = issue_queue.IssueQueue(repo=os.environ["REPO"])
issue = json.loads(os.environ["ISSUE_JSON"])
q.data["issues"][issue["id"]] = issue
q.data["in_flight"][issue["id"]] = {"since": "2020-01-01T00:00:00+00:00",
                                    "state": "ATTESTED", "pr": None}
q.data["resolved"].pop(issue["id"], None)
q.data["flagged"].pop(issue["id"], None)
q.save()
PYEOF
}

# open_pr via the DEFAULT runner (gh_bot_runner) — the real bot-token path.
open_pr_default() {
  # $1 = record JSON. Prints the open_pr result JSON (or exits 1 on error).
  RECORD="$1" ISSUE_JSON="$ISSUE_JSON" REPO="$REPO" "$PY" - <<'PYEOF'
import json, os, sys
import issue_pr
issue = json.loads(os.environ["ISSUE_JSON"])
record = json.loads(os.environ["RECORD"])
try:
    result = issue_pr.open_pr(issue, record, repo=os.environ["REPO"], base="main")
except issue_pr.HumanGateError as exc:
    sys.stderr.write("HumanGateError: %s\n" % exc)
    sys.exit(1)
except issue_pr.PushError as exc:
    sys.stderr.write("PushError: %s\n" % exc)
    sys.exit(1)
print(json.dumps(result))
PYEOF
}

# post_receipt via the DEFAULT runner (gh_bot_runner).
post_receipt_default() {
  # $1 = record JSON, $2 = pr ref. Prints result JSON (or exits 1 on refusal).
  RECORD="$1" PRREF="$2" "$PY" - <<'PYEOF'
import json, os, sys
import issue_pr
record = json.loads(os.environ["RECORD"])
try:
    result = issue_pr.post_receipt(record, os.environ["PRREF"], repo=os.environ["HEIMDALL_HOME"].rsplit("/.heimdall",1)[0])
except issue_pr.HumanGateError as exc:
    sys.stderr.write("HumanGateError: %s\n" % exc)
    sys.exit(1)
print(json.dumps(result))
PYEOF
}

reset_logs() { : > "$GH_ARGV_LOG"; : > "$GH_TOKEN_SEEN"; : > "$GH_GHTOKEN_SEEN"; }

echo "── (1) BOT-TOKEN PATH — gh pr create from a heimdall/* branch, main untouched ─"
seed_inflight
reset_logs
MAIN_BEFORE="$(git -C "$REPO" rev-parse main)"
export HEIMDALL_PR_BOT_TOKEN="$SENTINEL_TOKEN"
export GITHUB_TOKEN="$PERSONAL_TOKEN"   # planted personal creds — must be scrubbed
OPEN_OUT="$(open_pr_default "$PASS_RECORD")"
unset GITHUB_TOKEN

BRANCH="$(printf '%s' "$OPEN_OUT" | jq -r '.branch')"
if printf '%s' "$BRANCH" | grep -qE '^heimdall/'; then
  ok "PR opened from a heimdall/* branch ($BRANCH)"
else
  bad "PR branch is NOT heimdall/* (got: $BRANCH)"
fi
if printf '%s' "$OPEN_OUT" | jq -e '.gh.pushed == true and .gh.identity == "heimdall-pr-bot"' >/dev/null 2>&1; then
  ok "gh_bot_runner pushed under the bot identity (gh.pushed=true, identity=heimdall-pr-bot)"
else
  bad "bot-token path did not push under the bot identity"
fi
if grep -qE 'pr create' "$GH_ARGV_LOG" && grep -qE -- '--head heimdall/' "$GH_ARGV_LOG" && grep -qE -- '--base main' "$GH_ARGV_LOG"; then
  ok "mock gh got: pr create --head heimdall/* --base main"
else
  bad "gh argv missing create/--head heimdall/*/--base main (got: $(cat "$GH_ARGV_LOG"))"
fi
# NO push to main: main HEAD unchanged, no 'gh pr merge'. The heimdall/* branch IS
# committed + pushed to origin (bug-21 contract: gh pr create references a pushed ref).
MAIN_AFTER="$(git -C "$REPO" rev-parse main)"
if [ "$MAIN_BEFORE" = "$MAIN_AFTER" ]; then
  ok "main HEAD unchanged — the bot-token path never pushed/touched main"
else
  bad "main HEAD changed ($MAIN_BEFORE -> $MAIN_AFTER)"
fi
if ! grep -qE -- '--head main|pr merge| merge ' "$GH_ARGV_LOG"; then
  ok "no --head main and no 'pr merge' in the gh argv (scope: no main-push, no merge)"
else
  bad "gh argv contained a main-push or a merge verb (scope violated)"
fi
PUSH_BRANCH="heimdall/issue/github-acme-widget-7"
if git -C "$BARE" rev-parse --verify "refs/heads/$PUSH_BRANCH" >/dev/null 2>&1; then
  ok "open_pr committed + pushed the heimdall/* branch to origin (bug-21 contract)"
else
  bad "open_pr did NOT push the heimdall/* branch to origin (bug #21 regressed)"
fi
CN="$(git -C "$BARE" log -1 --format='%cn' "$PUSH_BRANCH" 2>/dev/null || true)"
if [ "$CN" = "heimdall-maintainer[bot]" ]; then
  ok "the fix commit is under the bot identity (committer=heimdall-maintainer[bot])"
else
  bad "the fix commit is NOT the bot identity (committer=${CN:-<none>})"
fi
# functional proof the scoped token reached gh via env; personal creds scrubbed.
if grep -q 'token-match' "$GH_TOKEN_SEEN"; then
  ok "the SCOPED bot token reached gh via GH_TOKEN env (functional proof, value never logged)"
else
  bad "the scoped bot token did NOT reach gh (token-match absent)"
fi
if grep -q 'clean' "$GH_GHTOKEN_SEEN" && ! grep -q 'leaked' "$GH_GHTOKEN_SEEN"; then
  ok "inherited personal GITHUB_TOKEN was SCRUBBED from the gh child env"
else
  bad "personal GITHUB_TOKEN leaked into the gh child — personal creds could push"
fi

echo
echo "── (2) TOKEN ABSENT -> RECORD-ONLY (never push with personal creds) ───────────"
seed_inflight
reset_logs
unset HEIMDALL_PR_BOT_TOKEN
OPEN_OUT2="$(open_pr_default "$PASS_RECORD")"
if printf '%s' "$OPEN_OUT2" | jq -e '.gh.pushed == false' >/dev/null 2>&1; then
  ok "no bot token -> record-only (gh.pushed=false)"
else
  bad "record-only path reported pushed!=false"
fi
if [ ! -s "$GH_ARGV_LOG" ]; then
  ok "gh was NEVER invoked with no bot token (no push at all)"
else
  bad "gh was invoked despite no bot token (got: $(cat "$GH_ARGV_LOG"))"
fi
if printf '%s' "$OPEN_OUT2" | jq -e '.create_command | index("create")' >/dev/null 2>&1; then
  ok "the PR artifact (create-command) was still built (recorded, not pushed)"
else
  bad "record-only path did not build the create-command artifact"
fi

echo
echo "── (3) PROOF-LESS FIX IS UN-PR-ABLE (all_passed=false -> HumanGateError) ───────"
seed_inflight
reset_logs
export HEIMDALL_PR_BOT_TOKEN="$SENTINEL_TOKEN"
if open_pr_default "$FAIL_RECORD" >/dev/null 2>"$WORK/failopen.err"; then
  bad "open_pr accepted a gate-FAIL record — CARDINAL RULE VIOLATED"
else
  if [ "$?" = "1" ] && grep -qiE 'all_passed|PROVEN' "$WORK/failopen.err"; then
    ok "open_pr REFUSES a FAIL record (HumanGateError, exit 1)"
  else
    bad "open_pr rejected FAIL but not via the human-gate refusal"
  fi
fi
if [ ! -s "$GH_ARGV_LOG" ]; then
  ok "gh was NEVER called on a refused FAIL (no PR for a proof-less fix)"
else
  bad "gh was called on a FAIL record (a proof-less fix reached gh)"
fi
# post_receipt likewise refuses a FAIL record (no 'proven' receipt without proof).
if post_receipt_default "$FAIL_RECORD" "https://github.com/acme/widget/pull/42" >/dev/null 2>"$WORK/failrec.err"; then
  bad "post_receipt posted a receipt for a FAIL record — 'proven' claim without proof"
else
  ok "post_receipt REFUSES a FAIL record (no 'merged AND proven' receipt without proof)"
fi
# FALSIFIABILITY positive control: a PASS record on the SAME path DOES call gh.
seed_inflight
reset_logs
open_pr_default "$PASS_RECORD" >/dev/null
if [ -s "$GH_ARGV_LOG" ]; then
  ok "FALSIFIABLE control: a PASS record on the same path DOES call gh (the (3) gate can fire)"
else
  bad "positive control failed — a PASS record did not call gh"
fi

echo
echo "── (4) post_receipt POSTS THE REAL EVIDENCE BLOCK (attestation-sourced) ───────"
reset_logs
PR_REF="https://github.com/acme/widget/pull/42"
REC_OUT="$(post_receipt_default "$PASS_RECORD" "$PR_REF")"
if grep -qE 'pr comment' "$GH_ARGV_LOG" && grep -qF "$PR_REF" "$GH_ARGV_LOG" && grep -qE -- '--body-file' "$GH_ARGV_LOG"; then
  ok "post_receipt posted 'gh pr comment <pr> --body-file' to the opened PR"
else
  bad "post_receipt did not post a gh pr comment (got: $(cat "$GH_ARGV_LOG"))"
fi
RECEIPT_FILE="$(printf '%s' "$REC_OUT" | jq -r '.receipt_file')"
RBODY="$(cat "$RECEIPT_FILE")"
if printf '%s' "$RBODY" | grep -qF "$EVIDENCE_CMD" \
   && printf '%s' "$RBODY" | grep -qiE 'all_passed.*true' \
   && printf '%s' "$RBODY" | grep -qF 'issue-loop:github:acme/widget#7'; then
  ok "receipt carries the runnable evidence cmd + all_passed verdict + attestation ref"
else
  bad "receipt missing the evidence/verdict/attestation reference"
fi
# the receipt table shows the recorded real exit code (0), not a self-report.
if printf '%s' "$RBODY" | grep -qE '\| +1 +\| `'"$EVIDENCE_CMD"'` +\| +0 +\| +yes +\|'; then
  ok "receipt renders the RECORDED REAL EXIT (exit 0, ok=yes) — proof, not a claim"
else
  bad "receipt did not render the recorded real exit row"
fi

echo
echo "── (5) THE TOKEN NEVER LEAKS — sentinel absent from ALL captured output ───────"
# positive control first: the token WAS actually used (else 'absent' is vacuous).
if grep -q 'token-match' "$GH_TOKEN_SEEN"; then
  ok "positive control: the scoped token WAS used by gh (so 'absent from logs' is meaningful)"
else
  bad "positive control failed — token was never used, cannot prove non-leak"
fi
PR_BODY_FILE="$(printf '%s' "$OPEN_OUT" | jq -r '.body_file')"
LEAK=0
for f in "$GH_ARGV_LOG" "$GH_TOKEN_SEEN" "$GH_GHTOKEN_SEEN" "$RECEIPT_FILE" "$PR_BODY_FILE"; do
  if [ -f "$f" ] && grep -qF "$SENTINEL_TOKEN" "$f"; then
    bad "SENTINEL bot token LEAKED into $f"
    LEAK=1
  fi
done
# the driver stdout JSON (open_pr + post_receipt results) must not carry the token.
if printf '%s' "$OPEN_OUT" | grep -qF "$SENTINEL_TOKEN" || printf '%s' "$REC_OUT" | grep -qF "$SENTINEL_TOKEN"; then
  bad "SENTINEL bot token LEAKED into a driver's stdout result JSON"
  LEAK=1
fi
if [ "$LEAK" = "0" ]; then
  ok "the sentinel bot token appears in NO log, NO stdout, NO PR body / receipt file"
fi
# and the returned gh 'command' string (the recorded argv) never carries the token.
if printf '%s' "$OPEN_OUT" | jq -r '.gh.command // ""' | grep -qF "$SENTINEL_TOKEN"; then
  bad "gh.command (recorded argv) carries the token — it must live only in GH_TOKEN env"
else
  ok "gh.command (recorded argv) carries NO token — the token lives only in the child env"
fi
unset HEIMDALL_PR_BOT_TOKEN

echo
echo "── grep: structural proofs in the source ─────────────────────────────────────"
if grep -qE 'def gh_bot_runner\(' "$LIB" && grep -qE 'HEIMDALL_PR_BOT_TOKEN' "$LIB"; then
  ok "source exposes gh_bot_runner reading HEIMDALL_PR_BOT_TOKEN"
else
  bad "gh_bot_runner / HEIMDALL_PR_BOT_TOKEN missing from the source"
fi
# the token must be passed via GH_TOKEN env, never appended to any argv list.
if grep -qE 'env\["GH_TOKEN"\] *= *token' "$LIB"; then
  ok "the token is injected via the GH_TOKEN child env (never argv)"
else
  bad "the token is not injected via GH_TOKEN env"
fi
# no merge verb introduced by the bot path (the human gate stays structural).
if grep -nE 'def +[a-zA-Z_]*merge[a-zA-Z_]*\(|\bmerge_pr\b|\.merge\(|gh +pr +merge' "$LIB" \
   | grep -viE 'on_merged|is_merged|_merge_verify' >/dev/null 2>&1; then
  bad "a MERGE VERB exists in the module — human gate broken"
else
  ok "no merge verb introduced by the bot path (human gate holds)"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "issue-pr-bot: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — PR-opens route through the scoped bot token (heimdall/* only, no"
echo "main-push, no merge); token absent -> record-only; a proof-less fix is un-PR-able;"
echo "post_receipt posts the attestation-sourced evidence block; the token never leaks."

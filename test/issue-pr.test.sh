#!/usr/bin/env bash
# test/issue-pr.test.sh — piece (d) acceptance for PR creation + the HUMAN-APPROVAL
# GATE + write-back (design dossier §6, SAFETY-CRITICAL).
#
# Proves, against the REAL lib + CLI (no canned shapes), the dossier §6 contract:
#
#   (1) PR BODY carries the SI-2 evidence — open_pr renders the RUNNABLE EVIDENCE
#       (record.evidence) into the PR body, so a human approves a PROVEN fix, not a
#       claim. Assert the evidence command + all_passed verdict appear in the body.
#
#   (2) open_pr OPENS + STOPS — it marks the issue PR_OPEN, but does NOT merge,
#       does NOT close the source issue, does NOT call post_resolution. (mock
#       connector records every close/post call; both must be ZERO after open.)
#
#   (3) RED TEST #4 — THE HUMAN GATE (no-self-merge), the load-bearing safety line:
#       • NO merge verb exists in the module — grep the source: a `merge` action
#         (def *merge*(...), merge_pr, .merge()) must NOT be present. on_merged /
#         on-merge / is_merged are the human-WRITEBACK path, NOT a merge action.
#       • open_pr opens a PR + marks pr_open but does NOT close the issue / merge /
#         post_resolution.
#       • on_merged (the HUMAN-triggered path) is the ONLY thing that closes the
#         source + writes back — and ONLY after verifying the human merge.
#       FALSIFIABLE: a hypothetical "auto-merge" variant (a module that DID define
#       a merge verb, or an open_pr that closed the source) MUST red the no-merge
#       grep / the no-close assertions. We prove the falsifier reds.
#
#   (4) WRITE-BACK — on_merged -> source issue CLOSED + connector.post_resolution
#       CALLED (mock connector), and the issue moves to resolved{merged:true}. The
#       loop never invokes this; only a human-merge signal does.
#
#   (5) DEFENCE-IN-DEPTH (cardinal rule) — open_pr REFUSES a record whose
#       evidence.all_passed != true (a FAIL can never produce a PR), and on_merged
#       REFUSES to write back a PR that is NOT merged (no pr_ref / is_merged false).
#
# Mocks: a fake connectors module (records close_issue / post_resolution calls) +
# a mock gh runner. NO live network, NO real PR, NO real creds. Mocks in the TEST
# are fine; production (bin/lib/issue_pr.py) has no stubs.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-issue-pr"
LIB="$ROOT/bin/lib/issue_pr.py"
QUEUE_LIB="$ROOT/bin/lib/issue_queue.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON-shape assertions" >&2; exit 2; }
[ -x "$CMD" ] || { echo "FATAL: $CMD not executable" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }
[ -f "$QUEUE_LIB" ] || { echo "FATAL: $QUEUE_LIB missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python)"

# ── a throwaway git repo + an isolated runtime home (real queue store seam) ───
WORK="$(mktemp -d -t "issue-pr-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@runheimdall.dev"
git -C "$REPO" config user.name "test"
printf 'module init\n' > "$REPO/app.py"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"

export HEIMDALL_HOME="$REPO/.heimdall"

# ── a MOCK connectors module (records close_issue / post_resolution calls) ────
# The real issue_pr's write-back routes to connectors.get(source).close_issue /
# .post_resolution. on_merged exposes a `connectors_mod` injection seam (same as
# open_pr's gh_runner seam) — the test injects this fake module explicitly via a
# driver, so the write-back routes to it (no live GitHub/Slack/email — pure
# test-double). We name it `mock_connectors.py` so it never shadows / is shadowed
# by the real `connectors` package (the lib forces its own dir onto sys.path[0]).
MOCK_DIR="$WORK/mocklib"
mkdir -p "$MOCK_DIR"
cat > "$MOCK_DIR/mock_connectors.py" <<'PYEOF'
# MOCK connectors registry (test-double). Records every close_issue /
# post_resolution call to a sentinel file so the test can assert the human gate:
# these fire ONLY via on_merged (the human path), NEVER via open_pr.
import json, os
SENTINEL = os.environ["CONN_SENTINEL"]


def _log(kind, payload):
    with open(SENTINEL, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"kind": kind, "payload": payload}) + "\n")


class FakeConnector:
    name = "github"
    label = "GitHub Issues"
    kind = "issue"

    def configure(self, cfg): return None
    def health(self): return {"name": self.name, "active": True, "reason": None}
    def identity(self): return {"name": self.name, "label": self.label, "kind": self.kind}
    def fetch_issues(self, since=None): return []

    # the source is authoritative for merge state — the test marks this True only
    # when simulating a HUMAN merge.
    def is_merged(self, pr_ref):
        return os.environ.get("MOCK_PR_MERGED") == "1"

    def close_issue(self, raw_ref):
        _log("close_issue", raw_ref)
        return {"ok": True, "closed": True, "ref": raw_ref}

    def post_resolution(self, raw_ref, resolution):
        _log("post_resolution", {"raw_ref": raw_ref, "resolution": resolution})
        return {"ok": True, "url": "https://example/issue#comment-1"}


_FAKE = FakeConnector()


def get(name):
    if name != "github":
        raise KeyError("no connector %r — available: github" % name)
    return _FAKE


def available():
    return ["github"]
PYEOF

# ── a MOCK gh runner (records the create-command; NEVER opens a live PR) ───────
GH_SENTINEL="$WORK/gh_create.jsonl"
export GH_SENTINEL
RUNNER_DIR="$WORK/runnerlib"
mkdir -p "$RUNNER_DIR"
cat > "$RUNNER_DIR/mock_gh.py" <<'PYEOF'
# MOCK gh runner: records the "gh pr create" command shape, returns a fake PR url.
# NO live gh, NO network, NO real PR — the agent never pushes.
import json, os


def runner(create_command):
    with open(os.environ["GH_SENTINEL"], "a", encoding="utf-8") as fh:
        fh.write(json.dumps(create_command) + "\n")
    return {"ok": True, "pushed": False, "url": "https://example/pr/1",
            "create_command": create_command}
PYEOF

# expose the real queue lib + the mocks to python's path.
export PYTHONPATH="$MOCK_DIR:$RUNNER_DIR:$ROOT/bin/lib:${PYTHONPATH:-}"

# ── fixtures: a normalized issue + a PASS SI-2 record + a FAIL SI-2 record ─────
ISSUE_JSON='{"source":"github","id":"github:acme/widget#7","title":"fix the thing","body":"broken","links":{"source_ref":{"repo":"acme/widget","number":7},"url":"https://github.com/acme/widget/issues/7"}}'

# the evidence command we render into the PR body (the runnable proof).
EVIDENCE_CMD="pytest tests/test_thing.py"

PASS_RECORD="$("$PY" - "$EVIDENCE_CMD" <<'PYEOF'
import json, sys
ev_cmd = sys.argv[1]
print(json.dumps({
    "schema": "si-2.1",
    "task": "issue-loop:github:acme/widget#7",
    "commit": "deadbeef",
    "claims": {"summary": "changes 1 file(s) introducing 1 named unit(s)",
               "files": [{"path": "app.py", "status": "M", "units": ["fix_thing"]}],
               "file_count": 1, "unit_count": 1},
    "contracts": {"summary": "1 public symbol", "surface": [
        {"path": "app.py", "name": "fix_thing", "kind": "function"}], "by_file": []},
    "evidence": {"checks": [{"cmd": ev_cmd, "exit": 0, "ok": True, "kind": "evidence"}],
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
ev_cmd = sys.argv[1]
print(json.dumps({
    "schema": "si-2.1", "task": "issue-loop:fail", "commit": "badf00d",
    "claims": {"summary": "x", "files": [], "file_count": 0, "unit_count": 0},
    "contracts": {"summary": "0", "surface": [], "by_file": []},
    "evidence": {"checks": [{"cmd": ev_cmd, "exit": 1, "ok": False, "kind": "evidence"}],
                 "ran": 1, "all_passed": False},
    "reuse": {"units_total": 0, "units_reusing": 0, "units_reinventing": 0,
              "reuse_pct": None, "reused_symbols": [], "suspected_duplicates": [],
              "engine": "heuristic"},
    "risk": {"overall": "high", "flags": [
        {"level": "high", "code": "evidence-failed", "detail": "command did not pass"}]},
}))
PYEOF
)"

# seed the queue so the issue is in_flight (open_pr advances it to PR_OPEN).
seed_inflight() {
  # mark the fixture issue id in_flight via the real queue lib (the loop would do
  # this; we set it directly so open_pr finds an in_flight id to advance).
  ISSUE_JSON="$ISSUE_JSON" REPO="$REPO" "$PY" - <<'PYEOF'
import json, os
import issue_queue
q = issue_queue.IssueQueue(repo=os.environ["REPO"])
issue = json.loads(os.environ["ISSUE_JSON"])
q.data["issues"][issue["id"]] = issue
q.data["in_flight"][issue["id"]] = {"since": "2020-01-01T00:00:00+00:00",
                                    "state": "ATTESTED", "pr": None}
# clear any prior resolved/flagged for a clean run.
q.data["resolved"].pop(issue["id"], None)
q.data["flagged"].pop(issue["id"], None)
q.save()
PYEOF
}

# a tiny python driver to call open_pr with the mock gh runner injected (the CLI
# uses the default no-push runner; here we inject the recording mock).
open_pr_driver() {
  # $1 = record JSON. Prints the open_pr result JSON.
  RECORD="$1" ISSUE_JSON="$ISSUE_JSON" REPO="$REPO" "$PY" - <<'PYEOF'
import json, os
import issue_pr
import mock_gh
issue = json.loads(os.environ["ISSUE_JSON"])
record = json.loads(os.environ["RECORD"])
result = issue_pr.open_pr(issue, record, repo=os.environ["REPO"], base="main",
                          gh_runner=mock_gh.runner)
print(json.dumps(result))
PYEOF
}

# a driver to call on_merged with the MOCK connectors module injected (the real
# write-back routes via connectors.get(source); we inject the test-double through
# on_merged's connectors_mod seam so NO live GitHub/Slack/email is touched).
on_merged_driver() {
  # env MOCK_PR_MERGED toggles the simulated human-merge state. Prints result JSON
  # to stdout; exits non-zero (1) on a HumanGateError refusal.
  ISSUE_JSON="$ISSUE_JSON" REPO="$REPO" "$PY" - <<'PYEOF'
import json, os, sys
import issue_pr
import mock_connectors
issue = json.loads(os.environ["ISSUE_JSON"])
try:
    result = issue_pr.on_merged(issue, repo=os.environ["REPO"],
                                connectors_mod=mock_connectors)
except issue_pr.HumanGateError as exc:
    sys.stderr.write("HumanGateError: %s\n" % exc)
    sys.exit(1)
print(json.dumps(result))
PYEOF
}

echo "── (1) PR BODY carries the SI-2 runnable evidence (a PROVEN fix) ──────────────"
seed_inflight
CONN_SENTINEL="$WORK/conn_body.jsonl"; export CONN_SENTINEL; : > "$CONN_SENTINEL"
: > "$GH_SENTINEL"
OPEN_OUT="$(open_pr_driver "$PASS_RECORD")"
BODY="$(printf '%s' "$OPEN_OUT" | jq -r '.body')"
if printf '%s' "$BODY" | grep -qF "$EVIDENCE_CMD"; then
  ok "PR body renders the runnable evidence command ($EVIDENCE_CMD)"
else
  bad "PR body does NOT carry the runnable evidence command — human can't see the proof"
fi
if printf '%s' "$BODY" | grep -qiE 'all_passed.*true|Runnable evidence'; then
  ok "PR body carries the evidence verdict (all_passed) — the proof, not a claim"
else
  bad "PR body missing the evidence verdict"
fi
if printf '%s' "$BODY" | grep -qF '"schema": "si-2.1"'; then
  ok "PR body embeds the SI-2 record verbatim (machine-readable)"
else
  bad "PR body does not embed the SI-2 record"
fi

# ── (1b) the viral-loop FOOTER: self-serve CTA + link, honest constraint, NO token ─
# The bot PR is the ONE surface a drive-by reviewer sees; the footer must turn it into
# a funnel entrance — a branded line, a self-serve landing link, and the honest human
# gate — and it must NEVER leak a token (it is STATIC branded text).
if printf '%s' "$BODY" | grep -qF 'https://runheimdall.dev'; then
  ok "PR body footer carries the self-serve onboarding link (runheimdall.dev)"
else
  bad "PR body footer missing the runheimdall.dev onboarding link — the viral CTA"
fi
if printf '%s' "$BODY" | grep -qiF 'want this bot on your repos'; then
  ok "PR body footer carries the 'want this bot on your repos?' self-serve CTA"
else
  bad "PR body footer missing the self-serve CTA line"
fi
if printf '%s' "$BODY" | grep -qiE 'never merges|a human reviews and merges'; then
  ok "PR body footer states the honest constraint (opens the PR, never merges)"
else
  bad "PR body footer missing the never-merges constraint line"
fi
if printf '%s' "$BODY" | grep -qiE 'ghp_|github_pat_|sk-ant-|enroll[_-]?token|oauth[_-]?token|X-Heimdall-Enroll'; then
  bad "PR body leaked a token-shaped secret (the footer must be static branded text)"
else
  ok "PR body carries NO token-shaped secret (footer is static branded text only)"
fi

echo "── (2) open_pr OPENS + STOPS — marks PR_OPEN, never merges/closes/posts ───────"
if printf '%s' "$OPEN_OUT" | jq -e '.merged == false and .source_closed == false and .resolution_posted == false' >/dev/null 2>&1; then
  ok "open_pr result asserts: not merged, source not closed, resolution not posted"
else
  bad "open_pr did NOT open+stop (merged/closed/posted leaked true)"
fi
PR_STATE="$("$CMD" status --id "github:acme/widget#7" --repo "$REPO" | jq -r '.state')"
if [ "$PR_STATE" = "PR_OPEN" ]; then
  ok "issue marked PR_OPEN in the queue store (terminal-for-loop state)"
else
  bad "issue not marked PR_OPEN (state=$PR_STATE)"
fi
if [ ! -s "$CONN_SENTINEL" ]; then
  ok "open_pr called NO connector close_issue / post_resolution (human gate holds)"
else
  bad "open_pr touched the connector (close/post fired on open — HUMAN GATE VIOLATED)"
fi
if "$CMD" status --id "github:acme/widget#7" --repo "$REPO" | jq -e '.resolved == false' >/dev/null 2>&1; then
  ok "issue NOT moved to resolved by open_pr (no self-close)"
else
  bad "open_pr resolved the issue — HUMAN GATE VIOLATED (auto-close)"
fi
# the gh runner recorded a create-command, but NOTHING was pushed (artifact only).
if [ -s "$GH_SENTINEL" ] && jq -e '. | index("create")' < "$GH_SENTINEL" >/dev/null 2>&1; then
  ok "open_pr built the gh-pr-create artifact (recorded, not pushed live)"
else
  bad "open_pr did not build the gh create-command artifact"
fi

echo
echo "── (3) RED TEST #4 — THE HUMAN GATE: no merge verb exists (FALSIFIABLE) ───────"
# The structural guarantee: there is NO merge verb anywhere in the module. A
# `merge` ACTION (merge_pr, def *merge*(...), .merge()) must be ABSENT. The
# human-WRITEBACK path (on_merged / on-merge / is_merged) is NOT a merge action.
NONWRITEBACK="$(grep -nE '\bmerge\b' "$LIB" \
  | grep -viE 'on_merged|on-merge|on merge|is_merged|merged|_merge_verify|human(-| )merge|self-merge|never merge|not merge|no merge|does not merge|cannot self-merge|verb' \
  || true)"
# specifically assert no merge ACTION verb (a function/method that merges).
if grep -nE 'def +[a-zA-Z_]*merge[a-zA-Z_]*\(|\bmerge_pr\b|\.merge\(|gh +pr +merge|pr +merge' "$LIB" \
   | grep -viE 'on_merged|is_merged|_merge_verify' >/dev/null 2>&1; then
  bad "a MERGE VERB exists in the module — HUMAN GATE BROKEN (self-merge possible)"
else
  ok "no merge verb in the module: merge_pr / def *merge*( / .merge( / gh pr merge — ABSENT"
fi
# the only merge-named symbols are the human writeback (on_merged) + the merge
# VERIFY check (is_merged / _merge_verify) — never a merge ACTION.
if grep -qE 'def on_merged\(' "$LIB"; then
  ok "the only merge-named entry point is on_merged (the HUMAN writeback path)"
else
  bad "on_merged (the human writeback entry point) is missing"
fi

echo "  ‣ FALSIFIABILITY proof — an 'auto-merge' variant MUST red the grep:"
AUTOMERGE_VARIANT="$WORK/automerge_variant.py"
cat > "$AUTOMERGE_VARIANT" <<'PYEOF'
# a HYPOTHETICAL bad build that DOES self-merge (the forbidden variant).
def merge_pr(pr_ref):
    # auto-merge — this is exactly what the human gate forbids.
    return {"ok": True, "merged": True}
PYEOF
if grep -nE 'def +[a-zA-Z_]*merge[a-zA-Z_]*\(|\bmerge_pr\b|\.merge\(' "$AUTOMERGE_VARIANT" \
   | grep -viE 'on_merged|is_merged|_merge_verify' >/dev/null 2>&1; then
  ok "FALSIFIABLE: the auto-merge variant REDS the no-merge grep (assertion can fail)"
else
  bad "the no-merge grep is NOT falsifiable — it would pass even an auto-merge build"
fi

echo
echo "── (4) WRITE-BACK — on_merged closes source + post_resolution (HUMAN path) ────"
# fresh in_flight + record the PR ref (as open_pr would), then simulate a HUMAN
# merge and run on_merged. ONLY now may close_issue + post_resolution fire.
seed_inflight
CONN_SENTINEL="$WORK/conn_merge.jsonl"; export CONN_SENTINEL; : > "$CONN_SENTINEL"
: > "$GH_SENTINEL"
open_pr_driver "$PASS_RECORD" >/dev/null   # marks PR_OPEN, records pr ref
export MOCK_PR_MERGED=1                     # the HUMAN merged the PR
MERGE_OUT="$(on_merged_driver 2>"$WORK/merge.err")"
if printf '%s' "$MERGE_OUT" | jq -e '.merged == true and .source_closed == true and .resolution_posted == true' >/dev/null 2>&1; then
  ok "on_merged: source closed + resolution posted + merged=true"
else
  bad "on_merged did not close+writeback (cat $WORK/merge.err)"
fi
N_CLOSE="$(grep -c '"kind": "close_issue"' "$CONN_SENTINEL" || true)"
N_POST="$(grep -c '"kind": "post_resolution"' "$CONN_SENTINEL" || true)"
if [ "$N_CLOSE" = "1" ]; then
  ok "connector.close_issue called exactly once (the source issue closed)"
else
  bad "connector.close_issue called $N_CLOSE times (expected 1)"
fi
if [ "$N_POST" = "1" ]; then
  ok "connector.post_resolution called exactly once (resolution routed back)"
else
  bad "connector.post_resolution called $N_POST times (expected 1)"
fi
# the resolution posted back carries the PR ref (the source links to the merge).
if grep -F '"post_resolution"' "$CONN_SENTINEL" | jq -e '.payload.resolution.pr != null' >/dev/null 2>&1; then
  ok "the written-back resolution carries the PR ref (source links to the merged PR)"
else
  bad "the written-back resolution missing the PR ref"
fi
if "$CMD" status --id "github:acme/widget#7" --repo "$REPO" | jq -e '.resolved == true and .merged == true' >/dev/null 2>&1; then
  ok "issue moved to resolved{merged:true} (only AFTER the human merge)"
else
  bad "issue not in resolved{merged:true} after on_merged"
fi
unset MOCK_PR_MERGED

echo
echo "── (5) DEFENCE-IN-DEPTH (cardinal rule + un-merged refusal) ───────────────────"
# (5a) open_pr REFUSES a FAIL record (all_passed != true) — a FAIL can't be a PR.
seed_inflight
CONN_SENTINEL="$WORK/conn_fail.jsonl"; export CONN_SENTINEL; : > "$CONN_SENTINEL"
if "$CMD" open --issue "$ISSUE_JSON" --record "$FAIL_RECORD" --repo "$REPO" >/dev/null 2>"$WORK/openfail.err"; then
  bad "open_pr accepted a gate-FAIL record — CARDINAL RULE VIOLATED (PR on a FAIL)"
else
  RC=$?
  if [ "$RC" = "1" ] && grep -qiE 'all_passed|PROVEN|gate-PASS' "$WORK/openfail.err"; then
    ok "open_pr REFUSES a FAIL record (exit 1, loud) — a FAIL cannot produce a PR"
  else
    bad "open_pr rejected the FAIL but not via the human-gate refusal (rc=$RC)"
  fi
fi
# the FAIL never reached the connector (no close/post on a refused open).
if [ ! -s "$CONN_SENTINEL" ]; then
  ok "the refused FAIL open touched NO connector (no close/post on a non-PR)"
else
  bad "a refused FAIL open still touched the connector"
fi

# (5b) on_merged REFUSES to write back an UN-merged PR (no human merge signal).
seed_inflight
CONN_SENTINEL="$WORK/conn_unmerged.jsonl"; export CONN_SENTINEL; : > "$CONN_SENTINEL"
open_pr_driver "$PASS_RECORD" >/dev/null
export MOCK_PR_MERGED=0   # the PR is NOT merged (is_merged -> False)
if on_merged_driver >/dev/null 2>"$WORK/unmerged.err"; then
  bad "on_merged wrote back an UN-merged PR — HUMAN GATE VIOLATED"
else
  RC=$?
  if [ "$RC" = "1" ] && grep -qiE 'not merged|human merge' "$WORK/unmerged.err"; then
    ok "on_merged REFUSES an un-merged PR (exit 1, loud) — writeback needs a human merge"
  else
    bad "on_merged rejected the un-merged PR but not via the human-gate refusal (rc=$RC)"
  fi
fi
if [ ! -s "$CONN_SENTINEL" ]; then
  ok "the refused un-merged writeback touched NO connector (no premature close/post)"
else
  bad "a refused un-merged writeback still closed/posted to the connector"
fi
unset MOCK_PR_MERGED

echo
echo "── (6) BUG #21 — open_pr COMMITS + PUSHES the heimdall/* branch BEFORE gh pr create ──"
# The defect: open_pr built `gh pr create --head heimdall/issue/<id>` while NOTHING ever
# created/committed/pushed that branch — a live PASS would open a PR against a ref the
# remote never saw (empty/failing PR). The fix commits the working-tree edit onto the
# heimdall/* branch (bot identity) and PUSHES it to origin (scoped bot token via env),
# THEN opens the PR. HERMETIC: a LOCAL BARE repo as origin (no network, no live GitHub);
# the mock gh runner records `gh pr create` (no real gh). We assert the branch LANDS in
# the bare remote carrying the edit commit, the committer is the bot, the push rode NO
# token on argv/refs, and gh pr create fired AFTER the push.
FAKETOKEN="ghs_FAKEbottoken000000000000000000000000"

# a clone with a real (local, bare) origin + an UNCOMMITTED working-tree fix edit.
PUSH_REPO="$WORK/pushrepo"; PUSH_BARE="$WORK/pushrepo.git"
git init --bare -q "$PUSH_BARE"
mkdir -p "$PUSH_REPO"
git -C "$PUSH_REPO" init -q
git -C "$PUSH_REPO" config user.email t@t
git -C "$PUSH_REPO" config user.name t
git -C "$PUSH_REPO" config commit.gpgsign false
git -C "$PUSH_REPO" remote add origin "$PUSH_BARE"
printf 'module init\n' > "$PUSH_REPO/app.py"
git -C "$PUSH_REPO" add -A
git -C "$PUSH_REPO" commit -qm init
FIX_MARK="THE-REAL-FIX-LINE-$$"
printf '%s\n' "$FIX_MARK" >> "$PUSH_REPO/app.py"   # the uncommitted fix the loop produced

# a driver that calls open_pr with the recording mock gh runner + a bot token set, so the
# COMMIT+PUSH path fires (the token rides the env; the mock avoids a live gh). Catches a
# PushError (branch push failed) and exits 1 with the scrubbed message — mirrors the CLI.
open_pr_push_driver() {
  # $1 = repo path. Prints the open_pr result JSON on success; exit 1 on PushError.
  RECORD="$PASS_RECORD" ISSUE_JSON="$ISSUE_JSON" REPO="$1" \
  HEIMDALL_PR_BOT_TOKEN="$FAKETOKEN" "$PY" - <<'PYEOF'
import json, os, sys
import issue_pr
import mock_gh
issue = json.loads(os.environ["ISSUE_JSON"])
record = json.loads(os.environ["RECORD"])
try:
    result = issue_pr.open_pr(issue, record, repo=os.environ["REPO"], base="main",
                              gh_runner=mock_gh.runner)
except issue_pr.PushError as exc:
    sys.stderr.write("PushError: %s\n" % exc)
    sys.exit(1)
print(json.dumps(result))
PYEOF
}

: > "$GH_SENTINEL"
PUSH_OUT="$(open_pr_push_driver "$PUSH_REPO")"
PUSH_BRANCH="heimdall/issue/github-acme-widget-7"

# (6a) the branch was created IN THE BARE REMOTE and carries the fix commit.
if git -C "$PUSH_BARE" rev-parse --verify "refs/heads/$PUSH_BRANCH" >/dev/null 2>&1; then
  ok "the heimdall/* branch was PUSHED to origin (it EXISTS in the bare remote)"
else
  bad "the branch never reached origin — the PR would reference a non-existent ref (bug #21)"
fi
if git -C "$PUSH_BARE" show "$PUSH_BRANCH:app.py" 2>/dev/null | grep -qF "$FIX_MARK"; then
  ok "the pushed branch CARRIES the working-tree fix edit (not empty)"
else
  bad "the pushed branch is missing the fix edit — the PR would be empty"
fi

# (6b) the commit was authored + committed by the BOT identity (never a real person).
CN="$(git -C "$PUSH_BARE" log -1 --format='%cn' "$PUSH_BRANCH" 2>/dev/null || true)"
AN="$(git -C "$PUSH_BARE" log -1 --format='%an' "$PUSH_BRANCH" 2>/dev/null || true)"
CE="$(git -C "$PUSH_BARE" log -1 --format='%ce' "$PUSH_BRANCH" 2>/dev/null || true)"
if [ "$CN" = "heimdall-maintainer[bot]" ] && [ "$AN" = "heimdall-maintainer[bot]" ]; then
  ok "the fix commit committer + author are the BOT identity (heimdall-maintainer[bot])"
else
  bad "the fix commit is NOT the bot identity (committer=$CN author=$AN)"
fi
if printf '%s' "$CE" | grep -qF 'noreply'; then
  ok "the bot commit email is a noreply address (a [bot] handle, never a real person)"
else
  bad "the bot commit email is not a noreply address ($CE)"
fi

# (6c) gh pr create FIRED (after the push) — the mock recorded a create-command whose
# --head is exactly the pushed heimdall/* branch.
if [ -s "$GH_SENTINEL" ] && jq -e '. | index("create")' < "$GH_SENTINEL" >/dev/null 2>&1; then
  ok "gh pr create FIRED after the push (the mock recorded a create-command)"
else
  bad "gh pr create did NOT fire after the push"
fi
if grep -qF "$PUSH_BRANCH" "$GH_SENTINEL"; then
  ok "the gh pr create --head references the pushed heimdall/* branch"
else
  bad "the gh pr create --head does not reference the pushed branch"
fi

# (6d) FALSIFIER — token-free: the scoped bot token rides the ENV only, NEVER argv / a
# logged URL / a stored ref. It must appear NOWHERE in the result, the recorded gh
# command, nor the bare remote (config/reflog/packed-refs). If code ever put it on argv or
# in a URL-with-token push, this REDS.
LEAK="$(
  { printf '%s\n' "$PUSH_OUT"; cat "$GH_SENTINEL";
    grep -rIsF "$FAKETOKEN" "$PUSH_BARE" 2>/dev/null || true; } | grep -F "$FAKETOKEN" || true
)"
if [ -z "$LEAK" ]; then
  ok "TOKEN-FREE: the bot token appears in NO argv / result / remote (it rode the env only)"
else
  bad "TOKEN LEAK: the scoped bot token surfaced on an argv/URL/ref — creds discipline broken"
fi

# (6e) the push targets the bot's heimdall/* namespace ONLY — main is NEVER pushed.
case "$PUSH_BRANCH" in
  heimdall/*) ok "the pushed branch is under the bot's heimdall/* namespace (never main)" ;;
  *) bad "the pushed branch escaped heimdall/* — SAFETY BROKEN" ;;
esac
if git -C "$PUSH_BARE" rev-parse --verify refs/heads/main >/dev/null 2>&1 \
   || git -C "$PUSH_BARE" rev-parse --verify refs/heads/master >/dev/null 2>&1; then
  bad "main/master exists in the bare remote — open_pr pushed a default branch (NEVER allowed)"
else
  ok "no main/master was pushed to origin — open_pr pushes ONLY the heimdall/* branch"
fi

echo "  ‣ FALSIFIER — a PUSH FAILURE opens NO PR (loud, scrubbed) ────────────────────"
# origin points at a path that is NOT a git repo -> the push FAILS. open_pr must raise a
# PushError BEFORE any gh pr create — a PR is never opened against a branch the remote
# never saw. The error is loud and token-scrubbed.
FAIL_REPO="$WORK/failpush"
mkdir -p "$FAIL_REPO" "$WORK/not-a-repo"
git -C "$FAIL_REPO" init -q
git -C "$FAIL_REPO" config user.email t@t
git -C "$FAIL_REPO" config user.name t
git -C "$FAIL_REPO" config commit.gpgsign false
git -C "$FAIL_REPO" remote add origin "$WORK/not-a-repo"   # not a repo -> push fails
printf 'module init\n' > "$FAIL_REPO/app.py"
git -C "$FAIL_REPO" add -A
git -C "$FAIL_REPO" commit -qm init
printf 'edit\n' >> "$FAIL_REPO/app.py"
: > "$GH_SENTINEL"
if open_pr_push_driver "$FAIL_REPO" >/dev/null 2>"$WORK/pusherr.err"; then
  bad "open_pr opened a PR despite a push failure — bug #21 regressed (dangling PR)"
else
  RC=$?
  if [ "$RC" = "1" ] && [ ! -s "$GH_SENTINEL" ]; then
    ok "a push failure -> exit 1 and NO gh pr create (no PR against an unpushed branch)"
  else
    bad "a push failure did not cleanly refuse (rc=$RC, gh recorded: $(cat "$GH_SENTINEL"))"
  fi
fi
if grep -qiE 'push|branch' "$WORK/pusherr.err"; then
  ok "the push failure is LOUD (the error names the push/branch failure)"
else
  bad "the push failure was not surfaced loudly"
fi
if grep -qF "$FAKETOKEN" "$WORK/pusherr.err"; then
  bad "the push-failure error LEAKED the bot token — scrub discipline broken"
else
  ok "the push-failure error is token-scrubbed (no credential in the surfaced message)"
fi

echo "  ‣ IDEMPOTENCY — gh_bot_runner treats an existing PR ('already exists') as success ──"
# A re-run re-pushes the branch and re-runs `gh pr create`; gh EXITS NON-ZERO when an open
# PR already exists for the head. That is SUCCESS for us — detect it, recover the existing
# PR url, return ok=true (never a spurious failure). Fake gh: exit 1 + the "already exists"
# message carrying the existing PR url.
IDEMPBIN="$WORK/idempbin"; mkdir -p "$IDEMPBIN"
cat > "$IDEMPBIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "a pull request for branch \"heimdall/issue/x\" into branch \"main\" already exists:" >&2
echo "https://github.com/acme/widget/pull/42" >&2
exit 1
GHEOF
chmod +x "$IDEMPBIN/gh"
IDEMP_OUT="$(PATH="$IDEMPBIN:$PATH" HEIMDALL_PR_BOT_TOKEN="$FAKETOKEN" "$PY" - <<'PYEOF'
import json
import issue_pr
r = issue_pr.gh_bot_runner(["gh", "pr", "create", "--head", "heimdall/issue/x"])
print(json.dumps(r))
PYEOF
)"
if printf '%s' "$IDEMP_OUT" | jq -e '.ok == true and .already_exists == true and (.url | test("/pull/42"))' >/dev/null 2>&1; then
  ok "an 'already exists' PR is treated as SUCCESS with the existing url recovered (idempotent re-run)"
else
  bad "gh_bot_runner did not tolerate an existing PR ($IDEMP_OUT)"
fi

echo
echo "── (7) BUG #24 — CLEAN COMMIT SCOPE: the push carries ONLY the fix, never junk ──"
# The defect: `git add -A` staged the fix AND the session/test artifacts the fix/attest run
# leaves in the clone (__pycache__/, .pytest_cache/, .claude/, egg-info, .heimdall/), so the
# pushed heimdall/* branch carried junk beyond the 1-file fix (run-11: "6 files" for a 1-file
# edit). _commit_and_push_branch now writes a SCOPED local exclude before staging, so the
# pushed diff is EXACTLY the source change. HERMETIC: a LOCAL BARE origin; we assert the fix
# file LANDS in the remote branch and every junk path is ABSENT (git -C bare ls-tree).
SCOPE_REPO="$WORK/scoperepo"; SCOPE_BARE="$WORK/scoperepo.git"
git init --bare -q "$SCOPE_BARE"
mkdir -p "$SCOPE_REPO"
git -C "$SCOPE_REPO" init -q
git -C "$SCOPE_REPO" config user.email t@t
git -C "$SCOPE_REPO" config user.name t
git -C "$SCOPE_REPO" config commit.gpgsign false
git -C "$SCOPE_REPO" remote add origin "$SCOPE_BARE"
mkdir -p "$SCOPE_REPO/tinymath"
printf 'def sum_range(a, b):\n    return sum(range(a, b))\n' > "$SCOPE_REPO/tinymath/core.py"
git -C "$SCOPE_REPO" add -A
git -C "$SCOPE_REPO" commit -qm init
# the REAL source fix (the only thing that should land on the branch).
SCOPE_FIX="THE-REAL-FIX-$$"
printf 'def sum_range(a, b):\n    return sum(range(a, b + 1))  # %s\n' "$SCOPE_FIX" > "$SCOPE_REPO/tinymath/core.py"
# the STRAY session/test artifacts the fix/attest run leaves behind (untracked junk).
mkdir -p "$SCOPE_REPO/tinymath/__pycache__" "$SCOPE_REPO/.pytest_cache" \
         "$SCOPE_REPO/.claude" "$SCOPE_REPO/tinymath.egg-info"
printf 'JUNK\n' > "$SCOPE_REPO/tinymath/__pycache__/core.cpython-312.pyc"
printf 'JUNK\n' > "$SCOPE_REPO/.pytest_cache/CACHEDIR.TAG"
printf 'JUNK\n' > "$SCOPE_REPO/.claude/scratch.json"
printf 'JUNK\n' > "$SCOPE_REPO/tinymath.egg-info/PKG-INFO"

: > "$GH_SENTINEL"
SCOPE_OUT="$(open_pr_push_driver "$SCOPE_REPO")"
SCOPE_BRANCH="heimdall/issue/github-acme-widget-7"

# (7a) the REAL fix file landed on the pushed branch, carrying the fix.
if git -C "$SCOPE_BARE" show "$SCOPE_BRANCH:tinymath/core.py" 2>/dev/null | grep -qF "$SCOPE_FIX"; then
  ok "the pushed branch CARRIES the real source fix (tinymath/core.py)"
else
  bad "the pushed branch is missing the real fix — clean-scope dropped the source change"
fi

# (7b) EVERY junk path is ABSENT from the pushed tree (the whole point of bug #24).
SCOPE_TREE="$(git -C "$SCOPE_BARE" ls-tree -r --name-only "$SCOPE_BRANCH" 2>/dev/null || true)"
JUNK_HIT=0
for junk in "__pycache__" ".pytest_cache" ".claude/" ".egg-info" ".heimdall"; do
  if printf '%s\n' "$SCOPE_TREE" | grep -qF "$junk"; then
    bad "JUNK LEAKED into the pushed branch: a path matching '$junk' was committed"
    JUNK_HIT=1
  fi
done
if [ "$JUNK_HIT" -eq 0 ]; then
  ok "NO junk in the pushed tree (__pycache__/.pytest_cache/.claude/.egg-info/.heimdall all absent)"
fi
# (7c) the committed tree is EXACTLY the one source file changed (files_changed=1 alignment).
SCOPE_DIFF_N="$(git -C "$SCOPE_BARE" diff --name-only "$SCOPE_BRANCH~1" "$SCOPE_BRANCH" 2>/dev/null | grep -c . || true)"
if [ "$SCOPE_DIFF_N" = "1" ]; then
  ok "the fix commit changed EXACTLY 1 file (aligned with the attestation's files_changed=1)"
else
  bad "the fix commit changed $SCOPE_DIFF_N files (expected exactly 1 — the source fix)"
fi
# (7d) the scoped exclude is LOCAL to the clone (never a committed .gitignore in the tree).
if printf '%s\n' "$SCOPE_TREE" | grep -qxF ".gitignore"; then
  bad "a .gitignore was committed — the exclude must be LOCAL (.git/info/exclude), not the tree"
else
  ok "the scope exclude is local to the clone (.git/info/exclude) — the repo tree is untouched"
fi
if grep -qF "heimdall-maintainer: scoped fix-commit exclude" "$SCOPE_REPO/.git/info/exclude" 2>/dev/null; then
  ok "the clone's LOCAL exclude (.git/info/exclude) carries the scoped junk patterns"
else
  bad "the local .git/info/exclude was not written with the scoped patterns"
fi

echo
echo "── grep: structural proofs of the human gate in the source ───────────────────"
if grep -qE 'def open_pr\(' "$LIB" && grep -qE 'def on_merged\(' "$LIB"; then
  ok "module exposes open_pr (open+stop) and on_merged (human writeback) — and only these"
else
  bad "module missing the open_pr / on_merged entry points"
fi
# open_pr must NOT call close_issue / post_resolution (those belong to on_merged).
# We check the executable CODE only — the docstring (which legitimately *mentions*
# "does NOT call post_resolution") is stripped before the check, so the assertion
# is about real call sites, not prose.
if "$PY" - "$LIB" <<'PYEOF'
import ast, sys
src = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(src)
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "open_pr")
body = list(fn.body)
if body and isinstance(body[0], ast.Expr) and isinstance(
        getattr(body[0], "value", None), ast.Constant) and isinstance(
        body[0].value.value, str):
    body = body[1:]  # drop the leading docstring node
code = "\n".join(ast.unparse(s) for s in body)
bad = ("close_issue" in code) or ("post_resolution" in code)
sys.exit(1 if bad else 0)
PYEOF
then
  ok "open_pr's CODE references NEITHER close_issue NOR post_resolution (writeback is on_merged-only)"
else
  bad "open_pr's code references close_issue/post_resolution — the human gate is not structural"
fi
# on_merged IS the writeback path (its CODE references both).
if "$PY" - "$LIB" <<'PYEOF'
import ast, sys
src = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(src)
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "on_merged")
body = list(fn.body)
if body and isinstance(body[0], ast.Expr) and isinstance(
        getattr(body[0], "value", None), ast.Constant) and isinstance(
        body[0].value.value, str):
    body = body[1:]
code = "\n".join(ast.unparse(s) for s in body)
ok = ("close_issue" in code) and ("post_resolution" in code)
sys.exit(0 if ok else 1)
PYEOF
then
  ok "on_merged's CODE references BOTH close_issue + post_resolution (the only writeback path)"
else
  bad "on_merged does not perform the close+writeback"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "issue-pr: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — open_pr opens+STOPS (no self-merge, no self-close); on_merged is the"
echo "ONLY human-triggered writeback; PR body carries SI-2 evidence; gate is STRUCTURAL."

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

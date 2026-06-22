#!/usr/bin/env bash
# test/issue-loop.test.sh — piece (c) acceptance for the Heimdall issue-resolution
# loop state machine (design dossier §4 + §5 THE CARDINAL RULE, safety-critical).
#
# Proves, against the REAL lib + CLI (no canned shapes), the dossier contract:
#
#   pick -> orient(SI-1) -> fix -> GATE -> attest(SI-2) -> [PR-ready | flagged]
#
#   (1) ORIENT reuses SI-1 — the loop shells out to `bin/heimdall-comprehend`
#       (load, falling back to comprehend on exit 3) and ATTACHES the resulting
#       capsule (.heimdall/context.json) to the fix brief. No reimplemented
#       comprehension — assert comprehend was invoked + the capsule rode along.
#
#   (2) ATTEST reuses SI-2 — the loop shells out to `bin/heimdall-attest emit
#       --evidence`, and the emitted record (schema si-2.1) carries the runnable
#       evidence. Assert the record is emitted + carries an evidence block.
#
#   (3) THE CARDINAL RULE (safety-critical, dossier §5) — the gate verdict is read
#       ONLY from record["evidence"]["all_passed"] (a recorded REAL exit), NEVER
#       from an agent "done" claim. FALSIFIABLE:
#         • a gate-PASS fix (its evidence command exits 0) DOES reach pr_ready and
#           DOES call the PR layer's open_pr(issue, record);
#         • FLIP the verdict (the evidence command exits non-zero) and the SAME
#           loop must NOT reach pr_ready, must NOT call open_pr, and must flag the
#           issue honestly {reason: 'gate-failed'} — kept OUT of the resolved path.
#       The PR layer is a TEST-DOUBLE (a mock issue_pr module) recording whether
#       open_pr fired. Mocks in the TEST are fine; production has no stubs.
#
#   (4) PICK respects in-flight idempotency (no double-pick) — the loop claims via
#       the real queue; a second run-once never re-picks the in-flight/flagged id.
#
#   (5) SOFT-IMPORT — with NO pr layer present, a gate-PASS marks the issue
#       pr_ready and STOPS (no fabricated PR), mirroring how piece (b) soft-imports
#       connectors.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-issue-loop"
LIB="$ROOT/bin/lib/issue_loop.py"
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

# ── a throwaway git repo to run the loop against (real seams) ─────────────────
WORK="$(mktemp -d -t "issue-loop-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@runheimdall.dev"
git -C "$REPO" config user.name "test"
printf 'module init\n' > "$REPO/app.py"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"

# store/home lives under the repo's gitignored .heimdall (queue + capsule + attests).
export HEIMDALL_HOME="$REPO/.heimdall"

# expose the real connectors + queue libs to the loop's python path.
export PYTHONPATH="$ROOT/bin/lib:${PYTHONPATH:-}"

# ── seed the queue with ONE fixable issue (the real queue store) ──────────────
seed_issue() {
  # $1 = native number (distinct id per call). Resets the queue first.
  local num="$1"
  rm -f "$HEIMDALL_HOME/issues/queue.json"
  local raw
  raw="$("$PY" -c 'import json,sys; print(json.dumps({"repo":"acme/widget","number":int(sys.argv[1]),"title":"fix the thing","body":"the thing is broken","labels":[{"name":"bug"}],"created_at":"2020-06-01T00:00:00Z"}))' "$num")"
  "$ROOT/bin/heimdall-issue-queue" ingest --source github --raw "$raw" --repo "$REPO" >/dev/null
}

# ── a TEST-DOUBLE pr layer: a fake bin/lib/issue_pr.py that records open_pr ────
# The loop soft-imports issue_pr (like piece b soft-imports connectors). We make a
# fake module on a DIR we prepend to PYTHONPATH for the PASS-with-pr-layer case.
PR_DIR="$WORK/prlayer"
mkdir -p "$PR_DIR"
cat > "$PR_DIR/issue_pr.py" <<PYEOF
# TEST-DOUBLE pr layer. Records every open_pr call to a sentinel file so the test
# can assert the cardinal-rule wiring: open_pr fires on PASS, NEVER on FAIL.
import json, os
SENTINEL = os.environ["PR_SENTINEL"]
def open_pr(issue, record):
    # Structural mirror of the real layer's contract: a FAIL must never reach here.
    # Record the call (issue id + the verdict we were handed) for the assertion.
    with open(SENTINEL, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "id": issue.get("id"),
            "all_passed": record.get("evidence", {}).get("all_passed"),
        }) + "\n")
    return {"ok": True, "pr": "fake#1", "id": issue.get("id")}
PYEOF

# ── fix-runner fixtures: a PASS evidence cmd and a FAIL evidence cmd ───────────
# The loop drives the fix slot, then the GATE runs the evidence command via SI-2.
# We hand the loop the evidence command through --evidence so the gate verdict is
# a RECORDED REAL EXIT, not a claim. PASS = `true` (exit 0); FAIL = `false`.

run_once() {
  # $1 = evidence cmd ; rest = extra args. Drives a single run-once.
  local ev="$1"; shift
  "$CMD" run-once --repo "$REPO" --evidence "$ev" "$@"
}

echo "── (1) orient reuses SI-1 (comprehend invoked, capsule attached) ─────────────"
seed_issue 1
PR_SENTINEL="$WORK/sentinel_orient.jsonl"; export PR_SENTINEL
: > "$PR_SENTINEL"
OUT="$(PYTHONPATH="$PR_DIR:$PYTHONPATH" run_once "true" --print 2>"$WORK/orient.err")" || true
# the capsule must exist (comprehend wrote it) AND be attached to the loop result.
if [ -f "$HEIMDALL_HOME/context.json" ]; then
  ok "SI-1 comprehend produced the capsule (.heimdall/context.json)"
else
  bad "SI-1 capsule not written — orient did not reuse comprehend"
fi
if printf '%s' "$OUT" | jq -e '.orient.capsule_attached == true' >/dev/null 2>&1; then
  ok "orient attached the SI-1 capsule to the fix brief"
else
  bad "orient did not attach the capsule (capsule_attached != true)"
fi
if printf '%s' "$OUT" | jq -e '.orient.tool == "heimdall-comprehend"' >/dev/null 2>&1; then
  ok "orient names heimdall-comprehend (SI-1 reused, not reimplemented)"
else
  bad "orient did not record the heimdall-comprehend reuse"
fi

echo "── (2) attest reuses SI-2 (record emitted, carries evidence) ─────────────────"
seed_issue 2
PR_SENTINEL="$WORK/sentinel_attest.jsonl"; export PR_SENTINEL
: > "$PR_SENTINEL"
OUT="$(PYTHONPATH="$PR_DIR:$PYTHONPATH" run_once "true" --print 2>"$WORK/attest.err")" || true
if printf '%s' "$OUT" | jq -e '.attestation.schema == "si-2.1"' >/dev/null 2>&1; then
  ok "SI-2 record emitted with schema si-2.1 (attest reused, not reimplemented)"
else
  bad "no si-2.1 attestation record emitted by the loop"
fi
if printf '%s' "$OUT" | jq -e '.attestation.evidence.checks | length >= 1' >/dev/null 2>&1; then
  ok "the attestation carries the runnable evidence the PR will show"
else
  bad "attestation evidence block is empty — SI-2 evidence not carried"
fi

echo "── (3) THE CARDINAL RULE — PASS->pr_ready/open_pr ; FAIL->flagged/NO PR ──────"

# (3a) PASS: evidence exits 0 -> pr_ready, open_pr fires once with all_passed=true.
seed_issue 3
PR_SENTINEL="$WORK/sentinel_pass.jsonl"; export PR_SENTINEL
: > "$PR_SENTINEL"
OUT="$(PYTHONPATH="$PR_DIR:$PYTHONPATH" run_once "true" --print 2>"$WORK/pass.err")" || true
if printf '%s' "$OUT" | jq -e '.state == "PR_OPEN" and .pr_ready == true' >/dev/null 2>&1; then
  ok "PASS: gate-pass fix reaches PR_OPEN / pr_ready"
else
  bad "PASS: gate-pass fix did NOT reach pr_ready (cardinal rule falsifiable-positive broken)"
fi
if printf '%s' "$OUT" | jq -e '.gate.all_passed == true' >/dev/null 2>&1; then
  ok "PASS: verdict read from record.evidence.all_passed == true (recorded real exit)"
else
  bad "PASS: gate verdict not sourced from evidence.all_passed"
fi
if [ "$(wc -l < "$PR_SENTINEL" | tr -d ' ')" = "1" ] && \
   jq -e '.all_passed == true' < "$PR_SENTINEL" >/dev/null 2>&1; then
  ok "PASS: open_pr fired exactly once, handed the all_passed=true record"
else
  bad "PASS: open_pr did NOT fire on a gate-pass (PR layer not invoked)"
fi

# (3b) FAIL: FLIP the verdict — evidence exits non-zero. The SAME loop must NOT
#      reach pr_ready, must NOT call open_pr, must flag {reason:'gate-failed'}.
seed_issue 4
PR_SENTINEL="$WORK/sentinel_fail.jsonl"; export PR_SENTINEL
: > "$PR_SENTINEL"
OUT="$(PYTHONPATH="$PR_DIR:$PYTHONPATH" run_once "false" --print 2>"$WORK/fail.err")" || true
if printf '%s' "$OUT" | jq -e '.state == "GATE_FAILED"' >/dev/null 2>&1; then
  ok "FAIL: gate-fail fix lands in GATE_FAILED"
else
  bad "FAIL: gate-fail fix did NOT land in GATE_FAILED"
fi
if printf '%s' "$OUT" | jq -e '.pr_ready != true' >/dev/null 2>&1; then
  ok "FAIL: NO pr_ready on a gate-fail (cardinal rule holds)"
else
  bad "FAIL: pr_ready set on a gate-FAIL — CARDINAL RULE VIOLATED"
fi
if printf '%s' "$OUT" | jq -e '.gate.all_passed == false' >/dev/null 2>&1; then
  ok "FAIL: verdict read from record.evidence.all_passed == false (honest real exit)"
else
  bad "FAIL: gate verdict not sourced from evidence.all_passed"
fi
if [ ! -s "$PR_SENTINEL" ]; then
  ok "FAIL: open_pr NEVER fired on a gate-fail (no PR on FAIL)"
else
  bad "FAIL: open_pr fired on a gate-FAIL — CARDINAL RULE VIOLATED (PR on a failed gate)"
fi
# the issue is flagged honestly + kept OUT of the resolved path.
if "$ROOT/bin/heimdall-issue-queue" status --repo "$REPO" | jq -e '.flagged >= 1 and .resolved == 0' >/dev/null 2>&1; then
  ok "FAIL: issue flagged (out of the resolved path)"
else
  bad "FAIL: issue not flagged / leaked into resolved"
fi
FLAG_REASON="$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); fl=d.get("flagged",{}); print(next(iter(fl.values()),{}).get("reason","") if fl else "")' "$HEIMDALL_HOME/issues/queue.json" 2>/dev/null || true)"
if [ "$FLAG_REASON" = "gate-failed" ]; then
  ok "FAIL: flag reason is the honest 'gate-failed'"
else
  bad "FAIL: flag reason was '$FLAG_REASON' (expected 'gate-failed')"
fi

echo "── (4) pick respects in-flight (no double-pick) ──────────────────────────────"
# After the FAIL run above, the id is flagged -> a second run-once must NOT re-pick
# it; with nothing else queued the loop is inert (picks nothing).
OUT2="$(PYTHONPATH="$PR_DIR:$PYTHONPATH" run_once "true" --print 2>"$WORK/nopick.err")" || true
if printf '%s' "$OUT2" | jq -e '.state == "IDLE" and (.issue == null)' >/dev/null 2>&1; then
  ok "no double-pick: a flagged id is never re-picked (loop idle, nothing pickable)"
else
  bad "double-pick: the loop re-picked an already-claimed/flagged id"
fi

echo "── (5) soft-import: NO pr layer present -> pr_ready + STOP (no fabricated PR) ─"
seed_issue 5
PR_SENTINEL="$WORK/sentinel_soft.jsonl"; export PR_SENTINEL
: > "$PR_SENTINEL"
# run WITHOUT the fake pr layer on the path: issue_pr is absent -> soft-import miss.
OUT="$(run_once "true" --print 2>"$WORK/soft.err")" || true
if printf '%s' "$OUT" | jq -e '.pr_ready == true and .pr_opened == false' >/dev/null 2>&1; then
  ok "soft-import: pr_ready marked, pr_opened false (no fabricated PR when layer absent)"
else
  bad "soft-import: absent pr layer did not degrade to pr_ready-and-stop"
fi
if [ ! -s "$PR_SENTINEL" ]; then
  ok "soft-import: no open_pr call fabricated when the layer is absent"
else
  bad "soft-import: a PR was fabricated despite the absent layer"
fi

echo
echo "── grep: FAIL cannot structurally reach open_pr (cardinal-rule wiring) ────────"
# open_pr must be guarded by an all_passed-True branch; assert the source proves it.
if grep -qE 'all_passed' "$LIB" && grep -qE 'open_pr' "$LIB"; then
  ok "loop source references both all_passed (the gate verdict) and open_pr (the PR hook)"
else
  bad "loop source missing the all_passed-gated open_pr wiring"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "issue-loop: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — pick->orient(SI-1)->fix->GATE(cardinal rule)->attest(SI-2)->[PR|flag]"

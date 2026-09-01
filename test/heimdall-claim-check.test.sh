#!/usr/bin/env bash
# test/heimdall-claim-check.test.sh — falsifies bin/heimdall-claim-check, the
# Stop-hook detector for false present-tense process-status claims (the
# "sweep is running" / "tool landed" gaslighting defect: stating a process's
# status from memory of when it started, not from a check at speaking-time).
#
# HONESTY NOTE (read this before trusting the green below). The tool's text
# extraction relies on two paths: (1) a direct `.last_assistant_message` field
# on the Stop hook payload — proven REAL and TESTED for the sibling
# SubagentStop event by test/heimdall-metric-hook.test.sh (which builds and
# feeds the hook a payload containing exactly that field), and likely (Stop
# and SubagentStop share one internal dispatch handler per decompiled-binary
# evidence in this repo) but NOT independently proven here for Stop
# specifically; (2) a fallback that parses `.transcript_path`'s JSONL
# directly — a structure bin/heimdall-conformance already parses in
# production, and test/heimdall-metric-hook.test.sh's own fixtures contain
# verbatim. Sections [1]-[16] exercise path 1; section [17] exercises path 2
# end-to-end. What this suite does NOT and cannot prove: that Claude Code's
# real Stop event actually populates either field at runtime. That is the one
# gap between "this code is correct" and "this code fires in production," and
# it is outside this repo's control to close from the inside.
#
# HERMETIC: every reality-check in this suite runs against fixture PIDs and a
# sweep-pattern override this suite creates and tears down itself — never an
# ambient real background process this suite does not control. This includes
# the FALSE-claim sweep sections ([1], [17]): they override
# HEIMDALL_CLAIM_CHECK_SWEEP_PATTERN to $NO_SWEEP_PATTERN, a sentinel
# guaranteed to match nothing, rather than relying on the tool's default
# pattern (`test/run-all\.sh`) being ambiently absent — a real test/run-all.sh
# sweep's own parent process stays alive and pgrep-visible for its whole run,
# which is exactly what this suite is commonly invoked from inside of.
#
# PREMATURE_REPORT sections ([18]+) fixture bin/heimdall-agents' "sibling
# live" signal directly rather than spawning a real Agent-tool subagent:
# bin/heimdall-agents' own enumerate() falls back to a candidate .output
# file's own mtime when no transcript/meta resolves, and an id that doesn't
# match its "background bash task" shape is never excluded — so one fresh,
# empty, regular (non-symlink) *.output file under a sandboxed
# HMD_AGENT_TASKDIR is sufficient to enumerate as exactly one live subagent
# (verified by reading bin/heimdall-agents' _collect_candidates/enumerate
# directly, not assumed). HMD_AGENT_SUBAGENTS_DIR/HMD_AGENT_PROJECTS_DIR/
# HMD_AGENT_REAPED_FILE are also pinned to sandbox paths so this never reads
# or writes real ~/.heimdall or ~/.claude state. bin/heimdall-agents' own
# correctness is test/heimdall-agents.test.sh's job, not this file's — this
# suite only proves heimdall-claim-check reacts correctly to what
# heimdall-agents reports.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/bin/heimdall-claim-check"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  PASS: %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL: %s\n" "$1"; }

[ -x "$BIN" ] || { echo "FATAL: $BIN missing or not executable"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this suite"; exit 2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hmd-claim-check-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

# NO_SWEEP_PATTERN — a sweep-pattern value guaranteed to match no real
# process, on this machine or any other: it embeds this run's own unique
# sandbox dir name. Sections [1] and [17] assert that a FALSE "sweep is
# running" claim gets flagged; that only holds if nothing matches the pattern
# being checked. The tool's own default pattern (`test/run-all\.sh`) is NOT
# safe to assume absent, because this suite is itself routinely invoked AS A
# CHILD of a real test/run-all.sh sweep, whose parent process stays alive and
# `pgrep -f`-visible for the sweep's entire run — matching the literal
# default and silently flipping the claim from false to true. Confirmed by
# reproduction: backgrounding a fixture process with argv0 "test/run-all.sh"
# reproduces this exact failure (sections [1] and [17] only) with no other
# change. Overriding to this sentinel, the same technique section [2] already
# uses for the TRUE-claim path ("sleep 30"), makes the false-claim path
# hermetic too.
NO_SWEEP_PATTERN="hmd-claim-check-no-such-sweep-$(basename "$SANDBOX")"

# run_raw PAYLOAD_JSON [REPO] — feeds PAYLOAD_JSON to the tool on stdin,
# captures stdout/stderr to sandbox files. REPO defaults to $ROOT (a real,
# tool-bearing repo); tests that need to simulate a missing bin/ tool pass a
# sandboxed REPO instead. Exit code propagates to the caller via $?.
run_raw() {
  local payload="$1" repo="${2:-$ROOT}"
  printf '%s' "$payload" > "$SANDBOX/stdin.json"
  "$BIN" --repo "$repo" < "$SANDBOX/stdin.json" \
    >"$SANDBOX/stdout.log" 2>"$SANDBOX/stderr.log"
}

# run MESSAGE [REPO] — wraps MESSAGE as {last_assistant_message: MESSAGE} and
# runs it. REPO forwards to run_raw (see above).
run() {
  local msg="$1" repo="${2:-$ROOT}" payload
  payload="$(jq -cn --arg m "$msg" '{session_id:"t", last_assistant_message:$m}')"
  run_raw "$payload" "$repo"
}

stderr_has() { grep -qF -- "$1" "$SANDBOX/stderr.log" 2>/dev/null; }

echo "[1] false 'sweep is running' claim (no such process) -> WARNS, still exits 0"
export HEIMDALL_CLAIM_CHECK_SWEEP_PATTERN="$NO_SWEEP_PATTERN"
run "The sweep is running now."
RC=$?
unset HEIMDALL_CLAIM_CHECK_SWEEP_PATTERN
if [ "$RC" -eq 0 ] && stderr_has "false process-status claim"; then
  ok "false sweep-running claim produces a stderr warning and still exits 0"
else
  bad "expected exit 0 + stderr warning; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

echo "[2] true 'sweep is running' claim (real matching process) -> SILENT"
sleep 30 &
SWEEP_PID=$!
i=0
while [ "$i" -lt 10 ]; do
  kill -0 "$SWEEP_PID" 2>/dev/null && break
  sleep 0.2
  i=$((i + 1))
done
export HEIMDALL_CLAIM_CHECK_SWEEP_PATTERN="sleep 30"
run "The sweep is running now."
unset HEIMDALL_CLAIM_CHECK_SWEEP_PATTERN
kill "$SWEEP_PID" >/dev/null 2>&1 || true
wait "$SWEEP_PID" 2>/dev/null || true
if [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "true sweep-running claim (matching real process) produces no warning"
else
  bad "expected silence; got: $(cat "$SANDBOX/stderr.log")"
fi

echo "[3] past-tense 'was still running ... ago' -> SILENT (PAST_GUARD)"
run "The sweep was still running three hours ago."
if [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "past-tense running claim suppressed by PAST_GUARD"
else
  bad "expected silence; got: $(cat "$SANDBOX/stderr.log")"
fi

echo "[4] message with no process-status claim -> SILENT"
run "Implemented the feature and wrote three tests, all passing."
if [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "message with no status claim produces no warning"
else
  bad "expected silence; got: $(cat "$SANDBOX/stderr.log")"
fi

echo "[5] claim naming a dead PID -> WARNS"
( exit 0 ) &
DEADPID=$!
wait "$DEADPID" 2>/dev/null || true
run "The task is running (pid $DEADPID)."
RC=$?
if [ "$RC" -eq 0 ] && stderr_has "false process-status claim"; then
  ok "claim naming a dead pid produces a stderr warning and still exits 0"
else
  bad "expected exit 0 + stderr warning; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

echo "[6] claim naming a genuinely live PID -> SILENT"
sleep 30 &
LIVEPID=$!
i=0
while [ "$i" -lt 10 ]; do
  kill -0 "$LIVEPID" 2>/dev/null && break
  sleep 0.2
  i=$((i + 1))
done
run "The task is running (pid $LIVEPID)."
kill "$LIVEPID" >/dev/null 2>&1 || true
wait "$LIVEPID" 2>/dev/null || true
if [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "claim naming a genuinely live pid produces no warning"
else
  bad "expected silence; got: $(cat "$SANDBOX/stderr.log")"
fi

echo "[7] conditional framing 'Let me check if ... running' -> SILENT (COND_GUARD)"
run "Let me check if the sweep is still running."
if [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "conditional framing suppressed by COND_GUARD"
else
  bad "expected silence; got: $(cat "$SANDBOX/stderr.log")"
fi

echo "[8] quoted claim -> SILENT (QUOTE_GUARD)"
run 'A note said "the sweep is running" as of the last check.'
if [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "sentence containing a literal quote is suppressed by QUOTE_GUARD"
else
  bad "expected silence; got: $(cat "$SANDBOX/stderr.log")"
fi

echo "[9] claim inside a fenced code block -> SILENT (stripped before scan)"
run 'Notes below.
```
# The sweep is running now.
```
No status claims outside the fence.'
if [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "claim-shaped text inside a fenced code block is stripped before scanning"
else
  bad "expected silence; got: $(cat "$SANDBOX/stderr.log")"
fi

echo "[10] documented gap: vague unattributable claim -> SILENT (nothing concrete to check)"
run "The agent is still running this task and should be done soon."
if [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "vague claim with nothing concrete to check is silently skipped (documented limitation)"
else
  bad "expected silence; got: $(cat "$SANDBOX/stderr.log")"
fi

echo "[11] 'landed'/'is wired' claim naming a nonexistent bin/ tool -> WARNS"
run 'Tool `bin/heimdall-totally-fake-tool-xyz` has landed and is wired into hooks.json.'
RC=$?
if [ "$RC" -eq 0 ] && stderr_has "false process-status claim"; then
  ok "claim naming a nonexistent bin/ tool produces a stderr warning and still exits 0"
else
  bad "expected exit 0 + stderr warning; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

echo "[12] 'landed'/'is wired' claim naming a real, LIVE bin/ tool -> SILENT"
DEADCODE="$ROOT/bin/heimdall-deadcode"
LIVE_PRECONDITION=1
if [ ! -x "$DEADCODE" ]; then
  LIVE_PRECONDITION=0
elif ! "$DEADCODE" --why heimdall-metric-hook >/dev/null 2>&1; then
  LIVE_PRECONDITION=0
fi
if [ "$LIVE_PRECONDITION" -eq 1 ]; then
  run 'Tool `bin/heimdall-metric-hook` has landed and is wired into hooks.json.'
  if [ ! -s "$SANDBOX/stderr.log" ]; then
    ok "claim naming a real, live bin/ tool produces no warning"
  else
    bad "expected silence; got: $(cat "$SANDBOX/stderr.log")"
  fi
else
  bad "precondition failed: 'heimdall-deadcode --why heimdall-metric-hook' did not report LIVE -- cannot exercise the true-claim path"
fi

echo "[13] latency bound on a representative no-claim invocation"
START_S=$(date +%s)
run "Nothing notable to report this turn."
END_S=$(date +%s)
ELAPSED_S=$((END_S - START_S))
if [ "$ELAPSED_S" -le 5 ]; then
  ok "invocation completed in ${ELAPSED_S}s (<= 5s bound)"
else
  bad "invocation took ${ELAPSED_S}s, exceeding the 5s bound"
fi

echo "[14] fail-open: empty stdin -> exit 0, silent"
run_raw ""
RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "empty stdin exits 0 silently"
else
  bad "empty stdin: exit=$RC stderr=$(cat "$SANDBOX/stderr.log" 2>/dev/null)"
fi

echo "[15] fail-open: malformed JSON -> exit 0, silent"
run_raw 'not { json at all'
RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "malformed JSON exits 0 silently"
else
  bad "malformed JSON: exit=$RC stderr=$(cat "$SANDBOX/stderr.log" 2>/dev/null)"
fi

echo "[16] fail-open: payload missing both text sources -> exit 0, silent"
run_raw '{"session_id":"t"}'
RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "payload with no text source exits 0 silently"
else
  bad "no-text-source payload: exit=$RC stderr=$(cat "$SANDBOX/stderr.log" 2>/dev/null)"
fi

echo "[17] transcript_path fallback end-to-end (last assistant turn's text, false claim) -> WARNS"
TRANSCRIPT="$SANDBOX/transcript.jsonl"
{
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Starting the sweep now."}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The sweep is running now."}]}}'
} > "$TRANSCRIPT"
PAYLOAD="$(jq -cn --arg tp "$TRANSCRIPT" '{session_id:"t", transcript_path:$tp}')"
export HEIMDALL_CLAIM_CHECK_SWEEP_PATTERN="$NO_SWEEP_PATTERN"
run_raw "$PAYLOAD"
RC=$?
unset HEIMDALL_CLAIM_CHECK_SWEEP_PATTERN
if [ "$RC" -eq 0 ] && stderr_has "false process-status claim"; then
  ok "transcript_path fallback extracts the LAST assistant turn's text and warns on its false claim"
else
  bad "expected exit 0 + stderr warning via transcript_path fallback; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

# ─────────────────────────────────────────────────────────────────────────
# PREMATURE_REPORT — batched-agent-reporting detector (see header above for
# the fixture rationale).
# ─────────────────────────────────────────────────────────────────────────
AGENTS_ENV_SANDBOX="$SANDBOX/agents-env"
mkdir -p "$AGENTS_ENV_SANDBOX/empty-subagents" "$AGENTS_ENV_SANDBOX/empty-projects" "$AGENTS_ENV_SANDBOX/no-siblings-tasks"
export HMD_AGENT_SUBAGENTS_DIR="$AGENTS_ENV_SANDBOX/empty-subagents"
export HMD_AGENT_PROJECTS_DIR="$AGENTS_ENV_SANDBOX/empty-projects"
export HMD_AGENT_REAPED_FILE="$AGENTS_ENV_SANDBOX/reaped.json"

# mk_live_sibling_taskdir — builds a fresh taskdir containing one live-shaped
# *.output fixture (see header note above) and prints its path.
mk_live_sibling_taskdir() {
  local d
  d="$(mktemp -d "$AGENTS_ENV_SANDBOX/live-tasks-XXXXXX")"
  : > "$d/afixturesibling00000000.output"
  printf '%s' "$d"
}

LONG_REPORT="Agent alpha finished the parser rewrite, replacing three legacy functions with a cleaner recursive-descent implementation; all forty-two unit tests pass. Agent beta wrapped up the renderer overhaul: the new layout engine now handles deeply nested grids correctly, and the visual regression suite shows zero diffs against the baseline snapshots. Agent gamma completed the test-suite expansion, adding twelve new cases that cover the edge conditions flagged during planning. A fourth pass confirmed no lint warnings and no type errors across the affected packages. Every agent's changes are merged into the feature branch and the branch is ready for review."

SHORT_HOLD="Two agents are still working; I'll post one summary once both finish."

LONG_UNRELATED="The capital of France is Paris, which has served as the country's political center since the late tenth century. The city sits on the Seine river in the north of the country and is home to roughly two million residents within its administrative boundary, with several million more across the wider metropolitan area. Paris is known worldwide for landmarks such as the Eiffel Tower, the Louvre museum, and Notre-Dame cathedral, and it remains one of the most visited cities on the planet every single year."

echo "[18] PREMATURE_REPORT: siblings live + substantial agent-synthesis report -> WARNS"
LIVE_TASKDIR="$(mk_live_sibling_taskdir)"
export HMD_AGENT_TASKDIR="$LIVE_TASKDIR"
run "$LONG_REPORT"
RC=$?
unset HMD_AGENT_TASKDIR
if [ "$RC" -eq 0 ] && stderr_has "PREMATURE_REPORT"; then
  ok "substantial report while siblings are live produces a PREMATURE_REPORT warning and still exits 0"
else
  bad "expected exit 0 + PREMATURE_REPORT warning; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

echo "[19] PREMATURE_REPORT: siblings live + short holding line -> SILENT"
LIVE_TASKDIR="$(mk_live_sibling_taskdir)"
export HMD_AGENT_TASKDIR="$LIVE_TASKDIR"
run "$SHORT_HOLD"
RC=$?
unset HMD_AGENT_TASKDIR
if [ "$RC" -eq 0 ] && [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "short holding line while siblings are live produces no warning"
else
  bad "expected silence; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

echo "[20] PREMATURE_REPORT: no siblings live + substantial agent-synthesis report -> SILENT"
export HMD_AGENT_TASKDIR="$AGENTS_ENV_SANDBOX/no-siblings-tasks"
run "$LONG_REPORT"
RC=$?
unset HMD_AGENT_TASKDIR
if [ "$RC" -eq 0 ] && [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "substantial report with no siblings live produces no warning"
else
  bad "expected silence; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

echo "[21] PREMATURE_REPORT: plumbing failure (bin/heimdall-agents missing) -> SILENT, exit 0"
FAKEREPO="$SANDBOX/fake-repo-no-agents-tool"
mkdir -p "$FAKEREPO"
LIVE_TASKDIR="$(mk_live_sibling_taskdir)"
export HMD_AGENT_TASKDIR="$LIVE_TASKDIR"
run "$LONG_REPORT" "$FAKEREPO"
RC=$?
unset HMD_AGENT_TASKDIR
if [ "$RC" -eq 0 ] && [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "missing bin/heimdall-agents fails open: silent, exit 0"
else
  bad "expected silence; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

echo "[22] PREMATURE_REPORT: siblings live + substantial but unrelated-topic message -> SILENT"
LIVE_TASKDIR="$(mk_live_sibling_taskdir)"
export HMD_AGENT_TASKDIR="$LIVE_TASKDIR"
run "$LONG_UNRELATED"
RC=$?
unset HMD_AGENT_TASKDIR
if [ "$RC" -eq 0 ] && [ ! -s "$SANDBOX/stderr.log" ]; then
  ok "long unrelated answer with no agent vocabulary produces no warning even with siblings live"
else
  bad "expected silence; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

echo "[23] PREMATURE_REPORT: HEIMDALL_CLAIM_CHECK_REPORT_MIN_CHARS override is respected"
LIVE_TASKDIR="$(mk_live_sibling_taskdir)"
export HMD_AGENT_TASKDIR="$LIVE_TASKDIR"
export HEIMDALL_CLAIM_CHECK_REPORT_MIN_CHARS=50
run "$SHORT_HOLD"
RC=$?
unset HMD_AGENT_TASKDIR
unset HEIMDALL_CLAIM_CHECK_REPORT_MIN_CHARS
if [ "$RC" -eq 0 ] && stderr_has "PREMATURE_REPORT"; then
  ok "lowering the length threshold makes a shorter message warn -- the env override is wired"
else
  bad "expected exit 0 + PREMATURE_REPORT warning; got exit=$RC stderr=$(cat "$SANDBOX/stderr.log")"
fi

echo "[24] PREMATURE_REPORT: latency bound with a live-sibling fixture present"
LIVE_TASKDIR="$(mk_live_sibling_taskdir)"
export HMD_AGENT_TASKDIR="$LIVE_TASKDIR"
START_S=$(date +%s)
run "$LONG_REPORT"
END_S=$(date +%s)
unset HMD_AGENT_TASKDIR
ELAPSED_S=$((END_S - START_S))
if [ "$ELAPSED_S" -le 5 ]; then
  ok "invocation with a live-sibling fixture completed in ${ELAPSED_S}s (<= 5s bound)"
else
  bad "invocation took ${ELAPSED_S}s, exceeding the 5s bound"
fi

unset HMD_AGENT_SUBAGENTS_DIR HMD_AGENT_PROJECTS_DIR HMD_AGENT_REAPED_FILE

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# test/plan-slice.test.sh
# budget: ~6s solo -- one bash and at most one python per case, six heimdall-brief runs; no network, no claude.
#
# Proof for plan-slice (docs/analysis/2026-11-22-token-utilization-next.md lever 6, docs/analysis/2026-11-24-market-token-techniques.md gap 5):
# a spawned coder gets only ITS task's section of a plan, never the whole file. Plan files were read whole by the coders spawned from them
# (76, 22, 17 and 13 coders for four plans, 12.5% of a measured session's subagent Read characters), each 28-128 KB, carried through every
# later request of that agent.
#
#    1  wiring     one PreToolUse Read entry runs heimdall-plan-slice; kill-switch id in the sidecar (not locked), a recommended manifest row
#    2  slice      the section of a task, verbatim, for the five task shapes the repo's plans use (bullet, bold paragraph, `Task <id>` heading,
#                  `Task: name` heading, `T1.2` heading); a fence never ends a section; a sibling or a longer id never leaks in
#    3  refusals   an unknown id or a missing plan is exit 4 and names what exists; usage is exit 2; a cap cuts at a line and says how to Read the rest
#    4  list       ids with line ranges that agree with `slice`
#    5  brief      heimdall-brief build --plan inlines the slice and a header that says so; no --plan leaves the brief byte-for-byte as it was;
#                  an id the plan lacks refuses the brief (exit 1), an unreachable slicer is NON_VERIFIED (exit 3); the brief is a fraction of the plan
#    6  hint       the REAL command of hooks.json, fed PreToolUse payloads as a subagent sends them: an unsliced Read of a plan (the three path
#                  shapes of this repo) gets additionalContext naming the slice command and is never a deny; the main thread, a sliced Read, a small
#                  plan, a non-plan file, junk input, the off switches: no output, exit 0; nothing is written to disk
#    7  prose      agents/coder.md, agents/wave-executor.md and the spawn templates tell the agent to take the slice, not the whole plan
#
# HMD_PLAN_SLICE_ROOT points the suite at another copy of the plugin root (a mutated copy, to watch an assertion go red). bash 3.2 compatible.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${HMD_PLAN_SLICE_ROOT:-$REPO}"
SLICE="$PLUGIN/bin/heimdall-plan-slice"
BRIEF="$PLUGIN/bin/heimdall-brief"
HOOKS="$REPO/hooks/hooks.json"
META="$REPO/hooks/hooks.metadata.json"
MANIFEST="$REPO/guardrails.manifest.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d" "rc=${RC:-?} out=[$(printf '%s' "${OUT:-}" | head -c 300)] err=[$(head -c 200 "$TMP/stderr" 2>/dev/null)]"; fi; }
finish() { printf '\n  plan-slice: %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

command -v jq >/dev/null 2>&1      || { echo "FATAL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 1; }

TMP="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
HHOME="$TMP/home"           # HEIMDALL_HOME: the hook must leave it empty
USERHOME="$TMP/user"        # HOME and the working directory of every hook run
PROJ="$TMP/proj"            # the repository the plans live in
PLANS="$PROJ/docs/superpowers/plans"
mkdir -p "$HHOME" "$USERHOME" "$PLANS" "$PROJ/.planning/plans" "$PROJ/docs/analysis" "$PROJ/src"
export HEIMDALL_HOME="$HHOME" HEIMDALL_PLANNING_DIR="$TMP/planning"   # heimdall-brief keeps its protocol store here, never in the repo

# ── fixtures: the task shapes the real plans use ────────────────────────────────────────────────────────────────────────────────────
BUL="$PLANS/2026-01-01-bullets.md"            # lean-core / split-skills: a bullet per task under a Wave heading
cat > "$BUL" <<'EOF'
# Plan: bullets

## Waves

### Wave 0: measure
- **T0.1 footprint meter.** Create `bin/a`. Accept: `test -x bin/a`.
- **T0.2 runtime closure.** Create `bin/b`.
  Second line of T0.2 (MARK-T02-TAIL).
- **T0.10 tenth.** Create `bin/c`.
Disjoint: yes (MARK-DISJOINT).

### Wave 1: next
- **T1.1 profile.** Create `bin/d`. (MARK-T11-LAST)
EOF
BOLD="$PLANS/2026-01-02-bold.md"              # m1-skill-registry: a bold paragraph per task
cat > "$BOLD" <<'EOF'
# Plan: bold

### Wave 0 — contracts

**T0.1 baseline-recorder** (independent reference author)
- Deps: none.
- Acceptance: `test -x x`. (MARK-B01)

**T0.2 skills-config**
- Deps: none. (MARK-B02)

### Wave 1

**T1.1 other**
- Deps: T0.2. (MARK-B11)
EOF
HEAD4="$PLANS/2026-01-03-taskhead.md"         # seamless-update-restart: `#### Task <id>`, with a fence and a deeper heading inside
cat > "$HEAD4" <<'EOF'
# Plan: task headings

### Wave 0

#### Task W0-spike
- goal: measure (MARK-W0)
```text
# not a heading (MARK-FENCE)
#### Task fake-inside-fence
```
##### Acceptance
- `test -f x` (MARK-W0-ACC)

#### Task W1-gate
- goal: gate (MARK-W1)

### Wave 2
#### Task W2-last
- goal: last (MARK-W2)

### Wave 3: after
prose (MARK-AFTER)
EOF
NAMED="$PLANS/2026-01-04-named.md"            # the architect template: `Task: name`, field lines in bold that are NOT tasks
cat > "$NAMED" <<'EOF'
# Plan: named

#### Task: issue-ledger
- **Wave:** 1
- **Files:** Create `x` (MARK-N-FILES)
- **Acceptance criteria:**
  - [ ] `test -f x` (MARK-N-ACC)

#### Task: Login Endpoint (INDEPENDENT reviewer)
- **Wave:** 2 (MARK-N-LOGIN)
EOF
THEAD="$PLANS/2026-01-05-numbered.md"         # `### T1.2 name` headings between numbered section headings that are not tasks
cat > "$THEAD" <<'EOF'
# Plan: numbered

## 1. Inventory (MARK-INV)

### T1.1 first task
- body (MARK-H11)

### T1.2 second task
- body (MARK-H12)

## 2. Risks
risk text (MARK-RISK)
EOF
BIG="$PLANS/2026-02-02-big.md"                # a plan whose twelve tasks are about 530 characters each
awk 'BEGIN { print "# Plan: big"; print ""; print "### Wave 0"
  for (i = 1; i <= 12; i++) { printf "- **T0.%d task number %d.** ", i, i; for (j = 0; j < 14; j++) printf "filler words for the economy check. "; printf "\n" } }' > "$BIG"
printf '# Plan: small\n\n- **T1.1 only.** do it\n' > "$PROJ/.planning/PLAN-small.md"
cp "$BIG" "$PROJ/.planning/PLAN-big.md"
cp "$BIG" "$PROJ/.planning/plans/PLAN-sub.md"
cp "$BIG" "$PROJ/docs/analysis/2026-02-02-notes.md"
cp "$BIG" "$PROJ/.planning/STATE.md"
cp "$BIG" "$PROJ/src/PLAN-big.md"
cp "$BIG" "$PROJ/docs/analysis/plans.md"
[ "$(wc -c < "$BIG" | tr -d ' ')" -ge 6000 ] || { echo "FATAL: the big fixture is under 6000 bytes"; exit 1; }

lineof() { grep -n -F -- "$2" "$1" | head -n 1 | cut -d: -f1; }      # first line number holding the text
slice() { OUT="$("$SLICE" slice "$@" 2>"$TMP/stderr")"; RC=$?; }
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
lacks() { ! printf '%s' "$OUT" | grep -qF -- "$1"; }
rc_is() { [ "$RC" = "$1" ]; }
err_has() { grep -qF -- "$1" "$TMP/stderr"; }

echo "1. wiring"
CMD_HINT="$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "Read") | .hooks[]?.command | select(contains("heimdall-plan-slice"))] | first // empty' "$HOOKS")"
N_HINT="$(jq '[.hooks.PreToolUse[]? | select(.matcher == "Read") | .hooks[]? | select(.command | contains("heimdall-plan-slice"))] | length' "$HOOKS")"
if [ "$N_HINT" = 1 ]; then ok "hooks.json: exactly one PreToolUse Read entry runs heimdall-plan-slice"
else bad "hooks.json: exactly one PreToolUse Read entry runs heimdall-plan-slice" "found $N_HINT"; finish; exit 1; fi
case "$CMD_HINT" in *"hmd_hook_enabled plan-slice-hint"*) ok "the entry carries the kill-switch prefix for id plan-slice-hint" ;;
  *) bad "the entry carries the kill-switch prefix for id plan-slice-hint" ;; esac
if jq -e '[.hooks[] | select(.id == "plan-slice-hint" and .event == "PreToolUse" and .matcher == "Read" and .locked == false)] | length == 1' "$META" >/dev/null 2>&1; then
  ok "sidecar: id plan-slice-hint, PreToolUse, matcher Read, not locked"
else bad "sidecar: id plan-slice-hint, PreToolUse, matcher Read, not locked"; fi
if jq -e '[.guardrails[] | select(.id == "plan-slice-hint" and .layer == "hook" and .hook == "plan-slice-hint" and .tier == "recommended" and .fails == "open")] | length == 1' "$MANIFEST" >/dev/null 2>&1; then
  ok "guardrails manifest: a recommended, fail-open hook row for plan-slice-hint"
else bad "guardrails manifest: a recommended, fail-open hook row for plan-slice-hint"; fi

echo "2. slice"
slice --plan "$BUL" --task T0.1
L="$(lineof "$BUL" 'T0.1 footprint')"
HDR="$(printf '%s\n' "$OUT" | head -n 1)"
if rc_is 0 && [ "${HDR#PLAN SLICE (task T0.1}" != "$HDR" ] && [ "${HDR#*lines $L-$L of 13}" != "$HDR" ]; then ok "bullet T0.1: exit 0, the header names the task, its lines ($L-$L) and the plan's 13"
else bad "bullet T0.1: exit 0, the header names the task, its lines ($L-$L) and the plan's 13" "rc=$RC hdr=[$HDR]"; fi
has "T0.1 footprint meter" && lacks "T0.2 runtime" && lacks "MARK-T02-TAIL" && ok "bullet T0.1 is its own line only" || bad "bullet T0.1 is its own line only"
slice --plan "$BUL" --task T0.2
A="$(lineof "$BUL" 'T0.2 runtime')"; B="$(lineof "$BUL" 'MARK-T02-TAIL')"
HDR="$(printf '%s\n' "$OUT" | head -n 1)"
[ "${HDR#*lines $A-$B of 13}" != "$HDR" ] && ok "bullet T0.2: the header range spans the bullet and its continuation line ($A-$B)" || bad "bullet T0.2: the header range spans the bullet and its continuation line ($A-$B)" "hdr=[$HDR]"
[ "$(printf '%s' "$OUT" | tail -n +2)" = "$(sed -n "${A},${B}p" "$BUL")" ] && ok "bullet T0.2: the body is the plan's own lines, byte for byte (sed -n $A,${B}p)" || bad "bullet T0.2: the body is the plan's own lines, byte for byte"
has "MARK-T02-TAIL" && lacks "T0.10 tenth" && lacks "T0.1 footprint" && ok "bullet T0.2 keeps its continuation, stops at the next task" || bad "bullet T0.2 keeps its continuation, stops at the next task"
slice --plan "$BUL" --task T0.10
has "T0.10 tenth" && has "MARK-DISJOINT" && lacks "T0.1 footprint" && lacks "Wave 1" && lacks "T1.1 profile" && ok "bullet T0.10 (not a prefix match of T0.1): keeps the wave's trailing line, stops at the next heading" || bad "bullet T0.10 (not a prefix match of T0.1): keeps the wave's trailing line, stops at the next heading"
slice --plan "$BUL" --task T1.1
has "MARK-T11-LAST" && lacks "T0.10" && ok "bullet T1.1 runs to the end of the file" || bad "bullet T1.1 runs to the end of the file"
slice --plan "$BUL" --task t0.2
rc_is 0 && has "T0.2 runtime" && ok "an id matches case-insensitively" || bad "an id matches case-insensitively"

slice --plan "$BOLD" --task T0.1
has "MARK-B01" && has "baseline-recorder" && lacks "MARK-B02" && ok "bold paragraph T0.1: both its lines, not T0.2" || bad "bold paragraph T0.1: both its lines, not T0.2"
slice --plan "$BOLD" --task T0.2
has "MARK-B02" && lacks "MARK-B01" && lacks "MARK-B11" && lacks "Wave 1" && ok "bold paragraph T0.2: stops at the next heading" || bad "bold paragraph T0.2: stops at the next heading"

slice --plan "$HEAD4" --task W0-spike
has "MARK-W0" && has "MARK-FENCE" && has "fake-inside-fence" && has "MARK-W0-ACC" && lacks "MARK-W1" && ok "Task W0-spike: a fence and a deeper heading stay inside; the next Task heading ends it" || bad "Task W0-spike: a fence and a deeper heading stay inside; the next Task heading ends it"
slice --plan "$HEAD4" --task W2-last
has "MARK-W2" && lacks "MARK-AFTER" && lacks "Wave 3" && ok "Task W2-last: a higher-level heading ends it" || bad "Task W2-last: a higher-level heading ends it"
slice --plan "$HEAD4" --task fake-inside-fence
rc_is 4 && ok "a heading inside a code fence is not a task" || bad "a heading inside a code fence is not a task"

slice --plan "$NAMED" --task issue-ledger
has "MARK-N-FILES" && has "MARK-N-ACC" && lacks "MARK-N-LOGIN" && ok "Task: issue-ledger: bold field lines and checkboxes stay inside" || bad "Task: issue-ledger: bold field lines and checkboxes stay inside"
slice --plan "$NAMED" --task "Login Endpoint"
LOGIN_BODY="$OUT"
rc_is 0 && has "MARK-N-LOGIN" && lacks "MARK-N-ACC" && ok "Task: Login Endpoint (...): found by its name without the parenthetical" || bad "Task: Login Endpoint (...): found by its name without the parenthetical"
slice --plan "$NAMED" --task login-endpoint
[ "$OUT" = "$LOGIN_BODY" ] && ok "the same task is found by its kebab slug" || bad "the same task is found by its kebab slug"
slice --plan "$NAMED" --task "LOGIN ENDPOINT"
[ "$OUT" = "$LOGIN_BODY" ] && ok "and by its name in any case" || bad "and by its name in any case"

slice --plan "$THEAD" --task T1.1
has "MARK-H11" && lacks "MARK-H12" && lacks "MARK-INV" && ok "### T1.1: stops at the next task heading" || bad "### T1.1: stops at the next task heading"
slice --plan "$THEAD" --task T1.2
has "MARK-H12" && lacks "MARK-RISK" && ok "### T1.2: stops at a higher-level heading" || bad "### T1.2: stops at a higher-level heading"
slice --plan "$THEAD" --task 1
rc_is 4 && ok "a numbered section heading (## 1. Inventory) is not a task" || bad "a numbered section heading (## 1. Inventory) is not a task"

echo "3. refusals"
slice --plan "$BUL" --task T9.9
if rc_is 4 && err_has "T9.9" && err_has "T0.1" && err_has "T1.1"; then ok "unknown id: exit 4, stderr names the id and the ones that exist"; else bad "unknown id: exit 4, stderr names the id and the ones that exist" "rc=$RC $(cat "$TMP/stderr")"; fi
[ -z "$OUT" ] && ok "unknown id: nothing on stdout" || bad "unknown id: nothing on stdout"
slice --plan "$TMP/nope.md" --task T0.1
if rc_is 4 && err_has "nope.md"; then ok "missing plan: exit 4, stderr names the path"; else bad "missing plan: exit 4, stderr names the path"; fi
slice --plan "$PROJ" --task T0.1
rc_is 4 && ok "a directory is not a plan: exit 4" || bad "a directory is not a plan: exit 4"
slice --task T0.1
rc_is 2 && ok "no --plan: usage, exit 2" || bad "no --plan: usage, exit 2"
slice --plan "$BUL"
rc_is 2 && ok "no --task: usage, exit 2" || bad "no --task: usage, exit 2"
slice --plan "$BUL" --task T0.1 --max-chars 0
rc_is 2 && ok "--max-chars 0: usage, exit 2" || bad "--max-chars 0: usage, exit 2"
OUT="$("$SLICE" 2>/dev/null)"; RC=$?
rc_is 2 && ok "no verb: usage, exit 2" || bad "no verb: usage, exit 2"
L7="$(sed -n "${A}p" "$BUL")"
slice --plan "$BUL" --task T0.2 --max-chars $(( ${#L7} + 5 ))
if rc_is 0 && has "[hmd: slice cut at ${#L7} of" && has "offset=$B limit=1" && lacks "MARK-T02-TAIL"; then ok "--max-chars cuts at a line and names the Read that gets the rest (offset=$B limit=1)"
else bad "--max-chars cuts at a line and names the Read that gets the rest (offset=$B limit=1)" "rc=$RC"; fi
slice --plan "$BIG" --task T0.1 --max-chars 120
if rc_is 0 && has "[hmd: slice cut at 120 of" && has "offset=4 limit=1"; then ok "a single line over the cap is cut at the cap, the pointer re-reads that line"
else bad "a single line over the cap is cut at the cap, the pointer re-reads that line" "rc=$RC"; fi

echo "4. list"
OUT="$("$SLICE" list --plan "$BUL" 2>"$TMP/stderr")"; RC=$?
ids="$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ')"
[ "$RC" = 0 ] && [ "$ids" = "T0.1 T0.2 T0.10 T1.1 " ] && ok "list: every task id, in plan order" || bad "list: every task id, in plan order" "ids=[$ids] rc=$RC"
RANGE="$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "T0.2" { print $2 }')"
[ "$RANGE" = "$A-$B" ] && ok "list: the range of T0.2 is $A-$B, the one slice reports" || bad "list: the range of T0.2 is $A-$B, the one slice reports" "got [$RANGE]"
printf '%s\n' "$OUT" | awk -F'\t' '$1 == "T0.1" { found = ($3 ~ /footprint meter/) } END { exit !found }' && ok "list: a title column" || bad "list: a title column"
OUT="$("$SLICE" list --plan "$THEAD" 2>/dev/null)"
ids="$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ')"
[ "$ids" = "T1.1 T1.2 " ] && ok "list: numbered section headings are not tasks" || bad "list: numbered section headings are not tasks" "ids=[$ids]"
OUT="$("$SLICE" list --plan "$NAMED" 2>/dev/null)"
ids="$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ')"
[ "$ids" = "issue-ledger login-endpoint " ] && ok "list: a named task is listed by its kebab id" || bad "list: a named task is listed by its kebab id" "ids=[$ids]"
printf '# no tasks here\n\njust prose\n' > "$TMP/none.md"
OUT="$("$SLICE" list --plan "$TMP/none.md" 2>"$TMP/stderr")"; RC=$?
rc_is 4 && ok "list: a file with no task is exit 4" || bad "list: a file with no task is exit 4"

echo "5. brief"
brief() { OUT="$("$BRIEF" "$@" 2>&1)"; RC=$?; }
brief build --task T0.2 --spec "do T0.2" --plan "$BUL" --repo "$PROJ"
if rc_is 0 && has "PLAN SLICE (task T0.2" && has "MARK-T02-TAIL" && has "Create \`bin/b\`" && lacks "T0.1 footprint" && lacks "T1.1 profile"; then ok "build --plan: the slice is inlined, its siblings are not"
else bad "build --plan: the slice is inlined, its siblings are not" "rc=$RC"; fi
has "# Refs, plus this task's own section of the plan. Not the whole plan, not prior conversation." && lacks "# Refs only." && ok "build --plan: the header says the brief carries a plan section" || bad "build --plan: the header says the brief carries a plan section"
[ "$(printf '%s\n' "$OUT" | grep -n 'TASK SPEC:' | head -n 1 | cut -d: -f1)" -lt "$(printf '%s\n' "$OUT" | grep -n 'PLAN SLICE' | head -n 1 | cut -d: -f1)" ] && ok "build --plan: the slice follows the task spec" || bad "build --plan: the slice follows the task spec"
brief build --task T0.2 --spec "do T0.2" --repo "$PROJ"
if rc_is 0 && has "# Refs only. Not the plan, not prior conversation, not restated criteria." && lacks "PLAN SLICE"; then ok "build without --plan: the brief is as it was (refs-only header, no slice)"
else bad "build without --plan: the brief is as it was (refs-only header, no slice)" "rc=$RC"; fi
brief build --task T0.2 --spec "do T0.2" --plan "docs/superpowers/plans/2026-01-01-bullets.md" --repo "$PROJ"
rc_is 0 && has "MARK-T02-TAIL" && ok "build --plan: a relative path resolves against --repo" || bad "build --plan: a relative path resolves against --repo"
brief build --task T9.9 --spec "ghost" --plan "$BUL" --repo "$PROJ"
if rc_is 1 && has "INCOMPLETE" && has "plan task T9.9" && has "UNRESOLVED REFS"; then ok "build --plan with an id the plan lacks: refused, exit 1, the brief is INCOMPLETE"
else bad "build --plan with an id the plan lacks: refused, exit 1, the brief is INCOMPLETE" "rc=$RC"; fi
brief build --task T0.2 --spec "ghost" --plan "$TMP/nope.md" --repo "$PROJ"
rc_is 1 && has "INCOMPLETE" && ok "build --plan with a missing plan file: refused, exit 1" || bad "build --plan with a missing plan file: refused, exit 1"
OUT="$(HEIMDALL_PLAN_SLICE_BIN="$TMP/no-such-slicer" "$BRIEF" build --task T0.2 --spec "x" --plan "$BUL" --repo "$PROJ" 2>&1)"; RC=$?
if rc_is 3 && has "NON_VERIFIED"; then ok "an unreachable slicer is NON_VERIFIED, exit 3: never read as 'no slice needed'"; else bad "an unreachable slicer is NON_VERIFIED, exit 3: never read as 'no slice needed'" "rc=$RC"; fi
brief build --task T0.7 --spec "economy" --plan "$BIG" --repo "$PROJ"
BRIEF_BYTES="$(printf '%s' "$OUT" | wc -c | tr -d ' ')"; PLAN_BYTES="$(wc -c < "$BIG" | tr -d ' ')"
if rc_is 0 && has "T0.7 task number 7" && [ $((BRIEF_BYTES * 4)) -lt "$PLAN_BYTES" ]; then ok "the brief with a slice is ${BRIEF_BYTES}B against a ${PLAN_BYTES}B plan: under a quarter"
else bad "the brief with a slice is ${BRIEF_BYTES}B against a ${PLAN_BYTES}B plan: under a quarter" "rc=$RC"; fi

echo "6. hint"
BEFORE="$(find "$HHOME" -type f 2>/dev/null | sort)"
ENVX=()
fire() {
  OUT="$(printf '%s' "$2" | ( cd "$USERHOME" && env CLAUDE_PLUGIN_ROOT="$PLUGIN" HEIMDALL_HOME="$HHOME" HOME="$USERHOME" ${ENVX[@]+"${ENVX[@]}"} bash -c "$1" ) 2>"$TMP/stderr")"
  RC=$?
}
# payload AGENT PATH [OFFSET] [LIMIT] -- a Read's PreToolUse payload (AGENT empty = the main thread)
payload() {
  jq -cn --arg agent "$1" --arg p "$2" --arg off "${3:-}" --arg lim "${4:-}" '
    {session_id: "s1", transcript_path: "/x/main.jsonl", cwd: "/work", permission_mode: "default", hook_event_name: "PreToolUse",
     tool_name: "Read", tool_use_id: "toolu_01",
     tool_input: ({file_path: $p} + (if $off == "" then {} else {offset: ($off | tonumber)} end) + (if $lim == "" then {} else {limit: ($lim | tonumber)} end))}
    + (if $agent == "" then {} else {agent_id: $agent, agent_type: "hmd:coder"} end)'
}
silent() { [ "$RC" = 0 ] && [ -z "$OUT" ]; }
# hint_for PATH -- $OUT is an advisory additionalContext naming the slice command for PATH: never a deny, never a rewrite
hint_for() {
  printf '%s' "$OUT" | jq -e --arg p "$1" '
    .hookSpecificOutput.hookEventName == "PreToolUse"
    and (.hookSpecificOutput | has("permissionDecision") | not)
    and (.hookSpecificOutput | has("updatedInput") | not)
    and (.hookSpecificOutput.additionalContext
         | (contains("heimdall-plan-slice slice --plan " + $p) and contains("--task") and contains("list --plan " + $p) and (length < 900)))' >/dev/null 2>&1
}
for P in "$PLANS/2026-02-02-big.md" "$PROJ/.planning/PLAN-big.md" "$PROJ/.planning/plans/PLAN-sub.md"; do
  fire "$CMD_HINT" "$(payload agent-7 "$P")"
  chk "a subagent's unsliced Read of ${P#"$PROJ"/} gets the hint (RC=$RC)" hint_for "$P"
done
fire "$CMD_HINT" "$(payload "" "$PLANS/2026-02-02-big.md")"
chk "the main thread reads a plan whole without a word" silent
fire "$CMD_HINT" "$(payload agent-7 "$PLANS/2026-02-02-big.md" 10)"
chk "a Read with an offset is already a slice: silent" silent
fire "$CMD_HINT" "$(payload agent-7 "$PLANS/2026-02-02-big.md" "" 40)"
chk "a Read with a limit is already a slice: silent" silent
fire "$CMD_HINT" "$(payload agent-7 "$PROJ/.planning/PLAN-small.md")"
chk "a plan under 6000 bytes is not worth a hint: silent" silent
for P in "$PROJ/docs/analysis/2026-02-02-notes.md" "$PROJ/.planning/STATE.md" "$PROJ/src/PLAN-big.md" "$PROJ/docs/analysis/plans.md" "$PROJ/src/none.py"; do
  fire "$CMD_HINT" "$(payload agent-7 "$P")"
  chk "not a plan: ${P#"$PROJ"/} is silent" silent
done
fire "$CMD_HINT" "$(payload agent-7 "$PROJ/.planning/PLAN-missing.md")"
chk "a plan that does not exist: silent, the Read reports it" silent
for J in '' 'not json at all' '[1,2,3]' '{"tool_name":"Read"}' '{"agent_id":"a","tool_name":"Read","tool_input":"PLAN"}' '{"agent_id":"a","x":"PLAN","tool_name":"Read","tool_input":{"file_path":42}}'; do
  fire "$CMD_HINT" "$J"
  chk "junk input [$(printf '%s' "$J" | head -c 30)]: silent, exit 0" silent
done
fire "$CMD_HINT" "$(payload agent-7 "$PLANS/2026-02-02-big.md" | jq -c '.tool_name = "Grep"')"
chk "another tool is not a Read: silent" silent
[ "$(find "$HHOME" -type f 2>/dev/null | sort)" = "$BEFORE" ] && ok "the hook wrote nothing under HEIMDALL_HOME (it keeps no state)" || bad "the hook wrote nothing under HEIMDALL_HOME (it keeps no state)"
ENVX=(HMD_PLAN_SLICE=off)
fire "$CMD_HINT" "$(payload agent-7 "$PLANS/2026-02-02-big.md")"
chk "HMD_PLAN_SLICE=off: silent" silent
ENVX=()
printf 'plan-slice-hint\n' > "$HHOME/hooks-disabled"
fire "$CMD_HINT" "$(payload agent-7 "$PLANS/2026-02-02-big.md")"
chk "hooks-disabled lists plan-slice-hint (hmd guardrails off): silent" silent
rm -f "$HHOME/hooks-disabled"
fire "$CMD_HINT" "$(payload agent-7 "$PLANS/2026-02-02-big.md")"
chk "and the hint is back once it is removed" hint_for "$PLANS/2026-02-02-big.md"

echo "7. prose"
CODER="$REPO/agents/coder.md"; WAVE="$REPO/agents/wave-executor.md"; TPL="$REPO/skills/heimdall/references/agent-templates.md"
grep -qF 'heimdall-plan-slice' "$CODER" && grep -qF 'PLAN SLICE' "$CODER" && ok "coder.md: take the PLAN SLICE of the brief, or ask heimdall-plan-slice for it" || bad "coder.md: take the PLAN SLICE of the brief, or ask heimdall-plan-slice for it"
grep -qF 'Otherwise execute the provided plan.' "$CODER" && bad "coder.md no longer says to execute 'the provided plan' (the sentence that sent coders to read it whole)" || ok "coder.md no longer says to execute 'the provided plan' (the sentence that sent coders to read it whole)"
grep -qF 'Read `.planning/PLAN-{phase}.md`, find tasks assigned to your wave' "$WAVE" && bad "wave-executor.md no longer reads the whole plan to find its wave" || ok "wave-executor.md no longer reads the whole plan to find its wave"
grep -qF 'heimdall-plan-slice list' "$WAVE" && grep -qF -- '--plan' "$WAVE" && ok "wave-executor.md: list the tasks, brief every child with --plan" || bad "wave-executor.md: list the tasks, brief every child with --plan"
grep -qF -- '--plan' "$TPL" && grep -qF 'heimdall-plan-slice' "$TPL" && ok "agent-templates.md: the Context block is built with --plan" || bad "agent-templates.md: the Context block is built with --plan"

finish

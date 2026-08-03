#!/usr/bin/env bash
#
# agent-name-gate.test.sh — convention R13 is ENFORCED, not advisory.
#
# WHY THIS FILE EXISTS
# --------------------
# Passing `name:` to the Agent tool flips the harness into persistent MAILBOX
# mode. The tool_result says it verbatim:
#
#     "The agent is now running and will receive instructions via mailbox."
#
# Such an agent never self-terminates and never emits a task-notification. The
# orchestrator therefore waits forever for a result that CANNOT arrive, and the
# entry sits `idle` in FleetView until the session dies.
#
# Measured across 109 spawns in one real session:
#     with    name:  ->   0 of 43 ever completed
#     without name:  ->  59 of 66 completed
#
# R13 lived in skills/heimdall/SKILL.md as advice. Advice is not a gate: the
# install-side launchd guard was advisory (an opt-out env var a caller had to
# remember), it was forgotten within the hour, and it repointed a real nightly
# job at a doomed worktree. So the rule now BLOCKS, with a deliberate opt-in
# for the one legitimate case (a long-lived agent you will drive by SendMessage).
#
# WHAT THIS SUITE PROVES
# ----------------------
#   1. A spawn carrying name: is DENIED (exit 2) and the reason reaches STDERR.
#      A PreToolUse hook's block reason is read from stderr; a receipt printed
#      only to stdout renders as "No stderr output" — this repo hit exactly that
#      in the stub gate. So stderr is asserted, not assumed.
#   2. An ordinary unnamed spawn is untouched (exit 0). A gate that blocks
#      everything is not a gate, it is an outage.
#   3. HEIMDALL_ALLOW_NAMED_AGENT=1 opts in deliberately.
#   4. THE REGRESSION: a payload carrying real JSON \n escapes inside a string is
#      still parsed and judged correctly. `echo "$INPUT" | jq` corrupts such a
#      payload (macOS /bin/sh expands backslash escapes), jq exits 5, the var
#      goes empty and the gate skips ITSELF — the bug that disabled 215 of 312
#      PreToolUse:Bash invocations here. Both the named and the unnamed
#      escape-carrying payloads are asserted, so a corrupted parse cannot pass by
#      accidentally landing on the right verdict.
#   5. FAIL CLOSED: an unreadable payload does NOT become a silent allow.
#      Treating "cannot parse" as "no name present" is byte-for-byte the
#      fail-open shape above, so it is denied instead.
#
# Usage:  bash test/agent-name-gate.test.sh   (exit 0 = R13 is enforced)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"

# The escape hatch must not leak in from the caller's environment, or every deny
# assertion below would be silently opted out of and the suite would read green.
unset HEIMDALL_ALLOW_NAMED_AGENT

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "agent-name-gate (R13 enforcement)  repo=$REPO"
echo "--------------------------------------------------------------------"

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq is required for this test" >&2
  exit 1
fi
if [ ! -f "$HOOKS" ]; then
  echo "  missing $HOOKS" >&2
  exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-name-gate.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

GATE="$SANDBOX/agent-gate.sh"
OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
RC=0

# ── extract the real hook command straight out of hooks.json ────────────────
# Driving the shipped command itself (never a copy) is what makes this suite
# falsifiable: neuter the gate in hooks.json and these assertions go red.
jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | .[0].hooks[0].command // empty' \
  "$HOOKS" > "$GATE"

AGENT_MATCHERS=$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | length' "$HOOKS")

# fire <payload-file> — runs the shipped command under /bin/sh, exactly as the
# harness does. /bin/sh (not bash) is the point: that is the escape-expanding
# shell where the echo|jq defect lives.
fire() {
  (
    cd "$SANDBOX" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO" sh "$GATE" < "$1" >"$OUT" 2>"$ERR"
  )
  RC=$?
}

# fire_optin <payload-file> — same, with the deliberate escape hatch set.
fire_optin() {
  (
    cd "$SANDBOX" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO" HEIMDALL_ALLOW_NAMED_AGENT=1 sh "$GATE" < "$1" >"$OUT" 2>"$ERR"
  )
  RC=$?
}

errhas() { grep -qF "$1" "$ERR" 2>/dev/null; }

# ── 0. ANTI-VACUOUS: the thing under test actually exists ───────────────────
# A suite that extracted an empty command would "pass" every allow assertion and
# prove nothing at all. Establish the subject before judging it.
if [ ! -s "$GATE" ]; then
  bad "no PreToolUse Agent hook command found — nothing is under test, aborting"
  echo "--------------------------------------------------------------------"
  echo "  $PASS passed, $FAIL failed"
  exit 1
fi
ok "extracted the shipped PreToolUse:Agent hook command ($(wc -c <"$GATE" | tr -d ' ') bytes)"

if [ "$AGENT_MATCHERS" = "1" ]; then
  ok "exactly one PreToolUse:Agent matcher — the gate extends it, no competing hook"
else
  bad "expected 1 PreToolUse:Agent matcher, found $AGENT_MATCHERS — a competing hook was added"
fi

# ── payload fixtures ────────────────────────────────────────────────────────
NAMED="$SANDBOX/named.json"
jq -cn '{tool_name:"Agent", tool_input:{
          description:"wire the billing service",
          prompt:"implement BillingService",
          subagent_type:"hmd:coder",
          name:"billing-worker"}}' > "$NAMED"

UNNAMED="$SANDBOX/unnamed.json"
jq -cn '{tool_name:"Agent", tool_input:{
          description:"wire the billing service",
          prompt:"implement BillingService",
          subagent_type:"hmd:coder"}}' > "$UNNAMED"

# The escape-carrying pair. The description must hold REAL newlines and tabs, so
# that JSON encoding turns them into the two-character escape \n — precisely what
# `echo` expands back into a raw 0x0A mid-string, making the document invalid.
# Writing literal backslashes instead would encode to \\n, survive `echo`, and
# prove nothing.
MULTILINE=$(printf 'wire the billing service\nstep 2: reconcile\n\tstep 3: invoice\n')

ESC_NAMED="$SANDBOX/esc-named.json"
jq -cn --arg d "$MULTILINE" '{tool_name:"Agent", tool_input:{
          description:$d, prompt:$d, subagent_type:"hmd:coder",
          name:"billing-worker"}}' > "$ESC_NAMED"

ESC_UNNAMED="$SANDBOX/esc-unnamed.json"
jq -cn --arg d "$MULTILINE" '{tool_name:"Agent", tool_input:{
          description:$d, prompt:$d, subagent_type:"hmd:coder"}}' > "$ESC_UNNAMED"

MALFORMED="$SANDBOX/malformed.json"
printf '%s' '{"tool_name":"Agent","tool_input":{"description":"truncated' > "$MALFORMED"

EMPTY="$SANDBOX/empty.json"
: > "$EMPTY"

# Prove the fixture really is escape-carrying before relying on it.
if grep -q '\\n' "$ESC_NAMED" && ! grep -q '\\\\n' "$ESC_NAMED"; then
  ok "fixture carries a real JSON \\n escape (the shape that breaks echo|jq)"
else
  bad "fixture is not escape-carrying — the regression case would prove nothing"
fi

# ── 1. a NAMED spawn is denied, with an actionable reason on STDERR ─────────
fire "$NAMED"
if [ "$RC" = "2" ]; then
  ok "named spawn BLOCKED (exit 2)"
else
  bad "named spawn was NOT blocked (exit $RC) — R13 is still advisory"
fi

if [ -s "$ERR" ]; then
  ok "block reason reaches stderr (renders, instead of 'No stderr output')"
else
  bad "block reason never reached stderr — the block lands with no receipt"
fi

if errhas 'HEIMDALL_ALLOW_NAMED_AGENT'; then
  ok "reason names the escape hatch (HEIMDALL_ALLOW_NAMED_AGENT=1)"
else
  bad "reason does not name the escape hatch — the block is a dead end"
fi

if errhas 'description:'; then
  ok "reason points at description: as the way to identify the work"
else
  bad "reason does not point at description: — no actionable alternative given"
fi

if grep -qi 'mailbox' "$ERR" 2>/dev/null; then
  ok "reason explains the mailbox-resident cause"
else
  bad "reason does not explain WHY a named spawn hangs (mailbox residency)"
fi

if grep -qiE 'never (self-terminate|return)' "$ERR" 2>/dev/null; then
  ok "reason states the consequence (never self-terminates / never returns)"
else
  bad "reason does not state that a named spawn never returns"
fi

# ── 2. an ordinary UNNAMED spawn is untouched ───────────────────────────────
fire "$UNNAMED"
if [ "$RC" = "0" ]; then
  ok "unnamed spawn passes through (exit 0)"
else
  bad "unnamed spawn was blocked (exit $RC) — the gate is an outage, not a gate"
fi

if grep -q 'BIFR' "$ERR" 2>/dev/null; then
  bad "unnamed spawn emitted a block receipt — false positive"
else
  ok "unnamed spawn emits no block receipt"
fi

# ── 3. the deliberate opt-in ────────────────────────────────────────────────
fire_optin "$NAMED"
if [ "$RC" = "0" ]; then
  ok "HEIMDALL_ALLOW_NAMED_AGENT=1 lets a named spawn through (deliberate opt-in)"
else
  bad "escape hatch did not work (exit $RC) — a legitimate SendMessage agent is unbuildable"
fi

# ── 4. THE REGRESSION: escapes inside a JSON string must not corrupt judgment ─
fire "$ESC_NAMED"
if [ "$RC" = "2" ]; then
  ok "escape-carrying NAMED payload still blocked — printf parsing holds"
else
  bad "escape-carrying named payload escaped the gate (exit $RC) — the echo|jq bug is back"
fi

if grep -q 'parse error' "$ERR" 2>/dev/null; then
  bad "jq parse error on an escape-carrying payload — the gate cannot see its own input"
else
  ok "no jq parse error on an escape-carrying payload"
fi

fire "$ESC_UNNAMED"
if [ "$RC" = "0" ]; then
  ok "escape-carrying UNNAMED payload still passes — no verdict flip from escapes"
else
  bad "escape-carrying unnamed payload was blocked (exit $RC) — parsing is corrupting the verdict"
fi

# ── 5. FAIL CLOSED: an unreadable payload is not a silent bypass ────────────
fire "$MALFORMED"
if [ "$RC" != "0" ]; then
  ok "malformed payload does NOT silently allow (exit $RC)"
else
  bad "malformed payload silently ALLOWED — unparseable became 'unnamed', the fail-open shape"
fi

if [ -s "$ERR" ]; then
  ok "malformed payload still produces a reason on stderr"
else
  bad "malformed payload blocked with no explanation on stderr"
fi

fire "$EMPTY"
if [ "$RC" != "0" ]; then
  ok "empty payload does NOT silently allow (exit $RC)"
else
  bad "empty payload silently ALLOWED — jq exits 0 on empty stdin, so this must be caught explicitly"
fi

# ── 6. STRUCTURAL: the gate is wired the way it must stay wired ─────────────
CMD_TEXT=$(cat "$GATE")

case "$CMD_TEXT" in
  *tool_input.name*) ok "hook reads .tool_input.name (the field that triggers mailbox mode)" ;;
  *) bad "hook never reads .tool_input.name — nothing enforces R13" ;;
esac

if printf '%s' "$CMD_TEXT" | grep -qE "printf[[:space:]]+'%s'[[:space:]]+\"\\\$INPUT\"[[:space:]]*\|[[:space:]]*jq"; then
  ok "payload reaches jq via printf '%s' (byte-exact), not echo"
else
  bad "payload does not reach jq via printf '%s' — escape-carrying input will corrupt"
fi

if printf '%s' "$CMD_TEXT" | grep -qE "echo[[:space:]]+\"?\\\$[A-Za-z_]"; then
  bad "hook pipes a shell variable through echo — reintroduces the escape-expansion defect"
else
  ok "hook never feeds a shell variable through echo"
fi

case "$CMD_TEXT" in
  *parallelism-tracker*) ok "existing parallelism-tracker call preserved (no behaviour dropped)" ;;
  *) bad "parallelism-tracker call was dropped from the Agent hook" ;;
esac

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

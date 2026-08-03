#!/usr/bin/env bash
#
# agent-name-gate.test.sh — convention R13 WARNS; it does not block.
#
# WHY THIS FILE EXISTS
# --------------------
# Passing `name:` to the Agent tool flips the harness into persistent MAILBOX
# mode. The tool_result says it verbatim:
#
#     "The agent is now running and will receive instructions via mailbox."
#
# Such an agent never self-terminates and never emits a task-notification, so the
# spawn call itself never yields a result. Measured across 109 spawns in one real
# session:
#     with    name:  ->   0 of 43 ever completed
#     without name:  ->  59 of 66 completed
#
# That measurement still stands, and it is why R13 defaults to unnamed spawns.
#
# WHY THIS IS A WARNING AND NOT A DENY
# ------------------------------------
# The gate originally exited 2. That rested on a second claim — that the
# orchestrator had no way to close a named agent — and that claim is now FALSE.
# `TaskStop` ships in Claude Code 2.1.198+ and was granted to every spawning
# agent, so a spawner CAN close what it opens. Named agents are a supported,
# documented feature.
#
# Meanwhile the blast radius of the deny was total: this matcher fires on EVERY
# Agent spawn in EVERY project (heimdall loads via --plugin-dir), so unrelated
# repos that legitimately spawn named teammates had those spawns hard-fail. A
# convention default must not break a supported harness feature everywhere.
#
# So the hook now WARNS and lets the spawn proceed. The warning carries the one
# thing the spawner must know: nothing will come back through the spawn call, and
# the spawner owns the cleanup via TaskStop.
#
# WHAT THIS SUITE PROVES
# ----------------------
#   1. A spawn carrying name: PROCEEDS (exit 0) and a warning reaches STDERR.
#      A PreToolUse hook's message is read from stderr; a receipt printed only to
#      stdout renders as "No stderr output" — this repo hit exactly that in the
#      stub gate. So stderr is asserted, not assumed.
#   2. The warning is ACTIONABLE: it names TaskStop (the cleanup the spawner now
#      owns), the orphan-finder, the mailbox cause, and the no-result consequence.
#   3. Nothing blocks. No exit 2 anywhere, on any input, ever.
#   4. An ordinary unnamed spawn is silent — a warning on every spawn is noise,
#      and noise gets muted, which is how a signal dies.
#   5. HEIMDALL_ALLOW_NAMED_AGENT=1 SUPPRESSES the warning ("I know what I'm
#      doing"). It used to be the only way through; now it is a mute switch.
#   6. THE REGRESSION: a payload carrying real JSON \n escapes inside a string is
#      still parsed and judged correctly. `echo "$INPUT" | jq` corrupts such a
#      payload (macOS /bin/sh expands backslash escapes), jq exits 5, the var goes
#      empty and the gate skips ITSELF — the bug that disabled 215 of 312
#      PreToolUse:Bash invocations here. Both the named and the unnamed
#      escape-carrying payloads are asserted, so a corrupted parse cannot pass by
#      accidentally landing on the right verdict.
#   7. A payload the hook cannot read WARNS rather than denies. Fail-safe now
#      means "say something", never "block a spawn".
#
# Usage:  bash test/agent-name-gate.test.sh   (exit 0 = R13 warns correctly)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"

# The mute switch must not leak in from the caller's environment, or every
# warning assertion below would be silently suppressed and the suite read green.
unset HEIMDALL_ALLOW_NAMED_AGENT

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "agent-name-gate (R13 warning contract)  repo=$REPO"
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
# falsifiable: neuter the warning in hooks.json and these assertions go red.
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

# fire_muted <payload-file> — same, with the deliberate mute switch set.
fire_muted() {
  (
    cd "$SANDBOX" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO" HEIMDALL_ALLOW_NAMED_AGENT=1 sh "$GATE" < "$1" >"$OUT" 2>"$ERR"
  )
  RC=$?
}

errhas()  { grep -qF "$1" "$ERR" 2>/dev/null; }
# The warning's signature marker. Asserting on a distinctive token (not merely
# "stderr is non-empty") is what keeps "no warning" cases honest: the
# parallelism-tracker in the same hook may legitimately write to stderr too.
warned()  { grep -qF 'BIFRÖST' "$ERR" 2>/dev/null; }

# ── 0. ANTI-VACUOUS: the thing under test actually exists ───────────────────
# A suite that extracted an empty command would "pass" every proceed assertion
# and prove nothing at all. Establish the subject before judging it.
if [ ! -s "$GATE" ]; then
  bad "no PreToolUse Agent hook command found — nothing is under test, aborting"
  echo "--------------------------------------------------------------------"
  echo "  $PASS passed, $FAIL failed"
  exit 1
fi
ok "extracted the shipped PreToolUse:Agent hook command ($(wc -c <"$GATE" | tr -d ' ') bytes)"

if [ "$AGENT_MATCHERS" = "1" ]; then
  ok "exactly one PreToolUse:Agent matcher — the warning extends it, no competing hook"
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

# ── 1. a NAMED spawn PROCEEDS, and carries a warning on STDERR ──────────────
fire "$NAMED"
if [ "$RC" = "0" ]; then
  ok "named spawn PROCEEDS (exit 0) — the hook warns, it does not block"
else
  bad "named spawn was blocked (exit $RC) — a supported harness feature is hard-failing"
fi

if warned; then
  ok "warning reaches stderr (renders, instead of 'No stderr output')"
else
  bad "no warning on stderr — the spawn proceeds with the caller told nothing"
fi

# A PreToolUse hook that exits 0 must not emit a deny-shaped {"error": ...}
# document on stdout; that is the blocking contract, and shipping it at exit 0
# is an ambiguous half-block.
if grep -q '"error"' "$OUT" 2>/dev/null; then
  bad "named spawn emitted a deny-shaped {\"error\":...} on stdout — that is a block, not a warning"
else
  ok "named spawn emits no deny-shaped {\"error\":...} document"
fi

if errhas 'TaskStop'; then
  ok "warning names TaskStop — the cleanup the spawner now owns"
else
  bad "warning never names TaskStop — the caller is told to worry with no way to act"
fi

if errhas 'heimdall-agents orphans'; then
  ok "warning points at bin/heimdall-agents orphans for finding leaked agents"
else
  bad "warning does not point at the orphan finder"
fi

if errhas 'HEIMDALL_ALLOW_NAMED_AGENT'; then
  ok "warning names the mute switch (HEIMDALL_ALLOW_NAMED_AGENT=1)"
else
  bad "warning does not name the mute switch — it cannot be silenced deliberately"
fi

if errhas 'description:'; then
  ok "warning points at description: as the way to identify the work"
else
  bad "warning does not point at description: — no alternative offered"
fi

if grep -qi 'mailbox' "$ERR" 2>/dev/null; then
  ok "warning explains the mailbox-resident cause"
else
  bad "warning does not explain WHY a named spawn never reports (mailbox residency)"
fi

if grep -qiE 'never (self-terminate|return)' "$ERR" 2>/dev/null; then
  ok "warning states the consequence (never self-terminates / never returns a result)"
else
  bad "warning does not state that a named spawn never returns a result"
fi

# The measured evidence is the whole reason the default is unnamed. Losing it
# turns the warning into an unfalsifiable opinion.
if grep -qE '0 of 43|0/43' "$ERR" 2>/dev/null; then
  ok "warning keeps the measurement (0 of 43 named completed vs 59 of 66 unnamed)"
else
  bad "warning dropped the measured evidence — the advice is now unfalsifiable"
fi

# ── 2. an ordinary UNNAMED spawn is silent ──────────────────────────────────
fire "$UNNAMED"
if [ "$RC" = "0" ]; then
  ok "unnamed spawn passes through (exit 0)"
else
  bad "unnamed spawn was blocked (exit $RC) — the hook is an outage, not a notice"
fi

if warned; then
  bad "unnamed spawn emitted a warning — false positive, and noise gets muted"
else
  ok "unnamed spawn emits no warning"
fi

# ── 3. the deliberate mute switch ───────────────────────────────────────────
fire_muted "$NAMED"
if [ "$RC" = "0" ]; then
  ok "HEIMDALL_ALLOW_NAMED_AGENT=1 + named spawn still proceeds (exit 0)"
else
  bad "mute switch broke the spawn (exit $RC) — opting in must never be worse than not"
fi

if warned; then
  bad "HEIMDALL_ALLOW_NAMED_AGENT=1 did NOT suppress the warning — the mute switch is dead"
else
  ok "HEIMDALL_ALLOW_NAMED_AGENT=1 suppresses the warning (deliberate opt-in)"
fi

# ── 4. THE REGRESSION: escapes inside a JSON string must not corrupt judgment ─
# If `echo|jq` ever comes back, jq exits 5, NAME goes empty, and the named case
# below silently stops warning. Asserting exit 0 alone would NOT catch that (the
# broken hook also exits 0), so the warning itself is the assertion that bites.
fire "$ESC_NAMED"
if [ "$RC" = "0" ]; then
  ok "escape-carrying NAMED payload proceeds (exit 0)"
else
  bad "escape-carrying named payload was blocked (exit $RC)"
fi

if warned; then
  ok "escape-carrying NAMED payload still WARNS — printf parsing holds"
else
  bad "escape-carrying named payload produced no warning — the echo|jq bug is back"
fi

if grep -q 'parse error' "$ERR" 2>/dev/null; then
  bad "jq parse error on an escape-carrying payload — the hook cannot see its own input"
else
  ok "no jq parse error on an escape-carrying payload"
fi

fire "$ESC_UNNAMED"
if [ "$RC" = "0" ]; then
  ok "escape-carrying UNNAMED payload proceeds (exit 0)"
else
  bad "escape-carrying unnamed payload was blocked (exit $RC)"
fi

if warned; then
  bad "escape-carrying UNNAMED payload warned — parsing is corrupting the verdict"
else
  ok "escape-carrying UNNAMED payload stays silent — no verdict flip from escapes"
fi

# ── 5. FAIL-SAFE now means WARN, never BLOCK ────────────────────────────────
fire "$MALFORMED"
if [ "$RC" = "0" ]; then
  ok "malformed payload does NOT block the spawn (exit 0)"
else
  bad "malformed payload blocked the spawn (exit $RC) — a bad payload must never cost a spawn"
fi

if warned; then
  ok "malformed payload still warns (unreadable is not silently 'unnamed')"
else
  bad "malformed payload passed silently — an unverifiable spawn with no notice"
fi

fire "$EMPTY"
if [ "$RC" = "0" ]; then
  ok "empty payload does NOT block the spawn (exit 0)"
else
  bad "empty payload blocked the spawn (exit $RC)"
fi

if warned; then
  ok "empty payload still warns (jq exits 0 on empty stdin, so this is caught explicitly)"
else
  bad "empty payload passed silently — absence of name: was assumed, not verified"
fi

# ── 6. STRUCTURAL: the hook is wired the way it must stay wired ─────────────
CMD_TEXT=$(cat "$GATE")

case "$CMD_TEXT" in
  *tool_input.name*) ok "hook reads .tool_input.name (the field that triggers mailbox mode)" ;;
  *) bad "hook never reads .tool_input.name — nothing implements R13" ;;
esac

# The load-bearing downgrade assertion. A behavioural test can only sample the
# payloads it thought of; this one proves no input at all can produce a block.
if printf '%s' "$CMD_TEXT" | grep -qE 'exit[[:space:]]+2'; then
  bad "hook still contains an 'exit 2' — some input path can still DENY a spawn"
else
  ok "hook contains no 'exit 2' — no input path can block a spawn"
fi

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

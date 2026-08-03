#!/usr/bin/env bash
#
# hook-payload-escaping.test.sh — a hook must survive a REALISTIC payload.
#
# WHY: hooks receive their payload as JSON on stdin. Real payloads carry escape
# sequences: every Write of a multi-line file puts "\n" inside .tool_input.content,
# every Bash command with a quoted string or a tab puts "\n"/"\t"/"\\" inside
# .tool_input.command. The hooks then re-emit that JSON into jq to read a field.
#
# The trap: on macOS /bin/sh is bash in POSIX mode, where the `echo` builtin
# EXPANDS backslash escapes (xpg_echo). So `echo "$INPUT" | jq` turns the two
# characters \ n — legal, escaped, inside a JSON string — into a raw 0x0A byte
# inside that same string. jq then rejects the whole document:
#
#   jq: parse error: Invalid string: control characters from U+0000 through
#   U+001F must be escaped
#
# jq exits non-zero, the command substitution yields EMPTY, and the guard that
# was supposed to run is skipped by its own `if [ -n "$VAR" ]`. Nothing errors.
# Nothing logs. The gate reports success by saying nothing at all.
#
# Measured blast radius when this regressed (one live session transcript):
#   215 of 312 PreToolUse:Bash invocations died on this parse error — i.e. the
#   pre-push quality-gate / secret-scan / oracle chain never saw the command it
#   was gating, and the edit ledger stayed empty across the whole session.
#
# `printf '%s'` is byte-exact and has no escape processing. That is the fix, and
# the invariant this file locks shut.
#
# Guarantees proved:
#   1. The edit-logging PostToolUse hook records the path when fed a payload
#      whose content carries \n and \t (the shape of every real multi-line edit).
#   2. The PreToolUse Bash gate extracts .tool_input.command intact from a
#      payload carrying escapes — no jq parse error on stderr.
#   3. STRUCTURAL, class-level: no hook command anywhere in hooks.json pipes a
#      shell variable into jq via `echo`. This is what stops the next hook from
#      reintroducing the same silent skip.
#   4. The PreToolUse stub gate reports its block reason on STDERR. An exit-2
#      hook is read for its reason on stderr; a reason printed only to stdout is
#      invisible ("No stderr output"), so the block lands with no receipt.
#
# Usage:  bash test/hook-payload-escaping.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
TRACKER="$REPO/bin/edit-tracker"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "hook-payload-escaping harness  repo=$REPO"
echo "--------------------------------------------------------------------"

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq is required for this test" >&2
  exit 1
fi
if [ ! -f "$HOOKS" ]; then
  echo "  missing $HOOKS" >&2
  exit 1
fi
if [ ! -x "$TRACKER" ] && [ -f "$REPO/bin/edit-tracker.c" ]; then
  clang -O2 -Wall -Wextra -o "$TRACKER" "$REPO/bin/edit-tracker.c" 2>/dev/null || true
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hook-payload-escaping.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# The content must hold REAL newlines and tabs. Claude Code JSON-encodes the file
# body, so a real 0x0A becomes the two-character escape \n inside the payload —
# and that is precisely what `echo` expands back into a raw 0x0A, mid-string,
# making the JSON invalid. Building this with literal backslashes instead would
# encode to \\n, which survives `echo` and would prove nothing.
REALISTIC_CONTENT=$(printf '#!/bin/sh\nset -e\n\techo hi\n')

extract_cmd() { # $1 = jq filter selecting the entry, prints .hooks[0].command
  jq -r "$1" "$HOOKS"
}

# --- 1. edit-logging hook survives a realistic Write payload -----------------
HOOK_CMD="$SANDBOX/post-edit-hook.sh"
extract_cmd '
  [.hooks.PostToolUse[]
   | select(any(.hooks[]?; .command != null
       and ((.command | contains("edit-tracker\" log")) or (.command | contains("edit-tracker log")))))]
  | .[0].hooks[0].command' > "$HOOK_CMD"

if [ ! -s "$HOOK_CMD" ]; then
  bad "could not locate the edit-logging PostToolUse hook command"
elif [ ! -x "$TRACKER" ]; then
  bad "bin/edit-tracker is not executable — cannot prove end-to-end logging"
else
  SID="hook-payload-escaping-write"
  TARGET="$SANDBOX/realistic-probe.sh"
  printf 'probe\n' > "$TARGET"

  PAYLOAD="$SANDBOX/payload-write.json"
  jq -cn --arg p "$TARGET" --arg c "$REALISTIC_CONTENT" \
    '{tool_name:"Write", tool_input:{file_path:$p, content:$c}, tool_response:{success:true}}' \
    > "$PAYLOAD"

  # Prove the fixture is the shape we claim: the JSON must carry a two-character
  # \n escape (backslash, n) and must NOT carry a doubled \\n, which `echo` would
  # merely collapse to a still-valid \n and so would not exercise the bug.
  if grep -q '\\n' "$PAYLOAD" && ! grep -q '\\\\n' "$PAYLOAD"; then
    ok "fixture payload carries a real JSON \\n escape (the shape that breaks echo)"
  else
    bad "fixture payload is not escape-carrying — the test would prove nothing"
  fi

  (
    cd "$SANDBOX" || exit 1
    TMPDIR="$SANDBOX" \
    CLAUDE_CODE_SESSION_ID="$SID" \
    CLAUDE_PLUGIN_ROOT="$REPO" \
      sh "$HOOK_CMD" < "$PAYLOAD" >/dev/null 2>"$SANDBOX/post-stderr.txt"
  )

  LOGGED=$(TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" "$TRACKER" paths 2>/dev/null)
  if printf '%s\n' "$LOGGED" | grep -qF "$TARGET"; then
    ok "edit-logging hook records a realistic (escape-carrying) Write payload"
  else
    bad "edit-logging hook LOST a realistic Write payload (ledger: '${LOGGED:-<empty>}')"
  fi

  if grep -q 'parse error' "$SANDBOX/post-stderr.txt" 2>/dev/null; then
    bad "edit-logging hook emitted a jq parse error on a realistic payload"
  else
    ok "edit-logging hook parses a realistic payload without a jq error"
  fi
fi

# --- 2. PreToolUse Bash gate extracts the command intact --------------------
BASH_CMD="$SANDBOX/pre-bash-hook.sh"
extract_cmd '
  [.hooks.PreToolUse[] | select(.matcher == "Bash")]
  | .[0].hooks[0].command' > "$BASH_CMD"

if [ ! -s "$BASH_CMD" ]; then
  bad "could not locate the PreToolUse Bash hook command"
else
  # A benign command, so no real gate (commit/push) is triggered — the point is
  # only whether jq can still read .tool_input.command out of the payload.
  BPAYLOAD="$SANDBOX/payload-bash.json"
  jq -cn --arg c 'ls -la' --arg d "$REALISTIC_CONTENT" \
    '{tool_name:"Bash", tool_input:{command:$c, description:$d}}' > "$BPAYLOAD"

  (
    cd "$SANDBOX" || exit 1
    CLAUDE_PLUGIN_ROOT="$REPO" sh "$BASH_CMD" < "$BPAYLOAD" \
      >/dev/null 2>"$SANDBOX/bash-stderr.txt"
  )

  if grep -q 'parse error' "$SANDBOX/bash-stderr.txt" 2>/dev/null; then
    bad "PreToolUse Bash gate hit a jq parse error — the command it gates is invisible to it"
  else
    ok "PreToolUse Bash gate reads .tool_input.command from an escape-carrying payload"
  fi
fi

# --- 3. structural: no hook pipes a shell variable into jq via echo ---------
# This is the class-level guard. Behavioural tests above cover two hooks; this
# covers every hook that exists now or is added later.
ECHO_JQ=$(jq -r '
  [ .hooks[][] | .hooks[]? | .command // "" ]
  | map(select(test("echo[[:space:]]+\"\\$[A-Za-z_][A-Za-z0-9_]*\"[[:space:]]*\\|[[:space:]]*jq")))
  | length' "$HOOKS")
if [ "$ECHO_JQ" = "0" ]; then
  ok "no hook command pipes a shell variable into jq via echo"
else
  bad "$ECHO_JQ hook command(s) pipe a variable into jq via echo — use printf '%s'"
fi

# `echo "$VAR" | grep` mangles the same way; a gate that greps a mangled command
# string can miss the very pattern it exists to catch.
ECHO_GREP=$(jq -r '
  [ .hooks[][] | .hooks[]? | .command // "" ]
  | map(select(test("echo[[:space:]]+\"\\$[A-Za-z_][A-Za-z0-9_]*\"[[:space:]]*\\|[[:space:]]*grep")))
  | length' "$HOOKS")
if [ "$ECHO_GREP" = "0" ]; then
  ok "no hook command pipes a shell variable into grep via echo"
else
  bad "$ECHO_GREP hook command(s) pipe a variable into grep via echo — use printf '%s\\n'"
fi

# --- 4. the stub gate's block reason reaches stderr -------------------------
STUB_CMD="$SANDBOX/pre-stub-hook.sh"
# Select on the stub gate's OWN receipt text, not on the shared "BIFRÖST" brand.
# Every Heimdall block gate emits a BIFRÖST receipt, so `contains("BIFR")` stops
# identifying anything as soon as a second one exists — it silently resolved to
# the PreToolUse:Agent gate (R13 name enforcement) and this block fed a Write
# payload to a hook that judges Agent spawns. A selector that can drift onto the
# wrong hook proves nothing about the hook it names.
extract_cmd '
  [.hooks.PreToolUse[]
   | select(any(.hooks[]?; (.command // "") | contains("blocked a stub")))]
  | .[0].hooks[0].command' > "$STUB_CMD"

if [ ! -s "$STUB_CMD" ]; then
  bad "could not locate the PreToolUse stub gate command"
else
  # Built at runtime so this test file itself never contains a blocked shape.
  MARKER=$(printf '%s%s' 'NotImplemented' 'Error')
  BAIT=$(printf 'function f() { throw new %s; }\n' "$MARKER")
  SPAYLOAD="$SANDBOX/payload-stub.json"
  jq -cn --arg p "$SANDBOX/stub-probe.js" --arg c "$BAIT" \
    '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}' > "$SPAYLOAD"

  (
    cd "$SANDBOX" || exit 1
    CLAUDE_PLUGIN_ROOT="$REPO" sh "$STUB_CMD" < "$SPAYLOAD" \
      >"$SANDBOX/stub-stdout.txt" 2>"$SANDBOX/stub-stderr.txt"
  )
  STUB_RC=$?

  if [ "$STUB_RC" = "2" ]; then
    ok "stub gate still BLOCKS (exit 2) — blocking behaviour intact"
  else
    bad "stub gate did NOT block a not-implemented marker (exit $STUB_RC)"
  fi

  if grep -q 'BIFR' "$SANDBOX/stub-stderr.txt" 2>/dev/null; then
    ok "stub gate's block reason reaches stderr (the receipt renders)"
  else
    bad "stub gate's block reason never reaches stderr — the block lands with no receipt"
  fi
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

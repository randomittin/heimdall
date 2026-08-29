#!/usr/bin/env bash
#
# edit-hook-matcher.test.sh — the edit-logging PostToolUse hook must be able to
# match every tool it claims to cover.
#
# WHY: CLAUDE.md promises "All Write/Edit ops auto-logged by edit-tracker
# (PostToolUse hook)". That promise is only as good as the hook's `matcher`.
# A matcher is a silent failure surface: if it does not name a tool, the hook
# simply never fires for it — no error, no log line, no warning. The ledger just
# stays empty, and every downstream consumer (verify-edits, summary-card) reports
# on a session it never actually observed. A matcher that cannot match the tools
# it claims to cover is indistinguishable, from the outside, from a session that
# made no edits.
#
# The specific gap this locks shut: the matcher named only `Write|Edit`, so the
# file-mutating tools `NotebookEdit` and `MultiEdit` were not named at all. They
# matched only if the harness happened to apply the matcher as an unanchored
# substring regex ("NotebookEdit" contains "Edit") — an undocumented harness
# implementation detail that must never be load-bearing. Coverage is asserted
# here under ANCHORED (full-match) semantics, which holds under both readings.
#
# Guarantees proved:
#   1. hooks/hooks.json is valid JSON (jq . exit 0).
#   2. Exactly one PostToolUse entry is responsible for edit logging (its command
#      invokes `edit-tracker log`) — so there is a single unambiguous matcher.
#   3. That matcher, as an ANCHORED alternation, matches each of the file-editing
#      tools by name: Write, Edit, MultiEdit, NotebookEdit.
#   4. It does NOT match unrelated tools (Bash, Read, Grep, Glob, Agent) — the
#      test would otherwise pass for a catch-all matcher that logs everything.
#   5. The edit-logging hook command actually records an edit end-to-end when fed
#      a representative PostToolUse payload for each covered tool.
#   6. Every other live hook event survives: UserPromptSubmit, PreToolUse,
#      SessionStart and SessionEnd are all still present with commands intact.
#
# Usage:  bash test/edit-hook-matcher.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
TRACKER="$REPO/bin/edit-tracker"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "edit-hook-matcher harness  repo=$REPO"
echo "--------------------------------------------------------------------"

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq is required for this test" >&2
  exit 1
fi
if [ ! -f "$HOOKS" ]; then
  echo "  missing $HOOKS" >&2
  exit 1
fi

# --- 1. hooks.json is valid JSON -------------------------------------------
if jq . "$HOOKS" >/dev/null 2>&1; then
  ok "hooks.json is valid JSON"
else
  bad "hooks.json is not valid JSON — nothing below is meaningful"
  echo "--------------------------------------------------------------------"
  echo "  $PASS passed, $((FAIL+1)) failed"
  exit 1
fi

# --- 2. exactly one PostToolUse entry owns edit logging ----------------------
# Identify it by behaviour (its command invokes `edit-tracker log`), never by
# array index, so reordering the file cannot silently retarget this test.
OWNERS=$(jq -r '
  [.hooks.PostToolUse[]
   | select(any(.hooks[]?; .command != null and (.command | contains("edit-tracker\" log") or contains("edit-tracker log"))))]
  | length' "$HOOKS")

if [ "$OWNERS" = "1" ]; then
  ok "exactly one PostToolUse entry invokes 'edit-tracker log'"
else
  bad "expected exactly 1 PostToolUse entry invoking 'edit-tracker log', found $OWNERS"
fi

MATCHER=$(jq -r '
  [.hooks.PostToolUse[]
   | select(any(.hooks[]?; .command != null and (.command | contains("edit-tracker\" log") or contains("edit-tracker log"))))]
  | .[0].matcher // ""' "$HOOKS")

if [ -n "$MATCHER" ]; then
  ok "edit-logging matcher is present: '$MATCHER'"
else
  bad "edit-logging PostToolUse entry has no matcher"
fi

# --- 3/4. matcher coverage under ANCHORED semantics --------------------------
# `matches_anchored <tool>` asks: does the matcher, read as a full-match regex,
# accept this tool name? grep -E with ^...$ gives exactly that. Anchoring is the
# strict reading: any matcher passing here also matches under the looser
# substring reading, so the assertion holds whichever the harness uses.
matches_anchored() {
  grep -qE "^($MATCHER)$" <<<"$1"
}

for TOOL in Write Edit MultiEdit NotebookEdit; do
  if matches_anchored "$TOOL"; then
    ok "matcher covers file-editing tool '$TOOL'"
  else
    bad "matcher '$MATCHER' does NOT match '$TOOL' — edits by $TOOL are never logged"
  fi
done

for TOOL in Bash Read Grep Glob Agent; do
  if matches_anchored "$TOOL"; then
    bad "matcher '$MATCHER' also matches non-editing tool '$TOOL' (catch-all)"
  else
    ok "matcher correctly excludes non-editing tool '$TOOL'"
  fi
done

# --- 5. the hook command really logs, for every covered tool -----------------
# Run the actual command string from hooks.json against a representative
# PostToolUse payload, in an isolated ledger root, and assert the path lands.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/edit-hook-matcher.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# Never rebuild onto the tracked $REPO/bin/edit-tracker — a test must not
# mutate a committed binary (test/run-all.sh's tree-integrity check flags
# exactly that). If the real one isn't usable, build a throwaway copy inside
# the sandbox instead and point TRACKER at it.
if [ ! -x "$TRACKER" ] && [ -f "$REPO/bin/edit-tracker.c" ]; then
  clang -O2 -Wall -Wextra -o "$SANDBOX/edit-tracker" "$REPO/bin/edit-tracker.c" 2>/dev/null || true
  [ -x "$SANDBOX/edit-tracker" ] && TRACKER="$SANDBOX/edit-tracker"
fi

if [ ! -x "$TRACKER" ]; then
  bad "bin/edit-tracker is not executable — cannot prove end-to-end logging"
else
  HOOK_CMD="$SANDBOX/hook-cmd.sh"
  jq -r '
    [.hooks.PostToolUse[]
     | select(any(.hooks[]?; .command != null and (.command | contains("edit-tracker\" log") or contains("edit-tracker log"))))]
    | .[0].hooks[0].command' "$HOOKS" > "$HOOK_CMD"

  for TOOL in Write Edit MultiEdit NotebookEdit; do
    SID="edit-hook-matcher-$TOOL"
    TARGET="$SANDBOX/probe-$TOOL.txt"
    printf 'probe for %s\n' "$TOOL" > "$TARGET"

    # tool_input shape differs per tool: NotebookEdit carries `notebook_path`
    # where Write/Edit/MultiEdit carry `file_path`. Feeding each tool its REAL
    # key is the point — a hook that only reads `file_path` silently logs
    # nothing for NotebookEdit, which is exactly the failure mode under test.
    PAYLOAD="$SANDBOX/payload-$TOOL.json"
    if [ "$TOOL" = "NotebookEdit" ]; then
      jq -cn --arg t "$TOOL" --arg p "$TARGET" \
        '{tool_name:$t, tool_input:{notebook_path:$p}}' > "$PAYLOAD"
    else
      jq -cn --arg t "$TOOL" --arg p "$TARGET" \
        '{tool_name:$t, tool_input:{file_path:$p}}' > "$PAYLOAD"
    fi

    # Isolated TMPDIR + session id => the real session ledger is never touched.
    # cwd is the sandbox so the hook's autocommit/state branches stay inert.
    (
      cd "$SANDBOX" || exit 1
      TMPDIR="$SANDBOX" \
      CLAUDE_CODE_SESSION_ID="$SID" \
      CLAUDE_PLUGIN_ROOT="$REPO" \
        bash "$HOOK_CMD" < "$PAYLOAD" >/dev/null 2>&1
    )

    LOGGED=$(TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" "$TRACKER" paths 2>/dev/null)
    if grep -qF "$TARGET" <<<"$LOGGED"; then
      ok "hook command records a '$TOOL' payload in the ledger"
    else
      bad "hook command did NOT record a '$TOOL' payload (ledger: '${LOGGED:-<empty>}')"
    fi
  done
fi

# --- 6. no collateral damage to the other live hook events -------------------
for EVENT in UserPromptSubmit PreToolUse SessionStart SessionEnd PostToolUse; do
  N=$(jq -r --arg e "$EVENT" '(.hooks[$e] // []) | length' "$HOOKS")
  if [ "${N:-0}" -ge 1 ]; then
    ok "$EVENT still registered ($N entr$([ "$N" = 1 ] && echo y || echo ies))"
  else
    bad "$EVENT lost all entries"
  fi
done

# Every registered hook must still carry a non-empty command; an entry that
# parses but has an empty command is a hook that silently does nothing.
EMPTY=$(jq -r '[.hooks[][] | .hooks[]? | select((.command // "") == "")] | length' "$HOOKS")
if [ "$EMPTY" = "0" ]; then
  ok "every registered hook has a non-empty command"
else
  bad "$EMPTY registered hook(s) have an empty command"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

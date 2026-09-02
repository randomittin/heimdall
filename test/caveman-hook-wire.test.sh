#!/usr/bin/env bash
#
# caveman-hook-wire.test.sh — hmd's OWN caveman level must actually reach the
# model every turn, not just live as an unused value in bin/heimdall-caveman.
#
# WHY THIS FILE EXISTS
# --------------------
# CLAUDE.md's "Token Efficiency" section documents hmd owning the caveman
# level in-house (bin/heimdall-caveman, single settable level: ultra) as of
# 2026-08-30/09-01. That ownership was worthless in practice until this
# change: `grep -c caveman hooks/hooks.json` was 0 — nothing in the actual
# hook chain ever called bin/heimdall-caveman, so every turn was still
# reinforced only by the EXTERNAL plugin's own UserPromptSubmit hook, at
# THAT plugin's level (observed diverging to 'full' while hmd stored
# 'ultra' — see bin/heimdall-caveman's own "DIVERGENCE" header). Measured
# against a 30-prompt corpus: hmd's ultra output is 12311 tokens vs the
# plugin-era 'full' baseline of 15847 — a real 22.3% saving that was
# reaching exactly zero live sessions because nothing wired it in.
#
# This suite proves the FIX, not just its presence: it runs the ACTUAL
# command string out of hooks.json (not a copy, not a paraphrase) through
# /bin/sh — the same interpreter Claude Code's hook runner uses — and reads
# its real stdout.
#
# GUARANTEES PROVED
#   1. hooks/hooks.json stays valid JSON (jq . exit 0).
#   2. Exactly one UserPromptSubmit entry wires bin/heimdall-caveman.
#   3. All 3 pre-existing UserPromptSubmit entries (parallel-gate,
#      heimdall-ctx-meter, heimdall-secret-filter) survive, in their
#      original order, with the new entry appended after them — never
#      inserted in the middle, never replacing one.
#   4. The new entry carries no stray "matcher" key, consistent with the
#      other 3 UserPromptSubmit entries (matchers only appear under
#      PreToolUse / PostToolUse in this file).
#   5. RED-PROOF (positive): running the real command emits hmd's actual
#      resolved level and the real "HMD OUTPUT COMPRESSION" header — not a
#      placeholder, not the external plugin's own "CAVEMAN MODE ACTIVE"
#      text.
#   6. RED-PROOF (fail-open, 3 cases): heimdall-caveman missing, present but
#      not executable, and present-but-broken (executable, always exits 1)
#      all leave the hook exiting 0 with EMPTY stdout — never a wedge,
#      never a half-written JSON line.
#
# Usage:  bash test/caveman-hook-wire.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "caveman-hook-wire harness  repo=$REPO"
echo "--------------------------------------------------------------------"

if ! command -v jq >/dev/null 2>&1; then
  echo "  jq is required for this test" >&2
  exit 1
fi
if [ ! -f "$HOOKS" ]; then
  echo "  missing $HOOKS" >&2
  exit 1
fi

# --- 1. hooks.json is valid JSON --------------------------------------------
if jq . "$HOOKS" >/dev/null 2>&1; then
  ok "hooks.json is valid JSON"
else
  bad "hooks.json is not valid JSON — nothing below is meaningful"
  echo "--------------------------------------------------------------------"
  echo ""
  echo "RESULT: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi

# --- 2. exactly one UserPromptSubmit entry wires heimdall-caveman -----------
CAVEMAN_OWNERS=$(jq -r '
  [.hooks.UserPromptSubmit[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-caveman"))))]
  | length' "$HOOKS")

if [ "$CAVEMAN_OWNERS" = "1" ]; then
  ok "exactly one UserPromptSubmit entry wires bin/heimdall-caveman"
else
  bad "expected exactly 1 UserPromptSubmit entry invoking heimdall-caveman, found $CAVEMAN_OWNERS"
fi

# --- 3. pre-existing entries + order survive --------------------------------
TOTAL=$(jq -r '(.hooks.UserPromptSubmit // []) | length' "$HOOKS")
if [ "${TOTAL:-0}" = "4" ]; then
  ok "UserPromptSubmit now has exactly 4 entries (3 pre-existing + hmd caveman)"
else
  bad "expected exactly 4 UserPromptSubmit entries, found ${TOTAL:-0}"
fi

IDX0=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command // ""' "$HOOKS")
IDX1=$(jq -r '.hooks.UserPromptSubmit[1].hooks[0].command // ""' "$HOOKS")
IDX2=$(jq -r '.hooks.UserPromptSubmit[2].hooks[0].command // ""' "$HOOKS")
IDX3=$(jq -r '.hooks.UserPromptSubmit[3].hooks[0].command // ""' "$HOOKS")

case "$IDX0" in
  *parallel-gate*) ok "entry[0] is still parallel-gate" ;;
  *) bad "entry[0] is no longer parallel-gate: '$IDX0'" ;;
esac
case "$IDX1" in
  *heimdall-ctx-meter*) ok "entry[1] is still heimdall-ctx-meter" ;;
  *) bad "entry[1] is no longer heimdall-ctx-meter: '$IDX1'" ;;
esac
case "$IDX2" in
  *heimdall-secret-filter*) ok "entry[2] is still heimdall-secret-filter" ;;
  *) bad "entry[2] is no longer heimdall-secret-filter: '$IDX2'" ;;
esac
case "$IDX3" in
  *heimdall-caveman*) ok "entry[3] (new, appended last) wires heimdall-caveman" ;;
  *) bad "entry[3] does not wire heimdall-caveman — new entry was not appended last: '$IDX3'" ;;
esac

# --- 4. structural consistency: no stray "matcher" key ----------------------
# Guarded on CAVEMAN_OWNERS==1: with no unique entry to inspect, jq's .[0] on
# an empty selection is null, and `null | has("matcher")` reads "false" —
# a VACUOUS pass that would misreport "consistent" when there is nothing to
# be consistent. This repo's own gate-echo-parser-guard.test.sh treats an
# unproven check as a failure, not a silent skip; this follows the same rule.
if [ "$CAVEMAN_OWNERS" = "1" ]; then
  HAS_MATCHER=$(jq -r '
    [.hooks.UserPromptSubmit[]
     | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-caveman"))))]
    | .[0] | has("matcher")' "$HOOKS")
  if [ "$HAS_MATCHER" = "false" ]; then
    ok "new entry has no 'matcher' key, consistent with the other 3 UserPromptSubmit entries"
  else
    bad "new entry unexpectedly carries a 'matcher' key"
  fi
else
  bad "cannot verify matcher-key consistency — no unique heimdall-caveman entry found (see assertion 2)"
fi

# --- 5. RED-PROOF (positive): the real command emits hmd's real ultra text -
CMD=$(jq -r '
  [.hooks.UserPromptSubmit[]
   | select(any(.hooks[]?; .command != null and (.command | contains("heimdall-caveman"))))]
  | .[0].hooks[0].command // empty' "$HOOKS")

if [ -z "$CMD" ]; then
  bad "could not extract the heimdall-caveman command string from hooks.json — skipping behavioral proofs"
else
  EXPECTED_LVL=$("$REPO/bin/heimdall-caveman" get 2>/dev/null)
  OUT=$(CLAUDE_PLUGIN_ROOT="$REPO" /bin/sh -c "$CMD" 2>/dev/null)
  RC=$?

  if [ "$RC" -eq 0 ]; then
    ok "hook exits 0 on the real repo (heimdall-caveman present and working)"
  else
    bad "hook exited $RC on the real repo — expected 0"
  fi

  if printf '%s' "$OUT" | grep -q "HMD OUTPUT COMPRESSION"; then
    ok "hook emits hmd's real compression header ('HMD OUTPUT COMPRESSION'), not a placeholder"
  else
    bad "hook did not emit the expected compression header; got: '$OUT'"
  fi

  if [ -n "$EXPECTED_LVL" ] && printf '%s' "$OUT" | grep -qF "level: $EXPECTED_LVL"; then
    ok "hook reports hmd's real resolved level ('$EXPECTED_LVL'), matching 'heimdall-caveman get' directly"
  else
    bad "hook did not report the level 'heimdall-caveman get' resolves to ('$EXPECTED_LVL'); got: '$OUT'"
  fi

  if printf '%s' "$OUT" | grep -q "heimdall-caveman rules"; then
    ok "hook points at 'heimdall-caveman rules' as the source of truth for the full ruleset"
  else
    bad "hook does not reference 'heimdall-caveman rules'; got: '$OUT'"
  fi

  if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and (.hookSpecificOutput.additionalContext | length > 0)' >/dev/null 2>&1; then
    ok "hook output matches the UserPromptSubmit hookSpecificOutput contract"
  else
    bad "hook output does not match the UserPromptSubmit hookSpecificOutput contract; got: '$OUT'"
  fi

  # --- 6. RED-PROOF (fail-open): missing / non-executable / broken ---------
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/caveman-hook-wire.XXXXXX")"
  trap 'rm -rf "$SANDBOX"' EXIT
  mkdir -p "$SANDBOX/bin"

  # case A: heimdall-caveman does not exist at all
  OUT_A=$(CLAUDE_PLUGIN_ROOT="$SANDBOX" /bin/sh -c "$CMD" 2>/dev/null)
  RC_A=$?
  if [ "$RC_A" -eq 0 ] && [ -z "$OUT_A" ]; then
    ok "case A (missing heimdall-caveman): hook exits 0 and emits nothing"
  else
    bad "case A (missing heimdall-caveman): rc=$RC_A out='$OUT_A' — expected rc=0, empty stdout"
  fi

  # case B: heimdall-caveman exists but is not executable
  cat > "$SANDBOX/bin/heimdall-caveman" <<'STUB'
#!/bin/sh
echo ultra
STUB
  chmod -x "$SANDBOX/bin/heimdall-caveman"
  OUT_B=$(CLAUDE_PLUGIN_ROOT="$SANDBOX" /bin/sh -c "$CMD" 2>/dev/null)
  RC_B=$?
  if [ "$RC_B" -eq 0 ] && [ -z "$OUT_B" ]; then
    ok "case B (non-executable heimdall-caveman): hook exits 0 and emits nothing"
  else
    bad "case B (non-executable heimdall-caveman): rc=$RC_B out='$OUT_B' — expected rc=0, empty stdout"
  fi

  # case C: heimdall-caveman is executable but broken (always fails, prints nothing)
  cat > "$SANDBOX/bin/heimdall-caveman" <<'STUB'
#!/bin/sh
exit 1
STUB
  chmod +x "$SANDBOX/bin/heimdall-caveman"
  OUT_C=$(CLAUDE_PLUGIN_ROOT="$SANDBOX" /bin/sh -c "$CMD" 2>/dev/null)
  RC_C=$?
  if [ "$RC_C" -eq 0 ] && [ -z "$OUT_C" ]; then
    ok "case C (broken heimdall-caveman, always exits 1): hook exits 0 and emits nothing"
  else
    bad "case C (broken heimdall-caveman): rc=$RC_C out='$OUT_C' — expected rc=0, empty stdout"
  fi
fi

echo "--------------------------------------------------------------------"
echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# test/heimdall-ai-select.test.sh — offline coding-AI CLI backend selection.
#
# WHAT THIS GATES. hmd can be driven by more than one offline coding-AI CLI
# (Claude Code, Cursor CLI's `agent`/`cursor-agent`, more later). This locks:
#   1. DETECTION — bin/heimdall-ai-select finds installed backends via PATH,
#      and self-host detection (CLAUDECODE=1) works without shelling out.
#   2. DEFAULT — the currently-hosting CLI wins the default when it's in the
#      detected set; a single-alternative set picks itself with no prompt.
#   3. PERSISTENCE — the choice round-trips through .planning/settings.json
#      under a NEW top-level `ai_backend` key, preserving any sibling keys
#      already in the file (this repo's settings.json is shared, substantial,
#      and other keys must survive an ai_backend write untouched).
#   4. `/switch-ai` — commands/switch-ai.md exists, documents the no-arg and
#      explicit-switch behaviors, and is honest that it cannot hot-swap the
#      CLI hosting the CURRENT session.
#   5. WIRING — hooks/hooks.json stays valid JSON and references the new tool
#      from SessionStart (bin-reachability-gate's "shipped ⇒ reachable" rule).
#
# Detection is tested against FAKE stub executables on an isolated PATH, not
# whatever happens to be installed on the machine running the suite — real
# `claude`/`agent` on this dev box must not make the test pass by accident.
#
# EXIT: 0 = all assertions pass; 1 = any FAIL.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
AISEL="$REPO/bin/heimdall-ai-select"
CMD_MD="$REPO/commands/switch-ai.md"
HOOKS="$REPO/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required for this test" >&2; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hmd-ai-select.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# Isolated PATH: real coreutils/jq/perl, but deliberately EXCLUDES ~/.local/bin
# and any plugin bin dir, so a real claude/agent install on this machine can't
# leak into the detection result and mask a bug.
FAKEBIN="$SANDBOX/fakebin"
mkdir -p "$FAKEBIN"
BASEPATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
ISOPATH="$FAKEBIN:$BASEPATH"

mk_stub() { # $1 = name, $2 = script body
  printf '#!/bin/sh\n%s\n' "$2" > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}
rm_stub() { rm -f "$FAKEBIN/$1"; }

# ── 0. files exist ────────────────────────────────────────────────────────
if [ -x "$AISEL" ]; then ok "bin/heimdall-ai-select exists and is executable"; else bad "bin/heimdall-ai-select missing or not executable"; fi
if [ -f "$CMD_MD" ]; then ok "commands/switch-ai.md exists"; else bad "commands/switch-ai.md missing"; fi

if [ ! -x "$AISEL" ]; then
  echo "  FATAL: cannot continue without bin/heimdall-ai-select" >&2
  printf "\n  Results: %d passed, %d failed\n" "$PASS" "$((FAIL+20))"
  exit 1
fi

# ── 1. detection: finds claude AND agent when both on PATH ─────────────────
mk_stub claude 'echo claude-stub'
mk_stub agent 'if [ "$1" = "status" ]; then echo "Not logged in"; else echo agent-stub; fi'

DETECT_JSON="$(PATH="$ISOPATH" "$AISEL" detect 2>/dev/null)"
if printf '%s' "$DETECT_JSON" | jq -e . >/dev/null 2>&1; then
  ok "detect emits valid JSON"
else
  bad "detect did not emit valid JSON: $DETECT_JSON"
fi

CC_AVAIL="$(printf '%s' "$DETECT_JSON" | jq -r '[.[] | select(.id=="claude-code")] | if length==0 then "missing" else .[0].available end')"
CU_AVAIL="$(printf '%s' "$DETECT_JSON" | jq -r '[.[] | select(.id=="cursor-cli")] | if length==0 then "missing" else .[0].available end')"
if [ "$CC_AVAIL" = "true" ]; then ok "detect finds claude-code when 'claude' stub is on PATH"; else bad "claude-code available=$CC_AVAIL (expected true)"; fi
if [ "$CU_AVAIL" = "true" ]; then ok "detect finds cursor-cli when 'agent' stub is on PATH"; else bad "cursor-cli available=$CU_AVAIL (expected true)"; fi

# Falsifier: remove the agent stub -> cursor-cli must flip to unavailable (RED),
# then restore it and prove it flips back (GREEN). A detector that can't go
# RED here is decoration, not a gate.
rm_stub agent
RED_JSON="$(PATH="$ISOPATH" "$AISEL" detect 2>/dev/null)"
RED_AVAIL="$(printf '%s' "$RED_JSON" | jq -r '[.[] | select(.id=="cursor-cli")] | if length==0 then "missing" else .[0].available end')"
if [ "$RED_AVAIL" = "false" ]; then
  ok "falsifier: removing the agent/cursor-agent stub flips cursor-cli to unavailable"
else
  bad "falsifier FAILED: cursor-cli still reports available=$RED_AVAIL with no stub on PATH"
fi
mk_stub agent 'if [ "$1" = "status" ]; then echo "Not logged in"; else echo agent-stub; fi'
GREEN_JSON="$(PATH="$ISOPATH" "$AISEL" detect 2>/dev/null)"
GREEN_AVAIL="$(printf '%s' "$GREEN_JSON" | jq -r '[.[] | select(.id=="cursor-cli")] | if length==0 then "missing" else .[0].available end')"
if [ "$GREEN_AVAIL" = "true" ]; then
  ok "falsifier: restoring the stub flips cursor-cli back to available (GREEN)"
else
  bad "falsifier FAILED: cursor-cli did not recover after restoring the stub"
fi

# ── 2. self-host detection via CLAUDECODE, no subprocess needed ────────────
HOST_JSON="$(unset CLAUDECODE; PATH="$ISOPATH" "$AISEL" detect 2>/dev/null)"
HOST_TRUE="$(printf '%s' "$HOST_JSON" | jq -r '[.[] | select(.id=="claude-code")][0].host')"
if [ "$HOST_TRUE" = "false" ]; then ok "claude-code host=false when CLAUDECODE is unset"; else bad "host=$HOST_TRUE with CLAUDECODE unset (expected false)"; fi

HOST_JSON2="$(CLAUDECODE=1 PATH="$ISOPATH" "$AISEL" detect 2>/dev/null)"
HOST_TRUE2="$(printf '%s' "$HOST_JSON2" | jq -r '[.[] | select(.id=="claude-code")][0].host')"
if [ "$HOST_TRUE2" = "true" ]; then ok "claude-code host=true when CLAUDECODE=1 (self-detection, no subprocess)"; else bad "host=$HOST_TRUE2 with CLAUDECODE=1 (expected true)"; fi

# ── 3. default selection logic ──────────────────────────────────────────────
# 3a. host wins when present in the detected set
DEF_HOST="$(CLAUDECODE=1 PATH="$ISOPATH" "$AISEL" default 2>/dev/null)"
if [ "$DEF_HOST" = "claude-code" ]; then ok "default: host (claude-code) wins when it is in the detected set"; else bad "default with host present = '$DEF_HOST' (expected claude-code)"; fi

# 3b. host absent, single alternative -> that alternative, no prompt needed
rm_stub claude
DEF_SINGLE="$(unset CLAUDECODE; PATH="$ISOPATH" "$AISEL" default 2>/dev/null)"
if [ "$DEF_SINGLE" = "cursor-cli" ]; then ok "default: sole detected non-host backend wins with no host present"; else bad "default with only cursor-cli = '$DEF_SINGLE' (expected cursor-cli)"; fi
mk_stub claude 'echo claude-stub'

# 3c. nothing detected -> default refuses rather than inventing a choice
rm_stub claude; rm_stub agent
if (unset CLAUDECODE; PATH="$ISOPATH" "$AISEL" default >/dev/null 2>&1); then
  bad "default exited 0 with NOTHING detected — it must refuse, not invent a backend"
else
  ok "default exits non-zero when no backend is detected (no fabricated choice)"
fi
mk_stub claude 'echo claude-stub'
mk_stub agent 'if [ "$1" = "status" ]; then echo "Not logged in"; else echo agent-stub; fi'

# ── 4. persistence round-trip in .planning/settings.json ───────────────────
# Isolate to "only cursor-cli detected": section 3c's cleanup restored the
# claude stub, so without removing it again here, CLAUDECODE-unset + both
# stubs present would make cmd_default pick claude-code (first table row),
# not cursor-cli — this block's assertions require the single-alternative
# path specifically. Restored right after, before section 5 needs it back.
rm_stub claude
P1="$SANDBOX/proj1"
mkdir -p "$P1"
SS1="$P1/.planning/settings.json"

# session-start on a fresh project (nothing persisted yet) auto-defaults + persists
(unset CLAUDECODE; PATH="$ISOPATH" "$AISEL" session-start "$P1" >/dev/null 2>&1)
if [ -f "$SS1" ]; then ok ".planning/settings.json created by session-start"; else bad ".planning/settings.json was not created"; fi
SEL1="$(jq -r '.ai_backend.selected // "missing"' "$SS1" 2>/dev/null)"
SRC1="$(jq -r '.ai_backend.source // "missing"' "$SS1" 2>/dev/null)"
if [ "$SEL1" = "cursor-cli" ]; then ok "session-start persisted the computed default (cursor-cli)"; else bad "persisted selected='$SEL1' (expected cursor-cli)"; fi
if [ "$SRC1" = "auto-default" ]; then ok "session-start records source=auto-default"; else bad "persisted source='$SRC1' (expected auto-default)"; fi

CUR1="$(PATH="$ISOPATH" "$AISEL" current "$P1" 2>/dev/null)"
if [ "$CUR1" = "cursor-cli" ]; then ok "current reads back the persisted selection"; else bad "current returned '$CUR1' (expected cursor-cli)"; fi

# session-start again must NOT clobber an existing choice or emit noise
OUT2="$(PATH="$ISOPATH" "$AISEL" session-start "$P1" 2>&1)"
SEL1B="$(jq -r '.ai_backend.selected // "missing"' "$SS1" 2>/dev/null)"
if [ -z "$OUT2" ] && [ "$SEL1B" = "cursor-cli" ]; then
  ok "session-start is silent and non-destructive once a choice is already persisted"
else
  bad "second session-start was noisy or changed the selection (out='$OUT2', selected='$SEL1B')"
fi
mk_stub claude 'echo claude-stub'

# pre-existing sibling keys in settings.json must survive an ai_backend write
P2="$SANDBOX/proj2"
mkdir -p "$P2/.planning"
printf '{"governance":"hierarchical","commands":{"test":"npm test"}}\n' > "$P2/.planning/settings.json"
PATH="$ISOPATH" "$AISEL" select claude-code "$P2" >/dev/null 2>&1
GOV="$(jq -r '.governance // "missing"' "$P2/.planning/settings.json" 2>/dev/null)"
TESTCMD="$(jq -r '.commands.test // "missing"' "$P2/.planning/settings.json" 2>/dev/null)"
SEL2="$(jq -r '.ai_backend.selected // "missing"' "$P2/.planning/settings.json" 2>/dev/null)"
if [ "$GOV" = "hierarchical" ] && [ "$TESTCMD" = "npm test" ]; then
  ok "explicit select() preserves pre-existing sibling keys (governance, commands.test)"
else
  bad "select() clobbered sibling keys — governance='$GOV' commands.test='$TESTCMD'"
fi
if [ "$SEL2" = "claude-code" ]; then ok "explicit select() writes the new ai_backend key"; else bad "ai_backend.selected='$SEL2' after explicit select (expected claude-code)"; fi

# ── 5. explicit /switch-ai-style selection: letter, id, loose name, failure ─
P3="$SANDBOX/proj3"; mkdir -p "$P3"
LIST_OUT="$(PATH="$ISOPATH" "$AISEL" list 2>/dev/null)"
if printf '%s' "$LIST_OUT" | grep -qE '^A\) .*claude-code'; then ok "list letters the first detected backend A) with its id"; else bad "list output missing expected 'A) ... claude-code' line: $LIST_OUT"; fi
if printf '%s' "$LIST_OUT" | grep -qE '^B\) .*cursor-cli'; then ok "list letters the second detected backend B) with its id"; else bad "list output missing expected 'B) ... cursor-cli' line: $LIST_OUT"; fi

PATH="$ISOPATH" "$AISEL" select B "$P3" >/dev/null 2>&1
SEL3="$(jq -r '.ai_backend.selected' "$P3/.planning/settings.json" 2>/dev/null)"
if [ "$SEL3" = "cursor-cli" ]; then ok "select B (letter) resolves to cursor-cli"; else bad "select B resolved to '$SEL3' (expected cursor-cli)"; fi

PATH="$ISOPATH" "$AISEL" select cursor "$P3" >/dev/null 2>&1
SEL4="$(jq -r '.ai_backend.selected' "$P3/.planning/settings.json" 2>/dev/null)"
if [ "$SEL4" = "cursor-cli" ]; then ok "select cursor (loose name) resolves to cursor-cli"; else bad "select cursor resolved to '$SEL4' (expected cursor-cli)"; fi

if PATH="$ISOPATH" "$AISEL" select totally-unknown-cli "$P3" >/dev/null 2>&1; then
  bad "select accepted an unknown backend name instead of failing"
else
  ok "select rejects an unrecognized backend name (non-zero exit)"
fi

# selecting an installed-but-not-detected backend must also fail (can't prefer
# a CLI that isn't actually on this machine)
rm_stub agent
if PATH="$ISOPATH" "$AISEL" select cursor-cli "$P3" >/dev/null 2>&1; then
  bad "select accepted cursor-cli while it was NOT detected on PATH"
else
  ok "select refuses a backend id that is not currently detected"
fi
mk_stub agent 'if [ "$1" = "status" ]; then echo "Not logged in"; else echo agent-stub; fi'

# ── 6. registry is table-driven: one definition site, appendable ───────────
DEFSITES="$(grep -c '^BACKENDS=(' "$AISEL" || true)"
if [ "$DEFSITES" = "1" ]; then ok "exactly one BACKENDS table definition site in the script"; else bad "found $DEFSITES BACKENDS=( definition sites (expected exactly 1)"; fi
ROWCOUNT="$(sed -n '/^BACKENDS=(/,/^)/p' "$AISEL" | grep -cE '^\s*"[a-z0-9-]+\|' || true)"
if [ "$ROWCOUNT" -ge 2 ]; then ok "registry lists >= 2 backends ($ROWCOUNT) in a flat table"; else bad "registry table has only $ROWCOUNT row(s)"; fi

# ── 7. commands/switch-ai.md — static contract ──────────────────────────────
if grep -qE '^name:[[:space:]]*switch-ai[[:space:]]*$' "$CMD_MD" 2>/dev/null; then
  ok "switch-ai.md frontmatter name: switch-ai"
else bad "switch-ai.md frontmatter name is not 'switch-ai'"; fi

if grep -q 'heimdall-ai-select' "$CMD_MD" 2>/dev/null; then ok "switch-ai.md invokes heimdall-ai-select"; else bad "switch-ai.md never calls heimdall-ai-select"; fi
if grep -qiE 'empty or missing' "$CMD_MD" 2>/dev/null; then ok "switch-ai.md documents no-arg (show current + options) behavior"; else bad "switch-ai.md missing no-arg behavior"; fi
if grep -qiE 'letter|backend id|loose' "$CMD_MD" 2>/dev/null; then ok "switch-ai.md documents explicit-switch (letter/id/name) behavior"; else bad "switch-ai.md missing explicit-switch behavior"; fi

# Honesty contract (requirement 5): must NOT claim to hot-swap the running
# session's own host CLI, and MUST say plainly what a restart actually buys.
if grep -qiE "cannot|can't|can not" "$CMD_MD" 2>/dev/null && grep -qiE "mid-session|hot-swap|this session|itself" "$CMD_MD" 2>/dev/null; then
  ok "switch-ai.md states plainly it cannot hot-swap the current session's host CLI"
else
  bad "switch-ai.md does not carry the 'cannot hot-swap this session' honesty caveat"
fi
if grep -qiE 'next session|next launch|next time' "$CMD_MD" 2>/dev/null; then
  ok "switch-ai.md explains the recorded choice governs the NEXT session's default"
else
  bad "switch-ai.md does not explain what actually changes for next time"
fi

# ── 8. hooks.json wiring stays valid and reachable ──────────────────────────
if jq -e . "$HOOKS" >/dev/null 2>&1; then ok "hooks/hooks.json is still valid JSON"; else bad "hooks/hooks.json is NOT valid JSON"; fi
if grep -q 'heimdall-ai-select' "$HOOKS" 2>/dev/null; then ok "hooks/hooks.json SessionStart references heimdall-ai-select"; else bad "hooks/hooks.json does not reference heimdall-ai-select anywhere"; fi
SS_REF="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command // "" | select(contains("heimdall-ai-select"))] | length' "$HOOKS" 2>/dev/null || echo 0)"
if [ "${SS_REF:-0}" -ge 1 ]; then ok "reference lives specifically under the SessionStart hook array"; else bad "heimdall-ai-select is not wired into SessionStart"; fi
# structural: this new entry must not pipe a shell var into jq/grep via echo
# (the same class of bug test/hook-payload-escaping.test.sh gates repo-wide).
BAD_ECHO="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command // "" | select(contains("heimdall-ai-select"))] | .[0] // ""' "$HOOKS" 2>/dev/null | grep -cE 'echo[[:space:]]+"\$[A-Za-z_]' || true)"
if [ "${BAD_ECHO:-0}" = "0" ]; then ok "new hook entry does not pipe a variable into jq/grep via echo"; else bad "new hook entry pipes a variable via echo — printf '%s' is required (see hook-payload-escaping.test.sh)"; fi

echo
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# test/heimdall-autonomy-rename.test.sh — the /level -> /autonomy rename contract.
#
# WHAT THIS GATES. The command NOUN renames from /level to /autonomy while:
#   1. /hmd:autonomy is the canonical command (name: autonomy) and keeps every
#      sub-behavior: set-N, + (cycle up), - (cycle down), no-arg show.
#   2. /hmd:level survives as a DEPRECATED ALIAS for one release — it still works
#      and prints a one-line "now /hmd:autonomy" notice.
#   3. THE ONE THING THAT MUST NOT BREAK: the on-disk config KEY stays
#      `.project.autonomy_level`. A config written with that key still resolves to
#      the saved value after the rename (no user's setting resets on upgrade).
#      Falsifier: if the command read the key from a renamed path, a state file
#      carrying autonomy_level=3 would resolve to null/default -> RED.
#   4. Statusline HUD is width-safe across tiers (truecolor/256/ascii). The
#      autonomy value is NOT a HUD segment, so the longer noun cannot overflow —
#      this guard proves the HUD still renders on a narrow terminal.
#   5. No half-rename residue: canonical surfaces (agent prompt, skill, status
#      CLI, conformance) reference /hmd:autonomy, not /hmd:level (the alias file
#      is the sole intentional exception).
#
# EXIT: 0 = all assertions pass; 1 = any FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
STATE_BIN="$REPO/bin/heimdall-state"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# ── 1. canonical /hmd:autonomy command ────────────────────────────────────────
AUTO="$REPO/commands/autonomy.md"
if [ -f "$AUTO" ]; then ok "commands/autonomy.md exists"; else bad "commands/autonomy.md missing"; fi

if grep -qE '^name:[[:space:]]*autonomy[[:space:]]*$' "$AUTO" 2>/dev/null; then
  ok "autonomy.md frontmatter name: autonomy"
else bad "autonomy.md frontmatter name is not 'autonomy'"; fi

# sub-behaviors preserved: set-N, + cycle, - cycle
if grep -q '/hmd:autonomy +' "$AUTO" 2>/dev/null; then ok "autonomy.md documents + (cycle up)"; else bad "autonomy.md missing + cycle"; fi
if grep -q '/hmd:autonomy -' "$AUTO" 2>/dev/null; then ok "autonomy.md documents - (cycle down)"; else bad "autonomy.md missing - cycle"; fi
if grep -qE '1, 2, or 3|1\|2\|3' "$AUTO" 2>/dev/null; then ok "autonomy.md documents set-N direct"; else bad "autonomy.md missing set-N"; fi

# config KEY is read from the STABLE path — the no-reset guard at the command layer
if grep -q "\.project\.autonomy_level" "$AUTO" 2>/dev/null; then
  ok "autonomy.md reads/writes stable key .project.autonomy_level"
else bad "autonomy.md does not use stable key .project.autonomy_level"; fi

# the canonical command must NOT INVOKE the old noun as an instruction (e.g.
# `/hmd:level +`, `/hmd:level 2`). A bare mention inside the deprecation notice
# is fine; a command-with-argument usage is half-rename residue.
if grep -qE '/hmd:level[[:space:]]+[-+<0-9]' "$AUTO" 2>/dev/null; then
  bad "autonomy.md still INVOKES /hmd:level (half-rename residue)"
else ok "autonomy.md has no /hmd:level invocation residue"; fi

# ── 2. deprecated /hmd:level alias ────────────────────────────────────────────
LEVEL="$REPO/commands/level.md"
if [ -f "$LEVEL" ]; then ok "commands/level.md (alias) still exists"; else bad "commands/level.md alias removed"; fi

if grep -q '/hmd:autonomy' "$LEVEL" 2>/dev/null; then
  ok "level.md alias points users to /hmd:autonomy"
else bad "level.md alias does not mention /hmd:autonomy"; fi

if grep -qiE 'deprecat|renamed|now ' "$LEVEL" 2>/dev/null; then
  ok "level.md alias carries a deprecation notice"
else bad "level.md alias lacks a deprecation notice"; fi

# alias keeps the same key too
if grep -q "\.project\.autonomy_level" "$LEVEL" 2>/dev/null; then
  ok "level.md alias uses the stable key .project.autonomy_level"
else bad "level.md alias does not use the stable key"; fi

# ── 3. config-key stability: no user's saved setting resets (RUNTIME PROOF) ────
T="$(mktemp -d)"
export HEIMDALL_STATE_FILE="$T/heimdall-state.json"
"$STATE_BIN" init >/dev/null 2>&1
# a pre-existing user saved level 3 under the on-disk key BEFORE the upgrade
"$STATE_BIN" set '.project.autonomy_level' '3' >/dev/null 2>&1
GOT="$("$STATE_BIN" get '.project.autonomy_level' 2>/dev/null)"
if [ "$GOT" = "3" ]; then
  ok "saved autonomy_level=3 still resolves to 3 post-rename (NOT default 2)"
else bad "saved autonomy_level resolved to '$GOT' — setting reset (KEY BROKE)"; fi
# falsifier direction: reading a renamed key would yield null
NULLGOT="$("$STATE_BIN" get '.project.autonomy' 2>/dev/null)"
if [ "$NULLGOT" = "null" ]; then
  ok "falsifier: a renamed key .project.autonomy resolves to null (would reset users)"
else bad "unexpected: .project.autonomy resolved to '$NULLGOT'"; fi
unset HEIMDALL_STATE_FILE
rm -rf "$T"

# ── 4. status CLI shows the Autonomy label, keyed off the stable field ─────────
T2="$(mktemp -d)"
export HEIMDALL_STATE_FILE="$T2/heimdall-state.json"
"$STATE_BIN" init >/dev/null 2>&1
"$STATE_BIN" set '.project.autonomy_level' '3' >/dev/null 2>&1
STATUS_OUT="$("$STATE_BIN" status 2>/dev/null)"
if grep -qiE 'Autonomy:[[:space:]]*3' <<<"$STATUS_OUT"; then
  ok "status output renders 'Autonomy: 3' from the stable key"
else bad "status output missing 'Autonomy: 3' (got: $(grep -i 'level\|autonomy' <<<"$STATUS_OUT"))"; fi
unset HEIMDALL_STATE_FILE
rm -rf "$T2"

# ── 5. statusline HUD width-safe across tiers (longer noun cannot overflow) ────
SL="$REPO/sentinels/hmd-statusline.py"
STDIN_JSON='{"workspace":{"current_dir":"/tmp/x"},"model":{"display_name":"opus"}}'
for MODE in truecolor 256 ascii; do
  OUT="$(printf '%s' "$STDIN_JSON" | HEIMDALL_STATUSLINE_MODE="$MODE" COLUMNS=40 python3 "$SL" 2>/dev/null)"
  RC=$?
  if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
    ok "statusline renders (tier=$MODE, COLUMNS=40) rc=0, non-empty"
  else bad "statusline failed (tier=$MODE) rc=$RC"; fi
done
# the autonomy value must not be a HUD segment (that is why the noun can't overflow)
if grep -qiE 'autonomy_level|1=Guided|Checkpoint' "$SL" 2>/dev/null; then
  bad "statusline now renders the autonomy label — re-check width budget"
else ok "statusline has no autonomy segment — longer noun structurally cannot overflow"; fi

# ── 6. no half-rename residue on canonical surfaces ───────────────────────────
# Residue = /hmd:level INVOKED as a command (followed by an arg), NOT the
# intentional deprecation-alias notices ("`/hmd:level` still works...").
RESIDUE="$(grep -rnE '/hmd:level[[:space:]]+[-+<0-9]' "$REPO/agents/heimdall.md" "$REPO/skills/heimdall/SKILL.md" "$REPO/commands/autonomy.md" "$REPO/conformance/INDEX.json" 2>/dev/null)"
if [ -z "$RESIDUE" ]; then
  ok "no /hmd:level invocation residue on canonical surfaces (agent/skill/autonomy cmd/conformance)"
else bad "half-rename residue found: $RESIDUE"; fi
# and the canonical /hmd:autonomy IS present in the agent prompt (discoverable)
if grep -q '/hmd:autonomy' "$REPO/agents/heimdall.md" 2>/dev/null; then
  ok "agent prompt references canonical /hmd:autonomy"
else bad "agent prompt does not reference /hmd:autonomy"; fi

echo
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

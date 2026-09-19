#!/usr/bin/env bash
# test/hooks-disable.test.sh
#
# Proof for the per-hook kill switch: `bin/heimdall-hooks disable|enable` (the
# write side) and bin/lib/hook-enabled.sh's `hmd_hook_enabled` (the read side
# every advisory hook command is prefixed with).
#
# The properties, asserted head-on:
#   1. An ADVISORY id can be disabled, and the lib then returns 1 for it.
#   2. A LOCKED id is REFUSED with exit 2 and stays enabled.
#   3. Hand-appending a locked id to hooks-disabled does NOT disable it -- the
#      lib re-reads the locked set from the sidecar; the file is not the truth.
#   4. `enable` restores.
#   5. Every plumbing failure (no HEIMDALL_HOME dir, no metadata, no jq, empty
#      id) resolves to ENABLED. A switch that fails toward "off" is a hook that
#      silently vanished.
#   6. The exact prefix the orchestrator prepends behaves: exits 0 early when
#      disabled, falls through when enabled, falls through when the lib is
#      missing.
#
# HEIMDALL_HOME is isolated to a temp dir; the operator's real
# ~/.heimdall/hooks-disabled is never read or written.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO/bin/heimdall-hooks"
LIB="$REPO/bin/lib/hook-enabled.sh"
META="$REPO/hooks/hooks.metadata.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export HEIMDALL_HOME="$TMPROOT/home"
unset CLAUDE_PLUGIN_ROOT

# Evaluate hmd_hook_enabled in a fresh subshell so state never leaks between cases.
# Echoes the function's return code.
enabled() {
  ( . "$LIB" 2>/dev/null; hmd_hook_enabled "$1"; printf '%s' "$?" )
}

run_tool() {
  "$TOOL" "$@" 2>"$TMPROOT/err" 1>"$TMPROOT/out"
  printf '%s' "$?"
}

echo "heimdall-hooks disable/enable + hmd_hook_enabled"

if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: jq not installed"; exit 0
fi

ADVISORY="ctx-meter-notice"
LOCKED="secret-read-guard"
[ "$(jq -r --arg i "$ADVISORY" '.hooks[] | select(.id==$i) | .locked' "$META")" = "false" ] \
  || { bad "precondition: $ADVISORY is not advisory in the sidecar"; }
[ "$(jq -r --arg i "$LOCKED" '.hooks[] | select(.id==$i) | .locked' "$META")" = "true" ] \
  || { bad "precondition: $LOCKED is not locked in the sidecar"; }

# ── 1. missing HEIMDALL_HOME dir -> enabled ─────────────────────────────────
[ "$(enabled "$ADVISORY")" = "0" ] && ok "1. no HEIMDALL_HOME dir -> enabled" \
                                    || bad "1. missing dir did not resolve to enabled"

# ── 2. disable an advisory id -> file written, lib returns 1 ────────────────
rc="$(run_tool disable "$ADVISORY")"
if [ "$rc" = "0" ] && grep -qx "$ADVISORY" "$HEIMDALL_HOME/hooks-disabled" \
   && [ "$(enabled "$ADVISORY")" = "1" ]; then
  ok "2. disable $ADVISORY -> written to hooks-disabled, hmd_hook_enabled returns 1"
else
  bad "2. disable advisory failed (rc=$rc, enabled=$(enabled "$ADVISORY"))"
fi

# ── 3. disabling is idempotent (no duplicate lines) ─────────────────────────
run_tool disable "$ADVISORY" >/dev/null
[ "$(grep -cx "$ADVISORY" "$HEIMDALL_HOME/hooks-disabled")" = "1" ] \
  && ok "3. second disable does not duplicate the line" \
  || bad "3. duplicate line written"

# ── 4. other advisory ids are unaffected ────────────────────────────────────
[ "$(enabled caveman-rules)" = "0" ] && ok "4. an undisabled advisory id stays enabled" \
                                     || bad "4. collateral disable"

# ── 5. disable a LOCKED id -> exit 2, not written, still enabled ────────────
rc="$(run_tool disable "$LOCKED")"
if [ "$rc" = "2" ] && grep -q 'REFUSED' "$TMPROOT/err" \
   && ! grep -qx "$LOCKED" "$HEIMDALL_HOME/hooks-disabled" \
   && [ "$(enabled "$LOCKED")" = "0" ]; then
  ok "5. disable $LOCKED -> exit 2 REFUSED, file untouched, still enabled"
else
  bad "5. locked id not refused correctly (rc=$rc, enabled=$(enabled "$LOCKED"))"
fi

# ── 6. hand-append a locked id -> STILL enabled ─────────────────────────────
printf '%s\n' "stub-gate" >> "$HEIMDALL_HOME/hooks-disabled"
[ "$(enabled stub-gate)" = "0" ] && ok "6. hand-appended locked id stub-gate is still enabled" \
                                 || bad "6. a hand-edit disabled a locked gate"

# ── 7. list shows the states ────────────────────────────────────────────────
rc="$(run_tool list)"
if [ "$rc" = "0" ] && grep -E "^$ADVISORY +.*DISABLED" "$TMPROOT/out" >/dev/null \
   && grep -E "^stub-gate +.*locked" "$TMPROOT/out" >/dev/null; then
  ok "7. list reports $ADVISORY DISABLED and stub-gate locked"
else
  bad "7. list output wrong (rc=$rc)"
fi

# ── 8. unknown id -> exit 1 (not 2, not 0) ──────────────────────────────────
rc="$(run_tool disable no-such-hook)"
[ "$rc" = "1" ] && ok "8. unknown id -> exit 1" || bad "8. unknown id exited $rc"

# ── 9. enable restores ──────────────────────────────────────────────────────
rc="$(run_tool enable "$ADVISORY")"
if [ "$rc" = "0" ] && ! grep -qx "$ADVISORY" "$HEIMDALL_HOME/hooks-disabled" \
   && [ "$(enabled "$ADVISORY")" = "0" ]; then
  ok "9. enable $ADVISORY -> removed, hmd_hook_enabled returns 0"
else
  bad "9. enable did not restore (rc=$rc)"
fi
rc="$(run_tool enable "$ADVISORY")"
[ "$rc" = "0" ] && ok "10. enable on an already-enabled id is a no-op exit 0" \
                || bad "10. re-enable exited $rc"

# ── 11. fail toward ENABLED: metadata missing while id is in the file ───────
run_tool disable "$ADVISORY" >/dev/null
rc="$( ( export HMD_HOOKS_METADATA="$TMPROOT/nope.json"; . "$LIB"; hmd_hook_enabled "$ADVISORY"; printf '%s' "$?" ) )"
[ "$rc" = "0" ] && ok "11. disabled id + missing metadata -> enabled (cannot prove not-locked)" \
                || bad "11. missing metadata resolved to disabled"

# ── 12. fail toward ENABLED: jq absent ──────────────────────────────────────
mkdir -p "$TMPROOT/emptybin"; ln -sf "$(command -v grep)" "$TMPROOT/emptybin/grep"
rc="$( ( PATH="$TMPROOT/emptybin"; . "$LIB"; hmd_hook_enabled "$ADVISORY"; printf '%s' "$?" ) )"
[ "$rc" = "0" ] && ok "12. disabled id + no jq on PATH -> enabled" \
                || bad "12. missing jq resolved to disabled"

# ── 13. empty id -> enabled ─────────────────────────────────────────────────
[ "$(enabled "")" = "0" ] && ok "13. empty id -> enabled" || bad "13. empty id disabled"

# ── 14. the exact orchestrator prefix, end to end ───────────────────────────
# Disabled -> the hook body must NOT run. Enabled -> it must. Lib missing -> it must.
PREFIX='. "$HMDP/bin/lib/hook-enabled.sh" 2>/dev/null && ! hmd_hook_enabled '"$ADVISORY"' && exit 0;'
body='echo RAN'
out="$(HMDP="$REPO" bash -c "$PREFIX $body")"
[ -z "$out" ] && ok "14a. prefix exits 0 before the body when the id is disabled" \
              || bad "14a. body ran while disabled"
run_tool enable "$ADVISORY" >/dev/null
out="$(HMDP="$REPO" bash -c "$PREFIX $body")"
[ "$out" = "RAN" ] && ok "14b. prefix falls through to the body when enabled" \
                   || bad "14b. body did not run while enabled"
run_tool disable "$ADVISORY" >/dev/null
out="$(HMDP="$TMPROOT/no-plugin-here" bash -c "$PREFIX $body")"
[ "$out" = "RAN" ] && ok "14c. prefix falls through when the lib cannot be sourced (fail toward enabled)" \
                   || bad "14c. an unsourceable lib disabled the hook"
PREFIX_LOCKED='. "$HMDP/bin/lib/hook-enabled.sh" 2>/dev/null && ! hmd_hook_enabled stub-gate && exit 0;'
out="$(HMDP="$REPO" bash -c "$PREFIX_LOCKED $body")"
[ "$out" = "RAN" ] && ok "14d. prefix on a locked id always runs the body (hand-appended stub-gate ignored)" \
                   || bad "14d. locked hook body skipped"

# ── 15. lib is POSIX-sh sourceable (Claude Code may run hooks under sh) ─────
if command -v sh >/dev/null 2>&1; then
  rc="$(sh -c ". '$LIB' && hmd_hook_enabled $ADVISORY; echo \$?")"
  [ "$rc" = "1" ] && ok "15. lib sources under sh and still reads the disabled-list" \
                  || bad "15. lib broke under sh (rc=$rc)"
fi

# ── 16. the tool never wrote outside HEIMDALL_HOME ──────────────────────────
[ -f "$HEIMDALL_HOME/hooks-disabled" ] && [ ! -e "$REPO/hooks-disabled" ] \
  && ok "16. state lives in \$HEIMDALL_HOME/hooks-disabled only" \
  || bad "16. state written elsewhere"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

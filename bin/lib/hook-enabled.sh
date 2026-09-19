#!/usr/bin/env bash
# bin/lib/hook-enabled.sh — the per-hook kill switch, read side.
#
# WHAT IT IS. One sourceable function, `hmd_hook_enabled <id>`, prepended to
# every ADVISORY inline command in hooks/hooks.json:
#
#   . "$P/bin/lib/hook-enabled.sh" 2>/dev/null && ! hmd_hook_enabled <id> && exit 0;
#
# It returns 1 iff <id> is listed in $HEIMDALL_HOME/hooks-disabled (written by
# `bin/heimdall-hooks disable <id>`). Every other outcome is 0 = enabled.
#
# LOCKED IDS ARE ALWAYS ENABLED. `heimdall-hooks disable` already refuses a
# locked id with exit 2, but the disabled-list is a plain text file anyone can
# hand-edit. So the locked set is re-read here, from hooks/hooks.metadata.json,
# and a locked id in the file is IGNORED. The fail-closed gates cannot be
# switched off from either side.
#
# FAILS TOWARD ENABLED, ON EVERYTHING. No HEIMDALL_HOME dir, no disabled file,
# no jq, no metadata, unreadable metadata, an empty id — all return 0. A kill
# switch whose plumbing failure silently disables a hook is a hook that
# vanished, which is the outcome this whole mechanism exists to make explicit.
# The prefix above is shaped for the same reason: if this file cannot be
# sourced, `&&` short-circuits and the hook runs as if the switch did not exist.
#
# CHEAP. Fires on every hook event, so the fast path is one `[ -f ]` and one
# grep. jq is only spawned when the id actually appears in the disabled-list —
# i.e. only for a hook the operator has switched off.
#
# Bash 3.2 / POSIX-sh compatible: no arrays, no [[ ]], no mapfile.

[ -n "${_HMD_HOOK_ENABLED_SH:-}" ] && return 0 2>/dev/null || true
_HMD_HOOK_ENABLED_SH=1

# Where hooks.metadata.json lives. Order: explicit override (tests), the
# plugin root Claude Code hands every hook, this file's own location.
_hmd_hook_metadata_path() {
  if [ -n "${HMD_HOOKS_METADATA:-}" ]; then
    printf '%s' "$HMD_HOOKS_METADATA"
    return 0
  fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s/hooks/hooks.metadata.json' "$CLAUDE_PLUGIN_ROOT"
    return 0
  fi
  _src="${BASH_SOURCE:-}"
  if [ -n "$_src" ]; then
    printf '%s/../../hooks/hooks.metadata.json' "$(dirname "$_src")"
    return 0
  fi
  printf '%s/hooks/hooks.metadata.json' "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

# hmd_hook_enabled <id>  → 0 enabled (run the hook), 1 disabled (exit 0 early)
hmd_hook_enabled() {
  _id="${1:-}"
  [ -n "$_id" ] || return 0
  _home="${HEIMDALL_HOME:-${HOME:-/tmp}/.heimdall}"
  _file="$_home/hooks-disabled"
  [ -f "$_file" ] || return 0
  grep -qxF -- "$_id" "$_file" 2>/dev/null || return 0

  # Listed as disabled. Honour that ONLY if the id is provably not locked.
  command -v jq >/dev/null 2>&1 || return 0
  _meta="$(_hmd_hook_metadata_path)"
  [ -f "$_meta" ] || return 0
  _locked="$(jq -r --arg id "$_id" \
    '[.hooks[]? | select(.id == $id) | .locked == true] | any' "$_meta" 2>/dev/null)" || return 0
  case "$_locked" in
    false) return 1 ;;   # advisory, and listed → disabled
    *)     return 0 ;;   # locked, or jq gave anything unexpected → enabled
  esac
}

#!/usr/bin/env bash
# bin/lib/hmd_guardrail_enabled.sh -- the guardrail switch, read side: may this RECOMMENDED guard run? A core guard always does.
#
# WHAT IT IS. One sourceable function, hmd_guardrail_enabled <id>. The cost and discipline guards that live INSIDE a locked hook (ci-waste-guard, disk-floor, sweep-guard, wait-guard and
# the rest in bin/heimdall-precheck-bash and bin/heimdall-precheck-agent) are out of reach of `hmd hooks disable`, which moves whole hooks only. Such a guard asks this, next to the
# per-process override it already honours, before it runs. The tiers are in guardrails.manifest.json (format: docs/schemas/guardrails.manifest.v1.json); the write side is
# `hmd guardrails off|on <id>`. Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, task T2.2.
#
# THE ANSWER. Exit 1 = the operator switched this guard off: skip it. Exit 0 = enabled: run it. It is 1 ONLY when BOTH hold, and EVERY other outcome is 0:
#   1. $HEIMDALL_HOME/guardrails-off has a line that is exactly <id>. One id per line, per operator, never in a repository. HEIMDALL_HOME, else ${HOME:-/tmp}/.heimdall: the resolution
#      bin/heimdall-hooks and hook-enabled.sh use for hooks-disabled. Only an ABSOLUTE path counts: a relative HEIMDALL_HOME is the cwd, and a repository could ship the file (INV-G7).
#   2. guardrails.manifest.json has exactly ONE row with that id, and its tier is exactly the string "recommended".
#
# CORE IS NEVER SWITCHABLE (INV-G1). `hmd guardrails off` refuses a core id, but guardrails-off is plain text anyone can edit, so it is not the truth: the tier is re-read from the manifest
# here. A core id in the file is ignored, and so is an id the manifest does not know, lists twice, gives no tier or gives any tier but "recommended". Anything not positively classified is core.
#
# ANY DOUBT IS ENABLED (INV-G5). No HEIMDALL_HOME directory, no file, a file that is a directory or unreadable, an empty id, no jq, a manifest that is missing, unreadable, empty, not JSON or not the
# v1 shape (`guardrails` must be an array; a row that is not an object spoils the lookup), a manifest path that is not absolute: each returns 0 and prints nothing (a hook's stdout is parsed and its
# stderr shown). A switch whose plumbing failure turned a guard off would be a guard that vanished.
#
# WHERE THE MANIFEST COMES FROM. $HMD_GUARDRAILS_MANIFEST (the tests' seam), else $CLAUDE_PLUGIN_ROOT/guardrails.manifest.json (the plugin root Claude Code hands every hook), else the one
# two directories above this file. The variables (these two and HEIMDALL_HOME) are read from the HOOK'S OWN environment, so, as with HMD_CI_RERUN_ALLOW and the other overrides of precheck-bash,
# an inline prefix on a command an agent types never reaches them. Never the cwd: a stranger's manifest must not decide which guards are core, so a relative path is refused, and this file's own
# path is made absolute when it is sourced (BASH_SOURCE inside a function is the path as it was given to `.`, which a later cd would turn toward whatever repository the hook happens to run in).
# The manifest is validated before it ships (bin/lib/guardrails_manifest.py, test/guardrails-manifest-drift.test.sh); this reader trusts what jq can see, which is not a key repeated inside one
# row (jq keeps the last).
#
# CALL SITE. The one status that means "skip the guard" is 1, so test for exactly 1: `! hmd_guardrail_enabled x` would read any failure, a 127 included, as "switched off".
#   . "$PLUGIN/bin/lib/hmd_guardrail_enabled.sh" 2>/dev/null && { hmd_guardrail_enabled ci-waste-guard; [ "$?" -eq 1 ]; } && <skip the guard>
# A lib that cannot be sourced leaves the guard running. In a script with `set -e`, check `[ -r ]` before the `.` (test/source-guard-lint.test.sh) and call the function in a condition: a 1 is an
# answer, not a failure.
#
# CHEAP. A hook fires on every tool call. With no guardrails-off file a call is one `[ -f ]`; with one it costs a grep; jq starts only for an id that IS in the file.
# Every name here starts hmd_guardrail_enabled / HMD_GUARDRAIL_ENABLED, so sourcing it into a hook cannot collide with the hook's own. Bash 3.2 (macOS /bin/bash), dash and zsh; nounset-safe.
# Proof: test/guardrail-enabled.test.sh.

# This file's own absolute path, fixed now, while PWD is still the directory it was sourced from. Empty (not bash) means no manifest of its own: the manifest is then found through the override
# or CLAUDE_PLUGIN_ROOT, or not at all.
HMD_GUARDRAIL_ENABLED_LIB="${BASH_SOURCE:-}"
case "$HMD_GUARDRAIL_ENABLED_LIB" in
  '' | /*) ;;
  *) HMD_GUARDRAIL_ENABLED_LIB="${PWD:-.}/$HMD_GUARDRAIL_ENABLED_LIB" ;;
esac

# hmd_guardrail_enabled_manifest -- the manifest this check believes, on stdout, or nothing when there is none to name: the override, else the plugin root, else beside this file.
hmd_guardrail_enabled_manifest() {
  if [ -n "${HMD_GUARDRAILS_MANIFEST:-}" ]; then
    printf '%s' "$HMD_GUARDRAILS_MANIFEST"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s/guardrails.manifest.json' "$CLAUDE_PLUGIN_ROOT"
  elif [ -n "${HMD_GUARDRAIL_ENABLED_LIB:-}" ]; then
    printf '%s/../../guardrails.manifest.json' "${HMD_GUARDRAIL_ENABLED_LIB%/*}"
  fi
}

# hmd_guardrail_enabled <id> -- exit 1 when the operator switched the guard off and the manifest calls it recommended; exit 0 for everything else.
hmd_guardrail_enabled() {
  local id="${1:-}" home file meta verdict
  [ -n "$id" ] || return 0
  home="${HEIMDALL_HOME:-${HOME:-/tmp}/.heimdall}"
  case "$home" in /*) ;; *) return 0 ;; esac
  file="$home/guardrails-off"
  [ -f "$file" ] || return 0
  grep -qxF -- "$id" "$file" 2>/dev/null || return 0
  command -v jq >/dev/null 2>&1 || return 0
  meta="$(hmd_guardrail_enabled_manifest)"
  case "$meta" in /*) ;; *) return 0 ;; esac
  [ -f "$meta" ] || return 0
  verdict="$(jq -r --arg id "$id" '.guardrails | type == "array" and ([.[] | select(.id == $id)] | length == 1 and .[0].tier == "recommended")' "$meta" 2>/dev/null)" || return 0
  [ "$verdict" = true ] || return 0
  return 1
}

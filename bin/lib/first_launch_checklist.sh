#!/usr/bin/env bash
# bin/lib/first_launch_checklist.sh -- a fresh hmd SHOWS the skills it could add on the first launch; nothing is installed unasked.
#
# WHAT IT IS. One sourceable function, called by first_run_setup (bin/heimdall) before the first-run installs:
#
#     if type hmd_first_launch_checklist >/dev/null 2>&1 && hmd_first_launch_checklist; then _fr_go="$HMD_FLC_FIRST_RUN_GO"; fi
#
# Status 0: a person was asked and answered, and HMD_FLC_FIRST_RUN_GO says what that means for the first-run set (superpowers and the heimdall marketplace, one
# decision as ever): 0 install it, 1 do not. Status 1: nobody was asked, and the legacy flow goes on exactly as it always did (the consent gate, its rows, its line).
#
# WHEN IT ASKS. The consent gate (bin/lib/skills_consent.sh) would ask for the first-run set: consent `ask`, or `allowlist` with superpowers off the list. Not when the
# person already said yes (HMD_SKILLS_YES=1) or consent is `auto` (an install that predates the consent model, or an operator who chose it): those install as before. The
# setup marker is first_run_setup's own guard, so the list is shown once per setup.
#
# WHAT IT ASKS. skills_checklist.py draws ONE numbered list on the terminal -- the recommended entries of skills.manifest.json, then on a lean install the bundled
# skills it left out -- each with its why, and reads one line: numbers, a (all), Enter (none for now), n (never ask).
#     picks    each goes through `hmd skills install ID --yes`: the pick IS the consent, and the consent gate, the receipt and the lock rows are that command's own.
#              superpowers is the one exception in HOW (never in whether): it is the first-run set's key, so a pick of it sets HMD_FLC_FIRST_RUN_GO=0 and the legacy lines
#              install it and register the heimdall marketplace, consent basis `prompt`.
#     Enter    nothing is added; superpowers (when it was listed) is deferred through the gate with no menu: a `suggested` row and its one stderr line, as with no terminal.
#     n        nothing is added and every listed id is recorded `declined` (machine lock, via first-run): held back from `hmd skills suggest` until `--reset`.
# No terminal: no question (it would hang), ONE line pointing to `hmd skills suggest`, status 1 -- the gate then writes the `suggested` row as it always did.
#
# NEVER FATAL, NEVER WORSE THAN BEFORE: a missing tool, a failed python, a manifest it cannot read all give status 1 with the legacy flow intact. User-facing text never
# names the coding agent underneath. Bash 3.2 compatible, no side effect when sourced, safe under `set -euo pipefail` (call it inside `if`).

# shellcheck disable=SC2034  # HMD_FLC_FIRST_RUN_GO is the function's published result: the caller reads it

[ -n "${_HMD_FIRST_LAUNCH_CHECKLIST_SH:-}" ] && return 0 2>/dev/null || true
_HMD_FIRST_LAUNCH_CHECKLIST_SH=1

# This file's own directory, from builtins only (the gate's rule): the tools beside it are found whatever PATH is.
_hmd_flc_src="${BASH_SOURCE[0]:-$0}"
case "$_hmd_flc_src" in */*) _hmd_flc_src="${_hmd_flc_src%/*}" ;; *) _hmd_flc_src=. ;; esac
_HMD_FLC_LIB_DIR="$(CDPATH='' cd "$_hmd_flc_src" && pwd)"
unset _hmd_flc_src

# The gate's own functions (settings, terminal test, lock rows) are the ones used: this file decides nothing about consent itself.
if ! type _hmd_sc_resolve >/dev/null 2>&1 && [ -f "$_HMD_FLC_LIB_DIR/skills_consent.sh" ]; then
  # shellcheck disable=SC1091  # skills_consent.sh sits beside this file; the path is only known at run time
  . "$_HMD_FLC_LIB_DIR/skills_consent.sh" 2>/dev/null || true
fi

# IDS -> the ids as separate words, each one a valid skill token (the lock's id rule); anything else is dropped.
_hmd_flc_tokens() {
  local id
  for id in $1; do
    _hmd_sc_token_ok "$id" && printf '%s\n' "$id"
  done
  return 0
}

hmd_first_launch_checklist() {
  local verdict="" listed="" action="" id="" failed=0 sp_listed=0
  HMD_FLC_FIRST_RUN_GO=1
  type _hmd_sc_resolve >/dev/null 2>&1 && type _hmd_sc_record >/dev/null 2>&1 || return 1
  [ "${HMD_SKILLS_YES:-}" != 1 ] || return 1
  _hmd_sc_resolve
  [ "$_HMD_SC_BROKEN" = 0 ] || return 1
  case "$_HMD_SC_MODE" in
    ask) ;;
    allowlist) if _hmd_sc_allowed superpowers; then return 1; fi ;;
    *) return 1 ;;
  esac
  if ! _hmd_sc_interactive; then
    printf '  No terminal to ask on, so no skills were added. See what is available: hmd skills suggest\n'
    return 1
  fi
  verdict="$(python3 -I "$_HMD_FLC_LIB_DIR/skills_checklist.py" ask)" || return 1
  { IFS= read -r listed || true; IFS= read -r action || true; } <<<"$verdict"
  case "$listed" in "listed "*) listed="${listed#listed }" ;; *) return 1 ;; esac
  case " $listed " in *" superpowers "*) sp_listed=1 ;; esac

  case "$action" in
    pick|pick\ *)
      for id in $(_hmd_flc_tokens "${action#pick}"); do
        if [ "$id" = superpowers ]; then
          HMD_FLC_FIRST_RUN_GO=0
          HMD_SKILLS_CONSENT_BASIS=prompt
        else
          bash "$_HMD_FLC_LIB_DIR/../heimdall-skills" install "$id" --yes || failed=$((failed + 1))
        fi
      done
      if [ "$failed" -gt 0 ]; then
        printf '  %s of the picked skills could not be added (the lines above say why). Try again with: hmd skills install ID\n' "$failed"
      fi ;;
    never)
      for id in $(_hmd_flc_tokens "$listed"); do
        _hmd_sc_record "$id" first-run declined
      done
      printf '  Noted: hmd will not ask about these again. hmd skills suggest --reset brings them back.\n' ;;
    *)
      printf '  Nothing added. See what is available any time: hmd skills suggest\n' ;;
  esac

  # superpowers was on the list and was not picked: the same deferral the gate writes with no terminal (a `suggested` row, one stderr line).
  if [ "$sp_listed" = 1 ] && [ "$HMD_FLC_FIRST_RUN_GO" = 1 ] && [ "$action" != never ]; then
    HMD_SKILLS_ASSUME=notty hmd_skills_consent superpowers first-run || true
  fi
  return 0
}

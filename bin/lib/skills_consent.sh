#!/usr/bin/env bash
# bin/lib/skills_consent.sh -- the consent gate for NEW skill installs (3.x M1, T3.5 of
# docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, "Consent model").
#
# WHAT IT IS. One sourceable function, asked by every call site BEFORE it installs a recommended skill or plugin:
#
#     hmd_skills_consent <id> <via> && <the existing install call>
#
# <id> is the manifest id (frontend-design, superpowers, ...). <via> is the path that asks: `first-run*` (the first-run
# installs: their lock rows live in the machine lock), `hmd-skills-install` (a person or an agent ran the command: an
# EXPLICIT ask), anything else (prompt-preinstall, ...) is an automatic one and its rows live in the project lock.
# The gate never installs anything itself and never touches the receipt.
#
# STATUS (the function's return value)
#     0   install now. HMD_SKILLS_CONSENT_BASIS holds the value for the lock row's `consent` field, which the caller
#         records with its `installed` row: yes-flag (HMD_SKILLS_YES=1), auto-legacy (consent auto, grandfathered),
#         explicit (consent auto, chosen by the operator), allowlist (the id is on the allowlist), prompt (a person
#         answered Install now). On every other status the basis is `n/a`.
#     10  defer. Nothing is installed, the id's lock row becomes `suggested`, ONE line goes to stderr. A command such as
#         `hmd skills install` turns it into exit 3, "consent required".
#     11  declined. Nothing is installed, the row is `declined`, nothing is printed. An automatic via is not asked again
#         until `hmd skills suggest --reset`; an explicit one is asked again (a person typed the command), and a deferred
#         explicit attempt leaves the decline in place.
#     Under `set -e` call it inside `&&` / `if`, or as `hmd_skills_consent ID VIA || rc=$?`.
#
# THE DECISION (settings come from skills_config.py, so only the operator's environment and $HEIMDALL_HOME/skills-config.json
# count: a repository cannot choose its operator's consent mode)
#     HMD_SKILLS_YES=1 (exactly 1) -> 0, in every mode. Otherwise by `consent`:
#     auto       -> 0.
#     allowlist  -> 0 when the allowlist names the id; any other id is handled like `ask`.
#     ask        -> a terminal ([ -t 0 ] && [ -t 1 ]): the menu Install now / Not now / Never ask again, drawn by hmd_select
#                   (bin/lib/select.sh), opening on Not now; ESC, EOF and the default are Not now. No terminal -> 10.
#     A caller that runs its own one-question batch prompt answers "all" with HMD_SKILLS_YES=1 and "none" with
#     HMD_SKILLS_ASSUME=notty (no menu, the deferral is recorded).
#
# WHEN SOMETHING IS WRONG: the setup marker, $HEIMDALL_HOME/setup-done, says whether this install predates the consent
# model. `skills_config.py get` never fails: a file it cannot use reads as the restrictive default (ask), so the gate
# checks for itself. No usable settings (no answer from the tool, a file that is not a JSON object or cannot be read) or
# no settings file at all, WITH the marker: a legacy install keeps its behaviour, so 0 (basis auto-legacy; the grandfather
# rule of `skills_config.py init`, applied in memory, and nothing is written). Unreadable settings WITHOUT the marker:
# a new install defers (10) without opening a menu. A value that is not allowed (a typo) is not "unreadable": it reads as
# the default ask, marker or not, so a typo never moves consent toward install. A malformed id is never installed (10).
# The lock is bookkeeping: a lock that cannot be read or written prints the lock tool's own line and changes no decision.
#
# ENVIRONMENT (all optional)
#     HMD_SKILLS_YES        1 = the person already said yes (`hmd skills install --yes`).
#     HMD_SKILLS_CONSENT    ask|allowlist|auto, read by skills_config.py (beats the file).
#     HMD_INSTALL_WHY_RULE / HMD_INSTALL_WHY_EVIDENCE   why.rule and why.evidence of the `suggested` / `declined` row: the
#                           trigger that fired and the matched token or path, never prompt text (the lock cuts it to 64).
#     HMD_SKILLS_ASSUME     TEST SEAM and non-interactive switch. `tty` behaves as if stdin and stdout were a terminal
#                           and lets the menu read its keys from stdin (HMD_SELECT_FORCE_TTY for that one call), so a pipe
#                           can drive it: k = up, j = down, Enter confirms. `notty` never opens a menu, terminal or not.
#                           Unset (the normal case) detects the terminal. test/skills-consent-gate.test.sh proves the real
#                           detection with a pty and no seam.
#     HEIMDALL_HOME         the settings, the setup marker and the machine lock (default ~/.heimdall).
#
# FILES. Siblings in this directory: skills_config.py, skills_lock.py, select.sh (sourced only when a menu is needed); the
# manifest two levels up (skills.manifest.json) supplies kind, ref, source and the line the menu shows.
# Bash 3.2 compatible, no side effect when sourced, safe under `set -euo pipefail`.

# shellcheck disable=SC2034  # HMD_SKILLS_CONSENT_BASIS is the function's published result: the caller reads it

[ -n "${_HMD_SKILLS_CONSENT_SH:-}" ] && return 0 2>/dev/null || true
_HMD_SKILLS_CONSENT_SH=1

# This file's own directory, from builtins only: a stripped PATH cannot break the lookup of the tools beside it.
_hmd_sc_src="${BASH_SOURCE[0]:-$0}"
case "$_hmd_sc_src" in */*) _hmd_sc_src="${_hmd_sc_src%/*}" ;; *) _hmd_sc_src=. ;; esac
_HMD_SKILLS_LIB_DIR="$(CDPATH='' cd "$_hmd_sc_src" && pwd)"
unset _hmd_sc_src
_HMD_SKILLS_MANIFEST="$_HMD_SKILLS_LIB_DIR/../../skills.manifest.json"

# Is the settings file a JSON object? (`skills_config.py get` already reported a file it could not use, so no stderr here.)
_HMD_SC_PY_USABLE='import json, sys
sys.exit(0 if isinstance(json.load(open(sys.argv[1], encoding="utf-8")), dict) else 1)'

# The manifest's words about one id: kind, ref, source, why -- four lines, printable ASCII, empty when it does not say.
_HMD_SC_PY_LOOKUP='import json, re, sys

def clean(value, cap):
    return re.sub(r"[^ -~]", "?", value).strip()[:cap] if isinstance(value, str) else ""

rows = []
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
    for entry in doc["entries"]:
        if entry["id"] == sys.argv[2]:
            repo = entry.get("repo")
            if entry["kind"] == "plugin":
                source = doc["marketplaces"][entry["marketplace"]]["source"]
            else:
                source = "github.com/" + repo if repo else None
            rows = [entry["kind"], entry.get("ref") or repo, source, entry.get("why")]
            break
except Exception as exc:
    sys.exit("skills-consent: cannot read the manifest %s: %s" % (sys.argv[1], type(exc).__name__))
for value in rows:
    print(clean(value, 120))'

# _hmd_sc_token_ok TEXT: one short token, letters digits . _ @ / + : - and a letter or digit first (the lock's id rule).
# Nothing else gets near a terminal, a glob pattern or an argument list.
_hmd_sc_token_ok() {
  local LC_ALL=C
  case "$1" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._@/+:-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# VIA -> _HMD_SC_SCOPE: first-run installs are machine rows, everything else is "this project needed it".
_hmd_sc_scope_of() {
  case "$1" in
    first-run*) _HMD_SC_SCOPE=machine ;;
    *) _HMD_SC_SCOPE=project ;;
  esac
  return 0
}

# ID -> _HMD_SC_KIND / _REF / _SOURCE / _WHY from the manifest; all empty when it does not list the id.
_hmd_sc_lookup() {
  local out=""
  _HMD_SC_KIND=""; _HMD_SC_REF=""; _HMD_SC_SOURCE=""; _HMD_SC_WHY=""
  out="$(python3 -I -c "$_HMD_SC_PY_LOOKUP" "$_HMD_SKILLS_MANIFEST" "$1")" || return 0
  { IFS= read -r _HMD_SC_KIND || true; IFS= read -r _HMD_SC_REF || true; IFS= read -r _HMD_SC_SOURCE || true; IFS= read -r _HMD_SC_WHY || true; } <<<"$out"
  return 0
}

# ID VIA STATE: one lock row. Best effort on purpose: a lock that cannot be written is the lock tool's own stderr line,
# and never a different decision.
_hmd_sc_record() {
  local -a args
  _hmd_sc_scope_of "$2"
  _hmd_sc_lookup "$1"
  args=(record --scope "$_HMD_SC_SCOPE" --id "$1" --state "$3" "--via=$2")
  if [ -n "$_HMD_SC_KIND" ]; then args+=("--kind=$_HMD_SC_KIND"); fi
  if [ -n "$_HMD_SC_REF" ]; then args+=("--ref=$_HMD_SC_REF"); fi
  if [ -n "$_HMD_SC_SOURCE" ]; then args+=("--source=$_HMD_SC_SOURCE"); fi
  if [ -n "${HMD_INSTALL_WHY_RULE:-}" ]; then args+=("--rule=$HMD_INSTALL_WHY_RULE"); fi
  if [ -n "${HMD_INSTALL_WHY_EVIDENCE:-}" ]; then args+=("--evidence=$HMD_INSTALL_WHY_EVIDENCE"); fi
  python3 -I "$_HMD_SKILLS_LIB_DIR/skills_lock.py" "${args[@]}" || true
  return 0
}

# ID VIA -> 0 when the id's lock row (in the scope VIA writes to) says declined. The probe's stderr is dropped: no row is
# the normal answer, and a damaged lock is reported by the record that follows.
_hmd_sc_declined() {
  local row=""
  _hmd_sc_scope_of "$2"
  row="$(python3 -I "$_HMD_SKILLS_LIB_DIR/skills_lock.py" read --scope "$_HMD_SC_SCOPE" --id "$1" 2>/dev/null)" || return 1
  case "$row" in *'"state": "declined"'*) return 0 ;; esac
  return 1
}

# ID VIA WHY KEEP: record `suggested` (unless KEEP is 1: a decline is lifted only by `hmd skills suggest --reset`), say so
# on one stderr line, answer 10.
_hmd_sc_defer() {
  [ "$4" = 1 ] || _hmd_sc_record "$1" "$2" suggested
  printf 'hmd: recommended skill %s not installed (%s): hmd skills suggest\n' "$1" "$3" >&2
  return 10
}

# Nothing trustworthy says what the operator chose. The setup marker says whether this install predates the consent
# model (keep its behaviour: install) or is new (defer, and open no menu).
_hmd_sc_unknown() {
  if [ "$_HMD_SC_MARKER" = 1 ]; then
    _HMD_SC_MODE=auto
    _HMD_SC_LEGACY=1
  else
    _HMD_SC_BROKEN=1
  fi
  return 0
}

# -> _HMD_SC_MODE (ask|allowlist|auto), _HMD_SC_LEGACY (1: auto because of the marker, nothing was chosen), _HMD_SC_BROKEN
# (1: new install, settings unreadable). Costs one python start on the usual path.
_hmd_sc_resolve() {
  local home mode=""
  _HMD_SC_MODE=ask; _HMD_SC_LEGACY=0; _HMD_SC_BROKEN=0; _HMD_SC_MARKER=0
  home="${HEIMDALL_HOME:-${HOME:-}/.heimdall}"
  [ -f "$home/setup-done" ] && _HMD_SC_MARKER=1
  mode="$(python3 -I "$_HMD_SKILLS_LIB_DIR/skills_config.py" get consent)" || mode=""
  case "$mode" in
    ask|allowlist|auto) _HMD_SC_MODE="$mode" ;;
    *) _hmd_sc_unknown; return 0 ;;
  esac
  # `get` answers ask for a file it cannot use. Only the file tier is in doubt, so when the operator's environment did
  # not decide and `ask` came back, look at the file itself.
  if [ "$mode" = ask ] && [ -z "${HMD_SKILLS_CONSENT:-}" ]; then
    if [ ! -e "$home/skills-config.json" ]; then
      # No settings file at all: the grandfather rule `skills_config.py init` applies at first run, applied in memory.
      if [ "$_HMD_SC_MARKER" = 1 ]; then _HMD_SC_MODE=auto; _HMD_SC_LEGACY=1; fi
    elif ! python3 -I -c "$_HMD_SC_PY_USABLE" "$home/skills-config.json" 2>/dev/null; then
      _hmd_sc_unknown
    fi
  fi
  return 0
}

# ID -> 0 when the allowlist names exactly that id (a whole line, never a prefix or a pattern).
_hmd_sc_allowed() {
  local list="" nl=$'\n'
  list="$(python3 -I "$_HMD_SKILLS_LIB_DIR/skills_config.py" get allowlist)" || return 1
  case "$nl$list$nl" in
    *"$nl$1$nl"*) return 0 ;;
  esac
  return 1
}

# -> 0 when a person can be asked: a terminal on stdin and stdout, or the HMD_SKILLS_ASSUME seam.
_hmd_sc_interactive() {
  case "${HMD_SKILLS_ASSUME:-}" in
    tty) return 0 ;;
    notty) return 1 ;;
  esac
  [ -t 0 ] && [ -t 1 ]
}

# ID -> 0 once HMD_SELECT_INDEX holds the answer (0 Install now, 1 Not now, 2 Never ask again); 1 when no menu could be shown.
_hmd_sc_prompt() {
  local header
  if ! type hmd_select >/dev/null 2>&1; then
    if [ ! -f "$_HMD_SKILLS_LIB_DIR/select.sh" ]; then
      printf 'skills-consent: %s/select.sh is missing, so nobody can be asked\n' "$_HMD_SKILLS_LIB_DIR" >&2
      return 1
    fi
    # shellcheck disable=SC1091  # select.sh sits beside this file; the path is only known at run time
    . "$_HMD_SKILLS_LIB_DIR/select.sh" || return 1
  fi
  _hmd_sc_lookup "$1"
  header="hmd: install skill $1"
  if [ -n "$_HMD_SC_REF" ]; then header="$header ($_HMD_SC_REF${_HMD_SC_SOURCE:+, from $_HMD_SC_SOURCE})"; fi
  header="$header?"
  if [ -n "$_HMD_SC_WHY" ]; then header="$header $_HMD_SC_WHY"; fi
  if [ "${HMD_SKILLS_ASSUME:-}" = tty ]; then
    HMD_SELECT_FORCE_TTY=1 hmd_select 1 "$header" "Install now" "Not now" "Never ask again"
  else
    hmd_select 1 "$header" "Install now" "Not now" "Never ask again"
  fi
  return 0
}

hmd_skills_consent() {
  local id="${1:-}" via="${2:-}" explicit=0 was_declined=0
  HMD_SKILLS_CONSENT_BASIS=n/a
  if ! _hmd_sc_token_ok "$id"; then
    printf 'skills-consent: no usable skill id was given; deferring\n' >&2
    return 10
  fi
  _hmd_sc_token_ok "$via" || via=unspecified
  if [ "$via" = hmd-skills-install ]; then explicit=1; fi

  if [ "${HMD_SKILLS_YES:-}" = 1 ]; then
    HMD_SKILLS_CONSENT_BASIS=yes-flag
    return 0
  fi

  _hmd_sc_resolve
  case "$_HMD_SC_MODE" in
    auto)
      HMD_SKILLS_CONSENT_BASIS=explicit
      if [ "$_HMD_SC_LEGACY" = 1 ] || [ "$(python3 -I "$_HMD_SKILLS_LIB_DIR/skills_config.py" get grandfathered 2>/dev/null)" = true ]; then
        HMD_SKILLS_CONSENT_BASIS=auto-legacy
      fi
      return 0 ;;
    allowlist)
      if _hmd_sc_allowed "$id"; then
        HMD_SKILLS_CONSENT_BASIS=allowlist
        return 0
      fi ;;
  esac

  # A person decides (ask, or an id the allowlist does not name), or nobody does.
  _hmd_sc_declined "$id" "$via" && was_declined=1
  if [ "$was_declined" = 1 ] && [ "$explicit" = 0 ]; then return 11; fi
  if [ "$_HMD_SC_BROKEN" = 1 ]; then
    _hmd_sc_defer "$id" "$via" "consent settings unreadable" "$was_declined"
    return
  fi
  if _hmd_sc_interactive && _hmd_sc_prompt "$id"; then
    case "${HMD_SELECT_INDEX:-1}" in
      0) HMD_SKILLS_CONSENT_BASIS=prompt; return 0 ;;
      2) _hmd_sc_record "$id" "$via" declined; return 11 ;;
    esac
  fi
  _hmd_sc_defer "$id" "$via" "consent=$_HMD_SC_MODE" "$was_declined"
}

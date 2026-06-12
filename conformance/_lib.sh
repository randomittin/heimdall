#!/usr/bin/env bash
# _lib.sh — shared assertion helpers for heimdall parity-conformance fixtures.
#
# These fixtures are DEFINED, not yet CI-wired (see conformance/README.md).
# Each fixture sources this file, then runs setup/run/assert. Asserts print
# `OK <row>` / `BAD <row>` and accumulate a failure count; the fixture exits
# nonzero iff any assert failed, so a future CI step can iterate INDEX.json and
# trust exit codes.
#
# No model is ever invoked. Every check is mechanical: exit code, output shape,
# file presence, JSON field. Real assertions throughout.

set -uo pipefail

# Resolve the heimdall plugin root (the repo this fixture lives in: conformance/..).
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$_LIB_DIR/.." && pwd)"
BIN="$PLUGIN_ROOT/bin"
export PLUGIN_ROOT BIN

# Put bin on PATH so cross-bin calls (e.g. conflict-log -> heimdall-state) resolve.
export PATH="$BIN:$PATH"

_FAILS=0
_ROW="${ROW:-unknown-row}"

ok()   { printf 'OK [%s] %s\n'   "$_ROW" "$*"; }
bad()  { printf 'BAD [%s] %s\n'  "$_ROW" "$*"; _FAILS=$((_FAILS+1)); }
note() { printf 'NOTE [%s] %s\n' "$_ROW" "$*"; }

# assert_exit <expected> <actual> <msg>
assert_exit() {
  local exp="$1" act="$2" msg="$3"
  if [ "$exp" = "$act" ]; then ok "$msg (exit=$act)"; else bad "$msg (want exit $exp got $act)"; fi
}

# assert_contains <haystack> <needle> <msg>
# Use a here-string (not a pipe) so grep -q closing the pipe early cannot raise
# SIGPIPE (141) on large inputs under `set -o pipefail`.
assert_contains() {
  local hay="$1" needle="$2" msg="$3"
  if grep -qF -- "$needle" <<<"$hay"; then ok "$msg"; else bad "$msg (missing: $needle)"; fi
}

# assert_grep <regex> <text> <msg>  (extended regex, case-insensitive)
assert_grep() {
  local re="$1" text="$2" msg="$3"
  if grep -qiE -- "$re" <<<"$text"; then ok "$msg"; else bad "$msg (no match: $re)"; fi
}

# assert_file <path> <msg>
assert_file() {
  if [ -f "$1" ]; then ok "$2"; else bad "$2 (no file: $1)"; fi
}

# assert_json_field <file> <jq-path> <msg>   (field present & non-null)
assert_json_field() {
  local f="$1" path="$2" msg="$3"
  if command -v jq >/dev/null 2>&1; then
    local v; v="$(jq -r "$path // empty" "$f" 2>/dev/null)"
    if [ -n "$v" ]; then ok "$msg ($path=$v)"; else bad "$msg ($path absent/null)"; fi
  else note "$msg (jq unavailable)"; fi
}

# Make an isolated scratch workspace; echoes its path. Caller cd's into it.
mk_workspace() {
  local tmpl; tmpl="hmd-conf.$(printf 'X%.0s' 1 2 3 4 5 6)"
  mktemp -d "${TMPDIR:-/tmp}/$tmpl"
}

finish() {
  if [ "$_FAILS" -eq 0 ]; then printf 'RESULT [%s] OK\n' "$_ROW"; exit 0
  else printf 'RESULT [%s] %d BAD\n' "$_ROW" "$_FAILS"; exit 1; fi
}

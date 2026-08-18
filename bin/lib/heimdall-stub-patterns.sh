#!/usr/bin/env bash
# bin/lib/heimdall-stub-patterns.sh — shared stub/placeholder code-shape patterns.
#
# WHAT IT IS. The single source of truth for "what counts as an unfinished-code
# shape", shared by TWO independent enforcement points that must never drift apart:
#   1. hooks/hooks.json's Write|Edit PreToolUse hook — Claude Code only, fires live
#      on every write inside a Claude Code session.
#   2. bin/heimdall-gate-run's pre-commit stub-scan — tool-agnostic, fires on the
#      staged git diff no matter which tool or human made the commit.
#
# SHAPE-BASED, NOT WORD-BASED. Every pattern here matches a CODE SHAPE (an empty
# function body, a not-finished throw, a comment-form marker) — never a bare word.
# A bare-word approach false-positives on Roman numerals, docs discussing this very
# policy, and test fixtures — see test/heimdall-stub-scanner.test.sh's docstring
# for the incident that fixed. Do not reintroduce bare-word matching here.
#
# USAGE.
#   . bin/lib/heimdall-stub-patterns.sh
#   heimdall_stub_exempt_path "$path"              # 0 = exempt (docs/data/fixtures)
#   printf '%s' "$content" | heimdall_stub_match   # prints matched shape + returns
#                                                   # 0, or prints nothing + returns
#                                                   # 1 when the content is clean
#
# Bash 3.2 (macOS system bash) compatible — no associative arrays, no mapfile.
set -u

[ -n "${_HEIMDALL_STUB_PATTERNS_SH:-}" ] && return 0 2>/dev/null || true
_HEIMDALL_STUB_PATTERNS_SH=1

# ── the 5 shapes — identical to hooks/hooks.json's Write|Edit hook ────────────
HEIMDALL_STUB_RE_TODO='(//|#)[[:space:]]*(TODO|FIXME)'
HEIMDALL_STUB_RE_NOTIMPL_MARKER='NotImplemented''Error|unimplemented!\(\)|todo!\(\)'
HEIMDALL_STUB_RE_NOTIMPL_THROW='throw new Error\([^)]*not implemented[^)]*\)'   # matched case-insensitively by the caller
HEIMDALL_STUB_RE_PASS_ONLY='^[[:space:]]*pass[[:space:]]*$'
HEIMDALL_STUB_RE_EMPTY_FN='\([^)]*\)[[:space:]]*=>[[:space:]]*\{[[:space:]]*\}|function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}|function[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}'

# heimdall_stub_exempt_path <path> — 0 = exempt, 1 = scan it. Mirrors hooks.json's
# Write|Edit case statement exactly (docs, data, fixtures/evals content).
heimdall_stub_exempt_path() {
  case "$1" in
    *.md|*.txt|*.json|*.ndjson|*/fixtures/*|fixtures/*|*/evals/*|evals/*) return 0 ;;
    *) return 1 ;;
  esac
}

# heimdall_stub_match — reads candidate content on stdin, prints the FIRST matched
# shape's human label on stdout and returns 0; prints nothing and returns 1 if none
# of the 5 shapes match. Check order mirrors hooks.json's Write|Edit hook exactly.
heimdall_stub_match() {
  local content
  content="$(cat)"
  if printf '%s\n' "$content" | grep -qE "$HEIMDALL_STUB_RE_TODO"; then
    printf 'code-comment TODO/FIXME'; return 0
  fi
  if printf '%s\n' "$content" | grep -qE "$HEIMDALL_STUB_RE_NOTIMPL_MARKER"; then
    printf 'not-finished marker (NotImplemented''Error, or a Rust todo/unimplemented macro)'; return 0
  fi
  if printf '%s\n' "$content" | grep -qiE "$HEIMDALL_STUB_RE_NOTIMPL_THROW"; then
    printf 'not-implemented throw'; return 0
  fi
  if printf '%s\n' "$content" | grep -qE "$HEIMDALL_STUB_RE_PASS_ONLY"; then
    printf 'pass-only body'; return 0
  fi
  if printf '%s\n' "$content" | grep -qE "$HEIMDALL_STUB_RE_EMPTY_FN"; then
    printf 'empty function body'; return 0
  fi
  return 1
}

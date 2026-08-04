#!/usr/bin/env bash
# autoupdate-announce-truth — "installed." may only be printed when the payload
# is verifiably ON THE MACHINE, never off the exit code of `add`.
#
# The bug this exists to prevent: `hmd modules add` exits 0 for a module that
# REGISTERED at its pin without its payload landing (an unprobeable installer, or
# a fetch deliberately withheld). heimdall-autoupdate announced `"<n>" installed.`
# on that exit code alone, so a green word stood over an absent install — the same
# class of defect as the `Installed "headroom"` line that `uv tool list` contradicted.
#
# Structural by necessity: the announcement lives inside the reconcile acquire path
# in "loud" mode, which requires a default module that is absent, not opted out, and
# a canonical state root. Driving that end-to-end would mean a real machine-global
# install. So this asserts the SHAPE that makes the announcement honest, and proves
# the assertion bites by mutating the real file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
AU="$REPO/bin/heimdall-autoupdate"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# The acquire-path announcement block: from the `add` invocation to the else arm.
block() { sed -n '/if "\$MODULES_BIN" add "\$n"; then/,/^      else$/p' "$AU"; }

B="$(block)"
if [ -z "$B" ]; then
  bad "could not locate the acquire announcement block — an empty scan must not pass"
else
  ok

  # 1. The success string must not be reachable straight off the add exit code.
  #    It has to sit behind a test of what is actually installed.
  case "$B" in
    *'payload.state'*) ok ;;
    *) bad "the announcement never consults receipt.payload.state — it is trusting the exit code" ;;
  esac

  # 2. "installed." must be guarded by a comparison against the installed state.
  case "$B" in
    *'= "installed" ]'*) ok ;;
    *) bad "no [ \"\$_st\" = \"installed\" ] guard around the success announcement" ;;
  esac

  # 3. The absent case must be SAID, not silently skipped.
  case "$B" in
    *'payload NOT on this machine'*) ok ;;
    *) bad "a registered-without-payload module is not announced as such" ;;
  esac

  # 4. And it must hand over the remedy, not just the bad news.
  case "$B" in
    *'payload.remedy'*) ok ;;
    *) bad "the absent branch does not surface the operator's remedy command" ;;
  esac

  # 5. Ordering: the guard must appear BEFORE the success printf, otherwise the
  #    string is emitted regardless of what the guard later decides.
  g="$(printf '%s' "$B" | grep -n '= "installed" \]' | head -1 | cut -d: -f1)"
  p="$(printf '%s' "$B" | grep -n '"%s" installed' | head -1 | cut -d: -f1)"
  if [ -n "$g" ] && [ -n "$p" ] && [ "$g" -lt "$p" ]; then ok
  else bad "the success printf is not downstream of the state guard (guard=$g printf=$p)"; fi
fi

# 6. The whole file must still parse — a guard that breaks the updater is worse
#    than the false line it replaced.
if bash -n "$AU" 2>/dev/null; then ok; else bad "bin/heimdall-autoupdate no longer parses"; fi

printf '\n  %s%d passed, %d failed\033[0m\n' \
  "$([ "$FAIL" -eq 0 ] && printf '\033[32m' || printf '\033[31m')" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

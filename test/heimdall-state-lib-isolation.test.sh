#!/usr/bin/env bash
# test/heimdall-state-lib-isolation.test.sh — heimdall-state must survive being
# deployed WITHOUT its bin/lib/ sibling.
#
# WHY THIS FILE EXISTS
# --------------------
# bin/heimdall-state sources bin/lib/hook-owned-path.sh at the top of the file,
# outside any function, before the subcommand `case` dispatch. The comment
# introducing that line calls it "DEFENSIVE, not required... never a reason to
# abort a state-management tool that has many other jq-only responsibilities
# unrelated to this one check" — i.e. the documented CONTRACT is that a missing
# lib degrades ONE check (the sweep-receipt staleness exemption), nothing more.
#
# That contract was violated by the original implementation:
#
#     . "$HMD_STATE_SELF_DIR/lib/hook-owned-path.sh" 2>/dev/null || true
#
# Under `set -e` (heimdall-state's line 4), bash treats `.`/`source` failing to
# OPEN a missing file as a hard abort of the WHOLE SCRIPT — the trailing
# `|| true` does not catch it (this is a real bash behaviour, not a typo:
# redirection/open failures on the dot-command are not subject to the normal
# "last command in an OR-list is exempt from set -e" rule the way a plain
# command's nonzero exit is). Concretely: a fake plugin root carrying ONLY
# bin/heimdall-state — exactly the shape test/pre-push-quality-gate-blocking.test.sh
# builds to isolate the gate under test, and exactly the shape any packaging
# step that ships bin/heimdall-state without its bin/lib/ subdirectory would
# produce — made EVERY subcommand (init, mark-clean, check-quality-gates, all
# of it) die immediately, before the case dispatch even read which subcommand
# was requested. That regression is what turned
# test/pre-push-quality-gate-blocking.test.sh case 1 red: check-quality-gates
# returned exit 1 (crash) instead of exit 2 (a real "gates failed" verdict),
# heimdall-precheck-bash's quality-gate branch treated exit 1 as
# "verdict UNAVAILABLE, allow", and the push sailed through unblocked.
#
# THIS FILE pins the actual contract down directly against bin/heimdall-state,
# independent of the precheck-bash wiring pre-push-quality-gate-blocking.test.sh
# exercises, so a future regression here is caught at the source rather than
# only as a downstream symptom three layers away.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_BIN="$REPO/bin/heimdall-state"
LIB="$REPO/bin/lib/hook-owned-path.sh"

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
bad() { fail=$((fail+1)); printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '\nheimdall-state — survives deployment without its bin/lib/ sibling\n'
printf -- '--------------------------------------------------------------------\n'

# A plugin root carrying ONLY heimdall-state -- no bin/lib/ subdirectory at all.
# Mirrors test/pre-push-quality-gate-blocking.test.sh's FAKE_PLUGIN exactly.
BARE="$WORK/bare/bin"
mkdir -p "$BARE"
cp "$STATE_BIN" "$BARE/heimdall-state"
chmod +x "$BARE/heimdall-state"

C="$WORK/case-bare"
mkdir -p "$C"

OUT="$(cd "$C" && "$BARE/heimdall-state" init 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then
  ok "bare plugin (no lib/) => init succeeds (exit 0)"
else
  bad "bare plugin (no lib/) => init succeeds (exit 0)" "got exit $RC; output=$OUT"
fi
if [ -f "$C/heimdall-state.json" ]; then
  ok "bare plugin => init actually wrote heimdall-state.json"
else
  bad "bare plugin => init actually wrote heimdall-state.json" "no state file at $C/heimdall-state.json"
fi

OUT="$(cd "$C" && "$BARE/heimdall-state" check-quality-gates 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then
  ok "bare plugin => check-quality-gates returns a REAL verdict (exit 2), not a crash"
else
  bad "bare plugin => check-quality-gates returns a REAL verdict (exit 2), not a crash" "got exit $RC; output=$OUT"
fi
if printf '%s' "$OUT" | grep -q 'GATE FAILED: Tests not passing'; then
  ok "bare plugin => the actual gate logic ran (named cause present)"
else
  bad "bare plugin => the actual gate logic ran (named cause present)" "output=$OUT"
fi

OUT="$(cd "$C" && "$BARE/heimdall-state" mark-clean 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then
  ok "bare plugin => mark-clean succeeds (exit 0)"
else
  bad "bare plugin => mark-clean succeeds (exit 0)" "got exit $RC; output=$OUT"
fi

OUT="$(cd "$C" && "$BARE/heimdall-state" check-quality-gates 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then
  ok "bare plugin => clean gates now pass end-to-end (exit 0)"
else
  bad "bare plugin => clean gates now pass end-to-end (exit 0)" "got exit $RC; output=$OUT"
fi

# --- control: identical sequence WITH bin/lib/ present, same results expected ---
FULL="$WORK/full/bin"
mkdir -p "$FULL/lib"
cp "$STATE_BIN" "$FULL/heimdall-state"
cp "$LIB" "$FULL/lib/hook-owned-path.sh"
chmod +x "$FULL/heimdall-state"

C2="$WORK/case-full"
mkdir -p "$C2"
OUT="$(cd "$C2" && "$FULL/heimdall-state" init 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then
  ok "control: plugin WITH lib/ present => init still succeeds (unaffected)"
else
  bad "control: plugin WITH lib/ present => init still succeeds (unaffected)" "got exit $RC; output=$OUT"
fi
OUT="$(cd "$C2" && "$FULL/heimdall-state" check-quality-gates 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then
  ok "control: plugin WITH lib/ present => check-quality-gates unaffected (exit 2)"
else
  bad "control: plugin WITH lib/ present => check-quality-gates unaffected (exit 2)" "got exit $RC; output=$OUT"
fi

printf -- '--------------------------------------------------------------------\n'
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

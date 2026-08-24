#!/usr/bin/env bash
#
# agent-pool-pressure.test.sh — falsifiable coverage for pressure-aware
# should-scale: bin/agent-pool's cmd_should_scale now consults
# bin/lib/pressure_control.py's AIMD recommend() before recommending a
# scale-up.
#
# THE GAP THIS CLOSES: pressure_control.recommend() computes a
# pressure-adjusted spawn ceiling, but nothing consulted it — a recorded 529
# changed no scaling behavior anywhere (commit 1fad13c landed the engine,
# with zero callers). This proves the wiring, not just the engine:
#
#   (a) NO recorded pressure -> should-scale's output/exit are BYTE-IDENTICAL
#       to pre-change behavior (captured empirically against the unmodified
#       binary before this suite was written).
#   (b) a threshold-breaching burst of 529s -> should-scale SUPPRESSES a
#       scale-up utilization would otherwise have granted, and the reduced
#       ceiling + reason are visible on stdout, not silently swallowed.
#   (c) FAIL OPEN: a corrupted pressure-state.json (c1), and an agent-pool
#       copy with pressure_control.py entirely absent (c2), both still
#       produce the plain pre-change SCALE UP verdict — never a refusal to
#       scale, never a crash. This is the falsifiability proof for the
#       fail-open contract; without it, "fails open" is asserted, not shown.
#
# THE HONEST LIMIT under test: should-scale is a recommendation over SPAWN
# decisions informed by past recorded failures — it cannot see or intercept
# a live HTTP response. See bin/lib/pressure_control.py's module docstring.
#
# HERMETIC: every case gets its own mktemp HOME. agent-pool.json AND
# pressure-state.json both live under $HOME/.heimdall/ (confirmed by
# resolve_state_file()/_resolve_pool_file() mirroring each other), exactly
# like test/heimdall-pressure.test.sh and test/agent-pool-stale-idle.test.sh.
# Never touches the real ~/.heimdall.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
POOL="$REPO/bin/agent-pool"
PRESSURE="$REPO/bin/heimdall-pressure"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

fresh_home() { mktemp -d "${TMPDIR:-/tmp}/agent-pool-pressure-test.XXXXXX"; }
pool() { python3 "$POOL" "$@"; }
pressure() { python3 "$PRESSURE" "$@"; }

# fill_to_util N -- acquire N agents into an already-init'd pool.
fill_to_util() {
  n="$1"; i=0
  while [ "$i" -lt "$n" ]; do
    pool acquire "agent-$i" worker --pid $$ >/dev/null
    i=$((i+1))
  done
}

echo "agent-pool-pressure harness"
echo "--------------------------------------------------------------------"

# ── (a) no recorded pressure -> byte-identical to pre-change behavior ───────
# Baseline captured empirically against the unmodified binary:
#   `SCALE UP: utilization=80% (8/10)`, exit 0.
export HOME; HOME="$(fresh_home)"
pool init --max 10 >/dev/null
fill_to_util 8   # 8/10 = 80% = default scale_up_threshold -> would scale up
out="$(pool should-scale)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "SCALE UP: utilization=80% (8/10)" ] \
  && ok "a. no pressure recorded -> should-scale output/exit byte-identical to pre-change" \
  || bad "a. got rc=$rc out='$out'"

# ── (b) threshold-breaching burst caps the scale-up, reason visible ─────────
export HOME; HOME="$(fresh_home)"
pool init --max 10 >/dev/null
fill_to_util 8
pressure record --kind overloaded_error >/dev/null
pressure record --kind overloaded_error >/dev/null
pressure record --kind overloaded_error >/dev/null   # breach threshold=3 -> factor 0.5
out="$(pool should-scale)"; rc=$?
echo "  (should-scale said: $out)"
[ "$rc" -eq 1 ] && ok "b1. burst pressure suppresses what would have been a scale-up (exit 1, not 0)" \
  || bad "b1. rc=$rc (want 1) out='$out'"
case "$out" in
  *"pressure-capped at 5/10"*"factor="*)
    ok "b2. reason is visible on stdout: reduced ceiling (5/10) + the real AIMD factor, not a canned string" ;;
  *)
    bad "b2. reduced ceiling/reason not visible in: '$out'" ;;
esac
# Cross-check: pressure_control's own recommendation for ceiling=10 after this
# exact burst independently matches the 5/10 should-scale surfaced.
rec="$(pressure recommend --ceiling 10)"
[ "$rec" = "5" ] && ok "b3. pressure_control's own recommend(--ceiling 10) is 5 (cross-check, not coincidence)" \
  || bad "b3. pressure recommend --ceiling 10 = '$rec', want 5"

# ── (c1) FAIL OPEN: corrupted pressure-state.json -> normal pre-change verdict ─
export HOME; HOME="$(fresh_home)"
pool init --max 10 >/dev/null
fill_to_util 8
mkdir -p "$HOME/.heimdall"
printf 'not json { garbage' > "$HOME/.heimdall/pressure-state.json"
out="$(pool should-scale 2>"$HOME/err.log")"; rc=$?
err="$(cat "$HOME/err.log")"
[ "$rc" -eq 0 ] && [ "$out" = "SCALE UP: utilization=80% (8/10)" ] && [ -z "$(grep -i traceback "$HOME/err.log")" ] \
  && ok "c1. corrupted pressure-state.json -> should-scale still returns the plain SCALE UP verdict (fail open)" \
  || bad "c1. rc=$rc out='$out' err='$err'"

# ── (c2) FAIL OPEN: pressure_control.py entirely absent -> normal verdict ───
# A bare copy of bin/agent-pool with NO lib/ sibling at all -- the import
# inside _pressure_recommend must ImportError and be swallowed, never crash
# and never suppress the scale-up.
export HOME; HOME="$(fresh_home)"
pool init --max 10 >/dev/null
fill_to_util 8
NOLIB_DIR="$(fresh_home)"
cp "$POOL" "$NOLIB_DIR/agent-pool"
out="$(python3 "$NOLIB_DIR/agent-pool" should-scale 2>"$HOME/err2.log")"; rc=$?
err="$(cat "$HOME/err2.log")"
[ "$rc" -eq 0 ] && [ "$out" = "SCALE UP: utilization=80% (8/10)" ] && [ -z "$(grep -i traceback "$HOME/err2.log")" ] \
  && ok "c2. pressure_control.py entirely missing -> should-scale still returns the plain SCALE UP verdict (fail open)" \
  || bad "c2. rc=$rc out='$out' err='$err'"

# ── (d) scale-down branch is untouched by the pressure cap (upper bound only) ─
export HOME; HOME="$(fresh_home)"
pool init --max 10 >/dev/null
fill_to_util 1   # 1/10 = 10% <= default scale_down_threshold(0.2)
pressure record --kind overloaded_error >/dev/null
pressure record --kind overloaded_error >/dev/null
pressure record --kind overloaded_error >/dev/null
out="$(pool should-scale)"; rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "SCALE DOWN possible: utilization=10% (1/10)" ] \
  && ok "d. pressure never forces/blocks a scale-down verdict — it is an upper bound on scale-up only" \
  || bad "d. got rc=$rc out='$out'"

echo "--------------------------------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

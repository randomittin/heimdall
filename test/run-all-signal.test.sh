#!/usr/bin/env bash
#
# run-all-signal.test.sh -- proves test/run-all.sh STOPS when it is sent SIGINT or SIGTERM.
#
# THE BUG THIS PINS (found 2026-10-02; the trap line dates from 2026-08-03):
#     trap cleanup EXIT INT TERM
# ran `cleanup` (rm -rf "$WORK") on INT/TERM and then let bash RESUME the script exactly
# where the signal interrupted it -- a trap handler that does not `exit` stops nothing. A
# sweep that was sent TERM therefore deleted its own work directory and carried on: every
# suite it launched afterwards failed to open its capture file, was classified
# `0s ? passed, ? failed`, the re-run-reds phase repeated that for all of them, and the
# walking corpse finished with "RUN RED -- 434 suite(s) not green" after 147s, wrote a sweep
# receipt saying so, and printed all of it into the SAME log as the real sweep that had been
# started in its place (`pkill -f test/run-all.sh` followed by a fresh sweep is how it got
# signalled). A red nobody could read, from a run that had been told to stop.
#
# What must hold now, for TERM and INT alike, in the parallel phase AND in the serial
# re-run-reds phase (there the runner is parked on ONE foreground suite, and bash defers a
# trap until a foreground command returns -- up to the suite's whole budget, 900s for
# install-stranger):
#   1. the runner exits promptly with 128+signal (143 / 130);
#   2. it prints no verdict and writes no receipt -- an interrupted sweep has none to give;
#   3. nothing it started outlives it (suites run in their own process group, so a signal
#      to the runner never reaches them on its own);
#   4. cleanup still runs: the work dir is removed and the gate marker released;
# and an uninterrupted run is untouched (control).
#
# Drives the REAL test/run-all.sh, copied into a throwaway git repo (never this repo), on
# fixture suites that park in `exec -a <unique name> sleep`. HOME/HEIMDALL_HOME point at a
# throwaway dir, so neither the real gate marker nor the real sweep receipt is touched.
#
# Usage:  bash test/run-all-signal.test.sh
# bash 3.2 compatible: no `wait -n`, no associative arrays, no mapfile.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REAL_RUNALL="$REPO/test/run-all.sh"
REAL_LIB="$REPO/bin/lib/hook-owned-path.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

[ -f "$REAL_RUNALL" ] || { echo "FATAL: $REAL_RUNALL not found" >&2; exit 2; }
[ -f "$REAL_LIB" ]    || { echo "FATAL: $REAL_LIB not found" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-all-signal.XXXXXX")"
[ -n "$ROOT" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }

# Every parked fixture carries this argv[0]. Liveness checks and teardown match on a name
# nothing else on the machine uses -- never on a bare pid, which the OS may have recycled
# by the time anyone looks.
PARK_NAME="run-all-signal-park-$$"
# A fixture parks this long. The bound a signalled runner must beat is shorter, so a runner
# that merely waits its suites out (the bug) cannot pass by accident.
PARK_SECS=12
EXIT_LIMIT_S=8
export PARK_NAME PARK_SECS

RUNNER_PID=""
CASE=""; SBX=""; HM=""; MARK=""; OUT=""
AWAIT_RC=0

reap_parked() {
  local p
  for p in $(pgrep -f "$PARK_NAME" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
}
parked_count() { pgrep -f "$PARK_NAME" 2>/dev/null | wc -l | tr -d ' '; }

# work_of PROBE_FILE -- the runner's WORK dir: the parent of the capture file a fixture's
# stdout points at (its own pid via lsof). Empty if lsof is absent or the path is not a
# run-all work dir, in which case the removal assertion is skipped, never faked.
work_of() {
  local p
  p="$(cat "$1" 2>/dev/null)"
  case "$p" in
    */heimdall-run-all.*/*.out) dirname "$p" ;;
    *) printf '' ;;
  esac
}

teardown() {
  local f w
  reap_parked
  [ -n "$RUNNER_PID" ] && kill -KILL "$RUNNER_PID" 2>/dev/null
  for f in "$ROOT"/*/mark/work-probe; do
    [ -f "$f" ] || continue
    w="$(work_of "$f")"
    [ -n "$w" ] && rm -rf "$w"
  done
  rm -rf "$ROOT"
}
trap teardown EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# new_case LABEL -- a throwaway repo holding the REAL run-all.sh and its lib, plus a private
# home (gate marker + receipt) and mark dir (fixture -> harness notes). Fixture suites are
# written into $SBX/test by the caller, then commit_case.
new_case() {
  CASE="$1"
  SBX="$ROOT/$CASE/repo"; HM="$ROOT/$CASE/home"; MARK="$ROOT/$CASE/mark"; OUT="$ROOT/$CASE/out.txt"
  mkdir -p "$SBX/test" "$SBX/bin/lib" "$HM" "$MARK"
  cp "$REAL_RUNALL" "$SBX/test/run-all.sh"
  cp "$REAL_LIB" "$SBX/bin/lib/hook-owned-path.sh"
}
commit_case() {
  ( cd "$SBX" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture ) >/dev/null 2>&1
}

# Fixture suites. Each is a standalone script run by the runner as `bash <suite>` with its
# stdout redirected into the runner's WORK dir, which is what the lsof probe reads.
write_parker() { # NAME -- parks until signalled; p1 also records the runner's WORK dir
  cat > "$SBX/test/$1.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
n="$(basename "$0" .test.sh)"
if [ "$n" = "p1" ]; then
  { lsof -a -p $$ -d 1 -Fn 2>/dev/null | sed -n 's/^n//p'; } > "$MARK/work-probe"
fi
exec -a "$PARK_NAME" sleep "$PARK_SECS"
FIXEOF
}
write_quick() { # NAME -- passes at once; records the runner's WORK dir
  cat > "$SBX/test/$1.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
n="$(basename "$0" .test.sh)"
{ lsof -a -p $$ -d 1 -Fn 2>/dev/null | sed -n 's/^n//p'; } > "$MARK/work-probe"
echo "$n: 1 passed, 0 failed."
FIXEOF
}
write_red_then_park() { # NAME -- red on its first run, parks on the solo re-run
  cat > "$SBX/test/$1.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
n="$(basename "$0" .test.sh)"
if [ ! -f "$MARK/$n.ran-once" ]; then
  { lsof -a -p $$ -d 1 -Fn 2>/dev/null | sed -n 's/^n//p'; } > "$MARK/work-probe"
  : > "$MARK/$n.ran-once"
  echo "$n: 0 passed, 1 failed."
  exit 1
fi
exec -a "$PARK_NAME" sleep "$PARK_SECS"
FIXEOF
}

# start_runner JOBS -- launch the sandboxed REAL run-all.sh in the background with INT and
# TERM at their DEFAULT disposition. A non-interactive shell starts background jobs with
# SIGINT ignored, and a signal ignored on entry cannot be trapped, so without perl's reset
# the INT case could not exercise the handler at all. Both exec calls keep the pid, so
# $RUNNER_PID is the runner itself.
start_runner() {
  local jobs="$1"
  (
    cd "$SBX" || exit 2
    export MARK HOME="$HM" HEIMDALL_HOME="$HM/.heimdall"
    exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV' \
      bash test/run-all.sh --min 1 --jobs "$jobs"
  ) >"$OUT" 2>&1 &
  RUNNER_PID=$!
}

# wait_parked N LIMIT_S -- until at least N parked fixtures exist.
wait_parked() {
  local n="$1" i=0 max=$(( $2 * 10 ))
  while [ "$(parked_count)" -lt "$n" ]; do
    [ "$i" -ge "$max" ] && return 1
    sleep 0.1; i=$((i+1))
  done
  return 0
}
# wait_gone LIMIT_S -- until no parked fixture is left.
wait_gone() {
  local i=0 max=$(( $1 * 10 ))
  while [ "$(parked_count)" -gt 0 ]; do
    [ "$i" -ge "$max" ] && return 1
    sleep 0.1; i=$((i+1))
  done
  return 0
}
# await_exit LIMIT_S -- wait for $RUNNER_PID (a child of this shell). Sets AWAIT_RC to its
# status. A runner still alive at the limit is SIGKILLed so a regression can never wedge
# this suite; returns 1 then.
await_exit() {
  local i=0 max=$(( $1 * 10 ))
  while kill -0 "$RUNNER_PID" 2>/dev/null; do
    if [ "$i" -ge "$max" ]; then
      kill -KILL "$RUNNER_PID" 2>/dev/null
      wait "$RUNNER_PID" 2>/dev/null
      AWAIT_RC=137
      RUNNER_PID=""
      return 1
    fi
    sleep 0.1; i=$((i+1))
  done
  wait "$RUNNER_PID" 2>/dev/null; AWAIT_RC=$?
  RUNNER_PID=""
  return 0
}

# interrupt_and_check SIGNAL WANT_RC -- send SIGNAL to the runner NOW, then assert everything
# an interrupted sweep must (and must not) leave behind. Caller has already waited for the
# fixtures to be in flight.
interrupt_and_check() {
  local sig="$1" want_rc="$2" t0 t1 took w
  w="$(work_of "$MARK/work-probe")"
  t0=$(date +%s)
  kill "-$sig" "$RUNNER_PID" 2>/dev/null
  if await_exit "$EXIT_LIMIT_S"; then
    t1=$(date +%s); took=$((t1 - t0))
    ok "$CASE: runner exited ${took}s after SIG$sig (bound ${EXIT_LIMIT_S}s, fixtures park ${PARK_SECS}s)"
  else
    bad "$CASE: runner still running ${EXIT_LIMIT_S}s after SIG$sig -- the trap resumed the sweep instead of ending it"
  fi
  [ "$AWAIT_RC" -eq "$want_rc" ] \
    && ok "$CASE: exit status $want_rc (128 + signal)" \
    || bad "$CASE: exit status $AWAIT_RC, want $want_rc"
  if grep -qE 'RUN (RED|GREEN)' "$OUT"; then
    bad "$CASE: an interrupted sweep printed a verdict: $(grep -E 'RUN (RED|GREEN)' "$OUT" | head -1)"
  else
    ok "$CASE: no RUN RED / RUN GREEN verdict from an interrupted sweep"
  fi
  if grep -q 'No such file or directory' "$OUT"; then
    bad "$CASE: runner carried on without its work dir ($(grep -c 'No such file or directory' "$OUT") 'No such file or directory' lines)"
  else
    ok "$CASE: no 'No such file or directory' -- it did not run on after deleting its work dir"
  fi
  [ ! -e "$HM/.heimdall/receipts/last-sweep.json" ] \
    && ok "$CASE: no sweep receipt written" \
    || bad "$CASE: an interrupted sweep wrote a sweep receipt: $(tr -d '\n ' < "$HM/.heimdall/receipts/last-sweep.json" | cut -c1-120)"
  if wait_gone 5; then
    ok "$CASE: no in-flight suite outlived the runner"
  else
    bad "$CASE: $(parked_count) in-flight suite(s) still running after the runner exited"
  fi
  if [ -n "$w" ]; then
    [ ! -d "$w" ] && ok "$CASE: work dir removed" || bad "$CASE: work dir left behind: $w"
  else
    echo "  SKIP $CASE: work dir not discoverable (no lsof) -- removal not asserted"
  fi
  [ ! -e "$HM/.heimdall/.gate-in-flight" ] \
    && ok "$CASE: gate marker released" \
    || bad "$CASE: gate marker still claimed"
  reap_parked
}

echo "run-all-signal harness  work=$ROOT"
echo "--------------------------------------------------------------------"

# ══════════════════════════════════════════════════════════════════════════════
# 1 -- parallel phase: two suites parked in flight, two more still queued
# ══════════════════════════════════════════════════════════════════════════════
for spec in "TERM:143:term-parallel" "INT:130:int-parallel"; do
  sig="${spec%%:*}"; rest="${spec#*:}"; rc="${rest%%:*}"; label="${rest#*:}"
  echo
  echo "1 -- SIG$sig while suites are in flight and more are queued"
  new_case "$label"
  write_parker p1; write_parker p2; write_quick q3; write_quick q4
  commit_case
  start_runner 2
  if wait_parked 2 30; then
    interrupt_and_check "$sig" "$rc"
  else
    bad "$CASE: fixtures never reached the parked state -- harness problem, nothing to assert"
    kill -KILL "$RUNNER_PID" 2>/dev/null; RUNNER_PID=""
    reap_parked
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# 2 -- re-run-reds phase: the runner is parked on ONE foreground solo suite
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "2 -- SIGTERM while the serial re-run-reds phase is parked on one suite"
new_case term-retry
write_red_then_park b1; write_quick b2
commit_case
start_runner 2
if wait_parked 1 30; then
  interrupt_and_check TERM 143
else
  bad "$CASE: the red suite never reached its solo re-run -- harness problem, nothing to assert"
  kill -KILL "$RUNNER_PID" 2>/dev/null; RUNNER_PID=""
  reap_parked
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3 -- CONTROL: nobody signals; the same machinery still ends the run normally
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "3 -- control: an uninterrupted run still passes and still cleans up"
new_case control
write_quick d1; write_quick d2
commit_case
start_runner 2
if await_exit 60; then
  [ "$AWAIT_RC" -eq 0 ] && ok "control: exit 0" || bad "control: exit $AWAIT_RC, want 0"
else
  bad "control: run did not finish within 60s"
fi
grep -q 'RUN GREEN' "$OUT" && ok "control: prints RUN GREEN" || bad "control: no RUN GREEN verdict"
if command -v jq >/dev/null 2>&1; then
  [ "$(jq -r '.exit_code' "$HM/.heimdall/receipts/last-sweep.json" 2>/dev/null)" = "0" ] \
    && ok "control: green sweep receipt written" \
    || bad "control: no green sweep receipt at $HM/.heimdall/receipts/last-sweep.json"
fi
[ ! -e "$HM/.heimdall/.gate-in-flight" ] && ok "control: gate marker released" || bad "control: gate marker still claimed"
W="$(work_of "$MARK/work-probe")"
if [ -n "$W" ]; then
  [ ! -d "$W" ] && ok "control: work dir removed" || bad "control: work dir left behind: $W"
else
  echo "  SKIP control: work dir not discoverable (no lsof) -- removal not asserted"
fi

echo
echo "--------------------------------------------------------------------"
printf 'run-all-signal: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

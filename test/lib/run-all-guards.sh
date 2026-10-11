#!/usr/bin/env bash
# run-all-guards.sh -- sourced by test/run-all.sh. Two things the runner does about the machine it runs on.
# Defined here, not inline, so test/run-all-guards.test.sh can drive them without a fixture sweep, and so a
# copy of run-all.sh run without this file next to it (the throwaway fixture repos of the test/run-all-*.test.sh
# suites) simply runs without them, as it always did.
#
# hmd_test_wait_quiet   (run-all.sh --wait-quiet)  THE quiet gate: wait for the machine to settle before the sweep
#     starts, but never indefinitely.
#   Handoff 2026-10-11: the old gate waited for the 15-minute load average to fall below an ABSOLUTE 15 on three
#   checks. On a 10-core Mac with three long-lived claude sessions the load has not been below ~55 for five hours,
#   so the sweep was deferred forever -- a slow green run beats an indefinitely deferred one. Now:
#     * the threshold is relative to the machine: HMD_QUIET_FACTOR (default 1.5) x cpu count (HMD_QUIET_LOAD15_MAX
#       pins an absolute number instead);
#     * the wait is bounded: HMD_QUIET_MAX_WAIT_S (default 1200 = 20 min), polled every HMD_QUIET_POLL_S (30 s),
#       quiet = HMD_QUIET_CHECKS (3) CONSECUTIVE checks under the threshold;
#     * when the bound passes the sweep runs anyway with half the jobs (never below 1) and
#       HMD_TEST_REDUCED_PARALLELISM=1 exported, which a suite or wrapper that spawns its own workers (jest, a
#       relay test pool) reads to cut its worker count.
#   Needs from the caller: _load_avg (prints "L1 L5 L15"), NCPU, JOBS. Sets QUIET_GATE_OUTCOME
#   (quiet|timeout|unreadable) and QUIET_GATE_WAITED_S.
#
# hmd_test_orphan_guard   the end-of-sweep guard (always on). Needs: RUN, TO_RUN, WORK. Sets ORPHAN_SURVIVORS.
#   (1) names the suites whose process group still held a live process when the suite ended (timeout_run killed
#       it with the group; the names are in $WORK/<idx>.leaked);
#   (2) asserts no hmd ui / relay client on a temp or deleted repo outlives the sweep -- bin/lib/hmd_ui_procs.py
#       reap with no age floor. Silent when everything is clean, so a clean sweep prints exactly what it did before.

hmd_test_wait_quiet() {
  local max_wait="${HMD_QUIET_MAX_WAIT_S:-1200}" poll="${HMD_QUIET_POLL_S:-30}" need="${HMD_QUIET_CHECKS:-3}"
  local factor="${HMD_QUIET_FACTOR:-1.5}" threshold start waited=0 streak=0 raw l15 prev_jobs
  QUIET_GATE_OUTCOME="" QUIET_GATE_WAITED_S=0
  case "$max_wait" in ''|*[!0-9]*) max_wait=1200 ;; esac
  case "$need" in ''|*[!0-9]*|0) need=3 ;; esac
  if [ -n "${HMD_QUIET_LOAD15_MAX:-}" ]; then
    threshold="$HMD_QUIET_LOAD15_MAX"
  elif [ -n "${NCPU:-}" ]; then
    threshold="$(awk -v n="$NCPU" -v f="$factor" 'BEGIN { printf "%.1f", n * f }')"
  else
    QUIET_GATE_OUTCOME=unreadable
    echo "quiet gate: cpu count unknown and no HMD_QUIET_LOAD15_MAX -- not waiting"
    return 0
  fi
  start="$(date +%s)"
  while :; do
    raw="$(_load_avg)"
    l15="$(printf '%s' "$raw" | awk '{print $3}')"
    if [ -z "$l15" ]; then
      QUIET_GATE_OUTCOME=unreadable
      echo "quiet gate: load average unreadable on this platform -- not waiting"
      return 0
    fi
    if awk -v l="$l15" -v t="$threshold" 'BEGIN { exit !(l < t) }'; then streak=$((streak + 1)); else streak=0; fi
    waited=$(( $(date +%s) - start ))
    if [ "$streak" -ge "$need" ]; then
      QUIET_GATE_OUTCOME=quiet QUIET_GATE_WAITED_S="$waited"
      echo "quiet gate: machine quiet -- 15-min load $l15 < $threshold on $need consecutive checks (waited ${waited}s)"
      return 0
    fi
    if [ "$waited" -ge "$max_wait" ]; then
      prev_jobs="$JOBS"
      JOBS=$(( JOBS / 2 )); [ "$JOBS" -lt 1 ] && JOBS=1
      export HMD_TEST_REDUCED_PARALLELISM=1
      QUIET_GATE_OUTCOME=timeout QUIET_GATE_WAITED_S="$waited"
      echo "quiet gate: gave up after ${waited}s (15-min load $l15 >= $threshold) -- running anyway with jobs=$JOBS (was $prev_jobs) and HMD_TEST_REDUCED_PARALLELISM=1"
      return 0
    fi
    sleep "$poll"
  done
}

hmd_test_orphan_guard() {
  local repo="$1" work="$2" i leaky="" helper py out rc=0
  ORPHAN_SURVIVORS=0
  for i in $(seq 0 $((TO_RUN - 1))); do
    [ -s "$work/$i.leaked" ] && leaky="$leaky $(basename "${RUN[$i]}")"
  done
  if [ -n "$leaky" ]; then
    echo "${YEL:-}orphan guard:${OFF:-} these suites left processes running after they ended (killed with their process group):$leaky"
  fi
  helper="$repo/bin/lib/hmd_ui_procs.py"
  py="$(command -v python3 2>/dev/null)"
  [ -r "$helper" ] && [ -n "$py" ] || return 0
  out="$("$py" -I "$helper" reap --min-age 0 --timeout 3 2>&1)" || rc=$?
  if printf '%s\n' "$out" | grep -qE '^(reaped|SURVIVED) '; then
    echo "${YEL:-}orphan guard:${OFF:-} hmd servers on a temp or deleted repo outlived the sweep:"
    printf '%s\n' "$out" | grep -E '^(reaped|SURVIVED) ' | sed 's/^/  /'
  fi
  ORPHAN_SURVIVORS="$(printf '%s\n' "$out" | grep -c '^SURVIVED ')"
  return 0
}

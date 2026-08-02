#!/usr/bin/env bash
#
# run-all.sh — the single test runner for this repo.
#
# WHY THIS EXISTS: every suite used to be invoked by hand as `bash test/<name>.test.sh`.
# A suite therefore only went red where somebody happened to run it. Two red suites were
# discovered BY ACCIDENT during unrelated work; nobody could say how many of the ~250
# suites were actually green. This runner makes the whole board observable in one command.
#
# Guarantees:
#   1. DISCOVERY IS A GLOB, never a list. A suite cannot silently drop out of coverage by
#      being forgotten in an array. Adding test/foo.test.sh is enough to get it run.
#   2. ANTI-VACUOUS FLOOR. If discovery finds fewer than --min suites the run FAILS loudly.
#      "0 failures over 0 suites" is the worst possible output; it is now impossible.
#   3. EVERY SUITE IS TIME-BOUND. timeout(1) does not exist on macOS, so each suite runs
#      under a perl alarm in its OWN process group; on expiry the whole group is TERM'd then
#      KILL'd and the suite is reported TIMEOUT. A hung suite cannot stall the run.
#   4. LIVE/CREDENTIALED SUITES ARE CLASSIFIED, NOT HIDDEN. Suites that deploy, publish, or
#      talk to the deployed control plane are SKIPPED by default and printed WITH THEIR
#      REASON in the summary. --include-live runs them. A skipped suite is never silently
#      omitted from the table.
#   5. EXIT CODE IS THE SOURCE OF TRUTH; parsed "N passed, M failed" counts are detail. If
#      the counts cannot be parsed the suite is reported UNPARSED, never assumed to pass.
#   6. SILENT-RED DETECTION. A suite that prints failures but still exits 0 is a red hiding
#      in plain sight — exactly the class of bug this runner was built for. Those are
#      reported as DISCREPANCY and they fail the run.
#   7. NO FALSE REDS FROM PARALLELISM. Suites run in parallel for speed, but every suite
#      that goes red is automatically RE-RUN ALONE before being reported. A suite is only
#      called red if it is red on its own. One that passes alone is reported PARALLEL-FLAKY.
#
# Usage:
#   test/run-all.sh                     # all non-live suites, parallel, with red re-runs
#   test/run-all.sh --include-live      # also run deploy/publish/prod-facing suites
#   test/run-all.sh --filter statusline # only suites whose path matches the regex
#   test/run-all.sh --jobs 1            # fully serial
#   test/run-all.sh --timeout 300       # per-suite seconds (default 120)
#   test/run-all.sh --no-retry          # do not re-run reds serially
#
# Exit 0 = every suite that ran passed. Nonzero = at least one FAIL / TIMEOUT / DISCREPANCY,
# or discovery fell below the floor.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

# ── defaults ──
TIMEOUT=120
MIN_SUITES=100
FILTER=""
INCLUDE_LIVE=0
RETRY_REDS=1
JOBS="$( { sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; } | head -1 )"
case "$JOBS" in ''|*[!0-9]*) JOBS=4 ;; esac
[ "$JOBS" -gt 6 ] && JOBS=6
[ "$JOBS" -lt 1 ] && JOBS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --include-live) INCLUDE_LIVE=1; shift ;;
    --no-retry)     RETRY_REDS=0; shift ;;
    --jobs)         JOBS="${2:-4}"; shift 2 ;;
    --timeout)      TIMEOUT="${2:-120}"; shift 2 ;;
    --min)          MIN_SUITES="${2:-100}"; shift 2 ;;
    --filter)       FILTER="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run-all: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done
for n in "$JOBS" "$TIMEOUT" "$MIN_SUITES"; do
  case "$n" in ''|*[!0-9]*) echo "run-all: --jobs/--timeout/--min must be integers" >&2; exit 2 ;; esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; BLD=$'\033[1m'; OFF=$'\033[0m'
if [ ! -t 1 ]; then RED=""; GRN=""; YEL=""; DIM=""; BLD=""; OFF=""; fi

# ── LIVE / CREDENTIALED CLASSIFICATION ────────────────────────────────────────────────────
# Skipped by default because they DEPLOY, PUBLISH, or read/mutate the deployed control plane
# — running them from a dev box either mutates prod or hangs on absent credentials.
# Deliberately narrow: anything NOT listed here RUNS. Drift therefore fails VISIBLY (a new
# live suite gets run and shows up as a red/TIMEOUT) instead of silently vanishing from
# coverage, which is what a run-allowlist would do.
live_reason() {
  case "$(basename "$1")" in
    *-deployed.test.sh|heimdall-deployed-*.test.sh)
      echo "reads/mutates the DEPLOYED control plane" ;;
    heimdall-deploy-*.test.sh|heimdall-provision-*.test.sh)
      echo "performs a real cloud deploy/provision (gcloud + docker/ssh)" ;;
    ship-npm.test.sh|ship-netlify.test.sh|ship-release.test.sh)
      echo "release/publish path (npm publish / netlify / github release)" ;;
    heimdall-live-verify.test.sh)
      echo "live prod verifier — needs gcloud ADC against real infrastructure" ;;
    docs-external-probe.test.sh)
      echo "curls the deployed public URL over the network" ;;
    cp-public-allowlist-serves.test.sh)
      echo "probes the deployed public surface over the network" ;;
    *) echo "" ;;
  esac
}

# ── TIMEOUT WRAPPER ───────────────────────────────────────────────────────────────────────
# macOS has no timeout(1). Fork the suite into its own process GROUP so that on expiry the
# suite AND every child it spawned die — a bare `kill $pid` would leave orphans behind and
# those orphans are how a 600s stall watchdog ends up killing the agent instead of the test.
# Returns 124 on timeout (GNU timeout's convention), else the suite's own exit status.
timeout_run() {
  local secs="$1"; shift
  perl -e '
    my $t = shift @ARGV;
    my $pid = fork();
    die "run-all: fork failed: $!\n" unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
    my $timed_out = 0;
    $SIG{ALRM} = sub {
      $timed_out = 1;
      kill("TERM", -$pid);
      select(undef, undef, undef, 2);
      kill("KILL", -$pid);
    };
    alarm $t;
    my $got = waitpid($pid, 0);
    my $st  = $?;
    $got = waitpid($pid, 0) if $got == -1 && !$timed_out;
    alarm 0;
    exit 124 if $timed_out;
    exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8));
  ' -- "$secs" "$@"
}

# ── OUTPUT PARSING ────────────────────────────────────────────────────────────────────────
# Suites print "<name>: N passed, M failed." Colour codes may be interleaved, and a suite may
# print several such lines (sections); the LAST one is the roll-up. Emits "P M", or "" when
# nothing parseable was printed — in which case the caller reports UNPARSED rather than
# inventing a pass.
parse_counts() {
  LC_ALL=C sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' "$1" 2>/dev/null \
    | grep -oE '[0-9]+ passed, [0-9]+ failed' \
    | tail -1 \
    | awk '{print $1, $3}'
}

# ── DISCOVERY (glob, never a list) ────────────────────────────────────────────────────────
GLOB_COUNT=0
ALL=()
for s in "$REPO"/test/*.test.sh; do
  [ -f "$s" ] || continue
  GLOB_COUNT=$((GLOB_COUNT + 1))
  if [ -n "$FILTER" ]; then printf '%s\n' "$s" | grep -qE "$FILTER" || continue; fi
  ALL+=("$s")
done
DISCOVERED=${#ALL[@]}

echo ""
echo "${BLD}heimdall test runner${OFF}  repo=$REPO"
echo "discovered ${BLD}${DISCOVERED}${OFF} suites   (glob test/*.test.sh -> ${GLOB_COUNT})   jobs=$JOBS timeout=${TIMEOUT}s"
[ -n "$FILTER" ] && echo "filter: /$FILTER/  (floor check applies to the unfiltered glob)"
echo "--------------------------------------------------------------------------------------"

# Anti-vacuous guard. Checked against the UNFILTERED glob so --filter cannot defeat it.
if [ "$GLOB_COUNT" -lt "$MIN_SUITES" ]; then
  echo "${RED}${BLD}FATAL${OFF} discovery found only $GLOB_COUNT suites, floor is $MIN_SUITES." >&2
  echo "       A runner reporting '0 failures' over ~0 suites is worse than no runner." >&2
  echo "       Either the glob is broken / cwd is wrong, or suites were deleted (then pass --min)." >&2
  exit 3
fi
if [ "$DISCOVERED" -eq 0 ]; then
  echo "${RED}${BLD}FATAL${OFF} filter /$FILTER/ matched 0 suites — nothing would run." >&2
  exit 3
fi

# ── PARTITION: live (skipped by default) vs runnable ───────────────────────────────────────
RUN=(); SKIP=(); SKIP_WHY=()
for s in "${ALL[@]}"; do
  why="$(live_reason "$s")"
  if [ -n "$why" ] && [ "$INCLUDE_LIVE" -eq 0 ]; then
    SKIP+=("$s"); SKIP_WHY+=("$why")
  else
    RUN+=("$s")
  fi
done
TO_RUN=${#RUN[@]}

if [ "$TO_RUN" -eq 0 ]; then
  echo "${RED}${BLD}FATAL${OFF} every discovered suite was classified live — nothing would run." >&2
  exit 3
fi

WORK="$(mktemp -d -t heimdall-run-all.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ── EXECUTE (bounded parallelism; bash 3.2 has no `wait -n`, so poll with kill -0) ─────────
run_one() {
  local idx="$1" suite="$2" t0 t1 rc
  t0=$(date +%s)
  timeout_run "$TIMEOUT" bash "$suite" >"$WORK/$idx.out" 2>&1
  rc=$?
  t1=$(date +%s)
  printf '%s\n' "$rc" >"$WORK/$idx.rc"
  printf '%s\n' "$((t1 - t0))" >"$WORK/$idx.dur"
}

START=$(date +%s)
PIDS=()
next=0
launched=0
while [ "$next" -lt "$TO_RUN" ] || [ ${#PIDS[@]} -gt 0 ]; do
  while [ ${#PIDS[@]} -lt "$JOBS" ] && [ "$next" -lt "$TO_RUN" ]; do
    run_one "$next" "${RUN[$next]}" &
    PIDS+=($!)
    next=$((next + 1))
    launched=$((launched + 1))
    if [ -t 1 ]; then printf '\r  running %d/%d ...' "$launched" "$TO_RUN"; fi
  done
  sleep 0.2
  alive=()
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    kill -0 "$p" 2>/dev/null && alive+=("$p")
  done
  PIDS=(${alive[@]+"${alive[@]}"})
done
[ -t 1 ] && printf '\r%*s\r' 44 ''

# ── RE-RUN EVERY RED ALONE ────────────────────────────────────────────────────────────────
# Parallel execution can produce a FALSE red when two suites contend for shared state. A red
# is therefore never reported until it has been reproduced with the suite running by itself.
FLAKY=()
if [ "$RETRY_REDS" -eq 1 ] && [ "$JOBS" -gt 1 ]; then
  retried=0
  for i in $(seq 0 $((TO_RUN - 1))); do
    rc="$(cat "$WORK/$i.rc" 2>/dev/null || echo 99)"
    [ "$rc" = "0" ] && continue
    retried=$((retried + 1))
    [ -t 1 ] && printf '\r  re-running red #%d alone ...' "$retried"
    cp "$WORK/$i.rc" "$WORK/$i.rc.parallel"
    run_one "$i" "${RUN[$i]}"
    newrc="$(cat "$WORK/$i.rc" 2>/dev/null || echo 99)"
    [ "$newrc" = "0" ] && FLAKY+=("${RUN[$i]}")
  done
  [ -t 1 ] && printf '\r%*s\r' 44 ''
fi
END=$(date +%s)
ELAPSED=$((END - START))

# ── CLASSIFY RESULTS ──────────────────────────────────────────────────────────────────────
n_pass=0; n_fail=0; n_timeout=0; n_unparsed=0; n_discrep=0
tot_p=0; tot_f=0
FAILED=(); TIMEDOUT=(); UNPARSED=(); DISCREP=()
ROWS=()

for i in $(seq 0 $((TO_RUN - 1))); do
  suite="${RUN[$i]}"; name="$(basename "$suite")"
  rc="$(cat "$WORK/$i.rc" 2>/dev/null || echo 99)"
  dur="$(cat "$WORK/$i.dur" 2>/dev/null || echo 0)"
  counts="$(parse_counts "$WORK/$i.out")"
  if [ -n "$counts" ]; then
    p="${counts% *}"; f="${counts#* }"
    tot_p=$((tot_p + p)); tot_f=$((tot_f + f))
  else
    p="?"; f="?"
  fi

  if [ "$rc" = "124" ]; then
    status="TIMEOUT"; n_timeout=$((n_timeout + 1)); TIMEDOUT+=("$name")
  elif [ "$rc" != "0" ]; then
    status="FAIL"; n_fail=$((n_fail + 1)); FAILED+=("$name")
  elif [ "$p" = "?" ]; then
    status="UNPARSED"; n_unparsed=$((n_unparsed + 1)); UNPARSED+=("$name")
  elif [ "$f" != "0" ]; then
    # Exit 0 while printing failures: a red that hides. This is the exact bug class the
    # runner exists to surface, so it counts against the run.
    status="DISCREP"; n_discrep=$((n_discrep + 1)); DISCREP+=("$name ($f failed, exit 0)")
  else
    status="PASS"; n_pass=$((n_pass + 1))
  fi
  ROWS+=("$status|$name|$p|$f|$rc|${dur}s")
done

# ── TABLE ─────────────────────────────────────────────────────────────────────────────────
printf '%-9s %-52s %6s %6s %5s %7s\n' STATUS SUITE PASSED FAILED EXIT TIME
printf '%s\n' "--------------------------------------------------------------------------------------"
for row in ${ROWS[@]+"${ROWS[@]}"}; do
  st="${row%%|*}"; rest="${row#*|}"
  nm="${rest%%|*}"; rest="${rest#*|}"
  pp="${rest%%|*}"; rest="${rest#*|}"
  ff="${rest%%|*}"; rest="${rest#*|}"
  ee="${rest%%|*}"; tt="${rest#*|}"
  case "$st" in
    PASS)     c="$GRN" ;;
    FAIL)     c="$RED" ;;
    TIMEOUT)  c="$RED" ;;
    DISCREP)  c="$RED" ;;
    UNPARSED) c="$YEL" ;;
    *)        c="" ;;
  esac
  printf '%b%-9s%b %-52s %6s %6s %5s %7s\n' "$c" "$st" "$OFF" "$nm" "$pp" "$ff" "$ee" "$tt"
done
for j in $(seq 0 $((${#SKIP[@]} - 1))); do
  [ "${#SKIP[@]}" -eq 0 ] && break
  printf '%b%-9s%b %-52s %6s %6s %5s %7s\n' "$DIM" SKIPPED "$OFF" "$(basename "${SKIP[$j]}")" "-" "-" "-" "-"
done

# ── LOUD SECTIONS ─────────────────────────────────────────────────────────────────────────
echo ""
if [ "$n_fail" -gt 0 ]; then
  echo "${RED}${BLD}FAILED (${n_fail})${OFF} — reproduced running alone:"
  for x in ${FAILED[@]+"${FAILED[@]}"}; do echo "  bash test/$x"; done
  echo ""
fi
if [ "$n_timeout" -gt 0 ]; then
  echo "${RED}${BLD}TIMEOUT (${n_timeout})${OFF} — killed after ${TIMEOUT}s, process group reaped:"
  for x in ${TIMEDOUT[@]+"${TIMEDOUT[@]}"}; do echo "  bash test/$x"; done
  echo ""
fi
if [ "$n_discrep" -gt 0 ]; then
  echo "${RED}${BLD}DISCREPANCY (${n_discrep})${OFF} — printed failures but exited 0 (a SILENT red):"
  for x in ${DISCREP[@]+"${DISCREP[@]}"}; do echo "  $x"; done
  echo ""
fi
if [ "$n_unparsed" -gt 0 ]; then
  echo "${YEL}${BLD}UNPARSED (${n_unparsed})${OFF} — exit 0 but no 'N passed, M failed' line; counts UNKNOWN, not assumed pass:"
  for x in ${UNPARSED[@]+"${UNPARSED[@]}"}; do echo "  bash test/$x"; done
  echo ""
fi
if [ "${#FLAKY[@]}" -gt 0 ]; then
  echo "${YEL}${BLD}PARALLEL-FLAKY (${#FLAKY[@]})${OFF} — red under --jobs $JOBS, green alone (shared-state contention):"
  for x in ${FLAKY[@]+"${FLAKY[@]}"}; do echo "  bash test/$(basename "$x")"; done
  echo ""
fi
if [ "${#SKIP[@]}" -gt 0 ]; then
  echo "${BLD}SKIPPED — live/credentialed (${#SKIP[@]})${OFF}  re-run with --include-live:"
  for j in $(seq 0 $((${#SKIP[@]} - 1))); do
    printf '  %-46s %s\n' "$(basename "${SKIP[$j]}")" "${SKIP_WHY[$j]}"
  done
  echo ""
fi

# ── SUMMARY ───────────────────────────────────────────────────────────────────────────────
echo "--------------------------------------------------------------------------------------"
echo "suites: ${TO_RUN} ran, ${#SKIP[@]} skipped (live), ${DISCOVERED} discovered of ${GLOB_COUNT} globbed"
echo "        ${GRN}${n_pass} pass${OFF}  ${RED}${n_fail} fail${OFF}  ${RED}${n_timeout} timeout${OFF}  ${RED}${n_discrep} discrepancy${OFF}  ${YEL}${n_unparsed} unparsed${OFF}"
echo "assertions: ${tot_p} passed, ${tot_f} failed  (parsed detail; exit codes above are authoritative)"
echo "wall clock: ${ELAPSED}s"

BAD=$((n_fail + n_timeout + n_discrep))
if [ "$BAD" -gt 0 ]; then
  echo "${RED}${BLD}RUN RED${OFF} — $BAD suite(s) not green."
  exit 1
fi
echo "${GRN}${BLD}RUN GREEN${OFF} — all ${TO_RUN} suites that ran passed."
exit 0

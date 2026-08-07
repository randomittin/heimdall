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
#      The budget is PER SUITE, not one global number (see suite_timeout). A handful of
#      suites are legitimately slow for a MEASURED, understood reason; the rest are not.
#      One global bump big enough for the slowest would let a genuinely HUNG suite sit for
#      minutes before being reaped, so the slow ones get a named, justified override and
#      everything else keeps a tight default. The budget each suite ran under is PRINTED
#      next to every TIMEOUT, so an override can never quietly hide a slowdown.
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
#   8. THE REPORT IS COMPACT BY DEFAULT AND LOSSLESS ABOUT FAILURE. This output is read by
#      a MODEL far more often than by a human: every agent runs the board, several times a
#      session, and the whole table lands in a context window each time. ~290 lines saying
#      "it worked" carry no information, so a PASSING suite collapses into ONE counted line.
#      A suite that is NOT green keeps its row, its loud section and its reproduce command,
#      and now additionally gets its ENTIRE captured output printed — never a head, never a
#      tail, never an elision. Failures got LOUDER, not quieter, because they are now the
#      only per-suite detail on stdout. Rows are selected by STATUS — compact skips only the
#      literal string PASS — never by pattern, so a status class that did not exist when
#      this was written cannot be filtered out by accident; the default is to print it.
#      --verbose restores the whole table, and EVERY run writes the full table plus every
#      suite's own output to a plain-text log whose path is printed in the summary, so the
#      collapsed detail is one grep away rather than gone. See test/run-all-output.test.sh,
#      which plants one of every not-green class into a throwaway fixture repo and proves
#      the compact form still carries it in full, with a non-zero exit.
#
# Usage:
#   test/run-all.sh                     # all non-live suites, parallel, with red re-runs
#   test/run-all.sh --verbose           # print the full per-suite table (default: compact)
#   test/run-all.sh --include-live      # also run deploy/publish/prod-facing suites
#   test/run-all.sh --filter statusline # only suites whose path matches the regex
#   test/run-all.sh --jobs 1            # fully serial
#   test/run-all.sh --timeout 300       # DEFAULT per-suite seconds (default 180); suites
#                                       # with a measured override keep theirs if it is larger
#   test/run-all.sh --no-retry          # do not re-run reds serially
#
# Every run writes .heimdall/test-runs/run-<utc>-<pid>.log — the full table plus the entire
# captured output of every suite, passing ones included. The path is printed with the
# summary; the newest few are kept and older ones pruned.
#
# Exit 0 = every suite that ran passed. Nonzero = at least one FAIL / TIMEOUT / DISCREPANCY,
# or discovery fell below the floor. Verbosity NEVER changes the exit code.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

# ── defaults ──
TIMEOUT=180
MIN_SUITES=100
FILTER=""
INCLUDE_LIVE=0
RETRY_REDS=1
VERBOSE=0
LOG_KEEP=5
JOBS="$( { sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; } | head -1 )"
case "$JOBS" in ''|*[!0-9]*) JOBS=4 ;; esac
[ "$JOBS" -gt 6 ] && JOBS=6
[ "$JOBS" -lt 1 ] && JOBS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --include-live) INCLUDE_LIVE=1; shift ;;
    --no-retry)     RETRY_REDS=0; shift ;;
    --verbose|-v)   VERBOSE=1; shift ;;
    --jobs)         JOBS="${2:-4}"; shift 2 ;;
    --timeout)      TIMEOUT="${2:-180}"; shift 2 ;;
    --min)          MIN_SUITES="${2:-100}"; shift 2 ;;
    --filter)       FILTER="${2:-}"; shift 2 ;;
    # Print the whole banner, however long it grows — a fixed line range silently
    # truncated --help the moment a guarantee was added above the usage block.
    -h|--help)      awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) echo "run-all: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done
for n in "$JOBS" "$TIMEOUT" "$MIN_SUITES"; do
  case "$n" in ''|*[!0-9]*) echo "run-all: --jobs/--timeout/--min must be integers" >&2; exit 2 ;; esac
done

# Colour is a function, not a one-shot assignment, because the report is rendered TWICE —
# once onto stdout and once into the on-disk log, which must stay plain text so grep/awk
# read it cleanly. `colors off` before the log pass is what keeps escapes out of the file.
TTY=0; [ -t 1 ] && TTY=1
colors() {
  if [ "$1" = "on" ] && [ "$TTY" -eq 1 ]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; BLD=$'\033[1m'; OFF=$'\033[0m'
  else
    RED=""; GRN=""; YEL=""; DIM=""; BLD=""; OFF=""
  fi
}
colors on

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

# ── PER-SUITE TIME BUDGET ─────────────────────────────────────────────────────────────────
# Default is $TIMEOUT. A suite listed here is legitimately slow for a reason we MEASURED,
# and gets a named override; every measurement below is a SOLO wall-clock on an M-series
# mac, then multiplied for parallel contention. Observed contention factor: the
# heimdall-context-capsule suite runs 56s solo and was clocked at 102s under --jobs 6
# (~1.8x). Budgets are therefore >= 2x the solo time, then rounded up for headroom.
#
# Why overrides instead of one big global number: the global default is what protects the
# run from a GENUINELY HUNG suite (network wait, lock, prompt). Raising it to fit the
# slowest suite would let every hang burn that much wall clock before being reaped. Naming
# the slow suites keeps the hang detector tight for the other ~230.
#
# The effective budget is max(default, override) so `--timeout 600` still raises everything
# and an override never drops below its measured need.
suite_timeout() {
  local base="$(basename "$1")" override=0
  case "$base" in
    # gitleaks history pass (~40s alone) PLUS a full tree-mode pass; both are I/O-bound
    # scans over the whole repo and contend hard when run alongside 5 other suites.
    selfscan.test.sh)                override=600 ;;
    # issue-loop-integration.test.sh deliberately has NO override any more. It carried 420s
    # only because its §6 ran the WHOLE install-stranger suite inline; measured 2026-08-04,
    # that ONE nested call was 412s of its 442s wall clock and is what pushed it past 420s
    # into a TIMEOUT — while the suite itself passes 26/26. The nested run is now gated
    # behind HEIMDALL_TEST_SLOW=1 (the gate test/telemetry-install.test.sh:429 already used
    # for the same nested suite), so its own work measures 28s SOLO and the tight default is
    # the correct budget. Do NOT re-add an override to "fix" a timeout here: with 28s of work
    # under a 180s default, a timeout means something genuinely hung.
    # measured 56s solo / 102s under --jobs 6 — the closest suite to the old 120s cliff.
    heimdall-context-capsule.test.sh) override=300 ;;
    # measured 428s SOLO (57 passed, 0 failed) on an M-series mac, 2026-08-04.
    # It drives FIVE real installs — the primary stranger HOME, the idempotency re-run,
    # a fresh first-run-ordering HOME, and the two graceful-degrade variants — then a
    # real uninstall + re-uninstall and ~29 launchd/settings sandbox probes.
    # WHERE THE TIME GOES, because "install" sounds cheap and is not: ONE install.sh run
    # is ~77s — git clone 4s, marketplace register 7s, plugin install 8s, Ed25519 crypto
    # backend 4s, claude-mem setup 21s, and the post-install validation gate ~23s (it
    # boots Claude Code HEADLESS via --cc-verify and runs presence doctor). Five of those
    # is ~385s of the 428s; every sandbox probe added since the last budget is only ~44s.
    # So this is IO/network/subprocess-bound real work, not a hang: it exits 0.
    #
    # The previous note here read "measured 93s SOLO (28 passed, 0 failed)" and set 300s.
    # That figure does not reproduce — the suite now reports 57 assertions and a SINGLE
    # install costs more than a quarter of the old budget. 300s was therefore not a suite
    # going slow, it was a stale budget converting a PASSING suite into a TIMEOUT, which
    # is an absence of verdict and strictly worse than a red.
    # 900s ~= 2.1x the measured solo, keeping the documented ~1.8x parallel-contention
    # factor inside the budget, and sits in the same tier as selfscan (203->600 = 2.96x).
    install-stranger.test.sh)        override=900 ;;
  esac
  [ "$override" -gt "$TIMEOUT" ] && { echo "$override"; return 0; }
  echo "$TIMEOUT"
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

# ── THE FULL LOG ON DISK ──────────────────────────────────────────────────────────────────
# stdout is compact, so the detail it omits has to land somewhere a reader can still get at
# it — otherwise "compact" would just mean "lost". Every run writes the complete table plus
# the entire captured output of every suite here, in plain text, and prints the path.
# Inside the repo (.heimdall/* is already gitignored) so it sits next to the tree it
# describes; falls back to TMPDIR if that is not writable, because a runner must never fail
# to RUN because it could not open a LOG.
LOG_DIR="$REPO/.heimdall/test-runs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/run-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
if ! : >"$LOG" 2>/dev/null; then
  LOG_DIR="${TMPDIR:-/tmp}/heimdall-test-runs"
  mkdir -p "$LOG_DIR" 2>/dev/null
  LOG="$LOG_DIR/run-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
  : >"$LOG" 2>/dev/null
fi
# Keep the newest few and drop the rest: these carry every suite's stdout, so an unpruned
# directory would grow without bound on a machine that runs the board several times a day.
prune_logs() {
  local n=0 f
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -gt "$LOG_KEEP" ] && rm -f "$f"
  done < <(ls -t "$LOG_DIR"/run-*.log 2>/dev/null)
}
prune_logs

# Printed immediately on stdout (a human watching an 800s run should not stare at a blank
# screen) and mirrored into the log with colours off, so the log is a complete transcript.
print_header() {
  echo ""
  echo "${BLD}heimdall test runner${OFF}  repo=$REPO"
  echo "discovered ${BLD}${DISCOVERED}${OFF} suites   (glob test/*.test.sh -> ${GLOB_COUNT})   jobs=$JOBS timeout=${TIMEOUT}s (default; slow suites carry a measured override)"
  [ -n "$FILTER" ] && echo "filter: /$FILTER/  (floor check applies to the unfiltered glob)"
  echo "--------------------------------------------------------------------------------------"
}
print_header
colors off; print_header >>"$LOG" 2>/dev/null; colors on

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
  local idx="$1" suite="$2" t0 t1 rc budget
  budget="$(suite_timeout "$suite")"
  t0=$(date +%s)
  timeout_run "$budget" bash "$suite" >"$WORK/$idx.out" 2>&1
  rc=$?
  t1=$(date +%s)
  printf '%s\n' "$rc" >"$WORK/$idx.rc"
  printf '%s\n' "$((t1 - t0))" >"$WORK/$idx.dur"
  printf '%s\n' "$budget" >"$WORK/$idx.budget"
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
# Assertions contributed by the suites whose rows the compact report collapses. Reported on
# the collapsed line so the passing suites stay ACCOUNTED FOR — a count, not a disappearance.
pass_assert=0
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
    status="TIMEOUT"; n_timeout=$((n_timeout + 1))
    TIMEDOUT+=("$name|$(cat "$WORK/$i.budget" 2>/dev/null || echo "$TIMEOUT")")
  elif [ "$rc" != "0" ]; then
    status="FAIL"; n_fail=$((n_fail + 1)); FAILED+=("$name")
  elif [ "$p" = "?" ]; then
    status="UNPARSED"; n_unparsed=$((n_unparsed + 1)); UNPARSED+=("$name")
  elif [ "$f" != "0" ]; then
    # Exit 0 while printing failures: a red that hides. This is the exact bug class the
    # runner exists to surface, so it counts against the run.
    status="DISCREP"; n_discrep=$((n_discrep + 1)); DISCREP+=("$name ($f failed, exit 0)")
  else
    status="PASS"; n_pass=$((n_pass + 1)); pass_assert=$((pass_assert + p))
  fi
  ROWS+=("$status|$name|$p|$f|$rc|${dur}s")
done

BAD=$((n_fail + n_timeout + n_discrep))

# ── REPORT ────────────────────────────────────────────────────────────────────────────────
# render() is called TWICE over the SAME arrays: once as `full` into the on-disk log, once
# onto stdout (`full` under --verbose, otherwise `compact`). Rendering twice from the data —
# rather than text-filtering one rendering down into the other — is deliberate. A filter is
# a pattern that can stop matching, and the failure mode of a pattern that stops matching
# here is a red that silently vanishes from a report every other agent trusts. Selecting
# rows by STATUS cannot fail that way.
#
# COMPACT WITHHOLDS EXACTLY TWO THINGS, both of them noise:
#   * the per-suite row of a suite whose status is the literal string PASS — replaced by one
#     line carrying the suite count AND their assertion count, so they stay accounted for;
#   * the duplicate SKIPPED rows, which the SKIPPED section below reprints in full WITH the
#     reason each was classified live.
# Everything else — FAIL, TIMEOUT, DISCREP, UNPARSED, and any status added later, because
# the test is `= PASS` and not a list of reds — keeps its row, keeps its loud section, and
# additionally gets its complete captured output printed. Failures are never truncated.

# A suite's captured output as text. ANSI is stripped for the log (which must stay
# grep-able) and whenever stdout is not a terminal, where escape bytes are pure noise in a
# pipe or a context window. The sed matches only ESC-prefixed CSI sequences — it is the same
# one parse_counts already trusts — so no byte of real content can be lost to it.
emit_capture() {
  local file="$1" strip="$2"
  if [ ! -s "$file" ]; then
    echo "  (the suite produced no output at all)"
    return 0
  fi
  if [ "$strip" -eq 1 ]; then
    LC_ALL=C sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' "$file" 2>/dev/null
  else
    cat "$file" 2>/dev/null
  fi
}

# $1 = full|compact, $2 = 1 to strip ANSI from suite captures
render() {
  local mode="$1" strip="$2"
  local i j x row st nm pp ff ee tt c budget shown=0

  # Count the rows this pass will actually print before printing anything, so a fully green
  # board can drop the column header too instead of heading an empty table.
  for i in $(seq 0 $((TO_RUN - 1))); do
    st="${ROWS[$i]%%|*}"
    if [ "$mode" = "compact" ] && [ "$st" = "PASS" ]; then continue; fi
    shown=$((shown + 1))
  done

  if [ "$mode" = "full" ] || [ "$shown" -gt 0 ]; then
    printf '%-9s %-52s %6s %6s %5s %7s\n' STATUS SUITE PASSED FAILED EXIT TIME
    printf '%s\n' "--------------------------------------------------------------------------------------"
  fi
  for i in $(seq 0 $((TO_RUN - 1))); do
    row="${ROWS[$i]}"
    st="${row%%|*}"; row="${row#*|}"
    nm="${row%%|*}"; row="${row#*|}"
    pp="${row%%|*}"; row="${row#*|}"
    ff="${row%%|*}"; row="${row#*|}"
    ee="${row%%|*}"; tt="${row#*|}"
    if [ "$mode" = "compact" ] && [ "$st" = "PASS" ]; then continue; fi
    case "$st" in
      PASS)                  c="$GRN" ;;
      FAIL|TIMEOUT|DISCREP)  c="$RED" ;;
      UNPARSED)              c="$YEL" ;;
      *)                     c="" ;;
    esac
    printf '%b%-9s%b %-52s %6s %6s %5s %7s\n' "$c" "$st" "$OFF" "$nm" "$pp" "$ff" "$ee" "$tt"
  done

  if [ "$mode" = "compact" ]; then
    if [ "$n_pass" -gt 0 ]; then
      printf '%b%-9s%b %s\n' "$GRN" PASS "$OFF" \
        "${n_pass} suites, ${pass_assert} assertions — per-suite rows withheld, every one of them in the log named below"
    fi
    if [ "${#SKIP[@]}" -gt 0 ]; then
      printf '%b%-9s%b %s\n' "$DIM" SKIPPED "$OFF" \
        "${#SKIP[@]} suites classified live — each named with its reason below"
    fi
  elif [ "${#SKIP[@]}" -gt 0 ]; then
    for j in $(seq 0 $((${#SKIP[@]} - 1))); do
      printf '%b%-9s%b %-52s %6s %6s %5s %7s\n' "$DIM" SKIPPED "$OFF" \
        "$(basename "${SKIP[$j]}")" "-" "-" "-" "-"
    done
  fi

  # ── LOUD SECTIONS ───────────────────────────────────────────────────────────────────────
  echo ""
  if [ "$n_fail" -gt 0 ]; then
    echo "${RED}${BLD}FAILED (${n_fail})${OFF} — reproduced running alone:"
    for x in ${FAILED[@]+"${FAILED[@]}"}; do echo "  bash test/$x"; done
    echo ""
  fi
  if [ "$n_timeout" -gt 0 ]; then
    echo "${RED}${BLD}TIMEOUT (${n_timeout})${OFF} — killed at the suite's budget, process group reaped:"
    for x in ${TIMEDOUT[@]+"${TIMEDOUT[@]}"}; do
      printf '  %-56s %s\n' "bash test/${x%%|*}" "(budget ${x#*|}s)"
    done
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

  # ── CAPTURED OUTPUT ─────────────────────────────────────────────────────────────────────
  # Compact prints this for every suite that is not green, in full. Before this existed the
  # runner named its reds and printed NOTHING about them, so reading a failure meant running
  # the suite again by hand; the story now arrives with the verdict.
  if [ "$mode" = "compact" ]; then
    if [ "$shown" -gt 0 ]; then
      echo "${RED}${BLD}FULL OUTPUT — every suite that is not green (${shown})${OFF}  complete, never truncated:"
      echo ""
    fi
  else
    echo "${BLD}FULL OUTPUT — all ${TO_RUN} suites that ran${OFF}:"
    echo ""
  fi
  for i in $(seq 0 $((TO_RUN - 1))); do
    row="${ROWS[$i]}"
    st="${row%%|*}"; row="${row#*|}"
    nm="${row%%|*}"; row="${row#*|}"
    pp="${row%%|*}"; row="${row#*|}"
    ff="${row%%|*}"; row="${row#*|}"
    ee="${row%%|*}"; tt="${row#*|}"
    if [ "$mode" = "compact" ] && [ "$st" = "PASS" ]; then continue; fi
    case "$st" in
      PASS)                  c="$GRN" ;;
      FAIL|TIMEOUT|DISCREP)  c="$RED" ;;
      UNPARSED)              c="$YEL" ;;
      *)                     c="" ;;
    esac
    budget=""
    [ "$st" = "TIMEOUT" ] && budget="  (budget $(cat "$WORK/$i.budget" 2>/dev/null || echo "$TIMEOUT")s)"
    echo "======================================================================================"
    printf '%b%s%b  %s   exit %s, %s passed, %s failed, %s%s\n' \
      "$c" "$st" "$OFF" "$nm" "$ee" "$pp" "$ff" "$tt" "$budget"
    echo "======================================================================================"
    emit_capture "$WORK/$i.out" "$strip"
    echo "── end $nm ──"
    echo ""
  done

  # ── SUMMARY ─────────────────────────────────────────────────────────────────────────────
  echo "--------------------------------------------------------------------------------------"
  echo "suites: ${TO_RUN} ran, ${#SKIP[@]} skipped (live), ${DISCOVERED} discovered of ${GLOB_COUNT} globbed"
  echo "        ${GRN}${n_pass} pass${OFF}  ${RED}${n_fail} fail${OFF}  ${RED}${n_timeout} timeout${OFF}  ${RED}${n_discrep} discrepancy${OFF}  ${YEL}${n_unparsed} unparsed${OFF}"
  echo "assertions: ${tot_p} passed, ${tot_f} failed  (parsed detail; exit codes above are authoritative)"
  echo "wall clock: ${ELAPSED}s"
  echo "log: ${LOG}  (full table + every suite's output, plain text — grep it)"
  if [ "$BAD" -gt 0 ]; then
    echo "${RED}${BLD}RUN RED${OFF} — $BAD suite(s) not green."
  else
    echo "${GRN}${BLD}RUN GREEN${OFF} — all ${TO_RUN} suites that ran passed."
  fi
}

# The log is written FIRST, so that the complete transcript exists on disk even if stdout is
# a pipe that goes away mid-write.
colors off
render full 1 >>"$LOG" 2>/dev/null
colors on

STDOUT_STRIP=1; [ "$TTY" -eq 1 ] && STDOUT_STRIP=0
if [ "$VERBOSE" -eq 1 ]; then
  render full "$STDOUT_STRIP"
else
  render compact "$STDOUT_STRIP"
fi

# Verbosity is a rendering choice and NEVER a verdict: the exit code is computed from the
# suite results alone, before either pass runs.
[ "$BAD" -gt 0 ] && exit 1
exit 0

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
#   8. THE TREE ITSELF IS A GUARANTEE. A frozen `git status` is taken before the first suite
#      starts and again after the very last one (including solo red re-runs) finishes. Any
#      tracked file a suite added, modified, deleted, or TYPE-CHANGED (e.g. swapped for a
#      symlink) fails the run LOUDLY, naming the file — never advisory, never silent. This
#      exists because it already happened for real, twice, undetected for hours each time:
#      a tracked file (bin/hmd) was replaced on disk by a dangling symlink into a deleted
#      test sandbox, surfacing only as an easy-to-miss ` T ` in `git status`; separately, a
#      test fixture leaked a directory into the REPO ROOT when a `set -e` short-circuit in
#      its own cleanup trap aborted before reaching later cleanup steps. The second shape is
#      transient — it only happens when a suite fails EARLY — so this check runs even when
#      every suite comes back green; gating it on "only check if otherwise green" would miss
#      exactly the failure mode it was added for. See "REPO INTEGRITY" near CLASSIFY RESULTS
#      below for what counts, what is deliberately excluded (`.planning/`, `~/.heimdall/`,
#      anything outside the repo — suites legitimately write there), and how a violation is
#      attributed to a specific suite without a git call per suite.
#
# Usage:
#   test/run-all.sh                     # all non-live suites, parallel, with red re-runs
#   test/run-all.sh --include-live      # also run deploy/publish/prod-facing suites
#   test/run-all.sh --filter statusline # only suites whose path matches the regex
#   test/run-all.sh --jobs 1            # fully serial
#   test/run-all.sh --timeout 300       # DEFAULT per-suite seconds (default 180); suites
#                                       # with a measured override keep theirs if it is larger
#   test/run-all.sh --no-retry          # do not re-run reds serially
#
# Exit 0 = every suite that ran passed. Nonzero = at least one FAIL / TIMEOUT / DISCREPANCY,
# or discovery fell below the floor.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

# ── defaults ──
TIMEOUT=180
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
    --timeout)      TIMEOUT="${2:-180}"; shift 2 ;;
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

echo ""
echo "${BLD}heimdall test runner${OFF}  repo=$REPO"
echo "discovered ${BLD}${DISCOVERED}${OFF} suites   (glob test/*.test.sh -> ${GLOB_COUNT})   jobs=$JOBS timeout=${TIMEOUT}s (default; slow suites carry a measured override)"
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

# ── PUBLISH THAT A GATE IS IN FLIGHT ─────────────────────────────────────────────────
# CLAUDE.md requires this sweep to grade a FROZEN tree — "a verdict over a moving tree is
# not a verdict" — but nothing in the repo announced that a sweep was running, so the
# things that can move the tree had no way to know. bin/heimdall-wip-commit, the
# edit-count checkpointer wired into the PreToolUse hook, duly committed three in-progress
# files during a real 337-suite run, moving HEAD and the index under the suites that read
# git state. This marker is the missing signal, and heimdall-wip-commit is its first
# reader (it withholds the commit and keeps counting).
#
# The pid is in the file so a reader can check LIVENESS: a sweep killed with SIGKILL never
# reaches the trap below, and a stale marker that silently disabled checkpointing forever
# would be worse than the race it prevents. It lives under HEIMDALL_HOME, never in the
# repo, because a marker inside the tree would itself be tree movement.
GATE_MARKER="${HEIMDALL_HOME:-$HOME/.heimdall}/.gate-in-flight"
# Do not steal a LIVE parent's claim: if a marker already names a running process, that
# sweep owns the freeze and this (nested) run must not overwrite it with its own pid —
# otherwise the parent's own release check would find a foreign pid and leave the marker
# behind forever. A marker naming a dead pid is stale and is taken over.
_gate_marker_claim() {
  local held
  mkdir -p "$(dirname "$GATE_MARKER")" 2>/dev/null || return 0
  if [ -f "$GATE_MARKER" ]; then
    held="$(cat "$GATE_MARKER" 2>/dev/null)"
    case "$held" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$held" 2>/dev/null && return 0 ;;
    esac
  fi
  # Line 1 the pid (liveness), line 2 the repo being graded (scope). Without the repo a
  # sweep here would freeze checkpointing in every unrelated repo on the machine — which
  # is exactly how the first version of this marker turned heimdall-wip-commit.test.sh RED
  # from inside the sweep, since that suite drives the checkpointer in its own temp repo.
  printf '%s\n%s\n' "$$" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" > "$GATE_MARKER" 2>/dev/null || true
}
_gate_marker_claim

# OWNERSHIP-CHECKED REMOVAL. Some suites invoke this runner again with --filter, and a
# nested run that blindly deleted the marker on exit would un-freeze the OUTER sweep while
# it was still grading — reintroducing exactly the race the marker exists to close, in the
# one situation hardest to notice. The marker is only removed by the process whose pid it
# names, so a nested run leaves its parent's claim standing.
_gate_marker_release() {
  [ -f "$GATE_MARKER" ] || return 0
  [ "$(sed -n '1p' "$GATE_MARKER" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$GATE_MARKER" 2>/dev/null || true
}
cleanup() { rm -rf "$WORK"; _gate_marker_release; }
trap cleanup EXIT INT TERM

# ── REPO INTEGRITY, BEFORE SIDE (guarantee #8 above) ────────────────────────────────────
# Snapshot the tree now, before suite #0 has even started. The AFTER side, and the full
# rationale for what counts / what's excluded / how a violation gets attributed to a suite
# without a git call per suite, live next to CLASSIFY RESULTS below, where the compare
# actually happens. --no-renames on both snapshots turns a moved tracked file into a plain
# delete+add pair instead of one "R  old -> new" line: easier to diff, and a rename IS a
# mutation of the tree, not a no-op.
_status_snapshot() { git -C "$REPO" status --porcelain=v1 --no-renames 2>/dev/null | sort; }
_status_snapshot > "$WORK/status-before.txt"
git -C "$REPO" stash list > "$WORK/stash-before.txt" 2>/dev/null

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
  # t0/t1 exist ONLY so a tree-integrity violation (see REPO INTEGRITY below) can be
  # narrowed to the suite(s) running when the offending mtime lands. Two tiny writes, no
  # new subprocess — read only if a violation is actually found.
  printf '%s\n' "$t0" >"$WORK/$idx.t0"
  printf '%s\n' "$t1" >"$WORK/$idx.t1"
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
    # Keep the PARALLEL-phase output too. The solo re-run overwrites $i.out, and the
    # difference between the two runs is the whole diagnosis for a contaminated suite.
    cp "$WORK/$i.out" "$WORK/$i.out.parallel" 2>/dev/null || true
    # Same reason for .t0/.t1: run_one() overwrites them on the solo re-run, and a tree
    # violation caused during the PARALLEL phase must still be attributable afterward.
    cp "$WORK/$i.t0" "$WORK/$i.t0.parallel" 2>/dev/null || true
    cp "$WORK/$i.t1" "$WORK/$i.t1.parallel" 2>/dev/null || true
    run_one "$i" "${RUN[$i]}"
    newrc="$(cat "$WORK/$i.rc" 2>/dev/null || echo 99)"
    [ "$newrc" = "0" ] && FLAKY+=("${RUN[$i]}")
  done
  [ -t 1 ] && printf '\r%*s\r' 44 ''
fi
END=$(date +%s)
ELAPSED=$((END - START))

# ── REPO INTEGRITY, AFTER SIDE (guarantee #8 in the header) ─────────────────────────────
# WHAT COUNTS: any git-status line for a file git ALREADY tracks — staged or unstaged
# add/modify/delete/typechange. --no-renames (both snapshots) keeps a moved tracked file as
# a delete+add pair rather than one "R  old -> new" line.
#
# WHAT IS DELIBERATELY EXCLUDED: untracked (`??`) and ignored (`!!`) lines — anything git
# has no opinion about yet. Suites legitimately write `.planning/` notes, `~/.heimdall/`
# state, and mktemp dirs outside the repo; none of that is corruption. The floor is "did a
# suite touch a file that was ALREADY git's business."
#
# THE ONE EXCEPTION: an untracked entry with no path separator — a bare name, or for a
# directory "name/" (git does not recurse into an untracked dir to list it) — sitting loose
# in the REPO ROOT. Nothing legitimate creates a new top-level sibling of .planning/, test/,
# etc. mid-run. This shape happened for real on 2026-08-23: a test fixture's own E2_HOME
# leaked into the repo root, untracked, when a `set -e` short-circuit in its cleanup trap's
# guarded-removal chain aborted before later cleanup steps ran. It only happens when that
# suite fails EARLY, so a fully green run never touches this path — exactly why this check
# is unconditional and never gated on "only check if otherwise green".
#
# git stash is checked too, separately: a suite that dirties a tracked file and stashes it
# away before exiting restores a byte-identical tree — invisible to the diff below — but the
# stash entry survives as residue, and creating one at all proves a tracked file WAS
# touched. A stash push+pop round trip within one suite nets zero and is genuinely
# undetectable by any before/after check; that's out of scope, same as this runner declines
# to sandbox suites more aggressively — this is a detector, not a jail.
#
# ATTRIBUTION is deliberately NOT a git-status bracket around every suite. Two reasons:
#   SOUNDNESS — suites run $JOBS wide. If suite A dirties a file at t=2s while suite B is
#   also mid-run, a bracket around B would show the same dirty file and could not tell the
#   two apart; it would accuse the innocent as readily as the guilty.
#   COST/CONTENTION — a `git status --porcelain` from inside every suite's parallel slot
#   fires while up to $JOBS-1 OTHER suites run arbitrary commands — including their own git
#   calls — against this same working tree: real .git/index.lock contention a run-level
#   snapshot (only called while nothing else is running) does not have.
# Instead, ONLY when a violation is actually found (never on a clean run, so this cost is
# never paid when nothing is wrong) the offending path's mtime is cross-referenced against
# the [t0,t1] wall-clock window already recorded per suite for the timing table — no new
# git calls, just a stat and integer comparisons — to print a narrowed CANDIDATE list.
# Honestly labelled as candidates, not a verdict: windows can overlap under parallelism.
_status_snapshot > "$WORK/status-after.txt"
git -C "$REPO" stash list > "$WORK/stash-after.txt" 2>/dev/null

grep -Ev '^(\?\?|!!)' "$WORK/status-before.txt" > "$WORK/tracked-before.txt"
grep -Ev '^(\?\?|!!)' "$WORK/status-after.txt"  > "$WORK/tracked-after.txt"
diff "$WORK/tracked-before.txt" "$WORK/tracked-after.txt" 2>/dev/null | grep -E '^[<>] ' \
  > "$WORK/tree-violations.txt"

grep '^??' "$WORK/status-before.txt" | cut -c4- | grep -E '^[^/]+/?$' | sort \
  > "$WORK/root-untracked-before.txt"
grep '^??' "$WORK/status-after.txt"  | cut -c4- | grep -E '^[^/]+/?$' | sort \
  > "$WORK/root-untracked-after.txt"
comm -13 "$WORK/root-untracked-before.txt" "$WORK/root-untracked-after.txt" \
  > "$WORK/root-litter.txt" 2>/dev/null

STASH_BEFORE_N=0; [ -s "$WORK/stash-before.txt" ] && STASH_BEFORE_N=$(wc -l < "$WORK/stash-before.txt" | tr -d '[:space:]')
STASH_AFTER_N=0;  [ -s "$WORK/stash-after.txt"  ] && STASH_AFTER_N=$(wc -l < "$WORK/stash-after.txt"  | tr -d '[:space:]')
NEW_STASH_N=$((STASH_AFTER_N - STASH_BEFORE_N))
[ "$NEW_STASH_N" -lt 0 ] && NEW_STASH_N=0

TREEVIOL_PATH_COUNT=0
: > "$WORK/tree-violation-paths.txt"
if [ -s "$WORK/tree-violations.txt" ]; then
  cut -c6- "$WORK/tree-violations.txt" | sort -u > "$WORK/tree-violation-paths.txt"
  TREEVIOL_PATH_COUNT=$(wc -l < "$WORK/tree-violation-paths.txt" | tr -d '[:space:]')
fi
ROOT_LITTER_COUNT=0
[ -s "$WORK/root-litter.txt" ] && ROOT_LITTER_COUNT=$(wc -l < "$WORK/root-litter.txt" | tr -d '[:space:]')

n_treeviol=$((TREEVIOL_PATH_COUNT + ROOT_LITTER_COUNT + NEW_STASH_N))

# _mtime_of PATH — epoch mtime of a repo-relative path. Plain `stat` (no -L) reports on a
# symlink itself rather than erroring on a dangling target — exactly the shape that hid for
# hours once already: a tracked file replaced on disk by a dangling symlink.
_mtime_of() {
  local target="$REPO/$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    stat -f %m "$target" 2>/dev/null || true
  fi
}
# _attribute MTIME — best-effort candidate suite list; see the long rationale above.
_attribute() {
  local target="$1" i s0 s1 hit="" sfx
  for i in $(seq 0 $((TO_RUN - 1))); do
    for sfx in "" ".parallel"; do
      [ -f "$WORK/$i.t0$sfx" ] || continue
      s0="$(cat "$WORK/$i.t0$sfx" 2>/dev/null || echo 0)"
      s1="$(cat "$WORK/$i.t1$sfx" 2>/dev/null || echo 0)"
      if [ "$target" -ge $((s0 - 1)) ] && [ "$target" -le $((s1 + 1)) ]; then
        hit="$hit $(basename "${RUN[$i]}")"
        break
      fi
    done
  done
  printf '%s' "$hit" | tr -s ' ' '\n' | sort -u | tr '\n' ' '
}
# _report_path PATH MISSING_MSG — append one report line: mtime + candidate suites, or a
# clear reason no mtime could be read.
_report_path() {
  local p="$1" missing_msg="$2" mtime cands
  mtime="$(_mtime_of "$p")"
  if [ -z "$mtime" ]; then
    printf '    %-40s (%s)\n' "$p" "$missing_msg" >> "$WORK/tree-report.txt"
    return
  fi
  cands="$(_attribute "$mtime")"
  if [ -n "$(printf '%s' "$cands" | tr -d '[:space:]')" ]; then
    printf '    %-40s (mtime %s -- running then: %s)\n' "$p" "$mtime" "$cands" >> "$WORK/tree-report.txt"
  else
    printf '    %-40s (mtime %s -- no recorded suite window covers it)\n' "$p" "$mtime" >> "$WORK/tree-report.txt"
  fi
}

: > "$WORK/tree-report.txt"
if [ "$TREEVIOL_PATH_COUNT" -gt 0 ]; then
  echo "  tracked file(s) changed during the run:" >> "$WORK/tree-report.txt"
  while IFS= read -r p; do
    [ -n "$p" ] && _report_path "$p" "gone -- deleted; no mtime left to narrow candidates"
  done < "$WORK/tree-violation-paths.txt"
fi
if [ "$ROOT_LITTER_COUNT" -gt 0 ]; then
  echo "  untracked entry(ies) appeared loose in the repo ROOT (not nested, not .planning/):" >> "$WORK/tree-report.txt"
  while IFS= read -r p; do
    [ -n "$p" ] && _report_path "$p" "already gone by the time this check ran"
  done < "$WORK/root-litter.txt"
fi
if [ "$NEW_STASH_N" -gt 0 ]; then
  printf '  %d new git-stash entry(ies) left behind (a tracked file WAS mutated mid-run):\n' "$NEW_STASH_N" >> "$WORK/tree-report.txt"
  head -n "$NEW_STASH_N" "$WORK/stash-after.txt" | sed 's/^/    /' >> "$WORK/tree-report.txt"
fi

# ── CLASSIFY RESULTS ──────────────────────────────────────────────────────────────────────
n_pass=0; n_fail=0; n_timeout=0; n_unparsed=0; n_discrep=0
tot_p=0; tot_f=0
FAILED=(); TIMEDOUT=(); UNPARSED=(); DISCREP=()
NONGREEN=()   # "idx|name|status" for every suite that did not come back green
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
    status="PASS"; n_pass=$((n_pass + 1))
  fi
  ROWS+=("$status|$name|$p|$f|$rc|${dur}s")
  [ "$status" = "PASS" ] || NONGREEN+=("$i|$name|$status")
done

# ── PRESERVE THE EVIDENCE FOR EVERY NON-GREEN SUITE ───────────────────────────────────────
# $WORK is deleted on exit, so without this every red's output self-destructs and the only
# way to see WHY a suite failed inside the run is to reproduce the whole 40-minute run. A
# red that cannot be read is a red that cannot be fixed. Copy out before cleanup fires.
# Solo-green-but-red-in-run (state contamination) is exactly the case this exists for: the
# .parallel.out / .out pair is the diagnosis.
EVIDENCE=""
if [ "${#NONGREEN[@]}" -gt 0 ] || [ "$n_treeviol" -gt 0 ]; then
  # Explicit template, not `-t`: on macOS `-t` treats the argument as a PREFIX and appends
  # its own suffix, leaving a literal "XXXXXX" in the printed path.
  EVIDENCE="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-run-all-evidence.XXXXXX")"
  for e in ${NONGREEN[@]+"${NONGREEN[@]}"}; do
    ei="${e%%|*}"; erest="${e#*|}"; ename="${erest%%|*}"; estatus="${erest#*|}"
    cp "$WORK/$ei.out" "$EVIDENCE/${ename%.test.sh}.$estatus.out" 2>/dev/null || true
    [ -f "$WORK/$ei.out.parallel" ] && \
      cp "$WORK/$ei.out.parallel" "$EVIDENCE/${ename%.test.sh}.$estatus.parallel.out" 2>/dev/null || true
  done
  if [ "$n_treeviol" -gt 0 ]; then
    cp "$WORK/tree-report.txt" "$EVIDENCE/TREE-INTEGRITY-VIOLATION.txt" 2>/dev/null || true
    for tf in status-before.txt status-after.txt stash-before.txt stash-after.txt tree-violations.txt root-litter.txt; do
      [ -f "$WORK/$tf" ] && cp "$WORK/$tf" "$EVIDENCE/$tf" 2>/dev/null || true
    done
  fi
  {
    printf 'run-all evidence  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'jobs=%s  suites_ran=%s  retry_reds=%s\n\n' "$JOBS" "$TO_RUN" "$RETRY_REDS"
    printf '%-9s %s\n' STATUS SUITE
    for e in ${NONGREEN[@]+"${NONGREEN[@]}"}; do
      erest="${e#*|}"
      printf '%-9s %s\n' "${erest#*|}" "${erest%%|*}"
    done
    [ "$n_treeviol" -gt 0 ] && printf '%-9s %s\n' TREEVIOL "see TREE-INTEGRITY-VIOLATION.txt ($n_treeviol finding(s))"
    printf '\n*.out          = the run that produced the verdict (solo re-run when --retry-reds)\n'
    printf '*.parallel.out = the same suite'"'"'s output during the parallel phase, when present\n'
  } > "$EVIDENCE/INDEX.txt"
fi

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
if [ "$n_treeviol" -gt 0 ]; then
  echo "${RED}${BLD}TREE INTEGRITY VIOLATION (${n_treeviol})${OFF} — the working tree was NOT the same after the run as before it:"
  cat "$WORK/tree-report.txt"
  echo "  this is a REAL CORRUPTION SIGNAL, not advisory — a suite wrote where only a human or git should."
  echo ""
fi

# ── SUMMARY ───────────────────────────────────────────────────────────────────────────────
echo "--------------------------------------------------------------------------------------"
echo "suites: ${TO_RUN} ran, ${#SKIP[@]} skipped (live), ${DISCOVERED} discovered of ${GLOB_COUNT} globbed"
echo "        ${GRN}${n_pass} pass${OFF}  ${RED}${n_fail} fail${OFF}  ${RED}${n_timeout} timeout${OFF}  ${RED}${n_discrep} discrepancy${OFF}  ${YEL}${n_unparsed} unparsed${OFF}"
echo "assertions: ${tot_p} passed, ${tot_f} failed  (parsed detail; exit codes above are authoritative)"
echo "wall clock: ${ELAPSED}s"
if [ "$n_treeviol" -eq 0 ]; then
  echo "tree-integrity: clean (before/after git status match; no tracked file touched, no root litter, no new stash)"
else
  echo "${RED}tree-integrity: VIOLATED (${n_treeviol} finding(s) -- see TREE INTEGRITY VIOLATION above)${OFF}"
fi
if [ -n "$EVIDENCE" ]; then
  echo "evidence:   ${EVIDENCE}   (${#NONGREEN[@]} non-green suite output(s) + INDEX.txt — kept, not deleted)"
fi

BAD=$((n_fail + n_timeout + n_discrep + n_treeviol))
if [ "$BAD" -gt 0 ]; then
  if [ "$n_treeviol" -gt 0 ]; then
    echo "${RED}${BLD}RUN RED${OFF} — $BAD suite(s)/finding(s) not green, including $n_treeviol TREE INTEGRITY VIOLATION(s)."
  else
    echo "${RED}${BLD}RUN RED${OFF} — $BAD suite(s) not green."
  fi
  [ -n "$EVIDENCE" ] && echo "  read it: ${EVIDENCE}/INDEX.txt"
  exit 1
fi
echo "${GRN}${BLD}RUN GREEN${OFF} — all ${TO_RUN} suites that ran passed, tree untouched."
exit 0

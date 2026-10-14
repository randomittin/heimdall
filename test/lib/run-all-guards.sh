#!/usr/bin/env bash
# run-all-guards.sh -- sourced by test/run-all.sh. Five things the runner does about the machine it runs on.
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
#
# hmd_test_tmp_begin / hmd_test_suite_tmp_settle / hmd_test_tmp_guard   EVERY SUITE GETS ITS OWN TMPDIR, REMOVED AFTER IT; LEAKS ARE
#     REPORTED (always on).
#   2026-10-13: free space on the dev machine dropped 1.6 GB while agents ran suites. A suite that makes a temp dir with mktemp and
#   never removes it (a missing `trap 'rm -rf' EXIT`, or an early abort before the cleanup line) leaves it in the machine's TMPDIR
#   for good, and nothing said so. Now:
#     * hmd_test_tmp_begin makes ONE run-level root (TMP_ROOT = $TMPDIR/hr.XXXX) and takes the before-snapshot of the directories the outside
#       check watches;
#     * run_one gives each suite a fresh $TMP_ROOT/s<N> (N = its index; the receipt's tmp_dirs says which suite had which) as ITS TMPDIR, so
#       everything it makes through mktemp / $TMPDIR / python tempfile lands there. Both names are as short as they can be on purpose: a unix
#       socket path has to fit macOS's 104 bytes, and every byte of the per-suite dir comes out of what a suite can use (hmd_test_sock_preflight);
#     * hmd_test_suite_tmp_settle, called AFTER timeout_run has returned -- timeout_run reaps the suite's whole process group first,
#       so nothing is still writing -- measures what is left (top-level entries + du bytes + a sample of names) into
#       $WORK/<idx>.tmpleak, then removes it (chmod first: a suite that leaves a read-only tree must not leak forever);
#     * hmd_test_tmp_guard, at the end of the sweep, turns those records into the receipt's tmp_leaks, a summary line, and the verdict:
#         - a suite that left MORE THAN HMD_TEST_TMP_LEAK_MAX_MB (default 50) MB behind, or ANY leftover when HMD_TEST_STRICT_TMP=1, is
#           a FAILURE (TMP_FINDINGS, which run-all.sh adds to BAD). The operator asked for this to be checked, and a number of
#           megabytes is exactly what is lost from the disk; a small leftover is rarely worth a red sweep, so below the limit it is a
#           loud WARNING (TMP LEFTOVERS) that still lands in the receipt;
#         - new top-level entries in /tmp and in the runner's real $TMPDIR (HMD_TEST_TMP_WATCH, colon-separated, replaces that list)
#           are what a suite wrote OUTSIDE its TMPDIR (a hard-coded /tmp/... path). They are attributed to the suites whose
#           [start, end] window covers their mtime and recorded as tmp_outside; entries no suite window covers are another process's
#           and are ignored. A WARNING by default and never deleted -- attribution is a mtime hint (suites overlap --jobs wide, and
#           the machine has other writers), so failing the sweep on it would make a busy box randomly red; HMD_TEST_STRICT_TMP=1
#           (for a quiet machine) makes them findings too.
#         - THE EXCEPTION IS SIZE (2026-10-14): an outside entry over the same HMD_TEST_TMP_LEAK_MAX_MB limit is a FINDING too (TMP LEAK OUTSIDE
#           TMPDIR). It is the same disk, and the shape that filled it was a 100 MB pip-unpack-* dir written outside any TMPDIR by a child started with
#           `env -i` (which drops TMPDIR): below the limit a warning is enough, above it a red sweep is the point. HMD_TEST_TMP_OUTSIDE_MAX (default
#           2000) bounds how many new entries are examined, and the ones beyond it are COUNTED and said loudly (NOT FULLY CHECKED) -- the old fixed 300,
#           taken in name order, skipped a pip-* dir behind 300 hmd-agents.* ones without a word.
#   Needs from the caller: RUN, TO_RUN, WORK (and RED/YEL/BLD/OFF for colour, optional). Sets TMP_ROOT (begin) and TMP_GUARD_RAN,
#   TMP_FINDINGS, TMP_LEAK_SUITES, TMP_LEAK_BYTES, TMP_OUTSIDE_COUNT (guard); writes $WORK/tmp-leaks.tsv, tmp-outside.tsv (what the
#   receipt is built from), tmp-section.txt (the loud text) and tmp-summary.txt (the summary lines).
#
# hmd_test_disk_preflight / hmd_test_sock_preflight   REFUSE TO START a sweep that cannot work (always on; run-all.sh calls them before the lock, the work dir,
#     any trap or receipt exists, so a refusal leaves nothing behind; neither runs on a dry run).
#   * disk (exit 5): if the volume holding TMPDIR, or the one holding the repo, has less than HMD_TEST_MIN_FREE_GB (default 5; 0 = off) GB free, OR less than
#     HMD_MIN_FREE_PCT (default 10; 0 = off) percent free -- whichever is stricter refuses -- the sweep is refused with a line per floor crossed, naming the volume
#     and what is free. A sweep writes real data (fixtures, clones, git history) and the machine had just lost 1.6 GB to suite leftovers; then (2026-10-14) it sat
#     at 7.1% free. The percent floor is the ONE definition the Agent and Bash hooks share (bin/lib/hmd_disk_floor.sh, loaded below when it is there; a fixture copy
#     of the runner has no bin/lib of its own and runs on the GB floor alone, as before). Free space comes from `df -Pk` looked up through PATH (so the tests can
#     fake it); a df that cannot answer skips that check with a notice -- a preflight must not be the reason a sweep cannot run.
#   * sockets (exit 6): macOS caps a unix socket path at 104 bytes including the NUL (103 usable). Every byte of the per-suite temp dir comes out of what a suite
#     can use, so the dir is named as short as possible ($TMPDIR/hr.XXXX/s<N>) and its length is CHECKED: headroom = 103 - length(the widest per-suite dir, in the
#     longer of its logical and its `cd -P` spelling -- macOS /var is /private/var). The longest socket path the suites can build is COMPUTED (hmd_test_sock_need:
#     the files under test/ that name AF_UNIX and the $VAR/.../x.sock paths in them, behind the 14 bytes of the suite's own mktemp dir). Under that need the sweep
#     is REFUSED: a suite is certain to fail. Under HMD_TEST_SOCK_HEADROOM (default 60) it is a loud WARNING and a receipt field (tmp_sock) -- on stock macOS TMPDIR
#     is already 48 bytes, so 60 cannot hold there and a refusal would block every sweep. Sockets are NEVER moved to the shared /tmp to buy room: that is exactly
#     the kind of leak this machinery exists to catch.
#
# hmd_test_disk_recheck   THE SAME TWO FLOORS, ASKED AGAIN BETWEEN SUITES. run-all.sh calls it before every suite it launches (and every solo re-run of a red): the first
#   time a volume is under a floor the runner launches nothing more, and the rest of the sweep is REFUSED -- a table row, receipt fields, a red run. Quiet about a df that
#   cannot answer (the preflight said so once). Sets DISK_RECHECK_MSG (the clauses, joined with "; ") and returns 1 when something is short.

# THE SHARED DISK FLOOR (bin/lib/hmd_disk_floor.sh): the percent floor is defined ONCE, for the hooks and for this runner. Loaded when it sits two directories up from this file
# (a real checkout); a fixture copy of the runner (the test/run-all-*.test.sh suites) has no bin/lib of its own, then only the GB floor below applies, as it always did.
_hmd_guards_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=../../bin/lib/hmd_disk_floor.sh disable=SC1091  # the path is derived from this file's own location at runtime
if [ -n "$_hmd_guards_dir" ] && [ -r "$_hmd_guards_dir/../../bin/lib/hmd_disk_floor.sh" ]; then . "$_hmd_guards_dir/../../bin/lib/hmd_disk_floor.sh"; fi

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

# hmd_test_fmt_bytes N -- "512 KB" / "3.0 MB" / "1.6 GB" for the human lines.
hmd_test_fmt_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1073741824) printf "%.1f GB", b / 1073741824
    else if (b >= 1048576) printf "%.1f MB", b / 1048576
    else printf "%.0f KB", b / 1024
  }'
}

# hmd_test_tmp_watch_dirs -- the directories whose TOP LEVEL the outside check watches, one canonical path per line, de-duplicated: /tmp
# (a hard-coded /tmp/... path; /private/tmp on macOS) and the runner's own real $TMPDIR (a suite that reset TMPDIR, or used mktemp -p).
# HMD_TEST_TMP_WATCH (colon-separated) replaces the list -- the tests point it at a sandbox.
hmd_test_tmp_watch_dirs() {
  local IFS=: d c seen=""
  for d in ${HMD_TEST_TMP_WATCH:-/tmp:${TMPDIR:-/tmp}}; do
    [ -n "$d" ] || continue
    c="$(cd -P "$d" 2>/dev/null && pwd)" || continue
    case "$seen" in *"|$c|"*) continue ;; esac
    seen="$seen|$c|"
    printf '%s\n' "$c"
  done
}

# hmd_test_tmp_snapshot OUTFILE -- every top-level entry of every watched directory (full path), sorted for comm(1).
hmd_test_tmp_snapshot() {
  local out="$1" d
  : > "$out" || return 0
  while IFS= read -r d; do
    find "$d" -mindepth 1 -maxdepth 1 2>/dev/null >> "$out"
  done < <(hmd_test_tmp_watch_dirs)
  LC_ALL=C sort -o "$out" "$out"
}

# hmd_test_tmp_begin WORK -- make the run-level temp root (sets TMP_ROOT, "" when it cannot be made: the sweep then runs with suites
# sharing the machine TMPDIR, loudly, and no leak accounting) and take the before-snapshot. Taken AFTER the root exists, so the root
# and the runner's own WORK dir are in both snapshots and never show up as new.
hmd_test_tmp_begin() {
  local work="$1" base="${TMPDIR:-/tmp}"
  base="${base%/}"; [ -n "$base" ] || base=/tmp
  TMP_ROOT="$(mktemp -d "$base/hr.XXXX" 2>/dev/null)" || TMP_ROOT="$(mktemp -d "$base/hr.XXXXXX" 2>/dev/null)" || TMP_ROOT=""
  if [ -z "$TMP_ROOT" ]; then
    echo "run-all: could not create the per-suite temp root under $base -- suites share the machine TMPDIR this run and their leftovers are NOT accounted for" >&2
    return 0
  fi
  # THIS platform's mktemp may ignore $TMPDIR for its template-less and -t forms (observed 2026-10-13 on Darwin 27: `TMPDIR=x mktemp -d` and
  # `mktemp -d -t p` answered with the user temp dir whatever TMPDIR said), which would put every suite's `mktemp -d` straight back OUTSIDE its
  # own dir. Probe once; only when it ignores TMPDIR, put a shim first on PATH (the suites inherit it) that answers exactly those forms from
  # $TMPDIR and passes everything else -- explicit templates, -p, -u -- to the real mktemp. A mktemp that honours TMPDIR gets no shim.
  hmd_test_mktemp_shim "$TMP_ROOT"
  hmd_test_tmp_snapshot "$work/tmp-outside-before.txt"
}

# hmd_test_mktemp_shim DIR -- the probe-and-shim described above, on its own, so a suite run ALONE (test/lib/private-tmp.sh) gets the same answer as one run by the
# sweep: a template-less mktemp lands under $TMPDIR. DIR is owned (and removed) by the caller; the probe dir and the shim live in it. Sets and exports
# HMD_MKTEMP_SHIM_DIR when it installs a shim -- a child whose PATH is rebuilt (`env -i ... PATH=...`) puts that directory first to keep the shim.
hmd_test_mktemp_shim() {
  local dir="$1" probe="$1/.probe" got real
  mkdir -p "$probe" 2>/dev/null
  got="$(TMPDIR="$probe" mktemp -d 2>/dev/null)"
  case "$got" in
    "$probe"/?*) rmdir "$got" 2>/dev/null ;;
    *)
      [ -z "$got" ] || rm -rf "$got" 2>/dev/null
      real="$(command -v mktemp 2>/dev/null)"
      case "$real" in
        /*\'*|/*\ *|'') echo "run-all: this platform's mktemp ignores TMPDIR and no usable path to it was found -- suites' mktemp dirs may land outside their own TMPDIR" >&2 ;;
        /*)
          mkdir -p "$dir/.shim" 2>/dev/null
          { printf '#!/bin/sh\nreal=%s\n' "'$real'"; cat <<'SHIMEOF'
d=""; prefix=tmp
if [ "$#" -eq 1 ] && [ "$1" = -d ]; then d=-d
elif [ "$#" -eq 2 ] && [ "$1" = -t ]; then prefix="$2"
elif [ "$#" -eq 3 ] && [ "$1" = -d ] && [ "$2" = -t ]; then d=-d; prefix="$3"
elif [ "$#" -eq 3 ] && [ "$1" = -t ] && [ "$3" = -d ]; then d=-d; prefix="$2"
elif [ "$#" -ne 0 ]; then exec "$real" "$@"
fi
base="${TMPDIR:-/tmp}"; base="${base%/}"
exec "$real" $d "$base/$prefix.XXXXXXXX"
SHIMEOF
          } > "$dir/.shim/mktemp" 2>/dev/null && chmod +x "$dir/.shim/mktemp" && { PATH="$dir/.shim:$PATH"; HMD_MKTEMP_SHIM_DIR="$dir/.shim"; export PATH HMD_MKTEMP_SHIM_DIR; }
          ;;
      esac
      ;;
  esac
  rmdir "$probe" 2>/dev/null
  return 0
}

# hmd_test_suite_tmp_settle DIR LEAKFILE -- DIR is a suite's own TMPDIR ($TMP_ROOT/<idx>) and its suite has ended AND its process group
# has been reaped (timeout_run returned). Append "bytes<TAB>entries<TAB>sample" to LEAKFILE when anything is left (entries = top-level
# entries, i.e. the temp dirs/files the suite never removed; bytes = du, block-rounded), then remove DIR. Refuses anything that is not
# strictly inside TMP_ROOT, so a bad argument can never delete a path this run did not create.
hmd_test_suite_tmp_settle() {
  local dir="$1" leakfile="$2" entries kb sample
  case "$dir" in "${TMP_ROOT:-/nonexistent-root}"/?*) ;; *) return 0 ;; esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  chmod -R u+rwX "$dir" 2>/dev/null
  entries="$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [ "${entries:-0}" -gt 0 ]; then
    kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
    sample="$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | LC_ALL=C sort | head -n 5 | sed 's#.*/##' | LC_ALL=C tr -c 'A-Za-z0-9._@+=\n-' '?' | paste -sd, -)"
    printf '%s\t%s\t%s\n' "$(( ${kb:-0} * 1024 ))" "$entries" "$sample" >> "$leakfile"
  fi
  rm -rf "$dir" 2>/dev/null
  if [ -e "$dir" ]; then sleep 0.3; chmod -R u+rwX "$dir" 2>/dev/null; rm -rf "$dir" 2>/dev/null; fi
  [ ! -e "$dir" ] || echo "run-all: could not remove $dir after its suite ended" >&2
  return 0
}

# _hmd_tmp_rows FILE CAP -- "  name  size in N entries  (sample)" for the lines of a name/bytes/entries/sample TSV, at most CAP of them.
_hmd_tmp_rows() {
  local f="$1" cap="${2:-15}" n=0 name b e s tab=$'\t' total
  total="$(wc -l < "$f" | tr -d ' ')"
  while IFS="$tab" read -r name b e s; do
    [ "$n" -lt "$cap" ] || break
    printf '  %-52s %9s in %s entr%s  (%s)\n' "$name" "$(hmd_test_fmt_bytes "$b")" "$e" "$([ "$e" = 1 ] && echo y || echo ies)" "$s"
    n=$((n + 1))
  done < "$f"
  [ "$total" -le "$cap" ] || printf '  ... and %d more (all of them are in the receipt: tmp_leaks)\n' "$((total - cap))"
}

# hmd_test_tmp_guard WORK -- the end-of-sweep verdict (see the header). Prints nothing itself: the loud text is in $WORK/tmp-section.txt
# and the summary lines in $WORK/tmp-summary.txt, which run-all.sh prints where its other sections go.
hmd_test_tmp_guard() {
  local work="$1" tab=$'\t' max_mb="${HMD_TEST_TMP_LEAK_MAX_MB:-50}" strict=0 max_b i=0 j line b e s name rest why limit_txt dirs foreign_txt
  local n_leak=0 n_over=0 sum_b=0 n_out=0 n_foreign=0 p mt kb cands s0 s1 sfx checked=0 n_out_big=0 n_new=0 n_skip=0 out_cap
  local R="${RED:-}" Y="${YEL:-}" B="${BLD:-}" O="${OFF:-}"
  TMP_GUARD_RAN=1; TMP_FINDINGS=0; TMP_LEAK_SUITES=0; TMP_LEAK_BYTES=0; TMP_OUTSIDE_COUNT=0
  [ "${HMD_TEST_STRICT_TMP:-0}" = 1 ] && strict=1
  case "$max_mb" in ''|*[!0-9]*) max_mb=50 ;; esac
  max_b=$((max_mb * 1048576))
  out_cap="${HMD_TEST_TMP_OUTSIDE_MAX:-2000}"; case "$out_cap" in ''|*[!0-9]*|0) out_cap=2000 ;; esac
  if [ "$strict" -eq 1 ]; then limit_txt="the strict limit (any leftover)"; else limit_txt="the ${max_mb} MB limit"; fi
  : > "$work/tmp-leaks.tsv"; : > "$work/tmp-leaks-over.tsv"; : > "$work/tmp-leaks-under.tsv"
  : > "$work/tmp-outside.tsv"; : > "$work/tmp-outside-big.tsv"; : > "$work/tmp-section.txt"; : > "$work/tmp-summary.txt"
  # name -> dir map, for attribution: which per-suite dir (s<N>) belonged to which suite, so a path found in a log, an orphan's cwd or a leftover traces back to its suite.
  : > "$work/tmp-dirs.tsv"
  while [ "$i" -lt "${TO_RUN:-0}" ]; do printf '%s\ts%d\n' "${RUN[$i]##*/}" "$i" >> "$work/tmp-dirs.tsv"; i=$((i + 1)); done
  i=0

  # 1. what each suite left in its own TMPDIR. A suite re-run alone (a red) has one line per run: the worst one counts.
  while [ "$i" -lt "${TO_RUN:-0}" ]; do
    if [ -s "$work/$i.tmpleak" ]; then
      line="$(LC_ALL=C sort -t "$tab" -k1,1nr "$work/$i.tmpleak" | head -n 1)"
      b="${line%%"$tab"*}"; rest="${line#*"$tab"}"; e="${rest%%"$tab"*}"; s="${rest#*"$tab"}"
      case "$b" in ''|*[!0-9]*) b=0 ;; esac
      case "$e" in ''|*[!0-9]*) e=0 ;; esac
      name="${RUN[$i]##*/}"
      printf '%s\t%s\t%s\t%s\n' "$name" "$b" "$e" "$s" >> "$work/tmp-leaks.tsv"
      n_leak=$((n_leak + 1)); sum_b=$((sum_b + b))
      if [ "$b" -gt "$max_b" ] || { [ "$strict" -eq 1 ] && [ "$e" -gt 0 ]; }; then
        n_over=$((n_over + 1)); printf '%s\t%s\t%s\t%s\n' "$name" "$b" "$e" "$s" >> "$work/tmp-leaks-over.tsv"
      else
        printf '%s\t%s\t%s\t%s\n' "$name" "$b" "$e" "$s" >> "$work/tmp-leaks-under.tsv"
      fi
    fi
    i=$((i + 1))
  done

  # 2. what appeared OUTSIDE the suites' TMPDIRs: new top-level entries in the watched directories, attributed by mtime window.
  if [ -f "$work/tmp-outside-before.txt" ]; then
    checked=1
    hmd_test_tmp_snapshot "$work/tmp-outside-after.txt"
    LC_ALL=C comm -13 "$work/tmp-outside-before.txt" "$work/tmp-outside-after.txt" > "$work/tmp-outside-new.txt" 2>/dev/null
    n_new="$(wc -l < "$work/tmp-outside-new.txt" | tr -d '[:space:]')"; case "$n_new" in ''|*[!0-9]*) n_new=0 ;; esac
    : > "$work/tmp-windows.txt"
    j=0
    while [ "$j" -lt "${TO_RUN:-0}" ]; do
      for sfx in "" ".parallel"; do
        [ -f "$work/$j.t0$sfx" ] && [ -f "$work/$j.t1$sfx" ] || continue
        read -r s0 < "$work/$j.t0$sfx"; read -r s1 < "$work/$j.t1$sfx"
        [ -n "$s0" ] && [ -n "$s1" ] || continue
        printf '%s %s %s\n' "$s0" "$s1" "${RUN[$j]##*/}" >> "$work/tmp-windows.txt"
      done
      j=$((j + 1))
    done
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in "${TMP_ROOT:-/nonexistent-root}") continue ;; esac
      mt="$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null)"
      [ -n "$mt" ] || continue
      cands="$(awk -v m="$mt" '$1 - 1 <= m && m <= $2 + 1 { print $3 }' "$work/tmp-windows.txt" | LC_ALL=C sort -u | paste -sd' ' -)"
      if [ -z "$cands" ]; then n_foreign=$((n_foreign + 1)); continue; fi
      kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
      printf '%s\t%s\t%s\t%s\n' "$p" "$(( ${kb:-0} * 1024 ))" "$mt" "$cands" >> "$work/tmp-outside.tsv"
      n_out=$((n_out + 1))
      if [ "$(( ${kb:-0} * 1024 ))" -gt "$max_b" ]; then
        printf '%s\t%s\t%s\t%s\n' "$p" "$(( ${kb:-0} * 1024 ))" "$mt" "$cands" >> "$work/tmp-outside-big.tsv"
        n_out_big=$((n_out_big + 1))
      fi
    done < <(head -n "$out_cap" "$work/tmp-outside-new.txt")
    [ "$n_new" -le "$out_cap" ] || n_skip=$((n_new - out_cap))
  fi

  # 3. the loud text, then the summary lines.
  if [ "$n_over" -gt 0 ]; then
    if [ "$strict" -eq 1 ]; then why="left something behind (HMD_TEST_STRICT_TMP=1)"; else why="left more than ${max_mb} MB behind"; fi
    printf '%s%sTMP LEAK (%d)%s -- suite(s) that %s in their own TMPDIR. The runner removed it, but a suite must clean up after itself (trap '"'"'rm -rf "$T"'"'"' EXIT):\n' "$R" "$B" "$n_over" "$O" "$why" >> "$work/tmp-section.txt"
    _hmd_tmp_rows "$work/tmp-leaks-over.tsv" 15 >> "$work/tmp-section.txt"
  fi
  if [ "$((n_leak - n_over))" -gt 0 ]; then
    printf '%s%sTMP LEFTOVERS (%d)%s -- suite(s) that left something in their own TMPDIR, under %s (removed by the runner; recorded in the receipt as tmp_leaks):\n' "$Y" "$B" "$((n_leak - n_over))" "$O" "$limit_txt" >> "$work/tmp-section.txt"
    _hmd_tmp_rows "$work/tmp-leaks-under.tsv" 15 >> "$work/tmp-section.txt"
  fi
  dirs="$(hmd_test_tmp_watch_dirs | paste -sd, -)"
  if [ "$n_out_big" -gt 0 ]; then
    printf '%s%sTMP LEAK OUTSIDE TMPDIR (%d)%s -- new top-level entr%s of more than %d MB in %s while these suites ran, written outside their own TMPDIR (a hard-coded /tmp path, or a child started with env -i, which drops TMPDIR). NOT removed (attribution is by mtime window), but a leak this size is what filled the disk (a pip-unpack-* dir is 100 MB), so it fails the run:\n' "$R" "$B" "$n_out_big" "$O" "$([ "$n_out_big" = 1 ] && echo y || echo ies)" "$max_mb" "$dirs" >> "$work/tmp-section.txt"
    LC_ALL=C sort -t "$tab" -k2,2nr "$work/tmp-outside-big.tsv" | head -n 10 | while IFS="$tab" read -r p b mt cands; do
      printf '  %-60s %9s  (mtime %s -- running then: %s)\n' "$p" "$(hmd_test_fmt_bytes "$b")" "$mt" "$cands" >> "$work/tmp-section.txt"
    done
  fi
  if [ "$n_skip" -gt 0 ]; then
    printf '%s%sTMP OUTSIDE TMPDIR NOT FULLY CHECKED%s -- %d new top-level entries appeared in %s, only the first %d (by name) were examined; HMD_TEST_TMP_OUTSIDE_MAX raises the bound\n' "$Y" "$B" "$O" "$n_new" "$dirs" "$out_cap" >> "$work/tmp-section.txt"
  fi
  if [ "$n_out" -gt 0 ]; then
    printf '%s%sTMP OUTSIDE TMPDIR (%d)%s -- new top-level entr%s in %s while these suites ran (a hard-coded /tmp path, or a suite that reset TMPDIR). NOT removed: whose they are cannot be proved, attribution is by mtime window and suites overlap:\n' "$Y" "$B" "$n_out" "$O" "$([ "$n_out" = 1 ] && echo y || echo ies)" "$dirs" >> "$work/tmp-section.txt"
    LC_ALL=C sort -t "$tab" -k2,2nr "$work/tmp-outside.tsv" | head -n 20 | while IFS="$tab" read -r p b mt cands; do
      printf '  %-60s %9s  (mtime %s -- running then: %s)\n' "$p" "$(hmd_test_fmt_bytes "$b")" "$mt" "$cands" >> "$work/tmp-section.txt"
    done
    [ "$n_out" -le 20 ] || printf '  ... and %d more (all of them are in the receipt: tmp_outside)\n' "$((n_out - 20))" >> "$work/tmp-section.txt"
  fi
  if [ "$n_leak" -eq 0 ]; then
    echo "tmp dirs:   clean -- every suite's own TMPDIR was empty when its suite ended" >> "$work/tmp-summary.txt"
  else
    printf 'tmp dirs:   %d suite(s) left %s in their own TMPDIR (removed); %d over %s\n' "$n_leak" "$(hmd_test_fmt_bytes "$sum_b")" "$n_over" "$limit_txt" >> "$work/tmp-summary.txt"
  fi
  if [ "$checked" -eq 1 ]; then
    foreign_txt=""
    [ "$n_foreign" -eq 0 ] || foreign_txt="; $n_foreign more had no suite running when written (other processes) and are ignored"
    [ "$n_skip" -eq 0 ] || foreign_txt="$foreign_txt; $n_skip more new entries were NOT examined (HMD_TEST_TMP_OUTSIDE_MAX=$out_cap)"
    if [ "$n_out" -gt 0 ]; then
      printf 'tmp outside: %d new entr%s at the top level of %s while suites ran (listed above, NOT removed)%s\n' "$n_out" "$([ "$n_out" = 1 ] && echo y || echo ies)" "$dirs" "$foreign_txt" >> "$work/tmp-summary.txt"
    else
      printf 'tmp outside: none attributed to a suite at the top level of %s%s\n' "$dirs" "$foreign_txt" >> "$work/tmp-summary.txt"
    fi
  fi

  if [ -n "${SOCK_HEADROOM:-}" ]; then
    printf 'tmp sockets: %s bytes left under the per-suite temp dir for a unix socket path (limit 104; target %s; the longest socket the suites build needs %s)%s\n' "$SOCK_HEADROOM" "${SOCK_TARGET:-?}" "${SOCK_NEED:-?}" "$([ "$SOCK_HEADROOM" -lt "${SOCK_TARGET:-0}" ] && printf ' -- BELOW TARGET')" >> "$work/tmp-summary.txt"
  fi
  TMP_LEAK_SUITES=$n_leak; TMP_LEAK_BYTES=$sum_b; TMP_OUTSIDE_COUNT=$n_out
  TMP_FINDINGS=$((n_over + n_out_big))
  [ "$strict" -eq 1 ] && TMP_FINDINGS=$((n_over + n_out))
  return 0
}

# ── PREFLIGHTS: refuse to START a sweep that cannot work ──────────────────────────────────────────────────────────────────────────

# _hmd_df_free PATH -- "<free KB><TAB><size KB><TAB><mount point>" of the volume holding PATH (df -Pk: column 4 is Available and column 2 the size, in 1024-byte blocks,
# column 6 on is the mount point, which can hold spaces), "" when df cannot say. `df` is looked up through PATH on purpose: the tests put a fake one first.
_hmd_df_free() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { m = $6; for (i = 7; i <= NF; i++) m = m " " $i; print $4 "\t" $2 "\t" m }'
}

# _hmd_disk_clause WHAT FREE_KB SIZE_KB MOUNT MIN_GB -- the GB floor's clause for one short volume (no prefix, no full stop), e.g.
# "only 1.0 GB (1.0%) free on the volume holding TMPDIR=/x (mounted on /vol); a sweep needs at least 5 GB free (HMD_TEST_MIN_FREE_GB)". The percent is truncated, never rounded
# (bin/lib/hmd_disk_floor.sh says why), and left out when the size could not be read.
_hmd_disk_clause() {
  local pct=""
  case "${3:-}" in ''|*[!0-9]*|0) ;; *) pct=" ($(awk -v f="$2" -v s="$3" 'BEGIN { printf "%.1f", int(f * 1000 / s) / 10 }')%)" ;; esac
  printf 'only %s%s free on the volume holding %s (mounted on %s); a sweep needs at least %s GB free (HMD_TEST_MIN_FREE_GB)' "$(hmd_test_fmt_bytes $(( $2 * 1024 )))" "$pct" "$1" "$4" "$5"
}

# _hmd_disk_add CLAUSES -- append CLAUSES (one per line) to DISK_SHORT_CLAUSES.
_hmd_disk_add() { DISK_SHORT_CLAUSES="${DISK_SHORT_CLAUSES:+$DISK_SHORT_CLAUSES$'\n'}$1"; }

# _hmd_disk_short REPO -- BOTH floors against the volume holding TMPDIR and the one holding the repo: the GB floor (HMD_TEST_MIN_FREE_GB, default 5; 0 = off) and the percent floor
# (HMD_MIN_FREE_PCT, default 10; 0 = off; bin/lib/hmd_disk_floor.sh, the one definition the hooks share). Whichever is stricter refuses; they are separate knobs, so turning
# one off leaves the other on. Sets DISK_SHORT_CLAUSES (one clause per floor per short volume, newline-separated, no prefix, no full stop; "" when nothing is short) and returns 1
# when something is. A volume df cannot answer for is ONE notice on stderr (none under HMD_DISK_FLOOR_QUIET=1) and no check for it: a guard must never be the reason a sweep
# cannot run on a machine where df itself is broken. Without the shared lib (a fixture copy of the runner) only the GB floor exists.
_hmd_disk_short() {
  local repo="$1" min_gb="${HMD_TEST_MIN_FREE_GB:-5}" pct=0 tdir="${TMPDIR:-/tmp}" tab=$'\t' min_kb t r tk tsz tmnt rk rsz rmnt rest lines
  DISK_SHORT_CLAUSES=""
  case "$min_gb" in ''|*[!0-9]*) min_gb=5 ;; esac
  if type hmd_disk_floor_pct >/dev/null 2>&1; then pct="$(hmd_disk_floor_pct)"; fi
  [ "$min_gb" -gt 0 ] || [ "$pct" -gt 0 ] || return 0
  min_kb=$((min_gb * 1048576))
  t="$(_hmd_df_free "$tdir")"; r="$(_hmd_df_free "$repo")"
  tk="${t%%"$tab"*}"; rest="${t#*"$tab"}"; tsz="${rest%%"$tab"*}"; tmnt="${rest#*"$tab"}"
  rk="${r%%"$tab"*}"; rest="${r#*"$tab"}"; rsz="${rest%%"$tab"*}"; rmnt="${rest#*"$tab"}"
  case "$tk" in ''|*[!0-9]*) tk="" ;; esac
  case "$rk" in ''|*[!0-9]*) rk="" ;; esac
  if [ "${HMD_DISK_FLOOR_QUIET:-0}" != 1 ]; then
    [ -n "$tk" ] || echo "run-all: could not read the free space of the volume holding TMPDIR=$tdir with df -- no disk check for it" >&2
    [ -n "$rk" ] || echo "run-all: could not read the free space of the volume holding the repo $repo with df -- no disk check for it" >&2
  fi
  if [ "$min_gb" -gt 0 ]; then
    if [ -n "$tk" ] && [ -n "$rk" ] && [ "$tmnt" = "$rmnt" ]; then
      [ "$tk" -ge "$min_kb" ] || _hmd_disk_add "$(_hmd_disk_clause "TMPDIR=$tdir and the repo $repo" "$tk" "$tsz" "$tmnt" "$min_gb")"
    else
      [ -z "$tk" ] || [ "$tk" -ge "$min_kb" ] || _hmd_disk_add "$(_hmd_disk_clause "TMPDIR=$tdir" "$tk" "$tsz" "$tmnt" "$min_gb")"
      [ -z "$rk" ] || [ "$rk" -ge "$min_kb" ] || _hmd_disk_add "$(_hmd_disk_clause "the repo $repo" "$rk" "$rsz" "$rmnt" "$min_gb")"
    fi
  fi
  # the percent floor asks df itself (two more calls: the shared check owns the volume grouping and the wording); its own warning about a df that cannot answer is off, the notices above
  # already said it
  if [ "$pct" -gt 0 ] && type hmd_disk_floor_check >/dev/null 2>&1; then
    lines="$(HMD_DISK_FLOOR_QUIET=1 hmd_disk_floor_check "$tdir" "$repo")" || _hmd_disk_add "$lines"
  fi
  [ -z "$DISK_SHORT_CLAUSES" ]
}

# hmd_test_disk_preflight REPO -- return 1 (one refusal line per clause on stderr, then what to do) when the volume holding TMPDIR, or the one holding the repo, is under the GB floor or
# the percent floor (see _hmd_disk_short). One volume holding both is reported once per floor. A df that cannot answer skips that check with a notice: a preflight must never be the
# reason a sweep cannot run on a machine where df itself is broken.
hmd_test_disk_preflight() {
  local c
  _hmd_disk_short "$1" && return 0
  while IFS= read -r c; do
    [ -z "$c" ] || echo "run-all: refusing to start -- $c." >&2
  done <<EOF
$DISK_SHORT_CLAUSES
EOF
  echo "         Nothing was run and no receipt was written. Free space first (hmd system-health, or the mac-deep-clean skill), or lower HMD_TEST_MIN_FREE_GB / HMD_MIN_FREE_PCT on purpose." >&2
  return 1
}

# hmd_test_disk_recheck REPO -- the same two floors, asked again between suites (run-all.sh before every suite it launches, and before every solo re-run of a red). Returns 0 and
# DISK_RECHECK_MSG="" while both hold; returns 1 and sets DISK_RECHECK_MSG (the clauses, joined with "; ") when a volume has fallen under one. Silent: a df that cannot answer is
# not repeated before every suite (the preflight said it once) and is no reason to stop a sweep.
hmd_test_disk_recheck() {
  DISK_RECHECK_MSG=""
  HMD_DISK_FLOOR_QUIET=1 _hmd_disk_short "$1" && return 0
  # shellcheck disable=SC2034  # read by test/run-all.sh (_disk_gate), which sources this file
  DISK_RECHECK_MSG="${DISK_SHORT_CLAUSES//$'\n'/; }"
  return 1
}

# hmd_test_sock_need REPO -- "<bytes> <file>": the longest unix-socket path, counted from the per-suite temp dir, that a suite can build; "0 -" when none does.
# Read off the suites: every file under test/ that names AF_UNIX, and the shell-style socket paths in it ($VAR/.../name.sock), behind the 14 bytes ("/tmp.XXXXXXXX/")
# of the mktemp dir a suite makes under its TMPDIR. A heuristic over what the suites WRITE, not a proof about what bin/ builds at run time -- but hmd ui, the relay
# client, the ledger, the MCP servers and the dashboards listen on TCP or stdio, so the suites that bind a unix socket themselves are the whole list today. This
# guard's own files are skipped: they name AF_UNIX and .sock in order to look for them.
hmd_test_sock_need() {
  local repo="$1" f rel n best=0 best_f="-"
  for f in $(grep -lIE 'AF_UNIX' "$repo"/test/*.test.sh "$repo"/test/lib/* 2>/dev/null); do
    case "${f##*/}" in run-all-guards.sh|run-all-guards.test.sh) continue ;; esac
    while IFS= read -r rel; do
      rel="${rel#*/}"
      n=$(( ${#rel} + 14 ))
      if [ "$n" -gt "$best" ]; then best=$n; best_f="${f##*/}"; fi
    done < <(grep -ohIE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/[A-Za-z0-9_./-]*\.sock' "$f" 2>/dev/null)
  done
  printf '%s %s\n' "$best" "$best_f"
}

# hmd_test_sock_preflight REPO NSUITES -- will a unix socket path still fit under the per-suite temp dir? macOS caps sun_path at 104 bytes INCLUDING the NUL, so a
# socket path may be 103 bytes; headroom = 103 - length(the widest per-suite dir). That dir is $TMPDIR/hr.XXXX/s<NSUITES> -- in the longer of its logical and its
# `cd -P` spelling, since a suite that does `cd "$TMPDIR" && pwd -P` builds its socket path from the canonical one (macOS: /var is /private/var). Sets SOCK_DIR,
# SOCK_HEADROOM, SOCK_NEED, SOCK_TARGET (the receipt's tmp_sock). Returns 1 (refusal on stderr) when the headroom is below SOCK_NEED, the longest socket path the suites
# build: a suite is then certain to fail, so the sweep does not start. Below HMD_TEST_SOCK_HEADROOM (default 60) it only warns (stdout): on stock macOS TMPDIR is
# already 48 bytes, so 60 cannot hold there and a refusal would block every sweep. Sockets are never moved to the shared /tmp to buy room.
hmd_test_sock_preflight() {
  local repo="$1" n="${2:-0}" target="${HMD_TEST_SOCK_HEADROOM:-60}" base="${TMPDIR:-/tmp}" canon need_line need need_f
  SOCK_DIR=""; SOCK_HEADROOM=""; SOCK_NEED=""; SOCK_TARGET=""
  case "$target" in ''|*[!0-9]*) target=60 ;; esac
  base="${base%/}"; [ -n "$base" ] || base=/tmp
  canon="$(cd -P "$base" 2>/dev/null && pwd)"
  if [ -n "$canon" ] && [ "${#canon}" -gt "${#base}" ]; then base="$canon"; fi
  SOCK_DIR="$base/hr.XXXX/s$n"
  SOCK_HEADROOM=$((103 - ${#SOCK_DIR}))
  need_line="$(hmd_test_sock_need "$repo")"; need="${need_line%% *}"; need_f="${need_line#* }"
  SOCK_NEED=$need; SOCK_TARGET=$target
  if [ "$SOCK_HEADROOM" -lt "$need" ]; then
    echo "run-all: refusing to start -- the per-suite temp dir (e.g. $SOCK_DIR, ${#SOCK_DIR} bytes) leaves only $SOCK_HEADROOM of the 103 bytes a unix socket path may have (macOS sun_path is 104 with the NUL), and $need_f builds one that needs $need. Use a shorter TMPDIR. Nothing was run and no receipt was written." >&2
    return 1
  fi
  if [ "$SOCK_HEADROOM" -lt "$target" ]; then
    echo "${YEL:-}sock paths:${OFF:-} only $SOCK_HEADROOM bytes are left under the per-suite temp dir ($SOCK_DIR) for a unix socket path (macOS limit 104; target $target, HMD_TEST_SOCK_HEADROOM changes it; the longest socket the suites build needs $need) -- a shorter TMPDIR gives more room"
  fi
  return 0
}

#!/usr/bin/env bash
# run-all-guards.sh -- sourced by test/run-all.sh. Three things the runner does about the machine it runs on.
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
#     * hmd_test_tmp_begin makes ONE run-level root (TMP_ROOT = $TMPDIR/hmd-ra.XXXXXX -- short on purpose, a unix socket path under it
#       must stay inside the 104-byte macOS limit) and takes the before-snapshot of the directories the outside check watches;
#     * run_one gives each suite a fresh $TMP_ROOT/<idx> as ITS TMPDIR, so everything it makes through mktemp / $TMPDIR / python
#       tempfile lands there;
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
#   Needs from the caller: RUN, TO_RUN, WORK (and RED/YEL/BLD/OFF for colour, optional). Sets TMP_ROOT (begin) and TMP_GUARD_RAN,
#   TMP_FINDINGS, TMP_LEAK_SUITES, TMP_LEAK_BYTES, TMP_OUTSIDE_COUNT (guard); writes $WORK/tmp-leaks.tsv, tmp-outside.tsv (what the
#   receipt is built from), tmp-section.txt (the loud text) and tmp-summary.txt (the summary lines).

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
  TMP_ROOT="$(mktemp -d "$base/hmd-ra.XXXXXX" 2>/dev/null)" || TMP_ROOT=""
  if [ -z "$TMP_ROOT" ]; then
    echo "run-all: could not create the per-suite temp root under $base -- suites share the machine TMPDIR this run and their leftovers are NOT accounted for" >&2
    return 0
  fi
  # THIS platform's mktemp may ignore $TMPDIR for its template-less and -t forms (observed 2026-10-13 on Darwin 27: `TMPDIR=x mktemp -d` and
  # `mktemp -d -t p` answered with the user temp dir whatever TMPDIR said), which would put every suite's `mktemp -d` straight back OUTSIDE its
  # own dir. Probe once; only when it ignores TMPDIR, put a shim first on PATH (the suites inherit it) that answers exactly those forms from
  # $TMPDIR and passes everything else -- explicit templates, -p, -u -- to the real mktemp. A mktemp that honours TMPDIR gets no shim.
  local probe="$TMP_ROOT/.probe" got real
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
          mkdir -p "$TMP_ROOT/.shim" 2>/dev/null
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
          } > "$TMP_ROOT/.shim/mktemp" 2>/dev/null && chmod +x "$TMP_ROOT/.shim/mktemp" && { PATH="$TMP_ROOT/.shim:$PATH"; export PATH; }
          ;;
      esac
      ;;
  esac
  rmdir "$probe" 2>/dev/null
  hmd_test_tmp_snapshot "$work/tmp-outside-before.txt"
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
  local n_leak=0 n_over=0 sum_b=0 n_out=0 n_foreign=0 p mt kb cands s0 s1 sfx checked=0
  local R="${RED:-}" Y="${YEL:-}" B="${BLD:-}" O="${OFF:-}"
  TMP_GUARD_RAN=1; TMP_FINDINGS=0; TMP_LEAK_SUITES=0; TMP_LEAK_BYTES=0; TMP_OUTSIDE_COUNT=0
  [ "${HMD_TEST_STRICT_TMP:-0}" = 1 ] && strict=1
  case "$max_mb" in ''|*[!0-9]*) max_mb=50 ;; esac
  max_b=$((max_mb * 1048576))
  if [ "$strict" -eq 1 ]; then limit_txt="the strict limit (any leftover)"; else limit_txt="the ${max_mb} MB limit"; fi
  : > "$work/tmp-leaks.tsv"; : > "$work/tmp-leaks-over.tsv"; : > "$work/tmp-leaks-under.tsv"
  : > "$work/tmp-outside.tsv"; : > "$work/tmp-section.txt"; : > "$work/tmp-summary.txt"

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
    done < <(head -n 300 "$work/tmp-outside-new.txt")
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
    if [ "$n_out" -gt 0 ]; then
      printf 'tmp outside: %d new entr%s at the top level of %s while suites ran (listed above, NOT removed)%s\n' "$n_out" "$([ "$n_out" = 1 ] && echo y || echo ies)" "$dirs" "$foreign_txt" >> "$work/tmp-summary.txt"
    else
      printf 'tmp outside: none attributed to a suite at the top level of %s%s\n' "$dirs" "$foreign_txt" >> "$work/tmp-summary.txt"
    fi
  fi

  TMP_LEAK_SUITES=$n_leak; TMP_LEAK_BYTES=$sum_b; TMP_OUTSIDE_COUNT=$n_out
  TMP_FINDINGS=$n_over
  [ "$strict" -eq 1 ] && TMP_FINDINGS=$((n_over + n_out))
  return 0
}

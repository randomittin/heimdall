#!/usr/bin/env bash
# bin/lib/hmd_disk_floor.sh -- THE disk-space floor: one definition, every caller.
#
# WHAT IT IS. Sourceable functions that answer one question -- is there enough free disk to start work? -- the same way in every place that asks it:
#   bin/heimdall-precheck-agent   the Agent hook: DENIES a spawn under the floor
#   bin/heimdall-precheck-bash    the Bash hook: DENIES a command that runs a *.test.sh or test/run-all.sh under the floor
#   test/lib/run-all-guards.sh    the sweep's preflight (exit 5) and its re-check before every suite (REFUSED suites)
#   bin/heimdall-disk-floor       the same, for a human: `check [--path P]`
#
# WHY (2.4.8; operator directive 2026-10-14: "a disk-space floor of 10%, enforced by hooks: agent spawns, test runs, each test file"). The dev
# machine sat at 7.1% free (16.4 GB of 228 GB) while agents ran suites that write fixtures, clones and temp data. A full disk fails in ways that
# look like bugs (a truncated receipt, a git object that will not write), and nothing stopped the next agent, or the next sweep, from making it
# worse. test/run-all.sh already had an absolute floor (HMD_TEST_MIN_FREE_GB, 5 GB); a percentage is the one that scales with the machine, and
# the hooks cover what the sweep's own preflight cannot: a spawn, and a single test file run by hand.
#
# THE KNOB. HMD_MIN_FREE_PCT: the whole percent of a volume that must be free. Default 10 (the operator runs 7 for now). 0 turns the check off.
# Anything else that is not a whole number from 0 to 100 -- a typo such as 7% or abc -- is the DEFAULT, said on stderr: a typo must never silently
# remove the floor. Set it in the environment Claude Code runs in. A hook reads ITS OWN environment, so an inline `HMD_MIN_FREE_PCT=5 bash
# test/x.test.sh` reaches the test but not the hook that decides whether the test may start.
#
# HOW FREE PERCENT IS COMPUTED. `df -Pk`, column 4 (Available) over column 2 (the size), both in 1024-byte blocks. NOT df's Capacity column: on APFS
# that is Used / (Used + Available) of ONE volume and leaves out every other volume of the container, so the Data volume of a disk that is 92% full
# reads 92% while `/` of the same disk reads 44%. The container's Available over its size is the figure that is true of both (here: 17203896 of
# 239362496 = 7.1% free). The comparison is exact integer arithmetic, free*100 < size*floor, so exactly AT the floor is allowed; the percent SHOWN
# is truncated, never rounded, so a volume that is refused never reads as the floor it is under (9.99% shows as 9.9%, not 10.0%). `df` is looked up
# through PATH on purpose: the tests put a fake one first.
#
# FAILS OPEN. This is a resource guard, not a security gate: a df that cannot answer (it fails, prints no row, prints no numbers, or a size of 0)
# is a warning on stderr and ALLOWED -- a hook must not be the reason all work stops on a machine where df is odd. The one thing that denies is a
# volume that was READ and is under the floor.
#
# HMD_DISK_FLOOR_QUIET=1 keeps every warning off stderr (the sweep's per-suite re-check: its preflight said it once).
# Every name here starts hmd_disk_floor_ / HMD_DISK_FLOOR_, so sourcing it into a hook cannot collide with the hook's own. Bash 3.2 compatible
# (macOS /bin/bash) and nounset-safe: a script that runs under `set -u` can source it.

# hmd_disk_floor_pct -- the floor, a whole percent, on stdout: HMD_MIN_FREE_PCT, default 10, 0 = off; a value that is not a whole number from 0 to 100 is the
# default, with a warning naming it.
hmd_disk_floor_pct() {
  local v="${HMD_MIN_FREE_PCT:-}"
  case "$v" in
    '') printf '10\n'; return 0 ;;
    *[!0-9]*) ;;
    *) if [ "${#v}" -le 3 ] && [ "$((10#$v))" -le 100 ]; then printf '%s\n' "$((10#$v))"; return 0; fi ;;
  esac
  [ "${HMD_DISK_FLOOR_QUIET:-0}" = 1 ] || printf 'heimdall disk floor: HMD_MIN_FREE_PCT=%s is not a whole number from 0 to 100 -- using the default, 10\n' "$v" >&2
  printf '10\n'
}

# hmd_disk_floor_stat PATH -- "<free KB><TAB><size KB><TAB><mount point>" of the volume holding PATH (df -Pk: column 4 is Available, column 2 the size, columns 6 on the mount
# point, which can hold spaces), "" when df cannot say.
hmd_disk_floor_stat() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 && NF >= 6 { m = $6; for (i = 7; i <= NF; i++) m = m " " $i; print $4 "\t" $2 "\t" m }'
}

# hmd_disk_floor_below FREE_KB SIZE_KB PCT -- succeeds when FREE is strictly under PCT percent of SIZE (free*100 < size*pct; integers, no rounding). Numeric arguments only.
hmd_disk_floor_below() { [ $(( $1 * 100 )) -lt $(( $2 * $3 )) ]; }

# hmd_disk_floor_fmt FREE_KB SIZE_KB -- "16.4 GB (7.1%)": what is free, in GB and as a percent of the volume, one decimal each (the percent truncated, see the header).
hmd_disk_floor_fmt() { awk -v f="$1" -v s="$2" 'BEGIN { printf "%.1f GB (%.1f%%)", f / 1048576, int(f * 1000 / s) / 10 }'; }

# hmd_disk_floor_line FREE_KB SIZE_KB WHAT MOUNT PCT -- the one-line verdict for a volume under the floor.
hmd_disk_floor_line() {
  printf 'only %s free on the volume holding %s (mounted on %s); the floor is %s%% free (HMD_MIN_FREE_PCT; 0 turns it off)' "$(hmd_disk_floor_fmt "$1" "$2")" "$3" "$4" "$5"
}

# hmd_disk_floor_check PATH... -- the hook entry point. Succeeds, silently, when every volume holding one of the PATHs is at or above the floor, the floor is off, or df could
# not answer for it (a warning on stderr: fail open). Returns 1 when a volume that was read is under the floor, with ONE line per such volume on stdout (hmd_disk_floor_line);
# PATHs on one volume are one line naming them all. An empty PATH is skipped, so an unset TMPDIR never becomes a bogus df call.
hmd_disk_floor_check() {
  local pct p st free rest size mnt tab=$'\t' i j n=0 rc=0
  local -a Mm=() Mf=() Ms=() Ml=()
  pct="$(hmd_disk_floor_pct)"
  [ "$pct" -gt 0 ] || return 0
  for p in "$@"; do
    [ -n "$p" ] || continue
    st="$(hmd_disk_floor_stat "$p")"
    free="${st%%"$tab"*}"; rest="${st#*"$tab"}"; size="${rest%%"$tab"*}"; mnt="${rest#*"$tab"}"
    case "$free" in ''|*[!0-9]*) free="" ;; esac
    case "$size" in ''|*[!0-9]*|0) size="" ;; esac
    if [ -z "$free" ] || [ -z "$size" ]; then
      [ "${HMD_DISK_FLOOR_QUIET:-0}" = 1 ] || printf 'heimdall disk floor: could not read the free space of the volume holding %s with df -- no disk check for it, allowing\n' "$p" >&2
      continue
    fi
    j=-1; i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${Mm[$i]}" = "$mnt" ]; then j=$i; break; fi
      i=$((i + 1))
    done
    if [ "$j" -ge 0 ]; then
      Ml[j]="${Ml[j]} and $p"
    else
      Mm[n]="$mnt"; Mf[n]="$free"; Ms[n]="$size"; Ml[n]="$p"; n=$((n + 1))
    fi
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    if hmd_disk_floor_below "${Mf[$i]}" "${Ms[$i]}" "$pct"; then
      hmd_disk_floor_line "${Mf[$i]}" "${Ms[$i]}" "${Ml[$i]}" "${Mm[$i]}" "$pct"; printf '\n'
      rc=1
    fi
    i=$((i + 1))
  done
  return "$rc"
}

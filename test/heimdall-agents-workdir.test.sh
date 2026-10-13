#!/usr/bin/env bash
#
# test/heimdall-agents-workdir.test.sh -- bin/heimdall-agents leaves NO work dir behind, however its process ends.
#
# THE LEAK (measured 2026-10-14 in one user temp dir): 3,731 `hmd-agents.XXXXXX` dirs, 218 MB, still growing. enumerate() made one (mktemp -d) per call -- the
# statusline runs `heimdall-agents count` on every refresh, hmd ui polls `list --json` -- only to hand three tables to one awk, and removed it with
# `trap 'rm -rf "$workdir"' RETURN`. A RETURN trap runs when the function returns; it can never run when the process is KILLED, and a caller's timeout kills it
# (the statusline's ceiling: TERM, 0.3 s later KILL; python's subprocess timeout: KILL at once). Every such kill left its dir behind.
# The fix is not a better trap -- no trap survives SIGKILL -- it is no directory: the three tables reach awk through process substitution, so there is nothing on
# disk to strand.
#
#   A  while enumerate() is parked in its batched lookup there is NO work dir in TMPDIR at all
#   B  TERM, HUP and KILL to the process group at that moment leave nothing behind
#   C  a count that finishes normally leaves nothing and still counts
# The park point is a `stat` shim on PATH: the batched mtime lookup is the first thing enumerate() does once its tables are being built, so a shim holding it is
# exactly the window the leak lived in.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
AGENTS="$ROOT/bin/heimdall-agents"
# shellcheck source=lib/private-tmp.sh disable=SC1091  # the default run never opens sourced files
. "$SELF_DIR/lib/private-tmp.sh" && hmd_private_tmp heimdall-agents-workdir || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
[ -x "$AGENTS" ] || { echo "FATAL: $AGENTS not executable" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FATAL: perl not found" >&2; exit 2; }

FX="$TMPDIR/fx"
mkdir -p "$FX/tasks" "$FX/bin" "$FX/projects"
: > "$FX/tasks/agent-aaa111.output"
{
  printf '#!/bin/sh\n'
  printf 'case "$*" in *"-L -f %%m"*|*"-L -c %%Y"*) : > "%s/reached"; sleep 60 ;; esac\n' "$FX"
  printf 'exec %s "$@"\n' "$(command -v stat)"
} > "$FX/bin/stat"
chmod +x "$FX/bin/stat"

AGENTS_ENV=(HMD_AGENT_TASKDIR="$FX/tasks" HMD_AGENT_PROJECTS_DIR="$FX/projects" HMD_AGENT_REAPED_FILE="$FX/reaped.json" HMD_AGENT_LIVE_SLUGS=x HMD_AGENT_NO_SWEEP=1)
workdirs() { ls -d "$TMPDIR"/hmd-agents.* 2>/dev/null | wc -l | tr -d ' '; }

parked_run() { # SIGNAL -- a count parked inside enumerate(), signalled as a process group, then what is left
  local sig="$1" pid wd i n
  rm -f "$FX/reached"
  # a plain command, not a shell function: $! must be the pid of the process that becomes the group leader (a function would run in a wrapper subshell, and the
  # group signalled below would be that wrapper's, not the count's -- the first version of this test signalled nothing and waited out the 60 s park)
  env "${AGENTS_ENV[@]}" PATH="$FX/bin:$PATH" perl -e 'setpgrp(0, 0); exec @ARGV' "$AGENTS" count >/dev/null 2>&1 </dev/null &
  pid=$!
  i=0; while [ ! -e "$FX/reached" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  if [ ! -e "$FX/reached" ]; then
    bad "$sig: the count never reached its batched lookup, so the park point was not exercised"
    kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0
  fi
  n="$(workdirs)"
  if [ "$n" = 0 ]; then ok "$sig: parked inside enumerate(), TMPDIR holds no work dir at all -- nothing a signal could strand"; else bad "$sig: parked inside enumerate(), TMPDIR holds $n work dir(s): $(ls -d "$TMPDIR"/hmd-agents.* | sed 's#.*/##' | paste -sd' ' -)"; fi
  perl -e 'sleep 30; kill "KILL", -$ARGV[0]' "$pid" &
  wd=$!
  kill -"$sig" -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  i=0; while kill -0 -- "-$pid" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  n="$(workdirs)"
  if [ "$n" = 0 ]; then ok "$sig to the process group while parked leaves nothing behind"; else bad "$sig left $n work dir(s) behind: $(ls -d "$TMPDIR"/hmd-agents.* | sed 's#.*/##' | paste -sd' ' -)"; fi
  rm -rf "$TMPDIR"/hmd-agents.* 2>/dev/null
}

echo "-- A/B. killed while enumerate() is parked in its batched lookup --"
parked_run TERM
parked_run HUP
parked_run KILL

echo "-- C. a normal count --"
OUT="$(env "${AGENTS_ENV[@]}" "$AGENTS" count 2>/dev/null)"
if printf '%s' "$OUT" | grep -Eq '^[0-9]+$'; then ok "a normal count still answers a number ($OUT)"; else bad "a normal count printed: '$OUT'"; fi
if [ "$(workdirs)" = 0 ]; then ok "a normal count leaves nothing behind"; else bad "a normal count left $(workdirs) work dir(s)"; fi

echo ""
echo "heimdall-agents-workdir: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]

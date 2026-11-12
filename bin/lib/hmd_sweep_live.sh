#!/usr/bin/env bash
# bin/lib/hmd_sweep_live.sh -- is a sweep (test/run-all.sh) running in THIS checkout right now? One definition, for every writer of tracked files.
#
# WHAT IT IS. One sourceable function, hmd_sweep_live <dir>: exit 0 and the sweep's pid on stdout when test/run-all.sh holds the sweep lock of the checkout <dir> is in, exit 1 for everything else.
#   bin/heimdall-checkpoint            `write` asks it first and, on a yes, writes nothing and exits 5
#   bin/heimdall-precompact-checkpoint says "checkpoint deferred" for that exit status, never "saved"
#
# WHY (2026-11-12). test/run-all.sh snapshots `git status` before its first suite and compares it after its last: a TRACKED file that changed in between is a TREE INTEGRITY VIOLATION and turns a 45-60
# minute run red. .planning/CHECKPOINT.md and .planning/settings.json are tracked here, and bin/heimdall-checkpoint rewrites them from the SessionEnd and PreCompact hooks of every session working in the
# repo: one of them landed mid-sweep. (The sweep's own session reaches it too: a sweep runs long enough for its context window to fill and PreCompact to fire.) A writer of tracked files asks this
# first and stays off the tree while the answer is yes. Skipping loses nothing for the checkpoint, which is derived afresh from git and the (untracked) notes store on every run.
#
# WHAT IT READS. The runner takes an flock on receipts/sweep.lock and writes pid=, repo= (git's toplevel) and started= into it; it blanks the file when it exits (test/run-all.sh, "ONE SWEEP AT A TIME").
# The file is found where the runner puts it, ${HEIMDALL_HOME:-<toplevel>/.heimdall}/receipts/sweep.lock, and read the way the sweep guard reads it (bin/lib/hmd_sweep_guard.py, running()): the pid is the
# first pid= line of digits, it must be above 1 (kill -0 0 signals the whole process group, and kill -0 1 is init: both answer alive) and it must answer kill -0. A process of another user, which kill -0
# refuses with EPERM, still counts: ps -p finds it. The lock must also name THIS checkout in repo=: HEIMDALL_HOME is often shared by every repo of the machine, and the sweep's own suites run the writers
# in throwaway repos under that same environment, which a sweep of another checkout must never defer.
#
# FAILS OPEN. A cost guard, not a security gate (the sweep guard's and the CI waste guard's convention): no git, no lock, a link, a FIFO or a directory where the lock should be, no usable pid, no repo=, a
# pid that is gone: each is "no sweep", i.e. the caller does what it did before. The lock is read only when it is a plain file (head on a FIFO a cloned repo planted would block) and never through a link.
# The one false yes is a pid recycled after a sweep was killed (the sweep guard accepts it too): it costs a skipped write, never a wrong one, and the next sweep blanks the note.
#
# Every name here starts hmd_sweep_live, so sourcing it into a hook cannot collide with the hook's own. Bash 3.2 compatible (macOS /bin/bash) and nounset-safe.

hmd_sweep_live() { # <dir> -> the sweep's pid on stdout and exit 0; exit 1 when there is none
  local top lock text pid repo
  top="$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null)" || return 1
  lock="${HEIMDALL_HOME:-$top/.heimdall}/receipts/sweep.lock"
  { [ -f "$lock" ] && [ ! -L "$lock" ]; } || return 1
  text="$(head -c 4096 "$lock" 2>/dev/null)" || return 1
  pid="$(printf '%s\n' "$text" | sed -n 's/^pid=\([0-9]\{1,9\}\)[[:space:]]*$/\1/p' | head -n 1)"
  repo="$(printf '%s\n' "$text" | sed -n 's/^repo=//p' | head -n 1)"
  { [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$repo" = "$top" ]; } || return 1
  kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1 || return 1
  printf '%s' "$pid"
}

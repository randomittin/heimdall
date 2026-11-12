#!/usr/bin/env bash
# checkpoint-defers-during-sweep.test.sh -- while a sweep grades the working tree, the checkpoint writer touches nothing in it.
#
# THE BUG (2026-11-12): a full sweep (test/run-all.sh) went red with TREE INTEGRITY VIOLATION -- .planning/CHECKPOINT.md and
# .planning/settings.json, both TRACKED, changed mid-run. The writer was bin/heimdall-checkpoint, run by the SessionEnd / PreCompact
# hook of another Claude session in the same repo: it rewrites the auto-checkpoint block and sets auto_checkpoint_at. The sweep's own
# session reaches it too -- a sweep runs for most of an hour, long enough for its context window to fill and PreCompact to fire.
#
# THE FIX under test: `heimdall-checkpoint write` first asks hmd_sweep_live (bin/lib/hmd_sweep_live.sh) whether test/run-all.sh holds
# THIS checkout's sweep lock (receipts/sweep.lock: pid, repo, start time, written by the runner and blanked when it ends). If so it
# writes NOTHING -- not CHECKPOINT.md, not settings.json, not the answer key, not the shared ledger record -- says so in one stderr
# line and exits 5. It SKIPS rather than parking its content in a side file: the block is derived afresh from git and the notes store
# on every run, and the notes live in the untracked .heimdall/, so the first write after the sweep saves what a deferred one would
# have. Anything it cannot read as a live sweep of this checkout is no sweep (fails open): the old behaviour, a write.
#
#   A. THE PREDICATE   hmd_sweep_live: a live pid in this checkout's lock is a sweep; a dead pid, a blank or garbled lock, pid 0 or 1,
#                      no repo=, another checkout's repo=, no lock, a lock that is a link / a FIFO / a directory, no git: none
#   B. LIVE SWEEP      the writer: rc 5, both tracked files byte-identical, git status clean, one stderr line naming the pid, stdout
#                      empty, nothing derived at all; `note` still records (the store is untracked)
#   C. HEIMDALL_HOME   the lock is found where the runner puts it
#   D. PRECOMPACT      the real hook says "deferred", never "saved", still exits 0 with an empty stdout, keeps its note
#   E. THE SWEEP ENDS  blank lock, the same call saves, and the note recorded mid-sweep is in the checkpoint (nothing was lost)
#   F. THE LATE LOOK   a sweep that starts AFTER the writer's first look and before its first write (the derivation takes seconds)
#                      is still honoured: rc 5, nothing written
#
# A write takes about 2 s, so the three that must complete (E, D's second run, F) run side by side. Hermetic: every project is a
# throwaway git repo under a scratch dir, the cwd is a scratch dir (no $PWD fallback reaches the real repo), HEIMDALL_HOME is unset
# except where set inline.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CKPT="$REPO/bin/heimdall-checkpoint"
PRECOMPACT="$REPO/bin/heimdall-precompact-checkpoint"
MARK="heimdall-auto-checkpoint:begin"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

unset HEIMDALL_HOME CLAUDE_PROJECT_DIR
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
cd "$TMPROOT" || exit 1

LIVE=$$                                    # this script: alive for the whole run, as a sweep is
true & DEAD=$!; wait "$DEAD" 2>/dev/null   # a pid that has exited and been reaped

# shellcheck source=../bin/lib/hmd_sweep_live.sh
. "$REPO/bin/lib/hmd_sweep_live.sh"

# A throwaway git project whose CHECKPOINT.md and settings.json are TRACKED, as in this repo. Prints git's toplevel -- the path
# test/run-all.sh records as repo= in its lock. The sweep's runtime dir is ignored; RESUME-KEY.json and the ledger are NOT, so a
# clean `git status` also proves neither was written.
make_project() { # <name>
  local d="$TMPROOT/$1"
  mkdir -p "$d/.planning"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf '.heimdall/\n' > "$d/.gitignore"
  printf 'hello\n' > "$d/README.md"
  printf '# Checkpoint\n\nhand-written handoff\n' > "$d/.planning/CHECKPOINT.md"
  printf '{"phase": "old"}\n' > "$d/.planning/settings.json"
  git -C "$d" add .gitignore README.md .planning/CHECKPOINT.md .planning/settings.json
  git -C "$d" commit -qm "initial commit" --no-verify
  git -C "$d" rev-parse --show-toplevel
}

# The note test/run-all.sh leaves in <home>/receipts/sweep.lock while it holds the lock, and what its EXIT trap leaves after.
set_lock() { # <home> <pid> <repo>
  mkdir -p "$1/receipts"
  printf 'pid=%s\nrepo=%s\nstarted=2026-11-12T00:00:00+0000\n' "$2" "$3" > "$1/receipts/sweep.lock"
}
set_lock_text() { mkdir -p "$1/receipts"; rm -rf "$1/receipts/sweep.lock"; printf '%s' "$2" > "$1/receipts/sweep.lock"; } # <home> <text>
end_sweep() { : > "$1/receipts/sweep.lock"; }

tracked_digest() { shasum -a 256 "$1/.planning/CHECKPOINT.md" "$1/.planning/settings.json" | awk '{print $1}' | tr '\n' ' '; }
status_of() { git -C "$1" status --porcelain | head -3 | tr '\n' ' '; }

payload() { printf '{"session_id":"sess-sweep","transcript_path":"/nonexistent/t.jsonl","cwd":"%s","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null}' "$1"; }
run_precompact() { payload "$1" | env HMD_PRECOMPACT_BUDGET=60 "$PRECOMPACT" --repo "$1"; }

# A stand-in for heimdall-state, which the writer asks for the goal as the FIRST thing it measures. It records that it was asked, and
# can start a "sweep" in the project at that moment: the lock then appears after the writer's first look and before its first write.
SHIM="$TMPROOT/shim"
mkdir -p "$SHIM"
cat > "$SHIM/heimdall-state" <<'SHIMEOF'
#!/bin/sh
[ -z "${SHIM_CALLED:-}" ] || : > "$SHIM_CALLED"
[ -z "${SHIM_LOCK_HOME:-}" ] || { mkdir -p "$SHIM_LOCK_HOME/receipts" && printf 'pid=%s\nrepo=%s\nstarted=x\n' "$SHIM_PID" "$SHIM_REPO" > "$SHIM_LOCK_HOME/receipts/sweep.lock"; }
echo none
SHIMEOF
chmod +x "$SHIM/heimdall-state"

# In the background; the exit status, stdout and stderr land in $TMPROOT/<name>.{rc,out,err}.
launch() { # <name> <command...>
  local name="$1"; shift
  ( "$@" >"$TMPROOT/$name.out" 2>"$TMPROOT/$name.err"; printf '%s' "$?" >"$TMPROOT/$name.rc" ) &
}
rc_of() { cat "$TMPROOT/$1.rc" 2>/dev/null || printf 'none'; }

# ─────────────────────────────────────────────────────────────────────────────
echo "A. THE PREDICATE -- hmd_sweep_live says yes only for a live sweep of THIS checkout"
PU="$(make_project unit)"
HU="$PU/.heimdall"
expect_live() { # <dir> <pid> <what>
  local got rc
  got="$(hmd_sweep_live "$1" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$got" = "$2" ]; then ok "$3"; else bad "$3 (rc=$rc, pid '$got', wanted $2)"; fi
}
expect_none() { # <dir> <what>
  local got rc
  got="$(hmd_sweep_live "$1" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$got" ]; then ok "$2"; else bad "$2 (rc=$rc, pid '$got')"; fi
}
set_lock "$HU" "$LIVE" "$PU";                         expect_live "$PU" "$LIVE" "a live pid and this checkout's repo=: a sweep, and its pid is printed"
set_lock "$HU" "$DEAD" "$PU";                         expect_none "$PU" "a pid that has exited (a sweep killed without a trace)"
end_sweep "$HU";                                      expect_none "$PU" "a blank lock (what the runner leaves when it ends)"
set_lock_text "$HU" $'garbage\npid=abc\n';            expect_none "$PU" "a lock with no usable pid"
set_lock "$HU" 0 "$PU";                               expect_none "$PU" "pid 0 (kill -0 0 signals the whole process group and answers alive)"
set_lock "$HU" 1 "$PU";                               expect_none "$PU" "pid 1 (init answers kill -0 whoever asks)"
set_lock_text "$HU" "pid=$LIVE"$'\n';                 expect_none "$PU" "a live pid with no repo= line (cannot be tied to this checkout)"
set_lock "$HU" "$LIVE" "$TMPROOT/some-other-checkout"; expect_none "$PU" "a live sweep of ANOTHER checkout"
HX="$TMPROOT/hh-unit"
set_lock "$HU" "$DEAD" "$PU"
set_lock "$HX" "$LIVE" "$PU"
got="$(HEIMDALL_HOME="$HX" hmd_sweep_live "$PU" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$got" = "$LIVE" ]; } && ok "HEIMDALL_HOME relocates the lock: it is read there, not under the checkout" || bad "HEIMDALL_HOME lock not read (rc=$rc, pid '$got')"
set_lock "$HX" "$LIVE" "$TMPROOT/some-other-checkout"
got="$(HEIMDALL_HOME="$HX" hmd_sweep_live "$PU" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$got" ]; } && ok "a shared HEIMDALL_HOME holding another checkout's live sweep is none of this one's" || bad "another checkout's sweep counted (rc=$rc, pid '$got')"
rm -rf "$HU/receipts/sweep.lock";                     expect_none "$PU" "no lock file"
mkdir "$HU/receipts/sweep.lock";                      expect_none "$PU" "a directory where the lock should be"
rm -rf "$HU/receipts/sweep.lock"
set_lock "$TMPROOT/elsewhere" "$LIVE" "$PU"
ln -s "$TMPROOT/elsewhere/receipts/sweep.lock" "$HU/receipts/sweep.lock"; expect_none "$PU" "a symlink to a live lock (never read through a link)"
rm -f "$HU/receipts/sweep.lock"
mkfifo "$HU/receipts/sweep.lock"
perl -e 'alarm 10; exec @ARGV' bash -c '. "$1"; hmd_sweep_live "$2"' _ "$REPO/bin/lib/hmd_sweep_live.sh" "$PU" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "a FIFO where the lock should be answers none and does not hang" || bad "a FIFO lock: rc=$rc (142 = it hung until the alarm)"
rm -f "$HU/receipts/sweep.lock"
mkdir -p "$TMPROOT/notgit"
expect_none "$TMPROOT/notgit" "a directory that is no git checkout"
ROOTPID="$(ps -axo pid=,user= 2>/dev/null | awk '$2 == "root" && $1 > 1 { print $1; exit }')"
if [ "$(id -u)" != "0" ] && [ -n "$ROOTPID" ]; then
  set_lock "$HU" "$ROOTPID" "$PU";                    expect_live "$PU" "$ROOTPID" "another user's live process (kill -0 says EPERM; ps -p finds it)"
else
  echo "  skip another user's process: no root-owned pid to name, or this runs as root"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "B. LIVE SWEEP -- the lock names a live pid of THIS checkout: the writer writes nothing"
P1="$(make_project live)"
set_lock "$P1/.heimdall" "$LIVE" "$P1"
T1="$(tracked_digest "$P1")"
env SHIM_CALLED="$TMPROOT/called-live" PATH="$SHIM:$PATH" "$CKPT" write "$P1" >"$TMPROOT/out1" 2>"$TMPROOT/err1"; RC1=$?
[ "$RC1" -eq 5 ] && ok "write exits 5 (DEFERRED: 0 would read as saved, 3 as incomplete, 4 as refused)" || bad "write exited $RC1 (want 5)"
[ "$(tracked_digest "$P1")" = "$T1" ] && ok "CHECKPOINT.md and settings.json are byte-identical" || bad "a tracked file CHANGED under a live sweep"
[ -z "$(git -C "$P1" status --porcelain)" ] && ok "git status is clean: no tracked change, no answer key, no ledger record" || bad "the work tree changed: $(status_of "$P1")"
[ ! -e "$TMPROOT/called-live" ] && ok "nothing was derived: the writer stopped before it measured anything" || bad "the writer measured the tree (asked heimdall-state for the goal) before deferring"
[ ! -s "$TMPROOT/out1" ] && ok "stdout is empty: it never claims a save" || bad "stdout was not empty: $(head -c 200 "$TMPROOT/out1")"
if [ "$(wc -l < "$TMPROOT/err1" | tr -d ' ')" -eq 1 ] && grep -q "DEFERRED" "$TMPROOT/err1" && grep -q "pid $LIVE" "$TMPROOT/err1"; then
  ok "one stderr line says DEFERRED and names the sweep's pid"
else
  bad "stderr is not one DEFERRED line naming pid $LIVE: $(head -c 300 "$TMPROOT/err1")"
fi
( cd "$P1" && "$CKPT" note in-progress "mid-sweep: half the parser is written" ) >/dev/null 2>&1; NRC=$?
if [ "$NRC" -eq 0 ] && grep -q "half the parser" "$P1/.heimdall/resume-notes.ndjson" 2>/dev/null && [ -z "$(git -C "$P1" status --porcelain)" ]; then
  ok "note still records during the sweep (the store is the untracked .heimdall/)"
else
  bad "note during a sweep: rc=$NRC, status: $(status_of "$P1")"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "C. HEIMDALL_HOME -- the lock is where the runner puts it"
P2="$(make_project home)"
HH="$TMPROOT/hh-live"
set_lock "$HH" "$LIVE" "$P2"
T2="$(tracked_digest "$P2")"
env HEIMDALL_HOME="$HH" "$CKPT" write "$P2" >/dev/null 2>"$TMPROOT/err2"; RC2=$?
if [ "$RC2" -eq 5 ] && [ "$(tracked_digest "$P2")" = "$T2" ] && [ -z "$(git -C "$P2" status --porcelain)" ]; then
  ok "a lock under HEIMDALL_HOME naming this checkout defers the write (rc 5, nothing changed)"
else
  bad "HEIMDALL_HOME lock: rc=$RC2, status: $(status_of "$P2")"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "D. PRECOMPACT -- the real hook says deferred, never saved, and still cannot hurt compaction"
P3="$(make_project precompact)"
set_lock "$P3/.heimdall" "$LIVE" "$P3"
T3="$(tracked_digest "$P3")"
run_precompact "$P3" >"$TMPROOT/out3" 2>"$TMPROOT/err3"; RC3=$?
[ "$RC3" -eq 0 ] && [ ! -s "$TMPROOT/out3" ] && ok "exit 0 and an empty stdout (a PreCompact hook fails open, always)" || bad "rc=$RC3, stdout: $(head -c 200 "$TMPROOT/out3")"
if grep -q "checkpoint deferred" "$TMPROOT/err3" && ! grep -q "checkpoint saved" "$TMPROOT/err3"; then
  ok "stderr says the checkpoint was deferred, never saved"
else
  bad "stderr: $(head -c 300 "$TMPROOT/err3")"
fi
{ [ "$(tracked_digest "$P3")" = "$T3" ] && [ -z "$(git -C "$P3" status --porcelain)" ]; } && ok "no tracked file touched, nothing new in the tree" || bad "the hook changed the tree: $(status_of "$P3")"
grep -q "compaction (auto)" "$P3/.heimdall/resume-notes.ndjson" 2>/dev/null && ok "the compaction note is still recorded for the next write" || bad "the compaction note was lost"

# ─────────────────────────────────────────────────────────────────────────────
# From here the writes COMPLETE, so they run side by side (about 2 s each alone).
end_sweep "$P1/.heimdall"                                    # E: the sweep of B ends
end_sweep "$P3/.heimdall"                                    # E: the sweep of D ends
P6="$(make_project late)"
T6="$(tracked_digest "$P6")"
launch after "$CKPT" write "$P1"
launch pc    run_precompact "$P3"
launch late  env SHIM_CALLED="$TMPROOT/called-late" SHIM_LOCK_HOME="$P6/.heimdall" SHIM_PID="$LIVE" SHIM_REPO="$P6" PATH="$SHIM:$PATH" "$CKPT" write "$P6"
wait

echo "E. THE SWEEP ENDS -- the same call saves, and nothing recorded meanwhile was lost"
[ "$(rc_of after)" = "0" ] && ok "write exits 0 once the lock is blank" || bad "write exited $(rc_of after) (want 0): $(head -c 300 "$TMPROOT/after.err")"
if [ "$(tracked_digest "$P1")" != "$T1" ] && grep -q "$MARK" "$P1/.planning/CHECKPOINT.md" && grep -q "auto_checkpoint_at" "$P1/.planning/settings.json"; then
  ok "CHECKPOINT.md carries the auto block and settings.json has auto_checkpoint_at"
else
  bad "the post-sweep write did not land in the tracked files"
fi
grep -q "half the parser" "$P1/.planning/CHECKPOINT.md" && ok "the note recorded mid-sweep is in the checkpoint" || bad "the mid-sweep note did not reach the checkpoint"
if [ "$(rc_of pc)" = "0" ] && grep -q "checkpoint saved" "$TMPROOT/pc.err" && grep -q "compaction (auto)" "$P3/.planning/CHECKPOINT.md"; then
  ok "the PreCompact hook saves again, and the checkpoint records the compaction"
else
  bad "PreCompact after the sweep: rc=$(rc_of pc), stderr: $(head -c 300 "$TMPROOT/pc.err")"
fi

echo "F. THE LATE LOOK -- a sweep that starts mid-derivation is still honoured"
if [ "$(rc_of late)" = "5" ] && [ -e "$TMPROOT/called-late" ] && [ "$(tracked_digest "$P6")" = "$T6" ] && [ -z "$(git -C "$P6" status --porcelain)" ]; then
  ok "lock created after the first look (the writer had begun to measure), before the first write: rc 5, nothing written"
else
  bad "late lock: rc=$(rc_of late), measured=$([ -e "$TMPROOT/called-late" ] && echo yes || echo no), status: $(status_of "$P6"), stderr: $(head -c 300 "$TMPROOT/late.err")"
fi

echo ""
echo "checkpoint-defers-during-sweep.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

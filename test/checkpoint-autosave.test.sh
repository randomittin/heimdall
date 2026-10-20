#!/usr/bin/env bash
# checkpoint-autosave.test.sh — acceptance for AUTOMATIC .planning checkpointing.
#
# THE BUG this guards against: Heimdall was supposed to auto-save forward session
# state to .planning/ (CHECKPOINT.md / STATE.md / settings.json) on its own, but it
# never fired — RJ had to run /hmd:save by hand. Root cause: /hmd:save is an LLM
# PROMPT (commands/save.md), not a script, and the SessionEnd hook only did a git
# COMMIT labelled "session-end checkpoint" — it never WROTE the .planning state
# files (which are gitignored anyway). Nothing mechanically wrote CHECKPOINT.md.
#
# This proves the mechanical auto-checkpoint writer (bin/heimdall-checkpoint) and,
# crucially, that it is WIRED into the real SessionEnd hook so it fires on its own:
#
#   A. WRITER CREATES IT     — `heimdall-checkpoint write <dir>` creates
#      .planning/CHECKPOINT.md with mechanical forward state (HEAD sha + marker).
#   B. IDEMPOTENT + UPDATES  — a second run advances mtime and leaves exactly one
#      auto block (no duplication) — "update", not "append forever".
#   C. NON-DESTRUCTIVE       — a manual (LLM-authored) CHECKPOINT.md with no auto
#      marker is PRESERVED; the auto block is added around it, never clobbering it.
#   D. WIRED @ SessionEnd    — extracting the ACTUAL SessionEnd hook command from
#      hooks/hooks.json and running it in a temp project auto-writes CHECKPOINT.md.
#      This is the falsifier: RED before the wiring (no CHECKPOINT.md), GREEN after.
#   E. NON-FATAL + AUTOCOMMIT-INDEPENDENT — the hook exits 0, and checkpointing
#      fires EVEN with .heimdall-no-autocommit present (state save != git commit).
#   F. DETACHED              — the hook returns in < 2s even when the checkpoint
#      writer takes 4s (a fake plugin root), and the write still lands afterwards.
#      RED if the write sits in the foreground: Claude Code cancels a SessionEnd
#      hook that outlives its budget ("SessionEnd hook [...] failed: Hook cancelled").
#      D and E poll for the file for the same reason: the write lands after the
#      hook has returned.
#   G. LINK-SAFE LOG         — the detached worker logs its cut-short/failed notices to
#      .heimdall/logs/session-end.log, a path a cloned repo controls. A .heimdall, .heimdall/logs
#      or session-end.log that is a symlink (a dangling one too) or a FIFO is skipped, never written
#      through: the link's target stays byte-for-byte unchanged. RED before the guard (the notice
#      lands in the target); a clean-repo control proves the notice is still logged when the path is real.
#   H. LINK-SAFE WRITES      — the WRITER itself never writes through, or over, a link a cloned repo planted. A
#      .planning, .planning/ledger, CHECKPOINT.md, RESUME-KEY.json or settings.json that is a symlink (a dangling
#      one too) or a FIFO is REFUSED: the save is skipped, one stderr line says why, rc 0 (fail open), the link's
#      target is unchanged, the link itself is left alone and nothing is written beside it. RED before the guard;
#      a clean-repo control proves the same writer still writes everything when the paths are real.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CKPT="$REPO/bin/heimdall-checkpoint"
HOOKS="$REPO/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

MARK="heimdall-auto-checkpoint:begin"

# A fresh throwaway git project with a .planning dir.
make_project() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'hello\n' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm "initial commit" --no-verify
  mkdir -p "$d/.planning"
  printf '%s' "$d"
}

mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# The SessionEnd hook DETACHES the checkpoint write (hooks.json: nohup + setsid), so the file
# lands after the hook has returned: poll for it, bounded at 15s.
wait_for() { local f="$1" i=0; while [ ! -f "$f" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done; [ -f "$f" ]; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000'; }

# ─────────────────────────────────────────────────────────────────────────────
echo "A. WRITER CREATES .planning/CHECKPOINT.md with mechanical state:"
P="$(make_project)"
"$CKPT" write "$P" >/dev/null 2>&1
CK="$P/.planning/CHECKPOINT.md"
[ -f "$CK" ] && ok "CHECKPOINT.md created by the writer" || bad "CHECKPOINT.md NOT created"
grep -q "$MARK" "$CK" 2>/dev/null && ok "auto-checkpoint marker present" || bad "auto marker missing"
HEAD_SHA="$(git -C "$P" rev-parse --short HEAD)"
grep -q "$HEAD_SHA" "$CK" 2>/dev/null && ok "HEAD sha ($HEAD_SHA) captured in checkpoint" || bad "HEAD sha not captured"
grep -q "initial commit" "$CK" 2>/dev/null && ok "recent commit subject captured" || bad "recent commits not captured"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "B. IDEMPOTENT — a second run updates (mtime advances) with ONE auto block:"
P="$(make_project)"
"$CKPT" write "$P" >/dev/null 2>&1
CK="$P/.planning/CHECKPOINT.md"
M1="$(mtime_of "$CK")"
sleep 1
"$CKPT" write "$P" >/dev/null 2>&1
M2="$(mtime_of "$CK")"
[ "$M2" -gt "$M1" ] && ok "mtime advanced on re-run ($M1 -> $M2)" || bad "mtime did not advance ($M1 -> $M2)"
N="$(grep -cF "$MARK" "$CK" 2>/dev/null; true)"; N="${N:-0}"
[ "$N" -eq 1 ] && ok "exactly one auto block after two runs (no duplication)" || bad "auto block count=$N (want 1)"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "C. NON-DESTRUCTIVE — a manual /hmd:save checkpoint is preserved:"
P="$(make_project)"
CK="$P/.planning/CHECKPOINT.md"
SENTINEL="MANUAL-LLM-HANDOFF-do-not-clobber-42"
printf '# Checkpoint — manual\n\n%s\n' "$SENTINEL" > "$CK"
"$CKPT" write "$P" >/dev/null 2>&1
grep -q "$SENTINEL" "$CK" 2>/dev/null && ok "manual handoff content preserved" || bad "manual content CLOBBERED"
grep -q "$MARK" "$CK" 2>/dev/null && ok "auto block added alongside manual content" || bad "auto block not added"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "D. WIRED — the ACTUAL SessionEnd hook command auto-writes CHECKPOINT.md:"
CMD="$(jq -r '[.hooks.SessionEnd[].hooks[].command | select(test("heimdall-checkpoint"))][0]' "$HOOKS" 2>/dev/null)"
[ -n "$CMD" ] && [ "$CMD" != "null" ] && ok "extracted SessionEnd hook command from hooks.json" || bad "could not read SessionEnd command"
P="$(make_project)"
( cd "$P" && CLAUDE_PLUGIN_ROOT="$REPO" PATH="$REPO/bin:$PATH" bash -c "$CMD" ) >/dev/null 2>&1
RC=$?
CK="$P/.planning/CHECKPOINT.md"
wait_for "$CK"
[ -f "$CK" ] && ok "SessionEnd hook auto-created CHECKPOINT.md (no manual /hmd:save)" || bad "SessionEnd hook did NOT write CHECKPOINT.md"
grep -q "$MARK" "$CK" 2>/dev/null && ok "auto marker written via the wired hook" || bad "no auto marker via hook"
[ "$RC" -eq 0 ] && ok "SessionEnd hook exited 0 (non-fatal)" || bad "SessionEnd hook exited $RC (want 0)"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "E. AUTOCOMMIT-INDEPENDENT — checkpoint fires even with autocommit OFF:"
P="$(make_project)"
touch "$P/.heimdall-no-autocommit"
( cd "$P" && CLAUDE_PLUGIN_ROOT="$REPO" PATH="$REPO/bin:$PATH" bash -c "$CMD" ) >/dev/null 2>&1
CK="$P/.planning/CHECKPOINT.md"
wait_for "$CK"
[ -f "$CK" ] && ok "checkpoint written despite .heimdall-no-autocommit" || bad "no-autocommit suppressed the checkpoint"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "F. DETACHED — the hook returns fast even when the writer is slow, and the write still lands:"
# A fake plugin root whose writer sleeps 4s: were the write in the foreground, the hook could not
# return in under 2s (Claude Code's default SessionEnd budget is 1.5s).
FAKE="$(mktemp -d)"
mkdir -p "$FAKE/bin"
printf '#!/bin/sh\nsleep 4\nmkdir -p "$2/.planning" && printf "detached-write\\n" > "$2/.planning/CHECKPOINT.md"\n' > "$FAKE/bin/heimdall-checkpoint"
chmod +x "$FAKE/bin/heimdall-checkpoint"
P="$(make_project)"
T0="$(now_ms)"
( cd "$P" && CLAUDE_PLUGIN_ROOT="$FAKE" bash -c "$CMD" </dev/null ) >/dev/null 2>&1
RC=$?
FG=$(( $(now_ms) - T0 ))
CK="$P/.planning/CHECKPOINT.md"
{ [ "$RC" -eq 0 ] && [ "$FG" -lt 2000 ]; } \
  && ok "hook returned rc 0 in ${FG}ms (< 2000ms) while the writer was still sleeping" \
  || bad "hook took ${FG}ms, rc=$RC (want rc 0 in < 2000ms): the checkpoint write is in the foreground"
[ ! -f "$CK" ] && ok "checkpoint not written yet at return: the write is detached" || bad "checkpoint already present at return: the write ran in the foreground"
wait_for "$CK" && grep -q detached-write "$CK" \
  && ok "detached writer completed after the hook returned (CHECKPOINT.md written)" \
  || bad "detached writer never wrote CHECKPOINT.md"
rm -rf "$P" "$FAKE"

# ─────────────────────────────────────────────────────────────────────────────
echo "G. LINK-SAFE LOG — the worker's notice log never writes through a link a cloned repo planted:"
# The cut-short/failed notices go to .heimdall/logs/session-end.log, and a repository controls every
# component of that path: .heimdall, .heimdall/logs and session-end.log can each be a symlink to anywhere
# the user can write (a dangling one is CREATED through by >>), or a FIFO that hangs the open.
# Each case runs the real hook against a fake plugin root whose checkpoint writer FAILS (so the worker
# logs "checkpoint write failed") and whose summary-card -- the worker's step after both notice sites --
# drops a marker: "the target is unchanged" is judged only once the worker has had its chance to write.
HOOK_RC=0
run_failing_worker() {
  local p="$1" fake marker finished
  fake="$(mktemp -d)"; marker="$fake/worker-done"
  mkdir -p "$fake/bin"
  printf '#!/bin/sh\nexit 3\n' > "$fake/bin/heimdall-checkpoint"
  printf '#!/bin/sh\n: > "%s"\n' "$marker" > "$fake/bin/summary-card"
  chmod +x "$fake/bin/heimdall-checkpoint" "$fake/bin/summary-card"
  ( cd "$p" && CLAUDE_PLUGIN_ROOT="$fake" bash -c "$CMD" </dev/null ) >/dev/null 2>&1
  HOOK_RC=$?
  wait_for "$marker"; finished=$?
  rm -rf "$fake"
  [ "$finished" -eq 0 ] && [ "$HOOK_RC" -eq 0 ]
}

echo "  G0. control — a clean repo's notice IS logged (the link cases below judge a worker that reached the log):"
P="$(make_project)"
run_failing_worker "$P" || bad "G0: hook rc=$HOOK_RC, or the detached worker never reached its last step"
grep -q "checkpoint write failed (rc=3)" "$P/.heimdall/logs/session-end.log" 2>/dev/null \
  && ok "notice written to .heimdall/logs/session-end.log in a clean repo" \
  || bad "no notice in a clean repo's .heimdall/logs/session-end.log (control broken: the cases below prove nothing)"
rm -rf "$P"

echo "  G1. .heimdall/logs is a symlink to a directory holding a session-end.log:"
P="$(make_project)"; T="$(mktemp -d)"
mkdir -p "$P/.heimdall"; printf 'precious\n' > "$T/session-end.log"; ln -s "$T" "$P/.heimdall/logs"
run_failing_worker "$P" || bad "G1: hook rc=$HOOK_RC, or the detached worker never reached its last step"
{ [ "$(cat "$T/session-end.log")" = "precious" ] && [ "$(ls -A "$T")" = "session-end.log" ]; } \
  && ok "the target of the .heimdall/logs link is unchanged and nothing was added beside it" \
  || bad "the notice was written THROUGH the .heimdall/logs link"
rm -rf "$P" "$T"

echo "  G2. .heimdall is a symlink to a directory holding logs/session-end.log:"
P="$(make_project)"; T="$(mktemp -d)"
mkdir -p "$T/logs"; printf 'precious\n' > "$T/logs/session-end.log"; ln -s "$T" "$P/.heimdall"
run_failing_worker "$P" || bad "G2: hook rc=$HOOK_RC, or the detached worker never reached its last step"
{ [ "$(cat "$T/logs/session-end.log")" = "precious" ] && [ "$(ls -A "$T")" = "logs" ] && [ "$(ls -A "$T/logs")" = "session-end.log" ]; } \
  && ok "the target of the .heimdall link is unchanged and nothing was created in it" \
  || bad "the notice (or its directory) was written THROUGH the .heimdall link"
rm -rf "$P" "$T"

echo "  G3. session-end.log is a symlink to an existing file:"
P="$(make_project)"; T="$(mktemp -d)"
mkdir -p "$P/.heimdall/logs"; printf 'precious\n' > "$T/target.txt"; ln -s "$T/target.txt" "$P/.heimdall/logs/session-end.log"
run_failing_worker "$P" || bad "G3: hook rc=$HOOK_RC, or the detached worker never reached its last step"
[ "$(cat "$T/target.txt")" = "precious" ] \
  && ok "the file the session-end.log link points at is unchanged" \
  || bad "the notice was appended THROUGH the session-end.log link"
rm -rf "$P" "$T"

echo "  G4. session-end.log is a DANGLING symlink (>> would create its target):"
P="$(make_project)"; T="$(mktemp -d)"
mkdir -p "$P/.heimdall/logs"; ln -s "$T/created-through-link" "$P/.heimdall/logs/session-end.log"
run_failing_worker "$P" || bad "G4: hook rc=$HOOK_RC, or the detached worker never reached its last step"
[ ! -e "$T/created-through-link" ] \
  && ok "the dangling link's target was not created" \
  || bad "the dangling session-end.log link was CREATED THROUGH"
rm -rf "$P" "$T"

echo "  G5. session-end.log is a FIFO (not a regular file):"
P="$(make_project)"
mkdir -p "$P/.heimdall/logs"; mkfifo "$P/.heimdall/logs/session-end.log"
exec 3<>"$P/.heimdall/logs/session-end.log"   # the test holds the FIFO open, so a stray open cannot hang the worker
run_failing_worker "$P" || bad "G5: hook rc=$HOOK_RC, or the detached worker never reached its last step"
LEAK="$(perl -e 'use Fcntl; fcntl(STDIN, F_SETFL, O_NONBLOCK); sysread(STDIN, $b, 4096); print $b' <&3)"
exec 3<&-
[ -z "$LEAK" ] \
  && ok "nothing was written to the FIFO" \
  || bad "a notice was written to the FIFO: $LEAK"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "H. LINK-SAFE WRITES — the writer never writes through, or over, a link a cloned repo planted:"
# bin/heimdall-checkpoint write runs unattended (the SessionEnd worker, the PreCompact hook) in whatever
# repository the session is in, and a repository controls every name below its root: .planning, .planning/ledger
# and each file the writer puts there can be a symlink to anywhere the user can write (a dangling one is created
# through), or a FIFO. The writer must REFUSE: skip the save, say so ONCE on stderr, exit 0 (fail open), leave the
# link's target unchanged AND the link itself alone, and write nothing beside it. H0 is the control: the same
# writer in a repo whose paths are real writes everything, so the refusals are judged against a writer that works.
# The writer runs with a throwaway HOME (its team-record step honours ~/.heimdall/presence-off, and a developer's
# own opt-out marker would turn H0 and H6 into proofs of nothing) and LC_ALL=C (no perl locale warning on stderr).
H_ERR=""; H_RC=0
run_writer() { # <project> [VAR=value ...]: stderr -> H_ERR, exit status -> H_RC
  local home p="$1"; shift
  home="$(mktemp -d)"
  H_ERR="$(cd "$p" && env -u HEIMDALL_PLANNING_DIR -u HEIMDALL_PRESENCE_DIR HOME="$home" LC_ALL=C "$@" \
    perl -e 'alarm 60; exec @ARGV' "$CKPT" write "$p" 2>&1 >/dev/null)"
  H_RC=$?
  rm -rf "$home"
}
said_once() { # <phrase>: stderr held ONE line and it says <phrase>
  [ "$(printf '%s\n' "$H_ERR" | grep -c .)" -eq 1 ] && printf '%s\n' "$H_ERR" | grep -q -- "$1"
}
holds_only() { # <dir> <name>: nothing was created beside <name>
  [ "$(ls -A "$1")" = "$2" ]
}

echo "  H0. control — a repo with real paths is written in full:"
P="$(make_project)"
run_writer "$P"
{ [ "$H_RC" -eq 0 ] && [ -f "$P/.planning/CHECKPOINT.md" ] && [ -f "$P/.planning/RESUME-KEY.json" ] && [ -f "$P/.planning/settings.json" ]; } \
  && ok "CHECKPOINT.md, RESUME-KEY.json and settings.json written, rc 0" \
  || bad "a clean repo was not written in full (rc=$H_RC): the refusals below prove nothing"
ls "$P/.planning/ledger/checkpoints/"*.json >/dev/null 2>&1 \
  && ok "the team record was published under .planning/ledger/checkpoints" \
  || bad "no team record in a clean repo: H6 proves nothing"
rm -rf "$P"

echo "  H1. .planning is a symlink to a directory:"
P="$(make_project)"; T="$(mktemp -d)"
rmdir "$P/.planning"; printf 'precious\n' > "$T/CHECKPOINT.md"; ln -s "$T" "$P/.planning"
run_writer "$P"
{ [ "$H_RC" -eq 0 ] && [ "$(cat "$T/CHECKPOINT.md")" = "precious" ] && holds_only "$T" CHECKPOINT.md; } \
  && ok "rc 0, the target of the .planning link is unchanged and nothing was created in it" \
  || bad "the checkpoint was written THROUGH the .planning link (rc=$H_RC): $(ls -A "$T" | tr '\n' ' ')"
{ [ -L "$P/.planning" ] && [ "$(readlink "$P/.planning")" = "$T" ]; } \
  && ok "the .planning link itself is left alone" || bad "the .planning link was replaced"
said_once "\.planning is a symbolic link" \
  && ok "one stderr line says why" || bad "stderr should be ONE line naming the link (got: $H_ERR)"
rm -rf "$P" "$T"

echo "  H2. CHECKPOINT.md is a symlink to an existing file:"
P="$(make_project)"; T="$(mktemp -d)"
printf 'precious\n' > "$T/target.md"; ln -s "$T/target.md" "$P/.planning/CHECKPOINT.md"
run_writer "$P"
[ "$(cat "$T/target.md")" = "precious" ] \
  && ok "the file the CHECKPOINT.md link points at is unchanged" \
  || bad "the checkpoint was written THROUGH the CHECKPOINT.md link"
{ [ "$H_RC" -eq 0 ] && [ -L "$P/.planning/CHECKPOINT.md" ] && [ "$(readlink "$P/.planning/CHECKPOINT.md")" = "$T/target.md" ] \
    && holds_only "$P/.planning" CHECKPOINT.md; } \
  && ok "rc 0, the link is left alone (not replaced) and no key, settings or ledger was written beside it" \
  || bad "the link was replaced or the save went ahead beside it (rc=$H_RC): $(ls -A "$P/.planning" | tr '\n' ' ')"
said_once "CHECKPOINT.md is a symbolic link" \
  && ok "one stderr line says why" || bad "stderr should be ONE line naming the link (got: $H_ERR)"
rm -rf "$P" "$T"

echo "  H3. CHECKPOINT.md is a DANGLING symlink (a write would create its target):"
P="$(make_project)"; T="$(mktemp -d)"
ln -s "$T/created-through-link" "$P/.planning/CHECKPOINT.md"
run_writer "$P"
[ ! -e "$T/created-through-link" ] \
  && ok "the dangling link's target was not created" \
  || bad "the dangling CHECKPOINT.md link was CREATED THROUGH"
{ [ "$H_RC" -eq 0 ] && [ -L "$P/.planning/CHECKPOINT.md" ] && [ "$(readlink "$P/.planning/CHECKPOINT.md")" = "$T/created-through-link" ] \
    && holds_only "$P/.planning" CHECKPOINT.md; } \
  && ok "rc 0, the dangling link is left alone and nothing was written beside it" \
  || bad "the dangling link was replaced or the save went ahead beside it (rc=$H_RC): $(ls -A "$P/.planning" | tr '\n' ' ')"
said_once "CHECKPOINT.md is a symbolic link" \
  && ok "one stderr line says why" || bad "stderr should be ONE line naming the link (got: $H_ERR)"
rm -rf "$P" "$T"

echo "  H4. RESUME-KEY.json is a symlink to an existing file:"
P="$(make_project)"; T="$(mktemp -d)"
printf '{"keep": 1}\n' > "$T/target.json"; ln -s "$T/target.json" "$P/.planning/RESUME-KEY.json"
run_writer "$P"
[ "$(cat "$T/target.json")" = '{"keep": 1}' ] \
  && ok "the file the RESUME-KEY.json link points at is unchanged" \
  || bad "the answer key was written THROUGH the RESUME-KEY.json link"
{ [ "$H_RC" -eq 0 ] && [ -L "$P/.planning/RESUME-KEY.json" ] && holds_only "$P/.planning" RESUME-KEY.json; } \
  && ok "rc 0, the link is left alone and the checkpoint was not written without its key" \
  || bad "the link was replaced or the save went ahead beside it (rc=$H_RC): $(ls -A "$P/.planning" | tr '\n' ' ')"
said_once "RESUME-KEY.json is a symbolic link" \
  && ok "one stderr line says why" || bad "stderr should be ONE line naming the link (got: $H_ERR)"
rm -rf "$P" "$T"

echo "  H5. settings.json is a symlink to an existing file:"
P="$(make_project)"; T="$(mktemp -d)"
printf '{"keep": 1}\n' > "$T/target.json"; ln -s "$T/target.json" "$P/.planning/settings.json"
run_writer "$P"
[ "$(cat "$T/target.json")" = '{"keep": 1}' ] \
  && ok "the file the settings.json link points at is unchanged" \
  || bad "settings were written THROUGH the settings.json link"
{ [ "$H_RC" -eq 0 ] && [ -L "$P/.planning/settings.json" ] && holds_only "$P/.planning" settings.json; } \
  && ok "rc 0, the link is left alone (its target was not read into a new file either) and nothing was written beside it" \
  || bad "the link was replaced or the save went ahead beside it (rc=$H_RC): $(ls -A "$P/.planning" | tr '\n' ' ')"
said_once "settings.json is a symbolic link" \
  && ok "one stderr line says why" || bad "stderr should be ONE line naming the link (got: $H_ERR)"
rm -rf "$P" "$T"

echo "  H6. .planning/ledger is a symlink to a directory (the team record would be published through it):"
P="$(make_project)"; T="$(mktemp -d)"
ln -s "$T" "$P/.planning/ledger"
run_writer "$P"
[ -z "$(ls -A "$T")" ] \
  && ok "nothing was created in the target of the ledger link" \
  || bad "the team record was published THROUGH the ledger link: $(ls -AR "$T" | tr '\n' ' ')"
{ [ "$H_RC" -eq 0 ] && [ -L "$P/.planning/ledger" ] && [ -f "$P/.planning/CHECKPOINT.md" ] && [ -f "$P/.planning/RESUME-KEY.json" ]; } \
  && ok "rc 0, the ledger link is left alone and the rest of the save still landed (only the team record is skipped)" \
  || bad "the ledger link was replaced, or the rest of the save was lost (rc=$H_RC): $(ls -A "$P/.planning" | tr '\n' ' ')"
rm -rf "$P" "$T"

echo "  H6b. HEIMDALL_PLANNING_DIR names a directory that is not there yet (the team record is made under it, as before the guard):"
P="$(make_project)"; T="$(mktemp -d)"
run_writer "$P" HEIMDALL_PLANNING_DIR="$T/plan"
ls "$T/plan/ledger/checkpoints/"*.json >/dev/null 2>&1 \
  && ok "the team record landed under the explicit planning dir, which the writer made" \
  || bad "no team record under HEIMDALL_PLANNING_DIR (rc=$H_RC, got: $(ls -AR "$T" | tr '\n' ' ')): the guard broke the explicit-dir path"
mv "$T/plan/ledger" "$T/moved" 2>/dev/null; mkdir "$T/target"; ln -s "$T/target" "$T/plan/ledger"
run_writer "$P" HEIMDALL_PLANNING_DIR="$T/plan"
{ [ "$H_RC" -eq 0 ] && [ -L "$T/plan/ledger" ] && [ -z "$(ls -A "$T/target")" ]; } \
  && ok "rc 0, a ledger link under the explicit dir is left alone and nothing was created through it" \
  || bad "the explicit dir's ledger link was written through or replaced (rc=$H_RC): $(ls -AR "$T/target" | tr '\n' ' ')"
rm -rf "$P" "$T"

echo "  H7. CHECKPOINT.md is a FIFO (not a regular file):"
P="$(make_project)"
mkfifo "$P/.planning/CHECKPOINT.md"
exec 3<>"$P/.planning/CHECKPOINT.md"   # the test holds the FIFO open, so a stray open cannot hang the writer
run_writer "$P"
LEAK="$(perl -e 'use Fcntl; fcntl(STDIN, F_SETFL, O_NONBLOCK); sysread(STDIN, $b, 4096); print $b' <&3)"
exec 3<&-
{ [ "$H_RC" -eq 0 ] && [ -p "$P/.planning/CHECKPOINT.md" ] && [ -z "$LEAK" ] && holds_only "$P/.planning" CHECKPOINT.md; } \
  && ok "rc 0, the FIFO is still a FIFO, nothing was written to it or beside it" \
  || bad "the FIFO was replaced or written to, or the save went ahead beside it (rc=$H_RC): $(ls -A "$P/.planning" | tr '\n' ' ')"
said_once "not a regular file" \
  && ok "one stderr line says why" || bad "stderr should be ONE line naming the FIFO (got: $H_ERR)"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "checkpoint-autosave.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

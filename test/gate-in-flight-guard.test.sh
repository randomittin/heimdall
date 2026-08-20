#!/usr/bin/env bash
#
# gate-in-flight-guard.test.sh — the full sweep announces that it is grading, and the
# edit-count checkpointer stops committing while it is.
#
# WHY THIS EXISTS. CLAUDE.md requires the 337-suite sweep to run over a FROZEN tree — "a
# verdict over a moving tree is not a verdict" — and nothing in the repo announced that a
# sweep was running. bin/heimdall-wip-commit, wired into the PreToolUse hook and firing
# every 6 edit-ops, therefore committed three in-progress files DURING a real sweep,
# moving HEAD and the index under suites that read git state. The bytes on disk did not
# change, so that verdict survived; a checkpointer racing the gate is nonetheless a
# coin-flip rather than a guarantee. test/run-all.sh now publishes a pid marker under
# HEIMDALL_HOME and heimdall-wip-commit reads it.
#
# Guarantees proved:
#   1. With no marker, the checkpointer still commits at its threshold — the control that
#      stops every other guarantee here from passing vacuously.
#   2. A marker naming a LIVE process suppresses the commit.
#   3. The edit is still COUNTED while suppressed: the work happened, and the first
#      checkpoint after the sweep has to include it.
#   4. A marker naming a DEAD process does NOT suppress. A sweep killed with SIGKILL never
#      runs its trap, and a stale file that disabled checkpointing forever would be a worse
#      failure than the race it prevents.
#   5. The marker is HEIMDALL_HOME-scoped, never written into the repo — a marker inside
#      the tree would itself be the tree movement it exists to prevent.
#   6. run-all.sh CLAIMS and RELEASES with an ownership check, so a nested `--filter` run
#      cannot un-freeze its parent by exiting first.
#
# Usage:  bash test/gate-in-flight-guard.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
WIP="$REPO/bin/heimdall-wip-commit"
RUNALL="$REPO/test/run-all.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-guard.XXXXXX")"
SLEEPER=""
cleanup() { [ -n "$SLEEPER" ] && kill "$SLEEPER" >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT

# A throwaway repo the checkpointer can commit into. Never this repo.
SANDBOX="$TMP/repo"; mkdir -p "$SANDBOX"
(
  cd "$SANDBOX" || exit 1
  git init -q .
  printf 'one\n' > f.txt
  git add f.txt
  git -c user.email=t@t -c user.name=t commit -qm init
) >/dev/null 2>&1

HOME_DIR="$TMP/hmdhome"; mkdir -p "$HOME_DIR"
MARKER="$HOME_DIR/.gate-in-flight"

# note_n <n> — fire the checkpointer n times against the sandbox, with a dirty tree.
note_n() {
  local n="$1" i
  for i in $(seq 1 "$n"); do
    ( cd "$SANDBOX" && HEIMDALL_HOME="$HOME_DIR" \
        git -c user.email=t@t -c user.name=t \
        --git-dir="$SANDBOX/.git" --work-tree="$SANDBOX" status >/dev/null 2>&1
      cd "$SANDBOX" && HEIMDALL_HOME="$HOME_DIR" "$WIP" note >/dev/null 2>&1 )
  done
}
wip_count() { cat "$SANDBOX/.git/heimdall-wip-count" 2>/dev/null || echo 0; }
commits()   { git -C "$SANDBOX" rev-list --count HEAD 2>/dev/null || echo 0; }
reset_counter() { rm -f "$SANDBOX/.git/heimdall-wip-count"; }

echo
echo "1 — with no marker, the checkpointer commits at its threshold (control)"
rm -f "$MARKER"; reset_counter
printf 'dirty-a\n' >> "$SANDBOX/f.txt"
BEFORE="$(commits)"
note_n 6
AFTER="$(commits)"
[ "$AFTER" -gt "$BEFORE" ] \
  && ok "6 edit-ops with a dirty tree produced a checkpoint commit ($BEFORE -> $AFTER)" \
  || bad "no commit without a marker ($BEFORE -> $AFTER) — every other guarantee here would pass vacuously"

echo
echo "2 — a marker naming a LIVE process suppresses the commit"
sleep 120 & SLEEPER=$!
printf '%s\n' "$SLEEPER" > "$MARKER"
reset_counter
printf 'dirty-b\n' >> "$SANDBOX/f.txt"
BEFORE="$(commits)"
note_n 8
AFTER="$(commits)"
[ "$AFTER" = "$BEFORE" ] \
  && ok "8 edit-ops during a live gate produced no commit (still $AFTER)" \
  || bad "the checkpointer committed while a gate was in flight ($BEFORE -> $AFTER)"

echo
echo "3 — the edit is still counted while suppressed"
C="$(wip_count)"
[ "${C:-0}" -ge 1 ] \
  && ok "the edit-op counter advanced to $C despite the suppressed commit" \
  || bad "the counter did not advance (got '$C') — work done during a sweep would be lost from the next checkpoint"

echo
echo "4 — a marker naming a DEAD process does NOT suppress"
kill "$SLEEPER" >/dev/null 2>&1; wait "$SLEEPER" 2>/dev/null; DEAD="$SLEEPER"; SLEEPER=""
printf '%s\n' "$DEAD" > "$MARKER"
reset_counter
printf 'dirty-c\n' >> "$SANDBOX/f.txt"
BEFORE="$(commits)"
note_n 6
AFTER="$(commits)"
[ "$AFTER" -gt "$BEFORE" ] \
  && ok "a stale marker (dead pid $DEAD) does not disable checkpointing ($BEFORE -> $AFTER)" \
  || bad "a stale marker silently disabled checkpointing forever ($BEFORE -> $AFTER)"

echo
echo "5 — the marker lives under HEIMDALL_HOME, never in the repo"
rm -f "$MARKER"
if grep -q 'GATE_MARKER="\${HEIMDALL_HOME:-\$HOME/.heimdall}/.gate-in-flight"' "$RUNALL"; then
  ok "run-all.sh scopes the marker to HEIMDALL_HOME"
else
  bad "run-all.sh does not scope the marker to HEIMDALL_HOME — a marker in the tree is tree movement"
fi
if git -C "$SANDBOX" status --porcelain | grep -q "gate-in-flight"; then
  bad "a gate marker appeared inside the working tree"
else
  ok "no gate marker appears in the working tree"
fi

echo
echo "6 — claim and release are ownership-checked, so a nested run cannot un-freeze its parent"
grep -q '_gate_marker_claim' "$RUNALL" && grep -q '_gate_marker_release' "$RUNALL" \
  && ok "run-all.sh claims and releases through the ownership-checked helpers" \
  || bad "run-all.sh does not use the ownership-checked claim/release helpers"
if grep -A 4 '_gate_marker_release()' "$RUNALL" | grep -q '= "\$\$"'; then
  ok "release only removes a marker naming this process"
else
  bad "release is unconditional — a nested --filter run would un-freeze the outer sweep on exit"
fi
if grep -A 10 '_gate_marker_claim()' "$RUNALL" | grep -q 'kill -0'; then
  ok "claim leaves a LIVE parent's marker alone and takes over a dead one"
else
  bad "claim overwrites any existing marker — the parent could never release its own"
fi

echo
echo "--------------------------------------------------------------------"
printf 'gate-in-flight-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

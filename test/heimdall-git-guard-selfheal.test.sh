#!/usr/bin/env bash
# test/heimdall-git-guard-selfheal.test.sh — heimdall-git-guard must self-heal two
# git-config corruptions that have actually bricked or broken this repo, in addition
# to its existing stale-index.lock job.
#
# THE TWO DEFECTS, both measured on this repo (git 2.53.0, macOS):
#
#   (1) core.bare=true on a PRIMARY CHECKOUT. `git init --bare` run with an empty/unset
#       target path degrades to the CURRENT working directory (see
#       test/repo-never-left-bare.test.sh for the exhaustive call-site scan of this
#       exact mechanism). Once set, `git status` and every worktree-requiring command
#       die with "fatal: this operation must be run in a work tree" — the checkout is
#       bricked. THE SAFE, UNAMBIGUOUS TEST: a genuinely bare repo has NO `.git` entry
#       (file or dir) AT ITS OWN ROOT — the repo root itself IS the git dir. So if the
#       standard root+.git layout is present (git-common-dir resolves to exactly
#       "<root>/.git"), core.bare can never legitimately be true there, and this is
#       always safe to reset — never touches a repo that is actually laid out bare.
#
#   (2) core.hooksPath flipping to an ABSOLUTE path. hooks/hooks.json's push-gate
#       dedup (test/pre-push-gate-dedup.test.sh) does an EXACT string match against the
#       literal ".heimdall/hooks" to decide whether the native pre-push hook is wired;
#       an absolute value silently breaks that match and doubles push latency. Root
#       cause (confirmed via commit 5448c1d, the bin/heimdall-hooks-link fix): a one-off
#       manual `git config core.hooksPath <absolute>` stopgap, run before
#       bin/heimdall-hooks-link existed to solve linked-worktree hook resolution the
#       RIGHT way (a symlink, never an absolute shared config value). Safe heal: only
#       ever normalize an absolute value back to the relative literal when it resolves
#       to EXACTLY this repo's own canonical root/.heimdall/hooks (derived independently
#       via --git-common-dir, never trusted from the possibly-corrupt value itself) AND
#       that directory actually contains a real, executable, hmd-named hook — the same
#       existence proof bin/heimdall-hooks-link itself requires before linking.
#
# KEY PLATFORM FACT this design leans on (pinned in section 0, not just assumed):
# `git rev-parse --absolute-git-dir` and `--git-common-dir` both SURVIVE core.bare=true
# even though `--show-toplevel` (and therefore `git status`) do not — so the healer can
# always find the shared config to fix, even while the corruption it is fixing is live.
#
# GUARANTEES PROVED (hermetic — own mktemp repos + the REAL bin/heimdall-init per
# fixture; HOME redirected; no network):
#   0. PLATFORM FACTS   — the git behaviours this design depends on.
#   1. BARE HEAL        — core.bare=true on a normal checkout is reset to false, and
#                          `git status` works again (DECISIVE).
#   2. BARE FALSIFIER   — a genuinely bare repo (no .git at its own root) keeps
#                          core.bare=true, untouched.
#   3. HOOKSPATH HEAL   — an absolute core.hooksPath pointing at this repo's own real
#                          hooks dir is normalized back to the relative literal
#                          (DECISIVE).
#   4. FOREIGN FALSIFIER— a genuinely custom (non-hmd, elsewhere) hooksPath is left
#                          completely alone.
#   5. EMPTY FALSIFIER  — an absolute path AT the canonical location but with no
#                          recognizable hmd hook inside is left alone (no false proof).
#   6. WORKTREE SHARED  — invoked FROM a linked worktree, both heals still land in the
#                          one shared config file.
#   7. IDEMPOTENT       — calling the guard twice is a stable no-op the second time.
#   8. EXIT CODE        — always 0, in every scenario above (fail-open, never blocks).
#   9. FALSIFIABLE      — stripping the self-heal block from a copy of the script and
#                          re-running the bare scenario must leave the corruption in
#                          place; a check that cannot be made to fail is decoration.
#
# bash 3.2 (macOS system bash) compatible: here-strings and `local` are both fine (in
# use throughout this suite already); no associative arrays, no mapfile/readarray.
# perl `alarm N; exec @ARGV` stands in for timeout(1), which macOS does not ship.
#
# Usage: bash test/heimdall-git-guard-selfheal.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$ROOT/bin/heimdall-git-guard"
INIT_BIN="$ROOT/bin/heimdall-init"

# DEFAULT-ON egress guard: `hmd init` generates a post-commit hook that shells the
# REAL `heimdall-presence beat` (fire-and-forget). Pin the baked-in default at a dead
# port so it can never reach prod from this hermetic run.
. "$ROOT/test/lib/net-default-guard.sh"

[ -x "$GUARD" ]    || { echo "FATAL: missing/!exec $GUARD" >&2; exit 2; }
[ -x "$INIT_BIN" ] || { echo "FATAL: missing/!exec $INIT_BIN" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "FATAL: git not found"  >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FATAL: perl not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-guard-selfheal.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.heimdall"
export HEIMDALL_NO_TEAM_AUTOSHARE=1

run_with_alarm() { # SECS CMD...  (perl exec replaces the image; real executables only)
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# mk_repo TAG — a standalone (non-worktree) repo with a REAL `hmd init` run in it, so
# it carries hmd's actual generated, executable hooks and the real relative
# core.hooksPath. Echoes the repo path.
mk_repo() {
  local dir="$WORK/repo$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email dev@example.com
  git -C "$dir" config user.name Dev
  printf 'hello\n' > "$dir/README.md"
  git -C "$dir" add README.md >/dev/null 2>&1
  git -C "$dir" commit -qm "initial commit" --no-verify >/dev/null 2>&1
  ( cd "$dir" && HOME="$HOME" "$INIT_BIN" ) >/dev/null 2>&1
  printf '%s' "$dir"
}

# mk_pair TAG — a main repo with a REAL `hmd init` run in it, plus a REAL linked
# worktree off it. Echoes "<main_root> <worktree_root>".
mk_pair() {
  local base="$WORK/pair$1" main wt
  main="$base/main"; wt="$base/wt"
  mkdir -p "$main"
  git -C "$main" init -q
  git -C "$main" config user.email dev@example.com
  git -C "$main" config user.name Dev
  printf 'hello\n' > "$main/README.md"
  git -C "$main" add README.md >/dev/null 2>&1
  git -C "$main" commit -qm "initial commit" --no-verify >/dev/null 2>&1
  ( cd "$main" && HOME="$HOME" "$INIT_BIN" ) >/dev/null 2>&1
  git -C "$main" worktree add -q --detach "$wt" HEAD >/dev/null 2>&1
  printf '%s %s' "$main" "$wt"
}

echo "════════════════════════════════════════════════════════════════"
echo "heimdall-git-guard self-heal — core.bare and core.hooksPath"
echo "════════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# 0. PLATFORM FACTS
# ══════════════════════════════════════════════════════════════════════════════
R0="$(mk_repo 0)"
git -C "$R0" config core.bare true

if git -C "$R0" rev-parse --show-toplevel >/dev/null 2>&1; then
  bad "platform: expected --show-toplevel to fail once core.bare=true"
else
  ok "platform: core.bare=true breaks --show-toplevel (reproduces the measured symptom)"
fi

GD0="$(git -C "$R0" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [ -n "$GD0" ]; then
  ok "platform: --absolute-git-dir SURVIVES core.bare=true ($GD0)"
else
  bad "platform: --absolute-git-dir failed under core.bare=true — the healing design's key premise is false"
fi

GC0="$(git -C "$R0" rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$GC0" ]; then
  ok "platform: --git-common-dir SURVIVES core.bare=true ($GC0)"
else
  bad "platform: --git-common-dir failed under core.bare=true — the healing design's key premise is false"
fi

git -C "$R0" config core.bare false   # de-corrupt this probe fixture; section 1 covers the heal itself
HP0="$(git -C "$R0" config --get core.hooksPath 2>/dev/null || true)"
if [ "$HP0" = ".heimdall/hooks" ]; then
  ok "platform: hmd init sets the shared core.hooksPath to the RELATIVE value"
else
  bad "platform: hmd init did not set the expected relative hooksPath (got '$HP0')"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 1. BARE HEAL — a normal checkout's core.bare=true is reset, via the real
#    no-argument invocation shape hooks.json actually uses (cwd = repo, no arg).
# ══════════════════════════════════════════════════════════════════════════════
R1="$(mk_repo 1)"
git -C "$R1" config core.bare true
BARE1_BEFORE="$(git -C "$R1" config --get core.bare 2>/dev/null || true)"
( cd "$R1" && run_with_alarm 10 "$GUARD" ) >/dev/null 2>&1
BARE1_AFTER="$(git -C "$R1" config --get core.bare 2>/dev/null || true)"
if [ "$BARE1_BEFORE" = "true" ] && [ "$BARE1_AFTER" = "false" ]; then
  ok "DECISIVE: guard heals core.bare true->false on a normal repo (no-arg/cwd invocation)"
else
  bad "guard did not heal core.bare (before='$BARE1_BEFORE' after='$BARE1_AFTER')"
fi
if git -C "$R1" status >/dev/null 2>&1; then
  ok "git status works again after the heal — the actual bricking symptom is gone"
else
  bad "git status still fails in $R1 after the heal"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. BARE FALSIFIER — a genuinely bare repo (no .git entry at its own root) must
#    never be touched.
# ══════════════════════════════════════════════════════════════════════════════
BAREREPO="$WORK/genuinely-bare.git"
[ -n "$BAREREPO" ] || { echo "FATAL: BAREREPO path empty" >&2; exit 1; }
git init -q --bare "$BAREREPO"
run_with_alarm 10 "$GUARD" "$BAREREPO" >/dev/null 2>&1
BR_AFTER="$(git -C "$BAREREPO" config --get core.bare 2>/dev/null || true)"
if [ "$BR_AFTER" = "true" ]; then
  ok "falsifier: a genuinely bare repo (no .git at its own root) keeps core.bare=true"
else
  bad "falsifier: the guard changed a genuinely bare repo's core.bare (now '$BR_AFTER') — UNSAFE" "expected true"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. HOOKSPATH HEAL — an absolute hooksPath pointing at THIS repo's own canonical
#    hooks dir is normalized back to the relative literal.
# ══════════════════════════════════════════════════════════════════════════════
R3="$(mk_repo 3)"
git -C "$R3" config core.hooksPath "$R3/.heimdall/hooks"
HP3_CORRUPT="$(git -C "$R3" config --get core.hooksPath 2>/dev/null || true)"
if [ "$HP3_CORRUPT" = "$R3/.heimdall/hooks" ]; then
  ok "gap reproduced: core.hooksPath corrupted to the absolute equivalent"
else
  bad "failed to reproduce the hooksPath corruption (got '$HP3_CORRUPT')"
fi
( cd "$R3" && run_with_alarm 10 "$GUARD" ) >/dev/null 2>&1
HP3_AFTER="$(git -C "$R3" config --get core.hooksPath 2>/dev/null || true)"
if [ "$HP3_AFTER" = ".heimdall/hooks" ]; then
  ok "DECISIVE: guard normalizes an absolute hmd hooksPath back to the relative literal"
else
  bad "guard did not normalize core.hooksPath (got '$HP3_AFTER')"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. FOREIGN FALSIFIER — a genuinely custom (non-hmd, elsewhere) hooksPath is
#    left completely alone.
# ══════════════════════════════════════════════════════════════════════════════
R4="$(mk_repo 4)"
FOREIGN="$WORK/some-other-hooks-dir"
mkdir -p "$FOREIGN"
printf '#!/bin/sh\nexit 0\n' > "$FOREIGN/pre-commit"
chmod +x "$FOREIGN/pre-commit"
git -C "$R4" config core.hooksPath "$FOREIGN"
( cd "$R4" && run_with_alarm 10 "$GUARD" ) >/dev/null 2>&1
HP4_AFTER="$(git -C "$R4" config --get core.hooksPath 2>/dev/null || true)"
if [ "$HP4_AFTER" = "$FOREIGN" ]; then
  ok "falsifier: a genuinely custom (non-hmd) hooksPath is left completely untouched"
else
  bad "falsifier: the guard rewrote a foreign hooksPath (now '$HP4_AFTER') — UNSAFE" "expected $FOREIGN"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. EMPTY FALSIFIER — an absolute path AT the canonical location, but with no
#    recognizable hmd hook inside, must not be "healed" on trust alone.
# ══════════════════════════════════════════════════════════════════════════════
R5="$(mk_repo 5)"
rm -rf "$R5/.heimdall/hooks"
mkdir -p "$R5/.heimdall/hooks"   # exists, but empty: no recognized executable hook
git -C "$R5" config core.hooksPath "$R5/.heimdall/hooks"
( cd "$R5" && run_with_alarm 10 "$GUARD" ) >/dev/null 2>&1
HP5_AFTER="$(git -C "$R5" config --get core.hooksPath 2>/dev/null || true)"
if [ "$HP5_AFTER" = "$R5/.heimdall/hooks" ]; then
  ok "falsifier: an absolute path at the canonical location but with no recognized hook file is left untouched"
else
  bad "falsifier: the guard normalized an empty hooks dir on trust alone (now '$HP5_AFTER')" "expected $R5/.heimdall/hooks"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. WORKTREE SHARED — invoked FROM a linked worktree, both heals still land in
#    the one shared config file (core.bare / core.hooksPath are not per-worktree).
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN6 WT6 <<<"$(mk_pair 6)"
git -C "$MAIN6" config core.bare true
git -C "$MAIN6" config core.hooksPath "$MAIN6/.heimdall/hooks"
run_with_alarm 10 "$GUARD" "$WT6" >/dev/null 2>&1
BARE6_AFTER="$(git -C "$WT6" config --get core.bare 2>/dev/null || true)"
HP6_AFTER="$(git -C "$WT6" config --get core.hooksPath 2>/dev/null || true)"
if [ "$BARE6_AFTER" = "false" ] && [ "$HP6_AFTER" = ".heimdall/hooks" ]; then
  ok "invoked FROM a linked worktree, the guard heals the ONE SHARED config for both keys"
else
  bad "worktree-invoked heal incomplete (bare='$BARE6_AFTER' hooksPath='$HP6_AFTER')"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7. IDEMPOTENT — calling the guard twice is a stable no-op the second time.
# ══════════════════════════════════════════════════════════════════════════════
R7="$(mk_repo 7)"
git -C "$R7" config core.bare true
git -C "$R7" config core.hooksPath "$R7/.heimdall/hooks"
( cd "$R7" && run_with_alarm 10 "$GUARD" ) >/dev/null 2>&1
( cd "$R7" && run_with_alarm 10 "$GUARD" ) >/dev/null 2>&1
BARE7="$(git -C "$R7" config --get core.bare 2>/dev/null || true)"
HP7="$(git -C "$R7" config --get core.hooksPath 2>/dev/null || true)"
if [ "$BARE7" = "false" ] && [ "$HP7" = ".heimdall/hooks" ]; then
  ok "idempotent: calling the guard twice leaves stable, correctly-healed state"
else
  bad "idempotency broke on the second call (bare='$BARE7' hooksPath='$HP7')"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 8. EXIT CODE CONTRACT — always 0, in every scenario above.
# ══════════════════════════════════════════════════════════════════════════════
run_with_alarm 10 "$GUARD" "$R1" >/dev/null 2>&1;       rc1=$?
run_with_alarm 10 "$GUARD" "$BAREREPO" >/dev/null 2>&1; rc2=$?
run_with_alarm 10 "$GUARD" "$R4" >/dev/null 2>&1;       rc3=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -eq 0 ]; then
  ok "exit code contract: guard exits 0 in every scenario above (never blocks a caller)"
else
  bad "exit code contract broken: rc1=$rc1 rc2=$rc2 rc3=$rc3"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 9. FALSIFIABLE — strip the self-heal block from a copy of the script; the SAME
#    bare corruption must now survive. A check that cannot fail is decoration.
# ══════════════════════════════════════════════════════════════════════════════
GUARD_OPEN="SELF-HEAL: core.bare / core.hooksPath"
GUARD_CLOSE="END SELF-HEAL"
if grep -qF -e "$GUARD_OPEN" "$GUARD" && grep -qF -e "$GUARD_CLOSE" "$GUARD"; then
  ok "guard carries both self-heal sentinels (mutation target is present)"
else
  bad "self-heal sentinels missing from $GUARD — cannot mutate what is not marked"
fi

MUTANT="$WORK/heimdall-git-guard.mutant"
awk -v a="$GUARD_OPEN" -v b="$GUARD_CLOSE" '
  index($0, a) { skip = 1 }
  !skip        { print }
  index($0, b) { skip = 0 }
' "$GUARD" > "$MUTANT"
chmod +x "$MUTANT"

orig_lines="$(awk 'END{print NR}' "$GUARD")"
mut_lines="$(awk 'END{print NR}' "$MUTANT")"
if [ "$mut_lines" -lt "$orig_lines" ]; then
  ok "mutation removed the self-heal block ($orig_lines -> $mut_lines lines)"
else
  bad "mutation removed nothing ($orig_lines -> $mut_lines lines) — falsifiability proves nothing"
fi
if grep -qF -e "$GUARD_OPEN" "$MUTANT"; then
  bad "mutant still carries the self-heal sentinel — mutation did not take"
else
  ok "mutant carries no self-heal sentinel"
fi

R9="$(mk_repo 9)"
git -C "$R9" config core.bare true
( cd "$R9" && run_with_alarm 10 "$MUTANT" ) >/dev/null 2>&1
BARE9="$(git -C "$R9" config --get core.bare 2>/dev/null || true)"
if [ "$BARE9" = "true" ]; then
  ok "FALSIFIABLE: with the self-heal stripped, core.bare=true survives — the assertions above are load-bearing"
else
  bad "guard-with-self-heal-stripped STILL healed core.bare — the mutation didn't remove what we think it did"
fi

echo ""
echo "heimdall-git-guard-selfheal: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

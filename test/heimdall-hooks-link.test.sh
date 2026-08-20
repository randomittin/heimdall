#!/usr/bin/env bash
# heimdall-hooks-link.test.sh — a LINKED WORKTREE must get hmd's git hooks too.
#
# THE GAP, measured empirically (git 2.53.0, macOS): `hmd init` sets
# core.hooksPath=.heimdall/hooks — a RELATIVE value, deliberately, so the
# config keeps working if the repo is ever moved/renamed. Per githooks(5) a
# relative hooksPath resolves against the ROOT OF THE WORKING TREE that FIRES
# the hook — for a LINKED worktree that is the worktree's OWN root, not the
# checkout `hmd init` actually ran in. Heimdall spawns hmd:coder and
# hmd:wave-executor with `isolation: worktree`, so that is where almost every
# real commit happens — and a fresh `git worktree add` has no .heimdall/hooks
# of its own until `hmd init` runs there again, which nothing does
# automatically. Net effect: every worktree commit silently gets NO hooks at
# all — no gate enforcement, and no `Co-Authored-By: hmd` trailer (see
# CLAUDE.md "Commit attribution" and test/prepare-commit-msg-trailer.test.sh,
# which covers the trailer's OWN properties but never a linked worktree — this
# file is the missing half).
#
# THE FIX (bin/heimdall-hooks-link, wired into bin/heimdall-precheck-edit —
# fires on every real Edit/Write/MultiEdit PreToolUse call): the 4 generated
# hook scripts carry no per-worktree STATE — the ones that need a repo root
# re-resolve it dynamically at RUN time (`git rev-parse --show-toplevel`), so
# the SAME files are correct from any worktree. A linked worktree missing its
# own .heimdall/hooks gets one lazily: a symlink straight at the CANONICAL
# checkout's .heimdall/hooks (never the whole .heimdall/ dir — receipts/ and
# verdict.json ARE genuinely per-worktree and must stay that way).
#
# Rejected: making core.hooksPath itself ABSOLUTE. .git/config is shared
# across every worktree, so ONE value has to work for all of them — and an
# absolute value breaks hooks/hooks.json's push-gate dedup, which does an
# EXACT string match against the literal ".heimdall/hooks" to decide whether
# to defer to the native pre-push hook (test/pre-push-gate-dedup.test.sh) —
# silently doubling push latency in the real repo. See the implementing commit
# for the full reasoning.
#
# Guarantees proved (hermetic — own mktemp repos + REAL `git worktree add` +
# the REAL bin/heimdall-init per section; HOME redirected; no network):
#   0. PLATFORM FACTS      — the git worktree-resolution premises this rests on.
#   1. GAP REPRODUCED      — untouched, a worktree commit carries ZERO hmd
#                             trailers (the bug, exactly as measured).
#   2. LINK CREATED         — heimdall-hooks-link symlinks the worktree's
#                             .heimdall/hooks at the canonical checkout's.
#   3. FIX END TO END       — after linking, a worktree commit carries EXACTLY
#                             ONE hmd trailer (the decisive assertion).
#   4. WIRED                — the REAL heimdall-precheck-edit, invoked exactly
#                             as the PreToolUse(Edit) hook invokes it, heals
#                             the link AND keeps its own exit-code contract.
#   5. MAIN UNCHANGED        — no regression: the canonical checkout's own
#                             (real, non-symlink) hooks dir is left untouched,
#                             and its commits still carry exactly one trailer.
#   6. HUMAN CO-AUTHOR      — a real human co-author in the message survives
#                             alongside the hmd trailer via the linked hook.
#   7. IDEMPOTENT           — calling the linker twice never errors or
#                             duplicates the trailer.
#   8. NEVER CLOBBERS        — a worktree with a REAL (non-symlink) hooks dir
#                             already in place (e.g. `hmd init` ran there
#                             directly) is left completely untouched.
#   9. FALSIFIERS           — the linker must still say no: not a worktree, a
#                             customised hooksPath, or a canonical dir that
#                             doesn't actually exist yet.
#  10. EXIT CODE CONTRACT   — always 0, in every scenario above (fail-open).
#  11. WIRING               — the call actually exists in heimdall-precheck-edit.
#
# Usage: bash test/heimdall-hooks-link.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin"
INIT_BIN="$BIN/heimdall-init"
LINK_BIN="$BIN/heimdall-hooks-link"
PRECHECK="$BIN/heimdall-precheck-edit"

# DEFAULT-ON egress guard: `hmd init` generates a post-commit hook that shells
# the REAL `heimdall-presence beat` (fire-and-forget). Pin the baked-in default
# at a dead port so it can never reach prod from this hermetic run.
. "$REPO/test/lib/net-default-guard.sh"

[ -x "$INIT_BIN" ] || { echo "FATAL: missing/!exec $INIT_BIN" >&2; exit 2; }
[ -x "$PRECHECK" ] || { echo "FATAL: missing/!exec $PRECHECK" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-hookslink.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.heimdall"
export HEIMDALL_NO_TEAM_AUTOSHARE=1

# mk_pair TAG — a main repo with a REAL `hmd init` run in it, plus a REAL
# linked worktree off it (freshly created -> no .heimdall/hooks of its own).
# Echoes "<main_root> <worktree_root>".
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

# Matches test/prepare-commit-msg-trailer.test.sh's own TRAILER constant — the
# CURRENT hmd attribution trailer (runhmd GitHub account, not the retired
# hmd@runheimdall.dev address / "hmd" display name).
HMD_TRAILER='Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>'
hmd_trailers() { git -C "$1" log -1 --format=%B 2>/dev/null | grep -Fc "$HMD_TRAILER"; }
hooks_kind() { # <dir> -> SYMLINK | REALDIR | MISSING
  if [ -L "$1/.heimdall/hooks" ]; then echo SYMLINK
  elif [ -d "$1/.heimdall/hooks" ]; then echo REALDIR
  else echo MISSING
  fi
}

echo "════════════════════════════════════════════════════════════════"
echo "heimdall-hooks-link — a linked worktree gets hmd's git hooks too"
echo "════════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# 0. PLATFORM FACTS
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN0 WT0 <<<"$(mk_pair 0)"
GD0="$(git -C "$WT0" rev-parse --absolute-git-dir 2>/dev/null)"
GCD0="$(git -C "$WT0" rev-parse --git-common-dir 2>/dev/null)"
if [ -n "$GD0" ] && [ -n "$GCD0" ] && [ "$GD0" != "$GCD0" ]; then
  ok "platform: a linked worktree's git-dir differs from its git-common-dir"
else
  bad "platform: expected git-dir != git-common-dir in a worktree" "git-dir=$GD0 common-dir=$GCD0"
fi
TOP0="$(git -C "$WT0" rev-parse --show-toplevel 2>/dev/null)"
WT0_REAL="$(cd "$WT0" && pwd -P)"
[ "$TOP0" = "$WT0_REAL" ] && ok "platform: --show-toplevel resolves to the WORKTREE's own root" || bad "platform: --show-toplevel gave '$TOP0', expected '$WT0_REAL'"
[ "$(hooks_kind "$WT0")" = "MISSING" ] && ok "platform: a fresh worktree has NO .heimdall/hooks of its own (the gap)" || bad "platform: fresh worktree unexpectedly already has .heimdall/hooks"
HP0="$(git -C "$MAIN0" config --get core.hooksPath 2>/dev/null)"
[ "$HP0" = ".heimdall/hooks" ] && ok "platform: hmd init sets the shared core.hooksPath to the RELATIVE value" || bad "platform: core.hooksPath wrong" "got '$HP0'"

# ══════════════════════════════════════════════════════════════════════════════
# 1. GAP REPRODUCED — untouched, a worktree commit gets ZERO hmd trailers.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN1 WT1 <<<"$(mk_pair 1)"
printf 'a\n' > "$WT1/a.txt"
git -C "$WT1" add a.txt >/dev/null 2>&1
git -C "$WT1" commit -qm "worktree commit, no fix applied" >/dev/null 2>&1
N1="$(hmd_trailers "$WT1")"
[ "$N1" -eq 0 ] && ok "gap reproduced: an unfixed worktree commit carries ZERO hmd trailers ($N1)" || bad "expected 0 trailers pre-fix, got $N1"

# ══════════════════════════════════════════════════════════════════════════════
# 2. LINK CREATED — heimdall-hooks-link symlinks .heimdall/hooks to the canonical dir.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN2 WT2 <<<"$(mk_pair 2)"
( cd "$WT2" && "$LINK_BIN" ) >/dev/null 2>&1
[ "$(hooks_kind "$WT2")" = "SYMLINK" ] && ok "heimdall-hooks-link created .heimdall/hooks as a symlink" || bad "heimdall-hooks-link did not create a symlink at .heimdall/hooks"
TARGET2="$(cd "$WT2" && readlink .heimdall/hooks 2>/dev/null || true)"
MAIN2_REAL="$(cd "$MAIN2" && pwd -P)"
[ "$TARGET2" = "$MAIN2_REAL/.heimdall/hooks" ] && ok "the symlink points at the CANONICAL checkout's own .heimdall/hooks" || bad "symlink target wrong" "got '$TARGET2', want '$MAIN2_REAL/.heimdall/hooks'"

# ══════════════════════════════════════════════════════════════════════════════
# 3. FIX END TO END — after linking, a worktree commit carries EXACTLY ONE trailer.
# ══════════════════════════════════════════════════════════════════════════════
printf 'b\n' > "$WT2/b.txt"
git -C "$WT2" add b.txt >/dev/null 2>&1
git -C "$WT2" commit -qm "worktree commit, fix applied" >/dev/null 2>&1
N3="$(hmd_trailers "$WT2")"
[ "$N3" -eq 1 ] && ok "DECISIVE: a fixed worktree commit carries EXACTLY ONE hmd trailer" || bad "expected exactly 1 trailer post-fix, got $N3"

# ══════════════════════════════════════════════════════════════════════════════
# 4. WIRED — the REAL heimdall-precheck-edit heals the link AND keeps its own contract.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN4 WT4 <<<"$(mk_pair 4)"
payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1"; }
printf 'c\n' > "$WT4/c.txt"
RC4=0
( cd "$WT4" && payload "c.txt" | CLAUDE_PLUGIN_ROOT="$REPO" "$PRECHECK" ) >/dev/null 2>&1 || RC4=$?
[ "$(hooks_kind "$WT4")" = "SYMLINK" ] && ok "precheck-edit's wired call healed the link with zero manual steps" || bad "precheck-edit did not heal the link"
[ "$RC4" -eq 0 ] && ok "precheck-edit's own exit-code contract unchanged (0 on a clear file)" || bad "precheck-edit exit code changed: rc=$RC4"
git -C "$WT4" add c.txt >/dev/null 2>&1
git -C "$WT4" commit -qm "worktree commit via the wired precheck-edit path" >/dev/null 2>&1
N4="$(hmd_trailers "$WT4")"
[ "$N4" -eq 1 ] && ok "end-to-end via the real hook wiring: exactly one trailer" || bad "expected exactly 1 trailer via wiring, got $N4"

# ══════════════════════════════════════════════════════════════════════════════
# 5. MAIN UNCHANGED — no regression in the canonical (non-worktree) checkout.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN5 _WT5 <<<"$(mk_pair 5)"
BEFORE5="$(hooks_kind "$MAIN5")"
( cd "$MAIN5" && "$LINK_BIN" ) >/dev/null 2>&1
AFTER5="$(hooks_kind "$MAIN5")"
[ "$BEFORE5" = "REALDIR" ] && [ "$AFTER5" = "REALDIR" ] && ok "the canonical checkout's own .heimdall/hooks is untouched (still a real dir, never re-linked to itself)" || bad "canonical checkout's hooks dir was altered" "before=$BEFORE5 after=$AFTER5"
printf 'd\n' > "$MAIN5/d.txt"
git -C "$MAIN5" add d.txt >/dev/null 2>&1
git -C "$MAIN5" commit -qm "main checkout commit" >/dev/null 2>&1
N5="$(hmd_trailers "$MAIN5")"
[ "$N5" -eq 1 ] && ok "main-checkout commits still carry exactly one trailer (no regression)" || bad "main checkout trailer count wrong, got $N5"

# ══════════════════════════════════════════════════════════════════════════════
# 6. HUMAN CO-AUTHOR SURVIVES alongside the hmd trailer via the linked hook.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN6 WT6 <<<"$(mk_pair 6)"
( cd "$WT6" && "$LINK_BIN" ) >/dev/null 2>&1
printf 'e\n' > "$WT6/e.txt"
git -C "$WT6" add e.txt >/dev/null 2>&1
git -C "$WT6" commit -qm "$(printf 'feat: add e\n\nCo-Authored-By: Jane Doe <jane@example.com>\n')" >/dev/null 2>&1
BODY6="$(git -C "$WT6" log -1 --format=%B)"
HUMAN6="$(printf '%s' "$BODY6" | grep -c '^Co-Authored-By: Jane Doe <jane@example.com>$')"
HMD6="$(hmd_trailers "$WT6")"
[ "$HUMAN6" -eq 1 ] && [ "$HMD6" -eq 1 ] && ok "a legitimate human co-author survives alongside the hmd trailer" || bad "co-author survival broke" "human=$HUMAN6 hmd=$HMD6"

# ══════════════════════════════════════════════════════════════════════════════
# 7. IDEMPOTENT — calling the linker twice never errors or duplicates anything.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN7 WT7 <<<"$(mk_pair 7)"
RC7A=0; RC7B=0
( cd "$WT7" && "$LINK_BIN" ) >/dev/null 2>&1 || RC7A=$?
( cd "$WT7" && "$LINK_BIN" ) >/dev/null 2>&1 || RC7B=$?
[ "$RC7A" -eq 0 ] && [ "$RC7B" -eq 0 ] && [ "$(hooks_kind "$WT7")" = "SYMLINK" ] && ok "calling the linker twice is a harmless no-op the second time" || bad "second call misbehaved" "rc1=$RC7A rc2=$RC7B"
printf 'f\n' > "$WT7/f.txt"
git -C "$WT7" add f.txt >/dev/null 2>&1
git -C "$WT7" commit -qm "after double-link" >/dev/null 2>&1
N7="$(hmd_trailers "$WT7")"
[ "$N7" -eq 1 ] && ok "double-linking never duplicates the trailer" || bad "trailer count wrong after double-link, got $N7"

# ══════════════════════════════════════════════════════════════════════════════
# 8. NEVER CLOBBERS a REAL (non-symlink) hooks dir already in the worktree.
# ══════════════════════════════════════════════════════════════════════════════
read -r MAIN8 WT8 <<<"$(mk_pair 8)"
mkdir -p "$WT8/.heimdall/hooks"
printf 'a real hooks dir, not ours to touch\n' > "$WT8/.heimdall/hooks/MARKER"
( cd "$WT8" && "$LINK_BIN" ) >/dev/null 2>&1
if [ "$(hooks_kind "$WT8")" = "REALDIR" ] && [ -f "$WT8/.heimdall/hooks/MARKER" ]; then
  ok "a pre-existing REAL hooks dir in the worktree is left completely untouched"
else
  bad "the linker clobbered a pre-existing real hooks dir"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 9. FALSIFIERS — the linker must still say no.
# ══════════════════════════════════════════════════════════════════════════════
# 9a. NOT a linked worktree at all: must never self-symlink the canonical checkout.
R9A="$WORK/r9a"; mkdir -p "$R9A"
git -C "$R9A" init -q; git -C "$R9A" config user.email dev@example.com; git -C "$R9A" config user.name Dev
git -C "$R9A" config core.hooksPath .heimdall/hooks
( cd "$R9A" && "$LINK_BIN" ) >/dev/null 2>&1
[ ! -e "$R9A/.heimdall" ] && ok "falsifier: a non-worktree repo is never touched, even with hooksPath pre-set" || bad "falsifier: linker created .heimdall in a non-worktree repo"

# 9b. hooksPath customised away from hmd's default: must not link.
read -r MAIN9B WT9B <<<"$(mk_pair 9b)"
git -C "$MAIN9B" config core.hooksPath ".git/hooks"
( cd "$WT9B" && "$LINK_BIN" ) >/dev/null 2>&1
[ "$(hooks_kind "$WT9B")" = "MISSING" ] && ok "falsifier: a customised (non-hmd) core.hooksPath is left alone" || bad "falsifier: linker acted on a customised hooksPath"

# 9c. Canonical hooks dir doesn't actually exist: must not link to nothing.
R9C_BASE="$WORK/r9c"; mkdir -p "$R9C_BASE/main"
git -C "$R9C_BASE/main" init -q
git -C "$R9C_BASE/main" config user.email dev@example.com; git -C "$R9C_BASE/main" config user.name Dev
printf 'x\n' > "$R9C_BASE/main/x.txt"; git -C "$R9C_BASE/main" add x.txt >/dev/null 2>&1
git -C "$R9C_BASE/main" commit -qm init --no-verify >/dev/null 2>&1
git -C "$R9C_BASE/main" config core.hooksPath ".heimdall/hooks"   # set WITHOUT running hmd init
git -C "$R9C_BASE/main" worktree add -q --detach "$R9C_BASE/wt" HEAD >/dev/null 2>&1
( cd "$R9C_BASE/wt" && "$LINK_BIN" ) >/dev/null 2>&1
[ "$(hooks_kind "$R9C_BASE/wt")" = "MISSING" ] && ok "falsifier: never links to a canonical hooks dir that doesn't exist" || bad "falsifier: linker created a symlink to a nonexistent canonical dir"

# ══════════════════════════════════════════════════════════════════════════════
# 10. EXIT CODE CONTRACT — always 0 (fail-open), across every scenario above.
# ══════════════════════════════════════════════════════════════════════════════
RC_OK=0
for d in "$R9A" "$WT9B" "$R9C_BASE/wt" "$WT8"; do
  ( cd "$d" && "$LINK_BIN" ) >/dev/null 2>&1 || RC_OK=1
done
[ "$RC_OK" -eq 0 ] && ok "heimdall-hooks-link exits 0 in every falsifier scenario (never blocks a caller)" || bad "heimdall-hooks-link returned nonzero in at least one fail-open scenario"

# ══════════════════════════════════════════════════════════════════════════════
# 11. WIRING — the call actually exists in heimdall-precheck-edit.
# ══════════════════════════════════════════════════════════════════════════════
grep -q 'heimdall-hooks-link' "$PRECHECK" && ok "heimdall-precheck-edit is wired to call heimdall-hooks-link" || bad "no heimdall-hooks-link call found in heimdall-precheck-edit"

printf "\n  heimdall-hooks-link: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

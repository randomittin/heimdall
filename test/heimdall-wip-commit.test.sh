#!/usr/bin/env bash
# heimdall-wip-commit.test.sh — acceptance for MECHANICAL mid-task WIP checkpointing.
#
# THE GAP this closes: the existing PostToolUse auto-commit hook (hooks/hooks.json)
# only fires when `git diff --name-only | wc -l` >= 5 — a DISTINCT-FILE-COUNT gate.
# A long-running agent that edits only 1-4 files across dozens of tool calls never
# crosses that threshold, so truncation loses everything (measured: 7 truncation
# events in one session, 2 with ZERO commits on the branch — see conventions R7).
# This tool adds an EDIT-OPERATION-COUNT gate (independent of distinct file count),
# wired through bin/heimdall-precheck-edit, which already fires on every real
# Edit/MultiEdit/Write PreToolUse call — no hooks.json change required.
#
# Guarantees proved (hermetic — own temp git project per section, own HOME untouched):
#   A. NOTE BELOW THRESHOLD    — fewer than N `note` calls: no commit, counter grows.
#   B. NOTE AT THRESHOLD       — the Nth `note` call with dirty changes commits them,
#      message is `wip:`-prefixed and marked, counter resets to 0.
#   C. NOTHING DIRTY           — counter hits threshold with nothing dirty: no empty
#      commit is created, counter still resets (no perpetual re-trigger next call).
#   D. NO-AUTOCOMMIT RESPECTED — .heimdall-no-autocommit present: `note` never commits.
#   E. CHECKPOINT FORCES NOW   — `checkpoint` commits immediately, ignoring the counter.
#   F. SQUASH COLLAPSES WIP    — 3 consecutive wip commits squash into 1; tree (file
#      contents) is byte-identical before/after; commits before the run are untouched.
#   G. WIRED                   — the REAL heimdall-precheck-edit, invoked exactly as
#      the PreToolUse(Edit) hook invokes it (JSON piped on stdin), triggers a
#      checkpoint at the threshold AND preserves its own original exit-code contract.
#   H. STATUS                  — reports counter/threshold/dirty count correctly.
#
# Falsifiability (quoted in the implementing commit, not re-asserted here): the
# threshold comparison in cmd_note was mutated from `-ge` to `-gt` during development,
# which turned section B red (commit created one call late) with the exact expected
# reason, then reverted back to green.
#
# Usage: bash test/heimdall-wip-commit.test.sh   (exit 0 = all hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
WIP="$REPO/bin/heimdall-wip-commit"
PRECHECK="$REPO/bin/heimdall-precheck-edit"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

make_project() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'hello\n' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm "initial commit" --no-verify
  printf '%s' "$d"
}

dirty_one_file() { # <repo> <name>
  printf 'change-%s\n' "$RANDOM" > "$1/$2"
}

ncommits() { git -C "$1" log --oneline 2>/dev/null | wc -l | tr -d ' '; }

# ─────────────────────────────────────────────────────────────────────────────
echo "A. NOTE BELOW THRESHOLD — counter grows, no commit:"
P="$(make_project)"
dirty_one_file "$P" "a.txt"
( cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=3 "$WIP" note ) >/dev/null 2>&1
( cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=3 "$WIP" note ) >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 1 ] && ok "no commit yet after 2 of 3 note calls (still 1 commit)" || bad "unexpected commit count=$(ncommits "$P")"
ST="$(cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=3 "$WIP" status 2>/dev/null)"
printf '%s' "$ST" | grep -q "count=2" && ok "status reports count=2 ($ST)" || bad "status did not report count=2: $ST"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "B. NOTE AT THRESHOLD — Nth call commits dirty changes, marked + resets:"
P="$(make_project)"
dirty_one_file "$P" "b.txt"
( cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=3 "$WIP" note ) >/dev/null 2>&1
( cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=3 "$WIP" note ) >/dev/null 2>&1
( cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=3 "$WIP" note ) >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 2 ] && ok "3rd note call created exactly one commit (total=2)" || bad "commit count=$(ncommits "$P") (want 2)"
SUBJ="$(git -C "$P" log -1 --format=%s)"
case "$SUBJ" in wip:*) ok "commit subject is wip:-marked ($SUBJ)" ;; *) bad "commit subject not wip:-marked: $SUBJ" ;; esac
git -C "$P" log -1 --format=%b | grep -qi "heimdall-wip" && ok "commit body carries the heimdall-wip marker" || bad "no heimdall-wip marker in body"
ST="$(cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=3 "$WIP" status 2>/dev/null)"
printf '%s' "$ST" | grep -q "count=0" && ok "counter reset to 0 after commit" || bad "counter not reset: $ST"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "C. NOTHING DIRTY — threshold hit but clean tree: no empty commit, counter resets:"
P="$(make_project)"
( cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=2 "$WIP" note ) >/dev/null 2>&1
( cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=2 "$WIP" note ) >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 1 ] && ok "no empty commit created on a clean tree (still 1 commit)" || bad "unexpected commit on clean tree, count=$(ncommits "$P")"
ST="$(cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=2 "$WIP" status 2>/dev/null)"
printf '%s' "$ST" | grep -q "count=0" && ok "counter still resets at threshold even with nothing dirty" || bad "counter did not reset: $ST"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "D. NO-AUTOCOMMIT RESPECTED — .heimdall-no-autocommit suppresses note commits:"
P="$(make_project)"
touch "$P/.heimdall-no-autocommit"
dirty_one_file "$P" "d.txt"
( cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=1 "$WIP" note ) >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 1 ] && ok "no-autocommit flag suppressed the wip commit" || bad "wip commit fired despite .heimdall-no-autocommit"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "E. CHECKPOINT FORCES IMMEDIATE COMMIT — ignores the counter:"
P="$(make_project)"
dirty_one_file "$P" "e.txt"
( cd "$P" && "$WIP" checkpoint ) >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 2 ] && ok "checkpoint committed immediately with counter untouched" || bad "checkpoint did not commit, count=$(ncommits "$P")"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "F. SQUASH COLLAPSES CONSECUTIVE WIP COMMITS, TREE UNCHANGED:"
P="$(make_project)"
BASE_SHA="$(git -C "$P" rev-parse HEAD)"
dirty_one_file "$P" "f1.txt"; ( cd "$P" && "$WIP" checkpoint ) >/dev/null 2>&1
dirty_one_file "$P" "f2.txt"; ( cd "$P" && "$WIP" checkpoint ) >/dev/null 2>&1
dirty_one_file "$P" "f3.txt"; ( cd "$P" && "$WIP" checkpoint ) >/dev/null 2>&1
BEFORE_TREE="$(git -C "$P" rev-parse 'HEAD^{tree}')"
[ "$(ncommits "$P")" -eq 4 ] && ok "setup: 3 wip commits atop initial (total=4)" || bad "setup wrong, count=$(ncommits "$P")"
( cd "$P" && "$WIP" squash --base "$BASE_SHA" ) >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 2 ] && ok "3 wip commits squashed into 1 (total=2)" || bad "squash count wrong, count=$(ncommits "$P")"
AFTER_TREE="$(git -C "$P" rev-parse 'HEAD^{tree}')"
[ "$BEFORE_TREE" = "$AFTER_TREE" ] && ok "tree contents byte-identical before/after squash" || bad "squash altered tree contents"
[ -f "$P/f1.txt" ] && [ -f "$P/f2.txt" ] && [ -f "$P/f3.txt" ] && ok "all 3 files still present after squash" || bad "squash lost a file"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "G. WIRED — the REAL heimdall-precheck-edit triggers a checkpoint at threshold, preserves its own contract:"
P="$(make_project)"
payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1"; }
dirty_one_file "$P" "g.txt"
RC1=0; RC2=0
( cd "$P" && payload "g.txt" | HEIMDALL_WIP_EDIT_THRESHOLD=2 CLAUDE_PLUGIN_ROOT="$REPO" "$PRECHECK" ) >/dev/null 2>&1 || RC1=$?
( cd "$P" && payload "g.txt" | HEIMDALL_WIP_EDIT_THRESHOLD=2 CLAUDE_PLUGIN_ROOT="$REPO" "$PRECHECK" ) >/dev/null 2>&1 || RC2=$?
[ "$(ncommits "$P")" -eq 2 ] && ok "precheck-edit's 2nd invocation auto-committed via the wired wip-commit call" || bad "no auto-commit via precheck-edit wiring, count=$(ncommits "$P")"
[ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && ok "precheck-edit's own exit-code contract unchanged (0 on a clear file)" || bad "precheck-edit exit codes changed: rc1=$RC1 rc2=$RC2"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "H. STATUS — reports counter/threshold/dirty correctly:"
P="$(make_project)"
dirty_one_file "$P" "h1.txt"
dirty_one_file "$P" "h2.txt"
( cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=9 "$WIP" note ) >/dev/null 2>&1
ST="$(cd "$P" && HEIMDALL_WIP_EDIT_THRESHOLD=9 "$WIP" status 2>/dev/null)"
printf '%s' "$ST" | grep -q "count=1" && printf '%s' "$ST" | grep -q "threshold=9" && printf '%s' "$ST" | grep -q "dirty=2" \
  && ok "status line correct: $ST" || bad "status line wrong: $ST"
rm -rf "$P"

echo ""
echo "heimdall-wip-commit.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

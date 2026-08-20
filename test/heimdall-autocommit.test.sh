#!/usr/bin/env bash
# heimdall-autocommit.test.sh — acceptance for the shared auto-commit mechanics
# used by hooks/hooks.json's two AUTOMATIC checkpoint call sites (PostToolUse
# >=5-file gate, SessionEnd dirty-tree gate).
#
# THE TWO VERIFIED DEFECTS this closes:
#
#   B1 — both call sites committed with `--no-verify`, which skips pre-commit,
#   the ONLY place an unproven-merge receipt was ever written (bin/heimdall-init's
#   generated hook, guarded by a DIFFERENT bypass — HMD_SKIP=1). So an automatic,
#   ungated commit landed with no receipt: "visible, never silent" was false for
#   this bypass path. bin/heimdall-autocommit now writes its own receipt to the
#   same .heimdall/receipts/unproven.log ledger, tagged AUTOCOMMIT.
#
#   B2 — both call sites staged with `git add -A`, which stages EVERYTHING dirty
#   in the tree, not just what the session touched. Confirmed real-world
#   consequence: commit d22dfc9 (already an ancestor of origin/main — a PUBLIC
#   repo) swept a file dropped by a different tool (the heimdall-ledger MCP
#   server, which writes straight to disk, bypassing Claude's Edit/Write tools
#   and therefore edit-tracker) into a checkpoint commit alongside six path globs
#   naming an unrelated PRIVATE project. bin/heimdall-autocommit now stages only
#   the intersection of (a) paths edit-tracker recorded THIS session and (b)
#   paths currently dirty per `git status --porcelain` — never `-A`. Empty
#   intersection (including: no ledger at all) means NO commit, not a fallback.
#
# A third, smaller defect rides along: the old inline code computed the
# "(N files)" commit-message count in a way that could run BEFORE staging
# (missing untracked files entirely — the exact shape behind a real
# "heimdall: session-end checkpoint (0 files)" commit that actually added 21
# lines). bin/heimdall-autocommit counts strictly from what it staged, before
# committing.
#
# Guarantees proved (hermetic — own throwaway git repo per section, own
# edit-tracker session id per section, isolated from this session's real ledger
# by forcing SESSION_ID and stripping CLAUDE_CODE_SESSION_ID/CLAUDE_SESSION_ID):
#   A. RECEIPT WRITTEN     — an auto-commit writes ts/AUTOCOMMIT/phase/staged=.
#   B. SCOPED STAGING      — an unrelated dirty file elsewhere in the tree is
#      never swept into the commit, and is still sitting there dirty afterward.
#   C. ACCURATE COUNT      — the "(N files)" subject matches the real count.
#   D. NO-AUTOCOMMIT        — .heimdall-no-autocommit suppresses commit AND receipt.
#   E. NOTHING TO STAGE    — a tracked-but-currently-clean path: no empty commit.
#   F. FAIL-SAFE ON EMPTY LEDGER — a dirty file the session never told
#      edit-tracker about is left alone; an empty ledger never falls back to -A.
#   G. RECEIPT SHAPE       — tab-separated ts / AUTOCOMMIT / phase / staged=...,
#      the same 4-field shape as the existing HMD_SKIP receipt (one coherent log).
#   H. GIT-GUARD WIRED     — a proven-stale index.lock is cleared, not left to
#      break the commit (HMD_GIT_GUARD_PGREP=false deterministically simulates
#      "no git process alive", same override heimdall-git-guard's own doc names).
#
# Falsifiability (proved during development, quoted in the implementing commit):
# the staging step was mutated from the edit-tracker∩dirty intersection to a
# blanket `git add -A`, which turned Section B and Section F red — B because
# unrelated.txt got swept into the commit, F because untracked-by-session.txt
# got committed instead of left alone — both with the exact expected reason,
# then reverted back to green. See the implementing commit message for the
# quoted PASS/FAIL counts on both sides of that mutation.
#
# Usage: bash test/heimdall-autocommit.test.sh   (exit 0 = all hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
AC="$REPO/bin/heimdall-autocommit"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

TESTTMP="${TMPDIR:-/tmp}"
TESTTMP="${TESTTMP%/}"

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

ncommits() { git -C "$1" log --oneline 2>/dev/null | wc -l | tr -d ' '; }

# Isolated from THIS session's own real edit-tracker ledger: force SESSION_ID
# and strip the two env vars edit-tracker checks first (CLAUDE_CODE_SESSION_ID,
# CLAUDE_SESSION_ID) so only our test-scoped SESSION_ID applies.
et() { # <session-id> <repo> <args...>
  local sid="$1" repo="$2"; shift 2
  ( cd "$repo" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID SESSION_ID="$sid" "$REPO/bin/edit-tracker" "$@" )
}

ac() { # <session-id> <repo> <phase>
  local sid="$1" repo="$2" phase="$3"
  ( cd "$repo" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID SESSION_ID="$sid" "$AC" "$phase" )
}

cleanup_ledger() { # <session-id>
  rm -f "$TESTTMP/heimdall-edits/$1.log" "$TESTTMP/heimdall-edits/$1.lock" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
echo "A. RECEIPT WRITTEN — an auto-commit writes an AUTOCOMMIT receipt (visible, never silent):"
P="$(make_project)"
SID="hmd-ac-A-$$"
cleanup_ledger "$SID"
printf 'x\n' > "$P/a.txt"
et "$SID" "$P" log Write "$P/a.txt" >/dev/null 2>&1
ac "$SID" "$P" "auto-checkpoint" >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 2 ] && ok "commit landed (total=2)" || bad "no commit, count=$(ncommits "$P")"
RCPT="$P/.heimdall/receipts/unproven.log"
if [ -s "$RCPT" ]; then
  grep -q "AUTOCOMMIT" "$RCPT" && ok "receipt tagged AUTOCOMMIT" || bad "receipt missing AUTOCOMMIT tag: $(cat "$RCPT")"
  grep -q "auto-checkpoint" "$RCPT" && ok "receipt records the phase" || bad "receipt missing phase: $(cat "$RCPT")"
  grep -q "a.txt" "$RCPT" && ok "receipt records what was staged" || bad "receipt missing staged file: $(cat "$RCPT")"
else
  bad "no receipt written at $RCPT"
fi
cleanup_ledger "$SID"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "B. SCOPED STAGING — an unrelated dirty file elsewhere in the tree is never swept in:"
P="$(make_project)"
SID="hmd-ac-B-$$"
cleanup_ledger "$SID"
printf 'x\n' > "$P/edited.txt"
printf 'y\n' > "$P/unrelated.txt"
et "$SID" "$P" log Edit "$P/edited.txt" >/dev/null 2>&1
ac "$SID" "$P" "auto-checkpoint" >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 2 ] && ok "commit landed (total=2)" || bad "no commit, count=$(ncommits "$P")"
COMMITTED="$(git -C "$P" diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null)"
printf '%s\n' "$COMMITTED" | grep -qx "edited.txt" && ok "edited.txt WAS committed" || bad "edited.txt missing from commit: $COMMITTED"
printf '%s\n' "$COMMITTED" | grep -qx "unrelated.txt" && bad "unrelated.txt was swept into the commit (the exact d22dfc9-class leak)" || ok "unrelated.txt was NOT swept into the commit"
git -C "$P" status --porcelain | grep -q "unrelated.txt" && ok "unrelated.txt is still dirty afterward (deliberately excluded, not lost)" || bad "unrelated.txt vanished from the working tree"
cleanup_ledger "$SID"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "C. ACCURATE COUNT — the (N files) subject matches what actually landed:"
P="$(make_project)"
SID="hmd-ac-C-$$"
cleanup_ledger "$SID"
for n in 1 2 3; do
  printf 'x\n' > "$P/f$n.txt"
  et "$SID" "$P" log Write "$P/f$n.txt" >/dev/null 2>&1
done
ac "$SID" "$P" "session-end checkpoint" >/dev/null 2>&1
SUBJ="$(git -C "$P" log -1 --format=%s)"
case "$SUBJ" in *"(3 files)"*) ok "subject reports (3 files): $SUBJ" ;; *) bad "subject wrong: $SUBJ" ;; esac
REAL="$(git -C "$P" diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | wc -l | tr -d ' ')"
[ "$REAL" = 3 ] && ok "actual committed file count matches (3)" || bad "actual count=$REAL, subject claimed 3"
cleanup_ledger "$SID"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "D. NO-AUTOCOMMIT RESPECTED — .heimdall-no-autocommit suppresses commit AND receipt:"
P="$(make_project)"
SID="hmd-ac-D-$$"
cleanup_ledger "$SID"
touch "$P/.heimdall-no-autocommit"
printf 'x\n' > "$P/d.txt"
et "$SID" "$P" log Write "$P/d.txt" >/dev/null 2>&1
ac "$SID" "$P" "auto-checkpoint" >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 1 ] && ok "no commit created" || bad "commit fired despite .heimdall-no-autocommit"
[ -f "$P/.heimdall/receipts/unproven.log" ] && bad "receipt written despite no-autocommit flag" || ok "no receipt written"
cleanup_ledger "$SID"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "E. NOTHING TO STAGE — edit-tracker knows a path but it is not currently dirty: no empty commit:"
P="$(make_project)"
SID="hmd-ac-E-$$"
cleanup_ledger "$SID"
et "$SID" "$P" log Write "$P/README.md" >/dev/null 2>&1   # already-committed, currently clean
ac "$SID" "$P" "auto-checkpoint" >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 1 ] && ok "no empty commit created" || bad "unexpected commit, count=$(ncommits "$P")"
[ -f "$P/.heimdall/receipts/unproven.log" ] && bad "receipt written with nothing staged" || ok "no receipt written"
cleanup_ledger "$SID"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "F. FAIL-SAFE ON EMPTY LEDGER — a dirty file this session never told edit-tracker about is left alone (no -A fallback):"
P="$(make_project)"
SID="hmd-ac-F-$$"
cleanup_ledger "$SID"
et "$SID" "$P" init >/dev/null 2>&1   # ledger present-and-empty, not absent
printf 'x\n' > "$P/untracked-by-session.txt"
ac "$SID" "$P" "auto-checkpoint" >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 1 ] && ok "no commit created — an empty ledger never falls back to -A" || bad "committed anyway, count=$(ncommits "$P")"
git -C "$P" status --porcelain | grep -q "untracked-by-session.txt" && ok "the file is still sitting there, untouched" || bad "the file got swept up somehow"
cleanup_ledger "$SID"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "G. RECEIPT SHAPE — tab-separated ts/AUTOCOMMIT/phase/staged=..., one coherent log with the HMD_SKIP family:"
P="$(make_project)"
SID="hmd-ac-G-$$"
cleanup_ledger "$SID"
printf 'x\n' > "$P/g.txt"
et "$SID" "$P" log Write "$P/g.txt" >/dev/null 2>&1
ac "$SID" "$P" "auto-checkpoint" >/dev/null 2>&1
RCPT="$P/.heimdall/receipts/unproven.log"
if [ -s "$RCPT" ]; then
  LINE="$(tail -1 "$RCPT")"
  F1="$(printf '%s' "$LINE" | cut -f1)"; F2="$(printf '%s' "$LINE" | cut -f2)"; F3="$(printf '%s' "$LINE" | cut -f3)"; F4="$(printf '%s' "$LINE" | cut -f4)"
  case "$F1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z) ok "field1 is an ISO8601 UTC timestamp: $F1" ;; *) bad "field1 not a timestamp: $F1" ;; esac
  [ "$F2" = "AUTOCOMMIT" ] && ok "field2 is the AUTOCOMMIT tag" || bad "field2 wrong: $F2"
  [ "$F3" = "auto-checkpoint" ] && ok "field3 is the phase" || bad "field3 wrong: $F3"
  case "$F4" in staged=*) ok "field4 is staged=...: $F4" ;; *) bad "field4 wrong: $F4" ;; esac
else
  bad "no receipt to inspect"
fi
cleanup_ledger "$SID"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "H. GIT-GUARD WIRED — a proven-stale index.lock is cleared, not left to break the commit:"
P="$(make_project)"
SID="hmd-ac-H-$$"
cleanup_ledger "$SID"
printf 'x\n' > "$P/h.txt"
et "$SID" "$P" log Write "$P/h.txt" >/dev/null 2>&1
: > "$P/.git/index.lock"
( cd "$P" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID SESSION_ID="$SID" HMD_GIT_GUARD_PGREP=false "$AC" "auto-checkpoint" ) >/dev/null 2>&1
[ "$(ncommits "$P")" -eq 2 ] && ok "stale lock was cleared and the commit still landed" || bad "commit blocked by stale lock, count=$(ncommits "$P")"
[ -f "$P/.git/index.lock" ] && bad "stale lock file still present" || ok "stale lock file is gone"
cleanup_ledger "$SID"
rm -rf "$P"

echo ""
echo "heimdall-autocommit.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

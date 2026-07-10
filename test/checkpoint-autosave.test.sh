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
[ -f "$CK" ] && ok "checkpoint written despite .heimdall-no-autocommit" || bad "no-autocommit suppressed the checkpoint"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "checkpoint-autosave.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

#!/usr/bin/env bash
# checkpoint-depth.test.sh — acceptance for the CHECKPOINT DEPTH the auto-checkpoint
# needs to make a context-reset genuinely safe.
#
# THE PROBLEM this guards against: a forensic measurement (docs/analysis/token-spend-
# forensics.md) found one 15-day session cost $913.54 (82.8% of a 3-week bill) because
# context grew to a mean of 501k tokens and never restarted. Capping context at ~150k
# recovers ~$369.50; a restart costs ~$0.02. The ONLY reason an operator doesn't
# restart is fear of losing context — RJ's own manual checkpoint calls the existing
# auto block "a git log with extra steps": everything in it is already in `git log`.
# What's missing is what exists ONLY in-session: work in OTHER worktrees that never
# got merged, files this session touched that never got committed, and whether the
# push gate is actually green — none of which `git log` on this one checkout can see.
#
#   0. METADATA REGRESSION — Branch/HEAD/Phase/Active goal/Uncommitted files must
#      actually APPEAR as dedicated lines (bash 3.2 printf leading-dash bug silently
#      dropped all five; this is the regression guard).
#   1. WORKTREE LEDGER    — "nothing is lost" proof: every worktree of this repo,
#      flagged if dirty or unmerged, clean otherwise.
#   2. SESSION EDITS      — this session's Write/Edit'd files via edit-tracker, never
#      printed as "zero" when the ledger is simply untracked.
#   3. GATE STATE          — push-gate verdict (PASS/FAILING/NOT-EVALUATED, never a
#      false PASS) + any failing evals/oracles/*/report.json.
#   4. RESUME              — runnable commands, not prose.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CKPT="$REPO/bin/heimdall-checkpoint"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# A fresh throwaway git project with a .planning dir (mirrors checkpoint-autosave.test.sh).
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

# ─────────────────────────────────────────────────────────────────────────────
echo "0. METADATA REGRESSION — Branch/HEAD/Phase/goal/dirty-count are dedicated lines:"
P="$(make_project)"
"$CKPT" write "$P" >/dev/null 2>&1
CK="$P/.planning/CHECKPOINT.md"
BR="$(git -C "$P" rev-parse --abbrev-ref HEAD)"
SHA="$(git -C "$P" rev-parse --short HEAD)"
grep -qE "^- \*\*Branch:\*\* ${BR}\$" "$CK" 2>/dev/null && ok "Branch line present with correct value" || bad "Branch line missing/wrong (bash 3.2 printf leading-dash regression)"
grep -qE "^- \*\*HEAD:\*\* ${SHA}\$" "$CK" 2>/dev/null && ok "HEAD line present with correct value" || bad "HEAD line missing/wrong"
grep -qE "^- \*\*Phase:\*\* " "$CK" 2>/dev/null && ok "Phase line present" || bad "Phase line missing"
grep -qE "^- \*\*Active goal:\*\* " "$CK" 2>/dev/null && ok "Active goal line present" || bad "Active goal line missing"
grep -cE "^- \*\*Uncommitted files:\*\* [0-9]+\$" "$CK" 2>/dev/null | grep -qx 1 && ok "Uncommitted-files line present exactly once, single-line integer" || bad "Uncommitted-files line missing, duplicated, or corrupted"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "1. WORKTREE LEDGER — nothing-lost proof across clean/dirty/unmerged worktrees:"
WRAP="$(mktemp -d)"
MAIN="$WRAP/main"
git init -q "$MAIN"
git -C "$MAIN" config user.email t@t.t
git -C "$MAIN" config user.name t
printf 'hello\n' > "$MAIN/README.md"
git -C "$MAIN" add README.md
git -C "$MAIN" commit -qm "initial commit" --no-verify
mkdir -p "$MAIN/.planning"

WT_DIRTY="$WRAP/wt-dirty"
git -C "$MAIN" worktree add -q -b branch-dirty "$WT_DIRTY" >/dev/null 2>&1
printf 'scratch\n' > "$WT_DIRTY/scratch.txt"

WT_UNMERGED="$WRAP/wt-unmerged"
git -C "$MAIN" worktree add -q -b branch-unmerged "$WT_UNMERGED" >/dev/null 2>&1
git -C "$WT_UNMERGED" commit -q --allow-empty -m "unmerged work" --no-verify

"$CKPT" write "$MAIN" >/dev/null 2>&1
CK="$MAIN/.planning/CHECKPOINT.md"

grep -q "Worktree ledger" "$CK" 2>/dev/null && ok "worktree ledger section present" || bad "worktree ledger section missing"
grep -F "$WT_DIRTY" "$CK" 2>/dev/null | grep -q "DIRTY" && ok "dirty worktree flagged with its path" || bad "dirty worktree NOT flagged (path/DIRTY not on same line)"
grep -F "$WT_DIRTY" "$CK" 2>/dev/null | grep -q "1 uncommitted file" && ok "dirty worktree reports correct file count (1)" || bad "dirty worktree file count wrong/missing"
grep -F "$WT_UNMERGED" "$CK" 2>/dev/null | grep -q "UNMERGED" && ok "unmerged worktree flagged with its path" || bad "unmerged worktree NOT flagged (path/UNMERGED not on same line)"
grep -F "$MAIN" "$CK" 2>/dev/null | grep -qE "DIRTY|UNMERGED" && bad "primary (clean) worktree incorrectly flagged" || ok "primary worktree correctly NOT flagged (clean)"
rm -rf "$WRAP"

# ─────────────────────────────────────────────────────────────────────────────
echo "2. SESSION EDITS — this session's Write/Edit'd files via edit-tracker:"
ET="$REPO/bin/edit-tracker"
if [ -x "$ET" ]; then
  P="$(make_project)"
  TRACK_TMP="$(mktemp -d)"
  SID="depth-test-$$"
  TMPDIR="$TRACK_TMP" CLAUDE_CODE_SESSION_ID="$SID" "$ET" log write "$P/src/example.txt" >/dev/null 2>&1
  TMPDIR="$TRACK_TMP" CLAUDE_CODE_SESSION_ID="$SID" "$CKPT" write "$P" >/dev/null 2>&1
  CK="$P/.planning/CHECKPOINT.md"
  grep -q "session's edited files" "$CK" 2>/dev/null && ok "session-edits section present when ledger has entries" || bad "session-edits section missing despite seeded ledger"
  grep -qF "example.txt" "$CK" 2>/dev/null && ok "seeded edit-tracker path appears in checkpoint" || bad "seeded path not surfaced"
  rm -rf "$P" "$TRACK_TMP"

  P="$(make_project)"
  TRACK_TMP2="$(mktemp -d)"
  SID2="depth-test-empty-$$"
  TMPDIR="$TRACK_TMP2" CLAUDE_CODE_SESSION_ID="$SID2" "$CKPT" write "$P" >/dev/null 2>&1
  CK="$P/.planning/CHECKPOINT.md"
  grep -q "session's edited files" "$CK" 2>/dev/null && bad "session-edits section printed for an untracked/absent ledger (would falsely imply zero edits)" || ok "session-edits section correctly omitted when ledger is untracked, not zero"
  rm -rf "$P" "$TRACK_TMP2"
else
  bad "bin/edit-tracker not present/executable — cannot verify session-edits section"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "3. GATE STATE — push-gate verdict is never a false PASS, plus failing oracle gates:"
HS="$REPO/bin/heimdall-state"
if [ -x "$HS" ]; then
  # 3a. No heimdall-state.json at all -> NOT-EVALUATED, never a silent PASS.
  P="$(make_project)"
  "$CKPT" write "$P" >/dev/null 2>&1
  CK="$P/.planning/CHECKPOINT.md"
  grep -q "NOT-EVALUATED" "$CK" 2>/dev/null && ok "absent heimdall-state.json reported NOT-EVALUATED" || bad "absent gate state not reported as NOT-EVALUATED"
  grep -qE "verdict — PASS\)" "$CK" 2>/dev/null && bad "absent gate state falsely reported as PASS" || ok "absent gate state correctly never claims PASS"
  rm -rf "$P"

  # 3b. init + mark-dirty -> FAILING, with a reason.
  P="$(make_project)"
  ( cd "$P" && "$HS" init >/dev/null 2>&1 && "$HS" mark-dirty >/dev/null 2>&1 )
  "$CKPT" write "$P" >/dev/null 2>&1
  CK="$P/.planning/CHECKPOINT.md"
  grep -qE "verdict — FAILING\)" "$CK" 2>/dev/null && ok "dirty gate state reported FAILING" || bad "dirty gate state not reported FAILING"
  grep -qi "GATE FAILED" "$CK" 2>/dev/null && ok "gate-failure reason surfaced" || bad "gate-failure reason missing"
  rm -rf "$P"

  # 3c. init + mark-clean -> PASS.
  P="$(make_project)"
  ( cd "$P" && "$HS" init >/dev/null 2>&1 && "$HS" mark-clean >/dev/null 2>&1 )
  "$CKPT" write "$P" >/dev/null 2>&1
  CK="$P/.planning/CHECKPOINT.md"
  grep -qE "verdict — PASS\)" "$CK" 2>/dev/null && ok "clean gate state reported PASS" || bad "clean gate state not reported PASS"
  rm -rf "$P"
else
  bad "bin/heimdall-state not present/executable — cannot verify gate-state section"
fi

# 3d. A failing evals/oracles/<domain>/report.json is surfaced.
P="$(make_project)"
mkdir -p "$P/evals/oracles/demo-gate"
cat > "$P/evals/oracles/demo-gate/report.json" <<'JSON'
{"gate_id":"demo-gate","status":"fail","first_divergence":null,"metrics":{},"fix_hint":"run the demo fixture","haid":"haid:test","wave":1,"ts":"2026-01-01T00:00:00Z"}
JSON
"$CKPT" write "$P" >/dev/null 2>&1
CK="$P/.planning/CHECKPOINT.md"
if command -v jq >/dev/null 2>&1; then
  grep -qF "demo-gate" "$CK" 2>/dev/null && ok "failing eval oracle report surfaced with its gate_id" || bad "failing eval oracle report NOT surfaced"
else
  bad "jq not present — cannot verify eval-oracle report surfacing"
fi
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "4. RESUME — runnable commands, not prose:"
P="$(make_project)"
"$CKPT" write "$P" >/dev/null 2>&1
CK="$P/.planning/CHECKPOINT.md"
awk '/^### Resume$/{f=1} f' "$CK" 2>/dev/null | grep -q '```' && ok "Resume section contains a fenced code block" || bad "Resume section has no fenced/runnable commands"
awk '/^### Resume$/{f=1} f' "$CK" 2>/dev/null | grep -q "check-quality-gates" && ok "Resume includes the gate-check command" || bad "Resume missing gate-check command"
awk '/^### Resume$/{f=1} f' "$CK" 2>/dev/null | grep -q -- "status --porcelain" && ok "Resume includes a git-status confirmation command" || bad "Resume missing git-status command"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "checkpoint-depth.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

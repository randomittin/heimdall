#!/usr/bin/env bash
# heimdall-resume-brief.test.sh — acceptance for the ORCHESTRATOR-facing resume brief.
#
# THE GAP this closes: today, resuming a truncated child agent's worktree is manual
# — `git log main..HEAD` + `git status --porcelain` + hand-written summary, redone
# from scratch, in the orchestrator's own tokens, every single time (measured this
# session: 7 truncation events, each mitigated by hand-inspection). This tool makes
# that inspection a single command instead.
#
# DISTINCT FROM bin/heimdall-resume-probe: the probe grades whether ONE session's
# OWN CHECKPOINT.md survived ITS OWN restart (an answer-key/digest match against
# .planning/RESUME-KEY.json). This tool has no answer key — it mechanically derives
# a state summary of ANY worktree, including one belonging to a different, possibly
# still-truncated agent, purely from git plumbing. Different question, different tool.
#
# Guarantees proved (hermetic — own temp git project per section):
#   A. BASIC BRIEF        — a worktree exactly at base: 0 ahead, 0 behind, 0 dirty.
#   B. AHEAD + DIRTY       — N commits ahead of base + M dirty files: counts and
#      listings (commit subjects, dirty paths) are correct, and the loss warning
#      fires only when something is actually dirty.
#   C. BEHIND BASE         — base moves forward after the branch point: behind-base
#      is reported correctly (this is the exact staleness this session hit for real
#      — a worktree up to 166 commits behind main).
#   D. JSON                — --json emits the same facts as structured, parseable
#      output.
#   E. FILES TOUCHED       — the touched-files union counts a file once even when
#      it is both committed-ahead-of-base AND currently dirty again.
#   F. RUN-TESTS TARGETED  — --run-tests runs ONLY test files implicated by the
#      touched-file set (this repo's bin/X <-> test/X.test.sh convention), never
#      the full suite — the full sweep is reserved for the landing commit only
#      (CLAUDE.md "When the full gate runs"). A pre-existing, untouched test file
#      must NOT be executed.
#   G. BAD PATH            — a non-git path is a real usage error: nonzero exit,
#      clear stderr message (this is a manually-invoked diagnostic tool, so unlike
#      a PreToolUse hook it fails LOUD, not open).
#
# Falsifiability (quoted in the implementing commit, not re-asserted here): the
# ahead-count rev-list direction was mutated (swapped base/HEAD order), which turned
# section B red (ahead reported as 0) with the exact expected reason, then reverted.
#
# Usage: bash test/heimdall-resume-brief.test.sh   (exit 0 = all hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BRIEF="$REPO/bin/heimdall-resume-brief"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

make_project() {
  # Deliberately decoupled from the ambient `init.defaultBranch` config: this
  # machine's is unset (git falls back to "master"), but a teammate's or CI's may
  # be "main" — if the working branch and the "main" base ever became the SAME
  # ref, every ahead/behind count in this file would silently read 0. Guarantee
  # separation by always checking the work out onto "wt", distinct from "main".
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'hello\n' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm "initial commit" --no-verify
  git -C "$d" branch -q main 2>/dev/null || true
  git -C "$d" checkout -qb wt main
  printf '%s' "$d"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "A. BASIC BRIEF — worktree exactly at base:"
P="$(make_project)"
OUT="$("$BRIEF" "$P" --base main 2>&1)"
printf '%s' "$OUT" | grep -q "ahead-of-base: 0" && ok "0 commits ahead reported" || bad "ahead-of-base wrong: $OUT"
printf '%s' "$OUT" | grep -q "behind-base:   0\|behind-base: 0\|up to date" && ok "0 commits behind reported" || bad "behind-base wrong: $OUT"
printf '%s' "$OUT" | grep -q "dirty:         0\|dirty: 0" && ok "0 dirty files reported" || bad "dirty count wrong: $OUT"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "B. AHEAD + DIRTY — commits ahead of base plus dirty files, loss warning fires:"
P="$(make_project)"
printf 'x\n' > "$P/x.txt"; git -C "$P" add x.txt; git -C "$P" commit -qm "add x" --no-verify
printf 'y\n' > "$P/y.txt"; git -C "$P" add y.txt; git -C "$P" commit -qm "add y" --no-verify
printf 'dirty1\n' > "$P/dirty1.txt"
printf 'dirty2\n' > "$P/dirty2.txt"
OUT="$("$BRIEF" "$P" --base main 2>&1)"
printf '%s' "$OUT" | grep -q "ahead-of-base: 2" && ok "2 commits ahead reported" || bad "ahead-of-base wrong: $OUT"
printf '%s' "$OUT" | grep -q "add x" && printf '%s' "$OUT" | grep -q "add y" && ok "both commit subjects listed" || bad "commit subjects missing: $OUT"
printf '%s' "$OUT" | grep -qE "dirty:[[:space:]]+2" && ok "2 dirty files reported" || bad "dirty count wrong: $OUT"
printf '%s' "$OUT" | grep -q "dirty1.txt" && printf '%s' "$OUT" | grep -q "dirty2.txt" && ok "both dirty paths listed" || bad "dirty paths missing: $OUT"
printf '%s' "$OUT" | grep -qi "uncommitted" && ok "loss warning fires when dirty > 0" || bad "no loss warning despite dirty files: $OUT"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "C. BEHIND BASE — base advances after the branch point:"
P="$(make_project)"
git -C "$P" checkout -qb feature main
printf 'feat\n' > "$P/feat.txt"; git -C "$P" add feat.txt; git -C "$P" commit -qm "feature work" --no-verify
git -C "$P" checkout -q main
printf 'm1\n' > "$P/m1.txt"; git -C "$P" add m1.txt; git -C "$P" commit -qm "main moves on 1" --no-verify
printf 'm2\n' > "$P/m2.txt"; git -C "$P" add m2.txt; git -C "$P" commit -qm "main moves on 2" --no-verify
git -C "$P" checkout -q feature
OUT="$("$BRIEF" "$P" --base main 2>&1)"
printf '%s' "$OUT" | grep -qE "behind-base:[[:space:]]+2" && ok "2 commits behind base reported (the real staleness this session hit)" || bad "behind-base wrong: $OUT"
printf '%s' "$OUT" | grep -qE "ahead-of-base:[[:space:]]+1" && ok "1 commit ahead of base still reported correctly" || bad "ahead-of-base wrong: $OUT"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "D. JSON — structured output carries the same facts:"
P="$(make_project)"
printf 'x\n' > "$P/x.txt"; git -C "$P" add x.txt; git -C "$P" commit -qm "add x" --no-verify
OUT="$("$BRIEF" "$P" --base main --json 2>&1)"
printf '%s' "$OUT" | grep -q '"ahead_of_base"[[:space:]]*:[[:space:]]*1' && ok "json ahead_of_base=1" || bad "json ahead_of_base wrong: $OUT"
printf '%s' "$OUT" | grep -q '"branch"' && ok "json carries branch key" || bad "json missing branch key: $OUT"
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && ok "json output actually parses" || bad "json output does not parse: $OUT"
fi
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "E. FILES TOUCHED — union counts a file once, not twice:"
P="$(make_project)"
printf 'x\n' > "$P/x.txt"; git -C "$P" add x.txt; git -C "$P" commit -qm "add x" --no-verify
printf 'x-changed-again\n' > "$P/x.txt"
OUT="$("$BRIEF" "$P" --base main 2>&1)"
printf '%s' "$OUT" | grep -qE "files-touched:[[:space:]]+1( |$)" && ok "x.txt counted once despite being both committed and re-dirtied" || bad "files-touched union wrong: $OUT"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "F. RUN-TESTS TARGETED — only touched test files run, never the full suite:"
P="$(make_project)"
mkdir -p "$P/test" "$P/bin"
# The unrelated test must land ON MAIN, BEFORE wt's own commits — that is what
# "pre-existing, this branch's diff never touches it" actually means structurally.
# Committing it onto wt itself would make it genuinely touched (correctly picked
# up), which is a different scenario, not this one.
git -C "$P" checkout -q main
printf '#!/bin/bash\necho "UNRELATED-SHOULD-NOT-RUN: 1 passed, 0 failed."\nexit 0\n' > "$P/test/unrelated.test.sh"
chmod +x "$P/test/unrelated.test.sh"
git -C "$P" add test/unrelated.test.sh
git -C "$P" commit -qm "add unrelated test (lands on main, before wt branches further)" --no-verify
git -C "$P" checkout -q wt
# checkout just pruned test/ as a side effect: removing main's tracked
# test/unrelated.test.sh from the working tree left the directory empty, and
# git rmdir's a directory a checkout empties. Recreate before writing into it.
mkdir -p "$P/test" "$P/bin"
printf '#!/bin/bash\necho "dummy-test: 1 passed, 0 failed."\nexit 0\n' > "$P/test/widget.test.sh"
chmod +x "$P/test/widget.test.sh"
printf '#!/bin/bash\necho widget\n' > "$P/bin/widget"
git -C "$P" add bin/widget test/widget.test.sh
git -C "$P" commit -qm "add widget + its test" --no-verify
OUT="$("$BRIEF" "$P" --base main --run-tests 2>&1)"
printf '%s' "$OUT" | grep -q "dummy-test: 1 passed" && ok "the touched test (widget.test.sh) was actually run" || bad "touched test did not run: $OUT"
printf '%s' "$OUT" | grep -q "UNRELATED-SHOULD-NOT-RUN" && bad "an UNTOUCHED test file was run — should be targeted, not full-suite: $OUT" || ok "the untouched pre-existing test file was correctly skipped"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "G. BAD PATH — a non-git path is a real usage error:"
BADPATH="$(mktemp -d)"
"$BRIEF" "$BADPATH" >/tmp/heimdall-resume-brief-badpath.out 2>&1
RC=$?
[ "$RC" -ne 0 ] && ok "nonzero exit on a non-git path (rc=$RC)" || bad "should have failed on a non-git path, rc=$RC"
grep -qi "git\|repo" /tmp/heimdall-resume-brief-badpath.out && ok "clear error message printed" || bad "no clear error message: $(cat /tmp/heimdall-resume-brief-badpath.out)"
rm -rf "$BADPATH" /tmp/heimdall-resume-brief-badpath.out

echo ""
echo "heimdall-resume-brief.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

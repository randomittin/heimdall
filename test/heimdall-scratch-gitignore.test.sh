#!/usr/bin/env bash
# test/heimdall-scratch-gitignore.test.sh — falsifiable proof that atomic-write scratch/temp
# artifacts can NEVER be staged by the auto-checkpoint hook's `git add -A` (hooks/hooks.json:83,
# `git add -A && git commit -m "heimdall: auto-checkpoint (${count} files)" ...`), by construction
# of the repo's OWN .gitignore — copied VERBATIM into a hermetic fixture repo (never reimplemented
# here), so a future edit that narrows or removes the rule fails THIS test, not just goes unnoticed.
#
# WHY THIS EXISTS: commit 35830f9 committed sentinels/hmd-statusline.py.tmp.24032.f3b2f4cdf9f6
# (~2124 lines) into git tracking — a leaked atomic-write temp file swept up by the blind
# `git add -A` the moment 5+ files were dirty (the same hook fired again mid-investigation of
# this defect and produced a fresh auto-checkpoint commit, d6e661d, confirming the hook is live
# and still blind to file SHAPE — only .gitignore stops it). The fix is additive: a .gitignore
# rule; this test is the falsifier that the rule actually holds, covering every scratch-file
# shape this codebase's OWN atomic-write helpers are observed to produce:
#   bin/heimdall-status-json  atomic_write():        <path>.tmp.<pid>          ("%s.tmp.%d")
#   sentinels/hmd-statusline.py (multiple helpers):   <path>.<pid>.tmp         (".%d.tmp")
#   the historical leak itself (35830f9):             <path>.tmp.<pid>.<hex>
#
# FALSIFIABLE CLAIMS:
#   (1) `git add -A` in a repo carrying this repo's REAL .gitignore does not stage any file
#       matching a scratch-artifact shape this codebase's atomic-write helpers produce.
#   (2) The rule is not over-broad: a legitimately-named file survives `git add -A` untouched.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GITIGNORE_SRC="$ROOT/.gitignore"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -f "$GITIGNORE_SRC" ] || { echo "FATAL: $GITIGNORE_SRC missing" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }

WORK="$(mktemp -d -t "scratch-gitignore-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FIXTURE="$WORK/repo"
mkdir -p "$FIXTURE/sentinels"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email "test@runheimdall.dev"
git -C "$FIXTURE" config user.name "test"
cp "$GITIGNORE_SRC" "$FIXTURE/.gitignore"
git -C "$FIXTURE" add .gitignore
git -C "$FIXTURE" commit -qm seed

echo "-- (1) atomic-write scratch shapes never get staged by git add -A -----------"
printf 'scratch\n' > "$FIXTURE/status.json.tmp.24032"
printf 'scratch\n' > "$FIXTURE/hmd-statusline.py.24032.tmp"
printf 'scratch\n' > "$FIXTURE/hmd-statusline.py.tmp.24032.f3b2f4cdf9f6"
printf 'scratch\n' > "$FIXTURE/sentinels/hmd-statusline.py.tmp.99999.abc123def456"
printf 'scratch\n' > "$FIXTURE/sentinels/hmd-statusline.py.55555.tmp"

git -C "$FIXTURE" add -A
STAGED="$(git -C "$FIXTURE" diff --cached --name-only)"

if printf '%s\n' "$STAGED" | grep -q '\.tmp'; then
  bad "git add -A staged a scratch artifact: $(printf '%s' "$STAGED" | grep '\.tmp' | tr '\n' ' ')"
else
  ok "git add -A staged nothing matching a scratch shape (staged: '${STAGED:-<empty>}')"
fi

echo "-- (2) a similarly-named REAL source file still stages normally -------------"
# Guard against an over-broad rule swallowing legitimate source.
printf 'real\n' > "$FIXTURE/tmpfile_helper.py"
git -C "$FIXTURE" add -A
STAGED2="$(git -C "$FIXTURE" diff --cached --name-only)"
if printf '%s\n' "$STAGED2" | grep -qF "tmpfile_helper.py"; then
  ok "a legitimately-named file (tmpfile_helper.py) still stages normally"
else
  bad "the ignore rule is too broad — it swallowed a real source file"
fi

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1

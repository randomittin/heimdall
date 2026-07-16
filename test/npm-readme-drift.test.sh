#!/usr/bin/env bash
#
# npm-readme-drift.test.sh — the npm README is a byte-identical copy of the root README.
#
#   bash test/npm-readme-drift.test.sh     (exit 0 = packages/runheimdall/README.md matches root)
#
# This is the same class of defect version-drift.test.sh gates: the npm package (`npm view
# runheimdall readme`, npmjs.com/package/runheimdall) used to ship a hand-maintained stub
# README while the real one lived at the repo root — a second copy nobody kept in sync.
# release/sync-release.sh now copies root README.md -> packages/runheimdall/README.md on
# every release sync, so the only way to make this drift is to hand-edit one copy and skip
# the sync step. This gate goes red the instant that happens.
#
# --self-test: proves the gate can go red. Copies the repo into a throwaway tmpdir, corrupts
# packages/runheimdall/README.md there, asserts this script reports the drift, then discards
# the copy. Nothing in the real tree is touched.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${NPM_README_DRIFT_REPO:-$(cd "$SELF_DIR/.." && pwd)}"

if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  # Corrupt the npm copy so it no longer matches root.
  printf '# stale stub\n' > "$TMP/packages/runheimdall/README.md"
  echo "npm-readme-drift --self-test: asserting the gate goes RED on a corrupted copy"
  if NPM_README_DRIFT_REPO="$TMP" bash "$SELF_DIR/npm-readme-drift.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed against a known-corrupted copy" >&2
    exit 1
  else
    echo "  ✓ gate correctly reported drift (exit non-zero) on the corrupted copy"
  fi
  echo "npm-readme-drift --self-test: PASS"
  exit 0
fi

ROOT_README="$REPO/README.md"
NPM_README="$REPO/packages/runheimdall/README.md"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "npm-readme-drift harness  repo=$REPO"
echo "--------------------------------------------------------------------"

[ -f "$ROOT_README" ] || { echo "npm-readme-drift: root README missing: $ROOT_README" >&2; exit 1; }
[ -f "$NPM_README" ] || { bad "packages/runheimdall/README.md is missing — run release/sync-release.sh <TAG> to render it"; echo; echo "npm-readme-drift.test.sh: $PASS passed, $FAIL failed."; exit 1; }

if cmp -s "$ROOT_README" "$NPM_README"; then
  ok "packages/runheimdall/README.md is byte-identical to root README.md"
else
  bad "packages/runheimdall/README.md has drifted from root README.md — run release/sync-release.sh <TAG> to re-render it (or, outside a release, cp README.md packages/runheimdall/README.md)"
fi

echo ""
echo "npm-readme-drift.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

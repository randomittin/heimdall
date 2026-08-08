#!/usr/bin/env bash
# oracle-hermeticity.test.sh — an oracle gate may never resolve to the CALLING repo.
#
# THE DEFECT THIS LOCKS DOWN. `falsify changelog-bash32` runs as a pre-commit gate.
# Git EXPORTS GIT_DIR and GIT_INDEX_FILE into every hook it runs, so a harness that
# builds throwaway git fixtures with a bare `cd "$FIX" && git init` does not get its
# own repo — it gets the caller's. Two failures fall out of that, both observed:
#
#   FALSE RED  — the oracle grades the CALLER's history instead of its fixture, so
#                the gate fails on a clean tree. Every agent then learns to reach
#                for HMD_SKIP=1, which dissolves the gate discipline entirely.
#   REAL WRITE — `git init` re-initialises the caller's repo (this is how core.bare
#                got flipped on the live repo), `git config` rewrites its identity,
#                and the fixture commits land on the caller's branch.
#
# WHAT THIS TEST DOES. It reproduces the hook environment against a DECOY repo —
# never the real one — and asserts:
#
#   [1] NOT FALSE-RED. With the hook's git env exported at a decoy, the gate still
#       scores 1.0000. A gate that only passes in a pristine shell is not a gate.
#   [2] NO ESCAPE. The decoy is byte-identical afterward — same refs, same config,
#       same object count. The gate wrote nothing into the ambient repo.
#   [3] FALSIFIABLE. The hermetic guard is stripped from a throwaway copy of the
#       oracle and the same run MUST go RED. A guard that cannot be made to fail
#       is decoration, and this is the check that proves it is load-bearing.
#
# The decoy carries a refusing pre-commit hook because the repo this gate protects
# has one too: that hook is what turns an escaped fixture commit into a hard abort.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$TEST_DIR/.." && pwd)"
FALSIFY="$PLUGIN/bin/falsify"
DOMAIN="changelog-bash32"
ORACLE="$PLUGIN/evals/oracles/$DOMAIN"
HARNESS="$ORACLE/run.test.sh"

# The sentinels delimiting the hermetic guard inside the harness. [3] strips
# exactly this block; if the harness renames them, this test fails loudly rather
# than silently "mutating" nothing and declaring victory.
GUARD_OPEN="── HERMETIC GIT ENV GUARD ──"
GUARD_CLOSE="── END HERMETIC GIT ENV GUARD ──"

# This test manipulates git env deliberately. Start from a known-clean slate so a
# variable inherited from OUR caller can never redirect the bookkeeping below.
for _gv in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
  [ "$_gv" = "GIT_EXEC_PATH" ] || unset "$_gv" 2>/dev/null || true
done
unset _gv

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$(( fail + 1 )); }

command -v git  >/dev/null 2>&1 || { printf 'git required\n'  >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { printf 'jq required\n'   >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { printf 'perl required\n' >&2; exit 2; }
[ -x "$FALSIFY" ] || { printf 'falsify not executable: %s\n' "$FALSIFY" >&2; exit 2; }
[ -f "$HARNESS" ] || { printf 'harness missing: %s\n'        "$HARNESS" >&2; exit 2; }

# ── Decoy: an ambient repo that looks like the one this gate actually guards ──
# History, a configured identity, and a pre-commit hook that refuses everything.
make_decoy() {
  _d="$1"
  rm -rf "$_d"; mkdir -p "$_d"
  git init -q "$_d"
  git -C "$_d" config user.email decoy@heimdall.invalid
  git -C "$_d" config user.name  decoy
  _n=0
  while [ "$_n" -lt 6 ]; do
    _n=$(( _n + 1 ))
    git -C "$_d" commit -q --allow-empty -m "ambient commit $_n"
  done
  printf '#!/bin/sh\nexit 1\n' > "$_d/.git/hooks/pre-commit"
  chmod +x "$_d/.git/hooks/pre-commit"
}

# Everything an escaping fixture would disturb: refs (incl. any namespaced ones),
# the identity/bare/hooksPath config it rewrites, and the object store.
decoy_fingerprint() {
  _d="$1"
  git -C "$_d" for-each-ref --format='ref %(refname) %(objectname)'
  git -C "$_d" rev-parse HEAD | sed 's/^/head /'
  for _k in user.email user.name core.bare core.hooksPath core.repositoryformatversion; do
    printf 'cfg %s=%s\n' "$_k" "$(git -C "$_d" config --get "$_k" 2>/dev/null || printf '<unset>')"
  done
  git -C "$_d" count-objects -v | sed 's/^/obj /'
}

# Run the gate with the git env a pre-commit hook really receives, aimed at the
# decoy. HEIMDALL_ORACLES_DIR (arg 1, may be empty) selects a throwaway oracle
# tree for [3]. perl alarm stands in for timeout(1), which macOS does not ship.
run_injected() {
  _oracles="$1"; _decoy="$2"; _out="$3"
  (
    export GIT_DIR="$_decoy/.git"
    export GIT_INDEX_FILE="$_decoy/.git/index"
    export GIT_WORK_TREE="$_decoy"
    export GIT_OBJECT_DIRECTORY="$_decoy/.git/objects"
    export GIT_COMMON_DIR="$_decoy/.git"
    export GIT_AUTHOR_NAME="hook-injected"
    export GIT_AUTHOR_EMAIL="hook@injected.invalid"
    export GIT_COMMITTER_NAME="hook-injected"
    export GIT_COMMITTER_EMAIL="hook@injected.invalid"
    export GIT_PREFIX=""
    if [ -n "$_oracles" ]; then export HEIMDALL_ORACLES_DIR="$_oracles"; fi
    perl -e 'alarm shift; exec @ARGV' 300 \
      bash "$FALSIFY" "$DOMAIN" --assert-score 1.0
  ) >"$_out" 2>&1
}

# ── [1] the gate is not FALSE-RED under a hook's git environment ─────────────
printf '[1] gate still scores 1.0000 with GIT_DIR/GIT_INDEX_FILE exported at a decoy repo\n'
DECOY="$TMP/decoy"
make_decoy "$DECOY"
decoy_fingerprint "$DECOY" > "$TMP/fp.before"

out1="$TMP/injected.out"; rc1=0
run_injected "" "$DECOY" "$out1" || rc1=$?

if [ "$rc1" -eq 0 ]; then
  ok "falsify $DOMAIN --assert-score 1.0 exits 0 under injected hook env"
else
  bad "gate went RED under injected hook env (rc=$rc1) — the false-RED is back"
  sed -n '1,40p' "$out1"
fi
if grep -q '1/1 = 1.0000' "$out1"; then
  ok "score line reads 1/1 = 1.0000 (mutant still killed, golden still green)"
else
  bad "no '1/1 = 1.0000' in output under injected hook env"
  grep -E 'SCORE|golden|RESULT' "$out1" || true
fi

# ── [2] the gate wrote NOTHING into the ambient repo ─────────────────────────
printf '[2] the decoy repo is untouched (no init, no config rewrite, no stray commits)\n'
decoy_fingerprint "$DECOY" > "$TMP/fp.after"
if diff -u "$TMP/fp.before" "$TMP/fp.after" > "$TMP/fp.diff" 2>&1; then
  ok "decoy fingerprint identical — refs, config and object store all unchanged"
else
  bad "THE GATE WROTE INTO THE AMBIENT REPO — fixture escaped its temp dir"
  sed -n '1,40p' "$TMP/fp.diff"
fi

# ── [3] the guard is load-bearing: strip it and the gate MUST go RED ─────────
printf '[3] FALSIFIABLE: removing the hermetic guard turns the gate RED again\n'
if grep -qF -e "$GUARD_OPEN" "$HARNESS" && grep -qF -e "$GUARD_CLOSE" "$HARNESS"; then
  ok "harness carries both guard sentinels (mutation target is present)"
else
  bad "guard sentinels missing from $HARNESS — cannot mutate what is not marked"
fi

WORK="$TMP/oracles"
mkdir -p "$WORK"
cp -R "$ORACLE" "$WORK/$DOMAIN"
WEAK="$WORK/$DOMAIN/run.test.sh"

# Delete every line from the opening sentinel through the closing one — this
# restores the exact pre-fix harness, nothing more.
awk -v a="$GUARD_OPEN" -v b="$GUARD_CLOSE" '
  index($0, a) { skip = 1 }
  !skip        { print }
  index($0, b) { skip = 0 }
' "$HARNESS" > "$WEAK"
chmod +x "$WEAK"

orig_lines="$(awk 'END { print NR }' "$HARNESS")"
weak_lines="$(awk 'END { print NR }' "$WEAK")"
if [ "$weak_lines" -lt "$orig_lines" ]; then
  ok "mutation removed the guard ($orig_lines -> $weak_lines lines)"
else
  bad "mutation removed nothing ($orig_lines -> $weak_lines lines) — [3] proves nothing"
fi
if grep -qF -e "$GUARD_OPEN" "$WEAK"; then
  bad "guard still present in the weakened copy"
else
  ok "weakened copy has no hermetic guard"
fi

DECOY2="$TMP/decoy-mutant"
make_decoy "$DECOY2"
decoy_fingerprint "$DECOY2" > "$TMP/fp2.before"

out3="$TMP/weakened.out"; rc3=0
run_injected "$WORK" "$DECOY2" "$out3" || rc3=$?

if [ "$rc3" -ne 0 ]; then
  ok "guard-stripped oracle goes RED under the same env (rc=$rc3) — guard is load-bearing"
else
  bad "guard-stripped oracle STILL passed — the guard is decoration, not a gate"
  sed -n '1,40p' "$out3"
fi

decoy_fingerprint "$DECOY2" > "$TMP/fp2.after"
if diff -q "$TMP/fp2.before" "$TMP/fp2.after" >/dev/null 2>&1; then
  bad "guard-stripped run left the decoy clean — the escape vector is not reproduced"
else
  ok "guard-stripped run demonstrably wrote into the ambient repo (the damage it prevents)"
fi

printf '\n'
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

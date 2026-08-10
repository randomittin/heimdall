#!/usr/bin/env bash
# test/dream-data-root.test.sh — acceptance for DREAM'S RELOCATED DATA ROOT.
#
# THE PROBLEM THIS PROVES SOLVED.
#   The nightly LaunchAgent could not read the repo: macOS TCC denies the launchd JOB
#   any read under ~/Downloads, ~/Documents or ~/Desktop, and a LaunchAgent carries no
#   grant. Measured in 245ede5: a probe agent whose program lived OUTSIDE the protected
#   tree still got LIST_REPO_DIR=DENIED while WRITE_DOTHEIMDALL=OK. So "move the binary"
#   alone is a non-fix — the job dies READING the repo, wherever its program lives.
#
#   The owner's constraint rules out the two known remedies: he will not move the repo
#   and he will not grant Full Disk Access. The third way is to stop needing the repo:
#   dream reads only a handful of .planning state files (audited — no source, no tests,
#   no git history), so that state is relocated under $HEIMDALL_HOME, which is NOT
#   TCC-guarded and IS writable from launchd. The scheduled job then touches nothing
#   under ~/Downloads and needs no grant and no move.
#
# FALSIFIABLE claims proven here:
#   (1)  KEY — the data root is namespaced per repo by a STABLE derived key, so two
#        checkouts cannot blend their routing evidence into one corrupt corpus.
#   (2)  AGREEMENT — the bash and python implementations of that key derive the SAME
#        string. Two languages resolving one path is only safe if pinned by a test.
#   (3)  LOCATION — the resolved state dir is under $HEIMDALL_HOME and NOT under the
#        repo, which is the whole point.
#   (4)  MIGRATION — pre-existing .planning/metrics.jsonl records are carried over, so
#        dream's evidence does not silently reset to empty and go quiet for the wrong
#        reason.
#   (5)  MIGRATION IS ONCE — re-seeding does not duplicate records.
#   (6)  NO REPO READ — with the repo made UNREADABLE, dream still produces its report
#        off the relocated root. This is the acceptance criterion.
#   (7)  NO INTERACTIVE REGRESSION — with a readable repo, the report still lands at
#        <repo>/.planning/dream/<date>.md where a human and git expect it.
#   (8)  DUAL-WRITE — heimdall-metric records reach the relocated root (so the nightly
#        job sees new evidence) AND the repo (so git history is not regressed).
#   (9)  MARKER — the hashed dir names the repo it belongs to, so a human can tell
#        which checkout a key maps to without reversing a hash.
#
# Hermetic: every case runs against a THROWAWAY repo and a THROWAWAY $HEIMDALL_HOME.
# Nothing here touches the real ~/.heimdall, the real LaunchAgents dir, launchctl, the
# crontab, or the keychain.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DREAM="$ROOT/bin/heimdall-dream"
METRIC="$ROOT/bin/heimdall-metric"
PYLIB="$ROOT/bin/lib/dream_data.py"
SHLIB="$ROOT/bin/lib/dream-data.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dream-data-root.XXXXXX")"
cleanup() { chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PY="$(command -v python3 || command -v python)"

# mkrepo <name> — a throwaway repo with a .planning dir.
mkrepo() {
  local r="$TMP/$1"
  mkdir -p "$r/.planning"
  printf '%s' "$r"
}

# newhome <name> — a throwaway $HEIMDALL_HOME.
newhome() {
  local h="$TMP/home-$1"
  mkdir -p "$h"
  printf '%s' "$h"
}

# ── (1) KEY: stable, namespaced, repo-distinguishing ─────────────────────────────
R1="$(mkrepo repo-one)"
R2="$(mkrepo repo-two)"
H="$(newhome key)"

K1="$(HEIMDALL_HOME="$H" "$PY" "$PYLIB" key --repo "$R1" 2>/dev/null || true)"
K1B="$(HEIMDALL_HOME="$H" "$PY" "$PYLIB" key --repo "$R1" 2>/dev/null || true)"
K2="$(HEIMDALL_HOME="$H" "$PY" "$PYLIB" key --repo "$R2" 2>/dev/null || true)"

if [ -n "$K1" ] && [ "$K1" = "$K1B" ]; then
  ok "(1) the repo key is stable across invocations"
else
  bad "(1) the repo key is stable across invocations (got '$K1' then '$K1B')"
fi

if [ -n "$K1" ] && [ -n "$K2" ] && [ "$K1" != "$K2" ]; then
  ok "(1) two different repos derive DIFFERENT keys (evidence cannot blend)"
else
  bad "(1) two different repos derive different keys (got '$K1' and '$K2')"
fi

case "$K1" in
  repo-one-*) ok "(1) the key carries the readable repo basename, not just a hash" ;;
  *)          bad "(1) the key carries the repo basename (got '$K1')" ;;
esac

# ── (2) AGREEMENT: bash and python derive the SAME key ───────────────────────────
BK1="$(HEIMDALL_HOME="$H" bash -c '. "$1"; heimdall_dream_repo_key "$2"' _ "$SHLIB" "$R1" 2>/dev/null || true)"
if [ -n "$BK1" ] && [ "$BK1" = "$K1" ]; then
  ok "(2) bash and python derive the same repo key ('$K1')"
else
  bad "(2) bash and python derive the same repo key (py='$K1' sh='$BK1')"
fi

BP1="$(HEIMDALL_HOME="$H" bash -c '. "$1"; heimdall_dream_planning_dir "$2"' _ "$SHLIB" "$R1" 2>/dev/null || true)"
PP1="$(HEIMDALL_HOME="$H" "$PY" "$PYLIB" planning --repo "$R1" 2>/dev/null || true)"
if [ -n "$BP1" ] && [ "$BP1" = "$PP1" ]; then
  ok "(2) bash and python resolve the same planning dir"
else
  bad "(2) bash and python resolve the same planning dir (py='$PP1' sh='$BP1')"
fi

# ── (3) LOCATION: under $HEIMDALL_HOME, never under the repo ─────────────────────
case "$PP1" in
  "$H"/*) ok "(3) the relocated state dir lives under \$HEIMDALL_HOME" ;;
  *)      bad "(3) the relocated state dir lives under \$HEIMDALL_HOME (got '$PP1')" ;;
esac
case "$PP1" in
  "$R1"/*) bad "(3) the relocated state dir is NOT under the repo (got '$PP1')" ;;
  *)       ok "(3) the relocated state dir is NOT under the repo" ;;
esac

# ── (9) MARKER: the hashed dir names its repo ────────────────────────────────────
HEIMDALL_HOME="$H" "$PY" "$PYLIB" ensure --repo "$R1" >/dev/null 2>&1 || true
MARKER="$(dirname "$PP1")/repo"
# The marker records the PHYSICAL path (symlinks resolved), which on macOS means
# /private/var/... where the test's own $TMPDIR says /var/... — compare like for like.
R1_PHYS="$(cd "$R1" && pwd -P)"
if [ -f "$MARKER" ] && grep -qF "$R1_PHYS" "$MARKER" 2>/dev/null; then
  ok "(9) the hashed data dir records which repo it belongs to"
else
  bad "(9) the hashed data dir records which repo it belongs to (no marker at $MARKER)"
fi

# ── (4)(5) MIGRATION: pre-existing records carried over, exactly once ────────────
R3="$(mkrepo repo-mig)"
H3="$(newhome mig)"
i=1
while [ "$i" -le 7 ]; do
  printf '{"ts":"2026-08-0%sT00:00:00Z","metric":"parallelism","n":%s}\n' "$i" "$i" \
    >> "$R3/.planning/metrics.jsonl"
  i=$((i+1))
done
printf '{"ts":"2026-08-08T00:00:00Z","metric":"task","schema":1,"task_type":"lint","model":"haiku","effort":"default","outcome":"pass","final":"pass","retries":0,"escalated_to":null,"wall_secs":1,"source":"cli","session":"default"}\n' \
  >> "$R3/.planning/metrics.jsonl"

HEIMDALL_HOME="$H3" "$PY" "$PYLIB" ensure --repo "$R3" >/dev/null 2>&1 || true
MIG="$(HEIMDALL_HOME="$H3" "$PY" "$PYLIB" planning --repo "$R3" 2>/dev/null || true)/metrics.jsonl"

if [ -f "$MIG" ] && [ "$(grep -c . "$MIG" 2>/dev/null || printf 0)" = 8 ]; then
  ok "(4) pre-existing metrics records are carried over to the relocated root (8)"
else
  bad "(4) pre-existing metrics carried over (got $(grep -c . "$MIG" 2>/dev/null || printf 0) lines at $MIG)"
fi
if grep -q '"metric":"task"' "$MIG" 2>/dev/null; then
  ok "(4) the carried-over corpus keeps its task records"
else
  bad "(4) the carried-over corpus keeps its task records"
fi

HEIMDALL_HOME="$H3" "$PY" "$PYLIB" ensure --repo "$R3" >/dev/null 2>&1 || true
HEIMDALL_HOME="$H3" "$PY" "$PYLIB" ensure --repo "$R3" >/dev/null 2>&1 || true
if [ "$(grep -c . "$MIG" 2>/dev/null || printf 0)" = 8 ]; then
  ok "(5) re-seeding does not duplicate records (still 8 after 3 ensures)"
else
  bad "(5) re-seeding duplicates records (got $(grep -c . "$MIG" 2>/dev/null || printf 0))"
fi

# ── (8) DUAL-WRITE: the emitter reaches BOTH roots ───────────────────────────────
R4="$(mkrepo repo-emit)"
H4="$(newhome emit)"
# --strict is a TOP-LEVEL flag: it must precede the subcommand or argparse rejects the
# call, and the never-fails contract then turns that into a silent exit 0.
HEIMDALL_HOME="$H4" "$PY" "$METRIC" --strict --repo "$R4" task \
  --type build --model sonnet --outcome pass >/dev/null 2>&1 || true
EMIT_MIRROR="$(HEIMDALL_HOME="$H4" "$PY" "$PYLIB" planning --repo "$R4" 2>/dev/null || true)/metrics.jsonl"

if grep -q '"task_type":"build"' "$EMIT_MIRROR" 2>/dev/null; then
  ok "(8) an emitted metric reaches the relocated root (the nightly job sees it)"
else
  bad "(8) an emitted metric reaches the relocated root ($EMIT_MIRROR)"
fi
if grep -q '"task_type":"build"' "$R4/.planning/metrics.jsonl" 2>/dev/null; then
  ok "(8) an emitted metric ALSO reaches the repo (git history not regressed)"
else
  bad "(8) an emitted metric also reaches the repo"
fi

# ── (7) NO INTERACTIVE REGRESSION: readable repo still reports into .planning ────
R5="$(mkrepo repo-inter)"
H5="$(newhome inter)"
HEIMDALL_HOME="$H5" "$PY" "$DREAM" --repo "$R5" run --date 2026-08-05 >/dev/null 2>&1 || true
if [ -f "$R5/.planning/dream/2026-08-05.md" ]; then
  ok "(7) with a readable repo the report still lands in <repo>/.planning/dream"
else
  bad "(7) with a readable repo the report still lands in <repo>/.planning/dream"
fi

# ── (6) THE ACCEPTANCE: repo UNREADABLE, dream still reports ─────────────────────
# chmod 000 on the .planning dir is the closest a normal test can get to a TCC denial:
# every read and write under it returns EACCES, exactly as TCC returns EPERM. The real
# launchd-context proof lives in test/dream-tcc-resilience.test.sh; this pins the
# behaviour that makes it possible.
R6="$(mkrepo repo-denied)"
H6="$(newhome denied)"
printf '{"ts":"2026-08-01T00:00:00Z","metric":"parallelism","n":1}\n' > "$R6/.planning/metrics.jsonl"
HEIMDALL_HOME="$H6" "$PY" "$PYLIB" ensure --repo "$R6" >/dev/null 2>&1 || true
chmod 000 "$R6/.planning" 2>/dev/null || true

DENIED_OUT="$(HEIMDALL_HOME="$H6" "$PY" "$DREAM" --repo "$R6" run --date 2026-08-06 --json 2>&1 || true)"
DENIED_REPORT="$(HEIMDALL_HOME="$H6" "$PY" "$PYLIB" planning --repo "$R6" 2>/dev/null || true)/dream/2026-08-06.md"
chmod 755 "$R6/.planning" 2>/dev/null || true

if [ -f "$DENIED_REPORT" ]; then
  ok "(6) with the repo UNREADABLE dream still wrote its report to the relocated root"
else
  bad "(6) with the repo unreadable dream still wrote its report (expected $DENIED_REPORT)"
  printf '       output was: %s\n' "$(printf '%s' "$DENIED_OUT" | head -3)"
fi
if grep -q 'Traceback' <<<"$DENIED_OUT"; then
  bad "(6) the unreadable-repo run raised no traceback"
else
  ok "(6) the unreadable-repo run raised no traceback"
fi

printf '\n-----------------------------------\n'
if [ "$FAIL" -eq 0 ]; then
  printf "dream-data-root: \033[32m%d passed\033[0m, %d failed\n" "$PASS" "$FAIL"
else
  printf "dream-data-root: %d passed, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  exit 1
fi

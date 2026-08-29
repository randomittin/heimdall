#!/usr/bin/env bash
#
# presence-tmp-reaper.test.sh — acceptance harness for heimdall-presence's
# _reap_roster_cache_tmps(): orphaned `.roster-cache.json.<pid>.tmp` files must
# be cleaned up, without ever risking the live `.roster-cache.json`, a fresh
# concurrent writer's temp, or any unrelated file.
#
# Why this exists: `<state>/.roster-cache.json` is produced by piping
# `heimdall-presence roster --json` through a caller-side write-to-temp-then-
# rename (sentinels/hmd-statusline.py's _spawn_presence: `roster --json > tmp
# && mv -f tmp cache`). When that shell is hard-killed between the write and
# the rename (a timeout, a killed render, a reboot), the `.tmp` is orphaned
# forever — nothing else ever globs for it. Measured on this repo: hundreds
# accumulated over weeks. bin/heimdall-presence's _reap_roster_cache_tmps
# fixes this, mirroring bin/lib/repo_roster.py's _reap_orphan_tmps() (age is
# the PRIMARY discriminator, a kill -0 liveness check on the embedded pid is
# only a secondary guard under the age floor).
#
# Proofs (all runnable):
#   1. OLD ORPHAN REAPED — a .tmp older than the 120s floor is removed, even
#      when its embedded pid is still alive (age dominates liveness).
#   2. FRESH TEMP PRESERVED — a .tmp younger than the floor, owned by a live
#      pid, survives. The concurrency-safety case that matters most.
#   3. REAL CACHE UNTOUCHED — .roster-cache.json survives byte-for-byte.
#   4. UNRELATED FILES SURVIVE — wrong base name, wrong suffix, unrelated file.
#   5. UNWRITABLE / MISSING DIR — no crash; presence still completes.
#   6. RED-PROOF (reaper disabled) — with _reap_roster_cache_tmps neutered in
#      a scratch copy, proof 1's assertion FLIPS to failing.
#   7. RED-PROOF (age floor widened to 0) — with the floor forced to 0 in a
#      scratch copy, proof 2's assertion FLIPS to failing.
#
# Hermetic: every fixture lives under a throwaway $TMPDIR workspace with a
# fake $HOME and a fake per-repo state dir (HEIMDALL_PRESENCE_DIR). The live
# repo's own accumulated orphan files under .heimdall/ are never touched by
# this suite — that cleanup is a separate, explicit one-off command.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-presence"
. "$REPO/test/lib/net-default-guard.sh"

[ -x "$BIN" ] || { echo "FATAL: heimdall-presence not executable at $BIN"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d -t "presence-tmp-reaper.XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT INT TERM
export HMD_AUTO_TEAM_DISABLE=1

# Fake-but-well-formed identity so the CLI's own offline-degrade guard
# (`[ -z "$URL" ] || [ -z "$HAID" ] || [ -z "$PROJECT" ]` -> emit_empty_roster;
# exit 0, BEFORE the reaper's call site) does not short-circuit before the
# reaper ever runs. --url is pinned at the guard's own dead discard port, so
# even with a "configured" identity the wire call fails fast/local, never prod.
TEST_HAID="hmd-test-haid-0000"
TEST_PROJECT="presence-tmp-reaper-test"
TEST_URL="${HEIMDALL_DEFAULT_CP_URL}"

# bound SECS -- cmd   (macOS has no `timeout`). The reaper runs synchronously
# BEFORE run_client's wire attempt, so this only guards the wire call's own
# path — belt-and-suspenders alongside the net-default-guard's dead port.
bound() {
  local secs="$1"; shift; [ "$1" = "--" ] && shift
  "$@" & local p=$!
  ( sleep "$secs"; kill -9 "$p" 2>/dev/null ) & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null || true
  return $rc
}

# _set_mtime_ago FILE SECS — backdate FILE's mtime by SECS. Mirrors
# heimdall-presence's own _stamp_mtime dual-path idiom (BSD `date -r` / GNU
# `date -d`) so this works on both macOS and Linux.
_set_mtime_ago() {
  local file="$1" secs="$2" epoch ts
  epoch=$(( $(date +%s) - secs ))
  ts="$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S)"
  touch -t "$ts" "$file"
}

# _make_scratch_bin NAME SED_EXPR — build a mutated scratch copy of heimdall-presence
# inside a bin/-shaped directory, with bin/lib symlinked to the REAL lib dir, never as
# a bare loose file. heimdall-presence resolves its sibling lib dir relative to its OWN
# path (SELF_DIR -> $REPO/bin/lib, the only $REPO use in the whole script); a bare-file
# copy breaks that resolution, which trips the unrelated offline-degrade guard
# (`[ -f "$LIB/cp_auth.py" ] || ... emit_empty_roster`) before the mutation under test
# ever runs — masking the real result and silently invalidating the red-proof. Echoes
# the scratch binary's path.
_make_scratch_bin() {
  # NOTE: `dir` must NOT be assigned in the same `local` as `name` -- referencing
  # $name inside the very declaration that creates it is unbound under `set -u`,
  # which silently aborted the mutation and made both red-proofs meaningless.
  local name="$1" sed_expr="$2"
  local dir="$WORK/scratch-$name"
  mkdir -p "$dir/bin"
  ln -s "$REPO/bin/lib" "$dir/bin/lib"
  sed "$sed_expr" "$BIN" > "$dir/bin/heimdall-presence"
  chmod +x "$dir/bin/heimdall-presence"
  echo "$dir/bin/heimdall-presence"
}

# run_roster STATE_DIR [OUTFILE] [BIN_PATH] — invoke the real `roster`
# subcommand (whose first act, on this code path, is the reaper) against a
# fully sandboxed HOME + per-repo state dir. Exit code is intentionally
# ignored by callers: only the resulting filesystem state under STATE_DIR is
# ever asserted on.
run_roster() {
  local state_dir="$1" outfile="${2:-/dev/null}" bin_path="${3:-$BIN}" fake_home="$WORK/home"
  mkdir -p "$fake_home"
  bound 8 -- env HOME="$fake_home" HEIMDALL_PRESENCE_DIR="$state_dir" HMD_AUTO_TEAM_DISABLE=1 \
    "$bin_path" roster --json --haid "$TEST_HAID" --project "$TEST_PROJECT" --url "$TEST_URL" \
    >"$outfile" 2>&1
}

echo "── 1. OLD ORPHAN REAPED (age dominates a still-alive pid) ──"
D1="$WORK/case1"; mkdir -p "$D1"
OLD_TMP="$D1/.roster-cache.json.$$.tmp"
echo '{"stale":true}' > "$OLD_TMP"
_set_mtime_ago "$OLD_TMP" 300   # 300s > the 120s floor
run_roster "$D1"
if [ ! -e "$OLD_TMP" ]; then ok "old orphan (300s old, live pid) is reaped"; else bad "old orphan survived: $OLD_TMP"; fi

echo
echo "── 2. FRESH TEMP PRESERVED (the concurrency-safety case that matters most) ──"
D2="$WORK/case2"; mkdir -p "$D2"
FRESH_TMP="$D2/.roster-cache.json.$$.tmp"
echo '{"inflight":true}' > "$FRESH_TMP"   # mtime = now, pid = $$ (alive for the whole test)
run_roster "$D2"
if [ -e "$FRESH_TMP" ]; then ok "fresh temp (age~0, live pid) is preserved"; else bad "fresh temp was reaped: $FRESH_TMP"; fi

echo
echo "── 3. REAL CACHE UNTOUCHED (byte-for-byte) ──"
D3="$WORK/case3"; mkdir -p "$D3"
REAL_CACHE="$D3/.roster-cache.json"
printf '[{"handle":"vader","haid":"h1","verdict":"working"}]' > "$REAL_CACHE"
cp "$REAL_CACHE" "$WORK/case3-before.json"
echo 'orphan' > "$D3/.roster-cache.json.$$.tmp"
_set_mtime_ago "$D3/.roster-cache.json.$$.tmp" 300
run_roster "$D3"
if cmp -s "$REAL_CACHE" "$WORK/case3-before.json"; then
  ok "real .roster-cache.json survives byte-identical"
else
  bad "real .roster-cache.json was modified"
fi

echo
echo "── 4. UNRELATED FILES SURVIVE ──"
D4="$WORK/case4"; mkdir -p "$D4"
U1="$D4/.wall-cache.json.$$.tmp"        # different base name entirely
U2="$D4/.roster-cache.json.backup"      # right base, wrong suffix
U3="$D4/notes.txt"                      # unrelated file
for u in "$U1" "$U2" "$U3"; do echo x > "$u"; _set_mtime_ago "$u" 300; done
run_roster "$D4"
SURVIVED=1
for u in "$U1" "$U2" "$U3"; do [ -e "$u" ] || SURVIVED=0; done
if [ "$SURVIVED" -eq 1 ]; then ok "unrelated files (wrong base name / wrong suffix) untouched"; else bad "an unrelated file was incorrectly removed"; fi

echo
echo "── 5. UNWRITABLE / MISSING DIR — no crash, presence still completes ──"
OUT5A="$WORK/case5a.out"
run_roster "$WORK/does-not-exist" "$OUT5A"
if grep -qiE "unbound variable|bad substitution|syntax error|command not found" "$OUT5A"; then
  bad "missing state dir: script-fatal error present: $(grep -iE 'unbound variable|bad substitution|syntax error|command not found' "$OUT5A" | head -1)"
else
  ok "missing state dir: no crash, no script-fatal error"
fi

D5B="$WORK/case5b"; mkdir -p "$D5B"
LOCKED_TMP="$D5B/.roster-cache.json.$$.tmp"
echo x > "$LOCKED_TMP"; _set_mtime_ago "$LOCKED_TMP" 300
chmod 555 "$D5B"
OUT5B="$WORK/case5b.out"
run_roster "$D5B" "$OUT5B"
chmod 755 "$D5B"
if grep -qiE "unbound variable|bad substitution|syntax error|command not found" "$OUT5B"; then
  bad "unwritable dir: script-fatal error present: $(grep -iE 'unbound variable|bad substitution|syntax error|command not found' "$OUT5B" | head -1)"
else
  ok "unwritable dir: no crash (failed unlink fails open)"
fi

echo
echo "── 6. RED-PROOF: disabling the reaper flips proof 1 to FAILING ──"
DISABLED_BIN="$(_make_scratch_bin disabled 's/^_reap_roster_cache_tmps() {$/_reap_roster_cache_tmps() { return 0; #DISABLED-FOR-TEST/')"
if grep -q 'DISABLED-FOR-TEST' "$DISABLED_BIN"; then
  ok "mutation applied: reaper neutered in the scratch copy"
else
  bad "mutation did not apply to the scratch copy — red-proof is not meaningful"
fi
D6="$WORK/case6"; mkdir -p "$D6"
OLD_TMP6="$D6/.roster-cache.json.$$.tmp"
echo x > "$OLD_TMP6"; _set_mtime_ago "$OLD_TMP6" 300
run_roster "$D6" /dev/null "$DISABLED_BIN"
if [ -e "$OLD_TMP6" ]; then
  ok "RED-PROOF: reaper disabled -> old orphan survives (proof 1 correctly goes RED)"
else
  bad "RED-PROOF FAILED: old orphan was reaped even with the reaper disabled — proof 1 is not falsifiable"
fi

echo
echo "── 7. RED-PROOF: widening the age floor to 0 flips proof 2 to FAILING ──"
AGE0_BIN="$(_make_scratch_bin age0 's/^_ROSTER_TMP_ORPHAN_AGE_S=120.*/_ROSTER_TMP_ORPHAN_AGE_S=0/')"
if grep -q '^_ROSTER_TMP_ORPHAN_AGE_S=0$' "$AGE0_BIN"; then
  ok "mutation applied: age floor widened to 0 in the scratch copy"
else
  bad "mutation did not apply to the scratch copy — red-proof is not meaningful"
fi
D7="$WORK/case7"; mkdir -p "$D7"
FRESH_TMP7="$D7/.roster-cache.json.$$.tmp"
echo x > "$FRESH_TMP7"   # age ~0, live pid ($$)
run_roster "$D7" /dev/null "$AGE0_BIN"
if [ ! -e "$FRESH_TMP7" ]; then
  ok "RED-PROOF: age floor=0 -> fresh temp is reaped (proof 2 correctly goes RED)"
else
  bad "RED-PROOF FAILED: fresh temp survived even with age floor=0 — proof 2 is not falsifiable"
fi

echo
echo "──────────────────────────────────────────"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
# run-all-guards.test.sh -- proves the two things test/run-all.sh does about the machine (handoff 2026-10-11):
#
#   1. THE QUIET GATE (--wait-quiet, test/lib/run-all-guards.sh hmd_test_wait_quiet) can always open: the threshold is
#      relative to the cpu count, the wait is bounded, and when the bound passes the sweep runs anyway with half the
#      jobs. The old gate (15-min load < an absolute 15, three checks) never opened on a 10-core box with three
#      long-lived sessions: load sat at ~55 for five hours.
#   2. NOTHING LEAKS PAST A SUITE: timeout_run kills whatever a suite left in its own process group the moment the suite
#      ends (the dashboards suite left 14 hmd ui servers that way), records it, and the end-of-sweep guard names the
#      suites and asserts no hmd server on a temp repo survives.
#
# The functions are taken from the REAL run-all.sh (sed-extracted, never copied) and driven directly: a `sysctl` shim on PATH
# supplies the load average and cpu count.
#
# Usage:  bash test/run-all-guards.test.sh        bash 3.2 compatible.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
RUNALL="$REPO/test/run-all.sh"
LIB="$REPO/test/lib/run-all-guards.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/run-all-guards.XXXXXX")"; T="$(cd "$T" && pwd -P)"
MARK="runallguards$$"
cleanup() { pkill -f "$MARK" 2>/dev/null || true; pkill -f "$T/fake/" 2>/dev/null || true; sleep 0.2; pkill -9 -f "$T/fake/" 2>/dev/null || true; rm -f "/tmp/$MARK-hardcoded.dat"; chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "run-all-guards (--wait-quiet gate, process-group sweep per suite, end-of-sweep orphan guard)"
[ -f "$LIB" ] || { bad "test/lib/run-all-guards.sh is missing"; printf '\nrun-all-guards: %s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }

eval "$(sed -n '/^_load_avg() {/,/^}/p' "$RUNALL")"
eval "$(sed -n '/^timeout_run() {/,/^}/p' "$RUNALL")"
# shellcheck source=lib/run-all-guards.sh disable=SC1091
. "$LIB"

mkdir -p "$T/shim"
cat > "$T/shim/sysctl" <<'SHIM_EOF'
#!/bin/sh
case "$*" in
  "-n vm.loadavg") printf '{ %s }\n' "$(cat "$SHIM_LOAD_FILE")" ;;
  "-n hw.ncpu") echo 10 ;;
  *) exit 1 ;;
esac
SHIM_EOF
chmod +x "$T/shim/sysctl"
export SHIM_LOAD_FILE="$T/load"
gate() { # LOAD15 [env...] -> "<gate output>|outcome=.. jobs=.. reduced=.. secs=.."
  local l15="$1"; shift
  echo "1.00 2.00 $l15" > "$T/load"
  ( export PATH="$T/shim:$PATH"; NCPU=10 JOBS=6; export HMD_QUIET_POLL_S=0 HMD_QUIET_MAX_WAIT_S=2; for kv in "$@"; do export "$kv"; done
    s0=$(date +%s); hmd_test_wait_quiet >"$T/gate.out"; s1=$(date +%s)
    printf '%s|outcome=%s jobs=%s reduced=%s secs=%s' "$(cat "$T/gate.out")" "$QUIET_GATE_OUTCOME" "$JOBS" "${HMD_TEST_REDUCED_PARALLELISM:-}" "$((s1 - s0))" )
}

echo "-- 1. the quiet gate: relative, bounded, and it always opens --"
R="$(gate 5.00)"
case "$R" in *"machine quiet"*"outcome=quiet jobs=6 reduced= "*) ok "15-min load 5 on 10 cores (< 1.5 x 10): quiet on 3 consecutive checks, jobs untouched" ;; *) bad "low load: $R" ;; esac
R="$(gate 14.00)"
case "$R" in *"outcome=quiet jobs=6"*) ok "load 14 < 15.0 (1.5 x 10 cores): quiet" ;; *) bad "load 14: $R" ;; esac
R="$(gate 55.00 HMD_QUIET_MAX_WAIT_S=2 HMD_QUIET_POLL_S=0.2)"
case "$R" in *"gave up"*"outcome=timeout jobs=3 reduced=1 "*) ok "load stuck at 55 (the measured box): gives up after the bound, halves jobs 6 -> 3, exports HMD_TEST_REDUCED_PARALLELISM=1" ;; *) bad "stuck load: $R" ;; esac
SECS="${R##*secs=}"
if [ "$SECS" -ge 2 ] && [ "$SECS" -lt 15 ]; then ok "the bound is honoured: waited ${SECS}s for a 2s limit (not forever)"; else bad "waited ${SECS}s for a 2s limit"; fi
R="$(gate 55.00 HMD_QUIET_LOAD15_MAX=60)"
case "$R" in *"outcome=quiet jobs=6"*) ok "HMD_QUIET_LOAD15_MAX pins an absolute threshold (55 < 60: quiet)" ;; *) bad "absolute override: $R" ;; esac
R="$(gate 55.00 HMD_QUIET_FACTOR=6)"
case "$R" in *"outcome=quiet jobs=6"*) ok "HMD_QUIET_FACTOR scales the relative threshold (6 x 10 = 60 > 55: quiet)" ;; *) bad "factor override: $R" ;; esac
echo "1.00 2.00 55.00" > "$T/load"
( sleep 1; echo "1.00 2.00 3.00" > "$T/load" ) &
R="$( export PATH="$T/shim:$PATH"; NCPU=10 JOBS=6 HMD_QUIET_POLL_S=0.2 HMD_QUIET_MAX_WAIT_S=20; hmd_test_wait_quiet >"$T/gate.out"; printf '%s|outcome=%s jobs=%s' "$(cat "$T/gate.out")" "$QUIET_GATE_OUTCOME" "$JOBS" )"
wait
case "$R" in *"outcome=quiet jobs=6"*) ok "load that drops while waiting opens the gate (no reduction)" ;; *) bad "load drop: $R" ;; esac
R="$( export PATH="$T/shim:$PATH"; NCPU=""; JOBS=6; hmd_test_wait_quiet >"$T/gate.out"; printf '%s|outcome=%s' "$(cat "$T/gate.out")" "$QUIET_GATE_OUTCOME" )"
case "$R" in *"not waiting"*"outcome=unreadable") ok "an unknown cpu count never blocks the sweep" ;; *) bad "unknown cpu: $R" ;; esac

echo "-- 2. timeout_run kills what a suite left in its process group --"
export RUN_ALL_LEAK_FILE="$T/leak"; : > "$T/leak"
timeout_run 60 bash -c '( exec -a '"$MARK"'-sleeper sleep 300 ) & sleep 0.3; exit 3'; RC=$?
i=0; while pgrep -f "$MARK-sleeper" >/dev/null 2>&1 && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if [ "$RC" -eq 3 ]; then ok "the suite's own exit status survives the sweep (3)"; else bad "exit status was $RC, want 3"; fi
if ! pgrep -f "$MARK-sleeper" >/dev/null 2>&1; then ok "a process the suite left running in its group is dead when the suite ends"; else bad "the leaked sleeper survived"; fi
if grep -q "$MARK-sleeper" "$T/leak"; then ok "the leak is recorded in RUN_ALL_LEAK_FILE (so the sweep can name the suite)"; else bad "leak file: $(cat "$T/leak")"; fi
: > "$T/leak"
timeout_run 60 bash -c 'exit 0'; RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$T/leak" ]; then ok "a suite that leaves nothing behind: exit 0, nothing recorded"; else bad "clean suite rc=$RC leak=$(cat "$T/leak")"; fi
timeout_run 1 bash -c 'sleep 30'; RC=$?
if [ "$RC" -eq 124 ]; then ok "a timeout is still exit 124"; else bad "timeout exit $RC, want 124"; fi
unset RUN_ALL_LEAK_FILE

echo "-- 3. the end-of-sweep guard --"
FAKE="$T/fake"; TMPR="$T/tmp"; mkdir -p "$FAKE/sentinels" "$TMPR/repo/.git" "$T/work"
cat > "$FAKE/sentinels/hmd-ui.py" <<'PYEOF'
import socket, sys, time
port = int(sys.argv[sys.argv.index("--port") + 1])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(5)
time.sleep(600)
PYEOF
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
( python3 "$FAKE/sentinels/hmd-ui.py" --repo "$TMPR/repo" --port "$PORT" --no-open >/dev/null 2>&1 & )
i=0; while ! { : <>"/dev/tcp/127.0.0.1/$PORT"; } 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
UI_PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p\([0-9][0-9]*\)$/\1/p' | head -1)"
RUN=("$T/a.test.sh" "$T/b.test.sh"); TO_RUN=2; WORK="$T/work"; printf '123 456 sleep 300\n' > "$WORK/1.leaked"
OUT="$(HMD_UI_PROCS_SCRIPT_ROOT="$FAKE" HMD_UI_PROCS_TMP_ROOTS="$TMPR" hmd_test_orphan_guard "$REPO" "$WORK")"
if printf '%s' "$OUT" | grep -q "b.test.sh" && ! printf '%s' "$OUT" | grep -q "a.test.sh"; then ok "the guard names the suite whose process group held a leak, and only that one"; else bad "guard output: $OUT"; fi
if printf '%s' "$OUT" | grep -q "reaped ui pid=$UI_PID" && ! kill -0 "$UI_PID" 2>/dev/null; then ok "an hmd ui still running on a temp repo at the end of the sweep is reaped and reported"; else bad "ui survived the guard: $OUT"; fi
HMD_UI_PROCS_SCRIPT_ROOT="$FAKE" HMD_UI_PROCS_TMP_ROOTS="$TMPR" hmd_test_orphan_guard "$REPO" "$WORK" >/dev/null
if [ "$ORPHAN_SURVIVORS" = 0 ]; then ok "ORPHAN_SURVIVORS is 0 once everything is gone"; else bad "ORPHAN_SURVIVORS=$ORPHAN_SURVIVORS"; fi
rm -f "$WORK/1.leaked"
OUT="$(HMD_UI_PROCS_SCRIPT_ROOT="$FAKE" HMD_UI_PROCS_TMP_ROOTS="$TMPR" hmd_test_orphan_guard "$REPO" "$WORK")"
if [ -z "$OUT" ]; then ok "a clean sweep prints nothing at all (output byte-identical to before the guard)"; else bad "clean sweep printed: $OUT"; fi

echo "-- 4. wiring in run-all.sh --"
for needle in '--wait-quiet)' 'hmd_test_wait_quiet' 'hmd_test_orphan_guard' 'RUN_ALL_LEAK_FILE="$WORK/$idx.leaked" timeout_run' 'ORPHAN_SURVIVORS'; do
  if grep -qF -- "$needle" "$RUNALL"; then ok "run-all.sh carries: $needle"; else bad "run-all.sh is missing: $needle"; fi
done
if bash -n "$RUNALL" 2>/dev/null; then ok "run-all.sh still parses"; else bad "run-all.sh no longer parses"; fi

echo "-- 5. every suite gets its own TMPDIR: measured once the suite is gone, then removed (hmd_test_tmp_begin / hmd_test_suite_tmp_settle) --"
# 2026-10-13: free space dropped 1.6 GB while agents ran suites; a suite's mktemp leftovers now land in a private dir the runner empties.
unset HMD_TEST_STRICT_TMP HMD_TEST_TMP_LEAK_MAX_MB HMD_TEST_TMP_WATCH
mkdir -p "$T/rt" "$T/work"; TMP_ROOT=""
TMPDIR="$T/rt" hmd_test_tmp_begin "$T/work"
if [ -n "${TMP_ROOT:-}" ] && [ -d "${TMP_ROOT:-/nonexistent}" ] && [ "$(dirname "${TMP_ROOT:-/}")" = "$T/rt" ]; then ok "one run-level temp root is made under the runner's TMPDIR"; else bad "temp root: '${TMP_ROOT:-}'"; fi
mkdir -p "${TMP_ROOT:-$T/rt/none}/0" "${TMP_ROOT:-$T/rt/none}/1" "${TMP_ROOT:-$T/rt/none}/2"
: > "$T/leak-clean"; : > "$T/leak-leaky"; : > "$T/leak-bg"
TMPDIR="$TMP_ROOT/0" timeout_run 60 bash -c 'd="$(mktemp -d)" || exit 1; echo x > "$d/f"; rm -rf "$d"; exit 0'
hmd_test_suite_tmp_settle "$TMP_ROOT/0" "$T/leak-clean"
if [ ! -e "$TMP_ROOT/0" ] && [ ! -s "$T/leak-clean" ]; then ok "a suite that removes what it makes: nothing recorded, its TMPDIR is gone"; else bad "clean suite: left=$(cat "$T/leak-clean")"; fi
TMPDIR="$TMP_ROOT/1" timeout_run 60 bash -c 'd="$(mktemp -d)" || exit 1; dd if=/dev/zero of="$d/blob" bs=1048576 count=3 2>/dev/null; mkdir -p "$d/ro/sub"; : > "$d/ro/sub/f"; chmod 555 "$d/ro/sub" "$d/ro"; exit 0'
hmd_test_suite_tmp_settle "$TMP_ROOT/1" "$T/leak-leaky"
IFS=$'\t' read -r LB LE LS < "$T/leak-leaky"
if [ "${LB:-0}" -ge 3145728 ] && [ "${LE:-0}" = 1 ] && [ -n "${LS:-}" ]; then ok "a leaky suite's mktemp landed in ITS dir: ${LB} bytes in ${LE} top-level entry (${LS})"; else bad "leaky record: '$(cat "$T/leak-leaky")'"; fi
if [ ! -e "$TMP_ROOT/1" ]; then ok "the leftover is removed -- a read-only (chmod 555) subtree included"; else bad "leaky dir survived: $(ls -A "$TMP_ROOT/1")"; fi
cat > "$T/bg-suite.sh" <<'BGEOF'
( exec -a "$BG_MARK-writer" bash -c 'while :; do echo x >> "$TMPDIR/bg.log"; sleep 0.05; done' ) &
sleep 0.3
exit 0
BGEOF
BG_MARK="$MARK" TMPDIR="$TMP_ROOT/2" timeout_run 60 bash "$T/bg-suite.sh"
if pgrep -f "$MARK-writer" >/dev/null 2>&1; then bad "the suite's background writer outlived timeout_run -- the settle would race it"; else ok "the process group is reaped FIRST (timeout_run returns only after it), so nothing still writes when the dir is measured"; fi
hmd_test_suite_tmp_settle "$TMP_ROOT/2" "$T/leak-bg"; sleep 0.3
if [ ! -e "$TMP_ROOT/2" ] && [ -s "$T/leak-bg" ]; then ok "what the reaped writer left (bg.log) is recorded, the dir is removed, and nothing re-populates it"; else bad "bg dir: exists=$([ -e "$TMP_ROOT/2" ] && echo yes || echo no) record='$(cat "$T/leak-bg")'"; fi
mkdir -p "$T/not-mine/x"; : > "$T/leak-x"
hmd_test_suite_tmp_settle "$T/not-mine" "$T/leak-x"
if [ -d "$T/not-mine/x" ] && [ ! -s "$T/leak-x" ]; then ok "settle only ever touches a directory inside this run's temp root (a stray path is left alone)"; else bad "settle removed or recorded a path outside the root"; fi

echo "-- 6. end-of-sweep tmp guard: limit, strict mode, outside-TMPDIR attribution --"
GW="$T/gwork"; mkdir -p "$GW" "$T/watch"
RUN=("$T/a.test.sh" "$T/b.test.sh" "$T/c.test.sh"); TO_RUN=3
printf '5242880\t1\tfat-dir\n' > "$GW/0.tmpleak"; printf '1024\t2\tx,y\n' > "$GW/1.tmpleak"
hmd_test_tmp_guard "$GW" >/dev/null
if [ "${TMP_FINDINGS:-x}" = 0 ] && [ "${TMP_LEAK_SUITES:-x}" = 2 ] && [ "${TMP_LEAK_BYTES:-x}" = 5243904 ] && grep -q 'TMP LEFTOVERS (2)' "$GW/tmp-section.txt" && ! grep -q 'TMP LEAK' "$GW/tmp-section.txt"; then ok "default limit (50 MB): a 5 MB and a 1 KB leftover are warnings, neither fails the run"; else bad "default policy: findings=${TMP_FINDINGS:-} suites=${TMP_LEAK_SUITES:-} bytes=${TMP_LEAK_BYTES:-} section=$(cat "$GW/tmp-section.txt")"; fi
HMD_TEST_TMP_LEAK_MAX_MB=1 hmd_test_tmp_guard "$GW" >/dev/null
if [ "${TMP_FINDINGS:-x}" = 1 ] && grep -q 'TMP LEAK (1)' "$GW/tmp-section.txt" && grep -q 'a.test.sh' "$GW/tmp-section.txt" && grep -q 'TMP LEFTOVERS (1)' "$GW/tmp-section.txt"; then ok "over HMD_TEST_TMP_LEAK_MAX_MB (5 MB > 1 MB): that suite is the one finding and is named; the 1 KB one stays a warning"; else bad "limit policy: findings=${TMP_FINDINGS:-} section=$(cat "$GW/tmp-section.txt")"; fi
HMD_TEST_STRICT_TMP=1 hmd_test_tmp_guard "$GW" >/dev/null
if [ "${TMP_FINDINGS:-x}" = 2 ] && grep -q 'TMP LEAK (2)' "$GW/tmp-section.txt"; then ok "HMD_TEST_STRICT_TMP=1: any leftover at all fails, even 1 KB"; else bad "strict policy: findings=${TMP_FINDINGS:-} section=$(cat "$GW/tmp-section.txt")"; fi
rm -f "$GW"/*.tmpleak
hmd_test_tmp_guard "$GW" >/dev/null
if [ "${TMP_FINDINGS:-x}" = 0 ] && [ "${TMP_LEAK_SUITES:-x}" = 0 ] && grep -q '^tmp dirs: *clean' "$GW/tmp-summary.txt" && [ ! -s "$GW/tmp-section.txt" ]; then ok "no leftovers: the summary says clean, there is no section, nothing fails"; else bad "clean policy: findings=${TMP_FINDINGS:-} summary=$(cat "$GW/tmp-summary.txt")"; fi
HMD_TEST_TMP_WATCH="$T/watch" TMPDIR="$T/rt" hmd_test_tmp_begin "$GW"
mkdir "$T/watch/hit-dir"; echo x > "$T/watch/hit-file"; mkdir "$T/watch/old-foreign"; touch -t 200001010000 "$T/watch/old-foreign"
NOW="$(date +%s)"; echo "$((NOW - 5))" > "$GW/0.t0"; echo "$((NOW + 5))" > "$GW/0.t1"; echo "$((NOW - 500))" > "$GW/1.t0"; echo "$((NOW - 400))" > "$GW/1.t1"
HMD_TEST_TMP_WATCH="$T/watch" hmd_test_tmp_guard "$GW" >/dev/null
HITS="$(awk -F'\t' '$1 ~ /hit-/ && $4 == "a.test.sh"' "$GW/tmp-outside.tsv" | wc -l | tr -d ' ')"
if [ "$HITS" = 2 ] && ! grep -q 'old-foreign' "$GW/tmp-outside.tsv" && ! grep -q 'b.test.sh' "$GW/tmp-outside.tsv" && [ "${TMP_OUTSIDE_COUNT:-x}" = 2 ]; then ok "new entries outside TMPDIR are attributed to the suite running when they were written (mtime window); one no suite was running for is not"; else bad "outside attribution: hits=$HITS count=${TMP_OUTSIDE_COUNT:-} tsv=$(cat "$GW/tmp-outside.tsv")"; fi
if [ "${TMP_FINDINGS:-x}" = 0 ] && grep -q 'TMP OUTSIDE TMPDIR (2)' "$GW/tmp-section.txt" && grep -q '^tmp outside: *2 new' "$GW/tmp-summary.txt"; then ok "outside-TMPDIR entries are a loud warning by default (cannot be proved the suite's), not a failure"; else bad "outside default: findings=${TMP_FINDINGS:-} section=$(cat "$GW/tmp-section.txt")"; fi
HMD_TEST_STRICT_TMP=1 HMD_TEST_TMP_WATCH="$T/watch" hmd_test_tmp_guard "$GW" >/dev/null
if [ "${TMP_FINDINGS:-x}" = 2 ]; then ok "HMD_TEST_STRICT_TMP=1 turns the attributed outside entries into findings"; else bad "outside strict: findings=${TMP_FINDINGS:-}"; fi

echo "-- 7. through the REAL run-all.sh (fixture repo): own TMPDIR per suite, receipt, summary line, exit status --"
FX="$T/fx"; mkdir -p "$FX/test/lib" "$FX/bin/lib" "$T/hh" "$T/watch2" "$T/ert"
cp "$RUNALL" "$FX/test/run-all.sh"; cp "$LIB" "$FX/test/lib/run-all-guards.sh"; cp "$REPO/bin/lib/hook-owned-path.sh" "$FX/bin/lib/hook-owned-path.sh"
git -C "$FX" init -q >/dev/null 2>&1; git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q --no-verify -m fixture >/dev/null 2>&1
fx_run() { # [K=V ...] -- one fixture sweep, output in $T/fx.out; exit status is the sweep's
  ( cd "$FX" && env -u HMD_TEST_STRICT_TMP -u HMD_TEST_TMP_LEAK_MAX_MB -u HMD_TEST_TMP_WATCH TMPDIR="$T/ert" HEIMDALL_HOME="$T/hh" "$@" bash "$FX/test/run-all.sh" --min 1 --jobs 2 --no-retry > "$T/fx.out" 2>&1 )
}
cat > "$FX/test/clean.test.sh" <<'EOF'
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT; echo x > "$d/f"
case "$TMPDIR" in */hmd-ra.*/[0-9]*) echo "clean: 1 passed, 0 failed." ;; *) echo "clean: 0 passed, 1 failed. (TMPDIR=$TMPDIR)"; exit 1 ;; esac
EOF
cat > "$FX/test/leaky.test.sh" <<'EOF'
d="$(mktemp -d)"; dd if=/dev/zero of="$d/blob" bs=1048576 count=3 2>/dev/null
mkdir -p "$d/ro/sub"; : > "$d/ro/sub/f"; chmod 555 "$d/ro/sub" "$d/ro"
echo "leaky: 1 passed, 0 failed."
EOF
sed "s#@MARK@#$MARK#g" > "$FX/test/outside.test.sh" <<'EOF'
printf 'x' > "/tmp/@MARK@-hardcoded.dat"
echo "outside: 1 passed, 0 failed."
EOF
fx_run; RC=$?
RCPT="$T/hh/receipts/last-sweep.json"
if [ "$RC" -eq 0 ] && grep -q 'RUN GREEN' "$T/fx.out"; then ok "default limit: a 3 MB leftover and an outside write are reported, the sweep stays green (and clean.test.sh saw its own TMPDIR)"; else bad "default sweep rc=$RC: $(tail -25 "$T/fx.out")"; fi
if grep -qE '^tmp dirs: +1 suite\(s\) left [0-9.]+ MB in their own TMPDIR \(removed\); 0 over the 50 MB limit' "$T/fx.out" && grep -qE '^  leaky\.test\.sh +[0-9.]+ MB in 1 entry' "$T/fx.out"; then ok "the summary line and the leftover table name the leaky suite (and only it)"; else bad "summary: $(grep -E 'tmp |leaky' "$T/fx.out")"; fi
if jq -e '.tmp_leaks | length == 1 and .[0].suite == "leaky.test.sh" and .[0].bytes >= 3145728 and .[0].entries >= 1' "$RCPT" >/dev/null 2>&1; then ok "receipt tmp_leaks = [{suite: leaky.test.sh, bytes >= 3 MB, entries >= 1}]"; else bad "receipt tmp_leaks: $(jq -c .tmp_leaks "$RCPT" 2>&1)"; fi
if grep -q "$MARK-hardcoded" "$T/fx.out" && jq -e --arg m "$MARK-hardcoded" '.tmp_outside | map(select((.path | contains($m)) and (.suites | index("outside.test.sh")))) | length == 1' "$RCPT" >/dev/null 2>&1; then ok "a hard-coded /tmp write is caught, attributed to outside.test.sh, printed and in the receipt (tmp_outside)"; else bad "outside: $(grep -E 'outside|hardcoded' "$T/fx.out") receipt=$(jq -c .tmp_outside "$RCPT" 2>&1)"; fi
if [ -z "$(ls -A "$T/ert")" ]; then ok "after the sweep nothing is left under the runner's TMPDIR: every suite's dir and the temp root are gone"; else bad "left under TMPDIR: $(ls -A "$T/ert")"; fi
rm -f "$FX/test/outside.test.sh"
fx_run HMD_TEST_TMP_LEAK_MAX_MB=1; RC=$?
if [ "$RC" -eq 1 ] && grep -q 'TMP LEAK (1)' "$T/fx.out" && grep -q 'RUN RED' "$T/fx.out" && jq -e '.exit_code == 1' "$RCPT" >/dev/null 2>&1; then ok "a leftover over HMD_TEST_TMP_LEAK_MAX_MB fails the sweep (exit 1, RUN RED, receipt exit_code 1)"; else bad "limit sweep rc=$RC: $(tail -20 "$T/fx.out")"; fi
rm -f "$FX"/test/*.test.sh
printf 'mktemp -d >/dev/null\necho "tiny: 1 passed, 0 failed."\n' > "$FX/test/tiny.test.sh"
fx_run HMD_TEST_STRICT_TMP=1 HMD_TEST_TMP_WATCH="$T/watch2"; RC=$?
if [ "$RC" -eq 1 ] && grep -q 'TMP LEAK (1)' "$T/fx.out"; then ok "HMD_TEST_STRICT_TMP=1: an empty leftover directory alone fails the sweep"; else bad "strict sweep rc=$RC: $(tail -20 "$T/fx.out")"; fi
rm -f "$FX"/test/*.test.sh
printf 'd="$(mktemp -d)"; trap '"'"'rm -rf "$d"'"'"' EXIT\necho "tidy: 1 passed, 0 failed."\n' > "$FX/test/tidy.test.sh"
fx_run HMD_TEST_STRICT_TMP=1 HMD_TEST_TMP_WATCH="$T/watch2"; RC=$?
if [ "$RC" -eq 0 ] && grep -qE '^tmp dirs: +clean' "$T/fx.out" && grep -qE '^tmp outside: +none' "$T/fx.out" && jq -e '.tmp_leaks == [] and .tmp_outside == []' "$RCPT" >/dev/null 2>&1; then ok "a tidy suite passes even strict: summary says clean/none, receipt arrays are empty"; else bad "tidy sweep rc=$RC: $(tail -20 "$T/fx.out")"; fi

echo "-- 8. wiring in run-all.sh --"
for needle in 'TMPDIR="$stmp" timeout_run' 'hmd_test_suite_tmp_settle' 'hmd_test_tmp_begin' 'hmd_test_tmp_guard' 'TMP_FINDINGS' 'tmp_leaks'; do
  if grep -qF -- "$needle" "$RUNALL"; then ok "run-all.sh carries: $needle"; else bad "run-all.sh is missing: $needle"; fi
done
if bash -n "$RUNALL" 2>/dev/null; then ok "run-all.sh still parses"; else bad "run-all.sh no longer parses"; fi

echo "-- 9. this suite leaves nothing running --"
LEFT="$(pgrep -f "$MARK|$T/fake/" 2>/dev/null | tr '\n' ' ')"
if [ -z "${LEFT// /}" ]; then ok "no process of this suite is left running"; else bad "still running: $LEFT"; fi

printf '\nrun-all-guards: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

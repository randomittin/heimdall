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
cleanup() { pkill -f "$MARK" 2>/dev/null || true; pkill -f "$T/fake/" 2>/dev/null || true; sleep 0.2; pkill -9 -f "$T/fake/" 2>/dev/null || true; rm -rf "$T"; }
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

echo "-- 5. this suite leaves nothing running --"
LEFT="$(pgrep -f "$MARK|$T/fake/" 2>/dev/null | tr '\n' ' ')"
if [ -z "${LEFT// /}" ]; then ok "no process of this suite is left running"; else bad "still running: $LEFT"; fi

printf '\nrun-all-guards: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

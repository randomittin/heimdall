#!/usr/bin/env bash
# cp-tick-watchdog.test.sh — THE TICK-LOOP WATCHDOG GATE (bug #17).
#
# THE INCIDENT THIS GATES (live prod, revision heimdall-control-plane-00050). The gated
# control plane's per-minute tick thread HUNG after the boot resume pass: the resume line
# printed, then ZERO further log lines (no "drain cycle", no "tick error") for 8+ minutes,
# while a queued task sat undrained. Root cause: run_tick() drained each team's queue, which
# read Firestore; a backend read WEDGED (an unbounded collection scan with no timeout), so the
# tick thread BLOCKED inside run_tick FOREVER. The loud-tick contract ("silence == blocked, an
# exception would print 'tick error'") held — but nothing recovered the loop. A block is not an
# exception, so the try/except around run_tick never fired.
#
# THE FIX THIS GATES (cp_boot._tick_loop watchdog): run_tick runs in a worker thread the loop
# WAITS ON for a bounded budget (step_timeout). If the step overruns, the loop ABANDONS THE WAIT
# (not the worker), emits a LOUD "drain step timeout" line, and continues — an OVERLAP GUARD
# refuses to start a second run_tick until the prior one finishes. Each wake also emits a
# "tick wake #N" liveness line FIRST, so total silence is now structurally impossible.
#
# FALSIFIER (why this test can FAIL when the fix is absent). run_tick is monkeypatched to BLOCK
# FOREVER. The loop is driven with a tiny interval + a tiny step_timeout in a thread the driver
# joins with a hard test-side timeout. WITH the watchdog: the loop keeps turning (>=2 "tick wake"
# lines), fires the watchdog (>=1 "drain step timeout"), and — crucially — HONORS stop_event so
# join() returns (survived=True). WITHOUT the watchdog (a synchronous run_tick call) the loop
# blocks on the first wake, never re-checks stop_event, join() times out -> survived=False -> the
# gate FAILS. So a regression that removes the watchdog turns this gate RED.
#
# Hermetic: pure in-process threading, NO firestore, NO network, NO sleep-racing on wall clock
# beyond a bounded drive window. Exit 0 = the watchdog fires AND the loop survives.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

[ -f "$LIB/cp_boot.py" ] || { echo "FATAL: $LIB/cp_boot.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

HOME_T="$(mktemp -d -t "cp-tickwd.$(printf 'X%.0s' 1 2 3 4)")"
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT

DRIVER="$HOME_T/wd_driver.py"
cat >"$DRIVER" <<'PYEOF'
import os
import sys
import threading
import time

sys.path.insert(0, os.environ["LIB"])

import cp_boot

# Capture every loud line the loop emits (cp_boot._stderr) into a thread-safe list, so the gate
# can assert on the liveness / watchdog lines without parsing a real stderr stream.
_lines = []
_lock = threading.Lock()


def _capture(msg):
    with _lock:
        _lines.append(msg)


cp_boot._stderr = _capture

# A run_tick that BLOCKS FOREVER (the wedged-backend simulation). It waits on an Event we never
# set until teardown — the exact "thread stuck inside run_tick" shape of the live hang.
_blocked = threading.Event()


def _blocking_run_tick(**_kwargs):
    _blocked.wait()   # never returns during the drive window -> run_tick is wedged.
    return []


cp_boot.run_tick = _blocking_run_tick

# Drive the loop in its own thread with a tiny cadence + a tiny watchdog budget so the whole
# gate runs in ~1s. step_timeout=0.15 << the block, so the watchdog MUST fire.
stop = threading.Event()
loop_thread = threading.Thread(
    target=cp_boot._tick_loop,
    kwargs=dict(stop_event=stop, home=os.environ["HEIMDALL_HOME"], base_env=None,
                interval=0.05, on_tick=None, step_timeout=0.15),
    name="wd-tick-loop",
    daemon=True,
)
loop_thread.start()

# Let several wakes happen (each wake: emit "tick wake #N", start/observe the wedged run_tick).
time.sleep(1.2)

# Signal shutdown and JOIN with a hard test-side timeout. This is the falsifier hinge: a loop
# that honored the watchdog re-checks stop_event every cadence and exits promptly; a loop that
# called run_tick synchronously is wedged and never returns -> join times out -> survived=False.
stop.set()
loop_thread.join(timeout=3.0)
survived = not loop_thread.is_alive()

# Release the abandoned worker so the interpreter can exit cleanly.
_blocked.set()

with _lock:
    snap = list(_lines)

wakes = sum(1 for line in snap if line.startswith("cp_boot: tick wake #"))
timeouts = sum(1 for line in snap if "drain step timeout" in line)
stillrun = sum(1 for line in snap if "drain step still running" in line)

print("STATUS survived=%s wakes=%d timeouts=%d stillrun=%d"
      % (survived, wakes, timeouts, stillrun))
PYEOF

OUT="$(HEIMDALL_HOME="$HOME_T" "$PY" "$DRIVER" 2>"$HOME_T/driver.err")"
echo "driver: $OUT"
[ -s "$HOME_T/driver.err" ] && { echo "  driver stderr:"; sed 's/^/    /' "$HOME_T/driver.err"; }
echo

SURVIVED="$(printf '%s' "$OUT" | sed -n 's/.*survived=\([A-Za-z]*\).*/\1/p')"
WAKES="$(printf '%s' "$OUT" | sed -n 's/.*wakes=\([0-9]*\).*/\1/p')"
TIMEOUTS="$(printf '%s' "$OUT" | sed -n 's/.*timeouts=\([0-9]*\).*/\1/p')"

echo "(a) SURVIVES — the loop honors stop_event despite a wedged run_tick (no infinite hang)"
if [ "$SURVIVED" = "True" ]; then
  ok "a1 the tick loop survived a forever-blocking run_tick and stopped on stop_event"
else
  bad "a1 the tick loop DID NOT survive — it hung on the blocked run_tick (out: $OUT)"
fi
echo

echo "(b) LOUD LIVENESS — the loop keeps emitting wake lines while a step is blocked"
if [ -n "$WAKES" ] && [ "$WAKES" -ge 2 ]; then
  ok "b1 the loop emitted >=2 'tick wake' liveness lines while run_tick was wedged (wakes=$WAKES)"
else
  bad "b1 the loop went silent — <2 'tick wake' lines (wakes=${WAKES:-0}, out: $OUT)"
fi
echo

echo "(c) WATCHDOG FIRES — a step that overruns the budget is abandoned loudly"
if [ -n "$TIMEOUTS" ] && [ "$TIMEOUTS" -ge 1 ]; then
  ok "c1 the watchdog fired a 'drain step timeout' on the wedged run_tick (timeouts=$TIMEOUTS)"
else
  bad "c1 the watchdog never fired — no 'drain step timeout' line (out: $OUT)"
fi

echo
echo "============================================================"
echo "cp-tick-watchdog: $PASS passed, $FAIL failed"
echo "  (a) survives: a forever-blocked run_tick cannot hang the loop (stop_event honored)"
echo "  (b) loud:     the loop keeps emitting 'tick wake' lines (silence impossible)"
echo "  (c) watchdog: an overrunning step is abandoned with a loud 'drain step timeout'"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

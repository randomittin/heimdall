#!/usr/bin/env bash
#
# heimdall-statusline-perf-budget.test.sh — dedicated perf regression gate for
# bin/heimdall-statusline's render time.
#
# WHY THIS EXISTS: a prior defect measured cold renders at 2.35-4.09s against
# Cursor CLI's statusLine timeoutMs (2000ms at the time this was found; the
# registration default is now 3000ms — see bin/heimdall-statusline-register-
# cursor), which silently killed the in-flight process and produced NO status
# line at all. Three structural fixes closed that gap — a pyenv-shim PATH
# bypass in this file, a double-fork memoization in bin/heimdall-identity, and
# a double-fork collapse in sentinels/hmd_ledger.py's _self_ids() (see those
# commits for mechanism detail). This suite is the regression net: nothing
# else in test/ asserts a render-time ceiling as a hard, dedicated, always-
# discoverable gate — heimdall-statusline-cursor-payload.test.sh section 4
# checks timing too, but as one section of a fixture-shape suite, not a
# standalone perf gate a future change could weaken without anyone noticing
# it was a timing assertion at all.
#
# BUDGET REASONING (both numbers from real, fresh measurement — not guessed):
#   - SOFT budget, 1000ms median / 2000ms max over 15 reps of the real
#     captured fixture: matches the existing convention in
#     heimdall-statusline-cursor-payload.test.sh section 4. Post-fix renders
#     were independently measured at 0.53-0.96s wall time on the main tree and
#     0.28-0.44s in this worktree (interleaved A/B, 10 samples/side, cold-
#     start round excluded) — 1000ms gives real headroom over the worst
#     observed sample while staying tight enough that a regression as small as
#     reintroducing ONE pyenv-shimmed python3 relaunch (~400-450ms measured
#     cost per launch — see the "FAST python3" PATH bypass below) trips it.
#   - HARD kill backstop, perl `alarm 2; exec @ARGV`: 2 whole seconds, chosen
#     as the ORIGINAL Cursor default timeoutMs this task started from — a
#     symbolic, principled ceiling ("must never again risk the exact kill that
#     motivated this fix"), enforced by an actual SIGALRM against the child
#     process, not a measured-and-compared float. This is a backstop against a
#     true hang (e.g. a blocking read that never returns), not the primary
#     signal — the soft budget above is tight enough to fail first in any
#     realistic regression. Perl's alarm() truncates to whole seconds, so
#     sub-second bounds are not expressible here; that granularity is exactly
#     why the soft budget (measured, not alarm-enforced) carries the real
#     regression-catching weight.
#
# FALSIFIER (verified by hand — see the coder-agent report for this task,
# which quotes the exact pass/fail counts both ways): a throwaway copy of
# bin/heimdall-statusline in a tmpdir, with `sleep 1.5` injected immediately
# after its `set -u` line, run through this suite's own measurement logic —
# the soft-budget assertion goes RED (median >1000ms). A second throwaway copy
# with `sleep 3` injected goes RED on the hard-kill assertion too (the 2s
# alarm fires — SIGALRM, non-zero/signal exit). The real, unmodified
# bin/heimdall-statusline (git diff confirmed empty throughout — the
# forbidden sentinels/hmd-statusline.py and this file are never touched by the
# falsifier) passes both — GREEN.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-statusline"
FIXTURE="$ROOT/test/fixtures/cursor-real-payload.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 unavailable"
  echo "heimdall-statusline-perf-budget: 0 passed, 0 failed (SKIPPED — python3 unavailable)"
  exit 0
}
command -v perl >/dev/null 2>&1 || {
  echo "SKIP: perl unavailable"
  echo "heimdall-statusline-perf-budget: 0 passed, 0 failed (SKIPPED — perl unavailable)"
  exit 0
}
[ -x "$CLI" ]     || { echo "FATAL: $CLI missing/not executable"; echo "heimdall-statusline-perf-budget: 0 passed, 1 failed"; exit 1; }
[ -f "$FIXTURE" ] || { echo "FATAL: $FIXTURE missing"; echo "heimdall-statusline-perf-budget: 0 passed, 1 failed"; exit 1; }

# hermetic workspace — identical shape to
# heimdall-statusline-cursor-payload.test.sh's mkws(), so a real filesystem
# read (identity/gate-verdict/roster) never leaks machine state into timing.
mkws() {
  ws="$(mktemp -d)"; homed="$(mktemp -d)"; tmpd="$(mktemp -d)"
  mkdir -p "$ws/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$ws/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$ws/.heimdall/statusline.json"
  : > "$ws/.heimdall/.beat-stamp"
  : > "$ws/.heimdall/.wall-cache.json.lock"
  printf '%s|%s|%s' "$ws" "$homed" "$tmpd"
}

FIXTURE_JSON="$(cat "$FIXTURE")"

echo "== 1) HARD KILL BACKSTOP: real fixture must survive a 2s perl alarm (Cursor's original timeoutMs) =="
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
ALARM_OUT="$(mktemp)"
printf '%s' "$FIXTURE_JSON" | env -i PATH="$PATH" HOME="$HOMED" LANG=en_US.UTF-8 \
    HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID=rj HMD_NOW=1752410000 \
    HEIMDALL_CP_URL="http://127.0.0.1:1" TERM=xterm-256color \
    HMD_STATUSLINE_TMP="$TMPD" HEIMDALL_STATUSLINE_MODE=truecolor \
    perl -e 'alarm 2; exec @ARGV' -- bash "$CLI" >"$ALARM_OUT" 2>&1
RC=$?
rm -rf "$WS" "$HOMED" "$TMPD"
OUTLEN="$(wc -c <"$ALARM_OUT" | tr -d ' ')"
rm -f "$ALARM_OUT"
if [ "$RC" = 0 ] && [ "$OUTLEN" -gt 0 ]; then
  ok "real fixture: completes within the 2s hard-kill alarm (exit 0, ${OUTLEN} bytes rendered)"
else
  bad "real fixture: did not cleanly complete within 2s (exit=$RC, bytes=$OUTLEN) — SIGALRM likely fired"
fi

echo "== 2) SOFT BUDGET: median/max render time over 15 reps of the real fixture =="
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
TIMING="$(FIXTURE_JSON="$FIXTURE_JSON" CLI="$CLI" WS="$WS" HOMED="$HOMED" TMPD="$TMPD" python3 - <<'PY'
import os, subprocess, time, statistics
json_blob = os.environ["FIXTURE_JSON"]
cli = os.environ["CLI"]
ws, home, tmp = os.environ["WS"], os.environ["HOMED"], os.environ["TMPD"]
env = dict(os.environ, HOME=home, HEIMDALL_IDENTITY_DIR=ws + "/.heimdall", HMD_HAID="rj",
           HMD_NOW="1752410000", HEIMDALL_CP_URL="http://127.0.0.1:1", TERM="xterm-256color",
           HMD_STATUSLINE_TMP=tmp, HEIMDALL_STATUSLINE_MODE="truecolor")
env.pop("COLUMNS", None)
ts = []
for _ in range(15):
    t0 = time.perf_counter()
    subprocess.run(["bash", cli], input=json_blob, capture_output=True, text=True, env=env)
    ts.append((time.perf_counter() - t0) * 1000)
print("%.3f %.3f" % (statistics.median(ts), max(ts)))
PY
)"
rm -rf "$WS" "$HOMED" "$TMPD"
MED="${TIMING%% *}"; MX="${TIMING##* }"
SOFT_MED_MS=1000
SOFT_MAX_MS=2000
echo "  render (real fixture, 15 reps): median=${MED}ms max=${MX}ms — soft budget: median<${SOFT_MED_MS}ms max<${SOFT_MAX_MS}ms"
python3 -c "import sys; sys.exit(0 if float('$MED') < $SOFT_MED_MS else 1)" \
  && ok "median render ${MED}ms < ${SOFT_MED_MS}ms soft budget" \
  || bad "median render ${MED}ms exceeds the ${SOFT_MED_MS}ms soft budget — perf regression"
python3 -c "import sys; sys.exit(0 if float('$MX') < $SOFT_MAX_MS else 1)" \
  && ok "max render ${MX}ms < ${SOFT_MAX_MS}ms soft budget" \
  || bad "max render ${MX}ms exceeds the ${SOFT_MAX_MS}ms soft budget — perf regression"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

#!/usr/bin/env bash
# test/tool-loop-detector.test.sh
#
# Proof for the live tool-loop detector inside bin/parallelism-tracker.
#
# Before this, hmd only noticed a stuck agent post-mortem (heimdall-agent-watchdog
# classifies STALL after the process is already dead). The detector fires WHILE
# the loop is happening: the same tool called with byte-identical input N times
# in a row (N = HMD_LOOP_THRESHOLD, default 5) prints one stderr line naming the
# tool, the count, and a hint to change approach.
#
# The properties asserted head-on:
#   1. Below the threshold: silent. Exactly at it: one LOOP line.
#   2. A different input resets the run; alternating A/B never fires.
#   3. WARN only. Exit code is 0 whether or not it fires.
#   4. An old-format (v1) state file cannot crash the new binary, and its
#      counters survive the upgrade.
#   5. HMD_LOOP_THRESHOLD is honoured; garbage falls back to the default.
#   6. Without an input argument the detector is inert (zero behaviour change
#      for every hook that still calls `check <tool>` bare).
#
# The tracker keys its state by $TMPDIR + $CLAUDE_SESSION_ID, so every case
# runs in its own temp dir and can never read or write the operator's real
# session state.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACKER="$REPO/bin/parallelism-tracker"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

if [ ! -x "$TRACKER" ] || ! "$TRACKER" check probe >/dev/null 2>&1; then
  bash "$REPO/bin/build-tracker.sh" >/dev/null 2>&1 || { echo "cannot build tracker"; exit 1; }
fi

# Fresh isolated state dir per case. Echoes the TMPDIR to use.
mk_case() {
  local d="$TMPROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# run_check <tmpdir> <tool> [input|-] ; stdin passes through for `-`.
# Captures stderr into $TMPROOT/err and echoes the exit code.
run_check() {
  local d="$1" tool="$2"; shift 2
  TMPDIR="$d" CLAUDE_SESSION_ID=loop-test "$TRACKER" check "$tool" "$@" 2>"$TMPROOT/err" >/dev/null
  printf '%s' "$?"
}

PAYLOAD='{"file_path":"/tmp/x.txt","content":"same bytes"}'

echo "tool-loop-detector"

# ── 1. four identical calls: silent, exit 0 each time ────────────────────────
D="$(mk_case below)"
quiet=1
for i in 1 2 3 4; do
  rc="$(run_check "$D" Write "$PAYLOAD")"
  if [ "$rc" != "0" ] || grep -q 'LOOP:' "$TMPROOT/err"; then quiet=0; fi
done
if [ "$quiet" = 1 ]; then
  ok "1. four identical Write calls print no LOOP line and exit 0"
else
  bad "1. detector fired below the threshold, or exit code changed"
fi

# ── 2. the fifth identical call fires, names tool + count, exit still 0 ──────
rc="$(run_check "$D" Write "$PAYLOAD")"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "0" ] \
   && grep -q 'LOOP:' <<<"$err" \
   && grep -q 'Write' <<<"$err" \
   && grep -q '5x' <<<"$err" \
   && grep -qi 'change approach' <<<"$err" \
   && [ "$(grep -c 'LOOP:' <<<"$err")" = 1 ]; then
  ok "2. fifth identical call prints ONE LOOP line naming Write, 5x, and the hint; exit 0"
else
  bad "2. fifth call did not warn as specified (rc=$rc): $err"
fi

# ── 3. a different input resets the run ─────────────────────────────────────
D="$(mk_case reset)"
for i in 1 2 3 4; do run_check "$D" Write "$PAYLOAD" >/dev/null; done
run_check "$D" Write '{"file_path":"/tmp/y.txt","content":"other"}' >/dev/null
rc="$(run_check "$D" Write "$PAYLOAD")"   # run is now 1, not 5
if [ "$rc" = "0" ] && ! grep -q 'LOOP:' "$TMPROOT/err"; then
  ok "3. one different input in between resets the run (no LOOP on the next repeat)"
else
  bad "3. run was not reset by a different input"
fi

# ── 4. alternating A/B/A/B... never warns, however long it goes ─────────────
D="$(mk_case alternate)"
fired=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if [ $((i % 2)) = 1 ]; then p="$PAYLOAD"; else p='{"file_path":"/tmp/b","content":"B"}'; fi
  run_check "$D" Edit "$p" >/dev/null
  grep -q 'LOOP:' "$TMPROOT/err" && fired=1
done
if [ "$fired" = 0 ]; then
  ok "4. alternating A/B inputs for 12 calls never fires"
else
  bad "4. alternating inputs tripped the detector"
fi

# ── 5. same input, different TOOL is not a repeat ───────────────────────────
D="$(mk_case tooldiff)"
fired=0
for i in 1 2 3 4 5 6; do
  if [ $((i % 2)) = 1 ]; then t=Write; else t=Edit; fi
  run_check "$D" "$t" "$PAYLOAD" >/dev/null
  grep -q 'LOOP:' "$TMPROOT/err" && fired=1
done
if [ "$fired" = 0 ]; then
  ok "5. identical input under alternating tool names is not a loop"
else
  bad "5. tool name is not part of the identity"
fi

# ── 6. `-` hashes stdin and agrees with the literal form ────────────────────
D="$(mk_case stdin)"
for i in 1 2 3; do printf '%s' "$PAYLOAD" | run_check "$D" Write - >/dev/null; done
run_check "$D" Write "$PAYLOAD" >/dev/null                       # 4th, literal
rc="$(printf '%s' "$PAYLOAD" | run_check "$D" Write -)"          # 5th, stdin
if [ "$rc" = "0" ] && grep -q 'LOOP:.*Write.*5x' "$TMPROOT/err"; then
  ok "6. stdin (-) and literal input hash identically; mixed run of 5 fires"
else
  bad "6. stdin hashing disagrees with the literal form"
fi

# ── 7. old-format (v1) state file: no crash, counters preserved, exit 0 ─────
D="$(mk_case oldstate)"
mkdir -p "$D/heimdall-parallel"
cat > "$D/heimdall-parallel/loop-test.state" <<'OLD'
last_ts=1700000000000
solo=1
batch_turns=7
total_turns=9
current_turn_size=1
calls=42
agent_solo=0
agent_calls=3
agent_batched=2
OLD
rc="$(run_check "$D" Write "$PAYLOAD")"
st="$D/heimdall-parallel/loop-test.state"
if [ "$rc" = "0" ] \
   && grep -q '^calls=43$' "$st" \
   && grep -q '^batch_turns=7$' "$st" \
   && grep -q '^agent_calls=3$' "$st" \
   && grep -q '^state_version=2$' "$st" \
   && grep -q '^loop_run=1$' "$st"; then
  ok "7. v1 state file read without crash; counters carried over; upgraded to v2 with run=1"
else
  bad "7. old-format state broke the new binary (rc=$rc)"; cat "$st" 2>/dev/null
fi

# ── 8. garbage in the v2 keys cannot crash either ───────────────────────────
D="$(mk_case garbage)"
mkdir -p "$D/heimdall-parallel"
printf 'calls=1\nloop_hash=not-hex\nloop_run=-99\nloop_tool=%s\nstate_version=999\nunknown_key=whatever\n' \
  "$(printf 'x%.0s' $(seq 1 300))" > "$D/heimdall-parallel/loop-test.state"
rc="$(run_check "$D" Write "$PAYLOAD")"
if [ "$rc" = "0" ] && ! grep -q 'LOOP:' "$TMPROOT/err" \
   && grep -q '^loop_run=1$' "$D/heimdall-parallel/loop-test.state"; then
  ok "8. malformed v2 keys (bad hex, negative run, 300-char tool, future version) → exit 0, run restarts at 1"
else
  bad "8. malformed state crashed or misfired (rc=$rc)"
fi

# ── 9. HMD_LOOP_THRESHOLD override is honoured ──────────────────────────────
D="$(mk_case thresh)"
fired_at=0
for i in 1 2 3 4 5; do
  HMD_LOOP_THRESHOLD=3 TMPDIR="$D" CLAUDE_SESSION_ID=loop-test "$TRACKER" check Bash "$PAYLOAD" 2>"$TMPROOT/err" >/dev/null
  if [ "$fired_at" = 0 ] && grep -q 'LOOP:' "$TMPROOT/err"; then fired_at=$i; fi
done
if [ "$fired_at" = 3 ] && grep -q '5x' "$TMPROOT/err"; then
  ok "9. HMD_LOOP_THRESHOLD=3 fires on the 3rd call (and keeps counting: 5x on the 5th)"
else
  bad "9. threshold override not honoured (first fired at call $fired_at)"
fi

# ── 10. garbage / too-small threshold falls back to the default of 5 ────────
D="$(mk_case threshbad)"
fired_at=0
for i in 1 2 3 4 5; do
  HMD_LOOP_THRESHOLD=banana TMPDIR="$D" CLAUDE_SESSION_ID=loop-test "$TRACKER" check Bash "$PAYLOAD" 2>"$TMPROOT/err" >/dev/null
  if [ "$fired_at" = 0 ] && grep -q 'LOOP:' "$TMPROOT/err"; then fired_at=$i; fi
done
D2="$(mk_case threshone)"
fired_one=0
HMD_LOOP_THRESHOLD=1 TMPDIR="$D2" CLAUDE_SESSION_ID=loop-test "$TRACKER" check Bash "$PAYLOAD" 2>"$TMPROOT/err" >/dev/null
grep -q 'LOOP:' "$TMPROOT/err" && fired_one=1
if [ "$fired_at" = 5 ] && [ "$fired_one" = 0 ]; then
  ok "10. non-numeric threshold → default 5; threshold 1 (every call a loop) is refused → default"
else
  bad "10. bad threshold values not sanitised (banana fired at $fired_at, one fired=$fired_one)"
fi

# ── 11. no input argument → detector inert, even for 8 bare identical calls ─
D="$(mk_case bare)"
fired=0
for i in 1 2 3 4 5 6 7 8; do
  run_check "$D" Write >/dev/null
  grep -q 'LOOP:' "$TMPROOT/err" && fired=1
done
if [ "$fired" = 0 ] && ! grep -q '^loop_run=[1-9]' "$D/heimdall-parallel/loop-test.state"; then
  ok "11. bare \`check <tool>\` (today's hook spelling) never tracks or fires — zero behaviour change"
else
  bad "11. bare check started loop-tracking"
fi

# ── 12. `check probe` (the SessionStart health probe) still passes ──────────
D="$(mk_case probe)"
rc="$(run_check "$D" probe)"
if [ "$rc" = "0" ]; then
  ok "12. check probe exits 0"
else
  bad "12. check probe broke (rc=$rc)"
fi

# ── 13. source stays -Wall -Wextra clean under the hook's own clang line ─────
if command -v clang >/dev/null 2>&1; then
  if clang -O2 -Wall -Wextra -Werror -fsyntax-only "$REPO/bin/parallelism-tracker.c" 2>"$TMPROOT/err"; then
    ok "13. bin/parallelism-tracker.c compiles -Wall -Wextra -Werror clean"
  else
    bad "13. compiler warnings: $(cat "$TMPROOT/err")"
  fi
else
  ok "13. (clang not present; compile check skipped)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

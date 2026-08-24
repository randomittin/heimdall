#!/usr/bin/env bash
# heimdall-pressure.test.sh — falsifiable coverage for bin/heimdall-pressure +
# bin/lib/pressure_control.py, the AIMD (additive-increase/multiplicative-
# decrease) feedback controller that turns OBSERVED 529/overloaded_error and
# connection-reset reports into a pressure-adjusted spawn-count recommendation.
#
# THE HONEST LIMIT under test: this is a controller over SPAWN DECISIONS,
# informed by past recorded failures — never an interceptor of a live request.
# It cannot see a 529 nobody reported. See bin/lib/pressure_control.py header.
#
# HERMETIC: every case gets its own mktemp HOME (pressure state lives under
# $HOME/.heimdall/, exactly like bin/agent-pool's own pool file) and its own
# mktemp repo dir for the --repo ledger. Never touches the real ~/.heimdall or
# a real .planning/metrics.jsonl. No sleeps — elapsed time is simulated by
# backdating stored timestamps via jq, exactly like agent-pool-stale-idle.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO/bin/heimdall-pressure"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

fresh_home() { mktemp -d "${TMPDIR:-/tmp}/hmd-pressure-test.XXXXXX"; }
pp() { python3 "$CLI" "$@"; }
state_file() { echo "$HOME/.heimdall/pressure-state.json"; }

echo "heimdall-pressure harness"
echo "--------------------------------------------------------------------"

# ── 1. fail-open: no state at all ────────────────────────────────────────────
export HOME; HOME="$(fresh_home)"
out="$(pp recommend --ceiling 10)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "10" ] && ok "1. no state -> recommend == ceiling (fail open)" \
  || bad "1. got '$out' rc=$rc, want 10 rc=0"

# ── 2. fail-open: corrupted state file ───────────────────────────────────────
export HOME; HOME="$(fresh_home)"
mkdir -p "$(dirname "$(state_file)")"
printf 'not json { garbage' > "$(state_file)"
out="$(pp recommend --ceiling 10 2>"$HOME/err.log")"; rc=$?
err="$(cat "$HOME/err.log")"
[ "$rc" -eq 0 ] && [ "$out" = "10" ] && [ -z "$(grep -i traceback "$HOME/err.log")" ] \
  && ok "2. corrupt state -> recommend == ceiling, no crash/traceback" \
  || bad "2. got out='$out' rc=$rc err='$err'"

# ── 3. single isolated event does NOT throttle ───────────────────────────────
export HOME; HOME="$(fresh_home)"
pp record --kind overloaded_error >/dev/null
out="$(pp recommend --ceiling 10)"
[ "$out" = "10" ] && ok "3. single event -> no throttle (recommend still 10)" \
  || bad "3. single event throttled: got '$out', want 10"

# ── 4. burst (>= threshold=3) triggers multiplicative decrease ──────────────
export HOME; HOME="$(fresh_home)"
pp record --kind overloaded_error >/dev/null
pp record --kind overloaded_error >/dev/null
pp record --kind overloaded_error >/dev/null
out="$(pp recommend --ceiling 10)"
[ "$out" = "5" ] && ok "4. burst of 3 -> recommend halved (10 -> 5)" \
  || bad "4. got '$out', want 5"
red="$(pp status --ceiling 10 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["reduced"])')"
reason="$(pp status --ceiling 10 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["reason"] or "")')"
[ "$red" = "True" ] && [ -n "$reason" ] && ok "4b. status --json: reduced=true with a non-empty reason (visible, not silent)" \
  || bad "4b. reduced='$red' reason='$reason'"

# ── 5. partial recovery: backdate by exactly one recovery step (120s) ───────
tmp="$(mktemp)"
jq --arg t "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=120)).isoformat())')" \
  '.last_change_ts=$t' "$(state_file)" >"$tmp" && mv "$tmp" "$(state_file)"
out="$(pp recommend --ceiling 10)"
[ "$out" = "7" ] && ok "5. one recovery step elapsed -> factor 0.5+0.2=0.7 -> 10*0.7=7" \
  || bad "5. got '$out', want 7 (formula, not just endpoint)"

# ── 6. full recovery: backdate far into the past -> back to ceiling ─────────
tmp="$(mktemp)"
jq --arg t "2000-01-01T00:00:00+00:00" '.last_change_ts=$t' "$(state_file)" >"$tmp" && mv "$tmp" "$(state_file)"
out="$(pp recommend --ceiling 10)"
red="$(pp status --ceiling 10 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["reduced"])')"
[ "$out" = "10" ] && [ "$red" = "False" ] && ok "6. pressure cleared long ago -> full recovery (== ceiling), reduced=false" \
  || bad "6. got out='$out' reduced='$red', want 10/False"

# ── 7. post-breach single follow-up event does not immediately re-cascade ───
export HOME; HOME="$(fresh_home)"
pp record --kind overloaded_error >/dev/null
pp record --kind overloaded_error >/dev/null
pp record --kind overloaded_error >/dev/null   # breach #1 -> factor 0.5
pp record --kind connection_reset >/dev/null   # one more, window reset to 1 -> below threshold
out="$(pp recommend --ceiling 10)"
[ "$out" = "5" ] && ok "7. single follow-up after a breach does not re-halve (stays at 5)" \
  || bad "7. got '$out', want 5 (unchanged)"

# ── 8. sustained pressure compounds (second breach halves again) ────────────
pp record --kind overloaded_error >/dev/null   # window: [4th,5th] = 2
pp record --kind overloaded_error >/dev/null   # window: [4th,5th,6th] = 3 -> breach #2 -> 0.5*0.5=0.25
out="$(pp recommend --ceiling 10)"
[ "$out" = "2" ] && ok "8. sustained pressure compounds multiplicatively (0.5 -> 0.25 -> 10*0.25=2)" \
  || bad "8. got '$out', want 2"

# ── 9. never below the floor, at any ceiling ─────────────────────────────────
export HOME; HOME="$(fresh_home)"
i=0
while [ $i -lt 24 ]; do
  pp record --kind overloaded_error >/dev/null
  i=$((i+1))
done
big="$(pp recommend --ceiling 1000)"
small="$(pp recommend --ceiling 1)"
big_ok=$(python3 -c "print(1 if 0 < $big < 1000 else 0)")
[ "$big_ok" = "1" ] && [ "$small" = "1" ] && ok "9. heavy sustained pressure never floors to 0 (ceiling=1000 -> $big; ceiling=1 -> $small)" \
  || bad "9. big='$big' small='$small'"

# ── 10. mixed kinds count toward the same threshold ──────────────────────────
export HOME; HOME="$(fresh_home)"
pp record --kind overloaded_error >/dev/null
pp record --kind connection_reset >/dev/null
pp record --kind overloaded_error >/dev/null
out="$(pp recommend --ceiling 10)"
[ "$out" = "5" ] && ok "10. 2 overloaded_error + 1 connection_reset together breach threshold" \
  || bad "10. got '$out', want 5"

# ── 11. invalid --kind is rejected, never breaks the caller (fail open) ─────
export HOME; HOME="$(fresh_home)"
pp record --kind not_a_real_kind >/dev/null 2>"$HOME/err.log"; rc=$?
out="$(pp recommend --ceiling 10)"
[ "$rc" -eq 0 ] && [ "$out" = "10" ] && ok "11a. bad --kind, no --strict -> exit 0, no state change" \
  || bad "11a. rc=$rc recommend='$out'"
pp --strict record --kind not_a_real_kind >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "11b. bad --kind WITH --strict -> exit 2 (opt-in strictness, mirrors heimdall-metric)" \
  || bad "11b. rc=$rc, want 2"

# ── 12. ledger audit trail under --repo (mirrors .planning/metrics.jsonl shape) ─
# .planning must pre-exist — heimdall-pressure never mkdir's it, same contract as
# bin/heimdall-metric's cmd_task (bin/heimdall-metric:297), whose own test fixture
# (test/heimdall-metric.test.sh:71 mk_repo) pre-creates it for the identical reason.
export HOME; HOME="$(fresh_home)"
R="$(fresh_home)"
mkdir -p "$R/.planning"
pp --repo "$R" record --kind overloaded_error --source cli-test >/dev/null
LEDGER="$R/.planning/metrics.jsonl"
[ -f "$LEDGER" ] && grep -q '"metric":"pressure"' "$LEDGER" && grep -q '"kind":"overloaded_error"' "$LEDGER" \
  && ok "12. --repo writes an audit line to .planning/metrics.jsonl" \
  || bad "12. ledger missing or malformed: $(cat "$LEDGER" 2>/dev/null)"

# ── 13. retry-delay: bounds, jitter is real, seed is deterministic ──────────
i=1
bounds_ok=1
while [ $i -le 6 ]; do
  d="$(pp retry-delay --attempt $i --base 1 --cap 60)"
  chk="$(python3 -c "
d=$d; ideal=min(60.0, 1.0*(2**($i-1)))
print(1 if 0.0 <= d <= ideal else 0)
")"
  [ "$chk" = "1" ] || bounds_ok=0
  i=$((i+1))
done
[ "$bounds_ok" = "1" ] && ok "13a. retry-delay stays within [0, min(cap, base*2^(attempt-1))] for attempts 1..6" \
  || bad "13a. a delay fell outside its full-jitter bound"
d1="$(pp retry-delay --attempt 5 --base 1 --cap 60 --seed 42)"
d2="$(pp retry-delay --attempt 5 --base 1 --cap 60 --seed 42)"
[ "$d1" = "$d2" ] && ok "13b. same --seed -> deterministic repeat ($d1 == $d2)" \
  || bad "13b. seeded runs diverged: $d1 vs $d2"
d3="$(pp retry-delay --attempt 5 --base 1 --cap 60)"
d4="$(pp retry-delay --attempt 5 --base 1 --cap 60)"
[ "$d3" != "$d4" ] && ok "13c. unseeded calls vary -> jitter is real, not a fixed formula ($d3 != $d4)" \
  || bad "13c. two unseeded delays were identical ($d3) — jitter looks fake"

# ── 14. latency: recommend() cost does not grow with recorded history ───────
export HOME; HOME="$(fresh_home)"
t_empty=$(python3 -c "
import sys, time
sys.path.insert(0, '$REPO/bin/lib')
import pressure_control as pc
t0=time.perf_counter()
for _ in range(500): pc.recommend(10)
print(time.perf_counter()-t0)
")
i=0
while [ $i -lt 100 ]; do pp record --kind overloaded_error >/dev/null; i=$((i+1)); done
t_loaded=$(python3 -c "
import sys, time
sys.path.insert(0, '$REPO/bin/lib')
import pressure_control as pc
t0=time.perf_counter()
for _ in range(500): pc.recommend(10)
print(time.perf_counter()-t0)
")
ratio_ok=$(python3 -c "print(1 if $t_loaded < ($t_empty*5 + 0.5) else 0)")
echo "  (latency: 500x recommend() empty=${t_empty}s after-100-events=${t_loaded}s)"
[ "$ratio_ok" = "1" ] && ok "14. recommend() cost does not scale with recorded-event history (no ledger scan)" \
  || bad "14. cost grew with history: empty=$t_empty loaded=$t_loaded"

echo "--------------------------------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

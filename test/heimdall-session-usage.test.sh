#!/usr/bin/env bash
# test/heimdall-session-usage.test.sh — hermetic, fixture-only tests for
# bin/heimdall-session-usage. NEVER touches the operator's real transcripts
# (non-reproducible, and could leak session content into test output) —
# every .jsonl fixture here is hand-built under a throwaway mktemp -d.
#
# FALSIFIABLE CLAIMS TESTED:
#  1. consumption below threshold        -> verdict=under, exit 0
#  2. consumption above 95% threshold    -> verdict=crossed, exit 1
#  3. consumption exactly at threshold (>=) -> crossed
#  4. missing transcript file            -> verdict=unknown (exit 0), NOT under
#  5. malformed JSON lines are skipped, not fatal
#  6. no budget configured               -> verdict=unconfigured, distinct from under/unknown
#  7. budget<=0 is treated as unconfigured
#  8. --json output is always valid JSON, including the unknown case
#  9. --window-secs is a real filter: records outside the window are excluded
# 10. --strict surfaces a rejected invocation as exit 2; default degrades to 0
# 11. --max-bytes bounds the read from the tail (truncation flagged + measured)
# 12. `where` prints the resolved path (or empty) deterministically
# 13. env-var defaults (HEIMDALL_SESSION_TOKEN_BUDGET / _THRESHOLD_PCT) honored
# 14. zero in-window usage on a readable file -> under (0%), never unknown
# 15. exit-code contract: 0 for under/unknown/unconfigured, 1 for crossed
# 16. fresh real rate-limit snapshot (five_hour) -> source=real, verdict driven
#     by the real figure; an EXPIRED one is ABSENT, never a low reading, and
#     never masks a crossed budget verdict
# 17. absent/malformed rate-limit file -> clean fallback to the budget path,
#     never a crash
# 18. seven_day is an independent, ADDITIVE crossed condition (2026-08-29):
#     its own threshold check, its own freshness rule (resets_at when present,
#     else observed_at + a bounded TTL when absent -- never five_hour's rule
#     reused)
# 19. verdict reports WHICH window crossed via a new 'window' field
#     (five_hour / seven_day / both / null) -- metadata only, never a fifth
#     verdict value; 'crossed' stays a plain boolean of the same 4-state verdict
# 20. a seven_day reading stale by EITHER freshness rule (expired resets_at, or
#     an absent one whose TTL fallback has elapsed) never fabricates a crossing
#     and never masks a genuine five_hour crossing -- falsified both ways
# 21. five_hour absent/expired entirely does not stop a fresh, crossed
#     seven_day from being reported (source=real, window=seven_day) -- the
#     literal production scenario this task exists for (weekly limit crossed
#     independent of the five-hour one)
# 22. seven_day with no resets_at AND no usable payload observed_at can't
#     prove its own freshness -> treated as absent, never a crash, never a
#     fabricated crossing
# PHASE 4 -- reactive HTTP-429 marker (2026-08-30, bin/heimdall-429-mark),
# cases 29-44:
#  29. fresh marker ALONE (no budget, no real snapshot) promotes an
#      otherwise-unconfigured verdict all the way to crossed
#  30. fresh marker promotes an otherwise-UNDER budget verdict -> crossed --
#      the literal production scenario (reported under while quota is gone)
#  31. an EXPIRED marker (age > the 900s TTL) does NOT promote -- proves the
#      TTL actually expires, not merely that absence is handled
#  32-37. absent / malformed marker content (bad JSON, non-dict, missing
#      key, non-numeric, bool-typed marked_at) -> never crashes, never a
#      fabricated crossing
#  38. marked_at in the FUTURE (clock skew) -> rejected (negative age)
#  39. an EXPIRED marker never masks OR mislabels an independently-crossed
#      five_hour verdict -- window stays plain 'five_hour'
#  40-42. window naming for every reactive combination:
#      five_hour+reactive_429 / seven_day+reactive_429 / all
#  43-44. --reactive-429-file (CLI) outranks HEIMDALL_429_MARKER_FILE (env),
#      which is itself honored absent a CLI flag -- same precedence shape as
#      every other path override in this file
# PHASE 5 -- generic extra/unknown rate-limit windows (2026-09-05, fifth
# production report of a live "session limit" reading under threshold while
# blocked): read_real_usage now ALSO captures any top-level payload key
# outside five_hour/seven_day/observed_at/windows_seen, held to five_hour's
# OWN strict freshness rule (mandatory resets_at) since an unnamed window's
# staleness semantics are unverified. Cases 45-50:
#  45. an extra window ALONE crosses threshold (five_hour under, no
#      seven_day) -> verdict=crossed, window='extra:<name>'
#  46. an extra window crosses ALONGSIDE an already-crossed five_hour ->
#      window='five_hour+extra:<name>' (additive suffix, same shape as
#      PHASE 4's five_hour+reactive_429)
#  47. an extra window is present but UNDER threshold, base also under ->
#      verdict=under, window=null, extra_windows still reports it with
#      crossed=false -- captured is not the same claim as crossed
#  48. a malformed extra window (dict but missing used_percentage) plus a
#      stray NON-dict top-level key -> no crash, extra_windows == {} exactly
#  49. rate-limit file missing entirely AND no budget configured ->
#      verdict=unconfigured, NEVER a confident 'under' when blind to real
#      usage -- the literal acceptance criterion this phase exists to pin
#  50. REGRESSION PIN: PHASE 3's "both crossed" (case 22) reproduced with an
#      extra UNDER-threshold window and windows_seen also present in the same
#      fixture -> window stays EXACTLY 'both', proving old behavior is
#      unchanged even when the new fields coexist
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/bin/heimdall-session-usage"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-session-usage-test.XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# never let a real running session / a real operator budget leak into these tests
unset CLAUDE_CODE_SESSION_ID HEIMDALL_SESSION_TOKEN_BUDGET HEIMDALL_SESSION_USAGE_THRESHOLD_PCT HEIMDALL_SESSION_USAGE_WINDOW_SECS HEIMDALL_SESSION_USAGE_MAX_BYTES
# never let a real developer's real ~/.heimdall/rate-limits.json (persisted by a live
# statusline render elsewhere on this machine) leak into cases 1-15, which never pass
# --rate-limit-file and must all stay on the pre-Phase-2 budget path exactly as before.
export HEIMDALL_RATE_LIMIT_STATE="$WORK/unused-rate-limits.json"
# PHASE 4 (2026-08-30): same hermeticity guard for the reactive-429 marker --
# a real ~/.heimdall/429-marker.json written by actual bin/lib/hmd-claude-
# retry.sh usage on this machine must never leak into cases 1-28, none of
# which pass --reactive-429-file and must all stay completely unaffected by
# PHASE 4. Both HEIMDALL_429_MARKER_FILE (the direct override
# bin/heimdall-session-usage reads) and HEIMDALL_HOME (its fallback default's
# own base) are neutralized to nonexistent paths under $WORK -- belt and
# suspenders, matching HEIMDALL_RATE_LIMIT_STATE just above.
export HEIMDALL_429_MARKER_FILE="$WORK/unused-429-marker.json"
export HEIMDALL_HOME="$WORK/unused-heimdall-home"

now_ts() {
  python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))"
}

ts_offset() {
  # ts_offset <seconds ago> -> ISO-8601 Z timestamp that far in the past
  python3 -c "
import sys
from datetime import datetime, timedelta, timezone
secs = float(sys.argv[1])
print((datetime.now(timezone.utc) - timedelta(seconds=secs)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))
" "$1"
}

usage_line() {
  # usage_line <timestamp> <input_tokens> <output_tokens> -> one transcript JSONL record
  python3 -c "
import json, sys
ts, itok, otok = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
print(json.dumps({
    'type': 'assistant',
    'timestamp': ts,
    'sessionId': 'test-session',
    'message': {'role': 'assistant', 'usage': {'input_tokens': itok, 'output_tokens': otok}},
}))
" "$1" "$2" "$3"
}

case_dir() {
  d="$WORK/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# epoch_offset <seconds ago (negative = in the future)> -> unix epoch float,
# for hand-building a bin/heimdall-429-mark-shaped marker file with exact
# control over freshness/staleness -- PHASE 4 cases below.
epoch_offset() {
  python3 -c "import time, sys; print(time.time() - float(sys.argv[1]))" "$1"
}

# write_marker <path> <marked_at epoch float> [reason] -> hand-builds a
# bin/heimdall-429-mark-shaped marker JSON file directly, independent of that
# tool's own writer, so a bug in ONE never masks or spuriously fails the
# OTHER's tests. See test/heimdall-429-mark.test.sh for the recorder's own
# dedicated coverage.
write_marker() {
  python3 -c "
import json, sys
path, marked_at = sys.argv[1], float(sys.argv[2])
payload = {'marked_at': marked_at}
if len(sys.argv) > 3 and sys.argv[3]:
    payload['reason'] = sys.argv[3]
json.dump(payload, open(path, 'w'))
" "$1" "$2" "${3:-}"
}

echo "=== 1. below threshold -> under ==="
d=$(case_dir c1); f="$d/t.jsonl"
usage_line "$(now_ts)" 100 50 > "$f"
out=$(python3 "$BIN" status --file "$f" --budget 1000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "under"'; then ok; else bad "case1 rc=$rc out=$out"; fi

echo "=== 2. above 95% threshold -> crossed ==="
d=$(case_dir c2); f="$d/t.jsonl"
usage_line "$(now_ts)" 900 60 > "$f"   # 960/1000 = 96%
out=$(python3 "$BIN" status --file "$f" --budget 1000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"'; then ok; else bad "case2 rc=$rc out=$out"; fi

echo "=== 3. exactly at threshold (>=) -> crossed ==="
d=$(case_dir c3); f="$d/t.jsonl"
usage_line "$(now_ts)" 900 50 > "$f"   # 950/1000 = 95.0% exactly, default threshold 95.0
out=$(python3 "$BIN" status --file "$f" --budget 1000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"'; then ok; else bad "case3 rc=$rc out=$out"; fi

echo "=== 4. missing file -> unknown, exit 0, distinct from under ==="
out=$(python3 "$BIN" status --file "$WORK/does-not-exist.jsonl" --budget 1000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "unknown"' && ! printf '%s' "$out" | grep -q '"verdict": "under"'; then ok; else bad "case4 rc=$rc out=$out"; fi

echo "=== 5. malformed JSON lines skipped, not fatal ==="
d=$(case_dir c5); f="$d/t.jsonl"
{
  echo 'not json at all {{{'
  usage_line "$(now_ts)" 100 50
  echo '{"broken": '
} > "$f"
out=$(python3 "$BIN" status --file "$f" --budget 1000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"tokens_observed": 150' && printf '%s' "$out" | grep -q '"verdict": "under"'; then ok; else bad "case5 rc=$rc out=$out"; fi

echo "=== 6. no budget configured -> unconfigured, distinct from under/unknown ==="
d=$(case_dir c6); f="$d/t.jsonl"
usage_line "$(now_ts)" 100 50 > "$f"
out=$(python3 "$BIN" status --file "$f" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "unconfigured"' && printf '%s' "$out" | grep -q '"percent_of_budget": null'; then ok; else bad "case6 rc=$rc out=$out"; fi

echo "=== 7. budget<=0 treated as unconfigured ==="
d=$(case_dir c7); f="$d/t.jsonl"
usage_line "$(now_ts)" 100 50 > "$f"
out=$(python3 "$BIN" status --file "$f" --budget 0 --json)
if printf '%s' "$out" | grep -q '"verdict": "unconfigured"'; then ok; else bad "case7(zero) out=$out"; fi
out=$(python3 "$BIN" status --file "$f" --budget -5 --json)
if printf '%s' "$out" | grep -q '"verdict": "unconfigured"'; then ok; else bad "case7(negative) out=$out"; fi

echo "=== 8. --json always valid JSON, incl. unknown case ==="
out=$(python3 "$BIN" status --file "$WORK/does-not-exist-2.jsonl" --budget 500 --json)
if printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then ok; else bad "case8(unknown) not valid JSON: $out"; fi
d=$(case_dir c8); f="$d/t.jsonl"
usage_line "$(now_ts)" 10 10 > "$f"
out=$(python3 "$BIN" status --file "$f" --budget 500 --json)
if printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then ok; else bad "case8(normal) not valid JSON: $out"; fi

echo "=== 9. --window-secs is a real filter ==="
d=$(case_dir c9); f="$d/t.jsonl"
{
  usage_line "$(ts_offset 999999)" 100000 100000   # ancient, far outside any sane window
  usage_line "$(now_ts)" 50 50
} > "$f"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --window-secs 60 --json)
if printf '%s' "$out" | grep -q '"tokens_observed": 100'; then ok; else bad "case9 out=$out"; fi

echo "=== 10. --strict surfaces rejected usage; default degrades to 0 ==="
python3 "$BIN" --strict bogus-subcommand >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "case10(strict) rc=$rc"; fi
python3 "$BIN" bogus-subcommand >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "case10(default) rc=$rc"; fi

echo "=== 11. --max-bytes bounds the tail read ==="
d=$(case_dir c11); f="$d/t.jsonl"
: > "$f"
i=0
while [ $i -lt 200 ]; do
  usage_line "$(now_ts)" 1 1 >> "$f"
  i=$((i+1))
done
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --max-bytes 500 --json)
if printf '%s' "$out" | grep -q '"window_truncated_by_byte_cap": true' && printf '%s' "$out" | grep -q '"bytes_read": 500'; then ok; else bad "case11 out=$out"; fi

echo "=== 12. where prints resolved path deterministically ==="
out=$(python3 "$BIN" where --file "/some/explicit/path.jsonl")
if [ "$out" = "/some/explicit/path.jsonl" ]; then ok; else bad "case12(explicit) out=$out"; fi
out=$(python3 "$BIN" where)
if [ -z "$out" ]; then ok; else bad "case12(empty) out=$out"; fi

echo "=== 13. env-var defaults honored ==="
d=$(case_dir c13); f="$d/t.jsonl"
usage_line "$(now_ts)" 900 60 > "$f"
out=$(HEIMDALL_SESSION_TOKEN_BUDGET=1000 HEIMDALL_SESSION_USAGE_THRESHOLD_PCT=95 python3 "$BIN" status --file "$f" --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"'; then ok; else bad "case13 rc=$rc out=$out"; fi

echo "=== 14. zero in-window usage on readable file -> under, not unknown ==="
d=$(case_dir c14); f="$d/t.jsonl"
usage_line "$(ts_offset 999999)" 5000 5000 > "$f"   # only an ancient record; readable file, empty window
out=$(python3 "$BIN" status --file "$f" --budget 1000 --window-secs 60 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "under"' && printf '%s' "$out" | grep -q '"tokens_observed": 0'; then ok; else bad "case14 rc=$rc out=$out"; fi

echo "=== 15. exit-code contract sanity across all four states ==="
d=$(case_dir c15); f="$d/t.jsonl"
usage_line "$(now_ts)" 10 10 > "$f"
python3 "$BIN" status --file "$f" --budget 1000000 --json >/dev/null; rc_under=$?
python3 "$BIN" status --file "$WORK/nope.jsonl" --budget 1000 --json >/dev/null; rc_unknown=$?
python3 "$BIN" status --file "$f" --json >/dev/null; rc_unconf=$?
python3 "$BIN" status --file "$f" --budget 1 --json >/dev/null; rc_crossed=$?
if [ "$rc_under" -eq 0 ] && [ "$rc_unknown" -eq 0 ] && [ "$rc_unconf" -eq 0 ] && [ "$rc_crossed" -eq 1 ]; then
  ok
else
  bad "case15 under=$rc_under unknown=$rc_unknown unconf=$rc_unconf crossed=$rc_crossed"
fi

echo "=== 16. fresh real rate-limit snapshot -> source=real, correct verdict ==="
d=$(case_dir c16); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 97.5, 'resets_at': time.time() + 3600}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"source": "real"' && printf '%s' "$out" | grep -q '"percent_real": 97.5' && printf '%s' "$out" | grep -q '"verdict": "crossed"'; then ok; else bad "case16 rc=$rc out=$out"; fi

echo "=== 17. EXPIRED real snapshot (low %) must NOT mask a crossed budget verdict — expired is ABSENT, never a low reading ==="
d=$(case_dir c17); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 900 60 > "$f"   # 960/1000 = 96% of budget -> crossed
python3 -c "
import json, time
json.dump({'observed_at': time.time() - 7200, 'five_hour': {'used_percentage': 3.0, 'resets_at': time.time() - 60}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"source": "budget"' && printf '%s' "$out" | grep -q '"percent_real": null' && printf '%s' "$out" | grep -q '"verdict": "crossed"'; then ok; else bad "case17 rc=$rc out=$out"; fi

echo "=== 18. absent rate-limit file -> budget fallback, percent_real null ==="
d=$(case_dir c18); f="$d/t.jsonl"
usage_line "$(now_ts)" 100 50 > "$f"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$d/does-not-exist.json" --budget 1000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"source": "budget"' && printf '%s' "$out" | grep -q '"percent_real": null' && printf '%s' "$out" | grep -q '"verdict": "under"'; then ok; else bad "case18 rc=$rc out=$out"; fi

echo "=== 19. malformed rate-limit file never crashes -> budget fallback, valid JSON ==="
d=$(case_dir c19); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 100 50 > "$f"
printf 'not json {{{' > "$rl"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && printf '%s' "$out" | grep -q '"source": "budget"'; then ok; else bad "case19 rc=$rc out=$out"; fi

echo "=== 20. seven_day CROSSED while five_hour UNDER (both fresh via resets_at) -> verdict=crossed, window=seven_day ==="
d=$(case_dir c20); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 10.0, 'resets_at': time.time() + 3600}, 'seven_day': {'used_percentage': 99.0, 'resets_at': time.time() + 500000}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"source": "real"' && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "seven_day"'; then ok; else bad "case20 rc=$rc out=$out"; fi

echo "=== 21. five_hour CROSSED while seven_day UNDER (both fresh) -> verdict=crossed, window=five_hour (pre-existing five-hour-alone behavior unchanged) ==="
d=$(case_dir c21); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 99.0, 'resets_at': time.time() + 3600}, 'seven_day': {'used_percentage': 10.0, 'resets_at': time.time() + 500000}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "five_hour"' && printf '%s' "$out" | grep -q '"percent_real": 99.0'; then ok; else bad "case21 rc=$rc out=$out"; fi

echo "=== 22. BOTH windows crossed -> window=both ==="
d=$(case_dir c22); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 96.0, 'resets_at': time.time() + 3600}, 'seven_day': {'used_percentage': 97.0, 'resets_at': time.time() + 500000}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "both"'; then ok; else bad "case22 rc=$rc out=$out"; fi

echo "=== 23. STALE seven_day (expired resets_at) must NOT fabricate a crossing -- five_hour fresh+under -> verdict=under ==="
d=$(case_dir c23); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json
json.dump({'observed_at': 1, 'five_hour': {'used_percentage': 10.0, 'resets_at': 9999999999}, 'seven_day': {'used_percentage': 10.0, 'resets_at': 1}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "under"' && printf '%s' "$out" | grep -q '"window": null'; then ok; else bad "case23 rc=$rc out=$out"; fi

echo "=== 24. seven_day with NO resets_at at all, fresh via observed_at+TTL fallback, CROSSED -> window=seven_day (fires when it should) ==="
d=$(case_dir c24); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time() - 30, 'five_hour': {'used_percentage': 10.0, 'resets_at': time.time() + 3600}, 'seven_day': {'used_percentage': 98.0}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "seven_day"' && printf '%s' "$out" | grep -q '"percent_real_seven_day": 98.0'; then ok; else bad "case24 rc=$rc out=$out"; fi

echo "=== 25. seven_day with NO resets_at, STALE via TTL (observed_at 6h ago > 18000s bound) -- must NOT fire even though the number alone would cross (does not fire when it should not) ==="
d=$(case_dir c25); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time() - 21600, 'five_hour': {'used_percentage': 10.0, 'resets_at': time.time() + 3600}, 'seven_day': {'used_percentage': 99.0}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "under"' && printf '%s' "$out" | grep -q '"percent_real_seven_day": null' && printf '%s' "$out" | grep -q '"window": null'; then ok; else bad "case25 rc=$rc out=$out"; fi

echo "=== 26. seven_day key entirely absent (pre-Phase-3 snapshot) -> unaffected, no crash, window=null ==="
d=$(case_dir c26); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 10.0, 'resets_at': time.time() + 3600}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "under"' && printf '%s' "$out" | grep -q '"window": null' && printf '%s' "$out" | grep -q '"percent_real_seven_day": null'; then ok; else bad "case26 rc=$rc out=$out"; fi

echo "=== 27. five_hour key ENTIRELY ABSENT, seven_day fresh+CROSSED -> source=real, percent_real=null, window=seven_day (the literal production scenario: weekly limit crossed independent of five-hour) ==="
d=$(case_dir c27); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'seven_day': {'used_percentage': 99.0, 'resets_at': time.time() + 500000}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"source": "real"' && printf '%s' "$out" | grep -q '"percent_real": null' && printf '%s' "$out" | grep -q '"window": "seven_day"' && printf '%s' "$out" | grep -q '"percent_real_seven_day": 99.0'; then ok; else bad "case27 rc=$rc out=$out"; fi

echo "=== 28. seven_day with no resets_at AND no usable top-level observed_at -> can't prove freshness -> treated as absent, no crash ==="
d=$(case_dir c28); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'five_hour': {'used_percentage': 10.0, 'resets_at': time.time() + 3600}, 'seven_day': {'used_percentage': 99.0}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "under"' && printf '%s' "$out" | grep -q '"window": null' && printf '%s' "$out" | grep -q '"percent_real_seven_day": null'; then ok; else bad "case28 rc=$rc out=$out"; fi

echo "=== 29. PHASE 4: fresh reactive-429 marker ALONE (no budget, no real snapshot) promotes unconfigured -> crossed, window=reactive_429 ==="
d=$(case_dir c29); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 100 50 > "$f"
write_marker "$mk" "$(epoch_offset 30)"
out=$(python3 "$BIN" status --file "$f" --reactive-429-file "$mk" --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "reactive_429"' && printf '%s' "$out" | grep -q '"reactive_429_marked": true'; then ok; else bad "case29 rc=$rc out=$out"; fi

echo "=== 30. PHASE 4: fresh reactive-429 marker promotes an otherwise-UNDER budget verdict -> crossed (the literal production scenario) ==="
d=$(case_dir c30); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
write_marker "$mk" "$(epoch_offset 1)"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$mk" --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "reactive_429"' && printf '%s' "$out" | grep -q '"source": "budget"'; then ok; else bad "case30 rc=$rc out=$out"; fi

echo "=== 31. PHASE 4: EXPIRED reactive-429 marker (age > 900s TTL) does NOT promote -- stays under (proves the TTL actually expires) ==="
d=$(case_dir c31); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
write_marker "$mk" "$(epoch_offset 901)"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$mk" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "under"' && printf '%s' "$out" | grep -q '"window": null' && printf '%s' "$out" | grep -q '"reactive_429_marked": false'; then ok; else bad "case31 rc=$rc out=$out"; fi

echo "=== 32. PHASE 4: marker file entirely ABSENT -> not crossed, no crash, valid JSON ==="
d=$(case_dir c32); f="$d/t.jsonl"
usage_line "$(now_ts)" 10 10 > "$f"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$d/does-not-exist.json" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && printf '%s' "$out" | grep -q '"reactive_429_marked": false' && printf '%s' "$out" | grep -q '"reactive_429_marked_at": null'; then ok; else bad "case32 rc=$rc out=$out"; fi

echo "=== 33. PHASE 4: malformed marker file (not valid JSON) -> not crossed, no crash ==="
d=$(case_dir c33); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
printf 'not json {{{' > "$mk"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$mk" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && printf '%s' "$out" | grep -q '"reactive_429_marked": false'; then ok; else bad "case33 rc=$rc out=$out"; fi

echo "=== 34. PHASE 4: marker file valid JSON but not an object (a list) -> not crossed, no crash ==="
d=$(case_dir c34); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
printf '[1, 2, 3]' > "$mk"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$mk" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"reactive_429_marked": false'; then ok; else bad "case34 rc=$rc out=$out"; fi

echo "=== 35. PHASE 4: marker object missing 'marked_at' entirely -> not crossed, no crash ==="
d=$(case_dir c35); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
printf '{"reason": "hmd-claude-retry"}' > "$mk"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$mk" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"reactive_429_marked": false'; then ok; else bad "case35 rc=$rc out=$out"; fi

echo "=== 36. PHASE 4: marker 'marked_at' is a non-numeric string -> not crossed, no crash ==="
d=$(case_dir c36); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
printf '{"marked_at": "not-a-number"}' > "$mk"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$mk" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"reactive_429_marked": false'; then ok; else bad "case36 rc=$rc out=$out"; fi

echo "=== 37. PHASE 4: marker 'marked_at' is a JSON boolean (true) -- bool is a python int subclass, must still be rejected -> not crossed ==="
d=$(case_dir c37); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
printf '{"marked_at": true}' > "$mk"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$mk" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"reactive_429_marked": false'; then ok; else bad "case37 rc=$rc out=$out"; fi

echo "=== 38. PHASE 4: marker 'marked_at' in the FUTURE (clock skew) -> age<0 rejected, not crossed ==="
d=$(case_dir c38); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
write_marker "$mk" "$(epoch_offset -500)"
out=$(python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$mk" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"reactive_429_marked": false'; then ok; else bad "case38 rc=$rc out=$out"; fi

echo "=== 39. PHASE 4: five_hour ALREADY crossed alone + an EXPIRED reactive marker -> verdict stays crossed via five_hour, window stays 'five_hour' ==="
d=$(case_dir c39); f="$d/t.jsonl"; rl="$d/rate-limits.json"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 99.0, 'resets_at': time.time() + 3600}}, open('$rl', 'w'))
"
write_marker "$mk" "$(epoch_offset 901)"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --reactive-429-file "$mk" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "five_hour"' && printf '%s' "$out" | grep -q '"reactive_429_marked": false'; then ok; else bad "case39 rc=$rc out=$out"; fi

echo "=== 40. PHASE 4: five_hour crossed + FRESH reactive marker -> window='five_hour+reactive_429' ==="
d=$(case_dir c40); f="$d/t.jsonl"; rl="$d/rate-limits.json"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 99.0, 'resets_at': time.time() + 3600}}, open('$rl', 'w'))
"
write_marker "$mk" "$(epoch_offset 5)"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --reactive-429-file "$mk" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"window": "five_hour+reactive_429"'; then ok; else bad "case40 rc=$rc out=$out"; fi

echo "=== 41. PHASE 4: seven_day crossed (five_hour under) + FRESH reactive marker -> window='seven_day+reactive_429' ==="
d=$(case_dir c41); f="$d/t.jsonl"; rl="$d/rate-limits.json"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 10.0, 'resets_at': time.time() + 3600}, 'seven_day': {'used_percentage': 99.0, 'resets_at': time.time() + 500000}}, open('$rl', 'w'))
"
write_marker "$mk" "$(epoch_offset 5)"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --reactive-429-file "$mk" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"window": "seven_day+reactive_429"'; then ok; else bad "case41 rc=$rc out=$out"; fi

echo "=== 42. PHASE 4: five_hour AND seven_day AND reactive marker all fresh/crossed -> window='all' ==="
d=$(case_dir c42); f="$d/t.jsonl"; rl="$d/rate-limits.json"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 96.0, 'resets_at': time.time() + 3600}, 'seven_day': {'used_percentage': 97.0, 'resets_at': time.time() + 500000}}, open('$rl', 'w'))
"
write_marker "$mk" "$(epoch_offset 5)"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --reactive-429-file "$mk" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"window": "all"'; then ok; else bad "case42 rc=$rc out=$out"; fi

echo "=== 43. PHASE 4: --reactive-429-file (CLI flag) takes precedence over HEIMDALL_429_MARKER_FILE (env) ==="
d=$(case_dir c43); f="$d/t.jsonl"; mk_env="$d/env-429-marker.json"; mk_cli="$d/cli-429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
write_marker "$mk_env" "$(epoch_offset 901)"
write_marker "$mk_cli" "$(epoch_offset 5)"
out=$(HEIMDALL_429_MARKER_FILE="$mk_env" python3 "$BIN" status --file "$f" --budget 1000000 --reactive-429-file "$mk_cli" --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "reactive_429"'; then ok; else bad "case43(cli-wins-over-env) rc=$rc out=$out"; fi

echo "=== 44. PHASE 4: HEIMDALL_429_MARKER_FILE env var honored when no --reactive-429-file flag given ==="
d=$(case_dir c44); f="$d/t.jsonl"; mk="$d/429-marker.json"
usage_line "$(now_ts)" 10 10 > "$f"
write_marker "$mk" "$(epoch_offset 5)"
out=$(HEIMDALL_429_MARKER_FILE="$mk" python3 "$BIN" status --file "$f" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "reactive_429"'; then ok; else bad "case44 rc=$rc out=$out"; fi

echo "=== 45. PHASE 5: an extra/unknown rate-limit window ALONE crosses threshold -- five_hour under, no seven_day -> verdict=crossed, window='extra:session' ==="
d=$(case_dir c45); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 10.0, 'resets_at': time.time() + 3600}, 'session': {'used_percentage': 97.0, 'resets_at': time.time() + 1800}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "extra:session"' && printf '%s' "$out" | grep -q '"used_percentage": 97.0'; then ok; else bad "case45 rc=$rc out=$out"; fi

echo "=== 46. PHASE 5: extra window crosses ALONGSIDE an already-crossed five_hour -> window='five_hour+extra:session' (additive, same shape as PHASE 4's five_hour+reactive_429) ==="
d=$(case_dir c46); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 99.0, 'resets_at': time.time() + 3600}, 'session': {'used_percentage': 97.0, 'resets_at': time.time() + 1800}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "five_hour+extra:session"'; then ok; else bad "case46 rc=$rc out=$out"; fi

echo "=== 47. PHASE 5: extra window present but UNDER threshold, base also under -> verdict=under, window=null, extra_windows still reports it (captured != crossed) ==="
d=$(case_dir c47); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 10.0, 'resets_at': time.time() + 3600}, 'session': {'used_percentage': 5.0, 'resets_at': time.time() + 1800}}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "under"' && printf '%s' "$out" | grep -q '"window": null' && printf '%s' "$out" | grep -q '"used_percentage": 5.0' && printf '%s' "$out" | grep -q '"crossed": false'; then ok; else bad "case47 rc=$rc out=$out"; fi

echo "=== 48. PHASE 5: malformed extra window (dict but missing used_percentage) + a stray NON-dict top-level key -> no crash, extra_windows == {} exactly ==="
d=$(case_dir c48); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 10.0, 'resets_at': time.time() + 3600}, 'session': {'resets_at': time.time() + 1800}, 'weird_stray_key': 12345}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "under"' && printf '%s' "$out" | grep -q '"extra_windows": {}'; then ok; else bad "case48 rc=$rc out=$out"; fi

echo "=== 49. PHASE 5 acceptance pin: rate-limit file missing entirely AND no budget configured -> verdict=unconfigured, NEVER a confident 'under' when blind to real usage ==="
d=$(case_dir c49); f="$d/t.jsonl"
usage_line "$(now_ts)" 10 10 > "$f"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$d/does-not-exist.json" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"verdict": "unconfigured"' && ! printf '%s' "$out" | grep -q '"verdict": "under"'; then ok; else bad "case49 rc=$rc out=$out"; fi

echo "=== 50. REGRESSION PIN: PHASE 3's 'both crossed' (case 22) reproduced with an extra UNDER-threshold window AND windows_seen also present -> window stays EXACTLY 'both', unchanged ==="
d=$(case_dir c50); f="$d/t.jsonl"; rl="$d/rate-limits.json"
usage_line "$(now_ts)" 10 10 > "$f"
python3 -c "
import json, time
json.dump({'observed_at': time.time(), 'five_hour': {'used_percentage': 96.0, 'resets_at': time.time() + 3600}, 'seven_day': {'used_percentage': 97.0, 'resets_at': time.time() + 500000}, 'session': {'used_percentage': 5.0, 'resets_at': time.time() + 1800}, 'windows_seen': ['five_hour', 'seven_day', 'session']}, open('$rl', 'w'))
"
out=$(python3 "$BIN" status --file "$f" --rate-limit-file "$rl" --budget 1000000 --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"verdict": "crossed"' && printf '%s' "$out" | grep -q '"window": "both"' && printf '%s' "$out" | grep -qF '"windows_seen": ["five_hour", "seven_day", "session"]'; then ok; else bad "case50 rc=$rc out=$out"; fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

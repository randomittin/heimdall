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

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

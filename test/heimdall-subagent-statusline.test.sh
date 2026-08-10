#!/usr/bin/env bash
#
# heimdall-subagent-statusline.test.sh — SUBAGENT statusline conformance (spec §9).
#
# The subagent statusline (sentinels/subagent-statusline.py) is INDEPENDENT of the
# sigil/main watchman: it reads ONE JSON object on stdin ({columns, tasks[]}) and
# emits ONE JSON line PER RUNNING task — {"id":..,"content":"<ansi row>"} — a ghost/
# faint transcript row per live subagent. It NEVER competes with the transcript and
# NEVER errors: malformed/empty input prints nothing, exits 0, writes no stderr.
#
# THIS SUITE LOCKS:
#   1. running-only: a mix of running + completed tasks yields EXACTLY ONE line,
#      for the RUNNING task's id — the completed task's id is OMITTED entirely.
#   2. format: the running row is `╰── hmd:<name> <desc> · <elapsed> ↓<tokens> <pct>%`
#      with humanized elapsed (4m10s) + tokens (708k) + round(tok/ctx*100) pct.
#   3. pct/token omission: a running task missing token fields drops ↓tokens AND pct.
#   4. empty/malformed: empty tasks → NO output + exit 0; garbage stdin → likewise.
#   5. every emitted line is valid JSON.
#   6. columns default: absent columns → default 80 (no crash, row still fits).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/subagent-statusline.py"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: subagent statusline missing at $SL"; exit 2; }

# Run the statusline with a FIXED clock (HMD_NOW) + NO_COLOR (so the emitted row is
# plain text and byte-assertable). stderr is captured separately to assert silence.
LAST_RC=0; LAST_ERR=""
run() {
  local json="$1" errfile out
  errfile="$(mktemp)"
  out="$(printf '%s' "$json" | env NO_COLOR=1 HMD_NOW=1250 python3 "$SL" 2>"$errfile")"
  LAST_RC=$?
  LAST_ERR="$(cat "$errfile")"; rm -f "$errfile"
  printf '%s' "$out"
}

# ── 1) running-only + 2) format ────────────────────────────────────────────────
# startTime=1000, HMD_NOW=1250 -> 250s -> 4m10s. tok=708000 -> 708k.
# ctx=1000000 -> pct=round(70.8)=71. A completed task is present and MUST be dropped.
echo "== 1) running-only + 2) format =="
J1='{"columns":120,"tasks":[
  {"id":"t-run","name":"coder","description":"implement auth","status":"running","startTime":1000,"tokenCount":708000,"model":"opus","contextWindowSize":1000000},
  {"id":"t-done","name":"reviewer","description":"review pr","status":"completed","startTime":1000,"tokenCount":42000,"model":"sonnet","contextWindowSize":1000000}
]}'
OUT="$(run "$J1")"
LINES="$(printf '%s\n' "$OUT" | grep -c .)"
[ "$LINES" = "1" ] && ok "exactly ONE line for one running task (got $LINES)" \
                    || bad "expected 1 line, got $LINES"
ID="$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["id"])' 2>/dev/null)"
[ "$ID" = "t-run" ] && ok "emitted id is the RUNNING task (t-run)" \
                     || bad "emitted id = '$ID', expected t-run"
grep -q 't-done' <<<"$OUT" && bad "completed task id t-done leaked into output" \
                                      || ok "completed task id OMITTED entirely"
CONTENT="$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["content"])' 2>/dev/null)"
case "$CONTENT" in
  "╰── hmd:coder implement auth · 4m10s ↓708k 71%") ok "content row exact: $CONTENT" ;;
  *) bad "content row mismatch: [$CONTENT]" ;;
esac

# ── 3) pct + token omission when token fields absent ────────────────────────────
echo "== 3) token/pct omission =="
J3='{"columns":120,"tasks":[
  {"id":"t-run","name":"coder","description":"no tokens","status":"running","startTime":1000,"model":"opus"}
]}'
OUT3="$(run "$J3")"
C3="$(printf '%s' "$OUT3" | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["content"])' 2>/dev/null)"
grep -q '%' <<<"$C3"  && bad "pct present when token fields absent: [$C3]" \
                                 || ok "pct omitted when token fields absent"
grep -q '↓' <<<"$C3"  && bad "↓tokens present when tokenCount absent: [$C3]" \
                                 || ok "↓tokens omitted when tokenCount absent"
grep -q '4m10s' <<<"$C3" && ok "elapsed still rendered: [$C3]" \
                                    || bad "elapsed missing: [$C3]"

# ── 4) empty tasks + malformed → NO output, exit 0, NO stderr ────────────────────
echo "== 4) empty / malformed → silent, exit 0 =="
OUT_EMPTY="$(run '{"columns":120,"tasks":[]}')"
[ -z "$OUT_EMPTY" ] && ok "empty tasks → no output" || bad "empty tasks emitted: [$OUT_EMPTY]"
[ "$LAST_RC" = "0" ] && ok "empty tasks → exit 0" || bad "empty tasks exit $LAST_RC"
[ -z "$LAST_ERR" ] && ok "empty tasks → no stderr" || bad "empty tasks wrote stderr: [$LAST_ERR]"

OUT_G="$(run 'not json at all {{{')"
[ -z "$OUT_G" ] && ok "garbage stdin → no output" || bad "garbage emitted: [$OUT_G]"
[ "$LAST_RC" = "0" ] && ok "garbage stdin → exit 0" || bad "garbage exit $LAST_RC"
[ -z "$LAST_ERR" ] && ok "garbage stdin → no stderr" || bad "garbage wrote stderr: [$LAST_ERR]"

OUT_EMPTYSTR="$(run '')"
[ -z "$OUT_EMPTYSTR" ] && ok "empty stdin → no output" || bad "empty stdin emitted: [$OUT_EMPTYSTR]"
[ "$LAST_RC" = "0" ] && ok "empty stdin → exit 0" || bad "empty stdin exit $LAST_RC"

# ── 5) every emitted line is valid JSON ──────────────────────────────────────────
echo "== 5) every line is valid JSON =="
J5='{"columns":100,"tasks":[
  {"id":"a","name":"coder","description":"one","status":"running","startTime":1000,"tokenCount":1200000,"model":"opus","contextWindowSize":2000000},
  {"id":"b","name":"tester","description":"two","status":"running","startTime":1200,"tokenCount":5000,"model":"haiku","contextWindowSize":200000}
]}'
OUT5="$(run "$J5")"
VALID="$(printf '%s\n' "$OUT5" | python3 -c '
import sys,json
n=0
for ln in sys.stdin:
    ln=ln.strip()
    if not ln: continue
    d=json.loads(ln)
    assert "id" in d and "content" in d, d
    n+=1
print(n)' 2>/dev/null)"
[ "$VALID" = "2" ] && ok "both running tasks → 2 valid JSON lines with id+content" \
                    || bad "expected 2 valid JSON lines, got '$VALID'"
# 1.2M humanization for tokenCount 1200000
grep -q '1.2M' <<<"$OUT5" && ok "tokens humanized to 1.2M" \
                                     || bad "1.2M humanization missing"

# ── 6) columns default 80 when absent (no crash, still emits) ────────────────────
echo "== 6) columns default 80 =="
J6='{"tasks":[{"id":"z","name":"coder","description":"defaults ok","status":"running","startTime":1000,"tokenCount":100,"model":"opus","contextWindowSize":1000}]}'
OUT6="$(run "$J6")"
[ -n "$OUT6" ] && ok "renders with columns absent (default 80)" \
               || bad "no output when columns absent"
printf '%s' "$OUT6" | python3 -c 'import sys,json; json.loads(sys.stdin.readline())' 2>/dev/null \
  && ok "columns-default line is valid JSON" || bad "columns-default line invalid JSON"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

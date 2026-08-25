#!/usr/bin/env bash
# test/heimdall-statusline-rate-limit-persist.test.sh — hermetic tests for the
# allowlisted rate_limits persister added to sentinels/hmd-statusline.py
# (persist_rate_limits / _rate_limit_state_path / _window_snapshot).
#
# WHY THIS EXISTS: bin/heimdall-session-usage cannot reach Anthropic's real
# rate_limits.* figures on its own (see its module docstring, PHASE 1
# FINDING) because they arrive ONLY on the live statusline hook's stdin. This
# statusline process is the only code in the repo that ever sees them, so it
# persists an ALLOWLISTED snapshot to disk for that tool to read. The single
# most important property under test here: the write is an ALLOWLIST, never
# a blanket stdin dump (stdin can carry session/transcript content) — and it
# is best-effort (never observable in what renders, never crashes on bad
# input).
#
# FALSIFIABLE CLAIMS TESTED:
#  1. fresh rate_limits in stdin -> exact five_hour+seven_day values persisted
#  2. a non-allowlisted stdin field (e.g. a transcript/session path) never
#     appears in the persisted file — proves this is an allowlist copy, not
#     a dump
#  3. rate_limits absent from stdin -> no file is written at all (true no-op)
#  4. malformed rate_limits (wrong types) -> no crash, no file written
#  5. persistence never changes stdout (the render is byte-identical whether
#     the persist write can succeed or not)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-statusline"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 unavailable"
  echo "heimdall-statusline-rate-limit-persist: 0 passed, 0 failed (SKIPPED — python3 unavailable)"
  exit 0
}
[ -x "$CLI" ] || { echo "FATAL: $CLI missing/not executable"; echo "heimdall-statusline-rate-limit-persist: 0 passed, 1 failed"; exit 1; }

# hermetic workspace — identical shape to heimdall-statusline-perf-budget.test.sh's
# mkws(), so a real filesystem read never leaks machine state into this suite.
mkws() {
  ws="$(mktemp -d)"; homed="$(mktemp -d)"; tmpd="$(mktemp -d)"
  mkdir -p "$ws/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$ws/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$ws/.heimdall/statusline.json"
  printf '%s|%s|%s' "$ws" "$homed" "$tmpd"
}

run_sl() {
  # run_sl <json-stdin> <rate-limit-file> -> stdout on stdout, exit code via $?
  json="$1"; rlfile="$2"
  triple="$(mkws)"; IFS='|' read -r ws homed tmpd <<EOF
$triple
EOF
  out="$(printf '%s' "$json" | env -i PATH="$PATH" HOME="$homed" LANG=en_US.UTF-8 \
      HEIMDALL_IDENTITY_DIR="$ws/.heimdall" HMD_HAID=rj HMD_NOW=1752410000 \
      HEIMDALL_CP_URL="http://127.0.0.1:1" TERM=xterm-256color \
      HMD_STATUSLINE_TMP="$tmpd" HEIMDALL_STATUSLINE_MODE=truecolor \
      HEIMDALL_RATE_LIMIT_STATE="$rlfile" \
      bash "$CLI")"
  rc=$?
  rm -rf "$ws" "$homed" "$tmpd"
  printf '%s' "$out"
  return "$rc"
}

echo "== 1) fresh rate_limits -> exact values persisted =="
RL="$(mktemp -u)"
JSON='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":10},"session_id":"p1","rate_limits":{"five_hour":{"used_percentage":42,"resets_at":9999999999},"seven_day":{"used_percentage":11}}}'
run_sl "$JSON" "$RL" >/dev/null
ERR="$(mktemp)"
if [ -f "$RL" ] && python3 -c "
import json
d = json.load(open('$RL'))
assert d['five_hour']['used_percentage'] == 42, d
assert d['five_hour']['resets_at'] == 9999999999, d
assert d['seven_day']['used_percentage'] == 11, d
assert 'observed_at' in d, d
" 2>"$ERR"; then
  ok "persisted file has exact five_hour+seven_day+observed_at values"
else
  bad "persisted file wrong/missing: $(cat "$RL" 2>/dev/null) err=$(cat "$ERR")"
fi
rm -f "$RL" "$ERR"

echo "== 2) allowlist, not a dump: non-rate_limits stdin fields never land in the file =="
RL="$(mktemp -u)"
JSON='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":10},"session_id":"p2","transcript_path":"/Users/rj/.claude/projects/secret/convo.jsonl","rate_limits":{"five_hour":{"used_percentage":55,"resets_at":9999999999}}}'
run_sl "$JSON" "$RL" >/dev/null
if [ -f "$RL" ] && ! grep -q "secret" "$RL" && ! grep -q "transcript_path" "$RL" && ! grep -q "session_id" "$RL" && ! grep -q "p2" "$RL"; then
  ok "no non-allowlisted stdin field reached the persisted file"
else
  bad "allowlist leak: $(cat "$RL" 2>/dev/null)"
fi
rm -f "$RL"

echo "== 3) rate_limits absent from stdin -> true no-op, no file written =="
RL="$(mktemp -u)"
JSON='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":10},"session_id":"p3"}'
run_sl "$JSON" "$RL" >/dev/null
if [ ! -e "$RL" ]; then
  ok "no rate_limits in stdin -> no file created"
else
  bad "file unexpectedly created with no rate_limits input: $(cat "$RL")"
fi

echo "== 4) malformed rate_limits (wrong types) -> no crash, no file written =="
RL="$(mktemp -u)"
JSON='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":10},"session_id":"p4","rate_limits":{"five_hour":"not-an-object"}}'
OUT="$(run_sl "$JSON" "$RL")"; RC=$?
if [ "$RC" -eq 0 ] && [ -n "$OUT" ] && [ ! -e "$RL" ]; then
  ok "malformed rate_limits -> exit 0, rendered normally, no file written"
else
  EXISTS=no; [ -e "$RL" ] && EXISTS=yes
  bad "malformed rate_limits mishandled: rc=$RC out_len=${#OUT} file_exists=$EXISTS"
fi
rm -f "$RL"

echo "== 5) persistence is invisible to stdout: byte-identical whether the persist write succeeds or fails =="
JSON='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":10},"session_id":"p5","rate_limits":{"five_hour":{"used_percentage":77,"resets_at":9999999999}}}'
RL_OK="$(mktemp -u)"
OUT_OK="$(run_sl "$JSON" "$RL_OK")"
rm -f "$RL_OK"
OUT_BROKEN="$(run_sl "$JSON" "/nonexistent-dir-xyz/rate-limits.json")"
if [ "$OUT_OK" = "$OUT_BROKEN" ]; then
  ok "render output identical whether the persist write succeeds or fails (best-effort confirmed)"
else
  bad "render output differs based on persist success — persistence is leaking into what renders"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

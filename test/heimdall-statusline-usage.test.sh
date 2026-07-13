#!/usr/bin/env bash
#
# heimdall-statusline-usage.test.sh — 5-HOUR USAGE-LIMIT INDICATOR (rightmost end).
#
# CC's stdin JSON carries rate_limits.five_hour.{used_percentage,resets_at} for
# Pro/Max accounts, ABSENT until the first API response. The statusline renders a
# right-pinned `5h NN%` (green→amber→red toward the cap) + a compact resets-in
# countdown WHEN PRESENT, and renders NOTHING (never a fabricated %) when absent.
#
# THIS SUITE LOCKS (driving the REAL statusline):
#   1. PRESENT → the 5-hour % renders, at the rightmost end of the top row.
#   2. ABSENT (no rate_limits) → no 5h indicator anywhere (no fabrication).
#   3. COLOR GRADE: <70 green (34;197;94), 70–89 amber (245;158;11), >=90 red
#      (239;68;68) — keyed to the FIVE-hour value, not seven-day.
#   4. RESETS COUNTDOWN: resets_at in the future → a `·Nh`/`·Nm` countdown appears.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

# render the full HUD (COLUMNS=120) with a given rate_limits JSON snippet (or none).
render() {
  rl="$1"   # e.g. ,"rate_limits":{...}  — empty for the absent case
  WS="$(mktemp -d)"; HOMED="$(mktemp -d)"; mkdir -p "$WS/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$WS/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$WS/.heimdall/statusline.json"
  printf '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall"}},"model":{"display_name":"Opus"},"context_window":{"used_percentage":42}%s}' "$WS" "$rl" \
    | env -i PATH="$PATH" HOME="$HOMED" \
        HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID=rj HMD_NOW=0 \
        HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS=120 LANG=en_US.UTF-8 \
        HEIMDALL_STATUSLINE_MODE=truecolor python3 "$SL"
  rm -rf "$WS" "$HOMED"
}

echo "== 1) present → 5h % renders =="
OUT="$(render ',"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":7200},"seven_day":{"used_percentage":88}}')"
printf '%s' "$OUT" | grep -qF '5h 42%' && ok "5h indicator 5h 42% present" || bad "5h indicator missing when rate_limits present"
# it must be the FIVE-hour value (42), NOT the seven-day (88)
printf '%s' "$OUT" | grep -qF '5h 88%' && bad "rendered the seven_day %, not five_hour" || ok "uses five_hour %, not seven_day"

echo "== 2) rightmost end of the top row =="
TOP="$(printf '%s' "$OUT" | head -1)"
# after stripping ANSI, the 5h token sits in the final third of the top row.
printf '%s' "$TOP" | python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m"); s=A.sub("",sys.stdin.read()).rstrip()
i=s.find("5h")
sys.exit(0 if i!=-1 and i > len(s)*2//3 else 1)' \
  && ok "5h indicator sits at the rightmost end of the top row" \
  || bad "5h indicator not right-aligned"

echo "== 3) absent → nothing (no fabrication) =="
OUT0="$(render '')"
printf '%s' "$OUT0" | grep -qE '5h [0-9]' && bad "fabricated a usage indicator with no rate_limits" || ok "no 5h indicator when rate_limits absent"

echo "== 4) color grade green→amber→red (keyed to five_hour) =="
G="$(render ',"rate_limits":{"five_hour":{"used_percentage":42}}')"
A_="$(render ',"rate_limits":{"five_hour":{"used_percentage":75}}')"
R="$(render ',"rate_limits":{"five_hour":{"used_percentage":95}}')"
printf '%s' "$G"  | grep -qE '38;2;34;197;94m5h 42%'   && ok "42% → green"  || bad "42% not green"
printf '%s' "$A_" | grep -qE '38;2;245;158;11m5h 75%'  && ok "75% → amber"  || bad "75% not amber"
printf '%s' "$R"  | grep -qE '38;2;239;68;68m5h 95%'   && ok "95% → red"    || bad "95% not red"

echo "== 5) resets-in countdown when resets_at is future =="
printf '%s' "$OUT" | python3 -c 'import sys,re
s=re.compile(r"\033\[[0-9;]*m").sub("",sys.stdin.read())
sys.exit(0 if "·2h" in s else 1)' && ok "resets countdown ·2h present" || bad "resets countdown missing"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

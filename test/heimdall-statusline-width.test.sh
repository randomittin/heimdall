#!/usr/bin/env bash
#
# heimdall-statusline-width.test.sh — STATUSLINE ROW-WIDTH / NO-WRAP CONFORMANCE.
#
# BUG: a single over-long row (a long model name, a deep swarm file path, a full
# team wall) made finalize() pad EVERY row to that row's width — wider than COLUMNS
# — so the terminal WRAPPED the block: the `HEIMDALL` header appeared TWICE and the
# 4-row sigil bled to ~8.5 visual rows. FIX: finalize() clamps each emitted row to
# COLUMNS − RMARGIN (dropping whole glyphs only, never slicing an escape/glyph), so
# no row can overflow and wrap.
#
# THIS SUITE LOCKS (driving the REAL statusline on an overflow-inducing fixture):
#   1. EXACTLY ONE `HEIMDALL` header line (no wrap-induced duplicate).
#   2. The sigil block is EXACTLY 4 text-rows (8px square, not 8.5).
#   3. NO rendered row exceeds COLUMNS visible cells (nothing wraps).
# Asserted across the full (≥120) and compact (80–119) density modes and a tight
# COLUMNS. FALSIFIER: drop the clamp in finalize() and the long-model fixture pushes
# a row past COLUMNS → assertion 3 goes RED and the header duplicates → 1 goes RED.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"
SEED=rj

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

# A LONG model display_name forces the top header row (eye-bracket + HEIMDALL +
# handle + model) far past the right block, so an UNCLAMPED finalize would pad every
# row to the overflow width and wrap the header. resets_at absent (no rate_limits).
LONGMODEL="Opus 4.8 $(printf 'A%.0s' $(seq 1 130))"

render_case() {
  cols="$1"
  WS="$(mktemp -d)"; HOMED="$(mktemp -d)"
  mkdir -p "$WS/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$WS/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$WS/.heimdall/statusline.json"
  printf '%s\n' '[{"handle":"nadia","haid":"haid:nadia","verdict":"working","file":"src/a/very/deep/path/module/component/file_name.ts","age_seconds":4},{"handle":"arjun","haid":"haid:arjun","verdict":"watching","file":"pkg/x/y/z/db.go","age_seconds":9},{"handle":"priya","haid":"haid:priya","verdict":"deny","file":"api.py","age_seconds":6}]' \
    > "$WS/.heimdall/.roster-cache.json"
  printf '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall"}},"model":{"display_name":"%s"},"context_window":{"used_percentage":42}}' "$WS" "$LONGMODEL" \
    | env -i PATH="$PATH" HOME="$HOMED" \
        HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID="$SEED" HMD_NOW=7 \
        HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS="$cols" LANG=en_US.UTF-8 \
        HEIMDALL_STATUSLINE_MODE=truecolor python3 "$SL"
  rm -rf "$WS" "$HOMED"
}

# metrics of one render → three lines: HEIMDALL-count, non-empty-row-count, max-width.
metrics() {
  render_case "$1" | python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
def w(l):
  s=A.sub("",l); n=0
  for ch in s:
    o=ord(ch)
    if o in (0x200B,0x200D,0xFE0F) or 0x0300<=o<=0x036F: continue
    if o==0x26A1 or 0x1100<=o<=0x115F or 0x2E80<=o<=0x303E or 0x3041<=o<=0x33FF or 0x3400<=o<=0x4DBF or 0x4E00<=o<=0x9FFF or 0xAC00<=o<=0xD7A3 or 0x1F000<=o<=0x1FAFF: n+=2
    else: n+=1
  return n
ls=[l for l in sys.stdin.read().split("\n") if l!=""]
print(sum(1 for l in ls if "HEIMDALL" in A.sub("",l)))
print(len(ls))
print(max((w(l) for l in ls), default=0))'
}

# run the three assertions for a (cols,label,expected-rows). ok/bad run in THIS
# shell (metrics is captured, the assertions are not) so pass/fail counts survive.
check() {
  cols="$1"; label="$2"; wantrows="$3"
  { read -r HC; read -r RC; read -r MX; } <<EOF
$(metrics "$cols")
EOF
  # full mode carries the HEIMDALL wordmark exactly once; compact/minimal carry it
  # zero times — in NO mode may a wrap ever duplicate it (>1).
  [ "$HC" -le 1 ] && ok "$label: HEIMDALL header not duplicated (count $HC)" \
                  || bad "$label: header rendered $HC times (wrap duplicate)"
  if [ "$label" = full ]; then
    [ "$HC" = 1 ] && ok "full: HEIMDALL header present exactly once" \
                  || bad "full: HEIMDALL header count $HC (expected 1)"
  fi
  [ "$RC" = "$wantrows" ] && ok "$label: sigil block exactly $wantrows text-rows (got $RC)" \
                          || bad "$label: rendered $RC rows (expected $wantrows — the bleed)"
  [ "$MX" -le "$cols" ] && ok "$label: max row width $MX <= COLUMNS $cols (no wrap)" \
                        || bad "$label: a row is $MX cells > COLUMNS $cols (wraps)"
}

echo "== full mode (COLUMNS=120) — overflow-inducing long model =="
check 120 full 4

echo "== compact mode (COLUMNS=100) =="
check 100 compact 2

echo "== tight width (COLUMNS=90) — nothing may wrap =="
check 90 tight 2

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

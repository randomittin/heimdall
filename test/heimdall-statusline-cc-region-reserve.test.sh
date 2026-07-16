#!/usr/bin/env bash
#
# heimdall-statusline-cc-region-reserve.test.sh — CC STATUSLINE REGION RESERVE / RIGHT-EDGE
# TRUNCATION.
#
# BUG (RJ, live render): the right edge of the statusline is visibly truncated — the tail of
# every row (watchman rail, team column, gauge readout) is eaten by Claude Code.
#
# ROOT CAUSE (MEASURED, not inferred). Claude Code sets $COLUMNS to the FULL TERMINAL WIDTH,
# NOT to the width of the statusLine region it will actually paint into. CC reserves a fixed
# 4 cells of built-in spacing and HARD-CLIPS the right edge of anything wider. Measured by
# driving the REAL `claude` binary (v2.1.211) inside pseudo-terminals of known width, with a
# probe statusLine that emitted a ruler of EXACTLY $COLUMNS cells, then reading back how many
# cells CC actually painted:
#
#     pty/$COLUMNS   ruler emitted   CC painted   RESERVE
#            80            80            76          4
#            95            95            91          4
#           120           120           116          4
#           160           160           156          4
#
# The reserve is CONSTANT (4) — not proportional. So the usable region is $COLUMNS - 4.
# The renderer previously resolved its layout width to $COLUMNS EXACTLY and hard-clamped every
# row to it (`honor CC $COLUMNS first + hard-clamp`, commit 9888500), which made every emitted
# row EXACTLY 4 cells too wide — guaranteeing CC clipped 4 cells off the right of EVERY row.
# That is why the "fix" made the truncation deterministic instead of removing it.
#
# THIS SUITE LOCKS (driving the REAL statusline, solo AND 3-person team, at 80/95/120/160):
#   1. NO row exceeds the CC-usable region ($COLUMNS - 4) — the anti-truncation invariant.
#      FALSIFIER: resolve to $COLUMNS exactly (the old code) → rows are 4 too wide → RED.
#   2. Rows still FULL-BLEED that region EXACTLY (== $COLUMNS - 4, not merely <=), so the fix
#      cannot be faked by under-rendering / short rows.
#   3. The reserve is honoured identically solo and with a team (the team column is the row
#      tail — it is what RJ actually saw clipped).
# HMD_STATUSLINE_RESERVE overrides the reserve (CC's spacing is undocumented and may change);
#   4. reserve=0 restores exact-$COLUMNS rows — proves the constant is a real knob, not a
#      hardcoded fudge.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"
RESERVE=4   # measured against claude v2.1.211 — see the table above

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

# render the REAL statusline. $2=solo|team, $3 (optional) = HMD_STATUSLINE_RESERVE override.
render_case() {
  cols="$1"; mode="$2"; res="${3:-}"
  WS="$(mktemp -d)"; HOMED="$(mktemp -d)"
  mkdir -p "$WS/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$WS/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$WS/.heimdall/statusline.json"
  if [ "$mode" = team ]; then
    printf '%s\n' '[{"handle":"nadia","haid":"haid:nadia","verdict":"running","file":"src/a/very/deep/path/component/file_name.ts","age_seconds":4},{"handle":"arjun","haid":"haid:arjun","verdict":"pass","file":"pkg/x/y/z/db.go","age_seconds":9},{"handle":"priya","haid":"haid:priya","verdict":"deny","file":"api.py","age_seconds":6}]' \
      > "$WS/.heimdall/.roster-cache.json"
  fi
  printf '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall"}},"model":{"display_name":"Opus 4.8"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":12.34,"total_duration_ms":9000000},"session_id":"r%s%s"}' "$WS" "$cols" "$mode" \
    | env -i PATH="$PATH" HOME="$HOMED" \
        HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID=rj HMD_NOW=7 \
        HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS="$cols" LANG=en_US.UTF-8 \
        HMD_STATUSLINE_TMP="$WS/tmp" \
        ${res:+HMD_STATUSLINE_RESERVE="$res"} \
        HEIMDALL_STATUSLINE_MODE=truecolor python3 "$SL"
  rm -rf "$WS" "$HOMED"
}

# distinct visible (ANSI-stripped, wide-glyph-aware) row widths, comma-joined
widths() {
  render_case "$1" "$2" "${3:-}" | python3 -c 'import sys,re
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
print(",".join(str(x) for x in sorted(set(w(l) for l in ls))))'
}

for mode in solo team; do
  echo "== $mode — every row must fit CC's region (\$COLUMNS - $RESERVE) =="
  for cols in 80 95 120 160; do
    want=$((cols - RESERVE))
    got="$(widths "$cols" "$mode")"
    # 1+2: exactly one distinct width, and it is EXACTLY the usable region
    if [ "$got" = "$want" ]; then
      ok "$mode COLUMNS=$cols: every row EXACTLY $want cells (fits CC region, full-bleed)"
    else
      bad "$mode COLUMNS=$cols: row widths {$got}, expected $want (= $cols - $RESERVE). Rows wider than $want are CLIPPED by CC (the right-edge truncation)."
    fi
  done
done

echo "== reserve knob =="
got="$(widths 120 team 0)"
[ "$got" = "120" ] && ok "HMD_STATUSLINE_RESERVE=0 → rows exactly 120 (knob is real, not a fudge)" \
                   || bad "HMD_STATUSLINE_RESERVE=0 → widths {$got}, expected 120"
got="$(widths 120 team 10)"
[ "$got" = "110" ] && ok "HMD_STATUSLINE_RESERVE=10 → rows exactly 110 (reserve is honoured)" \
                   || bad "HMD_STATUSLINE_RESERVE=10 → widths {$got}, expected 110"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

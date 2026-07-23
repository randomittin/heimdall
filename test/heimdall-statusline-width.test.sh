#!/usr/bin/env bash
#
# heimdall-statusline-width.test.sh — STATUSLINE ROW-WIDTH / NO-WRAP CONFORMANCE (v1
# full-bleed).
#
# The v1 layout lays three content rows to the RIGHT of the hero-sigil anchor, EACH
# padded/truncated to EXACTLY $COLUMNS visible cells (hmd_layout.pad_or_truncate /
# compose_with_sigil). The hero sigil is a perfect 8×8 = 4 half-block rows, so the
# render is 4 rows: content rows 1–3 beside sigil rows 1–3, and the sigil's 4th row
# beside a BLANK (space-padded) content row. An over-long segment (a long model name,
# a deep team file) can never widen a row past COLUMNS — it is truncated whole-glyph,
# never wrapped. The tiny tier (<40) collapses to ONE line.
#
# THIS SUITE LOCKS (driving the REAL statusline on an overflow-inducing fixture):
#   1. EXACTLY ONE `HEIMDALL` wordmark line at every multi-row tier (no wrap duplicate);
#      the tiny tier carries `HMD` (0 `HEIMDALL`), still one line.
#   2. The row count is EXACTLY 4 (full/mid/narrow — the untrimmed 8×8 sigil) or 1
#      (tiny) — never a bleed.
#   3. EVERY rendered row is EXACTLY COLUMNS visible cells (== , not merely <=): the
#      full-bleed layout fills the line precisely, so a wrap (width>COLUMNS) OR a short
#      row (width<COLUMNS) both fail.
# FALSIFIER: off-by-one the pad (cols-1) and assertion 3 goes RED; drop the 4-row
# compose and the row count / header-count assertions go RED.
#
# WIDTH SOURCE: this suite pins the RENDERER contract at a GIVEN layout width, so it renders
# with HMD_STATUSLINE_RESERVE=0 — COLUMNS IS the layout width here. In production the layout
# width is $COLUMNS MINUS CC's 4-cell statusLine region spacing (CC sets $COLUMNS to the FULL
# TERMINAL width, then clips the right edge of anything wider). That derivation is a separate
# contract, owned by heimdall-statusline-cc-region-reserve.test.sh.
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

# A LONG model display_name + deep team paths force every content segment far past the
# right edge, so an unpadded/unclamped layout would overflow and wrap.
LONGMODEL="Opus 4.8 $(printf 'A%.0s' $(seq 1 130))"

render_case() {
  cols="$1"
  WS="$(mktemp -d)"; HOMED="$(mktemp -d)"
  mkdir -p "$WS/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$WS/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$WS/.heimdall/statusline.json"
  printf '%s\n' '[{"handle":"nadia","haid":"haid:nadia","verdict":"working","file":"src/a/very/deep/path/module/component/file_name.ts","age_seconds":4},{"handle":"arjun","haid":"haid:arjun","verdict":"watching","file":"pkg/x/y/z/db.go","age_seconds":9},{"handle":"priya","haid":"haid:priya","verdict":"deny","file":"api.py","age_seconds":6}]' \
    > "$WS/.heimdall/.roster-cache.json"
  printf '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall"}},"model":{"display_name":"%s"},"context_window":{"used_percentage":42},"session_id":"w%s"}' "$WS" "$LONGMODEL" "$cols" \
    | env -i PATH="$PATH" HOME="$HOMED" \
        HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID="$SEED" HMD_NOW=7 \
        HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS="$cols" LANG=en_US.UTF-8 \
        HMD_STATUSLINE_TMP="$WS/tmp" HMD_STATUSLINE_RESERVE=0 \
        HEIMDALL_STATUSLINE_MODE=truecolor python3 "$SL"
  rm -rf "$WS" "$HOMED"
}

# metrics of one render → three lines: HEIMDALL-count, non-empty-row-count, and the set
# of DISTINCT visible (wcwidth) row widths (comma-joined).
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
print(",".join(str(x) for x in sorted(set(w(l) for l in ls))))'
}

# run the assertions for a (cols,label,expected-rows,expected-header-count).
check() {
  cols="$1"; label="$2"; wantrows="$3"; wanthdr="$4"
  { read -r HC; read -r RC; read -r WS; } <<EOF
$(metrics "$cols")
EOF
  [ "$HC" = "$wanthdr" ] && ok "$label: HEIMDALL wordmark count $HC (expected $wanthdr)" \
                         || bad "$label: HEIMDALL count $HC (expected $wanthdr — wrap/branding drift)"
  [ "$RC" = "$wantrows" ] && ok "$label: exactly $wantrows rows (got $RC)" \
                          || bad "$label: rendered $RC rows (expected $wantrows — the bleed)"
  [ "$WS" = "$cols" ] && ok "$label: every row EXACTLY $cols cells (full-bleed, no wrap)" \
                      || bad "$label: row widths {$WS} != COLUMNS $cols (wrap or short row)"
}

echo "== full mode (COLUMNS=120) — overflow-inducing long model =="
check 120 full 4 1

echo "== mid mode (COLUMNS=80) =="
check 80 mid 4 1

echo "== narrow mode (COLUMNS=48) — right rail dropped, still 4 exact rows =="
check 48 narrow 4 1

echo "== tiny mode (COLUMNS=30) — single line, HMD not HEIMDALL =="
check 30 tiny 1 0

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

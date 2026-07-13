#!/usr/bin/env bash
#
# heimdall-layout.test.sh — unit gate for sentinels/hmd_layout.py (statusline W1).
#
# hmd_layout is the pure row-assembly / layout layer for the 3-row statusline.
# SIGIL-KEEP interpretation (load-bearing, RJ constraint): the user's own 58-hero
# sigil stays as the LEFT ANCHOR; the identity/gauge/gates content lays out in the
# columns to the RIGHT of the sigil, and the gauge's "full-bleed" width is the FULL
# REMAINING width right of the sigil (cols - sigil_width - gutter).
#
# THIS SUITE LOCKS:
#   1. vis_width  — printable width after ANSI strip, wide-glyph aware (CJK = 2 cells).
#   2. pad_or_truncate — result is EXACTLY `width` visible cells (pad with spaces OR
#      truncate-with-…), incl. multi-byte + ANSI inputs, NEVER slicing an ANSI escape
#      or a wide glyph, re-closing SGR on clip.
#   3. left_right — right-aligns the right segment, gap = width-vis(l)-vis(r); on
#      overflow the LEFT is truncated first; result is EXACTLY `width`.
#   4. compose_with_sigil — prefixes each content row with the matching sigil row +
#      gutter, BLANKS the sigil prefix on rows past the sigil height, and every
#      composed row is EXACTLY `cols` wide. remaining_width == cols-sig_w-gutter.
#   5. width_tier — full(≥100)/mid(60-99)/narrow(40-59)/tiny(<40) boundaries at 40/60/100.
#   6. py_compile clean.
#
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MOD="$ROOT/sentinels/hmd_layout.py"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$MOD" ] || { echo "FATAL: hmd_layout.py missing at $MOD"; exit 2; }

echo "== py_compile =="
if python3 -m py_compile "$MOD" 2>/dev/null; then ok "py_compile clean"; else bad "py_compile clean"; fi

echo "== unit assertions =="
# One python process runs every assertion; each prints `ok <name>` / `FAIL <name>`.
python3 - "$MOD" <<'PY'
import sys, os, re, importlib.util
MOD = sys.argv[1]
spec = importlib.util.spec_from_file_location("hmd_layout", MOD)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

ANSI = re.compile(r"\033\[[0-9;]*m")
rc = 0
def check(name, cond):
    global rc
    if cond:
        print("  ok   " + name)
    else:
        print("  FAIL " + name); rc = 1

vw = m.vis_width
pt = m.pad_or_truncate
lr = m.left_right

# ── vis_width ────────────────────────────────────────────────────────────────
check("vis_width plain", vw("hello") == 5)
check("vis_width strips ANSI", vw("\033[31mhello\033[0m") == 5)
check("vis_width wide CJK = 2 cells each", vw("你好") == 4)
check("vis_width empty", vw("") == 0)

# ── pad_or_truncate: EXACT width ───────────────────────────────────────────────
check("pad short -> exact", vw(pt("ab", 5)) == 5)
check("pad short trailing spaces", pt("ab", 5) == "ab   ")
check("exact unchanged width", vw(pt("hello", 5)) == 5)
check("truncate long -> exact", vw(pt("HELLOWORLD", 5)) == 5)
check("truncate uses ellipsis", pt("HELLOWORLD", 5).endswith("…"))
check("width 0 -> empty", pt("hello", 0) == "")
check("width 1 truncate -> exact", vw(pt("hello", 1)) == 1)

# multi-byte wide, exact-width in all regimes
check("wide pad exact", vw(pt("你好", 6)) == 6)
check("wide unchanged exact", vw(pt("你好", 4)) == 4)
check("wide truncate no half-glyph (w3)", vw(pt("你好", 3)) == 3)
check("wide truncate no half-glyph (w2)", vw(pt("你好", 2)) == 2)

# ANSI input: exact width, no sliced escape, SGR re-closed on clip
clipped = pt("\033[31mHELLOWORLD\033[0m", 5)
check("ansi truncate exact width", vw(clipped) == 5)
check("ansi escape intact (opening SGR whole)", "\033[31m" in clipped)
check("ansi re-closed on clip", clipped.endswith("\033[0m"))
# every escape in the clipped string is a COMPLETE SGR (no sliced escape mid-sequence)
stripped = ANSI.sub("", clipped)
check("no dangling ESC byte after strip", "\033" not in stripped)

# ── left_right ─────────────────────────────────────────────────────────────────
row = lr("LEFT", "RIGHT", 20)
check("left_right exact width", vw(row) == 20)
check("left_right right-aligned", ANSI.sub("", row).endswith("RIGHT"))
check("left_right left present", ANSI.sub("", row).startswith("LEFT"))
check("left_right gap correct", ANSI.sub("", row) == "LEFT" + " " * 11 + "RIGHT")

# overflow: left truncated first, still exact, right intact
ov = lr("A_VERY_LONG_LEFT_SEGMENT", "RIGHT", 12)
check("left_right overflow exact width", vw(ov) == 12)
check("left_right overflow keeps right", ANSI.sub("", ov).endswith("RIGHT"))
check("left_right overflow truncates left (ellipsis)", "…" in ANSI.sub("", ov))

# right wider than width: still exact
rbig = lr("L", "THIS_RIGHT_IS_HUGE", 6)
check("left_right huge-right exact width", vw(rbig) == 6)

# ── compose_with_sigil ──────────────────────────────────────────────────────────
sig4 = ["ROW0____", "ROW1____", "ROW2____", "ROW3____"]  # 8 wide, 4 rows
content = ["identity-line", "GAUGE", "gates-line"]        # 3 content rows
COLS = 120; GUT = 2
comp = m.compose_with_sigil(sig4, content, cols=COLS, gutter=GUT)
check("compose rows = max(sigil,content)", len(comp) == 4)
check("compose every row exactly cols", all(vw(r) == COLS for r in comp))
check("compose prefixes sigil row0", ANSI.sub("", comp[0]).startswith("ROW0____"))
check("compose gutter after sigil", ANSI.sub("", comp[0])[8:8+GUT] == " " * GUT)
check("compose content after gutter", "identity-line" in ANSI.sub("", comp[0]))

# rows past the sigil height get a BLANK sigil-width prefix
sig2 = ["AA", "BB"]  # 2 wide, 2 rows
comp2 = m.compose_with_sigil(sig2, ["c0", "c1", "c2"], cols=40, gutter=GUT)
check("compose overflow-row count = content", len(comp2) == 3)
check("compose overflow row blank sigil prefix", ANSI.sub("", comp2[2])[:2] == "  ")
check("compose overflow rows exact cols", all(vw(r) == 40 for r in comp2))

# remaining_width == cols - sig_w - gutter (the full-bleed gauge width, sigil-keep)
rw = m.remaining_width(sig4, cols=COLS, gutter=GUT)
check("remaining_width = cols-sigw-gutter", rw == COLS - 8 - GUT)
# a gauge pre-rendered to remaining_width composes to an exactly-cols row (no re-pad)
gauge = "#" * rw
compg = m.compose_with_sigil(sig4, [gauge], cols=COLS, gutter=GUT)
check("full-bleed gauge row exact cols", vw(compg[0]) == COLS)
check("full-bleed gauge un-truncated", ("#" * rw) in ANSI.sub("", compg[0]))

# ── width_tier boundaries 40 / 60 / 100 ─────────────────────────────────────────
wt = m.width_tier
check("tier 120 full", wt(120) == "full")
check("tier 100 full (boundary)", wt(100) == "full")
check("tier 99 mid", wt(99) == "mid")
check("tier 80 mid", wt(80) == "mid")
check("tier 60 mid (boundary)", wt(60) == "mid")
check("tier 59 narrow", wt(59) == "narrow")
check("tier 40 narrow (boundary)", wt(40) == "narrow")
check("tier 39 tiny", wt(39) == "tiny")
check("tier 30 tiny", wt(30) == "tiny")

# ── never crash on odd input ─────────────────────────────────────────────────────
check("pad negative width -> empty", pt("x", -3) == "")
check("compose empty inputs", m.compose_with_sigil([], [], cols=80, gutter=2) == [])

sys.exit(rc)
PY
if [ $? -eq 0 ]; then ok "all unit assertions"; else bad "unit assertions (see FAIL lines above)"; fi

echo
echo "== summary =="
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "PASS"

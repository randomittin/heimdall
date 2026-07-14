#!/usr/bin/env bash
#
# heimdall-statusline-gauge.test.sh — Spec v2 falsifier for the two gauges in
# sentinels/hmd_gauge.py: the Row 2 blue-shader CONTEXT gauge (render_gauge) and
# the Row 4 rate-limit MICRO gauge (render_micro_gauge / micro_text).
#
# The reference math is transcribed from "HMD Statusline Spec v2.md" §2 — NOT
# read back from the module's own constants — so a spec-violating change goes RED.
#
# Properties (each names its known-bad RED):
#   compile      : py_compile clean.
#   exact-width  : main gauge visible width == `width` at {40,32,26,24} across
#                  truecolor/256/16/mono tiers.                RED if pad off-by-one.
#   gauge-fill   : filled-cell count == round(pct/100*width).  RED if fill floors.
#   null-pct     : used_pct=None -> 0 filled cells.            RED if fabricates a bar.
#   ramp-percell : the filled region is a PER-CELL gradient (many distinct bg
#                  colours), not a solid block.                RED if fill is flat.
#   ramp-tip     : tip cell is the ramp bright-end <70, gold #FFCB57 >=70, red
#                  #FF6B6B >=90 — tip only.                    RED if 70/90 swapped.
#   label-splice : CTX% always; `↓<tokens>` humanized (708k) present >=32 / gone
#                  <32; `$cost` present >=26 / gone <26.       RED if tiers wrong.
#   ink-flip     : when the fill overruns the right label, that label's fg flips
#                  to dark ink #0B0C10.                        RED if faint-on-bright.
#   micro-width  : micro-gauge bar (▓+░) == width at 12c and 8c.  RED if off.
#   micro-ramp   : 5h fill ramps its cyan hue; a >=90 micro tip goes red.
#   micro-text   : micro_text exact strings; pct=None -> bare label, never "0%".
#   downgrade    : 256 has 48;5 not 48;2; 16 has neither; mono is a plain ASCII bar.
#
# Usage:  test/heimdall-statusline-gauge.test.sh   (exit 0 = all properties hold)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GAUGE="$ROOT/sentinels/hmd_gauge.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$GAUGE" ] || { echo "FATAL: gauge module missing at $GAUGE"; exit 2; }

# py_compile gate (fast, first).
if ! python3 -m py_compile "$GAUGE" 2>/tmp/hmd-gauge2-pyc.err; then
    echo "  FAIL py_compile"; cat /tmp/hmd-gauge2-pyc.err; exit 1
fi
echo "  ok   py_compile"

python3 - "$GAUGE" <<'PY'
import sys, re, importlib.util

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("hmd_gauge", path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
TC = m.TC

ANSI = re.compile("\033\\[[0-9;]*m")
BG   = re.compile("\033\\[48;2;(\\d+);(\\d+);(\\d+)m")

# spec endpoints / colours (transcribed from Spec v2 §2, not the module)
CYAN = (0x5A, 0xD7, 0xE6); GOLD = (0xFF, 0xCB, 0x57); RED = (0xFF, 0x6B, 0x6B)
INK  = (0x0B, 0x0C, 0x10)
TRACK = {(0x18, 0x1B, 0x24), (0x14, 0x16, 0x1E)}

def caps(color, uni):
    return TC.Caps(color, uni, False, "", color)

CT   = caps(TC.TRUECOLOR, TC.FULL)
C256 = caps(TC.C256, TC.FULL)
C16  = caps(TC.C16, TC.FULL)
MONO = caps(TC.MONO, TC.ASCII)

pas = 0; fail = 0
def ok(n):
    global pas; pas += 1; print("  ok   %s" % n)
def bad(n, d=""):
    global fail; fail += 1; print("  FAIL %s %s" % (n, d))

def strip(s): return ANSI.sub("", s)
def vis(s):   return TC.display_width(strip(s), TC.FULL)   # grapheme-cell width

def cells_bg(s):
    """Reconstruct per-visible-cell background from a truecolor render."""
    out = []; cur = None; i = 0
    while i < len(s):
        mo = re.match("\033\\[[0-9;]*m", s[i:])
        if mo:
            seg = mo.group(0)
            b = BG.match(seg)
            if b:
                cur = (int(b.group(1)), int(b.group(2)), int(b.group(3)))
            i += len(seg); continue
        out.append(cur); i += 1
    return out

def fill_bgs(s):
    return [c for c in cells_bg(s) if c is not None and c not in TRACK]

def fill_count(s):
    return len(fill_bgs(s))

# ── exact-width : EXACTLY `width` visible cells at every spec tier width ───────
w_ok = True
for width in (40, 32, 26, 24):
    for pct in (0, 1, 42, 69, 70, 89, 90, 100):
        for cp in (CT, C256, C16, MONO):
            r = m.render_gauge(width, pct, 708000, 4.12, cp)
            if vis(r) != width:
                w_ok = False
                bad("exact-width", "w=%d pct=%d tier=%s got=%d" % (width, pct, cp.color, vis(r)))
                break
        if not w_ok: break
    if not w_ok: break
if w_ok: ok("exact-width (40/32/26/24 x pct sweep x 4 tiers)")

# ── gauge-fill : round(pct/100*width) ─────────────────────────────────────────
f_ok = True
for width in (24, 26, 32, 40):
    for pct in (0, 1, 50, 69, 70, 89, 90, 100):
        exp = max(0, min(width, round(pct / 100.0 * width)))
        got = fill_count(m.render_gauge(width, pct, 708000, 4.12, CT, labels=False))
        if got != exp:
            f_ok = False
            bad("gauge-fill", "w=%d pct=%d exp=%d got=%d" % (width, pct, exp, got))
if f_ok: ok("gauge-fill == round(pct/100*width)")

# ── null-pct : None -> 0 fill ─────────────────────────────────────────────────
if fill_count(m.render_gauge(40, None, 708000, 4.12, CT, labels=False)) == 0:
    ok("null-pct -> 0 fill")
else:
    bad("null-pct", "expected 0 filled cells")

# ── ramp-percell : the fill is a PER-CELL gradient, not a solid block ─────────
distinct = len(set(fill_bgs(m.render_gauge(40, 60, 708000, 4.12, CT, labels=False))))
# fill@40/60% == 24 cells; a per-cell #1E2F73->#4264FF->#5AD7E6 ramp yields ~24
# distinct bg colours. A flat/solid fill would be 1. Threshold 18 = clearly graded.
if distinct >= 18:
    ok("ramp-percell (fill has %d distinct bg colours)" % distinct)
else:
    bad("ramp-percell", "only %d distinct fill bg colours (solid fill?)" % distinct)

# ── ramp-tip : bright-end <70, gold >=70, red >=90 (tip only) ─────────────────
def tip_bg(width, pct):
    bgs = fill_bgs(m.render_gauge(width, pct, 708000, 4.12, CT, labels=False))
    return bgs[-1] if bgs else None
t50, t75, t95 = tip_bg(40, 50), tip_bg(40, 75), tip_bg(40, 95)
if t50 == CYAN and t75 == GOLD and t95 == RED:
    ok("ramp-tip remaps at 70/90 (cyan-end / gold / red)")
else:
    bad("ramp-tip", "tip50=%s tip75=%s tip95=%s" % (t50, t75, t95))
# tip-only: at 95%, the fill must NOT be all-red (identity hue survives inward).
red_cells = [c for c in fill_bgs(m.render_gauge(40, 95, 708000, 4.12, CT, labels=False)) if c == RED]
if 0 < len(red_cells) <= m.TIP_CELLS + 1:
    ok("ramp-tip is TIP-ONLY (%d red cells, not a red bar)" % len(red_cells))
else:
    bad("ramp-tip tip-only", "red cells=%d (expected <= tip)" % len(red_cells))

# ── label-splice : CTX always; ↓tokens >=32; $cost >=26 ───────────────────────
r40 = strip(m.render_gauge(40, 42, 708000, 4.12, CT))
r32 = strip(m.render_gauge(32, 42, 708000, 4.12, CT))
r31 = strip(m.render_gauge(31, 42, 708000, 4.12, CT))
r26 = strip(m.render_gauge(26, 42, 708000, 4.12, CT))
r25 = strip(m.render_gauge(25, 42, 708000, 4.12, CT))
r24 = strip(m.render_gauge(24, 42, 708000, 4.12, CT))
checks = [
    ("CTX in 40", "CTX 42%" in r40),
    ("708k humanized in 40", "708k" in r40),
    ("$cost in 40", "$4.12" in r40),
    ("↓tokens present at 32", "708k" in r32),
    ("↓tokens dropped at 31 (<32)", "708k" not in r31),
    ("CTX still present at 31", "CTX 42%" in r31),
    ("$cost present at 26", "$4.12" in r26),
    ("$cost dropped at 25 (<26)", "$4.12" not in r25),
    ("CTX present at 24 (min bar)", "CTX 42%" in r24),
]
ls_ok = True
for name, cond in checks:
    if not cond:
        ls_ok = False; bad("label-splice", name)
if ls_ok: ok("label-splice (CTX always, ↓tokens<32 drop, $cost<26 drop)")

# ── ink-flip : right label fg flips to dark ink when the fill overruns it ──────
hi = m.render_gauge(40, 96, 708000, 4.12, CT)   # fill ~38 -> overruns $cost@34..38
lo = m.render_gauge(40, 5, 708000, 4.12, CT)    # fill ~2  -> $cost stays faint
ink = "38;2;%d;%d;%d" % INK
if (ink in hi) and (ink not in lo):
    ok("ink-flip: right label -> dark ink on fill-overrun (#0B0C10)")
else:
    bad("ink-flip", "ink_in_hi=%s ink_in_lo=%s" % (ink in hi, ink not in lo))

# ── micro-width : the bar (▓+░) is EXACTLY `width` cells ──────────────────────
def bar_cells(s):
    t = strip(s)
    return t.count("▓") + t.count("░")
mw_ok = True
for width in (12, 8):
    for pct in (0, 1, 28, 70, 90, 100):
        got = bar_cells(m.render_micro_gauge(width, CYAN, pct, CT, "5h", reset_h=3))
        if got != width:
            mw_ok = False
            bad("micro-width", "w=%d pct=%d bar=%d" % (width, pct, got))
if mw_ok: ok("micro-width (12c & 8c bar == exactly N cells)")

# micro-gauge carries label + pct + reset in its rendered text
mg = strip(m.render_micro_gauge(12, CYAN, 28, CT, "5h", reset_h=3))
if mg.startswith("5h ") and "28%" in mg and "·3h" in mg:
    ok("micro-gauge text: `5h <bar> 28% ·3h`")
else:
    bad("micro-gauge text", repr(mg))

# ── micro-ramp : 5h fill ramps cyan hue; a >=90 micro tip goes red ────────────
def micro_fill_fgs(s):
    """fg colour of each ▓ fill glyph, in order."""
    out = []; cur = None; i = 0
    FG = re.compile("\033\\[38;2;(\\d+);(\\d+);(\\d+)m")
    while i < len(s):
        mo = re.match("\033\\[[0-9;]*m", s[i:])
        if mo:
            seg = mo.group(0); f = FG.match(seg)
            if f: cur = (int(f.group(1)), int(f.group(2)), int(f.group(3)))
            i += len(seg); continue
        if s[i] == "▓": out.append(cur)
        i += 1
    return out
mfill = micro_fill_fgs(m.render_micro_gauge(12, CYAN, 95, CT, "5h"))
if mfill and mfill[-1] == RED:
    ok("micro-ramp: 5h tip -> red at >=90 (same rule as main gauge)")
else:
    bad("micro-ramp", "tip fg=%s" % (mfill[-1] if mfill else None))

# ── micro-text : exact strings; None -> bare label (never "0%") ───────────────
mt = [
    ("micro_text('5h',28,3)", m.micro_text("5h", 28, 3), "5h 28% ·3h"),
    ("micro_text('7d',41)",   m.micro_text("7d", 41),    "7d 41%"),
    ("micro_text('5h')",      m.micro_text("5h"),        "5h"),
]
mt_ok = True
for name, got, exp in mt:
    if got != exp:
        mt_ok = False; bad("micro-text", "%s -> %r (want %r)" % (name, got, exp))
if mt_ok: ok("micro-text exact (`5h 28% ·3h` / `7d 41%` / `5h`)")

# pct=None on the renderer -> bare label, no bar, no "0%"
none_r = strip(m.render_micro_gauge(12, CYAN, None, CT, "5h"))
if none_r == "5h" and "%" not in none_r and "▓" not in none_r:
    ok("micro None-pct -> bare label only (never 0%)")
else:
    bad("micro None-pct", repr(none_r))

# ── downgrade : tier-correct SGR ──────────────────────────────────────────────
s256 = m.render_gauge(40, 55, 708000, 4.12, C256)
s16  = m.render_gauge(40, 55, 708000, 4.12, C16)
smono = m.render_gauge(40, 55, 708000, 4.12, MONO)
if ("48;2;" not in s256) and ("48;5;" in s256) and ("38;2;" not in s256):
    ok("downgrade 256: 48;5 present, no 48;2/38;2")
else:
    bad("downgrade 256", repr(s256[:60]))
if ("48;2;" not in s16) and ("48;5;" not in s16) and ("\033[" in s16):
    ok("downgrade 16: no 48;2 / no 48;5")
else:
    bad("downgrade 16", repr(s16[:60]))
if ("38;2;" not in smono) and ("48;2;" not in smono) and ("\033[" not in smono):
    ok("downgrade mono: plain ASCII, no truecolor SGR")
else:
    bad("downgrade mono", repr(smono[:60]))
if smono.startswith("[") and smono.endswith("]") and len(smono) == 40:
    ok("mono ASCII bar exact width")
else:
    bad("mono bar", repr(smono))
# micro-gauge on mono -> plain micro_text
mmono = m.render_micro_gauge(12, CYAN, 28, MONO, "5h", reset_h=3)
if ("\033[" not in mmono) and mmono == m.micro_text("5h", 28, 3):
    ok("micro downgrade mono -> plain micro_text")
else:
    bad("micro mono", repr(mmono))

print("\nSUMMARY: %d passed, %d failed" % (pas, fail))
sys.exit(1 if fail else 0)
PY
rc=$?
[ $rc -eq 0 ] && echo "ALL GAUGE V2 TESTS PASSED" || echo "GAUGE V2 TESTS FAILED"
exit $rc

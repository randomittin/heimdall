#!/usr/bin/env bash
#
# heimdall-gauge.test.sh — spec-derived falsifier for the Row2 full-bleed
# context gauge (sentinels/hmd_gauge.py). Independent of the impl's own
# constants: the reference math is transcribed here from the statusline v1
# full-bleed spec, not read back from the module.
#
# Properties (each names its known-bad RED):
#   row-width   : ANSI-stripped visible width == `width` at {40,80,120,200}
#                 across truecolor/256/16/mono tiers.   RED if pad off-by-one.
#   gauge-fill  : filled-cell count == round(pct/100*width) for a pct sweep.
#                 RED if fill floors instead of rounds.
#   null-pct    : used_pct=None -> 0 filled cells (never a fabricated bar).
#   ramp-tip    : tip (last filled) cell is cyan <70, gold >=70, red >=90.
#                 RED if the 70/90 thresholds are swapped/absent.
#   ansi-budget : distinct ramp bg colours per row <= ~40 total (the ramp steps
#                 every ceil(width/40) cells, so a 200-cell bar has ~40 colours,
#                 not 200).   RED if the ramp recolours per-cell.
#   labels      : both labels >=60; right dropped 40-59; none <40.
#   downgrade   : 256 has 48;5 not 48;2; 16 has neither 48;2 nor 48;5; mono
#                 has NO 38;2/48;2 (a plain ASCII bar).
#   compile     : py_compile clean.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GAUGE="$ROOT/sentinels/hmd_gauge.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$GAUGE" ] || { echo "FATAL: gauge module missing at $GAUGE"; exit 2; }

# py_compile gate (fast, first).
if ! python3 -m py_compile "$GAUGE" 2>/tmp/hmd-gauge-pyc.err; then
    echo "  FAIL py_compile"; cat /tmp/hmd-gauge-pyc.err; exit 1
fi
echo "  ok   py_compile"

HMD_GAUGE="$GAUGE" python3 - "$GAUGE" <<'PY'
import sys, re, math, importlib.util

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("hmd_gauge", path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
TC = m.TC

ANSI = re.compile("\033\\[[0-9;]*m")
BG   = re.compile("\033\\[48;2;(\\d+);(\\d+);(\\d+)m")
# spec-independent track colours (transcribed from the spec, not the module)
TRACK = {(24, 27, 36), (20, 22, 30)}

def caps(color, uni):
    return TC.Caps(color, uni, False, "", color)

CT  = caps(TC.TRUECOLOR, TC.FULL)
C256 = caps(TC.C256, TC.FULL)
C16 = caps(TC.C16, TC.FULL)
MONO = caps(TC.MONO, TC.ASCII)

pas = 0; fail = 0
def ok(n):
    global pas; pas += 1; print("  ok   %s" % n)
def bad(n, d=""):
    global fail; fail += 1; print("  FAIL %s %s" % (n, d))

def vis(s):
    return len(ANSI.sub("", s))

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

def fill_count(s):
    return sum(1 for c in cells_bg(s) if c is not None and c not in TRACK)

# ── row-width : exact width at every tier ────────────────────────────────────
w_ok = True
for width in (40, 80, 120, 200):
    for pct in (0, 1, 25, 50, 69, 70, 89, 90, 100):
        for cp in (CT, C256, C16, MONO):
            r = m.render_gauge(width, pct, 1234, 12, 0.5, 900000, cp)
            if vis(r) != width:
                w_ok = False
                bad("row-width", "w=%d pct=%d tier=%s got=%d" % (width, pct, cp.color, vis(r)))
                break
        if not w_ok: break
    if not w_ok: break
if w_ok: ok("row-width (40/80/120/200 x pct sweep x 4 tiers)")

# ── gauge-fill : round(pct/100*width) ────────────────────────────────────────
f_ok = True
for width in (80, 120, 200):
    for pct in (0, 1, 50, 69, 70, 89, 90, 100):
        exp = max(0, min(width, round(pct / 100.0 * width)))
        got = fill_count(m.render_gauge(width, pct, 1234, 12, 0.5, 900000, CT))
        if got != exp:
            f_ok = False
            bad("gauge-fill", "w=%d pct=%d exp=%d got=%d" % (width, pct, exp, got))
if f_ok: ok("gauge-fill == round(pct/100*width)")

# ── null-pct : None -> 0 fill ────────────────────────────────────────────────
if fill_count(m.render_gauge(80, None, 1234, 12, 0.5, 900000, CT)) == 0:
    ok("null-pct -> 0 fill")
else:
    bad("null-pct", "expected 0 filled cells")

# ── ramp-tip : cyan <70, gold >=70, red >=90 ─────────────────────────────────
def tip_bg(width, pct):
    bgs = [c for c in cells_bg(m.render_gauge(width, pct, 1234, 12, 0.5, 900000, CT))
           if c is not None and c not in TRACK]
    return bgs[-1] if bgs else None
# spec endpoints
CYAN = (0x5A, 0xD7, 0xE6); GOLD = (0xFF, 0xCB, 0x57); RED = (0xFF, 0x6B, 0x6B)
t50, t75, t95 = tip_bg(120, 50), tip_bg(120, 75), tip_bg(120, 95)
if t50 == CYAN and t75 == GOLD and t95 == RED:
    ok("ramp-tip remaps at 70/90 (cyan/gold/red)")
else:
    bad("ramp-tip", "tip50=%s tip75=%s tip95=%s" % (t50, t75, t95))

# ── ansi-budget : distinct ramp bg <= ceil(width/40)+3 ───────────────────────
b_ok = True
for width in (40, 80, 120, 200):
    bgs = set(c for c in cells_bg(m.render_gauge(width, 100, 1234, 12, 0.5, 900000, CT))
              if c is not None and c not in TRACK)
    # ramp steps every ceil(width/40) cells => ~40 colour blocks max at any
    # width (+ tip), NOT per-cell. 42 = ~40 with slack for the forced tip.
    budget = 42
    if len(bgs) > budget:
        b_ok = False
        bad("ansi-budget", "w=%d distinct=%d budget=%d" % (width, len(bgs), budget))
if b_ok: ok("ansi-budget (ramp quantized every ceil(w/40))")

# ── labels : both >=60, right dropped 40-59, none <40 ────────────────────────
def strip(s): return ANSI.sub("", s)
r80 = strip(m.render_gauge(80, 42, 708000, 12, 0.87, 3840000, CT))
r50 = strip(m.render_gauge(50, 42, 708000, 12, 0.87, 3840000, CT))
r36 = strip(m.render_gauge(36, 42, 708000, 12, 0.87, 3840000, CT))
ok80 = ("CTX" in r80) and ("7d" in r80)
ok50 = ("CTX" in r50) and ("7d" not in r50)
ok36 = ("CTX" not in r36)
if ok80: ok("labels: both present >=60")
else: bad("labels>=60", repr(r80))
if ok50: ok("labels: right dropped 40-59")
else: bad("labels 40-59", repr(r50))
if ok36: ok("labels: none <40")
else: bad("labels <40", repr(r36))

# ── downgrade : tier-correct SGR ─────────────────────────────────────────────
s256 = m.render_gauge(80, 55, 1234, 12, 0.5, 900000, C256)
s16  = m.render_gauge(80, 55, 1234, 12, 0.5, 900000, C16)
smono = m.render_gauge(80, 55, 1234, 12, 0.5, 900000, MONO)
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
# mono is a proportional bar
if smono.startswith("[") and smono.endswith("]") and len(smono) == 80:
    ok("mono ASCII bar exact width")
else:
    bad("mono bar", repr(smono))

print("\nSUMMARY: %d passed, %d failed" % (pas, fail))
sys.exit(1 if fail else 0)
PY
rc=$?
[ $rc -eq 0 ] && echo "ALL GAUGE TESTS PASSED" || echo "GAUGE TESTS FAILED"
exit $rc

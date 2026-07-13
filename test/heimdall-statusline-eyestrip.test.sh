#!/usr/bin/env bash
# heimdall-statusline-eyestrip.test.sh — the teammate EYE-STRIP render (eye_strip): the
# EYE band of the 8×8 hero face (pixel rows 3–6 = 2 `▄` text-rows, 8 cells wide) in the
# hero's OWN natural palette, cropped so the EYES are visible for every hero.
#
# WHY: the old top_half() cropped pixel rows 0–3 (the top of the head) → the eyes sat
# BELOW the crop and were invisible (Spec v2 §4 bug). eye_strip crops the eye band and
# AUTO-CENTERS the window on a hero's eye row when it falls outside the default [3,6], so
# the eyes are always in frame — batsy, black-bolt, captain-america all show their eyes.
#
# CONTRACT (all DERIVED from the existing 58-hero grids — nothing hand-authored):
#   1. SHAPE     — eye_strip(seed) is exactly 2 text-rows, 8 cells wide each, exit 0; every
#                  one of the 58 heroes renders a valid 2×8 strip.
#   2. EYES-VIS  — a hero with an authored eye token ('2') surfaces its OWN eye color in the
#                  rendered strip (the eyes are inside the crop, not below it); true for ALL
#                  eye-bearing heroes.
#   3. AUTO-SHIFT— a hero whose eye row is OUTSIDE the default [3,6] (black-bolt: row 0)
#                  shifts the 4-px window (top != 3) so the eye row lands inside it; a hero
#                  whose eye row is INSIDE (cyclops: row 3) keeps the default window.
#   4. NATURAL   — the strip carries the hero's OWN palette (distinct heroes look distinct);
#                  it is NOT a single-hue recolour.
#   5. TIER      — one-pass downgrade: 256 uses 48;5 (no 24-bit leak), mono strips ALL color.
#   6. ADDITIVE  — sigil_render(...,'S'/'M'/'L') is byte-UNCHANGED (eye_strip is a parallel
#                  crop, touches no shared render path); top_half is now the eye_strip alias.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SIG" ] || { echo "FATAL: sigil core missing at $SIG"; exit 2; }

PY="$(mktemp -t eyestrip.XXXXXX.py)"
trap 'rm -f "$PY"' EXIT
cat > "$PY" <<'PYEOF'
import importlib.util, sys, re
spec = importlib.util.spec_from_file_location("s", sys.argv[1])
S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
STRIP = re.compile(r"\033\[[0-9;]*m")
def vis(x): return STRIP.sub("", x)
P = [0]; F = [0]
def ok(m): P[0] += 1; print("  ok   " + m)
def bad(m): F[0] += 1; print("  FAIL " + m)
tc = S.tier_caps("truecolor")

def eye_count(seed):
    got = S.custom_for(seed)
    if got is not None:
        grid, _ = got
        return [sum(1 for c in range(8) if grid[r][c] == '2') for r in range(8)]
    g, _, _ = S.grid_for(seed)
    return [sum(1 for c in range(8) if g[r][c] == 2) for r in range(8)]

# 1) SHAPE
lines = S.eye_strip("batsy", tc)
ok("eye_strip is exactly 2 text-rows") if len(lines) == 2 else bad("eye_strip rows=%d (want 2)" % len(lines))
wok = all(S.TC.display_width(vis(l)) == 8 for l in lines)
ok("eye_strip rows are 8 cells wide") if wok else bad("eye_strip width != 8: %r" % [vis(l) for l in lines])
allrender = True; badhero = None
for name in S.HERO_ORDER:
    try:
        ls = S.eye_strip(name, tc)
        if len(ls) != 2 or any(S.TC.display_width(vis(l)) != 8 for l in ls):
            allrender = False; badhero = name
    except Exception as e:
        allrender = False; badhero = "%s (%s)" % (name, e)
ok("all %d heroes render a valid 2x8 eye_strip, exit 0" % len(S.HERO_ORDER)) if allrender else bad("hero eye_strip invalid: %s" % badhero)

# 2) EYES-VISIBLE — every eye-bearing hero surfaces its OWN eye color inside the strip
missing = []
for name in S.HERO_ORDER:
    spec_h = S.HERO_SIGILS[name]
    if 'eye' not in spec_h or not any('2' in row for row in spec_h['grid']):
        continue
    er, eg, eb = S._hex_rgb(spec_h['eye'])
    needle = "2;%d;%d;%d" % (er, eg, eb)   # the eye rgb in an SGR (38;2;.. or 48;2;..)
    if needle not in "\n".join(S.eye_strip(name, tc)):
        missing.append(name)
ok("every eye-bearing hero renders its eye color in the strip (eyes visible)") if not missing else bad("eyes NOT in strip for: %r" % missing)
# batsy specifically: eye row 4 is in the strip, eye color present
be_r, be_g, be_b = S._hex_rgb(S.HERO_SIGILS["batsy"]["eye"])
ok("batsy eyes visible (%s in strip)" % ("2;%d;%d;%d" % (be_r, be_g, be_b))) \
    if ("2;%d;%d;%d" % (be_r, be_g, be_b)) in "\n".join(S.eye_strip("batsy", tc)) else bad("batsy eyes missing from strip")

# 3) AUTO-SHIFT — eye row outside [3,6] shifts the window; inside keeps the default
bb = eye_count("black-bolt")
bb_eye = max(range(8), key=lambda r: (bb[r], -abs(r - 3.5)))
bb_top = S._eye_strip_top(bb)
ok("black-bolt eye row (%d) is OUTSIDE default [3,6]" % bb_eye) if not (3 <= bb_eye <= 6) else bad("black-bolt eye row %d unexpectedly in range" % bb_eye)
ok("black-bolt window SHIFTED (top=%d != default 3)" % bb_top) if bb_top != 3 else bad("black-bolt window did not shift (top=%d)" % bb_top)
ok("black-bolt eye row (%d) lands INSIDE the shifted window [%d,%d]" % (bb_eye, bb_top, bb_top + 3)) \
    if bb_top <= bb_eye <= bb_top + 3 else bad("black-bolt eye row %d outside shifted window [%d,%d]" % (bb_eye, bb_top, bb_top + 3))
cy = eye_count("cyclops")
cy_eye = max(range(8), key=lambda r: (cy[r], -abs(r - 3.5)))
cy_top = S._eye_strip_top(cy)
ok("cyclops eye row (%d) INSIDE [3,6] keeps default window (top=3)" % cy_eye) if (3 <= cy_eye <= 6 and cy_top == 3) else bad("cyclops window wrong: eye=%d top=%d" % (cy_eye, cy_top))
# a no-eye hero (joker) keeps the default window (nothing to center on)
jk_top = S._eye_strip_top(eye_count("joker"))
ok("no-eye hero (joker) keeps default window (top=3)") if jk_top == 3 else bad("joker window shifted with no eyes (top=%d)" % jk_top)

# 4) NATURAL PALETTE — distinct heroes look distinct, not one recoloured blob
show = ["batsy", "hulk", "spiderman", "ironman", "venom", "black-bolt"]
strips = {h: "\n".join(S.eye_strip(h, tc)) for h in show}
nd = len(set(strips.values()))
ok("heroes render distinct natural strips (%d/%d distinct)" % (nd, len(show))) if nd >= 5 else bad("eye_strip blobbed: only %d/%d distinct" % (nd, len(show)))
# batsy carries its own hue AND accent colours (not a single flat hue)
bhue = "2;%d;%d;%d" % S._hex_rgb(S.HERO_SIGILS["batsy"]["hue"])
ok("batsy strip carries its own body hue (natural palette)") if bhue in strips["batsy"] else bad("batsy body hue absent: not natural palette")

# 5) TIER
j256 = "\n".join(S.eye_strip("hulk", S.tier_caps("256")))
jmono = "\n".join(S.eye_strip("hulk", S.tier_caps(S.TC.MONO, S.TC.FULL)))
ok("256 uses the xterm-cube LUT (48;5 or 38;5), no 24-bit 2;R;G;B leak") if (("48;5;" in j256 or "38;5;" in j256) and "48;2;" not in j256 and "38;2;" not in j256) else bad("256 leaked/absent: %r" % j256)
ok("mono strips ALL color (no 2;R;G;B, no ESC)") if ("48;2" not in jmono and "38;2" not in jmono and "\033[" not in jmono) else bad("mono retained SGR: %r" % jmono)

# 6) ADDITIVE — the shared S/M/L render is byte-unchanged; top_half is the eye_strip alias
mok = True
for seed in ("batsy", "venom", "you", "haid:dev.box-ab12"):
    for size in ("S", "M", "L"):
        want = {"S": 4, "M": 8, "L": 16}[size]
        for tier in ("truecolor", "256", "16"):
            for l in S.sigil_render(seed, size, S.tier_caps(tier)):
                if l and S.TC.display_width(vis(l)) != want: mok = False
ok("S/M/L core still renders exact width (eye_strip is additive)") if mok else bad("eye_strip perturbed the S/M/L render")
ok("top_half is the eye_strip alias (caller-compatible)") if S.top_half is S.eye_strip else bad("top_half is not aliased to eye_strip")

print("::COUNT:: %d %d" % (P[0], F[0]))
PYEOF

out="$(python3 "$PY" "$SIG")"
printf '%s\n' "$out" | grep -v '^::COUNT::'
line="$(printf '%s\n' "$out" | grep '^::COUNT::')"
pass="$(echo "$line" | awk '{print $2}')"; fail="$(echo "$line" | awk '{print $3}')"
echo ""
echo "${pass:-0} passed, ${fail:-0} failed"
[ "${fail:-1}" -eq 0 ] || exit 1

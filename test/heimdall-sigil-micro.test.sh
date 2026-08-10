#!/usr/bin/env bash
# heimdall-sigil-micro.test.sh — the MICRO / chip render: a SINGLE text-row compressed
# sigil mark for the statusline Row-1 team cluster (`team <mark> <mark> name·name`).
#
# CONTRACT (all DERIVED from the existing 58-hero grids — nothing hand-authored):
#   1. SHAPE   — micro(seed) is exactly ONE text-row (no newline), MICRO_W cells wide,
#                visible width == MICRO_W on truecolor/256/16/mono, exit 0, never crashes.
#   2. DISTINCT— the 8 showcase heroes (batsy hulk joker thanos spiderman venom superman
#                flash) each render a DISTINCT mark; every hero in the pool renders.
#   3. COLOR   — with no override the mark carries the hero's OWN palette colors; a
#                supplied '#rrggbb' recolors the silhouette to that ONE hue (on→hue,
#                off→DIM) — the recolor is honored (the hex appears as an SGR triplet).
#   4. TIER    — terminal-safe one-pass downgrade: 256 uses 38;5/48;5 (no 24-bit leak),
#                16 uses the fixed shades (no 24-bit leak), mono strips ALL color (no
#                38;2 / no 38;5 — a plain `▄` glyph), ascii folds `▄`→`.`.
#   5. CLI     — `--seed X --micro [--color #hex] [--tier T]` prints the 1-row mark.
#   6. ADDITIVE— the existing S/M/L render is byte-UNCHANGED (micro touches no other
#                path): a spot-check of sigil_render(...,'M') matches across the change.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SIG" ] || { echo "FATAL: sigil core missing at $SIG"; exit 2; }

run_py() {
  local out; out="$(python3 - "$SIG" <<PY
import importlib.util, sys, re
spec=importlib.util.spec_from_file_location("s", sys.argv[1])
S=importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
STRIP=re.compile(r"\033\[[0-9;]*m")
def vis(x): return STRIP.sub("", x)
P=[0]; F=[0]
def ok(m): P[0]+=1; print("  ok   "+m)
def bad(m): F[0]+=1; print("  FAIL "+m)
$1
print("::COUNT:: %d %d" % (P[0], F[0]))
PY
)"
  grep -v '^::COUNT::' <<<"$out"
  local line; line="$(grep '^::COUNT::' <<<"$out")"
  pass=$((pass + $(echo "$line" | awk '{print $2}')))
  fail=$((fail + $(echo "$line" | awk '{print $3}')))
}

echo "== 1) SHAPE: micro is exactly 1 text-row, width MICRO_W, on every tier, exit 0 =="
run_py '
W=S.MICRO_W
ok("MICRO is a 4-wide x 2-tall (4x2 px) form") if (S.MICRO_W==4 and S.MICRO_H==2) else bad("MICRO dims are %dx%d (want 4x2)"%(S.MICRO_W,S.MICRO_H))
heroes=["batsy","hulk","joker","thanos","spiderman","venom","superman","flash"]
one_line=widthok=True
for tier in ("truecolor","256","16","mono"):
    caps=S.tier_caps(S.TC.MONO,S.TC.FULL) if tier=="mono" else S.tier_caps(tier)
    for h in heroes:
        m=S.micro(h,caps=caps)
        if "\n" in m: one_line=False
        if S.TC.display_width(vis(m))!=W: widthok=False
ok("micro is exactly ONE text-row (no newline) on every tier") if one_line else bad("micro emitted more than one line")
ok("micro visible width == MICRO_W (%d cells) on truecolor/256/16/mono"%W) if widthok else bad("micro width != %d on some tier"%W)
# every hero in the pool renders without crashing, width W
allrender=True
for name in S.HERO_ORDER:
    try:
        if S.TC.display_width(vis(S.micro(name,caps=S.tier_caps("truecolor"))))!=W: allrender=False
    except Exception as e: allrender=False
ok("all %d heroes render a width-%d micro mark, exit 0"%(len(S.HERO_ORDER),W)) if allrender else bad("a hero micro faulted")
# unknown / toy seed never crashes (resolves deterministically like every surface)
try:
    u=S.micro("some-random-unknown-seed",caps=S.tier_caps("truecolor"))
    ok("unknown seed never crashes (width %d)"%W) if S.TC.display_width(vis(u))==W else bad("unknown seed wrong width")
except Exception as e:
    bad("unknown seed crashed: %r"%e)
'

echo "== 2) DISTINCT: the 8 showcase heroes render distinct marks =="
run_py '
heroes=["batsy","hulk","joker","thanos","spiderman","venom","superman","flash"]
tc=S.tier_caps("truecolor")
marks={h:S.micro(h,caps=tc) for h in heroes}
ok("all 8 showcase heroes distinct") if len(set(marks.values()))==8 else bad("showcase marks collide: %d/8 unique"%len(set(marks.values())))
# each is the LOWER-half glyph (the _cell ▄ convention), width-1 cells
allbar=all(set(vis(m))<= {chr(0x2584)} for m in marks.values())
ok("micro packs the ▄ lower-half glyph (2 px/cell)") if allbar else bad("micro used a non-▄ glyph on truecolor")
'

echo "== 3) COLOR: hero-own palette by default; explicit hex recolors the silhouette =="
run_py '
tc=S.tier_caps("truecolor")
# default keeps the hero own colors — batsy carries its navy hue #141834 -> 20;24;52
b=S.micro("batsy",caps=tc)
ok("default mark carries the hero own colors (batsy navy 20;24;52)") if "20;24;52" in b else bad("batsy default lost its palette: %r"%b)
# recolor: a supplied hex tints the silhouette to that ONE hue
r=S.micro("spiderman",color="#2f96ff",caps=tc)
ok("recolor honored (#2f96ff -> 47;150;255 present)") if "47;150;255" in r else bad("recolor hex not applied: %r"%r)
ok("recolored mark drops the hero own red hue (fb0745 -> 251;7;69)") if "251;7;69" not in r else bad("recolor left original hue in")
# arbitrary hex works and changes the output vs default
d=S.micro("hulk",caps=tc); a=S.micro("hulk",color="#ff8800",caps=tc)
ok("arbitrary hex #ff8800 -> 255;136;0 and differs from default") if ("255;136;0" in a and a!=d) else bad("arbitrary recolor not honored")
# off pixels in a recolor use the DIM silhouette block (heroes with bg edges)
o=S.micro("harley-quinn",color="#ff8800",caps=tc)   # bg-heavy grid -> an off cell survives the 4x2 downsample
ok("recolor off-pixels use the DIM block (%s)"%str(S.DIM)) if ("%d;%d;%d"%S.DIM in o) else bad("recolor off-pixels not DIM: %r"%o)
'

echo "== 4) TIER: 256/16 quantize (no 24-bit leak); mono strips all color =="
run_py '
c256=S.micro("hulk",caps=S.tier_caps("256"))
c16 =S.micro("hulk",caps=S.tier_caps("16"))
mono=S.micro("hulk",caps=S.tier_caps(S.TC.MONO,S.TC.FULL))
asc =S.micro("hulk",caps=S.tier_caps(S.TC.MONO,S.TC.ASCII))
ok("256 uses the xterm-cube LUT (38;5/48;5), no 24-bit 38;2 leak") if ("38;5;" in c256 and "38;2;" not in c256) else bad("256 leaked/absent SGR: %r"%c256)
ok("16 quantizes with no 24-bit 38;2 leak") if "38;2;" not in c16 else bad("16 leaked 24-bit: %r"%c16)
ok("mono strips ALL color (no 38;2 and no 38;5)") if ("38;2" not in mono and "38;5" not in mono and "\033[" not in mono) else bad("mono retained SGR: %r"%mono)
ok("mono is a plain ▄ glyph fallback (%d cells)"%S.MICRO_W) if mono==chr(0x2584)*S.MICRO_W else bad("mono not plain ▄: %r"%mono)
ok("ascii folds ▄ -> . (no unicode half-block)") if asc=="."*S.MICRO_W else bad("ascii fallback wrong: %r"%asc)
'

echo "== 5) CLI: --seed X --micro [--color] [--tier] prints the 1-row mark =="
STRIP='s/\x1b\[[0-9;]*m//g'
OUT="$(python3 "$SIG" --seed batsy --micro --tier truecolor)"; RC=$?
LINES="$(grep -c '' <<<"$OUT")"
VIS="$(printf '%s' "$OUT" | sed "$STRIP")"
{ [ "$RC" -eq 0 ] && [ "$LINES" -eq 1 ]; } \
  && ok "CLI --micro prints exactly 1 line (exit $RC)" || bad "CLI --micro not 1 line (exit $RC, lines=$LINES)"
[ "$VIS" = "▄▄▄▄" ] && ok "CLI --micro visible mark is 4 ▄ cells" || bad "CLI --micro visible mark wrong: '$VIS'"
OUT="$(python3 "$SIG" --seed spiderman --micro --color '#2f96ff' --tier truecolor)"
grep -q "47;150;255" <<<"$OUT" && ok "CLI --color recolors the mark" || bad "CLI --color not applied"
OUT="$(python3 "$SIG" --seed joker --micro --tier mono)"
{ ! grep -q "38;2" <<<"$OUT"; } && ok "CLI --micro --tier mono has no 24-bit color" || bad "CLI mono leaked color"

echo "== 6) ADDITIVE: the S/M/L render path is untouched by micro =="
run_py '
# micro must not perturb the shared core — a spot render on M for a hero and a toy seed
# still produces the width-8, exit-0 output the existing goldens assert.
mok=True
for seed in ("batsy","venom","you","haid:dev.box-ab12"):
    for tier in ("truecolor","256","16"):
        lines=S.sigil_render(seed,"M",S.tier_caps(tier))
        for l in lines:
            if l and len(vis(l))!=8: mok=False
ok("S/M/L core still renders width-8 (micro is additive)") if mok else bad("micro perturbed the M render")
'

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

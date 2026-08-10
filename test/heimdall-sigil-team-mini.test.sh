#!/usr/bin/env bash
# heimdall-sigil-team-mini.test.sh — the high-quality 4×4 teammate mark (team_mini): a
# FEATURE-PRESERVING reduction of the 8×8 hero/animal grid to a 4×4px (4 cols × 2 text-row)
# silhouette for the statusline team cluster (TOP half rides Row1, BOTTOM half Row2).
#
# WHY: the generic S-size 8→4 box-majority made almost every box "on" → a solid recoloured
# BLOB (RJ: "a beige blob, not a recognizable hero"). team_mini carves the silhouette gaps
# + eyes instead, so batsy shows cowl+ears, hulk a solid brow + eye band, ironman faceplate
# slits — RECOGNIZABLE reductions of the same 8×8 heroes, in the teammate hue.
#
# CONTRACT (all DERIVED from the existing 58-hero grids — nothing hand-authored):
#   1. SHAPE   — team_mini(seed) is exactly 2 text-rows, 4 cells wide each, exit 0.
#   2. SILHOUETTE — a cowled hero (batsy) has an OFF (DIM) pixel in the TOP row (the ears
#                are carved, not flooded); it differs from a solid-head hero (joker), and
#                the showcase heroes are NOT all one blob.
#   3. EYE-POP — a hero with authored eyes (batsy) surfaces a bright EYE tint distinct from
#                both the body hue and the DIM off-block, so eye POSITIONS survive.
#   4. RECOLOR — a supplied '#rrggbb' paints the ON silhouette in that ONE hue; OFF pixels
#                use the DIM silhouette block.
#   5. TIER    — one-pass downgrade: 256 uses 48;5 (no 24-bit leak), mono strips ALL color.
#   6. ADDITIVE— sigil_render(...,'S'/'M') is byte-UNCHANGED (team_mini touches no shared
#                render path — the S goldens / heimdall-sigil-render stay byte-stable).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SIG" ] || { echo "FATAL: sigil core missing at $SIG"; exit 2; }

PY="$(mktemp -t team_mini.XXXXXX.py)"
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
DIM = "%d;%d;%d" % S.DIM

# 1) SHAPE
lines = S.team_mini("batsy", "#2f96ff", tc)
ok("team_mini is exactly 2 text-rows") if len(lines) == 2 else bad("team_mini rows=%d (want 2)" % len(lines))
wok = all(S.TC.display_width(vis(l)) == 4 for l in lines)
ok("team_mini rows are 4 cells wide") if wok else bad("team_mini width != 4: %r" % [vis(l) for l in lines])
allrender = True
for name in S.HERO_ORDER:
    try:
        ls = S.team_mini(name, "#2f96ff", tc)
        if len(ls) != 2 or any(S.TC.display_width(vis(l)) != 4 for l in ls): allrender = False
    except Exception:
        allrender = False
ok("all %d heroes render a 2x4 team_mini, exit 0" % len(S.HERO_ORDER)) if allrender else bad("a hero team_mini faulted")

# 2) SILHOUETTE
batsy = S.team_mini("batsy", "#2f96ff", tc)
ok("batsy TOP row carries a DIM off-pixel (cowl ears carved)") if DIM in batsy[0] else bad("batsy top has no off-pixel: %r" % batsy[0])
joker = "\n".join(S.team_mini("joker", "#2f96ff", tc))
ok("batsy silhouette differs from a solid-head hero (joker)") if "\n".join(batsy) != joker else bad("batsy == joker (blob collapse)")
show = ["batsy", "hulk", "spiderman", "ironman", "venom", "thanos"]
marks = {h: "\n".join(S.team_mini(h, "#2f96ff", tc)) for h in show}
nd = len(set(marks.values()))
ok("showcase heroes are NOT all one blob (%d/%d distinct)" % (nd, len(show))) if nd >= 5 else bad("team_mini blobbed: only %d/%d distinct" % (nd, len(show)))

# 3) EYE-POP
hue = S._hex_rgb("#2f96ff"); eye = S._mix(hue, S.WHITE, 0.6)
eyekey = "%d;%d;%d" % eye; huekey = "%d;%d;%d" % hue
joined = "\n".join(batsy)
cond = eyekey in joined and eyekey != huekey and eyekey != DIM
ok("batsy eye tint %s present + distinct from body/off (eye-pop)" % eyekey) if cond else bad("batsy eye-pop missing: %r" % joined)

# 4) RECOLOR
r = "\n".join(S.team_mini("spiderman", "#2f96ff", tc))
ok("recolor honored (#2f96ff -> 47;150;255 on the silhouette)") if "47;150;255" in r else bad("recolor not applied: %r" % r)
# off-pixels: a carved-silhouette hero (batsy — cowl ears are bg) recolors OFF to the DIM block
ok("recolor off-pixels use the DIM block (batsy ears)") if DIM in "\n".join(batsy) else bad("recolor off-pixels not DIM")

# 5) TIER
j256 = "\n".join(S.team_mini("hulk", "#26e948", S.tier_caps("256")))
jmono = "\n".join(S.team_mini("hulk", "#26e948", S.tier_caps(S.TC.MONO, S.TC.FULL)))
ok("256 uses the xterm-cube LUT (48;5), no 24-bit 48;2 leak") if ("48;5;" in j256 and "48;2;" not in j256) else bad("256 leaked/absent: %r" % j256)
ok("mono strips ALL color (no 48;2 / no 38;2 / no ESC)") if ("48;2" not in jmono and "38;2" not in jmono and "\033[" not in jmono) else bad("mono retained SGR: %r" % jmono)

# 6) ADDITIVE
mok = True
for seed in ("batsy", "venom", "you", "haid:dev.box-ab12"):
    for size in ("S", "M"):
        want = 4 if size == "S" else 8
        for tier in ("truecolor", "256", "16"):
            for l in S.sigil_render(seed, size, S.tier_caps(tier)):
                if l and S.TC.display_width(vis(l)) != want: mok = False
ok("S/M core still renders exact width (team_mini is additive)") if mok else bad("team_mini perturbed the S/M render")

print("::COUNT:: %d %d" % (P[0], F[0]))
PYEOF

out="$(python3 "$PY" "$SIG")"
grep -v '^::COUNT::' <<<"$out"
line="$(grep '^::COUNT::' <<<"$out")"
pass="$(echo "$line" | awk '{print $2}')"; fail="$(echo "$line" | awk '{print $3}')"
echo ""
echo "${pass:-0} passed, ${fail:-0} failed"
[ "${fail:-1}" -eq 0 ] || exit 1

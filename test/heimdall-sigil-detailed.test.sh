#!/usr/bin/env bash
#
# heimdall-sigil-detailed.test.sh — RJ's 132 hand-authored 16×16 DETAILED sprites,
# the detailed-tier shading, and the HAID→family+emotion scheme.
#
# The compact 8×8 statusline cast (ANIMALS) survives at 4 text-rows by dropping to a
# silhouette + eyes; the space-having surfaces (share card / banner / `hmd watch`)
# render the DETAILED 'D' tier: a 16×16 hand-authored sprite over the alphabet
#   . bg | 1 body | 2 eye | 3 highlight | 4 shadow | 5 outline | 6 accentA | 7 accentB
# value→color IS the shading (hand-authored highlight/shadow + a bg diagonal gradient).
#
# LOCKS:
#   1. LOAD    — exactly 132 sprites baked as literals; each grid is 16×16; every
#                cell is a valid palette char; a sprite that USES 6/7 declares
#                accent6/accent7 (the render never invents an accent).
#   2. FAMILY  — BASE_FAMILIES = the emotion-suffix-free names; HAID→base family is
#                deterministic (sha256 % N, stable across calls) and NEAR-UNIFORM
#                over 500 sampled HAIDs (every family hit; no family runs away).
#   3. EMOTION — sigil_render(haid, 'D', emotion=…) is addressable: a base vs an
#                emotion variant of the SAME family render DIFFERENT bytes; an ABSENT
#                emotion falls back to the base (never crashes / never blank).
#   4. RENDER  — render_detailed is 8 text-rows, every line the 16-cell square width;
#                value 2 emits a full white eye, value 5 a near-black outline;
#                deterministic (same seed → byte-identical).
#   5. COMPACT UNTOUCHED — the detailed path never perturbs the compact/animal S/M/L
#                grids: grid_for('rj') and the M render are byte-identical to a fresh
#                (detailed-free) reference computed from the value grid.
#
# FALSIFIER: drop a sprite (len!=132) or break the family index (non-uniform) → RED.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SIG" ] || { echo "FATAL: sigil core missing at $SIG"; exit 2; }

TMP="$(mktemp "${TMPDIR:-/tmp}/hmd-detailed.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
python3 - "$SIG" > "$TMP" 2>&1 <<'PY'
import importlib.util, sys, re, hashlib, collections
p = sys.argv[1]
s = importlib.util.spec_from_file_location("m", p); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)

def emit(tag, cond, detail=""):
    print(("OK " if cond else "BAD ") + tag + ((" :: " + detail) if detail and not cond else ""))

PAL = set(".1234567")
D = m.DETAILED_SPRITES

# ── 1) LOAD ──
emit("load: exactly 132 sprites baked", len(D) == 132, "n=%d" % len(D))
shape_ok = pal_ok = acc_ok = meta_ok = True
for name, sp in D.items():
    g = sp["grid"]
    if len(g) != 16 or any(len(r) != 16 for r in g): shape_ok = False
    used = set()
    for r in g:
        for c in r:
            if c not in PAL: pal_ok = False
            used.add(c)
    if not sp.get("hue") or not sp.get("bg"): meta_ok = False
    if "6" in used and not sp.get("accent6"): acc_ok = False
    if "7" in used and not sp.get("accent7"): acc_ok = False
emit("load: every sprite is a 16×16 grid", shape_ok)
emit("load: every cell is a valid palette char (. 1-7)", pal_ok)
emit("load: hue + bg present on every sprite", meta_ok)
emit("load: a sprite using 6/7 declares accent6/accent7", acc_ok)

# ── 2) FAMILY ──
fams = m.BASE_FAMILIES
emit("family: BASE_FAMILIES = emotion-free names (sorted, non-empty)",
     fams == sorted(fams) and len(fams) >= 1 and all("-" not in f for f in fams),
     "n=%d" % len(fams))
emit("family: every base family is a real base sprite", all(f in D for f in fams))
# deterministic + stable
seeds = ["dev-%d" % i for i in range(20)]
emit("family: deterministic (two calls identical)",
     all(m.detailed_family_for(x) == m.detailed_family_for(x) for x in seeds))
# near-uniform over 500 HAIDs: every family hit, none runs away past 3× expected
counts = collections.Counter(m.detailed_family_for("haid:%d" % i) for i in range(500))
exp = 500.0 / len(fams)
seen = len(counts)
runaway = max(counts.values())
emit("family: near-uniform over 500 HAIDs — every family appears",
     seen == len(fams), "seen=%d/%d" % (seen, len(fams)))
emit("family: near-uniform — no family exceeds 3× expected",
     runaway <= 3 * exp, "max=%d exp=%.1f" % (runaway, exp))

# ── 3) EMOTION ──
# find a family that HAS a named emotion variant, and a HAID that maps onto it.
emo_family = None; emo = None
for name in D:
    if "-" in name:
        emo_family, emo = name.split("-", 1); break
haid_for_fam = None
if emo_family:
    for i in range(2000):
        h = "seek:%d" % i
        if m.detailed_family_for(h) == emo_family:
            haid_for_fam = h; break
if haid_for_fam and emo:
    base_b = "\n".join(m.sigil_render(haid_for_fam, "D", m.tier_caps()))
    emo_b  = "\n".join(m.sigil_render(haid_for_fam, "D", m.tier_caps(), emotion=emo))
    emit("emotion: base vs '%s' variant of %s render DIFFERENT bytes" % (emo, emo_family),
         base_b != emo_b)
    # absent emotion → graceful fall back to base (identical to base, never blank)
    fb = "\n".join(m.sigil_render(haid_for_fam, "D", m.tier_caps(), emotion="no-such-emotion-xyz"))
    emit("emotion: an ABSENT variant falls back to the base (non-empty, == base)",
         fb == base_b and fb.strip() != "")
    emit("emotion: name resolver picks the variant when present",
         m.detailed_name_for(haid_for_fam, emo) == "%s-%s" % (emo_family, emo))
else:
    emit("emotion: base vs variant differ", False, "no emotion family found")
    emit("emotion: absent variant falls back to base", False, "no emotion family found")
    emit("emotion: name resolver picks the variant", False, "no emotion family found")

# ── 4) RENDER ──
ANSI = re.compile(r"\033\[[0-9;]*m")
tc = m.sigil_render("render-me-42", "D", m.tier_caps())
widths = set(len(ANSI.sub("", l)) for l in tc if l != "")
emit("render: detailed tier is 8 text-rows", len(tc) == 8, "rows=%d" % len(tc))
emit("render: every line is the 16-cell square width", widths == {16}, "widths=%s" % sorted(widths))
flat = "\n".join(tc)
emit("render: value 2 emits a full white eye (255;255;255 fg+bg)",
     "38;2;255;255;255" in flat and "48;2;255;255;255" in flat)
emit("render: value 5 (silhouette edge) emits the drawn outline (48;52;64)", "38;2;48;52;64" in flat or "48;2;48;52;64" in flat)
a = "\n".join(m.sigil_render("determinism", "D", m.tier_caps()))
b = "\n".join(m.sigil_render("determinism", "D", m.tier_caps()))
emit("render: deterministic (same seed → byte-identical)", a == b)

# ── 6) ANTI-SPECKLE — no scattered black dots in the body fill (RJ's #1 reject) ──
# The 2-px-per-cell `▀` pack turns a near-black INTERIOR pixel sitting over a body
# pixel into a half-black cell = a black speckle dot. Assert that no cell INTERIOR to
# the silhouette renders a near-black half (max channel < 40). This is RED on the old
# render (interior value-5 marks were the ink color 12,14,20) and GREEN after the fix
# (interior 5 is recolored to the soft shadow tone; only bg-bordering edge 5 stays dark).
CELL = re.compile(r"\033\[38;2;(\d+);(\d+);(\d+)m(?:\033\[48;2;(\d+);(\d+);(\d+)m)?([^\033])")
def _interior(g, r, c, N=16):
    if g[r][c] == ".": return False
    for dr, dc in ((-1,0),(1,0),(0,-1),(0,1)):
        rr, cc = r+dr, c+dc
        if not (0 <= rr < N and 0 <= cc < N) or g[rr][cc] == ".": return False
    return True
def _interior_black_halves(name):
    g = D[name]["grid"]; lines = m.sigil_render(name, "D", m.tier_caps()); bad = 0
    for ti, line in enumerate(lines):
        for ci, mm in enumerate(CELL.finditer(line)):
            fr,fg,fb,br,bg,bb,_ = mm.groups()
            if _interior(g, ti*2, ci) and max(int(fr),int(fg),int(fb)) < 40: bad += 1
            if br and _interior(g, ti*2+1, ci) and max(int(br),int(bg),int(bb)) < 40: bad += 1
    return bad
speckle = {n: _interior_black_halves(n) for n in ("fox","lisa","pearl","dragon","penguin","cat","cat-joy")}
emit("anti-speckle: NO near-black cell inside the body fill on any sampled sprite",
     all(v == 0 for v in speckle.values()), "counts=%s" % speckle)

# per-variant hue: an emotion variant renders ITS OWN authored hue, not a default/base.
def _has_hue(name, hexstr, emotion=None, seed=None):
    r,gc,b = int(hexstr[1:3],16), int(hexstr[3:5],16), int(hexstr[5:7],16)
    flat = "\n".join(m.render_detailed(seed or name, emotion=emotion))
    return ("38;2;%d;%d;%d" % (r,gc,b)) in flat
emit("hue: fox renders its authored ORANGE #e0783c (not the compact green)",
     _has_hue("fox", "#e0783c"))
emit("hue: fox-rage renders its authored RED #b0503c",
     _has_hue("fox", "#b0503c", emotion="rage"))
emit("hue: fox-neutral renders its authored GREY #d7dde3",
     _has_hue("fox", "#d7dde3", emotion="neutral"))
emit("hue: fox base vs fox-rage differ (per-variant hue applied, not identical)",
     "\n".join(m.render_detailed("fox")) != "\n".join(m.render_detailed("fox", emotion="rage")))

# clean eyes: a 2×2 eye-pair renders as SOLID white cells (fg==bg==255), never a
# half-white/half-body split (the BUG-3 checker), even when it straddles the pack.
def _eye_split(name):
    solid = split = 0
    for line in m.sigil_render(name, "D", m.tier_caps()):
        for mm in CELL.finditer(line):
            fr,fg,fb,br,bg,bb,_ = mm.groups()
            wt = (fr,fg,fb) == ("255","255","255"); wb = (br,bg,bb) == ("255","255","255")
            if wt or wb: (solid, split) = (solid+1, split) if (wt and wb) else (solid, split+1)
    return solid, split
eye_ok = True; eye_detail = []
for n in ("rabbit","dog","cat-shock","lisa","dragon","fox"):
    s, sp = _eye_split(n); eye_detail.append("%s=%d/%d" % (n, s, sp))
    if sp != 0 or s == 0: eye_ok = False
emit("eyes: 2×2 eye-pairs render as SOLID white cells, no half-white checker",
     eye_ok, "solid/split: %s" % " ".join(eye_detail))

# ── 5) COMPACT UNTOUCHED — the detailed literals never touched the value grid ──
# rebuild rj's finished 8×8 independently and confirm grid_for still equals it.
raw = [[int(c) for c in row] for row in m.CURATED_GRIDS["rj"]]
m._apply_watchman(raw)
emit("compact: grid_for('rj') unchanged by the detailed tier", m.grid_for("rj")[0] == raw)
# a compact M render must contain the compact EYE glint (240;248;255), NOT the
# detailed full-white eye — proof the compact path is a different, untouched code path.
mc = "\n".join(m.sigil_render("rj", "M", m.tier_caps()))
emit("compact: M render still uses the compact EYE glint (240;248;255)", "240;248;255" in mc)
PY

echo "== 132 detailed sprites + shading + family/emotion scheme =="
while IFS= read -r ln; do
    case "$ln" in
        "OK "*)  ok  "${ln#OK }" ;;
        "BAD "*) bad "${ln#BAD }" ;;
        *)       [ -n "$ln" ] && printf '  ??   %s\n' "$ln" ;;
    esac
done < "$TMP"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

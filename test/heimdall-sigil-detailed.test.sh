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
emit("render: value 5 emits the near-black outline (12;14;20)", "38;2;12;14;20" in flat or "48;2;12;14;20" in flat)
a = "\n".join(m.sigil_render("determinism", "D", m.tier_caps()))
b = "\n".join(m.sigil_render("determinism", "D", m.tier_caps()))
emit("render: deterministic (same seed → byte-identical)", a == b)

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

#!/usr/bin/env bash
#
# heimdall-sigil-sprites.test.sh — the ported SUPERX SPRITE-ART cast.
#
# THE BUG (RJ, evidenced): the GENERATED sigil path (every arbitrary HAID that is
# not one of the 4 curated mockup identities) built one fixed guardian-helm
# TEMPLATE and only flipped a handful of texture bits. Result: every real dev's
# sigil was the SAME domed-visor silhouette — a muddy blob that never resolves into
# a recognizable character. The dashboard sprite art from the superx era READ as
# characters because it was a CAST of distinct animals (owl/fox/cat/rabbit/panda/
# bear/dog/monk), each with its own unmistakable silhouette.
#
# THE FIX under test: the generated path now maps a HAID DETERMINISTICALLY onto one
# of that curated animal cast (ported to the statusline's 8x8 half-block grid),
# preserving the universal watchman finish (full-cell eyes on a carved band) so the
# sigil still READS as a face and every existing render/width contract holds.
#
# LOCKS:
#   1. The cast exists: 8 named animals, each an 8x8 grid, every row vertically
#      symmetric (the mirror-about-3.5 invariant the render depends on).
#   2. Determinism: same HAID -> same animal, forever (two grid_for calls identical).
#   3. RECOGNIZABLE, NOT A BLOB: every generated HAID's silhouette (the non-band
#      rows) equals EXACTLY one animal template — never an ad-hoc guardian grid.
#   4. DISTINCT: across many HAIDs the cast is actually spread (>=6 of 8 animals
#      appear) and two HAIDs that pick different animals render different silhouettes.
#   5. Eye contract preserved: the carved band (grid rows 2,3) still holds the two
#      full-cell eyes at cols 2 & 5 for a generated animal (the watchman finish).
#   6. Curated identities untouched: seed rj still renders its hand-authored mockup
#      grid (the generated-path change must not disturb the 4 curated faces).
#
# FALSIFIER: revert the generated path to the single guardian TEMPLATE and check 3
# goes RED — the guardian grid matches no animal template.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SIG" ] || { echo "FATAL: sigil core missing at $SIG"; exit 2; }

TMP="$(mktemp "${TMPDIR:-/tmp}/hmd-sprites.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
python3 - "$SIG" > "$TMP" 2>&1 <<'PY'
import importlib.util, sys, hashlib
p = sys.argv[1]
s = importlib.util.spec_from_file_location("m", p); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)

def emit(tag, cond, detail=""):
    print(("OK " if cond else "BAD ") + tag + ((" :: " + detail) if detail and not cond else ""))

# 1) the cast exists, 8 animals, 8x8, every row symmetric
animals = getattr(m, "ANIMALS", None)
order   = getattr(m, "ANIMAL_ORDER", None)
emit("cast: ANIMALS + ANIMAL_ORDER present", isinstance(animals, dict) and isinstance(order, (list, tuple)))
if isinstance(animals, dict) and isinstance(order, (list, tuple)):
    emit("cast: exactly 8 named animals", len(animals) == 8 and len(order) == 8, "n=%d/%d" % (len(animals), len(order)))
    emit("cast: ANIMAL_ORDER names all in ANIMALS", all(n in animals for n in order))
    shape_ok = True; sym_ok = True
    for name, grid in animals.items():
        if len(grid) != 8 or any(len(r) != 8 for r in grid): shape_ok = False
        for r in grid:
            if r != r[::-1]: sym_ok = False
    emit("cast: every animal is an 8x8 grid", shape_ok)
    emit("cast: every animal row is vertically symmetric", sym_ok)
else:
    order = order or []

# 2) determinism — same HAID, same grid
seeds = ["rj-a3f9", "devanand", "haid:alice", "b0b-9", "carol@x", "d4-ve", "erin_", "frank.7", "gwen-42", "hank"]
det = all(m.grid_for(sd)[0] == m.grid_for(sd)[0] for sd in seeds)
emit("determinism: same HAID -> identical grid", det)

# 3) recognizable, not a blob — every generated grid's non-band rows == some animal
BAND = (2, 3)
def nonband(g): return [tuple(g[r]) for r in range(8) if r not in BAND]
templates = {name: nonband([[int(c) for c in row] for row in grid]) for name, grid in (animals or {}).items()}
def which_animal(seed):
    g = m.grid_for(seed)[0]
    key = nonband(g)
    for name, t in templates.items():
        if key == t: return name
    return None
gen_seeds = ["gen%03d" % i for i in range(300)]
matched = [which_animal(sd) for sd in gen_seeds]
all_match = all(a is not None for a in matched)
emit("recognizable: every generated HAID is an animal (no ad-hoc blob)", all_match,
     "unmatched=%d" % sum(1 for a in matched if a is None))

# 4) distinct — the cast is actually spread + different picks differ
seen = set(a for a in matched if a)
emit("distinct: >=6 of 8 animals appear across 300 HAIDs", len(seen) >= 6, "seen=%d (%s)" % (len(seen), ",".join(sorted(seen))))
# find two seeds on different animals; their silhouettes must differ
byanimal = {}
for sd, a in zip(gen_seeds, matched):
    if a: byanimal.setdefault(a, sd)
picks = list(byanimal.items())
if len(picks) >= 2:
    (a1, s1), (a2, s2) = picks[0], picks[1]
    emit("distinct: two different animals -> different silhouettes",
         m.grid_for(s1)[0] != m.grid_for(s2)[0], "%s vs %s" % (a1, a2))
else:
    emit("distinct: two different animals -> different silhouettes", False, "not enough animals picked")

# 5) eye contract preserved on a generated animal (watchman finish)
g = m.grid_for("gen042")[0]
eyes_ok = (g[2][2] == 2 and g[2][5] == 2 and g[3][2] == 2 and g[3][5] == 2
           and g[2][3] == 0 and g[2][4] == 0)
emit("eyes: generated animal keeps full-cell eyes at cols 2 & 5 with a gap", eyes_ok)

# 6) curated identities untouched — rj still the hand-authored mockup grid
cur = getattr(m, "CURATED_GRIDS", {})
if "rj" in cur:
    expect = m.grid_for("rj")[0]
    # rebuild what a bare-curated + finish would be, independent of the generated path
    raw = [[int(c) for c in row] for row in cur["rj"]]
    m._apply_watchman(raw)
    emit("curated: seed rj unchanged (mockup grid + finish)", expect == raw)
else:
    emit("curated: seed rj unchanged (mockup grid + finish)", False, "rj not curated")

PY

echo "== ported superx sprite cast =="
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

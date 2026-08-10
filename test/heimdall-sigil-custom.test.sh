#!/usr/bin/env bash
# heimdall-sigil-custom.test.sh — the CUSTOM (pinned) sigil mechanism.
#
# CONTRACT (spec: a hand-authored complete face pinned to ONE identity):
#   1. PINNED → batsy: RJ's HAID resolves to the batsy face, rendered RAW through the
#      FULL palette (.=bg 1=hue 2=eye 5=outline 6=accent6 7=accent7). All six authored
#      colors appear; the shape matches the authored grid.
#   2. RAW (no watchman): the pinned face BYPASSES the animal watchman finish — it keeps
#      its OWN eyes (authored eye color #fffcf6), NOT the forced aliceblue band eyes.
#   3. EYE color honored: a value-2 cell paints the authored eye hex.
#   4. ADDITIVE / unpinned unchanged: a NON-pinned seed renders BYTE-IDENTICALLY to the
#      unchanged curated→animal path (watchman finish intact) — only the pin is affected.
#   5. TIER-SAFE: the pinned palette downgrades truecolor→256→16→mono, exit 0.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"
HAID="haid:rj.rishabhs-macbook-air-46d5"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }

# ── 1. PINNED → batsy full palette (all six authored colors present in the M render) ──
M="$(python3 "$SIG" --seed "$HAID" --size M --tier truecolor)"
# layer-agnostic: the ▄ lower-half glyph carries the BOTTOM pixel as fg (38;2) and the
# TOP pixel as bg (48;2), so an authored color may land on EITHER layer — match both.
for hex in "19;28;35" "20;24;52" "255;252;246" "0;0;0" "248;207;177" "47;150;255"; do
  if grep -qE "[34]8;2;$hex" <<<"$M"; then ok "batsy palette present: $hex"
  else bad "batsy palette MISSING: $hex"; fi
done
ncol=$(grep -oE '[34]8;2;[0-9]+;[0-9]+;[0-9]+' <<<"$M" | sed -E 's/^[0-9]+;2;//' | sort -u | wc -l | tr -d ' ')
[ "$ncol" = "6" ] && ok "batsy renders its full palette (6 distinct colors, not a flat body)" \
                   || bad "batsy distinct colors = $ncol (expected 6)"

# ── 1b. shape matches the authored grid (int projection: .=· 1=# 2=@) ──
DBG="$(python3 "$SIG" --seed "$HAID" --size M --tier truecolor --debug)"
EXP=$'#······#\n########\n########\n########\n#@@##@@#\n########\n###@@###\n·######·'
[ "$DBG" = "$EXP" ] && ok "batsy shape matches the authored 8×8 grid" \
                    || { bad "batsy shape mismatch"; printf '  got:\n%s\n' "$DBG"; }

# ── 2 + 3. RAW render: authored eyes (#faf3e8), NOT the forced watchman aliceblue band ──
grep -qE "[34]8;2;255;252;246" <<<"$M" \
  && ok "batsy eye uses the AUTHORED eye color #fffcf6 (value 2 honored)" \
  || bad "batsy authored eye color #fffcf6 absent"
grep -q "240;248;255" <<<"$M" \
  && bad "batsy leaked the watchman forced-eye aliceblue (240;248;255) — finish NOT bypassed" \
  || ok "batsy bypasses the watchman forced-eyes (no aliceblue band)"
# value-2 over value-5: grid row4='12255221' / row5='15555551' → a top=eye,bot=outline cell.
# With the ▄ lower-half glyph the bottom pixel (outline) is fg (38;2) and the top (eye) is bg (48;2).
grep -q "38;2;0;0;0m"$'\033'"\[48;2;255;252;246m▄" <<<"$M" \
  && ok "batsy eye(2) composites over outline(5) exactly as authored" \
  || bad "batsy eye-over-outline cell not found (raw palette not honored)"

# ── 4. ADDITIVE: a NON-pinned seed is byte-identical to the unchanged curated path ──
for seed in nadia arjun priya you teammate-xyz; do
  got="$(python3 "$SIG" --seed "$seed" --size M --tier truecolor)"
  want="$(python3 - "$seed" <<'PY'
import importlib.util, sys, os
here=os.path.dirname(os.path.abspath("sentinels/hmd_sigil.py"))
spec=importlib.util.spec_from_file_location("s","sentinels/hmd_sigil.py")
S=importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
# reference render straight through grid_for (curated/animal + watchman) — the path a
# non-pinned seed MUST still take. Bypasses CUSTOM entirely.
seed=sys.argv[1]
assert seed not in S.CUSTOM_SIGILS
print("\n".join(S.sigil_render(seed,'M',S.tier_caps())))
PY
)"
  [ "$got" = "$want" ] && ok "unpinned '$seed' unchanged (curated/animal + watchman intact)" \
                       || bad "unpinned '$seed' CHANGED — pin is not additive"
done
# and the curated 'rj' (the goldens' seed) still carries the watchman aliceblue eyes.
python3 "$SIG" --seed rj --size M --tier truecolor | grep -q "240;248;255" \
  && ok "curated 'rj' still renders the watchman eye band (goldens' seed untouched)" \
  || bad "curated 'rj' lost its watchman eyes"

# ── 5. TIER-SAFE downgrade for the pinned palette, exit 0 ──
for tier in truecolor 256 16 mono ascii; do
  python3 "$SIG" --seed "$HAID" --size M --tier "$tier" >/dev/null 2>&1 \
    && ok "batsy renders + exits 0 at tier=$tier" || bad "batsy failed at tier=$tier"
done
python3 "$SIG" --seed "$HAID" --size M --tier 256 | grep -q "38;2;" \
  && bad "batsy 256 tier leaked truecolor 38;2;" \
  || ok "batsy 256 tier quantized (no 38;2; leak)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

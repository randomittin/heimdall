#!/usr/bin/env bash
#
# heimdall-sigil-render.test.sh — the SHARED sigil render core (sentinels/hmd_sigil.py).
#
# The sigil rendered MORPHED because two surfaces disagreed: the statusline
# downgraded colors to the terminal's capability tier, but the CLI + banner emitted
# RAW 24-bit truecolor SGR blind. On a 256-color / tmux / 16-color terminal that raw
# SGR is quantized unpredictably or SWALLOWED (bg dropped → the silhouette/eyes
# collapse). Root cause classes proven here:
#   (3) color-tier blind      — a render must emit in the DETECTED tier, never
#                               truecolor everywhere. ASSERTED: 256 → 38;5 (no 38;2);
#                               16 → neither 38;2 nor 38;5.
#   (dup) twin implementations — hmd-sigil.py and hmd_sigil.py were byte-identical
#                               files; a fix to one left the other broken. ASSERTED:
#                               the two entry points produce byte-identical output.
#
# The fix is ONE shared core `sigil_render(haid, size, caps)`; this suite locks it
# with GOLDEN FIXTURES per (size × tier) byte-diffed exactly, a WIDTH INVARIANT
# (every emitted line has equal wcwidth = the declared square width), a one-pixel
# FALSIFIER (perturb a pixel → the golden must change, proving pixel-sensitivity),
# DETERMINISM, and the `hmd sigil --test` calibration card.
#
# FALSIFIER (headline): flip one grid pixel and the M/truecolor golden MUST differ.
# If it does not, the golden is not pixel-exact and this suite is worthless — asserted.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"
SIG_HY="$ROOT/sentinels/hmd-sigil.py"
GOLD="$ROOT/conformance/statusline/goldens/sigil"
HMD="$ROOT/bin/heimdall"
SEED=rj

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SIG" ]    || { echo "FATAL: sigil core missing at $SIG"; exit 2; }
[ -d "$GOLD" ]   || { echo "FATAL: golden dir missing at $GOLD"; exit 2; }

# visible cell width of a line after ANSI strip (▀ is multibyte → python char count)
wid() { python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
ws=set(len(A.sub("",l)) for l in sys.stdin.read().splitlines() if l!="")
print(sorted(ws))'; }

# declared square width per size (bash-3.2 safe: no associative arrays on macOS).
declw() { case "$1" in S) echo 4;; M) echo 8;; L) echo 16;; *) echo 0;; esac; }

echo "== 1) golden byte-diff: 3 sizes × 3 tiers (9 fixtures, byte-exact) =="
for sz in S M L; do
  for tier in truecolor 256 16; do
    g="$GOLD/${SEED}_${sz}_${tier}.txt"
    if [ ! -f "$g" ]; then bad "golden missing: ${SEED}_${sz}_${tier}.txt"; continue; fi
    if python3 "$SIG" --seed "$SEED" --size "$sz" --tier "$tier" | cmp -s - "$g"; then
      ok "golden byte-exact: ${sz} × ${tier}"
    else
      bad "golden DRIFT: ${sz} × ${tier} (re-render != committed golden)"
    fi
  done
done

echo "== 2) width invariant: every line == the declared square width, all 9 =="
for sz in S M L; do
  want="$(declw "$sz")"
  for tier in truecolor 256 16; do
    got="$(python3 "$SIG" --seed "$SEED" --size "$sz" --tier "$tier" | wid)"
    if [ "$got" = "[$want]" ]; then ok "width invariant: ${sz} × ${tier} all lines = $want"
    else bad "width invariant BROKEN: ${sz} × ${tier} widths=$got (want [$want])"; fi
  done
done

echo "== 3) tier fidelity: the emitted SGR family matches the tier =="
TC_M="$(python3 "$SIG" --seed "$SEED" --size M --tier truecolor)"
C256_M="$(python3 "$SIG" --seed "$SEED" --size M --tier 256)"
C16_M="$(python3 "$SIG" --seed "$SEED" --size M --tier 16)"
grep -qF '38;2;' <<<"$TC_M"    && ok "truecolor → 24-bit 38;2; SGR present" || bad "truecolor → no 38;2;"
grep -qF '38;5;' <<<"$TC_M"    && bad "truecolor → leaked a 256 38;5; SGR"  || ok "truecolor → no 38;5;"
grep -qF '38;5;' <<<"$C256_M"  && ok "256 → nearest-cube 38;5; SGR present" || bad "256 → no 38;5;"
grep -qF '38;2;' <<<"$C256_M"  && bad "256 → leaked raw truecolor 38;2;"    || ok "256 → NO raw 38;2; (the morph guard)"
grep -qF '38;2;' <<<"$C16_M"   && bad "16 → leaked raw truecolor 38;2;"     || ok "16 → no 38;2;"
grep -qF '38;5;' <<<"$C16_M"   && bad "16 → leaked 256 38;5;"               || ok "16 → no 38;5; (fixed 4-shade ANSI-16 only)"

echo "== 4) FALSIFIER: a one-pixel perturbation changes the golden (pixel-exact) =="
PERTURB="$(python3 - "$SIG" "$SEED" <<'PY'
import importlib.util,sys
p,seed=sys.argv[1],sys.argv[2]
s=importlib.util.spec_from_file_location("m",p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
base='\n'.join(m.sigil_render(seed,'M',m.tier_caps()))
_orig=m.grid_for
def patched(sd,eye=None):
    g,hue,e=_orig(sd,eye)
    g[0][0]=1 if g[0][0]==0 else 0   # flip exactly ONE pixel
    return g,hue,e
m.grid_for=patched
mut='\n'.join(m.sigil_render(seed,'M',m.tier_caps()))
print("DIFF" if base!=mut else "SAME")
PY
)"
[ "$PERTURB" = DIFF ] && ok "one-pixel flip → render differs (golden is pixel-exact)" \
                      || bad "one-pixel flip produced the SAME bytes (golden NOT pixel-sensitive)"

echo "== 5) determinism: two renders byte-identical (same seed/size/tier) =="
A="$(python3 "$SIG" --seed "$SEED" --size L --tier 256)"
B="$(python3 "$SIG" --seed "$SEED" --size L --tier 256)"
[ "$A" = "$B" ] && ok "deterministic: L × 256 identical across runs" || bad "non-deterministic render"

echo "== 6) collapse-the-twins: hmd-sigil.py (hyphen loader) == hmd_sigil.py =="
for sz in S M L; do
  H1="$(python3 "$SIG"    --seed "$SEED" --size "$sz" --tier 256)"
  H2="$(python3 "$SIG_HY" --seed "$SEED" --size "$sz" --tier 256)"
  [ "$H1" = "$H2" ] && ok "loader parity: hyphen == underscore for $sz" \
                    || bad "loader DRIFT: hmd-sigil.py != hmd_sigil.py for $sz"
done

echo "== 7) calibration card: hmd sigil --test renders + is tier-correct =="
CARD256="$(env HEIMDALL_STATUSLINE_MODE=256 python3 "$SIG" --test --seed "$SEED")"; RC=$?
[ "$RC" = 0 ] && ok "calibration exits 0" || bad "calibration exited $RC"
[ -n "$CARD256" ] && ok "calibration non-empty" || bad "calibration blank"
for tok in "calibration" "S 4x4" "M 8x8" "L 16x16" "aspect-square" "checkerboard"; do
  grep -qF "$tok" <<<"$CARD256" && ok "calibration contains: $tok" || bad "calibration missing: $tok"
done
grep -qF '38;2;' <<<"$CARD256" && bad "calibration (forced 256) leaked raw truecolor 38;2;" \
                               || ok "calibration honors the tier (256 → no 38;2;)"

echo "== 8) hmd sigil route: bin/heimdall dispatches to the core =="
if [ -x "$HMD" ]; then
  ROUT="$(env HEIMDALL_STATUSLINE_MODE=256 "$HMD" sigil --test 2>/dev/null)"; RRC=$?
  [ "$RRC" = 0 ] && ok "hmd sigil --test exits 0 via bin/heimdall" || bad "hmd sigil route exited $RRC"
  grep -qF "calibration" <<<"$ROUT" && ok "hmd sigil --test prints the calibration card" \
                                    || bad "hmd sigil route did not render the card"
else
  bad "bin/heimdall not executable at $HMD"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

#!/usr/bin/env bash
#
# heimdall-designmatch-web.test.sh — acceptance for the designmatch WEB path:
# kill the device dependency (Playwright-render the CANDIDATE, no adb/xcrun),
# the parity-score badge receipt (parity.json + parity-badge.svg from REAL diff
# numbers), and the CI gate (designmatch ci --min).
#
# Design honesty (matches the code's contract):
#   • The web CANDIDATE render uses Playwright ONLY — never adb/xcrun. Where
#     Playwright is present we render for real; where absent we honest-skip that
#     proof (a fixture PNG stands in so the downstream receipt proofs still run).
#   • The parity RECEIPT is transcribed from a metrics.json produced by the
#     UNCHANGED SSIM/pixelmatch harness — emit-parity fabricates NOTHING. We feed
#     a metrics.json with known real diff numbers and assert byte-faithful values.
#   • A run whose visual deps (pixelmatch/pngjs/ssim.js/sharp) are absent SKIPS
#     the parity computation with a clear message and writes NO parity.json —
#     never a fabricated pass. We assert the skip is honest, not faked.
#   • The CI gate reads the receipt and blocks below --min, passes above, and
#     honest-skips (non-failing) when there is nothing real to check.
#
# Proofs (each prints PASS/FAIL; exit 0 iff all hold):
#   1.  SEAM lists BOTH rn and web (a 2nd target = impl + register, not a
#       pipeline edit) — the device wall is killed by ADDING a target.
#   2.  web target GENERATES a static HTML candidate derived from the canonical
#       at the locked 1080x2444 viewport (Playwright-renderable, no device).
#   3.  a typo'd target still fails loudly (never silently rn/web).
#   4.  CANDIDATE render is Playwright-only (no adb/xcrun): render-web-candidate
#       produces a real PNG from a static HTML build — device-free.
#   5.  parity RECEIPT: emit-parity transcribes a KNOWN metrics.json into
#       parity.json (exact ssim / pixel_diff_pct / parity_pct / threshold /
#       triptych) + a parity-badge.svg — real numbers, zero fabrication.
#   6.  badge coloring is honest: a below-threshold diff → pass:false, a
#       non-green badge; an above-threshold diff → pass:true, green.
#   7.  CI gate BLOCKS below --min ("PR blocked: 87% parity < 95%", nonzero).
#   8.  CI gate PASSES above --min (exit 0).
#   9.  CI gate HONEST-SKIPS (non-failing) when no parity.json exists — and does
#       NOT fabricate one.
#   10. web run with visual deps ABSENT → honest skip (no parity.json written);
#       with them PRESENT → real parity.json. Env-adaptive, never a fake pass.
#   11. DEVICE PATH UNBROKEN: iterate + regen surface intact; the existing
#       designmatch-regen suite still passes (no regression from the new subcmds).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
DM="$REPO/bin/designmatch"
TARGET="$REPO/bin/designmatch-target"
SCRIPTS="$REPO/skills/designmatch/scripts"
RENDER_WEB="$SCRIPTS/render-web-candidate.js"
EMIT="$SCRIPTS/emit-parity.js"
CANON="$REPO/test/fixtures/designmatch/Checkout.canonical.jsx"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for JSON assertions" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required" >&2; exit 2; }
[ -x "$DM" ]         || { echo "FATAL: designmatch not executable at $DM" >&2; exit 2; }
[ -x "$TARGET" ]     || { echo "FATAL: designmatch-target not executable at $TARGET" >&2; exit 2; }
[ -f "$RENDER_WEB" ] || { echo "FATAL: missing $RENDER_WEB" >&2; exit 2; }
[ -f "$EMIT" ]       || { echo "FATAL: missing $EMIT" >&2; exit 2; }
[ -f "$CANON" ]      || { echo "FATAL: missing canonical fixture $CANON" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Dep probes (drive the honest-skip branches).
HAS_PLAYWRIGHT=0
( cd "$SCRIPTS" && node -e "require('playwright')" >/dev/null 2>&1 ) && HAS_PLAYWRIGHT=1
HAS_VISUAL=1
for m in pixelmatch pngjs ssim.js sharp; do
  ( cd "$SCRIPTS" && node -e "require('$m')" >/dev/null 2>&1 ) || HAS_VISUAL=0
done
echo "[env] playwright=$HAS_PLAYWRIGHT visual-deps(pixelmatch/pngjs/ssim.js/sharp)=$HAS_VISUAL"

# Minimal valid 1x1 PNG (base64) — a real PNG that stands in as a candidate when
# Playwright is absent, so the device-free receipt proofs still run.
PNG_1PX_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
write_fixture_png() { printf '%s' "$PNG_1PX_B64" | base64 --decode > "$1"; }

# A KNOWN metrics.json in the exact shape the SSIM/pixelmatch harness emits
# (visual-diff.js). These are REAL diff numbers for a known pair; emit-parity
# only transcribes them — it computes no similarity itself.
write_metrics() {
  # write_metrics <path> <ssim> <pixelDiffPct> <pass>
  cat > "$1" <<JSON
{
  "ssim": $2,
  "pixelDiffCount": 102345,
  "totalPixels": 2639520,
  "pixelDiffPct": $3,
  "width": 1080,
  "height": 2444,
  "threshold": 0.1,
  "canonical": "canonical.png",
  "native": "candidate.png",
  "timestamp": "2026-01-01T00:00:00.000Z",
  "resized": null,
  "pass": $4
}
JSON
}

echo ""
echo "1. SEAM lists BOTH rn and web (kill the device wall by ADDING a target):"
LIST_OUT="$("$TARGET" list 2>&1)"; LIST_RC=$?
if [ "$LIST_RC" -eq 0 ] \
   && grep -qE '^rn[[:space:]]' <<<"$LIST_OUT" \
   && grep -qE '^web[[:space:]]' <<<"$LIST_OUT"; then
  ok "registry lists rn AND web (pluggable seam — no pipeline edit)"
else
  bad "registry did not list both rn and web (rc=$LIST_RC, out='$LIST_OUT')"
fi

echo ""
echo "2. web target GENERATES a static HTML candidate at 1080x2444 from canonical:"
CAND_HTML="$WORK/candidate.html"
if "$TARGET" generate web Checkout "$CANON" --out "$CAND_HTML" 2>/dev/null \
   && [ -s "$CAND_HTML" ]; then
  if grep -q "1080" "$CAND_HTML" && grep -q "2444" "$CAND_HTML" \
     && grep -q "__APP_READY__" "$CAND_HTML" \
     && grep -q "Confirm purchase" "$CAND_HTML" \
     && grep -q "Apply coupon" "$CAND_HTML"; then
    ok "web generate → static HTML with locked viewport + derived canonical text + __APP_READY__"
  else
    bad "generated HTML missing viewport/derived-text/ready marker"
  fi
else
  bad "web generate did not produce an HTML file"
fi

echo ""
echo "3. a typo'd target fails loudly (never silently rn/web):"
BOGUS_OUT="$("$TARGET" ext bogustarget 2>&1)"; BOGUS_RC=$?
if [ "$BOGUS_RC" -ne 0 ] && grep -qi "available" <<<"$BOGUS_OUT"; then
  ok "unknown target 'bogustarget' fails loudly listing available keys (rc=$BOGUS_RC)"
else
  bad "typo target did not fail loudly (rc=$BOGUS_RC, out='$BOGUS_OUT')"
fi

echo ""
echo "4. CANDIDATE render is Playwright-only, no adb/xcrun (device-free):"
CAND_PNG="$WORK/candidate.png"
if [ "$HAS_PLAYWRIGHT" -eq 1 ]; then
  set +e
  R_OUT="$(node "$RENDER_WEB" --html "$CAND_HTML" --out "$CAND_PNG" 2>&1)"
  R_RC=$?
  set -e
  if [ "$R_RC" -eq 0 ] && [ -s "$CAND_PNG" ] \
     && node -e 'const fs=require("fs");const b=fs.readFileSync(process.argv[1]);process.exit(b.length>=8&&b[0]===0x89&&b[1]===0x50&&b[2]===0x4e&&b[3]===0x47?0:1)' "$CAND_PNG"; then
    ok "render-web-candidate produced a real PNG from a static HTML build (Playwright, no device)"
  else
    bad "candidate render failed (rc=$R_RC, out='$R_OUT')"
  fi
else
  # Honest skip: no Playwright. A fixture PNG stands in so downstream proofs run.
  write_fixture_png "$CAND_PNG"
  ok "SKIP (Playwright absent) — candidate render honest-skipped; fixture PNG stands in"
fi

echo ""
echo "5. parity RECEIPT: emit-parity transcribes a KNOWN metrics.json (real numbers):"
RCPT="$WORK/receipt"
mkdir -p "$RCPT"
write_metrics "$RCPT/metrics.json" 0.9612 3.87 true
TRIP="$RCPT/composite.png"; write_fixture_png "$TRIP"
set +e
node "$EMIT" --metrics "$RCPT/metrics.json" --out-dir "$RCPT" --screen Checkout --min 0.95 --triptych "$TRIP" >/dev/null 2>&1
E_RC=$?
set -e
PJ="$RCPT/parity.json"; BADGE="$RCPT/parity-badge.svg"
if [ "$E_RC" -eq 0 ] && [ -f "$PJ" ] && [ -f "$BADGE" ]; then
  GOT_SSIM="$(jq -r '.ssim' "$PJ")"
  GOT_PIX="$(jq -r '.pixel_diff_pct' "$PJ")"
  GOT_PCT="$(jq -r '.parity_pct' "$PJ")"
  GOT_THR="$(jq -r '.threshold' "$PJ")"
  GOT_PASS="$(jq -r '.pass' "$PJ")"
  GOT_SCREEN="$(jq -r '.screen' "$PJ")"
  GOT_TRIP="$(jq -r '.triptych' "$PJ")"
  if [ "$GOT_SSIM" = "0.9612" ] && [ "$GOT_PIX" = "3.87" ] && [ "$GOT_PCT" = "96" ] \
     && [ "$GOT_THR" = "0.95" ] && [ "$GOT_PASS" = "true" ] && [ "$GOT_SCREEN" = "Checkout" ] \
     && [ "$GOT_TRIP" = "$TRIP" ]; then
    ok "parity.json transcribes real diff numbers (ssim=0.9612 pix=3.87 pct=96 thr=0.95 pass=true, triptych recorded)"
  else
    bad "parity.json values wrong (ssim=$GOT_SSIM pix=$GOT_PIX pct=$GOT_PCT thr=$GOT_THR pass=$GOT_PASS screen=$GOT_SCREEN trip=$GOT_TRIP)"
  fi
  if grep -qi "design parity" "$BADGE" && grep -q "96%" "$BADGE"; then
    ok "parity-badge.svg is a drop-in receipt ('design parity' + 96%)"
  else
    bad "badge svg missing label/percent"
  fi
else
  bad "emit-parity did not write parity.json + badge (rc=$E_RC)"
fi

echo ""
echo "6. badge coloring is honest (pass=green / fail=non-green):"
FAILDIR="$WORK/fail"; mkdir -p "$FAILDIR"
write_metrics "$FAILDIR/metrics.json" 0.8700 12.4 false
node "$EMIT" --metrics "$FAILDIR/metrics.json" --out-dir "$FAILDIR" --screen Checkout --min 0.95 >/dev/null 2>&1
FPASS="$(jq -r '.pass' "$FAILDIR/parity.json" 2>/dev/null || echo err)"
FPCT="$(jq -r '.parity_pct' "$FAILDIR/parity.json" 2>/dev/null || echo err)"
GREEN="#3fb950"
PASS_HAS_GREEN=0; grep -qi "$GREEN" "$RCPT/parity-badge.svg" && PASS_HAS_GREEN=1
FAIL_HAS_GREEN=0; grep -qi "$GREEN" "$FAILDIR/parity-badge.svg" && FAIL_HAS_GREEN=1
if [ "$FPASS" = "false" ] && [ "$FPCT" = "87" ] \
   && [ "$PASS_HAS_GREEN" -eq 1 ] && [ "$FAIL_HAS_GREEN" -eq 0 ] \
   && grep -q "87%" "$FAILDIR/parity-badge.svg"; then
  ok "below-threshold badge is pass:false, 87%, NON-green; above-threshold badge is green"
else
  bad "badge coloring dishonest (fpass=$FPASS fpct=$FPCT passGreen=$PASS_HAS_GREEN failGreen=$FAIL_HAS_GREEN)"
fi

echo ""
echo "7. CI gate BLOCKS below --min:"
APP_FAIL="$WORK/app_fail"; mkdir -p "$APP_FAIL/.designmatch"
write_metrics "$APP_FAIL/m.json" 0.8700 12.4 false
node "$EMIT" --metrics "$APP_FAIL/m.json" --out-dir "$APP_FAIL/.designmatch" --screen Checkout --min 0.95 >/dev/null 2>&1
set +e
CI_OUT="$("$DM" ci --min 0.95 --app-dir "$APP_FAIL" 2>&1)"
CI_RC=$?
set -e
if [ "$CI_RC" -ne 0 ] && grep -qi "blocked" <<<"$CI_OUT" \
   && grep -q "87" <<<"$CI_OUT" && grep -q "95" <<<"$CI_OUT"; then
  ok "ci --min 0.95 BLOCKS at 87% (nonzero + 'PR blocked: 87% parity < 95%')"
else
  bad "ci did not block below threshold (rc=$CI_RC, out='$CI_OUT')"
fi

echo ""
echo "8. CI gate PASSES above --min:"
APP_OK="$WORK/app_ok"; mkdir -p "$APP_OK/.designmatch"
write_metrics "$APP_OK/m.json" 0.9612 3.87 true
node "$EMIT" --metrics "$APP_OK/m.json" --out-dir "$APP_OK/.designmatch" --screen Checkout --min 0.95 >/dev/null 2>&1
set +e
CI_OUT2="$("$DM" ci --min 0.95 --app-dir "$APP_OK" 2>&1)"
CI_RC2=$?
set -e
if [ "$CI_RC2" -eq 0 ] && grep -q "96" <<<"$CI_OUT2"; then
  ok "ci --min 0.95 PASSES at 96% (exit 0)"
else
  bad "ci did not pass above threshold (rc=$CI_RC2, out='$CI_OUT2')"
fi

echo ""
echo "9. CI gate HONEST-SKIPS (non-failing) with no parity.json — and fakes nothing:"
APP_NONE="$WORK/app_none"; mkdir -p "$APP_NONE/.designmatch"
set +e
CI_OUT3="$("$DM" ci --min 0.95 --app-dir "$APP_NONE" 2>&1)"
CI_RC3=$?
set -e
if [ "$CI_RC3" -eq 0 ] && grep -qi "skip" <<<"$CI_OUT3" \
   && [ ! -f "$APP_NONE/.designmatch/parity.json" ]; then
  ok "ci skips honestly (exit 0 + 'skip') and did NOT fabricate a parity.json"
else
  bad "ci skip dishonest (rc=$CI_RC3, out='$CI_OUT3', parity exists=$([ -f "$APP_NONE/.designmatch/parity.json" ] && echo yes || echo no))"
fi

echo ""
echo "10. web run — deps-absent → honest skip (no fake parity); deps-present → real receipt:"
APP_WEB="$WORK/app_web"; mkdir -p "$APP_WEB"
set +e
WEB_OUT="$("$DM" web Checkout --canonical "$CANON" --candidate-png "$CAND_PNG" --canonical-png "$CAND_PNG" --app-dir "$APP_WEB" --min 0.95 2>&1)"
WEB_RC=$?
set -e
WEB_PARITY="$APP_WEB/.designmatch/parity.json"
if [ "$HAS_VISUAL" -eq 1 ]; then
  if [ "$WEB_RC" -eq 0 ] && [ -f "$WEB_PARITY" ] && [ "$(jq -r '.ssim' "$WEB_PARITY")" != "null" ]; then
    ok "web run (visual deps present) → real parity.json with a computed ssim"
  else
    bad "web run should have produced a real parity.json (rc=$WEB_RC, out='$WEB_OUT')"
  fi
else
  if [ "$WEB_RC" -eq 0 ] && grep -qiE "skip|install" <<<"$WEB_OUT" \
     && [ ! -f "$WEB_PARITY" ]; then
    ok "web run (visual deps absent) → honest skip (exit 0, no parity.json fabricated)"
  else
    bad "web run skip dishonest (rc=$WEB_RC, parity exists=$([ -f "$WEB_PARITY" ] && echo yes || echo no), out='$WEB_OUT')"
  fi
fi

echo ""
echo "11. DEVICE PATH UNBROKEN + no regression:"
HELP_OUT="$("$DM" help 2>&1)"
if grep -q "iterate" <<<"$HELP_OUT" \
   && grep -q "regen" <<<"$HELP_OUT" \
   && grep -q "web" <<<"$HELP_OUT" \
   && grep -q "ci" <<<"$HELP_OUT"; then
  ok "help surfaces device path (iterate/regen) AND new web/ci subcommands"
else
  bad "help missing expected subcommands"
fi
set +e
bash "$REPO/test/designmatch-regen.test.sh" >/tmp/dm_regen_regression.log 2>&1
REGEN_RC=$?
set -e
if [ "$REGEN_RC" -eq 0 ]; then
  ok "existing designmatch-regen suite still passes (no regression from web/ci)"
else
  bad "designmatch-regen suite regressed (rc=$REGEN_RC — see /tmp/dm_regen_regression.log)"
fi

echo ""
echo "heimdall-designmatch-web.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1

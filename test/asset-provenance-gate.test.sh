#!/usr/bin/env bash
#
# asset-provenance-gate.test.sh — the FABRICATED-ASSET falsifier.
#
# WHY. `launch-docs/assets/wall.png` depicts five invented teammates (arjun, kai,
# maya, nadia, priya) and a merge count seeded from a throwaway beats.log fixture.
# `launch-docs/assets/README.md` is honest about that — but a README reader never
# opens the assets README. README.md carries a `HEIMDALL:HERO-ASSET` slot waiting
# for the REAL recording (`wall.gif`, not yet produced). The failure mode this gate
# exists to prevent: someone fills that empty hero slot with `wall.png` as a
# stand-in, and the front page of a project whose whole pitch is "our receipts are
# real" leads with fabricated teammates.
#
# THE MECHANISM. Provenance is marked AT THE SOURCE, in
# `launch-docs/assets/provenance.json` — one entry per asset, each declaring
# `real` or `fixture` plus a `reason` and a `receipt` (you cannot assert `real`
# without citing where that claim cashes out). A filename blocklist would rot the
# moment someone adds `wall2.png`; a manifest cannot, because Guarantee B fails if
# the directory and the manifest ever disagree.
#
# FAIL-CLOSED. The default is `fixture`, hardcoded HERE, not read from the
# manifest — an undeclared asset, or one with an unrecognised provenance value, is
# NOT assumed real. There is deliberately no manifest field that can widen what
# counts as `real`.
#
# Guarantees:
#   A. MANIFEST PRESENT + WELL-FORMED — exists, parses, right schema tag, declares
#      at least one asset, every entry carries file/provenance/reason/receipt.
#      Missing, empty, or unparseable => RED, never a silent pass.
#   B. MANIFEST COVERS THE DIRECTORY BOTH WAYS — every asset file on disk is
#      declared, and every declared file exists. Neither side may rot.
#   C. NO FIXTURE ASSET ON A READER-FACING SURFACE — HTML comments are stripped
#      first (a comment renders to nobody, so the HERO-ASSET slot naming the
#      expected future `wall.gif` is correctly inert), then every surface is
#      scanned for a reference to each fixture asset. One hit => RED.
#   D. SURFACES WERE ACTUALLY SCANNED — README.md must be among them and the
#      scanned count must be non-zero, so a mis-resolved repo path can never
#      vacuously "pass" with nothing checked.
#   E. THE SELF-DOCUMENTATION EXEMPTION IS LOAD-BEARING — launch-docs/ is exempt
#      (the assets README documents its own fixtures on purpose), and that
#      exemption is proven non-decorative: the assets README must contain at least
#      one reference the scanner WOULD have flagged had the exemption been wrong.
#
# --self-test: proves the gate can go red. Copies the repo to a throwaway tmpdir,
# plants a fixture asset in the README hero slot, asserts this script reports it,
# then does the same for a deleted manifest and an emptied manifest. Nothing in
# the real tree is touched.
#
# Usage:  test/asset-provenance-gate.test.sh   (exit 0 = no fabricated asset is
#                                               reachable from a reader surface)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${ASSET_PROV_REPO:-$(cd "$SELF_DIR/.." && pwd)}"
ASSET_DIR="$REPO/launch-docs/assets"
MANIFEST="$ASSET_DIR/provenance.json"
SCHEMA='asset_provenance_v1'

# ── --self-test: prove the gate is falsifiable ────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "asset-provenance-gate --self-test: asserting the gate goes RED on each planted fault"

  # 1. A fixture asset embedded on the README hero surface.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  printf '\n![Heimdall'"'"'s proven wall](launch-docs/assets/wall.png)\n' >> "$TMP/README.md"
  if ASSET_PROV_REPO="$TMP" bash "$SELF_DIR/asset-provenance-gate.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with a fixture asset embedded in README.md" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on a fixture asset in the README"

  # 2. Manifest deleted — the anti-vacuous guard. No manifest must NEVER mean
  #    "nothing is fixture, everything passes".
  rm -rf "$TMP"; TMP="$(mktemp -d)"
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  rm -f "$TMP/launch-docs/assets/provenance.json"
  if ASSET_PROV_REPO="$TMP" bash "$SELF_DIR/asset-provenance-gate.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with the provenance manifest deleted" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on a missing manifest"

  # 3. Manifest emptied — matching zero assets must fail loudly, not pass.
  rm -rf "$TMP"; TMP="$(mktemp -d)"
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  printf '{"schema":"%s","assets":[]}\n' "$SCHEMA" > "$TMP/launch-docs/assets/provenance.json"
  if ASSET_PROV_REPO="$TMP" bash "$SELF_DIR/asset-provenance-gate.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with an empty manifest (zero assets matched)" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on an empty manifest"

  # 4. An asset relabelled `real` without a receipt cannot buy its way onto the
  #    README — an unsupported provenance claim is still a claim.
  rm -rf "$TMP"; TMP="$(mktemp -d)"
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  jq '(.assets[] | select(.file == "wall.png") | .receipt) = ""' \
    "$REPO/launch-docs/assets/provenance.json" > "$TMP/launch-docs/assets/provenance.json"
  if ASSET_PROV_REPO="$TMP" bash "$SELF_DIR/asset-provenance-gate.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with a provenance entry missing its receipt" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on a receipt-less provenance claim"

  echo "asset-provenance-gate --self-test: PASS"
  exit 0
fi

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Strip HTML comments (multi-line aware) from stdin's file. A commented-out
# reference renders to no reader, so the HERO-ASSET slot documenting the expected
# future wall.gif is inert — and so is the prose in it naming wall.png/wall.svg as
# the things it deliberately does NOT embed.
strip_html_comments() {
  awk '
    BEGIN { inc = 0 }
    {
      line = $0; out = ""
      while (length(line) > 0) {
        if (inc) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          line = substr(line, p + 3); inc = 0
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, p - 1)
          line = substr(line, p + 4); inc = 1
        }
      }
      print out
    }
  ' "$1"
}

echo "asset-provenance-gate harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ── Guarantee A: the manifest exists and is well-formed ────────────────────────
MANIFEST_OK=0
if [ -f "$MANIFEST" ]; then
  ok "provenance manifest exists (launch-docs/assets/provenance.json)"
  if jq -e . "$MANIFEST" >/dev/null 2>&1; then
    ok "provenance manifest parses as JSON"
    MANIFEST_OK=1
  else
    bad "provenance manifest is NOT valid JSON — provenance cannot be established"
  fi
else
  bad "provenance manifest is MISSING — every asset defaults to fixture, gate cannot run"
fi

DECLARED_COUNT=0
if [ "$MANIFEST_OK" -eq 1 ]; then
  if [ "$(jq -r '.schema // ""' "$MANIFEST")" = "$SCHEMA" ]; then
    ok "manifest schema tag is $SCHEMA"
  else
    bad "manifest schema tag is not $SCHEMA — refusing to interpret an unknown format"
  fi
  DECLARED_COUNT="$(jq -r '(.assets // []) | length' "$MANIFEST")"
  if [ "$DECLARED_COUNT" -gt 0 ]; then
    ok "manifest declares $DECLARED_COUNT asset(s)"
  else
    bad "manifest declares ZERO assets — an empty manifest must never pass silently"
  fi
else
  bad "manifest schema tag unverifiable (manifest unreadable)"
  bad "manifest asset count unverifiable (manifest unreadable)"
fi

# Every entry must carry a file, a recognised provenance, a reason AND a receipt.
# A `real` claim without a citation is exactly the kind of unbacked assertion this
# repo refuses to ship.
FIXTURE_FILES=""
REAL_FILES=""
INCOMPLETE=0
if [ "$MANIFEST_OK" -eq 1 ] && [ "$DECLARED_COUNT" -gt 0 ]; then
  while IFS=$'\t' read -r f prov reason receipt; do
    [ -n "$f" ] || { INCOMPLETE=$((INCOMPLETE+1)); printf '    entry with no "file" field\n'; continue; }
    if [ -z "$reason" ] || [ -z "$receipt" ]; then
      INCOMPLETE=$((INCOMPLETE+1))
      printf '    %s: provenance claimed without a reason+receipt\n' "$f"
    fi
    # FAIL-CLOSED: only the exact string `real` is trusted. Anything else —
    # `fixture`, a typo, an empty value, a novel category — is treated as fixture.
    if [ "$prov" = "real" ]; then
      REAL_FILES="$REAL_FILES$f"$'\n'
    else
      FIXTURE_FILES="$FIXTURE_FILES$f"$'\n'
      if [ "$prov" != "fixture" ]; then
        INCOMPLETE=$((INCOMPLETE+1))
        printf '    %s: unrecognised provenance "%s" — treated as fixture\n' "$f" "$prov"
      fi
    fi
  done < <(jq -r '(.assets // [])[] | [(.file // ""), (.provenance // ""), (.reason // ""), (.receipt // "")] | @tsv' "$MANIFEST")
fi
[ "$INCOMPLETE" -eq 0 ] && [ "$DECLARED_COUNT" -gt 0 ] \
  && ok "every manifest entry has a recognised provenance with a reason + receipt" \
  || bad "$INCOMPLETE manifest entr(ies) are incomplete or use an unrecognised provenance"

# ── Guarantee B: the manifest and the directory agree, both ways ───────────────
MISSING_ON_DISK=0
UNDECLARED=0
if [ "$MANIFEST_OK" -eq 1 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -f "$ASSET_DIR/$f" ]; then
      MISSING_ON_DISK=$((MISSING_ON_DISK+1))
      printf '    declared but absent from disk: %s\n' "$f"
    fi
  done < <(jq -r '(.assets // [])[] | .file // empty' "$MANIFEST")

  for path in "$ASSET_DIR"/*; do
    [ -f "$path" ] || continue
    base="$(basename "$path")"
    case "$base" in README.md|provenance.json) continue ;; esac
    if ! jq -e --arg f "$base" '(.assets // []) | map(.file) | index($f)' "$MANIFEST" >/dev/null 2>&1; then
      UNDECLARED=$((UNDECLARED+1))
      FIXTURE_FILES="$FIXTURE_FILES$base"$'\n'   # fail-closed: undeclared => fixture
      printf '    on disk but undeclared (defaulted to fixture): %s\n' "$base"
    fi
  done
fi
[ "$MANIFEST_OK" -eq 1 ] && [ "$MISSING_ON_DISK" -eq 0 ] \
  && ok "every declared asset exists on disk" \
  || bad "$MISSING_ON_DISK declared asset(s) missing from disk — the manifest has rotted"
[ "$MANIFEST_OK" -eq 1 ] && [ "$UNDECLARED" -eq 0 ] \
  && ok "every asset on disk is declared in the manifest" \
  || bad "$UNDECLARED asset(s) on disk carry no provenance declaration"

# ── the reader-facing surfaces ────────────────────────────────────────────────
# launch-docs/ is deliberately NOT a surface: the assets README's whole job is to
# document its own fixtures (Guarantee E proves that exemption is load-bearing).
SURFACES=()
[ -f "$REPO/README.md" ] && SURFACES+=("$REPO/README.md")
[ -f "$REPO/packages/runheimdall/README.md" ] && SURFACES+=("$REPO/packages/runheimdall/README.md")
if [ -d "$REPO/site" ]; then
  while IFS= read -r sf; do
    [ -n "$sf" ] && SURFACES+=("$sf")
  done < <(find "$REPO/site" -type f \( -name '*.md' -o -name '*.mdx' -o -name '*.html' \) 2>/dev/null)
fi

# ── Guarantee C: no fixture asset is referenced from a reader-facing surface ───
REFS=0
SURFACES_CHECKED=0
for surface in ${SURFACES+"${SURFACES[@]}"}; do
  SURFACES_CHECKED=$((SURFACES_CHECKED+1))
  visible="$(strip_html_comments "$surface")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Match the asset as a PATH (`assets/<file>`), which is how any reference that
    # actually renders must be written — a bare prose mention of the filename is
    # honest documentation and is not a fabrication.
    if printf '%s\n' "$visible" | grep -Fq "assets/$f"; then
      REFS=$((REFS+1))
      printf '    FABRICATED ASSET ON A READER SURFACE: %s references fixture asset %s\n' \
        "${surface#$REPO/}" "$f"
    fi
  done <<< "$FIXTURE_FILES"
done
[ "$REFS" -eq 0 ] \
  && ok "no fixture-provenance asset is referenced from any reader-facing surface" \
  || bad "$REFS fixture-asset reference(s) on a reader surface — a README reader would see invented data"

# ── Guarantee D: the scan was not vacuous ─────────────────────────────────────
if [ "$SURFACES_CHECKED" -gt 0 ] && [ -f "$REPO/README.md" ]; then
  ok "scanned $SURFACES_CHECKED reader-facing surface(s), README.md among them"
else
  bad "scanned $SURFACES_CHECKED surface(s) / README.md missing — the gate checked nothing"
fi

# ── Guarantee E: the launch-docs exemption is load-bearing, not decorative ─────
# The assets README must contain at least one reference the scanner WOULD have
# flagged. If it does not, the exemption is protecting nothing and the next person
# to read this gate would wrongly believe fixtures are documented somewhere.
SELF_DOC=0
if [ -f "$ASSET_DIR/README.md" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -Fq "assets/$f" "$ASSET_DIR/README.md" 2>/dev/null; then
      SELF_DOC=$((SELF_DOC+1))
    fi
  done <<< "$FIXTURE_FILES"
fi
[ "$SELF_DOC" -gt 0 ] \
  && ok "assets README documents $SELF_DOC fixture asset(s) — exemption is load-bearing" \
  || bad "assets README references no fixture asset — the fixtures are documented nowhere"

echo "--------------------------------------------------------------------"
printf 'asset-provenance-gate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

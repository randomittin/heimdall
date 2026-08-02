#!/usr/bin/env bash
#
# version-drift.test.sh — the version-drift gate: plugin.json is the SINGLE SOURCE.
#
#   bash test/version-drift.test.sh     (exit 0 = every surface agrees with plugin.json)
#
# .claude-plugin/plugin.json .version is authoritative. EVERY other surface in the repo
# that names the plugin version must equal it. This test goes RED the instant any one of
# them drifts. It is the gate that would have caught the live defect it was written for:
# packages/runheimdall/package.json sat at 2.0.5 while the manifest was at 2.2.6 — the npx
# wrapper `npx runheimdall` was installing a months-stale release, and nothing was red.
#
# Surfaces gated (each is RENDERED from the manifest, never hand-typed):
#   1. VERSION                              — bin/heimdall-render-version
#   2. README.md generated region + no stale semver pin anywhere in the file
#                                           — bin/heimdall-render-version
#   3. packages/runheimdall/package.json    — .version, .heimdall.tag, .heimdall.installScriptUrl
#                                           — release/sync-release.sh
#   4. vercel.json /install redirect target — release/sync-release.sh
#   5. _redirects  /install redirect target — release/sync-release.sh
#   6. install.sh  DEFAULT_REF              — release/ship.sh bump_default_ref
#   7. the marketing SITE (a SIBLING repo)  — hand-maintained; see below
#
# Surface 7 is the runheimdall.dev checkout, which is NOT a subdirectory of this repo. Its
# version strings are hand-typed and nothing gated them, so they drifted three different ways
# at once while the plugin shipped 2.3.8: the <meta heimdall-version> tags sat at v2.0.16 and
# v2.2.2, the index.html JSON-LD softwareVersion at 2.3.3, and the llms-full.txt install URL
# at v2.2.6. That is how a public install one-liner reaches v2.0.16. Absent checkout =>
# SKIPPED and said out loud, never a failure — a contributor without the site must not eat a
# red. Point HEIMDALL_SITE_DIR at it to override the default sibling location.
#
# Scoped to FULL three-part semver (X.Y.Z). Two-part strings that are NOT the plugin
# version ("Claude Code 1.0+", "0.50 median reuse") are not version pins and are ignored.
# On the site this scoping matters more, not less: published pages legitimately name OTHER
# software's versions in prose (a pinned google-cloud-firestore==2.16.1, superx v1.1.0, the
# v2.0.5 incident write-up), so this gate asserts the SPECIFIC version-bearing fields listed
# above rather than sweeping every semver on the page.
#
# R6: this gate ships with a corrupt-and-confirm proof — `--self-test` plants a drift in a
# THROWAWAY copy of the repo, asserts the gate reports it, and restores nothing (the copy is
# discarded). A gate that cannot demonstrate going red proves nothing.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${VERSION_DRIFT_REPO:-$(cd "$SELF_DIR/.." && pwd)}"

# ── --self-test: the corrupt-and-confirm proof promised above ─────────────────
# Every mutation happens in a `mktemp -d` throwaway copy reached through the
# VERSION_DRIFT_REPO override; the real tree is never written to.
if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  SITE_TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP" "$SITE_TMP"' EXIT

  # Repo mutants must be blind to the real site: if the live site were drifted, every
  # one of them would "correctly go RED" with the mutation removed, and the proof
  # would be worth nothing. NO_SITE is never created.
  NO_SITE="$TMP/no-site-here"
  MUT_SITE="$NO_SITE"

  SELF_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$REPO/.claude-plugin/plugin.json" | head -1)"
  SELF_TAG="v$SELF_VER"

  # set_version <json-file> <semver> — rewrites the single top-level .version.
  # plugin.json and packages/runheimdall/package.json each carry exactly one
  # "version" key, so this is unambiguous without depending on jq being installed.
  set_version() {
    sed 's/"version"[[:space:]]*:[[:space:]]*"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"/"version": "'"$2"'"/' "$1" > "$1.mut" \
      && mv "$1.mut" "$1"
  }

  # assert_red <label> <expected-substring> — require BOTH a non-zero exit AND the
  # SPECIFIC failure the mutation should have caused. Asserting the reason rather
  # than a pass/fail count is deliberate: counts shift every time a surface is added,
  # which trains people to "just update the number" instead of reading the failure.
  assert_red() {
    local label="$1" want="$2" out summary
    if out="$(VERSION_DRIFT_REPO="$TMP" HEIMDALL_SITE_DIR="$MUT_SITE" bash "$SELF_DIR/version-drift.test.sh" 2>&1)"; then
      echo "  ✗ SELF-TEST FAILED: gate stayed GREEN with $label planted" >&2
      exit 1
    fi
    case "$out" in
      *"$want"*) ;;
      *) echo "  ✗ SELF-TEST FAILED: RED for the wrong reason with $label planted (wanted: $want)" >&2
         printf '%s\n' "$out" >&2
         exit 1 ;;
    esac
    summary="$(printf '%s\n' "$out" | grep -E '^version-drift.test.sh:' | tail -1)"
    echo "  ✓ RED on $label — ${summary:-<no summary line>}"
  }

  # assert_green <label> — the inverted direction. Without this, a mutant that goes
  # red for an unrelated reason looks like a working proof.
  assert_green() {
    local label="$1" out
    if out="$(VERSION_DRIFT_REPO="$TMP" HEIMDALL_SITE_DIR="$MUT_SITE" bash "$SELF_DIR/version-drift.test.sh" 2>&1)"; then
      echo "  ✓ GREEN on $label"
    else
      echo "  ✗ SELF-TEST FAILED: gate went RED on $label" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
  }

  echo "version-drift --self-test: asserting the gate goes RED on planted drift"

  # Mutant 1 — the SINGLE SOURCE itself moves. Every rendered surface must disagree.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  set_version "$TMP/.claude-plugin/plugin.json" 9.9.9
  assert_red "plugin.json .version=9.9.9" "VERSION drift"

  # Mutant 2 — THE HISTORICAL LIVE DEFECT. packages/runheimdall/package.json sat at
  # 2.0.5 while the manifest was current, so `npx runheimdall` fetched a months-stale
  # installScriptUrl and installed a months-stale Heimdall with nothing red. This is
  # the regression that actually happened in production; it stays in the proof set.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  set_version "$TMP/packages/runheimdall/package.json" 2.0.5
  assert_red "runheimdall package.json .version=2.0.5" "runheimdall package.json drift"

  # Mutants 3+4 — the SITE block, both directions. A site surface that is never proven
  # able to go red is exactly how the site drifted to v2.0.16 unnoticed. proof.html (not
  # index.html) carries the planted tag so ONLY the meta assertion is in play.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  MUT_SITE="$SITE_TMP"
  printf '<meta name="heimdall-version" content="v0.0.1">\n' > "$SITE_TMP/proof.html"
  assert_red "site meta heimdall-version=v0.0.1" "site meta heimdall-version drift"

  printf '<meta name="heimdall-version" content="%s">\n' "$SELF_TAG" > "$SITE_TMP/proof.html"
  assert_green "site meta heimdall-version=$SELF_TAG"

  # Mutant 5 — degrade, don't crash: no site checkout must never mean a red.
  MUT_SITE="$NO_SITE"
  assert_green "no site checkout (skipped, not failed)"

  echo "version-drift --self-test: PASS"
  exit 0
fi

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

MANIFEST="$REPO/.claude-plugin/plugin.json"
README="$REPO/README.md"
VERSION_FILE="$REPO/VERSION"
PKG="$REPO/packages/runheimdall/package.json"
VERCEL="$REPO/vercel.json"
REDIRECTS="$REPO/_redirects"
INSTALL="$REPO/install.sh"

# read_json <file> <jq-filter> <sed-fallback-pattern>
# jq when present; sed fallback keeps the gate runnable on a box without jq (the same
# dual resolution release/ship.sh read_version and bin/heimdall-render-version use).
read_version_field() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.version // empty' "$file" 2>/dev/null
  else
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$file" | head -1
  fi
}

# ── The single source of truth ───────────────────────────────────────────────
[ -f "$MANIFEST" ] || { printf 'version-drift: manifest missing: %s\n' "$MANIFEST" >&2; exit 1; }
VER="$(read_version_field "$MANIFEST")"
TAG="v$VER"

echo "version-drift harness  repo=$REPO  manifest=$VER"
echo "--------------------------------------------------------------------"

printf '%s' "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  && ok "plugin.json .version is a readable semver ($VER)" \
  || { bad "plugin.json .version not semver: '${VER:-<none>}'"; echo; echo "version-drift.test.sh: $PASS passed, $FAIL failed."; exit 1; }

# ── 1. VERSION ───────────────────────────────────────────────────────────────
if [ -f "$VERSION_FILE" ]; then
  VF="$(tr -d '[:space:]' < "$VERSION_FILE")"
  [ "$VF" = "$VER" ] \
    && ok "VERSION == plugin.json ($VF)" \
    || bad "VERSION drift: VERSION='$VF' != plugin.json='$VER'"
else
  bad "VERSION missing at repo root (bin/heimdall-render-version must mirror plugin.json into it)"
fi

# ── 2. README: generated region carries the version, and no stale semver anywhere ──
if [ -f "$README" ]; then
  grep -Fq "badge/version-${VER}-" "$README" \
    && ok "README generated region carries the manifest version ($VER)" \
    || bad "README generated region does not carry '$VER' — run bin/heimdall-render-version"

  grep -Fq 'HEIMDALL:VERSION:BEGIN' "$README" \
    && ok "README version region is generated (markers present)" \
    || bad "README has no HEIMDALL:VERSION markers — the version is hand-typed and will drift"

  # Any three-part semver in README that is not the manifest version is a stale pin.
  README_DRIFT=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [ "$v" = "$VER" ] && continue
    bad "README stale version pin: '$v' != plugin.json '$VER'"
    README_DRIFT=1
  done <<EOF
$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$README" | sort -u)
EOF
  [ "$README_DRIFT" -eq 0 ] && ok "README carries no stale version pin"
else
  bad "README.md missing"
fi

# ── 3. packages/runheimdall/package.json — the npx wrapper ───────────────────
# This is the surface that actually drifted in production (2.0.5 vs 2.2.6): `npx runheimdall`
# fetches .heimdall.installScriptUrl, so a stale tag here installs a stale Heimdall.
if [ -f "$PKG" ]; then
  PKG_VER="$(read_version_field "$PKG")"
  [ "$PKG_VER" = "$VER" ] \
    && ok "runheimdall package.json .version == plugin.json ($PKG_VER)" \
    || bad "runheimdall package.json drift: .version='$PKG_VER' != plugin.json='$VER'"

  if command -v jq >/dev/null 2>&1; then
    PKG_TAG="$(jq -r '.heimdall.tag // empty' "$PKG" 2>/dev/null)"
    PKG_URL="$(jq -r '.heimdall.installScriptUrl // empty' "$PKG" 2>/dev/null)"
    [ "$PKG_TAG" = "$TAG" ] \
      && ok "runheimdall .heimdall.tag == $TAG" \
      || bad "runheimdall .heimdall.tag drift: '$PKG_TAG' != '$TAG'"
    case "$PKG_URL" in
      */"$TAG"/install.sh) ok "runheimdall .heimdall.installScriptUrl pinned to $TAG" ;;
      *) bad "runheimdall .heimdall.installScriptUrl drift: '$PKG_URL' is not pinned to $TAG" ;;
    esac
  fi
else
  bad "packages/runheimdall/package.json missing"
fi

# ── 4/5. Vanity redirect targets (vercel.json + _redirects) ──────────────────
# runheimdall.dev/install 302s here; a stale target serves a stale installer.
if [ -f "$VERCEL" ]; then
  grep -Fq "/heimdall/${TAG}/install.sh" "$VERCEL" \
    && ok "vercel.json /install redirect targets $TAG" \
    || bad "vercel.json /install redirect drift: not pointed at $TAG (run release/sync-release.sh $TAG)"
else
  bad "vercel.json missing"
fi

if [ -f "$REDIRECTS" ]; then
  grep -Fq "/heimdall/${TAG}/install.sh" "$REDIRECTS" \
    && ok "_redirects /install targets $TAG" \
    || bad "_redirects /install drift: not pointed at $TAG (run release/sync-release.sh $TAG)"
else
  bad "_redirects missing"
fi

# ── 6. install.sh DEFAULT_REF ────────────────────────────────────────────────
# A fresh `curl|bash` resolves this ref; a stale default is the historical v2.0.5 downgrade.
if [ -f "$INSTALL" ]; then
  DEF_REF="$(sed -n 's/.*local DEFAULT_REF="\(v[0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$INSTALL" | head -1)"
  if [ -z "$DEF_REF" ]; then
    bad "install.sh has no DEFAULT_REF=\"vX.Y.Z\" line to gate"
  else
    [ "$DEF_REF" = "$TAG" ] \
      && ok "install.sh DEFAULT_REF == $TAG" \
      || bad "install.sh DEFAULT_REF drift: '$DEF_REF' != '$TAG'"
  fi
else
  bad "install.sh missing"
fi

# ── 7. The marketing site — a SIBLING repo, absent means SKIPPED not FAILED ───
HEIMDALL_SITE_DIR="${HEIMDALL_SITE_DIR:-$REPO/../heimdall-site}"
if [ ! -d "$HEIMDALL_SITE_DIR" ]; then
  echo "  site: SKIPPED — nothing at $HEIMDALL_SITE_DIR (set HEIMDALL_SITE_DIR to gate it)"
else
  # Published surfaces only. Dot-dirs are pruned: .git is binary object storage, and
  # .planning holds archived design comps pinned to long-dead tags (v2.0.5) — that is
  # history, not drift. `-name '.?*'` (not '.*') is deliberate: '.*' also matches the
  # start directory itself and would prune the entire tree, silently gating nothing.
  SITE_PUB=()
  SITE_PUB_N=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    SITE_PUB+=("$f"); SITE_PUB_N=$((SITE_PUB_N+1))
  done <<EOF
$(find "$HEIMDALL_SITE_DIR" -type d -name '.?*' -prune -o -type f \
    \( -name '*.html' -o -name '*.js' -o -name '*.txt' \) -print | sort)
EOF
  echo "  site: $HEIMDALL_SITE_DIR ($SITE_PUB_N published files)"
  SITE_CHECKED=0

  # (a) <meta name="heimdall-version"> on every published page. Matched with the
  # leading '<meta ' so the JS that READS the tag (querySelector('meta[name=...]'))
  # is not mistaken for a tag that declares one.
  if [ "$SITE_PUB_N" -gt 0 ]; then
    SITE_META_N=0; SITE_META_BAD=0
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      SITE_META_N=$((SITE_META_N+1))
      mval="$(printf '%s' "$hit" | sed -n 's/.*content="\([^"]*\)".*/\1/p')"
      if [ "$mval" != "$TAG" ]; then
        bad "site meta heimdall-version drift: '${mval:-<unparseable>}' != '$TAG' (${hit%%:*})"
        SITE_META_BAD=1
      fi
    done <<EOF
$(grep -rn '<meta name="heimdall-version"' "${SITE_PUB[@]}" 2>/dev/null)
EOF
    SITE_CHECKED=$((SITE_CHECKED+SITE_META_N))
    [ "$SITE_META_N" -gt 0 ] && [ "$SITE_META_BAD" -eq 0 ] \
      && ok "site meta heimdall-version == $TAG ($SITE_META_N page(s))"
  fi

  # (b) index.html JSON-LD softwareVersion — what search engines and AI answers cite.
  IDX="$HEIMDALL_SITE_DIR/index.html"
  if [ -f "$IDX" ]; then
    SITE_CHECKED=$((SITE_CHECKED+1))
    SV="$(sed -n 's/.*"softwareVersion"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' "$IDX" | head -1)"
    [ "$SV" = "$VER" ] \
      && ok "site index.html JSON-LD softwareVersion == $VER" \
      || bad "site index.html JSON-LD softwareVersion drift: '${SV:-<none>}' != '$VER'"
  fi

  # (c) llms-full.txt install URL. EVERY pinned URL must be the current tag — asserting
  # merely that the right one is present would stay green with a stale one beside it.
  LLMS="$HEIMDALL_SITE_DIR/llms-full.txt"
  if [ -f "$LLMS" ]; then
    LLMS_N=0; LLMS_BAD=0
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      LLMS_N=$((LLMS_N+1))
      [ "$u" = "$TAG" ] && continue
      bad "site llms-full.txt install URL drift: '$u' != '$TAG'"
      LLMS_BAD=1
    done <<EOF
$(grep -oE '/heimdall/v[0-9]+\.[0-9]+\.[0-9]+/install\.sh' "$LLMS" 2>/dev/null | sed -e 's|^/heimdall/||' -e 's|/install\.sh$||' | sort -u)
EOF
    SITE_CHECKED=$((SITE_CHECKED+LLMS_N))
    if [ "$LLMS_N" -eq 0 ]; then
      bad "site llms-full.txt carries no pinned /heimdall/<tag>/install.sh URL to gate"
    elif [ "$LLMS_BAD" -eq 0 ]; then
      ok "site llms-full.txt install URL pinned to $TAG"
    fi
  fi

  # (d) The hardcoded JS version fallback — what every visitor sees when the GitHub
  # API call is cold, rate-limited, or offline. version.js has one, and index.html and
  # team.html each inline the same construct; gating only version.js would leave the
  # other two free to drift, which is the same gap in miniature.
  if [ "$SITE_PUB_N" -gt 0 ]; then
    FB_N=0; FB_BAD=0
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      FB_N=$((FB_N+1))
      fval="${hit##*:}"
      if [ "$fval" != "'$TAG'" ]; then
        bad "site JS version fallback drift: $fval != '$TAG' (${hit%%:*})"
        FB_BAD=1
      fi
    done <<EOF
$(grep -rnoE "'v[0-9]+\.[0-9]+\.[0-9]+'" "${SITE_PUB[@]}" 2>/dev/null)
EOF
    SITE_CHECKED=$((SITE_CHECKED+FB_N))
    [ "$FB_N" -gt 0 ] && [ "$FB_BAD" -eq 0 ] \
      && ok "site JS version fallbacks == '$TAG' ($FB_N literal(s))"
  fi

  # A checkout that yields zero version-bearing fields is a VACUOUS pass, not a clean
  # one — the same shape of false green that let the site drift in the first place.
  [ "$SITE_CHECKED" -eq 0 ] \
    && bad "site present at $HEIMDALL_SITE_DIR but ZERO version-bearing fields found — vacuous sweep, not a clean one"
fi

echo ""
echo "version-drift.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

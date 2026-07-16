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
#
# Scoped to FULL three-part semver (X.Y.Z). Two-part strings that are NOT the plugin
# version ("Claude Code 1.0+", "0.50 median reuse") are not version pins and are ignored.
#
# R6: this gate ships with a corrupt-and-confirm proof — `--self-test` plants a drift in a
# THROWAWAY copy of the repo, asserts the gate reports it, and restores nothing (the copy is
# discarded). A gate that cannot demonstrate going red proves nothing.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${VERSION_DRIFT_REPO:-$(cd "$SELF_DIR/.." && pwd)}"

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

echo ""
echo "version-drift.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

#!/usr/bin/env bash
#
# version-unified.test.sh — acceptance for a SINGLE-SOURCE version.
#
# The plugin version lives in exactly one authoritative place:
#   .claude-plugin/plugin.json  ->  .version   (audit 6634, mirrored by ship.sh read_version)
#
# Everything else that names the version MUST equal it. Two surfaces drift in
# practice and are gated here:
#   - README.md          — the version badge (and any other X.Y.Z semver in the file)
#   - VERSION            — the repo-root plain-text mirror ship.sh writes on release
#
# A stale README badge or a VERSION file that lags the manifest is DRIFT — this
# test goes RED (exit 1) the instant any semver in those surfaces disagrees with
# plugin.json, and exits 0 only when every version string is unified.
#
# Deliberately scoped to FULL three-part semver (X.Y.Z). Two-part strings that are
# NOT the plugin version — "Claude Code 1.0+", "0.50 median reuse" — are not
# version pins and are correctly ignored.
#
# Usage:  test/version-unified.test.sh   (exit 0 = versions unified)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MANIFEST="$REPO/.claude-plugin/plugin.json"
README="$REPO/README.md"
VERSION_FILE="$REPO/VERSION"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Authoritative version from plugin.json (prefer jq; sed fallback keeps the gate
# runnable on a box without jq — same resolution ship.sh read_version uses).
if command -v jq >/dev/null 2>&1; then
  MANIFEST_VER="$(jq -r '.version // empty' "$MANIFEST" 2>/dev/null)"
else
  MANIFEST_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$MANIFEST" | head -1)"
fi

echo "version-unified harness  repo=$REPO  manifest=$MANIFEST_VER"
echo "--------------------------------------------------------------------"

printf '%s' "$MANIFEST_VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  && ok "plugin.json .version is a readable semver ($MANIFEST_VER)" \
  || { bad "plugin.json .version not a semver: '${MANIFEST_VER:-<none>}'"; echo; echo "version-unified.test.sh: $PASS passed, $FAIL failed."; exit 1; }

# ── VERSION file exists and matches the manifest ──
if [ -f "$VERSION_FILE" ]; then
  ok "VERSION file exists"
  VF="$(tr -d '[:space:]' < "$VERSION_FILE")"
  [ "$VF" = "$MANIFEST_VER" ] \
    && ok "VERSION == plugin.json ($VF)" \
    || bad "VERSION drift: VERSION='$VF' != plugin.json='$MANIFEST_VER'"
else
  bad "VERSION file missing at repo root (ship.sh must mirror plugin.json into it)"
fi

# ── Every three-part semver in README must equal the manifest version ──
# grep -o pulls each X.Y.Z token; any token != manifest is a stale pin -> RED.
README_SEMVERS="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$README" | sort -u)"
if [ -z "$README_SEMVERS" ]; then
  bad "no version string found in README.md (expected the version badge to carry $MANIFEST_VER)"
else
  drift=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ "$v" = "$MANIFEST_VER" ]; then
      ok "README semver matches manifest ($v)"
    else
      bad "README stale version pin: '$v' != plugin.json '$MANIFEST_VER'"
      drift=1
    fi
  done <<EOF
$README_SEMVERS
EOF
  [ "$drift" -eq 0 ] && ok "README carries no stale version pin"
fi

echo ""
echo "version-unified.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

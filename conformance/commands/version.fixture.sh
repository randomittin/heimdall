#!/usr/bin/env bash
# PARITY-ROW: Command (none at tag) -> improved(new) `heimdall version`/`-v`
# ASSERT: superx had NO version subcommand (baseline = absent). Heimdall ADDS one:
#   `heimdall version` and `heimdall -v` both exit 0 and print a version string
#   that matches the DYNAMICALLY RESOLVED version. "Improved" means strictly more
#   than the baseline, so presence + correctness is the bar.
#
# The version subcommand resolves via bin/heimdall's heimdall_version(): the
# nearest git tag FIRST, falling back to the manifest .version ONLY when git is
# unavailable. So the assertion below mirrors that exact order — it must NOT
# pin to the manifest alone, because the manifest is a fallback (it shipped a
# stale 1.1.0 while the real release was v2.0.x; pinning to it re-introduced the
# very drift this subcommand fix removes).
ROW="cmd:version"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
cd "$PLUGIN_ROOT" || { bad "cannot cd"; finish; }

# Resolve the EXPECTED version the same way heimdall_version() does:
#   1. nearest git tag (git describe --tags --abbrev=0), normalised to X.Y.Z
#   2. fall back to the manifest .version if the tree has no tags
EXPECT_VER="$(git -C "$PLUGIN_ROOT" describe --tags --abbrev=0 2>/dev/null \
  | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
if [ -z "$EXPECT_VER" ]; then
  EXPECT_VER="$(jq -r '.version // empty' .claude-plugin/plugin.json 2>/dev/null)"
fi

for form in "version" "-v"; do
  OUT="$("$BIN/heimdall" $form 2>&1)"; CODE=$?
  assert_exit 0 "$CODE" "heimdall $form exits 0"
  assert_grep 'heimdall.*v?[0-9]+\.[0-9]+\.[0-9]+' "$OUT" "heimdall $form prints a semver version"
  assert_contains "$OUT" "$EXPECT_VER" "heimdall $form matches resolved version $EXPECT_VER"
  # Permanent anti-drift gate: the subcommand must NEVER report the old hardcoded
  # 1.1.0 once the release has moved past it (it read plugin.json directly and
  # lied for the entire v2.0.x line). If git resolves to a different tag, seeing
  # 1.1.0 means the subcommand regressed back to parsing the stale manifest.
  if [ "$EXPECT_VER" != "1.1.0" ]; then
    if printf '%s' "$OUT" | grep -qE 'Heimdall v1\.1\.0([^0-9]|$)'; then
      bad "heimdall $form reports stale hardcoded 1.1.0 (expected $EXPECT_VER) — plugin.json drift regressed"
    else
      ok "heimdall $form does not report stale 1.1.0 (anti-drift gate)"
    fi
  fi
done
finish

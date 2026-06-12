#!/usr/bin/env bash
# PARITY-ROW: Command (none at tag) -> improved(new) `heimdall version`/`-v`
# ASSERT: superx had NO version subcommand (baseline = absent). Heimdall ADDS one:
#   `heimdall version` and `heimdall -v` both exit 0 and print a version string
#   that matches the manifest version. "Improved" means strictly more than the
#   baseline, so presence + correctness is the bar.
ROW="cmd:version"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
cd "$PLUGIN_ROOT" || { bad "cannot cd"; finish; }

MANIFEST_VER="$(jq -r '.version' .claude-plugin/plugin.json 2>/dev/null)"
for form in "version" "-v"; do
  OUT="$("$BIN/heimdall" $form 2>&1)"; CODE=$?
  assert_exit 0 "$CODE" "heimdall $form exits 0"
  assert_grep 'heimdall.*v?[0-9]+\.[0-9]+\.[0-9]+' "$OUT" "heimdall $form prints a semver version"
  assert_contains "$OUT" "$MANIFEST_VER" "heimdall $form matches manifest version $MANIFEST_VER"
done
finish

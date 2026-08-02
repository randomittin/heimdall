#!/usr/bin/env bash
# oracle-registry-integrity.test.sh — the oracle registry cannot silently rot.
#
# Two registry defects are invisible until someone gets burned by them, so this
# test converts both into a gate:
#
#   [1] NO PHANTOM GATES. Every `.oracles[*].gate_command` must name a command
#       that actually exists on disk. A registry entry that resolves a domain to
#       a nonexistent command is worse than one reporting the domain as unknown:
#       `bin/oracle-select` happily prints the phantom path with exit 0, so the
#       failure only surfaces when the gate is finally invoked.
#   [2] NO STALE DOC TABLE. The "Registered oracles" table in README.md must
#       list exactly the registry's oracle ids — no missing rows, no phantom
#       rows — and each row's gate_type must match the registry. A table that
#       under-reports is how a reader concludes an oracle does not exist.
#   [3] FALSIFIABLE, not decorative. Both checks are re-run against deliberately
#       broken throwaway copies (a dropped table row, an inflated gate_type, a
#       phantom gate_command) and MUST go RED. A check that cannot fail proves
#       nothing.
#
# Every assertion reads the REAL registry/README — nothing is fabricated.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$TEST_DIR/.." && pwd)"
REGISTRY="$PLUGIN/evals/oracles/registry.json"
README="$PLUGIN/evals/oracles/README.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$(( fail + 1 )); }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
[ -r "$REGISTRY" ] || { echo "registry not readable: $REGISTRY" >&2; exit 2; }
[ -r "$README" ]   || { echo "README not readable: $README"     >&2; exit 2; }

# ── Extractors ───────────────────────────────────────────────────────────────

# "id<TAB>gate_type" per registry entry, sorted.
registry_pairs() {
  jq -r '.oracles | to_entries[] | "\(.key)\t\(.value.gate_type)"' "$1" | sort
}

# "id<TAB>gate_type" per row of the README "Registered oracles" table, sorted.
readme_pairs() {
  awk '
    /^## Registered oracles/ { inseg = 1; next }
    inseg && /^## /          { inseg = 0 }
    inseg && /^\|/ {
      if ($0 ~ /^\|[[:space:]]*id[[:space:]]*\|/) next   # header row
      if ($0 ~ /^\|[-: |]+\|[[:space:]]*$/)       next   # separator row
      n = split($0, c, "|")
      if (n < 3) next
      id = c[2]; gt = c[3]
      gsub(/`/, "", id); gsub(/^[ \t]+|[ \t]+$/, "", id)
      gsub(/`/, "", gt); gsub(/^[ \t]+|[ \t]+$/, "", gt)
      if (id != "") print id "\t" gt
    }
  ' "$1" | sort
}

# Report phantom gate_commands (missing/empty command, or first token not on disk).
# Prints one "id: reason" line per offender; silent + exit 0 when all resolve.
phantom_gates() {
  local reg="$1" root="$2" id cmd tok
  while IFS=$'\t' read -r id cmd; do
    if [ -z "$cmd" ]; then
      printf '%s: gate_command missing or empty\n' "$id"
      continue
    fi
    tok="${cmd%% *}"
    [ -e "$root/$tok" ] || printf '%s: gate_command points at nonexistent path: %s\n' "$id" "$tok"
  done < <(jq -r '.oracles | to_entries[] | "\(.key)\t\(.value.gate_command // "")"' "$reg")
}

# ── [1] No phantom gate_commands ─────────────────────────────────────────────

echo "[1] every registered gate_command exists on disk (no phantom gates)"
phantoms="$TMP/phantoms.txt"
phantom_gates "$REGISTRY" "$PLUGIN" >"$phantoms"
if [ ! -s "$phantoms" ]; then
  ok "all $(jq -r '.oracles | length' "$REGISTRY") registered gate_commands resolve to a real path"
else
  while IFS= read -r line; do bad "phantom gate_command -> $line"; done <"$phantoms"
fi

# ── [2] README table matches the registry ────────────────────────────────────

echo "[2] README 'Registered oracles' table matches the registry exactly"
registry_pairs "$REGISTRY" >"$TMP/reg.tsv"
readme_pairs   "$README"   >"$TMP/doc.tsv"

cut -f1 "$TMP/reg.tsv" >"$TMP/reg.ids"
cut -f1 "$TMP/doc.tsv" >"$TMP/doc.ids"

missing="$(comm -23 "$TMP/reg.ids" "$TMP/doc.ids")"
extra="$(comm -13 "$TMP/reg.ids" "$TMP/doc.ids")"

if [ -z "$missing" ]; then
  ok "no registered oracle is missing from the README table"
else
  while IFS= read -r m; do bad "registered but undocumented (missing README row): $m"; done <<<"$missing"
fi

if [ -z "$extra" ]; then
  ok "no README row names an unregistered oracle"
else
  while IFS= read -r e; do bad "documented but not in registry (phantom README row): $e"; done <<<"$extra"
fi

if diff -u "$TMP/reg.tsv" "$TMP/doc.tsv" >"$TMP/pairs.diff" 2>&1; then
  ok "every README row's gate_type matches the registry (no inflated/stale types)"
else
  bad "README table gate_type disagrees with registry"
  cat "$TMP/pairs.diff"
fi

# ── [3] Falsifiability: the checks MUST be able to go RED ────────────────────

echo "[3] falsifiability — each check goes RED on a deliberately broken copy"

# 3a. Drop a README table row -> the missing-row check must fire.
drop_id="$(head -1 "$TMP/reg.ids")"
sed "/^| \`${drop_id}\` |/d" "$README" >"$TMP/readme-dropped.md"
readme_pairs "$TMP/readme-dropped.md" >"$TMP/doc-dropped.ids.tsv"
cut -f1 "$TMP/doc-dropped.ids.tsv" >"$TMP/doc-dropped.ids"
if [ -n "$(comm -23 "$TMP/reg.ids" "$TMP/doc-dropped.ids")" ]; then
  ok "dropping README row '$drop_id' is DETECTED (check is not vacuous)"
else
  bad "dropping README row '$drop_id' went UNDETECTED — table check is vacuous"
fi

# 3b. Inflate a README gate_type -> the gate_type diff must fire.
sed "s/^| \`${drop_id}\` | [a-z-]* |/| \`${drop_id}\` | differential |/" "$README" >"$TMP/readme-inflated.md"
readme_pairs "$TMP/readme-inflated.md" >"$TMP/doc-inflated.tsv"
if diff -q "$TMP/reg.tsv" "$TMP/doc-inflated.tsv" >/dev/null 2>&1; then
  bad "inflating '$drop_id' gate_type to 'differential' went UNDETECTED — type check is vacuous"
else
  ok "inflating '$drop_id' gate_type to 'differential' is DETECTED"
fi

# 3c. Inject a phantom gate_command -> the phantom check must fire.
jq '.oracles["phantom-probe"] = {"gate_command": "evals/oracles/phantom-probe/gate.sh --nope"}' \
  "$REGISTRY" >"$TMP/registry-phantom.json"
phantom_gates "$TMP/registry-phantom.json" "$PLUGIN" >"$TMP/phantom-probe.txt"
if grep -q '^phantom-probe: gate_command points at nonexistent path' "$TMP/phantom-probe.txt"; then
  ok "an entry whose gate.sh does not exist is DETECTED (the raytracer-calib class of defect)"
else
  bad "phantom gate_command went UNDETECTED — phantom check is vacuous"
fi

# 3d. A command-less entry -> also caught (absent gate_command is not a loophole).
jq '.oracles["commandless-probe"] = {"gate_type": "verdict"}' "$REGISTRY" >"$TMP/registry-commandless.json"
phantom_gates "$TMP/registry-commandless.json" "$PLUGIN" >"$TMP/commandless.txt"
if grep -q '^commandless-probe: gate_command missing or empty' "$TMP/commandless.txt"; then
  ok "an entry with no gate_command at all is DETECTED"
else
  bad "missing gate_command went UNDETECTED — phantom check has a loophole"
fi

# ── [4] Registry stays machine-readable + schema-complete ─────────────────────

echo "[4] registry is valid JSON and every entry carries the six required fields"
if jq -e type "$REGISTRY" >/dev/null 2>&1; then
  ok "registry.json parses as valid JSON"
else
  bad "registry.json is not valid JSON"
fi

incomplete="$(jq -r '
  .oracles | to_entries[]
  | select(
      (.value.gate_type    | type != "string") or
      (.value.description  | type != "string") or
      (.value.domain_signals | type != "array") or
      (.value.assets       | type != "array")  or
      (.value.gate_command | type != "string") or
      (.value.reference    | type != "object")
    )
  | .key' "$REGISTRY")"
if [ -z "$incomplete" ]; then
  ok "all entries carry gate_type/description/domain_signals/assets/gate_command/reference"
else
  while IFS= read -r i; do bad "entry missing a required schema field: $i"; done <<<"$incomplete"
fi

unranked="$(jq -r '
  .gate_type_ranking as $r
  | .oracles | to_entries[] | select(.value.gate_type as $g | ($r | index($g)) == null) | .key' "$REGISTRY")"
if [ -z "$unranked" ]; then
  ok "every gate_type is a member of gate_type_ranking"
else
  while IFS= read -r u; do bad "gate_type not in gate_type_ranking: $u"; done <<<"$unranked"
fi

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

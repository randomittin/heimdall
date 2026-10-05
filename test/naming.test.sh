#!/usr/bin/env bash
#
# naming.test.sh — NAMING.md is true against the code.
#
#   bash test/naming.test.sh               # the gate
#   bash test/naming.test.sh --self-test   # corrupt-and-confirm proof
#
# NAMING.md maps every codename to an `hmd <subcommand>`, a `bin/<file>`, or "internal". A map nobody
# checks is prose that rots: rename a subcommand in bin/heimdall and NAMING.md keeps pointing at a name
# that no longer exists. This gate reads the table between the naming-table markers and asserts:
#   1. every `hmd <sub>` token is a real dispatch arm of bin/heimdall;
#   2. every `bin/<file>` token is a real executable file;
#   3. every name the plan lists (runhmd, hmd, Heimdall, rr, Bifröst, dream, watchmen, designmatch,
#      bloat gates, presence) is accounted for in NAMING.md;
#   4. a row in the deprecated-aliases table is only allowed when bin/heimdall really prints
#      `deprecated: use hmd` — the notice NAMING.md promises;
#   5. the table is not empty (an empty table would pass 1-2 for free).
#
# --self-test plants each defect in a throwaway copy (NAMING.md + bin/) and requires the gate to go RED
# for the right reason, plus an INVERTED mutant: an untouched copy must stay GREEN.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${NAMING_REPO:-$(cd "$SELF_DIR/.." && pwd)}"

PLAN_NAMES="runhmd hmd Heimdall rr Bifröst dream watchmen designmatch bloat_gates presence"

# check <root> — prints PASS/FAIL lines, returns non-zero when anything failed.
check() {
  local root="$1" naming disp rows row name reach tok sub path fails=0 n=0 pn arows
  naming="$root/NAMING.md"; disp="$root/bin/heimdall"
  [ -f "$naming" ] || { echo "  FAIL NAMING.md is missing"; return 1; }
  [ -f "$disp" ]   || { echo "  FAIL bin/heimdall is missing"; return 1; }

  rows="$(awk '/naming-table:begin/{f=1;next} /naming-table:end/{f=0} f && /^\|/' "$naming" \
          | grep -vE '^\|[ -]*(\|[ -]*)+$' | grep -viE '^\| *Name *\|' || true)"
  if [ -z "$rows" ]; then echo "  FAIL the naming table has no rows (vacuous)"; return 1; fi

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    n=$((n+1))
    name="$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}')"
    reach="$(printf '%s' "$row" | awk -F'|' '{print $4}')"
    for tok in $(printf '%s' "$reach" | grep -oE '`[^`]+`' | tr -d '`' | tr ' ' '_'); do
      case "$tok" in
        hmd_*)
          sub="${tok#hmd_}"
          if grep -qE "^  ([a-z0-9_-]+\|)*${sub}(\|[a-z0-9_-]+)*\)" "$disp"; then
            echo "  PASS '$name': \`hmd $sub\` is a dispatch arm of bin/heimdall"
          else
            echo "  FAIL '$name': \`hmd $sub\` is NOT a dispatch arm of bin/heimdall"; fails=$((fails+1))
          fi ;;
        bin/*)
          path="$root/$tok"
          if [ -f "$path" ] && [ -x "$path" ]; then
            echo "  PASS '$name': $tok exists and is executable"
          else
            echo "  FAIL '$name': $tok does not exist or is not executable"; fails=$((fails+1))
          fi ;;
      esac
    done
  done <<EOF
$rows
EOF
  echo "  rows checked: $n"

  for pn in $PLAN_NAMES; do
    pn="${pn//_/ }"
    if grep -qiF -- "$pn" "$naming"; then
      echo "  PASS plan name '$pn' is accounted for"
    else
      echo "  FAIL plan name '$pn' is missing from NAMING.md"; fails=$((fails+1))
    fi
  done

  arows="$(awk '/deprecated-aliases:begin/{f=1;next} /deprecated-aliases:end/{f=0} f && /^\|/' "$naming" \
           | grep -vE '^\|[ -]*(\|[ -]*)+$' | grep -viE '^\| *Old *\|' || true)"
  if [ -n "$arows" ]; then
    if grep -qF 'deprecated: use hmd' "$disp"; then
      echo "  PASS deprecated aliases are listed and bin/heimdall prints the notice"
    else
      echo "  FAIL NAMING.md lists deprecated aliases but bin/heimdall never prints 'deprecated: use hmd <new>'"; fails=$((fails+1))
    fi
  else
    echo "  PASS no alias is claimed deprecated (none promised, none required in code)"
  fi
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  fresh() { rm -rf "$TMP/root"; mkdir -p "$TMP/root"; cp -R "$REPO/bin" "$TMP/root/bin"; cp "$REPO/NAMING.md" "$TMP/root/NAMING.md"; }
  assert_red() {  # <label> <expected-substring>
    local out
    if out="$(check "$TMP/root" 2>&1)"; then echo "  ✗ SELF-TEST FAILED: gate stayed GREEN with $1" >&2; exit 1; fi
    case "$out" in *"$2"*) echo "  ✓ RED on $1" ;; *) echo "  ✗ SELF-TEST FAILED: RED for the wrong reason with $1 (wanted: $2)" >&2; printf '%s\n' "$out" >&2; exit 1 ;; esac
  }
  echo "naming --self-test: asserting the gate goes RED on planted defects"

  fresh
  if ! check "$TMP/root" >/dev/null 2>&1; then echo "  ✗ SELF-TEST FAILED: gate is RED on an untouched copy" >&2; exit 1; fi
  echo "  ✓ GREEN on an untouched copy (the mutants below are attributable)"

  fresh; sed 's/^  designmatch)/  designmatch-gone)/' "$REPO/bin/heimdall" > "$TMP/root/bin/heimdall"
  assert_red "the designmatch arm renamed away" "\`hmd designmatch\` is NOT a dispatch arm"

  fresh; rm -f "$TMP/root/bin/heimdall-debloat"
  assert_red "bin/heimdall-debloat deleted" "bin/heimdall-debloat does not exist"

  fresh; grep -v '^| Bifröst' "$REPO/NAMING.md" | sed 's/Bifröst/Bifrost-removed/g' > "$TMP/root/NAMING.md"
  assert_red "the Bifröst row dropped" "plan name 'Bifröst' is missing"

  fresh; awk '{print} /^\|---\|---\|---\|$/ && ++s==3 {print "| oldcmd | hmd newcmd | next release |"}' "$REPO/NAMING.md" > "$TMP/root/NAMING.md"
  assert_red "a deprecated alias promised with no notice in bin/heimdall" "never prints 'deprecated: use hmd <new>'"

  fresh; awk '/naming-table:begin/{print; f=1; next} /naming-table:end/{f=0} !f{print}' "$REPO/NAMING.md" > "$TMP/root/NAMING.md"
  assert_red "the naming table emptied" "the naming table has no rows"

  echo "naming --self-test: PASS"
  exit 0
fi

echo "naming harness  repo=$REPO"
echo "--------------------------------------------------------------------"
if check "$REPO"; then
  echo "--------------------------------------------------------------------"
  echo "naming.test.sh: PASS"
  exit 0
fi
echo "--------------------------------------------------------------------"
echo "naming.test.sh: FAIL" >&2
exit 1

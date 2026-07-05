#!/usr/bin/env bash
# Link-checker for the documentation brain-index tree.
# Extracts every markdown link target from the index files and asserts each
# relative target resolves to a real file or directory (test -e), so no index
# ever points at a moved/renamed/deleted doc.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

INDEXES=(
  "docs/INDEX.md"
  "docs/specs/INDEX.md"
  "docs/analysis/INDEX.md"
  "docs/archive/INDEX.md"
  "deploy/cloud-run/INDEX.md"
)

pass=0
fail=0

check_index() {
  local index="$1"
  local dir
  dir="$(dirname "$index")"
  if [ ! -f "$index" ]; then
    echo "  FAIL missing index: $index"
    fail=$((fail + 1))
    return
  fi
  # Extract link targets: the (...) part of ](...) markdown links.
  # grep -oE the whole ](target) then strip the ]( prefix and ) suffix.
  local target stripped resolved
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    stripped="${target#](}"
    stripped="${stripped%)}"
    # Skip external links and pure anchors.
    case "$stripped" in
      http://*|https://*|mailto:*|\#*) continue ;;
    esac
    # Strip any #anchor suffix.
    stripped="${stripped%%#*}"
    [ -z "$stripped" ] && continue
    # Absolute (repo-rooted) vs relative-to-index-dir.
    case "$stripped" in
      /*) resolved="$ROOT$stripped" ;;
      *)  resolved="$dir/$stripped" ;;
    esac
    if [ -e "$resolved" ]; then
      pass=$((pass + 1))
    else
      echo "  FAIL $index -> $stripped (resolved: $resolved)"
      fail=$((fail + 1))
    fi
  done < <(grep -oE '\]\([^)]+\)' "$index")
}

echo "docs-index link check:"
for idx in "${INDEXES[@]}"; do
  check_index "$idx"
done

echo "──────────"
echo "docs-index-links: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

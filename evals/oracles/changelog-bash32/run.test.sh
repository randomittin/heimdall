#!/usr/bin/env bash
# run.test.sh — behavioral gate for bin/generate-changelog under bash 3.2.
#
# macOS ships bash 3.2.57 (no associative arrays). Finding #5: the original
# generate-changelog used `declare -A` and assoc-array syntax that aborts under
# 3.2 with `declare: -A: invalid option`. This gate asserts the rewrite:
#   - parses + runs under the running bash (3.2 on this machine), exit 0
#   - contains NO bash>=4-only constructs (declare -A / mapfile / case-mod)
#   - actually groups conventional commits by type into Keep-a-Changelog sections
#   - does NOT leak the bash builtin $GROUPS array (the rename-or-die regression:
#     an indexed array literally named GROUPS yields user GIDs, e.g. bare "20")
#   - --append inserts before the first "## [" heading without awk errors
# Run it before trusting the script green; this is the gate RJ specified.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$DIR/../../.." && pwd)"
SCRIPT="${GENERATE_CHANGELOG:-$PLUGIN_DIR/bin/generate-changelog}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$(( fail + 1 )); }

# Build a self-contained git fixture with known conventional-commit subjects so
# the gate does not depend on the live repo history.
FIX="$TMP/repo"
mkdir -p "$FIX"
(
  cd "$FIX"
  git init -q
  git config user.email test@heimdall.dev
  git config user.name test
  # Root commit is a no-op anchor: generate-changelog uses SINCE..HEAD, which
  # EXCLUDES SINCE itself, so the anchor must not be a real changelog entry.
  git commit -q --allow-empty -m "init"
  i=0
  for subj in \
    "feat(api): add login endpoint" \
    "fix(auth): handle empty token" \
    "docs: update README" \
    "refactor(core): split module" \
    "test: add unit tests" \
    "chore(ci): bump actions" \
    "perf(db): cache queries" \
    "build: tweak webpack config" \
    "totally non-conventional subject"
  do
    i=$(( i + 1 ))
    git commit -q --allow-empty -m "$subj"
  done
) >/dev/null 2>&1
FIRST=$(cd "$FIX" && git rev-list --max-parents=0 HEAD)

echo "[1] bin/generate-changelog parses (bash -n) and is non-empty"
if [ -s "$SCRIPT" ] && bash -n "$SCRIPT" 2>/dev/null; then ok "script parses"; else bad "script missing or syntax error"; fi

echo "[2] no bash>=4-only constructs (declare -A / mapfile / readarray / case-mod)"
if grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)' "$SCRIPT" >/dev/null 2>&1; then
  bad "bash>=4-ism present"; grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)' "$SCRIPT"
else
  ok "no declare -A / mapfile / readarray / \${v,,}/\${v^^}"
fi

echo "[3] runs under the running bash (exit 0, clean stderr)"
out="$TMP/out.md"; err="$TMP/err.txt"; rc=0
( cd "$FIX" && bash "$SCRIPT" --since "$FIRST" --version v1.0 ) >"$out" 2>"$err" || rc=$?
if [ "$rc" -eq 0 ]; then ok "exit 0"; else bad "exit $rc"; fi
if [ -s "$err" ]; then bad "stderr not empty: $(cat "$err")"; else ok "stderr empty (no 'declare: -A: invalid option')"; fi

echo "[4] commits grouped by conventional type into Keep-a-Changelog sections"
check_line() { if grep -qF -e "$1" "$out"; then ok "$2"; else bad "$2 (missing: $1)"; cat "$out"; fi; }
check_line "## [v1.0] - "                      "version heading present"
check_line "### Added"                          "feat -> Added section"
check_line "- **api**: add login endpoint"      "feat scope+msg under Added"
check_line "### Fixed"                           "fix -> Fixed section"
check_line "- **auth**: handle empty token"      "fix entry"
check_line "### Documentation"                   "docs -> Documentation section"
check_line "### Changed"                          "refactor -> Changed section"
check_line "### Tests"                            "test -> Tests section"
check_line "### Maintenance"                      "chore -> Maintenance section"
check_line "### Performance"                      "perf -> Performance section"
check_line "### Other"                            "unknown/non-conventional -> Other section"
check_line "- **db**: cache queries"             "perf entry"

echo "[5] unknown type (build:) + non-conventional land in Other"
# Both lines must appear under Other and NOT mint their own ### sections.
if grep -qiE '^### Build' "$out"; then bad "minted a bogus ### Build section"; else ok "no bogus section for unknown 'build:' type"; fi
if grep -qF -e "- totally non-conventional subject" "$out"; then ok "non-conventional subject captured in Other"; else bad "non-conventional subject dropped"; fi
if grep -qF -e "- **build**: tweak webpack config" "$out" || grep -qF -e "- tweak webpack config" "$out"; then ok "unknown 'build:' type captured"; else bad "unknown 'build:' type dropped"; fi

echo "[6] REGRESSION: no \$GROUPS builtin leak (no bare-number-only lines)"
# An indexed array named GROUPS collides with bash's builtin GIDs array; the
# symptom was section bodies printing bare GIDs like "20". Assert no such line.
if grep -nE '^[0-9]+$' "$out" >/dev/null 2>&1; then
  bad "bare numeric line(s) present — GROUPS builtin leaked"; grep -nE '^[0-9]+$' "$out"
else
  ok "no bare numeric lines (GROUPS builtin not leaked)"
fi

echo "[7] --append inserts before the first '## [' heading, no awk errors"
CL="$FIX/CHANGELOG.md"
printf '# Changelog\n\n## [0.1.0] - 2026-01-01\n\n### Added\n- old entry\n' > "$CL"
aerr="$TMP/aerr.txt"; arc=0
( cd "$FIX" && bash "$SCRIPT" --since "$FIRST" --version v2.0 --append ) >/dev/null 2>"$aerr" || arc=$?
if [ "$arc" -eq 0 ] && [ ! -s "$aerr" ]; then ok "--append exit 0, no stderr (no BSD-awk newline error)"; else bad "--append rc=$arc stderr=$(cat "$aerr")"; fi
# New v2.0 block must appear BEFORE the pre-existing 0.1.0 block, old content kept.
nv=$(grep -n '## \[v2.0\]' "$CL" | head -1 | cut -d: -f1 || true)
ov=$(grep -n '## \[0.1.0\]' "$CL" | head -1 | cut -d: -f1 || true)
if [ -n "$nv" ] && [ -n "$ov" ] && [ "$nv" -lt "$ov" ]; then ok "v2.0 inserted above existing 0.1.0"; else bad "append order wrong (v2.0@$nv 0.1.0@$ov)"; cat "$CL"; fi
if grep -qF -e "- old entry" "$CL"; then ok "pre-existing entry preserved"; else bad "append clobbered existing content"; fi

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

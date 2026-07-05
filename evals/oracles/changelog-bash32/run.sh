#!/usr/bin/env bash
# run.sh — changelog-bash32 oracle gate, structured-contract entry point (spec 2A).
#
# Grades a candidate implementation of bin/generate-changelog against the behavioral
# test harness in run.test.sh. The candidate must:
#   - parse under the running bash (bash -n), exit 0
#   - contain no bash>=4-only constructs (declare -A / mapfile / readarray)
#   - correctly group conventional commits by type into Keep-a-Changelog sections
#   - not leak the $GROUPS builtin array (bare GID lines in output)
#   - implement --append correctly (insert before the first ## [ heading)
#
# run.test.sh is the single source of behavioral truth; this file is the STRUCTURED
# CONTRACT SEAM that falsify invokes. It sets GENERATE_CHANGELOG=<input> so run.test.sh
# grades the candidate rather than the live bin/generate-changelog.
#
# report.json = {
#   "gate_id":          "changelog-bash32",
#   "status":           "pass" | "fail",
#   "first_divergence": { file, step, expected, actual } | null,
#   "metrics":          { tests_passed, tests_failed, feature },
#   "fix_hint":         string,
#   "haid":             string,
#   "wave":             string | null,
#   "ts":               string
# }
#
# Usage:
#   run.sh [--input <candidate-generate-changelog>] [--report <out>]
#
#   --input  <path>   Candidate implementation to grade (bash script). Default:
#                     fixtures/golden/generate-changelog.
#   --report <path>   Where to write report.json. Default: gate-dir report.json.
#
# Exit: 0 = pass, 1 = fail, 2 = usage/IO error (no valid report).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_ID="changelog-bash32"
HARNESS="$HERE/run.test.sh"

INPUT="$HERE/fixtures/golden/generate-changelog"
REPORT="$HERE/report.json"

die() { printf 'run.sh: %s\n' "$*" >&2; exit 2; }

command -v jq  >/dev/null 2>&1 || die "jq is required to emit report.json"
command -v git >/dev/null 2>&1 || die "git is required by the test harness"
[ -f "$HARNESS" ] || die "test harness missing: $HARNESS"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)  INPUT="${2:?--input needs a path}";   shift 2 ;;
    --report) REPORT="${2:?--report needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done

[ -f "$INPUT" ] || die "candidate implementation missing: $INPUT"

# Run the behavioral test harness against the candidate.
# run.test.sh reads GENERATE_CHANGELOG env to override the default script path.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HARNESS_OUT="$TMP/harness.out"
HARNESS_RC=0
GENERATE_CHANGELOG="$INPUT" bash "$HARNESS" >"$HARNESS_OUT" 2>&1 || HARNESS_RC=$?

# Parse pass/fail counts from the harness summary line ("RESULT: N passed, N failed").
tests_passed=0
tests_failed=0
result_line="$(grep '^RESULT:' "$HARNESS_OUT" 2>/dev/null | tail -1 || true)"
if [ -n "$result_line" ]; then
  p="$(printf '%s' "$result_line" | grep -oE '[0-9]+ passed' | grep -oE '^[0-9]+' || echo 0)"
  f="$(printf '%s' "$result_line" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+' || echo 0)"
  [ -n "$p" ] && tests_passed="$p"
  [ -n "$f" ] && tests_failed="$f"
fi

# Extract the first FAIL step for first_divergence.
first_fail_step=""
if [ "$HARNESS_RC" -ne 0 ]; then
  first_fail_line="$(grep '  FAIL:' "$HARNESS_OUT" | head -1 || true)"
  if [ -n "$first_fail_line" ]; then
    first_fail_step="$(printf '%s' "$first_fail_line" | sed -E 's/^[[:space:]]*FAIL:[[:space:]]*//')"
  else
    first_fail_step="test harness exited nonzero (rc=${HARNESS_RC})"
  fi
fi

HAID="${HEIMDALL_HAID:-haid:local}"
WAVE="${HEIMDALL_WAVE:-}"
TS="$(date -u +%FT%TZ)"
mkdir -p "$(dirname "$REPORT")"
tmp_report="$(mktemp)"

if [ "$HARNESS_RC" -eq 0 ]; then
  fix_hint="Candidate satisfies all changelog-bash32 behavioral checks: bash 3.2 compat, conventional commit grouping, no GROUPS builtin leak, --append mode correct."
  jq -n \
    --arg gate_id "$GATE_ID" \
    --argjson tests_passed "$tests_passed" --argjson tests_failed "$tests_failed" \
    --arg fix_hint "$fix_hint" --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
    '{gate_id:$gate_id, status:"pass", first_divergence:null,
      metrics:{tests_passed:$tests_passed, tests_failed:$tests_failed, feature:"generate-changelog"},
      fix_hint:$fix_hint, haid:$haid,
      wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$tmp_report"
else
  fix_hint="Candidate failed ${tests_failed} changelog-bash32 check(s). Ensure: no bash>=4 constructs (declare -A/mapfile/readarray), conventional commits grouped by type (feat->Added, fix->Fixed, refactor->Changed, perf->Performance, docs->Documentation, test->Tests, chore->Maintenance), no GROUPS builtin leak (bare GID lines), --append inserts before existing ## [ headings. First failure: ${first_fail_step}."
  jq -n \
    --arg gate_id "$GATE_ID" \
    --arg file "$GATE_ID" --arg step "$first_fail_step" \
    --arg expected "pass" --arg actual "fail" \
    --argjson tests_passed "$tests_passed" --argjson tests_failed "$tests_failed" \
    --arg fix_hint "$fix_hint" --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
    '{gate_id:$gate_id, status:"fail",
      first_divergence:{file:$file, step:$step, expected:$expected, actual:$actual},
      metrics:{tests_passed:$tests_passed, tests_failed:$tests_failed, feature:"generate-changelog"},
      fix_hint:$fix_hint, haid:$haid,
      wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$tmp_report"
fi
mv "$tmp_report" "$REPORT"

printf '%s: %s (%d passed, %d failed) -> %s\n' \
  "$GATE_ID" "$(jq -r .status "$REPORT")" "$tests_passed" "$tests_failed" "$REPORT" >&2

jq -e '.status == "pass"' "$REPORT" >/dev/null 2>&1 && exit 0 || exit 1

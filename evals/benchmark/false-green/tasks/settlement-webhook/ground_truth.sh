#!/usr/bin/env bash
# ground_truth.sh <candidate.mjs>: the ground truth for the settlement-webhook task.
# Exit 0 = pass, 1 = fail (a rule of INVARIANTS.md is violated), 2 = the check could not run.
# One JSON line on stdout. The candidate runs in a private temp dir under env -i with a wall-clock
# watchdog; this script is never copied into an agent workspace.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CAND="${1:-}"
TIMEOUT_S="${FG_GROUND_TRUTH_TIMEOUT_S:-180}"

err() { printf '{"result":"error","detail":"%s"}\n' "$1"; exit 2; }
[ -f "$CAND" ] || err "usage: ground_truth.sh <candidate.mjs>"
NODE_BIN="$(command -v node)" || err "node is required"
command -v perl >/dev/null 2>&1 || err "perl is required for the watchdog"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fg-ground-truth.XXXXXX")" || err "cannot create a temp dir"
trap 'rm -rf "$WORK"' EXIT
cp "$CAND" "$WORK/candidate.mjs"

(cd "$WORK" && perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" \
  env -i PATH="$PATH" HOME="$WORK" TMPDIR="$WORK" LANG=C \
  "$NODE_BIN" "$HERE/ground_truth.mjs" "$WORK/candidate.mjs") >"$WORK/out.json" 2>"$WORK/err.txt"
rc=$?

if [ "$rc" -eq 142 ]; then err "the candidate did not finish within ${TIMEOUT_S}s"; fi
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  printf '{"result":"error","detail":"the check exited %s: %s"}\n' "$rc" "$(tail -n 2 "$WORK/err.txt" | tr '\n"\\' '  /' | cut -c1-300)"
  exit 2
fi
cat "$WORK/out.json"
exit "$rc"

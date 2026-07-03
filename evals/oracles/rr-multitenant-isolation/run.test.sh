#!/usr/bin/env bash
# run.test.sh — TDD harness for the rr-multitenant-isolation structured gate contract.
#
# Asserts spec 2A's typed-report contract: run.sh grades a candidate isolation module
# against the fixed cross-tenant attack acceptance oracle and WRITES a typed report.json
# (never parses stdout). gate.json declares the gate's identity + golden_input.
#
# CONVENTIONS R6 — golden checks must be CAPABLE OF FAILING. This harness drives every
# gate-dropped mutant RED. The full falsifiability sweep + weakened-oracle meta-check
# lives in test/heimdall-rr-isolation-oracle.test.sh.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$DIR/run.sh"
GATE_JSON="$DIR/gate.json"
GOLDEN="$DIR/fixtures/golden/candidate.mjs"
MUT="$DIR/fixtures/mutants"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$(( fail + 1 )); }

echo "[1] gate.json contract (id/name/trigger/severity + golden_input)"
if jq -e '.id=="rr-multitenant-isolation" and (.trigger|type=="string") and (.severity|type=="string") and (.name|type=="string") and (.golden_input|type=="string")' "$GATE_JSON" >/dev/null 2>&1; then
  ok "gate.json valid, self-describes golden_input"
else
  bad "gate.json missing required typed fields"
fi

echo "[2] run.sh + grade.mjs + model.mjs parse; run.sh executable"
if bash -n "$RUN" 2>/dev/null; then ok "run.sh parses (bash -n)"; else bad "run.sh syntax error"; fi
if node --check "$DIR/grade.mjs" 2>/dev/null; then ok "grade.mjs parses"; else bad "grade.mjs syntax error"; fi
if node --check "$DIR/fixtures/model.mjs" 2>/dev/null; then ok "model.mjs parses"; else bad "model.mjs syntax error"; fi
if [ -x "$RUN" ]; then ok "run.sh executable"; else bad "run.sh not chmod +x"; fi

echo "[3] GOLDEN candidate -> status=pass, first_divergence=null, exit 0 (all attacks denied)"
gr="$TMP/golden.report.json"
if "$RUN" --input "$GOLDEN" --report "$gr" >/dev/null 2>&1; then grc=0; else grc=$?; fi
if [ "$grc" -eq 0 ] && jq -e '.status=="pass" and .first_divergence==null and .gate_id=="rr-multitenant-isolation" and (.metrics|type=="object")' "$gr" >/dev/null 2>&1; then
  ok "golden report.json: status=pass, schema valid, exit 0"
else
  bad "golden did not pass (rc=$grc)"; cat "$gr" 2>/dev/null || true
fi

echo "[4] every MUTANT -> status=fail, ALLOW at its pinned attack, exit nonzero"
mnames="$(jq -r '.mutants[].name' "$MUT/manifest.json")"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  file="$(jq -r --arg n "$name" '.mutants[] | select(.name==$n) | .file' "$MUT/manifest.json")"
  step="$(jq -r --arg n "$name" '.mutants[] | select(.name==$n) | .first_fail_case' "$MUT/manifest.json")"
  rep="$TMP/$name.json"
  if "$RUN" --input "$MUT/$file" --report "$rep" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ] && jq -e --arg s "$step" '.status=="fail" and .first_divergence.step==$s and .first_divergence.actual=="ALLOW"' "$rep" >/dev/null 2>&1; then
    ok "mutant $name rejected @ $step (ALLOW)"
  else
    bad "mutant $name not rejected @ $step (rc=$rc)"; cat "$rep" 2>/dev/null || true
  fi
done <<< "$mnames"

echo "[5] EMPTY acceptance oracle is an ERROR, never a silent pass"
empty="$TMP/empty.json"
printf '{"feature":"rr-multitenant-isolation","cases":[]}\n' > "$empty"
ea="$TMP/empty.report.json"
"$RUN" --input "$GOLDEN" --truth "$empty" --report "$ea" >/dev/null 2>&1 || true
if [ -s "$ea" ] && jq -e '.status=="error" and .metrics.attacks_total==0' "$ea" >/dev/null 2>&1; then
  ok "empty acceptance oracle -> status=error, attacks_total=0 (ungradable, not a graded pass)"
else
  bad "empty acceptance oracle did not report status=error"; cat "$ea" 2>/dev/null || true
fi

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

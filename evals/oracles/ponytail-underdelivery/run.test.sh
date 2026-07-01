#!/usr/bin/env bash
# run.test.sh — TDD harness for the ponytail-underdelivery structured gate contract.
#
# Asserts spec 2A's typed-report contract: run.sh grades a candidate roman(n)
# implementation against the acceptance oracle and WRITES a typed report.json
# (never parses stdout). gate.json declares the gate's identity.
#
# CONVENTIONS R6 — golden checks must be CAPABLE OF FAILING. This harness is not
# only green-on-good: it drives every under-delivery mutant RED and includes a
# corrupt-and-confirm on the golden itself. A gate that cannot be made to fail
# proves nothing. The full falsifiability sweep + meta-check lives in
# test/heimdall-underdelivery-guard.test.sh.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$DIR/run.sh"
GATE_JSON="$DIR/gate.json"
GOLDEN="$DIR/fixtures/golden/candidate.mjs"
ACC="$DIR/fixtures/golden/acceptance.json"
MUT="$DIR/fixtures/mutants"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$(( fail + 1 )); }

echo "[1] gate.json contract"
if jq -e '.id=="ponytail-underdelivery" and (.trigger|type=="string") and (.severity|type=="string") and (.name|type=="string")' "$GATE_JSON" >/dev/null 2>&1; then
  ok "gate.json has id/name/trigger/severity"
else
  bad "gate.json missing required typed fields"
fi

echo "[2] run.sh + grade.mjs parse; run.sh executable"
if bash -n "$RUN" 2>/dev/null; then ok "run.sh parses (bash -n)"; else bad "run.sh has syntax errors"; fi
if node --check "$DIR/grade.mjs" 2>/dev/null; then ok "grade.mjs parses (node --check)"; else bad "grade.mjs has syntax errors"; fi
if [ -x "$RUN" ]; then ok "run.sh is executable"; else bad "run.sh not chmod +x"; fi

echo "[3] GOLDEN candidate -> status=pass, first_divergence=null, exit 0"
gr="$TMP/golden.report.json"
if "$RUN" --input "$GOLDEN" --report "$gr" >/dev/null 2>&1; then grc=0; else grc=$?; fi
if [ "$grc" -eq 0 ] && jq -e '.status=="pass" and .first_divergence==null and .gate_id=="ponytail-underdelivery" and (.metrics|type=="object") and (.fix_hint|type=="string")' "$gr" >/dev/null 2>&1; then
  ok "golden report.json: status=pass, schema valid, exit 0"
else
  bad "golden did not pass (rc=$grc)"; cat "$gr" 2>/dev/null || true
fi

echo "[4] MUTANT hard-part-skipped -> fail @ roman(4), IV vs IIII, exit nonzero"
m1="$TMP/m1.report.json"
if "$RUN" --input "$MUT/hard-part-skipped.mjs" --report "$m1" >/dev/null 2>&1; then r1=0; else r1=$?; fi
if [ "$r1" -ne 0 ] && jq -e '.status=="fail" and .first_divergence.step=="roman(4)" and .first_divergence.expected=="IV" and .first_divergence.actual=="IIII"' "$m1" >/dev/null 2>&1; then
  ok "hard-part-skipped rejected @ roman(4) (expected IV, actual IIII)"
else
  bad "hard-part-skipped not rejected as pinned (rc=$r1)"; cat "$m1" 2>/dev/null || true
fi

echo "[5] MUTANT criterion-dropped -> fail @ roman(1000), M vs empty"
m2="$TMP/m2.report.json"
if "$RUN" --input "$MUT/criterion-dropped.mjs" --report "$m2" >/dev/null 2>&1; then r2=0; else r2=$?; fi
if [ "$r2" -ne 0 ] && jq -e '.status=="fail" and .first_divergence.step=="roman(1000)" and .first_divergence.expected=="M" and .first_divergence.actual==""' "$m2" >/dev/null 2>&1; then
  ok "criterion-dropped rejected @ roman(1000) (expected M, actual empty — thousands scope dropped)"
else
  bad "criterion-dropped not rejected as pinned (rc=$r2)"; cat "$m2" 2>/dev/null || true
fi

echo "[6] MUTANT terse-but-broken -> fail @ roman(1), I vs empty"
m3="$TMP/m3.report.json"
if "$RUN" --input "$MUT/terse-but-broken.mjs" --report "$m3" >/dev/null 2>&1; then r3=0; else r3=$?; fi
if [ "$r3" -ne 0 ] && jq -e '.status=="fail" and .first_divergence.step=="roman(1)" and .first_divergence.expected=="I" and .first_divergence.actual==""' "$m3" >/dev/null 2>&1; then
  ok "terse-but-broken rejected @ roman(1) (expected I, actual empty — small is not done)"
else
  bad "terse-but-broken not rejected as pinned (rc=$r3)"; cat "$m3" 2>/dev/null || true
fi

echo "[7] CORRUPT-AND-CONFIRM (R6): a broken golden candidate MUST drive the gate RED"
corrupt="$TMP/golden-corrupt.mjs"
sed "s/\[4, 'IV'\], //" "$GOLDEN" > "$corrupt"
cc="$TMP/corrupt.report.json"
if "$RUN" --input "$corrupt" --report "$cc" >/dev/null 2>&1; then ccr=0; else ccr=$?; fi
if [ "$ccr" -ne 0 ] && jq -e '.status=="fail" and .first_divergence.step=="roman(4)"' "$cc" >/dev/null 2>&1; then
  ok "corrupted golden driven RED @ roman(4) — golden check is falsifiable, not X-vs-X"
else
  bad "corrupted golden did NOT drive the gate red (rc=$ccr) — R6 violation"; cat "$cc" 2>/dev/null || true
fi

echo "[8] EMPTY acceptance oracle is an ERROR, never a silent pass (no false-green over nothing)"
empty_acc="$TMP/empty-acc.json"
printf '{"feature":"roman","cases":[]}\n' > "$empty_acc"
ea="$TMP/empty.report.json"
"$RUN" --input "$GOLDEN" --truth "$empty_acc" --report "$ea" >/dev/null 2>&1 || true
if [ -s "$ea" ] && jq -e '.status=="error" and .metrics.cases_total==0' "$ea" >/dev/null 2>&1; then
  ok "empty acceptance oracle -> status=error, cases_total=0 (ungradable, not a graded pass)"
else
  bad "empty acceptance oracle did not report status=error"; cat "$ea" 2>/dev/null || true
fi

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

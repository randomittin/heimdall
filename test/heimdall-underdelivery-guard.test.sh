#!/usr/bin/env bash
# heimdall-underdelivery-guard.test.sh — the FALSIFIABLE under-delivery guard.
#
# The user's #1 fear about adopting ponytail's lazy-ladder (now live in
# agents/coder.md): an agent reads rung 1 ("does this need to exist? -> skip") as
# license to hollow out the hard part, silently drop a required criterion, or
# call a terse-but-broken thing "lazy=done." The defense is NOT a prompt — it is
# that the ORACLE GATE is non-bypassable. This test PROVES, falsifiably, that a
# deliberately under-delivered "lazy" shortcut MUST FAIL the gate.
#
# It asserts:
#   [1] bin/falsify ponytail-underdelivery --assert-score 1.0 -> exit 0, score 3/3.
#   [2] the GOLDEN (fully-delivered) candidate PASSES the acceptance oracle.
#   [3] EACH under-delivery mutant is REJECTED at exactly its manifest-pinned case:
#         (a) hard-part-skipped   -> fail @ roman(4)     (subtractive not built)
#         (b) criterion-dropped   -> fail @ roman(1000)  (thousands scope dropped)
#         (c) terse-but-broken    -> fail @ roman(1)     (off-by-one, small!=done)
#   [4] the golden check is FALSIFIABLE (not an X-vs-X tautology): corrupt the
#       golden candidate and the gate goes RED.
#   [5] THE META-CHECK — the gate does the work, not a tautology: WEAKEN the gate
#       (strip the hard subtractive/thousands cases from the acceptance oracle)
#       and the hard-part-skipped mutant SURVIVES (passes) — dropping the falsify
#       score BELOW 1.0. Restore the hard cases and it is caught again. The gate's
#       STRENGTH is load-bearing; minimalism cannot ship a shortcut because the
#       shortcut fails the (unweakened) gate.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$TEST_DIR/.." && pwd)"
DOMAIN="ponytail-underdelivery"
FALSIFY="$PLUGIN/bin/falsify"
ORACLE="$PLUGIN/evals/oracles/$DOMAIN"
RUN="$ORACLE/run.sh"
GOLDEN="$ORACLE/fixtures/golden/candidate.mjs"
ACC="$ORACLE/fixtures/golden/acceptance.json"
MUT="$ORACLE/fixtures/mutants"
MANIFEST="$MUT/manifest.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$(( fail + 1 )); }

command -v jq   >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "node required" >&2; exit 2; }

# run.sh --input X [--truth Y] --report R ; never aborts the harness.
grade() {  # <input> <report> [<truth>]
  local input="$1" report="$2" truth="${3:-}"
  if [ -n "$truth" ]; then
    "$RUN" --input "$input" --truth "$truth" --report "$report" >/dev/null 2>&1 || true
  else
    "$RUN" --input "$input" --report "$report" >/dev/null 2>&1 || true
  fi
}
rstatus() { jq -r '.status // empty' "$1" 2>/dev/null || echo ""; }
rstep()   { jq -r '.first_divergence.step // empty' "$1" 2>/dev/null || echo ""; }

echo "[1] bin/falsify $DOMAIN --assert-score 1.0 -> exit 0, score 3/3 (golden passes AND every mutant rejected)"
fout="$TMP/falsify.out"
if "$FALSIFY" "$DOMAIN" --assert-score 1.0 >"$fout" 2>&1; then frc=0; else frc=$?; fi
if [ "$frc" -eq 0 ]; then ok "falsify exit 0"; else bad "falsify exit $frc (expected 0)"; cat "$fout"; fi
if grep -q 'SCORE: 3/3 = 1.0000' "$fout"; then ok "falsify SCORE line is 3/3 = 1.0000"; else bad "falsify SCORE line not 3/3 = 1.0000"; grep -i score "$fout" || true; fi
if grep -q 'ASSERT PASS: score 1.0000' "$fout"; then ok "falsify ASSERT PASS at score 1.0000"; else bad "falsify did not ASSERT PASS at 1.0000"; fi

echo "[2] GOLDEN candidate PASSES the acceptance oracle (fully delivered)"
gr="$TMP/golden.report.json"
grade "$GOLDEN" "$gr"
if [ "$(rstatus "$gr")" = "pass" ] && jq -e '.first_divergence==null and .gate_id=="ponytail-underdelivery"' "$gr" >/dev/null 2>&1; then
  ok "golden -> status=pass, first_divergence=null"
else
  bad "golden did not pass"; cat "$gr" 2>/dev/null || true
fi

echo "[3] EACH under-delivery mutant is REJECTED at its manifest-pinned first-fail case"
while IFS=$'\t' read -r mname mfile mstep; do
  [ -n "$mname" ] || continue
  mr="$TMP/$mname.report.json"
  grade "$MUT/$mfile" "$mr"
  st="$(rstatus "$mr")"; step="$(rstep "$mr")"
  if [ "$st" = "fail" ] && [ "$step" = "$mstep" ]; then
    ok "mutant '$mname' REJECTED: status=fail @ $step (matches manifest first_fail_case)"
  else
    bad "mutant '$mname' NOT rejected as pinned (status='$st' step='$step' want fail @ '$mstep')"
    cat "$mr" 2>/dev/null || true
  fi
done < <(jq -r '.mutants[] | [.name, .file, .first_fail_case] | @tsv' "$MANIFEST")

echo "[4] GOLDEN CHECK IS FALSIFIABLE (not X-vs-X): a corrupted golden candidate drives the gate RED"
# The golden check grades the golden CODE against the acceptance TABLE. Prove it
# is a real comparison: break one case in a copy of the golden and confirm fail.
# Removing the [4,'IV'] subtractive pair regresses roman(4) to the additive IIII.
corrupt="$TMP/golden-corrupt.mjs"
sed "s/\[4, 'IV'\], //" "$GOLDEN" > "$corrupt"
cr="$TMP/corrupt.report.json"
grade "$corrupt" "$cr"
if [ "$(rstatus "$cr")" = "fail" ] && [ "$(rstep "$cr")" = "roman(4)" ]; then
  ok "corrupted golden driven RED @ roman(4) — golden check is a real comparison, not X-vs-X"
else
  bad "corrupted golden did NOT drive the gate red (status='$(rstatus "$cr")' step='$(rstep "$cr")')"
  cat "$cr" 2>/dev/null || true
fi

echo "[5] META-CHECK — the gate's STRENGTH does the work (falsifiable, not a tautology)"
# Build a WEAKENED acceptance oracle: keep only additive cases (no subtractive,
# no thousands) — exactly the hard coverage that catches an under-delivered
# shortcut. Under it, the hard-part-skipped candidate looks fully delivered.
WEAK="$TMP/acceptance-weak.json"
cat > "$WEAK" <<'JSON'
{ "feature": "roman", "cases": [
  { "n": 1, "expected": "I" },
  { "n": 3, "expected": "III" },
  { "n": 6, "expected": "VI" },
  { "n": 8, "expected": "VIII" }
] }
JSON

# (5a) Under the FULL gate, hard-part-skipped is KILLED (contrast baseline).
full_hp="$TMP/full-hp.report.json"
grade "$MUT/hard-part-skipped.mjs" "$full_hp"
if [ "$(rstatus "$full_hp")" = "fail" ]; then
  ok "under FULL gate: hard-part-skipped is REJECTED (status=fail)"
else
  bad "under FULL gate: hard-part-skipped was NOT rejected (status='$(rstatus "$full_hp")')"
fi

# (5b) Under the WEAKENED gate, the SAME mutant SURVIVES (false-green) — proving
# the hard-case coverage is what was doing the work.
weak_hp="$TMP/weak-hp.report.json"
grade "$MUT/hard-part-skipped.mjs" "$weak_hp" "$WEAK"
if [ "$(rstatus "$weak_hp")" = "pass" ]; then
  ok "under WEAKENED gate: hard-part-skipped SURVIVES (status=pass) — the stripped hard cases were load-bearing"
else
  bad "weakened gate did NOT let hard-part-skipped survive (status='$(rstatus "$weak_hp")') — meta-check inconclusive"
  cat "$weak_hp" 2>/dev/null || true
fi

# (5c) Recompute the falsify SWEEP score under the weakened gate the same way
# bin/falsify does (golden must pass; killed = mutants that still fail). At least
# one survivor => score < 1.0. This is the concrete "un-rejecting a shortcut
# drops the score" proof — the gate is falsifiable, not a tautology.
weak_golden="$TMP/weak-golden.report.json"
grade "$GOLDEN" "$weak_golden" "$WEAK"
total="$(jq -r '.mutants | length' "$MANIFEST")"
killed=0
while IFS= read -r mfile; do
  [ -n "$mfile" ] || continue
  wr="$TMP/weak-$(basename "$mfile").report.json"
  grade "$MUT/$mfile" "$wr" "$WEAK"
  [ "$(rstatus "$wr")" = "fail" ] && killed=$(( killed + 1 ))
done < <(jq -r '.mutants[].file' "$MANIFEST")
survivors=$(( total - killed ))
score="$(awk -v k="$killed" -v t="$total" 'BEGIN { printf "%.4f", k / t }')"
if [ "$(rstatus "$weak_golden")" = "pass" ] && [ "$survivors" -ge 1 ] && [ "$score" != "1.0000" ]; then
  ok "WEAKENED sweep: golden still passes but $survivors/$total mutant(s) SURVIVE -> score $score < 1.0000 (score dropped when the gate was weakened)"
else
  bad "weakened sweep did not drop below 1.0 (golden='$(rstatus "$weak_golden")' survivors=$survivors score=$score) — gate strength not demonstrated"
fi

# (5d) Sanity: the REAL (unweakened) sweep is still 1.0000 — the drop in 5c is
# caused ONLY by weakening the gate, nothing else.
if grep -q 'SCORE: 3/3 = 1.0000' "$fout"; then
  ok "unweakened sweep remains 3/3 = 1.0000 — the score drop is attributable to weakening alone"
else
  bad "unweakened sweep is not 3/3 = 1.0000 (see [1])"
fi

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

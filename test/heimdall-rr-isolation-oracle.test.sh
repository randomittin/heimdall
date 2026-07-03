#!/usr/bin/env bash
# heimdall-rr-isolation-oracle.test.sh — the META-PROOF for the W5 cross-tenant-denial
# oracle (evals/oracles/rr-multitenant-isolation). This is the load-bearing check that
# the multi-tenant isolation story is REAL, not tautological:
#
#   [1] bin/falsify rr-multitenant-isolation --assert-score 1.0 exits 0
#       (golden denies every attack AND every gate-dropped mutant is caught).
#   [2] the GOLDEN candidate DENIES every cross-tenant attack (run.sh status=pass;
#       the acceptance oracle demands DENY for every case).
#   [3] each MUTANT drops exactly one isolation gate -> its cross-tenant attack
#       SUCCEEDS -> the oracle goes RED at the pinned attack (status=fail,
#       expected DENY / actual ALLOW). This proves each gate is LOAD-BEARING: drop
#       it and the oracle turns red — the falsifiable meta-proof.
#   [4] un-rejecting a mutant (weaken the acceptance oracle by dropping the attack
#       case it flips) makes that mutant SURVIVE -> the falsify score drops BELOW 1.0
#       and falsify exits nonzero. This proves the acceptance table does the work
#       (the gate is not green-by-construction).
#
# Deps: bash, jq, node. Skips cleanly if node/jq are unavailable (the gate needs them).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FALSIFY="$REPO/bin/falsify"
DOMAIN="rr-multitenant-isolation"
ORACLE="$REPO/evals/oracles/$DOMAIN"
RUN="$ORACLE/run.sh"
GOLDEN="$ORACLE/fixtures/golden/candidate.mjs"
ACC="$ORACLE/fixtures/golden/acceptance.json"
MANIFEST="$ORACLE/fixtures/mutants/manifest.json"
MUT="$ORACLE/fixtures/mutants"

if ! command -v jq >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  echo "  SKIP: jq/node required for the rr-multitenant-isolation oracle."
  echo "heimdall-rr-isolation-oracle: 0 passed, 0 failed (SKIPPED — no jq/node)"
  exit 0
fi

for f in "$FALSIFY" "$RUN" "$GOLDEN" "$ACC" "$MANIFEST"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$(( fail + 1 )); }

echo "============================================================"
echo "W5 cross-tenant-denial oracle — falsifiable isolation gate"
echo "  domain: $DOMAIN"
echo "============================================================"

echo "[1] bin/falsify $DOMAIN --assert-score 1.0 exits 0 (golden passes, every mutant caught)"
if bash "$FALSIFY" "$DOMAIN" --assert-score 1.0 >"$TMP/falsify.out" 2>&1; then
  fex=0; else fex=$?; fi
score_line="$(grep -E '^SCORE:' "$TMP/falsify.out" | tail -1)"
if [ "$fex" -eq 0 ] && printf '%s' "$score_line" | grep -q '= 1.0000'; then
  ok "falsify score == 1.0 ($score_line)"
else
  bad "falsify did not assert score 1.0 (exit=$fex; $score_line)"; cat "$TMP/falsify.out"
fi

echo "[2] GOLDEN denies EVERY cross-tenant attack (status=pass; acceptance all-DENY)"
gr="$TMP/golden.report.json"
if bash "$RUN" --input "$GOLDEN" --report "$gr" >/dev/null 2>&1; then grc=0; else grc=$?; fi
non_deny="$(jq -r '[.cases[] | select(.expected != "DENY")] | length' "$ACC")"
attacks_total="$(jq -r '.cases | length' "$ACC")"
if [ "$grc" -eq 0 ] \
   && jq -e '.status=="pass" and .first_divergence==null and .gate_id=="rr-multitenant-isolation"' "$gr" >/dev/null 2>&1 \
   && [ "$non_deny" -eq 0 ] && [ "$attacks_total" -ge 1 ]; then
  ok "golden: status=pass, all $attacks_total acceptance cases demand DENY (0 non-DENY), exit 0"
else
  bad "golden did not deny every attack (rc=$grc, non_deny=$non_deny)"; cat "$gr" 2>/dev/null || true
fi

echo "[3] each MUTANT drops a gate -> its attack SUCCEEDS -> oracle RED at the pinned attack"
mut_names="$(jq -r '.mutants[].name' "$MANIFEST")"
mut_count=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  mut_count=$(( mut_count + 1 ))
  file="$(jq -r --arg n "$name" '.mutants[] | select(.name==$n) | .file' "$MANIFEST")"
  want_step="$(jq -r --arg n "$name" '.mutants[] | select(.name==$n) | .first_fail_case' "$MANIFEST")"
  rep="$TMP/$name.report.json"
  if bash "$RUN" --input "$MUT/$file" --report "$rep" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ] \
     && jq -e --arg s "$want_step" \
        '.status=="fail" and .first_divergence.step==$s and .first_divergence.expected=="DENY" and .first_divergence.actual=="ALLOW"' \
        "$rep" >/dev/null 2>&1; then
    ok "mutant '$name' -> RED at attack '$want_step' (expected DENY, got ALLOW) — gate is load-bearing"
  else
    bad "mutant '$name' did not go RED at '$want_step' (rc=$rc)"; cat "$rep" 2>/dev/null || true
  fi
done <<< "$mut_names"
if [ "$mut_count" -ge 5 ]; then
  ok "all $mut_count isolation gates exercised (>=5 cross-tenant attack vectors)"
else
  bad "expected >=5 mutants, saw $mut_count"
fi

echo "[4] UN-REJECTING a mutant drops the score below 1.0 (acceptance table is load-bearing)"
# Copy the oracle to a throwaway tree, drop the A1-idor-repo attack case from the
# acceptance oracle, and re-run falsify there via HEIMDALL_ORACLES_DIR. The
# drop-team-covers-repo mutant ONLY flips A1-idor-repo, so removing that case makes it
# SURVIVE -> score < 1.0 -> falsify exits nonzero. A gate that could not be made to
# survive would be green-by-construction (unfalsifiable); this proves it is not.
WEAK_ORACLES="$TMP/oracles"
mkdir -p "$WEAK_ORACLES"
cp -R "$ORACLE" "$WEAK_ORACLES/$DOMAIN"
jq '{feature, note, cases: [.cases[] | select(.n != "A1-idor-repo")]}' "$ACC" \
  > "$WEAK_ORACLES/$DOMAIN/fixtures/golden/acceptance.json.tmp"
mv "$WEAK_ORACLES/$DOMAIN/fixtures/golden/acceptance.json.tmp" \
   "$WEAK_ORACLES/$DOMAIN/fixtures/golden/acceptance.json"
if HEIMDALL_ORACLES_DIR="$WEAK_ORACLES" bash "$FALSIFY" "$DOMAIN" --assert-score 1.0 \
     >"$TMP/weak.out" 2>&1; then wex=0; else wex=$?; fi
if [ "$wex" -ne 0 ] && grep -q 'SURVIVED' "$TMP/weak.out"; then
  ok "weakened acceptance -> mutant survived -> score < 1.0, falsify exit=$wex ($(grep -E '^SCORE:' "$TMP/weak.out" | tail -1))"
else
  bad "weakened acceptance did not drop the score below 1.0 (exit=$wex)"; cat "$TMP/weak.out"
fi

echo "[5] CORRUPT-AND-CONFIRM (R6): a golden that leaks one attack drives the gate RED"
# Corrupt the GOLDEN inside a full oracle copy (so the model.mjs import resolves): swap
# the strong candidate for one that drops the keystone gate. The golden check must then
# go RED at the leaked attack — proving the golden check is falsifiable, not X-vs-X.
LEAK_DIR="$TMP/leak-oracle/$DOMAIN"
mkdir -p "$TMP/leak-oracle"
cp -R "$ORACLE" "$LEAK_DIR"
cp "$LEAK_DIR/fixtures/mutants/drop-team-covers-repo.mjs" "$LEAK_DIR/fixtures/golden/candidate.mjs"
cc="$TMP/corrupt.report.json"
if bash "$LEAK_DIR/run.sh" --input "$LEAK_DIR/fixtures/golden/candidate.mjs" --report "$cc" >/dev/null 2>&1; then ccr=0; else ccr=$?; fi
if [ "$ccr" -ne 0 ] && jq -e '.status=="fail" and .first_divergence.step=="A1-idor-repo" and .first_divergence.actual=="ALLOW"' "$cc" >/dev/null 2>&1; then
  ok "a leaking golden is driven RED @ A1-idor-repo (ALLOW) — the golden check is falsifiable, not X-vs-X"
else
  bad "a leaking golden did NOT drive the gate red (rc=$ccr)"; cat "$cc" 2>/dev/null || true
fi

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

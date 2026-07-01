#!/usr/bin/env bash
# heimdall-falsify-card.test.sh — the mutation KILL-CARD is real, honest, pipe-clean.
#
# bin/falsify's deepest moat (a gate proven falsifiable — it CAN go red) was
# invisible. This test asserts the shareable receipt that makes it visible:
#
#   [1] `bin/falsify <domain> --card` renders ONE row per mutant, each carrying its
#       ✓KILLED / ✗SURVIVED glyph, plus the REAL headline SCORE from the actual run.
#   [2] The card is FALSIFIABLE, not always-green: weaken the acceptance oracle in a
#       throwaway copy so a mutant SURVIVES — the card must then show a ✗ SURVIVED
#       row AND a sub-1.0 score (proof the card can show failure, never green-washes).
#   [3] `bin/falsify --demo` runs the bundled oracle with zero setup, exits 0, and
#       prints the kill-card (the <2-min stranger wow).
#   [4] Pipe mode is ANSI-CLEAN: piped (non-tty) output carries NO raw ESC escape
#       codes — screenshot/paste safe in CI, logs, and markdown.
#
# Every number the card shows is read from a REAL falsify run — nothing fabricated.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$TEST_DIR/.." && pwd)"
DOMAIN="ponytail-underdelivery"
FALSIFY="$PLUGIN/bin/falsify"
ORACLE="$PLUGIN/evals/oracles/$DOMAIN"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$(( fail + 1 )); }

command -v jq   >/dev/null 2>&1 || { echo "jq required"   >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "node required" >&2; exit 2; }
[ -x "$FALSIFY" ] || { echo "bin/falsify not executable: $FALSIFY" >&2; exit 2; }

ESC="$(printf '\033')"   # raw escape byte — must NOT appear in piped output

echo "[1] --card renders one row per mutant (✓KILLED) + the real 3/3 score (piped)"
card="$TMP/card.out"
if "$FALSIFY" "$DOMAIN" --card >"$card" 2>&1; then crc=0; else crc=$?; fi
[ "$crc" -eq 0 ] && ok "falsify --card exit 0" || { bad "falsify --card exit $crc (expected 0)"; cat "$card"; }

# one row per mutant, each KILLED with the ✓ glyph
for m in hard-part-skipped criterion-dropped terse-but-broken; do
  if grep -q "✓" "$card" && grep -Eq "✓ *KILLED .*$m" "$card"; then
    ok "card row present: ✓ KILLED $m"
  else
    bad "card missing ✓ KILLED row for mutant '$m'"; grep -n "$m" "$card" || true
  fi
done
# exactly 3 mutant rows (one per manifest mutant), no phantom rows
rows="$(grep -cE '(✓|✗|!) *(KILLED|SURVIVED|ERROR) ' "$card" || true)"
[ "$rows" -eq 3 ] && ok "card shows exactly 3 mutant rows (matches manifest)" || bad "card row count = $rows (expected 3)"
# the headline SCORE is real and reads 3/3 = 1.0000
grep -q 'SCORE' "$card" && grep -q '3/3 = 1.0000' "$card" \
  && ok "card headline SCORE = 3/3 = 1.0000 (real run)" || { bad "card missing real SCORE 3/3 = 1.0000"; }
# the one-line verdict for an all-killed gate
grep -qi 'BIFR.ST holds' "$card" && ok "card verdict: 'BIFRÖST holds' (no mutant survived)" \
  || { bad "card missing 'BIFRÖST holds' verdict"; grep -i bifr "$card" || true; }

echo "[2] card is FALSIFIABLE: a WEAKENED oracle lets a mutant SURVIVE -> ✗ + sub-1.0"
# Throwaway copy of the real oracle; weaken acceptance.json to additive-only cases.
# hard-part-skipped (additive-only impl) then PASSES -> SURVIVES. terse-but-broken
# fails even roman(1), so it stays KILLED -> a genuine mixed board + sub-1.0 score.
WORK="$TMP/oracles"
mkdir -p "$WORK"
cp -R "$ORACLE" "$WORK/$DOMAIN"
cat > "$WORK/$DOMAIN/fixtures/golden/acceptance.json" <<'JSON'
{ "feature": "roman", "cases": [
  { "n": 1, "expected": "I" },
  { "n": 3, "expected": "III" },
  { "n": 6, "expected": "VI" },
  { "n": 8, "expected": "VIII" }
] }
JSON
wcard="$TMP/weak-card.out"
if HEIMDALL_ORACLES_DIR="$WORK" "$FALSIFY" "$DOMAIN" --card >"$wcard" 2>&1; then wrc=0; else wrc=$?; fi
# a surviving mutant -> falsify default mode exits nonzero; the card must still render.
[ "$wrc" -ne 0 ] && ok "weakened run exits nonzero (a mutant survived)" || bad "weakened run exit 0 (expected nonzero — survivor)"
if grep -q "✗" "$wcard" && grep -Eq "✗ *SURVIVED " "$wcard"; then
  ok "card shows a ✗ SURVIVED row (the gate CAN show failure — falsifiable)"
else
  bad "card shows no ✗ SURVIVED row under the weakened oracle"; cat "$wcard"
fi
# specifically hard-part-skipped survived
grep -Eq "✗ *SURVIVED .*hard-part-skipped" "$wcard" \
  && ok "hard-part-skipped SURVIVED under the additive-only oracle" \
  || bad "expected hard-part-skipped to survive the weakened oracle"
# sub-1.0 score, and NOT the always-green 1.0000
if grep -Eq 'SCORE.*[0-9]+/3 = 0\.' "$wcard" && ! grep -q '3/3 = 1.0000' "$wcard"; then
  ok "card headline score dropped below 1.0 (not always-green)"
else
  bad "weakened card did not show a sub-1.0 score"; grep -i score "$wcard" || true
fi
# honest breach verdict
grep -qi 'BIFR.ST BREACHED' "$wcard" && ok "card verdict: 'BIFRÖST BREACHED' (survivor present)" \
  || { bad "card missing breach verdict under survivor"; grep -i bifr "$wcard" || true; }

echo "[3] --demo runs the bundled oracle, exits 0, prints the kill-card (zero setup)"
demo="$TMP/demo.out"
if "$FALSIFY" --demo >"$demo" 2>&1; then drc=0; else drc=$?; fi
[ "$drc" -eq 0 ] && ok "falsify --demo exit 0" || { bad "falsify --demo exit $drc (expected 0)"; cat "$demo"; }
grep -qi 'kill-card' "$demo" && ok "--demo prints the kill-card (title present)" || bad "--demo did not print the card title"
grep -q '3/3 = 1.0000' "$demo" && ok "--demo card carries the real 3/3 = 1.0000 score" || bad "--demo card missing real score"
grep -q "✓" "$demo" && ok "--demo card carries ✓ KILLED glyphs" || bad "--demo card missing kill glyphs"

echo "[4] pipe mode is ANSI-CLEAN: piped output carries NO raw ESC escape codes"
for f in "$card" "$wcard" "$demo"; do
  if grep -q "$ESC" "$f"; then
    bad "raw ESC escape code found in piped output: $(basename "$f")"
  else
    ok "no raw ESC escape codes in piped output: $(basename "$f")"
  fi
done

echo "[5] existing gate contract UNCHANGED: --assert-score 1.0 still exits 0 at 3/3"
if "$FALSIFY" "$DOMAIN" --assert-score 1.0 >"$TMP/assert.out" 2>&1; then arc=0; else arc=$?; fi
[ "$arc" -eq 0 ] && grep -q 'ASSERT PASS: score 1.0000' "$TMP/assert.out" \
  && ok "--assert-score 1.0 -> exit 0, ASSERT PASS (gate behavior preserved)" \
  || { bad "--assert-score 1.0 behavior changed (exit $arc)"; cat "$TMP/assert.out"; }

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

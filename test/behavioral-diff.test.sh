#!/usr/bin/env bash
# behavioral-diff.test.sh — acceptance for the designmatch v2 AST behavioral diff.
#
# Proves, against REAL small RN component fixtures (no canned numbers), that the
# behavioral diff distinguishes PRESENT-AND-WIRED from NAME-APPEARS-BUT-UNWIRED —
# the thing grep cannot do — and reports HONEST coverage:
#
#   A. FULL MIGRATION — old's handlers/state/api/nav/effect/props all present and
#      WIRED in new → K=0, high coverage, exit 0 (tmp-exit NOT blocked).
#   B. PLANTED GAP — a handler is left DECLARED-BUT-UNWIRED in new (no onPress
#      binding). grep would call it migrated; the AST must report it UNMATCHED
#      (K>=1), coverage drops, exit 3 (tmp-exit BLOCKED).
#   C. GREP-FALSE-GREEN CONTRAST — the planted-gap handler name DOES appear in the
#      new file (grep -c > 0), yet the diff still flags it. This is the wired-vs-
#      unwired proof: a string match is not a migration.
#   D. COVERAGE HONESTY — an old component the extractor only PARTIALLY parses →
#      parse_confidence drops and low_confidence:true is set; coverage_pct reflects
#      the partial parse rather than greening.
#   E. HEURISTIC FALLBACK — force the regex floor backend and re-run the planted
#      gap: the degraded layer STILL catches it (backend=heuristic, K>=1). Plus an
#      unknown backend degrades gracefully (never crashes).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO/bin/designmatch-behavioral-diff"
FIX="$REPO/test/fixtures/designmatch"

OLD="$FIX/CheckoutScreen.old.jsx"
NEW_FULL="$FIX/CheckoutScreen.new.full.jsx"
NEW_GAP="$FIX/CheckoutScreen.new.gap.jsx"
OLD_PARTIAL="$FIX/Partial.old.tsx"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for JSON assertions" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: CLI not executable at $CLI" >&2; exit 2; }
for f in "$OLD" "$NEW_FULL" "$NEW_GAP" "$OLD_PARTIAL"; do
  [ -f "$f" ] || { echo "FATAL: missing fixture $f" >&2; exit 2; }
done

# run_diff OLD NEW [--backend NAME] → captures JSON in $REC and exit code in $RC.
run_diff() {
  local old="$1" new="$2"; shift 2
  REC="$("$CLI" "$old" "$new" --quiet "$@")"; RC=$?
}

jget() { printf '%s' "$REC" | jq -r "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
echo "A. FULL MIGRATION (structural) — every behavioral unit present-and-wired:"
run_diff "$OLD" "$NEW_FULL"
A_K="$(jget '.unmatched')"; A_COV="$(jget '.coverage_pct')"; A_EXTRACT="$(jget '.extracted')"
A_BLOCKED="$(jget '.blocked')"; A_BACKEND="$(jget '.backend')"
[ "$A_BACKEND" = "structural" ] && ok "backend is structural (primary now)" || bad "backend=$A_BACKEND (want structural)"
[ "$A_EXTRACT" -ge 6 ] && ok "extracted a real surface ($A_EXTRACT units across categories)" || bad "only $A_EXTRACT units extracted (want >=6)"
[ "$A_K" -eq 0 ] && ok "K=0 (no unmatched units)" || bad "K=$A_K (want 0); unmatched: $(jget '.unmatched_units')"
[ "$A_BLOCKED" = "false" ] && ok "tmp-exit NOT blocked (clean migration)" || bad "blocked=$A_BLOCKED (want false)"
awk "BEGIN{exit !($A_COV >= 95.0)}" && ok "coverage_pct=$A_COV (>=95, high)" || bad "coverage_pct=$A_COV (want >=95)"
[ "$RC" -eq 0 ] && ok "CLI exit 0 on a clean migration" || bad "CLI exit $RC (want 0)"

# ─────────────────────────────────────────────────────────────────────────────
echo "B. PLANTED GAP (structural) — an unwired handler must be UNMATCHED:"
run_diff "$OLD" "$NEW_GAP"
B_K="$(jget '.unmatched')"; B_COV="$(jget '.coverage_pct')"; B_BLOCKED="$(jget '.blocked')"
B_HAS_HANDLER="$(printf '%s' "$REC" | jq -r '[.unmatched_units[] | select(.category=="handler" and .key=="confirmPurchase")] | length')"
[ "$B_K" -ge 1 ] && ok "K=$B_K (>=1 — gap detected)" || bad "K=$B_K (want >=1)"
[ "$B_HAS_HANDLER" -ge 1 ] && ok "confirmPurchase handler reported UNMATCHED" || bad "confirmPurchase not in unmatched_units: $(jget '.unmatched_units')"
[ "$B_BLOCKED" = "true" ] && ok "tmp-exit BLOCKED (K>0)" || bad "blocked=$B_BLOCKED (want true)"
awk "BEGIN{exit !($B_COV < 100.0)}" && ok "coverage_pct=$B_COV (<100 — reflects the gap)" || bad "coverage_pct=$B_COV (want <100)"
[ "$RC" -eq 3 ] && ok "CLI exit 3 (blocked) on a planted gap" || bad "CLI exit $RC (want 3)"

# ─────────────────────────────────────────────────────────────────────────────
echo "C. GREP-FALSE-GREEN CONTRAST — name present, yet AST flags it unwired:"
GREP_HITS="$(grep -c 'confirmPurchase' "$NEW_GAP" || true)"
GREP_BOUND="$(grep -c 'onPress={confirmPurchase}' "$NEW_GAP" || true)"
[ "$GREP_HITS" -gt 0 ] && ok "grep FINDS 'confirmPurchase' ($GREP_HITS hits) — grep would green it" || bad "grep found 0 hits (fixture wrong)"
[ "$GREP_BOUND" -eq 0 ] && ok "grep finds NO 'onPress={confirmPurchase}' binding — it is unwired" || bad "fixture has the binding (gap not planted)"
# The AST verdict from B already flagged it: the contrast is grep>0 BUT AST blocks.
[ "$B_HAS_HANDLER" -ge 1 ] && ok "AST blocks where grep would pass (wired-vs-unwired proven)" || bad "AST did not flag the unwired handler"

# ─────────────────────────────────────────────────────────────────────────────
echo "D. COVERAGE HONESTY — a partial parse must NOT yield a false green:"
run_diff "$OLD_PARTIAL" "$NEW_FULL"
D_CONF="$(jget '.parse_confidence')"; D_LOW="$(jget '.low_confidence')"; D_COV="$(jget '.coverage_pct')"
D_EXTRACT="$(jget '.extracted')"
awk "BEGIN{exit !($D_CONF < 0.5)}" && ok "parse_confidence=$D_CONF (<0.5 — honest about the partial parse)" || bad "parse_confidence=$D_CONF (want <0.5)"
[ "$D_LOW" = "true" ] && ok "low_confidence:true (the green is flagged untrustworthy)" || bad "low_confidence=$D_LOW (want true)"
[ "$D_EXTRACT" -ge 1 ] && ok "still extracted $D_EXTRACT unit(s) from the fragment (degraded, not crashed)" || bad "extracted 0 from the fragment"
awk "BEGIN{exit !($D_COV < 100.0)}" && ok "coverage_pct=$D_COV reflects the partial parse (not 100)" || bad "coverage_pct=$D_COV (want <100)"

# ─────────────────────────────────────────────────────────────────────────────
echo "E. HEURISTIC FALLBACK — the degraded floor still catches the gap:"
run_diff "$OLD" "$NEW_GAP" --backend heuristic
E_BACKEND="$(jget '.backend')"; E_K="$(jget '.unmatched')"; E_BLOCKED="$(jget '.blocked')"
[ "$E_BACKEND" = "heuristic" ] && ok "backend=heuristic (regex floor exercised)" || bad "backend=$E_BACKEND (want heuristic)"
[ "$E_K" -ge 1 ] && ok "heuristic backend STILL catches the planted gap (K=$E_K)" || bad "heuristic backend missed the gap (K=$E_K)"
[ "$E_BLOCKED" = "true" ] && ok "heuristic backend BLOCKS tmp-exit" || bad "heuristic backend did not block"
[ "$RC" -eq 3 ] && ok "CLI exit 3 under the heuristic backend" || bad "CLI exit $RC (want 3)"
# unknown backend degrades gracefully rather than crashing.
run_diff "$OLD" "$NEW_FULL" --backend treesitter
U_BACKEND="$(jget '.backend')"; U_NOTE="$(printf '%s' "$REC" | jq -r '[.notes[] | select(test("degraded to heuristic"))] | length')"
[ "$U_BACKEND" = "heuristic" ] && [ "$U_NOTE" -ge 1 ] && ok "unknown backend 'treesitter' degrades to heuristic with a note (seam-ready, never crashes)" || bad "unknown backend did not degrade gracefully (backend=$U_BACKEND notes=$U_NOTE)"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "behavioral-diff.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

#!/usr/bin/env bash
# test/redum-integration.test.sh — the END-TO-END F3 Redum + F2 Checker gate.
#
# Unit tests pass while INTEGRATION bugs ship (the metering + launcher class). So
# this test drives the REAL wired flow against a REAL temp git repo — not isolated
# library calls:
#
#   stage the card-data fixture into a git repo
#     → heimdall-attest emit   (the REAL SI-2 attestation, with the reuse field)
#     → heimdall-redum gate     (commit-time; READS that attestation's reuse field)
#     → heimdall-check max       (F2 cross-author dedup over the same change)
#   then ASSERT the three agree:
#     • the attestation reuse field flags the residual duplicate(s),
#     • Redum's gate verdict is consistent with that reuse field,
#     • F2's max-tier names the same existing unit to reuse.
#   and the GENUINE-REUSE control change fires NONE of them (the gate must flag
#   duplicates, not real reuse — otherwise the test is a tautology).
#
# A failure here means the wiring is wrong (attestation→gate→checker), not that the
# harness is broken. Isolated temp dir, no network, cleaned up on exit.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures/redum"
ATTEST="$ROOT/bin/heimdall-attest"
REDUM="$ROOT/bin/heimdall-redum"
CHECK="$ROOT/bin/heimdall-check"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON assertions" >&2; exit 2; }
for f in "$ATTEST" "$REDUM" "$CHECK"; do
  [ -x "$f" ] || { echo "FATAL: not executable: $f" >&2; exit 2; }
done
[ -f "$FIX/base/src/store/cardsSlice.ts" ] || { echo "FATAL: fixtures missing: $FIX" >&2; exit 2; }

WORK="$(mktemp -d -t "redum-int.$(printf 'X%.0s' 1 2 3 4 5 6)")"
# keep attestations inside the temp tree, never the real repo.
export HEIMDALL_HOME="$WORK/.heimdall"
trap 'rm -rf "$WORK"' EXIT

# ── build a base repo: the pre-existing card store (authored by "alice") ───────
REPO="$WORK/repo"
mkdir -p "$REPO/src/store" "$REPO/src/screens"
git -C "$REPO" init -q
git -C "$REPO" config user.email "alice@team.dev"
git -C "$REPO" config user.name  "alice"
cp "$FIX/base/src/store/cardsSlice.ts"   "$REPO/src/store/cardsSlice.ts"
cp "$FIX/base/src/store/cardsStorage.ts" "$REPO/src/store/cardsStorage.ts"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "base: existing card store (slice, selectors, MMKV key)"
BASE="$(git -C "$REPO" rev-parse HEAD)"

# ════════════════════════════════════════════════════════════════════════════
# PART A — the REINVENTION change: it must be flagged by all three.
# A DIFFERENT author (bob) re-declares the slice / selector / MMKV key.
# ════════════════════════════════════════════════════════════════════════════
git -C "$REPO" config user.email "bob@team.dev"
git -C "$REPO" config user.name  "bob"
cp "$FIX/reinvention/src/screens/CardsScreen.tsx" "$REPO/src/screens/CardsScreen.tsx"

# 1) REAL SI-2 attestation over the working tree vs BASE (the actual emit flow).
ATT_FILE="$WORK/attest-reinvention.json"
"$ATTEST" emit --repo "$REPO" --base "$BASE" --task "add cards screen" \
  --print --quiet > "$ATT_FILE" 2>/dev/null
if jq -e . "$ATT_FILE" >/dev/null 2>&1; then
  ok "attestation emit produced well-formed JSON (the real SI-2 flow ran)"
else
  bad "attestation emit did not produce valid JSON"
fi

# the reuse field must be present + carry a reuse_pct and suspected_duplicates.
RPCT="$(jq -r '.reuse.reuse_pct // "null"' "$ATT_FILE")"
if jq -e '.reuse | has("reuse_pct") and has("suspected_duplicates")' "$ATT_FILE" >/dev/null; then
  ok "attestation carries the SI-2 reuse field (reuse_pct=$RPCT)"
else
  bad "attestation missing the reuse field"
fi

# SI-2 must have detected the reinvention: either a low reuse_pct OR a suspected
# duplicate (the change re-added a shape the repo had). This is the integration
# signal Redum's gate consumes — assert it is genuinely present, not assumed.
SUSP="$(jq -r '.reuse.suspected_duplicates | length' "$ATT_FILE")"
REINV="$(jq -r '.reuse.units_reinventing // 0' "$ATT_FILE")"
if [ "$SUSP" -ge 1 ] || [ "$REINV" -ge 1 ]; then
  ok "SI-2 reuse field flags the reinvention (suspected=$SUSP, reinventing=$REINV)"
else
  bad "SI-2 reuse field did NOT flag the reinvention (suspected=$SUSP, reinventing=$REINV)"
fi

# 2) Redum's commit-time gate READS that attestation (does NOT re-measure) and must
#    flag the residual duplicate. --block makes it exit nonzero on a duplicate.
set +e
GATE_OUT="$("$REDUM" gate --repo "$REPO" --base "$BASE" --attest "$ATT_FILE" --block 2>/dev/null)"
GATE_RC=$?
set -e
GATE_VERDICT="$(printf '%s' "$GATE_OUT" | jq -r '.verdict')"
if [ "$GATE_RC" -eq 1 ] && [ "$GATE_VERDICT" = "block" ]; then
  ok "redum gate BLOCKED the reinvention (verdict=block, exit=1)"
else
  bad "redum gate did not block the reinvention (verdict=$GATE_VERDICT, exit=$GATE_RC)"
fi

# 3) the gate must name an EXISTING repo unit to reuse (actionable, not just "low
#    reuse") — at least one residual entry pointing back into the base store.
RESID="$(printf '%s' "$GATE_OUT" | jq -r '.residual | length')"
NAMED_EXISTING="$(printf '%s' "$GATE_OUT" \
  | jq -r '[.residual[] | select(.existing.file != null)] | length')"
if [ "$RESID" -ge 1 ] && [ "$NAMED_EXISTING" -ge 1 ]; then
  ok "redum gate named the existing unit to reuse ($RESID residual, $NAMED_EXISTING with a file)"
else
  bad "redum gate did not name an existing unit (residual=$RESID, named=$NAMED_EXISTING)"
fi

# 4) the gate's reuse_pct must be the SAME number SI-2 emitted — proving the gate
#    READ the attestation rather than recomputing its own (the no-re-measure
#    contract). Compare the raw strings (both come from the same JSON shape).
GATE_PCT="$(printf '%s' "$GATE_OUT" | jq -r '.reuse_pct // "null"')"
if [ "$GATE_PCT" = "$RPCT" ]; then
  ok "redum gate reuse_pct == SI-2 reuse_pct ($GATE_PCT) — it READ, did not re-measure"
else
  bad "redum gate reuse_pct ($GATE_PCT) != SI-2 reuse_pct ($RPCT) — it re-measured"
fi

# 5) F2 Checker max-tier over the SAME change must independently flag the dup and
#    name the SAME existing unit (cross-author: bob duplicated alice's units).
set +e
CHECK_OUT="$("$CHECK" --repo "$REPO" --base "$BASE" --tier max --attest "$ATT_FILE" --block 2>/dev/null)"
CHECK_RC=$?
set -e
CHECK_VERDICT="$(printf '%s' "$CHECK_OUT" | jq -r '.verdict')"
CHECK_DUPS="$(printf '%s' "$CHECK_OUT" | jq -r '.duplicates | length')"
if [ "$CHECK_RC" -eq 1 ] && [ "$CHECK_VERDICT" = "duplicate" ] && [ "$CHECK_DUPS" -ge 1 ]; then
  ok "checker[max] flagged the cross-author duplicate ($CHECK_DUPS dup(s), exit=1)"
else
  bad "checker[max] did not flag the duplicate (verdict=$CHECK_VERDICT, dups=$CHECK_DUPS, exit=$CHECK_RC)"
fi

# 6) the duplicate F2 names must attribute to alice (the original author) — the
#    cross-author dedup, not a self-match.
ALICE_DUPS="$(printf '%s' "$CHECK_OUT" \
  | jq -r '[.duplicates[] | select(.author == "alice@team.dev")] | length')"
if [ "$ALICE_DUPS" -ge 1 ]; then
  ok "checker[max] attributed the duplicate to the original author (alice: $ALICE_DUPS)"
else
  bad "checker[max] did not attribute the duplicate to alice ($ALICE_DUPS)"
fi

# 7) CONSISTENCY: all three saw the SAME problem. The selectCards selector is the
#    shared anchor — it must appear in SI-2's reinvention signal OR the gate's
#    residual AND in F2's duplicates (the three features agree on the dup).
GATE_HAS_SELECT="$(printf '%s' "$GATE_OUT" \
  | jq -r '[.residual[] | select((.duplicates // "") | test("selectCards"))] | length')"
CHECK_HAS_SELECT="$(printf '%s' "$CHECK_OUT" \
  | jq -r '[.duplicates[] | select(.new_unit == "selectCards")] | length')"
if [ "$GATE_HAS_SELECT" -ge 1 ] && [ "$CHECK_HAS_SELECT" -ge 1 ]; then
  ok "gate + checker agree on the duplicated unit (selectCards in both)"
else
  bad "gate ($GATE_HAS_SELECT) + checker ($CHECK_HAS_SELECT) disagree on selectCards"
fi

# ════════════════════════════════════════════════════════════════════════════
# PART B — the GENUINE-REUSE control: it must fire NONE of the flags.
# Same screen, written to IMPORT + CALL the existing units. If the gate flags
# this, it is flagging on presence, not on duplication — a false positive.
# ════════════════════════════════════════════════════════════════════════════
rm -f "$REPO/src/screens/CardsScreen.tsx"
cp "$FIX/reuse/src/screens/CardsScreen.tsx" "$REPO/src/screens/CardsScreen.tsx"

ATT2="$WORK/attest-reuse.json"
"$ATTEST" emit --repo "$REPO" --base "$BASE" --task "add cards screen (reuse)" \
  --print --quiet > "$ATT2" 2>/dev/null

set +e
GATE2_OUT="$("$REDUM" gate --repo "$REPO" --base "$BASE" --attest "$ATT2" --block 2>/dev/null)"
GATE2_RC=$?
set -e
GATE2_VERDICT="$(printf '%s' "$GATE2_OUT" | jq -r '.verdict')"
if [ "$GATE2_RC" -eq 0 ] && [ "$GATE2_VERDICT" = "ok" ]; then
  ok "redum gate did NOT flag the genuine-reuse control (verdict=ok, exit=0)"
else
  bad "redum gate WRONGLY flagged genuine reuse (verdict=$GATE2_VERDICT, exit=$GATE2_RC)"
fi

set +e
CHECK2_OUT="$("$CHECK" --repo "$REPO" --base "$BASE" --tier max --block 2>/dev/null)"
CHECK2_RC=$?
set -e
CHECK2_VERDICT="$(printf '%s' "$CHECK2_OUT" | jq -r '.verdict')"
if [ "$CHECK2_RC" -eq 0 ] && [ "$CHECK2_VERDICT" = "ok" ]; then
  ok "checker[max] did NOT flag the genuine-reuse control (verdict=ok, exit=0)"
else
  bad "checker[max] WRONGLY flagged genuine reuse (verdict=$CHECK2_VERDICT, exit=$CHECK2_RC)"
fi

# the genuine-reuse change must score HIGHER reuse than the reinvention change —
# the metric moves the right direction (this is the proof the artifact captures).
RPCT2="$(jq -r '.reuse.reuse_pct // "null"' "$ATT2")"
HIGHER="$(REINV_P="$RPCT" REUSE_P="$RPCT2" python3 - <<'PYEOF'
import os
def f(x):
    try: return float(x)
    except Exception: return None
a, b = f(os.environ["REINV_P"]), f(os.environ["REUSE_P"])
print("yes" if (a is not None and b is not None and b > a) else "no")
PYEOF
)"
if [ "$HIGHER" = "yes" ]; then
  ok "genuine reuse scores higher reuse_pct than reinvention ($RPCT2 > $RPCT)"
else
  bad "genuine reuse did NOT score higher ($RPCT2 vs reinvention $RPCT)"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
printf "redum-integration: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "redum-integration: OK — attestation → redum gate → F2 checker are wired + consistent"
exit 0

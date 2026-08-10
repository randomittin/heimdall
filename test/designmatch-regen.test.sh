#!/usr/bin/env bash
#
# designmatch-regen.test.sh — acceptance for the designmatch v2 REGENERATE
# pipeline (bin/designmatch: regen / regen-gate), the thing that ties the merged
# hash-log change-detection (bin/designmatch-regen-log), the merged AST behavioral
# diff (bin/designmatch-behavioral-diff), the language-pluggable target seam
# (bin/designmatch-target → bin/lib/designmatch_targets/), and the existing visual
# harness together into ONE gated flow:
#
#   changed? → quarantine old (MOVE, never delete) → generate fresh (seam) →
#   migrate → DUAL-GATE (visual SSIM/pixelmatch AND behavioral K=0 + honest
#   coverage) → release old from tmp ONLY on BOTH.
#
# The BEHAVIORAL half is ALWAYS REAL here — every proof actually runs
# behavioral-diff over real RN fixtures (no canned K). Only the VISUAL half is
# injected via the pipeline's documented test seam (--visual-result pass|fail),
# so the behavioral gap is the SOLE blocker where we want to prove it.
#
# Proofs (all runnable, none skippable):
#   1. HASH-LOG GATE — an UNCHANGED screen (hash matches ledger) → regen NO-OPs:
#      no quarantine, no regenerate. A CHANGED/new screen → regen proceeds.
#   2. QUARANTINE CARDINAL RULE — on regen the old component is MOVED to
#      .designmatch/tmp/<Screen>.<ts>/: the tmp copy EXISTS and the old file is
#      NO LONGER at its original path (moved, NEVER deleted — recoverable).
#   3. DUAL-GATE BLOCKS on a behavioral gap — a migrated NEW missing a wired
#      handler (the .new.gap fixture) → REAL behavioral-diff K>0 → dual-gate FAILS
#      → the old file STAYS in tmp (recoverable, NOT released) → the gate reports
#      the unmatched unit by name.
#   4. DUAL-GATE RELEASES only when BOTH pass — full migration (.new.full, K=0)
#      AND visual pass → old file LEAVES tmp + regen-log `record` stamps
#      provenance. Release happens ONLY here.
#   5. VISUAL-ONLY IS NOT ENOUGH — with the visual half FORCED to pass, a
#      behaviorally-gapped screen still does NOT release (the behavioral gap is
#      the sole blocker in #3); and the converse, a visual FAIL with a clean
#      behavioral pass, also does NOT release. Release needs BOTH.
#   6. COVERAGE HONESTY — the dual-gate surfaces coverage_pct / backend /
#      parse_confidence; a low-confidence parse is flagged and does NOT yield a
#      false green (old stays in tmp).
#   7. LANGUAGE SEAM — adding a 2nd target is implementing the interface, not
#      editing the pipeline: the targets registry lists `rn`, exposes a register
#      point, and a typo'd target fails loudly (never silently RN).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
DM="$REPO/bin/designmatch"
REGEN_LOG="$REPO/bin/designmatch-regen-log"
BEHAVIORAL="$REPO/bin/designmatch-behavioral-diff"
TARGET="$REPO/bin/designmatch-target"
FIX="$REPO/test/fixtures/designmatch"

CANON="$FIX/Checkout.canonical.jsx"
OLD="$FIX/CheckoutScreen.old.jsx"
NEW_FULL="$FIX/CheckoutScreen.new.full.jsx"
NEW_GAP="$FIX/CheckoutScreen.new.gap.jsx"
OLD_PARTIAL="$FIX/Partial.old.tsx"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for JSON assertions" >&2; exit 2; }
[ -x "$DM" ]         || { echo "FATAL: designmatch not executable at $DM" >&2; exit 2; }
[ -x "$REGEN_LOG" ]  || { echo "FATAL: regen-log CLI not executable at $REGEN_LOG" >&2; exit 2; }
[ -x "$BEHAVIORAL" ] || { echo "FATAL: behavioral-diff CLI not executable at $BEHAVIORAL" >&2; exit 2; }
[ -x "$TARGET" ]     || { echo "FATAL: designmatch-target CLI not executable at $TARGET" >&2; exit 2; }
for f in "$CANON" "$OLD" "$NEW_FULL" "$NEW_GAP" "$OLD_PARTIAL"; do
  [ -f "$f" ] || { echo "FATAL: missing fixture $f" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SCREEN="Checkout"

# fresh_app — make an isolated RN-ish app dir with its own .designmatch ledger and
# an old component seeded at src/screens/<Screen>.tsx. Echoes the app dir. Each
# proof gets a clean app so quarantine timestamps + ledgers never collide.
fresh_app() {
  # fresh_app <tag> <old-fixture>  → echoes APP dir
  local tag="$1" oldfix="$2"
  local app="$WORK/$tag"
  mkdir -p "$app/src/screens"
  cp "$oldfix" "$app/src/screens/$SCREEN.tsx"
  echo "$app"
}

# ledger_for — the per-app ledger path (matches the pipeline default).
ledger_for() { echo "$1/.designmatch/regen-log.json"; }

# tmp_dir_for — the most recent quarantine tmp dir for the screen under an app.
tmp_dir_for() {
  find "$1/.designmatch/tmp" -maxdepth 1 -type d -name "$SCREEN.*" 2>/dev/null | sort | tail -1 || true
}

# old_in_tmp_for — the quarantined old file (non-manifest) inside the tmp dir.
old_in_tmp_for() {
  local td; td="$(tmp_dir_for "$1")"
  [ -n "$td" ] || { echo ""; return 0; }
  find "$td" -maxdepth 1 -type f ! -name 'manifest.json' 2>/dev/null | head -1 || true
}

# regen — drive the full pipeline with no unguarded pipe; sets REG_OUT, REG_RC.
regen() {
  set +e
  REG_OUT="$("$DM" regen "$@" 2>&1)"
  REG_RC=$?
  set +e
}

echo "designmatch-regen.test.sh — v2 regenerate pipeline acceptance"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "1. HASH-LOG GATE — unchanged → NO-OP; changed/new → proceeds:"

# 1a. UNCHANGED: record the canonical first, then regen the SAME canonical → no-op.
APP="$(fresh_app gate_noop "$OLD")"
LEDGER="$(ledger_for "$APP")"
"$REGEN_LOG" --ledger "$LEDGER" record "$SCREEN" "$CANON" "$APP/src/screens/$SCREEN.tsx" >/dev/null 2>&1
REC_RC=$?
[ "$REC_RC" -eq 0 ] && ok "seed: regen-log record stamps the unchanged canonical (rc=0)" \
  || bad "seed record failed (rc=$REC_RC)"

regen "$SCREEN" --app-dir "$APP" --canonical "$CANON" --old "$APP/src/screens/$SCREEN.tsx"
if [ "$REG_RC" -eq 0 ] && grep -qi 'no-op' <<<"$REG_OUT"; then
  ok "UNCHANGED screen → regen NO-OPs (rc=0, hash matches ledger)"
else
  bad "unchanged screen should no-op (rc=$REG_RC, out='$REG_OUT')"
fi
# A no-op must NOT quarantine and must NOT move the old file.
if [ -f "$APP/src/screens/$SCREEN.tsx" ]; then
  ok "NO-OP did not touch the old file (still at original path — no churn)"
else
  bad "no-op moved/removed the old file (churn on an unchanged design)"
fi
if [ -z "$(tmp_dir_for "$APP")" ]; then
  ok "NO-OP created no quarantine tmp dir (nothing regenerated)"
else
  bad "no-op created a quarantine tmp dir: $(tmp_dir_for "$APP")"
fi

# 1b. CHANGED/NEW: a never-recorded screen → regen proceeds (quarantines + generates).
APP="$(fresh_app gate_changed "$OLD")"
regen "$SCREEN" --app-dir "$APP" --canonical "$CANON" --old "$APP/src/screens/$SCREEN.tsx"
if grep -qi 'CHANGED (or new)' <<<"$REG_OUT"; then
  ok "NEW/CHANGED screen → regen PROCEEDS (design changed → regenerating)"
else
  bad "new screen should proceed to regenerate (out='$REG_OUT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "2. QUARANTINE CARDINAL RULE — old MOVED to tmp (exists), gone from origin:"
# (Uses the gate_changed app from 1b: it regenerated, so it quarantined.)
ORIG_OLD="$APP/src/screens/$SCREEN.tsx"   # original path (now holds the GENERATED file)
TD="$(tmp_dir_for "$APP")"
QFILE="$(old_in_tmp_for "$APP")"
if [ -n "$TD" ] && [ -d "$TD" ]; then
  ok "quarantine tmp dir created: ${TD#$WORK/}"
else
  bad "no quarantine tmp dir created on a changed screen"
fi
if [ -n "$QFILE" ] && [ -f "$QFILE" ]; then
  ok "old component EXISTS under tmp (recoverable): ${QFILE#$WORK/}"
else
  bad "old component not found under tmp (quarantine did not preserve it)"
fi
# The quarantined copy must be byte-identical to the original OLD fixture (a MOVE,
# not a truncate / empty-shell). Proves it is the real, recoverable old behavior.
if [ -n "$QFILE" ] && cmp -s "$QFILE" "$OLD"; then
  ok "quarantined copy is byte-identical to the old component (real MOVE, recoverable)"
else
  bad "quarantined copy differs from the old component (not a faithful move)"
fi
# The MANIFEST records what/why/when + release:false at quarantine time.
MAN="$TD/manifest.json"
if [ -f "$MAN" ] && [ "$(jq -r '.released' "$MAN")" = "false" ] \
   && [ "$(jq -r '.screen' "$MAN")" = "$SCREEN" ]; then
  ok "manifest records the quarantine (screen=$SCREEN, released:false)"
else
  bad "manifest missing/wrong at $MAN"
fi
# CARDINAL: the original path must NOT still hold the OLD component. The pipeline
# generated a fresh skeleton there; the key invariant is the OLD bytes are GONE
# from origin (moved) yet PRESENT in tmp. Prove origin != old, tmp == old.
if [ -f "$ORIG_OLD" ] && ! cmp -s "$ORIG_OLD" "$OLD"; then
  ok "original path no longer holds the OLD component (it was MOVED to tmp, then regenerated fresh)"
else
  bad "original path still holds the old component bytes (not moved) at $ORIG_OLD"
fi
# And the generated file at origin is the behavior-free RN skeleton from the seam.
if [ -f "$ORIG_OLD" ] && grep -q 'REGENERATED by designmatch v2' "$ORIG_OLD"; then
  ok "original path now holds the freshly GENERATED (behavior-free) RN component"
else
  bad "original path does not hold the regenerated component"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "3. DUAL-GATE BLOCKS on a behavioral gap — old STAYS in tmp (visual forced PASS):"
# Visual is FORCED to pass so the REAL behavioral-diff (over .new.gap) is the SOLE
# blocker. The gap fixture leaves confirmPurchase declared-but-UNWIRED.
APP="$(fresh_app gate_block "$OLD")"
regen "$SCREEN" --app-dir "$APP" --canonical "$CANON" \
  --old "$APP/src/screens/$SCREEN.tsx" \
  --migrated "$NEW_GAP" \
  --visual-result pass
if [ "$REG_RC" -ne 0 ]; then
  ok "dual-gate returns nonzero on a behavioral gap (rc=$REG_RC — blocked)"
else
  bad "dual-gate should block on a behavioral gap (rc=$REG_RC)"
fi
if grep -qi 'dual-gate BLOCKED (behavioral' <<<"$REG_OUT"; then
  ok "block reason is BEHAVIORAL (visual was forced PASS — gap is the sole blocker)"
else
  bad "block reason not behavioral (out='$REG_OUT')"
fi
# The REAL behavioral-diff must have reported the unwired handler by name.
if grep -qi 'UNMATCHED handler:confirmPurchase' <<<"$REG_OUT"; then
  ok "behavioral gate reports the unmatched unit by name (handler:confirmPurchase)"
else
  bad "behavioral gate did not name the unmatched unit (out='$REG_OUT')"
fi
# CARDINAL: on a blocked gate the old file STAYS in tmp (recoverable, NOT released).
QFILE="$(old_in_tmp_for "$APP")"
if [ -n "$QFILE" ] && [ -f "$QFILE" ] && cmp -s "$QFILE" "$OLD"; then
  ok "old file STAYS in tmp after a blocked gate (recoverable, NOT released)"
else
  bad "old file not preserved in tmp after a block (cardinal rule broken)"
fi
TD="$(tmp_dir_for "$APP")"
if [ "$(jq -r '.released' "$TD/manifest.json")" = "false" ] \
   && [ "$(jq -r '.dual_gate.behavioral' "$TD/manifest.json")" = "false" ] \
   && [ "$(jq -r '.dual_gate.visual' "$TD/manifest.json")" = "true" ]; then
  ok "manifest records the verdict honestly (visual:true, behavioral:false, released:false)"
else
  bad "manifest verdict wrong after block: $(jq -c '.dual_gate, {released}' "$TD/manifest.json")"
fi
# No provenance may be recorded for a blocked screen (the gate did not advance).
set +e
"$REGEN_LOG" --ledger "$(ledger_for "$APP")" provenance "$SCREEN" >/dev/null 2>&1
PROV_RC=$?
set +e
[ "$PROV_RC" -ne 0 ] && ok "no provenance recorded for a blocked screen (gate not advanced)" \
  || bad "provenance was recorded despite a blocked gate"

# ─────────────────────────────────────────────────────────────────────────────
echo "4. DUAL-GATE RELEASES only when BOTH pass — full migration + visual pass:"
APP="$(fresh_app gate_release "$OLD")"
LEDGER="$(ledger_for "$APP")"
regen "$SCREEN" --app-dir "$APP" --canonical "$CANON" \
  --old "$APP/src/screens/$SCREEN.tsx" \
  --migrated "$NEW_FULL" \
  --ledger "$LEDGER" \
  --visual-result pass
if [ "$REG_RC" -eq 0 ] && grep -qi 'dual-gate PASSED' <<<"$REG_OUT"; then
  ok "dual-gate PASSES on full migration + visual pass (rc=0)"
else
  bad "dual-gate should pass on both-green (rc=$REG_RC, out='$REG_OUT')"
fi
# REAL behavioral-diff must have reported K=0 / 100% coverage in the surfaced line.
if grep -qiE 'coverage: .*100\.0%.*K=0 unmatched' <<<"$REG_OUT"; then
  ok "behavioral gate (REAL) reports K=0 + full coverage on the clean migration"
else
  bad "behavioral gate did not report a clean K=0 (out='$REG_OUT')"
fi
# RELEASE: the old file LEAVES tmp (no longer the sole behavior source).
QFILE="$(old_in_tmp_for "$APP")"
if [ -z "$QFILE" ]; then
  ok "old file RELEASED from tmp on a both-pass gate (migration proven)"
else
  bad "old file still in tmp after a passing gate (should be released): $QFILE"
fi
TD="$(tmp_dir_for "$APP")"
if [ "$(jq -r '.released' "$TD/manifest.json")" = "true" ]; then
  ok "manifest marked released:true on the both-pass gate"
else
  bad "manifest not marked released after a passing gate"
fi
# Provenance is stamped ONLY on release (gate advanced).
PROV="$("$REGEN_LOG" --ledger "$LEDGER" provenance "$SCREEN" 2>/dev/null)"; PROV_RC=$?
if [ "$PROV_RC" -eq 0 ] && [ "$(printf '%s' "$PROV" | jq -r '.generated_output')" = "$NEW_FULL" ]; then
  ok "regen-log RECORD stamped provenance on release (generated_output=migrated component)"
else
  bad "provenance not stamped correctly on release (rc=$PROV_RC, out='$PROV')"
fi
# After release the SAME canonical is now UNCHANGED → a re-regen no-ops (the gate
# advanced). This closes the loop: release advances change-detection.
regen "$SCREEN" --app-dir "$APP" --canonical "$CANON" --ledger "$LEDGER" \
  --old "$APP/src/screens/$SCREEN.tsx"
if [ "$REG_RC" -eq 0 ] && grep -qi 'no-op' <<<"$REG_OUT"; then
  ok "after release the recorded canonical is UNCHANGED → re-regen no-ops (gate advanced)"
else
  bad "post-release re-regen should no-op (rc=$REG_RC, out='$REG_OUT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "5. VISUAL-ONLY IS NOT ENOUGH — release needs BOTH halves:"
# 5a is the contrapositive of #3: visual PASS + behavioral GAP did NOT release
# (already proven above — assert the captured state explicitly here).
APP_BLOCK="$WORK/gate_block"
if [ -n "$(old_in_tmp_for "$APP_BLOCK")" ]; then
  ok "visual-PASS + behavioral-GAP did NOT release (old still in tmp) — visual alone is insufficient"
else
  bad "visual-pass somehow released despite a behavioral gap"
fi
# 5b the converse: visual FAIL + behavioral CLEAN (K=0) must also NOT release.
APP="$(fresh_app gate_visfail "$OLD")"
regen "$SCREEN" --app-dir "$APP" --canonical "$CANON" \
  --old "$APP/src/screens/$SCREEN.tsx" \
  --migrated "$NEW_FULL" \
  --visual-result fail
if [ "$REG_RC" -ne 0 ] && grep -qi 'dual-gate BLOCKED (visual' <<<"$REG_OUT"; then
  ok "visual FAIL blocks even with a clean behavioral pass (rc=$REG_RC)"
else
  bad "visual fail should block despite clean behavioral (rc=$REG_RC, out='$REG_OUT')"
fi
QFILE="$(old_in_tmp_for "$APP")"
if [ -n "$QFILE" ] && cmp -s "$QFILE" "$OLD"; then
  ok "old file STAYS in tmp on a visual-fail block (behavioral-alone is also insufficient)"
else
  bad "old file not preserved on a visual-fail block"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "6. COVERAGE HONESTY — low-confidence parse surfaced + does NOT green:"
# Quarantine a PARTIALLY-parseable old (Partial.old) and migrate the full new.
# The behavioral-diff parses the old with low confidence (parse_confidence<0.5):
# the gate must surface coverage_pct/backend/parse_confidence AND refuse to green.
APP="$(fresh_app gate_lowconf "$OLD_PARTIAL")"
regen "$SCREEN" --app-dir "$APP" --canonical "$CANON" \
  --old "$APP/src/screens/$SCREEN.tsx" \
  --migrated "$NEW_FULL" \
  --visual-result pass
# The surfaced coverage line carries ALL THREE honesty fields.
if grep -qE 'coverage: .*%.*backend=structural.*parse_confidence=' <<<"$REG_OUT"; then
  ok "dual-gate surfaces coverage_pct + backend + parse_confidence (honest record)"
else
  bad "coverage honesty fields not surfaced (out='$REG_OUT')"
fi
if grep -qi 'LOW-CONFIDENCE' <<<"$REG_OUT"; then
  ok "low-confidence parse is FLAGGED in the surfaced coverage (not hidden as a pass)"
else
  bad "low-confidence parse not flagged (out='$REG_OUT')"
fi
if [ "$REG_RC" -ne 0 ] && ! grep -qi 'dual-gate PASSED' <<<"$REG_OUT"; then
  ok "low-confidence parse does NOT yield a false green (gate blocked, rc=$REG_RC)"
else
  bad "low-confidence parse greened (rc=$REG_RC, out='$REG_OUT')"
fi
QFILE="$(old_in_tmp_for "$APP")"
if [ -n "$QFILE" ] && cmp -s "$QFILE" "$OLD_PARTIAL"; then
  ok "old file STAYS in tmp on a low-confidence parse (recoverable, not falsely released)"
else
  bad "old file not preserved on a low-confidence block"
fi
# DIRECT honesty seam: drive the SAME REAL behavioral CLI the pipeline gates on
# over the very inputs the gate_lowconf scenario blocked on. The record must carry
# an HONEST sub-threshold parse_confidence with low_confidence:true — i.e. the
# pipeline's block above was triggered by a genuine low-confidence parse surfaced
# in the record, not by inference. parse_confidence is a real number in [0,1]; the
# low_confidence flag is exactly parse_confidence < 0.5.
HREC="$("$BEHAVIORAL" "$OLD_PARTIAL" "$NEW_FULL" --quiet 2>/dev/null)"
H_LOW="$(printf '%s' "$HREC" | jq -r '.low_confidence')"
H_CONF="$(printf '%s' "$HREC" | jq -r '.parse_confidence')"
if [ "$H_LOW" = "true" ] && awk "BEGIN{exit !($H_CONF < 0.5)}"; then
  ok "the blocked parse carries an HONEST sub-threshold parse_confidence=$H_CONF → low_confidence:true (no false green)"
else
  bad "expected low_confidence:true with parse_confidence<0.5 (low=$H_LOW conf=$H_CONF)"
fi
# And a CONFIDENT parse is the contrast: the full old component parses cleanly →
# parse_confidence>=0.5, low_confidence:false. This proves the flag tracks the
# parse, not a constant (the honesty number is real, computed per-input).
CREC="$("$BEHAVIORAL" "$OLD" "$NEW_FULL" --quiet 2>/dev/null)"
C_LOW="$(printf '%s' "$CREC" | jq -r '.low_confidence')"
C_CONF="$(printf '%s' "$CREC" | jq -r '.parse_confidence')"
if [ "$C_LOW" = "false" ] && awk "BEGIN{exit !($C_CONF >= 0.5)}"; then
  ok "a confident parse (full old) reports parse_confidence=$C_CONF → low_confidence:false (flag tracks the real parse, not a constant)"
else
  bad "expected a confident parse for the full old (low=$C_LOW conf=$C_CONF)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "7. LANGUAGE SEAM — registry lists rn + register point; typo fails loudly:"
set +e
LIST_OUT="$("$TARGET" list 2>&1)"; LIST_RC=$?
set +e
if [ "$LIST_RC" -eq 0 ] && grep -qE '^rn[[:space:]]+React Native[[:space:]]+tsx$' <<<"$LIST_OUT"; then
  ok "targets registry lists rn → React Native → tsx (launch target registered via the seam)"
else
  bad "registry did not list the rn target (rc=$LIST_RC, out='$LIST_OUT')"
fi
# ext resolves through the registry.
set +e
EXT_OUT="$("$TARGET" ext rn 2>&1)"; EXT_RC=$?
set +e
[ "$EXT_RC" -eq 0 ] && [ "$EXT_OUT" = "tsx" ] \
  && ok "registry resolves rn extension via the interface (ext rn → tsx)" \
  || bad "ext rn wrong (rc=$EXT_RC, out='$EXT_OUT')"
# A typo'd / unimplemented target fails LOUDLY (never silently defaults to RN).
set +e
BAD_OUT="$("$TARGET" ext flutter 2>&1)"; BAD_RC=$?
set +e
if [ "$BAD_RC" -ne 0 ] && grep -qi 'no designmatch target' <<<"$BAD_OUT"; then
  ok "unknown target 'flutter' fails loudly listing available keys (add via interface, not pipeline edit)"
else
  bad "unknown target did not fail loudly (rc=$BAD_RC, out='$BAD_OUT')"
fi
# The seam's register point is a real, documented interface (register + Target).
if grep -q 'def register(' "$REPO/bin/lib/designmatch_targets/__init__.py" \
   && grep -q 'class Target' "$REPO/bin/lib/designmatch_targets/__init__.py"; then
  ok "seam exposes the register point + Target interface (a 2nd target = impl + register, not a pipeline edit)"
else
  bad "seam register point / Target interface not found in designmatch_targets/__init__.py"
fi
# And the pipeline depends ONLY on the seam CLI to generate — never a baked target.
if grep -q 'BIN_TARGET" generate' "$DM"; then
  ok "regen pipeline generates THROUGH the seam CLI ($(basename "$TARGET") generate) — language-agnostic by construction"
else
  bad "regen pipeline does not route generation through the target seam"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "designmatch-regen.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

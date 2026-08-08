#!/usr/bin/env bash
#
# security-review-tier.test.sh — pins the security-guidance reviewer to opus.
#
# WHY: docs/analysis/token-spend-forensics.md row 3 measured $57.73 of spend and
# prescribed `export SECURITY_REVIEW_MODEL=claude-haiku-4-5` to "save $46.18".
# Two things were wrong with that, and both are cheap to re-introduce:
#
#   1. WRONG KNOB. The measured sessions are the PostToolUse commit/push
#      AGENTIC review (Agent SDK -> transcript, tools Read/Grep/Glob), whose
#      model comes from SG_AGENTIC_MODEL. SECURITY_REVIEW_MODEL governs the
#      Stop hook, which posts over raw HTTP and writes no transcript — so it
#      contributed $0.00 to the figure the export claimed to reduce.
#   2. WRONG DIRECTION. This repo's canonical routing rule (bin/heimdall,
#      "MODEL ROUTING" preamble) puts review AND security on opus, quality
#      non-negotiable. Downgrading a vulnerability reviewer to buy $46 is the
#      trade that costs far more than $46 the first time it misses something.
#
# Setting SECURITY_REVIEW_MODEL also has a documented trap: the plugin's
# sonnet fallback is suppressed whenever the var is set explicitly, so a typo
# turns the reviewer permanently silent instead of erroring.
#
# Guarantees proved:
#   1. No tracked script/config prescribes a sub-opus tier for either knob.
#   2. The forensics doc no longer presents the downgrade as live advice — it
#      carries a REFUTED marker and links the decision memo.
#   3. The decision memo exists and records tier, knob, and conclusion.
#   4. The ambient environment, if it sets either knob, is not sub-opus.
#
# Usage:  test/security-review-tier.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
cd "$REPO" || exit 2

FORENSICS="docs/analysis/token-spend-forensics.md"
DECISION="docs/analysis/2026-08-08-security-review-tier-decision.md"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

printf 'security-review-tier harness  repo=%s\n' "$REPO"
printf -- '--------------------------------------------------------------------\n'

# ── 1. NO TRACKED SCRIPT/CONFIG PRESCRIBES A SUB-OPUS REVIEWER ──
# docs/analysis/ is excluded here and checked separately in step 2/3 — those
# two docs must be free to QUOTE the refuted advice in order to refute it.
# This file is excluded for the SAME reason docs/analysis/ is: the checker has to
# be free to write the pattern it forbids, and it does so twice — once in the header
# quoting the refuted advice, once in the detection regex below, which necessarily
# contains SECURITY_REVIEW_MODEL … haiku|sonnet and therefore matches itself. The
# exclusion is exactly one literal path, never a glob, so it cannot widen; and the
# synthetic probe below proves the pattern still detects after the exclusion, so a
# self-exclusion can never quietly become a blind spot.
SELF_REL="test/security-review-tier.test.sh"
SCAN="$(git ls-files -- 'bin/*' 'hooks/*' 'test/*' 'conformance/*' '*.json' '*.sh' '*.md' \
        2>/dev/null | grep -v '^docs/analysis/' | grep -vFx "$SELF_REL" || true)"
if [ -z "$SCAN" ]; then
  bad "file scan matched nothing — an empty scan must not pass"
else
  ok "scanning $(printf '%s\n' "$SCAN" | grep -c '') tracked files for tier downgrades"
  HITS=""
  for f in $SCAN; do
    [ -f "$f" ] || continue
    H="$(grep -nE '(SECURITY_REVIEW_MODEL|SG_AGENTIC_MODEL)[[:space:]]*=[[:space:]]*"?.*(haiku|sonnet)' \
         "$f" 2>/dev/null || true)"
    [ -n "$H" ] && HITS="$HITS
$f: $H"
  done
  # PROVE-DETECTS: a green scan above is only worth something if the pattern can still
  # go red. Feed it a planted downgrade and require a hit. Without this, widening the
  # exclusions or breaking the regex would read exactly like a clean tree.
  PROBE="$(mktemp -t sectier-probe)"
  printf 'export SECURITY_REVIEW_MODEL=claude-haiku-4-5\n' > "$PROBE"
  if grep -qE '(SECURITY_REVIEW_MODEL|SG_AGENTIC_MODEL)[[:space:]]*=[[:space:]]*"?.*(haiku|sonnet)' "$PROBE"; then
    ok "PROVE-DETECTS: the scan pattern still flags a planted sub-opus prescription"
  else
    bad "PROVE-DETECTS: the scan pattern no longer flags a planted downgrade — the clean verdict above is vacuous"
  fi
  rm -f "$PROBE"

  if [ -z "$HITS" ]; then
    ok "no tracked script/config downgrades SECURITY_REVIEW_MODEL / SG_AGENTIC_MODEL"
  else
    bad "a tracked file prescribes a sub-opus security reviewer:"
    printf '       %s\n' "$HITS"
  fi
fi

# ── 2. THE FORENSICS DOC NO LONGER SELLS THE DOWNGRADE ──
if [ ! -f "$FORENSICS" ]; then
  bad "$FORENSICS missing — row 3 correction cannot be verified"
else
  grep -q 'REFUTED' "$FORENSICS" \
    && ok "forensics carries a REFUTED marker on the row-3 fix" \
    || bad "forensics has no REFUTED marker — the haiku advice still reads as live"

  grep -q '2026-08-08-security-review-tier-decision.md' "$FORENSICS" \
    && ok "forensics links the decision memo" \
    || bad "forensics does not link the decision memo — the correction is orphaned"

  # The refuted export must never appear as the doc's standing recommendation
  # in the "Fixes, ranked by measured value" list.
  FIXES="$(sed -n '/^## Fixes, ranked by measured value/,/^## /p' "$FORENSICS")"
  if printf '%s' "$FIXES" | grep -qE 'SECURITY_REVIEW_MODEL=claude-(haiku|sonnet)'; then
    bad "the ranked-fixes list still prescribes a sub-opus SECURITY_REVIEW_MODEL"
  else
    ok "ranked-fixes list no longer prescribes a sub-opus SECURITY_REVIEW_MODEL"
  fi
fi

# ── 3. THE DECISION MEMO RECORDS TIER, KNOB, AND CONCLUSION ──
if [ ! -f "$DECISION" ]; then
  bad "$DECISION missing — the decision is unpinned and will be re-litigated"
else
  ok "decision memo present at $DECISION"
  for tok in 'SG_AGENTIC_MODEL' 'SECURITY_REVIEW_MODEL' 'claude-opus-4-7' 'IRREDUCIBLE'; do
    grep -q "$tok" "$DECISION" \
      && ok "decision memo records '$tok'" \
      || bad "decision memo never mentions '$tok'"
  done
  # It must name the agentic path as the one that produced the measured spend,
  # so the Stop-hook misattribution cannot quietly return.
  grep -qi 'agentic' "$DECISION" \
    && ok "decision memo attributes the spend to the agentic review path" \
    || bad "decision memo omits the agentic attribution — the core correction"
fi

# ── 4. AMBIENT ENV MUST NOT DOWNGRADE THE REVIEWER ──
# Unset is correct (the plugin defaults to claude-opus-4-7). Set-to-opus is
# fine. Set-to-haiku/sonnet is the regression this whole file exists to catch.
for var in SECURITY_REVIEW_MODEL SG_AGENTIC_MODEL; do
  eval "val=\${$var:-}"
  if [ -z "$val" ]; then
    ok "\$$var unset — plugin default (claude-opus-4-7) applies"
  else
    case "$val" in
      *haiku*|*sonnet*)
        bad "\$$var='$val' downgrades the security reviewer below opus" ;;
      *)
        ok "\$$var='$val' is not a sub-opus tier" ;;
    esac
  fi
done

printf '\n'
printf 'security-review-tier.test.sh: %s passed, %s failed.\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

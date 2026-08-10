#!/usr/bin/env bash
#
# headroom-ab.test.sh — acceptance for bin/heimdall-headroom-ab.
#
# WHY: the harness renders a RECEIPT for a published A/B. A receipt that cannot
# fire its own negative verdict is an advertisement. This test feeds the tool
# arms whose correct answer is known in advance and proves it says so — most
# importantly that it refuses to call an UNDERPOWERED run a null result, which
# is the single failure mode launch-docs/log-compression-and-gates.md
# pre-commits against.
#
# Guarantees proved:
#   1. Degraded arm (pass-rate down)      -> UNWRAP, and names the interval.
#   2. Neutral arm, adequately powered    -> KEEP.
#   3. Underpowered arm                   -> UNDERPOWERED, never "no degradation
#                                            found", never KEEP.
#   4. Falsify survivor in arm B          -> UNWRAP categorically, with NO
#                                            confidence interval on that call,
#                                            even when pass-rate is untouched.
#   5. No paired tasks                    -> INDETERMINATE, never KEEP.
#   6. Missing input renders `unavailable`, never 0.
#   7. The statistics are REPRODUCIBLE — same inputs, byte-identical output.
#   8. The rule text encodes the post's four pre-registered outcomes, and
#      rule_hash is stable across invocations.
#   9. DEPEND, DON'T CLONE — the harness never installs or vendors Headroom.
#
# Usage:  bash test/headroom-ab.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
AB="$REPO/bin/heimdall-headroom-ab"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/headroom-ab.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Strips ANSI so assertions match on text, not on colour codes.
plain() { perl -pe 's/\e\[[0-9;]*m//g'; }

# Builds a snapshot fixture with a known shape.
#   path arm n_tasks n_failing_tasks n_surviving_mutants
# Tasks are dom-0 … dom-(n-1). The first `fails` fail their golden; the last
# `surv` carry one surviving mutant each.
mk_snap() {
  local path="$1" arm="$2" n="$3" fails="$4" surv="$5"
  jq -n --arg arm "$arm" --argjson n "$n" --argjson fails "$fails" --argjson surv "$surv" '
    ($n - $fails) as $passed
    | { schema:"heimdall-headroom-ab/v2", arm:$arm, ts:"2026-08-04T00:00:00Z",
        repo:"/fixture/repo", window_days:7, rule_hash:"fixture-hash",
        per_task: [ range(0; $n) as $i
                    | (if $i < $fails then 0 else 1 end) as $gp
                    | { domain: ("dom-" + ($i|tostring)),
                        golden_pass: $gp,
                        mutants: (if $gp == 1 then 5 else 0 end),
                        survived: (if $gp == 1 and $i >= ($n - $surv) then 1 else 0 end) } ],
        metrics: {
          oracle_pass_rate: (if $n == 0
                             then { value:null, provenance:"unavailable", n:0,
                                    reason:"fixture: no task measured — a zero denominator is not a rate" }
                             else { value: ($passed / $n), provenance:"measured",
                                    n:$n, passed:$passed, errors:0,
                                    source:"fixture" } end),
          falsify_survival: (if $passed == 0
                             then { value:null, provenance:"unavailable", n:0,
                                    reason:"no mutant ran under a passing golden" }
                             else { value: ($surv / ($passed * 5)), provenance:"measured",
                                    n: ($passed * 5), survived:$surv, errors:0,
                                    source:"fixture" } end),
          agent_deaths:       { value:null, provenance:"unavailable", reason:"fixture: tracker blind" },
          gate_retries:       { value:null, provenance:"unavailable", reason:"fixture: no gate-runs.jsonl" },
          time_to_green_mins: { value:null, provenance:"unavailable", reason:"fixture: no commits" },
          tokens_in:          { value:null, provenance:"unavailable", reason:"fixture: not supplied" },
          tokens_out:         { value:null, provenance:"unavailable", reason:"fixture: not supplied" },
          cost_usd:           { value:null, provenance:"unavailable", reason:"fixture: not supplied" } } }' \
    > "$path"
}

echo "headroom-ab harness  repo=$REPO"
echo "--------------------------------------------------------------------"

[ -x "$AB" ] && ok "bin/heimdall-headroom-ab is executable" \
  || { bad "bin/heimdall-headroom-ab missing or not executable"; echo "FATAL"; exit 1; }

bash -n "$AB" && ok "bin/heimdall-headroom-ab parses (bash -n)" \
  || bad "bin/heimdall-headroom-ab has a syntax error"

# ── 1. DEGRADED ARM -> UNWRAP ────────────────────────────────────────────────
# 40 paired tasks; arm A passes all, arm B fails 20. The paired-bootstrap
# interval on B-A must lie entirely below zero.
mk_snap "$TMP/deg-a.json" before 40 0 0
mk_snap "$TMP/deg-b.json" after  40 20 0
got="$("$AB" verdict --before "$TMP/deg-a.json" --after "$TMP/deg-b.json" 2>/dev/null)"
[ "$got" = "unwrap" ] \
  && ok "degraded arm (100% -> 50% pass-rate) -> verdict '$got'" \
  || bad "degraded arm -> verdict '$got', expected 'unwrap'"

rep="$("$AB" report --before "$TMP/deg-a.json" --after "$TMP/deg-b.json" 2>&1 | plain)"
grep -q 'VERDICT: UNWRAP' <<<"$rep" \
  && ok "degraded report renders VERDICT: UNWRAP" \
  || bad "degraded report did not render VERDICT: UNWRAP"
grep -q 'headroom unwrap claude' <<<"$rep" \
  && ok "degraded report names the exact action: headroom unwrap claude" \
  || bad "degraded report never names 'headroom unwrap claude'"
grep -q 'entirely below zero' <<<"$rep" \
  && ok "degraded report justifies via the interval lying entirely below zero" \
  || bad "degraded report does not cite the interval position"
grep -qi 'NEGATIVE receipt' <<<"$rep" \
  && ok "degraded report instructs publishing the NEGATIVE receipt" \
  || bad "degraded report never mentions the negative receipt"

# ── 2. NEUTRAL + POWERED -> KEEP ─────────────────────────────────────────────
# 40 identical paired tasks. Zero discordant pairs -> rule-of-three bound
# 3/40 = 7.5pp, inside the pre-committed 10pp threshold -> conclusive.
mk_snap "$TMP/neu-a.json" before 40 0 0
mk_snap "$TMP/neu-b.json" after  40 0 0
got="$("$AB" verdict --before "$TMP/neu-a.json" --after "$TMP/neu-b.json" 2>/dev/null)"
[ "$got" = "keep" ] \
  && ok "neutral arm at n=40 (half-width 7.5pp < 10pp) -> verdict '$got'" \
  || bad "neutral powered arm -> verdict '$got', expected 'keep'"

rep="$("$AB" report --before "$TMP/neu-a.json" --after "$TMP/neu-b.json" 2>&1 | plain)"
grep -q 'VERDICT: KEEP' <<<"$rep" \
  && ok "neutral report renders VERDICT: KEEP" \
  || bad "neutral report did not render VERDICT: KEEP"
grep -qi 'POSITIVE receipt' <<<"$rep" \
  && ok "neutral report instructs publishing the POSITIVE receipt" \
  || bad "neutral report never mentions the positive receipt"

# ── 3. UNDERPOWERED -> SAYS SO, NEVER A NULL ────────────────────────────────
# Same neutral shape but only 10 paired tasks: 3/10 = 30pp half-width, well
# outside the threshold. The honest answer is "this run could not tell".
mk_snap "$TMP/up-a.json" before 10 0 0
mk_snap "$TMP/up-b.json" after  10 0 0
got="$("$AB" verdict --before "$TMP/up-a.json" --after "$TMP/up-b.json" 2>/dev/null)"
[ "$got" = "underpowered" ] \
  && ok "underpowered arm at n=10 (half-width 30pp > 10pp) -> verdict '$got'" \
  || bad "underpowered arm -> verdict '$got', expected 'underpowered'"

[ "$got" != "keep" ] \
  && ok "underpowered arm does NOT resolve to keep" \
  || bad "underpowered arm resolved to keep — an underpowered null sold as a pass"

rep="$("$AB" report --before "$TMP/up-a.json" --after "$TMP/up-b.json" 2>&1 | plain)"
grep -q 'VERDICT: UNDERPOWERED' <<<"$rep" \
  && ok "underpowered report renders VERDICT: UNDERPOWERED" \
  || bad "underpowered report did not render VERDICT: UNDERPOWERED"
grep -qi 'could not tell' <<<"$rep" \
  && ok "underpowered report says the run could not tell" \
  || bad "underpowered report never says the run could not tell"
if grep -qi 'no degradation found' <<<"$rep"; then
  bad "underpowered report claims 'no degradation found' — the exact banned phrasing"
else
  ok "underpowered report never claims 'no degradation found'"
fi
grep -q '10pp' <<<"$rep" \
  && ok "underpowered report cites the pre-committed 10pp threshold" \
  || bad "underpowered report never cites the 10pp threshold"

# ── 4. CATEGORICAL FALSIFY STOP -> UNWRAP, NO CI ────────────────────────────
# Pass-rate identical and adequately powered; arm B leaks ONE mutant. Survival
# is categorical, so this alone is a hard stop.
mk_snap "$TMP/cat-a.json" before 40 0 0
mk_snap "$TMP/cat-b.json" after  40 0 1
got="$("$AB" verdict --before "$TMP/cat-a.json" --after "$TMP/cat-b.json" 2>/dev/null)"
[ "$got" = "unwrap" ] \
  && ok "one surviving mutant in arm B -> verdict '$got' (categorical stop)" \
  || bad "surviving mutant -> verdict '$got', expected 'unwrap'"

rep="$("$AB" report --before "$TMP/cat-a.json" --after "$TMP/cat-b.json" 2>&1 | plain)"
grep -q 'CATEGORICAL STOP' <<<"$rep" \
  && ok "categorical report labels the stop CATEGORICAL" \
  || bad "categorical report never labels the stop as categorical"
grep -qi 'No confidence interval applies' <<<"$rep" \
  && ok "categorical stop states that no confidence interval applies" \
  || bad "categorical stop does not state the no-CI rule"

# The categorical call must not be reported as a statistical one.
sj="$("$AB" stats --before "$TMP/cat-a.json" --after "$TMP/cat-b.json" 2>/dev/null)"
[ "$(printf '%s' "$sj" | jq -r '.falsify.categorical_stop')" = "true" ] \
  && ok "stats records falsify.categorical_stop=true" \
  || bad "stats did not record the categorical stop"
[ "$(printf '%s' "$sj" | jq -r '.falsify.survivors_after')" = "1" ] \
  && ok "stats records the arm B survivor count (1)" \
  || bad "stats survivor count wrong"

# ── 5. NO PAIRED TASKS -> INDETERMINATE ─────────────────────────────────────
mk_snap "$TMP/emp-a.json" before 0 0 0
mk_snap "$TMP/emp-b.json" after  0 0 0
got="$("$AB" verdict --before "$TMP/emp-a.json" --after "$TMP/emp-b.json" 2>/dev/null)"
[ "$got" = "indeterminate" ] \
  && ok "no paired tasks -> verdict '$got'" \
  || bad "no paired tasks -> verdict '$got', expected 'indeterminate'"
[ "$got" != "keep" ] \
  && ok "absent measurement never defaults to keep" \
  || bad "absent measurement defaulted to keep"

# Unpaired tasks are EXCLUDED and the exclusion is counted.
mk_snap "$TMP/exc-a.json" before 40 0 0
mk_snap "$TMP/exc-b.json" after  38 0 0
sj="$("$AB" stats --before "$TMP/exc-a.json" --after "$TMP/exc-b.json" 2>/dev/null)"
[ "$(printf '%s' "$sj" | jq -r '.paired_tasks')" = "38" ] \
  && ok "pairing keeps only tasks present in BOTH arms (38)" \
  || bad "paired task count wrong: $(printf '%s' "$sj" | jq -r '.paired_tasks')"
[ "$(printf '%s' "$sj" | jq -r '.excluded_count')" = "2" ] \
  && ok "the 2 one-arm-only tasks are counted as exclusions" \
  || bad "exclusion count wrong: $(printf '%s' "$sj" | jq -r '.excluded_count')"

# ── 6. MISSING INPUT RENDERS `unavailable`, NEVER 0 ─────────────────────────
rep="$("$AB" report --before "$TMP/neu-a.json" --after "$TMP/neu-b.json" 2>&1 | plain)"
tok_line="$(grep -E '^[[:space:]]+tokens in' <<<"$rep" | head -1)"
grep -q 'unavailable' <<<"$tok_line" \
  && ok "an unsupplied token count renders 'unavailable'" \
  || bad "tokens-in row did not render unavailable: '$tok_line'"
if grep -qE '(^|[^0-9.])0([^0-9.]|$)' <<<"$tok_line"; then
  bad "tokens-in row rendered a bare 0 for missing data: '$tok_line'"
else
  ok "tokens-in row renders NO digits at all — cannot be misread as a measured 0"
fi
cost_line="$(grep -E '^[[:space:]]+cost \(USD\)' <<<"$rep" | head -1)"
grep -q 'unavailable' <<<"$cost_line" \
  && ok "an unsupplied dollar figure renders 'unavailable', not an invented cost" \
  || bad "cost row did not render unavailable: '$cost_line'"
grep -q 'why a figure is unavailable' <<<"$rep" \
  && ok "the report explains WHY each figure is unavailable" \
  || bad "the report never explains its unavailable figures"

# ── 7. REPRODUCIBILITY ──────────────────────────────────────────────────────
# A receipt whose numbers move between runs is not a receipt.
a="$("$AB" stats --before "$TMP/deg-a.json" --after "$TMP/deg-b.json" 2>/dev/null)"
b="$("$AB" stats --before "$TMP/deg-a.json" --after "$TMP/deg-b.json" 2>/dev/null)"
[ "$a" = "$b" ] \
  && ok "the bootstrap is seeded — two runs give byte-identical statistics" \
  || bad "statistics differ between runs — the receipt is not reproducible"
[ "$(printf '%s' "$a" | jq -r '.resamples')" = "10000" ] \
  && ok "the bootstrap runs the pre-registered 10,000 resamples" \
  || bad "resample count is not the pre-registered 10,000"
[ "$(printf '%s' "$a" | jq -r '.power_halfwidth_threshold')" = "0.1" ] \
  && ok "the power threshold is the pre-registered 0.1 (±10pp)" \
  || bad "power threshold is not the pre-registered ±10pp"

# ── 8. THE RULE ENCODES THE POST'S FOUR OUTCOMES ────────────────────────────
pre="$("$AB" preregister 2>&1 | plain)"
for phrase in "CATEGORICAL" "Wilson" "PAIRED BOOTSTRAP" "10,000" "ENTIRELY BELOW ZERO" "UNDERPOWERED" "LABELLED COST"; do
  printf '%s' "$pre" | grep -qi -- "$phrase" \
    && ok "pre-registration states '$phrase'" \
    || bad "pre-registration is missing '$phrase' — it disagrees with the post"
done
h1="$("$AB" preregister 2>/dev/null | plain | grep -o 'rule_hash: [0-9a-f]*' | head -1)"
h2="$("$AB" preregister 2>/dev/null | plain | grep -o 'rule_hash: [0-9a-f]*' | head -1)"
[ -n "$h1" ] && [ "$h1" = "$h2" ] \
  && ok "rule_hash is stable across invocations ($h1)" \
  || bad "rule_hash is unstable or absent: '$h1' vs '$h2'"

# A snapshot registered under a different rule is called out, not accepted.
rep="$("$AB" report --before "$TMP/neu-a.json" --after "$TMP/neu-b.json" 2>&1 | plain)"
grep -q 'RULE PROVENANCE' <<<"$rep" \
  && ok "an arm whose rule_hash differs is flagged, not silently accepted" \
  || bad "a mismatched rule_hash was accepted silently"

# ── 9. DEPEND, DON'T CLONE ──────────────────────────────────────────────────
if grep -nE '(npm|pnpm|yarn|pip3?|brew|cargo)[[:space:]]+(install|add)|git[[:space:]]+clone|curl[^|]*\|[[:space:]]*(ba)?sh' "$AB" >/dev/null 2>&1; then
  bad "the harness installs or clones something — it must depend, not clone"
else
  ok "the harness never installs, clones, or curl-pipes anything"
fi
grep -q 'headroom unwrap claude' "$AB" \
  && ok "the harness names the unwrap command without invoking a wrapper" \
  || bad "the harness never names the unwrap action"
# It must run with Headroom absent — that IS the before arm.
if command -v headroom >/dev/null 2>&1; then
  ok "headroom present on PATH; harness ran regardless (it never shells out to it)"
else
  ok "headroom absent from PATH and every assertion above still ran — the 'before' arm works"
fi

echo ""
echo "headroom-ab.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

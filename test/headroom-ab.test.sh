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
#  10. CLAUSE (a) IS IMPLEMENTED, NOT JUST PRINTED — a decision metric that was
#      never MEASURED in an arm resolves to INDETERMINATE and never to KEEP.
#      Its inseparable other half: a genuinely-measured run still resolves, so
#      the guard cannot be satisfied by answering `indeterminate` to everything.
#  11. A missing or null golden result is a VERDICT, not a Python traceback.
#  12. `verdict` never prints an empty line — an uncomputable comparison fails
#      CLOSED with a named error and a nonzero exit.
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
printf '%s' "$rep" | grep -q 'VERDICT: UNWRAP' \
  && ok "degraded report renders VERDICT: UNWRAP" \
  || bad "degraded report did not render VERDICT: UNWRAP"
printf '%s' "$rep" | grep -q 'headroom unwrap claude' \
  && ok "degraded report names the exact action: headroom unwrap claude" \
  || bad "degraded report never names 'headroom unwrap claude'"
printf '%s' "$rep" | grep -q 'entirely below zero' \
  && ok "degraded report justifies via the interval lying entirely below zero" \
  || bad "degraded report does not cite the interval position"
printf '%s' "$rep" | grep -qi 'NEGATIVE receipt' \
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
printf '%s' "$rep" | grep -q 'VERDICT: KEEP' \
  && ok "neutral report renders VERDICT: KEEP" \
  || bad "neutral report did not render VERDICT: KEEP"
printf '%s' "$rep" | grep -qi 'POSITIVE receipt' \
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
printf '%s' "$rep" | grep -q 'VERDICT: UNDERPOWERED' \
  && ok "underpowered report renders VERDICT: UNDERPOWERED" \
  || bad "underpowered report did not render VERDICT: UNDERPOWERED"
printf '%s' "$rep" | grep -qi 'could not tell' \
  && ok "underpowered report says the run could not tell" \
  || bad "underpowered report never says the run could not tell"
if printf '%s' "$rep" | grep -qi 'no degradation found'; then
  bad "underpowered report claims 'no degradation found' — the exact banned phrasing"
else
  ok "underpowered report never claims 'no degradation found'"
fi
printf '%s' "$rep" | grep -q '10pp' \
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
printf '%s' "$rep" | grep -q 'CATEGORICAL STOP' \
  && ok "categorical report labels the stop CATEGORICAL" \
  || bad "categorical report never labels the stop as categorical"
printf '%s' "$rep" | grep -qi 'No confidence interval applies' \
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
tok_line="$(printf '%s\n' "$rep" | grep -E '^[[:space:]]+tokens in' | head -1)"
printf '%s' "$tok_line" | grep -q 'unavailable' \
  && ok "an unsupplied token count renders 'unavailable'" \
  || bad "tokens-in row did not render unavailable: '$tok_line'"
if printf '%s' "$tok_line" | grep -qE '(^|[^0-9.])0([^0-9.]|$)'; then
  bad "tokens-in row rendered a bare 0 for missing data: '$tok_line'"
else
  ok "tokens-in row renders NO digits at all — cannot be misread as a measured 0"
fi
cost_line="$(printf '%s\n' "$rep" | grep -E '^[[:space:]]+cost \(USD\)' | head -1)"
printf '%s' "$cost_line" | grep -q 'unavailable' \
  && ok "an unsupplied dollar figure renders 'unavailable', not an invented cost" \
  || bad "cost row did not render unavailable: '$cost_line'"
printf '%s' "$rep" | grep -q 'why a figure is unavailable' \
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
printf '%s' "$rep" | grep -q 'RULE PROVENANCE' \
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

# ── 10. CLAUSE (a): AN UNMEASURED DECISION METRIC IS INDETERMINATE ──────────
# The rule's FIRST clause — "a decision metric unavailable in either arm ->
# INDETERMINATE … an absent measurement is NOT evidence of success and must
# never resolve to KEEP by default" — was printed by `preregister` and never
# implemented. Only ONE availability case was checked (no task ran in both
# arms), so an arm that swept ZERO mutants sailed past every other clause and
# landed on KEEP, publishing the POSITIVE receipt for a metric it never measured.
#
# THE TWO HALVES ARE INSEPARABLE. 10a proves the blind arm now stops. 10b proves
# a genuinely-measured run still resolves; without it, `verdict() { echo
# indeterminate; }` would pass 10a and gut the harness.

# A snapshot whose per_task records are supplied verbatim — the shapes mk_snap
# cannot express: a PASSING golden that swept zero mutants, and a task carrying
# no golden result at all.
mk_raw() {  # path arm per_task_json
  jq -n --arg arm "$2" --argjson pt "$3" '
    { schema:"heimdall-headroom-ab/v2", arm:$arm, ts:"2026-08-04T00:00:00Z",
      repo:"/fixture/repo", window_days:7, rule_hash:"fixture-hash",
      per_task: $pt,
      metrics: {
        oracle_pass_rate:   { value:null, provenance:"unavailable", n:0, reason:"fixture" },
        falsify_survival:   { value:null, provenance:"unavailable", n:0, reason:"fixture" },
        agent_deaths:       { value:null, provenance:"unavailable", reason:"fixture" },
        gate_retries:       { value:null, provenance:"unavailable", reason:"fixture" },
        time_to_green_mins: { value:null, provenance:"unavailable", reason:"fixture" },
        tokens_in:          { value:null, provenance:"unavailable", reason:"fixture" },
        tokens_out:         { value:null, provenance:"unavailable", reason:"fixture" },
        cost_usd:           { value:null, provenance:"unavailable", reason:"fixture" } } }' > "$1"
}
# $1 tasks, every golden PASSING, each sweeping $2 mutants with no survivors.
pt_swept()    { jq -cn --argjson n "$1" --argjson m "$2" \
  '[range(0;$n) | {domain:"d\(.)", golden_pass:1, mutants:$m, survived:0}]'; }
pt_nogold()   { jq -cn --argjson n "$1" \
  '[range(0;$n) | {domain:"d\(.)", mutants:5, survived:0}]'; }
pt_nullgold() { jq -cn --argjson n "$1" \
  '[range(0;$n) | {domain:"d\(.)", golden_pass:null, mutants:5, survived:0}]'; }

# ── 10a. THE REPRODUCER: arm B swept ZERO mutants ───────────────────────────
mk_raw "$TMP/zm-a.json" before "$(pt_swept 30 10)"
mk_raw "$TMP/zm-b.json" after  "$(pt_swept 30 0)"
got="$("$AB" verdict --before "$TMP/zm-a.json" --after "$TMP/zm-b.json" 2>/dev/null)"
[ "$got" = "indeterminate" ] \
  && ok "arm B swept ZERO mutants -> verdict '$got' (clause (a))" \
  || bad "arm B swept zero mutants -> verdict '$got', expected 'indeterminate'"
[ "$got" != "keep" ] \
  && ok "a decision metric that was never measured never resolves to KEEP" \
  || bad "zero mutants resolved to KEEP — an unmeasured metric sold as a pass"

sj="$("$AB" stats --before "$TMP/zm-a.json" --after "$TMP/zm-b.json" 2>/dev/null)"
[ "$(printf '%s' "$sj" | jq -r '.availability.falsify_survival.after.available')" = "false" ] \
  && ok "stats records falsify survival as UNAVAILABLE in arm B" \
  || bad "stats did not mark the blind arm unavailable"
[ "$(printf '%s' "$sj" | jq -r '.availability.falsify_survival.before.available')" = "true" ] \
  && ok "…and AVAILABLE in arm A, which really did sweep 300 mutants" \
  || bad "arm A was wrongly marked unavailable"
printf '%s' "$sj" | jq -r '.availability.falsify_survival.after.reason' | grep -q 'arm B' \
  && ok "the availability reason names the ARM" \
  || bad "the availability reason does not name the arm"
printf '%s' "$sj" | jq -r '.availability.falsify_survival.after.reason' | grep -qi 'falsify survival' \
  && ok "the availability reason names the METRIC" \
  || bad "the availability reason does not name the metric"
# The evidence of the blindness must survive onto the receipt, not be dropped.
[ "$(printf '%s' "$sj" | jq -r '.falsify.mutants_before')" = "300" ] \
  && ok "the receipt still carries arm A's 300 swept mutants" \
  || bad "mutants_before was dropped from the indeterminate receipt"
[ "$(printf '%s' "$sj" | jq -r '.falsify.mutants_after')" = "0" ] \
  && ok "…beside arm B's 0 — the evidence FOR the verdict stays on the receipt" \
  || bad "mutants_after was dropped from the indeterminate receipt"

rep="$("$AB" report --before "$TMP/zm-a.json" --after "$TMP/zm-b.json" 2>&1 | plain)"
printf '%s' "$rep" | grep -q 'VERDICT: INDETERMINATE' \
  && ok "the blind-arm report renders VERDICT: INDETERMINATE" \
  || bad "the blind-arm report did not render INDETERMINATE"
printf '%s' "$rep" | grep -q 'NOT MEASURED' \
  && ok "the report flags the metric NOT MEASURED beside the decision rows" \
  || bad "the report never says the decision metric was not measured"
printf '%s' "$rep" | grep -qi 'Publish NEITHER receipt' \
  && ok "the blind-arm report withholds BOTH receipts" \
  || bad "the blind-arm report does not withhold both receipts"
if printf '%s' "$rep" | grep -q 'VERDICT: KEEP'; then
  bad "the blind-arm report still renders VERDICT: KEEP"
else
  ok "the blind-arm report never renders KEEP"
fi

# ── 10b. PROVE-NARROW: a genuinely-measured run still resolves ──────────────
mk_raw "$TMP/msr-a.json" before "$(pt_swept 40 5)"
mk_raw "$TMP/msr-b.json" after  "$(pt_swept 40 5)"
got="$("$AB" verdict --before "$TMP/msr-a.json" --after "$TMP/msr-b.json" 2>/dev/null)"
[ "$got" = "keep" ] \
  && ok "a MEASURED neutral run (200 mutants in both arms) still -> verdict '$got'" \
  || bad "a measured neutral run -> '$got', expected 'keep' — the guard is too broad"
sj="$("$AB" stats --before "$TMP/msr-a.json" --after "$TMP/msr-b.json" 2>/dev/null)"
[ "$(printf '%s' "$sj" | jq -r '[.availability[][] | select(.available==false)] | length')" = "0" ] \
  && ok "both decision metrics report AVAILABLE in both arms when both really ran" \
  || bad "a fully-measured run still reported an unavailable metric"

# The other half of narrow: a golden that FAILED legitimately sweeps 0 mutants —
# bin/falsify emits 0/0 without a passing golden. That zero is EXPLAINED by a
# measurement, and must not be laundered into 'indeterminate'; the degraded arm
# still has to publish its NEGATIVE receipt.
sj="$("$AB" stats --before "$TMP/deg-a.json" --after "$TMP/deg-b.json" 2>/dev/null)"
[ "$(printf '%s' "$sj" | jq -r '.availability.falsify_survival.after.available')" = "true" ] \
  && ok "a FAILED golden's zero mutants is explained, not counted as blindness" \
  || bad "a measured golden failure was misread as an unmeasured falsify sweep"
got="$("$AB" verdict --before "$TMP/deg-a.json" --after "$TMP/deg-b.json" 2>/dev/null)"
[ "$got" = "unwrap" ] \
  && ok "…so the degraded arm still resolves to '$got', not indeterminate" \
  || bad "clause (a) swallowed a real degradation: verdict '$got'"

# ── 11. A MISSING GOLDEN RESULT IS A VERDICT, NOT A TRACEBACK ───────────────
# `bt[d]["golden_pass"]` on a snapshot missing the key raised KeyError: exit 1
# with EMPTY stdout, which `verdict` piped into jq and printed as a BLANK line.
mk_raw "$TMP/ng-a.json" before "$(pt_swept 30 5)"
mk_raw "$TMP/ng-b.json" after  "$(pt_nogold 30)"
got="$("$AB" verdict --before "$TMP/ng-a.json" --after "$TMP/ng-b.json" 2>/dev/null)"
[ "$got" = "indeterminate" ] \
  && ok "a MISSING golden result -> verdict '$got'" \
  || bad "missing golden result -> verdict '$got', expected 'indeterminate'"
err="$("$AB" verdict --before "$TMP/ng-a.json" --after "$TMP/ng-b.json" 2>&1 >/dev/null)"
if printf '%s' "$err" | grep -q 'Traceback'; then
  bad "a missing golden result still raises a Python traceback"
else
  ok "a missing golden result raises NO traceback — it is graded, not crashed on"
fi
sj="$("$AB" stats --before "$TMP/ng-a.json" --after "$TMP/ng-b.json" 2>/dev/null)"
[ "$(printf '%s' "$sj" | jq -r '.availability.oracle_pass_rate.after.available')" = "false" ] \
  && ok "stats marks the oracle pass-rate unavailable in the arm that lost it" \
  || bad "the missing golden was not recorded as an availability failure"
printf '%s' "$sj" | jq -r '.availability.oracle_pass_rate.after.reason' | grep -q 'arm B' \
  && ok "the oracle availability reason names arm B" \
  || bad "the oracle availability reason does not name the arm"

mk_raw "$TMP/nl-b.json" after "$(pt_nullgold 30)"
got="$("$AB" verdict --before "$TMP/ng-a.json" --after "$TMP/nl-b.json" 2>/dev/null)"
[ "$got" = "indeterminate" ] \
  && ok "a NULL golden result -> verdict '$got' (null is absence, not a fail)" \
  || bad "null golden result -> verdict '$got', expected 'indeterminate'"

# The report must not explain this as a pairing failure — there ARE 30 pairs.
rep="$("$AB" report --before "$TMP/ng-a.json" --after "$TMP/ng-b.json" 2>&1 | plain)"
if printf '%s' "$rep" | grep -q 'no paired tasks'; then
  bad "the report blames a pairing failure on a run that paired 30 tasks"
else
  ok "the report does not invent a pairing failure to explain a missing golden"
fi

# ── 12. `verdict` NEVER PRINTS AN EMPTY LINE ────────────────────────────────
# A blank verdict is the worst output this tool can emit: `$(… verdict …)` gives
# "" and every comparison against it is false, so a caller silently takes
# whichever branch it happened to write first.
verdict_is_a_word() {  # before after label
  local out rc
  out="$("$AB" verdict --before "$1" --after "$2" 2>/dev/null)"; rc=$?
  case "$out" in
    keep|unwrap|underpowered|indeterminate)
      ok "verdict on $3 is a word, never blank ('$out', exit $rc)" ;;
    "") bad "verdict on $3 printed an EMPTY line (exit $rc)" ;;
    *)  bad "verdict on $3 printed an unknown token '$out' (exit $rc)" ;;
  esac
}
verdict_is_a_word "$TMP/zm-a.json"  "$TMP/zm-b.json"  "the zero-mutant arm"
verdict_is_a_word "$TMP/ng-a.json"  "$TMP/ng-b.json"  "the missing-golden arm"
verdict_is_a_word "$TMP/msr-a.json" "$TMP/msr-b.json" "the fully-measured arm"
verdict_is_a_word "$TMP/emp-a.json" "$TMP/emp-b.json" "the unpaired arm"

# …including when the statistics cannot be computed AT ALL. `require_snap` only
# asserts `.metrics` exists, so a truncated arm whose per_task is not a list of
# task records reaches the grader intact. It must fail CLOSED — a named error
# and a nonzero exit — never a blank line with exit 0.
jq -n '{schema:"heimdall-headroom-ab/v2", arm:"after", metrics:{}, per_task:["truncated"]}' \
  > "$TMP/broken-b.json"
out="$("$AB" verdict --before "$TMP/msr-a.json" --after "$TMP/broken-b.json" 2>/dev/null)"; rc=$?
[ "$out" = "indeterminate" ] \
  && ok "an uncomputable comparison prints 'indeterminate', not a blank line" \
  || bad "an uncomputable comparison printed '$out'"
[ "$rc" -ne 0 ] \
  && ok "…and exits nonzero ($rc), so a caller cannot read it as a graded run" \
  || bad "an uncomputable comparison exited 0 — it looks like a successful grade"
err="$("$AB" verdict --before "$TMP/msr-a.json" --after "$TMP/broken-b.json" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -qi 'could not be computed' \
  && ok "the computation failure is NAMED on stderr, not swallowed" \
  || bad "the computation failure is silent on stderr"

echo ""
echo "headroom-ab.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

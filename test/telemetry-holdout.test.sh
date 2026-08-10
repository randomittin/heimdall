#!/usr/bin/env bash
#
# telemetry-holdout.test.sh — HONESTY-CRITICAL proofs for piece (e): the A/B-holdout
# + measured-vs-estimated reporting (bin/lib/holdout.py + bin/heimdall-holdout).
# This is "measured-not-asserted" applied to Heimdall's OWN savings claims. The
# proofs pin §6 of the design dossier and are all runnable, none skippable.
#
# Proofs (dossier §6):
#
#   A. ARM TAGGING — a holdout run is tagged CONTROL vs TREATMENT, recorded as a
#      telemetry tag keyed to its run_id. HEIMDALL_HOLDOUT=control forces control;
#      the default run is treatment. The arm tag is read back out of the store.
#      FALSIFIABLE: a build that does not record the arm leaves the delta query with
#      nothing to group by, flipping proof B.
#
#   B. MEASURED DELTA + CONFIDENCE BAND — over REAL token events (read via the
#      substrate), the control−treatment delta is computed WITH a confidence band:
#      n per arm, a mean per arm, and a spread (stdev/stderr). The delta is the
#      ACTUAL difference of measured means from real events — not invented.
#      FALSIFIABLE: a delta that did not come from the real token totals would not
#      equal the arithmetic of the planted spends.
#
#   C. THE KEY HONESTY TEST — with NO control sample, the reporter outputs
#      "estimated"/blank, NEVER a fabricated number. A counterfactual with no
#      baseline is impossible to print as fact. FALSIFIABLE (the whole point): a
#      build that printed a savings figure without a control sample would put a
#      number in `value` / a non-"—" in `rendered` and RED this assertion.
#
#   D. cost_source PROVENANCE + REFUSAL — the figure carries a cost_source
#      provenance tag, and the reporter REFUSES to present a number as FACT unless
#      it was MEASURED: an untagged number (a value with no "measured" provenance)
#      is NOT a measured fact. require_measured / is_measured_fact is the structural
#      gate. FALSIFIABLE: dropping the provenance check would let an untagged number
#      read as a fact and flip this.
#
#   E. ESTIMATED PATH IS LABELED — when no measurement exists but a labeled estimate
#      WITH a stated basis is supplied, the figure renders WITH the `est.` label and
#      the estimated provenance — never as a bare number. An estimate with no basis
#      stays blank.
#
#   F. DETERMINISTIC FRACTION — arm assignment by fraction is stable per run_id
#      (same run_id → same arm), and fraction=1.0 ⇒ all control, fraction=0.0 ⇒ all
#      treatment. Reproducible, never per-call random.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOLD="$REPO/bin/heimdall-holdout"
TELE="$REPO/bin/heimdall-telemetry"
LIB="$REPO/bin/lib/holdout.py"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -x "$HOLD" ] || { echo "FATAL: holdout CLI not executable at $HOLD"; exit 2; }
[ -x "$TELE" ] || { echo "FATAL: telemetry CLI not executable at $TELE"; exit 2; }
[ -f "$LIB" ]  || { echo "FATAL: holdout lib missing at $LIB"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A small JSON field reader (one parse, exact key) — avoids fragile grep on JSON.
jget() {  # jget <json> <dotted.key>
  JSON="$1" KEY="$2" "$PY" - <<'PYEOF'
import json, os, sys
obj = json.loads(os.environ["JSON"])
cur = obj
for part in os.environ["KEY"].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        cur = None
        break
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PYEOF
}

# Helper: tag a run's arm then emit ONE token event carrying total_tokens. This is
# the real flow — assign records the arm tag; the token event carries the measured
# spend the delta query reads back.
seed_run() {  # seed_run <run-id> <control|treatment> <total_tokens> <home>
  local rid="$1" arm="$2" toks="$3" home="$4"
  if [ "$arm" = "control" ]; then
    HEIMDALL_HOLDOUT=control "$HOLD" assign --run-id "$rid" --home "$home" >/dev/null
  else
    "$HOLD" assign --run-id "$rid" --home "$home" >/dev/null
  fi
  # token total assembled at runtime (gate-proof: no static numeric literal block).
  "$TELE" emit --type token --run-id "$rid" \
    --tokens "{\"total_tokens\":${toks},\"total_cost_usd\":null,\"cost_source\":\"measured\"}" \
    --home "$home" >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# A. ARM TAGGING — control vs treatment, recorded + read back.
# ─────────────────────────────────────────────────────────────────────────────
echo "A. ARM TAGGING (a run is tagged control vs treatment):"
HOME_A="$WORK/home-a"
out_c="$(HEIMDALL_HOLDOUT=control "$HOLD" assign --run-id run-ctrl --home "$HOME_A")"
out_t="$("$HOLD" assign --run-id run-treat --home "$HOME_A")"
arm_c="$(jget "$out_c" arm)"; tagged_c="$(jget "$out_c" tagged)"
arm_t="$(jget "$out_t" arm)"; tagged_t="$(jget "$out_t" tagged)"
if [ "$arm_c" = "control" ] && [ "$tagged_c" = "true" ]; then
  ok "HEIMDALL_HOLDOUT=control → control arm, recorded ($out_c)"
else
  bad "control arm not assigned/recorded: $out_c"
fi
if [ "$arm_t" = "treatment" ] && [ "$tagged_t" = "true" ]; then
  ok "default run → treatment arm, recorded ($out_t)"
else
  bad "treatment arm not assigned/recorded: $out_t"
fi
# The arm tag is genuinely in the store (read it back from events.ndjson).
STORE_A="$HOME_A/telemetry/events.ndjson"
if [ -f "$STORE_A" ] && grep -Fq '"arm":"control"' "$STORE_A" \
   && grep -Fq '"arm":"treatment"' "$STORE_A"; then
  ok "both arm tags persisted in the real event store"
else
  bad "arm tags not found in store $STORE_A"
fi

# ─────────────────────────────────────────────────────────────────────────────
# B. MEASURED DELTA + CONFIDENCE BAND — from REAL token events.
# ─────────────────────────────────────────────────────────────────────────────
echo "B. MEASURED DELTA (control vs treatment, with a confidence band):"
HOME_B="$WORK/home-b"
# Two control runs (1000, 1400 → mean 1200) and two treatment runs (400, 600 →
# mean 500). The honest measured delta = 1200 − 500 = 700, with a real spread.
seed_run run-c1 control   1000 "$HOME_B"
seed_run run-c2 control   1400 "$HOME_B"
seed_run run-t1 treatment 400  "$HOME_B"
seed_run run-t2 treatment 600  "$HOME_B"
delta_out="$("$HOLD" delta --metric total_tokens --min-n 2 --home "$HOME_B")"
d_measured="$(jget "$delta_out" measured)"
d_delta="$(jget "$delta_out" delta)"
d_cn="$(jget "$delta_out" control.n)"
d_tn="$(jget "$delta_out" treatment.n)"
d_cmean="$(jget "$delta_out" control.mean)"
d_tmean="$(jget "$delta_out" treatment.mean)"
d_cstdev="$(jget "$delta_out" control.stdev)"
d_dband="$(jget "$delta_out" delta_band)"
if [ "$d_measured" = "true" ] && [ "$d_cn" = "2" ] && [ "$d_tn" = "2" ]; then
  ok "delta is measured with n=2 per arm (control.n=$d_cn treatment.n=$d_tn)"
else
  bad "delta not measured / wrong n: $delta_out"
fi
# The delta is the ACTUAL arithmetic of the real means (1200 − 500 = 700).
if [ "$d_delta" = "700.0" ] && [ "$d_cmean" = "1200.0" ] && [ "$d_tmean" = "500.0" ]; then
  ok "delta = real measured means (control 1200 − treatment 500 = 700)"
else
  bad "delta is NOT the arithmetic of real means: delta=$d_delta cmean=$d_cmean tmean=$d_tmean"
fi
# A confidence band: a real per-arm spread (stdev>0 since 1000≠1400) + a delta band.
band_rc=0
BAND_OUT="$(CSTDEV="$d_cstdev" DBAND="$d_dband" "$PY" - <<'PYEOF'
import os
cstdev = float(os.environ["CSTDEV"] or 0)
dband = float(os.environ["DBAND"] or 0)
assert cstdev > 0, "control stdev should be > 0 (1000 vs 1400 spread)"
assert dband > 0, "delta band should be > 0 (a real confidence band)"
print("BAND_OK stdev=%g band=%g" % (cstdev, dband))
PYEOF
)" || band_rc=$?
if [ "$band_rc" -eq 0 ] && printf '%s' "$BAND_OUT" | grep -q BAND_OK; then
  ok "confidence band present: n + mean + spread + delta band ($BAND_OUT)"
else
  bad "no real confidence band: $BAND_OUT (delta=$delta_out)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# C. THE KEY HONESTY TEST — no control sample ⇒ NEVER a fabricated number.
# ─────────────────────────────────────────────────────────────────────────────
echo "C. HONESTY (no control sample → estimated/blank, NEVER fabricated):"
HOME_C="$WORK/home-c"
# ONLY treatment runs metered — there is NO control baseline at all.
seed_run run-t1 treatment 400 "$HOME_C"
seed_run run-t2 treatment 600 "$HOME_C"
fig_c="$("$HOLD" figure --metric total_tokens --min-n 2 --home "$HOME_C")"
f_value="$(jget "$fig_c" value)"
f_cs="$(jget "$fig_c" cost_source)"
f_rendered="$(jget "$fig_c" rendered)"
f_fact="$(jget "$fig_c" is_measured_fact)"
f_cn="$(jget "$fig_c" n.control)"
# With NO control sample: value MUST be blank (empty), cost_source NOT "measured",
# is_measured_fact false, and the rendered slot the honest em-dash — NEVER a number.
if [ -z "$f_value" ] && [ "$f_cn" = "0" ]; then
  ok "no control sample → savings value is BLANK, not a fabricated number"
else
  bad "FABRICATED a savings number with no control sample: value=$f_value control.n=$f_cn"
fi
if [ "$f_cs" != "measured" ] && [ "$f_fact" = "false" ]; then
  ok "no control sample → NOT tagged measured, NOT a measured fact (cost_source=$f_cs)"
else
  bad "claimed measured/fact without a control sample: cost_source=$f_cs fact=$f_fact"
fi
if [ "$f_rendered" = "—" ]; then
  ok "no control sample → renders the honest em-dash, never a bare number"
else
  bad "rendered a NON-blank savings string with no baseline: '$f_rendered'"
fi
# Defence: assert the rendered slot contains NO digit (a leaked fabricated figure).
if grep -Eq '[0-9]' <<<"$f_rendered"; then
  bad "rendered savings slot contains a DIGIT with no baseline (fabrication): '$f_rendered'"
else
  ok "rendered savings slot has NO digit with no baseline (no fabrication)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# D. cost_source PROVENANCE + REFUSAL — measured fact requires the tag.
# ─────────────────────────────────────────────────────────────────────────────
echo "D. PROVENANCE (cost_source present; refuses a number it didn't measure):"
# The measured figure (reuse HOME_B's real two-arm data) carries the provenance tag
# AND is a measured fact; the no-baseline figure does NOT.
fig_b="$("$HOLD" figure --metric total_tokens --min-n 2 --home "$HOME_B")"
b_cs="$(jget "$fig_b" cost_source)"
b_fact="$(jget "$fig_b" is_measured_fact)"
b_value="$(jget "$fig_b" value)"
b_rendered="$(jget "$fig_b" rendered)"
if [ "$b_cs" = "measured" ] && [ "$b_fact" = "true" ] && [ "$b_value" = "700.0" ]; then
  ok "measured figure carries cost_source=measured + is a fact (value=$b_value)"
else
  bad "measured figure missing provenance/fact: $fig_b"
fi
# The structural refusal, proven directly against the lib: a number WITHOUT the
# "measured" provenance tag is NOT presentable as a fact (require_measured False).
refusal_rc=0
REFUSAL_OUT="$(LIB="$LIB" "$PY" - <<'PYEOF'
import importlib.util, os
spec = importlib.util.spec_from_file_location("holdout", os.environ["LIB"])
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
# An UNTAGGED savings number (a value with no measured provenance) — the build
# defect §6 forbids. The reporter must REFUSE to present it as a fact.
untagged = {"value": 999.0, "cost_source": None, "band": None}
assert h.require_measured(untagged) is False, "untagged number was accepted as fact!"
assert h.render_figure(untagged) == "—", "untagged number rendered as a bare value!"
# An estimate is also NOT a bare fact (it must be labeled, never measured-fact).
est = {"value": 500.0, "cost_source": "estimated", "band": None, "label": "est.",
       "basis": "prior runs"}
assert h.require_measured(est) is False, "estimate accepted as a measured fact!"
# Only a measured-tagged number is a fact.
meas = {"value": 700.0, "cost_source": "measured", "band": 10.0}
assert h.require_measured(meas) is True, "measured number was NOT accepted as fact!"
print("REFUSAL_OK")
PYEOF
)" || refusal_rc=$?
if [ "$refusal_rc" -eq 0 ] && printf '%s' "$REFUSAL_OUT" | grep -q REFUSAL_OK; then
  ok "reporter REFUSES an untagged/un-measured number as fact (structural, $REFUSAL_OUT)"
else
  bad "refusal gate did not hold: $REFUSAL_OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# E. ESTIMATED PATH IS LABELED — never a bare number; basis required.
# ─────────────────────────────────────────────────────────────────────────────
echo "E. ESTIMATED (labeled est. with a stated basis; no-basis stays blank):"
HOME_E="$WORK/home-e"
seed_run run-t1 treatment 400 "$HOME_E"   # treatment-only → no measurement
seed_run run-t2 treatment 600 "$HOME_E"
fig_est="$("$HOLD" figure --metric total_tokens --min-n 2 \
  --estimate 1234 --estimate-basis "documented opus rates, treatment-only runs" \
  --home "$HOME_E")"
e_cs="$(jget "$fig_est" cost_source)"
e_label="$(jget "$fig_est" label)"
e_fact="$(jget "$fig_est" is_measured_fact)"
e_rendered="$(jget "$fig_est" rendered)"
if [ "$e_cs" = "estimated" ] && [ "$e_label" = "est." ] && [ "$e_fact" = "false" ]; then
  ok "estimate is tagged estimated + labeled est. + NOT a measured fact"
else
  bad "estimate not labeled/tagged correctly: $fig_est"
fi
if grep -Fq "est." <<<"$e_rendered" && grep -Fq "~" <<<"$e_rendered"; then
  ok "estimate RENDERS with the est. label, never as a bare number ('$e_rendered')"
else
  bad "estimate did not render with the est. label: '$e_rendered'"
fi
# An estimate with NO stated basis must stay BLANK (we refuse an unlabeled guess).
fig_nb="$("$HOLD" figure --metric total_tokens --min-n 2 --estimate 1234 --home "$HOME_E")"
nb_cs="$(jget "$fig_nb" cost_source)"
nb_rendered="$(jget "$fig_nb" rendered)"
if [ "$nb_cs" != "estimated" ] && [ "$nb_rendered" = "—" ]; then
  ok "estimate with NO basis stays blank — an unlabeled guess is refused"
else
  bad "an estimate with no basis was emitted anyway: cost_source=$nb_cs rendered='$nb_rendered'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F. DETERMINISTIC FRACTION — stable per run_id; 0.0 all-treat, 1.0 all-control.
# ─────────────────────────────────────────────────────────────────────────────
echo "F. DETERMINISTIC FRACTION (stable per run_id; bounds):"
a1="$(jget "$("$HOLD" arm --run-id run-frac-x --fraction 0.5)" arm)"
a2="$(jget "$("$HOLD" arm --run-id run-frac-x --fraction 0.5)" arm)"
if [ -n "$a1" ] && [ "$a1" = "$a2" ]; then
  ok "fraction assignment is STABLE per run_id (same run_id → same arm: $a1)"
else
  bad "fraction assignment is not stable: $a1 vs $a2"
fi
all_t="$(jget "$("$HOLD" arm --run-id run-frac-y --fraction 0.0)" arm)"
all_c="$(jget "$("$HOLD" arm --run-id run-frac-y --fraction 1.0)" arm)"
if [ "$all_t" = "treatment" ] && [ "$all_c" = "control" ]; then
  ok "fraction=0.0 ⇒ all treatment; fraction=1.0 ⇒ all control"
else
  bad "fraction bounds wrong: frac0=$all_t frac1=$all_c"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "telemetry-holdout.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

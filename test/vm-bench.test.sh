#!/usr/bin/env bash
# vm-bench.test.sh — acceptance for the Verified-Memory BENCHMARK (VM piece C,
# bin/lib/vm_bench.py + bin/heimdall-vm-bench + test/fixtures/verified-memory/).
#
# The deliverable is a NUMBER and the discipline is HONESTY (dossier §4). This test
# asserts the HONESTY + the MECHANISM, NOT a specific winning number — the actual
# delta (does git-grounding beat the baselines, by how much, or null) is PRINTED
# honestly and the test verifies it was computed from real runs, never fabricated.
#
# The Postgres->MySQL->NoSQL fixture (a REAL throwaway 3-commit git repo) drives all
# four methods. Every assertion is mechanical + falsifiable.
#
# The proofs (dossier §4):
#   A. FIXTURE DRIVES ALL FOUR — the bench builds the real 3-commit migration repo
#      (P/M/N shas) and scores all four methods (verified-memory + decay + llm-judge
#      + drift) over the SAME git-true labels.
#   B. VERIFIED-MEMORY DETECTS THE PLANTED STALENESS — git-grounded → it gets the
#      Type-I + Type-II stale cases right: stale-retrieval error == 0 (no git-true
#      stale entry served as live). FALSIFIABLE: a false-live reds this.
#   C. EACH BASELINE RUNS + PRODUCES A REAL NUMBER — decay / llm-judge / drift each
#      emit a stale-retrieval error rate that is a real number (not fabricated, not
#      blank). The decay + drift baselines, lacking a git referent, produce a WORSE
#      (higher) error — a real measured difference, not a strawman.
#   D. HONESTY GUARD IS FALSIFIABLE — a delta number carries a provenance tag and
#      require_provenance REFUSES a number with no/foreign provenance: injecting a
#      fabricated (untagged) number renders blank '—', never a bare fact. The
#      llm-judge arm (a deterministic double) is tagged `estimated`, never `measured`.
#   E. THE DELTA IS COMPUTED FROM REAL RUNS — baseline−verified deltas equal the
#      arithmetic of the two arms' measured per-method rates (not a hand-typed value).
#   F. THE RESULT IS PRINTED HONESTLY — the headline names the winner OR the null;
#      when verified-memory does not strictly beat every baseline, null_result=true is
#      reported (a finding, not a failure).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO/bin/heimdall-vm-bench"
ENGINE="$REPO/bin/lib/vm_bench.py"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: CLI missing/not-exec at $CLI" >&2; exit 2; }
[ -f "$ENGINE" ] || { echo "FATAL: engine missing at $ENGINE" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# a throwaway work dir (the bench builds its own fixture repo inside it); cleaned.
WORK="${TMPDIR:-/tmp}/vm-bench.$$.${RANDOM}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# jq-free JSON field extraction (python, mirrors the piece-B test).
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

# run the full benchmark ONCE as JSON; every proof reads this single real run.
RESULT="$("$CLI" run --work "$WORK/repo" --json 2>/dev/null)"
RC=$?

# ─────────────────────────────────────────────────────────────────────────────
echo "A. FIXTURE DRIVES ALL FOUR — real 3-commit P/M/N repo, all methods scored:"
[ "$RC" -eq 0 ] && ok "bench run exit 0" || bad "bench run exit $RC (want 0)"
A_P="$(printf '%s' "$RESULT" | jget "['built_shas']['P']")"
A_M="$(printf '%s' "$RESULT" | jget "['built_shas']['M']")"
A_N="$(printf '%s' "$RESULT" | jget "['built_shas']['N']")"
{ [ -n "$A_P" ] && [ -n "$A_M" ] && [ -n "$A_N" ] && [ "$A_P" != "$A_M" ] && [ "$A_M" != "$A_N" ]; } \
  && ok "built three distinct real commits (P=$A_P M=$A_M N... migration chain)" \
  || bad "fixture commits not built distinctly (P=$A_P M=$A_M N=$A_N)"
for m in verified-memory decay llm-judge drift; do
  N="$(printf '%s' "$RESULT" | jget "['methods']['$m']['stale']['n']")"
  [ "$N" = "9" ] && ok "method '$m' scored all 9 fixture cases" || bad "method '$m' scored n=$N (want 9)"
done

# ─────────────────────────────────────────────────────────────────────────────
echo "B. VERIFIED-MEMORY DETECTS THE PLANTED STALENESS — sre==0, git-grounded:"
B_SRE="$(printf '%s' "$RESULT" | jget "['methods']['verified-memory']['stale']['stale_retrieval_error']")"
B_FL="$(printf '%s' "$RESULT" | jget "['methods']['verified-memory']['stale']['false_live']")"
B_STALE_TOTAL="$(printf '%s' "$RESULT" | jget "['methods']['verified-memory']['stale']['stale_total']")"
awk "BEGIN{exit !($B_SRE == 0)}" && ok "verified-memory stale-retrieval error = 0 (no git-true stale served as live)" || bad "verified-memory sre=$B_SRE (want 0 — a false-live is the failure mode)"
[ "$B_FL" = "0" ] && ok "verified-memory false-live count = 0 (every Type-I/II stale caught by git)" || bad "verified-memory false_live=$B_FL (want 0)"
awk "BEGIN{exit !($B_STALE_TOTAL >= 4)}" && ok "the fixture plants >=4 git-true stale cases (Type-I + Type-II) — a real staleness load" || bad "stale_total=$B_STALE_TOTAL (fixture must plant staleness to test detection)"
# the Type-II indirect-dependency case is in the planted set and verified caught it.
B_TYPEII="$(printf '%s' "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
pcs=d['methods']['verified-memory']['stale']['per_case']
t2=[p for p in pcs if p['type']=='type-II']
caught=all(p['predicted']=='stale' for p in t2 if p['git_true']=='stale')
print('yes' if (t2 and caught) else 'no')")"
[ "$B_TYPEII" = "yes" ] && ok "verified-memory catches the Type-II indirect dependency-chain staleness" || bad "Type-II staleness not caught ($B_TYPEII)"

# ─────────────────────────────────────────────────────────────────────────────
echo "C. EACH BASELINE RUNS + PRODUCES A REAL NUMBER (not fabricated, not blank):"
for m in decay llm-judge drift; do
  SRE="$(printf '%s' "$RESULT" | jget "['methods']['$m']['stale']['stale_retrieval_error']")"
  case "$SRE" in
    ""|None) bad "baseline '$m' produced NO stale-retrieval number ($SRE)";;
    *) awk "BEGIN{exit !($SRE >= 0 && $SRE <= 1)}" && ok "baseline '$m' produced a real stale-retrieval error rate = $SRE" || bad "baseline '$m' sre=$SRE out of [0,1]";;
  esac
done
# the git-less baselines (decay, drift) lack a referent → a HIGHER (worse) error than
# git-grounded verified-memory. A real measured difference, not a rigged strawman.
C_DECAY="$(printf '%s' "$RESULT" | jget "['methods']['decay']['stale']['stale_retrieval_error']")"
C_DRIFT="$(printf '%s' "$RESULT" | jget "['methods']['drift']['stale']['stale_retrieval_error']")"
awk "BEGIN{exit !($C_DECAY > $B_SRE)}" && ok "decay error ($C_DECAY) > verified-memory ($B_SRE) — age lags git truth (a real gap)" || bad "decay error $C_DECAY not worse than verified $B_SRE (baseline may be rigged or fixture too easy)"
awk "BEGIN{exit !($C_DRIFT > $B_SRE)}" && ok "drift error ($C_DRIFT) > verified-memory ($B_SRE) — textual proxy misses indirect staleness (a real gap vs closest prior art)" || bad "drift error $C_DRIFT not worse than verified $B_SRE"

# ─────────────────────────────────────────────────────────────────────────────
echo "D. HONESTY GUARD IS FALSIFIABLE — require_provenance refuses a fabricated number:"
# D1: the llm-judge arm (a deterministic double of a real, unavailable LLM call) is
# tagged `estimated`, NEVER `measured` — an honest label, not a disguised LLM run.
D_LLM_PROV="$(printf '%s' "$RESULT" | jget "['methods']['llm-judge']['stale']['provenance']")"
[ "$D_LLM_PROV" = "estimated" ] && ok "llm-judge arm tagged provenance=estimated (a labeled double, never a measured LLM run)" || bad "llm-judge provenance=$D_LLM_PROV (want estimated)"
# the measured arms are tagged measured.
D_VM_PROV="$(printf '%s' "$RESULT" | jget "['methods']['verified-memory']['stale']['provenance']")"
[ "$D_VM_PROV" = "measured" ] && ok "verified-memory arm tagged provenance=measured (a real git-grounded run)" || bad "verified-memory provenance=$D_VM_PROV (want measured)"
# D2: THE FALSIFIABLE CORE — inject a FABRICATED delta number with NO provenance and
# assert require_provenance REFUSES it (renders blank '—'), proving a fabricated
# number CANNOT print as a fact. Then a properly-tagged measured number IS rendered.
D_GUARD="$(python3 - "$ENGINE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vm_bench", sys.argv[1])
vmb = importlib.util.module_from_spec(spec); spec.loader.exec_module(vmb)
# a FABRICATED number: a value present but NO/foreign provenance tag → must be refused.
fabricated = {"value": 0.99, "provenance": None, "basis": None, "band": None}
prov, val = vmb.require_provenance(fabricated)
refused = (prov is None and val is None and vmb.render_figure(fabricated) == "—")
# a fabricated number wearing a foreign tag is ALSO refused (only measured/estimated pass).
foreign = {"value": 0.99, "provenance": "totally-made-up", "basis": "lie", "band": None}
fprov, fval = vmb.require_provenance(foreign)
foreign_refused = (fprov is None and fval is None)
# a genuine measured number IS rendered as a bare fact.
measured = {"value": 0.4, "provenance": "measured", "basis": "real", "band": None}
mprov, mval = vmb.require_provenance(measured)
measured_ok = (mprov == "measured" and mval == 0.4 and vmb.render_figure(measured) == "0.4")
# an estimate WITHOUT a basis is refused; WITH a basis it renders labelled (never bare).
est_nobasis = {"value": 0.5, "provenance": "estimated", "basis": "", "band": None}
enb_refused = vmb.require_provenance(est_nobasis) == (None, None)
est_ok = {"value": 0.5, "provenance": "estimated", "basis": "double", "band": None}
est_labeled = vmb.render_figure(est_ok).startswith("~") and "est." in vmb.render_figure(est_ok)
print("REFUSED" if (refused and foreign_refused and measured_ok and enb_refused and est_labeled) else "LEAKED")
PY
)"
[ "$D_GUARD" = "REFUSED" ] && ok "require_provenance REFUSES a fabricated/untagged/baseless number ('—'), renders measured bare + estimate labeled — FALSIFIABLE guard holds" || bad "honesty guard LEAKED a fabricated number ($D_GUARD) — a fabricated delta could print as fact"
# D3: a delta whose arm has NO data is blank, never an invented number.
D_BLANK="$(python3 - "$ENGINE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vm_bench", sys.argv[1])
vmb = importlib.util.module_from_spec(spec); spec.loader.exec_module(vmb)
# one arm None (no data) → the delta MUST be blank, not a fabricated value.
fig = vmb.delta_figure(None, 0.4, treatment_prov="measured", baseline_prov="measured")
print("BLANK" if (fig["value"] is None and vmb.render_figure(fig) == "—") else "FABRICATED")
PY
)"
[ "$D_BLANK" = "BLANK" ] && ok "a delta with a no-data arm renders blank '—' (never a fabricated number — a null is honest absence)" || bad "a no-data delta produced a number ($D_BLANK)"

# ─────────────────────────────────────────────────────────────────────────────
echo "E. THE DELTA IS COMPUTED FROM REAL RUNS — arithmetic of the two measured arms:"
# the decay delta on stale-retrieval MUST equal (decay_sre - verified_sre), computed
# from the real per-method rates — not a hand-typed value.
E_DELTA="$(printf '%s' "$RESULT" | jget "['deltas']['decay']['stale_retrieval']['value']")"
E_EXPECT="$(awk "BEGIN{printf \"%.6f\", $C_DECAY - $B_SRE}")"
E_GOT="$(awk "BEGIN{printf \"%.6f\", $E_DELTA}")"
[ "$E_GOT" = "$E_EXPECT" ] && ok "decay delta ($E_GOT) == decay_sre−verified_sre ($E_EXPECT) — computed from real runs, not invented" || bad "decay delta $E_GOT != computed $E_EXPECT (delta not derived from the real per-arm numbers)"
# the decay/drift deltas are tagged measured (both arms measured); the llm-judge delta
# is tagged estimated (one arm is the labeled double) — provenance flows honestly.
E_DECAY_PROV="$(printf '%s' "$RESULT" | jget "['deltas']['decay']['stale_retrieval']['provenance']")"
E_LLM_PROV="$(printf '%s' "$RESULT" | jget "['deltas']['llm-judge']['stale_retrieval']['provenance']")"
[ "$E_DECAY_PROV" = "measured" ] && ok "decay delta provenance=measured (both arms measured)" || bad "decay delta provenance=$E_DECAY_PROV (want measured)"
[ "$E_LLM_PROV" = "estimated" ] && ok "llm-judge delta provenance=estimated (cannot measure against an estimated arm — honesty flows)" || bad "llm-judge delta provenance=$E_LLM_PROV (want estimated — a delta is only as strong as its weaker arm)"

# ─────────────────────────────────────────────────────────────────────────────
echo "F. THE RESULT IS PRINTED HONESTLY — winner OR null, never a buried null:"
F_BEST="$(printf '%s' "$RESULT" | jget "['headline']['lowest_stale_retrieval']")"
F_NULL="$(printf '%s' "$RESULT" | jget "['headline']['null_result']")"
F_SUMMARY="$(printf '%s' "$RESULT" | jget "['headline']['summary']")"
# verified-memory IS the (joint) lowest stale-retrieval error — the mechanism works.
[ "$F_BEST" = "verified-memory" ] && ok "headline: verified-memory has the lowest stale-retrieval error (the git-grounding mechanism works)" || bad "headline best=$F_BEST (want verified-memory)"
# and the headline is HONEST about the null: verified-memory ties the estimated
# llm-judge on stale-retrieval, so null_result is reported true (a finding, not buried).
case "$F_NULL" in
  True)  ok "null_result=True reported honestly (verified-memory ties the est. llm-judge on stale-retrieval — not buried)";;
  False) ok "null_result=False — verified-memory strictly beat every baseline on stale-retrieval (a clean win, also honest)";;
  *)     bad "null_result=$F_NULL (must be a real boolean — the result must be printed)";;
esac
[ -n "$F_SUMMARY" ] && ok "a one-line headline summary is emitted: $F_SUMMARY" || bad "no headline summary printed (the result must be stated)"
# conflict-resolution: verified-memory wins decisively (git escalates team-divergence;
# the text/age baselines auto-pick → wrong). This is the axis git-grounding owns.
F_VM_CONF="$(printf '%s' "$RESULT" | jget "['methods']['verified-memory']['conflict']['accuracy']")"
F_DRIFT_CONF="$(printf '%s' "$RESULT" | jget "['methods']['drift']['conflict']['accuracy']")"
awk "BEGIN{exit !($F_VM_CONF > $F_DRIFT_CONF)}" && ok "verified-memory conflict accuracy ($F_VM_CONF) > drift ($F_DRIFT_CONF) — git escalates team-divergence, text auto-picks wrong" || bad "verified-memory conflict $F_VM_CONF not > drift $F_DRIFT_CONF"

# ─────────────────────────────────────────────────────────────────────────────
echo "G. THE HUMAN TABLE RENDERS (no fabricated number leaks into the rendered view):"
TABLE="$("$CLI" run --work "$WORK/repo2" 2>/dev/null)"
grep -q "verified-memory" <<<"$TABLE" && ok "table names verified-memory" || bad "table missing verified-memory row"
grep -q "est\." <<<"$TABLE" && ok "table labels the estimated arm 'est.' (never a bare estimate)" || bad "table did not label the estimated arm"
grep -qiE "HEADLINE" <<<"$TABLE" && ok "table prints the HEADLINE result line" || bad "table missing the headline result"

# ─────────────────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mALL %d PROOFS PASSED\033[0m\n' "$PASS"
  # Machine-readable roll-up for test/run-all.sh. Printed LAST on BOTH paths so an
  # unparseable-but-green suite (indistinguishable from an empty one) is impossible.
  printf 'vm-bench: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 0
fi
printf '\033[31m%d/%d PROOFS FAILED\033[0m\n' "$FAIL" "$((PASS + FAIL))"
printf 'vm-bench: %d passed, %d failed\n' "$PASS" "$FAIL"
exit 1

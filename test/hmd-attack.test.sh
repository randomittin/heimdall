#!/usr/bin/env bash
# test/hmd-attack.test.sh — `hmd attack` (RP1): the runhmd.verdict/1 contract, the
# falsifiable `attack` oracle gate, and the CLI behaviour that sits on top of both.
#
# WHAT THIS PROVES
#   [S] SCHEMA   docs/schemas/runhmd.verdict.v1.json is the single source for the
#                runhmd.verdict/1 document (and the runhmd.prove/1 envelope `hmd prove`
#                emits). bin/lib/runhmd_schema.py validates against that file, and every
#                rule is proven falsifiable: a document broken in exactly one way must be
#                REJECTED for that way, not merely rejected.
#   [G] GATE     the `attack` oracle domain is falsifiable under bin/falsify: the golden
#                (a correct settlement webhook) is PROVEN, and each mutant — missed
#                duplicate, racy duplicate, missed IDOR, off-by-one rounding — is DENIED
#                by a real attack, at the attack pinned in its manifest.
#   [C] CLI      the RP1 acceptance lines, verbatim, plus consent / budget / isolation /
#                batch / card behaviour.
#
# Hermetic: HEIMDALL_HOME and TMPDIR point into a throwaway dir, nothing is written to the
# real home, and no network is touched (the engine is deterministic and offline).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HMD="$REPO/bin/hmd"
ATTACK_BIN="$REPO/bin/heimdall-attack"
FALSIFY="$REPO/bin/falsify"
SCHEMA_PY="$REPO/bin/lib/runhmd_schema.py"
SCHEMA_JSON="$REPO/docs/schemas/runhmd.verdict.v1.json"
ORACLE="$REPO/evals/oracles/attack"
BUGGY="$REPO/fixtures/attack/buggy-webhook"
CLEAN="$REPO/fixtures/attack/clean-sample"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() {  # check <description> <command...> : PASS iff the command exits 0
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmd-attack-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HEIMDALL_HOME="$TMP/home"; mkdir -p "$HEIMDALL_HOME"
export HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1

command -v jq      >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }
command -v node    >/dev/null 2>&1 || { echo "node required" >&2; exit 2; }

# ══════════════════════════════════════════════════════════════════════════════
# [S] SCHEMA — runhmd.verdict/1 (single source) + the validator that enforces it
# ══════════════════════════════════════════════════════════════════════════════
echo "[S] runhmd.verdict/1 schema + validator (single source)"

DENIED_DOC="$TMP/denied.json"
PROVEN_DOC="$TMP/proven.json"
PROVE_DOC="$TMP/prove.json"
cat >"$DENIED_DOC" <<'JSON'
{
  "schema": "runhmd.verdict/1",
  "id": "a1b2c3d4e5f6",
  "verdict": "DENIED",
  "target": {"kind": "path", "ref": "fixtures/attack/buggy-webhook", "head_sha": null},
  "attacks": {"total": 24, "survived": 21, "killed": 3},
  "findings": [
    {"id": "f-0001", "title": "duplicate settlement (webhook+retry within 50ms)",
     "severity": "high", "category": "concurrency",
     "counterexample": {"summary": "event evt_1 delivered twice 10ms apart was credited twice",
                        "repro_cmd": "hmd attack fixtures/attack/buggy-webhook --json --yes",
                        "minimal_input": "{\"deliveries\":[{\"at_ms\":0},{\"at_ms\":10}]}"},
     "evidence_ref": null}
  ],
  "cost_usd": 0, "duration_s": 1.25,
  "agent": {"name": "none", "model": null},
  "receipt_url": null
}
JSON
jq '.verdict="PROVEN" | .findings=[] | .attacks={"total":24,"survived":24,"killed":0}' "$DENIED_DOC" >"$PROVEN_DOC"
cat >"$PROVE_DOC" <<'JSON'
{"schema": "runhmd.prove/1", "verdict": "PROVEN",
 "gates": [{"id": "exchange-lob", "gate_type": "differential", "status": "pass", "falsified": true, "falsify_score": 1.0}],
 "passed": 1, "total": 1, "regression_tests": {"passed": 1482, "failed": 0}}
JSON

# validate <doc> -> sets VRC (exit code) and VERR (stderr)
validate() { VERR="$(python3 "$SCHEMA_PY" validate "$@" 2>&1 >/dev/null)"; VRC=$?; }
# must_reject <description> <jq-filter> <expected-error-substring> [base-doc]
must_reject() {
  local desc="$1" filter="$2" want="$3" base="${4:-$DENIED_DOC}" f="$TMP/mut.$RANDOM.json"
  jq "$filter" "$base" >"$f"
  validate "$f"
  if [ "$VRC" -eq 1 ] && printf '%s' "$VERR" | grep -qF -- "$want"; then
    ok "rejects: $desc"
  else
    bad "rejects: $desc (rc=$VRC, want error containing '$want', got: $(printf '%s' "$VERR" | head -2 | tr '\n' '|'))"
  fi
}

[ -f "$SCHEMA_JSON" ] && ok "schema file exists: docs/schemas/runhmd.verdict.v1.json" || bad "schema file exists"
check "schema file is valid JSON with title runhmd.verdict/1" \
  jq -e '.title=="runhmd.verdict/1" and (."$id"|type=="string")' "$SCHEMA_JSON"

validate "$DENIED_DOC"; [ "$VRC" -eq 0 ] && ok "valid DENIED verdict accepted" || bad "valid DENIED verdict accepted (rc=$VRC: $VERR)"
validate "$PROVEN_DOC"; [ "$VRC" -eq 0 ] && ok "valid PROVEN verdict accepted" || bad "valid PROVEN verdict accepted (rc=$VRC: $VERR)"
validate "$PROVE_DOC";  [ "$VRC" -eq 0 ] && ok "valid runhmd.prove/1 envelope accepted" || bad "valid prove envelope accepted (rc=$VRC: $VERR)"
if python3 "$SCHEMA_PY" validate - <"$DENIED_DOC" >/dev/null 2>&1; then ok "reads the document from stdin ('-')"; else bad "reads the document from stdin ('-')"; fi

must_reject "wrong schema id"                  '.schema="runhmd.verdict/2"'                      'schema'
must_reject "missing required key (agent)"     'del(.agent)'                                      'agent'
must_reject "unknown top-level key"            '.extra=1'                                         'extra'
must_reject "verdict outside the enum"         '.verdict="MAYBE"'                                 '/verdict'
must_reject "target.kind outside the enum"     '.target.kind="repo"'                              '/target/kind'
must_reject "severity outside the enum"        '.findings[0].severity="urgent"'                   '/findings/0/severity'
must_reject "category outside the enum"        '.findings[0].category="style"'                    '/findings/0/category'
must_reject "finding id not f-NNNN"            '.findings[0].id="finding-1"'                      '/findings/0/id'
must_reject "finding without a counterexample" 'del(.findings[0].counterexample)'                 'counterexample'
must_reject "unknown key inside a finding"     '.findings[0].fix="do it"'                         'fix'
must_reject "negative cost"                    '.cost_usd=-0.01'                                  '/cost_usd'
must_reject "cost is not a number"             '.cost_usd="free"'                                 '/cost_usd'
must_reject "boolean is not a number"          '.duration_s=true'                                 '/duration_s'
must_reject "agent name outside the enum"      '.agent.name="gpt"'                                '/agent/name'
must_reject "receipt_url that is not https"    '.receipt_url="http://runhmd.dev/r/abc"'           '/receipt_url'
must_reject "attacks.total != survived+killed" '.attacks.total=25'                                'attacks.total'
must_reject "DENIED with no findings"          '.findings=[]'                                     'DENIED'
must_reject "duplicate finding ids"            '.findings += [.findings[0]]'                      'f-0001'
must_reject "PROVEN while attacks were killed" '.verdict="PROVEN"'                                'PROVEN'
must_reject "PROVEN carrying findings"         '.verdict="PROVEN" | .attacks={"total":24,"survived":24,"killed":0}' 'PROVEN'
must_reject "PROVEN over zero attacks and zero gates (false green)" \
  '.attacks={"total":0,"survived":0,"killed":0}' 'zero' "$PROVEN_DOC"
must_reject "PROVEN with an unfalsified gate" \
  '.gates=[{"id":"g","gate_type":"example","status":"pass","falsified":false,"falsify_score":0.5}]' 'falsified' "$PROVEN_DOC"
must_reject "prove: PROVEN although a gate is not falsified" \
  '.gates[0].falsified=false | .gates[0].falsify_score=0.5' 'falsified' "$PROVE_DOC"
must_reject "prove: PROVEN although a gate failed" \
  '.gates[0].status="fail" | .passed=0' 'PROVEN' "$PROVE_DOC"
must_reject "prove: DENIED although nothing failed" \
  '.verdict="DENIED"' 'DENIED' "$PROVE_DOC"
must_reject "prove: total != number of gates" \
  '.total=2' 'total' "$PROVE_DOC"
must_reject "prove: falsified gate whose score is not 1.0" \
  '.gates[0].falsify_score=0.9' 'falsify_score' "$PROVE_DOC"

# not JSON / missing file / unsupported schema keyword must each fail LOUDLY (never a quiet pass)
printf 'not json{' >"$TMP/garbage.json"
validate "$TMP/garbage.json"; [ "$VRC" -eq 1 ] && ok "rejects: input that is not JSON (exit 1)" || bad "rejects: input that is not JSON (rc=$VRC)"
validate "$TMP/does-not-exist.json"; [ "$VRC" -eq 2 ] && ok "missing input file is a usage/IO error (exit 2)" || bad "missing input file exit 2 (rc=$VRC)"
jq '. + {"patternProperties": {"^x": {"type":"string"}}}' "$SCHEMA_JSON" >"$TMP/schema-unsupported.json"
validate --schema "$TMP/schema-unsupported.json" "$DENIED_DOC"
[ "$VRC" -eq 2 ] && printf '%s' "$VERR" | grep -q patternProperties \
  && ok "a schema keyword the validator cannot enforce fails closed (exit 2), never a silent pass" \
  || bad "unsupported schema keyword must fail closed (rc=$VRC: $VERR)"
jq '."$defs".verdict.enum=["PROVEN","DENIED","MAYBE"]' "$SCHEMA_JSON" >"$TMP/schema-loose.json"
jq '.verdict="MAYBE"' "$DENIED_DOC" >"$TMP/maybe.json"
validate --schema "$TMP/schema-loose.json" "$TMP/maybe.json"
[ "$VRC" -eq 0 ] && ok "the schema FILE drives validation: loosening the enum there changes the verdict (it is the single source)" \
  || bad "schema file does not drive validation (rc=$VRC: $VERR)"

check "every x-invariants id documented in the schema is implemented in the validator" \
  bash -c 'for id in $(jq -r ".\"x-invariants\"[].id" "$1"); do grep -Eq "(^|[^A-Za-z0-9])$id([^A-Za-z0-9]|$)" "$2" || { echo "missing $id"; exit 1; }; done' _ "$SCHEMA_JSON" "$SCHEMA_PY"

# ══════════════════════════════════════════════════════════════════════════════
# [G] GATE — the `attack` oracle domain is falsifiable under bin/falsify
# ══════════════════════════════════════════════════════════════════════════════
echo "[G] attack oracle gate: golden PROVEN, every mutant DENIED, the gate can go red"

GREP="$ORACLE/fixtures/mutants/manifest.json"
FOUT="$TMP/falsify.out"
if "$FALSIFY" attack --assert-score 1.0 >"$FOUT" 2>&1; then frc=0; else frc=$?; fi
[ "$frc" -eq 0 ] && ok "bin/falsify attack --assert-score 1.0 exits 0" || { bad "bin/falsify attack --assert-score 1.0 exit $frc"; tail -5 "$FOUT"; }
n_mut="$(jq '.mutants|length' "$GREP")"
grep -q "SCORE: $n_mut/$n_mut = 1.0000" "$FOUT" && ok "falsify SCORE is $n_mut/$n_mut = 1.0000 (golden passing, no mutant survived)" || bad "falsify SCORE line is not $n_mut/$n_mut = 1.0000"
[ "$n_mut" -ge 3 ] && ok "the manifest declares $n_mut mutants (spec: golden + >=3)" || bad "manifest declares $n_mut mutants, want >=3"
for required in missed-duplicate missed-idor off-by-one-rounding; do
  jq -e --arg n "$required" 'any(.mutants[]; .name==$n)' "$GREP" >/dev/null 2>&1 \
    && ok "required mutant present: $required" || bad "required mutant missing: $required"
done

# gate(<input> <report>): run.sh, never aborting the harness; sets GRC
gate() { "$ORACLE/run.sh" --input "$1" --report "$2" >/dev/null 2>"$TMP/gate.err"; GRC=$?; }
rj() { jq -r "$1" "$2" 2>/dev/null; }

gate "$ORACLE/fixtures/golden/target.mjs" "$TMP/golden.report.json"
if [ "$GRC" -eq 0 ] && jq -e '.gate_id=="attack" and .status=="pass" and .first_divergence==null and .metrics.attacks.killed==0 and .metrics.attacks.total>=20 and (.metrics.findings|length)==0' "$TMP/golden.report.json" >/dev/null 2>&1; then
  ok "golden: exit 0, status=pass, first_divergence=null, 0 findings, $(rj .metrics.attacks.total "$TMP/golden.report.json") attacks survived"
else
  bad "golden did not pass cleanly (rc=$GRC)"; cat "$TMP/golden.report.json" 2>/dev/null | head -c 600
fi
check "report.json carries the 8 fixed spec-H-1 fields" \
  jq -e 'keys==["fix_hint","first_divergence","gate_id","haid","metrics","status","ts","wave"]' "$TMP/golden.report.json"

# every mutant: DENIED at its pinned first case, breaking EXACTLY its pinned attack set
while IFS=$'\t' read -r mname mfile mfirst; do
  [ -n "$mname" ] || continue
  r="$TMP/mut.$mname.report.json"
  gate "$ORACLE/fixtures/mutants/$mfile" "$r"
  if [ "$GRC" -eq 1 ] && [ "$(rj .status "$r")" = "fail" ] && [ "$(rj .first_divergence.step "$r")" = "$mfirst" ]; then
    ok "mutant $mname: DENIED, first divergence at $mfirst"
  else
    bad "mutant $mname: want DENIED at $mfirst, got rc=$GRC status=$(rj .status "$r") step=$(rj .first_divergence.step "$r")"
  fi
  want="$(jq -r --arg n "$mname" '.mutants[]|select(.name==$n)|.kills|sort[]' "$GREP")"
  got="$(jq -r '.metrics.cases[]|select(.status=="killed")|.id' "$r" 2>/dev/null | sort)"
  if [ "$want" = "$got" ]; then
    ok "mutant $mname: breaks exactly its $(printf '%s\n' "$want" | grep -c .) pinned attack(s) (single defect)"
  else
    bad "mutant $mname: kill set differs from the manifest: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | tr '\n' ' ')"
  fi
done < <(jq -r '.mutants[]|[.name,.file,.first_fail_case]|@tsv' "$GREP")

# the whole battery is accounted for: every attack id is killed by at least one mutant (no decorative attack)
all_ids="$(jq -r '.metrics.cases[].id' "$TMP/golden.report.json" | sort)"
killed_ids="$(jq -r '.mutants[].kills[]' "$GREP" | sort -u)"
[ "$all_ids" = "$killed_ids" ] && ok "every one of the $(printf '%s\n' "$all_ids" | grep -c .) attacks is killed by at least one mutant (none decorative)" \
  || bad "attacks no mutant kills (decorative): $(comm -23 <(printf '%s\n' "$all_ids") <(printf '%s\n' "$killed_ids") | tr '\n' ' ')"

# findings group by root cause with a minimal counterexample
r="$TMP/mut.racy-duplicate.report.json"
if jq -e '(.metrics.findings|length)==1 and .metrics.findings[0].title=="duplicate settlement (webhook+retry within 50ms)" and .metrics.findings[0].category=="concurrency" and .metrics.findings[0].severity=="high" and (.metrics.findings[0].attacks|length)==6 and (.metrics.findings[0].counterexample.minimal_input|fromjson|.deliveries|length)==2' "$r" >/dev/null 2>&1; then
  ok "racy-duplicate: ONE finding (6 attacks folded), titled webhook+retry within 50ms, minimal input = two deliveries"
else bad "racy-duplicate finding shape wrong"; jq -c '.metrics.findings[0]|del(.evidence)' "$r" 2>/dev/null | head -c 500; fi

# ── the gate can go RED for the right reasons (not a tautology) ──────────────────────
WEAK="$TMP/weak"; mkdir -p "$WEAK"; cp -R "$ORACLE" "$WEAK/attack"
python3 - "$WEAK/attack/engine/battery.mjs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
needle = "export const CASES = [...duplicateCases(), ...readCases(), ...roundingCases()];"
assert needle in src, "battery CASES line moved: update this test"
src = src.replace(needle, "export const CASES = [...duplicateCases(), ...readCases(), ...roundingCases()].filter((c) => !/^duplicate\\.(retry-at|burst)/.test(c.id));")
open(path, "w").write(src)
PY
WOUT="$TMP/weak.out"
if HEIMDALL_ORACLES_DIR="$WEAK" "$FALSIFY" attack --assert-score 1.0 >"$WOUT" 2>&1; then wrc=0; else wrc=$?; fi
if [ "$wrc" -ne 0 ] && grep -q "SCORE: 6/7 = 0.8571" "$WOUT" && grep -q "SURVIVED: racy-duplicate" "$WOUT"; then
  ok "META: drop the concurrent-retry attacks and racy-duplicate SURVIVES (6/7 = 0.8571) — a sequential-only test misses the race"
else bad "META: weakened battery did not let racy-duplicate survive (rc=$wrc)"; tail -4 "$WOUT"; fi

CORR="$TMP/corrupt"; mkdir -p "$CORR"; cp -R "$ORACLE" "$CORR/attack"
cp "$ORACLE/fixtures/mutants/off-by-one-rounding.mjs" "$CORR/attack/fixtures/golden/target.mjs"
if HEIMDALL_ORACLES_DIR="$CORR" "$FALSIFY" attack >"$TMP/corrupt.out" 2>&1; then crc=0; else crc=$?; fi
if [ "$crc" -ne 0 ] && grep -q "GOLDEN FAILED" "$TMP/corrupt.out"; then
  ok "a corrupted golden turns the gate RED (false-RED check is live, not an X-vs-X self-diff)"
else bad "corrupted golden was not rejected (rc=$crc)"; fi

# ── independence of the reference: a different author, and a different derivation ────
REF="$ORACLE/reference/settlement.ref.mjs"
head -12 "$REF" | grep -q "derived solely from" && ok "reference declares it was derived solely from INVARIANTS.md" || bad "reference provenance header missing"
jq -e '.oracles.attack.reference.independent==true and .oracles.attack.reference.kind=="separate-agent" and .oracles.attack.gate_type=="differential"' "$REPO/evals/oracles/registry.json" >/dev/null 2>&1 \
  && ok "registry: attack is a differential oracle with an independent separate-agent reference" || bad "registry entry for attack missing or not independent"
[ "$("$REPO/bin/oracle-select" attack 2>/dev/null)" = "evals/oracles/attack/run.sh" ] && ok "bin/oracle-select attack resolves its gate command" || bad "bin/oracle-select attack"
node --input-type=module -e "
import { feeCents } from '$REF';
const out = [];
for (let g = 1; g <= 200000; g++) out.push(g + ' ' + feeCents(g));
process.stdout.write(out.join('\n') + '\n');" >"$TMP/ref-fees.txt" 2>/dev/null
bad_fee="$(python3 - "$TMP/ref-fees.txt" <<'PY'
import sys
from decimal import Decimal, ROUND_HALF_UP
bad = rows = 0
for line in open(sys.argv[1]):
    gross, fee = map(int, line.split())
    exact = (Decimal(gross) * Decimal(29) / Decimal(1000)).quantize(Decimal(1), rounding=ROUND_HALF_UP)
    rows += 1
    bad += int(exact) != fee
print(bad if rows == 200000 else "short:%d" % rows)
PY
)"
[ "$bad_fee" = "0" ] && ok "reference fee == Python decimal ROUND_HALF_UP for every gross in 1..200000 (a second, independent derivation of R2)" || bad "reference fee disagrees with decimal arithmetic ($bad_fee)"

# ── gate behaviour on unusable / hostile targets ─────────────────────────────────────
mk_target() {  # mk_target <dir> <module-source-file>  -> a directory target with a manifest
  mkdir -p "$1"; cp "$2" "$1/webhook.mjs"
  printf '{"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"webhook.mjs"}\n' >"$1/runhmd.attack.json"
}
GOLDEN_SRC="$ORACLE/fixtures/golden/target.mjs"

mk_target "$TMP/t/ok" "$GOLDEN_SRC"
gate "$TMP/t/ok" "$TMP/r.ok.json"
[ "$GRC" -eq 0 ] && [ "$(rj .status "$TMP/r.ok.json")" = "pass" ] && ok "a directory target with a manifest is attacked and PROVEN" || bad "directory target (rc=$GRC)"

mkdir -p "$TMP/t/nomanifest"; cp "$GOLDEN_SRC" "$TMP/t/nomanifest/webhook.mjs"
gate "$TMP/t/nomanifest" "$TMP/r.nomanifest.json"
[ "$GRC" -eq 2 ] && [ "$(rj .status "$TMP/r.nomanifest.json")" = "error" ] && [ "$(rj .metrics.error_kind "$TMP/r.nomanifest.json")" = "no_attack_surface" ] \
  && ok "no manifest => exit 2 no_attack_surface (never a PROVEN over nothing)" || bad "no manifest should be exit 2 no_attack_surface (rc=$GRC)"

mk_target "$TMP/t/escape-module" "$GOLDEN_SRC"
printf '{"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"../webhook.mjs"}\n' >"$TMP/t/escape-module/runhmd.attack.json"
gate "$TMP/t/escape-module" "$TMP/r.escape-module.json"
[ "$GRC" -eq 2 ] && [ "$(rj .metrics.error_kind "$TMP/r.escape-module.json")" = "bad_manifest" ] && ok "a manifest module path that climbs out of the target is refused (bad_manifest)" || bad "manifest path traversal accepted (rc=$GRC)"

mk_target "$TMP/t/wrong-profile" "$GOLDEN_SRC"
printf '{"schema":"runhmd.attack-target/1","profile":"graphql-api/9","module":"webhook.mjs"}\n' >"$TMP/t/wrong-profile/runhmd.attack.json"
gate "$TMP/t/wrong-profile" "$TMP/r.wrong-profile.json"
[ "$GRC" -eq 2 ] && [ "$(rj .metrics.error_kind "$TMP/r.wrong-profile.json")" = "bad_manifest" ] && ok "an unknown profile is refused (bad_manifest), not silently attacked" || bad "unknown profile accepted (rc=$GRC)"

RUNHMD_ATTACK_MAX_FILES=1 "$ORACLE/run.sh" --input "$TMP/t/ok" --report "$TMP/r.big.json" >/dev/null 2>&1; GRC=$?
[ "$GRC" -eq 2 ] && [ "$(rj .metrics.error_kind "$TMP/r.big.json")" = "too_large" ] && ok "a target over the file cap is refused (too_large)" || bad "file cap not enforced (rc=$GRC)"

mkdir -p "$TMP/t/syntax"; printf 'export default function (\n' >"$TMP/t/syntax/webhook.mjs"
printf '{"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"webhook.mjs"}\n' >"$TMP/t/syntax/runhmd.attack.json"
gate "$TMP/t/syntax" "$TMP/r.syntax.json"
[ "$GRC" -eq 1 ] && [ "$(rj .first_divergence.step "$TMP/r.syntax.json")" = "module load" ] && jq -e '.metrics.findings[0].key=="load"' "$TMP/r.syntax.json" >/dev/null 2>&1 \
  && ok "a target that does not load is DENIED with a 'cannot be loaded' finding" || bad "unloadable target not DENIED (rc=$GRC)"

mkdir -p "$TMP/t/noexport"; printf 'export const x = 1;\n' >"$TMP/t/noexport/webhook.mjs"
printf '{"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"webhook.mjs"}\n' >"$TMP/t/noexport/runhmd.attack.json"
gate "$TMP/t/noexport" "$TMP/r.noexport.json"
[ "$GRC" -eq 1 ] && [ "$(rj .first_divergence.step "$TMP/r.noexport.json")" = "module load" ] && ok "a module with no createWebhook export is DENIED, not crashed" || bad "missing export not DENIED (rc=$GRC)"

# stdout noise from the target must not corrupt the verdict
{ printf "console.log('hello from the target'); process.stdout.write('garbage{');\n"; cat "$GOLDEN_SRC"; } >"$TMP/noisy.mjs"
mk_target "$TMP/t/noisy" "$TMP/noisy.mjs"
gate "$TMP/t/noisy" "$TMP/r.noisy.json"
[ "$GRC" -eq 0 ] && ok "a target that prints on stdout cannot corrupt the result (it goes to a file)" || bad "stdout noise broke the verdict (rc=$GRC)"

# a handler that never returns: no verdict, never a PROVEN
{ cat "$GOLDEN_SRC"; } | sed 's/const claimed = await store.putIfAbsent(`event:${event.id}`, true);/while (true) { Math.random(); } const claimed = await store.putIfAbsent(`event:${event.id}`, true);/' >"$TMP/hang.mjs"
grep -q 'while (true)' "$TMP/hang.mjs" || bad "test setup: hang target not built"
mk_target "$TMP/t/hang" "$TMP/hang.mjs"
RUNHMD_ATTACK_TIMEOUT_S=3 "$ORACLE/run.sh" --input "$TMP/t/hang" --report "$TMP/r.hang.json" >/dev/null 2>&1; GRC=$?
[ "$GRC" -eq 2 ] && [ "$(rj .metrics.error_kind "$TMP/r.hang.json")" = "watchdog" ] && ok "a non-terminating handler is killed by the watchdog: exit 2 watchdog, no verdict" || bad "watchdog did not fire (rc=$GRC, kind=$(rj .metrics.error_kind "$TMP/r.hang.json"))"

# isolation: scrubbed environment
{ printf "const leaked = process.env.RUNHMD_SECRET_PROBE ? 'leaked' : 'applied';\n"; sed "s/return { status: 'applied' };/return { status: leaked };/" "$GOLDEN_SRC"; } >"$TMP/envprobe.mjs"
grep -q "status: leaked" "$TMP/envprobe.mjs" || bad "test setup: env probe not built"
RUNHMD_SECRET_PROBE=topsecret node "$ORACLE/grade.mjs" "$TMP/envprobe.mjs" "$TMP/envprobe.direct.json" >/dev/null 2>&1
[ "$(jq -r '.attacks.killed' "$TMP/envprobe.direct.json" 2>/dev/null)" -gt 0 ] 2>/dev/null \
  && ok "control: the env probe DOES see a leaked secret when run unscrubbed" || bad "control: env probe cannot detect a leak (probe is broken)"
mk_target "$TMP/t/envprobe" "$TMP/envprobe.mjs"
RUNHMD_SECRET_PROBE=topsecret "$ORACLE/run.sh" --input "$TMP/t/envprobe" --report "$TMP/r.envprobe.json" >/dev/null 2>&1; GRC=$?
[ "$GRC" -eq 0 ] && ok "isolation: the target never sees the caller's environment (secret scrubbed)" || bad "environment leaked into the target (rc=$GRC)"

# isolation: no writes outside the temp dir (needs node's permission model)
if node --permission -e 0 >/dev/null 2>&1 || node --experimental-permission -e 0 >/dev/null 2>&1; then
  mkdir -p "$TMP/escape"
  { printf "import { writeFileSync } from 'node:fs';\ntry { writeFileSync('%s/marker', 'escaped'); } catch (error) { globalThis.blocked = String(error.code); }\n" "$TMP/escape"; cat "$GOLDEN_SRC"; } >"$TMP/escape.mjs"
  node --input-type=module -e "import('$TMP/escape.mjs')" >/dev/null 2>&1
  if [ -f "$TMP/escape/marker" ]; then ok "control: the escape probe really can write outside when unsandboxed"; rm -f "$TMP/escape/marker"; else bad "control: escape probe cannot write (probe is broken)"; fi
  mk_target "$TMP/t/escape" "$TMP/escape.mjs"
  gate "$TMP/t/escape" "$TMP/r.escape.json"
  if [ ! -e "$TMP/escape/marker" ]; then ok "isolation: a target that tries to write outside its temp copy is blocked (nothing written)"; else bad "isolation: the target wrote outside its sandbox"; fi
else
  echo "  SKIP: this node has no permission model; the write-isolation probe needs it"
fi
snap() { (cd "$1" && find . -type f -exec shasum {} + | sort); }
before="$(snap "$TMP/t/ok")"
gate "$TMP/t/ok" "$TMP/r.ok2.json"
[ "$before" = "$(snap "$TMP/t/ok")" ] && ok "the caller's target directory is byte-identical after the run (the attack happens in a copy)" || bad "the gate modified the caller's target directory"
mkdir -p "$TMP/clean-tmp"
TMPDIR="$TMP/clean-tmp" "$ORACLE/run.sh" --input "$TMP/t/ok" --report "$TMP/r.ok3.json" >/dev/null 2>&1
[ -z "$(ls -A "$TMP/clean-tmp")" ] && ok "the gate leaves nothing behind in TMPDIR (ephemeral temp dir removed)" || bad "the gate left files in TMPDIR: $(ls -A "$TMP/clean-tmp")"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

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
# Safety rails: if `hmd attack` is ever unrouted, the dispatcher falls through to the Claude
# task-prompt path. With a stub claude, a setup-done marker and HEIMDALL_TRACE_ORDER that path
# only appends "launch:task" to a file and exits — it can never start a model session, run
# first-run setup or touch the network from this suite. [C] asserts the trace stays empty.
touch "$HEIMDALL_HOME/setup-done"
mkdir -p "$TMP/stubbin"; printf '#!/bin/sh\nexit 0\n' >"$TMP/stubbin/claude"; chmod +x "$TMP/stubbin/claude"
export PATH="$TMP/stubbin:$PATH"
export HEIMDALL_TRACE_ORDER="$TMP/trace.order"; : >"$HEIMDALL_TRACE_ORDER"

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

if [ -f "$SCHEMA_JSON" ]; then ok "schema file exists: docs/schemas/runhmd.verdict.v1.json"; else bad "schema file exists"; fi
# shellcheck disable=SC2016 # "$id" is a jq key inside the jq program, not a shell variable
check "schema file is valid JSON with title runhmd.verdict/1" \
  jq -e '.title=="runhmd.verdict/1" and (."$id"|type=="string")' "$SCHEMA_JSON"

validate "$DENIED_DOC"; if [ "$VRC" -eq 0 ]; then ok "valid DENIED verdict accepted"; else bad "valid DENIED verdict accepted (rc=$VRC: $VERR)"; fi
validate "$PROVEN_DOC"; if [ "$VRC" -eq 0 ]; then ok "valid PROVEN verdict accepted"; else bad "valid PROVEN verdict accepted (rc=$VRC: $VERR)"; fi
validate "$PROVE_DOC";  if [ "$VRC" -eq 0 ]; then ok "valid runhmd.prove/1 envelope accepted"; else bad "valid prove envelope accepted (rc=$VRC: $VERR)"; fi
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
validate "$TMP/garbage.json"; if [ "$VRC" -eq 1 ]; then ok "rejects: input that is not JSON (exit 1)"; else bad "rejects: input that is not JSON (rc=$VRC)"; fi
validate "$TMP/does-not-exist.json"; if [ "$VRC" -eq 2 ]; then ok "missing input file is a usage/IO error (exit 2)"; else bad "missing input file exit 2 (rc=$VRC)"; fi
jq '. + {"patternProperties": {"^x": {"type":"string"}}}' "$SCHEMA_JSON" >"$TMP/schema-unsupported.json"
validate --schema "$TMP/schema-unsupported.json" "$DENIED_DOC"
if [ "$VRC" -eq 2 ] && printf '%s' "$VERR" | grep -q patternProperties; then
  ok "a schema keyword the validator cannot enforce fails closed (exit 2), never a silent pass"
else
  bad "unsupported schema keyword must fail closed (rc=$VRC: $VERR)"
fi
jq '."$defs".verdict.enum=["PROVEN","DENIED","MAYBE"]' "$SCHEMA_JSON" >"$TMP/schema-loose.json"
jq '.verdict="MAYBE"' "$DENIED_DOC" >"$TMP/maybe.json"
validate --schema "$TMP/schema-loose.json" "$TMP/maybe.json"
if [ "$VRC" -eq 0 ]; then
  ok "the schema FILE drives validation: loosening the enum there changes the verdict (it is the single source)"
else
  bad "schema file does not drive validation (rc=$VRC: $VERR)"
fi

# shellcheck disable=SC2016 # the bash -c script is single-quoted on purpose: $1/$2/$id expand in the child shell
check "every x-invariants id documented in the schema is implemented in the validator" \
  bash -c 'for id in $(jq -r ".\"x-invariants\"[].id" "$1"); do grep -Eq "(^|[^A-Za-z0-9])$id([^A-Za-z0-9]|$)" "$2" || { echo "missing $id"; exit 1; }; done' _ "$SCHEMA_JSON" "$SCHEMA_PY"

# ══════════════════════════════════════════════════════════════════════════════
# [G] GATE — the `attack` oracle domain is falsifiable under bin/falsify
# ══════════════════════════════════════════════════════════════════════════════
echo "[G] attack oracle gate: golden PROVEN, every mutant DENIED, the gate can go red"

GREP="$ORACLE/fixtures/mutants/manifest.json"
FOUT="$TMP/falsify.out"
if "$FALSIFY" attack --assert-score 1.0 >"$FOUT" 2>&1; then frc=0; else frc=$?; fi
if [ "$frc" -eq 0 ]; then ok "bin/falsify attack --assert-score 1.0 exits 0"; else bad "bin/falsify attack --assert-score 1.0 exit $frc"; tail -5 "$FOUT"; fi
n_mut="$(jq '.mutants|length' "$GREP")"
if grep -q "SCORE: $n_mut/$n_mut = 1.0000" "$FOUT"; then ok "falsify SCORE is $n_mut/$n_mut = 1.0000 (golden passing, no mutant survived)"; else bad "falsify SCORE line is not $n_mut/$n_mut = 1.0000"; fi
if [ "$n_mut" -ge 3 ]; then ok "the manifest declares $n_mut mutants (spec: golden + >=3)"; else bad "manifest declares $n_mut mutants, want >=3"; fi
for required in missed-duplicate missed-idor off-by-one-rounding; do
  if jq -e --arg n "$required" 'any(.mutants[]; .name==$n)' "$GREP" >/dev/null 2>&1; then
    ok "required mutant present: $required"
  else
    bad "required mutant missing: $required"
  fi
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
  jq -e 'keys==["first_divergence","fix_hint","gate_id","haid","metrics","status","ts","wave"]' "$TMP/golden.report.json"

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
if [ "$all_ids" = "$killed_ids" ]; then
  ok "every one of the $(printf '%s\n' "$all_ids" | grep -c .) attacks is killed by at least one mutant (none decorative)"
else
  bad "attacks no mutant kills (decorative): $(comm -23 <(printf '%s\n' "$all_ids") <(printf '%s\n' "$killed_ids") | tr '\n' ' ')"
fi

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
if head -12 "$REF" | grep -q "derived solely from"; then ok "reference declares it was derived solely from INVARIANTS.md"; else bad "reference provenance header missing"; fi
if jq -e '.oracles.attack.reference.independent==true and .oracles.attack.reference.kind=="separate-agent" and .oracles.attack.gate_type=="differential"' "$REPO/evals/oracles/registry.json" >/dev/null 2>&1; then
  ok "registry: attack is a differential oracle with an independent separate-agent reference"
else
  bad "registry entry for attack missing or not independent"
fi
if [ "$("$REPO/bin/oracle-select" attack 2>/dev/null)" = "evals/oracles/attack/run.sh" ]; then ok "bin/oracle-select attack resolves its gate command"; else bad "bin/oracle-select attack"; fi
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
if [ "$bad_fee" = "0" ]; then ok "reference fee == Python decimal ROUND_HALF_UP for every gross in 1..200000 (a second, independent derivation of R2)"; else bad "reference fee disagrees with decimal arithmetic ($bad_fee)"; fi

# ── gate behaviour on unusable / hostile targets ─────────────────────────────────────
mk_target() {  # mk_target <dir> <module-source-file>  -> a directory target with a manifest
  mkdir -p "$1"; cp "$2" "$1/webhook.mjs"
  printf '{"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"webhook.mjs"}\n' >"$1/runhmd.attack.json"
}
GOLDEN_SRC="$ORACLE/fixtures/golden/target.mjs"

mk_target "$TMP/t/ok" "$GOLDEN_SRC"
gate "$TMP/t/ok" "$TMP/r.ok.json"
if [ "$GRC" -eq 0 ] && [ "$(rj .status "$TMP/r.ok.json")" = "pass" ]; then ok "a directory target with a manifest is attacked and PROVEN"; else bad "directory target (rc=$GRC)"; fi

mkdir -p "$TMP/t/nomanifest"; cp "$GOLDEN_SRC" "$TMP/t/nomanifest/webhook.mjs"
gate "$TMP/t/nomanifest" "$TMP/r.nomanifest.json"
if [ "$GRC" -eq 2 ] && [ "$(rj .status "$TMP/r.nomanifest.json")" = "error" ] && [ "$(rj .metrics.error_kind "$TMP/r.nomanifest.json")" = "no_attack_surface" ]; then
  ok "no manifest => exit 2 no_attack_surface (never a PROVEN over nothing)"
else
  bad "no manifest should be exit 2 no_attack_surface (rc=$GRC)"
fi

mk_target "$TMP/t/escape-module" "$GOLDEN_SRC"
printf '{"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"../webhook.mjs"}\n' >"$TMP/t/escape-module/runhmd.attack.json"
gate "$TMP/t/escape-module" "$TMP/r.escape-module.json"
if [ "$GRC" -eq 2 ] && [ "$(rj .metrics.error_kind "$TMP/r.escape-module.json")" = "bad_manifest" ]; then ok "a manifest module path that climbs out of the target is refused (bad_manifest)"; else bad "manifest path traversal accepted (rc=$GRC)"; fi

mk_target "$TMP/t/wrong-profile" "$GOLDEN_SRC"
printf '{"schema":"runhmd.attack-target/1","profile":"graphql-api/9","module":"webhook.mjs"}\n' >"$TMP/t/wrong-profile/runhmd.attack.json"
gate "$TMP/t/wrong-profile" "$TMP/r.wrong-profile.json"
if [ "$GRC" -eq 2 ] && [ "$(rj .metrics.error_kind "$TMP/r.wrong-profile.json")" = "bad_manifest" ]; then ok "an unknown profile is refused (bad_manifest), not silently attacked"; else bad "unknown profile accepted (rc=$GRC)"; fi

RUNHMD_ATTACK_MAX_FILES=1 "$ORACLE/run.sh" --input "$TMP/t/ok" --report "$TMP/r.big.json" >/dev/null 2>&1; GRC=$?
if [ "$GRC" -eq 2 ] && [ "$(rj .metrics.error_kind "$TMP/r.big.json")" = "too_large" ]; then ok "a target over the file cap is refused (too_large)"; else bad "file cap not enforced (rc=$GRC)"; fi

mkdir -p "$TMP/t/syntax"; printf 'export default function (\n' >"$TMP/t/syntax/webhook.mjs"
printf '{"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"webhook.mjs"}\n' >"$TMP/t/syntax/runhmd.attack.json"
gate "$TMP/t/syntax" "$TMP/r.syntax.json"
if [ "$GRC" -eq 1 ] && [ "$(rj .first_divergence.step "$TMP/r.syntax.json")" = "module load" ] && jq -e '.metrics.findings[0].key=="load"' "$TMP/r.syntax.json" >/dev/null 2>&1; then
  ok "a target that does not load is DENIED with a 'cannot be loaded' finding"
else
  bad "unloadable target not DENIED (rc=$GRC)"
fi

mkdir -p "$TMP/t/noexport"; printf 'export const x = 1;\n' >"$TMP/t/noexport/webhook.mjs"
printf '{"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"webhook.mjs"}\n' >"$TMP/t/noexport/runhmd.attack.json"
gate "$TMP/t/noexport" "$TMP/r.noexport.json"
if [ "$GRC" -eq 1 ] && [ "$(rj .first_divergence.step "$TMP/r.noexport.json")" = "module load" ]; then ok "a module with no createWebhook export is DENIED, not crashed"; else bad "missing export not DENIED (rc=$GRC)"; fi

# stdout noise from the target must not corrupt the verdict
{ printf "console.log('hello from the target'); process.stdout.write('garbage{');\n"; cat "$GOLDEN_SRC"; } >"$TMP/noisy.mjs"
mk_target "$TMP/t/noisy" "$TMP/noisy.mjs"
gate "$TMP/t/noisy" "$TMP/r.noisy.json"
if [ "$GRC" -eq 0 ]; then ok "a target that prints on stdout cannot corrupt the result (it goes to a file)"; else bad "stdout noise broke the verdict (rc=$GRC)"; fi

# a handler that never returns: no verdict, never a PROVEN
# shellcheck disable=SC2016 # the sed program is literal JS: the backticks and ${event.id} must reach the file unexpanded
{ cat "$GOLDEN_SRC"; } | sed 's/const claimed = await store.putIfAbsent(`event:${event.id}`, true);/while (true) { Math.random(); } const claimed = await store.putIfAbsent(`event:${event.id}`, true);/' >"$TMP/hang.mjs"
grep -q 'while (true)' "$TMP/hang.mjs" || bad "test setup: hang target not built"
mk_target "$TMP/t/hang" "$TMP/hang.mjs"
RUNHMD_ATTACK_TIMEOUT_S=3 "$ORACLE/run.sh" --input "$TMP/t/hang" --report "$TMP/r.hang.json" >/dev/null 2>&1; GRC=$?
if [ "$GRC" -eq 2 ] && [ "$(rj .metrics.error_kind "$TMP/r.hang.json")" = "watchdog" ]; then ok "a non-terminating handler is killed by the watchdog: exit 2 watchdog, no verdict"; else bad "watchdog did not fire (rc=$GRC, kind=$(rj .metrics.error_kind "$TMP/r.hang.json"))"; fi

# isolation: scrubbed environment
{ printf "const leaked = process.env.RUNHMD_SECRET_PROBE ? 'leaked' : 'applied';\n"; sed "s/return { status: 'applied' };/return { status: leaked };/" "$GOLDEN_SRC"; } >"$TMP/envprobe.mjs"
grep -q "status: leaked" "$TMP/envprobe.mjs" || bad "test setup: env probe not built"
RUNHMD_SECRET_PROBE=topsecret node "$ORACLE/grade.mjs" "$TMP/envprobe.mjs" "$TMP/envprobe.direct.json" >/dev/null 2>&1
if [ "$(jq -r '.attacks.killed' "$TMP/envprobe.direct.json" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
  ok "control: the env probe DOES see a leaked secret when run unscrubbed"
else
  bad "control: env probe cannot detect a leak (probe is broken)"
fi
mk_target "$TMP/t/envprobe" "$TMP/envprobe.mjs"
RUNHMD_SECRET_PROBE=topsecret "$ORACLE/run.sh" --input "$TMP/t/envprobe" --report "$TMP/r.envprobe.json" >/dev/null 2>&1; GRC=$?
if [ "$GRC" -eq 0 ]; then ok "isolation: the target never sees the caller's environment (secret scrubbed)"; else bad "environment leaked into the target (rc=$GRC)"; fi

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
if [ "$before" = "$(snap "$TMP/t/ok")" ]; then ok "the caller's target directory is byte-identical after the run (the attack happens in a copy)"; else bad "the gate modified the caller's target directory"; fi
mkdir -p "$TMP/clean-tmp"
TMPDIR="$TMP/clean-tmp" "$ORACLE/run.sh" --input "$TMP/t/ok" --report "$TMP/r.ok3.json" >/dev/null 2>&1
if [ -z "$(ls -A "$TMP/clean-tmp")" ]; then ok "the gate leaves nothing behind in TMPDIR (ephemeral temp dir removed)"; else bad "the gate left files in TMPDIR: $(ls -A "$TMP/clean-tmp")"; fi

# ══════════════════════════════════════════════════════════════════════════════
# [C] CLI — `hmd attack`
# ══════════════════════════════════════════════════════════════════════════════
echo "[C] hmd attack CLI"

# attack <args...>: run from the repo root with stdin from /dev/null; sets AOUT AERR ARC
attack() {
  AOUT="$TMP/attack.out"; AERR="$TMP/attack.err"
  (cd "$REPO" && "$HMD" attack "$@" </dev/null >"$AOUT" 2>"$AERR"); ARC=$?
}

echo "  -- the RP1 acceptance lines, verbatim --"
if ( set +o pipefail; cd "$REPO" && "$HMD" attack fixtures/attack/buggy-webhook --json --yes 2>/dev/null | jq -e '.verdict=="DENIED" and (.findings|length)>=1' >/dev/null ); then
  ok "ACCEPT 1: hmd attack fixtures/attack/buggy-webhook --json --yes | jq -e '.verdict==\"DENIED\" and (.findings|length)>=1'"
else
  bad "ACCEPT 1: buggy-webhook is not DENIED with >=1 finding"
fi
if ( set +o pipefail; cd "$REPO" && "$HMD" attack fixtures/attack/clean-sample --json --yes 2>/dev/null | jq -e '.verdict=="PROVEN"' >/dev/null ); then
  ok "ACCEPT 2: hmd attack fixtures/attack/clean-sample --json --yes | jq -e '.verdict==\"PROVEN\"'"
else
  bad "ACCEPT 2: clean-sample is not PROVEN"
fi
if ( cd "$REPO" && "$HMD" attack . </dev/null >/dev/null 2>&1; test $? -eq 3 ); then
  ok "ACCEPT 3: hmd attack . </dev/null exits 3 (no TTY, no --yes: refuses to run)"
else
  bad "ACCEPT 3: hmd attack . </dev/null did not exit 3"
fi

echo "  -- verdicts, exit codes, contract --"
attack fixtures/attack/buggy-webhook --json --yes; cp "$AOUT" "$TMP/v.denied.json"; DRC=$ARC
attack fixtures/attack/clean-sample --json --yes;  cp "$AOUT" "$TMP/v.proven.json"; PRC=$ARC
if [ "$DRC" -eq 1 ]; then ok "DENIED exits 1"; else bad "DENIED exit code is $DRC, want 1"; fi
if [ "$PRC" -eq 0 ]; then ok "PROVEN exits 0"; else bad "PROVEN exit code is $PRC, want 0"; fi
for v in denied proven; do
  if python3 "$SCHEMA_PY" validate "$TMP/v.$v.json" >/dev/null 2>"$TMP/v.err"; then
    ok "the $v verdict validates against docs/schemas/runhmd.verdict.v1.json"
  else
    bad "the $v verdict violates the schema: $(head -2 "$TMP/v.err" | tr '\n' '|')"
  fi
done
check "the verdict document is the only thing on stdout (one JSON value)" jq -e -s 'length==1' "$TMP/v.denied.json"
check "DENIED document: path target as given, 40-hex head_sha, 23 attacks / 6 killed, no model, no receipt" \
  jq -e '.schema=="runhmd.verdict/1" and .target.kind=="path" and .target.ref=="fixtures/attack/buggy-webhook"
         and (.target.head_sha|test("^[0-9a-f]{40}$")) and .attacks=={total:23,survived:17,killed:6}
         and .cost_usd==0 and .agent=={name:"none",model:null} and .receipt_url==null' "$TMP/v.denied.json"
check "DENIED finding: the 50ms duplicate-settlement race, high/concurrency, f-0001, minimal two-delivery input" \
  jq -e '(.findings|length)==1 and .findings[0].id=="f-0001" and .findings[0].title=="duplicate settlement (webhook+retry within 50ms)"
         and .findings[0].severity=="high" and .findings[0].category=="concurrency" and .findings[0].evidence_ref==null
         and (.findings[0].counterexample.minimal_input|fromjson|.deliveries|length)==2
         and (.findings[0].counterexample.summary|contains("delivery statuses"))' "$TMP/v.denied.json"
check "PROVEN document: no findings, nothing killed, every attack survived" \
  jq -e '.verdict=="PROVEN" and .findings==[] and .attacks.killed==0 and .attacks.total==23 and .attacks.survived==23' "$TMP/v.proven.json"
if [ "$(jq -r .id "$TMP/v.denied.json")" != "$(jq -r .id "$TMP/v.proven.json")" ]; then ok "different targets get different ids"; else bad "buggy and clean share an id"; fi
attack fixtures/attack/buggy-webhook --json --yes
if [ "$(jq -r .id "$AOUT")" = "$(jq -r .id "$TMP/v.denied.json")" ] \
  && [ "$(jq -S 'del(.duration_s)' "$AOUT")" = "$(jq -S 'del(.duration_s)' "$TMP/v.denied.json")" ]; then
  ok "the same target gives the same id and the same document (deterministic; only duration_s varies)"
else
  bad "two runs on one target differ"
fi
repro="$(jq -r '.findings[0].counterexample.repro_cmd' "$TMP/v.denied.json")"
case "$repro" in "hmd attack fixtures/attack/buggy-webhook "*) ok "repro_cmd names the command and the target: $repro" ;; *) bad "repro_cmd is not a runnable hmd attack command: $repro" ;; esac
# shellcheck disable=SC2086 # repro_cmd is an argv string: word-splitting it back into arguments is the point
attack ${repro#hmd attack }
if [ "$(jq -r '.findings[0].title' "$AOUT")" = "duplicate settlement (webhook+retry within 50ms)" ]; then ok "running repro_cmd reproduces the same finding"; else bad "repro_cmd does not reproduce the finding"; fi

echo "  -- consent (non-TTY without --yes exits 3, before any work) --"
attack fixtures/attack/clean-sample
if [ "$ARC" -eq 3 ] && [ ! -s "$AOUT" ] && grep -q -- '--yes' "$AERR"; then ok "no --yes and no TTY: exit 3, nothing on stdout, stderr says to pass --yes"; else bad "non-TTY consent refusal wrong (rc=$ARC)"; fi
if ( cd "$REPO" && printf 'y\n' | "$HMD" attack fixtures/attack/clean-sample >"$TMP/piped.out" 2>/dev/null; test $? -eq 3 && [ ! -s "$TMP/piped.out" ] ); then ok "a 'y' piped into a non-TTY is NOT consent (exit 3)"; else bad "piped input was accepted as consent"; fi
attack fixtures/attack/clean-sample --json
if [ "$ARC" -eq 3 ] && jq -e '.error=="consent_required"' "$AOUT" >/dev/null 2>&1; then ok "--json without consent: exit 3 and an error document on stdout"; else bad "--json consent refusal wrong (rc=$ARC)"; fi
attack /nonexistent/path/xyz
if [ "$ARC" -eq 3 ]; then ok "consent is asked for before the target is even looked at (exit 3, not 2)"; else bad "consent should precede target resolution (rc=$ARC)"; fi

cat >"$TMP/pty-consent.py" <<'PY'
import os, pty, select, sys, time

def run(answer, hmd, repo, args):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(repo)
        os.execv(hmd, [hmd, "attack"] + args)
    out, sent, deadline = b"", False, time.time() + 90
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            if not sent and b"[y/N]" in out:
                os.write(fd, answer)
                sent = True
    _, status = os.waitpid(pid, 0)
    return os.WEXITSTATUS(status), out.decode("utf-8", "replace"), sent

hmd, repo = sys.argv[1], sys.argv[2]
rc_y, out_y, sent_y = run(b"y\n", hmd, repo, ["fixtures/attack/clean-sample"])
rc_n, out_n, sent_n = run(b"n\n", hmd, repo, ["fixtures/attack/clean-sample"])
print("YES rc=%d prompted=%s proven=%s executes=%s" % (rc_y, sent_y, "PROVEN" in out_y, "EXECUTE" in out_y.upper()))
print("NO rc=%d prompted=%s ran=%s" % (rc_n, sent_n, "VERDICT" in out_n))
PY
pty_out="$(python3 "$TMP/pty-consent.py" "$HMD" "$REPO" 2>/dev/null)"
if printf '%s\n' "$pty_out" | grep -q '^YES rc=0 prompted=True proven=True executes=True'; then ok "on a TTY the prompt says it will EXECUTE the target; answering y runs the attack (PROVEN, exit 0)"; else bad "TTY consent 'y' flow wrong: $(printf '%s' "$pty_out" | tr '\n' '|')"; fi
if printf '%s\n' "$pty_out" | grep -q '^NO rc=3 prompted=True ran=False'; then ok "on a TTY, answering n declines: exit 3 and nothing ran"; else bad "TTY consent 'n' flow wrong: $(printf '%s' "$pty_out" | tr '\n' '|')"; fi

echo "  -- no attack surface / bad input is never a PROVEN --"
attack . --json --yes
if [ "$ARC" -eq 2 ] && jq -e '.error=="no_attack_surface" and (has("verdict")|not)' "$AOUT" >/dev/null 2>&1; then
  ok "attacking a tree that declares no attack surface exits 2 (no_attack_surface), never a vacuous PROVEN"
else
  bad "no-surface target wrong (rc=$ARC): $(head -c 200 "$AOUT")"
fi
attack /nonexistent/path/xyz --yes --json
if [ "$ARC" -eq 2 ] && jq -e '.error=="target_not_found"' "$AOUT" >/dev/null 2>&1; then ok "a missing target exits 2 (target_not_found)"; else bad "missing target wrong (rc=$ARC)"; fi
attack --bogus --yes;                     if [ "$ARC" -eq 2 ]; then ok "an unknown flag exits 2"; else bad "unknown flag rc=$ARC"; fi
attack fixtures/attack/clean-sample --max-usd abc --yes;  if [ "$ARC" -eq 2 ]; then ok "--max-usd abc exits 2"; else bad "--max-usd abc rc=$ARC"; fi
attack fixtures/attack/clean-sample --max-usd -1 --yes;   if [ "$ARC" -eq 2 ]; then ok "--max-usd -1 exits 2"; else bad "--max-usd -1 rc=$ARC"; fi
attack --batch "$TMP/none.txt" --yes;     if [ "$ARC" -eq 2 ]; then ok "--batch without --out exits 2"; else bad "--batch without --out rc=$ARC"; fi
attack fixtures/attack/clean-sample --diff x.patch --yes
if [ "$ARC" -eq 2 ] && grep -q 'x.patch' "$AERR"; then ok "--diff with a patch file that does not exist is refused with exit 2 and names it (the working path is proven in test/adapter-gitdiff.test.sh)"; else bad "--diff handling wrong (rc=$ARC)"; fi
attack https://github.com/org/repo/pull/123 --yes
if [ "$ARC" -eq 2 ] && grep -qi 'not supported' "$AERR"; then ok "a PR URL is refused with exit 2 (needs network + adapters), nothing fetched"; else bad "PR url handling wrong (rc=$ARC)"; fi
attack fixtures/attack/clean-sample --max-usd 0.50 --no-network --json --yes
if [ "$ARC" -eq 0 ] && jq -e '.verdict=="PROVEN" and .cost_usd==0' "$AOUT" >/dev/null 2>&1; then ok "--max-usd 0.50 --no-network: runs, costs \$0 (deterministic engine: no model, no network)"; else bad "--max-usd/--no-network run wrong (rc=$ARC)"; fi
attack --help
[ "$ARC" -eq 0 ] && for w in --json --card --yes --max-usd --batch --out --no-network --diff; do grep -q -- "$w" "$AOUT" || { bad "--help does not document $w"; break; }; done
if [ "$ARC" -eq 0 ] && grep -Eq '^ +3 .*consent' "$AOUT" && grep -Eq '^ +4 .*budget' "$AOUT"; then ok "--help documents every flag and the exit codes (0..5)"; else bad "--help incomplete (rc=$ARC)"; fi

PYLIB="$REPO/bin/lib"
python3 - "$PYLIB" <<'PY' >"$TMP/budget.out" 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import runhmd_attack as ra
over = ra.enforce_budget(0.5, 0.01)
assert over == {"error": "budget_cap", "spent_usd": 0.5, "cap_usd": 0.01}, over
assert ra.enforce_budget(0.0, 0.0) is None
assert ra.enforce_budget(0.01, 0.01) is None
assert ra.enforce_budget(3.0, None) is None
assert ra.EXIT_BUDGET == 4 and ra.EXIT_CONSENT == 3 and ra.EXIT_USAGE == 2 and ra.EXIT_INFRA == 5
print("budget-ok")
PY
if grep -q budget-ok "$TMP/budget.out"; then ok "budget cap: a cost over --max-usd is exit 4 {error:budget_cap,spent_usd,cap_usd}; at-or-under passes"; else bad "enforce_budget wrong: $(cat "$TMP/budget.out")"; fi
if ! grep -En '^[[:space:]]*(import|from)[[:space:]]+(socket|urllib|http|ssl|ftplib|smtplib|requests)' "$PYLIB/runhmd_attack.py" "$PYLIB/runhmd_card.py" "$ATTACK_BIN" >/dev/null 2>&1; then
  ok "the CLI imports no network module (nothing beyond the local gate subprocess)"
else
  bad "the CLI imports a network module"
fi
if ! grep -En 'shell[[:space:]]*=[[:space:]]*True|os\.system' "$PYLIB/runhmd_attack.py" "$ATTACK_BIN" >/dev/null 2>&1; then
  ok "the CLI never shells out through a shell string"
else
  bad "the CLI uses shell=True / os.system"
fi

echo "  -- the verdict card (plan 5.3, 40 columns) --"
attack fixtures/attack/buggy-webhook --card --yes
# shellcheck disable=SC2016 # $1 expands in the bash -c child, not here
check "--card output starts with the runhmd attack box (head -3 | grep 'runhmd attack')" bash -c 'head -3 "$1" | grep -q "runhmd attack"' _ "$AOUT"
python3 - "$AOUT" <<'PY' >"$TMP/card.out" 2>&1
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
width = lambda s: sum(2 if ch == "\U0001F6E1" else 1 for ch in s)
bad = [(i, width(l)) for i, l in enumerate(lines) if width(l) != 40]
print("cols-ok" if lines and not bad else "bad-cols %r" % bad)
print("denied" if any("VERDICT: DENIED" in l for l in lines) else "no-verdict")
print("finding" if any(l.startswith("│ ✗ duplicate settlement (webhook+retry") for l in lines) else "no-finding")
print("counts" if any("23 attacks · 17 survived · 6 killed" in l for l in lines) else "no-counts")
print("nourl" if not any("Evidence" in l for l in lines) else "fabricated-evidence-line")
PY
if [ "$(tr '\n' ' ' <"$TMP/card.out")" = "cols-ok denied finding counts nourl " ]; then ok "the real DENIED card: every row is 40 columns, VERDICT: DENIED, the wrapped finding, the real counts, and no invented receipt line"; else bad "card content wrong: $(tr '\n' '|' <"$TMP/card.out")"; fi

cat >"$TMP/plan-card.txt" <<'CARD'
╭──────────────────────────────────────╮
│ 🛡 runhmd attack                     │
│                                      │
│ VERDICT: DENIED                      │
│                                      │
│ 24 attacks · 21 survived · 3 killed  │
│                                      │
│ ✗ duplicate settlement (webhook+retry│
│   within 50ms)                       │
│ ✗ missing auth check on /refunds     │
│ ✗ regression in currency rounding    │
│                                      │
│ Cost: $0.41 · Time: 2m 14s           │
│ Evidence → runhmd.dev/r/abc123       │
╰──────────────────────────────────────╯
CARD
python3 - "$PYLIB" >"$TMP/plan-card.got" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import runhmd_card
finding = lambda i, title, sev, cat: {"id": "f-000%d" % i, "title": title, "severity": sev, "category": cat,
    "counterexample": {"summary": "s", "repro_cmd": "hmd attack x", "minimal_input": ""}, "evidence_ref": None}
doc = {"schema": "runhmd.verdict/1", "id": "abc123", "verdict": "DENIED",
       "target": {"kind": "path", "ref": ".", "head_sha": None},
       "attacks": {"total": 24, "survived": 21, "killed": 3},
       "findings": [finding(1, "duplicate settlement (webhook+retry within 50ms)", "high", "concurrency"),
                    finding(2, "missing auth check on /refunds", "high", "auth"),
                    finding(3, "regression in currency rounding", "medium", "regression")],
       "cost_usd": 0.41, "duration_s": 134, "agent": {"name": "claude-code", "model": "m"},
       "receipt_url": "https://runhmd.dev/r/abc123"}
sys.stdout.write(runhmd_card.render_card(doc))
PY
if cmp -s "$TMP/plan-card.txt" "$TMP/plan-card.got"; then ok "the card is byte-for-byte the box in plan 5.3 (wrapping, glyphs, cost/time, evidence line)"; else bad "card differs from plan 5.3"; diff "$TMP/plan-card.txt" "$TMP/plan-card.got" | head -10; fi
attack fixtures/attack/clean-sample --yes
if grep -q "VERDICT: PROVEN" "$AOUT" && ! grep -q '✗' "$AOUT"; then ok "the default human output (no --json) is the card: PROVEN with no findings"; else bad "default human output is not the PROVEN card"; fi
attack fixtures/attack/buggy-webhook --json --card --yes
if jq -e '.verdict=="DENIED"' "$AOUT" >/dev/null 2>&1 && grep -q "VERDICT: DENIED" "$AERR"; then ok "--json --card: stdout stays pure JSON, the card goes to stderr"; else bad "--json --card mixes the streams"; fi

echo "  -- evidence on disk (--out) and batch --"
OUTD="$TMP/out1"
attack fixtures/attack/buggy-webhook --json --yes --out "$OUTD"
if [ "$ARC" -eq 1 ] && python3 "$SCHEMA_PY" validate "$OUTD/verdict.json" >/dev/null 2>&1 \
   && [ "$(jq -r '.findings[0].evidence_ref' "$OUTD/verdict.json")" = "attacks/f-0001.json" ] \
   && jq -e '.finding_id=="f-0001" and (.evidence|length)==6 and (.evidence[0].scenario.deliveries|length)==2' "$OUTD/attacks/f-0001.json" >/dev/null 2>&1; then
  ok "--out DIR: verdict.json is schema-valid and evidence_ref points at a real attacks/f-0001.json holding all 6 killed attacks"
else bad "--out evidence layout wrong (rc=$ARC)"; find "$OUTD" 2>&1 | head; fi
if [ "$(jq -r '.findings[0].evidence_ref' "$TMP/v.denied.json")" = "null" ]; then ok "without --out evidence_ref is null (never a dangling path into a deleted temp dir)"; else bad "evidence_ref set without --out"; fi

printf '# targets\n\nfixtures/attack/buggy-webhook\nfixtures/attack/clean-sample\n' >"$TMP/targets.txt"
BATCH="$TMP/batch"
attack --batch "$TMP/targets.txt" --out "$BATCH" --json --yes
nfiles="$(find "$BATCH" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ARC" -eq 1 ] && [ "$nfiles" -eq 2 ] && [ "$(wc -l <"$AOUT" | tr -d ' ')" -eq 2 ] \
   && [ "$(jq -r .verdict "$AOUT" | paste -sd, -)" = "DENIED,PROVEN" ] \
   && for f in "$BATCH"/*.json; do python3 "$SCHEMA_PY" validate "$f" >/dev/null 2>&1 || exit 1; done; then
  ok "--batch FILE --out DIR: one schema-valid verdict file per target ($nfiles), JSONL on stdout, exit 1 because one was DENIED"
else bad "batch wrong (rc=$ARC files=$nfiles)"; find "$BATCH" 2>&1 | head; fi
printf 'fixtures/attack/clean-sample\n.\n' >"$TMP/targets2.txt"
attack --batch "$TMP/targets2.txt" --out "$TMP/batch2" --json --yes
if [ "$ARC" -eq 2 ] && [ "$(find "$TMP/batch2" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" -eq 2 ] && [ -n "$(find "$TMP/batch2" -maxdepth 1 -name '*.json' | head -1)" ]; then
  ok "a batch target that cannot be attacked gets an error file and exit 2; the other targets are still attacked"
else
  bad "batch error handling wrong (rc=$ARC)"
fi

echo "  -- isolation: nothing written outside the temp dir --"
HOME_BEFORE="$TMP/clihome"; mkdir -p "$HOME_BEFORE/h" "$HOME_BEFORE/heimdall" "$HOME_BEFORE/tmp"
git_before="$(git -C "$REPO" status --porcelain)"
( cd "$REPO" && HOME="$HOME_BEFORE/h" HEIMDALL_HOME="$HOME_BEFORE/heimdall" TMPDIR="$HOME_BEFORE/tmp" "$HMD" attack fixtures/attack/buggy-webhook --json --yes >/dev/null 2>&1 )
if [ -z "$(ls -A "$HOME_BEFORE/h")" ] && [ -z "$(ls -A "$HOME_BEFORE/tmp")" ] && [ "$git_before" = "$(git -C "$REPO" status --porcelain)" ]; then
  ok "no files in HOME, none left in TMPDIR, repo tree untouched"
else
  bad "attack wrote outside its ephemeral dir: home=[$(ls -A "$HOME_BEFORE/h")] tmp=[$(ls -A "$HOME_BEFORE/tmp")]"
fi
# What the dispatcher preamble itself leaves in HEIMDALL_HOME (run-count bump, setup marker) is
# pre-existing behaviour of EVERY hmd command (RP7's zero-footprint mode owns it); measure it with
# a command that does nothing else, and require attack to add nothing on top.
BASE_HOME="$TMP/basehome"; mkdir -p "$BASE_HOME"
( cd "$REPO" && HEIMDALL_HOME="$BASE_HOME" "$HMD" version >/dev/null 2>&1 )
footprint() { (cd "$1" && find . -type f | sort | tr '\n' ' '); }
if [ "$(footprint "$HOME_BEFORE/heimdall")" = "$(footprint "$BASE_HOME")" ]; then
  ok "attack adds nothing to HEIMDALL_HOME beyond the dispatcher preamble's own footprint ($(footprint "$BASE_HOME"))"
else
  bad "attack wrote extra files into HEIMDALL_HOME: [$(footprint "$HOME_BEFORE/heimdall")] vs preamble-only [$(footprint "$BASE_HOME")]"
fi

echo "  -- the verdict comes from the gate (mutation proof) --"
mkdir -p "$TMP/mut"
python3 - "$REPO/fixtures/attack" "$TMP/mut" <<'PY'
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
claim = "      const claimed = await store.putIfAbsent(`event:${event.id}`, true);\n      if (!claimed) return { status: 'duplicate' };\n"
check = "      const alreadyProcessed = await store.get(`event:${event.id}`);\n      if (alreadyProcessed) return { status: 'duplicate' };\n"
incr = "      await store.incr(`balance:${event.account}`, net);\n"
mark = "      await store.set(`event:${event.id}`, true);\n"
for name in ("clean-sample", "buggy-webhook"):
    shutil.copytree(os.path.join(src, name), os.path.join(dst, name))
# break the clean sample: atomic claim -> check-then-act
p = os.path.join(dst, "clean-sample", "webhook.mjs"); s = open(p).read()
assert claim in s and incr in s
open(p, "w").write(s.replace(claim, check).replace(incr, incr + mark))
# fix the buggy one: check-then-act -> atomic claim
p = os.path.join(dst, "buggy-webhook", "webhook.mjs"); s = open(p).read()
assert check in s and mark in s
open(p, "w").write(s.replace(check, claim).replace(mark, ""))
PY
attack "$TMP/mut/clean-sample" --json --yes
if [ "$ARC" -eq 1 ] && jq -e '.verdict=="DENIED" and .findings[0].title=="duplicate settlement (webhook+retry within 50ms)"' "$AOUT" >/dev/null 2>&1; then
  ok "MUTATION: introduce the race into clean-sample -> PROVEN flips to DENIED with the duplicate-settlement finding"
else
  bad "mutating clean-sample did not flip it to DENIED (rc=$ARC)"
fi
attack "$TMP/mut/buggy-webhook" --json --yes
if [ "$ARC" -eq 0 ] && jq -e '.verdict=="PROVEN"' "$AOUT" >/dev/null 2>&1; then
  ok "MUTATION: fix the race in buggy-webhook (atomic claim) -> DENIED flips to PROVEN"
else
  bad "fixing buggy-webhook did not flip it to PROVEN (rc=$ARC)"
fi
if ( cd "$REPO" && HEIMDALL_ORACLES_DIR="$WEAK" "$HMD" attack fixtures/attack/buggy-webhook --json --yes 2>/dev/null | jq -e '.verdict=="PROVEN"' >/dev/null ); then ok "MUTATION: weaken the gate (drop the concurrent-retry attacks) and the same buggy-webhook is PROVEN — the verdict is computed by the gate, not by the fixture's name"; else bad "the CLI verdict does not follow the gate"; fi

echo "  -- dispatch --"
if [ ! -s "$HEIMDALL_TRACE_ORDER" ]; then ok "hmd attack never fell through to the Claude task-prompt path during this suite"; else bad "hmd attack fell through to the task-prompt path: $(head -c 200 "$HEIMDALL_TRACE_ORDER")"; fi
if grep -Eq '^  attack\)' "$REPO/bin/heimdall"; then ok "bin/heimdall has an attack) dispatch arm"; else bad "bin/heimdall has no attack) arm"; fi
if [ -x "$ATTACK_BIN" ]; then ok "bin/heimdall-attack is executable"; else bad "bin/heimdall-attack is not executable"; fi
if bash -n "$REPO/bin/heimdall"; then ok "bin/heimdall still passes bash -n"; else bad "bin/heimdall has a syntax error"; fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

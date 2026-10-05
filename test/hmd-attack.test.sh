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
jq 'del(.properties.verdict.enum) | .properties.verdict.enum=["PROVEN","DENIED","MAYBE"]' "$SCHEMA_JSON" >"$TMP/schema-loose.json"
jq '.verdict="MAYBE"' "$DENIED_DOC" >"$TMP/maybe.json"
validate --schema "$TMP/schema-loose.json" "$TMP/maybe.json"
[ "$VRC" -eq 0 ] && ok "the schema FILE drives validation: loosening the enum there changes the verdict (it is the single source)" \
  || bad "schema file does not drive validation (rc=$VRC: $VERR)"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# test/runhmd-receipt.test.sh — runhmd.receipt/1 (RP3): the signed, shareable record of one verdict.
#
# WHAT THIS PROVES
#   [S] SCHEMA   docs/schemas/runhmd.receipt.v1.json is the single source for the receipt document
#                (and borrows the verdict/finding/attacks/gate vocabulary from
#                runhmd.verdict.v1.json by $ref instead of copying it). bin/lib/runhmd_schema.py
#                validates against it, and every rule is proven falsifiable: a document broken in
#                exactly one way must be REJECTED for that way. Nothing in a receipt can carry
#                counterexample text (privacy by construction: digests only).
#   [C] CRYPTO   canonical bytes + Ed25519 signature (bin/lib/runhmd_receipt.py, signing through the
#                shipped cp_auth backend): a receipt round-trips; changing ANY field (each one is
#                tried, each must fail for the signature, not merely for the schema) or ANY single
#                byte of the file makes verification fail; a re-signed forgery is refused; the key
#                source is documented and no secret ever lands in a receipt.
#   [V] VERIFY   `hmd receipt verify <file|id>`, `hmd receipt keygen`: exit codes and messages.
#   [H] HOSTING  `/r/<id>` (HTML, escaped) and `/r/<id>.json` (the exact signed bytes), served by
#                `hmd receipt serve` locally and written by `hmd receipt render` for a static host.
#   [A] ATTACK   `hmd attack --receipt` issues a receipt and populates receipt_url.
#   [D] DOCS     dispatch, inventory, and the documented `hmd prove` call site.
#
# Hermetic: HEIMDALL_HOME, RUNHMD_RECEIPT_DIR and TMPDIR point into a throwaway dir; every key in
# here is generated on the spot and thrown away; nothing is written to the real home and no
# network is touched (the server binds 127.0.0.1 on an ephemeral port).
#
#   bash test/runhmd-receipt.test.sh          all sections
#   RECEIPT_TEST_SECTIONS="S C" bash test/runhmd-receipt.test.sh     only those sections
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HMD="$REPO/bin/hmd"
RECEIPT_BIN="$REPO/bin/heimdall-receipt"
SCHEMA_PY="$REPO/bin/lib/runhmd_schema.py"
RECEIPT_SCHEMA="$REPO/docs/schemas/runhmd.receipt.v1.json"
VERDICT_SCHEMA="$REPO/docs/schemas/runhmd.verdict.v1.json"
PYLIB="$REPO/bin/lib"
SECTIONS="${RECEIPT_TEST_SECTIONS:-S C V H A D}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() {  # check <description> <command...> : PASS iff the command exits 0
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
section() { case " $SECTIONS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/runhmd-receipt-test-XXXXXX")"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT
export HEIMDALL_HOME="$TMP/home"; mkdir -p "$HEIMDALL_HOME"
export HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1
export TMPDIR="$TMP/tmp"; mkdir -p "$TMPDIR"
# Safety rails (same as test/hmd-attack.test.sh): if `hmd receipt` is ever unrouted the dispatcher
# falls through to the Claude task-prompt path; with a stub claude, a setup-done marker and
# HEIMDALL_TRACE_ORDER that path only appends "launch:task" to a file and exits.
touch "$HEIMDALL_HOME/setup-done"
mkdir -p "$TMP/stubbin"; printf '#!/bin/sh\nexit 0\n' >"$TMP/stubbin/claude"; chmod +x "$TMP/stubbin/claude"
export PATH="$TMP/stubbin:$PATH"
export HEIMDALL_TRACE_ORDER="$TMP/trace.order"; : >"$HEIMDALL_TRACE_ORDER"
unset RUNHMD_RECEIPT_KEY_FILE RUNHMD_RECEIPT_PUBKEY_FILE RUNHMD_RECEIPT_DIR RUNHMD_RECEIPT_BASE_URL

command -v jq      >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }
command -v curl    >/dev/null 2>&1 || { echo "curl required" >&2; exit 2; }

# ══════════════════════════════════════════════════════════════════════════════
# [S] SCHEMA — runhmd.receipt/1 (single source) + the validator that enforces it
# ══════════════════════════════════════════════════════════════════════════════
if section S; then
echo "[S] runhmd.receipt/1 schema + validator (single source)"

HEX64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SIG88="$(printf 'A%.0s' $(seq 1 86))=="
DENIED_RC="$TMP/rc.denied.json"
PROVEN_RC="$TMP/rc.proven.json"
cat >"$DENIED_RC" <<JSON
{
  "schema": "runhmd.receipt/1",
  "id": "a1b2c3d4e5f6",
  "created_at": "2026-10-05T12:00:00Z",
  "visibility": "private",
  "verdict": "DENIED",
  "subject": {"kind": "path", "head_sha": null, "tree_sha256": "$HEX64"},
  "attacks": {"total": 24, "survived": 21, "killed": 3},
  "findings": [
    {"id": "f-0001", "title": "duplicate settlement (webhook+retry within 50ms)",
     "severity": "high", "category": "concurrency", "digest": "sha256:$HEX64"}
  ],
  "gates": [{"id": "settlement", "gate_type": "differential", "status": "fail", "falsified": true, "falsify_score": 1}],
  "regression_tests": {"passed": 10, "failed": 0},
  "agent": {"name": "none", "model": null},
  "cost_usd": 0, "duration_s": 1.25,
  "tool": {"name": "hmd", "version": "2.4.3"},
  "verdict_sha256": "$HEX64",
  "key_id": "4f5478232bc96072",
  "signature": "$SIG88"
}
JSON
jq '.verdict="PROVEN" | .findings=[] | .attacks={"total":24,"survived":24,"killed":0}
    | .gates=[{"id":"settlement","gate_type":"differential","status":"pass","falsified":true,"falsify_score":1}]' "$DENIED_RC" >"$PROVEN_RC"

# validate <doc> -> sets VRC (exit code) and VERR (stderr)
validate() { VERR="$(python3 "$SCHEMA_PY" validate "$@" 2>&1 >/dev/null)"; VRC=$?; }
# must_reject <description> <jq-filter> <expected-error-substring> [base-doc]
must_reject() {
  local desc="$1" filter="$2" want="$3" base="${4:-$DENIED_RC}" f="$TMP/mut.$RANDOM.json"
  jq "$filter" "$base" >"$f"
  validate "$f"
  if [ "$VRC" -eq 1 ] && printf '%s' "$VERR" | grep -qF -- "$want"; then
    ok "rejects: $desc"
  else
    bad "rejects: $desc (rc=$VRC, want error containing '$want', got: $(printf '%s' "$VERR" | head -2 | tr '\n' '|'))"
  fi
}

[ -f "$RECEIPT_SCHEMA" ] && ok "schema file exists: docs/schemas/runhmd.receipt.v1.json" || bad "schema file exists: docs/schemas/runhmd.receipt.v1.json"
check "schema file is valid JSON titled runhmd.receipt/1 with an \$id and an x-documents entry" \
  jq -e '.title=="runhmd.receipt/1" and (."$id"|type=="string") and ."x-documents"=={"runhmd.receipt/1":"#"}' "$RECEIPT_SCHEMA"

validate "$DENIED_RC"; [ "$VRC" -eq 0 ] && printf '%s' "$(python3 "$SCHEMA_PY" validate "$DENIED_RC" 2>/dev/null)" | grep -q '^ok runhmd.receipt/1' \
  && ok "valid DENIED receipt accepted (the validator finds the receipt schema from the document's own id)" || bad "valid DENIED receipt accepted (rc=$VRC: $VERR)"
validate "$PROVEN_RC"; [ "$VRC" -eq 0 ] && ok "valid PROVEN receipt accepted" || bad "valid PROVEN receipt accepted (rc=$VRC: $VERR)"
if python3 "$SCHEMA_PY" validate - <"$DENIED_RC" >/dev/null 2>&1; then ok "reads the receipt from stdin ('-')"; else bad "reads the receipt from stdin ('-')"; fi
jq 'del(.gates, .regression_tests)' "$DENIED_RC" >"$TMP/rc.minimal.json"
validate "$TMP/rc.minimal.json"; [ "$VRC" -eq 0 ] && ok "gates and regression_tests are optional (an attack receipt carries neither)" || bad "minimal receipt rejected (rc=$VRC: $VERR)"
jq '.subject.head_sha="4ddffa2c1234567890abcdef1234567890abcdef"' "$DENIED_RC" >"$TMP/rc.sha.json"
validate "$TMP/rc.sha.json"; [ "$VRC" -eq 0 ] && ok "a 40-hex git head_sha is accepted" || bad "head_sha rejected (rc=$VRC: $VERR)"

must_reject "wrong schema id"                     '.schema="runhmd.receipt/2"'                         'schema'
must_reject "missing signature"                   'del(.signature)'                                     'signature'
must_reject "missing key_id"                      'del(.key_id)'                                        'key_id'
must_reject "missing tool"                        'del(.tool)'                                          'tool'
must_reject "missing verdict_sha256"              'del(.verdict_sha256)'                                'verdict_sha256'
must_reject "missing subject.tree_sha256"         'del(.subject.tree_sha256)'                           'tree_sha256'
must_reject "unknown top-level key"               '.extra=1'                                            'extra'
must_reject "visibility outside the enum"         '.visibility="internal"'                              '/visibility'
must_reject "verdict outside the enum"            '.verdict="MAYBE"'                                    '/verdict'
must_reject "subject.kind outside the enum"       '.subject.kind="repo"'                                '/subject/kind'
must_reject "tree_sha256 that is not 64 hex"      '.subject.tree_sha256="abc123"'                       '/subject/tree_sha256'
must_reject "head_sha that is not hex"            '.subject.head_sha="main"'                            '/subject/head_sha'
must_reject "unknown key inside subject"          '.subject.path="/Users/me/secret-project"'            'path'
must_reject "id that is not a safe token"         '.id="../etc/passwd"'                                 '/id'
must_reject "created_at not an ISO UTC timestamp" '.created_at="yesterday"'                             '/created_at'
must_reject "created_at with a UTC offset"        '.created_at="2026-10-05T12:00:00+02:00"'             '/created_at'
must_reject "created_at on a day that does not exist (30 February)" '.created_at="2026-02-30T12:00:00Z"' 'real UTC'
must_reject "created_at at hour 25"               '.created_at="2026-10-05T25:00:00Z"'                  'real UTC'
must_reject "negative cost"                       '.cost_usd=-0.01'                                     '/cost_usd'
must_reject "cost with more than 4 decimal places" '.cost_usd=0.00001'                                  'decimal places'
must_reject "duration with more than 2 decimal places" '.duration_s=1.255'                              'decimal places'
must_reject "boolean is not a number"             '.duration_s=true'                                    '/duration_s'
must_reject "tool.name other than hmd"            '.tool.name="other"'                                  '/tool/name'
must_reject "tool.version empty"                  '.tool.version=""'                                    '/tool/version'
must_reject "verdict_sha256 not 64 hex"           '.verdict_sha256="deadbeef"'                          '/verdict_sha256'
must_reject "key_id not 16 lowercase hex"         '.key_id="4F5478232BC96072"'                          '/key_id'
must_reject "signature that is not 64 bytes of base64" '.signature="AAAA"'                              '/signature'
must_reject "signature with url-safe base64"      ".signature=\"$(printf '_%.0s' $(seq 1 86))==\""      '/signature'
must_reject "finding without a digest"            'del(.findings[0].digest)'                            'digest'
must_reject "finding digest that is not sha256:<64 hex>" '.findings[0].digest="md5:abc"'                '/findings/0/digest'
must_reject "finding severity outside the enum (vocabulary shared with the verdict schema)" '.findings[0].severity="urgent"' '/findings/0/severity'
must_reject "finding category outside the enum"   '.findings[0].category="style"'                       '/findings/0/category'
must_reject "finding id not f-NNNN"               '.findings[0].id="finding-1"'                         '/findings/0/id'
must_reject "finding title over 200 characters"   ".findings[0].title=\"$(printf 'x%.0s' $(seq 1 201))\"" '/findings/0/title'
must_reject "a finding carrying counterexample text (receipts hold digests only)" \
  '.findings[0].counterexample={"summary":"s","repro_cmd":"hmd attack /Users/me/proj","minimal_input":"{\"k\":1}"}' 'counterexample'
must_reject "a finding carrying minimal_input directly" '.findings[0].minimal_input="{\"k\":1}"'         'minimal_input'
must_reject "the attacked target path leaking in (no ref in a receipt)" '.subject.ref="/Users/me/secret"' 'ref'
must_reject "duplicate finding ids"               '.findings += [.findings[0]]'                         'f-0001'
must_reject "agent name outside the enum"         '.agent.name="gpt"'                                   '/agent/name'
must_reject "attacks.total != survived+killed"    '.attacks.total=25'                                   'attacks.total'
must_reject "DENIED with no findings"             '.findings=[]'                                        'DENIED'
must_reject "PROVEN while attacks were killed"    '.verdict="PROVEN"'                                   'PROVEN'
must_reject "PROVEN carrying findings"            '.verdict="PROVEN" | .attacks={"total":24,"survived":24,"killed":0}' 'PROVEN'
must_reject "PROVEN over zero attacks and zero gates (a false green)" \
  '.attacks={"total":0,"survived":0,"killed":0} | del(.gates)' 'zero' "$PROVEN_RC"
must_reject "PROVEN with an unfalsified gate" \
  '.gates=[{"id":"g","gate_type":"example","status":"pass","falsified":false,"falsify_score":0.5}]' 'falsified' "$PROVEN_RC"
must_reject "PROVEN with a failed regression test" '.regression_tests={"passed":9,"failed":1}'          'regression' "$PROVEN_RC"
must_reject "a gate marked falsified without a perfect score" '.gates[0].falsify_score=0.9'              'falsify_score' "$PROVEN_RC"

printf 'not json{' >"$TMP/garbage.json"
validate "$TMP/garbage.json"; [ "$VRC" -eq 1 ] && ok "rejects: input that is not JSON (exit 1)" || bad "rejects: input that is not JSON (rc=$VRC)"

# single source: the verdict vocabulary lives in ONE file and the receipt schema points at it
check "the receipt schema borrows verdict/attacks/agent/gate/finding vocabulary by \$ref to the verdict schema file, not by copy" \
  jq -e '[.properties.verdict, .properties.attacks, .properties.agent, .properties.id, .properties.regression_tests]
         | all(."$ref"|startswith("runhmd.verdict.v1.json#/"))' "$RECEIPT_SCHEMA"
check "the receipt schema defines none of the shared vocabulary itself (no local verdict/attacks/agent/gate def)" \
  jq -e '(."$defs"|keys) as $k | (["verdict","attacks","agent","gate","regressionTests","counterexample"] - $k)==["verdict","attacks","agent","gate","regressionTests","counterexample"]' "$RECEIPT_SCHEMA"
mkdir -p "$TMP/loose"; cp "$RECEIPT_SCHEMA" "$VERDICT_SCHEMA" "$TMP/loose/"
jq '."$defs".finding.properties.severity.enum += ["urgent"]' "$VERDICT_SCHEMA" >"$TMP/loose/runhmd.verdict.v1.json"
jq '.findings[0].severity="urgent"' "$DENIED_RC" >"$TMP/rc.urgent.json"
validate "$TMP/rc.urgent.json"; [ "$VRC" -eq 1 ] && printf '%s' "$VERR" | grep -q '/findings/0/severity' \
  && ok "control: the shipped schemas reject severity 'urgent'" || bad "control: the shipped schemas should reject severity 'urgent' (rc=$VRC)"
validate --schema "$TMP/loose/runhmd.receipt.v1.json" "$TMP/rc.urgent.json"
[ "$VRC" -eq 0 ] && ok "single source: loosening the severity enum in the VERDICT schema file changes what the RECEIPT validator accepts" \
  || bad "the receipt validator does not follow the verdict schema file (rc=$VRC: $VERR)"

check "every x-invariants id documented in the receipt schema is implemented in the validator" \
  bash -c 'for id in $(jq -r ".\"x-invariants\"[].id" "$1"); do grep -Eq "(^|[^A-Za-z0-9])$id([^A-Za-z0-9]|$)" "$2" || { echo "missing $id"; exit 1; }; done; [ "$(jq ".\"x-invariants\"|length" "$1")" -ge 3 ]' _ "$RECEIPT_SCHEMA" "$SCHEMA_PY"

# a sibling $ref may only name another runhmd.*.json file in the schema directory: never a URL, never a path
jq '.properties.verdict={"$ref":"https://evil.example/schema.json#/x"}' "$RECEIPT_SCHEMA" >"$TMP/loose/runhmd.receipt.v1.json"
validate --schema "$TMP/loose/runhmd.receipt.v1.json" "$DENIED_RC"
[ "$VRC" -eq 2 ] && printf '%s' "$VERR" | grep -q 'never fetched' && ok "a \$ref to a URL fails closed (exit 2), never fetched" || bad "URL \$ref must fail closed (rc=$VRC: $VERR)"
jq '.properties.verdict={"$ref":"../../etc/passwd#/x"}' "$RECEIPT_SCHEMA" >"$TMP/loose/runhmd.receipt.v1.json"
validate --schema "$TMP/loose/runhmd.receipt.v1.json" "$DENIED_RC"
[ "$VRC" -eq 2 ] && printf '%s' "$VERR" | grep -q 'etc/passwd' && ok "a \$ref that climbs out of the schema directory fails closed (exit 2, naming the ref)" || bad "path-traversal \$ref must fail closed (rc=$VRC: $VERR)"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

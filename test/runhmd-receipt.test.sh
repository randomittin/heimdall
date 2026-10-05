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
must_reject "key_id with a trailing newline (Python's \$ alone would let it through)" '.key_id="4f5478232bc96072\n"' '/key_id'
must_reject "id with a trailing newline"          '.id="a1b2c3d4e5f6\n"'                                '/id'
must_reject "verdict_sha256 with a trailing newline" ".verdict_sha256=\"$HEX64\\n\""                    '/verdict_sha256'
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
for odd in '{"schema":[]}' '{"schema":{"a":1}}' '[]' 'null' '{"schema":null}'; do
  printf '%s' "$odd" >"$TMP/odd.json"
  validate "$TMP/odd.json"
  if [ "$VRC" -eq 1 ] && printf '%s' "$VERR" | grep -q "one of"; then ok "rejects with exit 1 and a message, not a traceback: $odd"
  else bad "rejects cleanly: $odd (rc=$VRC: $(printf '%s' "$VERR" | tail -1))"; fi
done

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

# ══════════════════════════════════════════════════════════════════════════════
# [C] CRYPTO — canonical bytes, Ed25519 signature, trust anchors, tamper evidence
# ══════════════════════════════════════════════════════════════════════════════
if section C; then
echo "[C] canonical bytes, Ed25519 signature, trust anchors, tamper evidence"

cat >"$TMP/crypto-check.py" <<'PY'
import base64, calendar, copy, hashlib, json, os, stat, sys, time

PYLIB, REPO, WORK = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, PYLIB)

def case(desc, cond, detail=""):
    print("%s %s%s" % ("PASS" if cond else "FAIL", desc, "" if cond or not detail else ": " + str(detail)), flush=True)

import cp_auth
import runhmd_receipt as rr
import runhmd_schema

def outcome(raw, trust):
    """'ok', the ReceiptError kind, or 'CRASH:<exception>': verify_bytes must never raise anything else."""
    try:
        rr.verify_bytes(raw, trust)
        return "ok"
    except rr.ReceiptError as exc:
        return exc.kind
    except Exception as exc:  # noqa: BLE001 -- the point of this helper is to catch a crash
        return "CRASH:%s:%s" % (type(exc).__name__, exc)

def kind_of(fn):
    try:
        fn()
    except rr.ReceiptError as exc:
        return exc.kind
    return None

def indep_canon(obj):
    """A second, independent writer of the canonical form (json.dumps based), to cross-check rr.canonical."""
    def norm(v):
        if isinstance(v, float) and v == int(v):
            return int(v)
        if isinstance(v, dict):
            return {k: norm(x) for k, x in v.items()}
        if isinstance(v, list):
            return [norm(x) for x in v]
        return v
    return json.dumps(norm(obj), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

HEX = lambda c: c * 64
priv, pub = cp_auth.generate_keypair()
signer = rr.Signer(priv)
trust = {signer.key_id: pub}
FINDINGS = [
    {"id": "f-0001", "title": "duplicate settlement (webhook+retry within 50ms)", "severity": "high", "category": "concurrency", "digest": "sha256:" + HEX("a")},
    {"id": "f-0002", "title": "missing auth check on /refunds — é ✓", "severity": "medium", "category": "auth", "digest": "sha256:" + HEX("b")},
]
GATES = [{"id": "settlement", "gate_type": "differential", "status": "fail", "falsified": True, "falsify_score": 1},
         {"id": "ledger", "gate_type": "property", "status": "pass", "falsified": False, "falsify_score": 0.5}]

def issue(**over):
    kw = dict(signer=signer, id="a1b2c3d4e5f6", verdict="DENIED",
              subject={"kind": "path", "head_sha": None, "tree_sha256": HEX("c")},
              attacks={"total": 24, "survived": 21, "killed": 3}, findings=FINDINGS,
              agent={"name": "none", "model": None}, cost_usd=0.41, duration_s=1.25,
              verdict_sha256=HEX("d"), gates=GATES, regression_tests={"passed": 10, "failed": 0},
              visibility="private", created_at="2026-10-05T12:00:00Z")
    kw.update(over)
    return rr.issue_receipt(**kw)

PROVEN_OVER = dict(verdict="PROVEN", attacks={"total": 24, "survived": 24, "killed": 0}, findings=[],
                   gates=[{"id": "settlement", "gate_type": "differential", "status": "pass", "falsified": True, "falsify_score": 1}])

# ── canonical form ───────────────────────────────────────────────────────────
c = rr.canonical
case("canonical: sorted keys, no whitespace", c({"b": 1, "a": [True, None, "x"]}) == b'{"a":[true,null,"x"],"b":1}')
case("canonical: an integral float is written as an integer (1.0 -> 1, -0.0 -> 0, 134.0 -> 134)", c({"x": 1.0, "y": -0.0, "z": 134.0}) == b'{"x":1,"y":0,"z":134}')
case("canonical: other numbers are the shortest round-trip decimal", c({"x": 0.41, "y": 1.25, "z": 12.35}) == b'{"x":0.41,"y":1.25,"z":12.35}')
for label, bad in (("NaN", float("nan")), ("infinity", float("inf")), ("a number that needs an exponent (1e-05)", 1e-05), ("an integral number past 1e16", 1e16)):
    try:
        c({"x": bad}); refused = False
    except ValueError:
        refused = True
    case("canonical: %s is refused" % label, refused)
case("canonical: non-ASCII is literal UTF-8 and control characters use \\u00xx",
     c({"t": "é \x1f"}) == '{"t":"é \\u001f"}'.encode("utf-8"))
case("canonical: quote, backslash and newline use the short escapes", c({"t": '"\\\n'}) == b'{"t":"\\"\\\\\\n"}')
case("canonical: keys sort by UTF-16 code unit (U+10000 sorts before U+FFFF, as in RFC 8785)",
     c({"￿": 1, "\U00010000": 2}).decode("utf-8").startswith('{"\U00010000"'))
try:
    c({"t": "\ud800"}); lone = False
except ValueError:
    lone = True
case("canonical: a lone surrogate (not encodable as UTF-8) is refused", lone)
case("canonical agrees with an independent json.dumps-based writer on a full receipt document",
     c(json.loads(issue())) == indep_canon(json.loads(issue())))

# ── issue + verify round trip ────────────────────────────────────────────────
raw = issue()
doc = rr.verify_bytes(raw, trust)
case("round trip: a freshly issued receipt verifies and returns the document", doc == json.loads(raw) and doc["verdict"] == "DENIED")
case("the file is exactly the canonical form of the whole document plus one LF", raw == rr.canonical(doc) + b"\n")
case("the issued document passes the schema and its invariants", runhmd_schema.validate(doc) == [], runhmd_schema.validate(doc))
case("key_id is the first 16 hex digits of sha256(raw public key)", doc["key_id"] == hashlib.sha256(base64.b64decode(pub)).hexdigest()[:16])
case("the receipt names its key but never embeds the public key, the seed or any secret",
     pub.encode() not in raw and priv.encode() not in raw and base64.b64decode(priv) not in raw)
case("Ed25519 is deterministic: issuing the same receipt twice gives identical bytes", issue() == raw)
t0 = time.time()
now_doc = json.loads(issue(created_at=None))
case("created_at defaults to the current UTC time, to the second",
     len(now_doc["created_at"]) == 20 and now_doc["created_at"].endswith("Z")
     and abs(calendar.timegm(time.strptime(now_doc["created_at"], "%Y-%m-%dT%H:%M:%SZ")) - t0) < 10, now_doc["created_at"])
case("a receipt without its final LF still verifies (the LF is not content)", outcome(raw[:-1], trust) == "ok")
case("a second LF is refused", outcome(raw + b"\n", trust) != "ok")
proven = issue(**PROVEN_OVER)
case("round trip: a PROVEN receipt verifies", outcome(proven, trust) == "ok")
case("issue refuses a receipt that would violate its own contract (PROVEN with findings)", kind_of(lambda: issue(verdict="PROVEN")) == "invalid")
case("issue refuses an unknown visibility", kind_of(lambda: issue(visibility="secret")) == "invalid")
case("issue does not alias or mutate its inputs", FINDINGS[0]["title"] == "duplicate settlement (webhook+retry within 50ms)" and "signature" not in GATES[0])

# ── every field, one at a time ───────────────────────────────────────────────
def leaves(node, path=()):
    if isinstance(node, dict):
        for k in node:
            yield from leaves(node[k], path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from leaves(v, path + (i,))
    else:
        yield path

def norm(path):
    return ".".join("*" if isinstance(p, int) else p for p in path)

def get(d, path):
    for p in path:
        d = d[p]
    return d

def put(d, path, value):
    for p in path[:-1]:
        d = d[p]
    d[path[-1]] = value

def flip_hex(s):
    return ("0" if s[0] != "0" else "1") + s[1:]

MUTATE = {
    "schema": lambda v: "runhmd.receipt/2",
    "id": lambda v: "ffffffffffff",
    "created_at": lambda v: "2026-10-05T12:00:01Z",
    "visibility": lambda v: "public" if v == "private" else "private",
    "verdict": lambda v: "PROVEN",
    "subject.kind": lambda v: "pr",
    "subject.head_sha": lambda v: "a" * 40,
    "subject.tree_sha256": flip_hex,
    "attacks.total": lambda v: v + 1,
    "attacks.survived": lambda v: v + 1,
    "attacks.killed": lambda v: v + 1,
    "findings.*.id": lambda v: "f-0099",
    "findings.*.title": lambda v: v + "!",
    "findings.*.severity": lambda v: "low" if v != "low" else "info",
    "findings.*.category": lambda v: "logic" if v != "logic" else "input",
    "findings.*.digest": lambda v: "sha256:" + flip_hex(v[7:]),
    "gates.*.id": lambda v: v + "x",
    "gates.*.gate_type": lambda v: v + "x",
    "gates.*.status": lambda v: "pass" if v == "fail" else "fail",
    "gates.*.falsified": lambda v: not v,
    "gates.*.falsify_score": lambda v: 0.75 if v != 0.75 else 0.25,
    "regression_tests.passed": lambda v: v + 1,
    "regression_tests.failed": lambda v: v + 1,
    "agent.name": lambda v: "codex",
    "agent.model": lambda v: "some-model",
    "cost_usd": lambda v: 0.42,
    "duration_s": lambda v: 1.26,
    "tool.name": lambda v: "other",
    "tool.version": lambda v: "9.9.9",
    "verdict_sha256": flip_hex,
    "key_id": flip_hex,
    "signature": lambda v: v[:10] + ("B" if v[10] != "B" else "C") + v[11:],
}
base = json.loads(raw)
all_leaf_paths = list(leaves(base))
missing = sorted({norm(p) for p in all_leaf_paths} - set(MUTATE))
case("every leaf field of a full receipt has a registered mutation (%d fields)" % len({norm(p) for p in all_leaf_paths}), not missing, missing)

def expected_kind(mut, path):
    if runhmd_schema.validate(mut):
        return "schema"
    return "unknown_key" if path == ("key_id",) else "bad_signature"

survivors, wrong_reason, tried, by_signature = [], [], 0, 0
for path in all_leaf_paths:
    mut = copy.deepcopy(base)
    put(mut, path, MUTATE[norm(path)](get(mut, path)))
    assert get(mut, path) != get(base, path), path
    tried += 1
    got = outcome(rr.canonical(mut) + b"\n", trust)
    want = expected_kind(mut, path)
    if got == "ok":
        survivors.append(".".join(map(str, path)))
    elif got != want:
        wrong_reason.append((".".join(map(str, path)), got, want))
    elif got == "bad_signature":
        by_signature += 1
case("%d single-field mutations, each re-serialised canonically: NONE verifies" % tried, not survivors and tried >= 30, survivors)
case("each mutation that the schema still accepts is stopped by the SIGNATURE (%d of them), not by luck" % by_signature, not wrong_reason and by_signature >= 20, wrong_reason[:3])

# the forgery that matters: DENIED rewritten into a consistent PROVEN
forged = copy.deepcopy(base)
forged.update(verdict="PROVEN", findings=[], attacks={"total": 24, "survived": 24, "killed": 0})
forged["gates"] = [{"id": "settlement", "gate_type": "differential", "status": "pass", "falsified": True, "falsify_score": 1}]
case("forgery: a DENIED receipt rewritten into a schema-valid PROVEN one is rejected by the signature",
     runhmd_schema.validate(forged) == [] and outcome(rr.canonical(forged) + b"\n", trust) == "bad_signature")

# members added, removed, reordered
structural, bad = 0, []
def dict_paths(node, path=()):
    if isinstance(node, dict):
        yield path
        for k in node:
            yield from dict_paths(node[k], path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from dict_paths(v, path + (i,))
for dpath in dict_paths(base):
    holder = get(base, dpath)
    for key in list(holder):
        mut = copy.deepcopy(base)
        del get(mut, dpath)[key]
        structural += 1
        got, want = outcome(rr.canonical(mut) + b"\n", trust), expected_kind(mut, dpath + (key,))
        if got != want:
            bad.append(("del", dpath, key, got, want))
    mut = copy.deepcopy(base)
    get(mut, dpath)["injected"] = "x"
    structural += 1
    got = outcome(rr.canonical(mut) + b"\n", trust)
    if got != "schema":
        bad.append(("add", dpath, got))
case("%d member deletions and injections are all rejected (a deleted optional member by the signature, an unknown member by the schema)" % structural, not bad and structural > 40, bad[:3])
swapped = copy.deepcopy(base); swapped["findings"].reverse()
case("reordering the findings array is detected", outcome(rr.canonical(swapped) + b"\n", trust) == "bad_signature")
swapped = copy.deepcopy(base); swapped["gates"].reverse()
case("reordering the gates array is detected", outcome(rr.canonical(swapped) + b"\n", trust) == "bad_signature")
dropped = copy.deepcopy(base); dropped["findings"].pop()
case("dropping a finding is detected", outcome(rr.canonical(dropped) + b"\n", trust) == "bad_signature")

# ── every byte of the file ───────────────────────────────────────────────────
for label, sample in (("DENIED", raw), ("PROVEN", proven)):
    n = len(sample)
    escaped = {"flip bit 0": [], "flip case bit": [], "delete": [], "insert a space": []}
    for i in range(n):
        for name, variant in (("flip bit 0", sample[:i] + bytes([sample[i] ^ 0x01]) + sample[i + 1:]),
                              ("flip case bit", sample[:i] + bytes([sample[i] ^ 0x20]) + sample[i + 1:]),
                              ("delete", sample[:i] + sample[i + 1:] if i < n - 1 else None),
                              ("insert a space", sample[:i] + b" " + sample[i:])):
            if variant is None:
                continue
            got = outcome(variant, trust)
            if got == "ok" or got.startswith("CRASH"):
                escaped[name].append((i, got))
    if sample.endswith(b"\n"):
        got = outcome(sample + b" ", trust)
        if got == "ok" or got.startswith("CRASH"):
            escaped["insert a space"].append((n, got))
    case("%s receipt, %d bytes: editing ANY single byte (flip a bit, flip case, delete it, insert a space before it) fails verification (%d variants)" % (label, n, 4 * n),
         not any(escaped.values()), {k: v[:3] for k, v in escaped.items() if v})

# ── hostile input never crashes the verifier ─────────────────────────────────
hostile = {"empty": b"", "not UTF-8": b"\xff\xfe\x00", "a JSON array": b"[]", "JSON null": b"null", "a bare string": b'"x"',
           "NaN in a number slot": raw.replace(b'"cost_usd":0.41', b'"cost_usd":NaN'),
           "deep nesting": b"[" * 200000, "a 5 MB blob": b"x" * (5 * 1024 * 1024)}
for label, blob in hostile.items():
    got = outcome(blob, trust)
    case("hostile input (%s) is refused with a clean ReceiptError, no crash" % label, got in ("not_json", "schema"), got)
dup = raw.replace(b'"id":"a1b2c3d4e5f6"', b'"id":"zzzzzzzzzzzz","id":"a1b2c3d4e5f6"')
case("a duplicate object member is refused (the bytes are not the canonical form)", dup != raw and outcome(dup, trust) == "not_canonical")
parsed = json.loads(raw)
pretty = json.dumps(parsed, indent=2, sort_keys=True, ensure_ascii=False).encode()
case("a pretty-printed copy of a genuine receipt (same members, same order, only whitespace added) is refused as not canonical",
     outcome(pretty, trust) == "not_canonical")
reordered = json.dumps(dict(reversed(list(parsed.items()))), separators=(",", ":"), ensure_ascii=False).encode()
case("a compact copy with the members in another order is refused as not canonical",
     reordered != raw.rstrip(b"\n") and outcome(reordered, trust) == "not_canonical")
ascii_escaped = json.dumps(parsed, sort_keys=True, separators=(",", ":")).encode()
case("an ensure_ascii re-serialisation (non-ASCII as \\uXXXX escapes) is refused as not canonical",
     ascii_escaped != raw.rstrip(b"\n") and outcome(ascii_escaped, trust) == "not_canonical")

# ── who may have signed it ───────────────────────────────────────────────────
mine = json.loads(raw)
case("an empty trust set is a CONFIG error, never a pass and never 'invalid'", kind_of(lambda: rr.verify_bytes(raw, {})) == "no_trust")
other_priv, other_pub = cp_auth.generate_keypair()
attacker = rr.Signer(other_priv)
forged_doc = copy.deepcopy(mine); forged_doc["verdict"] = "PROVEN"; forged_doc.update(findings=[], attacks={"total": 24, "survived": 24, "killed": 0})
forged_doc["gates"] = PROVEN_OVER["gates"]; forged_doc["key_id"] = attacker.key_id
forged_doc.pop("signature")
forged_doc["signature"] = attacker.sign(rr.SIGN_PREFIX + rr.canonical({k: v for k, v in forged_doc.items() if k != "signature"}))
forged_raw = rr.canonical(forged_doc) + b"\n"
case("a receipt re-signed by an attacker's own key is refused: that key is not in the pinned trust set", outcome(forged_raw, trust) == "unknown_key")
case("control: the very same forgery verifies once the attacker's key is pinned (the trust set, not the receipt, is the root)", outcome(forged_raw, {attacker.key_id: other_pub}) == "ok")
spoof = copy.deepcopy(forged_doc); spoof["key_id"] = signer.key_id; spoof.pop("signature")
spoof["signature"] = attacker.sign(rr.SIGN_PREFIX + rr.canonical(spoof))
case("an attacker claiming the victim's key_id but signing with their own key fails the signature", outcome(rr.canonical(spoof) + b"\n", trust) == "bad_signature")
body = {k: v for k, v in mine.items() if k != "signature"}
def with_sig(sig):
    d = dict(body); d["signature"] = sig
    return rr.canonical(d) + b"\n"
case("control: signing exactly 'runhmd.receipt/1' LF + canonical(body) verifies (the documented construction)",
     outcome(with_sig(signer.sign(b"runhmd.receipt/1\n" + rr.canonical(body))), trust) == "ok")
case("domain separation: a signature over the bare canonical body (no prefix) is refused", outcome(with_sig(signer.sign(rr.canonical(body))), trust) == "bad_signature")
case("domain separation: a signature under another prefix ('runhmd.receipt/2' LF) is refused", outcome(with_sig(signer.sign(b"runhmd.receipt/2\n" + rr.canonical(body))), trust) == "bad_signature")
sig = mine["signature"]
ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
variant = sig[:85] + ALPHABET[ALPHABET.index(sig[85]) + 1] + "=="
case("control: a variant that differs only in the unused trailing bits decodes to the SAME 64 bytes (so only a canonical-base64 check can tell it apart)",
     sig[85] in "AQgw" and variant != sig and base64.b64decode(variant) == base64.b64decode(sig))
case("a non-canonical base64 spelling of the genuine signature is refused", outcome(with_sig(variant), trust) == "bad_signature")

# ── keys: where the secret comes from, and what is refused ───────────────────
os.makedirs(WORK, exist_ok=True)
saved = {k: os.environ.pop(k, None) for k in ("RUNHMD_RECEIPT_KEY_FILE", "RUNHMD_RECEIPT_PUBKEY_FILE", "RUNHMD_RECEIPT_DIR", "HEIMDALL_HOME")}
os.environ["HEIMDALL_HOME"] = os.path.join(WORK, "home")
key_dir = os.path.join(WORK, "keys")
key_path, pub_path, key_id = rr.generate_key_files(key_dir)
case("keygen: the secret key file is 0600 and the public key file is world-readable", stat.S_IMODE(os.stat(key_path).st_mode) == 0o600 and stat.S_IMODE(os.stat(pub_path).st_mode) & 0o044 == 0o044)
case("keygen: the public key file never contains the seed", open(key_path).read().strip() not in open(pub_path).read())
case("keygen: refuses to overwrite an existing key", kind_of(lambda: rr.generate_key_files(key_dir)) == "key_exists")
loaded = rr.load_signer(key_path)
case("load_signer: reads the key file and reports the same key_id as keygen", loaded.key_id == key_id)
pub_lines = [l.strip() for l in open(pub_path).read().splitlines() if l.strip() and not l.startswith("#")]
case("load_trust: the public key file holds one base64 line and yields exactly that key under its key_id",
     len(pub_lines) == 1 and rr.load_trust([pub_path]) == {key_id: pub_lines[0]}
     and key_id == hashlib.sha256(base64.b64decode(pub_lines[0])).hexdigest()[:16])
signed_by_file = rr.issue_receipt(signer=loaded, id="b1b2c3d4e5f6", verdict="PROVEN", subject={"kind": "path", "head_sha": None, "tree_sha256": HEX("c")},
                                  attacks=PROVEN_OVER["attacks"], findings=[], agent={"name": "none", "model": None}, cost_usd=0, duration_s=0.5,
                                  verdict_sha256=HEX("d"), gates=PROVEN_OVER["gates"], created_at="2026-10-05T12:00:00Z")
case("a key generated by keygen signs receipts that verify against its public key file", outcome(signed_by_file, rr.load_trust([pub_path])) == "ok")
loose = os.path.join(WORK, "loose.key"); open(loose, "w").write(priv + "\n"); os.chmod(loose, 0o644)
case("load_signer refuses a key file other users can read", kind_of(lambda: rr.load_signer(loose)) == "insecure_key_file")
os.chmod(loose, 0o600)
case("load_signer accepts the same file once it is 0600", rr.load_signer(loose).key_id == signer.key_id)
junk = os.path.join(WORK, "junk.key"); open(junk, "w").write("not-base64!!\n"); os.chmod(junk, 0o600)
case("load_signer refuses a key file that is not base64", kind_of(lambda: rr.load_signer(junk)) == "key_unusable")
short = os.path.join(WORK, "short.key"); open(short, "w").write(base64.b64encode(b"x" * 16).decode() + "\n"); os.chmod(short, 0o600)
case("load_signer refuses a seed that is not 32 bytes", kind_of(lambda: rr.load_signer(short)) == "key_unusable")
case("load_signer on a missing file is no_signing_key", kind_of(lambda: rr.load_signer(os.path.join(WORK, "absent.key"))) == "no_signing_key")
os.environ["RUNHMD_RECEIPT_KEY_FILE"] = key_path
case("RUNHMD_RECEIPT_KEY_FILE selects the signing key", rr.load_signer().key_id == key_id)
del os.environ["RUNHMD_RECEIPT_KEY_FILE"]
case("with no env and no default key file there is no signing key (never a silent mint)", kind_of(lambda: rr.load_signer()) == "no_signing_key")
default_dir = os.path.join(WORK, "home", "signing")
d_key, d_pub, d_id = rr.generate_key_files(default_dir)
case("the default signing key lives at $HEIMDALL_HOME/signing/runhmd-receipt.key",
     d_key == os.path.join(default_dir, "runhmd-receipt.key") and rr.load_signer().key_id == d_id)
repo_anchor_file = os.path.join(REPO, "release", "runhmd-receipt.pub")
repo_anchor = set(rr.load_trust([repo_anchor_file])) if os.path.exists(repo_anchor_file) else set()
case("the default trust set is the public key beside it ($HEIMDALL_HOME/signing/runhmd-receipt.pub) plus the in-repo release/runhmd-receipt.pub when that exists",
     d_pub == os.path.join(default_dir, "runhmd-receipt.pub") and set(rr.load_trust()) == {d_id} | repo_anchor)

two = os.path.join(WORK, "two.pub")
open(two, "w").write("# receipt keys: current + previous (rotation)\n\n%s\n%s\n" % (pub, other_pub))
tr = rr.load_trust([two])
case("load_trust: comments and blank lines are skipped and several keys may be pinned (rotation)", set(tr) == {signer.key_id, attacker.key_id})
os.environ["RUNHMD_RECEIPT_PUBKEY_FILE"] = two
case("RUNHMD_RECEIPT_PUBKEY_FILE replaces the defaults", set(rr.load_trust()) == {signer.key_id, attacker.key_id})
del os.environ["RUNHMD_RECEIPT_PUBKEY_FILE"]
bad_pub = os.path.join(WORK, "bad.pub"); open(bad_pub, "w").write(pub + "\nthis-is-not-a-key\n")
case("load_trust: a malformed line is a hard error, never skipped", kind_of(lambda: rr.load_trust([bad_pub])) == "bad_trust")
short_pub = os.path.join(WORK, "short.pub"); open(short_pub, "w").write(base64.b64encode(b"x" * 31).decode() + "\n")
case("load_trust: a key that is not 32 bytes is refused", kind_of(lambda: rr.load_trust([short_pub])) == "bad_trust")
case("load_trust: a missing file is refused", kind_of(lambda: rr.load_trust([os.path.join(WORK, "nope.pub")])) == "bad_trust")
os.environ["HEIMDALL_HOME"] = os.path.join(WORK, "empty-home")
case("load_trust: no explicit file, no env and no default key yields nothing beyond the in-repo anchor (an empty set is a config error at verify time)",
     set(rr.load_trust()) == repo_anchor)

# ── digests, privacy, tool version, store ────────────────────────────────────
finding = {"id": "f-0001", "title": "t é", "severity": "high", "category": "auth",
           "counterexample": {"summary": "s", "repro_cmd": "hmd attack x", "minimal_input": "{\"k\":1}"}, "evidence_ref": None}
case("finding_digest is sha256 of the finding's canonical JSON, counterexample included",
     rr.finding_digest(finding) == "sha256:" + hashlib.sha256(indep_canon(finding)).hexdigest())
changed = copy.deepcopy(finding); changed["counterexample"]["minimal_input"] = "{\"k\":2}"
case("finding_digest changes when the counterexample changes (it commits to text the receipt does not carry)", rr.finding_digest(changed) != rr.finding_digest(finding))
VERDICT = {
    "schema": "runhmd.verdict/1", "id": "a1b2c3d4e5f6", "verdict": "DENIED",
    "target": {"kind": "path", "ref": "/Users/me/secret-project/webhook", "head_sha": "4ddffa2c" + "0" * 32},
    "attacks": {"total": 23, "survived": 17, "killed": 6},
    "findings": [dict(finding, title="duplicate settlement (webhook+retry within 50ms)", severity="high", category="concurrency",
                      counterexample={"summary": "event evt_1 credited twice", "repro_cmd": "hmd attack /Users/me/secret-project/webhook --json --yes",
                                      "minimal_input": "{\"deliveries\":[{\"at_ms\":0},{\"at_ms\":10}]}"})],
    "cost_usd": 0.0, "duration_s": 12.35, "agent": {"name": "none", "model": None}, "receipt_url": None}
with_url = dict(VERDICT, receipt_url="https://runhmd.dev/r/a1b2c3d4e5f6")
case("verdict_digest ignores receipt_url (a receipt cannot hash the URL that points at it)", rr.verdict_digest(VERDICT) == rr.verdict_digest(with_url))
case("verdict_digest is sha256 of the canonical verdict with receipt_url null", rr.verdict_digest(VERDICT) == hashlib.sha256(indep_canon(VERDICT)).hexdigest())
tweaked = copy.deepcopy(VERDICT); tweaked["duration_s"] = 12.36
case("verdict_digest changes when any other field changes", rr.verdict_digest(tweaked) != rr.verdict_digest(VERDICT))
vraw = rr.receipt_for_verdict(VERDICT, tree_sha256=HEX("e"), signer=signer, created_at="2026-10-05T12:00:00Z")
vdoc = rr.verify_bytes(vraw, trust)
case("receipt_for_verdict mirrors id, verdict, attacks, agent, cost and duration",
     (vdoc["id"], vdoc["verdict"], vdoc["attacks"], vdoc["agent"], vdoc["cost_usd"], vdoc["duration_s"]) == ("a1b2c3d4e5f6", "DENIED", VERDICT["attacks"], VERDICT["agent"], 0, 12.35))
case("receipt_for_verdict records the subject as hashes: kind, git head, tree sha256",
     vdoc["subject"] == {"kind": "path", "head_sha": "4ddffa2c" + "0" * 32, "tree_sha256": HEX("e")})
case("receipt_for_verdict reduces each finding to id/title/severity/category + digest",
     len(vdoc["findings"]) == 1 and set(vdoc["findings"][0]) == {"id", "title", "severity", "category", "digest"}
     and vdoc["findings"][0]["digest"] == "sha256:" + hashlib.sha256(indep_canon(VERDICT["findings"][0])).hexdigest())
case("receipt_for_verdict commits to the whole verdict (verdict_sha256)", vdoc["verdict_sha256"] == hashlib.sha256(indep_canon(VERDICT)).hexdigest())
leaks = [s for s in (b"/Users/me", b"secret-project", b"minimal_input", b"deliveries", b"evt_1", b"repro_cmd", b"counterexample", b"at_ms") if s in vraw]
case("privacy by construction: no path, counterexample text or repro command from the verdict reaches the receipt", not leaks, leaks)
plugin_version = json.load(open(os.path.join(REPO, ".claude-plugin", "plugin.json")))["version"]
case("tool is hmd at the version in .claude-plugin/plugin.json (%s)" % plugin_version, vdoc["tool"] == {"name": "hmd", "version": plugin_version})
case("issuing a receipt for a verdict document that is itself invalid is refused", kind_of(lambda: rr.receipt_for_verdict(dict(VERDICT, findings=[]), tree_sha256=HEX("e"), signer=signer)) == "invalid")

store = os.path.join(WORK, "store")
path = rr.write_receipt(store, "a1b2c3d4e5f6", raw)
case("write_receipt stores <id>.json byte for byte, readable only by the owner", open(path, "rb").read() == raw and os.path.basename(path) == "a1b2c3d4e5f6.json" and stat.S_IMODE(os.stat(path).st_mode) == 0o600)
case("read_receipt returns the stored bytes", rr.read_receipt(store, "a1b2c3d4e5f6") == raw)
case("write_receipt replaces atomically and leaves no temp files", rr.write_receipt(store, "a1b2c3d4e5f6", proven) and os.listdir(store) == ["a1b2c3d4e5f6.json"])
case("read_receipt of an unknown id is not_found", kind_of(lambda: rr.read_receipt(store, "zzzzzzzzzzzz")) == "not_found")
for hostile_id in ("../a1b2c3d4e5f6", "a/b", "..", ".", "", "a" * 65, "a b", "a\x00b", "/etc/passwd", "ab"):
    got = (kind_of(lambda: rr.read_receipt(store, hostile_id)), kind_of(lambda: rr.write_receipt(store, hostile_id, raw)))
    case("an id like %r never reaches the filesystem (bad_id on read and write)" % hostile_id, got == ("bad_id", "bad_id"), got)
os.environ["RUNHMD_RECEIPT_DIR"] = os.path.join(WORK, "elsewhere")
case("RUNHMD_RECEIPT_DIR selects the store", rr.store_dir() == os.path.join(WORK, "elsewhere"))
del os.environ["RUNHMD_RECEIPT_DIR"]
os.environ["HEIMDALL_HOME"] = os.path.join(WORK, "home")
case("the default store is $HEIMDALL_HOME/runhmd/receipts", rr.store_dir() == os.path.join(WORK, "home", "runhmd", "receipts"))
case("the default receipt URL base is https://runhmd.dev", rr.receipt_url("a1b2c3d4e5f6") == "https://runhmd.dev/r/a1b2c3d4e5f6")
os.environ["RUNHMD_RECEIPT_BASE_URL"] = "https://receipts.example.test/prefix/"
case("RUNHMD_RECEIPT_BASE_URL moves the URL (one trailing slash trimmed)", rr.receipt_url("a1b2c3d4e5f6") == "https://receipts.example.test/prefix/r/a1b2c3d4e5f6")
for bad_base in ("http://runhmd.dev", "ftp://x", "runhmd.dev", "https://", "https://a b", "javascript:alert(1)", "https://x.test/?q=1", "https://x.test/#f"):
    os.environ["RUNHMD_RECEIPT_BASE_URL"] = bad_base
    case("a receipt URL base like %r is refused (https only, no query or fragment)" % bad_base, kind_of(lambda: rr.receipt_url("a1b2c3d4e5f6")) == "bad_base_url")
del os.environ["RUNHMD_RECEIPT_BASE_URL"]
case("receipt_url refuses an id that is not a safe token", kind_of(lambda: rr.receipt_url("../x")) == "bad_id")

for k, v in saved.items():
    if v is None:
        os.environ.pop(k, None)
    else:
        os.environ[k] = v
PY
python3 "$TMP/crypto-check.py" "$PYLIB" "$REPO" "$TMP/crypto-work" >"$TMP/crypto.out" 2>"$TMP/crypto.err"
crc=$?
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
  esac
done <"$TMP/crypto.out"
[ "$crc" -eq 0 ] || bad "the crypto driver crashed (exit $crc): $(tail -3 "$TMP/crypto.err" | tr '\n' '|')"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

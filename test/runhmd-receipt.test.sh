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
other_priv, other_pub = cp_auth.generate_keypair()
attacker = rr.Signer(other_priv)
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
for label, bad in (("NaN", float("nan")), ("infinity", float("inf")), ("a number that needs an exponent (1e-05)", 1e-05),
                   ("an integral float past 2**53", 1e16), ("an integer past 2**53 (a JavaScript verifier would misread it)", 2 ** 53)):
    try:
        c({"x": bad}); refused = False
    except ValueError:
        refused = True
    case("canonical: %s is refused" % label, refused)
case("canonical: the largest interoperable integer (2**53 - 1) is written as is", c({"x": 2 ** 53 - 1}) == b'{"x":9007199254740991}')
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
liar = rr.Signer(priv)
liar.sign = attacker.sign       # signs with ANOTHER key while the receipt will name this signer's key_id
case("issue refuses to hand out a receipt it cannot verify itself (a signer whose signatures do not match its key)",
     kind_of(lambda: issue(signer=liar)) == "invalid")
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
doc_v, raw_v = rr.load_verified(store, "a1b2c3d4e5f6", trust)
case("load_verified returns the verified document together with the exact stored bytes", doc_v["verdict"] == "PROVEN" and raw_v == proven)
rr.write_receipt(store, "b1b2c3d4e5f6", proven)
case("load_verified refuses a valid receipt filed under another receipt's id (it would be served at the wrong URL)",
     kind_of(lambda: rr.load_verified(store, "b1b2c3d4e5f6", trust)) == "id_mismatch")
rr.write_receipt(store, "c1b2c3d4e5f6", proven[:100] + bytes([proven[100] ^ 1]) + proven[101:])
case("load_verified refuses a stored receipt whose bytes were altered",
     kind_of(lambda: rr.load_verified(store, "c1b2c3d4e5f6", trust)) in ("not_json", "schema", "not_canonical", "bad_signature"))
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

# rcpt <args...>: run `hmd receipt` from the repo root with stdin from /dev/null; sets ROUT RERR RRC
rcpt() {
  ROUT="$TMP/rcpt.out"; RERR="$TMP/rcpt.err"
  (cd "$REPO" && "$HMD" receipt "$@" </dev/null >"$ROUT" 2>"$RERR"); RRC=$?
}
modeof() { python3 -c 'import os,stat,sys; print("%o" % stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$1"; }
# flip <file> <needle> <replacement>: replace the first occurrence of a text in a file
flip() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, needle, repl = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
data = open(path, "rb").read()
assert needle in data, "needle %r not in %s" % (needle, path)
open(path, "wb").write(data.replace(needle, repl, 1))
PY
}

# ══════════════════════════════════════════════════════════════════════════════
# [V] VERIFY — hmd receipt verify / keygen
# ══════════════════════════════════════════════════════════════════════════════
if section V; then
echo "[V] hmd receipt verify / keygen"
VH="$TMP/v-home"; mkdir -p "$VH"; touch "$VH/setup-done"
VK="$TMP/v-keys"; VS="$TMP/v-store"; VO="$TMP/v-out"; mkdir -p "$VO"
D_ID=d1d1d1d1d1d1; P_ID=b2b2b2b2b2b2; V_ID=a1b2c3d4e5f6

echo "  -- keygen: the documented key source --"
rcpt keygen --dir "$VK"
if [ "$RRC" -eq 0 ] && [ "$(modeof "$VK/runhmd-receipt.key")" = "600" ] && [ "$(modeof "$VK/runhmd-receipt.pub")" = "644" ] && [ "$(modeof "$VK")" = "700" ]; then
  ok "keygen --dir DIR writes the secret key (0600) and the public key (0644) into a 0700 directory"
else bad "keygen --dir DIR (rc=$RRC: $(head -3 "$RERR" | tr '\n' '|'))"; fi
SEED="$(tr -d '\n' <"$VK/runhmd-receipt.key")"
KID="$(grep -Eo '[0-9a-f]{16}' "$ROUT" | head -1)"
if [ -n "$SEED" ] && ! grep -qF -- "$SEED" "$ROUT" "$RERR" && [ -n "$KID" ] && grep -qF "$VK/runhmd-receipt.pub" "$ROUT"; then
  ok "keygen prints the key id and where the public key is, and never prints the seed"
else bad "keygen output wrong (kid='$KID')"; fi
before="$(shasum "$VK/runhmd-receipt.key" | awk '{print $1}')"
rcpt keygen --dir "$VK"
[ "$RRC" -eq 2 ] && grep -q 'key_exists' "$RERR" && [ "$before" = "$(shasum "$VK/runhmd-receipt.key" | awk '{print $1}')" ] \
  && ok "keygen refuses to overwrite an existing key (exit 2) and leaves it byte-identical" || bad "keygen overwrote or mis-reported (rc=$RRC)"
HEIMDALL_HOME="$VH" rcpt keygen
[ "$RRC" -eq 0 ] && [ -f "$VH/signing/runhmd-receipt.key" ] && [ -f "$VH/signing/runhmd-receipt.pub" ] \
  && ok "keygen with no --dir writes into \$HEIMDALL_HOME/signing (the default key source)" || bad "default keygen location wrong (rc=$RRC)"
rcpt keygen --dir "$TMP/v-keys-other"
OTHER_PUB="$TMP/v-keys-other/runhmd-receipt.pub"

echo "  -- issuing fixtures with the library (the CLI under test only verifies) --"
cat >"$TMP/make-receipts.py" <<'PY'
import json, sys
PYLIB, KEYFILE, STORE, OUT = sys.argv[1:5]
sys.path.insert(0, PYLIB)
import runhmd_receipt as rr
signer = rr.load_signer(KEYFILE)
HEX = lambda c: c * 64
common = dict(signer=signer, subject={"kind": "path", "head_sha": None, "tree_sha256": HEX("c")}, agent={"name": "none", "model": None},
              cost_usd=0, duration_s=1.25, created_at="2026-10-05T12:00:00Z")
finding = {"id": "f-0001", "title": "duplicate settlement (webhook+retry within 50ms)", "severity": "high", "category": "concurrency",
           "counterexample": {"summary": "event evt_1 credited twice", "repro_cmd": "hmd attack x --json --yes", "minimal_input": "{\"deliveries\":[{\"at_ms\":0},{\"at_ms\":10}]}"},
           "evidence_ref": None}
VERDICT = {"schema": "runhmd.verdict/1", "id": "a1b2c3d4e5f6", "verdict": "DENIED", "target": {"kind": "path", "ref": "x", "head_sha": None},
           "attacks": {"total": 23, "survived": 17, "killed": 6}, "findings": [finding], "cost_usd": 0.0, "duration_s": 12.35,
           "agent": {"name": "none", "model": None}, "receipt_url": None}
json.dump(VERDICT, open(OUT + "/verdict.json", "w"), indent=2)
receipts = {
    "d1d1d1d1d1d1": rr.issue_receipt(id="d1d1d1d1d1d1", verdict="DENIED", attacks={"total": 24, "survived": 21, "killed": 3}, verdict_sha256=HEX("d"),
        findings=[{k: finding[k] for k in ("id", "title", "severity", "category")} | {"digest": rr.finding_digest(finding)}], **common),
    "b2b2b2b2b2b2": rr.issue_receipt(id="b2b2b2b2b2b2", verdict="PROVEN", attacks={"total": 24, "survived": 24, "killed": 0}, findings=[], verdict_sha256=HEX("d"), **common),
    "a1b2c3d4e5f6": rr.receipt_for_verdict(VERDICT, tree_sha256=HEX("e"), signer=signer, created_at="2026-10-05T12:00:00Z"),
}
for rid, raw in receipts.items():
    rr.write_receipt(STORE, rid, raw)
PY
python3 "$TMP/make-receipts.py" "$PYLIB" "$VK/runhmd-receipt.key" "$VS" "$VO" 2>"$TMP/make.err" && ok "fixtures: DENIED, PROVEN and verdict-attesting receipts signed with the generated key" || bad "fixture setup failed: $(tail -3 "$TMP/make.err" | tr '\n' '|')"
cp "$VS/$D_ID.json" "$VO/denied.receipt.json"

echo "  -- verify: a genuine receipt --"
rcpt verify "$VO/denied.receipt.json" --pubkey "$VK/runhmd-receipt.pub"
[ "$RRC" -eq 0 ] && grep -q "^ok $D_ID DENIED" "$ROUT" && grep -q "$KID" "$ROUT" \
  && ok "verify FILE --pubkey PUB: exit 0, 'ok <id> <verdict>' naming the signing key" || bad "verify FILE (rc=$RRC: $(cat "$ROUT" "$RERR" | head -3 | tr '\n' '|'))"
rcpt verify "$VO/denied.receipt.json" --pubkey "$VK/runhmd-receipt.pub" --json
jq -e --arg id "$D_ID" --arg kid "$KID" '.ok==true and .id==$id and .verdict=="DENIED" and .key_id==$kid and .visibility=="private" and .created_at=="2026-10-05T12:00:00Z"' "$ROUT" >/dev/null 2>&1 \
  && ok "verify --json: the canonical output, one JSON object on stdout" || bad "verify --json shape wrong: $(head -c 200 "$ROUT")"
rcpt verify "$D_ID" --pubkey "$VK/runhmd-receipt.pub" --store "$VS"
[ "$RRC" -eq 0 ] && ok "verify <id> --store DIR: finds the receipt by id" || bad "verify by id with --store (rc=$RRC)"
( cd "$REPO" && RUNHMD_RECEIPT_DIR="$VS" RUNHMD_RECEIPT_PUBKEY_FILE="$VK/runhmd-receipt.pub" "$HMD" receipt verify "$P_ID" </dev/null >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "verify <id>: RUNHMD_RECEIPT_DIR selects the store and RUNHMD_RECEIPT_PUBKEY_FILE the trust anchor" || bad "verify by id via env (rc=$rc)"
mkdir -p "$VH/runhmd/receipts"
python3 "$TMP/make-receipts.py" "$PYLIB" "$VH/signing/runhmd-receipt.key" "$VH/runhmd/receipts" "$TMP/v-out-home" 2>/dev/null || mkdir -p "$TMP/v-out-home"
python3 "$TMP/make-receipts.py" "$PYLIB" "$VH/signing/runhmd-receipt.key" "$VH/runhmd/receipts" "$TMP/v-out-home" 2>"$TMP/make.err"
HEIMDALL_HOME="$VH" rcpt verify "$P_ID"
[ "$RRC" -eq 0 ] && ok "the default flow needs no flags: keygen, issue, then 'hmd receipt verify <id>' (default store, default trust = the local public key)" || bad "default flow (rc=$RRC: $(cat "$RERR" | head -2 | tr '\n' '|'))"

echo "  -- verify: tampering is caught (exit 1, with the reason) --"
cp "$VS/$D_ID.json" "$TMP/tamper-store-copy.json"
before="$(shasum "$VS/$D_ID.json" | awk '{print $1}')"
flip "$VS/$D_ID.json" 'duplicate settlement' 'duplicate settlemenT'
rcpt verify "$D_ID" --pubkey "$VK/runhmd-receipt.pub" --store "$VS"
[ "$RRC" -eq 1 ] && grep -q 'bad_signature' "$RERR" && [ "$before" != "$(shasum "$VS/$D_ID.json" | awk '{print $1}')" ] \
  && ok "RP3 acceptance: edit one byte of a STORED receipt and 'hmd receipt verify <id>' exits non-zero (1, bad_signature)" || bad "stored-receipt tamper not caught (rc=$RRC: $(head -2 "$RERR" | tr '\n' '|'))"
cp "$TMP/tamper-store-copy.json" "$VS/$D_ID.json"
rcpt verify "$D_ID" --pubkey "$VK/runhmd-receipt.pub" --store "$VS"; [ "$RRC" -eq 0 ] && ok "control: restoring the byte makes it verify again" || bad "control restore failed (rc=$RRC)"
rcpt verify "$VO/denied.receipt.json" --pubkey "$VK/runhmd-receipt.pub" --json >/dev/null
cp "$VO/denied.receipt.json" "$TMP/t-private-public.json"; flip "$TMP/t-private-public.json" '"visibility":"private"' '"visibility":"public"'
rcpt verify "$TMP/t-private-public.json" --pubkey "$VK/runhmd-receipt.pub"
[ "$RRC" -eq 1 ] && grep -q 'bad_signature' "$RERR" && ok "turning a private receipt public (a schema-valid edit) breaks the signature" || bad "private->public edit not caught (rc=$RRC)"
cp "$VO/denied.receipt.json" "$TMP/t-verdict.json"; flip "$TMP/t-verdict.json" '"verdict":"DENIED"' '"verdict":"PROVEN"'
rcpt verify "$TMP/t-verdict.json" --pubkey "$VK/runhmd-receipt.pub"
[ "$RRC" -eq 1 ] && ok "rewriting DENIED as PROVEN is refused (exit 1)" || bad "DENIED->PROVEN edit not caught (rc=$RRC)"
head -c 200 "$VO/denied.receipt.json" >"$TMP/t-trunc.json"
rcpt verify "$TMP/t-trunc.json" --pubkey "$VK/runhmd-receipt.pub"; [ "$RRC" -eq 1 ] && grep -q 'not_json' "$RERR" && ok "a truncated receipt is refused (exit 1, not_json)" || bad "truncated receipt (rc=$RRC)"
: >"$TMP/t-empty.json"
rcpt verify "$TMP/t-empty.json" --pubkey "$VK/runhmd-receipt.pub"; [ "$RRC" -eq 1 ] && ok "an empty file is refused (exit 1)" || bad "empty file (rc=$RRC)"
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2, sort_keys=True, ensure_ascii=False))' "$VO/denied.receipt.json" >"$TMP/t-pretty.json"
rcpt verify "$TMP/t-pretty.json" --pubkey "$VK/runhmd-receipt.pub"
[ "$RRC" -eq 1 ] && grep -q 'not_canonical' "$RERR" && ok "a pretty-printed copy is refused (exit 1, not_canonical): only the signed bytes are the receipt" || bad "pretty-printed copy (rc=$RRC)"
rcpt verify "$VO/denied.receipt.json" --pubkey "$OTHER_PUB"
[ "$RRC" -eq 1 ] && grep -q 'unknown_key' "$RERR" && ok "a receipt signed by a key outside the pinned set is refused (exit 1, unknown_key)" || bad "unknown key (rc=$RRC)"
rcpt verify "$VO/denied.receipt.json" --pubkey "$OTHER_PUB" --json
jq -e '.ok==false and .error=="unknown_key" and (.detail|type=="string")' "$ROUT" >/dev/null 2>&1 && ok "verify --json on failure: {ok:false,error,detail} on stdout, exit 1" || bad "verify --json failure shape: $(head -c 200 "$ROUT")"
cp "$VS/$P_ID.json" "$VS/$D_ID.swapped.json"; cp "$VS/$P_ID.json" "$TMP/swap.json"
mkdir -p "$TMP/v-swap"; cp "$VS/$P_ID.json" "$TMP/v-swap/$D_ID.json"
rcpt verify "$D_ID" --pubkey "$VK/runhmd-receipt.pub" --store "$TMP/v-swap"
[ "$RRC" -eq 1 ] && grep -q 'id_mismatch' "$RERR" && ok "a genuine receipt filed under another receipt's id is refused (exit 1, id_mismatch)" || bad "id swap (rc=$RRC)"
rm -f "$VS/$D_ID.swapped.json"

echo "  -- verify: configuration problems are exit 2, never a pass and never 'invalid' --"
HEIMDALL_HOME="$TMP/v-empty-home" rcpt verify "$VO/denied.receipt.json"
[ "$RRC" -eq 2 ] && grep -q 'no_trust' "$RERR" && ok "no trust anchor anywhere: exit 2 (no_trust), naming --pubkey, not a silent pass" || bad "no trust anchor (rc=$RRC: $(head -2 "$RERR" | tr '\n' '|'))"
rcpt verify "$TMP/nope.json" --pubkey "$VK/runhmd-receipt.pub"; [ "$RRC" -eq 2 ] && grep -q 'not_found' "$RERR" && ok "a missing file is exit 2 (not_found)" || bad "missing file (rc=$RRC)"
rcpt verify zzzzzzzzzzzz --pubkey "$VK/runhmd-receipt.pub" --store "$VS"; [ "$RRC" -eq 2 ] && grep -q 'not_found' "$RERR" && ok "an unknown id is exit 2 (not_found)" || bad "unknown id (rc=$RRC)"
mkdir -p "$TMP/decoy"; cp "$VS/$P_ID.json" "$TMP/decoy/$P_ID.json"
for hostile in "../decoy/$P_ID" "a/b" ".." "$TMP/decoy/$P_ID"; do
  rcpt verify "$hostile" --pubkey "$VK/runhmd-receipt.pub" --store "$VS/inner-never-created"
  [ "$RRC" -eq 2 ] && ok "an id like '$hostile' is never resolved against the filesystem: exit 2" || bad "hostile id '$hostile' (rc=$RRC)"
done
rcpt verify "$VO/denied.receipt.json" --pubkey "$TMP/absent.pub"; [ "$RRC" -eq 2 ] && grep -q 'bad_trust' "$RERR" && ok "an unreadable --pubkey file is exit 2 (bad_trust)" || bad "absent pubkey file (rc=$RRC)"
printf 'AAAA\n' >"$TMP/short.pub"
rcpt verify "$VO/denied.receipt.json" --pubkey "$TMP/short.pub"; [ "$RRC" -eq 2 ] && grep -q 'bad_trust' "$RERR" && ok "a malformed --pubkey file is exit 2, not skipped" || bad "malformed pubkey (rc=$RRC)"
rcpt verify; [ "$RRC" -eq 2 ] && ok "verify with no target is a usage error (exit 2)" || bad "verify with no target (rc=$RRC)"
rcpt verify a b; [ "$RRC" -eq 2 ] && ok "verify with two targets is a usage error (exit 2)" || bad "verify with two targets (rc=$RRC)"
rcpt verify --bogus x; [ "$RRC" -eq 2 ] && ok "an unknown flag is exit 2" || bad "unknown flag (rc=$RRC)"
rcpt verify "$VO/denied.receipt.json" --pubkey; [ "$RRC" -eq 2 ] && ok "a flag missing its value is exit 2" || bad "missing flag value (rc=$RRC)"

echo "  -- the command itself --"
snap() { (cd "$1" && find . -type f -exec shasum {} + | sort); }
s1="$(snap "$VS")"; h1="$(snap "$VK")"
rcpt verify "$P_ID" --pubkey "$VK/runhmd-receipt.pub" --store "$VS" --json >/dev/null
[ "$s1" = "$(snap "$VS")" ] && [ "$h1" = "$(snap "$VK")" ] && ok "verify writes nothing (store and key directory byte-identical afterwards)" || bad "verify modified files"
rcpt
[ "$RRC" -eq 2 ] && grep -q 'verify' "$RERR" && grep -q 'keygen' "$RERR" && [ ! -s "$ROUT" ] && ok "hmd receipt with no subcommand prints the usage on stderr and exits 2" || bad "no-subcommand usage (rc=$RRC)"
rcpt bogus; [ "$RRC" -eq 2 ] && grep -q 'bogus' "$RERR" && ok "an unknown subcommand is exit 2 and named" || bad "unknown subcommand (rc=$RRC)"
rcpt --help
if [ "$RRC" -eq 0 ] && for w in verify keygen render serve --pubkey --store --json RUNHMD_RECEIPT_KEY_FILE RUNHMD_RECEIPT_PUBKEY_FILE RUNHMD_RECEIPT_DIR; do grep -q -- "$w" "$ROUT" || { echo "missing $w" >&2; exit 1; }; done 2>"$TMP/help.miss" && grep -Eq '^ +1 ' "$ROUT" && grep -Eq '^ +2 ' "$ROUT"; then
  ok "--help documents every subcommand, flag, the key/trust/store environment variables and the exit codes"
else bad "--help incomplete (rc=$RRC: $(cat "$TMP/help.miss" 2>/dev/null | tr '\n' ' '))"; fi
[ ! -s "$HEIMDALL_TRACE_ORDER" ] && ok "hmd receipt never fell through to the Claude task-prompt path during this section" || bad "hmd receipt fell through to the task-prompt path: $(head -c 200 "$HEIMDALL_TRACE_ORDER")"
! grep -En 'shell[[:space:]]*=[[:space:]]*True|os\.system' "$PYLIB/runhmd_receipt.py" "$PYLIB/runhmd_receipt_cli.py" "$RECEIPT_BIN" >/dev/null 2>&1 \
  && ok "the receipt code never shells out through a shell string" || bad "the receipt code uses shell=True / os.system"
! grep -En '^[[:space:]]*(import|from)[[:space:]]+(socket|urllib|ssl|ftplib|smtplib|requests)' "$PYLIB/runhmd_receipt.py" "$PYLIB/runhmd_receipt_cli.py" "$RECEIPT_BIN" >/dev/null 2>&1 \
  && ok "issue/verify code imports no network module (only the local server module does, and only to listen on loopback)" || bad "the receipt core imports a network module"
fi

# ══════════════════════════════════════════════════════════════════════════════
# [H] HOSTING — /r/<id> (escaped HTML) and /r/<id>.json (the exact signed bytes)
# ══════════════════════════════════════════════════════════════════════════════
if section H; then
echo "[H] /r/<id> and /r/<id>.json: hmd receipt serve (local) and hmd receipt render (static)"

HK="$TMP/h-keys"; HS="$TMP/h-store"; HPUB="$HK/runhmd-receipt.pub"
PUB_ID=a0a0a0a0a0a0; PRIV_ID=b0b0b0b0b0b0; HOSTILE_ID=c0c0c0c0c0c0; FLIP_ID=d0d0d0d0d0d0; SWAP_ID=e0e0e0e0e0e0
rcpt keygen --dir "$HK"
cat >"$TMP/make-hosting.py" <<'PY'
import json, sys
PYLIB, KEYFILE, STORE, OUT = sys.argv[1:5]
sys.path.insert(0, PYLIB)
import runhmd_receipt as rr
signer = rr.load_signer(KEYFILE)
HEX = lambda c: c * 64
common = dict(signer=signer, subject={"kind": "path", "head_sha": None, "tree_sha256": HEX("c")}, cost_usd=0.41, duration_s=1.25,
              verdict_sha256=HEX("d"), created_at="2026-10-05T12:00:00Z")
digest = "sha256:" + HEX("a")
HOSTILE_TITLES = [
    "<script>alert(1)</script>",
    "\"><img src=x onerror=alert(2)>",
    "' onmouseover='alert(3)",
    "&lt;b&gt;already escaped&lt;/b&gt; & <b>bold</b>",
    "</title><script>alert(4)</script>",
    "javascript:alert(5)",
    "<svg/onload=alert(6)>",
    "café ✓ 日本語 \U0001F6E1 </td></tr></table><h1>injected</h1>",
]
hostile_findings = [{"id": "f-%04d" % (i + 1), "title": t, "severity": "high", "category": "logic", "digest": digest} for i, t in enumerate(HOSTILE_TITLES)]
HOSTILE_META = {"model": "\"><script>alert(7)</script>", "version": "<b>9.9</b>&amp;", "gate_id": "<img src=x onerror=alert(8)>", "gate_type": "\" onmouseover=\"alert(9)"}
receipts = {
    "a0a0a0a0a0a0": rr.issue_receipt(id="a0a0a0a0a0a0", verdict="PROVEN", attacks={"total": 24, "survived": 24, "killed": 0}, findings=[], visibility="public",
        agent={"name": "none", "model": None}, gates=[{"id": "settlement", "gate_type": "differential", "status": "pass", "falsified": True, "falsify_score": 1}], **common),
    "b0b0b0b0b0b0": rr.issue_receipt(id="b0b0b0b0b0b0", verdict="DENIED", attacks={"total": 24, "survived": 21, "killed": 3}, visibility="private",
        agent={"name": "none", "model": None}, findings=[{"id": "f-0001", "title": "a private finding title", "severity": "high", "category": "auth", "digest": digest}], **common),
    "c0c0c0c0c0c0": rr.issue_receipt(id="c0c0c0c0c0c0", verdict="DENIED", attacks={"total": 24, "survived": 16, "killed": 8}, visibility="public",
        agent={"name": "none", "model": HOSTILE_META["model"]}, findings=hostile_findings, tool={"name": "hmd", "version": HOSTILE_META["version"]},
        gates=[{"id": HOSTILE_META["gate_id"], "gate_type": HOSTILE_META["gate_type"], "status": "fail", "falsified": True, "falsify_score": 1}], **common),
}
for rid, raw in receipts.items():
    rr.write_receipt(STORE, rid, raw)
good = receipts["a0a0a0a0a0a0"]
rr.write_receipt(STORE, "d0d0d0d0d0d0", good[:300] + bytes([good[300] ^ 1]) + good[301:])          # one byte altered
rr.write_receipt(STORE, "e0e0e0e0e0e0", good)                                                    # a genuine receipt under another id
json.dump({"hostile_titles": HOSTILE_TITLES, "meta": HOSTILE_META}, open(OUT, "w"))
PY
python3 "$TMP/make-hosting.py" "$PYLIB" "$HK/runhmd-receipt.key" "$HS" "$TMP/hostile.json" 2>"$TMP/make-h.err" \
  && ok "fixtures: a public PROVEN, a private DENIED and a public DENIED receipt full of hostile text, plus a byte-flipped copy and a mis-filed copy" || bad "hosting fixtures failed: $(tail -3 "$TMP/make-h.err" | tr '\n' '|')"
head_of() { tr -d '\r' <"$HHEAD" | grep -i "^$1:" | head -1 | cut -d' ' -f2-; }
http_do() {  # http_do <curl-args...> <path>: sets HCODE HBODY HHEAD against $BASE
  local path="${*: -1}"; set -- "${@:1:$#-1}"
  HBODY="$TMP/http.body"; HHEAD="$TMP/http.head"; : >"$HBODY"; : >"$HHEAD"
  HCODE="$(curl -sS --noproxy '*' --max-time 15 --path-as-is -D "$HHEAD" -o "$HBODY" -w '%{http_code}' "$@" "$BASE$path" 2>"$TMP/http.err")" || HCODE="curl-failed:$(head -c 100 "$TMP/http.err")"
}

echo "  -- the local server (loopback only) --"
rcpt serve --store "$HS" --port 0 --pubkey "$HK/absent.pub"
[ "$RRC" -eq 2 ] && grep -q 'bad_trust' "$RERR" && ok "serve refuses to start with an unreadable trust file (exit 2): it will not serve what it cannot verify" || bad "serve with a bad trust file (rc=$RRC)"
HEIMDALL_HOME="$TMP/h-empty-home" rcpt serve --store "$HS" --port 0
[ "$RRC" -eq 2 ] && grep -q 'no_trust' "$RERR" && ok "serve refuses to start with no trust anchor at all (exit 2, no_trust)" || bad "serve without trust (rc=$RRC)"
rcpt serve --store "$HS" --port abc --pubkey "$HPUB"; [ "$RRC" -eq 2 ] && ok "serve --port abc is exit 2" || bad "serve --port abc (rc=$RRC)"
rcpt serve --store "$HS" --port 70000 --pubkey "$HPUB"; [ "$RRC" -eq 2 ] && ok "serve --port 70000 is exit 2" || bad "serve --port 70000 (rc=$RRC)"
rcpt serve --store "$HS" --host 0.0.0.0 --pubkey "$HPUB"; [ "$RRC" -eq 2 ] && ok "there is no --host: the server only ever binds 127.0.0.1 (exit 2 on the flag)" || bad "serve --host (rc=$RRC)"
"$HMD" receipt serve --store "$HS" --pubkey "$HPUB" --port 0 </dev/null >"$TMP/serve.out" 2>"$TMP/serve.err" &
SERVER_PID=$!
for _ in $(seq 1 150); do grep -q 'http://127.0.0.1:' "$TMP/serve.out" 2>/dev/null && break; sleep 0.1; done
BASE="$(grep -Eo 'http://127\.0\.0\.1:[0-9]+' "$TMP/serve.out" | head -1)"
[ -n "$BASE" ] && ok "serve --port 0 listens on an ephemeral loopback port and prints its URL ($BASE)" || { bad "the server did not report a listening URL: $(head -c 300 "$TMP/serve.err")"; BASE="http://127.0.0.1:9"; }
store_before="$(cd "$HS" && find . -type f -exec shasum {} + | sort)"

echo "  -- /r/<id>.json serves the exact signed bytes --"
http_do "/r/$PUB_ID.json"
if [ "$HCODE" = "200" ] && cmp -s "$HBODY" "$HS/$PUB_ID.json"; then ok "GET /r/<id>.json: 200 and the body is byte-identical to the stored, signed receipt"; else bad "GET /r/<id>.json (code=$HCODE, bytes differ or missing)"; fi
head_of content-type | grep -qi '^application/json' && ok "GET /r/<id>.json is served as application/json" || bad "content-type of .json is '$(head_of content-type)'"
head_of x-content-type-options | grep -qi nosniff && ok "responses carry X-Content-Type-Options: nosniff" || bad "no nosniff header"
cp "$HBODY" "$TMP/served.json"
rcpt verify "$TMP/served.json" --pubkey "$HPUB"
[ "$RRC" -eq 0 ] && ok "the downloaded /r/<id>.json verifies with 'hmd receipt verify' (what was served is what was signed)" || bad "the served bytes do not verify (rc=$RRC: $(head -c 200 "$RERR"))"
curl -fsS --noproxy '*' "$BASE/r/$PUB_ID.json" 2>/dev/null | jq -e '.schema=="runhmd.receipt/1" and .cost_usd!=null' >/dev/null \
  && ok "RP3 acceptance verbatim: curl -fsS \$BASE/r/<id>.json | jq -e '.schema==\"runhmd.receipt/1\" and .cost_usd!=null'" || bad "RP3 acceptance line for /r/<id>.json"
curl -fsS --noproxy '*' "$BASE/r/$PUB_ID.json" 2>/dev/null | grep -q minimal_input \
  && bad "the served receipt contains minimal_input" || ok "RP3 acceptance: ! curl \$BASE/r/<id>.json | grep -q minimal_input (a receipt holds digests only)"
http_do -I "/r/$PUB_ID.json"
[ "$HCODE" = "200" ] && [ "$(head_of content-length)" = "$(wc -c <"$HS/$PUB_ID.json" | tr -d ' ')" ] && ok "HEAD /r/<id>.json: 200 with the exact Content-Length and no body" || bad "HEAD (code=$HCODE length=$(head_of content-length))"

echo "  -- /r/<id> is HTML, with every dynamic value escaped --"
http_do "/r/$PUB_ID"
[ "$HCODE" = "200" ] && head_of content-type | grep -qi '^text/html; charset=utf-8' && grep -q "PROVEN" "$HBODY" && grep -q "$PUB_ID" "$HBODY" && ok "GET /r/<id>: 200 text/html with the verdict and the id" || bad "GET /r/<id> (code=$HCODE type=$(head_of content-type))"
grep -q "href=\"$PUB_ID.json\"" "$HBODY" && ok "the page links to its own signed JSON by a relative href" || bad "no link to $PUB_ID.json"
grep -q "hmd receipt verify" "$HBODY" && ok "the page tells the reader how to verify it themselves" || bad "no verify instructions on the page"
CSP="$(head_of content-security-policy)"
case "$CSP" in *"default-src 'none'"*"base-uri 'none'"*"form-action 'none'"*"frame-ancestors 'none'"*) ok "the Content-Security-Policy header is default-src 'none' (+ base-uri, form-action, frame-ancestors)" ;; *) bad "CSP header is '$CSP'" ;; esac
head_of referrer-policy | grep -qi 'no-referrer' && ok "Referrer-Policy: no-referrer" || bad "no referrer policy"
cp "$HBODY" "$TMP/public-page.html"
http_do "/r/$HOSTILE_ID"
cp "$HBODY" "$TMP/hostile-page.html"; HHOSTILE_CODE="$HCODE"
cat >"$TMP/html-check.py" <<'PY'
import hashlib, base64, json, re, sys
from html.parser import HTMLParser
page = open(sys.argv[1], "rb").read().decode("utf-8")
hostile = json.load(open(sys.argv[2]))
ALLOWED = {"html", "head", "meta", "title", "style", "body", "main", "header", "section", "h1", "h2", "p", "dl", "dt", "dd", "table", "thead",
           "tbody", "tr", "th", "td", "code", "pre", "a", "span", "ul", "li", "strong", "em"}
class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags, self.attrs, self.text, self.style, self.in_style, self.title = [], [], [], [], False, []
        self.in_title = False
    def handle_starttag(self, tag, attrs):
        self.tags.append(tag); self.attrs += [(tag, k, v) for k, v in attrs]
        self.in_style = self.in_style or tag == "style"; self.in_title = tag == "title" or self.in_title
    def handle_endtag(self, tag):
        self.in_style = False if tag == "style" else self.in_style; self.in_title = False if tag == "title" else self.in_title
    def handle_data(self, data):
        (self.style if self.in_style else self.text).append(data)
        if self.in_title: self.title.append(data)
p = P(); p.feed(page); p.close()
out = []
def case(desc, cond, detail=""):
    out.append(("PASS " if cond else "FAIL ") + desc + ("" if cond or not detail else ": " + str(detail)))
extra = sorted(set(p.tags) - ALLOWED)
case("the page uses only plain structural elements (no script, img, svg, iframe, form, link, base, object)", not extra, extra)
on = [(t, k) for t, k, v in p.attrs if k.lower().startswith("on")]
case("no element carries an event-handler attribute", not on, on)
bad_urls = [(t, k, v) for t, k, v in p.attrs if k in ("href", "src", "action", "data", "formaction") and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{2,63}\.json", v or "")]
case("the only link target is the receipt's own <id>.json (no javascript:, no absolute URL)", not bad_urls, bad_urls)
text = "".join(p.text)
missing = [t for t in hostile["hostile_titles"] if t not in text]
case("every hostile finding title is DISPLAYED, as text, exactly as issued (escaped, not dropped, not interpreted)", not missing, missing[:2])
for label, value in (("agent.model", hostile["meta"]["model"]), ("tool.version", hostile["meta"]["version"]), ("gate id", hostile["meta"]["gate_id"]), ("gate type", hostile["meta"]["gate_type"])):
    case("hostile %s is displayed verbatim as text" % label, value in text, value)
case("the document title is the receipt id and verdict, free of finding text", "".join(p.title).strip() == "runhmd receipt c0c0c0c0c0c0 · DENIED", "".join(p.title))
raw_bad = [s for s in ("<script", "<img", "<svg", "<iframe", "</td></tr></table><h1>injected", "<b>bold</b>") if s in page]
case("raw markup from the hostile text never appears in the page source", not raw_bad, raw_bad)
case("an already-escaped title is escaped again (&lt;b&gt; is displayed as the characters &lt;b&gt;, not as <b>)", "&amp;lt;b&amp;gt;already escaped" in page)
meta_csp = re.search(r"<meta http-equiv=\"Content-Security-Policy\" content=\"([^\"]*)\"", page)
case("the page carries its own CSP in a <meta>, so it is safe on any static host", bool(meta_csp) and "default-src 'none'" in meta_csp.group(1), meta_csp and meta_csp.group(1))
style_hash = "sha256-" + base64.b64encode(hashlib.sha256("".join(p.style).encode("utf-8")).digest()).decode()
case("the inline <style> is allowed by hash ('%s'), not by 'unsafe-inline'" % style_hash[:18], bool(meta_csp) and style_hash in meta_csp.group(1) and "unsafe-inline" not in meta_csp.group(1))
print("\n".join(out))
PY
python3 "$TMP/html-check.py" "$TMP/hostile-page.html" "$TMP/hostile.json" >"$TMP/html-check.out" 2>"$TMP/html-check.err"
[ "$HHOSTILE_CODE" = "200" ] && ok "GET /r/<id> of a receipt whose every text field is hostile still serves 200 (it is valid, just hostile)" || bad "hostile receipt page (code=$HHOSTILE_CODE)"
while IFS= read -r line; do case "$line" in "PASS "*) ok "${line#PASS }" ;; "FAIL "*) bad "${line#FAIL }" ;; esac; done <"$TMP/html-check.out"
[ -s "$TMP/html-check.out" ] || bad "the HTML checker produced no output: $(tail -3 "$TMP/html-check.err" | tr '\n' '|')"
grep -q 'private' "$TMP/public-page.html" && bad "a public receipt page mentions 'private'" || ok "a public receipt's page does not claim to be private"
http_do "/r/$PRIV_ID"
[ "$HCODE" = "200" ] && grep -qi 'private' "$HBODY" && head_of x-robots-tag | grep -qi noindex && ok "the local server also serves a PRIVATE receipt (it is the owner's loopback), marked private and X-Robots-Tag: noindex" || bad "private receipt (code=$HCODE robots=$(head_of x-robots-tag))"

echo "  -- nothing but verified receipts at /r/<id>[.json] --"
for bad_route in "/" "/r" "/r/" "/r/zzzzzzzzzzzz" "/r/zzzzzzzzzzzz.json" "/r/$PUB_ID/" "/r/$PUB_ID.json/" "/r/$PUB_ID/card.png" "/r/$PUB_ID.html" "/api/receipts" "/r/$PUB_ID.JSON" "/r/ab" "/R/$PUB_ID"; do
  http_do "$bad_route"
  if [ "$HCODE" = "404" ] && ! grep -q "PROVEN" "$HBODY"; then ok "GET $bad_route is 404"; else bad "GET $bad_route -> $HCODE"; fi
done
mkdir -p "$TMP/h-outside"; cp "$HS/$PUB_ID.json" "$TMP/h-outside/loot.json"; cp "$HS/$PUB_ID.json" "$TMP/h-secret.json"
for evil in "/r/../h-secret" "/r/../h-secret.json" "/r/..%2fh-secret.json" "/r/%2e%2e%2fh-secret.json" "/r/%252e%252e%252fh-secret.json" "/r/$PUB_ID.json%00.png" "/r/$PUB_ID%0a" "/r/$PUB_ID.json%0a" "/r/%2e%2e/%2e%2e/etc/passwd" "/r/..\\h-secret.json" "//r/$PUB_ID.json"; do
  http_do "$evil"
  if [ "$HCODE" = "404" ] || [ "$HCODE" = "400" ]; then ok "traversal/odd path $evil is refused ($HCODE)"; else bad "path $evil -> $HCODE"; fi
done
http_do -X POST --data 'x=1' "/r/$PUB_ID"
[ "$HCODE" = "405" ] && head_of allow | grep -qi 'GET' && ok "POST /r/<id> is 405 with an Allow header" || bad "POST -> $HCODE"
http_do -X PUT --data 'x=1' "/r/$PUB_ID.json"; [ "$HCODE" = "405" ] && ok "PUT is 405" || bad "PUT -> $HCODE"
http_do -X DELETE "/r/$PUB_ID.json"; [ "$HCODE" = "405" ] && ok "DELETE is 405" || bad "DELETE -> $HCODE"
http_do "/r/$(printf 'a%.0s' $(seq 1 6000))"; [ "$HCODE" = "404" ] || [ "$HCODE" = "414" ] || [ "$HCODE" = "400" ] && ok "a 6 KB path is refused ($HCODE), no crash" || bad "huge path -> $HCODE"
for tampered in "$FLIP_ID" "$SWAP_ID"; do
  for suffix in "" ".json"; do
    http_do "/r/$tampered$suffix"
    if [ "$HCODE" = "500" ] && ! grep -qiE "PROVEN|verdict|settlement|signature" "$HBODY"; then ok "a stored receipt that fails verification ($tampered) is 500 on /r/<id>$suffix and its content is not served"
    else bad "tampered receipt $tampered$suffix -> $HCODE body='$(head -c 80 "$HBODY")'"; fi
  done
done
http_do "/r/$PUB_ID.json"; [ "$HCODE" = "200" ] && ok "the server is still serving after every hostile request" || bad "the server stopped serving ($HCODE)"
[ "$store_before" = "$(cd "$HS" && find . -type f -exec shasum {} + | sort)" ] && ok "the server only reads: the store is byte-identical after every request" || bad "the server modified the store"
kill "$SERVER_PID" >/dev/null 2>&1; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""

echo "  -- hmd receipt render: the same pages as a static tree for runhmd.dev --"
HS2="$TMP/h-store-clean"; mkdir -p "$HS2"
for id in "$PUB_ID" "$PRIV_ID" "$HOSTILE_ID"; do cp "$HS/$id.json" "$HS2/$id.json"; done
HO="$TMP/h-site"
rcpt render --store "$HS2" --pubkey "$HPUB" --out "$HO" --json
if [ "$RRC" -eq 0 ] && jq -e --arg a "$PUB_ID" --arg c "$HOSTILE_ID" --arg b "$PRIV_ID" '.ok==true and (.rendered|sort)==([$a,$c]|sort) and .skipped_private==[$b] and .failed==[]' "$ROUT" >/dev/null 2>&1; then
  ok "render --json: the two PUBLIC receipts are rendered, the private one is skipped by name, nothing failed"
else bad "render summary wrong (rc=$RRC: $(head -c 300 "$ROUT") $(head -c 200 "$RERR"))"; fi
if [ -f "$HO/r/$PUB_ID.json" ] && cmp -s "$HO/r/$PUB_ID.json" "$HS2/$PUB_ID.json" && [ -f "$HO/r/$PUB_ID.html" ]; then ok "render writes r/<id>.json (byte-identical to the signed receipt) and r/<id>.html"; else bad "render output missing or not byte-identical"; fi
[ ! -e "$HO/r/$PRIV_ID.json" ] && [ ! -e "$HO/r/$PRIV_ID.html" ] && ! grep -rqs "a private finding title" "$HO" && ok "a private receipt is never written into the publishable tree" || bad "private receipt leaked into the static site"
cmp -s "$HO/r/$PUB_ID.html" "$TMP/public-page.html" && cmp -s "$HO/r/$HOSTILE_ID.html" "$TMP/hostile-page.html" && ok "the static HTML is byte-identical to what the server returned (one code path renders both)" || bad "static HTML differs from the served HTML"
[ "$(find "$HO" -type f | wc -l | tr -d ' ')" = "4" ] && ok "the tree holds exactly r/<id>.json and r/<id>.html for each public receipt, nothing else" || bad "unexpected files: $(find "$HO" -type f | tr '\n' ' ')"
python3 "$TMP/html-check.py" "$HO/r/$HOSTILE_ID.html" "$TMP/hostile.json" | grep -q '^FAIL' && bad "the STATIC hostile page fails the escaping checks" || ok "the static hostile page passes every escaping check too"
before="$(cd "$HO" && find . -type f -exec shasum {} + | sort)"
rcpt render --store "$HS2" --pubkey "$HPUB" --out "$HO"
[ "$RRC" -eq 0 ] && [ "$before" = "$(cd "$HO" && find . -type f -exec shasum {} + | sort)" ] && ok "re-rendering is idempotent (same bytes)" || bad "re-render changed the tree (rc=$RRC)"
HO2="$TMP/h-site-bad"
rcpt render --store "$HS" --pubkey "$HPUB" --out "$HO2" --json
if [ "$RRC" -eq 1 ] && jq -e --arg f "$FLIP_ID" --arg s "$SWAP_ID" '.ok==false and ([.failed[].id]|sort)==([$f,$s]|sort) and (.failed[0].error|type=="string")' "$ROUT" >/dev/null 2>&1; then
  ok "render over a store holding a tampered and a mis-filed receipt exits 1 and names both"
else bad "render over a bad store (rc=$RRC: $(head -c 300 "$ROUT"))"; fi
[ ! -e "$HO2/r/$FLIP_ID.json" ] && [ ! -e "$HO2/r/$FLIP_ID.html" ] && [ ! -e "$HO2/r/$SWAP_ID.json" ] && [ -f "$HO2/r/$PUB_ID.json" ] && ok "a receipt that fails verification is never published; the genuine ones still are" || bad "bad receipts were published or good ones were not"
rcpt render --store "$HS2" --pubkey "$HPUB"; [ "$RRC" -eq 2 ] && ok "render without --out is a usage error (exit 2)" || bad "render without --out (rc=$RRC)"
HEIMDALL_HOME="$TMP/h-empty-home" rcpt render --store "$HS2" --out "$TMP/h-site-notrust"
[ "$RRC" -eq 2 ] && [ ! -e "$TMP/h-site-notrust" ] && ok "render with no trust anchor is exit 2 and writes nothing" || bad "render without trust (rc=$RRC)"
rcpt render --store "$TMP/h-no-such-store" --pubkey "$HPUB" --out "$TMP/h-site-empty" --json
[ "$RRC" -eq 0 ] && jq -e '.ok==true and .rendered==[]' "$ROUT" >/dev/null 2>&1 && ok "render over an empty or missing store succeeds with nothing rendered" || bad "render over a missing store (rc=$RRC)"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

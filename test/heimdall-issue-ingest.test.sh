#!/usr/bin/env bash
# heimdall-issue-ingest.test.sh — THE ANONYMIZED ISSUE INGEST FALSIFIER SUITE (Wave 2, issue-collection).
#
# WHAT THIS GATES. The SERVER-SIDE issue ingest surface (bin/lib/cp_issue_ingest.py): a teammate's
# hmd session spools ZERO-CONTENT issue_v1 metadata and FLUSHES it to the control plane's SIGNED
# POST /issues, which lands it in the ISOLATED heimdall_corpus/issues/ keyspace keyed by the
# SERVER-DERIVED team_id_hash. Every one of those properties is a promise: a break is a
# brand-killing incident (a forged attribution, a cross-tenant read, a de-anonymizing leak). This
# suite is the falsifier belt — each section RED-tests a property that MUST hold. It runs the REAL
# cp_issue_ingest code, not a fake of it.
#
# THE FALSIFIERS (mapped to the INVARIANTS.md ledger):
#   1. SIGNED INGEST + ISOLATED NAMESPACE (INV-E/INV-G) — a signed POST /issues lands ONE issue in
#      the heimdall_corpus/issues/ namespace keyed by the SERVER-DERIVED team_id_hash (INV-C, NOT
#      the client's claim); an unsigned / bad-signature push is REFUSED at the cp_auth chokepoint.
#      FALSIFIER: an unsigned push that verifies + stores -> RED (fail-closed broken).
#   2. SERVER-DERIVED ATTRIBUTION (INV-C) — a client that sets ids.team_id_hash in the body to
#      another team's key must NOT land under that forged key; the server re-stamps it.
#      FALSIFIER: the client-claimed team_id_hash appearing in the store -> RED.
#   3. CROSS-NAMESPACE ISOLATION (INV-G, cardinal) — the issue backend can NEVER resolve a
#      presence/ops rel and the control-plane backend can NEVER resolve an issue rel; disjoint
#      keyspaces on the SAME backend. FALSIFIER: an issue write readable through the control-plane
#      namespace (or vice-versa) -> RED (a cross-tenant read path).
#   4. CROSS-TENANT PARTITION ISOLATION (INV-G) — team A's ingest lands ONLY under team A's
#      partition; team B's read path never surfaces team A's records.
#      FALSIFIER: team A's issue appearing in team B's partition read -> RED.
#   5. BOUNDARY DROPS (INV-F/T2) — a security_sensitive record is DROPPED fail-closed (never
#      stored in the public partition); a secret-bearing record is BLOCKED by the boundary belt.
#      FALSIFIER: a security_sensitive / secret byte-string landing in the store -> RED.
#
# Exit 0 iff ALL sections pass. Nonzero otherwise. stdlib + the shipped cp_* / issue_corpus /
# pmr_corpus code ONLY — ZERO real GCP / ZERO spend. Crypto (Ed25519) is required for the
# signed-ingest section; absent it, the suite SKIPS honestly (exit 0) rather than false-green.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_issue_ingest issue_corpus cp_state cp_auth cp_server cp_audit pmr_corpus; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# Crypto is required for the SIGNED ingest / refusal falsifier (section 1). Absent an Ed25519
# backend, skip the WHOLE suite honestly (a green with no crypto would be a false pass).
if ! "$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;sys.exit(0 if cp_auth.crypto_available() else 1)" >/dev/null 2>&1; then
  echo "heimdall-issue-ingest: SKIP — no Ed25519 backend (install \`cryptography\` or \`pynacl\`)."
  echo "RESULT: 0 passed, 0 failed (skipped)"
  exit 0
fi

# A hermetic per-run home + a UNIQUE corpus namespace so the cross-namespace isolation proof is
# honest — issues land under their OWN root, never the control-plane store, on the SAME backend.
ROOT_T="$(mktemp -d -t "issue-ingest.XXXXXX")"
HOME_T="$ROOT_T/home"
mkdir -p "$HOME_T"
cleanup() { rm -rf "$ROOT_T"; }
trap cleanup EXIT

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_CORPUS_NAMESPACE="heimdall_issue_gate"

echo "============================================================"
echo "ANONYMIZED ISSUE INGEST falsifier suite (Wave 2)"
echo "  home=$HEIMDALL_HOME  corpus_ns=$HEIMDALL_CORPUS_NAMESPACE"
echo "============================================================"
echo

DRIVER="$ROOT_T/driver.py"
cat >"$DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_auth
import cp_issue_ingest as ING
import cp_state
import pmr_corpus

HOME = os.environ["HEIMDALL_HOME"]
NS = pmr_corpus.corpus_namespace()

out = {}


def client_issue(issue_id, claimed_team, error_class="lint"):
    """A NESTED client issue_v1 carrying a BOGUS client-claimed team_id_hash — the server MUST
    re-stamp it with the server-derived team (INV-C), never trust the body field."""
    return {"schema": "issue_v1", "consent_version": "c1",
            "ids": {"issue_id": issue_id, "team_id_hash": claimed_team,
                    "repo_class_hash": "rc"},
            "when": {"ts": "1000", "tz_bucket": "utc"},
            "signal": {"error_class": error_class, "signature_hash": "sig" + issue_id,
                       "gate": "lint", "phase": "verify", "command": "test",
                       "severity": "low"},
            "env": {"os_class": "linux", "ci": False, "hmd_version": "v1"},
            "security_sensitive": False}


# ── SECTION 1 — signed ingest lands in the isolated namespace; unsigned/bad-sig REFUSED ──
secret = "team-secret-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
priv, pub = cp_auth.generate_keypair()
haid = "haid:issue-dev-1"
cp_auth.register_key(haid, pub, team_id=cp_auth.derive_team_id(secret), home=HOME)
server_team = cp_auth.registered_team(haid, home=HOME)

body = json.dumps({"issues": [client_issue("p1", "CLIENTCLAIM-not-my-team")]})
msg = cp_auth.canonical_message("POST", "/issues", body)
sig = cp_auth.sign(priv, msg)

# GOOD — verify at the cp_auth chokepoint (the seam the server runs before the route), then route.
ident = cp_auth.verify_identity(
    {"method": "POST", "path": "/issues", "body": body, "haid": haid, "signature": sig}, home=HOME)
resp = ING.issues_route(ident, {"body": body}, home=HOME)
stored = ING.all_issues(home=HOME)
out["s1_status"] = resp.status
out["s1_ingested"] = bool(resp.body.get("ingested"))
out["s1_stored_count"] = len(stored)
out["s1_stored_team"] = stored[0]["ids"]["team_id_hash"] if stored else None
out["s1_server_team"] = server_team
out["s1_client_claim_leaked"] = "CLIENTCLAIM-not-my-team" in json.dumps(stored)

# ISOLATION of the landing: the record is in the corpus namespace, NOT the control-plane store.
cp_backend = cp_state.get_backend(home=HOME)                     # namespace=None -> control-plane
out["s1_in_control_plane"] = bool(cp_backend.read_lines("issues/%s/issues.ndjson" % server_team))

# UNSIGNED — no signature on the request. The chokepoint MUST raise (server maps to 401).
out["s1_unsigned"] = "verified_BUG"
try:
    cp_auth.verify_identity(
        {"method": "POST", "path": "/issues", "body": body, "haid": haid}, home=HOME)
except cp_auth.AuthError as e:
    out["s1_unsigned"] = e.reason

# BAD SIGNATURE — a valid signature over a DIFFERENT body, presented for THIS body. MUST raise.
badsig = cp_auth.sign(priv, cp_auth.canonical_message("POST", "/issues", "{}"))
out["s1_badsig"] = "verified_BUG"
try:
    cp_auth.verify_identity(
        {"method": "POST", "path": "/issues", "body": body, "haid": haid, "signature": badsig},
        home=HOME)
except cp_auth.AuthError as e:
    out["s1_badsig"] = e.reason
out["s1_count_after_refusals"] = len(ING.all_issues(home=HOME))


# ── SECTION 3 — cross-namespace isolation (cardinal): issue <-> control-plane keyspaces disjoint ──
corp_backend = cp_state.get_backend(home=HOME, namespace=NS)
cp_backend.append_line("presence/acme/dev.ndjson", {"online": True, "marker": "OPSDATA_ctrlplane"})
out["s3_issue_reads_ctrlplane"] = corp_backend.read_lines("presence/acme/dev.ndjson")
out["s3_ctrlplane_reads_issue"] = cp_backend.read_lines("issues/%s/issues.ndjson" % server_team)
out["s3_ops_marker_in_issues"] = any(
    "OPSDATA_ctrlplane" in json.dumps(p) for p in ING.all_issues(home=HOME))
out["s3_issue_root"] = corp_backend.path("").rstrip("/").split("/")[-1]
out["s3_ctrlplane_root"] = cp_backend.path("").rstrip("/").split("/")[-1]


# ── SECTION 4 — cross-tenant partition isolation: team A's issue never in team B's read ──
secretB = "team-secret-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
privB, pubB = cp_auth.generate_keypair()
haidB = "haid:issue-dev-2"
cp_auth.register_key(haidB, pubB, team_id=cp_auth.derive_team_id(secretB), home=HOME)
server_team_b = cp_auth.registered_team(haidB, home=HOME)

bodyB = json.dumps({"issues": [client_issue("pb1", "CLIENTCLAIM-not-my-team")]})
sigB = cp_auth.sign(privB, cp_auth.canonical_message("POST", "/issues", bodyB))
identB = cp_auth.verify_identity(
    {"method": "POST", "path": "/issues", "body": bodyB, "haid": haidB, "signature": sigB},
    home=HOME)
ING.issues_route(identB, {"body": bodyB}, home=HOME)

out["s4_team_a_distinct"] = server_team != server_team_b
a_issues = ING.read_team_issues(server_team, home=HOME)
b_issues = ING.read_team_issues(server_team_b, home=HOME)
out["s4_a_ids"] = sorted(i["ids"]["issue_id"] for i in a_issues)
out["s4_b_ids"] = sorted(i["ids"]["issue_id"] for i in b_issues)
# team A's read must NOT surface team B's issue and vice-versa (disjoint partitions).
out["s4_a_sees_b"] = any(i["ids"]["issue_id"] == "pb1" for i in a_issues)
out["s4_b_sees_a"] = any(i["ids"]["issue_id"] == "p1" for i in b_issues)


# ── SECTION 5 — boundary drops: security-sensitive dropped, secret-bearing blocked ──
sec_issue = client_issue("psec", "CLIENTCLAIM-not-my-team", error_class="auth")
sec_issue["security_sensitive"] = True   # a client should never send this; the boundary drops it.
res_sec = ING.ingest_issues(server_team, [sec_issue], home=HOME)
out["s5_security_blocked"] = res_sec["blocked_security"]
out["s5_security_stored"] = res_sec["stored"]

AKIA = "AKIAIOSFODNN7EXAMPLE"   # the canonical AWS access-key-id shape (a secret_scan pattern).
# Smuggle the secret into a coded field so rebuild_issue keeps it as a token; the boundary belt
# re-scans the rebuilt record and MUST drop it (never store the secret byte-string).
secret_issue = client_issue("pkey", "CLIENTCLAIM-not-my-team")
secret_issue["signal"]["signature_hash"] = AKIA
res_key = ING.ingest_issues(server_team, [secret_issue], home=HOME)
out["s5_secret_blocked"] = res_key["blocked_secret"]
out["s5_secret_stored"] = res_key["stored"]
out["s5_secret_in_store"] = AKIA in json.dumps(ING.all_issues(home=HOME))

print(json.dumps(out))
PYEOF

OUT="$("$PY" "$DRIVER" 2>"$ROOT_T/driver.err")"
if [ -z "$OUT" ]; then
  bad "driver produced no output (see stderr)"; cat "$ROOT_T/driver.err" >&2
  echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
echo "  driver: $OUT"
echo

j() { printf '%s' "$OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

echo "── SECTION 1 — signed /issues ingest -> isolated namespace; unsigned/bad-sig REFUSED"
[ "$(j "['s1_status']")" = "200" ] && [ "$(j "['s1_ingested']")" = "True" ] \
  && [ "$(j "['s1_stored_count']")" = "1" ] \
  && ok "S1a a SIGNED POST /issues (200) lands ONE issue in the store" \
  || bad "S1a signed ingest did not land exactly one issue — out=$OUT"

[ "$(j "['s1_stored_team']")" = "$(j "['s1_server_team']")" ] \
  && [ "$(j "['s1_client_claim_leaked']")" = "False" ] \
  && ok "S1b the stored issue is keyed by the SERVER-DERIVED team_id_hash (INV-C), NOT the client claim" \
  || bad "S1b INV-C violated: the client-claimed team_id_hash leaked into the store — out=$OUT"

[ "$(j "['s1_in_control_plane']")" = "False" ] \
  && ok "S1c the issue landed in the ISOLATED corpus namespace, NOT the control-plane store" \
  || bad "S1c the issue leaked into the control-plane store (not isolated) — out=$OUT"

[ "$(j "['s1_unsigned']")" = "missing_signature" ] \
  && ok "S1d an UNSIGNED push is REFUSED at the auth chokepoint (missing_signature)" \
  || bad "S1d an unsigned push was NOT refused — out=$OUT"

[ "$(j "['s1_badsig']")" = "bad_signature" ] \
  && ok "S1e a BAD-SIGNATURE push is REFUSED (bad_signature)" \
  || bad "S1e a bad-signature push was NOT refused — out=$OUT"

[ "$(j "['s1_count_after_refusals']")" = "1" ] \
  && ok "S1f the refused pushes stored NOTHING (count unchanged) — the refusal is load-bearing" \
  || bad "S1f a refused push still landed a record — out=$OUT"

echo
echo "── SECTION 3 — cross-namespace isolation (cardinal — no cross-tenant read path)"
[ "$(j "['s3_issue_reads_ctrlplane']")" = "[]" ] \
  && ok "S3a the issue backend can NEVER resolve a control-plane (presence/ops) rel" \
  || bad "S3a the issue backend READ a control-plane rel (namespace leak) — out=$OUT"

[ "$(j "['s3_ctrlplane_reads_issue']")" = "[]" ] \
  && ok "S3b the control-plane backend can NEVER resolve an issue rel (FALSIFIER)" \
  || bad "S3b the control-plane backend READ an issue rel (cross-namespace read path) — out=$OUT"

[ "$(j "['s3_ops_marker_in_issues']")" = "False" ] \
  && ok "S3c the issue read path never surfaces the control-plane ops marker" \
  || bad "S3c ops data leaked into the issue read path — out=$OUT"

CROOT="$(j "['s3_issue_root']")"; CPROOT="$(j "['s3_ctrlplane_root']")"
[ -n "$CROOT" ] && [ -n "$CPROOT" ] && [ "$CROOT" != "$CPROOT" ] \
  && ok "S3d disjoint on-disk roots: issue=$CROOT vs control-plane=$CPROOT (different keyspaces)" \
  || bad "S3d the issue + control-plane share a root (not disjoint) — issue=$CROOT cp=$CPROOT"

echo
echo "── SECTION 4 — cross-tenant partition isolation (team A's issue never in team B's read)"
[ "$(j "['s4_team_a_distinct']")" = "True" ] \
  && ok "S4a team A and team B resolve to DISTINCT server-derived team_id_hash partitions" \
  || bad "S4a team A/B collapsed to the same partition — out=$OUT"

[ "$(j "['s4_a_sees_b']")" = "False" ] && [ "$(j "['s4_b_sees_a']")" = "False" ] \
  && ok "S4b team A's read never surfaces team B's issue and vice-versa (FALSIFIER — INV-G)" \
  || bad "S4b a cross-tenant partition read surfaced another team's issue — out=$OUT"

echo
echo "── SECTION 5 — boundary drops (security-sensitive dropped; secret-bearing blocked)"
[ "$(j "['s5_security_blocked']")" = "1" ] && [ "$(j "['s5_security_stored']")" = "0" ] \
  && ok "S5a a security_sensitive record is DROPPED fail-closed at the boundary (never stored, INV-F)" \
  || bad "S5a a security_sensitive record was NOT dropped at the boundary — out=$OUT"

[ "$(j "['s5_secret_blocked']")" = "1" ] && [ "$(j "['s5_secret_stored']")" = "0" ] \
  && [ "$(j "['s5_secret_in_store']")" = "False" ] \
  && ok "S5b a secret-bearing record is BLOCKED by the boundary belt; the secret NEVER lands (FALSIFIER)" \
  || bad "S5b the boundary secret belt failed — a secret may have landed — out=$OUT"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

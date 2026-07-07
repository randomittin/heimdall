#!/usr/bin/env bash
# heimdall-corpus-ingest.test.sh — THE PRE-MERGE CORPUS INGEST FALSIFIER SUITE (#10, spec §5.2).
#
# WHAT THIS GATES. The corpus is the acquisition-value data asset (heimdall-premerge-corpus-spec
# §3): clients spool ZERO-CONTENT pmr_v1 T0 records (+ opt-in T1 deny-context hunks) and FLUSH
# them to the control plane's SIGNED POST /corpus, which lands them in an ISOLATED
# heimdall_corpus/ namespace, rolls them up under a HARD k-anonymity gate, and shadow-synthesizes
# candidate rules. Every one of those properties is a promise to a paying team — a break is a
# brand-killing incident (a leaked secret, a cross-tenant read, a de-anonymized small-team cell).
# This suite is the falsifier belt: each section RED-tests a property that MUST hold.
#
# THE SIX FALSIFIERS (each runs the REAL corpus code, not a fake of it):
#   1. SIGNED INGEST + ISOLATED NAMESPACE — a signed POST /corpus lands a PMR in the heimdall_
#      corpus/ namespace keyed by the SERVER-DERIVED team_id_hash (INV-1, NOT the client's claim);
#      an unsigned / bad-signature push is REFUSED at the cp_auth chokepoint (the same discipline
#      the presence/roster routes use). FALSIFIER: an unsigned push that verifies -> RED.
#   2. K-ANONYMITY >= 20 (HARD gate) — an aggregate bucket backed by < 20 DISTINCT team_id_hash is
#      SUPPRESSED (no metrics served); >= 20 is published. Applied PER BUCKET. FALSIFIER: a
#      < 20-team bucket appearing with real rates -> RED (proves the gate is load-bearing).
#   3. SECRET-SCAN BEFORE STORE (T1 belt) — a planted AWS key in a T1 hunk is BLOCKED + counted,
#      never stored; the client before-send belt (scan_for_secrets) flags it too. FALSIFIER: the
#      secret byte-string appearing in the stored corpus -> RED.
#   4. CONSENT HONORED — telemetry OFF => the flusher's send gate (corpus_send_enabled) is False
#      (no byte leaves); T1 OFF => the hunk gate (any_hunks_enabled) is False (no hunk payload).
#      FALSIFIER: send/hunk gate True while consent is off -> RED.
#   5. CROSS-NAMESPACE ISOLATION (cardinal) — the corpus backend can NEVER resolve a presence/ops
#      rel and the control-plane backend can NEVER resolve a corpus rel; the two live under
#      DISJOINT keyspaces on the SAME backend. FALSIFIER: a corpus write readable through the
#      control-plane namespace (or vice-versa) -> RED (a cross-tenant read path).
#   6. FIRESTORE-MODE ROUND-TRIP (deployed-shape) — ingest + isolation hold under the REAL
#      FirestoreBackend (HEIMDALL_STATE_BACKEND=firestore), no "__" slug collision, no
#      path()-under-firestore raise. FALSIFIER: LocalBackend-green but Firestore-broken -> RED
#      (the presence bug taught us LocalBackend-green != Firestore-green).
#
# Exit 0 iff ALL sections pass. Nonzero otherwise. stdlib + the shipped cp_* / pmr_corpus code
# ONLY — ZERO real GCP / ZERO spend (section 6 uses the SAME faithful in-process firestore fake
# the cp-*-firestore gates use, or a caller-provided emulator). Crypto (Ed25519) is required for
# the signed-ingest section; absent it, the suite SKIPS honestly (exit 0) rather than false-green.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_corpus cp_corpus_aggregate cp_corpus_synth cp_state cp_state_firestore cp_auth cp_server pmr_corpus; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# Crypto is required for the SIGNED ingest / refusal falsifier (section 1) + section 6. Absent an
# Ed25519 backend, skip the WHOLE suite honestly (a green with no crypto would be a false pass).
if ! "$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;sys.exit(0 if cp_auth.crypto_available() else 1)" >/dev/null 2>&1; then
  echo "heimdall-corpus-ingest: SKIP — no Ed25519 backend (install \`cryptography\` or \`pynacl\`)."
  echo "RESULT: 0 passed, 0 failed (skipped)"
  exit 0
fi

# A hermetic per-run home + a UNIQUE corpus namespace (pinned via HEIMDALL_CORPUS_NAMESPACE) so
# the cross-namespace isolation proof is honest — the corpus lands under its OWN root, never the
# control-plane store, on the SAME backend.
ROOT_T="$(mktemp -d -t "corpus-ingest.XXXXXX")"
HOME_T="$ROOT_T/home"
mkdir -p "$HOME_T"
cleanup() { rm -rf "$ROOT_T"; }
trap cleanup EXIT

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_CORPUS_NAMESPACE="heimdall_corpus_gate"

echo "============================================================"
echo "PRE-MERGE CORPUS INGEST falsifier suite (#10)"
echo "  home=$HEIMDALL_HOME  corpus_ns=$HEIMDALL_CORPUS_NAMESPACE"
echo "============================================================"
echo

# ── shared python driver: the whole local-backend proof set (sections 1-5) prints ONE JSON line ──
DRIVER="$ROOT_T/local_driver.py"
cat >"$DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_auth
import cp_corpus
import cp_corpus_aggregate as AGG
import cp_state
import pmr_corpus

HOME = os.environ["HEIMDALL_HOME"]
NS = pmr_corpus.corpus_namespace()

out = {}


def client_pmr(pmr_id, claimed_team, lang="py", verdict="pass"):
    """A NESTED item-#4 client pmr_v1 carrying a BOGUS client-claimed team_id_hash — the server
    MUST re-stamp it with the server-derived team (INV-1), never trust the body field."""
    return {"schema": "pmr_v1",
            "ids": {"pmr_id": pmr_id, "team_id_hash": claimed_team, "repo_class_hash": "rc"},
            "when": {"ts": 1000, "tz_bucket": "u"},
            "agent": {"haid_class": {"tool": "claude", "model_family": "opus"}},
            "change": {"langs": [lang]},
            "verify": {"verdict": verdict, "deny_reasons": []}}


# ── SECTION 1 — signed ingest lands in the isolated namespace; unsigned/bad-sig REFUSED ──
secret = "team-secret-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
priv, pub = cp_auth.generate_keypair()
haid = "haid:corpus-dev-1"
cp_auth.register_key(haid, pub, team_id=cp_auth.derive_team_id(secret), home=HOME)
server_team = cp_auth.registered_team(haid, home=HOME)

body = json.dumps({"pmrs": [client_pmr("p1", "CLIENTCLAIM-not-my-team")]})
msg = cp_auth.canonical_message("POST", "/corpus", body)
sig = cp_auth.sign(priv, msg)

# GOOD — verify at the cp_auth chokepoint (the seam the server runs before the route), then route.
ident = cp_auth.verify_identity(
    {"method": "POST", "path": "/corpus", "body": body, "haid": haid, "signature": sig}, home=HOME)
resp = cp_corpus.corpus_route(ident, {"body": body}, home=HOME)
stored = cp_corpus.all_pmrs(home=HOME)
out["s1_status"] = resp.status
out["s1_ingested"] = bool(resp.body.get("ingested"))
out["s1_stored_count"] = len(stored)
out["s1_stored_team"] = stored[0]["team_id_hash"] if stored else None
out["s1_server_team"] = server_team
out["s1_client_claim_leaked"] = any(p.get("team_id_hash") == "CLIENTCLAIM-not-my-team" for p in stored)

# ISOLATION of the landing: the record is in the corpus namespace, NOT the control-plane store.
cp_backend = cp_state.get_backend(home=HOME)                     # namespace=None -> control-plane
out["s1_in_control_plane"] = bool(cp_backend.read_lines("t0/%s/pmr.ndjson" % server_team))

# UNSIGNED — no signature on the request. The chokepoint MUST raise (server maps to 401).
out["s1_unsigned"] = "verified_BUG"
try:
    cp_auth.verify_identity(
        {"method": "POST", "path": "/corpus", "body": body, "haid": haid}, home=HOME)
except cp_auth.AuthError as e:
    out["s1_unsigned"] = e.reason

# BAD SIGNATURE — a valid signature over a DIFFERENT body, presented for THIS body. MUST raise.
badsig = cp_auth.sign(priv, cp_auth.canonical_message("POST", "/corpus", "{}"))
out["s1_badsig"] = "verified_BUG"
try:
    cp_auth.verify_identity(
        {"method": "POST", "path": "/corpus", "body": body, "haid": haid, "signature": badsig},
        home=HOME)
except cp_auth.AuthError as e:
    out["s1_badsig"] = e.reason
# FALSIFIER guard: the refused pushes stored NOTHING extra (count is still 1 from the GOOD push).
out["s1_count_after_refusals"] = len(cp_corpus.all_pmrs(home=HOME))


# ── SECTION 2 — k-anonymity >= 20 HARD gate, applied PER BUCKET ──
def agg_pmr(team, lang="py"):
    return {"schema": "pmr_v1", "team_id_hash": team,
            "agent": {"tool": "claude", "model_family": "opus"},
            "change": {"langs": [lang]}, "verify": {"verdict": "pass", "deny_reasons": []},
            "human": {}}

K = pmr_corpus.K_ANONYMITY_MIN
# Exactly K distinct teams -> published (metrics served).
at_k = AGG.compute_aggregates([agg_pmr("t%03d" % i) for i in range(K)], k_min=K)
ov_k = at_k["dimensions"]["overall"]["all"]
out["s2_at_k_suppressed"] = bool(ov_k.get("suppressed"))
out["s2_at_k_has_metrics"] = "verdict_rates" in ov_k
# K-1 distinct teams -> SUPPRESSED (no metrics, only the marker).
below = AGG.compute_aggregates([agg_pmr("t%03d" % i) for i in range(K - 1)], k_min=K)
ov_b = below["dimensions"]["overall"]["all"]
out["s2_below_suppressed"] = bool(ov_b.get("suppressed"))
out["s2_below_has_metrics"] = "verdict_rates" in ov_b
out["s2_below_teams"] = ov_b.get("teams")
# PER-BUCKET: a large 'py' bucket (K teams) publishes while a small 'rs' bucket (5 teams) is
# suppressed IN THE SAME rollup — the gate is per-cell, not global.
mixed = [agg_pmr("t%03d" % i, "py") for i in range(K)] + [agg_pmr("t%03d" % i, "rs") for i in range(5)]
mx = AGG.compute_aggregates(mixed, k_min=K)
out["s2_bucket_py_suppressed"] = bool(mx["dimensions"]["by_lang"]["py"]["suppressed"])
out["s2_bucket_rs_suppressed"] = bool(mx["dimensions"]["by_lang"]["rs"]["suppressed"])


# ── SECTION 3 — secret-scan BEFORE store (T1 belt): a planted AWS key is BLOCKED, never stored ──
AKIA = "AKIAIOSFODNN7EXAMPLE"   # the canonical AWS access-key-id shape (a secret_scan pattern).
secret_hunk = {"pmr_id": "h-secret", "deny_reason": "leak", "gate": "secret-scan",
               "lang": "py", "diff": "const key = '%s'" % AKIA}
clean_hunk = {"pmr_id": "h-clean", "deny_reason": "style", "gate": "lint", "lang": "py",
              "note": "coded shape only, no content"}
# The CLIENT before-send belt (the flusher re-runs this) flags the secret, clears the clean one.
out["s3_belt_findings"] = pmr_corpus.scan_for_secrets(secret_hunk)
out["s3_belt_clean"] = pmr_corpus.scan_for_secrets(clean_hunk)
# The SERVER boundary: ingest both; the secret hunk is blocked, the clean one stored.
res = cp_corpus.ingest_corpus(server_team, [], [secret_hunk, clean_hunk], home=HOME)
out["s3_blocked_hunks"] = res["blocked_hunks"]
out["s3_stored_hunks"] = res["stored_hunks"]
# FALSIFIER: the secret byte-string must NOT appear anywhere in the stored T1 corpus.
stored_hunks_blob = json.dumps(cp_corpus.all_hunks(home=HOME))
out["s3_secret_in_store"] = AKIA in stored_hunks_blob
out["s3_clean_landed"] = any(h.get("pmr_id") == "h-clean" for h in cp_corpus.all_hunks(home=HOME))


# ── SECTION 4 — consent honored: telemetry OFF => no send; T1 OFF => no hunk payload ──
# Default state (no explicit off): send is enabled, T1 is OFF (no repo opted in).
out["s4_default_send"] = pmr_corpus.corpus_send_enabled(home=HOME)
out["s4_default_hunks"] = pmr_corpus.any_hunks_enabled(home=HOME)
# Persisted OFF => the flusher's master send gate is False (no network byte leaves).
pmr_corpus.set_enabled(False, home=HOME)
out["s4_off_send"] = pmr_corpus.corpus_send_enabled(home=HOME)
pmr_corpus.set_enabled(True, home=HOME)
# Per-repo T1 opt-in flips any_hunks_enabled; without it the flusher sends NO hunk payload.
out["s4_hunks_before_optin"] = pmr_corpus.any_hunks_enabled(home=HOME)
pmr_corpus.set_hunks("repo-class-xyz", True, home=HOME)
out["s4_hunks_after_optin"] = pmr_corpus.any_hunks_enabled(home=HOME)
pmr_corpus.set_hunks("repo-class-xyz", False, home=HOME)


# ── SECTION 5 — cross-namespace isolation (cardinal): corpus <-> control-plane keyspaces disjoint ──
corp_backend = cp_state.get_backend(home=HOME, namespace=NS)
# Plant an OPS/presence record in the CONTROL-PLANE namespace.
cp_backend.append_line("presence/acme/dev.ndjson", {"online": True, "marker": "OPSDATA_ctrlplane"})
# The corpus backend must NOT resolve that control-plane rel.
out["s5_corpus_reads_ctrlplane"] = corp_backend.read_lines("presence/acme/dev.ndjson")
# The control-plane backend must NOT resolve the corpus T0 rel.
out["s5_ctrlplane_reads_corpus"] = cp_backend.read_lines("t0/%s/pmr.ndjson" % server_team)
# The corpus read path must NEVER surface the ops marker.
out["s5_ops_marker_in_corpus"] = any(
    "OPSDATA_ctrlplane" in json.dumps(p) for p in cp_corpus.all_pmrs(home=HOME))
# Disjoint on-disk roots (local backend): corpus lands under <ns>/, control-plane under
# control-plane/ — different directories, so no rel can be shared.
out["s5_corpus_root"] = corp_backend.path("").rstrip("/").split("/")[-1]
out["s5_ctrlplane_root"] = cp_backend.path("").rstrip("/").split("/")[-1]

print(json.dumps(out))
PYEOF

OUT="$("$PY" "$DRIVER" 2>"$ROOT_T/local.err")"
if [ -z "$OUT" ]; then
  bad "local driver produced no output (see stderr)"; cat "$ROOT_T/local.err" >&2
  echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
echo "  local driver: $OUT"
echo

j() { printf '%s' "$OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

echo "── SECTION 1 — signed /corpus ingest -> isolated namespace; unsigned/bad-sig REFUSED"
[ "$(j "['s1_status']")" = "200" ] && [ "$(j "['s1_ingested']")" = "True" ] \
  && [ "$(j "['s1_stored_count']")" = "1" ] \
  && ok "S1a a SIGNED POST /corpus (200) lands ONE PMR in the corpus store" \
  || bad "S1a signed ingest did not land exactly one PMR — out=$OUT"

[ "$(j "['s1_stored_team']")" = "$(j "['s1_server_team']")" ] \
  && [ "$(j "['s1_client_claim_leaked']")" = "False" ] \
  && ok "S1b the stored PMR is keyed by the SERVER-DERIVED team_id_hash (INV-1), NOT the client claim" \
  || bad "S1b INV-1 violated: the client-claimed team_id_hash leaked into the store — out=$OUT"

[ "$(j "['s1_in_control_plane']")" = "False" ] \
  && ok "S1c the PMR landed in the ISOLATED corpus namespace, NOT the control-plane store" \
  || bad "S1c the PMR leaked into the control-plane store (not isolated) — out=$OUT"

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
KMIN="$("$PY" -c "import sys;sys.path.insert(0,'$LIB');import pmr_corpus;print(pmr_corpus.K_ANONYMITY_MIN)")"
echo "── SECTION 2 — k-anonymity >= $KMIN HARD gate (per bucket)"
[ "$(j "['s2_at_k_suppressed']")" = "False" ] && [ "$(j "['s2_at_k_has_metrics']")" = "True" ] \
  && ok "S2a a bucket with >= K distinct teams is PUBLISHED (metrics served)" \
  || bad "S2a a >= K-team bucket was suppressed — out=$OUT"

[ "$(j "['s2_below_suppressed']")" = "True" ] && [ "$(j "['s2_below_has_metrics']")" = "False" ] \
  && ok "S2b a bucket with < K distinct teams is SUPPRESSED — NO metrics, only the marker (FALSIFIER)" \
  || bad "S2b a < K-team bucket SERVED its metrics (k-anonymity broken) — out=$OUT"

[ "$(j "['s2_bucket_py_suppressed']")" = "False" ] && [ "$(j "['s2_bucket_rs_suppressed']")" = "True" ] \
  && ok "S2c the gate is PER BUCKET: a small lang cell is suppressed while a large one publishes in one rollup" \
  || bad "S2c the per-bucket k-anonymity gate did not hold — out=$OUT"

echo
echo "── SECTION 3 — secret-scan BEFORE store (T1 belt)"
[ "$(j "['s3_belt_findings']")" != "[]" ] && [ "$(j "['s3_belt_clean']")" = "[]" ] \
  && ok "S3a the client before-send belt (scan_for_secrets) FLAGS the planted AWS key, clears the clean hunk" \
  || bad "S3a the before-send secret belt did not flag the planted key — out=$OUT"

[ "$(j "['s3_blocked_hunks']")" = "1" ] && [ "$(j "['s3_stored_hunks']")" = "1" ] \
  && ok "S3b the server boundary BLOCKS the secret hunk (blocked=1) and stores the clean one (stored=1)" \
  || bad "S3b the server-side secret boundary miscounted — out=$OUT"

[ "$(j "['s3_secret_in_store']")" = "False" ] && [ "$(j "['s3_clean_landed']")" = "True" ] \
  && ok "S3c the planted secret NEVER lands in the stored corpus (FALSIFIER); the clean hunk does" \
  || bad "S3c the planted secret leaked into the stored T1 corpus — out=$OUT"

echo
echo "── SECTION 4 — consent honored (telemetry off => no send; T1 off => no hunk payload)"
[ "$(j "['s4_default_send']")" = "True" ] \
  && ok "S4a with consent ON the flusher's send gate (corpus_send_enabled) is True" \
  || bad "S4a the default send gate was not True — out=$OUT"

[ "$(j "['s4_off_send']")" = "False" ] \
  && ok "S4b telemetry OFF => the send gate is False — the flusher sends NOTHING (FALSIFIER)" \
  || bad "S4b telemetry off did NOT close the send gate — out=$OUT"

[ "$(j "['s4_hunks_before_optin']")" = "False" ] && [ "$(j "['s4_hunks_after_optin']")" = "True" ] \
  && ok "S4c T1 is OFF by default (no hunk payload) and flips ON only on explicit per-repo opt-in" \
  || bad "S4c the T1 hunk consent gate did not honor opt-in state — out=$OUT"

echo
echo "── SECTION 5 — cross-namespace isolation (cardinal — no cross-tenant read path)"
[ "$(j "['s5_corpus_reads_ctrlplane']")" = "[]" ] \
  && ok "S5a the corpus backend can NEVER resolve a control-plane (presence/ops) rel" \
  || bad "S5a the corpus backend READ a control-plane rel (namespace leak) — out=$OUT"

[ "$(j "['s5_ctrlplane_reads_corpus']")" = "[]" ] \
  && ok "S5b the control-plane backend can NEVER resolve a corpus rel (FALSIFIER)" \
  || bad "S5b the control-plane backend READ a corpus rel (cross-namespace read path) — out=$OUT"

[ "$(j "['s5_ops_marker_in_corpus']")" = "False" ] \
  && ok "S5c the corpus read path never surfaces the control-plane ops marker" \
  || bad "S5c ops data leaked into the corpus read path — out=$OUT"

CROOT="$(j "['s5_corpus_root']")"; CPROOT="$(j "['s5_ctrlplane_root']")"
[ -n "$CROOT" ] && [ -n "$CPROOT" ] && [ "$CROOT" != "$CPROOT" ] \
  && ok "S5d disjoint on-disk roots: corpus=$CROOT vs control-plane=$CPROOT (different keyspaces)" \
  || bad "S5d the corpus + control-plane share a root (not disjoint) — corpus=$CROOT cp=$CPROOT"

# ── SECTION 6 — FIRESTORE-MODE round-trip (deployed-shape: LocalBackend-green != Firestore-green) ──
echo
echo "── SECTION 6 — firestore-mode ingest + isolation (the deployed-shape guard)"

FS_EXT="$ROOT_T/fs"
mkdir -p "$FS_EXT"
FS_HOME="$FS_EXT/home"
mkdir -p "$FS_HOME"

MODE=""
# (0) caller-provided emulator (real client).
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  MODE="emulator"
  echo "  using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client)"
fi
# (2) faithful in-process fake (the SAME double the cp-*-firestore gates use). The fake is
# deterministic + zero-dep and it exercises the SHIPPED FirestoreBackend code (only the external
# service is a double), which is exactly what this deployed-shape guard needs.
if [ -z "$MODE" ]; then
  MODE="fake"
  FAKEPKG="$FS_EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore FirestoreBackend uses. PERSISTS
# to the JSON file named by HEIMDALL_FAKE_FS_STORE so a read after a write shares one store.
import json
import os

_STORE_ENV = "HEIMDALL_FAKE_FS_STORE"


def _store_path():
    p = os.environ.get(_STORE_ENV)
    if not p:
        raise RuntimeError("fake firestore needs %s set to a path" % _STORE_ENV)
    return p


def _load():
    try:
        with open(_store_path(), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _save(data):
    tmp = _store_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, _store_path())


class Client:
    def __init__(self, project=None, database=None):
        self.project = project

    def collection(self, name):
        return CollectionRef(name)

    def transaction(self):
        return _Transaction()


class CollectionRef:
    def __init__(self, path):
        self._path = path

    def document(self, doc_id):
        return DocRef(self._path, doc_id)

    def order_by(self, field):
        return _Query(self._path, order_field=field)

    def stream(self):
        return _Query(self._path).stream()


class _Query:
    def __init__(self, coll_path, order_field=None):
        self._coll_path = coll_path
        self._order_field = order_field

    def order_by(self, field):
        return _Query(self._coll_path, order_field=field)

    def stream(self):
        data = _load()
        coll = data.get("collections", {}).get(self._coll_path, {})
        items = []
        for doc_id, doc in coll.items():
            items.append(_Snapshot(self._coll_path, doc_id, doc.get("fields")))
        if self._order_field:
            items.sort(key=lambda s: (s.to_dict() or {}).get(self._order_field))
        else:
            items.sort(key=lambda s: s.id)
        return iter(items)


class DocRef:
    def __init__(self, coll_path, doc_id):
        self._coll_path = coll_path
        self._doc_id = doc_id

    @property
    def id(self):
        return self._doc_id

    def collection(self, name):
        return CollectionRef("%s/%s/%s" % (self._coll_path, self._doc_id, name))

    def get(self, transaction=None):
        data = _load()
        doc = data.get("collections", {}).get(self._coll_path, {}).get(self._doc_id)
        fields = doc.get("fields") if doc else None
        return _Snapshot(self._coll_path, self._doc_id, fields)

    def set(self, fields, merge=False):
        data = _load()
        colls = data.setdefault("collections", {})
        coll = colls.setdefault(self._coll_path, {})
        doc = coll.setdefault(self._doc_id, {"fields": {}})
        if merge:
            cur = dict(doc.get("fields") or {})
            cur.update(fields)
            doc["fields"] = cur
        else:
            doc["fields"] = dict(fields)
        _save(data)


class _Snapshot:
    def __init__(self, coll_path, doc_id, fields):
        self._coll_path = coll_path
        self._doc_id = doc_id
        self._fields = fields

    @property
    def id(self):
        return self._doc_id

    @property
    def exists(self):
        return self._fields is not None

    def to_dict(self):
        return dict(self._fields) if self._fields is not None else None


class _Transaction:
    def set(self, ref, fields, merge=False):
        ref.set(fields, merge=merge)

    def get(self, ref):
        return ref.get()


def transactional(func):
    def _wrapped(transaction, *args, **kwargs):
        return func(transaction, *args, **kwargs)
    return _wrapped
PYEOF
  cat >"$FAKEPKG/sitecustomize.py" <<'PYEOF'
import importlib
import sys

import _fake_firestore_impl as _impl

for _name in ("google", "google.cloud"):
    if _name not in sys.modules:
        try:
            importlib.import_module(_name)
        except Exception:  # noqa: BLE001 — synthesize a bare package when google is absent.
            import types
            _pkg = types.ModuleType(_name)
            _pkg.__path__ = []
            sys.modules[_name] = _pkg

sys.modules["google.cloud.firestore"] = _impl
setattr(sys.modules["google.cloud"], "firestore", _impl)
PYEOF
  export HEIMDALL_FAKE_FS_STORE="$FS_EXT/fake_fs.json"
  : >"$HEIMDALL_FAKE_FS_STORE"
  export PYTHONPATH="$FAKEPKG${PYTHONPATH:+:$PYTHONPATH}"
fi
echo "  firestore MODE=$MODE"

FS_DRIVER="$ROOT_T/fs_driver.py"
cat >"$FS_DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_auth
import cp_corpus
import cp_state
import pmr_corpus

HOME = os.environ["HEIMDALL_HOME"]
NS = pmr_corpus.corpus_namespace()
out = {}

# Enroll a member + drive the SIGNED ingest through the route UNDER THE FIRESTORE BACKEND.
secret = "team-secret-FSFSFSFSFSFSFSFSFSFSFSFSFSFS"
priv, pub = cp_auth.generate_keypair()
haid = "haid:corpus-fs-dev"
cp_auth.register_key(haid, pub, team_id=cp_auth.derive_team_id(secret), home=HOME)
server_team = cp_auth.registered_team(haid, home=HOME)

# No path SEGMENT may contain the firestore "__" doc-id separator (the presence-bug class).
t0_rel = "t0/%s/pmr.ndjson" % server_team
out["fs_team"] = server_team
out["fs_team_has_dunder"] = "__" in server_team
out["fs_rel_segment_dunder"] = any("__" in seg for seg in t0_rel.split("/"))

body = json.dumps({"pmrs": [{"schema": "pmr_v1",
                             "ids": {"pmr_id": "pfs", "team_id_hash": "CLAIM", "repo_class_hash": "r"},
                             "when": {"ts": 1}, "verify": {"verdict": "pass"}}]})
sig = cp_auth.sign(priv, cp_auth.canonical_message("POST", "/corpus", body))
ident = cp_auth.verify_identity(
    {"method": "POST", "path": "/corpus", "body": body, "haid": haid, "signature": sig}, home=HOME)
resp = cp_corpus.corpus_route(ident, {"body": body}, home=HOME)
out["fs_status"] = resp.status
landed = cp_corpus.all_pmrs(home=HOME)   # the READ path (list_teams + read_lines) under firestore
out["fs_landed_count"] = len(landed)
out["fs_landed_team"] = landed[0]["team_id_hash"] if landed else None

# Cross-namespace isolation UNDER FIRESTORE: control-plane root collection vs corpus root
# collection are disjoint, so neither backend resolves the other's rel.
cp_backend = cp_state.get_backend(home=HOME)
corp_backend = cp_state.get_backend(home=HOME, namespace=NS)
cp_backend.append_line("presence/acme/dev.ndjson", {"marker": "OPSDATA_fs"})
out["fs_corpus_reads_ctrlplane"] = corp_backend.read_lines("presence/acme/dev.ndjson")
out["fs_ctrlplane_reads_corpus"] = cp_backend.read_lines(t0_rel)

# path() MUST raise under firestore — and the corpus code proves it NEVER calls it, because every
# ingest/read above succeeded (a single path() call would have raised BackendUnavailable).
out["fs_path_raises"] = False
try:
    corp_backend.path("t0")
except cp_state.BackendUnavailable:
    out["fs_path_raises"] = True

print(json.dumps(out))
PYEOF

FSOUT="$(env HEIMDALL_STATE_BACKEND=firestore HEIMDALL_HOME="$FS_HOME" \
  HEIMDALL_FIRESTORE_ROOT="corpus_gate_cp" HEIMDALL_FIRESTORE_PROJECT="corpus-ingest-fs-test" \
  "$PY" "$FS_DRIVER" 2>"$ROOT_T/fs.err")"
if [ -z "$FSOUT" ]; then
  bad "S6 firestore driver produced no output (see stderr)"; cat "$ROOT_T/fs.err" >&2
else
  echo "  fs driver: $FSOUT"
  fj() { printf '%s' "$FSOUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

  [ "$(fj "['fs_status']")" = "200" ] && [ "$(fj "['fs_landed_count']")" = "1" ] \
    && [ "$(fj "['fs_landed_team']")" = "$(fj "['fs_team']")" ] \
    && ok "S6a a signed ingest LANDS + reads back under the FIRESTORE backend (server-derived team)" \
    || bad "S6a firestore ingest/read-back failed — out=$FSOUT"

  [ "$(fj "['fs_team_has_dunder']")" = "False" ] && [ "$(fj "['fs_rel_segment_dunder']")" = "False" ] \
    && ok "S6b no '__' in any corpus path segment (no firestore doc-id slug collision)" \
    || bad "S6b a corpus path segment contains the '__' firestore separator — out=$FSOUT"

  [ "$(fj "['fs_corpus_reads_ctrlplane']")" = "[]" ] && [ "$(fj "['fs_ctrlplane_reads_corpus']")" = "[]" ] \
    && ok "S6c cross-namespace isolation HOLDS under firestore (disjoint root collections)" \
    || bad "S6c a namespace leaked under firestore — out=$FSOUT"

  [ "$(fj "['fs_path_raises']")" = "True" ] \
    && ok "S6d path() raises under firestore, yet ingest+read succeeded => the corpus code never calls path()" \
    || bad "S6d path() did not raise under firestore (unexpected backend shape) — out=$FSOUT"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

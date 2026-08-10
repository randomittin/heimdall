#!/usr/bin/env bash
# cp-presence-firestore-pushdown.test.sh — THE PROD-READ REGRESSION GATE: the presence roster
# READ must PUSH ITS DOC-ID PREFIX DOWN to Firestore, never silently fall back to a full-
# collection scan.
#
# THE INCIDENT THIS GATES (production Cloud Run, HEIMDALL_STATE_BACKEND=firestore). A valid
# signed presence BEAT (POST /presence) returned HTTP 200 and the record WAS written to
# Firestore — yet GET /roster-team with the SAME team secret + project read back {"online":[]},
# and a raw enumeration HUNG for ~2 minutes. The write landed a durable doc; the roster READ
# could not enumerate it.
#
# ROOT CAUSE (firestore-only, network-independent, invisible to the fake-backend suites).
# cp_state_firestore._prefix_query is the bug #17 "bounded read" that pushes a document-id RANGE
# filter to Firestore so list_names/exists scan ONLY the "<rel_dir>__*" family, never the whole
# heimdall_cp collection. It obtained the document-id field path via
#     docid = firestore.FieldPath.document_id()
# But the PINNED prod client (google-cloud-firestore==2.16.1, deploy/requirements-firestore.txt)
# does NOT export FieldPath at the top-level google.cloud.firestore namespace (it lives in
# firestore_v1.field_path; only FieldFilter is exported). So that line raised AttributeError,
# which _prefix_query's own `except Exception:` SWALLOWED, DEGRADING to the FULL collection ref.
# Every list_names/exists then streamed the ENTIRE, ever-growing heimdall_cp collection under the
# 20s query timeout: while the collection was small the scan finished (roster worked "earlier
# today"); once it grew past what a full scan completes in 20s, every read hit DeadlineExceeded
# -> the tolerant `except` -> [] -> a SILENT empty roster (and a raw call HUNG). The pushdown had
# been INERT since it shipped — it never once bounded the scan on the pinned client.
#
# THE FIX under test: _prefix_query resolves the document-id path from a location that EXISTS in
# the pinned client (firestore_v1.field_path.FieldPath.document_id(), == the sentinel "__name__"),
# with a literal-"__name__" fallback, so the FieldFilter doc-id RANGE is actually built and pushed
# down. A build failure now degrades LOUDLY (a one-line stderr warning), never silently.
#
# THE FALSIFIER (deterministic, NO network — query construction is lazy in the client, only
# .stream() hits Firestore). Build a FirestoreBackend over a REAL google.cloud.firestore client
# (anonymous creds; never contacts GCP) and assert _prefix_query(<non-empty prefix>) returns a
# BOUNDED Query carrying doc-id range filters — NOT the bare CollectionReference the silent
# degrade returns.
#   PRE-FIX  : firestore.FieldPath missing -> AttributeError -> returns CollectionReference == RED
#   POST-FIX : returns a Query with >=1 field filter                                     == GREEN
#
# Requires the real google-cloud-firestore client (deploy-only dep). When it is absent this gate
# cannot exercise the real client API, so it SKIPs LOUDLY (exit 0) rather than pass vacuously —
# the exact fake-backend blind spot that let the bug ship is called out in the skip message.
#
# Exit 0 = the pushdown is built (or the real client is unavailable to test). Nonzero = the read
# silently degraded to a full-collection scan (the prod-empty-roster regression).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

[ -f "$LIB/cp_state_firestore.py" ] || { echo "FATAL: $LIB/cp_state_firestore.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

echo "============================================================"
echo "PROD-READ regression gate — presence roster READ pushes its doc-id prefix down"
echo "============================================================"
echo

# Is the REAL firestore client importable? (deploy-only dep; laptops usually lack it.)
if ! "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  echo "  SKIP google-cloud-firestore is not installed on this host, so the REAL client API"
  echo "       (the exact surface the bug lived on: firestore.FieldPath missing in 2.16.1)"
  echo "       cannot be exercised. Install deploy/requirements-firestore.txt to run this gate."
  echo "       NB: the fake-backend firestore suites CANNOT catch this class — that blind spot"
  echo "       is why the prod-empty-roster regression shipped."
  echo
  echo "RESULT: SKIPPED (0 assertions ran — this is NOT a pass)"
  # 0 passed / 0 failed makes the skip VISIBLE to test/run-all.sh as a zero-assertion row.
  # A silent exit 0 here would be indistinguishable from a gate that actually proved the
  # pushdown — which is exactly how a vacuous gate hides.
  printf 'cp-presence-firestore-pushdown: 0 passed, 0 failed (SKIPPED — google-cloud-firestore absent)\n'
  exit 0
fi

OUT="$("$PY" - <<'PYEOF' 2>&1
import sys, os
sys.path.insert(0, os.environ["LIB"])
from google.cloud import firestore
try:
    from google.auth.credentials import AnonymousCredentials
    creds = AnonymousCredentials()
except Exception:  # noqa: BLE001 — fall back to default creds discovery (still no network for build).
    creds = None
import cp_state_firestore as F

# A REAL client — construction + query BUILDING never touch the network (only .stream() would).
client = firestore.Client(project="pushdown-falsify", credentials=creds)
b = F.FirestoreBackend(client=client)

prefix = "presence__github.com_acme_widget__" + "0" * 32 + "__"
q = b._prefix_query(prefix)
qtype = type(q).__name__
# The silent degrade returns the bare CollectionReference (whole-collection scan). The fix returns
# a bounded Query carrying the doc-id range filters. CollectionReference has no pushed filters.
degraded = (qtype == "CollectionReference")
n_filters = len(getattr(q, "_field_filters", ()) or ())
print("qtype=%s degraded=%s n_filters=%d" % (qtype, degraded, n_filters))
PYEOF
)"
RC=$?
echo "  probe: $OUT"
echo

if [ "$RC" -ne 0 ]; then
  echo "  FAIL the pushdown probe crashed (rc=$RC)"; echo; echo "RESULT: FAIL"
  printf 'cp-presence-firestore-pushdown: 0 passed, 1 failed\n'
  exit 1
fi

# GREEN iff the query is bounded (not the degraded CollectionReference) AND carries >=1 filter.
if grep -q "degraded=False" <<<"$OUT" && grep -qE "n_filters=[1-9]" <<<"$OUT"; then
  echo "  PASS _prefix_query pushes the doc-id RANGE down (bounded Query, doc-id filters present)"
  echo; echo "RESULT: PASS"
  printf 'cp-presence-firestore-pushdown: 1 passed, 0 failed\n'
  exit 0
else
  echo "  FAIL _prefix_query DEGRADED to a full-collection scan (bounded pushdown NOT built) —"
  echo "       the prod-empty-roster / 2-min-hang regression. firestore.FieldPath is absent in"
  echo "       the pinned client; resolve the doc-id path from firestore_v1.field_path instead."
  echo; echo "RESULT: FAIL"
  printf 'cp-presence-firestore-pushdown: 0 passed, 1 failed\n'
  exit 1
fi

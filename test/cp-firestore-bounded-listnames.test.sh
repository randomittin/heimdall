#!/usr/bin/env bash
# cp-firestore-bounded-listnames.test.sh — THE BOUNDED-ENUMERATION GATE (bug #17).
#
# THE INCIDENT THIS GATES (live prod, revision heimdall-control-plane-00050). The gated tick's
# drain called cp_team_queue.known_team_ids -> FirestoreBackend.list_names("teamq"), which
# streamed the ENTIRE `heimdall_cp` root collection every tick and filtered by prefix in Python
# (`self._root().stream()` — no doc-id range pushdown, no page bound, no timeout). As the
# collection grew past 300+ docs (TTL/nonce/ratelimit/audit families), that per-tick full scan
# was the wedge point of the silent hang.
#
# THE FIX THIS GATES: list_names now streams a PREFIX-BOUNDED query — a Firestore document-id
# RANGE filter [<rel_dir>__, <rel_dir>__] pushed to the server — so ONLY the target family
# is scanned, never the whole collection. This gate seeds a LARGE collection (500 docs: a handful
# of teamq partitions among hundreds of unrelated docs) behind a fake google.cloud.firestore that
# COUNTS how many docs each read actually touches, then asserts list_names("teamq"):
#   (a) returns EXACTLY the teamq partition names (correctness preserved), AND
#   (b) SCANNED only the teamq doc-id range, NOT the whole collection (boundedness).
#
# FALSIFIER (why this fails without the fix). The fake's UNBOUNDED CollectionRef.stream() (the old
# `self._root().stream()` path) yields ALL 500 docs and drives the scan counter to >=500; the
# BOUNDED where(FieldFilter(document_id ...)) path yields only the ~5 teamq docs and keeps the
# counter tiny. So a regression back to the full-collection scan turns (b) RED (scanned ~= 500).
#
# Hermetic: an in-process fake firestore client (no real GCP, no emulator, no network). The
# SHIPPED cp_state_firestore code runs verbatim; only the external service is a double. Exit 0 =
# list_names is CORRECT and BOUNDED on a large collection.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

[ -f "$LIB/cp_state_firestore.py" ] || { echo "FATAL: $LIB/cp_state_firestore.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-boundln.$(printf 'X%.0s' 1 2 3 4)")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

DRIVER="$WORK/bounded_driver.py"
cat >"$DRIVER" <<'PYEOF'
import os
import sys
import types

sys.path.insert(0, os.environ["LIB"])

# ── an in-process FAKE google.cloud.firestore that supports the DOCUMENT-ID RANGE query the fix
#    uses (FieldPath.document_id() + FieldFilter + CollectionRef.where) AND counts docs SCANNED,
#    so the gate can prove the enumeration is bounded (the counter stays tiny) not a full scan. ──

SCANNED = {"n": 0}   # total docs yielded across ALL reads this run (the boundedness probe).


class FieldPath:
    @staticmethod
    def document_id():
        return "__name__"


class FieldFilter:
    def __init__(self, field, op, value):
        self.field = field
        self.op = op
        self.value = value


def _match(doc_id, filters):
    for f in filters:
        if f.field != "__name__":
            return False
        if f.op == ">=" and not (doc_id >= f.value):
            return False
        if f.op == "<=" and not (doc_id <= f.value):
            return False
    return True


class _Snapshot:
    def __init__(self, doc_id, fields):
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


class _Query:
    def __init__(self, coll, filters):
        self._coll = coll
        self._filters = list(filters)

    def where(self, filter=None):   # noqa: A002 — mirrors the real client kwarg name.
        return _Query(self._coll, self._filters + [filter])

    def order_by(self, field):
        return self

    def stream(self, timeout=None):
        # BOUNDED read: yield ONLY the docs whose id satisfies the doc-id range filters, and count
        # each one. A correctly-bounded list_names touches only the small target family here.
        for doc_id in sorted(self._coll._docs):
            if _match(doc_id, self._filters):
                SCANNED["n"] += 1
                yield _Snapshot(doc_id, self._coll._docs[doc_id])


class _DocRef:
    def __init__(self, coll, doc_id):
        self._coll = coll
        self._doc_id = doc_id

    @property
    def id(self):
        return self._doc_id

    def get(self, transaction=None, timeout=None):
        # A single-doc read counts as ONE doc scanned (list_names never calls this; exists does).
        SCANNED["n"] += 1
        return _Snapshot(self._doc_id, self._coll._docs.get(self._doc_id))

    def set(self, fields, merge=False):
        cur = self._coll._docs.get(self._doc_id) if merge else None
        if merge and isinstance(cur, dict):
            new = dict(cur)
            new.update(fields)
            self._coll._docs[self._doc_id] = new
        else:
            self._coll._docs[self._doc_id] = dict(fields)


class CollectionRef:
    def __init__(self, docs):
        self._docs = docs

    def document(self, doc_id):
        return _DocRef(self, doc_id)

    def where(self, filter=None):   # noqa: A002 — mirrors the real client kwarg name.
        return _Query(self, [filter])

    def order_by(self, field):
        return _Query(self, [])

    def stream(self, timeout=None):
        # THE UNBOUNDED PATH (the OLD `self._root().stream()`): yields EVERY doc and counts each.
        # If list_names regressed to this, SCANNED explodes to the full collection size -> RED.
        for doc_id in sorted(self._docs):
            SCANNED["n"] += 1
            yield _Snapshot(doc_id, self._docs[doc_id])


class Client:
    def __init__(self):
        self._collections = {}

    def collection(self, name):
        return CollectionRef(self._collections.setdefault(name, {}))


def transactional(func):   # parity only — list_names/exists never enter a transaction.
    def _wrapped(transaction, *args, **kwargs):
        return func(transaction, *args, **kwargs)
    return _wrapped


# REGISTER the fake as `google.cloud.firestore` so cp_state_firestore._prefix_query's lazy
# `from google.cloud import firestore` resolves to THIS module — so FieldPath/FieldFilter are the
# fake's (the range query is built against the fake), exactly as the shipped code builds it against
# the real client. Without this the import would resolve to the real installed client and the
# fake's data would never see the bounded query. Mirrors the sitecustomize trick the sibling
# firestore gates use.
_fakemod = types.ModuleType("google.cloud.firestore")
_fakemod.Client = Client
_fakemod.FieldPath = FieldPath
_fakemod.FieldFilter = FieldFilter
_fakemod.transactional = transactional
for _n in ("google", "google.cloud"):
    if _n not in sys.modules:
        _pkg = types.ModuleType(_n)
        _pkg.__path__ = []
        sys.modules[_n] = _pkg
sys.modules["google.cloud.firestore"] = _fakemod
setattr(sys.modules["google.cloud"], "firestore", _fakemod)

import cp_state_firestore as fs

fake = Client()
backend = fs.FirestoreBackend(client=fake, root="heimdall_cp")

# Seed a LARGE collection: 5 teamq partitions (the target family) + 495 unrelated docs whose
# encoded ids ALL sort BELOW "teamq__" (jobs__, nonce__, audit__, ratelimit__), so a correct
# doc-id range excludes every one of them. Total = 500 docs.
TEAM_SLUGS = ["a1b2", "c3d4", "e5f6", "07a8", "b9c0"]   # sorts to: 07a8, a1b2, b9c0, c3d4, e5f6
for slug in TEAM_SLUGS:
    backend.put_record("teamq/%s/queue.json" % slug, {"queued": {"task:x": {"id": "task:x"}}})

NOISE_ROOTS = ["jobs", "nonce", "audit", "ratelimit", "presence"]
made = 0
i = 0
while made < 495:
    root = NOISE_ROOTS[i % len(NOISE_ROOTS)]
    backend.put_record("%s/doc%05d.json" % (root, i), {"v": i})
    made += 1
    i += 1

total_docs = sum(len(c) for c in fake._collections.values())

# THE PROBE: reset the scan counter, then enumerate the teamq partition names.
SCANNED["n"] = 0
names = backend.list_names("teamq")
scanned = SCANNED["n"]

expected = sorted(fs._encode_rel("teamq/%s/queue.json" % s).split("__")[1] for s in TEAM_SLUGS)
# list_names("teamq") returns the immediate child (the slug directory) of each partition.
got = list(names)

correct = got == expected
# BOUNDED: a correct range pushdown scans only the teamq family (5 docs), NOT the collection.
# Allow generous head-room (<= 50) but assert it is nowhere near the full 500-doc collection.
bounded = scanned <= 50 and scanned < total_docs

print("STATUS total_docs=%d scanned=%d bounded=%s correct=%s got=%r expected=%r"
      % (total_docs, scanned, bounded, correct, got, expected))
PYEOF

OUT="$(env -u HEIMDALL_STATE_BACKEND "$PY" "$DRIVER" 2>"$WORK/driver.err")"
echo "driver: $OUT"
[ -s "$WORK/driver.err" ] && { echo "  driver stderr:"; sed 's/^/    /' "$WORK/driver.err"; }
echo

TOTAL="$(printf '%s' "$OUT" | sed -n 's/.*total_docs=\([0-9]*\).*/\1/p')"
SCANNED_N="$(printf '%s' "$OUT" | sed -n 's/.*scanned=\([0-9]*\).*/\1/p')"
BOUNDED="$(printf '%s' "$OUT" | sed -n 's/.*bounded=\([A-Za-z]*\).*/\1/p')"
CORRECT="$(printf '%s' "$OUT" | sed -n 's/.*correct=\([A-Za-z]*\).*/\1/p')"

echo "(a) CORRECT — list_names returns exactly the teamq partition names on a large collection"
if [ "$CORRECT" = "True" ]; then
  ok "a1 list_names('teamq') returned exactly the 5 teamq partition slugs (correctness preserved)"
else
  bad "a1 list_names('teamq') returned the WRONG set (out: $OUT)"
fi
echo

echo "(b) BOUNDED — the enumeration scanned the teamq doc-id range, NOT the whole collection"
if [ "$BOUNDED" = "True" ]; then
  ok "b1 list_names scanned $SCANNED_N of $TOTAL docs — the doc-id range bounded the scan (not a full collection sweep)"
else
  bad "b1 list_names scanned $SCANNED_N of $TOTAL docs — it swept the whole collection (the bug #17 unbounded scan regressed)"
fi

echo
echo "============================================================"
echo "cp-firestore-bounded-listnames: $PASS passed, $FAIL failed"
echo "  (a) correct: list_names returns exactly the teamq partitions on a 500-doc collection"
echo "  (b) bounded: it scans only the '<rel_dir>__*' doc-id range, never the whole collection"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

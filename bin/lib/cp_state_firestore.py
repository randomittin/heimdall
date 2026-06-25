#!/usr/bin/env python3
# cp_state_firestore.py — the DURABLE StateBackend (Wave 2, the capstone).
#
# WHY THIS EXISTS (the durability gap it closes). cp_state.LocalBackend writes the
# 6 control-plane stores' NDJSON/keyed-JSON under ${HEIMDALL_HOME}/control-plane/.
# On Cloud Run that home is an EPHEMERAL per-instance disk: wiped on scale-to-zero,
# not shared across instances. So the §4 flight-fix durability claim ("a job survives
# a client disconnect AND a process restart, because state is the fold of an on-disk
# log") is FALSE on the deploy target — the log is on a disk that vanishes. This module
# implements FirestoreBackend: the SAME 7 StateBackend operations, but persisted in
# Google Cloud Firestore — an EXTERNAL store keyed to the Firestore project/database,
# NOT to ${HEIMDALL_HOME}. That external-ness IS the durability property: a fresh
# instance with a brand-new ephemeral home re-reads the same state from Firestore, so
# the state survives the home wipe. test/cp-durability.test.sh proves the contrast:
# LocalBackend loses state on a simulated scale-to-zero; FirestoreBackend survives it.
#
# THE rel→FIRESTORE MAPPING (the design — every `rel` is RELATIVE to
# ${HEIMDALL_HOME}/control-plane/, e.g. "jobs/job-abc.ndjson", "approvals/act-x.json").
# There is no filesystem; each `rel` maps to ONE document under a single root
# collection, the slashes of the rel encoded into a flat, reversible doc id:
#
#   root collection (default "heimdall_cp", env HEIMDALL_FIRESTORE_ROOT) holds one
#   "node" document per `rel`. The doc id is the rel with "/" → "__" (Firestore doc
#   ids may not contain "/"; "__" is not produced by any real rel segment, so the map
#   is reversible and collision-free). The node doc stores:
#
#     • For an append-only NDJSON rel (append_line / read_lines): the node doc is a
#       marker (kind="ndjson") and the actual lines live in an ordered SUBCOLLECTION
#       "lines" of that node doc — one doc per appended line, each carrying {seq, rec}.
#       `seq` is a monotonic per-rel counter (an atomic transaction increments a
#       "seq" field on the node doc, so concurrent appends across instances never
#       collide and read_lines returns STORE ORDER by ascending seq). This is the
#       Firestore-native equivalent of "append a line to a file"; store order is the
#       seq order, exactly as file order is append order.
#
#     • For a keyed JSON rel (put_record / get_record): the node doc itself holds the
#       record under field "rec" (kind="record"). put_record overwrites the doc whole
#       (atomic single-doc set — Firestore single-doc writes are atomic, the same
#       no-torn-read guarantee the LocalBackend gets from mktemp+os.replace).
#
#   list_names(rel_dir, suffix): the doc ids under "<rel_dir>/" are recovered by
#   querying every node doc whose id starts with the encoded "<rel_dir>__" prefix and
#   taking the segment after it (the basename), filtered by suffix, sorted — the same
#   sorted-basenames contract LocalBackend.list_names returns from os.listdir.
#
#   exists(rel): the node doc (or, for a dir rel, any node under its prefix) exists.
#
#   path(rel): RAISES BackendUnavailable — there is no local file for a Firestore-
#   backed rel, and the StateBackend contract explicitly permits a non-filesystem
#   backend to refuse path() while still serving read/write. secret-scan/gitleaks
#   cannot scan Firestore as a plaintext tree; that scan is a LocalBackend concern.
#
# LAZY IMPORT (the default-path guarantee). google.cloud.firestore is imported INSIDE
# _build_client (never at module import), so importing this module — or running the
# default "local" backend — NEVER requires the firestore dep. Only constructing a
# FirestoreBackend AND touching the store pulls the client in. If the dep is absent the
# error names exactly what to install. A test (or the durability gate when the client
# lib / emulator is unavailable) may inject a fake client via the `client=` constructor
# arg, exactly as the billing kill-switch test injects a FakeBillingClient — the
# SHIPPED code path uses the real google.cloud.firestore client; only a test double
# substitutes the external service.

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state  # the frozen StateBackend ABC + BackendUnavailable (never re-defined here).

# The Firestore root collection every control-plane node doc lives under. Overridable so
# multiple deployments / test runs can share one Firestore project without colliding.
FIRESTORE_ROOT_ENV = "HEIMDALL_FIRESTORE_ROOT"
DEFAULT_ROOT = "heimdall_cp"

# The Firestore project the store is keyed to (the durability anchor — NOT the home).
# Read live from the standard GCP env so the deploy wires it via env at deploy time.
FIRESTORE_PROJECT_ENV = "HEIMDALL_FIRESTORE_PROJECT"

# The Firestore DATABASE the store is keyed to. A doc's full address is
# (project, database, root-collection, doc-id); the database is the third coordinate and was
# previously PINNED to "(default)" because the client was built with no database= arg. If a
# deploy uses a NAMED database (not "(default)"), the writer and the reader MUST agree on it or
# they address different keyspaces — the same write/read-doc mismatch class the project/root
# coordinates have. Overridable via env so the deploy sets it once; unset -> the client's own
# default ("(default)"), the prior behavior, so existing deploys are byte-for-byte unchanged.
FIRESTORE_DATABASE_ENV = "HEIMDALL_FIRESTORE_DATABASE"

# The rel-segment separator. Firestore doc ids may not contain "/", so a rel's "/" is
# encoded to this token. Real rel segments are job ids / store names / "<id>.ndjson" /
# "<id>.json" — none contain "__", so the encoding is reversible and collision-free.
_SEP = "__"

# The ordered subcollection holding one NDJSON line per doc, and the field names used.
_LINES_SUBCOLLECTION = "lines"
_FIELD_SEQ = "seq"       # monotonic per-rel line ordinal (store order).
_FIELD_REC = "rec"       # the line record (append) / the keyed record (put_record).
_FIELD_KIND = "kind"     # "ndjson" | "record" — what a node doc represents.
_KIND_NDJSON = "ndjson"
_KIND_RECORD = "record"


def _encode_rel(rel):
    """Encode a store-relative path into a flat Firestore doc id (slashes → _SEP).
    Normalizes os.sep to "/" first so the mapping is identical on every platform."""
    norm = rel.replace(os.sep, "/").strip("/")
    return norm.replace("/", _SEP)


def _dir_prefix(rel_dir):
    """The encoded doc-id prefix every node directly under `rel_dir` shares. A node
    "jobs/job-abc.ndjson" under rel_dir "jobs" encodes to "jobs__job-abc.ndjson", so
    the prefix is "jobs__"; the basename is what follows it."""
    norm = rel_dir.replace(os.sep, "/").strip("/")
    return (norm.replace("/", _SEP) + _SEP) if norm else ""


class FirestoreBackend(cp_state.StateBackend):
    """The durable StateBackend: the 7 control-plane store operations, persisted in
    Google Cloud Firestore (external to ${HEIMDALL_HOME}). Construct with no args to use
    the real client (lazily imported, keyed to the GCP project / FIRESTORE_EMULATOR_HOST);
    pass `client=` a Firestore-client-shaped object to inject a test double (the billing
    kill-switch precedent). `root` overrides the root collection.

    PERSISTENCE IS KEYED TO THE FIRESTORE PROJECT/DATABASE, never to a home dir — that
    is the entire durability property: a fresh instance with a new ephemeral home reads
    the same state back from Firestore."""

    def __init__(self, *, client=None, root=None, project=None, database=None):
        # The home arg the factory threads through is intentionally IGNORED for storage:
        # a Firestore backend must NOT key persistence to a per-instance home, or it
        # would lose its durability property. We keep no home reference at all.
        self._injected_client = client
        self._client = client
        self._project = project if project is not None else os.environ.get(
            FIRESTORE_PROJECT_ENV
        )
        self._root_name = root if root is not None else (
            os.environ.get(FIRESTORE_ROOT_ENV) or DEFAULT_ROOT
        )
        # The DATABASE coordinate of the doc path (the third of (project, database, root, doc)).
        # Unset -> None -> the client's own default ("(default)"), preserving prior behavior; a
        # named db (set via env or arg) is honored so writer and reader address the SAME db.
        self._database = database if database is not None else (
            os.environ.get(FIRESTORE_DATABASE_ENV) or None
        )

    # ── the client seam (lazy real client OR an injected test double) ──────────────

    def _build_client(self):
        """Construct the real google.cloud.firestore client. Imported HERE (never at
        module load) so the default local path never needs the dep. Honors
        FIRESTORE_EMULATOR_HOST automatically (the google client routes to the emulator
        when that env is set). Raises BackendUnavailable naming the missing dep if the
        firestore lib is not installed — an honest boundary, never a silent degrade."""
        try:
            from google.cloud import firestore  # lazy: only when actually talking to FS.
        except ImportError as exc:
            raise cp_state.BackendUnavailable(
                "HEIMDALL_STATE_BACKEND=firestore needs the 'google-cloud-firestore' "
                "package, which is not installed (%s). Install it (see "
                "deploy/requirements-firestore.txt) or use the default 'local' backend."
                % exc
            )
        # Build the client honoring whichever of (project, database) is pinned. The database
        # is the third doc-path coordinate: a named db (HEIMDALL_FIRESTORE_DATABASE) must be
        # passed so the writer and reader address the SAME db; unset -> omit the kwarg -> the
        # client's "(default)" db, the prior behavior (existing deploys unchanged).
        kwargs = {}
        if self._project:
            kwargs["project"] = self._project
        if self._database:
            kwargs["database"] = self._database
        return firestore.Client(**kwargs)

    def _db(self):
        """The Firestore client, built once and cached. An injected test double is used
        verbatim; otherwise the real client is built lazily on first store touch."""
        if self._client is None:
            self._client = self._build_client()
        return self._client

    def _root(self):
        """The root collection reference holding every control-plane node doc."""
        return self._db().collection(self._root_name)

    def _node(self, rel):
        """The node document reference for a store-relative path."""
        return self._root().document(_encode_rel(rel))

    # ── append-only NDJSON (append_line / read_lines) ─────────────────────────────

    def append_line(self, rel, record, *, fsync=False):
        """Append ONE record as the next ordered line of the NDJSON rel. A transaction
        atomically reads+bumps the node doc's monotonic `seq` and writes a line doc
        {seq, rec} into the node's "lines" subcollection, so concurrent appends across
        instances never collide and read_lines returns STORE ORDER (ascending seq).
        `fsync` is accepted for interface parity but is a no-op: Firestore acks a write
        only once it is durably committed server-side (there is no client-side buffer to
        flush), so every append is already at least as durable as a local fsync. Returns
        True on a committed write, False on any backend error (the caller degrades,
        never crashes — the LocalBackend contract)."""
        try:
            db = self._db()
            node = self._node(rel)
            lines = node.collection(_LINES_SUBCOLLECTION)
            transaction = db.transaction()
            _append_in_transaction(transaction, node, lines, record)
            return True
        except Exception:  # noqa: BLE001 — degrade to a dropped line, never crash (§4).
            return False

    def read_lines(self, rel):
        """Stream the NDJSON rel's parsed line records in STORE ORDER (ascending seq).
        Tolerant: a non-dict line is skipped, an absent rel yields []. Read-only — the
        replay every fold runs. Mirrors LocalBackend.read_lines exactly, sourced from
        the ordered "lines" subcollection instead of a file."""
        out = []
        try:
            lines = self._node(rel).collection(_LINES_SUBCOLLECTION)
            for snap in lines.order_by(_FIELD_SEQ).stream():
                data = snap.to_dict() or {}
                rec = data.get(_FIELD_REC)
                if isinstance(rec, dict):
                    out.append(rec)
        except Exception:  # noqa: BLE001 — absent/unreadable → [] (tolerant, never raise).
            return out
        return out

    # ── keyed JSON record (put_record / get_record) ───────────────────────────────

    def put_record(self, rel, record):
        """ATOMICALLY write ONE keyed JSON record to the rel's node doc (a single-doc
        Firestore set is atomic — no reader ever sees a torn write, the same guarantee
        LocalBackend gets from mktemp+os.replace). Returns True on a committed write,
        False on any backend error."""
        try:
            self._node(rel).set({_FIELD_KIND: _KIND_RECORD, _FIELD_REC: record})
            return True
        except Exception:  # noqa: BLE001 — IO failure → False (the LocalBackend contract).
            return False

    def get_record(self, rel):
        """Read ONE keyed JSON record from the rel's node doc, or None if the doc is
        absent or its `rec` field is not a JSON object. Read-only; tolerant."""
        try:
            snap = self._node(rel).get()
            if not snap.exists:
                return None
            rec = (snap.to_dict() or {}).get(_FIELD_REC)
            return rec if isinstance(rec, dict) else None
        except Exception:  # noqa: BLE001 — absent/unreadable → None (tolerant).
            return None

    # ── enumeration / presence (list_names / exists) ──────────────────────────────

    def list_names(self, rel_dir, *, suffix=""):
        """The SORTED IMMEDIATE-CHILD names directly under `rel_dir`, filtered by
        `suffix`. Recovered by scanning the root collection for doc ids sharing the
        encoded "<rel_dir>__" prefix and taking the FIRST segment after it. This mirrors
        LocalBackend.list_names (which is os.listdir of the rel dir): the immediate child
        is a LEAF basename when the node sits directly under rel_dir, OR a synthetic
        SUBDIRECTORY name when the node is nested deeper (the dir has no doc of its own in
        Firestore's flat keyspace, so it is recovered from its descendants' doc ids).

        Why the FIRST segment, not "leaf or nothing": the observe store is NESTED —
        observe/<slug>/events.ndjson encodes to "observe__<slug>__events.ndjson". The
        immediate child of "observe/" is the directory "<slug>", exactly as os.listdir of
        a local observe/ returns the slug DIRECTORIES (not the deeper events.ndjson). A
        leaf-only rule returned [] here and the cross-dev dashboard silently showed zero
        instances under firestore (the firestore-only read-path defect this fixes).

        Suffix semantics match LocalBackend's os.listdir + endswith filter EXACTLY: a
        synthetic subdirectory name carries no file suffix, so a non-empty `suffix` never
        matches it (just as a local dir entry "<slug>" never ends with ".ndjson"); a
        suffix filter therefore selects only LEAF children, the flat-store case (jobs/
        approvals enumerate with suffix and get leaf doc names, unchanged).

        Limitation (pre-existing, not introduced here): a rel SEGMENT that itself contains
        the "__" separator (e.g. an instance slug derived from a HAID with two adjacent
        non-alnum chars) is ambiguous under this flat encoding for BOTH read/write and this
        enumeration. Production instance slugs derive single "_" runs from "haid:<id>"; the
        firestore encoding header documents the "no __ in a segment" assumption."""
        prefix = _dir_prefix(rel_dir)
        names = set()
        try:
            for snap in self._root().stream():
                doc_id = snap.id
                if not doc_id.startswith(prefix):
                    continue
                rest = doc_id[len(prefix):]
                if not rest:
                    continue
                # The immediate child under rel_dir: a leaf basename when the node sits
                # directly here, or a synthetic subdirectory name (first segment) when the
                # node is nested deeper. os.listdir(rel_dir) returns the SAME on local.
                head, sep, _tail = rest.partition(_SEP)
                if sep:
                    # rest had a deeper segment -> `head` is a subdirectory name. A dir
                    # carries no file suffix, so a suffix filter excludes it (matching the
                    # local os.listdir behavior where a dir entry never ends with .ndjson).
                    if suffix:
                        continue
                    names.add(head)
                    continue
                # `rest` is a leaf basename directly under rel_dir.
                if suffix and not rest.endswith(suffix):
                    continue
                names.add(rest)
        except Exception:  # noqa: BLE001 — absent/unreadable collection → [] (tolerant).
            return []
        return sorted(names)

    def exists(self, rel):
        """True iff a node exists at `rel` (a keyed/NDJSON doc) OR any node lives under
        `rel` as a dir prefix (so exists("jobs") is True once a job log exists, matching
        LocalBackend.exists on a store dir)."""
        try:
            if self._node(rel).get().exists:
                return True
            prefix = _dir_prefix(rel)
            if not prefix:
                return False
            for snap in self._root().stream():
                if snap.id.startswith(prefix):
                    return True
            return False
        except Exception:  # noqa: BLE001 — unreadable → False (tolerant).
            return False

    # ── path: refused (no local file for a Firestore-backed rel) ──────────────────

    def path(self, rel):
        """RAISES BackendUnavailable: a Firestore-backed rel has no local filesystem
        path. The StateBackend contract explicitly permits a non-filesystem backend to
        refuse path() while still serving every read/write method. Callers that need a
        real plaintext path (bin/secret-scan / *_path() accessors) are a LocalBackend
        concern; on Firestore there is nothing to point at."""
        raise cp_state.BackendUnavailable(
            "FirestoreBackend has no local filesystem path for %r — Firestore is an "
            "external store, not an on-disk tree. path() is a LocalBackend-only "
            "operation (the StateBackend contract permits refusing it here)." % rel
        )


def _append_in_transaction(transaction, node, lines, record):
    """Atomically: read the node doc's current `seq`, write the next line doc with that
    seq, and bump the node's seq. Decorated as a Firestore transaction so two instances
    appending concurrently get distinct, monotonically increasing seqs (store order is
    total). Kept module-level (not a method) so the @firestore.transactional decorator
    wraps a plain function as the library requires."""
    from google.cloud import firestore  # lazy — same dep boundary as _build_client.

    @firestore.transactional
    def _txn(txn):
        snap = node.get(transaction=txn)
        if snap.exists:
            cur = (snap.to_dict() or {}).get(_FIELD_SEQ)
            next_seq = (cur + 1) if isinstance(cur, int) else 0
        else:
            next_seq = 0
        # The new ordered line doc: id is the zero-padded seq so a raw doc-id sort and the
        # seq order agree; the authoritative order is still the explicit order_by(seq).
        line_ref = lines.document("%012d" % next_seq)
        txn.set(line_ref, {_FIELD_SEQ: next_seq, _FIELD_REC: record})
        txn.set(node, {_FIELD_KIND: _KIND_NDJSON, _FIELD_SEQ: next_seq}, merge=True)

    _txn(transaction)

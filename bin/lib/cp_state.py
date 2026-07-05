#!/usr/bin/env python3
# cp_state.py — the PLUGGABLE PERSISTENCE LAYER behind the control plane's 6 stores.
#
# WHY THIS EXISTS (the durability bug it fixes). The 6 control-plane stores
# (jobstore §4, audit §9, scheduler §6, approval §7, notify §8, observe-ingest §5)
# each write NDJSON / per-key JSON to ${HEIMDALL_HOME}/control-plane/. On a laptop
# that is durable. On Cloud Run it is NOT: the filesystem is ephemeral, wiped on
# scale-to-zero, and not shared across instances. So the §4 flight-fix durability
# claim ("a job survives a client disconnect AND a full process restart, because the
# state is the fold of an on-disk log") is FALSE on the deploy target — the log is on
# a disk that vanishes. This module puts a backend SEAM between every store and the
# bytes, so the local-NDJSON behavior is preserved verbatim for dev/test while a
# Wave-2 FirestoreBackend can make the same operations durable on Cloud Run.
#
# THE CONTRACT (StateBackend) — the MINIMAL union of what the 6 stores actually do,
# distilled from reading every store module (NOT speculative; each method is used by
# at least one real store):
#
#   append_line(rel, record, *, fsync=False) -> bool
#       Append ONE compact JSON line to an append-only NDJSON file. The bread-and-
#       butter of jobstore / audit / scheduler / notify / observe. `fsync=True` adds
#       os.fsync after flush — the jobstore's durability discipline; the other logs
#       flush only. Returns True on a durable write, False on any IO failure (the
#       stores degrade to a dropped line, never crash — preserved verbatim).
#
#   read_lines(rel) -> list[dict]
#       Stream the parsed JSON-object lines of an NDJSON file in STORE ORDER. Tolerant:
#       a bad line is skipped, an absent file yields []. The replay every fold runs.
#
#   put_record(rel, record) -> bool
#       ATOMICALLY write ONE keyed JSON record (mktemp + os.replace, indent=2,
#       sort_keys). The approval store's discipline (one .json file per action_id, one
#       writer, no torn reads). Returns True on success, False on IO failure.
#
#   get_record(rel) -> dict | None
#       Read ONE keyed JSON record written by put_record, or None if absent/corrupt.
#
#   list_names(rel_dir, *, suffix="") -> list[str]
#       The SORTED file/dir names directly under a store dir, optionally filtered by
#       `suffix` (e.g. ".ndjson" / ".json"). Tolerant of an absent dir ([]). The
#       enumeration jobstore (list_job_ids), approval (list_pending), scheduler (fold),
#       and observe (stored_instances) all build on.
#
#   exists(rel) -> bool
#       Does the store path exist? For the dashboard / secret-scan / status reads.
#
#   path(rel) -> str
#       The ABSOLUTE on-disk path of a store-relative path. The local backend exposes a
#       real filesystem path here (so bin/secret-scan can gitleaks-scan the store as
#       plaintext, and existing *_path() accessors keep returning a real path); a future
#       Firestore backend MAY raise BackendUnavailable for path() while still serving
#       the read/write methods, since there is no local file to point at.
#
# PATH MODEL — every `rel` is RELATIVE TO ${HEIMDALL_HOME}/control-plane/. A store
# passes "jobs/job-abc.ndjson", "audit/audit.ndjson", "approvals/act-x.json",
# "observe/<slug>/events.ndjson". The backend owns the home root + makedirs. This keeps
# the control-plane store namespace in ONE place and lets a non-filesystem backend map
# the same rel keys to its own collections.
#
# BYTE-IDENTITY (the LocalBackend guarantee) — LocalBackend reproduces the CURRENT
# on-disk behavior EXACTLY: same files, same json.dumps(sort_keys=True, separators=
# (",",":")) line shape for append_line, same json.dump(sort_keys=True, indent=2)
# atomic shape for put_record, same flush / fsync discipline, same store order on read,
# same sorted enumeration. A store migrated onto LocalBackend writes byte-identical
# files to its pre-migration self — proven by the cp suites staying green.
#
# THE FACTORY — get_backend() selects the impl from HEIMDALL_STATE_BACKEND
# (default "local"). "firestore" returns FirestoreBackend (cp_state_firestore, Wave 2),
# lazy-imported so the local path never needs the google-cloud-firestore dep. There is
# NEVER a silent fallback to local: a firestore selection whose client/dep cannot load
# raises BackendUnavailable loudly rather than degrading to the wrong store.
#
# stdlib-only (json/os) + issue_queue (REUSE heimdall_home) — mirrors every store's
# dependency shape, no third-party dep, self-hostable.

from __future__ import annotations

import abc
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import issue_queue  # REUSE heimdall_home() — the store root, never re-derived.

# The env var that selects the backend impl. "local" (default) is the byte-identical
# NDJSON-to-HEIMDALL_HOME behavior; "firestore" selects the durable FirestoreBackend.
BACKEND_ENV = "HEIMDALL_STATE_BACKEND"
BACKEND_LOCAL = "local"
BACKEND_FIRESTORE = "firestore"

# The single sub-root every control-plane store lives under (so `rel` paths are
# relative to ${HEIMDALL_HOME}/control-plane/). This is the one place the
# "control-plane" path segment is named — stores pass only their own sub-path.
CONTROL_PLANE_DIR = "control-plane"

# The optimistic-concurrency VERSION field carried INSIDE a keyed record for the
# compare-and-swap put_record_if path (the cross-instance atomic-claim seam behind the
# team-queue). A record with no rev is version 0; a successful CAS write persists the
# caller-supplied bumped rev. A LOCAL flock only serialises within one host — under
# max-instances>1 two hosts race, and this rev check is what makes the losing writer
# see False + re-read instead of clobbering the winner's claim (double-dispatch).
REV_FIELD = "rev"


def _rev_of(record):
    """The integer rev carried by a keyed record (REV_FIELD), or 0 when the record is
    absent / carries no (or a malformed) rev — the version compare-and-swap keys on."""
    if not isinstance(record, dict):
        return 0
    try:
        return int(record.get(REV_FIELD, 0) or 0)
    except (TypeError, ValueError):
        return 0


class BackendUnavailable(RuntimeError):
    """Raised when a selected backend cannot be initialized (e.g. HEIMDALL_STATE_BACKEND=
    firestore but the google-cloud-firestore client/dep is unavailable in the runtime),
    or when a backend cannot serve a method (e.g. path() on a non-filesystem backend). It
    is an honest failure boundary that names exactly what is missing, never a silent
    degrade to a different backend — the request fails loudly with the reason rather than writing to the wrong
    store."""


# ── the contract every store binds to (the frozen interface) ───────────────────


class StateBackend(abc.ABC):
    """The minimal persistence contract behind the 6 control-plane stores. Every `rel`
    argument is a path RELATIVE TO ${HEIMDALL_HOME}/control-plane/ (e.g.
    "jobs/job-abc.ndjson"). An impl maps those rel keys onto its own durable medium;
    LocalBackend maps them onto the filesystem byte-identically to the pre-migration
    stores. The contract is deliberately small — only operations a real store performs."""

    @abc.abstractmethod
    def append_line(self, rel, record, *, fsync=False):
        """Append ONE record as a compact JSON line to the append-only NDJSON file at
        `rel`, creating parent dirs as needed. The line MUST be
        json.dumps(record, sort_keys=True, separators=(",", ":")) + "\\n" (the shape
        every store's _append writes). `fsync=True` forces os.fsync after flush (the
        jobstore's durability discipline); fsync=False flushes only. Returns True on a
        durable write, False on any IO failure (the caller degrades, never crashes)."""

    @abc.abstractmethod
    def read_lines(self, rel):
        """Stream the parsed JSON-object lines of the NDJSON file at `rel` in STORE
        ORDER. Tolerant: a non-dict / unparseable line is skipped, an absent file
        yields []. Read-only — this is the replay every fold runs on each read."""

    @abc.abstractmethod
    def put_record(self, rel, record):
        """ATOMICALLY write ONE keyed JSON record to `rel` (the approval store's
        discipline: a temp file + os.replace so a reader never sees a torn write). The
        serialization MUST be json.dump(record, sort_keys=True, indent=2). Returns True
        on success, False on any IO failure."""

    @abc.abstractmethod
    def get_record(self, rel):
        """Read ONE keyed JSON record from `rel` (written by put_record), or None if the
        path is absent or the content is not a JSON object. Read-only; tolerant."""

    @abc.abstractmethod
    def put_record_if(self, rel, record, expected_rev):
        """ATOMIC compare-and-swap keyed write: persist `record` to `rel` ONLY IF the
        currently-stored record's REV_FIELD equals `expected_rev` (an absent record is
        version 0). Returns True on a committed write, False on a rev-conflict (a
        concurrent writer already advanced the version) or an IO failure. The caller
        sets record[REV_FIELD] to the bumped version BEFORE calling and, on False,
        re-reads + re-runs its mutation — the cross-instance optimistic-concurrency
        (CAS) discipline that makes a queued->in_flight claim safe under max-instances>1.
        A local flock only serialises within ONE host; this atomic rev check is what
        stops two Cloud Run instances both claiming the same task (double-dispatch)."""

    @abc.abstractmethod
    def list_names(self, rel_dir, *, suffix=""):
        """The SORTED names of entries directly under the store dir `rel_dir`,
        optionally filtered to those ending with `suffix` (e.g. ".ndjson"). Tolerant of
        an absent dir ([]). Names only (not full paths) — the caller strips the suffix
        / re-joins as it already does today."""

    @abc.abstractmethod
    def exists(self, rel):
        """True iff the store path `rel` exists (a file or a dir). For status / dashboard
        / secret-scan reads that check presence before reading."""

    @abc.abstractmethod
    def path(self, rel):
        """The ABSOLUTE on-disk path of `rel`. LocalBackend returns a real filesystem
        path (so secret-scan can scan the store and existing *_path() accessors keep
        their contract). A non-filesystem backend MAY raise BackendUnavailable here
        while still serving the read/write methods."""


# ── the LocalBackend: byte-identical NDJSON-to-HEIMDALL_HOME (the shipped path) ─


class LocalBackend(StateBackend):
    """The filesystem impl — byte-identical to the CURRENT control-plane store behavior.
    Resolves every `rel` under ${HEIMDALL_HOME}/control-plane/ (HEIMDALL_HOME read live
    via issue_queue.heimdall_home every call, so a test that pins HEIMDALL_HOME in a
    subprocess sees its own dir — the exact behavior the stores have today). `home`
    overrides the env when passed (the same `home=` arg every store accessor threads
    through), so a caller can pin the store root explicitly.

    Every method reproduces the pre-migration bytes: the compact-line append shape, the
    indent=2 atomic put shape, the flush/fsync discipline, the store read order, and the
    sorted enumeration. A migrated store on this backend writes identical files."""

    def __init__(self, home=None):
        self._home = home

    # the store root: ${home or HEIMDALL_HOME}/control-plane/ (resolved live).
    def _root(self):
        base = self._home if self._home else issue_queue.heimdall_home()
        return os.path.join(base, CONTROL_PLANE_DIR)

    def path(self, rel):
        """Absolute filesystem path under control-plane/ for a store-relative path."""
        return os.path.join(self._root(), rel)

    def exists(self, rel):
        return os.path.exists(self.path(rel))

    def append_line(self, rel, record, *, fsync=False):
        """One open('a') + one compact JSON line + flush (+ os.fsync when fsync=True).
        Byte-identical to every store's _append / _append_line. False on OSError."""
        try:
            abspath = self.path(rel)
            os.makedirs(os.path.dirname(abspath), exist_ok=True)
            line = json.dumps(record, sort_keys=True, separators=(",", ":"))
            with open(abspath, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
                fh.flush()
                if fsync:
                    os.fsync(fh.fileno())  # the §4 jobstore durability discipline.
            return True
        except OSError:
            return False

    def read_lines(self, rel):
        """Tolerant NDJSON scan in store order (skip bad lines, absent -> []). The exact
        _read_lines / read_records loop every store uses."""
        abspath = self.path(rel)
        out = []
        if not os.path.isfile(abspath):
            return out
        try:
            with open(abspath, "r", encoding="utf-8", errors="replace") as fh:
                for raw in fh:
                    line = raw.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except (ValueError, TypeError):
                        continue
                    if isinstance(obj, dict):
                        out.append(obj)
        except OSError:
            return out
        return out

    def put_record(self, rel, record):
        """Atomic keyed write: mktemp + json.dump(indent=2, sort_keys) + os.replace.
        Byte-identical to cp_approval._write_record. False on OSError."""
        try:
            abspath = self.path(rel)
            os.makedirs(os.path.dirname(abspath), exist_ok=True)
            tmp = abspath + ".tmp.%d" % os.getpid()
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(record, fh, sort_keys=True, indent=2)
                fh.flush()
            os.replace(tmp, abspath)
            return True
        except OSError:
            return False

    def get_record(self, rel):
        """Read one keyed JSON record, or None if absent/corrupt. Byte-for-byte the
        cp_approval.get read path."""
        abspath = self.path(rel)
        if not os.path.isfile(abspath):
            return None
        try:
            with open(abspath, "r", encoding="utf-8") as fh:
                obj = json.load(fh)
        except (OSError, ValueError):
            return None
        return obj if isinstance(obj, dict) else None

    def put_record_if(self, rel, record, expected_rev):
        """Compare-and-swap keyed write (the optimistic-concurrency seam): write `record`
        ONLY IF the currently-stored record's rev equals `expected_rev`. On a single host
        this is a correct CAS because the team-queue holds a per-partition flock across the
        whole read-mutate-write, so the get_record + put_record below run under mutual
        exclusion (no other same-host writer interleaves); the rev compare is the durable
        cross-check (and the guard when a caller does NOT hold the flock). Returns True on
        the committed write, False on a rev-conflict or an IO failure."""
        if _rev_of(self.get_record(rel)) != expected_rev:
            return False
        return self.put_record(rel, record)

    def list_names(self, rel_dir, *, suffix=""):
        """Sorted names directly under a store dir, filtered by suffix. Absent -> []."""
        abspath = self.path(rel_dir)
        out = []
        try:
            if not os.path.isdir(abspath):
                return out
            for name in sorted(os.listdir(abspath)):
                if suffix and not name.endswith(suffix):
                    continue
                out.append(name)
        except OSError:
            return out
        return out


# ── the factory: select the backend impl from the environment ──────────────────


def get_backend(home=None, backend=None):
    """Return the StateBackend impl selected by HEIMDALL_STATE_BACKEND (default
    "local"), or the explicit `backend` name when passed. `home` pins the store root
    (threaded through from the store's `home=` arg).

      "local"     -> LocalBackend (the byte-identical NDJSON-to-HEIMDALL_HOME path).
      "firestore" -> FirestoreBackend (Wave 2): the SAME 7 operations, persisted in
                     Google Cloud Firestore — an EXTERNAL store keyed to the Firestore
                     project/database, NOT to ${HEIMDALL_HOME}. That external-ness is
                     the durability property: a fresh Cloud Run instance with a wiped
                     ephemeral home reads the same state back. Imported LAZILY so a
                     local user never loads the firestore dep.

    An unknown backend name raises ValueError (fail closed — never guess a backend)."""
    name = (backend if backend is not None
            else os.environ.get(BACKEND_ENV) or BACKEND_LOCAL).strip().lower()
    if name == BACKEND_LOCAL:
        return LocalBackend(home=home)
    if name == BACKEND_FIRESTORE:
        # Lazy import: the firestore adapter (and its google-cloud-firestore dep) is
        # pulled in ONLY when the firestore backend is actually selected, so the default
        # local path never requires the dep. The home arg is intentionally not used for
        # storage by FirestoreBackend (persistence is keyed to the Firestore project,
        # not the home) — it is accepted for factory-signature parity only.
        import cp_state_firestore
        return cp_state_firestore.FirestoreBackend()
    raise ValueError(
        "unknown %s=%r (expected 'local' or 'firestore')" % (BACKEND_ENV, name)
    )

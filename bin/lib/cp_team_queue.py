#!/usr/bin/env python3
# cp_team_queue.py — the TEAM-PARTITIONED work queue for public multi-tenant Heimdall.
#
# WHY THIS EXISTS. The two shipped queues are SINGLE-TENANT: issue_queue.py (the
# issue-resolution loop's prioritized store) and work_queue.py (the local continuous-
# intake queue) each key their store to ONE ${HEIMDALL_HOME} — every caller shares the
# same pool. On the PUBLIC control plane that is a cross-tenant leak: team B could pick,
# list, or drain team A's queued work. This module is the ADDITIVE multi-tenant layer that
# closes that gap — each team's queued tasks live in their OWN partition (keyed by the
# non-secret team_id), and NO operation can reach across the partition boundary. The two
# single-tenant queues are left UNTOUCHED (this is a layer OVER their semantics, not an
# edit of them).
#
# WHAT IT REUSES (never re-implements, never edits issue_queue.py / work_queue.py):
#   • issue_queue.pick_order / issue_queue.score — the PRIORITIZATION + pick order
#     (severity-weighted, age-normalized, source-priority, deterministic id tie-break).
#     A team's pick() selects the highest-priority queued item with the SAME scorer the
#     single-tenant loop uses.
#   • issue_queue's DEDUP-BY-ID discipline — an id already known in ANY bucket is not
#     re-queued (idempotent enqueue), here scoped to the caller's partition.
#   • issue_queue's CLAIM-BEFORE-WORK guard — pick atomically MOVES the chosen id out of
#     the queued pool BEFORE returning it, so a second pick never re-selects it.
#   • cp_state.StateBackend (get_backend) — the SAME durable persistence seam every
#     control-plane store binds to: a keyed JSON record per partition (put_record /
#     get_record), byte-identical to disk on the local backend and Firestore-durable on
#     Cloud Run WITHOUT changing this module. (issue_queue.normalize is the issue-loop's
#     SOURCE mapper — github/slack/email native shapes — and is deliberately NOT used
#     here: a team task is OPAQUE DATA, not a connector item, so there is no source to
#     normalize; the reused logic is the score/pick/dedup/claim discipline.)
#   • telemetry's secret patterns — the no-secret-by-construction scrub (see _scrub_text).
#
# THE ISOLATION INVARIANT (enforced + tested). Every operation is scoped to EXACTLY ONE
# team_id partition. The team_id is a PATH SEGMENT of the store rel (teamq/<team_id>/…),
# so team A's record is a DIFFERENT keyed record than team B's — there is no function that
# takes two team_ids, and no read that enumerates across partitions. A task enqueued by
# team A is invisible to team B's pick/list/depth. A falsy/missing team_id FAILS CLOSED
# (ValueError) — never a silent unscoped op that could touch another partition.
#
# THE TASK TEXT IS DATA, NEVER EXECUTED. enqueue() stores the task text as a bounded,
# secret-scrubbed STRING. There is no code path from this module into dispatch / a handler
# / a shell — a queued task is a record, not a command. (Same control/data-plane line the
# rest of the control plane holds.)
#
# ATOMIC PICK. The read-select-write of a pick runs under an EXCLUSIVE per-partition flock
# (work_queue's no-double-pick discipline), so two concurrent picks in the SAME partition
# can never both claim one item — the second sees the first's claim and returns the next
# item (or None). The lock is a local mutex file per partition; the durable state is the
# keyed record on the StateBackend.
#
# stdlib-only (json/os/sys/hashlib/fcntl/datetime/builtins) + issue_queue (score/pick_order,
# heimdall_home) + cp_state (the persistence seam) + telemetry (the secret patterns) — the
# SAME dependency shape every other control-plane store has, no third-party dep, self-hostable.

from __future__ import annotations

import builtins
import datetime
import fcntl
import hashlib
import json  # noqa: F401 — kept for parity / structured-record debugging symmetry.
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state    # the pluggable persistence backend — the partition record is written /
                   # read THROUGH a StateBackend (get_backend), so the same atomic put /
                   # tolerant get becomes Firestore-durable on Cloud Run with no change here.
import issue_queue  # REUSE score / pick_order (the pick order) + heimdall_home + _to_int /
                   # SEVERITY_RANK — never edited, never re-implemented.
import telemetry   # REUSE the gitleaks secret patterns for the no-secret-by-construction scrub.

# ── store layout (a keyed record per team_id — the StateBackend rel namespace) ─────
#
# Every rel is RELATIVE to ${HEIMDALL_HOME}/control-plane/ (the StateBackend namespace):
# the team-queue root is "teamq/", one team's partition is "teamq/<team_id_slug>/", and its
# single queue record is "teamq/<team_id_slug>/queue.json". The team_id path segment IS the
# isolation boundary — a different team_id addresses a different record, so no op crosses it.

_TEAMQ_REL = "teamq"
_QUEUE_FILE = "queue.json"
_SCHEMA_VERSION = "1.0.0"

# A conservative slug bound for the team_id path segment (mirrors cp_presence._SLUG_MAX):
# keeps the store filesystem-safe, path-traversal-proof, and free of the "__" run the
# Firestore flat encoding reserves. team_id is already 32-hex (derive_team_id), so this is
# a defense-in-depth guard, not a reshape of a well-formed id.
_SLUG_MAX = 80

# The task-text size cap (chars). An oversized task is TRIMMED to this bound (not rejected)
# so a legitimate long prompt still enqueues while the store stays bounded per item.
_TASK_MAX_CHARS = 4000

# The redaction token a secret-shaped substring is replaced WITH (trim/redact, not reject —
# the requirement is "an oversized or secret-shaped task is trimmed/redacted").
_REDACTION = "[REDACTED]"

# ── BOUNDED RETRY (the never-permanently-consume-a-failed-task discipline) ──────────
#
# WHY THIS EXISTS (the live silent-drain incident, 2026-07-04). The gated drain used to
# complete() every picked task REGARDLESS of the dispatch outcome. When a dispatch was
# REFUSED (arm=None, no job created — e.g. the maintainer Job didn't exist yet, or an
# authz DENY), the task was still moved to `done`. Because the task id is content-
# deterministic (sha256 of the scrubbed text), the idempotent re-enqueue of the SAME text
# then no-oped — so the queue had NO pending task, and the warm per-minute tick correctly
# drained nothing, SILENTLY. The task was permanently lost to a terminal `done` state it
# never actually reached.
#
# THE FIX. A dispatch that did not durably kick off work must RETURN the task to the pick
# pool (retry), bounded by an `attempts` counter so a deterministically-failing task cannot
# loop forever — at the cap it moves to a terminal `dead` bucket (gave up, flagged, re-
# openable) rather than re-queuing endlessly. A fresh enqueue of the same text RE-OPENS a
# dead task (the operator asking to retry after fixing the root cause). A genuinely-
# dispatched `done` task is NEVER re-opened (idempotency preserved).
_MAX_ATTEMPTS_ENV = "HEIMDALL_RR_TASK_MAX_ATTEMPTS"
_MAX_ATTEMPTS_DEFAULT = 5


# ── small helpers ──────────────────────────────────────────────────────────────


def _require_team(team_id):
    """FAIL CLOSED on a missing/blank team_id. Every public op calls this FIRST: a falsy
    team_id is refused with a ValueError rather than silently running an UNSCOPED op that
    could touch another partition. There is no default-partition fallback here — an
    unscoped queue op is a cross-tenant hazard, so it is never allowed."""
    if not team_id or not str(team_id).strip():
        raise ValueError(
            "team_id is required (fail-closed): a queue op MUST be scoped to a team "
            "partition — refusing an unscoped op that could cross tenants")
    return str(team_id)


def _slug(value):
    """A filesystem-safe, bounded path slug for a team_id (mirrors cp_presence._slug): keep
    [A-Za-z0-9._-], map every other char to '_', strip edge separators. Returns 'unknown'
    for an empty value (guarded upstream by _require_team). Path-traversal-proof — a '../'
    can never survive (both '/' and '.' runs collapse to a bounded single-segment slug)."""
    raw = str(value or "").strip()
    if not raw:
        return "unknown"
    out = []
    for ch in raw[:_SLUG_MAX]:
        out.append(ch if (ch.isalnum() or ch in "._-") else "_")
    slug = "".join(out).strip("._-")
    return slug or "unknown"


def _team_rel(team_id):
    """The store-relative dir of one team's partition: teamq/<team_id_slug>/."""
    return os.path.join(_TEAMQ_REL, _slug(team_id))


def _queue_rel(team_id):
    """The store-relative path of one team's queue record: teamq/<team_id_slug>/queue.json."""
    return os.path.join(_team_rel(team_id), _QUEUE_FILE)


def _now_iso():
    """Current UTC time as a second-precision ISO-8601 string (the record timestamps)."""
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


def _max_attempts(explicit=None):
    """The bounded-retry cap: an explicit positive `explicit` wins; else
    HEIMDALL_RR_TASK_MAX_ATTEMPTS; else _MAX_ATTEMPTS_DEFAULT. A malformed / non-positive
    env value falls back to the default (never crashes a retry)."""
    if isinstance(explicit, int) and explicit > 0:
        return explicit
    raw = os.environ.get(_MAX_ATTEMPTS_ENV)
    parsed = issue_queue._to_int(raw) if raw else 0
    return parsed if parsed > 0 else _MAX_ATTEMPTS_DEFAULT


def _backend(home=None):
    """The StateBackend for the team-queue store (HEIMDALL_STATE_BACKEND, default local).
    `home` pins the store root exactly as every control-plane accessor's `home=` arg does —
    threaded straight through (the backend owns heimdall_home resolution). Mirrors
    cp_presence._backend / cp_auth._backend verbatim."""
    return cp_state.get_backend(home=home)


# ── the no-secret-by-construction scrub (REUSE telemetry's secret patterns) ────────


def _scrub_text(text):
    """Bound + redact a task text so a secret can NEVER enter a queued record (the
    requirement: "trim/redact", not all-or-nothing reject — a long legitimate task must
    still enqueue). Two steps:

      1. REDACT every secret-shaped substring by replacing it with [REDACTED], REUSING
         telemetry's gitleaks high-signal patterns + the assigned-credential shape (the
         SAME families telemetry._scrub rejects on). A key=opaque-RHS run, a GitHub PAT, an
         AWS key id, a Stripe/Slack token, a PEM header, a JWT — each is stripped out.
      2. TRIM to _TASK_MAX_CHARS (bound the record size). Trimming AFTER redaction means a
         secret can never survive by hiding past the cap.

    Returns the cleaned string (never None) — an all-secret task collapses to a redacted
    marker, a huge task is trimmed, but a task always yields a storable bounded string."""
    s = str(text if text is not None else "")
    # 1) redact the generic assigned-credential shape first (token=<opaque> etc.), then
    #    every named vendor pattern. re.sub replaces the WHOLE match with the marker.
    s = telemetry._ASSIGNED_OPAQUE.sub(_REDACTION, s)
    for rx in telemetry._SECRET_PATTERNS:
        s = rx.sub(_REDACTION, s)
    # 2) bound the size (trim, never reject).
    if len(s) > _TASK_MAX_CHARS:
        s = s[:_TASK_MAX_CHARS]
    return s


def _task_text(task):
    """Extract the raw task text from `task`: a plain string is the text; a dict supplies it
    under 'text' | 'prompt' | 'body' (the first present, in that order). Anything else is
    coerced with str(). The text is DATA — it is scrubbed + stored, never executed."""
    if isinstance(task, str):
        return task
    if isinstance(task, dict):
        for key in ("text", "prompt", "body"):
            if task.get(key) is not None:
                return str(task.get(key))
        return ""
    return str(task if task is not None else "")


def _task_id(scrubbed_text, team_id):
    """The idempotency key for a task within a partition (issue_queue's dedup-by-id, applied
    to opaque task text): 'task:' + sha256(scrubbed_text NUL team_id)[:32]. Hashing the
    ALREADY-SCRUBBED text means two enqueues that differ ONLY in a redacted secret dedup to
    the same id (the stored data is identical). team_id is folded in so an id is inherently
    partition-scoped."""
    h = hashlib.sha256()
    h.update(scrubbed_text.encode("utf-8"))
    h.update(b"\x00")
    h.update(str(team_id).encode("utf-8"))
    return "task:" + h.hexdigest()[:32]


def _priority_signal(task):
    """The issue_queue priority_signal for a task, so issue_queue.pick_order scores it with
    the SAME weights the single-tenant loop uses. A dict task may carry 'severity' (one of
    issue_queue.SEVERITY_RANK — else None, never guessed) and 'priority' (an int source
    boost). A plain-string task has no signals (severity None, source_priority 0) and is
    ordered by age + id. age_seconds is 0 at enqueue (the record carries created_at)."""
    severity = None
    source_priority = 0
    if isinstance(task, dict):
        sev = task.get("severity")
        if sev in issue_queue.SEVERITY_RANK:
            severity = sev
        source_priority = issue_queue._to_int(task.get("priority", 0))
    return {"severity": severity, "age_seconds": 0, "source_priority": source_priority}


# ── the per-partition exclusive lock (work_queue's no-double-pick discipline) ──────


def _lock_path(team_id, home=None):
    """The local mutex file for a team's partition:
    ${home or HEIMDALL_HOME}/control-plane/teamq/<team_id_slug>/.lock. A pure LOCAL file
    (never a StateBackend serving path — so no backend.path() call that FirestoreBackend
    would refuse): the durable state is the keyed record; this file only SERIALIZES the
    read-select-write of a pick so two concurrent picks in one partition can never both
    claim one item. Created on demand."""
    base = home if home else issue_queue.heimdall_home()
    partition_dir = os.path.join(base, cp_state.CONTROL_PLANE_DIR, _team_rel(team_id))
    os.makedirs(partition_dir, exist_ok=True)
    return os.path.join(partition_dir, ".lock")


class _PartitionLock:
    """An exclusive flock over one partition's mutex file — held across the whole read-
    modify-write of a mutating op so concurrent processes serialize (claim-before-work).
    Mirrors work_queue._FlockCtx exactly."""

    def __init__(self, team_id, home=None):
        self.path = _lock_path(team_id, home)
        self._fh = None

    def __enter__(self):
        self._fh = open(self.path, "w")
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self._fh, fcntl.LOCK_UN)
        finally:
            self._fh.close()
        return False


# ── the partition record (buckets, mirrors issue_queue's store shape) ──────────────


def _empty_store(team_id):
    """An empty partition record. Buckets: queued (the pick pool, dedup by id), in_flight
    (claimed by a pick, out of the pick set), done (dispatched with a verdict), dead (retries
    exhausted — a terminal bounded-retry state, re-openable by a fresh enqueue)."""
    return {
        "schema_version": _SCHEMA_VERSION,
        "team_id": team_id,
        "queued": {},
        "in_flight": {},
        "done": {},
        "dead": {},
    }


def _load(backend, team_id):
    """Read a team's partition record (get_record), healing a partial/absent record to the
    empty shape without losing data. team_id is pinned to the caller's value on every read
    (never trusted from the stored blob) — the read is scoped to EXACTLY this partition."""
    rec = backend.get_record(_queue_rel(team_id))
    if not isinstance(rec, dict):
        return _empty_store(team_id)
    # MIGRATE forward: a record written before the bounded-retry design lacks the `dead`
    # bucket. setdefault-ing every bucket (incl. `dead`) heals a partial/old partition to
    # the current shape WITHOUT a KeyError and without dropping data — an old queue keeps
    # its queued/in_flight/done items and simply gains an empty dead:{}.
    for bucket in ("queued", "in_flight", "done", "dead"):
        if not isinstance(rec.get(bucket), dict):
            rec[bucket] = {}
    rec.setdefault("schema_version", _SCHEMA_VERSION)
    rec["team_id"] = team_id
    return rec


def _save(backend, team_id, store):
    """Atomically write a team's partition record (put_record — tmp+os.replace, sorted keys).
    Returns True on a durable write, False on IO failure."""
    return backend.put_record(_queue_rel(team_id), store)


# ── THE PUBLIC API (every op scoped to the caller's team_id partition) ─────────────


def enqueue(team_id, task, *, home=None):
    """ADD a scrubbed, bounded task to THIS team's partition (idempotent dedup within the
    partition). `team_id` is the caller's verified partition handle (fail-closed if blank);
    `task` is a string OR a dict ({text|prompt|body, severity?, priority?}). The task text
    is DATA — scrubbed (secret-redacted) + trimmed (<=_TASK_MAX_CHARS) — and NEVER executed.

    Idempotent: a task whose scrubbed text hashes to an id already known in the queued /
    in_flight / done buckets is NOT re-queued — a duplicate enqueue returns added=False. A
    successfully-DISPATCHED (done) task is therefore NEVER re-opened (idempotency preserved).
    Held under the partition lock so two identical concurrent enqueues cannot both win.

    RE-OPEN A DEAD TASK: if the id is in the terminal `dead` bucket (bounded retry exhausted),
    a fresh enqueue of the same text REVIVES it — moves it back to `queued`, resets attempts
    to 0, and returns added=True + reopened=True. This is the operator's "I fixed the root
    cause, retry it" path: a task that gave up is re-drivable by re-submitting the same text.

    Returns {ok, id, added, team_id[, reopened]}. added=False means a dedup no-op (ok is still
    True). An empty task (no text after scrub) is refused: {ok: False, reason: 'empty_task'}."""
    team_id = _require_team(team_id)
    scrubbed = _scrub_text(_task_text(task))
    if not scrubbed.strip():
        return {"ok": False, "reason": "empty_task", "team_id": team_id}
    tid = _task_id(scrubbed, team_id)
    item = {
        "id": tid,
        "team_id": team_id,
        "text": scrubbed,
        "priority_signal": _priority_signal(task),
        "created_at": _now_iso(),
        "attempts": 0,
    }
    backend = _backend(home)
    with _PartitionLock(team_id, home):
        store = _load(backend, team_id)
        # RE-OPEN: a fresh enqueue of a dead task's text revives it (attempts reset to 0).
        if tid in store["dead"]:
            store["dead"].pop(tid, None)
            store["queued"][tid] = item
            ok = _save(backend, team_id, store)
            if not ok:
                return {"ok": False, "reason": "io_error", "id": tid, "team_id": team_id}
            return {"ok": True, "id": tid, "added": True, "reopened": True,
                    "team_id": team_id}
        if tid in store["queued"] or tid in store["in_flight"] or tid in store["done"]:
            return {"ok": True, "id": tid, "added": False, "team_id": team_id}
        store["queued"][tid] = item
        ok = _save(backend, team_id, store)
        if not ok:
            return {"ok": False, "reason": "io_error", "id": tid, "team_id": team_id}
        return {"ok": True, "id": tid, "added": True, "team_id": team_id}


def pick(team_id, *, home=None, cfg=None):
    """ATOMICALLY CLAIM the highest-priority queued item from ONLY this team's partition.
    Uses issue_queue.pick_order (the single-tenant scorer) to select, then MOVES the chosen
    id out of `queued` into `in_flight` BEFORE returning it (claim-before-work). The whole
    read-select-write runs under the partition's exclusive lock, so a second concurrent
    pick sees the first's claim and never double-claims — it returns the NEXT item or None.

    `cfg` optionally supplies issue_queue prioritization weights / source_priority. Returns
    the claimed item dict, or None when the partition's queue is empty. A pick can ONLY ever
    see this team_id's partition — team B's items are in a different record and are
    unreachable here."""
    team_id = _require_team(team_id)
    backend = _backend(home)
    with _PartitionLock(team_id, home):
        store = _load(backend, team_id)
        queued = builtins.list(store["queued"].values())
        if not queued:
            return None
        chosen = issue_queue.pick_order(queued, cfg or {})[0]
        cid = chosen["id"]
        del store["queued"][cid]
        store["in_flight"][cid] = {"since": _now_iso(), "item": chosen}
        _save(backend, team_id, store)
        return chosen


def complete(team_id, id, verdict, *, home=None):
    """RECORD a verdict for an item and move it to `done`, scoped to THIS partition. Pops the
    id from in_flight (the normal path) or from queued (completing an unclaimed item); a
    verdict is scrubbed (bounded/secret-rejected via telemetry._scrub). An id unknown in this
    partition returns {ok: False, reason: 'unknown_id'} — you cannot complete an id that is
    not in YOUR partition, so team B can never complete team A's item.

    Returns {ok, id, verdict, team_id} on success."""
    team_id = _require_team(team_id)
    if not id:
        return {"ok": False, "reason": "no_id", "team_id": team_id}
    backend = _backend(home)
    with _PartitionLock(team_id, home):
        store = _load(backend, team_id)
        rec = store["in_flight"].pop(id, None)
        item = rec.get("item") if isinstance(rec, dict) else None
        if item is None:
            item = store["queued"].pop(id, None)
        if item is None and id not in store["done"]:
            return {"ok": False, "reason": "unknown_id", "id": id, "team_id": team_id}
        if item is None:
            item = store["done"].get(id, {}).get("item")
        clean_verdict = telemetry._scrub(verdict) if verdict is not None else None
        store["done"][id] = {"verdict": clean_verdict, "at": _now_iso(), "item": item}
        ok = _save(backend, team_id, store)
        if not ok:
            return {"ok": False, "reason": "io_error", "id": id, "team_id": team_id}
        return {"ok": True, "id": id, "verdict": clean_verdict, "team_id": team_id}


def retry(team_id, id, reason=None, *, max_attempts=None, home=None):
    """RETURN a task whose dispatch did NOT durably start work to the pick pool, bounded by an
    `attempts` counter — the never-permanently-consume-a-failed-task discipline (the silent-
    drain fix). Scoped to THIS partition.

    Pops the id from in_flight (the normal path — the task was picked, then its dispatch was
    refused) or from queued, INCREMENTS its attempts, then:
      • attempts < cap  -> returns it to `queued` (re-pickable next tick), state='queued';
      • attempts >= cap -> moves it to the terminal `dead` bucket (bounded — a
        deterministically-failing task cannot re-queue forever), state='dead'. A dead task is
        re-openable ONLY by a fresh enqueue of the same text (the operator's explicit retry).

    The cap is _max_attempts(max_attempts) — an explicit positive arg, else
    HEIMDALL_RR_TASK_MAX_ATTEMPTS, else the default. `reason` is scrubbed (never stores a
    secret) and kept as the last error for observability. An id unknown in this partition
    returns {ok: False, reason: 'unknown_id'} — you cannot retry another team's task.

    Returns {ok, id, state, attempts, team_id[, error]}."""
    team_id = _require_team(team_id)
    if not id:
        return {"ok": False, "reason": "no_id", "team_id": team_id}
    cap = _max_attempts(max_attempts)
    clean_error = telemetry._scrub(reason) if reason is not None else None
    backend = _backend(home)
    with _PartitionLock(team_id, home):
        store = _load(backend, team_id)
        rec = store["in_flight"].pop(id, None)
        item = rec.get("item") if isinstance(rec, dict) else None
        if item is None:
            item = store["queued"].pop(id, None)
        if not isinstance(item, dict):
            return {"ok": False, "reason": "unknown_id", "id": id, "team_id": team_id}
        attempts = issue_queue._to_int(item.get("attempts", 0)) + 1
        item["attempts"] = attempts
        item["last_error"] = clean_error
        if attempts >= cap:
            store["dead"][id] = {"item": item, "reason": clean_error,
                                 "attempts": attempts, "at": _now_iso()}
            state = "dead"
        else:
            item["retry_at"] = _now_iso()
            store["queued"][id] = item
            state = "queued"
        ok = _save(backend, team_id, store)
        if not ok:
            return {"ok": False, "reason": "io_error", "id": id, "team_id": team_id}
        return {"ok": True, "id": id, "state": state, "attempts": attempts,
                "error": clean_error, "team_id": team_id}


def requeue(team_id, id, *, home=None):
    """DEFER a claimed (in_flight) task back to `queued` WITHOUT burning an attempt — for a
    non-failure re-drive (e.g. the drain wrapped around to a task it already handled this pass,
    or a benign back-pressure defer). Distinct from retry(), which is the FAILURE path that
    increments attempts toward the dead cap. Scoped to THIS partition.

    Pops the id from in_flight and returns it to queued unchanged. An id already in queued is a
    no-op success. An id unknown in this partition returns {ok: False, reason: 'unknown_id'}.

    Returns {ok, id, state, team_id}."""
    team_id = _require_team(team_id)
    if not id:
        return {"ok": False, "reason": "no_id", "team_id": team_id}
    backend = _backend(home)
    with _PartitionLock(team_id, home):
        store = _load(backend, team_id)
        rec = store["in_flight"].pop(id, None)
        item = rec.get("item") if isinstance(rec, dict) else None
        if item is None:
            if id in store["queued"]:
                return {"ok": True, "id": id, "state": "queued", "team_id": team_id}
            return {"ok": False, "reason": "unknown_id", "id": id, "team_id": team_id}
        store["queued"][id] = item
        ok = _save(backend, team_id, store)
        if not ok:
            return {"ok": False, "reason": "io_error", "id": id, "team_id": team_id}
        return {"ok": True, "id": id, "state": "queued", "team_id": team_id}


def list(team_id, *, home=None, cfg=None):  # noqa: A001 — the public API name is `list`.
    """LIST every item in THIS team's partition, queued ones first in pick order (reusing
    issue_queue.pick_order), then in_flight, then done, then dead. Each row is
    {id, state, item[, verdict|reason]}. Read-only. A list can ONLY ever enumerate this
    team_id's partition — team B's items live in a different record and never appear here."""
    team_id = _require_team(team_id)
    store = _load(_backend(home), team_id)
    rows = []
    for it in issue_queue.pick_order(builtins.list(store["queued"].values()), cfg or {}):
        rows.append({"id": it["id"], "state": "queued", "item": it})
    for cid, rec in store["in_flight"].items():
        rows.append({"id": cid, "state": "in_flight",
                     "item": rec.get("item") if isinstance(rec, dict) else None})
    for cid, rec in store["done"].items():
        rows.append({"id": cid, "state": "done",
                     "item": rec.get("item") if isinstance(rec, dict) else None,
                     "verdict": rec.get("verdict") if isinstance(rec, dict) else None})
    for cid, rec in store["dead"].items():
        rows.append({"id": cid, "state": "dead",
                     "item": rec.get("item") if isinstance(rec, dict) else None,
                     "reason": rec.get("reason") if isinstance(rec, dict) else None})
    return rows


def depth(team_id, *, home=None):
    """The number of QUEUED (unclaimed) items in THIS team's partition — the per-team backlog
    depth. Read-only, scoped to this team_id partition (never counts another team's items)."""
    team_id = _require_team(team_id)
    store = _load(_backend(home), team_id)
    return len(store["queued"])

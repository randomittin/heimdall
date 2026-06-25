#!/usr/bin/env python3
# cp_audit.py — piece (a) of the Heimdall control plane: THE AUDIT LOG (§9).
#
# DESIGN DOSSIER §9 (authoritative). Append-only, searchable, exportable. Every
# dispatch (incl. REFUSALS §1), every job transition (§4), every approval/override
# (§7), every auth failure (§3) writes ONE row. This is the security record AND the
# 3am-debug record.
#
# STORE — NDJSON at ${HEIMDALL_HOME}/control-plane/audit/audit.ndjson. NDJSON (not
# SQLite) so `bin/secret-scan` (gitleaks) scans it natively as plaintext — the
# secret gate stays armed on the store, mirroring telemetry.py's choice (§9 L155).
# The bytes are written THROUGH a StateBackend (cp_state, Wave 0): the same compact
# flush-only NDJSON append + tolerant store-ordered scan, byte-identical on the local
# backend, durable on Cloud Run when the Wave-2 FirestoreBackend lands — without
# editing this store. The backend owns the home root + makedirs; the audit no longer
# re-derives heimdall_home itself (the rel key "audit/audit.ndjson" resolves there).
#
# NO-SECRET-BY-CONSTRUCTION — REUSE telemetry._scrub verbatim (never re-derive the
# secret discipline). The `detail` field passes through _scrub: bounded to <=120
# chars AND rejected (dropped) if it matches a gitleaks high-signal pattern or looks
# like an assigned credential. params-SHAPE is recorded (the param NAMES + their
# value TYPES), NEVER the param VALUES — a value that could be a secret never enters
# the store by construction. actor_haid is a deterministic identity name (no key
# material), safe to record verbatim.
#
# THE INTERFACE pieces (b)-(f) BIND to (stable; they import, never edit):
#   write(event, *, actor_haid, ...)      — append one audit row, returns the audit_id.
#   record_dispatch / record_refusal      — the §1 convenience writers (the cardinal pair).
#   search(...)                           — filter rows by actor_haid / event / time range.
#   export(...)                           — stream the store back as NDJSON text.
#   AUDIT_EVENTS                           — the pinned event-name enum.
#
# stdlib-only (json/os/uuid/datetime) + telemetry (sibling) — minimal self-host deps.

from __future__ import annotations

import datetime
import json
import os
import sys
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state     # the pluggable persistence backend (Wave 0). The audit log writes
                   # its append-only NDJSON THROUGH a StateBackend (get_backend) so the
                   # same flush-only append + tolerant scan becomes durable on Cloud Run
                   # (Wave 2 FirestoreBackend) WITHOUT editing this store. The local
                   # backend is byte-identical to the prior NDJSON-to-HEIMDALL_HOME path,
                   # and it owns heimdall_home() resolution (the audit no longer needs
                   # issue_queue directly — the backend re-derives the runtime home).
import telemetry     # REUSE _scrub — the no-secret-by-construction discipline (§9).

# ── schema constants (the pinned audit contract — §9) ─────────────────────────

SCHEMA_VERSION = "1.0.0"

# The audit event ENUM (§9). write() REJECTS any other event name (returns None,
# nothing written) — the audit schema is closed, like telemetry's EVENT_TYPES.
AUDIT_EVENTS = (
    "dispatch",          # an allowlisted action was accepted + dispatched.
    "dispatch_refused",  # a dispatch was REFUSED (unknown type / bad param / smuggle).
    "job_state",         # a job state transition (§4).
    "approval",          # an approval decision landed (approved/rejected) (§7).
    "override",          # an owner forced a gate (§7) — authority exercised, audited.
    "ingest",            # a telemetry batch was ingested (§5).
    "auth_fail",         # an auth verification failed (unsigned/bad-sig/revoked) (§3).
)

# The decision vocabulary for approval/override rows (§7).
AUDIT_DECISIONS = ("approved", "rejected", "overridden", None)

# The outcome vocabulary (§9).
AUDIT_OUTCOMES = ("ok", "refused", "error")

# detail is a bounded SHAPE summary — reuse telemetry's bound + scrubber directly.
_DETAIL_MAX = telemetry._SCRUB_MAX  # 120 (single source of truth for the bound).


# ── store location + backend (the persistence SEAM — Wave 0) ───────────────────
#
# The audit log addresses its store by paths RELATIVE to ${HEIMDALL_HOME}/control-plane/
# (the StateBackend rel namespace): the audit dir is "audit/", the log is
# "audit/audit.ndjson". The backend owns the home root + makedirs + the byte shape;
# audit_dir/audit_path remain the public absolute-path accessors (now derived from the
# backend's path(), so they stay byte-identical to the prior layout — and secret-scan
# keeps a real filesystem path to gitleaks-scan).

# the rel sub-dir the audit log lives under, within control-plane/.
_AUDIT_REL_DIR = "audit"

# the store-relative path of the append-only audit log: audit/audit.ndjson.
_AUDIT_REL = os.path.join(_AUDIT_REL_DIR, "audit.ndjson")


def _backend(home=None):
    """The StateBackend for the audit log (HEIMDALL_STATE_BACKEND, default local). `home`
    pins the store root exactly as every audit accessor's `home=` arg always has."""
    return cp_state.get_backend(home=home)


def audit_dir(home=None):
    """The audit store dir: ${HEIMDALL_HOME}/control-plane/audit/ (the backend's absolute
    path for the audit rel-dir — unchanged on the local backend)."""
    return _backend(home).path(_AUDIT_REL_DIR)


def audit_path(home=None):
    """Absolute path to the append-only audit log (the backend's absolute path for the
    audit/audit.ndjson rel key — unchanged on the local backend)."""
    return _backend(home).path(_AUDIT_REL)


def _now_iso():
    """Current UTC time as a second-precision ISO-8601 string (§9 ts field)."""
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


# ── the params-SHAPE extractor (record the SHAPE, NEVER the values — §9) ───────


def params_shape(params):
    """Reduce a params dict to its SHAPE: {param_name: value_type_tag}. The audit
    records WHICH params an action carried + their TYPES, NEVER their VALUES. A
    value that could be a secret (or simply user data) never enters the audit by
    construction — only its name + type does. Returns {} for a non-dict.

    e.g. {"task_id": "build-x", "suite": "unit"} -> {"task_id": "str", "suite": "str"}
    The value strings 'build-x'/'unit' are DROPPED — only the shape survives."""
    if not isinstance(params, dict):
        return {}
    out = {}
    for k, v in params.items():
        key = str(k)[:_DETAIL_MAX]
        if isinstance(v, bool):
            out[key] = "bool"
        elif isinstance(v, int):
            out[key] = "int"
        elif isinstance(v, float):
            out[key] = "float"
        elif isinstance(v, str):
            out[key] = "str"
        elif isinstance(v, (list, tuple)):
            out[key] = "list"
        elif isinstance(v, dict):
            out[key] = "object"
        elif v is None:
            out[key] = "null"
        else:
            out[key] = "other"
    return out


def _scrub_detail(detail):
    """A free-ish `detail` SHAPE note passes through telemetry._scrub: bounded +
    secret-rejected. A rejected/over-long value yields None (the field is dropped) —
    never a truncated secret. Reuses the substrate's secret discipline verbatim."""
    if detail is None:
        return None
    cleaned = telemetry._scrub(str(detail))
    return cleaned  # None when rejected -> the row simply omits detail.


# ── the audit writer (the ONE append API — §9) ─────────────────────────────────


def build_record(event, *, actor_haid=None, action_type=None, action_id=None,
                 job_id=None, decision=None, outcome=None, params=None, detail=None):
    """Assemble ONE schema-validated, secret-scrubbed audit record (§9). Returns the
    record dict, or None when `event` is not in AUDIT_EVENTS (an invalid event is
    dropped, never written). Pure — no IO.

    params is reduced to params_shape (names+types only, NEVER values). detail is
    scrubbed (bounded + secret-rejected). actor_haid is a deterministic identity
    name (no key material) — safe verbatim, but still bounded."""
    if event not in AUDIT_EVENTS:
        return None

    def _tag(v):
        """A short bounded identity/id tag — scrubbed so no value smuggles a payload
        through actor_haid/action_id/job_id."""
        if v is None:
            return None
        return telemetry._scrub(str(v))

    dec = decision if decision in AUDIT_DECISIONS else None
    out = outcome if outcome in AUDIT_OUTCOMES else None
    return {
        "schema_version": SCHEMA_VERSION,
        "audit_id": "aud-" + uuid.uuid4().hex,
        "ts": _now_iso(),
        "actor_haid": _tag(actor_haid),
        "event": event,
        "action_type": _tag(action_type),
        "action_id": _tag(action_id),
        "job_id": _tag(job_id),
        "decision": dec,
        "outcome": out,
        "params_shape": params_shape(params),
        "detail": _scrub_detail(detail),
    }


def write(event, *, actor_haid=None, action_type=None, action_id=None, job_id=None,
          decision=None, outcome=None, params=None, detail=None, home=None):
    """Append ONE schema-validated, secret-scrubbed audit row to audit.ndjson.

    Returns the audit_id on a successful write, or None on ANY drop (invalid event /
    write failure). UNLIKE telemetry.emit, the audit is a SECURITY record: it is NOT
    disable-able by an env flag — there is no opt-out marker, the audit always writes
    when the store is writable. (A disk failure still degrades to None rather than
    crashing a request — the request handler decides how to surface that.)

    This is the ONLY way to write the audit store. Consumers never touch the file."""
    record = build_record(
        event, actor_haid=actor_haid, action_type=action_type, action_id=action_id,
        job_id=job_id, decision=decision, outcome=outcome, params=params,
        detail=detail,
    )
    if record is None:
        return None
    if not _append(record, home):
        return None
    return record["audit_id"]


def _append(record, home):
    """Write one JSON line to audit.ndjson. Returns True on success, False on any IO
    failure (the audit degrades to a dropped row rather than crashing the request —
    but a security deployment should monitor for a False here).

    Routed THROUGH the StateBackend (Wave 0): append_line writes the same compact JSON
    line with the same flush-only discipline the audit has always used (fsync=False —
    the audit flushes, it does NOT os.fsync; that durability tier is the §4 jobstore's).
    Byte-identical on the local backend; the SAME append becomes Cloud-Run-durable when
    the Wave-2 backend lands."""
    return _backend(home).append_line(_AUDIT_REL, record, fsync=False)


# ── the §1 convenience writers (the cardinal dispatch/refusal pair) ────────────


def record_dispatch(actor_haid, action_type, *, action_id=None, job_id=None,
                    params=None, outcome="ok", detail=None, home=None):
    """Audit an ACCEPTED dispatch (§1/§9). params is reduced to shape (no values)."""
    return write(
        "dispatch", actor_haid=actor_haid, action_type=action_type,
        action_id=action_id, job_id=job_id, params=params, outcome=outcome,
        detail=detail, home=home,
    )


def record_refusal(actor_haid, action_type, *, reason=None, params=None,
                   action_id=None, home=None):
    """Audit a REFUSED dispatch (§1/§9) — the falsifiable-core record. `reason` is a
    short refusal code (unknown_action/bad_param/extra_param/...) carried in detail
    (scrubbed). action_type may be the rejected string (scrubbed + bounded) so the
    record names WHAT was refused without trusting it. outcome is always 'refused'."""
    return write(
        "dispatch_refused", actor_haid=actor_haid, action_type=action_type,
        action_id=action_id, params=params, outcome="refused", detail=reason,
        home=home,
    )


# ── read / search / export (searchable + exportable — §9) ──────────────────────


def read_records(home=None):
    """Stream every audit record from audit.ndjson, parsing each. Tolerant: a bad
    line is skipped, an absent store yields []. Read-only — never writes.

    Routed THROUGH the StateBackend (Wave 0): read_lines returns the same tolerant,
    store-ordered scan (blank/unparseable/non-dict lines skipped, absent store -> [])
    the audit has always done — the search/export semantics are unchanged."""
    return _backend(home).read_lines(_AUDIT_REL)


def search(home=None, *, actor_haid=None, event=None, action_type=None,
           since=None, until=None):
    """Filter audit rows (§9 searchable). Every filter is AND-combined; an omitted
    filter matches everything. `since`/`until` are ISO-8601 strings compared
    lexically (ISO-8601 sorts chronologically). Returns the matching rows in store
    order. Read-only; tolerant of an absent store ([])."""
    rows = read_records(home)
    out = []
    for r in rows:
        if actor_haid is not None and r.get("actor_haid") != actor_haid:
            continue
        if event is not None and r.get("event") != event:
            continue
        if action_type is not None and r.get("action_type") != action_type:
            continue
        ts = r.get("ts") or ""
        if since is not None and ts < since:
            continue
        if until is not None and ts > until:
            continue
        out.append(r)
    return out


def export(home=None, **filters):
    """Export the (optionally filtered) audit as NDJSON text — one canonical JSON
    line per row (sorted keys, compact). The exact on-disk shape, re-serialized so
    an export is stable + diffable. Returns a string (possibly empty)."""
    rows = search(home, **filters) if filters else read_records(home)
    return "".join(
        json.dumps(r, sort_keys=True, separators=(",", ":")) + "\n" for r in rows
    )

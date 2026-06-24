#!/usr/bin/env python3
# cp_scheduler.py — piece (c) of the Heimdall control plane: THE SCHEDULER (§6).
#
# DESIGN DOSSIER §6 (authoritative). Cron-style, server-side, scheduled runs of
# ALLOWLISTED action-types ONLY ("run-suite 2am", "sync-queue hourly"). The scheduler
# is NOT a privileged dispatch path — it is just an AUTOMATED CLIENT of the §1
# allowlist. It can fire ONLY what an allowlisted dispatch could fire; it can NEVER
# run an arbitrary command string.
#
# THE TWO HARD GATES (both go through cp_allowlist.validate — never a raw exec):
#   1. CREATE-TIME: creating a schedule VALIDATES its action_type+params via
#      cp_allowlist.validate(). A schedule for an UNKNOWN action_type, OR with a
#      smuggled command field / off-pattern param, is REFUSED at creation — 422 +
#      an audit `dispatch_refused` row, NEVER persisted. There is no schedule store
#      entry that names something the allowlist would not accept.
#   2. FIRE-TIME: when a schedule is due, tick() DISPATCHES through cp_server.dispatch
#      — the EXACT §1 path, which re-validates against cp_allowlist and writes the §9
#      audit `dispatch` row. The scheduler holds NO bypass: a stored entry is
#      re-validated at fire-time too, so an entry that somehow drifted off-allowlist
#      (or a now-removed action_type) is refused at fire, not run.
#
# THE FALSIFIABLE PROPERTY (§6, mirrors §1): a scheduler that could fire an arbitrary
# command would have to dispatch a raw string instead of going through validate() ->
# the test goes RED. Proven by the converse: a VALID allowlisted schedule DOES fire a
# real dispatch (refuse-arbitrary, distinct from refuse-everything).
#
# A scheduled `run-suite` (requires_gate=True) still surfaces to the approval queue
# (§7) at fire-time exactly as a manual dispatch would — cp_server.dispatch returns a
# 422 `requires_approval` until an owner approval lands. The scheduler does not, and
# cannot, skip the gate.
#
# STORE — append-only NDJSON at ${HEIMDALL_HOME}/control-plane/schedules/
# schedules.ndjson (one line per create/update/delete event; the live set is the FOLD
# of the log by schedule_id, mirroring cp_audit / the §4 jobstore discipline). NDJSON
# so bin/secret-scan scans it as plaintext. No secret enters by construction: params
# are allowlist-validated typed scalars (no free string), and the store is scanned.
#
# THE INTERFACE pieces bind to (stable; they import, never edit):
#   ScheduleError                          — raised on a bad cron / bad schedule shape.
#   parse_cron(expr) -> Cron               — parse a 5-field cron expr (raises on bad).
#   Cron.matches(dt) -> bool               — does this cron fire at minute `dt`?
#   create_schedule(identity, action_type, params, cron, *, ...) -> dict
#                                          — the §1-gated create (RefusedDispatch -> 422).
#   list_schedules(...) / get_schedule(...) / delete_schedule(...)
#   tick(identity_for, now, ...) -> list   — fire every due, enabled schedule via §1.
#   register_routes()                      — plug the CRUD surface into cp_server (§10).
#
# stdlib-only (json/os/uuid/datetime) + the sibling cp_* substrate (imported, never
# edited) — minimal self-host deps, mirrors cp_audit.py discipline.

from __future__ import annotations

import datetime
import json
import os
import sys
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_allowlist  # THE dispatch gate — a schedule MUST be an allowlisted action.
import cp_audit      # §9 — a refused create + a fired dispatch both audit.
import cp_server     # §1 dispatch core + the register_route seam (we never edit it).
import issue_queue   # REUSE heimdall_home() — the store lands in the same runtime home.


# ── error type (a bad cron / bad schedule shape — distinct from a dispatch refusal) ─


class ScheduleError(Exception):
    """Raised on a malformed cron expression or a structurally bad schedule request
    (e.g. a non-string action_type). A DISPATCH refusal (unknown action / smuggled
    command) is NOT this — that is cp_allowlist.RefusedDispatch, surfaced as the §1
    422 + audit. `reason` is a short machine code; `detail` a short, secret-free note."""

    def __init__(self, reason, detail=""):
        self.reason = reason
        self.detail = detail
        super().__init__("%s: %s" % (reason, detail) if detail else reason)


# ── the cron parser (a closed 5-field grammar — never a shell, never an eval) ──
#
# 5 whitespace-separated fields: minute hour day-of-month month day-of-week.
# Each field is one of: "*" (every value), a comma list of values/ranges, a step
# "*/N" or "lo-hi/N". Values are integers in the field's bounds. This is a CLOSED
# numeric grammar — it CANNOT express a command; the only thing a cron field decides
# is WHEN, never WHAT. The WHAT is the allowlisted action_type (gated separately).

_FIELD_BOUNDS = (
    (0, 59),   # minute
    (0, 23),   # hour
    (1, 31),   # day of month
    (1, 12),   # month
    (0, 6),    # day of week (0=Mon .. 6=Sun, matching datetime.weekday())
)
_FIELD_NAMES = ("minute", "hour", "dom", "month", "dow")


def _parse_field(spec, lo, hi, fname):
    """Parse ONE cron field into a frozenset of the integer values it matches. Accepts
    '*', comma lists, 'a-b' ranges, and '*/N' | 'a-b/N' steps. Every produced value is
    bounded to [lo,hi]; anything else raises ScheduleError. Returns a frozenset (a
    '*' field yields the full [lo,hi] set so matching is a pure membership test)."""
    spec = spec.strip()
    if not spec:
        raise ScheduleError("bad_cron", "%s field is empty" % fname)
    values = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            raise ScheduleError("bad_cron", "%s has an empty list item" % fname)
        step = 1
        if "/" in part:
            base, _, step_s = part.partition("/")
            if not step_s.isdigit() or int(step_s) <= 0:
                raise ScheduleError("bad_cron", "%s has a bad step" % fname)
            step = int(step_s)
        else:
            base = part
        if base == "*":
            rlo, rhi = lo, hi
        elif "-" in base:
            a, _, b = base.partition("-")
            if not (_is_int(a) and _is_int(b)):
                raise ScheduleError("bad_cron", "%s has a non-integer range" % fname)
            rlo, rhi = int(a), int(b)
        else:
            if not _is_int(base):
                raise ScheduleError("bad_cron", "%s has a non-integer value" % fname)
            rlo = rhi = int(base)
        if rlo > rhi or rlo < lo or rhi > hi:
            raise ScheduleError(
                "bad_cron", "%s value out of [%d,%d]" % (fname, lo, hi))
        for v in range(rlo, rhi + 1, step):
            values.add(v)
    if not values:
        raise ScheduleError("bad_cron", "%s matched no value" % fname)
    return frozenset(values)


def _is_int(s):
    s = s.strip()
    if not s:
        return False
    if s[0] in "+-":
        s = s[1:]
    return s.isdigit()


class Cron:
    """A parsed 5-field cron schedule. minutes/hours/doms/months/dows are each the
    frozenset of values the corresponding field matches. matches(dt) is True iff the
    minute `dt` lands in every field set (day-of-month AND day-of-week both match —
    the conservative/strict reading: both constraints hold). A pure WHEN decision —
    it carries NOTHING about WHAT runs (that is the allowlisted action)."""

    __slots__ = ("minutes", "hours", "doms", "months", "dows", "expr")

    def __init__(self, minutes, hours, doms, months, dows, expr):
        self.minutes = minutes
        self.hours = hours
        self.doms = doms
        self.months = months
        self.dows = dows
        self.expr = expr

    def matches(self, dt):
        """Does this cron fire at the minute `dt` (a datetime)? True iff every field
        set contains the corresponding component of `dt`. weekday(): Mon=0..Sun=6."""
        return (
            dt.minute in self.minutes
            and dt.hour in self.hours
            and dt.day in self.doms
            and dt.month in self.months
            and dt.weekday() in self.dows
        )


def parse_cron(expr):
    """Parse a 5-field cron expression into a Cron. Raises ScheduleError('bad_cron')
    on the wrong field count or any malformed field. The grammar is closed + numeric:
    a cron expr can NEVER carry a command — it only decides WHEN an allowlisted action
    fires."""
    if not isinstance(expr, str):
        raise ScheduleError("bad_cron", "cron must be a string")
    fields = expr.split()
    if len(fields) != 5:
        raise ScheduleError("bad_cron", "cron needs exactly 5 fields")
    sets = [
        _parse_field(fields[i], _FIELD_BOUNDS[i][0], _FIELD_BOUNDS[i][1],
                     _FIELD_NAMES[i])
        for i in range(5)
    ]
    return Cron(sets[0], sets[1], sets[2], sets[3], sets[4], expr)


# ── the schedule store (append-only NDJSON; live set = fold of the log — §6/§4) ─


def schedules_dir(home=None):
    """The schedule store dir: ${HEIMDALL_HOME}/control-plane/schedules/."""
    base = home if home else issue_queue.heimdall_home()
    return os.path.join(base, "control-plane", "schedules")


def schedules_path(home=None):
    """Absolute path to the append-only schedule log."""
    return os.path.join(schedules_dir(home), "schedules.ndjson")


def _now_iso():
    """Current UTC time, second precision, ISO-8601 (the store ts field)."""
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


def _append(record, home):
    """Append one JSON line to schedules.ndjson. Returns True on success, False on any
    IO failure (a create surfaces a False as an IO error rather than a silent drop)."""
    try:
        ldir = schedules_dir(home)
        os.makedirs(ldir, exist_ok=True)
        path = os.path.join(ldir, "schedules.ndjson")
        line = json.dumps(record, sort_keys=True, separators=(",", ":"))
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
            fh.flush()
        return True
    except OSError:
        return False


def _read_events(home=None):
    """Stream every schedule event (create/update/delete) from the log, in order.
    Tolerant: a bad line is skipped, an absent store yields []. Read-only."""
    out = []
    path = schedules_path(home)
    if not os.path.isfile(path):
        return out
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if isinstance(obj, dict) and obj.get("schedule_id"):
                    out.append(obj)
    except OSError:
        return out
    return out


def _fold(home=None):
    """Fold the append-only log into the LIVE schedule set: {schedule_id -> entry},
    last write wins, a `deleted:true` event removes the id. This is the source of
    truth (mirrors the §4 jobstore state = fold-of-log discipline). Returns a dict."""
    live = {}
    for ev in _read_events(home):
        sid = ev["schedule_id"]
        if ev.get("deleted"):
            live.pop(sid, None)
        else:
            live[sid] = ev
    return live


# ── CREATE — the §1-gated create (validate through cp_allowlist or REFUSE) ──────


def create_schedule(identity, action_type, params, cron, *, enabled=True,
                    schedule_id=None, home=None):
    """Create a schedule for an ALLOWLISTED action_type. THE create-time gate (§6):

      1. cp_allowlist.validate(action_type, params) — an UNKNOWN action_type, OR a
         smuggled command field / off-pattern param, raises RefusedDispatch. The
         caller (the route / tick) maps that to a 422 + an audit `dispatch_refused`
         row, and the schedule is NEVER persisted. The scheduler cannot store an
         entry the allowlist would not accept — no arbitrary command can be scheduled.
      2. parse_cron(cron) — a malformed cron raises ScheduleError (a 422 too), the
         schedule is not persisted. The cron decides WHEN, never WHAT.

    On success: appends a schedule event {schedule_id, cron, action_type, params (the
    VALIDATED params), owner_haid, enabled, ts} and returns the stored entry dict.

    Raises cp_allowlist.RefusedDispatch (off-allowlist / smuggle) or ScheduleError
    (bad cron / bad shape / store IO). It does NOT swallow them — the route layer
    decides the HTTP + audit mapping, exactly like cp_server.dispatch does for §1."""
    if not isinstance(action_type, str) or not action_type:
        raise ScheduleError("bad_schedule", "action_type must be a non-empty string")

    # 1. THE ALLOWLIST GATE — validate the action_type + params through §1. An unknown
    #    action_type or a command-smuggle raises RefusedDispatch (NEVER persisted).
    plan = cp_allowlist.validate(action_type, params)  # -> RefusedDispatch on refuse

    # 2. THE CRON — a closed numeric WHEN grammar; a bad cron is not persisted.
    parsed = parse_cron(cron)  # -> ScheduleError on a bad cron

    sid = schedule_id or ("sch-" + uuid.uuid4().hex)
    owner_haid = identity.haid if hasattr(identity, "haid") else identity
    record = {
        "schedule_id": sid,
        "cron": parsed.expr,
        "action_type": action_type,
        # store the VALIDATED params (typed/bounded scalars only) — the same params a
        # manual dispatch would carry; never a raw free string.
        "params": plan["params"],
        "owner_haid": owner_haid,
        "enabled": bool(enabled),
        "requires_gate": plan["requires_gate"],
        "ts": _now_iso(),
        "deleted": False,
    }
    if not _append(record, home):
        raise ScheduleError("io_error", "could not persist the schedule")
    return record


def list_schedules(home=None, *, owner_haid=None, action_type=None, enabled=None):
    """The LIVE schedule set (fold of the log), optionally filtered. Returns a list in
    schedule_id order. Read-only; tolerant of an absent store ([])."""
    out = []
    for entry in _fold(home).values():
        if owner_haid is not None and entry.get("owner_haid") != owner_haid:
            continue
        if action_type is not None and entry.get("action_type") != action_type:
            continue
        if enabled is not None and bool(entry.get("enabled")) != bool(enabled):
            continue
        out.append(entry)
    return sorted(out, key=lambda e: e["schedule_id"])


def get_schedule(schedule_id, home=None):
    """The live entry for `schedule_id`, or None if it does not exist (or was
    deleted). Read-only."""
    return _fold(home).get(schedule_id)


def delete_schedule(schedule_id, home=None):
    """Delete a schedule by appending a tombstone event. Returns True if the id was
    live before deletion, False if it did not exist. Append-only: the log keeps the
    history; the fold drops the id."""
    live = _fold(home)
    if schedule_id not in live:
        return False
    tomb = {
        "schedule_id": schedule_id,
        "deleted": True,
        "ts": _now_iso(),
    }
    return _append(tomb, home)


def set_enabled(schedule_id, enabled, home=None):
    """Enable/disable a schedule by appending an updated entry (last write wins).
    Returns the updated entry, or None if the id does not exist. A disabled schedule
    is skipped by tick() — it stays in the store but does not fire."""
    entry = get_schedule(schedule_id, home)
    if entry is None:
        return None
    updated = dict(entry)
    updated["enabled"] = bool(enabled)
    updated["ts"] = _now_iso()
    if not _append(updated, home):
        return None
    return updated


# ── FIRE — the tick (dispatch every due schedule through the §1 allowlist path) ─


def due_schedules(now, home=None):
    """The live, ENABLED schedules whose cron matches the minute `now`. A malformed
    stored cron (should not happen — create validates it) is skipped, not fired. Pure
    of dispatch — just the WHEN filter."""
    out = []
    for entry in list_schedules(home, enabled=True):
        try:
            cron = parse_cron(entry.get("cron", ""))
        except ScheduleError:
            continue
        if cron.matches(now):
            out.append(entry)
    return out


def tick(identity, now=None, *, home=None, approved_action_types=None,
         base_env=None):
    """Fire every due, enabled schedule by DISPATCHING through cp_server.dispatch —
    the EXACT §1 allowlist path (§6). The scheduler has NO privileged dispatch: it
    builds the SAME (identity, action_type, params) call a manual client would, and
    cp_server.dispatch re-validates against cp_allowlist + writes the §9 audit row.

    A scheduler that fired an arbitrary command would have to bypass this and exec a
    raw string — there is no such path here. tick() can only fire allowlisted
    dispatches; that is what makes the falsifiable test go RED for a bad build.

    `now` defaults to the current UTC minute. `identity` is the actor the scheduled
    dispatches run AS (the §6 scheduler identity — typically an owner HAID). A
    `run-suite` (requires_gate) dispatch returns the §7 `requires_approval` 422 from
    cp_server.dispatch unless its action_type is in `approved_action_types` (the set
    the approval queue (e) has cleared) — the scheduler never skips the gate itself.

    Returns a list of {schedule_id, action_type, status, action_id, audit_id} — one
    per fired schedule (the dispatch outcomes, for the caller's run log)."""
    when = now if now is not None else datetime.datetime.now(datetime.timezone.utc)
    approved = set(approved_action_types or ())
    fired = []
    for entry in due_schedules(when, home=home):
        action_type = entry["action_type"]
        params = entry.get("params") or {}
        # DISPATCH through the §1 core — re-validates against cp_allowlist (an entry
        # that drifted off-allowlist, or a now-removed action_type, is refused HERE,
        # never run) and writes the §9 audit dispatch/refusal row.
        resp = cp_server.dispatch(
            identity, action_type, params, home=home,
            approved=(action_type in approved), base_env=base_env,
        )
        fired.append({
            "schedule_id": entry["schedule_id"],
            "action_type": action_type,
            "status": resp.status,
            "action_id": (resp.body or {}).get("action_id"),
            "audit_id": resp.audit_id,
        })
    return fired


# ── the CRUD surface (plug into cp_server via register_route — §10, never edit it) ─


def _parse_body(request):
    """Parse a route request body (bytes/str/dict) into a dict, or None on malformed.
    cp_server hands the route the request dict whose `body` is the raw bytes."""
    if not isinstance(request, dict):
        return None
    body = request.get("body")
    if isinstance(body, dict):
        return body
    if body is None or body == b"" or body == "":
        return {}
    try:
        return json.loads(body)
    except (ValueError, TypeError):
        return None


def _route_create(identity, request):
    """POST /schedules — create a schedule (the §6 create-time allowlist gate). Body:
    {action_type, params, cron, enabled?}. An UNKNOWN action_type / smuggled command
    -> 422 + audit dispatch_refused (NEVER persisted). A bad cron -> 422. Success ->
    200 with the stored entry."""
    body = _parse_body(request)
    if body is None:
        return cp_server.Response(422, {"refused": True, "reason": "malformed_body"})
    actor = identity.haid if hasattr(identity, "haid") else identity
    try:
        entry = create_schedule(
            identity, body.get("action_type"), body.get("params"),
            body.get("cron"), enabled=bool(body.get("enabled", True)),
        )
    except cp_allowlist.RefusedDispatch as ref:
        # the falsifiable wall: an off-allowlist / smuggled schedule is refused at
        # creation, audited, never stored.
        audit_id = cp_audit.record_refusal(
            actor, body.get("action_type"), reason=ref.reason,
            params=body.get("params"),
        )
        return cp_server.Response(
            422, {"refused": True, "reason": ref.reason}, audit_id=audit_id)
    except ScheduleError as err:
        audit_id = cp_audit.record_refusal(
            actor, body.get("action_type"), reason=err.reason,
            params=body.get("params"),
        )
        return cp_server.Response(
            422, {"refused": True, "reason": err.reason}, audit_id=audit_id)
    return cp_server.Response(
        200,
        {"created": True, "schedule_id": entry["schedule_id"],
         "action_type": entry["action_type"], "cron": entry["cron"],
         "enabled": entry["enabled"]},
    )


def _route_list(identity, request):
    """GET /schedules — list the caller's live schedules (the §6 store view)."""
    actor = identity.haid if hasattr(identity, "haid") else identity
    entries = list_schedules(owner_haid=actor)
    return cp_server.Response(
        200,
        {"schedules": [
            {"schedule_id": e["schedule_id"], "action_type": e["action_type"],
             "cron": e["cron"], "enabled": e["enabled"]}
            for e in entries
        ]},
    )


def _route_delete(identity, request):
    """DELETE /schedules — delete a schedule by id. Body: {schedule_id}. Only the
    owning HAID (or an owner identity) may delete its schedule."""
    body = _parse_body(request)
    if body is None:
        return cp_server.Response(422, {"refused": True, "reason": "malformed_body"})
    sid = body.get("schedule_id")
    if not sid:
        return cp_server.Response(
            422, {"refused": True, "reason": "missing_schedule_id"})
    actor = identity.haid if hasattr(identity, "haid") else identity
    entry = get_schedule(sid)
    if entry is None:
        return cp_server.Response(404, {"error": "no_such_schedule"})
    is_owner = bool(getattr(identity, "owner", False))
    if entry.get("owner_haid") != actor and not is_owner:
        return cp_server.Response(403, {"error": "not_your_schedule"})
    delete_schedule(sid)
    return cp_server.Response(200, {"deleted": True, "schedule_id": sid})


def register_routes():
    """Plug the schedule CRUD surface into cp_server via register_route (§10) WITHOUT
    editing cp_server. Registers POST/GET/DELETE /schedules. Returns the registered
    route keys. Idempotent (re-registering replaces). This is how piece (c) extends
    the server without touching the wave-1 substrate."""
    keys = [
        cp_server.register_route("POST", "/schedules", _route_create),
        cp_server.register_route("GET", "/schedules", _route_list),
        cp_server.register_route("DELETE", "/schedules", _route_delete),
    ]
    return keys

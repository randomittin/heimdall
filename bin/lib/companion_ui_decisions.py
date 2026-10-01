#!/usr/bin/env python3
"""companion_ui_decisions.py -- the decision store for the phone's DENY-ONLY say over a pending
risky action (A4 in docs/HANDOFF-TO-HEIMDALL-product-asks.md, first round).

The one rule this module exists to keep: a phone can only ever REDUCE what runs. The only
decision it can record is `deny`; `allow` is refused here, for every request, in this version
(DecisionError("allow-not-permitted")). Nothing in this file can make an action run that would
not have run anyway.

Three writers meet in one directory, <repo>/.heimdall/ui/approvals/ (0700; every file 0600):

    bin/heimdall-phone-deny      the PreToolUse hook: request() a decision for a risky action, then
                                 poll decision_of() / apply_stop() inside a short bounded window,
                                 heartbeat() while it waits, close() when it leaves
    bin/heimdall-relay-client    the sealed, replay-guarded command path: decide() and request_stop()
                                 -- only a frame that opened under the paired device's session key
                                 ever reaches them
    sentinels/hmd-ui.py          reads pending() into the `approvals` slice of /api/state

Files:
    p-<8 hex>.json       a pending request {id, tool, summary, requested_at, expires_at, risk}. Its
                         MTIME is the hook's heartbeat: a request nobody has heartbeated for
                         HEARTBEAT_STALE_S is a dead hook (killed, timed out) and counts as expired
                         -- a deny must never be acknowledged for an action that already ran.
    p-<8 hex>.decision   the decision {id, decision: "deny", decided_at}, created O_EXCL: that
                         create IS the single-use guarantee (two concurrent denies -> one wins,
                         the other is `already-decided`). It outlives the request file so a replay
                         within GC_AFTER_S still answers `already-decided`, not `unknown-id`.
    stop.json            the phone's `stop` request {id, requested_at, expires_at, applied_at}
    armed                zero bytes; its mtime is the last time an ARMED hook ran (mark_armed)

Ids are random (`p-` / `s-` + 8 hex) and checked against a strict pattern before any path is built
from one, so a hostile id can never walk out of the directory. A request id is never reused.

Exposure (pending()) is minimal on purpose: the doc's six keys and nothing else -- never the raw
tool input, never a pid. The summary is a single line of at most SUMMARY_MAX chars; a
secret_shaped one is dropped to null (the request itself survives), and the raw value is never
written to disk in the first place.

Error codes (DecisionError.code) are the doc's own `error` strings: unknown-id | already-decided
| expired | allow-not-permitted | bad-decision.

Stdlib only. Self-contained (secret_shaped is ported from bin/lib/companion_ui_inbox.py, the same
way that module ports it from bin/heimdall-activity) so every caller can load this one file by path.
"""
import json
import math
import os
import re
import secrets
import time

APPROVALS_REL = os.path.join(".heimdall", "ui", "approvals")
MAX_LISTED = 5               # the doc: at most 5 entries in `approvals`
SUMMARY_MAX = 200            # the doc: summary at most 200 chars
TOOL_MAX = 60
HEARTBEAT_STALE_S = 5.0      # a request whose hook has not heartbeated this long is dead
GC_AFTER_S = 600.0           # request()/decision files older than this are swept
STOP_TTL_S = 60.0            # an unapplied stop request lapses after this
STOP_GRACE_S = 5.0           # once applied, sibling parallel tool calls still get it for this long
ARMED_FRESH_S = 900.0        # an `armed` heartbeat older than this: no armed hook is running
RISKS = ("low", "high")
READ_CAP_BYTES = 65536

_ID_RE = re.compile(r"p-[0-9a-f]{8}")
_REQUEST_FILE_RE = re.compile(r"(p-[0-9a-f]{8})\.json")
_MANAGED_FILE_RE = re.compile(r"p-[0-9a-f]{8}\.(?:json|decision)|\.tmp-.*")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
_TOOL_RE = re.compile(r"[^A-Za-z0-9_.:-]")

# -- secret scrub: bin/lib/companion_ui_inbox.py, itself bin/heimdall-activity's, ported ----------
_SECRET_RES = (
    re.compile(r"(token|secret|password|passwd|pwd|api[_-]?key|apikey|access[_-]?key|auth|bearer|"
               r"credential|private[_-]?key)\s*[=:]\s*\S{16,}", re.IGNORECASE),
    re.compile(r"ghp_[A-Za-z0-9]{36}"),
    re.compile(r"gh[oprsu]_[A-Za-z0-9]{36}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"sk_(live|test)_[A-Za-z0-9]{16,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----"),
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
)


def secret_shaped(v):
    if not isinstance(v, str):
        return False
    return any(rx.search(v) for rx in _SECRET_RES)


class DecisionError(ValueError):
    """A decision was refused. `code` is the doc's machine-readable `error` string; the message
    names the rule and never echoes anything the caller sent."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


# -- paths and permissions --------------------------------------------------------------------
def _approvals_dir(root):
    return os.path.join(root, APPROVALS_REL)


def _ensure_dir(root):
    """Create <root>/.heimdall/ui/approvals and force 0700 on it and on .heimdall/ui, on every
    touch, so a directory that predates this (or a hostile umask) self-heals."""
    d = _approvals_dir(root)
    os.makedirs(d, exist_ok=True)
    os.chmod(os.path.dirname(d), 0o700)
    os.chmod(d, 0o700)
    return d


def _valid_id(value, prefix="p"):
    return isinstance(value, str) and re.fullmatch(prefix + r"-[0-9a-f]{8}", value) is not None


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _now(now):
    return time.time() if now is None else float(now)


def _read_json(path):
    """The JSON object in `path`, or None -- a missing, oversized, unparsable or non-object file
    is simply no record, never an exception."""
    try:
        with open(path, "rb") as f:
            raw = f.read(READ_CAP_BYTES + 1)
    except OSError:
        return None
    if len(raw) > READ_CAP_BYTES:
        return None
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        return False
    return True


def _write_tmp(directory, obj, now):
    """A fully written 0600 temp file holding `obj` as JSON (mtime = `now`), ready to be renamed or
    linked into place -- so a reader never sees half a record."""
    tmp = os.path.join(directory, ".tmp-%d-%s" % (os.getpid(), secrets.token_hex(4)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(obj, sort_keys=True, separators=(",", ":")))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.utime(tmp, (now, now))
    except BaseException:
        _unlink(tmp)
        raise
    return tmp


def _write_json_atomic(directory, name, obj, now):
    """Replace <directory>/<name> with `obj` (tmp + rename)."""
    tmp = _write_tmp(directory, obj, now)
    try:
        os.replace(tmp, os.path.join(directory, name))
    except BaseException:
        _unlink(tmp)
        raise


def _sweep(directory, now):
    """Drop request / decision / temp files older than GC_AFTER_S. Only ever called from the
    write path (request()); the read path (pending()) never deletes anything."""
    try:
        entries = list(os.scandir(directory))
    except OSError:
        return
    for e in entries:
        if not _MANAGED_FILE_RE.fullmatch(e.name):
            continue
        try:
            age = now - e.stat().st_mtime
        except OSError:
            continue
        if age > GC_AFTER_S:
            _unlink(e.path)


# -- summary ----------------------------------------------------------------------------------
def clean_summary(text):
    """A one-line, at most SUMMARY_MAX-char summary, or None: not a string, empty after cleaning, or
    secret_shaped (checked on the WHOLE text before any truncation, so a secret past char 200 still
    drops the field). Control bytes and newlines become single spaces."""
    if not isinstance(text, str):
        return None
    line = " ".join(_CONTROL_RE.sub(" ", text).split())
    if not line or secret_shaped(text) or secret_shaped(line):
        return None
    if len(line) > SUMMARY_MAX:
        line = line[:SUMMARY_MAX - 1] + "…"
    return line


def clean_tool(name):
    return _TOOL_RE.sub("", name if isinstance(name, str) else "")[:TOOL_MAX] or "tool"


# -- the request side (the hook) --------------------------------------------------------------
def request(root, tool, summary, window_s, now=None, risk="high"):
    """Publish one pending request and return its record. The id is allocated with link(2), so it
    can never collide with a live one; the record's mtime starts the heartbeat."""
    now = _now(now)
    d = _ensure_dir(root)
    _sweep(d, now)
    base = {"tool": clean_tool(tool), "summary": clean_summary(summary), "requested_at": now,
            "expires_at": now + float(window_s), "risk": risk if risk in RISKS else "high"}
    for _ in range(8):
        rec = dict(base, id="p-" + secrets.token_hex(4))
        tmp = _write_tmp(d, rec, now)
        try:
            os.link(tmp, os.path.join(d, rec["id"] + ".json"))
        except FileExistsError:
            continue
        finally:
            _unlink(tmp)
        return rec
    raise OSError("could not allocate a free approval id")


def heartbeat(root, req_id, now=None):
    """Keep a request alive. A request that is already gone is not an error."""
    if not _valid_id(req_id):
        return
    now = _now(now)
    try:
        os.utime(os.path.join(_approvals_dir(root), req_id + ".json"), (now, now))
    except OSError:
        return


def decision_of(root, req_id):
    """"deny" when a well-formed deny decision exists for exactly this id, else None. Anything
    else in the file -- garbage, an `allow`, another id -- is read as no decision at all."""
    if not _valid_id(req_id):
        return None
    obj = _read_json(os.path.join(_approvals_dir(root), req_id + ".decision"))
    if obj is not None and obj.get("id") == req_id and obj.get("decision") == "deny":
        return "deny"
    return None


def close(root, req_id):
    """The hook is leaving: drop the request so it stops being listed. The decision file (if any)
    stays, so a replay is still answered `already-decided`."""
    if _valid_id(req_id):
        _unlink(os.path.join(_approvals_dir(root), req_id + ".json"))


# -- the decision side (the relay client) -----------------------------------------------------
def decide(root, req_id, decision, now=None):
    """Record the phone's decision for `req_id` and return {id, decision}. Raises DecisionError --
    the order below is the contract, and nothing is written on any refusal:
        bad-decision          `decision` is not "allow"/"deny" (a string)
        unknown-id            `req_id` is not an id this store ever issued (or is shaped like a path)
        allow-not-permitted   "allow", for EVERY request, in this version
        already-decided       a decision file exists (the single-use rule)
        expired               past expires_at, or the hook stopped heartbeating
    """
    now = _now(now)
    if not isinstance(decision, str) or decision not in ("allow", "deny"):
        raise DecisionError("bad-decision", "decision must be \"deny\"")
    if not _valid_id(req_id):
        raise DecisionError("unknown-id", "no such approval request")
    d = _approvals_dir(root)
    req_path = os.path.join(d, req_id + ".json")
    dec_path = os.path.join(d, req_id + ".decision")
    if not (os.path.exists(req_path) or os.path.exists(dec_path)):
        raise DecisionError("unknown-id", "no such approval request")
    if decision == "allow":
        raise DecisionError("allow-not-permitted", "the phone cannot approve an action")
    if os.path.exists(dec_path):
        raise DecisionError("already-decided", "this request already has a decision")
    rec = _read_json(req_path)
    try:
        beat = os.stat(req_path).st_mtime
    except OSError:
        rec = None
    if rec is None or rec.get("id") != req_id or not _is_number(rec.get("expires_at")):
        raise DecisionError("unknown-id", "no such approval request")
    if now >= rec["expires_at"] or now - beat > HEARTBEAT_STALE_S:
        raise DecisionError("expired", "this request is no longer waiting for a decision")
    try:
        fd = os.open(dec_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise DecisionError("already-decided", "this request already has a decision") from None
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps({"id": req_id, "decision": "deny", "decided_at": now},
                           sort_keys=True, separators=(",", ":")))
        f.flush()
        os.fsync(f.fileno())
    os.chmod(dec_path, 0o600)
    os.utime(dec_path, (now, now))
    return {"id": req_id, "decision": "deny"}


# -- exposure (sentinels/hmd-ui.py -> /api/state.approvals) ------------------------------------
def pending(root, now=None):
    """The live, undecided requests as the doc's six keys, oldest first, at most MAX_LISTED. Live =
    inside its window AND heartbeated within HEARTBEAT_STALE_S. Read-only: it never deletes."""
    now = _now(now)
    d = _approvals_dir(root)
    try:
        entries = list(os.scandir(d))
    except OSError:
        return []
    out = []
    for e in entries:
        m = _REQUEST_FILE_RE.fullmatch(e.name)
        if m is None:
            continue
        rid = m.group(1)
        rec = _read_json(e.path)
        try:
            beat = e.stat().st_mtime
        except OSError:
            continue
        if (rec is None or rec.get("id") != rid or not isinstance(rec.get("tool"), str)
                or not (rec.get("summary") is None or isinstance(rec.get("summary"), str))
                or not _is_number(rec.get("requested_at")) or not _is_number(rec.get("expires_at"))
                or rec.get("risk") not in RISKS):
            continue
        if now >= rec["expires_at"] or now - beat > HEARTBEAT_STALE_S:
            continue
        if os.path.exists(os.path.join(d, rid + ".decision")):
            continue
        out.append({"id": rid, "tool": rec["tool"], "summary": rec["summary"],
                    "requested_at": rec["requested_at"], "expires_at": rec["expires_at"],
                    "risk": rec["risk"]})
    out.sort(key=lambda r: (r["requested_at"], r["id"]))
    return out[:MAX_LISTED]


# -- stop ---------------------------------------------------------------------------------------
def request_stop(root, now=None, ttl_s=None):
    """Record the phone's request to stop the running turn at its next tool call. Latest wins."""
    now = _now(now)
    ttl = STOP_TTL_S if ttl_s is None else float(ttl_s)
    d = _ensure_dir(root)
    rec = {"id": "s-" + secrets.token_hex(4), "requested_at": now, "expires_at": now + ttl,
           "applied_at": None}
    _write_json_atomic(d, "stop.json", rec, now)
    return {"id": rec["id"], "requested_at": rec["requested_at"], "expires_at": rec["expires_at"]}


def apply_stop(root, now=None):
    """The stop request that applies to a tool call being made right now, or None. The first call
    stamps `applied_at`; every call inside STOP_GRACE_S of that still gets it (so parallel sibling
    tool calls of the same assistant message are stopped together); after that the request is
    spent and removed -- a stop never lingers into the next turn."""
    now = _now(now)
    path = os.path.join(_approvals_dir(root), "stop.json")
    rec = _read_json(path)
    if rec is None or not _valid_id(rec.get("id"), "s") or not _is_number(rec.get("expires_at")):
        return None
    applied = rec.get("applied_at")
    if applied is None:
        if now >= rec["expires_at"]:
            _unlink(path)
            return None
        rec["applied_at"] = now
        _write_json_atomic(os.path.dirname(path), "stop.json", rec, now)
    elif not _is_number(applied) or now - applied > STOP_GRACE_S:
        _unlink(path)
        return None
    return {"id": rec["id"], "requested_at": rec.get("requested_at"), "expires_at": rec["expires_at"]}


# -- armed heartbeat ----------------------------------------------------------------------------
def mark_armed(root, now=None):
    """An armed hook is running right now (called once per armed invocation)."""
    now = _now(now)
    path = os.path.join(_ensure_dir(root), "armed")
    os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600))
    os.chmod(path, 0o600)
    os.utime(path, (now, now))


def armed(root, now=None, max_age_s=None):
    """True when an armed hook has run within `max_age_s` (default ARMED_FRESH_S)."""
    now = _now(now)
    limit = ARMED_FRESH_S if max_age_s is None else float(max_age_s)
    try:
        beat = os.stat(os.path.join(_approvals_dir(root), "armed")).st_mtime
    except OSError:
        return False
    return now - beat <= limit

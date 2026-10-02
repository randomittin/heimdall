#!/usr/bin/env python3
"""companion_ui_decisions.py -- the decision store for the phone's DENY-ONLY say over a pending
risky action (A4 in docs/HANDOFF-TO-HEIMDALL-product-asks.md, first round).

The one rule this module exists to keep: a phone can only ever REDUCE what runs. The only
decision it can record is `deny`; `allow` is refused here, for every request, in this version
(DecisionError("allow-not-permitted")). Nothing in this file can make an action run that would
not have run anyway.

Three parties meet in one directory, <repo>/.heimdall/ui/approvals/ (0700; every file 0600):

    bin/heimdall-phone-deny      the PreToolUse hook: request() a decision for a risky action, then
                                 poll decision_of() inside a short bounded window, heartbeat()
                                 while it waits, settle() when the window ends, close() when it leaves
    bin/heimdall-relay-client    the sealed, replay-guarded command path: decide() -- only a frame
                                 that opened under the paired device's session key ever reaches it
    sentinels/hmd-ui.py          reads pending() into the `approvals` slice of /api/state

Files:
    p-<8 hex>.json       a pending request {id, tool, summary, requested_at, expires_at, risk}. Its
                         MTIME is the hook's heartbeat: a request nobody has heartbeated for
                         HEARTBEAT_STALE_S is a dead hook (killed, timed out) and counts as expired
                         -- a deny must never be acknowledged for an action that already ran.
    p-<8 hex>.decision   the one decision slot of a request, {id, decision, decided_at}. It is
                         created by link(2)-ing a finished temp file into place, so it appears
                         complete or not at all, and a second create fails: that IS the single-use
                         guarantee. Two parties can claim it. The phone claims it with "deny"
                         (decide()); the hook claims it with "timeout" when its window ends
                         (settle()). Whoever gets there first wins, and the loser is told so:
                         a late deny is `expired`, never an ack for an action that already went
                         through; a deny that got in first is the one settle() hands back. The
                         file outlives the request file so a replay within GC_AFTER_S still
                         answers `already-decided` / `expired`, not `unknown-id`.

Ids are random (`p-` + 8 hex) and checked against a strict pattern before any path is built from
one, so a hostile id can never walk out of the directory. A request id is never reused.

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
GC_AFTER_S = 600.0           # request/decision files older than this are swept
RISKS = ("low", "high")
READ_CAP_BYTES = 65536

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


def _valid_id(value):
    return isinstance(value, str) and re.fullmatch(r"p-[0-9a-f]{8}", value) is not None


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
    """A fully written 0600 temp file holding `obj` as JSON (mtime = `now`), ready to be linked
    into place -- so a reader never sees half a record."""
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


def _claim(directory, req_id, decision, now):
    """Take the decision slot of `req_id` with `decision`: True when THIS call created it, False when
    a decision is already there. The record is written in full to a temp file first and link(2)ed into
    place -- which fails if the name exists -- so no reader ever sees half a decision and exactly one
    claimant can win."""
    tmp = _write_tmp(directory, {"id": req_id, "decision": decision, "decided_at": now}, now)
    try:
        os.link(tmp, os.path.join(directory, req_id + ".decision"))
    except FileExistsError:
        return False
    finally:
        _unlink(tmp)
    return True


def _already_decided(dec_path):
    """Why a request whose slot is taken cannot take a deny: the hook's own timeout marker means the
    window closed first (`expired`); anything else is a decision that was already made."""
    obj = _read_json(dec_path)
    if obj is not None and obj.get("decision") == "timeout":
        return DecisionError("expired", "this request is no longer waiting for a decision")
    return DecisionError("already-decided", "this request already has a decision")


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


def settle(root, req_id, now=None):
    """The hook's window is over. Returns "deny" when the phone's deny is on record, else None -- and in
    the same step makes sure no deny can be recorded from now on, by claiming the decision slot with a
    "timeout" marker. That is the line the whole store turns on: decide() answers OK exactly when this
    returns "deny", and `expired` exactly when it returns None, so a deny the phone is told was
    accepted is a deny the hook acts on. Anything unexpected (no such directory, an unwritable one) is
    None: the hook does nothing."""
    if not _valid_id(req_id):
        return None
    try:
        claimed = _claim(_approvals_dir(root), req_id, "timeout", _now(now))
    except OSError:
        return None
    return None if claimed else decision_of(root, req_id)


def close(root, req_id):
    """The hook is leaving: drop the request so it stops being listed. The decision file (if any)
    stays, so a replay is still answered `already-decided` / `expired`."""
    if _valid_id(req_id):
        _unlink(os.path.join(_approvals_dir(root), req_id + ".json"))


# -- the decision side (the relay client) -----------------------------------------------------
def decide(root, req_id, decision, now=None):
    """Record the phone's decision for `req_id` and return {id, decision}. Raises DecisionError --
    the order below is the contract, and nothing is written on any refusal:
        bad-decision          `decision` is not "allow"/"deny" (a string)
        unknown-id            `req_id` is not an id this store ever issued (or is shaped like a path)
        allow-not-permitted   "allow", for EVERY request, in this version
        already-decided       a deny is already on record (the single-use rule)
        expired               the hook already gave up (its timeout marker), or past expires_at, or the
                              hook stopped heartbeating
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
        raise _already_decided(dec_path)
    rec = _read_json(req_path)
    try:
        beat = os.stat(req_path).st_mtime
    except OSError:
        rec = None
    if rec is None or rec.get("id") != req_id or not _is_number(rec.get("expires_at")):
        raise DecisionError("unknown-id", "no such approval request")
    if now >= rec["expires_at"] or now - beat > HEARTBEAT_STALE_S:
        raise DecisionError("expired", "this request is no longer waiting for a decision")
    if not _claim(d, req_id, "deny", now):
        raise _already_decided(dec_path)
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

#!/usr/bin/env python3
"""companion_dashboards.py -- custom dashboards, the PROTOCOL half (hmdapp docs/HANDOFF-TO-HEIMDALL-custom-dashboards.md DD1-DD3, DD7;
its spec docs/superpowers/specs/2026-10-06-custom-dashboards.md).

The phone describes a panel in words for a paired project; hmd on that laptop turns it into a panel definition plus a READ-ONLY
data producer, publishes the result in `state.dashboards`, and requires laptop-side confirmation before any new producer exists.
THIS module owns the wire, the tile store and the panel publishing. It never runs a producer, never talks to a model and never
confirms anything: bin/lib/dashboard_producers.py (DD4 generator, DD5 runtime, DD6 `hmd dash` confirmation) sits on the other side
of the function boundary documented under INTERFACE below.

WIRE (cap `dash-v1`, sealed action `dashboard-request`, an `expand` action behind `hmd app remote-dashboards on`, off by default).
Plaintext `{"action":"dashboard-request","params":{...}}`, at most 1 KiB, exact key set per `op` (an extra key, a wrong type or an
id off its pattern is `bad-params`); `rid` (`q-<8 hex>`) is REQUIRED on every op:

    create       rid op dashboard_id screen_id tile_id project text [refresh_s shape origin author]
    refine       rid op dashboard_id tile_id project text [refresh_s]
    set-refresh  rid op dashboard_id tile_id project refresh_s
    refresh      rid op dashboard_id project [tile_id]       (no tile_id = every tile of that dashboard in this repo)
    remove       rid op dashboard_id project [tile_id]       (no tile_id = every tile of that dashboard in this repo)

Ids are `^[dst]-[0-9a-f]{8}$`; `text` 1-240 characters and <= 600 UTF-8 bytes, NFC, no control or bidi character; `refresh_s`
an integer 60..86400; `shape` {type: <panel types>, format?: <number formats>, series?: 1..6}; `origin` is "import" or absent;
`author` is 32 lowercase hex. Ack `{of_seq, ok, detail?, id?, retry_after_s?}`: ok:true detail "queued" (the request was taken; the
answer rides state.dashboards) or "dup" (a replayed rid, answered with the first ack's `id`, the handler does not run again), `id`
= the tile id when the op names one. Refusals (ok:false, detail): bad-params, caps-missing, controls-off, dashboards-off,
rate-limited (+ retry_after_s), too-many-tiles, unknown-tile, wrong-project, busy, daily-limit, not-implemented.

STATE. snapshot() is the additive `dashboards` key, sent ONLY to a phone whose latest sealed resync listed `dash-v1`
(overlay()), as `{"v":1,"enabled":bool,"limits":{..},"tiles":[..],"requests":[..last 8..]}`; a tile row is `{dashboard_id, screen_id,
tile_id, intent, origin: phone|import, rev, refresh_s, phase: generating|needs-confirm|live|error|paused, detail, producer_label,
confirm: null|{code, expires_at}, last_ok_at, panel: null|{id, title, type, data, refresh_s, updated_at, stale}}`. NEVER in it: the
proposal, the statement, a connector's settings, a path (test/heimdall-dashboards.test.sh plants a marker in each). `phase` is never
`rejected`: the app derives that itself from a panel it will not draw; a declined or expired tile is `error` + detail declined /
expired, the pair the app's copy table words. `detail` `budget` is hmd's own addition: the slice is held under 512 KiB, and past that
the panels of the least recently updated tiles are dropped (the rows stay, `panel` null, `detail` budget). snapshot(phone=False) is
the LAPTOP view that goes into the base `/api/state` (so the digest moves on every change and `hmd ui` can draw its card): no panel
data (a short signature instead) and no confirmation code -- the six digits are shown on the phone only.

STORE. <repo>/.heimdall/ui/dashboards/<dashboard_id>/<tile_id>.json (dir 0700, file 0600, `<id>.json.<pid>.tmp` -> os.replace, regular
files only, never a symlink) is ONE tile definition; meta.json beside them holds the request ring, the generation queue and the
day's count; `rev` is rewritten on every change (hmd-ui watches that one stat). Every writer holds the flock on `.lock`, so the relay
client, the producer runtime and the confirmation CLI -- separate processes -- cannot lose each other's update. A tile file is
`{tile_id, dashboard_id, screen_id, intent, shape, refresh_s, origin, author, rev, proposal, fingerprint, confirmed_fp, phase,
detail, last_ok_at, history:[<=5 prior {rev, intent, fingerprint}], panel, panel_rev, pending_at, refresh_requested_at}`. `proposal`
(the producer plan, statement included) is stored here and goes to NO state frame, ack, log or audit line.

INTERFACE for bin/lib/dashboard_producers.py (all take `root` first, are safe from any process, and never raise for an unknown tile):
  DD4  claim_generation(root) -> job|None     next queued create/refine, one in flight per repo; job = {rid, op, tile_id, dashboard_id,
                                              text, shape, refresh_s, origin, author, context:[{intent, shape}]} (the other tiles of the
                                              same dashboard, for the generator's prompt). A job in flight past GENERATION_TIMEOUT_S is
                                              failed `timeout` by the next call.
       register_proposal(root, tile_id, rid, proposal) -> (ok, detail)   proposal = {"shape":{..}, "producer":{"kind":"sql",
                                              "connector":str, "statement":str, "columns":[str]}}; closed schema; stores it, derives the
                                              fingerprint and puts the tile in needs-confirm unless that fingerprint is already the one
                                              confirmed (a refine that did not change the producer needs nothing).
       fail_generation(root, tile_id, rid, detail)   detail in no-connector | ambiguous | unsafe-query | generation-failed | timeout
  DD5  confirmed_producers(root) -> [{tile_id, dashboard_id, refresh_s, shape, producer, fingerprint, phase, detail, last_ok_at,
                                              refresh_requested_at}]   EXACTLY the tiles allowed to run: fingerprint == confirmed_fp
                                              and not paused / declined / expired; the statement is in `producer`, for the runtime only.
       publish_panel(root, tile_id, candidate) -> (ok, detail)   DD3: the closed validator + the 32 KiB budget; a rejected result keeps
                                              the previous panel and sets error / rejected-panel; an unconfirmed tile is refused.
       set_tile_status(root, tile_id, phase, detail) -> bool     live | error(producer-failed, timeout) | paused(idle, backoff); the
                                              failure and the idle pause are audited here.
       phone_present(root, idle_s=IDLE_S) -> bool                any dashboard-request in the last 12 h (idle_s 0 = always present)
  DD6  pending_confirmations(root) / get_tile(root, tile_id)   full records, proposal included, for `hmd dash pending|show`
       confirm_code(tile_id, fingerprint) -> "012345"           the one derivation of the six digits (domain hmd-dash-confirm-v1)
       confirm_tile(root, tile_id, fingerprint) -> (ok, why)    pins confirmed_fp; the CALLER owns the TTY and the code check
       decline_tile(root, tile_id) -> bool                      error / declined
       expire_pending(root) -> [tile_id]                        24 h without confirmation: error / expired
  DD7  audit_event(root, op, tile_id, ok, detail)               one controls-audit.jsonl line, ids and fixed tokens only

SECURITY. Nothing here can flip the dashboards switch (bin/lib/companion_remote_switches.py is the one writer and only a person at a
terminal reaches it). The phone's text is stored as the tile's `intent` and nowhere else: not in the audit line, not in the timeline,
not in a log. A request that creates or changes a producer ends in needs-confirm or an error, never in a run.

Stdlib only. Registered into bin/lib/companion_ui_controls.py by its register_actions(kit) hook (see the bottom of that module).
"""
import contextlib
import fcntl
import hashlib
import json
import math
import os
import re
import stat
import sys
import threading
import time
import types
import unicodedata
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))

CAP_DASH = "dash-v1"
ACTION = "dashboard-request"
SWITCH = "dashboards"
MAX_TILES = 16                         # per repo
REFRESH_MIN_S, REFRESH_MAX_S, REFRESH_DEFAULT_S = 60, 86400, 300
PANEL_BYTES = 32768                    # one tile's panel, stricter than the 64 KiB a job panel may be (DD3)
SLICE_BYTES = 512 * 1024               # the whole state.dashboards slice, asserted before it is sealed
MAX_TEXT_CHARS, MAX_TEXT_BYTES, MAX_PROJECT_CHARS = 240, 600, 255
IDLE_S = 12 * 3600                     # a phone is "present" if any dashboard-request arrived this recently
PENDING_TTL_S = 24 * 3600              # an unconfirmed proposal expires
GENERATION_TIMEOUT_S = 135             # the generator's 120 s plus slack: an in-flight job past this is failed `timeout`
QUEUE_MAX = 3                          # queued generations per repo, then `busy`
DAILY_MAX = 40                         # create + refine per repo per UTC day, then `daily-limit`
REFRESH_TILE_GAP_S = 30                # one refresh per tile per this many seconds
REQUESTS_KEPT, HISTORY_KEPT, LABEL_MAX = 8, 5, 60
LABEL_FALLBACK = "data source (read-only)"
STATUS_DETAILS = {"live": (None,), "error": ("producer-failed", "timeout"), "paused": ("idle", "backoff")}
GENERATION_DETAILS = ("no-connector", "ambiguous", "unsafe-query", "generation-failed", "timeout")
DETAILS = frozenset(GENERATION_DETAILS + ("producer-failed", "rejected-panel", "declined", "expired", "idle", "backoff", "budget"))
PHASES = frozenset(("generating", "needs-confirm", "live", "error", "paused"))
LIMITS = {"tiles": MAX_TILES, "refresh_min_s": REFRESH_MIN_S, "refresh_max_s": REFRESH_MAX_S,
          "refresh_default_s": REFRESH_DEFAULT_S, "panel_bytes": PANEL_BYTES}

ID_RES = {"dashboard_id": re.compile(r"d-[0-9a-f]{8}"), "screen_id": re.compile(r"s-[0-9a-f]{8}"),
          "tile_id": re.compile(r"t-[0-9a-f]{8}")}
RID_RE = re.compile(r"q-[0-9a-f]{8}")
AUTHOR_RE = re.compile(r"[0-9a-f]{32}")
CONNECTOR_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._ -]{0,63}")
_BIDI = frozenset("؜‎‏‪‫‬‭‮⁦⁧⁨⁩")

# exact key sets per op: (required, optional); `rid` and `op` ride beside them
_OPS = {
    "create": (("dashboard_id", "screen_id", "tile_id", "project", "text"), ("refresh_s", "shape", "origin", "author")),
    "refine": (("dashboard_id", "tile_id", "project", "text"), ("refresh_s",)),
    "set-refresh": (("dashboard_id", "tile_id", "project", "refresh_s"), ()),
    "refresh": (("dashboard_id", "project"), ("tile_id",)),
    "remove": (("dashboard_id", "project"), ("tile_id",)),
}
TIMELINE_OPS = ("create", "refine", "remove")     # the ops that also get a `remote-action` line in relay-events.jsonl

_MODULES = {}
_KIT = None                                       # set by register_actions: the dispatcher that loaded THIS copy of the module


def _sibling(name):
    """A sibling bin/lib module loaded by path (None when it cannot load), once."""
    if name not in _MODULES:
        try:
            spec = spec_from_file_location(name, os.path.join(HERE, name + ".py"))
            mod = module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception:
            mod = None
        _MODULES[name] = mod
    return _MODULES[name]


def _panels():
    mod = _sibling("companion_ui_panels")
    if mod is None:
        raise RuntimeError("bin/lib/companion_ui_panels.py did not load: no panel can be validated")
    return mod


def _ctl():
    """What this module needs of the dispatcher (audit, iso, controls_enabled): the kit it was registered through, else the
    controls module loaded by path. Lazy on purpose -- the controls module loads THIS one at import time."""
    if _KIT is not None:
        return _KIT
    mod = _sibling("companion_ui_controls")
    if mod is None:
        return None
    return types.SimpleNamespace(audit=mod._audit, iso=mod._iso, controls_enabled=mod.controls_enabled)


def _switch_on():
    sw = _sibling("companion_remote_switches")
    return sw is not None and sw.switch_enabled(SWITCH)


def _controls_on(root):
    ctl = _ctl()
    return ctl is not None and ctl.controls_enabled(root)


def enabled(root):
    """The slice's `enabled`: the laptop switch is on AND the controls kill switch is not thrown."""
    return _switch_on() and _controls_on(root)


# -- params ------------------------------------------------------------------------------------------------------
def _valid_text(v):
    if not isinstance(v, str) or not 0 < len(v) <= MAX_TEXT_CHARS or unicodedata.normalize("NFC", v) != v:
        return False
    try:
        if len(v.encode("utf-8")) > MAX_TEXT_BYTES:
            return False
    except UnicodeEncodeError:       # a lone surrogate
        return False
    return not any(unicodedata.category(ch) in ("Cc", "Cs") or ch in _BIDI for ch in v)


def _valid_project(v):
    return isinstance(v, str) and 0 < len(v) <= MAX_PROJECT_CHARS and not any(unicodedata.category(ch) in ("Cc", "Cs") for ch in v)


def _valid_refresh(v):
    return isinstance(v, int) and not isinstance(v, bool) and REFRESH_MIN_S <= v <= REFRESH_MAX_S


def _valid_shape(v):
    p = _panels()
    if not isinstance(v, dict) or not set(v) <= {"type", "format", "series"} or "type" not in v or v["type"] not in p.PANEL_TYPES:
        return False
    if "format" in v and v["format"] not in p.NUMBER_FORMATS:
        return False
    series = v.get("series", 1)
    return isinstance(series, int) and not isinstance(series, bool) and 1 <= series <= p.MAX_SERIES


def parse_params(body):
    """The clean params of one op from `body` (the params without `rid`), or ValueError: the exact key set of its op, each
    value of its exact type."""
    op = body.get("op") if isinstance(body, dict) else None
    if not isinstance(op, str) or op not in _OPS:
        raise ValueError("op")
    required, optional = _OPS[op]
    keys = set(body) - {"op"}
    if not set(required) <= keys or not keys <= set(required) | set(optional):
        raise ValueError("keys")
    checks = {"project": _valid_project, "text": _valid_text, "refresh_s": _valid_refresh, "shape": _valid_shape,
              "origin": lambda v: v == "import", "author": lambda v: isinstance(v, str) and AUTHOR_RE.fullmatch(v) is not None}
    out = {"op": op}
    for key in keys:
        value = body[key]
        valid = (isinstance(value, str) and ID_RES[key].fullmatch(value) is not None) if key in ID_RES else checks[key](value)
        if not valid:
            raise ValueError(key)
        out[key] = value
    return out


# -- the store ---------------------------------------------------------------------------------------------------
def store_dir(root):
    return os.path.join(root, ".heimdall", "ui", "dashboards")


def _mkdir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)


def _read_json(path, cap=262144):
    """The JSON object in `path`: a regular file only, opened without following a symlink; None when absent or unusable."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        raw = os.read(fd, cap + 1)
    finally:
        os.close(fd)
    try:
        obj = json.loads(raw.decode("utf-8")) if len(raw) <= cap else None
    except (ValueError, UnicodeDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


def _write_json(path, obj):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    data = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


@contextlib.contextmanager
def _locked(root):
    d = store_dir(root)
    _mkdir(d)
    fd = os.open(os.path.join(d, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _touch(root):
    """Bump the one file hmd-ui stats, so a change lands in the state within a poll, whichever process made it."""
    _write_json(os.path.join(store_dir(root), "rev"), {"t": time.time_ns()})


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _sane(tile, dashboard_id, tile_id):
    return (isinstance(tile, dict) and tile.get("tile_id") == tile_id and tile.get("dashboard_id") == dashboard_id
            and isinstance(tile.get("screen_id"), str) and ID_RES["screen_id"].fullmatch(tile["screen_id"])
            and isinstance(tile.get("intent"), str) and tile.get("phase") in PHASES
            and (tile.get("detail") is None or tile.get("detail") in DETAILS) and _valid_refresh(tile.get("refresh_s"))
            and _int(tile.get("rev")) and tile.get("origin") in ("phone", "import")
            and isinstance(tile.get("history"), list))


def _tile_path(root, dashboard_id, tile_id):
    return os.path.join(store_dir(root), dashboard_id, tile_id + ".json")


def _read_tile(root, dashboard_id, tile_id):
    if not (ID_RES["dashboard_id"].fullmatch(dashboard_id) and ID_RES["tile_id"].fullmatch(tile_id)):
        return None
    tile = _read_json(_tile_path(root, dashboard_id, tile_id))
    return tile if _sane(tile, dashboard_id, tile_id) else None


def _write_tile(root, tile):
    _mkdir(os.path.join(store_dir(root), tile["dashboard_id"]))
    _write_json(_tile_path(root, tile["dashboard_id"], tile["tile_id"]), tile)


def _all_tiles(root):
    """Every sane tile of the repo, ordered by (dashboard, tile); a corrupt or foreign file is skipped, never repaired."""
    out = []
    try:
        dirs = sorted(n for n in os.listdir(store_dir(root)) if ID_RES["dashboard_id"].fullmatch(n))
    except OSError:
        return out
    for d in dirs[:64]:
        try:
            if not stat.S_ISDIR(os.lstat(os.path.join(store_dir(root), d)).st_mode):
                continue
            names = sorted(n[:-5] for n in os.listdir(os.path.join(store_dir(root), d)) if n.endswith(".json"))
        except OSError:
            continue
        for t in names[:MAX_TILES * 2]:
            tile = _read_tile(root, d, t)
            if tile is not None:
                out.append(tile)
    return out


def _find(root, tile_id):
    return next((t for t in _all_tiles(root) if t["tile_id"] == tile_id), None) if ID_RES["tile_id"].fullmatch(str(tile_id)) else None


def _load_meta(root):
    raw = _read_json(os.path.join(store_dir(root), "meta.json")) or {}
    daily = raw.get("daily") if isinstance(raw.get("daily"), dict) else {}
    return {"requests": [r for r in raw.get("requests", []) if isinstance(r, dict)][-REQUESTS_KEPT:] if isinstance(raw.get("requests"), list) else [],
            "queue": [j for j in raw.get("queue", []) if isinstance(j, dict)] if isinstance(raw.get("queue"), list) else [],
            "in_flight": raw.get("in_flight") if isinstance(raw.get("in_flight"), dict) else None,
            "daily": {"day": daily.get("day") if isinstance(daily.get("day"), str) else "", "n": daily.get("n") if _int(daily.get("n")) else 0},
            "last_request_at": raw.get("last_request_at") if isinstance(raw.get("last_request_at"), (int, float)) else None}


def _save_meta(root, meta):
    meta = dict(meta, requests=meta["requests"][-REQUESTS_KEPT:])
    _write_json(os.path.join(store_dir(root), "meta.json"), meta)
    _touch(root)


def _request(meta, rid, op=None, tile_id=None, phase=None, detail=None, now=0):
    """Create (op given) or move the request ring's entry for `rid`: queued|working|done|failed."""
    entry = next((r for r in meta["requests"] if r.get("rid") == rid), None)
    if entry is None:
        entry = {"rid": rid, "op": op, "tile_id": tile_id, "phase": "queued", "detail": None, "at": int(now)}
        meta["requests"].append(entry)
    if phase is not None:
        entry["phase"], entry["detail"] = phase, detail
    return entry


def _new_tile(f, now):
    return {"tile_id": f["tile_id"], "dashboard_id": f["dashboard_id"], "screen_id": f["screen_id"], "intent": f["text"],
            "shape": f.get("shape"), "refresh_s": f.get("refresh_s", REFRESH_DEFAULT_S),
            "origin": "import" if f.get("origin") == "import" else "phone", "author": f.get("author"), "rev": 1, "proposal": None,
            "fingerprint": None, "confirmed_fp": None, "phase": "generating", "detail": None, "last_ok_at": None, "history": [],
            "panel": None, "panel_rev": 0, "pending_at": None, "refresh_requested_at": None, "created_at": int(now)}


# -- fingerprint, confirmation code, proposal --------------------------------------------------------------------
def fingerprint_of(producer):
    """sha256 over kind, connector, statement and columns, NUL-separated (none of them may hold a NUL): the one value a
    confirmation pins. Any change to the statement, the connector, the kind or the columns is a different fingerprint."""
    parts = [producer["kind"], producer["connector"], producer["statement"], json.dumps(producer["columns"], ensure_ascii=False, separators=(",", ":"))]
    return hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()


def confirm_code(tile_id, fingerprint):
    """The six digits the phone shows and the person types at the laptop (spec 5.5): uint32_be of the first four bytes of
    sha256("hmd-dash-confirm-v1\\0" || tile_id || "\\0" || fingerprint), mod 10^6, zero-padded."""
    digest = hashlib.sha256(b"hmd-dash-confirm-v1\0" + tile_id.encode("utf-8") + b"\0" + fingerprint.encode("utf-8")).digest()
    return "%06d" % (int.from_bytes(digest[:4], "big") % 1000000)


def _clean_proposal(proposal):
    """The closed schema of a generator's output, or ValueError. Safety of the STATEMENT is the runtime's check (DD5), not this one."""
    if not isinstance(proposal, dict) or set(proposal) != {"shape", "producer"} or not _valid_shape(proposal["shape"]):
        raise ValueError("proposal")
    p = proposal["producer"]
    if not isinstance(p, dict) or set(p) != {"kind", "connector", "statement", "columns"} or p["kind"] != "sql":
        raise ValueError("producer")
    if not (isinstance(p["connector"], str) and CONNECTOR_RE.fullmatch(p["connector"])
            and isinstance(p["statement"], str) and 0 < len(p["statement"].encode("utf-8", "replace")) <= 8192 and "\0" not in p["statement"]
            and isinstance(p["columns"], list) and len(p["columns"]) <= 32
            and all(isinstance(c, str) and 0 < len(c) <= 64 and "\0" not in c for c in p["columns"])):
        raise ValueError("producer")
    return {"shape": dict(proposal["shape"]),
            "producer": {"kind": "sql", "connector": p["connector"], "statement": p["statement"], "columns": list(p["columns"])}}


def _label(tile):
    producer = (tile.get("proposal") or {}).get("producer") if isinstance(tile.get("proposal"), dict) else None
    name = producer.get("connector") if isinstance(producer, dict) else None
    if not isinstance(name, str):
        return None
    label = "".join(ch for ch in name if ch.isprintable())[:LABEL_MAX - len(" (read-only)")].strip() + " (read-only)"
    return LABEL_FALLBACK if _panels().secret_shaped(label) or label.startswith("/") else label


# -- audit -------------------------------------------------------------------------------------------------------
def audit_event(root, op, tile_id, ok, detail, device="local", via="local"):
    """One controls-audit.jsonl line for something that happened here and not in a sealed command: a confirmation, a decline, an
    expiry, a run failure, an idle pause. Ids and fixed tokens only -- never the text, the statement, a rid or a setting."""
    ctl = _ctl()
    if ctl is None:
        return
    now = time.time()
    ctl.audit(root, {"ts": ctl.iso(now), "device": device, "seq": None, "action": ACTION, "op": op, "tile_id": tile_id, "params": {},
                     "ok": bool(ok), "detail": detail if detail in DETAILS else None, "ms": 0, "via": via})


# -- request handling (the registered action) --------------------------------------------------------------------
class _Bucket:
    def __init__(self, capacity, per_s):
        self.capacity, self.per_s, self.tokens, self.at = float(capacity), per_s, float(capacity), time.monotonic()

    def wait(self, now):
        self.tokens = min(self.capacity, self.tokens + max(0.0, now - self.at) * self.per_s)
        self.at = max(self.at, now)
        return 0.0 if self.tokens >= 1.0 else (1.0 - self.tokens) / self.per_s


_BUCKETS = {}
_BLOCK = threading.Lock()
_TILE_REFRESH = {}                      # (root, tile_id) -> time.monotonic() of the last refresh


def _take(root, name, capacity, per_s):
    """0.0 once a token is taken from this repo's bucket, else the seconds until there is one (nothing taken)."""
    now = time.monotonic()
    with _BLOCK:
        bucket = _BUCKETS.setdefault((root, name), _Bucket(capacity, per_s))
        wait = bucket.wait(now)
        if wait <= 0:
            bucket.tokens -= 1.0
        return wait


def _limited(wait):
    return False, "rate-limited", {"retry_after_s": max(1, int(math.ceil(wait)))}


def project_names(root):
    """What `project` may be: the repo's basename as the phone's sessionIdentity derives it (last non-empty path segment), for
    the path as the client was given it and for its realpath."""
    names = set()
    for path in (root, os.path.realpath(root)):
        segments = [s for s in path.split("/") if s]
        if segments:
            names.add(segments[-1])
    return names


def _expire(root, meta, now):
    """Persist the 24 h expiry of unconfirmed proposals (caller holds the lock). Returns the expired tile ids."""
    gone = []
    for tile in _all_tiles(root):
        if tile["phase"] == "needs-confirm" and _pending_over(tile, now):
            tile.update(phase="error", detail="expired", pending_at=None)
            _write_tile(root, tile)
            audit_event(root, "expire", tile["tile_id"], False, "expired")
            gone.append(tile["tile_id"])
    return gone


def _pending_over(tile, now):
    return not isinstance(tile.get("pending_at"), (int, float)) or now - tile["pending_at"] > PENDING_TTL_S


def _reap_in_flight(root, meta, now):
    job = meta["in_flight"]
    if job is not None and now - job.get("started_at", 0) > GENERATION_TIMEOUT_S:
        _fail_unlocked(root, meta, job["tile_id"], job["rid"], "timeout", now)


def _fail_unlocked(root, meta, tile_id, rid, detail, now):
    detail = detail if detail in GENERATION_DETAILS else "generation-failed"
    _request(meta, rid, phase="failed", detail=detail, now=now)
    if meta["in_flight"] is not None and meta["in_flight"].get("rid") == rid:
        meta["in_flight"] = None
    tile = _find(root, tile_id)
    if tile is not None and tile["phase"] == "generating":
        tile.update(phase="error", detail=detail)
        _write_tile(root, tile)


def _gen_gate(root, meta, now):
    """The refusals every create/refine shares, cheapest first: a full queue, the day's cap, the bucket."""
    if len(meta["queue"]) >= QUEUE_MAX:
        return False, "busy", {}
    day = time.strftime("%Y-%m-%d", time.gmtime(now))
    if meta["daily"]["day"] == day and meta["daily"]["n"] >= DAILY_MAX:
        return False, "daily-limit", {}
    wait = _take(root, "generate", 3, 6 / 60.0)
    return _limited(wait) if wait > 0 else None


def _enqueue(meta, f, rid, tile_id, now):
    day = time.strftime("%Y-%m-%d", time.gmtime(now))
    meta["daily"] = {"day": day, "n": (meta["daily"]["n"] if meta["daily"]["day"] == day else 0) + 1}
    meta["queue"].append({"rid": rid, "op": f["op"], "tile_id": tile_id, "dashboard_id": f["dashboard_id"], "text": f["text"],
                          "shape": f.get("shape"), "refresh_s": f.get("refresh_s"), "origin": f.get("origin"), "author": f.get("author"), "at": int(now)})
    _request(meta, rid, f["op"], tile_id, "queued", None, now)


def _of_dashboard(root, f):
    return [t for t in _all_tiles(root) if t["dashboard_id"] == f["dashboard_id"]]


def _do_create(root, meta, f, rid, now):
    existing = _find(root, f["tile_id"])
    if existing is not None:
        if existing["dashboard_id"] != f["dashboard_id"] or existing["screen_id"] != f["screen_id"]:
            return False, "bad-params", {}
        if existing["phase"] != "error":              # a second create of a tile hmd already holds changes nothing
            _request(meta, rid, "create", f["tile_id"], "done", None, now)
            return True, "dup", {"id": f["tile_id"]}
    elif len(_all_tiles(root)) >= MAX_TILES:
        return False, "too-many-tiles", {}
    refusal = _gen_gate(root, meta, now)
    if refusal is not None:
        return refusal
    if existing is None:
        _write_tile(root, _new_tile(f, now))
    else:                                              # a failed tile asked for again: same ids, new words, a new generation
        existing.update(intent=f["text"], phase="generating", detail=None, refresh_s=f.get("refresh_s", existing["refresh_s"]))
        _write_tile(root, existing)
    _enqueue(meta, f, rid, f["tile_id"], now)
    return True, "queued", {"id": f["tile_id"]}


def _do_refine(root, meta, f, rid, now):
    tile = _read_tile(root, f["dashboard_id"], f["tile_id"])
    if tile is None:
        return False, "unknown-tile", {}
    refusal = _gen_gate(root, meta, now)
    if refusal is not None:
        return refusal
    tile["history"] = (tile["history"] + [{"rev": tile["rev"], "intent": tile["intent"], "fingerprint": tile["fingerprint"]}])[-HISTORY_KEPT:]
    tile.update(rev=tile["rev"] + 1, intent=f["text"], phase="generating", detail=None, refresh_s=f.get("refresh_s", tile["refresh_s"]))
    _write_tile(root, tile)
    _enqueue(meta, f, rid, f["tile_id"], now)
    return True, "queued", {"id": f["tile_id"]}


def _do_set_refresh(root, meta, f, rid, now):
    tile = _read_tile(root, f["dashboard_id"], f["tile_id"])
    if tile is None:
        return False, "unknown-tile", {}
    tile["refresh_s"] = f["refresh_s"]
    if isinstance(tile.get("panel"), dict):
        tile["panel"]["refresh_s"] = f["refresh_s"]
    _write_tile(root, tile)
    _request(meta, rid, "set-refresh", f["tile_id"], "done", None, now)
    return True, "queued", {"id": f["tile_id"]}


def _targets(root, f):
    if "tile_id" in f:
        tile = _read_tile(root, f["dashboard_id"], f["tile_id"])
        return None if tile is None else [tile]
    return _of_dashboard(root, f)


def _do_refresh(root, meta, f, rid, now):
    tiles = _targets(root, f)
    if tiles is None:
        return False, "unknown-tile", {}
    mono = time.monotonic()
    due = [t for t in tiles if mono - _TILE_REFRESH.get((root, t["tile_id"]), -1e9) >= REFRESH_TILE_GAP_S]
    if tiles and not due:
        wait = min(REFRESH_TILE_GAP_S - (mono - _TILE_REFRESH.get((root, t["tile_id"]), -1e9)) for t in tiles)
        return _limited(wait)
    wait = _take(root, "refresh", 12, 12 / 60.0)
    if wait > 0:
        return _limited(wait)
    for tile in due:
        _TILE_REFRESH[(root, tile["tile_id"])] = mono
        runnable = tile["fingerprint"] is not None and tile["fingerprint"] == tile["confirmed_fp"]
        if tile["phase"] == "paused" and runnable:     # the one thing that resumes an idle or backed-off tile
            tile.update(phase="live", detail=None)
        tile["refresh_requested_at"] = now
        _write_tile(root, tile)
    _request(meta, rid, "refresh", f.get("tile_id"), "done", None, now)
    return True, "queued", ({"id": f["tile_id"]} if "tile_id" in f else {})


def _do_remove(root, meta, f, rid, now):
    tiles = _targets(root, f)
    if tiles is None:
        return False, "unknown-tile", {}
    gone = {t["tile_id"] for t in tiles}
    for tile in tiles:
        with contextlib.suppress(OSError):
            os.unlink(_tile_path(root, tile["dashboard_id"], tile["tile_id"]))
        _TILE_REFRESH.pop((root, tile["tile_id"]), None)
    meta["queue"] = [j for j in meta["queue"] if j.get("tile_id") not in gone]
    _request(meta, rid, "remove", f.get("tile_id"), "done", None, now)
    return True, "queued", ({"id": f["tile_id"]} if "tile_id" in f else {})


_HANDLERS = {"create": _do_create, "refine": _do_refine, "set-refresh": _do_set_refresh, "refresh": _do_refresh, "remove": _do_remove}


def handle(root, fields, ctx=None):
    """The registered action's handler: (ok, detail, extra). The dispatcher already did the kill switch, the laptop switch, the
    exact params, the rid replay and the action's own bucket; this is the project check, the per-op limits and the store."""
    if fields["project"] not in project_names(root):
        return False, "wrong-project", {}
    now = time.time()
    try:
        with _locked(root):
            meta = _load_meta(root)
            meta["last_request_at"] = now                 # presence: a phone that talks to hmd is a phone that is watching
            _expire(root, meta, now)
            _reap_in_flight(root, meta, now)
            result = _HANDLERS[fields["op"]](root, meta, fields, fields["rid"], now)
            _save_meta(root, meta)
            return result
    except OSError:
        return False, "internal-error", {}


def audit_rule(fields):
    return {"op": fields["op"], "tile_id": fields.get("tile_id")}


def register_actions(kit):
    """Called by companion_ui_controls at import with its registration kit: puts `dashboard-request` on the allowlist. Not
    registered when the panel validator cannot load -- there is then nothing a tile could be published through."""
    global _KIT
    try:
        _panels()
    except RuntimeError:
        return
    _KIT = kit

    def fields(body):
        try:
            return parse_params(body)
        except ValueError:
            raise kit.Refusal("bad-params")

    every = sorted({k for required, optional in _OPS.values() for k in required + optional})
    kit.register_action(ACTION, cls=kit.CLASS_EXPAND, switch=SWITCH, handler=handle, required=("op",), optional=tuple(every),
                        fields=fields, audit=audit_rule, rate=((6, 20 / 60.0),), usable=lambda root: True,
                        policy={"cap": CAP_DASH, "rid_re": RID_RE, "replay_detail": "dup", "global_rate": False,
                                "off_detail": "dashboards-off", "open_switch": True, "timeline_ops": TIMELINE_OPS})


# -- the interface the producer side calls -----------------------------------------------------------------------
def get_tile(root, tile_id):
    """A tile's full record (proposal included -- for the laptop's own `hmd dash show`), or None."""
    return _find(root, tile_id)


def list_tiles(root):
    return _all_tiles(root)


def claim_generation(root, now=None):
    """The next queued create/refine, marked working (one in flight per repo), or None. See INTERFACE in the module docstring."""
    now = time.time() if now is None else now
    with _locked(root):
        meta = _load_meta(root)
        _reap_in_flight(root, meta, now)
        job = None
        while meta["in_flight"] is None and meta["queue"] and job is None:
            candidate = meta["queue"].pop(0)
            if _find(root, candidate["tile_id"]) is None:        # removed while it waited
                _request(meta, candidate["rid"], phase="failed", detail="generation-failed", now=now)
                continue
            job = candidate
        if job is None:
            _save_meta(root, meta)
            return None
        meta["in_flight"] = dict(job, started_at=now)
        _request(meta, job["rid"], phase="working", now=now)
        _save_meta(root, meta)
        context = [{"intent": t["intent"], "shape": t.get("shape")} for t in _all_tiles(root)
                   if t["dashboard_id"] == job["dashboard_id"] and t["tile_id"] != job["tile_id"]]
        return dict(job, context=context)


def register_proposal(root, tile_id, rid, proposal, now=None):
    """Store a generator's proposal; (True, None), or (False, <detail>) when it was refused -- the request is then failed."""
    now = time.time() if now is None else now
    with _locked(root):
        meta = _load_meta(root)
        tile = _find(root, tile_id)
        if tile is None:
            return False, "unknown-tile"
        try:
            clean = _clean_proposal(proposal)
        except ValueError:
            _fail_unlocked(root, meta, tile_id, rid, "generation-failed", now)
            _save_meta(root, meta)
            return False, "generation-failed"
        fp = fingerprint_of(clean["producer"])
        tile.update(proposal=clean, fingerprint=fp, shape=clean["shape"], detail=None)
        if tile["confirmed_fp"] == fp:                           # a refine that left the producer as it was needs nothing
            tile.update(phase="live", pending_at=None)
        else:
            tile.update(phase="needs-confirm", pending_at=now)
        _write_tile(root, tile)
        _request(meta, rid, phase="done", now=now)
        if meta["in_flight"] is not None and meta["in_flight"].get("rid") == rid:
            meta["in_flight"] = None
        _save_meta(root, meta)
        return True, None


def fail_generation(root, tile_id, rid, detail, now=None):
    now = time.time() if now is None else now
    with _locked(root):
        meta = _load_meta(root)
        _fail_unlocked(root, meta, tile_id, rid, detail, now)
        _save_meta(root, meta)


def _runnable(tile):
    return (tile["fingerprint"] is not None and tile["fingerprint"] == tile["confirmed_fp"] and isinstance(tile.get("proposal"), dict)
            and (tile["phase"] in ("live", "generating")
                 or (tile["phase"] == "error" and tile["detail"] in ("producer-failed", "rejected-panel"))))


def confirmed_producers(root):
    """EXACTLY the tiles allowed to run now. Never a tile whose fingerprint is not the confirmed one, never a paused, declined,
    expired or still-unconfirmed one."""
    return [{"tile_id": t["tile_id"], "dashboard_id": t["dashboard_id"], "refresh_s": t["refresh_s"], "shape": t.get("shape"),
             "producer": json.loads(json.dumps(t["proposal"]["producer"])), "fingerprint": t["fingerprint"], "phase": t["phase"],
             "detail": t["detail"], "last_ok_at": t.get("last_ok_at"), "refresh_requested_at": t.get("refresh_requested_at")}
            for t in _all_tiles(root) if _runnable(t)]


def phone_present(root, idle_s=IDLE_S, now=None):
    now = time.time() if now is None else now
    if idle_s <= 0:
        return True
    last = _load_meta(root)["last_request_at"]
    return last is not None and now - last <= idle_s


def set_tile_status(root, tile_id, phase, detail=None, now=None):
    """The runtime's word about a tile it ran or paused: live | error (producer-failed, timeout) | paused (idle, backoff). False for
    an unknown tile, an unrecognised pair, or a tile that may not run (nothing here can un-pause or un-decline a tile)."""
    if detail not in STATUS_DETAILS.get(phase, ()):
        return False
    with _locked(root):
        tile = _find(root, tile_id)
        if tile is None or not (_runnable(tile) or (tile["phase"] == "paused" and tile["fingerprint"] == tile["confirmed_fp"])):
            return False
        tile.update(phase=phase, detail=detail)
        _write_tile(root, tile)
        _touch(root)
        if phase == "error" or (phase == "paused" and detail == "idle"):
            audit_event(root, "run-failed" if phase == "error" else "idle-pause", tile_id, False, detail)
        return True


def publish_panel(root, tile_id, candidate, now=None, panel_bytes=PANEL_BYTES):
    """DD3: publish a producer's result as the tile's panel, through the SAME validator a job panel goes through (closed type set,
    per-type data shape, `source` anywhere refuses the whole panel, the secret scrub of the title and every string leaf, the
    list / string / series caps) plus one stricter budget, `panel_bytes`. (True, None) on success. A refused result keeps the
    previous good panel, sets error / rejected-panel and logs the failing FIELD to stderr, never its value."""
    now = time.time() if now is None else now
    panels = _panels()
    with _locked(root):
        tile = _find(root, tile_id)
        if tile is None:
            return False, "unknown-tile"
        if tile["fingerprint"] is None or tile["fingerprint"] != tile["confirmed_fp"]:
            return False, "unconfirmed"                         # belt and braces: the runtime never runs it either
        try:
            if not isinstance(candidate, dict):
                raise panels.PanelError("result is not an object")
            body = dict(candidate, id=tile_id, refresh_s=tile["refresh_s"], updated_at=now)
            panel = panels.validate_panel(body)
            stored = {"id": tile_id, "title": panel["title"], "type": panel["type"], "data": panel["data"],
                      "refresh_s": tile["refresh_s"], "updated_at": int(now)}
            size = len(json.dumps(stored, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
            if size > panel_bytes:
                raise panels.PanelError("panel serialises to %d bytes; the dashboard budget is %d" % (size, panel_bytes))
        except Exception as e:   # PanelError names the field; any other type is reported by type only
            reason = str(e) if isinstance(e, panels.PanelError) else type(e).__name__
            sys.stderr.write("companion_dashboards: tile %s: panel rejected: %s\n" % (tile_id, reason))
            tile.update(phase="error", detail="rejected-panel")
            _write_tile(root, tile)
            _touch(root)
            return False, "rejected-panel"
        tile.update(panel=stored, panel_rev=tile["panel_rev"] + 1, last_ok_at=int(now), phase="live", detail=None)
        _write_tile(root, tile)
        _touch(root)
        return True, None


def pending_confirmations(root, now=None):
    """The tiles waiting for the person at the laptop, with the FULL proposal (statement included): `hmd dash pending`."""
    now = time.time() if now is None else now
    return [{"tile_id": t["tile_id"], "dashboard_id": t["dashboard_id"], "origin": t["origin"], "author": t.get("author"),
             "intent": t["intent"], "shape": t.get("shape"), "producer": t["proposal"]["producer"], "fingerprint": t["fingerprint"],
             "age_s": int(now - t["pending_at"]), "expires_at": int(t["pending_at"] + PENDING_TTL_S)}
            for t in _all_tiles(root) if t["phase"] == "needs-confirm" and isinstance(t.get("proposal"), dict)
            and not _pending_over(t, now)]


def confirm_tile(root, tile_id, fingerprint, now=None):
    """Pin `fingerprint` as the tile's confirmed producer. (True, None) or (False, why): unknown-tile | not-pending | expired |
    fingerprint-changed. The CALLER (`hmd dash confirm`) has already required a TTY and the code; nothing in a sealed command does."""
    now = time.time() if now is None else now
    with _locked(root):
        tile = _find(root, tile_id)
        if tile is None:
            return False, "unknown-tile"
        if tile["phase"] != "needs-confirm":
            return False, "expired" if tile["detail"] == "expired" else "not-pending"
        if _pending_over(tile, now):
            return False, "expired"
        if fingerprint != tile["fingerprint"]:
            return False, "fingerprint-changed"
        tile.update(confirmed_fp=fingerprint, phase="live", detail=None, pending_at=None, refresh_requested_at=now)
        _write_tile(root, tile)
        _touch(root)
        audit_event(root, "confirm", tile_id, True, None)
        return True, None


def decline_tile(root, tile_id, now=None):
    with _locked(root):
        tile = _find(root, tile_id)
        if tile is None or tile["phase"] != "needs-confirm":
            return False
        tile.update(phase="error", detail="declined", pending_at=None)
        _write_tile(root, tile)
        _touch(root)
        audit_event(root, "decline", tile_id, False, "declined")
        return True


def expire_pending(root, now=None):
    now = time.time() if now is None else now
    with _locked(root):
        gone = _expire(root, _load_meta(root), now)
        if gone:
            _touch(root)
        return gone


# -- the state slice ---------------------------------------------------------------------------------------------
def _stale(panel, now):
    return now - panel["updated_at"] > _panels().stale_after(panel.get("refresh_s"))


def _row(tile, now, phone):
    phase, detail = tile["phase"], tile["detail"]
    if phase == "needs-confirm" and _pending_over(tile, now):     # expired but not yet persisted: never show a dead code
        phase, detail = "error", "expired"
    panel = tile.get("panel") if isinstance(tile.get("panel"), dict) else None
    row = {"dashboard_id": tile["dashboard_id"], "screen_id": tile["screen_id"], "tile_id": tile["tile_id"], "intent": tile["intent"],
           "origin": tile["origin"], "rev": tile["rev"], "refresh_s": tile["refresh_s"], "phase": phase, "detail": detail,
           "producer_label": _label(tile), "confirm": None, "last_ok_at": tile.get("last_ok_at"), "panel": None}
    if phase == "needs-confirm":
        expires = int(tile["pending_at"] + PENDING_TTL_S)
        row["confirm"] = {"code": confirm_code(tile["tile_id"], tile["fingerprint"]), "expires_at": expires} if phone else {"expires_at": expires}
    if panel is not None:
        if phone:
            row["panel"] = dict(panel, stale=_stale(panel, now))
        else:                                                     # the laptop view: a signature moves the digest, the numbers stay put
            row["panel_sig"] = hashlib.sha256(json.dumps(panel, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()[:12]
            row["stale"] = _stale(panel, now)
    return row


def snapshot(root, now=None, phone=True, redact=None):
    """The `dashboards` key: the phone's slice (phone=True, codes and panels in) or the laptop view for the base state. `redact`
    is the relay's redaction profile, applied before the size is judged. Held under SLICE_BYTES: past it the panels of the least
    recently updated tiles go (the rows stay, `panel` null, `detail` budget)."""
    now = time.time() if now is None else now
    out = {"v": 1, "enabled": enabled(root), "limits": dict(LIMITS), "tiles": [], "requests": []}
    if not out["enabled"]:
        return out
    meta = _load_meta(root)
    out["tiles"] = [_row(t, now, phone) for t in _all_tiles(root)]
    out["requests"] = [{"rid": r.get("rid"), "op": r.get("op"), "tile_id": r.get("tile_id"), "phase": r.get("phase"),
                        "detail": r.get("detail"), "at": r.get("at")} for r in meta["requests"] if RID_RE.fullmatch(str(r.get("rid")))]
    if not phone:
        out["pending"] = sum(1 for t in out["tiles"] if t["phase"] == "needs-confirm")
    if redact is not None:
        out = redact(out)
    while len(json.dumps(out, separators=(",", ":")).encode("utf-8")) >= SLICE_BYTES:
        held = [t for t in out["tiles"] if t.get("panel")]
        if not held:
            break
        oldest = min(held, key=lambda t: t["panel"]["updated_at"])
        oldest["panel"], oldest["detail"] = None, "budget"
    return out


def overlay(state, root, device_caps, redact=None):
    """`state` as ONE phone must see it (a copy): the laptop view of `dashboards` replaced by the phone's slice when it listed
    dash-v1, the key dropped when it did not -- an old app never sees a key it does not know."""
    listed = isinstance(device_caps, (set, frozenset, list, tuple)) and CAP_DASH in device_caps
    if not listed and "dashboards" not in state:
        return state
    out = {k: v for k, v in state.items() if k != "dashboards"}
    if listed:
        out["dashboards"] = snapshot(root, phone=True, redact=redact)
    return out


# -- `hmd app status` --------------------------------------------------------------------------------------------
def status_line(root):
    if not enabled(root):
        return "remote dashboards: off"
    tiles = _all_tiles(root)
    pending = sum(1 for t in tiles if t["phase"] == "needs-confirm" and not _pending_over(t, time.time()))
    return "remote dashboards: on · %d tile%s · %d pending" % (len(tiles), "" if len(tiles) == 1 else "s", pending)


def main(argv):
    root = os.getcwd()
    args = list(argv)
    if args and args[0] == "status-line":
        if "--repo" in args and args.index("--repo") + 1 < len(args):
            root = args[args.index("--repo") + 1]
        print(status_line(os.path.realpath(os.path.expanduser(root))))
        return 0
    sys.stderr.write("usage: companion_dashboards.py status-line [--repo DIR]\n")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)

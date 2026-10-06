#!/usr/bin/env python3
"""dashboard_alerts.py -- threshold alerts on a number tile, evaluated on the LAPTOP (hmdapp docs/HANDOFF-TO-HEIMDALL-watch.md H1; H2 is the
push kind `tile_alert` this module registers into bin/lib/companion_push.py).

WIRE (cap `dash-alert-v1`, which REQUIRES `dash-v1`: two more ops on the sealed `dashboard-request`, same envelope, exact key sets, an extra
key is `bad-params`, plaintext <= 1 KiB, `rid` `q-<8 hex>` required). A phone that did not list `dash-alert-v1` is `caps-missing`:

    set-alert    rid op dashboard_id tile_id project cmp value hold_s with_value
                 cmp "lt"|"le"|"gt"|"ge"; value a finite number, abs <= 1e15; hold_s an int 0..3600; with_value a bool
    clear-alert  rid op dashboard_id tile_id project

Ack `{of_seq, ok, detail, id?, retry_after_s?}`: ok:true detail "queued" (id = the tile id; clearing a tile with no alert is the same ok).
Refusals (ok:false, detail): caps-missing, bad-params, wrong-project, alerts-off (the laptop switch `hmd app remote-alerts on`, off by
default; clear-alert is exempt -- it only removes), push-off (HMD_PUSH=0, or no registered device asked for the kind `tile_alert`),
not-a-number-tile (the tile's panel.type, else its shape, is not `number`), too-many-alerts (10 per project; changing the alert of a tile
that already has one is not a new alert), unknown-tile, rate-limited (+ retry_after_s; 6 ops, refilled at 6 a minute).

STATE, only in the frames of a phone that listed `dash-alert-v1` (companion_dashboards.overlay): `tiles[].alert = {cmp, value, hold_s,
with_value, armed, last_checked_at, last_fired_at, paused}` -- exactly those eight keys, `paused` null | "idle" | "backoff", the key absent
on a tile with no alert. The phone shows "checked N min ago" from last_checked_at; a sleeping laptop evaluates nothing and the phone says so.

EVALUATION. After every SUCCESSFUL producer run of an alerted tile (companion_dashboards.publish_panel calls evaluate()), on
panel.data.value when it is a finite number (a string, a bool, a missing value: never). The condition must have held on consecutive runs
spanning at least hold_s. It fires on the false-to-true edge only: a new alert is `armed` only after a run that saw the condition false (or
when the value was already false as it was set); it re-arms on a run that sees the condition false when at least 60 min have passed since the
last push; at most 6 pushes a UTC day per alert (the seventh crossing is dropped, not queued). A failed run never reaches evaluate(): it
neither fires nor re-arms nor counts toward the hold. IDLE: an alerted tile is exempt from the 12 h no-phone pause of the dashboards
spec (companion_dashboards.alerted_tiles -> dashboard_producers.Scheduler.tick), at a floor interval of 300 s while no phone is present;
alerts pause after 30 days without phone contact (`paused:"idle"`, nothing evaluated).

PUSH. A fire hands ONE event of kind `tile_alert` to companion_push.enqueue_event (the sender-lock owner serves it; this process never
sends). The body is fixed unless `with_value`, then "<value>, limit <limit>" formatted here, scrubbed, <= 40 characters. Nothing else
about the tile or the value is in the event. AUDIT (controls-audit.jsonl, ids and fixed tokens only, never a value or a threshold):
`alert-set` / `alert-clear` (the sealed command's own line), `alert-fired`, `alert-refused` (+ the detail).

STORE. <repo>/.heimdall/ui/dashboards/alerts.json (0600, beside the tiles; `alerts.lock` flock; companion_dashboards' helpers write it,
nested INSIDE the dashboards lock when both are held -- always in that order). Definitions and arm state only: no panel, no frame data.

Stdlib only. Every function takes `kit` first: the helper namespace companion_dashboards builds (store_dir, read_json, write_json, mkdir,
touch, find, read_tile, enabled, audit, take, last_request_at) -- so this module never loads a second copy of the store.
"""
import contextlib
import fcntl
import json
import math
import os
import time
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))

CAP_ALERTS = "dash-alert-v1"
PUSH_CAP = "push-tile-alert-v1"
KIND = "tile_alert"
SWITCH = "alerts"
CMPS = ("lt", "le", "gt", "ge")
MAX_ALERTS, HOLD_MAX_S, VALUE_MAX = 10, 3600, 1e15
REARM_GAP_S, DAILY_MAX, IDLE_FLOOR_S, PAUSE_IDLE_S = 3600.0, 6, 300.0, 30 * 86400.0
OP_RATE = (6, 6 / 60.0)
BODY_FIXED = "A tile you watch crossed its limit. Open to see it."
VALUE_BODY_MAX = 40

OPS = {"set-alert": (("dashboard_id", "tile_id", "project", "cmp", "value", "hold_s", "with_value"), ()),
       "clear-alert": (("dashboard_id", "tile_id", "project"), ())}
AUDIT_OP = {"set-alert": "alert-set", "clear-alert": "alert-clear"}
_MODULES = {}


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


def _num(v):
    """`v` as a finite number, else None (a bool, a string, NaN and an out-of-range value are never a number here)."""
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) and abs(v) <= VALUE_MAX and math.isfinite(v) else None


CHECKS = {"cmp": lambda v: isinstance(v, str) and v in CMPS, "value": lambda v: _num(v) is not None,
          "hold_s": lambda v: isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= HOLD_MAX_S,
          "with_value": lambda v: isinstance(v, bool)}


# -- the pure part -----------------------------------------------------------------------------------------------
def holds(cmp, value, limit):
    return {"lt": value < limit, "le": value <= limit, "gt": value > limit, "ge": value >= limit}[cmp]


def step(alert, value, now):
    """(alert', fire) for one successful run that read `value` at `now`: the whole edge / hold / re-arm / daily-cap rule, no I/O."""
    a = dict(alert, fired=dict(alert.get("fired") or {"day": "", "n": 0}))
    a["last_checked_at"], fire = int(now), False
    if holds(a["cmp"], value, a["value"]):
        if a.get("true_since") is None:
            a["true_since"] = now
        if a["armed"] and now - a["true_since"] >= a["hold_s"]:
            a["armed"] = False                               # the edge is consumed whether or not the push goes out
            day = time.strftime("%Y-%m-%d", time.gmtime(now))
            if a["fired"].get("day") != day:
                a["fired"] = {"day": day, "n": 0}
            if a["fired"]["n"] < DAILY_MAX:
                a["fired"]["n"] += 1
                a["last_fired_at"], fire = int(now), True
    else:
        a["true_since"] = None
        last = a.get("last_fired_at")
        if not a["armed"] and (last is None or now - last >= REARM_GAP_S):
            a["armed"] = True
    return a, fire


def fmt_value(value, fmt=None):
    """A number as the push body may say it (grouped digits, 1.2M past a million, 4m 12s, 1.2 GB, 63%)."""
    n = float(value)

    def trim(x):
        return ("%d" % x) if x == int(x) else ("%.2f" % x).rstrip("0").rstrip(".")
    if fmt == "percent":
        return trim(n) + "%"
    if fmt == "duration_s":
        h, rest = divmod(int(abs(n)), 3600)
        m, s = divmod(rest, 60)
        return ("-" if n < 0 else "") + ("%dh %02dm" % (h, m) if h else "%dm %02ds" % (m, s) if m else "%ds" % s)
    if fmt == "bytes":
        size, unit = abs(n), "B"
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if size < 1024 or unit == "TB":
                break
            size /= 1024.0
        return ("-" if n < 0 else "") + (trim(round(size, 1)) + " " + unit)
    for limit, suffix in ((1e9, "B"), (1e6, "M")):
        if abs(n) >= limit:
            return trim(round(n / limit, 1)) + suffix
    return "{:,}".format(int(n)) if n == int(n) else "{:,.2f}".format(n).rstrip("0").rstrip(".")


def register_push_kinds(kit):
    """companion_push's registration hook: the kind `tile_alert` and its constants (H2 table: title "<label> · tile alert", channel
    hmd-attention, no category, level active, ttl 3600, collapseId "<tile hash>.alert")."""
    def body(fields):
        if fields.get("with_value") is True:
            value, limit = fields.get("value_text"), fields.get("limit_text")
            if isinstance(value, str) and isinstance(limit, str) and value and limit:
                text = "%s, limit %s" % (value, limit)
                if len(text) <= VALUE_BODY_MAX and kit.scrub(text, VALUE_BODY_MAX) == text:
                    return text
        return BODY_FIXED
    kit.register_kind(KIND, phrase="tile alert", channel="hmd-attention", level="active", ttl=3600, cap=PUSH_CAP, priority=3,
                      body=body, suffix="alert", scope=lambda fields: "tile:%s" % fields.get("tile"))


# -- the store ---------------------------------------------------------------------------------------------------
def _path(kit, root):
    return os.path.join(kit.store_dir(root), "alerts.json")


@contextlib.contextmanager
def _alock(kit, root):
    directory = kit.store_dir(root)
    kit.mkdir(directory)
    fd = os.open(os.path.join(directory, "alerts.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _valid(a):
    return (isinstance(a, dict) and a.get("cmp") in CMPS and _num(a.get("value")) is not None and isinstance(a.get("armed"), bool)
            and isinstance(a.get("hold_s"), int) and not isinstance(a.get("hold_s"), bool) and isinstance(a.get("with_value"), bool)
            and isinstance(a.get("dashboard_id"), str) and isinstance(a.get("created_at"), (int, float)))


def _load(kit, root):
    raw = (kit.read_json(_path(kit, root)) or {}).get("alerts")
    return {t: a for t, a in raw.items() if isinstance(t, str) and _valid(a)} if isinstance(raw, dict) else {}


def _save(kit, root, alerts):
    kit.write_json(_path(kit, root), {"v": 1, "alerts": alerts})
    kit.touch(root)


def _switch_on():
    sw = _sibling("companion_remote_switches")
    return sw is not None and sw.switch_enabled(SWITCH)


def enabled(kit, root):
    """The laptop switch is on AND remote dashboards are enabled (alerts ride the dashboards' producers)."""
    return _switch_on() and kit.enabled(root)


def value_of(panel):
    """The finite number a number panel carries, else None."""
    data = panel.get("data") if isinstance(panel, dict) and panel.get("type") == "number" else None
    return _num(data.get("value")) if isinstance(data, dict) else None


def _push_ready(root):
    push = _sibling("companion_push")
    return push is not None and push.enabled() and push.devices_wanting(root, KIND) > 0


# -- the two ops -------------------------------------------------------------------------------------------------
def _refuse(kit, root, tile_id, detail, **extra):
    kit.audit(root, "alert-refused", tile_id, False, detail)
    return False, detail, extra


def handle(kit, root, f, ctx, now=None):
    """(ok, detail, extra) of set-alert / clear-alert (the caller, companion_dashboards.handle, already did the dashboards switch, the
    kill switch, the exact params, the rid replay and the project check): caps, switch, rate, tile, push, tile type, the 10-alert cap,
    then the store."""
    now = time.time() if now is None else now
    tile_id = f["tile_id"]
    caps = getattr(ctx, "caps", None)
    if caps is None or CAP_ALERTS not in caps:
        return False, "caps-missing", {}
    if f["op"] == "set-alert" and not enabled(kit, root):
        return _refuse(kit, root, tile_id, "alerts-off")
    wait = kit.take(root, "alert", *OP_RATE)
    if wait > 0:
        return _refuse(kit, root, tile_id, "rate-limited", retry_after_s=max(1, int(math.ceil(wait))))
    tile = kit.read_tile(root, f["dashboard_id"], tile_id)
    if tile is None:
        return _refuse(kit, root, tile_id, "unknown-tile")
    with _alock(kit, root):
        alerts = {t: a for t, a in _load(kit, root).items() if kit.find(root, t) is not None}     # an alert outlives no tile
        if f["op"] == "clear-alert":
            alerts.pop(tile_id, None)
            _save(kit, root, alerts)
            return True, "queued", {"id": tile_id}
        panel = tile.get("panel") if isinstance(tile.get("panel"), dict) else None
        kind = panel.get("type") if panel else (tile.get("shape") or {}).get("type")
        if kind != "number":
            return _refuse(kit, root, tile_id, "not-a-number-tile")
        if not _push_ready(root):
            return _refuse(kit, root, tile_id, "push-off")
        if tile_id not in alerts and len(alerts) >= MAX_ALERTS:
            return _refuse(kit, root, tile_id, "too-many-alerts")
        current = value_of(panel)
        alerts[tile_id] = {"dashboard_id": f["dashboard_id"], "cmp": f["cmp"], "value": f["value"], "hold_s": f["hold_s"],
                           "with_value": f["with_value"], "armed": current is not None and not holds(f["cmp"], current, f["value"]),
                           "true_since": None, "last_checked_at": None, "last_fired_at": None, "fired": {"day": "", "n": 0},
                           "created_at": int(now)}
        _save(kit, root, alerts)
    return True, "queued", {"id": tile_id}


# -- evaluation --------------------------------------------------------------------------------------------------
def evaluate(kit, root, tile_id, panel, now=None):
    """Called after a SUCCESSFUL producer run published `panel` for `tile_id`. True when an alert fired (its push was handed over)."""
    now = time.time() if now is None else now
    value = value_of(panel)
    if value is None or not enabled(kit, root):
        return False
    with _alock(kit, root):
        alerts = _load(kit, root)
        held = alerts.get(tile_id)
        if held is None or now - max(kit.last_request_at(root) or 0, held["created_at"]) > PAUSE_IDLE_S:
            return False
        alerts[tile_id], fire = step(held, value, now)
        _save(kit, root, alerts)
    if fire:
        kit.audit(root, "alert-fired", tile_id, True, None)
        _push(root, tile_id, held, panel, now)
    return fire


def _push(root, tile_id, alert, panel, now):
    """Hand the sender one `tile_alert` event, when some device asked for the kind. Numbers go in only when the alert opted in."""
    push = _sibling("companion_push")
    if push is None or not _push_ready(root):
        return False
    fields = {"tile": tile_id, "with_value": alert["with_value"]}
    if alert["with_value"]:
        fmt = (panel.get("data") or {}).get("format")
        fields.update(value_text=fmt_value(value_of(panel), fmt), limit_text=fmt_value(alert["value"], fmt))
    return push.enqueue_event(root, KIND, fields, key="a:%s:%d" % (tile_id, int(now)), now=now)


def alerted_tiles(kit, root, now=None):
    """The tile ids whose alert is live (switch on, not paused idle): exempt from the 12 h no-phone pause of the producers."""
    now = time.time() if now is None else now
    if not enabled(kit, root):
        return set()
    last = kit.last_request_at(root) or 0
    return {t for t, a in _load(kit, root).items() if now - max(last, a["created_at"]) <= PAUSE_IDLE_S}


def forget(kit, root, tile_ids):
    """Drop the alerts of tiles that were removed."""
    with _alock(kit, root):
        alerts = _load(kit, root)
        kept = {t: a for t, a in alerts.items() if t not in tile_ids}
        if len(kept) != len(alerts):
            _save(kit, root, kept)


def rows(kit, root, now, tiles):
    """{tile_id: the eight-key `alert` row} for the tiles that have an alert."""
    alerts = _load(kit, root)
    last = kit.last_request_at(root) or 0
    out = {}
    for tile in tiles:
        a = alerts.get(tile["tile_id"])
        if a is None or a["dashboard_id"] != tile["dashboard_id"]:
            continue
        paused = "idle" if now - max(last, a["created_at"]) > PAUSE_IDLE_S else \
            "backoff" if tile["phase"] == "paused" and tile["detail"] == "backoff" else None
        out[tile["tile_id"]] = {"cmp": a["cmp"], "value": a["value"], "hold_s": a["hold_s"], "with_value": a["with_value"],
                                "armed": a["armed"], "last_checked_at": a.get("last_checked_at"),
                                "last_fired_at": a.get("last_fired_at"), "paused": paused}
    return out

#!/usr/bin/env python3
"""dashboard_digest.py -- the daily morning-report push (hmdapp docs/HANDOFF-TO-HEIMDALL-watch.md H4, cap `push-digest-v1`).

The phone sets a schedule with the `set-digest` op of the sealed `dashboard-request` action; the push sender
(bin/lib/companion_push.py) sends ONE `digest` push a day when the schedule is due, through the same message builder, scrub,
foreground suppression, coalescing and rate limits as every other kind. This module owns the schedule, the counters and the body;
the sender owns everything about talking to Expo.

WIRE (op `set-digest`, exact key set, a laptop-side extension of bin/lib/companion_dashboards.py's table):
    rid op project at tz_min tiles include_values on
`at` is "HH:MM" (24 h, zero padded) in the PERSON's local time; `tz_min` is that local time's offset from UTC in minutes, EAST
POSITIVE (local = UTC + tz_min; UTC+05:30 is 330, UTC-04:00 is -240), an int in -840..840 -- the app sends `-getTimezoneOffset()`.
It is a fixed offset: a daylight-saving change moves the report an hour until the phone sends the schedule again. `tiles` is up to
3 distinct tile ids of THIS repo; `include_values` and `on` are bools. Refusals (ok:false, detail): bad-params, caps-missing (the phone
did not list push-digest-v1), dashboards-off / controls-off (the dashboards laptop switch, as for every dashboard-request),
wrong-project (another project, or a tile this repo does not hold), push-off (HMD_PUSH=0, or no phone registered for push; only a
schedule that turns the digest ON is refused -- `on:false` always works), rate-limited. Ack ok:true detail "queued" (the schedule is
stored); a replayed rid is "dup".

WHEN. One digest per local day, at or after `at`, on the FIRST state the sender's process observes then -- hmd runs on the laptop, so
a laptop that is asleep at `at` sends nothing then; its first activity afterwards sends the day's digest. The day (local, by
`tz_min`) is spent by the first due observation of a process that is the repo's sender and has a phone that listed `digest`:
whatever happens to that digest -- sent, suppressed (the app is in the foreground), coalesced away, rate limited -- it is not
replayed, exactly like every other kind. A digest with nothing to say is skipped and still spends the day.

CONTENT. At most 4 lines and 160 UTF-16 units (the handoff's own limit for this kind; title <= 48 as for any push). Line 1, only when a
count is non-zero: `Finished N · Verdicts N · Alerts N` (zero segments are left out). Lines 2-4, only when `include_values` (default
off: a number in a push body transits Apple, Google and Expo): one per listed tile, `<title> <value>`, for a tile that is live, shows
a number panel and is not stale. The counts are of what the push monitor itself handled since the last digest: a `finished` event
(sessions finished: done / stopped) , a `finished` event of the verdict variant (sweep verdicts), a `tile_alert` event (alerts
fired). Everything else of the state is never read. Free text is the tile title only: it must pass companion_ui_attention.secret_shaped
and then companion_push.scrub; a title that does not is left out. Values are formatted here from finite numbers (grouped digits,
k/M/B/T, 4m 12s, 1.2 GB, 63%) or a short string of letters, digits and `.,%+- `.

STORE. <repo>/.heimdall/app/digest.json (dir 0700, file 0600, atomic replace, one exclusive flock over digest.json.lock around every
read-modify-write, so the relay client, `hmd ui` and the sender can not lose each other's update):
    {"v":1,"config":null|{"at","tz_min","tiles","include_values","on","set_at"},"last_day":null|"YYYY-MM-DD","last_at":null|epoch,
     "counts":{"finished","verdicts","alerts"},"seen":[<=64 event keys]}
Counting is idempotent across processes: an event key already in `seen` is not counted again. Never in it: a token, a title, a value.

Stdlib only. Loadable by path, like every companion_* module; no side effects at import.
"""
import contextlib
import errno
import fcntl
import json
import math
import os
import re
import secrets
import stat
import time

CAP_DIGEST = "push-digest-v1"
KIND = "digest"
OP = "set-digest"
APP_REL = os.path.join(".heimdall", "app")
STORE_REL = os.path.join(APP_REL, "digest.json")
LOCK_REL = STORE_REL + ".lock"
READ_CAP_BYTES = 16384
LOCK_TIMEOUT_S = 1.0
LOCK_POLL_S = 0.005
RETRY_S = 60.0                  # a process whose attempt came to nothing looks again no sooner than this
MAX_TILES = 3
MAX_LINES = 4
BODY_MAX = 160                  # UTF-16 units: the handoff's limit for a digest body (every other kind: companion_push.BODY_MAX)
TITLE_UNITS = 24                # a tile title as shown, ellipsis included
VALUE_UNITS = 12
COUNT_MAX = 9999
SEEN_CAP = 64
COUNTERS = ("finished", "verdicts", "alerts")
COUNT_LABELS = (("Finished", "finished"), ("Verdicts", "verdicts"), ("Alerts", "alerts"))

AT_RE = re.compile(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]")
TILE_ID_RE = re.compile(r"t-[0-9a-f]{8}")
DAY_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
SAFE_VALUE_RE = re.compile(r"[A-Za-z0-9.,%+\- ]{1,12}")


def available(environ=None):
    """The digest rides the push sender: it exists exactly while push is on (HMD_PUSH is not "0")."""
    return (os.environ if environ is None else environ).get("HMD_PUSH") != "0"


# -- params (companion_dashboards.parse_params calls these) ------------------------------------------------------------
def valid_at(v):
    return isinstance(v, str) and AT_RE.fullmatch(v) is not None


def valid_tz(v):
    return isinstance(v, int) and not isinstance(v, bool) and -840 <= v <= 840


def valid_tiles(v):
    return (isinstance(v, list) and len(v) <= MAX_TILES and len(set(v)) == len(v)
            and all(isinstance(t, str) and TILE_ID_RE.fullmatch(t) is not None for t in v))


def valid_bool(v):
    return isinstance(v, bool)


# -- the schedule ------------------------------------------------------------------------------------------------------
def local_day_minute(now, tz_min):
    """("YYYY-MM-DD", minutes since local midnight) of the epoch second `now` at the fixed offset `tz_min` (east positive)."""
    t = time.gmtime(now + tz_min * 60)
    return time.strftime("%Y-%m-%d", t), t.tm_hour * 60 + t.tm_min


def at_minutes(at):
    return int(at[:2]) * 60 + int(at[3:])


def is_due(config, last_day, now):
    """Is a digest owed now: switched on, its local time reached today, and today's not yet spent."""
    if not isinstance(config, dict) or config.get("on") is not True:
        return False
    day, minute = local_day_minute(now, config["tz_min"])
    return day != last_day and minute >= at_minutes(config["at"])


# -- the store ---------------------------------------------------------------------------------------------------------
def _zero():
    return dict.fromkeys(COUNTERS, 0)


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _clean_config(raw):
    ok = (isinstance(raw, dict) and valid_at(raw.get("at")) and valid_tz(raw.get("tz_min")) and valid_tiles(raw.get("tiles"))
          and valid_bool(raw.get("include_values")) and valid_bool(raw.get("on")))
    if not ok:
        return None
    return {"at": raw["at"], "tz_min": raw["tz_min"], "tiles": list(raw["tiles"]), "include_values": raw["include_values"],
            "on": raw["on"], "set_at": raw["set_at"] if _int(raw.get("set_at")) else 0}


def _clean(raw):
    state = {"config": None, "last_day": None, "last_at": None, "counts": _zero(), "seen": []}
    if not isinstance(raw, dict):
        return state
    state["config"] = _clean_config(raw.get("config"))
    day = raw.get("last_day")
    state["last_day"] = day if isinstance(day, str) and DAY_RE.fullmatch(day) else None
    state["last_at"] = raw["last_at"] if _int(raw.get("last_at")) else None
    counts = raw.get("counts") if isinstance(raw.get("counts"), dict) else {}
    state["counts"] = {name: min(COUNT_MAX, max(0, counts[name])) if _int(counts.get(name)) else 0 for name in COUNTERS}
    seen = raw.get("seen") if isinstance(raw.get("seen"), list) else []
    state["seen"] = [k for k in seen if isinstance(k, str) and 0 < len(k) <= 80][-SEEN_CAP:]
    return state


def _path(root):
    return os.path.join(root, STORE_REL)


def _read_json(path):
    """The JSON object in `path`: a regular file only, no symlink followed; None when absent, oversized or unusable."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        raw = os.read(fd, READ_CAP_BYTES + 1)
    finally:
        os.close(fd)
    try:
        obj = json.loads(raw.decode("utf-8")) if len(raw) <= READ_CAP_BYTES else None
    except (ValueError, UnicodeDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


def load(root):
    """The stored state, validated field by field; a missing, damaged or foreign file is the default (no schedule). Never raises."""
    return _clean(_read_json(_path(root)))


def _write(root, state):
    path = _path(root)
    tmp = "%s.tmp-%d-%s" % (path, os.getpid(), secrets.token_hex(4))
    body = json.dumps(dict(state, v=1), sort_keys=True, separators=(",", ":"))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def _locked(root):
    directory = os.path.join(root, APP_REL)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    fd = os.open(os.path.join(root, LOCK_REL), os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        deadline = time.monotonic() + LOCK_TIMEOUT_S
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise OSError(errno.ETIMEDOUT, "digest.json is locked by another writer")
                time.sleep(LOCK_POLL_S)
        yield
    finally:
        os.close(fd)


def _update(root, change):
    """Run change(state) -> (changed, result) under the exclusive lock; the file is rewritten only when `changed`. Raises OSError."""
    with _locked(root):
        state = load(root)
        changed, result = change(state)
        if changed:
            _write(root, state)
    return result


def set_config(root, config, now):
    """Store the phone's schedule (already validated by the wire). Turning the digest ON (from off, or the first time) starts the
    counters from zero: the first report covers what happens from then on. Today's spent day is never un-spent. Raises OSError."""
    fresh = {"at": config["at"], "tz_min": config["tz_min"], "tiles": list(config["tiles"]),
             "include_values": config["include_values"], "on": config["on"], "set_at": int(now)}

    def change(state):
        was = state["config"]
        if fresh["on"] and not (was and was["on"]):
            state["counts"], state["last_at"] = _zero(), int(now)
        state["config"] = fresh
        return True, None

    _update(root, change)


# -- counting ----------------------------------------------------------------------------------------------------------
def counter_of(event):
    """Which counter a push event moves: sessions finished (a finished turn), sweep verdicts, alerts fired; else None."""
    if not isinstance(event, dict):
        return None
    kind = event.get("kind")
    variant = event.get("fields", {}).get("variant") if isinstance(event.get("fields"), dict) else None
    if kind == "finished":
        return "verdicts" if variant == "verdict" else "finished" if variant in ("done", "stopped") else None
    return "alerts" if kind == "tile_alert" else None


def record(root, events, now=None):
    """Count the events that move a counter, once per event key across every process (`seen`), and only while the digest is on.
    Returns how many were counted. Raises OSError."""
    hits = []
    for event in events:
        name, key = counter_of(event), event.get("key") if isinstance(event, dict) else None
        if name is not None and isinstance(key, str) and 0 < len(key) <= 80:
            hits.append((key, name))
    if not hits:
        return 0

    def change(state):
        if not (state["config"] and state["config"]["on"]):
            return False, 0
        counted = 0
        for key, name in hits:
            if key not in state["seen"]:
                state["seen"] = (state["seen"] + [key])[-SEEN_CAP:]
                state["counts"][name] = min(COUNT_MAX, state["counts"][name] + 1)
                counted += 1
        return counted > 0, counted

    return _update(root, change)


def claim(root, now):
    """Take today's digest atomically: None unless one is owed now; else what it covers -- {"day", "counts", "tiles",
    "include_values"} -- and the local day is SPENT (the counters restart). Raises OSError."""
    def change(state):
        config = state["config"]
        if not is_due(config, state["last_day"], now):
            return False, None
        day, _ = local_day_minute(now, config["tz_min"])
        taken = {"day": day, "counts": dict(state["counts"]), "tiles": list(config["tiles"]),
                 "include_values": config["include_values"]}
        state.update(last_day=day, last_at=int(now), counts=_zero())
        return True, taken

    return _update(root, change)


# -- values from the observed state ------------------------------------------------------------------------------------
def _group(v):
    """A number as at most 6 characters where it can be: grouped digits, else compacted (1.2M)."""
    text = "{:,.0f}".format(v) if float(v).is_integer() else "{:,.2f}".format(v).rstrip("0").rstrip(".")
    if len(text) <= 6:
        return text
    for divisor, suffix in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "k")):
        if abs(v) >= divisor:
            return ("%.1f" % (v / divisor)).rstrip("0").rstrip(".") + suffix
    return text


def _duration(seconds):
    s = int(abs(seconds))
    d, rest = divmod(s, 86400)
    h, rest = divmod(rest, 3600)
    m, sec = divmod(rest, 60)
    text = "%dd %dh" % (d, h) if d else "%dh %dm" % (h, m) if h else "%dm %ds" % (m, sec) if m else "%ds" % sec
    return ("-" if seconds < 0 else "") + text


def _bytes(count):
    size, unit = float(abs(count)), "B"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            break
        size /= 1024.0
    text = ("%d" % size) if unit == "B" else ("%.1f" % size).rstrip("0").rstrip(".")
    return ("-" if count < 0 else "") + text + " " + unit


def format_value(value, number_format=None):
    """A panel's `data.value` as the digest writes it, or None when it must not appear: a finite number in the panel's own format,
    or a short string of letters, digits and `.,%+- `."""
    if isinstance(value, bool):
        return None
    if isinstance(value, str):
        return value if SAFE_VALUE_RE.fullmatch(value) else None
    if not isinstance(value, (int, float)) or not math.isfinite(value) or abs(value) >= 1e15:
        return None
    if number_format == "percent":
        return _group(value) + "%"
    if number_format == "duration_s":
        return _duration(value)
    if number_format == "bytes":
        return _bytes(value)
    return _group(value)


def tile_rows(state, wanted):
    """[{"title", "value"}] for the listed tiles, in the listed order, from the observed state's `dashboards` slice: a tile that is
    live and shows a fresh number panel. Everything else about a tile is never read."""
    slice_ = state.get("dashboards") if isinstance(state, dict) else None
    tiles = slice_.get("tiles") if isinstance(slice_, dict) and isinstance(slice_.get("tiles"), list) else []
    by_id = {t.get("tile_id"): t for t in tiles if isinstance(t, dict)}
    rows = []
    for tile_id in wanted:
        tile = by_id.get(tile_id)
        panel = tile.get("panel") if isinstance(tile, dict) else None
        if not (isinstance(panel, dict) and tile.get("phase") == "live" and panel.get("type") == "number"
                and panel.get("stale") is False and isinstance(panel.get("data"), dict)):
            continue
        value = format_value(panel["data"].get("value"), panel["data"].get("format"))
        if value is not None and isinstance(panel.get("title"), str):
            rows.append({"title": panel["title"], "value": value})
    return rows


# -- the event and its body --------------------------------------------------------------------------------------------
def make_event(taken, rows):
    """The push event for a claimed digest, or None when there is nothing to say (no count, no value to show). `rows` are shown
    only when the schedule asked for values."""
    counts = taken["counts"]
    tiles = [dict(r) for r in rows][:MAX_TILES] if taken["include_values"] else []
    if not any(counts.values()) and not tiles:
        return None
    return {"kind": KIND, "key": "d:" + taken["day"], "ep": None,
            "fields": {"finished": counts["finished"], "verdicts": counts["verdicts"], "alerts": counts["alerts"], "tiles": tiles}}


def _count(v):
    return v if _int(v) and v > 0 else 0


def _tile_line(item, tools):
    title, value = (item.get("title"), item.get("value")) if isinstance(item, dict) else (None, None)
    check = tools.secret_shaped
    if not (isinstance(title, str) and isinstance(value, str)) or check is None or check(title) or check(value):
        return None
    shown_title, shown_value = tools.scrub(title, TITLE_UNITS), tools.scrub(value, VALUE_UNITS)
    return "%s %s" % (shown_title, shown_value) if shown_title and shown_value else None


def compose_body(fields, tools):
    """The body of one digest push -- at most MAX_LINES lines and BODY_MAX UTF-16 units -- or None when there is nothing to say.
    `tools` carries the sender's own scrub, clip and secret check (companion_push), reused, never copied."""
    fields = fields if isinstance(fields, dict) else {}
    segments = []
    for label, key in COUNT_LABELS:
        n = _count(fields.get(key))
        if n:
            segments.append("%s %s" % (label, "%d+" % COUNT_MAX if n >= COUNT_MAX else n))
    lines = [" · ".join(segments)] if segments else []
    for item in (fields.get("tiles") if isinstance(fields.get("tiles"), list) else [])[:4 * MAX_LINES]:
        if len(lines) >= MAX_LINES:
            break
        line = _tile_line(item, tools)
        if line:
            lines.append(line)
    return tools.clip("\n".join(lines), BODY_MAX) if lines else None


# -- the sender's side -------------------------------------------------------------------------------------------------
class Scheduler:
    """One per push monitor. `precheck` is the cheap look the poller's thread may take (one stat() of the store per observed state);
    `record` and `fire` do the file work and belong to the sender's worker thread."""

    def __init__(self, root):
        self.root = root
        self._stamp = None
        self._view = (None, None)       # (config, last_day) as of the last stamp

    def _current(self):
        try:
            st = os.stat(_path(self.root))
            stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
        except OSError:
            stamp = None
        if stamp != self._stamp:
            self._stamp = stamp
            state = load(self.root) if stamp is not None else None
            self._view = (state["config"], state["last_day"]) if state else (None, None)
        return self._view

    def precheck(self, state, now):
        """None unless a digest looks due -- then the tile rows the observed `state` offers ([] without values)."""
        config, last_day = self._current()
        if not is_due(config, last_day, now):
            return None
        return tile_rows(state, config["tiles"]) if config["include_values"] else []

    def record(self, events, now):
        return record(self.root, events, now)

    def fire(self, now, rows, switch_on=None):
        """The event of today's digest, or None. Spends the local day when one was owed (see claim), whether or not there was
        anything to say. `switch_on` -- the dashboards laptop switch -- gates it; a switch that went off since the schedule
        was set stops the digest without spending the day."""
        if switch_on is not None and not switch_on():
            return None
        taken = claim(self.root, now)
        return None if taken is None else make_event(taken, rows)


def source_paths(root):
    """What the digest touches under the repo, for `hmd ui --print-sources`."""
    return [os.path.join(root, STORE_REL), os.path.join(root, LOCK_REL)]

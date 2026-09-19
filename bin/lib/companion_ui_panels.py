#!/usr/bin/env python3
"""companion_ui_panels.py -- job panels for `hmd ui` (PLAN-companion-ui.md, Decision 6, Wave 4).

A job (any hmd agent, or hmd itself) publishes ONE JSON file per concern under
<repo>/.heimdall/ui/panels/<id>.json and the static page renders it from a CLOSED
type set with zero job-supplied code. This module is the single place the
contract lives -- the `hmd ui panel` CLI (the __main__ block) and the server
(sentinels/hmd-ui.py) both import it, so the type set, every size cap, the
secret scrub and the atomic-write rule cannot drift between writer and reader.

Panel file schema (exactly Decision 6):
    {"id": str, "title": str, "type": <PANEL_TYPES>, "data": {...},
     "refresh_s": int?, "updated_at": float}

`source` -- a job-supplied shell command the server would run on refresh -- is
REJECTED outright, never deferred: whoever can write a file under
.heimdall/ui/panels/ (any coding agent with repo access) would otherwise gain
unattended, timer-driven code execution as the operator's own user. A panel is
data, never code; the presence of the key fails the WHOLE panel.

Secret scrub: `secret_shaped()` below is bin/heimdall-activity's own regex family
(bin/heimdall-activity:167-179, `secret_shaped`/`reject_if_secret`) ported line
for line -- the same gitleaks-pattern-plus-assigned-credential-shape check that
already gates the git-tracked activity record. It is run over the title and every
string leaf inside `data`; a hit refuses the whole panel (reject, never truncate:
a truncated secret is still a leak). Numeric x/y values are never scanned.

Atomic write: `<id>.json.<pid>.tmp` then os.replace -- the exact tmp-suffix
convention bin/heimdall-presence uses for `.roster-cache.json.<pid>.tmp`, with the
same age-first orphan reaper that never touches the live `.json`.

Stdlib only (json, re, os, time, math, stat) -- Decision 1's zero-toolchain posture.
"""
import argparse
import json
import math
import os
import re
import stat
import subprocess
import sys
import time

PANEL_TYPES = ("kv", "table", "number", "timeseries", "bars", "markdown", "log-tail")
MAX_FILE_BYTES = 65536        # per panel file, checked before read AND before write
MAX_TITLE_CHARS = 120         # mirrors bin/heimdall-activity's SCRUB_MAX=120
MAX_STRING_CHARS = 500        # per string leaf inside data
MAX_LIST_ITEMS = 200          # per list (rows, points-per-series, lines) -- read_feed(limit=200)
MAX_SERIES = 6                # dataviz: fixed categorical hue order, never a 7th generated hue
MAX_COLUMNS = 32              # a table wider than this is not a dashboard tile
MAX_PANELS = 64               # total panels served; the directory is data, not a free store
PANEL_TTL_SECONDS = 86400     # 24h: an abandoned job's tile is reaped on the next poll
STALE_FLOOR_S = 30
STALE_MULTIPLIER = 3
TMP_ORPHAN_AGE_S = 120        # matches bin/heimdall-presence _ROSTER_TMP_ORPHAN_AGE_S
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
NUMBER_FORMATS = ("count", "duration_s", "bytes", "percent")
PANELS_REL = os.path.join(".heimdall", "ui", "panels")
GIT_TIMEOUT_S = 3

# ── secret scrub: bin/heimdall-activity:167-179, ported regex for regex ───────
# Order and families are the activity record's own; a hit on ANY rejects the value.
_SECRET_RES = (
    # assigned-credential shape: key = long-opaque-RHS
    re.compile(r"(token|secret|password|passwd|pwd|api[_-]?key|apikey|access[_-]?key|auth|bearer|"
               r"credential|private[_-]?key)\s*[=:]\s*\S{16,}", re.IGNORECASE),
    re.compile(r"ghp_[A-Za-z0-9]{36}"),                     # GitHub PAT
    re.compile(r"gh[oprsu]_[A-Za-z0-9]{36}"),               # other GitHub tokens
    re.compile(r"AKIA[0-9A-Z]{16}"),                        # AWS access key id
    re.compile(r"sk_(live|test)_[A-Za-z0-9]{16,}"),         # Stripe secret
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),            # Slack token
    re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----"),       # PEM key
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),  # JWT
)


def secret_shaped(v):
    """True when `v` matches bin/heimdall-activity's secret_shaped() pattern family.
    The activity record's >SCRUB_MAX length rule is NOT ported: panel leaf length
    is governed by MAX_STRING_CHARS (500) and checked separately."""
    if not isinstance(v, str):
        return False
    return any(rx.search(v) for rx in _SECRET_RES)


class PanelError(ValueError):
    """A panel failed validation. The message names the field, never the value."""


# ── leaf checks ──────────────────────────────────────────────────────────────
def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _check_str(v, field, max_chars=MAX_STRING_CHARS):
    if not isinstance(v, str):
        raise PanelError("%s must be a string" % field)
    if len(v) > max_chars:
        raise PanelError("%s exceeds %d characters" % (field, max_chars))
    if secret_shaped(v):
        raise PanelError("%s looks like it carries a secret/credential (bin/heimdall-activity "
                         "secret_shaped family); panel refused, nothing written" % field)
    return v


def _check_scalar(v, field):
    """A cell/value leaf: string (scrubbed), finite number, bool or null."""
    if isinstance(v, str):
        return _check_str(v, field)
    if v is None or isinstance(v, bool) or _is_num(v):
        return v
    raise PanelError("%s must be a string, number, boolean or null" % field)


def _check_list(v, field, cap=MAX_LIST_ITEMS):
    if not isinstance(v, list):
        raise PanelError("%s must be a list" % field)
    if len(v) > cap:
        raise PanelError("%s has %d items, cap is %d" % (field, len(v), cap))
    return v


def _check_keys(obj, allowed, field):
    if not isinstance(obj, dict):
        raise PanelError("%s must be an object" % field)
    if "source" in obj:
        raise PanelError("%s carries a `source` key; a job-supplied command is an RCE surface and "
                         "is rejected outright (Decision 6) -- publish the numbers, not a command" % field)
    extra = sorted(k for k in obj if k not in allowed)
    if extra:
        raise PanelError("%s has unknown key(s): %s" % (field, ", ".join(extra)))


def _check_points(x, y, field):
    _check_list(x, field + ".x")
    _check_list(y, field + ".y")
    if len(x) != len(y):
        raise PanelError("%s: x and y must have the same length" % field)
    for i, v in enumerate(x):
        if isinstance(v, str):
            _check_str(v, "%s.x[%d]" % (field, i))
        elif not _is_num(v):
            raise PanelError("%s.x[%d] must be a string or finite number" % (field, i))
    for i, v in enumerate(y):
        if not _is_num(v):
            raise PanelError("%s.y[%d] must be a finite number" % (field, i))


def _check_series(series, field):
    _check_list(series, field, cap=MAX_SERIES)
    if not series:
        raise PanelError("%s must not be empty" % field)
    for i, s in enumerate(series):
        sf = "%s[%d]" % (field, i)
        _check_keys(s, ("name", "x", "y"), sf)
        _check_str(s.get("name", ""), sf + ".name")
        _check_points(s.get("x"), s.get("y"), sf)


# ── per-type data validators ─────────────────────────────────────────────────
def _validate_kv(data):
    _check_keys(data, ("rows",), "data")
    rows = _check_list(data.get("rows"), "data.rows")
    for i, row in enumerate(rows):
        if not isinstance(row, list) or len(row) != 2:
            raise PanelError("data.rows[%d] must be a [label, value] pair" % i)
        _check_str(row[0], "data.rows[%d][0]" % i)
        _check_scalar(row[1], "data.rows[%d][1]" % i)


def _validate_table(data):
    _check_keys(data, ("columns", "rows"), "data")
    cols = _check_list(data.get("columns"), "data.columns", cap=MAX_COLUMNS)
    if not cols:
        raise PanelError("data.columns must not be empty")
    for i, c in enumerate(cols):
        _check_str(c, "data.columns[%d]" % i)
    rows = _check_list(data.get("rows"), "data.rows")
    for i, row in enumerate(rows):
        if not isinstance(row, list) or len(row) != len(cols):
            raise PanelError("data.rows[%d] must have exactly %d cells" % (i, len(cols)))
        for j, cell in enumerate(row):
            _check_scalar(cell, "data.rows[%d][%d]" % (i, j))


def _validate_number(data):
    _check_keys(data, ("value", "delta", "format"), "data")
    if "value" not in data:
        raise PanelError("data.value is required")
    v = data["value"]
    if isinstance(v, str):
        _check_str(v, "data.value")
    elif not _is_num(v):
        raise PanelError("data.value must be a number or string")
    if "delta" in data and data["delta"] is not None and not _is_num(data["delta"]):
        raise PanelError("data.delta must be a finite number")
    if "format" in data and data["format"] is not None and data["format"] not in NUMBER_FORMATS:
        raise PanelError("data.format must be one of %s" % "|".join(NUMBER_FORMATS))


def _validate_timeseries(data):
    if not isinstance(data, dict):
        raise PanelError("data must be an object")
    if "series" in data:
        _check_keys(data, ("series",), "data")
        _check_series(data["series"], "data.series")
        return
    _check_keys(data, ("x", "y"), "data")
    _check_points(data.get("x"), data.get("y"), "data")


def _validate_bars(data):
    if not isinstance(data, dict):
        raise PanelError("data must be an object")
    if "series" in data:
        _check_keys(data, ("series",), "data")
        _check_series(data["series"], "data.series")
        return
    _check_keys(data, ("labels", "values"), "data")
    labels = _check_list(data.get("labels"), "data.labels")
    values = _check_list(data.get("values"), "data.values")
    if len(labels) != len(values):
        raise PanelError("data: labels and values must have the same length")
    for i, v in enumerate(labels):
        _check_str(v, "data.labels[%d]" % i)
    for i, v in enumerate(values):
        if not _is_num(v):
            raise PanelError("data.values[%d] must be a finite number" % i)


def _validate_markdown(data):
    _check_keys(data, ("text",), "data")
    _check_str(data.get("text"), "data.text")


def _validate_log_tail(data):
    _check_keys(data, ("lines",), "data")
    lines = _check_list(data.get("lines"), "data.lines")
    for i, line in enumerate(lines):
        _check_str(line, "data.lines[%d]" % i)


_VALIDATORS = {
    "kv": _validate_kv,
    "table": _validate_table,
    "number": _validate_number,
    "timeseries": _validate_timeseries,
    "bars": _validate_bars,
    "markdown": _validate_markdown,
    "log-tail": _validate_log_tail,
}


def validate_panel(obj):
    """Enforce the whole Decision 6 contract on a decoded panel object. Returns a
    normalised copy {id, title, type, data, refresh_s, updated_at}; raises
    PanelError (message names the field, never the value) on the first violation.
    Nothing partial is ever honoured: one bad leaf rejects the whole panel."""
    if not isinstance(obj, dict):
        raise PanelError("panel must be a JSON object")
    if "source" in obj:
        raise PanelError("panel carries a `source` key: a job-supplied shell command the server would run "
                         "is an RCE surface (file-write privilege escalating to unattended code execution) "
                         "and is rejected outright, not deferred (Decision 6)")
    pid = obj.get("id")
    if not isinstance(pid, str) or not ID_RE.match(pid):
        raise PanelError("id must match ^[A-Za-z0-9_-]{1,64}$")
    title = obj.get("title")
    if not isinstance(title, str) or not title.strip():
        raise PanelError("title must be a non-empty string")
    _check_str(title, "title", max_chars=MAX_TITLE_CHARS)
    ptype = obj.get("type")
    if ptype not in PANEL_TYPES:
        raise PanelError("type must be one of %s (closed set; a job cannot add a rendering mode)"
                         % "|".join(PANEL_TYPES))
    data = obj.get("data")
    if not isinstance(data, dict):
        raise PanelError("data must be an object")
    _VALIDATORS[ptype](data)
    refresh_s = obj.get("refresh_s")
    if refresh_s is not None:
        if isinstance(refresh_s, bool) or not isinstance(refresh_s, (int, float)) or refresh_s < 0 \
                or not math.isfinite(refresh_s):
            raise PanelError("refresh_s must be a non-negative number")
        refresh_s = int(refresh_s)
    updated_at = obj.get("updated_at")
    if not _is_num(updated_at) or updated_at < 0:
        raise PanelError("updated_at must be a unix epoch number")
    return {"id": pid, "title": title, "type": ptype, "data": data,
            "refresh_s": refresh_s, "updated_at": float(updated_at)}


def stale_after(refresh_s):
    """Seconds after updated_at at which a panel greys out: max(refresh_s*3, 30)."""
    r = refresh_s if isinstance(refresh_s, (int, float)) and not isinstance(refresh_s, bool) else 0
    return max(r * STALE_MULTIPLIER, STALE_FLOOR_S)


# ── files ────────────────────────────────────────────────────────────────────
def panels_dir(root):
    return os.path.join(root, PANELS_REL)


def panel_path(root, pid):
    if not isinstance(pid, str) or not ID_RE.match(pid):
        raise PanelError("id must match ^[A-Za-z0-9_-]{1,64}$")
    return os.path.join(panels_dir(root), pid + ".json")


_TMP_RE = re.compile(r"^([A-Za-z0-9_-]{1,64})\.json\.([0-9]+)\.tmp$")


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (OSError, OverflowError):
        return True
    return True


def _reap_orphan_tmps(d, now=None):
    """Remove `<id>.json.<pid>.tmp` files a crashed writer left behind. Age is the
    primary discriminator (a real writer opens, dumps and renames in one breath);
    the pid liveness check only guards the window under TMP_ORPHAN_AGE_S. Strict
    shape only: this can never match a live `<id>.json`. Fails open -- housekeeping."""
    now = time.time() if now is None else now
    try:
        names = os.listdir(d)
    except OSError:
        return
    for n in names:
        m = _TMP_RE.match(n)
        if not m:
            continue
        p = os.path.join(d, n)
        try:
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode):
                continue
            if now - st.st_mtime < TMP_ORPHAN_AGE_S and _pid_alive(int(m.group(2))):
                continue
            os.remove(p)
        except (OSError, ValueError):
            continue


def write_panel(root, pid, obj):
    """Validate, then atomically publish `<root>/.heimdall/ui/panels/<pid>.json`.
    Raises PanelError before touching disk on any contract violation; on success
    returns the final path. Write-to-tmp-then-os.replace means a reader never sees
    a half-written file, and a concurrent writer of the SAME id simply loses the
    race whole (one writer per file is the convention; the id names its owner)."""
    body = dict(obj)
    body.setdefault("id", pid)
    panel = validate_panel(body)
    if panel["id"] != pid:
        raise PanelError("id in the panel body does not match the id being written")
    out = {"id": panel["id"], "title": panel["title"], "type": panel["type"], "data": panel["data"],
           "updated_at": panel["updated_at"]}
    if panel["refresh_s"] is not None:
        out["refresh_s"] = panel["refresh_s"]
    raw = json.dumps(out, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(raw) > MAX_FILE_BYTES:
        raise PanelError("panel serialises to %d bytes; cap is %d" % (len(raw), MAX_FILE_BYTES))
    d = panels_dir(root)
    os.makedirs(d, exist_ok=True)
    _reap_orphan_tmps(d)
    final = panel_path(root, pid)
    tmp = "%s.%d.tmp" % (final, os.getpid())
    try:
        with open(tmp, "wb") as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, final)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            sys.stderr.write("hmd ui panel: could not remove %s after a failed write\n" % tmp)
        raise
    return final


def remove_panel(root, pid):
    """`hmd ui panel rm`: unlink the live file. True if a file was removed."""
    p = panel_path(root, pid)
    try:
        os.remove(p)
        return True
    except FileNotFoundError:
        return False


def _read_panel_file(path, now):
    """One file -> ("ok", panel) | ("expired", None) | ("invalid", reason).
    Symlinks and non-regular files are refused so a crafted link under the panels
    dir can never make the server read a file outside it (team.json, a key...)."""
    try:
        st = os.lstat(path)
    except OSError as e:
        return "invalid", "unreadable (%s)" % e.__class__.__name__
    if not stat.S_ISREG(st.st_mode):
        return "invalid", "not a regular file (symlinks are refused)"
    if st.st_size > MAX_FILE_BYTES:
        return "invalid", "file is %d bytes; cap is %d" % (st.st_size, MAX_FILE_BYTES)
    try:
        with open(path, "rb") as f:
            raw = f.read(MAX_FILE_BYTES + 1)
    except OSError as e:
        return "invalid", "unreadable (%s)" % e.__class__.__name__
    if len(raw) > MAX_FILE_BYTES:
        return "invalid", "file exceeds %d bytes" % MAX_FILE_BYTES
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return "invalid", "not valid UTF-8 JSON"
    try:
        panel = validate_panel(obj)
    except PanelError as e:
        return "invalid", str(e)
    expected = os.path.splitext(os.path.basename(path))[0]
    if panel["id"] != expected:
        return "invalid", "id inside the file does not match its filename"
    if now - panel["updated_at"] > PANEL_TTL_SECONDS:
        return "expired", None
    return "ok", panel


def read_panels(root, now=None, log=None):
    """Every valid, live panel under <root>/.heimdall/ui/panels/, sorted by id, as
    the /api/state `panels` array entries: {id, title, type, data, refresh_s,
    updated_at, stale}. Invalid / secret-shaped / mis-shaped files are DROPPED and
    named on stderr (id and reason only, never contents). TTL-expired files are
    deleted -- an abandoned job's tile never lingers. A missing dir is simply []."""
    now = time.time() if now is None else now
    log = sys.stderr.write if log is None else log
    d = panels_dir(root)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    _reap_orphan_tmps(d, now)
    out = []
    for n in names:
        if not n.endswith(".json"):
            continue
        base = n[:-5]
        if not ID_RE.match(base):
            log("hmd-ui panels: skipping %r: filename is not a valid panel id\n" % n)
            continue
        path = os.path.join(d, n)
        status, payload = _read_panel_file(path, now)
        if status == "expired":
            try:
                os.remove(path)
            except OSError:
                log("hmd-ui panels: could not reap expired panel %s\n" % base)
            continue
        if status == "invalid":
            log("hmd-ui panels: dropping %s: %s\n" % (base, payload))
            continue
        panel = payload
        panel["stale"] = (now - panel["updated_at"]) > stale_after(panel["refresh_s"])
        out.append(panel)
        if len(out) >= MAX_PANELS:
            log("hmd-ui panels: cap of %d panels reached; the rest are not served\n" % MAX_PANELS)
            break
    return out


# ── CLI: `hmd ui panel set|rm|ls` (exec'd by bin/heimdall-ui) ─────────────────
def resolve_root(explicit=None):
    """--repo > HEIMDALL_WATCH_ROOT > git toplevel (bounded) > cwd. Same order as
    bin/lib/watch_data.resolve_root, inlined so the CLI has no import beyond stdlib."""
    if explicit:
        return os.path.realpath(os.path.expanduser(explicit))
    env_root = os.environ.get("HEIMDALL_WATCH_ROOT")
    if env_root:
        return os.path.realpath(os.path.expanduser(env_root))
    try:
        p = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           timeout=GIT_TIMEOUT_S, stdin=subprocess.DEVNULL)
        if p.returncode == 0 and p.stdout.strip():
            return os.path.realpath(p.stdout.strip())
    except (OSError, subprocess.SubprocessError, ValueError):
        return os.getcwd()
    return os.getcwd()


def _read_data_json(spec):
    """`--data-json FILE|-`: bounded read, decoded as the panel's `data` object."""
    if spec == "-":
        raw = sys.stdin.buffer.read(MAX_FILE_BYTES + 1)
    else:
        with open(spec, "rb") as f:
            raw = f.read(MAX_FILE_BYTES + 1)
    if len(raw) > MAX_FILE_BYTES:
        raise PanelError("--data-json input exceeds %d bytes" % MAX_FILE_BYTES)
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise PanelError("--data-json is not valid UTF-8 JSON: %s" % e.__class__.__name__)


def _cmd_set(args):
    root = resolve_root(args.repo)
    data = _read_data_json(args.data_json)
    body = {"id": args.id, "title": args.title, "type": args.type, "data": data, "updated_at": time.time()}
    if args.refresh_s is not None:
        body["refresh_s"] = args.refresh_s
    path = write_panel(root, args.id, body)
    print(path)
    return 0


def _cmd_rm(args):
    root = resolve_root(args.repo)
    if remove_panel(root, args.id):
        print("removed %s" % args.id)
        return 0
    sys.stderr.write("hmd ui panel rm: no panel named %s under %s\n" % (args.id, panels_dir(root)))
    return 1


def _cmd_ls(args):
    root = resolve_root(args.repo)
    rows = read_panels(root)
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    if not rows:
        print("no panels under %s" % panels_dir(root))
        return 0
    now = time.time()
    for p in rows:
        print("%-24s %-11s %-6s %6ds  %s" % (p["id"], p["type"], "stale" if p["stale"] else "live",
                                             int(now - p["updated_at"]), p["title"]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd ui panel",
                                 description="publish/remove/list job panels for `hmd ui` (Decision 6: "
                                             "inline data only, closed type set, no job-supplied commands)")
    ap.add_argument("--repo", help="repo root (default: HEIMDALL_WATCH_ROOT, git toplevel, or cwd)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("set", help="validate, scrub and atomically publish <id>.json")
    s.add_argument("id")
    s.add_argument("--type", required=True, help="|".join(PANEL_TYPES))
    s.add_argument("--title", required=True)
    s.add_argument("--data-json", required=True, metavar="FILE|-", help="the `data` object; - reads stdin")
    s.add_argument("--refresh-s", type=int, default=None, help="advisory cadence; stale after max(3x, 30s)")
    s.set_defaults(fn=_cmd_set)
    r = sub.add_parser("rm", help="remove a panel")
    r.add_argument("id")
    r.set_defaults(fn=_cmd_rm)
    ls = sub.add_parser("ls", help="list live panels (as the server would serve them)")
    ls.add_argument("--json", action="store_true")
    ls.set_defaults(fn=_cmd_ls)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except PanelError as e:
        sys.stderr.write("hmd ui panel: refused -- %s\n" % e)
        return 2
    except OSError as e:
        sys.stderr.write("hmd ui panel: %s\n" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())

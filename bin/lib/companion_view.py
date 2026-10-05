#!/usr/bin/env python3
"""companion_view.py -- the read-only `view-v1` channel: the diff the phone's Files list opens.

The phone half is hmdapp's src/views (docs/HANDOFF-TO-HEIMDALL-cursor-parity.md CP5, section 3.5 of
docs/analysis/2026-10-03-cursor-mobile-parity.md). bin/heimdall-relay-client owns the wire -- the sealed
command, the ack, the `views` slice of the state frame, the capability token -- and this module owns every
rule about what may be shown:

    cap      "view-v1", listed in every state frame's `caps` while this module loaded
    command  {"action":"view","params":{"rid":"v-9","kind":"diff","scope":"worktree","path":"src/a.ts"|null,
              "ctx":3,"max_bytes":131072}}              scope: worktree | staged | head; path null = the whole tree
    ack ok   {"ok":true,"of_seq":N,"id":"v-9"}
    ack no   {"ok":false,"of_seq":N,"detail":<code>[,"retry_after_s":N]}
    answer   state.views = {"v":1,"enabled":bool,"kinds":["diff"],"result":null | {
                "id":"v-9","kind":"diff","at":<epoch>,"truncated":bool,"bytes":N,
                "files":[{"path","status":"M|A|D|R|C|T|U|?","add","del","binary"[,"old_path"]}],
                "hunks":[{"path","header":"@@ -a,b +c,d @@ ...","lines":[{"t":"+"|"-"|" "|"\\","s":<text>}]}]}}
             Only to a phone whose latest sealed resync listed view-v1; the newest result replaces the last.
             `kinds` is what this hmd answers today, so a phone can hide the entry points it would refuse.

The `detail` of a refusal is one of: caps-missing (the phone never listed view-v1), controls-off, rate-limited
(+retry_after_s), bad-params, not-implemented (transcript | reel | pr: the contract's other three kinds, which
this hmd does not answer yet), not-allowed, not-found, too-large, timeout.

What the phone can never be shown, in the order it is checked:
  * a path that is not a clean repo-relative one (absolute, a `..` segment, a control byte, over 1024 units): bad-params;
  * `.git`, `.heimdall`, `.env*` / `*.env`, `id_rsa`-shaped names, `*.pem` `*.key` `*.p12` `*.pfx` `*.jks`
    `*.keystore`, `.netrc` `.npmrc` `.pypirc`, and any path that is itself secret-shaped: not-allowed -- for a
    named path, and silently left out of a whole-tree or directory diff;
  * any path with a symlink anywhere in it, whatever it points at: not-allowed. The one file this module reads
    itself (an untracked file, shown as all-added) is opened component by component with O_NOFOLLOW, so a
    link swapped in after the check is refused too. Everything else comes from `git diff`, which never follows a
    link for a tracked path;
  * every diff line goes through companion_ui_panels.secret_shaped(): a hit masks the WHOLE line as
    "[redacted]" (its type stays), and a PEM private key is masked from its BEGIN line to its END line;
  * the relay's redaction profile (sentinels/hmd-ui.py _transport_redaction: emails, absolute paths) is applied to
    every string of the result by the caller's `redact`, exactly as it is to the rest of the state.

Size: the diff is cut at a hunk boundary (`truncated: true`) once it passes `max_bytes` (default 131072, at most
262144), the app's own caps (2000 files, 5000 hunks, 20000 lines, 2000 characters a line) or the slice budget
(the caller's `max_slice_bytes`: 3/8 of the envelope cap, so a plain frame -- 4/3 of its plaintext once sealed --
still fits beside a state of that size; a phone that listed z-zlib gets the same frame compressed). When the very
first hunk alone is over a budget its leading lines are kept rather than nothing.

Rate: 20 requests in any 60 s (HMD_VIEW_RATE_LIMIT, a positive whole number, replaces the 20). Work: every git call is an argv list in a scrubbed environment (no GIT_DIR, no
pager, no external diff, no textconv, no fsmonitor, literal pathspecs), bounded by one DEADLINE_S for the request
and GIT_OUTPUT_CAP bytes of output. A result lives in memory only and is never logged.

Stdlib only; Python 3.9+.
"""
import collections
import json
import math
import os
import re
import stat
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import companion_ui_panels as P  # noqa: E402 -- secret_shaped(): the one scrub every companion slice shares

CAP_VIEW = "view-v1"
VIEWS_VERSION = 1
KINDS = ("diff", "transcript", "reel", "pr")  # the contract's four
SERVED = ("diff",)                            # the ones answered here; the rest are refused `not-implemented`
SCOPES = ("worktree", "staged", "head")

DEFAULT_CTX, MAX_CTX = 3, 10
DEFAULT_MAX_BYTES, MAX_MAX_BYTES = 131072, 262144
DEFAULT_SLICE_BYTES = 1048576 * 3 // 8        # the relay client passes 3/8 of ITS envelope cap
BASE_JSON_BYTES = 256                         # the result's own keys, plus the slice wrapper, with room to spare
RATE_LIMIT, RATE_WINDOW_S = 20, 60
DEADLINE_S = 6.0                              # for the whole request; the phone waits 10 s for the ack
GIT_OUTPUT_CAP = 8 * 1024 * 1024
UNTRACKED_MAX_BYTES = 2 * 1024 * 1024
BINARY_SNIFF = 8000                           # git's own rule: a NUL in the first 8000 bytes is a binary file
# What the phone's guard (hmdapp src/views/guards.ts) will hold: more than this and it clips or refuses the result.
MAX_PATH_UNITS = 1024                         # UTF-16 units: a longer path makes the whole result unreadable there
MAX_FILES, MAX_HUNKS, MAX_LINES = 2000, 5000, 20000
MAX_LINE_CHARS, MAX_HEADER_CHARS = 2000, 500
REDACTED = "[redacted]"

_RID = re.compile(r"[A-Za-z0-9_-]{1,32}")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_HUNK = re.compile(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
_PEM_BEGIN = re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----")
_PEM_END = re.compile(r"-----END[ A-Z]*PRIVATE KEY-----")
_KEY_FILE = re.compile(r"id_(rsa|dsa|ecdsa|ed25519)")
_DENIED_DIRS = frozenset((".git", ".heimdall"))
_DENIED_SUFFIXES = (".env", ".pem", ".key", ".p12", ".pfx", ".jks", ".keystore")
_DENIED_NAMES = frozenset((".netrc", ".npmrc", ".pypirc"))
_STATUSES = frozenset("MADRCTU")
_DIFF_KEYS = frozenset(("rid", "kind", "scope", "path", "ctx", "max_bytes"))
_GIT_ENV_KEEP = ("PATH", "HOME", "XDG_CONFIG_HOME", "TMPDIR")


class ViewError(Exception):
    """A request refused. `code` is the ack's machine-readable `detail`; the message never names a path or a line."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def controls_off(root):
    """The laptop's kill switch for every remote control: HMD_UI_CONTROLS=0, or the file
    <repo>/.heimdall/app/controls-disabled. Read at every call, so the switch is never stale."""
    return (os.environ.get("HMD_UI_CONTROLS") == "0"
            or os.path.exists(os.path.join(root, ".heimdall", "app", "controls-disabled")))


def rate_limit():
    """Requests per RATE_WINDOW_S: RATE_LIMIT, or HMD_VIEW_RATE_LIMIT when that is a positive whole number."""
    value = os.environ.get("HMD_VIEW_RATE_LIMIT", "")
    return int(value) if value.isdigit() and int(value) > 0 else RATE_LIMIT


def denied(segments):
    """True for a path the phone may never be shown (see the module docstring). `segments` are its non-empty
    '/'-separated parts. Case-insensitive: macOS and Windows checkouts treat `.GIT` and `.git` as one directory."""
    low = [s.lower() for s in segments]
    if any(s in _DENIED_DIRS for s in low):
        return True
    name = low[-1]
    return name.startswith(".env") or name.endswith(_DENIED_SUFFIXES) or name in _DENIED_NAMES \
        or _KEY_FILE.match(name) is not None


def _u16len(text):
    return len(text.encode("utf-16-le")) // 2


def _jsize(obj):
    """Bytes `obj` takes in the sealed frame: the client dumps with json's defaults (ASCII-escaped) and compact separators."""
    return len(json.dumps(obj, separators=(",", ":")))


def _visible(path, old):
    """May this diff entry be listed: it has a name the phone can read, and neither name is denied or secret-shaped."""
    for name in (path, old):
        if name is None:
            continue
        if not name or _u16len(name) > MAX_PATH_UNITS or denied(name.split("/")) or P.secret_shaped(name):
            return False
    return True


def split_path(path):
    """A repo-relative path -> its segments, lexically (no filesystem access), or ViewError("bad-params")."""
    if (not isinstance(path, str) or not 0 < _u16len(path) <= MAX_PATH_UNITS
            or _CONTROL.search(path) or path.startswith("/")):
        raise ViewError("bad-params")
    segments = [s for s in path.split("/") if s not in ("", ".")]
    if not segments or ".." in segments:
        raise ViewError("bad-params")
    return segments


def _int_in(value, low, high):
    return isinstance(value, int) and not isinstance(value, bool) and low <= value <= high


def parse_request(params):
    """The `view` command's params -> {rid, kind, scope, path (segments or None), ctx, max_bytes}, or ViewError.
    The key set is exact: an unknown key, a wrong type or an out-of-range number is bad-params."""
    if not isinstance(params, dict):
        raise ViewError("bad-params")
    rid = params.get("rid")
    if not isinstance(rid, str) or _RID.fullmatch(rid) is None:
        raise ViewError("bad-params")
    kind = params.get("kind")
    if kind not in KINDS:
        raise ViewError("bad-params")
    if kind not in SERVED:
        raise ViewError("not-implemented")
    if set(params) - _DIFF_KEYS:
        raise ViewError("bad-params")
    scope = params.get("scope", "worktree")
    ctx = params.get("ctx", DEFAULT_CTX)
    max_bytes = params.get("max_bytes", DEFAULT_MAX_BYTES)
    if scope not in SCOPES or not _int_in(ctx, 0, MAX_CTX) or not _int_in(max_bytes, 1, MAX_MAX_BYTES):
        raise ViewError("bad-params")
    path = params.get("path")
    return {"rid": rid, "kind": kind, "scope": scope, "ctx": ctx, "max_bytes": max_bytes,
            "path": None if path is None else split_path(path)}


# -- git -------------------------------------------------------------------------------------------------------

def _git_env():
    """A whitelist, never os.environ: a GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE or GIT_EXTERNAL_DIFF inherited from a
    hook or a shell must not point this git at another repository or make it run a program."""
    env = {name: os.environ[name] for name in _GIT_ENV_KEEP if name in os.environ}
    env.update(LC_ALL="C", GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", GIT_LITERAL_PATHSPECS="1")
    return env


def _tokens(out):
    """The NUL-terminated fields of `git ... -z` output."""
    fields = out.decode("utf-8", "replace").split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    return fields


def _changes(out):
    """`git diff --raw --numstat -z` -> [(path, old_path|None, add, del, binary, status letter)] in git's order.
    The raw records come first (`:modes shas STATUS`, then the name -- two names for a rename or copy), the numstat
    records after them (`add TAB del TAB name`, a rename's name field empty and the two names after it). A binary
    file's `-` counts are 0. One git run answers both, because a big diff is slow and the phone is waiting."""
    fields, status, i = _tokens(out), {}, 0
    while i < len(fields) and fields[i].startswith(":"):
        letter = fields[i].split(" ")[-1][:1]
        i += 1
        if letter in ("R", "C"):
            if i + 1 >= len(fields):
                break
            status[fields[i + 1]] = (letter, fields[i])
            i += 2
        elif i < len(fields):
            status[fields[i]] = (letter, None)
            i += 1
    entries = []
    while i < len(fields):
        parts = fields[i].split("\t", 2)
        i += 1
        if len(parts) != 3:
            continue
        added, removed, path = parts
        old = None
        if path == "":  # a rename or copy: the next two fields are the names it was and became
            if i + 1 >= len(fields):
                break
            old, path = fields[i], fields[i + 1]
            i += 2
        binary = added == "-" and removed == "-"
        letter, renamed_from = status.get(path, ("M", None))
        entries.append((path, old or renamed_from, 0 if binary or not added.isdigit() else int(added),
                        0 if binary or not removed.isdigit() else int(removed), binary, letter))
    return entries


_ESCAPES = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}


def _unquote(text):
    """A git C-quoted name ("a\\tb", "\\303\\251") -> the name."""
    body = text[1:-1] if len(text) > 1 and text.endswith('"') else text[1:]
    out, i = bytearray(), 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt in _ESCAPES:
                out.append(_ESCAPES[nxt])
                i += 2
                continue
            if nxt in "01234567":
                j = i + 1
                while j < len(body) and j < i + 4 and body[j] in "01234567":
                    j += 1
                out.append(int(body[i + 1:j], 8) & 0xFF)
                i = j
                continue
        out.extend(ch.encode("utf-8"))
        i += 1
    return out.decode("utf-8", "replace")


def _header_path(raw):
    """The name on a `--- ` / `+++ ` line of `git diff --no-prefix`; None for /dev/null (a file that is not there)."""
    raw = raw.rstrip("\t")  # git adds a TAB after a name that holds spaces, for patch(1)
    if raw.startswith('"'):
        raw = _unquote(raw)
    return None if raw == "/dev/null" else raw


def _hunks(text):
    """Yield (path, `@@` line, [(type, text)], complete) for every hunk of a unified diff made with --no-prefix.
    Hunk bodies are read by their line counts, so a removed line that reads `-- x` (shown `--- x`) is never taken for
    a file header. A combined diff (`diff --cc`, an unmerged path) is skipped. `complete` is False when the text
    ended before the counts were met (the output cap cut the diff)."""
    lines = text.split("\n")
    i, n = 0, len(lines)
    path = old = None
    combined = False
    while i < n:
        line = lines[i]
        i += 1
        if line.startswith("diff "):
            path = old = None
            combined = line.startswith(("diff --cc ", "diff --combined "))
            continue
        if combined:
            continue
        if line.startswith("--- "):
            old = _header_path(line[4:])
            continue
        if line.startswith("+++ "):
            path = _header_path(line[4:])
            continue
        m = _HUNK.match(line)
        if m is None:
            continue
        old_left = int(m.group(2)) if m.group(2) is not None else 1
        new_left = int(m.group(4)) if m.group(4) is not None else 1
        body = []
        while (old_left > 0 or new_left > 0) and i < n:
            kind = lines[i][:1]
            if kind == " ":
                old_left -= 1
                new_left -= 1
            elif kind == "-":
                old_left -= 1
            elif kind == "+":
                new_left -= 1
            elif kind != "\\":
                break
            body.append((kind, lines[i][1:]))
            i += 1
        while i < n and lines[i].startswith("\\"):  # "\ No newline at end of file" trails the last counted line
            body.append(("\\", lines[i][1:]))
            i += 1
        target = path if path is not None else old
        if target is not None:
            yield target, line, body, old_left <= 0 and new_left <= 0


class ViewManager:
    """Answers the phone's `view` command and holds the newest result for the `views` slice.

    handle() runs on the relay client's stream thread (a request is answered whole before the next command is read, so
    there is never more than one in flight); snapshot() runs on its state loop. The result is one reference
    assigned whole, so the state loop sees the old result or the new one, never half of either."""

    def __init__(self, root, redact=None, max_slice_bytes=DEFAULT_SLICE_BYTES, on_change=None):
        self._root = root
        self._real_root = os.path.realpath(root)
        self._redact = redact
        self._budget = max_slice_bytes
        self._on_change = on_change
        self._rate = rate_limit()
        self._stamps = collections.deque()  # time.monotonic() of the requests inside the last RATE_WINDOW_S
        self._result = None

    # -- the wire -----------------------------------------------------------------------------------------------
    def handle(self, params, has_cap):
        """-> (ok, detail, extra): what the relay client puts in the ack. `has_cap`: the phone's latest sealed resync
        listed view-v1. An answer is only ever put in the slice for such a phone, so a request from any other would
        wait forever for one."""
        if not has_cap:
            return False, "caps-missing", {}
        if controls_off(self._root):
            return False, "controls-off", {}
        wait = self._throttle()
        if wait:
            return False, "rate-limited", {"retry_after_s": wait}
        try:
            request = parse_request(params)
            self._result = self._run(request)
        except ViewError as e:
            return False, e.code, {}
        if self._on_change is not None:
            self._on_change()
        return True, None, {"id": request["rid"]}

    def snapshot(self):
        """The `views` slice for a phone that listed view-v1. Switched off at the laptop: enabled false, nothing held."""
        off = controls_off(self._root)
        return {"v": VIEWS_VERSION, "enabled": not off, "kinds": list(SERVED), "result": None if off else self._result}

    def forget(self):
        """Drop the held result: the phone stopped listing view-v1, or a new device bound."""
        self._result = None

    def _throttle(self):
        """0 and the request is counted, or the whole seconds until the oldest of the last RATE_LIMIT is a minute old."""
        now = time.monotonic()
        while self._stamps and now - self._stamps[0] >= RATE_WINDOW_S:
            self._stamps.popleft()
        if len(self._stamps) >= self._rate:
            return max(1, int(math.ceil(RATE_WINDOW_S - (now - self._stamps[0]))))
        self._stamps.append(now)
        return 0

    # -- one request --------------------------------------------------------------------------------------------
    def _run(self, req):
        deadline = time.monotonic() + DEADLINE_S
        segments = req["path"]
        rel = "/".join(segments) if segments else None
        if segments:
            self._check_path(segments, rel)
        out, _ = self._git(self._diff_args(["--raw", "--numstat", "-z"], req, rel), deadline)
        entries = [e for e in _changes(out) if _visible(e[0], e[1])]
        if not entries:
            return self._unchanged(req, rel, segments, deadline)
        files, shown, truncated, used = self._files(entries)
        patch, capped = self._git(self._diff_args(["-U%d" % req["ctx"]], req, rel), deadline)
        hunks, raw, cut = self._collect(_hunks(patch.decode("utf-8", "replace")), shown, req["max_bytes"], used)
        return self._result_of(req, files, hunks, raw, truncated or capped or cut)

    def _check_path(self, segments, rel):
        if denied(segments) or P.secret_shaped(rel):
            raise ViewError("not-allowed")
        candidate = os.path.join(self._real_root, *segments)
        if os.path.realpath(candidate) != candidate:  # a symlink somewhere in the path: never followed, whatever it targets
            raise ViewError("not-allowed")

    def _unchanged(self, req, rel, segments, deadline):
        """No visible tracked change. A named untracked file is shown as all added; any other named path must at least
        exist (or be tracked), else not-found."""
        if rel is None:
            return self._result_of(req, [], [], 0, False)
        if req["scope"] != "staged":
            out, _ = self._git(["ls-files", "-z", "--others", "--exclude-standard", "--", rel], deadline)
            if rel in _tokens(out):
                return self._untracked(req, rel, segments)
        if not os.path.lexists(os.path.join(self._real_root, rel)):
            out, _ = self._git(["ls-files", "-z", "--", rel], deadline)
            if not _tokens(out):
                raise ViewError("not-found")
        return self._result_of(req, [], [], 0, False)

    def _untracked(self, req, rel, segments):
        data = self._read_untracked(segments)
        if b"\0" in data[:BINARY_SNIFF]:
            entry = {"path": rel, "status": "?", "add": 0, "del": 0, "binary": True}
            return self._result_of(req, [entry], [], 0, False)
        lines = data.decode("utf-8", "replace").split("\n")
        ended = lines[-1] == ""  # the piece after the last newline is empty when the file ends with one
        if ended:
            lines.pop()
        body = [("+", s) for s in lines] + ([] if ended or not lines else [("\\", " No newline at end of file")])
        entry = {"path": rel, "status": "?", "add": len(lines), "del": 0, "binary": False}
        header = "@@ -0,0 +1%s @@" % ("" if len(lines) == 1 else ",%d" % len(lines))  # git's own form
        added = [(rel, header, body, True)] if lines else []
        hunks, raw, cut = self._collect(iter(added), {rel}, req["max_bytes"], BASE_JSON_BYTES + _jsize(entry) + 1)
        return self._result_of(req, [entry], hunks, raw, cut)

    def _read_untracked(self, segments):
        try:
            fd = self._open_beneath(segments)
        except FileNotFoundError:
            raise ViewError("not-found")
        except OSError:  # ELOOP (a symlink), ENOTDIR (a file where a directory is expected), EACCES
            raise ViewError("not-allowed")
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise ViewError("not-allowed")
            if info.st_size > UNTRACKED_MAX_BYTES:
                raise ViewError("too-large")
            chunks, size = [], 0
            while size <= UNTRACKED_MAX_BYTES:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
        finally:
            os.close(fd)
        if size > UNTRACKED_MAX_BYTES:  # it grew while it was read
            raise ViewError("too-large")
        return b"".join(chunks)

    def _open_beneath(self, segments):
        """An fd for the file at <root>/<segments>, opened one component at a time with O_NOFOLLOW: a symlink swapped
        in between the check and this open is refused (ELOOP), never followed out of the repository."""
        cloexec = getattr(os, "O_CLOEXEC", 0)
        directory = getattr(os, "O_DIRECTORY", 0)
        fd = os.open(self._real_root, os.O_RDONLY | directory | cloexec)
        try:
            for name in segments[:-1]:
                step = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | directory | cloexec, dir_fd=fd)
                os.close(fd)
                fd = step
            return os.open(segments[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | cloexec, dir_fd=fd)
        finally:
            os.close(fd)

    def _diff_args(self, shape, req, rel):
        # The working tree against the index holds no renames (git pairs only what the index or HEAD names), and finding
        # them costs a second pass over every changed file: so only the staged and head scopes look.
        args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-prefix", "--relative",
                "--no-renames" if req["scope"] == "worktree" else "--find-renames"] + shape
        if req["scope"] == "staged":
            args.append("--cached")
        elif req["scope"] == "head":
            args.append("HEAD")
        return args + ["--"] + ([rel] if rel is not None else [])

    def _git(self, args, deadline):
        """-> (stdout, capped): at most GIT_OUTPUT_CAP bytes of it, `capped` when there was more. ViewError(timeout) once
        `deadline` (time.monotonic()) passes, ViewError(not-found) when git cannot run here (not a repository, no HEAD)."""
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ViewError("timeout")
        argv = ["git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.quotepath=false"] + args
        try:
            proc = subprocess.Popen(argv, cwd=self._root, env=_git_env(), stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, close_fds=True)
        except FileNotFoundError:  # no git, or the repository is gone
            raise ViewError("not-found")
        expired = threading.Event()

        def expire():
            expired.set()
            proc.kill()

        timer = threading.Timer(remaining, expire)
        timer.daemon = True
        timer.start()
        chunks, size, capped = [], 0, False
        try:
            while True:
                chunk = proc.stdout.read1(65536)
                if not chunk:
                    break
                if size + len(chunk) > GIT_OUTPUT_CAP:
                    chunks.append(chunk[:GIT_OUTPUT_CAP - size])
                    capped = True
                    proc.kill()
                    break
                chunks.append(chunk)
                size += len(chunk)
        finally:
            timer.cancel()
            proc.stdout.close()
            code = proc.wait()
        if expired.is_set():
            raise ViewError("timeout")
        if not capped and code in (128, 129):  # fatal (not a repository, no HEAD) and usage (git diff outside a repository)
            raise ViewError("not-found")
        if not capped and code != 0:
            raise RuntimeError("git exited %d" % code)
        return b"".join(chunks), capped

    # -- the result ---------------------------------------------------------------------------------------------
    def _files(self, entries):
        """The `files` list, in git's order, within the slice budget -> (files, paths shown, truncated, bytes used)."""
        files, shown, used, truncated = [], set(), BASE_JSON_BYTES, False
        for path, old, added, removed, binary, letter in entries:
            entry = {"path": path, "status": letter if letter in _STATUSES else "M", "add": added, "del": removed,
                     "binary": binary}
            if entry["status"] in ("R", "C") and old:
                entry["old_path"] = old
            size = _jsize(entry) + 1
            if len(files) >= MAX_FILES or used + size > self._budget:
                truncated = True
                break
            files.append(entry)
            shown.add(path)
            used += size
        return files, shown, truncated, used

    def _collect(self, hunk_iter, shown, max_bytes, used):
        """The `hunks` list: whole hunks of the listed files while they fit every budget -> (hunks, diff bytes shown,
        cut). The first hunk is kept in part, rather than dropped, when it alone is over a budget."""
        hunks, raw, nlines, cut, in_key = [], 0, 0, False, {}
        for path, header, body, complete in hunk_iter:
            if path not in shown:
                continue
            if not complete:
                cut = True
                break
            head = self._header(header)
            lines = [{"t": t, "s": self._text(path, s, in_key)} for t, s in body]
            h_raw = len(head.encode("utf-8")) + 1
            h_json = _jsize({"path": path, "header": head, "lines": []}) + 1
            room = len(hunks) < MAX_HUNKS and raw + h_raw <= max_bytes and used + h_json <= self._budget
            keep = 0
            for line in lines if room else ():
                l_raw = len(line["s"].encode("utf-8")) + 2  # the type character and the newline
                l_json = _jsize(line) + 1
                if raw + h_raw + l_raw > max_bytes or used + h_json + l_json > self._budget or nlines + keep >= MAX_LINES:
                    break
                h_raw += l_raw
                h_json += l_json
                keep += 1
            if not room or keep < len(lines):
                cut = True
                if hunks or keep == 0:  # a later hunk that does not fit is dropped; the first is kept in part
                    break
            hunks.append({"path": path, "header": head, "lines": lines[:keep]})
            raw += h_raw
            used += h_json
            nlines += keep
            if cut:
                break
        return hunks, raw, cut

    @staticmethod
    def _header(line):
        """The `@@ -a,b +c,d @@` of a hunk line, plus git's function-context text unless that is secret-shaped."""
        end = _HUNK.match(line).end()
        context = line[end:]
        return (line[:end] + ("" if P.secret_shaped(context) else context))[:MAX_HEADER_CHARS]

    @staticmethod
    def _text(path, text, in_key):
        """One diff line's text as the phone may see it: "[redacted]" when secret-shaped, and the whole body of a PEM
        private key (`in_key[path]` holds whether the previous line of this file was inside one)."""
        if in_key.get(path) or _PEM_BEGIN.search(text):
            in_key[path] = _PEM_END.search(text) is None
            return REDACTED
        if P.secret_shaped(text):
            return REDACTED
        return text if len(text) <= MAX_LINE_CHARS else text[:MAX_LINE_CHARS] + "…"

    def _result_of(self, req, files, hunks, raw, truncated):
        result = {"id": req["rid"], "kind": "diff", "at": time.time(), "truncated": bool(truncated), "bytes": raw,
                  "files": files, "hunks": hunks}
        return self._redact(result) if self._redact is not None else result

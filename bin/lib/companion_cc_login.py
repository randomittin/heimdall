#!/usr/bin/env python3
"""companion_cc_login.py -- sign the laptop's Claude Code in from the paired phone (capability `login-v1`).

Design of record: hmdapp's docs/HANDOFF-TO-HEIMDALL-remote-cc-login.md and
docs/superpowers/specs/2026-10-03-remote-cc-login.md (read-only inputs from the hmdapp repo). The phone
asks (sealed `login_start`), hmd runs `claude auth login` on a PTY, validates the authorize URL the CLI
prints against an exact allowlist and publishes it in the sealed state (`state.login.request`); the user
signs in in the phone's browser, the page shows `CODE#STATE`, the phone sends it back sealed
(`login_code`) and hmd types it into the waiting CLI, then verifies the outcome with `claude auth status`
and reports it in `state.login.result`. Nothing here talks to the relay: bin/heimdall-relay-client owns
the wire, this module owns the login.

Facts about Claude Code 2.1.288 this code stands on (read from its binary, not guessed):
  * `claude auth login [--console]` prints `Opening browser to sign in...`, then
    `If the browser didn't open, visit: <URL>`, then the prompt `Paste code here if prompted > ` (no
    trailing newline), and never exits on its own. It needs no TTY; the PTY is only there so it behaves
    as it does for a person.
  * The pasted text is read as a LINE from stdin and split on `#`: BOTH `CODE` and `STATE` must be
    non-empty, else the CLI prints `Invalid code. Please make sure the full code was copied.` on stderr
    and keeps waiting. Hence submit_code refuses a code without `#STATE` (bad-code) before it is spent.
  * Success prints `Login successful.` and exits 0; failure prints `Login failed: <reason>` on stderr and
    exits 1. (`OAuth error`, the marker the handoff guessed, does not occur; it is still honoured.)
  * `claude auth status` prints JSON {loggedIn, authMethod, apiProvider, analyticsDisabled,
    projectsDirectory, configDirectory[, apiKeySource][, email, orgId, orgName, subscriptionType]} and
    exits 0 iff loggedIn. A console login is reported as authMethod `api_key` with apiKeySource
    `/login managed key`; an ANTHROPIC_API_KEY from the environment as `api_key` with another source.

What this module guarantees (each is a test in test/companion-cc-login-*.test.sh):
  * validate_url: only an https authorize URL on an allowlisted (host, path) with the pinned manual
    redirect_uri, PKCE-shaped challenge/state, no repeated keys, no userinfo/port/punycode/fragment, at
    most 2048 chars, for the kind that was asked for, ever reaches the phone. The rows, redirect values and
    the code shape are DATA (docs/samples/login/allowlist.json), not code.
  * The login CODE is a secret: it exists only inside the sealed `login_code` command, in one local
    variable between normalize_code and one os.write to the PTY. It is never logged, evented, stored, put
    in state or echoed in an ack; the PTY has ECHO off; the 16 KiB output buffer is process memory only
    and is dropped when the session ends. No exception message here ever contains caller input.
  * One login at a time (a global flock), 3 starts per 600 s, 300 s of life, the whole process group
    killed (SIGTERM, then SIGKILL) on every terminal state, an orphan sweep at relay-client start.
  * After the code is written the outcome is always verified (`claude auth status`) and the identity is
    compared with the pin the operator set at the laptop; a different account is logged out again.

Stdlib only. Loadable by path (the convention of bin/lib/companion_ui_*.py), no import-time side effects.
"""
import atexit
import calendar
import codecs
import contextlib
import errno
import fcntl
import hashlib
import json
import os
import re
import secrets
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.realpath(__file__))
# The vendored allowlist (hmdapp's docs/samples/login/allowlist.json, checksum-pinned by
# test/companion-cc-login-vectors.test.sh): URL rows, redirect values, PKCE shape, code shape.
ALLOWLIST_PATH = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "samples", "login", "allowlist.json"))

CAP_LOGIN = "login-v1"
ACTIONS = ("login_start", "login_code", "login_cancel")
KINDS = ("claudeai", "console")
MANAGED_KEY_SOURCE = "/login managed key"  # apiKeySource of `claude auth status` after a console login
ASCII_WHITESPACE = " \t\n\r\f\v"

_PRINTABLE_ASCII = re.compile(r"[\x21-\x7e]+")


class LoginError(Exception):
    """A login request was refused or ended. `code` is the machine-readable string that becomes the ack's
    `detail` (start/code/cancel) or `result.detail` (spec 4.3 / 4.5). The message names the rule and never
    echoes anything the phone or the CLI sent."""

    def __init__(self, code, message=None):
        super().__init__(message or code)
        self.code = code


# -- the allowlist ------------------------------------------------------------------------------------
class _AllowlistError(Exception):
    """allowlist.json is missing or malformed: nothing can be validated, so everything is refused."""


_allowlist_cache = {}  # path -> ((mtime_ns, size), parsed)


def _text(value):
    if not isinstance(value, str):
        raise TypeError("expected a string")
    return value


def _parse_allowlist(doc):
    rows = []
    for row in doc["rows"]:
        kind = _text(row["kind"])
        if kind not in KINDS:
            raise ValueError("unknown kind")
        rows.append({"kind": kind, "host": _text(row["host"]), "path": _text(row["path"]),
                     "redirect_uri": _text(row["redirect_uri"])})
    if not rows:
        raise ValueError("no rows")
    required = {_text(k): _text(v) for k, v in doc["required_query"].items()}
    cap = doc["max_url_length"]
    code_cap = doc["code_max_length"]
    if not all(isinstance(n, int) and not isinstance(n, bool) and n > 0 for n in (cap, code_cap)):
        raise ValueError("lengths must be positive integers")
    return {
        "rows": rows,
        "required": required,
        "pkce_keys": [_text(k) for k in doc["pkce_keys"]],
        "pkce_re": re.compile(_text(doc["pkce_regex"]), re.ASCII),
        "nonempty_keys": [_text(k) for k in doc["nonempty_keys"]],
        "max_url_length": cap,
        "code_re": re.compile(_text(doc["code_regex"]), re.ASCII),
        "code_max_length": code_cap,
    }


def _allowlist(path=None):
    path = path or ALLOWLIST_PATH
    try:
        st = os.stat(path)
        stamp = (st.st_mtime_ns, st.st_size)
        cached = _allowlist_cache.get(path)
        if cached is not None and cached[0] == stamp:
            return cached[1]
        with open(path, "rb") as f:
            raw = f.read(65537)
        if len(raw) > 65536:
            raise ValueError("allowlist.json is implausibly large")
        parsed = _parse_allowlist(json.loads(raw.decode("utf-8")))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, re.error) as e:
        raise _AllowlistError(type(e).__name__) from None
    _allowlist_cache[path] = (stamp, parsed)
    return parsed


def _parse_query(query):
    """The query's pairs as a dict of decoded key -> decoded value. Every pair must be `key=value` with a
    key, no key may repeat once decoded, and the percent-escapes must be valid UTF-8: whatever is
    ambiguous about the query is refused rather than interpreted."""
    params = {}
    for pair in query.split("&"):
        key, equals, value = pair.partition("=")
        if not equals or not key:
            raise LoginError("bad-url", "the query is malformed")
        try:
            key = urllib.parse.unquote_plus(key, errors="strict")
            value = urllib.parse.unquote_plus(value, errors="strict")
        except UnicodeDecodeError:
            raise LoginError("bad-url", "the query has an invalid percent-escape") from None
        if key in params:
            raise LoginError("bad-url", "a query key is repeated")
        params[key] = value
    return params


def validate_url(url, kind):
    """The authorize URL's host when `url` passes spec 3.2 for `kind`, else LoginError("host-not-allowed")
    when its (host, path) is not an allowlist row, else LoginError("bad-url"). Nothing is normalised or
    decoded before it is judged (no lower-casing, no dot-segment or percent-decoding of the path), so the
    string checked is the string a browser would be handed."""
    try:
        allow = _allowlist()
    except _AllowlistError:
        raise LoginError("host-not-allowed", "the allowlist is unavailable") from None
    # rule 1: the form of the URL
    if not isinstance(url, str) or _PRINTABLE_ASCII.fullmatch(url) is None or "\\" in url:
        raise LoginError("bad-url", "the URL is not a plain printable-ASCII string")
    scheme, separator, rest = url.partition("://")
    if not separator or scheme != "https":
        raise LoginError("bad-url", "the scheme is not https")
    authority = re.split(r"[/?#]", rest, maxsplit=1)[0]
    if not authority or "@" in authority or ":" in authority:
        raise LoginError("bad-url", "the URL has userinfo, a port or no host")
    if authority != authority.lower() or "xn--" in authority:
        raise LoginError("bad-url", "the host is not lower-case ASCII or is punycode")
    before_fragment, hash_sep, _fragment = rest[len(authority):].partition("#")
    path, _question, query = before_fragment.partition("?")
    # rule 2: the (host, path) pair is a row
    row = next((r for r in allow["rows"] if r["host"] == authority and r["path"] == path), None)
    if row is None:
        raise LoginError("host-not-allowed", "the host and path are not on the allowlist")
    # rule 3: the query
    if hash_sep:
        raise LoginError("bad-url", "the URL carries a fragment")
    params = _parse_query(query)
    for key, want in allow["required"].items():
        if params.get(key) != want:
            raise LoginError("bad-url", "a required query parameter is missing or wrong")
    if params.get("redirect_uri") != row["redirect_uri"]:
        raise LoginError("bad-url", "redirect_uri is not the pinned manual callback")
    for key in allow["pkce_keys"]:
        if allow["pkce_re"].fullmatch(params.get(key, "")) is None:
            raise LoginError("bad-url", "code_challenge or state is not a base64url value of the allowed length")
    for key in allow["nonempty_keys"]:
        if not params.get(key):
            raise LoginError("bad-url", "a required query parameter is empty")
    # rule 4: the length
    if len(url) > allow["max_url_length"]:
        raise LoginError("bad-url", "the URL is longer than the allowed maximum")
    # rule 5: the kind the caller asked for
    if row["kind"] != kind:
        raise LoginError("bad-url", "the URL is for the other login kind")
    return authority


def normalize_code(raw):
    """`raw` with ASCII whitespace trimmed, when it is a code of the shape of spec 4.4 (`CODE` or
    `CODE#STATE`); else LoginError("bad-code"). Only ASCII whitespace is trimmed (a no-break space or an
    ideographic space is part of the value, so it is refused), and the shape is a full match: no control
    byte, no second `#`, nothing outside [A-Za-z0-9._~-] can reach the PTY."""
    if not isinstance(raw, str):
        raise LoginError("bad-code", "the code is not a string")
    try:
        allow = _allowlist()
    except _AllowlistError:
        raise LoginError("bad-code", "the code shape is unavailable") from None
    code = raw.strip(ASCII_WHITESPACE)
    if len(code) > allow["code_max_length"] or allow["code_re"].fullmatch(code) is None:
        raise LoginError("bad-code", "the code is not CODE or CODE#STATE of the allowed shape")
    return code


def mask_account(email):
    """`r...@example.com` for r@example.com: the first character of the local part, an ellipsis, `@` and the
    domain. None for anything that is not one plain address. The phone only ever sees this, never the
    address (the state frame is sealed to the operator's own phone; the mask keeps screenshots low-value)."""
    if not isinstance(email, str) or email.count("@") != 1:
        return None
    local, domain = email.split("@")
    if not local or not domain or any(ch.isspace() or ord(ch) < 0x20 for ch in email):
        return None
    return local[0] + "…@" + domain


def identity_fingerprint(status):
    """sha256 hex of the account `claude auth status` JSON names -- its e-mail (case-folded) and organisation
    id -- or None when nobody is signed in or the account cannot be told. Method, organisation name and
    plan are deliberately left out: the same person signing in again through the console must stay the same
    identity, and a renamed organisation must not lock the operator out."""
    if not isinstance(status, dict) or status.get("loggedIn") is not True:
        return None
    email = status.get("email")
    if not isinstance(email, str) or not email.strip():
        return None
    org = status.get("orgId")
    canonical = json.dumps([email.strip().lower(), org.strip().lower() if isinstance(org, str) else ""],
                           separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


# -- the laptop's switch: $HEIMDALL_HOME/remote-login.json --------------------------------------------
CONFIG_FILE = "remote-login.json"
LOCK_FILE = "cc-login.lock"
PID_FILE = "cc-login.pid"
CONFIG_MAX_BYTES = 4096
_PIN_RE = re.compile(r"[0-9a-f]{64}")


def heimdall_home(env=None):
    env = os.environ if env is None else env
    return env.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")


def read_config(home):
    """{"enabled", "pin", "pin_next", "updated_at"} from remote-login.json. A missing, oversized, unparsable
    or mistyped file is the OFF state: remote login is opt-in, so anything unclear means no."""
    blank = {"enabled": False, "pin": None, "pin_next": False, "updated_at": 0}
    try:
        with open(os.path.join(home, CONFIG_FILE), "rb") as f:
            raw = f.read(CONFIG_MAX_BYTES + 1)
        obj = json.loads(raw.decode("utf-8")) if len(raw) <= CONFIG_MAX_BYTES else None
    except (OSError, ValueError):
        return blank
    if not isinstance(obj, dict):
        return blank
    pin, stamp = obj.get("pin"), obj.get("updated_at")
    return {"enabled": obj.get("enabled") is True,
            "pin": pin if isinstance(pin, str) and _PIN_RE.fullmatch(pin) else None,
            "pin_next": obj.get("pin_next") is True,
            "updated_at": stamp if isinstance(stamp, int) and not isinstance(stamp, bool) else 0}


def write_config(home, enabled, pin=None, pin_next=False):
    """Atomically (temp file, fsync, rename) writes remote-login.json, 0600. `pin` is an
    identity_fingerprint -- never an address."""
    if pin is not None and not (isinstance(pin, str) and _PIN_RE.fullmatch(pin)):
        raise ValueError("pin must be a 64-hex fingerprint")
    os.makedirs(home, mode=0o700, exist_ok=True)
    path = os.path.join(home, CONFIG_FILE)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    body = json.dumps({"enabled": bool(enabled), "pin": pin, "pin_next": bool(pin_next),
                       "updated_at": int(time.time())}, sort_keys=True, separators=(",", ":"))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


# -- bounds, markers and small helpers ------------------------------------------------------------------
LIFETIME_S = 300        # a request lives this long from the spawn (spec 6)
NO_URL_S = 20           # spawn -> a valid authorize URL
PROMPT_WAIT_S = 5       # how long a code waits for the paste prompt before it is typed anyway
RESULT_S = 30           # code written -> an outcome marker
TERM_GRACE_S = 3        # SIGTERM -> SIGKILL
STATUS_TIMEOUT_S = 10   # one `claude auth status` / `auth logout`
VERIFY_JOIN_S = 25      # a shutdown lets a verification that is already running finish (bounded)
RESULT_KEEP_S = 3600    # state.login.result is dropped after an hour
RATE_MAX = 3            # login starts ...
RATE_WINDOW_S = 600     # ... per this many seconds, per relay client
PROBE_EVERY_S = 900
RING_CHARS = 16384
MAX_CANDIDATES = 16
PTY_ROWS, PTY_COLS = 50, 1000  # wide enough that the CLI never wraps the URL

PROMPT_TEXT = "Paste code here if prompted"
SUCCESS_MARKERS = ("Login successful",)
INVALID_CODE_MARKERS = ("Invalid code",)
FAILURE_MARKERS = ("Login failed", "OAuth login failed", "OAuth error")
OVERRIDE_METHODS = ("oauth_token", "api_key_helper", "third_party")
AUTH_METHODS = ("none", "claude.ai", "oauth_token", "api_key", "api_key_helper", "third_party")

_ID_RE = re.compile(r"l-[0-9a-f]{8}")
# CSI, OSC (BEL or ST terminated) and two-byte escapes: stripped before any text is matched
_ANSI_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]")
_VISIT_URL_RE = re.compile(r"visit:[ \t]*(https://\S+)(?=\s)")
_URL_RE = re.compile(r"(https://\S+)(?=\s)")  # a URL counts once whitespace follows it: never judge half of one


def _valid_id(value):
    return isinstance(value, str) and _ID_RE.fullmatch(value) is not None


def _is_overridden(status):
    """True when `claude auth status` says the credential in use comes from the environment, a helper or a
    gateway, all of which outrank what a /login writes. A console login's managed key does not."""
    method = status.get("authMethod")
    if method in OVERRIDE_METHODS:
        return True
    return method == "api_key" and status.get("apiKeySource") != MANAGED_KEY_SOURCE


def _short_home(path, home):
    if not isinstance(path, str):
        return None
    base = (home or "").rstrip("/")
    if base and (path == base or path.startswith(base + "/")):
        return "~" + path[len(base):]
    return path


def _group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _terminate_group(pgid, grace_s):
    """SIGTERM the process group `pgid`, give it `grace_s`, SIGKILL what is left. False when there was
    no such group to signal."""
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return False
    deadline = time.monotonic() + grace_s
    while time.monotonic() < deadline and _group_alive(pgid):
        time.sleep(0.05)
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pgid, signal.SIGKILL)
    return True


def _kill_group(proc, grace_s):
    """Ends the process group `proc` leads: SIGTERM, up to `grace_s` for the leader, then SIGKILL for the
    group (a leader that ignores SIGTERM, and whatever it left behind), and reaps the leader."""
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(proc.pid, signal.SIGTERM)
    deadline = time.monotonic() + grace_s
    while proc.poll() is None and time.monotonic() < deadline:
        time.sleep(0.05)
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(proc.pid, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=5)


def _run(argv, env, timeout):
    """(returncode, stdout) of argv run with no stdin in a session of its own; (None, b"") when it could not
    start or did not finish inside `timeout` (its whole group is then SIGKILLed)."""
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=env, start_new_session=True, close_fds=True)
    except (OSError, ValueError):
        return None, b""
    try:
        out, _unused = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(proc.pid, signal.SIGKILL)
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=5)
        proc.stdout.close()
        return None, b""
    return proc.returncode, out


def _parse_status(returncode, out):
    """{"rc", "json"} for one `claude auth status` run; json is the object it printed, else None."""
    if returncode is None:
        return None
    text = _ANSI_RE.sub("", out.decode("utf-8", "replace"))
    start, end = text.find("{"), text.rfind("}")
    obj = None
    if 0 <= start < end:
        with contextlib.suppress(ValueError):
            candidate = json.loads(text[start:end + 1])
            obj = candidate if isinstance(candidate, dict) else None
    return {"rc": returncode, "json": obj}


def _is_login_process(pid):
    """True when `pid` is running `claude auth login` -- the check that keeps an orphan sweep from killing
    an unrelated process that merely inherited a recycled pid."""
    returncode, out = _run(["ps", "-o", "command=", "-p", str(pid)], dict(os.environ), 5)
    if returncode != 0:
        return False
    tokens = out.decode("utf-8", "replace").split()
    return (any(os.path.basename(t) == "claude" for t in tokens[:2])
            and any(a == "auth" and b == "login" for a, b in zip(tokens, tokens[1:])))


# -- one login: `claude auth login` on a PTY ------------------------------------------------------------
class LoginSession:
    """One `claude auth login` on a PTY. Its process, its descriptors and its buffers belong to its own
    thread (_run); every other thread only asks (request_abort, submit) and waits (done)."""

    def __init__(self, mgr, kind, lock_fd):
        self.mgr = mgr
        self.kind = kind
        self.id = "l-" + secrets.token_hex(4)
        self.lock_fd = lock_fd
        self.created = mgr.now()
        self.expires_at = int(self.created + mgr.lifetime_s)
        self.started_mono = time.monotonic()
        self.claude = None
        self.proc = None
        self.master = None
        self.thread = None
        self.done = threading.Event()
        self.phase = "starting"       # starting -> awaiting-code -> verifying
        self.url = None
        self.host = None
        self.submitted = False        # a code was accepted: cancel can no longer undo the exchange
        self.in_verify = False        # the CLI said success; `claude auth status` and the pin check are running
        self._abort = None
        self._finished = False
        self._cleaned = False
        self._state_lock = threading.Lock()
        self._master_lock = threading.Lock()
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self._ring = ""               # the CLI's output, newest RING_CHARS characters, process memory only
        self._after = ""              # its output since the code was typed
        self._collect_after = False
        self._written_mono = None
        self._prompt_seen = threading.Event()
        self._seen = set()            # candidate URLs already judged
        self._candidate_fail = None   # the first reason a candidate URL was refused

    def spawn(self, claude):
        """Opens the PTY (50x1000, ECHO off) and starts `claude auth login [--console]` in a session of its
        own, so the whole process group can be killed. LoginError("spawn-failed") when it cannot."""
        self.claude = claude
        master = slave = None
        try:
            master, slave = os.openpty()
            os.set_blocking(master, False)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", PTY_ROWS, PTY_COLS, 0, 0))
            attrs = termios.tcgetattr(slave)
            attrs[3] &= ~termios.ECHO
            termios.tcsetattr(slave, termios.TCSANOW, attrs)
            argv = [claude, "auth", "login"] + (["--console"] if self.kind == "console" else [])
            self.proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, env=self.mgr.child_env(),
                                         start_new_session=True, close_fds=True)
            self.master = master
            self._write_pid_file()
        except (OSError, ValueError, subprocess.SubprocessError, termios.error) as e:
            if self.proc is not None:
                _kill_group(self.proc, 0.5)
            if master is not None:
                with contextlib.suppress(OSError):
                    os.close(master)
            self.master = None
            raise LoginError("spawn-failed", "could not start claude auth login (%s)" % type(e).__name__) from None
        finally:
            if slave is not None:
                with contextlib.suppress(OSError):
                    os.close(slave)

    def start_thread(self):
        self.thread = threading.Thread(target=self._run, name="cc-login-" + self.id, daemon=True)
        self.thread.start()

    def _write_pid_file(self):
        path = os.path.join(self.mgr.home, PID_FILE)
        tmp = "%s.tmp-%d" % (path, os.getpid())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"pid": self.proc.pid, "started_at": int(self.created)}, f)
        os.replace(tmp, path)

    def public(self):
        """state.login.request while this login is live: None until a validated URL exists."""
        with self._state_lock:
            if self.url is None:
                return None
            return {"id": self.id, "url": self.url, "host": self.host, "expires_at": self.expires_at,
                    "kind": self.kind, "phase": self.phase}

    def request_abort(self, detail):
        """Asks the session thread to end with `detail` (the first request wins)."""
        if self._abort is None and not self._finished:
            self._abort = detail

    def emergency_kill(self):
        """Last resort for interpreter exit: SIGKILL the process group, no waiting, no bookkeeping."""
        self.request_abort("superseded")
        if self.proc is not None:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(self.proc.pid, signal.SIGKILL)

    # -- the code ---------------------------------------------------------------------------------------
    def submit(self, code):
        """Types an already-normalised `CODE#STATE` into the waiting CLI: marked submitted FIRST (a crash
        cannot re-use it), then one write of the code and a carriage return. The code lives in this
        frame's argument and in a bytearray that is overwritten after the write -- nowhere else."""
        with self._state_lock:
            if self._finished or self._abort is not None:
                raise LoginError("expired" if self._abort == "expired" else "unknown-id", "the request is over")
            if self.submitted:
                raise LoginError("already-submitted", "a code was already sent for this request")
            expired = self.mgr.now() >= self.expires_at
            if not expired and self.phase != "awaiting-code":
                raise LoginError("unknown-id", "the request has no sign-in URL yet")
            if not expired:
                self.submitted = True
        if expired:
            self.request_abort("expired")
            self.done.wait(self.mgr.term_grace_s + 10)
            raise LoginError("expired", "the request has expired")
        self._prompt_seen.wait(self.mgr.prompt_wait_s)  # a CLI that never prompts is typed at anyway: auth status decides
        payload = bytearray(code.encode("ascii"))
        payload.append(0x0D)
        try:
            with self._state_lock:
                self._after = ""
                self._collect_after = True
            self._write(payload)
        except OSError:
            self.request_abort("exited")
            return {"id": self.id, "phase": "verifying"}
        finally:
            for i in range(len(payload)):
                payload[i] = 0
        with self._state_lock:
            self.phase = "verifying"
            self._written_mono = time.monotonic()
        self.mgr.changed()
        return {"id": self.id, "phase": "verifying"}

    def _write(self, payload):
        view = memoryview(payload)
        sent = 0
        deadline = time.monotonic() + 5
        try:
            with self._master_lock:
                if self.master is None:
                    raise OSError(errno.EBADF, "the PTY is closed")
                while sent < len(view):
                    try:
                        sent += os.write(self.master, view[sent:])
                    except BlockingIOError:
                        if time.monotonic() > deadline:
                            raise OSError(errno.ETIMEDOUT, "the PTY did not take the input") from None
                        select.select([], [self.master], [], 0.1)
        finally:
            view.release()

    # -- the session thread -----------------------------------------------------------------------------
    def _run(self):
        try:
            self._loop()
        except Exception as e:  # a bug here must never leave a login process running
            self.mgr.report_error("login session failed: %s" % type(e).__name__)
            self._finish("exited")
        finally:
            self._cleanup()
            self.done.set()
        if self.submitted:
            self.mgr.probe()  # the credentials may have changed: refresh what the phone is told about them

    def _loop(self):
        while True:
            abort = self._abort
            if abort is not None:
                return self._finish(abort)
            if self.mgr.now() >= self.expires_at:
                return self._finish("expired")
            now = time.monotonic()
            with self._state_lock:
                phase, written = self.phase, self._written_mono
            if phase == "starting" and now - self.started_mono > self.mgr.no_url_s:
                return self._finish(self._candidate_fail or "no-url")
            if written is not None and now - written > self.mgr.result_s:
                return self._finish("no-result")
            if self._readable(0.25):
                data = self._read()
                if data == b"":
                    return self._on_exit()
                if data:
                    terminal = self._on_text(self._decoder.decode(data))
                    if terminal:
                        return self._finish(terminal)
                    outcome = self._outcome()
                    if outcome == "success":
                        return self._verify()
                    if outcome:
                        return self._finish(outcome)
            elif self.proc.poll() is not None:
                return self._on_exit()

    def _readable(self, timeout):
        try:
            return bool(select.select([self.master], [], [], timeout)[0])
        except (OSError, ValueError):
            return True  # a broken descriptor reads as end of file below

    def _read(self):
        """Bytes from the PTY; b"" at end of file (macOS: EOF, Linux: EIO); None when nothing was there."""
        try:
            return os.read(self.master, 4096)
        except BlockingIOError:
            return None
        except OSError:
            return b""

    def _drain(self):
        end = time.monotonic() + 1.0
        while time.monotonic() < end and self._readable(0.1):
            data = self._read()
            if not data:
                return
            self._on_text(self._decoder.decode(data))

    def _on_text(self, text):
        """Takes new CLI output: remembers it (bounded, in memory), notes the paste prompt and, until a URL
        is published, judges the https URLs in it. A terminal detail when the URL the CLI told the user to
        visit fails validation."""
        with self._state_lock:
            self._ring = (self._ring + text)[-RING_CHARS:]
            if self._collect_after:
                self._after = (self._after + text)[-RING_CHARS:]
            ring = self._ring
            need_url = self.url is None
        clean = _ANSI_RE.sub("", ring)
        if PROMPT_TEXT in clean:
            self._prompt_seen.set()
        if need_url:
            return self._scan_candidates(clean)
        return None

    def _scan_candidates(self, clean):
        visit = {mt.group(1) for mt in _VISIT_URL_RE.finditer(clean)}
        for mt in _URL_RE.finditer(clean):
            candidate = mt.group(1)
            if candidate in self._seen or len(self._seen) >= MAX_CANDIDATES:
                continue
            self._seen.add(candidate)
            try:
                host = validate_url(candidate, self.kind)
            except LoginError as e:
                if self._candidate_fail is None:
                    self._candidate_fail = e.code
                if candidate in visit:
                    return e.code  # the link the CLI told the user to open is not one hmd will hand out
                continue
            with self._state_lock:
                self.url, self.host, self.phase = candidate, host, "awaiting-code"
            self.mgr.changed()
            return None
        return None

    def _outcome(self):
        """"success", a failure detail, or None -- from what the CLI printed since the code was typed."""
        with self._state_lock:
            text = self._after if self._collect_after else ""
        if not text:
            return None
        clean = _ANSI_RE.sub("", text)
        if any(marker in clean for marker in SUCCESS_MARKERS):
            return "success"
        if any(marker in clean for marker in INVALID_CODE_MARKERS):
            return "invalid-code"
        if any(marker in clean for marker in FAILURE_MARKERS):
            return "oauth-error"
        return None

    def _on_exit(self):
        self._drain()
        outcome = self._outcome()
        if outcome is None and self._written_mono is not None:
            code = self.proc.poll()
            if code is None:
                with contextlib.suppress(subprocess.TimeoutExpired):
                    code = self.proc.wait(timeout=2)
            if code == 0:
                outcome = "success"  # the markers are hints; a clean exit after the code is verified like one
        if outcome == "success":
            return self._verify()
        return self._finish(outcome or "exited")

    # -- verifying and ending ----------------------------------------------------------------------------
    def _method_matches(self, status):
        method = status.get("authMethod")
        if self.kind == "claudeai":
            return method == "claude.ai"
        return method == "claude.ai" or (method == "api_key" and status.get("apiKeySource") == MANAGED_KEY_SOURCE)

    def _verify(self):
        """The authority on whether the login worked is `claude auth status`, not the CLI's text; and the
        identity is checked against the pin the operator set at the laptop. Always runs once a code was typed
        and the CLI claimed success, and runs to its end even if the phone cancels or hmd is shutting down."""
        self.in_verify = True
        mgr = self.mgr
        result = mgr.auth_status(self.claude)
        status = result["json"] if result is not None and result["rc"] == 0 else None
        if status is None or status.get("loggedIn") is not True or not self._method_matches(status):
            return self._finish("verify-failed")
        fingerprint = identity_fingerprint(status)
        config = read_config(mgr.home)
        if config["pin"] is not None:
            if fingerprint != config["pin"]:
                return self._reject_account()
        elif config["enabled"] and config["pin_next"]:
            if fingerprint is None:
                return self._finish("verify-failed")
            try:
                write_config(mgr.home, True, pin=fingerprint, pin_next=False)
            except OSError:
                return self._reject_account()  # an identity that cannot be pinned is not kept
        else:
            mgr.logout(self.claude)  # remote login was switched off while the code was out: undo it
            return self._finish("cancelled")
        mgr.set_cc(mgr.cc_from(result))
        return self._finish("", ok=True, account_hint=mask_account(status.get("email")))

    def _reject_account(self):
        self.mgr.logout(self.claude)
        return self._finish("account-mismatch")

    def _finish(self, detail, ok=False, account_hint=None):
        with self._state_lock:
            if self._finished:
                return
            self._finished = True
        if self.proc is not None:
            _kill_group(self.proc, self.mgr.term_grace_s)
        self._cleanup()
        self.mgr.session_done(self, ok, None if ok else detail, account_hint)

    def _cleanup(self):
        """Idempotent: drops the buffers, closes the PTY, removes the pid file, then releases the global lock
        (in that order, so a login started the instant the lock frees never meets this one's pid file)."""
        with self._state_lock:
            if self._cleaned:
                return
            self._cleaned = True
            self._ring = self._after = ""
            self._collect_after = False
        with self._master_lock:
            master, self.master = self.master, None
        if master is not None:
            with contextlib.suppress(OSError):
                os.close(master)
        path = os.path.join(self.mgr.home, PID_FILE)
        with contextlib.suppress(OSError, ValueError):
            with open(path, "rb") as f:
                record = json.loads(f.read(512).decode("utf-8"))
            if isinstance(record, dict) and self.proc is not None and record.get("pid") == self.proc.pid:
                os.unlink(path)
        lock_fd, self.lock_fd = self.lock_fd, None
        if lock_fd is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            with contextlib.suppress(OSError):
                os.close(lock_fd)


# -- the manager: one per relay client -------------------------------------------------------------------
class LoginManager:
    """Owns the current login, the last result, what the phone is told about Claude Code's state and the
    rules around starting one (opt-in, one at a time, rate limit). Thread-safe: the relay client calls it
    from its stream thread and its state loop, each login runs on a thread of its own."""

    def __init__(self, heimdall_home, env, now=time.time, *, emit=None, on_change=None):
        self.home = heimdall_home
        self.env = dict(env)
        self.now = now
        self._emit_fn = emit
        self._on_change = on_change
        # tunables: the module's defaults, shortened per instance by the tests
        self.lifetime_s = LIFETIME_S
        self.no_url_s = NO_URL_S
        self.prompt_wait_s = PROMPT_WAIT_S
        self.result_s = RESULT_S
        self.term_grace_s = TERM_GRACE_S
        self.status_timeout_s = STATUS_TIMEOUT_S
        self.rate_max = RATE_MAX
        self.rate_window_s = RATE_WINDOW_S
        self.probe_every_s = PROBE_EVERY_S
        self.current = None
        self.last_result = None
        self.cc = {"status": "unknown", "method": "none", "account_hint": None, "config_dir": None, "checked_at": 0}
        self._last_closed = None
        self._starts = []
        self._config_cache = None
        self._atexit_registered = False
        self._lock = threading.RLock()
        self._start_lock = threading.Lock()
        self._probe_lock = threading.Lock()

    # -- plumbing ---------------------------------------------------------------------------------------
    def _emit(self, obj):
        if self._emit_fn is not None:
            with contextlib.suppress(OSError, ValueError):  # a closed log must never break a login
                self._emit_fn(obj)

    def report_error(self, detail):
        self._emit({"event": "error", "detail": detail})

    def changed(self):
        """Something the phone sees changed: have the next state tick send it."""
        if self._on_change is not None:
            try:
                self._on_change()
            except Exception as e:  # re-arming the state send must never break a login
                self.report_error("login: state re-arm failed: %s" % type(e).__name__)

    def child_env(self):
        env = dict(self.env)
        env.update({"TERM": "dumb", "NO_COLOR": "1", "BROWSER": "/usr/bin/false"})
        return env

    def which_claude(self):
        return shutil.which("claude", path=self.env.get("PATH") or os.defpath)

    def auth_status(self, claude):
        return _parse_status(*_run([claude, "auth", "status"], self.child_env(), self.status_timeout_s))

    def logout(self, claude):
        returncode, _out = _run([claude, "auth", "logout"], self.child_env(), self.status_timeout_s)
        if returncode != 0:
            self.report_error("login: `claude auth logout` did not succeed after a login that was refused")

    # -- the laptop's switch ----------------------------------------------------------------------------
    def config(self):
        path = os.path.join(self.home, CONFIG_FILE)
        try:
            st = os.stat(path)
            stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
        except OSError:
            stamp = None
        with self._lock:
            if self._config_cache is not None and self._config_cache[0] == stamp:
                return self._config_cache[1]
            cfg = read_config(self.home)
            self._config_cache = (stamp, cfg)
            return cfg

    def enabled(self):
        """Properly enabled: switched on AND something to authenticate the account against (a pin, or
        --pin-next). A file that says enabled with neither is treated as off."""
        cfg = self.config()
        return cfg["enabled"] and (cfg["pin"] is not None or cfg["pin_next"])

    # -- start / code / cancel --------------------------------------------------------------------------
    def start(self, kind, *, caps_ok=True):
        """Starts `claude auth login` for `kind` and returns {"id"[, "dup": True]}; LoginError otherwise.
        Refusals, in the doc's order: remote-login-off, caps-missing, a live request (same kind: the same id
        with dup), busy, rate-limited, claude-not-found, overridden-by-env, spawn-failed."""
        try:
            result = self._start(kind, caps_ok)
        except LoginError as e:
            self._emit({"event": "login", "phase": "start", "id": None, "ok": False, "detail": e.code})
            raise
        self._emit({"event": "login", "phase": "start", "id": result["id"], "ok": True,
                    "detail": "dup" if result.get("dup") else None})
        return result

    def _start(self, kind, caps_ok):
        if not isinstance(kind, str) or kind not in KINDS:
            raise LoginError("bad-params", "kind must be claudeai or console")
        if not self.enabled():
            raise LoginError("remote-login-off", "remote login is not enabled on this laptop")
        if not caps_ok:
            raise LoginError("caps-missing", "the phone did not list login-v1")
        with self._start_lock:
            with self._lock:
                live = self.current
            if live is not None:
                if live.kind == kind:
                    return {"id": live.id, "dup": True}
                raise LoginError("busy", "another login is already live")
            lock_fd = self._take_global_lock()
            session = None
            try:
                self._count_attempt()
                claude = self.which_claude()
                if not claude:
                    raise LoginError("claude-not-found", "claude is not on this process's PATH")
                self._refuse_if_overridden(claude)
                session = LoginSession(self, kind, lock_fd)
                session.spawn(claude)
            except BaseException:
                if session is None or session.proc is None:
                    with contextlib.suppress(OSError):
                        fcntl.flock(lock_fd, fcntl.LOCK_UN)
                    with contextlib.suppress(OSError):
                        os.close(lock_fd)
                else:
                    session._cleanup()
                raise
            with self._lock:
                self.current = session
                self.last_result = None  # kept "until the next login_start"
                if not self._atexit_registered:
                    self._atexit_registered = True
                    atexit.register(self._atexit)
            session.start_thread()
        return {"id": session.id}

    def _take_global_lock(self):
        """The one-login-at-a-time lock, shared by every relay client of this user (flock: it dies with its
        holder, so a crashed client never leaves it stuck). LoginError("busy") when another holds it."""
        try:
            os.makedirs(self.home, mode=0o700, exist_ok=True)
            fd = os.open(os.path.join(self.home, LOCK_FILE), os.O_RDWR | os.O_CREAT, 0o600)
        except OSError:
            raise LoginError("spawn-failed", "cannot create the login lock file") from None
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            raise LoginError("busy", "another login is running on this laptop") from None
        return fd

    def _count_attempt(self):
        now = self.now()
        with self._lock:
            self._starts = [t for t in self._starts if now - t < self.rate_window_s]
            if len(self._starts) >= self.rate_max:
                raise LoginError("rate-limited", "too many login starts; try again later")
            self._starts.append(now)

    def _refuse_if_overridden(self, claude):
        if self.env.get("ANTHROPIC_AUTH_TOKEN"):
            raise LoginError("overridden-by-env", "ANTHROPIC_AUTH_TOKEN outranks a login")
        result = self.auth_status(claude)
        if result is not None and result["json"] is not None and _is_overridden(result["json"]):
            raise LoginError("overridden-by-env", "a key or token from the environment outranks a login")

    def _dead_reason(self, req_id):
        closed = self._last_closed
        if closed is not None and closed["id"] == req_id:
            if closed["detail"] == "expired":
                return "expired"
            if closed["submitted"]:
                return "already-submitted"
        return "unknown-id"

    def submit_code(self, req_id, code):
        """Types the phone's code into the live login: {"id", "phase": "verifying"}; LoginError(unknown-id |
        expired | already-submitted | bad-code | bad-params) otherwise, writing nothing. The outcome comes
        later, in snapshot()["result"]."""
        try:
            result = self._submit_code(req_id, code)
        except LoginError as e:
            self._emit({"event": "login", "phase": "code", "id": req_id if _valid_id(req_id) else None,
                        "ok": False, "detail": e.code})
            raise
        self._emit({"event": "login", "phase": "code", "id": result["id"], "ok": True, "detail": None})
        return result

    def _submit_code(self, req_id, code):
        if not _valid_id(req_id):
            raise LoginError("bad-params", "id must be a request id")
        with self._lock:
            session = self.current
        if session is None or session.id != req_id:
            raise LoginError(self._dead_reason(req_id), "no live request has that id")
        normalized = normalize_code(code)
        if "#" not in normalized:
            raise LoginError("bad-code", "the CLI needs CODE#STATE; a bare code is refused before it is spent")
        if not self.enabled():  # switched off at the laptop while the request was out: nothing runs
            session.request_abort("cancelled")
            session.done.wait(self.term_grace_s + 10)
            raise LoginError("unknown-id", "remote login was switched off")
        return session.submit(normalized)

    def cancel(self, req_id):
        """Ends the live login `req_id` (cancelled). A request that is unknown, finished or already has its
        code in flight is left alone and reported unchanged: once the code is typed the exchange cannot be
        undone from here, only verified."""
        if not _valid_id(req_id):
            raise LoginError("bad-params", "id must be a request id")
        with self._lock:
            session = self.current
        if session is None or session.id != req_id or session.submitted:
            return {"id": req_id, "detail": "unchanged"}
        session.request_abort("cancelled")
        session.done.wait(self.term_grace_s + 10)
        return {"id": req_id}

    def session_done(self, session, ok, detail, account_hint):
        """A login ended (called by its thread once its process is dead and its lock released)."""
        result = {"id": session.id, "ok": bool(ok), "detail": detail, "at": int(self.now()),
                  "account_hint": account_hint if ok else None, "restart_needed": bool(ok)}
        with self._lock:
            if self.current is session:
                self.current = None
            self.last_result = result
            self._last_closed = {"id": session.id, "submitted": session.submitted, "detail": detail}
        self._emit({"event": "login", "phase": "result", "id": session.id, "ok": bool(ok), "detail": detail})
        self.changed()

    # -- what the phone is told -------------------------------------------------------------------------
    def snapshot(self):
        """state.login (spec 4.2): enabled, cc, request, result. Masked account only, never an address."""
        enabled = self.enabled()
        now = self.now()
        with self._lock:
            session = self.current
            result = self.last_result
            if result is not None and now - result["at"] > RESULT_KEEP_S:
                result = self.last_result = None
            cc = dict(self.cc)
            result = dict(result) if result is not None else None
        return {"enabled": enabled, "cc": cc, "request": session.public() if session is not None else None,
                "result": result}

    def cc_from(self, result):
        """state.login.cc for one `claude auth status` run (None: it could not be run or understood)."""
        now = int(self.now())
        if result is None or result["json"] is None:
            return {"status": "unknown", "method": "none", "account_hint": None, "config_dir": None, "checked_at": now}
        status = result["json"]
        method = status.get("authMethod")
        logged_in = result["rc"] == 0 and status.get("loggedIn") is True
        state = "signed-out" if not logged_in else ("overridden" if _is_overridden(status) else "ok")
        home = self.env.get("HOME") or os.path.expanduser("~")
        return {"status": state, "method": method if method in AUTH_METHODS else "none",
                "account_hint": mask_account(status.get("email")),
                "config_dir": _short_home(status.get("configDirectory"), home), "checked_at": now}

    def set_cc(self, cc):
        with self._lock:
            before = {k: v for k, v in self.cc.items() if k != "checked_at"}
            self.cc = dict(cc)
        if before != {k: v for k, v in cc.items() if k != "checked_at"}:
            self.changed()

    def probe(self):
        """`claude auth status` -> state.login.cc. Never two at once, never while a login is live (both
        return what is already known). Never raises."""
        if not self._probe_lock.acquire(blocking=False):
            return dict(self.cc)
        try:
            with self._lock:
                live = self.current is not None
            if not live:
                claude = self.which_claude()
                self.set_cc(self.cc_from(self.auth_status(claude) if claude else None))
            return dict(self.cc)
        finally:
            self._probe_lock.release()

    def run_probe_loop(self, stop_event, every=None, tick=5.0):
        """Blocks until `stop_event`: probes while remote login is enabled (at once when it is switched on,
        then every `every` seconds) and re-sends the state when the laptop's switch flips. While it is off
        nothing is run -- no `claude` process, no keychain read."""
        every = self.probe_every_s if every is None else every
        was_enabled = self.enabled()
        next_probe = 0.0
        while not stop_event.is_set():
            enabled = self.enabled()
            if enabled != was_enabled:
                was_enabled = enabled
                next_probe = 0.0
                self.changed()
            if enabled and time.monotonic() >= next_probe:
                self.probe()
                next_probe = time.monotonic() + every
            stop_event.wait(tick)

    # -- teardown ---------------------------------------------------------------------------------------
    def shutdown(self, detail="superseded"):
        """Ends the live login (relay client exit, a replaced phone). A verification that is already running
        is allowed to finish first (bounded): the pin check must not be skipped by an exit."""
        with self._lock:
            session = self.current
        if session is None:
            return
        if session.in_verify:
            session.done.wait(VERIFY_JOIN_S)
        session.request_abort(detail)
        session.done.wait(self.term_grace_s + 10)

    def _atexit(self):
        session = self.current
        if session is not None:
            session.emergency_kill()

    def sweep_orphan(self):
        """At relay-client start: kills the process group of a `claude auth login` an earlier client left
        behind (named by the pid file), but only while that pid still runs `claude auth login`. True when a
        group was killed. The pid file is removed either way."""
        path = os.path.join(self.home, PID_FILE)
        try:
            with open(path, "rb") as f:
                record = json.loads(f.read(512).decode("utf-8"))
        except (OSError, ValueError):
            record = None
        pid = record.get("pid") if isinstance(record, dict) else None
        killed = False
        if isinstance(pid, int) and not isinstance(pid, bool) and pid > 1 and _is_login_process(pid):
            killed = _terminate_group(pid, self.term_grace_s)
        with contextlib.suppress(OSError):
            os.unlink(path)
        return killed


# -- the laptop's side: `hmd app remote-login on [--pin-next] | off | status` ----------------------------
def _age(seconds):
    if seconds < 90:
        return "%ds" % seconds
    if seconds < 5400:
        return "%dm" % (seconds // 60)
    if seconds < 172800:
        return "%dh" % (seconds // 3600)
    return "%dd" % (seconds // 86400)


def _last_result(repo, env):
    """"ok 12m ago" / "failed (invalid-code) 3m ago" / "none" -- from the relay client's event log."""
    path = env.get("HMD_RELAY_EVENT_LOG") if "HMD_RELAY_EVENT_LOG" in env else os.path.join(
        repo, ".heimdall", "app", "relay-events.jsonl")
    if not path:
        return "none"
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 65536))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return "none"
    for line in reversed(lines):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("event") == "login" and row.get("phase") == "result":
            ago = ""
            with contextlib.suppress(ValueError, KeyError, TypeError, OverflowError):
                stamp = time.strptime(row["ts"][:19], "%Y-%m-%dT%H:%M:%S")
                ago = " %s ago" % _age(max(0, int(time.time() - calendar.timegm(stamp))))
            return ("ok" if row.get("ok") else "failed (%s)" % row.get("detail")) + ago
    return "none"


def main(argv=None, out=None, env=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    out = sys.stdout if out is None else out
    env = dict(os.environ) if env is None else dict(env)
    command = argv[0] if argv else ""
    rest = argv[1:]
    repo = os.getcwd()
    pin_next = False
    i = 0
    while i < len(rest):
        if rest[i] == "--pin-next" and command == "on":
            pin_next = True
        elif rest[i] == "--repo" and i + 1 < len(rest):
            repo = rest[i + 1]
            i += 1
        else:
            command = ""
        i += 1
    home = heimdall_home(env)
    mgr = LoginManager(home, env)
    if command == "off":
        write_config(home, False)
        out.write("remote login: off\n")
        return 0
    if command == "on":
        return _cli_on(mgr, home, pin_next, out)
    if command == "status":
        return _cli_status(mgr, home, repo, env, out)
    if command == "status-line":
        cfg = read_config(home)
        state = "on" + (" (pinned)" if cfg["pin"] else " (will pin the next login)") if mgr.enabled() else "off"
        out.write("remote login: %s - last: %s\n" % (state, _last_result(repo, env)))
        return 0
    sys.stderr.write("usage: hmd app remote-login on [--pin-next] | off | status [--repo DIR]\n")
    return 2


def _probe(mgr):
    """(claude path or None, `auth status` result or None, the signed-in status JSON or None)."""
    claude = mgr.which_claude()
    result = mgr.auth_status(claude) if claude else None
    signed_in = result["json"] if result is not None and result["rc"] == 0 else None
    return claude, result, signed_in


def _cli_on(mgr, home, pin_next, out):
    if pin_next:
        write_config(home, True, pin=None, pin_next=True)
        out.write("remote login: on (the next successful remote login will set the pin)\n")
        return 0
    claude, result, status = _probe(mgr)
    if not claude:
        out.write("remote login: not enabled -- `claude` is not on PATH, so there is no account to pin\n")
        return 1
    if result is None or result["json"] is None:
        out.write("remote login: not enabled -- `claude auth status` gave no answer\n")
        return 1
    if _is_overridden(result["json"]):
        out.write("remote login: not enabled -- Claude Code here uses a key or token from its environment, "
                  "which outranks a login\n")
        return 1
    fingerprint = identity_fingerprint(status)
    if fingerprint is None:
        out.write("remote login: not enabled -- Claude Code is signed out on this laptop: sign in here first, "
                  "or run `hmd app remote-login on --pin-next` to pin the next remote login\n")
        return 1
    write_config(home, True, pin=fingerprint)
    out.write("remote login: on (pinned to %s)\n" % mask_account(status.get("email")))
    return 0


def _cli_status(mgr, home, repo, env, out):
    cfg = read_config(home)
    claude, result, status = _probe(mgr)
    account = mask_account(status.get("email")) if status else None
    out.write("remote login: %s\n" % ("on" if mgr.enabled() else "off"))
    if cfg["pin"] is not None:
        same = status is not None and identity_fingerprint(status) == cfg["pin"]
        out.write("pin: %s\n" % ("pinned to %s" % account if same and account else "set (not the account signed in now)"))
    elif cfg["pin_next"]:
        out.write("pin: none yet -- the first successful remote login sets it\n")
    else:
        out.write("pin: none\n")
    if not claude:
        out.write("claude: not found on PATH\n")
    elif result is None or result["json"] is None:
        out.write("claude: `auth status` gave no answer\n")
    elif status is None:
        out.write("claude: signed out\n")
    else:
        out.write("claude: signed in as %s\n" % (account or "an account without an address"))
        out.write("config dir: %s\n" % _short_home(status.get("configDirectory"), env.get("HOME") or os.path.expanduser("~")))
    out.write("last result: %s\n" % _last_result(repo, env))
    return 0


if __name__ == "__main__":
    sys.exit(main())

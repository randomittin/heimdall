#!/usr/bin/env python3
"""companion_ui_controls.py -- the paired phone's remote controls over a running hmd session
(hmdapp docs/HANDOFF-TO-HEIMDALL-remote-controls.md H1-H6, its spec docs/superpowers/specs/2026-10-02-remote-controls.md,
and CP1 of docs/HANDOFF-TO-HEIMDALL-cursor-parity.md).

ONE dispatcher, ONE allowlist. bin/heimdall-relay-client (the sealed `command` frame) and sentinels/hmd-ui.py
(POST /api/control) both call dispatch(); neither knows any action's rules, so the two transports cannot drift.
Everything that reaches dispatch() already passed its transport's own gate: a relay frame opened under the paired
device's latched session key and passed the replay guard, a direct request passed the token / Host / backoff gate.

WIRE. Command plaintext is `{"action": A, "params": {...}}` for A in ALLOWED_ACTIONS. `params` is an exact key set
(the action's keys plus an optional `rid`), exact types, and the whole command is at most 1 KiB, else `bad-params`.

    interrupt         {}                          ack ok  {"id":"s-<8 hex>","result":{"via":"hook","effective":
                                                  "next-tool-boundary"}}; detail already-pending (same id) | not-running
    save-checkpoint   {}                          ack ok  {"result":{"written_at":<epoch>}}; detail coalesced | incomplete
    hook-toggle       {"id": str, "enabled": bool} ack ok  {"result":{"id","enabled"}}; detail unchanged | not-allowed |
                                                  unknown-id | write-failed
    fallback-mode     {"mode": "off"|"auto"|"switch", "confirm"?: true}
                                                  ack ok  {"result":{"mode","was"}}; detail unchanged | confirm-required |
                                                  write-failed | unavailable

Every refusal is `{"ok": false, "detail": <code>}`; the codes common to all four are `not-implemented` (unknown
action), `bad-params`, `controls-off` (kill switch), `rate-limited` (+ `retry_after_s`), `timeout` (the 5 s bound ran
out: the effect may have landed, the next state frame is the truth), `internal-error`. A repeated `rid` is answered
with the stored ack plus `dup: true` and the handler does not run again. dispatch() returns (ok, detail, extra); `extra`
is merged into the sealed ack next to ok / of_seq / detail and holds only `id`, `result` (<= 1 KiB, hmd-computed values,
never free text), `dup`, `retry_after_s`.

STATE. snapshot() is the additive `controls` key of /api/state (so of every relay state frame):
    {"v":1,"actions":[..usable now..],"hooks_toggleable":[ids],"hooks":[{"id","enabled"}..],
     "fallback":{"mode":..,"modes":["off","auto","switch"],"confirm":["auto","switch"]},"enabled":bool,
     "last":{"action","ok","at"}|null}
`hooks_toggleable` / `hooks` are the hooks whose sidecar entry says `remote_toggle: true` and `locked: false`;
`last` is the newest line of the audit log, params left out.

SECURITY MODEL.
  * One allowlist, fail closed: an action not in ALLOWED_ACTIONS is `not-implemented` and audited. A hook is toggleable
    only when hooks/hooks.metadata.json says `remote_toggle: true` AND `locked: false` -- a hand-set flag, false for every
    new hook; a locked gate can never be switched off from here even if someone hand-edits the sidecar.
  * Reduce-direction first: `interrupt` ends work, `hook-toggle` only reaches advisory hooks, `fallback-mode` `off` is the
    safe state. The two states that ROUTE (`auto`, `switch` -- both reach the main agent, owner directive 2026-09-11) are
    refused unless the command carries `confirm: true`. `coop` is not settable from the phone at all.
  * No shell, argv lists only, every id matched against a fixed pattern before any path or argv is built. A phone-supplied
    string is never written to disk, logged or echoed: the audit line carries only whitelisted, pattern-checked fields
    (never `rid`, never text), and a field that is secret-shaped is dropped.
  * Kill switch: env HMD_UI_CONTROLS=0, or the file <repo>/.heimdall/app/controls-disabled (`hmd app controls off`):
    every action returns `controls-off`. Neither can be flipped by any action in this module.
  * Rate limits (token buckets, per repo, in memory): all controls 10/min burst 5; interrupt 3/min; hook-toggle 6/min;
    fallback-mode 3/min; save-checkpoint is not refused but COALESCED (a second save within 5 s of a good one is ok).
  * Every command -- ok, refused, unknown -- appends one line to <repo>/.heimdall/ui/controls-audit.jsonl (0600, dir 0700,
    O_APPEND + fsync, rotated at 1 MiB to `.1`). A write failure disables the log for the rest of the process with ONE
    stderr notice and never blocks a command.

INTERRUPT -- what was investigated and what ships. Claude Code has no external interrupt API; the options on this machine:
  1. A hook returning {"continue": false, "stopReason": ..} is the only documented lever (the phone-deny hook already
     uses it). It lands at the next tool boundary, so a single long Bash or pure generation is not cut until it ends.
     SHIPPED: handler writes <repo>/.heimdall/ui/stop-request.json (atomic, 0600); bin/heimdall-phone-control, wired on
     PreToolUse + PostToolUse (fast path: one `[ -f ]`), consumes it once and prints the stop; UserPromptSubmit deletes a
     stale one; a request older than 120 s is deleted unused. Only for an attended session.
  2. `tmux send-keys -t <target> Escape` -- the same operator-configured target bin/heimdall-inbox-deliver's tmux mode
     already uses (HMD_TMUX_TARGET, else .heimdall/ui/tmux-target). One fixed key, argv list, 2 s bound; only when the
     operator configured a target. Reported as via "tmux+hook".
  3. SIGINT / SIGTERM to the claude pid -- REFUSED, not built. The only signalable pid is the session itself and killing
     it destroys all live work (bin/heimdall-agents header, measured 2026-08-03); the TUI reads Ctrl-C as a keystroke on
     the pty, not as a signal; and nothing maps "this repo's running turn" to one pid when several sessions run.
`not-running` unless the repo's session is `working` (companion_ui_attention), and nothing is written then.

Stdlib only. Self-contained (secret_shaped is ported from bin/lib/companion_ui_inbox.py, the way the decisions module ports
it) so every caller can load this one file by path.
"""
import argparse
import calendar
import collections
import fcntl
import hashlib
import json
import math
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))
BIN_DIR = os.path.normpath(os.path.join(HERE, ".."))
PLUGIN_DIR = os.path.normpath(os.path.join(HERE, "..", ".."))

CONTROL_DEADLINE_S = 5.0          # a synchronous handler's whole budget; past it the command is `timeout`
MAX_COMMAND_BYTES = 1024          # the whole command plaintext
MAX_RESULT_BYTES = 1024           # an ack's `result`, serialized
RID_MEMORY = 64                   # rid -> ack pairs kept per repo
STOP_TTL_S = 120.0                # a stop request older than this is never honoured
CHECKPOINT_COALESCE_S = 5.0       # a save within this of a good one is `coalesced`
AUDIT_MAX_BYTES = 1024 * 1024
KILL_SWITCH_ENV = "HMD_UI_CONTROLS"
HOOKS_METADATA_ENV = "HMD_HOOKS_METADATA"   # the same override bin/lib/hook-enabled.sh honours

AUDIT_REL = os.path.join(".heimdall", "ui", "controls-audit.jsonl")
KILL_SWITCH_REL = os.path.join(".heimdall", "app", "controls-disabled")
STOP_REQUEST_REL = os.path.join(".heimdall", "ui", "stop-request.json")
STOP_CONSUMED_REL = os.path.join(".heimdall", "ui", "stop-request.consumed")
CHECKPOINT_LOCK_REL = os.path.join(".heimdall", "ui", "controls-checkpoint.lock")
CHECKPOINT_FILE_REL = os.path.join(".planning", "CHECKPOINT.md")

FALLBACK_MODES = ("off", "auto", "switch")     # all the phone may set; `coop` is a laptop-only, per-role state
FALLBACK_STATES = ("off", "auto", "switch", "coop")   # what heimdall-fallback can report
CONFIRM_MODES = ("auto", "switch")             # the states that route the main agent: explicit confirm only

RID_RE = re.compile(r"[A-Za-z0-9_-]{1,32}")
HOOK_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
ACTION_NAME_RE = re.compile(r"[A-Za-z0-9_-]{1,40}")
STOP_ID_RE = re.compile(r"s-[0-9a-f]{8}")

# -- secret scrub: bin/lib/companion_ui_inbox.py, itself bin/heimdall-activity's, ported -----------------------------
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


class _Refusal(Exception):
    """A command refused with a machine-readable `detail` (and, for a rate limit, `retry_after_s`)."""

    def __init__(self, detail, extra=None):
        super().__init__(detail)
        self.detail = detail
        self.extra = extra or {}


class _Timeout(Exception):
    """The handler's CONTROL_DEADLINE_S ran out."""


# -- small shared helpers ---------------------------------------------------------------------------------------
def heimdall_home():
    """$HEIMDALL_HOME, else ~/.heimdall -- bin/heimdall-hooks' own resolution, so a toggle written by that CLI is read
    from the same hooks-disabled."""
    override = os.environ.get("HEIMDALL_HOME")
    if override:
        return override
    return os.path.join(os.environ.get("HOME") or "/tmp", ".heimdall")


def device_id_of(device_pub):
    """The audit's `device`: the first 8 hex of sha256 of the bound device's raw public key."""
    if isinstance(device_pub, (bytes, bytearray)) and device_pub:
        return hashlib.sha256(bytes(device_pub)).hexdigest()[:8]
    return "unknown"


def _ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    os.chmod(path, 0o700)


def _read_json(path, cap=65536):
    try:
        with open(path, "rb") as f:
            obj = json.loads(f.read(cap).decode("utf-8"))
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


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


def _bin(name):
    return os.path.join(BIN_DIR, name)


def _usable_tool(name):
    return os.access(_bin(name), os.X_OK)


def _kill_group(proc):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except OSError:
            return
        try:
            proc.wait(timeout=0.5)
            return
        except subprocess.TimeoutExpired:
            continue


def _run_argv(argv, deadline, env=None, cwd=None):
    """(returncode, stdout) of an argv list (never a shell), killed with its process group when `deadline`
    (time.monotonic) passes: raises _Timeout. stderr is discarded -- no tool's message is ever relayed."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise _Timeout()
    proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, start_new_session=True, text=True, errors="replace")
    try:
        out, _ = proc.communicate(timeout=remaining)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        raise _Timeout()
    return proc.returncode, out


# -- kill switch ------------------------------------------------------------------------------------------------
def controls_enabled(root):
    """False when HMD_UI_CONTROLS=0 or <repo>/.heimdall/app/controls-disabled exists. Read on every call."""
    if os.environ.get(KILL_SWITCH_ENV) == "0":
        return False
    return not os.path.exists(os.path.join(root, KILL_SWITCH_REL))


def set_enabled(root, enabled):
    """`hmd app controls on|off`: remove / create the kill-switch file. Idempotent."""
    path = os.path.join(root, KILL_SWITCH_REL)
    if enabled:
        try:
            os.unlink(path)
        except FileNotFoundError:
            return
        return
    _ensure_dir(os.path.dirname(path))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n").encode("ascii"))
    finally:
        os.close(fd)


# -- audit ------------------------------------------------------------------------------------------------------
_AUDIT_OFF = set()
_LAST_CACHE = {}


def _iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def _audit(root, line):
    if root in _AUDIT_OFF:
        return
    try:
        _ensure_dir(os.path.join(root, ".heimdall", "ui"))
        path = os.path.join(root, AUDIT_REL)
        try:
            if os.stat(path).st_size >= AUDIT_MAX_BYTES:
                os.replace(path, path + ".1")
        except OSError:
            _LAST_CACHE.pop(path, None)
        data = (json.dumps(line, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as e:
        _AUDIT_OFF.add(root)
        sys.stderr.write("companion_ui_controls: audit log disabled for this process (%s)\n" % type(e).__name__)


def _tail_last(path, size):
    try:
        with open(path, "rb") as f:
            f.seek(max(0, size - 8192))
            chunk = f.read(8192)
    except OSError:
        return None
    for raw in reversed(chunk.splitlines()):
        try:
            obj = json.loads(raw.decode("utf-8"))
            ts = obj["ts"]
            at = calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) + float("0" + ts[19:-1])
            action, ok = obj["action"], obj["ok"]
        except (ValueError, KeyError, TypeError, UnicodeDecodeError):
            continue
        if isinstance(action, str) and isinstance(ok, bool):
            return {"action": action, "ok": ok, "at": round(at, 3)}
    return None


def last_control(root):
    """{action, ok, at} of the newest audit line (params never), or None. Stat-cached: an unchanged log costs a stat."""
    base = os.path.join(root, AUDIT_REL)
    for path in (base, base + ".1"):
        try:
            st = os.stat(path)
        except OSError:
            continue
        stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
        hit = _LAST_CACHE.get(path)
        if hit is not None and hit[0] == stamp:
            value = hit[1]
        else:
            value = _tail_last(path, st.st_size)
            _LAST_CACHE[path] = (stamp, value)
        if value is not None:
            return value
    return None


def audit_count(root):
    """How many commands the audit log (current generation) holds -- for `hmd app status`."""
    try:
        with open(os.path.join(root, AUDIT_REL), "rb") as f:
            return sum(1 for _ in f)
    except OSError:
        return 0


# -- hooks registry (hooks/hooks.metadata.json) -----------------------------------------------------------------
_SIDECAR_CACHE = {}


def hooks_metadata_path():
    return os.environ.get(HOOKS_METADATA_ENV) or os.path.join(PLUGIN_DIR, "hooks", "hooks.metadata.json")


def _sidecar_entries():
    path = hooks_metadata_path()
    try:
        st = os.stat(path)
    except OSError:
        return []
    stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
    hit = _SIDECAR_CACHE.get(path)
    if hit is not None and hit[0] == stamp:
        return hit[1]
    data = _read_json(path, cap=1024 * 1024) or {}
    entries = [e for e in (data.get("hooks") or []) if isinstance(e, dict) and isinstance(e.get("id"), str)]
    _SIDECAR_CACHE[path] = (stamp, entries)
    return entries


def _toggleable(entry):
    """The one allowlist rule: a hand-set `remote_toggle: true` on an entry that is not locked."""
    return entry.get("remote_toggle") is True and not entry.get("locked")


def toggleable_hooks():
    return [e["id"] for e in _sidecar_entries() if _toggleable(e) and HOOK_ID_RE.fullmatch(e["id"])]


def _disabled_ids():
    try:
        with open(os.path.join(heimdall_home(), "hooks-disabled"), "r", encoding="utf-8") as f:
            return {line.strip() for line in f if line.strip()}
    except OSError:
        return set()


# -- the stop request: interrupt's file protocol (handler writes, bin/heimdall-phone-control reads) ---------------
def _stop_path(root):
    return os.path.join(root, STOP_REQUEST_REL)


def _stop_fresh(record, now):
    requested = record.get("requested_at") if isinstance(record, dict) else None
    if isinstance(requested, bool) or not isinstance(requested, (int, float)):
        return False
    return -5.0 <= now - requested < STOP_TTL_S


def _pending_stop(root, now):
    record = _read_json(_stop_path(root))
    if record is not None and _stop_fresh(record, now) and isinstance(record.get("id"), str) \
            and STOP_ID_RE.fullmatch(record["id"]):
        return record
    return None


def _write_stop(root, record):
    _ensure_dir(os.path.join(root, ".heimdall", "ui"))
    path = _stop_path(root)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    finally:
        os.close(fd)
    os.replace(tmp, path)


def consume_stop_request(root, now=None):
    """The hook's half: take the pending stop request exactly once. Returns its record when it was fresh (younger than
    STOP_TTL_S) and is now renamed to stop-request.consumed; None when there was none, another hook already took it, it
    was too old (deleted) or unreadable (deleted). The claim is an atomic rename, so two hooks cannot both stop."""
    now = time.time() if now is None else now
    path = _stop_path(root)
    claim = "%s.claim.%d" % (path, os.getpid())
    try:
        os.rename(path, claim)
    except OSError:
        return None
    record = _read_json(claim)
    if record is not None and _stop_fresh(record, now):
        os.replace(claim, os.path.join(root, STOP_CONSUMED_REL))
        return record
    try:
        os.unlink(claim)
    except OSError:
        return None
    return None


def clear_stop_request(root):
    """UserPromptSubmit's half: drop a pending request so a stale one can never stop the NEXT turn."""
    try:
        os.unlink(_stop_path(root))
    except OSError:
        return False
    return True


# -- parameter rules --------------------------------------------------------------------------------------------
def _no_fields(body):
    return {}


def _hook_toggle_fields(body):
    hook_id, enabled = body["id"], body["enabled"]
    if not (isinstance(hook_id, str) and HOOK_ID_RE.fullmatch(hook_id)) or not isinstance(enabled, bool):
        raise _Refusal("bad-params")
    return {"id": hook_id, "enabled": enabled}


def _fallback_fields(body):
    mode, confirm = body["mode"], body.get("confirm", False)
    if not isinstance(mode, str) or mode not in FALLBACK_MODES or not isinstance(confirm, bool):
        raise _Refusal("bad-params")
    return {"mode": mode, "confirm": confirm}


def _audit_hook_toggle(fields):
    return {"id": fields["id"], "enabled": fields["enabled"]} if not secret_shaped(fields["id"]) \
        else {"enabled": fields["enabled"]}


def _audit_fallback(fields):
    return {"mode": fields["mode"], "confirm": fields["confirm"]}


def _validate(action, params):
    """(rid, fields) for a well-formed command, else _Refusal("bad-params"). Exact key set, exact types, <= 1 KiB."""
    spec = _ACTIONS[action]
    if params is None:
        params = {}
    if not isinstance(params, dict):
        raise _Refusal("bad-params")
    size = len(json.dumps({"action": action, "params": params}, separators=(",", ":")).encode("utf-8"))
    if size > MAX_COMMAND_BYTES:
        raise _Refusal("bad-params")
    rid = params.get("rid")
    if "rid" in params and not (isinstance(rid, str) and RID_RE.fullmatch(rid)):
        raise _Refusal("bad-params")
    body = {k: v for k, v in params.items() if k != "rid"}
    keys = set(body)
    if not set(spec["required"]) <= keys or not keys <= set(spec["required"]) | set(spec["optional"]):
        raise _Refusal("bad-params")
    return rid, spec["fields"](body)


# -- rate limits ------------------------------------------------------------------------------------------------
class _Bucket:
    """A token bucket: `capacity` tokens (the burst), refilled at `per_s` tokens a second."""

    def __init__(self, capacity, per_s):
        self.capacity = float(capacity)
        self.per_s = per_s
        self.tokens = float(capacity)
        self.at = time.monotonic()

    def _refill(self, now):
        self.tokens = min(self.capacity, self.tokens + (now - self.at) * self.per_s)
        self.at = now

    def wait(self, now):
        """Seconds until a token is available (0.0 when one is now)."""
        self._refill(now)
        return 0.0 if self.tokens >= 1.0 else (1.0 - self.tokens) / self.per_s

    def take(self):
        self.tokens -= 1.0


_GLOBAL_RATE = (5, 10 / 60.0)    # all controls: 10 a minute, burst 5
_LOCK = threading.Lock()
_BUCKETS = {}                    # (root, bucket name) -> _Bucket
_RIDS = {}                       # root -> OrderedDict(rid -> (ok, detail, extra))
_CHECKPOINTS = {}                # root -> (monotonic, result) of the last good save


def _charge(root, action):
    """Take one token from every bucket this command draws on, or raise rate-limited with the longest wait. Nothing is
    taken when any bucket is empty, so a refused command never spends budget."""
    now = time.monotonic()
    names = [("*",) + _GLOBAL_RATE]
    rate = _ACTIONS[action]["rate"]
    if rate is not None:
        names.append((action,) + rate)
    with _LOCK:
        buckets = [_BUCKETS.setdefault((root, n), _Bucket(cap, per)) for n, cap, per in names]
        wait = max(b.wait(now) for b in buckets)
        if wait > 0:
            raise _Refusal("rate-limited", {"retry_after_s": max(1, int(math.ceil(wait)))})
        for b in buckets:
            b.take()


# -- handlers: (root, fields, ctx) -> (ok, detail, extra) --------------------------------------------------------
class _Ctx:
    def __init__(self, device_id, deadline):
        self.device_id = device_id
        self.deadline = deadline


def _attention(root):
    mod = _sibling("companion_ui_attention")
    if mod is None:
        return None
    try:
        return mod.collect(root)
    except Exception:
        return None


def _interrupt_result(via):
    return {"via": via, "effective": "next-tool-boundary"}


def _do_interrupt(root, fields, ctx):
    attention = _attention(root)
    if attention is None:
        return False, "unavailable", {}
    if attention.get("state") != "working":
        return False, "not-running", {}
    now = time.time()
    pending = _pending_stop(root, now)
    if pending is not None:
        return True, "already-pending", {"id": pending["id"], "result": _interrupt_result(pending.get("via") or "hook")}
    turn = attention.get("turn")
    record = {"id": "s-" + secrets.token_hex(4), "requested_at": round(now, 3),
              "turn": turn if isinstance(turn, int) and not isinstance(turn, bool) else None,
              "device": ctx.device_id}
    _write_stop(root, record)
    return True, None, {"id": record["id"], "result": _interrupt_result("hook")}


def _checkpoint_written_at(root):
    try:
        return int(os.stat(os.path.join(root, CHECKPOINT_FILE_REL)).st_mtime)
    except OSError:
        return int(time.time())


def _acquire_lock(path, deadline):
    _ensure_dir(os.path.dirname(path))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.monotonic() >= deadline:
                os.close(fd)
                raise _Timeout()
            time.sleep(0.05)


def _do_save_checkpoint(root, fields, ctx):
    fd = _acquire_lock(os.path.join(root, CHECKPOINT_LOCK_REL), ctx.deadline)
    try:
        last = _CHECKPOINTS.get(root)
        if last is not None and time.monotonic() - last[0] < CHECKPOINT_COALESCE_S:
            return True, "coalesced", {"result": last[1]}
        if not _usable_tool("heimdall-checkpoint"):
            return False, "unavailable", {}
        rc, _out = _run_argv([_bin("heimdall-checkpoint"), "write", root], ctx.deadline, cwd=root)
        if rc != 0:
            return False, "incomplete", {}
        result = {"written_at": _checkpoint_written_at(root)}
        _CHECKPOINTS[root] = (time.monotonic(), result)
        return True, None, {"result": result}
    finally:
        os.close(fd)


def _do_hook_toggle(root, fields, ctx):
    hook_id, enabled = fields["id"], fields["enabled"]
    entry = next((e for e in _sidecar_entries() if e["id"] == hook_id), None)
    if entry is None:
        return False, "unknown-id", {}
    if not _toggleable(entry):
        return False, "not-allowed", {}
    result = {"id": hook_id, "enabled": enabled}
    if (hook_id not in _disabled_ids()) == enabled:
        return True, "unchanged", {"result": result}
    if not _usable_tool("heimdall-hooks"):
        return False, "unavailable", {}
    argv = [_bin("heimdall-hooks"), "enable" if enabled else "disable", "--metadata", hooks_metadata_path(), hook_id]
    rc, _out = _run_argv(argv, ctx.deadline)
    if rc == 1:
        return False, "unknown-id", {}
    if rc == 2:
        return False, "not-allowed", {}
    if rc != 0 or (hook_id not in _disabled_ids()) != enabled:
        return False, "write-failed", {}
    return True, None, {"result": result}


def _fallback_state(root, deadline):
    """heimdall-fallback's own answer for this repo's state (off|auto|switch|coop), or None. Its loopback probe is
    bounded to 1 s unless the operator pinned a value, as sentinels/hmd-ui.py's collect_fallback does."""
    env = dict(os.environ)
    env.setdefault("HEIMDALL_FALLBACK_PROBE_TIMEOUT", "1")
    rc, out = _run_argv([_bin("heimdall-fallback"), "--repo", root, "status", "--json"], deadline, env=env)
    if rc != 0:
        return None
    try:
        state = json.loads(out).get("state")
    except (ValueError, AttributeError):
        return None
    return state if state in FALLBACK_STATES else None


def _do_fallback_mode(root, fields, ctx):
    mode = fields["mode"]
    if mode in CONFIRM_MODES and fields["confirm"] is not True:
        return False, "confirm-required", {}
    if not _usable_tool("heimdall-fallback"):
        return False, "unavailable", {}
    was = _fallback_state(root, ctx.deadline)
    if was is None:
        return False, "unavailable", {}
    if was == mode:
        return True, "unchanged", {"result": {"mode": mode}}
    rc, out = _run_argv([_bin("heimdall-fallback"), "--repo", root, "set", mode], ctx.deadline)
    if rc != 0 or "state set to '%s'" % mode not in out:
        return False, "write-failed", {}
    return True, None, {"result": {"mode": mode, "was": was}}


#            required keys        optional      field rules        audit rule         handler              rate (burst, /s)
_ACTIONS = {
    "interrupt": {"required": (), "optional": (), "fields": _no_fields, "audit": lambda f: {},
                  "handler": _do_interrupt, "rate": (3, 3 / 60.0)},
    "save-checkpoint": {"required": (), "optional": (), "fields": _no_fields, "audit": lambda f: {},
                        "handler": _do_save_checkpoint, "rate": None},
    "hook-toggle": {"required": ("id", "enabled"), "optional": (), "fields": _hook_toggle_fields,
                    "audit": _audit_hook_toggle, "handler": _do_hook_toggle, "rate": (6, 6 / 60.0)},
    "fallback-mode": {"required": ("mode",), "optional": ("confirm",), "fields": _fallback_fields,
                      "audit": _audit_fallback, "handler": _do_fallback_mode, "rate": (3, 3 / 60.0)},
}
ALLOWED_ACTIONS = frozenset(_ACTIONS)
ACTION_ORDER = ("interrupt", "save-checkpoint", "hook-toggle", "fallback-mode")


# -- dispatch ---------------------------------------------------------------------------------------------------
def _bounded(extra):
    """`extra` as the ack may carry it: only id / result / dup / retry_after_s, a result inside MAX_RESULT_BYTES."""
    out = {}
    for key in ("id", "result", "dup", "retry_after_s"):
        if key in extra:
            out[key] = extra[key]
    result = out.get("result")
    if result is not None and len(json.dumps(result, separators=(",", ":")).encode("utf-8")) > MAX_RESULT_BYTES:
        del out["result"]
    return out


def _run_command(root, action, params, device_id, started):
    """(ok, detail, extra, audit_params, dup) -- every refusal path included."""
    if not isinstance(action, str) or action not in _ACTIONS:
        return False, "not-implemented", {}, {}, False
    if not controls_enabled(root):
        return False, "controls-off", {}, {}, False
    try:
        rid, fields = _validate(action, params)
    except _Refusal as r:
        return False, r.detail, _bounded(r.extra), {}, False
    audit_params = _ACTIONS[action]["audit"](fields)
    try:
        if rid is not None:
            with _LOCK:
                hit = _RIDS.get(root, {}).get(rid)
            if hit is not None:
                ok, detail, extra = hit
                return ok, detail, dict(extra, dup=True), audit_params, True
        _charge(root, action)
        ctx = _Ctx(device_id, started + CONTROL_DEADLINE_S)
        try:
            ok, detail, extra = _ACTIONS[action]["handler"](root, fields, ctx)
        except _Timeout:
            return False, "timeout", {}, audit_params, False
        extra = _bounded(extra)
        if rid is not None:
            with _LOCK:
                store = _RIDS.setdefault(root, collections.OrderedDict())
                store[rid] = (ok, detail, extra)
                while len(store) > RID_MEMORY:
                    store.popitem(last=False)
        return ok, detail, extra, audit_params, False
    except _Refusal as r:
        return False, r.detail, _bounded(r.extra), audit_params, False


def dispatch(root, action, params, *, device_id="direct", seq=None, transport="direct"):
    """Run one phone command. Returns (ok, detail, extra); never raises. Every command is audited, refused or not."""
    started = time.monotonic()
    wall = time.time()
    try:
        ok, detail, extra, audit_params, dup = _run_command(root, action, params, device_id, started)
    except Exception as e:  # the type only: a message could hold what the phone sent
        sys.stderr.write("companion_ui_controls: internal error: %s\n" % type(e).__name__)
        ok, detail, extra, audit_params, dup = False, "internal-error", {}, {}, False
    name = action if isinstance(action, str) and ACTION_NAME_RE.fullmatch(action) and not secret_shaped(action) else None
    line = {"ts": _iso(wall), "device": device_id, "seq": seq if isinstance(seq, int) and not isinstance(seq, bool) else None,
            "action": name, "params": audit_params, "ok": ok, "detail": detail,
            "ms": int(round((time.monotonic() - started) * 1000)), "via": transport}
    if isinstance(extra.get("id"), str):
        line["id"] = extra["id"]
    if dup:
        line["dup"] = True
    _audit(root, line)
    return ok, detail, extra


# -- the `controls` key of /api/state ---------------------------------------------------------------------------
def _usable(action):
    if action == "interrupt":
        return _usable_tool("heimdall-phone-control")
    if action == "save-checkpoint":
        return _usable_tool("heimdall-checkpoint")
    if action == "hook-toggle":
        return _usable_tool("heimdall-hooks") and bool(toggleable_hooks())
    if action == "fallback-mode":
        return _usable_tool("heimdall-fallback")
    return False


def snapshot(root, hooks=None, fallback=None):
    """The additive `controls` key. `hooks` is the state's own hooks slice and `fallback` its fallback slice (the
    states the phone already sees, so one pass never disagrees with itself); both may be None."""
    states = {h["id"]: bool(h.get("enabled")) for h in (hooks or []) if isinstance(h, dict) and isinstance(h.get("id"), str)}
    ids = toggleable_hooks()
    mode = fallback.get("state") if isinstance(fallback, dict) else None
    return {
        "v": 1,
        "actions": [a for a in ACTION_ORDER if a in ALLOWED_ACTIONS and _usable(a)],
        "hooks_toggleable": ids,
        "hooks": [{"id": i, "enabled": states[i]} for i in ids if i in states],
        "fallback": {"mode": mode if mode in FALLBACK_STATES else None, "modes": list(FALLBACK_MODES),
                     "confirm": list(CONFIRM_MODES)},
        "enabled": controls_enabled(root),
        "last": last_control(root),
    }


# -- `hmd app controls on|off|status` (bin/heimdall-app delegates here) ------------------------------------------
def _ago(at):
    seconds = max(0, int(time.time() - at))
    if seconds < 90:
        return "%ds ago" % seconds
    if seconds < 5400:
        return "%dm ago" % (seconds // 60)
    return "%dh ago" % (seconds // 3600)


def status_line(root):
    state = "on" if controls_enabled(root) else "off"
    why = ""
    if not controls_enabled(root):
        why = " (HMD_UI_CONTROLS=0)" if os.environ.get(KILL_SWITCH_ENV) == "0" else " (hmd app controls on re-enables)"
    last = last_control(root)
    tail = "none yet" if last is None else "%s %s %s" % (last["action"], "ok" if last["ok"] else "refused", _ago(last["at"]))
    return "controls: %s%s; last: %s; %d audited" % (state, why, tail, audit_count(root))


def main(argv):
    parser = argparse.ArgumentParser(prog="companion_ui_controls.py", description="hmd app controls on|off|status")
    parser.add_argument("command", choices=("on", "off", "status", "status-line"))
    parser.add_argument("--repo", default=".")
    args = parser.parse_args(argv)
    root = os.path.realpath(os.path.expanduser(args.repo))
    if args.command in ("on", "off"):
        try:
            set_enabled(root, args.command == "on")
        except OSError as e:
            sys.stderr.write("hmd app controls %s: cannot write the switch (%s)\n" % (args.command, type(e).__name__))
            return 1
        if args.command == "on" and os.environ.get(KILL_SWITCH_ENV) == "0":
            sys.stderr.write("hmd app controls on: note -- HMD_UI_CONTROLS=0 is set in this shell and still switches "
                             "controls off for processes started with it\n")
    print(status_line(root))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)

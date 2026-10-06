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
    fallback-mode     {"mode": "off"|"auto"|"switch"|"coop", "confirm"?: true}
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
     "fallback":{"mode":..,"modes":["off","auto","switch","coop"],"confirm":["auto","switch","coop"]},"enabled":bool,
     "last":{"action","ok","at"}|null}
`hooks_toggleable` / `hooks` are the hooks whose sidecar entry says `remote_toggle: true` and `locked: false`;
`last` is the newest line of the audit log, params left out. `fallback.modes` is every state bin/heimdall-fallback's `set`
accepts (test/heimdall-controls.test.sh reads its VALID_STATES and fails on any drift); `fallback.confirm` is each of them
but `off`.

SECURITY MODEL.
  * One allowlist, fail closed: an action not in ALLOWED_ACTIONS is `not-implemented` and audited. A hook is toggleable
    only when hooks/hooks.metadata.json says `remote_toggle: true` AND `locked: false` -- a hand-set flag, false for every
    new hook; a locked gate can never be switched off from here even if someone hand-edits the sidecar.
  * Reduce-direction first: `interrupt` ends work, `hook-toggle` only reaches advisory hooks, `fallback-mode` `off` is the
    safe state and needs no confirm. Every other state bin/heimdall-fallback accepts can route work off Claude -- `auto`
    and `switch` both reach the main agent (owner directive 2026-09-11), `coop` routes only the subagent roles on the
    laptop's allowlist and never the main agent -- so each is refused unless the command carries `confirm: true`. `coop`
    moves the state word and nothing else: its allowlist (`heimdall-fallback coop add|remove`) is edited at the laptop
    alone, the phone never reads, grows or shrinks it, and an empty allowlist means coop routes nothing.
  * No shell, argv lists only, every id matched against a fixed pattern before any path or argv is built. A phone-supplied
    string is never written to disk, logged or echoed: the audit line carries only whitelisted, pattern-checked fields
    (never `rid`, never text), and a field that is secret-shaped is dropped.
  * Kill switch: env HMD_UI_CONTROLS=0, or the file <repo>/.heimdall/app/controls-disabled (`hmd app controls off`):
    every action returns `controls-off` -- except `launch-stop` (KILL_SWITCH_EXEMPT), which only ends work the phone
    started, so the phone can always say stop. Neither can be flipped by any action in this module.
  * Rate limits (token buckets, per repo, in memory): all controls 10/min burst 5; interrupt 3/min; hook-toggle 6/min;
    fallback-mode 3/min; save-checkpoint is not refused but COALESCED (a second save within 5 s of a good one is ok).
  * Every command -- ok, refused, unknown -- appends one line to <repo>/.heimdall/ui/controls-audit.jsonl (0600, dir 0700,
    O_APPEND + fsync, rotated at 1 MiB to `.1`). A write failure disables the log for the rest of the process with ONE
    stderr notice and never blocks a command.

CLASSES AND THE EXPAND GATE (hmdapp docs/HANDOFF-TO-HEIMDALL-cursor-parity.md CP1 + CP2). Every action is registered
(register_action, import time, trusted code only -- the ONE way a name joins ALLOWED_ACTIONS) with a class tag: `read`
(shows something), `safe-write` (adds data, or only reduces what is running: interrupt, save-checkpoint, launch-stop),
`risky-write` (changes how this laptop behaves: hook-toggle, fallback-mode) or `expand` (gives the phone authority it
did not have: launch-session, pr-merge). An `expand` command is refused `not-allowed` unless, in this order: the
laptop's switch for it is on (`hmd app remote-launch on` / `remote-merge on`, flipped at a terminal by a person --
bin/lib/companion_remote_switches.py; nothing in THIS file can write either switch), its params are well formed, and
the repo it names -- by allowlist id, never by label or path; the session's own repo for a merge -- is on the allowlist
(`hmd app launch-allow`), still resolves to the path it was added with and, for the merge switch, was added with
--merge. `launch-session` and `pr-merge` are RESERVED expand names (RESERVED_EXPAND): their class and switch cannot be
re-declared, and they are gated even before a handler is registered for them (answered `not-implemented` once the
switch is on). Every expand attempt, refused ones included, and every launch-stop is recorded TWICE: one
controls-audit.jsonl line and one `remote-action` line in relay-events.jsonl (same ts; `ref` is the action id). The
audit params are filtered here whatever a handler's own rule returns: repo, branch, model, mode, number, method, id,
enabled, confirm only, each pattern-checked -- never a prompt, a rid or a path. An expand command that cannot be
audited is refused `internal-error`, not run unaudited. EXPAND_RATES carries the per-session limits the registrations
use (launch 1 a minute; merge 1 per 30 s and 5 an hour).
STATE (additive, beside `controls`): remote_actions {v, launch_enabled, merge_enabled, recent:[{at, action, device,
repo_label, ok, detail}] -- the last 20, newest first, read back from the audit log} and launch {v, enabled[, repos:
[{id, label}]]} -- ids and labels only, never a path.

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
import contextlib
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
import tempfile
import threading
import time
import types
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))
BIN_DIR = os.path.normpath(os.path.join(HERE, ".."))
PLUGIN_DIR = os.path.normpath(os.path.join(HERE, "..", ".."))

CONTROL_DEADLINE_S = 5.0          # a synchronous handler's whole budget; past it the command is `timeout`
DEADLINE_ENV = "HMD_UI_CONTROL_DEADLINE_S"   # operator knob for a slow disk / a big repo: clamped to [1, 8] (the relay's ack
                                             # window is 8 s and the phone waits 10), CONTROL_DEADLINE_S when unset or junk
MAX_COMMAND_BYTES = 1024          # the whole command plaintext
MAX_RESULT_BYTES = 1024           # an ack's `result`, serialized
RID_MEMORY = 64                   # rid -> ack pairs kept per repo
STOP_TTL_S = 120.0                # a stop request older than this is never honoured
CHECKPOINT_COALESCE_S = 5.0       # a save within this of a good one is `coalesced`
AUDIT_MAX_BYTES = 1024 * 1024
KILL_SWITCH_ENV = "HMD_UI_CONTROLS"
EVENT_LOG_ENV = "HMD_RELAY_EVENT_LOG"          # the relay client's own event log override ("" = off)
EVENT_LOG_MAX_BYTES = 4 * 1024 * 1024         # its rotation size: a second writer must not outgrow it
RECENT_REMOTE = 20                            # rows in state.remote_actions.recent
RECENT_SCAN_BYTES = 256 * 1024                # how much of an audit generation is read back for them

CLASS_READ, CLASS_SAFE_WRITE, CLASS_RISKY_WRITE, CLASS_EXPAND = "read", "safe-write", "risky-write", "expand"
CLASSES = (CLASS_READ, CLASS_SAFE_WRITE, CLASS_RISKY_WRITE, CLASS_EXPAND)
EXPAND_SWITCHES = ("launch", "merge", "dashboards")   # the laptop switches (companion_remote_switches.SWITCHES)
GATE_SWITCHES = ("asks",)    # the laptop switches that gate a NON-expand action (policy gate_switch); their writer is the same one
# What register_action's `policy` may carry: the per-action rules a sibling module's action needs of this dispatcher and nothing
# else does. cap: the phone must have listed it (caps-missing). rid_re: a rid is REQUIRED and must be exactly this shape (it is
# then also handed to the handler as fields["rid"]). replay_detail: the detail a replayed rid's ok ack carries instead of the first
# one's. global_rate: False = exempt from the all-controls bucket (the action's own `rate` still applies). off_detail: the refusal
# when its switch is off (default not-allowed). open_switch: the switch is the whole gate, there is no repo allowlist (the action
# only ever acts on the session's own repo). timeline_ops: only these `op`s are also recorded in relay-events.jsonl. gate_switch: a
# GATE_SWITCHES laptop switch that must be on for an action that is not expand (a read action behind its own consent); off = its
# off_detail, answered before the params are read, the rid memory or any bucket is touched.
POLICY_KEYS = frozenset(("cap", "rid_re", "replay_detail", "global_rate", "off_detail", "open_switch", "timeline_ops", "gate_switch"))
RESERVED_EXPAND = {"launch-session": "launch", "pr-merge": "merge"}   # fixed by CP2: class expand, this switch, always
KILL_SWITCH_EXEMPT = frozenset(("launch-stop",))   # reduce-direction: ends only what the phone started
EXPAND_RATES = {"launch-session": ((1, 1 / 60.0),),
                "pr-merge": ((1, 1 / 30.0), (5, 5 / 3600.0))}   # (burst, per second): launch 1/min; merge 1/30 s and 5/h
HOOKS_METADATA_ENV = "HMD_HOOKS_METADATA"   # the same override bin/lib/hook-enabled.sh honours

AUDIT_REL = os.path.join(".heimdall", "ui", "controls-audit.jsonl")
KILL_SWITCH_REL = os.path.join(".heimdall", "app", "controls-disabled")
STOP_REQUEST_REL = os.path.join(".heimdall", "ui", "stop-request.json")
STOP_CONSUMED_REL = os.path.join(".heimdall", "ui", "stop-request.consumed")
CHECKPOINT_LOCK_REL = os.path.join(".heimdall", "ui", "controls-checkpoint.lock")
CHECKPOINT_FILE_REL = os.path.join(".planning", "CHECKPOINT.md")

FALLBACK_MODES = ("off", "auto", "switch", "coop")   # every state bin/heimdall-fallback's `set` accepts (its VALID_STATES; test-pinned)
CONFIRM_MODES = tuple(m for m in FALLBACK_MODES if m != "off")   # `off` routes nothing; every other state needs confirm:true

RID_RE = re.compile(r"[A-Za-z0-9_-]{1,32}")
HOOK_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
ACTION_NAME_RE = re.compile(r"[A-Za-z0-9_-]{1,40}")
STOP_ID_RE = re.compile(r"s-[0-9a-f]{8}")
REPO_ID_RE = re.compile(r"r-[0-9a-f]{4}")         # an allowlist id (companion_remote_switches.repo_id)
TILE_ID_RE = re.compile(r"t-[0-9a-f]{8}")         # a dashboard tile id (bin/lib/companion_dashboards.py)
AUDIT_OPS = frozenset(("create", "refine", "set-refresh", "refresh", "remove", "confirm", "decline", "expire", "run-failed",
                       "idle-pause", "alert-set", "alert-clear", "alert-fired", "alert-refused"))             # the dashboards ops an audit line may name, requests and what the laptop did
NAME_RE = re.compile(r"[a-z][a-z0-9-]{0,39}")      # a registered action name: kebab-case
DETAIL_RE = re.compile(r"[a-z0-9-]{1,40}")
DEVICE_RE = re.compile(r"[0-9a-f]{8}|direct|unknown")
_BRANCH_RE = re.compile(r"[A-Za-z0-9._][A-Za-z0-9._/-]{0,99}")

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


def _switches():
    """bin/lib/companion_remote_switches.py -- the laptop's expand switches and the repo allowlist -- or None when it
    cannot load: every expand command is then refused, and the state says both switches are off."""
    return _sibling("companion_remote_switches")


def _switch_on(name):
    sw = _switches()
    return sw is not None and sw.switch_enabled(name)


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
    # A temp file of its own per call (mkstemp: unique, O_EXCL, 0600): two stop requests handled on two threads of one
    # process (a double click, the laptop and a phone) must not share one temp name, or one rename pulls the file out
    # from under the other.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".tmp.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8"))
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


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


# The ONLY params an audit line may carry, and the shape each must have. Applied to every action's own audit rule, so a
# handler (or a later ask) that returns more -- a prompt, a path, a rid -- cannot widen what the log holds.
_AUDIT_FIELDS = {
    "id": lambda v: isinstance(v, str) and HOOK_ID_RE.fullmatch(v) is not None,
    "enabled": lambda v: isinstance(v, bool),
    "confirm": lambda v: isinstance(v, bool),
    "mode": lambda v: v in FALLBACK_MODES or v in ("plan", "default"),
    "repo": lambda v: isinstance(v, str) and REPO_ID_RE.fullmatch(v) is not None,
    "branch": lambda v: isinstance(v, str) and _BRANCH_RE.fullmatch(v) is not None and ".." not in v and "//" not in v,
    "model": lambda v: v in ("sonnet", "opus", "haiku"),
    "method": lambda v: v in ("squash", "merge", "rebase"),
    "number": lambda v: isinstance(v, int) and not isinstance(v, bool) and 0 < v < 10 ** 9,
    "op": lambda v: v in AUDIT_OPS,
    "tile_id": lambda v: isinstance(v, str) and TILE_ID_RE.fullmatch(v) is not None,
}


def _clean_audit(params):
    return {k: v for k, v in params.items() if k in _AUDIT_FIELDS and _AUDIT_FIELDS[k](v) and not secret_shaped(v)}


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
    rid_re = spec["policy"].get("rid_re")
    if ("rid" in params or rid_re is not None) and not (isinstance(rid, str) and (rid_re or RID_RE).fullmatch(rid)):
        raise _Refusal("bad-params")
    body = {k: v for k, v in params.items() if k != "rid"}
    keys = set(body)
    if not set(spec["required"]) <= keys or not keys <= set(spec["required"]) | set(spec["optional"]):
        raise _Refusal("bad-params")
    fields = spec["fields"](body)
    return rid, (dict(fields, rid=rid) if rid_re is not None else fields)


# -- rate limits ------------------------------------------------------------------------------------------------
class _Bucket:
    """A token bucket: `capacity` tokens (the burst), refilled at `per_s` tokens a second."""

    def __init__(self, capacity, per_s):
        self.capacity = float(capacity)
        self.per_s = per_s
        self.tokens = float(capacity)
        self.at = time.monotonic()

    def _refill(self, now):
        # `now` can be a hair BEFORE `at`: _charge reads the clock, then builds a bucket that stamps a later one. A one-token
        # bucket (an expand action's) would then start a sliver short of a whole token and refuse its very first command.
        self.tokens = min(self.capacity, self.tokens + max(0.0, now - self.at) * self.per_s)
        self.at = max(self.at, now)

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
    names = [("*",) + _GLOBAL_RATE] if _ACTIONS[action]["policy"].get("global_rate", True) else []
    for i, (cap, per) in enumerate(_ACTIONS[action]["rate"]):
        names.append(("%s#%d" % (action, i), cap, per))
    with _LOCK:
        buckets = [_BUCKETS.setdefault((root, n), _Bucket(cap, per)) for n, cap, per in names]
        wait = max([b.wait(now) for b in buckets] or [0.0])
        if wait > 0:
            raise _Refusal("rate-limited", {"retry_after_s": max(1, int(math.ceil(wait)))})
        for b in buckets:
            b.take()


# -- handlers: (root, fields, ctx) -> (ok, detail, extra) --------------------------------------------------------
class _Ctx:
    def __init__(self, device_id, deadline, repo=None, caps=None):
        self.caps = caps   # the capability set the phone listed (None = unknown): a handler that needs a second cap checks it
        self.device_id = device_id
        self.deadline = deadline
        self.repo = repo   # an expand handler's allowlist entry {id, label, path, merge}: hmd's own path, never the phone's


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


def fallback_mode(root):
    """The repo's fallback state (off|auto|switch|coop) as bin/heimdall-fallback's load_config reads it from
    <repo>/.heimdall/fallback.json: a missing, unreadable or unknown value (the retired `on` included) is `off`, the
    fail-closed default. A file read, not `heimdall-fallback status` -- that runs the whole preflight, a loopback probe
    and two database reads, which is no way to answer a phone inside a 5 s bound. Only this one closed-set word is ever
    taken from the file (it is on hmd-ui's never-forward list for everything else it holds)."""
    data = _read_json(os.path.join(root, ".heimdall", "fallback.json"))
    state = data.get("state") if isinstance(data, dict) else None
    return state if state in FALLBACK_MODES else "off"


def _do_fallback_mode(root, fields, ctx):
    mode = fields["mode"]
    if mode in CONFIRM_MODES and fields["confirm"] is not True:
        return False, "confirm-required", {}
    if not _usable_tool("heimdall-fallback"):
        return False, "unavailable", {}
    was = fallback_mode(root)
    if was == mode:
        return True, "unchanged", {"result": {"mode": mode}}
    rc, out = _run_argv([_bin("heimdall-fallback"), "--repo", root, "set", mode], ctx.deadline)
    if rc != 0 or "state set to '%s'" % mode not in out:
        return False, "write-failed", {}
    return True, None, {"result": {"mode": mode, "was": was}}


_ACTIONS = {}
ALLOWED_ACTIONS = frozenset()
ACTION_ORDER = []


def _rate_pairs(rate):
    """`rate` -- None, one (burst, per_second) pair, or a sequence of pairs -- as a tuple of validated pairs."""
    if rate is None:
        return ()
    pairs = (rate,) if isinstance(rate[0], (int, float)) else tuple(rate)
    for pair in pairs:
        if len(pair) != 2 or not all(isinstance(x, (int, float)) and x > 0 for x in pair):
            raise ValueError("a rate is (burst, per_second), both positive")
    return tuple((float(cap), float(per)) for cap, per in pairs)


def register_action(name, *, cls, handler, required=(), optional=(), fields=_no_fields, audit=None, rate=None, switch=None,
                    repo_field=None, usable=None, policy=None):
    """Put `name` on the allowlist: the one way an action gets in (module import time; trusted code only). `handler(root,
    fields, ctx)` returns (ok, detail, extra). `cls` is read | safe-write | risky-write | expand. An expand action names its
    laptop `switch` (launch | merge) and, when the phone picks the repo, `repo_field` -- the param holding an allowlist id
    (otherwise the gate checks the session's own repo); the handler then finds the allowlist's own entry in ctx.repo -- its
    path was re-checked at the gate, so a handler that acts later (a worktree add, a merge) re-checks it with
    companion_remote_switches.usable(ctx.repo) first, and never touches any path the phone sent. A name
    in RESERVED_EXPAND must be that class and switch; a name in KILL_SWITCH_EXEMPT must be safe-write. `rate` is a (burst,
    per_second) pair or a sequence of them (see EXPAND_RATES); `usable(root)` says whether the action is offered now."""
    global ALLOWED_ACTIONS
    if not (isinstance(name, str) and NAME_RE.fullmatch(name)) or name in _ACTIONS:
        raise ValueError("an action name is kebab-case and registered once")
    if cls not in CLASSES:
        raise ValueError("unknown class")
    if not callable(handler):
        raise ValueError("a handler is callable")
    if (cls == CLASS_EXPAND) != (switch is not None) or (switch is not None and switch not in EXPAND_SWITCHES):
        raise ValueError("an expand action names exactly one expand switch; no other class names one")
    if repo_field is not None and cls != CLASS_EXPAND:
        raise ValueError("repo_field belongs to expand actions")
    if name in RESERVED_EXPAND and (cls != CLASS_EXPAND or switch != RESERVED_EXPAND[name]):
        raise ValueError("a reserved name keeps its class and switch")
    if name in KILL_SWITCH_EXEMPT and cls != CLASS_SAFE_WRITE:
        raise ValueError("only a safe-write action can be exempt from the kill switch")
    policy = dict(policy or {})
    if not set(policy) <= POLICY_KEYS or (policy.get("open_switch") and cls != CLASS_EXPAND):
        raise ValueError("unknown policy key, or open_switch on an action that is not expand")
    if policy.get("gate_switch") is not None and (policy["gate_switch"] not in GATE_SWITCHES or cls == CLASS_EXPAND):
        raise ValueError("gate_switch names a GATE_SWITCHES switch and belongs to an action that is not expand")
    _ACTIONS[name] = {"cls": cls, "switch": switch, "repo_field": repo_field, "required": tuple(required),
                      "optional": tuple(optional), "fields": fields, "audit": audit or (lambda f: {}), "handler": handler,
                      "rate": _rate_pairs(rate), "usable": usable, "policy": policy,
                      "timeline": cls == CLASS_EXPAND or name in KILL_SWITCH_EXEMPT}
    ACTION_ORDER.append(name)
    ALLOWED_ACTIONS = frozenset(_ACTIONS)


register_action("interrupt", cls=CLASS_SAFE_WRITE, handler=_do_interrupt, rate=(3, 3 / 60.0),
                usable=lambda root: _usable_tool("heimdall-phone-control"))
register_action("save-checkpoint", cls=CLASS_SAFE_WRITE, handler=_do_save_checkpoint,
                usable=lambda root: _usable_tool("heimdall-checkpoint"))
register_action("hook-toggle", cls=CLASS_RISKY_WRITE, handler=_do_hook_toggle, required=("id", "enabled"),
                fields=_hook_toggle_fields, audit=_audit_hook_toggle, rate=(6, 6 / 60.0),
                usable=lambda root: _usable_tool("heimdall-hooks") and bool(toggleable_hooks()))
register_action("fallback-mode", cls=CLASS_RISKY_WRITE, handler=_do_fallback_mode, required=("mode",), optional=("confirm",),
                fields=_fallback_fields, audit=_audit_fallback, rate=(3, 3 / 60.0),
                usable=lambda root: _usable_tool("heimdall-fallback"))


# -- actions a sibling module owns ------------------------------------------------------------------------------
# A module named here registers its own action(s) through register_actions(kit) when this one imports (trusted code only,
# like every register_action call); one that cannot load, or raises, simply leaves its action off the allowlist.
ACTION_MODULES = ("companion_dashboards", "companion_quick_ask")


def _load_action_modules():
    kit = types.SimpleNamespace(register_action=register_action, CLASS_EXPAND=CLASS_EXPAND, CLASS_READ=CLASS_READ, Refusal=_Refusal, audit=_audit,
                                iso=_iso, controls_enabled=controls_enabled)
    for name in ACTION_MODULES:
        hook = getattr(_sibling(name), "register_actions", None)
        if callable(hook):
            try:
                hook(kit)
            except Exception as e:
                sys.stderr.write("companion_ui_controls: %s did not register its actions (%s)\n" % (name, type(e).__name__))


_load_action_modules()


# -- dispatch ---------------------------------------------------------------------------------------------------
def _deadline_s():
    try:
        value = float(os.environ.get(DEADLINE_ENV, ""))
    except ValueError:
        return CONTROL_DEADLINE_S
    return min(8.0, max(1.0, value)) if math.isfinite(value) else CONTROL_DEADLINE_S


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


def _authorize(root, spec, fields):
    """(entry, repo, detail) for an expand command: the allowlist entry it may act on (its path re-checked now), the allowlist
    id it named (None when what it named is not shaped like one) and `not-allowed` unless the laptop's switch is on and the
    repo is on the allowlist BY ID -- never by label or path --, still resolves to the path it was added with and, for the
    merge switch, was added with --merge. `fields` is None when the params were malformed: only the switch is checked."""
    sw = _switches()
    if sw is None or not sw.switch_enabled(spec["switch"]):
        return None, None, spec["policy"].get("off_detail", "not-allowed")
    if spec["policy"].get("open_switch"):    # acts on the session's own repo only: the switch is the whole gate
        real = os.path.realpath(root)
        return {"id": sw.repo_id(real), "label": None, "path": real, "merge": False}, sw.repo_id(real), None
    if fields is None:
        return None, None, None
    if spec["repo_field"] is not None:
        wanted = fields.get(spec["repo_field"])
        repo = wanted if isinstance(wanted, str) and REPO_ID_RE.fullmatch(wanted) else None
        entry = sw.authorize(spec["switch"], repo=wanted) if isinstance(wanted, str) else None
    else:
        repo = sw.repo_id(os.path.realpath(root))
        entry = sw.authorize(spec["switch"], root=root)
    return entry, repo, (None if entry is not None else "not-allowed")


def _audit_ready(root):
    """True when this command's audit line can be written: an expand command is never run unrecorded."""
    if root in _AUDIT_OFF:
        return False
    try:
        _ensure_dir(os.path.join(root, ".heimdall", "ui"))
        os.close(os.open(os.path.join(root, AUDIT_REL), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600))
    except OSError:
        return False
    return True


def _timeline_names():
    """The actions that also go to relay-events.jsonl: every expand action (reserved names included) and launch-stop."""
    return set(RESERVED_EXPAND) | set(KILL_SWITCH_EXEMPT) | {n for n, s in _ACTIONS.items() if s["timeline"]}


def _timeline_row_ok(name, op):
    """An action whose policy lists `timeline_ops` is on the timeline (and in remote_actions.recent) for those ops only."""
    spec = _ACTIONS.get(name)
    ops = spec["policy"].get("timeline_ops") if spec is not None else None
    return ops is None or op in ops


def _run_command(root, action, params, device_id, started, caps=None):
    """(ok, detail, extra, audit_params, dup, repo) -- every refusal path included. `repo` is the allowlist id an expand
    command named (the session's own repo's, for a merge), else None."""
    spec = _ACTIONS.get(action) if isinstance(action, str) else None
    gate = RESERVED_EXPAND.get(action) if isinstance(action, str) else None
    if spec is None and gate is None:
        return False, "not-implemented", {}, {}, False, None
    cap = spec["policy"].get("cap") if spec is not None else None
    if cap is not None and (caps is None or cap not in caps):   # an action behind a capability: the phone must have listed it
        return False, "caps-missing", {}, {}, False, None
    if action not in KILL_SWITCH_EXEMPT and not controls_enabled(root):
        return False, "controls-off", {}, {}, False, None
    if spec is None:   # a reserved expand name nothing has registered a handler for: gated all the same
        detail = "not-allowed" if not _switch_on(gate) else "not-implemented"
        return False, detail, {}, {}, False, None
    gated = spec["policy"].get("gate_switch")
    if gated is not None and not _switch_on(gated):   # a laptop switch in front of a non-expand action: refused before anything is read
        return False, spec["policy"].get("off_detail", "not-allowed"), {}, {}, False, None
    try:
        rid, fields = _validate(action, params)
        refusal = None
    except _Refusal as r:
        rid, fields, refusal = None, None, r
    audit_params = _clean_audit(spec["audit"](fields)) if fields is not None else {}
    repo = None
    try:
        entry = None
        if spec["cls"] == CLASS_EXPAND:
            entry, repo, detail = _authorize(root, spec, fields)
            if detail is not None:
                return False, detail, {}, audit_params, False, repo
        if refusal is not None:
            raise refusal
        if rid is not None:
            with _LOCK:
                hit = _RIDS.get(root, {}).get(rid)
            if hit is not None:
                ok, detail, extra = hit
                replay = spec["policy"].get("replay_detail")
                return ok, (replay if ok and replay else detail), dict(extra, dup=True), audit_params, True, repo
        if spec["cls"] == CLASS_EXPAND and not _audit_ready(root):
            return False, "internal-error", {}, audit_params, False, repo
        _charge(root, action)
        ctx = _Ctx(device_id, started + _deadline_s(), entry, caps)
        try:
            ok, detail, extra = spec["handler"](root, fields, ctx)
        except _Timeout:
            return False, "timeout", {}, audit_params, False, repo
        extra = _bounded(extra)
        if rid is not None:
            with _LOCK:
                store = _RIDS.setdefault(root, collections.OrderedDict())
                store[rid] = (ok, detail, extra)
                while len(store) > RID_MEMORY:
                    store.popitem(last=False)
        return ok, detail, extra, audit_params, False, repo
    except _Refusal as r:
        return False, r.detail, _bounded(r.extra), audit_params, False, repo


_TIMELINE_WARNED = set()


def _timeline_path(root):
    """The relay client's own event log: HMD_RELAY_EVENT_LOG ("" = off, no file), else <repo>/.heimdall/app/relay-events.jsonl."""
    override = os.environ.get(EVENT_LOG_ENV)
    if override == "":
        return None
    return override or os.path.join(root, ".heimdall", "app", "relay-events.jsonl")


def _timeline(root, line, repo):
    """The second record of an expand attempt (and of a launch-stop): one `remote-action` line in relay-events.jsonl, the log
    the relay client already keeps, so it is the single timeline. Same ts as the audit line; `ref` is the audit line's `id`.
    Never a param, a path or free text. Best effort: a failure costs the line and ONE stderr notice, never the command."""
    path = _timeline_path(root)
    if path is None:
        return
    ref, detail = line.get("id"), line.get("detail")
    record = {"ts": line["ts"], "event": "remote-action", "action": line["action"], "device": line["device"], "repo": repo,
              "ok": line["ok"], "detail": detail if isinstance(detail, str) and DETAIL_RE.fullmatch(detail) else None,
              "ref": ref if isinstance(ref, str) and HOOK_ID_RE.fullmatch(ref) else None}
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        try:
            oversized = os.stat(path).st_size >= EVENT_LOG_MAX_BYTES
        except OSError:
            oversized = False
        if oversized:
            os.replace(path, path + ".1")
        data = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as e:
        if path not in _TIMELINE_WARNED:
            _TIMELINE_WARNED.add(path)
            sys.stderr.write("companion_ui_controls: relay event log not written (%s)\n" % type(e).__name__)


def dispatch(root, action, params, *, device_id="direct", seq=None, transport="direct", caps=None):
    """Run one phone command. Returns (ok, detail, extra); never raises. Every command is audited, refused or not. `caps` is the
    capability set the phone listed (None = unknown, as on the direct route): an action behind a capability is `caps-missing`."""
    started = time.monotonic()
    wall = time.time()
    try:
        ok, detail, extra, audit_params, dup, repo = _run_command(root, action, params, device_id, started, caps)
    except Exception as e:  # the type only: a message could hold what the phone sent
        sys.stderr.write("companion_ui_controls: internal error: %s\n" % type(e).__name__)
        ok, detail, extra, audit_params, dup, repo = False, "internal-error", {}, {}, False, None
    name = action if isinstance(action, str) and ACTION_NAME_RE.fullmatch(action) and not secret_shaped(action) else None
    line = {"ts": _iso(wall), "device": device_id, "seq": seq if isinstance(seq, int) and not isinstance(seq, bool) else None,
            "action": name, "params": audit_params, "ok": ok, "detail": detail,
            "ms": int(round((time.monotonic() - started) * 1000)), "via": transport}
    if isinstance(extra.get("id"), str):
        line["id"] = extra["id"]
    if dup:
        line["dup"] = True
    for key in ("op", "tile_id"):    # an action that names its op or tile in its audit rule has them beside `action`, not inside params
        if key in audit_params:
            line[key] = audit_params.pop(key)
    _audit(root, line)
    if name is not None and name in _timeline_names() and _timeline_row_ok(name, line.get("op")):
        _timeline(root, line, repo)
    return ok, detail, extra


# -- the `controls` key of /api/state ---------------------------------------------------------------------------
def _usable(root, action):
    spec = _ACTIONS[action]
    if spec["cls"] == CLASS_EXPAND:
        sw = _switches()
        if sw is None or not sw.available(spec["switch"], root=root):
            return False
    return True if spec["usable"] is None else bool(spec["usable"](root))


def snapshot(root, hooks=None):
    """The additive `controls` key. `hooks` is the state's own hooks slice (the enabled flags the phone already sees, so
    one pass never disagrees with itself); it may be None."""
    states = {h["id"]: bool(h.get("enabled")) for h in (hooks or []) if isinstance(h, dict) and isinstance(h.get("id"), str)}
    ids = toggleable_hooks()
    return {
        "v": 1,
        "actions": [a for a in ACTION_ORDER if _usable(root, a)],
        "hooks_toggleable": ids,
        "hooks": [{"id": i, "enabled": states[i]} for i in ids if i in states],
        "fallback": {"mode": fallback_mode(root), "modes": list(FALLBACK_MODES), "confirm": list(CONFIRM_MODES)},
        "enabled": controls_enabled(root),
        "last": last_control(root),
    }


_RECENT_CACHE = {}


def _ts_epoch(ts):
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) + float("0" + ts[19:-1])
    except (ValueError, TypeError, IndexError):
        return None


def _remote_rows(path, names):
    """The remote-action rows (oldest first) in the tail of one audit generation, stat-cached."""
    try:
        st = os.stat(path)
    except OSError:
        return []
    stamp = (st.st_mtime_ns, st.st_size, st.st_ino, tuple(sorted(names)))
    hit = _RECENT_CACHE.get(path)
    if hit is not None and hit[0] == stamp:
        return hit[1]
    try:
        with open(path, "rb") as f:
            f.seek(max(0, st.st_size - RECENT_SCAN_BYTES))
            chunk = f.read(RECENT_SCAN_BYTES)
    except OSError:
        return []
    rows = []
    for raw in chunk.splitlines():
        try:
            obj = json.loads(raw.decode("utf-8"))
            at, action, ok = _ts_epoch(obj["ts"]), obj["action"], obj["ok"]
        except (ValueError, KeyError, TypeError, UnicodeDecodeError):
            continue
        if at is None or not isinstance(action, str) or action not in names or not isinstance(ok, bool) \
                or not _timeline_row_ok(action, obj.get("op")):
            continue
        params = obj.get("params")
        repo = params.get("repo") if isinstance(params, dict) else None
        device, detail = obj.get("device"), obj.get("detail")
        rows.append({"at": round(at, 3), "action": action,
                     "device": device if isinstance(device, str) and DEVICE_RE.fullmatch(device) else "unknown",
                     "repo": repo if isinstance(repo, str) and REPO_ID_RE.fullmatch(repo) else None, "ok": ok,
                     "detail": detail if isinstance(detail, str) and DETAIL_RE.fullmatch(detail) else None})
    _RECENT_CACHE[path] = (stamp, rows)
    return rows


def remote_actions(root):
    """The additive `remote_actions` key of /api/state: both laptop switches as they are now and the last RECENT_REMOTE expand
    attempts (and launch-stops), newest first, read back from the audit log so the two cannot disagree. A row carries the
    repo's LABEL from the allowlist (None when it is not on it) -- never a path, a param or any text."""
    sw = _switches()
    names = _timeline_names()
    base = os.path.join(root, AUDIT_REL)
    rows = _remote_rows(base + ".1", names) + _remote_rows(base, names)
    recent = [{"at": r["at"], "action": r["action"], "device": r["device"],
               "repo_label": sw.label_of(r["repo"]) if sw is not None and r["repo"] is not None else None,
               "ok": r["ok"], "detail": r["detail"]} for r in reversed(rows[-RECENT_REMOTE:])]
    return {"v": 1, "launch_enabled": _switch_on("launch"), "merge_enabled": _switch_on("merge"), "recent": recent}


def launch_state(root):
    """The additive `launch` key: {"v":1,"enabled":false} while the launch switch is off, else the repos the phone may name --
    allowlist id and label only; an entry whose path no longer resolves as it was added is left out, and no path is ever sent."""
    sw = _switches()
    if sw is None or not sw.switch_enabled("launch"):
        return {"v": 1, "enabled": False}
    return {"v": 1, "enabled": True, "repos": sw.public_repos()}


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

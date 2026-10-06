#!/usr/bin/env python3
"""companion_push_store.py -- the phone's push-notification registrations, on disk.

hmdapp's docs/HANDOFF-TO-HEIMDALL-push-notifications.md (PN2) and its spec,
docs/superpowers/specs/2026-10-03-push-notifications.md section 5, define what the phone sends:
a sealed `register_push` carrying its Expo push token, `unregister_push`, and `app_state`. This
module is where bin/heimdall-relay-client keeps what those commands say, and where whatever sends
the notifications reads it back. One file, <repo>/.heimdall/app/push.json (directory 0700, file
0600, atomic temp-file-and-rename writes, one exclusive flock over push.json.lock around every
read-modify-write):

    {"v":1,"tokens":[{"token":..,"platform":..,"registered_at":..,"ref":..,"label":..,"events":[..]}],
     "app_state":"foreground"|"background"|"unknown","app_state_at":"<iso>"|null}

PUBLIC INTERFACE (the notification sender is written against exactly this):

    load(repo_root) -> {"tokens": [{"token": str, "platform": str|None, "registered_at": iso}],
                        "app_state": "foreground"|"background"|"unknown", "app_state_at": iso|None}
        A missing, unreadable, oversized, unparsable or wrongly-shaped file is the default
        {"tokens": [], "app_state": "unknown", "app_state_at": None}; a damaged entry is dropped, never
        an exception. Takes no lock (the file is only ever replaced whole), and hands back copies.
        A token's entry also carries `ref`, `label` and `events` when the phone supplied them (the
        sender may use them or ignore them); `registered_at` and `app_state_at` are ISO-8601 UTC
        with a trailing Z, to the second.
    register(repo_root, token, platform=None, *, ref=None, label=None, events=None) -> the stored entry
        An upsert: the same token, or the same `ref`, replaces the entry it matches (a phone has one
        registration, and a rotated token supersedes the old one); the entry becomes the newest.
        At most MAX_TOKENS are kept, the oldest dropped first.
    unregister(repo_root, token=None, *, ref=None) -> bool
        Drops the entry with this token, or with this `ref` (exactly one is named); True when
        something was removed. Nothing is written otherwise.
    set_app_state(repo_root, state)
        state: "foreground" ("active", the phone's own word, is accepted for it), "background", or
        "unknown" (forget what was reported). Stamps app_state_at, so a report that stops arriving ages.
    remove_tokens(repo_root, tokens) -> int
        Drops every entry whose token is listed (what the sender does once Expo says a token is dead);
        returns how many went. Unknown tokens are ignored.

The module owns every rule and its machine-readable refusal, as companion_ui_inbox and
companion_ui_decisions do: a refusal is a PushStoreError whose `code` is the spec's own `detail`
string -- bad-token | bad-platform | bad-ref | bad-label | bad-events | bad-state | bad-params. A
write that could not happen (unwritable directory, a lock held past LOCK_TIMEOUT_S, full disk) is
the OSError it was, never swallowed.

THE TOKEN IS A SECRET (spec 2.3, R3: anyone holding it can put a notification on that phone). It
lives only in push.json (0600) and in the memory of whoever called in. This module prints nothing,
logs nothing, and no error message it raises repeats anything it was given -- they name the rule.

EXTENSION KINDS. `events` accepts the five kinds of EVENT_KINDS and, beyond them, exactly the kinds bin/lib/companion_push.py has
registered (register_kind): `extension_kinds()` -> {kind: capability}, supplied through `bind_extension_kinds(provider)` (the relay
client binds companion_push.registered_kinds at start; unbound, there are none). The relay client advertises each of those capabilities in its
state frames, so a phone asks for a kind only when it is listed, and a kind that is not registered here is `bad-events` for that
registration alone (the rest of the phone's notifications keep working).

Stdlib only; loadable by path like the other bin/lib modules, no side effects at import.
"""
import copy
import errno
import fcntl
import json
import os
import re
import secrets
import time
import unicodedata

APP_REL = os.path.join(".heimdall", "app")
PUSH_REL = os.path.join(APP_REL, "push.json")
MAX_TOKENS = 5                 # newest wins: a sixth registration evicts the oldest
READ_CAP_BYTES = 65536         # five entries are ~1 KiB; a file bigger than this is not ours
LOCK_TIMEOUT_S = 3.0           # the relay client's stream thread must never wedge behind a stuck writer
LOCK_POLL_S = 0.005
PLATFORMS = ("ios", "android")
EVENT_KINDS = ("approval", "digest", "error", "finished", "gate_red", "question")  # spec 5.2's five kinds, and `digest` (watch handoff H2/H4: a phone asks for it only when hmd lists push-digest-v1)
LABEL_MAX_UNITS = 24           # UTF-16 code units, after trim (spec 5.2)

# Spec 5.2: the Expo token shape. fullmatch, so a trailing newline can never ride along.
_TOKEN_RE = re.compile(r"(?:ExponentPushToken|ExpoPushToken)\[[A-Za-z0-9_-]{8,64}\]")
_REF_RE = re.compile(r"[0-9a-f]{16}")
_ISO_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
_APP_STATES = {"foreground": "foreground", "active": "foreground", "background": "background", "unknown": "unknown"}


class PushStoreError(ValueError):
    """A registration, a ref or a state was refused. `code` is the spec's machine-readable `detail`
    string; the message names the rule and never echoes what the caller sent."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


# -- validation (each returns the normalised value or raises PushStoreError) ------------------------
def _valid_token(value):
    return isinstance(value, str) and _TOKEN_RE.fullmatch(value) is not None


def _valid_ref(value):
    return isinstance(value, str) and _REF_RE.fullmatch(value) is not None


def _label(value):
    """The label trimmed, when it is 1..LABEL_MAX_UNITS UTF-16 units with no control character, lone
    surrogate, `/` or `\\` (spec 5.2: it is shown in a notification title, one line)."""
    refusal = PushStoreError("bad-label", "label must be 1..%d UTF-16 units, one line, no / or \\" % LABEL_MAX_UNITS)
    if not isinstance(value, str):
        raise refusal
    text = value.strip()
    units = len(text.encode("utf-16-le", "surrogatepass")) // 2
    if not 1 <= units <= LABEL_MAX_UNITS or "/" in text or "\\" in text:
        raise refusal
    if any(unicodedata.category(c) == "Cc" or "\ud800" <= c <= "\udfff" for c in text):
        raise refusal
    return text


_EXTENSION = {"provider": None}


def bind_extension_kinds(provider):
    """Name where the registered push kinds come from: `provider()` -> {kind: capability token}, bin/lib/companion_push.py's
    registered_kinds (the relay client binds it at start). This module imports nothing to find out -- it stays dependency-free."""
    _EXTENSION["provider"] = provider if callable(provider) else None


def extension_kinds():
    """{kind: capability token} of the push kinds registered beyond EVENT_KINDS (companion_push.register_kind: the registration
    interface in its docstring). Empty while nothing is bound or the provider fails -- so an extension kind is then `bad-events`,
    and no capability is advertised for it: a kind is accepted exactly while hmd can send it."""
    provider = _EXTENSION["provider"]
    if provider is None:
        return {}
    try:
        kinds = provider()
    except Exception:
        return {}
    return {k: v for k, v in kinds.items() if isinstance(k, str) and isinstance(v, str)} if isinstance(kinds, dict) else {}


def _events(value):
    """The event list, sorted, when it is a non-empty set of the accepted kinds (the five, plus the registered extension kinds)
    without a duplicate."""
    allowed = EVENT_KINDS + tuple(sorted(extension_kinds()))
    if (not isinstance(value, (list, tuple)) or not value or len(value) > len(allowed)
            or not all(isinstance(kind, str) for kind in value)
            or len(set(value)) != len(value) or not set(value) <= set(allowed)):
        raise PushStoreError("bad-events", "events must be a non-empty set of %s" % ", ".join(allowed))
    return sorted(value)


def _now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# -- paths and permissions ----------------------------------------------------------------------------
def _path(repo_root):
    return os.path.join(repo_root, PUSH_REL)


def _ensure_dir(repo_root):
    """Create <repo>/.heimdall/app and force 0700 on it, on every touch, so a directory that predates
    this (or a hostile umask) self-heals."""
    directory = os.path.join(repo_root, APP_REL)
    os.makedirs(directory, exist_ok=True)
    os.chmod(directory, 0o700)


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        return False
    return True


class _Flock:
    """An exclusive flock on push.json.lock -- a dedicated file, never the data file, whose replacement
    by rename would otherwise orphan the lock. Acquired without blocking and retried until
    LOCK_TIMEOUT_S, so a writer that was stopped holding it costs the caller an OSError, not a hang."""

    def __init__(self, repo_root):
        self.lock_path = _path(repo_root) + ".lock"
        self._fd = None

    def __enter__(self):
        fd = os.open(self.lock_path, os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.chmod(self.lock_path, 0o600)
            deadline = time.monotonic() + LOCK_TIMEOUT_S
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise OSError(errno.ETIMEDOUT, "push.json is locked by another writer")
                    time.sleep(LOCK_POLL_S)
        except BaseException:
            os.close(fd)
            raise
        self._fd = fd
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        finally:
            os.close(self._fd)
        return False


# -- reading -------------------------------------------------------------------------------------------
def _read_json(path):
    """The JSON object in `path`, or None -- a missing, oversized, unparsable or non-object file is
    simply no record, never an exception."""
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


def _clean_entry(raw):
    """One stored entry as load() promises it, or None when it is damaged. The optional ref / label /
    events survive only when they still satisfy their rules."""
    if not isinstance(raw, dict) or not _valid_token(raw.get("token")):
        return None
    registered_at = raw.get("registered_at")
    if not isinstance(registered_at, str) or _ISO_RE.fullmatch(registered_at) is None:
        return None
    platform = raw.get("platform")
    entry = {"token": raw["token"], "platform": platform if platform in PLATFORMS else None,
             "registered_at": registered_at}
    if _valid_ref(raw.get("ref")):
        entry["ref"] = raw["ref"]
    for key, check in (("label", _label), ("events", _events)):
        try:
            if key in raw:
                entry[key] = check(raw[key])
        except PushStoreError:
            continue  # a damaged optional field is dropped on its own; the token it rode with is still good
    return entry


def _clean(raw):
    """The state load() returns for whatever was parsed from disk."""
    state = {"tokens": [], "app_state": "unknown", "app_state_at": None}
    if not isinstance(raw, dict):
        return state
    entries = []
    for item in raw["tokens"] if isinstance(raw.get("tokens"), list) else []:
        entry = _clean_entry(item)
        if entry is not None:
            entries = [e for e in entries if e["token"] != entry["token"]] + [entry]
    state["tokens"] = entries[-MAX_TOKENS:]
    if raw.get("app_state") in ("foreground", "background"):
        at = raw.get("app_state_at")
        state["app_state"] = raw["app_state"]
        state["app_state_at"] = at if isinstance(at, str) and _ISO_RE.fullmatch(at) else None
    return state


def load(repo_root):
    return _clean(_read_json(_path(repo_root)))


# -- writing -------------------------------------------------------------------------------------------
def _write(repo_root, state):
    """Replace push.json with `state`: a fully written, fsynced 0600 temp file renamed into place, so a
    reader sees the old file or the new one and never half of either."""
    path = _path(repo_root)
    tmp = "%s.tmp-%d-%s" % (path, os.getpid(), secrets.token_hex(4))
    body = json.dumps(dict(state, v=1), sort_keys=True, separators=(",", ":"))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        _unlink(tmp)
        raise


def _update(repo_root, change):
    """Run change(state) -> (changed, result) over the current state under the exclusive lock; the
    file is rewritten only when `changed`. Returns `result`."""
    _ensure_dir(repo_root)
    with _Flock(repo_root):
        state = load(repo_root)
        changed, result = change(state)
        if changed:
            _write(repo_root, state)
    return result


def register(repo_root, token, platform=None, *, ref=None, label=None, events=None):
    if not _valid_token(token):
        raise PushStoreError("bad-token", "not an Expo push token")
    if platform is not None and platform not in PLATFORMS:
        raise PushStoreError("bad-platform", "platform must be ios or android")
    if ref is not None and not _valid_ref(ref):
        raise PushStoreError("bad-ref", "ref must be 16 lowercase hex digits")
    entry = {"token": token, "platform": platform, "registered_at": _now_iso()}
    if ref is not None:
        entry["ref"] = ref
    if label is not None:
        entry["label"] = _label(label)
    if events is not None:
        entry["events"] = _events(events)

    def change(state):
        kept = [e for e in state["tokens"] if e["token"] != token and (ref is None or e.get("ref") != ref)]
        state["tokens"] = (kept + [entry])[-MAX_TOKENS:]
        return True, copy.deepcopy(entry)

    return _update(repo_root, change)


def _drop(repo_root, doomed):
    """Remove the entries `doomed(entry)` selects; how many went. Nothing on disk is touched when the
    file does not exist or nothing matches."""
    if not os.path.exists(_path(repo_root)):
        return 0

    def change(state):
        kept = [e for e in state["tokens"] if not doomed(e)]
        removed = len(state["tokens"]) - len(kept)
        state["tokens"] = kept
        return removed > 0, removed

    return _update(repo_root, change)


def unregister(repo_root, token=None, *, ref=None):
    if (token is None) == (ref is None):
        raise PushStoreError("bad-params", "name exactly one of token or ref")
    if ref is not None:
        if not _valid_ref(ref):
            raise PushStoreError("bad-ref", "ref must be 16 lowercase hex digits")
        return _drop(repo_root, lambda e: e.get("ref") == ref) > 0
    return _drop(repo_root, lambda e: e["token"] == token) > 0


def remove_tokens(repo_root, tokens):
    if isinstance(tokens, str):
        tokens = (tokens,)
    doomed = {t for t in tokens if isinstance(t, str)}
    return _drop(repo_root, lambda e: e["token"] in doomed) if doomed else 0


def set_app_state(repo_root, state):
    value = _APP_STATES.get(state) if isinstance(state, str) else None
    if value is None:
        raise PushStoreError("bad-state", "state must be foreground, background or unknown")

    def change(current):
        current["app_state"] = value
        current["app_state_at"] = None if value == "unknown" else _now_iso()
        return True, None

    _update(repo_root, change)

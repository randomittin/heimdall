#!/usr/bin/env python3
"""companion_push_store.py -- the phone's push-notification registrations, on disk.

hmdapp's docs/HANDOFF-TO-HEIMDALL-push-notifications.md (PN2) and its spec,
docs/superpowers/specs/2026-10-03-push-notifications.md section 5, define what the phone sends:
a sealed `register_push` carrying its Expo push token, `unregister_push`, and `app_state`. This
module is where bin/heimdall-relay-client keeps what those commands say, and where whatever sends
the notifications reads it back. One file, <repo>/.heimdall/app/push.json (directory 0700, file
0600, atomic temp-file-and-rename writes, one exclusive flock over push.json.lock around every
read-modify-write):

    {"v":2,"tokens":[{"token":..,"platform":..,"registered_at":..,"ref":..,"label":..,"events":[..]}],
     "app_state":"foreground"|"background"|"unknown","app_state_at":"<iso>"|null,"sig":"<64 hex>"}

WHAT IS BELIEVED. push.json decides where a notification goes (the token), what it may be about (events, label) and whether it
goes at all (app_state: a phone that says it is looking silences the push), and it sits in <repo>/.heimdall, a tree a repository
controls: a checked-in file, a planted link, another process. So a record is believed only when ALL of this holds, and anything
else is the default state -- no devices, nothing sent:
  * hmd_private_state (bin/lib/hmd_private_state.py) reached it: the way down from the repo root is walked one component at a time
    without following a link and through directories this user owns, none of them writable by anyone else, and the file itself is a
    regular file of this user's with no group or other permission bit (a checkout leaves 0644). Every read, write and lock of the
    store goes through it, so a link at .heimdall/app, push.json or the lock is refused, never written through or chmod'ed through;
  * its "sig" verifies: HMAC-SHA256 over the whole record (version, every token entry with its ref, label and events, app_state)
    and the repo's real path, under the per-machine key bin/lib/companion_ui_inbox.py already seals answers with
    ($HEIMDALL_HOME/app/inbox-answer.key, 0600 in a 0700 directory outside every repo; made here on first use), with a domain prefix
    of its own, so the seal is valid for this store only, for this repo only and for this machine only. Only register(),
    unregister(), remove_tokens() and set_app_state() write a record, and bin/heimdall-relay-client calls them only for a frame that
    opened under the paired phone's session key.
MIGRATION. A push.json written before sealing ("v":1, no "sig") is ignored: never read as devices, never deleted. The phone
registers again at its next connect -- the relay client forgets an earlier session's registrations at every pairing anyway -- and
the first registration replaces the file. Until then nothing is pushed.

PUBLIC INTERFACE (the notification sender is written against exactly this):

    load(repo_root) -> {"tokens": [{"token": str, "platform": str|None, "registered_at": iso}],
                        "app_state": "foreground"|"background"|"unknown", "app_state_at": iso|None}
        A missing, unreadable, oversized, unparsable, wrongly-shaped, unsealed or otherwise untrusted file (WHAT IS BELIEVED, above) is the default
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
import contextlib
import copy
import errno
import fcntl
import hashlib
import hmac
import json
import os
import re
import time
import unicodedata
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.abspath(__file__))
APP_REL = os.path.join(".heimdall", "app")
PUSH_NAME = "push.json"
LOCK_NAME = "push.json.lock"
PUSH_REL = os.path.join(APP_REL, PUSH_NAME)
RECORD_VERSION = 2             # 1 was the unsealed file: ignored, see MIGRATION
SEAL_KEY_DIR = "app"           # under $HEIMDALL_HOME: the per-machine key bin/lib/companion_ui_inbox.py seals answers with
SEAL_KEY_NAME = "inbox-answer.key"
SEAL_KEY_BYTES = 32            # a key shorter than this is no key
SEAL_KEY_MAX_BYTES = 4096      # never read more of the key file than this
SEAL_DOMAIN = b"hmd-push-store-v1\n"   # prefixes what is sealed, so this seal is never valid as any other HMAC under the key
PRIVATE = 0o077                # mode bits a file of ours must not carry: only 0600 is believed
NOT_SHARED = 0o022             # mode bits a directory holding one must not carry: nobody else may write into it
MAX_TOKENS = 5                 # newest wins: a sixth registration evicts the oldest
READ_CAP_BYTES = 65536         # five entries are ~1 KiB; a file bigger than this is not ours
LOCK_TIMEOUT_S = 3.0           # the relay client's stream thread must never wedge behind a stuck writer
LOCK_POLL_S = 0.005
PLATFORMS = ("ios", "android")
EVENT_KINDS = ("approval", "error", "finished", "gate_red", "question")  # spec 5.2: the five kinds a phone may ask for
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


# -- the private-state helper, the machine key and the seal -----------------------------------------------
_STATE = []   # [the hmd_private_state module] once it loaded


def _state():
    """bin/lib/hmd_private_state.py, loaded by path beside this file (it is not a package): the ONLY way this module touches a
    file under a repo or under $HEIMDALL_HOME -- the pattern of bin/lib/companion_ui_inbox.py (_state). It walks down from the root
    without following a link, makes files 0600 in 0700 directories (on every touch, so one that predates this self-heals) and opens
    nothing through a link. There is no fallback to plain open()/chmod()/rename(): a helper that cannot be loaded is an OSError
    here, so a write is refused and a read finds no record."""
    if not _STATE:
        try:
            spec = spec_from_file_location("hmd_private_state", os.path.join(HERE, "hmd_private_state.py"))
            mod = module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception as exc:
            raise OSError("hmd_private_state is not available: %s" % (exc,))
        _STATE.append(mod)
    return _STATE[0]


def _heimdall_home():
    """$HEIMDALL_HOME, else ~/.heimdall (bin/lib/companion_remote_switches.py's resolution); None with neither it nor HOME -- there
    is no /tmp fallback, a directory other users can write. Read on every call: a key is never cached past a change of home."""
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit
    home = os.environ.get("HOME")
    return os.path.join(home, ".heimdall") if home else None


def _read_seal_key(home):
    """The key under `home` when hmd_private_state accepts it -- a regular file this user owns that nobody else can read, reached
    through no link, in a directory nobody else can write -- and it is long enough, else None."""
    try:
        key = _state().read(home, SEAL_KEY_DIR, SEAL_KEY_NAME, SEAL_KEY_MAX_BYTES, forbidden=PRIVATE, dir_forbidden=NOT_SHARED)
    except OSError:
        return None
    return key if key is not None and len(key) >= SEAL_KEY_BYTES else None


def _seal_key(make):
    """The per-machine key a record is sealed with (companion_ui_inbox._seal_key: the same file). With `make`, made when absent --
    written whole to a private temp file and linked into place (create_once), so a racing second maker gets EEXIST and reads the
    winner's key, never a half-written one. A reader passes False and creates nothing: no key means nothing was ever sealed.
    None when it can be neither read nor made."""
    home = _heimdall_home()
    if home is None:
        return None
    key = _read_seal_key(home)
    if key is not None or not make:
        return key
    try:
        os.makedirs(home, exist_ok=True)   # the root is the operator's own choice (a link AT it is fine); everything below it is walked link-free
        with contextlib.suppress(FileExistsError):   # EEXIST: another maker linked its key first, and that one is the key
            _state().create_once(home, SEAL_KEY_DIR, SEAL_KEY_NAME, os.urandom(SEAL_KEY_BYTES))
    except OSError:
        return None
    return _read_seal_key(home)


def _seal(key, repo_root, record):
    """The seal of a record: HMAC-SHA256 (hex) over the repo's real path and the record (everything but "sig"), as one JSON array so
    no choice of path can shift a byte of the record into it."""
    body = json.dumps([os.path.realpath(repo_root), record], sort_keys=True, separators=(",", ":")).encode("ascii")
    return hmac.new(key, SEAL_DOMAIN + body, hashlib.sha256).hexdigest()


class _Flock:
    """An exclusive flock on push.json.lock -- a dedicated file, never the data file, whose replacement
    by rename would otherwise orphan the lock -- opened by hmd_private_state (no link, a file of ours, 0600).
    Acquired without blocking and retried until LOCK_TIMEOUT_S, so a writer that was stopped holding it
    costs the caller an OSError, not a hang."""

    def __init__(self, repo_root):
        self.repo_root = repo_root
        self._fd = None

    def __enter__(self):
        fd = _state().open_lockfile(self.repo_root, APP_REL, LOCK_NAME)
        try:
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
_SIG_RE = re.compile(r"[0-9a-f]{64}")


def _read_record(repo_root):
    """The record push.json holds when it is ours to believe (see WHAT IS BELIEVED), else None -- a missing, unreachable,
    foreign, linked, group- or world-accessible, oversized, unparsable, non-object, unsealed or wrongly sealed file is simply no
    record, never an exception. The file is read through hmd_private_state; the seal is checked before anything in the record is
    looked at."""
    try:
        raw = _state().read(repo_root, APP_REL, PUSH_NAME, READ_CAP_BYTES, forbidden=PRIVATE, dir_forbidden=NOT_SHARED)
        key = _seal_key(False) if raw is not None else None
    except OSError:
        return None
    if raw is None or key is None:
        return None
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, RecursionError):
        return None
    if not isinstance(obj, dict):
        return None
    sig = obj.pop("sig", None)
    if obj.get("v") != RECORD_VERSION or not isinstance(sig, str) or _SIG_RE.fullmatch(sig) is None:
        return None
    return obj if hmac.compare_digest(sig, _seal(key, repo_root, obj)) else None


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
    return _clean(_read_record(repo_root))


# -- writing -------------------------------------------------------------------------------------------
def _write(repo_root, state):
    """Replace push.json with `state`, sealed: hmd_private_state writes a fully written, fsynced 0600 temp file and renames it
    into place, so a reader sees the old file or the new one and never half of either, and a link at push.json is replaced, never
    written through. OSError when anything on the way is a link or not ours, or when there is no machine key to seal with."""
    key = _seal_key(True)
    if key is None:
        raise OSError(errno.EACCES, "push registrations cannot be sealed: no per-machine key under $HEIMDALL_HOME")
    record = dict(state, v=RECORD_VERSION)
    body = json.dumps(dict(record, sig=_seal(key, repo_root, record)), sort_keys=True, separators=(",", ":"))
    _state().write(repo_root, APP_REL, PUSH_NAME, body.encode("ascii"))


def _update(repo_root, change):
    """Run change(state) -> (changed, result) over the current state under the exclusive lock; the
    file is rewritten only when `changed`. Returns `result`."""
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
    if _state().stat_file(repo_root, APP_REL, PUSH_NAME) is None:
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

#!/usr/bin/env python3
"""hmd_session_login.py -- the login a relay client attaches to its relay session with, kept OUTSIDE the repo (stdlib only).

WHY. A paired phone is bound to one relay session, and the bearer token that session was minted with (plus the hmd private key its
session key derives from) lived only in the memory of the client that paired it: a stopped, crashed or killed client could neither be
resumed nor, later, revoke that session, so stopping the laptop's client meant unpairing the phone. Once a phone is bound the client
now stores this login here. A new client resumes the same relay session for HMD_SESSION_RESUME_H hours (default 24) after the old one
was last alive, and `hmd app disconnect` revokes through it when no client is left to ask.

WHERE. Never in the repo (a repository controls everything under it), never in argv, an environment variable or a log:
  * the SECRET half -- {"token", "priv"} -- goes to the macOS Keychain when `security` is there (one generic-password item per
    repo realpath + session: service "heimdall-relay-session", account "<sha256(realpath)[:16]>-<session id>"), written through
    `security -i` so it travels on its stdin and not in its argv, and read back to be sure it was kept; else (no Keychain, or it
    refused) it is held in the metadata file itself;
  * the METADATA half is a 0600 JSON file, $HEIMDALL_HOME/app/sessions/<account>.json (HEIMDALL_HOME, else ~/.heimdall), written
    through bin/lib/hmd_private_state.py: session id, relay, device id and label, when it bound, when its client was last alive (and its
    pid), and the two sequence numbers a resumed client must never go back on -- hmd_seq is the HIGH-WATER of the seq blocks handed out
    (reserve_block: a client seals only inside a block it was handed, and the block is durable before it is used, so a seq -- and with it
    a nonce, which is only sender tag || seq -- is never sealed twice under one key, whatever kills the client), last_device_seq the
    phone's newest accepted command seq (the replay guard). Fields like these only ever grow (_merge), and every read-modify-write runs
    under one exclusive store lock (_locked).
HMD_SESSION_LOGIN_STORE=file|keychain|auto (default auto: the Keychain on macOS when `security` is on PATH) picks the secret's home.

LIMIT. A login whose client was last alive more than HMD_SESSION_RESUME_H hours ago (default 24; 0 = never resume) is discarded on
the next look and the phone pairs again. It is not revoked: only an explicit disconnect, a revoke from the phone or a failed login is.
CONFIRMED OR KEPT. A login is removed by a revoke here only once the relay confirmed it (the session ended, or is no longer there); an
unreachable or unwilling relay, a secret that cannot be read and a login file that cannot be read all keep it and fail loudly. A revoke
marks the login `revoking` FIRST (under the store lock, durably): from then on no resume claims it, so a disconnect racing a resume ends
revoked and never resumed -- if the resume won the race the revoke ends its session at the relay, if the revoke did, the resume finds
nothing to claim. A login a revoke removed cannot be brought back: every writer re-reads it under the same lock.

CLI (the shell tools; nothing secret is ever printed):
    python3 hmd_session_login.py list   --repo DIR                                   the logins of that repo, as JSON, secret-free
    python3 hmd_session_login.py revoke --repo DIR (--device-id ID | --all)           revoke those sessions AT THE RELAY with the stored
        login and discard what was confirmed. exit 0 every one confirmed (revoked, or the relay says it is already gone), 1 one or more
        could NOT be confirmed (the reason on stderr; an unreachable relay keeps the login so the command can be run again; a login
        the relay refuses is discarded and reported), 3 no stored login selected (the caller falls back to what it did before).
        --forget-local (never implied by anything else): a login whose revoke the relay does not confirm is not kept but dropped here --
        the session id, the warning that its phone can keep connecting until the session expires and when (absolute UTC: session_exp, the
        bind plus the relay's 30-day device-token lifetime) go to stderr, the Keychain item and the file are deleted under the store lock,
        and a session_login_forgotten event (the repo's relay-events.jsonl) and a line ($HEIMDALL_HOME/logs/app.log) record session, device,
        expiry and that the relay was NOT told. Exit 4: nothing failed, but at least one login was dropped without the relay's word.
"""
import argparse
import contextlib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from importlib.util import module_from_spec, spec_from_file_location

REL = "app/sessions"
SERVICE = "heimdall-relay-session"
DEFAULT_RESUME_H = 24.0
SECRET_LIMIT = 16384
_SID_RE = re.compile(r"[A-Za-z0-9_-]{1,100}\Z")
STORE_LOCK = "sessions.lock"
SEQ_BLOCK = 1000  # seqs handed out at a time unless the caller says otherwise
_MONOTONIC = ("hmd_seq", "last_device_seq", "last_alive")  # fields that only ever grow: a writer holding a stale copy cannot take one back
DEVICE_TOKEN_TTL_S = 30 * 24 * 3600  # relay/src/pairing.ts DEVICE_TOKEN_TTL_S: a bound session lives until its device token's exp, the bind plus this
APP_LOG_REL, APP_LOG = "logs", "app.log"  # $HEIMDALL_HOME/logs/app.log: the human-readable line of what was done to a stored login
EVENT_LOG_MAX_BYTES = 4 * 1024 * 1024  # where the relay client's event log rotates (bin/heimdall-relay-client)
FORGOTTEN = 4  # exit of `revoke --forget-local`: nothing failed, but a login was dropped here with the relay NOT told


def _sibling(name):
    spec = spec_from_file_location(name, os.path.join(os.path.dirname(os.path.realpath(__file__)), name + ".py"))
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PRIVATE = _sibling("hmd_private_state")


def home():
    """$HEIMDALL_HOME, else ~/.heimdall; None with neither it nor HOME (there is no /tmp fallback). Read on every call."""
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit
    user_home = os.environ.get("HOME")
    return os.path.join(user_home, ".heimdall") if user_home else None


def resume_limit_s():
    """HMD_SESSION_RESUME_H hours in seconds; an unusable value is the default, 0 means no resume at all."""
    try:
        hours = float(os.environ.get("HMD_SESSION_RESUME_H", DEFAULT_RESUME_H))
    except ValueError:
        return DEFAULT_RESUME_H * 3600
    return hours * 3600 if hours == hours and 0 <= hours < 24 * 3650 else DEFAULT_RESUME_H * 3600


def account(root, sid):
    """The name of one stored login: the repo's real path and the session, folded to a name that is safe anywhere."""
    if not isinstance(sid, str) or not _SID_RE.match(sid):
        raise OSError("not a session id this store can name")
    return "%s-%s" % (hashlib.sha256(os.path.realpath(root).encode("utf-8")).hexdigest()[:16], sid)


def _backend():
    want = (os.environ.get("HMD_SESSION_LOGIN_STORE") or "auto").strip().lower()
    if want in ("file", "keychain"):
        return want
    return "keychain" if sys.platform == "darwin" and shutil.which("security") else "file"


# -- the Keychain: `security -i` takes its commands on stdin, so a secret is never in an argument list --------------------------------
def _security(args, stdin=None):
    done = subprocess.run(["security"] + args, input=stdin, capture_output=True, text=True, timeout=20)
    return done.returncode, done.stdout


def _kc_get(acct):
    rc, out = _security(["find-generic-password", "-a", acct, "-s", SERVICE, "-w"])
    return out.rstrip("\n") if rc == 0 and out.strip() else None


def _kc_put(acct, text):
    _security(["-i"], "add-generic-password -U -a %s -s %s -X %s\n" % (acct, SERVICE, text.encode("utf-8").hex()))
    if _kc_get(acct) != text:  # interactive mode answers 0 whatever a command did: only a read-back says it was kept
        raise OSError("the Keychain did not keep the login")


def _kc_del(acct):
    _security(["delete-generic-password", "-a", acct, "-s", SERVICE])


# -- the metadata file ----------------------------------------------------------------------------------------------------------------
def _read_meta(sid_account):
    base = home()
    if base is None:
        return None
    return PRIVATE.read_json(base, REL, sid_account + ".json", SECRET_LIMIT)


def _write_meta(sid_account, rec):
    base = home()
    if base is None:
        raise OSError("no HEIMDALL_HOME or HOME to keep a session login under")
    os.makedirs(base, mode=0o700, exist_ok=True)
    PRIVATE.write(base, REL, sid_account + ".json", json.dumps(rec, sort_keys=True, separators=(",", ":")).encode("utf-8"))


@contextlib.contextmanager
def _locked():
    """The store's one exclusive lock. Every read-modify-write of a login runs under it, so that two writers -- a client's refresh and
    its seq reservation, two clients, a client and a command-line revoke -- cannot interleave and lose one another's update. Held only
    for file reads and writes, never across the network."""
    base = home()
    if base is None:
        raise OSError("no HEIMDALL_HOME or HOME to keep a session login under")
    os.makedirs(base, mode=0o700, exist_ok=True)
    PRIVATE.ensure_dir(base, REL)
    with PRIVATE.lock(base, REL, STORE_LOCK):
        yield


def _merge(old, fields):
    """`old` with `fields` applied -- except that a monotonic field never goes down."""
    new = dict(old)
    for key, value in fields.items():
        prev = old.get(key)
        grows = key in _MONOTONIC and isinstance(prev, (int, float)) and isinstance(value, (int, float)) and not isinstance(value, bool)
        new[key] = max(prev, value) if grows else value
    return new


def save(root, relay, sid, secret, **fields):
    """Keep the login of session `sid` (secret = {"token", "priv"}; fields = the metadata). The secret first, the metadata last, so a
    record never names a secret that was not kept. Raises OSError when nothing could be written."""
    acct = account(root, sid)
    now = int(time.time())
    rec = dict(fields, v=1, repo=os.path.realpath(root), relay=relay, session_id=sid, created_at=now, last_alive=now)
    bound = fields.get("bound_at")  # the client never sees the device token, so its exp is kept from what the relay documents: the bind + 30 days
    rec["session_exp"] = int(bound if isinstance(bound, (int, float)) and not isinstance(bound, bool) else now) + DEVICE_TOKEN_TTL_S
    text = json.dumps(secret, sort_keys=True, separators=(",", ":"))
    if _backend() == "keychain":
        try:
            _kc_put(acct, text)
            rec["secret_in"] = "keychain"
        except (OSError, subprocess.SubprocessError):
            rec["secret_in"] = "file"
    else:
        rec["secret_in"] = "file"
    if rec["secret_in"] == "file":
        rec["secret"] = secret
    with _locked():
        old = _read_meta(acct)
        _write_meta(acct, _merge(old, rec) if old else rec)


def update(root, sid, **fields):
    """Change fields of a login that still exists. False when it is gone -- discarded, revoked or never kept -- and then NOTHING is
    written: an update must never bring back a login that was removed."""
    acct = account(root, sid)
    with _locked():
        rec = _read_meta(acct)
        if rec is None:
            return False
        _write_meta(acct, _merge(rec, fields))
    return True


def reserve_block(root, sid, n):
    """Hand the next `n` seqs of this session to the caller -- durably, BEFORE it seals anything in them (write-ahead). (lo, hi): every seq in
    [lo, hi) is the caller's alone and was never handed out before; None when the login is gone. OSError when it cannot be written, and
    the caller then seals nothing outside the block it already holds. A frame's nonce is only sender tag || seq, so a seq sealed twice
    under one key is a nonce reused: the block is the one thing standing between a killed client and that."""
    acct = account(root, sid)
    with _locked():
        rec = _read_meta(acct)
        if rec is None:
            return None
        lo = rec.get("hmd_seq")
        if not isinstance(lo, int) or isinstance(lo, bool) or lo < 0:
            raise OSError("the stored seq mark is not usable")
        _write_meta(acct, _merge(rec, {"hmd_seq": lo + n, "last_alive": int(time.time())}))
    return lo, lo + n


def discard(root, sid):
    """Remove a login, its Keychain item included -- under the store lock, so that no writer holding a stale copy can bring it back."""
    with _locked():
        _discard_unlocked(root, sid)


def _discard_unlocked(root, sid):
    acct = account(root, sid)
    rec = _read_meta(acct)
    if rec is not None and rec.get("secret_in") == "keychain":
        try:
            _kc_del(acct)
        except (OSError, subprocess.SubprocessError):
            sys.stderr.write("hmd_session_login: the Keychain item of a discarded login could not be removed\n")
    base = home()
    if base is not None:
        PRIVATE.remove(base, REL, acct + ".json")


def records(root):
    """Every stored login of this repo, newest first (the metadata, and the secret too when the file holds it)."""
    base = home()
    if base is None:
        return []
    prefix = account(root, "x")[: -len("x")]
    found = []
    for name in PRIVATE.names(base, REL):
        if name.startswith(prefix) and name.endswith(".json"):
            rec = _read_meta(name[: -len(".json")])
            if rec is not None and rec.get("repo") == os.path.realpath(root) and _SID_RE.match(str(rec.get("session_id"))):
                found.append(rec)
    return sorted(found, key=lambda r: r.get("last_alive") or 0, reverse=True)


def public(rec):
    return {k: v for k, v in rec.items() if k != "secret"}


def secret_of(root, rec):
    """The {"token", "priv"} of a login, or None when it cannot be had (the Keychain item is gone, the file lost it)."""
    if rec.get("secret_in") == "keychain":
        try:
            text = _kc_get(account(root, rec["session_id"]))
            secret = json.loads(text) if text else None
        except (OSError, ValueError, subprocess.SubprocessError):
            return None
    else:
        secret = rec.get("secret")
    ok = isinstance(secret, dict) and isinstance(secret.get("token"), str) and isinstance(secret.get("priv"), str)
    return secret if ok else None


def _same_relay(a, b):
    return isinstance(a, str) and isinstance(b, str) and a.rstrip("/") == b.rstrip("/")


def _held(root, pid):
    """True while another live relay client of this repo is serving that pid's session: two clients on one session would supersede each
    other for ever."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0 or pid == os.getpid():
        return False
    return _sibling("hmd_devices").client_alive(pid, os.path.realpath(root))


def load_resumable(root, relay, reserve=SEQ_BLOCK):
    """CLAIM the newest login of this repo, on this relay, that may be resumed -- its client last alive within HMD_SESSION_RESUME_H and no
    other client holding it -- under the store lock: its secret ({"token","priv"}) and the seq block [seq_lo, seq_hi) the new client owns
    come back with it, and the block is durable before this returns. It starts one whole block above the stored high-water: a block
    whose write a power cut lost may still have been used, so the next client skips one. None when there is none. A login past the limit,
    or whose secret is gone, is discarded here: the phone pairs again."""
    limit = resume_limit_s()
    with _locked():
        for rec in records(root):
            if not _same_relay(rec.get("relay"), relay):
                continue
            if rec.get("revoking"):  # a disconnect was asked for: it is revoked, never resumed -- kept only for that revoke to be repeated
                continue
            if time.time() - float(rec.get("last_alive") or 0) > limit:
                _discard_unlocked(root, rec["session_id"])
                continue
            if _held(root, rec.get("pid")):
                continue
            secret = secret_of(root, rec)
            if secret is None:  # a locked Keychain, a vanished item: no reason to lose the one thing a disconnect revokes with
                sys.stderr.write("session %s: its stored secret cannot be read, so it is not resumed (and not discarded)\n"
                                 % rec["session_id"][:8])
                continue
            mark = rec.get("hmd_seq")
            if not isinstance(mark, int) or isinstance(mark, bool) or mark < 0:
                continue
            lo = mark + reserve
            _write_meta(account(root, rec["session_id"]),
                        _merge(rec, {"hmd_seq": lo + reserve, "pid": os.getpid(), "last_alive": int(time.time())}))
            return dict(public(rec), seq_lo=lo, seq_hi=lo + reserve, **secret)
    return None


# -- revoking at the relay with a stored login --------------------------------------------------------------------------------------
def _revoke_at_relay(rec, token, timeout=15):
    """POST /session/:id/revoke with the stored bearer: "revoked", "gone" (the relay no longer has it: 404/410), "rejected" (it does not
    accept this login: 401/403) or "failed: why". No proxy -- the relay client dials the relay directly too."""
    url = "%s/session/%s/revoke" % (rec["relay"].rstrip("/"), urllib.parse.quote(rec["session_id"], safe=""))
    request = urllib.request.Request(url, data=b"", method="POST", headers={"Authorization": "Bearer " + token})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=timeout) as answer:
            return "revoked" if answer.status == 200 else "failed: HTTP %d" % answer.status
    except urllib.error.HTTPError as e:
        if e.code in (404, 410):
            return "gone"
        if e.code in (401, 403):
            return "rejected"
        return "failed: HTTP %d" % e.code
    except (urllib.error.URLError, OSError, ValueError) as e:
        return "failed: %s" % type(e).__name__


def session_exp(rec):
    """Epoch second the relay stops serving this session -- until then its phone can keep connecting: the stored `session_exp`, else the
    bind (the login's creation, for a record without one) plus the relay's fixed device-token lifetime."""
    exp = rec.get("session_exp")
    if isinstance(exp, (int, float)) and not isinstance(exp, bool):
        return int(exp)
    base = rec.get("bound_at") if isinstance(rec.get("bound_at"), (int, float)) and not isinstance(rec.get("bound_at"), bool) else rec.get("created_at")
    return int(base if isinstance(base, (int, float)) and not isinstance(base, bool) else 0) + DEVICE_TOKEN_TTL_S


def _iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def _clean(text, limit):
    return "".join(ch for ch in str(text) if not (ord(ch) < 0x20 or 0x7F <= ord(ch) <= 0x9F))[:limit]


def _remove_strict(root, rec):
    """Delete a login for good and be sure of it, under the store lock: the Keychain item (read back, never taken on trust), then the metadata
    file. None when both are gone, else what is still there -- and then the metadata stays, because it is what names the item."""
    acct = account(root, rec["session_id"])
    if rec.get("secret_in") == "keychain":
        try:
            _kc_del(acct)
            if _kc_get(acct) is not None:
                return "the Keychain item could not be removed"
        except (OSError, subprocess.SubprocessError) as e:
            return "the Keychain item could not be removed (%s)" % type(e).__name__
    base = home()
    if base is not None:
        PRIVATE.remove(base, REL, acct + ".json")
        if acct + ".json" in PRIVATE.names(base, REL):
            return "the login file could not be removed"
    return None


def _event_log_target(root):
    """(dir, rel, name) of the relay client's event log -- HMD_RELAY_EVENT_LOG: "" is off (None), a path is that file, else the repo's
    <repo>/.heimdall/app/relay-events.jsonl."""
    env = os.environ.get("HMD_RELAY_EVENT_LOG")
    if env == "":
        return None
    if env:
        return os.path.dirname(os.path.abspath(env)), "", os.path.basename(env)
    return os.path.realpath(root), ".heimdall/app", "relay-events.jsonl"


def _record_forgotten(root, rec, reason):
    """The log entry of a forget -- a `session_login_forgotten` event in the relay client's event log and a line in the app log -- written
    once the delete succeeded, so a log never claims what did not happen. The paths written; [] when no log took it."""
    now, exp = time.time(), session_exp(rec)
    meta = rec.get("device_meta") if isinstance(rec.get("device_meta"), dict) else {}
    label, why = _clean(meta.get("label") or "", 40), _clean(reason, 200)
    event = {"event": "session_login_forgotten", "ts": "%s.%03dZ" % (time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)), int(now * 1000) % 1000),
             "session_id": rec["session_id"], "device_id": rec.get("device_id"), "device_label": label, "relay": rec.get("relay"),
             "session_exp": exp, "session_exp_at": _iso(exp), "relay_told": False, "reason": why, "by": "hmd app disconnect --forget-local"}
    line = ("%s hmd app: session login forgotten locally (hmd app disconnect --forget-local): session %s, device %s (%s) -- the relay was NOT told "
            "(%s); the phone can keep connecting until %s\n" % (_iso(now), rec["session_id"], rec.get("device_id"), label, why, _iso(exp)))
    sinks = [(os.path.join(home() or "", APP_LOG_REL, APP_LOG), (home(), APP_LOG_REL, APP_LOG, line.encode("utf-8"), None))]
    target = _event_log_target(root)
    if target is not None:
        data = (json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        sinks.append((os.path.join(*target), target + (data, EVENT_LOG_MAX_BYTES)))
    wrote = []
    for shown, (base, rel, name, data, rotate) in sinks:
        try:
            if base is None:
                raise OSError("no HEIMDALL_HOME or HOME")
            PRIVATE.append(base, rel, name, data, rotate_at=rotate)
            wrote.append(shown)
        except OSError as e:
            sys.stderr.write("session %s: the forget could not be logged to %s (%s)\n" % (rec["session_id"], shown, e))
    return wrote


def forget_login(root, sid, reason):
    """--forget-local: drop the stored login of session `sid` although the relay did not confirm its revoke (`reason` says why). The relay
    session id, the warning that the phone can keep connecting until the session expires and when (absolute UTC, session_exp) go to stderr;
    the delete -- Keychain item and file, verified -- runs under the store lock; then the forget is logged (_record_forgotten). True only
    when the login is gone AND the log took the entry (a login already gone counts as done); False keeps what could not be removed."""
    try:
        with _locked():
            rec = _read_meta(account(root, sid))
            if rec is None:
                return True  # a concurrent revoke or discard has already ended it
            exp, meta = session_exp(rec), rec.get("device_meta") if isinstance(rec.get("device_meta"), dict) else {}
            risk = ("the phone can keep connecting to that session until it expires: %s (epoch %d)" % (_iso(exp), exp) if exp > time.time()
                    else "that session's lifetime ended at %s (epoch %d), so nothing is left open at the relay" % (_iso(exp), exp))
            sys.stderr.write("session %s: the relay revoke could NOT be confirmed (%s), so --forget-local drops the stored login anyway\n"
                             "  device %s (%s)\n  WARNING: the relay was NOT told -- %s\n"
                             % (sid, _clean(reason, 200), rec.get("device_id"), _clean(meta.get("label") or "", 40), risk))
            problem = _remove_strict(root, rec)
            if problem:
                sys.stderr.write("session %s: %s -- the login is KEPT, run this again\n" % (sid, problem))
                return False
    except OSError as e:
        sys.stderr.write("session %s: the login could not be forgotten (%s) -- it is kept, run this again\n" % (sid, e))
        return False
    device_id = rec.get("device_id")
    if isinstance(device_id, str):  # a phone whose client is gone goes with its login (push registrations, device record); a LIVE client's record stays: disconnect finds that client by it
        try:
            devices = _sibling("hmd_devices")
            record = next((r for r in devices.records(root) if r["id"] == device_id), None)
            if record is not None and not devices.client_alive(record["pid"], os.path.realpath(root)) and not devices.forget(root, device_id):
                sys.stderr.write("session %s: device %s: its push registrations could not be removed, so its record is kept -- run this again\n"
                                 % (sid, device_id))
        except (OSError, ValueError, ImportError, AttributeError, KeyError) as e:
            sys.stderr.write("session %s: device %s could not be forgotten (%s) -- run this again\n" % (sid, device_id, e))
    wrote = _record_forgotten(root, rec, reason)
    if not wrote:
        sys.stderr.write("session %s: the login is deleted but the forget could NOT be logged anywhere -- note it down yourself: relay NOT told, "
                         "session expires %s\n" % (sid, _iso(exp)))
        return False
    print("session %s: login forgotten locally (relay NOT told); logged to %s" % (sid, ", ".join(wrote)))
    return True


def status(root, sid):
    """"resumable" while the login is stored, "revoking" once a disconnect asked for it to be revoked (it is then kept only for that revoke to
    be repeated, and no resume claims it), "gone" when it is not stored -- or cannot be read."""
    rec = _read_meta(account(root, sid))
    if rec is None:
        return "gone"
    return "revoking" if rec.get("revoking") else "resumable"


def unreadable(root):
    """The files in the store that carry THIS repo's name but cannot be read or trusted (not 0600, not ours, not JSON): a login the revoke
    cannot see, so one it must not walk past -- it may be the very login that was asked for."""
    base = home()
    if base is None:
        return []
    prefix = account(root, "x")[: -len("x")]
    return [n for n in PRIVATE.names(base, REL)
            if n.startswith(prefix) and n.endswith(".json") and _read_meta(n[: -len(".json")]) is None]


def revoke_logins(root, device_id=None, forget_local=False):
    """(confirmed, failed, selected) of _revoke_logins; a login dropped by --forget-local counts as done (it is not a failure)."""
    confirmed, forgotten, failed, selected = _revoke_logins(root, device_id, forget_local)
    return confirmed + forgotten, failed, selected


def _revoke_logins(root, device_id=None, forget_local=False):
    """Revoke the stored sessions of this repo (all, or the one device's) at the relay. (confirmed, forgotten, failed, selected); `forgotten` is
    only ever above 0 with `forget_local`: a login whose revoke is not confirmed is then dropped here (forget_login). ONLY a revoke the
    relay confirmed -- done, or the session no longer there -- removes a login. Everything else keeps it and says so, loudly: a relay that
    cannot be reached or will not take it (5xx, 401, 403), a secret that cannot be read (a locked or emptied Keychain), and a login file
    that cannot be read at all, which is never walked past. The stored login is the only thing that can end that session from here."""
    chosen = [r for r in records(root) if device_id is None or r.get("device_id") == device_id]
    confirmed = forgotten = failed = 0
    blind = unreadable(root)
    for name in blind:
        failed += 1
        sys.stderr.write("session login %s: it cannot be read (is it a 0600 file of ours?), so it could NOT be revoked from here -- it is kept\n"
                         % name)
    for rec in chosen:
        sid, short = rec["session_id"], rec["session_id"][:8]
        try:
            with _locked():  # marked FIRST, durably: from here on no resume claims it, whatever the relay then says or does not
                rec = _read_meta(account(root, sid))
                if rec is None:
                    continue  # a concurrent revoke or discard has already ended it
                if not rec.get("revoking"):
                    _write_meta(account(root, sid), dict(rec, revoking=True))
        except OSError as e:
            if forget_local and forget_login(root, sid, "it could not be marked for revoke (%s)" % e):
                forgotten += 1
                continue
            failed += 1
            sys.stderr.write("session %s: it could not be marked for revoke (%s) -- it is kept, run this again\n" % (short, e))
            continue
        secret = secret_of(root, rec)
        if secret is None:
            if forget_local and forget_login(root, sid, "its stored secret cannot be read"):
                forgotten += 1
                continue
            failed += 1
            sys.stderr.write("session %s: its stored secret cannot be read (a locked or emptied Keychain?), so it could NOT be revoked "
                             "from here -- the login is kept, run this again\n" % short)
            continue
        state = _revoke_at_relay(rec, secret["token"])
        if state in ("revoked", "gone"):
            discard(root, sid)
            confirmed += 1
            print("session %s: %s at the relay" % (short, "revoked" if state == "revoked" else "already gone"))
        else:
            why = "the relay refused the stored login" if state == "rejected" else state
            if forget_local and forget_login(root, sid, why):
                forgotten += 1
                continue
            failed += 1
            sys.stderr.write("session %s: the revoke could NOT be confirmed (%s) -- the login is kept, run this again\n" % (short, why))
    return confirmed, forgotten, failed, len(chosen) + len(blind)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd_session_login.py", description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("list", "revoke"))
    ap.add_argument("--repo", required=True)
    ap.add_argument("--device-id", default=None)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--forget-local", action="store_true",
                    help="revoke: a login the relay does not confirm is dropped HERE anyway -- loudly, logged, the relay NOT told")
    args = ap.parse_args(argv)
    root = os.path.realpath(args.repo)
    if args.action == "list":
        print(json.dumps([public(r) for r in records(root)], sort_keys=True))
        return 0
    if bool(args.device_id) == bool(args.all):
        ap.error("revoke takes --device-id ID or --all")
    _confirmed, forgotten, failed, selected = _revoke_logins(root, None if args.all else args.device_id, args.forget_local)
    if selected == 0:
        return 3
    if failed:
        return 1
    return FORGOTTEN if forgotten else 0


if __name__ == "__main__":
    sys.exit(main())

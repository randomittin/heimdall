#!/usr/bin/env python3
"""hmd_session_login.py -- the login a relay client attaches to its relay session with, kept OUTSIDE the repo (stdlib only).

WHY. A paired phone is bound to one relay session, and the bearer token that session was minted with (plus the hmd private key its
session key derives from) lived only in the memory of the client that paired it: a stopped, crashed or killed client could neither be
resumed nor, later, revoke that session, so stopping the laptop's client meant unpairing the phone. Once a phone is bound the client
now stores this login here. A new client resumes the same relay session whenever the old one is gone -- however long ago it was last alive,
unless the operator bounds that with HMD_SESSION_RESUME_H -- and `hmd app disconnect` revokes through it when no client is left to ask.

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

NO LIMIT BY DEFAULT. A paired phone must not drop because Claude Code ended, restarted, resumed or sat idle -- or because a weekend went by. So a
stored login is resumed however long ago its client was last alive: only an explicit disconnect, a revoke from the phone or a failed login
(the relay refusing it: stream 401/404/410) ends a session; the relay's own 30-day device-token lifetime (session_exp) is the one clock, and
the relay says when it ran out. HMD_SESSION_RESUME_H is the operator's opt-in bound, for a login whose client is NOT running: a number of hours
past which that login is discarded on the next look (not revoked) and the phone pairs again; 0 = never resume a stopped client's login.
Unset, empty or not a number is no limit. A login a client that is ALIVE holds is never past any limit (its client is alive now, whatever its
last stamp says): no look discards it, so HMD_SESSION_RESUME_H=0 stops a STOPPED client's session being resumed and never ends a live
phone's session -- a live client that finds its login gone ends itself and revokes (bin/heimdall-relay-client, _login_guard).
THE REPO'S PAIRING RECORD. Per repo, in the same store, $HEIMDALL_HOME/app/repos/<sha256(realpath)[:16]>.json (0600): the repo's session
code and the relay session(s) its phones are paired on -- {"v", "repo", "code", "relay", "sessions": [{"session_id", "device_id"}],
"updated_at"} -- written under the store lock when a phone binds, kept in step with the logins as they go, and removed with the last one.
While it exists every surface shows ITS code (bin/lib/hmd_session_code.py resolve_session_code), so a regenerated machine seed cannot
change the code of a repo that has a paired phone; with the last phone gone the code is derived afresh, as ever. `show` prints it.
CONFIRMED OR KEPT. A login is removed by a revoke here only once the relay confirmed it (the session ended, or is no longer there); an
unreachable or unwilling relay, a secret that cannot be read and a login file that cannot be read all keep it and fail loudly. A revoke
marks the login `revoking` FIRST (under the store lock, durably): from then on no resume claims it, so a disconnect racing a resume ends
revoked and never resumed -- if the resume won the race the revoke ends its session at the relay, if the revoke did, the resume finds
nothing to claim. A login a revoke removed cannot be brought back: every writer re-reads it under the same lock.

CLI (the shell tools; nothing secret is ever printed):
    python3 hmd_session_login.py list   --repo DIR                                   the logins of that repo, as JSON, secret-free
    python3 hmd_session_login.py resumable --repo DIR --relay URL                    the logins a client could resume now (one client per phone), as JSON
    python3 hmd_session_login.py paired --repo DIR --relay URL                       the logins of the phones that are paired (not being revoked), whoever
        serves them -- a live client, or none: what keeps a window and a supervisor from letting go of a phone -- as JSON
    python3 hmd_session_login.py show   --repo DIR                                   the repo's pairing record (its code and relay sessions) as JSON; exit 3 none
    python3 hmd_session_login.py note   --repo DIR --text TEXT                       one line in $HEIMDALL_HOME/logs/app.log: what became of a pairing, and why
    python3 hmd_session_login.py mark   --repo DIR (--device-id ID | --all)          mark those logins `revoking`, ALL in one hold of the store lock: what a
        disconnect does FIRST, before a supervisor, a window, a client or the relay is touched; exit 0 marked, 3 none selected, 1 could not be marked
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
REPOS_REL = "app/repos"  # the repo's pairing record: <sha256(realpath)[:16]>.json -- its code and the relay sessions of its paired phones
SERVICE = "heimdall-relay-session"
SECRET_LIMIT = 16384
_SID_RE = re.compile(r"[A-Za-z0-9_-]{1,100}\Z")
_CODE_RE = re.compile(r"[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}\Z")  # bin/lib/hmd_session_code.py's alphabet and length
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
    """Seconds a STOPPED client's login may sit before it is no longer resumed: HMD_SESSION_RESUME_H hours. There is NO limit by default -- unset,
    empty, negative, not a number or absurdly large is infinity, because the safe reading of a value nobody can use is never to drop a paired
    phone. 0 is the operator's "never resume a stopped client's login" and a positive number their opt-in bound. (A live client's login is never
    expired by any of them: see load_resumable.)"""
    try:
        hours = float(os.environ.get("HMD_SESSION_RESUME_H", "").strip())
    except ValueError:
        return float("inf")
    return hours * 3600 if hours == hours and 0 <= hours < 24 * 3650 else float("inf")


def _repo_key(root):
    """The repo's real path folded to a name that is safe anywhere: what its logins and its pairing record are filed under."""
    return hashlib.sha256(os.path.realpath(root).encode("utf-8")).hexdigest()[:16]


def account(root, sid):
    """The name of one stored login: the repo's real path and the session, folded to a name that is safe anywhere."""
    if not isinstance(sid, str) or not _SID_RE.match(sid):
        raise OSError("not a session id this store can name")
    return "%s-%s" % (_repo_key(root), sid)


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


def repo_record(root):
    """The repo's pairing record -- {"v", "repo", "code", "relay", "sessions": [{"session_id", "device_id"}], "updated_at"} -- or None when the
    repo has no paired phone (or the record cannot be trusted: not a 0600 file of ours, another repo's)."""
    base = home()
    if base is None:
        return None
    rec = PRIVATE.read_json(base, REPOS_REL, _repo_key(root) + ".json", SECRET_LIMIT)
    return rec if rec is not None and rec.get("repo") == os.path.realpath(root) else None


def _repo_code(root):
    """The code this repo's surfaces show for it now (bin/lib/hmd_session_code.py), or None when none can be had. It only READS the machine's
    seed: a phone binding makes no seed of its own (a repo paired by QR alone never had a code), so a record may lack `code` until one exists."""
    try:
        return _sibling("hmd_session_code").resolve_session_code(root, create_seed=False)[0]
    except (ValueError, OSError, ImportError, AttributeError):
        return None


def _live_sessions(root, sessions):
    """`sessions` (a record's list) without the entries whose login is no longer stored: the record names only what exists."""
    held = set(PRIVATE.names(home(), REL))
    return [s for s in sessions if isinstance(s, dict) and _SID_RE.match(str(s.get("session_id")))
            and account(root, s["session_id"]) + ".json" in held]


def _record_write(root, rec):
    """Under the store lock: the repo's record becomes `rec`; a record with no session left is removed -- the repo has no paired phone, so
    its code goes back to being derived. A failure here is said and goes no further: the record is the second thing a login is kept in,
    never a reason to lose the first."""
    base, name = home(), _repo_key(root) + ".json"
    try:
        if rec["sessions"]:
            PRIVATE.write(base, REPOS_REL, name, json.dumps(rec, sort_keys=True, separators=(",", ":")).encode("utf-8"))
        else:
            PRIVATE.remove(base, REPOS_REL, name)
    except OSError as e:
        sys.stderr.write("hmd_session_login: the repo's pairing record could not be updated (%s)\n" % e)


def _record_add(root, relay, sid, device_id):
    """Under the store lock: list session `sid` in the repo's pairing record. The first phone pins the repo's code in it; later ones keep that
    code, so every phone of a repo is paired under the code the first was."""
    old = repo_record(root) or {}
    code = old.get("code") if isinstance(old.get("code"), str) and _CODE_RE.match(old["code"]) else _repo_code(root)
    sessions = [s for s in _live_sessions(root, old.get("sessions") or []) if s.get("session_id") != sid]
    sessions.append({"session_id": sid, "device_id": device_id})
    rec = {"v": 1, "repo": os.path.realpath(root), "relay": relay, "sessions": sessions, "updated_at": int(time.time())}
    if code:
        rec["code"] = code
    _record_write(root, rec)


def _record_drop(root, sid):
    """Under the store lock, once login `sid` is gone: take it out of the repo's pairing record (the last one takes the record with it)."""
    old = repo_record(root)
    if old is None:
        return
    rec = dict(old, sessions=[s for s in _live_sessions(root, old.get("sessions") or []) if s.get("session_id") != sid],
               updated_at=int(time.time()))
    _record_write(root, rec)


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
        _record_add(root, relay, sid, fields.get("device_id"))


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
    _record_drop(root, sid)


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
    """CLAIM the newest login of this repo, on this relay, that may be resumed -- its client last alive within HMD_SESSION_RESUME_H (no limit
    unless the operator set one) and no other client holding it -- under the store lock: its secret ({"token","priv"}) and the seq block [seq_lo, seq_hi) the new client owns
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
            if _held(root, rec.get("pid")):  # a live client serves it: not ours to resume, and never "past the limit" -- a login a live client holds is not discarded
                continue
            if time.time() - float(rec.get("last_alive") or 0) > limit:
                _discard_unlocked(root, rec["session_id"])
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
def paired(root, relay):
    """The logins of the phones that are paired on this relay -- public records, newest first: stored and not being revoked, whoever serves them
    (a live client, or none). Unlike resumable() it asks nothing of the age of a login or of the client holding it, and it discards nothing: it is
    what a pair window and its supervisor look at to know a phone is theirs to keep, so that a Claude session ending lets none of them go."""
    return [public(r) for r in records(root) if _same_relay(r.get("relay"), relay) and not r.get("revoking")]


def resumable(root, relay):
    """The logins a client could claim right now (public records, newest first): this relay, not `revoking`, its client last alive within
    HMD_SESSION_RESUME_H (when the operator set one) -- a login past it is discarded here, as load_resumable does -- no live client holding it and its secret readable.
    What `hmd app connect` and the pair window count to start one client per phone (a relay session binds exactly one)."""
    limit = resume_limit_s()
    found = []
    with _locked():
        for rec in records(root):
            if not _same_relay(rec.get("relay"), relay) or rec.get("revoking"):
                continue
            if _held(root, rec.get("pid")):  # a live client serves it: neither resumable nor expired (see load_resumable)
                continue
            if time.time() - float(rec.get("last_alive") or 0) > limit:
                _discard_unlocked(root, rec["session_id"])
                continue
            mark = rec.get("hmd_seq")
            if secret_of(root, rec) is None or not isinstance(mark, int) or isinstance(mark, bool) or mark < 0:
                continue
            found.append(public(rec))
    return found


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
    _record_drop(root, rec["session_id"])
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


def note(text):
    """One line in $HEIMDALL_HOME/logs/app.log -- what became of a pairing and why (a client ended by a signal, a window kept for a phone, a supervisor
    that stopped), so the next time a phone drops there is a record of what dropped it. Never a secret: the caller passes ids and reasons.
    True when the line was written."""
    base = home()
    if base is None:
        return False
    line = "%s hmd app: %s\n" % (_iso(time.time()), _clean(text, 400))
    try:
        PRIVATE.append(base, APP_LOG_REL, APP_LOG, line.encode("utf-8"), rotate_at=EVENT_LOG_MAX_BYTES)
    except OSError:
        return False
    return True


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


def mark_revoking(root, sids):
    """Mark every login in `sids` `revoking` -- ALL of them in ONE hold of the store lock, durably -- and return the session ids that were there to
    mark. This is the first thing a disconnect does, before a window, a supervisor, a client or the relay is touched: from then on no resume claims
    one of them (a periodic look, a respawn, the pair window and a client started a moment ago all claim under this same lock and skip what is
    marked) and a live client of one ends itself (login_state). OSError when the lock or a write fails; what was written stays."""
    marked = []
    with _locked():
        for sid in sids:
            acct = account(root, sid)
            rec = _read_meta(acct)
            if rec is None:
                continue
            if not rec.get("revoking"):
                _write_meta(acct, dict(rec, revoking=True))
            marked.append(sid)
    return marked


def login_state(root, sid):
    """What a running client may believe about its own stored login: "ok"; "revoking" (a disconnect marked it); "gone" (the store can be read and
    holds no such login: discarded, forgotten or deleted); or "unreadable" (the store, or the file, cannot be read or trusted -- a link, not 0600, not
    ours: no reason to end anybody's session, so nothing acts on it)."""
    base = home()
    if base is None:
        return "unreadable"
    try:
        acct = account(root, sid)
        fd = PRIVATE.open_dir(base, REL, False)
    except OSError:
        return "unreadable"
    try:
        present = acct + ".json" in os.listdir(fd)
    except OSError:
        return "unreadable"
    finally:
        os.close(fd)
    if not present:
        return "gone"
    rec = _read_meta(acct)
    if rec is None:
        return "unreadable"
    return "revoking" if rec.get("revoking") else "ok"


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
    try:  # every selected login is marked in ONE hold of the lock, before any relay call: none stays claimable while an earlier one is being revoked
        mark_revoking(root, [r["session_id"] for r in chosen])
    except OSError:
        pass  # each is marked again, one at a time, below -- and one that cannot be marked is reported there
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
    ap.add_argument("action", choices=("list", "revoke", "resumable", "paired", "show", "note", "mark"))
    ap.add_argument("--relay", default=None, help="resumable, paired: the relay whose logins are counted")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--text", default=None, help="note: the line for $HEIMDALL_HOME/logs/app.log")
    ap.add_argument("--device-id", default=None)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--forget-local", action="store_true",
                    help="revoke: a login the relay does not confirm is dropped HERE anyway -- loudly, logged, the relay NOT told")
    args = ap.parse_args(argv)
    root = os.path.realpath(args.repo)
    if args.action == "list":
        print(json.dumps([public(r) for r in records(root)], sort_keys=True))
        return 0
    if args.action == "resumable":
        if not args.relay:
            ap.error("resumable takes --relay URL")
        print(json.dumps([{"session_id": r["session_id"], "device_id": r.get("device_id")} for r in resumable(root, args.relay)], sort_keys=True))
        return 0
    if args.action == "paired":
        if not args.relay:
            ap.error("paired takes --relay URL")
        print(json.dumps([{"session_id": r["session_id"], "device_id": r.get("device_id")} for r in paired(root, args.relay)], sort_keys=True))
        return 0
    if args.action == "show":
        rec = repo_record(root)
        print(json.dumps(rec if rec is not None else {}, sort_keys=True))
        return 0 if rec is not None else 3
    if args.action == "note":
        if not args.text:
            ap.error("note takes --text TEXT")
        return 0 if note(args.text) else 1
    if bool(args.device_id) == bool(args.all):
        ap.error("%s takes --device-id ID or --all" % args.action)
    if args.action == "mark":
        chosen = [r["session_id"] for r in records(root) if args.all or r.get("device_id") == args.device_id]
        try:
            mark_revoking(root, chosen)
        except OSError as e:
            sys.stderr.write("hmd_session_login: the logins could not be marked revoking (%s)\n" % e)
            return 1
        return 0 if chosen else 3
    _confirmed, forgotten, failed, selected = _revoke_logins(root, None if args.all else args.device_id, args.forget_local)
    if selected == 0:
        return 3
    if failed:
        return 1
    return FORGOTTEN if forgotten else 0


if __name__ == "__main__":
    sys.exit(main())

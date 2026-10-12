#!/usr/bin/env python3
"""hmd_devices.py -- the phones paired to a repo, one record each.

A relay session binds exactly ONE device (relay/README.md: `device_bound` fires once per session, and INV-41 releases the session's
code at the bind), so a repo with more than one phone runs one relay client per phone, each on its own relay session, all offering the
repo's one code in turn and all reading the same repo state. What ties those clients together on this machine is one small record each,
<repo>/.heimdall/app/device-<id>.json (0600, written and read through bin/lib/hmd_private_state.py: no link followed, a file of ours):

    {"v":1,"id":"<8 hex>","label":"..","gh_login":"..","via":"code"|"qr","code":"<code>"|null,"bound_at":N,"last_seen":N,
     "caps":[..],"push_fps":["<16 hex>",..],"pid":N}

`id` is the first 8 hex of the SHA-256 of the phone's raw public key (INV-29's {device_pubkey_fp}), so a phone that pairs again is the same
device. `label` and `gh_login` are what the relay CLAIMED, already cleaned. `push_fps` are fingerprints (never the tokens) of the push tokens
that phone registered, which is how a revoke takes out ITS registrations and nobody else's (bin/lib/companion_push_store.py keeps the tokens;
its signed store is only ever written through its own register / remove_tokens). `pid` is the relay client serving the phone.

A record is believed while that pid is a live bin/heimdall-relay-client: the client removes its own record when it ends, and one a killed
client left behind is a dead record, never a listed device. At most MAX_DEVICES are live at once.

    hmd_devices.py list     --repo R           JSON array of the live devices, oldest pairing first
    hmd_devices.py count    --repo R           how many are live
    hmd_devices.py has-pid  --repo R PID       exit 0 when a live device is served by PID
    hmd_devices.py resolve  --repo R [--dead] NAME   "<id> <pid>" of the live device NAME names (its label, any case, or its id), or with
                                               --dead of the one whose client is gone; exit 1 for none, 2 for more than one (ids on stderr)
    hmd_devices.py forget   --repo R ID        remove the push tokens only that device held, then its record; exit 1, record kept, when the
                                               tokens could not be removed
    hmd_devices.py signal   --repo R ID        the signal that revokes ID's phone: USR1, or TERM for a client older than the records
    hmd_devices.py limit                       how many phones one repo may have paired at once (HMD_PAIR_MAX_DEVICES, default 4)

UPGRADE WHILE PAIRED. A relay client that v2.4.6 (or earlier) started and that is still running has its phone bound but wrote no record
-- it cannot be asked to, and must not be restarted for it. Every read of the records (records(), so list, count, resolve, has-pid, the
relay client's own limit and push checks) therefore makes the record such a client never did, from what it did leave: the status file
relay.json (paired, when), for a phone that paired by code the marker paired-<code>.json (label, GitHub login, when), the event log's last
device_caps (capabilities), the signed push store (its tokens). The record is marked "legacy": true and stored with create_once, so
it is made once however many readers race and read as any other afterwards. Nothing the client runs on is touched -- no signal, no
state file of its own. A legacy phone's id cannot be the fingerprint of its key (the key lived only in that client's memory): it is the
hash of the client's pid and the bind time. The client never refreshes the record, so it holds the push tokens it had when it was made
and, while its client runs, every token in the store that no other record claims; and it is revoked with TERM (see `signal`), the one
signal that client handles.

A REVOKE IS FINAL. forget() removes the push tokens first -- the record is what names them, so tokens that cannot be removed leave it and
the revoke is reported as failed, never as done -- and then the record. A legacy record is not removed but rewritten as a tombstone
(`revoked`): it is made from files its client left, and a removed one would be made again for as long as that client runs or its files
stay. A revoked record is no device: live(), so every list, count, limit and push check, skips it. A phone whose client is gone (it
crashed) cannot be revoked at the relay from here -- its session token lived in that client's memory only -- so `resolve --dead` finds
its record, for the caller to clean up and to say so.

Stdlib only; loadable by path like the other bin/lib modules, no side effects at import.
"""
import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

MAX_DEVICES = 4  # the most one repo may have: a ceiling HMD_PAIR_MAX_DEVICES can lower, never raise
REL = ".heimdall/app"
_NAME_RE = re.compile(r"device-([0-9a-f]{8})\.json\Z")
_ID_RE = re.compile(r"[0-9a-f]{8}\Z")
CLIENT_MARK = "heimdall-relay-client"
_MARKER_RE = re.compile(r"paired-([A-HJ-NP-Z2-9]{5})\.json\Z")  # the marker a client leaves for a phone that paired by code


def _sibling(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(os.path.dirname(os.path.realpath(__file__)), name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PRIVATE = _sibling("hmd_private_state")


def max_devices():
    """How many phones this repo may have paired at once: HMD_PAIR_MAX_DEVICES, 1..MAX_DEVICES (default MAX_DEVICES). 1 is the one-phone
    behavior -- the code is not offered again once a phone is bound. This is a switch that LIMITS a way in, so a value that is not a whole
    number fails closed to 1, and one above the ceiling is the ceiling."""
    raw = os.environ.get("HMD_PAIR_MAX_DEVICES", "")
    if raw == "":
        return MAX_DEVICES
    try:
        return max(1, min(int(raw), MAX_DEVICES))
    except ValueError:
        return 1


def device_id(pub):
    """The id of the phone whose raw X25519 public key is `pub`."""
    return hashlib.sha256(pub).hexdigest()[:8]


def token_fp(token):
    """What a record keeps of a push token: enough to match it, never the token."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]


def clean(value, limit):
    """`value` without C0/C1 controls and DEL, cut to `limit` characters: what a relay-claimed name is reduced to before it is shown."""
    return "".join(ch for ch in str(value) if not (ord(ch) < 0x20 or 0x7F <= ord(ch) <= 0x9F))[:limit]


def shown(rec):
    """`rec` as `list` prints it: every text the relay or the phone supplied reduced to printable characters."""
    return dict(rec, label=clean(rec["label"], 32), gh_login=clean(rec["gh_login"], 39), caps=[clean(c, 40) for c in rec["caps"]])


def record_name(dev_id):
    return "device-%s.json" % dev_id


def write_record(root, rec):
    """Store `rec` (a dict with at least `id`) as the device's record. Raises OSError when the state directory cannot be used."""
    PRIVATE.write(root, REL, record_name(rec["id"]), json.dumps(rec, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def remove_record(root, dev_id):
    return PRIVATE.remove(root, REL, record_name(dev_id))


def client_alive(pid, root=None):
    """True while `pid` is a running (not a zombie) heimdall-relay-client of THIS user's and, when `root` is given, of that repo. A record is a
    file in a tree a repository controls: the process it names is looked at here, never believed -- one that is another user's, another
    repo's or not a relay client at all is no device."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        out = subprocess.run(["ps", "-ww", "-o", "stat=,uid=,command=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    m = re.match(r"(\S+)\s+(\d+)\s+(.*)\Z", out, re.S)
    if m is None or m.group(1).startswith("Z") or int(m.group(2)) != os.geteuid() or CLIENT_MARK not in m.group(3):
        return False
    if root is None:
        return True
    repo = re.search(r"--repo (.+?) --ui-port ", m.group(3))
    return repo is not None and os.path.realpath(repo.group(1)) == root


def _valid(rec, dev_id):
    if rec.get("v") != 1 or rec.get("id") != dev_id:
        return False
    return all(isinstance(rec.get(k), int) and not isinstance(rec.get(k), bool) for k in ("pid", "bound_at", "last_seen")) \
        and isinstance(rec.get("label"), str) and isinstance(rec.get("gh_login"), str) \
        and isinstance(rec.get("caps"), list) and isinstance(rec.get("push_fps"), list)


def _whole(value):
    """`value` as a whole number, or None when it is not a number."""
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _store_fps(root):
    """Fingerprints of the push tokens in the repo's signed store: a client older than the records kept every one its one phone
    registered there. A store that cannot be read holds nothing to claim."""
    try:
        return {token_fp(e["token"]) for e in _sibling("companion_push_store").load(root)["tokens"]}
    except (OSError, ValueError, ImportError, AttributeError, KeyError):
        return set()


def _logged_caps(root):
    """The capabilities the phone last listed in the event log (a bind starts with none): [] when the log is off or holds none. It is
    the only place a client older than the records ever put them."""
    caps = []
    for line in (PRIVATE.read(root, REL, "relay-events.jsonl", 8 << 20) or b"").decode("utf-8", "replace").splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        if ev.get("event") in ("device_bound", "code_paired"):
            caps = []
        elif ev.get("event") == "device_caps" and isinstance(ev.get("caps"), list):
            caps = [c for c in ev["caps"] if isinstance(c, str)]
    return caps


def _legacy_candidates(root):
    """{pid: what is known of its phone} for the clients that left only what v2.4.6 and earlier kept: the status file relay.json of the
    client that wrote it last (`paired`, when) and, for a phone that paired by code, the marker paired-<code>.json (label, GitHub login,
    when). Both are read through hmd_private_state; a pid is only a candidate until client_alive has looked at the process."""
    found = {}
    status = PRIVATE.read_json(root, REL, "relay.json")
    if status is not None and status.get("paired") is True and _whole(status.get("pid")) and _whole(status.get("bound_at")) is not None:
        found[_whole(status["pid"])] = {"label": "unnamed device", "gh_login": "unknown", "via": "qr", "code": None,
                                        "bound_at": _whole(status["bound_at"])}
    for name in PRIVATE.names(root, REL):
        m = _MARKER_RE.match(name)
        mark = PRIVATE.read_json(root, REL, name) if m else None
        if mark is not None and mark.get("via") == "code" and _whole(mark.get("pid")) and _whole(mark.get("bound_at")) is not None:
            found[_whole(mark["pid"])] = {"label": clean(mark.get("device_label") or "", 32) or "unnamed device",
                                          "gh_login": clean(mark.get("gh_login") or "", 39) or "unknown",
                                          "via": "code", "code": m.group(1), "bound_at": _whole(mark["bound_at"])}
    return found


def _migrate(root, named):
    """The records of the phones whose client is older than the records, made now from what that client left (UPGRADE WHILE PAIRED in the
    module docstring): one per running client that has a phone bound and that no record (`named`: their pids) names. Read-time and
    idempotent -- once a record is stored its pid is named and nothing is made again -- and it touches neither the client nor its relay
    session. A record that cannot be stored is still returned: the phone is listed whether or not the directory takes the file."""
    made = []
    for pid, info in _legacy_candidates(root).items():
        if pid in named or not client_alive(pid, root):
            continue
        st = PRIVATE.stat_file(root, REL, "relay.json")
        ident = hashlib.sha256(("hmd-legacy-device-v1:%d:%d" % (pid, info["bound_at"])).encode("ascii")).hexdigest()[:8]
        rec = dict(info, v=1, id=ident, pid=pid, legacy=True, last_seen=max(info["bound_at"], int(st.st_mtime)) if st else info["bound_at"],
                   caps=_logged_caps(root), push_fps=sorted(_store_fps(root)))
        with contextlib.suppress(OSError):
            PRIVATE.create_once(root, REL, record_name(ident), json.dumps(rec, sort_keys=True, separators=(",", ":")).encode("utf-8"))
        made.append(rec)
    return made


def records(root):
    """Every well-formed record, live or not, oldest pairing first -- those of phones bound through a client older than the records
    included (_migrate)."""
    found = []
    for name in PRIVATE.names(root, REL):
        m = _NAME_RE.match(name)
        rec = PRIVATE.read_json(root, REL, name) if m else None
        if rec is not None and _valid(rec, m.group(1)):
            found.append(rec)
    found += _migrate(root, {r["pid"] for r in found})
    return sorted(found, key=lambda r: (r["bound_at"], r["id"]))


def live(root, except_pid=None):
    """The records whose client is running, except the one `except_pid` serves. A revoked record is gone, whatever its client left."""
    return [r for r in records(root) if r["pid"] != except_pid and not r.get("revoked") and client_alive(r["pid"], root)]


def stale(root):
    """The records of the phones whose client is no longer running and that were never revoked: what a crashed client left behind."""
    return [r for r in records(root) if not r.get("revoked") and not client_alive(r["pid"], root)]


def push_fps_of(root, rec):
    """The fingerprints of the push tokens `rec`'s phone holds: the ones its record lists and, for a phone bound through a client older
    than the records -- which never listed any, and registers more on its own -- every token in the store that no other record claims."""
    mine = {fp for fp in rec["push_fps"] if isinstance(fp, str)}
    if rec.get("legacy") and not rec.get("revoked"):
        claimed = {fp for r in records(root) if r["id"] != rec["id"] for fp in r["push_fps"] if isinstance(fp, str)}
        mine |= _store_fps(root) - claimed
    return mine


def held_push_fps(root, except_pid=None):
    """Fingerprints of the push tokens that live devices (other than the one `except_pid` serves) registered."""
    return {fp for r in live(root, except_pid) for fp in push_fps_of(root, r)}


def _drop_push_tokens(root, fps, except_pid=None):
    """Remove the push tokens whose fingerprint is in `fps` and that no live device (other than the one `except_pid` serves) holds. False
    when the store could not be edited: the tokens are then still in it, and the caller says so."""
    try:
        store = _sibling("companion_push_store")
        keep = held_push_fps(root, except_pid)
        doomed = [e["token"] for e in store.load(root)["tokens"] if token_fp(e["token"]) in fps and token_fp(e["token"]) not in keep]
        if doomed:
            store.remove_tokens(root, doomed)
    except (OSError, ValueError, ImportError, AttributeError, KeyError):
        return False
    return True


def forget(root, dev_id):
    """The device is gone (its client ended, or it was revoked): its push tokens go FIRST, then its record -- the record is what names the
    tokens, so tokens that cannot be removed leave it, and the answer is False: nothing is then to be reported as revoked. A phone bound
    through a client older than the records keeps its record as a tombstone (`revoked`) instead of losing it: that record is made from
    files its client left, and a removed one would be made again for as long as the client runs. True when both are done."""
    rec = next((r for r in records(root) if r["id"] == dev_id), None)
    if rec is None or rec.get("revoked"):
        return True
    if not _drop_push_tokens(root, push_fps_of(root, rec), rec["pid"]):
        return False
    if not rec.get("legacy"):
        remove_record(root, dev_id)
        return True
    try:
        write_record(root, dict(rec, revoked=True, caps=[], push_fps=[]))
    except OSError:
        return False
    return True


def resolve(root, wanted, dead=False):
    """The live records `wanted` names -- with `dead`, the stale ones -- the one whose id it is, else every one whose label it is
    (compared without case)."""
    devices = stale(root) if dead else live(root)
    by_id = [r for r in devices if r["id"] == wanted.lower()]
    return by_id or [r for r in devices if r["label"].lower() == wanted.lower()]


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd_devices.py", description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("list", "count", "has-pid", "resolve", "forget", "signal", "limit"))
    ap.add_argument("--repo", default="")
    ap.add_argument("--dead", action="store_true", help="resolve: the phones whose client is gone, not the running ones")
    ap.add_argument("arg", nargs="?")
    args = ap.parse_intermixed_args(argv)  # `has-pid --repo R PID`: the argument comes after the option
    if args.action != "limit" and not args.repo:
        ap.error("%s needs --repo" % args.action)
    root = os.path.realpath(args.repo)
    if args.action in ("has-pid", "resolve", "forget", "signal") and not args.arg:
        ap.error("%s needs an argument" % args.action)
    if args.action == "limit":
        print(max_devices())
    elif args.action == "signal":
        rec = next((r for r in records(root) if r["id"] == args.arg), None)
        print("TERM" if rec is not None and rec.get("legacy") else "USR1")
    elif args.action == "list":
        print(json.dumps([shown(r) for r in live(root)], sort_keys=True))
    elif args.action == "count":
        print(len(live(root)))
    elif args.action == "has-pid":
        return 0 if args.arg.isdigit() and any(r["pid"] == int(args.arg) for r in live(root)) else 1
    elif args.action == "resolve":
        found = resolve(root, args.arg, args.dead)
        if not found:
            return 1
        if len(found) > 1:
            print(" ".join(r["id"] for r in found), file=sys.stderr)
            return 2
        print("%s %d" % (found[0]["id"], found[0]["pid"]))
    elif _ID_RE.match(args.arg):
        if not forget(root, args.arg):
            print("hmd_devices: %s: its push tokens could not be removed, so its record is kept" % args.arg, file=sys.stderr)
            return 1
    else:
        ap.error("forget takes a device id")
    return 0


if __name__ == "__main__":
    sys.exit(main())

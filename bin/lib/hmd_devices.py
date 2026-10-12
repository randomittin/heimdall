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
    hmd_devices.py resolve  --repo R NAME      "<id> <pid>" of the live device NAME names (its label, any case, or its id);
                                               exit 1 for none, 2 for more than one (their ids on stderr)
    hmd_devices.py forget   --repo R ID        remove the record and the push tokens only that device held
    hmd_devices.py limit                       how many phones one repo may have paired at once (HMD_PAIR_MAX_DEVICES, default 4)

Stdlib only; loadable by path like the other bin/lib modules, no side effects at import.
"""
import argparse
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


def records(root):
    """Every well-formed record, live or not, oldest pairing first."""
    found = []
    for name in PRIVATE.names(root, REL):
        m = _NAME_RE.match(name)
        rec = PRIVATE.read_json(root, REL, name) if m else None
        if rec is not None and _valid(rec, m.group(1)):
            found.append(rec)
    return sorted(found, key=lambda r: (r["bound_at"], r["id"]))


def live(root, except_pid=None):
    """The records whose client is running, except the one `except_pid` serves."""
    return [r for r in records(root) if r["pid"] != except_pid and client_alive(r["pid"], root)]


def held_push_fps(root, except_pid=None):
    """Fingerprints of the push tokens that live devices (other than the one `except_pid` serves) registered."""
    return {fp for r in live(root, except_pid) for fp in r["push_fps"] if isinstance(fp, str)}


def _drop_push_tokens(root, fps):
    """Remove the push tokens whose fingerprint is in `fps` and that no live device holds. False when the store could not be edited: a
    token left in it belongs to a phone nobody is paired with, and the next pairing clears it."""
    try:
        store = _sibling("companion_push_store")
        keep = held_push_fps(root)
        doomed = [e["token"] for e in store.load(root)["tokens"] if token_fp(e["token"]) in fps and token_fp(e["token"]) not in keep]
        if doomed:
            store.remove_tokens(root, doomed)
    except (OSError, ValueError, ImportError, AttributeError, KeyError):
        return False
    return True


def forget(root, dev_id):
    """The device is gone (its client ended or was revoked): drop its record and the push tokens only it held."""
    rec = next((r for r in records(root) if r["id"] == dev_id), None)
    remove_record(root, dev_id)
    if rec is not None and rec["push_fps"]:
        _drop_push_tokens(root, set(rec["push_fps"]))


def resolve(root, wanted):
    """The live records `wanted` names: the one whose id it is, else every one whose label it is (compared without case)."""
    devices = live(root)
    by_id = [r for r in devices if r["id"] == wanted.lower()]
    return by_id or [r for r in devices if r["label"].lower() == wanted.lower()]


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd_devices.py", description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("list", "count", "has-pid", "resolve", "forget", "limit"))
    ap.add_argument("--repo", default="")
    ap.add_argument("arg", nargs="?")
    args = ap.parse_intermixed_args(argv)  # `has-pid --repo R PID`: the argument comes after the option
    if args.action != "limit" and not args.repo:
        ap.error("%s needs --repo" % args.action)
    root = os.path.realpath(args.repo)
    if args.action in ("has-pid", "resolve", "forget") and not args.arg:
        ap.error("%s needs an argument" % args.action)
    if args.action == "limit":
        print(max_devices())
    elif args.action == "list":
        print(json.dumps([shown(r) for r in live(root)], sort_keys=True))
    elif args.action == "count":
        print(len(live(root)))
    elif args.action == "has-pid":
        return 0 if args.arg.isdigit() and any(r["pid"] == int(args.arg) for r in live(root)) else 1
    elif args.action == "resolve":
        found = resolve(root, args.arg)
        if not found:
            return 1
        if len(found) > 1:
            print(" ".join(r["id"] for r in found), file=sys.stderr)
            return 2
        print("%s %d" % (found[0]["id"], found[0]["pid"]))
    elif _ID_RE.match(args.arg):
        forget(root, args.arg)
    else:
        ap.error("forget takes a device id")
    return 0


if __name__ == "__main__":
    sys.exit(main())

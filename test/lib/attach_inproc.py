#!/usr/bin/env python3
"""test/lib/attach_inproc.py -- the cases of test/companion-attach.test.sh that must see INSIDE one call, which a sealed-frame round trip
through the real relay client cannot: a base64 decode that never happened, a write that never started, a directory that is a link on
the way down, a directory some other account owns.

    attach_inproc.py CONTROLS_PY SCENARIO ROOT [heimdall|app|attachments]      -> ONE JSON object on stdout

    link  <where>        that directory on the way to the pictures is a link to somewhere else; one upload
    owner                every directory on the way belongs to another account; one upload
    sweep-link <where>   the same link, then sweep() with a day-old picture on the far side of it
    decode               100 attach-chunk commands in one burst, counting the base64 decodes
    note                 a note the inbox record cannot hold, then one it can, counting the writes

CONTROLS_PY is bin/lib/companion_ui_controls.py (or the copy a mutant changed): it is loaded by path in this fresh interpreter, which
finds bin/lib/companion_attach.py beside it, and driven the way the relay client drives it -- dispatch(root, action, params,
caps=frozenset()) with the phone's own begin / chunk / commit params -- so the allowlist, the rate buckets, the rid memory and the audit
line are the real ones. ROOT is an empty directory the scenario builds its tree in; a place the tree must not reach is built beside it
(ROOT + "-outside"). Nothing is replaced except where a scenario says so: it wraps ONE function to count the calls that reach it, or one
os function to lie about who is asking.
"""
import base64
import hashlib
import importlib.util
import json
import os
import stat
import sys
import time

CHUNK = 262144
WHERE = {"heimdall": (), "app": (".heimdall",), "attachments": (".heimdall", "app")}     # the real directories above the link
LINK = {"heimdall": ".heimdall", "app": "app", "attachments": "attachments"}             # the name that is the link
BELOW = {"heimdall": ("app", "attachments"), "app": ("attachments",), "attachments": ()}  # what the pictures' directory is, past the link


def load(path):
    spec = importlib.util.spec_from_file_location("controls", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def seg(marker, payload):
    n = len(payload) + 2
    return bytes([0xFF, marker, n >> 8, n & 0xFF]) + payload


def jpeg():
    """A framing-valid 1x1 JPEG (nothing decodes the pixels), the shape test/lib/attach_scenarios.py builds."""
    return (b"\xff\xd8" + seg(0xE0, b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00") + seg(0xC0, bytes([8, 0, 1, 0, 1, 1, 1, 0x11, 0]))
            + seg(0xDA, bytes([1, 1, 0, 0, 63, 0])) + b"\x12\x34" + b"\x55" * 16 + b"\xff\xd9")


class Phone:
    """The app's three commands, through the dispatcher the relay client calls."""

    def __init__(self, controls, root):
        self.controls, self.root, self.count = controls, root, 0

    def send(self, action, **params):
        self.count += 1
        params.setdefault("rid", "t-%d" % self.count)
        return self.controls.dispatch(self.root, action, params, caps=frozenset())

    def upload(self, data, message=None):
        """begin, every chunk, commit -> {"begin": [ok, detail], "commit": [ok, detail] | None (a step before it was refused)}."""
        pieces = [data[i:i + CHUNK] for i in range(0, len(data), CHUNK)]
        ok, detail, extra = self.send("attach-begin", name="x.jpg", mime="image/jpeg", bytes=len(data), w=1, h=1, n=len(pieces),
                                      sha256=hashlib.sha256(data).hexdigest())
        out = {"begin": [ok, detail], "commit": None}
        if not ok:
            return out
        for idx, piece in enumerate(pieces):
            ok, detail, _extra = self.send("attach-chunk", id=extra["id"], idx=idx, b64=base64.b64encode(piece).decode("ascii"))
            if not ok:
                out["chunk"] = [ok, detail]
                return out
        params = {"id": extra["id"]}
        if message is not None:
            params["message"] = message
        ok, detail, _extra = self.send("attach-commit", **params)
        out["commit"] = [ok, detail]
        return out


def listing(top):
    """Every path under `top`, relative and sorted, a directory with a trailing slash."""
    found = []
    for here, dirs, names in os.walk(top):
        rel = os.path.relpath(here, top)
        found += [os.path.normpath(os.path.join(rel, d)) + "/" for d in dirs]
        found += [os.path.normpath(os.path.join(rel, n)) for n in names]
    return sorted(found)


def link_tree(root, where):
    """ROOT/.heimdall[/app[/attachments]] with the directory `where` replaced by a link to ROOT-outside (an empty directory) -> its path."""
    outside = root + "-outside"
    os.makedirs(outside)
    here = root
    for part in WHERE[where]:
        here = os.path.join(here, part)
        os.makedirs(here)
    os.symlink(outside, os.path.join(here, LINK[where]))
    return outside


def s_link(controls, attach, root, where):
    outside = link_tree(root, where)
    result = Phone(controls, root).upload(jpeg(), "hello")
    result["outside"] = listing(outside)
    return result


def s_owner(controls, attach, root):
    heimdall = os.path.join(root, ".heimdall")
    app = os.path.join(heimdall, "app")
    attachments = os.path.join(app, "attachments")
    os.makedirs(attachments)
    dirs = (heimdall, app, attachments)
    for path in dirs:
        os.chmod(path, 0o755)
    real = os.geteuid
    os.geteuid = lambda: real() + 1                       # as if every one of those directories belonged to another account
    try:
        result = Phone(controls, root).upload(jpeg(), "hello")
    finally:
        os.geteuid = real
    result["modes"] = [oct(stat.S_IMODE(os.stat(path).st_mode)) for path in dirs]
    result["files"] = sorted(os.listdir(attachments))
    return result


def s_sweep_link(controls, attach, root, where):
    outside = link_tree(root, where)
    far = os.path.join(outside, *BELOW[where])
    os.makedirs(far, exist_ok=True)
    stale = os.path.join(far, "att-aaaaaaaa.jpg")
    with open(stale, "wb") as f:
        f.write(jpeg())
    day_old = time.time() - 25 * 3600
    os.utime(stale, (day_old, day_old))
    removed = attach.sweep(root)
    return {"removed": removed, "outside": listing(outside)}


def s_decode(controls, attach, root):
    seen = [0]
    real = attach.base64

    class Counting:
        def __getattr__(self, name):
            return getattr(real, name)

        def b64decode(self, *args, **kwargs):
            seen[0] += 1
            return real.b64decode(*args, **kwargs)

    attach.base64 = Counting()
    phone = Phone(controls, root)
    body = base64.b64encode(b"x" * 4096).decode("ascii")
    details = [phone.send("attach-chunk", id="att-00000000", idx=0, b64=body)[1] for _ in range(100)]
    limited = details.count("rate-limited")
    return {"decodes": seen[0], "limited": limited, "answered": len(details) - limited, "details": sorted(set(details))}


def s_note(controls, attach, root):
    writes = []
    real = attach._store

    def counting(*args, **kwargs):
        writes.append(args[1])
        return real(*args, **kwargs)

    attach._store = counting
    phone = Phone(controls, root)
    too_long = phone.upload(jpeg(), "n" * 1990)           # inside the app's 2000-character field, not inside the record
    writes_for_it = len(writes)
    fits = phone.upload(jpeg(), "fits")
    return {"long": too_long["commit"], "writes_for_long": writes_for_it, "short": fits["commit"], "writes_total": len(writes)}


SCENARIOS = {"link": s_link, "owner": s_owner, "sweep-link": s_sweep_link, "decode": s_decode, "note": s_note}


def main(argv):
    controls_path, scenario, root, extra = argv[1], argv[2], argv[3], argv[4:]
    controls = load(controls_path)
    attach = controls._sibling("companion_attach")
    if attach is None:
        print(json.dumps({"error": "companion_attach did not load"}))
        return 1
    print(json.dumps(SCENARIOS[scenario](controls, attach, root, *extra)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

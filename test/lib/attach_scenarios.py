#!/usr/bin/env python3
"""test/lib/attach_scenarios.py -- the cases of test/companion-attach.test.sh: `attach-v1`, a picture from the paired phone, saved on the
laptop and handed to the Claude session (hmdapp docs/HANDOFF-TO-HEIMDALL-cursor-parity.md CP6; the phone half is hmdapp's src/attach).

Every case drives the REAL bin/heimdall-relay-client (or a mutated copy of it -- see --client) as its own process against
test/lib/fake-relay.py, through sealed commands shaped exactly like the app's (src/attach/protocol.ts: rids `a-..`, `<rid>-<idx>`,
`<rid>-c`; 256 KiB chunks; the commit's note riding the first image) and the sealed ack that answers each, with test/lib/view_phone.py
playing the paired phone. Nothing here imports the client or bin/lib/companion_attach.py. The pictures are built here: the JPEG has the
shape hmdapp's own test builds (src/attach/__tests__/attach.test.ts buildJpeg), with and without the tags a phone writes.

    attach_scenarios.py --client PATH [--groups wire,happy,max,refuse,gate,keep,off,rate,maxws]

Secret-shaped inputs are assembled at runtime: no such literal sits in the repo. Output: "  ok   ..." / "  FAIL ..." lines and a closing
"P passed, F failed"; exit 1 when F > 0. Processes this starts are reaped on exit; it signals nothing else.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import view_phone as VP  # noqa: E402

REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
FAKE_RELAY = os.path.join(HERE, "fake-relay.py")
DELIVER = os.path.join(REPO, "bin", "heimdall-inbox-deliver")
CONTROLS = os.path.join(REPO, "bin", "lib", "companion_ui_controls.py")
CHUNK = 262144
MAX_BYTES = 2 * 1024 * 1024
APP_CAPS = ["z-zlib", "resync", "push-v1", "login-v1", "view-v1", "dash-v1"]   # hmdapp src/transport/resync.ts APP_CAPS: no attach-v1
MARKER = "[companion inbox -- message from the paired phone"
GROUPS = ["wire", "happy", "max", "refuse", "gate", "keep", "off", "rate", "maxws"]
PASS = FAIL = 0
COUNTER = [0]
DROP = object()


def check(cond, text, got=None):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ok   " + text, flush=True)
    else:
        FAIL += 1
        print("  FAIL " + text, flush=True)
        if got is not None:
            print("       got: %s" % (str(got)[:500],), flush=True)


def refused(ack, code):
    return ack is not None and ack.get("ok") is False and ack.get("detail") == code and "id" not in ack


def token_shaped():
    return "".join(("gh", "p_", "Q" * 36))     # a GitHub-token-shaped string, assembled at runtime


# -- the pictures --------------------------------------------------------------------------------------------------------
def seg(marker, payload):
    n = len(payload) + 2
    return bytes([0xFF, marker, n >> 8, n & 0xFF]) + payload


LEAKS = [b"Exif", b"GPSLatitude", b"GPSLongitude", b"xmpmeta", b"Photoshop", b"IPTC", b"taken at home", b"thumb"]


def jpeg(metadata=False, entropy=16, w=1, h=1):
    """Framing-valid JPEG bytes (nothing decodes the pixels) in the shape hmdapp's attach.test.ts buildJpeg() makes; with `metadata` it carries
    every kind of tag a phone photo does."""
    head = b"\xff\xd8" + seg(0xE0, b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00")
    tags = b""
    if metadata:
        tags = (seg(0xE1, b"Exif\x00\x00GPSLatitude=12.97 GPSLongitude=77.59")
                + seg(0xE1, b"http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta>home</x:xmpmeta>")
                + seg(0xED, b"Photoshop 3.0\x00IPTC-caption") + seg(0xFE, b"taken at home")
                + seg(0xE0, b"JFXX\x00\x10thumbnail"))
    frame = (seg(0xE2, b"ICC_PROFILE\x00\x01\x01\x09\x09\x09") + seg(0xC0, bytes([8, h >> 8, h & 255, w >> 8, w & 255, 1, 1, 0x11, 0]))
             + seg(0xDA, bytes([1, 1, 0, 0, 63, 0])) + b"\x12\xff\x00\x34\xff\xd0\x56")
    return head + tags + frame + b"\x55" * entropy + b"\xff\xd9"


def png_chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def png(w=2, h=2, extra=()):
    rows = b"".join(b"\x00" + b"\x10\x20\x30" * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + b"".join(extra)
            + png_chunk(b"IDAT", zlib.compress(rows)) + png_chunk(b"IEND", b""))


# -- the app's commands ----------------------------------------------------------------------------------------------------
def rid(prefix):
    COUNTER[0] += 1
    return "%s%d" % (prefix, COUNTER[0])


def call(p, action, params):
    return p.ack(p.command({"action": action, "params": {k: v for k, v in params.items() if v is not DROP}}))


def parts(data):
    return [data[i:i + CHUNK] for i in range(0, len(data), CHUNK)]


def begin(p, data, **over):
    params = {"rid": rid("a-"), "name": "IMG-0001.jpg", "mime": "image/jpeg", "bytes": len(data), "w": 1, "h": 1,
              "n": max(1, -(-len(data) // CHUNK)), "sha256": hashlib.sha256(data).hexdigest()}
    params.update(over)
    return call(p, "attach-begin", params)


def put(p, att_id, idx, raw, **over):
    params = {"rid": rid("c-"), "id": att_id, "idx": idx, "b64": base64.b64encode(raw).decode("ascii")}
    params.update(over)
    return call(p, "attach-chunk", params)


def finish(p, att_id, message=None, **over):
    params = {"rid": rid("m-"), "id": att_id}
    if message is not None:
        params["message"] = message
    params.update(over)
    return call(p, "attach-commit", params)


def upload(p, data, message=None, order=None, **begin_over):
    """The app's whole sequence for one image -> (begin ack, [chunk acks], commit ack)."""
    b = begin(p, data, **begin_over)
    if not (b and b.get("ok")):
        return b, [], None
    pieces = parts(data)
    acks = []
    for i in (order or range(len(pieces))):
        acks.append(put(p, b["id"], i, pieces[i]))
        if not (acks[-1] and acks[-1].get("ok")):          # a chunk that was not taken ends the sequence, as the app's upload does
            return b, acks, None
    return b, acks, finish(p, b["id"], message)


# -- the world -------------------------------------------------------------------------------------------------------------
def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class World:
    def __init__(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="attach-"))
        self.home = os.path.join(self.tmp, "home")
        self.env = dict(os.environ, HOME=self.home, HEIMDALL_HOME=os.path.join(self.home, ".heimdall"), TMPDIR=os.path.join(self.tmp, "tmp"),
                        HMD_PYTHON=sys.executable, HMD_PUSH="0", HMD_UI_COMPANION_PANELS="0", HEIMDALL_FALLBACK_ASSUME_REACHABLE="0",
                        HEIMDALL_FALLBACK_PROBE_TIMEOUT="1")
        for var in ("CLAUDE_SESSION_ID", "SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CONFIG_DIR", "HMD_UI_CONTROLS", "HMD_ATTACH",
                    "CLAUDE_CODE_ENTRYPOINT", "HMD_AGENT_TYPE", "HMD_JUDGMENT", "CLAUDE_PROJECT_DIR"):
            self.env.pop(var, None)
        for d in (os.path.join(self.home, ".claude"), os.path.join(self.tmp, "tmp")):
            os.makedirs(d)

    def repo(self, name):
        path = os.path.join(self.tmp, name)
        os.makedirs(path)
        for args in (("init", "-q", "."), ("add", "-A"), ("commit", "-q", "--allow-empty", "-m", "fixture")):
            subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *args], cwd=path, check=True, capture_output=True)
        with open(os.path.join(path, ".gitignore"), "w") as f:
            f.write(".heimdall/\n")
        return path

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class Stack:
    """One fake relay and one real relay client on its own repo, with a phone bound to it."""

    def __init__(self, world, client, name, env=None, ws=False):
        self.world, self.client_path, self.name, self.ws = world, client, name, ws
        self.repo = world.repo(name)
        self.att = os.path.join(self.repo, ".heimdall", "app", "attachments")
        self.dir = os.path.join(world.tmp, "stack-" + name)
        self.log, self.ctl = os.path.join(self.dir, "log"), os.path.join(self.dir, "ctl")
        self.out, self.err = os.path.join(self.dir, "client.out"), os.path.join(self.dir, "client.err")
        self.env = dict(world.env, **(env or {}))
        self.procs, self.phone, self.client = [], None, None

    def start(self):
        for d in (self.dir, self.log, self.ctl):
            os.makedirs(d, exist_ok=True)
        relay_port, ui_port = free_port(), free_port()
        self.procs.append(subprocess.Popen([sys.executable, FAKE_RELAY, "serve", str(relay_port), "--log", self.log, "--ctl", self.ctl]
                                           + (["--ws"] if self.ws else []),
                                           stdout=open(os.path.join(self.dir, "relay.out"), "w"), stderr=subprocess.STDOUT))
        for _ in range(100):
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", relay_port)) == 0:
                    break
            time.sleep(0.1)
        self.phone = VP.Phone(self.ctl, self.log)
        self.phone.bind()
        self.client = subprocess.Popen([self.client_path, "--relay", "http://127.0.0.1:%d" % relay_port, "--repo", self.repo, "--ui-port",
                                        str(ui_port)], stdout=open(self.out, "w"), stderr=open(self.err, "w"), env=self.env)
        self.procs.append(self.client)
        return self.phone.pair(self.out)

    def stop(self):
        for proc in reversed(self.procs):
            if proc.poll() is None:
                proc.terminate()
        for proc in self.procs:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    def files(self):
        return sorted(os.listdir(self.att)) if os.path.isdir(self.att) else []

    def inbox(self):
        try:
            with open(os.path.join(self.repo, ".heimdall", "ui", "inbox.jsonl"), encoding="utf-8") as f:
                return [json.loads(line) for line in f if line.strip()]
        except OSError:
            return []

    def audit(self):
        try:
            with open(os.path.join(self.repo, ".heimdall", "ui", "controls-audit.jsonl"), encoding="utf-8") as f:
                return [json.loads(line) for line in f if line.strip()]
        except OSError:
            return []

    def found_in(self, needle):
        """The places `needle` is in: what the client and the relay wrote, the audit log and every decrypted frame. [] when nowhere."""
        paths = {"stdout": self.out, "stderr": self.err, "relay-log": os.path.join(self.log, "requests.log"),
                 "events": os.path.join(self.repo, ".heimdall", "app", "relay-events.jsonl"),
                 "status": os.path.join(self.repo, ".heimdall", "app", "relay.json"),
                 "audit": os.path.join(self.repo, ".heimdall", "ui", "controls-audit.jsonl")}
        text = {}
        for name, path in paths.items():
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    text[name] = f.read()
            except OSError:
                text[name] = ""
        text["frames"] = self.phone.all_text()
        return [name for name, body in text.items() if needle in body]

    def deliver(self):
        """The inbox delivered into a session by the real bin/heimdall-inbox-deliver (UserPromptSubmit mode): the context it hands Claude."""
        r = subprocess.run([DELIVER, "prompt", "--repo", self.repo], input='{"session_id":"s1","cwd":"%s"}' % self.repo, capture_output=True,
                           text=True, env=self.env, timeout=60)
        try:
            return json.loads(r.stdout)["hookSpecificOutput"]["additionalContext"]
        except (ValueError, KeyError):
            return ""


def snapshot(s):
    return (s.files(), [r["text"] for r in s.inbox()])


# -- groups ------------------------------------------------------------------------------------------------------------------
def g_wire(s):
    p = s.phone
    first = p.state(timeout=30)
    caps = first["body"]["caps"] if first else []
    check("attach-v1" in caps and caps == sorted(caps) and {"resync", "controls-v1", "view-v1"} <= set(caps),
          "1a. hmd lists attach-v1 in its state frames' caps, sorted, beside the other caps", caps)
    ack, _ = p.resync(APP_CAPS)
    check(ack is not None and ack.get("ok") is True, "1b. the app's own resync (its caps do NOT include attach-v1) is acked", ack)
    clean = jpeg(entropy=40)
    b = begin(p, clean)
    check(b is not None and b.get("ok") is True and re.fullmatch(r"att-[0-9a-f]{8}", b.get("id", "")) is not None
          and b.get("result") == {"chunk_max": CHUNK} and set(b) <= {"ok", "of_seq", "id", "result"},
          "1c. attach-begin from a phone that never listed attach-v1 is taken: {id: att-<8 hex>, result: {chunk_max: 262144}} and nothing else", b)
    c = put(p, b["id"], 0, clean)
    check(c is not None and c.get("ok") is True and set(c) <= {"ok", "of_seq"}, "1d. attach-chunk is acked {ok} and nothing else", c)
    d = finish(p, b["id"], "wire check")
    check(d is not None and d.get("ok") is True and d.get("result") == {"queued": True} and isinstance(d.get("id"), str)
          and set(d) <= {"ok", "of_seq", "id", "result"}, "1e. attach-commit is acked {id: <inbox record id>, result: {queued: true}}", d)
    again = begin(p, clean, rid="a-replayed")
    twice = begin(p, clean, rid="a-replayed")
    check(again and twice and again.get("ok") and twice.get("ok") and twice.get("id") == again.get("id") and twice.get("dup") is True,
          "1f. a begin sent again with the same rid is answered with the same id and dup: true (hmd dedupes on rid)", (again, twice))
    put(p, again["id"], 0, clean)
    finish(p, again["id"])


def g_happy(s):
    p = s.phone
    p.resync(APP_CAPS)
    files0, inbox0 = s.files(), len(s.inbox())         # what an earlier group left: this group asserts on what it adds
    clean = jpeg(entropy=CHUNK + 1000)                 # two chunks: the first is a full 256 KiB, the size the app sends
    b, acks, c = upload(p, clean, "circle = the bug")
    check(b and b.get("ok") and len(acks) == 2 and all(a and a.get("ok") for a in acks) and c and c.get("ok"),
          "2a. begin, two chunks (256 KiB + the rest) and commit are all taken", (b, acks, c))
    stored = os.path.join(s.att, (b or {}).get("id", "?") + ".jpg")
    added = sorted(set(s.files()) - set(files0))
    check(added == [os.path.basename(stored)] and os.path.isfile(stored), "2b. the file is <attachments>/<id>.jpg and it is the only file the upload added", (added, s.files()))
    check(stat.S_IMODE(os.stat(stored).st_mode) == 0o600 and stat.S_IMODE(os.stat(s.att).st_mode) == 0o700,
          "2c. the file is mode 0600 and its directory 0700, under a 022 umask", (oct(os.stat(stored).st_mode), oct(os.stat(s.att).st_mode)))
    with open(stored, "rb") as f:
        saved = f.read()
    check(hashlib.sha256(saved).hexdigest() == hashlib.sha256(clean).hexdigest() and saved == clean,
          "2d. the app's metadata-free JPEG is stored byte for byte (its sha256 equals the fixture's)")
    texts = [r["text"] for r in s.inbox()][inbox0:]
    want = "[image attached: %s (1x1), phone note: circle = the bug]" % stored
    check(texts == [want], "2e. ONE inbox record: [image attached: <abs path> (<w>x<h>), phone note: <message>]", texts)
    context = s.deliver()
    check(MARKER in context and want in context and context.index(MARKER) < context.index(want),
          "2f. delivered into a session by bin/heimdall-inbox-deliver: the provenance marker, then the line with the path Claude can Read", context[:300])
    check(s.found_in(stored) == [] and s.found_in("app/attachments") == [], "2g. the path is in no ack, no state frame, no audit line, no event, no log",
          (s.found_in(stored), s.found_in("app/attachments")))
    lines = [a for a in s.audit() if str(a.get("action", "")).startswith("attach-")]
    check(len(lines) >= 4 and all(a.get("params") == {} for a in lines) and any(a["action"] == "attach-commit" and a["ok"] for a in lines),
          "2h. every attach command is audited (action, ok, no params)", lines[-2:])

    tagged = jpeg(metadata=True, entropy=64, w=640, h=480)
    b2, _acks, c2 = upload(p, tagged, None, w=1, h=1)
    saved2 = open(os.path.join(s.att, b2["id"] + ".jpg"), "rb").read() if b2 and b2.get("ok") else b""
    check(c2 and c2.get("ok") and not any(leak in saved2 for leak in LEAKS) and saved2 == jpeg(metadata=False, entropy=64, w=640, h=480),
          "2i. Exif+GPS, XMP, IPTC, a comment and a JFXX thumbnail are gone from the stored JPEG; the rest is byte for byte", saved2[:80])
    texts = [r["text"] for r in s.inbox()]
    check(texts and texts[-1].endswith(" (640x480)]") and "phone note" not in texts[-1],
          "2j. the size in the line comes from the file (640x480), not from the 1x1 the phone declared; no note, no 'phone note'", texts[-1:])

    tagged_png = png(extra=(png_chunk(b"eXIf", b"Exif\x00\x00GPSLatitude=12.97"), png_chunk(b"tEXt", b"Comment\x00taken at home"),
                            png_chunk(b"tIME", bytes(7)), png_chunk(b"iTXt", b"XML:com.adobe.xmp\x00\x00\x00\x00\x00<x:xmpmeta>home</x:xmpmeta>")))
    b3, _acks, c3 = upload(p, tagged_png, None, mime="image/png", name="shot.png")
    saved3 = open(os.path.join(s.att, b3["id"] + ".png"), "rb").read() if b3 and b3.get("ok") else b""
    check(c3 and c3.get("ok") and saved3 == png() and not any(leak in saved3 for leak in LEAKS),
          "2k. a PNG is stored as <id>.png with eXIf, text, time and XMP chunks removed (byte for byte the metadata-free PNG)", saved3[:60])

    outside = [(d, n) for d, _dirs, names in os.walk(s.world.tmp) for n in names if n in ("x", "passwd")]
    for hostile in ("../../x", "/etc/passwd", "..\\..\\x", "a\x00b/../../x"):
        b4, _acks, c4 = upload(p, jpeg(entropy=8), None, name=hostile)
        check(b4 and b4.get("ok") and c4 and c4.get("ok") and os.path.isfile(os.path.join(s.att, b4["id"] + ".jpg")),
              "2l. a client name that is a path (%r) is taken and never used: the file is still <id>.jpg" % hostile, (b4, c4))
    after = [(d, n) for d, _dirs, names in os.walk(s.world.tmp) for n in names if n in ("x", "passwd")]
    check(after == outside and all(re.fullmatch(r"att-[0-9a-f]{8}\.(jpg|png)", n) for n in s.files()),
          "2m. nothing named by a client exists anywhere in the tree; every file in the directory is att-<8 hex>.jpg|png", (after, s.files()))

    token = token_shaped()
    _b, _a, c5 = upload(p, jpeg(entropy=8), "see %s ok" % token)
    text = s.inbox()[-1]["text"]
    check(c5 and c5.get("ok") and "[secret removed]" in text and token not in text and s.found_in(token) == [],
          "2n. a secret-shaped token in the note is masked in the inbox text and appears nowhere else", text)
    _b, _a, c6 = upload(p, jpeg(entropy=8), "a\x1b]0;evil\x07b")
    check(c6 and c6.get("ok") and "\x1b" not in s.inbox()[-1]["text"] and "\x07" not in s.inbox()[-1]["text"],
          "2o. control and escape characters in the note are stripped like any inbox message", s.inbox()[-1]["text"])
    b7 = begin(p, jpeg(entropy=8))
    put(p, b7["id"], 0, jpeg(entropy=8))
    c7 = finish(p, b7["id"], "look", pin={"x": 0.42, "y": 0.61, "note": "wrong colour"})
    check(c7 and c7.get("ok") and s.inbox()[-1]["text"].endswith(", phone note: look; pin at (42%, 61%): wrong colour]"),
          "2p. the optional pin rides the line: pin at (42%, 61%): <note>", (c7, s.inbox()[-1]["text"]))


def g_max(s):
    p = s.phone
    p.resync(APP_CAPS)
    full = jpeg(entropy=MAX_BYTES - len(jpeg(entropy=0)))
    t0 = time.time()
    b8, acks8, c8 = upload(p, full, "max")
    check(len(full) == MAX_BYTES and b8 and b8.get("ok") and len(acks8) == 8 and all(a and a.get("ok") for a in acks8) and c8 and c8.get("ok")
          and os.path.getsize(os.path.join(s.att, b8["id"] + ".jpg")) == MAX_BYTES,
          "2q. a picture of exactly 2 MiB (8 chunks, the app's cap) goes through the real client and is stored whole (%.1fs)" % (time.time() - t0), (b8, c8))


def g_refuse(s):
    p = s.phone
    p.resync(APP_CAPS)
    small = jpeg(entropy=20)
    before = snapshot(s)
    for mime in ("image/svg+xml", "image/gif"):
        check(refused(begin(p, small, mime=mime), "bad-mime"), "3a. mime %s -> bad-mime" % mime)
    check(refused(begin(p, small, bytes=MAX_BYTES + 1, n=9), "too-large"), "3b. bytes over 2 MiB -> too-large")
    check(refused(begin(p, small, bytes=MAX_BYTES, n=9), "bad-params"), "3c. 9 chunks declared for 2 MiB -> bad-params")
    for label, over in (("an extra key", {"extra": 1}), ("bytes as a string", {"bytes": "5"}), ("n as a float", {"n": 1.5}),
                        ("no sha256", {"sha256": DROP}), ("an upper-case sha256", {"sha256": "A" * 64}), ("width 0", {"w": 0}),
                        ("width 8193", {"w": 8193}), ("no rid", {"rid": DROP}), ("a rid with a space", {"rid": "a b"}),
                        ("a 33-character rid", {"rid": "r" * 33}), ("a name that is not a string", {"name": 7}), ("an empty name", {"name": ""})):
        check(refused(begin(p, small, **over), "bad-params"), "3d. attach-begin with %s -> bad-params" % label)
    check(refused(put(p, "att-00000000", 0, b"x"), "unknown-id"), "3e. a chunk for an id hmd never issued -> unknown-id")
    check(refused(finish(p, "att-00000000"), "unknown-id"), "3f. a commit for an id hmd never issued -> unknown-id")
    for hostile in ("../../etc/passwd", "att-../../x", "ATT-00000000", ""):
        check(refused(put(p, hostile, 0, b"x"), "bad-params") and refused(finish(p, hostile), "bad-params"),
              "3g. an id that is not att-<8 hex> (%r) is bad-params on chunk and commit, never looked up" % hostile)
    two = jpeg(entropy=CHUNK + 10)
    b = begin(p, two)
    check(b and b.get("ok"), "3h. (a two-chunk upload to try chunks against)", b)
    pieces = parts(two)
    check(refused(put(p, b["id"], 0, pieces[0][:100]), "bad-params"), "3i. a first chunk that is not 256 KiB -> bad-params")
    check(refused(put(p, b["id"], 1, pieces[1] + b"x"), "bad-params"), "3j. a last chunk that is not the remainder -> bad-params")
    check(refused(put(p, b["id"], 2, b"x"), "bad-params") and refused(put(p, b["id"], -1, b"x"), "bad-params"), "3k. idx past n, or negative -> bad-params")
    check(refused(put(p, b["id"], 0, b"", b64="A" * (349528 + 4)), "too-large"), "3l. a chunk whose base64 is over 349528 characters -> too-large")
    check(refused(put(p, b["id"], 0, b"", b64="!!!!"), "bad-params") and refused(put(p, b["id"], 0, b"", b64=""), "bad-params"),
          "3m. base64 that is not base64, or empty -> bad-params")
    check(refused(finish(p, b["id"]), "incomplete"), "3n. a commit with no chunk sent -> incomplete")
    r1 = put(p, b["id"], 1, pieces[1], rid="c-replayed")
    r2 = put(p, b["id"], 1, pieces[1], rid="c-replayed")
    check(r1 and r1.get("ok") and r2 and r2.get("ok") and r2.get("dup") is True, "3o. a chunk sent again with the same rid -> ok, dup: true")
    r3 = put(p, b["id"], 1, pieces[1])
    check(r3 and r3.get("ok") and "dup" not in r3, "3p. the same bytes at the same idx under a new rid -> ok (idempotent by idx)")
    check(refused(put(p, b["id"], 1, bytes(len(pieces[1]))), "bad-params"), "3q. other bytes at an idx already held -> bad-params")
    check(refused(finish(p, b["id"]), "incomplete"), "3r. one chunk of two -> incomplete, and the upload stays open")
    put(p, b["id"], 0, pieces[0])                                          # out of order: idx 1 went first
    long_note = finish(p, b["id"], "n" * 2001)
    check(refused(long_note, "too-long"), "3s. a note over 2000 characters -> too-long")
    bad_pin = finish(p, b["id"], None, pin={"x": 1.5, "y": 0.5})
    check(refused(bad_pin, "bad-params") and refused(finish(p, b["id"], None, pin={"x": 0.5, "y": 0.5, "z": 1}), "bad-params")
          and refused(finish(p, b["id"], None, pin="here"), "bad-params"), "3t. a pin outside [0,1], with an extra key or not an object -> bad-params")
    check(snapshot(s) == before, "3u. nothing was stored and nothing queued by any refusal above", (snapshot(s), before))
    ok = finish(p, b["id"], None, rid="m-replayed")
    check(ok and ok.get("ok") and len(s.files()) == len(before[0]) + 1, "3v. the open upload survived those refusals; chunks out of order, then commit -> ok", ok)
    again = finish(p, b["id"], None, rid="m-replayed")
    check(again and again.get("ok") and again.get("dup") is True and len(s.inbox()) == len(before[1]) + 1,
          "3w. the commit sent again with the same rid -> ok, dup: true, no second inbox record")
    check(refused(finish(p, b["id"]), "unknown-id"), "3x. a commit for an upload that is already finished -> unknown-id")

    before = snapshot(s)
    png_as_jpeg = png()
    b, _acks, c = upload(p, png_as_jpeg, None)
    check(refused(c, "magic-mismatch"), "4a. PNG bytes declared image/jpeg -> magic-mismatch at commit")
    b, _acks, c = upload(p, small, None, sha256="0" * 64)
    check(refused(c, "sha-mismatch"), "4b. a declared sha256 that is not the file's -> sha-mismatch")
    b = begin(p, small)
    flipped = bytearray(small)
    flipped[-5] ^= 0xFF
    put(p, b["id"], 0, bytes(flipped))
    check(refused(finish(p, b["id"]), "sha-mismatch"), "4c. a chunk corrupted on the way -> sha-mismatch")
    cut = jpeg(entropy=20)[:-2]
    _b, _acks, c = upload(p, cut, None)
    check(refused(c, "bad-mime"), "4d. a JPEG cut off before its end-of-image marker (sha matches) -> bad-mime: what cannot be cleaned is not kept")
    bad_crc = bytearray(png())
    bad_crc[40] ^= 0xFF
    _b, _acks, c = upload(p, bytes(bad_crc), None, mime="image/png")
    check(refused(c, "bad-mime"), "4e. a PNG with a bad chunk checksum -> bad-mime")
    _b, _acks, c = upload(p, jpeg(entropy=20, w=9000, h=9000), None)
    check(refused(c, "too-large"), "4f. a JPEG whose own frame header says 9000x9000 -> too-large (the declared 1x1 is not trusted)")
    check(snapshot(s) == before, "4g. nothing was stored and nothing queued by any of those", (snapshot(s), before))
    _b, _acks, c = upload(p, jpeg(entropy=20), "n" * 1990)
    check(refused(c, "too-long") and snapshot(s) == before,
          "4h. a note that fits the 2000-character field but not the inbox record once the path is added -> too-long, and the file already written is removed again",
          (c, snapshot(s), before))


def g_gate(s):
    p = s.phone
    p.resync(APP_CAPS)
    small = jpeg(entropy=20)
    switch = os.path.join(s.repo, ".heimdall", "app", "controls-disabled")
    os.makedirs(os.path.dirname(switch), exist_ok=True)
    open(switch, "w").write("off\n")
    before = snapshot(s)
    check(refused(begin(p, small), "controls-off") and refused(put(p, "att-00000000", 0, b"x"), "controls-off")
          and refused(finish(p, "att-00000000"), "controls-off"), "5a. the kill switch (hmd app controls off) refuses all three commands: controls-off")
    os.unlink(switch)
    b, _acks, c = upload(p, small, None)
    check(b and b.get("ok") and c and c.get("ok") and snapshot(s)[0] != before[0], "5b. controls on again: the same upload goes through", (b, c))

    real, aside, outside = s.att, s.att + ".real", os.path.join(s.world.tmp, "outside-" + s.name)
    os.makedirs(outside)
    os.rename(real, aside)
    os.symlink(outside, real)
    b, _acks, c = upload(p, small, None)
    check(refused(c, "write-failed") and os.listdir(outside) == [], "5c. an attachments directory that is a symlink is refused (write-failed), nothing written through it", (c, os.listdir(outside)))
    os.unlink(real)
    os.rename(aside, real)

    probe = subprocess.run([sys.executable, "-c",
                            "import importlib.util as u, sys; s = u.spec_from_file_location('c', sys.argv[1]); c = u.module_from_spec(s); s.loader.exec_module(c); "
                            "print(c.dispatch(sys.argv[2], 'attach-begin', {'rid': 'a-1', 'name': 'x', 'mime': 'image/jpeg', 'bytes': 1, 'w': 1, 'h': 1, 'n': 1, "
                            "'sha256': '0' * 64}, transport='direct')[:2])", CONTROLS, s.repo], capture_output=True, text=True, env=s.env)
    check(probe.stdout.strip() == "(False, 'not-implemented')", "5d. the direct route (no phone caps) answers not-implemented: attach is relay only", probe.stdout + probe.stderr)

    listed = lambda st: "attach-begin" in ((st.get("controls") or {}).get("actions") or [])
    mark = p.mark()
    check(not any(listed(f["body"]["state"]) for f in p.frames if f["type"] == "state"), "5e. with no relay session recorded, state.controls.actions lists no attach action")
    with open(os.path.join(s.repo, ".heimdall", "app", "connect.json"), "w") as f:
        json.dump({"mode": "relay", "pid_ui": os.getpid(), "pid_client": s.client.pid}, f)
    p.resync(APP_CAPS)
    frame = p.state(listed, since=mark, timeout=30)
    check(frame is not None and {"attach-begin", "attach-chunk", "attach-commit"} <= set(frame["body"]["state"]["controls"]["actions"]),
          "5f. with a live relay client in connect.json, state.controls.actions lists attach-begin, attach-chunk and attach-commit")
    os.unlink(os.path.join(s.repo, ".heimdall", "app", "connect.json"))

    expiry = subprocess.run([sys.executable, "-c",
                             "import importlib.util as u, sys, time\n"
                             "s = u.spec_from_file_location('c', sys.argv[1]); c = u.module_from_spec(s); s.loader.exec_module(c)\n"
                             "a = c._sibling('companion_attach')\n"
                             "begin = {'rid': 'a-1', 'name': 'x', 'mime': 'image/jpeg', 'bytes': 1, 'w': 1, 'h': 1, 'n': 1, 'sha256': '0' * 64}\n"
                             "ok, detail, extra = c.dispatch(sys.argv[2], 'attach-begin', begin, caps=frozenset())\n"
                             "real = time.monotonic\n"
                             "a.time = type('T', (), {'monotonic': staticmethod(lambda: real() + 601), 'time': time.time})\n"
                             "print(ok, c.dispatch(sys.argv[2], 'attach-chunk', {'rid': 'c-1', 'id': extra['id'], 'idx': 0, 'b64': 'AA=='}, caps=frozenset())[:2])\n",
                             CONTROLS, s.repo], capture_output=True, text=True, env=s.env)
    check(expiry.stdout.strip() == "True (False, 'unknown-id')",
          "5g. an upload left open for 10 minutes is forgotten: its next chunk is unknown-id (begin worked for a phone whose caps were empty)", expiry.stdout + expiry.stderr)


def seed_stale(s):
    os.makedirs(s.att, mode=0o700, exist_ok=True)
    stale = os.path.join(s.att, "att-0badf00d.jpg")
    open(stale, "wb").write(jpeg())
    old = time.time() - 25 * 3600
    os.utime(stale, (old, old))
    return stale


def g_keep(s):
    p = s.phone
    p.resync(APP_CAPS)
    check(not os.path.exists(os.path.join(s.att, "att-0badf00d.jpg")), "6a. a picture 25 hours old is removed when the relay client starts")
    now = time.time()
    for i in range(1, 23):
        path = os.path.join(s.att, "att-1000%04d.jpg" % i)
        open(path, "wb").write(jpeg())
        os.utime(path, (now - 60 * i, now - 60 * i))
    old = os.path.join(s.att, "att-2000ffff.png")
    open(old, "wb").write(png())
    os.utime(old, (now - 25 * 3600, now - 25 * 3600))
    canary = os.path.join(s.world.tmp, "canary-" + s.name)
    open(canary, "w").write("keep me")
    os.symlink(canary, os.path.join(s.att, "att-deadbeef.jpg"))
    open(os.path.join(s.att, "notes.txt"), "w").write("not ours")
    b, _acks, c = upload(p, jpeg(entropy=30), None)
    finals = [n for n in s.files() if re.fullmatch(r"att-[0-9a-f]{8}\.(jpg|png)", n)]
    check(c and c.get("ok") and len(finals) == 20 and b["id"] + ".jpg" in finals, "6b. after a commit exactly the 20 newest pictures remain, the new one among them", (len(finals), b, c))
    check("att-1000" "0022.jpg" not in finals and "att-2000ffff.png" not in finals, "6c. the oldest and the one past 24 hours are the ones removed")
    check("att-deadbeef.jpg" not in s.files() and open(canary).read() == "keep me", "6d. a symlink in the directory is removed as a link: what it pointed at is untouched")
    check(open(os.path.join(s.att, "notes.txt")).read() == "not ours", "6e. a file this module did not make is never touched")


def g_maxws(world, client):
    """The same 2 MiB picture over the WebSocket leg, the one the hosted relay speaks."""
    s = Stack(world, client, "maxws", ws=True)
    check(s.start(), "9a. (setup: a real relay client on a relay that upgrades hmd's leg to a WebSocket)")
    try:
        with open(s.out, encoding="utf-8") as f:
            check('"transport":"ws"' in f.read(), "9b. hmd's stream really is a WebSocket in this stack")
        g_max(s)
    finally:
        s.stop()


def g_off(world, client):
    s = Stack(world, client, "off", env={"HMD_ATTACH": "0"})
    check(s.start(), "7a. (setup: a real relay client started with HMD_ATTACH=0)")
    p = s.phone
    first = p.state(timeout=30)
    caps = first["body"]["caps"] if first else []
    check(first is not None and "attach-v1" not in caps and "resync" in caps and "controls-v1" in caps,
          "7b. with HMD_ATTACH=0 hmd does not list attach-v1 (the other caps stay)", caps)
    p.resync(APP_CAPS)
    small = jpeg(entropy=20)
    check(refused(begin(p, small), "not-implemented") and refused(put(p, "att-00000000", 0, b"x"), "not-implemented")
          and refused(finish(p, "att-00000000"), "not-implemented"),
          "7c. every attach command is refused not-implemented while the cap is not listed: nothing takes a picture from a phone that was not offered")
    check(not os.path.exists(s.att) and s.inbox() == [], "7d. no directory was created and nothing was queued")
    s.stop()


def g_rate(world, client):
    s = Stack(world, client, "rate")
    check(s.start(), "8a. (setup: a real relay client for the limits)")
    p = s.phone
    p.resync(APP_CAPS)
    small = jpeg(entropy=20)
    rows = [{"rid": rid("a-"), "name": "x.jpg", "mime": "image/jpeg", "bytes": len(small), "w": 1, "h": 1, "n": 1,
             "sha256": hashlib.sha256(small).hexdigest()} for _ in range(40)]
    seqs = [p.command({"action": "attach-begin", "params": row}) for row in rows]      # sealed first, answered back to back: one burst
    answers = [p.ack(seq) for seq in seqs]
    codes = [("ok" if a and a.get("ok") else (a or {}).get("detail")) for a in answers]
    check(codes[:3] == ["ok"] * 3 and codes[3] == "too-many", "8b. three uploads may be open at once: the fourth begin is too-many", codes[:6])
    limited = [a for a in answers if a and a.get("detail") == "rate-limited"]
    check(limited and limited[0].get("retry_after_s", 0) >= 1 and codes.index("rate-limited") >= 16 and set(codes[3:codes.index("rate-limited")]) == {"too-many"}
          and "ok" not in codes[3:], "8c. a burst past 16 begins is rate-limited, with retry_after_s (the ones before it are too-many, none is taken)", codes)
    s.stop()


MAIN = {"wire": g_wire, "happy": g_happy, "max": g_max, "refuse": g_refuse, "gate": g_gate, "keep": g_keep}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--client", default=os.path.join(REPO, "bin", "heimdall-relay-client"))
    ap.add_argument("--groups", default=",".join(GROUPS))
    args = ap.parse_args()
    wanted = [g for g in GROUPS if g in args.groups.split(",")]
    os.umask(0o022)
    world = World()
    try:
        chosen = [g for g in wanted if g in MAIN]
        if chosen:
            s = Stack(world, args.client, "main")
            s.world = world
            if "keep" in chosen:
                seed_stale(s)
            ok = s.start()
            check(ok, "setup: the real relay client paired with the fake phone through the fake relay")
            try:
                if ok:
                    for name in chosen:
                        print("-- group %s" % name, flush=True)
                        MAIN[name](s)
            finally:
                s.stop()
        for name, fn in (("off", g_off), ("rate", g_rate), ("maxws", g_maxws)):
            if name in wanted:
                print("-- group %s" % name, flush=True)
                fn(world, args.client)
    finally:
        world.cleanup()
    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

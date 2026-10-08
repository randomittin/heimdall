#!/usr/bin/env python3
"""companion_attach.py -- `attach-v1`: a picture from the paired phone, saved on this laptop and handed to the running Claude Code
session as data (hmdapp docs/HANDOFF-TO-HEIMDALL-cursor-parity.md CP6, asked for again in docs/HANDOFF-TO-HEIMDALL-chat-replies.md
section A; the phone half is hmdapp's src/attach, whose wire this matches key for key).

WIRE (relay only). hmd lists `attach-v1` in every state frame's caps (the relay client asks enabled()); the phone then draws its attach
control and seals three actions of class `safe-write`, registered into bin/lib/companion_ui_controls.py by register_actions(kit), so the
kill switch (`hmd app controls off`), the audit line, the `rid` de-duplication, the rate buckets and `state.controls.actions` are the
dispatcher's own. Command `{"action":A,"params":{"rid":..,...}}`, ack `{"ok":..,"of_seq":N[,"detail":..][,"id":..][,"result":{..}][,"dup":true]}`:

    attach-begin   {name, mime, bytes, w, h, n, sha256}   ok {"id":"att-<8 hex>","result":{"chunk_max":262144}}
    attach-chunk   {id, idx, b64}                         ok {}            idempotent by idx, any order
    attach-commit  {id, message?, pin?{x, y, note?}}      ok {"id":<inbox record id>,"result":{"queued":true}}

The shipped app lists no `attach-v1` in ITS caps (hmdapp src/transport/resync.ts APP_CAPS): it gates its control on hmd's list alone, so
nothing here may require the phone to list it. Relay only: a command that arrives without the phone's caps (the direct `POST /api/control`,
whose body cap is 4096 bytes) is `not-implemented`, exactly what an hmd without the feature answers. So is every command while the
operator runs hmd with HMD_ATTACH=0 (exactly `0`; HMD_PUSH=0's precedent): the cap is then not listed either.

REFUSALS (`detail`): bad-params, bad-mime (not image/jpeg or image/png, or a file whose structure cannot be cleaned), magic-mismatch,
too-large, too-long (a note the inbox record cannot hold), sha-mismatch, incomplete (a chunk is missing: the upload stays open so the
phone can send them all again), unknown-id, too-many (3 open uploads), rate-limited (dispatcher), controls-off (dispatcher),
not-implemented, write-failed, inbox-full, inbox-unavailable.

UNTRUSTED BYTES. Nothing touches the disk until a commit has verified the whole file: chunks wait in memory (at most 3 uploads of 2 MiB,
10 minutes), each of exactly the size its index implies (256 KiB, the last one the rest), and the declared sha256 of the reassembled
bytes must match. The magic bytes must match the declared type; JPEG and PNG are then rewritten by a strict byte-level whitelist (no
imaging library, no decoding, no guessing: anything that does not parse is refused): JPEG keeps its frame, tables and scans, a bare JFIF
header, an ICC profile and Adobe's colour flag, and loses Exif, XMP, IPTC, comments, thumbnails and everything after the end-of-image
marker; PNG keeps its critical chunks and the colour ones and loses eXIf, text, time and every other chunk. The width and height Claude is
told come from the cleaned file itself, not from the phone. `name` is a label for the phone: it is never kept and never part of a path.

STORAGE AND HANDOFF. <repo>/.heimdall/app/attachments/<id>.jpg|png, the directory 0700 and the file 0600 whatever the umask, written to
a `.part` file and renamed, the name made here and never from the client, the directory refused when it is a link or not ours. The 20
newest files stay and none outlives 24 hours: swept after every commit and when the relay client starts. One inbox record is queued
(companion_ui_inbox.append, so the same control-character strip, secret scan, 2000-character limit and capacity as `send-message`):
`[image attached: <abs path> (<w>x<h>), phone note: <message>; pin at (42%, 61%): <note>]`. A secret-shaped span of the note is masked
(`[secret removed]`) before the append refuses on it. The provenance marker is added when the record is DELIVERED
(bin/heimdall-inbox-deliver wraps every record in INBOX_PROVENANCE_MARKER and a fence), so Claude reads the marker, the line and the
path, and can `Read` the picture; the record is never given the marker twice. The path is the one absolute path that reaches Claude:
no ack, state frame, audit line or event carries it (the relay's redaction profile would also cut it to its repo-relative form).

Stdlib only. Registered into bin/lib/companion_ui_controls.py by its register_actions(kit) hook; the relay client takes its instance from
CONTROLS._sibling (open uploads live in this module's memory, so ONE instance per process).
"""
import base64
import binascii
import collections
import hashlib
import json
import math
import os
import re
import secrets
import stat
import threading
import time
import zlib
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))

CAP_ATTACH = "attach-v1"
OFF_ENV = "HMD_ATTACH"
BEGIN, CHUNK, COMMIT = "attach-begin", "attach-chunk", "attach-commit"
ATTACH_REL = os.path.join(".heimdall", "app", "attachments")
CONNECT_REL = os.path.join(".heimdall", "app", "connect.json")

CHUNK_MAX = 262144                           # raw bytes of a chunk; its base64 is 349528 characters, far inside the 1 MiB envelope
MAX_BYTES = 2 * 1024 * 1024
MAX_CHUNKS = MAX_BYTES // CHUNK_MAX
MAX_DIM = 8192
MAX_NAME_CHARS = 255
MAX_MESSAGE_CHARS = 2000                     # the app's own limit, and the inbox record's
MAX_PIN_NOTE_CHARS = 200
MAX_OPEN = 3                                 # uploads begun and not finished, per repo
OPEN_TTL_S = 600.0
KEEP = 20
KEEP_TTL_S = 24 * 3600
B64_CHUNK_CHARS = 4 * ((CHUNK_MAX + 2) // 3)
COMMAND_MAX = {BEGIN: 4096, CHUNK: B64_CHUNK_CHARS + 512, COMMIT: 32768}   # whole-command limits (dispatcher policy max_bytes)
RATE = {BEGIN: (16, 1.0), CHUNK: (64, 5.0), COMMIT: (16, 1.0)}   # (burst, per second): four four-image messages in a row fit the burst; what
# really bounds the work is MAX_OPEN, KEEP and the inbox's own capacity, so this only stops a runaway loop
MASK = "[secret removed]"

RID_RE = re.compile(r"[A-Za-z0-9_-]{1,32}")
ID_RE = re.compile(r"att-[0-9a-f]{8}")
SHA_RE = re.compile(r"[0-9a-f]{64}")
FILE_RE = re.compile(r"att-[0-9a-f]{8}\.(?:jpg|png)(?:\.part)?")
_TYPES = {"image/jpeg": (".jpg", b"\xff\xd8\xff"), "image/png": (".png", b"\x89PNG\r\n\x1a\n")}

_MODULES = {}
_KIT = None                                  # set by register_actions: the dispatcher that loaded THIS copy of the module
_LOCK = threading.Lock()
_OPEN = {}                                   # root -> OrderedDict(att id -> _Upload)


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


def enabled():
    """Registered with the dispatcher and not switched off (HMD_ATTACH=0): what the relay client asks before it lists `attach-v1`."""
    return _KIT is not None and os.environ.get(OFF_ENV) != "0"


def _relay_live(root):
    """True while <repo>/.heimdall/app/connect.json names a running relay client: attach has no other way in."""
    try:
        with open(os.path.join(root, CONNECT_REL), "rb") as f:
            pid = json.loads(f.read(65536).decode("utf-8")).get("pid_client")
        if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
            return False
        os.kill(pid, 0)
    except PermissionError:
        return True
    except (OSError, ValueError, AttributeError):
        return False
    return True


def usable(root):
    """Whether `state.controls.actions` lists the three actions: on, and a relay session is live (so a plain `hmd ui` lists nothing new)."""
    return enabled() and _relay_live(root)


def _refuse(code):
    return _KIT.Refusal(code)


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


# -- params ------------------------------------------------------------------------------------------------------------
def _begin_fields(body):
    name, mime, nbytes, w, h, n, sha = (body[k] for k in ("name", "mime", "bytes", "w", "h", "n", "sha256"))
    if not (isinstance(name, str) and 1 <= len(name) <= MAX_NAME_CHARS and isinstance(mime, str) and isinstance(sha, str)
            and all(_is_int(v) for v in (nbytes, w, h, n))):
        raise _refuse("bad-params")
    if mime not in _TYPES:
        raise _refuse("bad-mime")
    if nbytes > MAX_BYTES:
        raise _refuse("too-large")
    if not (nbytes >= 1 and n == -(-nbytes // CHUNK_MAX) and 1 <= w <= MAX_DIM and 1 <= h <= MAX_DIM and SHA_RE.fullmatch(sha)):
        raise _refuse("bad-params")
    return {"mime": mime, "bytes": nbytes, "n": n, "sha256": sha}     # `name` is dropped: a label for the phone, never kept


def _chunk_fields(body):
    att_id, idx, b64 = body["id"], body["idx"], body["b64"]
    if not (isinstance(att_id, str) and ID_RE.fullmatch(att_id) and _is_int(idx) and 0 <= idx < MAX_CHUNKS and isinstance(b64, str)):
        raise _refuse("bad-params")
    if len(b64) > B64_CHUNK_CHARS:
        raise _refuse("too-large")
    try:
        data = base64.b64decode(b64, validate=True) if b64.isascii() else b""
    except (binascii.Error, ValueError):
        data = b""
    if not data:
        raise _refuse("bad-params")
    return {"id": att_id, "idx": idx, "data": data}


def _unit(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= 1


def _pin_of(pin):
    if pin is None:
        return None
    if not (isinstance(pin, dict) and {"x", "y"} <= set(pin) <= {"x", "y", "note"} and _unit(pin["x"]) and _unit(pin["y"])):
        raise _refuse("bad-params")
    note = pin.get("note", "")
    if not (isinstance(note, str) and len(note) <= MAX_PIN_NOTE_CHARS):
        raise _refuse("bad-params")
    return {"x": pin["x"], "y": pin["y"], "note": note}


def _commit_fields(body):
    att_id, message = body["id"], body.get("message", "")
    if not (isinstance(att_id, str) and ID_RE.fullmatch(att_id) and isinstance(message, str)):
        raise _refuse("bad-params")
    if len(message) > MAX_MESSAGE_CHARS:
        raise _refuse("too-long")
    return {"id": att_id, "message": message, "pin": _pin_of(body.get("pin"))}


# -- JPEG and PNG: a strict whitelist rewrite, no decoding ---------------------------------------------------------------
_JPEG_SOF = frozenset(range(0xC0, 0xD0)) - {0xC4, 0xC8, 0xCC}
_JPEG_STRUCTURAL = _JPEG_SOF | {0xC4, 0xCC, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF}   # frame, tables, scan, restart interval
_PNG_SIGNATURE = _TYPES["image/png"][1]
_PNG_KEEP = frozenset((b"IHDR", b"PLTE", b"IDAT", b"IEND", b"tRNS", b"gAMA", b"cHRM", b"sRGB", b"iCCP", b"sBIT", b"bKGD", b"hIST", b"pHYs"))


def _jpeg_keep(marker, data, start, end):
    """Whether the segment whose payload is data[start:end] survives. A whitelist: an APP segment lives only as a bare JFIF header (no
    thumbnail), an ICC colour profile or Adobe's colour flag; Exif, XMP, IPTC, every other APPn, comments and the reserved JPGn do not."""
    if marker == 0xE0:
        return end - start == 14 and data[start:start + 5] == b"JFIF\x00" and data[end - 2:end] == b"\x00\x00"
    if marker == 0xE2:
        return data[start:start + 12] == b"ICC_PROFILE\x00"
    if marker == 0xEE:
        return end - start == 12 and data[start:start + 5] == b"Adobe"
    return marker in _JPEG_STRUCTURAL


def _strip_jpeg(data):
    """(cleaned bytes, (width, height)) or ValueError. Pixel data is copied byte for byte; whatever follows the end-of-image marker (a
    phone appends whole extra images there) is dropped."""
    n = len(data)
    if n < 4 or data[0] != 0xFF or data[1] != 0xD8:
        raise ValueError("not a JPEG")
    out, pos, dims, scans = [data[:2]], 2, None, 0
    while pos < n:
        if data[pos] != 0xFF:
            raise ValueError("a marker was expected")
        while pos + 1 < n and data[pos + 1] == 0xFF:      # fill bytes ahead of a marker
            pos += 1
        if pos + 1 >= n:
            raise ValueError("cut off")
        marker = data[pos + 1]
        if marker == 0xD9:
            if dims is None or not scans:
                raise ValueError("no image data")
            out.append(b"\xff\xd9")
            return b"".join(out), dims
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:      # standalone markers carry no length
            out.append(data[pos:pos + 2])
            pos += 2
            continue
        if marker in (0x00, 0xD8) or pos + 4 > n:
            raise ValueError("misplaced marker or cut off")
        end = pos + 2 + ((data[pos + 2] << 8) | data[pos + 3])
        if end < pos + 4 or end > n:
            raise ValueError("bad segment length")
        if marker in _JPEG_SOF:
            if dims is not None or end - pos < 10:
                raise ValueError("bad frame header")
            dims = ((data[pos + 7] << 8) | data[pos + 8], (data[pos + 5] << 8) | data[pos + 6])
            if not all(dims):
                raise ValueError("no size")
        if _jpeg_keep(marker, data, pos + 4, end):
            out.append(data[pos:end])
        pos = end
        if marker == 0xDA:                                # entropy-coded data runs to the next marker that is not a stuffed 0xFF00 or a restart
            scans += 1
            nxt = pos
            while nxt < n - 1 and not (data[nxt] == 0xFF and data[nxt + 1] != 0x00 and not 0xD0 <= data[nxt + 1] <= 0xD7):
                nxt += 1
            out.append(data[pos:nxt])
            pos = nxt
    raise ValueError("no end of image")


def _strip_png(data):
    """(cleaned bytes, (width, height)) or ValueError. Every chunk's CRC is checked, kept or not; chunks past IEND are dropped."""
    n = len(data)
    if data[:8] != _PNG_SIGNATURE:
        raise ValueError("not a PNG")
    out, pos, dims, idat = [data[:8]], 8, None, False
    while pos + 12 <= n:
        length = int.from_bytes(data[pos:pos + 4], "big")
        kind = data[pos + 4:pos + 8]
        end = pos + 12 + length
        if length > 0x7FFFFFFF or end > n or not kind.isalpha():
            raise ValueError("bad chunk")
        if zlib.crc32(data[pos + 4:end - 4]) != int.from_bytes(data[end - 4:end], "big"):
            raise ValueError("bad checksum")
        if dims is None:
            if kind != b"IHDR" or length != 13:
                raise ValueError("no header")
            dims = (int.from_bytes(data[pos + 8:pos + 12], "big"), int.from_bytes(data[pos + 12:pos + 16], "big"))
            if not all(dims):
                raise ValueError("no size")
        elif kind == b"IHDR":
            raise ValueError("a second header")
        idat = idat or kind == b"IDAT"
        if kind in _PNG_KEEP:
            out.append(data[pos:end])
        pos = end
        if kind == b"IEND":
            if not idat or length:
                raise ValueError("no image data")
            return b"".join(out), dims
    raise ValueError("no end chunk")


# -- the files -----------------------------------------------------------------------------------------------------------
def _private_dir(path):
    os.makedirs(path, exist_ok=True)
    os.chmod(path, 0o700)


def _attachments_dir(root):
    """<repo>/.heimdall/app/attachments, 0700 on every touch; refused when it is a link or not ours (the check comes before any chmod)."""
    _private_dir(os.path.join(root, ".heimdall", "app"))
    path = os.path.join(root, ATTACH_REL)
    os.makedirs(path, mode=0o700, exist_ok=True)
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
        raise OSError("%s is not a directory of ours" % ATTACH_REL)
    os.chmod(path, 0o700)
    return path


def _drop(path):
    try:
        os.unlink(path)
    except OSError:
        return 0
    return 1


def _store(root, name, data):
    """Write `data` as <attachments>/<name> (0600, never replacing a file) and return its absolute path. `name` is made here."""
    final = os.path.join(os.path.realpath(_attachments_dir(root)), name)
    if os.path.lexists(final):
        raise FileExistsError(name)
    tmp = final + ".part"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        _drop(tmp)
        raise
    os.close(fd)
    try:
        os.replace(tmp, final)
    except OSError:
        _drop(tmp)
        raise
    return final


def sweep(root, now=None):
    """Delete pictures past their 24 h and all but the 20 newest, and `.part` files a crash left; only names this module makes, a link
    removed as a link at once (this module only makes regular files). Best effort: -> how many were removed, never raises."""
    now = time.time() if now is None else now
    removed, finals = 0, []
    try:
        with os.scandir(os.path.join(root, ATTACH_REL)) as entries:
            for entry in entries:
                if not FILE_RE.fullmatch(entry.name):
                    continue
                try:
                    st = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if not stat.S_ISREG(st.st_mode):               # this module makes regular files only: a link under its names is a stranger's
                    removed += _drop(entry.path)
                    continue
                mtime = st.st_mtime
                if entry.name.endswith(".part"):
                    if now - mtime >= OPEN_TTL_S:
                        removed += _drop(entry.path)
                else:
                    finals.append((mtime, entry.name, entry.path))
    except OSError:
        return removed
    finals.sort(reverse=True)
    for rank, (mtime, _name, path) in enumerate(finals):
        if rank >= KEEP or now - mtime >= KEEP_TTL_S:
            removed += _drop(path)
    return removed


# -- the commands --------------------------------------------------------------------------------------------------------
class _Upload:
    __slots__ = ("id", "mime", "nbytes", "n", "sha", "chunks", "opened")

    def __init__(self, att_id, fields, now):
        self.id, self.mime, self.nbytes, self.n, self.sha = att_id, fields["mime"], fields["bytes"], fields["n"], fields["sha256"]
        self.chunks = {}
        self.opened = now

    def size_of(self, idx):
        return CHUNK_MAX if idx < self.n - 1 else self.nbytes - (self.n - 1) * CHUNK_MAX


def _find(root, att_id):
    """The open upload `att_id` of this repo, or None (unknown, or older than OPEN_TTL_S, which is dropped). The caller holds _LOCK."""
    opened = _OPEN.get(root)
    up = opened.get(att_id) if opened else None
    if up is not None and time.monotonic() - up.opened >= OPEN_TTL_S:
        del opened[att_id]
        return None
    return up


def _do_begin(root, fields, ctx):
    with _LOCK:
        opened = _OPEN.setdefault(root, collections.OrderedDict())
        now = time.monotonic()
        for stale in [i for i, up in opened.items() if now - up.opened >= OPEN_TTL_S]:
            del opened[stale]
        if len(opened) >= MAX_OPEN:
            return False, "too-many", {}
        att_id = "att-" + secrets.token_hex(4)
        while att_id in opened:
            att_id = "att-" + secrets.token_hex(4)
        opened[att_id] = _Upload(att_id, fields, now)
    return True, None, {"id": att_id, "result": {"chunk_max": CHUNK_MAX}}


def _do_chunk(root, fields, ctx):
    idx, data = fields["idx"], fields["data"]
    with _LOCK:
        up = _find(root, fields["id"])
        if up is None:
            return False, "unknown-id", {}
        if idx >= up.n or len(data) != up.size_of(idx):
            return False, "bad-params", {}
        held = up.chunks.get(idx)
        if held is not None:                              # a chunk sent again: the same bytes are a no-op, other bytes are refused
            return (True, None, {}) if held == data else (False, "bad-params", {})
        up.chunks[idx] = data
    return True, None, {}


def _mask(inbox, text):
    """The note with every span the inbox's own secret scan would refuse replaced: the same patterns, taken from the inbox module."""
    for rx in inbox._SECRET_RES:
        text = rx.sub(MASK, text)
    return text


def _compose(path, width, height, message, pin):
    text = "[image attached: %s (%dx%d)" % (path, width, height)
    if message:
        text += ", phone note: " + message
    if pin is not None:
        text += "; pin at (%d%%, %d%%)" % (round(pin["x"] * 100), round(pin["y"] * 100))
        if pin["note"]:
            text += ": " + pin["note"]
    return text + "]"


def _do_commit(root, fields, ctx):
    inbox = _sibling("companion_ui_inbox")
    if inbox is None:
        return False, "inbox-unavailable", {}
    with _LOCK:
        up = _find(root, fields["id"])
        if up is None:
            return False, "unknown-id", {}
        if len(up.chunks) != up.n:
            return False, "incomplete", {}                 # stays open: the phone sends the chunks again, then commits
        del _OPEN[root][up.id]                             # from here the upload is spent, whatever the outcome
        data = b"".join(up.chunks[i] for i in range(up.n))
    if hashlib.sha256(data).hexdigest() != up.sha:
        return False, "sha-mismatch", {}
    ext, magic = _TYPES[up.mime]
    if not data.startswith(magic):
        return False, "magic-mismatch", {}
    try:
        clean, (width, height) = (_strip_jpeg if ext == ".jpg" else _strip_png)(data)
    except ValueError:
        return False, "bad-mime", {}
    if width > MAX_DIM or height > MAX_DIM:
        return False, "too-large", {}
    try:
        path = _store(root, up.id + ext, clean)
    except OSError:
        return False, "write-failed", {}
    pin = fields["pin"]
    if pin is not None:
        pin = dict(pin, note=_mask(inbox, pin["note"]))
    try:
        record = inbox.append(root, _compose(path, width, height, _mask(inbox, fields["message"]), pin))
    except inbox.InboxError as e:
        _drop(path)
        return False, e.code, {}
    except OSError:
        _drop(path)
        return False, "write-failed", {}
    sweep(root)
    return True, None, {"id": record["id"], "result": {"queued": True}}


def _gated(handler):
    def run(root, fields, ctx):
        if not enabled() or ctx.caps is None:              # switched off, or the direct route: as if the action did not exist
            return False, "not-implemented", {}
        return handler(root, fields, ctx)
    return run


def register_actions(kit):
    """Called by companion_ui_controls at import with its registration kit: puts the three actions on the allowlist. Not registered when
    the inbox module cannot load -- there is then nowhere to hand a picture to."""
    global _KIT
    if _sibling("companion_ui_inbox") is None:
        return
    _KIT = kit
    for action, required, optional, fields, handler in (
            (BEGIN, ("name", "mime", "bytes", "w", "h", "n", "sha256"), (), _begin_fields, _do_begin),
            (CHUNK, ("id", "idx", "b64"), (), _chunk_fields, _do_chunk),
            (COMMIT, ("id",), ("message", "pin"), _commit_fields, _do_commit)):
        kit.register_action(action, cls=kit.CLASS_SAFE_WRITE, handler=_gated(handler), required=required, optional=optional,
                            fields=fields, rate=RATE[action], usable=usable,
                            policy={"rid_re": RID_RE, "global_rate": False, "max_bytes": COMMAND_MAX[action]})

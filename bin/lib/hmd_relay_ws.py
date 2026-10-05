#!/usr/bin/env python3
"""hmd_relay_ws.py -- stdlib-only RFC 6455 WebSocket client for hmd's relay leg.

WHY THIS EXISTS
hmd's `GET /session/:id/stream` used to be one long chunked HTTP response, and an open response keeps the
relay's Durable Object resident -- billed wall-clock for as long as it lasts, 10,800 GB-s a day for one
always-on session (docs/analysis/2026-10-05-relay-hibernation.md). The same route now also speaks a
hibernatable WebSocket (relay/contract/wire.json `stream_ws`), which lets the object sleep between events.
Python's standard library has no WebSocket client, so this is the smallest honest one: the opening handshake
(RFC 6455 section 4.1), the frame codec (section 5) as a client needs it, and nothing else -- no
extensions, no subprotocols, no TLS code of its own. The socket comes from http.client, so
bin/heimdall-relay-client's Happy Eyeballs connect, IP-family pinning and certificate checks all apply to
this leg exactly as they do to every other request it makes.

WHAT IT DOES AND DOES NOT DO
  - Client frames are always masked with a fresh random key (section 5.3); a server frame that IS masked, one
    with a reserved bit set (no extension was negotiated), an unknown opcode, a malformed control frame, text
    that is not UTF-8, or a continuation that continues nothing is a protocol error -- the connection is
    dropped, never repaired.
  - Messages and the connection are BOUNDED, the same way the NDJSON reader bounds a line and a stream: a
    message over `max_message` bytes is refused from its header, before any of it is read (so a hostile peer
    cannot make this allocate what it declares), and the bytes read on one connection in total are capped at
    `max_total`.
  - A server ping is answered with a pong carrying the same payload, and a close frame is echoed, inside
    `receive()`; neither is an event for the caller beyond the close itself.
  - receive() never loses a byte to a timeout: bytes read are kept, so a frame that straddles a timeout is
    completed by the next call.

PUBLIC API (bin/heimdall-relay-client imports these by name)
  WsError > WsHandshakeError, WsProtocolError, WsEof, WsOverflow(message_bytes, total_bytes)
  new_key() / accept_for(key) / upgrade_headers(key) / check_upgrade(resp, key)   the opening handshake
  UpgradeResponse                    http.client.HTTPResponse that never reads past the head of a 101
  encode_frame(opcode, payload, mask_key=None, fin=True) -> bytes                 one client frame
  Connection(sock, max_message, max_total, mask_source=None)
      .receive(timeout) -> [("text", str) | ("binary", bytes) | ("pong", bytes) | ("close", code, reason)]
      .send_text(text)  .send_close(code, reason)

test/lib/relay_ws_cases.py (run by test/hmd-relay-ws.test.sh) checks every line of this against frames it
builds itself from the RFC's own examples, and runs against deliberately broken copies of this module to
prove it can fail.
"""

import base64
import contextlib
import functools
import hashlib
import http.client
import os
import struct

# RFC 6455 section 1.3: the fixed string every Sec-WebSocket-Accept is derived with
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONT = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA
_KNOWN_OPCODES = frozenset((OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG))
_FIRST_CONTROL = 0x8
_MAX_CONTROL_PAYLOAD = 125  # RFC 6455 section 5.5
_RECV_BYTES = 65536

try:  # the handshake hash is not a security boundary; FIPS-restricted pythons allow sha1 only when told so
    _sha1 = functools.partial(hashlib.sha1, usedforsecurity=False)
    _sha1(b"")
except TypeError:  # python < 3.9 has no such flag, and no such restriction
    _sha1 = hashlib.sha1


class WsError(Exception):
    """Base of everything this module raises on purpose (socket errors are the caller's OSError)."""


class WsHandshakeError(WsError):
    """The relay's answer to the upgrade request is not a valid WebSocket handshake."""


class WsProtocolError(WsError):
    """The peer sent something RFC 6455 forbids a server to send a client."""


class WsEof(WsError):
    """The peer closed the TCP connection (with or without a close frame before it)."""


class WsOverflow(WsError):
    """A message or the connection exceeded its bound. `message_bytes` is the size of the offending
    message (declared, or accumulated over its fragments), 0 when the connection total tripped first."""

    def __init__(self, message_bytes, total_bytes):
        super().__init__("message of %d bytes, %d bytes read on this connection" % (message_bytes, total_bytes))
        self.message_bytes = message_bytes
        self.total_bytes = total_bytes


# -- the opening handshake ---------------------------------------------------------------------------

def new_key():
    """A Sec-WebSocket-Key: 16 random bytes, base64 (RFC 6455 section 4.1)."""
    return base64.b64encode(os.urandom(16)).decode("ascii")


def accept_for(key):
    """The Sec-WebSocket-Accept a server must answer `key` with (RFC 6455 section 4.2.2)."""
    return base64.b64encode(_sha1((key + GUID).encode("ascii")).digest()).decode("ascii")


def upgrade_headers(key):
    """The headers that turn a GET into an upgrade request, beside whatever authorizes it."""
    return {"Upgrade": "websocket", "Connection": "Upgrade", "Sec-WebSocket-Key": key,
            "Sec-WebSocket-Version": "13"}


def check_upgrade(resp, key):
    """Raise WsHandshakeError unless `resp` (anything with .status and .getheader) is a correct answer to an
    upgrade request sent with `key` -- RFC 6455 section 4.1's list of what a client must check. No extension
    and no subprotocol was asked for, so a server that picks one is wrong."""
    if resp.status != 101:
        raise WsHandshakeError("expected status 101, got %s" % resp.status)
    if (resp.getheader("Upgrade") or "").strip().lower() != "websocket":
        raise WsHandshakeError("the Upgrade header is not websocket")
    if "upgrade" not in [token.strip().lower() for token in (resp.getheader("Connection") or "").split(",")]:
        raise WsHandshakeError("the Connection header does not name upgrade")
    if (resp.getheader("Sec-WebSocket-Accept") or "").strip() != accept_for(key):
        raise WsHandshakeError("Sec-WebSocket-Accept does not answer the Sec-WebSocket-Key that was sent")
    for name in ("Sec-WebSocket-Extensions", "Sec-WebSocket-Protocol"):
        if resp.getheader(name):
            raise WsHandshakeError("%s in the answer, and none was asked for" % name)


class UpgradeResponse(http.client.HTTPResponse):
    """http.client's response for a request that may be answered 101 Switching Protocols.

    HTTPResponse reads its socket through a buffered reader, which reads AHEAD: a relay that writes the
    first WebSocket frame in the same segment as the 101 (it does -- a held `device_bound` is sent as the
    socket is accepted) would have it swallowed into that buffer, where nothing that reads the socket can
    reach it. So the head is read through a reader with a ONE-byte buffer, which cannot read past a newline;
    a 101 then leaves every byte after its head on the socket for Connection to read. Any other answer is
    an ordinary response -- a relay that does not know the Upgrade header streams NDJSON, and a refusal
    carries a status and headers -- so once its head is parsed the reader is swapped for the stock buffered
    one, which starts exactly at the body, and the response is used as http.client always is.

    Set it as `conn.response_class` on the connection that sends the upgrade request, and nowhere else."""

    def __init__(self, sock, *args, **kwargs):
        super().__init__(sock, *args, **kwargs)
        self._upgrade_sock = sock
        stock, self.fp = self.fp, sock.makefile("rb", 1)
        stock.close()

    def begin(self):
        super().begin()
        if self.status != 101:
            head_reader, self.fp = self.fp, self._upgrade_sock.makefile("rb")
            head_reader.close()


# -- frames -------------------------------------------------------------------------------------------

def _apply_mask(data, mask_key):
    """`data` XOR the 4-byte key repeated (RFC 6455 section 5.3), as one big-integer XOR: one pass in C."""
    n = len(data)
    if n == 0:
        return b""
    key = (mask_key * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big")


def encode_frame(opcode, payload=b"", mask_key=None, fin=True):
    """One frame as a CLIENT sends it: always masked, with `mask_key` or a fresh random one."""
    n = len(payload)
    if opcode >= _FIRST_CONTROL and (n > _MAX_CONTROL_PAYLOAD or not fin):
        raise ValueError("a control frame is one frame of at most %d bytes" % _MAX_CONTROL_PAYLOAD)
    if mask_key is None:
        mask_key = os.urandom(4)
    if len(mask_key) != 4:
        raise ValueError("a mask key is 4 bytes")
    first = (0x80 if fin else 0) | opcode
    if n < 126:
        head = struct.pack("!BB", first, 0x80 | n)
    elif n < 65536:
        head = struct.pack("!BBH", first, 0x80 | 126, n)
    else:
        head = struct.pack("!BBQ", first, 0x80 | 127, n)
    return head + mask_key + _apply_mask(payload, mask_key)


class Connection:
    """One open WebSocket, seen from the client. `max_message` bounds a message, `max_total` the bytes read on
    the connection; `mask_source` (a callable returning 4 bytes) exists so a test can pin the masks."""

    def __init__(self, sock, max_message, max_total, mask_source=None):
        self.sock = sock
        self.max_message = max_message
        self.max_total = max_total
        self.total_bytes = 0
        self._mask_source = mask_source or (lambda: os.urandom(4))
        self._buf = bytearray()
        self._fragments = []
        self._fragment_opcode = None
        self._fragment_bytes = 0

    # -- sending ------------------------------------------------------------------------------------
    def _send(self, opcode, payload):
        self.sock.sendall(encode_frame(opcode, payload, self._mask_source()))

    def send_text(self, text):
        self._send(OP_TEXT, text.encode("utf-8"))

    def send_close(self, code=None, reason=""):
        """A close frame: a status code and a reason short enough to fit a control frame."""
        payload = b"" if code is None else struct.pack("!H", code) + reason.encode("utf-8")[:_MAX_CONTROL_PAYLOAD - 2]
        self._send(OP_CLOSE, payload)

    # -- receiving ----------------------------------------------------------------------------------
    def receive(self, timeout):
        """Wait up to `timeout` seconds for bytes, read once, and return every message they complete (an empty
        list when they completed none -- the bytes are kept). Raises socket.timeout when nothing arrived,
        WsEof when the peer closed, WsOverflow past a bound, WsProtocolError on a forbidden frame; a ping met
        on the way is answered, which can raise the OSError of a dead socket."""
        self.sock.settimeout(timeout)
        data = self.sock.recv(_RECV_BYTES)
        if not data:
            raise WsEof("the relay closed the connection")
        self.total_bytes += len(data)
        self._buf += data
        events = self._parse()  # a message declared over its cap is refused here, and named by its own size
        if self.max_total is not None and self.total_bytes > self.max_total:
            raise WsOverflow(0, self.total_bytes)
        return events

    def _parse(self):
        events = []
        buf = self._buf
        while len(buf) >= 2:
            first, second = buf[0], buf[1]
            if first & 0x70:
                raise WsProtocolError("a reserved bit is set and no extension was negotiated")
            if second & 0x80:
                raise WsProtocolError("a server frame is masked")
            opcode, fin, length, head = first & 0x0F, bool(first & 0x80), second & 0x7F, 2
            if opcode not in _KNOWN_OPCODES:
                raise WsProtocolError("reserved opcode %d" % opcode)
            if length == 126:
                if len(buf) < 4:
                    break
                length, head = struct.unpack_from("!H", buf, 2)[0], 4
            elif length == 127:
                if len(buf) < 10:
                    break
                length, head = struct.unpack_from("!Q", buf, 2)[0], 10
                if length >> 63:
                    raise WsProtocolError("a 64-bit length with the top bit set")
            if opcode >= _FIRST_CONTROL:
                if not fin or length > _MAX_CONTROL_PAYLOAD:
                    raise WsProtocolError("a control frame that is fragmented or over %d bytes"
                                          % _MAX_CONTROL_PAYLOAD)
            elif self._fragment_bytes + length > self.max_message:
                # refused from the header alone: nothing the peer declares is ever allocated or waited for
                raise WsOverflow(self._fragment_bytes + length, self.total_bytes)
            if len(buf) < head + length:
                break
            payload = bytes(buf[head:head + length])
            del buf[:head + length]
            if opcode == OP_PING:
                self._send(OP_PONG, payload)
            elif opcode == OP_PONG:
                events.append(("pong", payload))
            elif opcode == OP_CLOSE:
                events.append(self._close_event(payload))
                buf.clear()  # nothing may follow a close frame
                break
            else:
                message = self._add_fragment(opcode, fin, payload)
                if message is not None:
                    events.append(message)
        return events

    def _add_fragment(self, opcode, fin, payload):
        """One data frame of a message; the finished message as an event, or None while it is incomplete."""
        if opcode == OP_CONT:
            if self._fragment_opcode is None:
                raise WsProtocolError("a continuation frame with nothing to continue")
        elif self._fragment_opcode is not None:
            raise WsProtocolError("a new data frame in the middle of a fragmented message")
        else:
            self._fragment_opcode = opcode
        self._fragments.append(payload)
        self._fragment_bytes += len(payload)
        if not fin:
            return None
        kind, body = self._fragment_opcode, b"".join(self._fragments)
        self._fragments, self._fragment_opcode, self._fragment_bytes = [], None, 0
        if kind == OP_BINARY:
            return ("binary", body)
        try:
            return ("text", body.decode("utf-8"))
        except UnicodeDecodeError:
            raise WsProtocolError("a text message that is not valid UTF-8") from None

    def _close_event(self, payload):
        """The peer's close frame as an event, echoed back with its status code (RFC 6455 section 5.5.1). The
        echo is a courtesy to a peer that may already be gone: its write failing changes nothing the caller
        needs to know, so the close is still reported."""
        if len(payload) == 1:
            raise WsProtocolError("a close frame with a one-byte payload")
        code = struct.unpack("!H", payload[:2])[0] if payload else None
        reason = payload[2:].decode("utf-8", "replace")
        with contextlib.suppress(OSError):
            self._send(OP_CLOSE, payload[:2])
        return ("close", code, reason)

#!/usr/bin/env python3
"""test/lib/relay_ws_cases.py -- the cases test/hmd-relay-ws.test.sh runs against bin/lib/hmd_relay_ws.py,
the stdlib RFC 6455 client hmd's relay leg speaks (bin/heimdall-relay-client imports it by path).

Everything the module sends or reads is checked against frames this file builds and decodes ITSELF, from the
RFC's own text (section 1.3's handshake sample, section 5.7's masking examples), never through the module:
a codec that shared its encoder with its test would agree with itself whatever it did. The sockets are
scripted in memory except for the UpgradeResponse cases, which need a real loopback connection because the
property they pin -- the head of a 101 is read WITHOUT reading the first WebSocket frame behind it -- is a
property of how http.client buffers a socket.

HMD_RELAY_WS_MODULE points the run at another copy of the module: test/hmd-relay-ws.test.sh uses it to prove
the cases go red on a module that has been broken (a mutant), so a case that can no longer fail is itself a
failing suite.

Output follows the suite convention: "  ok   N. ..." / "  FAIL N. ..." and a final "P passed, F failed"
line; exit 0 only when F == 0.
"""
import http.client
import importlib.util
import os
import queue
import socket
import struct
import sys
import threading
import time
import warnings

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
MODULE_PATH = os.environ.get("HMD_RELAY_WS_MODULE") or os.path.join(REPO, "bin", "lib", "hmd_relay_ws.py")

# RFC 6455 section 5.7's masking key, and the "Hello" examples built on it
MASK = bytes.fromhex("37fa213d")
HELLO_MASKED = bytes.fromhex("7f9f4d5158")
PASSED = FAILED = 0


def check(cond, label, detail=None):
    global PASSED, FAILED
    n = PASSED + FAILED + 1
    if cond:
        PASSED += 1
        print("  ok   %d. %s" % (n, label))
    else:
        FAILED += 1
        print("  FAIL %d. %s" % (n, label))
        if detail is not None:
            print("       %s" % (detail,))


def load_module():
    spec = importlib.util.spec_from_file_location("hmd_relay_ws", MODULE_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# -- frames, built and read here and nowhere else ----------------------------------------------------

def server_frame(opcode, payload=b"", fin=True, rsv=0, masked=False):
    """One frame as a server sends it (unmasked), or, with masked=True, the forbidden masked kind."""
    first = (0x80 if fin else 0) | rsv | opcode
    n = len(payload)
    flag = 0x80 if masked else 0
    if n < 126:
        head = bytes([first, flag | n])
    elif n < 65536:
        head = bytes([first, flag | 126]) + struct.pack("!H", n)
    else:
        head = bytes([first, flag | 127]) + struct.pack("!Q", n)
    if masked:
        return head + MASK + bytes(c ^ MASK[i % 4] for i, c in enumerate(payload))
    return head + payload


def read_client_frame(data):
    """(fin, opcode, payload, masked, consumed) of the first frame in `data`, the way a server reads one."""
    first, second = data[0], data[1]
    n, i = second & 0x7F, 2
    if n == 126:
        n, i = struct.unpack("!H", data[2:4])[0], 4
    elif n == 127:
        n, i = struct.unpack("!Q", data[2:10])[0], 10
    masked = bool(second & 0x80)
    mask = data[i:i + 4] if masked else b""
    i += 4 if masked else 0
    payload = bytes(data[i:i + n])
    if masked:
        payload = bytes(c ^ mask[k % 4] for k, c in enumerate(payload))
    return bool(first & 0x80), first & 0x0F, payload, masked, i + n


class ScriptedSocket:
    """A socket whose recv() plays a script: bytes are handed out (split to the size asked for), b"" is the
    peer closing, TIMEOUT raises socket.timeout, an exception instance is raised. sendall() records."""
    TIMEOUT = object()

    def __init__(self, *script):
        self.script = list(script)
        self.sent = bytearray()
        self.timeouts = []

    def settimeout(self, value):
        self.timeouts.append(value)

    def recv(self, n):
        if not self.script:
            raise AssertionError("recv() called with nothing left in the script")
        item = self.script.pop(0)
        if item is self.TIMEOUT:
            raise socket.timeout("timed out")
        if isinstance(item, BaseException):
            raise item
        if len(item) > n:
            self.script.insert(0, item[n:])
            return item[:n]
        return item

    def sendall(self, data):
        self.sent += data


class Head:
    """The two things check_upgrade reads off an http.client response."""

    def __init__(self, status, **headers):
        self.status = status
        self._headers = {k.replace("_", "-").lower(): v for k, v in headers.items()}

    def getheader(self, name, default=None):
        return self._headers.get(name.lower(), default)


def connection(mod, *script, max_message=1000, max_total=100000):
    sock = ScriptedSocket(*script)
    return sock, mod.Connection(sock, max_message=max_message, max_total=max_total, mask_source=lambda: MASK)


def receive_all(conn, rounds=1):
    events = []
    for _ in range(rounds):
        events.extend(conn.receive(1.0))
    return events


def raises(exc_type, fn):
    try:
        fn()
    except exc_type as exc:
        return exc
    except Exception as exc:  # the wrong failure is a failure of the case, reported by the caller
        return exc
    return None


# -- real-socket helper for UpgradeResponse -----------------------------------------------------------

def serve_once(ports, reply, pieces=1, gap_s=0.0):
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    ports.put(srv.getsockname()[1])
    conn, _ = srv.accept()
    conn.settimeout(5)
    seen = b""
    while b"\r\n\r\n" not in seen:
        seen += conn.recv(4096)
    step = max(1, len(reply) // pieces)
    for start in range(0, len(reply), step):
        conn.sendall(reply[start:start + step])
        if gap_s:
            time.sleep(gap_s)
    try:
        conn.recv(16)
    except OSError:
        time.sleep(0)
    conn.close()
    srv.close()


def upgrade_roundtrip(mod, reply, inspect, pieces=1, gap_s=0.0):
    """Sends GET with `Upgrade: websocket` to a loopback server that answers `reply`, through
    mod.UpgradeResponse, and hands (conn, resp) to `inspect`. The connection is closed afterwards the way the
    client closes it, so an exception there fails the case."""
    ports = queue.Queue()
    thread = threading.Thread(target=serve_once, args=(ports, reply, pieces, gap_s), daemon=True)
    thread.start()
    conn = http.client.HTTPConnection("127.0.0.1", ports.get(timeout=5), timeout=5)
    conn.response_class = mod.UpgradeResponse
    try:
        conn.request("GET", "/session/x/stream", headers={"Upgrade": "websocket"})
        resp = conn.getresponse()
        return inspect(conn, resp)
    finally:
        conn.close()
        thread.join(timeout=5)


def chunked(body):
    return b"%x\r\n" % len(body) + body + b"\r\n"


def main():
    print("relay-ws (bin/lib/hmd_relay_ws.py, RFC 6455 client, against frames built here)")
    mod = load_module()

    # -- the handshake -------------------------------------------------------------------------------
    sample_key = "dGhlIHNhbXBsZSBub25jZQ=="
    check(mod.accept_for(sample_key) == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
          "handshake: Sec-WebSocket-Accept for RFC 6455 section 1.3's sample key", mod.accept_for(sample_key))

    keys = {mod.new_key() for _ in range(50)}
    import base64
    check(len(keys) == 50 and all(len(base64.b64decode(k)) == 16 for k in keys),
          "handshake: new_key() is 16 random bytes, base64, fresh each time")

    check(mod.upgrade_headers(sample_key) == {"Upgrade": "websocket", "Connection": "Upgrade",
                                              "Sec-WebSocket-Key": sample_key, "Sec-WebSocket-Version": "13"},
          "handshake: the upgrade request carries exactly Upgrade, Connection, Sec-WebSocket-Key and Version 13",
          mod.upgrade_headers(sample_key))

    good = dict(Upgrade="websocket", Connection="Upgrade", Sec_WebSocket_Accept="s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    check(raises(Exception, lambda: mod.check_upgrade(Head(101, **good), sample_key)) is None,
          "handshake: a correct 101 is accepted")
    check(raises(Exception, lambda: mod.check_upgrade(
              Head(101, Upgrade="WebSocket", Connection="keep-alive, Upgrade",
                   Sec_WebSocket_Accept="s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), sample_key)) is None,
          "handshake: header names and values are compared case-insensitively, Connection as a token list")
    refusals = {
        "a status other than 101": Head(200, **good),
        "a wrong Sec-WebSocket-Accept": Head(101, **dict(good, Sec_WebSocket_Accept="AAAAAAAAAAAAAAAAAAAAAAAAAAA=")),
        "a missing Sec-WebSocket-Accept": Head(101, Upgrade="websocket", Connection="Upgrade"),
        "a missing Upgrade header": Head(101, Connection="Upgrade", Sec_WebSocket_Accept=good["Sec_WebSocket_Accept"]),
        "an Upgrade that is not websocket": Head(101, **dict(good, Upgrade="h2c")),
        "a Connection without upgrade": Head(101, **dict(good, Connection="keep-alive")),
        "an extension nobody asked for": Head(101, **dict(good, Sec_WebSocket_Extensions="permessage-deflate")),
        "a subprotocol nobody asked for": Head(101, **dict(good, Sec_WebSocket_Protocol="chat")),
    }
    for what, head in refusals.items():
        err = raises(Exception, lambda head=head: mod.check_upgrade(head, sample_key))
        check(isinstance(err, mod.WsHandshakeError), "handshake: refused -- %s" % what, repr(err))

    # -- encoding what hmd sends ----------------------------------------------------------------------
    masked_hello = bytes.fromhex("81 85 37fa213d 7f9f4d5158".replace(" ", ""))
    check(mod.encode_frame(mod.OP_TEXT, b"Hello", mask_key=MASK) == masked_hello,
          "encode: RFC 6455 section 5.7's masked text frame 'Hello' is reproduced byte for byte")
    check(mod.encode_frame(mod.OP_PONG, b"Hello", mask_key=MASK) == bytes.fromhex("8a85") + MASK + HELLO_MASKED,
          "encode: RFC 6455 section 5.7's masked pong 'Hello' is reproduced byte for byte")

    lengths_ok = True
    seen_heads = {}
    for n in (0, 1, 125, 126, 127, 65535, 65536, 70000):
        payload = bytes((i * 7) % 256 for i in range(n))
        wire = mod.encode_frame(mod.OP_BINARY, payload, mask_key=MASK)
        fin, opcode, back, masked, consumed = read_client_frame(wire)
        seen_heads[n] = wire[1] & 0x7F
        if not (fin and opcode == 2 and masked and back == payload and consumed == len(wire)):
            lengths_ok = False
    check(lengths_ok and seen_heads[125] == 125 and seen_heads[126] == 126 and seen_heads[65535] == 126
          and seen_heads[65536] == 127,
          "encode: payloads of 0 to 70000 bytes use the 7-, 16- and 64-bit length forms, always masked, and read back",
          seen_heads)

    first = mod.encode_frame(mod.OP_TEXT, b"same payload")
    second = mod.encode_frame(mod.OP_TEXT, b"same payload")
    check(first != second and first[1] & 0x80 and second[1] & 0x80,
          "encode: with no mask given each frame draws its own random mask (RFC 6455 section 5.3)")

    close = mod.encode_frame(mod.OP_CLOSE, struct.pack("!H", 1000) + b"rotate", mask_key=MASK)
    fin, opcode, payload, masked, _ = read_client_frame(close)
    check(fin and opcode == 8 and masked and payload == struct.pack("!H", 1000) + b"rotate",
          "encode: a close frame carries its status code then its reason")
    check(isinstance(raises(ValueError, lambda: mod.encode_frame(mod.OP_PING, b"x" * 126)), ValueError),
          "encode: a control frame over 125 bytes is refused (RFC 6455 section 5.5)")

    # -- reading what the relay sends -----------------------------------------------------------------
    _, conn = connection(mod, bytes.fromhex("810548656c6c6f"))
    check(receive_all(conn) == [("text", "Hello")],
          "decode: RFC 6455 section 5.7's unmasked text frame 'Hello' is the message 'Hello'")

    _, conn = connection(mod, bytes.fromhex("010348656c") + bytes.fromhex("80026c6f"))
    check(receive_all(conn) == [("text", "Hello")],
          "decode: RFC 6455 section 5.7's fragmented message 'Hel' + 'lo' is one message")

    wire = server_frame(1, b'{"a":1}') + server_frame(1, b'{"b":2}') + server_frame(1, b"pong")
    _, conn = connection(mod, wire)
    check(receive_all(conn) == [("text", '{"a":1}'), ("text", '{"b":2}'), ("text", "pong")],
          "decode: several frames in one read come back in order")

    one_byte_at_a_time = [bytes([b]) for b in wire]
    _, conn = connection(mod, *one_byte_at_a_time)
    check(receive_all(conn, rounds=len(wire)) == [("text", '{"a":1}'), ("text", '{"b":2}'), ("text", "pong")],
          "decode: the same frames arriving one byte per read are the same messages")

    sock, conn = connection(mod, server_frame(1, b"par", fin=False) + server_frame(9, b"beat")
                            + server_frame(0, b"ts"))
    events = receive_all(conn)
    fin, opcode, payload, masked, _ = read_client_frame(bytes(sock.sent))
    check(events == [("text", "parts")] and opcode == 10 and payload == b"beat" and masked,
          "decode: a ping inside a fragmented message is answered with a masked pong, and the message survives",
          (events, bytes(sock.sent)))

    sock, conn = connection(mod, bytes.fromhex("890548656c6c6f"))
    events = receive_all(conn)
    check(bytes(sock.sent) == bytes.fromhex("8a85") + MASK + HELLO_MASKED and events == [],
          "decode: a server ping 'Hello' is answered with RFC 6455 section 5.7's masked pong, and is not an event",
          bytes(sock.sent).hex())

    _, conn = connection(mod, server_frame(10, b"x"))
    check(receive_all(conn) == [("pong", b"x")], "decode: a pong from the relay is reported (it proves the path is alive)")

    sock, conn = connection(mod, server_frame(8, struct.pack("!H", 4002) + b"superseded"))
    events = receive_all(conn)
    fin, opcode, payload, masked, _ = read_client_frame(bytes(sock.sent))
    check(events == [("close", 4002, "superseded")] and opcode == 8 and masked and payload[:2] == struct.pack("!H", 4002),
          "decode: a close frame gives its code and reason, and is echoed back masked", (events, bytes(sock.sent)))

    _, conn = connection(mod, server_frame(8, b""))
    check(receive_all(conn) == [("close", None, "")], "decode: a close frame with no payload has no code")

    _, conn = connection(mod, server_frame(2, b"\x00\x01\x02"))
    check(receive_all(conn) == [("binary", b"\x00\x01\x02")], "decode: a binary message is reported as binary")

    payload_256, payload_64k = b"a" * 256, b"b" * 65536
    _, conn = connection(mod, server_frame(1, payload_256) + server_frame(1, payload_64k),
                         max_message=70000, max_total=200000)
    check(receive_all(conn) == [("text", payload_256.decode()), ("text", payload_64k.decode())],
          "decode: the 16-bit and the 64-bit length forms are read")

    euro = "café €".encode("utf-8")
    _, conn = connection(mod, server_frame(1, euro[:4], fin=False) + server_frame(0, euro[4:]))
    check(receive_all(conn) == [("text", "café €")],
          "decode: a multibyte character split across two fragments is decoded whole")

    # -- frames a client must refuse -------------------------------------------------------------------
    forbidden = {
        "a masked frame from the server": server_frame(1, b"x", masked=True),
        "a reserved bit set": server_frame(1, b"x", rsv=0x40),
        "a reserved opcode": server_frame(3, b"x"),
        "a control frame over 125 bytes": bytes([0x89, 126]) + struct.pack("!H", 126) + b"x" * 126,
        "a fragmented control frame": server_frame(9, b"x", fin=False),
        "a continuation with nothing to continue": server_frame(0, b"x"),
        "a new data frame in the middle of a fragmented message": server_frame(1, b"a", fin=False) + server_frame(1, b"b"),
        "a text message that is not UTF-8": server_frame(1, b"\xff\xfe"),
        "a 64-bit length with the top bit set": bytes([0x82, 127]) + struct.pack("!Q", 1 << 63),
        "a close frame with a one-byte payload": server_frame(8, b"x"),
    }
    for what, wire in forbidden.items():
        _, conn = connection(mod, wire)
        err = raises(Exception, lambda conn=conn: conn.receive(1.0))
        check(isinstance(err, mod.WsProtocolError), "decode: refused -- %s" % what, repr(err))

    # -- the bounds -------------------------------------------------------------------------------------
    sock, conn = connection(mod, bytes([0x81, 126]) + struct.pack("!H", 1001), max_message=1000)
    err = raises(Exception, lambda: conn.receive(1.0))
    check(isinstance(err, mod.WsOverflow) and err.message_bytes == 1001 and not sock.script,
          "limits: a message declared over the cap is refused from its header, before any of it is read",
          repr(err))

    _, conn = connection(mod, server_frame(1, b"x" * 600, fin=False) + server_frame(0, b"y" * 401), max_message=1000)
    err = raises(Exception, lambda: conn.receive(1.0))
    check(isinstance(err, mod.WsOverflow) and err.message_bytes == 1001,
          "limits: fragments that add up past the cap are refused as a message", repr(err))

    _, conn = connection(mod, server_frame(1, b"x" * 1000), max_message=1000)
    check(receive_all(conn) == [("text", "x" * 1000)], "limits: a message of exactly the cap is accepted")

    sock, conn = connection(mod, server_frame(1, b"x" * 40), server_frame(1, b"y" * 40), server_frame(1, b"z" * 40),
                            max_message=1000, max_total=100)
    conn.receive(1.0)
    err = raises(Exception, lambda: [conn.receive(1.0), conn.receive(1.0)])
    check(isinstance(err, mod.WsOverflow) and err.total_bytes > 100,
          "limits: the bytes read on one connection are capped in total, whatever they are", repr(err))

    # -- the socket underneath ------------------------------------------------------------------------
    whole = server_frame(1, b"split across a timeout")
    sock, conn = connection(mod, whole[:5], ScriptedSocket.TIMEOUT, whole[5:])
    first_read = conn.receive(1.0)
    timed_out = raises(socket.timeout, lambda: conn.receive(0.25))
    rest = conn.receive(1.0)
    check(first_read == [] and isinstance(timed_out, socket.timeout) and rest == [("text", "split across a timeout")]
          and sock.timeouts == [1.0, 0.25, 1.0],
          "socket: a timeout in the middle of a frame loses nothing, and the timeout asked for reaches the socket",
          (first_read, repr(timed_out), rest, sock.timeouts))

    _, conn = connection(mod, b"")
    check(isinstance(raises(Exception, lambda: conn.receive(1.0)), mod.WsEof),
          "socket: the peer closing the TCP connection is WsEof")

    sock, conn = connection(mod)
    conn.send_text("ping")
    fin, opcode, payload, masked, consumed = read_client_frame(bytes(sock.sent))
    check(fin and opcode == 1 and payload == b"ping" and masked and consumed == len(sock.sent),
          "send: send_text('ping') is one masked text frame")

    sock, conn = connection(mod)
    conn.send_close(1000, "rotate")
    fin, opcode, payload, masked, _ = read_client_frame(bytes(sock.sent))
    check(opcode == 8 and masked and payload == struct.pack("!H", 1000) + b"rotate",
          "send: send_close(1000, 'rotate') is one masked close frame")

    class Broken(ScriptedSocket):
        def sendall(self, data):
            raise BrokenPipeError("peer gone")

    broken = mod.Connection(Broken(), max_message=10, max_total=10, mask_source=lambda: MASK)
    check(isinstance(raises(OSError, lambda: broken.send_text("ping")), BrokenPipeError),
          "send: a write that fails is the caller's OSError, never swallowed")

    # -- UpgradeResponse: http.client, but never one byte past the head of a 101 ---------------------------
    head_101 = (b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                b"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n")
    frames = server_frame(1, b"first") + server_frame(10, b"second")

    def inspect_101(conn, resp):
        conn.sock.settimeout(5)
        got = b""
        while len(got) < len(frames):
            got += conn.sock.recv(4096)
        return resp.status, resp.getheader("Sec-WebSocket-Accept"), got

    with warnings.catch_warnings():
        warnings.simplefilter("error", ResourceWarning)
        try:
            result = upgrade_roundtrip(mod, head_101 + frames, inspect_101)
        except Exception as exc:
            result = repr(exc)
    check(result == (101, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", frames),
          "upgrade response: the frames sent in the same segment as a 101 are still on the socket after the head is read",
          result)

    def inspect_split(conn, resp):
        conn.sock.settimeout(5)
        got = b""
        while len(got) < len(frames):
            got += conn.sock.recv(4096)
        return resp.status, got

    result = upgrade_roundtrip(mod, head_101 + frames, inspect_split, pieces=40, gap_s=0.005)
    check(result == (101, frames), "upgrade response: a head that trickles in a few bytes at a time is parsed all the same", result)

    lines = [b'{"a":1}\n', b'{"b":2}\n']
    head_200 = b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n"

    def inspect_200(conn, resp):
        return resp.status, [resp.readline(100) for _ in range(3)]

    result = upgrade_roundtrip(mod, head_200 + chunked(lines[0]) + chunked(lines[1]) + b"0\r\n\r\n", inspect_200)
    check(result == (200, lines + [b""]),
          "upgrade response: a relay that ignores the Upgrade header and streams NDJSON is read as before (the fallback)",
          result)

    head_429 = b"HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\nContent-Length: 2\r\n\r\n{}"

    def inspect_429(conn, resp):
        return resp.status, resp.getheader("Retry-After"), resp.read()

    result = upgrade_roundtrip(mod, head_429, inspect_429)
    check(result == (429, "7", b"{}"), "upgrade response: an ordinary refusal keeps its status, headers and body", result)

    print("\n%d passed, %d failed" % (PASSED, FAILED))
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

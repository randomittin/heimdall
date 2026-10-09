#!/usr/bin/env python3
"""test/lib/fake_relay_code.py -- a hermetic stand-in for the relay's pair-by-session-code surface
(hmdapp's docs/superpowers/specs/2026-10-05-pair-by-session-code.md section 6), imported by
test/lib/app_pair_code_cases.py to drive the REAL bin/heimdall-relay-client and the REAL
bin/heimdall-app against a loopback HTTP server. test/lib/fake-relay.py stays the stand-in for the
QR-only relay surface; this one answers the routes code pairing adds and, unlike that one, never
sends a device_bound on its own: a test says when, and with what, the "phone" claimed the window.

Routes (every answer is the shape section 6 documents):
  POST /pair/init                    session_id, 26-char pairing_code, relay_session_token, exp (now + ttl_s)
  POST /session/:id/code             bearer; {code, gh_token, hmd_commit} -> 200 {code, gh_login, exp},
                                     or whatever `code_status` says for that registration
  POST /session/:id/frames           bearer; state | ack | key_reveal envelopes, recorded -> {ok, delivered}
  POST /session/:id/revoke           bearer; ends the session (its stream gets session_ended)
  GET  /session/:id/stream           bearer; chunked NDJSON, fed by inject_device_bound / end_session
  POST /identity/github/revoke       {gh_token} -> 200 {gh_login, not_before}, or `identity_status`

What it records (all in memory, read by the tests): `registrations` (one dict per /code call, with
`token_ok` -- the token compared against `expect_token` -- and `token_len`, NEVER the token itself, so
a test that scans files for the token cannot find it here either), `frames`, `revokes`,
`identity_revokes`, `pair_inits` and `requests`.

Two knobs make it hostile: `ignore_revokes` (a revoke is answered and recorded but the session and its stream
stay open -- a relay that does not end what hmd asked it to end) and `frames_status` (answers a frame it has
already recorded with a status of the test's choosing -- a relay that refuses a key_reveal it has read).

Stdlib only.
"""
import base64
import json
import queue
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CODE_RE = re.compile(r"^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}$")
B64URL_32_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
SESSION_PATH_RE = re.compile(r"^/session/([^/]+)/(code|frames|revoke|stream)$")


def _compact(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


class _QuietServer(ThreadingHTTPServer):
    """A client that closes a connection mid-request (the code-window renewal cuts hmd's stream on purpose) is
    not a fault of this fake: the default handler would print a traceback for it into the suite's output."""

    daemon_threads = True

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (ConnectionError, TimeoutError)):
            return
        super().handle_error(request, client_address)


class Session:
    def __init__(self, sid, token, pairing_code, exp):
        self.id = sid
        self.token = token
        self.pairing_code = pairing_code
        self.exp = exp
        self.outbox = queue.Queue()  # NDJSON lines for hmd's stream; None ends it
        self.ended = False
        self.stream_gen = 0
        self.stream_opens = 0


class FakeCodeRelay:
    def __init__(self, ttl_s=60, gh_login="octocat", expect_token=None):
        self.ttl_s = ttl_s
        self.gh_login = gh_login
        self.expect_token = expect_token
        self.code_status = None      # callable(registration dict) -> (status, body) or None for the default
        self.identity_status = None  # callable(identity dict) -> (status, body) or None for the default
        self.frames_status = None    # callable(envelope dict) -> (status, body) or None for the default; recorded first
        self.pair_init_status = None  # callable() -> (status, body) or None for the default; answered before a session is made
        self.ignore_revokes = False  # a hostile relay: a revoke is recorded and answered, the session stays open
        self.lock = threading.Lock()
        self.sessions = {}
        self.order = []
        self.registrations = []
        self.frames = []
        self.revokes = []
        self.identity_revokes = []
        self.pair_inits = []
        self.requests = []
        self.closing = False
        self.httpd = None
        self.thread = None
        self.port = None

    # -- lifecycle -------------------------------------------------------------------------
    def start(self):
        handler = type("BoundHandler", (_Handler,), {"relay": self})
        self.httpd = _QuietServer(("127.0.0.1", 0), handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        return self

    def stop(self):
        self.closing = True
        with self.lock:
            sessions = list(self.sessions.values())
        for sess in sessions:
            sess.outbox.put(None)
        if self.httpd is not None:
            self.httpd.shutdown()
            self.httpd.server_close()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.port

    # -- state the tests read and drive ---------------------------------------------------------
    def new_session(self):
        sid = str(uuid.uuid4())
        token = base64.urlsafe_b64encode(uuid.uuid4().bytes + uuid.uuid4().bytes).decode("ascii").rstrip("=")
        pairing_code = base64.b32encode(uuid.uuid4().bytes).decode("ascii").rstrip("=")
        sess = Session(sid, token, pairing_code, int(time.time()) + self.ttl_s)
        with self.lock:
            self.sessions[sid] = sess
            self.order.append(sid)
            self.pair_inits.append(sid)
        return sess

    def get(self, sid):
        with self.lock:
            return self.sessions.get(sid)

    def latest(self):
        with self.lock:
            return self.sessions[self.order[-1]] if self.order else None

    def frames_of(self, sid, type_=None):
        with self.lock:
            return [env for s, env in self.frames if s == sid and (type_ is None or env.get("type") == type_)]

    def all_frames(self, type_):
        with self.lock:
            return [(s, env) for s, env in self.frames if env.get("type") == type_]

    def inject_device_bound(self, sid, device_pub_b64url, via="code", device_label="Pixel 9a", gh_login=None):
        """What the relay tells hmd once a phone claimed the session (section 6.5): the device's key and,
        for a claim by code, who it is. `via` None leaves the field out, as a relay that predates it would."""
        payload = {"device_pubkey": device_pub_b64url, "bound_at": int(time.time())}
        if via is not None:
            payload["via"] = via
        if via == "code":
            payload["device_label"] = device_label
            payload["gh_login"] = gh_login if gh_login is not None else self.gh_login
        self.get(sid).outbox.put(_compact({"v": 1, "session_id": sid, "seq": 0, "sender": "relay",
                                           "type": "device_bound", "nonce": None, "ciphertext": None,
                                           "payload": payload}))

    def end_session(self, sid, reason="revoked"):
        sess = self.get(sid)
        sess.ended = True
        sess.outbox.put(_compact({"v": 1, "session_id": sid, "seq": 0, "sender": "relay", "type": "session_ended",
                                  "nonce": None, "ciphertext": None, "payload": {"reason": reason}}))
        sess.outbox.put(None)


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fake-relay-code/1"
    relay = None  # bound by FakeCodeRelay.start

    def log_message(self, fmt, *args):
        return

    # -- helpers --------------------------------------------------------------------------------
    def _json(self, status, obj):
        body = _compact(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _bearer(self):
        auth = self.headers.get("Authorization") or ""
        return auth[len("Bearer "):] if auth.startswith("Bearer ") else None

    def _record(self, method):
        with self.relay.lock:
            self.relay.requests.append("%s %s" % (method, self.path))

    def _session(self, sid):
        """The session when the bearer matches; otherwise answers 404/401 itself and returns None."""
        sess = self.relay.get(sid)
        if sess is None:
            self._json(404, {"error": "session not found"})
            return None
        if self._bearer() != sess.token:
            self._json(401, {"error": "unauthorized"})
            return None
        return sess

    # -- routes ---------------------------------------------------------------------------------
    def do_POST(self):
        self._record("POST")
        relay = self.relay
        raw = self._body()
        if self.path == "/pair/init":
            if relay.pair_init_status is not None:
                answer = relay.pair_init_status()
                if answer is not None:
                    self._json(*answer)
                    return
            sess = relay.new_session()
            self._json(200, {"session_id": sess.id, "pairing_code": sess.pairing_code,
                             "relay_session_token": sess.token, "exp": sess.exp})
            return
        if self.path == "/identity/github/revoke":
            self._identity_revoke(raw)
            return
        m = SESSION_PATH_RE.match(self.path)
        if not m or m.group(2) == "stream":
            self._json(404, {"error": "no such route"})
            return
        sess = self._session(m.group(1))
        if sess is None:
            return
        route = m.group(2)
        if route == "code":
            self._code(sess, raw)
        elif route == "frames":
            self._frames(sess, raw)
        else:
            with relay.lock:
                relay.revokes.append(sess.id)
            if not relay.ignore_revokes:
                relay.end_session(sess.id)
            self._json(200, {"ok": True})

    def _code(self, sess, raw):
        relay = self.relay
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            body = None
        body = body if isinstance(body, dict) else {}
        token = body.get("gh_token")
        registration = {
            "session_id": sess.id,
            "code": body.get("code"),
            "hmd_commit": body.get("hmd_commit"),
            "keys": sorted(body),
            "token_ok": isinstance(token, str) and relay.expect_token is not None and token == relay.expect_token,
            "token_len": len(token) if isinstance(token, str) else 0,
            "content_type": self.headers.get("Content-Type"),
            "at": time.time(),
        }
        with relay.lock:
            relay.registrations.append(registration)
        if relay.code_status is not None:
            answer = relay.code_status(registration)
            if answer is not None:
                self._json(*answer)
                return
        if not isinstance(registration["code"], str) or not CODE_RE.match(registration["code"]):
            self._json(400, {"error": "invalid code"})
        elif not isinstance(registration["hmd_commit"], str) or not B64URL_32_RE.match(registration["hmd_commit"]):
            self._json(400, {"error": "invalid hmd_commit"})
        elif not registration["token_ok"]:
            self._json(401, {"error": "github token rejected"})
        else:
            self._json(200, {"code": registration["code"], "gh_login": relay.gh_login, "exp": sess.exp})

    def _frames(self, sess, raw):
        try:
            envelope = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._json(400, {"error": "invalid JSON"})
            return
        if not isinstance(envelope, dict) or envelope.get("sender") != "hmd" \
                or envelope.get("type") not in ("state", "ack", "key_reveal"):
            self._json(400, {"error": "invalid envelope"})
            return
        with self.relay.lock:
            self.relay.frames.append((sess.id, envelope))
        if self.relay.frames_status is not None:
            answer = self.relay.frames_status(envelope)
            if answer is not None:
                self._json(*answer)
                return
        self._json(200, {"ok": True, "delivered": True})

    def _identity_revoke(self, raw):
        relay = self.relay
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            body = None
        body = body if isinstance(body, dict) else {}
        token = body.get("gh_token")
        record = {
            "keys": sorted(body),
            "token_ok": isinstance(token, str) and relay.expect_token is not None and token == relay.expect_token,
            "token_len": len(token) if isinstance(token, str) else 0,
        }
        with relay.lock:
            relay.identity_revokes.append(record)
        if relay.identity_status is not None:
            answer = relay.identity_status(record)
            if answer is not None:
                self._json(*answer)
                return
        if not record["token_ok"]:
            self._json(401, {"error": "github token rejected"})
        else:
            self._json(200, {"gh_login": relay.gh_login, "not_before": int(time.time())})

    def do_GET(self):
        self._record("GET")
        m = SESSION_PATH_RE.match(self.path)
        if not m or m.group(2) != "stream":
            self._json(404, {"error": "no such route"})
            return
        sess = self._session(m.group(1))
        if sess is None:
            return
        if sess.ended and sess.outbox.empty():
            self._json(410, {"error": "session ended"})
            return
        sess.stream_gen += 1
        gen = sess.stream_gen
        sess.stream_opens += 1
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while True:
                if self.relay.closing or sess.stream_gen != gen:
                    return
                try:
                    line = sess.outbox.get(timeout=0.1)
                except queue.Empty:
                    continue
                if line is None:
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                    return
                data = line.encode("utf-8") + b"\n"
                self.wfile.write(("%x\r\n" % len(data)).encode("ascii") + data + b"\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

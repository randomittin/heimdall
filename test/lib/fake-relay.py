#!/usr/bin/env python3
"""test/lib/fake-relay.py -- a HERMETIC stand-in for the Cloudflare relay
(hmdapp's docs/HANDOFF-TO-HEIMDALL-relay.md "Implemented relay API"), used by
test/heimdall-app-relay.test.sh to drive the REAL bin/heimdall-relay-client
against a loopback HTTP server instead of the real Cloudflare Worker.

Two independent modes, selected by argv[1]:

  fake-relay.py serve PORT --log LOGDIR --ctl CTLDIR
      Runs a ThreadingHTTPServer forever (until killed) implementing
      POST /pair/init, GET /session/:id/stream, POST /session/:id/frames,
      POST /session/:id/revoke -- see Handler below for the per-route
      contract. Every request line is appended to LOGDIR/requests.log; every
      POST /frames body is appended verbatim to LOGDIR/frames.ndjson.

  fake-relay.py device <action> ...
      One-shot helper subcommands standing in for the paired PHONE, so the
      bash test can drive the session-key bootstrap (a real device pubkey
      written to ctl/bind-device before the client's first stream connect --
      see RelayState.device_pubkey_b64 below) and later send-message
      commands step by step without a real device. Imports
      bin/lib/hmd_relay_e2e.py BY PATH (the same convention
      bin/heimdall-relay-client itself uses) -- never re-implements the
      crypto. See device_main() below for the action list.

CONTROL PROTOCOL (the --ctl DIR the "serve" stream handler polls):
  NNN.json      -- (numeric name, ascending) one Envelope (JSON object) to be
                   pushed, in filename order, down the currently-open hmd
                   stream connection -- built by `device envelope` below and
                   written to CTLDIR by the bash test, standing in for a
                   frame the paired phone "sent".
  bind-device   -- (written ONCE, before the server is asked to start a
                   stream -- NOT polled mid-stream) the paired phone's X25519
                   public key, base64, embedded in every device_bound frame's
                   payload.device_pubkey for this run. Absent -> a fixed,
                   valid, non-low-order fallback key is used instead (see
                   RelayState.device_pubkey_b64), so scenarios that never
                   drive a real device handshake (backoff/rate-limit timing)
                   still get a device_bound the client can derive a session
                   key from.
  drop-stream   -- (no content needed) consumed ONCE by the very next
                   /session/:id/stream connection ATTEMPT: that attempt is
                   refused before any response line is written (the raw
                   socket is closed), so bin/heimdall-relay-client's own
                   `_stream_loop` takes its "stream connect failed" branch
                   (http.client raises before `getresponse()` returns a
                   status) rather than the post-200 EOF branch -- the ONLY
                   one of the two that never resets `backoff_ms` on success,
                   which is what makes 3 induced drops read back as the exact
                   2000/4000/8000 doubling sequence (backoff resets to
                   BACKOFF_BASE_MS on every successful re-connect --
                   bin/heimdall-relay-client:499 -- so a mid-stream drop
                   AFTER a 200 would not compound the way a pre-response
                   refusal does).
  rate-limit-next=<secs> -- consumed ONCE by the next stream connection
                   attempt: answered with 429 + Retry-After: <secs> instead
                   of opening the stream.
  end-session   -- consumed by the ACTIVE stream loop (or, if none is open
                   yet, by the next one to open): pushes a `session_ended`
                   Envelope and ends the session.

Stdlib only (Decision 1 zero-toolchain posture) -- http.server, json, base64,
uuid, threading, argparse, importlib.
"""
import argparse
import base64
import json
import os
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.util import module_from_spec, spec_from_file_location
from urllib.parse import urlsplit, parse_qs

HERE = os.path.dirname(os.path.realpath(__file__))
REPO_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
E2E_PATH = os.path.join(REPO_ROOT, "bin", "lib", "hmd_relay_e2e.py")

# Mirrors the real Cloudflare relay's INV-16 cap -- see
# bin/heimdall-relay-client's own MAX_ENVELOPE_BYTES comment for the
# 2026-09-24 128 KiB -> 1 MiB raise this fixture stands in for.
MAX_ENVELOPE_BYTES = 1048576
NUM_JSON_RE = re.compile(r"^\d+\.json$")

# A fixed, valid (non-low-order), obviously-fake X25519 public key -- used as
# the device_bound payload's device_pubkey whenever a scenario never writes
# ctl/bind-device (see RelayState.device_pubkey_b64). Never a real key: the
# bytes 1..32 fill point is far from every documented X25519 low-order point
# (RFC 7748 section 5.9), so derive_session_key() never sees an all-zero
# shared secret from it.
_DEFAULT_DEVICE_PUBKEY = base64.b64encode(bytes(range(1, 33))).decode("ascii")


def _load_e2e():
    """Import bin/lib/hmd_relay_e2e.py by path -- the exact convention
    bin/heimdall-relay-client's own `_load_module` uses. Raises SystemExit
    with a clear message (never a bare traceback) when the module is absent
    or fails to import -- a `device` subcommand has no useful fallback
    without it."""
    if not os.path.isfile(E2E_PATH):
        sys.stderr.write("fake-relay: bin/lib/hmd_relay_e2e.py absent -- device "
                          "subcommands need it (server-only `serve` mode does not)\n")
        raise SystemExit(3)
    spec = spec_from_file_location("hmd_relay_e2e", E2E_PATH)
    mod = module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception as e:
        sys.stderr.write("fake-relay: bin/lib/hmd_relay_e2e.py failed to import: %s\n" % e)
        raise SystemExit(3)
    return mod


# ── private-key (de)serialization ────────────────────────────────────────────
# hmd_relay_e2e's public API deliberately has no priv_b64/priv_from_b64 (a real
# session's private key is "memory only, never a file, never argv" per
# bin/heimdall-relay-client's own docstring) -- but this test's `device`
# subcommands are one-shot processes, so the fake phone's OWN private key has
# to cross process boundaries between them via a bash variable. X25519 keys
# are inherently raw 32-byte scalars (RFC 7748), so the vendored module's
# generate_keypair() is expected to hand back plain `bytes` for both halves of
# the pair; the fallbacks below cover it handing back a key-object instead
# (e.g. a `cryptography` X25519PrivateKey) without assuming which.
def _priv_to_b64(priv):
    if isinstance(priv, (bytes, bytearray)):
        return base64.b64encode(bytes(priv)).decode("ascii")
    if hasattr(priv, "private_bytes_raw"):
        return base64.b64encode(priv.private_bytes_raw()).decode("ascii")
    if hasattr(priv, "private_bytes"):
        from cryptography.hazmat.primitives import serialization
        raw = priv.private_bytes(encoding=serialization.Encoding.Raw,
                                  format=serialization.PrivateFormat.Raw,
                                  encryption_algorithm=serialization.NoEncryption())
        return base64.b64encode(raw).decode("ascii")
    raise SystemExit("fake-relay: cannot serialize private key of type %r" % type(priv))


def _priv_from_b64(e2e, s):
    raw = base64.b64decode(s)
    if hasattr(e2e, "priv_from_raw"):
        return e2e.priv_from_raw(raw)
    if hasattr(e2e, "generate_keypair"):
        # The vendored X25519 (RFC 7748) path represents a private key as its
        # raw 32-byte clamped scalar directly -- hand the raw bytes straight
        # through; if the module actually wants an object wrapper instead,
        # derive_session_key() will raise and the caller sees a clear error
        # rather than a silently wrong key.
        return raw
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    return X25519PrivateKey.from_private_bytes(raw)


# ── serve mode ────────────────────────────────────────────────────────────────
class Session:
    def __init__(self, sid, token, pairing_code, exp):
        self.id = sid
        self.token = token
        self.pairing_code = pairing_code
        self.exp = exp
        self.lock = threading.Lock()
        self.ended = False


class RelayState:
    def __init__(self, log_dir, ctl_dir):
        self.log_dir = log_dir
        self.ctl_dir = ctl_dir
        self.sessions = {}
        self.lock = threading.Lock()
        os.makedirs(log_dir, exist_ok=True)
        os.makedirs(ctl_dir, exist_ok=True)
        self._req_log_lock = threading.Lock()
        self._frames_log_lock = threading.Lock()

    def device_pubkey_b64(self):
        """The device pubkey to embed in this session's `device_bound` frame --
        whatever the test wrote to ctl/bind-device (a real handshake scenario),
        or a fixed, valid, non-low-order fallback pubkey (any scenario that
        never calls a real device handshake, e.g. backoff/rate-limit timing
        tests) so `device_bound` -- and therefore this client's own successful
        key derivation -- is never gated on a bind that will never come."""
        p = os.path.join(self.ctl_dir, "bind-device")
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8") as f:
                val = f.read().strip()
            if val:
                return val
        return _DEFAULT_DEVICE_PUBKEY

    def new_session(self):
        sid = str(uuid.uuid4())
        token = base64.urlsafe_b64encode(os.urandom(24)).decode("ascii").rstrip("=")
        code = base64.b32encode(os.urandom(16)).decode("ascii").rstrip("=")
        exp = int(time.time()) + 60
        sess = Session(sid, token, code, exp)
        with self.lock:
            self.sessions[sid] = sess
        return sess

    def get(self, sid):
        with self.lock:
            return self.sessions.get(sid)

    def log_request(self, method, path, query, auth_present):
        token_query = "y" if "token" in parse_qs(query) else "n"
        line = "%s %s token_query=%s auth=%s\n" % (method, path, token_query,
                                                     "y" if auth_present else "n")
        with self._req_log_lock:
            with open(os.path.join(self.log_dir, "requests.log"), "a", encoding="utf-8") as f:
                f.write(line)

    def log_frame(self, raw_body):
        with self._frames_log_lock:
            with open(os.path.join(self.log_dir, "frames.ndjson"), "ab") as f:
                f.write(raw_body if raw_body.endswith(b"\n") else raw_body + b"\n")

    # ── one-shot control-file consumption (existence-based, deleted after use) ──
    def consume_drop_stream(self):
        p = os.path.join(self.ctl_dir, "drop-stream")
        if os.path.exists(p):
            try:
                os.remove(p)
            except OSError:
                return True
            return True
        return False

    def consume_rate_limit(self):
        try:
            names = os.listdir(self.ctl_dir)
        except OSError:
            return None
        for name in names:
            m = re.match(r"^rate-limit-next=(\d+)$", name)
            if m:
                try:
                    os.remove(os.path.join(self.ctl_dir, name))
                except OSError:
                    return int(m.group(1))
                return int(m.group(1))
        return None

    def consume_end_session(self):
        p = os.path.join(self.ctl_dir, "end-session")
        if os.path.exists(p):
            try:
                os.remove(p)
            except OSError:
                return True
            return True
        return False

    def pending_envelopes(self, seen):
        """Every ctl/NNN.json not yet in `seen`, ascending by numeric name --
        the device-authored frames still queued to be pushed down the
        currently-open stream."""
        try:
            names = sorted((n for n in os.listdir(self.ctl_dir) if NUM_JSON_RE.match(n)),
                           key=lambda n: int(n.split(".")[0]))
        except OSError:
            return []
        out = []
        for n in names:
            if n in seen:
                continue
            path = os.path.join(self.ctl_dir, n)
            try:
                with open(path, "r", encoding="utf-8") as f:
                    env = json.load(f)
            except (OSError, ValueError):
                continue  # not fully written yet -- retry next poll, never mark seen
            seen.add(n)
            out.append(env)
        return out


def _envelope_bytes(env):
    return (json.dumps(env, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fake-relay/1"

    def log_message(self, fmt, *args):
        return  # requests.log (STATE.log_request) is the log; stderr stays quiet

    # -- chunked-transfer helpers ---------------------------------------------
    def _chunk_send(self, data):
        self.wfile.write(("%x\r\n" % len(data)).encode("ascii") + data + b"\r\n")
        self.wfile.flush()

    def _chunk_end(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def _json(self, status, obj, headers=None):
        body = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _bearer(self):
        auth = self.headers.get("Authorization") or ""
        if auth.startswith("Bearer "):
            return auth[len("Bearer "):]
        return None

    def _parsed(self):
        return urlsplit(self.path)

    def _session_for(self, sid, method):
        parsed = self._parsed()
        token = self._bearer()
        STATE.log_request(method, parsed.path, parsed.query, token is not None)
        sess = STATE.get(sid)
        if sess is None:
            self._json(404, {"error": "unknown session"})
            return None
        if token is None or token != sess.token:
            self._json(401, {"error": "bad or missing bearer token"})
            return None
        return sess

    # -- routes ------------------------------------------------------------
    def do_POST(self):
        parsed = self._parsed()
        path = parsed.path
        if path == "/pair/init":
            STATE.log_request("POST", path, parsed.query, self._bearer() is not None)
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            sess = STATE.new_session()
            self._json(200, {"session_id": sess.id, "pairing_code": sess.pairing_code,
                             "relay_session_token": sess.token, "exp": sess.exp})
            return

        m = re.match(r"^/session/([^/]+)/frames$", path)
        if m:
            sid = m.group(1)
            length_hdr = self.headers.get("Content-Length")
            if length_hdr is not None and int(length_hdr) > MAX_ENVELOPE_BYTES:
                STATE.log_request("POST", path, parsed.query, self._bearer() is not None)
                self.rfile.read(int(length_hdr))
                self._json(413, {"error": "envelope exceeds %d bytes" % MAX_ENVELOPE_BYTES})
                return
            sess = self._session_for(sid, "POST")
            if sess is None:
                if length_hdr:
                    self.rfile.read(int(length_hdr))
                return
            raw = self.rfile.read(int(length_hdr or 0))
            if len(raw) > MAX_ENVELOPE_BYTES:
                self._json(413, {"error": "envelope exceeds %d bytes" % MAX_ENVELOPE_BYTES})
                return
            STATE.log_frame(raw)
            self._json(200, {"ok": True, "delivered": True})
            return

        m = re.match(r"^/session/([^/]+)/revoke$", path)
        if m:
            sid = m.group(1)
            length_hdr = self.headers.get("Content-Length")
            sess = self._session_for(sid, "POST")
            if length_hdr:
                self.rfile.read(int(length_hdr))
            if sess is None:
                return
            with sess.lock:
                sess.ended = True
            self._json(200, {"ok": True})
            return

        STATE.log_request("POST", path, parsed.query, self._bearer() is not None)
        self._json(404, {"error": "no such route"})

    def do_GET(self):
        parsed = self._parsed()
        path = parsed.path
        m = re.match(r"^/session/([^/]+)/stream$", path)
        if not m:
            STATE.log_request("GET", path, parsed.query, self._bearer() is not None)
            self._json(404, {"error": "no such route"})
            return
        sid = m.group(1)

        # drop-stream / rate-limit-next are consumed BEFORE the session/auth
        # check runs so a test can exercise them even against a session that
        # is otherwise perfectly healthy -- see the module docstring for why
        # a pre-response refusal (not a mid-stream close) is what makes the
        # backoff sequence compound.
        if STATE.consume_drop_stream():
            STATE.log_request("GET", path, parsed.query, self._bearer() is not None)
            self.close_connection = True
            return
        rl = STATE.consume_rate_limit()
        if rl is not None:
            STATE.log_request("GET", path, parsed.query, self._bearer() is not None)
            self._json(429, {"error": "rate limited"}, headers={"Retry-After": str(rl)})
            return

        sess = self._session_for(sid, "GET")
        if sess is None:
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            self._chunk_send(_envelope_bytes({
                "v": 1, "session_id": sess.id, "seq": 0, "sender": "relay",
                "type": "device_bound", "nonce": None, "ciphertext": None,
                "payload": {"device_pubkey": STATE.device_pubkey_b64(), "bound_at": int(time.time())},
            }))
            seen = set()
            while True:
                with sess.lock:
                    ended = sess.ended
                if ended or STATE.consume_end_session():
                    self._chunk_send(_envelope_bytes({
                        "v": 1, "session_id": sess.id, "seq": 0, "sender": "relay",
                        "type": "session_ended", "nonce": None, "ciphertext": None,
                        "payload": {"reason": "revoked"},
                    }))
                    self._chunk_end()
                    return
                pushed = False
                for env in STATE.pending_envelopes(seen):
                    self._chunk_send(_envelope_bytes(env))
                    pushed = True
                if STATE.consume_drop_stream():
                    # a drop induced WHILE this stream is already open: honor
                    # it as an abrupt close of the live connection too.
                    self.close_connection = True
                    return
                if not pushed:
                    time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return


STATE = None  # set by serve_main


def serve_main(argv):
    ap = argparse.ArgumentParser(prog="fake-relay.py serve")
    ap.add_argument("port", type=int)
    ap.add_argument("--log", required=True, metavar="DIR")
    ap.add_argument("--ctl", required=True, metavar="DIR")
    args = ap.parse_args(argv)

    global STATE
    STATE = RelayState(args.log, args.ctl)
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    httpd.daemon_threads = True
    try:
        httpd.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        return 0
    return 0


# ── device mode ───────────────────────────────────────────────────────────────
def _cmd_keygen(e2e, args):
    priv, pub = e2e.generate_keypair()
    print(json.dumps({"priv_b64": _priv_to_b64(priv), "pub_b64": e2e.pub_b64(pub)}))
    return 0


def _cmd_derive(e2e, args):
    priv = _priv_from_b64(e2e, args.dev_priv_b64)
    peer_pub = e2e.pub_from_b64(args.hmd_pub_b64)
    key = e2e.derive_session_key(priv, peer_pub, args.session_id)
    key_bytes = bytes(key) if isinstance(key, (bytes, bytearray)) else key
    print(json.dumps({"key_b64": base64.b64encode(key_bytes).decode("ascii")}))
    return 0


def _cmd_seal(e2e, args):
    key = base64.b64decode(args.key_b64)
    nonce, ciphertext = e2e.seal(key, args.seq, args.sender, args.text.encode("utf-8"))
    print(json.dumps({"nonce_b64": nonce, "ciphertext_b64": ciphertext}))
    return 0


def _cmd_open(e2e, args):
    key = base64.b64decode(args.key_b64)
    try:
        plaintext = e2e.open_(key, args.seq, args.sender, args.nonce_b64, args.ciphertext_b64)
    except e2e.E2EError as e:
        sys.stderr.write("fake-relay: open failed: %s\n" % e)
        return 1
    print(json.dumps({"plaintext_json": json.loads(plaintext.decode("utf-8"))}))
    return 0


def _cmd_envelope(e2e, args):
    env = {
        "v": 1, "session_id": args.session_id, "seq": args.seq, "sender": args.sender,
        "type": args.type, "nonce": args.nonce, "ciphertext": args.ciphertext,
        "payload": json.loads(args.payload_json) if args.payload_json else None,
    }
    print(json.dumps(env, sort_keys=True, separators=(",", ":")))
    return 0


def device_main(argv):
    ap = argparse.ArgumentParser(prog="fake-relay.py device")
    sub = ap.add_subparsers(dest="action", required=True)

    sub.add_parser("keygen").set_defaults(fn=_cmd_keygen)

    d = sub.add_parser("derive")
    d.add_argument("--dev-priv-b64", required=True)
    d.add_argument("--hmd-pub-b64", required=True)
    d.add_argument("--session-id", required=True)
    d.set_defaults(fn=_cmd_derive)

    s = sub.add_parser("seal")
    s.add_argument("--key-b64", required=True)
    s.add_argument("--seq", required=True, type=int)
    s.add_argument("--sender", required=True, choices=["hmd", "device"])
    s.add_argument("--text", required=True, help="plaintext JSON body to seal")
    s.set_defaults(fn=_cmd_seal)

    o = sub.add_parser("open")
    o.add_argument("--key-b64", required=True)
    o.add_argument("--seq", required=True, type=int)
    o.add_argument("--sender", required=True, choices=["hmd", "device"])
    o.add_argument("--nonce-b64", required=True)
    o.add_argument("--ciphertext-b64", required=True)
    o.set_defaults(fn=_cmd_open)

    e = sub.add_parser("envelope")
    e.add_argument("--session-id", required=True)
    e.add_argument("--seq", required=True, type=int)
    e.add_argument("--sender", required=True, choices=["hmd", "device", "relay"])
    e.add_argument("--type", required=True)
    e.add_argument("--nonce", required=True)
    e.add_argument("--ciphertext", required=True)
    e.add_argument("--payload-json", default=None)
    e.set_defaults(fn=_cmd_envelope)

    args = ap.parse_args(argv)
    e2e = _load_e2e()
    return args.fn(e2e, args)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "device":
        return device_main(argv[1:])
    if argv and argv[0] == "serve":
        return serve_main(argv[1:])
    sys.stderr.write("usage: fake-relay.py serve PORT --log DIR --ctl DIR | fake-relay.py device <action> ...\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""test/lib/relay_contract_replay.py -- hermetic replay of the shared relay wire-contract
fixtures (relay/contract/wire.json + relay/contract/vectors.json) against the REAL
bin/heimdall-relay-client and bin/lib/hmd_relay_e2e.py. Run by test/relay-contract-fixtures.test.sh.

The fixtures are consumed from two sides. The relay's own suites (relay/test/contract.spec.ts
drives the real Worker + Durable Object; relay/scripts/__tests__/contract-fixtures.test.mjs
opens every sealed frame with the JS crypto) prove the relay and the JS side honour them. This
file is hmd's side: it feeds what the relay and the phone send to the client's real handlers and
compares what the client sends back, byte for byte, with the fixture. A fixture that drifts from
the client, or a client that drifts from the fixture, fails here.

Hermetic by construction: no socket is opened. The client reaches the relay through exactly one
function, _connect(): pair/init and revoke (RelayClient._request), POST /frames (_FramesChannel, one
persistent keep-alive connection per sender since zero-lag Ask 3) and GET /stream (_open_stream) all
take their connection from it. _connect is replaced by a factory of in-memory keep-alive connections
that record every request and answer from the fixture; every other line of the client -- pair_init,
send_frame_envelope, the frame channels, _handle_envelope, _handle_command, _decide, revoke, the E2E
module, the inbox and decision stores -- is the shipped code. The replay counts REQUESTS, never
connections: a persistent connection carries several of them.

Only the two sources of randomness the client reaches are pinned, so its output is reproducible:
the keypair (the golden vectors.json seeds) and the two ids a command creates (the inbox record's
uuid and the approval request's id). Nothing is faked about what the client does with them.

Output follows the suite convention: "  ok   N. ..." / "  FAIL N. ..." lines and a final
"P passed, F failed" line. Exit 0 only when F == 0.
"""
import base64
import importlib.machinery
import importlib.util
import json
import os
import re
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
CLIENT_PATH = os.path.join(REPO, "bin", "heimdall-relay-client")
# HMD_RELAY_CONTRACT_WIRE points the replay at another wire.json: the suite uses it to prove the
# replay goes red on a fixture that has been tampered with (see test/relay-contract-fixtures.test.sh).
WIRE_PATH = os.environ.get("HMD_RELAY_CONTRACT_WIRE") or os.path.join(REPO, "relay", "contract", "wire.json")
VECTORS_PATH = os.path.join(REPO, "relay", "contract", "vectors.json")

PLACEHOLDER = re.compile(r"\$([a-z_]+)")


def load_client():
    """bin/heimdall-relay-client has no .py suffix, so it is loaded through an explicit loader."""
    loader = importlib.machinery.SourceFileLoader("hmd_relay_client", CLIENT_PATH)
    spec = importlib.util.spec_from_loader("hmd_relay_client", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def compact(obj):
    """The wire serialization every hmd and phone frame uses: compact separators, key order as
    stored (python's json and JS's JSON.stringify both keep insertion order)."""
    return json.dumps(obj, separators=(",", ":"))


def keypair_from_seed(e2e, seed_hex):
    """The client's own generate_keypair(), with its one source of randomness pinned to a seed."""
    seed = bytes.fromhex(seed_hex)
    real = e2e.secrets.token_bytes
    e2e.secrets.token_bytes = lambda n: seed
    try:
        return e2e.generate_keypair()
    finally:
        e2e.secrets.token_bytes = real


def b64url_nopad(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


class Fixture:
    """wire.json + vectors.json, with the `$name` placeholders resolved to concrete values."""

    def __init__(self, e2e, wire, vectors):
        self.e2e = e2e
        self.wire = wire
        self.vectors = vectors
        self.hmd_priv, self.hmd_pub = keypair_from_seed(e2e, vectors["hmdSeedHex"])
        self.device_priv, self.device_pub = keypair_from_seed(e2e, vectors["phnSeedHex"])
        self.computed = {
            "device_pubkey_b64url": b64url_nopad(self.device_pub),
            "hmd_pubkey_b64": e2e.pub_b64(self.hmd_pub),
        }
        self.session_id = self.value("session_id")
        # The session key as each side derives it. Never stored in a fixture: the sealed frames
        # opening under it is the proof that both derivations agree.
        self.hmd_key = e2e.derive_session_key(self.hmd_priv, self.device_pub, self.session_id)
        self.device_key = e2e.derive_session_key(self.device_priv, self.hmd_pub, self.session_id)

    def value(self, name):
        binding = self.wire["bindings"][name]
        return self.computed[binding["computed"]] if "computed" in binding else binding["example"]

    def instantiate(self, node):
        if isinstance(node, str):
            whole = PLACEHOLDER.fullmatch(node)
            if whole:
                return self.value(whole.group(1))
            return PLACEHOLDER.sub(lambda m: str(self.value(m.group(1))), node)
        if isinstance(node, list):
            return [self.instantiate(item) for item in node]
        if isinstance(node, dict):
            return {key: self.instantiate(item) for key, item in node.items()}
        return node

    def placeholders_in(self, node):
        if isinstance(node, str):
            return set(PLACEHOLDER.findall(node))
        if isinstance(node, list):
            return set().union(*[self.placeholders_in(item) for item in node]) if node else set()
        if isinstance(node, dict):
            return set().union(*[self.placeholders_in(item) for item in node.values()]) if node else set()
        return set()

    def seal(self, frame):
        """seal() of a fixture frame's plaintext, on the sending side's key."""
        wire = frame["wire"]
        sender = wire["sender"]
        key = self.hmd_key if sender == "hmd" else self.device_key
        return self.e2e.seal(key, wire["seq"], sender, compact(frame["plaintext"]).encode("utf-8"))

    def open_(self, frame):
        """open_() of a fixture frame's wire envelope, on the receiving side's key."""
        wire = frame["wire"]
        sender = wire["sender"]
        key = self.device_key if sender == "hmd" else self.hmd_key
        return self.e2e.open_(key, wire["seq"], sender, wire["nonce"], wire["ciphertext"])


class FakeSocket:
    """The socket the client touches on a connection: settimeout() when it reuses the connection,
    setsockopt() for TCP keepalive on a fresh one. It keeps what it was told and carries no bytes."""

    def __init__(self):
        self.timeout = None
        self.options = []

    def settimeout(self, value):
        self.timeout = value

    def setsockopt(self, *args):
        self.options.append(args)


class FakeResponse:
    def __init__(self, status, body):
        self.status = status
        self._body = body

    def read(self):
        return self._body


class FakeConn:
    """Stands in for the http.client connection _connect() hands out. Like the real one it is
    keep-alive: it takes any number of requests until close() -- which is how the client's
    persistent POST /frames channels use it -- and it "opens" its socket on the first request, as
    http.client does. Every request is recorded exactly as the client built it, tagged with the
    number of the connection it rode, and answered from the fixture."""

    def __init__(self, network, number):
        self.network = network
        self.number = number
        self.sock = None
        self.timeout = None
        self._response = None

    def connect(self):
        self.sock = FakeSocket()

    def close(self):
        self.sock = None

    def request(self, method, path, headers=None, body=None):
        if self.sock is None:
            self.connect()
        text = None if body is None else (body.decode("utf-8") if isinstance(body, bytes) else body)
        self.network.requests.append({"conn": self.number, "method": method, "path": path,
                                      "headers": dict(headers or {}), "body": text})
        status, payload = self.network.answers(method, path)
        self._response = FakeResponse(status, b"" if payload is None else json.dumps(payload).encode("utf-8"))

    def getresponse(self):
        return self._response


class FakeNetwork:
    """The client's one network seam: _connect(). `requests` is every request the client made, in
    order; the replay counts those, not `connections`, because a persistent connection carries several."""

    def __init__(self, answers):
        self.answers = answers
        self.requests = []
        self.connections = 0

    def connect(self, parsed, timeout=None, label="request"):
        self.connections += 1
        return FakeConn(self, self.connections)


class HandshakeAnswer:
    """What check_upgrade reads off the relay's answer to the upgrade request: a status and headers."""

    def __init__(self, status, headers):
        self.status = status
        self._headers = {name.lower(): value for name, value in headers.items()}

    def getheader(self, name, default=None):
        return self._headers.get(name.lower(), default)


class OneShotSocket:
    """A socket that has received `data` and nothing more; it keeps what it was told and what was sent."""

    def __init__(self, data):
        self.data = data
        self.timeout = None
        self.sent = b""

    def settimeout(self, value):
        self.timeout = value

    def recv(self, n):
        chunk, self.data = self.data[:n], self.data[n:]
        return chunk

    def sendall(self, data):
        self.sent += data


class Observed:
    def __init__(self):
        self.requests = []
        self.events = []
        self.inbox_texts = []
        self.decision = None
        self.silent_after_keepalive = None


def drive(mod, fx, root):
    """Plays one whole session through the real client, in the order the wire fixtures number it:
    pair/init, the relay's device_bound, a state frame, the phone's three commands, the first of
    them replayed, a relay keepalive, the stream open, revoke. Returns everything the client did."""
    wire = fx.wire
    obs = Observed()
    pair_response = fx.instantiate(wire["pair_init"]["response"]["body"])
    delivered = fx.instantiate(wire["frames_post"]["response_delivered"]["body"])
    revoked = fx.instantiate(wire["revoke"]["response"]["body"])

    def answers(method, path):
        if path == "/pair/init":
            return 200, pair_response
        if path.endswith("/frames"):
            return 200, delivered
        if path.endswith("/revoke"):
            return 200, revoked
        if method == "GET" and path.endswith("/stream"):
            return 200, None
        raise AssertionError("the client made a request the fixture does not know: %s %s" % (method, path))

    network = FakeNetwork(answers)
    mod.emit = obs.events.append

    args = mod.build_argparser().parse_args(
        ["--relay", fx.value("relay_url"), "--repo", root, "--ui-port", "1"])
    client = mod.RelayClient(args)
    client.priv, client.pub = fx.hmd_priv, fx.hmd_pub

    real_connect, mod._connect = mod._connect, network.connect
    try:
        if client.pair_init() != 0:
            raise AssertionError("pair_init did not return 0 against the fixture's /pair/init answer")

        client._handle_envelope(fx.instantiate(wire["stream"]["lines"]["device_bound"]))

        # The client adds hmd's own caps to this plaintext (zero-lag Ask 5), so the fixture's
        # sealed bytes -- caps included -- are what the POST body is compared with.
        state = fx.wire["frames"]["state"]["plaintext"]["state"]
        client.send_hmd_frame("state", {"state": state})

        # Pin the two ids a command creates, so the acks are reproducible: the inbox record's uuid and
        # the approval request's id. Both are restored before this function returns.
        real_uuid4, real_token_hex = mod.INBOX.uuid.uuid4, mod.DECISIONS.secrets.token_hex
        mod.INBOX.uuid.uuid4 = lambda: uuid.UUID(wire["frames"]["ack_send_message"]["plaintext"]["id"])
        request_id = wire["frames"]["command_decide_deny"]["plaintext"]["params"]["id"]
        mod.DECISIONS.secrets.token_hex = lambda n: request_id[len("p-"):]
        try:
            mod.DECISIONS.request(root, "Bash", "contract fixture approval", 60)
            for name in ("command_send_message", "command_decide_allow", "command_decide_deny"):
                envelope = json.loads(compact(wire["frames"][name]["wire"]))
                client._handle_envelope(envelope)
            # The phone's first command (seq 1) arrives again once seq 3 has been taken. It is a frame that
            # opens, so the replay guard's rejection is answered with a sealed refusal, never acted on.
            client._handle_envelope(json.loads(compact(wire["frames"]["command_send_message"]["wire"])))
        finally:
            mod.INBOX.uuid.uuid4, mod.DECISIONS.secrets.token_hex = real_uuid4, real_token_hex

        obs.inbox_texts = [row["text"] for row in mod.INBOX.list_pending(root)]
        obs.decision = mod.DECISIONS.decision_of(root, request_id)

        before = (len(network.requests), len(obs.events))
        client._handle_envelope(fx.instantiate(wire["stream"]["lines"]["keepalive"]))
        obs.silent_after_keepalive = (len(network.requests), len(obs.events)) == before

        # hmd's leg is one route with two transports: a request with no Upgrade header (what every client before
        # the WebSocket sends, and what HMD_RELAY_STREAM_TRANSPORT=ndjson still sends) and one that asks for it.
        real_transport, real_new_key = mod.STREAM_TRANSPORT, mod.WS.new_key
        mod.STREAM_TRANSPORT = "ndjson"
        client._open_stream()
        mod.STREAM_TRANSPORT, mod.WS.new_key = "auto", lambda: fx.value("ws_key")
        try:
            client._open_stream()
        finally:
            mod.STREAM_TRANSPORT, mod.WS.new_key = real_transport, real_new_key
        client.revoke()
    finally:
        mod._connect = real_connect
    obs.requests = network.requests
    return obs


def main():
    passed = failed = 0

    def check(cond, label, detail=None):
        nonlocal passed, failed
        n = passed + failed + 1
        if cond:
            passed += 1
            print("  ok   %d. %s" % (n, label))
        else:
            failed += 1
            print("  FAIL %d. %s" % (n, label))
            if detail is not None:
                print("       %s" % (detail,))

    print("relay-contract-fixtures (relay/contract/wire.json replayed against bin/heimdall-relay-client)")

    mod = load_client()
    check(mod.E2E is not None and mod.E2E.e2e_available(), "client: hmd_relay_e2e loads and passes its RFC self-tests")
    check(mod.INBOX is not None and mod.DECISIONS is not None, "client: inbox and decision stores load")
    check(mod.WS is not None, "client: the WebSocket codec (hmd_relay_ws) loads")
    if failed:
        print("\n%d passed, %d failed" % (passed, failed))
        return 1
    e2e = mod.E2E

    with open(VECTORS_PATH, encoding="utf-8") as fh:
        vectors = json.load(fh)
    with open(WIRE_PATH, encoding="utf-8") as fh:
        wire = json.load(fh)
    check(wire.get("contract") == "hmd-relay-wire" and wire.get("version") == 1,
          "fixture: wire.json is the hmd-relay-wire contract, version 1")

    # -- crypto: heimdall's pure-python E2E against the golden vector the app's @noble stack made --
    hmd_priv, hmd_pub = keypair_from_seed(e2e, vectors["hmdSeedHex"])
    phn_priv, phn_pub = keypair_from_seed(e2e, vectors["phnSeedHex"])
    check(hmd_pub.hex() == vectors["hmdPublicKeyHex"] and phn_pub.hex() == vectors["phnPublicKeyHex"],
          "golden vector: X25519 public keys from the two seeds match")
    golden_key = e2e.derive_session_key(hmd_priv, phn_pub, vectors["sessionId"])
    check(golden_key.hex() == vectors["sessionKeyHex"]
          and e2e.derive_session_key(phn_priv, hmd_pub, vectors["sessionId"]) == golden_key,
          "golden vector: HKDF session key matches from both sides")
    nonce_b64, ct_b64 = e2e.seal(golden_key, vectors["seq"], vectors["senderTag"],
                                 bytes.fromhex(vectors["plaintextHex"]))
    check(base64.b64decode(ct_b64).hex() == vectors["ciphertextHex"],
          "golden vector: ChaCha20-Poly1305 ciphertext+tag matches byte for byte")
    check(e2e.open_(golden_key, vectors["seq"], vectors["senderTag"], nonce_b64, ct_b64)
          == bytes.fromhex(vectors["plaintextHex"]), "golden vector: opens back to the plaintext")

    fx = Fixture(e2e, wire, vectors)

    # -- the fixture is internally honest ----------------------------------------------------------
    unbound = fx.placeholders_in({k: v for k, v in wire.items() if k not in ("about", "bindings")}) \
        - set(wire["bindings"])
    check(not unbound, "fixture: every $placeholder is bound", sorted(unbound))
    check(all(frame["wire"]["session_id"] == fx.session_id for frame in wire["frames"].values()),
          "fixture: every sealed frame carries the fixture session id the key was derived under")
    for name, frame in wire["frames"].items():
        nonce_b64, ct_b64 = fx.seal(frame)
        check((nonce_b64, ct_b64) == (frame["wire"]["nonce"], frame["wire"]["ciphertext"]),
              "sealed frame %s: python seal() of its plaintext reproduces the fixture bytes" % name,
              "expected nonce=%s ciphertext=%s" % (nonce_b64, ct_b64))
        try:
            opened = json.loads(fx.open_(frame))
        except e2e.E2EError as exc:
            opened = "open_ refused the frame: %s" % exc
        check(opened == frame["plaintext"],
              "sealed frame %s: opens on the receiving side to its plaintext" % name, opened)

    # -- the real client, driven with the fixture ----------------------------------------------------
    try:
        with tempfile.TemporaryDirectory() as root:
            obs = drive(mod, fx, root)
    except Exception as exc:  # a tampered fixture can make the client refuse a frame outright
        check(False, "client: the replay ran to the end", "%s: %s" % (type(exc).__name__, exc))
        print("\n%d passed, %d failed" % (passed, failed))
        return 1

    requests = obs.requests
    check(len(requests) == 9, "client: made exactly the nine requests the session implies, in order "
          "(pair/init, state, three acks, the refusal of the replay, stream, stream asking for a WebSocket, revoke)",
          [(r["method"], r["path"]) for r in requests])
    if len(requests) != 9:
        print("\n%d passed, %d failed" % (passed, failed))
        return 1
    (pair_call, state_call, ack_send, ack_allow, ack_deny, ack_refusal, stream_call, stream_ws_call,
     revoke_call) = requests

    def request_matches(call, template, label):
        want = fx.instantiate(template)
        got = {"method": call["method"], "path": call["path"], "headers": call["headers"]}
        exp = {"method": want["method"], "path": want["path"], "headers": want["headers"]}
        check(got == exp, "client: %s request line and headers match the fixture" % label, (got, exp))

    request_matches(pair_call, wire["pair_init"]["request"], "pair/init")
    check(pair_call["body"] == fx.instantiate(wire["pair_init"]["request"]["body"]),
          "client: pair/init sends an empty body")
    pair_event = next((e for e in obs.events if e.get("event") == "pair_init"), None)
    check(pair_event is not None and pair_event["qr"] == fx.instantiate(wire["pair_init"]["qr"]),
          "client: the QR payload it prints matches the fixture shape and values",
          pair_event and pair_event.get("qr"))

    frames_template = wire["frames_post"]["request"]
    for call, name in ((state_call, "state"), (ack_send, "ack_send_message"),
                       (ack_allow, "ack_decide_allow"), (ack_deny, "ack_decide_deny"),
                       (ack_refusal, "ack_non_increasing_seq")):
        request_matches(call, frames_template, "POST /frames (%s)" % name)
        check(call["body"] == compact(wire["frames"][name]["wire"]),
              "client: the %s frame it POSTs is byte-identical to the fixture" % name,
              "got %s" % call["body"])

    # The five frames are five requests on two connections: one persistent connection per sender,
    # so every ack after the first is a reused-connection POST (the client's own `post` event says so).
    posts = [e for e in obs.events if e.get("event") == "post"]
    check(ack_send["conn"] == ack_allow["conn"] == ack_deny["conn"] == ack_refusal["conn"] != state_call["conn"]
          and [e["reused"] for e in posts] == [False, False, True, True, True],
          "client: POST /frames keeps one persistent connection per sender -- the four acks shared one, "
          "the state frame has its own",
          {"connections": [c["conn"] for c in (state_call, ack_send, ack_allow, ack_deny, ack_refusal)],
           "reused": [e["reused"] for e in posts]})

    request_matches(stream_call, wire["stream"]["request"], "GET /stream (the bearer rides in a header)")

    # -- hmd's leg as a WebSocket: the request, the handshake, and the octets on the wire ----------------
    request_matches(stream_ws_call, wire["stream_ws"]["request"],
                    "GET /stream asking for a WebSocket (the same bearer beside the upgrade headers, key pinned)")
    ws, ws_fixture = mod.WS, wire["stream_ws"]
    answer = HandshakeAnswer(ws_fixture["response"]["status"], fx.instantiate(ws_fixture["response"]["headers"]))
    try:
        ws.check_upgrade(answer, fx.value("ws_key"))
        handshake = "valid"
    except ws.WsError as exc:
        handshake = "refused: %s" % exc
    check(handshake == "valid",
          "client: the fixture's 101 (Sec-WebSocket-Accept included) answers the key the client sent", handshake)
    ping = ws_fixture["frames"]["client_ping"]
    check(ws.encode_frame(ws.OP_TEXT, ws_fixture["messages"]["client_ping"].encode("utf-8"),
                          mask_key=bytes.fromhex(ping["mask"])).hex() == ping["hex"],
          "client: its ping is the fixture's octets, byte for byte")
    pong = ws_fixture["frames"]["relay_pong"]
    check(ws.Connection(OneShotSocket(bytes.fromhex(pong["hex"])), max_message=1000, max_total=1000).receive(1.0)
          == [("text", ws_fixture["messages"]["relay_pong"])],
          "client: the relay's pong octets read back as the text message the fixture names")
    bound_message = fx.instantiate(ws_fixture["messages"]["device_bound"])
    check(bound_message == fx.instantiate(wire["stream"]["lines"]["device_bound"]),
          "fixture: a WebSocket message is the NDJSON line's envelope, the same bytes without the newline")
    bound_text = compact(bound_message)
    bound_frame = bytes([0x81, 0x7E]) + len(bound_text).to_bytes(2, "big") + bound_text.encode("utf-8")
    check(ws.Connection(OneShotSocket(bound_frame), max_message=100000, max_total=100000).receive(1.0)
          == [("text", bound_text)],
          "client: the device_bound message the relay sends is read off the wire whole")

    revoke_template = wire["revoke"]["request"]
    request_matches(revoke_call, revoke_template, "revoke")
    check(revoke_call["body"] == fx.instantiate(revoke_template["body"]), "client: revoke sends an empty body")

    # -- what the client did with each frame it was handed ---------------------------------------------
    bound = next((e for e in obs.events if e.get("event") == "device_bound"), None)
    bound_line = fx.instantiate(wire["stream"]["lines"]["device_bound"])
    check(bound is not None and bound["bound_at"] == bound_line["payload"]["bound_at"],
          "client: device_bound on the hmd leg derives the key and reports bound_at", bound)

    commands = [e for e in obs.events if e.get("event") == "command"]
    wanted = []
    for name in ("ack_send_message", "ack_decide_allow", "ack_decide_deny", "ack_non_increasing_seq"):
        ack = wire["frames"][name]["plaintext"]
        wanted.append({"ok": ack["ok"], "detail": ack.get("detail")})
    check([{"ok": c["ok"], "detail": c["detail"]} for c in commands] == wanted
          and [c["action"] for c in commands] == ["send-message", "decide", "decide", None],
          "client: send-message, decide(allow) and decide(deny) each end as their fixture ack says, and the "
          "replay of the first is refused as the fixture says (no action: its plaintext is never read)", commands)
    check(obs.inbox_texts == [wire["frames"]["command_send_message"]["plaintext"]["params"]["text"]],
          "client: the send-message text reached the inbox", obs.inbox_texts)
    check(obs.decision == wire["frames"]["command_decide_deny"]["plaintext"]["params"]["decision"],
          "client: the phone's deny was recorded, and its allow was not", obs.decision)
    sent = next((e for e in obs.events if e.get("event") == "state_sent"), None)
    check(sent is not None and sent["seq"] == wire["frames"]["state"]["wire"]["seq"] and sent["delivered"] is True,
          "client: the state frame is reported sent at the fixture's seq", sent)
    check(obs.silent_after_keepalive is True,
          "client: a relay keepalive on the stream is skipped silently (no event, no request)")

    print("\n%d passed, %d failed" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

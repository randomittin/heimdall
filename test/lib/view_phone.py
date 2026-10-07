#!/usr/bin/env python3
"""test/lib/view_phone.py -- the paired PHONE for test/companion-view.test.sh.

The client under test runs as its own process (bin/heimdall-relay-client) against test/lib/fake-relay.py. This file does
only what a phone does: hold an X25519 key, derive the session key from the client's pair_init, seal a command under it,
hand it to the relay through the ctl directory the fake relay polls, and open the frames the relay logged
(frames.ndjson). It imports bin/lib/hmd_relay_e2e.py -- the codec, the way fake-relay.py's own `device` mode does -- and
never the client or bin/lib/companion_view.py.
"""
import json
import os
import time
from importlib.util import module_from_spec, spec_from_file_location

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", ".."))


def _load(name, path):
    spec = spec_from_file_location(name, path)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


E2E = _load("hmd_relay_e2e", os.path.join(REPO, "bin", "lib", "hmd_relay_e2e.py"))
FULL_CAPS = ["resync", "z-zlib", "view-v1"]


class Phone:
    def __init__(self, ctl, log):
        self.ctl = ctl
        self.frames_path = os.path.join(log, "frames.ndjson")
        self.priv, self.pub = E2E.generate_keypair()
        self.key = None
        self.session_id = None
        self.seq = 0
        self.nctl = 0
        self.frames = []  # every hmd frame opened so far, oldest first
        self._read = 0

    # -- pairing --------------------------------------------------------------------------------------------------
    def bind(self):
        """Before the client's first stream connect: the key the relay's device_bound frame will carry."""
        with open(os.path.join(self.ctl, "bind-device"), "w", encoding="utf-8") as f:
            f.write(E2E.pub_b64(self.pub))

    def pair(self, client_out, timeout=20):
        """Derive the session key from the client's pair_init, then wait for its device_bound. True when paired."""
        deadline = time.time() + timeout
        init, bound = None, False
        while time.time() < deadline and not (init and bound):
            try:
                with open(client_out, encoding="utf-8") as f:
                    events = [json.loads(line) for line in f if line.strip().startswith("{")]
            except (OSError, ValueError):
                events = []
            init = next((e for e in events if e.get("event") == "pair_init"), None)
            bound = any(e.get("event") == "device_bound" for e in events)
            time.sleep(0.1)
        if not (init and bound):
            return False
        self.session_id = init["qr"]["session_id"]
        self.key = E2E.derive_session_key(self.priv, E2E.pub_from_b64(init["qr"]["hmd_pubkey"]), self.session_id)
        return True

    # -- the relay's ctl queue ---------------------------------------------------------------------------------------
    def _queue(self, envelope):
        self.nctl += 1
        tmp = os.path.join(self.ctl, ".queue-%03d" % self.nctl)
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(json.dumps(envelope, sort_keys=True, separators=(",", ":")))
        os.rename(tmp, os.path.join(self.ctl, "%03d.json" % self.nctl))

    def command(self, obj, key=None, seq=None):
        """Seal `obj` as a device command and queue it. `key` / `seq` override the session key and the next seq."""
        if seq is None:
            self.seq += 1
            seq = self.seq
        plaintext = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        nonce, ciphertext = E2E.seal(key or self.key, seq, "device", plaintext)
        self._queue({"v": 1, "session_id": self.session_id, "seq": seq, "sender": "device", "type": "command",
                     "nonce": nonce, "ciphertext": ciphertext, "payload": None})
        return seq

    def rebind(self, other=False):
        """The relay's own device_bound frame again: with the same device key by default, which is what a stream reconnect looks like
        to the client, or with other=True the key of a device that was never paired (the relay claiming the session for someone else)."""
        pub = E2E.generate_keypair()[1] if other else self.pub
        self._queue({"v": 1, "session_id": self.session_id, "seq": 0, "sender": "relay", "type": "device_bound",
                     "nonce": "", "ciphertext": "",
                     "payload": {"device_pubkey": E2E.pub_b64(pub), "bound_at": int(time.time())}})

    # -- what the client sent -----------------------------------------------------------------------------------------
    def pull(self):
        try:
            with open(self.frames_path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            return
        for line in lines[self._read:]:
            self._read += 1
            env = json.loads(line)
            if env.get("sender") != "hmd":
                continue
            plain = E2E.open_(self.key, env["seq"], "hmd", env["nonce"], env["ciphertext"])
            first = json.loads(plain)
            inner = E2E.unpack_plaintext(plain)
            self.frames.append({"type": env["type"], "seq": env["seq"], "body": json.loads(inner),
                                "z": isinstance(first, dict) and "z" in first, "envelope_bytes": len(line),
                                "text": inner.decode("utf-8")})

    def mark(self):
        self.pull()
        return len(self.frames)

    def wait(self, pred, since=0, timeout=20):
        """The first frame at index >= since for which pred(frame) holds, or None after `timeout` seconds."""
        deadline = time.time() + timeout
        while True:
            self.pull()
            for frame in self.frames[since:]:
                if pred(frame):
                    return frame
            if time.time() >= deadline:
                return None
            time.sleep(0.1)

    def ack(self, seq, since=0, timeout=20):
        frame = self.wait(lambda f: f["type"] == "ack" and f["body"].get("of_seq") == seq, since=since, timeout=timeout)
        return None if frame is None else frame["body"]

    def state(self, pred=lambda state: True, since=0, timeout=20):
        frame = self.wait(lambda f: f["type"] == "state" and pred(f["body"]["state"]), since=since, timeout=timeout)
        return frame

    def resync(self, caps):
        """A resync listing `caps`; its digest never matches, so hmd answers with a fresh state frame."""
        before = self.mark()
        seq = self.command({"action": "resync", "params": {"last_seq": 0, "digest": "0" * 64, "caps": caps}})
        return self.ack(seq), before

    def view(self, params, timeout=20):
        """Seal a view command; -> (ack, result). `result` is the slice's result for params['rid'] when the ack was ok."""
        before = self.mark()
        ack = self.ack(self.command({"action": "view", "params": params}), timeout=timeout)
        if not ack or not ack.get("ok"):
            return ack, None
        rid = params.get("rid")
        frame = self.state(lambda s: ((s.get("views") or {}).get("result") or {}).get("id") == rid, since=before,
                           timeout=timeout)
        return ack, None if frame is None else frame["body"]["state"]["views"]["result"]

    def all_text(self):
        self.pull()
        return "\n".join(f["text"] for f in self.frames)

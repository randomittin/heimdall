#!/usr/bin/env bash
# test/hmd-relay-zlib-frames.test.sh
#
# Oracle for the zero-lag wire's Ask 5 on the relay channel -- the FINAL spec in hmdapp's
# docs/HANDOFF-TO-HEIMDALL-zero-lag-sync.md section 5 (zlib state frames, in-band capabilities, the
# resync command and its digest); hmdapp's docs/HANDBACK-FROM-HEIMDALL-zlib-frames.md records what
# hmd does with it. The codec lives in bin/lib/hmd_relay_e2e.py (hmd_caps / normalize_caps /
# compress_envelope / pack_plaintext / unpack_plaintext / canonical_state_json / state_digest); the
# negotiation and the one call site in bin/heimdall-relay-client (_resync, _adopt_device_caps,
# send_hmd_frame).
#
# The wire under test: every `state` frame's plaintext is
#   {"state": {...}, "caps": ["login-v1","push-v1","resync","z-zlib"]}         plain
#   {"z":"zlib","d":"<std base64 of zlib.compress(<the plain plaintext>)>"}    only for a phone whose
#                                         most recent sealed `resync` command listed "z-zlib"
# test/fixtures/hmdapp-zero-lag-vectors.json is the app's own vector file, vendored byte for byte
# (sha256 d8ad0bba...7de8; hmdapp src/transport/__tests__/fixtures/zero-lag-vectors.json, which its
# doc reproduces) -- case 20 decodes, digests and re-encodes against it.
#
# Codec cases (no network):
#   1.  round trip on a REAL state frame (sentinels/hmd-ui.py collect_state, relay transport)
#   2.  the envelope is standard base64 of a zlib-WITH-header stream; measured size reduction
#   3.  no "z-zlib" token (nothing / junk / other tokens / the old "zlib") -> plaintext unchanged
#   4.  size threshold: below stays plain, at it compresses, min_bytes honoured
#   5.  never larger: an incompressible payload above the threshold stays plain
#   6.  unpack: a frame with no top-level "z" is returned unchanged (a nested "z" is data)
#   7.  decompression bomb: output capped at the app's 2 MiB, never fully inflated
#   8.  everything the spec calls malformed fails closed (E2EError), nothing leaks a raw exception
#   9.  state_digest: pinned vector cross-checked against shasum, integral floats as ints
#   10. normalize_caps / hmd_caps
# Client cases (the REAL RelayClient driven in-process: real _handle_envelope / _handle_command /
# send_hmd_frame / seal, only the POST is recorded):
#   11. before any resync: plain frames, hmd's caps in every one; caps outside a resync are ignored
#   12. after a resync listing z-zlib: compressed frames that decode to the same bytes
#   13. a frame under the threshold stays plain even then
#   14. resync is acked ok, bad params acked bad-params; acks are never compressed
#   15. caps lifecycle: the latest resync replaces the set; bad params change nothing
#   16. only an AUTHENTICATED resync counts (device_bound payload / forged command / keepalive cannot)
#   17. device_bound forgets the phone's caps and forces a plain resend
#   18. resync digest: current -> no resend; stale / nothing sent -> full state forced; desync logged
#   19. seq stays strictly increasing and every frame opens under its own (seq, "hmd") nonce
#   20. a python without zlib: no z-zlib listed, plain frames
# Vectors + the real process:
#   21. the app's vectors: decode, digest, canonical, resync command; sealed vectors pinned
#   22. the real heimdall-relay-client against test/lib/fake-relay.py: plain, then compressed after a resync
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$REPO/bin/lib/hmd_relay_e2e.py"
CLIENT="$REPO/bin/heimdall-relay-client"
FAKE_RELAY="$REPO/test/lib/fake-relay.py"
VECTORS="$REPO/test/fixtures/hmdapp-zero-lag-vectors.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "hmd-relay-zlib-frames (zero-lag wire: zlib state frames, in-band caps, resync)"

for f in "$MOD" "$CLIENT" "$FAKE_RELAY" "$VECTORS"; do
  if [ ! -f "$f" ]; then
    printf '  FAIL %s is absent\n' "$f"
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  printf '  FAIL required tool missing: python3\n'
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

# ── sandbox: a throwaway HOME so collect_state() never reads the operator's roster/ledger ──
TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
mkdir -p "$HOME/.claude"
trap 'rm -rf "$TMPROOT"' EXIT

# Every python case gets this prelude (module loaded by path -- the convention
# bin/heimdall-relay-client itself uses) followed by its own body on stdin.
PRELUDE='
import base64, json, os, re, sys, time, zlib
from importlib.util import module_from_spec, spec_from_file_location
MOD, REPO, TMPROOT, VECTORS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
_spec = spec_from_file_location("hmd_relay_e2e", MOD)
e2e = module_from_spec(_spec)
_spec.loader.exec_module(e2e)
# stock zlib (1.2 / 1.3) reproduces compressed bytes exactly; a fork such as zlib-ng writes another valid stream
STOCK_ZLIB = re.fullmatch(r"1\.[23]\.\d+(\.\d+)?", zlib.ZLIB_RUNTIME_VERSION) is not None


def refused(fn, *args, **kwargs):
    """The E2EError fn(*args) raises. AssertionError when it returns, or raises anything else."""
    try:
        fn(*args, **kwargs)
    except e2e.E2EError as e:
        return e
    except Exception as e:
        raise AssertionError("raised %s instead of E2EError: %s" % (type(e).__name__, e))
    raise AssertionError("was accepted instead of refused")


def real_state():
    """The REAL collect_state() of this checkout with public-mode (relay transport) redaction applied --
    exactly the object bin/heimdall-relay-client seals. Collected once per run (~1 s), cached on disk."""
    cache = os.path.join(TMPROOT, "real-state.json")
    if os.path.exists(cache):
        with open(cache, encoding="utf-8") as f:
            return json.load(f)
    spec = spec_from_file_location("hmd_ui", os.path.join(REPO, "sentinels", "hmd-ui.py"))
    ui = module_from_spec(spec)
    spec.loader.exec_module(ui)
    state = ui.collect_state(REPO, {"bind": "relay", "public_host": "relay", "trust_proxy": False, "port": 0})
    with open(cache + ".tmp", "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(cache + ".tmp", cache)
    return state


def plain_frame(state):
    """The bytes send_hmd_frame serialises a state frame to before any packing: the state plus hmd'"'"'s caps."""
    return json.dumps({"state": state, "caps": e2e.hmd_caps(extra=[e2e.CAP_LOGIN, e2e.CAP_CONTROLS, "view-v1", "dash-v1", "ask-v1", "dash-alert-v1", "push-tile-alert-v1"])}, sort_keys=True, separators=(",", ":")).encode("utf-8")


def real_state_plaintext():
    return plain_frame(real_state())
'

# The REAL RelayClient, paired in-process with a fake phone through the real device_bound path.
RIG='
import argparse, contextlib, importlib.util, io, tempfile
from importlib.machinery import SourceFileLoader

NEVER = "0" * 64  # a well-formed digest that is never the digest of anything hmd sent


class Rig:
    """Only the POST is replaced: every frame the client would send is recorded as the phone would receive
    it, and `plaintext()` opens it with the key the phone derived -- the client then has exactly the
    state it has in production (session key, seq counter, device_caps, last_sent_state, event stream)."""

    def __init__(self, bind_extra=None):
        loader = SourceFileLoader("hmd_relay_client_zlib_rig", os.path.join(REPO, "bin", "heimdall-relay-client"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.mod = importlib.util.module_from_spec(spec)
        loader.exec_module(self.mod)
        self.E2E = self.mod.E2E
        self.out = io.StringIO()
        self.repo = tempfile.mkdtemp(prefix="zlib-rig-", dir=TMPROOT)
        args = argparse.Namespace(relay="http://127.0.0.1:1", repo=self.repo, ui_port=0, public_host=None,
                                  status_file=os.path.join(self.repo, "status.json"), tick_s=2.0)
        self.client = self.mod.RelayClient(args)
        self.client.session_id, self.client.token = "sess-zlib-rig", "token-zlib-rig"
        self.client.priv, self.client.pub = self.E2E.generate_keypair()
        self.dev_priv, self.dev_pub = self.E2E.generate_keypair()
        self.dev_seq = 0
        self.posts = []
        self.client.send_frame_envelope = self._post
        self.bind(bind_extra)
        self.dev_key = self.E2E.derive_session_key(self.dev_priv, self.client.pub, self.client.session_id)
        assert self.dev_key == self.client.session_key, "device_bound did not pair the client with the phone key"

    def _post(self, type_, nonce, ciphertext, seq, **kwargs):
        self.posts.append({"type": type_, "seq": seq, "nonce": nonce, "ciphertext": ciphertext})
        return True, len(ciphertext)

    def handle(self, env):
        with contextlib.redirect_stdout(self.out):
            self.client._handle_envelope(env)

    def bind(self, extra=None):
        payload = {"device_pubkey": self.E2E.pub_b64(self.dev_pub), "bound_at": 1}
        payload.update(extra or {})
        self.handle({"v": 1, "session_id": self.client.session_id, "seq": 0, "sender": "relay",
                     "type": "device_bound", "nonce": None, "ciphertext": None, "payload": payload})

    def command_text(self, text, key=None):
        """The phone sends `text` as its next sealed command (under `key`, default the paired one)."""
        self.dev_seq += 1
        nonce, ct = self.E2E.seal(key or self.dev_key, self.dev_seq, "device", text.encode("utf-8"))
        self.handle({"v": 1, "session_id": self.client.session_id, "seq": self.dev_seq, "sender": "device",
                     "type": "command", "nonce": nonce, "ciphertext": ct, "payload": None})

    def command(self, obj, key=None):
        self.command_text(json.dumps(obj), key=key)

    def resync(self, caps, digest=NEVER, last_seq=0, key=None):
        params = {"last_seq": last_seq, "digest": digest}
        if caps is not None:
            params["caps"] = caps
        self.command({"action": "resync", "params": params}, key=key)

    def send(self, type_, obj):
        with contextlib.redirect_stdout(self.out):
            return self.client.send_hmd_frame(type_, obj)

    def plaintext(self, post):
        return self.E2E.open_(self.dev_key, post["seq"], "hmd", post["nonce"], post["ciphertext"])

    def last(self, type_):
        return [p for p in self.posts if p["type"] == type_][-1]

    def ack(self):
        return json.loads(self.plaintext(self.last("ack")))

    def events(self, name):
        rows = (json.loads(line) for line in self.out.getvalue().splitlines() if line.strip())
        return [e for e in rows if e.get("event") == name]
'

# py_case NUM DESCRIPTION [rig]  (python body on stdin; stdout's last line, if any, is appended to the ok line)
py_case() {
  local num="$1" desc="$2" extra="" out
  [ "${3:-}" = "rig" ] && extra="$RIG"
  if { printf '%s\n%s\n' "$PRELUDE" "$extra"; cat; } | python3 - "$MOD" "$REPO" "$TMPROOT" "$VECTORS" >"$TMPROOT/case$num.out" 2>"$TMPROOT/case$num.err"; then
    out="$(tail -n 1 "$TMPROOT/case$num.out")"
    if [ -n "$out" ]; then ok "$num. $desc ($out)"; else ok "$num. $desc"; fi
  else
    bad "$num. $desc:"
    sed 's/^/       | /' "$TMPROOT/case$num.err"
  fi
}

# ═══ 1. round trip on a real state frame ════════════════════════════════════
py_case 1 "round trip: unpack_plaintext(pack_plaintext(real state frame, {z-zlib})) is the original bytes" <<'PYEOF'
plain = real_state_plaintext()
packed = e2e.pack_plaintext(plain, {"z-zlib"})
assert packed != plain, "a real state frame for a z-zlib phone must be compressed"
assert e2e.unpack_plaintext(packed) == plain, "round trip did not return the original plaintext"
print("%d B plaintext -> %d B sealed plaintext" % (len(plain), len(packed)))
PYEOF

# ═══ 2. wire shape + measured reduction ═════════════════════════════════════
py_case 2 "wire shape: {z:zlib,d:std-base64(zlib stream with header)}; real frame shrinks to <= 60%" <<'PYEOF'
plain = real_state_plaintext()
packed = e2e.pack_plaintext(plain, {"z-zlib"})
obj = json.loads(packed.decode("utf-8"))
assert list(obj) == ["z", "d"], "envelope keys/order must be exactly z then d, got %r" % list(obj)
assert obj["z"] == "zlib", obj["z"]
assert isinstance(obj["d"], str)
assert "-" not in obj["d"] and "_" not in obj["d"], "d must be STANDARD base64, not url-safe"
raw = base64.b64decode(obj["d"], validate=True)
assert base64.b64encode(raw).decode("ascii") == obj["d"] and len(obj["d"]) % 4 == 0, "d must be canonical padded base64"
assert raw[0] == 0x78, "zlib stream must carry its 2-byte header (0x78..), got %#x" % raw[0]
assert zlib.decompress(raw) == plain, "d must inflate to the plain plaintext"
assert packed == json.dumps(obj, separators=(",", ":")).encode("utf-8"), "envelope must be compact JSON"
assert packed == e2e.compress_envelope(plain), "pack_plaintext must emit exactly compress_envelope's bytes"
ratio = len(packed) / len(plain)
assert ratio <= 0.60, "sealed plaintext is %.1f%% of the original, expected <= 60%%" % (100 * ratio)
print("%d -> %d B (%.1f%%), zlib alone %d B" % (len(plain), len(packed), 100 * ratio, len(raw)))
PYEOF

# ═══ 3. no z-zlib token -> plaintext untouched ══════════════════════════════
py_case 3 "no z-zlib token (none / empty / other tokens / junk / the old \"zlib\") -> plaintext returned unchanged" <<'PYEOF'
plain = real_state_plaintext()
for caps in (None, (), frozenset(), set(), {"resync"}, ["resync"], "z-zlib", 7, {"zlib"}, {"Z-ZLIB"}, {"z-zlib2"},
             {b"z-zlib"}, {"delta"}):
    out = e2e.pack_plaintext(plain, caps)
    assert out == plain, "caps=%r still changed the plaintext" % (caps,)
assert e2e.pack_plaintext(plain, {"z-zlib", "resync", "delta", "unknown-token"}) != plain, "unknown tokens must be ignored"
PYEOF

# ═══ 4. size threshold ══════════════════════════════════════════════════════
py_case 4 "threshold: below COMPRESS_MIN_BYTES stays plain, at it compresses, min_bytes honoured" <<'PYEOF'
n = e2e.COMPRESS_MIN_BYTES
assert n == 2048, "the spec's reference encoder sends anything under 2048 bytes plain, got %r" % (n,)
head, tail = b"{\"state\":{\"log\":\"", b"\"}}"
at = (head + b"abcdef " * n + tail)[:n]
below = at[: n - 1]
assert len(at) == n and len(below) == n - 1
assert e2e.pack_plaintext(below, {"z-zlib"}) == below, "a frame under the threshold must not be compressed"
packed = e2e.pack_plaintext(at, {"z-zlib"})
assert packed != at and json.loads(packed)["z"] == "zlib", "a frame at the threshold must be compressed"
assert e2e.pack_plaintext(below, {"z-zlib"}, min_bytes=0) != below, "min_bytes=0 must compress the small frame"
assert e2e.pack_plaintext(at, {"z-zlib"}, min_bytes=n + 1) == at, "min_bytes above the size must leave it plain"
print("threshold %d B" % n)
PYEOF

# ═══ 5. never larger ════════════════════════════════════════════════════════
py_case 5 "never larger: an incompressible payload above the threshold stays plain" <<'PYEOF'
import secrets
plain = b"{\"state\":{\"blob\":\"" + base64.b64encode(secrets.token_bytes(8192)) + b"\"}}"
assert len(plain) > e2e.COMPRESS_MIN_BYTES
assert e2e.pack_plaintext(plain, {"z-zlib"}) == plain, "an incompressible frame must be sent as it is"
for _ in range(20):
    junk = b"{\"x\":\"" + base64.b64encode(secrets.token_bytes(900)) + b"\"}"
    got = e2e.pack_plaintext(junk, {"z-zlib"}, min_bytes=0)
    assert len(got) <= len(junk), "packed form larger than the original"
PYEOF

# ═══ 6. unpack: no top-level z -> unchanged ═════════════════════════════════
py_case 6 "unpack_plaintext: no top-level z -> unchanged (a nested z is data, not an envelope)" <<'PYEOF'
for blob in (b"{\"state\":{\"a\":1}}", b"{\"state\":{\"z\":\"zlib\",\"d\":\"AAAA\"}}", b"{\"action\":\"send-message\"}",
             b"{}", b"{\"ok\":true,\"of_seq\":3}", b"{\"state\":{},\"caps\":[\"resync\",\"z-zlib\"]}"):
    assert e2e.unpack_plaintext(blob) == blob, blob
PYEOF

# ═══ 7. decompression bomb ══════════════════════════════════════════════════
py_case 7 "decompression bomb: output capped at the app's 2 MiB, never inflated in full" <<'PYEOF'
import tracemalloc
cap = e2e.MAX_INFLATED_BYTES
assert cap == 2097152, "the app refuses an inner over 2,097,152 bytes; hmd must never send one, got %r" % (cap,)


def wrap(raw):
    d = base64.b64encode(zlib.compress(raw, 9)).decode("ascii")
    return json.dumps({"z": "zlib", "d": d}, separators=(",", ":")).encode("utf-8")


at_cap = b" " * cap
assert e2e.unpack_plaintext(wrap(at_cap)) == at_cap, "a frame inflating to exactly the cap must be accepted"
err = refused(e2e.unpack_plaintext, wrap(b" " * (cap + 1)))
assert "cap" in str(err), "the error should name the cap: %s" % err
assert e2e.pack_plaintext(b" " * (cap + 1), {"z-zlib"}) == b" " * (cap + 1), "hmd must not compress what the app would refuse"

# a ~100 MiB bomb (compresses to ~100 KB): refused fast, memory held near the cap
bomb = wrap(b"\0" * (100 << 20))
assert len(bomb) < 200_000, "fixture is not a bomb (%d B)" % len(bomb)
tracemalloc.start()
t0 = time.perf_counter()
refused(e2e.unpack_plaintext, bomb)
dt = time.perf_counter() - t0
peak = tracemalloc.get_traced_memory()[1]
tracemalloc.stop()
assert peak < cap + (8 << 20), "peak %d B: the bomb was inflated well past the %d B cap" % (peak, cap)
assert dt < 2.0, "refusing the bomb took %.2fs" % dt
refused(e2e.unpack_plaintext, wrap(b"x" * 5000), max_bytes=4096)  # the caller's cap is honoured too
print("cap %d B, 100 MiB bomb refused in %.0f ms, peak %.1f MiB" % (cap, dt * 1000, peak / 1048576))
PYEOF

# ═══ 8. malformed envelopes fail closed ═════════════════════════════════════
py_case 8 "malformed envelopes -> E2EError (unknown z, bad/missing d, bad base64, bad stream, empty, nested)" <<'PYEOF'
inner = b"{\"state\":{\"a\":1}}"
good_raw = zlib.compress(inner, 1)
good_d = base64.b64encode(good_raw).decode("ascii")
assert e2e.unpack_plaintext(json.dumps({"z": "zlib", "d": good_d}).encode()) == inner
nested = e2e.compress_envelope(inner)  # an envelope as the INNER of an envelope
bad = {
    "z gzip": {"z": "gzip", "d": good_d},
    "z deflate-raw": {"z": "deflate-raw", "d": good_d},
    "z upper case": {"z": "ZLIB", "d": good_d},
    "z a number": {"z": 1, "d": good_d},
    "z null": {"z": None, "d": good_d},
    "z a list": {"z": ["zlib"], "d": good_d},
    "d missing": {"z": "zlib"},
    "d not a string": {"z": "zlib", "d": 12},
    "d empty": {"z": "zlib", "d": ""},
    "d not base64": {"z": "zlib", "d": "not base64 !!"},
    "d url-safe alphabet": {"z": "zlib", "d": base64.urlsafe_b64encode(b"\xfb\xff\xfe" * 8).decode()},
    "d unpadded": {"z": "zlib", "d": good_d.rstrip("=") if good_d.endswith("=") else good_d[:-1]},
    "d not a zlib stream": {"z": "zlib", "d": base64.b64encode(b"hello world, definitely not deflate").decode()},
    "d truncated": {"z": "zlib", "d": base64.b64encode(good_raw[:-6]).decode("ascii")},
    "d trailing bytes": {"z": "zlib", "d": base64.b64encode(good_raw + b"\x00junk").decode("ascii")},
    "raw deflate, no header": {"z": "zlib", "d": base64.b64encode(zlib.compress(inner)[2:-4]).decode("ascii")},
    "inflates to nothing": {"z": "zlib", "d": base64.b64encode(zlib.compress(b"")).decode("ascii")},
    "envelope inside envelope": json.loads(e2e.compress_envelope(nested)),
}
for name, obj in bad.items():
    try:
        refused(e2e.unpack_plaintext, json.dumps(obj).encode("utf-8"))
    except AssertionError as e:
        raise AssertionError("%s: %s" % (name, e))
for name, blob in (("not json", b"\xff\xfe not json"), ("json array", b"[1,2]"), ("json null", b"null")):
    try:
        out = e2e.unpack_plaintext(blob)
    except e2e.E2EError:
        continue
    assert out == blob, "%s: must be returned unchanged or refused, got %r" % (name, out)
PYEOF

# ═══ 9. state_digest ════════════════════════════════════════════════════════
# The resync digest (spec 5.4): sha256 hex of json.dumps(normalize(state), sort_keys=True,
# separators=(",", ":"), ensure_ascii=False). The expected value is computed here by shasum over the
# canonical text written out by hand -- not by the code under test.
CANON='{"a":"é","b":[1,2,{"c":null}],"z":"x\"y"}'
WANT_DIGEST="$(printf '%s' "$CANON" | shasum -a 256 | awk '{print $1}')"
py_case 9 "state_digest(state) == sha256 hex of the canonical JSON; an integral float hashes as its int" <<PYEOF
want = "$WANT_DIGEST"
state = {"z": 'x"y', "b": [1, 2, {"c": None}], "a": "é"}
got = e2e.state_digest(state)
assert got == want, "state_digest %s != shasum %s" % (got, want)
assert e2e.canonical_state_json(state) == '{"a":"é","b":[1,2,{"c":null}],"z":"x\\\\"y"}'
assert len(got) == 64 and got == got.lower()
assert e2e.state_digest({"a": 1, "b": 2}) == e2e.state_digest({"b": 2, "a": 1}), "key order must not matter"
assert e2e.state_digest({"a": 1}) != e2e.state_digest({"a": 2})
assert e2e.state_digest({"n": [1.0, -0.0, 2.5, [3.0], {"k": 4.0}]}) == e2e.state_digest({"n": [1, 0, 2.5, [3], {"k": 4}]}), \
    "JavaScript cannot tell 1.0 from 1: an integral float must hash as its int"
assert e2e.state_digest({"n": 1.5}) != e2e.state_digest({"n": 1}), "a non-integral float is hashed as written"
lone = e2e.state_digest({"a": "\ud800"})  # a JSON file can carry one; it must not wedge the send loop
assert len(lone) == 64 and lone != e2e.state_digest({"a": "\ud801"}), "lone surrogates must hash, distinctly"
print(got[:16] + "...")
PYEOF

# ═══ 10. normalize_caps / hmd_caps ══════════════════════════════════════════
py_case 10 "normalize_caps: the string entries of an array, else the empty set; hmd_caps lists push-v1 + resync + z-zlib, plus the caller's extra (login-v1)" <<'PYEOF'
assert e2e.normalize_caps(["z-zlib", "resync"]) == frozenset({"z-zlib", "resync"})
assert e2e.normalize_caps(("z-zlib",)) == frozenset({"z-zlib"})
assert e2e.normalize_caps(["z-zlib", 7, None, "", {"x": 1}, ["z-zlib"], "x" * 33]) == frozenset({"z-zlib"})
for junk in (None, "z-zlib", "z-zlib,resync", {"z-zlib": True}, 7, True, b"z-zlib", object()):
    assert e2e.normalize_caps(junk) == frozenset(), "%r must be the empty set" % (junk,)
many = ["cap%d" % i for i in range(1000)]
assert len(e2e.normalize_caps(many)) == e2e.MAX_CAPS, "an advertised list must be bounded"
assert e2e.CAP_ZLIB == "z-zlib" and e2e.CAP_RESYNC == "resync" and e2e.ENC_ZLIB == "zlib"
assert e2e.hmd_caps() == ["push-v1", "resync", "z-zlib"], e2e.hmd_caps()
assert e2e.CAP_PUSH == "push-v1"
os.environ["HMD_PUSH"] = "0"  # the operator's kill switch withdraws the cap
try:
    assert e2e.hmd_caps() == ["resync", "z-zlib"], e2e.hmd_caps()
    assert not e2e.push_enabled()
finally:
    del os.environ["HMD_PUSH"]
assert e2e.push_enabled() and e2e.hmd_caps(push=False) == ["resync", "z-zlib"], "a caller without a push store lists none"
os.environ["HMD_PUSH"] = "1"
try:
    assert e2e.push_enabled() and "push-v1" in e2e.hmd_caps(), "only the exact value 0 is the switch"
finally:
    del os.environ["HMD_PUSH"]
# the two optional features compose: login-v1 rides in on the caller's `extra`, push-v1 on `push` and the switch
assert e2e.hmd_caps(extra=[e2e.CAP_LOGIN]) == ["login-v1", "push-v1", "resync", "z-zlib"], e2e.hmd_caps(extra=[e2e.CAP_LOGIN])
assert e2e.hmd_caps([e2e.CAP_LOGIN], push=False) == ["login-v1", "resync", "z-zlib"], "login-v1 is the first positional, push a keyword"
os.environ["HMD_PUSH"] = "0"
try:
    assert e2e.hmd_caps(extra=[e2e.CAP_LOGIN]) == ["login-v1", "resync", "z-zlib"], "the push switch must leave login-v1 alone"
finally:
    del os.environ["HMD_PUSH"]
PYEOF

# ═══ 11. before any resync: plain frames ════════════════════════════════════
py_case 11 "client: until a resync lists z-zlib every state frame is plain and carries hmd's caps" rig <<'PYEOF'
rig = Rig()
state = real_state()
assert rig.client.device_caps == frozenset(), "a fresh client must assume the oldest phone"
rig.send("state", {"state": state})
got = rig.plaintext(rig.last("state"))
assert got == plain_frame(state), "before a resync the frame must be exactly the plain {state, caps}"
obj = json.loads(got)
assert "z" not in obj and obj["caps"] == ["ask-v1", "controls-v1", "dash-alert-v1", "dash-v1", "login-v1", "push-tile-alert-v1", "push-v1", "resync", "view-v1", "z-zlib"] and obj["state"] == state
# caps outside a resync command are not the handshake: a send-message that carries them changes nothing
rig.command({"action": "send-message", "params": {"text": "no handshake here"}, "caps": ["z-zlib"]})
rig.command({"action": "decide", "params": {"id": "p-0", "decision": "deny"}, "caps": ["z-zlib"]})
assert rig.client.device_caps == frozenset() and rig.events("device_caps") == []
rig.send("state", {"state": state})
assert rig.plaintext(rig.last("state")) == plain_frame(state)
print("%d B plaintext sealed as is, caps %s" % (len(got), obj["caps"]))
PYEOF

# ═══ 12. after a resync listing z-zlib: compressed frames ═══════════════════
py_case 12 "client: after a resync listing z-zlib a state frame is compressed and decodes to the same bytes" rig <<'PYEOF'
rig = Rig()
state = real_state()
rig.send("state", {"state": state})
plain_post = rig.last("state")
rig.resync(["z-zlib", "resync"])
assert rig.client.device_caps == frozenset({"z-zlib", "resync"})
assert rig.events("device_caps") == [{"event": "device_caps", "caps": ["resync", "z-zlib"]}]
assert rig.ack() == {"ok": True, "of_seq": 1}, "a resync must be acked ok"
rig.send("state", {"state": state})
post = rig.last("state")
got = rig.plaintext(post)
obj = json.loads(got)
assert obj["z"] == "zlib" and list(obj) == ["z", "d"], "expected the envelope, got keys %r" % list(obj)
assert rig.E2E.unpack_plaintext(got) == plain_frame(state), "the envelope must inflate to the plain frame"
assert zlib.decompress(base64.b64decode(obj["d"])) == plain_frame(state)
inner = json.loads(zlib.decompress(base64.b64decode(obj["d"])))
assert inner["caps"] == ["ask-v1", "controls-v1", "dash-alert-v1", "dash-v1", "login-v1", "push-tile-alert-v1", "push-v1", "resync", "view-v1", "z-zlib"], "the inner plaintext still carries hmd's caps"
before, after = len(plain_post["ciphertext"]), len(post["ciphertext"])
assert after < 0.6 * before, "sealed ciphertext went %d -> %d B, expected <= 60%%" % (before, after)
print("envelope ciphertext %d -> %d B (%.1f%%)" % (before, after, 100.0 * after / before))
PYEOF

# ═══ 13. threshold at the client ════════════════════════════════════════════
py_case 13 "client: a frame under the threshold stays plain even for a z-zlib phone" rig <<'PYEOF'
rig = Rig()
rig.resync(["z-zlib"])
rig.send("state", {"state": {"a": 1}})
assert rig.plaintext(rig.last("state")) == plain_frame({"a": 1}), "a tiny frame must stay plain"
assert len(plain_frame({"a": 1})) < e2e.COMPRESS_MIN_BYTES
rig.send("state", {"state": real_state()})
assert json.loads(rig.plaintext(rig.last("state")))["z"] == "zlib", "a real-sized frame must still compress"
PYEOF

# ═══ 14. resync ack; acks never compressed ══════════════════════════════════
py_case 14 "client: resync is acked ok, bad params are acked bad-params, acks are never compressed" rig <<'PYEOF'
rig = Rig()
rig.resync(["z-zlib"], last_seq=0)
assert rig.ack() == {"ok": True, "of_seq": 1}
rig.command({"action": "resync", "params": {"last_seq": -1, "digest": NEVER, "caps": ["z-zlib"]}})
assert rig.ack() == {"ok": False, "of_seq": 2, "detail": "bad-params"}
for i, params in enumerate((None, [], {}, {"last_seq": 0}, {"digest": NEVER}, {"last_seq": True, "digest": NEVER},
                            {"last_seq": 1.5, "digest": NEVER}, {"last_seq": "1", "digest": NEVER},
                            {"last_seq": 0, "digest": "ABCDEF" + "0" * 58}, {"last_seq": 0, "digest": "0" * 63},
                            {"last_seq": 0, "digest": "0" * 65}, {"last_seq": 0, "digest": "g" * 64},
                            {"last_seq": 0, "digest": 7}), start=3):
    rig.command({"action": "resync", "params": params})
    assert rig.ack() == {"ok": False, "of_seq": i, "detail": "bad-params"}, (params, rig.ack())
assert rig.client.device_caps == {"z-zlib"}, "a refused resync must not change the caps"
rig.send("ack", {"ok": False, "of_seq": 9, "detail": "x" * 4000})
big = rig.plaintext(rig.last("ack"))
assert len(big) > e2e.COMPRESS_MIN_BYTES and "z" not in json.loads(big) and json.loads(big)["of_seq"] == 9
PYEOF

# ═══ 15. caps lifecycle ═════════════════════════════════════════════════════
py_case 15 "client: each valid resync replaces the phone's set; unchanged sets are not re-logged" rig <<'PYEOF'
rig = Rig()
rig.resync(["z-zlib", "resync"])
assert rig.client.device_caps == {"z-zlib", "resync"}
rig.resync(["resync", "z-zlib"])
assert len(rig.events("device_caps")) == 1, "an unchanged set must not be logged again"
rig.resync(["resync"])
assert rig.client.device_caps == {"resync"}, "the latest resync replaces the set"
rig.resync(["z-zlib", "delta", "never-heard-of-it"])
assert rig.client.device_caps == {"z-zlib", "delta", "never-heard-of-it"}, "unknown tokens are ignored, not an error"
rig.resync("z-zlib")
assert rig.client.device_caps == frozenset(), "caps that is not an array lists nothing"
rig.resync(["z-zlib"])
rig.resync([])
assert rig.client.device_caps == frozenset(), "an empty array clears the set"
rig.resync(["z-zlib"])
rig.resync(None)  # no caps key at all
assert rig.client.device_caps == frozenset(), "a resync without caps lists nothing"
assert [e["caps"] for e in rig.events("device_caps")] == [
    ["resync", "z-zlib"], ["resync"], ["delta", "never-heard-of-it", "z-zlib"], [], ["z-zlib"], [], ["z-zlib"], []]
PYEOF

# ═══ 16. only an authenticated resync counts ════════════════════════════════
py_case 16 "client: caps in device_bound's plaintext, a forged resync or a relay frame are ignored" rig <<'PYEOF'
rig = Rig(bind_extra={"caps": ["z-zlib"]})  # the relay's own unencrypted control frame
assert rig.client.device_caps == frozenset(), "device_bound is unauthenticated: its caps must not count"
rig.bind({"caps": ["z-zlib", "resync"]})
assert rig.client.device_caps == frozenset()
rig.resync(["z-zlib"], key=os.urandom(32))  # does not open under the session key
assert rig.client.device_caps == frozenset(), "a command that fails to decrypt must not list anything"
ack = rig.ack()
assert ack["ok"] is False and ack["detail"] == "decrypt-failed", ack
rig.handle({"v": 1, "session_id": rig.client.session_id, "seq": 0, "sender": "relay", "type": "keepalive",
            "nonce": None, "ciphertext": None, "payload": {"caps": ["z-zlib"], "ts": 1}})
rig.handle({"v": 1, "session_id": rig.client.session_id, "seq": 5, "sender": "relay", "type": "state",
            "nonce": None, "ciphertext": None, "payload": {"caps": ["z-zlib"]}})
assert rig.client.device_caps == frozenset()
rig.send("state", {"state": real_state()})
assert "z" not in json.loads(rig.plaintext(rig.last("state"))), "no authenticated resync -> plain"
PYEOF

# ═══ 17. device_bound forgets the caps ══════════════════════════════════════
py_case 17 "client: device_bound forgets the phone's caps, forces a resend, and the next frame is plain" rig <<'PYEOF'
rig = Rig()
state = real_state()
rig.resync(["z-zlib"])
rig.send("state", {"state": state})
assert json.loads(rig.plaintext(rig.last("state")))["z"] == "zlib"
rig.client.last_sent_digest = "abc"
rig.bind()  # the same device_pubkey again
assert rig.client.device_caps == frozenset(), "device_bound must forget the phone's caps"
assert rig.client.last_sent_digest is None, "a rebind must still force the next tick to resend"
assert rig.events("device_caps")[-1] == {"event": "device_caps", "caps": []}
rig.send("state", {"state": state})
assert rig.plaintext(rig.last("state")) == plain_frame(state)
rig.resync(["z-zlib"])
rig.send("state", {"state": state})
assert json.loads(rig.plaintext(rig.last("state")))["z"] == "zlib", "a new resync turns compression back on"
PYEOF

# ═══ 18. resync digest ══════════════════════════════════════════════════════
py_case 18 "client: resync digest of the last sent state -> no resend; stale or nothing sent -> full state forced" rig <<'PYEOF'
state = real_state()
rig = Rig()
rig.send("state", {"state": state})
current = rig.E2E.state_digest(state)
rig.client.last_sent_digest = "sentinel"
rig.resync(["z-zlib"], digest=current)
assert rig.client.last_sent_digest == "sentinel", "a phone that already holds the last sent state needs no resend"
assert rig.ack()["ok"] is True
rig.resync(["z-zlib"], digest="f" * 64)
assert rig.client.last_sent_digest is None, "a digest that is not the last sent state's forces a full state frame"
fresh = Rig()
fresh.client.last_sent_digest = "sentinel"
fresh.resync(["z-zlib"], digest=current)
assert fresh.client.last_sent_digest is None, "with nothing sent yet, any digest is stale"
# the app's own resync command, verbatim from its vector file, against the state its vector frame carries
fx = json.load(open(VECTORS, encoding="utf-8"))
vstate = json.loads(fx["frame"]["plaintext"])["state"]
rig = Rig()
rig.send("state", {"state": vstate})
rig.client.last_sent_digest = "sentinel"
rig.command_text(fx["resync"]["command"])
assert rig.client.device_caps == {"z-zlib", "resync"}, rig.client.device_caps
assert rig.ack() == {"ok": True, "of_seq": 1}
assert rig.client.last_sent_digest == "sentinel", "the vector digest IS the digest of the vector state: no resend"
rig.send("state", {"state": {**vstate, "repo": "other"}})
rig.command_text(fx["resync"]["command"])
assert rig.client.last_sent_digest is None, "the vector digest is stale once another state was sent"
# last_seq at or above hmd's next seq: desynced, surfaced, acked ok, the counter untouched
rig = Rig()
next_seq = rig.client.hmd_seq
rig.resync(["z-zlib"], last_seq=next_seq + 10)
errors = [e["detail"] for e in rig.events("error")]
assert any("desynced" in d for d in errors), errors
assert rig.ack()["ok"] is True and rig.client.hmd_seq == next_seq + 1, "only the ack itself advanced the counter"
rig = Rig()
rig.resync(["z-zlib"], last_seq=0)
assert not [e for e in rig.events("error") if "desynced" in e["detail"]], "a phone below hmd's seq is in sync"
PYEOF

# ═══ 19. seq / nonce invariants ═════════════════════════════════════════════
py_case 19 "client: seq strictly increasing across plain/compressed/ack frames; each opens under its own nonce" rig <<'PYEOF'
rig = Rig()
state = real_state()
rig.send("state", {"state": state})
rig.resync(["z-zlib"])
rig.send("state", {"state": state})
rig.send("state", {"state": {"a": 1}})
rig.resync([])
rig.send("state", {"state": state})
seqs = [p["seq"] for p in rig.posts]
assert seqs == list(range(seqs[0], seqs[0] + len(seqs))), "hmd seqs must be consecutive and increasing: %r" % (seqs,)
kinds = []
for p in rig.posts:
    body = json.loads(rig.plaintext(p))  # raises E2EError if the (seq, "hmd") nonce / tag does not match
    kinds.append(p["type"] + (":z" if "z" in body else ""))
assert kinds == ["state", "ack", "state:z", "state", "ack", "state"], kinds
print(" ".join(kinds))
PYEOF

# ═══ 20. no zlib in this python ═════════════════════════════════════════════
py_case 20 "client: a python without zlib lists only resync (and push-v1, login-v1) and sends plain whatever the phone listed" rig <<'PYEOF'
rig = Rig()
rig.E2E.zlib = None  # what `import zlib` failing leaves behind
assert rig.E2E.hmd_caps() == ["push-v1", "resync"], "hmd must not list z-zlib when it cannot compress"
rig.resync(["z-zlib"])
state = real_state()
rig.send("state", {"state": state})
got = rig.plaintext(rig.last("state"))
assert json.loads(got)["caps"] == ["ask-v1", "controls-v1", "dash-alert-v1", "dash-v1", "login-v1", "push-tile-alert-v1", "push-v1", "resync", "view-v1"] and "z" not in json.loads(got)
assert got == json.dumps({"state": state, "caps": ["ask-v1", "controls-v1", "dash-alert-v1", "dash-v1", "login-v1", "push-tile-alert-v1", "push-v1", "resync", "view-v1"]}, sort_keys=True, separators=(",", ":")).encode("utf-8")
try:
    rig.E2E.compress_envelope(plain_frame(state))
except rig.E2E.E2EError as e:
    assert "zlib" in str(e), e
else:
    raise AssertionError("compress_envelope without zlib must refuse")
try:
    rig.E2E.unpack_plaintext(e2e.compress_envelope(plain_frame(state)))  # the rig's own copy lost its zlib
except rig.E2E.E2EError as e:
    assert "zlib" in str(e), e
else:
    raise AssertionError("a python without zlib must refuse an envelope, not return it undecoded")
PYEOF

# ═══ 21. the app's vectors ══════════════════════════════════════════════════
# test/fixtures/hmdapp-zero-lag-vectors.json is hmdapp's own vector file, generated there by
# scripts/gen-zero-lag-vectors.py from the Python standard library alone. The decoder must reproduce
# frame.plaintext; the encoder need only produce an envelope that inflates to what it meant (compressed
# bytes are not canonical across zlib builds) -- here it is also byte-identical on a stock zlib. The sealed
# values pinned below are hmd_relay_e2e.seal's output for those same bytes under key 00..1f, cross-checked
# against `cryptography`'s ChaCha20Poly1305 (independent of the pure-python one) when pinned.
py_case 21 "the app's vectors: decode, digests, canonical, resync command; encoder byte-identical; sealed vectors pinned" <<'PYEOF'
fx = json.load(open(VECTORS, encoding="utf-8"))
frame = fx["frame"]
plain, envelope = frame["plaintext"].encode("utf-8"), frame["envelope"].encode("utf-8")
assert e2e.unpack_plaintext(envelope) == plain, "decoding frame.envelope must reproduce frame.plaintext"
assert zlib.decompress(base64.b64decode(json.loads(envelope)["d"], validate=True)) == plain
mine = e2e.compress_envelope(plain)
assert e2e.unpack_plaintext(mine) == plain, "the encoder's envelope must inflate to what it meant"
if STOCK_ZLIB:
    assert mine == envelope, "stock zlib %s no longer reproduces frame.envelope byte for byte" % zlib.ZLIB_RUNTIME_VERSION
assert e2e.pack_plaintext(plain, {"z-zlib"}) == plain, "the vector frame is far under the threshold: sent plain"
state = json.loads(frame["plaintext"])["state"]
assert e2e.state_digest(state) == frame["state_sha256"], "frame.state_sha256"
for row in fx["digests"]:
    st = json.loads(row["state_json"])
    assert e2e.canonical_state_json(st) == row["canonical"], row["name"]
    assert e2e.state_digest(st) == row["sha256"], row["name"]
resync = json.loads(fx["resync"]["command"])
assert resync["action"] == "resync" and resync["params"]["digest"] == frame["state_sha256"]
assert e2e.normalize_caps(resync["params"]["caps"]) == frozenset({"z-zlib", "resync"})
assert resync["params"]["last_seq"] == fx["resync"]["last_seq"] == 7
KEY = bytes(range(32))
assert KEY.hex() == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
CT_FRAME = ("P+ppeoAoAzJBZIGH/0i8gufIeagfStnsb+q3q34B4OPO0juHqEuaD0u2oUc1OLsnbPbDE+YmW0QW5CkBVsEyHJL6d0P4Ax+IOqnV"
            "SrHHBM7/AB+3VlR7USB5/XrU2FX2i0Xth+EeYJKM8LsjfMFUixBX6zokujBc1VrjjIlknlvEB5oyAeZ7xPCEZxrWZGHRio/6R0tR1g==")
nonce, ct = e2e.seal(KEY, 7, "hmd", envelope)
assert nonce == "aG1kAAAAAAAAAAAH" and base64.b64decode(nonce).hex() == "686d64000000000000000007", nonce
assert ct == CT_FRAME, "seal(key 00..1f, seq 7, hmd, frame.envelope) changed: %s" % ct
assert len(base64.b64decode(ct)) == len(envelope) + 16, "ciphertext is the plaintext plus a 16-byte tag"
assert e2e.unpack_plaintext(e2e.open_(KEY, 7, "hmd", nonce, ct)) == plain, "open -> inflate must give frame.plaintext"
CT_RESYNC = ("bDSDeLriEoQUT0dHtPHaDTFdqau1UgcVU1KQCOiQ9N9QLOkyDn9070iazV+NiiSLU1TyPte37jxqRHtLrqu9HdXKvlaQNQ3D8Gg0"
             "Bkk0YjTL3A+D2Kq9Y1/dTUJMtRTlKQkZisBxaPtuUiY+eAgF+eOeJyjWr9FYv+fxaMI5evTT/799yHAPKdb5GUHtzkBOjg6NTODD"
             "7PJmarP5vRkCc8eq")
rn, rc = e2e.seal(KEY, 1, "device", fx["resync"]["command"].encode("utf-8"))
assert rn == "cGhuAAAAAAAAAAAB" and base64.b64decode(rn).hex() == "70686e000000000000000001", rn
assert rc == CT_RESYNC, "seal(key 00..1f, seq 1, device, resync.command) changed: %s" % rc
assert e2e.open_(KEY, 1, "device", rn, rc) == fx["resync"]["command"].encode("utf-8")
print("zlib %s, encoder %s frame.envelope" % (zlib.ZLIB_RUNTIME_VERSION, "reproduces" if mine == envelope else "differs from (valid)"))
PYEOF

# ═══ 22. the real process ═══════════════════════════════════════════════════
py_case 22 "real heimdall-relay-client vs fake-relay: plain, then compressed (and decodable) after a z-zlib resync" <<'PYEOF'
import socket, subprocess, threading

work = os.path.join(TMPROOT, "int")
repo, logd, ctl = (os.path.join(work, d) for d in ("repo", "log", "ctl"))
for d in (repo, logd, ctl):
    os.makedirs(d)
subprocess.run(["git", "init", "-q", repo], check=True)
dev_priv, dev_pub = e2e.generate_keypair()
with open(os.path.join(ctl, "bind-device"), "w", encoding="utf-8") as f:
    f.write(e2e.pub_b64(dev_pub))
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()
env = dict(os.environ, HMD_RELAY_EVENT_LOG="")
relay = subprocess.Popen([sys.executable, os.path.join(REPO, "test", "lib", "fake-relay.py"), "serve", str(port),
                          "--log", logd, "--ctl", ctl], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
client = None
events = []


def frames(type_):
    try:
        with open(os.path.join(logd, "frames.ndjson"), encoding="utf-8") as f:
            rows = [json.loads(line) for line in f if line.strip()]
    except OSError:
        return []
    return [r for r in rows if r.get("sender") == "hmd" and r.get("type") == type_]


def wait(what, pred, secs=40):
    deadline = time.time() + secs
    while time.time() < deadline:
        got = pred()
        if got:
            return got
        time.sleep(0.1)
    raise AssertionError("timed out waiting for %s; client events: %r" % (what, events[-8:]))


try:
    for _ in range(100):
        probe = socket.socket()
        if probe.connect_ex(("127.0.0.1", port)) == 0:
            probe.close()
            break
        probe.close()
        time.sleep(0.05)
    client = subprocess.Popen([sys.executable, os.path.join(REPO, "bin", "heimdall-relay-client"),
                               "--relay", "http://127.0.0.1:%d" % port, "--repo", repo, "--ui-port", "0",
                               "--tick-s", "0.3"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    threading.Thread(target=lambda: [events.append(json.loads(l)) for l in client.stdout if l.strip()],
                     daemon=True).start()
    pair = wait("pair_init", lambda: next((e for e in events if e.get("event") == "pair_init"), None))
    sid, hmd_pub = pair["qr"]["session_id"], pair["qr"]["hmd_pubkey"]
    key = e2e.derive_session_key(dev_priv, e2e.pub_from_b64(hmd_pub), sid)

    def read(env_):
        return e2e.open_(key, env_["seq"], "hmd", env_["nonce"], env_["ciphertext"])

    first = wait("the first state frame", lambda: (frames("state") or [None])[0])
    first_plain = read(first)
    obj = json.loads(first_plain)
    assert "z" not in obj and obj["caps"] == ["ask-v1", "controls-v1", "dash-alert-v1", "dash-v1", "login-v1", "push-tile-alert-v1", "push-v1", "resync", "view-v1", "z-zlib"] and "schema_version" in obj["state"], \
        "before any resync the frame must be plain and list hmd's caps"

    # the phone saw `resync` in hmd's caps: it sends its resync, listing z-zlib, with a digest hmd never sent
    command = {"action": "resync", "params": {"last_seq": first["seq"], "digest": "0" * 64, "caps": ["z-zlib", "resync"]}}
    nonce, ct = e2e.seal(key, 1, "device", json.dumps(command).encode("utf-8"))
    with open(os.path.join(ctl, "001.json"), "w", encoding="utf-8") as f:
        json.dump({"v": 1, "session_id": sid, "seq": 1, "sender": "device", "type": "command",
                   "nonce": nonce, "ciphertext": ct, "payload": None}, f)
    wait("device_caps", lambda: next((e for e in events if e.get("event") == "device_caps"), None))
    assert [e["caps"] for e in events if e.get("event") == "device_caps"] == [["resync", "z-zlib"]]
    ack = wait("the resync ack", lambda: next((read(a) for a in frames("ack")), None))
    assert json.loads(ack) == {"ok": True, "of_seq": 1}, ack
    packed = wait("a compressed state frame (the stale digest forces a full state)",
                  lambda: next((f for f in frames("state") if f["seq"] > first["seq"] and b'"z"' in read(f)[:8]), None))
    wrapper = read(packed)
    inner = json.loads(e2e.unpack_plaintext(wrapper))
    assert inner["caps"] == ["ask-v1", "controls-v1", "dash-alert-v1", "dash-v1", "login-v1", "push-tile-alert-v1", "push-v1", "resync", "view-v1", "z-zlib"] and "schema_version" in inner["state"], "decoded frame must be a full state"
    assert len(wrapper) < 0.6 * len(first_plain), "%d -> %d" % (len(first_plain), len(wrapper))
    sent = [e for e in events if e.get("event") == "state_sent"]
    assert sent[0]["bytes"] > sent[-1]["bytes"] and all(e["delivered"] for e in sent), sent
    print("first frame %d B plain, then %d B compressed (envelopes %d -> %d B)"
          % (len(first_plain), len(wrapper), sent[0]["bytes"], sent[-1]["bytes"]))
finally:
    if client is not None:
        client.terminate()
        client.wait(timeout=20)
    relay.terminate()
    relay.wait(timeout=20)
PYEOF

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] && exit 0 || exit 1

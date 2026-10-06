#!/usr/bin/env bash
# test/companion-cc-login-e2e.test.sh -- remote Claude Code login (login-v1), end to end and hermetic:
# the REAL bin/lib/companion_cc_login.py driving a FAKE `claude` (test/lib/fake-claude.py, first on PATH)
# over a real PTY, reached through the REAL bin/heimdall-relay-client's sealed command path (the Rig below
# pairs a RelayClient with a fake phone exactly as test/hmd-relay-zlib-frames.test.sh does). Nothing here
# runs the real login flow, touches the keychain or opens a socket: the fake's whole world is a temp dir.
#
# The fake replays docs/samples/login/cc-2.1.288-transcript.txt (the 2.1.288 CLI's output up to the paste
# prompt; reconstructed from its authLogin code path and the S1 spike's byte layout, PKCE and client values
# replaced by runs of one letter) and then behaves as the 2.1.288 CLI does when it reads the pasted line.
# Every code-shaped value is assembled at run time (secrets.token_urlsafe), never stored in a file.
#
# Cases (the handoff's RL7 list, plus the safety properties):
#   transcript fidelity; happy path claudeai and console; wrong code; the CLI's `Invalid code` answer; a
#   code without #STATE is refused before it is spent; one code per id; expiry and the group kill (also
#   when SIGTERM is ignored); a URL off the allowlist (host, redirect) never reaches the phone; noise and a
#   split URL; no URL; one login at a time (dup, busy across roots, rate limit); every refusal; account pin
#   (mismatch logs the account out again, --pin-next); verify-failed, no-result, exited; cancel; shutdown;
#   orphan sweep; probe; the probe loop; the laptop CLI; state.login only for a phone that listed login-v1;
#   the code never appears on stdout, in relay-events.jsonl, relay.json, $HEIMDALL_HOME or any sealed frame
#   (also when the CLI itself echoes it), and the detector is shown to be able to fail.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$REPO/bin/lib/companion_cc_login.py"
CLIENT="$REPO/bin/heimdall-relay-client"
E2E_MOD="$REPO/bin/lib/hmd_relay_e2e.py"
FAKE="$REPO/test/lib/fake-claude.py"
TRANSCRIPT="$REPO/docs/samples/login/cc-2.1.288-transcript.txt"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "companion-cc-login-e2e (fake claude over a real PTY, through the relay client's sealed command path)"

for f in "$MOD" "$CLIENT" "$E2E_MOD" "$FAKE" "$TRANSCRIPT"; do
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

# A throwaway HOME so collect_state() and the relay client never read the operator's roster, ledger or
# remote-login.json, and so the fake's `~/.claude` lives under the sandbox.
TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
mkdir -p "$HOME/.claude"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR
trap 'rm -rf "$TMPROOT"' EXIT

# Guard: this suite must never run the REAL claude. Anything on this script's own PATH named `claude` is a
# shim that refuses (the fake worlds below build their own PATH, with the fake first, so they are unaffected).
mkdir -p "$TMPROOT/guard"
printf '#!/bin/sh\necho "BLOCKED: the real claude must never run in the login test suite" >&2\nexit 99\n' >"$TMPROOT/guard/claude"
chmod +x "$TMPROOT/guard/claude"
export PATH="$TMPROOT/guard:$PATH"

cat >"$TMPROOT/prelude.py" <<'PYEOF'
import argparse, atexit, importlib.util, io, json, os, re, secrets, select, signal, subprocess, sys, tempfile, time
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_file_location

REPO, TMPROOT = sys.argv[1], sys.argv[2]
FAKE = os.path.join(REPO, "test", "lib", "fake-claude.py")
CLIENT = os.path.join(REPO, "bin", "heimdall-relay-client")
LOGIN_PATH = os.path.join(REPO, "bin", "lib", "companion_cc_login.py")
TRANSCRIPT = os.path.join(REPO, "docs", "samples", "login", "cc-2.1.288-transcript.txt")
REAL_STDOUT = sys.stdout

_spec = spec_from_file_location("companion_cc_login", LOGIN_PATH)
m = module_from_spec(_spec)
_spec.loader.exec_module(m)

OWNER = "owner@example.test"
OTHER = "someone-else@example.test"
ORG = "11111111-2222-3333-4444-555555555555"
OWNER_MASK = "o…@example.test"
NEVER = "0" * 64


def wait_for(pred, timeout=15.0, what="the condition"):
    end = time.monotonic() + timeout
    while True:
        value = pred()
        if value:
            return value
        if time.monotonic() > end:
            raise AssertionError("timed out after %.0fs waiting for %s" % (timeout, what))
        time.sleep(0.02)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def refused(fn, *args, **kwargs):
    """The LoginError code fn(*args) raised; AssertionError when it returned or raised something else."""
    try:
        fn(*args, **kwargs)
    except m.LoginError as e:
        return e.code
    except Exception as e:
        raise AssertionError("raised %s instead of LoginError: %s" % (type(e).__name__, e))
    raise AssertionError("was accepted instead of refused")


class World:
    """One throwaway machine: a fake `claude` first on PATH, its store, a HOME, a HEIMDALL_HOME, a repo."""

    def __init__(self, mode="happy", signed_in=True, pinned=True, pin_next=False, enabled=True,
                 account=OWNER, env_extra=None):
        self.base = tempfile.mkdtemp(prefix="login-world-", dir=TMPROOT)
        self.bin = os.path.join(self.base, "bin")
        self.fake = os.path.join(self.base, "fake")
        self.home = os.path.join(self.base, "home")
        self.repo = os.path.join(self.base, "repo")
        for d in (self.bin, self.fake, self.home, self.repo):
            os.makedirs(d)
        os.symlink(FAKE, os.path.join(self.bin, "claude"))
        self.hh = os.path.join(self.home, ".heimdall")
        # code-shaped input, assembled at run time -- the repo never holds a literal one
        self.code = secrets.token_urlsafe(32)
        self.state = secrets.token_urlsafe(32)
        self.full = self.code + "#" + self.state
        owner = {"loggedIn": True, "authMethod": "claude.ai", "email": OWNER, "orgId": ORG, "orgName": "Owner Org"}
        self.write_store(owner if signed_in else {"loggedIn": False})
        self.env = {"PATH": self.bin + os.pathsep + "/usr/bin:/bin", "HOME": self.home, "HEIMDALL_HOME": self.hh,
                    "FAKE_CLAUDE_DIR": self.fake, "FAKE_CLAUDE_MODE": mode, "FAKE_CLAUDE_EXPECT": self.full,
                    "FAKE_CLAUDE_ACCOUNT_EMAIL": account, "FAKE_CLAUDE_ACCOUNT_ORG": ORG}
        self.env.update(env_extra or {})
        self.owner_fp = m.identity_fingerprint(owner)
        if enabled:
            m.write_config(self.hh, True, pin=self.owner_fp if pinned else None, pin_next=pin_next)
        atexit.register(self.cleanup)

    def write_store(self, obj):
        with open(os.path.join(self.fake, "store.json"), "w", encoding="utf-8") as f:
            json.dump(obj, f)

    def store(self):
        with open(os.path.join(self.fake, "store.json"), encoding="utf-8") as f:
            return json.load(f)

    def calls(self):
        try:
            with open(os.path.join(self.fake, "calls.log"), encoding="utf-8") as f:
                return f.read().splitlines()
        except OSError:
            return []

    def logins(self):
        return [c for c in self.calls() if c.startswith("login ")]

    def pid(self, name):
        try:
            with open(os.path.join(self.fake, name), encoding="utf-8") as f:
                return int(f.read())
        except (OSError, ValueError):
            return None

    def manager(self, events=None, **tunables):
        mgr = m.LoginManager(self.hh, self.env, emit=(events.append if events is not None else None))
        for key, value in tunables.items():
            setattr(mgr, key, value)
        return mgr

    def gone(self, what="the CLI and its helper"):
        """True once the fake CLI's whole process group is gone (waits for it)."""
        pids = [p for p in (self.pid("login.pid"), self.pid("child.pid")) if p]
        wait_for(lambda: not any(alive(p) for p in pids), timeout=10, what=what + " to exit")
        if self.pid("login.pid"):
            wait_for(lambda: not group_alive(self.pid("login.pid")), timeout=10, what="its process group to be empty")
        return True

    def cleanup(self):
        for name in ("login.pid", "child.pid"):
            pid = self.pid(name)
            if pid:
                for kill in (lambda: os.killpg(pid, signal.SIGKILL), lambda: os.kill(pid, signal.SIGKILL)):
                    try:
                        kill()
                    except (ProcessLookupError, PermissionError):
                        continue


def request_of(mgr):
    return mgr.snapshot()["request"]


def result_of(mgr):
    return mgr.snapshot()["result"]


def started(mgr, kind="claudeai"):
    """Starts a login and waits for its authorize URL; returns (id, request)."""
    rid = mgr.start(kind)["id"]
    return rid, wait_for(lambda: request_of(mgr), what="the authorize URL")


class StubCache:
    """The one thing RelayClient._tick_once reads from the real StateCache."""

    def __init__(self, state):
        self.state = state

    def latest(self):
        return self.state, "stub-digest"


class Rig:
    """The REAL RelayClient, paired in-process with a fake phone through the real device_bound path. Only the
    POST is replaced: every frame the client would send is recorded and opened with the phone's key. All of
    emit()'s output, from any thread, lands in `out` (and in the event log file, as in production)."""

    def __init__(self, w, phone_caps=("login-v1", "resync", "z-zlib")):
        for key, value in w.env.items():
            os.environ[key] = value  # the manager's env is the relay client's own environment
        loader = SourceFileLoader("hmd_relay_client_login_rig", CLIENT)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.mod = importlib.util.module_from_spec(spec)
        loader.exec_module(self.mod)
        self.E2E = self.mod.E2E
        self.w = w
        self.out = io.StringIO()
        sys.stdout = self.out
        self.mod.configure_event_log(w.repo)
        self.status_path = os.path.join(w.repo, "relay.json")
        args = argparse.Namespace(relay="http://127.0.0.1:1", repo=w.repo, ui_port=0, public_host=None,
                                  status_file=self.status_path, tick_s=2.0)
        self.client = self.mod.RelayClient(args)
        self.client.session_id, self.client.token = "sess-login-rig", "token-login-rig"
        self.client.priv, self.client.pub = self.E2E.generate_keypair()
        self.dev_priv, self.dev_pub = self.E2E.generate_keypair()
        self.dev_seq = 0
        self.posts = []
        self.client.send_frame_envelope = self._post
        self.client.cache = StubCache({"schema_version": 1, "ts": 1, "sessions": []})
        self.bind()
        self.dev_key = self.E2E.derive_session_key(self.dev_priv, self.client.pub, self.client.session_id)
        assert self.dev_key == self.client.session_key, "device_bound did not pair the client with the phone key"
        if phone_caps is not None:
            self.resync(list(phone_caps))

    @property
    def mgr(self):
        return self.client._login_manager()

    def _post(self, type_, nonce, ciphertext, seq, **kwargs):
        self.posts.append({"type": type_, "seq": seq, "nonce": nonce, "ciphertext": ciphertext})
        return True, len(ciphertext)

    def handle(self, env):
        self.client._handle_envelope(env)

    def bind(self):
        payload = {"device_pubkey": self.E2E.pub_b64(self.dev_pub), "bound_at": 1}
        self.handle({"v": 1, "session_id": self.client.session_id, "seq": 0, "sender": "relay",
                     "type": "device_bound", "nonce": None, "ciphertext": None, "payload": payload})

    def command(self, obj):
        self.dev_seq += 1
        nonce, ct = self.E2E.seal(self.dev_key, self.dev_seq, "device", json.dumps(obj).encode("utf-8"))
        self.handle({"v": 1, "session_id": self.client.session_id, "seq": self.dev_seq, "sender": "device",
                     "type": "command", "nonce": nonce, "ciphertext": ct, "payload": None})

    def cmd(self, action, params):
        """The phone's sealed command; returns the ack the client sealed back."""
        self.command({"action": action, "params": params})
        return self.ack()

    def resync(self, caps):
        self.command({"action": "resync", "params": {"last_seq": 0, "digest": NEVER, "caps": caps}})

    def plaintext(self, post):
        return self.E2E.open_(self.dev_key, post["seq"], "hmd", post["nonce"], post["ciphertext"])

    def ack(self):
        return json.loads(self.plaintext([p for p in self.posts if p["type"] == "ack"][-1]))

    def all_plaintexts(self):
        return [self.plaintext(p) for p in self.posts]

    def login(self):
        """Forces one state frame and returns its state.login (None when the frame carries none)."""
        self.client._rearm_state()
        self.client._tick_once()
        post = [p for p in self.posts if p["type"] == "state"][-1]
        obj = json.loads(self.E2E.unpack_plaintext(self.plaintext(post)))
        self.last_frame = obj
        return obj["state"].get("login")

    def events(self, name):
        rows = []
        for line in self.out.getvalue().splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("event") == name:
                rows.append(row)
        return rows

    def event_log(self):
        path = os.path.join(self.w.repo, ".heimdall", "app", "relay-events.jsonl")
        with open(path, encoding="utf-8") as f:
            return f.read()


def tree_bytes(path):
    chunks = []
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                with open(os.path.join(root, name), "rb") as f:
                    chunks.append(f.read())
            except OSError:
                continue
    return b"\n".join(chunks)


def leaks_of(rig, w):
    """Where the first 12 characters of the code appear among everything hmd wrote or sent."""
    needle = w.code[:12].encode()
    haystacks = {"stdout capture": rig.out.getvalue().encode(),
                 "$HEIMDALL_HOME": tree_bytes(w.hh),
                 "repo tree (relay.json, relay-events.jsonl)": tree_bytes(w.repo),
                 "sealed hmd frames": b"\n".join(rig.all_plaintexts())}
    assert b'"event"' in haystacks["repo tree (relay.json, relay-events.jsonl)"], "the event log was never written: the check would be vacuous"
    return [where for where, data in haystacks.items() if needle in data]


def transcript_url():
    with open(TRANSCRIPT, "rb") as f:
        text = f.read().decode("utf-8")
    return re.search(r"visit: (https://\S+)", text).group(1)


def say(line):
    REAL_STDOUT.write(line + "\n")
    REAL_STDOUT.flush()
PYEOF

# py_case NUM DESCRIPTION  (python body on stdin; the case's last stdout line, if any, is appended to the ok line)
py_case() {
  local num="$1" desc="$2" out
  if { cat "$TMPROOT/prelude.py"; cat; } | python3 - "$REPO" "$TMPROOT" >"$TMPROOT/case$num.out" 2>"$TMPROOT/case$num.err"; then
    out="$(tail -n 1 "$TMPROOT/case$num.out")"
    if [ -n "$out" ]; then ok "$num. $desc ($out)"; else ok "$num. $desc"; fi
  else
    bad "$num. $desc:"
    sed 's/^/       | /' "$TMPROOT/case$num.err" | tail -25
  fi
}

# ═══ 1. the fake is faithful to the recorded transcript ═════════════════════
py_case 1 "transcript fidelity: the fake's PTY output up to the prompt is the recorded transcript, byte for byte" <<'PYEOF'
import fcntl, struct, termios
w = World(mode="hang")
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 1000, 0, 0))
attrs = termios.tcgetattr(slave)
attrs[3] &= ~termios.ECHO
termios.tcsetattr(slave, termios.TCSANOW, attrs)
proc = subprocess.Popen([os.path.join(w.bin, "claude"), "auth", "login"], stdin=slave, stdout=slave, stderr=slave,
                        env=dict(w.env, TERM="dumb", NO_COLOR="1"), start_new_session=True, close_fds=True)
os.close(slave)
try:
    with open(TRANSCRIPT, "rb") as f:
        want = f.read()
    got = b""
    end = time.monotonic() + 15
    while len(got) < len(want) and time.monotonic() < end:
        if select.select([master], [], [], 0.2)[0]:
            got += os.read(master, 4096)
    assert got == want, "PTY bytes differ from the transcript:\n%r\n%r" % (got, want)
finally:
    os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    os.close(master)
assert want.endswith(b"Paste code here if prompted > ") and b"\r\n" in want and want.count(b"https://") == 1
say("%d bytes" % len(want))
PYEOF

# ═══ 2. happy path, claudeai ═════════════════════════════════════════════════
py_case 2 "happy path (claudeai): start -> URL in state.login.request -> code -> result ok, group gone, code nowhere" <<'PYEOF'
w = World()
rig = Rig(w)
ack = rig.cmd("login_start", {"kind": "claudeai"})
assert ack["ok"] is True and re.fullmatch(r"l-[0-9a-f]{8}", ack["id"]) and "dup" not in ack and "detail" not in ack, ack
rid = ack["id"]
wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
login = rig.login()
req = login["request"]
assert set(req) == {"id", "url", "host", "expires_at", "kind", "phase"}, req
assert req["id"] == rid and req["kind"] == "claudeai" and req["phase"] == "awaiting-code" and req["host"] == "claude.com", req
assert req["url"] == transcript_url(), "the published URL must be exactly the one the CLI printed"
assert m.validate_url(req["url"], "claudeai") == "claude.com"
assert abs(req["expires_at"] - (time.time() + 300)) < 20, req["expires_at"]
assert login["enabled"] is True and login["result"] is None, login
assert "login" not in rig.client.cache.state, "the overlay must never mutate the shared StateCache object"
ack = rig.cmd("login_code", {"id": rid, "code": w.full})
assert ack["ok"] is True and ack["id"] == rid and ack["phase"] == "verifying" and "detail" not in ack, ack
res = wait_for(lambda: rig.mgr.snapshot()["result"], what="the result")
assert res == {"id": rid, "ok": True, "detail": None, "at": res["at"], "account_hint": OWNER_MASK, "restart_needed": True}, res
login = rig.login()
assert login["request"] is None and login["result"] == res, login
assert login["cc"]["status"] == "ok" and login["cc"]["method"] == "claude.ai" and login["cc"]["account_hint"] == OWNER_MASK, login["cc"]
assert len(w.logins()) == 1 and "console=False" in w.logins()[0], w.calls()
assert w.gone()
assert not os.path.exists(os.path.join(w.hh, "cc-login.pid")), "the pid file must go with the session"
assert leaks_of(rig, w) == []
say("result in state, %d fake calls" % len(w.calls()))
PYEOF

# ═══ 3. happy path, console ══════════════════════════════════════════════════
py_case 3 "happy path (console): --console, the console host, and the managed api key counts as signed in (not an override)" <<'PYEOF'
w = World()
rig = Rig(w)
rid = rig.cmd("login_start", {"kind": "console"})["id"]
req = wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
assert req["kind"] == "console" and req["host"] == "platform.claude.com", req
assert m.validate_url(req["url"], "console") == "platform.claude.com" and "/oauth/authorize?" in req["url"]
assert "console=True" in w.logins()[0], w.calls()
assert rig.cmd("login_code", {"id": rid, "code": w.full})["ok"] is True
res = wait_for(lambda: rig.mgr.snapshot()["result"], what="the result")
assert res["ok"] is True and res["account_hint"] == OWNER_MASK, res
assert w.store()["authMethod"] == "api_key", "the fake signs a console login in as a managed api key"
cc = rig.login()["cc"]
assert cc["status"] == "ok" and cc["method"] == "api_key", "a /login managed key is a login, not an env override: %r" % cc
assert w.gone() and leaks_of(rig, w) == []
PYEOF

# ═══ 4. wrong code ═══════════════════════════════════════════════════════════
py_case 4 "wrong code: the CLI's 'Login failed' -> result oauth-error, process gone" <<'PYEOF'
w = World()
rig = Rig(w)
rid = rig.cmd("login_start", {"kind": "claudeai"})["id"]
wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
wrong = secrets.token_urlsafe(32) + "#" + secrets.token_urlsafe(32)
assert rig.cmd("login_code", {"id": rid, "code": wrong})["ok"] is True
res = wait_for(lambda: rig.mgr.snapshot()["result"], what="the result")
assert res["ok"] is False and res["detail"] == "oauth-error" and res["account_hint"] is None and res["restart_needed"] is False, res
assert rig.login()["request"] is None
assert w.store()["email"] == OWNER, "a failed login must leave the store as it was"
assert w.gone()
PYEOF

py_case 5 "the CLI's 'Invalid code' answer -> result invalid-code, process killed (the CLI would wait on)" <<'PYEOF'
w = World(mode="invalid-code-marker")
rig = Rig(w)
rid = rig.cmd("login_start", {"kind": "claudeai"})["id"]
wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
assert rig.cmd("login_code", {"id": rid, "code": w.full})["ok"] is True
res = wait_for(lambda: rig.mgr.snapshot()["result"], what="the result")
assert res["ok"] is False and res["detail"] == "invalid-code", res
assert w.gone() and leaks_of(rig, w) == []
PYEOF

# ═══ 6. a malformed code is refused before it is spent ═════════════════════
py_case 6 "bad-code: no #STATE, control bytes, junk are refused and do NOT consume the request; the real code still works" <<'PYEOF'
w = World()
rig = Rig(w)
rid = rig.cmd("login_start", {"kind": "claudeai"})["id"]
wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
for junk in (w.code, "abc#def", w.code + "#", "#" + w.state, w.code + " " + w.state, w.code + "\r#" + w.state,
             w.full + "#" + w.state, w.code + "\x1b[31m#" + w.state, "", None, 12345, ["a"], {"c": 1}):
    ack = rig.cmd("login_code", {"id": rid, "code": junk})
    assert ack == {"ok": False, "of_seq": ack["of_seq"], "detail": "bad-code"}, (junk, ack)
assert rig.mgr.snapshot()["request"]["phase"] == "awaiting-code", "a refused code must not move the request on"
assert w.logins() and len(w.logins()) == 1
ack = rig.cmd("login_code", {"id": rid, "code": "  " + w.full + "\r\n"})
assert ack["ok"] is True and ack["phase"] == "verifying", ack
res = wait_for(lambda: rig.mgr.snapshot()["result"], what="the result")
assert res["ok"] is True, res
assert leaks_of(rig, w) == []
PYEOF

# ═══ 7. one code per id ═════════════════════════════════════════════════════
py_case 7 "one-shot: a second code on the same id is already-submitted (live and after); unknown and malformed ids are refused" <<'PYEOF'
w = World(mode="slow-result", env_extra={})
rig = Rig(w)
rig.mgr.result_s = 30
rid = rig.cmd("login_start", {"kind": "claudeai"})["id"]
wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
assert rig.cmd("login_code", {"id": rid, "code": w.full})["ok"] is True
other = secrets.token_urlsafe(32) + "#" + secrets.token_urlsafe(32)
assert rig.cmd("login_code", {"id": rid, "code": other}) == {"ok": False, "of_seq": rig.ack()["of_seq"], "detail": "already-submitted"}
assert rig.mgr.snapshot()["request"]["phase"] == "verifying"
assert rig.cmd("login_code", {"id": "l-00000000", "code": w.full})["detail"] == "unknown-id"
for bad_id in ("", "l-xyz", "L-00000000", "l-0000000", "../../etc", None, 7, ["l-00000000"]):
    assert rig.cmd("login_code", {"id": bad_id, "code": w.full})["detail"] == "bad-params", bad_id
assert rig.cmd("login_code", "not-an-object")["detail"] == "bad-params"
assert len(w.logins()) == 1
rig.cmd("login_cancel", {"id": rid})  # unchanged: a code is already in flight
rig.mgr.shutdown("superseded")
res = result_of(rig.mgr)
assert res and res["detail"] == "superseded", res
assert rig.cmd("login_code", {"id": rid, "code": other})["detail"] == "already-submitted", "the id stays spent after the result"
assert w.gone()
PYEOF

# ═══ 8-9. expiry and the group kill ═════════════════════════════════════════
py_case 8 "expiry: after expires_at the request is dropped, the whole process group is killed, a late code is 'expired'" <<'PYEOF'
w = World(mode="hang")
mgr = w.manager(lifetime_s=2, term_grace_s=1)
rid, req = started(mgr)
assert abs(req["expires_at"] - (time.time() + 2)) < 2
t0 = time.monotonic()
res = wait_for(lambda: result_of(mgr), timeout=10, what="the expiry")
assert res["ok"] is False and res["detail"] == "expired" and res["id"] == rid, res
assert request_of(mgr) is None
assert w.gone("the hung CLI and its helper")
assert refused(mgr.submit_code, rid, w.full) == "expired"
assert len(w.logins()) == 1
say("expired after %.1fs, group gone" % (time.monotonic() - t0))
PYEOF

py_case 9 "timeout kill: a CLI that ignores SIGTERM is SIGKILLed after the grace period, helper included" <<'PYEOF'
w = World(mode="ignore-term")
mgr = w.manager(lifetime_s=2, term_grace_s=0.5)
rid, _req = started(mgr)
t0 = time.monotonic()
res = wait_for(lambda: result_of(mgr), timeout=10, what="the expiry")
assert res["detail"] == "expired", res
assert w.gone("the SIGTERM-proof CLI and its helper")
took = time.monotonic() - t0
assert took < 6, "teardown took %.1fs" % took
say("ended %.1fs after the request was published" % took)
PYEOF

# ═══ 10. URL off the allowlist ═══════════════════════════════════════════════
py_case 10 "a URL off the allowlist is never published: host -> host-not-allowed, redirect -> bad-url, process killed" <<'PYEOF'
for mode, want in (("bad-host", "host-not-allowed"), ("bad-redirect", "bad-url")):
    w = World(mode=mode)
    rig = Rig(w)
    ack = rig.cmd("login_start", {"kind": "claudeai"})
    assert ack["ok"] is True, ack  # the start itself is fine: the CLI only misbehaves after it is running
    seen = []
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and result_of(rig.mgr) is None:
        seen.append(request_of(rig.mgr))
        time.sleep(0.01)
    res = result_of(rig.mgr)
    assert res and res["ok"] is False and res["detail"] == want, (mode, res)
    assert all(r is None for r in seen), "an unvalidated URL reached state.login.request: %r" % [r for r in seen if r]
    login = rig.login()
    assert login["request"] is None and login["result"]["detail"] == want
    frames = b"\n".join(rig.all_plaintexts())
    assert b"evil.example" not in frames and b"localhost" not in frames, "the rejected URL leaked into a sealed frame"
    assert rig.cmd("login_code", {"id": ack["id"], "code": w.full})["detail"] in ("unknown-id", "already-submitted"), "no code may be accepted"
    assert w.gone()
say("host-not-allowed and bad-url, nothing published")
PYEOF

py_case 11 "noise before the URL (another https link) and a URL that arrives in pieces: published only when whole and valid" <<'PYEOF'
want = transcript_url()
for mode in ("noise-then-url", "split-url"):
    w = World(mode=mode)
    mgr = w.manager()
    rid = mgr.start("claudeai")["id"]
    seen = []
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and not any(seen):
        seen.append(request_of(mgr))
        time.sleep(0.005)
    for req in seen:
        if req is not None:
            assert req["url"] == want, "a partial or foreign URL was published in mode %s: %r" % (mode, req["url"])
    assert any(seen), "the real URL was never published in mode %s" % mode
    assert refused(mgr.submit_code, rid, "x") == "bad-code"
    assert mgr.submit_code(rid, w.full)["phase"] == "verifying"
    res = wait_for(lambda: result_of(mgr), what="the result")
    assert res["ok"] is True, (mode, res)
    assert w.gone()
say("noise-then-url and split-url")
PYEOF

py_case 12 "no URL within no_url_s -> result no-url, process group killed" <<'PYEOF'
w = World(mode="no-url")
mgr = w.manager(no_url_s=1)
rid = mgr.start("claudeai")["id"]
t0 = time.monotonic()
res = wait_for(lambda: result_of(mgr), timeout=10, what="no-url")
assert res["detail"] == "no-url" and res["ok"] is False and request_of(mgr) is None, res
assert time.monotonic() - t0 < 6
assert refused(mgr.submit_code, rid, w.full) == "unknown-id"
assert w.gone()
PYEOF

# ═══ 13. one login at a time ═════════════════════════════════════════════════
py_case 13 "one at a time: same-kind start is a dup (same id, no second process); other kind or another root is busy; lock released after" <<'PYEOF'
w = World(mode="hang")
mgr = w.manager()
first = mgr.start("claudeai")
assert set(first) == {"id"} and re.fullmatch(r"l-[0-9a-f]{8}", first["id"]), first
wait_for(lambda: w.logins(), what="the CLI to start")
dup = mgr.start("claudeai")
assert dup == {"id": first["id"], "dup": True}, dup
time.sleep(0.5)
assert len(w.logins()) == 1, "a duplicate start must not spawn a second CLI"
assert refused(mgr.start, "console") == "busy"
other_root = w.manager()  # a second relay client (another repo root) on the same machine, same HEIMDALL_HOME
assert refused(other_root.start, "claudeai") == "busy"
assert len(w.logins()) == 1
assert mgr.cancel(first["id"]) == {"id": first["id"]}
res = wait_for(lambda: result_of(mgr), what="the cancel")
assert res["detail"] == "cancelled" and res["ok"] is False, res
assert w.gone()
again = other_root.start("claudeai")  # the flock went with the first login
assert again["id"] != first["id"]
wait_for(lambda: len(w.logins()) == 2, what="the second CLI")
other_root.shutdown("superseded")
assert w.gone()
PYEOF

py_case 14 "rate limit: 3 starts per 600 s, the 4th is rate-limited and spawns nothing" <<'PYEOF'
w = World(mode="hang")
mgr = w.manager()
for _ in range(3):
    rid, _req = started(mgr)
    mgr.cancel(rid)
    wait_for(lambda: request_of(mgr) is None and result_of(mgr) and result_of(mgr)["id"] == rid, what="the cancel")
assert len(w.logins()) == 3
assert refused(mgr.start, "claudeai") == "rate-limited"
time.sleep(0.5)
assert len(w.logins()) == 3, "a rate-limited start must not spawn anything"
mgr.now = lambda: time.time() + 601
assert mgr.start("claudeai")["id"], "the window slides: a start 601 s after the first three is allowed again"
wait_for(lambda: len(w.logins()) == 4, what="the fourth CLI")
mgr.shutdown("superseded")
assert w.gone()
PYEOF

# ═══ 15. every refusal ═══════════════════════════════════════════════════════
py_case 15 "refusals in the doc's order: off, caps-missing, busy-free paths, bad-params, claude-not-found, overridden-by-env, spawn-failed" <<'PYEOF'
events = []
w = World(enabled=False)
mgr = w.manager(events)
assert refused(mgr.start, "claudeai") == "remote-login-off"
assert refused(mgr.start, "claudeai", caps_ok=False) == "remote-login-off", "off is reported before caps-missing"
assert w.logins() == [] and w.calls() == [], "a refused start must not run claude at all"
m.write_config(w.hh, True, pin=None, pin_next=False)  # enabled but no pin and no --pin-next: not properly enabled
assert refused(w.manager().start, "claudeai") == "remote-login-off"
m.write_config(w.hh, True, pin=w.owner_fp)
assert refused(mgr.start, "claudeai", caps_ok=False) == "caps-missing"
for kind in ("", "other", None, 7, "CLAUDEAI", ["claudeai"]):
    assert refused(mgr.start, kind) == "bad-params", kind
assert w.logins() == []
assert [e["detail"] for e in events if e["phase"] == "start"] == ["remote-login-off", "remote-login-off", "caps-missing"] + ["bad-params"] * 6
assert all(e["ok"] is False and e["id"] is None for e in events)
# claude is not on PATH
w2 = World()
nopath = m.LoginManager(w2.hh, dict(w2.env, PATH="/usr/bin:/bin"))
assert refused(nopath.start, "claudeai") == "claude-not-found"
# the environment's own credentials outrank a /login: refuse, spawn nothing
for var in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"):
    w3 = World(env_extra={var: "placeholder-value"})
    assert refused(w3.manager().start, "claudeai") == "overridden-by-env", var
    assert w3.logins() == [], var
# claude exists but cannot be executed: spawn-failed, and the lock is not left behind
w4 = World()
broken = os.path.join(w4.base, "broken-bin")
os.makedirs(broken)
with open(os.path.join(broken, "claude"), "w") as f:
    f.write("#!/nonexistent/interpreter\n")
os.chmod(os.path.join(broken, "claude"), 0o755)
bad_mgr = m.LoginManager(w4.hh, dict(w4.env, PATH=broken))
assert refused(bad_mgr.start, "claudeai") == "spawn-failed"
good = w4.manager()
assert good.start("claudeai")["id"], "the failed start must release the global lock"
good.shutdown("superseded")
assert w4.gone()
PYEOF

# ═══ 16. account pin ═════════════════════════════════════════════════════════
py_case 16 "pin: a different account is logged out again (account-mismatch); the same account is kept; cc follows" <<'PYEOF'
w = World(account=OTHER)
rig = Rig(w)
rid = rig.cmd("login_start", {"kind": "claudeai"})["id"]
wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
assert rig.cmd("login_code", {"id": rid, "code": w.full})["ok"] is True
res = wait_for(lambda: rig.mgr.snapshot()["result"], what="the result")
assert res["ok"] is False and res["detail"] == "account-mismatch" and res["account_hint"] is None, res
assert any(c.startswith("logout ") for c in w.calls()), "the fake must have seen `auth logout`: %r" % w.calls()
assert w.store()["loggedIn"] is False, "the mismatching login must be undone"
cc = wait_for(lambda: (rig.login()["cc"] if rig.login()["cc"]["status"] == "signed-out" else None), what="cc to follow the logout")
assert cc["account_hint"] is None and cc["method"] == "none", cc
frames = b"\n".join(rig.all_plaintexts())
assert OTHER.encode() not in frames and b"someone-else" not in frames, "the other account's address must never reach the phone"
assert leaks_of(rig, w) == [] and w.gone()
# the same account passes the pin
w2 = World(account=OWNER)
mgr = w2.manager()
rid, _req = started(mgr)
mgr.submit_code(rid, w2.full)
res = wait_for(lambda: result_of(mgr), what="the result")
assert res["ok"] is True and res["account_hint"] == OWNER_MASK and not any(c.startswith("logout ") for c in w2.calls()), res
PYEOF

py_case 17 "--pin-next: the first successful remote login sets the pin (64 hex, no address), then it binds" <<'PYEOF'
w = World(signed_in=False, pinned=False, pin_next=True, account=OWNER)
cfg = m.read_config(w.hh)
assert cfg["enabled"] is True and cfg["pin"] is None and cfg["pin_next"] is True
mgr = w.manager()
rid, _req = started(mgr)
mgr.submit_code(rid, w.full)
res = wait_for(lambda: result_of(mgr), what="the result")
assert res["ok"] is True and res["account_hint"] == OWNER_MASK, res
cfg = m.read_config(w.hh)
assert cfg["pin_next"] is False and re.fullmatch(r"[0-9a-f]{64}", cfg["pin"]), cfg
assert cfg["pin"] == m.identity_fingerprint({"loggedIn": True, "email": OWNER, "orgId": ORG})
raw = open(os.path.join(w.hh, "remote-login.json"), "rb").read()
assert b"example.test" not in raw and b"owner" not in raw, "the pin file must hold a fingerprint, never an address"
assert oct(os.stat(os.path.join(w.hh, "remote-login.json")).st_mode & 0o777) == "0o600"
# now pinned: another account is refused
w.env["FAKE_CLAUDE_ACCOUNT_EMAIL"] = OTHER
mgr2 = w.manager()
rid2, _req = started(mgr2)
mgr2.submit_code(rid2, w.full)
res2 = wait_for(lambda: result_of(mgr2), what="the second result")
assert res2["detail"] == "account-mismatch", res2
assert w.gone()
PYEOF

# ═══ 18. how a login can fail to verify ═════════════════════════════════════
py_case 18 "verify-failed: the CLI says success but auth status still reports signed out" <<'PYEOF'
w = World(mode="login-keeps-store", signed_in=False)
mgr = w.manager()
rid, _req = started(mgr)
mgr.submit_code(rid, w.full)
res = wait_for(lambda: result_of(mgr), what="the result")
assert res["ok"] is False and res["detail"] == "verify-failed", res
assert not any(c.startswith("logout ") for c in w.calls())
assert w.gone()
PYEOF

py_case 19 "no-result (the CLI takes the code and says nothing) and exited (the CLI dies first), both killed and reported" <<'PYEOF'
w = World(mode="slow-result")
mgr = w.manager(result_s=1)
rid, _req = started(mgr)
mgr.submit_code(rid, w.full)
t0 = time.monotonic()
res = wait_for(lambda: result_of(mgr), timeout=10, what="no-result")
assert res["detail"] == "no-result" and time.monotonic() - t0 < 6, res
assert w.gone()
w2 = World(mode="exit-after-url")
mgr2 = w2.manager()
rid2 = mgr2.start("claudeai")["id"]
res2 = wait_for(lambda: result_of(mgr2), what="exited")
assert res2["detail"] == "exited" and res2["ok"] is False and request_of(mgr2) is None, res2
w3 = World(mode="exit-early")
mgr3 = w3.manager()
mgr3.start("claudeai")
assert wait_for(lambda: result_of(mgr3), what="exited early")["detail"] == "exited"
PYEOF

# ═══ 20. cancel and shutdown ═════════════════════════════════════════════════
py_case 20 "login_cancel: a live request ends cancelled with no process left; an unknown or finished id is ok + unchanged" <<'PYEOF'
w = World(mode="hang")
rig = Rig(w)
rid = rig.cmd("login_start", {"kind": "claudeai"})["id"]
wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
ack = rig.cmd("login_cancel", {"id": rid})
assert ack["ok"] is True and ack["id"] == rid and "detail" not in ack, ack
res = rig.mgr.snapshot()["result"]
assert res["detail"] == "cancelled" and res["ok"] is False and res["id"] == rid, res
assert w.gone()
ack = rig.cmd("login_cancel", {"id": rid})
assert ack["ok"] is True and ack["detail"] == "unchanged" and ack["id"] == rid, ack
ack = rig.cmd("login_cancel", {"id": "l-00000000"})
assert ack["ok"] is True and ack["detail"] == "unchanged", ack
assert rig.cmd("login_cancel", {"id": "nope"})["detail"] == "bad-params"
PYEOF

py_case 21 "shutdown (relay client exit / a replaced phone): the live login ends superseded and nothing is left running" <<'PYEOF'
w = World(mode="hang")
rig = Rig(w)
rid = rig.cmd("login_start", {"kind": "claudeai"})["id"]
wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
rig.client._login_shutdown()
res = rig.mgr.snapshot()["result"]
assert res["detail"] == "superseded" and res["id"] == rid, res
assert w.gone()
assert not os.path.exists(os.path.join(w.hh, "cc-login.pid"))
rig.client._login_shutdown()  # idempotent
PYEOF

py_case 22 "orphan sweep: a leftover claude auth login named by the pid file is killed; an unrelated process with that pid is not" <<'PYEOF'
w = World(mode="hang")
orphan = subprocess.Popen([os.path.join(w.bin, "claude"), "auth", "login"], env=dict(w.env), start_new_session=True,
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
wait_for(lambda: w.pid("child.pid"), what="the orphan to be up")
os.makedirs(w.hh, exist_ok=True)
with open(os.path.join(w.hh, "cc-login.pid"), "w") as f:
    json.dump({"pid": orphan.pid, "started_at": int(time.time())}, f)
assert w.manager(term_grace_s=0.5).sweep_orphan() is True  # (the test is the orphan's parent, so it lingers as a zombie)
assert orphan.wait(timeout=10) is not None, "the orphan must be dead"
wait_for(lambda: not group_alive(orphan.pid), what="the orphan's group")
assert not os.path.exists(os.path.join(w.hh, "cc-login.pid"))
# a recycled pid belonging to something else must be left alone
bystander = subprocess.Popen(["sleep", "60"], start_new_session=True)
with open(os.path.join(w.hh, "cc-login.pid"), "w") as f:
    json.dump({"pid": bystander.pid, "started_at": int(time.time())}, f)
assert w.manager().sweep_orphan() is False
assert bystander.poll() is None, "an unrelated process must not be killed"
assert not os.path.exists(os.path.join(w.hh, "cc-login.pid"))
bystander.kill()
bystander.wait()
# a damaged pid file is just removed
for junk in ("not json", "{}", '{"pid": "x"}', '{"pid": -1}', '{"pid": 0}', '{"pid": 1}'):
    with open(os.path.join(w.hh, "cc-login.pid"), "w") as f:
        f.write(junk)
    assert w.manager().sweep_orphan() is False, junk
    assert not os.path.exists(os.path.join(w.hh, "cc-login.pid")), junk
# a LIVE login of another relay client holds the global lock: it is not an orphan and must never be swept
lw = World(mode="hang")
live = lw.manager()
live_id, _req = started(live)
newcomer = lw.manager(term_grace_s=0.5)  # another relay client starting up on the same machine
assert newcomer.sweep_orphan() is False
assert alive(lw.pid("login.pid")) and os.path.exists(os.path.join(lw.hh, "cc-login.pid")), "a live login must survive another client's start"
assert live.cancel(live_id) == {"id": live_id}
assert lw.gone()
PYEOF

# ═══ 23-24. what the phone sees, and when ═══════════════════════════════════
py_case 23 "state.login rides only for a phone that listed login-v1; its first resync with the cap re-arms the state" <<'PYEOF'
w = World()
rig = Rig(w, phone_caps=None)
assert rig.client.device_caps == frozenset()
assert rig.login() is None and "login" not in rig.last_frame["state"], "no cap, no state.login"
assert rig.last_frame["caps"] == ["controls-v1", "dash-alert-v1", "dash-v1", "login-v1", "push-tile-alert-v1", "push-v1", "resync", "view-v1", "z-zlib"], "hmd advertises login-v1 (and controls-v1, push-v1, view-v1) in every state frame"
assert rig.cmd("login_start", {"kind": "claudeai"}) == {"ok": False, "of_seq": rig.ack()["of_seq"], "detail": "caps-missing"}
assert rig.cmd("login_code", {"id": "l-00000000", "code": w.full})["detail"] == "caps-missing"
assert rig.cmd("login_cancel", {"id": "l-00000000"})["detail"] == "caps-missing"
assert w.logins() == []
# the phone now says it speaks login-v1 (its resync matches what hmd last sent, so only the new cap can re-arm)
rig.client.last_sent_digest = "already-sent"
sent = rig.client.last_sent_state
rig.command({"action": "resync", "params": {"last_seq": 0, "digest": rig.E2E.state_digest(sent), "caps": ["login-v1", "resync"]}})
assert rig.client.device_caps == {"login-v1", "resync"}
assert rig.client.last_sent_digest is None, "a phone that newly lists login-v1 must be sent state.login at once"
rig.client._tick_once()
frame = json.loads(rig.E2E.unpack_plaintext(rig.plaintext([p for p in rig.posts if p["type"] == "state"][-1])))
login = frame["state"]["login"]
assert login["enabled"] is True and login["request"] is None and login["result"] is None
assert set(login["cc"]) == {"status", "method", "account_hint", "config_dir", "checked_at"}, login["cc"]
assert login["cc"]["status"] == "unknown" and login["cc"]["checked_at"] == 0, "nothing was probed yet"
# device_bound forgets the caps again
rig.bind()
assert rig.client.device_caps == frozenset() and rig.login() is None
PYEOF

py_case 24 "a rebind of the same phone keeps the request live and re-sends it (level-triggered state)" <<'PYEOF'
w = World(mode="hang")
rig = Rig(w)
rid = rig.cmd("login_start", {"kind": "claudeai"})["id"]
req = wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
rig.bind()
assert rig.client.last_sent_digest is None, "device_bound must re-arm the next state send"
rig.resync(["login-v1", "resync", "z-zlib"])
login = rig.login()
assert login["request"] == req and login["request"]["id"] == rid, login
rig.mgr.shutdown("superseded")
PYEOF

# ═══ 25-26. the code is a secret ═════════════════════════════════════════════
py_case 25 "leaks: even when the CLI echoes the code back, it is in no stdout, event log, relay.json, HEIMDALL_HOME or sealed frame" <<'PYEOF'
w = World(mode="echo-code")
rig = Rig(w)
rid = rig.cmd("login_start", {"kind": "claudeai"})["id"]
wait_for(lambda: rig.mgr.snapshot()["request"], what="the authorize URL")
assert rig.cmd("login_code", {"id": rid, "code": w.full})["ok"] is True
res = wait_for(lambda: rig.mgr.snapshot()["result"], what="the result")
assert res["ok"] is True
rig.login()
assert leaks_of(rig, w) == []
assert w.state[:12] not in rig.out.getvalue() and w.state[:12] not in rig.event_log(), "the STATE half is as secret as the code"
# the log lines that exist say what happened and nothing more
rows = [json.loads(line) for line in rig.event_log().splitlines()]
login_rows = [r for r in rows if r.get("event") == "login"]
assert [(r["phase"], r["ok"], r.get("detail")) for r in login_rows] == [("start", True, None), ("code", True, None), ("result", True, None)], login_rows
for r in login_rows:
    assert set(r) == {"event", "phase", "id", "ok", "detail", "ts"} and r["id"] == rid, r
text = rig.event_log()
assert "http" not in text and "example.test" not in text and "claude.com" not in text, "no URL, host or address in the event log"
commands = [r for r in rows if r.get("event") == "command"]
assert [(c["action"], c["ok"]) for c in commands if c["action"].startswith("login_")] == [("login_start", True), ("login_code", True)]
assert all(set(c) == {"event", "action", "ok", "detail", "ts"} for c in commands), "command events must not carry params"
PYEOF

py_case 26 "the leak detector can fail: a planted copy of the code is found in each place it looks" <<'PYEOF'
w = World()
rig = Rig(w)
rig.cmd("login_start", {"kind": "claudeai"})
assert leaks_of(rig, w) == []
for where, path in (("repo tree (relay.json, relay-events.jsonl)", os.path.join(w.repo, "planted.txt")),
                    ("$HEIMDALL_HOME", os.path.join(w.hh, "planted.txt"))):
    with open(path, "w") as f:
        f.write("x " + w.code + " y")
    assert where in leaks_of(rig, w), where
    os.unlink(path)
rig.out.write("oops " + w.code + "\n")
assert "stdout capture" in leaks_of(rig, w)
rig.mgr.shutdown("superseded")
PYEOF

# ═══ 27-29. detection ═════════════════════════════════════════════════════════
py_case 27 "probe: signed-out, ok (masked account, ~ config dir), overridden, unknown (no claude, garbage, hang)" <<'PYEOF'
w = World(signed_in=False)
mgr = w.manager()
cc = mgr.probe()
assert cc["status"] == "signed-out" and cc["method"] == "none" and cc["account_hint"] is None, cc
assert cc["config_dir"] == "~/.claude" and abs(cc["checked_at"] - time.time()) < 30, cc
assert mgr.snapshot()["cc"] == cc
w.write_store({"loggedIn": True, "authMethod": "claude.ai", "email": OWNER, "orgId": ORG})
cc = mgr.probe()
assert cc["status"] == "ok" and cc["method"] == "claude.ai" and cc["account_hint"] == OWNER_MASK, cc
assert OWNER not in json.dumps(mgr.snapshot()), "the snapshot must carry the masked account only"
w.write_store({"loggedIn": True, "authMethod": "api_key", "email": OWNER, "orgId": ORG})
assert mgr.probe()["status"] == "ok" and mgr.probe()["method"] == "api_key"
for var, method in (("ANTHROPIC_API_KEY", "api_key"), ("CLAUDE_CODE_OAUTH_TOKEN", "oauth_token")):
    ov = World(env_extra={var: "placeholder-value"}).manager().probe()
    assert ov["status"] == "overridden" and ov["method"] == method and ov["account_hint"] is None, (var, ov)
nobin = m.LoginManager(w.hh, dict(w.env, PATH="/usr/bin:/bin")).probe()
assert nobin["status"] == "unknown" and nobin["method"] == "none" and nobin["account_hint"] is None, nobin
garbage = World(env_extra={"FAKE_CLAUDE_STATUS_GARBAGE": "1"}).manager().probe()
assert garbage["status"] == "unknown", garbage
hang = World(env_extra={"FAKE_CLAUDE_STATUS_HANG": "1"}).manager(status_timeout_s=1)
t0 = time.monotonic()
assert hang.probe()["status"] == "unknown" and time.monotonic() - t0 < 8
w.gone("the hung status probe")
PYEOF

py_case 28 "probe never runs during a live login and never two at once" <<'PYEOF'
w = World(mode="hang")
mgr = w.manager()
rid, _req = started(mgr)
before = len(w.calls())
assert mgr.probe()["status"] == "unknown" and len(w.calls()) == before, "a probe must not run while a login is live"
mgr.shutdown("superseded")
w2 = World(env_extra={"FAKE_CLAUDE_STATUS_HANG": "1"})
slow = w2.manager(status_timeout_s=3)
import threading
t = threading.Thread(target=slow.probe)
t.start()
wait_for(lambda: len(w2.calls()) >= 1, what="the first probe to start")
t0 = time.monotonic()
slow.probe()
assert time.monotonic() - t0 < 1.5, "a second probe must return at once instead of running"
assert len([c for c in w2.calls() if c.startswith("status ")]) == 1
t.join()
PYEOF

py_case 29 "probe loop: idle while remote login is off, probes once enabled, notices an on/off flip, stops with the event" <<'PYEOF'
import threading
w = World(enabled=False)
changes = []
mgr = m.LoginManager(w.hh, w.env, on_change=lambda: changes.append(time.monotonic()))
stop = threading.Event()
t = threading.Thread(target=mgr.run_probe_loop, args=(stop,), kwargs={"every": 60, "tick": 0.05}, daemon=True)
t.start()
time.sleep(0.4)
assert w.calls() == [], "no `claude auth status` while remote login is off"
m.write_config(w.hh, True, pin=w.owner_fp)
wait_for(lambda: any(c.startswith("status ") for c in w.calls()), what="the first probe after enabling")
wait_for(lambda: changes, what="on_change after the flip")
wait_for(lambda: mgr.snapshot()["cc"]["status"] == "ok", what="cc from the probe's answer")
assert mgr.snapshot()["enabled"] is True
n = len(changes)
m.write_config(w.hh, False)
wait_for(lambda: len(changes) > n and mgr.snapshot()["enabled"] is False, what="the off flip to be noticed")
stop.set()
t.join(timeout=5)
assert not t.is_alive()
PYEOF

# ═══ 30. the laptop CLI ═══════════════════════════════════════════════════════
py_case 30 "hmd app remote-login: on pins the signed-in account, refuses when signed out, --pin-next, off clears, status" <<'PYEOF'
def run(w, *argv):
    out = io.StringIO()
    rc = m.main(list(argv), out=out, env=w.env)
    return rc, out.getvalue()

w = World(enabled=False)
rc, text = run(w, "status")
assert rc == 0 and "remote login: off" in text and "last result: none" in text, text
rc, text = run(w, "on")
assert rc == 0 and "remote login: on" in text and OWNER_MASK in text and OWNER not in text, text
cfg = m.read_config(w.hh)
assert cfg["enabled"] is True and cfg["pin"] == w.owner_fp and cfg["pin_next"] is False, cfg
rc, text = run(w, "status")
assert rc == 0 and "remote login: on" in text and "pinned to " + OWNER_MASK in text and "~/.claude" in text, text
rc, text = run(w, "off")
assert rc == 0 and "remote login: off" in text
cfg = m.read_config(w.hh)
assert cfg == {"enabled": False, "pin": None, "pin_next": False, "updated_at": cfg["updated_at"]}, cfg
w2 = World(signed_in=False, enabled=False)
rc, text = run(w2, "on")
assert rc != 0 and "signed out" in text and "--pin-next" in text, text
assert m.read_config(w2.hh)["enabled"] is False, "a refused `on` must change nothing"
rc, text = run(w2, "on", "--pin-next")
assert rc == 0 and "next successful remote login" in text, text
cfg = m.read_config(w2.hh)
assert cfg["enabled"] is True and cfg["pin"] is None and cfg["pin_next"] is True, cfg
rc, text = run(w2, "status")
assert rc == 0 and "signed out" in text and "first successful" in text, text
w3 = World(enabled=False, env_extra={"ANTHROPIC_API_KEY": "placeholder-value"})
rc, text = run(w3, "on")
assert rc != 0, "an environment credential cannot be pinned"
rc, text = run(w3, "bogus")
assert rc == 2
mode = oct(os.stat(os.path.join(w.hh, "remote-login.json")).st_mode & 0o777)
assert mode == "0o600", mode
PYEOF

# ═══ 31. caps and the wire name ══════════════════════════════════════════════
py_case 31 "caps: hmd_caps lists login-v1 only when the feature module loaded; the client sends it in every state frame" <<'PYEOF'
rig = Rig(World(), phone_caps=None)
E2E = rig.E2E
assert E2E.CAP_LOGIN == "login-v1" == m.CAP_LOGIN
assert E2E.hmd_caps(push=False) == ["resync", "z-zlib"], "the codec alone does not know the feature (push-v1 is the other optional one, left out here)"
assert E2E.hmd_caps(extra=[E2E.CAP_LOGIN], push=False) == ["login-v1", "resync", "z-zlib"]
assert E2E.hmd_caps(extra=("login-v1", "login-v1", 7, None, "", "x" * 33), push=False) == ["login-v1", "resync", "z-zlib"], "junk tokens and duplicates are dropped"
assert E2E.hmd_caps(extra=None, push=False) == ["resync", "z-zlib"]
rig.login()
assert rig.last_frame["caps"] == ["controls-v1", "dash-alert-v1", "dash-v1", "login-v1", "push-tile-alert-v1", "push-v1", "resync", "view-v1", "z-zlib"], rig.last_frame["caps"]
rig.mod.LOGIN = None  # the feature module failed to import
rig.client._rearm_state()
rig.client._tick_once()
frame = json.loads(rig.E2E.unpack_plaintext(rig.plaintext([p for p in rig.posts if p["type"] == "state"][-1])))
assert frame["caps"] == ["controls-v1", "dash-alert-v1", "dash-v1", "push-tile-alert-v1", "push-v1", "resync", "view-v1", "z-zlib"], "no module, no cap (and the controls', the push store's and the view channel's own caps are untouched)"
rig.resync(["login-v1"])
assert rig.cmd("login_start", {"kind": "claudeai"})["detail"] == "not-implemented"
assert rig.cmd("login_code", {"id": "l-00000000", "code": "x"})["detail"] == "not-implemented"
assert rig.cmd("login_cancel", {"id": "l-00000000"})["detail"] == "not-implemented"
PYEOF

# ── static acceptance (the handoff's own greps) ──────────────────────────────
if grep -q '"login-v1"\|CAP_LOGIN' "$E2E_MOD"; then ok "32. bin/lib/hmd_relay_e2e.py names the login-v1 capability"; else bad "32. hmd_relay_e2e.py does not name login-v1"; fi
if grep -q 'login_code' "$CLIENT" && grep -q 'login_start' "$CLIENT" && grep -q 'login_cancel' "$MOD"; then ok "33. the relay client wires login_start/login_code and the module names all three actions"; else bad "33. relay client does not wire the login actions"; fi
if [ -f "$TRANSCRIPT" ]; then ok "34. docs/samples/login/cc-2.1.288-transcript.txt exists"; else bad "34. the transcript fixture is missing"; fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

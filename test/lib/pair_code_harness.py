#!/usr/bin/env python3
"""test/lib/pair_code_harness.py -- what test/lib/app_pair_code_client_cases.py and
test/lib/app_pair_code_app_cases.py share: a throwaway sandbox (HOME, repo, TMPDIR), a process
wrapper that keeps everything a child printed, the "phone" side of a pairing (a keypair plus the
independent hashlib references for the commitment and the SAS), a file scanner for "this secret is
nowhere on disk", and the ok/FAIL tally in the suite convention ("  ok   N. ..." / "  FAIL N. ..."
and a final "P passed, F failed" line).

Nothing here talks to the real relay or the real GitHub: the relay is test/lib/fake_relay_code.py on
a loopback port, `gh` is a script the test writes into the sandbox, and TOKEN is an obviously fake
string that matches no real credential pattern.

Stdlib only.
"""
import base64
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
CLIENT_PATH = os.path.join(REPO, "bin", "heimdall-relay-client")
APP_PATH = os.path.join(REPO, "bin", "heimdall-app")
E2E_PATH = os.path.join(REPO, "bin", "lib", "hmd_relay_e2e.py")
CODE_HELPER_PATH = os.path.join(REPO, "bin", "lib", "hmd_app_code.py")
VECTORS_PATH = os.path.join(REPO, "test", "fixtures", "hmdapp-pair-code-vectors.json")
CODE_PAIR_CONTRACT_PATH = os.path.join(REPO, "relay", "contract", "code-pair.json")

# Fake on purpose: no `gh*_` prefix, so no secret scanner mistakes it for a real credential. Every test
# that asserts "the token went nowhere but the relay's request body" looks for exactly this string.
TOKEN = "fake-gh-token-for-pair-code-tests-0123456789"
CODE = "4SELK"
HOSTED_RELAY = "https://hmd-relay.therishabh16.workers.dev"
COMMIT_DOMAIN = b"hmd-pair-commit-v1\x00"
SAS_DOMAIN = b"hmd-pair-sas-v1\x00"


def load_module(name, path):
    """bin/heimdall-relay-client has no .py suffix, so every module is loaded through an explicit loader."""
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class Tally:
    def __init__(self):
        self.n = 0
        self.passed = 0
        self.failed = 0

    def check(self, cond, name, detail=""):
        self.n += 1
        if cond:
            self.passed += 1
            print("  ok   %d. %s" % (self.n, name))
        else:
            self.failed += 1
            print("  FAIL %d. %s%s" % (self.n, name, (" -- " + detail) if detail else ""))
        sys.stdout.flush()
        return bool(cond)

    def finish(self):
        print("\n%d passed, %d failed" % (self.passed, self.failed))
        sys.stdout.flush()
        return 0 if self.failed == 0 else 1


# -- independent references (hashlib only, never the code under test) ---------------------------------
def b64url(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def b64_any(value):
    """Either base64 alphabet, padded or not -- the app accepts both for a key_reveal field."""
    normalized = value.replace("-", "+").replace("_", "/")
    return base64.b64decode(normalized + "=" * (-len(normalized) % 4), validate=True)


def commit_ref(hmd_pub, nonce):
    return b64url(hashlib.sha256(COMMIT_DOMAIN + hmd_pub + nonce).digest())


def sas_ref(session_id, hmd_pub, device_pub):
    digest = hashlib.sha256(SAS_DOMAIN + session_id.encode("utf-8") + b"\x00" + hmd_pub + device_pub).digest()
    return "%06d" % (int.from_bytes(digest[:4], "big") % 1000000)


class Phone:
    """The phone side of a pairing: an X25519 keypair from the same module hmd uses."""

    def __init__(self, e2e):
        self.e2e = e2e
        self.priv, self.pub = e2e.generate_keypair()

    @property
    def pub_b64url(self):
        return b64url(self.pub)

    def open_hmd_frame(self, hmd_pub, session_id, envelope):
        """The plaintext of a sealed hmd frame, opened the way the phone would (None when it does not open)."""
        key = self.e2e.derive_session_key(self.priv, hmd_pub, session_id)
        try:
            return json.loads(self.e2e.open_(key, envelope["seq"], "hmd", envelope["nonce"], envelope["ciphertext"]))
        except Exception:
            return None


# -- sandbox and processes -----------------------------------------------------------------------------
class Sandbox:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="app-pair-code.")
        self.home = os.path.join(self.root, "home")
        self.tmp = os.path.join(self.root, "tmp")
        self.repo = os.path.join(self.root, "repo")
        self.bin = os.path.join(self.root, "bin")
        for d in (os.path.join(self.home, ".claude"), self.tmp, self.repo, self.bin):
            os.makedirs(d)
        subprocess.run("git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture",
                       shell=True, cwd=self.repo, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def env(self, **extra):
        """A clean environment: nothing inherited but PATH, so no session id or token of the machine running
        the test leaks into what a child computes."""
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home, "TMPDIR": self.tmp,
               "HEIMDALL_HOME": os.path.join(self.home, ".heimdall"), "HMD_RELAY_STREAM_TRANSPORT": "ndjson",
               "HMD_RELAY_BACKOFF_BASE_MS": "200", "HMD_RELAY_EVENT_LOG": ""}
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def write_executable(self, name, text):
        path = os.path.join(self.bin, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(path, 0o755)
        return path

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


class Proc:
    def __init__(self, argv, env, cwd=None, stdin=subprocess.PIPE, tty=False):
        """`tty=True` gives the child a pseudo-terminal for stdin (`send` types on it, `close_stdin` hangs it
        up): the one way to answer a prompt that is only ever asked at a terminal."""
        self.argv = argv
        self._master = None
        if tty:
            self._master, slave = os.openpty()
            stdin = slave
        self.p = subprocess.Popen(argv, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env=env, cwd=cwd, bufsize=0)
        if tty:
            os.close(slave)
        self._out = bytearray()
        self._err = bytearray()
        self._lock = threading.Lock()
        for stream, buf in ((self.p.stdout, self._out), (self.p.stderr, self._err)):
            threading.Thread(target=self._pump, args=(stream, buf), daemon=True).start()

    def _pump(self, stream, buf):
        fd = stream.fileno()
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            with self._lock:
                buf.extend(chunk)

    @property
    def pid(self):
        return self.p.pid

    @property
    def rc(self):
        return self.p.poll()

    def out(self):
        with self._lock:
            return bytes(self._out)

    def err(self):
        with self._lock:
            return bytes(self._err)

    def text(self):
        return self.out().decode("utf-8", "replace")

    def tail(self, n=600):
        return ("stdout: %r | stderr: %r" % (self.out()[-n:], self.err()[-n:]))

    def events(self):
        found = []
        for line in self.text().splitlines():
            line = line.strip()
            if line.startswith("{"):
                try:
                    found.append(json.loads(line))
                except ValueError:
                    continue
        return found

    def send(self, data):
        raw = data if isinstance(data, bytes) else data.encode("utf-8")
        try:
            if self._master is not None:
                os.write(self._master, raw)
            elif self.p.stdin is not None:
                self.p.stdin.write(raw)
                self.p.stdin.flush()
            else:
                return False
        except (BrokenPipeError, OSError):
            return False
        return True

    def close_stdin(self):
        if self._master is not None:
            master, self._master = self._master, None
            try:
                os.close(master)
            except OSError:
                return
            return
        if self.p.stdin is None:
            return
        try:
            self.p.stdin.close()
        except (BrokenPipeError, OSError):
            return

    def wait_for(self, pred, timeout=10.0, step=0.05):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if pred():
                return True
            time.sleep(step)
        return bool(pred())

    def wait_text(self, needle, timeout=10.0):
        return self.wait_for(lambda: needle in self.text(), timeout)

    def wait_event(self, name, timeout=10.0, where=None, start=0):
        """The first `name` event after the first `start` events (and satisfying `where`), or None."""
        found = []

        def seen():
            for ev in self.events()[start:]:
                if ev.get("event") == name and (where is None or where(ev)):
                    found.append(ev)
                    return True
            return False

        self.wait_for(seen, timeout)
        return found[0] if found else None

    def count_events(self, name):
        return sum(1 for ev in self.events() if ev.get("event") == name)

    def wait_exit(self, timeout=10.0):
        try:
            return self.p.wait(timeout)
        except subprocess.TimeoutExpired:
            return None

    def stop(self, sig=signal.SIGTERM, timeout=8.0):
        self.close_stdin()
        if self.p.poll() is None:
            try:
                self.p.send_signal(sig)
            except OSError:
                return
            try:
                self.p.wait(timeout)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait(5)


def argv_of(pid):
    """What `ps` shows for a live process -- the argv any local user can read."""
    out = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
    return out.stdout.strip()


def files_containing(root, needle):
    """Every regular file under `root` whose bytes contain `needle` (bytes). The leak test: a secret that
    was only ever on a pipe must be in none of them."""
    hits = []
    for base, _dirs, names in os.walk(root):
        for name in names:
            path = os.path.join(base, name)
            if not os.path.isfile(path) or os.path.islink(path):
                continue
            try:
                with open(path, "rb") as f:
                    if needle in f.read():
                        hits.append(path)
            except OSError:
                continue
    return hits

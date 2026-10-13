#!/usr/bin/env python3
"""test/lib/app_session_resume_cases.py -- a stopped laptop relay client must not unpair the phone (option A, 2.4.8).

The relay client keeps the login it attaches to its relay session with (session id, bearer token, hmd private key, the sequence
numbers it must never go back on) OUTSIDE the repo -- the macOS Keychain, or a 0600 file under $HEIMDALL_HOME -- once a phone is
bound. A client that is stopped, crashed, TERMed or KILLed does not revoke; a new client resumes the same relay session for
HMD_SESSION_RESUME_H hours. Only an explicit disconnect, a revoke from the phone or a failed login unpairs.

Everything runs against an in-process loopback relay (Relay below) that speaks the part of the relay contract this needs
(/pair/init, GET /stream as NDJSON, POST /frames, POST /revoke) and a fake phone that derives the same session key from its own
private key. Only pids this test started are ever signalled -- never anything by name. The checks:
  R1  a bound phone's login is stored outside the repo, 0600, and no copy of the token is anywhere under the repo
  R2  TERM: the client ends 0 and revokes nothing; a new --resume client attaches to the SAME relay session (no new /pair/init)
      and the phone gets frames it opens under the key it already holds, with seqs above everything sent before
  R3  KILL: the same
  R4  past HMD_SESSION_RESUME_H the stored login is discarded, nothing is revoked, and the new client pairs afresh (a re-pair)
  R5  `hmd app disconnect --device` for a phone whose client is dead revokes its relay session with the stored login (no
      "could NOT be revoked"), removes the login and the device record; a relay that cannot be reached is a loud failure that keeps
      the login
  R6  `hmd app disconnect` (everything) revokes the relay session of a LIVE client's phone and ends it
  R7  a revoke from the phone ends the client and discards the login; a relay that refuses the login (stream 401) does too
  R8  SIGUSR1 is not a revoke: the client lives on, nothing is revoked, the login stays
  R9  Keychain backend (a fake `security` on PATH): the secret goes over its stdin, never its argv; the metadata file holds none;
      a KILLed client resumes from it; the item goes with the login
  R10 no token is in any client's output or in its event log
"""
import base64
import glob
import http.server
import json
import os
import queue
import re
import secrets
import shutil
import signal
import socketserver
import stat
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "bin", "lib"))
import hmd_relay_e2e as E2E  # noqa: E402

CLIENT = os.path.join(ROOT, "bin", "heimdall-relay-client")
APP = os.path.join(ROOT, "bin", "heimdall-app")
PASS = FAIL = 0
STARTED = []  # every client process this run started: the only pids it ever signals


def check(n, text, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ok   %s. %s" % (n, text))
    else:
        FAIL += 1
        print("  FAIL %s. %s" % (n, text))


def wait_until(fn, timeout=30.0, step=0.1):
    end = time.time() + timeout
    while time.time() < end:
        try:
            got = fn()
        except (KeyError, IndexError, OSError, ValueError):
            got = None
        if got:
            return got
        time.sleep(step)
    return None


class Relay:
    """A loopback relay: one record per /pair/init, the bearer checked on every session route."""

    def __init__(self):
        self.lock = threading.Lock()
        self.sessions = {}
        self.revokes = []
        self.inits = 0
        self.down = False          # /revoke answers 503 while set
        self.revoke_status = None  # /revoke answers this status while set (a relay that refuses: 403)
        self.stream_status = None  # GET /stream answers this status while set
        relay = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_a):
                return None

            def reply(self, code, obj):
                raw = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def session(self, sid):
                s = relay.sessions.get(sid)
                if s is None:
                    self.reply(404, {"error": "session not found"})
                elif self.headers.get("Authorization") != "Bearer " + s["token"]:
                    self.reply(401, {"error": "missing or invalid bearer token"})
                else:
                    return s
                return None

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                if self.path == "/pair/init":
                    with relay.lock:
                        relay.inits += 1
                        sid = "sess%d%s" % (relay.inits, secrets.token_hex(3))
                        relay.sessions[sid] = {"token": secrets.token_urlsafe(24), "bound": None, "revoked": False,
                                               "streams": [], "attaches": 0, "frames": []}
                        tok = relay.sessions[sid]["token"]
                    return self.reply(200, {"session_id": sid, "pairing_code": "PC" + secrets.token_hex(4),
                                            "relay_session_token": tok, "exp": int(time.time()) + 360})
                m = re.match(r"/session/([^/]+)/(frames|revoke)$", self.path)
                if not m:
                    return self.reply(404, {"error": "no route"})
                s = self.session(m.group(1))
                if s is None:
                    return None
                if m.group(2) == "revoke":
                    if relay.down or relay.revoke_status:
                        return self.reply(relay.revoke_status or 503, {"error": "unavailable"})
                    with relay.lock:
                        s["revoked"] = True
                        relay.revokes.append(m.group(1))
                        for q in s["streams"]:
                            q.put(None)
                    return self.reply(200, {"ok": True})
                if s["revoked"]:
                    return self.reply(410, {"error": "session ended"})
                with relay.lock:
                    s["frames"].append(json.loads(body.decode()))
                return self.reply(200, {"delivered": True})

            def do_GET(self):
                m = re.match(r"/session/([^/]+)/stream", self.path)
                if not m:
                    return self.reply(404, {"error": "no route"})
                s = self.session(m.group(1))
                if s is None:
                    return None
                if relay.stream_status:
                    return self.reply(relay.stream_status, {"error": "refused"})
                if s["revoked"]:
                    return self.reply(410, {"error": "session ended"})
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson")
                self.send_header("Transfer-Encoding", "chunked")  # like the real relay: a close-delimited body drops the client's socket handle
                self.end_headers()
                q = queue.Queue()
                with relay.lock:
                    s["streams"].append(q)
                    s["attaches"] += 1
                try:
                    while True:
                        try:
                            item = q.get(timeout=0.5)
                        except queue.Empty:
                            item = relay.envelope(m.group(1), "keepalive", None)
                        if item is None:
                            self.wfile.write(b"0\r\n\r\n")
                            self.wfile.flush()
                            break
                        data = (json.dumps(item) + "\n").encode()
                        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
                        self.wfile.flush()
                except OSError:
                    self.close_connection = True
                finally:
                    with relay.lock:
                        if q in s["streams"]:
                            s["streams"].remove(q)
                    self.close_connection = True
                return None

        class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @staticmethod
    def envelope(sid, type_, payload):
        return {"v": 1, "session_id": sid, "seq": 0, "sender": "relay", "type": type_, "nonce": None, "ciphertext": None,
                "payload": payload}

    def push(self, sid, item):
        with self.lock:
            for q in self.sessions[sid]["streams"]:
                q.put(item)

    def bind(self, sid, device_pub):
        pub = base64.urlsafe_b64encode(device_pub).rstrip(b"=").decode()
        self.sessions[sid]["bound"] = pub
        self.push(sid, self.envelope(sid, "device_bound", {"device_pubkey": pub, "bound_at": int(time.time())}))

    def end(self, sid, reason):
        self.push(sid, self.envelope(sid, "session_ended", {"reason": reason}))

    def attaches(self, sid):
        return self.sessions[sid]["attaches"]

    def state_frames(self, sid):
        with self.lock:
            return [f for f in self.sessions[sid]["frames"] if f.get("sender") == "hmd" and f.get("type") == "state"]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class Sandbox:
    def __init__(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="hmd-resume."))
        self.repo = os.path.join(self.tmp, "repo")
        self.home = os.path.join(self.tmp, "home")
        self.hh = os.path.join(self.home, ".heimdall")
        self.bin = os.path.join(self.tmp, "bin")
        for d in (self.repo, self.home, self.bin):
            os.makedirs(d)
        subprocess.run(["git", "init", "-q", self.repo], check=True, capture_output=True)

    def env(self, **extra):
        env = dict(os.environ, HOME=self.home, HEIMDALL_HOME=self.hh, HMD_SESSION_LOGIN_STORE="file", HMD_PUSH="0",
                   HMD_RELAY_STREAM_TRANSPORT="ndjson", PYTHONDONTWRITEBYTECODE="1", HMD_RELAY_BACKOFF_BASE_MS="200")
        env.pop("HMD_SESSION_RESUME_H", None)
        env.update(extra)
        return env

    def logins(self):
        return sorted(glob.glob(os.path.join(self.hh, "app", "sessions", "*.json")))

    def device_records(self):
        return sorted(glob.glob(os.path.join(self.repo, ".heimdall", "app", "device-*.json")))

    def tree_has(self, needle):
        for base, _dirs, files in os.walk(self.repo):
            for name in files:
                try:
                    with open(os.path.join(base, name), "rb") as f:
                        if needle.encode() in f.read():
                            return True
                except OSError:
                    continue
        return False

    def drop(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class Client:
    def __init__(self, sb, relay, tag, resume=False, **env):
        self.out_path = os.path.join(sb.tmp, tag + ".out")
        self.err_path = os.path.join(sb.tmp, tag + ".err")
        self.log_path = os.path.join(sb.repo, ".heimdall", "app", "relay-events.jsonl")
        argv = [sys.executable, CLIENT, "--relay", relay.url, "--repo", sb.repo, "--ui-port", "1", "--tick-s", "0.2"]
        if resume:
            argv.append("--resume")
        self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=open(self.out_path, "w"),
                                     stderr=open(self.err_path, "w"), env=sb.env(**env))
        STARTED.append(self.proc.pid)
        # Reaped the moment it ends, as a client `hmd app connect` backgrounds is: an unreaped child stays a zombie, which `kill -0` (what
        # _relay_stop_client waits on) still sees as running.
        threading.Thread(target=self.proc.wait, daemon=True).start()

    def events(self):
        out = []
        try:
            with open(self.out_path, encoding="utf-8") as f:
                lines = f.readlines()
        except OSError:
            return out
        for line in lines:
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        return out

    def event(self, name, timeout=30):
        return wait_until(lambda: next((e for e in self.events() if e.get("event") == name), None), timeout)

    def text(self):
        parts = []
        for p in (self.out_path, self.err_path, self.log_path):
            try:
                with open(p, encoding="utf-8", errors="replace") as f:
                    parts.append(f.read())
            except OSError:
                continue
        return "\n".join(parts)

    def stop(self, sig):
        self.proc.send_signal(sig)
        try:
            return self.proc.wait(15)
        except subprocess.TimeoutExpired:
            return None


def open_frame(key, env):
    return json.loads(E2E.open_(key, env["seq"], "hmd", env["nonce"], env["ciphertext"]).decode())


def bind_phone(sb, relay, tag="c1", **env):
    """A client pairs, a phone binds: (client, session id, the phone's key for it)."""
    c = Client(sb, relay, tag, **env)
    pair = c.event("pair_init")
    sid = pair["qr"]["session_id"]
    hmd_pub = E2E.pub_from_b64(pair["qr"]["hmd_pubkey"])
    dev_priv, dev_pub = E2E.generate_keypair()
    wait_until(lambda: relay.sessions[sid]["streams"])
    relay.bind(sid, dev_pub)
    c.event("device_bound")
    key = E2E.derive_session_key(dev_priv, hmd_pub, sid)
    wait_until(lambda: relay.state_frames(sid))
    return c, sid, key


def max_seq(relay, sid):
    return max([f["seq"] for f in relay.state_frames(sid)] or [0])


def device_id(sb):
    names = [os.path.basename(p) for p in sb.device_records()]
    return names[0][len("device-"):-len(".json")] if names else ""


def run_app(sb, *args):
    return subprocess.run([APP] + list(args), env=sb.env(), capture_output=True, text=True, timeout=180)


def kill_leftovers(*clients):
    for c in clients:
        if c is not None and c.proc.poll() is None:
            c.proc.kill()


def scenario_stop(n, label, sig):
    sb, relay = Sandbox(), Relay()
    c1 = c2 = None
    try:
        c1, sid, key = bind_phone(sb, relay)
        token = relay.sessions[sid]["token"]
        first = max_seq(relay, sid)
        stored = sb.logins()
        mode = stat.S_IMODE(os.stat(stored[0]).st_mode) if stored else None
        if n == "R2":
            check("R1", "a bound phone's login is stored outside the repo (0600) and the token is nowhere under the repo",
                  len(stored) == 1 and mode == 0o600 and not os.path.realpath(stored[0]).startswith(sb.repo + os.sep)
                  and not sb.tree_has(token))
        rc = c1.stop(sig)
        ended_ok = rc == 0 if sig == signal.SIGTERM else rc in (-signal.SIGKILL, None)
        check(n, "%s: the client ends and revokes nothing; the phone is still bound" % label,
              ended_ok and relay.revokes == [] and relay.sessions[sid]["bound"] is not None
              and not relay.sessions[sid]["revoked"])
        c2 = Client(sb, relay, "c2", resume=True)
        resumed = c2.event("session_resumed")
        wait_until(lambda: max_seq(relay, sid) > first)
        frames = [f for f in relay.state_frames(sid) if f["seq"] > first]
        opened = []
        for f in frames:
            try:
                opened.append(open_frame(key, f))
            except (ValueError, KeyError, Exception):
                opened.append(None)
        check(n, "%s: a new client resumes the SAME relay session (no new /pair/init) and the phone opens its frames under the "
                 "key it already holds, seqs above the old client's" % label,
              resumed is not None and relay.inits == 1 and relay.attaches(sid) == 2 and bool(frames)
              and all(o and "state" in o for o in opened))
        c2.stop(signal.SIGTERM)
    finally:
        kill_leftovers(c1, c2)
        relay.close()
        sb.drop()


def scenario_expired():
    sb, relay = Sandbox(), Relay()
    c1 = c2 = None
    try:
        c1, sid, _key = bind_phone(sb, relay)
        c1.stop(signal.SIGKILL)
        stored = sb.logins()
        with open(stored[0], encoding="utf-8") as f:
            meta = json.load(f)
        meta["last_alive"] = int(time.time()) - 3 * 3600
        with open(stored[0], "w", encoding="utf-8") as f:
            json.dump(meta, f)
        os.chmod(stored[0], 0o600)
        c2 = Client(sb, relay, "c2", resume=True, HMD_SESSION_RESUME_H="1")
        pair = c2.event("pair_init")
        check("R4", "past HMD_SESSION_RESUME_H the stored login is discarded, nothing is revoked and the new client pairs afresh",
              pair is not None and relay.inits == 2 and pair["qr"]["session_id"] != sid and relay.revokes == []
              and c2.event("session_resumed", 1) is None and stored[0] not in sb.logins())
        c2.stop(signal.SIGTERM)
    finally:
        kill_leftovers(c1, c2)
        relay.close()
        sb.drop()


def scenario_device_revoke():
    sb, relay = Sandbox(), Relay()
    c1 = None
    try:
        c1, sid, _key = bind_phone(sb, relay)
        c1.stop(signal.SIGKILL)
        did = device_id(sb)
        relay.down = True
        r = run_app(sb, "disconnect", "--repo", sb.repo, "--device", did)
        check("R5", "a relay that cannot be reached is a loud failure: non-zero, says the revoke was not confirmed, keeps the login",
              r.returncode != 0 and "NOT" in (r.stdout + r.stderr) and relay.revokes == [] and len(sb.logins()) == 1)
        relay.down = False
        r = run_app(sb, "disconnect", "--repo", sb.repo, "--device", did)
        out = r.stdout + r.stderr
        check("R5", "--device for a phone whose client crashed revokes its relay session through the stored login, then removes the "
                    "login and the device record",
              r.returncode == 0 and relay.revokes == [sid] and "could NOT be revoked" not in out and not sb.logins()
              and not sb.device_records())
    finally:
        kill_leftovers(c1)
        relay.close()
        sb.drop()


def scenario_disconnect_all():
    sb, relay = Sandbox(), Relay()
    c1 = None
    try:
        c1, sid, _key = bind_phone(sb, relay)
        run_app(sb, "disconnect", "--repo", sb.repo)
        gone = wait_until(lambda: c1.proc.poll() is not None, 20)
        check("R6", "`hmd app disconnect` revokes the relay session of a live client's phone, ends the client and removes the login (the "
                    "client, stopped once its login is gone, may revoke the session once more itself: the relay takes that twice)",
              set(relay.revokes) == {sid} and bool(gone) and not sb.logins())
    finally:
        kill_leftovers(c1)
        relay.close()
        sb.drop()


def scenario_phone_revoke_and_auth():
    sb, relay = Sandbox(), Relay()
    c1 = c2 = c3 = None
    try:
        c1, sid, _key = bind_phone(sb, relay)
        relay.end(sid, "revoked")
        c1.event("session_ended")
        wait_until(lambda: c1.proc.poll() is not None, 15)
        check("R7", "a revoke from the phone ends the client and discards the login", c1.proc.poll() == 0 and not sb.logins())
        c2, _sid2, _k2 = bind_phone(sb, relay, tag="c2")
        c2.stop(signal.SIGKILL)
        relay.stream_status = 401
        c3 = Client(sb, relay, "c3", resume=True)
        ended = c3.event("session_ended")
        wait_until(lambda: c3.proc.poll() is not None, 15)
        check("R7", "a relay that refuses the stored login (stream 401) ends the client and discards the login",
              ended is not None and ended.get("reason") == "stream-401" and not sb.logins())
    finally:
        kill_leftovers(c1, c2, c3)
        relay.close()
        sb.drop()


def scenario_usr1():
    sb, relay = Sandbox(), Relay()
    c1 = None
    try:
        c1, _sid, _key = bind_phone(sb, relay)
        c1.proc.send_signal(signal.SIGUSR1)
        time.sleep(1.5)
        check("R8", "SIGUSR1 is not a revoke: the client lives on, nothing is revoked, the login stays",
              c1.proc.poll() is None and relay.revokes == [] and len(sb.logins()) == 1)
        c1.stop(signal.SIGTERM)
    finally:
        kill_leftovers(c1)
        relay.close()
        sb.drop()


FAKE_SECURITY = '''#!/usr/bin/env python3
import hashlib, os, shlex, sys
d = os.environ["FAKE_SECURITY_DIR"]
argv = sys.argv[1:]
with open(os.path.join(d, "argv.log"), "a") as f:
    f.write(" ".join(argv) + "\\n")
def run(a):
    opts = a[1:]
    def opt(flag):
        return opts[opts.index(flag) + 1] if flag in opts else ""
    path = os.path.join(d, "item-" + hashlib.sha256((opt("-s") + "/" + opt("-a")).encode()).hexdigest()[:16])
    if a[0] == "add-generic-password":
        with open(path, "w") as f:
            f.write(bytes.fromhex(opt("-X")).decode())
        return 0
    if a[0] == "find-generic-password":
        if not os.path.exists(path):
            sys.stderr.write("security: The specified item could not be found in the keychain.\\n")
            return 44
        sys.stdout.write(open(path).read() + "\\n")
        return 0
    if a[0] == "delete-generic-password":
        if os.path.exists(path):
            os.remove(path)
            return 0
        return 44
    return 1
if argv[:1] == ["-i"]:
    for line in sys.stdin:
        parts = shlex.split(line)
        if parts:
            run(parts)
    sys.exit(0)
sys.exit(run(argv))
'''


def scenario_keychain():
    sb, relay = Sandbox(), Relay()
    c1 = c2 = None
    try:
        store = os.path.join(sb.tmp, "kc")
        os.makedirs(store)
        fake = os.path.join(sb.bin, "security")
        with open(fake, "w", encoding="utf-8") as f:
            f.write(FAKE_SECURITY)
        os.chmod(fake, 0o755)
        env = dict(HMD_SESSION_LOGIN_STORE="keychain", FAKE_SECURITY_DIR=store, PATH=sb.bin + os.pathsep + os.environ["PATH"])
        c1, sid, _key = bind_phone(sb, relay, **env)
        token = relay.sessions[sid]["token"]
        items = glob.glob(os.path.join(store, "item-*"))
        with open(os.path.join(store, "argv.log"), encoding="utf-8") as f:
            argv_log = f.read()
        stored = sb.logins()
        meta = open(stored[0], encoding="utf-8").read() if stored else ""
        check("R9", "Keychain: the item holds the secret; it went over security's stdin (never argv) and the metadata file holds none",
              len(items) == 1 and token in open(items[0], encoding="utf-8").read() and token not in argv_log
              and token not in meta and bool(stored))
        c1.stop(signal.SIGKILL)
        c2 = Client(sb, relay, "c2", resume=True, **env)
        resumed = c2.event("session_resumed")
        check("R9", "Keychain: a KILLed client's session is resumed from the item", resumed is not None and relay.inits == 1)
        relay.end(sid, "revoked")
        wait_until(lambda: c2.proc.poll() is not None, 15)
        check("R9", "Keychain: the item goes with the login", not glob.glob(os.path.join(store, "item-*")) and not sb.logins())
        check("R10", "no token is in any client's output or in its event log",
              token not in c1.text() + c2.text() and not sb.tree_has(token))
    finally:
        kill_leftovers(c1, c2)
        relay.close()
        sb.drop()


def main():
    scenarios = (lambda: scenario_stop("R2", "TERM", signal.SIGTERM), lambda: scenario_stop("R3", "KILL", signal.SIGKILL),
                 scenario_expired, scenario_device_revoke, scenario_disconnect_all, scenario_phone_revoke_and_auth,
                 scenario_usr1, scenario_keychain)
    try:
        for run in scenarios:
            try:
                run()
            except Exception as e:  # a scenario that cannot even run is a failed check, and the next still runs
                check("ERR", "a scenario raised %s: %s" % (type(e).__name__, e), False)
    finally:
        for pid in STARTED:
            try:
                os.kill(pid, 0)
            except OSError:
                continue
            os.kill(pid, signal.SIGKILL)  # only a pid this run started, and only one still alive
    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

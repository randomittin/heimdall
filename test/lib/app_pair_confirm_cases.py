#!/usr/bin/env python3
"""test/lib/app_pair_confirm_cases.py -- code-only pairing (hmdapp's docs/HANDOFF-TO-HEIMDALL-pair-confirm-in-session.md):
the REAL bin/heimdall-relay-client, bin/heimdall-app, the SessionStart/SessionEnd hooks from hooks/hooks.json, the statusline,
`hmd ui`'s /api/state and heimdall-inbox-deliver, against test/lib/fake_relay_code.py on a loopback port and a `gh` script in the
sandbox's PATH (never the real relay, never the real GitHub, never a real token). Run by test/app-pair-confirm.test.sh.

The spec's nine acceptance tests, in its own numbering (a case's checks are prefixed with the number they prove):
  1  the statusline's code, bin/lib/hmd_app_code.py --repo and /api/state identity.session_code are ONE value, and it is the
     code of the session session.json records
  2  the SessionStart hook creates session.json (0600) and opens the window; the SessionEnd hook removes it and stops the window;
     a window outlives the client's own code window (the supervisor opens the next one)
  3  a claim with the same GitHub identity pairs: device_bound, no prompt, no answer on stdin, no terminal
  4  `hmd app connect --bg` pairs by code and exits 0; the exit-64 refusal is gone from the code and from the usage text
  5  a claim naming another GitHub identity is refused and nothing is revealed, derived, sealed or bound
  6  a default run puts no approve_request and no SAS in any frame or any file under .heimdall/ (the event log ON)
  7  a pairing queues an inbox notice heimdall-inbox-deliver hands the session, and the statusline says `paired via code`
     -- NOT covered: "hmd ui lists the device and revoke removes it". That is CP4 (per-device list and revoke), which does not
     exist in this tree (hmdapp's alignment doc, P1-7); the notice, the statusline note, `hmd app disconnect` (which closes
     the window) and `hmd app identity revoke` are what a pairing nobody expected can be undone with.
  8  --confirm restores the 6-digit compare (approve and reject at a terminal), and fails clearly without one or with --bg
  9  gh signed out: no window, one line, the session unaffected; two sessions in one repo keep separate codes
plus one case for each finding of the security review of hmd_session_code.py:
  S1 no state file is written, chmod'ed or read through a link
  S2 the code is not derivable from a repo path or a session id, and not taken from a file a checkout could plant
and the back-off of the pair window's token (see "B / I" below):
  B  the window re-registers its code -- the gh token is in that request -- no more often than a floor, a margin ahead of
     the lapse, and the client rides out the relay purging its lapsed session instead of ending
  I  and stops for good after HMD_PAIR_WINDOW_IDLE_H hours with no pairing and no activity in the session
"""
import argparse
import hashlib
import hmac
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import pair_code_harness as H  # noqa: E402
import statusline_sandbox as SL  # noqa: E402
from fake_relay_code import FakeCodeRelay  # noqa: E402

T = H.Tally()
E2E = H.load_module("hmd_relay_e2e", H.E2E_PATH)
CLIENT = H.load_module("hmd_relay_client", H.CLIENT_PATH)

REPO = H.REPO
SESSION_CODE_PY = os.path.join(REPO, "bin", "lib", "hmd_session_code.py")
APP_CODE_PY = os.path.join(REPO, "bin", "lib", "hmd_app_code.py")
STATUSLINE = os.path.join(REPO, "bin", "heimdall-statusline")
UI_BIN = os.path.join(REPO, "bin", "heimdall-ui")
DELIVER = os.path.join(REPO, "bin", "heimdall-inbox-deliver")
HOOKS_JSON = os.path.join(REPO, "hooks", "hooks.json")
HOOKS_META = os.path.join(REPO, "hooks", "hooks.metadata.json")
SID1 = "5b0b2d3e-1111-4222-8333-444455556666"
SID2 = "7c1c3e4f-2222-4333-8444-555566667777"
ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


# -- independent references (hashlib / hmac only, never the code under test) ----------------------------------------
def _letters(digest):
    top25 = int.from_bytes(digest[:4], "big") >> 7
    return "".join(ALPHABET[(top25 >> shift) & 0x1F] for shift in (20, 15, 10, 5, 0))


def ref_code(seed_hex, kind, raw):
    """The code of a session id (kind "session_id") or a repo path (kind "repo") under a machine's seed."""
    mac = hmac.new(bytes.fromhex(seed_hex), b"hmd-session-code-v1\x00" + kind.encode("ascii") + b"\x00" + raw.encode("utf-8"),
                   hashlib.sha256)
    return _letters(mac.digest())


def old_code(raw):
    """The derivation before the seed existed: a plain sha256 of the input -- what anyone who knows the input could compute."""
    return _letters(hashlib.sha256(raw.encode("utf-8")).digest())


# -- small helpers -------------------------------------------------------------------------------------------------
def run(argv, env, stdin=None, timeout=120, cwd=None):
    return subprocess.run(argv, input=stdin, env=env, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def wait_until(pred, timeout=15.0, step=0.1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(step)
    return bool(pred())


def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def write_private(path, text, mode=0o600):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(path, mode)


def mode_of(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def write_gh(bindir, mode):
    """A `gh` that prints H.TOKEN for `auth token` ("ok"), or says it is signed out ("signed-out")."""
    path = os.path.join(bindir, "gh")
    with open(path, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\n"
                "case \"%s\" in\n"
                "  signed-out) echo 'You are not logged into any GitHub hosts. To log in, run: gh auth login' >&2; exit 1 ;;\n"
                "esac\n"
                "if [ \"$1\" = auth ] && [ \"$2\" = token ]; then printf '%%s\\n' \"%s\"; exit 0; fi\n"
                "echo 'fake gh: unsupported' >&2\n"
                "exit 2\n" % (mode, H.TOKEN))
    os.chmod(path, 0o755)


def seed_of(heimdall_home, wait=30.0):
    """The machine's seed, once whatever is about to derive the first code has made it (a hook's background process
    records the session before it derives anything, so the file can lag the session record by a moment)."""
    path = os.path.join(heimdall_home, "session-code.key")
    wait_until(lambda: os.path.exists(path), wait)
    with open(path, encoding="ascii") as f:
        return f.read().strip()


def code_cli(env, *args):
    p = run([sys.executable, SESSION_CODE_PY] + list(args), env)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def statusline_fixture():
    path = os.path.join(tempfile.mkdtemp(prefix="pair-confirm-fixture."), "payload.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"cwd": "x", "workspace": {"current_dir": "x"}}, f)
    return path


def render(sl, sid):
    """The statusline for session `sid` in sandbox `sl`, escape codes stripped."""
    blob = json.loads(sl.claude_blob)
    blob["session_id"] = sid
    _ms, _rc, out = sl.render(STATUSLINE, json.dumps(blob).encode(), COLUMNS="200")
    return ANSI.sub("", out.decode("utf-8", "replace"))


def row_code(text):
    m = re.search(r"Opus 4\.8 · ([A-HJ-NP-Z2-9]{5})", text)
    return m.group(1) if m else None


def hook_commands():
    """{id: command} of the pair-window hooks, found by the ids hooks.metadata.json gives their (event, index)."""
    with open(HOOKS_JSON, encoding="utf-8") as f:
        hooks = json.load(f)["hooks"]
    with open(HOOKS_META, encoding="utf-8") as f:
        ids = {(e["event"], e["index"]): e["id"] for e in json.load(f)["hooks"]}
    found = {}
    for event, groups in hooks.items():
        for index, group in enumerate(groups):
            for hook in group.get("hooks", []):
                ident = ids.get((event, index))
                if ident in ("pair-window-start", "pair-window-stop"):
                    found[ident] = hook["command"]
    return found


class Scn:
    """A sandbox (HOME, repo, TMPDIR, HEIMDALL_HOME), a fake `gh`, a loopback relay and a phone."""

    def __init__(self, gh="ok", ttl=60, gh_login="octocat"):
        self.sb = H.Sandbox()
        write_gh(self.sb.bin, gh)
        self.relay = FakeCodeRelay(ttl_s=ttl, gh_login=gh_login, expect_token=H.TOKEN).start()
        self.phone = H.Phone(E2E)
        self.procs = []

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        for proc in self.procs:
            proc.stop()
        run([H.APP_PATH, "disconnect", "--repo", self.sb.repo], self.env(), timeout=120)
        self.relay.stop()
        self.sb.close()

    @property
    def repo(self):
        return self.sb.repo

    @property
    def home(self):
        return os.path.join(self.sb.home, ".heimdall")

    def env(self, **extra):
        return self.sb.env(PATH=self.sb.bin + os.pathsep + os.environ.get("PATH", ""), HMD_RELAY_URL=self.relay.url, **extra)

    def app(self, *args, tty=False, env=None):
        argv = [H.APP_PATH, "connect", "--repo", self.repo, "--port", "0"] + list(args)
        proc = H.Proc(argv, self.env(**(env or {})), cwd=self.repo, tty=tty)
        self.procs.append(proc)
        return proc

    def client(self, code, extra=("--no-confirm",), repo=None, env=None):
        argv = [H.CLIENT_PATH, "--relay", self.relay.url, "--repo", repo or self.repo, "--ui-port", "1", "--code", code] + list(extra)
        proc = H.Proc(argv, self.env(**(env or {})))
        self.procs.append(proc)
        proc.send(H.TOKEN + "\n")  # the token on stdin and nothing after it: there is nobody to answer a question
        return proc

    def bind(self, sid=None, **kw):
        sid = sid or self.relay.latest().id
        self.relay.inject_device_bound(sid, self.phone.pub_b64url, **kw)
        return sid

    def paired_state(self, sid, timeout=30):
        """(the first state frame opened the way the phone opens it, hmd's revealed key)."""
        wait_until(lambda: self.relay.frames_of(sid, "state"), timeout)
        reveals, states = self.relay.frames_of(sid, "key_reveal"), self.relay.frames_of(sid, "state")
        if not reveals or not states:
            return None, b""
        hmd_pub = H.b64_any(reveals[0]["payload"]["hmd_pubkey"])
        return self.phone.open_hmd_frame(hmd_pub, sid, states[0]), hmd_pub

    def window_code(self):
        wait_until(lambda: self.relay.registrations, 40)
        return self.relay.registrations[0]["code"] if self.relay.registrations else None

    def hook(self, ident, sid, payload=None, **extra):
        env = self.env(CLAUDE_PLUGIN_ROOT=REPO, CLAUDE_PROJECT_DIR=self.repo, **extra)
        stdin = json.dumps(dict({"session_id": sid, "source": "startup"}, **(payload or {})))
        return run(["sh", "-c", hook_commands()[ident]], env, stdin=stdin, timeout=60, cwd=self.repo)

    def window_state(self, sid):
        try:
            with open(os.path.join(self.repo, ".heimdall", "app", "pair-window-%s.json" % sid), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None


# -- 1 -------------------------------------------------------------------------------------------------------------
def case_one_code():
    sl = SL.Sandbox(statusline_fixture())
    try:
        env = sl.env()
        code_cli(env, "--session-id", "seed-probe")  # the first use makes the machine's seed
        seed = seed_of(os.path.join(sl.home, ".heimdall"))
        expected = ref_code(seed, "session_id", SID1)
        app_dir = os.path.join(sl.ws, ".heimdall", "app")
        os.makedirs(app_dir, exist_ok=True)
        os.chmod(app_dir, 0o700)
        session = os.path.join(app_dir, "session.json")
        write_private(session, json.dumps({"session_id": SID1, "pid": os.getpid(), "ts": int(time.time())}))
        line_code = row_code(render(sl, SID1))
        helper = run([sys.executable, APP_CODE_PY, "--repo", sl.ws], env).stdout.strip()
        state = run([UI_BIN, "--repo", sl.ws, "--print-state"], env, timeout=180)
        try:
            shown = json.loads(state.stdout)["identity"]["session_code"]
        except (ValueError, KeyError, TypeError):
            shown = None
        T.check(line_code == helper == shown == expected and len(expected) == 5,
                "1. with session.json present the statusline code, hmd_app_code.py --repo and /api/state identity.session_code "
                "are one value, the code of the recorded session",
                "statusline %r helper %r state %r expected %r" % (line_code, helper, shown, expected))
        os.unlink(session)
        bare = run([sys.executable, APP_CODE_PY, "--repo", sl.ws], env).stdout.strip()
        gone = subprocess.Popen(["true"])
        gone.wait()
        write_private(session, json.dumps({"session_id": SID1, "pid": gone.pid, "ts": 1}))
        dead = run([sys.executable, APP_CODE_PY, "--repo", sl.ws], env).stdout.strip()
        T.check(bare != expected and dead == bare,
                "1. without session.json, or with one whose process is gone, hmd_app_code.py falls back to the repo's own code "
                "(it is the file that makes the codes agree)", "bare %r dead %r expected %r" % (bare, dead, expected))
    finally:
        sl.close()


# -- 2 -------------------------------------------------------------------------------------------------------------
def case_hooks():
    with Scn() as s:
        cmds = hook_commands()
        T.check(sorted(cmds) == ["pair-window-start", "pair-window-stop"],
                "2. hooks.json carries both pair-window hooks, registered in hooks.metadata.json under those ids", str(sorted(cmds)))
        started = s.hook("pair-window-start", SID1)
        session = os.path.join(s.repo, ".heimdall", "app", "session.json")
        T.check(wait_until(lambda: os.path.exists(session), 20) and started.returncode == 0 and started.stdout == "",
                "2. SessionStart: session.json is created, and the hook says nothing a session would put in front of the model",
                "rc %r out %r err %r" % (started.returncode, started.stdout, started.stderr))
        try:
            with open(session, encoding="utf-8") as f:
                rec = json.load(f)
        except (OSError, ValueError):
            rec = {}
        T.check(mode_of(session) == 0o600 and sorted(rec) == ["pid", "session_id", "ts"] and rec.get("session_id") == SID1
                and rec.get("pid") == os.getpid(),
                "2. session.json is 0600 and is exactly {session_id, pid, ts}, owned by the hook's parent process", str(rec))
        seed = seed_of(s.home)
        T.check(wait_until(lambda: s.relay.registrations, 30) and s.relay.registrations[0]["code"] == ref_code(seed, "session_id", SID1)
                and s.relay.registrations[0]["token_ok"],
                "2. the window is registered with the relay under the session's code, with gh's token",
                str(s.relay.registrations[:1]))
        state = s.window_state(SID1) or {}
        sup = state.get("pid")
        T.check(isinstance(sup, int) and alive(sup) and state.get("code") == ref_code(seed, "session_id", SID1),
                "2. a supervisor is running for the session and names its code", str(state))
        window_sid = s.relay.latest().id
        stopped = s.hook("pair-window-stop", SID1)
        T.check(stopped.returncode == 0 and not os.path.exists(session),
                "2. SessionEnd: session.json is gone", "rc %r %s" % (stopped.returncode, stopped.stderr))
        T.check(isinstance(sup, int) and wait_until(lambda: not alive(sup), 30) and wait_until(lambda: window_sid in s.relay.revokes, 30),
                "2. the supervisor is gone and its relay session was revoked", "alive %r revokes %r" % (alive(sup), s.relay.revokes))
    # a window with no terminal outlives the client's own code window: the supervisor opens the next one
    knobs = {"HMD_RELAY_CODE_WINDOW_S": "3", "HMD_RELAY_CODE_RENEW_MARGIN_S": "0.2", "HMD_RELAY_CODE_RENEW_MIN_S": "0.5",
             "HMD_PAIR_WINDOW_RESTART_S": "1"}
    with Scn(ttl=2) as s:
        out = run([H.APP_PATH, "pair-window", "--session", SID1, "--pid", str(os.getpid()), "--repo", s.repo, "--relay", s.relay.url],
                  s.env(**knobs))
        T.check(out.returncode == 0 and "pair window open" in out.stdout,
                "2. `hmd app pair-window --session SID --pid N` opens the window and says so on one line", out.stdout + out.stderr)
        span = lambda: (s.relay.registrations[-1]["at"] - s.relay.registrations[0]["at"]) if s.relay.registrations else 0.0
        wait_until(lambda: span() >= 5.0, 60)
        regs = list(s.relay.registrations)
        sup = (s.window_state(SID1) or {}).get("pid")
        T.check(span() >= 5.0 and len({r["code"] for r in regs}) == 1 and isinstance(sup, int) and alive(sup),
                "2. past the client's own 3 s window the code is registered again (a new client), the same code, supervisor alive",
                "span %.1f regs %d" % (span(), len(regs)))


# -- 3 -------------------------------------------------------------------------------------------------------------
def case_auto_pair():
    with Scn() as s:
        c = s.client(H.CODE)
        c.wait_event("code_window")
        sid = s.bind(device_label="Pixel 9a")
        bound = c.wait_event("device_bound", timeout=20)
        opened, hmd_pub = s.paired_state(sid)
        frames = [(env.get("type")) for ssid, env in s.relay.frames if ssid == sid]
        T.check(bool(bound) and c.count_events("approve_request") == 0 and c.p.stdin is not None and not c.p.stdin.closed,
                "3. a claim with the same GitHub identity: device_bound is emitted with no prompt, no answer on stdin, no terminal",
                c.tail())
        T.check(opened is not None and "state" in opened and "key_reveal" in frames and "state" in frames
                and frames.index("key_reveal") < frames.index("state"),
                "3. the key reveal still precedes the bind, and the first state frame opens under the key derived from it",
                str(frames))
    with Scn() as s:  # and through `hmd app connect` itself, at no terminal
        app = s.app("--relay", s.relay.url)
        T.check(app.wait_text("SESSION CODE:", 60), "3. connect (stdin a pipe) offers the code", app.tail())
        sid = s.relay.latest().id
        s.bind(sid, device_label="Pixel 9a")
        T.check(app.wait_text("phone paired via code", 30) and "Approve [y/N]" not in app.text() and "The phone shows" not in app.text(),
                "3. connect says the phone paired, by code, and never asks", app.tail())
        T.check("relay-claimed device 'Pixel 9a'" in app.text() and "GitHub @octocat" in app.text(),
                "3. the line names the device and the account, marked as the relay's claim", app.tail())


# -- 4 -------------------------------------------------------------------------------------------------------------
def case_bg():
    with Scn() as s:
        app = s.app("--relay", s.relay.url, "--bg")
        app.close_stdin()
        rc = app.wait_exit(90)
        T.check(rc == 0 and "SESSION CODE:" in app.text() and "running in background" in app.text(),
                "4. connect --bg pairs by code and exits 0 (the code is on screen when it leaves)", "rc %r %s" % (rc, app.tail()))
        sid = s.relay.latest().id
        s.bind(sid)
        opened, _pub = s.paired_state(sid)
        T.check(opened is not None, "4. ...and the detached client pairs a claim by itself", "")
    with Scn() as s:
        app = s.app("--relay", s.relay.url, "--bg", "--no-confirm")
        app.close_stdin()
        rc = app.wait_exit(90)
        T.check(rc == 0 and "SESSION CODE:" in app.text(), "4. --no-confirm stays accepted, and means the default", "rc %r %s" % (rc, app.tail()))
    help_text = run([H.APP_PATH, "--help"], {"PATH": os.environ.get("PATH", "")}).stdout
    source = open(H.APP_PATH, encoding="utf-8").read()
    gone = ("drop --bg", "--bg needs it", "and no --no-confirm", "confirms at this terminal", "no terminal to confirm a phone at")
    T.check(not [g for g in gone if g in help_text or g in source] and "--confirm" in help_text and "pair-window" in help_text,
            "4. the exit-64 --bg refusal and the no-terminal drop are gone from the code and the usage text; --confirm and pair-window are in it",
            str([g for g in gone if g in help_text or g in source]))
    with Scn() as s:
        app = s.app("--relay", s.relay.url, "--confirm", "--bg")
        app.close_stdin()
        rc = app.wait_exit(60)
        T.check(rc == 64 and "--confirm" in app.err().decode("utf-8", "replace") and s.relay.pair_inits == [],
                "4. --confirm with --bg is the one refusal left: exit 64, a clear line, nothing started", "rc %r %s" % (rc, app.tail()))


# -- 5 -------------------------------------------------------------------------------------------------------------
def case_identity_mismatch():
    with Scn() as s:
        c = s.client(H.CODE)
        c.wait_event("code_window")
        sid = s.bind(gh_login="mallory")
        refused = c.wait_event("code_rejected", where=lambda e: e.get("reason") == "identity-mismatch", timeout=15)
        wait_until(lambda: len(s.relay.registrations) >= 2, 20)
        status = {}
        try:
            with open(os.path.join(s.repo, ".heimdall", "app", "relay.json"), encoding="utf-8") as f:
                status = json.load(f)
        except (OSError, ValueError):
            status = {}
        time.sleep(0.5)
        T.check(bool(refused) and c.count_events("device_bound") == 0 and s.relay.frames_of(sid, "key_reveal") == []
                and s.relay.frames_of(sid, "state") == [] and s.relay.frames_of(sid, "ack") == [] and status.get("paired") is False
                and sid in s.relay.revokes,
                "5. a claim naming another GitHub identity is refused: no key revealed, nothing sealed, nothing bound, the session revoked",
                c.tail())
        T.check(len(s.relay.registrations) >= 2 and s.relay.registrations[1]["code"] == H.CODE,
                "5. ...and the window renews under the same code", str(len(s.relay.registrations)))
        sid2 = s.bind()
        bound = c.wait_event("device_bound", timeout=20)
        opened, _pub = s.paired_state(sid2)
        T.check(bool(bound) and opened is not None, "5. ...so the right phone can still pair afterwards", c.tail())


# -- 6 -------------------------------------------------------------------------------------------------------------
def case_no_sas_anywhere():
    with Scn() as s:
        log = os.path.join(s.repo, ".heimdall", "app", "relay-events.jsonl")
        app = s.app("--relay", s.relay.url, "--bg", env={"HMD_RELAY_EVENT_LOG": log})
        app.close_stdin()
        app.wait_exit(90)
        sid = s.relay.latest().id
        s.bind(sid)
        opened, hmd_pub = s.paired_state(sid)
        sas = H.sas_ref(sid, hmd_pub, s.phone.pub) if hmd_pub else "000000"
        wait_until(lambda: os.path.exists(log) and "code_paired" in open(log, encoding="utf-8").read(), 20)
        needle = re.compile(r"(?<!\d)%s(?!\d)" % sas)
        hits = []
        for base, _dirs, names in os.walk(os.path.join(s.repo, ".heimdall")):
            for name in names:
                path = os.path.join(base, name)
                try:
                    data = open(path, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                if "approve_request" in data or needle.search(data):
                    hits.append(path)
        wire = json.dumps(s.relay.frames, sort_keys=True)
        T.check(opened is not None and os.path.exists(log) and hits == [],
                "6. a default run leaves no approve_request and no SAS in any file under .heimdall/ (the event log on, and it has the pairing)",
                str(hits))
        T.check("approve" not in wire and '"sas"' not in wire and not needle.search(wire) and "approve" not in app.text()
                and "phone shows" not in app.text(),
                "6. ...nor in any frame the phone is sent, nor in connect's output", app.tail())
        opened_text = json.dumps(opened, sort_keys=True) if opened else ""
        T.check('"sas"' not in opened_text and not needle.search(opened_text),
                "6. ...nor inside the first sealed state the phone opens", "")


# -- 7 -------------------------------------------------------------------------------------------------------------
def case_notice_and_statusline():
    sl = SL.Sandbox(statusline_fixture())
    with Scn() as s:
        try:
            ok, code, err = code_cli(sl.env(), "--session-id", SID1)
            T.check(ok == 0 and len(code) == 5, "7. (setup) the session's code", err)
            c = s.client(code, repo=sl.ws)
            c.wait_event("code_window")
            T.check("paired via code" not in render(sl, SID1), "7. before anyone pairs the statusline has no pairing note")
            sid = s.bind(device_label="Pixel 9a")
            c.wait_event("device_bound", timeout=20)
            inbox = os.path.join(sl.ws, ".heimdall", "ui", "inbox.jsonl")
            wait_until(lambda: os.path.exists(inbox) and os.path.getsize(inbox) > 0, 15)
            records = [json.loads(line) for line in open(inbox, encoding="utf-8").read().splitlines() if line.strip()] \
                if os.path.exists(inbox) else []
            text = records[0]["text"] if records else ""
            T.check(len(records) == 1 and "paired" in text and "Pixel 9a" in text and "@octocat" in text and code in text,
                    "7. the pairing queues one inbox notice naming the code, the device and the account (as the relay claimed them)", text)
            delivered = run([DELIVER, "prompt", "--repo", sl.ws], sl.env(),
                            stdin=json.dumps({"hook_event_name": "UserPromptSubmit", "cwd": sl.ws}))
            try:
                context = json.loads(delivered.stdout)["hookSpecificOutput"]["additionalContext"]
            except (ValueError, KeyError, TypeError):
                context = ""
            T.check("Pixel 9a" in context and "paired" in context,
                    "7. heimdall-inbox-deliver hands the Claude session that notice", delivered.stdout[:300])
            marker = os.path.join(sl.ws, ".heimdall", "app", "paired-%s.json" % code)
            shown = render(sl, SID1)
            T.check(os.path.exists(marker) and mode_of(marker) == 0o600 and "paired via code" in shown and "Pixel 9a" in shown,
                    "7. the statusline says `paired via code` with the device, from a 0600 marker the client keeps", shown[:400])
            c.stop()
            gone = wait_until(lambda: not os.path.exists(marker), 15)
            T.check(gone and "paired via code" not in render(sl, SID1),
                    "7. when the client ends the marker goes and the note with it", "")
        finally:
            sl.close()


# -- 8 -------------------------------------------------------------------------------------------------------------
def case_confirm():
    with Scn() as s:
        app = s.app("--relay", s.relay.url, "--confirm", tty=True)
        app.wait_text("SESSION CODE:", 60)
        sid = s.bind(device_label="Pixel 9a")
        shown = app.wait_text("Approve [y/N]:", 30)
        reveals = s.relay.frames_of(sid, "key_reveal")
        hmd_pub = H.b64_any(reveals[0]["payload"]["hmd_pubkey"]) if reveals else b""
        sas = H.sas_ref(sid, hmd_pub, s.phone.pub)
        T.check(shown and ("The phone shows:  %s %s" % (sas[:3], sas[3:])) in app.text() and s.relay.frames_of(sid, "state") == [],
                "8. --confirm restores the compare: the prompt shows the SAS the phone computes, and nothing is sealed while it waits",
                app.tail())
        app.send("y\n")
        app.wait_text("phone paired", 30)
        opened, _pub = s.paired_state(sid)
        T.check("phone paired" in app.text() and opened is not None, "8. y at the terminal pairs the session", app.tail())
    with Scn() as s:
        app = s.app("--relay", s.relay.url, "--confirm", tty=True)
        app.wait_text("SESSION CODE:", 60)
        sid = s.bind()
        app.wait_text("Approve [y/N]:", 30)
        app.send("n\n")
        app.wait_text("pairing rejected", 30)
        wait_until(lambda: len(s.relay.registrations) >= 2, 30)
        T.check("pairing rejected" in app.text() and sid in s.relay.revokes and s.relay.frames_of(sid, "state") == []
                and len(s.relay.registrations) >= 2,
                "8. n rejects: the session is revoked, nothing was sealed, the window renews", app.tail())
    with Scn() as s:
        app = s.app("--relay", s.relay.url, "--confirm")
        app.close_stdin()
        rc = app.wait_exit(60)
        err = app.err().decode("utf-8", "replace")
        T.check(rc == 64 and "--confirm" in err and "terminal" in err and s.relay.pair_inits == [],
                "8. --confirm without a terminal fails clearly (exit 64, says why) and starts nothing", "rc %r %s" % (rc, app.tail()))


# -- 9 -------------------------------------------------------------------------------------------------------------
def case_gh_signed_out_and_two_sessions():
    with Scn(gh="signed-out") as s:
        out = run([H.APP_PATH, "pair-window", "--session", SID1, "--pid", str(os.getpid()), "--repo", s.repo], s.env())
        lines = [ln for ln in out.stdout.splitlines() if ln.strip()]
        T.check(out.returncode == 0 and len(lines) == 1 and "Scan the QR" in lines[0] and s.relay.pair_inits == []
                and s.relay.requests == [],
                "9. gh signed out: no window, one line saying to scan the QR, the relay never contacted", out.stdout + out.stderr)
        started = s.hook("pair-window-start", SID1)
        T.check(started.returncode == 0 and started.stdout == "" and wait_until(
                lambda: os.path.exists(os.path.join(s.repo, ".heimdall", "app", "session.json")), 20) and s.relay.requests == [],
                "9. ...and the SessionStart hook is silent and the session unaffected (the session is still recorded, no window opens)",
                "rc %r out %r" % (started.returncode, started.stdout))
    with Scn() as s:
        args = ["--pid", str(os.getpid()), "--repo", s.repo, "--relay", s.relay.url]
        first = run([H.APP_PATH, "pair-window", "--session", SID1] + args, s.env())
        second = run([H.APP_PATH, "pair-window", "--session", SID2] + args, s.env())
        T.check(first.returncode == 0 and second.returncode == 0 and wait_until(lambda: len(s.relay.registrations) >= 2, 40),
                "9. two sessions in one repo each open a window", first.stdout + second.stdout)
        seed = seed_of(s.home)
        want = {ref_code(seed, "session_id", SID1), ref_code(seed, "session_id", SID2)}
        got = {r["code"] for r in s.relay.registrations}
        pids = [(s.window_state(sid) or {}).get("pid") for sid in (SID1, SID2)]
        T.check(len(want) == 2 and got == want and all(isinstance(p, int) and alive(p) for p in pids),
                "9. ...and keep separate codes, each the one its session's statusline shows, both windows alive together",
                "want %s got %s pids %s" % (sorted(want), sorted(got), pids))
        run([H.APP_PATH, "pair-window", "--stop", "--session", SID2, "--repo", s.repo], s.env())
        T.check(isinstance(pids[1], int) and wait_until(lambda: not alive(pids[1]), 30) and alive(pids[0]),
                "9. stopping one session's window leaves the other's open", "pids %s" % pids)
        run([H.APP_PATH, "pair-window", "--stop", "--session", SID1, "--repo", s.repo], s.env())
        T.check(isinstance(pids[0], int) and wait_until(lambda: not alive(pids[0]), 30), "9. ...and then it closes too", "")


# -- B / I: the pair window sends the token far less often, and stops when nobody is there -------------------------------
# A window with no terminal re-registers its code with the relay each time the relay's registration of it lapses, and the
# laptop's gh token is in that request's body. The relay keeps a registration PAIRING_CODE_TTL_S = 60 s (relay/src/pairing.ts;
# `pair_window_s` in relay/contract/code-pair.json), so the token went out once a minute for as long as the session lived.
#   B  now it goes out no more often than HMD_PAIR_WINDOW_RENEW_MIN_S (300 s) after the last time -- and a margin ahead of
#      the lapse, with the old registration freed first so the relay does not refuse the new one as a clash, whenever the
#      relay keeps a registration longer than that. Against the relay's real 60 s the floor wins: the code is claimable for
#      the minute after each registration and dark in between, which is the price of the back-off
#   I  and the window stops for good after HMD_PAIR_WINDOW_IDLE_H hours (4; 0 never) with no pairing and no activity in the
#      session (the modification time of the transcript the SessionStart hook hands it); a new session, or `hmd app connect`,
#      opens it again. Time is injected (HMD_PAIR_WINDOW_NOW_FILE) and the relay's timings are scaled down: nothing sleeps hours.
def simulated_renewals(due, ttl, hours):
    """(registered_at, lapses_at) of every registration over `hours` of simulated time against a relay that keeps one `ttl`
    seconds, each renewed when `due(registered_at, lapses_at)` says. No clock is read and nothing sleeps; a schedule that does
    not move on ends the run (the checks that follow fail it) instead of spinning here."""
    regs, t = [], 0.0
    while t < hours * 3600 and len(regs) < 100000:
        regs.append((t, t + ttl))
        nxt = due(t, t + ttl)
        if nxt <= t:
            break
        t = nxt
    return regs


def case_renewal_schedule():
    due = getattr(CLIENT, "code_renewal_due", None)
    T.check(callable(due), "B1. the relay client schedules a code window's renewal in one pure function, code_renewal_due()")
    if not callable(due):
        return
    floor, lead = 300.0, 10.0
    schedule = lambda registered, lapses: due(registered, lapses, floor, lead)
    for ttl in (60, 290, 305, 600, 3600):
        regs = simulated_renewals(schedule, ttl, 4)
        gaps = [b[0] - a[0] for a, b in zip(regs, regs[1:])]
        most = max(sum(1 for other in regs if at <= other[0] < at + 300.0) for at, _lapse in regs)
        T.check(len(regs) >= 2 and most == 1 and min(gaps) >= floor - 1e-9,
                "B1. against a relay that keeps a registration %d s: over 4 simulated hours never more than one renewal in any 5 minutes (%d in all)"
                % (ttl, len(regs)), "most in 5 min %d, first gaps %s" % (most, gaps[:3]))
    for ttl in (305, 600, 3600):
        regs = simulated_renewals(schedule, ttl, 4)
        pairs = list(zip(regs, regs[1:]))
        T.check(bool(pairs) and all(b[0] < a[1] and a[1] - b[0] <= lead + 1e-9 for a, b in pairs),
                "B2. a relay that keeps a registration %d s is renewed before it lapses, never more than the %d s margin ahead" % (ttl, lead),
                str([round(a[1] - b[0], 1) for a, b in pairs[:3]]))
    regs = simulated_renewals(schedule, 60, 4)
    pairs = list(zip(regs, regs[1:]))
    T.check(len(regs) == 48 and bool(pairs) and all(abs((b[0] - a[0]) - 300.0) < 1e-9 and abs((b[0] - a[1]) - 240.0) < 1e-9 for a, b in pairs),
            "B3. against the relay's real 60 s the 5-minute floor wins: 48 registrations in 4 hours, each renewed 300 s after the last "
            "(the code is dark for the 240 s between a lapse and the next)", "%d registrations" % len(regs))
    T.check(abs(due(0.0, 60.0, 5.0, -1.5) - 61.5) < 1e-9 and abs(due(0.0, 2.0, 0.5, 10.0) - 1.0) < 1e-9,
            "B4. `hmd app connect`'s own schedule is unchanged (5 s floor, renewed 1.5 s after the lapse), and a short registration is never renewed "
            "at once, over and over, by a long margin (the margin is capped at half its life)",
            "connect %r short %r" % (due(0.0, 60.0, 5.0, -1.5), due(0.0, 2.0, 0.5, 10.0)))


def offline_client(sandbox):
    """A RelayClient pointed at a port nothing listens on, for what is decided in memory (the way
    test/lib/app_pair_code_client_cases.py drives one)."""
    return CLIENT.RelayClient(argparse.Namespace(relay="http://127.0.0.1:1", repo=sandbox.repo, tick_s=2.0,
                                                 status_file=os.path.join(sandbox.root, "relay.json"), public_host=None, ui_port=1))


def case_stream_waits_for_renewal():
    sandbox = H.Sandbox()
    try:
        client = offline_client(sandbox)
        now = time.monotonic()
        client._last_renew_at, client._code_renew_at = now, now + 3.0
        client._renew_now.clear()
        due_of = getattr(client, "_renewal_due", None)
        if callable(due_of):
            scheduled = due_of()
            client._renew_now.set()
            asked = due_of()
            client._renew_now.clear()
            T.check(abs(scheduled - (now + 3.0)) < 1e-6 and abs(asked - (now + CLIENT.CODE_RENEW_MIN_S)) < 1e-6,
                    "B5. the schedule says when the registration is about to lapse; an event (a bind refused, the relay ending the session) asks for "
                    "the renewal at once, but never sooner than the floor after the last", "scheduled %+.2f s, asked %+.2f s" % (scheduled - now, asked - now))
        else:
            T.check(False, "B5. the client answers when its next renewal is due in one place, _renewal_due()")
        # The relay purges a registration nobody claimed 60 s after it lapsed and tells hmd's stream; the stream thread then waits for
        # the replacement. With a 5-minute floor that replacement is minutes away, and a fixed 30 s of patience would end the client
        # (exit 0) for the supervisor to relaunch -- sending the token again, long before the floor.
        epoch = client._stream_epoch
        threading.Timer(1.2, lambda: setattr(client, "_stream_epoch", epoch + 1)).start()  # the renewal swaps the session in 1.2 s
        began = time.monotonic()
        swapped = client._await_window_swap(epoch, timeout=0.4)
        T.check(swapped, "B5. a stream whose session was purged waits for the renewal that is scheduled; it does not give up on a fixed patience",
                "gave up after %.1f s with the renewal due in %.1f s" % (time.monotonic() - began, now + 3.0 - time.monotonic()))
    finally:
        sandbox.close()


class purging_lapsed_sessions:
    """What the real relay's storage alarm does to a registration nobody claimed -- PURGE_GRACE_MS, 60 s after it lapses; `after_s`
    here -- ends the session and tells hmd's stream so (a session_ended, then a stream that answers 410)."""

    def __init__(self, relay, after_s):
        self.relay, self.after_s, self.stop = relay, after_s, threading.Event()

    def _run(self):
        done = set()
        while not self.stop.wait(0.1):
            with self.relay.lock:
                sessions = list(self.relay.sessions.values())
            for sess in sessions:
                if sess.id not in done and not sess.ended and time.time() >= sess.exp + self.after_s:
                    done.add(sess.id)
                    self.relay.end_session(sess.id, "pairing-expired")

    def __enter__(self):
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.stop.set()
        self.thread.join(5)


def one_live_window_per_code(relay):
    """relay/src/code-index.ts registerEntry, for the fake: a code another session of the account holds -- not lapsed, not revoked --
    is refused with the 409 the real relay answers, so a renewal ahead of the lapse that does not free the old one first is refused."""
    held = {}

    def answer(registration):
        sid, code = registration["session_id"], registration["code"]
        other = held.get(code)
        if other is not None and other != sid and relay.get(other).exp > time.time() and other not in relay.revokes:
            return 409, {"error": "code in use by another open window"}
        held[code] = sid
        return None
    return answer


def start_window(s, sid=SID1, transcript=None, **knobs):
    """`hmd app pair-window` for session `sid`, owned by this process, against the scenario's relay; `knobs` go to the supervisor."""
    argv = [H.APP_PATH, "pair-window", "--session", sid, "--pid", str(os.getpid()), "--repo", s.repo, "--relay", s.relay.url]
    if transcript:
        argv += ["--transcript", transcript]
    return run(argv, s.env(**knobs))


def window_pid(s, sid=SID1, timeout=20):
    wait_until(lambda: s.window_state(sid), timeout)
    pid = (s.window_state(sid) or {}).get("pid")
    return pid if isinstance(pid, int) else None


def case_renewal_floor_live():
    # A registration lasts 2 s here and the floor is 8 s (the real relay: 60 s and 300 s). The old loop renewed about 5 s on, and the
    # purge a relay does of a lapsed session lands inside the floor: the client has to ride it out, not end and be relaunched.
    knobs = {"HMD_PAIR_WINDOW_RENEW_MIN_S": "8", "HMD_RELAY_CODE_RENEW_MARGIN_S": "0.2", "HMD_PAIR_WINDOW_RESTART_S": "1"}
    with Scn(ttl=2) as s, purging_lapsed_sessions(s.relay, 2.0):
        out = start_window(s, **knobs)
        if not (out.returncode == 0 and wait_until(lambda: s.relay.registrations, 40)):
            T.check(False, "B6. (setup) the window opens and registers its code", out.stdout + out.stderr)
            return
        t0 = s.relay.registrations[0]["at"]
        time.sleep(max(0.0, t0 + 7.0 - time.time()))
        early = len(s.relay.registrations)
        wait_until(lambda: len(s.relay.registrations) >= 2, 30)
        regs = list(s.relay.registrations)
        gap = regs[1]["at"] - regs[0]["at"] if len(regs) >= 2 else 0.0
        T.check(early == 1 and gap >= 7.6,
                "B6. with a floor of 8 s the token goes out once in the first 7 s, and the next registration comes after the floor (not ~5 s on)",
                "registrations in the first 7 s: %d, first gap %.1f s" % (early, gap))
        T.check(len({r["code"] for r in regs}) == 1 and alive(window_pid(s) or 0),
                "B6. ...the same code each time, and the supervisor never ended", str(len(regs)))


def case_renewal_before_lapse_live():
    # A registration lasts 8 s, the floor is 2 s and the margin 3 s: each renewal is due about 5 s on, inside the registration.
    knobs = {"HMD_PAIR_WINDOW_RENEW_MIN_S": "2", "HMD_PAIR_WINDOW_RENEW_LEAD_S": "3", "HMD_RELAY_CODE_RENEW_MARGIN_S": "0.2"}
    with Scn(ttl=8) as s:
        s.relay.code_status = one_live_window_per_code(s.relay)
        out = start_window(s, **knobs)
        if not (out.returncode == 0 and wait_until(lambda: len(s.relay.registrations) >= 3, 60)):
            T.check(False, "B7. (setup) the window registers three times", "%s %s registrations %d" % (out.stdout, out.stderr, len(s.relay.registrations)))
            return
        regs, reqs = list(s.relay.registrations)[:3], list(s.relay.requests)
        before = [regs[i + 1]["at"] < s.relay.get(regs[i]["session_id"]).exp for i in (0, 1)]
        gaps = [regs[i + 1]["at"] - regs[i]["at"] for i in (0, 1)]
        T.check(all(before) and all(g >= 1.9 for g in gaps),
                "B7. a relay that keeps a registration longer than the floor sees each renewal before the last one lapses, and not before the floor",
                "before lapse %s, gaps %s" % (before, [round(g, 1) for g in gaps]))
        at = lambda line: reqs.index(line) if line in reqs else float("inf")
        freed = [at("POST /session/%s/revoke" % regs[i]["session_id"]) < at("POST /session/%s/code" % regs[i + 1]["session_id"]) for i in (0, 1)]
        T.check(len({r["session_id"] for r in regs}) == 3 and all(freed),
                "B7. the old registration is freed first, so the relay does not refuse the new one as a clash and the token is not sent a second time",
                "sessions %d, freed first %s" % (len({r["session_id"] for r in regs}), freed))


class Clock:
    """The window supervisor's injected clock: HMD_PAIR_WINDOW_NOW_FILE names a file holding the epoch second it reads as now, so
    rewriting the file moves hours of idle time in no time at all."""

    def __init__(self, root):
        self.path = os.path.join(root, "pair-window-now")
        self.base = int(time.time())
        self.set(0)

    def set(self, offset_s):
        tmp = self.path + ".tmp"
        write_private(tmp, "%d\n" % (self.base + int(offset_s)))
        os.replace(tmp, self.path)


def idle_knobs(clock, **extra):
    return dict({"HMD_PAIR_WINDOW_NOW_FILE": clock.path, "HMD_PAIR_WINDOW_POLL_S": "0.2"}, **extra)


def open_window_or_fail(s, label, **kw):
    """Start the window and wait for its first registration; the supervisor's pid, or None after a failed check."""
    out = start_window(s, **kw)
    if out.returncode == 0 and wait_until(lambda: s.relay.registrations, 40):
        return window_pid(s)
    T.check(False, "%s (setup) the window opens and registers its code" % label, "rc %r %s %s" % (out.returncode, out.stdout, out.stderr))
    return None


def case_idle_stop():
    with Scn() as s:
        clock = Clock(s.sb.root)
        knobs = idle_knobs(clock)
        sup = open_window_or_fail(s, "I1.", **knobs)
        if sup is None:
            return
        window_sid = s.relay.latest().id
        kids = [int(p) for p in run(["pgrep", "-P", str(sup)], s.env()).stdout.split()]
        argvs = [H.argv_of(p) for p in [sup] + kids]
        clock.set(4 * 3600 - 120)
        time.sleep(1.5)
        T.check(alive(sup) and s.window_state(SID1) is not None and len(s.relay.registrations) == 1,
                "I1. four hours less two minutes with no pairing and no activity: the window is still open (the default is four hours)",
                "alive %r state %r registrations %d" % (alive(sup), s.window_state(SID1), len(s.relay.registrations)))
        clock.set(4 * 3600 + 120)
        stopped = wait_until(lambda: not alive(sup), 25)
        revoked = wait_until(lambda: window_sid in s.relay.revokes, 20)
        T.check(stopped and revoked and s.window_state(SID1) is None,
                "I1. four hours and two minutes: the supervisor ends, its relay session is revoked and its state file is gone -- nothing says a window is live",
                "stopped %r revoked %r state %r" % (stopped, revoked, s.window_state(SID1)))
        time.sleep(1.0)
        session = os.path.join(s.repo, ".heimdall", "app", "session.json")
        T.check(len(s.relay.registrations) == 1 and os.path.exists(session),
                "I1. the code is not registered again, and the session stays recorded (so `hmd app connect` and the statusline still agree on its code)",
                "registrations %d, session.json %r" % (len(s.relay.registrations), os.path.exists(session)))
        needle = H.TOKEN.encode()
        leaks = H.files_containing(s.repo, needle) + H.files_containing(s.sb.home, needle) + H.files_containing(s.sb.tmp, needle)
        T.check(kids and not any(H.TOKEN in a for a in argvs) and leaks == [],
                "I1. the token was in no argv of the supervisor or its client, and is in no file under the repo, the home or the temp dir: only on the pipe",
                "argvs %r leaks %r" % (argvs, leaks))
        again = start_window(s, **knobs)  # a new session
        reopened = again.returncode == 0 and "pair window open" in again.stdout and wait_until(lambda: len(s.relay.registrations) >= 2, 40)
        new_sup = window_pid(s)
        T.check(bool(reopened) and new_sup is not None and new_sup != sup and alive(new_sup),
                "I1. a new session opens the window again", "rc %r out %r pid %r" % (again.returncode, again.stdout, new_sup))


def case_idle_stop_off():
    with Scn() as s:
        clock = Clock(s.sb.root)
        sup = open_window_or_fail(s, "I2.", **idle_knobs(clock, HMD_PAIR_WINDOW_IDLE_H="0"))
        if sup is None:
            return
        clock.set(1000 * 3600)
        time.sleep(2.0)
        T.check(alive(sup) and s.window_state(SID1) is not None and len(s.relay.registrations) == 1,
                "I2. HMD_PAIR_WINDOW_IDLE_H=0 never stops it: a thousand hours with no pairing and no activity and the window is still open",
                "alive %r state %r" % (alive(sup), s.window_state(SID1)))


def case_idle_stop_activity():
    with Scn() as s:
        clock = Clock(s.sb.root)
        transcript = os.path.join(s.sb.root, "session.jsonl")
        write_private(transcript, "{}\n")
        os.utime(transcript, (clock.base, clock.base))
        sup = open_window_or_fail(s, "I3.", transcript=transcript, **idle_knobs(clock, HMD_PAIR_WINDOW_IDLE_H="1"))
        if sup is None:
            return
        clock.set(1800)
        os.utime(transcript, (clock.base + 1800, clock.base + 1800))  # the session did something half an hour in
        time.sleep(1.0)
        clock.set(5000)  # 1 h 23 min since the window opened, but 53 min since that activity
        time.sleep(1.5)
        T.check(alive(sup) and s.window_state(SID1) is not None,
                "I3. HMD_PAIR_WINDOW_IDLE_H=1: activity in the session half an hour in keeps the window open past the hour it was opened",
                "alive %r" % alive(sup))
        clock.set(1800 + 3600 + 60)  # an hour and a minute since that activity
        T.check(wait_until(lambda: not alive(sup), 25) and s.window_state(SID1) is None,
                "I3. ...and it stops an hour after the last activity, the override honored", "alive %r" % alive(sup))


def case_idle_stop_spares_a_pairing():
    with Scn() as s:
        clock = Clock(s.sb.root)
        sup = open_window_or_fail(s, "I4.", **idle_knobs(clock))
        if sup is None:
            return
        code = s.relay.registrations[0]["code"]
        s.bind(s.relay.latest().id)
        marker = os.path.join(s.repo, ".heimdall", "app", "paired-%s.json" % code)
        paired = wait_until(lambda: os.path.exists(marker), 40)
        clock.set(5 * 3600)
        time.sleep(2.0)
        try:
            with open(marker, encoding="utf-8") as f:
                serving = json.load(f).get("pid")
        except (OSError, ValueError):
            serving = None
        T.check(paired and alive(sup) and isinstance(serving, int) and alive(serving),
                "I4. five hours on with a phone paired by the code: neither the window nor the client serving the phone is stopped",
                "paired %r supervisor %r client %r" % (paired, alive(sup), serving))


def case_hook_hands_over_the_transcript():
    with Scn() as s:
        transcript = os.path.join(s.sb.root, "session.jsonl")
        write_private(transcript, "{}\n")
        started = s.hook("pair-window-start", SID1, payload={"transcript_path": transcript})
        sup = window_pid(s, timeout=30)
        argv = H.argv_of(sup) if sup else ""
        T.check(started.returncode == 0 and started.stdout == "" and "--transcript %s" % transcript in argv,
                "I5. the SessionStart hook hands the window the session's transcript, the activity its idle stop watches",
                "rc %r out %r argv %r" % (started.returncode, started.stdout, argv))


def case_idle_stop_connect_reopens():
    with Scn() as s:
        clock = Clock(s.sb.root)
        sup = open_window_or_fail(s, "I6.", **idle_knobs(clock))
        if sup is None:
            return
        code = s.relay.registrations[0]["code"]
        clock.set(4 * 3600 + 120)
        wait_until(lambda: not alive(sup), 25)
        app = s.app("--relay", s.relay.url, "--bg")
        app.close_stdin()
        rc = app.wait_exit(90)
        wait_until(lambda: len(s.relay.registrations) >= 2, 30)
        regs = list(s.relay.registrations)
        T.check(rc == 0 and "SESSION CODE:" in app.text() and "already open for pairing" not in app.text()
                and len(regs) >= 2 and regs[-1]["code"] == code and regs[-1]["session_id"] != regs[0]["session_id"],
                "I6. once the window has stopped, `hmd app connect` registers the session's code itself and does not say a window already holds it",
                "rc %r registrations %d %s" % (rc, len(regs), app.tail()))


# -- S1 ------------------------------------------------------------------------------------------------------------
def case_no_links_followed():
    with Scn() as s:
        env = s.env()
        victim = os.path.join(s.sb.root, "victim")
        os.makedirs(victim)
        os.chmod(victim, 0o755)
        link_repo = os.path.join(s.sb.root, "linked-heimdall")
        os.makedirs(link_repo)
        os.symlink(victim, os.path.join(link_repo, ".heimdall"))
        rc, _out, err = code_cli(env, "--record-session", "--repo", link_repo, "--session-id", SID1, "--pid", str(os.getpid()))
        T.check(rc != 0 and os.listdir(victim) == [] and mode_of(victim) == 0o755,
                "S1. a symlinked .heimdall is refused: nothing is created in, or chmod'ed on, what it points at", "rc %r %s" % (rc, err))
        victim2 = os.path.join(s.sb.root, "victim2")
        os.makedirs(victim2)
        os.chmod(victim2, 0o755)
        app_repo = os.path.join(s.sb.root, "linked-app")
        os.makedirs(os.path.join(app_repo, ".heimdall"))
        os.symlink(victim2, os.path.join(app_repo, ".heimdall", "app"))
        rc, _out, err = code_cli(env, "--record-session", "--repo", app_repo, "--session-id", SID1, "--pid", str(os.getpid()))
        T.check(rc != 0 and os.listdir(victim2) == [] and mode_of(victim2) == 0o755,
                "S1. so is a symlinked .heimdall/app", "rc %r %s" % (rc, err))
        plain = os.path.join(s.sb.root, "plain")
        os.makedirs(os.path.join(plain, ".heimdall", "app"))
        target = os.path.join(s.sb.root, "keep.txt")
        write_private(target, "keep")
        session = os.path.join(plain, ".heimdall", "app", "session.json")
        os.symlink(target, session)
        rc, _out, err = code_cli(env, "--record-session", "--repo", plain, "--session-id", SID1, "--pid", str(os.getpid()))
        T.check(rc == 0 and open(target).read() == "keep" and not os.path.islink(session) and mode_of(session) == 0o600,
                "S1. a link planted AT session.json is replaced, never written through", "rc %r %s" % (rc, err))
        os.unlink(session)
        os.symlink(target, session)
        helper_linked = run([sys.executable, APP_CODE_PY, "--repo", plain], env).stdout.strip()
        os.unlink(session)
        helper_bare = run([sys.executable, APP_CODE_PY, "--repo", plain], env).stdout.strip()
        T.check(helper_linked == helper_bare and helper_bare != "",
                "S1. a session.json reached through a link is no session when read", "%r %r" % (helper_linked, helper_bare))
        # the marker the relay client leaves, in a repo whose .heimdall/app is a link
        victim3 = os.path.join(s.sb.root, "victim3")
        os.makedirs(victim3)
        client_repo = os.path.join(s.sb.root, "client-repo")
        os.makedirs(os.path.join(client_repo, ".heimdall"))
        os.symlink(victim3, os.path.join(client_repo, ".heimdall", "app"))
        c = s.client(H.CODE, repo=client_repo)
        c.wait_event("code_window")
        s.bind()
        bound = c.wait_event("device_bound", timeout=20)
        err_ev = c.wait_event("error", where=lambda e: "paired marker not written" in e.get("detail", ""), timeout=15)
        T.check(bool(bound) and bool(err_ev) and not [n for n in os.listdir(victim3) if n.startswith("paired-")],
                "S1. the relay client's pairing marker is refused through a link (reported, the bind unaffected) and written nowhere",
                c.tail())


# -- S2 ------------------------------------------------------------------------------------------------------------
def case_code_not_derivable():
    with Scn() as s_a, Scn() as s_b:
        env_a, env_b = s_a.env(), s_b.env()
        rc_a, code_a, _ = code_cli(env_a, "--session-id", SID1)
        rc_b, code_b, _ = code_cli(env_b, "--session-id", SID1)
        _rc, repo_code, _ = code_cli(env_a, "--repo", s_a.repo)
        seed_a = seed_of(s_a.home)
        T.check(rc_a == 0 and rc_b == 0 and code_a == ref_code(seed_a, "session_id", SID1) and repo_code == ref_code(seed_a, "repo", s_a.repo),
                "S2. the code is the HMAC of its input under the machine's seed (checked against an independent computation)",
                "%r %r" % (code_a, repo_code))
        T.check(code_a != old_code(SID1) and repo_code != old_code(s_a.repo) and code_a != code_b,
                "S2. so it is not the plain hash of a session id or a repo path, and another machine's seed gives another code",
                "a %r b %r plain %r" % (code_a, code_b, old_code(SID1)))
        key = os.path.join(s_a.home, "session-code.key")
        text = open(key, encoding="ascii").read().strip()
        T.check(mode_of(key) == 0o600 and re.fullmatch(r"[0-9a-f]{64}", text) is not None,
                "S2. the seed is 32 random bytes kept as 64 hex characters, 0600", "%o" % mode_of(key))
        app_dir = os.path.join(s_a.repo, ".heimdall", "app")
        os.makedirs(app_dir, exist_ok=True)
        os.chmod(app_dir, 0o700)
        session = os.path.join(app_dir, "session.json")
        planted = json.dumps({"session_id": SID2, "pid": os.getpid(), "ts": int(time.time())})
        write_private(session, planted, mode=0o644)  # what a git checkout leaves behind
        repo_own = run([sys.executable, APP_CODE_PY, "--repo", s_a.repo], env_a).stdout.strip()
        os.chmod(session, 0o600)
        trusted = run([sys.executable, APP_CODE_PY, "--repo", s_a.repo], env_a).stdout.strip()
        T.check(repo_own != ref_code(seed_a, "session_id", SID2) and trusted == ref_code(seed_a, "session_id", SID2),
                "S2. a session.json a checkout planted (0644) is not believed; the same file at 0600 -- as the hook writes it -- is",
                "planted %r trusted %r" % (repo_own, trusted))
        os.chmod(key, 0o644)
        rc_open, out_open, _ = code_cli(env_a, "--session-id", SID1)
        os.chmod(key, 0o600)
        write_private(key, "not-hex\n")
        rc_bad, out_bad, _ = code_cli(env_a, "--session-id", SID1)
        os.unlink(key)
        elsewhere = os.path.join(s_a.sb.root, "elsewhere.key")
        write_private(elsewhere, "0" * 64 + "\n")
        os.symlink(elsewhere, key)
        rc_link, out_link, _ = code_cli(env_a, "--session-id", SID1)
        T.check(rc_open != 0 and out_open == "" and rc_bad != 0 and out_bad == "" and rc_link != 0 and out_link == "",
                "S2. a seed that is group-readable, malformed or a link gives NO code -- never a guessable one",
                "%r/%r %r/%r %r/%r" % (rc_open, out_open, rc_bad, out_bad, rc_link, out_link))


def main():
    for case in (case_one_code, case_hooks, case_auto_pair, case_bg, case_identity_mismatch, case_no_sas_anywhere,
                 case_notice_and_statusline, case_confirm, case_gh_signed_out_and_two_sessions,
                 case_renewal_schedule, case_stream_waits_for_renewal, case_renewal_floor_live, case_renewal_before_lapse_live,
                 case_idle_stop, case_idle_stop_off, case_idle_stop_activity, case_idle_stop_spares_a_pairing,
                 case_hook_hands_over_the_transcript, case_idle_stop_connect_reopens,
                 case_no_links_followed, case_code_not_derivable):
        try:
            case()
        except Exception as exc:  # a case that dies is a failure, not a crash of the whole run
            T.check(False, "%s raised %s: %s" % (case.__name__, type(exc).__name__, exc))
    return T.finish()


if __name__ == "__main__":
    sys.exit(main())

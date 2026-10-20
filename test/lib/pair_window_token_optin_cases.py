#!/usr/bin/env python3
"""test/lib/pair_window_token_optin_cases.py -- pairing by code is ON for every repo, the gh token goes out once, and a repo or a machine can say no.
Run by test/pair-window-token-optin.test.sh. The REAL bin/heimdall-app and bin/heimdall-relay-client, the SessionStart hook command from
hooks/hooks.json, a loopback relay (test/lib/fake_relay_code.py: it records every registration, whether the token in it was the laptop's, and
every request of any kind) and a `gh` in the sandbox's PATH that appends each call it gets to a log and prints an obviously fake token (or, for
the signed-out case, says it is not logged in). Never the real relay, GitHub or Keychain.

The SessionStart pair window used to need a record `hmd app connect` made for the repo. It no longer does: a repo nobody ever connected gets its
window at the first session start. What is left of that record (bin/lib/hmd_pair_optin.py) is a way to say NO for one repo -- `hmd app
disconnect` and `hmd app connect --no-code` write it as `off`, `hmd app connect` as `on` -- and HMD_PAIR_WINDOW=0 says no for the machine.
  N1  a repo switched OFF (what `hmd app disconnect` leaves): the hook records the session and nothing else -- gh is not called (not even to ask
      whether it is signed in), the relay gets no request of any kind, no window starts -- and files a checkout plants do not switch it back on
  N2  `hmd app connect` is an explicit yes: no record before it (the default), an `on` record after; it registers the code once with the token
      (one gh read, one send), registers it again NOT -- over about 4.5 registration lifetimes -- and ends by itself when the code and QR lapse
      unpaired; `hmd app disconnect` switches the repo off
  N3  a repo nobody ever connected (no record, the default): the hook's window registers the code once and sends the token once; over the same
      4.5 lifetimes no registration, no gh read and no token follow, a second session start finds the window open and sends nothing, and the
      session start made no record
  N4  a phone already paired needs no code: the window opens, gh is not asked anything (no probe in the hook, no read in the window), nothing is registered
  N5  `hmd app connect --no-code` sends no token and switches the repo off -- and the SessionStart window then honours it
  N6  the record is in HEIMDALL_HOME, 0600, keyed by the repo's real path, never inside the repo; one that cannot be vetted is `off`, not the default
  N7  a connect whose client crashed after its phone paired replaces it with a plain --resume client: the phone's session resumes, and the
      relay sees no second registration and no token
  N8  HMD_PAIR_WINDOW=0 (also off, false, no): the machine-wide off -- a repo nobody switched off starts nothing either
  N9  gh not signed in: nothing starts, the session goes on (exit 0, the session still recorded), and ONE line on stderr names `gh auth login`

WHICH RELAY GETS THE TOKEN. On by default means a cloned repository's session start sends the token too -- and a repository sets the environment of
the session it is opened in (`.claude/settings.json` "env", `.envrc`), HMD_RELAY_URL included. So the environment is not trusted with the token: a
relay it names gets it only when it is the default or one the operator approved (bin/lib/hmd_relay_approval.py, in HEIMDALL_HOME, never in the repo;
`hmd app connect --relay URL` records it). Every case above runs with its fake relay approved (Scn's default); these run with it not:
  E1  HMD_RELAY_URL names a relay nobody approved: the SessionStart window reads no token (gh is not called), makes no relay request, starts no window,
      and says so in ONE line on stderr and in the app log -- whatever shape the URL has
  E2  no HMD_RELAY_URL, or the default one spelled another way: the window's client is started for the default relay and handed the token
  E3  a relay approved in HEIMDALL_HOME gets the token; approving one relay approves no other
  E4  an approval a repository planted (any place its own tree has, a whole HEIMDALL_HOME inside it, a relative HEIMDALL_HOME) is not honoured, and the
      same record in the operator's own HEIMDALL_HOME is; a HEIMDALL_HOME inside the repo is judged by file identity (device and inode), so spelling it in
      another case -- one place on APFS -- does not get it past, and a relative HEIMDALL_HOME is no store even where it resolves outside the repo
  E5  `hmd app connect` with the relay named only by the environment pairs by QR and sends no token; `connect --relay URL` is the operator naming it:
      the token goes, and the relay is recorded as approved -- unless `--no-code`, which sends no token and approves nothing
  E6  `hmd app add-device` and `hmd app identity revoke` refuse an environment relay they do not trust (exit 2, gh not asked); `--relay URL` names it
      for that one command and approves nothing
  E7  the matching is exact: scheme, host and port, compared as written once normalised; no path, no credentials, no lookalike character
  E8  `hmd app identity revoke` asks about the repo's root, never the working directory: run from a subdirectory of the repo (or of a CLAUDE_PROJECT_DIR that is no git
      work tree), a HEIMDALL_HOME inside it with the relay approved there is not honoured
  E9  a store inside ANY git work tree is not read, not only inside the repo the question names -- nested, spelled through a link, a `.git` that is a file or a link
      to nowhere; `approve` makes none (nothing is created), `list` shows none, `forget` touches none; a name that only looks like `.git` does not count
  E10 the directory that is read is the directory that is judged: $HEIMDALL_HOME/app (or app/relay-approved) a link into the repo is not honoured, and the judge
      walks the ancestors of the directory it was handed by device and inode, so one reached through a link is judged where it is
  E11 a store outside every work tree is honoured -- from the repo, from a subdirectory of it, with no --repo -- and what makes a record believable is unchanged
Scaled like the other pair-window cases: the relay keeps a registration 2 s (the real one 360 s), the floor is 0.5 s (300 s) and the lead 0.2 s
(10 s). The window this replaces registered the code again about every 1.8 s here; WAIT seconds are about 4.5 lifetimes -- 27 minutes of the
real relay's 6 -- and the old schedule would have made five or six registrations (each one a send of the token) in them.
"""
import hashlib
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import app_pair_confirm_cases as C  # noqa: E402  (the hook command, run, wait_until, the relay's purge of lapsed sessions)
import pair_code_harness as H  # noqa: E402
from fake_relay_code import FakeCodeRelay  # noqa: E402

T = H.Tally()
REPO = H.REPO
OPTIN_PY = os.path.join(REPO, "bin", "lib", "hmd_pair_optin.py")
APPROVAL_PY = os.path.join(REPO, "bin", "lib", "hmd_relay_approval.py")
DEVICES_PY = os.path.join(REPO, "bin", "lib", "hmd_devices.py")
KNOBS = {"HMD_PAIR_WINDOW_RENEW_MIN_S": "0.5", "HMD_PAIR_WINDOW_RENEW_LEAD_S": "0.2", "HMD_PAIR_WINDOW_POLL_S": "0.2",
         "HMD_PAIR_WINDOW_RESTART_S": "1", "HMD_CONNECT_RESTART_S": "1"}
WAIT = 9.0
SIGNED_OUT = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
DEFAULT_RELAY = H.HOSTED_RELAY
TOKEN_SHA = hashlib.sha256(H.TOKEN.encode()).hexdigest()

# Stands in for bin/heimdall-relay-client where a case must see what the window HANDS its client, for the default relay (the real one is not
# reachable from a test): its argv and the hash of the first line of its stdin -- the token, when one was handed over, never the line itself --
# one pair of files per start.
RECORDER_SH = r"""#!/bin/sh
REC="$HMD_FAKE_REC"
{ for a in "$@"; do printf '[%s]\n' "$a"; done; } > "$REC/argv.$$"
if IFS= read -r first; then printf '%s' "$first" | shasum -a 256 | cut -d' ' -f1 > "$REC/stdin.$$"; fi
exit 0
"""


class Scn:
    """A sandbox, a `gh` that records every call, a loopback relay -- and a repo nobody ever connected or switched off, until a case says so. The
    default environment is the DEFAULT one: no HMD_PAIR_WINDOW_RENEW, no HMD_PAIR_WINDOW. HMD_RELAY_URL names the loopback relay, which the
    sandbox's operator has approved (`approve=False`: has not -- a relay only a cloned repository's environment would name)."""

    def __init__(self, ttl=2, signed_in=True, approve=True):
        self.sb = H.Sandbox()
        self.gh_log = os.path.join(self.sb.root, "gh-calls.log")
        token_call = ("printf '%%s\\n' \"%s\"; exit 0" % H.TOKEN) if signed_in else ("echo '%s' >&2; exit 1" % SIGNED_OUT)
        self.sb.write_executable("gh", "#!/bin/sh\n"
                                       "printf '%%s\\n' \"$*\" >> \"%s\"\n"
                                       "if [ \"$1\" = auth ] && [ \"$2\" = token ]; then %s; fi\n"
                                       "exit 2\n" % (self.gh_log, token_call))
        self.relay = FakeCodeRelay(ttl_s=ttl, expect_token=H.TOKEN).start()
        self.procs = []
        self.dummies = []
        if approve:
            self.approve_relay()

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        for proc in self.procs:
            proc.stop()
        for dummy in self.dummies:
            dummy.kill()  # only the processes this case started
            dummy.wait(5)
        C.run([H.APP_PATH, "disconnect", "--repo", self.repo], self.env(), timeout=120)
        self.relay.stop()
        self.sb.close()

    @property
    def repo(self):
        return self.sb.repo

    @property
    def home(self):
        return os.path.join(self.sb.home, ".heimdall")

    def env(self, **extra):
        """The environment of a run. `extra` overrides any of it; a value of None leaves that variable out altogether (HMD_RELAY_URL=None: the
        environment names no relay)."""
        merged = {"PATH": self.sb.bin + os.pathsep + os.environ.get("PATH", ""), "HMD_RELAY_URL": self.relay.url, "HMD_SESSION_LOGIN_STORE": "file"}
        merged.update(KNOBS)
        merged.update(extra)
        return self.sb.env(**{name: value for name, value in merged.items() if value is not None})

    def approve_relay(self, url=None, home=None):
        """Approve a relay the way `hmd app connect --relay URL` does (bin/lib/hmd_relay_approval.py), in this sandbox's HEIMDALL_HOME -- or in
        `home`, to plant the same record somewhere else. The exit status of the helper."""
        extra = {"HEIMDALL_HOME": home} if home else {}
        return C.run([sys.executable, APPROVAL_PY, "approve", "--relay", url or self.relay.url], self.env(**extra), timeout=60).returncode

    def trusted(self, url, home=None):
        """Whether the helper the session start asks would let the token go to `url` for this repo: the default relay or an approved one."""
        extra = {"HEIMDALL_HOME": home} if home else {}
        argv = [sys.executable, APPROVAL_PY, "trusted", "--relay", url, "--default", DEFAULT_RELAY, "--repo", self.repo]
        return C.run(argv, self.env(**extra), timeout=60).returncode == 0

    def trusted_in(self, home, repo, cwd=None):
        """Whether the helper would let the token go to the loopback relay with `home` as HEIMDALL_HOME, asked about `repo` (None: no --repo at all), run from `cwd`."""
        argv = [sys.executable, APPROVAL_PY, "trusted", "--relay", self.relay.url, "--default", DEFAULT_RELAY] + (["--repo", repo] if repo else [])
        return C.run(argv, self.env(HEIMDALL_HOME=home), timeout=60, cwd=cwd).returncode == 0

    def plant_approval(self, home, url=None):
        """What a repository that carries its own approval store has in its tree: the record `approve` writes (the same bytes, 0600 in a 0700 directory), put in
        `home` without asking where that is -- `approve` itself refuses a store inside a git work tree, so a plant cannot be made with it."""
        approval = H.load_module("hmd_relay_approval_plant", APPROVAL_PY)
        origin = approval.normalize(url or self.relay.url)
        body = json.dumps({"v": approval.VERSION, "relay": origin, "approved_at": int(time.time())}, sort_keys=True, separators=(",", ":"))
        os.makedirs(home, mode=0o700, exist_ok=True)
        approval.PRIVATE.write(home, approval.REL, approval._name(origin), body.encode("utf-8"))

    @staticmethod
    def records_in(home):
        """How many files the approval store of `home` holds."""
        folder = os.path.join(home, "app", "relay-approved")
        return len(os.listdir(folder)) if os.path.isdir(folder) else 0

    def recorder(self):
        """The extra environment that puts a recorder where the relay client goes (HEIMDALL_RELAY_CLIENT_BIN, bin/heimdall-app's documented override)."""
        rec = os.path.join(self.sb.root, "rec")
        os.makedirs(rec, exist_ok=True)
        return {"HEIMDALL_RELAY_CLIENT_BIN": self.sb.write_executable("fake-relay-client", RECORDER_SH), "HMD_FAKE_REC": rec}

    def started(self):
        """[(argv, hash of the first stdin line or None)] for each start the recorder saw, code windows only (a --resume-only start is not one)."""
        rec = os.path.join(self.sb.root, "rec")
        found = []
        for name in sorted(os.listdir(rec)) if os.path.isdir(rec) else []:
            if not name.startswith("argv."):
                continue
            with open(os.path.join(rec, name), encoding="utf-8") as f:
                argv = [line[1:-1] for line in f.read().splitlines()]
            try:
                with open(os.path.join(rec, "stdin." + name.split(".", 1)[1]), encoding="utf-8") as f:
                    first = f.read().strip()
            except OSError:
                first = None
            if "--code" in argv:
                found.append((argv, first))
        return found

    def app_log(self):
        try:
            with open(os.path.join(self.home, "logs", "app.log"), encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""

    def gh_calls(self):
        try:
            with open(self.gh_log, encoding="utf-8") as f:
                return f.read().splitlines()
        except OSError:
            return []

    def gh_token_reads(self):
        return sum(1 for call in self.gh_calls() if call == "auth token")

    def token_sends(self):
        """How many registrations the relay got that carried the laptop's token."""
        return sum(1 for reg in list(self.relay.registrations) if reg["token_ok"])

    def state(self):
        """What the record says about this repo: "on", "off", or "default" (nothing recorded, which is on)."""
        return C.run([sys.executable, OPTIN_PY, "state", "--repo", self.repo], self.env(), timeout=60).stdout.strip()

    def record(self, action):
        """`set` (on), `off` or `clear` the repo's record, through the helper connect and disconnect use."""
        C.run([sys.executable, OPTIN_PY, action, "--repo", self.repo], self.env(), timeout=60)

    def hook(self, sid, **extra):
        env = self.env(CLAUDE_PLUGIN_ROOT=REPO, CLAUDE_PROJECT_DIR=self.repo, **extra)
        stdin = json.dumps({"session_id": sid, "source": "startup"})
        return C.run(["sh", "-c", C.hook_commands()["pair-window-start"]], env, stdin=stdin, timeout=60, cwd=self.repo)

    def pair_window(self, sid, **extra):
        """`hmd app pair-window --session SID` run directly, as the hook does: what it prints is what a hook would put in front of anybody."""
        return C.run([H.APP_PATH, "pair-window", "--session", sid, "--pid", str(os.getpid()), "--repo", self.repo], self.env(**extra), timeout=60)

    def window_state(self):
        try:
            with open(os.path.join(self.repo, ".heimdall", "app", "pair-window.json"), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def session_record(self, sid):
        try:
            with open(os.path.join(self.repo, ".heimdall", "app", "sessions", "%s.json" % sid), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def connect_json(self):
        return os.path.join(self.repo, ".heimdall", "app", "connect.json")

    def connect(self, *args, env=None):
        """`hmd app connect --relay <the loopback relay>`: the relay is named on the command line, as an operator does it."""
        proc = H.Proc([H.APP_PATH, "connect", "--repo", self.repo, "--port", "0", "--relay", self.relay.url] + list(args), self.env(**(env or {})),
                      cwd=self.repo)
        self.procs.append(proc)
        return proc

    def connect_env(self, *args):
        """`hmd app connect` with NO --relay: the relay is whatever the environment names (HMD_RELAY_URL), the default when it names none."""
        proc = H.Proc([H.APP_PATH, "connect", "--repo", self.repo, "--port", "0"] + list(args), self.env(), cwd=self.repo)
        self.procs.append(proc)
        return proc

    def pair_a_phone(self):
        """A phone paired to the repo, as the repo's records know it: a device record naming a live process that is a relay client of this repo (a
        stand-in this case starts and ends itself -- its argv is all the record is checked by). The count the helper reports."""
        real = os.path.realpath(self.repo)
        dummy = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)", "heimdall-relay-client", "--repo", real, "--ui-port", "1"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.dummies.append(dummy)
        devices = H.load_module("hmd_devices_probe", DEVICES_PY)
        now = int(time.time())
        devices.write_record(real, {"v": 1, "id": "0123abcd", "label": "Pixel 9a", "gh_login": "octocat", "via": "code", "code": None, "bound_at": now,
                                    "last_seen": now, "caps": [], "push_fps": [], "pid": dummy.pid})
        return C.run([sys.executable, DEVICES_PY, "count", "--repo", self.repo], self.env()).stdout.strip()


# -- N1 ------------------------------------------------------------------------------------------------------------
def case_switched_off_nothing_sent():
    with Scn() as s:
        s.record("off")  # what `hmd app disconnect` leaves behind
        started = s.hook(C.SID1)
        recorded = C.wait_until(lambda: s.session_record(C.SID1), 20)
        time.sleep(3)  # a probe, a supervisor or a registration would have shown by now
        T.check(started.returncode == 0 and started.stdout == "" and bool(recorded),
                "N1. SessionStart in a repo that was switched off: the hook exits 0 and says nothing, and the session is still recorded (a local file)",
                "rc %r out %r err %r record %r" % (started.returncode, started.stdout, started.stderr, recorded))
        T.check(s.gh_calls() == [], "N1. ...gh was not called at all -- not even to ask whether it is signed in", repr(s.gh_calls()))
        T.check(s.relay.requests == [] and not s.relay.registrations, "N1. ...the relay got no request of any kind, so no token", repr(s.relay.requests))
        T.check(s.window_state() is None and s.state() == "off", "N1. ...no pair window was started and the record still says off", repr(s.window_state()))
        # a checkout cannot switch itself back on: nothing it can write under its own tree is the record
        app_dir = os.path.join(s.repo, ".heimdall", "app")
        os.makedirs(os.path.join(app_dir, "pair-optin"), exist_ok=True)
        for name in ("pair-optin.json", "optin", os.path.join("pair-optin", "planted.json"), "connect.json"):
            C.write_private(os.path.join(app_dir, name), json.dumps({"v": 1, "repo": os.path.realpath(s.repo), "state": "on", "mode": "relay"}))
        again = s.hook(C.SID2)
        time.sleep(3)
        T.check(again.returncode == 0 and s.gh_calls() == [] and s.relay.requests == [] and s.window_state() is None,
                "N1. ...files a repository plants where it keeps its own state (pair-optin, connect.json) do not switch it back on: still no gh call, no relay request, no window",
                "gh %r requests %r window %r" % (s.gh_calls(), s.relay.requests, s.window_state()))


# -- N2 ------------------------------------------------------------------------------------------------------------
def case_connect_is_an_explicit_yes():
    with Scn() as s, C.purging_lapsed_sessions(s.relay, 0.3):
        before = s.state()
        app = s.connect("--bg")
        app.close_stdin()
        rc = app.wait_exit(90)
        registered = C.wait_until(lambda: s.relay.registrations, 40)
        T.check(rc == 0 and registered and before == "default" and s.state() == "on",
                "N2. `hmd app connect` is the explicit yes: no record before it (the default, which is on) and an `on` record after",
                "rc %r before %r after %r %s" % (rc, before, s.state(), app.tail()))
        T.check(len(s.relay.registrations) == 1 and s.token_sends() == 1 and s.gh_token_reads() == 1,
                "N2. ...it registers the code once, with the token: one registration, one send, one gh read",
                "registrations %d sends %d gh reads %d" % (len(s.relay.registrations), s.token_sends(), s.gh_token_reads()))
        time.sleep(WAIT)
        T.check(len(s.relay.registrations) == 1 and s.token_sends() == 1 and s.gh_token_reads() == 1,
                "N2. ...and over about 4.5 registration lifetimes (27 minutes of the real relay's six) the code is not registered again: no second send, no second gh read",
                "registrations %d sends %d gh reads %d" % (len(s.relay.registrations), s.token_sends(), s.gh_token_reads()))
        ended = C.wait_until(lambda: not os.path.exists(s.connect_json()), 30)
        T.check(ended, "N2. ...a connect whose code and QR lapsed with no phone paired ended by itself instead of offering them again", app.tail())
        out = C.run([H.APP_PATH, "disconnect", "--repo", s.repo], s.env(), timeout=120)
        T.check(out.returncode == 0 and s.state() == "off", "N2. `hmd app disconnect` switches the repo off: the next session start opens no window until connect is run again",
                "rc %r state %r %s%s" % (out.returncode, s.state(), out.stdout[-200:], out.stderr[-200:]))


# -- N3 ------------------------------------------------------------------------------------------------------------
def case_default_repo_registers_once():
    with Scn() as s:
        started = s.hook(C.SID1)  # no `hmd app connect` anywhere, no record: the DEFAULT repo
        registered = C.wait_until(lambda: s.relay.registrations, 40)
        T.check(started.returncode == 0 and registered and len(s.relay.registrations) == 1 and s.token_sends() == 1,
                "N3. a repo `hmd app connect` was never run for: the SessionStart hook's window registers the code once and sends the token once",
                "rc %r registrations %d sends %d" % (started.returncode, len(s.relay.registrations), s.token_sends()))
        time.sleep(WAIT)
        state = s.window_state() or {}
        T.check(len(s.relay.registrations) == 1 and s.token_sends() == 1 and s.gh_token_reads() == 2,
                "N3. ...over about 4.5 registration lifetimes nothing registers the code again and no token follows; gh was read twice in all (the hook's look, the window's)",
                "registrations %d sends %d gh reads %d" % (len(s.relay.registrations), s.token_sends(), s.gh_token_reads()))
        lapsed = C.wait_until(lambda: (s.window_state() or {}).get("state") == "lapsed", 30)
        sup = (s.window_state() or {}).get("pid")
        T.check(lapsed and isinstance(sup, int) and C.alive(sup),
                "N3. ...the window says it lapsed and stays up (to bring back a paired phone), registering nothing", "state %r" % (s.window_state() or state))
        again = s.hook(C.SID2)
        time.sleep(3)
        T.check(again.returncode == 0 and len(s.relay.registrations) == 1 and s.gh_token_reads() == 2,
                "N3. ...a second session start finds the window open and sends nothing: no registration, no gh read",
                "registrations %d gh reads %d" % (len(s.relay.registrations), s.gh_token_reads()))
        T.check(s.state() == "default", "N3. ...and a session start writes no record: the repo is still on by default, not by anything it recorded", repr(s.state()))


# -- N4 ------------------------------------------------------------------------------------------------------------
def case_paired_phone_needs_no_code():
    with Scn() as s:
        count = s.pair_a_phone()
        T.check(count == "1", "N4. (setup) one phone is paired to the repo", "count %r" % count)
        started = s.hook(C.SID1)
        paired = C.wait_until(lambda: (s.window_state() or {}).get("state") == "paired", 30)
        time.sleep(WAIT / 3)
        T.check(started.returncode == 0 and paired, "N4. a window that opens with a phone already paired says so and offers no code", "state %r" % (s.window_state(),))
        T.check(not s.relay.registrations and s.relay.requests == [],
                "N4. ...it registered nothing and made no relay request", "registrations %d requests %r" % (len(s.relay.registrations), s.relay.requests))
        T.check(s.gh_calls() == [],
                "N4. ...and asked gh nothing at all: a paired phone needs no code, so not even the hook looks at gh (a phone the repo has no stored login for "
                "is still a paired phone)", repr(s.gh_calls()))


# -- N5 ------------------------------------------------------------------------------------------------------------
def case_no_code_switches_it_off():
    with Scn() as s:
        s.record("set")  # an earlier `hmd app connect`
        app = s.connect("--no-code", "--bg")
        app.close_stdin()
        rc = app.wait_exit(90)
        T.check(rc == 0 and s.state() == "off", "N5. `hmd app connect --no-code` switches the repo off: no token for this repo, now or from a later session start",
                "rc %r state %r %s" % (rc, s.state(), app.tail()))
        T.check(s.gh_calls() == [] and not s.relay.registrations,
                "N5. ...and sends no token: gh was not called and nothing was registered", "gh %r registrations %d" % (s.gh_calls(), len(s.relay.registrations)))
        started = s.hook(C.SID1)
        time.sleep(3)
        T.check(started.returncode == 0 and s.gh_calls() == [] and not s.relay.registrations and s.window_state() is None,
                "N5. ...and the SessionStart window honours it: no gh call, no registration, no window",
                "rc %r gh %r registrations %d window %r" % (started.returncode, s.gh_calls(), len(s.relay.registrations), s.window_state()))


# -- N6 ------------------------------------------------------------------------------------------------------------
def case_record_is_outside_the_repo():
    with Scn() as s:
        s.record("off")
        folder = os.path.join(s.home, "app", "pair-optin")
        names = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
        record = os.path.join(folder, names[0]) if names else ""
        inside = [os.path.join(base, n) for base, _d, files in os.walk(s.repo) for n in files if "optin" in n]
        T.check(len(names) == 1 and C.mode_of(record) == 0o600 and C.mode_of(folder) == 0o700 and inside == [],
                "N6. the record is one 0600 file in HEIMDALL_HOME/app/pair-optin (a 0700 directory) and nothing of the kind is inside the repo",
                "names %r inside %r" % (names, inside))
        other = os.path.join(s.sb.root, "other")
        os.makedirs(other)
        link = os.path.join(s.sb.root, "link")
        os.symlink(s.repo, link)
        state = lambda path: C.run([sys.executable, OPTIN_PY, "state", "--repo", path], s.env()).stdout.strip()  # noqa: E731
        check = lambda path: C.run([sys.executable, OPTIN_PY, "check", "--repo", path], s.env()).returncode  # noqa: E731
        T.check(state(other) == "default" and check(other) == 0 and state(link) == "off" and check(link) == 1 and check(s.repo) == 1,
                "N6. ...it belongs to the repo's real path: another directory has none (the default, which `check` says yes to), a link to the repo has the repo's, and `check` says no to an off",
                "other %r/%r link %r/%r" % (state(other), check(other), state(link), check(link)))
        os.chmod(record, 0o644)  # a record anyone else could write cannot be vetted ...
        T.check(s.state() == "off" and check(s.repo) == 1,
                "N6. ...and a record that cannot be vetted (group or other permission bits) is off, not the default: a choice that cannot be read is not guessed at",
                "state %r" % s.state())
        s.record("set")
        os.chmod(record, 0o644)
        T.check(s.state() == "off", "N6. ...that holds for a record that said on as well", "state %r" % s.state())
        s.record("set")
        T.check(s.state() == "on" and check(s.repo) == 0, "N6. ...`set` replaces it with an on record (what connect does)", "state %r" % s.state())
        s.record("clear")
        T.check(s.state() == "default" and not os.listdir(folder), "N6. ...clear removes the record: back to the default", "state %r" % s.state())


# -- N7 ------------------------------------------------------------------------------------------------------------
def case_replacement_client_resumes_without_a_token():
    with Scn(ttl=60) as s:
        phone = H.Phone(C.E2E)
        app = s.connect()
        app.close_stdin()
        if not C.wait_until(lambda: C.client_pid(s) and s.relay.registrations, 40):
            T.check(False, "N7. (setup) connect registers the code", app.tail())
            return
        first = C.client_pid(s)
        sid = s.relay.registrations[-1]["session_id"]
        s.relay.inject_device_bound(sid, phone.pub_b64url, device_label="Pixel 9a")
        paired = C.wait_until(lambda: "phone paired via code" in app.text(), 30) and C.wait_until(lambda: s.relay.frames_of(sid, "state"), 30)
        T.check(paired, "N7. (setup) the phone pairs by the code and its first state frame is sealed (its login is stored by then)", app.tail())
        os.kill(first, 9)  # the client this connect started, crashed
        new = C.new_client(s, first)
        said = bool(new) and C.wait_until(lambda: "resumed the paired phone's session" in app.text(), 60)
        time.sleep(3)  # a code window the replacement wrongly offered would have registered by now
        T.check(bool(new) and said and sid not in s.relay.revokes and len(s.relay.registrations) == 1 and s.token_sends() == 1 and s.gh_token_reads() == 1,
                "N7. a client that crashed after its phone paired is replaced by one that resumes the phone's session, with no code and no token: one registration, one send, one gh read in all",
                "new %r said %r revokes %r registrations %d sends %d gh reads %d %s"
                % (new, said, s.relay.revokes, len(s.relay.registrations), s.token_sends(), s.gh_token_reads(), app.tail()))


# -- N8 ------------------------------------------------------------------------------------------------------------
def case_machine_wide_off():
    with Scn() as s:
        started = s.hook(C.SID1, HMD_PAIR_WINDOW="0")
        recorded = C.wait_until(lambda: s.session_record(C.SID1), 20)
        time.sleep(3)  # a probe, a supervisor or a registration would have shown by now
        T.check(started.returncode == 0 and bool(recorded) and s.gh_calls() == [] and s.relay.requests == [] and s.window_state() is None and s.state() == "default",
                "N8. HMD_PAIR_WINDOW=0 in the environment Claude Code runs in: a repo nobody switched off starts nothing either -- the session is recorded, gh is not "
                "called, the relay gets no request, no window",
                "rc %r record %r gh %r requests %r window %r" % (started.returncode, recorded, s.gh_calls(), s.relay.requests, s.window_state()))
        said = []
        for value in ("off", "false", "no"):
            out = s.pair_window(C.SID2, HMD_PAIR_WINDOW=value)
            said.append(out.returncode == 0 and ("HMD_PAIR_WINDOW=%s" % value) in out.stdout)
        T.check(all(said) and s.gh_calls() == [] and s.relay.requests == [] and s.window_state() is None,
                "N8. ...and it is the same off spelled off, false or no: each says so on stdout and starts nothing", repr(said))


# -- N9 ------------------------------------------------------------------------------------------------------------
def case_gh_signed_out_starts_nothing():
    with Scn(signed_in=False) as s:
        direct = s.pair_window(C.SID1)
        hint = [line for line in direct.stderr.splitlines() if line.strip()]
        T.check(direct.returncode == 0 and direct.stdout.strip() == "" and len(hint) == 1 and "gh auth login" in hint[0],
                "N9. gh is not signed in: `hmd app pair-window` exits 0, says nothing on stdout, and puts ONE line on stderr that names `gh auth login`",
                "rc %r out %r err %r" % (direct.returncode, direct.stdout, direct.stderr))
        T.check(s.window_state() is None and s.relay.requests == [] and not s.relay.registrations,
                "N9. ...nothing started: no window, no request of any kind to the relay", "window %r requests %r" % (s.window_state(), s.relay.requests))
        started = s.hook(C.SID2)
        recorded = C.wait_until(lambda: s.session_record(C.SID2), 20)
        time.sleep(2)
        T.check(started.returncode == 0 and started.stdout == "" and bool(recorded) and s.window_state() is None and s.relay.requests == [],
                "N9. ...and the SessionStart hook is silent and the session unaffected: it exits 0, the session is still recorded, no window opens",
                "rc %r out %r record %r" % (started.returncode, started.stdout, recorded))
        T.check(s.gh_calls() == ["auth token", "auth token"],
                "N9. ...gh was asked one thing, once per session start: can it give a token (two starts, two reads, no `gh auth status`, no login)", repr(s.gh_calls()))


# -- E1 ------------------------------------------------------------------------------------------------------------
def case_env_relay_nobody_approved_gets_nothing():
    with Scn(approve=False) as s:
        direct = s.pair_window(C.SID1)  # HMD_RELAY_URL names the loopback relay; nobody approved it
        said = [line for line in direct.stderr.splitlines() if line.strip()]
        T.check(direct.returncode == 0 and direct.stdout.strip() == "" and len(said) == 1 and "HMD_RELAY_URL" in said[0] and s.relay.url in said[0]
                and "hmd app connect --relay" in said[0],
                "E1. HMD_RELAY_URL -- which a cloned repository can set for the session -- names a relay that is not the default and was never approved: "
                "pair-window exits 0, says nothing on stdout and ONE line on stderr that names HMD_RELAY_URL, the relay and how to approve it",
                "rc %r out %r err %r" % (direct.returncode, direct.stdout, direct.stderr))
        T.check(s.gh_calls() == [] and s.relay.requests == [] and not s.relay.registrations and s.window_state() is None,
                "E1. ...no token was read (gh was not called, not even to ask), the relay it named got no request of any kind, and no window started",
                "gh %r requests %r window %r" % (s.gh_calls(), s.relay.requests, s.window_state()))
        started = s.hook(C.SID2)
        recorded = C.wait_until(lambda: s.session_record(C.SID2), 20)
        time.sleep(3)  # a probe, a supervisor or a registration would have shown by now
        T.check(started.returncode == 0 and started.stdout == "" and bool(recorded) and s.gh_calls() == [] and s.relay.requests == [] and s.window_state() is None,
                "E1. ...the SessionStart hook is silent and the session unaffected (exit 0, the session still recorded), and still no gh call, no relay request, no window",
                "rc %r out %r record %r gh %r requests %r window %r"
                % (started.returncode, started.stdout, recorded, s.gh_calls(), s.relay.requests, s.window_state()))
        T.check("HMD_RELAY_URL" in s.app_log(), "E1. ...and the app log says why no window opened (the hook's own stderr goes nowhere)", repr(s.app_log()[-300:]))
        # whatever shape the URL has, with a recorder where the relay client goes: none of them is the default, none of them was approved
        refused = []
        for url in ("http://evil", "https://evil.example/pair", "HTTPS://EVIL.EXAMPLE:443", "http://127.0.0.1:1", DEFAULT_RELAY + ".evil.example",
                    DEFAULT_RELAY + "/x", DEFAULT_RELAY.replace("https://", "https://user@")):
            out = s.pair_window(C.SID1, HMD_RELAY_URL=url, **s.recorder())
            refused.append(out.returncode == 0 and len([line for line in out.stderr.splitlines() if line.strip()]) == 1)
        T.check(all(refused) and s.started() == [] and s.gh_calls() == [] and s.relay.requests == [],
                "E1. ...nor does any other URL the environment could name -- another host, a path, an upper-case spelling, the default relay's name with a suffix or "
                "with credentials: each is refused with its one line, no client is started, no token read", repr(refused))


# -- E2 ------------------------------------------------------------------------------------------------------------
def case_default_relay_gets_the_token():
    for label, named in (("names no relay", None), ("names the default relay in another spelling", "https://HMD-Relay.TheRishabh16.workers.dev/")):
        with Scn(approve=False) as s:
            out = s.pair_window(C.SID1, HMD_RELAY_URL=named, **s.recorder())
            C.wait_until(lambda: any(first for _argv, first in s.started()), 40)  # the recorder writes its argv first, the hash of what it read on stdin after it
            starts = s.started()
            argv = starts[0][0] if starts else []
            T.check(out.returncode == 0 and len(starts) == 1 and "--relay" in argv and argv[argv.index("--relay") + 1] == (named or DEFAULT_RELAY)
                    and starts[0][1] == TOKEN_SHA,
                    "E2. HMD_RELAY_URL %s: the window's client is started for the default relay and handed the laptop's token (the recorder saw its hash)" % label,
                    "rc %r err %r starts %r" % (out.returncode, out.stderr, starts))
            T.check(out.stderr.strip() == "" and s.relay.requests == [],
                    "E2. ...with nothing said on stderr, and no request to the loopback relay the sandbox runs (which is not the default)", repr(out.stderr))


# -- E3 ------------------------------------------------------------------------------------------------------------
def case_approved_relay_gets_the_token():
    other = FakeCodeRelay(ttl_s=2, expect_token=H.TOKEN).start()
    try:
        with Scn(approve=False) as s:
            before = s.trusted(s.relay.url)
            approved = s.approve_relay()  # what `hmd app connect --relay URL` records
            T.check(not before and approved == 0 and s.trusted(s.relay.url),
                    "E3. (setup) the loopback relay is not trusted until it is approved, and `approve` -- what `hmd app connect --relay URL` records -- makes it so",
                    "before %r approve rc %r after %r" % (before, approved, s.trusted(s.relay.url)))
            elsewhere = s.pair_window(C.SID1, HMD_RELAY_URL=other.url)
            T.check(elsewhere.returncode == 0 and other.requests == [] and not other.registrations and s.gh_calls() == [],
                    "E3. approving one relay approves no other: a second relay (the same host, another port) named by the environment gets no request and no token",
                    "rc %r requests %r gh %r" % (elsewhere.returncode, other.requests, s.gh_calls()))
            started = s.hook(C.SID2)
            registered = C.wait_until(lambda: s.relay.registrations, 40)
            T.check(started.returncode == 0 and registered and len(s.relay.registrations) == 1 and s.token_sends() == 1,
                    "E3. a relay approved in HEIMDALL_HOME and named by the environment gets the token: the SessionStart window registers the code once, with it",
                    "rc %r registrations %d sends %d" % (started.returncode, len(s.relay.registrations), s.token_sends()))
    finally:
        other.stop()


# -- E4 ------------------------------------------------------------------------------------------------------------
def case_approval_planted_in_the_repo_is_not_honoured():
    with Scn(approve=False) as s:
        # what the helper writes, in each place a repository's own tree has -- the state tree hmd keeps in a repo, a dot directory, its top level --
        # valid in every respect but where it is
        homes = [os.path.join(s.repo, ".heimdall"), os.path.join(s.repo, ".hmd-home"), s.repo]
        for home in homes:
            s.plant_approval(home)  # not `approve`: it refuses to make a store inside a git work tree, and a repository does not ask it anyway
        planted = [s.records_in(home) for home in homes]
        T.check(planted == [1, 1, 1] and not s.trusted(s.relay.url) and [s.trusted(s.relay.url, home=home) for home in homes] == [False, False, False],
                "E4. approvals planted inside the repository (under .heimdall, in a dot directory, at its top level) are not read: the relay is still not trusted, "
                "and a store inside the repository is not believed even when it is named as HEIMDALL_HOME",
                "planted %r trusted %r" % (planted, [s.trusted(s.relay.url), [s.trusted(s.relay.url, home=home) for home in homes]]))
        first = s.pair_window(C.SID1)
        T.check(first.returncode == 0 and s.gh_calls() == [] and s.relay.requests == [] and s.window_state() is None,
                "E4. ...so the session start with that relay named by the environment still reads no token and makes no relay request",
                "rc %r err %r gh %r requests %r" % (first.returncode, first.stderr, s.gh_calls(), s.relay.requests))
        results = []
        for home in homes + [".hmd-home"]:  # the last one is relative: it resolves inside the repo because a hook runs there
            out = C.run([H.APP_PATH, "pair-window", "--session", C.SID1, "--pid", str(os.getpid()), "--repo", s.repo], s.env(HEIMDALL_HOME=home), timeout=60,
                        cwd=s.repo)
            results.append(out.returncode == 0)
        T.check(all(results) and s.gh_calls() == [] and s.relay.requests == [] and s.window_state() is None,
                "E4. ...and nor does a HEIMDALL_HOME the environment points into the repository (absolute or relative), approval in it or not: no gh call, no relay request, no window",
                "results %r gh %r requests %r window %r" % (results, s.gh_calls(), s.relay.requests, s.window_state()))
        s.approve_relay()  # the same record, in the operator's own HEIMDALL_HOME
        started = s.pair_window(C.SID1)
        registered = C.wait_until(lambda: s.relay.registrations, 40)
        T.check(started.returncode == 0 and registered and s.token_sends() == 1,
                "E4. ...while the same record in the operator's own HEIMDALL_HOME is honoured: the window registers the code with the token (so what refused the plants was where they are)",
                "rc %r registrations %d sends %d" % (started.returncode, len(s.relay.registrations), s.token_sends()))


def case_home_in_the_repo_is_not_honoured_in_any_spelling():
    with Scn(approve=False) as s:
        real = os.path.realpath(s.repo)
        home = os.path.join(real, ".hmd-home")
        s.plant_approval(home)  # a valid store, inside the repository
        planted = s.records_in(home)
        # the same directory spelled in another case: on a case-insensitive volume (the macOS default, APFS) /Users/RJ/x and /Users/rj/x are one place and a
        # comparison of path strings reads them as two -- and the HEIMDALL_HOME the environment gives is the attacker's to spell
        spelled = os.path.join(os.path.dirname(real), os.path.basename(real).upper(), ".hmd-home")
        reaches = os.path.exists(spelled) and os.path.samefile(spelled, home)
        out = C.run([H.APP_PATH, "pair-window", "--session", C.SID1, "--pid", str(os.getpid()), "--repo", s.repo], s.env(HEIMDALL_HOME=spelled), timeout=60,
                    cwd=s.repo)
        T.check(planted == 1 and out.returncode == 0 and not s.trusted(s.relay.url, home=spelled) and s.gh_calls() == [] and s.relay.requests == []
                and s.window_state() is None,
                "E4. a HEIMDALL_HOME inside the repository, spelled in another case (%s), is not honoured either: a store is judged by what it IS -- below the repo "
                "directory, by device and inode -- not by how its path is written: no gh call, no relay request, no window"
                % ("this volume reads that spelling as the planted store" if reaches else "this volume is case-sensitive, so the spelling reaches nothing here"),
                "planted %r rc %r err %r gh %r requests %r window %r" % (planted, out.returncode, out.stderr, s.gh_calls(), s.relay.requests, s.window_state()))
        # a HEIMDALL_HOME that is not an absolute path is no store at all, wherever it would resolve: here to the operator's own approved one
        s.approve_relay()
        relative = os.path.relpath(s.home, s.sb.root)
        argv = [sys.executable, APPROVAL_PY, "trusted", "--relay=" + s.relay.url, "--default=" + DEFAULT_RELAY, "--repo=" + s.repo]
        by_absolute = C.run(argv, s.env(), timeout=60, cwd=s.sb.root).returncode
        by_relative = C.run(argv, s.env(HEIMDALL_HOME=relative), timeout=60, cwd=s.sb.root).returncode
        T.check(by_absolute == 0 and by_relative == 1,
                "E4. ...and a relative HEIMDALL_HOME is refused: the operator's own approved store, named relative to the directory the process runs in, is not read "
                "(the same store named by its absolute path is)", "absolute rc %r relative rc %r (%s)" % (by_absolute, by_relative, relative))
        # the repo a question names need not be a git work tree. For a plain project directory only its own identity can refuse a store inside it, so this is the
        # case that proves the device-and-inode comparison (with a work tree around it, the `.git` entry refuses the store whatever the repo is)
        project = os.path.join(os.path.realpath(s.sb.root), "Project")
        os.makedirs(project)
        plain_home = os.path.join(project, ".hmd-home")
        s.plant_approval(plain_home)
        plain_spelled = os.path.join(os.path.dirname(project), "PROJECT", ".hmd-home")
        in_plain = [s.trusted_in(plain_home, project), s.trusted_in(plain_spelled, project)]
        unnamed = s.trusted_in(plain_home, None)
        T.check(in_plain == [False, False] and unnamed,
                "E4. ...and for a project directory that is no git work tree (so nothing but the repo's own identity can refuse): a store inside it is refused by device and inode, "
                "also with its path spelled in another case, while the same store asked about no repo at all is honoured (the record is valid: what refused it was where it is)",
                "refused %r unnamed %r" % (in_plain, unnamed))


# -- E5 ------------------------------------------------------------------------------------------------------------
def case_connect_env_relay_pairs_by_qr_without_the_token():
    with Scn(approve=False) as s:
        app = s.connect_env("--bg")  # no --relay: the environment names the loopback relay, which nobody approved
        app.close_stdin()
        rc = app.wait_exit(90)
        said = app.text()
        T.check(rc == 0 and "code pairing off" in said and "HMD_RELAY_URL" in said and "hmd app connect --relay" in said and "SESSION CODE" not in said,
                "E5. `hmd app connect` with the relay named only by HMD_RELAY_URL (not the default, never approved) pairs by QR and says in one line why there is no code",
                "rc %r %s" % (rc, app.tail()))
        T.check(s.gh_calls() == [] and not s.relay.registrations and s.token_sends() == 0,
                "E5. ...gh is not asked for a token and the relay gets no registration: the token goes nowhere",
                "gh %r registrations %d" % (s.gh_calls(), len(s.relay.registrations)))


def case_connect_relay_flag_names_the_relay():
    with Scn(approve=False) as s:
        app = s.connect("--bg", env={"HMD_RELAY_URL": "http://evil"})  # --relay <the loopback relay> on the command line, the environment naming another
        app.close_stdin()
        rc = app.wait_exit(90)
        registered = C.wait_until(lambda: s.relay.registrations, 40)
        T.check(rc == 0 and registered and len(s.relay.registrations) == 1 and s.token_sends() == 1,
                "E5. `hmd app connect --relay URL` is the operator naming the relay: the code is registered there and the token sent once, whatever HMD_RELAY_URL says",
                "rc %r registrations %d sends %d %s" % (rc, len(s.relay.registrations), s.token_sends(), app.tail()))
        T.check(s.trusted(s.relay.url),
                "E5. ...and it records that relay as approved, so a session start may send the token there too", "trusted %r" % s.trusted(s.relay.url))


def case_connect_no_code_approves_nothing():
    with Scn(approve=False) as s:
        app = s.connect("--no-code", "--bg")
        app.close_stdin()
        rc = app.wait_exit(90)
        T.check(rc == 0 and s.gh_calls() == [] and not s.relay.registrations and not s.trusted(s.relay.url),
                "E5. `hmd app connect --relay URL --no-code` sends no token and approves nothing: the relay is still not one a session start may send it to",
                "rc %r gh %r registrations %d trusted %r %s" % (rc, s.gh_calls(), len(s.relay.registrations), s.trusted(s.relay.url), app.tail()))


# -- E6 ------------------------------------------------------------------------------------------------------------
def case_add_device_and_identity_revoke_refuse_an_env_relay():
    with Scn(approve=False) as s:
        count = s.pair_a_phone()
        refused = C.run([H.APP_PATH, "add-device", "--repo", s.repo], s.env(), timeout=60, cwd=s.repo)
        T.check(count == "1" and refused.returncode == 2 and "HMD_RELAY_URL" in refused.stderr and s.gh_calls() == [] and s.relay.requests == [],
                "E6. `hmd app add-device` with the relay named only by HMD_RELAY_URL (not the default, never approved) refuses -- exit 2, a message naming HMD_RELAY_URL -- "
                "before it asks gh for anything or calls the relay",
                "count %r rc %r err %r gh %r requests %r" % (count, refused.returncode, refused.stderr, s.gh_calls(), s.relay.requests))
        revoke = C.run([H.APP_PATH, "identity", "revoke"], s.env(), timeout=60, cwd=s.repo)
        T.check(revoke.returncode == 2 and "HMD_RELAY_URL" in revoke.stderr and s.gh_calls() == [] and s.relay.identity_revokes == [],
                "E6. ...and so does `hmd app identity revoke`: exit 2, gh not asked, no request to the relay",
                "rc %r err %r gh %r revokes %r" % (revoke.returncode, revoke.stderr, s.gh_calls(), s.relay.identity_revokes))
        named = C.run([H.APP_PATH, "add-device", "--repo", s.repo, "--relay", s.relay.url], s.env(HMD_RELAY_URL="http://evil"), timeout=90, cwd=s.repo)
        # at least once, not exactly once: add-device's window is clamped to 1 s, longer than the 0.5 s floor of this scaled sandbox, so a loaded machine can let
        # the 2 s registration lapse and the client register again -- that the token is sent once per request is proved by the connect and window cases above
        T.check(s.token_sends() >= 1 and not s.trusted(s.relay.url),
                "E6. `add-device --relay URL` names the relay for that one command (the code is registered there, with the token, whatever HMD_RELAY_URL says) "
                "and approves nothing",
                "rc %r sends %d trusted %r out %r err %r" % (named.returncode, s.token_sends(), s.trusted(s.relay.url), named.stdout[-200:], named.stderr[-200:]))
        revoked = C.run([H.APP_PATH, "identity", "revoke", "--relay", s.relay.url], s.env(HMD_RELAY_URL="http://evil"), timeout=60, cwd=s.repo)
        T.check(revoked.returncode == 0 and len(s.relay.identity_revokes) == 1 and s.relay.identity_revokes[0]["token_ok"] and not s.trusted(s.relay.url),
                "E6. ...and so does `identity revoke --relay URL`: the token goes to that relay and nothing is approved",
                "rc %r revokes %r trusted %r err %r" % (revoked.returncode, s.relay.identity_revokes, s.trusted(s.relay.url), revoked.stderr[-200:]))


# -- E7 ------------------------------------------------------------------------------------------------------------
def case_relay_matching_is_exact():
    sb = H.Sandbox()
    saved = os.environ.get("HEIMDALL_HOME")
    try:
        os.environ["HEIMDALL_HOME"] = os.path.join(sb.home, ".heimdall")
        approval = H.load_module("hmd_relay_approval_probe", APPROVAL_PY)
        for url in ("https://relay.example.com", "http://127.0.0.1:8787", "http://[::1]:9000", "https://key.example.com"):
            approval.approve(url)
        yes = ("https://relay.example.com", "HTTPS://Relay.Example.COM/", "https://relay.example.com:443", "http://127.0.0.1:8787", "http://127.0.0.1:8787/",
               "http://[::1]:9000", "http://[0:0:0:0:0:0:0:1]:9000", "https://key.example.com",
               DEFAULT_RELAY, DEFAULT_RELAY + "/", "HTTPS://HMD-RELAY.THERISHABH16.WORKERS.DEV", DEFAULT_RELAY + ":443")
        no = ("", " ", "relay.example.com", "ftp://relay.example.com", "//relay.example.com", "https://", "https:///x", "javascript:alert(1)",
              "http://relay.example.com",  # the other scheme
              "https://relay.example.com:8443", "https://relay.example.com:80",  # another port
              "http://127.0.0.1", "http://127.0.0.1:8788", "https://127.0.0.1:8787", "http://[::1]", "http://[::2]:9000",
              "https://relay.example.com.evil.example", "https://evil-relay.example.com", "https://x.relay.example.com", "https://relay.example.com.",
              "https://relay.example.com@evil.example", "https://evil.example@relay.example.com", "https://:@relay.example.com",
              "https://relay.example.com/x", "https://relay.example.com//", "https://relay.example.com?x=1", "https://relay.example.com#x",
              "https://relay.example.com;x", "https://relay.example.com\\@evil.example", "https://relay.example.com%2eevil.example",
              "https://relay.example.com\t", "https://relay.example.com ", " https://relay.example.com", "https://relay.example.com\n",
              "https://relay.example.com\x00", "https://relay.example.com∕evil.example", "https://relаy.example.com",
              "https://Key.example.com",  # KELVIN SIGN: it lower-cases to a plain k, the lookalike a case-insensitive pattern lets through
              "https://ｒelay.example.com",  # a full-width r
              DEFAULT_RELAY + ".evil.example", "https://evil." + DEFAULT_RELAY[len("https://"):], DEFAULT_RELAY + ":8443", DEFAULT_RELAY.replace("https", "http"))
        wrong_yes = [url for url in yes if not approval.trusted(url, DEFAULT_RELAY, sb.repo)]
        wrong_no = [url for url in no if approval.trusted(url, DEFAULT_RELAY, sb.repo)]
        T.check(not wrong_yes, "E7. the default relay and the approved ones are trusted however the scheme and host are cased, with or without the closing slash or the scheme's own port",
                "refused: %r" % wrong_yes)
        T.check(not wrong_no, "E7. ...and nothing else is: another scheme, port, host, a suffix or prefix of one, credentials, a path, a query, a fragment, whitespace, "
                "a lookalike or control character, an empty value", "trusted: %r" % wrong_no)
        normalised = {"HTTPS://Relay.Example.COM:443/": "https://relay.example.com", "http://127.0.0.1:80": "http://127.0.0.1",
                      "http://[0:0:0:0:0:0:0:1]:9000": "http://[::1]:9000", "https://x.example:8443/": "https://x.example:8443",
                      "https://x.example:0443": None, "https://x.example:0": None, "https://x.example:65536": None, "https://-x.example": None,
                      "https://x..example": None, "https://x.example:": None}
        wrong_form = {url: approval.normalize(url) for url, want in normalised.items() if approval.normalize(url) != want}
        T.check(not wrong_form, "E7. a URL is compared in one form: scheme://host[:port], lower-cased, the scheme's own port left out, IPv6 compressed -- and a port with a leading "
                "zero, above 65535 or empty, an empty or hyphen-edged label is no URL at all", "differs: %r" % wrong_form)
        out = C.run([sys.executable, APPROVAL_PY, "approve", "--relay", "https://relay.example.com/x"], sb.env(), timeout=60)
        T.check(out.returncode == 1 and not approval.trusted("https://relay.example.com/x", DEFAULT_RELAY, sb.repo),
                "E7. a URL that is not a plain scheme://host[:port] cannot be approved (exit 1)", "rc %r err %r" % (out.returncode, out.stderr))
    finally:
        if saved is None:
            os.environ.pop("HEIMDALL_HOME", None)
        else:
            os.environ["HEIMDALL_HOME"] = saved
        sb.close()


# -- E8 ------------------------------------------------------------------------------------------------------------
def case_identity_revoke_asks_about_the_repo_root_not_the_working_directory():
    with Scn(approve=False) as s:
        revoke = [H.APP_PATH, "identity", "revoke"]
        # a subdirectory of the repo, and a HEIMDALL_HOME inside the repo with the relay approved in it
        sub = os.path.join(s.repo, "pkg", "deeper")
        os.makedirs(sub)
        planted = os.path.join(s.repo, ".hmd-home")
        s.plant_approval(planted)
        inside = C.run(revoke, s.env(HEIMDALL_HOME=planted), timeout=60, cwd=sub)
        T.check(inside.returncode == 2 and "HMD_RELAY_URL" in inside.stderr and s.gh_calls() == [] and s.relay.identity_revokes == [],
                "E8. `hmd app identity revoke` run from a subdirectory of the repo, with a HEIMDALL_HOME inside the repo that holds an approval for the relay HMD_RELAY_URL names: "
                "refused (exit 2, gh not asked, nothing sent to the relay) -- the trust check is asked about the repo's root, not about the working directory",
                "rc %r err %r gh %r revokes %r" % (inside.returncode, inside.stderr, s.gh_calls(), s.relay.identity_revokes))
        # a project directory that is no git work tree, named by CLAUDE_PROJECT_DIR, run from a subdirectory of it: no `.git` refuses its store, only the project's own identity can
        project = os.path.join(s.sb.root, "project")
        os.makedirs(os.path.join(project, "src"))
        s.plant_approval(os.path.join(project, ".hmd-home"))
        plain = C.run(revoke, s.env(HEIMDALL_HOME=os.path.join(project, ".hmd-home"), CLAUDE_PROJECT_DIR=project), timeout=60, cwd=os.path.join(project, "src"))
        T.check(plain.returncode == 2 and "HMD_RELAY_URL" in plain.stderr and s.gh_calls() == [] and s.relay.identity_revokes == [],
                "E8. ...and so is one run from a subdirectory of a CLAUDE_PROJECT_DIR that is no git work tree (nothing but the project's own identity can refuse that store)",
                "rc %r err %r gh %r revokes %r" % (plain.returncode, plain.stderr, s.gh_calls(), s.relay.identity_revokes))
        s.approve_relay()  # the operator's own HEIMDALL_HOME
        honoured = C.run(revoke, s.env(), timeout=60, cwd=sub)
        T.check(honoured.returncode == 0 and len(s.relay.identity_revokes) == 1 and s.relay.identity_revokes[0]["token_ok"],
                "E8. ...while the approval in the operator's own HEIMDALL_HOME is honoured from that same subdirectory: the token goes once (so what refused the others was where the store is)",
                "rc %r err %r revokes %r" % (honoured.returncode, honoured.stderr, s.relay.identity_revokes))


# -- E9 ------------------------------------------------------------------------------------------------------------
def case_a_store_inside_any_git_work_tree_is_not_honoured():
    with Scn(approve=False) as s:
        root = s.sb.root
        shown = H.load_module("hmd_relay_approval_listing", APPROVAL_PY).normalize(s.relay.url)
        # a work tree that is not the repo the question names, and the other shapes a place with a `.git` entry takes
        other = os.path.join(root, "other")
        made = C.run(["git", "init", "-q", other], s.env(), timeout=60)
        linked = os.path.join(root, "linked-work-tree")  # a linked work tree or a submodule: its .git is a file
        os.makedirs(linked)
        C.write_private(os.path.join(linked, ".git"), "gitdir: %s\n" % os.path.join(other, ".git"), 0o644)
        dangling = os.path.join(root, "dangling")  # a .git that is a link to nowhere: it is not followed, and it is there
        os.makedirs(dangling)
        os.symlink(os.path.join(root, "no-such-directory"), os.path.join(dangling, ".git"))
        through = os.path.join(root, "link-to-other")
        os.symlink(other, through)
        homes = {"at the work tree's top": os.path.join(other, ".hmd-home"), "four directories down": os.path.join(other, "a", "b", "c", "home"),
                 "spelled through a link to the work tree": os.path.join(through, ".hmd-home-2"), "in a work tree whose .git is a file": os.path.join(linked, "home"),
                 "in a directory whose .git is a link to nowhere": os.path.join(dangling, "home")}
        for home in homes.values():
            s.plant_approval(home)
        answers = {where: s.trusted_in(home, s.repo) for where, home in homes.items()}
        T.check(made.returncode == 0 and not any(answers.values()),
                "E9. a store inside a git work tree that is not the repo the question names is not honoured, wherever in it: at its top, four directories down, spelled through a link, "
                "in a work tree whose .git is a file, in a directory whose .git is a link to nowhere",
                "init rc %r honoured %r" % (made.returncode, [where for where, yes in answers.items() if yes]))
        plain = os.path.join(root, "plain-home")
        s.plant_approval(plain)
        lookalike = os.path.join(root, "lookalike")  # names that only look like it
        os.makedirs(os.path.join(lookalike, ".github"))
        os.makedirs(os.path.join(lookalike, "x.git"))
        C.write_private(os.path.join(lookalike, ".gitignore"), "*\n", 0o644)
        s.plant_approval(os.path.join(lookalike, "home"))
        T.check(s.trusted_in(plain, s.repo) and s.trusted_in(os.path.join(lookalike, "home"), s.repo),
                "E9. ...while the same record outside every work tree is honoured, and so is one below a directory that holds only names that look like .git (.gitignore, .github, x.git)",
                "plain %r lookalike %r" % (s.trusted_in(plain, s.repo), s.trusted_in(os.path.join(lookalike, "home"), s.repo)))
        top = homes["at the work tree's top"]
        fresh = os.path.join(other, ".hmd-fresh")
        project = os.path.join(root, "project")  # no git work tree here: only the repo the question names can refuse a store in it
        os.makedirs(project)
        fresh_in_project = os.path.join(project, ".hmd-fresh")
        in_tree = C.run([sys.executable, APPROVAL_PY, "approve", "--relay", s.relay.url], s.env(HEIMDALL_HOME=fresh), timeout=60)
        in_repo = C.run([sys.executable, APPROVAL_PY, "approve", "--relay", s.relay.url, "--repo", project], s.env(HEIMDALL_HOME=fresh_in_project), timeout=60)
        T.check(in_tree.returncode == 1 and "git work tree" in in_tree.stderr and not os.path.exists(fresh)
                and in_repo.returncode == 1 and not os.path.exists(fresh_in_project),
                "E9. `approve` refuses to make a store inside a git work tree, or inside the repo it is asked for, says why on stderr and creates nothing (not even the directories)",
                "tree rc %r err %r made %r | repo rc %r made %r" % (in_tree.returncode, in_tree.stderr, os.path.exists(fresh), in_repo.returncode, os.path.exists(fresh_in_project)))
        listed_in = C.run([sys.executable, APPROVAL_PY, "list"], s.env(HEIMDALL_HOME=top), timeout=60)
        listed_out = C.run([sys.executable, APPROVAL_PY, "list"], s.env(HEIMDALL_HOME=plain), timeout=60)
        T.check(listed_in.returncode == 0 and listed_in.stdout.strip() == "" and listed_out.stdout.split() == [shown],
                "E9. `list` shows none of the approvals in a store inside a git work tree, and shows the one in a store outside",
                "inside %r outside %r" % (listed_in.stdout, listed_out.stdout))
        started = s.pair_window(C.SID1, HEIMDALL_HOME=top)
        T.check(started.returncode == 0 and s.gh_calls() == [] and s.relay.requests == [] and s.window_state() is None,
                "E9. ...and a session start with such a HEIMDALL_HOME reads no token, makes no relay request and opens no window",
                "rc %r err %r gh %r requests %r window %r" % (started.returncode, started.stderr, s.gh_calls(), s.relay.requests, s.window_state()))
        forgot_in = C.run([sys.executable, APPROVAL_PY, "forget", "--relay", s.relay.url], s.env(HEIMDALL_HOME=top), timeout=60)
        forgot_out = C.run([sys.executable, APPROVAL_PY, "forget", "--relay", s.relay.url], s.env(HEIMDALL_HOME=plain), timeout=60)
        T.check(forgot_in.returncode == 0 and s.records_in(top) == 1 and forgot_out.returncode == 0 and s.records_in(plain) == 0 and not s.trusted_in(plain, s.repo),
                "E9. `forget` takes an approval back from a store outside every work tree and leaves a store inside one untouched",
                "inside rc %r records %r | outside rc %r records %r" % (forgot_in.returncode, s.records_in(top), forgot_out.returncode, s.records_in(plain)))


# -- E10 -----------------------------------------------------------------------------------------------------------
def case_a_store_directory_that_is_a_link_is_judged_where_it_is():
    with Scn(approve=False) as s:
        root = s.sb.root
        approval = H.load_module("hmd_relay_approval_judge", APPROVAL_PY)
        hidden = os.path.join(s.repo, "hidden-home")
        s.plant_approval(hidden)  # <repo>/hidden-home/app/relay-approved/<record>: valid in every respect but where it is
        by_app = os.path.join(root, "home-with-linked-app")  # $HEIMDALL_HOME/app is a link into the repository
        os.makedirs(by_app, mode=0o700)
        os.symlink(os.path.join(hidden, "app"), os.path.join(by_app, "app"))
        by_store = os.path.join(root, "home-with-linked-store")  # $HEIMDALL_HOME/app/relay-approved is a link into the repository
        os.makedirs(os.path.join(by_store, "app"), mode=0o700)
        os.symlink(os.path.join(hidden, "app", "relay-approved"), os.path.join(by_store, "app", "relay-approved"))
        answers = [s.trusted_in(by_app, s.repo), s.trusted_in(by_store, s.repo), s.trusted_in(by_app, None), s.trusted_in(by_store, None)]
        started = s.pair_window(C.SID1, HEIMDALL_HOME=by_app)
        T.check(answers == [False] * 4 and started.returncode == 0 and s.gh_calls() == [] and s.relay.requests == [] and s.window_state() is None,
                "E10. a HEIMDALL_HOME whose app (or app/relay-approved) is a link into the repository is not honoured -- whether or not the question names the repo -- and a "
                "session start with it reads no token, makes no relay request and opens no window",
                "answers %r rc %r gh %r requests %r window %r" % (answers, started.returncode, s.gh_calls(), s.relay.requests, s.window_state()))
        # the judge itself: handed the directory a link leads to, it answers for where that directory IS (its ancestors, by device and inode), not for the path it was reached by
        project = os.path.join(os.path.realpath(root), "project")  # no git work tree
        os.makedirs(project)
        s.plant_approval(os.path.join(project, "hidden"))
        by_project = os.path.join(root, "home-linked-into-project")
        os.makedirs(os.path.join(by_project, "app"), mode=0o700)
        os.symlink(os.path.join(project, "hidden", "app", "relay-approved"), os.path.join(by_project, "app", "relay-approved"))
        plain = os.path.join(root, "plain-home")
        s.plant_approval(plain)

        def judged(home, repo):
            fd = os.open(os.path.join(home, "app", "relay-approved"), os.O_RDONLY | os.O_DIRECTORY)  # follows the links: the directory they lead to
            try:
                return approval.in_a_repo(fd, repo)
            finally:
                os.close(fd)

        verdicts = [judged(by_store, s.repo), judged(by_store, None), judged(by_project, project), judged(by_project, None), judged(plain, s.repo), judged(plain, None)]
        T.check(verdicts == [True, True, True, False, False, False],
                "E10. ...the judge (in_a_repo) answers for where a directory is, not for how it was reached: one a link leads to inside the repository is inside it, and inside a work tree "
                "(when the repo is not named); one inside a plain project directory is inside it only when it is named; one outside every repo and work tree is neither",
                "verdicts %r" % verdicts)


# -- E11 -----------------------------------------------------------------------------------------------------------
def case_a_store_outside_every_work_tree_is_honoured():
    with Scn(approve=False) as s:
        s.approve_relay()  # the sandbox's own HEIMDALL_HOME: what `hmd app connect --relay URL` records
        sub = os.path.join(s.repo, "pkg")
        os.makedirs(sub)
        other = os.path.join(s.sb.root, "other")  # a work tree beside the store, which the store is not in
        made = C.run(["git", "init", "-q", other], s.env(), timeout=60)
        answers = [s.trusted_in(s.home, s.repo), s.trusted_in(s.home, s.repo, cwd=sub), s.trusted_in(s.home, sub), s.trusted_in(s.home, None), s.trusted_in(s.home, other)]
        T.check(made.returncode == 0 and all(answers),
                "E11. a store in the operator's own HEIMDALL_HOME, outside every git work tree, is honoured: asked about the repo, from a subdirectory of it, about a subdirectory, "
                "about no repo, and about another work tree",
                "init rc %r answers %r" % (made.returncode, answers))
        # what makes a record believable is unchanged: each of these, in place of the record, is not believed
        store = os.path.join(s.home, "app", "relay-approved")
        record = os.path.join(store, os.listdir(store)[0])
        parked = record + ".parked"
        with open(record, encoding="utf-8") as f:
            good = f.read()

        def asked_with(make):
            os.rename(record, parked)
            try:
                make()
                return s.trusted_in(s.home, s.repo)
            finally:
                if os.path.lexists(record):
                    os.remove(record)
                os.rename(parked, record)

        os.chmod(store, 0o755)
        loose_dir = s.trusted_in(s.home, s.repo)
        os.chmod(store, 0o700)
        believed = {"a record with group and other permission bits": asked_with(lambda: C.write_private(record, good, 0o644)),
                    "a link to a good record": asked_with(lambda: os.symlink(parked, record)),
                    "a FIFO": asked_with(lambda: os.mkfifo(record, 0o600)),
                    "a record over the size limit": asked_with(lambda: C.write_private(record, good + " " * 5000)),
                    "something that is not a JSON object": asked_with(lambda: C.write_private(record, "[]")),
                    "a record about another relay": asked_with(lambda: C.write_private(record, good.replace(s.relay.url, "http://127.0.0.1:1")))}
        restored = s.trusted_in(s.home, s.repo)
        T.check(not loose_dir and not any(believed.values()) and restored,
                "E11. ...and none of these is believed in its place: a store directory with group or other bits, a record with them, a link to a good record, a FIFO, a record over "
                "the size limit, something that is not a JSON object, a record about another relay (and the good record is believed again once restored)",
                "loose dir %r believed %r restored %r" % (loose_dir, [what for what, yes in believed.items() if yes], restored))


CASES = [case_switched_off_nothing_sent, case_connect_is_an_explicit_yes, case_default_repo_registers_once, case_paired_phone_needs_no_code,
         case_no_code_switches_it_off, case_record_is_outside_the_repo, case_replacement_client_resumes_without_a_token, case_machine_wide_off,
         case_gh_signed_out_starts_nothing, case_env_relay_nobody_approved_gets_nothing, case_default_relay_gets_the_token,
         case_approved_relay_gets_the_token, case_approval_planted_in_the_repo_is_not_honoured, case_home_in_the_repo_is_not_honoured_in_any_spelling,
         case_connect_env_relay_pairs_by_qr_without_the_token,
         case_connect_relay_flag_names_the_relay, case_connect_no_code_approves_nothing, case_add_device_and_identity_revoke_refuse_an_env_relay,
         case_relay_matching_is_exact, case_identity_revoke_asks_about_the_repo_root_not_the_working_directory, case_a_store_inside_any_git_work_tree_is_not_honoured,
         case_a_store_directory_that_is_a_link_is_judged_where_it_is, case_a_store_outside_every_work_tree_is_honoured]


def main():
    return H.run_main(T, os.path.realpath(__file__), CASES)


if __name__ == "__main__":
    sys.exit(main())

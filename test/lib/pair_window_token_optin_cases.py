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
Scaled like the other pair-window cases: the relay keeps a registration 2 s (the real one 360 s), the floor is 0.5 s (300 s) and the lead 0.2 s
(10 s). The window this replaces registered the code again about every 1.8 s here; WAIT seconds are about 4.5 lifetimes -- 27 minutes of the
real relay's 6 -- and the old schedule would have made five or six registrations (each one a send of the token) in them.
"""
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
DEVICES_PY = os.path.join(REPO, "bin", "lib", "hmd_devices.py")
KNOBS = {"HMD_PAIR_WINDOW_RENEW_MIN_S": "0.5", "HMD_PAIR_WINDOW_RENEW_LEAD_S": "0.2", "HMD_PAIR_WINDOW_POLL_S": "0.2",
         "HMD_PAIR_WINDOW_RESTART_S": "1", "HMD_CONNECT_RESTART_S": "1"}
WAIT = 9.0
SIGNED_OUT = "You are not logged into any GitHub hosts. To log in, run: gh auth login"


class Scn:
    """A sandbox, a `gh` that records every call, a loopback relay -- and a repo nobody ever connected or switched off, until a case says so. The
    default environment is the DEFAULT one: no HMD_PAIR_WINDOW_RENEW, no HMD_PAIR_WINDOW."""

    def __init__(self, ttl=2, signed_in=True):
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
        return self.sb.env(PATH=self.sb.bin + os.pathsep + os.environ.get("PATH", ""), HMD_RELAY_URL=self.relay.url,
                           HMD_SESSION_LOGIN_STORE="file", **dict(KNOBS, **extra))

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

    def connect(self, *args):
        proc = H.Proc([H.APP_PATH, "connect", "--repo", self.repo, "--port", "0", "--relay", self.relay.url] + list(args), self.env(), cwd=self.repo)
        self.procs.append(proc)
        return proc


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
        real = os.path.realpath(s.repo)
        # a paired phone, as the repo's records know it: a record naming a live process that is a relay client of this repo (a stand-in this
        # case starts and ends itself -- its argv is all the record is checked by)
        dummy = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)", "heimdall-relay-client", "--repo", real, "--ui-port", "1"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        s.dummies.append(dummy)
        devices = H.load_module("hmd_devices_probe", DEVICES_PY)
        now = int(time.time())
        devices.write_record(real, {"v": 1, "id": "0123abcd", "label": "Pixel 9a", "gh_login": "octocat", "via": "code", "code": None, "bound_at": now,
                                    "last_seen": now, "caps": [], "push_fps": [], "pid": dummy.pid})
        count = C.run([sys.executable, DEVICES_PY, "count", "--repo", s.repo], s.env()).stdout.strip()
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


CASES = [case_switched_off_nothing_sent, case_connect_is_an_explicit_yes, case_default_repo_registers_once, case_paired_phone_needs_no_code,
         case_no_code_switches_it_off, case_record_is_outside_the_repo, case_replacement_client_resumes_without_a_token, case_machine_wide_off,
         case_gh_signed_out_starts_nothing]


def main():
    return H.run_main(T, os.path.realpath(__file__), CASES)


if __name__ == "__main__":
    sys.exit(main())

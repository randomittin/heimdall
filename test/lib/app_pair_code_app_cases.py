#!/usr/bin/env python3
"""test/lib/app_pair_code_app_cases.py -- the REAL bin/heimdall-app (`hmd app connect`, `hmd app identity
revoke`) driving pair by session code. Run by test/app-pair-code.test.sh; the relay-client half is
test/lib/app_pair_code_client_cases.py.

Two kinds of stand-in for the relay client, each where it proves something the other cannot:
  * a RECORDER script (HEIMDALL_RELAY_CLIENT_BIN) that logs its own argv and environment, hashes the first
    line of its stdin, notes every later stdin line, and prints events from files the test wrote -- exact
    control over what heimdall-app is shown, and an exact record of what it handed over;
  * the real relay client against test/lib/fake_relay_code.py -- the whole path, end to end.
`gh` is a script in the sandbox's PATH (never the real one, never a real token).

Proven here: the transport default (hosted relay, HMD_RELAY_URL, --relay, in that precedence); the token
reaches the client on stdin only -- not argv, not environment, not a file -- and `gh` is asked exactly
`auth token`; the code is the one `hmd ui` shows; every way pair by code can be off prints one line and
leaves the QR; a plain connect passes --no-confirm (code-only pairing, proved end to end by test/app-pair-confirm.test.sh) while --confirm needs a terminal and refuses --bg; the --confirm prompt shows the SAS, strips escape sequences from what the phone
called itself, and an answer other than yes (or no answer) rejects; identity revoke; and one full pairing.
"""
import hashlib
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import pair_code_harness as H  # noqa: E402
from fake_relay_code import FakeCodeRelay  # noqa: E402

T = H.Tally()
E2E = H.load_module("hmd_relay_e2e", H.E2E_PATH)

OFF_NO_GH = "hmd app: code pairing off — laptop not signed in to GitHub (gh auth login). Scan the QR."

RECORDER_SH = r"""#!/bin/sh
# Stands in for bin/heimdall-relay-client: records what heimdall-app handed it, replays scripted events.
REC="$HMD_FAKE_REC"
{ for a in "$@"; do printf '[%s]\n' "$a"; done; } > "$REC/argv"
env | sort > "$REC/env"
if IFS= read -r first; then printf '%s' "$first" | shasum -a 256 | cut -d' ' -f1 > "$REC/stdin.sha256"; fi
[ -f "$REC/events-1" ] && cat "$REC/events-1"
if [ -f "$REC/events-2" ]; then
  if IFS= read -r answer; then printf '%s\n' "$answer" >> "$REC/control"; fi
  cat "$REC/events-2"
fi
while IFS= read -r line; do printf '%s\n' "$line" >> "$REC/control"; done
exit 0
"""

PAIR_INIT = {"event": "pair_init", "exp": 4102444800,
             "qr": {"v": 1, "relay": "http://127.0.0.1:9", "session_id": "s-1", "exp": 4102444800,
                    "pairing_code": "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "hmd_pubkey": "A" * 43 + "="}}


def line(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n"


class AppScenario:
    def __init__(self, relay=False, gh_mode="ok", ttl=60):
        self.sb = H.Sandbox()
        self.relay = FakeCodeRelay(ttl_s=ttl, expect_token=H.TOKEN).start() if relay else None
        self.phone = H.Phone(E2E)
        self.rec = os.path.join(self.sb.root, "rec")
        os.makedirs(self.rec)
        self.gh_log = os.path.join(self.sb.root, "gh.log")
        self.recorder = self.sb.write_executable("fake-relay-client", RECORDER_SH)
        self.procs = []
        self.write_gh(gh_mode)

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        for proc in self.procs:
            proc.stop()
        subprocess.run([H.APP_PATH, "disconnect", "--repo", self.sb.repo], env=self.env(), capture_output=True, timeout=60)
        if self.relay is not None:
            self.relay.stop()
        self.sb.close()

    def write_gh(self, mode):
        self.sb.write_executable("gh", """#!/bin/sh
echo "$*" >> "%s"
case "%s" in
  signed-out) echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2; exit 1 ;;
  broken) exit 127 ;;
esac
if [ "$1" = auth ] && [ "$2" = token ]; then printf '%%s\\n' "%s"; exit 0; fi
echo "fake gh: unsupported: $*" >&2
exit 2
""" % (self.gh_log, mode, H.TOKEN))

    def env(self, **extra):
        return self.sb.env(PATH=self.sb.bin + os.pathsep + os.environ.get("PATH", ""), HMD_FAKE_REC=self.rec, **extra)

    def events(self, name, *objs):
        with open(os.path.join(self.rec, name), "w", encoding="utf-8") as f:
            f.write("".join(line(o) for o in objs))

    def read(self, name):
        try:
            with open(os.path.join(self.rec, name), encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""

    def gh_calls(self):
        try:
            with open(self.gh_log, encoding="utf-8") as f:
                return f.read().splitlines()
        except OSError:
            return []

    def app(self, *args, recorder=False, env=None, tty=False):
        """`hmd app connect` with --repo and --port 0 (never the fixed 8710: the machine's own sessions live
        there). `tty=True` gives it a terminal on stdin -- only --confirm needs one."""
        argv = [H.APP_PATH, "connect", "--repo", self.sb.repo, "--port", "0"] + list(args)
        extra = dict(env or {})
        if recorder:
            extra["HEIMDALL_RELAY_CLIENT_BIN"] = self.recorder
        proc = H.Proc(argv, self.env(**extra), cwd=self.sb.repo, tty=tty)
        self.procs.append(proc)
        return proc

    def leaked(self, needle=H.TOKEN.encode()):
        hits = []
        for d in (self.sb.repo, self.sb.home, self.sb.tmp, self.rec):
            hits += H.files_containing(d, needle)
        return hits


def has_none_of(data, *needles):
    return not any(n in data for n in needles)


# -- transport default and the token's path ----------------------------------------------------------
def case_default_transport():
    runs = (
        ("no flag, no env -> the hosted relay", (), {}, H.HOSTED_RELAY),
        ("HMD_RELAY_URL overrides the default", (), {"HMD_RELAY_URL": "http://127.0.0.1:1"}, "http://127.0.0.1:1"),
        ("--relay overrides both", ("--relay", "http://127.0.0.1:2"), {"HMD_RELAY_URL": "http://127.0.0.1:1"},
         "http://127.0.0.1:2"),
    )
    for label, args, env, want in runs:
        with AppScenario() as s:
            s.events("events-1", PAIR_INIT)
            app = s.app(*args, "--no-code", recorder=True, env=env)
            app.close_stdin()
            app.wait_for(lambda: s.read("argv"), 30)
            argv = s.read("argv").splitlines()
            T.check("[--relay]" in argv and argv[argv.index("[--relay]") + 1] == "[%s]" % want,
                    "connect %s" % label, s.read("argv") or app.tail())
    with AppScenario() as s:
        s.events("events-1", PAIR_INIT)
        app = s.app("--no-code", recorder=True)
        app.close_stdin()
        # the last line of the block asserted below, not its first: the lines after PAIRING CODE follow it by a
        # `date` fork, and a poll that lands in between used to find the warning "missing"
        app.wait_text("the relay sees only ciphertext.", 30)
        T.check("scan to pair a device" in app.text() and "WARNING: anyone who scans this code within" in app.text()
                and "SESSION CODE" not in app.text(),
                "--no-code: the QR flow prints exactly as it always did (header, QR, pairing code, warning)", app.tail())
    with AppScenario() as s:
        s.events("events-1", PAIR_INIT)
        app = s.app(recorder=True)  # stdin is a pipe: nobody to ask, and nobody needs to be (pairing by code asks nothing)
        app.close_stdin()
        app.wait_text("PAIRING CODE:", 30)
        argv = s.read("argv").splitlines()
        T.check("no terminal to confirm" not in app.text() and "[--code]" in argv and "[--no-confirm]" in argv,
                "no terminal on stdin: the code is still offered, to a client that is told --no-confirm, and nothing says otherwise", app.tail())


def case_token_path_and_code():
    with AppScenario() as s:
        s.events("events-1", PAIR_INIT)
        app = s.app(recorder=True, tty=True)
        app.wait_for(lambda: s.read("stdin.sha256"), 30)
        argv, env = s.read("argv"), s.read("env")
        code = ""
        if "[--code]" in argv.splitlines():
            code = argv.splitlines()[argv.splitlines().index("[--code]") + 1].strip("[]")
        helper = subprocess.run([sys.executable, H.CODE_HELPER_PATH, "--repo", s.sb.repo], env=s.sb.env(),
                                capture_output=True, text=True, timeout=60).stdout.strip()
        state = subprocess.run([os.path.join(H.REPO, "bin", "heimdall-ui"), "--repo", s.sb.repo, "--print-state"],
                               env=s.sb.env(), capture_output=True, text=True, timeout=120)
        try:
            shown = json.loads(state.stdout)["identity"]["session_code"]
        except (ValueError, KeyError, TypeError):
            shown = None
        T.check(len(code) == 5 and code == helper == shown,
                "the code handed to the client is the one `hmd ui` shows in /api/state (identity.session_code)",
                "client %r helper %r ui %r" % (code, helper, shown))
        T.check(s.read("stdin.sha256").strip() == hashlib.sha256(H.TOKEN.encode()).hexdigest(),
                "the client's first stdin line is exactly the token gh printed (its hash, never the token, was recorded)")
        T.check(H.TOKEN not in argv and H.TOKEN not in env, "the token is in neither the client's argv nor its environment")
        T.check(s.gh_calls() == ["auth token"], "gh is asked exactly `auth token`, once", str(s.gh_calls()))
        app.stop()
        out = app.out() + app.err()
        T.check(H.TOKEN.encode() not in out and s.leaked() == [],
                "the token is in no output of the app and on no disk (repo, HOME, TMPDIR, the recorder's files)",
                str(s.leaked()))
        T.check("[--no-confirm]" in argv and "[--code]" in argv, "a plain connect asks the client for --code and --no-confirm")


def case_off_paths():
    for mode in ("signed-out", "broken"):
        with AppScenario(gh_mode=mode) as s:
            s.events("events-1", PAIR_INIT)
            app = s.app(recorder=True)
            app.close_stdin()
            app.wait_for(lambda: s.read("argv"), 30)
            app.wait_text("PAIRING CODE:", 10)
            T.check(OFF_NO_GH in app.text() and "[--code]" not in s.read("argv") and "PAIRING CODE:" in app.text()
                    and s.gh_calls() == ["auth token"],
                    "gh %s: one line says code pairing is off, no --code is passed, the QR is still printed" % mode, app.tail())
    with AppScenario() as s:
        s.events("events-1", PAIR_INIT)
        app = s.app("--no-code", recorder=True)
        app.close_stdin()
        app.wait_for(lambda: s.read("argv"), 30)
        T.check(s.gh_calls() == [] and "[--code]" not in s.read("argv") and "code pairing off" not in app.text(),
                "--no-code: gh is never asked and nothing is printed about it", app.tail())
    with AppScenario() as s:
        s.events("events-1", PAIR_INIT, {"event": "code_unavailable", "reason": "conflict"})
        app = s.app(recorder=True, tty=True)
        T.check(app.wait_text("is held by another open window of yours. Scan the QR.", 30) and "PAIRING CODE:" in app.text(),
                "a code clash prints one line and the QR is still shown", app.tail())
    with AppScenario() as s:
        s.events("events-1", PAIR_INIT, {"event": "code_unavailable", "reason": "disabled"})
        app = s.app(recorder=True, tty=True)
        T.check(app.wait_text("this relay has code pairing disabled. Scan the QR.", 30), "a relay without code pairing prints one line", app.tail())


def case_flags():
    with AppScenario() as s:
        for args, rc, text in ((("--tailscale", "--relay", "http://127.0.0.1:1"), 2, "--relay and --tailscale are mutually exclusive"),
                               (("--tailscale", "--no-code"), 2, "belong to the relay transport"),
                               (("--relay",), 2, "--relay needs a URL"),
                               (("--confirm", "--bg"), 64, "--confirm asks at this terminal and --bg leaves it"),
                               (("--confirm",), 64, "--confirm asks at this terminal and stdin is not one"),
                               (("--confirm", "--no-confirm"), 2, "--confirm and --no-confirm are mutually exclusive"),
                               (("--confirm", "--no-code"), 2, "cannot be combined with --no-code")):
            s.events("events-1", PAIR_INIT)
            app = s.app(*args, recorder=True)
            app.close_stdin()
            got = app.wait_exit(30)
            T.check(got == rc and text in (app.text() + app.err().decode("utf-8", "replace")),
                    "connect %s -> exit %d, %s" % (" ".join(args), rc, text), "rc %r %s" % (got, app.tail()))
        T.check(s.read("argv") == "", "none of those refusals started the relay client")


def case_bg_with_no_confirm():
    with AppScenario(relay=True) as s:
        app = s.app("--relay", s.relay.url, "--bg", "--no-confirm")
        app.close_stdin()
        rc = app.wait_exit(40)
        out = app.text()
        T.check(rc == 0 and "SESSION CODE:" in out and "running in background" in out
                and out.count("No number to compare") == 1,
                "--bg --no-confirm: returns 0 once the code is on screen, the no-compare trust note printed once", "rc %r %s" % (rc, app.tail()))
        T.check(len(s.relay.registrations) == 1 and s.relay.registrations[0]["token_ok"], "...and the window is registered with the relay")
        sid = s.relay.latest().id
        s.relay.inject_device_bound(sid, s.phone.pub_b64url, via="code")
        deadline = time.time() + 20
        while time.time() < deadline and not s.relay.frames_of(sid, "state"):
            time.sleep(0.1)
        T.check(bool(s.relay.frames_of(sid, "key_reveal")) and bool(s.relay.frames_of(sid, "state")),
                "...and the detached client approves a code bind by itself (nobody is left to ask)")


# -- the prompt --------------------------------------------------------------------------------------
NASTY = "Evil\x1b[2J\x1b]0;pwn\x07\u0085\u009bPhone\x00"
REQUEST = {"event": "approve_request", "sas": "817531", "device_label": NASTY, "gh_login": "octo\x1bcat", "timeout_s": 5}
WINDOW = {"event": "code_window", "code": "4SELK", "gh_login": "octocat", "exp": 4102444800}


def case_prompt():
    for answer, word, then in (("y\n", "approve", {"event": "device_bound", "bound_at": 1}),
                               ("yes\n", "approve", {"event": "device_bound", "bound_at": 1}),
                               ("n\n", "reject", {"event": "code_rejected", "reason": "operator"}),
                               ("\n", "reject", {"event": "code_rejected", "reason": "operator"}),
                               ("maybe\n", "reject", {"event": "code_rejected", "reason": "operator"}),
                               (None, "reject", {"event": "code_rejected", "reason": "eof"})):
        with AppScenario() as s:
            s.events("events-1", PAIR_INIT, WINDOW, REQUEST)
            s.events("events-2", then)
            app = s.app("--confirm", recorder=True, tty=True)
            shown = app.wait_text("Approve [y/N]:", 40)
            if answer is None:
                app.close_stdin()
            else:
                app.send(answer)
            want = "phone paired" if word == "approve" else "pairing rejected — device revoked"
            app.wait_text(want, 20)
            out = app.text()
            T.check(shown and want in out and s.read("control").split() == [word],
                    "prompt answered %r -> the client is told %s and the screen says %r" % (answer, word, want),
                    "control %r %s" % (s.read("control"), app.tail()))
            if answer == "y\n":
                T.check("The phone shows:  817 531" in out and "relay-claimed device name: 'Evil[2J]0;pwnPhone'" in out
                        and "relay-claimed GitHub user: @octocat" in out,
                        "the prompt shows the SAS as 817 531 and the phone's label and login, each marked relay-claimed (escape bytes gone, the rest is plain text)",
                        out[-500:])
                T.check(has_none_of(app.out(), b"\x1b", b"\x07", b"\x00", "\u0085".encode(), "\u009b".encode()),
                        "no escape, bell, NUL or C1 control of the phone's label or login reaches the terminal")
                T.check("SESSION CODE: 4SELK" in out and "type 4SELK." in out and "as @octocat can use it. Valid for 10 min." in out,
                        "the SESSION CODE block names the code, the GitHub login and the 10 minutes")
    with AppScenario() as s:
        s.events("events-1", PAIR_INIT, WINDOW, {"event": "code_paired", "device_label": NASTY, "gh_login": "octo\x1bcat", "bound_at": 1},
                 {"event": "device_bound", "bound_at": 1})
        app = s.app(recorder=True)
        app.close_stdin()
        app.wait_text("phone paired via code", 40)
        out = app.text()
        T.check("Approve [y/N]" not in out and "[--no-confirm]" in s.read("argv") and out.count("phone paired") == 1
                and "relay-claimed device 'Evil[2J]0;pwnPhone', GitHub @octocat" in out
                and has_none_of(app.out(), b"\x1b", b"\x07", b"\x00", "\u0085".encode(), "\u009b".encode()),
                "default connect: the client is told --no-confirm, no prompt appears, a code bind is announced once as relay-claimed "
                "(escape bytes of the phone's label and login gone)", app.tail())
    with AppScenario() as s:
        renewal = dict(PAIR_INIT, renewal=1)
        s.events("events-1", PAIR_INIT, WINDOW, renewal, dict(WINDOW, renewal=1), {"event": "code_window_closed", "reason": "expired"})
        app = s.app(recorder=True, tty=True)
        app.wait_text("code window closed", 40)
        T.check(app.text().count("PAIRING CODE:") == 1 and app.text().count("SESSION CODE:") == 1
                and "code window closed — rerun to pair" in app.text() + app.err().decode("utf-8", "replace"),
                "a renewal prints neither a second QR nor a second SESSION CODE; the window's end is one line", app.tail())


# -- identity revoke ---------------------------------------------------------------------------------
def case_identity_revoke():
    with AppScenario(relay=True) as s:
        proc = H.Proc([H.APP_PATH, "identity", "revoke", "--relay", s.relay.url], s.env(), cwd=s.sb.repo)
        s.procs.append(proc)
        rc = proc.wait_exit(40)
        T.check(rc == 0 and "revoked every hmd app sign-in for @octocat" in proc.text()
                and s.relay.identity_revokes and s.relay.identity_revokes[0]["keys"] == ["gh_token"]
                and s.relay.identity_revokes[0]["token_ok"] and s.gh_calls() == ["auth token"],
                "identity revoke: gh's token goes to POST /identity/github/revoke and the login is reported", "rc %r %s" % (rc, proc.tail()))
        T.check(s.leaked() == [] and H.TOKEN.encode() not in proc.out() + proc.err(), "identity revoke: the token is on no disk and in no output")
    with AppScenario(relay=True, gh_mode="signed-out") as s:
        proc = H.Proc([H.APP_PATH, "identity", "revoke", "--relay", s.relay.url], s.env(), cwd=s.sb.repo)
        s.procs.append(proc)
        rc = proc.wait_exit(40)
        T.check(rc == 3 and s.relay.identity_revokes == [] and b"gh auth login" in proc.err(),
                "identity revoke with gh signed out: exit 3, the relay is never called", "rc %r %s" % (rc, proc.tail()))
    with AppScenario(relay=True) as s:
        s.relay.identity_status = lambda _rec: (401, {"error": "github token rejected"})
        proc = H.Proc([H.APP_PATH, "identity", "revoke", "--relay", s.relay.url], s.env(), cwd=s.sb.repo)
        s.procs.append(proc)
        rc = proc.wait_exit(40)
        T.check(rc == 3 and b"nothing was revoked" in proc.err() and b"revoked every" not in proc.out(),
                "identity revoke refused by GitHub (401): exit 3 and it says nothing was revoked", "rc %r %s" % (rc, proc.tail()))


# -- one whole pairing -------------------------------------------------------------------------------
def case_end_to_end():
    with AppScenario(relay=True) as s:
        app = s.app("--relay", s.relay.url, "--confirm", tty=True)
        T.check(app.wait_text("SESSION CODE:", 40), "end to end: the app prints the SESSION CODE after the relay verified the token", app.tail())
        sid = s.relay.latest().id
        s.relay.inject_device_bound(sid, s.phone.pub_b64url, via="code", device_label="Pixel 9a")
        shown = app.wait_text("Approve [y/N]:", 20)
        reveals = s.relay.frames_of(sid, "key_reveal")
        hmd_pub = H.b64_any(reveals[0]["payload"]["hmd_pubkey"]) if reveals else b""
        sas = H.sas_ref(sid, hmd_pub, s.phone.pub)
        T.check(shown and ("The phone shows:  %s %s" % (sas[:3], sas[3:])) in app.text()
                and "relay-claimed device name: 'Pixel 9a'" in app.text() and "relay-claimed GitHub user: @octocat" in app.text(),
                "end to end: the prompt shows the SAS the phone computes from the revealed key, its name and login marked relay-claimed", app.tail())
        T.check(s.relay.frames_of(sid, "state") == [], "end to end: nothing is sealed while the prompt waits")
        app.send("y\n")
        app.wait_text("phone paired", 20)
        deadline = time.time() + 20
        while time.time() < deadline and not s.relay.frames_of(sid, "state"):
            time.sleep(0.1)
        states = s.relay.frames_of(sid, "state")
        opened = s.phone.open_hmd_frame(hmd_pub, sid, states[0]) if states else None
        T.check("phone paired" in app.text() and opened is not None and "state" in opened,
                "end to end: y pairs the session and the first sealed state frame opens under the phone's key", app.tail())
    with AppScenario(relay=True) as s:
        app = s.app("--relay", s.relay.url, "--confirm", tty=True)
        app.wait_text("SESSION CODE:", 40)
        sid = s.relay.latest().id
        s.relay.inject_device_bound(sid, s.phone.pub_b64url, via="code")
        app.wait_text("Approve [y/N]:", 20)
        app.send("n\n")
        app.wait_text("pairing rejected — device revoked", 20)
        deadline = time.time() + 25
        while time.time() < deadline and len(s.relay.registrations) < 2:
            time.sleep(0.1)
        T.check(sid in s.relay.revokes and len(s.relay.registrations) >= 2 and s.relay.frames_of(sid, "state") == []
                and s.relay.registrations[1]["code"] == s.relay.registrations[0]["code"],
                "end to end: n revokes the session, seals nothing, and the window renews with the same code", app.tail())
    with AppScenario(relay=True) as s:
        s.relay.code_status = lambda _reg: (409, {"error": "code in use by another open window"})
        app = s.app("--relay", s.relay.url, tty=True)
        T.check(app.wait_text("is held by another open window of yours. Scan the QR.", 40) and "PAIRING CODE:" in app.text(),
                "end to end: the relay's 409 prints one line and the QR is still shown", app.tail())


def main():
    for case in (case_default_transport, case_token_path_and_code, case_off_paths, case_flags,
                 case_bg_with_no_confirm, case_prompt, case_identity_revoke, case_end_to_end):
        try:
            case()
        except Exception as exc:  # a case that dies is a failure, not a crash of the whole run
            T.check(False, "%s raised %s: %s" % (case.__name__, type(exc).__name__, exc))
    return T.finish()


if __name__ == "__main__":
    sys.exit(main())

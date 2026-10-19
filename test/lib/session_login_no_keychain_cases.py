#!/usr/bin/env python3
"""test/lib/session_login_no_keychain_cases.py -- the relay session login never asks macOS for a keychain that is not there.

2026-10-19, in the middle of a sweep, macOS showed "Keychain Not Found -- A keychain cannot be found to store <account>" with a "Reset To
Defaults" button: a test harness ran under `env -i HOME=<throwaway>`, which drops the sweep's HMD_SESSION_LOGIN_STORE=file, and
bin/lib/hmd_session_login.py stored the login of a bound phone with `security -i add-generic-password` -- under a HOME with no keychain.
macOS then asks a human what to do, and `security -i` waits for the answer. The store now asks first, with the one `security` verb that
only reads (`default-keychain`), and talks to a keychain only when one exists under this HOME. Every case below runs against a STUB
`security` -- the only thing on PATH, so the real binary is unreachable and no Keychain, real or not, is touched -- that records every
call and treats an item verb (add / find / delete / -i) with no keychain as a VIOLATION: it exits 99 and logs it, and a case fails on it.
  N0  the tripwire itself works: an item read with no keychain is a recorded violation
  N1  auto, no keychain for this HOME: the login goes to the 0600 file with its secret, ONE notice on stderr says why, and the only thing
      `security` was ever asked is `default-keychain`; reading it back and discarding it ask nothing either
  N2  HMD_SESSION_LOGIN_STORE=keychain with no keychain is an ERROR (OSError naming the variable), not a dialog and not a quiet file
  N3  HMD_SESSION_LOGIN_STORE=file wins over a keychain that is there: `security` is never run, not even to ask, and nothing is said
  N4  a keychain under this HOME (auto, and explicit): the secret goes to it, the metadata file holds none, it is read back from it and
      discarding the login removes the item
  N5  a `security` that names a keychain that is not this HOME's -- another account's login keychain (a path that merely starts with
      HOME), or a file that is not on disk -- is not used: file store, one notice; explicit keychain is an error
  N6  no HOME at all: no keychain is assumed
  N7  a `security` that never answers -- the probe, or an item read (a dialog nobody answers) -- is killed at HMD_SECURITY_TIMEOUT_S and the
      login falls back to the file within seconds; security_timeout_s() takes only a number above 0
  N8  a login whose keychain is gone (the CLI, as `env -i` runs it): its secret cannot be read, so the revoke fails loudly and keeps it --
      without one item verb; discarding such a login asks nothing and removes it
  N9  not macOS, or no `security` binary: auto is the file, silently; explicit keychain is an error
  N10 HOME reached through a link, the keychain named by its real path: still this HOME's
  N11 the fake `security` the resume / revoke / forget suites share carries a keychain the probe accepts (those suites run the Keychain path)
"""
import contextlib
import glob
import io
import os
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "bin", "lib"))
import hmd_session_login as L  # noqa: E402

LOGIN_LIB = os.path.join(ROOT, "bin", "lib", "hmd_session_login.py")
TOKEN = secrets.token_hex(16)
SECRET = {"token": TOKEN, "priv": "cHJpdg=="}
PASS = FAIL = 0

# What `security` is, as far as the login store can tell. `default-keychain` answers like the real tool -- `    "<path>"` and 0, or "A
# default keychain could not be found" and 1 -- and every other verb is an item verb: allowed only where a keychain is.
STUB = '''#!@PYTHON@
import hashlib
import os
import shlex
import sys
import time

d = os.environ["STUB_DIR"]
argv = sys.argv[1:]
with open(os.path.join(d, "mode"), encoding="utf-8") as f:
    mode = f.read().strip()
home = os.path.realpath(os.environ.get("HOME", "/nonexistent"))


def log(name, text):
    with open(os.path.join(d, name), "a", encoding="utf-8") as f:
        f.write(text + "\\n")


def run(a):
    opts = a[1:]

    def opt(flag):
        return opts[opts.index(flag) + 1] if flag in opts else ""

    path = os.path.join(d, "item-" + hashlib.sha256((opt("-s") + "/" + opt("-a")).encode()).hexdigest()[:16])
    if a[0] == "add-generic-password":
        with open(path, "w", encoding="utf-8") as f:
            f.write(bytes.fromhex(opt("-X")).decode())
        return 0
    if a[0] == "find-generic-password":
        if mode == "hang-find":
            time.sleep(120)
        if not os.path.exists(path):
            return 44
        with open(path, encoding="utf-8") as f:
            sys.stdout.write(f.read() + "\\n")
        return 0
    if a[0] == "delete-generic-password":
        if not os.path.exists(path):
            return 44
        os.remove(path)
        return 0
    return 1


log("calls.log", " ".join(argv))
if argv[:1] == ["default-keychain"]:
    if mode == "hang-probe":
        time.sleep(120)
    if mode in ("present", "hang-find", "stale"):
        print('    "%s"' % os.path.join(home, "Library", "Keychains", "login.keychain-db"))
        sys.exit(0)
    if mode == "foreign":
        print('    "%s"' % os.environ["STUB_FOREIGN"])
        sys.exit(0)
    sys.stderr.write("security: SecKeychainCopyDefault: A default keychain could not be found.\\n")
    sys.exit(1)
if mode not in ("present", "hang-find"):
    log("violations.log", " ".join(argv))
    sys.stderr.write("stub security: there is no keychain here, and something asked it to store or read an item anyway\\n")
    sys.exit(99)
if argv[:1] == ["-i"]:
    for line in sys.stdin:
        parts = shlex.split(line)
        if parts:
            run(parts)
    sys.exit(0)
sys.exit(run(argv))
'''


def check(n, text, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
    print("  %s %s. %s" % ("ok  " if cond else "FAIL", n, text))


class Scene:
    """A throwaway HOME, HEIMDALL_HOME and repo and the stub `security` as the ONLY thing on PATH, for the length of a `with`. `mode` is what
    the stub says: none, present (a login keychain under HOME), foreign (it names a keychain outside HOME that starts with HOME's name), stale
    (it names a keychain under HOME that is not on disk), hang-probe (default-keychain never answers), hang-find (present, but an item read
    never answers)."""

    ENV_KEYS = ("HOME", "HEIMDALL_HOME", "PATH", "STUB_DIR", "STUB_FOREIGN", "HMD_SESSION_LOGIN_STORE", "HMD_SECURITY_TIMEOUT_S")

    def __init__(self, mode, store=None, platform="darwin", stub=True, home_set=True, link_home=False, **env):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="hmd-nokc."))
        self.home = os.path.join(self.tmp, "home")
        self.hh = os.path.join(self.home, ".heimdall")
        self.repo = os.path.join(self.tmp, "repo")
        self.bin = os.path.join(self.tmp, "bin")
        self.state = os.path.join(self.tmp, "stub-state")
        self.keychains = os.path.join(self.home, "Library", "Keychains")
        self.keychain = os.path.join(self.keychains, "login.keychain-db")
        self.foreign = os.path.join(self.home + "-real", "Library", "Keychains", "login.keychain-db")
        self.platform, self.stub = platform, stub
        for d in (self.home, self.repo, self.bin, self.state, os.path.dirname(self.foreign)):
            os.makedirs(d)
        self.set_mode(mode)
        if stub:
            fake = os.path.join(self.bin, "security")
            with open(fake, "w", encoding="utf-8") as f:
                f.write(STUB.replace("@PYTHON@", sys.executable))
            os.chmod(fake, 0o755)
        if mode in ("present", "hang-find"):
            os.makedirs(self.keychains)
            open(self.keychain, "w", encoding="utf-8").close()
        elif mode in ("stale", "foreign"):
            os.makedirs(self.keychains)  # the directory is there; the keychain the stub names is not in it
        if mode == "foreign":
            open(self.foreign, "w", encoding="utf-8").close()
        self.env = {"HOME": self.home, "HEIMDALL_HOME": self.hh, "PATH": self.bin, "STUB_DIR": self.state, "STUB_FOREIGN": self.foreign}
        if link_home:
            self.env["HOME"] = os.path.join(self.tmp, "home-link")
            os.symlink(self.home, self.env["HOME"])
        if not home_set:
            del self.env["HOME"]
        if store:
            self.env["HMD_SESSION_LOGIN_STORE"] = store
        self.env.update(env)

    def __enter__(self):
        self.saved = {k: os.environ.get(k) for k in self.ENV_KEYS}
        self.saved_platform = sys.platform
        for k in self.ENV_KEYS:
            os.environ.pop(k, None)
        os.environ.update(self.env)
        sys.platform = self.platform
        wanted = os.path.join(self.bin, "security") if self.stub else None
        if shutil.which("security") != wanted:
            self.__exit__(None, None, None)
            raise RuntimeError("`security` on PATH is not the stub (%r): refusing to go on" % shutil.which("security"))
        return self

    def __exit__(self, *_exc):
        sys.platform = self.saved_platform
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)
        return False

    def set_mode(self, mode):
        with open(os.path.join(self.state, "mode"), "w", encoding="utf-8") as f:
            f.write(mode)

    def _lines(self, name):
        try:
            with open(os.path.join(self.state, name), encoding="utf-8") as f:
                return [line.strip() for line in f if line.strip()]
        except FileNotFoundError:
            return []

    def calls(self):
        return self._lines("calls.log")

    def clear_calls(self):
        os.remove(os.path.join(self.state, "calls.log"))

    def violations(self):
        return self._lines("violations.log")

    def items(self):
        return glob.glob(os.path.join(self.state, "item-*"))

    def logins(self):
        return sorted(glob.glob(os.path.join(self.hh, "app", "sessions", "*.json")))

    def cli_env(self):
        """What `env -i HOME=... PATH=...` hands a process: no HMD_SESSION_LOGIN_STORE, so the store is on auto."""
        return {k: os.environ[k] for k in ("HOME", "HEIMDALL_HOME", "PATH", "STUB_DIR") if k in os.environ}


def store(sc, sid="s1"):
    """What a client does when a phone binds: (what it said on stderr, the OSError it raised or None, seconds it took)."""
    err, raised, began = io.StringIO(), None, time.monotonic()
    with contextlib.redirect_stderr(err):
        try:
            L.save(sc.repo, "http://127.0.0.1:9", sid, SECRET, pub="cHVi", device_pub="ZGV2", device_id="abcd1234",
                   device_meta={"label": "x", "gh_login": "y", "via": "qr"}, bound_at=1, hmd_seq=1000, last_device_seq=0, pid=0)
        except OSError as e:
            raised = e
    return err.getvalue(), raised, time.monotonic() - began


def one_notice(said):
    return len(said.strip().splitlines()) == 1 and "keychain" in said.lower() and TOKEN not in said


def in_file(sc, raised):
    """True when the login was kept in the 0600 file, with its secret in it, and `security` was never asked for an item (nothing was stored
    in the stub's keychain either, whichever mode it is in)."""
    if raised is not None:
        return False
    recs = L.records(sc.repo)
    private = bool(sc.logins()) and all(stat.S_IMODE(os.stat(p).st_mode) == 0o600 for p in sc.logins())
    return (len(recs) == 1 and recs[0].get("secret_in") == "file" and recs[0].get("secret") == SECRET and private
            and not sc.violations() and not sc.items() and TOKEN not in "".join(sc.calls()))


def scenario_tripwire():
    with Scene("none") as sc:
        done = subprocess.run(["security", "find-generic-password", "-a", "x", "-s", "y", "-w"], capture_output=True, text=True, timeout=30)
        check("N0", "the tripwire works: the stub answers an item read, with no keychain, by logging a violation and exiting 99",
              done.returncode == 99 and len(sc.violations()) == 1)


def scenario_auto_none():
    with Scene("none") as sc:
        said, raised, _took = store(sc)
        check("N1", "auto, no keychain for this HOME: the login is kept in the 0600 file, the secret in it", in_file(sc, raised))
        check("N1", "... and the only thing `security` was asked is `default-keychain` (a read): no add, no find, no `-i`",
              bool(sc.calls()) and set(sc.calls()) == {"default-keychain"} and not sc.violations())
        check("N1", "... and ONE notice on stderr says why, naming this HOME, with no secret in it", one_notice(said) and sc.home in said)
        recs = L.records(sc.repo)
        secret = L.secret_of(sc.repo, recs[0]) if recs else None
        L.discard(sc.repo, "s1")
        check("N1", "... reading the secret back and discarding the login ask `security` for nothing more",
              secret == SECRET and not L.records(sc.repo) and set(sc.calls()) == {"default-keychain"} and not sc.violations())


def scenario_explicit_keychain_none():
    with Scene("none", store="keychain") as sc:
        said, raised, _took = store(sc)
        check("N2", "HMD_SESSION_LOGIN_STORE=keychain with no keychain: an OSError that names the variable, nothing stored, no item verb",
              isinstance(raised, OSError) and "HMD_SESSION_LOGIN_STORE=keychain" in str(raised) and not sc.logins() and not sc.violations()
              and TOKEN not in str(raised) + said)


def scenario_explicit_file():
    with Scene("present", store="file") as sc:
        said, raised, _took = store(sc)
        check("N3", "HMD_SESSION_LOGIN_STORE=file wins over a keychain that is there: the file, `security` never run (not to ask either), "
                    "nothing said", in_file(sc, raised) and sc.calls() == [] and said == "")


def scenario_keychain_present():
    for explicit in (None, "keychain"):
        with Scene("present", store=explicit) as sc:
            said, raised, _took = store(sc)
            recs = L.records(sc.repo)
            check("N4", "a keychain under this HOME (%s): the secret goes to it, the metadata file holds none, nothing is said" % (explicit or "auto"),
                  raised is None and len(recs) == 1 and recs[0].get("secret_in") == "keychain" and "secret" not in recs[0]
                  and len(sc.items()) == 1 and said == "" and not sc.violations())
            secret = L.secret_of(sc.repo, recs[0]) if recs else None
            L.discard(sc.repo, "s1")
            check("N4", "... it is read back from the keychain, and discarding the login removes the item (%s)" % (explicit or "auto"),
                  secret == SECRET and not sc.items() and not L.records(sc.repo) and not sc.violations())


def scenario_wrong_keychain():
    for mode, what in (("foreign", "another account's login keychain, outside HOME (its path starts with HOME's)"),
                       ("stale", "a keychain file that is not on disk")):
        with Scene(mode) as sc:
            said, raised, _took = store(sc)
            check("N5", "auto, `security` names %s: not used -- the file, ONE notice, no item verb" % what,
                  in_file(sc, raised) and one_notice(said))
        with Scene(mode, store="keychain") as sc:
            said, raised, _took = store(sc)
            check("N5", "... and HMD_SESSION_LOGIN_STORE=keychain is an error (%s)" % mode,
                  isinstance(raised, OSError) and not sc.logins() and not sc.violations())


def scenario_no_home():
    with Scene("present", home_set=False) as sc:
        said, raised, _took = store(sc)
        check("N6", "no HOME at all: no keychain is assumed -- the file, ONE notice, no item verb", in_file(sc, raised) and one_notice(said))


def scenario_hang():
    with Scene("hang-probe", HMD_SECURITY_TIMEOUT_S="1") as sc:
        said, raised, took = store(sc)
        check("N7", "a `security` that never answers the probe is killed at HMD_SECURITY_TIMEOUT_S=1: the file, no item verb (%.1fs)" % took,
              took < 10 and in_file(sc, raised) and one_notice(said))
    with Scene("hang-find", HMD_SECURITY_TIMEOUT_S="1") as sc:
        said, raised, took = store(sc)
        recs = L.records(sc.repo)
        check("N7", "... and so is one that hangs on an item read (a dialog nobody answers): the login falls back to the file (%.1fs)" % took,
              took < 10 and raised is None and len(recs) == 1 and recs[0].get("secret_in") == "file" and recs[0].get("secret") == SECRET)
    results = {}
    for value in ("", "garbage", "0", "-3", "nan", "inf", "99999", "2.5"):
        os.environ["HMD_SECURITY_TIMEOUT_S"] = value
        results[value] = L.security_timeout_s()
    os.environ.pop("HMD_SECURITY_TIMEOUT_S")
    default = L.SECURITY_TIMEOUT_S
    check("N7", "security_timeout_s() takes only a number above 0 (and at most an hour), else the default %ds" % default,
          all(results[v] == default for v in ("", "garbage", "0", "-3", "nan", "inf", "99999")) and results["2.5"] == 2.5)


def scenario_login_outlives_its_keychain():
    with Scene("present") as sc:
        _said, raised, _took = store(sc)
        recs = L.records(sc.repo)
        in_keychain = raised is None and len(recs) == 1 and recs[0].get("secret_in") == "keychain"
        os.remove(sc.keychain)  # the keychain is gone (another HOME, a reset): the login still names it
        sc.set_mode("none")
        sc.clear_calls()
        done = subprocess.run([sys.executable, LOGIN_LIB, "revoke", "--repo", sc.repo, "--all"], env=sc.cli_env(), capture_output=True,
                              text=True, timeout=120)
        said = done.stdout + done.stderr
        check("N8", "the revoke CLI under a bare environment cannot read a secret whose keychain is gone: it fails loudly and keeps the login, "
                    "asking `security` only `default-keychain`",
              in_keychain and done.returncode == 1 and "could NOT be revoked" in said and len(L.records(sc.repo)) == 1
              and set(sc.calls()) == {"default-keychain"} and not sc.violations() and TOKEN not in said)
        L.discard(sc.repo, "s1")
        check("N8", "... and discarding that login removes it, with no item verb (there is no item to remove)",
              not L.records(sc.repo) and not sc.logins() and not sc.violations())


def scenario_not_macos_or_no_binary():
    with Scene("present", platform="linux") as sc:
        said, raised, _took = store(sc)
        check("N9", "not macOS: auto is the file, silently, and `security` is never run", in_file(sc, raised) and sc.calls() == [] and said == "")
    with Scene("none", stub=False) as sc:
        said, raised, _took = store(sc)
        check("N9", "no `security` on PATH: auto is the file, silently", in_file(sc, raised) and said == "")
    with Scene("none", stub=False, store="keychain") as sc:
        said, raised, _took = store(sc)
        check("N9", "... and HMD_SESSION_LOGIN_STORE=keychain without a `security` is an error", isinstance(raised, OSError) and not sc.logins())


def scenario_linked_home():
    with Scene("present", link_home=True) as sc:
        said, raised, _took = store(sc)
        recs = L.records(sc.repo)
        check("N10", "HOME reached through a link, the keychain named by its real path: it is this HOME's, and is used",
              raised is None and len(recs) == 1 and recs[0].get("secret_in") == "keychain" and len(sc.items()) == 1 and said == ""
              and not sc.violations())


def scenario_shared_fake():
    import app_session_resume_cases as H
    sb, saved = H.Sandbox(), dict(os.environ)
    try:
        items, env = H.install_fake_security(sb)
        pybin = os.path.join(sb.tmp, "pybin")  # the fake runs as `env python3`: give PATH a python3, and nothing else, beside the fake
        os.makedirs(pybin)
        os.symlink(sys.executable, os.path.join(pybin, "python3"))
        os.environ.update(sb.env(**dict(env, PATH=sb.bin + os.pathsep + pybin)))  # the real `security` is out of reach
        if shutil.which("security") != os.path.join(sb.bin, "security"):
            raise RuntimeError("`security` on PATH is not the suites' fake: refusing to go on")
        L.save(sb.repo, "http://127.0.0.1:9", "s1", SECRET, pub="cHVi", device_pub="ZGV2", device_id="abcd1234",
               device_meta={"label": "x", "gh_login": "y", "via": "qr"}, bound_at=1, hmd_seq=1000, last_device_seq=0, pid=0)
        recs = L.records(sb.repo)
        secret = L.secret_of(sb.repo, recs[0]) if recs else None
        check("N11", "the suites' fake `security` carries a keychain the probe accepts: an explicit-keychain login lands in it and reads back",
              len(recs) == 1 and recs[0].get("secret_in") == "keychain" and len(glob.glob(os.path.join(items, "item-*"))) == 1 and secret == SECRET)
        L.discard(sb.repo, "s1")
        check("N11", "... and discarding it removes the item", not glob.glob(os.path.join(items, "item-*")) and not L.records(sb.repo))
    finally:
        os.environ.clear()
        os.environ.update(saved)
        sb.drop()


def main():
    for run in (scenario_tripwire, scenario_auto_none, scenario_explicit_keychain_none, scenario_explicit_file, scenario_keychain_present,
                scenario_wrong_keychain, scenario_no_home, scenario_hang, scenario_login_outlives_its_keychain, scenario_not_macos_or_no_binary,
                scenario_linked_home, scenario_shared_fake):
        try:
            run()
        except Exception as e:  # a scenario that cannot run is a failed check, and the next still runs
            check("ERR", "%s raised %s: %s" % (run.__name__, type(e).__name__, e), False)
    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

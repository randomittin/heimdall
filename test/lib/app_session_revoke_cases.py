#!/usr/bin/env python3
"""test/lib/app_session_revoke_cases.py -- every way a phone is unpaired either confirms the revoke at the relay or fails loudly and KEEPS
the stored login (and the device record); nothing reports success, and nothing deletes local state, on a revoke the relay did not confirm.
  V1  the relay refuses the revoke (403): non-zero, 'NOT' said, no 'revoked device', login and device record kept; the same command
      succeeds once the relay takes it
  V2  the stored secret cannot be read (the Keychain item is gone): the revoke fails loudly with the login kept, and a resume that cannot
      read it does not discard the login either
  V3  `hmd app disconnect` with nothing connected but a stored login the relay will not take: non-zero, the login kept
  V4  a login file that cannot be read (not 0600) is never walked past: --device and a plain disconnect both fail loudly, nothing deleted
  V5  `hmd app disconnect` with a live client and a relay that cannot be reached: non-zero, login and device record kept
  V6  a live client that could not store its login is revoked through its own stop (TERM), not through a signal it ignores
  V7  a client whose stored login has gone cannot be resumed, so stopping it revokes its session itself
"""
import glob
import os
import signal
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import app_session_resume_cases as H  # noqa: E402

PASS = FAIL = 0


def check(n, text, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
    print("  %s %s. %s" % ("ok  " if cond else "FAIL", n, text))


def app(sb, env, *args):
    return subprocess.run([H.APP] + list(args), env=sb.env(**env), capture_output=True, text=True, timeout=180)


def said(done):
    return done.stdout + done.stderr


def fake_keychain(sb):
    store = os.path.join(sb.tmp, "kc")
    os.makedirs(store)
    fake = os.path.join(sb.bin, "security")
    with open(fake, "w", encoding="utf-8") as f:
        f.write(H.FAKE_SECURITY)
    os.chmod(fake, 0o755)
    return store, dict(HMD_SESSION_LOGIN_STORE="keychain", FAKE_SECURITY_DIR=store, PATH=sb.bin + os.pathsep + os.environ["PATH"])


def scenario_relay_refuses():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = None
    try:
        c1, sid, _key = H.bind_phone(sb, relay)
        c1.stop(signal.SIGKILL)
        did = H.device_id(sb)
        relay.revoke_status = 403
        r = app(sb, {}, "disconnect", "--repo", sb.repo, "--device", did)
        check("V1", "a relay that refuses the revoke (403): non-zero, 'NOT' said, no 'revoked device', login and device record KEPT",
              r.returncode != 0 and "NOT" in said(r) and "revoked device" not in said(r) and len(sb.logins()) == 1
              and len(sb.device_records()) == 1 and relay.revokes == [])
        relay.revoke_status = None
        r = app(sb, {}, "disconnect", "--repo", sb.repo, "--device", did)
        check("V1", "the same command succeeds once the relay takes the revoke",
              r.returncode == 0 and relay.revokes == [sid] and not sb.logins() and not sb.device_records())
    finally:
        H.kill_leftovers(c1)
        relay.close()
        sb.drop()


def scenario_secret_unreadable():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = c2 = None
    try:
        store, env = fake_keychain(sb)
        c1, _sid, _key = H.bind_phone(sb, relay, **env)
        c1.stop(signal.SIGKILL)
        for item in glob.glob(os.path.join(store, "item-*")):
            os.remove(item)  # the Keychain no longer gives the secret up
        r = app(sb, env, "disconnect", "--repo", sb.repo, "--device", H.device_id(sb))
        check("V2", "the stored secret cannot be read: non-zero, 'NOT' said, login and device record KEPT, nothing revoked",
              r.returncode != 0 and "NOT" in said(r) and len(sb.logins()) == 1 and len(sb.device_records()) == 1 and relay.revokes == [])
        c2 = H.Client(sb, relay, "c2", resume=True, **env)
        c2.event("pair_init")
        check("V2", "a resume that cannot read the secret does not discard the login either (the phone pairs afresh meanwhile)",
              len(sb.logins()) == 1 and c2.event("session_resumed", 1) is None)
    finally:
        H.kill_leftovers(c1, c2)
        relay.close()
        sb.drop()


def scenario_nothing_connected():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = None
    try:
        c1, _sid, _key = H.bind_phone(sb, relay)
        c1.stop(signal.SIGKILL)
        relay.down = True
        r = app(sb, {}, "disconnect", "--repo", sb.repo)
        check("V3", "`hmd app disconnect` with nothing connected but a stored login the relay cannot take: non-zero, the login KEPT",
              r.returncode != 0 and len(sb.logins()) == 1 and relay.revokes == [])
    finally:
        H.kill_leftovers(c1)
        relay.close()
        sb.drop()


def scenario_login_unreadable():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = None
    try:
        c1, _sid, _key = H.bind_phone(sb, relay)
        c1.stop(signal.SIGKILL)
        path = sb.logins()[0]
        os.chmod(path, 0o644)  # a file that is not 0600 is never believed
        r = app(sb, {}, "disconnect", "--repo", sb.repo, "--device", H.device_id(sb))
        check("V4", "a login file that cannot be read: --device fails loudly, claims no revoke, deletes neither the file nor the record",
              r.returncode != 0 and "NOT" in said(r) and "revoked device" not in said(r) and os.path.exists(path)
              and len(sb.device_records()) == 1 and relay.revokes == [])
        r = app(sb, {}, "disconnect", "--repo", sb.repo)
        check("V4", "... and a plain disconnect fails loudly too", r.returncode != 0 and os.path.exists(path) and relay.revokes == [])
    finally:
        H.kill_leftovers(c1)
        relay.close()
        sb.drop()


def scenario_live_relay_down():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = None
    try:
        c1, _sid, _key = H.bind_phone(sb, relay)
        relay.down = True
        r = app(sb, {}, "disconnect", "--repo", sb.repo)
        H.wait_until(lambda: c1.proc.poll() is not None, 20)
        check("V5", "`hmd app disconnect` with a live client and a relay that cannot be reached: non-zero, login and device record KEPT",
              r.returncode != 0 and len(sb.logins()) == 1 and len(sb.device_records()) == 1 and relay.revokes == [])
    finally:
        H.kill_leftovers(c1)
        relay.close()
        sb.drop()


def scenario_login_not_stored():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = None
    try:
        os.makedirs(os.path.join(sb.hh, "app"))
        os.symlink(os.path.join(sb.tmp, "elsewhere"), os.path.join(sb.hh, "app", "sessions"))  # the store refuses every write
        c1, sid, _key = H.bind_phone(sb, relay)
        r = app(sb, {}, "disconnect", "--repo", sb.repo, "--device", H.device_id(sb))
        gone = H.wait_until(lambda: c1.proc.poll() is not None, 20)
        check("V6", "a live client that could not store its login is revoked through its own stop, not a signal it ignores",
              r.returncode == 0 and relay.revokes == [sid] and bool(gone))
    finally:
        H.kill_leftovers(c1)
        relay.close()
        sb.drop()


def scenario_login_gone():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = None
    try:
        c1, sid, _key = H.bind_phone(sb, relay)
        os.remove(sb.logins()[0])
        c1.stop(signal.SIGTERM)
        check("V7", "a client whose stored login has gone cannot be resumed, so stopping it revokes its session itself",
              relay.revokes == [sid])
    finally:
        H.kill_leftovers(c1)
        relay.close()
        sb.drop()


def main():
    try:
        for run in (scenario_relay_refuses, scenario_secret_unreadable, scenario_nothing_connected, scenario_login_unreadable,
                    scenario_live_relay_down, scenario_login_not_stored, scenario_login_gone):
            try:
                run()
            except Exception as e:  # a scenario that cannot run is a failed check, and the next still runs
                check("ERR", "%s raised %s: %s" % (run.__name__, type(e).__name__, e), False)
    finally:
        for pid in H.STARTED:
            try:
                os.kill(pid, 0)
            except OSError:
                continue
            os.kill(pid, signal.SIGKILL)  # only a pid this run started, and only while it is still alive
    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

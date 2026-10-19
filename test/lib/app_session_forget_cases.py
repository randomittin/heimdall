#!/usr/bin/env python3
"""test/lib/app_session_forget_cases.py -- `hmd app disconnect --forget-local`: the one explicit way out of a login whose relay revoke can never
be confirmed (a login stuck `revoking`, a relay that stays down or refuses it). Operator decision, 2.4.8.
  F1  a login a real client stores carries the session's expiry: the bind plus the relay's fixed 30-day device-token lifetime
  F2  WITHOUT the flag nothing is forgotten, whatever else is given: plain disconnect and `--device` both fail, keep the login (marked
      `revoking`), and write no forget record (the disconnect's own app-log note is not one) -- the flag is never implied
  F3  `--forget-local` prints the full relay session id, the warning that the phone can keep connecting, and when (the stored expiry, as an
      absolute UTC time); exit 0
  F4  the stored login (file) and the device record are gone, and the relay was never told (no revoke reached it)
  F5  a log entry: a `session_login_forgotten` event in relay-events.jsonl and a line in $HEIMDALL_HOME/logs/app.log, both 0600, naming the
      session id, the device, the expiry and that the relay was not told
  F6  per device (`--device <id> --forget-local`): only that phone's login goes, the other phone's login and live client are untouched
  F7  for all: the rest goes too, the live client ends, both forgets are logged
  F8  Keychain: the item goes with the metadata; an item that cannot be removed is a non-zero exit that keeps the login and logs nothing
  F9  the delete runs under the store lock: it waits while another process holds it
"""
import glob
import json
import os
import signal
import stat
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import app_session_race_cases as R  # noqa: E402
import app_session_resume_cases as H  # noqa: E402
import app_session_revoke_cases as V  # noqa: E402

L = R.L
PASS = FAIL = 0


def check(n, text, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
    print("  %s %s. %s" % ("ok  " if cond else "FAIL", n, text))


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def said(done):
    return done.stdout + done.stderr


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def set_login(path, **fields):
    meta = read_json(path)
    meta.update(fields)
    with open(path, "w", encoding="utf-8") as f:  # the file exists: it keeps its 0600
        json.dump(meta, f)


def forgotten_events(sb):
    path = os.path.join(sb.repo, ".heimdall", "app", "relay-events.jsonl")
    found = []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return found
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("event") == "session_login_forgotten":
            found.append(ev)
    return found


def app_log(sb):
    try:
        with open(os.path.join(sb.hh, "logs", "app.log"), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def forget_lines(sb):
    """The lines of $HEIMDALL_HOME/logs/app.log that record a forget (`session login forgotten locally ... the relay was NOT told ...`).
    app_log() is NOT empty after a disconnect that forgets nothing: every `hmd app disconnect` notes itself in that log ("the explicit end of a
    pairing", so a phone that went is never a mystery). That line is the disconnect's own, not a forget's, so "no forget record" is read here
    and never as "no app log"."""
    return [line for line in app_log(sb).splitlines() if "login forgotten locally" in line or "NOT told" in line]


def private(path):
    try:
        return stat.S_IMODE(os.stat(path).st_mode) == 0o600
    except OSError:
        return False


def scenario_flag_and_report():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = None
    try:
        c1, sid, _key = H.bind_phone(sb, relay)
        c1.stop(signal.SIGKILL)
        did = H.device_id(sb)
        path = sb.logins()[0]
        meta = read_json(path)
        check("F1", "a login a real client stores carries the session's expiry: the bind plus the relay's 30-day device-token lifetime",
              isinstance(meta.get("bound_at"), int) and meta.get("session_exp") == meta["bound_at"] + 30 * 24 * 3600)
        exp = int(time.time()) + 5 * 86400 + 123
        set_login(path, session_exp=exp)
        relay.down = True
        plain = V.app(sb, {}, "disconnect", "--repo", sb.repo)
        by_device = V.app(sb, {}, "disconnect", "--repo", sb.repo, "--device", did)
        check("F2", "without --forget-local nothing is forgotten (plain and --device both fail, the login stays `revoking`, no forget record)",
              plain.returncode != 0 and by_device.returncode != 0 and len(sb.logins()) == 1 and read_json(path).get("revoking") is True
              and not forgotten_events(sb) and not forget_lines(sb) and "forgot" not in said(plain).lower())
        done = V.app(sb, {}, "disconnect", "--repo", sb.repo, "--forget-local")
        out = said(done)
        check("F3", "--forget-local prints the full session id, the warning and the absolute expiry (the stored one), and exits 0",
              done.returncode == 0 and sid in out and "relay was NOT told" in out and "can keep connecting" in out and iso(exp) in out)
        check("F4", "the stored login and the device record are gone and the relay was never told",
              not sb.logins() and not sb.device_records() and relay.revokes == [])
        events, log = forgotten_events(sb), app_log(sb)
        ev = events[0] if len(events) == 1 else {}
        check("F5", "a `session_login_forgotten` event (session, device, expiry, relay not told) and an app-log line, both 0600",
              ev.get("session_id") == sid and ev.get("device_id") == did and ev.get("session_exp") == exp and ev.get("relay_told") is False
              and sid in log and iso(exp) in log and "NOT told" in log and "ts" in ev
              and private(os.path.join(sb.repo, ".heimdall", "app", "relay-events.jsonl")) and private(os.path.join(sb.hh, "logs", "app.log")))
    finally:
        H.kill_leftovers(c1)
        relay.close()
        sb.drop()


def scenario_per_device_and_all():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = c2 = None
    try:
        c1, sid1, _k1 = H.bind_phone(sb, relay, tag="c1")
        c2, sid2, _k2 = H.bind_phone(sb, relay, tag="c2")
        by_sid = {read_json(p)["session_id"]: read_json(p)["device_id"] for p in sb.logins()}
        c1.stop(signal.SIGKILL)
        relay.down = True
        one = V.app(sb, {}, "disconnect", "--repo", sb.repo, "--device", by_sid[sid1], "--forget-local")
        left = [read_json(p)["session_id"] for p in sb.logins()]
        check("F6", "--device <id> --forget-local forgets only that phone's login: the other login is stored and its client lives on",
              one.returncode == 0 and sid1 in said(one) and left == [sid2] and c2.proc.poll() is None and relay.revokes == []
              and [e["session_id"] for e in forgotten_events(sb)] == [sid1])
        rest = V.app(sb, {}, "disconnect", "--repo", sb.repo, "--forget-local")
        gone = H.wait_until(lambda: c2.proc.poll() is not None, 30)
        check("F7", "without --device everything left goes: the live client ends, no login or record stays, both forgets are logged",
              rest.returncode == 0 and sid2 in said(rest) and bool(gone) and not sb.logins() and not sb.device_records()
              and sorted(e["session_id"] for e in forgotten_events(sb)) == sorted([sid1, sid2]))
    finally:
        H.kill_leftovers(c1, c2)
        relay.close()
        sb.drop()


def scenario_keychain():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = None
    try:
        store, env = V.fake_keychain(sb)
        c1, _sid, _key = H.bind_phone(sb, relay, **env)
        c1.stop(signal.SIGKILL)
        relay.down = True
        items = os.path.join(store, "item-*")
        refused = V.app(sb, dict(env, FAKE_SECURITY_REFUSE_DELETE="1"), "disconnect", "--repo", sb.repo, "--forget-local")
        check("F8", "a Keychain item that cannot be removed fails loudly (exit non-zero) and keeps the login; nothing is logged as forgotten",
              refused.returncode != 0 and "Keychain" in said(refused) and len(sb.logins()) == 1 and len(glob.glob(items)) == 1
              and not forgotten_events(sb))
        done = V.app(sb, env, "disconnect", "--repo", sb.repo, "--forget-local")
        check("F8", "once it can be, the Keychain item goes with the metadata file", done.returncode == 0 and not glob.glob(items)
              and not sb.logins())
    finally:
        H.kill_leftovers(c1)
        relay.close()
        sb.drop()


def scenario_lock():
    sb, relay = H.Sandbox(), H.Relay()
    os.environ.update(HEIMDALL_HOME=sb.hh, HMD_SESSION_LOGIN_STORE="file")
    os.environ.pop("HMD_RELAY_EVENT_LOG", None)
    try:
        sid, token = R.new_session(relay)
        R.store(sb, relay, sid, token)
        waited = R.waits_for_the_lock(sb, lambda: L.forget_login(sb.repo, sid, "test"))
        check("F9", "the delete waits while another process holds the store lock, then removes the login and logs it",
              waited and not L.records(sb.repo) and len(forgotten_events(sb)) == 1 and sid in app_log(sb))
    finally:
        relay.close()
        sb.drop()


def main():
    try:
        for run in (scenario_flag_and_report, scenario_per_device_and_all, scenario_keychain, scenario_lock):
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

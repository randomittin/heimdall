#!/usr/bin/env python3
"""test/lib/app_session_race_cases.py -- concurrent writers of the stored session login must not interleave.

The login store is written by a client's refresh and seq reservation, by a respawned client's claim and by a command-line revoke -- all at
once, from separate processes. Every read-modify-write runs under ONE exclusive store lock, a login a revoke removed cannot be brought back
by a writer holding a stale copy, and a disconnect that has been asked for marks the login `revoking` (durably, first), after which no
resume may claim it.
  L1  each writer -- update, seq reservation, resume claim, revoke, discard -- waits while another process holds the store lock
  L2  a revoke the relay could not confirm marks the login `revoking`, keeps it, and a resume no longer claims it; once the relay takes
      the revoke the login goes
  L3  end to end: after a disconnect that could not be confirmed, a new client does NOT resume the session (the phone pairs afresh), and
      the same disconnect succeeds once the relay can be reached
  L4  a client that resumed first and is then disconnected ends revoked: the relay's session is revoked and the client ends
  L5  two clients started at once on one stored login: exactly one resumes it
"""
import json
import os
import signal
import subprocess
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import app_session_resume_cases as H  # noqa: E402

LIB = os.path.join(H.ROOT, "bin", "lib")
sys.path.insert(0, LIB)
import hmd_session_login as L  # noqa: E402

PASS = FAIL = 0
HOLD = '''
import sys, time
sys.path.insert(0, sys.argv[1])
import hmd_private_state as P
with P.lock(sys.argv[2], "app/sessions", "sessions.lock"):
    print("held", flush=True)
    time.sleep(float(sys.argv[3]))
'''


def check(n, text, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
    print("  %s %s. %s" % ("ok  " if cond else "FAIL", n, text))


def new_session(relay):
    """A real session on the fake relay: (session id, bearer token)."""
    request = urllib.request.Request(relay.url + "/pair/init", data=b"", method="POST")
    with urllib.request.urlopen(request, timeout=10) as answer:
        init = json.loads(answer.read().decode("utf-8"))
    return init["session_id"], init["relay_session_token"]


def store(sb, relay, sid, token):
    """The login a bound client would have stored for that session."""
    L.save(sb.repo, relay.url, sid, {"token": token, "priv": "cHJpdg=="}, pub="cHVi", device_pub="ZGV2", device_id="abcd1234",
           device_meta={"label": "x", "gh_login": "y", "via": "qr"}, bound_at=1, hmd_seq=1000, last_device_seq=0, pid=0)


def waits_for_the_lock(sb, op, hold=2.0):
    """True when `op` (run here, in this process) did not finish while ANOTHER process held the store lock."""
    holder = subprocess.Popen([sys.executable, "-c", HOLD, LIB, sb.hh, str(hold)], stdout=subprocess.PIPE, text=True)
    holder.stdout.readline()  # "held"
    began = time.time()
    op()
    elapsed = time.time() - began
    holder.wait(15)
    return elapsed >= hold * 0.6


def scenario_lock():
    sb, relay = H.Sandbox(), H.Relay()
    os.environ.update(HEIMDALL_HOME=sb.hh, HMD_SESSION_LOGIN_STORE="file")
    try:
        for name in ("update", "seq reservation", "resume claim", "revoke", "discard"):
            sid, token = new_session(relay)
            store(sb, relay, sid, token)
            op = {"update": lambda: L.update(sb.repo, sid, last_device_seq=5),
                  "seq reservation": lambda: L.reserve_block(sb.repo, sid, 10),
                  "resume claim": lambda: L.load_resumable(sb.repo, relay.url),
                  "revoke": lambda: L.revoke_logins(sb.repo),
                  "discard": lambda: L.discard(sb.repo, sid)}[name]
            check("L1", "%s waits while another process holds the store lock" % name, waits_for_the_lock(sb, op))
    finally:
        relay.close()
        sb.drop()


def scenario_revoking_flag():
    sb, relay = H.Sandbox(), H.Relay()
    os.environ.update(HEIMDALL_HOME=sb.hh, HMD_SESSION_LOGIN_STORE="file")
    try:
        sid, token = new_session(relay)
        store(sb, relay, sid, token)
        relay.down = True
        _confirmed, failed, _selected = L.revoke_logins(sb.repo)
        kept = L.records(sb.repo)
        check("L2", "a revoke the relay could not confirm keeps the login, marked `revoking`, and a resume no longer claims it",
              failed == 1 and len(kept) == 1 and kept[0].get("revoking") is True and L.load_resumable(sb.repo, relay.url) is None
              and L.status(sb.repo, sid) == "revoking")
        relay.down = False
        confirmed, failed, _selected = L.revoke_logins(sb.repo)
        check("L2", "once the relay takes the revoke the login goes",
              confirmed == 1 and failed == 0 and not L.records(sb.repo) and relay.revokes == [sid])
    finally:
        relay.close()
        sb.drop()


def disconnect_device(sb, did):
    return subprocess.run([H.APP, "disconnect", "--repo", sb.repo, "--device", did], env=sb.env(), capture_output=True, text=True,
                          timeout=120)


def scenario_disconnect_then_resume():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = c2 = None
    try:
        c1, sid, _key = H.bind_phone(sb, relay)
        c1.stop(signal.SIGKILL)
        did = H.device_id(sb)
        relay.down = True
        refused = disconnect_device(sb, did)
        c2 = H.Client(sb, relay, "c2", resume=True)
        pair = c2.event("pair_init")
        check("L3", "after a disconnect that could not be confirmed a new client does NOT resume the session: the phone pairs afresh",
              refused.returncode != 0 and pair is not None and c2.event("session_resumed", 1) is None and relay.inits == 2
              and not relay.sessions[sid]["revoked"])
        c2.stop(signal.SIGTERM)
        relay.down = False
        retried = disconnect_device(sb, did)
        check("L3", "the same disconnect succeeds once the relay can be reached", retried.returncode == 0 and relay.revokes == [sid])
    finally:
        H.kill_leftovers(c1, c2)
        relay.close()
        sb.drop()


def scenario_resume_then_disconnect():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = c2 = None
    try:
        c1, sid, _key = H.bind_phone(sb, relay)
        c1.stop(signal.SIGKILL)
        c2 = H.Client(sb, relay, "c2", resume=True)
        resumed = c2.event("session_resumed")
        subprocess.run([H.APP, "disconnect", "--repo", sb.repo], env=sb.env(), capture_output=True, text=True, timeout=120)
        gone = H.wait_until(lambda: c2.proc.poll() is not None, 30)
        check("L4", "a client that resumed first and is then disconnected ends revoked: the session is revoked, the client ends, no login "
                    "is left", resumed is not None and relay.sessions[sid]["revoked"] and bool(gone) and not sb.logins())
    finally:
        H.kill_leftovers(c1, c2)
        relay.close()
        sb.drop()


def decided(client):
    return any(e.get("event") in ("session_resumed", "pair_init") for e in client.events())


def scenario_two_resumers():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = c2 = c3 = None
    try:
        c1, sid, _key = H.bind_phone(sb, relay)
        c1.stop(signal.SIGKILL)
        c2 = H.Client(sb, relay, "c2", resume=True)
        c3 = H.Client(sb, relay, "c3", resume=True)
        H.wait_until(lambda: decided(c2) and decided(c3), 40)
        winners = [c for c in (c2, c3) if any(e.get("event") == "session_resumed" for e in c.events())]
        check("L5", "two clients started at once on one stored login: exactly one resumes it, the other pairs afresh",
              len(winners) == 1 and relay.inits == 2 and relay.attaches(sid) == 2)
    finally:
        H.kill_leftovers(c1, c2, c3)
        relay.close()
        sb.drop()


def main():
    try:
        for run in (scenario_lock, scenario_revoking_flag, scenario_disconnect_then_resume, scenario_resume_then_disconnect,
                    scenario_two_resumers):
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

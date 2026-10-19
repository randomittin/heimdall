#!/usr/bin/env python3
"""test/lib/app_session_revoke_race_cases.py -- a disconnect and a resume must never interleave into a phone that comes back after it was
revoked or forgotten (security review of the multi-phone resume, 2.4.8).

A client is started from a snapshot of the stored logins (a periodic look, a respawn, the SessionStart pair window, a `--resume-only` client)
while a disconnect, `--device` or `--forget-local` may be running. So: the disconnect marks FIRST -- every stored login `revoking`, all of them
in one hold of the store lock, before a window, a client or the relay is touched -- every resume start claims under that same lock and skips
what is marked or gone, and a client that got through anyway ends itself, revoking its session, once its login is marked or gone.
  X1  `hmd app disconnect` marks EVERY login before the first relay call returns (the relay is slow): none is left unmarked, and so claimable,
      while an earlier one is being revoked
  X2  a live client ends itself, and revokes its relay session, when its stored login is marked `revoking` (the stop that missed it)
  X3  ... and when the login is gone (discarded, forgotten, deleted)
  X4  ... but not when the store merely cannot be read: an unreadable file is no reason to end a phone's session
  X5  a `--resume-only` client started BEFORE the mark / the forget never claims after it: it waits for the store lock, finds the login marked or
      gone, says resume_none and never attaches
  X6  (full stack, two phones) connect's resume and its periodic look skip a marked login; `--forget-local` concurrent with the look leaves nothing
      to resume; the SessionStart pair window skips a marked login -- no client ever attaches to a phone that was marked or forgotten
  X7  after `hmd app disconnect` returns NO process of the repo's connect survives -- no supervisor, respawned client, resume client or ui -- not even
      later, even when the connect's own client died a moment before (its supervisor was about to respawn it)
  X8  a SIGKILL of the laptop client mid-stream, with frames flowing: the supervisor resumes the SAME relay session (no re-pair), the phone keeps
      receiving, every seq after the kill is above every seq before it, and no (key, nonce) is reused
"""
import json
import os
import signal
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import app_pair_confirm_cases as C  # noqa: E402
import app_session_multi_cases as M  # noqa: E402
import app_session_resume_cases as H  # noqa: E402

LIB = os.path.join(H.ROOT, "bin", "lib")
sys.path.insert(0, LIB)
import hmd_session_login as L  # noqa: E402

PASS = FAIL = 0
APP_PATH = C.H.APP_PATH
HOLD = '''
import os, sys, time
sys.path.insert(0, sys.argv[1])
os.environ["HEIMDALL_HOME"] = sys.argv[2]
os.environ["HMD_SESSION_LOGIN_STORE"] = "file"
import hmd_session_login as L
root, sid, mode, hold = sys.argv[3], sys.argv[4], sys.argv[5], float(sys.argv[6])
with L._locked():
    print("held", flush=True)
    time.sleep(hold)
    if mode == "mark":
        acct = L.account(root, sid)
        L._write_meta(acct, dict(L._read_meta(acct), revoking=True))
    else:
        L._discard_unlocked(root, sid)
'''


def check(n, text, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
    print("  %s %s. %s" % ("ok  " if cond else "FAIL", n, text))


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def login_path(paths, sid):
    return next((p for p in paths if read_json(p).get("session_id") == sid), None)


def mark(root, sid):
    """What a disconnect does first: the login goes `revoking`, durably, under the store lock."""
    acct = L.account(root, sid)
    with L._locked():
        L._write_meta(acct, dict(L._read_meta(acct), revoking=True))


def scenario_mark_before_any_revoke():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = c2 = proc = None
    try:
        c1, sid1, _k1 = H.bind_phone(sb, relay, tag="c1")
        c2, sid2, _k2 = H.bind_phone(sb, relay, tag="c2")
        c1.stop(signal.SIGKILL)
        c2.stop(signal.SIGKILL)
        relay.revoke_delay = 8
        proc = subprocess.Popen([H.APP, "disconnect", "--repo", sb.repo], env=sb.env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def both_marked():
            paths = sb.logins()
            return len(paths) == 2 and all(read_json(p).get("revoking") is True for p in paths)

        # what is proved is the ORDER -- every login is marked while the first relay revoke is still in flight (it takes 8 s) -- not a stopwatch on
        # the disconnect's start (a few process starts: seconds on a loaded machine, and six scenarios now run at once): a disconnect that revokes first
        # is seen marked only after a revoke has returned, so `in_flight` fails it, whatever this bound is
        marked = H.wait_until(both_marked, 30.0, 0.1)
        in_flight = relay.revokes == []
        rc = proc.wait(120)
        check("X1", "`hmd app disconnect` marks EVERY stored login `revoking` within seconds -- before the first (slow) relay revoke has returned -- "
                    "so none is claimable while another is being revoked; then both are revoked",
              bool(marked) and in_flight and rc == 0 and set(relay.revokes) == {sid1, sid2} and not sb.logins())
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
        H.kill_leftovers(c1, c2)
        relay.close()
        sb.drop()


def scenario_client_guard():
    sb, relay = H.Sandbox(), H.Relay()
    os.environ.update(HEIMDALL_HOME=sb.hh, HMD_SESSION_LOGIN_STORE="file")
    env = {"HMD_SESSION_LOGIN_CHECK_S": "0.3"}
    c1 = c2 = c3 = None
    try:
        c1, sid1, _k1 = H.bind_phone(sb, relay, tag="c1", **env)
        mark(sb.repo, sid1)
        gone = H.wait_until(lambda: c1.proc.poll() is not None, 20)
        ended = c1.event("session_ended", 2) or {}
        check("X2", "a live client ends itself, and revokes its relay session, once its stored login is marked `revoking` (no signal sent)",
              bool(gone) and c1.proc.poll() == 0 and relay.sessions[sid1]["revoked"] and ended.get("reason") == "local-disconnect")
        c2, sid2, _k2 = H.bind_phone(sb, relay, tag="c2", **env)
        os.remove(login_path(sb.logins(), sid2))
        gone = H.wait_until(lambda: c2.proc.poll() is not None, 20)
        check("X3", "... and once its stored login is gone (discarded, forgotten, deleted): it ends and revokes, so no session is left that nobody can end",
              bool(gone) and c2.proc.poll() == 0 and relay.sessions[sid2]["revoked"])
        c3, sid3, _k3 = H.bind_phone(sb, relay, tag="c3", **env)
        path = login_path(sb.logins(), sid3)
        os.chmod(path, 0o644)  # a file that is not 0600 is never believed: the store cannot be read, which says nothing about the login
        time.sleep(3)
        alive = c3.proc.poll() is None and not relay.sessions[sid3]["revoked"]
        os.chmod(path, 0o600)
        rc = c3.stop(signal.SIGTERM)
        check("X4", "... but not when the store merely cannot be read (an unreadable login file): the client lives on, and a stop leaves its session open",
              alive and rc == 0 and not relay.sessions[sid3]["revoked"])
    finally:
        H.kill_leftovers(c1, c2, c3)
        relay.close()
        sb.drop()


def scenario_claim_rechecks():
    for mode, what in (("mark", "marked `revoking` by a disconnect"), ("delete", "deleted by `--forget-local`")):
        sb, relay = H.Sandbox(), H.Relay()
        c1 = c2 = holder = None
        try:
            c1, sid, _key = H.bind_phone(sb, relay)
            c1.stop(signal.SIGKILL)
            attaches = relay.attaches(sid)
            holder = subprocess.Popen([sys.executable, "-c", HOLD, LIB, sb.hh, sb.repo, sid, mode, "5"], stdout=subprocess.PIPE, text=True)
            holder.stdout.readline()  # "held": from here every writer and every claim waits for the store lock
            c2 = H.Client(sb, relay, "c2", resume_only=True)
            time.sleep(2.0)
            waiting = c2.proc.poll() is None and not any(e.get("event") in ("session_resumed", "resume_none") for e in c2.events())
            holder.wait(30)
            none = c2.event("resume_none", 30)
            H.wait_until(lambda: c2.proc.poll() is not None, 15)
            kept = sb.logins() if mode == "mark" else []
            check("X5", "a resume client started BEFORE the login is %s waits for the store lock, then finds it unclaimable: resume_none, exit 0, "
                        "never attached" % what,
                  waiting and none is not None and c2.proc.poll() == 0 and relay.attaches(sid) == attaches and relay.revokes == []
                  and len(sb.logins()) == len(kept))
        finally:
            if holder is not None and holder.poll() is None:
                holder.kill()
            H.kill_leftovers(c1, c2)
            relay.close()
            sb.drop()


def run_stack(s):
    sid_a, sid_b, _hmd_a, _hmd_b, phone_b = C.two_phones(s, M.KNOBS)
    ready = sid_a is not None and sid_b is not None and C.wait_until(lambda: len(C.device_pids(s)) == 2, 30)
    check("X6", "(setup) two phones are bound: the first by the pair window, the second by `hmd app add-device`", ready)
    if not ready:
        return
    os.environ.update(HEIMDALL_HOME=s.home, HMD_SESSION_LOGIN_STORE="file")
    id_a = C.device_fp(s.phone)
    opens = lambda sid: s.relay.get(sid).stream_opens  # noqa: E731

    # (1) a restart with the first phone's login marked `revoking`: connect's resume and its periodic look (every second) bring back only the second
    M.laptop_down(s)
    mark(s.repo, sid_a)
    before = {sid_a: opens(sid_a), sid_b: opens(sid_b)}
    rc, _pid = C.connect_bg(s, HMD_RESUME_RECONCILE_S="1")
    b_back = C.wait_until(lambda: opens(sid_b) > before[sid_b], 90)
    time.sleep(5)  # five looks
    kept = login_path([p for p, _d in M.logins(s)], sid_a)
    check("X6", "connect's resume and its periodic look skip a login marked `revoking`: the second phone is back, the first is never attached, its login "
                "stays marked", rc == 0 and b_back and opens(sid_a) == before[sid_a] and kept is not None
          and read_json(kept).get("revoking") is True and list(C.device_pids(s)) == ["iPhone 15"])

    # (2) `--forget-local` of the first phone while the relay refuses revokes and the look runs: nothing is left to resume, nothing comes back
    s.relay.revoke_status = 503
    done = C.run([APP_PATH, "disconnect", "--repo", s.repo, "--device", id_a, "--forget-local"], s.env(HMD_TAILSCALE_BIN="/usr/bin/false"), timeout=120)
    time.sleep(5)
    s.relay.revoke_status = None
    check("X6", "`--forget-local` of the first phone concurrent with the periodic look: its login is gone, no client ever attaches to it again, the "
                "second phone is untouched",
          done.returncode == 0 and login_path([p for p, _d in M.logins(s)], sid_a) is None and opens(sid_a) == before[sid_a]
          and sid_a not in s.relay.revokes and list(C.device_pids(s)) == ["iPhone 15"])

    # (3) the SessionStart pair window after another restart, the second phone's login marked: it does not come back either
    M.laptop_down(s)
    mark(s.repo, sid_b)
    mid = opens(sid_b)
    C.start_window(s, C.SID1, **M.KNOBS)
    time.sleep(8)
    kept_b = login_path([p for p, _d in M.logins(s)], sid_b)
    check("X6", "the SessionStart pair window skips a marked login: the second phone's session is never attached, its login stays marked, no phone's client runs",
          opens(sid_b) == mid and opens(sid_a) == before[sid_a] and not C.device_pids(s) and kept_b is not None
          and read_json(kept_b).get("revoking") is True)


def scenario_stack():
    with C.Scn() as s:
        try:
            run_stack(s)
        finally:
            M.laptop_down(s)


def settled_empty(s, within=6.0, still=6.0):
    """True when none of the scenario's own processes (those whose command line names its private temp directory: no other run has that name) is
    left within `within` seconds, and none shows up again during the next `still` seconds -- a leaked respawn appears later, not at once."""
    if not C.wait_until(lambda: not M.mine(s), within, 0.3):
        return False
    end = time.time() + still
    while time.time() < end:
        if M.mine(s):
            return False
        time.sleep(0.3)
    return True


def run_nothing_survives(s):
    sid_a, sid_b, _hmd_a, _hmd_b, _phone_b = C.two_phones(s, M.KNOBS)
    ready = sid_a is not None and sid_b is not None and C.wait_until(lambda: len(C.device_pids(s)) == 2, 30)
    check("X7", "(setup) two phones are bound", ready)
    if not ready:
        return
    M.laptop_down(s)
    before = {sid_a: s.relay.get(sid_a).stream_opens, sid_b: s.relay.get(sid_b).stream_opens}
    rc, pid = C.connect_bg(s, HMD_RESUME_RECONCILE_S="1", HMD_CONNECT_RESTART_S="1")
    back = C.wait_until(lambda: all(s.relay.get(sid).stream_opens > before[sid] for sid in before) and len(C.device_pids(s)) == 2, 90)
    check("X7", "(setup) `hmd app connect --bg` brought both phones back and left its supervisor behind", rc == 0 and back and bool(pid))
    if not (rc == 0 and back and pid):
        return
    # the connect's own client dies: its supervisor is now in its 1 s back-off, about to respawn it -- and the disconnect runs right then
    os.kill(pid, signal.SIGKILL)  # the exact client this connect run started
    done = C.run([APP_PATH, "disconnect", "--repo", s.repo], s.env(HMD_TAILSCALE_BIN="/usr/bin/false"), timeout=180)
    inits = len(s.relay.pair_inits)
    clean = settled_empty(s)
    check("X7", "after `hmd app disconnect` returns NO process of the repo's connect survives -- no supervisor, no respawned client, no resume client, "
                "no ui -- not even later, and nothing opens a new pairing session; both phones' sessions are revoked",
          done.returncode == 0 and clean and len(s.relay.pair_inits) == inits and {sid_a, sid_b} <= set(s.relay.revokes))


def scenario_nothing_survives():
    with C.Scn() as s:
        try:
            run_nothing_survives(s)
        finally:
            M.laptop_down(s)


class Driver:
    """The phone, sending a sealed `resync` command every 50 ms with a device seq that only ever goes up. hmd answers each with an ack (and a full
    state frame), so frames flow all the time -- also the moment the client is killed, and across the restart (what is sent while no client is
    attached waits in the relay's outbox for the next stream)."""

    def __init__(self, s, sid, key):
        self.s, self.sid, self.key = s, sid, key
        self.seq = 0
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def run(self):
        plain = json.dumps({"action": "resync", "params": {"last_seq": 0, "digest": "none", "caps": []}}).encode()
        while not self.stop.is_set():
            self.seq += 1
            nonce, ciphertext = C.E2E.seal(self.key, self.seq, "device", plain)
            env = {"v": 1, "session_id": self.sid, "seq": self.seq, "sender": "device", "type": "command", "nonce": nonce, "ciphertext": ciphertext}
            self.s.relay.get(self.sid).outbox.put(json.dumps(env, sort_keys=True, separators=(",", ":")))
            self.stop.wait(0.05)


def run_midstream_kill(s):
    rc, pid = C.connect_bg(s, HMD_SESSION_SEQ_RESERVE="8", HMD_CONNECT_RESTART_S="1")  # small seq blocks: the client rolls over many while it streams
    registered = C.wait_until(lambda: s.relay.registrations, 40)
    if not (rc == 0 and pid and registered):
        check("X8", "(setup) `hmd app connect --bg` offers the code", False)
        return
    sid = s.relay.registrations[-1]["session_id"]
    s.bind(sid, device_label="Pixel 9a")
    opened, hmd_pub = C.phone_state(s, s.phone, sid)
    check("X8", "(setup) the phone is bound and receiving", opened is not None)
    if opened is None:
        return
    key = C.E2E.derive_session_key(s.phone.priv, hmd_pub, sid)
    inits, regs = len(s.relay.pair_inits), len(s.relay.registrations)
    drive = Driver(s, sid, key)
    drive.start()
    try:
        flowing = C.wait_until(lambda: len(M.hmd_frames(s, sid)) >= 40, 60)
        os.kill(pid, signal.SIGKILL)  # the exact client this connect run started, with frames in flight
        time.sleep(0.5)               # what it had already posted lands
        sent = M.hmd_frames(s, sid)
        old_top, n_old = M.top_seq(sent), len(sent)
        stored = max([d.get("hmd_seq", 0) for _p, d in M.logins(s)] or [0])
        new_pid = C.new_client(s, pid, 60)
        back = C.wait_until(lambda: len(M.hmd_frames(s, sid)) >= n_old + 8, 90)
        time.sleep(1)
    finally:
        drive.stop.set()
    frames = M.hmd_frames(s, sid)
    new = frames[n_old:]
    check("X8", "a SIGKILL mid-stream leaves the stored seq high-water above every seq the dead client had sealed (%d frames, top seq %d, stored %d)"
          % (n_old, old_top, stored), flowing and stored > old_top)
    check("X8", "the supervisor resumes the SAME relay session: a new client serves it, the stream is attached again, no new pairing session, no code "
                "registered, nothing revoked or ended",
          new_pid not in (0, pid) and s.relay.get(sid).stream_opens >= 2 and len(s.relay.pair_inits) == inits and len(s.relay.registrations) == regs
          and sid not in s.relay.revokes and not s.relay.get(sid).ended)
    check("X8", "the phone keeps receiving: frames (acks too) from the new client open under the key it holds, and every one has a seq above everything "
                "the dead client sent -- a phone that accepts only a seq above its last accepts all of them (a jump is fine)",
          back and len(new) >= 8 and all(s.phone.open_hmd_frame(hmd_pub, sid, e) is not None for e in new)
          and any(e.get("type") == "ack" for e in new) and min(e["seq"] for e in new) > old_top)
    check("X8", "no message number or nonce is reused under the one key across the kill and the resume: no two different ciphertexts share a nonce or a seq",
          not M.repeated_nonces(frames) and len({e["seq"] for e in frames}) == len({(e["seq"], e["ciphertext"]) for e in frames}))


def scenario_midstream_kill():
    with C.Scn() as s:
        try:
            run_midstream_kill(s)
        finally:
            M.laptop_down(s)


# The scenarios share nothing: each has its own sandbox (HOME, repo, HEIMDALL_HOME), its own loopback relay on a port the OS hands out, its
# own processes (found by the name of its private temp directory) and its own clock -- and nearly all of their time goes to waiting (a slow
# relay, a store lock held, five looks of a supervisor). Run one after another they took 126 s; so with no scenario named, main() runs
# each in a process of its own, all six at once (pair_code_harness.report_children), and prints what each printed in the order they are
# declared, under one tally. A scenario whose process ends without a tally (killed, crashed) is one failed check that says so.
SCENARIOS = (scenario_mark_before_any_revoke, scenario_client_guard, scenario_claim_rechecks, scenario_stack, scenario_nothing_survives,
             scenario_midstream_kill)


def main():
    by_name = {run.__name__: run for run in SCENARIOS}
    wanted = sys.argv[1:]  # scenario names to run alone, here, one after another (a quick look while working on one); none runs them all
    unknown = [name for name in wanted if name not in by_name]
    if unknown:
        print("no such scenario: %s (scenarios: %s)" % (", ".join(unknown), ", ".join(by_name)), file=sys.stderr)
        return 2
    if not wanted:
        return C.H.report_children(C.H.Tally(), os.path.realpath(__file__), list(by_name))
    try:
        for name in wanted:
            try:
                by_name[name]()
            except Exception as e:  # a scenario that cannot run is a failed check, and the next still runs
                check("ERR", "%s raised %s: %s" % (name, type(e).__name__, e), False)
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

#!/usr/bin/env python3
"""test/lib/app_session_multi_cases.py -- every phone paired to a repo comes back by itself after its client is gone (operator decision, 2.4.8).

A relay session binds ONE phone, so a repo with two phones (the first by the pair window, the second by `hmd app add-device`) runs two relay
clients, and each stores the login of its own session. When the laptop restarts nothing is left running; `hmd app connect` (or the
SessionStart pair window) must start one client per stored login, each resuming ITS phone's session -- with its own seq blocks and under the
store lock -- and no phone may be asked to pair again. Real bin/heimdall-app, bin/heimdall-relay-client and the SessionStart hook against
test/lib/fake_relay_code.py; the processes killed are this scenario's own (those whose command line names its private temp directory).
  P1  setup: two phones bound, a client and a stored login each
  P2  everything is killed (SIGKILL: nothing revokes), then `hmd app connect`: BOTH phones resume on their own relay sessions -- both streams
      are attached again, both `session_resumed`, no new pairing session, nothing revoked or ended
  P3  both phones get frames from the new clients, each opens under the key its phone already holds, seqs above everything sent before
  P4  no (key, nonce) pair repeats across the restart, on either session
  P5  the SessionStart hook's pair window alone does the same after another restart
  P6  the resume limit applies per phone: past HMD_SESSION_RESUME_H one phone's login is discarded and it is NOT resumed, the other is
"""
import glob
import json
import os
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import app_pair_confirm_cases as C  # noqa: E402
import pair_code_harness as H  # noqa: E402

T = C.T
KNOBS = {"HMD_PAIR_WINDOW_POLL_S": "0.2", "HMD_PAIR_WINDOW_IDLE_H": "0"}
_plain_env = H.Sandbox.env


def _file_store_env(self, **extra):
    """The stored login goes to a file under the sandbox's HEIMDALL_HOME, never into the machine's Keychain."""
    return _plain_env(self, **dict({"HMD_SESSION_LOGIN_STORE": "file"}, **extra))


H.Sandbox.env = _file_store_env


def running(pid):
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(out) and not out.startswith("Z")


def mine(s):
    """The pids of this scenario's own live processes: every one whose command line names its private temp directory (a name no other run has)."""
    token = os.path.basename(s.sb.root)
    out = subprocess.run(["ps", "-axww", "-o", "pid=,stat=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and not parts[1].startswith("Z") and token in parts[2] and int(parts[0]) != os.getpid() \
                and not parts[2].startswith("ps "):
            found.append(int(parts[0]))
    return found


def laptop_down(s):
    """The laptop restarts: the window's supervisor, connect's watcher and ui and every client die at once (KILL: nothing revokes)."""
    pids = mine(s)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            continue
    C.wait_until(lambda: not any(running(p) for p in pids), 20)


def logins(s):
    found = []
    for path in sorted(glob.glob(os.path.join(s.home, "app", "sessions", "*.json"))):
        with open(path, encoding="utf-8") as f:
            found.append((path, json.load(f)))
    return found


def hmd_frames(s, sid):
    return [e for e in s.relay.frames_of(sid) if e.get("sender") == "hmd" and e.get("nonce")]


def top_seq(frames):
    return max([e["seq"] for e in frames] or [0])


def repeated_nonces(frames):
    """The nonces that sealed two DIFFERENT ciphertexts (a byte-identical repeat is a retry of one frame, not a reuse)."""
    seen, bad = {}, []
    for e in frames:
        if seen.setdefault(e["nonce"], e["ciphertext"]) != e["ciphertext"]:
            bad.append(e["nonce"])
    return bad


def snap(s, phones):
    return {sid: {"opens": s.relay.get(sid).stream_opens, "n": len(hmd_frames(s, sid)), "top": top_seq(hmd_frames(s, sid))} for sid in phones}


def back_up(s, before, expect, timeout=90):
    """True once every session in `expect` is attached again and has sent frames since `before`, and that many clients serve phones."""
    return C.wait_until(lambda: all(s.relay.get(sid).stream_opens > before[sid]["opens"] and len(hmd_frames(s, sid)) > before[sid]["n"]
                                    for sid in expect) and len(C.device_pids(s)) == len(expect), timeout)


def opens_above(s, phones, before, expect):
    """Every frame sent since `before` opens under the key its phone already holds, and its seq is above everything sent before."""
    for sid in expect:
        phone, hmd_pub, _label = phones[sid]
        new = hmd_frames(s, sid)[before[sid]["n"]:]
        if not new or any(phone.open_hmd_frame(hmd_pub, sid, e) is None for e in new) or min(e["seq"] for e in new) <= before[sid]["top"]:
            return False
    return True


def nonce_clean(s, phones, expect):
    return all(not repeated_nonces(hmd_frames(s, sid)) for sid in expect)


def untouched(s, phones):
    """No phone's relay session was revoked or ended (the pair window's own, unclaimed windows are revoked and renewed as ever)."""
    return not (set(s.relay.revokes) & set(phones)) and not any(s.relay.get(sid).ended for sid in phones)


def run(s):
    sid_a, sid_b, hmd_a, hmd_b, phone_b = C.two_phones(s, KNOBS)
    ready = sid_a is not None and sid_b is not None and C.wait_until(lambda: len(C.device_pids(s)) == 2, 30)
    stored = logins(s)
    T.check(ready and len(stored) == 2 and {d["session_id"] for _p, d in stored} == {sid_a, sid_b},
            "P1. (setup) two phones are bound -- the first by the pair window, the second by `hmd app add-device` -- each with a client and a stored login of its own",
            "sids %r %r logins %r pids %r" % (sid_a, sid_b, [d.get("session_id") for _p, d in stored], C.device_pids(s)))
    if not ready or len(stored) != 2:
        return
    phones = {sid_a: (s.phone, hmd_a, "Pixel 9a"), sid_b: (phone_b, hmd_b, "iPhone 15")}
    both = list(phones)
    before = snap(s, phones)
    inits, regs = len(s.relay.pair_inits), len(s.relay.registrations)

    laptop_down(s)
    down = not C.device_pids(s)
    rc, _pid = C.connect_bg(s)
    back = back_up(s, before, both)
    resumed = {e.get("session_id") for e in C.connect_events(s, "session_resumed")}
    T.check(down and rc == 0 and back and resumed == set(both) and len(s.relay.pair_inits) == inits and len(s.relay.registrations) == regs
            and untouched(s, phones),
            "P2. after every client is killed, `hmd app connect` resumes BOTH phones on their own relay sessions: both streams attached again, both `session_resumed`, "
            "no pairing session or code registered, nothing revoked or ended",
            "down %s rc %r back %s resumed %r inits %d->%d regs %d->%d revokes %r devices %r" % (
                down, rc, back, sorted(resumed), inits, len(s.relay.pair_inits), regs, len(s.relay.registrations), s.relay.revokes, C.device_pids(s)))
    T.check(opens_above(s, phones, before, both),
            "P3. both phones receive frames from the new clients: each opens under the key its phone already holds, with seqs above everything sent before", "")
    T.check(nonce_clean(s, phones, both), "P4. no (key, nonce) pair repeats across the restart on either session", "")

    mid = snap(s, phones)
    laptop_down(s)
    C.start_window(s, C.SID1, **KNOBS)
    back = back_up(s, mid, both)
    T.check(back and untouched(s, phones) and opens_above(s, phones, mid, both) and nonce_clean(s, phones, both),
            "P5. the SessionStart hook's pair window alone brings both phones back after another restart: sessions re-attached, frames open under the held keys, no nonce repeats",
            "back %s revokes %r devices %r" % (back, s.relay.revokes, C.device_pids(s)))

    mid = snap(s, phones)
    laptop_down(s)
    path_a = next((p for p, d in logins(s) if d.get("device_id") == C.device_fp(s.phone)), None)
    if path_a is None:
        T.check(False, "P6. (setup) the first phone's stored login is there", "")
        return
    with open(path_a, encoding="utf-8") as f:
        meta = json.load(f)
    meta["last_alive"] = int(time.time()) - 3 * 3600
    with open(path_a, "w", encoding="utf-8") as f:
        json.dump(meta, f)
    rc, _pid = C.connect_bg(s, HMD_SESSION_RESUME_H="1")
    b_back = C.wait_until(lambda: s.relay.get(sid_b).stream_opens > mid[sid_b]["opens"] and len(hmd_frames(s, sid_b)) > mid[sid_b]["n"], 90)
    time.sleep(4)
    T.check(rc == 0 and b_back and s.relay.get(sid_a).stream_opens == mid[sid_a]["opens"] and list(C.device_pids(s)) == ["iPhone 15"]
            and [d["session_id"] for _p, d in logins(s)] == [sid_b] and untouched(s, phones) and opens_above(s, phones, mid, [sid_b]),
            "P6. the resume limit applies per phone: the first phone's login, past HMD_SESSION_RESUME_H, is discarded and NOT resumed; the second's is, and its frames flow",
            "rc %r b_back %s opens_a %d->%d devices %r logins %r" % (rc, b_back, mid[sid_a]["opens"], s.relay.get(sid_a).stream_opens,
                                                                  C.device_pids(s), [d.get("session_id") for _p, d in logins(s)]))


def main():
    try:
        with C.Scn() as s:
            try:
                run(s)
            finally:
                laptop_down(s)
    except Exception as exc:  # a scenario that dies is a failed check, not a crash of the run
        T.check(False, "the scenario raised %s: %s" % (type(exc).__name__, exc))
    return T.finish()


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""test/lib/app_session_nonce_cases.py -- a resumed relay client must never seal two frames under one key with one nonce.

A frame's nonce is nothing but sender tag || seq (hmd_relay_e2e.nonce_for_seq), so a nonce repeats exactly when a seq does. A client
that is killed and resumed starts again from what its stored login says; if the login lags what the dead client had already sealed,
the resumed one seals different plaintexts under the same (key, nonce) -- the break of a stream cipher's confidentiality and of its
integrity. The stored login therefore hands out seq BLOCKS, durably, BEFORE a client seals anything in them (write-ahead), the client
seals nothing outside a block it holds (and so nothing when the store cannot be written), and a resume starts above everything ever
handed out. The phone needs only a seq above the last it accepted (INV-14; no gap rule in relay/contract/wire.json), so jumps are fine.
  N1  SIGKILL mid-stream: the stored high-water is above every seq the dead client sealed
  N2  the resumed client's frames: no nonce repeats unless the frame is byte-identical (a retry), all seqs above the dead client's, and
      the phone opens every frame of both under the one key it holds
  N3  the store cannot be written: the client seals nothing at or above the high-water it last persisted
  N4  once the store can be written again the client reserves the next block and goes on, never past the new high-water
"""
import glob
import json
import os
import signal
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import app_session_resume_cases as H  # noqa: E402

E2E = H.E2E
PASS = FAIL = 0


def check(n, text, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
    print("  %s %s. %s" % ("ok  " if cond else "FAIL", n, text))


def command(sid, key, seq):
    """A sealed `resync` of the fake phone: every one is answered with an ack, and most with a state frame too."""
    plain = json.dumps({"action": "resync", "params": {"last_seq": 0, "digest": "none", "caps": []}}).encode()
    nonce, ciphertext = E2E.seal(key, seq, "device", plain)
    return {"v": 1, "session_id": sid, "seq": seq, "sender": "device", "type": "command", "nonce": nonce,
            "ciphertext": ciphertext, "payload": None}


def drive(relay, sid, key, first, count, pause=0.005):
    for seq in range(first, first + count):
        relay.push(sid, command(sid, key, seq))
        time.sleep(pause)
    return first + count


def hmd_frames(relay, sid):
    with relay.lock:
        return [dict(f) for f in relay.sessions[sid]["frames"] if f.get("sender") == "hmd"]


def top_seq(relay, sid):
    return max([f["seq"] for f in hmd_frames(relay, sid)] or [0])


def reused(frames):
    """The nonces that sealed two DIFFERENT ciphertexts (a byte-identical repeat is a retry of one frame, not a reuse)."""
    seen, bad = {}, []
    for f in frames:
        if seen.setdefault(f["nonce"], f["ciphertext"]) != f["ciphertext"]:
            bad.append(f["nonce"])
    return bad


def stored_high_water(sb, where=None):
    paths = glob.glob(os.path.join(where or os.path.join(sb.hh, "app", "sessions"), "*.json"))
    with open(paths[0], encoding="utf-8") as f:
        return json.load(f)["hmd_seq"]


def scenario_kill_and_resume():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = c2 = None
    env = {"HMD_SESSION_SEQ_RESERVE": "8"}
    try:
        c1, sid, key = H.bind_phone(sb, relay, **env)
        nxt = drive(relay, sid, key, 1, 12)
        H.wait_until(lambda: len(hmd_frames(relay, sid)) >= 20, 30)
        nxt = drive(relay, sid, key, nxt, 5, pause=0.01)
        c1.stop(signal.SIGKILL)
        old = hmd_frames(relay, sid)
        old_top = max(f["seq"] for f in old)
        check("N1", "SIGKILL mid-stream: the stored high-water is above every seq the dead client sealed (%d frames, top seq %d, stored %d)"
              % (len(old), old_top, stored_high_water(sb)), stored_high_water(sb) > old_top)
        c2 = H.Client(sb, relay, "c2", resume=True, **env)
        resumed = c2.event("session_resumed")
        nxt = drive(relay, sid, key, nxt, 10, pause=0.02)
        H.wait_until(lambda: top_seq(relay, sid) > old_top + 4, 30)
        every = hmd_frames(relay, sid)
        new = [f for f in every if f["seq"] > old_top]
        opened = []
        for f in every:
            try:
                opened.append(H.open_frame(key, f))
            except Exception:  # a frame that does not open under the phone's key is a failed check, not a crash
                opened.append(None)
        check("N2", "resumed: no (key, nonce) pair repeats, every new seq is above the dead client's, and the phone opens every frame "
                    "of both clients under its one key", resumed is not None and not reused(every) and len(new) >= 3
              and all(f["seq"] > old_top for f in new if f not in old) and all(o is not None for o in opened))
        c2.stop(signal.SIGTERM)
    finally:
        H.kill_leftovers(c1, c2)
        relay.close()
        sb.drop()


def scenario_store_unwritable():
    sb, relay = H.Sandbox(), H.Relay()
    c1 = None
    try:
        c1, sid, key = H.bind_phone(sb, relay)
        sessions = os.path.join(sb.hh, "app", "sessions")
        moved = sessions + ".moved"
        os.rename(sessions, moved)
        os.symlink(moved, sessions)  # a link is never followed: every write to the store is refused
        nxt = drive(relay, sid, key, 1, 1300, pause=0.002)
        time.sleep(2)
        high = stored_high_water(sb, moved)
        top = top_seq(relay, sid)
        check("N3", "the store cannot be written: the client seals nothing at or above the high-water it last persisted (top seq %d, "
                    "persisted %d)" % (top, high), 0 < top < high and not reused(hmd_frames(relay, sid)))
        os.remove(sessions)
        os.rename(moved, sessions)
        drive(relay, sid, key, nxt, 12, pause=0.05)
        H.wait_until(lambda: top_seq(relay, sid) >= high, 30)
        time.sleep(1)
        high2, top2 = stored_high_water(sb), top_seq(relay, sid)
        check("N4", "the store is writable again: the client reserves the next block and goes on, never past the new high-water (top "
                    "seq %d, persisted %d)" % (top2, high2), high <= top2 < high2 and not reused(hmd_frames(relay, sid)))
        c1.stop(signal.SIGTERM)
    finally:
        H.kill_leftovers(c1)
        relay.close()
        sb.drop()


def main():
    try:
        for run in (scenario_kill_and_resume, scenario_store_unwritable):
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

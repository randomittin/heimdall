#!/usr/bin/env python3
"""test/lib/app_session_survives_cases.py -- a paired phone must never drop because Claude Code ends, restarts, resumes or sits idle (2.4.8).

Operator requirement: "a paired session must never drop because the Claude Code session ends, restarts, resumes or goes idle. The same code and
relay session come back. No idle shutdown by default. Only hmd app disconnect, a revoke from the phone or a failed login ends a session."

Real bin/heimdall-app, bin/heimdall-relay-client, bin/lib/hmd_session_login.py and the REAL SessionStart / SessionEnd / Stop hooks from
hooks/hooks.json (run through `sh -c`, the way Claude Code runs them), against test/lib/fake_relay_code.py and a fake phone that holds its own
key. "Claude Code" is a process whose pid the SessionStart hook records for the session (Claude below) and that the test kills when the session
ends. HOME, HEIMDALL_HOME, repo and `gh` are throwaway and HMD_SESSION_LOGIN_STORE=file: never the real Keychain, and only processes this
scenario started are ever signalled (those whose command line names its private temp directory, or the pids it was handed).
  S1  a phone paired by the window's code: its client runs, its login is stored, and the repo's pairing record (HEIMDALL_HOME/app/repos) holds the
      code it was paired under and its relay session id
  S2  the Stop hook of a turn leaves it alone; the session ENDS (its process dies, then the SessionEnd hook runs): the same supervisor and the same
      client still run, nothing is revoked or ended, the login stays, the supervisor says it is holding the phone, and the phone still gets frames
      (acks to its commands, strictly increasing seq)
  S3  five hours of idle time (the old window's limit was four; no HMD_PAIR_WINDOW_IDLE_H is set): nothing stops, the phone still gets frames --
      and with NO phone paired either, a thousand idle hours leave the window open: the default is no idle stop
  S4  a new Claude Code session resumes (the real SessionStart hook): the SAME code is registered and shown, the SAME relay session and client carry
      on with no /pair/init, the pairing record is unchanged, and the code is the stored one -- not a re-derivation: deleting the machine's seed
      does not move it; and when the phone's client is then KILLED the supervisor brings the phone back at once, on the same relay session
  S5  the Claude session AND every process die (a restart of the laptop), the stored login is three days old (the old limit was 24 hours), gh is
      signed out: a new session's SessionStart hook still resumes the SAME relay session -- no /pair/init, no code registered, no token sent, the
      phone opens the new client's frames under the key it already holds, seqs above everything sent before, no nonce repeated
  S6  `hmd app disconnect` ends it: the relay session is revoked, the login and the pairing record go, the client and the supervisor end
  S7  a revoke from the phone ends it: the client ends, the login and the pairing record go, and the app log says the relay ended the session
  S8  no hook of SessionEnd or Stop but pair-window-stop touches a relay client, a window or a disconnect
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import app_pair_confirm_cases as C  # noqa: E402
import app_session_multi_cases as M  # noqa: E402
import pair_code_harness as H  # noqa: E402

T = C.T
REPO = H.REPO
LOGIN_PY = os.path.join(REPO, "bin", "lib", "hmd_session_login.py")
SID3 = "9d2d4f50-3333-4444-8555-666677778888"
KNOBS = {"HMD_PAIR_WINDOW_POLL_S": "0.2", "HMD_RESUME_RECONCILE_S": "1", "HMD_RELAY_STOP_TIMEOUT_S": "10"}
LABEL = "Pixel 9a"


def hook_command(ident):
    """The command of the hook hooks.metadata.json calls `ident`, as hooks.json carries it."""
    with open(C.HOOKS_JSON, encoding="utf-8") as f:
        hooks = json.load(f)["hooks"]
    with open(C.HOOKS_META, encoding="utf-8") as f:
        ids = {(e["event"], e["index"]): e["id"] for e in json.load(f)["hooks"]}
    for event, groups in hooks.items():
        for index, group in enumerate(groups):
            if ids.get((event, index)) == ident:
                return group["hooks"][0]["command"]
    raise KeyError(ident)


class Claude:
    """Claude Code, as far as the hooks can tell: a process -- its pid is what the SessionStart hook records for the session -- that runs the
    real SessionStart hook with the session's id on stdin as it starts, and is killed when the session ends."""

    def __init__(self, s, sid, source="startup", **env):
        self.s, self.sid = s, sid
        payload = os.path.join(s.sb.root, "payload-%s.json" % sid)
        with open(payload, "w", encoding="utf-8") as f:
            json.dump({"session_id": sid, "source": source}, f)
        full = s.env(CLAUDE_PLUGIN_ROOT=REPO, CLAUDE_PROJECT_DIR=s.repo, HMD_TEST_HOOK=hook_command("pair-window-start"), HMD_TEST_PAYLOAD=payload,
                     **env)
        # the hook's $PPID is this outer shell, which then becomes the sleep: the one process the session's record names
        self.proc = subprocess.Popen(["sh", "-c", 'sh -c "$HMD_TEST_HOOK" < "$HMD_TEST_PAYLOAD"; exec sleep 3600'], env=full, cwd=s.repo,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.pid = self.proc.pid

    def recorded(self, timeout=30):
        return C.wait_until(lambda: (self.s.session_record(self.sid) or {}).get("pid") == self.pid, timeout)

    def stop_hook(self):
        """The Stop hook that touches the phone's inbox, at the end of a turn."""
        env = self.s.env(CLAUDE_PLUGIN_ROOT=REPO, CLAUDE_PROJECT_DIR=self.s.repo, HMD_INBOX_WAIT_S="0")
        return C.run(["sh", "-c", hook_command("inbox-deliver-stop")], env, stdin=json.dumps({"session_id": self.sid}), timeout=90, cwd=self.s.repo)

    def end(self, **env):
        """The session ends: its process dies, then the SessionEnd hook runs, as Claude Code runs it on its way out."""
        self.proc.kill()
        self.proc.wait()
        return self.s.hook("pair-window-stop", self.sid, **env)

    def gone(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


def code_now(s):
    return C.code_cli(s.env(), "--repo", s.repo)[1]


def show(s):
    """(exit code, the repo's pairing record) as `hmd_session_login.py show` prints it."""
    p = C.run([sys.executable, LOGIN_PY, "show", "--repo", s.repo], s.env(), timeout=60)
    try:
        return p.returncode, json.loads(p.stdout)
    except ValueError:
        return p.returncode, {}


def app_log(s):
    try:
        with open(os.path.join(s.home, "logs", "app.log"), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def session_ids(s):
    return [d["session_id"] for _p, d in M.logins(s)]


def untouched(s, sid):
    return sid not in s.relay.revokes and not s.relay.get(sid).ended


def pair_phone(s, claude, label=LABEL):
    """Claude's session starts, its window offers the repo's code, and the phone claims it: a dict with everything the cases look at again -- or None
    after a failed check (the setup is a check too)."""
    if not claude.recorded():
        T.check(False, "(setup) the SessionStart hook records the session and opens the window", s.relay.requests[-3:])
        return None
    code = s.window_code()
    sup = C.window_pid(s)
    sid = s.relay.latest().id if code else None
    if not (code and isinstance(sup, int) and sid):
        T.check(False, "(setup) the window registers the repo's code", "code %r supervisor %r" % (code, sup))
        return None
    s.bind(sid, device_label=label)
    _opened, hmd_pub = s.paired_state(sid)
    ready = hmd_pub and C.wait_until(lambda: C.device_pids(s).get(label) and len(M.logins(s)) == 1 and show(s)[0] == 0, 30)
    if not ready:
        T.check(False, "(setup) the phone pairs: a client serves it, its login and the repo's pairing record are stored", "devices %r" % C.device_pids(s))
        return None
    return {"code": code, "sup": sup, "sid": sid, "hmd_pub": hmd_pub, "client": C.device_pids(s)[label], "label": label, "inits": len(s.relay.pair_inits),
            "phones": {sid: (s.phone, hmd_pub, label)}}


def settle(s, secs=2.5):
    time.sleep(secs)


def case_session_end_restart_idle():
    """S1 - S4."""
    with C.Scn() as s:
        clock = C.Clock(s.sb.root)
        knobs = dict(KNOBS, HMD_PAIR_WINDOW_NOW_FILE=clock.path)  # the supervisor's clock moves by rewriting a file; no HMD_PAIR_WINDOW_IDLE_H is set
        a = Claude(s, C.SID1, **knobs)
        b = None
        try:
            p = pair_phone(s, a)
            if p is None:
                return
            sid, phones = p["sid"], p["phones"]
            rec = show(s)[1]
            stored = M.logins(s)
            T.check(rec.get("code") == p["code"] == code_now(s) and [x.get("session_id") for x in rec.get("sessions", [])] == [sid]
                    and session_ids(s) == [sid] and C.mode_of(stored[0][0]) == 0o600 and rec.get("repo") == os.path.realpath(s.repo),
                    "S1. a phone paired by the window's code has a client, a stored login and a pairing record in HEIMDALL_HOME (0600 login) holding the "
                    "code it was paired under and its relay session id",
                    "record %s code %s window code %s logins %s" % (json.dumps(rec)[:200], code_now(s), p["code"], session_ids(s)))

            turn = a.stop_hook()
            before = M.snap(s, phones)
            ended = a.end(**knobs)
            held = C.wait_until(lambda: (s.window_state() or {}).get("state") == "holding", 25)
            T.check(turn.returncode == 0 and ended.returncode == 0 and s.session_record(C.SID1) is None and C.alive(p["sup"]) and C.alive(p["client"])
                    and C.device_pids(s).get(LABEL) == p["client"] and untouched(s, sid) and session_ids(s) == [sid] and bool(held),
                    "S2. the Stop hook and then the session's end (the SessionEnd hook) leave the SAME supervisor and the SAME client running: nothing is "
                    "revoked or ended, the login stays, and the supervisor says it is holding the phone",
                    "stop rc %r end rc %r supervisor %s client %s revokes %r state %r" % (turn.returncode, ended.returncode, C.alive(p["sup"]),
                                                                                         C.alive(p["client"]), s.relay.revokes, s.window_state()))
            ack = C.phone_says(s, s.phone, p["hmd_pub"], sid, 1, "still here with no Claude session")
            T.check(ack is not None and M.opens_above(s, phones, before, [sid]),
                    "S2. ...and with no Claude session at all the phone still gets frames: its command is acked, the ack opens under the key it holds and "
                    "its seq is above everything sent before", "ack %r" % (ack,))

            before = M.snap(s, phones)
            clock.set(5 * 3600)
            settle(s)
            ack = C.phone_says(s, s.phone, p["hmd_pub"], sid, 2, "still here after five idle hours")
            T.check(C.alive(p["sup"]) and C.alive(p["client"]) and untouched(s, sid) and session_ids(s) == [sid] and ack is not None
                    and M.opens_above(s, phones, before, [sid]),
                    "S3. five idle hours later (the old limit was four; no idle bound is set) the supervisor and the client are alive, nothing is revoked, "
                    "and the phone still gets frames",
                    "supervisor %s client %s revokes %r ack %r" % (C.alive(p["sup"]), C.alive(p["client"]), s.relay.revokes, ack))

            regs, before = len(s.relay.registrations), M.snap(s, phones)
            b = Claude(s, C.SID2, source="resume", **knobs)
            resumed = b.recorded()
            running = C.wait_until(lambda: (s.window_state() or {}).get("state") == "running", 25)
            rec2 = show(s)[1]
            T.check(resumed and running and C.window_pid(s) == p["sup"] and C.alive(p["client"]) and code_now(s) == p["code"]
                    and rec2.get("code") == p["code"] and [x.get("session_id") for x in rec2.get("sessions", [])] == [sid]
                    and len(s.relay.pair_inits) == p["inits"] and len(s.relay.registrations) == regs and untouched(s, sid),
                    "S4. a new session of the repo (claude --resume): the SAME code, the SAME pairing record and relay session; the very supervisor and client "
                    "carry on (no /pair/init, no second registration of the code), and the supervisor is no longer only holding",
                    "running %r code %r/%r record %s inits %d->%d regs %d->%d" % (running, code_now(s), p["code"], json.dumps(rec2)[:160], p["inits"],
                                                                                   len(s.relay.pair_inits), regs, len(s.relay.registrations)))
            ack = C.phone_says(s, s.phone, p["hmd_pub"], sid, 3, "still here after the resume")
            T.check(ack is not None and M.opens_above(s, phones, before, [sid]) and not M.repeated_nonces(M.hmd_frames(s, sid)),
                    "S4. ...and the phone keeps receiving: its next command is acked, strictly above everything sent before, and no nonce repeats",
                    "ack %r" % (ack,))
            seed = os.path.join(s.home, "session-code.key")
            had = os.path.exists(seed)
            if had:
                os.remove(seed)
            T.check(had and code_now(s) == p["code"],
                    "S4. the code is the STORED one, not a re-derivation: with the machine's seed deleted (a new one would give another code) the repo "
                    "still shows the code its phone was paired under", "seed existed %r code %r want %r" % (had, code_now(s), p["code"]))
            log = app_log(s)
            T.check("SessionEnd of Claude session" in log and "stay paired" in log and "nothing is revoked" in log,
                    "S4. the app log says what the SessionEnd hook did: the phone stayed paired, nothing was revoked", log[-300:])

            before = M.snap(s, phones)
            os.kill(p["client"], signal.SIGKILL)  # the phone's client dies (a stray kill, a crash) -- a pid this scenario started
            back = C.wait_until(lambda: C.device_pids(s).get(LABEL) not in (None, p["client"]) and s.relay.get(sid).stream_opens > before[sid]["opens"]
                                and len(M.hmd_frames(s, sid)) > before[sid]["n"], 60)
            T.check(back and untouched(s, sid) and session_ids(s) == [sid] and len(s.relay.pair_inits) == p["inits"]
                    and M.opens_above(s, phones, before, [sid]) and not M.repeated_nonces(M.hmd_frames(s, sid)),
                    "S4. the phone's client is KILLED: the supervisor brings the phone back at once (well inside the window's 5-minute retry delay) on the SAME "
                    "relay session -- a new client, no /pair/init, frames that open under the held key above everything sent, no nonce repeated",
                    "back %r revokes %r devices %r inits %d->%d" % (back, s.relay.revokes, C.device_pids(s), p["inits"], len(s.relay.pair_inits)))
        finally:
            a.gone()
            if b is not None:
                b.gone()
            M.laptop_down(s)


def case_default_never_idles():
    """S3b."""
    with C.Scn() as s:
        clock = C.Clock(s.sb.root)
        a = Claude(s, C.SID1, **dict(KNOBS, HMD_PAIR_WINDOW_NOW_FILE=clock.path))  # no HMD_PAIR_WINDOW_IDLE_H: the default
        try:
            code = s.window_code() if a.recorded() else None
            sup = C.window_pid(s) if code else None
            if not isinstance(sup, int):
                T.check(False, "(setup) the window opens and registers its code", "code %r" % (code,))
                return
            clock.set(1000 * 3600)
            settle(s, 3.0)
            T.check(C.alive(sup) and s.window_state() is not None and len(s.relay.registrations) == 1 and s.relay.latest().id not in s.relay.revokes,
                    "S3. with NO phone paired either, a thousand hours with no pairing and no activity leave the window open and its session unrevoked: "
                    "the default is no idle stop (HMD_PAIR_WINDOW_IDLE_H above 0 is the operator's opt-in)",
                    "alive %r state %r registrations %d" % (C.alive(sup), s.window_state(), len(s.relay.registrations)))
        finally:
            a.gone()
            M.laptop_down(s)


def case_laptop_restart_gh_signed_out():
    """S5."""
    with C.Scn() as s:
        a = Claude(s, C.SID1, **KNOBS)
        c = None
        try:
            p = pair_phone(s, a)
            if p is None:
                return
            sid, phones = p["sid"], p["phones"]
            ack = C.phone_says(s, s.phone, p["hmd_pub"], sid, 1, "before the restart")
            a.end(**KNOBS)
            M.laptop_down(s)  # the laptop restarts: the supervisor and the client die at once (KILL: nothing revokes)
            down = not C.device_pids(s) and not C.alive(p["client"])
            stored = M.logins(s)
            if len(stored) != 1:
                T.check(False, "(setup) one stored login survives the restart", "logins %r" % session_ids(s))
                return
            path, meta = stored[0]
            meta["last_alive"] = int(time.time()) - 3 * 24 * 3600  # the client was last alive three days ago: past the old 24-hour limit
            with open(path, "w", encoding="utf-8") as f:
                json.dump(meta, f)
            C.write_gh(s.sb.bin, "signed-out")  # and gh is signed out when the next session starts
            before, regs = M.snap(s, phones), len(s.relay.registrations)
            c = Claude(s, SID3, source="resume", **KNOBS)
            recorded = c.recorded()
            back = C.wait_until(lambda: s.relay.get(sid).stream_opens > before[sid]["opens"] and len(M.hmd_frames(s, sid)) > before[sid]["n"]
                                and C.device_pids(s).get(LABEL), 90)
            sup = C.window_pid(s)
            holding = C.wait_until(lambda: (s.window_state() or {}).get("state") == "holding", 25)
            rec = show(s)[1]
            T.check(ack is not None and down and recorded and back and untouched(s, sid) and len(s.relay.pair_inits) == p["inits"]
                    and len(s.relay.registrations) == regs and session_ids(s) == [sid] and [x.get("session_id") for x in rec.get("sessions", [])] == [sid]
                    and code_now(s) == p["code"] and rec.get("code") == p["code"],
                    "S5. everything died and the stored login is three days old (past the old 24-hour limit), gh is signed out: the new session's SessionStart "
                    "hook resumes the SAME relay session -- its stream is attached again, no /pair/init, no code registered, no token sent, the same login, "
                    "pairing record and code",
                    "recorded %r back %r revokes %r inits %d->%d regs %d->%d logins %s" % (recorded, back, s.relay.revokes, p["inits"], len(s.relay.pair_inits),
                                                                                         regs, len(s.relay.registrations), session_ids(s)))
            T.check(M.opens_above(s, phones, before, [sid]) and M.nonce_clean(s, phones, [sid]),
                    "S5. the phone opens the new client's frames under the key it already holds, with seqs above everything sent before, and no (key, nonce) "
                    "pair repeats across the restart", "")
            ack = C.phone_says(s, s.phone, p["hmd_pub"], sid, 2, "after the restart") if back else None
            T.check(isinstance(sup, int) and C.alive(sup) and bool(holding) and ack is not None,
                    "S5. a supervisor runs with gh signed out: it holds the phone (state `holding`, no code offered), and the phone's command is acked",
                    "supervisor %r holding %r ack %r" % (sup, holding, ack))
        finally:
            a.gone()
            if c is not None:
                c.gone()
            M.laptop_down(s)


def case_disconnect_ends_it():
    """S6."""
    with C.Scn() as s:
        a = Claude(s, C.SID1, **KNOBS)
        try:
            p = pair_phone(s, a)
            if p is None:
                return
            sid = p["sid"]
            out = C.run([H.APP_PATH, "disconnect", "--repo", s.repo], s.env(HMD_TAILSCALE_BIN="/usr/bin/false"), timeout=120)
            gone = C.wait_until(lambda: not C.alive(p["client"]) and not C.alive(p["sup"]), 30)
            rc, _rec = show(s)
            T.check(sid in s.relay.revokes and not M.logins(s) and rc == 3 and bool(gone) and "hmd app disconnect" in app_log(s),
                    "S6. `hmd app disconnect` ends the pairing: the relay session is revoked, the stored login and the pairing record are gone, the client "
                    "and the supervisor end, and the app log says it was the disconnect",
                    "rc %r revokes %r logins %r show rc %r gone %r %s" % (out.returncode, s.relay.revokes, session_ids(s), rc, gone, out.stderr[-200:]))
        finally:
            a.gone()
            M.laptop_down(s)


def case_phone_revoke_ends_it():
    """S7."""
    with C.Scn() as s:
        a = Claude(s, C.SID1, **KNOBS)
        try:
            p = pair_phone(s, a)
            if p is None:
                return
            sid = p["sid"]
            s.relay.end_session(sid, "revoked")  # the phone revokes: the relay tells hmd's stream the session is over
            gone = C.wait_until(lambda: not C.alive(p["client"]) and not M.logins(s) and show(s)[0] == 3, 40)
            log = app_log(s)
            T.check(bool(gone) and "the relay ended the session" in log and sid[:8] in log,
                    "S7. a revoke from the phone ends the pairing: the client ends, the stored login and the pairing record go, and the app log says the "
                    "relay ended the session", "gone %r logins %r log %s" % (gone, session_ids(s), log[-300:]))
        finally:
            a.gone()
            M.laptop_down(s)


def case_no_other_hook_stops_it():
    """S8."""
    with open(C.HOOKS_JSON, encoding="utf-8") as f:
        hooks = json.load(f)["hooks"]
    with open(C.HOOKS_META, encoding="utf-8") as f:
        ids = {(e["event"], e["index"]): e["id"] for e in json.load(f)["hooks"]}
    stop_ids = ("SessionEnd", "Stop")
    touching = re.compile(r"heimdall-relay-client|heimdall-app|app disconnect|pkill|killall|\bkill\b")
    found = {}
    for event in stop_ids:
        for index, group in enumerate(hooks.get(event, [])):
            for hook in group.get("hooks", []):
                if touching.search(hook["command"]):
                    found[ids.get((event, index), "%s[%d]" % (event, index))] = hook["command"]
    stop = found.get("pair-window-stop", "")
    T.check(sorted(found) == ["pair-window-stop"] and "pair-window --stop" in stop and "disconnect" not in stop and "relay-client" not in stop,
            "S8. of every SessionEnd and Stop hook only pair-window-stop reaches a window or a relay client, and it runs `pair-window --stop` -- no hook "
            "disconnects, kills or signals anything", str(sorted(found)))


def main():
    H.CASE_JOBS = 2  # five scenarios, each with a supervisor, a client and a relay: two at a time keeps the machine light
    return H.run_main(T, os.path.abspath(__file__), [case_session_end_restart_idle, case_default_never_idles, case_laptop_restart_gh_signed_out,
                                                    case_disconnect_ends_it, case_phone_revoke_ends_it, case_no_other_hook_stops_it])


if __name__ == "__main__":
    sys.exit(main())

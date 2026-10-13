#!/usr/bin/env python3
"""test/lib/app_upgrade_paired_cases.py -- upgrade while paired: a phone bound to a relay client that v2.4.6 started must survive the
upgrade to the per-phone device records (v2.4.7) without that client being restarted and without the phone pairing again -- and a
revoke of that phone, or of any phone, must be final.

The OLD side is real: bin/ and everything else of the v2.4.6 tag (74e33748), extracted with `git archive` into a scratch directory,
runs `hmd app connect --bg` against test/lib/fake_relay_code.py exactly as the operator's did (HMD_PAIR_WINDOW_IDLE_H=0), and a fake
phone binds to its code. The NEW side is this tree: its SessionStart hook (from hooks/hooks.json), its statusline, `hmd app status`,
`hmd app connect` and `hmd app disconnect --device`, run against the old client's live process and the state files it wrote. What must
hold (the numbers are the checks'):
  U1  the starting point is what 2.4.6 leaves: one client, the phone bound, a push registration, and no device record at all
  U2  after the new SessionStart hook, statusline render, `hmd app status` and `hmd app connect`: the SAME client process is still
      running (same pid, same start time), connect.json still names it and its ui, its relay session was neither ended nor revoked
  U3  `hmd app connect` says the repo is already connected and starts nothing
  U4  the phone, which was never asked to pair again, still gets its commands acknowledged under the key it already holds
  U5  `hmd app status` lists the phone as a device: label, GitHub login, id, paired-at, last seen, the capabilities it listed
  U6  the statusline still says `paired via code` with the phone
  U7  the record the new code made of it carries what 2.4.6 kept: label, login, how it paired, when, its capabilities, its push tokens
  U8  a SECOND phone pairs by the code the new pair window offers, and the first phone's push registrations -- the one it made before
      and the one it made after the upgrade -- are not cleared by that pairing; the first phone still works
  U9  revoking the second phone takes out ITS push token and leaves the first phone's (the 2.4.6 client's, which no record lists
      tokens for) where they were
  U10 `hmd app disconnect --device` revokes the 2.4.6 client's relay session (it ends it with TERM: that client has no SIGUSR1
      handler, and SIGUSR1 would kill it with no revoke) and takes out its push registrations
  U11 nothing started here is left running
a revoke is final (a second scenario, the 2.4.6 client alone):
  R1  the phone is listed once and holds a push token
  R2  a revoke whose push token cannot be removed (the store is locked) does not report success, keeps the device's record, and
      leaves the token where it can still be removed
  R3  a legacy phone that was revoked -- its record forgotten while its 2.4.6 client still runs, as drift or a slow exit would leave it --
      is not listed again by any later read, restart of the readers, or `hmd app status`, and its push token is gone
  R4  plain `hmd app disconnect` ends the 2.4.6 client through the relay (its session is revoked), leaving nothing listed or notified
  R5  nothing started here is left running
and every other way a phone ends (a third scenario, a connect run's phone and two more added by `hmd app add-device`, new clients):
  E1  the starting point: three phones bound -- the first by the connect run, one more by each add-device run -- each with a push token and a device record
  E2  `disconnect --device` for a phone whose client crashed does not claim a revoke -- the relay session cannot be revoked from here --
      says so and exits non-zero, yet removes that phone's push token and record and leaves the others alone
  E3  plain `disconnect` with several phones revokes each one's relay session through its client and leaves no token and no record
  E4  nothing started here is left running
"""
import contextlib
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import app_pair_confirm_cases as C  # noqa: E402
import pair_code_harness as H  # noqa: E402
import statusline_sandbox as SL  # noqa: E402

T = C.T
OLD_REF = "74e33748185af9b5ca4efdcc99a8c386e99e1122"  # v2.4.6
APP_REL = (".heimdall", "app")
TOKEN_A = "ExponentPushToken[AAAAAAAAAAAAAAAAAAAAAA]"
TOKEN_A2 = "ExponentPushToken[CCCCCCCCCCCCCCCCCCCCCC]"
TOKEN_B = "ExponentPushToken[BBBBBBBBBBBBBBBBBBBBBB]"
CAPS = ["push-v1", "resync", "view-v1"]
STARTED = set()  # the pids of the processes this test started, as the scratch repo's own state names them


def note_started(s):
    """Remember the pids the scratch repo's state files name -- the connect run's client and ui, the pair window's supervisor, the device
    records' clients -- so that a failed run can end exactly those and nothing else."""
    for pid in (connect_json(s).get("pid_client"), connect_json(s).get("pid_ui"), (s.window_state() or {}).get("pid")):
        if isinstance(pid, int):
            STARTED.add(pid)
    STARTED.update(d["pid"] for d in listed(s) if isinstance(d.get("pid"), int))


def old_tree():
    """A scratch copy of the v2.4.6 tree, or None when this clone's history does not have it (a shallow clone)."""
    have = subprocess.run(["git", "-C", H.REPO, "cat-file", "-e", OLD_REF + "^{commit}"], capture_output=True)
    if have.returncode != 0:
        return None
    dest = tempfile.mkdtemp(prefix="hmd-2.4.6.")
    archive = subprocess.Popen(["git", "-C", H.REPO, "archive", OLD_REF], stdout=subprocess.PIPE)
    untar = subprocess.run(["tar", "-x", "-C", dest], stdin=archive.stdout)
    archive.stdout.close()
    archive.wait()
    if untar.returncode != 0 or archive.returncode != 0:
        shutil.rmtree(dest, ignore_errors=True)
        return None
    return dest


def app_file(s, name):
    try:
        with open(os.path.join(s.repo, *APP_REL, name), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def connect_json(s):
    try:
        return json.loads(app_file(s, "connect.json") or "")
    except ValueError:
        return {}


def device_records(s):
    try:
        return sorted(n for n in os.listdir(os.path.join(s.repo, *APP_REL)) if n.startswith("device-"))
    except OSError:
        return []


def started(pid):
    """The start time `ps` gives a process: with the pid, it tells the same process from one the number was handed to."""
    return subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()


def devices_cli(s, *args):
    return C.run([sys.executable, C.DEVICES_PY] + list(args) + ["--repo", s.repo], s.env())


def listed(s):
    try:
        return json.loads(devices_cli(s, "list").stdout)
    except ValueError:
        return []


def leftovers(paths):
    out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True).stdout
    return [ln.strip() for ln in out.splitlines() if any(p in ln for p in paths) and "ps -axww" not in ln]


def nothing_left(tag, paths):
    """The check that no process whose command line names the scratch directories outlives the run. Only a pid this test itself recorded
    as one it started is ever signalled -- never anything by name."""
    gone = C.wait_until(lambda: not leftovers(paths), 30)
    left = leftovers(paths)
    for line in left:
        with contextlib.suppress(OSError, ValueError):
            if int(line.split()[0]) in STARTED:
                os.kill(int(line.split()[0]), 9)
    T.check(gone, "%s. nothing the 2.4.6 client, the new window or the test started is left running" % tag, "\n".join(left))


def old_connect(s, old):
    """What the operator ran under 2.4.6: `hmd app connect --bg` from the v2.4.6 tree, the event log where its default puts it."""
    argv = [os.path.join(old, "bin", "heimdall-app"), "connect", "--repo", s.repo, "--port", "0", "--relay", s.relay.url, "--bg"]
    env = s.env(HMD_PAIR_WINDOW_IDLE_H="0", HMD_RELAY_EVENT_LOG=os.path.join(s.repo, *APP_REL, "relay-events.jsonl"))
    proc = H.Proc(argv, env, cwd=s.repo)
    s.procs.append(proc)
    proc.close_stdin()
    return proc, proc.wait_exit(90)


def case_upgrade_while_paired():
    old = old_tree()
    if old is None:
        T.check(True, "U0. (skipped) v2.4.6 is not in this clone's history: the old client cannot be started")
        return
    sl = SL.Sandbox(C.statusline_fixture())
    paths = [old, sl.base, os.path.realpath(sl.base)]
    try:
        subprocess.run("git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture",
                       shell=True, cwd=sl.ws, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with C.Scn() as s:
            s.sb.repo = sl.ws  # the repo is the statusline sandbox's workspace, so the statusline renders THIS repo's marker
            run_upgrade(s, sl, old)
        nothing_left("U11", paths)
    finally:
        sl.close()
        shutil.rmtree(old, ignore_errors=True)


def run_upgrade(s, sl, old):
    proc, rc = old_connect(s, old)
    registered = C.wait_until(lambda: s.relay.registrations, 40)
    if not (rc == 0 and registered and C.client_pid(s)):
        T.check(False, "U1. (setup) the 2.4.6 `hmd app connect --bg` is running and offers the code", "rc %r %s" % (rc, proc.tail()))
        return
    sid_a, pid = s.relay.latest().id, C.client_pid(s)
    s.bind(sid_a, device_label="Pixel 9a")
    _opened, hmd_a = C.phone_state(s, s.phone, sid_a)
    seqs = iter(range(1, 100))

    def pixel(action, params):
        ack = C.phone_command(s, s.phone, hmd_a, sid_a, next(seqs), action, params)
        return bool(ack and ack.get("ok"))

    def push(token, ref):
        return pixel("register_push", {"v": 1, "provider": "expo", "token": token, "platform": "android", "ref": ref,
                                       "label": "phone", "events": ["approval"]})

    resynced = pixel("resync", {"last_seq": 0, "digest": "0" * 64, "caps": CAPS})
    pushed = push(TOKEN_A, "aaaaaaaaaaaaaaaa")
    before = connect_json(s)
    t0 = started(pid)
    marker = os.path.join(s.repo, *APP_REL, "paired-%s.json" % s.relay.registrations[0]["code"])
    T.check(bool(hmd_a) and resynced and pushed and C.push_tokens(s) == [TOKEN_A] and before.get("pid_client") == pid
            and not device_records(s) and os.path.exists(marker),
            "U1. (setup) a 2.4.6 client has the phone bound -- state, capabilities, a push token -- and keeps no device record",
            "hmd %r resync %r push %r tokens %r records %r connect %r" % (bool(hmd_a), resynced, pushed, C.push_tokens(s), device_records(s), before))

    # -- the upgrade: this tree's hook, statusline, status and connect, against the old client's live state ----------------------------
    hook = s.hook("pair-window-start", C.SID1, HMD_PAIR_WINDOW_POLL_S="0.2", HMD_PAIR_WINDOW_IDLE_H="0")
    shown = C.render(sl, C.SID1, HEIMDALL_HOME=s.home)
    status = C.ANSI.sub("", C.app_status(s, HMD_PAIR_WINDOW_IDLE_H="0").stdout)
    again = C.run([H.APP_PATH, "connect", "--repo", s.repo, "--port", str(before.get("port")), "--relay", s.relay.url, "--bg"],
                  s.env(HMD_PAIR_WINDOW_IDLE_H="0"), stdin="", timeout=120, cwd=s.repo)
    after = connect_json(s)
    note_started(s)
    T.check(hook.returncode == 0 and C.alive(pid) and started(pid) == t0 and after.get("pid_client") == pid
            and after.get("pid_ui") == before.get("pid_ui") and not s.relay.get(sid_a).ended and sid_a not in s.relay.revokes,
            "U2. after the new SessionStart hook, statusline, `hmd app status` and `hmd app connect` the SAME 2.4.6 client is running "
            "(pid, start time, connect.json) and its relay session was neither ended nor revoked",
            "alive %s start %r -> %r connect.json %r revokes %r hook rc %r" % (C.alive(pid), t0, started(pid), after, s.relay.revokes, hook.returncode))
    T.check(again.returncode != 0 and "already connected" in again.stderr and after == before,
            "U3. `hmd app connect` says this repo is already connected and starts nothing",
            "rc %r %s %s" % (again.returncode, again.stdout[-200:], again.stderr[-300:]))
    T.check(pixel("send-message", {"text": "after the upgrade"}),
            "U4. the phone, never asked to pair again, still gets its command acknowledged under the key it holds", "")
    T.check("devices: 1 paired" in status and "Pixel 9a" in status and "@octocat" in status and "last seen" in status
            and "paired " in status and ",".join(CAPS) in status,
            "U5. `hmd app status` lists the phone as a device: label, GitHub login, id, paired-at, last seen, capabilities", status[-700:])
    T.check("paired via code" in shown and "Pixel 9a" in shown,
            "U6. the statusline still says `paired via code` with the phone", shown[-300:])
    devices = listed(s)
    d = devices[0] if len(devices) == 1 else {}
    T.check(d.get("label") == "Pixel 9a" and d.get("gh_login") == "octocat" and d.get("via") == "code" and d.get("pid") == pid
            and d.get("caps") == CAPS and abs(d.get("bound_at", 0) - time.time()) < 600 and len(d.get("push_fps", [])) == 1
            and len(device_records(s)) == 1,
            "U7. the device record made of it carries what 2.4.6 kept: label, login, how it paired, when, capabilities, push token",
            "devices %r records %r" % (devices, device_records(s)))

    # -- a second phone pairs on the window the new code opened; the first keeps everything it had --------------------------------
    phone_b = H.Phone(C.E2E)
    rotated = push(TOKEN_A2, "cccccccccccccccc")  # the first phone registers again AFTER the upgrade, through the old client
    sid_b, opened_b, hmd_b = C.pair_next(s, phone_b, "iPhone 15", 1, timeout=60)
    kept = C.push_tokens(s)
    note_started(s)
    status_two = C.ANSI.sub("", C.app_status(s, HMD_PAIR_WINDOW_IDLE_H="0").stdout)
    ack_b = C.phone_says(s, phone_b, hmd_b, sid_b, 1, "from the iphone") if sid_b else None
    T.check(rotated and sid_b is not None and opened_b is not None and kept == sorted([TOKEN_A, TOKEN_A2])
            and pixel("send-message", {"text": "still here"}) and bool(ack_b and ack_b.get("ok"))
            and "devices: 2 paired" in status_two and "Pixel 9a" in status_two and "iPhone 15" in status_two
            and C.alive(pid) and sid_a not in s.relay.revokes,
            "U8. a second phone pairs by the code and the first phone's push registrations survive it, both phones work and both are listed",
            "tokens %r sid_b %r status %s" % (kept, sid_b, status_two[-500:]))

    # -- revoking the second phone: its token goes, the first phone's (which no record lists) stay -------------------------------------
    ack_reg = C.phone_command(s, phone_b, hmd_b, sid_b, 2, "register_push",
                              {"v": 1, "provider": "expo", "token": TOKEN_B, "platform": "ios", "ref": "00112233445566ff",
                               "label": "phone", "events": ["approval"]}) if sid_b else None
    both = C.push_tokens(s)
    gone_b = C.run([H.APP_PATH, "disconnect", "--repo", s.repo, "--device", "iPhone 15"], s.env(HMD_TAILSCALE_BIN="/usr/bin/false"),
                   stdin="", timeout=120)
    revoked_b = C.wait_until(lambda: sid_b in s.relay.revokes, 30)
    left = C.wait_until(lambda: C.push_tokens(s) == sorted([TOKEN_A, TOKEN_A2]), 20)
    T.check(bool(ack_reg and ack_reg.get("ok")) and both == sorted([TOKEN_A, TOKEN_A2, TOKEN_B]) and gone_b.returncode == 0 and revoked_b
            and left and pixel("send-message", {"text": "still here after the iphone went"}) and sid_a not in s.relay.revokes,
            "U9. revoking the second phone takes out ITS push token and leaves the first phone's (the 2.4.6 client's) where they were",
            "tokens %r then %r revoked %s rc %r %s" % (both, C.push_tokens(s), revoked_b, gone_b.returncode, gone_b.stderr[-300:]))

    # -- `hmd app disconnect --device` on the 2.4.6 client ----------------------------------------------------------------------------
    gone = C.run([H.APP_PATH, "disconnect", "--repo", s.repo, "--device", "Pixel 9a"], s.env(HMD_TAILSCALE_BIN="/usr/bin/false"),
                 stdin="", timeout=120)
    revoked = C.wait_until(lambda: sid_a in s.relay.revokes, 30)
    ended = C.wait_until(lambda: not C.alive(pid), 20)
    T.check(gone.returncode == 0 and revoked and ended and C.wait_until(lambda: C.push_tokens(s) == [], 20),
            "U10. `disconnect --device` revokes the 2.4.6 client's relay session and takes out its push tokens (both)",
            "rc %r revoked %s ended %s revokes %r tokens %r %s%s" % (gone.returncode, revoked, ended, s.relay.revokes, C.push_tokens(s),
                                                                     gone.stdout[-200:], gone.stderr[-300:]))


def case_revoked_legacy_stays_revoked():
    old = old_tree()
    if old is None:
        T.check(True, "R0. (skipped) v2.4.6 is not in this clone's history: the old client cannot be started")
        return
    paths = [old]
    try:
        with C.Scn() as s:
            paths += [s.sb.root, os.path.realpath(s.sb.root)]
            run_revoked_legacy(s, old)
        nothing_left("R5", paths)
    finally:
        shutil.rmtree(old, ignore_errors=True)


def hold_push_lock(s):
    """An exclusive flock on the push store's lock file, the one its writers take: they wait their 3 s and fail."""
    fd = os.open(os.path.join(s.repo, *APP_REL, "push.json.lock"), os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def run_revoked_legacy(s, old):
    proc, rc = old_connect(s, old)
    registered = C.wait_until(lambda: s.relay.registrations, 40)
    if not (rc == 0 and registered and C.client_pid(s)):
        T.check(False, "R1. (setup) the 2.4.6 `hmd app connect --bg` is running and offers the code", "rc %r %s" % (rc, proc.tail()))
        return
    sid_a, pid = s.relay.latest().id, C.client_pid(s)
    s.bind(sid_a, device_label="Pixel 9a")
    _opened, hmd_a = C.phone_state(s, s.phone, sid_a)
    pushed = C.register_push(s, s.phone, hmd_a, sid_a, TOKEN_A, "aaaaaaaaaaaaaaaa")
    devices = listed(s)
    dev_id = devices[0]["id"] if len(devices) == 1 else None
    note_started(s)
    T.check(bool(hmd_a) and pushed and dev_id and C.push_tokens(s) == [TOKEN_A],
            "R1. (setup) the 2.4.6 client's phone is listed once and holds a push token", "devices %r tokens %r" % (devices, C.push_tokens(s)))
    if not dev_id:
        return

    fd = hold_push_lock(s)
    try:
        blocked = devices_cli(s, "forget", dev_id)
    finally:
        os.close(fd)
    T.check(blocked.returncode != 0 and [x["id"] for x in listed(s)] == [dev_id] and C.push_tokens(s) == [TOKEN_A],
            "R2. a revoke whose push token cannot be removed does not report success, keeps the device's record and leaves the token to be removed",
            "rc %r listed %r tokens %r %s" % (blocked.returncode, listed(s), C.push_tokens(s), blocked.stderr[-300:]))

    done = devices_cli(s, "forget", dev_id)
    reads = [listed(s), listed(s)]  # each read is a process of its own: nothing carries over between them but the files
    counted = devices_cli(s, "count").stdout.strip()
    resolved = C.run([sys.executable, C.DEVICES_PY, "resolve", "--repo", s.repo, "Pixel 9a"], s.env()).returncode
    status = C.ANSI.sub("", C.app_status(s, HMD_PAIR_WINDOW_IDLE_H="0").stdout)
    T.check(done.returncode == 0 and C.alive(pid) and reads == [[], []] and counted == "0" and resolved == 1
            and "devices:" not in status and C.push_tokens(s) == [],
            "R3. a revoked legacy phone is not listed again -- by later reads, a restart of the readers or `hmd app status` -- though its "
            "2.4.6 client and the files it left are still there, and its push token is gone",
            "rc %r alive %s reads %r count %r resolve %r tokens %r status %s" % (done.returncode, C.alive(pid), reads, counted, resolved,
                                                                                C.push_tokens(s), status[-300:]))
    ended = C.run([H.APP_PATH, "disconnect", "--repo", s.repo], s.env(HMD_TAILSCALE_BIN="/usr/bin/false"), stdin="", timeout=180)
    T.check(ended.returncode == 0 and C.wait_until(lambda: sid_a in s.relay.revokes, 30) and C.wait_until(lambda: not C.alive(pid), 20)
            and listed(s) == [] and C.push_tokens(s) == [],
            "R4. plain `hmd app disconnect` ends the 2.4.6 client through the relay: its session is revoked, and nothing is left listed or notified",
            "rc %r revokes %r alive %s %s%s" % (ended.returncode, s.relay.revokes, C.alive(pid), ended.stdout[-200:], ended.stderr[-300:]))


def case_every_end_reaches_the_relay():
    # a connect run's phone and two more added with `hmd app add-device` (one window per use), each holding a push token. A phone whose client crashed (kill -9) cannot be revoked from here -- its
    # session token lived in that client's memory only -- so `--device` says so, in words and in its exit status, and still removes what is
    # local; plain `disconnect` ends every other phone through its own client, which revokes its relay session and takes out its tokens.
    with C.Scn() as s:
        app = s.app("--relay", s.relay.url, "--bg")
        app.close_stdin()
        rc = app.wait_exit(90)
        if not (rc == 0 and C.wait_until(lambda: s.relay.registrations, 40)):
            T.check(False, "E1. (setup) connect --bg offers the code", "rc %r %s" % (rc, app.tail()))
            return
        phones = [s.phone, H.Phone(C.E2E), H.Phone(C.E2E)]
        sids, keys = [], []
        for n, phone in enumerate(phones):
            if n == 0:
                sid = s.bind(device_label="Phone 1")
                opened, hmd = C.phone_state(s, phone, sid)
            else:
                # a connect pairs ONE phone and closes the code: each further phone is one `add-device` run, which ends once its phone paired
                proc, sid, opened, hmd = C.add_phone(s, phone, "Phone %d" % (n + 1), n)
                proc.wait_exit(30)
            sids.append(sid if opened is not None else None)
            keys.append(hmd)
        tokens = ["ExponentPushToken[%s]" % (c * 22) for c in "DEF"]
        pushed = [sids[n] is not None and C.register_push(s, phone, keys[n], sids[n], tokens[n], "%016x" % (n + 1)) for n, phone in enumerate(phones)]
        note_started(s)
        pids = C.device_pids(s)
        T.check(None not in sids and all(pushed) and C.push_tokens(s) == sorted(tokens) and len(device_records(s)) == 3 and len(pids) == 3,
                "E1. (setup) a connect run has three phones bound -- one by the connect, two added with `hmd app add-device` -- each with a push token and a device record",
                "sids %r pushed %r tokens %r records %r pids %r" % (sids, pushed, C.push_tokens(s), device_records(s), pids))
        if None in sids or len(pids) != 3:
            return
        os.kill(pids["Phone 1"], 9)  # the exact client this connect run started for the first phone
        C.wait_until(lambda: "Phone 1" not in C.device_pids(s), 20)
        env = s.env(HMD_TAILSCALE_BIN="/usr/bin/false")
        gone = C.run([H.APP_PATH, "disconnect", "--repo", s.repo, "--device", "Phone 1"], env, stdin="", timeout=120)
        T.check(gone.returncode == 0 and "revoked device" in gone.stdout + gone.stderr and "NOT be revoked" not in gone.stderr
                and C.wait_until(lambda: C.push_tokens(s) == sorted(tokens[1:]), 20)
                and "device-%s.json" % C.device_fp(phones[0]) not in device_records(s) and sorted(C.device_pids(s)) == ["Phone 2", "Phone 3"]
                and sids[0] in s.relay.revokes and sids[1] not in s.relay.revokes and sids[2] not in s.relay.revokes,
                "E2. `disconnect --device` for a phone whose client is gone revokes its relay session through the login its client stored "
                "(no client is left to ask), exits 0, removes that phone's push token and record and leaves the others alone",
                "rc %r tokens %r records %r revokes %r %s%s" % (gone.returncode, C.push_tokens(s), device_records(s), s.relay.revokes,
                                                              gone.stdout[-200:], gone.stderr[-400:]))
        end = C.run([H.APP_PATH, "disconnect", "--repo", s.repo], env, stdin="", timeout=180)
        T.check(end.returncode == 0 and C.wait_until(lambda: sids[1] in s.relay.revokes and sids[2] in s.relay.revokes, 30)
                and C.wait_until(lambda: not C.alive(pids["Phone 2"]) and not C.alive(pids["Phone 3"]), 20)
                and C.wait_until(lambda: C.push_tokens(s) == [] and not device_records(s), 20),
                "E3. plain `hmd app disconnect` with several phones revokes each one's relay session through its own client, and leaves "
                "no push token and no device record",
                "rc %r revokes %r tokens %r records %r %s%s" % (end.returncode, s.relay.revokes, C.push_tokens(s), device_records(s),
                                                              end.stdout[-200:], end.stderr[-300:]))
        nothing_left("E4", [s.sb.root, os.path.realpath(s.sb.root)])


def main():
    for case in (case_upgrade_while_paired, case_revoked_legacy_stays_revoked, case_every_end_reaches_the_relay):
        try:
            case()
        except Exception as exc:  # a case that dies is a failure, not a crash of the run
            T.check(False, "%s raised %s: %s" % (case.__name__, type(exc).__name__, exc))
    return T.finish()


if __name__ == "__main__":
    sys.exit(main())

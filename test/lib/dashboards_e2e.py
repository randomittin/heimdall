#!/usr/bin/env python3
"""test/lib/dashboards_e2e.py [CLIENT] -- the cases of test/dashboards-e2e.test.sh: custom dashboards end to end, DD1-DD8 as ONE flow.

    fake phone (sealed, test/lib/view_phone.py) --dashboard-request create--> the REAL bin/heimdall-relay-client (through test/lib/fake-relay.py)
      --> the producer loop the client starts by itself while `hmd app remote-dashboards` is on (a child `hmd dash run`)
      --> the generator, its model call stubbed by an env-pointed fake hmd-exec that returns one fixed {shape, producer}
      --> needs-confirm: the six digits ride the sealed state frame to the phone
      --> `hmd dash confirm` on a pty, the code typed at the prompt (without a terminal, or with a wrong code, it refuses)
      --> the producer runs against a temp sqlite connector --> the sealed state frame carries the panel data
    plus: a stream rebind of the same phone keeps its dash-v1 with no new resync and another device's refused device_bound leaves it alone; a phone that
    never listed dash-v1 sees no state.dashboards and cannot ask; the switch off ends the loop and refuses requests; the switch on starts it
    again; the client's own shutdown takes the loop with it.

Only fakes and temp dirs: HOME / HEIMDALL_HOME / TMPDIR are one temp tree, the model is a script in it, the database a file in it, no
credential of any kind exists. The only processes signalled are the ones this starts (its client, its fake relay, its own loop child as a
last-resort cleanup, found by this run's unique repo path) -- never any other relay client. Every wait is a bounded poll.
Output: "  ok   ..." / "  FAIL ..." lines and a closing "P passed, F failed"; exit 1 when F > 0.
"""
import contextlib
import json
import os
import pty
import re
import select
import shutil
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import view_phone as VP  # noqa: E402

CLIENT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "bin", "heimdall-relay-client")
FAKE_RELAY = os.path.join(HERE, "fake-relay.py")
HMD = os.path.join(REPO, "bin", "heimdall")
DASH_CAPS = ["resync", "z-zlib", "dash-v1"]
OLD_CAPS = ["resync", "z-zlib"]
D, S, T = "d-0a0b0c0d", "s-1a1b1c1d", "t-2a2b2c2d"
TEXT = "daily signups this week"
PASS = FAIL = 0

TMP = os.path.realpath(tempfile.mkdtemp(prefix="dash-e2e-"))
HOME = os.path.join(TMP, "home")
HH = os.path.join(HOME, ".heimdall")
REPO_DIR = os.path.join(TMP, "shop-repo")
SUBDIR = os.path.join(REPO_DIR, "src")     # `hmd dash` run from here must still find the repo (the git toplevel), as `hmd app` does
PROJECT = os.path.basename(REPO_DIR)
DB = os.path.join(TMP, "shop.db")
FAKE_MODEL = os.path.join(TMP, "bin", "fake-hmd-exec")
MODEL_LOG = os.path.join(TMP, "model-argv.json")
PROPOSAL = {"shape": {"type": "timeseries"},
            "producer": {"kind": "sql", "connector": "shop", "columns": ["day", "n"],
                         "statement": "SELECT day AS day, n AS n FROM signups ORDER BY day"}}
ENV = dict(os.environ, HOME=HOME, HEIMDALL_HOME=HH, TMPDIR=os.path.join(TMP, "tmp"), HMD_PYTHON=sys.executable, HMD_PUSH="0",
           HMD_UI_COMPANION_PANELS="0", HEIMDALL_FALLBACK_ASSUME_REACHABLE="0", HEIMDALL_FALLBACK_PROBE_TIMEOUT="1",
           HMD_DASH_INTERVAL_S="0.5", HMD_DASH_MODEL_BIN=FAKE_MODEL, E2E_MODEL_LOG=MODEL_LOG)
for var in ("CLAUDE_SESSION_ID", "SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CONFIG_DIR", "HMD_UI_CONTROLS", "CLAUDE_CODE_ENTRYPOINT",
            "HMD_AGENT_TYPE", "HMD_JUDGMENT", "CLAUDE_PROJECT_DIR", "HMD_DASH_STORE_MODULE", "HMD_DASH_PSQL", "HMD_DASH_IDLE_PAUSE_S"):
    ENV.pop(var, None)


def check(cond, text, got=None):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ok   " + text, flush=True)
    else:
        FAIL += 1
        print("  FAIL " + text, flush=True)
        if got is not None:
            print("       got: %s" % (str(got)[:600],), flush=True)


def wait_until(pred, timeout, step=0.3):
    deadline = time.time() + timeout
    while True:
        if pred():
            return True
        if time.time() >= deadline:
            return False
        time.sleep(step)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def git(*args):
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *args], cwd=REPO_DIR, check=True, capture_output=True)


def build_world():
    for d in (os.path.join(HOME, ".claude"), os.path.join(TMP, "tmp"), os.path.join(TMP, "bin"), REPO_DIR, SUBDIR):
        os.makedirs(d, exist_ok=True)
    git("init", "-q", ".")
    with open(os.path.join(REPO_DIR, ".gitignore"), "w") as f:
        f.write(".heimdall/\n")
    git("add", "-A")
    git("commit", "-q", "--allow-empty", "-m", "fixture")
    conn = sqlite3.connect(DB)
    conn.execute("CREATE TABLE signups (day TEXT, n INTEGER)")
    conn.executemany("INSERT INTO signups VALUES (?, ?)", [("2026-10-01", 4), ("2026-10-02", 7), ("2026-10-03", 9)])
    conn.commit()
    conn.close()
    with open(FAKE_MODEL, "w") as f:   # what hmd-exec would print for the prompt: one fixed proposal; its argv is kept for the assertions
        f.write("#!%s\nimport json, os, sys\nopen(os.environ['E2E_MODEL_LOG'], 'w').write(json.dumps(sys.argv[1:]))\nsys.stdout.write(%r)\n"
                % (sys.executable, json.dumps(PROPOSAL)))
    os.chmod(FAKE_MODEL, 0o755)


def run_pty(argv, typed=None, wait_for=None, timeout=90, cwd=None):
    """Run argv with a pseudo-terminal as its stdin / stdout / stderr -- a person at a terminal. When `typed` is given it is sent (and a
    newline) once `wait_for` has appeared in the output. -> (exit status, output text); status 124 when it ran out of time."""
    pid, fd = pty.fork()
    if pid == 0:
        try:
            if cwd:
                os.chdir(cwd)
            os.execvpe(argv[0], argv, ENV)
        finally:
            os._exit(127)
    out, sent, status, deadline = b"", typed is None, None, time.time() + timeout
    while status is None and time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            out += chunk
            if not chunk:
                _, status = os.waitpid(pid, 0)
                break
        if not sent and (wait_for is None or wait_for.encode() in out):
            os.write(fd, (typed + "\n").encode())
            sent = True
        done, st = os.waitpid(pid, os.WNOHANG)
        if done:
            status = st
    if status is None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        return 124, out.decode("utf-8", "replace")
    while True:    # what the child printed last is still in the pty
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            break
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    os.close(fd)
    code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)
    return code, out.decode("utf-8", "replace")


def plain(*argv, cwd=None):
    return subprocess.run(list(argv), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90, env=ENV, cwd=cwd)


def loop_procs():
    """(pid, ppid, command) of every `dashboard_producers.py ... run` of THIS run's repo -- found by its unique path, so nothing else counts."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and "dashboard_producers.py" in parts[2] and REPO_DIR in parts[2] and " run" in parts[2]:
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def dash(op, **params):
    return {"action": "dashboard-request", "params": dict(params, op=op)}


def tiles(state):
    return (state.get("dashboards") or {}).get("tiles", [])


def tile_file():
    with open(os.path.join(REPO_DIR, ".heimdall", "ui", "dashboards", D, T + ".json"), encoding="utf-8") as f:
        return json.load(f)


def relist(p):
    """What the app does after a (re)bind: list dash-v1 again. The client keeps the caps across a same-device rebind (3d) and a refused
    foreign one (3e), so this changes nothing unless they were forgotten."""
    p.resync(DASH_CAPS)


def count_events(st, needle):
    """How many lines of the client's own event stream hold `needle`: a device_bound event (the bind itself, plus one for every repeat the
    relay sent) or the error a refused foreign bind prints."""
    try:
        with open(st.out, encoding="utf-8", errors="replace") as f:
            return sum(1 for line in f if needle in line)
    except OSError:
        return 0


def wait_tile(p, pred, since, timeout):
    """The first state frame at index >= since with a tile satisfying `pred`. A phone whose newest frame lost state.dashboards (its caps
    were forgotten) lists dash-v1 again, exactly as the app does, and keeps waiting."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        f = p.state(lambda s: any(pred(t) for t in tiles(s)), since=since, timeout=min(8, max(1, deadline - time.time())))
        if f is not None:
            return f
        newest = [fr for fr in p.frames if fr["type"] == "state"][-1:]
        if newest and "dashboards" not in newest[0]["body"]["state"]:
            relist(p)
    return None


class Stack:
    def __init__(self):
        self.procs, self.client, self.phone = [], None, None
        self.log, self.ctl = os.path.join(TMP, "log"), os.path.join(TMP, "ctl")
        self.out, self.err = os.path.join(TMP, "client.out"), os.path.join(TMP, "client.err")

    def start(self):
        os.makedirs(self.log)
        os.makedirs(self.ctl)
        relay_port, ui_port = free_port(), free_port()
        self.procs.append(subprocess.Popen([sys.executable, FAKE_RELAY, "serve", str(relay_port), "--log", self.log, "--ctl", self.ctl],
                                           stdout=open(os.path.join(TMP, "relay.out"), "w"), stderr=subprocess.STDOUT))
        for _ in range(100):
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", relay_port)) == 0:
                    break
            time.sleep(0.1)
        self.phone = VP.Phone(self.ctl, self.log)
        self.phone.bind()
        self.client = subprocess.Popen([CLIENT, "--relay", "http://127.0.0.1:%d" % relay_port, "--repo", REPO_DIR, "--ui-port", str(ui_port)],
                                       stdout=open(self.out, "w"), stderr=open(self.err, "w"), env=ENV)
        self.procs.append(self.client)
        return self.phone.pair(self.out)

    def stop(self):
        for proc in reversed(self.procs):
            if proc.poll() is None:
                proc.terminate()
        for proc in self.procs:
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def run(st):
    check(st.start(), "setup: the real relay client paired with the fake phone through the fake relay")
    p = st.phone
    first = p.state(timeout=30)
    check(first is not None and "dashboards" not in first["body"]["state"],
          "1a. before the phone lists dash-v1 its state frames carry no dashboards key")
    check(loop_procs() == [], "1b. no producer loop runs while remote dashboards are off")

    # 2. the laptop side: a connector and the switch -- both need a person at a terminal
    code, out = run_pty([HMD, "dash", "connector", "add", "shop", "--engine", "sqlite", "--path", DB])
    cfile = os.path.join(HH, "dashboard-connectors.json")
    check(code == 0 and os.path.isfile(cfile) and stat.S_IMODE(os.stat(cfile).st_mode) == 0o600 and json.load(open(cfile))[0]["name"] == "shop",
          "2a. `hmd dash connector add` (on a pty, through the dispatcher's dash arm) stores the sqlite connector, 0600", (code, out[-300:]))
    r = plain(HMD, "dash", "connector", "add", "other", "--engine", "sqlite", "--path", DB)
    check(r.returncode == 1 and "TTY" in r.stderr and "other" not in open(cfile).read(),
          "2b. without a terminal the same command is refused and nothing is stored", r.stderr[-300:])
    r = plain(HMD, "dash", "connector", "ls")
    check(r.returncode == 0 and "shop" in r.stdout and "sqlite" in r.stdout, "2c. `hmd dash connector ls` lists it", r.stdout + r.stderr)
    code, out = run_pty([HMD, "app", "remote-dashboards", "on", "--repo", REPO_DIR])
    check(code == 0 and "remote dashboards: on" in out, "2d. `hmd app remote-dashboards on` (on a pty) switches them on", (code, out[-300:]))

    # 3. the phone lists dash-v1: the slice appears, and the client has started the loop by itself
    before = p.mark()
    p.resync(DASH_CAPS)
    f = p.state(lambda s: (s.get("dashboards") or {}).get("enabled") is True, since=before, timeout=30)
    slice_ = f["body"]["state"]["dashboards"] if f else {}
    check(f is not None and "dash-v1" in f["body"]["caps"] and slice_.get("v") == 1 and slice_.get("tiles") == [],
          "3a. a phone that lists dash-v1 gets state.dashboards {v:1, enabled:true, tiles:[]} and dash-v1 in hmd's caps", slice_)
    check(wait_until(lambda: len(loop_procs()) == 1, 30), "3b. while remote dashboards are on the client runs exactly one `hmd dash run`", loop_procs())
    procs = loop_procs()
    check(len(procs) == 1 and procs[0][1] == st.client.pid and ("--parent %d" % st.client.pid) in procs[0][2],
          "3c. that loop is the client's own child and was started with the client's pid as --parent", procs)
    if os.environ.get("DASH_E2E_STOP_AFTER") == "3":    # the wrapper's mutant runs only need to get this far
        return

    # 3d. a stream rebind: the relay's device_bound again with the paired phone's own key. What the phone listed is still held, so
    # state.dashboards keeps riding with no new resync from the phone
    bound_before, before = count_events(st, '"device_bound"'), p.mark()
    p.rebind()
    rebound = wait_until(lambda: count_events(st, '"device_bound"') > bound_before, 20)
    lost = p.state(lambda s: "dashboards" not in s, since=before, timeout=4)
    p.pull()
    states = [fr for fr in p.frames[before:] if fr["type"] == "state"]
    check(rebound and lost is None and states and all("dashboards" in fr["body"]["state"] for fr in states),
          "3d. a same-device device_bound (a stream rebind) keeps the phone's dash-v1: every state frame after it still carries state.dashboards, with no new resync",
          (rebound, [sorted(fr["body"]["state"])[:4] for fr in states][-2:]))

    # 3e. another device's device_bound is refused by the latch, and a frame that binds no one takes nothing from the paired phone: its
    # dash-v1 stays, so a stray or hostile frame cannot strip its slices
    refused_before, before = count_events(st, "differs from the already latched"), p.mark()
    p.rebind(other=True)
    refused = wait_until(lambda: count_events(st, "differs from the already latched") > refused_before, 20)
    lost = p.state(lambda s: "dashboards" not in s, since=before, timeout=4)
    p.pull()
    states = [fr for fr in p.frames[before:] if fr["type"] == "state"]
    check(refused and lost is None and all("dashboards" in fr["body"]["state"] for fr in states),
          "3e. a device_bound for ANOTHER device is refused and the paired phone keeps its dash-v1: no state frame after it lacks state.dashboards",
          (refused, [sorted(fr["body"]["state"])[:4] for fr in states][-2:]))
    # 3f. the latch held: the paired phone's own next command is still heard
    ack, before = p.resync(DASH_CAPS)
    f = p.state(lambda s: "dashboards" in s, since=before, timeout=20)
    check(ack is not None and ack.get("ok") is True and f is not None,
          "3f. the paired phone is unaffected: its next sealed command is acked ok and state.dashboards is still there", ack)
    if os.environ.get("DASH_E2E_STOP_AFTER") == "3f":    # the wrapper's mutants of 3d / 3e
        return

    # 4. the phone describes a tile hmd has never seen
    relist(p)   # the app lists its caps again after every (re)bind; the stream may have been rebound since step 3
    before = p.mark()
    seq = p.command(dash("create", rid="q-00000001", dashboard_id=D, screen_id=S, tile_id=T, project=PROJECT, text=TEXT))
    ack = p.ack(seq)
    check(ack is not None and ack.get("ok") is True and ack.get("detail") == "queued" and ack.get("id") == T and ack.get("of_seq") == seq,
          "4. dashboard-request create for an unseen tile -> {ok:true, detail:queued, id:<tile>}", ack)

    # 5. the generator (fake hmd-exec) answers; the tile waits for the person at the laptop, with the six digits on the phone
    f = wait_tile(p, lambda t: t["tile_id"] == T and t["phase"] == "needs-confirm", before, 60)
    row = next((t for t in tiles(f["body"]["state"]) if t["tile_id"] == T), None) if f else None
    check(row is not None and re.fullmatch(r"[0-9]{6}", (row.get("confirm") or {}).get("code", "")) and row["panel"] is None
          and row["producer_label"] == "shop (read-only)" and row["origin"] == "phone" and row["intent"] == TEXT,
          "5a. the tile reaches needs-confirm with confirm.code (six digits), no panel yet, label 'shop (read-only)'", row)
    code_digits = row["confirm"]["code"] if row else "000000"
    try:
        argv = json.load(open(MODEL_LOG))
    except (OSError, ValueError):
        argv = []
    prompt = argv[argv.index("-p") + 1] if "-p" in argv else ""
    check(argv[:1] == ["run"] and "--tools" in argv and argv[argv.index("--tools") + 1] == "" and "not instructions" in prompt and TEXT in prompt
          and "signups" in prompt and DB not in prompt and REPO_DIR not in prompt,
          "5b. the model was asked with the description as quoted data (not instructions), the table names, no tools, and no path", argv[:3])
    time.sleep(3)   # six passes of the loop
    held = tile_file()
    check(held["phase"] == "needs-confirm" and held["panel"] is None and held["confirmed_fp"] is None,
          "5c. nothing runs while the tile is unconfirmed: still needs-confirm, no panel, nothing pinned", (held["phase"], held["panel"]))
    r = plain(HMD, "dash", "pending", cwd=SUBDIR)
    check(r.returncode == 0 and T in r.stdout and "shop" in r.stdout and "SELECT day AS day, n AS n FROM signups ORDER BY day" in r.stdout,
          "5d. `hmd dash pending`, run from a subdirectory of the repo, lists the tile with its connector and its FULL statement", r.stdout[-400:] + r.stderr[-200:])

    # 6. the confirmation: a person, a terminal, the code
    before = p.mark()
    r = plain(HMD, "dash", "confirm", T, "--code", code_digits, cwd=SUBDIR)
    check(r.returncode == 1 and "TTY" in r.stderr and tile_file()["confirmed_fp"] is None,
          "6a. confirm without a terminal is refused, even with the right code", r.stderr[-300:])
    wrong = "%06d" % ((int(code_digits) + 1) % 1000000)
    code, out = run_pty([HMD, "dash", "confirm", T], typed=wrong, wait_for="Enter to cancel", cwd=SUBDIR)
    check(code == 1 and "wrong code" in out and tile_file()["confirmed_fp"] is None, "6b. a wrong code on a pty is refused and pins nothing", (code, out[-300:]))
    code, out = run_pty([HMD, "dash", "confirm", T], typed=code_digits, wait_for="Enter to cancel", cwd=REPO_DIR)
    pinned = tile_file()
    check(code == 0 and "confirmed" in out and pinned["confirmed_fp"] == pinned["fingerprint"] and "FROM signups" in out,
          "6c. the code typed on a pty confirms it (the full statement was shown) and pins the fingerprint", (code, out[-400:]))

    # 7. the producer runs against the sqlite connector; the sealed frame carries the panel
    f = wait_tile(p, lambda t: t["tile_id"] == T and t["phase"] == "live" and t["panel"], before, 60)
    row = next((t for t in tiles(f["body"]["state"]) if t["tile_id"] == T), None) if f else None
    want = {"x": ["2026-10-01", "2026-10-02", "2026-10-03"], "y": [4, 7, 9]}
    check(row is not None and row["panel"]["type"] == "timeseries" and row["panel"]["data"] == want and row["confirm"] is None
          and row["detail"] is None and isinstance(row["last_ok_at"], int) and row["panel"]["stale"] is False,
          "7. the confirmed producer ran against the temp sqlite connector: the sealed state frame carries the timeseries data, live", row)

    # 8. a refresh from the phone reruns it against the changed database
    conn = sqlite3.connect(DB)
    conn.execute("INSERT INTO signups VALUES ('2026-10-04', 11)")
    conn.commit()
    conn.close()
    relist(p)
    before = p.mark()
    seq = p.command(dash("refresh", rid="q-00000002", dashboard_id=D, project=PROJECT, tile_id=T))
    ack = p.ack(seq)
    f = wait_tile(p, lambda t: t["tile_id"] == T and t["panel"] and t["panel"]["data"]["y"][-1:] == [11], before, 60)
    check(ack is not None and ack.get("ok") is True and f is not None,
          "8. a sealed refresh makes the loop run it again: the new row is in the next frame's panel", ack)

    # 9. nothing about the producer left the laptop
    text = p.all_text()
    leaks = [w for w in ("SELECT", "proposal", "shop.db", DB, REPO_DIR, "dashboard-connectors", "FROM signups") if w in text]
    check(not leaks, "9a. no statement, proposal, database path, repo path or connector file name in any sealed frame", leaks)
    audit = open(os.path.join(REPO_DIR, ".heimdall", "ui", "controls-audit.jsonl"), encoding="utf-8").read()
    events = open(os.path.join(REPO_DIR, ".heimdall", "app", "relay-events.jsonl"), encoding="utf-8").read()
    check("dashboard-request" in audit and "SELECT" not in audit and TEXT not in audit and "SELECT" not in events and TEXT not in events
          and '"confirm"' in audit, "9b. the audit log has the requests and the confirmation, and neither it nor the timeline holds the text or a statement",
          audit[-300:])

    # 10. a phone that does not list dash-v1 sees none of it and cannot ask
    before = p.mark()
    p.resync(OLD_CAPS)
    p.state(since=before, timeout=30)
    seq = p.command(dash("refresh", rid="q-00000003", dashboard_id=D, project=PROJECT, tile_id=T))
    ack = p.ack(seq)
    time.sleep(2.5)
    p.pull()
    after = p.frames[before:]
    states = [fr for fr in after if fr["type"] == "state"]
    check(states and all("dashboards" not in fr["body"]["state"] for fr in states),
          "10a. after the phone drops dash-v1 every state frame lacks the dashboards key", [list(fr["body"]["state"])[:3] for fr in states][:2])
    check(ack is not None and ack.get("ok") is False and ack.get("detail") == "caps-missing", "10b. its dashboard-request is refused caps-missing", ack)
    joined = "\n".join(fr["text"] for fr in after)
    check(T not in joined and "shop (read-only)" not in joined and TEXT not in joined,
          "10c. neither the tile id, its label nor its intent is in any frame sent to that phone", [w for w in (T, "shop (read-only)", TEXT) if w in joined])

    # 11. the switch off ends the loop and refuses requests
    r = plain(HMD, "app", "remote-dashboards", "off", "--repo", REPO_DIR)
    check(r.returncode == 0 and wait_until(lambda: loop_procs() == [], 30),
          "11a. `hmd app remote-dashboards off` -- the client ends its producer loop", (r.returncode, r.stdout[-200:], loop_procs()))
    before = p.mark()
    p.resync(DASH_CAPS)
    f = p.state(lambda s: (s.get("dashboards") or {}).get("enabled") is False, since=before, timeout=30)
    seq = p.command(dash("refresh", rid="q-00000004", dashboard_id=D, project=PROJECT, tile_id=T))
    ack = p.ack(seq)
    check(f is not None and f["body"]["state"]["dashboards"]["tiles"] == [] and ack is not None and ack.get("ok") is False
          and ack.get("detail") == "dashboards-off", "11b. the dash-v1 phone is told enabled:false (no tiles) and its request is refused dashboards-off", ack)

    # 12. back on: the client starts the loop again
    code, out = run_pty([HMD, "app", "remote-dashboards", "on", "--repo", REPO_DIR])
    check(code == 0 and wait_until(lambda: len(loop_procs()) == 1, 30), "12. switching them on again starts a fresh producer loop", (code, loop_procs()))

    # 12b. a crashed loop costs a restart of the loop, never the client
    crashed = loop_procs()
    for pid, _ppid, _cmd in crashed:
        os.kill(pid, signal.SIGKILL)      # this run's own child, found by its unique repo path
    gone = {c[0] for c in crashed}
    restarted = wait_until(lambda: [x for x in loop_procs() if x[0] not in gone] != [], 40)
    before = p.mark()
    p.resync(DASH_CAPS)
    f = p.state(lambda s: (s.get("dashboards") or {}).get("enabled") is True, since=before, timeout=30)
    check(len(crashed) == 1 and st.client.poll() is None and restarted and f is not None,
          "12b. a loop killed with SIGKILL does not take the client down: it keeps answering the phone and starts a new loop", (crashed, st.client.poll()))

    # 12c. one loop per repo: a second `hmd dash run` finds the first one's lock and leaves
    r = subprocess.run([HMD, "dash", "run", "--repo", REPO_DIR], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30, env=ENV)
    check(r.returncode == 3 and "already runs" in r.stderr, "12c. a second `hmd dash run` for the same repo exits 3: the client's loop owns it", (r.returncode, r.stderr[-200:]))

    # 13. the client's own shutdown takes the loop with it
    st.stop()
    check(wait_until(lambda: loop_procs() == [], 20), "13. stopping the relay client leaves no producer loop behind", loop_procs())


def main():
    st = Stack()
    try:
        build_world()
        run(st)
    except Exception as exc:   # a crash of the scenario is a failure with its type, never a silent pass
        check(False, "scenario crashed: %s: %s" % (type(exc).__name__, exc))
    finally:
        st.stop()
        if FAIL:    # what the client itself said about binds, caps and errors: the first thing a red run needs
            with contextlib.suppress(OSError):
                events = [ln.strip()[:220] for ln in open(st.out, encoding="utf-8", errors="replace")
                          if any(k in ln for k in ('"device_bound"', '"device_caps"', '"error"', '"reconnect', '"stream'))]
                print("diagnostics (client events): %s" % events[-12:], flush=True)
        for pid, _ppid, _cmd in loop_procs():     # last resort, this run's own loop only (found by its unique repo path)
            with contextlib.suppress(OSError):
                os.kill(pid, signal.SIGTERM)
        shutil.rmtree(TMP, ignore_errors=True)
    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

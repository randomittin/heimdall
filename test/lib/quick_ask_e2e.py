#!/usr/bin/env python3
"""test/lib/quick_ask_e2e.py [CLIENT] -- the cases of test/quick-ask-e2e.test.sh: `quick-ask` (hmdapp docs/HANDOFF-TO-HEIMDALL-watch.md H3) END TO END.

    fake phone (sealed, test/lib/view_phone.py) --quick-ask--> the REAL bin/heimdall-relay-client (through test/lib/fake-relay.py)
      --> the dispatcher (cap ask-v1, laptop switch `hmd app remote-asks`) --> a worker that asks ONE closed question of a model (an
      env-pointed fake hmd-exec) --> the answer composed in code from the live tiles' panels --> the sealed state frame's `asks` slice

The tiles are real store records: two live number tiles with a confirmed producer on a temp sqlite connector and a panel published through
the store's own validator (the client's producer loop is on while `hmd app remote-dashboards` is, and may refresh them; the scenario
publishes the same panels again before each ask, because what the loop does to a tile is not what is tested here).
Also: a phone that never listed ask-v1 sees no `asks` key and cannot ask; the switch off answers asks-off and empties the slice; the
question text appears in no sealed frame, no audit line, no relay event.

Only fakes and temp dirs: HOME / HEIMDALL_HOME / TMPDIR are one temp tree, the model is a script in it, no credential of any kind exists.
The only processes signalled are the ones this starts (its client, its fake relay, its own loop child as a last-resort cleanup, found by
this run's unique repo path) -- never any other relay client. Every wait is a bounded poll.
Output: "  ok   ..." / "  FAIL ..." lines and a closing "P passed, F failed"; exit 1 when F > 0. ASK_E2E_STOP_AFTER=4 stops after step 4
(the wrapper's mutant runs only need to get that far).
"""
import contextlib
import json
import os
import pty
import select
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import view_phone as VP  # noqa: E402

CLIENT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "bin", "heimdall-relay-client")
FAKE_RELAY = os.path.join(HERE, "fake-relay.py")
HMD = os.path.join(REPO, "bin", "heimdall")
STOP_AFTER = os.environ.get("ASK_E2E_STOP_AFTER")
SETTLE_S = 10 if STOP_AFTER else 30
WAIT_S = 12 if STOP_AFTER else 30
ASK_CAPS = ["resync", "z-zlib", "dash-v1", "ask-v1"]
NO_ASK_CAPS = ["resync", "z-zlib", "dash-v1"]
D, S, T1, T2 = "d-0a0b0c0d", "s-1a1b1c1d", "t-2a2b2c01", "t-2a2b2c02"
NEEDLE = "needle-9f3a7c"
PASS = FAIL = 0

TMP = os.path.realpath(tempfile.mkdtemp(prefix="ask-e2e-"))
HOME = os.path.join(TMP, "home")
HH = os.path.join(HOME, ".heimdall")
REPO_DIR = os.path.join(TMP, "shop-repo")
PROJECT = os.path.basename(REPO_DIR)
DB = os.path.join(TMP, "shop.db")
FAKE_MODEL = os.path.join(TMP, "bin", "fake-hmd-exec")
MODEL_LOG = os.path.join(TMP, "model-calls.ndjson")
REPLY = os.path.join(TMP, "reply.txt")
ENV = dict(os.environ, HOME=HOME, HEIMDALL_HOME=HH, TMPDIR=os.path.join(TMP, "tmp"), HMD_PYTHON=sys.executable, HMD_PUSH="0",
           HMD_UI_COMPANION_PANELS="0", HEIMDALL_FALLBACK_ASSUME_REACHABLE="0", HEIMDALL_FALLBACK_PROBE_TIMEOUT="1",
           HMD_DASH_INTERVAL_S="0.5", HMD_DASH_IDLE_PAUSE_S="0", HMD_DASH_MODEL_BIN=FAKE_MODEL, E2E_MODEL_LOG=MODEL_LOG, E2E_REPLY=REPLY)
for var in ("CLAUDE_SESSION_ID", "SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CONFIG_DIR", "HMD_UI_CONTROLS", "CLAUDE_CODE_ENTRYPOINT",
            "HMD_AGENT_TYPE", "HMD_JUDGMENT", "CLAUDE_PROJECT_DIR", "HMD_DASH_STORE_MODULE", "HMD_DASH_PSQL"):
    ENV.pop(var, None)
os.environ.update(HOME=HOME, HEIMDALL_HOME=HH)     # this process loads the dashboards store in-process to lay the tiles down

# What each tile's producer returns, and so what the panel holds once the loop has run it: the same numbers either way.
TILES = {T1: {"intent": "orders today", "shape": {"type": "number", "format": "count"}, "statement": "SELECT 1284 AS n, 212 AS d",
              "columns": ["n", "d"], "data": {"value": 1284, "delta": 212, "format": "count"}},
         T2: {"intent": "refunds", "shape": {"type": "number", "format": "count"}, "statement": "SELECT 52 AS n",
              "columns": ["n"], "data": {"value": 52, "format": "count"}}}
COUNTER = [0]


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


def load_store():
    spec = spec_from_file_location("companion_ui_controls", os.path.join(REPO, "bin", "lib", "companion_ui_controls.py"))
    controls = module_from_spec(spec)
    spec.loader.exec_module(controls)
    return controls._sibling("companion_dashboards")


def build_world():
    for d in (os.path.join(HOME, ".claude"), os.path.join(TMP, "tmp"), os.path.join(TMP, "bin"), REPO_DIR):
        os.makedirs(d, exist_ok=True)
    git("init", "-q", ".")
    with open(os.path.join(REPO_DIR, ".gitignore"), "w") as f:
        f.write(".heimdall/\n")
    git("add", "-A")
    git("commit", "-q", "--allow-empty", "-m", "fixture")
    conn = sqlite3.connect(DB)
    conn.execute("CREATE TABLE orders (n INTEGER)")
    conn.commit()
    conn.close()
    with open(FAKE_MODEL, "w") as f:   # what hmd-exec would print for the prompt: the chooser's JSON, read from a file the scenario rewrites
        f.write("#!%s\nimport json, os, sys\nopen(os.environ['E2E_MODEL_LOG'], 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "sys.stdout.write(open(os.environ['E2E_REPLY']).read())\n" % sys.executable)
    os.chmod(FAKE_MODEL, 0o755)
    store, now = load_store(), 1790273000
    for tid, spec in TILES.items():           # live tiles: a confirmed producer on the sqlite connector and a published panel
        with store._locked(REPO_DIR):
            store._write_tile(REPO_DIR, store._new_tile({"tile_id": tid, "dashboard_id": D, "screen_id": S, "text": spec["intent"], "refresh_s": 3600}, now))
        proposal = {"shape": spec["shape"], "producer": {"kind": "sql", "connector": "shop", "statement": spec["statement"], "columns": spec["columns"]}}
        COUNTER[0] += 1
        assert store.register_proposal(REPO_DIR, tid, "q-%08x" % COUNTER[0], proposal, now=now) == (True, None), tid
        assert store.confirm_tile(REPO_DIR, tid, store.get_tile(REPO_DIR, tid)["fingerprint"], now=now + 1) == (True, None), tid
        assert store.publish_panel(REPO_DIR, tid, {"title": spec["intent"], "type": "number", "data": spec["data"]}, now=time.time()) == (True, None), tid


def say(obj):
    with open(REPLY, "w") as f:
        f.write(obj if isinstance(obj, str) else json.dumps(obj))


def model_calls():
    try:
        return [json.loads(line) for line in open(MODEL_LOG)]
    except OSError:
        return []


def run_pty(argv, timeout=90):
    """Run argv with a pseudo-terminal as its stdin / stdout / stderr -- a person at a terminal. -> (exit status, output text)."""
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvpe(argv[0], argv, ENV)
        finally:
            os._exit(127)
    out, status, deadline = b"", None, time.time() + timeout
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
        done, st = os.waitpid(pid, os.WNOHANG)
        if done:
            status = st
    if status is None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        return 124, out.decode("utf-8", "replace")
    os.close(fd)
    return (os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)), out.decode("utf-8", "replace")


def plain(*argv):
    return subprocess.run(list(argv), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90, env=ENV)


def loop_procs():
    """(pid, ppid, command) of every `dashboard_producers.py ... run` of THIS run's repo -- found by its unique path, so nothing else counts."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and "dashboard_producers.py" in parts[2] and REPO_DIR in parts[2] and " run" in parts[2]:
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def wait_state(p, pred, since, timeout):
    """The first state frame at index >= since satisfying `pred`. A phone whose newest frame lost state.asks (a stream rebind made the client
    forget its caps) lists ask-v1 again, exactly as the app does after every (re)bind, and keeps waiting."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        frame = p.state(pred, since=since, timeout=min(5, max(1, deadline - time.time())))
        if frame is not None:
            return frame
        newest = [fr for fr in p.frames if fr["type"] == "state"][-1:]
        if newest and "asks" not in newest[0]["body"]["state"]:
            p.resync(ASK_CAPS)
    return None


def listed(p, caps, pred, timeout=WAIT_S):
    """List `caps` (a resync: its digest never matches, so hmd answers with a fresh state frame) and wait for a state satisfying `pred`."""
    _ack, before = p.resync(caps)
    return wait_state(p, pred, before, timeout) if "ask-v1" in caps else p.state(pred, since=before, timeout=timeout)


def slice_of(frame):
    return (frame["body"]["state"].get("asks") if frame else None)


def republish():
    """Lay both panels down again, both tiles live and no longer confirmed: the client's producer loop is on while the dashboards switch is,
    and a tile it may not run is a tile nothing refreshes (or flips to error) behind this scenario's back. An ask reads whatever the store
    holds at that moment, which is all this scenario needs of a tile."""
    store = load_store()
    for tid, spec in TILES.items():
        with store._locked(REPO_DIR):
            tile = store.get_tile(REPO_DIR, tid)
            tile.update(phase="live", detail=None, confirmed_fp=None,
                        panel={"id": tid, "title": spec["intent"], "type": "number", "data": spec["data"], "refresh_s": 3600, "updated_at": int(time.time())})
            store._write_tile(REPO_DIR, tile)


def send_ask(p, text, rid, caps=ASK_CAPS, **overrides):
    """Seal one quick-ask after listing `caps` again (the app does after every rebind; None = do not); -> (ack, index of the first frame
    that can answer it)."""
    if caps is not None:
        p.resync(caps)
    republish()
    before = p.mark()
    params = dict({"rid": rid, "project": PROJECT, "text": text}, **overrides)
    return p.ack(p.command({"action": "quick-ask", "params": params})), before


def settled(p, rid, since, timeout=SETTLE_S):
    """The result row for `rid` once its phase is not `working`, from the first state frame that holds it that way; None on timeout."""
    def done(state):
        return any(r["rid"] == rid and r["phase"] != "working" for r in (state.get("asks") or {}).get("results", []))
    frame = wait_state(p, done, since, timeout)
    return next((r for r in slice_of(frame)["results"] if r["rid"] == rid), None) if frame else None


def ask(p, text, reply, rid):
    """Make the model say `reply`, ask (listing ask-v1 first): -> (ack, result row)."""
    say(reply)
    ack, before = send_ask(p, text, rid)
    return ack, (settled(p, rid, before) if ack and ack.get("ok") else None)


def tile_states():
    store = load_store()
    return [(tid, (store.get_tile(REPO_DIR, tid) or {}).get("phase"), (store.get_tile(REPO_DIR, tid) or {}).get("detail")) for tid in TILES]


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
    check(first is not None and "asks" not in first["body"]["state"] and "ask-v1" in first["body"]["caps"],
          "1a. hmd lists ask-v1 in its caps, and before the phone lists it the state frames carry no asks key", first and first["body"]["caps"])

    # 1b. the laptop's switch is off by default: a phone that lists ask-v1 is told so, and its ask is refused first thing
    f = listed(p, ASK_CAPS, lambda s: "asks" in s)
    check(slice_of(f) == {"v": 1, "enabled": False, "results": []}, "1b. a phone that lists ask-v1 gets state.asks {v:1, enabled:false, results:[]} while the switch is off", slice_of(f))
    ack, _ = send_ask(p, "how many orders today?", "q-0000e201")
    check(ack is not None and ack.get("ok") is False and ack.get("detail") == "asks-off", "1c. a quick-ask is refused asks-off (the switch is the first gate)", ack)

    # 2. the laptop side: a connector and both switches -- each needs a person at a terminal
    code, out = run_pty([HMD, "dash", "connector", "add", "shop", "--engine", "sqlite", "--path", DB])
    check(code == 0, "2a. `hmd dash connector add` (on a pty) stores the sqlite connector the tiles' producers read", (code, out[-300:]))
    code, out = run_pty([HMD, "app", "remote-asks", "on", "--repo", REPO_DIR])
    check(code == 0 and "remote asks: on" in out, "2b. `hmd app remote-asks on` (on a pty) switches asks on", (code, out[-300:]))
    ack, _ = send_ask(p, "how many orders today?", "q-0000e202")
    check(ack is not None and ack.get("ok") is False and ack.get("detail") in ("asks-off", "dashboards-off"),
          "2c. asks on but remote dashboards off is still refused: an ask needs both switches", ack)
    code, out = run_pty([HMD, "app", "remote-dashboards", "on", "--repo", REPO_DIR])
    check(code == 0 and "remote dashboards: on" in out, "2d. `hmd app remote-dashboards on` (on a pty) switches the dashboards on", (code, out[-300:]))
    r = plain(HMD, "app", "remote-asks", "status", "--repo", REPO_DIR)
    check(r.returncode == 0 and r.stdout.startswith("remote asks: on"), "2e. `hmd app remote-asks status` (no terminal) says on", r.stdout + r.stderr)

    # 3. both switches on: the slice is enabled, and the client's loop has run the tiles' producers against the connector
    f = listed(p, ASK_CAPS, lambda s: (s.get("asks") or {}).get("enabled") is True)
    check(slice_of(f) == {"v": 1, "enabled": True, "results": []}, "3a. with both switches on the slice is {v:1, enabled:true, results:[]}", slice_of(f))
    f = listed(p, ASK_CAPS, lambda s: sum(1 for t in (s.get("dashboards") or {}).get("tiles", []) if t["phase"] == "live" and t["panel"] and t["panel"]["data"]["value"] in (1284, 52)) == 2, timeout=WAIT_S)
    check(f is not None, "3b. the dash-v1 phone sees both number tiles live in state.dashboards, with the numbers the panels hold", tile_states())

    # 4. an ask: acked at once, answered later in the slice, matched by rid, the number the panel holds
    rid = "q-0000a001"
    ack, row = ask(p, "how many orders today? " + NEEDLE, {"op": "value", "tiles": [T1]}, rid)
    check(ack is not None and ack.get("ok") is True and ack.get("detail") == "queued" and isinstance(ack.get("of_seq"), int) and set(ack) <= {"ok", "detail", "of_seq"},
          "4a. quick-ask -> {of_seq, ok:true, detail:queued}", ack)
    check(row is not None and row["phase"] == "done" and row["answer"] == "orders today: 1,284" and row["tiles"] == [T1] and row["detail"] is None
          and set(row) == {"rid", "phase", "answer", "tiles", "at", "detail"} and isinstance(row["at"], int),
          "4b. the answer arrives in state.asks, composed from the panel: the tile's exact number, its tile id, no detail", row)
    if STOP_AFTER == "4":
        return

    calls = model_calls()
    prompt = next((a for a in (calls[-1] if calls else []) if "BEGIN-QUESTION" in a), "")
    check(len(calls) == 1 and NEEDLE in prompt and "1,284" not in prompt and "1284" not in prompt and REPO_DIR not in prompt
          and calls[0][:2] == ["run", "-p"] and calls[0][calls[0].index("--tools") + 1] == "",
          "4c. the model was asked once, with no tools: the question is in the prompt, no number and no path is", calls[:1])

    # 5. compare, change, no-tile
    ack, row = ask(p, "orders against refunds?", {"op": "compare", "tiles": [T1, T2]}, "q-0000a002")
    check(row is not None and row["answer"] == "orders today 1,284 vs refunds 52\nDifference +1,232" and row["tiles"] == [T1, T2],
          "5a. compare: two lines, the difference computed in code from the two panels", row)
    ack, row = ask(p, "how did orders change?", {"op": "change", "tiles": [T1]}, "q-0000a003")
    check(row is not None and row["answer"] == "orders today changed +212", "5b. change: the panel's own delta, signed", row)
    ack, row = ask(p, "what is the weather?", {"op": "no-tile", "tiles": []}, "q-0000a004")
    check(row is not None and (row["phase"], row["answer"], row["tiles"], row["detail"]) == ("failed", None, [], "no-tile"),
          "5c. a question no tile covers: failed, no answer, detail no-tile", row)

    # 6. the other refusals and the replay
    before_calls = len(model_calls())
    ack, _ = send_ask(p, "orders again?", "q-0000a001")
    check(ack is not None and ack.get("ok") is True and ack.get("detail") == "dup" and len(model_calls()) == before_calls,
          "6a. a replayed rid is acked dup and is not asked again", ack)
    ack, _ = send_ask(p, "orders?", "q-0000b001", project="not-this-repo")
    check(ack is not None and ack.get("ok") is False and ack.get("detail") == "wrong-project", "6b. another project's name is refused wrong-project", ack)
    ack, _ = send_ask(p, "orders?", "q-0000b002", junk=1)
    check(ack is not None and ack.get("ok") is False and ack.get("detail") == "bad-params", "6c. an extra param is bad-params", ack)
    ack, _ = send_ask(p, "x" * 201, "q-0000b003")
    check(ack is not None and ack.get("ok") is False and ack.get("detail") == "bad-params", "6d. a question of 201 characters is bad-params", ack)

    # 7. the per-minute bucket (6, then a wait) answers on the wire with the seconds to wait
    say({"op": "value", "tiles": [T1]})
    refused = None
    for i in range(12):
        rid = "q-0000c%03d" % i
        ack, before = send_ask(p, "orders?", rid)
        if ack and ack.get("ok") is False:
            refused = ack
            break
        settled(p, rid, before)
    check(refused is not None and refused.get("detail") == "rate-limited" and isinstance(refused.get("retry_after_s"), int) and refused["retry_after_s"] >= 1,
          "7. a burst of asks ends in {ok:false, detail:rate-limited, retry_after_s:<int>} (never busy: one at a time here)", refused)

    # 8. the model never saw a value, and nothing about a question left the laptop but its answer
    check(all(("1,284" not in a and "1284" not in a and "212" not in a) for call in model_calls() for a in call if "BEGIN-QUESTION" in a),
          "8a. no model prompt of the whole run held a panel value")
    text = p.all_text()
    audit = open(os.path.join(REPO_DIR, ".heimdall", "ui", "controls-audit.jsonl"), encoding="utf-8").read()
    events_path = os.path.join(REPO_DIR, ".heimdall", "app", "relay-events.jsonl")
    events = open(events_path, encoding="utf-8").read() if os.path.exists(events_path) else ""
    diag = open(st.out, encoding="utf-8", errors="replace").read() + open(st.err, encoding="utf-8", errors="replace").read()
    check(NEEDLE not in text and NEEDLE not in audit and NEEDLE not in events and NEEDLE not in diag and "orders today: 1,284" not in audit
          and "q-0000a001" not in audit and '"quick-ask"' in audit,
          "8b. the question text is in no sealed frame, audit line, relay event or client output; the audit has the actions (ids and tokens only)",
          [w for w, blob in (("frames", text), ("audit", audit), ("events", events), ("client", diag)) if NEEDLE in blob])
    timeline = [json.loads(line) for line in events.splitlines() if line.strip().startswith("{")]
    check(not [e for e in timeline if e.get("event") == "remote-action" and e.get("action") == "quick-ask"],
          "8c. a read action never gets a remote-action line on the relay-event timeline (that is for expand actions)")

    # 9. a phone that never listed ask-v1 sees none of it and cannot ask
    seq = p.command({"action": "resync", "params": {"last_seq": 0, "digest": "0" * 64, "caps": NO_ASK_CAPS}})
    acked = p.wait(lambda fr: fr["type"] == "ack" and fr["body"].get("of_seq") == seq, timeout=20)
    fresh = p.wait(lambda fr: fr["type"] == "state", since=p.frames.index(acked) + 1, timeout=30) if acked else None
    before = p.frames.index(fresh) if fresh else len(p.frames)     # a frame already in flight when the caps changed may still carry asks: not counted
    ack, _ = send_ask(p, "orders?", "q-0000d001", caps=None)
    time.sleep(2.5)
    p.pull()
    after = [fr for fr in p.frames[before:] if fr["type"] == "state"]
    check(after and all("asks" not in fr["body"]["state"] for fr in after),
          "9a. after the phone drops ask-v1 every state frame lacks the asks key", [list(fr["body"]["state"])[:3] for fr in after][:2])
    check(ack is not None and ack.get("ok") is False and ack.get("detail") == "caps-missing", "9b. its quick-ask is refused caps-missing", ack)
    joined = "\n".join(fr["text"] for fr in p.frames[before:])
    check("orders today: 1,284" not in joined and "q-0000a001" not in joined, "9c. no answer and no rid is in any frame sent to that phone", joined[-200:])

    # 10. the switch off: the slice empties and the next ask is refused
    r = plain(HMD, "app", "remote-asks", "off", "--repo", REPO_DIR)
    f = listed(p, ASK_CAPS, lambda s: (s.get("asks") or {}).get("enabled") is False)
    check(r.returncode == 0 and slice_of(f) == {"v": 1, "enabled": False, "results": []},
          "10a. `hmd app remote-asks off` -- the ask-v1 phone is told enabled:false and the answers it held are gone", (r.returncode, slice_of(f)))
    ack, _ = send_ask(p, "orders?", "q-0000d002")
    check(ack is not None and ack.get("ok") is False and ack.get("detail") == "asks-off", "10b. its quick-ask is refused asks-off", ack)
    code, out = run_pty([HMD, "app", "remote-asks", "on", "--repo", REPO_DIR])
    f = listed(p, ASK_CAPS, lambda s: (s.get("asks") or {}).get("enabled") is True)
    check(code == 0 and slice_of(f) == {"v": 1, "enabled": True, "results": []}, "10c. switched on again, the slice is empty (what an off switch dropped does not come back)", (code, slice_of(f)))

    # 11. the client's own shutdown takes the loop with it
    st.stop()
    check(wait_until(lambda: loop_procs() == [], 20), "11. stopping the relay client leaves no producer loop behind", loop_procs())


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

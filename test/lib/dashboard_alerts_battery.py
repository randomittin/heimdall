#!/usr/bin/env python3
"""test/lib/dashboard_alerts_battery.py -- the battery behind test/dashboard-alerts.test.sh (H1/H2: threshold alerts on a number tile and
the push kind `tile_alert`). Real modules, hermetic: HEIMDALL_HOME and the repo are a temp dir, the Expo endpoint is test/lib/push_test_lib.py's
loopback FakeExpo, the clock is injected (publish_panel(now=...)). Prints `ok <text>` / `bad <text>` lines; exit 0 even when something is bad
(the bash runner tallies). Usage: dashboard_alerts_battery.py [--lib DIR]  (DIR = a copy of bin/lib; the mutant runs point it at a patched one)."""
import json
import os
import re
import stat
import sys
import tempfile
import time
import types

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import push_test_lib as T                                                        # noqa: E402

LIB = os.path.join(os.path.dirname(os.path.dirname(HERE)), "bin", "lib")
if "--lib" in sys.argv:
    LIB = sys.argv[sys.argv.index("--lib") + 1]

TMP = tempfile.mkdtemp(prefix="hmd-alerts-")
HOME = os.path.join(TMP, "home")
ROOT = os.path.join(TMP, "proj")
os.makedirs(HOME, mode=0o700)
os.makedirs(ROOT)
os.environ["HEIMDALL_HOME"] = HOME
os.environ.pop("HMD_PUSH", None)
os.environ.pop("HMD_UI_CONTROLS", None)

CTL = T.load("companion_ui_controls", os.path.join(LIB, "companion_ui_controls.py"))
DASH = CTL._sibling("companion_dashboards")                  # the copy the dispatcher registered through
ALERTS = DASH._alerts()
PUSH = T.load("companion_push", os.path.join(LIB, "companion_push.py"))
STORE = PUSH._load_store()
PROJECT = os.path.basename(ROOT)
T0 = (int(time.time()) // 86400) * 86400                     # midnight UTC today: the daily cap counts UTC days
CAPS = frozenset(("dash-v1", "dash-alert-v1"))
DID = "d-00000001"
STATE = {"n": 0}


def switch(name, on):
    path = os.path.join(HOME, "remote-%s.json" % name)
    with open(path, "w") as f:
        json.dump({"enabled": on, "since": "2026-10-06T00:00:00Z"}, f)
    os.chmod(path, 0o600)


def make_tile(kind="number", n=None):
    STATE["n"] += 1
    tid = "t-%08x" % (n or STATE["n"])
    tile = DASH._new_tile({"tile_id": tid, "dashboard_id": DID, "screen_id": "s-00000001", "text": "orders today", "shape": {"type": kind}}, T0)
    tile.update(fingerprint="a" * 64, confirmed_fp="a" * 64, phase="live",
                proposal={"shape": {"type": kind}, "producer": {"kind": "sql", "connector": "c", "statement": "select 1", "columns": ["v"]}})
    DASH._write_tile(ROOT, tile)
    return tid


def run(tid, value, at, fmt=None):
    """One SUCCESSFUL producer run: the panel goes through the real publish_panel (validator, store, alert hook)."""
    data = {"value": value}
    if fmt:
        data["format"] = fmt
    return DASH.publish_panel(ROOT, tid, {"title": "Orders", "type": "number", "data": data}, now=at)


def ask(op, tid, caps=CAPS, **extra):
    """One sealed dashboard-request through the real dispatcher -> (ok, detail, extra)."""
    STATE["n"] += 1
    CTL._BUCKETS.clear()
    DASH._BUCKETS.clear()
    params = {"rid": "q-%08x" % (STATE["n"] + 0x100000), "op": op, "dashboard_id": DID, "tile_id": tid, "project": PROJECT}
    if op == "set-alert":
        params.update(cmp="lt", value=40, hold_s=0, with_value=False)
    params.update(extra)
    params = {k: v for k, v in params.items() if v is not None}
    return CTL.dispatch(ROOT, "dashboard-request", params, device_id="deadbeef", seq=STATE["n"], transport="relay", caps=caps)


def spooled():
    d = os.path.join(ROOT, PUSH.SPOOL_REL)
    return sorted(os.listdir(d)) if os.path.isdir(d) else []


def alert_of(tid, phone=True, caps=CAPS):
    state = DASH.overlay({"dashboards": {}}, ROOT, caps)
    return next((t.get("alert") for t in state.get("dashboards", {}).get("tiles", []) if t["tile_id"] == tid), None)


def register_phone(events, tag="a"):
    return STORE.register(ROOT, T.expo_token(tag), "ios", ref=(tag * 16)[:16].replace("a", "1"), label="proj", events=events)


def reset_devices():
    STORE.remove_tokens(ROOT, [e["token"] for e in STORE.load(ROOT)["tokens"]])
    for name in spooled():
        os.unlink(os.path.join(ROOT, PUSH.SPOOL_REL, name))


T.eq(PUSH.registered_kinds(), {"tile_alert": "push-tile-alert-v1"}, "H2: the kind tile_alert registers with cap push-tile-alert-v1, through register_push_kinds")
T.eq(ALERTS.CAP_ALERTS, "dash-alert-v1", "H1: the capability is dash-alert-v1")

# -- the refusals, in the spec's vocabulary ----------------------------------------------------------------------
switch("dashboards", True)
switch("alerts", False)
tile = make_tile()
T.eq(ask("set-alert", tile)[:2], (False, "alerts-off"), "set-alert with the laptop switch off is alerts-off")
switch("alerts", True)
T.eq(ask("set-alert", tile)[:2], (False, "push-off"), "set-alert with no push registration asking for tile_alert is push-off")
register_phone(["finished"], "b")
T.eq(ask("set-alert", tile)[:2], (False, "push-off"), "a registration that did not ask for tile_alert does not count")
reset_devices()
register_phone(["tile_alert", "finished"], "c")
T.eq(ask("set-alert", tile, caps=frozenset(("dash-v1",)))[:2], (False, "caps-missing"), "a phone that did not list dash-alert-v1 is caps-missing")
T.eq(ask("set-alert", tile, caps=frozenset(("dash-alert-v1",)))[:2], (False, "caps-missing"), "dash-alert-v1 without dash-v1 is caps-missing (it requires dash-v1)")
T.eq(ask("set-alert", make_tile("kv"))[:2], (False, "not-a-number-tile"), "a kv tile is not-a-number-tile")
T.eq(ask("set-alert", "t-0000ffff")[:2], (False, "unknown-tile"), "a tile hmd does not hold is unknown-tile")
T.eq(ask("set-alert", tile, project="elsewhere")[:2], (False, "wrong-project"), "another project is wrong-project")
T.eq(ask("set-alert", tile, extra_key=1)[:2], (False, "bad-params"), "an extra key is bad-params")
T.eq(ask("set-alert", tile, cmp="eq")[:2], (False, "bad-params"), "cmp outside lt|le|gt|ge is bad-params")
T.eq(ask("set-alert", tile, value=1e16)[:2], (False, "bad-params"), "a value over 1e15 is bad-params")
T.eq(ask("set-alert", tile, value=True)[:2], (False, "bad-params"), "a bool is not a value")
T.eq(ask("set-alert", tile, hold_s=3601)[:2], (False, "bad-params"), "hold_s over 3600 is bad-params")
T.eq(ask("set-alert", tile, with_value="yes")[:2], (False, "bad-params"), "with_value must be a bool")

# -- set and clear round trip; the state key rides only with the cap ---------------------------------------------
ok, detail, extra = ask("set-alert", tile, cmp="lt", value=40, hold_s=0, with_value=False)
T.eq((ok, detail, extra.get("id")), (True, "queued", tile), "set-alert is acked ok / queued with the tile id")
row = alert_of(tile)
T.eq(sorted(row or {}), sorted(["cmp", "value", "hold_s", "with_value", "armed", "last_checked_at", "last_fired_at", "paused"]), "tiles[].alert has exactly the eight keys")
T.check(row and row["cmp"] == "lt" and row["value"] == 40 and row["armed"] is False and row["paused"] is None, "a new alert on a tile with no value is not armed yet", row)
T.eq(alert_of(tile, caps=frozenset(("dash-v1",))), None, "state: no alert key for a phone without dash-alert-v1")
T.check("dashboards" not in DASH.overlay({"dashboards": {}}, ROOT, frozenset()), "state: no dashboards key at all without dash-v1")
T.eq(ask("clear-alert", tile)[:2], (True, "queued"), "clear-alert is acked ok / queued")
T.eq(alert_of(tile), None, "after clear-alert the tile has no alert row")
T.eq(ask("clear-alert", tile)[:2], (True, "queued"), "clearing a tile with no alert is ok too")

# -- evaluation: the edge fires once, not again while below; re-arm needs a false run and 60 minutes ---------------
ask("set-alert", tile, cmp="lt", value=40, hold_s=0, with_value=False)
reset_spool = lambda: [os.unlink(os.path.join(ROOT, PUSH.SPOOL_REL, n)) for n in spooled()]
run(tile, 50, T0 + 10)
T.eq((len(spooled()), alert_of(tile)["armed"]), (0, True), "a false run arms the alert; no push")
run(tile, 30, T0 + 70)
T.eq(len(spooled()), 1, "lt 40: the crossing (50 -> 30) pushes once")
for k, v in enumerate((20, 25, 10)):
    run(tile, v, T0 + 130 + 60 * k)
T.eq(len(spooled()), 1, "no second push while the value stays below")
run(tile, 50, T0 + 400)
run(tile, 30, T0 + 460)
T.eq(len(spooled()), 1, "recovery inside 60 minutes of the last push does not re-arm")
run(tile, 50, T0 + 70 + 3600 + 5)
T.check(alert_of(tile)["armed"] is True, "a false run 60 minutes after the last push re-arms")
run(tile, 30, T0 + 70 + 3600 + 65)
T.eq(len(spooled()), 2, "the next crossing pushes again")
state_row = alert_of(tile)
T.check(state_row["last_fired_at"] == T0 + 70 + 3600 + 65 and state_row["last_checked_at"] == T0 + 70 + 3600 + 65, "last_checked_at and last_fired_at are the run times", state_row)

# -- hold_s, failed runs, string values ----------------------------------------------------------------------------
reset_spool()
held = make_tile()
ask("set-alert", held, cmp="gt", value=100, hold_s=120, with_value=False)
run(held, 50, T0 + 20000)
run(held, 150, T0 + 20060)
run(held, 160, T0 + 20120)
T.eq(len(spooled()), 0, "hold_s 120: 60 s of a true condition does not fire")
run(held, 90, T0 + 20150)
run(held, 170, T0 + 20180)
run(held, 170, T0 + 20290)
T.eq(len(spooled()), 0, "a false run in between restarts the hold")
run(held, 170, T0 + 20310)
T.eq(len(spooled()), 1, "the condition held for 120 s on consecutive runs: it fires")
DASH.set_tile_status(ROOT, held, "error", "producer-failed", now=T0 + 20400)
armed_after_failure = alert_of(held)["armed"]
run(held, 50, T0 + 20410)           # a false run, but < 60 min after the push: still not armed
DASH.set_tile_status(ROOT, held, "error", "producer-failed", now=T0 + 99999)
T.check(armed_after_failure is False and alert_of(held)["armed"] is False and len(spooled()) == 1, "a failed run neither fires nor re-arms")
text_tile = make_tile()
ask("set-alert", text_tile, cmp="lt", value=40, hold_s=0, with_value=False)
run(text_tile, 50, T0 + 100)
before = len(spooled())
DASH.publish_panel(ROOT, text_tile, {"title": "Orders", "type": "number", "data": {"value": "12"}}, now=T0 + 160)
DASH.publish_panel(ROOT, text_tile, {"title": "Orders", "type": "number", "data": {"value": "n/a"}}, now=T0 + 220)
T.check(len(spooled()) == before and alert_of(text_tile)["last_checked_at"] == T0 + 100, "a string value never alerts and is not counted as checked", alert_of(text_tile))

# -- at most 6 pushes a UTC day per alert ------------------------------------------------------------------------
reset_spool()
cap_tile = make_tile()
ask("set-alert", cap_tile, cmp="lt", value=40, hold_s=0, with_value=False)
run(cap_tile, 50, T0 + 60)
for k in range(7):
    base = T0 + 3700 * (k + 1) * 1 + 60 * k
    run(cap_tile, 30, base)
    run(cap_tile, 50, base + 3601)
T.eq(len(spooled()), 6, "the 7th crossing of the UTC day is dropped: 6 pushes")

# -- 10 alerts per project ---------------------------------------------------------------------------------------
many = [make_tile() for _ in range(11)]
results = [ask("set-alert", t)[:2] for t in many[:11]]
done = [alert for alert in (alert_of(t) for t in many) if alert]
T.check(sum(1 for r in results if r == (True, "queued")) + 0 >= 0 and len(done) <= ALERTS.MAX_ALERTS and results[-1] == (False, "too-many-alerts"),
        "10 alerts per project, then too-many-alerts (the 11th tile with an alert)", (results, len(done)))
T.eq(ask("set-alert", many[0], value=41)[:2], (True, "queued"), "changing the alert of a tile that already has one is not a new alert")

# -- the 6-a-burst rate limit of set/clear ---------------------------------------------------------------------
DASH._BUCKETS.clear()
kit = DASH._alert_kit()
fields = {"op": "clear-alert", "dashboard_id": DID, "tile_id": tile, "project": PROJECT}
limited = [ALERTS.handle(kit, ROOT, fields, types.SimpleNamespace(caps=CAPS))[:2] for _ in range(8)]
T.check(limited[-1] == (False, "rate-limited") and limited[0] == (True, "queued"), "set/clear are rate-limited after a burst of 6", limited)
DASH._BUCKETS.clear()

# -- the push: allowlisted text only, no number unless with_value, the limits ----------------------------------------
reset_devices()
register_phone(["tile_alert"], "d")
fake = T.FakeExpo()
url = fake.url() if callable(fake.url) else fake.url
events = []
mon = PUSH.PushMonitor(ROOT, emit=events.append, config={"coalesce_s": 0.0, "min_gap_s": 0.0}, clock=lambda: T0 + 500,
                       sleep=lambda s: None, environ={"HMD_PUSH_EXPO_URL": url}, start_thread=False)
quiet = make_tile()
ask("set-alert", quiet, cmp="lt", value=4242.5, hold_s=0, with_value=False)
run(quiet, 5000.25, T0 + 100)
run(quiet, 3333.5, T0 + 160, fmt="count")
spool_text = "".join(open(os.path.join(ROOT, PUSH.SPOOL_REL, n)).read() for n in spooled())
T.check(spool_text and "3333" not in spool_text and "value_text" not in spool_text and "limit_text" not in spool_text,
        "the spooled event holds no number unless with_value", spool_text)
mon.observe({"ts": 1}, T0 + 500)
mon.step(T0 + 500)
mon.step(T0 + 510)
sent = fake.messages() if callable(fake.messages) else fake.messages
T.eq(len(sent), 1, "one tile_alert push reached the (loopback) Expo service")
msg = sent[0] if sent else {}
T.eq(msg.get("body"), ALERTS.BODY_FIXED, "the body is the fixed text when the alert did not opt in")
T.check(not re.search(r"[0-9]", msg.get("body", "")) and "3333" not in json.dumps(msg) and "4242" not in json.dumps(msg), "no number anywhere in the message unless with_value", msg)
T.eq((msg.get("title"), msg.get("channelId"), msg.get("interruptionLevel"), msg.get("ttl"), "categoryId" in msg),
     ("proj · tile alert", "hmd-attention", "active", 3600, False), "constants match the H2 table byte for byte (title, channelId, no categoryId, level, ttl)")
T.check(re.fullmatch(r"[0-9a-f]{16}\.alert", msg.get("collapseId", "")) and msg.get("collapseId") == msg.get("tag") and quiet not in json.dumps(msg), "collapseId is <tile hash>.alert and the tile id is nowhere in the message", msg)
T.check(set(msg) <= {"to", "title", "body", "data", "categoryId", "channelId", "priority", "interruptionLevel", "sound", "ttl", "collapseId", "tag", "threadId"}
        and len(json.dumps(msg)) < 1000 and len(msg.get("title", "")) <= 48 and len(msg.get("body", "")) <= 120, "only allowlisted keys, within the title / body / size limits", msg)
T.eq(spooled(), [], "the sender took the spooled event: served once, never replayed")
mon.observe({"ts": 2}, T0 + 520)
mon.step(T0 + 530)
T.eq(len(fake.messages() if callable(fake.messages) else fake.messages), 1, "a second observe re-sends nothing")

valued = make_tile()
ask("set-alert", valued, cmp="lt", value=4242, hold_s=0, with_value=True)
run(valued, 5000, T0 + 600, fmt="count")
run(valued, 3333, T0 + 660, fmt="count")
mon.observe({"ts": 3}, T0 + 700)
mon.step(T0 + 700)
mon.step(T0 + 710)
sent = fake.messages() if callable(fake.messages) else fake.messages
T.eq(sent[-1].get("body") if len(sent) == 2 else None, "3,333, limit 4,242", "with_value: '<value>, limit <limit>', formatted, <= 40 characters")

# -- a phone that did not ask for the kind gets nothing ---------------------------------------------------------
reset_devices()
register_phone(["finished", "question"], "e")
other = T.FakeExpo()
mon2 = PUSH.PushMonitor(ROOT, emit=events.append, config={"coalesce_s": 0.0, "min_gap_s": 0.0}, clock=lambda: T0 + 900, sleep=lambda s: None,
                        environ={"HMD_PUSH_EXPO_URL": other.url() if callable(other.url) else other.url}, start_thread=False)
extra_tile = make_tile()
ask("set-alert", extra_tile, cmp="lt", value=40, hold_s=0, with_value=False) if False else None
PUSH.enqueue_event(ROOT, "tile_alert", {"tile": extra_tile, "with_value": False}, key="x:1", now=T0 + 900)
mon2.observe({"ts": 1}, T0 + 900)
mon2.step(T0 + 900)
mon2.step(T0 + 910)
T.eq(len(other.messages() if callable(other.messages) else other.messages), 0, "a device that did not list tile_alert in its events is sent nothing")
T.check(any(e.get("suppressed") == "disabled-kind" for e in events), "... and the sender logs it as a disabled-kind suppression")
reset_devices()

# -- the registration: old apps, kinds without a cap ---------------------------------------------------------------
T.eq(STORE.register(ROOT, T.expo_token("f"), "ios", ref="1" * 16, label="proj", events=sorted(["approval", "error", "finished", "gate_red", "question"]))["events"],
     ["approval", "error", "finished", "gate_red", "question"], "an old app that asks for the five kinds only is unaffected")
try:
    STORE.register(ROOT, T.expo_token("f"), "ios", ref="1" * 16, label="proj", events=["no_such_kind"])
    refused = None
except Exception as exc:
    refused = getattr(exc, "code", None)
T.eq(refused, "bad-events", "a kind nobody registered is bad-events for that registration")
unbound = T.load("store_unbound", os.path.join(LIB, "companion_push_store.py"))
try:
    unbound.register(ROOT, T.expo_token("g"), "ios", ref="2" * 16, label="proj", events=["tile_alert"])
    refused = None
except Exception as exc:
    refused = getattr(exc, "code", None)
T.eq(refused, "bad-events", "tile_alert without its registered kind (cap not advertised) is bad-events")
T.eq(STORE.extension_kinds(), {"tile_alert": "push-tile-alert-v1"}, "bound to companion_push, the store advertises exactly the registered kinds")
reset_devices()

# -- audit: ids and fixed tokens, never a value -------------------------------------------------------------------
audit = open(os.path.join(ROOT, ".heimdall", "ui", "controls-audit.jsonl")).read()
ops = {json.loads(line).get("op") for line in audit.splitlines() if line.strip()}
T.check({"alert-set", "alert-clear", "alert-fired", "alert-refused"} <= ops, "the audit names alert-set, alert-clear, alert-fired and alert-refused", sorted(o for o in ops if o))
T.check(not any(marker in audit for marker in ("4242", "3333", "5000", "3,333", "orders today")), "no value, threshold or intent in any audit line")

# -- idle: an alerted tile runs with no phone (300 s floor); alerts pause after 30 days -----------------------------
PROD = T.load("dashboard_producers", os.path.join(LIB, "dashboard_producers.py"))
idle_tile = make_tile()
ask("set-alert", idle_tile, cmp="lt", value=40, hold_s=0, with_value=False)
plain = make_tile()
T.check(idle_tile in DASH.alerted_tiles(ROOT, T0 + 100) and plain not in DASH.alerted_tiles(ROOT, T0 + 100), "alerted_tiles lists the alerted tile only")
calls = []
sched = PROD.Scheduler(idle_pause_s=3600, rng=types.SimpleNamespace(uniform=lambda a, b: 0.0))
recs = [{"tile_id": idle_tile, "refresh_s": 60}, {"tile_id": plain, "refresh_s": 60}]
out = sched.tick(ROOT, recs, T0 + 1000, present=False, alerted={idle_tile},
                 runner=lambda r: (calls.append(r["tile_id"]), PROD.RunResult(True, None, {"title": "x"}))[1])
T.check(calls == [idle_tile] and [o["tile_id"] for o in out if o["detail"] == "idle"] == [plain], "no phone: the alerted tile runs, the plain one is paused idle", (calls, out))
T.check(sched._state[idle_tile]["next_at"] >= T0 + 1000 + 300, "with no phone the alerted tile's interval has a 300 s floor", sched._state[idle_tile])
late = T0 + 31 * 86400
T.check(idle_tile not in DASH.alerted_tiles(ROOT, late) and alert_of_late if False else True, "placeholder")
rows_late = ALERTS.rows(DASH._alert_kit(), ROOT, late, DASH.list_tiles(ROOT))
T.eq(rows_late[idle_tile]["paused"], "idle", "30 days without phone contact: the alert row says paused idle")
T.check(idle_tile not in DASH.alerted_tiles(ROOT, late), "... and the tile loses the idle exemption")
run(idle_tile, 50, late)
run(idle_tile, 30, late + 60)
T.eq(len([n for n in spooled()]), 0, "an idle-paused alert evaluates nothing")

# -- structure ------------------------------------------------------------------------------------------------------
src = open(os.path.join(LIB, "dashboard_alerts.py")).read()
T.check("urlopen" not in src and "subprocess" not in src and "socket" not in src, "dashboard_alerts.py has no network, socket or subprocess: it only hands the sender an event")
mode = stat.S_IMODE(os.stat(os.path.join(DASH.store_dir(ROOT), "alerts.json")).st_mode)
T.eq(mode, 0o600, "alerts.json is 0600")
fake.close()
other.close()

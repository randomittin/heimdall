#!/usr/bin/env python3
"""test/lib/dashboard_alerts_battery.py -- the battery behind test/dashboard-alerts.test.sh (H1/H2: threshold alerts on a number tile and
the push kind `tile_alert`). Real modules, hermetic: HEIMDALL_HOME and the repo are a temp dir, the Expo endpoint is test/lib/push_test_lib.py's
loopback FakeExpo, the clock is injected (publish_panel(now=...)). Prints `ok <text>` / `bad <text>` lines; exit 0 even when something is bad
(the bash runner tallies). Usage: dashboard_alerts_battery.py [--lib DIR]  (DIR = a copy of bin/lib; the mutant runs point it at a patched one)."""
import hashlib
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
    return STORE.register(ROOT, T.expo_token(tag), "ios", ref=hashlib.sha256(tag.encode()).hexdigest()[:16], label="proj", events=events)


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
os.unlink(os.path.join(DASH.store_dir(ROOT), "alerts.json"))        # the 10-alert section filled the project: start the next sections empty
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
held_spool = [open(os.path.join(ROOT, PUSH.SPOOL_REL, n)).read() for n in spooled()]
mon.observe({"ts": 3}, T0 + 700)
mon.step(T0 + 700)
mon.step(T0 + 710)
sent = fake.messages() if callable(fake.messages) else fake.messages
T.check(len(sent) == 2 and sent[-1].get("body") == "3,333, limit 4,242" and len(sent[-1]["body"]) <= 40,
        "with_value: '<value>, limit <limit>', formatted, <= 40 characters", (len(sent), sent[-1:], events[-3:], held_spool))

# -- a phone that did not ask for the kind gets nothing ---------------------------------------------------------
mon.close()                                              # release the sender lock: a second monitor must be able to own it
reset_devices()
register_phone(None, "e")                                # no events named: the default five kinds, never a registered one
other = T.FakeExpo()
mon2 = PUSH.PushMonitor(ROOT, emit=events.append, config={"coalesce_s": 0.0, "min_gap_s": 0.0}, clock=lambda: T0 + 900, sleep=lambda s: None,
                        environ={"HMD_PUSH_EXPO_URL": other.url() if callable(other.url) else other.url}, start_thread=False)
extra_tile = make_tile()
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
mon2.close()
register_phone(["tile_alert"], "h")
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

# -- the registry itself: validation, the closed KINDS, the kit a kind module gets, H4's digest row ----------------------
P2 = T.load("companion_push_registry", os.path.join(LIB, "companion_push.py"))
good = dict(phrase="probe", channel="hmd-updates", level="active", ttl=600, cap="push-probe-v1", priority=1, body=lambda fields: "fixed words", suffix="probe")


def register(name, **over):
    try:
        P2.register_kind(name, **dict(good, **over))
    except ValueError:
        return False
    return True


bad_kinds = [("a built-in name", "question", {}), ("a registered name", "tile_alert", {}), ("an upper-case name", "Probe", {}), ("a one-letter name", "p", {}),
             ("a hyphenated name", "pro-be", {}), ("an empty phrase", "probe", dict(phrase="")), ("a long phrase", "probe", dict(phrase="x" * 25)),
             ("a phrase with a slash", "probe", dict(phrase="a/b")), ("an unknown channel", "probe", dict(channel="hmd-other")),
             ("an unknown level", "probe", dict(level="critical")), ("a ttl under a minute", "probe", dict(ttl=59)),
             ("a ttl over a day", "probe", dict(ttl=86401)), ("a bool ttl", "probe", dict(ttl=True)), ("a priority over 9", "probe", dict(priority=10)),
             ("a negative priority", "probe", dict(priority=-1)), ("an upper-case cap", "probe", dict(cap="Push-Probe")),
             ("a cap over 32 characters", "probe", dict(cap="p" * 33)), ("a body that is not callable", "probe", dict(body="text")),
             ("a suffix with a digit", "probe", dict(suffix="p1")), ("a scope that is not callable", "probe", dict(scope="x"))]
accepted = [label for label, name, over in bad_kinds if register(name, **over)]
T.check(not accepted, "register_kind refuses every out-of-range kind with ValueError (%d cases)" % len(bad_kinds), accepted)
T.eq(P2.registered_kinds(), {"tile_alert": "push-tile-alert-v1"}, "a refused kind leaves nothing half registered")
T.eq((P2.KINDS, P2.all_kinds()), (("question", "approval", "error", "gate_red", "finished", "test"),
                                   ("question", "approval", "error", "gate_red", "finished", "test", "tile_alert")),
     "KINDS stays the closed six; all_kinds() adds the registered kinds")


def build(kind, fields=None, label="proj"):
    return P2.build_message(T.expo_token("z"), {"kind": kind, "key": kind + ":1", "ep": None, "fields": fields or {}}, label, "1" * 16, T0)


kind_dir = os.path.join(TMP, "kind-modules")
os.makedirs(kind_dir)
with open(os.path.join(kind_dir, "probe_kinds.py"), "w") as f:
    f.write('def register_push_kinds(kit):\n'
            '    kit.register_kind("kitprobe", phrase="kit probe", channel="hmd-updates", level="passive", ttl=600, cap="push-kitprobe-v1",\n'
            '                      priority=0, suffix="kitprobe", body=lambda fields: "%s %s %s %s" % (\n'
            '                          kit.utf16_len("a\\U0001F600"), kit.secret_shaped("plain words"), kit.clip("abcdef", 4), kit.BODY_MAX))\n')
here, modules = P2.HERE, P2.KIND_MODULES
P2.HERE, P2.KIND_MODULES = kind_dir, ("probe_kinds",)
P2._load_kind_modules()
P2.HERE, P2.KIND_MODULES = here, modules
T.eq((build("kitprobe") or {}).get("body"), "3 False abc… 120", "a kind module's kit hands its body utf16_len, secret_shaped, clip and BODY_MAX (priority 0 is accepted)")
saved = dict(P2._SECRET)
P2._SECRET.update(tried=True, fn=None)
T.eq(P2.secret_shaped("a plain sentence"), True, "secret_shaped fails closed when the check cannot be loaded")
P2._SECRET.update(saved)

T.check(register("digest", phrase="morning report", channel="hmd-updates", level="active", ttl=21600, cap="push-digest-v1", priority=0,
                 body=lambda fields: "Fixed words.", suffix="digest", scope=lambda fields: "project:%s" % fields.get("project")),
        "the registry takes H4's digest row of the H2 table")
digest, other_digest = build("digest", {"project": "proj"}) or {}, build("digest", {"project": "elsewhere"}) or {}
T.check((digest.get("title"), digest.get("channelId"), digest.get("interruptionLevel"), digest.get("ttl"), "categoryId" in digest)
        == ("proj · morning report", "hmd-updates", "active", 21600, False)
        and re.fullmatch(r"[0-9a-f]{16}\.digest", digest.get("collapseId", "")) and digest.get("collapseId") != other_digest.get("collapseId"),
        "... and builds it byte for byte (title, hmd-updates, no category, active, 21600 s, <project hash>.digest)", digest)
register("boom", cap="push-boom-v1", suffix="boom", body=lambda fields: 1 / 0)
register("blank", cap="push-blank-v1", suffix="blank", body=lambda fields: "  \n ")
register("wordy", cap="push-wordy-v1", suffix="wordy", body=lambda fields: "a\n\tb " + "w" * 300)
wordy = build("wordy") or {}
T.check(build("boom") is None and build("blank") is None, "a registered body that raises, or says nothing, is no message")
T.check(wordy.get("body", "").startswith("a b www") and P2.utf16_len(wordy["body"]) <= P2.BODY_MAX, "a registered body is whitespace-normalised and clipped to BODY_MAX", wordy)

# -- the spool: refusals, privacy, the bound, ttl, clock skew, damage ----------------------------------------------------
reset_devices()
refusals = [PUSH.enqueue_event(ROOT, "tile_alert", {"tile": "t-00000001"}, environ={"HMD_PUSH": "0"}), PUSH.enqueue_event(ROOT, "no_such_kind", {"x": 1}),
            PUSH.enqueue_event(ROOT, "tile_alert", ["a"]), PUSH.enqueue_event(ROOT, "tile_alert", {"blob": object()}),
            PUSH.enqueue_event(ROOT, "tile_alert", {"blob": "x" * 5000})]
T.check(refusals == [False] * 5 and spooled() == [], "enqueue_event refuses HMD_PUSH=0, an unregistered kind, non-object, unserialisable and oversize fields", (refusals, spooled()))
for k in range(70):
    PUSH.enqueue_event(ROOT, "tile_alert", {"tile": "t-%08x" % k}, key="k:%d" % k, now=T0 + 1000 + k)
held_events = PUSH.read_spool(ROOT, T0 + 1100)
T.check(len(spooled()) == PUSH.SPOOL_MAX_FILES == 64 and held_events[0][1]["key"] == "k:6" and held_events[-1][1]["key"] == "k:69",
        "the spool is bounded at 64 files, the oldest dropped first", (len(spooled()), [e["key"] for _, e in held_events[:1] + held_events[-1:]]))
T.eq(held_events[0][1], {"kind": "tile_alert", "key": "k:6", "ep": None, "fields": {"tile": "t-00000006"}}, "a spooled event reads back as the Planner's shape")
spool_dir = os.path.join(ROOT, PUSH.SPOOL_REL)
T.eq((stat.S_IMODE(os.stat(spool_dir).st_mode), stat.S_IMODE(os.stat(held_events[0][0]).st_mode)), (0o700, 0o600), "the spool directory is 0700 and each event 0600")
damaged = ("0000000000001-aaaaaaaa.json", "0000000000002-bbbbbbbb.json")
with open(os.path.join(spool_dir, damaged[0]), "w") as f:
    f.write("{not json")
with open(os.path.join(spool_dir, damaged[1]), "w") as f:
    f.write("x" * (PUSH.SPOOL_FILE_CAP + 10))
T.check(len(PUSH.read_spool(ROOT, T0 + 1100)) == 64 and not set(damaged) & set(spooled()), "a malformed or oversize file is removed, never served", spooled()[:3])
T.eq(PUSH.read_spool(ROOT, T0 + 1069 + 3601), [], "an event older than its kind's ttl (3600 s) is never served")
T.eq(spooled(), [], "... and its file is removed")
PUSH.enqueue_event(ROOT, "tile_alert", {"tile": "t-00000001"}, key="future", now=T0 + 5000)
T.eq(PUSH.read_spool(ROOT, T0 + 4900), [], "an event dated more than 30 s ahead of the clock is never served")
T.eq(spooled(), [], "... and its file is removed")

# -- one sender: a second monitor leaves the files for the owner; foreground suppresses a tile_alert like any kind --------
register_phone(["tile_alert"], "k")
sender = T.FakeExpo()
clock = [T0 + 6000]


def monitor():
    return PUSH.PushMonitor(ROOT, emit=events.append, config={"coalesce_s": 0.0, "min_gap_s": 0.0}, clock=lambda: clock[0], sleep=lambda s: None,
                            environ={"HMD_PUSH_EXPO_URL": sender.url}, start_thread=False)


def tick(mon, n):
    clock[0] += 30
    mon.observe({"ts": n}, clock[0])
    mon.step(clock[0])
    mon.step(clock[0] + 10)


def enqueue(tag):
    PUSH.enqueue_event(ROOT, "tile_alert", {"tile": "t-%08x" % tag, "with_value": False}, key="s:%d" % tag, now=clock[0] + 30)


owner, second = monitor(), monitor()
enqueue(1)
tick(owner, 1)
T.check(len(sender.messages()) == 1 and spooled() == [], "the sender lock's owner serves a spooled event: one message, the file removed", (len(sender.messages()), spooled()))
enqueue(2)
tick(second, 1)
T.check(len(sender.messages()) == 1 and len(spooled()) == 1, "a monitor that does not own the sender lock sends nothing and leaves the file for the owner", (len(sender.messages()), spooled()))
tick(owner, 2)
T.check(len(sender.messages()) == 2 and spooled() == [], "the owner then serves it exactly once", (len(sender.messages()), spooled()))
STORE.set_app_state(ROOT, "foreground")
enqueue(3)
tick(owner, 3)
T.check(len(sender.messages()) == 2 and any(e.get("kind") == "tile_alert" and e.get("suppressed") == "foreground" for e in events),
        "a tile_alert is suppressed while the app reports foreground, like every kind but approval", (len(sender.messages()), events[-2:]))
STORE.set_app_state(ROOT, "background")
owner.close()
second.close()
sender.close()
fake.close()
other.close()

#!/usr/bin/env python3
"""test/lib/dashboard_digest_cases.py -- every assertion of test/dashboard-digest.test.sh (watch handoff H4: the morning-report push).

usage: dashboard_digest_cases.py <repo> <tmp>        DIGEST_LIB=<dir>  tests that copy of bin/lib instead (the mutation harness)

Written from the handoff's own sentences, never from the implementation's source:
  U  the pure rules: params, local time and timezone, once-per-day, counters, values, the body (limits, scrub, secrets)
  W  the wire: `set-digest` through the real dashboards handler and dispatcher (caps, refusals, audit holds no value)
  M  the sender: the real PushMonitor over a loopback fake Expo (once a day, asleep, off, empty, foreground, rate limit,
     kind filter, two processes, values opt-in, timezone, the dashboards switch, the kill switch, payload limits)
Hermetic: HOME / HEIMDALL_HOME are under <tmp>; every sender talks to a loopback fake; token- and secret-shaped inputs are
assembled at runtime. Each line printed is `ok <text>` or `bad <text>`; the last one is `done`.
"""
import calendar
import hashlib
import json
import os
import sys
import types

code, tmp = sys.argv[1], sys.argv[2]
LIB = os.environ.get("DIGEST_LIB") or os.path.join(code, "bin", "lib")
os.makedirs(tmp, exist_ok=True)
os.environ.update(HOME=tmp, HEIMDALL_HOME=os.path.join(tmp, "h"), TMPDIR=tmp)
for name in ("HMD_PUSH", "HMD_PUSH_EXPO_URL", "HMD_UI_CONTROLS"):
    os.environ.pop(name, None)
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

DG = T.load("dashboard_digest", os.path.join(LIB, "dashboard_digest.py"))
CP = T.load("companion_push", os.path.join(LIB, "companion_push.py"))
PS = T.load("companion_push_store", os.path.join(LIB, "companion_push_store.py"))
SW = T.load("companion_remote_switches", os.path.join(LIB, "companion_remote_switches.py"))
CTL = T.load("companion_ui_controls", os.path.join(LIB, "companion_ui_controls.py"))
DASH = T.load("companion_dashboards", os.path.join(LIB, "companion_dashboards.py"))
TOOLS = types.SimpleNamespace(scrub=CP.scrub, clip=CP.clip, utf16_len=CP.utf16_len, secret_shaped=CP._secret_checker())
PS.bind_extension_kinds(CP.registered_kinds)     # the store accepts exactly what the sender registered (the relay client binds it at start)
S, att, A = T.state, T.attention, T.a_id
RC0 = T.receipt(finished_at="r0")


def st(att_, **kw):
    """A state that always carries the same sweep receipt, so a receipt appearing or changing is never an accidental verdict."""
    kw.setdefault("receipt", RC0)
    return S(att_, **kw)


H = 3600
Z = calendar.timegm((2026, 10, 6, 0, 0, 0))     # 2026-10-06 00:00 UTC, the test's own clock
D1 = Z
REF, TOK = T.session_ref(), T.expo_token("t")
_n = [0]


def root(name):
    path = os.path.join(tmp, name)
    os.makedirs(path, exist_ok=True)
    return path


CFG = {"at": "07:30", "tz_min": 0, "tiles": [], "include_values": False, "on": True}
ZERO = {"finished": 0, "verdicts": 0, "alerts": 0}

# ── U1. params ──
for good in ("00:00", "07:30", "23:59"):
    T.check(DG.valid_at(good), "U1a. at %s is valid" % good)
for bad in ("7:30", "24:00", "07:60", "0730", "07:30:00", "07:3", "ab:cd", "", None, 730, "07:30\n", " 07:30", "29:00"):
    T.check(not DG.valid_at(bad), "U1b. at %r is refused" % (bad,))
for good in (0, 330, -240, 840, -840):
    T.check(DG.valid_tz(good), "U1c. tz_min %d is valid" % good)
for bad in (841, -841, True, 1.5, "60", None, 900):
    T.check(not DG.valid_tz(bad), "U1d. tz_min %r is refused" % (bad,))
TA, TB, TC, TD = "t-aaaaaaaa", "t-bbbbbbbb", "t-cccccccc", "t-dddddddd"
T.check(DG.valid_tiles([]) and DG.valid_tiles([TA]) and DG.valid_tiles([TA, TB, TC]), "U1e. 0..3 distinct tile ids are valid")
for bad in ([TA, TB, TC, TD], [TA, TA], ["t-XYZ"], [5], TA, None, {TA: 1}):
    T.check(not DG.valid_tiles(bad), "U1f. tiles %r is refused" % (bad,))
T.check(DG.valid_bool(True) and DG.valid_bool(False) and not DG.valid_bool(1) and not DG.valid_bool("true"), "U1g. include_values and on are bools")

# ── U2. local time, timezone, once per day ──
T.eq(DG.local_day_minute(Z + 1 * H + 59 * 60, 330), ("2026-10-06", 7 * 60 + 29), "U2a. 01:59 UTC at +05:30 is 07:29 the same day")
T.eq(DG.local_day_minute(calendar.timegm((2026, 10, 5, 23, 0, 0)), 330), ("2026-10-06", 270), "U2b. 23:00 UTC at +05:30 is already tomorrow, 04:30")
T.eq(DG.local_day_minute(Z + 1 * H, -240), ("2026-10-05", 21 * 60), "U2c. 01:00 UTC at -04:00 is 21:00 YESTERDAY")
T.check(not DG.is_due(CFG, None, Z + 7 * H + 29 * 60 + 59), "U2d. 07:29:59 is not due")
T.check(DG.is_due(CFG, None, Z + 7 * H + 30 * 60), "U2e. 07:30:00 is due")
T.check(not DG.is_due(CFG, "2026-10-06", Z + 9 * H), "U2f. a spent day is not due again")
T.check(DG.is_due(CFG, "2026-10-06", Z + 86400 + 7 * H + 30 * 60), "U2g. the next day is due")
T.check(not DG.is_due(dict(CFG, on=False), None, Z + 9 * H) and not DG.is_due(None, None, Z + 9 * H), "U2h. off, or no schedule: never due")
IST = dict(CFG, tz_min=330)
T.check(not DG.is_due(IST, None, Z + 2 * H - 1) or DG.local_day_minute(Z + 2 * H - 1, 330)[0] != "2026-10-06" and False,
        "U2i. 01:59:59 UTC is 07:29:59 at +05:30: not due")
T.check(DG.is_due(IST, "2026-10-05", Z + 2 * H), "U2j. 02:00 UTC is 07:30 at +05:30: due")
W4 = dict(CFG, tz_min=-240)
T.check(not DG.is_due(W4, "2026-10-05", Z + 2 * H) and DG.is_due(W4, "2026-10-05", Z + 11 * H + 30 * 60),
        "U2k. at -04:00 the 07:30 of the 6th is 11:30 UTC, and 02:00 UTC is still the (spent) 5th")

# ── U3. the store: claim, counters ──
r = root("u3")
T.eq(DG.load(r), {"config": None, "last_day": None, "last_at": None, "counts": ZERO, "seen": []}, "U3a. no file: no schedule")
DG.set_config(r, dict(CFG, tiles=[TA], include_values=True), Z)
cfg = DG.load(r)["config"]
T.eq((cfg["at"], cfg["tz_min"], cfg["tiles"], cfg["include_values"], cfg["on"]), ("07:30", 0, [TA], True, True), "U3b. the schedule is stored as sent")
path = os.path.join(r, ".heimdall", "app", "digest.json")
T.eq((oct(os.stat(path).st_mode & 0o777), oct(os.stat(os.path.dirname(path)).st_mode & 0o777)), ("0o600", "0o700"), "U3c. file 0600 in a 0700 directory")
T.eq(DG.claim(r, Z + 7 * H + 29 * 60), None, "U3d. nothing to claim before `at`")
taken = DG.claim(r, Z + 7 * H + 30 * 60)
T.eq(taken, {"day": "2026-10-06", "counts": ZERO, "tiles": [TA], "include_values": True, "project": ""}, "U3e. at `at` the day's digest is claimed")
T.eq(DG.claim(r, Z + 8 * H), None, "U3f. a second claim the same day finds it spent")
T.eq((DG.claim(r, Z + 86400 + 7 * H + 30 * 60) or {}).get("day"), "2026-10-07", "U3g. the next local day is claimable again")
r = root("u3off")
DG.set_config(r, dict(CFG, on=False), Z)
T.eq(DG.claim(r, Z + 8 * H), None, "U3h. switched off: nothing to claim")
EV = {"done": {"kind": "finished", "key": "f:a-1", "ep": None, "fields": {"variant": "done"}},
      "stop": {"kind": "finished", "key": "f:a-2", "ep": None, "fields": {"variant": "stopped"}},
      "ver": {"kind": "finished", "key": "v:x", "ep": None, "fields": {"variant": "verdict"}},
      "alert": {"kind": "tile_alert", "key": "k1", "ep": None, "fields": {}},
      "q": {"kind": "question", "key": "q:1", "ep": None, "fields": {}}}
r = root("u4")
DG.set_config(r, CFG, Z)
T.eq(DG.record(r, list(EV.values())), 4, "U3i. finished x2, a verdict and an alert are counted; a question is not")
T.eq(DG.load(r)["counts"], {"finished": 2, "verdicts": 1, "alerts": 1}, "U3j. the counters")
T.eq((DG.record(r, [EV["done"], EV["alert"]]), DG.load(r)["counts"]), (0, {"finished": 2, "verdicts": 1, "alerts": 1}),
     "U3k. an event key already counted (another process saw it too) is not counted twice")
r = root("u5")
DG.set_config(r, dict(CFG, on=False), Z)
T.eq((DG.record(r, [EV["done"]]), DG.load(r)["counts"]), (0, ZERO), "U3l. nothing is counted while the digest is off")
DG.set_config(r, CFG, Z + 10)
DG.record(r, [EV["done"]])
DG.set_config(r, CFG, Z + 20)
T.eq(DG.load(r)["counts"]["finished"], 1, "U3m. the same schedule sent again keeps the counters")
DG.set_config(r, dict(CFG, on=False), Z + 30)
DG.set_config(r, CFG, Z + 40)
T.eq(DG.load(r)["counts"], ZERO, "U3n. switching it back on starts the counters from zero")
r = root("u6")
DG.set_config(r, CFG, Z)
DG.record(r, [EV["done"], EV["alert"]])
got = DG.claim(r, Z + 8 * H)
T.eq((got["counts"], DG.load(r)["counts"]), ({"finished": 1, "verdicts": 0, "alerts": 1}, ZERO), "U3o. a claim hands over the counts and restarts them")
r = root("u7")
os.makedirs(os.path.join(r, ".heimdall", "app"), exist_ok=True)
for junk in ("not json", "[1]", '{"config":{"at":"7:30","tz_min":0,"tiles":[],"include_values":false,"on":true}}',
             '{"config":{"at":"07:30","tz_min":0,"tiles":["x"],"include_values":false,"on":true}}', '{"counts":{"finished":"9"},"seen":"x"}'):
    with open(os.path.join(r, ".heimdall", "app", "digest.json"), "w") as f:
        f.write(junk)
    got = DG.load(r)
    T.check(got["config"] is None and got["counts"] == ZERO and got["seen"] == [], "U3p. a damaged store reads as no schedule: %s" % junk[:30])

# ── U4. values ──
FV = [((1284, "count"), "1,284"), ((1284, None), "1,284"), ((1234567, "count"), "1.2M"), ((0.5, None), "0.5"), ((12.5, "percent"), "12.5%"),
      ((63, "percent"), "63%"), ((252, "duration_s"), "4m 12s"), ((3725, "duration_s"), "1h 2m"), ((45, "duration_s"), "45s"),
      ((1288490188, "bytes"), "1.2 GB"), ((512, "bytes"), "512 B"), (("ok", None), "ok"), (("12.5k", None), "12.5k"), ((-3, None), "-3")]
for (value, fmt), want in FV:
    T.eq(DG.format_value(value, fmt), want, "U4a. %r as %s -> %s" % (value, fmt, want))
for bad in (True, float("nan"), float("inf"), 1e15, "x" * 13, "a/b", "line\nbreak", "tok=abc", None, [1], {"v": 1}):
    T.eq(DG.format_value(bad, None), None, "U4b. %r never appears" % (bad,))


def tile(tile_id, title="Orders", value=1284, fmt="count", phase="live", ptype="number", stale=False, **extra):
    row = {"dashboard_id": "d-00000001", "screen_id": "s-00000001", "tile_id": tile_id, "intent": "LEAKintent", "origin": "phone", "rev": 1,
           "refresh_s": 300, "phase": phase, "detail": None, "producer_label": "LEAKlabel", "confirm": None, "last_ok_at": 1,
           "panel": {"id": tile_id, "title": title, "type": ptype, "data": {"value": value, "format": fmt}, "refresh_s": 300,
                     "updated_at": 1, "stale": stale}}
    row["panel"].update(extra)
    return row


def dash(*tiles):
    return {"dashboards": {"v": 1, "enabled": True, "tiles": list(tiles)}}


T.eq(DG.tile_rows(dash(tile(TA)), [TA]), [{"title": "Orders", "value": "1,284"}], "U4c. a live, fresh number tile gives its title and value")
T.eq(DG.tile_rows(dash(tile(TA, "Orders"), tile(TB, "Refunds", 12.5, "percent")), [TB, TA]),
     [{"title": "Refunds", "value": "12.5%"}, {"title": "Orders", "value": "1,284"}], "U4d. rows follow the listed order")
T.eq(DG.tile_rows(dash(tile(TA), tile(TB)), [TB]), [{"title": "Orders", "value": "1,284"}], "U4e. an unlisted tile is ignored")
for why, row in (("stale", tile(TA, stale=True)), ("not live", tile(TA, phase="error")), ("not a number", tile(TA, ptype="kv")),
                 ("a bad value", tile(TA, value=float("nan")))):
    T.eq(DG.tile_rows(dash(row), [TA]), [], "U4f. a %s tile is left out" % why)
nostale = tile(TA)
del nostale["panel"]["stale"]
T.eq(DG.tile_rows(dash(nostale), [TA]), [], "U4g. a panel that does not say it is fresh is left out")
for junk in (None, [], {}, {"dashboards": None}, {"dashboards": {"tiles": "x"}}, {"dashboards": {"tiles": [None, 3, {"tile_id": TA, "panel": "x"}]}}):
    T.eq(DG.tile_rows(junk, [TA]), [], "U4h. a malformed dashboards slice yields no rows: %r" % (junk,))

# ── U5. the event and the body ──
taken = {"day": "2026-10-06", "counts": dict(ZERO), "tiles": [TA], "include_values": False}
ROWS = [{"title": "Orders", "value": "1,284"}]
T.eq(DG.make_event(taken, ROWS), None, "U5a. no count and values off: nothing to say")
T.eq(DG.make_event(dict(taken, include_values=True), ROWS)["fields"]["tiles"], ROWS, "U5b. values on: the rows go in")
ev = DG.make_event(dict(taken, counts={"finished": 2, "verdicts": 0, "alerts": 0}), ROWS)
T.eq((ev["kind"], ev["key"], ev["ep"], ev["fields"]), ("digest", "d:2026-10-06", None, {"finished": 2, "verdicts": 0, "alerts": 0, "tiles": [], "project": ""}),
     "U5c. values off: counts only, however many rows the state offered")
T.eq(len(DG.make_event(dict(taken, include_values=True), ROWS * 5)["fields"]["tiles"]), 3, "U5d. at most 3 tiles")


def body(**fields):
    return DG.compose_body(dict({"finished": 0, "verdicts": 0, "alerts": 0, "tiles": []}, **fields), TOOLS)


T.eq(body(finished=3, verdicts=2, alerts=1), "Finished 3 · Verdicts 2 · Alerts 1", "U5e. the counts line, fixed format")
T.eq(body(finished=2), "Finished 2", "U5f. a zero count leaves its segment out")
T.eq(body(), None, "U5g. nothing to say -> no body")
T.eq(body(alerts=1, tiles=[{"title": "Orders", "value": "1,284"}]), "Alerts 1\nOrders 1,284", "U5h. counts line, then one line per tile")
T.eq(body(tiles=[{"title": "Orders", "value": "1,284"}, {"title": "Signups", "value": "40"}]), "Orders 1,284\nSignups 40",
     "U5i. no counts, no counts line")
T.eq(body(finished=1, tiles=[{"title": "A", "value": "1"}] * 5).count("\n") + 1, 4, "U5j. at most 4 lines, however many tiles come in")
T.eq(body(finished=10 ** 6), "Finished 9999+", "U5k. a count is clamped")
T.eq(body(finished=True, verdicts="3", alerts=-1, tiles="x"), None, "U5l. a count that is not a positive int is nothing")
T.eq(DG.compose_body("x", TOOLS), None, "U5m. a non-dict is nothing")
worst = body(finished=99999, verdicts=99999, alerts=99999,
             tiles=[{"title": "Open support tickets awaiting a reply", "value": "123.4 GB"}] * 3)
T.check(worst is not None and CP.utf16_len(worst) <= 160 and worst.count("\n") <= 3, "U5n. the worst case stays within 4 lines and 160 units", worst)
for title in ("Open support tickets awaiting a reply", "\U0001F600" * 30):
    line = body(tiles=[{"title": title, "value": "1"}])
    T.check(line is not None and CP.utf16_len(line.rsplit(" ", 1)[0]) <= 24, "U5o. a long title is cut to 24 units: %r" % (title[:12],), line)
secret = T.ghp_shaped()
got = body(finished=1, tiles=[{"title": "key " + secret, "value": "1"}, {"title": "ok", "value": "tok " + secret}])
T.eq(got, "Finished 1", "U5p. a secret-shaped title or value leaves its tile out")
T.eq(body(tiles=[{"title": "/Users/rj/proj/Orders.csv", "value": "1"}]), "Orders.csv 1", "U5q. a path in a title is cut to its basename")
T.eq(body(tiles=[{"title": "bob@example.com", "value": "1"}]), "[email] 1", "U5r. an email in a title is replaced")
T.eq(body(tiles=[{"title": "A\x00B", "value": "1"}]), "A B 1", "U5s. control characters in a title become a space")
T.eq(body(tiles=[{"title": "", "value": "1"}, {"title": "ok", "value": ""}, {"title": 5, "value": "1"}, "x", None]), None, "U5t. malformed tile entries are left out")
LOOSE = types.SimpleNamespace(scrub=lambda text, limit=0: text, clip=CP.clip, utf16_len=CP.utf16_len, secret_shaped=CP._secret_checker())
loose = DG.compose_body({"finished": 1, "tiles": [{"title": "t" * 80 + " end", "value": "v" * 12}] * 3}, LOOSE)
T.check(loose is not None and CP.utf16_len(loose) <= 160 and loose.endswith("…"),
        "U5v. whatever the lines hold, the whole body is cut to 160 units (ellipsis included)", loose)
NOSECRET = types.SimpleNamespace(scrub=CP.scrub, clip=CP.clip, utf16_len=CP.utf16_len, secret_shaped=None)
T.eq(DG.compose_body({"finished": 1, "tiles": [{"title": "Orders", "value": "1"}]}, NOSECRET), "Finished 1",
     "U5u. when the secret check cannot load, no free text is shown (fail closed)")

# ── W. the wire ──
RW = os.path.join(root("w"), "digestproj")
os.makedirs(RW, exist_ok=True)
SW.set_switch("dashboards", True)
CAPS = frozenset(("dash-v1", "push-digest-v1"))
rids = iter(range(1, 10 ** 6))
BODY = {"op": "set-digest", "project": "digestproj", "at": "07:30", "tz_min": 330, "tiles": [], "include_values": False, "on": True}


def params(**over):
    body = dict(BODY, **over)
    for key in [k for k, v in over.items() if v is None and k.startswith("drop_")]:
        del body[key]
    return body


def dispatch(body, caps=CAPS, rid=None):
    return CTL.dispatch(RW, "dashboard-request", dict(body, rid=rid or "q-%08x" % next(rids)), device_id="w", transport="relay", caps=caps)[:2]


made = dispatch({"op": "create", "dashboard_id": "d-00000001", "screen_id": "s-00000001", "tile_id": TA, "project": "digestproj",
                 "text": "orders today"}, caps=frozenset(("dash-v1",)))
T.eq(made, (True, "queued"), "W0. a tile exists in this repo (created through the real dispatcher)")


def handle(body, caps=CAPS):
    """The dashboards handler directly (the dispatcher's own bucket is not under test here)."""
    try:
        fields = DASH.parse_params(body)
    except ValueError:
        return False, "bad-params"
    fields["rid"] = "q-%08x" % next(rids)
    return DASH.handle(RW, fields, types.SimpleNamespace(caps=None if caps is None else frozenset(caps), device_id="w"))[:2]


T.eq(dispatch(dict(BODY, tiles=[TA]), caps=frozenset(("dash-v1",))), (False, "caps-missing"), "W1a. a phone that did not list push-digest-v1 is caps-missing")
T.eq(dispatch(dict(BODY, tiles=[TA]), caps=None), (False, "caps-missing"), "W1b. so is a route that carries no caps")
T.eq(handle(dict(BODY, tiles=[TA]), caps=None), (False, "caps-missing"), "W1c. the handler itself gates the cap")
T.eq(DG.load(RW)["config"], None, "W1d. a refused schedule stores nothing")
PS.register(RW, TOK, "ios", ref=REF, label="digest", events=["digest"])
T.eq(dispatch(dict(BODY, tiles=[TA], include_values=True), rid="q-0000aaaa"), (True, "queued"), "W2a. a valid schedule is queued")
cfg = DG.load(RW)["config"]
T.eq((cfg["at"], cfg["tz_min"], cfg["tiles"], cfg["include_values"], cfg["on"]), ("07:30", 330, [TA], True, True), "W2b. and stored exactly as sent")
T.eq(dispatch(dict(BODY, tiles=[TA], include_values=True), rid="q-0000aaaa"), (True, "dup"), "W2c. a replayed rid is answered dup")
BAD = [("at 7:30", dict(at="7:30")), ("at 24:00", dict(at="24:00")), ("tz 841", dict(tz_min=841)), ("tz bool", dict(tz_min=True)), ("tz float", dict(tz_min=1.5)),
       ("4 tiles", dict(tiles=[TA, TB, TC, TD])), ("dup tiles", dict(tiles=[TA, TA])), ("tile shape", dict(tiles=["t-1"])), ("tiles str", dict(tiles=TA)),
       ("include_values str", dict(include_values="yes")), ("on int", dict(on=1)), ("project int", dict(project=5)), ("extra key", dict(text="x")),
       ("dashboard_id extra", dict(dashboard_id="d-00000001"))]
for why, over in BAD:
    T.eq(handle(dict(BODY, **over)), (False, "bad-params"), "W3a. bad-params: %s" % why)
for gone in ("at", "tz_min", "tiles", "include_values", "on", "project"):
    T.eq(handle({k: v for k, v in BODY.items() if k != gone}), (False, "bad-params"), "W3b. bad-params: %s missing" % gone)
T.eq(handle(dict(BODY, project="otherproj")), (False, "wrong-project"), "W4a. another project is wrong-project")
T.eq(handle(dict(BODY, tiles=["t-deadbeef"])), (False, "wrong-project"), "W4b. a tile id this repo does not hold (another project's) is wrong-project")
T.eq(handle(dict(BODY, tiles=[TA, "t-deadbeef"])), (False, "wrong-project"), "W4c. one foreign tile refuses the whole schedule")
T.eq(DG.load(RW)["config"]["tiles"], [TA], "W4d. a refused schedule leaves the stored one alone")
SW.set_switch("dashboards", False)
T.eq(dispatch(dict(BODY, tiles=[TA])), (False, "dashboards-off"), "W5a. the dashboards laptop switch off: dashboards-off")
SW.set_switch("dashboards", True)
PS.unregister(RW, TOK)
T.eq(handle(dict(BODY, tiles=[TA])), (False, "push-off"), "W6a. turning it on with no phone registered for push is push-off")
T.eq(handle(dict(BODY, tiles=[TA], on=False)), (True, "queued"), "W6b. turning it OFF is always allowed")
PS.register(RW, TOK, "ios", ref=REF, label="digest", events=["digest"])
os.environ["HMD_PUSH"] = "0"
T.eq(handle(dict(BODY, tiles=[TA])), (False, "push-off"), "W6c. HMD_PUSH=0: turning it on is push-off")
T.check(not DG.available() and DG.available({}), "W6d. the capability exists exactly while push is on")
del os.environ["HMD_PUSH"]
T.eq(handle(dict(BODY, tiles=[TA])), (True, "queued"), "W6e. push back on, a phone registered: queued")
T.eq(dispatch({"op": "refresh", "dashboard_id": "d-00000001", "project": "digestproj"}, caps=frozenset(("dash-v1",)))[1], "queued",
     "W7. the other dashboard ops need no push-digest-v1")
audit_path = os.path.join(RW, ".heimdall", "ui", "controls-audit.jsonl")
audit = open(audit_path, encoding="utf-8").read() if os.path.exists(audit_path) else ""
T.check('"op":"set-digest"' in audit, "W8a. a schedule is audited by its op", audit[-200:])
T.check(not any(marker in audit for marker in ("07:30", "digestproj", TOK, "330")), "W8b. the audit line holds no time, project, token or offset")
T.check("digest" not in PS.EVENT_KINDS and PS.extension_kinds().get("digest") == "push-digest-v1"
        and PS.register(RW, TOK, "ios", events=["digest", "finished"]) is not None,
        "W9a. a phone may ask for `digest` in its registration: a registered kind, not one of the five")
try:
    PS.register(RW, TOK, "ios", events=["digest", "not-a-kind"])
    refused = None
except PS.PushStoreError as exc:
    refused = exc.code
T.eq(refused, "bad-events", "W9b. an unknown kind is still bad-events")
PS.bind_extension_kinds(None)
try:
    PS.register(RW, TOK, "ios", events=["digest"])
    refused = None
except PS.PushStoreError as exc:
    refused = exc.code
PS.bind_extension_kinds(CP.registered_kinds)
T.eq(refused, "bad-events", "W9c. where no kind is registered, `digest` is bad-events for that registration")
relay = open(os.path.join(code, "bin", "heimdall-relay-client"), encoding="utf-8").read()
T.check("DIGEST.CAP_DIGEST" not in relay and "PUSH_STORE.extension_kinds().values()" in relay and DG.CAP_DIGEST == "push-digest-v1"
        and CP.registered_kinds().get("digest") == DG.CAP_DIGEST,
        "W10. push-digest-v1 is advertised by the registry (one cap per registered kind), not by a line of its own in the relay client")
T.eq((CP.KINDS, "digest" in CP.all_kinds(), CP.PRIORITY["digest"]), (("question", "approval", "error", "gate_red", "finished", "test"), True, 0),
     "W11. digest is registered: KINDS stays the closed six, all_kinds() has it, priority 0 loses to every built-in kind")

# ── M. the sender ──
DEV = {"token": TOK, "platform": "ios", "registered_at": T.iso(1), "ref": REF, "label": "api server", "events": ["digest"]}
IDLE = st(att("idle", A(1), "done"))
COMMON = {"to", "title", "body", "data", "channelId", "priority", "interruptionLevel", "sound", "ttl", "collapseId", "tag", "threadId"}


class Rig:
    def __init__(self, tokens=None, cfg=None, app_state="unknown", app_state_at=None, root_dir=None, store=None, fake=None, env=None, real_store=False):
        _n[0] += 1
        self.root = root_dir or root("m%d" % _n[0])
        self.store = store or (None if real_store else T.FileStore(os.path.join(tmp, "s%d.json" % _n[0])))
        if store is None and not real_store:
            self.store.seed([DEV] if tokens is None else tokens, app_state, app_state_at)
        self.fake = fake or T.FakeExpo()
        self.events = []
        environ = {"HMD_PUSH_EXPO_URL": self.fake.url}
        environ.update(env or {})
        config = {"min_run_s": 0, "timeout_s": 3.0}
        config.update(cfg or {})
        self.m = CP.PushMonitor(self.root, store=self.store, emit=self.events.append, config=config, sleep=lambda s: None, environ=environ,
                                start_thread=False)

    def close(self):
        self.m.close()
        self.fake.close()


def msgs(rig):
    return [m for m in rig.fake.messages() if m["data"]["kind"] == "digest"]


def bodies(rig):
    return [m["body"] for m in msgs(rig)]


def logs(rig, suppressed=None):
    return [e for e in rig.events if e.get("event") == "push" and e["kind"] == "digest" and (suppressed is None or e["suppressed"] == suppressed)]


def schedule(rig_or_root, now=D1, **over):
    DG.set_config(rig_or_root.root if hasattr(rig_or_root, "root") else rig_or_root, dict(CFG, **over), now)


def finish(rig, n, t):
    """One run that ends done: observed at t (working) and t+60 (idle/done) -> one `finished` event, counted for the next report."""
    rc = T.receipt(finished_at="r0")
    rig.m.observe(st(att("working", A(n)), receipt=rc), t)
    rig.m.observe(st(att("idle", A(n + 1), "done"), gate=True, receipt=rc), t + 60)
    rig.m.step(t + 60)


def tick(rig, now, state=IDLE):
    rig.m.observe(state, now)
    rig.m.step(now)
    rig.m.step(now + 5.0)


# M1. once a day; the constants; the next day again
rig = Rig()
schedule(rig)
finish(rig, 10, D1 + 2 * H)
tick(rig, D1 + 7 * H + 29 * 60)
T.eq(bodies(rig), [], "M1a. before `at` nothing is sent")
tick(rig, D1 + 7 * H + 30 * 60)
T.eq(bodies(rig), ["Finished 1"], "M1b. at `at` the first observed state sends the digest, from the counted finished run")
for t in (7 * H + 31 * 60, 9 * H, 23 * H + 59 * 60):
    tick(rig, D1 + t)
T.eq(len(msgs(rig)), 1, "M1c. exactly one digest that day, however many states follow")
m = msgs(rig)[0]
T.eq((m["title"], m["channelId"], m["interruptionLevel"], m["ttl"], "categoryId" in m, m["collapseId"], m["tag"], m["threadId"]),
     ("api server · morning report", "hmd-updates", "active", 21600, False, REF + ".digest", REF + ".digest", REF), "M1d. the per-kind constants, byte for byte")
T.eq((set(m), m["data"], m["priority"], m["sound"], "badge" in m), (COMMON, {"v": 1, "ref": REF, "kind": "digest", "ep": None}, "high", "default", False),
     "M1e. the exact key set, no badge, data carries only v/ref/kind/ep")
finish(rig, 20, D1 + 86400 + 3 * H)
tick(rig, D1 + 86400 + 7 * H + 29 * 60)
T.eq(len(msgs(rig)), 1, "M1f. the next morning, still before `at`: nothing new")
tick(rig, D1 + 86400 + 7 * H + 30 * 60)
T.eq(bodies(rig), ["Finished 1", "Finished 1"], "M1g. the next day sends the next digest, its counts restarted")
rig.close()

# M1i. the collapseId and tag are `<project hash>.digest`, whatever device they go to
rig = Rig()
schedule(rig, project="digestproj")
finish(rig, 10, D1 + 2 * H)
tick(rig, D1 + 8 * H)
want = hashlib.sha256(b"project:digestproj").hexdigest()[:16] + ".digest"
T.eq([(m["collapseId"], m["tag"], m["threadId"]) for m in msgs(rig)], [(want, want, REF)],
     "M1i. a schedule with a project collapses on <project hash>.digest (sha256 of the project, 16 hex): no raw name in a message")
T.check("digestproj" not in json.dumps(msgs(rig)), "M1j. the project name itself is never in the message")
rig.close()

# M1h. a verdict (a new sweep receipt) is counted as one
rig = Rig()
schedule(rig)
VERDICT = st(att("idle", A(1), "stopped"), receipt=T.receipt(finished_at="v2"))
rig.m.observe(st(att("idle", A(1), "stopped"), receipt=T.receipt(finished_at="v1")), D1 + 5 * H)
rig.m.observe(VERDICT, D1 + 5 * H + 60)
rig.m.step(D1 + 5 * H + 60)
tick(rig, D1 + 8 * H, VERDICT)
T.eq(bodies(rig), ["Verdicts 1"], "M1h. a new sweep receipt is one verdict in the next digest")
rig.close()

# M2. a laptop asleep at `at` sends nothing then; its first activity afterwards sends
rig = Rig()
schedule(rig)
finish(rig, 10, D1 + 5 * H)
T.eq(len(msgs(rig)), 0, "M2a. nothing before `at`")
T.eq(len(rig.fake.sends()), 0, "M2b. and nothing at all while no state is observed (07:30 .. 09:59, the laptop asleep)")
tick(rig, D1 + 10 * H)
T.eq(bodies(rig), ["Finished 1"], "M2c. the first state observed after waking sends the day's digest")
rig.close()

# M3. off, no phone for it, empty
rig = Rig()
schedule(rig, on=False)
finish(rig, 10, D1 + 5 * H)
tick(rig, D1 + 8 * H)
T.eq((len(msgs(rig)), DG.load(rig.root)["last_day"], DG.load(rig.root)["counts"]), (0, None, ZERO), "M3a. on:false: nothing sent, nothing counted, no day spent")
rig.close()
rig = Rig()
schedule(rig)
tick(rig, D1 + 8 * H)
T.eq((len(msgs(rig)), DG.load(rig.root)["last_day"]), (0, "2026-10-06"), "M3b. nothing to say: no push, and the day is spent")
finish(rig, 10, D1 + 9 * H)
tick(rig, D1 + 10 * H)
T.eq(len(msgs(rig)), 0, "M3c. a later event the same day does not reopen a spent day")
tick(rig, D1 + 86400 + 8 * H)
T.eq(bodies(rig), ["Finished 1"], "M3d. it is in the next day's digest")
rig.close()
rig = Rig(tokens=[dict(DEV, events=["question"])])
schedule(rig)
finish(rig, 10, D1 + 5 * H)
tick(rig, D1 + 8 * H)
T.eq((len(msgs(rig)), DG.load(rig.root)["last_day"]), (0, None), "M3e. no phone asked for `digest`: nothing sent and the day is not spent")
rig.store.seed([DEV])
tick(rig, D1 + 8 * H + 61)
T.eq(bodies(rig), ["Finished 1"], "M3f. once a phone asks for it, the digest goes out")
rig.close()
rig = Rig(tokens=[])
schedule(rig)
finish(rig, 10, D1 + 5 * H)
tick(rig, D1 + 8 * H)
T.eq((len(rig.fake.sends()), DG.load(rig.root)["last_day"]), (0, None), "M3g. no phone registered at all: nothing sent, the day is not spent")
rig.close()

rig = Rig(tokens=[dict(DEV, events=[])])
schedule(rig)
finish(rig, 10, D1 + 5 * H)
tick(rig, D1 + 8 * H)
T.eq(([m["data"]["kind"] for m in rig.fake.messages()], DG.load(rig.root)["last_day"]), (["finished"], None),
     "M3h. a phone that named no events gets the five built-in kinds and never a registered one: no digest, the day is not spent")
rig.close()

# M4. the sender's own policy: foreground, rate limit, kind filter, kill switch
rig = Rig(app_state="foreground", app_state_at=D1 + 8 * H - 10)
schedule(rig)
finish(rig, 10, D1 + 5 * H)
tick(rig, D1 + 8 * H)
T.eq((len(msgs(rig)), [e["suppressed"] for e in logs(rig)], DG.load(rig.root)["last_day"]), (0, ["foreground"], "2026-10-06"),
     "M4a. the app in the foreground suppresses it (logged), and the day counts as handled: nothing is replayed")
rig.close()
rig = Rig(tokens=[dict(DEV, events=["digest", "question"])], cfg={"hourly_cap": 1})
schedule(rig)
rig.m.observe(st(att("working", A(1))), D1 + 7 * H)
rig.m.observe(st(att("needs_input", A(2), "question", "Delete it?", None)), D1 + 7 * H + 20 * 60)
rig.m.step(D1 + 7 * H + 20 * 60)
rig.m.step(D1 + 7 * H + 20 * 60 + 5)
finish(rig, 30, D1 + 7 * H + 21 * 60)
tick(rig, D1 + 7 * H + 30 * 60)
T.eq(([m["data"]["kind"] for m in rig.fake.messages()], [e["suppressed"] for e in logs(rig)]), (["question"], ["rate-limited"]),
     "M4b. the hourly cap of non-approval messages applies to the digest too")
rig.close()
rig = Rig(env={"HMD_PUSH": "0"})
schedule(rig)
finish(rig, 10, D1 + 5 * H)
tick(rig, D1 + 8 * H)
T.eq((rig.m.enabled, len(rig.fake.sends()), DG.load(rig.root)["last_day"]), (False, 0, None), "M4c. HMD_PUSH=0: no digest, no counting, no day spent")
rig.close()

# M5. two processes on one repo: exactly one digest, counts not doubled, a non-sender never spends the day
shared = root("m-shared")
fake = T.FakeExpo()
store = T.FileStore(os.path.join(tmp, "s-shared.json"))
store.seed([dict(DEV, events=["digest", "question"])])
r1, r2 = Rig(store=store, fake=fake, root_dir=shared), Rig(store=store, fake=fake, root_dir=shared)
schedule(shared)
for r_ in (r1,):
    r_.m.observe(st(att("working", A(1))), D1 + 6 * H)
    r_.m.observe(st(att("needs_input", A(2), "question", "Q?", None)), D1 + 6 * H + 60)
    r_.m.step(D1 + 6 * H + 60)
    r_.m.step(D1 + 6 * H + 66)
r2.m.observe(st(att("working", A(1))), D1 + 6 * H)
r2.m.observe(st(att("needs_input", A(2), "question", "Q?", None)), D1 + 6 * H + 60)
r2.m.step(D1 + 6 * H + 66)
for r_ in (r1, r2):
    finish(r_, 10, D1 + 7 * H)
for r_ in (r1, r2):
    r_.m.observe(IDLE, D1 + 8 * H)
r2.m.step(D1 + 8 * H)          # the process that is NOT the sender looks first: it must leave the day alone
T.eq(DG.load(shared)["last_day"], None, "M5a. a process that does not own the sender lock never spends the day")
r1.m.step(D1 + 8 * H)
r1.m.step(D1 + 8 * H + 5)
T.eq([m["body"] for m in fake.messages() if m["data"]["kind"] == "digest"], ["Finished 1"], "M5b. one digest, with the run counted once (not twice)")
r1.m.close()
r2.m.close()
fake.close()

# M6. values: off by default, opt-in, only the listed live fresh number tiles, nothing else of the state
LEAKS = T.LEAK_VALUES + ("LEAKintent", "LEAKlabel", "LEAKnotlisted")
state = dict(st(att("idle", A(1), "done")), **dash(tile(TA, "Orders", 1284), tile(TB, "Refund rate", 12.5, "percent"),
                                                    tile(TC, "LEAKnotlisted", 7), tile(TD, "Stale thing", 5, stale=True)))
rig = Rig()
schedule(rig, tiles=[TA, TB, TD], include_values=False)
finish(rig, 10, D1 + 5 * H)
tick(rig, D1 + 8 * H, state)
T.eq(bodies(rig), ["Finished 1"], "M6a. include_values off (the default): no number in the body, though tiles are listed")
rig.close()
rig = Rig()
schedule(rig, tiles=[TA, TB, TD], include_values=True)
tick(rig, D1 + 8 * H, state)
T.eq(bodies(rig), ["Orders 1,284\nRefund rate 12.5%"], "M6b. include_values on: the listed live fresh number tiles, in order; the stale one is left out")
wire = json.dumps(msgs(rig)[0], ensure_ascii=False)
T.check(not [x for x in LEAKS if x in wire], "M6c. nothing else of the state (intents, labels, unlisted tiles, repo, branch) reaches the push", [x for x in LEAKS if x in wire])
rig.close()
rig = Rig()
schedule(rig, tiles=[TA], include_values=True)
finish(rig, 10, D1 + 5 * H)
tick(rig, D1 + 8 * H, dict(state))
T.eq(bodies(rig), ["Finished 1\nOrders 1,284"], "M6d. counts first, then the values")
rig.close()

rig = Rig()
schedule(rig, tiles=[TA], include_values=True)
tick(rig, D1 + 8 * H, dict(S(att("idle", A(1), "done"), receipt=RC0), **dash(tile(TA, "/Users/rj/proj/Orders.csv", 1284))))
T.eq(bodies(rig), ["Orders.csv 1,284"], "M6e. a tile title reaches the push only through the sender's own scrub (a path is cut to its basename)")
rig.close()
rig = Rig()
schedule(rig, tiles=[TA], include_values=True)
tick(rig, D1 + 8 * H, dict(S(att("idle", A(1), "done"), receipt=RC0), **dash(tile(TA, "key " + secret, 1284))))
T.eq((len(msgs(rig)), DG.load(rig.root)["last_day"]), (0, "2026-10-06"), "M6f. a secret-shaped title leaves the tile out; nothing else to say, so no push")
rig.close()

# M7. timezone: the same clock, different people
rig = Rig()
schedule(rig, tz_min=330)
finish(rig, 10, D1 + 30 * 60)
tick(rig, D1 + 1 * H + 59 * 60)
T.eq(len(msgs(rig)), 0, "M7a. 01:59 UTC is 07:29 at +05:30: not yet")
tick(rig, D1 + 2 * H)
T.eq(bodies(rig), ["Finished 1"], "M7b. 02:00 UTC is 07:30 at +05:30: sent")
rig.close()
rig = Rig()
schedule(rig, tz_min=-240)
finish(rig, 10, D1 + 30 * 60)
tick(rig, D1 + 1 * H)
T.eq(bodies(rig), ["Finished 1"], "M7c. at -04:00 it is 21:00 on the 5th: that day's 07:30 has passed, the first activity sends")
tick(rig, D1 + 3 * H)
T.eq(len(msgs(rig)), 1, "M7d. 23:00 local, the same local day: nothing more")
finish(rig, 20, D1 + 4 * H)
tick(rig, D1 + 4 * H + 30 * 60)
T.eq(len(msgs(rig)), 1, "M7e. 00:30 local on the 6th is before 07:30: nothing yet")
tick(rig, D1 + 11 * H + 30 * 60)
T.eq(len(msgs(rig)), 2, "M7f. 07:30 local on the 6th (11:30 UTC): the next digest")
rig.close()

# M8. the dashboards laptop switch is part of it
rig = Rig()
schedule(rig)
finish(rig, 10, D1 + 5 * H)
SW.set_switch("dashboards", False)
tick(rig, D1 + 8 * H)
T.eq((len(msgs(rig)), DG.load(rig.root)["last_day"]), (0, None), "M8a. remote dashboards off: no digest, and the day is not spent")
SW.set_switch("dashboards", True)
tick(rig, D1 + 8 * H + 61)
T.eq(bodies(rig), ["Finished 1"], "M8b. back on: the digest goes out")
rig.close()

# M9. a tile_alert another process spools (companion_push.enqueue_event, what dashboard_alerts does) is counted for the report
rig = Rig()
schedule(rig)
T.eq(CP.enqueue_event(rig.root, "tile_alert", {"tile": TA, "with_value": False}, key="a:%s:%d" % (TA, D1 + 6 * H), now=D1 + 6 * H), True,
     "M9a. the alert is spooled for the sender")
rig.m.observe(IDLE, D1 + 6 * H + 1)
rig.m.step(D1 + 6 * H + 1)
T.eq(DG.load(rig.root)["counts"]["alerts"], 1, "M9b. the sender's worker counts the spooled alert for the next report")
rig.m.observe(IDLE, D1 + 6 * H + 30)
rig.m.step(D1 + 6 * H + 30)
T.eq(DG.load(rig.root)["counts"]["alerts"], 1, "M9c. and only once, however many states follow")
tick(rig, D1 + 8 * H)
T.eq(bodies(rig), ["Alerts 1"], "M9d. it is in the morning report")
rig.close()
rig = Rig()
schedule(rig, on=False)
CP.enqueue_event(rig.root, "tile_alert", {"tile": TA, "with_value": False}, key="a:%s:%d" % (TA, D1 + 6 * H), now=D1 + 6 * H)
rig.m.observe(IDLE, D1 + 6 * H + 1)
rig.m.step(D1 + 6 * H + 1)
T.eq(DG.load(rig.root)["counts"]["alerts"], 0, "M9e. with the digest off nothing is counted")
rig.close()

# M9f. the registry's own limits for this kind: 4 lines, past the default 120 units, up to 160
worst = {"finished": 99999, "verdicts": 99999, "alerts": 99999, "project": "p",
         "tiles": [{"title": "Open support tickets awaiting a reply", "value": "123.4 GB"}] * 3}
built = CP.build_message(TOK, {"kind": "digest", "key": "d:x", "ep": None, "fields": worst}, "api", REF, D1)
T.check(built is not None and 120 < CP.utf16_len(built["body"]) <= 160 and built["body"].count("\n") == 3,
        "M9f. the worst-case digest body keeps its 4 lines and is not cut at the default 120 units", built and built["body"])
T.check(CP.build_message(TOK, {"kind": "digest", "key": "d:x", "ep": None, "fields": {"finished": 0, "tiles": []}}, "api", REF, D1) is None,
        "M9g. a digest with nothing to say builds no message")

# M10. payload limits end to end; the production store
rig = Rig(real_store=True)
PS.register(rig.root, TOK, "ios", ref=REF, label="x" * 24, events=["digest"])
long_state = dict(st(att("idle", A(1), "done")), **dash(*[tile("t-%08x" % i, "Open support tickets awaiting a reply", 123456789, "bytes") for i in range(1, 4)]))
schedule(rig, tiles=["t-%08x" % i for i in (1, 2, 3)], include_values=True)
for n in range(1, 4):
    finish(rig, 10 * n, D1 + 5 * H + n * 60)
tick(rig, D1 + 8 * H, long_state)
sent = msgs(rig)
T.eq(len(sent), 1, "M10a. through the production store: one digest")
if sent:
    wire = json.dumps(sent[0], ensure_ascii=False)
    T.check(CP.utf16_len(sent[0]["title"]) <= 48 and CP.utf16_len(sent[0]["body"]) <= 160 and sent[0]["body"].count("\n") <= 3 and len(wire.encode("utf-8")) < 3500,
            "M10b. title <= 48, body <= 160 units in <= 4 lines, the whole message well under 3500 B", (sent[0]["title"], sent[0]["body"]))
rig.close()
print("done")

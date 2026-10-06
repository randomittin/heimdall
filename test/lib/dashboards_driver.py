#!/usr/bin/env python3
"""test/lib/dashboards_driver.py LIBDIR [--write-fixture] -- every check of test/heimdall-dashboards.test.sh (DD1-DD3, DD7 and the
interface the producer side calls), run against the bin/lib in LIBDIR. The shell test runs it on the real tree (all must pass) and
on mutated copies (the named check must FAIL: that is what makes the suite falsifiable). Prints `ok NAME` / `FAIL NAME: why`.
Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir; nothing signals a process and no relay client is touched."""
import contextlib
import io
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from importlib.util import module_from_spec, spec_from_file_location

LIB = os.path.abspath(sys.argv[1])
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
TMP = os.path.realpath(tempfile.mkdtemp())
os.environ.update(HOME=TMP, HEIMDALL_HOME=TMP + "/h", TMPDIR=TMP)
for var in ("HMD_UI_CONTROLS", "HMD_RELAY_EVENT_LOG"):
    os.environ.pop(var, None)
SWITCH_FILE = TMP + "/h/remote-dashboards.json"


def load(name, path=None):
    spec = spec_from_file_location(name, path or os.path.join(LIB, name + ".py"))
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


c, sw, d = load("companion_ui_controls"), load("companion_remote_switches"), load("companion_dashboards")
CAPS = frozenset(("dash-v1", "resync"))
D, S = "d-0a0a0a0a", "s-0b0b0b0b"
COUNTER = [0]
GOOD = {"title": "New customers", "type": "number", "data": {"value": 12}}
SECRET = "gh" + "p_" + "Ab1" * 12            # assembled at run time: no secret-shaped literal sits in this file


def nid(prefix):
    COUNTER[0] += 1
    return "%s-%08x" % (prefix, COUNTER[0])


def prop(statement="SELECT count(*) AS n FROM customers", connector="shop-db"):
    return {"shape": {"type": "number"}, "producer": {"kind": "sql", "connector": connector, "statement": statement, "columns": ["n"]}}


class Env:
    def __init__(self):
        self.root = os.path.realpath(tempfile.mkdtemp(dir=TMP, prefix="repo-"))
        self.project = os.path.basename(self.root)
        sw.set_switch("dashboards", True)

    def send(self, params, caps=CAPS, action="dashboard-request"):
        return c.dispatch(self.root, action, params, device_id="deadbeef", seq=1, transport="relay", caps=caps)

    def p(self, op, **over):
        base = {"create": {"screen_id": S, "tile_id": nid("t"), "text": "daily new customers"},
                "refine": {"tile_id": None, "text": "make it weekly"}, "set-refresh": {"tile_id": None, "refresh_s": 600},
                "refresh": {}, "remove": {}}[op]
        out = dict(base, rid=nid("q"), op=op, dashboard_id=D, project=self.project)
        out.update(over)
        return {k: v for k, v in out.items() if v is not None or k == "rid"}

    def add(self, tile_id=None, dashboard=D, intent="seeded tile"):
        tile_id = tile_id or nid("t")
        with d._locked(self.root):
            d._write_tile(self.root, d._new_tile({"tile_id": tile_id, "dashboard_id": dashboard, "screen_id": S, "text": intent}, 1790273000))
        return tile_id

    def pending(self, tile_id=None, statement="SELECT count(*) AS n FROM customers", now=None):
        now = time.time() if now is None else now
        tid = self.add(tile_id)
        assert d.register_proposal(self.root, tid, nid("q"), prop(statement), now=now) == (True, None)
        return tid

    def live(self, tile_id=None, statement="SELECT count(*) AS n FROM customers", panel=None, now=1790273050):
        tid = self.pending(tile_id, statement, now=1790273000)
        assert d.confirm_tile(self.root, tid, d.get_tile(self.root, tid)["fingerprint"], now=1790273001) == (True, None)
        assert d.publish_panel(self.root, tid, panel or GOOD, now=now) == (True, None)
        return tid

    def audit(self):
        path = os.path.join(self.root, c.AUDIT_REL)
        return open(path).read() if os.path.exists(path) else ""

    def events(self):
        path = os.path.join(self.root, ".heimdall", "app", "relay-events.jsonl")
        return open(path).read() if os.path.exists(path) else ""


CHECKS = []


def check(fn):
    CHECKS.append(fn)
    return fn


@check
def registered():
    assert "dashboard-request" in c.ALLOWED_ACTIONS and "dashboard_request" not in c.ALLOWED_ACTIONS, sorted(c.ALLOWED_ACTIONS)
    assert c._ACTIONS["dashboard-request"]["cls"] == "expand" and c._ACTIONS["dashboard-request"]["switch"] == "dashboards"
    assert "dashboards" in c.EXPAND_SWITCHES and sw.SWITCHES["dashboards"] == "remote-dashboards.json"
    assert sw.CLI_SWITCH["remote-dashboards"] == "dashboards" and d.CAP_DASH == "dash-v1"


@check
def underscore_is_not_implemented():
    e = Env()
    assert e.send(e.p("create"), action="dashboard_request")[:2] == (False, "not-implemented")


@check
def switch_off_refuses():
    e = Env()
    sw.set_switch("dashboards", False)
    assert e.send(e.p("create"))[:2] == (False, "dashboards-off"), "valid params, switch off"
    assert e.send({"junk": 1})[:2] == (False, "dashboards-off"), "malformed params, switch off: still the switch first"
    assert d._all_tiles(e.root) == [], "nothing is written while the switch is off"
    sw.set_switch("dashboards", True)
    assert e.send(e.p("create"))[:2] == (True, "queued")


@check
def switch_file_untouched():
    if os.path.exists(SWITCH_FILE):
        os.remove(SWITCH_FILE)
    e = Env()
    os.remove(SWITCH_FILE)
    for action in sorted(c.ALLOWED_ACTIONS):
        for params in ({}, e.p("create"), {"rid": "q-00000000", "op": "remove", "dashboard_id": D, "project": e.project}):
            e.send(params, action=action)
    assert not os.path.exists(SWITCH_FILE), "an action created the dashboards switch file"
    assert d.enabled(e.root) is False


@check
def caps_missing():
    e = Env()
    for caps in (None, frozenset(), frozenset(("controls-v1",))):
        assert e.send(e.p("create"), caps=caps)[:2] == (False, "caps-missing"), caps
    assert e.send(e.p("create"))[:2] == (True, "queued")


@check
def controls_off():
    e = Env()
    os.environ["HMD_UI_CONTROLS"] = "0"
    try:
        assert e.send(e.p("create"))[:2] == (False, "controls-off")
        assert d.snapshot(e.root)["enabled"] is False
    finally:
        del os.environ["HMD_UI_CONTROLS"]


@check
def controls_lists_action_only_when_on():
    e = Env()
    assert "dashboard-request" in c.snapshot(e.root)["actions"]
    sw.set_switch("dashboards", False)
    assert "dashboard-request" not in c.snapshot(e.root)["actions"]
    sw.set_switch("dashboards", True)


@check
def keysets():
    e = Env()
    tile = nid("t")
    assert e.send(e.p("create", tile_id=tile, shape={"type": "number", "format": "count", "series": 2}, origin="import", author="ab" * 16)) \
        [:2] == (True, "queued"), "create with every optional key"
    assert e.send(e.p("refine", tile_id=tile, refresh_s=900))[:2] == (True, "queued")
    assert e.send(e.p("set-refresh", tile_id=tile))[:2] == (True, "queued")
    assert e.send(e.p("refresh"))[:2] == (True, "queued"), "refresh without tile_id"
    assert e.send(e.p("remove", tile_id=tile))[:2] == (True, "queued")
    assert e.send(e.p("remove"))[:2] == (True, "queued"), "remove without tile_id (nothing left: still ok)"
    t0 = nid("t")
    bad = [e.p("create", text=None), e.p("create", x=1), e.p("create", refresh_s=True), e.p("create", refresh_s=59),
           e.p("create", refresh_s=86401), e.p("create", refresh_s=60.5), e.p("create", text=""), e.p("create", text="a" * 241),
           e.p("create", text="x‮y"), e.p("create", text="x\ny"), e.p("create", text="é"), e.p("create", text="€" * 201),
           e.p("create", shape={"type": "nope"}), e.p("create", shape={"type": "number", "extra": 1}),
           e.p("create", shape={"type": "number", "series": 7}), e.p("create", shape={"type": "number", "format": "x"}),
           e.p("create", origin="phone"), e.p("create", author="AB" * 16), e.p("create", author="ab" * 15),
           e.p("create", dashboard_id="d-XYZ"), e.p("create", tile_id="d-00000000"), e.p("create", screen_id="s-1"),
           e.p("create", project=5), e.p("create", rid="q-ZZZZZZZZ"), e.p("create", rid="v-00000001"),
           {k: v for k, v in e.p("create").items() if k != "rid"}, {k: v for k, v in e.p("create").items() if k != "op"},
           dict(e.p("create"), op="update"), e.p("refine", tile_id=t0, screen_id=S), e.p("set-refresh", tile_id=t0, refresh_s=None),
           e.p("refresh", text="x"), e.p("remove", refresh_s=60), e.p("refresh", tile_id="t-nothex!!"), e.p("create", pad="x" * 1100)]
    for params in bad:
        got = e.send(params)[:2]
        assert got == (False, "bad-params"), (got, sorted(params))
    assert e.send(None)[:2] == (False, "bad-params")
    assert d._all_tiles(e.root) == [], "a refused request wrote a tile"


@check
def wrong_project():
    e = Env()
    assert e.send(e.p("create", project="not-" + e.project))[:2] == (False, "wrong-project")
    assert d._all_tiles(e.root) == []


@check
def unknown_tile():
    e = Env()
    for op in ("refine", "set-refresh"):
        assert e.send(e.p(op, tile_id=nid("t")))[:2] == (False, "unknown-tile"), op
    for op in ("refresh", "remove"):
        assert e.send(e.p(op, tile_id=nid("t")))[:2] == (False, "unknown-tile"), op


@check
def create_accepts_unseen_tile_ids():
    e = Env()
    fresh = dict(e.p("create"), dashboard_id="d-cafecafe", screen_id="s-cafecafe", tile_id="t-cafecafe")
    assert d.get_tile(e.root, "t-cafecafe") is None and d._all_tiles(e.root) == []
    assert e.send(fresh)[:2] == (True, "queued"), "a tile hmd has never seen, on a dashboard and a screen it has never seen"
    tile = d.get_tile(e.root, "t-cafecafe")
    assert tile is not None and (tile["dashboard_id"], tile["screen_id"], tile["phase"]) == ("d-cafecafe", "s-cafecafe", "generating"), tile
    unseen = "t-deadbeef"
    for op in ("refine", "set-refresh", "refresh", "remove"):
        assert e.send(e.p(op, tile_id=unseen))[:2] == (False, "unknown-tile"), "%s on an id hmd does not hold stays refused" % op
    assert d.get_tile(e.root, unseen) is None and len(d._all_tiles(e.root)) == 1, "a refused op created or removed nothing"
    assert e.send(dict(fresh, rid=nid("q")))[:2] == (True, "dup") and len(d._all_tiles(e.root)) == 1, "a second create is a duplicate, not a second tile"


@check
def too_many_tiles():
    e = Env()
    for _ in range(d.MAX_TILES):
        e.add()
    assert e.send(e.p("create"))[:2] == (False, "too-many-tiles")
    assert len(d._all_tiles(e.root)) == d.MAX_TILES


@check
def busy_and_daily_limit():
    e = Env()
    for _ in range(d.QUEUE_MAX):
        assert e.send(e.p("create"))[:2] == (True, "queued")
    assert e.send(e.p("create"))[:2] == (False, "busy")
    f = Env()
    with d._locked(f.root):
        meta = d._load_meta(f.root)
        meta["daily"] = {"day": time.strftime("%Y-%m-%d", time.gmtime()), "n": d.DAILY_MAX}
        d._save_meta(f.root, meta)
    assert f.send(f.p("create"))[:2] == (False, "daily-limit")


@check
def rate_limited():
    e = Env()
    tile = e.add()
    results = [e.send(e.p("set-refresh", tile_id=tile)) for _ in range(7)]
    assert [r[:2] for r in results[:6]] == [(True, "queued")] * 6, "the all-ops burst is 6, not the 5 of the all-controls bucket"
    assert results[6][:2] == (False, "rate-limited") and results[6][2]["retry_after_s"] >= 1, results[6]


@check
def rid_replay_is_dup():
    e = Env()
    params = e.p("create")
    first, second = e.send(params), e.send(params)
    assert first[:2] == (True, "queued") and second[:2] == (True, "dup") and second[2]["id"] == params["tile_id"] and second[2]["dup"] is True
    assert len(d._load_meta(e.root)["queue"]) == 1 and len(d._all_tiles(e.root)) == 1


@check
def store_files():
    e = Env()
    tile = e.add()
    path = d._tile_path(e.root, D, tile)
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600 and stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode) == 0o700
    assert stat.S_IMODE(os.stat(d.store_dir(e.root)).st_mode) == 0o700
    keys = set(json.load(open(path)))
    want = {"tile_id", "dashboard_id", "screen_id", "intent", "shape", "refresh_s", "origin", "author", "rev", "proposal", "fingerprint",
            "confirmed_fp", "phase", "detail", "last_ok_at", "history"}
    assert want <= keys, want - keys
    assert not [n for n in os.listdir(os.path.dirname(path)) if n.endswith(".tmp")], "a temp file was left behind"
    os.replace(path, path + ".real")
    os.symlink(path + ".real", path)
    assert d._all_tiles(e.root) == [] and d.get_tile(e.root, tile) is None, "a symlinked tile file must be ignored"


@check
def slice_shape():
    e = Env()
    tid = e.live()
    e.pending()
    s = d.snapshot(e.root, now=1790273100)
    assert set(s) == {"v", "enabled", "limits", "tiles", "requests"} and s["v"] == 1 and s["enabled"] is True, sorted(s)
    assert s["limits"] == {"tiles": 16, "refresh_min_s": 60, "refresh_max_s": 86400, "refresh_default_s": 300, "panel_bytes": 32768}
    row = next(t for t in s["tiles"] if t["tile_id"] == tid)
    assert set(row) == {"dashboard_id", "screen_id", "tile_id", "intent", "origin", "rev", "refresh_s", "phase", "detail", "producer_label",
                        "confirm", "last_ok_at", "panel"}, sorted(row)
    assert row["phase"] == "live" and row["producer_label"] == "shop-db (read-only)" and row["confirm"] is None
    assert row["panel"]["id"] == tid and row["panel"]["stale"] is False and row["panel"]["title"] == "New customers"
    wait = next(t for t in s["tiles"] if t["phase"] == "needs-confirm")
    assert set(wait["confirm"]) == {"code", "expires_at"} and len(wait["confirm"]["code"]) == 6 and wait["panel"] is None
    sw.set_switch("dashboards", False)
    assert d.snapshot(e.root) == {"v": 1, "enabled": False, "limits": s["limits"], "tiles": [], "requests": []}
    sw.set_switch("dashboards", True)


@check
def overlay_gating():
    e = Env()
    e.live()
    state = {"schema_version": 1, "dashboards": d.snapshot(e.root, phone=False)}
    frozen = json.dumps(state, sort_keys=True)
    assert "dashboards" not in d.overlay(state, e.root, frozenset()), "a phone that never listed dash-v1 must not see the key"
    assert "dashboards" not in d.overlay(state, e.root, frozenset(("controls-v1",)))
    assert d.overlay({"a": 1}, e.root, frozenset()) == {"a": 1}
    got = d.overlay(state, e.root, CAPS)["dashboards"]
    assert got["v"] == 1 and got["tiles"][0]["panel"] is not None, "the phone's slice carries the panel"
    assert json.dumps(state, sort_keys=True) == frozen, "overlay must copy, never edit the shared state"
    assert "code" not in json.dumps(state["dashboards"]), "the shared (desktop) view carries no confirmation code"


@check
def desktop_view_has_panels_but_no_code():
    e = Env()
    wait, live = e.pending(), e.live()
    desktop, phone = d.snapshot(e.root, phone=False), d.snapshot(e.root, phone=True)
    code = d.confirm_code(wait, d.get_tile(e.root, wait)["fingerprint"])
    assert code in json.dumps(phone) and code not in json.dumps(desktop), "the six digits are for the phone only"
    row = lambda s, tid: next(t for t in s["tiles"] if t["tile_id"] == tid)
    assert row(desktop, live) == row(phone, live) and row(desktop, live)["panel"]["data"] == {"value": 12}, "the same tile, the same panel"
    without_confirm = lambda t: {k: v for k, v in t.items() if k != "confirm"}
    assert without_confirm(row(desktop, wait)) == without_confirm(row(phone, wait)) and row(desktop, wait)["confirm"].keys() == {"expires_at"}
    assert desktop["pending"] == 1 and "pending" not in phone and {k: v for k, v in desktop.items() if k not in ("pending", "tiles")} \
        == {k: v for k, v in phone.items() if k != "tiles"}


def _ui_dir():
    return os.environ.get("HMD_UI_DIR") or os.path.join(REPO, "sentinels")


def _between(text, pattern):
    match = re.search(pattern, text, re.S)
    assert match, "pattern not found: " + pattern[:60]
    return match.group(0)


@check
def desktop_has_no_mutating_route():
    py = open(os.path.join(_ui_dir(), "hmd-ui.py"), encoding="utf-8").read()
    html = open(os.path.join(_ui_dir(), "hmd-ui.html"), encoding="utf-8").read()
    paths = lambda body: set(re.findall(r'path == "(/[^"]*)"', body))
    post = paths(_between(py, r"def _route_post\(self, _query\):.*?(?=\n    # The HTTP status)"))
    get = paths(_between(py, r"    def _route\(self, query\):.*?(?=\n    def |\Z)"))
    assert post == {"/api/send", "/api/control"}, "POST routes: %s" % sorted(post)
    assert get == {"/", "/api/state", "/api/events"}, "GET routes: %s" % sorted(get)
    assert not [p for p in post | get if "dashboard" in p or "tile" in p], "no route is about dashboards: they ride /api/state"
    assert not re.search(r"def do_(PUT|DELETE|PATCH)\b", py), "no other HTTP method is served"
    assert "caps=" not in _between(py, r"    def _handle_control\(self\):.*?(?=\n    def |\Z)"), "the direct route has no phone caps: a dashboard-request is caps-missing"
    section = _between(html, r'<section id="p-dashboards".*?</section>')
    assert not re.search(r"<(button|input|form|select|textarea|a )|contenteditable|onclick", section, re.I), "no control in the dashboards section"
    functions = re.findall(r"  function (?:renderDashboards|renderDashPanels)\(.*?\n  \}\n", html, re.S)
    assert len(functions) == 2, "both read-only renderers are present"
    forbidden = ("fetch(", "XMLHttpRequest", "EventSource", "addEventListener", ".submit(", "sendBeacon", "onclick", "onsubmit", "<button",
                 "<input", "<form", "<select", "<textarea", "contenteditable", "POST", "PUT", "DELETE", "method")
    for source in functions:
        assert not [t for t in forbidden if t in source], [t for t in forbidden if t in source]
    assert "renderDashPanels(state.dashboards" in html, "the desktop view is drawn from the state slice"


@check
def no_proposal_or_statement_anywhere():
    e = Env()
    marker = "zz_marker_col FROM zz_marker_tbl"
    e.send(e.p("create", tile_id="t-aaaaaaaa", text="zz-intent-marker"))
    d.claim_generation(e.root)
    assert d.register_proposal(e.root, "t-aaaaaaaa", "q-00000000", prop("SELECT " + marker, connector="zz-conn")) == (True, None)
    fp = d.get_tile(e.root, "t-aaaaaaaa")["fingerprint"]
    d.confirm_tile(e.root, "t-aaaaaaaa", fp)
    d.publish_panel(e.root, "t-aaaaaaaa", GOOD)
    d.set_tile_status(e.root, "t-aaaaaaaa", "error", "producer-failed")
    blobs = {"phone": json.dumps(d.snapshot(e.root, phone=True)), "laptop": json.dumps(d.snapshot(e.root, phone=False)),
             "audit": e.audit(), "events": e.events()}
    for name, text in blobs.items():
        for needle in ("zz_marker_col", "zz_marker_tbl", "SELECT", '"statement"', '"proposal"'):
            assert needle not in text, "%r leaked into the %s" % (needle, name)
    for name in ("audit", "events"):
        assert "zz-intent-marker" not in blobs[name], "the phone's text leaked into the " + name


@check
def slice_budget():
    e = Env()
    lines = ["x" * 490 for _ in range(64)]
    for i in range(d.MAX_TILES):
        e.live(panel={"title": "t", "type": "log-tail", "data": {"lines": lines}}, now=1790273050 + i)
    full = len(json.dumps(d.snapshot(e.root, now=1790273100), separators=(",", ":")).encode())
    assert full > 400 * 1024, "sixteen near-budget panels are a slice of real size (%d bytes)" % full
    real, d.SLICE_BYTES = d.SLICE_BYTES, 300 * 1024      # the same loop at a budget these panels can exceed
    try:
        s = d.snapshot(e.root, now=1790273100)
    finally:
        d.SLICE_BYTES = real
    size = len(json.dumps(s, separators=(",", ":")).encode())
    assert size < 300 * 1024 and len(s["tiles"]) == d.MAX_TILES, (size, len(s["tiles"]))
    dropped = [t for t in s["tiles"] if t["detail"] == "budget"]
    assert dropped and all(t["panel"] is None for t in dropped), "tile rows stay, panels go, detail is budget"
    assert min(t["last_ok_at"] for t in dropped) == 1790273050, "the least recently updated tile loses its panel first"


@check
def digest_moves():
    ui = load("hmd_ui", os.path.join(REPO, "sentinels", "hmd-ui.py"))
    e = Env()
    tid = e.pending()
    before = ui.digest_of({"schema_version": 1, "dashboards": ui.collect_dashboards(e.root)})
    assert d.confirm_tile(e.root, tid, d.get_tile(e.root, tid)["fingerprint"]) == (True, None)
    mid = ui.digest_of({"schema_version": 1, "dashboards": ui.collect_dashboards(e.root)})
    d.publish_panel(e.root, tid, GOOD)
    one = ui.digest_of({"schema_version": 1, "dashboards": ui.collect_dashboards(e.root)})
    d.publish_panel(e.root, tid, dict(GOOD, data={"value": 13}), now=time.time() + 5)
    two = ui.digest_of({"schema_version": 1, "dashboards": ui.collect_dashboards(e.root)})
    assert len({before, mid, one, two}) == 4, "confirm, a first panel and new numbers must each change the digest"
    assert ".heimdall/ui/dashboards/rev" in ui.WATCH_SOURCES and '"dashboards"' in open(os.path.join(REPO, "sentinels", "hmd-ui.py")).read()


def _bad_panels():
    return {"unknown type": {"title": "t", "type": "nope", "data": {}},
            "source nested in data": {"title": "t", "type": "markdown", "data": {"text": "x", "source": "ls"}},
            "secret-shaped cell": {"title": "t", "type": "kv", "data": {"rows": [["k", SECRET]]}},
            "40 KiB result": {"title": "t", "type": "log-tail", "data": {"lines": ["y" * 500] * 80}},
            "title of 121 characters": {"title": "T" * 121, "type": "number", "data": {"value": 1}},
            "not an object": ["x"]}


@check
def publish_goes_through_the_validator():
    e = Env()
    tid = e.live()
    old = d.get_tile(e.root, tid)["panel"]
    for name, bad in _bad_panels().items():
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            got = d.publish_panel(e.root, tid, bad)
        assert got == (False, "rejected-panel"), (name, got)
        tile = d.get_tile(e.root, tid)
        assert (tile["phase"], tile["detail"]) == ("error", "rejected-panel"), (name, tile["phase"], tile["detail"])
        assert SECRET not in err.getvalue() and "ghp_" not in err.getvalue(), "the log must name the field, never the value"
        assert tile["panel"] == old, "%s: the previous good panel must survive" % name
    assert d.publish_panel(e.root, tid, dict(GOOD, data={"value": 14})) == (True, None)
    assert d.get_tile(e.root, tid)["phase"] == "live"
    assert d.publish_panel(e.root, tid, GOOD, panel_bytes=10) == (False, "rejected-panel"), "the budget is a parameter"


@check
def publish_keeps_old_panel_after_rejection():
    e = Env()
    tid = e.live()
    old = d.get_tile(e.root, tid)["panel"]
    with contextlib.redirect_stderr(io.StringIO()):
        d.publish_panel(e.root, tid, {"title": "t", "type": "nope", "data": {}})
    assert d.get_tile(e.root, tid)["panel"] == old
    row = next(t for t in d.snapshot(e.root)["tiles"] if t["tile_id"] == tid)
    assert row["panel"]["data"] == {"value": 12} and row["detail"] == "rejected-panel", "served stale-but-good, flagged"


@check
def publish_refuses_unconfirmed_tile():
    e = Env()
    tid = e.pending()
    assert d.publish_panel(e.root, tid, GOOD) == (False, "unconfirmed")
    assert d.get_tile(e.root, tid)["panel"] is None


@check
def audit_lines_and_timeline():
    e = Env()
    tile = nid("t")
    ops = [e.p("create", tile_id=tile, text="zz-intent-marker"), e.p("refine", tile_id=tile, text="zz-intent-marker two"),
           e.p("set-refresh", tile_id=tile), e.p("refresh", tile_id=tile), e.p("remove", tile_id=tile)]
    for params in ops:
        assert e.send(params)[0] is True, params["op"]
    lines = [json.loads(x) for x in e.audit().splitlines()]
    assert [x["op"] for x in lines] == ["create", "refine", "set-refresh", "refresh", "remove"]
    for x in lines:
        assert {"ts", "device", "seq", "action", "op", "ok", "detail", "ms", "tile_id"} <= set(x) and x["action"] == "dashboard-request", x
        assert x["tile_id"] == tile and x["device"] == "deadbeef" and "text" not in x and "rid" not in x and "text" not in x.get("params", {})
    raw = e.audit() + e.events()
    assert "zz-intent-marker" not in raw and "SELECT" not in raw and "statement" not in raw
    timeline = [json.loads(x) for x in e.events().splitlines()]
    assert [(x["event"], x["action"], x["ref"]) for x in timeline] == [("remote-action", "dashboard-request", tile)] * 3, timeline
    d.confirm_tile(e.root, e.pending(), "0" * 64)       # a refused confirmation is audited too
    local = e.pending()
    d.decline_tile(e.root, local)
    live = e.live()
    d.set_tile_status(e.root, live, "error", "producer-failed")
    d.set_tile_status(e.root, live, "paused", "idle")
    d.expire_pending(e.root, now=time.time() + d.PENDING_TTL_S + 60)
    seen = {json.loads(x).get("op") for x in e.audit().splitlines()}
    assert {"confirm", "decline", "run-failed", "idle-pause", "expire"} <= seen, seen


@check
def fingerprint_gate():
    e = Env()
    tid = e.live()
    same = d.register_proposal(e.root, tid, nid("q"), prop())
    assert same == (True, None) and d.get_tile(e.root, tid)["phase"] == "live", "a refine that kept the producer needs nothing"
    assert d.register_proposal(e.root, tid, nid("q"), prop("SELECT count(*) AS n FROM orders")) == (True, None)
    tile = d.get_tile(e.root, tid)
    assert tile["phase"] == "needs-confirm" and tile["fingerprint"] != tile["confirmed_fp"] and tile["panel"] is not None
    row = next(t for t in d.snapshot(e.root)["tiles"] if t["tile_id"] == tid)
    assert row["confirm"]["code"] == d.confirm_code(tid, tile["fingerprint"]) and row["panel"]["data"] == {"value": 12}
    assert tid not in [p["tile_id"] for p in d.confirmed_producers(e.root)], "an unconfirmed fingerprint never runs"


@check
def import_is_always_confirmed():
    e = Env()
    first = e.live(statement="SELECT count(*) AS n FROM customers")
    params = e.p("create", origin="import", author="cd" * 16)
    assert e.send(params)[:2] == (True, "queued")
    job = d.claim_generation(e.root)
    assert job["origin"] == "import" and job["author"] == "cd" * 16
    assert d.register_proposal(e.root, job["tile_id"], job["rid"], prop("SELECT count(*) AS n FROM customers")) == (True, None)
    tile = d.get_tile(e.root, job["tile_id"])
    assert tile["origin"] == "import" and tile["phase"] == "needs-confirm", "a previously confirmed identical fingerprint must not skip it"
    assert job["tile_id"] not in [p["tile_id"] for p in d.confirmed_producers(e.root)] and first in [p["tile_id"] for p in d.confirmed_producers(e.root)]


@check
def confirmed_producers_exact():
    e = Env()
    live, unconfirmed, paused, declined, changed = e.live(), e.pending(), e.live(), e.pending(), e.live()
    assert d.set_tile_status(e.root, paused, "paused", "idle") is True
    assert d.decline_tile(e.root, declined) is True
    d.register_proposal(e.root, changed, nid("q"), prop("SELECT 1 AS n"))
    got = {p["tile_id"] for p in d.confirmed_producers(e.root)}
    assert got == {live}, got
    assert d.set_tile_status(e.root, unconfirmed, "live", None) is False and d.set_tile_status(e.root, live, "live", "idle") is False
    producer = d.confirmed_producers(e.root)[0]
    assert producer["producer"]["statement"].startswith("SELECT") and producer["fingerprint"] == d.get_tile(e.root, live)["fingerprint"]
    forged = e.live()                      # a tile file edited by hand: live, but its fingerprint is not the one that was confirmed
    tile = d.get_tile(e.root, forged)
    tile["confirmed_fp"] = "0" * 64
    with d._locked(e.root):
        d._write_tile(e.root, tile)
    assert forged not in [p["tile_id"] for p in d.confirmed_producers(e.root)], "fingerprint != confirmed_fp must never run"


@check
def expiry_and_decline():
    e = Env()
    tid = e.pending(now=1000)
    fp = d.get_tile(e.root, tid)["fingerprint"]
    assert d.expire_pending(e.root, now=1000 + d.PENDING_TTL_S - 1) == []
    live = next(t for t in d.snapshot(e.root, now=1000 + d.PENDING_TTL_S - 1)["tiles"] if t["tile_id"] == tid)
    assert live["phase"] == "needs-confirm"
    late = next(t for t in d.snapshot(e.root, now=1000 + d.PENDING_TTL_S + 1)["tiles"] if t["tile_id"] == tid)
    assert (late["phase"], late["detail"], late["confirm"]) == ("error", "expired", None), "a dead code is never shown"
    assert d.confirm_tile(e.root, tid, fp, now=1000 + d.PENDING_TTL_S + 1) == (False, "expired")
    assert d.expire_pending(e.root, now=1000 + d.PENDING_TTL_S + 1) == [tid] and d.get_tile(e.root, tid)["detail"] == "expired"
    other = e.pending(now=2000)
    assert d.confirm_tile(e.root, other, "f" * 64, now=2001) == (False, "fingerprint-changed")
    assert d.decline_tile(e.root, other) is True and d.get_tile(e.root, other)["detail"] == "declined"
    assert d.confirm_tile(e.root, other, d.get_tile(e.root, other)["fingerprint"]) == (False, "not-pending")


@check
def generation_queue():
    e = Env()
    a, b = e.p("create"), e.p("create")
    e.send(a)
    e.send(b)
    job = d.claim_generation(e.root, now=5000)
    assert job["rid"] == a["rid"] and job["text"] == "daily new customers" and d.claim_generation(e.root, now=5001) is None, "one in flight"
    assert [r["phase"] for r in d._load_meta(e.root)["requests"]] == ["working", "queued"]
    d.fail_generation(e.root, job["tile_id"], job["rid"], "no-connector", now=5002)
    assert d.get_tile(e.root, job["tile_id"])["detail"] == "no-connector"
    assert d.claim_generation(e.root, now=5003)["rid"] == b["rid"]
    assert d.claim_generation(e.root, now=5003 + d.GENERATION_TIMEOUT_S + 1) is None
    assert d.get_tile(e.root, b["tile_id"])["detail"] == "timeout", "a generator that never answers is failed `timeout`"
    assert d.register_proposal(e.root, a["tile_id"], a["rid"], {"shape": {"type": "number"}, "producer": {"kind": "sql"}}) == (False, "generation-failed")
    assert d.register_proposal(e.root, a["tile_id"], a["rid"], dict(prop(), extra=1)) == (False, "generation-failed")


@check
def presence_and_status_line():
    e = Env()
    assert d.phone_present(e.root) is False
    e.send(e.p("create"))
    assert d.phone_present(e.root) is True and d.phone_present(e.root, now=time.time() + d.IDLE_S + 5) is False
    assert d.phone_present(e.root, idle_s=0, now=time.time() + 10 ** 7) is True
    e.pending()
    assert d.status_line(e.root) == "remote dashboards: on · 2 tiles · 1 pending", d.status_line(e.root)
    sw.set_switch("dashboards", False)
    assert d.status_line(e.root) == "remote dashboards: off"
    sw.set_switch("dashboards", True)


@check
def cli_switch_needs_a_terminal():
    script = os.path.join(LIB, "companion_remote_switches.py")
    if os.path.exists(SWITCH_FILE):
        os.remove(SWITCH_FILE)
    run = lambda *a: subprocess.run(["python3", script, "remote-dashboards", *a], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    r = run("on")
    assert r.returncode == 1 and "TTY" in r.stderr and not os.path.exists(SWITCH_FILE), (r.returncode, r.stderr)
    assert run("status").stdout.startswith("remote dashboards: off")
    sw.set_switch("dashboards", True)
    assert run("status").stdout.startswith("remote dashboards: on")
    assert run("off").returncode == 0 and sw.switch_enabled("dashboards") is False


@check
def fixture_pins_the_slice():
    e = Env()
    t0 = 1790273000
    gen = e.add("t-11aa22bb", intent="order volume so far today")
    wait = e.pending("t-33cc44dd", now=t0)
    live = e.live("t-9c0d1e2f", panel={"title": "New customers", "type": "timeseries", "data": {"x": ["Mon", "Tue"], "y": [12, 15]}}, now=t0 + 51)
    err = e.live("t-55ee66ff", panel={"title": "Refund rate", "type": "bars", "data": {"labels": ["Week 1", "Week 2"], "values": [2, 3]}}, now=t0 + 40)
    d.set_tile_status(e.root, err, "error", "producer-failed")
    paused = e.live("t-77001122", panel={"title": "Support backlog", "type": "markdown", "data": {"text": "**12** open"}}, now=t0 + 20)
    d.set_tile_status(e.root, paused, "paused", "idle")
    with d._locked(e.root):
        meta = d._load_meta(e.root)
        meta["requests"] = [{"rid": "q-00ff11ee", "op": "create", "tile_id": live, "phase": "done", "detail": None, "at": t0 + 49},
                            {"rid": "q-1100ff22", "op": "create", "tile_id": gen, "phase": "working", "detail": None, "at": t0 + 52}]
        d._save_meta(e.root, meta)
    s = d.snapshot(e.root, now=t0 + 60)
    s["tiles"].sort(key=lambda t: t["tile_id"])
    path = os.path.join(REPO, "docs", "samples", "dashboards-state-slice.json")
    text = json.dumps(s, indent=2, sort_keys=True) + "\n"
    if "--write-fixture" in sys.argv:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write(text)
    assert os.path.exists(path) and open(path).read() == text, "docs/samples/dashboards-state-slice.json is stale: run the driver with --write-fixture"
    assert {t["phase"] for t in s["tiles"]} == {"generating", "needs-confirm", "live", "error", "paused"}


def main():
    failed = 0
    for fn in CHECKS:
        name = fn.__name__.replace("_", "-")
        try:
            fn()
        except Exception as exc:  # AssertionError carries the why; anything else is a failure with its type
            failed += 1
            print("FAIL %s: %s %s" % (name, type(exc).__name__, str(exc)[:300].replace("\n", " ")))
        else:
            print("ok %s" % name)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

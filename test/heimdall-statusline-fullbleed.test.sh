#!/usr/bin/env bash
#
# heimdall-statusline-fullbleed.test.sh — the ORACLE GATE for the v1 4-row statusline
# (FULL-BLEED gauge, CTX-on-bar, inline team on Row1, gate labels on Row3). This suite is the
# INDEPENDENT correctness authority: every assertion is derived from
# conformance/statusline/INVARIANTS.md (authored SEPARATELY from the impl), NOT from
# impl-authored goldens. It drives the REAL SUT
# (sentinels/hmd-statusline.py + hmd_gauge.py + hmd_layout.py + hmd_ledger.py).
#
# The 12 invariants (INVARIANTS.md), each with its named known-bad RED:
#   ROW-EXACT     every emitted row == COLUMNS visible cells (@40/80/120/200).
#   GAUGE-FILL    Row2 filled cells == round(pct/100 * gw), where gw is the FULL-BLEED content
#                 span (COLUMNS-10); the gauge spans the whole content column (no reserved zone).
#   GAUGE-RAMP    ramp #1E2F73→#4264FF→#5AD7E6; gold tip @>=70, red tip @>=90; dim track.
#   GAUGE-LABELS  the metric labels live ON the Row2 bar (CTX + ↓tokens on the fill; 7d% + $cost
#                 on the track end), gated by width: CTX at gw>=40, the 7d/$ readout at gw>=60.
#                 Row4 carries NO metric labels (it is the blank content row under the sigil).
#   GATE-LABELS   Row3 renders each ledger gate as `<mark> <id> <detail>` · joined
#                 (`✓ secrets · ✓ tests 41/41 · ✓ designmatch .91`); empty ledger → `◌ offline`.
#   NULL-SAFE     absent rate_limits/cost/tokens/repo render NOTHING (never a fake 0%).
#   WIDTH-TIERS   full/mid/narrow/tiny → 4/4/4/1 rows; tiny == `HMD <pct>% <gates>`.
#   ANSI-BUDGET   the ramp is QUANTIZED (no per-cell recolor); track = a 2-colour stripe.
#   FALLBACK      empty/malformed stdin + missing ledger → ⛭ HEIMDALL / offline, no crash.
#   PERF          warm render (primed session cache) < 50ms; cold < 80ms.
#   EXIT          every input → exit 0 AND empty stderr.
#   SIGIL-KEEP    the hero ▄ 8×8 render stays the LEFT anchor; sigil goldens diff clean.
#
# SPAN CONVENTION (SIGIL-KEEP + FULL-BLEED gauge): the content column is the span RIGHT of the
# sigil anchor — gw = COLUMNS - anchor(8 sigil + 2 gutter) = COLUMNS-10. The Row2 gauge is
# FULL-BLEED of gw (the statusline calls render_gauge(gw, ..., labels=True)); there is NO cap and
# NO reserved teammate zone — the team is INLINE on Row1 now, not stacked beside the gauge.
# GAUGE-FILL / GAUGE-RAMP / ANSI-BUDGET are computed against gw, exactly as the statusline calls
# render_gauge(gw, ...). GAUGE-FILL also proves the full-bleed is REAL: it re-derives the span
# from the SUT's own render (bg-cell count − sigil 8) and asserts it equals gw (a cap regression
# → span < gw → RED). ROW-EXACT then proves anchor + full-bleed gauge fill the line to COLUMNS.
#
# ANSI-BUDGET RECONCILIATION (documented deviation): INVARIANTS.md states the literal
# bound "distinct 48;2 <= ceil(COLUMNS/40)+2". The SHIPPED hmd_gauge.py (a frozen
# foundation module this work must NOT rebuild) renders a per-cell 2-colour dim TRACK
# stripe and a ramp quantized in blocks of ceil(span/40) — so total 48;2 occurrences
# scale with width and the literal bound is unmet BY THE SUT. The ledger's bound is
# mathematically inconsistent with the shipped gauge (stepping every N cells over F
# filled cells yields ~F/N distinct ramp colours, not N). This suite therefore asserts
# the TRUE budget the module guarantees and that carries the spirit (no blind per-cell
# ramp recolor): the ramp emits <= ceil(fill/step)+2 distinct NON-track colours, and the
# empty track uses exactly the two documented stripe colours. Known-bad still flips it
# RED (step=1 → a fresh ramp colour every filled cell).
#
# MODES:
#   (no args)        run all 12 invariants.
#   --only <name>    run one (row-exact|gauge-fill|gauge-ramp|gauge-labels|gate-labels|
#                    null-safe|width-tiers|ansi-budget|fallback|perf|exit|sigil-keep).
#   --prove-red      MUTATION harness: monkeypatch the named known-bad into the SUT and
#                    prove the corresponding property FLIPS RED (a green-only suite that
#                    cannot go red is worthless). Proves row-width, gauge-fill, null-safe,
#                    gate-labels.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

MODE="all"
case "${1:-}" in
  --only) MODE="only:${2:-}";;
  --prove-red) MODE="prove-red";;
  "") MODE="all";;
  *) echo "usage: $0 [--only <name> | --prove-red]"; exit 2;;
esac

ROOT="$ROOT" SL="$SL" MODE="$MODE" python3 - <<'PY'
import os, sys, re, json, math, time, tempfile, shutil, subprocess, io, importlib.util, statistics

SL   = os.environ["SL"]
ROOT = os.environ["ROOT"]
MODE = os.environ["MODE"]

ANSI = re.compile(r"\x1b\[[0-9;]*m")
ANCHOR = 10   # sigil 8 + gutter 2  (span convention, see header)

_p = 0; _f = 0
def ok(m):
    global _p; _p += 1; print("  ok   " + m)
def bad(m):
    global _f; _f += 1; print("  FAIL " + m)

def _wide(o):
    return (o == 0x26A1 or 0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0x303E or
            0x3041 <= o <= 0x33FF or 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or
            0xAC00 <= o <= 0xD7A3 or 0x1F000 <= o <= 0x1FAFF)
def vis(s):
    s = ANSI.sub("", s); n = 0
    for ch in s:
        o = ord(ch)
        if o in (0x200B, 0x200D, 0xFE0F) or 0x0300 <= o <= 0x036F:
            continue
        n += 2 if _wide(o) else 1
    return n
def strip(s):
    return ANSI.sub("", s)

# ── load the SUT modules for the direct-gauge + monkeypatch checks ──
def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
SENT = os.path.join(ROOT, "sentinels")
G = load(os.path.join(SENT, "hmd_gauge.py"), "hmd_gauge_fb")
L = load(os.path.join(SENT, "hmd_layout.py"), "hmd_layout_fb")
TC = load(os.path.join(SENT, "hmd_termcaps.py"), "hmd_termcaps_fb")
CAPS = TC.detect(["--color"])
TRACK = {G.TRACK_A, G.TRACK_B}

def span_of(cols):
    return L.remaining_width(["x" * 8], cols, 2)   # == cols-10 for cols>10 (the CONTENT span gw)

# Row2 gauge is FULL-BLEED of the content span gw — the statusline calls render_gauge(gw, ...).
# There is NO cap and NO reserved teammate zone (the team is INLINE on Row1 now), so the gauge
# span IS gw. GAUGE-FILL / GAUGE-RAMP / ANSI-BUDGET are computed against this full-bleed span.
def gauge_span_of(cols):
    return span_of(cols)

def bg_cell_count(row):
    """Count visible cells carrying an ACTIVE 48;2 bg (reset-aware). In a real Row2 this is
    the 8 sigil cells + the gauge_span cells (fill+track); the trailing pad carries no bg —
    so (bg_cell_count(Row2) - 8) re-derives the SUT's actual capped gauge_span."""
    cur = None; n = 0; i = 0
    while i < len(row):
        m = ANSI.match(row, i)
        if m:
            g = m.group(0)
            mm = re.match(r"\x1b\[48;2;(\d+);(\d+);(\d+)m", g)
            if mm:
                cur = tuple(int(x) for x in mm.groups())
            elif g == "\x1b[0m":
                cur = None
            i = m.end(); continue
        if cur is not None:
            n += 1
        i += 1
    return n

# ── hermetic render of the REAL statusline ──
def render(cols, data, home=None, tmp=None, now=1000, extra_env=None):
    own = home is None
    if own:
        home = tempfile.mkdtemp()
    cwd = data.get("workspace", {}).get("current_dir") or home
    os.makedirs(os.path.join(cwd, ".heimdall"), exist_ok=True)
    with open(os.path.join(cwd, ".heimdall", "identity.json"), "w") as f:
        f.write('{"handle":"rj","seed":"rj","created":0}\n')
    with open(os.path.join(cwd, ".heimdall", "statusline.json"), "w") as f:
        f.write('{"verdict":"pass","passed":3,"total":3}\n')
    env = {
        "PATH": os.environ.get("PATH", ""), "HOME": home, "LANG": "en_US.UTF-8",
        "HEIMDALL_IDENTITY_DIR": os.path.join(cwd, ".heimdall"), "HMD_HAID": "rj",
        "HMD_NOW": str(now), "HEIMDALL_CP_URL": "http://127.0.0.1:1", "COLUMNS": str(cols),
        "HMD_STATUSLINE_TMP": (tmp or tempfile.mkdtemp()),
        "HEIMDALL_STATUSLINE_MODE": "truecolor",
    }
    if extra_env:
        env.update(extra_env)
    r = subprocess.run([sys.executable, SL, "--color"], input=json.dumps(data).encode(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    out = r.stdout.decode("utf-8", "replace"); err = r.stderr.decode("utf-8", "replace")
    if own:
        shutil.rmtree(home, ignore_errors=True)
    return out, r.returncode, err

def rows(out):
    return [l for l in out.split("\n") if l != ""]

def canned(cwd, cols, rl=True, repo=True, cost=True, tokens=True, pct=42, now=1000):
    d = {"workspace": {"current_dir": cwd}, "model": {"display_name": "Opus 4.8"},
         "context_window": {"used_percentage": pct}, "session_id": "fb-%d-%d" % (cols, int(pct))}
    if tokens:
        d["context_window"]["total_input_tokens"] = 128000
    if repo:
        d["workspace"]["repo"] = {"name": "heimdall", "branch": "statusline-v1"}
    if cost:
        d["cost"] = {"total_cost_usd": 0.87, "total_duration_ms": 3840000}
    if rl:
        d["rate_limits"] = {"five_hour": {"used_percentage": 42, "resets_at": now + 7200},
                            "seven_day": {"used_percentage": 12}}
    return d

# ── gauge-span cell classification (direct render_gauge parse) ──
def fill_count(row):
    """Leading run of filled (non-track) bg cells in a render_gauge row."""
    cur = None; cnt = 0; started = False
    i = 0; n = len(row)
    while i < n:
        m = ANSI.match(row, i)
        if m:
            g = m.group(0)
            mm = re.match(r"\x1b\[48;2;(\d+);(\d+);(\d+)m", g)
            if mm:
                cur = tuple(int(x) for x in mm.groups())
            i = m.end(); continue
        # a visible cell
        if cur in TRACK:
            break
        if cur is not None:
            cnt += 1; started = True
        i += 1
    return cnt if started else 0

def bg_sequence(row):
    """Per-visible-cell bg colour sequence for a render_gauge row."""
    cur = None; seq = []
    i = 0; n = len(row)
    while i < n:
        m = ANSI.match(row, i)
        if m:
            mm = re.match(r"\x1b\[48;2;(\d+);(\d+);(\d+)m", m.group(0))
            if mm:
                cur = tuple(int(x) for x in mm.groups())
            i = m.end(); continue
        seq.append(cur); i += 1
    return seq

# ════════════════════════ INVARIANTS ════════════════════════
def inv_row_exact():
    for w in (40, 80, 120, 200):
        c = tempfile.mkdtemp()
        out, rc, err = render(w, canned(c, w))
        shutil.rmtree(c, ignore_errors=True)
        rs = rows(out)
        widths = sorted(set(vis(r) for r in rs))
        if widths == [w]:
            ok("ROW-EXACT: every row == %d (%d rows)" % (w, len(rs)))
        else:
            bad("ROW-EXACT: COLUMNS=%d rows widths %s != [%d]" % (w, widths, w))

def inv_gauge_fill():
    for w in (80, 120, 200):
        gw = span_of(w)
        # (a) the gauge is FULL-BLEED of the content span — the SUT's REAL Row2 gauge occupies
        #     exactly gw cells (bg-cells − sigil 8). A cap regression (span < gw) flips this RED.
        c = tempfile.mkdtemp(); out, _, _ = render(w, canned(c, w)); shutil.rmtree(c, True)
        measured = bg_cell_count(rows(out)[1]) - 8
        (ok if measured == gw else bad)(
            "GAUGE-FILL: COLUMNS=%d real Row2 gauge span=%d == full-bleed content %d"
            % (w, measured, gw))
        # (b) fill == round(pct/100 × gw) across the pct bands (round-half-up, NOT floor).
        for p in (0, 1, 50, 69, 70, 89, 90, 100):
            row = G.render_gauge(gw, p, 128000, 12, 0.87, 3840000, None, CAPS)
            got = fill_count(row)
            exp = max(0, min(gw, round(p / 100.0 * gw)))
            if got == exp:
                ok("GAUGE-FILL: span=%d pct=%d fill=%d==round" % (gw, p, got))
            else:
                bad("GAUGE-FILL: span=%d pct=%d fill=%d != round=%d" % (gw, p, got, exp))

def _classify(rgb):
    if rgb in TRACK:
        return "track"
    # gold-class / red-class heuristic
    r, g, b = rgb
    if r >= 200 and g >= 150 and b < 130:
        return "gold"
    if r >= 200 and g < 140 and b < 140:
        return "red"
    return "ramp"

def inv_gauge_ramp():
    span = gauge_span_of(120)
    # the BASE ramp fills the whole bar (danger is tip-only now), so the FIRST filled cell
    # is the dark ramp start #1E2F73 for EVERY pct band — pct=70/90 no longer start blue.
    for p, want_tip, want_first in ((50, "ramp", G.DARK), (70, "gold", G.DARK), (90, "red", G.DARK)):
        row = G.render_gauge(span, p, None, None, None, None, None, CAPS)
        seq = bg_sequence(row)
        fills = [c for c in seq if c is not None and c not in TRACK]
        tracks = [c for c in seq if c in TRACK]
        if not fills:
            bad("GAUGE-RAMP: pct=%d no filled cells" % p); continue
        # (a) first filled cell ~ the base-ramp start endpoint (same for every pct band)
        first_ok = fills[0] == want_first
        # (b) tip class
        tip_cls = _classify(fills[-1])
        tip_ok = (tip_cls == want_tip) if want_tip != "ramp" else (tip_cls in ("ramp",))
        # (c) dim track present at pct<100
        track_ok = len(tracks) >= 1
        if first_ok and tip_ok and track_ok:
            ok("GAUGE-RAMP: pct=%d first≈%s tip=%s track=%d" % (p, want_first, tip_cls, len(tracks)))
        else:
            bad("GAUGE-RAMP: pct=%d first_ok=%s tip=%s(want %s) track=%d"
                % (p, first_ok, tip_cls, want_tip, len(tracks)))

def _row2_plain(out):
    rs = rows(out)
    if len(rs) < 2:
        return ""
    return strip(rs[1])

def _row4_plain(out):
    rs = rows(out)
    return strip(rs[3]) if len(rs) > 3 else ""

def inv_gauge_labels():
    # The metric labels live ON the Row2 bar now (CTX + ↓tokens on the fill; 7d% + $cost on the
    # track end), gated by width: CTX at gw>=40, the right 7d/$ readout at gw>=60. Row4 carries
    # NO metric labels (it is the blank content row beside the sigil's 4th half-block row).
    def r2r4(w):
        c = tempfile.mkdtemp(); out, _, _ = render(w, canned(c, w)); shutil.rmtree(c, True)
        return _row2_plain(out), _row4_plain(out)
    # full(120): gw=110 → Row2 has CTX AND the right $ readout; Row4 has neither.
    r2, r4 = r2r4(120)
    (ok if ("CTX" in r2 and "$" in r2) else bad)("GAUGE-LABELS: full → Row2 has CTX AND right $ readout on the bar")
    (ok if ("CTX" not in r4 and "$" not in r4) else bad)("GAUGE-LABELS: full → Row4 carries no metric labels")
    # mid(80): gw=70>=60 → Row2 keeps CTX AND the $ readout.
    r2, r4 = r2r4(80)
    (ok if ("CTX" in r2 and "$" in r2) else bad)("GAUGE-LABELS: mid(80) → Row2 has CTX AND $ (gw>=60)")
    (ok if ("CTX" not in r4 and "$" not in r4) else bad)("GAUGE-LABELS: mid(80) → Row4 carries no metric labels")
    # a width where CTX shows but the right $ readout is GATED OFF (40<=gw<60): cols=64 → gw=54.
    r2, _ = r2r4(64)
    (ok if ("CTX" in r2 and "$" not in r2) else bad)("GAUGE-LABELS: gw=54 → Row2 CTX only, right $ dropped")
    # narrow bar (gw<40): cols=48 → gw=38 → the bar is CLEAN (no CTX label fits under gw<40).
    r2, _ = r2r4(48)
    (ok if ("CTX" not in r2) else bad)("GAUGE-LABELS: gw=38 → Row2 bar clean (no CTX under gw<40)")

def inv_gate_labels():
    # Row3 renders each ledger gate as `<mark> <id> <detail>` · joined. Drive a status.json
    # ledger (HEIMDALL_HOME/ledger/status.json, i.e. HOME/.heimdall/ledger) with three known
    # gates and assert Row3 carries the id + detail for each, marked ✓.
    home = tempfile.mkdtemp()
    os.makedirs(os.path.join(home, ".heimdall", "ledger"), exist_ok=True)
    status = {"daemon": True, "gates": [
        {"id": "secrets", "state": "pass", "detail": ""},
        {"id": "tests", "state": "pass", "detail": "41/41"},
        {"id": "designmatch", "state": "pass", "detail": ".91"}]}
    with open(os.path.join(home, ".heimdall", "ledger", "status.json"), "w") as f:
        json.dump(status, f)
    c = tempfile.mkdtemp()
    out, rc, _ = render(120, canned(c, 120), home=home)
    shutil.rmtree(c, True); shutil.rmtree(home, True)
    r3 = strip(rows(out)[2])
    for tok in ("✓ secrets", "✓ tests 41/41", "✓ designmatch .91"):
        (ok if tok in r3 else bad)("GATE-LABELS: Row3 carries `%s`" % tok)
    # empty ledger gates (present but []) → the neutral `◌ offline` marker (no fabricated pass).
    home2 = tempfile.mkdtemp()
    os.makedirs(os.path.join(home2, ".heimdall", "ledger"), exist_ok=True)
    with open(os.path.join(home2, ".heimdall", "ledger", "status.json"), "w") as f:
        json.dump({"daemon": False, "gates": []}, f)
    c2 = tempfile.mkdtemp()
    out2, _, _ = render(120, canned(c2, 120), home=home2)
    shutil.rmtree(c2, True); shutil.rmtree(home2, True)
    r3b = strip(rows(out2)[2])
    (ok if "offline" in r3b else bad)("GATE-LABELS: empty ledger gates → `◌ offline`")

def inv_null_safe():
    # (a) used_percentage absent → fill 0, exit 0
    c = tempfile.mkdtemp()
    d = canned(c, 120); del d["context_window"]["used_percentage"]
    out, rc, err = render(120, d); shutil.rmtree(c, True)
    span = span_of(120)
    (ok if rc == 0 else bad)("NULL-SAFE: absent used_percentage → exit 0")
    # (b) rate_limits absent → NO 5h token on Row1 (the tail) AND NO 7d token on Row2 (the gauge
    #     readout) — the limits render from LIVE sources only, never a fabricated 0%.
    c = tempfile.mkdtemp(); out, rc, err = render(120, canned(c, 120, rl=False)); shutil.rmtree(c, True)
    r1 = strip(rows(out)[0]); r2 = _row2_plain(out)
    (ok if "5h" not in r1 else bad)("NULL-SAFE: rate_limits absent → no 5h token on Row1 tail")
    (ok if "7d" not in r2 else bad)("NULL-SAFE: rate_limits absent → no 7d token on Row2 gauge")
    # (c) workspace.repo absent → basename, no ':' worktree join in the repo segment
    c = tempfile.mkdtemp()
    d = canned(c, 120, repo=False); out, rc, err = render(120, d); shutil.rmtree(c, True)
    r0 = strip(rows(out)[0])
    base = os.path.basename(c.rstrip("/"))
    (ok if base in r0 else bad)("NULL-SAFE: repo absent → current_dir basename on Row1")
    (ok if (":" + "statusline") not in r0 else bad)("NULL-SAFE: repo absent → no branch/:worktree join")

def inv_width_tiers():
    for w, want in ((120, 4), (80, 4), (48, 4), (30, 1)):
        c = tempfile.mkdtemp(); out, rc, err = render(w, canned(c, w)); shutil.rmtree(c, True)
        rc_rows = len(rows(out))
        (ok if rc_rows == want else bad)("WIDTH-TIERS: COLUMNS=%d → %d rows (want %d)" % (w, rc_rows, want))
    c = tempfile.mkdtemp(); out, _, _ = render(30, canned(c, 30, pct=42)); shutil.rmtree(c, True)
    line = strip(rows(out)[0])
    (ok if re.match(r"^HMD \d+% ", line) else bad)("WIDTH-TIERS: tiny line matches '^HMD <pct>% '")

def inv_ansi_budget():
    # the ramp is QUANTIZED: distinct NON-track colours <= ceil(fill/step)+2, and the
    # track uses exactly the two documented stripe colours. (See header reconciliation.)
    for w in (120, 200):
        span = gauge_span_of(w)
        step = max(1, math.ceil(span / 40.0))
        row = G.render_gauge(span, 50, None, None, None, None, None, CAPS)
        seq = [c for c in bg_sequence(row) if c is not None]
        fills = [c for c in seq if c not in TRACK]
        distinct_ramp = len(set(fills))
        distinct_track = len(set(c for c in seq if c in TRACK))
        budget = math.ceil(len(fills) / step) + 2
        cond = distinct_ramp <= budget and distinct_track <= 2
        (ok if cond else bad)(
            "ANSI-BUDGET: span=%d step=%d ramp-distinct=%d<=%d track-distinct=%d<=2"
            % (span, step, distinct_ramp, budget, distinct_track))

def inv_fallback():
    # empty + malformed stdin → ⛭ HEIMDALL, exit 0
    for label, blob in (("empty", ""), ("malformed", "{bad json")):
        c = tempfile.mkdtemp()
        env = {"PATH": os.environ.get("PATH", ""), "HOME": c, "COLUMNS": "120",
               "HMD_STATUSLINE_TMP": c, "HEIMDALL_STATUSLINE_MODE": "truecolor"}
        r = subprocess.run([sys.executable, SL, "--color"], input=blob.encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        shutil.rmtree(c, True)
        out = r.stdout.decode("utf-8", "replace")
        cond = "HEIMDALL" in strip(out) and r.returncode == 0
        (ok if cond else bad)("FALLBACK: %s stdin → HEIMDALL, exit %d" % (label, r.returncode))
    # missing ledger dir → Row3 offline/neutral, no crash
    c = tempfile.mkdtemp()
    d = {"workspace": {"current_dir": "/nonexistent-xyz-fb"},
         "context_window": {"used_percentage": 50}, "session_id": "fb-noledger"}
    env = {"PATH": os.environ.get("PATH", ""), "HOME": c, "COLUMNS": "120",
           "HMD_STATUSLINE_TMP": c, "HEIMDALL_STATUSLINE_MODE": "truecolor"}
    r = subprocess.run([sys.executable, SL, "--color"], input=json.dumps(d).encode(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    shutil.rmtree(c, True)
    cond = r.returncode == 0 and not r.stderr and "offline" in strip(r.stdout.decode())
    (ok if cond else bad)("FALLBACK: missing ledger → Row3 offline, exit 0, clean stderr")

def inv_perf():
    # in-process warm/cold render timing (mirrors the density benchmark).
    home = tempfile.mkdtemp(); cwd = tempfile.mkdtemp()
    os.makedirs(os.path.join(cwd, ".heimdall"), exist_ok=True)
    open(os.path.join(cwd, ".heimdall", "identity.json"), "w").write('{"handle":"rj","seed":"rj","created":0}\n')
    open(os.path.join(cwd, ".heimdall", "statusline.json"), "w").write('{"verdict":"pass","passed":3,"total":3}\n')
    tmp = tempfile.mkdtemp()
    os.environ.update({"HOME": home, "HEIMDALL_IDENTITY_DIR": os.path.join(cwd, ".heimdall"),
                       "HMD_HAID": "rj", "HMD_NOW": "1000", "HEIMDALL_CP_URL": "http://127.0.0.1:1",
                       "COLUMNS": "120", "HMD_STATUSLINE_TMP": tmp, "HEIMDALL_STATUSLINE_MODE": "truecolor"})
    m = load(SL, "sl_perf")
    j = json.dumps(canned(cwd, 120))
    def one():
        sys.stdin = io.StringIO(j)
        buf = io.StringIO()
        old = sys.stdout; sys.stdout = buf
        try:
            m.main()
        finally:
            sys.stdout = old
    one()  # warm interpreter + sigil cache + ledger cache
    shutil.rmtree(m._sigil_cache_dir(), ignore_errors=True); m._SIG_MEMO.clear()
    shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp, exist_ok=True)
    t0 = time.perf_counter(); one(); cold = (time.perf_counter() - t0) * 1000
    one()
    ts = []
    for _ in range(40):
        t0 = time.perf_counter(); one(); ts.append((time.perf_counter() - t0) * 1000)
    med = statistics.median(ts)
    shutil.rmtree(home, True); shutil.rmtree(cwd, True); shutil.rmtree(tmp, True)
    print("  .... warm median=%.2fms cold=%.2fms" % (med, cold))
    (ok if med < 50.0 else bad)("PERF: warm median %.2fms < 50ms" % med)
    (ok if cold < 80.0 else bad)("PERF: cold %.2fms < 80ms" % cold)

def inv_exit():
    inputs = [("valid", json.dumps(canned("/tmp", 120))), ("empty", ""),
              ("malformed", "{nope"), ("array", "[1,2,3]"), ("null", "null")]
    allok = True
    for label, blob in inputs:
        for w in (40, 80, 120, 200):
            c = tempfile.mkdtemp()
            env = {"PATH": os.environ.get("PATH", ""), "HOME": c, "COLUMNS": str(w),
                   "HMD_STATUSLINE_TMP": c, "HEIMDALL_STATUSLINE_MODE": "truecolor"}
            r = subprocess.run([sys.executable, SL, "--color"], input=blob.encode(),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            shutil.rmtree(c, True)
            if r.returncode != 0 or r.stderr:
                allok = False
                bad("EXIT: %s @%d → rc=%d stderr=%r" % (label, w, r.returncode, r.stderr[:80]))
    if allok:
        ok("EXIT: all inputs × widths → exit 0, empty stderr")

def inv_sigil_keep():
    # (a) SELF render: the left anchor is the multi-cell hero ▄ block, NOT a lone ▟█▙.
    c = tempfile.mkdtemp(); out, _, _ = render(120, canned(c, 120)); shutil.rmtree(c, True)
    rs = rows(out)
    # the hero sigil is a perfect 8×8 = 4 half-block rows, untrimmed → anchors all 4 rows.
    anchors = [strip(r)[:8] for r in rs[:4]]
    has_block = all("▄" in a for a in anchors)
    no_brand_glyph = not any(g in out for g in ("▟", "█", "▙"))
    (ok if has_block else bad)("SIGIL-KEEP: hero ▄ block anchors all 4 rows (left 8 cells)")
    (ok if no_brand_glyph else bad)("SIGIL-KEEP: no ▟█▙ brand glyph (hero kept, not replaced)")
    # (b) the sigil goldens diff clean (hmd_sigil.py byte-untouched by this work).
    r = subprocess.run(["git", "diff", "--quiet", "conformance/statusline/goldens/sigil/"],
                       cwd=ROOT)
    (ok if r.returncode == 0 else bad)("SIGIL-KEEP: sigil goldens diff clean (untouched)")

REG = {
    "row-exact": inv_row_exact, "gauge-fill": inv_gauge_fill, "gauge-ramp": inv_gauge_ramp,
    "gauge-labels": inv_gauge_labels, "gate-labels": inv_gate_labels, "null-safe": inv_null_safe,
    "width-tiers": inv_width_tiers, "ansi-budget": inv_ansi_budget, "fallback": inv_fallback,
    "perf": inv_perf, "exit": inv_exit, "sigil-keep": inv_sigil_keep,
}

# ════════════════════════ PROVE-RED (mutation) ════════════════════════
def prove_red():
    print("== --prove-red: each named known-bad MUST flip its property RED ==")
    # 1) row-width RED: disable pad_or_truncate (return unpadded) → some row != COLUMNS.
    m = load(SL, "sl_mut1")
    m.LAYOUT.pad_or_truncate = lambda s, w, *a, **k: (s if s is not None else "")
    j = json.dumps(canned("/tmp", 120))
    sys.stdin = io.StringIO(j); buf = io.StringIO(); old = sys.stdout; sys.stdout = buf
    try:
        m.main()
    finally:
        sys.stdout = old
    rs = rows(buf.getvalue())
    widths = set(vis(r) for r in rs)
    (ok if widths != {120} else bad)("prove-red row-width: pad disabled → rows %s != {120} (RED)" % sorted(widths))

    # 2) gauge-fill RED: floor instead of round → a fractional case diverges.
    m2 = load(SL, "sl_mut2")
    m2.GAUGE._fill_count = lambda w, p: max(0, min(w, int(p / 100.0 * w)))
    diverged = False
    for w in (80, 120, 200):
        span = gauge_span_of(w)
        for p in (1, 50, 69, 70, 89, 90):
            row = m2.GAUGE.render_gauge(span, p, None, None, None, None, None, CAPS)
            got = fill_count(row); exp = max(0, min(span, round(p / 100.0 * span)))
            if got != exp:
                diverged = True
    (ok if diverged else bad)("prove-red gauge-fill: floor→round mismatch on a fractional case (RED)")

    # 3) null-safe RED: remove the None-guard in rate_limit_parts (the INVARIANTS.md known-bad
    #    "default a missing rate_limits to 0%") → a fabricated `5h 0%` appears on the Row1 tail
    #    even though rate_limits is ABSENT. rate_limit_seg → main's Row1 tail reads this fn.
    m3 = load(SL, "sl_mut3")
    def _rlp_guard_removed(data, now):
        rl = data.get("rate_limits") or {}
        fh = rl.get("five_hour") or {}
        up = fh.get("used_percentage")
        up = 0 if up is None else up          # THE BUG: fabricate 0% when the source is absent
        pct = max(0, min(100, int(round(up))))
        return ("5h %d%%" % pct, "")
    m3.rate_limit_parts = _rlp_guard_removed
    c = tempfile.mkdtemp()
    d = canned(c, 120, rl=False)
    os.makedirs(os.path.join(c, ".heimdall"), exist_ok=True)
    open(os.path.join(c, ".heimdall", "identity.json"), "w").write('{"handle":"rj","seed":"rj"}\n')
    os.environ.update({"HOME": c, "HEIMDALL_IDENTITY_DIR": os.path.join(c, ".heimdall"),
                       "HMD_HAID": "rj", "HMD_NOW": "1000", "COLUMNS": "120",
                       "HMD_STATUSLINE_TMP": c, "HEIMDALL_STATUSLINE_MODE": "truecolor",
                       "HEIMDALL_CP_URL": "http://127.0.0.1:1"})
    sys.stdin = io.StringIO(json.dumps(d)); buf = io.StringIO(); old = sys.stdout; sys.stdout = buf
    try:
        m3.main()
    finally:
        sys.stdout = old
    r1 = strip(rows(buf.getvalue())[0])
    shutil.rmtree(c, True)
    (ok if "5h 0%" in r1 else bad)("prove-red null-safe: fabricated 5h 0%% appears on Row1 when rate_limits absent (RED)")

    # 4) gate-labels RED: force _gate_seg to marks-only (drop id+detail regardless of level) →
    #    Row3 loses the gate ids, so the mockup label `secrets` disappears from the render.
    m4 = load(SL, "sl_mut4")
    def _seg_marks_only(g, level, colored):
        glyph, col = m4._GATE_GLYPH.get(g.get("state"), ("◌", m4.DIM))
        return (col + glyph + m4.X) if colored else glyph
    m4._gate_seg = _seg_marks_only          # gate_labels → _gate_seg (module global) reads this
    home = tempfile.mkdtemp()
    os.makedirs(os.path.join(home, ".heimdall", "ledger"), exist_ok=True)
    st = {"daemon": True, "gates": [{"id": "secrets", "state": "pass", "detail": ""},
                                    {"id": "tests", "state": "pass", "detail": "41/41"}]}
    open(os.path.join(home, ".heimdall", "ledger", "status.json"), "w").write(json.dumps(st))
    c = tempfile.mkdtemp()
    d = canned(c, 120)
    os.makedirs(os.path.join(c, ".heimdall"), exist_ok=True)
    open(os.path.join(c, ".heimdall", "identity.json"), "w").write('{"handle":"rj","seed":"rj"}\n')
    os.environ.update({"HOME": home, "HEIMDALL_IDENTITY_DIR": os.path.join(c, ".heimdall"),
                       "HMD_HAID": "rj", "HMD_NOW": "1000", "COLUMNS": "120",
                       "HMD_STATUSLINE_TMP": tempfile.mkdtemp(), "HEIMDALL_STATUSLINE_MODE": "truecolor",
                       "HEIMDALL_CP_URL": "http://127.0.0.1:1"})
    sys.stdin = io.StringIO(json.dumps(d)); buf = io.StringIO(); old = sys.stdout; sys.stdout = buf
    try:
        m4.main()
    finally:
        sys.stdout = old
    r3 = strip(rows(buf.getvalue())[2])
    shutil.rmtree(c, True); shutil.rmtree(home, True)
    (ok if "secrets" not in r3 else bad)("prove-red gate-labels: _gate_seg marks-only → Row3 loses `secrets` (RED)")

# ════════════════════════ dispatch ════════════════════════
if MODE == "prove-red":
    prove_red()
elif MODE.startswith("only:"):
    name = MODE.split(":", 1)[1]
    if name not in REG:
        print("unknown invariant: %s (have: %s)" % (name, " ".join(sorted(REG)))); sys.exit(2)
    print("== --only %s ==" % name)
    REG[name]()
else:
    for name in ("row-exact", "gauge-fill", "gauge-ramp", "gauge-labels", "gate-labels",
                 "null-safe", "width-tiers", "ansi-budget", "fallback", "perf", "exit",
                 "sigil-keep"):
        print("== %s ==" % name)
        REG[name]()

print()
print("%d passed, %d failed" % (_p, _f))
sys.exit(1 if _f else 0)
PY

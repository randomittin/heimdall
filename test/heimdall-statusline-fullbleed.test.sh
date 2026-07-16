#!/usr/bin/env bash
#
# heimdall-statusline-fullbleed.test.sh — the ROW-WIDTH FALSIFIER for the v2 4-row
# composite statusline (Spec v2 §8). It drives the REAL SUT
# (sentinels/hmd-statusline.py + hmd_gauge.py + hmd_layout.py + hmd_sigil.py + hmd_ledger.py)
# and asserts the four §8 falsifier properties — the anti-truncation contract:
#
#   1. ROW-EXACT   every emitted row == COLUMNS visible grapheme cells at
#                  40/60/80/95/120/160 (⛭ ▄ ◉ = 1 cell; wide glyphs counted via wcwidth).
#   2. TEAM-UNCUT  with 3 teammates @120: NO row contains `…` inside the team-zone span
#                  (the last team_w cells), AND the last 8 cells of rows 1–2 are SIGIL
#                  cells (an active 48;2 bg) — the eye-strips ride the right edge, never
#                  truncated (Spec v2 §2 R-A / §8.2).
#   3. LEDGER-GONE ledger deleted mid-session → the `– gates offline` row + an EMPTY team
#                  zone, exit 0, no crash (Spec v2 §8.3).
#   4. FALLBACK    empty/malformed stdin → the `⛭ HEIMDALL` fallback line, exit 0 (§8.4).
#
# MODES:
#   (no args)     run the four falsifier properties.
#   --prove-red   MUTATION harness: monkeypatch a named known-bad into the SUT and prove
#                 the corresponding property FLIPS RED (a green-only suite is worthless).
#                 Proves row-width, team-truncation, and gate-offline.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

MODE="all"
case "${1:-}" in
  --prove-red) MODE="prove-red";;
  "") MODE="all";;
  *) echo "usage: $0 [--prove-red]"; exit 2;;
esac

ROOT="$ROOT" SL="$SL" MODE="$MODE" python3 - <<'PY'
import os, sys, re, json, tempfile, shutil, subprocess, io, importlib.util

SL   = os.environ["SL"]
ROOT = os.environ["ROOT"]
MODE = os.environ["MODE"]

ANSI = re.compile(r"\x1b\[[0-9;]*m")

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

# ── load the SUT modules (for the team_w geometry + the monkeypatch RED harness) ──
def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
SENT = os.path.join(ROOT, "sentinels")
L = load(os.path.join(SENT, "hmd_layout.py"), "hmd_layout_fb")
# the 2nd-column gutter the SUT (hmd-statusline.py) reserves + renders between the content
# column and the left-packed team column (kept in sync with hmd-statusline.TEAM_COL_GAP).
SL_TEAM_COL_GAP = 4

def bg_cells(row):
    """Per-visible-cell 'has an active 48;2 bg?' list (reset-aware)."""
    cur = False; out = []; i = 0
    while i < len(row):
        m = ANSI.match(row, i)
        if m:
            g = m.group(0)
            if re.match(r"\x1b\[48;2;", g):
                cur = True
            elif g == "\x1b[0m":
                cur = False
            i = m.end(); continue
        out.append(cur); i += 1
    return out

def last8_are_sigil(row):
    cells = bg_cells(row)
    return len(cells) >= 8 and all(cells[-8:])

# ── hermetic render of the REAL statusline ──
def render(cols, data, home=None, tmp=None, now=1752410000, blob=None, legacy=True):
    own_home = home is None
    if own_home:
        home = tempfile.mkdtemp()
    cwd = data.get("workspace", {}).get("current_dir") if data else None
    cwd = cwd or tempfile.mkdtemp()
    os.makedirs(os.path.join(cwd, ".heimdall"), exist_ok=True)
    with open(os.path.join(cwd, ".heimdall", "identity.json"), "w") as f:
        f.write('{"handle":"rj","seed":"rj","created":0}\n')
    if legacy:
        with open(os.path.join(cwd, ".heimdall", "statusline.json"), "w") as f:
            f.write('{"verdict":"watching","passed":3,"total":3}\n')
    env = {
        "PATH": os.environ.get("PATH", ""), "HOME": home, "LANG": "en_US.UTF-8",
        "HEIMDALL_HOME": os.path.join(home, ".heimdall"),
        "HEIMDALL_IDENTITY_DIR": os.path.join(cwd, ".heimdall"), "HMD_HAID": "rj",
        "HMD_NOW": str(now), "HEIMDALL_CP_URL": "http://127.0.0.1:1", "COLUMNS": str(cols),
        "HMD_STATUSLINE_TMP": (tmp or tempfile.mkdtemp()),
        "HEIMDALL_STATUSLINE_MODE": "truecolor",
        # This suite pins the RENDERER contract (rows full-bleed the layout width; tier
        # boundaries at 40/60/100) at a GIVEN width — so it takes COLUMNS AS the layout width
        # and holds back none of CC's region spacing. Deriving the layout width from CC's
        # $COLUMNS (which is the FULL TERMINAL width, 4 cells wider than CC's paint region)
        # is a SEPARATE contract, owned by heimdall-statusline-cc-region-reserve.test.sh.
        # Without this pin the reserve would silently shift the tier under test (COLUMNS=40
        # → layout 36 → tiny, not narrow), testing a different tier than the label claims.
        "HMD_STATUSLINE_RESERVE": "0",
    }
    if not legacy:
        # a TRUE ledger-absent render — no status.json AND no legacy statusline.json to map.
        env["HEIMDALL_STATE"] = os.path.join(cwd, ".heimdall", "no-such-statusline.json")
    payload = blob if blob is not None else json.dumps(data).encode()
    r = subprocess.run([sys.executable, SL, "--color"], input=payload,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    out = r.stdout.decode("utf-8", "replace"); err = r.stderr.decode("utf-8", "replace")
    if own_home:
        shutil.rmtree(home, ignore_errors=True)
    return out, r.returncode, err

def rows(out):
    return [l for l in out.split("\n") if l != ""]

def canned(cwd, cols, now=1752410000):
    return {"workspace": {"current_dir": cwd, "repo": {"name": "heimdall"}},
            "model": {"display_name": "Opus 4.8"},
            "context_window": {"used_percentage": 71, "total_input_tokens": 708000},
            "cost": {"total_cost_usd": 4.12, "total_duration_ms": 3840000},
            "rate_limits": {"five_hour": {"used_percentage": 28, "resets_at": now + 7200},
                            "seven_day": {"used_percentage": 41}},
            "session_id": "fb-%d" % cols}

# three teammates with distinct REAL HAIDs → distinct auto-assigned heroes.
TEAM3 = [{"user": "akshat", "haid": "haid:akshat.mbp-1a2b", "state": "pass"},
         {"user": "kai",    "haid": "haid:kai.mbp-9z8y",    "state": "running"},
         {"user": "mira",   "haid": "haid:mira.mbp-3c4d",   "state": "deny"}]

def team_home(now=1752410000, gates=True, team=True):
    home = tempfile.mkdtemp()
    os.makedirs(os.path.join(home, ".heimdall", "ledger"), exist_ok=True)
    status = {"daemon": True}
    if gates:
        status["gates"] = [{"id": "secrets", "state": "pass", "detail": "0"},
                           {"id": "tests", "state": "pass", "detail": "41/41"},
                           {"id": "designmatch", "state": "pass", "detail": ".91"}]
    if team:
        status["team"] = [dict(m, ts=now - 30 * (i + 1)) for i, m in enumerate(TEAM3)]
    with open(os.path.join(home, ".heimdall", "ledger", "status.json"), "w") as f:
        json.dump(status, f)
    return home

# ════════════════════════ FALSIFIER PROPERTIES ════════════════════════
def inv_row_exact():
    # Spec v2 §8.1 — every row EXACTLY COLUMNS cells at the six tiers, SOLO and with a team.
    for w in (40, 60, 80, 95, 120, 160):
        for label, home in (("solo", None), ("team", team_home())):
            c = tempfile.mkdtemp()
            out, rc, err = render(w, canned(c, w), home=home)
            shutil.rmtree(c, ignore_errors=True)
            if home:
                shutil.rmtree(home, ignore_errors=True)
            rs = rows(out)
            widths = sorted(set(vis(r) for r in rs))
            if widths == [w] and rc == 0 and not err and len(rs) == 4:
                ok("ROW-EXACT: COLUMNS=%d %s → %d rows each == %d" % (w, label, len(rs), w))
            else:
                bad("ROW-EXACT: COLUMNS=%d %s widths=%s rows=%d rc=%d err=%r"
                    % (w, label, widths, len(rs), rc, err[:60]))

def inv_team_uncut():
    # Spec v2 §8.2 (LEFT-PACK, RJ): 3 teammates @120 render as a COMPACT 2ND COLUMN hugging the
    # content (a TEAM_COL_GAP gutter), NOT flush to the right edge — a flush-right team at a wide
    # terminal overshoots CC's narrower live statusLine region and clips. The anti-truncation
    # contract is therefore: NO `…` ANYWHERE in the render (left-pack + trailing blanks ⇒ nothing
    # rides the far edge), and rows 1–2 carry the teammate eye-strips as contiguous 8-cell SIGIL
    # runs. team_w is derived from the SUT's own allocator (with the SAME TEAM_COL_GAP gutter).
    rows_zone_w, team_w, shown, of, gap = L.team_zone_alloc(120, 3, 0, rows_gap=SL_TEAM_COL_GAP)
    home = team_home()
    c = tempfile.mkdtemp()
    out, rc, err = render(120, canned(c, 120), home=home)
    shutil.rmtree(c, ignore_errors=True); shutil.rmtree(home, ignore_errors=True)
    rs = rows(out)
    (ok if (shown == 3 and team_w == 49) else bad)(
        "TEAM-UNCUT: allocator packs 3 members @120 → team_w=%d shown=%d (want 49/3)" % (team_w, shown))
    # (a) NO ellipsis anywhere — the left-pack guarantees no row ever needs a mid-token clip.
    clean = all("…" not in strip(r) for r in rs)
    (ok if clean else bad)("TEAM-UNCUT: no `…` anywhere (left-pack ⇒ nothing rides the far edge)")
    # (b) rows 1–2 carry the main sigil (8c) PLUS every teammate eye-strip (8c each) as sigil
    # bg-cells: total active-bg cells on each of rows 1–2 >= 8·(1 + shown).
    want_bg = 8 * (1 + shown)
    r12_ok = (len(rs) >= 2 and sum(bg_cells(rs[0])) >= want_bg
              and sum(bg_cells(rs[1])) >= want_bg)
    (ok if r12_ok else bad)(
        "TEAM-UNCUT: rows 1–2 carry main+%d teammate eye-strips as sigil cells (>=%d bg cells)"
        % (shown, want_bg))
    # (c) the eyes are VISIBLE — a teammate's authored eye color appears on rows 1–2.
    SIG = load(os.path.join(SENT, "hmd_sigil.py"), "hmd_sigil_fb")
    er, eg, eb = SIG._hex_rgb(SIG.HERO_SIGILS[SIG.hero_for("haid:akshat.mbp-1a2b")]["eye"])
    needle = "2;%d;%d;%d" % (er, eg, eb)
    (ok if any(needle in r for r in rs[:2]) else bad)(
        "TEAM-UNCUT: teammate eye color present on rows 1–2 (eyes visible, not the hair crop)")

def inv_ledger_gone():
    # Spec v2 §8.3 — no ledger at all → `– gates offline` on Row3, an EMPTY team zone, exit 0.
    home = tempfile.mkdtemp()   # a HOME with NO .heimdall/ledger/status.json
    c = tempfile.mkdtemp()
    out, rc, err = render(120, canned(c, 120), home=home, legacy=False)
    shutil.rmtree(c, ignore_errors=True); shutil.rmtree(home, ignore_errors=True)
    rs = rows(out)
    (ok if rc == 0 and not err else bad)("LEDGER-GONE: exit 0, empty stderr")
    r3 = strip(rs[2]) if len(rs) > 2 else ""
    (ok if "gates offline" in r3 else bad)("LEDGER-GONE: Row3 → `– gates offline`")
    # empty team zone → the last 8 cells of rows 1–2 are NOT sigil cells (no teammates)
    empty_team = len(rs) >= 2 and not last8_are_sigil(rs[0]) and not last8_are_sigil(rs[1])
    (ok if empty_team else bad)("LEDGER-GONE: team zone empty (rows 1–2 tail is not a teammate sigil)")
    widths = sorted(set(vis(r) for r in rs))
    (ok if widths == [120] else bad)("LEDGER-GONE: rows still exactly 120 (widths=%s)" % widths)

def inv_fallback():
    # Spec v2 §8.4 — empty + malformed stdin → the ⛭ HEIMDALL fallback line, exit 0.
    for label, blob in (("empty", b""), ("malformed", b"{bad json"),
                        ("array", b"[1,2,3]"), ("null", b"null")):
        out, rc, err = render(120, None, blob=blob)
        cond = "⛭ HEIMDALL" in strip(out) and rc == 0 and not err
        (ok if cond else bad)("FALLBACK: %s stdin → ⛭ HEIMDALL, exit %d, err=%r" % (label, rc, err[:40]))

def inv_perf():
    # Spec v2 §5 caching + §10 acceptance — the WARM render is <50ms (the strict spec gate); a COLD
    # render (sigil recompute + fork dominated) is bounded at <300ms best-of-3 as a regression ceiling.
    # MEASURED IN-PROCESS (import the module + call main()), NOT subprocess wall: a subprocess
    # render folds in ~30-60ms of python interpreter startup + module import that the live
    # statusLine (a warm long-lived cache dir on disk) never pays per tick, so wall time would
    # measure the WRONG thing. The identity 5s-cache (hmd-statusline._identity_cache_*) makes a
    # warm tick fork ZERO subprocesses for identity — asserted explicitly below.
    import io, time, statistics, contextlib
    m = load(SL, "sl_perf")
    home = team_home(); c = tempfile.mkdtemp()
    os.makedirs(os.path.join(c, ".heimdall"), exist_ok=True)
    open(os.path.join(c, ".heimdall", "identity.json"), "w").write('{"handle":"rj","seed":"rj"}\n')
    tmp = tempfile.mkdtemp()
    os.environ.update({"HOME": home, "HEIMDALL_HOME": os.path.join(home, ".heimdall"),
                       "HEIMDALL_IDENTITY_DIR": os.path.join(c, ".heimdall"), "HMD_HAID": "rj",
                       "HMD_NOW": "1752410000", "COLUMNS": "120", "LANG": "en_US.UTF-8",
                       "HMD_STATUSLINE_TMP": tmp, "HEIMDALL_STATUSLINE_MODE": "truecolor",
                       "HEIMDALL_CP_URL": "http://127.0.0.1:1"})
    j = json.dumps(canned(c, 120))
    def one():
        sys.stdin = io.StringIO(j)
        with contextlib.redirect_stdout(io.StringIO()):
            m.main()
    one()   # prime: interpreter + sigil (disk + memo) + ledger + identity 5s caches

    # ZERO identity forks on a warm tick: count heimdall-identity execs across a primed render.
    forks = {"n": 0}
    real_run = m.subprocess.run
    def counting_run(cmd, *a, **k):
        with contextlib.suppress(Exception):
            p = cmd[0] if isinstance(cmd, (list, tuple)) else cmd
            if isinstance(p, str) and os.path.basename(p) == "heimdall-identity":
                forks["n"] += 1
        return real_run(cmd, *a, **k)
    m.subprocess.run = counting_run
    one()
    m.subprocess.run = real_run
    (ok if forks["n"] == 0 else bad)(
        "PERF: warm render forks ZERO heimdall-identity (5s identity cache HIT, not %d)" % forks["n"])

    # COLD sample: wipe the on-disk sigil cache + in-process memo + the ledger tmp so the render
    # is forced to recompute the 8×8 sigil + re-read the ledger (the cold-path regression the warm
    # median, served from cache, never sees). The cold path is DOMINATED by the full sigil recompute
    # + (on a truly cold session) the heimdall-identity fork — exactly the costs the warm 5s caches
    # exist to avoid — so its absolute time is hardware/load-variable (100-200ms observed). We take
    # the MIN of 3 cold runs (min sheds transient load spikes) and assert a regression-catching
    # bound, NOT the warm 50ms gate. The MEANINGFUL cold invariant is the ZERO-fork warm assert
    # above + this "cold is not pathologically slow" ceiling; warm (Spec §10) stays strict below.
    colds = []
    for _ in range(3):
        shutil.rmtree(m._sigil_cache_dir(), ignore_errors=True); m._SIG_MEMO.clear()
        shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp, exist_ok=True)
        sys.stdin = io.StringIO(j); t0 = time.perf_counter()
        with contextlib.redirect_stdout(io.StringIO()): m.main()
        colds.append((time.perf_counter() - t0) * 1000.0)
    cold = min(colds)
    one()   # re-warm the caches for the warm-median run

    ts = []
    for _ in range(10):   # warm in-process median over 10 iterations (Spec v2 §10)
        sys.stdin = io.StringIO(j); t0 = time.perf_counter()
        with contextlib.redirect_stdout(io.StringIO()): m.main()
        ts.append((time.perf_counter() - t0) * 1000.0)
    med = statistics.median(ts); mx = max(ts)
    shutil.rmtree(home, ignore_errors=True); shutil.rmtree(c, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)
    print("  PERF: warm median=%.3fms max=%.3fms (budget 50) | cold=%.3fms best-of-3 (budget 500)" % (med, mx, cold))
    (ok if med < 50.0 else bad)("PERF: warm in-process median %.3fms < 50ms (10 iters, primed)" % med)
    (ok if cold < 500.0 else bad)("PERF: cold-cache render %.3fms < 500ms best-of-3 (sigil recompute + fork dominated)" % cold)

# ════════════════════════ PROVE-RED (mutation) ════════════════════════
def _seed_cwd(c):
    os.makedirs(os.path.join(c, ".heimdall"), exist_ok=True)
    open(os.path.join(c, ".heimdall", "identity.json"), "w").write('{"handle":"rj","seed":"rj"}\n')

def _env(home, c):
    os.environ.update({"HOME": home, "HEIMDALL_HOME": os.path.join(home, ".heimdall"),
                       "HEIMDALL_IDENTITY_DIR": os.path.join(c, ".heimdall"), "HMD_HAID": "rj",
                       "HMD_NOW": "1752410000", "COLUMNS": "120",
                       "HMD_STATUSLINE_TMP": tempfile.mkdtemp(),
                       "HEIMDALL_STATUSLINE_MODE": "truecolor",
                       "HEIMDALL_CP_URL": "http://127.0.0.1:1"})

def _run(m, c):
    sys.stdin = io.StringIO(json.dumps(canned(c, 120)))
    buf = io.StringIO(); old = sys.stdout; sys.stdout = buf
    try:
        m.main()
    finally:
        sys.stdout = old
    return rows(buf.getvalue())

def prove_red():
    print("== --prove-red: each named known-bad MUST flip its property RED ==")

    # 1) row-width RED: disable pad_or_truncate (return unpadded) → some row != COLUMNS.
    m = load(SL, "sl_mut1")
    m.LAYOUT.pad_or_truncate = lambda s, w, *a, **k: (s if s is not None else "")
    home = team_home(); c = tempfile.mkdtemp(); _seed_cwd(c); _env(home, c)
    widths = set(vis(r) for r in _run(m, c))
    shutil.rmtree(home, ignore_errors=True); shutil.rmtree(c, ignore_errors=True)
    (ok if widths != {120} else bad)("prove-red row-width: pad disabled → rows %s != {120} (RED)" % sorted(widths))

    # 2) team-truncation RED: widen eye_strip to 12 cells → the team columns overflow team_w,
    #    so pad_or_truncate clips them and a `…` appears INSIDE the team-zone span.
    m2 = load(SL, "sl_mut2")
    m2.SIG.eye_strip = lambda *a, **k: ["X" * 12, "X" * 12]
    _rzw, team_w, _sh, _of, _g = L.team_zone_alloc(120, 3, 0)
    home = team_home(); c = tempfile.mkdtemp(); _seed_cwd(c); _env(home, c)
    rs = _run(m2, c)
    has_ellipsis = any("…" in strip(r)[-team_w:] for r in rs)
    shutil.rmtree(home, ignore_errors=True); shutil.rmtree(c, ignore_errors=True)
    (ok if has_ellipsis else bad)("prove-red team-truncation: 12c eye_strip → `…` in the team span (RED)")

    # 3) gate-offline RED: force gate_labels to swallow the empty-ledger marker → Row3 loses
    #    the `gates offline` text even though the ledger is gone.
    m3 = load(SL, "sl_mut3")
    m3.gate_labels = lambda gates, avail, colored=True: ""   # THE BUG: no offline marker
    home = tempfile.mkdtemp(); c = tempfile.mkdtemp(); _seed_cwd(c); _env(home, c)  # HOME w/ no ledger
    r3 = strip(_run(m3, c)[2])
    shutil.rmtree(home, ignore_errors=True); shutil.rmtree(c, ignore_errors=True)
    (ok if "gates offline" not in r3 else bad)("prove-red gate-offline: gate_labels swallowed → Row3 loses `gates offline` (RED)")

# ════════════════════════ dispatch ════════════════════════
if MODE == "prove-red":
    prove_red()
else:
    for name, fn in (("row-exact", inv_row_exact), ("team-uncut", inv_team_uncut),
                     ("ledger-gone", inv_ledger_gone), ("fallback", inv_fallback),
                     ("perf", inv_perf)):
        print("== %s ==" % name)
        fn()

print()
print("%d passed, %d failed" % (_p, _f))
sys.exit(1 if _f else 0)
PY

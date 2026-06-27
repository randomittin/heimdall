#!/usr/bin/env python3
"""
hmd-statusline.py — Heimdall watchman statusline v2 for Claude Code.
Full-width. Personal sigil anchors the left; gate verdict pins the right; the
team watch wall fills the bottom row when teammates are live. Reads CC JSON on
stdin. Zero context cost. Falls back gracefully with no state and no team.

Ships via plugin settings.json:
  "statusLine": {"type":"command","command":"python3 ${CLAUDE_PLUGIN_ROOT}/sentinels/hmd-statusline.py","refreshInterval":3}

Modes:
  --widget   emit only the watchman+verdict segment (ccstatusline coexistence)
"""
import sys, os, json, time, re, hashlib, importlib.util, subprocess, shlex

HERE = os.path.dirname(os.path.abspath(__file__))
BIN_DIR = os.path.normpath(os.path.join(HERE, "..", "bin"))  # heimdall-identity / heimdall-presence live here
spec = importlib.util.spec_from_file_location("hmd_sigil", os.path.join(HERE, "hmd_sigil.py"))
SIG = importlib.util.module_from_spec(spec); spec.loader.exec_module(SIG)

# palette
CY="\033[38;2;34;211;238m"; GR="\033[38;2;34;197;94m"; RD="\033[38;2;239;68;68m"
AM="\033[38;2;245;158;11m"; DIM="\033[38;2;90;100;114m"; FAINT="\033[38;2;58;65;77m"
TEAL="\033[38;2;45;212;191m"  # #2dd4bf — brand wordmark + eye bracket (mockup §3 teal)
BOLD="\033[1m"; X="\033[0m"
SEP=f"{FAINT} │ {X}"
ANSI = re.compile(r"\033\[[0-9;]*m")
def vis(s): return len(ANSI.sub("", s))

def read_json():
    try: return json.load(sys.stdin)
    except Exception: return {}

def gate_state(cwd):
    p = os.environ.get("HEIMDALL_STATE", os.path.join(cwd, ".heimdall", "statusline.json"))
    try:
        with open(p) as f: return json.load(f)
    except Exception: return {}

def identity(cwd, fallback):
    """Sigil SEED + display HANDLE from bin/heimdall-identity (RJ's call: identity is a
    file each dev controls, not a derived HAID). One `--json` call resolves both. Any
    absence/error/timeout falls back to the OLD HMD_HAID/USER seed so the line never breaks."""
    seed = handle = None
    bin_path = os.path.join(BIN_DIR, "heimdall-identity")
    try:
        if os.access(bin_path, os.X_OK):
            r = subprocess.run([bin_path, "--json"], cwd=cwd, timeout=1.0,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            rec = json.loads(r.stdout.decode("utf-8", "replace") or "{}")
            seed = (rec.get("seed") or "").strip() or None
            handle = (rec.get("handle") or "").strip() or None
    except Exception:
        seed = handle = None   # any fault → drop to the env fallback below
    return (seed or fallback), (handle or seed or fallback)

def _quiet_rm(path):
    try: os.remove(path)
    except OSError: return

def _roster_cache_path(cwd): return os.path.join(cwd, ".heimdall", ".roster-cache.json")
def _beat_stamp_path(cwd): return os.path.join(cwd, ".heimdall", ".beat-stamp")

def _spawn_presence(cwd, handle, verdict):
    """ONE coordinated, fire-and-forget presence fork per render. Cheap STAT-ONLY throttle
    gates decide what is due — the beat stamp (~20s, under the server's ~45s TTL) and the
    roster cache (~4s) + refresher lock (~8s) — BEFORE anything is spawned, so a throttled
    (cold/offline) render is a pure stat → return with ZERO subprocesses. When BOTH a beat
    and a roster refresh come due they ride ONE /bin/sh child (one fork, not two); when only
    one is due only that runs. Throttle stamps are written BEFORE the fork so a crash still
    backs off (one attempt per window). Detached, non-blocking, never raises — the statusline
    must never hang or break on presence; heimdall-presence is itself a no-op when offline."""
    bin_path = os.path.join(BIN_DIR, "heimdall-presence")
    if not os.access(bin_path, os.X_OK): return
    now = time.time()
    cache = _roster_cache_path(cwd); lock = cache + ".lock"; stamp = _beat_stamp_path(cwd)
    # stat-only "is it due?" gates — NO process is spawned just to decide.
    try: beat_due = not (os.path.exists(stamp) and now - os.path.getmtime(stamp) < 20)
    except Exception: beat_due = False
    try:
        fresh  = os.path.exists(cache) and now - os.path.getmtime(cache) < 4
        locked = os.path.exists(lock)  and now - os.path.getmtime(lock)  < 8
        roster_due = (not fresh) and (not locked)
    except Exception:
        roster_due = False
    if not beat_due and not roster_due:
        return   # everything throttled → the fast no-op path: zero forks.
    try:
        os.makedirs(os.path.join(cwd, ".heimdall"), exist_ok=True)
    except Exception:
        return
    pieces = []; env = dict(os.environ)
    if beat_due:
        try: open(stamp, "w").close()   # claim the beat window BEFORE the fork → one per 20s
        except Exception: beat_due = False
    if beat_due:
        pv = {"pass": "pass", "deny": "deny", "scanning": "working",
              "watching": "watching"}.get(verdict, "working")
        env["HMD_HANDLE"] = handle or ""; env["HMD_VERDICT"] = pv
        pieces.append("%s beat >/dev/null 2>&1" % shlex.quote(bin_path))
    if roster_due:
        try: open(lock, "w").close()    # claim the refresher lock BEFORE the fork
        except Exception: roster_due = False
    if roster_due:
        tmp = cache + ".%d.tmp" % os.getpid()
        pieces.append("%s roster --json > %s 2>/dev/null && mv -f %s %s; rm -f %s" %
                      (shlex.quote(bin_path), shlex.quote(tmp), shlex.quote(tmp),
                       shlex.quote(cache), shlex.quote(lock)))
    if not pieces: return
    try:
        subprocess.Popen(["/bin/sh", "-c", "; ".join(pieces)], cwd=cwd, env=env,
                         start_new_session=True, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    except Exception:
        if roster_due: _quiet_rm(lock)   # spawn failed → drop the lock so the next render retries

def roster_presence(cwd):
    """SERVER-synced ONLINE team (devs on OTHER machines, within the server TTL), served
    INSTANTLY from a short-TTL cache. The background refresh that keeps the cache warm is
    driven by _spawn_presence (coordinated with the beat into ONE fork); here we only READ.
    An empty/missing cache returns [] so team_presence falls back to local files. Never
    blocks, never raises."""
    cache = _roster_cache_path(cwd); rows = None
    try:
        with open(cache) as f: rows = json.load(f)
    except Exception:
        rows = None
    if not isinstance(rows, list): return []
    now = time.time(); out = []
    for r in rows:
        if not isinstance(r, dict): continue
        a = r.get("age_seconds")
        ts = (now - a) if isinstance(a, (int, float)) else r.get("ts", now)
        out.append({
            "name": r.get("handle") or r.get("haid") or "?",
            "haid": r.get("haid"),
            "verdict": r.get("verdict") or "working",
            "file": r.get("file") or "",
            "ts": ts,
            "online": True,   # the roster is who is actually ONLINE now
        })
    return out

def team_presence(cwd, ttl=30):
    """Prefer the SERVER roster (online team across machines), else the local
    .heimdall/team/*.json heartbeat files (OFFLINE fallback) when the control plane is
    unreachable/unconfigured — the watch wall always renders, empty never means a hang."""
    roster = roster_presence(cwd)
    if roster: return roster
    d = os.path.join(cwd, ".heimdall", "team"); out = []
    try: names = os.listdir(d)
    except Exception: return out
    now = time.time()
    for n in names:
        if not n.endswith(".json"): continue
        try:
            with open(os.path.join(d, n)) as f: t = json.load(f)
        except Exception: continue
        if now - t.get("ts", 0) > ttl: continue   # gone stale → agent left
        out.append(t)
    out.sort(key=lambda t: t.get("name", ""))
    return out

VERDICT = {  # verdict -> (eye color rgb, ansi col, glyph, word)
 "pass":     ((34,197,94),  GR, "✓", "GATE"),
 "deny":     ((239,68,68),  RD, "✗", "BIFRÖST CLOSED"),
 "scanning": ((245,158,11), AM, "◦", "scanning"),
 "watching": ((34,211,238), CY, "◦", "watching"),
}

def main():
    data = read_json()
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or os.getcwd()
    model = (data.get("model") or {}).get("display_name", "Claude")
    cw = data.get("context_window") or {}
    pct = int(cw.get("used_percentage") or 0)
    repo = ((data.get("workspace") or {}).get("repo") or {}).get("name") or os.path.basename(cwd)
    # identity is FILE-controlled (bin/heimdall-identity): seed feeds the sigil, handle
    # shows on the wall. Falls back to the old HMD_HAID/USER resolution if the bin errors.
    fallback = os.environ.get("HMD_HAID") or os.environ.get("USER") or "you"
    seed, handle = identity(cwd, fallback)

    st = gate_state(cwd)
    verdict = st.get("verdict", "watching")
    if verdict not in VERDICT: verdict = "watching"
    eye_rgb, vcol, vglyph, vword = VERDICT[verdict]
    passed, total = st.get("passed"), st.get("total")
    cols = int(os.environ.get("COLUMNS") or 120)
    RMARGIN = 6  # right safety gutter: clears Claude Code's scrollbar + edge padding so the verdict never clips off-screen

    # ── animation: the watchman keeps a bright WHITE eye glint so the face
    # always reads. The verdict is shown by the right block + bar + bifröst
    # text — NOT by recoloring the eyes: a verdict-colored eye washes into a
    # same-hue body (e.g. cyan 'watching' eyes on a teal sigil) and erases the
    # face. SQUINT, not blink: every ~5s the eyes DIM to a muted white, they
    # NEVER go dark. A still can land on any frame, so a full-dark blink could
    # be captured eyeless — a squint keeps the watchman's eyes visible in EVERY
    # frame. Scanning gets the same gentle dim pulse. HMD_NOW overrides the
    # clock for deterministic conformance. (The red deny-flash lives in
    # hmd-gate-anim.sh, not here.)
    t = int(os.environ.get("HMD_NOW") or time.time())
    SQUINT = (150, 160, 175)                      # muted white — dimmed, never dark
    eye = SQUINT if (t % 5 == 0) else None        # None -> default bright white glint
    if verdict == "scanning" and (t % 2 == 0): eye = SQUINT  # subtle dim pulse, still visible

    if "--widget" in sys.argv:
        eyes = {"pass":"^ ^","deny":"O O","scanning":". .","watching":"• •"}[verdict]
        cnt = f" {passed}/{total}" if passed is not None else ""
        sys.stdout.write(f"{CY}▐{X}{vcol}{eyes}{X}{CY}▌{X} {vcol}{vglyph} {vword}{cnt}{X}")
        return

    # keep THIS dev present on teammates' walls AND warm the roster cache in ONE fork: a
    # throttled, detached beat + roster refresh (the roster read alone never announced us).
    # Stat-only throttle gates → ZERO forks when both are throttled. Never blocks the render.
    _spawn_presence(cwd, handle, verdict)

    # ── sigil anchor (squint animates; eyes stay visible in every frame) ──
    sig = SIG.render(seed, eye_override=eye, pad="")  # 4 rows, 9 cols
    SW = 9
    ANCHOR = SW + 2  # sigil(9 cols) + 2-space gutter, prefixed on EVERY row

    # context bar
    bcol = RD if pct >= 90 else AM if pct >= 70 else GR
    fill = min(10, round(pct / 10))  # 38% -> 4 cells (mockup §3), not floor(3)
    bar = f"{bcol}{'▓'*fill}{FAINT}{'░'*(10-fill)}{X} {bcol}{pct}%{X}"

    # token gauge (honest: absolute input tokens from CC, else derived from %×size)
    def human(n):
        if not n: return None
        return f"{n//1000}k" if n >= 1000 else str(n)
    tin = cw.get("total_input_tokens")
    size = cw.get("context_window_size")
    if not tin and pct and size: tin = int(size * pct / 100)
    toks = human(tin)
    tok_seg = f"{SEP}{DIM}↓{toks}{X}" if toks else ""

    # ledger claim count (live coordination signal — count claim files, no subprocess)
    def ledger_claims(p):
        d = os.path.join(p, ".planning", "ledger", "claims")
        try: return sum(1 for n in os.listdir(d) if n.endswith(".json"))
        except Exception: return 0
    claims = ledger_claims(cwd)
    claim_txt = f"{DIM}ledger {claims} claim{'s' if claims != 1 else ''}{X}" if claims else ""
    claim_seg = f" {FAINT}·{X} {claim_txt}" if claim_txt else ""  # with leading separator, appended after bifröst

    # inline eye bracket `▐ ● ● ▌` — brand teal, NOT verdict-colored (§3 row0; a
    # verdict hue washes the eyes into the body). Verdict reads from the right block.
    eyes_inline = f"{TEAL}▐ ● ● ▌{X}"

    # right-aligned verdict block. IDLE (verdict==watching, no gate verdict) showed
    # "watching" TWICE — r1 glyph-word AND r2 bifröst-else. Dedup: idle shows it ONCE.
    idle = (verdict == "watching" and passed is None)
    if idle:
        r1 = f"{DIM}◦ watching{X}"          # single calm idle marker, top-right
        r2 = claim_txt                       # ledger claim if any, else EMPTY — never a 2nd "watching"
    else:
        r1 = f"{vcol}{BOLD}{vglyph} {vword}{X}" + (f" {vcol}{passed}/{total}{X}" if passed is not None else "")
        bifrost = (f"{GR}bifröst open{X}" if verdict=="pass" else
                   f"{RD}bifröst closed{X}" if verdict=="deny" else f"{DIM}watching{X}")
        r2 = f"{bifrost}{claim_seg}"

    # left info rows
    l1 = f"{eyes_inline} {TEAL}{BOLD}HEIMDALL{X}{SEP}{DIM}{handle}{X}{SEP}{DIM}{model}{X}"
    l2 = f"{bar}{SEP}{AM}{repo}:main{X}{tok_seg}"

    # team wall (only when teammates present). WIDTH-AWARE capacity: fit as many of the
    # most-recently-active teammates as the row width allows (COLUMNS minus the sigil
    # anchor + right gutter), then "+N more" for the overflow — no clip past the gutter.
    team = team_presence(cwd)
    wall_segs = []
    if team:
        team = sorted(team, key=lambda t: t.get("ts", 0), reverse=True)

        def member_seg(m):  # the per-teammate render — formula unchanged, + an online pip
            v = m.get("verdict", "working")
            col = {"pass":GR,"done":GR,"deny":RD,"working":AM,"watching":CY}.get(v, CY)
            ergb = {"pass":(34,197,94),"done":(34,197,94),"deny":(239,68,68),"working":(245,158,11)}.get(v)
            g = SIG.glyph(m.get("name","?"), eye_override=ergb)
            state = ({"pass":"✓","done":"✓","deny":"✗","working":"⚡"}.get(v,"◦"))
            f = m.get("file","")
            # online status: a server-roster teammate is live NOW (green ●); a local
            # file-fallback heartbeat shows a faint ◦.
            pip = f"{GR}●{X}" if m.get("online") else f"{FAINT}◦{X}"
            label = f"{m.get('name','?')} {col}{state}{(' '+f) if f else ''}{X}"
            seg = f"{pip} {g} {label}"
            if v == "deny":  # the moment — make it pop
                seg = f"{RD}▕{X}{pip} {g} {RD}{BOLD}{m.get('name','?')} ✗ BIFRÖST{(' '+f) if f else ''}{X}{RD}▏{X}"
            return seg

        header = f"{FAINT}── watch ──{X}"
        you_state = {"pass": "✓", "deny": "✗", "scanning": "◦"}.get(verdict, "⚡")
        you_word  = {"pass": "proven", "deny": "blocked", "scanning": "scanning"}.get(verdict, "working")
        you_seg = f"{SIG.glyph(seed)} {BOLD}you{X} {DIM}{you_state} {you_word}{X}"  # your watchman closes the wall

        JOIN = 2                                   # the "  " between wall segments
        budget = max(0, cols - (SW + 2) - RMARGIN) # usable row width: COLUMNS − sigil anchor − gutter
        used = vis(header) + JOIN + vis(you_seg)   # header + the you-closer are always shown
        chosen = []
        for m in team:
            seg = member_seg(m)
            if chosen and used + JOIN + vis(seg) > budget: break
            chosen.append((m, seg)); used += JOIN + vis(seg)
        extra = len(team) - len(chosen)
        while extra > 0 and chosen and used + JOIN + vis(f"{DIM}+{extra} more{X}") > budget:
            m, seg = chosen.pop(); used -= JOIN + vis(seg); extra += 1   # make room for the "+N more" tag

        wall_segs.append(header)
        for m, seg in sorted(chosen, key=lambda ms: ms[0].get("name", "")):
            wall_segs.append(seg)
        if extra > 0:
            wall_segs.append(f"{DIM}+{extra} more{X}")
        wall_segs.append(you_seg)

    def line(left, right):
        # account for the sigil anchor prefixed on every row AND a right safety
        # gutter, so the right block pins inside the usable width — Claude Code
        # reserves the far-right edge (scrollbar + padding) and clips anything
        # rendered at exactly COLUMNS.
        gap = cols - ANCHOR - RMARGIN - vis(left) - vis(right)
        return left + (" " * max(1, gap)) + right

    out = []
    out.append(f"{_sig(sig,0,CY)}  " + line(l1, r1))
    out.append(f"{_sig(sig,1,CY)}  " + line(l2, r2))
    if wall_segs:
        wall = "  ".join(wall_segs)
        out.append(f"{_sig(sig,2,CY)}  " + wall)
        out.append(f"{_sig(sig,3,CY)}  ")
    else:
        # SOLO TEASE: the wall is empty (no roster, no team files). Fill the dead row
        # with a faint invite — sells the team feature, drives the growth loop. Single
        # row, width-safe (<= COLUMNS − sigil anchor − gutter): dropped if it can't fit.
        tease = f"{FAINT}── watch ── invite your team · hmd invite{X}"
        if vis(tease) > max(0, cols - ANCHOR - RMARGIN): tease = ""
        out.append(f"{_sig(sig,2,CY)}  " + tease)
        out.append(f"{_sig(sig,3,CY)}  ")
    sys.stdout.write("\n".join(out) + "\n")

def _sig(rows, i, fallback):
    return rows[i] if i < len(rows) else "         "

if __name__ == "__main__":
    main()

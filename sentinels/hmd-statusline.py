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
_tcspec = importlib.util.spec_from_file_location("hmd_termcaps", os.path.join(HERE, "hmd_termcaps.py"))
TC = importlib.util.module_from_spec(_tcspec); _tcspec.loader.exec_module(TC)

# ── terminal capability tier ─────────────────────────────────────────────────
# CC's statusLine is non-TTY but truecolor, so we can't lean on isatty alone.
# hmd_termcaps.detect() resolves a graded tier from $COLORTERM/$TERM/$TERM_PROGRAM/
# $TMUX (+ the --no-color/--plain flag hooks/statusline.sh passes, + the
# HEIMDALL_STATUSLINE_MODE override): color ∈ {truecolor,256,16,mono}, unicode ∈
# {full,basic,ascii}. The line is BUILT in 24-bit truecolor + full unicode exactly
# as before; CAPS.emit() downgrades the finished bytes in one pass at write time
# (truecolor+full = byte-identical NO-OP). USE_COLOR gates the palette (empty codes
# → clean plain text) so the sigil/glyphs that emit ANSI regardless collapse too.
CAPS = TC.detect(sys.argv)
USE_COLOR = CAPS.use_color()
def _c(s): return s if USE_COLOR else ""
def _write(s):
    # single choke point: every render path emits through the tier downgrade.
    sys.stdout.write(CAPS.emit(s))

# a branded ASCII sigil for no-unicode terminals (dumb/CI): 4 rows × 8 cols so the
# 8-wide square-sigil anchor + 2-space gutter (ANCHOR=10) alignment is preserved.
ASCII_SIGIL = ["  ____  ", " |o  o| ", " |____| ", "  hmd   "]
def _sigil_rows(seed, eye):
    """The left anchor per tier: half-block watchman when unicode=full + color on
    (color downgraded by emit); a branded ASCII sigil for no-unicode terms; a blank
    8-wide anchor for mono+unicode (preserves the legacy no-color blank behavior)."""
    if CAPS.unicode == TC.ASCII:
        return list(ASCII_SIGIL)
    if CAPS.color == TC.MONO:
        return ["        "] * 4
    if CAPS.unicode == TC.FULL:
        try: return cached_sigil(seed, "M", CAPS, eye)   # shared core, cached (§1/§5)
        except Exception: return list(ASCII_SIGIL)
    return list(ASCII_SIGIL)   # basic unicode + color → safe ASCII sigil

def _sigil_rows_s(seed, eye):
    """The COMPACT anchor: sigil S (4 cols × 2 rows) through the same shared/cached
    core as the full-mode M anchor, with the identical per-tier fallbacks (ASCII
    mini-anchor on no-unicode, blank on mono, safe ASCII on basic)."""
    if CAPS.unicode == TC.ASCII:
        return list(ASCII_SIGIL_S)
    if CAPS.color == TC.MONO:
        return ["    ", "    "]
    if CAPS.unicode == TC.FULL:
        try: return cached_sigil(seed, "S", CAPS, eye)
        except Exception: return list(ASCII_SIGIL_S)
    return list(ASCII_SIGIL_S)

def _wall_state(v):
    """Teammate verdict → the compact wall's three visual states (spec B §4):
    deny → red-frame, watching/idle → dim, everything live → solid."""
    nv = _norm_verdict(v)
    if nv == "deny": return "deny"
    if nv == "watching": return "idle"
    return "active"

def wall_state_glyph(seed, state):
    """One teammate cell for the compact wall: a ◉ tinted by the teammate's DOMINANT
    sigil color (glyph_color — identity, NOT verdict), with state carried by the
    frame/intensity: active = solid hue, idle = dimmed hue, deny = red ▕ ▏ frame
    around the hue glyph. In no-color mode the glyph collapses to a bare ◉ (emit
    strips the tint)."""
    try: hue = SIG.glyph_color(seed)
    except Exception: hue = (90, 100, 114)
    if not USE_COLOR:
        return "▕◉▏" if state == "deny" else "◉"
    if state == "deny":
        return f"{RD}▕{X}{sgr(hue)}◉{X}{RD}▏{X}"
    if state == "idle":
        dim = tuple(max(0, c * 45 // 100) for c in hue)
        return f"{sgr(dim)}◉{X}"
    return f"{sgr(hue)}◉{X}"

def compact_wall(cwd, seed, my_verdict, present, cols, anch):
    """A row of teammate GLYPHS for the compact HUD: your glyph first, then live
    teammates (most-recent first) tinted by glyph_color, capped to the row budget
    with a `+k` overflow tag (spec B §4). Width-safe: stops before the gutter, never
    slicing a glyph."""
    budget = max(0, cols - anch - 6)   # usable width: cols − S anchor − right gutter
    you_state = ("deny" if my_verdict == "deny"
                 else "idle" if my_verdict == "watching" else "active")
    if present:
        parts = [wall_state_glyph(seed, you_state)]
    else:
        parts = [f"{FAINT}◦{X}"]        # you are invisible (presence off) — a faint dot
    used = vis(parts[0]); JOIN = 1
    team = sorted(team_presence(cwd), key=lambda m: m.get("ts", 0), reverse=True)
    shown = 0
    for m in team:
        g = wall_state_glyph(m.get("name", "?"), _wall_state(m.get("verdict", "working")))
        if used + JOIN + vis(g) > budget: break
        parts.append(g); used += JOIN + vis(g); shown += 1
    extra = len(team) - shown
    if extra > 0:
        tag = f"{DIM}+{extra}{X}"
        while shown > 0 and used + JOIN + vis(tag) > budget:
            dropped = parts.pop(); shown -= 1; extra += 1
            used -= JOIN + vis(dropped); tag = f"{DIM}+{extra}{X}"
        parts.append(tag)
    return " ".join(parts)

# palette (empty in no-color mode → f-strings render as plain text)
CY=_c("\033[38;2;34;211;238m"); GR=_c("\033[38;2;34;197;94m"); RD=_c("\033[38;2;239;68;68m")
AM=_c("\033[38;2;245;158;11m"); DIM=_c("\033[38;2;90;100;114m"); FAINT=_c("\033[38;2;58;65;77m")
TEAL=_c("\033[38;2;45;212;191m")  # #2dd4bf — brand wordmark + eye bracket (mockup §3 teal)
BOLD=_c("\033[1m"); X=_c("\033[0m")
SEP=f"{FAINT} │ {X}"
ANSI = re.compile(r"\033\[[0-9;]*m")
# visible width is tier-aware: emoji (e.g. ⚡) are double-width when unicode=full,
# but width-1 once downgraded to ASCII — so the right-pin math tracks the real cells.
def vis(s): return CAPS.width(s)

def sgr(rgb):
    """A 24-bit fg SGR for an arbitrary rgb, gated by USE_COLOR (empty → plain text)
    and downgraded to the detected tier at write time by CAPS.emit (like the fixed
    palette above). Used for per-identity glyph tints (glyph_color)."""
    return _c("\033[38;2;%d;%d;%dm" % (rgb[0], rgb[1], rgb[2]))

# ── DENSITY (spec B §2) ────────────────────────────────────────────────────────
# Auto-select by terminal width. NEVER truncate mid-glyph: each mode renders a
# self-contained block whose rows are padded (finalize) to a uniform width, so a
# line is either fully present or absent — never sliced through a half-block/emoji.
#   full    (≥120): sigil M + name + verdict + team wall (the rich ambient HUD)
#   compact (80–119): sigil S + verdict + wall GLYPHS (tinted, +k overflow)
#   minimal (<80):    a single glyph + the verdict word
def density(cols):
    if cols >= 120: return "full"
    if cols >= 80:  return "compact"
    return "minimal"

# ── VERDICT SEMANTICS (spec B §3) ──────────────────────────────────────────────
# PASS / DENY / RUNNING / IDLE — each a FIXED glyph + color, identical across every
# capability tier (the bytes are built once in truecolor and CAPS.emit maps the color
# to the tier deterministically, so the glyph never changes and the hue maps 1:1).
# DENY PULSES via a TWO-FRAME alternation on the refresh tick (SGR blink is BANNED):
# frame A = bold bright red, frame B = a dimmer red — SAME glyph+word+width, so the
# pulse never shifts columns (width invariant holds across both frames).
VERDICT_CANON = {
    "PASS":    ((34, 197, 94),  "✓", "PASS"),
    "DENY":    ((239, 68, 68),  "✗", "DENY"),
    "RUNNING": ((245, 158, 11), "⟳", "RUNNING"),
    "IDLE":    ((34, 211, 238), "◦", "IDLE"),
}
CANON_OF = {
    "pass": "PASS", "proven": "PASS", "green": "PASS", "done": "PASS", "ok": "PASS",
    "deny": "DENY", "blocked": "DENY", "fail": "DENY", "failed": "DENY", "closed": "DENY",
    "scanning": "RUNNING", "scan": "RUNNING", "running": "RUNNING", "working": "RUNNING",
    "active": "RUNNING", "busy": "RUNNING",
    "watching": "IDLE", "idle": "IDLE",
}
def canon_verdict(v):
    return CANON_OF.get((v or "").strip().lower(), "IDLE")

def _deny_dim(rgb, tick):
    """Frame B of the DENY pulse: a dimmer red on odd ticks (frame A = full red on
    even). Two-frame, deterministic on the tick — no SGR blink."""
    if tick % 2 == 1:
        return tuple(max(0, c * 6 // 10) for c in rgb)
    return rgb

def verdict_seg(canon, tick):
    """The fixed glyph + word for a verdict, pulsing on DENY. Same width every frame."""
    rgb, g, w = VERDICT_CANON[canon]
    if canon == "DENY": rgb = _deny_dim(rgb, tick)
    return f"{sgr(rgb)}{BOLD}{g} {w}{X}"

def verdict_word(canon, tick):
    """Just the colored word (minimal mode), pulsing on DENY."""
    rgb, _g, w = VERDICT_CANON[canon]
    if canon == "DENY": rgb = _deny_dim(rgb, tick)
    return f"{sgr(rgb)}{BOLD}{w}{X}"

# ── SIGIL CACHE (spec B §5) ────────────────────────────────────────────────────
# Precompute the sigil to a cached string per (haid, size, caps[, eye]). The cache
# key embeds the capability tier so a CAPS CHANGE — and only a caps change (plus the
# small fixed set of animation eye-colors) — invalidates it; a verdict/context/token
# change never rebuilds the sigil. An in-process memo makes repeat lookups within one
# render free; a durable on-disk layer under ~/.heimdall/.sigil-cache carries the
# precompute across the per-refresh process spawns, keeping render well under 50ms.
# Bytes are stored in native truecolor (tier-independent); the single tier downgrade
# happens later in finalize(), so the same cache serves every surface consistently.
_SIG_MEMO = {}
def _sigil_cache_dir():
    return os.path.join(os.path.expanduser("~"), ".heimdall", ".sigil-cache")

def _sigil_version():
    """A short CONTENT hash of hmd_sigil.py's source, folded into the cache key. Any
    change to the sigil code (grids, palette, render logic, the border frame) mints a
    fresh key → the stale on-disk sigil is never served again, with NO manual cache
    clear (the "sigil never updated" bug). Falls back to '0' when the source can't be
    read — the key then degrades to the old tier/eye/seed behavior, never crashing."""
    try:
        src = getattr(SIG, "__file__", None) or os.path.join(HERE, "hmd_sigil.py")
        with open(src, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:12]
    except Exception:
        return "0"
_SIG_VERSION = _sigil_version()

def cached_sigil(seed, size, caps, eye, border=True):
    eyt = tuple(eye or SIG.EYE)
    ekey = "%02x%02x%02x" % (eyt[0], eyt[1], eyt[2])
    # the version hash + border flag are part of the key/filename → a code change (or
    # a border toggle) invalidates the cache automatically; only a tier/eye/seed/
    # version/border match hits the stored sigil.
    ckey = "%s-%s-%s%s" % (caps.color, caps.unicode, _SIG_VERSION, "b" if border else "")
    memo_k = (seed, size, ckey, ekey)
    m = _SIG_MEMO.get(memo_k)
    if m is not None: return list(m)
    lines = None
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", seed or "you")[:48]
    path = os.path.join(_sigil_cache_dir(), "%s__%s__%s__%s.sig" % (safe, size, ckey, ekey))
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().split("\n")
    except Exception:
        lines = None
    if lines is None:
        try:
            lines = SIG.sigil_render(seed, size, SIG.tier_caps(), eye_override=eye, border=border)
        except Exception:
            lines = None
        if lines is not None:
            try:
                os.makedirs(_sigil_cache_dir(), exist_ok=True)
                tmp = path + ".%d.tmp" % os.getpid()
                with open(tmp, "w", encoding="utf-8") as f: f.write("\n".join(lines))
                os.replace(tmp, path)
            except Exception:
                lines = lines   # cache write is best-effort; a miss just recomputes
    if lines is None:
        lines = list(ASCII_SIGIL) if size == "M" else ["    ", "    "]
    _SIG_MEMO[memo_k] = list(lines)
    return list(lines)

# a 4-wide × 2-row branded ASCII anchor for the compact mode's no-unicode fallback.
ASCII_SIGIL_S = [" __ ", "|oo|"]

def _clamp_row(s, maxw):
    """Truncate one already-emitted row to `maxw` VISIBLE cells without slicing an
    ANSI escape or a wide glyph in half. ANSI codes carry zero width and are copied
    verbatim; a visible glyph is dropped whole once it would cross the budget. A
    reset is appended iff the row carried color AND was actually clipped, so a
    truncated row never bleeds its last SGR into the terminal. maxw<=0 → empty."""
    if maxw is None:
        return s
    if maxw <= 0:
        return ""
    out = []; w = 0; pos = 0; n = len(s); had_ansi = False; clipped = False
    while pos < n:
        m = ANSI.match(s, pos)
        if m:
            out.append(m.group(0)); had_ansi = True; pos = m.end(); continue
        ch = s[pos]; cw = CAPS.width(ch)
        if w + cw > maxw:
            clipped = True; break
        out.append(ch); w += cw; pos += 1
    r = "".join(out)
    if clipped and had_ansi:
        r += "\033[0m"   # close any dangling SGR so the clip never bleeds color
    return r

def finalize(lines, clamp=None):
    """Emit every row to the detected tier (the single downgrade pass), CLAMP each to
    the available terminal width so no row can overflow COLUMNS and wrap onto a 2nd
    visual line (the double-header / 8.5-row-sigil bleed), then pad each to the
    uniform MAX visible width so ALL rows are wcwidth-equal — the width invariant the
    density goldens assert (spec Tests 2–3). Pad is trailing spaces only; clamp drops
    whole glyphs only — so a line is never sliced mid-glyph and never wraps."""
    em = [_clamp_row(CAPS.emit(ln), clamp) for ln in lines]
    ws = [CAPS.width(ln) for ln in em]
    W = max(ws) if ws else 0
    return "\n".join(ln + " " * (W - w) for ln, w in zip(em, ws))

def read_json():
    try: return json.load(sys.stdin)
    except Exception: return {}

def gate_state(cwd):
    p = os.environ.get("HEIMDALL_STATE", os.path.join(cwd, ".heimdall", "statusline.json"))
    try:
        with open(p) as f: return json.load(f)
    except Exception: return {}

def _parse_semver(v):
    """Parse a vX.Y.Z (optional leading v) into a comparable (int,int,int) tuple,
    or None when it does NOT cleanly match — mirrors bin/heimdall's _update_semver_cmp
    parser so a malformed/empty version can never yield a false 'behind'."""
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)$", (v or "").strip())
    return tuple(int(x) for x in m.groups()) if m else None

def update_notice():
    """A compact 'update available' HUD notice, read PURELY from the update-check
    cache that bin/heimdall's daily BACKGROUND probe writes — NO network and NO
    subprocess on this render path (the statusline must stay fast + off-box). The
    cache lives at ${HEIMDALL_HOME:-~/.heimdall}/update-check.json and holds
    {checked_epoch, installed, latest} (the exact schema the probe writes). Returns
    the notice iff the cached installed version is STRICTLY older than the cached
    latest; returns '' (silent) on a current/ahead install, a missing/corrupt/
    unparseable cache, or ANY fault — a fail-safe that never breaks the line and
    never cries a false 'behind'."""
    home = os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")
    try:
        with open(os.path.join(home, "update-check.json")) as f:
            d = json.load(f)
        installed = _parse_semver(d.get("installed"))
        latest_raw = (d.get("latest") or "").strip()
        latest = _parse_semver(latest_raw)
    except Exception:
        return ""
    if not installed or not latest or installed >= latest:
        return ""
    return f"{AM}⬆ {latest_raw} available{X} {FAINT}·{X} {DIM}hmd --update{X}"

def usage_limit_seg(data, now):
    """The session-relevant 5-HOUR usage-limit indicator, pinned at the rightmost end
    of the top row. Reads rate_limits.five_hour.{used_percentage,resets_at} from CC's
    stdin JSON — present ONLY for Pro/Max accounts and ABSENT until the first API
    response, so a missing/malformed field returns '' (render NOTHING, never a fake %).
    Renders `⧗ NN%` color-graded green→amber→red as it approaches 100, plus a compact
    resets-in countdown (`·2h` / `·45m`) when resets_at is a future epoch. HMD_NOW
    drives the clock for deterministic conformance (same override the eye animation uses)."""
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return ""
    fh = rl.get("five_hour")
    if not isinstance(fh, dict):
        return ""
    up = fh.get("used_percentage")
    if not isinstance(up, (int, float)) or isinstance(up, bool):
        return ""                                   # absent/malformed → NO fabrication
    pct = max(0, min(100, int(round(up))))
    col = RD if pct >= 90 else AM if pct >= 70 else GR   # green→amber→red toward the cap
    seg = f"{col}⧗ {pct}%{X}"
    ra = fh.get("resets_at")
    if isinstance(ra, (int, float)) and not isinstance(ra, bool) and ra > now:
        rem = int(ra - now)
        cd = f"{rem // 3600}h" if rem >= 3600 else f"{max(1, rem // 60)}m"
        seg += f" {FAINT}·{X}{DIM}{cd}{X}"           # compact "resets in" countdown
    return seg

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

def _presence_state(cwd):
    """Effective presence opt-out — read from the SAME durable state bin/heimdall-presence
    writes: the global ~/.heimdall/presence-off stamp (existence = off) + the per-repo
    <cwd>/.heimdall/presence.json ({"enabled": false} = off, {"files": false} = file detail
    withheld). Returns (present, files_shown). Default (no files) = present — existing users
    unchanged. Pure stat/JSON reads, never raises (the statusline must never break)."""
    present, files_shown = True, True
    gp = os.path.join(os.path.expanduser("~"), ".heimdall", "presence-off")
    try:
        if os.path.exists(gp): present = False
    except Exception: present = present   # any stat fault → leave the default (present)
    try:
        with open(os.path.join(cwd, ".heimdall", "presence.json")) as f: st = json.load(f)
        if isinstance(st, dict):
            if st.get("enabled") is False: present = False
            if st.get("files") is False: files_shown = False
    except Exception: files_shown = files_shown   # absent/unreadable → default (present, shown)
    return present, files_shown

def _spawn_presence(cwd, handle, verdict, present=True):
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
    # OFF = ZERO beats: an opted-out dev writes NO .beat-stamp and forks NO beat (invisible to
    # teammates). The roster refresh below is untouched — OFF is invisible, NOT blind. FALSIFIER:
    # drop this line and an off render writes the stamp + forks a beat → the optout test goes RED.
    if not present: beat_due = False
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

def sig_glyph(seed, rgb=None):
    """One identity cell — the watchman ◉ from hmd_sigil, verdict-tinted. In
    no-color mode SIG.glyph would still emit ANSI, so return a bare ◉ instead."""
    if not USE_COLOR: return "◉"
    try: return SIG.glyph(seed, eye_override=rgb)
    except Exception: return f"{DIM}◉{X}"

# ── the parallel-agent SWARM: the REAL live-agent set, never fabricated ────────
# Roster   = bin/agent-pool (active agents: id, role/type, pid) under ~/.heimdall.
# Surface  = the claim ledger (.planning/ledger/claims/*.json — an agent's current
#            claimed file) with bin/shared-memory (ns swarm-file) as fallback.
# Verdict  = bin/shared-memory (ns swarm-gate) — each agent's live gate verdict —
#            falling back to "working" for a live-but-unreported agent.
# All reads are plain file / SQLite reads (no subprocess, no network) so the
# statusline stays a few milliseconds on every render.

def _home(): return os.path.expanduser("~")

def _agent_pool_file():
    """Mirror agent-pool._resolve_pool_file: ~/.heimdall, adopting a pre-existing
    legacy ~/.superx pool. HOME-relative, so tests isolate by redirecting HOME."""
    new = os.path.join(_home(), ".heimdall", "agent-pool.json")
    legacy = os.path.join(_home(), ".superx", "agent-pool.json")
    if not os.path.exists(new) and os.path.exists(legacy): return legacy
    return new

def active_swarm_agents():
    """The live roster from agent-pool: only status=='active' agents, and only
    those whose PID is still alive (a dead-but-unreaped entry is NOT a real agent
    — never render a ghost tile). Returns ([{id, role, started_at}], max_agents)."""
    try:
        with open(_agent_pool_file()) as f: pool = json.load(f)
    except Exception:
        return [], 0
    if not isinstance(pool, dict): return [], 0
    agents = pool.get("agents") or {}
    if not isinstance(agents, dict): return [], 0
    mx = pool.get("max_agents") or 0
    out = []
    for aid, info in agents.items():
        if not isinstance(info, dict) or info.get("status") != "active": continue
        pid = info.get("pid")
        if isinstance(pid, int):
            try: os.kill(pid, 0)
            except ProcessLookupError: continue      # dead → not a real live agent
            except Exception: pass                    # PermissionError etc. → alive
        out.append({"id": aid, "role": (info.get("type") or "agent"),
                    "started_at": info.get("started_at") or ""})
    out.sort(key=lambda a: (a["started_at"], a["id"]))
    return out, mx

def _slug(s):  # match heimdall-haid's slug: alnum runs → '-', lowercased, trimmed
    return re.sub(r"[^A-Za-z0-9]+", "-", s or "").strip("-").lower()

def _iso_epoch(s):
    try:
        from datetime import datetime
        return datetime.fromisoformat((s or "").strip().replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def swarm_claims(cwd):
    """Current claimed surface per haid, from the coordination ledger. Honors
    HEIMDALL_PLANNING_DIR (tests + non-default checkouts), else <cwd>/.planning.
    TTL-expired claims are skipped so a stale surface never renders."""
    base = os.environ.get("HEIMDALL_PLANNING_DIR") or os.path.join(cwd, ".planning")
    d = os.path.join(base, "ledger", "claims")
    out = {}
    try: names = os.listdir(d)
    except Exception: return out
    now = time.time()
    for n in names:
        if not n.endswith(".json"): continue
        try:
            with open(os.path.join(d, n)) as f: c = json.load(f)
        except Exception: continue
        if not isinstance(c, dict): continue
        hb = c.get("heartbeat") or c.get("claimed_at")
        ttl = c.get("ttl_minutes") or 90
        e = _iso_epoch(hb) if hb else None
        if e and now > e + ttl * 60: continue          # expired → not active
        surfs = [s for s in (c.get("claimed_surfaces") or []) if isinstance(s, str)]
        rec = {"task": c.get("task_ref") or "", "surface": surfs[0] if surfs else ""}
        haid = c.get("haid") or ""
        if haid: out[haid] = rec; out[_slug(haid)] = rec
    return out

def swarm_shared(ns):
    """A namespace snapshot from bin/shared-memory's SQLite (read-only, expiry
    honored). Empty/missing DB → {}. Never blocks (0.5s busy timeout)."""
    dbp = (os.environ.get("HEIMDALL_MEMORY_DB") or os.environ.get("SUPERX_MEMORY_DB")
           or os.path.join(_home(), ".heimdall", "shared-memory.db"))
    if not os.path.exists(dbp):
        legacy = os.path.join(_home(), ".superx", "shared-memory.db")
        if os.path.exists(legacy): dbp = legacy
        else: return {}
    out = {}
    try:
        import sqlite3
        conn = sqlite3.connect("file:%s?mode=ro" % dbp, uri=True, timeout=0.5)
        now = time.time()
        for k, v, exp in conn.execute(
                "SELECT key, value, expires_at FROM memory WHERE namespace=?", (ns,)):
            if exp is not None and exp < now: continue
            out[k] = v
        conn.close()
    except Exception:
        return {}
    return out

_VERDICT_ALIAS = {
    "pass":"pass","proven":"pass","green":"pass","done":"pass","ok":"pass",
    "deny":"deny","blocked":"deny","fail":"deny","failed":"deny","closed":"deny",
    "working":"working","active":"working","running":"working","busy":"working",
    "scan":"scanning","scanning":"scanning",
    "watching":"watching","idle":"watching",
}
def _norm_verdict(v): return _VERDICT_ALIAS.get((v or "").strip().lower(), "working")

def _swarm_v(v):  # normalized verdict -> (eye rgb, ansi col, glyph, word)
    return {
        "pass":     ((34,197,94),  GR, "✓", "proven"),
        "deny":     ((239,68,68),  RD, "✗", "BIFRÖST"),
        "working":  ((245,158,11), AM, "⟳", "working"),
        "scanning": ((245,158,11), AM, "◦", "scanning"),
        "watching": ((34,211,238), CY, "◦", "watching"),
    }[v]

def swarm_block(cwd):
    """Build the SWARM block rows (header + one aligned row per live agent), or
    None when 1-or-fewer agents are active (→ the normal HUD is untouched). Each
    row is spectacle + receipt: mini-sigil · role · gate glyph · current file."""
    agents, mx = active_swarm_agents()
    if len(agents) < 2: return None
    gate = swarm_shared("swarm-gate"); files = swarm_shared("swarm-file")
    claims = swarm_claims(cwd)
    def _lookup(m, aid): return m.get(aid) or m.get(_slug(aid))
    entries = []
    for a in agents:
        aid = a["id"]
        v = _norm_verdict(_lookup(gate, aid) or "working")
        cl = _lookup(claims, aid) or {}
        surface = (cl.get("surface") or cl.get("task")
                   or _lookup(files, aid) or "")
        entries.append((a, v, surface))
    role_w = min(13, max(len(a["role"]) for a, _, _ in entries))
    word_w = max(len(_swarm_v(v)[3]) for _, v, _ in entries)
    rows = []
    for a, v, surface in entries:
        rgb, col, glyph, word = _swarm_v(v)
        g = sig_glyph(a["id"], rgb)
        role = a["role"][:role_w].ljust(role_w)
        verdict = f"{col}{BOLD}{glyph} {word.ljust(word_w)}{X}"
        surf = f" {FAINT}·{X} {DIM}{surface}{X}" if surface else ""
        if v == "deny":  # the screenshot moment — bracket it red so the block reads
            rows.append(f"{RD}▕{X}{g} {DIM}{role}{X} {verdict}{surf}{RD}▏{X}")
        else:
            rows.append(f"{g} {DIM}{role}{X} {verdict}{surf}")
    n = len(agents)
    cap = f"/{mx}" if mx else ""
    header = f"{FAINT}── swarm {n}{cap} active ──{X}"
    return [header] + rows

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
    cols = int(os.environ.get("COLUMNS") or 120)   # CC exports COLUMNS (v2.1.153+); 80 is the ANSI floor, 120 our default
    if cols < 1: cols = 120
    RMARGIN = 6  # right safety gutter: clears Claude Code's scrollbar + edge padding so the verdict never clips off-screen
    # every finalized row is clamped to this width so none can wrap: it matches the
    # width a line()-built row already targets (cols − RMARGIN, ANCHOR included), so
    # the well-formed HUD rows are untouched and only an overflowing wall/swarm/tease/
    # update row (the double-header bleed) is trimmed back inside the terminal.
    MAXW = max(1, cols - RMARGIN)

    # ── eye animation: the watchman's eyes are the signature, so they animate —
    # but NEVER off the verdict (a verdict-colored eye washes into a same-hue body
    # and erases the face; the verdict reads from the right block + bar + bifröst
    # text). And NEVER fully dark: a still can land on ANY frame, so every phase is
    # a LIGHT color and the eyes stay visible in EVERY frame (the eyeless-capture
    # lesson holds). A cheap, deterministic 12-tick cycle (~36s at the 3s refresh)
    # keeps the watchman alive in a screen recording, richer than a lone squint:
    #   • BLINK  — one tick the eyes dim to a near-closed muted slate (still visible)
    #   • LOOK   — a couple of ticks a brighter glint passes across the eyes (a scan)
    #   • GLINT  — the steady bright white watch the rest of the time
    # Scanning verdict overrides with a faster look-pulse so the watchman reads as
    # actively scanning. HMD_NOW overrides the clock for deterministic conformance.
    # (The red deny-flash / pass-sparkle live in hmd-gate-anim.sh, not here.)
    t = int(os.environ.get("HMD_NOW") or time.time())
    GLINT  = (240, 248, 255)   # steady bright white watch-glint (the default eye)
    LOOK   = (255, 255, 255)   # pure-white pulse — a light passing across the eyes
    BLINK  = (120, 128, 145)   # a blink: eyes nearly closed, dimmed but STILL VISIBLE
    SQUINT = (150, 160, 175)   # alert squint — muted white, never dark
    phase = t % 12
    if phase == 0:          eye = BLINK       # ~1 frame in 12: a quick blink
    elif phase in (4, 8):   eye = LOOK        # periodic bright look/scan pulse
    else:                   eye = GLINT       # steady bright watch
    if verdict == "scanning":                 # actively scanning -> faster look-pulse
        eye = LOOK if (t % 2 == 0) else SQUINT

    if "--widget" in sys.argv:
        eyes = {"pass":"^ ^","deny":"O O","scanning":". .","watching":"• •"}[verdict]
        cnt = f" {passed}/{total}" if passed is not None else ""
        _write(f"{CY}▐{X}{vcol}{eyes}{X}{CY}▌{X} {vcol}{vglyph} {vword}{cnt}{X}")
        return

    # presence opt-out (consent surface): when the dev ran `hmd presence off` (repo or global)
    # they are INVISIBLE — no beat is forked (present=False gates it), but the roster still
    # refreshes so they can SEE the team (off = invisible, not blind). The statusline shows a
    # clear off-hint below so the dev is never silently invisible.
    present, files_shown = _presence_state(cwd)

    # keep THIS dev present on teammates' walls AND warm the roster cache in ONE fork: a
    # throttled, detached beat + roster refresh (the roster read alone never announced us).
    # Stat-only throttle gates → ZERO forks when both are throttled. Never blocks the render.
    _spawn_presence(cwd, handle, verdict, present)

    # ── DENSITY SELECTION (spec B §2) ─────────────────────────────────────────
    # The canonical verdict (PASS/DENY/RUNNING/IDLE) drives the compact + minimal
    # blocks. IDLE = solo + no gate verdict (matches the full-HUD idle dedup below).
    dmode = density(cols)
    idle = (verdict == "watching" and passed is None)
    canon = "IDLE" if idle else canon_verdict(verdict)

    # "update available" notice (spec: dev learns of a newer release AMBIENTLY). A
    # pure LOCAL cache read (update_notice makes zero network calls) → '' when the
    # install is current/ahead or the cache is absent/corrupt (silent fail-safe). We
    # width-guard it so a very narrow terminal never wraps the line.
    upd = update_notice()
    if upd and vis(upd) > max(0, cols - RMARGIN):
        upd = ""

    if dmode == "minimal":
        # minimal (<80): the watchman glyph + the verdict word. One cell + one whole
        # word, padded to width — structurally impossible to slice mid-glyph. An
        # available update rides one extra padded row below (added only when present,
        # so a current install renders byte-identically to before).
        vrgb = VERDICT_CANON[canon][0]
        row = f"{sig_glyph(seed, vrgb)} {verdict_word(canon, t)}"
        rows = [row] + ([upd] if upd else [])
        sys.stdout.write(finalize(rows, MAXW) + "\n")
        return

    if dmode == "compact":
        # compact (80–119): sigil S (4 cols × 2 rows) + verdict, then a wall of
        # teammate glyphs (tinted by glyph_color, +k overflow) on the second row.
        # An available update appends one extra row (only when present).
        sigS = _sigil_rows_s(seed, eye)
        ANCH_S = 4 + 2
        head = f"{BOLD}{handle}{X}  {verdict_seg(canon, t)}"
        wall = compact_wall(cwd, seed, verdict, present, cols, ANCH_S)
        r0 = f"{_sig(sigS, 0, CY)}  {head}"
        r1 = f"{_sig(sigS, 1, CY)}  {wall}"
        rows = [r0, r1] + ([f"{'':6}{upd}"] if upd else [])
        sys.stdout.write(finalize(rows, MAXW) + "\n")
        return

    # ── sigil anchor (squint animates; eyes stay visible in every frame) ──
    # Per terminal tier: half-block watchman on unicode=full, a branded ASCII sigil
    # on no-unicode terms (dumb/CI), a blank 8-wide anchor in mono (legacy no-color).
    sig = _sigil_rows(seed, eye)
    SW = 8
    ANCHOR = SW + 2  # sigil(8 cols) + 2-space gutter, prefixed on EVERY row

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

    # 5-hour usage-limit indicator, pinned at the rightmost end of the top row (after
    # the verdict). Absent unless CC's stdin JSON carries rate_limits (Pro/Max, post
    # first API response) → never fabricated. Rides r1, which line() right-pins.
    usage_seg = usage_limit_seg(data, t)
    if usage_seg:
        r1 = f"{r1}  {usage_seg}" if r1 else usage_seg

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
            g = sig_glyph(m.get("name","?"), ergb)
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
        if present:
            you_seg = f"{sig_glyph(seed)} {BOLD}you{X} {DIM}{you_state} {you_word}{X}"  # your watchman closes the wall
        else:
            # OPTED OUT: the dev sees the team but the team can't see them — say so plainly.
            you_seg = f"{sig_glyph(seed)} {BOLD}you{X} {DIM}◦ presence off{X}"

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

    # ── SWARM MODE: >1 agent live → the top two rows (brand + gate) stay, and the
    # bottom rows become the live agent roster (spectacle + per-agent receipt).
    # 1-or-fewer agents → fall through to the unchanged team-wall / solo behavior.
    swarm = swarm_block(cwd)
    if swarm:
        out = []
        # VERTICALLY CENTER the 4-row sigil among the N content rows. A swarm/team-
        # wall layout has N>4 rows, so the perfect 8×8 sigil (8 cols × 4 half-block
        # rows) can't fill them — it sits in the MIDDLE: ⌊(N−4)/2⌋ blank 8-space
        # prefixes above, the sigil's 4 rows contiguous, the rest blank below. Only
        # the vertical POSITION shifts; the sigil is never distorted. N≤4 → off 0 →
        # top-anchored (byte-identical to before). `off` guards negative indices so
        # a blank-above row is a true 8-space prefix, not a wrapped sig[-1].
        N = 2 + len(swarm) + (1 if upd else 0)
        off = (N - 4) // 2 if N > 4 else 0
        def sigc(c):  # sigil prefix for content row c, centered by `off`
            idx = c - off
            return sig[idx] if 0 <= idx < len(sig) else "        "
        out.append(f"{sigc(0)}  " + line(l1, r1))
        out.append(f"{sigc(1)}  " + line(l2, r2))
        for i, seg in enumerate(swarm):
            out.append(f"{sigc(2+i)}  " + seg)
        if upd:
            out.append(f"{sigc(2+len(swarm))}  " + upd)
        sys.stdout.write(finalize(out, MAXW) + "\n")   # single tier downgrade + width invariant + no-wrap clamp
        return

    out = []
    out.append(f"{_sig(sig,0,CY)}  " + line(l1, r1))
    out.append(f"{_sig(sig,1,CY)}  " + line(l2, r2))
    if wall_segs:
        wall = "  ".join(wall_segs)
        out.append(f"{_sig(sig,2,CY)}  " + wall)
        out.append(f"{_sig(sig,3,CY)}  " + upd)   # blank tail row → carries the update notice when one is available
    else:
        # SOLO TEASE: the wall is empty (no roster, no team files). Fill the dead row
        # with a faint invite — sells the team feature, drives the growth loop. Single
        # row, width-safe (<= COLUMNS − sigil anchor − gutter): dropped if it can't fit.
        # When OPTED OUT the invite would be a lie (no one can see the dev) — show the
        # invisible-state hint instead so the dev knows they're off, not just alone.
        if present:
            tease = f"{FAINT}── watch ── invite your team · hmd invite{X}"
        else:
            tease = f"{FAINT}── watch ── presence off · hmd presence on{X}"
        if vis(tease) > max(0, cols - ANCHOR - RMARGIN): tease = ""
        out.append(f"{_sig(sig,2,CY)}  " + tease)
        out.append(f"{_sig(sig,3,CY)}  " + upd)   # blank tail row → carries the update notice when one is available
    sys.stdout.write(finalize(out, MAXW) + "\n")   # single tier downgrade + width invariant + no-wrap clamp

def _sig(rows, i, fallback):
    return rows[i] if i < len(rows) else "        "   # 8-space blank = square sigil width

if __name__ == "__main__":
    main()

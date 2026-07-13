#!/usr/bin/env python3
"""
hmd-statusline.py — Heimdall watchman statusline v1 "Full-bleed Gauge".

The user's OWN hero sigil (hmd_sigil size 'M', the ▄ 8×8 render) anchors the LEFT as a
perfect 8×8 = 4 half-block rows; three content rows lay out to its right, EXACTLY
$COLUMNS visible cells each, and the sigil's 4th row sits beside a BLANK content row so
the full untrimmed sigil shows (a 4-row statusline):

  Row1  ⛭ HEIMDALL │ <user>·<model> │ <repo>:<branch>   ·· team · daemon · rate-limit
  Row2  <full-bleed context gauge, per-cell 48;2 bg ramp, inside labels>
  Row3  <gate cells ✓/◌/✗ · perm-mode>                    ·· busiest subagent (ghost)
  Row4  <blank content — the sigil's bottom row, padded to COLUMNS>

Assembled through the sibling pure modules:
  hmd_gauge   — the Row2 full-bleed gauge (render_gauge)
  hmd_layout  — exact-width row assembly (compose_with_sigil / remaining_width /
                pad_or_truncate / left_right / width_tier)
  hmd_ledger  — the coordination ledger reader (read_status → daemon/gates/verdict/team)

Width tiers (hmd_layout.width_tier):
  full   (>=100): all three rows, all segments.
  mid    (60-99): drop team member names (count only) + the gauge right label.
  narrow (40-59): drop Row1 right rail + all gauge labels (bar-only).
  tiny   (<40):   ONE line — `HMD <pct>% <gates>`.

Reads Claude Code's statusLine JSON on stdin. Null-safe throughout; always exits 0,
NEVER writes stderr. Empty/malformed stdin → the `⛭ HEIMDALL` fallback line, exit 0.

Ships via hooks/statusline.sh → python3 ${CLAUDE_PLUGIN_ROOT}/sentinels/hmd-statusline.py
(refreshInterval:2, wired by bin/heimdall-statusline-register / install.sh).

Modes:
  --widget   emit only the watchman+verdict segment (ccstatusline coexistence)
"""
import sys, os, json, time, re, hashlib, importlib.util, subprocess, shlex, contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
BIN_DIR = os.path.normpath(os.path.join(HERE, "..", "bin"))  # heimdall-identity / heimdall-presence


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# sibling modules — imported by path so this file stays runnable from any cwd.
SIG = _load("hmd_sigil")
TC = _load("hmd_termcaps")
GAUGE = _load("hmd_gauge")        # import hmd_gauge — the Row2 full-bleed gauge
LAYOUT = _load("hmd_layout")      # import hmd_layout — exact-width row assembly
LEDGER = _load("hmd_ledger")      # import hmd_ledger — the ledger reader (read_status)

# ── terminal capability tier ─────────────────────────────────────────────────
# CC's statusLine is non-TTY but truecolor. hmd_termcaps.detect() grades a tier from
# $COLORTERM/$TERM/$TERM_PROGRAM/$TMUX (+ --no-color/--plain + HEIMDALL_STATUSLINE_MODE).
# The line is BUILT in 24-bit truecolor + full unicode; CAPS.emit() downgrades the
# finished bytes in ONE pass at write time (truecolor+full = byte-identical NO-OP).
CAPS = TC.detect(sys.argv)
USE_COLOR = CAPS.use_color()
def _c(s): return s if USE_COLOR else ""
def _write(s):
    # single choke point: every render path emits through the tier downgrade.
    sys.stdout.write(CAPS.emit(s))

# palette (empty in no-color mode → f-strings render as plain text)
CY=_c("\033[38;2;34;211;238m"); GR=_c("\033[38;2;34;197;94m"); RD=_c("\033[38;2;239;68;68m")
AM=_c("\033[38;2;245;158;11m"); DIM=_c("\033[38;2;90;100;114m"); FAINT=_c("\033[38;2;58;65;77m")
TEAL=_c("\033[38;2;45;212;191m")  # brand wordmark teal
BOLD=_c("\033[1m"); X=_c("\033[0m")
SEP=f"{FAINT} │ {X}"
ANSI = re.compile(r"\033\[[0-9;]*m")
def vis(s): return CAPS.width(s)

def sgr(rgb):
    """A 24-bit fg SGR for an arbitrary rgb, gated by USE_COLOR + downgraded by CAPS.emit."""
    return _c("\033[38;2;%d;%d;%dm" % (rgb[0], rgb[1], rgb[2]))

# a branded ASCII sigil for no-unicode terminals (dumb/CI): 8-wide × 3 rows so the
# anchor alignment survives AND the `hmd` wordmark still reads within the 3-row height.
ASCII_SIGIL = [" ______ ", "|o    o|", "|_hmd__|"]

GUTTER = 2   # spaces between the sigil anchor and the content column.

# ── SIGIL CACHE ────────────────────────────────────────────────────────────────
# Precompute the sigil to a cached string per (haid, size, caps[, eye]). A content
# hash of hmd_sigil.py is folded into the key so a code change mints a fresh key.
_SIG_MEMO = {}
def _sigil_cache_dir():
    return os.path.join(os.path.expanduser("~"), ".heimdall", ".sigil-cache")

def _sigil_version():
    """Short CONTENT hash of hmd_sigil.py folded into the cache key (mtime-memoized in a
    .srcver sidecar so a fresh spawn skips re-hashing an unchanged source)."""
    try:
        src = getattr(SIG, "__file__", None) or os.path.join(HERE, "hmd_sigil.py")
        mtime = os.path.getmtime(src)
        vpath = os.path.join(_sigil_cache_dir(), ".srcver")
        cached = None
        with contextlib.suppress(Exception):
            with open(vpath, "r", encoding="utf-8") as f:
                cached_mtime, cached_hash = f.read().split(None, 1)
            if float(cached_mtime) == mtime:
                cached = cached_hash.strip()
        if cached is not None:
            return cached
        with open(src, "rb") as f:
            h = hashlib.sha256(f.read()).hexdigest()[:12]
        with contextlib.suppress(Exception):
            os.makedirs(_sigil_cache_dir(), exist_ok=True)
            with open(vpath, "w", encoding="utf-8") as f:
                f.write("%r %s" % (mtime, h))
        return h
    except Exception:
        return "0"
_SIG_VERSION = _sigil_version()

def cached_sigil(seed, size, caps, eye):
    eyt = tuple(eye or SIG.EYE)
    ekey = "%02x%02x%02x" % (eyt[0], eyt[1], eyt[2])
    ckey = "%s-%s-%s" % (caps.color, caps.unicode, _SIG_VERSION)
    memo_k = (seed, size, ckey, ekey)
    m = _SIG_MEMO.get(memo_k)
    if m is not None: return list(m)
    lines = None
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", seed or "you")[:48]
    path = os.path.join(_sigil_cache_dir(), "%s__%s__%s__%s.sig" % (safe, size, ckey, ekey))
    with contextlib.suppress(Exception):
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().split("\n")
    if lines is None:
        with contextlib.suppress(Exception):
            lines = SIG.sigil_render(seed, size, SIG.tier_caps(), eye_override=eye)
        if lines is not None:
            with contextlib.suppress(Exception):
                os.makedirs(_sigil_cache_dir(), exist_ok=True)
                tmp = path + ".%d.tmp" % os.getpid()
                with open(tmp, "w", encoding="utf-8") as f: f.write("\n".join(lines))
                os.replace(tmp, path)
    if lines is None:
        lines = list(ASCII_SIGIL)
    _SIG_MEMO[memo_k] = list(lines)
    return list(lines)

def _sigil_rows(seed, eye):
    """The left anchor per tier: the 58-hero half-block watchman (size 'M') on
    unicode=full + color; a branded ASCII sigil on no-unicode terms; a blank 8-wide
    anchor in mono. The hero block is a perfect 8×8 = 4 half-block text-rows and is
    returned UNTRIMMED (SIGIL-KEEP: the multi-cell hero block stays the anchor;
    hmd_sigil.py is byte-untouched). The layout emits max(sigil_height, content_height)
    rows, so the full 4-row sigil shows: content rows 1–3 beside sigil rows 1–3, and
    sigil row 4 sits beside a BLANK content row padded to COLUMNS."""
    if CAPS.unicode == TC.ASCII:
        rows = list(ASCII_SIGIL)
    elif CAPS.color == TC.MONO:
        rows = ["        "] * 4
    elif CAPS.unicode == TC.FULL:
        try:
            rows = cached_sigil(seed, "M", CAPS, eye)
        except Exception:
            rows = list(ASCII_SIGIL)
    else:
        rows = list(ASCII_SIGIL)
    return rows

# ── stdin ────────────────────────────────────────────────────────────────────
def read_stdin():
    """Return (data|None). None means empty OR malformed stdin (→ the ⛭ HEIMDALL
    fallback). A valid but empty `{}` returns {} (→ the full null-safe render)."""
    try:
        raw = sys.stdin.read()
    except Exception:
        return None
    if not raw or not raw.strip():
        return None
    try:
        d = json.loads(raw)
    except Exception:
        return None
    return d if isinstance(d, dict) else None

# ── width detection (REUSE: 80-col conservative floor — RJ's ~95-col wrap bug) ──
def _cols_from_tty():
    """Read the REAL width of the CONTROLLING terminal via /dev/tty (CC captures stdout,
    so it is not a tty). tput cols → stty size, in order. None when no tty / both fail."""
    try:
        tty = open("/dev/tty")
    except Exception:
        return None
    try:
        probes = (
            (["tput", "cols"], lambda o: o.strip()),
            (["stty", "size"], lambda o: (o.split()[1] if len(o.split()) >= 2 else "")),
        )
        for cmd, pick in probes:
            try:
                r = subprocess.run(cmd, stdin=tty, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, timeout=0.5)
                c = int(pick(r.stdout.decode("utf-8", "replace")))
                if c > 0:
                    return c
            except Exception:
                continue
    finally:
        with contextlib.suppress(Exception):
            tty.close()
    return None

def resolve_cols():
    """Width WITHOUT over-assuming (never render wider than the real terminal, or an
    over-wide row soft-wraps into a thin duplicate strip). $COLUMNS → /dev/tty → 80."""
    env = os.environ.get("COLUMNS")
    if env is not None:
        with contextlib.suppress(Exception):
            c = int(env.strip())
            if c > 0:
                return c
    c = _cols_from_tty()
    if c and c > 0:
        return c
    return 80   # conservative floor: under-render, never wrap

# ── git branch (cached, NO subprocess) ────────────────────────────────────────
def _git_branch(cwd):
    """The current git branch for `cwd`, read STRAIGHT from `.git/HEAD` — no
    subprocess, no network. Walks up parents until a `.git` (dir OR the worktree
    `gitdir:` file) is found, then parses `ref: refs/heads/<branch>` (a detached HEAD
    → the short sha). Returns None outside any git repo (→ no branch suffix). Total:
    any fault degrades to None, never raises."""
    try:
        d = os.path.abspath(cwd)
    except Exception:
        return None
    for _ in range(64):
        gitpath = os.path.join(d, ".git")
        head = None
        try:
            if os.path.isdir(gitpath):
                head = os.path.join(gitpath, "HEAD")
            elif os.path.isfile(gitpath):
                # a linked worktree: `.git` is a file `gitdir: <path-to-gitdir>`.
                with open(gitpath, "r", encoding="utf-8") as f:
                    line = f.read().strip()
                if line.startswith("gitdir:"):
                    head = os.path.join(line.split(":", 1)[1].strip(), "HEAD")
            if head and os.path.isfile(head):
                with open(head, "r", encoding="utf-8") as f:
                    ref = f.read().strip()
                if ref.startswith("ref: refs/heads/"):
                    return ref[len("ref: refs/heads/"):].strip() or None
                return ref[:7] if ref else None   # detached HEAD → short sha
        except Exception:
            return None
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None

# ── legacy single-verdict state (for --widget + eye animation) ────────────────
def gate_state(cwd):
    p = os.environ.get("HEIMDALL_STATE", os.path.join(cwd, ".heimdall", "statusline.json"))
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {}

VERDICT = {  # verdict -> (eye color rgb, ansi col, glyph, word)
 "pass":     ((34,197,94),  GR, "✓", "GATE"),
 "deny":     ((239,68,68),  RD, "✗", "BIFRÖST CLOSED"),
 "scanning": ((245,158,11), AM, "◦", "scanning"),
 "watching": ((34,211,238), CY, "◦", "watching"),
}

# ── identity (FILE-controlled seed + handle; env fallback) ────────────────────
def identity(cwd, fallback):
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
        seed = handle = None
    resolved = seed or fallback
    return _sigil_override_seed(resolved), (handle or resolved)

def _sigil_override_seed(seed):
    """Honor `hmd sigil set <hero>` (unlocked after >=3 runs); else the seed unchanged."""
    home = os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")
    try:
        with open(os.path.join(home, "sigil-choice")) as f:
            choice = f.read().strip()
    except Exception:
        return seed
    if not choice or choice not in SIG.HERO_SIGILS:
        return seed
    try:
        with open(os.path.join(home, ".run-count")) as f:
            runs = int(f.read().strip() or "0")
    except Exception:
        runs = 0
    return choice if runs >= 3 else seed

# ── presence (opt-out + one coordinated fire-and-forget beat/roster fork) ─────
def _quiet_rm(path):
    with contextlib.suppress(OSError):
        os.remove(path)

def _roster_cache_path(cwd): return os.path.join(cwd, ".heimdall", ".roster-cache.json")
def _beat_stamp_path(cwd): return os.path.join(cwd, ".heimdall", ".beat-stamp")

def _presence_state(cwd):
    present, files_shown = True, True
    gp = os.path.join(os.path.expanduser("~"), ".heimdall", "presence-off")
    with contextlib.suppress(Exception):
        if os.path.exists(gp):
            present = False
    try:
        with open(os.path.join(cwd, ".heimdall", "presence.json")) as f:
            st = json.load(f)
        if isinstance(st, dict):
            if st.get("enabled") is False: present = False
            if st.get("files") is False: files_shown = False
    except Exception:
        files_shown = files_shown   # absent/unreadable → default (present, shown)
    return present, files_shown

def _spawn_presence(cwd, handle, verdict, present=True):
    """ONE coordinated, throttled, fire-and-forget presence fork per render (beat +
    roster refresh ride one child). Stat-only 'is it due?' gates → ZERO forks when
    throttled. Detached, never blocks, never raises."""
    bin_path = os.path.join(BIN_DIR, "heimdall-presence")
    if not os.access(bin_path, os.X_OK): return
    now = time.time()
    cache = _roster_cache_path(cwd); lock = cache + ".lock"; stamp = _beat_stamp_path(cwd)
    try:
        beat_due = not (os.path.exists(stamp) and now - os.path.getmtime(stamp) < 20)
    except Exception:
        beat_due = False
    if not present: beat_due = False
    try:
        fresh  = os.path.exists(cache) and now - os.path.getmtime(cache) < 4
        locked = os.path.exists(lock)  and now - os.path.getmtime(lock)  < 8
        roster_due = (not fresh) and (not locked)
    except Exception:
        roster_due = False
    if not beat_due and not roster_due:
        return
    try:
        os.makedirs(os.path.join(cwd, ".heimdall"), exist_ok=True)
    except Exception:
        return
    pieces = []; env = dict(os.environ)
    if beat_due:
        try:
            open(stamp, "w").close()
        except Exception:
            beat_due = False
    if beat_due:
        pv = {"pass": "pass", "deny": "deny", "scanning": "working",
              "watching": "watching"}.get(verdict, "working")
        env["HMD_HANDLE"] = handle or ""; env["HMD_VERDICT"] = pv
        pieces.append("%s beat >/dev/null 2>&1" % shlex.quote(bin_path))
    if roster_due:
        try:
            open(lock, "w").close()
        except Exception:
            roster_due = False
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
        if roster_due: _quiet_rm(lock)

def roster_presence(cwd):
    """SERVER-synced ONLINE team, served instantly from the short-TTL roster cache."""
    cache = _roster_cache_path(cwd); rows = None
    try:
        with open(cache) as f:
            rows = json.load(f)
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
            "online": True,
        })
    return out

def team_presence(cwd, ttl=30):
    """Prefer the SERVER roster, else local .heimdall/team/*.json heartbeats."""
    roster = roster_presence(cwd)
    if roster: return roster
    d = os.path.join(cwd, ".heimdall", "team"); out = []
    try:
        names = os.listdir(d)
    except Exception:
        return out
    now = time.time()
    for n in names:
        if not n.endswith(".json"): continue
        try:
            with open(os.path.join(d, n)) as f:
                t = json.load(f)
        except Exception:
            continue
        if now - t.get("ts", 0) > ttl: continue
        out.append(t)
    out.sort(key=lambda t: t.get("name", ""))
    return out

# ── live subagent set (agent-pool: the REAL live-agent roster, never fabricated) ─
def _home(): return os.path.expanduser("~")

def _agent_pool_file():
    new = os.path.join(_home(), ".heimdall", "agent-pool.json")
    legacy = os.path.join(_home(), ".superx", "agent-pool.json")
    if not os.path.exists(new) and os.path.exists(legacy): return legacy
    return new

def active_swarm_agents():
    """Live roster from agent-pool: status=='active' agents whose PID is still alive."""
    try:
        with open(_agent_pool_file()) as f:
            pool = json.load(f)
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
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            except Exception:
                pass_alive = True   # PermissionError etc. → the pid is alive
        out.append({"id": aid, "role": (info.get("type") or "agent"),
                    "started_at": info.get("started_at") or ""})
    out.sort(key=lambda a: (a["started_at"], a["id"]))
    return out, mx

# ── Row-1 right-rail segments ─────────────────────────────────────────────────
# the 5-hour usage limit ALWAYS resets within 5 hours; anything larger is a garbage
# resets_at (e.g. a far-future epoch) and its countdown is OMITTED, never printed.
FIVE_HOUR_S = 5 * 3600

def rate_limit_parts(data, now):
    """(pct_seg, reset_seg) for the 5-hour usage limit. Reads
    rate_limits.five_hour.{used_percentage,resets_at} (Pro/Max, present only after the
    first API response). pct_seg is the coloured `𝘅 NN%`; reset_seg is `·<Nh|Nm>`.
    Either is '' when its source is absent/malformed (never a fabricated value).

    RESET SANITY (guards the 2282244h overflow): the countdown is emitted ONLY when
    `0 < (resets_at − now) ≤ 5h`. A resets_at that is absent, ≤ now, or yields > 5h
    (a far-future epoch mis-read as a delta) → reset_seg '' — an implausible hour count
    is never printed."""
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return "", ""
    fh = rl.get("five_hour")
    if not isinstance(fh, dict):
        return "", ""
    up = fh.get("used_percentage")
    if not isinstance(up, (int, float)) or isinstance(up, bool):
        return "", ""
    pct = max(0, min(100, int(round(up))))
    col = RD if pct >= 90 else AM if pct >= 70 else GR
    pct_seg = f"{col}𝘅 {pct}%{X}"
    reset_seg = ""
    ra = fh.get("resets_at")
    if isinstance(ra, (int, float)) and not isinstance(ra, bool) and ra > now:
        rem = int(ra - now)
        if 0 < rem <= FIVE_HOUR_S:   # sane: a 5-hour-limit reset is always ≤ 5h
            cd = f"{rem // 3600}h" if rem >= 3600 else f"{max(1, rem // 60)}m"
            reset_seg = f"{FAINT}·{X}{DIM}{cd}{X}"
    return pct_seg, reset_seg

def rate_limit_seg(data, now):
    """The combined 5-hour indicator `𝘅 NN%·<reset>` (pct + sanitized countdown)."""
    pct_seg, reset_seg = rate_limit_parts(data, now)
    return pct_seg + reset_seg if pct_seg else ""

def seven_day_pct(data):
    """rate_limits.seven_day.used_percentage → float, or None (absent → gauge omits it)."""
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return None
    sd = rl.get("seven_day")
    if not isinstance(sd, dict):
        return None
    v = sd.get("used_percentage")
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return None
    return v

def five_hour_pct(data):
    """rate_limits.five_hour.used_percentage → float, or None (absent → gauge omits the
    `5h <n>%` readout — never a fabricated 0%)."""
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return None
    fh = rl.get("five_hour")
    if not isinstance(fh, dict):
        return None
    v = fh.get("used_percentage")
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return None
    return v

def _team_hue(seed, sigil):
    """A '#rrggbb' recolor hue for a teammate's cluster sigil: the entry's OWN sigil hex
    if it carries a valid one, else the seed's VIVID sigil accent (sigil_accent_color — the
    colour a human names the hero by: batsy→blue, hulk→green), else the deterministic dim
    identity hue. A single-hue S silhouette reads best in the vivid accent, not the dark
    body hue glyph_color returns."""
    if isinstance(sigil, str) and re.match(r"^#[0-9A-Fa-f]{6}$", sigil):
        return sigil
    try:
        r, g, b = SIG.sigil_accent_color(seed)
    except Exception:
        try:
            r, g, b = SIG.glyph_color(seed)
        except Exception:
            r, g, b = (90, 100, 114)
    return "#%02x%02x%02x" % (r, g, b)


# team-cluster geometry: each teammate's S-size sigil is 4 cols × 2 text rows; the name
# below is padded/truncated to the same 4-cell column so tops, bottoms and names stack.
TEAM_CELL_W = 4
TEAM_GAP = 2   # cells between the gauge (Row2) and the team sigil-bottoms rail


def _team_members(cwd, ledger):
    """Up to 3 teammates + a `+N` overflow, from the ledger team[] (status.json mirror)
    else the live roster cache (team_presence). Each member carries its OWN haid so the
    cluster resolves per-teammate. Returns (members[<=3], overflow)."""
    members = list(ledger.get("team") or [])
    overflow = int(ledger.get("team_overflow") or 0)
    if not members:
        tp = team_presence(cwd)
        members = [{"user": m.get("name") or "?", "haid": m.get("haid"),
                    "sigil": "", "state": m.get("verdict") or ""} for m in tp[:3]]
        overflow = max(0, len(tp) - 3)
    return members[:3], overflow


def team_rail(cwd, ledger):
    """The RIGHT-rail team cluster as STACKED S-size sigils (RJ: '2x2 not 4x4' + stacked).
    Each teammate's 4×4px sigil (S = 4 cols × 2 TEXT ROWS) sits with its TOP half on Row1
    and BOTTOM half on Row2 of the right rail, the teammate NAME under it on Row3. Up to 3
    teammates (space-gapped) + a `+N` overflow on Row1; HIDDEN entirely when solo.

    Each sigil is seeded on the teammate's OWN haid (pin/hero_for-aware → THEIR hero) and
    recoloured to their hue (sigil_silhouette single-hue projection — the multi-tone S grid
    reads as mud at 8px, so one flat identity hue). Returns (top, bot, names, rail_w): the
    three right-rail row strings, each LEFT-aligned to the SAME rail_w so the halves stack
    (tops above bottoms) and names sit under each column. Solo → ('', '', '', 0)."""
    members, overflow = _team_members(cwd, ledger)
    if not members:
        return "", "", "", 0
    tops, bots, nams = [], [], []
    for m in members:
        seed = m.get("haid") or m.get("user") or m.get("sigil") or "?"
        hue = _team_hue(seed, m.get("sigil")) if USE_COLOR else None
        try:
            srows = SIG.sigil_silhouette(seed, "S", hue, CAPS)
        except Exception:
            srows = [" " * TEAM_CELL_W, " " * TEAM_CELL_W]
        tops.append(srows[0] if len(srows) > 0 else " " * TEAM_CELL_W)
        bots.append(srows[1] if len(srows) > 1 else " " * TEAM_CELL_W)
        nm = LAYOUT.pad_or_truncate(str(m.get("user") or ""), TEAM_CELL_W)
        nams.append(f"{DIM}{nm}{X}")
    top = " ".join(tops)
    bot = " ".join(bots)
    names = " ".join(nams)
    if overflow > 0:
        top += f" {DIM}+{overflow}{X}"
    rail_w = max(vis(top), vis(bot), vis(names))
    # LEFT-align each rail row within rail_w so the sigil columns stack vertically; the
    # whole rail_w block is then RIGHT-pinned in the content row by left_right().
    top = LAYOUT.pad_or_truncate(top, rail_w)
    bot = LAYOUT.pad_or_truncate(bot, rail_w)
    names = LAYOUT.pad_or_truncate(names, rail_w)
    return top, bot, names, rail_w

def daemon_seg(ledger):
    return f"{GR}◆{X}" if ledger.get("daemon") == "up" else f"{FAINT}◇{X}"

def _parse_semver(v):
    """Parse vX.Y.Z (optional leading v) into a comparable (int,int,int), or None when
    it does NOT cleanly match — a malformed/empty version can never yield a false 'behind'."""
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)$", (v or "").strip())
    return tuple(int(x) for x in m.groups()) if m else None

def update_notice():
    """A compact 'update available' HUD notice, read PURELY from the update-check cache
    bin/heimdall's daily BACKGROUND probe writes — NO network, NO subprocess on the render
    path. Cache: ${HEIMDALL_HOME:-~/.heimdall}/update-check.json {checked_epoch,installed,
    latest}. Returns the notice iff installed is STRICTLY older than latest; else '' (silent
    on a current/ahead install, a missing/corrupt/unparseable cache, or ANY fault)."""
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




# ── Row-3 segments ─────────────────────────────────────────────────────────────
_GATE_GLYPH = {"pass": ("✓", GR), "running": ("◌", AM), "deny": ("✗", RD)}

def gate_cells(gates, colored=True):
    """Gate verdict cells (✓ pass / ◌ running / ✗ deny) `·`-joined. Empty → the neutral
    offline marker. `colored=False` yields plain glyphs (tiny-tier single line)."""
    if not gates:
        return f"{DIM}◌ offline{X}" if colored else "offline"
    out = []
    for g in gates:
        glyph, col = _GATE_GLYPH.get(g.get("state"), ("◌", DIM))
        out.append(f"{col}{glyph}{X}" if colored else glyph)
    return (f"{FAINT}·{X}".join(out) if colored else "·".join(out))

def perm_mode(data):
    """The permission-mode indicator. CC does NOT pass permission mode on statusLine
    stdin today (descoped) — probe the stdin fields, then a bounded transcript tail,
    then OMIT (never fabricated). Returns '' when no signal exists."""
    for k in ("permission_mode", "permissionMode", "permission"):
        v = data.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    tp = data.get("transcript_path") or data.get("transcriptPath")
    if isinstance(tp, str) and tp:
        try:
            with open(tp, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 4096))
                tail = f.read().decode("utf-8", "replace")
            m = re.findall(r'"permission[_A-Za-z]*"\s*:\s*"([A-Za-z]+)"', tail)
            if m:
                return m[-1]
        except Exception:
            return ""
    return ""

def subagent_ghost(agents):
    """A faint right-rail ghost naming the busiest live subagent (the most recently
    started) + the active count. '' when no subagent is live."""
    if not agents:
        return ""
    busiest = agents[-1]
    role = str(busiest.get("role") or "agent")[:16]
    n = len(agents)
    plural = "s" if n != 1 else ""
    return f"{FAINT}⋯ {n} agent{plural} · {role}{X}"

# ── the render ──────────────────────────────────────────────────────────────
def _eye(verdict, t):
    """The watchman's eye color for THIS tick — always a LIGHT color (never dark), a
    12-tick blink/look/glint cycle; scanning pulses faster. Deterministic on HMD_NOW."""
    GLINT = (240, 248, 255); LOOK = (255, 255, 255)
    BLINK = (120, 128, 145); SQUINT = (150, 160, 175)
    phase = t % 12
    if phase == 0:          eye = BLINK
    elif phase in (4, 8):   eye = LOOK
    else:                   eye = GLINT
    if verdict == "scanning":
        eye = LOOK if (t % 2 == 0) else SQUINT
    return eye

def _fallback(cols):
    _write(LAYOUT.pad_or_truncate(f"{TEAL}{BOLD}⛭ HEIMDALL{X}", cols) + "\n")

def main():
    data = read_stdin()
    cols = resolve_cols()
    if data is None:
        _fallback(cols)
        return

    ws = data.get("workspace") or {}
    cwd = ws.get("current_dir") or data.get("cwd") or os.getcwd()
    model = (data.get("model") or {}).get("display_name") or "Claude"
    cw = data.get("context_window") or {}
    up = cw.get("used_percentage")
    pct = 0.0 if not isinstance(up, (int, float)) or isinstance(up, bool) else float(up)
    session_id = data.get("session_id") or ""

    # repo:branch — CC's statusLine stdin rarely carries a branch, so fall back to the
    # cached .git/HEAD read (no subprocess) so Row1 shows `heimdall:main`, not bare
    # `heimdall`. repo absent → the current_dir basename with NO branch/:worktree join
    # (dir-basename no-branch outside git).
    repo_obj = ws.get("repo") or {}
    repo_name = repo_obj.get("name")
    branch = ws.get("git_worktree") or repo_obj.get("branch")
    if repo_name:
        if not branch:
            branch = _git_branch(cwd)
        repo_str = str(repo_name) + (":" + str(branch) if branch else "")
    else:
        repo_str = os.path.basename(str(cwd).rstrip("/")) or str(cwd)

    fallback = os.environ.get("HMD_HAID") or os.environ.get("USER") or "you"
    seed, handle = identity(cwd, fallback)

    # legacy verdict for the eye + --widget only.
    st = gate_state(cwd)
    verdict = st.get("verdict", "watching")
    if verdict not in VERDICT: verdict = "watching"
    passed, total = st.get("passed"), st.get("total")

    t = int(os.environ.get("HMD_NOW") or time.time())
    eye = _eye(verdict, t)

    if "--widget" in sys.argv:
        eye_rgb, vcol, vglyph, vword = VERDICT[verdict]
        eyes = {"pass":"^ ^","deny":"O O","scanning":". .","watching":"• •"}[verdict]
        cnt = f" {passed}/{total}" if passed is not None else ""
        _write(f"{CY}▐{X}{vcol}{eyes}{X}{CY}▌{X} {vcol}{vglyph} {vword}{cnt}{X}")
        return

    # keep THIS dev present on teammates' walls + warm the roster cache in ONE fork.
    present, _files_shown = _presence_state(cwd)
    _spawn_presence(cwd, handle, verdict, present)

    # point the ledger's LEGACY fallback at THIS project's statusline.json (the stdin
    # cwd, not the process cwd) so Row3 reflects the real gate verdict — matching the
    # old gate_state(cwd) lookup. An explicit HEIMDALL_STATE (tests) always wins.
    os.environ.setdefault("HEIMDALL_STATE", os.path.join(cwd, ".heimdall", "statusline.json"))
    ledger = LEDGER.read_status(session_id)
    gates = ledger.get("gates") or []
    tier = LAYOUT.width_tier(cols)

    # ── tiny (<40): ONE line — `HMD <pct>% <gates>` ──
    if tier == "tiny":
        line = "HMD %d%% %s" % (int(round(pct)), gate_cells(gates, colored=False))
        _write(LAYOUT.pad_or_truncate(line, cols) + "\n")
        return

    # ── the 4-row layout, laid out to the RIGHT of the hero sigil anchor ──
    sigrows = _sigil_rows(seed, eye)                      # 8-wide × 4 rows
    gw = LAYOUT.remaining_width(sigrows, cols, GUTTER)    # gauge / content span

    # the TEAM CLUSTER owns the right rail across rows 1–3: each teammate's S-size sigil
    # TOP on Row1, BOTTOM on Row2, and the NAME on Row3 (RJ: '2x2 not 4x4' + stacked).
    # Shown at full/mid; dropped at narrow (the right rail collapses like the old rail).
    if tier in ("full", "mid"):
        t_top, t_bot, t_names, rail_w = team_rail(cwd, ledger)
    else:
        t_top, t_bot, t_names, rail_w = "", "", "", 0
    team_gap = TEAM_GAP if rail_w > 0 else 0
    gauge_span = max(0, gw - rail_w - team_gap)   # the gauge yields room to the team rail

    # Row1 — identity (left) + teammate sigil-TOPS (right rail).
    left1 = f"{TEAL}{BOLD}⛭ HEIMDALL{X}{SEP}{DIM}{handle}·{model}{X}{SEP}{AM}{repo_str}{X}"
    if tier == "narrow":
        row1 = LAYOUT.pad_or_truncate(left1, gw)          # drop the right rail
    else:
        row1 = LAYOUT.left_right(left1, t_top, gw)

    # the fill ramp is tinted from the user's OWN sigil VIVID accent (sigil_accent_color:
    # batsy→blue, hulk→green, spiderman→red — NOT the dark body hue glyph_color returns);
    # the gold/red danger tint stays hue-independent and tip-only. base_hue None →
    # the default blue ramp.
    try:
        sig_hue = SIG.sigil_accent_color(seed)
    except Exception:
        sig_hue = None

    # Row2 — the context gauge over `gauge_span`, with the teammate sigil-BOTTOMS on the
    # right rail (the gauge is full-bleed of the span it is left when the team rail is
    # present; solo → full remaining width, byte-identical to the pre-team layout).
    tin = cw.get("total_input_tokens")
    if tier == "full":
        gauge = GAUGE.render_gauge(gauge_span, pct, tin, five_hour_pct(data), seven_day_pct(data),
                                   (data.get("cost") or {}).get("total_cost_usd"),
                                   (data.get("cost") or {}).get("total_duration_ms"), CAPS,
                                   ctx_pct=pct, base_hue=sig_hue)
    elif tier == "mid":     # drop the gauge RIGHT label (nulled → render_gauge omits it)
        gauge = GAUGE.render_gauge(gauge_span, pct, tin, None, None, None, None, CAPS, base_hue=sig_hue)
    else:                   # narrow → bar-only
        gauge = GAUGE.render_gauge(gauge_span, pct, None, None, None, None, None, CAPS, base_hue=sig_hue)
    row2 = LAYOUT.left_right(gauge, t_bot, gw) if rail_w > 0 else gauge

    # Row3 — gate verdict + daemon (left) / teammate NAMES (right rail).
    left3 = gate_cells(gates, colored=True)
    if tier != "narrow":
        left3 += f"{SEP}{daemon_seg(ledger)}"
        pm = perm_mode(data)
        if pm:
            left3 += f"{SEP}{DIM}{pm}{X}"
    if tier == "narrow":
        row3 = LAYOUT.pad_or_truncate(left3, gw)
    else:
        row3 = LAYOUT.left_right(left3, t_names, gw)

    # Row4 — (metrics land here in the next step) blank content beside the sigil's 4th row.
    row4 = ""

    lines = LAYOUT.compose_with_sigil(sigrows, [row1, row2, row3, row4], cols, GUTTER)
    _write("\n".join(lines) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # the statusline must NEVER error, NEVER write stderr: any fault → the branded
        # floor, exit 0. (Bare width probe so even resolve_cols faults degrade cleanly.)
        try:
            _fallback(resolve_cols())
        except Exception:
            with contextlib.suppress(Exception):
                sys.stdout.write("⛭ HEIMDALL\n")
        sys.exit(0)

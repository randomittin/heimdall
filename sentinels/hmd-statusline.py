#!/usr/bin/env python3
"""
hmd-statusline.py — Heimdall watchman statusline v2 "Composite Final".

The user's OWN hero sigil (hmd_sigil size 'M', the ▄ 8×8 render) anchors the LEFT as a
perfect 8×8 = 4 half-block rows (8c sigil + 1c gap = 9c fixed left). The 4 content rows
lay out to its right, EXACTLY $COLUMNS visible cells each. The TEAM zone is reserved
FIRST from the right edge (Spec v2 §2 — the anti-truncation order swap); the rows zone
(identity / gauge / gates / micro-gauges) takes the leftover, with the gauge the only
flexible element (24–40c). A 4-row statusline:

  Row1  ⛭ HEIMDALL │ rj · Opus 4.8 │ heimdall:branch +2 ~1   ◦ watching │ [team eye-strips]
  Row2  [ context gauge: CTX <pct>% · ↓<tok> on the fill, $<cost> on the track end ]  [team eye-strips]
  Row3  ✓ secrets 0 · ✓ tests 41/41 · ✓ designmatch .91                              [team names]
  Row4  5h ▓▓▓░░ 28% ·3h │ 7d ▓▓▓▓░ 41%                                              [team states]

Assembled through the sibling pure modules:
  hmd_gauge   — the Row2 context gauge (render_gauge) + Row4 micro-gauges (render_micro_gauge)
  hmd_layout  — exact-width row assembly + team-first zone allocation (team_zone_alloc /
                compose_with_sigil / pad_or_truncate / left_right / width_tier)
  hmd_sigil   — the main 8×8 hero sigil + the teammate eye_strip (eyes-visible crop)
  hmd_ledger  — the coordination ledger reader (read_status → daemon/gates/verdict/team)

No bypass/permission-mode segment (CC prints its own banner) and no box/hairline chrome
(Spec v2 §1). Width tiers (hmd_layout.width_tier):
  full   (>=100): 3 team members, 40c gauge, gate details, 12c micro-bars.
  mid    (60-99): 2 team members + `+N` (states drop), 32c gauge, gate details drop, 8c micro.
  narrow (40-59): team → inline `● ● ●` dots on the Row1 rail; gauge bar-only; micro → text.
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
TEAL=_c("\033[38;2;45;212;191m")  # brand wordmark teal (legacy --widget)
# Spec v2 §2 palette
BLUE=_c("\033[38;2;66;100;255m")    # #4264FF — the ⛭ HEIMDALL wordmark
INK=_c("\033[38;2;236;239;242m")    # #ECEFF2 — repo name ink
BRANCHC=_c("\033[38;2;92;99;109m")  # #5C636D — the branch suffix (faint)
MINT=_c("\033[38;2;61;214;163m")    # #3DD6A3 — +staged git count
GOLDC=_c("\033[38;2;255;203;87m")   # #FFCB57 — ~modified git count
GHOST=_c("\033[38;2;58;63;73m")     # #3A3F49 — the │ separator
BOLD=_c("\033[1m"); X=_c("\033[0m")
SEP=f"{GHOST} │ {X}"
ANSI = re.compile(r"\033\[[0-9;]*m")
def vis(s): return CAPS.width(s)

def sgr(rgb):
    """A 24-bit fg SGR for an arbitrary rgb, gated by USE_COLOR + downgraded by CAPS.emit."""
    return _c("\033[38;2;%d;%d;%dm" % (rgb[0], rgb[1], rgb[2]))

# a branded ASCII sigil for no-unicode terminals (dumb/CI): 8-wide × 3 rows so the
# anchor alignment survives AND the `hmd` wordmark still reads within the 3-row height.
ASCII_SIGIL = [" ______ ", "|o    o|", "|_hmd__|"]

GUTTER = 1   # Spec v2 §2: sigil zone = 8c sigil + 1c gap = 9c fixed left.

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
    """Read the REAL width of the CONTROLLING terminal via /dev/tty. This is the FALLBACK
    ONLY — it runs when $COLUMNS is absent/invalid (resolve_cols probes COLUMNS first).

    Under Claude Code's statusLine the script's stdout is CAPTURED (a pipe, not a tty) and
    there is typically NO controlling terminal, so /dev/tty cannot be opened and this returns
    None → resolve_cols then honours $COLUMNS (which CC sets) or the conservative floor. It is
    the PLAIN-TERMINAL path (dev runs the script by hand with COLUMNS unset) where this probe
    resolves the true width. tput cols → stty size, in order. None when no tty / both fail."""
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

# CC's statusLine region is NARROWER than $COLUMNS by this many cells (see resolve_cols).
# MEASURED against the real `claude` binary (v2.1.211), not inferred: a probe statusLine
# emitted a ruler of EXACTLY $COLUMNS cells inside pseudo-terminals of known width, and we
# read back how many cells CC actually painted —
#     pty/$COLUMNS:  80 → 76   95 → 91   120 → 116   160 → 156     (reserve == 4, CONSTANT)
# Override via $HMD_STATUSLINE_RESERVE (CC's spacing is undocumented and may change between
# CC versions; 0 disables the reserve and restores exact-$COLUMNS rows).
CC_REGION_RESERVE = 4


def _region_reserve():
    """Cells to hold back from $COLUMNS for CC's statusLine spacing. $HMD_STATUSLINE_RESERVE
    overrides the measured default; a negative/garbage value degrades to the default."""
    env = os.environ.get("HMD_STATUSLINE_RESERVE")
    if env is not None:
        with contextlib.suppress(Exception):
            r = int(env.strip())
            if r >= 0:
                return r
    return CC_REGION_RESERVE


def resolve_cols():
    """The width the whole layout is clamped to. Resolution order is LOAD-BEARING:

        1. $COLUMNS - CC_REGION_RESERVE  (CC's statusLine contract, v2.1.153+ — ALWAYS FIRST)
        2. /dev/tty                      (plain-terminal fallback when COLUMNS is unset)
        3. 80                            (conservative floor — under-render, never wrap)

    WHY $COLUMNS MUST WIN (the RJ live-statusline bug): Claude Code runs this script for its
    statusLine with $COLUMNS set, but it CAPTURES stdout (a pipe) and gives the process no
    controlling terminal — so a /dev/tty width probe there FAILS, or (worse) resolves the FULL
    outer terminal. Honouring $COLUMNS FIRST is correct; the tty probe is reached ONLY when
    COLUMNS is genuinely absent (a plain terminal).

    WHY $COLUMNS IS NOT THE USABLE WIDTH (the RIGHT-EDGE truncation, RJ again). $COLUMNS is the
    FULL TERMINAL width — NOT the width of the statusLine region CC paints into. CC reserves a
    constant 4 cells of built-in spacing and HARD-CLIPS the right edge of anything wider (see
    CC_REGION_RESERVE for the measurement). Resolving to $COLUMNS EXACTLY and then hard-clamping
    every row to it (the previous behaviour) made every row EXACTLY 4 cells too wide, so CC ate
    4 cells off the right of EVERY row — the truncation the clamp was meant to prevent. The
    renderer must therefore target $COLUMNS - reserve, which is CC's real region.
    (CC tells the SUBAGENT statusline its usable width directly, via the stdin `columns` field;
    the main statusLine gets no such field, so the reserve must be applied here.)

    Combined with the per-row hard clamp in main() (every emitted row is forced to EXACTLY the
    returned width), nothing the SUT emits can ever exceed CC's statusLine region."""
    env = os.environ.get("COLUMNS")
    if env is not None:
        with contextlib.suppress(Exception):
            c = int(env.strip())
            if c > 0:
                # $COLUMNS wins — the tty probe below is NOT consulted. Hold back CC's
                # region spacing; floor at 1 so a pathologically narrow COLUMNS stays sane.
                return max(1, c - _region_reserve())
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
# Resolving identity forks the canonical `heimdall-identity` bin (bash + jq, ~tens of
# ms) — and profiling the render shows this fork is the DOMINANT per-render cost (the
# sigil renders are already sub-millisecond + disk-cached). But identity is SESSION-
# STABLE (the seed/handle do not change while a session runs), so the resolved
# (seed, handle) is served through a per-session 5s cache (mirroring hmd_ledger's
# read_status TTL): the fork happens at most ONCE per 5s and a WARM refresh does ZERO
# subprocess forks for identity. The cache stores the FINAL resolved pair, so the render
# is byte-identical to the uncached fork — the cache only elides the re-resolution.
IDENTITY_TTL = 5.0   # seconds — session-stable; mirror hmd_ledger.CACHE_TTL

def _identity_cache_path(session_id):
    """`<tmp>/hmd-statusline-identity-<slug>` — session-keyed (never pid-keyed), the same
    HMD_STATUSLINE_TMP dir + slugging convention the ledger cache uses."""
    slug = re.sub(r"[^A-Za-z0-9._-]", "-", str(session_id or "").strip()) or "default"
    tmp = os.environ.get("HMD_STATUSLINE_TMP") or "/tmp"
    return os.path.join(tmp, "hmd-statusline-identity-" + slug)

def _identity_cache_read(session_id):
    """The cached (seed, handle) tuple, plus whether it is still FRESH (< IDENTITY_TTL old):
    returns (value_or_None, is_fresh). A FRESH value serves the WARM no-fork render (a hit
    proves NO heimdall-identity fork happened this tick). A STALE value is kept as the
    last-known-good identity, reused when a re-fork FAILS — so a transient fork
    timeout/error never regresses the MAIN sigil to the $USER fallback (the batsy-pin miss
    that rendered the `rj`→dog animal). Never raises."""
    p = _identity_cache_path(session_id)
    try:
        fresh = (time.time() - os.path.getmtime(p)) <= IDENTITY_TTL
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        if isinstance(d, dict) and isinstance(d.get("seed"), str) and isinstance(d.get("handle"), str):
            return (d["seed"], d["handle"]), fresh
    except Exception:
        return None, False
    return None, False

def _identity_cache_put(session_id, seed, handle):
    """Atomically persist the resolved (seed, handle) for the session (tmp + os.replace).
    Best-effort: a write failure just means the next render re-resolves. Never raises."""
    p = _identity_cache_path(session_id)
    tmp = p + ".%d.tmp" % os.getpid()
    try:
        os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"seed": seed, "handle": handle}, f)
        os.replace(tmp, p)
    except Exception:
        with contextlib.suppress(Exception):
            os.remove(tmp)

def identity(cwd, fallback, session_id=""):
    """The resolved (sigil seed, display handle), served through the per-session 5s cache
    so a WARM refresh never forks heimdall-identity. On a FRESH hit the cached pair is
    returned with NO fork. On a MISS (cold or >TTL) the canonical bin is forked ONCE
    (bash+jq); a GENUINE resolution is applied through the sigil override, cached, and
    returned (byte-identical to the uncached path).

    A fork that TIMES OUT / errors / returns empty must NEVER poison the cache with the
    $USER fallback: that bare handle is not a real HAID, so it MISSES the batsy
    CUSTOM_SIGILS pin and the MAIN sigil regresses to the `rj`→dog TEAL animal — and the
    5s cache would then FREEZE that wrong seed, flipping the sigil for a full 5s while the
    team-self sigil (which reads the real HAID from the ledger) stays batsy. So a failed
    re-fork instead REUSES the last-known-good identity (the stale cache entry, any age),
    keeping the MAIN sigil the SAME pinned hero the team renders. Only a cold session that
    has NEVER resolved falls back to $USER — and that is left UNCACHED so the next
    (recovered) fork wins immediately (self-heals, no 5s freeze)."""
    cached, fresh = _identity_cache_read(session_id)
    if cached is not None and fresh:
        return cached
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
    if seed:
        out = (_sigil_override_seed(seed), (handle or seed))
        _identity_cache_put(session_id, out[0], out[1])
        return out
    if cached is not None:
        return cached   # fork failed → reuse last-known-good (== team-self), never $USER
    return _sigil_override_seed(fallback), fallback   # cold + broken fork → transient, UNCACHED

def _sigil_override_seed(seed):
    """Honor `hmd sigil set <hero>` (unlocked after >=5 runs — matches the heimdall-sigil CLI
    threshold); else the seed unchanged."""
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
    return choice if runs >= 5 else seed

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
            # the teammate's OWN git branch (repo-relative), recorded at beat time. Absent on
            # older roster records → "" (the render then shows no branch line, back-compat).
            "branch": r.get("branch") or "",
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

# ── the parallel-agent SWARM block: spectacle + per-agent receipt ──────────────
# Roster   = active_swarm_agents() (bin/agent-pool, live PID only — never a ghost).
# Surface  = the claim ledger (.planning/ledger/claims/*.json — an agent's current
#            claimed file) with bin/shared-memory (ns swarm-file) as fallback.
# Verdict  = bin/shared-memory (ns swarm-gate) — each agent's live gate verdict —
#            falling back to "working" for a live-but-unreported agent.
# All reads are plain file / SQLite reads (no subprocess, no network) so the render
# stays a few milliseconds. >1 live agent → the block; 1-or-fewer → None (HUD
# byte-for-byte unchanged). Restored after the v2 composite rewrite dropped it.
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
    try:
        names = os.listdir(d)
    except Exception:
        return out
    now = time.time()
    for n in names:
        if not n.endswith(".json"): continue
        try:
            with open(os.path.join(d, n)) as f: c = json.load(f)
        except Exception:
            continue
        if not isinstance(c, dict): continue
        hb = c.get("heartbeat") or c.get("claimed_at")
        ttl = c.get("ttl_minutes") or 90
        e = _iso_epoch(hb) if hb else None
        if e and now > e + ttl * 60: continue          # expired → not active
        surfs = [s for s in (c.get("claimed_surfaces") or []) if isinstance(s, str)]
        rec = {"task": c.get("task_ref") or "", "surface": surfs[0] if surfs else ""}
        haid = c.get("haid") or ""
        if haid:
            out[haid] = rec
            out[_slug(haid)] = rec
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

def _swarm_glyph(seed, rgb=None):
    """One identity cell — the watchman ◉ from hmd_sigil, verdict-tinted. In
    no-color mode SIG.glyph would still emit ANSI, so return a bare ◉ instead."""
    if not USE_COLOR: return "◉"
    try: return SIG.glyph(seed, eye_override=rgb)
    except Exception: return f"{DIM}◉{X}"

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
        g = _swarm_glyph(a["id"], rgb)
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

# ── Row-1 right-rail segments ─────────────────────────────────────────────────
# the 5-hour usage limit ALWAYS resets within 5 hours; anything larger is a garbage
# resets_at (e.g. a far-future epoch) and its countdown is OMITTED, never printed.
FIVE_HOUR_S = 5 * 3600

def reset_countdown(data, now):
    """The BARE sanitized 5-hour reset countdown — 'Nh' (>=1h) or 'Nm' (<1h) — from
    rate_limits.five_hour.resets_at, or '' when absent/insane. SANITY (guards the
    2282244h far-future overflow): emitted ONLY when `0 < (resets_at − now) ≤ 5h`; a
    resets_at that is absent, ≤ now, or yields > 5h → '' (an implausible hour count is
    never printed). Single source of the reset math for both the Row4 readout and the
    legacy rate_limit_parts segment."""
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return ""
    fh = rl.get("five_hour")
    if not isinstance(fh, dict):
        return ""
    ra = fh.get("resets_at")
    if isinstance(ra, (int, float)) and not isinstance(ra, bool) and ra > now:
        rem = int(ra - now)
        if 0 < rem <= FIVE_HOUR_S:   # sane: a 5-hour-limit reset is always ≤ 5h
            return f"{rem // 3600}h" if rem >= 3600 else f"{max(1, rem // 60)}m"
    return ""

def rate_limit_parts(data, now):
    """(pct_seg, reset_seg) for the 5-hour usage limit. Reads
    rate_limits.five_hour.{used_percentage,resets_at} (Pro/Max, present only after the
    first API response). pct_seg is the coloured `5h NN%`; reset_seg is `·<Nh|Nm>`.
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
    # plain ASCII `5h` label (NOT an astral math glyph) so vis_width == the terminal's
    # rendered width on every font/terminal — the right rail can never be mis-budgeted
    # past COLUMNS by an astral-glyph width disagreement.
    pct_seg = f"{col}5h {pct}%{X}"
    cd = reset_countdown(data, now)
    reset_seg = f"{FAINT}·{X}{DIM}{cd}{X}" if cd else ""
    return pct_seg, reset_seg

def rate_limit_seg(data, now):
    """The combined 5-hour indicator `5h NN%·<reset>` (pct + sanitized countdown)."""
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


# team-sigil-rail geometry (Row1 top-row + Row2 bottom-row + Row3 names): each teammate is
# the TOP HALF of their OWN 8×8 hero (8 cols × 2 `▄` text-rows) in NATURAL colors — the top
# text-row rides Row1, the bottom text-row rides Row2 (stacked = the recognizable top of the
# face: ears/brow/eyes), and the NAME sits under it on Row3. A 1-cell gap separates adjacent
# teammates; a `+N` overflow tag rides the tail. The rail drops WHOLE teammates (→ +N) before
# it would overflow — never a sliced mark. HIDDEN entirely when solo.
TEAM_SIG_W = 8         # a hero top-half is 8 cells wide (the full 8×8 render width)
TEAM_SIG_GAP = 1       # one blank cell between adjacent teammate sigils
TEAM_ROW2_GAP = 2      # blank cells between the Row2 gauge and the reserved sigil zone
GAUGE_MIN_W = 24       # the Row2 gauge keeps at least this many cells when a team zone is set
TEAM_COL_GAP = 4       # 2nd-column gutter: blank cells between the content column and the team
                       # column. The team is packed LEFT (hugs the content) — NOT flush to the
                       # right edge — so a wide terminal never rides the team past CC's narrower
                       # live statusLine region (RJ's right-side truncation). See main().


def _team_members(cwd, ledger):
    """Up to 3 teammates + a `+N` overflow, from the ledger team[] (status.json mirror)
    else the live roster cache (team_presence). Each member carries its OWN haid so the
    cluster resolves per-teammate. Returns (members[<=3], overflow)."""
    members = list(ledger.get("team") or [])
    overflow = int(ledger.get("team_overflow") or 0)
    if not members:
        tp = team_presence(cwd)
        members = [{"user": m.get("name") or "?", "haid": m.get("haid"),
                    "sigil": "", "branch": m.get("branch") or "",
                    "state": m.get("verdict") or ""} for m in tp[:3]]
        overflow = max(0, len(tp) - 3)
    return members[:3], overflow


# ── Spec v2 §6 team zone — 4 rows on the RIGHT, reserved FIRST (team_zone_alloc) ──
# Each teammate is a 15-cell column: the 8-cell EYE-STRIP (eye_strip — the eye band of
# their OWN hero, eyes visible, natural palette) rides the RIGHT 8 cells of the column
# on rows 1–2; the NAME (hero hue) rides row 3 and the STATE rides row 4, both under the
# strip. Adjacent columns are separated by a 2-cell gap; a `+N` overflow tag rides row 3.
# The strip on the RIGHT of each column guarantees the row-1/2 tail is a sigil (never
# truncated text) — Spec v2 §8 falsifier R-A.
TEAM_STATE = {  # ledger state → (glyph, word, color) for the Row4 state segment
    "deny":    ("✗", "deny", RD),   # a gate-deny — the screenshot signal, reds the name
    "pass":    ("◉", "rev",  GR),   # passing / at review
    "running": ("⚡", "wrk",  AM),   # actively working
}


def _team_state_seg(m, now):
    """Row4 per-member state (Spec v2 §6): `◉ rev` mint / `⚡ wrk` gold / `✗ deny` red, or
    `○ <N>m` faint (last-seen minutes) for an idle/unknown state."""
    g = TEAM_STATE.get(m.get("state") or "")
    if g:
        glyph, word, col = g
        return f"{col}{glyph} {word}{X}"
    ts = m.get("ts")
    if isinstance(ts, (int, float)) and not isinstance(ts, bool):
        mins = max(0, int((now - ts) // 60))
        return f"{FAINT}○ {mins}m{X}"
    return f"{FAINT}○{X}"


def _team_branch_seg(branch):
    """Row4 BRANCH indicator (RJ: every same-repo teammate surfaces their branch): `⎇<branch>`
    in the faint branch hue, shown UNDER the teammate's name for ANY teammate with a recorded
    branch — whether or not it matches yours — so who's on which branch of the SAME repo reads
    at a glance. Terse (no space after the glyph) to keep the most branch chars in the 8-cell
    strip; the caller pad_or_truncate()s it to the strip width (a long branch clips with `…`)."""
    b = str(branch or "").strip()
    return f"{BRANCHC}⎇{b}{X}"


def team_columns(members, team_w, overflow, now, states=True, self_branch=""):
    """Render `members` into the four team-zone row strings — each EXACTLY `team_w` visible
    cells. Rows 1–2: the 8-cell eye_strip (natural palette, eyes visible) riding the RIGHT
    of each 15c column. Row 3: the NAME (hero hue, ≤ strip width) under the strip, plus a
    trailing `+N` overflow tag. Row 4: the teammate's BRANCH (`⎇<branch>`) whenever they have
    a recorded branch — EVERY same-repo teammate surfaces their branch on the line UNDER their
    name, not only cross-branch ones; a teammate with no branch falls back to the state segment
    (blank when `states` is False — the mid tier). Members are joined by a 2-cell gap. Returns
    (r1, r2, r3, r4). `self_branch` is retained for callers but no longer gates the branch line."""
    lp = " " * (LAYOUT.TEAM_MEMBER_W - LAYOUT.TEAM_STRIP_W)   # 7c left pad → strip on the right 8c
    gap = " " * LAYOUT.TEAM_MEMBER_GAP
    tops = []; bots = []; names = []; sts = []
    for i, m in enumerate(members):
        seed = m.get("haid") or m.get("user") or m.get("sigil") or "?"
        try:
            strip2 = SIG.eye_strip(seed, CAPS)               # 2 text-rows × 8 cells, eyes visible
            if len(strip2) < 2:
                raise ValueError
        except Exception:
            blank = " " * LAYOUT.TEAM_STRIP_W
            strip2 = [blank, blank]
        g = gap if i else ""
        tops.append(g + lp + strip2[0])
        bots.append(g + lp + strip2[1])
        hue = _team_hue(seed, m.get("sigil")) if USE_COLOR else None
        ncol = sgr(SIG._hex_rgb(hue)) if hue else DIM
        nm = LAYOUT.pad_or_truncate(str(m.get("user") or ""), LAYOUT.TEAM_STRIP_W)
        names.append(g + lp + f"{ncol}{nm}{X}")
        # Row4: EVERY same-repo teammate with a recorded branch shows it UNDER their name
        # (the branch line) — matching OR differing from self_branch; a teammate with no
        # branch falls back to the state segment. The branch line rides even in the mid tier
        # (states=False) since it is NEW data absent from prior renders.
        mb = str(m.get("branch") or "").strip()
        if mb:
            r4seg = _team_branch_seg(mb)
        elif states:
            r4seg = _team_state_seg(m, now)
        else:
            r4seg = None
        if r4seg is not None:
            sts.append(g + lp + LAYOUT.pad_or_truncate(r4seg, LAYOUT.TEAM_STRIP_W))
        else:
            sts.append(g + " " * (len(lp) + LAYOUT.TEAM_STRIP_W))
    tag_seg = f"{DIM} +%d{X}" % overflow if overflow > 0 else ""
    r1 = LAYOUT.pad_or_truncate("".join(tops), team_w)         # tag slot stays blank on the sigil rows
    r2 = LAYOUT.pad_or_truncate("".join(bots), team_w)
    r3 = LAYOUT.pad_or_truncate("".join(names) + tag_seg, team_w)
    r4 = LAYOUT.pad_or_truncate("".join(sts), team_w)
    return r1, r2, r3, r4


def team_dots(members):
    """Narrow-tier inline team indicator (Spec v2 §7): one `●` per online teammate, tinted
    by the teammate hue, space-joined — rides the Row1 right rail."""
    dots = []
    for m in members:
        seed = m.get("haid") or m.get("user") or m.get("sigil") or "?"
        hue = _team_hue(seed, m.get("sigil")) if USE_COLOR else None
        col = sgr(SIG._hex_rgb(hue)) if hue else DIM
        dots.append(f"{col}●{X}")
    return " ".join(dots)

def daemon_seg(ledger):
    return f"{GR}◆{X}" if ledger.get("daemon") == "up" else f"{FAINT}◇{X}"


def daemon_rail(verdict):
    """Row1 right-rail watchman state (Spec v2 §2): `◦ watching` faint (idle watch) /
    `⚡ scanning` gold (a gate run in flight) / `✗ down` red (a gate deny). Driven by the
    live verdict — the watchman's own state — since there is no daemon process today."""
    if verdict == "scanning":
        return f"{AM}⚡ scanning{X}"
    if verdict == "deny":
        return f"{RD}✗ down{X}"
    return f"{FAINT}◦ watching{X}"


# ── git working-tree counts (cached — Spec v2 §5) ─────────────────────────────
def _gitcount_cache_path(cwd):
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", os.path.abspath(str(cwd)))[-80:] or "root"
    tmp = os.environ.get("HMD_STATUSLINE_TMP") or "/tmp"
    return os.path.join(tmp, "hmd-statusline-gitcount-" + slug)


def git_counts(cwd):
    """(staged, modified) working-tree counts for `cwd`, cached 5s (Spec v2 §5). ONE
    `git status --porcelain` fork on a cache MISS; a warm render reads the cache with ZERO
    forks. Returns (0,0) when clean, or None on any fault / non-repo (→ the `+n ~n` segment
    is omitted). Never raises."""
    p = _gitcount_cache_path(cwd)
    with contextlib.suppress(Exception):
        if time.time() - os.path.getmtime(p) <= 5.0:
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
            if isinstance(d, list) and len(d) == 2 and d[0] is not None:
                return int(d[0]), int(d[1])
            return None
    result = None
    try:
        r = subprocess.run(["git", "-C", str(cwd), "status", "--porcelain"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=0.6)
        if r.returncode == 0:
            staged = modified = 0
            for line in r.stdout.decode("utf-8", "replace").splitlines():
                if len(line) < 2:
                    continue
                if line[0] not in (" ", "?"):
                    staged += 1
                if line[1] != " ":
                    modified += 1
            result = (staged, modified)
    except Exception:
        result = None
    with contextlib.suppress(Exception):
        os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
        tmp = p + ".%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(list(result) if result is not None else [None, None], f)
        os.replace(tmp, p)
    return result


# ── Row4 limit micro-gauges (Spec v2 §2/§4) ───────────────────────────────────
def _reset_hours(data, now):
    """ceil hours until five_hour.resets_at, sanitized to 0 < Δ ≤ 5h (else None) — the same
    far-future overflow guard as reset_countdown, in whole hours for the Row4 5h micro-bar."""
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return None
    fh = rl.get("five_hour")
    if not isinstance(fh, dict):
        return None
    ra = fh.get("resets_at")
    if isinstance(ra, (int, float)) and not isinstance(ra, bool) and ra > now:
        rem = ra - now
        if 0 < rem <= FIVE_HOUR_S:
            return max(1, -(-int(rem) // 3600))   # ceil hours
    return None


def micro_row(data, now, bar_w, session_id, dur_ms, avail=None):
    """Row4 content (Spec v2 §2): two rate-limit micro-gauges — 5h (cyan) + 7d (gold), from
    rate_limits.*.used_percentage, both following the shared ramp (own hue → gold ≥70 → red
    ≥90). `bar_w` is the bar cell count (12c full / 8c mid; 0 → plain micro_text). When
    rate_limits is ABSENT the row shows session stats `<Hh MMm> · <session>` faint instead —
    never a fabricated 0%. Self-downgrades to plain micro_text if the bars overflow `avail`."""
    fh = five_hour_pct(data)
    sd = seven_day_pct(data)
    if fh is None and sd is None:
        dur = GAUGE.humanize_duration(dur_ms) if dur_ms is not None else ""
        sid = str(session_id or "")[:8]
        parts = [s for s in (dur, sid) if s]
        return f"{FAINT}{' · '.join(parts) if parts else 'session'}{X}"
    rh = _reset_hours(data, now)
    if bar_w and bar_w > 0:
        mg5 = GAUGE.render_micro_gauge(bar_w, GAUGE.CYAN, fh, CAPS, "5h", reset_h=rh)
        mg7 = GAUGE.render_micro_gauge(bar_w, GAUGE.GOLD, sd, CAPS, "7d")
        s = mg5 + SEP + mg7
        if avail is None or vis(s) <= avail:
            return s
    # plain text (narrow tier, or the bars overflow the available span)
    return GAUGE.micro_text("5h", fh, rh) + SEP + GAUGE.micro_text("7d", sd)

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


# The proven-merge count that earns the badge offer. Exact, not a floor: the offer is a
# one-shot moment, so it belongs to the merge that crosses the line and to no other.
BADGE_OFFER_AT = 10

def _proven_merges(beats_path):
    """Count of `pass` verdicts in a beats.log — one `<iso-ts>\\t<verdict>\\t<file>` line per
    gated commit. Byte-wise and streaming: a half-written or binary-garbled line can never
    raise, and the file is never held in memory. This is the SAME reader shape as
    bin/heimdall-badge:59-63 and bin/heimdall-clip:61-65, so the HUD's number and the
    number `hmd badge` prints cannot drift apart. Any fault → None (never a false count)."""
    try:
        n = 0
        with open(beats_path, "rb") as f:
            for raw in f:
                parts = raw.split(b"\t")
                if len(parts) >= 2 and parts[1].strip() == b"pass":
                    n += 1
        return n
    except Exception:
        return None

def badge_offer_notice(cwd, width=None):
    """The badge OFFER: one ambient line, shown EXACTLY ONCE, the moment this repo's 10th
    merge is proven. A dev only runs `hmd badge` if they know it exists, so the offer has
    to come to them — but exactly once, because a nudge that reappears every session gets
    muted, and then the nudge that MATTERS is muted with it.

    PURE LOCAL READ: <cwd>/.heimdall/receipts/beats.log, the same store `hmd badge --count`
    counts. No network, no subprocess — this is on the interactive render path.

    Returns '' unless the count is EXACTLY BADGE_OFFER_AT and the once-only stamp
    (<cwd>/.heimdall/.badge-offer) does not already exist.

    FIT BEFORE FIRE: `width` is the content width the caller can actually give this row.
    A notice that would not fit whole is not shown AND not stamped — burning the one shot
    on a row the terminal clips would spend it on nobody.

    FAIL-CLOSED ON PERSISTENCE: the stamp is written BEFORE the notice is returned and a
    failed write suppresses the notice, because an offer we cannot record is an offer that
    repeats. O_EXCL makes the create the atomic winner-takes-it, so two concurrent renders
    cannot both fire it."""
    hd = os.path.join(cwd, ".heimdall")
    stamp = os.path.join(hd, ".badge-offer")
    try:
        if os.path.exists(stamp):
            return ""
    except Exception:
        return ""
    n = _proven_merges(os.path.join(hd, "receipts", "beats.log"))
    if n != BADGE_OFFER_AT:
        return ""
    note = (f"{GR}🛡 {n} proven merges{X} {FAINT}·{X} {DIM}hmd badge{X} "
            f"{FAINT}→ pin it to your README{X}")
    if width is not None and vis(note) > width:
        return ""
    try:
        fd = os.open(stamp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        try:
            os.write(fd, (json.dumps({"count": n, "epoch": int(time.time())}) + "\n").encode())
        finally:
            os.close(fd)
    except Exception:
        return ""
    return note




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

# Row3 gate-label detail levels (richest → sparsest): 0 = `<mark> <id> <detail>`,
# 1 = `<mark> <id>`, 2 = `<mark>` only. The mark (verdict glyph) is ALWAYS kept; the
# detail is dropped first, then the id, when the row is width-constrained.
_GATE_LVL_FULL, _GATE_LVL_ID, _GATE_LVL_MARK = 0, 1, 2

def _gate_seg(g, level, colored):
    """One gate rendered at `level`: mark (verdict-coloured) + optional id (dim) + optional
    detail (faint). The mark is always present; the id/detail are gated by `level`."""
    glyph, col = _GATE_GLYPH.get(g.get("state"), ("◌", DIM))
    mark = f"{col}{glyph}{X}" if colored else glyph
    gid = str(g.get("id") or "")
    if level >= _GATE_LVL_MARK or not gid:
        return mark
    idpart = f" {DIM}{gid}{X}" if colored else " " + gid
    detail = str(g.get("detail") or "")
    if level >= _GATE_LVL_ID or not detail:
        return mark + idpart
    detpart = f" {FAINT}{detail}{X}" if colored else " " + detail
    return mark + idpart + detpart

def gate_labels(gates, avail, colored=True):
    """Row3 gate labels — `<mark> <id> <detail> · …` (e.g. `✓ secrets · ✓ tests 41/41 ·
    ✓ designmatch .91`). Mark ✓ pass / ◌ running / ✗ deny; id + detail from the ledger
    gates[]. BUDGET: render at the RICHEST detail level whose visible width fits `avail`,
    dropping the detail first (level 1) then the id (level 2 → marks only) GLOBALLY when
    width-constrained — the verdict mark is never dropped. Empty gates → `◌ offline` (no
    ledger). The caller still pad_or_truncate()s to the exact span as a last resort."""
    if not gates:
        return f"{FAINT}– gates offline{X}" if colored else "gates offline"
    sep = f"{FAINT} · {X}" if colored else " · "
    seg = ""
    for level in (_GATE_LVL_FULL, _GATE_LVL_ID, _GATE_LVL_MARK):
        seg = sep.join(_gate_seg(g, level, colored) for g in gates)
        if avail is None or vis(seg) <= avail:
            return seg
    return seg   # marks-only still over budget → caller clips

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

# ── Row1 identity — WHOLE-SEGMENT drop (Spec v2 §2/§7: text drops per tier, NEVER
# mid-token) ─────────────────────────────────────────────────────────────────────
def row1_left(handle, model, repo_seg, cseg, avail):
    """The Row1 identity left run — `⛭ HEIMDALL │ rj · Opus 4.8 │ heimdall:branch +2 ~1`
    — reduced to fit `avail` cells by dropping WHOLE segments, never slicing a token with
    an ellipsis (the `rj · Opus …` / `heimdall:statu…` mid-word clip from the 80c render).

    Drop order, least → most important: git counts → model name → handle → repo:branch.
    The `⛭ HEIMDALL` brand is the anchor and is NEVER dropped (if even it overruns a
    pathologically narrow rows zone, the caller's exact-width clamp handles it — but at
    every tier ≥ narrow the brand fits). Dependencies fall out of the order: the model
    never renders without its handle, git counts never render without their repo.

    `avail` None → no width pressure, the full run is returned."""
    brand = f"{BLUE}{BOLD}⛭ HEIMDALL{X}"

    def build(handle_on, model_on, repo_on, counts_on):
        s = brand
        if handle_on:
            idt = f"{handle} · {model}" if model_on else str(handle)
            s += f"{SEP}{DIM}{idt}{X}"
        if repo_on:
            s += f"{SEP}{repo_seg}" + (cseg if counts_on else "")
        return s

    # richest → sparsest whole-segment combos (H=handle M=model R=repo:branch C=counts).
    # repo:branch outranks the model name; when the repo string won't fit at all it is
    # dropped as a UNIT and the handle (± model) is kept — never a sliced `heimdall:statu…`.
    combos = (
        (True,  True,  True,  True),    # rj · Opus 4.8 │ heimdall:branch +2 ~1
        (True,  True,  True,  False),   # rj · Opus 4.8 │ heimdall:branch
        (True,  False, True,  False),   # rj │ heimdall:branch          (drop model)
        (True,  True,  False, False),   # rj · Opus 4.8                 (repo won't fit → drop as a unit)
        (True,  False, False, False),   # rj                            (handle only)
        (False, False, False, False),   # ⛭ HEIMDALL                    (brand anchor only)
    )
    for h, m, r, c in combos:
        s = build(h, m, r, c)
        if avail is None or vis(s) <= avail:
            return s
    return brand


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
    _write(LAYOUT.pad_or_truncate(f"{BLUE}{BOLD}⛭ HEIMDALL{X}", cols) + "\n")

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
    seed, handle = identity(cwd, fallback, session_id)

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

    # ── the 4-row composite, laid out to the RIGHT of the 9c hero sigil anchor ──
    sigrows = _sigil_rows(seed, eye)                     # 8-wide × 4 rows (the main sigil)

    # the Row2 fill ramp is tinted from the user's OWN sigil VIVID accent (batsy→blue,
    # hulk→green, …); the gold/red danger tint stays hue-independent + tip-only. None →
    # the default blue shader.
    try:
        sig_hue = SIG.sigil_accent_color(seed)
    except Exception:
        sig_hue = None

    tin = cw.get("total_input_tokens")
    cost_obj = data.get("cost")
    cost = cost_obj.get("total_cost_usd") if isinstance(cost_obj, dict) else None
    dur_ms = cost_obj.get("total_duration_ms") if isinstance(cost_obj, dict) else None

    # ── team roster (§6) + the anti-truncation ZONE ALLOCATION (§2 — team reserved FIRST) ──
    # team_zone_alloc reserves the team zone from the RIGHT edge BEFORE the gauge is sized —
    # the order swap that stops a teammate eye-strip from ever being truncated. mid → 2
    # members + +N (states drop); narrow → the roster becomes inline dots on Row1 (no zone).
    members, overflow = _team_members(cwd, ledger)
    roster = list(members)                               # kept for the narrow-tier dots
    team_states = True
    if tier == "mid":
        if len(members) > 2:
            overflow += len(members) - 2
            members = members[:2]
        team_states = False                              # §7 mid: states drop (name only)

    inner = cols - 9                                     # everything right of the 9c sigil zone
    # team_zone_alloc sizes the team zone + caps members so the gauge keeps its floor; we take
    # its rows-zone width as the CONTENT BUDGET (build the rows at their richest that fits).
    # The team is then placed as a COMPACT 2ND COLUMN hugging the content (a TEAM_COL_GAP
    # gutter), NOT flush to the right edge: a flush-right team at a wide terminal sits out at
    # $COLUMNS, which overshoots CC's narrower live statusLine region and gets clipped (RJ's
    # right-side truncation). Left-packing keeps the whole render only as wide as its content +
    # team, so nothing ever rides the far edge; the per-row hard clamp pads the tail with blanks.
    if tier in ("full", "mid") and members:
        # reserve the SAME TEAM_COL_GAP gutter the compose step renders, so content_budget is
        # the exact col1 ceiling — col1_w + gap + team_w <= inner, never a hard-clamp `…` clip.
        content_budget, team_w, shown_n, of, _alloc_gap = LAYOUT.team_zone_alloc(
            cols, len(members), overflow, rows_gap=TEAM_COL_GAP)
        members = members[:shown_n]
        team_gap = TEAM_COL_GAP
    else:
        content_budget, team_w, of, team_gap = inner, 0, overflow, 0

    # the gauge is the ONLY flexible element in the rows zone: 40c full / 32c mid, min 24.
    gauge_max = LAYOUT.GAUGE_MAX_W if tier == "full" else 32
    gauge_w = max(0, min(gauge_max, content_budget))

    if team_w > 0:
        t1, t2, t3, t4 = team_columns(members, team_w, of, t, states=team_states,
                                      self_branch=branch or "")
    else:
        t1 = t2 = t3 = t4 = ""

    # ── Row1 — identity (left) + the watchman rail (right) ──
    # `⛭ HEIMDALL` (blue) │ `rj · Opus 4.8` (dim) │ `heimdall:branch` (ink·faint) +staged
    # ~modified (mint·gold). Right rail: the watchman state (◦ watching / ⚡ scanning / ✗ down).
    if repo_name:
        repo_seg = f"{INK}{repo_name}{X}" + (f"{BRANCHC}:{branch}{X}" if branch else "")
    else:
        repo_seg = f"{INK}{repo_str}{X}"
    counts = git_counts(cwd) if branch else None
    cseg = ""
    if counts and (counts[0] or counts[1]):
        cparts = []
        if counts[0]:
            cparts.append(f"{MINT}+{counts[0]}{X}")
        if counts[1]:
            cparts.append(f"{GOLDC}~{counts[1]}{X}")
        cseg = " " + " ".join(cparts)
    right1 = daemon_rail(verdict)
    if tier == "narrow":
        dots = team_dots(roster)                         # §7 narrow: inline `● ● ●`
        if dots:
            right1 += "  " + dots
    # WHOLE-SEGMENT drop: fit the identity run into the span left of the right rail so a
    # tier-narrowed Row1 drops `· Opus 4.8` / `heimdall:branch` as whole units — never a
    # mid-token `…` (Spec v2 §2). Reserve 1c so the two runs never abut with no gap.
    avail1 = max(0, content_budget - vis(right1) - 1)
    left1 = row1_left(handle, model, repo_seg, cseg, avail1)

    # ── Row2 — the context gauge (CTX%·↓tokens on the fill, $cost on the track end) ──
    # narrow → bar-only (labels off). render_gauge splices the labels inside the bar's cell
    # array, preserving each cell's bg ramp, and gates them by bar width internally.
    gauge = GAUGE.render_gauge(gauge_w, pct, tin, cost, CAPS, base_hue=sig_hue,
                               labels=(tier != "narrow"))

    # ── Row3 — the gate labels `✓ <id> <detail> · …` (ledger missing → `– gates offline`) ──
    row3_zone = gate_labels(gates, content_budget, colored=True)

    # ── Row4 — the 5h + 7d limit micro-gauges (session stats when rate_limits is absent) ──
    bar_w = 12 if tier == "full" else (8 if tier == "mid" else 0)
    row4_zone = micro_row(data, t, bar_w, session_id, dur_ms, avail=content_budget)

    # ── COMPACT column-1: shrink the content column to the NATURAL width of its widest row so
    # the team column HUGS the content (a TEAM_COL_GAP gutter) instead of the far edge. col1_w
    # is >= every row's natural width (no new truncation) and <= the content budget. Solo
    # (team_w==0) keeps the full inner width so the watchman rail stays right-anchored. ──
    if team_w > 0:
        nat1 = vis(left1) + (1 + vis(right1) if right1 else 0)
        col1_w = min(content_budget,
                     max(nat1, gauge_w, vis(row3_zone), vis(row4_zone)))
        col1_w = max(1, col1_w)
    else:
        col1_w = content_budget

    row1_zone = LAYOUT.left_right(left1, right1, col1_w)

    def compose(zone, col):
        """content column (padded to col1_w) + the TEAM_COL_GAP gutter + the team column. Solo
        → just the padded content column. Sum <= inner; the caller's exact-width clamp pads the
        trailing blanks so the team never rides the far edge (the anti-truncation left-pack)."""
        z = LAYOUT.pad_or_truncate(zone, col1_w)
        return z if team_w <= 0 else z + " " * team_gap + col

    row1 = compose(row1_zone, t1)
    row2 = compose(gauge, t2)
    row3 = compose(row3_zone, t3)
    row4 = compose(row4_zone, t4)

    # ── ambient "update available" notice (RJ's ask: a dev learns of a newer Heimdall
    # release WITHOUT running any command). update_notice() is a PURE LOCAL read of the
    # update-check cache bin/heimdall's daily background probe writes — zero network, zero
    # subprocess on the render path — and returns '' on a current/ahead/missing/corrupt
    # cache, so a current install renders byte-identically (the density goldens stay exact).
    # It rides one extra row under the CONTENT column (blank sigil prefix via
    # compose_with_sigil), shown only when it fits WHOLE in the content width so a narrow
    # terminal never wraps the line nor clips the `hmd --update` command.
    content_rows = [row1, row2, row3, row4]
    content_w = LAYOUT.remaining_width(sigrows, cols, GUTTER)
    note = update_notice()
    if note and vis(note) <= content_w:
        content_rows.append(note)

    # ── the BADGE OFFER (one-shot): the 10th proven merge earns a README badge, and the
    # dev learns that WITHOUT running a command. Same pure-local-read, same one-extra-row
    # mechanism as the update note above, but it fires exactly once ever — badge_offer_notice
    # persists a stamp as it fires and returns '' forever after, so a repo past its 10th
    # merge renders byte-identically (the density goldens stay exact). It is handed the
    # content width so it can decline to fire rather than spend its one shot on a row this
    # terminal would clip.
    offer = badge_offer_notice(cwd, content_w)
    if offer:
        content_rows.append(offer)

    # ── the parallel-agent SWARM block (bottom rows) — spectacle + per-agent receipt.
    # Rendered ONLY when >1 REAL live agent is in agent-pool; 1-or-fewer → swarm is None
    # and the composite is byte-for-byte unchanged (the density goldens stay exact). Each
    # row rides its own line under the CONTENT column via compose_with_sigil's blank-sigil
    # prefix (same mechanism as the update note), hard-clamped to the content width below.
    swarm = swarm_block(cwd)
    if swarm:
        content_rows.extend(swarm)

    lines = LAYOUT.compose_with_sigil(sigrows, content_rows, cols, GUTTER)
    # HARD COLUMNS CLAMP (the CC live-statusline safety net): every assembled line is forced
    # to EXACTLY `cols` visible cells so CC can never truncate a row mid-token (the `…` clip)
    # nor soft-wrap an over-wide row into a thin duplicate strip.
    lines = [LAYOUT.pad_or_truncate(l, cols) for l in lines]
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

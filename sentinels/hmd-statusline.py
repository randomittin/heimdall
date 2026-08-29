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
import hashlib
import re as _re_drain
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
WALL = _load("hmd_wall")          # import hmd_wall — the repo wall reader (repo_roster cache)

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

_ROSTER_LIB = os.path.join(BIN_DIR, "lib", "repo_roster.py")


def _github_handle(cwd, fallback):
    """The GitHub login the owner is publicly known by, for the Row1 identity — else
    `fallback` (the identity handle Row1 showed before).

    `rj` is a git-config nickname. `randomittin` is the name on his commits, on his
    teammates' walls and on every roster row — so the header was introducing him under the
    one name that appears nowhere else in the product.

    ONE RESOLVER, REUSED. repo_roster.local_github_login() already answers this (the
    git-config / HAID / `gh api user` chain, cached positively and negatively), and the
    roster exists so that there is a SINGLE answer to "who am I". Re-deriving it here would
    put a second chain directly above the wall the first one builds, free to disagree with
    it — so this asks, and does not re-implement.

    CACHE READS ONLY (`spawn=False`). This runs on every keystroke: it may not probe `gh`,
    and may not even fork the roster's detached refresh, because the wall refresh child
    already warms this exact cache file — the signal simply lands on a later prompt. A
    missing `gh`, an unauthenticated or rate-limited one, no network, and a cold cache all
    resolve to '' and fall back, so Row1 degrades to the previous handle and is NEVER blank.
    Never raises: a broken or absent roster lib is just another way to have no signal."""
    try:
        spec = importlib.util.spec_from_file_location("hmd_repo_roster", _ROSTER_LIB)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        login = mod.local_github_login(cwd, spawn=False)
    except Exception:
        return fallback
    return login.strip() if isinstance(login, str) and login.strip() else fallback


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
    # The WALL refresh — repo_roster's ~62ms build (O(n²) identity unification), kept OFF the
    # render path entirely. It rides this SAME already-throttled child, so a warm wall costs
    # ZERO extra forks; the 15-min cache TTL plus a 120s lock bounds it to at most one build
    # per repo per refresh window. --blocking is right HERE and only here: this child is
    # detached and nothing waits on it, so warming the git/github caches synchronously just
    # means the file it writes is complete.
    wall_cache = WALL.wall_cache_path(cwd); wlock = wall_cache + ".lock"
    roster_lib = os.path.join(BIN_DIR, "lib", "repo_roster.py")
    # `producer=roster_lib` keys the cache on the CODE as well as the clock: a wall cache
    # written before the roster lib it memoises is COLD on sight, so a roster fix (an identity
    # merge, a tier change) can never keep serving its pre-fix answer for the rest of the TTL.
    # Without it the renderer and `repo_roster.py --repo <same repo>` disagreed for 15 minutes
    # after every roster change — two sources of truth for who is on the wall.
    try:
        wall_due = (os.access(roster_lib, os.R_OK) and
                    WALL.refresh_due(cwd, producer=roster_lib) and
                    not (os.path.exists(wlock) and now - os.path.getmtime(wlock) < 120))
    except Exception:
        wall_due = False
    if not beat_due and not roster_due and not wall_due:
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
        # `rm -f` the TEMP as well as the lock. The `&&` short-circuits when the refresh
        # exits non-zero, so `mv` never runs — and without this the temp is orphaned on
        # EVERY failed background refresh. Measured before the fix: 1163 orphaned
        # `.roster-cache.json.<pid>.tmp` files beside a single live cache, on a statusline
        # that respawns this on every prompt.
        pieces.append("%s roster --json > %s 2>/dev/null && mv -f %s %s; rm -f %s %s" %
                      (shlex.quote(bin_path), shlex.quote(tmp), shlex.quote(tmp),
                       shlex.quote(cache), shlex.quote(tmp), shlex.quote(lock)))
    if wall_due:
        try:
            open(wlock, "w").close()
        except Exception:
            wall_due = False
    if wall_due:
        wtmp = wall_cache + ".%d.tmp" % os.getpid()
        pieces.append("%s %s --repo %s --blocking > %s 2>/dev/null && mv -f %s %s; rm -f %s %s" %
                      (shlex.quote(sys.executable or "python3"), shlex.quote(roster_lib),
                       shlex.quote(cwd), shlex.quote(wtmp), shlex.quote(wtmp),
                       shlex.quote(wall_cache), shlex.quote(wtmp), shlex.quote(wlock)))
    if not pieces: return
    try:
        subprocess.Popen(["/bin/sh", "-c", "; ".join(pieces)], cwd=cwd, env=env,
                         start_new_session=True, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    except Exception:
        if roster_due: _quiet_rm(lock)
        if wall_due: _quiet_rm(wlock)

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
            # The server's own flag — the roster now carries away teammates (past the 45s TTL,
            # inside the 7-day offline window) as online:false so they render greyed instead of
            # vanishing. Absent on an older CP → assume online (the row was returned at all,
            # which on that CP could only mean live). NEVER hardcoded true: a wall that invents
            # a present teammate is worse than an empty one.
            "online": r.get("online") if isinstance(r.get("online"), bool) else True,
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

def _agent_tiers_cache_path(cwd): return os.path.join(cwd, ".heimdall", ".agent-tiers-cache.json")

def _agent_tiers_ttl():
    try: return float(os.environ.get("HMD_AGENT_TIERS_TTL", "300"))
    except Exception: return 300.0

def _agent_tiers_lock_ttl():
    try: return float(os.environ.get("HMD_AGENT_TIERS_LOCK_TTL", "30"))
    except Exception: return 30.0

def _spawn_agent_tiers_refresh(cwd):
    """Detached, throttled, fire-and-forget refresh of the per-agent tier cache via
    `bin/heimdall-tier agents --json` — the ONE frontmatter parser (heimdall-tier's
    read_frontmatter), never a second one here that could quietly disagree with
    `heimdall-tier check`'s own verdict. Mirrors _spawn_presence's stat-gate + lock
    + detached-child + atomic-rename shape. Called ONLY from swarm_block(), itself
    only reached once 2+ live agents already exist — the solo-agent render path
    never calls this, never stats the cache, never forks."""
    bin_path = os.path.join(BIN_DIR, "heimdall-tier")
    if not os.access(bin_path, os.X_OK): return
    now = time.time()
    cache = _agent_tiers_cache_path(cwd); lock = cache + ".lock"
    try:
        fresh = os.path.exists(cache) and now - os.path.getmtime(cache) < _agent_tiers_ttl()
        locked = os.path.exists(lock) and now - os.path.getmtime(lock) < _agent_tiers_lock_ttl()
    except Exception:
        return
    if fresh or locked: return
    try:
        os.makedirs(os.path.join(cwd, ".heimdall"), exist_ok=True)
        open(lock, "w").close()
    except Exception:
        return
    tmp = cache + ".%d.tmp" % os.getpid()
    cmd = ("%s agents --json --repo %s > %s 2>/dev/null && mv -f %s %s; rm -f %s %s" %
           (shlex.quote(bin_path), shlex.quote(cwd), shlex.quote(tmp), shlex.quote(tmp),
            shlex.quote(cache), shlex.quote(tmp), shlex.quote(lock)))
    try:
        subprocess.Popen(["/bin/sh", "-c", cmd], cwd=cwd, env=dict(os.environ),
                          start_new_session=True, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    except Exception:
        try: os.remove(lock)
        except Exception: pass

def agent_tier_map(cwd):
    """Best-effort {agent_name: row} from the cached `heimdall-tier agents --json`
    output, keyed by agent template name (e.g. 'coder', 'reviewer'). NEVER reads
    agents/*.md itself on this path — that only happens inside the detached child
    this kicks off when the cache is stale (see _spawn_agent_tiers_refresh). A
    missing, stale or corrupt cache all degrade to {} — the swarm row then simply
    omits the tier tag, the same 'no data -> no segment' contract every other
    swarm-row field (surface, gate verdict) already follows."""
    out = {}
    try:
        with open(_agent_tiers_cache_path(cwd)) as f:
            data = json.load(f)
    except Exception:
        data = None
    if isinstance(data, dict):
        for row in data.get("agents") or []:
            if isinstance(row, dict) and row.get("agent"):
                out[row["agent"]] = row
    _spawn_agent_tiers_refresh(cwd)
    return out

def _role_tier_key(role):
    """Normalize a live agent-pool 'type' string to an agents/*.md template name:
    strip an 'hmd:' dispatch-namespace prefix (this repo's own Agent-tool spawn
    convention — subagent_type: 'hmd:coder', CLAUDE.md 'Parallelism') if present,
    then lowercase/trim. A role matching neither form simply misses the tier-map
    lookup — degrade cleanly, never guess."""
    r = (role or "").strip()
    if r.lower().startswith("hmd:"): r = r[4:]
    return r.strip().lower()

def _tier_tag(role, tier_map):
    """' [tier]' for a swarm row, plus an explicitly-unapplied routing-override
    note when one exists for that agent's class — never rendered as though it
    were the tier actually running. '' when no cached tier data matches this
    role (cold cache, unknown role, or the row's own declared_tier is empty)."""
    if not tier_map: return ""
    info = tier_map.get(_role_tier_key(role))
    if not info: return ""
    tier = info.get("declared_tier") or info.get("model")
    if not tier: return ""
    tag = f" {DIM}[{tier}]{X}"
    ov = info.get("override")
    if isinstance(ov, dict) and ov.get("model"):
        tag += f"{FAINT}→{X}{AM}{ov['model']}(unapplied){X}"
    return tag

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
    row is spectacle + receipt: mini-sigil · role · gate glyph · current file ·
    cached model tier (+ an explicitly-unapplied routing-override note, if one
    exists for that agent's class). The tier lookup is CACHE-ONLY and its
    refresh is kicked off (detached, throttled) only from here — a solo-agent
    render never reaches this line, so it never stats or forks for tier data."""
    agents, mx = active_swarm_agents()
    if len(agents) < 2: return None
    gate = swarm_shared("swarm-gate"); files = swarm_shared("swarm-file")
    claims = swarm_claims(cwd)
    tier_map = agent_tier_map(cwd)
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
        tier_seg = _tier_tag(a["role"], tier_map)
        if v == "deny":  # the screenshot moment — bracket it red so the block reads
            rows.append(f"{RD}▕{X}{g} {DIM}{role}{X} {verdict}{surf}{tier_seg}{RD}▏{X}")
        else:
            rows.append(f"{g} {DIM}{role}{X} {verdict}{surf}{tier_seg}")
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

# ── rate-limit persistence (best-effort bridge for bin/heimdall-session-usage) ──
# Claude Code's own harness-computed rate_limits.{five_hour,seven_day} arrive ONLY on
# THIS hook's live stdin (see bin/heimdall-session-usage's module docstring, PHASE 1
# FINDING — no CLI/`/usage` equivalent, no on-disk cache). This statusline process is
# therefore the only code in the repo that ever sees them, so it persists an
# ALLOWLISTED snapshot to disk, letting a standalone CLI invocation read a recent
# observation instead of nothing. Never a blanket stdin dump (stdin can carry
# transcript/session content) — ONLY the two numeric rate-limit fields per window plus
# an observation timestamp. Best-effort: wrapped so a failure here can NEVER slow or
# break what renders (matches this module's own NEVER-FAILS contract: always exits 0,
# never writes stderr).
RATE_LIMIT_STATE_ENV = "HEIMDALL_RATE_LIMIT_STATE"

def _rate_limit_state_path():
    """GLOBAL by default (~/.heimdall/rate-limits.json) — Anthropic's rate limit is an
    account/session concept, not a per-repo one, so (unlike HEIMDALL_STATE's cwd-scoped
    default two lines above main()) this must NOT default under the stdin cwd: a
    developer's quota is shared across every repo/worktree at once.
    HEIMDALL_RATE_LIMIT_STATE overrides for tests/power users."""
    override = os.environ.get(RATE_LIMIT_STATE_ENV)
    if override:
        return override
    return os.path.expanduser(os.path.join("~", ".heimdall", "rate-limits.json"))

def _window_snapshot(data, window):
    """rate_limits.<window>.{used_percentage,resets_at} -> {"used_percentage": float,
    "resets_at": float} or None. resets_at is OPTIONAL (seven_day does not always carry
    one) but used_percentage is required — mirrors five_hour_pct's own null-safety
    exactly, never fabricates a value for either key."""
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return None
    w = rl.get(window)
    if not isinstance(w, dict):
        return None
    up = w.get("used_percentage")
    if not isinstance(up, (int, float)) or isinstance(up, bool):
        return None
    snap = {"used_percentage": float(up)}
    ra = w.get("resets_at")
    if isinstance(ra, (int, float)) and not isinstance(ra, bool):
        snap["resets_at"] = float(ra)
    return snap

def persist_rate_limits(data, now):
    """Best-effort, allowlist-only persist of rate_limits to disk. Writes NOTHING when
    both windows are absent — a run with no rate_limits in stdin is a true no-op,
    silent and harmless. Never raises: ANY failure (permissions, disk full, a race with
    another concurrent render) is swallowed via contextlib.suppress — the same idiom
    this module's own top-level fallback already uses — so the render path is never
    affected. Called before all rendering in main(); must never be able to slow or
    break what the operator sees."""
    with contextlib.suppress(Exception):
        five = _window_snapshot(data, "five_hour")
        seven = _window_snapshot(data, "seven_day")
        if five is None and seven is None:
            return
        payload = {"observed_at": now}
        if five is not None:
            payload["five_hour"] = five
        if seven is not None:
            payload["seven_day"] = seven
        path = _rate_limit_state_path()
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)
        tmp = path + ".%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(json.dumps(payload, sort_keys=True))
        os.replace(tmp, path)

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


def _hero_seed(m):
    """The identity seed used to resolve a teammate's HERO (not just their name hue): a REAL
    haid always wins — sha256-mod-assigned, stable forever (hero_for). A member with no
    ENROLLED haid still deserves a real hero, not the duller curated/animal 2-shade fallback a
    bare handle resolves to (hmd_sigil._HAID_RE: "short demo/handle seeds ... stay on the
    curated/animal path"). So one is synthesized from the handle in the SAME shape a real haid
    has, so it clears _is_haid and resolves through the 190-hero pool — deterministic, so one
    handle always draws the same hero.

    This is the gap behind "name lit up, sigil greyed out": _team_hue's accent colour
    (sigil_accent_color) never checks haid shape, so an online no-haid teammate's NAME was
    always vivid — but eye_strip -> grid_for DOES gate on haid shape, so their SIGIL fell back
    to the duller fallback. 3f5e959 gave the WALL's cache builder this same synthesis
    (bin/lib/repo_roster.py) for its own listing, but it never reached this renderer; this
    closes that gap at the one place both the sigil and the name key off the same seed."""
    haid = m.get("haid")
    if haid and SIG._is_haid(haid):
        return haid
    handle = re.sub(r"[^a-z0-9-]+", "-", str(m.get("user") or m.get("sigil") or "?").lower()).strip("-")
    handle = handle or "teammate"
    h4 = hashlib.sha256(handle.encode()).hexdigest()[:4]
    return "haid:%s.wall-%s" % (handle, h4)


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


def _wall_self_ids(handle, seed):
    """The identifiers that mean "me", built with ZERO subprocesses.

    hmd_ledger._self_ids() resolves the same set but SHELLS OUT to bin/heimdall-identity
    twice; that is affordable there only because it sits behind the ledger's 5s cache. The
    wall needs the self-set on EVERY render, so it reuses the identity main() already
    resolved through the statusline's own 5s identity cache plus the free env/$USER probes.
    Forking here would cost two subprocesses per keystroke — measured at +33ms per render."""
    ids = set()
    for v in (handle, seed, os.environ.get("HMD_HANDLE"), os.environ.get("HMD_HAID"),
              os.environ.get("USER")):
        if v and str(v).strip():
            ids.add(str(v).strip())
    return ids


def _not_self(members, ids):
    """THE ONE MEMBERSHIP GATE — drop the local human from a candidate wall list.

    You are the big hero sigil on the left, never a column on your own wall. Every source of
    wall members passes through here, because the alternative shipped twice: hmd_wall applied
    its own self-exclusion, the ledger mirror applied `filter_team`'s, and the live-presence
    fallback applied NONE. While the wall cache was stale the wall path won and the owner was
    dropped correctly; the moment repo_roster merged him into a single row the wall path
    yielded zero members, the ungated fallback took over, and he reappeared on his own wall.

    Matching is on HANDLE **and** HAID. The roster merge can rename a person — the owner's
    merged row may carry his GitHub login while this render still knows him by the HAID his
    machine minted — so a handle-only gate lets a renamed self straight back through."""
    keep = []
    for m in members or []:
        if not isinstance(m, dict):
            continue
        if any(str(m.get(k) or "") in ids for k in ("user", "name", "handle", "haid")):
            continue
        keep.append(m)
    return keep


def _ledger_in_scope(cwd, ledger):
    """THE SCOPE GATE — the ledger mirror, but ONLY when it is the roster of THIS tree.

    THE DEFECT THIS CLOSES (reported live): "the wall is now showing folks from other repos
    as well initially and then updates it back to the current project".

    The mirror comes from ONE machine-global file, ${HEIMDALL_HOME}/ledger/status.json, which
    bin/heimdall-status-json rewrites on every keeper beat from whatever repo that keeper runs
    in. Its `team` is therefore the roster of the LAST repo to write it, and hmd_ledger filters
    it by time-window and self — never by project. Two live sessions in two repos fight over
    the one slot, so this repo's wall rendered the OTHER repo's people as present here.

    It self-corrected a beat later only because _team_members prefers the repo-scoped wall once
    that wall is BIGGER, so the wrong frame was exactly the FIRST one — while the repo-scoped
    wall cache was still cold. A first paint naming people who are not on this project is a
    false statement about who is here.

    THE RULE: an UNKNOWN scope renders as NOTHING, never as EVERYTHING. An absent stamp (an
    older writer, a torn write, the no-python fallback) is UNKNOWN — not "all repos" — so it
    yields {} and the wall falls through to the two sources that are already repo-scoped
    (<cwd>/.heimdall/.wall-cache.json and .roster-cache.json). The first paint therefore stays
    POPULATED and correct rather than merely blanked.

    Scope is decided by PATH CONTAINMENT against `cwd`, which is exactly how the rest of the
    wall resolves scope (both caches live under <cwd>/.heimdall), so the mirror is in scope
    precisely when those caches are. Containment rather than equality so a session in a
    SUBDIR of the stamped tree still reads its own roster — that admits no other repo, since
    a foreign stamp can never contain this cwd. Pure path arithmetic: no fork, no stat, no
    git — this is the per-keystroke render path. Never raises."""
    if not isinstance(ledger, dict):
        return {}
    stamped = str(ledger.get("repo") or "").strip()
    if not stamped:
        return {}          # UNKNOWN scope → show nothing, never everyone
    try:
        root = os.path.realpath(stamped)
        here = os.path.realpath(cwd or ".")
        if root != here and os.path.commonpath([root, here]) != root:
            return {}      # the stamp names a DIFFERENT tree → not our roster
    except Exception:
        return {}          # unusable stamp (relative, mixed-drive, junk) → fail closed
    return ledger


def _team_members(cwd, ledger, self_ids=None):
    """THE WALL: everyone who works on THIS repo, ranked, each carrying its own tier.

    Reads the precomputed wall cache (hmd_wall — repo_roster's output, refreshed by the
    detached child below) and overlays LIVE presence, so the git/github tiers render TODAY
    without a control plane while the present tense stays decided by the 45s heartbeat alone.

    The wall wins only when it knows about MORE people than the ledger mirror does. That
    keeps every pre-existing render bit-identical when the wall adds nothing (a cold cache,
    a non-git dir, a solo repo) while fixing the case this exists for — a roster of 23 people
    rendering as one lonely sigil.

    THREE SOURCES, ONE GATE. The wall cache, the ledger mirror and the live-presence fallback
    are three ways to LEARN about a teammate, but membership is decided in exactly one place:
    _not_self, applied to each candidate list before it can win. A degraded source may show
    LESS than the roster; it may never show someone the roster excludes. That equality —
    renderer == roster-minus-self, whatever the source — is asserted in
    test/heimdall-wall-roster.test.sh section H.

    Returns (members, overflow). The members are NOT capped here: team_zone_alloc packs as
    many columns as actually fit and folds the remainder into an explicit `+N`, so the cap is
    made by the code that knows the real width instead of a hardcoded 3."""
    ids = {str(s).strip() for s in (self_ids or set()) if s and str(s).strip()}
    live = team_presence(cwd)
    wall, _of = WALL.read_members(cwd, live=live, self_ids=ids)
    # SCOPED first, then self-gated, both BEFORE the comparison. The scope gate drops a mirror
    # that belongs to another repo; without it this repo's wall renders that repo's people on
    # the cold first paint. The overflow rides the SAME gate deliberately — an out-of-scope
    # `+3` would claim three more people are here, which is the identical lie one line shorter.
    mirror = _ledger_in_scope(cwd, ledger)
    # Self-gated BEFORE the comparison: an ungated ledger would count self and make a correct,
    # self-excluded wall look smaller than it is.
    members = _not_self(mirror.get("team"), ids)
    overflow = int(mirror.get("team_overflow") or 0)
    if len(wall) > len(members):
        return wall, 0
    if not members:
        others = _not_self([{"user": m.get("name") or "?", "haid": m.get("haid"),
                             "sigil": "", "branch": m.get("branch") or "",
                             "state": m.get("verdict") or ""} for m in live], ids)
        members = others[:3]
        overflow = max(0, len(others) - 3)
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


def _last_seen(now, ts):
    """A last-seen age in AT MOST 3 cells — `now` / `9m` / `59m` / `3h` / `23h` / `6d` / `52w` /
    `99y`. The team strip is 8 cells wide and the offline segment spends 5 on `⊘off `, so the
    age must stay tiny; the largest unit that fits wins. `off`/`git` ages stay inside the 7-day
    wall/git window in practice, but `mem` carries a member's last COMMIT with no window at all
    — repo_roster attaches it regardless of age — so every bucket up to a clamped 99y is covered
    too; the 3-cell budget must hold for an age of any size, not just the ones seen so far."""
    secs = max(0, int(now - ts))
    if secs < 60:
        return "now"
    if secs < 3600:
        return "%dm" % (secs // 60)
    if secs < 86400:
        return "%dh" % (secs // 3600)
    if secs < 7 * 86400:
        return "%dd" % (secs // 86400)
    if secs < 365 * 86400:
        return "%dw" % (secs // (7 * 86400))
    return "%dy" % min(99, secs // (365 * 86400))


# Row4 NON-PRESENT tier vocabulary — EXTENDS the offline vocabulary 9cad9a9 established
# (`⊘off 3d`) to the two git/github tiers, rather than inventing a competing one. Each entry
# is a glyph that appears NOWHERE in the online set (◉ ⚡ ✗ ○ ●) PLUS a literal word, so the
# tier survives --no-color, a mono terminal AND a colorblind viewer — colour alone fails all
# three. The channels are deliberately split: COLOUR carries only the binary present/absent,
# the WORD carries the four-way tier. That split is what stops a subtle hue from ever being
# the only thing standing between "here" and "not here".
# The Row4 absent segment's cell budget — the team column's LABEL slot, read from the
# layout so the two can never drift. The AGE is budgeted first inside it and never
# truncated; the branch takes only what genuinely remains.
_ABSENT_SEG_CELLS = LAYOUT.TEAM_LABEL_W

TEAM_TIER = {              # tier → (glyph, word, show_age)
    "away":        ("⊘", "off", True),    # a heartbeat, but stale     → `⊘off 3d`
    "contributed": ("⌁", "git", True),    # a commit, no presence ever → `⌁git 3d`
    "member":      ("⌂", "mem", True),    # on the repo; ages ONLY with a real commit →
                                           # `⌂mem 2w`, else bare `⌂mem` — never fabricated
}


def _tier_of(m):
    """The member's presence TIER — the ONE classifier every render decision reads.

    A wall member carries its tier explicitly (hmd_wall). A LEGACY member — an older ledger
    status.json or a local heartbeat file, neither of which has a tier key — keeps the
    pre-existing two-state mapping EXACTLY: an explicit online:false or the pinned "offline"
    state means away, and anything else is treated as present just as before. Presence is
    never INVENTED here, only ever carried."""
    t = m.get("tier")
    if t in WALL.TIER_RANK:
        return t
    if m.get("online") is False or (m.get("state") or "") == "offline":
        return "away"
    return WALL.PRESENT_TIER


def _drained(m):
    """True iff this member is NOT present, and so must render with the identity hue DRAINED
    (MONO sigil + faintest name). Exactly one tier — `online` — is present; every other tier
    is absent. The hero colour therefore appears if and only if the person is here RIGHT NOW,
    which is the single strongest cue on the wall and the one that must never lie."""
    return _tier_of(m) != WALL.PRESENT_TIER


def _team_tier_seg(m, now):
    """Row4 NON-PRESENT segment — `⊘off 3d` / `⌁git 3d` / `⌂mem` in the faintest hue. This is
    the only thing on an absent person's column that says so in WORDS.

    UNMISTAKABLE BY CONSTRUCTION, three ways that do not depend on each other:
      • the glyph is outside the online vocabulary (◉ rev / ⚡ wrk / ✗ deny / ○ idle),
      • the literal word survives --no-color, a mono terminal, and a colorblind viewer —
        colour alone would fail all three,
      • the age is the ONE number shown, and it is the age of the tier's OWN signal (last
        heartbeat for `off`, last COMMIT for `git` AND for `mem` — a member can carry a real
        commit that simply fell outside the contributed window), so the number never labels
        a clock it did not come from. A member with no commit at all still shows bare `mem`,
        never a fabricated age.
    An absent person must never be a subtly-different present one: a viewer who misreads this
    is the exact failure this wall exists to prevent."""
    glyph, word, show_age = TEAM_TIER.get(_tier_of(m), TEAM_TIER["member"])
    # The WORD slot prefers the person's BRANCH when we know it. `git` is the same string on
    # every contributed row — it spends the widest field on the column telling you a source
    # that never varies, while `fix/mdr-preview-cardid` says what they were actually doing.
    # The tier stays readable without it: the glyph is already outside the online vocabulary
    # and differs per tier, and the hue still carries present/absent. When there is no branch
    # (no tip they authored) the word returns, so the slot is never empty and the tier is
    # never unlabelled.
    ts = m.get("ts")
    has_age = show_age and isinstance(ts, (int, float)) and not isinstance(ts, bool)
    age = _last_seen(now, ts) if has_age else ""
    branch = str(m.get("last_branch") or "").strip()

    # THE AGE OUTRANKS THE BRANCH, always. The segment is 8 cells; `<glyph><branch> <age>`
    # does not fit both at that width, and the earlier attempt clipped the AGE — producing
    # `⌁main 1…`, which drops the very number that says "not here" and leaves a bare branch
    # under a name. That is the presence misread this wall exists to prevent, so the branch
    # is shown ONLY when it fits WHOLE alongside a WHOLE age. Otherwise the tier word
    # returns. A wider terminal earns the branch; a narrow one never trades away the signal.
    room = _ABSENT_SEG_CELLS - len(glyph) - (len(age) + 1 if age else 0)
    label = branch if (branch and 0 < len(branch) <= room) else word
    if age:
        return f"{FAINT}{glyph}{label} {age}{X}"
    return f"{FAINT}{glyph}{label}{X}"


def _team_state_seg(m, now):
    """Row4 per-member state (Spec v2 §6): `◉ rev` mint / `⚡ wrk` gold / `✗ deny` red, or
    `○ <N>m` faint (last-seen minutes) for an idle/unknown state. A NON-PRESENT teammate gets
    the explicit tier segment instead — checked FIRST so no online glyph can ever claim them."""
    if _drained(m):
        return _team_tier_seg(m, now)
    # A wall member carries the LIVE verdict verbatim ("working"), a ledger member carries an
    # already-normalized state ("running"); _norm_state maps both and is idempotent. Only a
    # NON-EMPTY state is mapped — _norm_state sends the unknown/empty case to "running", and
    # painting a teammate with no reported verdict as "actively working" would be fabrication.
    raw = str(m.get("state") or "").strip()
    g = TEAM_STATE.get(LEDGER._norm_state(raw)) if raw else None
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
    label slot; the caller pad_or_truncate()s it to TEAM_LABEL_W (a long branch clips with `…`)."""
    b = str(branch or "").strip()
    return f"{BRANCHC}⎇{b}{X}"


# ── the wall NAME LABEL — collision-safe truncation ───────────────────────────────────────
# THE PROPERTY: no two visible columns may share a rendered label.
#
# The roster deliberately REFUSES to merge two people it cannot prove are one, because a
# wrong merge hides a human. `ravikiran2904` and `ravikiranuo` are two such people. The
# renderer then re-merged them at the very last step: an 8-cell name slot cut both at 7
# chars + `…` and emitted `ravikir…` twice, adjacent. Every bit of upstream caution was
# undone by the final `[:7]`.
#
# The cut itself was never the defect — a real `…`, consistently placed, reads as
# deliberate rather than broken. What it lacked was a fallback for the case where the
# difference does not live in the head. So the label is chosen off a LADDER, and a name
# only climbs it when it actually collides:
#
#   1. the PLAIN head cut (`priyadh…`)  — unchanged for everyone who is already unique,
#      so collision handling never rewrites the innocent;
#   2. a MIDDLE cut (`ravi…904` / `ravi…nuo`) — the same 8 cells, respent on the part
#      that actually differs, with the narrowest tail that separates the group widened
#      to _LABEL_TAIL_MIN so the suffix reads as a suffix and not as a typo;
#   3. an explicit ORDINAL (`akshat·2`) — reached only when the names carry no difference
#      to show at all. Two rows with the same handle are a roster-level anomaly, but the
#      guarantee this makes cannot depend on an invariant the renderer cannot see, and a
#      visible ordinal at least says "two rows claim this name" instead of quietly
#      drawing one person twice.
_LABEL_TAIL_MIN = 3   # the shortest tail that reads as a suffix rather than a stray char


def _label_key(label):
    """(characters, was-it-cut) — what a reader actually tells two columns apart by.

    The `…` is only a signal where it separates a CUT label from a WHOLE one: `priyadh…`
    beside `priyadh` honestly says "there is more name here that did not fit". Between two
    cut labels its POSITION carries no identity at all, so `superpe…` beside `superp…e` is
    two renderings of the same seven characters and reads as one person. Keying on the
    pair is what stops the ladder from answering a collision by shuffling the ellipsis."""
    return (label.replace("…", "").strip(), "…" in label)


def _mid_label(name, width, tail):
    """`name` cut in the MIDDLE — `head…tail` — in exactly `width` cells, or None when the
    cut cannot be made honestly.

    A name that already FITS is never cut: `akshat` is six characters in an eight-cell
    slot, so `akshat…t` would claim characters were elided that never existed. Inventing a
    cut to win a tie-break is fabrication, and it is not available to this ladder."""
    head = width - 1 - tail
    if head < 1 or tail < 1 or len(name) <= width:
        return None
    return LAYOUT.pad_or_truncate(name[:head] + "…" + name[-tail:], width)


def _ordinal_label(name, width, k):
    """`name` with an explicit `·k` discriminator — `akshat·2` — in exactly `width` cells."""
    suffix = "·%d" % k
    body = LAYOUT.pad_or_truncate(name, max(1, width - len(suffix))).rstrip()
    return LAYOUT.pad_or_truncate(body + suffix, width)


def wall_labels(names, width):
    """`names` → one EXACTLY-`width`-cell label each, with NO two labels equal.

    Deterministic: the same roster renders the same labels every time. Never raises —
    every rung of the ladder is a pure string operation over data already in hand.
    """
    names = [str(n or "") for n in names]
    plain = [LAYOUT.pad_or_truncate(n, width) for n in names]
    out = list(plain)

    # ── rung 2, per GROUP. Distinctness is MONOTONE in the tail length — two names whose
    # last `t` chars differ also differ over their last `t+1` — so the first tail that
    # separates a group is the threshold, and widening it to _LABEL_TAIL_MIN can only
    # ever keep it separated. That is why the widen loop below is safe to take blind.
    for label in sorted({p for p in plain if plain.count(p) > 1}):
        idxs = [i for i, p in enumerate(plain) if p == label]
        for tail in range(1, width - 1):
            cand = [_mid_label(names[i], width, tail) for i in idxs]
            if any(c is None for c in cand) or len(set(cand)) != len(cand):
                continue
            wider = [_mid_label(names[i], width, max(tail, _LABEL_TAIL_MIN)) for i in idxs]
            if all(c is not None for c in wider) and len(set(wider)) == len(wider):
                cand = wider
            for i, c in zip(idxs, cand):
                out[i] = c
            break
        else:
            # No cut anywhere in the slot exposes a difference — the names share both a
            # head and a tail (`superpe-alpha-node` / `superpe-omega-node`), or they are
            # the same string twice. Ordinal the WHOLE group rather than only the loser:
            # `super…·1` beside `super…·2` reads as a deliberate pair, where leaving one
            # bare would quietly nominate it as the real one.
            for n, i in enumerate(idxs, 1):
                out[i] = _ordinal_label(names[i], width, n)

    # ── the global sweep. A middle cut resolves its own group but is not yet proven
    # unique against the REST of the wall (two groups with different heads can share a
    # shorter head), and names that differ only in the middle never separated at all.
    # One ordered pass settles both, and is the only place rung 3 can be reached.
    seen = {}
    for i, label in enumerate(out):
        if _label_key(label) not in seen:
            seen[_label_key(label)] = i
            continue
        alt = None
        for tail in range(1, width - 1):
            cand = _mid_label(names[i], width, tail)
            if cand is not None and _label_key(cand) not in seen:
                alt = cand
                break
        if alt is None:
            # `seen` holds at most len(names)-1 keys and this range yields len(names)+1
            # DISTINCT candidates (the `·k` suffixes differ and are never clipped, since
            # the body is shortened to make room), so one of them is always free.
            for k in range(2, len(names) + 3):
                cand = _ordinal_label(names[i], width, k)
                if _label_key(cand) not in seen:
                    alt = cand
                    break
        out[i] = alt if alt is not None else label
        seen[_label_key(out[i])] = i
    return out


# ── the AWAY hue drain ────────────────────────────────────────────────────────────────────
# MONO was the wrong tool and shipped as blank bars: TC.MONO removes COLOUR, so eye_strip
# emitted bare `▄▄▄▄▄▄▄▄` and an absent teammate lost their FACE, not just their hue. The
# owner saw "two empty lines with my own handle". Draining is a DESATURATION, not a colour
# strip — map each pixel to its luminance so the portrait survives in greyscale and the
# identity hue (the thing that reads as "present") is what goes.
_DRAIN_SCALE = 0.72   # sit clearly below a present column without collapsing the shape
_DRAIN_FLOOR = 26     # keep the darkest pixels off pure black so structure stays readable
_RGB_RE = _re_drain.compile(r"\x1b\[(38|48);2;(\d{1,3});(\d{1,3});(\d{1,3})m")


def _drain_rgb(match):
    layer, r, g, b = match.group(1), *(int(x) for x in match.groups()[1:])
    # Rec.709 luminance: the perceptual grey of that colour, so a bright hue stays bright
    # and a dark one stays dark — which is exactly what preserves facial structure.
    y = int(0.2126 * r + 0.7152 * g + 0.0722 * b)
    y = max(_DRAIN_FLOOR, min(255, int(y * _DRAIN_SCALE)))
    return "\x1b[%s;2;%d;%d;%dm" % (layer, y, y, y)


def _drain_hue(rows):
    """Greyscale an already-emitted sigil strip. Shape preserved, identity hue gone."""
    return [_RGB_RE.sub(_drain_rgb, row) for row in rows]


# ── a stable hero seed for a teammate with no HAID ────────────────────────────────────────
# hmd_sigil auto-assigns one of 190 heroes ONLY to a real `haid:human.machine-hash4` seed;
# a bare handle stays on the curated/animal path, which is a 2-SHADE silhouette. That rule
# is deliberate — it keeps every existing golden untouched — so this does not change it.
#
# But a wall built from git history is mostly people with NO HAID (they have never run hmd),
# and 2 shades means the only thing distinguishing them was hue. Draining that hue for an
# absent teammate then collapsed the whole strip into identical grey blocks: eight teammates,
# one face. Measured: every git-derived member returned shades=2.
#
# So a member without a HAID gets a DETERMINISTIC synthetic one, shaped to satisfy the same
# regex, derived from their handle plus the project so the same person is the same hero on
# the same wall forever. It is never persisted, never sent anywhere, and never treated as an
# identity — it exists only to pick a face.
def _hero_seed(member, project=""):
    haid = (member.get("haid") or "").strip()
    if haid:
        return haid
    handle = str(member.get("user") or member.get("handle") or "").strip().lower()
    if not handle:
        return member.get("sigil") or "?"
    slug = _re_drain.sub(r"[^a-z0-9-]", "", handle) or "x"
    scope = _re_drain.sub(r"[^a-z0-9-]", "", str(project or "wall").lower()) or "wall"
    h4 = hashlib.sha256(("%s@%s" % (slug, scope)).encode()).hexdigest()[:4]
    return "haid:%s.%s-%s" % (slug, scope, h4)


def team_columns(members, team_w, overflow, now, states=True, self_branch=""):
    """Render `members` into the four team-zone row strings — each EXACTLY `team_w` visible
    cells. Rows 1–2: the 4-cell eye_strip_mini (natural palette, eyes visible) riding the
    RIGHT of each 10c column. Row 3: the NAME (hero hue, ≤ TEAM_LABEL_W) right-aligned in the
    same column, plus a trailing `+N` overflow tag. Row 4: the BRANCH (`⎇<branch>`) whenever they have
    a recorded branch — EVERY same-repo teammate surfaces their branch on the line UNDER their
    name, not only cross-branch ones; a teammate with no branch falls back to the state segment
    (blank when `states` is False — the mid tier). Members are joined by a 2-cell gap. Returns
    (r1, r2, r3, r4). `self_branch` is retained for callers but no longer gates the branch line."""
    # The strip and the label are BOTH right-aligned to the column's right edge, each behind
    # its own pad — the strip is narrower than the label, so they need different pads to land
    # on the same edge. Right-alignment is what keeps the name reading as belonging to the
    # face directly above it once the two stopped being the same width.
    lp = " " * (LAYOUT.TEAM_MEMBER_W - LAYOUT.TEAM_STRIP_W)   # 6c pad → strip on the right 4c
    lpl = " " * (LAYOUT.TEAM_MEMBER_W - LAYOUT.TEAM_LABEL_W)  # 2c pad → label on the right 8c
    gap = " " * LAYOUT.TEAM_MEMBER_GAP
    # `members` is ALREADY the visible set — main() slices it to team_zone_alloc's shown_n
    # before calling here — so the labels are resolved against exactly the columns a viewer
    # will see, which is the scope the no-two-columns-alike property is about.
    labels = wall_labels([m.get("user") for m in members], LAYOUT.TEAM_LABEL_W)
    tops = []; bots = []; names = []; sts = []
    for i, m in enumerate(members):
        seed = _hero_seed(m)
        away = _drained(m)
        # An AWAY teammate's sigil is DESATURATED (drained), not tier-swapped to MONO: the
        # identity hue — the thing that reads as "present" — drains out of their column, while
        # the glyph SHAPE still says who they are. Online teammates keep their natural palette
        # (with a real hero, even lacking an enrolled haid — see _hero_seed), so the two never
        # look alike.
        try:
            # Always render the REAL strip, then drain. Rendering it through a colourless
            # tier is what erased the face; desaturating a full-colour render keeps it.
            strip2 = SIG.eye_strip_mini(seed, CAPS)           # 2 text-rows × 4 cells, eyes visible
            if away:
                strip2 = _drain_hue(strip2)
            if len(strip2) < 2:
                raise ValueError
        except Exception:
            blank = " " * LAYOUT.TEAM_STRIP_W
            strip2 = [blank, blank]
        g = gap if i else ""
        tops.append(g + lp + strip2[0])
        bots.append(g + lp + strip2[1])
        # An away teammate's NAME also drops to the faintest hue — never their hero colour,
        # which is the strongest "this person is here" cue on the whole wall.
        hue = None if away else (_team_hue(seed, m.get("sigil")) if USE_COLOR else None)
        ncol = sgr(SIG._hex_rgb(hue)) if hue else (FAINT if away else DIM)
        names.append(g + lpl + f"{ncol}{labels[i]}{X}")
        # Row4: EVERY same-repo teammate with a recorded branch shows it UNDER their name
        # (the branch line) — matching OR differing from self_branch; a teammate with no
        # branch falls back to the state segment. The branch line rides even in the mid tier
        # (states=False) since it is NEW data absent from prior renders.
        mb = str(m.get("branch") or "").strip()
        if away:
            # OFFLINE OUTRANKS EVERYTHING on Row4 — the branch line AND the mid-tier state drop.
            # A stale teammate carries a recorded branch from their last beat, and showing
            # `⎇feature/x` under a name with no offline marker reads as someone working on that
            # branch RIGHT NOW. That is the exact misread this feature exists to prevent, so the
            # away label is the one thing that always survives.
            r4seg = _team_state_seg(m, now)
        elif mb:
            r4seg = _team_branch_seg(mb)
        elif states:
            r4seg = _team_state_seg(m, now)
        else:
            r4seg = None
        if r4seg is not None:
            sts.append(g + lpl + LAYOUT.pad_or_truncate(r4seg, LAYOUT.TEAM_LABEL_W))
        else:
            sts.append(g + " " * (len(lpl) + LAYOUT.TEAM_LABEL_W))
    tag_seg = f"{DIM} +%d{X}" % overflow if overflow > 0 else ""
    r1 = LAYOUT.pad_or_truncate("".join(tops), team_w)         # tag slot stays blank on the sigil rows
    r2 = LAYOUT.pad_or_truncate("".join(bots), team_w)
    r3 = LAYOUT.pad_or_truncate("".join(names) + tag_seg, team_w)
    r4 = LAYOUT.pad_or_truncate("".join(sts), team_w)
    return r1, r2, r3, r4


# Narrow-tier marks — a SHAPE ramp by how much signal we have on the person, descending:
# a filled disc (a live heartbeat), a hollow ring (a heartbeat, but stale), a dotted ring (no
# heartbeat ever, but commits), a speck (on the repo, nothing else). At this width there is no
# room for a word, so the mark's SHAPE carries the whole signal — and only `●` is filled, so
# present-vs-absent reads at a glance even on a mono terminal where every mark is one colour.
TEAM_DOT = {"online": "●", "away": "○", "contributed": "◌", "member": "·"}
TEAM_DOT_CAP = 4       # the narrow tier is 40-59 cols; past this the rail crowds out identity


def team_dots(members, cap=TEAM_DOT_CAP):
    """Narrow-tier inline team indicator (Spec v2 §7): one mark per teammate, space-joined,
    riding the Row1 right rail. A PRESENT teammate's disc is tinted by their identity hue;
    every absent tier is the faintest hue AND a distinct shape, so the distinction survives
    --no-color and a mono terminal.

    Bounded by `cap` with an explicit `+N` tail: 23 people would be 45 cells of dots on a
    40-cell rail, and dropping the remainder silently would re-create the very bug this wall
    fixes. Members arrive rank-ordered (present first), so the `+N` can only ever hide people
    who are NOT here."""
    dots = []
    for m in members[:cap]:
        seed = _hero_seed(m)
        tier = _tier_of(m)
        if tier != WALL.PRESENT_TIER:
            dots.append(f"{FAINT}{TEAM_DOT.get(tier, '·')}{X}")
            continue
        hue = _team_hue(seed, m.get("sigil")) if USE_COLOR else None
        col = sgr(SIG._hex_rgb(hue)) if hue else DIM
        dots.append(f"{col}{TEAM_DOT['online']}{X}")
    rest = len(members) - len(dots)
    if rest > 0:
        dots.append(f"{FAINT}+{rest}{X}")
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


# ── the CONTENT PANEL's width floor (reserved BEFORE the team zone packs) ──────
def _gauge_max_for(tier):
    """The Row2 gauge's tier ceiling — read by BOTH the renderer and panel_floor, so the
    width the panel RESERVES can never drift from the width it later SPENDS."""
    return LAYOUT.GAUGE_MAX_W if tier == "full" else 32


def _bar_w_for(tier):
    """The Row4 micro-gauge bar width per tier (0 → plain text). Same one-source rule: a
    wider bar has to move the reservation with it or the reservation is a lie."""
    return 12 if tier == "full" else (8 if tier == "mid" else 0)


def panel_floor(tier, data, now, gates, session_id, dur_ms):
    """The cells the CONTENT PANEL needs at `tier` to render its rows WHOLE — MEASURED off
    the very builders that render them, never a constant, so a change to a bar, a label or a
    gate segment moves this number with it instead of silently under-reserving.

    The rows are STACKED, so the floor is the WIDEST of them, not their sum:
      Row2  the context gauge at its tier ceiling (40c full / 32c mid);
      Row4  micro_row at its natural width — `avail=None` asks it what it WANTS, which is
            the two bars, their labels, the ` · ` separator and any `·5h` reset suffix;
      Row3  gate_labels at its RICHEST level (mark + id + detail), FULL TIER ONLY, because
            mid's documented contract is that the gate details are the first thing to drop.
    Row1 is excluded on purpose: it already degrades by WHOLE SEGMENTS (row1_left drops
    `· Opus 4.8`, then the repo) and so has no width it must have.

    main() hands this to team_zone_alloc as `content_floor`, which reserves it before the
    team packs. Without it the team took the right edge first, and a NINE-teammate wall on a
    200-col terminal left the panel 36c — less than the 44c its own bars need — so Row4
    self-downgraded to plain text on the widest terminal in the room. The panel is the
    fixed-cost anchor; the wall is the elastic one, and it folds whole members into `+N`."""
    want = max(_gauge_max_for(tier),
               vis(micro_row(data, now, _bar_w_for(tier), session_id, dur_ms, avail=None)))
    if tier == "full":
        want = max(want, vis(gate_labels(gates, None, colored=True)))
    return want


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

    persist_rate_limits(data, float(os.environ.get("HMD_NOW") or time.time()))

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
    ledger = LEDGER.read_status(session_id, repo=cwd)
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
    members, overflow = _team_members(cwd, ledger, _wall_self_ids(handle, seed))
    roster = list(members)                               # kept for the narrow-tier dots
    team_states = True
    if tier == "mid":
        if len(members) > 2:
            overflow += len(members) - 2
            members = members[:2]
        team_states = False                              # §7 mid: states drop (name only)

    inner = cols - 9                                     # everything right of the 9c sigil zone
    # team_zone_alloc sizes the team zone + caps members so the PANEL keeps its floor; we take
    # its rows-zone width as the CONTENT BUDGET (build the rows at their richest that fits).
    # The team is then placed FLUSH RIGHT, against the right edge of CC's paint region, with
    # every unspent cell absorbed as gutter BETWEEN the panel and the first member (see the
    # `team_gap` derivation below). TEAM_COL_GAP is therefore the MINIMUM gutter, not the gutter.
    if tier in ("full", "mid") and members:
        # reserve the SAME TEAM_COL_GAP gutter the compose step renders, so content_budget is
        # the exact col1 ceiling — col1_w + gap + team_w <= inner, never a hard-clamp `…` clip.
        # content_floor is the PANEL's measured need (panel_floor), reserved BEFORE the team
        # packs: the panel is the fixed-cost anchor, the wall is elastic and folds whole
        # members into `+N`. Reserving only the gauge minimum here is what let nine teammates
        # squeeze a 200-col panel down to 36c and turn its Row4 bars into plain text.
        content_budget, team_w, shown_n, of, _alloc_gap = LAYOUT.team_zone_alloc(
            cols, len(members), overflow, rows_gap=TEAM_COL_GAP,
            content_floor=panel_floor(tier, data, t, gates, session_id, dur_ms))
        members = members[:shown_n]
        team_gap = TEAM_COL_GAP
    else:
        content_budget, team_w, of, team_gap = inner, 0, overflow, 0

    # the gauge is the ONLY flexible element in the rows zone: 40c full / 32c mid, min 24.
    gauge_w = max(0, min(_gauge_max_for(tier), content_budget))

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
    # DISPLAY ONLY. `handle` stays the identity everything else is keyed on — the presence
    # beat published to teammates and the self-exclusion that keeps the owner off his own
    # wall — because those match on what the ledger and the roster already know him as.
    # Row1 is the one place a human is being INTRODUCED, so it is the one place that spends
    # a lookup on the name that human answers to in public.
    left1 = row1_left(_github_handle(cwd, handle), model, repo_seg, cseg, avail1)

    # ── Row2 — the context gauge (CTX%·↓tokens on the fill, $cost on the track end) ──
    # narrow → bar-only (labels off). render_gauge splices the labels inside the bar's cell
    # array, preserving each cell's bg ramp, and gates them by bar width internally.
    gauge = GAUGE.render_gauge(gauge_w, pct, tin, cost, CAPS, base_hue=sig_hue,
                               labels=(tier != "narrow"))

    # ── Row3 — the gate labels `✓ <id> <detail> · …` (ledger missing → `– gates offline`) ──
    row3_zone = gate_labels(gates, content_budget, colored=True)

    # ── Row4 — the 5h + 7d limit micro-gauges (session stats when rate_limits is absent) ──
    row4_zone = micro_row(data, t, _bar_w_for(tier), session_id, dur_ms, avail=content_budget)

    # ── COMPACT column-1: shrink the content column to the NATURAL width of its widest row.
    # col1_w is >= every row's natural width (no new truncation) and <= the content budget.
    # Solo (team_w==0) keeps the full inner width so the watchman rail stays right-anchored. ──
    if team_w > 0:
        nat1 = vis(left1) + (1 + vis(right1) if right1 else 0)
        col1_w = min(content_budget,
                     max(nat1, gauge_w, vis(row3_zone), vis(row4_zone)))
        col1_w = max(1, col1_w)
        # FLUSH RIGHT: every cell col1 did not need becomes GUTTER, so the wall lands hard
        # against the right edge instead of trailing off into filler blanks. The slack has to
        # go somewhere; putting it BEFORE the first member keeps the wall a wall — a column
        # a reader's eye finds in the same place on every terminal — whereas putting it after
        # (the old left-pack) left nine members adrift mid-screen at 200 cols.
        #
        # This reverses the earlier left-pack, and the reason it is now safe is CC_REGION_RESERVE.
        # Left-packing was a SECOND mitigation for RJ's right-edge truncation, added when the
        # renderer still targeted raw $COLUMNS and CC hard-clipped the 4 cells it reserves for
        # its own spacing. resolve_cols() now measures that region and renders INSIDE it, so
        # "flush right" is flush against CC's real paint region, not against a right edge that
        # was never ours. Keeping both mitigations cost the layout its right anchor for nothing.
        #
        # The panel is untouched: col1_w and content_budget are exactly what they were, so this
        # can only ever GROW the gutter (>= TEAM_COL_GAP, since col1_w <= content_budget and
        # content_budget + team_w + TEAM_COL_GAP == inner). The panel never gives up a cell.
        team_gap = max(TEAM_COL_GAP, inner - col1_w - team_w)
    else:
        col1_w = content_budget

    row1_zone = LAYOUT.left_right(left1, right1, col1_w)

    def compose(zone, col):
        """content column (padded to col1_w) + the `team_gap` gutter + the team column. Solo
        → just the padded content column. With a team the three sum to EXACTLY `inner`, so the
        team lands on the right edge and the caller's clamp has no trailing blanks to add."""
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

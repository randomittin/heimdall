#!/usr/bin/env python3
"""hmd-ui.py -- the `hmd ui` companion server (PLAN-companion-ui.md, Wave 1).

A loopback-only, stdlib-only HTTP server that renders hmd's ALREADY-WRITTEN local
state in a browser. It is a READER over existing plumbing -- the same posture
bin/lib/watch_data.py states for `hmd watch`: it never re-implements a gate, a
verdict, or a roster parse. Every field it serves traces to one of the sources in
SOURCE_FILES / SOURCE_COMMANDS below, and `--print-sources` prints that list so a
tester can assert the deny-list against it.

Routes (all GET):
    /                 the single static page (sentinels/hmd-ui.html)
    /api/state        the section-4 JSON contract, served from the SAME background-
                      polled StateCache snapshot /api/events reads (perf: a GET is a
                      dict->JSON serialize, not a fresh collect -- the cache recomputes
                      itself at least every POLL_INTERVAL_S, or synchronously on demand
                      if empty/stale; see StateCache.latest()). `?digest=<sha>` (or an
                      `If-None-Match: "<sha>"` header) matching the current digest gets
                      a bodyless 304 with `ETag: "<sha>"`; otherwise 200 with that same
                      ETag -- the identical digest_of() value an /api/events frame's
                      `id:` line carries, so a client can share one digest between both
                      routes. (+ Wave 4's additive `panels` array: .heimdall/ui/panels/<id>.json
                      through bin/lib/companion_ui_panels.read_panels -- validated,
                      secret-scrubbed, capped, `stale`-flagged, TTL-reaped). The whole
                      body is then scrubbed per the TRANSPORT carrying it
                      (`_transport_redaction` -- never anything a request says):
                      loopback is unredacted; with transport.public_host set
                      (--allow-host) every absolute path token becomes its basename;
                      over the E2E relay (bin/heimdall-relay-client builds a transport
                      with bind "relay" in-process, the leg is sealed) a path token below
                      the repo root keeps its repo-relative part ("src/app/x.ts") and
                      the rest is still reduced. Email-shaped substrings become
                      "[email]" on every redacting profile. `edits.count` is the number
                      of UNIQUE edited paths (not edit events); `edits.paths` is
                      repo-relative inside the repo, absolute outside it
    /api/events       text/event-stream; a `data:` frame only when the digest changes
                      (the digest covers `panels`, so a `hmd ui panel set` lands within
                      one poll)

Auth, in this order, on EVERY route:
    0. Host header must be 127.0.0.1:<port>, localhost:<port>, or one of --allow-host's
       names (bare, or with ANY numeric port, e.g. ":443"/":8443"/":10000" --
       case-insensitive, no wildcard/suffix matching on the hostname)  -> else 403
       (DNS-rebinding defence: a page on evil.example resolving to 127.0.0.1 still
       sends Host: evil.example, and is refused before the token is even looked at)
    1. per-launch token (`?token=` query or X-Heimdall-UI-Token header), compared with
       hmac.compare_digest                                          -> else 401
    2. per-IP backoff, but ONLY on the failure path above: 5 auth failures (401 w/ a
       presented-but-wrong token, or any 403) from one client IP within a rolling 60s
       window -> 429 + Retry-After for 30s. A request presenting the CORRECT token on
       an allowed Host is NEVER denied by backoff -- lockout exists to slow a guesser,
       not to lock out the legitimate phone behind a shared carrier NAT, a spoofed
       X-Forwarded-For, or (--trust-proxy off, behind a real proxy) the single peer
       address every request shares. A successful auth resets the count.

--allow-host <name> (repeatable) extends the Host allowlist for a reverse proxy (e.g.
a Tailscale Funnel hostname); the bind stays 127.0.0.1 regardless. --trust-proxy makes
per-IP accounting (backoff, /api/state.transport) use X-Forwarded-For's LAST value --
the one appended by the single trusted hop itself, never a client-supplied earlier
hop -- instead of the socket peer; only meaningful behind a proxy that sets it, so it
is opt-in and ignored entirely when the flag is absent.

Never read, in any form: .heimdall/team.json, *.key/*.pem/*.seed, ~/.omniroute/*,
.env*, settings.json env blocks, hooks-disabled contents. `_read_text` refuses a
denied path even if a future caller asks for one -- the deny-list is enforced at
the one read primitive, not by convention.

Fail-open everywhere except auth: a missing or malformed source yields null for
its field; the server never crashes on a read. Every subprocess is bounded.
"""
import argparse
import hashlib
import hmac
import importlib.util
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import threading
import time
import webbrowser
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
BIN_DIR = os.path.normpath(os.path.join(HERE, "..", "bin"))
LIB_DIR = os.path.join(BIN_DIR, "lib")
PAGE_PATH = os.path.join(HERE, "hmd-ui.html")

SCHEMA_VERSION = 1
POLL_INTERVAL_S = 2.0
KEEPALIVE_S = 15.0
CMD_TIMEOUT_S = 8
CHECKPOINT_HEAD_BYTES = 8192   # the auto-checkpoint header lives in the first few KB
REELS_LIMIT = 20
MAX_SEND_BODY_BYTES = 4096     # POST /api/send request body cap (413 above this)
BACKOFF_MAX_FAILURES = 5       # auth failures from one IP inside the window trips a lockout
BACKOFF_WINDOW_S = 60.0        # rolling window the failures must fall inside
BACKOFF_LOCKOUT_S = 30.0       # lockout duration once tripped
BACKOFF_CAP = 4096             # max tracked IPs; a live lockout is never evicted to make room (A7)
HEADER_READ_TIMEOUT_S = 10.0   # A2: UIHandler.timeout -- bounds the pre-auth header read
                                # (slow-loris defence); cleared once a request is confirmed
                                # to be a long-lived /api/events stream
MAX_CONNECTIONS = 64           # A2: hard cap on concurrent connections/threads, server-wide
MAX_SSE_STREAMS = 8            # A2: lower cap on live /api/events streams specifically
SSE_RETRY_AFTER_S = 5          # A2: Retry-After seconds on the 503 an over-cap SSE request gets

# ── sources: the complete list of what this process reads ────────────────────
# Relative to the target repo root. `--print-sources` prints exactly these (made
# absolute) plus the commands below -- nothing else is opened by this server.
SOURCE_FILES = (
    ".heimdall/statusline.json",          # via hmd_ledger.read_status (legacy tier)
    ".heimdall/.roster-cache.json",       # roster rows (watch_data.read_roster + raw fallback)
    ".heimdall/roster-cache.json",        # the path watch_data.read_roster itself opens
    ".heimdall/receipts/last-sweep.json", # full-sweep receipt
    ".planning/CHECKPOINT.md",            # header fields only, first 8 KB
    ".planning/reels/",                   # directory listing: name + mtime only
    ".planning/metrics.jsonl",            # last graded parallelism row (tail only)
    ".heimdall/ui/panels/",               # job panels: <id>.json via companion_ui_panels.read_panels
    ".heimdall/ui/inbox.jsonl",           # undelivered companion messages: companion_ui_inbox.list_pending
    ".heimdall/.agents-count-cache",      # live-subagent count (one integer), read only after a turn ends
)
# Under $TMPDIR: parallelism-tracker's live per-session counters (key=value text).
# READ ONLY. `parallelism-tracker grade` is deliberately NOT called: it is the
# SessionEnd action -- it appends a metrics.jsonl row and unlinks the session state,
# so polling it every 2s would wipe the counters the real SessionEnd grade reads.
SOURCE_TMP_FILES = (
    "heimdall-parallel/<session>.state",
)
# Outside the repo: hmd_ledger's per-repo mirror under $HEIMDALL_HOME/ledger/.
SOURCE_HOME_FILES = (
    "ledger/repos/<repo_key>.json",
    "ledger/status.json",
)
# Under ${CLAUDE_CONFIG_DIR:-~/.claude}: the repo's own session transcript, for the `attention`
# slice. READ ONLY and TAIL ONLY (bin/lib/companion_ui_attention.py): never the whole file, and
# never anything else in that directory -- settings.json stays deny-listed and unopened.
SOURCE_CLAUDE_FILES = (
    "projects/<slug>/<session>.jsonl",
)
SOURCE_COMMANDS = (
    ("heimdall-hooks", "list", "--json"),
    ("edit-tracker", "paths"),
    ("heimdall-state", "check-quality-gates"),
    ("heimdall-fallback", "status", "--json"),
    ("heimdall-identity", "--json"),
    ("heimdall-haid", "current"),
    ("heimdall-agents", "list", "--json"),   # A3: the `agents` panel (throttled; see companion_ui_publish)
)
GIT_COMMANDS = (
    ("git", "rev-parse", "--abbrev-ref", "HEAD"),
)

# ── deny-list: enforced at the read primitive ────────────────────────────────
DENY_BASENAMES = frozenset({
    "team.json", "settings.json", "settings.local.json", "hooks-disabled",
    ".team-gh-auto-stamp", "team-auto.log", "fallback.json", "cp-endpoint.json",
})
DENY_SUFFIXES = (".key", ".pem", ".seed")
DENY_PREFIXES = (".env",)
DENY_DIR_PARTS = frozenset({".omniroute", "pki", "signing", "gh-app"})
# Keys that must never be forwarded even when a permitted source carries them.
FALLBACK_ALLOWED_KEYS = ("state", "target_provider")


def path_is_denied(path):
    """True when `path` matches the never-read list. Checked on every component so a
    denied directory (~/.heimdall/pki/) denies everything under it."""
    norm = os.path.normpath(os.path.expanduser(str(path)))
    parts = norm.split(os.sep)
    base = parts[-1] if parts else ""
    if base in DENY_BASENAMES:
        return True
    if base.endswith(DENY_SUFFIXES):
        return True
    if base.startswith(DENY_PREFIXES):
        return True
    return any(p in DENY_DIR_PARTS for p in parts[:-1])


def _read_text(path, limit=None):
    """The ONE file-read primitive. Returns text or None; refuses denied paths."""
    if path_is_denied(path):
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit) if limit else f.read()
    except (OSError, ValueError):
        return None


def _read_json(path):
    text = _read_text(path)
    if text is None:
        return None
    try:
        return json.loads(text)
    except ValueError:
        return None


def _load_module(name, path):
    """Import a sibling module by path (the sentinels/ convention, see hmd-statusline.py)."""
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


WATCH_DATA = _load_module("watch_data", os.path.join(LIB_DIR, "watch_data.py"))
LEDGER = _load_module("hmd_ledger", os.path.join(HERE, "hmd_ledger.py"))
# Wave 4: the ONE place the job-panel contract lives (type set, caps, scrub, atomic
# write). The `hmd ui panel` CLI imports the same module, so writer and reader agree.
PANELS = _load_module("companion_ui_panels", os.path.join(LIB_DIR, "companion_ui_panels.py"))
# The write path's ONE place the message contract lives (validation, caps, secret
# scrub, atomic append). sentinels/hmd-ui.py's POST handler and `hmd ui inbox` both
# import it, so writer and reader agree -- mirrors PANELS immediately above.
INBOX = _load_module("companion_ui_inbox", os.path.join(LIB_DIR, "companion_ui_inbox.py"))
# The ONE place the session-code derivation lives (deterministic sha256-based 5-char
# code, stdlib only) -- sentinels/hmd-statusline.py's `_session_code()` loads this exact
# same file, so the code shown here in identity.session_code and the code shown on the
# statusline can never disagree.
SESSION_CODE = _load_module("hmd_session_code", os.path.join(LIB_DIR, "hmd_session_code.py"))
# The ONE place the `attention` derivation lives (A1, docs/HANDOFF-TO-HEIMDALL-product-asks.md):
# the newest main-chain entries of the repo's session transcript -> {state,id,since,kind,summary,
# options,turn}. Tail-only, stat-cached; see the module docstring.
ATTENTION = _load_module("companion_ui_attention", os.path.join(LIB_DIR, "companion_ui_attention.py"))

LIVE_USERS_PANEL_ID = "hmd-live-users"
LIVE_USERS_REFRESH_S = 2
# Republish the self-panel when its value changes or its age nears the stale
# threshold (max(2*3, 30) = 30s) -- never every tick, or the digest would change
# every 2s and the SSE stream could never be quiet.
LIVE_USERS_REWRITE_AFTER_S = 15.0


def _run(argv, cwd, timeout=CMD_TIMEOUT_S, env=None):
    """Bounded subprocess: (returncode, stdout, stderr) or (None, '', '') on any fault.
    The first argv element is resolved against hmd's own bin/ so the target repo's
    PATH never decides which hmd tool answers. `env`, when given, overlays a copy of
    this process's own environment (never replaces it outright) -- e.g. collect_fallback
    tightens HEIMDALL_FALLBACK_PROBE_TIMEOUT so heimdall-fallback's own network probe
    finishes with room to spare inside this call's own `timeout`, rather than leaning on
    the kill below to cut off a probe that may have been about to answer anyway."""
    exe = argv[0]
    if exe != "git":
        exe = os.path.join(BIN_DIR, exe)
        if not os.access(exe, os.X_OK):
            return None, "", ""
    child_env = os.environ.copy()
    if env:
        child_env.update(env)
    try:
        p = subprocess.run(
            [exe] + list(argv[1:]), cwd=cwd, capture_output=True, text=True,
            timeout=timeout, stdin=subprocess.DEVNULL, env=child_env,
        )
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.SubprocessError, ValueError):
        return None, "", ""


def _run_json(argv, cwd):
    rc, out, _ = _run(argv, cwd)
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


# perf (HANDOFF-TO-HEIMDALL-2026-09-21.md item 1): /api/state measured 1.5-3.0s per
# request on loopback. Reproduced locally with HMD_UI_PROFILE=1 -- collect_fallback
# ~310ms, collect_hooks ~290ms, collect_identity ~255ms, collect_quality_gate ~10ms,
# every other collector sub-millisecond: seven subprocess spawns per collect_state()
# call account for nearly all of it. _run_cached/_run_json_cached memoize by the
# exact (argv, cwd) pair for SUBPROCESS_CACHE_TTL_S (one poll interval), so a burst
# of GETs -- or a GET landing next to the poller's own tick -- never spawns the same
# command twice within it; no caller ends up with an answer staler than the
# un-cached code already tolerated (StateCache only refreshed once per tick anyway).
SUBPROCESS_CACHE_TTL_S = POLL_INTERVAL_S
_subprocess_cache = {}
_subprocess_cache_lock = threading.Lock()


def _run_cached(argv, cwd, timeout=CMD_TIMEOUT_S, env=None):
    """Same contract as `_run`, memoized by the exact (argv, cwd) pair for
    SUBPROCESS_CACHE_TTL_S. The lock spans the whole miss path (not just the dict
    read/write): two concurrent /api/state requests racing a cold cache must never
    both spawn the same command -- the second blocks on the lock and then hits the
    now-warm entry instead of racing its own subprocess (perf item 2d: never spawn
    `git` more than once per poll interval, even under concurrent load). `timeout`/
    `env` are forwarded to `_run` -- the cache key stays (argv, cwd) only, since every
    caller always pairs the same argv+cwd with the same timeout/env."""
    key = (tuple(argv), cwd)
    with _subprocess_cache_lock:
        now = time.monotonic()
        hit = _subprocess_cache.get(key)
        if hit is not None and now - hit[0] < SUBPROCESS_CACHE_TTL_S:
            return hit[1]
        result = _run(argv, cwd, timeout=timeout, env=env)
        _subprocess_cache[key] = (time.monotonic(), result)
        return result


def _run_json_cached(argv, cwd, timeout=CMD_TIMEOUT_S, env=None):
    rc, out, _ = _run_cached(argv, cwd, timeout=timeout, env=env)
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def _first_line(text):
    for line in (text or "").splitlines():
        s = line.strip()
        if s:
            return s
    return ""


# ── per-field collectors (each returns its contract slice, or None) ──────────
def collect_session_code(root):
    """identity.session_code -- the same 5-char code the companion app shows for this
    paired session (bin/lib/hmd_session_code.py, the one source both this file and
    sentinels/hmd-statusline.py read). `hmd app connect` pairs ONE `hmd ui` instance
    per repo (.planning/plans/PLAN-hmd-app-connect.md; its state file
    <repo>/.heimdall/app/connect.json is repo-keyed, not per-Claude-session), so this
    is REPO-scoped here -- the live Claude Code session_id, when this process happens
    to have inherited one (CLAUDE_SESSION_ID/SESSION_ID, the same env precedence
    `_tracker_state_path()` elsewhere in this file already uses), wins when present;
    otherwise `root` is the input. Never raises."""
    if SESSION_CODE is None:
        return None
    sid = os.environ.get("CLAUDE_SESSION_ID") or os.environ.get("SESSION_ID")
    try:
        code, _source = SESSION_CODE.session_code_for(session_id=sid or None, repo=root)
    except Exception:
        return None
    return code if isinstance(code, str) and code else None


def collect_identity(root):
    ident = _run_json_cached(("heimdall-identity", "--json"), root)
    handle = ident.get("handle") if isinstance(ident, dict) else None
    rc, out, _ = _run_cached(("heimdall-haid", "current"), root)
    haid = _first_line(out) if rc == 0 else None
    rc, out, _ = _run_cached(("git", "rev-parse", "--abbrev-ref", "HEAD"), root, timeout=3)
    branch = _first_line(out) if rc == 0 else None
    return {"handle": handle or None, "haid": haid or None, "branch": branch or None,
            "session_code": collect_session_code(root)}


LEDGER_EMPTY = {"daemon": None, "gates": [], "verdict": None, "team": [], "team_overflow": 0}


def collect_ledger(root):
    if LEDGER is None:
        return dict(LEDGER_EMPTY)
    # Session id keyed by ROOT: hmd_ledger's 5s file cache is per session id, and two
    # `hmd ui` instances on different repos must never serve each other's ledger.
    sid = "hmd-ui-" + hashlib.sha256(root.encode("utf-8")).hexdigest()[:12]
    try:
        st = LEDGER.read_status(sid, repo=root)
    except Exception:
        return dict(LEDGER_EMPTY)
    if not isinstance(st, dict):
        return dict(LEDGER_EMPTY)
    return {
        "daemon": st.get("daemon", "down"),
        "gates": list(st.get("gates") or []),
        "verdict": st.get("verdict"),
        "team": list(st.get("team") or []),
        "team_overflow": int(st.get("team_overflow") or 0),
    }


ROSTER_KEYS = ("haid", "handle", "branch", "project", "state", "verdict", "online", "age_seconds")


def collect_roster(root):
    rows = []
    if WATCH_DATA is not None:
        try:
            rows, _payload = WATCH_DATA.read_roster(root)
        except Exception:
            rows = []
    if not rows:
        # watch_data opens `roster-cache.json`; the live cache heimdall-presence writes is
        # the dot-prefixed sibling. Same payload shapes, same normalisation.
        raw = _read_json(os.path.join(root, ".heimdall", ".roster-cache.json"))
        if isinstance(raw, list):
            rows = raw
        elif isinstance(raw, dict):
            rows = raw.get("members") or raw.get("roster") or []
    out = []
    for r in rows:
        if isinstance(r, dict):
            out.append({k: r.get(k) for k in ROSTER_KEYS})
    return out


def collect_quality_gate(root):
    rc, out, err = _run_cached(("heimdall-state", "check-quality-gates"), root)
    if rc is None:
        return {"clear_to_push": None, "reason": None}
    text = (out or "") + "\n" + (err or "")
    reason = ""
    for line in text.splitlines():
        if line.strip().startswith("GATE FAILED"):
            reason = line.strip()
            break
    if not reason:
        reason = _first_line(text)
    return {"clear_to_push": rc == 0, "reason": reason}


RECEIPT_KEYS = ("finished_at", "head_sha", "tree_clean", "suites_total",
                "suites_passed", "suites_failed", "duration_s")


def collect_sweep_receipt(root):
    data = _read_json(os.path.join(root, ".heimdall", "receipts", "last-sweep.json"))
    if not isinstance(data, dict):
        return None
    return {k: data.get(k) for k in RECEIPT_KEYS}


HOOK_KEYS = ("id", "event", "locked", "enabled", "description")


def collect_hooks(root):
    data = _run_json_cached(("heimdall-hooks", "list", "--json"), root)
    if not isinstance(data, list):
        return []
    return [{k: h.get(k) for k in HOOK_KEYS} for h in data if isinstance(h, dict)]


# heimdall-fallback status is the one SOURCE_COMMANDS entry that can make a REAL
# network syscall: run_preflight() (bin/heimdall-fallback) sends an actual loopback
# HTTP GET via _endpoint_reachable() on every single invocation, regardless of
# fallback state (even the default state=="off"). Every other collector in this file
# is a file read or a fast, local-only subprocess. Under contention -- several hmd-ui
# processes each polling every POLL_INTERVAL_S, all probing the same loopback port
# concurrently (test/heimdall-ui-allowhost.test.sh alone launches six) -- sharing the
# generic CMD_TIMEOUT_S here compounds badly: a slow or wedged local endpoint can
# legitimately cost the full shared timeout on EVERY poll tick of EVERY running
# server, indistinguishable from a hang under a loaded parallel test sweep. So this
# one collector gets its own tighter bound instead of the shared default.
FALLBACK_CMD_TIMEOUT_S = 2.0
# heimdall-fallback's own probe already has a bounded timeout (_probe_timeout(),
# default 3.0s -- already longer than FALLBACK_CMD_TIMEOUT_S above), so tighten it
# here too, UNLESS the caller already pinned an explicit value of its own -- never
# override an explicit choice. This way a slow-but-honest probe answer normally
# beats FALLBACK_CMD_TIMEOUT_S's own kill, instead of every close call being decided
# by a hard SIGKILL that throws away whatever heimdall-fallback was about to report.
FALLBACK_PROBE_TIMEOUT_S = "1"


def collect_fallback(root):
    env = None
    if not os.environ.get("HEIMDALL_FALLBACK_PROBE_TIMEOUT"):
        env = {"HEIMDALL_FALLBACK_PROBE_TIMEOUT": FALLBACK_PROBE_TIMEOUT_S}
    data = _run_json_cached(
        ("heimdall-fallback", "status", "--json"), root,
        timeout=FALLBACK_CMD_TIMEOUT_S, env=env,
    )
    if not isinstance(data, dict):
        # Hard-timeout (or any other subprocess failure) degrade: keep the
        # existing state/target_provider keys (null) for back-compat, and add
        # status/reason so a caller can tell "off" apart from "we couldn't
        # ask in time" instead of inferring it from two identical nulls.
        result = {k: None for k in FALLBACK_ALLOWED_KEYS}
        result["status"] = "unknown"
        result["reason"] = "timeout"
        return result
    # Decision 4: never forward endpoint / operator_key_* / config_path.
    return {k: data.get(k) for k in FALLBACK_ALLOWED_KEYS}


PARALLELISM_KEYS = ("batched", "turns", "ratio", "calls", "agent_calls", "agent_batched")
METRICS_TAIL_BYTES = 65536


def parallelism_empty():
    out = {k: None for k in PARALLELISM_KEYS}
    out["source"] = None
    return out


def _parallelism_shape(batched, turns, calls, agent_calls, agent_batched, source):
    ratio = round(batched / turns, 2) if turns else 0.0
    return {"batched": batched, "turns": turns, "ratio": ratio, "calls": calls,
            "agent_calls": agent_calls, "agent_batched": agent_batched, "source": source}


def _tracker_state_dir():
    tmp = os.environ.get("TMPDIR") or "/tmp"
    return os.path.join(tmp, "heimdall-parallel")


def _tracker_state_path():
    """The live counters file parallelism-tracker maintains (state_path() in
    bin/parallelism-tracker.c). With no session id in our env, the most recently
    touched session's file is the one the operator is looking at."""
    sid = os.environ.get("CLAUDE_SESSION_ID") or os.environ.get("SESSION_ID")
    d = _tracker_state_dir()
    if sid:
        return os.path.join(d, sid + ".state")
    try:
        cands = [os.path.join(d, n) for n in os.listdir(d) if n.endswith(".state")]
        return max(cands, key=os.path.getmtime) if cands else None
    except (OSError, ValueError):
        return None


def parse_tracker_state(text):
    """`key=value` lines, exactly what write_state_atomic() emits. Unknown keys ignored."""
    vals = {}
    for line in (text or "").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        try:
            vals[k.strip()] = int(v.strip())
        except ValueError:
            continue
    if "total_turns" not in vals or "calls" not in vals:
        return None
    if vals.get("calls", 0) == 0:
        return None
    return _parallelism_shape(vals.get("batch_turns", 0), vals["total_turns"], vals["calls"],
                              vals.get("agent_calls", 0), vals.get("agent_batched", 0), "live")


def parse_metrics_tail(text):
    """The LAST `metric: parallelism` row of .planning/metrics.jsonl -- the most recent
    graded session, used when no live counters exist."""
    for line in reversed((text or "").splitlines()):
        line = line.strip()
        if not line or '"parallelism"' not in line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("metric") == "parallelism":
            try:
                return _parallelism_shape(int(row.get("batch_turns", 0)), int(row.get("total_turns", 0)),
                                          int(row.get("total_calls", 0)), int(row.get("agent_calls", 0)),
                                          int(row.get("agent_batched", 0)), "last_graded")
            except (TypeError, ValueError):
                return None
    return None


def _read_tail(path, nbytes):
    if path_is_denied(path):
        return None
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - nbytes))
            return f.read().decode("utf-8", errors="replace")
    except (OSError, ValueError):
        return None


_file_cache = {}
_file_cache_lock = threading.Lock()


def _cached_by_mtime(path, compute):
    """Memoize compute() (a parse) by path's (mtime_ns, size) -- perf: e.g.
    collect_parallelism's metrics.jsonl tail-parse only re-runs when the file
    actually changed, not on every poll tick or GET. Lock spans the compute step
    too, so concurrent callers racing an unchanged path never both re-parse it."""
    try:
        st = os.stat(path)
        stamp = (st.st_mtime_ns, st.st_size)
    except OSError:
        stamp = None
    with _file_cache_lock:
        hit = _file_cache.get(path)
        if hit is not None and hit[0] == stamp:
            return hit[1]
        result = compute()
        _file_cache[path] = (stamp, result)
        return result


def collect_parallelism(root):
    spath = _tracker_state_path()
    live = parse_tracker_state(_read_text(spath)) if spath else None
    if live:
        return live
    mpath = os.path.join(root, ".planning", "metrics.jsonl")
    graded = _cached_by_mtime(mpath, lambda: parse_metrics_tail(_read_tail(mpath, METRICS_TAIL_BYTES)))
    return graded if graded else parallelism_empty()


def collect_edits(root):
    rc, out, _ = _run_cached(("edit-tracker", "paths"), root)
    if rc is None:
        return None
    paths = []
    for line in (out or "").splitlines():
        p = line.strip()
        if not p:
            continue
        try:
            rel = os.path.relpath(p, root)
        except ValueError:
            rel = p
        paths.append(p if rel.startswith("..") else rel)
    return {"count": len(paths), "paths": paths}


_CKPT_FIELD_RE = re.compile(r"^-\s+\*\*(Branch|HEAD|Phase|Uncommitted files|Open warnings):\*\*\s*(.*)$")


def parse_checkpoint_header(text):
    """The five mechanically-written fields of the auto-checkpoint block -- never the
    free-text body. Only lines matching `- **<Field>:** value` for exactly those
    field names are consumed; every other line in the block (In progress, Refuted
    claims, the worktree ledger ...) is skipped unread. Scanning ends at the block's
    `:end` marker. `Open warnings` sits under the first `###` sub-heading in the real
    writer's output, which is why the scan is field-keyed rather than heading-bounded."""
    if not text or "heimdall-auto-checkpoint:begin" not in text:
        return None
    fields = {}
    started = False
    for line in text.splitlines():
        if "heimdall-auto-checkpoint:begin" in line:
            started = True
            continue
        if not started:
            continue
        if "heimdall-auto-checkpoint:end" in line:
            break
        m = _CKPT_FIELD_RE.match(line.strip())
        if m and m.group(1) not in fields:
            fields[m.group(1)] = m.group(2).strip()
    if not fields:
        return None
    unc = fields.get("Uncommitted files", "")
    m = re.match(r"\d+", unc)
    warnings = fields.get("Open warnings", "")
    return {
        "branch": fields.get("Branch") or None,
        "head": fields.get("HEAD") or None,
        "phase": fields.get("Phase") or None,
        "uncommitted_files": int(m.group(0)) if m else None,
        "push_gate_open_warning": warnings if "push gate" in warnings.lower() else None,
    }


def collect_checkpoint(root):
    text = _read_text(os.path.join(root, ".planning", "CHECKPOINT.md"), limit=CHECKPOINT_HEAD_BYTES)
    return parse_checkpoint_header(text)


def collect_reels(root):
    d = os.path.join(root, ".planning", "reels")
    try:
        names = os.listdir(d)
    except OSError:
        return []
    out = []
    for n in names:
        if n.startswith("."):
            continue
        try:
            out.append({"name": n, "mtime": os.stat(os.path.join(d, n)).st_mtime})
        except OSError:
            continue
    out.sort(key=lambda r: r["mtime"], reverse=True)
    return out[:REELS_LIMIT]


def collect_panels(root):
    """Wave 4 addendum: the `panels` array, always via companion_ui_panels.read_panels
    (validated, scrubbed, capped, TTL-reaped) -- never a raw directory listing.
    A missing panels dir, or a missing module, is simply []."""
    if PANELS is None:
        return []
    return PANELS.read_panels(root)


def collect_inbox(root):
    """The `inbox` addendum: {pending, consumer, oldest_age_s, delivered}, always via
    companion_ui_inbox.summary -- never a raw line count of a file the server hasn't
    parsed. `consumer` is who takes the next phone message ("waiting": a stop long-poll
    is live, "tmux": a tmux target is configured, "none": it needs a turn boundary);
    `delivered` is the last 20 receipts as {id, delivered_at} -- never text. A missing
    inbox file, or a missing module, is simply nothing pending and nobody listening."""
    if INBOX is None:
        return {"pending": 0, "consumer": "none", "oldest_age_s": None, "delivered": []}
    return INBOX.summary(root)


def attention_empty():
    """The no-evidence `attention` shape (A1): idle, nothing to point at. Mirrors
    companion_ui_attention.empty(), which is unreachable when that module failed to load."""
    return {"state": "idle", "id": None, "since": None, "kind": None,
            "summary": None, "options": None, "turn": None}


def collect_attention(root, state=None):
    """The `attention` addendum (A1): derived from the repo's session transcript tail and the
    slices collect_state already holds (parallelism.turns, sweep_receipt, checkpoint,
    quality_gate) -- no extra subprocess, no second read of those sources. path_is_denied is
    handed down so the deny-list still guards the one file this reads outside the repo."""
    if ATTENTION is None:
        return attention_empty()
    state = state or {}
    parallelism = state.get("parallelism")
    return ATTENTION.collect(
        root,
        turn=parallelism.get("turns") if isinstance(parallelism, dict) else None,
        sweep_receipt=state.get("sweep_receipt"),
        checkpoint=state.get("checkpoint"),
        quality_gate=state.get("quality_gate"),
        denied=path_is_denied,
    )


def publish_live_users(root, roster_count, previous, now=None):
    """hmd dogfoods the panel publish path: the roster count /api/state already
    computes becomes the `hmd-live-users` number tile, written in-process through
    the exact companion_ui_panels.write_panel an agent's `hmd ui panel set` uses --
    no subprocess, no second read of any presence file, never team.json.
    `previous` is (value, written_at) or None; returns the new tuple, or `previous`
    unchanged when nothing needed rewriting (value same, age under the rewrite bound)."""
    if PANELS is None:
        return previous
    now = time.time() if now is None else now
    if previous is not None and previous[0] == roster_count \
            and now - previous[1] < LIVE_USERS_REWRITE_AFTER_S:
        return previous
    try:
        PANELS.write_panel(root, LIVE_USERS_PANEL_ID, {
            "id": LIVE_USERS_PANEL_ID,
            "title": "hmd — live users",
            "type": "number",
            "data": {"value": int(roster_count), "format": "count"},
            "refresh_s": LIVE_USERS_REFRESH_S,
            "updated_at": now,
        })
    except (OSError, ValueError) as e:
        sys.stderr.write("hmd-ui: could not publish %s: %s\n" % (LIVE_USERS_PANEL_ID, e.__class__.__name__))
        return previous
    return (roster_count, now)


# A3 (HANDOFF-TO-HEIMDALL-product-asks.md): the phone's Chat tab, question sheet and
# Agents tab render the `chat`, `hmd-question` and `agents` panels, whose only
# publishers used to be two scripts wired into the hmdapp repo's own settings. The
# native publishers (bin/lib/companion_ui_publish.py) run in this poller, in the
# same slot as publish_live_users: derived from a bounded tail of the session
# transcript, written through the same write_panel, only when content changed.
# HMD_UI_COMPANION_PANELS=0 switches them off.
COMPANION = _load_module("companion_ui_publish", os.path.join(LIB_DIR, "companion_ui_publish.py"))


AGENTS_LIST_TIMEOUT_S = 6


def new_companion_publisher(root):
    if COMPANION is None or os.environ.get("HMD_UI_COMPANION_PANELS") == "0":
        return None

    def list_agents():
        # The publisher throttles this (>= 10s apart) and skips it while the statusline's
        # cached count says nothing is running; _run_json_cached memoizes within a tick.
        return _run_json_cached(("heimdall-agents", "list", "--json"), root,
                                timeout=AGENTS_LIST_TIMEOUT_S, env={"HMD_AGENT_CWD": root})

    return COMPANION.CompanionPublisher(root, read_tail=_read_tail, list_agents=list_agents)


def publish_companion_panels(publisher):
    """One publish pass of the native panels; True when any panel file changed.
    Never raises: a publisher fault must cost a panel, never the poll loop."""
    if publisher is None:
        return False
    try:
        return bool(publisher.tick())
    except Exception as e:
        sys.stderr.write("hmd-ui: companion panels: %s\n" % e.__class__.__name__)
        return False


_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

# N4: a path TOKEN -- '/' or '~/' at the start of the string or right after
# whitespace (never mid-word, so "a/b" and "http://x" are left alone -- their '/'
# is preceded by a non-space character), running to the next whitespace/quote.
# Matches wherever the token sits in a larger string, so a value that IS nothing
# but a path and a warning message that merely MENTIONS one both lose it.
_ABS_PATH_TOKEN_RE = re.compile(r"""(?<!\S)(?:/|~/)[^\s"']*""")


def _repo_relative(token, root):
    """`token`'s part below `root` -- '/'-separated, never absolute, never climbing
    out -- or None when the token IS `root`, sits outside it, or `root` is '/' (where
    "below the root" would be everything and the whole filesystem layout would leak).
    Purely lexical (`normpath`, no filesystem access): a value whose '..' segments
    escape the repo normalises to something outside it, and a sibling that merely
    shares the root's name as a string prefix ('<root>-evil/z.ts') is not below it."""
    prefix = os.path.normpath(root).rstrip("/") + "/"
    norm = os.path.normpath(os.path.expanduser(token))
    return norm[len(prefix):] if len(prefix) > 1 and norm.startswith(prefix) else None


def _redact_public_token(token, root=None):
    """One matched path token -> what may leave this process: with a `root` (the E2E
    relay profile only) its repo-relative part when it sits below that root, otherwise
    its basename. `os.path.normpath` first so a trailing slash (or an embedded
    '.'/'..' segment) still collapses to a real last-component name instead of the
    empty string `basename()` would otherwise give it; falls back to the original
    token on the rare all-slashes value (e.g. a bare '/') rather than emptying it."""
    if root:
        rel = _repo_relative(token, root)
        if rel:
            return rel
    bn = os.path.basename(os.path.normpath(token))
    return bn if bn else token


def _scrub_public_string(value, root=None):
    """N4: a public-mode string LEAF must carry no email-shaped substring and no
    absolute-or-home path token -- either would hand the operator's identity, a
    `$HOME`-adjacent username, or a private filesystem layout to anyone Tailscale
    Funnel's --allow-host exposes this server to. Non-strings (bool/int/float/
    None) pass through untouched. A leaf transform only -- see `_redact_public`
    for the recursive walk that reaches every leaf in the first place. `root` is
    set only for the E2E relay profile (see `_transport_redaction`): a path token
    below it keeps its repo-relative part instead of collapsing to a basename."""
    if not isinstance(value, str):
        return value
    if _EMAIL_RE.search(value):
        value = _EMAIL_RE.sub("[email]", value)
    if _ABS_PATH_TOKEN_RE.search(value):
        value = _ABS_PATH_TOKEN_RE.sub(lambda m: _redact_public_token(m.group(0), root), value)
    return value


def _redact_public(obj, root=None):
    """N4: the single recursive walk applied to the WHOLE /api/state body in
    public mode -- replacing the old 4-key allowlist (repo/edits.paths/roster/
    ledger.team), which left panels, checkpoint, sweep_receipt, identity.handle
    and every other string-valued field reaching an --allow-host listener
    unscrubbed. Every string leaf at any depth, including inside lists, goes
    through `_scrub_public_string`; dict KEYS and non-string leaves (numbers,
    bools, None) come back exactly as-is -- never scrubbed, never recursed into
    as if they were containers. Rebuilds dicts/lists rather than mutating them in
    place, so a structure another part of the process still holds a reference to
    (e.g. a cached panel dict) is never mutated behind its back. `root` selects the
    E2E relay profile and is threaded unchanged to every leaf."""
    if isinstance(obj, dict):
        return {k: _redact_public(v, root) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_redact_public(v, root) for v in obj]
    return _scrub_public_string(obj, root)


def _redact_state_for_public(state, root=None):
    """A9/N4: called only when `_transport_redaction` says the state leaves this
    machine (transport.public_host set, or the E2E relay). Walks EVERY slice of
    `state` -- repo, edits, roster, ledger, panels, checkpoint, sweep_receipt,
    identity, hooks, fallback, parallelism, quality_gate, reels, inbox, transport
    itself, and whatever the section-4 contract carries next -- so a newly added
    field is covered automatically instead of needing to be remembered here by
    name. Loopback (no --allow-host) never calls this, so its output stays
    byte-for-byte what it was before A9/N4."""
    for key, value in list(state.items()):
        state[key] = _redact_public(value, root)


def _transport_redaction(transport, root):
    """(redact, strip_root): how state must be scrubbed before it leaves this process,
    chosen from the TRANSPORT that carries it and from nothing a request can say -- the
    HTTP server's transport is built from argv alone (see main()) and the relay client
    builds its own in-process (bin/heimdall-relay-client), so no query, header or Host
    value ever reaches this decision.
      loopback (no public_host)  -> (False, None): the owner's own machine, as ever.
      HTTP behind --allow-host   -> (True, None):  the PUBLIC profile -- anyone who can
                                    reach the hostname may read it, so every absolute
                                    path token becomes its basename.
      bind "relay"               -> (True, root):  the E2E RELAY profile -- the leg is
                                    sealed and only the paired phone can open it, so a
                                    path below the repo keeps its repo-relative part
                                    ("src/app/x.ts"); the root itself, anything outside
                                    it and ~/ tokens still reduce to basenames, and
                                    emails are still scrubbed. Never gated on
                                    public_host: state that leaves the machine is
                                    redacted whether or not a friendly name was given."""
    if not transport:
        return False, None
    if transport.get("bind") == "relay":
        return True, root
    return bool(transport.get("public_host")), None


def collect_state(root, transport=None):
    """The section-4 contract. Each slice degrades independently: object-typed
    slices keep their keys with null values, array slices go empty, and the two
    `| null` slices (sweep_receipt, checkpoint) go null -- never an error.

    HMD_UI_PROFILE=1 (env, read fresh on every call so a test can toggle it
    without restarting the server) logs `hmd-ui: profile <collector> <ms>ms` to
    stderr for each collector below -- how this file's perf work
    (test/heimdall-ui-perf.test.sh) was measured. Off by default: one
    os.environ.get() plus a branch per call, no timer ever started."""
    profile = os.environ.get("HMD_UI_PROFILE") == "1"

    def safe(fn, empty=None):
        started = time.monotonic() if profile else None
        try:
            return fn(root)
        except Exception:
            return empty() if callable(empty) else empty
        finally:
            if profile:
                sys.stderr.write("hmd-ui: profile %s %.1fms\n" % (fn.__name__, (time.monotonic() - started) * 1000))
    state = {
        "schema_version": SCHEMA_VERSION,
        "ts": time.time(),
        "repo": root,
        "identity": safe(collect_identity, lambda: {"handle": None, "haid": None, "branch": None, "session_code": None}),
        "ledger": safe(collect_ledger, lambda: dict(LEDGER_EMPTY)),
        "roster": safe(collect_roster, list),
        "quality_gate": safe(collect_quality_gate, lambda: {"clear_to_push": None, "reason": None}),
        "sweep_receipt": safe(collect_sweep_receipt),
        "hooks": safe(collect_hooks, list),
        "fallback": safe(collect_fallback, lambda: {k: None for k in FALLBACK_ALLOWED_KEYS}),
        "parallelism": safe(collect_parallelism, parallelism_empty),
        "checkpoint": safe(collect_checkpoint),
        "reels": safe(collect_reels, list),
        "edits": safe(collect_edits),
        "panels": safe(collect_panels, list),
        "inbox": safe(collect_inbox, lambda: {"pending": 0}),
    }
    # Derived AFTER the slices it reads, so it sees this pass's parallelism/receipt/checkpoint/gate.
    state["attention"] = safe(lambda r: collect_attention(r, state), attention_empty)
    if transport is not None:
        state["transport"] = transport
        redact, strip_root = _transport_redaction(transport, root)
        if redact:
            _redact_state_for_public(state, strip_root)
    return state


def canonical_json(state):
    return json.dumps(state, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def json_for_wire(obj):
    """JSON for the HTTP body / SSE frame with `<`, `>` and `&` written as \\uXXXX
    escapes. Identical value after JSON.parse; but no job-supplied panel string can
    ever put a literal `<script` or `</` byte sequence on the wire, so the served
    bytes are inert even if a consumer other than this page's JSON.parse sees them."""
    return (json.dumps(obj, ensure_ascii=False)
            .replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026"))


def digest_of(state):
    """SHA-256 over the canonical JSON with the wall-clock `ts` removed -- otherwise
    every poll would differ and the SSE stream would never be quiet."""
    body = dict(state)
    body.pop("ts", None)
    # A panel's `updated_at` bump alone is a heartbeat, not a state change (contract
    # decision, Wave 4): the digest sees id/type/title/data/refresh_s and the `stale`
    # flip, never the timestamp -- so hmd's own periodic hmd-live-users rewrite, or a
    # job re-publishing identical numbers, keeps the SSE stream quiet.
    panels = body.get("panels")
    if isinstance(panels, list):
        body["panels"] = [{k: v for k, v in p.items() if k != "updated_at"} if isinstance(p, dict) else p
                          for p in panels]
    # `inbox.oldest_age_s` ticks every second a message sits queued: a clock reading,
    # not a state change (pending 0->1 and 1->0 already move the digest), so like `ts`
    # it stays out -- otherwise every poll tick would emit an SSE frame and a relay
    # state frame for as long as one message is pending.
    inbox = body.get("inbox")
    if isinstance(inbox, dict) and "oldest_age_s" in inbox:
        body["inbox"] = {k: v for k, v in inbox.items() if k != "oldest_age_s"}
    return hashlib.sha256(canonical_json(body).encode("utf-8")).hexdigest()


# ── one poller, many consumers ───────────────────────────────────────────────
class StateCache:
    """A single background thread re-reads the sources every POLL_INTERVAL_S and
    publishes (state, digest). SSE clients wait on the condition for a digest change,
    so N open tabs cost one collection per tick, not N. UIHandler._route's /api/state
    branch shares this SAME object (state, digest, lock) via refresh() -- perf comes
    from the lower-level subprocess/file caches making each refresh() cheap, not from
    skipping it; a GET can also be what wakes an idle SSE stream, since refresh()
    notifies the same condition variable wait_for_change() blocks on."""

    def __init__(self, root, transport=None):
        self.root = root
        self.transport = transport
        self._cond = threading.Condition()
        self._refresh_lock = threading.Lock()  # only one collect_state() in flight at a time
        self._state = None
        self._digest = None
        self._refreshed_at = None   # time.monotonic() of the last completed refresh, or None
        self._stop = threading.Event()
        self._live_users = None   # (value, written_at) of the self-published panel
        self._companion = new_companion_publisher(root)   # A3: chat / hmd-question / agents

    def refresh(self, publish=False):
        state = collect_state(self.root, self.transport)
        if publish:
            # Poll-tick only (never on a GET): publish hmd's own live-users tile from
            # the roster count just collected, then re-read panels so THIS frame
            # already carries the fresh value instead of waiting one more tick.
            before = self._live_users
            self._live_users = publish_live_users(self.root, len(state.get("roster") or []), before)
            companion_changed = publish_companion_panels(self._companion)
            if self._live_users is not before or companion_changed:
                try:
                    panels = collect_panels(self.root)
                    # collect_panels() is called directly here (not through another
                    # collect_state()), so it bypasses collect_state()'s own A9/N4
                    # redaction gate -- re-apply it so a public-mode server can never
                    # emit one unredacted panel per live-users publish tick.
                    redact, strip_root = _transport_redaction(self.transport, self.root)
                    if redact:
                        panels = _redact_public(panels, strip_root)
                    state["panels"] = panels
                except Exception:
                    state["panels"] = []
        digest = digest_of(state)
        with self._cond:
            self._state = state
            self._refreshed_at = time.monotonic()
            if digest != self._digest:
                self._digest = digest
                self._cond.notify_all()
        return state, digest

    def _fresh_locked(self):
        """True if there's a state newer than one poll interval. Caller holds _cond."""
        return (self._state is not None and self._refreshed_at is not None
                and time.monotonic() - self._refreshed_at < POLL_INTERVAL_S)

    def latest(self):
        """perf: the common case is a lock, a freshness check, and a return -- no
        collection at all. Recomputes synchronously, at most once per
        POLL_INTERVAL_S, only when empty (first request) or stale (poller fell
        behind, or invalidate() was just called)."""
        with self._cond:
            if self._fresh_locked():
                return self._state, self._digest
        with self._refresh_lock:
            with self._cond:
                if self._fresh_locked():
                    return self._state, self._digest
            return self.refresh()

    def invalidate(self):
        """Force the next latest() to recompute rather than serve a cached snapshot --
        for a write THIS process just made (POST /api/send) that latest()'s own
        POLL_INTERVAL_S staleness window would otherwise mask for up to one tick."""
        with self._cond:
            self._refreshed_at = None

    def wait_for_change(self, seen_digest, timeout):
        """Block until the digest differs from `seen_digest` or `timeout` elapses.
        Returns (state, digest) -- the caller compares digests to decide whether to emit."""
        with self._cond:
            if self._digest != seen_digest:
                return self._state, self._digest
            self._cond.wait(timeout)
            return self._state, self._digest

    def run(self):
        while not self._stop.is_set():
            with self._refresh_lock:
                self.refresh(publish=True)
            self._stop.wait(POLL_INTERVAL_S)

    def start(self):
        t = threading.Thread(target=self.run, name="hmd-ui-poller", daemon=True)
        t.start()
        return t

    def stop(self):
        self._stop.set()


# ── HTTP layer ────────────────────────────────────────────────────────────────
class UIServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False   # a stale reuse could hand another process our port

    def __init__(self, port, token, cache, allow_hosts=(), trust_proxy=False):
        super().__init__(("127.0.0.1", port), UIHandler)
        self.token = token
        self.cache = cache
        self.port = self.server_address[1]
        self.trust_proxy = bool(trust_proxy)
        self.public_host = None
        hosts = {"127.0.0.1:%d" % self.port, "localhost:%d" % self.port}
        names = set()
        for name in allow_hosts or ():
            n = (name or "").strip().lower()
            if not n:
                continue
            if self.public_host is None:
                self.public_host = n
            hosts.add(n)
            names.add(n)
        self.allowed_hosts = frozenset(hosts)
        self.allow_host_names = frozenset(names)  # bare names; _host_ok matches these w/ ANY port
        self._backoff_lock = threading.Lock()
        self._backoff = OrderedDict()   # ip -> {"count", "window_start", "locked_until"}
        # A2: hard caps so a burst of idle/slow connections (pre-auth slow-loris) or a
        # pile of open streams can never grow thread/resource use without bound.
        # BoundedSemaphore so a mismatched extra release() raises loudly instead of
        # silently letting the effective cap drift upward over the server's lifetime.
        self.conn_semaphore = threading.BoundedSemaphore(MAX_CONNECTIONS)
        self.sse_semaphore = threading.BoundedSemaphore(MAX_SSE_STREAMS)

    def process_request(self, request, client_address):
        """A2: a connection past MAX_CONNECTIONS concurrent is closed immediately --
        no thread spawned, nothing read or written. True pre-auth: routing/auth only
        starts once a handler thread exists, which this refuses to create. `_threads`
        bookkeeping (block_on_close / server_close()'s .join()) is left entirely to
        the real ThreadingMixIn.process_request, only reached once a slot is held."""
        if not self.conn_semaphore.acquire(blocking=False):
            self._reject_over_capacity(request)
            return
        super().process_request(request, client_address)

    def _reject_over_capacity(self, request):
        # Mirrors _serve_events' except-and-return idiom: a socket this far past its
        # useful life raising on close is expected, not exceptional.
        try:
            request.close()
        except OSError:
            return

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.conn_semaphore.release()

    def backoff_seconds_left(self, ip):
        """>0 if `ip` is currently locked out; the caller need not hold any lock."""
        now = time.time()
        with self._backoff_lock:
            rec = self._backoff.get(ip)
            if rec and rec["locked_until"] > now:
                return rec["locked_until"] - now
        return 0.0

    def backoff_record_failure(self, ip):
        """Count one auth failure for `ip`; returns True the instant a lockout trips
        (so the caller logs exactly once per lockout, not once per blocked request).
        At capacity, room for a brand-new ip is made by evicting the oldest tracked
        record that is NOT currently a live lockout; if every tracked record is
        presently locked, this ip's failure goes untracked rather than bumping a real
        lockout off early (A7) -- plain `popitem(last=False)` evicted whichever record
        was oldest even if its lock was still counting down, so a burst of fresh
        distinct ips (trivial under a spoofed X-Forwarded-For) could free an
        attacker's own lockout well before BACKOFF_LOCKOUT_S actually elapsed."""
        now = time.time()
        tripped = False
        with self._backoff_lock:
            rec = self._backoff.get(ip)
            is_new = rec is None
            if rec is None or now - rec["window_start"] > BACKOFF_WINDOW_S:
                rec = {"count": 0, "window_start": now, "locked_until": 0.0}
            if is_new and len(self._backoff) >= BACKOFF_CAP:
                if not self._evict_oldest_unlocked(now):
                    return False   # every tracked record is a live lockout -- refuse, don't evict one
            rec["count"] += 1
            if rec["count"] >= BACKOFF_MAX_FAILURES and rec["locked_until"] <= now:
                rec["locked_until"] = now + BACKOFF_LOCKOUT_S
                tripped = True
            self._backoff[ip] = rec
            self._backoff.move_to_end(ip)
        return tripped

    def _evict_oldest_unlocked(self, now):
        """Caller already holds `_backoff_lock`. Evicts the least-recently-touched
        record whose lockout isn't currently live; returns whether it found one to
        evict. Plain `OrderedDict` iteration order is insertion/move-to-end order, so
        this is the same oldest-first policy as before, just skipping over any
        record that is still a live lockout."""
        for k, v in self._backoff.items():
            if v["locked_until"] <= now:
                del self._backoff[k]
                return True
        return False

    def backoff_clear(self, ip):
        """A successful auth resets `ip`'s failure count entirely."""
        with self._backoff_lock:
            self._backoff.pop(ip, None)


class UIHandler(BaseHTTPRequestHandler):
    server_version = "hmd-ui"
    sys_version = ""
    # A2: socketserver.StreamRequestHandler.setup() applies this to the connection
    # before the first read -- an idle pre-auth socket (classic slow-loris: connect,
    # send nothing) now gets its header read timed out and closed by the stdlib's own
    # TimeoutError handling in handle_one_request, instead of parking a thread on
    # that socket forever. _serve_events clears it back to None once a stream
    # actually starts, so a long-lived SSE tab is never at risk of being cut by this.
    timeout = HEADER_READ_TIMEOUT_S

    # -- helpers --------------------------------------------------------------
    def _common_headers(self, ctype, length=None):
        self.send_header("Content-Type", ctype)
        if length is not None:
            self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
            "connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'",
        )
        self.send_header("Connection", "close")

    def _send(self, code, body, ctype="text/plain; charset=utf-8", extra_headers=None):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self._common_headers(ctype, len(data))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _send_json(self, code, obj, extra_headers=None):
        self._send(code, json_for_wire(obj), "application/json; charset=utf-8", extra_headers)

    def _host_ok(self):
        host = (self.headers.get("Host") or "").strip().lower()
        if host in self.server.allowed_hosts:
            return True
        # An --allow-host name also matches with ANY numeric port (a Funnel-fronted
        # proxy may terminate on 443, 8443, or 10000) -- exact hostname required,
        # no suffix/wildcard matching; only the port half is a wildcard.
        name, sep, port = host.rpartition(":")
        return bool(sep) and port.isdigit() and name in self.server.allow_host_names

    def _presented_token(self, query):
        presented = self.headers.get("X-Heimdall-UI-Token") or ""
        if not presented:
            vals = query.get("token") or []
            presented = vals[0] if vals else ""
        return presented

    def _token_ok(self, query):
        presented = self._presented_token(query)
        if not presented:
            return False
        return hmac.compare_digest(presented.encode("utf-8"), self.server.token.encode("utf-8"))

    def _client_ip(self):
        if self.server.trust_proxy:
            xff = self.headers.get("X-Forwarded-For") or ""
            # A1: key on the LAST value -- the one the single trusted hop in front of
            # this server appended itself. Everything before it came from the client
            # (or an attacker) and must never be trusted. Keying on the FIRST value let
            # an attacker pick their own backoff identity at will, just by varying it
            # request to request, without ever affecting the real lockout.
            parts = [p.strip() for p in xff.split(",") if p.strip()]
            if parts:
                return parts[-1]
        return self.client_address[0]

    def _send_backoff_429(self):
        self._send_json(429, {"error": "backoff", "retry_after_s": int(BACKOFF_LOCKOUT_S)},
                         extra_headers={"Retry-After": str(int(BACKOFF_LOCKOUT_S))})

    def _log_lockout(self, ip):
        sys.stderr.write("hmd-ui: backoff lockout ip=%s\n" % ip)

    def log_message(self, fmt, *args):
        # Never log the query string: it carries the token. `path`/`command` may not
        # exist yet if this fires before a request line was ever parsed -- e.g. the
        # A2 header-read timeout closing an idle connection that sent nothing at all.
        path = urlsplit(getattr(self, "path", "") or "").path
        sys.stderr.write("hmd-ui %s %s %s\n" % (getattr(self, "command", None), path,
                                                 args[1] if len(args) > 1 else ""))

    # -- routing --------------------------------------------------------------
    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        self._gate_then(self._route_post)

    def do_GET(self):
        self._gate_then(self._route)

    def _route_post(self, _query):
        path = urlsplit(self.path).path
        if path == "/api/send":
            self._handle_send()
        else:
            self._send(405, "method not allowed")

    def _handle_send(self):
        """POST /api/send: companion -> session message, appended to
        .heimdall/ui/inbox.jsonl (bin/lib/companion_ui_inbox.append). Auth already
        passed -- _gate_then ran first. The text is never logged (log_message only
        ever sees the path, see its comment above) and never echoed back on any
        failure path -- only a field/rule name is."""
        ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        if ctype != "application/json":
            self._send_json(415, {"error": "unsupported-media-type"})
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self._send_json(400, {"error": "invalid-content-length"})
            return
        if length < 0:
            self._send_json(400, {"error": "invalid-content-length"})
            return
        if length > MAX_SEND_BODY_BYTES:
            self._send_json(413, {"error": "payload-too-large"})
            return
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            obj = json.loads(raw.decode("utf-8")) if raw else {}
        except (ValueError, UnicodeDecodeError):
            self._send_json(400, {"error": "invalid-json"})
            return
        if not isinstance(obj, dict) or not isinstance(obj.get("text"), str):
            self._send_json(400, {"error": "text field (string) is required"})
            return
        if INBOX is None:
            self._send_json(500, {"error": "inbox module unavailable"})
            return
        root = self.server.cache.root
        try:
            record = INBOX.append(root, obj["text"])
        except INBOX.InboxError as e:
            self._send_json(422, {"error": e.code})
            return
        except OSError:
            self._send_json(500, {"error": "write-failed"})
            return
        # This write changes /api/state's inbox.pending in THIS process -- invalidate
        # so the very next GET recomputes instead of serving a snapshot up to
        # POLL_INTERVAL_S stale (see StateCache.invalidate).
        self.server.cache.invalidate()
        queued = len(INBOX.list_pending(root))
        self._send_json(202, {"id": record["id"], "queued": queued})

    def _gate_then(self, handler):
        parts = urlsplit(self.path)
        query = parse_qs(parts.query, keep_blank_values=False)
        ip = self._client_ip()
        host_ok = self._host_ok()
        if host_ok and self._token_ok(query):
            # A7: a request presenting the CORRECT token on an allowed Host is NEVER
            # denied by backoff. Lockout exists to slow a guesser; it must not also
            # lock out the legitimate phone behind a shared carrier NAT, an
            # attacker-chosen X-Forwarded-For, or -- with --trust-proxy off behind a
            # real proxy -- the single peer address (127.0.0.1) every request shares.
            self.server.backoff_clear(ip)
            handler(query)
            return
        if self.server.backoff_seconds_left(ip) > 0:
            self._send_backoff_429()
            return
        if not host_ok:
            if self.server.backoff_record_failure(ip):
                self._log_lockout(ip)
            self._send(403, "forbidden: Host header is not this server's loopback origin")
            return
        presented = self._presented_token(query)
        # Only a presented-but-wrong token counts toward backoff: a client that simply
        # has not sent one yet must not trip the same lockout a brute-force guesser would.
        if presented:
            if self.server.backoff_record_failure(ip):
                self._log_lockout(ip)
        self._send(401, "unauthorized: missing or invalid token")

    def _route(self, query):
        path = urlsplit(self.path).path
        if path == "/":
            self._serve_page()
        elif path == "/api/state":
            # perf: always a fresh collect_state() -- same invariant the pre-cache
            # code documented: a source deleted a moment ago must read as null NOW,
            # not after the next poll tick. refresh() is cheap now because the slow
            # parts (subprocess spawns, metrics.jsonl parses) are cached below it at
            # SUBPROCESS_CACHE_TTL_S / by mtime -- not because the whole snapshot is
            # served stale. refresh() also updates the SAME (state, digest) pair
            # /api/events waits on, so a GET here can wake an idle SSE stream sooner.
            state, digest = self.server.cache.refresh()
            etag = '"%s"' % digest
            if self._state_not_modified(query, digest):
                self._send_not_modified(etag)
            else:
                self._send_json(200, state, extra_headers={"ETag": etag})
        elif path == "/api/events":
            self._serve_events()
        else:
            self._send(404, "not found")

    def _state_not_modified(self, query, digest):
        """True when the client already has this exact snapshot: `?digest=` or
        `If-None-Match` (quoted or bare) matches the current digest -- the same
        digest_of() value an /api/events frame's `id:` line carries, so a client can
        reuse either as the other's cache key. Pattern: _presented_token above."""
        vals = query.get("digest") or []
        requested = vals[0] if vals else ""
        if requested and requested == digest:
            return True
        inm = (self.headers.get("If-None-Match") or "").strip()
        if inm.startswith('"') and inm.endswith('"') and len(inm) >= 2:
            inm = inm[1:-1]
        return bool(inm) and inm == digest

    def _send_not_modified(self, etag):
        """304, no body. RFC 7232 section 4.1 permits only a handful of headers on a
        304 and forbids a representation header like Content-Type, so this does not
        go through _common_headers()."""
        self.send_response(304)
        self.send_header("ETag", etag)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

    def _serve_page(self):
        html = _read_text(PAGE_PATH)
        if html is None:
            self._send(500, "hmd-ui.html is missing next to hmd-ui.py; reinstall hmd")
            return
        self._send(200, html, "text/html; charset=utf-8")

    def _serve_events(self):
        if not self.server.sse_semaphore.acquire(blocking=False):
            # A2: a separate, lower cap than MAX_CONNECTIONS -- an authenticated
            # client can still open only so many concurrent held-open streams before
            # they, specifically, get pushed back; the caller can retry shortly.
            self._send_json(503, {"error": "too-many-streams", "retry_after_s": SSE_RETRY_AFTER_S},
                             extra_headers={"Retry-After": str(SSE_RETRY_AFTER_S)})
            return
        try:
            self.send_response(200)
            self._common_headers("text/event-stream; charset=utf-8")
            self.end_headers()
            if self.command == "HEAD":
                return
            # A2: UIHandler.timeout governs the pre-auth header read; a stream that
            # made it this far is authenticated and expected to sit open a long time,
            # writing only every POLL_INTERVAL_S/KEEPALIVE_S -- clear it so that
            # normal long idle gaps are never mistaken for the slow-loris case it was
            # added for.
            self.connection.settimeout(None)
            cache = self.server.cache
            state, digest = cache.latest()
            seen = None
            last_write = time.monotonic()
            while True:
                if digest != seen:
                    frame = "id: %s\ndata: %s\n\n" % (digest, json_for_wire(state))
                    self.wfile.write(frame.encode("utf-8"))
                    self.wfile.flush()
                    seen = digest
                    last_write = time.monotonic()
                state, digest = cache.wait_for_change(seen, POLL_INTERVAL_S)
                if digest == seen and time.monotonic() - last_write >= KEEPALIVE_S:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    last_write = time.monotonic()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return
        finally:
            self.server.sse_semaphore.release()


# ── CLI ───────────────────────────────────────────────────────────────────────
def resolve_root(explicit):
    if explicit:
        return os.path.realpath(os.path.expanduser(explicit))
    if WATCH_DATA is not None:
        try:
            return os.path.realpath(WATCH_DATA.resolve_root())
        except Exception:
            return os.getcwd()
    return os.getcwd()


def print_sources(root):
    """Exactly the paths and commands this server reads. Nothing else is opened."""
    home = os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")
    for rel in SOURCE_FILES:
        print("file %s" % os.path.join(root, rel))
    for rel in SOURCE_HOME_FILES:
        print("file %s" % os.path.join(home, rel))
    for rel in SOURCE_TMP_FILES:
        print("file %s" % os.path.join(os.environ.get("TMPDIR") or "/tmp", rel))
    if COMPANION is not None:
        for path in COMPANION.source_paths(root):
            print("file %s" % path)
    claude_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    for rel in SOURCE_CLAUDE_FILES:
        print("file %s" % os.path.join(claude_dir, rel))
    print("file %s" % PAGE_PATH)
    for argv in SOURCE_COMMANDS:
        print("exec %s" % shlex.join([os.path.join(BIN_DIR, argv[0])] + list(argv[1:])))
    for argv in GIT_COMMANDS:
        print("exec %s" % shlex.join(list(argv)))


def print_deny_list():
    for b in sorted(DENY_BASENAMES):
        print("basename %s" % b)
    for s in DENY_SUFFIXES:
        print("suffix *%s" % s)
    for p in DENY_PREFIXES:
        print("prefix %s*" % p)
    for d in sorted(DENY_DIR_PARTS):
        print("dir */%s/*" % d)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd ui", description="loopback companion UI for hmd")
    ap.add_argument("--repo", help="repo root to render (default: HEIMDALL_WATCH_ROOT, git toplevel, or cwd)")
    ap.add_argument("--port", type=int, default=0, help="bind port (default: a random free port)")
    ap.add_argument("--no-open", action="store_true", help="do not open the browser")
    ap.add_argument("--print-sources", action="store_true", help="list every file/command the server reads, then exit")
    ap.add_argument("--print-deny-list", action="store_true", help="list the never-read patterns, then exit")
    ap.add_argument("--print-state", action="store_true", help="collect the contract once, print it, then exit")
    ap.add_argument("--allow-host", action="append", default=[], metavar="NAME",
                     help="extend the Host allowlist with NAME (repeatable) -- a reverse proxy's "
                          "public hostname (e.g. a Tailscale Funnel *.ts.net name); matches "
                          "NAME bare or NAME:<any port>, exactly, case-insensitive; bind stays 127.0.0.1")
    ap.add_argument("--trust-proxy", action="store_true",
                     help="use X-Forwarded-For's last value (the one the trusted hop itself "
                          "appended) for per-IP accounting (backoff, /api/state.transport) "
                          "instead of the socket peer; only meaningful behind a proxy that "
                          "sets it -- ignored entirely when absent")
    args = ap.parse_args(argv)

    root = resolve_root(args.repo)
    transport = {
        "bind": "loopback",
        "public_host": (args.allow_host[0].strip().lower() if args.allow_host else None),
        "trust_proxy": bool(args.trust_proxy),
    }
    if args.print_sources:
        print_sources(root)
        return 0
    if args.print_deny_list:
        print_deny_list()
        return 0
    if args.print_state:
        print(json.dumps(collect_state(root, transport), indent=2, ensure_ascii=False))
        return 0

    token = secrets.token_urlsafe(32)
    cache = StateCache(root, transport)
    try:
        server = UIServer(args.port, token, cache, allow_hosts=args.allow_host, trust_proxy=args.trust_proxy)
    except OSError as e:
        sys.stderr.write("hmd ui: cannot bind 127.0.0.1:%d: %s\n" % (args.port, e))
        return 2
    cache.start()
    url = "http://127.0.0.1:%d/?token=%s" % (server.port, token)
    print(url, flush=True)
    if server.public_host:
        print("hmd ui: public hostname allowed: %s" % server.public_host, flush=True)
        print("hmd ui: WARNING -- once reachable via that hostname (e.g. a Tailscale Funnel), "
              "this server is reachable beyond this machine", flush=True)
    if not args.no_open:
        threading.Thread(target=webbrowser.open_new_tab, args=(url,), daemon=True).start()
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        sys.stderr.write("\nhmd ui: stopped\n")
    finally:
        cache.stop()
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

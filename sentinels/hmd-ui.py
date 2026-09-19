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
    /api/state        the section-4 JSON contract, built fresh from the sources
    /api/events       text/event-stream; a `data:` frame only when the digest changes

Auth, in this order, on EVERY route:
    1. Host header must be 127.0.0.1:<port> or localhost:<port>   -> else 403
       (DNS-rebinding defence: a page on evil.example resolving to 127.0.0.1 still
       sends Host: evil.example, and is refused before the token is even looked at)
    2. per-launch token (`?t=` query or X-Heimdall-UI-Token header), compared with
       hmac.compare_digest                                          -> else 401

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
)
# Outside the repo: hmd_ledger's per-repo mirror under $HEIMDALL_HOME/ledger/.
SOURCE_HOME_FILES = (
    "ledger/repos/<repo_key>.json",
    "ledger/status.json",
)
SOURCE_COMMANDS = (
    ("heimdall-hooks", "list", "--json"),
    ("parallelism-tracker", "grade"),
    ("edit-tracker", "paths"),
    ("heimdall-state", "check-quality-gates"),
    ("heimdall-fallback", "status", "--json"),
    ("heimdall-identity", "--json"),
    ("heimdall-haid", "current"),
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


def _run(argv, cwd, timeout=CMD_TIMEOUT_S):
    """Bounded subprocess: (returncode, stdout, stderr) or (None, '', '') on any fault.
    The first argv element is resolved against hmd's own bin/ so the target repo's
    PATH never decides which hmd tool answers."""
    exe = argv[0]
    if exe != "git":
        exe = os.path.join(BIN_DIR, exe)
        if not os.access(exe, os.X_OK):
            return None, "", ""
    try:
        p = subprocess.run(
            [exe] + list(argv[1:]), cwd=cwd, capture_output=True, text=True,
            timeout=timeout, stdin=subprocess.DEVNULL,
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


def _first_line(text):
    for line in (text or "").splitlines():
        s = line.strip()
        if s:
            return s
    return ""


# ── per-field collectors (each returns its contract slice, or None) ──────────
def collect_identity(root):
    ident = _run_json(("heimdall-identity", "--json"), root)
    handle = ident.get("handle") if isinstance(ident, dict) else None
    rc, out, _ = _run(("heimdall-haid", "current"), root)
    haid = _first_line(out) if rc == 0 else None
    rc, out, _ = _run(("git", "rev-parse", "--abbrev-ref", "HEAD"), root, timeout=3)
    branch = _first_line(out) if rc == 0 else None
    return {"handle": handle or None, "haid": haid or None, "branch": branch or None}


def collect_ledger(root):
    if LEDGER is None:
        return None
    try:
        st = LEDGER.read_status("hmd-ui", repo=root)
    except Exception:
        return None
    if not isinstance(st, dict):
        return None
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
    rc, out, err = _run(("heimdall-state", "check-quality-gates"), root)
    if rc is None:
        return None
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
    data = _run_json(("heimdall-hooks", "list", "--json"), root)
    if not isinstance(data, list):
        return None
    return [{k: h.get(k) for k in HOOK_KEYS} for h in data if isinstance(h, dict)]


def collect_fallback(root):
    data = _run_json(("heimdall-fallback", "status", "--json"), root)
    if not isinstance(data, dict):
        return None
    # Decision 4: never forward endpoint / operator_key_* / config_path.
    return {k: data.get(k) for k in FALLBACK_ALLOWED_KEYS}


_PAR_RE = re.compile(
    r"(\d+)\s+batched\s*/\s*(\d+)\s+turns\s*\(ratio\s+([\d.]+),\s*(\d+)\s+calls\)"
    r"(?:\s*\|\s*agents:\s*(\d+)\s+calls?(?:,\s*(\d+)\s+batched)?)?"
)


def parse_parallelism(line):
    m = _PAR_RE.search(line or "")
    if not m:
        return None
    g = m.groups()
    return {
        "batched": int(g[0]), "turns": int(g[1]), "ratio": float(g[2]), "calls": int(g[3]),
        "agent_calls": int(g[4]) if g[4] is not None else 0,
        "agent_batched": int(g[5]) if g[5] is not None else 0,
    }


def collect_parallelism(root):
    rc, out, _ = _run(("parallelism-tracker", "grade"), root)
    if rc is None:
        return None
    return parse_parallelism(_first_line(out))


def collect_edits(root):
    rc, out, _ = _run(("edit-tracker", "paths"), root)
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
    """Header fields of the auto-checkpoint block only -- never the free-text body.
    Stops at the first `###` sub-heading, which is where the body begins."""
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
        if line.startswith("### "):
            break
        m = _CKPT_FIELD_RE.match(line.strip())
        if m:
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


def collect_state(root):
    """The section-4 contract. Each slice degrades to null independently."""
    def safe(fn):
        try:
            return fn(root)
        except Exception:
            return None
    return {
        "schema_version": SCHEMA_VERSION,
        "ts": time.time(),
        "repo": root,
        "identity": safe(collect_identity),
        "ledger": safe(collect_ledger),
        "roster": safe(collect_roster),
        "quality_gate": safe(collect_quality_gate),
        "sweep_receipt": safe(collect_sweep_receipt),
        "hooks": safe(collect_hooks),
        "fallback": safe(collect_fallback),
        "parallelism": safe(collect_parallelism),
        "checkpoint": safe(collect_checkpoint),
        "reels": safe(collect_reels),
        "edits": safe(collect_edits),
    }


def canonical_json(state):
    return json.dumps(state, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest_of(state):
    """SHA-256 over the canonical JSON with the wall-clock `ts` removed -- otherwise
    every poll would differ and the SSE stream would never be quiet."""
    body = dict(state)
    body.pop("ts", None)
    return hashlib.sha256(canonical_json(body).encode("utf-8")).hexdigest()


# ── one poller, many consumers ───────────────────────────────────────────────
class StateCache:
    """A single background thread re-reads the sources every POLL_INTERVAL_S and
    publishes (state, digest). SSE clients wait on the condition for a digest change,
    so N open tabs cost one collection per tick, not N."""

    def __init__(self, root):
        self.root = root
        self._cond = threading.Condition()
        self._state = None
        self._digest = None
        self._stop = threading.Event()

    def refresh(self):
        state = collect_state(self.root)
        digest = digest_of(state)
        with self._cond:
            self._state = state
            if digest != self._digest:
                self._digest = digest
                self._cond.notify_all()
        return state, digest

    def latest(self):
        with self._cond:
            if self._state is not None:
                return self._state, self._digest
        return self.refresh()

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
            self.refresh()
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

    def __init__(self, port, token, cache):
        super().__init__(("127.0.0.1", port), UIHandler)
        self.token = token
        self.cache = cache
        self.port = self.server_address[1]
        self.allowed_hosts = frozenset({"127.0.0.1:%d" % self.port, "localhost:%d" % self.port})


class UIHandler(BaseHTTPRequestHandler):
    server_version = "hmd-ui"
    sys_version = ""

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

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self._common_headers(ctype, len(data))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _send_json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def _host_ok(self):
        host = (self.headers.get("Host") or "").strip().lower()
        return host in self.server.allowed_hosts

    def _token_ok(self, query):
        presented = self.headers.get("X-Heimdall-UI-Token") or ""
        if not presented:
            vals = query.get("t") or []
            presented = vals[0] if vals else ""
        if not presented:
            return False
        return hmac.compare_digest(presented.encode("utf-8"), self.server.token.encode("utf-8"))

    def log_message(self, fmt, *args):
        # Never log the query string: it carries the token.
        path = urlsplit(self.path).path
        sys.stderr.write("hmd-ui %s %s %s\n" % (self.command, path, args[1] if len(args) > 1 else ""))

    # -- routing --------------------------------------------------------------
    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        self._gate_then(lambda _q: self._send(405, "method not allowed"))

    def do_GET(self):
        self._gate_then(self._route)

    def _gate_then(self, handler):
        parts = urlsplit(self.path)
        query = parse_qs(parts.query, keep_blank_values=False)
        if not self._host_ok():
            self._send(403, "forbidden: Host header is not this server's loopback origin")
            return
        if not self._token_ok(query):
            self._send(401, "unauthorized: missing or invalid token")
            return
        handler(query)

    def _route(self, _query):
        path = urlsplit(self.path).path
        if path == "/":
            self._serve_page()
        elif path == "/api/state":
            state, _digest = self.server.cache.latest()
            self._send_json(200, state)
        elif path == "/api/events":
            self._serve_events()
        else:
            self._send(404, "not found")

    def _serve_page(self):
        html = _read_text(PAGE_PATH)
        if html is None:
            self._send(500, "hmd-ui.html is missing next to hmd-ui.py; reinstall hmd")
            return
        self._send(200, html, "text/html; charset=utf-8")

    def _serve_events(self):
        self.send_response(200)
        self._common_headers("text/event-stream; charset=utf-8")
        self.end_headers()
        if self.command == "HEAD":
            return
        cache = self.server.cache
        state, digest = cache.latest()
        seen = None
        last_write = time.monotonic()
        try:
            while True:
                if digest != seen:
                    frame = "id: %s\ndata: %s\n\n" % (digest, json.dumps(state, ensure_ascii=False))
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
    args = ap.parse_args(argv)

    root = resolve_root(args.repo)
    if args.print_sources:
        print_sources(root)
        return 0
    if args.print_deny_list:
        print_deny_list()
        return 0
    if args.print_state:
        print(json.dumps(collect_state(root), indent=2, ensure_ascii=False))
        return 0

    token = secrets.token_urlsafe(32)
    cache = StateCache(root)
    try:
        server = UIServer(args.port, token, cache)
    except OSError as e:
        sys.stderr.write("hmd ui: cannot bind 127.0.0.1:%d: %s\n" % (args.port, e))
        return 2
    cache.start()
    url = "http://127.0.0.1:%d/?t=%s" % (server.port, token)
    print(url, flush=True)
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

#!/usr/bin/env python3
"""hmd_session_resolve.py -- which Claude Code session an `hmd ui` / relay-client instance reads.

THE PROBLEM. bin/heimdall-app launches `hmd ui` and bin/heimdall-relay-client from whatever shell
ran `hmd app connect`, so every instance inherits THAT shell's CLAUDE_CODE_SESSION_ID. Two
instances serving two repos, launched from one shell, therefore shared one session id -- and every
collector keyed off the inherited id (the edit ledger `edit-tracker paths`, the parallelism
counters, the session code) served the OTHER repo's session: the relay client for
/Users/rj/Downloads/heimdall showed the hmdapp session's edits (2026-10-01). The transcript-derived
collectors (attention, chat, hmd-question) read the repo's own project dir but disagreed with each
other about which session in it (one honoured the pin, the other ignored it).

THE RULE (operator decision, 2026-10-01) -- an instance reads ONLY sessions whose cwd is its own
--repo, and every collector asks THIS module which one:

  1. Candidates are the top-level *.jsonl files directly under
     ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<slug>/, <slug> = every non-alphanumeric char of the
     repo root -> '-' (the naming bin/heimdall-agents uses), for the root as given AND its
     realpath. Sub-agent files (<session>/subagents/) and dot-files are not sessions.
  2. An inherited CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID / SESSION_ID (that precedence; the
     first name that fits wins) is honoured ONLY when it names one of THOSE candidates. A foreign
     id -- the other repo's session -- is ignored, never trusted. A value that is not a plain
     [A-Za-z0-9_-]{1,128} key is ignored (it is joined into a path and handed to edit-tracker).
  3. Otherwise the session is the newest candidate whose entrypoint is not `sdk*` (hmd's own
     headless judge / dream sessions write transcripts into the same directory and would flap
     everything); with only headless sessions, the newest of them.
  4. No candidate at all -> None. Callers fall back to their own UNKEYED source (edit-tracker's
     `default` ledger, the tracker's `default.state`, the repo path for the session code) --
     never to an inherited id.

`Session.id` is the transcript's file name without `.jsonl` (== Claude's session id, and the key
edit-tracker / parallelism-tracker name their files by), or None when that name is not a safe key.
`Session.pinned` is True when rule 2 chose it.

COST. A selection is a scandir + a stat per candidate; the entrypoint of up to PROBE_LIMIT of the
newest candidates is read once (the first HEAD_BYTES of the file) and cached per path. Results are
cached for `ttl` seconds (default DIR_SCAN_TTL_S; ttl=0 re-scans every call).

Stdlib only.
"""
import collections
import json
import os
import re
import threading
import time

SESSION_ENV_NAMES = ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "SESSION_ID")
HEAD_BYTES = 64 * 1024         # entrypoint probe of a candidate transcript
PROBE_LIMIT = 12               # newest candidates probed for a non-headless entrypoint
DIR_SCAN_TTL_S = 2.0

_SID_RE = re.compile(r"[A-Za-z0-9_-]{1,128}")

Session = collections.namedtuple("Session", ("id", "path", "pinned"))

_LOCK = threading.RLock()
_SELECT = {}   # (project dirs, inherited ids, denied) -> (monotonic, Session | None)
_HEADS = {}    # transcript path -> entrypoint (a session file's entrypoint never changes)


def reset_caches():
    with _LOCK:
        _SELECT.clear()
        _HEADS.clear()


def project_slug(path):
    """Claude Code's project dir name: every non-alphanumeric char -> '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def projects_dir():
    """HMD_AGENT_PROJECTS_DIR (bin/heimdall-agents' test override), else CLAUDE_CONFIG_DIR, else ~/.claude."""
    override = os.environ.get("HMD_AGENT_PROJECTS_DIR")
    if override:
        return override
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        return os.path.join(cfg, "projects")
    return os.path.join(os.environ.get("HOME") or os.path.expanduser("~"), ".claude", "projects")


def project_dirs(root):
    """The Claude project dirs for `root` as given and for its realpath (deduplicated)."""
    base = projects_dir()
    dirs = []
    for p in (root, os.path.realpath(root)):
        d = os.path.join(base, project_slug(p))
        if d not in dirs:
            dirs.append(d)
    return tuple(dirs)


def inherited_ids():
    """The well-formed session ids in this process's env, in SESSION_ENV_NAMES precedence."""
    out = []
    for name in SESSION_ENV_NAMES:
        v = os.environ.get(name)
        if v and _SID_RE.fullmatch(v) and v not in out:
            out.append(v)
    return tuple(out)


def transcripts(root, denied=None):
    """[(mtime_ns, size, path)] of the repo's top-level session transcripts, newest first.
    `denied` is hmd-ui's path_is_denied: a denied path is never a candidate."""
    out = []
    for d in project_dirs(root):
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                if not e.name.endswith(".jsonl") or e.name.startswith("."):
                    continue
                try:
                    if e.is_file():
                        st = e.stat()
                        out.append((st.st_mtime_ns, st.st_size, e.path))
                except OSError:
                    continue
    out = [c for c in out if not (denied and denied(c[2]))]
    out.sort(reverse=True)
    return out


def _entrypoint(path):
    cached = _HEADS.get(path)
    if cached is not None:
        return cached
    try:
        with open(path, "rb") as f:
            head = f.read(HEAD_BYTES)
    except OSError:
        return None
    for raw in head.split(b"\n"):
        if b'"entrypoint"' not in raw:
            continue
        try:
            obj = json.loads(raw)
        except ValueError:
            continue
        ep = obj.get("entrypoint") if isinstance(obj, dict) else None
        if isinstance(ep, str):
            if len(_HEADS) > 256:
                _HEADS.clear()
            _HEADS[path] = ep
            return ep
    return None


def _headless(path):
    ep = _entrypoint(path)
    return ep is not None and ep.startswith("sdk")


def _session(path, pinned):
    sid = os.path.splitext(os.path.basename(path))[0]
    return Session(sid if _SID_RE.fullmatch(sid) else None, path, pinned)


def _pick(root, ids, denied):
    for sid in ids:
        for d in project_dirs(root):
            p = os.path.join(d, sid + ".jsonl")
            if os.path.isfile(p) and not (denied and denied(p)):
                return _session(p, True)
    cands = transcripts(root, denied)
    for _mtime, _size, p in cands[:PROBE_LIMIT]:
        if not _headless(p):
            return _session(p, False)
    return _session(cands[0][2], False) if cands else None


def resolve(root, denied=None, ttl=DIR_SCAN_TTL_S):
    """The Session the instance serving `root` reads (rules above), or None. Never raises on a
    missing / unreadable project dir."""
    if not isinstance(root, str) or not root:
        return None
    ids = inherited_ids()
    key = (project_dirs(root), ids, denied)
    now = time.monotonic()
    with _LOCK:
        hit = _SELECT.get(key)
        if ttl > 0 and hit is not None and now - hit[0] < ttl:
            return hit[1]
        session = _pick(root, ids, denied)
        if len(_SELECT) > 64:
            _SELECT.clear()
        _SELECT[key] = (now, session)
        return session

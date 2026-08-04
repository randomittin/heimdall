#!/usr/bin/env python3
"""hmd_ledger — the STATUSLINE LEDGER READER (Wave 1).

This module is how the full-bleed statusline CONSUMES the coordination ledger. It
is a READER ONLY: it never writes status.json (the writer lives in
bin/heimdall-status-json / an extended hmd-gate-event.sh). Its single public entry
is `read_status(session_id)`, which returns a NORMALIZED dict the statusline renders
directly, served through a per-session 5-second file cache.

SOURCE (spec §6):  ${HEIMDALL_HOME:-~/.heimdall}/ledger/status.json
    {
      "daemon": <bool|str>,                         # liveness (informational)
      "gates":  [{"id","state","detail"}, ...],     # the check/circle/cross render feed
      "verdict":{"state","label"},                  # the headline gate verdict
      "team":   [{"user","sigil","branch","state","ts"}, ...]  # presence mirror
    }

NORMALIZED RETURN SHAPE (what read_status hands the statusline):
    {
      "daemon":  "up" | "down",
      "gates":   [{"id":str, "state":"pass"|"running"|"deny", "detail":str}, ...],
      "verdict": {"state":"pass"|"running"|"deny", "label":str} | None,
      "team":    [{"user","sigil","branch","state","ts"}, ...],   # <=3, self-excluded
      "team_overflow": int,                                       # the "+N" count
    }

DEGRADE-NOT-CRASH (spec §6): a missing file OR malformed JSON OR non-dict content
yields the SAFE DEFAULT {daemon:"down", gates:[], verdict:None, team:[], team_overflow:0}.
Nothing here ever raises — the statusline must never break on ledger reads.

LEGACY FALLBACK: when the new status.json is ABSENT, the old single-verdict
${HEIMDALL_STATE:-<cwd>/.heimdall/statusline.json} {verdict,passed,total,gate,ts}
is mapped into the normalized shape, so the reader works before the new writer is
wired everywhere. (A malformed/present new status.json does NOT fall back — that is
a corrupt live source, reported as the safe default, per the spec's "malformed →
safe default" clause.)

DAEMON NOTE (plan reconciliation): there is NO daemon today; the writer emits
`daemon:false` as a literal. The `daemon` field is REPORTED ("down" for false/absent)
but does NOT blank gates/verdict/team — those are consumed whenever the file parses,
or the whole status.json feature would never render. The degradation "daemon down"
trigger collapses into "no usable data" (missing/malformed).

CACHE (spec §5): read_status caches the fully-normalized dict to a per-session file
`${HMD_STATUSLINE_TMP:-/tmp}/hmd-statusline-ledger-<session_id>` with a 5s mtime TTL.
Keyed by SESSION_ID, never the pid — the statusline is a fresh process per render, so
an in-process cache would never hit; a session-keyed file survives renders. A distinct
`-ledger-` filename is used so this JSON cache never clobbers the statusline's own
whole-line text cache (which shares the `hmd-statusline-<session_id>` prefix). Writes
are atomic (tmp + os.replace) and never raise.

stdlib only.
"""

import json
import os
import re
import subprocess
import tempfile
import time

# ── tunables ─────────────────────────────────────────────────────────────────
CACHE_TTL = 5.0            # spec §5 — whole-read cache lifetime, seconds
TEAM_TTL = 300             # spec §6 — a teammate heartbeat reads LIVE for 5 minutes
TEAM_CAP = 3               # spec §6 — at most 3 names, then a "+N" overflow

# ── the OFFLINE WALL WINDOW (mirrors cp_presence.DEFAULT_OFFLINE_WINDOW_SECONDS) ──
# A teammate whose last heartbeat is within this window keeps a wall slot and renders in an
# explicit OFFLINE state; past it they leave the wall. TEAM_TTL above still decides LIVE vs
# OFFLINE — this only decides who gets a slot AT ALL. Before this window existed an offline
# teammate was simply erased, so a wall showing only yourself looked exactly like a broken
# wall; that ambiguity is what this closes. Must stay in step with the server constant.
OFFLINE_WINDOW = 7 * 24 * 60 * 60.0   # 7 days

_MOD_DIR = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_MOD_DIR)   # <repo>/sentinels/hmd_ledger.py → <repo>

# gate/verdict state words → the 3 render states the statusline knows (check/circle/cross).
_STATE_ALIASES = {
    "pass": "pass", "passed": "pass", "green": "pass", "ok": "pass", "success": "pass",
    "deny": "deny", "denied": "deny", "fail": "deny", "failed": "deny",
    "red": "deny", "blocked": "deny", "closed": "deny",
    "run": "running", "running": "running", "scan": "running", "scanning": "running",
    "watching": "running", "watch": "running", "idle": "running", "pending": "running",
    "working": "running",
}

SAFE_DEFAULT = {"daemon": "down", "gates": [], "verdict": None,
                "team": [], "team_overflow": 0}


# ── paths (all env-overridable for isolation + testability) ───────────────────
def _home():
    return os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")


def _status_path():
    """The new ledger source: ${HEIMDALL_HOME:-~/.heimdall}/ledger/status.json."""
    return os.path.join(_home(), "ledger", "status.json")


def _legacy_path():
    """The old single-verdict source (back-compat). Honors HEIMDALL_STATE exactly like
    hmd-statusline.py's gate_state(), else <cwd>/.heimdall/statusline.json."""
    return os.environ.get("HEIMDALL_STATE") or os.path.join(os.getcwd(), ".heimdall", "statusline.json")


def _cache_dir():
    return os.environ.get("HMD_STATUSLINE_TMP") or "/tmp"


def _cache_path(session_id):
    """`<tmp>/hmd-statusline-ledger-<slug>`. Session-keyed, filesafe, never pid-keyed.
    An empty/absent session_id (older CC stdin) collapses to a stable 'default' key —
    a 5s cache-key collision is harmless, and we still never key on the pid."""
    slug = re.sub(r"[^A-Za-z0-9._-]", "-", str(session_id or "").strip()) or "default"
    return os.path.join(_cache_dir(), "hmd-statusline-ledger-" + slug)


def _now():
    """Wall clock, overridable via HMD_NOW for deterministic conformance (the same knob
    the eye animation + usage indicator use)."""
    env = os.environ.get("HMD_NOW")
    if env:
        try:
            return float(env)
        except Exception:
            return time.time()
    return time.time()


# ── normalization helpers ─────────────────────────────────────────────────────
def _norm_state(v):
    """Any gate/verdict state word → pass|running|deny. Unknown → running (the neutral
    'in progress' render), never a fabricated pass or deny."""
    return _STATE_ALIASES.get(str(v if v is not None else "").strip().lower(), "running")


def _norm_daemon(v):
    """Liveness → 'up'|'down'. true/'up'/'alive'/'running'/'on' → up; everything else
    (false, absent, 'down', junk) → down."""
    if v is True:
        return "up"
    if isinstance(v, str) and v.strip().lower() in ("up", "alive", "running", "true", "on"):
        return "up"
    return "down"


def normalize_gate(g):
    """One raw gate → {id, state∈(pass|running|deny), detail}. Tolerates missing keys and
    non-dict junk (→ a running gate with an empty id/detail) so a corrupt gate never crashes
    the render."""
    if not isinstance(g, dict):
        return {"id": "", "state": "running", "detail": ""}
    gid = g.get("id")
    if gid is None:
        gid = g.get("name")   # tolerate the legacy {name,status} shape
    detail = g.get("detail")
    if detail is None:
        detail = ""
    state = g.get("state")
    if state is None:
        state = g.get("status")
    return {"id": str(gid if gid is not None else ""),
            "state": _norm_state(state),
            "detail": str(detail)}


def _norm_verdict(v):
    """Raw verdict → {state, label} | None. Accepts the {state,label} object shape or a
    bare state string; anything empty/None → None (render nothing, never a fake verdict)."""
    if isinstance(v, dict):
        state = v.get("state")
        if state is None and v.get("label") is None:
            return None
        label = v.get("label")
        return {"state": _norm_state(state), "label": str(label) if label is not None else ""}
    if isinstance(v, str) and v.strip():
        return {"state": _norm_state(v), "label": v.strip()}
    return None


# ── self identity (for the team self-exclude) ────────────────────────────────
def _self_ids():
    """The set of identifiers that mean 'me', used to drop self from the team cluster.
    Resolves through the canonical identity helper (bin/heimdall-identity — SEED + handle),
    then env (HMD_HANDLE/HMD_HAID) and the identity.json store it reads, then $USER. Every
    probe is best-effort; the identity bin is only invoked on a cache MISS (<= once per 5s),
    and its absence/failure falls through to the file + env chain (no fork required)."""
    ids = set()
    for k in ("HMD_HANDLE", "HMD_HAID"):
        v = os.environ.get(k)
        if v:
            ids.add(v.strip())
    bin_id = os.path.join(_ROOT, "bin", "heimdall-identity")
    if os.access(bin_id, os.X_OK):
        for args in ([bin_id], [bin_id, "--handle"]):
            try:
                r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   timeout=0.5)
                v = r.stdout.decode("utf-8", "replace").strip()
                if v:
                    ids.add(v)
            except Exception:
                continue   # bin absent / jq missing / timeout → file + env cover it
    idir = os.environ.get("HEIMDALL_IDENTITY_DIR") or os.path.join(os.getcwd(), ".heimdall")
    try:
        with open(os.path.join(idir, "identity.json")) as f:
            d = json.load(f)
        if isinstance(d, dict):
            for k in ("handle", "seed", "haid"):
                if d.get(k):
                    ids.add(str(d[k]))
    except Exception:
        d = None   # identity.json absent/unreadable → env + bin cover it
    u = os.environ.get("USER")
    if u:
        ids.add(u.strip())
    return ids


def filter_team(team, now=None, self_ids=None, cap=TEAM_CAP, ttl=TEAM_TTL,
                window=OFFLINE_WINDOW):
    """Spec §6 team cluster. From the raw team[] keep entries whose heartbeat `ts` is within
    `window` seconds of `now` (7 days) and that are NOT self, normalize each to
    {user,haid,sigil,branch,state,ts,online}, order them, then cap to `cap` names.
    Returns (members[<=cap], overflow_count).

    LIVE vs OFFLINE. An entry is LIVE when the producer marked it `online: true`, or — for a
    producer that predates the flag — when its heartbeat is within `ttl` (5 min). Anything
    older keeps its slot with `online: False` and the explicit state "offline", so an away
    teammate renders greyed instead of VANISHING. That erasure is the defect this closes: a
    wall showing only yourself used to be indistinguishable from a wall that was broken.

    An offline entry's state is pinned to "offline" and never sent through _norm_state, which
    maps anything unknown to "running" — that would paint an away teammate as actively
    working. Offline must never be a subtly-different online.

    ORDER: LIVE first, then deny (the screenshot signal the statusline reds), then freshest.
    So an offline teammate can never evict a live one from the `cap` slots."""
    if now is None:
        now = _now()
    if self_ids is None:
        self_ids = _self_ids()
    if not isinstance(team, list):
        return [], 0
    live = []
    for e in team:
        if not isinstance(e, dict):
            continue
        ts = e.get("ts")
        if not isinstance(ts, (int, float)) or isinstance(ts, bool):
            continue
        if now - ts > window:
            continue   # beyond the offline window → teammate has left the wall for good
        user = e.get("user")
        sigil = e.get("sigil")
        haid = e.get("haid")
        # self-exclude: match on any identifier the entry carries
        if any(v is not None and str(v) in self_ids for v in (user, sigil, haid)):
            continue
        # The producer's explicit flag wins; absent it, the 5-min heartbeat TTL decides
        # (back-compat with a status.json written before `online` was carried through).
        flag = e.get("online")
        online = bool(flag) if isinstance(flag, bool) else (now - ts <= ttl)
        live.append({
            "user": str(user) if user is not None else "",
            # preserve the teammate's OWN HAID so the statusline can render THEIR sigil
            # hero (hero_for/pin), not one hardcoded hero recolored for the whole team.
            "haid": str(haid) if haid is not None else "",
            "sigil": str(sigil) if sigil is not None else "",
            "branch": str(e.get("branch") or ""),
            "state": _norm_state(e.get("state")) if online else "offline",
            "ts": ts,
            "online": online,
        })
    # LIVE FIRST, then DENY, then freshest. A gate-deny is the screenshot signal the statusline
    # reds — it must never be silently capped out below fresher passing teammates; and no
    # offline teammate may ever displace a live one.
    live.sort(key=lambda m: (not m["online"], m["state"] != "deny", -m["ts"]))
    overflow = max(0, len(live) - cap)
    return live[:cap], overflow


# ── legacy fallback ────────────────────────────────────────────────────────
def _map_legacy():
    """Map the old .heimdall/statusline.json {verdict,passed,total,gate,ts} into the
    normalized shape (used ONLY when the new status.json is absent). Returns a normalized
    dict, or None when the legacy file is also missing/corrupt (→ caller uses SAFE_DEFAULT)."""
    try:
        with open(_legacy_path()) as f:
            d = json.load(f)
    except Exception:
        return None
    if not isinstance(d, dict):
        return None
    verdict = d.get("verdict")
    passed, total = d.get("passed"), d.get("total")
    detail = ""
    if isinstance(passed, int) and isinstance(total, int):
        detail = "%d/%d" % (passed, total)
    gate_id = str(d.get("gate") or "gate")
    state = _norm_state(verdict)
    return {
        "daemon": "down",   # no daemon behind the legacy file
        "gates": [{"id": gate_id, "state": state, "detail": detail}],
        "verdict": {"state": state, "label": detail or (str(verdict) if verdict else "")},
        "team": [],
        "team_overflow": 0,
    }


# ── cache (atomic, never-raising, session-keyed) ─────────────────────────────
def _cache_get(session_id):
    """Return the cached normalized dict when the cache file is < CACHE_TTL old, else None.
    Reads the cache file — never the source status.json — so a hit proves the source was
    not re-read this render."""
    p = _cache_path(session_id)
    try:
        age = time.time() - os.path.getmtime(p)
        if age > CACHE_TTL:
            return None
        with open(p) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def _cache_put(session_id, data):
    """Atomically persist the normalized dict for the session (tmp + os.replace). Best-effort:
    a cache write failure just means the next render re-reads the source."""
    p = _cache_path(session_id)
    d = os.path.dirname(p) or "."
    try:
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".hmd-ledger.", dir=d)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(data, f)
            os.replace(tmp, p)
        finally:
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except Exception:
                tmp = None   # tmp already consumed by os.replace / unlink raced — fine
    except Exception:
        return None


# ── the source read (uncached) ────────────────────────────────────────────
def _read_source():
    """Read + normalize the ledger source. status.json present & parseable → normalize it;
    present but malformed/non-dict → SAFE_DEFAULT (corrupt live source); absent → the legacy
    fallback, else SAFE_DEFAULT. Never raises."""
    sp = _status_path()
    if os.path.exists(sp):
        try:
            with open(sp) as f:
                d = json.load(f)
        except Exception:
            return dict(SAFE_DEFAULT)         # malformed live source → safe default
        if not isinstance(d, dict):
            return dict(SAFE_DEFAULT)
        gates_raw = d.get("gates")
        gates = [normalize_gate(g) for g in gates_raw] if isinstance(gates_raw, list) else []
        members, overflow = filter_team(d.get("team"))
        return {
            "daemon": _norm_daemon(d.get("daemon")),
            "gates": gates,
            "verdict": _norm_verdict(d.get("verdict")),
            "team": members,
            "team_overflow": overflow,
        }
    legacy = _map_legacy()                    # new file absent → try the legacy single-verdict
    return legacy if legacy is not None else dict(SAFE_DEFAULT)


# ── public entry ───────────────────────────────────────────────────────────
def read_status(session_id):
    """Return the normalized ledger dict for the statusline, served through the per-session
    5s cache. On a cache HIT (< 5s) the cached dict is returned without touching the source
    status.json; on a MISS the source (or legacy) is read, normalized, cached, and returned.
    Never raises — degrades to SAFE_DEFAULT on any fault."""
    cached = _cache_get(session_id)
    if cached is not None:
        return cached
    data = _read_source()
    _cache_put(session_id, data)
    return data


if __name__ == "__main__":   # tiny CLI for manual inspection: hmd_ledger.py [session_id]
    import sys
    sid = sys.argv[1] if len(sys.argv) > 1 else ""
    print(json.dumps(read_status(sid), indent=2, ensure_ascii=False))

#!/usr/bin/env python3
"""hmd_ledger — the STATUSLINE LEDGER READER (Wave 1).

This module is how the full-bleed statusline CONSUMES the coordination ledger. It
is a READER ONLY: it never writes status.json (the writer lives in
bin/heimdall-status-json / an extended hmd-gate-event.sh). Its single public entry
is `read_status(session_id)`, which returns a NORMALIZED dict the statusline renders
directly, served through a per-session 5-second file cache.

SOURCE (spec §6; per-repo since the mirror-race fix — docs/analysis/2026-08-29-statusline-
roster-inflation.md):
    ${HEIMDALL_HOME:-~/.heimdall}/ledger/repos/<repo_key>.json   preferred: one file PER repo
    ${HEIMDALL_HOME:-~/.heimdall}/ledger/status.json             legacy: machine-global, kept
                                                                  as a migration fallback only
    {
      "daemon": <bool|str>,                         # liveness (informational)
      "gates":  [{"id","state","detail"}, ...],     # the check/circle/cross render feed
      "verdict":{"state","label"},                  # the headline gate verdict
      "team":   [{"user","sigil","branch","state","ts"}, ...],  # presence mirror
      "repo":   "<abs repo root>"                   # WHICH repo team[] is the roster OF
    }
<repo_key> comes from repo_key() below (SHA256[:16] of the realpath'd git root). The writer
(bin/heimdall-status-json) imports this exact function so the two sides can never compute
different paths for the same tree — see repo_key()'s docstring for why a hash was chosen
over a sanitized path string.

SCOPE (why `repo` is STILL carried, even though the mirror is per-repo now). The legacy
global path above is a REAL fallback tier — an install whose writer has not beaten once
since this fix landed, or an explicit HMD_STATUS_OUT/--out override — so a foreign repo's
roster can still transiently reach a reader through it, same as before this fix. `team` is
only ever the roster of ONE project regardless of which tier answered. This module CARRIES
the stamp and never interprets it; the renderer compares it against the tree it is painting.
An absent stamp means UNKNOWN scope, never "all repos" — `_ledger_in_scope` in
hmd-statusline.py stays as defense-in-depth for exactly this tier.

NORMALIZED RETURN SHAPE (what read_status hands the statusline):
    {
      "daemon":  "up" | "down",
      "gates":   [{"id":str, "state":"pass"|"running"|"deny", "detail":str}, ...],
      "verdict": {"state":"pass"|"running"|"deny", "label":str} | None,
      "team":    [{"user","sigil","branch","state","ts"}, ...],   # <=3, self-excluded
      "team_overflow": int,                                       # the "+N" count
      "repo":    str,                          # the team's scope; "" = UNKNOWN, never "all"
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

import hashlib
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
                "team": [], "team_overflow": 0, "repo": ""}


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


def _git_root(path):
    """Walk up from `path` looking for a `.git` marker (a dir, for a normal checkout, or a
    `gitdir:` FILE, for a linked worktree) and stop at the directory that has one — mirrors
    hmd-statusline.py's _git_branch() walk (minus the HEAD parse) so the per-repo key below
    never forks `git` on the statusline's hot path. realpath'd first so a symlinked cwd and
    its resolved twin always hash to the SAME key — the same realpath-before-compare
    convention _ledger_in_scope() already uses in hmd-statusline.py. No `.git` found within
    64 levels (or any error resolving `path`) -> the realpath'd (or abspath'd) starting dir
    itself, so callers always get a stable, hashable anchor rather than None."""
    try:
        d = os.path.realpath(path or ".")
    except Exception:
        d = os.path.abspath(path or ".")
    start = d
    for _ in range(64):
        gitpath = os.path.join(d, ".git")
        if os.path.isdir(gitpath) or os.path.isfile(gitpath):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return start


def repo_key(repo):
    """THE single place the per-repo mirror key is derived. Imported by BOTH sides — this
    reader and bin/heimdall-status-json's writer heredoc (via the same sys.path.insert onto
    this sentinels/ dir it already uses for hmd_sigil) — so the two can never independently
    drift onto different keys for the same tree.

    SHA256 of the realpath'd git root, truncated to 16 hex chars (64 bits), NOT a sanitized
    path string: a lossy substitution like `/` -> `-` collides two genuinely different repos
    (`/a/b-c` and `/a/b/c` both become `-a-b-c`), and an unbounded path risks a filesystem
    filename-length limit on a deeply nested checkout. 64 bits of a cryptographic digest
    makes an accidental collision across every repo ever hashed on one machine astronomically
    unlikely, and human-readability is not needed here — the mirror file's own `repo` field
    already carries the readable path for anyone inspecting it by hand."""
    root = _git_root(repo or os.getcwd())
    return hashlib.sha256(root.encode("utf-8", "surrogateescape")).hexdigest()[:16]


def status_path_for(repo):
    """Per-repo mirror path: ${HEIMDALL_HOME:-~/.heimdall}/ledger/repos/<repo_key>.json.
    Structurally replaces the single machine-global slot every repo's presence keeper used
    to fight over (docs/analysis/2026-08-29-statusline-roster-inflation.md) with one file
    PER repo, so that race is impossible by construction rather than merely detected after
    the fact by _ledger_in_scope's scope check (which stays, as defense-in-depth — see the
    module docstring's SCOPE section)."""
    return os.path.join(_home(), "ledger", "repos", repo_key(repo) + ".json")


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
        # ONE fork, not two: --json carries both SEED and HANDLE from the exact same
        # resolve_seed()/resolve_handle() heimdall-identity already runs internally
        # for its bare and --handle arms (see bin/heimdall-identity) — forking it
        # twice here computed the identical resolution twice. Each fork pays its own
        # bash+jq(+heimdall-haid, on a cold identity file) startup cost, so this was
        # measured (cProfile, cold identity file) at ~0.36s of a ~1.1s cold render —
        # more than the statusline's OWN identity() call. Timeout doubled (0.5 -> 1.0)
        # since this single call now does the work the two calls used to split.
        try:
            r = subprocess.run([bin_id, "--json"], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=1.0)
            d = json.loads(r.stdout.decode("utf-8", "replace"))
            if isinstance(d, dict):
                for k in ("seed", "handle"):
                    v = d.get(k)
                    if isinstance(v, str) and v.strip():
                        ids.add(v.strip())
        except Exception:
            pass   # bin absent / jq missing / timeout / bad json → file + env cover it
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
        # The legacy file carries no roster at all, so there is no scope to declare.
        "repo": "",
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
def _read_source(repo=None):
    """Read + normalize the ledger source. Tries the PER-REPO mirror first (structurally
    race-free — see repo_key()/status_path_for()), then the legacy machine-global mirror
    (an install whose writer has not beaten since this fix landed, or an explicit
    HMD_STATUS_OUT/--out override), stopping at the FIRST of the two that exists. status.json
    present & parseable → normalize it; present but malformed/non-dict → SAFE_DEFAULT (a
    corrupt LIVE source — deliberately does NOT fall through to the next tier, so a corrupt
    per-repo mirror can never silently paint a different repo's stale global roster); every
    tier absent → the legacy single-verdict fallback, else SAFE_DEFAULT. Never raises."""
    for sp in (status_path_for(repo), _status_path()):
      if not os.path.exists(sp):
          continue
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
          # WHICH repo team[] is the roster of. Carried, never interpreted here: this reader
          # has no idea which tree is being rendered. The renderer compares it against the
          # tree it is painting and drops the mirror when they differ. Absent/unusable → ""
          # (UNKNOWN), which the renderer fails CLOSED on.
          "repo": str(d.get("repo") or ""),
      }
    legacy = _map_legacy()          # both mirror tiers absent → try the legacy single-verdict
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

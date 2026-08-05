#!/usr/bin/env python3
"""hmd_wall — the REPO WALL reader: everyone who works on this repo, ranked.

THE DEFECT THIS CLOSES. `bin/lib/repo_roster.py` landed and returns the WHOLE repo roster —
for the owner's repo, 23 people across four tiers. The statusline never read it
(`grep -rc repo_roster sentinels/` was 0), so the wall rendered ONE person and an empty
slot. The data to show a populated team already existed and was simply unread. This module
is the seam that consumes it.

WHY A CACHE AND NOT A CALL. repo_roster.build() costs ~62ms warm — it is dominated by the
O(n²) identity unification (2203 would_merge / 90k fold calls for 23 people), which is pure
CPU and cannot be cached away inside it. The statusline runs on EVERY prompt and its warm
render median is 0.7ms, so calling build() on the render path would be an ~85x keystroke
latency regression. So the split is:

    detached child (throttled, off the hot path)  →  writes <repo>/.heimdall/.wall-cache.json
    the renderer                                  →  ONE json.load of that file

read_wall() is therefore a PURE FILE READ: no subprocess, no `gh`, no `git`, no network, no
unbounded log. Everything here is O(people) over an already-computed array.

THE ANTI-FABRICATION RULE (the property the whole wall exists to protect). A viewer must
NEVER read a non-present person as present. The wall cache is a SNAPSHOT — by the time it is
read, its `online` flag may be up to WALL_CACHE_TTL stale, which is far longer than the 45s
presence TTL. So:

    PRESENCE IS DECIDED EXCLUSIVELY BY THE LIVE PRESENCE CACHE, NEVER BY THE WALL CACHE.

overlay_presence() re-decides the present tense from the short-TTL presence roster the
statusline already maintains (<repo>/.heimdall/.roster-cache.json, 4s). A cached `online`
row with no live, fresh, key-matched heartbeat behind it is DEMOTED to `away`. The wall
cache's own `online`/`last_seen_ts` fields are never trusted to assert presence — they only
ever say who to ASK about. An absent or malformed field therefore shows LESS, never a
synthesised online.

Promotion the other way IS allowed, because it is backed by the freshest real data: a
contributor who is live right now, or a teammate who joined since the last refresh, is
unioned in as online from the live cache. That is not fabrication — it is the live source
outranking a stale snapshot.

TIERS (the frozen contract from repo_roster, ranked most- to least-present):
    online       a presence heartbeat inside the online TTL   (needs the repo team secret)
    contributed  a commit inside the git window, any branch   (git only, no control plane)
    away         seen inside the 7-day presence window        (needs the repo team secret)
    member       a GitHub collaborator with no recent signal  (gh only, no control plane)

Only `online` and `away` need the control plane, so a POPULATED wall works today — before a
control-plane redeploy and before teammates update their hmd — off git + the GitHub
collaborator list alone.

stdlib only. Nothing here raises: every entry point degrades to the empty/least-present
answer so the statusline can never crash, hang, or blank the line.
"""

import json
import os
import time

# ── tunables ─────────────────────────────────────────────────────────────────────
# The wall cache holds the SLOW tiers (git history + the GitHub collaborator list), which
# move on the scale of hours. 15 minutes keeps it warm without ever forking per prompt; the
# fast tier (presence) is re-decided live on every render and is NOT bounded by this.
WALL_CACHE_TTL = 900.0

# Mirrors cp_presence's online TTL. A heartbeat older than this is NOT present, full stop.
ONLINE_TTL = 45.0

# Mirrors hmd_ledger.OFFLINE_WINDOW / cp_presence.DEFAULT_OFFLINE_WINDOW_SECONDS. A teammate
# seen inside this window keeps a wall slot as `away`; past it they leave the wall for good,
# so the wall stays a roster and never becomes a graveyard.
OFFLINE_WINDOW = 7 * 24 * 60 * 60.0

# repo_roster's tier vocabulary, in RANK ORDER (most present first). This ordering is what
# makes the `+N` overflow tag SAFE: an online person always sorts above a non-present one, so
# nobody who is actually here can ever be the one hidden behind the count.
TIER_ORDER = ("online", "contributed", "away", "member")
TIER_RANK = {t: i for i, t in enumerate(TIER_ORDER)}

# The ONE tier that means "this person is here right now". Everything else is absent, and the
# renderer drains the identity hue out of all of them.
PRESENT_TIER = "online"

# An unknown/absent tier degrades to the LEAST present tier — show less, never more.
_FALLBACK_TIER = "member"


def wall_cache_path(repo):
    """The precomputed roster the detached child writes and the renderer reads."""
    return os.path.join(repo or ".", ".heimdall", ".wall-cache.json")


def _num(value):
    """A real timestamp, or None. Booleans are not numbers here (bool is an int subclass)."""
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


def read_wall(repo, path=None):
    """The precomputed roster rows, or [] on ANY fault.

    Pure file read — the whole point of this module. A missing cache (never refreshed yet),
    malformed JSON (a torn write), or a non-list payload (a contract break) all read as [],
    which the renderer treats as "fall back to the presence-only wall". Junk ROWS inside an
    otherwise valid array are dropped individually so one bad record cannot cost the wall
    everyone else.
    """
    try:
        with open(path or wall_cache_path(repo)) as f:
            raw = json.load(f)
    except Exception:
        return []
    if not isinstance(raw, list):
        return []
    out = []
    for r in raw:
        if not isinstance(r, dict):
            continue
        handle = r.get("handle")
        if handle is None or not str(handle).strip():
            continue
        tier = r.get("tier")
        if tier not in TIER_RANK:
            tier = _FALLBACK_TIER
        out.append({
            "handle": str(handle).strip(),
            "haid": str(r["haid"]) if r.get("haid") else "",
            "tier": tier,
            # NOT trusted to assert presence — overlay_presence re-decides it from the live
            # cache. Carried only so a caller can see what the snapshot believed.
            "online": r.get("online") is True,
            "last_seen_ts": _num(r.get("last_seen_ts")),
            "last_commit_ts": _num(r.get("last_commit_ts")),
            # Display only — never an identity key, never a presence fact. A branch name is
            # repo metadata, so carrying it reveals nothing a git log would not.
            "last_branch": str(r.get("last_branch") or ""),
            "sources": [str(s) for s in (r.get("sources") or []) if s],
        })
    return out


def refresh_due(repo, ttl=WALL_CACHE_TTL, path=None, now=None, producer=None):
    """True when the wall cache is COLD, older than `ttl`, or OLDER THAN ITS PRODUCER.

    Stat-only, so asking is free: a fresh cache means the render forks NOTHING. This is what
    keeps the 62ms roster build off the hot path without letting the wall go stale.

    THE PRODUCER RULE (`producer` = the path of the roster lib the refresh child runs).
    A cache keyed only on TIME is a second source of truth: it outlives the code that made
    it. That shipped — repo_roster gained the identity merge at 10:07 while the wall cache
    had been written at 10:05, so for the next fifteen minutes the renderer served the
    PRE-FIX snapshot and put the owner on his own wall as a second person, while the roster
    CLI run against the same repo in the same second returned one row.

    This cache is a MEMO of repo_roster.build(), so its key must include the identity of the
    function it memoises, not just the clock. A producer mtime NEWER than the snapshot means
    the snapshot came out of a previous version of that function → COLD, whatever its age.
    One `stat` (microseconds, no read, no hash), and the next render's already-throttled
    child rewrites the cache with the current code. That is what leaves exactly ONE code
    path — today's build() — deciding who is on the wall.

    An unstattable producer degrades to the plain age rule: a wall that is merely stale is a
    far smaller fault than a wall that forks a roster build on every single prompt.
    """
    p = path or wall_cache_path(repo)
    when = float(now) if now is not None else time.time()
    try:
        cached_at = os.path.getmtime(p)
    except Exception:
        return True   # absent/unstattable → cold, so the child should warm it
    if producer:
        try:
            if os.path.getmtime(producer) > cached_at:
                return True
        except Exception:
            pass      # no producer to compare against → the age rule alone decides
    return (when - cached_at) > float(ttl)


def _live_index(live, when, online_ttl):
    """Index the live presence rows by every identifier they carry → (entry, is_fresh).

    `is_fresh` is the ONLY thing that may assert presence: the producer's explicit online
    flag AND a heartbeat inside the online TTL. Both, never either.
    """
    index = {}
    for e in live or []:
        if not isinstance(e, dict):
            continue
        ts = _num(e.get("ts"))
        fresh = e.get("online") is True and ts is not None and (when - ts) <= online_ttl
        for key in (e.get("haid"), e.get("name"), e.get("handle")):
            if key and str(key) not in index:
                index[str(key)] = (e, fresh)
    return index


def _from_live(entry, fresh, when):
    """One live presence entry → a roster row. Used for devs the wall cache has not seen yet."""
    ts = _num(entry.get("ts"))
    return {
        "handle": str(entry.get("name") or entry.get("handle") or entry.get("haid") or "?"),
        "haid": str(entry.get("haid") or ""),
        "tier": PRESENT_TIER if fresh else "away",
        "online": bool(fresh),
        "last_seen_ts": ts,
        "last_commit_ts": None,
        "sources": ["presence"],
        "verdict": str(entry.get("verdict") or "") if fresh else "",
        "branch": str(entry.get("branch") or "") if fresh else "",
    }


def overlay_presence(rows, live, now=None, online_ttl=ONLINE_TTL, window=OFFLINE_WINDOW):
    """Re-decide the PRESENT TENSE from the live presence cache. The anti-fabrication seam.

    For every roster row, presence is resolved by looking the person up in `live` (the short-
    TTL presence roster) by haid then handle:
      • a fresh, key-matched heartbeat  → `online`, carrying the LIVE verdict + branch,
      • anything else                   → NOT online. A row the snapshot called `online`
                                          demotes to `away`; a git/github row simply stays
                                          where it is.
    The wall cache can therefore never, by itself, put a present-tense person on the wall.

    Live devs the snapshot has not seen yet are UNIONED in (fresh → online, stale-but-inside
    the 7-day window → away), so a COLD wall cache still renders exactly today's presence
    wall rather than nothing. Never raises.
    """
    when = float(now) if now is not None else time.time()
    index = _live_index(live, when, online_ttl)
    out, used = [], set()
    for r in rows or []:
        if not isinstance(r, dict):
            continue
        row = dict(r)
        entry, fresh = None, False
        for key in (row.get("haid"), row.get("handle")):
            if key and str(key) in index:
                entry, fresh = index[str(key)]
                used.add(id(entry))
                break
        if fresh:
            # Backed by a live heartbeat — the freshest real source outranks the snapshot.
            row["tier"] = PRESENT_TIER
            row["online"] = True
            row["last_seen_ts"] = _num(entry.get("ts"))
            row["verdict"] = str(entry.get("verdict") or "")
            row["branch"] = str(entry.get("branch") or "")
        else:
            row["online"] = False
            row["verdict"] = ""
            row["branch"] = ""
            if row.get("tier") in (PRESENT_TIER, "away"):
                # A presence tier with no live backing is AWAY, never online. This is the
                # demotion that stops a stale snapshot from inventing a present teammate.
                row["tier"] = "away"
                if entry is not None:
                    row["last_seen_ts"] = _num(entry.get("ts")) or row.get("last_seen_ts")
        out.append(row)
    for e in live or []:
        if not isinstance(e, dict) or id(e) in used:
            continue
        ts = _num(e.get("ts"))
        if ts is None or (when - ts) > window:
            continue   # outside the 7-day wall window → not a member of this wall at all
        _entry, fresh = index.get(str(e.get("haid") or e.get("name") or ""), (e, False))
        out.append(_from_live(e, fresh, when))
    return out


def _tier_ts(row):
    """The timestamp the row's TIER is actually about — so the rendered age never lies.

    online/away → the last heartbeat ("away 3d" = not seen for 3 days).
    contributed → the last COMMIT  ("git 3d"  = last committed 3 days ago).
    member      → nothing; there is no signal, which is exactly what the tier means.
    """
    tier = row.get("tier")
    if tier == "contributed":
        return _num(row.get("last_commit_ts"))
    if tier in (PRESENT_TIER, "away"):
        return _num(row.get("last_seen_ts"))
    return None


def _sort_key(m):
    """Rank, then most-recent-first within the rank, then a stable name tiebreak.

    Mirrors repo_roster's own ordering so the wall shows people in the same order the roster
    ranks them: present first, then the freshest contributors.
    """
    ts = m.get("ts")
    return (TIER_RANK.get(m.get("tier"), len(TIER_ORDER)),
            -(ts if isinstance(ts, float) else 0.0),
            m.get("user") or "")


def wall_members(rows, self_ids=None, now=None, cap=None):
    """Roster rows → the member dicts the statusline's team_columns() renders.

    Returns (members, overflow). SELF is excluded — you are the big hero sigil on the left,
    not a column on your own wall. With no `cap`, overflow is 0 and every person is returned;
    the caller's layout decides how many columns actually fit and discloses the rest as `+N`.

    Each member carries its `tier` so the renderer can pick the right glyph+word, its OWN
    haid so its sigil resolves to THAT person's hero, and a `ts` that means whatever the tier
    is about (see _tier_ts) so a rendered age is never a different clock than its label.
    """
    when = float(now) if now is not None else time.time()
    ids = {str(s) for s in (self_ids or set()) if s}
    members = []
    for r in rows or []:
        if not isinstance(r, dict):
            continue
        handle = str(r.get("handle") or "").strip()
        haid = str(r.get("haid") or "")
        if not handle:
            continue
        if (handle and handle in ids) or (haid and haid in ids):
            continue
        tier = r.get("tier") if r.get("tier") in TIER_RANK else _FALLBACK_TIER
        online = tier == PRESENT_TIER
        members.append({
            "user": handle,
            "haid": haid,
            "sigil": "",
            # Only a PRESENT dev may carry a branch onto the wall. A contributor's branch is
            # a fact about their last commit, and `⎇feature/x` under a name reads as someone
            # working on it right now — the exact misread this wall exists to prevent.
            "branch": str(r.get("branch") or "") if online else "",
            # A SECOND, deliberately separate key. `branch` above stays PRESENT-ONLY because a
            # bare `⎇feature/x` under a name reads as someone working on it right now.
            # `last_branch` is the historical fact and is only ever rendered inside the faint
            # absent segment, WITH the age — `⌁fix/mdr-preview 16h` cannot be misread as
            # presence the way a bare branch can. Two keys, because they mean different things:
            # collapsing them is what would reintroduce the misread.
            "last_branch": str(r.get("last_branch") or ""),
            "state": str(r.get("verdict") or "") if online else tier,
            "ts": _tier_ts(r),
            "online": online,
            "tier": tier,
        })
    members.sort(key=_sort_key)
    if cap is None or cap >= len(members):
        return members, 0
    cap = max(0, int(cap))
    return members[:cap], len(members) - cap


def read_members(repo, live=None, self_ids=None, now=None, cap=None, path=None):
    """The one call the renderer makes: cache → live presence overlay → ranked members.

    Every stage degrades independently, so a fault anywhere costs detail and never the line.
    """
    when = float(now) if now is not None else time.time()
    try:
        rows = overlay_presence(read_wall(repo, path=path), live, now=when)
        return wall_members(rows, self_ids=self_ids, now=when, cap=cap)
    except Exception:
        return [], 0


if __name__ == "__main__":   # manual inspection: hmd_wall.py [repo]
    import sys
    _repo = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    _m, _o = read_members(_repo)
    print(json.dumps({"members": _m, "overflow": _o}, indent=2, ensure_ascii=False))

#!/usr/bin/env bash
# heimdall-statusline-member-age.test.sh — a MEMBER-tier teammate with a real last_commit_ts
# must render an honest last-contributed age (`⌂mem 2w`), not a bare `⌂mem` — the age was being
# silently discarded even when repo_roster attached a genuine (if stale) commit timestamp.
#
# THE REPORTED DEFECT (owner, 2026-08-24): "the second line for teammates in status line shows
# o mem -- it must be the last time they contributed or were online -- like 15h or 2d".
#
# REPRODUCED FIRST, before any fix: `echo '<payload>' | COLUMNS=120 bash hooks/statusline.sh`
# against a wall-cache fixture with a member-tier teammate rendered the literal Row4 segment
# `⌂mem` — U+2302 HOUSE + the word "mem", NOT the literal text "o mem". Nothing is truncated;
# the whole word is present. The glyph is the most likely source of the owner's "o" reading
# (⌂ can render ambiguously in some terminal fonts) — a real but separate, PURELY COSMETIC
# concern this fix does not change (swapping glyphs is unrequested scope: the ask was the AGE).
#
# ROOT CAUSE, two cooperating places:
#   sentinels/hmd_wall.py       _tier_ts()   returned None for "member" tier UNCONDITIONALLY,
#                                even though bin/lib/repo_roster.py's rows() ALWAYS attaches the
#                                cluster's real last_commit_ts regardless of tier — tier_of()
#                                only assigns "member" because that commit fell outside the
#                                contributed window (or there is none), never because the field
#                                was dropped. That stale-but-real timestamp is the authoritative
#                                "last contributed" signal this fix surfaces.
#   sentinels/hmd-statusline.py TEAM_TIER["member"] pinned show_age=False, so even a non-None
#                                ts could never reach _last_seen().
#
# _last_seen() also needed a wider bucket range: "away"/"contributed" ages stay inside the 7-day
# wall/presence window in practice, but a member's last_commit_ts is UNBOUNDED (repo_roster's
# git window default is 90 days just to classify the tier; the commit itself can be years old).
# The old formatter's day bucket alone would print `400d` — 4 cells, blowing the 3-cell budget
# _team_tier_seg relies on to stay inside the 8-cell team-label strip. Extended with week/year
# buckets so every age up to a clamped 99y stays <= 3 cells.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

python3 - "$REPO" <<'PY'
import sys, re, importlib.util as u

repo = sys.argv[1]


def load(path, name):
    spec = u.spec_from_file_location(name, path)
    mod = u.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


W = load(repo + "/sentinels/hmd_wall.py", "hmd_wall_ma")
S = load(repo + "/sentinels/hmd-statusline.py", "sl_ma")

NOW = 1785900000
DAY = 86400

_p = 0
_f = 0


def ok(m):
    global _p
    _p += 1
    print("  ok   " + m)


def bad(m):
    global _f
    _f += 1
    print("  FAIL " + m)


def vis(s):
    return re.sub(r"\x1b\[[0-9;]*m", "", s)


def row(handle, tier, **kw):
    return {"handle": handle, "haid": kw.get("haid"), "tier": tier,
            "online": tier == "online",
            "last_seen_ts": kw.get("last_seen_ts"),
            "last_commit_ts": kw.get("last_commit_ts"),
            "sources": kw.get("sources") or ["git"]}


# ══════════════════════════════════════════════════════════════════════════════════
print("A. THE FIX: a member row with a genuine last_commit_ts renders an honest age")

members, _of = W.wall_members([
    row("nosignal", "member", sources=["github"]),
    row("stale", "member", last_commit_ts=NOW - 20 * DAY, sources=["git"]),
], self_ids=set(), now=NOW)
nosignal = [m for m in members if m["user"] == "nosignal"][0]
stale = [m for m in members if m["user"] == "stale"][0]

seg_stale = vis(S._team_tier_seg(stale, NOW))
seg_none = vis(S._team_tier_seg(nosignal, NOW))

if "mem" in seg_stale and "2w" in seg_stale:
    ok("A1 a member row with a real last_commit_ts (20d old) renders its age: %r" % seg_stale)
else:
    bad("A1 stale member did not render its commit age: %r" % seg_stale)

if seg_none == "⌂mem":
    ok("A2 a TRUE zero-signal member still renders the bare, honest `⌂mem` "
       "(no fabricated age): %r" % seg_none)
else:
    bad("A2 a zero-signal member's render changed: %r" % (seg_none,))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nB. WIDTH: the new age never blows the 8-cell team-label budget")

if len(seg_stale) <= 8:
    ok("B1 the member+age segment fits the 8-cell budget: %d cells (%r)" % (len(seg_stale), seg_stale))
else:
    bad("B1 the member+age segment overflowed 8 cells: %d (%r)" % (len(seg_stale), seg_stale))

very_old = dict(stale)
very_old["ts"] = NOW - 400 * DAY
seg_old = vis(S._team_tier_seg(very_old, NOW))
age_part = seg_old.split(" ")[-1] if " " in seg_old else ""
if 0 < len(age_part) <= 3 and len(seg_old) <= 8:
    ok("B2 a 400-day-old commit still fits: age=%r whole=%r" % (age_part, seg_old))
else:
    bad("B2 a 400-day-old commit overflowed: age=%r whole=%r" % (age_part, seg_old))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nC. _last_seen bucket thresholds, stated explicitly")

CASES = [
    (30, "now"), (59, "now"),
    (60, "1m"), (3599, "59m"),
    (3600, "1h"), (86399, "23h"),
    (86400, "1d"), (7 * DAY - 1, "6d"),
    (7 * DAY, "1w"), (365 * DAY - 1, "52w"),
    (365 * DAY, "1y"), (100 * 365 * DAY, "99y"),
]


def check_buckets(fn, label):
    mism = [(age, want, fn(NOW, NOW - age)) for age, want in CASES if fn(NOW, NOW - age) != want]
    if not mism:
        ok("%s every _last_seen bucket boundary matches: %r" % (label, CASES))
    else:
        bad("%s bucket mismatch(es): %r" % (label, mism))


check_buckets(S._last_seen, "C1")

overflow = [age for age in (0, 59, 60, 3599, 3600, 86399, 86400, 604799, 604800,
                            31535999, 31536000, 999999999)
            if len(S._last_seen(NOW, NOW - age)) > 3]
if not overflow:
    ok("C2 _last_seen never exceeds 3 cells across the full range")
else:
    bad("C2 _last_seen exceeded 3 cells for ages: %r" % (overflow,))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nD. hmd_wall._tier_ts is the authoritative source")

if W._tier_ts({"tier": "member", "last_commit_ts": NOW - DAY}) == NOW - DAY:
    ok("D1 hmd_wall._tier_ts surfaces a member row's real last_commit_ts")
else:
    bad("D1 hmd_wall._tier_ts still drops a member row's last_commit_ts")

if W._tier_ts({"tier": "member", "last_commit_ts": None}) is None:
    ok("D2 hmd_wall._tier_ts stays None for a truly signal-less member row")
else:
    bad("D2 hmd_wall._tier_ts fabricated a timestamp for a signal-less member row")

# ══════════════════════════════════════════════════════════════════════════════════
print("\nE. AWAY / CONTRIBUTED unaffected — pre-existing behaviour is bit-identical")

away_m, _o = W.wall_members([row("a", "away", last_seen_ts=NOW - 15 * 3600)], self_ids=set(), now=NOW)
contrib_m, _o = W.wall_members([row("c", "contributed", last_commit_ts=NOW - 2 * DAY)], self_ids=set(), now=NOW)
seg_away = vis(S._team_tier_seg(away_m[0], NOW))
seg_contrib = vis(S._team_tier_seg(contrib_m[0], NOW))
if seg_away == "⊘off 15h":
    ok("E1a away render is bit-identical to before this change: %r" % seg_away)
else:
    bad("E1a away render changed: %r" % (seg_away,))
if seg_contrib == "⌁git 2d":
    ok("E1b contributed render is bit-identical to before this change: %r" % seg_contrib)
else:
    bad("E1b contributed render changed: %r" % (seg_contrib,))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nF. DEGRADATION: malformed member dicts never raise, never fabricate")

try:
    S._team_tier_seg({"user": "junk", "tier": "member"}, NOW)
    S._team_tier_seg({"user": "junk2", "tier": "member", "ts": "not-a-number"}, NOW)
    bool_seg = vis(S._team_tier_seg({"user": "junk3", "tier": "member", "ts": True}, NOW))
    ok("F1 malformed member dicts (missing/string/bool ts) render without raising")
    # bool is an int subclass in Python — True must NOT be read as a 1-second-old timestamp.
    if bool_seg == "⌂mem":
        ok("F2 a bool `ts=True` is REJECTED as a timestamp, not rendered as a fabricated age: %r"
           % bool_seg)
    else:
        bad("F2 a bool ts fabricated an age: %r" % (bool_seg,))
except Exception as e:
    bad("F1 a malformed member dict crashed the render: %r" % (e,))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nG. FALSIFIABILITY: break the AGE FORMATTER in-process, prove RED, restore, prove GREEN")

_original_last_seen = S._last_seen


def _pre_fix_last_seen(now, ts):   # the EXACT old 3-bucket implementation, reinstated
    secs = max(0, int(now - ts))
    if secs < 3600:
        return "%dm" % (secs // 60)
    if secs < 86400:
        return "%dh" % (secs // 3600)
    return "%dd" % (secs // 86400)


S._last_seen = _pre_fix_last_seen
mism_broken = [(age, want, S._last_seen(NOW, NOW - age)) for age, want in CASES
               if S._last_seen(NOW, NOW - age) != want]
if mism_broken:
    ok("G1 reverting to the pre-fix formatter FLIPS the bucket test RED (mismatches=%r)"
       % (mism_broken,))
else:
    bad("G1 the pre-fix formatter did not diverge — this falsifier is vacuous")

S._last_seen = _original_last_seen
mism_restored = [(age, want, S._last_seen(NOW, NOW - age)) for age, want in CASES
                 if S._last_seen(NOW, NOW - age) != want]
if not mism_restored:
    ok("G2 restoring the real formatter returns the bucket test to GREEN")
else:
    bad("G2 the formatter did not restore cleanly: %r" % (mism_restored,))

print()
print("%d passed, %d failed" % (_p, _f))
sys.exit(1 if _f else 0)
PY

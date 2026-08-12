#!/usr/bin/env bash
# heimdall-wall-roster — THE POPULATED WALL (repo_roster → statusline).
#
# THE DEFECT THIS CLOSES. bin/lib/repo_roster.py landed and returns TWENTY-THREE people for
# the owner's repo — 1 online, 14 contributed (git), 9 members (github). The renderer never
# read it (`grep -rc repo_roster sentinels/` was 0), so the wall showed ONE person and an
# empty slot. The data to show a full team already existed and was simply unread.
#
# THE CONTRACT PROVEN HERE.
#   A. READER   — hmd_wall.read_wall() is a PURE CACHE READ. No subprocess, no gh, no git,
#                 no network. A missing/malformed/non-list cache degrades to [] and the wall
#                 falls back to the presence-only render (never a crash, never a blank line).
#   B. OVERLAY  — presence is re-decided from the LIVE presence cache and may only ever be
#                 LOST, never GAINED. A cached `online` with no live backing is DEMOTED. This
#                 is the anti-fabrication rule: a stale cache can never invent a present dev.
#   C. TIERS    — all four tiers render, each UNMISTAKABLE, extending the 9cad9a9 vocabulary:
#                 a glyph outside the online set PLUS a literal word, so the distinction
#                 survives --no-color, a mono terminal and a colorblind viewer.
#   D. PROPERTY — a viewer may NEVER read a non-present person as present. Only tier "online"
#                 keeps the natural sigil palette and the hero-hue name; every other tier is
#                 drained to MONO + faint. `contributed` is the sharp case: someone who
#                 committed 3 days ago must NOT show a bare branch line, which reads as
#                 "working on it right now".
#   E. WIDTH    — nobody is ever SILENTLY dropped: shown + overflow == total, always.
#   F. HOTPATH  — the render path stays cheap (the roster build is 60ms+; it belongs in the
#                 detached refresh child, never in the renderer).
#
# Pure functions + injected clocks (no wall-clock flake, no network, no real control plane).
# Exit 0 = every proof holds.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WALL="$ROOT/sentinels/hmd_wall.py"
STATUSLINE="$ROOT/sentinels/hmd-statusline.py"
ROSTER="$ROOT/bin/lib/repo_roster.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
for f in "$WALL" "$STATUSLINE" "$ROSTER"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done

TMP="$(mktemp -d -t hmd-wall-roster.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PY="$TMP/proof.py"
cat > "$PY" <<'PYEOF'
import importlib.util
import json
import os
import re
import sys
import time

WALL, STATUSLINE, ROSTER, TMP = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

os.environ["HEIMDALL_HOME"] = os.path.join(TMP, "home")
os.environ.setdefault("COLUMNS", "200")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


W = load(WALL, "hmd_wall")
S = load(STATUSLINE, "hmd_statusline")

STRIP = re.compile(r"\033\[[0-9;]*m")
vis = lambda x: STRIP.sub("", x)                 # noqa: E731
P_N = [0]
F_N = [0]
ok = lambda m: (P_N.__setitem__(0, P_N[0] + 1), print("  \033[32mPASS\033[0m " + m))
bad = lambda m: (F_N.__setitem__(0, F_N[0] + 1), print("  \033[31mFAIL\033[0m " + m))

DAY = 86400.0
NOW = 1_700_000_000.0


def repo(name):
    d = os.path.join(TMP, name, ".heimdall")
    os.makedirs(d, exist_ok=True)
    return os.path.join(TMP, name)


def put_wall(r, rows):
    with open(W.wall_cache_path(r), "w") as f:
        json.dump(rows, f)


def row(handle, tier, **kw):
    out = {"handle": handle, "haid": kw.get("haid"), "tier": tier,
           "online": tier == "online",
           "last_seen_ts": kw.get("last_seen_ts"),
           "last_commit_ts": kw.get("last_commit_ts"),
           "sources": kw.get("sources") or ["git"]}
    return out


# ══════════════════════════════════════════════════════════════════════════════════
print("\nA. READER: the wall cache read is pure, and degrades instead of crashing")

r = repo("a_missing")
if W.read_wall(r) == []:
    ok("A1 a MISSING wall cache reads as [] (→ the presence-only wall, not a crash)")
else:
    bad("A1 missing cache did not read as []: %r" % (W.read_wall(r),))

r = repo("a_malformed")
with open(W.wall_cache_path(r), "w") as f:
    f.write("{not json at all")
if W.read_wall(r) == []:
    ok("A2 a MALFORMED wall cache reads as [] (never raises)")
else:
    bad("A2 malformed cache did not read as []")

r = repo("a_nonlist")
put_wall(r, {"handle": "nope"})
if W.read_wall(r) == []:
    ok("A3 a NON-LIST wall cache reads as [] (the contract is an array)")
else:
    bad("A3 non-list cache did not read as []")

r = repo("a_valid")
put_wall(r, [row("rj", "online"), row("akshat", "contributed")])
if len(W.read_wall(r)) == 2:
    ok("A4 a valid wall cache reads its rows back")
else:
    bad("A4 valid cache did not read back 2 rows")

r = repo("a_junkrows")
put_wall(r, [row("rj", "online"), "garbage", 42, None, {"no_handle": 1}])
got = W.read_wall(r)
if [g["handle"] for g in got] == ["rj"]:
    ok("A5 junk ROWS inside a valid array are dropped, the good rows survive")
else:
    bad("A5 junk rows not filtered: %r" % (got,))

# The hot path must never shell out. Poison subprocess and prove the read still works.
r = repo("a_nofork")
put_wall(r, [row("rj", "online"), row("akshat", "contributed")])
import subprocess as _sp                                          # noqa: E402
_real_popen, _real_run = _sp.Popen, _sp.run


def _boom(*a, **k):
    raise AssertionError("the render path forked a subprocess")


_sp.Popen, _sp.run = _boom, _boom
try:
    W.read_wall(r)
    W.wall_members(W.read_wall(r), self_ids=set(), now=NOW)
    ok("A6 read_wall + wall_members fork ZERO subprocesses (no gh, no git, no network)")
except AssertionError as e:
    bad("A6 %s" % e)
finally:
    _sp.Popen, _sp.run = _real_popen, _real_run

# ══════════════════════════════════════════════════════════════════════════════════
print("\nB. OVERLAY: presence may only ever be LOST here, never GAINED")

# B1 — the cache claims online; the LIVE presence cache has nobody. Demote.
rows = [row("ghost", "online", haid="haid:ghost.box", last_seen_ts=NOW - 5)]
out = W.overlay_presence(rows, [], now=NOW)
if out and out[0]["tier"] != "online" and out[0]["online"] is False:
    ok("B1 a cached ONLINE row with NO live presence is DEMOTED (no fabricated presence)")
else:
    bad("B1 stale cache invented a present dev: %r" % (out,))

# B2 — live presence confirms them. Keep online.
live = [{"name": "ghost", "haid": "haid:ghost.box", "online": True, "ts": NOW - 5,
         "verdict": "working", "branch": "feat/x"}]
out = W.overlay_presence(rows, live, now=NOW)
if out and out[0]["tier"] == "online" and out[0]["online"] is True:
    ok("B2 a cached ONLINE row CONFIRMED by live presence stays online")
else:
    bad("B2 live-confirmed dev was not kept online: %r" % (out,))

# B3 — live entry exists but its heartbeat is past the online TTL. Demote.
stale = [{"name": "ghost", "haid": "haid:ghost.box", "online": True, "ts": NOW - 600,
          "verdict": "working", "branch": "feat/x"}]
out = W.overlay_presence(rows, stale, now=NOW)
if out and out[0]["tier"] != "online":
    ok("B3 a live entry STALE past the online TTL is DEMOTED (the clock still rules)")
else:
    bad("B3 a stale heartbeat was rendered as online: %r" % (out,))

# B4 — someone live who is NOT in the wall cache yet (joined since the last refresh).
out = W.overlay_presence([row("akshat", "contributed")],
                         [{"name": "newbie", "haid": "haid:newbie.box", "online": True,
                           "ts": NOW - 3, "verdict": "working", "branch": ""}], now=NOW)
handles = [o["handle"] for o in out]
if "newbie" in handles and out[handles.index("newbie")]["tier"] == "online":
    ok("B4 a LIVE dev missing from the cache is UNIONED in (a cold cache still shows presence)")
else:
    bad("B4 live dev absent from the cache was lost: %r" % (handles,))

# B5 — a contributed row can never be promoted by presence noise it does not own.
out = W.overlay_presence([row("akshat", "contributed", last_commit_ts=NOW - 3 * DAY)],
                         [{"name": "someone-else", "haid": "haid:x.y", "online": True,
                           "ts": NOW}], now=NOW)
akshat = [o for o in out if o["handle"] == "akshat"][0]
if akshat["tier"] == "contributed" and akshat["online"] is False:
    ok("B5 a CONTRIBUTED row stays contributed — another dev's presence never promotes it")
else:
    bad("B5 contributed row was promoted: %r" % (akshat,))

# B6 — a malformed/absent online field must show LESS, never a synthesised online.
out = W.overlay_presence([{"handle": "weird", "tier": "online", "online": "yes-ish",
                           "haid": None, "last_seen_ts": None, "last_commit_ts": None,
                           "sources": []}], [], now=NOW)
if out and out[0]["tier"] != "online":
    ok("B6 a MALFORMED online field degrades to not-present (show less, never more)")
else:
    bad("B6 malformed online field produced a present dev: %r" % (out,))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nC. TIERS: four tiers, each unmistakable in WORDS as well as colour")

members, _of = W.wall_members([
    row("rj", "online", haid="haid:rj.box", last_seen_ts=NOW - 5),
    row("akshat", "contributed", last_commit_ts=NOW - 3 * DAY),
    row("anu", "away", haid="haid:anu.box", last_seen_ts=NOW - 2 * DAY),
    row("iris594", "member", sources=["github"]),
], self_ids=set(), now=NOW)

segs = {m["user"]: vis(S._team_state_seg(m, NOW)) for m in members}

if len(set(segs.values())) == 4:
    ok("C1 all FOUR tiers render a DISTINCT Row4 segment: %r" % (sorted(segs.values()),))
else:
    bad("C1 tiers collide on Row4: %r" % (segs,))

words = {"akshat": "git", "anu": "off", "iris594": "mem"}
missing = [h for h, w in words.items() if w not in segs.get(h, "")]
if not missing:
    ok("C2 every non-present tier carries a LITERAL WORD (off/git/mem) — survives --no-color")
else:
    bad("C2 tiers with no literal word: %r (segs=%r)" % (missing, segs))

ONLINE_GLYPHS = set("◉⚡✗○●")
collide = [h for h, s in segs.items() if h != "rj" and (set(s) & ONLINE_GLYPHS)]
if not collide:
    ok("C3 no non-present tier reuses an ONLINE glyph (◉ ⚡ ✗ ○ ●)")
else:
    bad("C3 a non-present tier reused an online glyph: %r" % (collide,))

over = {h: len(s) for h, s in segs.items() if len(s) > 8}
if not over:
    ok("C4 every tier segment fits the 8-cell team strip: %r" % (
        {h: len(s) for h, s in segs.items()},))
else:
    bad("C4 segment(s) overflow the 8-cell strip: %r" % (over,))

# C5 — THE SHARP CASE. A contributed dev carries a branch from their last commit; showing it
# bare under their name reads as "working on that branch right now". The tier marker must win.
contributed = [m for m in members if m["user"] == "akshat"][0]
contributed["branch"] = "feature/checkout"
_r1, _r2, _r3, r4 = S.team_columns([contributed], 40, 0, NOW)
if "git" in vis(r4) and "feature/checkout" not in vis(r4):
    ok("C5 a CONTRIBUTED dev's branch NEVER displaces the tier marker (the whole misread)")
else:
    bad("C5 contributed dev rendered a bare branch line: %r" % (vis(r4),))

dots = vis(S.team_dots(members))
shapes = [d for d in dots if d.strip()]
if len(set(shapes)) == 4:
    ok("C6 the narrow-tier dots are SHAPE-distinct per tier (%s) — survives a mono terminal"
       % (" ".join(shapes),))
else:
    bad("C6 narrow dots are not shape-distinct: %r" % (dots,))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nD. THE PROPERTY: a non-present person can never READ as present")

if all(S._tier_of(m) == "online" for m in members if m["user"] == "rj") and \
        all(S._tier_of(m) != "online" for m in members if m["user"] != "rj"):
    ok("D1 exactly one tier — 'online' — is classified present")
else:
    bad("D1 tier classification leaked presence: %r" % ([(m["user"], S._tier_of(m))
                                                        for m in members],))

# Only the online dev keeps a hero-hue name; everyone else is drained to the faint hue.
_r1, _r2, r3, _r4 = S.team_columns(members, 120, 0, NOW)
hero_runs = re.findall(r"\033\[38;2;(\d+);(\d+);(\d+)m([^\033]*)", r3)
faint = (58, 65, 77)
colored_names = [t.strip() for (a, b, c, t) in hero_runs
                 if (int(a), int(b), int(c)) != faint and t.strip()]
if colored_names == ["rj"]:
    ok("D2 ONLY the online dev gets a hero-hue name; every other tier is faint: %r"
       % (colored_names,))
else:
    bad("D2 a non-present dev kept an identity hue: %r" % (colored_names,))

if all(S._drained(m) for m in members if m["user"] != "rj") and \
        not S._drained([m for m in members if m["user"] == "rj"][0]):
    ok("D3 ONLY the online dev keeps the natural sigil palette (all others drain to MONO)")
else:
    bad("D3 a non-present dev kept the identity hue in their sigil")

# D4 — the ORDERING INVARIANT that makes `+N` safe: online devs sort first, so an online
# person can NEVER be the one hidden behind the overflow tag.
many = [row("on%d" % i, "online", haid="haid:on%d.b" % i, last_seen_ts=NOW - 1)
        for i in range(3)] + [row("c%d" % i, "contributed", last_commit_ts=NOW - i * DAY)
                              for i in range(20)]
ms, _of = W.wall_members(many, self_ids=set(), now=NOW)
first3 = [m["user"] for m in ms[:3]]
if all(u.startswith("on") for u in first3):
    ok("D4 ONLINE devs sort FIRST — nobody present can ever hide behind the `+N` tag")
else:
    bad("D4 an online dev was sorted below a non-present one: %r" % (first3,))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nE. WIDTH: nobody is ever SILENTLY dropped")

ms, of = W.wall_members([row("rj", "online", haid="haid:rj.b", last_seen_ts=NOW - 1)] +
                        [row("c%d" % i, "contributed", last_commit_ts=NOW - i * DAY)
                         for i in range(22)], self_ids=set(), now=NOW)
total = len(ms) + of
if total == 23:
    ok("E1 wall_members accounts for EVERY person: shown %d + overflow %d == 23" % (len(ms), of))
else:
    bad("E1 people vanished: shown %d + overflow %d != 23" % (len(ms), of))

# Whatever the layout packs, the remainder is DISCLOSED as `+N` on Row3.
shown = ms[:4]
_r1, _r2, r3, _r4 = S.team_columns(shown, 120, len(ms) - len(shown) + of, NOW)
if "+19" in vis(r3):
    ok("E2 the hidden remainder is DISCLOSED as `+19` — never a silent truncation")
else:
    bad("E2 the overflow tag is missing from Row3: %r" % (vis(r3),))

# E3 — self is excluded from the wall (you are the big sigil on the left, not a column).
ms, _of = W.wall_members([row("rj", "online", haid="haid:rj.b", last_seen_ts=NOW - 1),
                          row("akshat", "contributed", last_commit_ts=NOW - DAY)],
                         self_ids={"rj"}, now=NOW)
if [m["user"] for m in ms] == ["akshat"]:
    ok("E3 SELF is excluded from the wall columns (you are the hero sigil on the left)")
else:
    bad("E3 self-exclude failed: %r" % ([m["user"] for m in ms],))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nF. HOT PATH: the render read stays cheap (the 60ms build belongs in the child)")

r = repo("f_perf")
put_wall(r, [row("rj", "online", haid="haid:rj.b", last_seen_ts=NOW - 1)] +
         [row("c%d" % i, "contributed", last_commit_ts=NOW - i * DAY) for i in range(22)])
W.read_wall(r)                                             # prime the page cache
ts = []
for _ in range(20):
    t0 = time.perf_counter()
    W.wall_members(W.overlay_presence(W.read_wall(r), [], now=NOW), self_ids=set(), now=NOW)
    ts.append((time.perf_counter() - t0) * 1000.0)
ts.sort()
med = ts[len(ts) // 2]
if med < 5.0:
    ok("F1 read+overlay+members median %.3fms < 5ms for 23 people (build() is 60ms+)" % med)
else:
    bad("F1 the render path is too expensive: %.3fms median" % med)

if W.refresh_due(repo("f_cold")):
    ok("F2 a COLD wall cache reports refresh_due (the detached child will warm it)")
else:
    bad("F2 a cold cache did not report refresh_due")

r = repo("f_fresh")
put_wall(r, [row("rj", "online")])
if not W.refresh_due(r):
    ok("F3 a FRESH wall cache reports NOT due — the refresh is throttled, not per-prompt")
else:
    bad("F3 a fresh cache asked for a refresh (would fork every prompt)")

# ── F4–F6: THE CACHE MAY NOT OUTLIVE THE CODE THAT PRODUCED IT ────────────────────
# The MEASURED defect: repo_roster gained the identity merge at 10:07 and the wall cache had
# been written at 10:05. For the next 15 minutes (WALL_CACHE_TTL) the renderer kept serving
# the PRE-FIX snapshot — the owner rendered as TWO people on the wall while the roster CLI,
# run against the same repo at the same moment, returned ONE. The cache was a SECOND source
# of truth for identity, keyed only on time, so it survived the fix that invalidated it.
#
# A memo may not outlive its producer. The cache is a memo of repo_roster.build(), so a
# producer NEWER than the snapshot means the snapshot came from a previous version of the
# code and is COLD regardless of its age. That is what makes exactly one code path — the
# current build() — decide who is on the wall.
r = repo("f_producer")
put_wall(r, [row("rj", "online")])
producer = os.path.join(TMP, "f_producer", "producer.py")
with open(producer, "w") as f:
    f.write("# the roster lib\n")
cache_mtime = os.path.getmtime(W.wall_cache_path(r))

os.utime(producer, (cache_mtime - 60, cache_mtime - 60))     # lib OLDER than the snapshot
if not W.refresh_due(r, producer=producer):
    ok("F4 a cache NEWER than its producer stays warm — no fork per prompt on a steady lib")
else:
    bad("F4 a cache newer than its producer was called stale (would fork every prompt)")

os.utime(producer, (cache_mtime + 60, cache_mtime + 60))     # lib NEWER than the snapshot
if W.refresh_due(r, producer=producer):
    ok("F5 a cache OLDER than its producer is COLD — a roster fix can never serve stale identity")
else:
    bad("F5 a cache predating its producer stayed warm — the 10:05-vs-10:07 wall bug is live")

if not W.refresh_due(r, producer=os.path.join(TMP, "f_producer", "absent.py")):
    ok("F6 an UNSTATTABLE producer falls back to the age rule (degrades, never forks forever)")
else:
    bad("F6 a missing producer forced a refresh on every prompt")

# ══════════════════════════════════════════════════════════════════════════════════
print("\nG. DEGRADATION: the statusline never crashes, hangs, or blanks the line")

# G1 — every tier helper tolerates a junk member dict.
try:
    junk = {"user": "x"}
    S._team_state_seg(junk, NOW)
    S._tier_of(junk)
    S.team_dots([junk])
    S.team_columns([junk], 40, 0, NOW)
    ok("G1 a member dict with NO tier/ts/online renders without raising")
except Exception as e:
    bad("G1 a junk member crashed the render: %r" % (e,))

# G2 — an untiered member (an older ledger status.json) keeps the PRE-EXISTING behaviour.
legacy_live = {"user": "leg", "state": "running", "ts": NOW - 10, "online": True}
legacy_away = {"user": "leg", "state": "offline", "ts": NOW - 600, "online": False}
if S._tier_of(legacy_live) == "online" and S._tier_of(legacy_away) == "away":
    ok("G2 a LEGACY ledger member (no tier key) still maps to online/away — back-compat")
else:
    bad("G2 legacy member mapping broke: %r / %r" % (S._tier_of(legacy_live),
                                                     S._tier_of(legacy_away)))

# ══════════════════════════════════════════════════════════════════════════════════
print("\nH. ONE CODE PATH: the renderer's wall == the roster, from EVERY source")
# The MEASURED defect. _team_members had THREE member sources — the wall cache, the
# ledger mirror, and a live-presence fallback — and only the first two excluded SELF.
# While the wall cache was stale the wall path won and self was dropped correctly; the
# moment the roster merged the owner into ONE row the wall path yielded zero members,
# the live fallback took over, and the owner reappeared on his own wall. The renderer
# and `repo_roster.py --repo <same repo>` disagreed AGAIN, one layer up.
#
# Two sources of truth for identity is how both bugs exist. So the property asserted
# here is not "the fallback also excludes self" — it is that the renderer's member list
# EQUALS the roster's, whichever source supplied it.


def put_presence(r, rows):
    with open(S._roster_cache_path(r), "w") as f:
        json.dump(rows, f)


def beat(handle, haid, age=1.0):
    return {"handle": handle, "haid": haid, "verdict": "working", "file": "",
            "branch": "", "age_seconds": age, "online": True}


SELF_IDS = {"rj", "haid:rj.box-46d5"}

# H1 — the exact live shape: the roster merged the owner into ONE row, so the wall has
# nobody left to show. The fallback must not resurrect him from the presence cache.
r = repo("h_selfonly")
put_wall(r, [row("rj", "online", haid="haid:rj.box-46d5", last_seen_ts=NOW - 1)])
put_presence(r, [beat("rj", "haid:rj.box-46d5")])
ms, of = S._team_members(r, {"team": [], "team_overflow": 0}, SELF_IDS)
if [m.get("user") for m in ms] == [] and of == 0:
    ok("H1 a wall of ONLY self renders ZERO columns — no source may re-add the owner")
else:
    bad("H1 self came back through a fallback: %r" % ([m.get("user") for m in ms],))

# H2 — FALSIFIABILITY. The pre-fix fallback is reconstructed verbatim from the live
# presence rows with no self gate; it MUST produce the owner, or H1 proves nothing.
mutant = [{"user": m.get("name") or "?", "haid": m.get("haid")}
          for m in S.team_presence(r)[:3]]
if [m["user"] for m in mutant] == ["rj"]:
    ok("H2 the UNGATED fallback yields ['rj'] — H1 discriminates, it is not vacuous")
else:
    bad("H2 the mutant fallback did not reproduce the defect: %r" % (mutant,))

# H3 — THE EQUALITY. For the same repo the renderer's member list must be exactly the
# roster's rows minus self, in the roster's own order. This is the assertion that would
# have caught both divergences on the first render.
crowd = [row("rj", "online", haid="haid:rj.box-46d5", last_seen_ts=NOW - 1),
         row("akshat", "contributed", last_commit_ts=NOW - DAY),
         row("anu", "away", last_seen_ts=NOW - 3 * DAY),
         row("madala", "member")]
r = repo("h_equal")
put_wall(r, crowd)
put_presence(r, [beat("rj", "haid:rj.box-46d5")])
want = [c["handle"] for c in crowd if c["handle"] not in SELF_IDS]
ms, of = S._team_members(r, {"team": [], "team_overflow": 0}, SELF_IDS)
if [m.get("user") for m in ms] == want and of == 0:
    ok("H3 renderer wall == roster rows minus self, in roster order: %s" % (want,))
else:
    bad("H3 renderer/roster divergence: renderer=%r roster=%r"
        % ([m.get("user") for m in ms], want))

# H4 — the ledger mirror is a THIRD source and is gated by the same one gate. A stale
# status.json naming the owner may not put him back either.
r = repo("h_ledger")
put_wall(r, [])
put_presence(r, [])
stale_ledger = {"team": [{"user": "rj", "haid": "haid:rj.box-46d5", "state": "running"},
                         {"user": "akshat", "haid": None, "state": "running"}],
                "team_overflow": 0}
ms, _of = S._team_members(r, stale_ledger, SELF_IDS)
if [m.get("user") for m in ms] == ["akshat"]:
    ok("H4 a stale LEDGER mirror naming self is gated too — one gate, every source")
else:
    bad("H4 the ledger source bypassed the self gate: %r" % ([m.get("user") for m in ms],))

# H5 — the gate matches on HAID as well as handle. After the merge the roster may name
# the owner by his GitHub login while the render still knows him by his HAID; matching
# only the handle would put him straight back on the wall.
r = repo("h_haid")
put_wall(r, [])
put_presence(r, [])
ms, _of = S._team_members(
    r, {"team": [{"user": "randomittin", "haid": "haid:rj.box-46d5", "state": "running"}],
        "team_overflow": 0}, SELF_IDS)
if [m.get("user") for m in ms] == []:
    ok("H5 self is matched by HAID even under a different handle (the merge renames)")
else:
    bad("H5 a renamed self row survived the gate: %r" % ([m.get("user") for m in ms],))

print("\nI. SCOPE: the machine-global ledger may never put ANOTHER repo's people here")
# THE MEASURED DEFECT, reported live: "the wall is now showing folks from other repos as
# well initially and then updates it back to the current project".
#
# The ledger mirror is read from ONE MACHINE-GLOBAL file —
# ${HEIMDALL_HOME}/ledger/status.json — which bin/heimdall-status-json rewrites on every
# keeper beat from whatever repo that keeper happens to run in. It carried NO project
# identity, and hmd_ledger.filter_team filters only by time-window and self — never by
# project. So two live sessions in two repos fight over one slot, and each repo's
# statusline renders the OTHER repo's roster as if those people were here.
#
# It self-corrects a beat later only because _team_members prefers the repo-scoped wall
# once that wall is BIGGER (len(wall) > len(members)). So the wrong frame is exactly the
# FIRST one — while the repo-scoped wall cache is still cold. A first paint naming people
# who are not on this project is a false statement about who is here, screenshotted or not.
#
# THE RULE PROVEN HERE: an unknown scope renders as NOTHING. Never as EVERYTHING.

FOREIGN = {"team": [{"user": "priya", "haid": "haid:priya.box-11", "state": "running"},
                    {"user": "marcus", "haid": "haid:marcus.box-22", "state": "running"},
                    {"user": "wei", "haid": "haid:wei.box-33", "state": "running"}],
           "team_overflow": 0}

# I1 — THE DEFECT ITSELF. Cold repo-scoped caches (the FIRST-PAINT condition) plus a global
# ledger stamped with a DIFFERENT repo must contribute ZERO columns.
r = repo("i_foreign")
put_wall(r, [])
put_presence(r, [])
ms, of = S._team_members(r, dict(FOREIGN, repo=os.path.join(TMP, "some_other_repo")), SELF_IDS)
if [m.get("user") for m in ms] == [] and of == 0:
    ok("I1 a ledger stamped with ANOTHER repo contributes ZERO on the cold first paint")
else:
    bad("I1 other repos' people reached this wall's first paint: %r"
        % ([m.get("user") for m in ms],))

# I2 — NOT VACUOUS. The mirror is SCOPED, not disabled: stamped with THIS repo it still
# populates the wall. Without this, I1 would pass by simply deleting the ledger source.
r2 = repo("i_own")
put_wall(r2, [])
put_presence(r2, [])
ms, _of = S._team_members(r2, dict(FOREIGN, repo=r2), SELF_IDS)
if [m.get("user") for m in ms] == ["priya", "marcus", "wei"]:
    ok("I2 a ledger stamped with THIS repo still populates it — scoped, not disabled")
else:
    bad("I2 the scope gate broke the legitimate same-repo mirror: %r"
        % ([m.get("user") for m in ms],))

# I3 — FAIL CLOSED. An UNSTAMPED ledger (an older heimdall-status-json, or a torn write)
# has an UNKNOWN scope. Unknown must render as nothing: the absence of a filter must never
# be read as "everything".
r3 = repo("i_unstamped")
put_wall(r3, [])
put_presence(r3, [])
ms, _of = S._team_members(r3, dict(FOREIGN), SELF_IDS)
if [m.get("user") for m in ms] == []:
    ok("I3 an UNSTAMPED ledger fails CLOSED — unknown scope shows nothing, not everyone")
else:
    bad("I3 an unknown scope degraded to EVERYTHING: %r" % ([m.get("user") for m in ms],))

# I4 — the first paint is SCOPED, not merely BLANKED. With the foreign mirror gated out,
# the repo-scoped LIVE presence still paints THIS project's teammates on that same first
# frame. Suppressing the mirror must not cost the wall its own real roster — a flash of
# nothing would still be a flash.
r4 = repo("i_firstpaint")
put_wall(r4, [])
put_presence(r4, [beat("akshat", "haid:akshat.box-77")])
ms, _of = S._team_members(r4, dict(FOREIGN, repo=os.path.join(TMP, "elsewhere")), SELF_IDS)
if [m.get("user") for m in ms] == ["akshat"]:
    ok("I4 the cold first paint renders THIS repo's live teammate, not a blank wall")
else:
    bad("I4 the first paint lost the repo-scoped roster: %r"
        % ([m.get("user") for m in ms],))

print("\n" + "=" * 60)
print("wall-roster: %d passed, %d failed" % (P_N[0], F_N[0]))
print("=" * 60)
sys.exit(1 if F_N[0] else 0)
PYEOF

python3 "$PY" "$WALL" "$STATUSLINE" "$ROSTER" "$TMP"
exit $?

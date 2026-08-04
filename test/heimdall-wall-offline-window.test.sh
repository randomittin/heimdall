#!/usr/bin/env bash
# heimdall-wall-offline-window — the 7-DAY OFFLINE WALL.
#
# THE DEFECT THIS CLOSES. Before this, presence was an ONLINE-ONLY projection at EVERY layer:
# the server's roster() dropped any dev whose heartbeat was older than the 45s online TTL, and
# the statusline's filter_team() dropped any teammate whose ts was older than 300s. A teammate
# who was simply not beating RIGHT NOW did not render as "away" — they were ERASED. So a wall
# showing only yourself was INDISTINGUISHABLE from a wall that was broken, and a real presence
# outage looked exactly like a quiet afternoon. That ambiguity is the product defect.
#
# THE CONTRACT PROVEN HERE. A teammate whose last heartbeat falls within the OFFLINE WINDOW
# (7 days, a NAMED constant at every layer) renders in an EXPLICIT OFFLINE state instead of
# disappearing. Beyond the window they are dropped (the wall stays bounded, not a graveyard).
#
#   A. SERVER  — cp_presence.roster() returns stale-but-recent devs with online:false +
#                state "offline"; the 45s TTL still decides ONLINE, the 7d window decides
#                MEMBERSHIP; retired devs stay dropped (opt-out is still real).
#   B. LEDGER  — hmd_ledger.filter_team() RETAINS offline teammates within the window, marks
#                them, and never lets one displace a live teammate in the 3-name cap.
#   C. RENDER  — the offline segment is UNMISTAKABLE: a distinct glyph + the literal word
#                "off", so it survives --no-color and colorblind viewers; it can NEVER be
#                confused with an online state, and a recorded branch never masks it.
#   D. BUDGET  — every offline segment fits the 8-cell team strip (the wall is width-bound).
#
# Pure functions + injected clocks (no wall-clock flake, no network, no real GCP).
# Exit 0 = every proof holds.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib"
LEDGER="$ROOT/sentinels/hmd_ledger.py"
STATUSLINE="$ROOT/sentinels/hmd-statusline.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
for f in "$LIB/cp_presence.py" "$LEDGER" "$STATUSLINE"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done

TMP="$(mktemp -d -t hmd-wall-offline.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PY="$TMP/proof.py"
cat > "$PY" <<'PYEOF'
import importlib.util
import os
import re
import sys

LIB, LEDGER, STATUSLINE, HOME = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

os.environ["HEIMDALL_HOME"] = HOME
os.environ.pop("HEIMDALL_STATE_BACKEND", None)
sys.path.insert(0, LIB)


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


import cp_presence as P                      # noqa: E402
L = load(LEDGER, "hmd_ledger")
os.environ.setdefault("COLUMNS", "200")
S = load(STATUSLINE, "hmd_statusline")

STRIP = re.compile(r"\033\[[0-9;]*m")
vis = lambda x: STRIP.sub("", x)             # noqa: E731
P_N = [0]
F_N = [0]
ok = lambda m: (P_N.__setitem__(0, P_N[0] + 1), print("  \033[32mPASS\033[0m " + m))
bad = lambda m: (F_N.__setitem__(0, F_N[0] + 1), print("  \033[31mFAIL\033[0m " + m))

DAY = 86400.0
NOW = 1_700_000_000.0
PROJECT = "github.com/acme/wall"
TEAM = "a" * 32


def seed(haid, age, **extra):
    """Write one presence record whose heartbeat is `age` seconds old."""
    rec = {"haid": haid, "handle": haid.split(":")[-1].split(".")[0], "project": PROJECT,
           "ts": NOW - age, "verdict": None, "file": None, "branch": None,
           "activity_ts": None}
    rec.update(extra)
    P._backend(HOME).put_record(P._record_rel(PROJECT, TEAM, haid), rec)


def roster(now=NOW):
    return P.roster(PROJECT, TEAM, home=HOME, now=now)


def by_handle(rows):
    return {r.get("handle"): r for r in rows}


# ── A. SERVER — the roster returns offline members inside the window ────────────
print("\nA. SERVER: roster() surfaces stale-but-recent devs as OFFLINE")

seed("haid:live.box-0001", 10)                       # 10s  -> ONLINE  (< 45s TTL)
seed("haid:away.box-0002", 600)                      # 10m  -> OFFLINE (inside 7d)
seed("haid:old.box-0003", 8 * DAY)                   # 8d   -> DROPPED (outside 7d)
seed("haid:gone.box-0004", 300, retired=True)        # retired -> DROPPED (opt-out is real)

rows = roster()
got = by_handle(rows)

if got.get("live", {}).get("online") is True:
    ok("A1 a dev inside the 45s TTL is ONLINE (online:true)")
else:
    bad("A1 live dev not online: %r" % (got.get("live"),))

if "away" in got:
    ok("A2 a dev stale by 10m is PRESENT on the roster (no longer erased)")
else:
    bad("A2 stale-by-10m dev was DROPPED — the wall still erases offline teammates")

if got.get("away", {}).get("online") is False:
    ok("A3 the stale dev is explicitly online:false")
else:
    bad("A3 stale dev online flag = %r (want False)" % (got.get("away", {}).get("online"),))

if got.get("away", {}).get("state") == "offline":
    ok("A4 the stale dev carries the explicit state 'offline'")
else:
    bad("A4 stale dev state = %r (want 'offline')" % (got.get("away", {}).get("state"),))

if "old" not in got:
    ok("A5 a dev stale by 8d is DROPPED (the 7-day window still bounds the wall)")
else:
    bad("A5 a dev beyond the 7-day window stayed on the roster")

if "gone" not in got:
    ok("A6 a RETIRED dev stays DROPPED (opt-out is still real, not cosmetic)")
else:
    bad("A6 a retired dev reappeared as offline — opt-out broken")

# the window is a NAMED constant, not a magic number
w = getattr(P, "DEFAULT_OFFLINE_WINDOW_SECONDS", None)
if w == 7 * DAY:
    ok("A7 DEFAULT_OFFLINE_WINDOW_SECONDS is a named constant == 7 days")
else:
    bad("A7 DEFAULT_OFFLINE_WINDOW_SECONDS = %r (want %r)" % (w, 7 * DAY))

if callable(getattr(P, "offline_window_seconds", None)) and \
        getattr(P, "PRESENCE_OFFLINE_WINDOW_ENV", "") == "HEIMDALL_PRESENCE_OFFLINE_WINDOW_SECONDS":
    ok("A8 the window is env-tunable via offline_window_seconds()")
else:
    bad("A8 no env-tunable offline_window_seconds() seam")

# PRIVACY: an offline row exposes EXACTLY the field set an online row does — no new leak.
live_keys = set(got.get("live", {}).keys())
away_keys = set(got.get("away", {}).keys())
if live_keys == away_keys:
    ok("A9 PRIVACY: an offline row exposes the SAME fields as an online row (no widening)")
else:
    bad("A9 offline row field set differs: extra=%r missing=%r"
        % (sorted(away_keys - live_keys), sorted(live_keys - away_keys)))

# The boundary is the window, not an accident: 1s inside stays, 1s outside goes.
seed("haid:edge.box-0005", 7 * DAY - 1)
seed("haid:past.box-0006", 7 * DAY + 1)
edge = by_handle(roster())
if "edge" in edge and "past" not in edge:
    ok("A10 the 7-day boundary is exact (inside stays, outside drops)")
else:
    bad("A10 boundary wrong: edge=%s past=%s" % ("edge" in edge, "past" in edge))

# ── B. LEDGER — filter_team retains offline teammates ──────────────────────────
print("\nB. LEDGER: filter_team() keeps offline teammates inside the window")

win = getattr(L, "OFFLINE_WINDOW", None)
if win == 7 * DAY:
    ok("B1 hmd_ledger.OFFLINE_WINDOW is a named constant == 7 days")
else:
    bad("B1 hmd_ledger.OFFLINE_WINDOW = %r (want %r)" % (win, 7 * DAY))

team = [
    {"user": "akshat", "haid": "haid:akshat.a", "sigil": "#112233", "state": "offline",
     "ts": NOW - 3 * DAY, "online": False},
    {"user": "anu", "haid": "haid:anu.b", "sigil": "#223344", "state": "idle",
     "ts": NOW - 20, "online": True},
    {"user": "ancient", "haid": "haid:ancient.c", "sigil": "#334455", "state": "offline",
     "ts": NOW - 9 * DAY, "online": False},
]
members, overflow = L.filter_team(team, now=NOW, self_ids=set())
names = [m["user"] for m in members]

if "akshat" in names:
    ok("B2 a teammate offline for 3 days is RETAINED on the wall")
else:
    bad("B2 the 3-day-offline teammate was dropped — the erase bug survives")

if "ancient" not in names:
    ok("B3 a teammate offline for 9 days is DROPPED (window bounds the wall)")
else:
    bad("B3 a 9-day-stale teammate stayed on the wall")

akshat = next((m for m in members if m["user"] == "akshat"), None)
if akshat is not None and akshat.get("online") is False:
    ok("B4 the retained teammate is marked online:false through the ledger")
else:
    bad("B4 retained teammate lost its offline marking: %r" % (akshat,))

# THE FALSE-ONLINE FALSIFIER: an offline teammate must NEVER normalize into a working state.
if akshat is not None and akshat.get("state") == "offline":
    ok("B5 an offline teammate's state stays 'offline' (never normalized to 'running')")
else:
    bad("B5 offline state was normalized to %r — reads as a WORKING teammate"
        % (akshat or {}).get("state"))

# ORDERING: a live teammate must never be evicted by an offline one under the 3-name cap.
crowd = [{"user": "off%d" % i, "haid": "haid:off%d.x" % i, "sigil": "#000000",
          "state": "offline", "ts": NOW - (i + 1) * 3600, "online": False} for i in range(5)]
crowd.append({"user": "livedev", "haid": "haid:livedev.x", "sigil": "#00FF00",
              "state": "idle", "ts": NOW - 5, "online": True})
capped, _ = L.filter_team(crowd, now=NOW, self_ids=set())
if capped and capped[0]["user"] == "livedev":
    ok("B6 an ONLINE teammate sorts ahead of every offline one (cap never evicts the living)")
else:
    bad("B6 online teammate did not lead the capped wall: %r" % ([m["user"] for m in capped],))

# ── C. RENDER — offline is UNMISTAKABLE ───────────────────────────────────────
print("\nC. RENDER: the offline segment can never be read as present")

offline_m = {"user": "akshat", "state": "offline", "ts": NOW - 3 * DAY, "online": False}
seg = vis(S._team_state_seg(offline_m, NOW))
online_segs = [vis(S._team_state_seg({"user": "x", "state": st, "ts": NOW - 5, "online": True}, NOW))
               for st in ("pass", "running", "deny", "idle")]

if seg not in online_segs:
    ok("C1 the offline segment differs from EVERY online state segment")
else:
    bad("C1 offline segment %r collides with an online segment" % seg)

if "off" in seg.lower():
    ok("C2 the offline segment carries the literal word 'off' (survives --no-color)")
else:
    bad("C2 offline segment %r has no textual marker — color-only signalling" % seg)

online_glyphs = {"◉", "⚡", "✗"}   # ◉ rev / ⚡ wrk / ✗ deny
if not (set(seg) & online_glyphs):
    ok("C3 the offline segment reuses NO online glyph (never a subtly-different online)")
else:
    bad("C3 offline segment %r borrows an online glyph" % seg)

# A recorded branch must NOT mask the offline marker (Row4 branch line vs offline).
r1, r2, r3, r4 = S.team_columns(
    [{"user": "akshat", "haid": "haid:akshat.a", "sigil": "#112233", "state": "offline",
      "ts": NOW - 3 * DAY, "online": False, "branch": "feature/x"}],
    S.LAYOUT.TEAM_MEMBER_W, 0, NOW)
if "off" in vis(r4).lower():
    ok("C4 a recorded branch never masks the offline marker on Row4")
else:
    bad("C4 branch masked the offline state — row4=%r reads as a present teammate" % vis(r4))

# ── D. BUDGET — the wall stays width-bound ────────────────────────────────────
print("\nD. BUDGET: offline segments respect the 8-cell strip")

widths_ok = True
worst = None
for age in (90, 600, 3600, 5 * 3600, 23 * 3600, DAY, 3 * DAY, 6 * DAY, 7 * DAY - 60):
    s = vis(S._team_state_seg({"user": "x", "state": "offline", "ts": NOW - age,
                               "online": False}, NOW))
    if len(s) > S.LAYOUT.TEAM_STRIP_W:
        widths_ok = False
        worst = (age, s)
if widths_ok:
    ok("D1 every offline segment across the whole window fits the 8-cell strip")
else:
    bad("D1 offline segment overflows the strip at age=%s: %r" % worst)

for row in (r1, r2, r3, r4):
    if S.LAYOUT.vis_width(vis(row)) != S.LAYOUT.TEAM_MEMBER_W:
        widths_ok = False
if widths_ok:
    ok("D2 an offline teammate column renders at the exact team-member width")
else:
    bad("D2 offline column broke the exact-width contract")

print("\n" + "=" * 60)
print("wall-offline-window: %d passed, %d failed" % (P_N[0], F_N[0]))
print("=" * 60)
sys.exit(1 if F_N[0] else 0)
PYEOF

python3 "$PY" "$LIB" "$LEDGER" "$STATUSLINE" "$TMP/home"
exit $?

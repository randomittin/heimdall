#!/usr/bin/env bash
# cp-funnel-walk.test.sh — THE SYNTHETIC FUNNEL WALK: drive the launch funnel end-to-end and
# assert every event fires EXACTLY ONCE — not zero (never emitted), not twice (double-counted).
#
# WHY EXACTLY-ONCE IS THE ASSERTION THAT MATTERS. A K-factor is teams-2+ / enrolls. Double-count
# the denominator and the ratio silently halves; double-count the numerator and it doubles. A
# funnel computed off a double-counted stage is WORSE than no metric, because it looks like a
# number and reads like a fact. So every stage here is checked on BOTH failure modes: the
# trigger must move the counter by exactly +1, and every repeat of that trigger must move it
# by exactly 0.
#
# THE WALK DRIVES THE REAL CALL SITES, NEVER THE STAMPS DIRECTLY. Each step runs the actual
# server entry point a real request would run — cp_presence.record_presence for a beat,
# cp_enroll.enroll for a registration. A test that called cp_funnel.stamp_* directly would still
# pass with every call site deleted, which would make the whole suite unfalsifiable. Driving the
# entry points is what makes "suppress an emission -> this goes RED" true (the GATE mutation).
#
# THE FIVE STAGES (init-proxy -> first-verdict -> enroll -> team-2+ -> badge-rendered):
#   1. INIT-PROXY     the first beat EVER from a HAID. The server-side PROXY for `hmd init`:
#                     init is a local command the server cannot see, but the first heartbeat it
#                     sends is a fact the heartbeat ALREADY lawfully delivers.
#   2. FIRST-VERDICT  the first non-empty verdict from a HAID (the activation event).
#   3. ENROLL         the net-new registration (the K-factor DENOMINATOR).
#   4. TEAM-2+        the 1 -> 2 member edge (the K-factor NUMERATOR), write-once even when the
#                     edge is RE-CROSSED after a hygiene eviction.
#   5. BADGE-RENDERED asserted ABSENT ON PURPOSE. `bin/heimdall-badge` renders locally and makes
#                     ZERO network calls, so no server-side signal for it exists or may be
#                     invented — building one would need NEW client egress, which is exactly what
#                     IDENTITY.md:32-38 forbids. Section 5 proves the client is still silent and
#                     that the metric reports UNAVAILABLE rather than a lying 0.
#
# Hermetic: throwaway HOME + local StateBackend, no network, no real GCP. Exit 0 = every event
# fired exactly once.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_funnel cp_enroll cp_presence cp_auth cp_state pmr_corpus; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t cp-funnel-walk)"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# THE WALK — one scripted journey through every stage, recording a counter delta
# at every step. Runs ONCE; sections 1-4 assert different slices of its trace.
# ══════════════════════════════════════════════════════════════════════════════
echo "0. driving the synthetic funnel walk (real call sites, hermetic store)"
HW="$EXT/walk"; mkdir -p "$HW"
WALK="$(HEIMDALL_HOME="$HW" HEIMDALL_ENROLL_OPEN=1 LIB="$LIB" "$PY" - <<'PYEOF' 2>&1
import base64, json, os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_enroll, cp_funnel, cp_presence, cp_state

SECRET = "walk-team-secret-0123456789abcdef0123456789abcdef"
TEAM = cp_auth.derive_team_id(SECRET)
PROJ = "acme/widget"
backend = cp_state.get_backend()
trace = []

def counters():
    """The five funnel counters, read the SAME way the report reads them."""
    return {
        "init_proxy": cp_funnel.init_proxy_count(),
        "first_verdict": cp_funnel.first_verdict_count(),
        "enroll": cp_funnel.enroll_count(),
        "team_grew": cp_funnel.team_grew_count(),
        "active": cp_funnel.active_count(days=7),
    }

def step(label, fn):
    """Run one walk step and record the EXACT delta it produced on every counter."""
    before = counters()
    fn()
    after = counters()
    trace.append({
        "label": label,
        "delta": {k: after[k] - before[k] for k in after},
        "after": after,
    })

def pub(seed):
    return base64.b64encode(bytes([seed]) * 32).decode("ascii")

def beat(haid, verdict=None, ts=None):
    return cp_presence.record_presence(haid, project=PROJ, team_id=TEAM,
                                       verdict=verdict, ts=ts)

def enroll(haid, seed):
    return cp_enroll.enroll(haid, pub(seed), provided_token=None, team_secret=SECRET)

D1 = "haid:walk-d1"

# ── STAGE 1: INIT-PROXY — the first beat EVER is the only one that stamps ──────
# The first beats carry NO verdict, which ISOLATES init-proxy from first-verdict:
# if they were conflated, stage 2 below would show a +1 here instead of there.
step("1a first beat ever (no verdict)", lambda: beat(D1))
step("1b second beat (no verdict)", lambda: beat(D1))
step("1c third beat (no verdict)", lambda: beat(D1))
init_rec_after_first = backend.get_record(cp_funnel.init_proxy_rel(D1))

# ── STAGE 2: FIRST-VERDICT — the first non-empty verdict, and only it ──────────
step("2a empty verdict (not an activation)", lambda: beat(D1, verdict=""))
time.sleep(1.05)
step("2b FIRST non-empty verdict", lambda: beat(D1, verdict="building"))
fv_first = backend.get_record(cp_funnel.first_verdict_rel(D1))
time.sleep(1.05)
step("2c later verdict (must not re-fire)", lambda: beat(D1, verdict="testing"))
fv_later = backend.get_record(cp_funnel.first_verdict_rel(D1))
step("2d another later verdict", lambda: beat(D1, verdict="pass"))

# ── STAGE 3: ENROLL — one line per NET-NEW identity, zero on a re-enroll ───────
step("3a enroll member 1 (net-new)", lambda: enroll("haid:walk-m1", 11))
step("3b RE-enroll member 1 (idempotent)", lambda: enroll("haid:walk-m1", 11))

# ── STAGE 4: TEAM-2+ — the 1 -> 2 edge, once, even when RE-CROSSED ────────────
time.sleep(1.05)
step("4a enroll member 2 (THE 1->2 edge)", lambda: enroll("haid:walk-m2", 12))
grew_first = backend.get_record(cp_funnel.team_grew_rel(TEAM))
time.sleep(1.05)
step("4b enroll member 3 (2->3, not the edge)", lambda: enroll("haid:walk-m3", 13))
grew_after_3 = backend.get_record(cp_funnel.team_grew_rel(TEAM))

# THE RE-CROSSED EDGE. Hygiene evicts members, the team falls back to ONE, and a new dev
# crosses 1 -> 2 a SECOND time. The members_before guard is SATISFIED AGAIN here, so it
# protects nothing — only write-once keeps the original cohort date.
cp_auth.remove_keys(["haid:walk-m2", "haid:walk-m3"], home=None)
members_after_evict = cp_auth.team_member_count(TEAM)
time.sleep(1.05)
step("4c enroll member 4 (RE-CROSSED 1->2 edge)", lambda: enroll("haid:walk-m4", 14))
grew_after_recross = backend.get_record(cp_funnel.team_grew_rel(TEAM))

# ── WAU: an active-day mark is write-once PER (haid, UTC day) ─────────────────
# D1 already beat many times today above; every one of those was the same day, so the
# active counter must have moved exactly once across the WHOLE walk so far.
step("5a a brand-new dev beats (new active day)", lambda: beat("haid:walk-d2"))
step("5b that dev beats again same day", lambda: beat("haid:walk-d2"))

# ── STAGE 5: BADGE-RENDERED — no server-side signal exists, by construction ────
badge_rel_probe = sorted(backend.list_names("funnel", suffix=""))

print(json.dumps({
    "trace": trace,
    "final": counters(),
    "init_rec_after_first": init_rec_after_first,
    "fv_first": fv_first,
    "fv_later": fv_later,
    "grew_first": grew_first,
    "grew_after_3": grew_after_3,
    "grew_after_recross": grew_after_recross,
    "members_after_evict": members_after_evict,
    "members_recrossed": cp_auth.team_member_count(TEAM),
    "funnel_families": badge_rel_probe,
}, sort_keys=True, default=str))
PYEOF
)"
RW="$?"

if [ "$RW" -ne 0 ]; then
  bad "0a the walk did not complete (rc=$RW) -- $WALK"
  echo
  echo "============================================================"
  printf "cp-funnel-walk: %d passed, %d failed\n" "$PASS" "$FAIL"
  echo "============================================================"
  exit 1
fi
ok "0a the walk ran end-to-end through the real call sites"

# A tiny helper: assert one step's delta on one counter is EXACTLY n.
delta_is() { # <label-prefix> <counter> <expected>
  printf '%s' "$WALK" | STEP="$1" CTR="$2" WANT="$3" "$PY" -c '
import json, os, sys
d = json.load(sys.stdin)
step, ctr, want = os.environ["STEP"], os.environ["CTR"], int(os.environ["WANT"])
hits = [t for t in d["trace"] if t["label"].startswith(step)]
assert len(hits) == 1, "step %s matched %d rows" % (step, len(hits))
got = hits[0]["delta"][ctr]
assert got == want, "step %s: %s moved by %d, expected %d" % (step, ctr, got, want)
' >/dev/null 2>&1
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. INIT-PROXY — fires on the first beat ever, exactly once
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "1. init-proxy: the first beat ever stamps exactly once"
if delta_is "1a" init_proxy 1 && delta_is "1b" init_proxy 0 && delta_is "1c" init_proxy 0; then
  ok "1a first beat fires init-proxy exactly ONCE (+1); the 2nd and 3rd beats fire it ZERO more times"
else
  bad "1a init-proxy did not fire exactly once -- $WALK"
fi

# It must ALSO not have fired first-verdict: those beats carried no verdict at all.
if delta_is "1a" first_verdict 0 && delta_is "1b" first_verdict 0; then
  ok "1b a verdict-less beat fires init-proxy but NOT first-verdict (the stages are not conflated)"
else
  bad "1b a verdict-less beat moved the first-verdict counter -- $WALK"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. FIRST-VERDICT — fires on the first non-empty verdict, exactly once
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "2. first-verdict: the first non-empty verdict stamps exactly once"
if delta_is "2a" first_verdict 0 && delta_is "2b" first_verdict 1 \
   && delta_is "2c" first_verdict 0 && delta_is "2d" first_verdict 0; then
  ok "2a an EMPTY verdict fires nothing; the first non-empty one fires exactly ONCE; two later verdicts fire ZERO more"
else
  bad "2a first-verdict did not fire exactly once -- $WALK"
fi

if printf '%s' "$WALK" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
f, l = d["fv_first"], d["fv_later"]
assert isinstance(f, dict) and isinstance(f.get("first_verdict_at"), (int, float)), f
assert l == f, "a LATER verdict MOVED the activation instant: %r -> %r" % (f, l)
' >/dev/null 2>&1; then
  ok "2b the activation INSTANT is preserved -- a later verdict never moves first_verdict_at"
else
  bad "2b the activation instant moved -- $WALK"
fi

# The stamp must not have landed on the presence doc (which is rebuilt every beat and
# tombstoned by a retire). Re-beating above would have destroyed it if it had.
if printf '%s' "$WALK" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
assert d["final"]["first_verdict"] == 1, d["final"]
assert isinstance(d["fv_later"], dict), "the stamp did not survive 2 later beats"
' >/dev/null 2>&1; then
  ok "2c the stamp SURVIVED 2 subsequent beats -- it is on its own durable doc, not the last-write-wins presence record"
else
  bad "2c the stamp died on a later beat -- $WALK"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. ENROLL — one line per NET-NEW identity, zero on a re-enroll
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "3. enroll: a net-new registration counts once; a re-enroll counts zero"
if delta_is "3a" enroll 1 && delta_is "3b" enroll 0; then
  ok "3a a net-new enroll appends exactly ONE spool line; re-enrolling the SAME identity appends ZERO (no double-counted denominator)"
else
  bad "3a the enroll denominator double-counted or missed -- $WALK"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. TEAM-2+ — the 1 -> 2 edge, exactly once, even RE-CROSSED
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "4. team-2+: the 1->2 edge fires once; 2->3 and a RE-CROSSED 1->2 fire zero"
if delta_is "3a" team_grew 0 && delta_is "4a" team_grew 1 \
   && delta_is "4b" team_grew 0 && delta_is "4c" team_grew 0; then
  ok "4a the 0->1 and 2->3 edges fire ZERO; the 1->2 edge fires exactly ONCE; the RE-CROSSED 1->2 fires ZERO"
else
  bad "4a the K-factor numerator did not fire exactly once -- $WALK"
fi

if printf '%s' "$WALK" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
g = d["grew_first"]
assert isinstance(g, dict) and isinstance(g.get("first_second_member_at"), (int, float)), g
assert d["grew_after_3"] == g, "the 2->3 enroll OVERWROTE the cohort date"
assert d["members_after_evict"] == 1, d["members_after_evict"]
assert d["members_recrossed"] == 2, d["members_recrossed"]
assert d["grew_after_recross"] == g, "the RE-CROSSED 1->2 edge OVERWROTE the cohort date"
' >/dev/null 2>&1; then
  ok "4b the COHORT DATE is preserved across a hygiene eviction and a re-crossed 1->2 edge (write-once, not the members_before guard)"
else
  bad "4b the cohort date was overwritten -- $WALK"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. WAU — an active-day mark is write-once per (haid, UTC day)
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "5. WAU: an active-day mark is write-once per (haid, UTC day)"
if delta_is "5a" active 1 && delta_is "5b" active 0; then
  ok "5a a new dev's first beat of the day marks active exactly ONCE; a second beat the same day marks ZERO more"
else
  bad "5a the active-day mark double-counted or missed -- $WALK"
fi

# Across the WHOLE walk: 2 distinct devs beat (D1 many times, D2 twice) -> WAU is exactly 2,
# never the number of beats. This is the assertion that catches a per-beat (not per-dev) counter.
if printf '%s' "$WALK" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
f = d["final"]
assert f["active"] == 2, "WAU counted beats, not distinct devs: %r" % (f["active"],)
assert f["init_proxy"] == 2, f["init_proxy"]
assert f["first_verdict"] == 1, f["first_verdict"]
assert f["enroll"] == 4, f["enroll"]
assert f["team_grew"] == 1, f["team_grew"]
' >/dev/null 2>&1; then
  ok "5b WAU counts DISTINCT DEVS (2), not beats (10) -- and the final funnel is init=2, verdict=1, enroll=4, team2+=1"
else
  bad "5b the final funnel counts are wrong -- $WALK"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. BADGE-RENDERED — absent BY CONSTRUCTION; the client stays silent
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "6. badge-rendered: no server-side signal exists, and none was invented"
# 6a the badge renders LOCALLY: zero outbound primitives in the client.
#     `curl` is matched ONLY IN COMMAND POSITION -- start of line, or after a control operator
#     ( ; & | ( ) { } ` $( ), optionally through a modifier word (sudo/env/exec/if/!/...) --
#     because that, not the mere presence of the word, is what makes the shell RUN it. The token
#     inside `echo "... curl ..."` or after a `#` is an argument or a comment: inert text, not
#     egress. A bare \bcurl\b red on the reinstall help line that half of bin/ prints, and a
#     privacy gate that cries wolf on documentation gets muted -- taking the real red with it.
#     Nothing is given up: curl|bash, $(curl ...), backtick, sudo curl and piped-into curl are
#     all still caught (test/cp-funnel.test.sh 4e calibrates this exact pattern on a fixture of
#     both shapes). The file MUST exist -- a missing file makes `! grep` succeed, which would
#     turn a deleted badge into a silent PASS.
EGRESS_RX='urllib\.request|urlopen|http\.client|httplib|requests\.(get|post|put|request)|socket\.(socket|create_connection)|subprocess.*curl|(^|[;&|(){}`]|\$\()[[:space:]]*((if|then|else|elif|do|while|until|!|sudo|env|exec|command|nohup|time|xargs)[[:space:]]+)*curl([[:space:]]|$)'
if [ ! -f "$REPO/bin/heimdall-badge" ]; then
  bad "6a bin/heimdall-badge is MISSING -- the no-egress scan covered nothing"
elif ! grep -qE "$EGRESS_RX" "$REPO/bin/heimdall-badge"; then
  ok "6a bin/heimdall-badge has ZERO outbound primitives -- a badge render is invisible to the server, so no lawful stamp for it can exist"
else
  bad "6a heimdall-badge gained a network call -- a badge-render beacon BREAKS IDENTITY.md:32-38"
fi

# 6b no funnel family for it was invented (inventing one would require new client egress).
if printf '%s' "$WALK" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
fams = d["funnel_families"]
assert not any("badge" in f for f in fams), "a badge funnel family was invented: %r" % (fams,)
' >/dev/null 2>&1; then
  ok "6b no badge-rendered funnel family exists -- the stage is reported UNAVAILABLE, never faked as a 0"
else
  bad "6b a badge funnel family appeared -- $WALK"
fi

echo
echo "============================================================"
printf "cp-funnel-walk: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

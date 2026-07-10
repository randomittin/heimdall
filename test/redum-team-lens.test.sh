#!/usr/bin/env bash
# test/redum-team-lens.test.sh — the TEAM LENS on F3 Redum (the code∪work BRIDGE).
#
# Redum today sees ONLY the local repo file index (grep haid|team|claim bin/lib/redum.py = 0).
# The team lens folds OTHER teammates' ACTIVE claims + SHARED checkpoints into the reuse
# surfacing, so plan-time advice says not just "this code EXISTS in the repo" but "Raj is
# BUILDING this right now (his claim + checkpoint) — don't reinvent OR redo it".
#
# ONE read-model, TWO guarantees (the bridge):
#   * active claim  -> class teammate-in-flight  ("coordinate/reuse, do NOT reinvent")  PREVENTION
#   * dropped ckpt  -> class adoptable-dropped    ("adopt/resume, do NOT redo")         RECOVERY
#
# Falsifiers (each RED before the team lens exists):
#   F1  team-lens surfaces a teammate's ACTIVE claimed surface as a reuse candidate
#   F2  the team residual signal at the gate is WARN — never a block verdict (no exit-3)
#   F3  a LOCAL same-repo duplicate STILL hard-blocks (verdict=block preserved)
#   F4  TEAM ISOLATION — a DIFFERENT team's ledger (a different planning dir) NEVER surfaces
#   F5  a REAPED teammate (checkpoint survives, claim dropped) -> adoptable-dropped (RECOVERY)
#   F6  SOLO-PATH byte-identical — team lens OFF adds zero keys (no regression)
#
# Isolated temp planning dirs, no network, cleaned up on exit.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -f "$ROOT/bin/lib/redum.py" ] || { echo "FATAL: redum.py missing" >&2; exit 2; }

WORK="$(mktemp -d -t "redum-team.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

REDUM_LIB="$ROOT/bin/lib" WORK="$WORK" python3 - <<'PYEOF'
import json, os, re, sys, datetime

sys.path.insert(0, os.environ["REDUM_LIB"])
import redum
import checkpoint_share as cp

WORK = os.environ["WORK"]
PASS = {"n": 0}
FAIL = {"n": 0}
def ok(m):  PASS["n"] += 1; print("  \033[32mPASS\033[0m %s" % m)
def bad(m): FAIL["n"] += 1; print("  \033[31mFAIL\033[0m %s" % m)

# ── fixed clock so TTL math is hermetic (no wall-clock flake) ──────────────────
NOW = 1_800_000_000                      # a fixed epoch
def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)\
        .strftime("%Y-%m-%dT%H:%M:%SZ")

def slug(haid):
    return re.sub(r"[/:]", "_", haid)

def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=2)

def new_plan(name):
    """A fresh, isolated .planning dir (one team's ledger)."""
    d = os.path.join(WORK, name, ".planning")
    os.makedirs(os.path.join(d, "ledger", "claims"), exist_ok=True)
    os.makedirs(os.path.join(d, "ledger", "checkpoints"), exist_ok=True)
    return d

def put_claim(plan, haid, surfaces, *, heartbeat_epoch, ttl=60, human=None):
    write_json(os.path.join(plan, "ledger", "claims", slug(haid) + ".json"), {
        "haid": haid, "human": human or cp.haid_human(haid),
        "claimed_surfaces": surfaces, "task_ref": "t",
        "claimed_at": iso(heartbeat_epoch), "ttl_minutes": ttl,
        "heartbeat": iso(heartbeat_epoch),
    })

def put_checkpoint(plan, haid, surfaces, *, phase="build", pct=40, human=None):
    write_json(os.path.join(plan, "ledger", "checkpoints", slug(haid) + ".json"), {
        "schema": cp.SCHEMA, "haid": haid, "human": human or cp.haid_human(haid),
        "branch": "feat/x", "head_sha": "abc123", "phase": phase, "progress_pct": pct,
        "active_goal": "[dropped]", "claimed_surfaces": sorted(surfaces),
        "task_ref": "t", "updated_at": iso(NOW), "resumable": True,
    })

ME = "haid:me.myhost-0001"
RAJ = "haid:raj.rajhost-abcd"

# ════════════════════════════════════════════════════════════════════════════
# F1 — team lens surfaces a teammate's ACTIVE claimed surface as a reuse candidate
# ════════════════════════════════════════════════════════════════════════════
plan = new_plan("f1")
os.environ["HEIMDALL_PLANNING_DIR"] = plan
put_claim(plan, RAJ, ["auth/session.ts#rotateToken"], heartbeat_epoch=NOW - 60)  # fresh, active
put_checkpoint(plan, RAJ, ["auth/session.ts#rotateToken"], phase="build", pct=40)

res = redum.factor_for_task(
    "add rotateToken rotation to auth/session.ts",
    repo_files={}, team_lens=True, my_haid=ME, repo_root=plan, now=NOW)

tc = res.get("team_candidates", [])
hit = [c for c in tc if c.get("surface") == "auth/session.ts#rotateToken"]
if hit and hit[0].get("class") == "teammate-in-flight" and hit[0].get("human") == "raj":
    ok("F1 active teammate surface surfaced as reuse candidate (class=teammate-in-flight, human=raj)")
else:
    bad("F1 teammate in-flight surface NOT surfaced: team_candidates=%r" % tc)

# and the advice must name the coordinate-don't-reinvent guidance.
if "team_advice" in res and re.search(r"reinvent|coordinate|in-flight|building", res["team_advice"], re.I):
    ok("F1 team_advice names the coordinate/don't-reinvent guidance")
else:
    bad("F1 team_advice missing/weak: %r" % res.get("team_advice"))

# NO leak: the teammate's active_goal prose is never echoed into a candidate.
serialized = json.dumps(tc)
if "[dropped]" not in serialized and "active_goal" not in serialized:
    ok("F1 team candidates carry NO free-form goal prose (leak surface = 0)")
else:
    bad("F1 team candidate leaked goal prose: %s" % serialized)

# ════════════════════════════════════════════════════════════════════════════
# F2 — team residual signal at the gate is WARN, never a block verdict (no exit-3)
# ════════════════════════════════════════════════════════════════════════════
plan = new_plan("f2")
os.environ["HEIMDALL_PLANNING_DIR"] = plan
put_claim(plan, RAJ, ["auth/session.ts#rotateToken"], heartbeat_epoch=NOW - 60)  # active

# an attestation with NO local duplicate (clean reuse) — the ONLY signal is the team overlap.
clean_att = {"reuse": {"reuse_pct": 0.95, "suspected_duplicates": []}}
gres = redum.gate_attestation(
    clean_att,
    repo_files={"auth/session.ts": "export function rotateToken(){return 1}\n"},
    changed_files={"auth/session.ts": "export function rotateToken(){return 1}\n"},
    policy="block", team_lens=True, my_haid=ME, repo_root=plan, now=NOW)

if gres["verdict"] != "block":
    ok("F2 team overlap does NOT block (verdict=%s, never exit-3)" % gres["verdict"])
else:
    bad("F2 team overlap WRONGLY blocked (verdict=block)")

sigs = gres.get("team_signals", [])
if sigs and all(s.get("level") == "warn" for s in sigs) and any(RAJ == s.get("haid") for s in sigs):
    ok("F2 team residual emitted as WARN signal naming the teammate (%d signal(s))" % len(sigs))
else:
    bad("F2 team residual signal missing/not-warn: %r" % sigs)

# the team signal must NEVER be a high flag (a high flag would escalate the verdict).
if not any(f.get("level") == "high" for f in gres.get("flags", [])):
    ok("F2 no HIGH flag raised by a pure team overlap (verdict stays non-block)")
else:
    bad("F2 a HIGH flag was raised by team overlap: %r" % gres.get("flags"))

# ════════════════════════════════════════════════════════════════════════════
# F3 — a LOCAL same-repo duplicate STILL hard-blocks (verdict=block preserved)
# ════════════════════════════════════════════════════════════════════════════
plan = new_plan("f3")
os.environ["HEIMDALL_PLANNING_DIR"] = plan
put_claim(plan, RAJ, ["auth/session.ts#rotateToken"], heartbeat_epoch=NOW - 60)  # a team overlap too

# a genuine LOCAL residual duplicate (SI-2 flagged) — with the team lens ON.
dup_att = {"reuse": {"reuse_pct": 0.10,
                     "suspected_duplicates": [{"duplicates": "selectCards", "new_unit": "selectCards"}]}}
bres = redum.gate_attestation(
    dup_att, policy="block", team_lens=True, my_haid=ME, repo_root=plan, now=NOW)
if bres["verdict"] == "block":
    ok("F3 LOCAL same-repo duplicate STILL hard-blocks (verdict=block) with team lens ON")
else:
    bad("F3 local duplicate no longer blocks (verdict=%s) — team lens broke the hard gate" % bres["verdict"])

# and the block came from a HIGH local flag (residual-duplicate / low-reuse), not the team.
local_high = [f for f in bres["flags"] if f["level"] == "high"
              and f["code"] in ("residual-duplicate", "low-reuse")]
if local_high:
    ok("F3 block is driven by the LOCAL high flag (%s)" % ", ".join(f["code"] for f in local_high))
else:
    bad("F3 block not driven by a local high flag: %r" % bres["flags"])

# ════════════════════════════════════════════════════════════════════════════
# F4 — TEAM ISOLATION: a DIFFERENT team's ledger (different planning dir) NEVER surfaces
# ════════════════════════════════════════════════════════════════════════════
mine = new_plan("f4-mine")
other = new_plan("f4-other")          # a DIFFERENT team's ledger
OTHERDEV = "haid:mallory.evilhost-9999"
put_claim(other, OTHERDEV, ["secret/leaked.ts#stealToken"], heartbeat_epoch=NOW - 60)
put_checkpoint(other, OTHERDEV, ["secret/leaked.ts#stealToken"], pct=50)
# my ledger is EMPTY of that surface.
os.environ["HEIMDALL_PLANNING_DIR"] = mine
res4 = redum.factor_for_task(
    "add stealToken to secret/leaked.ts", repo_files={},
    team_lens=True, my_haid=ME, repo_root=mine, now=NOW)
tc4 = res4.get("team_candidates", [])
if not any("leaked.ts" in c.get("surface", "") or c.get("haid") == OTHERDEV for c in tc4):
    ok("F4 a DIFFERENT team's claim/checkpoint NEVER surfaced (isolation holds)")
else:
    bad("F4 CROSS-TEAM LEAK — another team's surface appeared: %r" % tc4)

# ════════════════════════════════════════════════════════════════════════════
# F5 — a REAPED teammate (checkpoint survives, claim dropped) -> adoptable-dropped
# ════════════════════════════════════════════════════════════════════════════
plan = new_plan("f5")
os.environ["HEIMDALL_PLANNING_DIR"] = plan
# claim is TTL-EXPIRED (dropped/reaped): heartbeat far in the past, ttl 60min.
put_claim(plan, RAJ, ["billing/invoice.ts#renderPdf"], heartbeat_epoch=NOW - 7200, ttl=60)
# but the checkpoint SURVIVES (git-committed, redundant) and is NOT completed.
put_checkpoint(plan, RAJ, ["billing/invoice.ts#renderPdf"], phase="build", pct=55)
res5 = redum.factor_for_task(
    "add renderPdf to billing/invoice.ts", repo_files={},
    team_lens=True, my_haid=ME, repo_root=plan, now=NOW)
tc5 = res5.get("team_candidates", [])
adopt = [c for c in tc5 if c.get("surface") == "billing/invoice.ts#renderPdf"]
if adopt and adopt[0].get("class") == "adoptable-dropped" and adopt[0].get("adoptable") is True:
    ok("F5 reaped teammate's checkpoint surface -> adoptable-dropped (RECOVERY, don't redo)")
else:
    bad("F5 dropped-work recovery not surfaced as adoptable: %r" % tc5)

# an EXPIRED claim alone (no surviving checkpoint) must NOT surface as in-flight (it's gone).
plan_b = new_plan("f5b")
os.environ["HEIMDALL_PLANNING_DIR"] = plan_b
put_claim(plan_b, RAJ, ["gone/dead.ts#zap"], heartbeat_epoch=NOW - 7200, ttl=60)  # expired, no ckpt
res5b = redum.factor_for_task(
    "add zap to gone/dead.ts", repo_files={},
    team_lens=True, my_haid=ME, repo_root=plan_b, now=NOW)
if not res5b.get("team_candidates"):
    ok("F5 an expired claim with NO surviving checkpoint does NOT surface (nothing to reuse)")
else:
    bad("F5 an expired-claim-only surface wrongly surfaced: %r" % res5b.get("team_candidates"))

# ════════════════════════════════════════════════════════════════════════════
# F6 — SOLO-PATH byte-identical: team lens OFF adds ZERO keys (no regression)
# ════════════════════════════════════════════════════════════════════════════
solo = redum.factor_for_task("add rotateToken to auth/session.ts", repo_files={})
if set(solo.keys()) == {"task", "candidates", "concepts", "advice"}:
    ok("F6 factor_for_task solo path returns exactly the 4 legacy keys (no team keys)")
else:
    bad("F6 solo factor path grew keys: %r" % sorted(solo.keys()))

solo_g = redum.gate_attestation({"reuse": {"reuse_pct": 0.9, "suspected_duplicates": []}})
if "team_signals" not in solo_g:
    ok("F6 gate_attestation solo path carries NO team_signals key (byte-identical)")
else:
    bad("F6 solo gate path grew a team_signals key")

# ── summary ────────────────────────────────────────────────────────────────────
print()
print("redum-team-lens: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m" % (PASS["n"], FAIL["n"]))
sys.exit(0 if FAIL["n"] == 0 else 1)
PYEOF
RC=$?
echo
[ "$RC" -eq 0 ] && echo "redum-team-lens: OK — team lens surfaces in-flight + adoptable, WARN-not-block, isolated" \
               || echo "redum-team-lens: FAILED"
exit "$RC"

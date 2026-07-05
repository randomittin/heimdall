#!/usr/bin/env bash
# heimdall-cp-team-queue.test.sh — acceptance for the TEAM-PARTITIONED work queue
# (bin/lib/cp_team_queue.py), the additive multi-tenant layer OVER issue_queue's
# score/pick/dedup/claim semantics.
#
# HERMETIC: LocalBackend only (HEIMDALL_STATE_BACKEND=local), a throwaway HEIMDALL_HOME,
# no network, no live model, no control-plane server. Every proof runs against the REAL
# lib.
#
# Proves:
#   A. enqueue -> pick -> complete round-trip PER TEAM (the per-partition happy path).
#   B. CROSS-TENANT ISOLATION (the cardinal invariant, falsifiable): team A's pick / list /
#      depth NEVER return team B's items; a task team A enqueued is invisible to team B; and
#      team B cannot complete team A's item. Two-team fixture.
#   C. CROSS-TENANT DRAIN DENIED (explicit): team B pick()s its OWN (empty) partition to
#      exhaustion and NEVER drains a single one of team A's queued items — A's depth is
#      untouched by B draining.
#   D. DEDUP within a partition — the same task text enqueued twice adds once (idempotent).
#   E. ATOMIC PICK — N concurrent picks in ONE partition never double-claim an item (every
#      picked id is distinct; the claimed count equals the enqueued count).
#   F. BOUNDED + SCRUBBED enqueue — an oversized task is TRIMMED; a secret-shaped task is
#      REDACTED (no secret substring survives in the stored record).
#   G. FAIL-CLOSED on a missing team_id — every op raises rather than running unscoped.
#   H. PRIORITY — pick honors issue_queue's scorer (a higher-severity item outranks a
#      plain one) within a partition.
#
# Exit 0 = "N passed, 0 failed". Any failure is non-zero.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib"
SRC="$LIB/cp_team_queue.py"
export LIB ROOT

for f in cp_team_queue cp_state issue_queue telemetry; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-team-queue.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

export HEIMDALL_HOME="$WORK/home"
mkdir -p "$HEIMDALL_HOME"
export HEIMDALL_STATE_BACKEND="local"

# Two DISTINCT team_id partition handles (32-hex, the derive_team_id shape). Same shape a
# real team_id has; the queue only ever sees the non-secret handle.
TEAM_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TEAM_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
export TEAM_A TEAM_B

echo "============================================================"
echo "TEAM-PARTITIONED WORK QUEUE (LocalBackend, hermetic)"
echo "  home=$HEIMDALL_HOME  backend=$HEIMDALL_STATE_BACKEND"
echo "============================================================"
echo

# ──────────────────────────────────────────────────────────────────────────────
# A. enqueue -> pick -> complete round-trip PER TEAM.
# ──────────────────────────────────────────────────────────────────────────────
echo "A. enqueue -> pick -> complete round-trip (per team)"
A_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/a.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
A = os.environ["TEAM_A"]
e = Q.enqueue(A, "fix the login bug")
picked = Q.pick(A)
comp = Q.complete(A, picked["id"], "PROVEN")
after = Q.pick(A)  # nothing left -> None
print(json.dumps({
    "enq_ok": e.get("ok") and e.get("added"),
    "picked_text": picked.get("text") if picked else None,
    "picked_id_matches": bool(picked and picked["id"] == e["id"]),
    "comp_ok": comp.get("ok") and comp.get("verdict") == "PROVEN",
    "empty_after": after is None,
}))
PYEOF
)"
if [ -s "$WORK/a.err" ]; then cat "$WORK/a.err" >&2; fi
ja(){ printf '%s' "$A_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(ja enq_ok)" = "True" ] && ok "A1 enqueue adds a task to the team partition" || bad "A1 enqueue failed (A_OUT=$A_OUT)"
[ "$(ja picked_text)" = "fix the login bug" ] && [ "$(ja picked_id_matches)" = "True" ] \
  && ok "A2 pick claims the enqueued task (text + id round-trip)" || bad "A2 pick mismatch (A_OUT=$A_OUT)"
[ "$(ja comp_ok)" = "True" ] && ok "A3 complete records the verdict (PROVEN)" || bad "A3 complete failed (A_OUT=$A_OUT)"
[ "$(ja empty_after)" = "True" ] && ok "A4 a second pick returns None (the claimed item is out of the pick set)" || bad "A4 item re-picked (A_OUT=$A_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# B. CROSS-TENANT ISOLATION — A's pick/list/depth NEVER return B's items (falsifiable).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "B. cross-tenant isolation (two-team fixture)"
B_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/b.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
A = os.environ["TEAM_A"]; B = os.environ["TEAM_B"]
# A enqueues a SECRET-project task; B enqueues its own.
ea = Q.enqueue(A, "team-A-only: rotate the prod keys")
eb = Q.enqueue(B, "team-B-only: ship the marketing site")
# team B list / depth must NOT see the team A item.
b_list_ids = [r["item"]["text"] for r in Q.list(B) if r["item"]]
a_list_ids = [r["item"]["text"] for r in Q.list(A) if r["item"]]
# team B pick must return the team B item (or None), NEVER the team A item.
b_pick = Q.pick(B)
# team B tries to complete the team A item id -> must be refused (unknown in B partition).
b_steal = Q.complete(B, ea["id"], "PROVEN")
print(json.dumps({
    "a_has_own": "team-A-only: rotate the prod keys" in a_list_ids,
    "a_no_b":    "team-B-only: ship the marketing site" not in a_list_ids,
    "b_has_own": "team-B-only: ship the marketing site" in b_list_ids,
    "b_no_a":    "team-A-only: rotate the prod keys" not in b_list_ids,
    "b_pick_is_b": bool(b_pick and b_pick["text"] == "team-B-only: ship the marketing site"),
    "b_pick_not_a": bool(b_pick and b_pick["text"] != "team-A-only: rotate the prod keys"),
    "b_cannot_complete_a": (b_steal.get("ok") is False and b_steal.get("reason") == "unknown_id"),
    "a_depth": Q.depth(A), "b_depth_after_pick": Q.depth(B),
}))
PYEOF
)"
if [ -s "$WORK/b.err" ]; then cat "$WORK/b.err" >&2; fi
jb(){ printf '%s' "$B_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jb a_has_own)" = "True" ] && [ "$(jb b_has_own)" = "True" ] \
  && ok "B1 each team's list shows its OWN item" || bad "B1 own-item missing (B_OUT=$B_OUT)"
[ "$(jb a_no_b)" = "True" ] && [ "$(jb b_no_a)" = "True" ] \
  && ok "B2 neither team's list contains the OTHER team's item (invisible across partitions)" || bad "B2 CROSS-TENANT LEAK in list (B_OUT=$B_OUT)"
[ "$(jb b_pick_is_b)" = "True" ] && [ "$(jb b_pick_not_a)" = "True" ] \
  && ok "B3 team B's pick returns B's item, NEVER A's (THE LEAK FALSIFIER)" || bad "B3 pick crossed teams (B_OUT=$B_OUT)"
[ "$(jb b_cannot_complete_a)" = "True" ] \
  && ok "B4 team B CANNOT complete team A's item id (unknown in B's partition)" || bad "B4 cross-tenant complete allowed (B_OUT=$B_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# C. CROSS-TENANT DRAIN DENIED (explicit) — B drains ITS OWN partition to empty and
#    NEVER touches A's queued item; A's depth is unchanged by B draining.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "C. cross-tenant-drain-denied (B drains, A untouched)"
C_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/c.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
A = os.environ["TEAM_A"]; B = os.environ["TEAM_B"]
# Fresh, deterministic state for A: two queued items A did not have drained yet.
Q.enqueue(A, "A-task-1: audit the invoices")
Q.enqueue(A, "A-task-2: reconcile the ledger")
a_depth_before = Q.depth(A)
# B drains ITS partition to exhaustion (drain loop until None). B must NEVER see an A item.
drained_by_b = []
while True:
    p = Q.pick(B)
    if p is None:
        break
    drained_by_b.append(p["text"])
a_depth_after = Q.depth(A)
leaked_a = [t for t in drained_by_b if t.startswith("A-task")]
print(json.dumps({
    "b_drained_no_a": leaked_a == [],
    "a_depth_unchanged": (a_depth_before == a_depth_after and a_depth_before >= 2),
    "drained_by_b": drained_by_b,
}))
PYEOF
)"
if [ -s "$WORK/c.err" ]; then cat "$WORK/c.err" >&2; fi
jc(){ printf '%s' "$C_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jc b_drained_no_a)" = "True" ] \
  && ok "C1 team B draining its partition NEVER drains an A task (cross-tenant-drain-denied)" || bad "C1 B drained an A task (C_OUT=$C_OUT)"
[ "$(jc a_depth_unchanged)" = "True" ] \
  && ok "C2 team A's queue depth is UNCHANGED by team B draining (partitions independent)" || bad "C2 A's depth moved under B's drain (C_OUT=$C_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# D. DEDUP within a partition — same text twice adds once.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "D. dedup within a partition"
D_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/d.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
# A throwaway team so this proof is independent of A/B state above.
T = "dddddddddddddddddddddddddddddddd"
e1 = Q.enqueue(T, "identical task text")
e2 = Q.enqueue(T, "identical task text")
print(json.dumps({
    "first_added": e1.get("added") is True,
    "second_dedup": (e2.get("ok") is True and e2.get("added") is False),
    "same_id": e1.get("id") == e2.get("id"),
    "depth_is_one": Q.depth(T) == 1,
}))
PYEOF
)"
if [ -s "$WORK/d.err" ]; then cat "$WORK/d.err" >&2; fi
jd(){ printf '%s' "$D_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jd first_added)" = "True" ] && [ "$(jd second_dedup)" = "True" ] && [ "$(jd same_id)" = "True" ] && [ "$(jd depth_is_one)" = "True" ] \
  && ok "D1 the same task text enqueued twice adds ONCE (idempotent dedup by id)" || bad "D1 dedup failed (D_OUT=$D_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# E. ATOMIC PICK — N concurrent picks in ONE partition never double-claim.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "E. atomic pick (no double-claim under concurrent picks)"
# Fresh team; enqueue N items; launch 2N concurrent pick processes each writing its picked
# id (or 'NONE') to its own file. Then assert: every non-NONE id is DISTINCT and their count
# equals N (each item claimed exactly once, never twice).
N=12
E_TEAM="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
export E_TEAM N_ITEMS="$N"
"$PY" - <<'PYEOF' 2>"$WORK/e_seed.err"
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
T = os.environ["E_TEAM"]
for i in range(int(os.environ["N_ITEMS"])):
    Q.enqueue(T, "concurrent-item-%02d" % i)
PYEOF
if [ -s "$WORK/e_seed.err" ]; then cat "$WORK/e_seed.err" >&2; fi
PIDS=""
OUTDIR="$WORK/picks"
mkdir -p "$OUTDIR"
i=0
while [ "$i" -lt $((2 * N)) ]; do
  ( PICK_OUT="$OUTDIR/pick_$i" "$PY" - <<'PYEOF' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
p = Q.pick(os.environ["E_TEAM"])
with open(os.environ["PICK_OUT"], "w") as fh:
    fh.write(p["id"] if p else "NONE")
PYEOF
  ) &
  PIDS="$PIDS $!"
  i=$((i + 1))
done
for pid in $PIDS; do wait "$pid"; done
# Collect the non-NONE picked ids; assert distinct count == N and no duplicates.
E_OUT="$(N_ITEMS="$N" OUTDIR="$OUTDIR" "$PY" - <<'PYEOF' 2>"$WORK/e.err"
import json, os
ids = []
for name in os.listdir(os.environ["OUTDIR"]):
    with open(os.path.join(os.environ["OUTDIR"], name)) as fh:
        v = fh.read().strip()
    if v and v != "NONE":
        ids.append(v)
n = int(os.environ["N_ITEMS"])
print(json.dumps({
    "claimed_count": len(ids),
    "distinct_count": len(set(ids)),
    "no_double_claim": len(ids) == len(set(ids)),
    "all_claimed": len(set(ids)) == n,
}))
PYEOF
)"
if [ -s "$WORK/e.err" ]; then cat "$WORK/e.err" >&2; fi
je(){ printf '%s' "$E_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(je no_double_claim)" = "True" ] \
  && ok "E1 no item was claimed twice under $((2 * N)) concurrent picks (atomic claim-before-work)" || bad "E1 DOUBLE-CLAIM under concurrency (E_OUT=$E_OUT)"
[ "$(je all_claimed)" = "True" ] \
  && ok "E2 every one of the $N enqueued items was claimed exactly once" || bad "E2 not every item claimed exactly once (E_OUT=$E_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# F. BOUNDED + SCRUBBED enqueue.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "F. bounded + scrubbed enqueue"
F_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/f.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
T = "ffffffffffffffffffffffffffffffff"
# Oversized: 10k chars -> trimmed to the cap (<= _TASK_MAX_CHARS).
big = "x" * 10000
eb = Q.enqueue(T, big)
pb = Q.pick(T)
# Secret-shaped: a GitHub PAT + an assigned-credential shape -> redacted, not stored.
secret = "deploy with token=ASSIGNED_CRED_SENTINEL_notreal and key ghp_" + ("a" * 36)
es = Q.enqueue(T, secret)
ps = Q.pick(T)
stored = ps["text"] if ps else ""
print(json.dumps({
    "trimmed": len(pb["text"]) <= Q._TASK_MAX_CHARS and len(pb["text"]) < 10000,
    "no_ghp": "ghp_" not in stored,
    "no_assigned": "token=ASSIGNED_CRED_SENTINEL_notreal" not in stored,
    "redaction_present": Q._REDACTION in stored,
}))
PYEOF
)"
if [ -s "$WORK/f.err" ]; then cat "$WORK/f.err" >&2; fi
jf(){ printf '%s' "$F_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jf trimmed)" = "True" ] && ok "F1 an oversized task is TRIMMED to the size cap" || bad "F1 oversized task not trimmed (F_OUT=$F_OUT)"
[ "$(jf no_ghp)" = "True" ] && [ "$(jf no_assigned)" = "True" ] && [ "$(jf redaction_present)" = "True" ] \
  && ok "F2 a secret-shaped task is REDACTED (no secret substring survives in the record)" || bad "F2 secret survived enqueue (F_OUT=$F_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# G. FAIL-CLOSED on a missing team_id.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "G. fail-closed on missing team_id"
G_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/g.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
def raises(fn):
    try:
        fn()
        return False
    except ValueError:
        return True
    except Exception:
        return False
res = {
    "enqueue_none": raises(lambda: Q.enqueue(None, "x")),
    "enqueue_empty": raises(lambda: Q.enqueue("", "x")),
    "enqueue_blank": raises(lambda: Q.enqueue("   ", "x")),
    "pick_none": raises(lambda: Q.pick(None)),
    "list_none": raises(lambda: Q.list(None)),
    "depth_none": raises(lambda: Q.depth(None)),
    "complete_none": raises(lambda: Q.complete(None, "id", "PROVEN")),
}
print(json.dumps(res))
PYEOF
)"
if [ -s "$WORK/g.err" ]; then cat "$WORK/g.err" >&2; fi
jg(){ printf '%s' "$G_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
ALL_G="$(printf '%s' "$G_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(all(d.values()))" 2>/dev/null)"
[ "$ALL_G" = "True" ] \
  && ok "G1 every op (enqueue/pick/list/depth/complete) RAISES on a missing/blank team_id (fail-closed)" || bad "G1 an op ran unscoped on a missing team_id (G_OUT=$G_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# H. PRIORITY — pick honors issue_queue's scorer within a partition.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "H. priority (issue_queue scorer within a partition)"
H_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/h.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
T = "11111111111111111111111111111111"
Q.enqueue(T, {"text": "low: tidy the docs", "severity": "low"})
Q.enqueue(T, {"text": "critical: prod is down", "severity": "critical"})
first = Q.pick(T)
print(json.dumps({"critical_first": bool(first and first["text"] == "critical: prod is down")}))
PYEOF
)"
if [ -s "$WORK/h.err" ]; then cat "$WORK/h.err" >&2; fi
jh(){ printf '%s' "$H_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jh critical_first)" = "True" ] \
  && ok "H1 pick selects the higher-severity item first (reuses issue_queue.pick_order)" || bad "H1 priority order wrong (H_OUT=$H_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# I. RETRY SEMANTICS — a task whose dispatch FAILED must NOT be permanently consumed.
#    retry() returns a claimed (in_flight) task to `queued`, bumping a bounded `attempts`
#    counter; at the cap it moves to a terminal `dead` bucket instead of re-queuing
#    forever. A fresh enqueue of the SAME content-deterministic text RE-OPENS a dead task
#    (the human is asking to retry it). A genuinely-dispatched `done` task is NOT re-opened
#    (idempotency preserved). requeue() defers an in_flight task WITHOUT burning an attempt.
#    THE BUG THIS GUARDS: drain used to complete() every picked task regardless of dispatch
#    outcome, so a refused dispatch (arm=None, no job) permanently consumed the task -> the
#    idempotent re-enqueue no-oped -> the queue had no pending task -> the warm tick drained
#    nothing, silently. Retry keeps a failed task re-drivable.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "I. retry semantics (bounded re-queue -> dead -> re-open; requeue defers)"
I_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/i.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
T = "22222222222222222222222222222222"
# retry: pick -> retry -> back in queued (attempts=1), re-pickable.
e = Q.enqueue(T, "flaky task that fails dispatch")
p1 = Q.pick(T)
r1 = Q.retry(T, p1["id"], "dispatch refused: no_team_cred", max_attempts=3)
depth_after_retry = Q.depth(T)          # 1 (returned to the pick pool, not consumed)
p2 = Q.pick(T)                          # re-pickable
# drive to the cap (cap=3): the 3rd retry is terminal -> dead.
r2 = Q.retry(T, p2["id"], "again", max_attempts=3)   # attempts=2 -> queued
p3 = Q.pick(T)
r3 = Q.retry(T, p3["id"], "again", max_attempts=3)   # attempts=3 -> dead
depth_after_dead = Q.depth(T)           # 0 (no pending item — it gave up, bounded)
rows = Q.list(T)
dead_row = [row for row in rows if row.get("state") == "dead"]
# re-open: a fresh enqueue of the SAME text revives the dead task (attempts reset to 0).
e_reopen = Q.enqueue(T, "flaky task that fails dispatch")
depth_after_reopen = Q.depth(T)         # 1
p4 = Q.pick(T)
print(json.dumps({
    "retry_requeued": (r1.get("ok") is True and r1.get("state") == "queued" and r1.get("attempts") == 1),
    "depth_after_retry_1": depth_after_retry == 1,
    "repick_after_retry": bool(p2 and p2["id"] == e["id"]),
    "attempts_tracked": bool(p2 and p2.get("attempts") == 1),
    "dead_at_cap": (r3.get("ok") is True and r3.get("state") == "dead" and r3.get("attempts") == 3),
    "depth_zero_when_dead": depth_after_dead == 0,
    "dead_listed": (len(dead_row) == 1 and dead_row[0]["id"] == e["id"]),
    "enqueue_reopens_dead": (e_reopen.get("added") is True and e_reopen.get("reopened") is True),
    "depth_after_reopen_1": depth_after_reopen == 1,
    "reopened_attempts_reset": bool(p4 and p4.get("attempts") == 0),
}))
PYEOF
)"
if [ -s "$WORK/i.err" ]; then cat "$WORK/i.err" >&2; fi
ji(){ printf '%s' "$I_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(ji retry_requeued)" = "True" ] && [ "$(ji depth_after_retry_1)" = "True" ] \
  && [ "$(ji repick_after_retry)" = "True" ] && [ "$(ji attempts_tracked)" = "True" ] \
  && ok "I1 retry() returns a failed task to the pick pool (attempts=1), never permanently consumed" || bad "I1 retry did not re-queue (I_OUT=$I_OUT)"
[ "$(ji dead_at_cap)" = "True" ] && [ "$(ji depth_zero_when_dead)" = "True" ] && [ "$(ji dead_listed)" = "True" ] \
  && ok "I2 at the attempts cap the task moves to a terminal 'dead' state (bounded retry, no infinite loop)" || bad "I2 retry did not bound to dead (I_OUT=$I_OUT)"
[ "$(ji enqueue_reopens_dead)" = "True" ] && [ "$(ji depth_after_reopen_1)" = "True" ] && [ "$(ji reopened_attempts_reset)" = "True" ] \
  && ok "I3 a fresh enqueue of the same text RE-OPENS a dead task (attempts reset) — the re-submit unblock path" || bad "I3 enqueue did not re-open a dead task (I_OUT=$I_OUT)"

echo
echo "I(cont). requeue defers without burning an attempt; a DONE task is NOT re-opened"
J_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/j.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
T = "33333333333333333333333333333333"
e = Q.enqueue(T, "deferred task")
p1 = Q.pick(T)
Q.retry(T, p1["id"], "fail1")               # attempts=1, back to queued
p2 = Q.pick(T)
rq = Q.requeue(T, p2["id"])                  # defer, NO attempt burn
p3 = Q.pick(T)
# a genuinely-dispatched (done) task is NOT re-opened by a fresh enqueue (idempotency held).
Q.complete(T, p3["id"], "dispatched:cloud")
e2 = Q.enqueue(T, "deferred task")           # same text -> dedup no-op (done, not reopened)
print(json.dumps({
    "requeue_ok": (rq.get("ok") is True and rq.get("state") == "queued"),
    "requeue_no_attempt_burn": bool(p3 and p3.get("attempts") == 1),
    "done_not_reopened": (e2.get("added") is False and not e2.get("reopened")),
}))
PYEOF
)"
if [ -s "$WORK/j.err" ]; then cat "$WORK/j.err" >&2; fi
jj(){ printf '%s' "$J_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jj requeue_ok)" = "True" ] && [ "$(jj requeue_no_attempt_burn)" = "True" ] \
  && ok "I4 requeue() defers an in_flight task back to queued WITHOUT incrementing attempts" || bad "I4 requeue burned an attempt or failed (J_OUT=$J_OUT)"
[ "$(jj done_not_reopened)" = "True" ] \
  && ok "I5 a successfully-dispatched (done) task is NOT re-opened by a duplicate enqueue (idempotency preserved)" || bad "I5 a done task was wrongly re-opened (J_OUT=$J_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# K. CROSS-INSTANCE ATOMIC CLAIM (the double-dispatch fix, audit §3b). The queued->
#    in_flight claim is a compare-and-swap on the partition record's `rev` via the
#    StateBackend's put_record_if. Under max-instances>1 the local flock gives NO cross-
#    instance mutual exclusion, so two instances could pick() the SAME task. The CAS makes
#    the LOSER of a claim race see the winner's committed rev and re-read (claim the next /
#    nothing) instead of double-claiming.
#    FALSIFIER: without the rev check, a STALE-rev write would succeed and BOTH instances
#    would win the same task (double-dispatch / a lost task).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "K. cross-instance atomic claim (compare-and-swap on rev, LocalBackend)"
K_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/k.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
import cp_state

b = cp_state.get_backend()

# --- K1: the RAW backend CAS — put_record_if honors expected_rev. ---
rel1 = Q._queue_rel("cccccccccccccccccccccccccccccccc")
first   = b.put_record_if(rel1, {"rev": 1, "mark": "first"},   0)  # absent==0 -> commit
stale   = b.put_record_if(rel1, {"rev": 2, "mark": "stale"},   0)  # stored rev now 1 -> REFUSE
correct = b.put_record_if(rel1, {"rev": 2, "mark": "correct"}, 1)  # matches -> commit
after1  = b.get_record(rel1)

# --- K2: two "instances" both read the SAME rev and both try to claim the SAME task.
#         Exactly ONE CAS commits; the loser re-reads and claims the OTHER task. ---
T2 = "22220000222200002222000022220000"
Q.enqueue(T2, "race task one")
Q.enqueue(T2, "race task two")
rel2 = Q._queue_rel(T2)
sA = b.get_record(rel2); revA = cp_state._rev_of(sA)
sB = b.get_record(rel2); revB = cp_state._rev_of(sB)          # STALE read at the same rev
victim = sorted(sA["queued"].keys())[0]
# instance A claims `victim`.
itemA = sA["queued"].pop(victim); sA["in_flight"][victim] = {"since": "A", "item": itemA}
sA["rev"] = revA + 1
okA = b.put_record_if(rel2, sA, revA)                         # True (rev matched)
# instance B tries the SAME claim at the now-STALE revB -> MUST be refused (no double-claim).
itemB = sB["queued"].pop(victim); sB["in_flight"][victim] = {"since": "B", "item": itemB}
sB["rev"] = revB + 1
okB = b.put_record_if(rel2, sB, revB)                         # False (A advanced the rev)
# B, having lost, RE-READS and claims the OTHER task.
sB2 = b.get_record(rel2); revB2 = cp_state._rev_of(sB2)
other = sorted(sB2["queued"].keys())[0] if sB2["queued"] else None
recovered = False
if other is not None:
    itemO = sB2["queued"].pop(other); sB2["in_flight"][other] = {"since": "B", "item": itemO}
    sB2["rev"] = revB2 + 1
    recovered = b.put_record_if(rel2, sB2, revB2)
final2 = b.get_record(rel2)
inflight2 = sorted(final2["in_flight"].keys())

# --- K3: Q.pick RECOVERS from an injected conflict — the loser re-reads and claims the
#         next task (the whole point: no double-claim, no lost task). A one-shot wrapper
#         forces the first put_record_if to lose to a competing instance. ---
T3 = "33330000333300003333000033330000"
Q.enqueue(T3, "pick task alpha")
Q.enqueue(T3, "pick task beta")

class ConflictOnce:
    """Wraps a real backend; the FIRST put_record_if loses a race: before returning False it
    commits a COMPETING claim (as if another instance won), so the caller's _cas MUST re-read
    and claim a different task."""
    def __init__(self, inner):
        self._inner = inner
        self._fired = False
    def __getattr__(self, name):
        return getattr(self._inner, name)
    def put_record_if(self, rel, record, expected_rev):
        if not self._fired:
            self._fired = True
            cur = self._inner.get_record(rel); rev = cp_state._rev_of(cur)
            keys = sorted(cur.get("queued", {}).keys())
            if keys:
                v = keys[0]; it = cur["queued"].pop(v)
                cur["in_flight"][v] = {"since": "competitor", "item": it}; cur["rev"] = rev + 1
                self._inner.put_record(rel, cur)   # competing commit advances the rev
            return False                            # our write loses the race
        return self._inner.put_record_if(rel, record, expected_rev)

wrapped = ConflictOnce(cp_state.get_backend())
orig = Q._backend
Q._backend = lambda home=None: wrapped
try:
    picked3 = Q.pick(T3)          # first CAS conflicts -> _cas re-reads -> claims the OTHER task
finally:
    Q._backend = orig
final3 = cp_state.get_backend().get_record(Q._queue_rel(T3))
inflight3 = sorted(final3["in_flight"].keys())

print(json.dumps({
    "k1_first_commit": first is True,
    "k1_stale_refused": stale is False,
    "k1_correct_commit": correct is True,
    "k1_correct_won": (after1 or {}).get("mark") == "correct",
    "k2_A_won": okA is True,
    "k2_B_refused_stale": okB is False,
    "k2_B_recovered": recovered is True,
    "k2_two_distinct_claims": (len(inflight2) == 2 and not final2["queued"]),
    "k3_pick_recovered": picked3 is not None,
    "k3_two_distinct_claims": (len(inflight3) == 2 and not final3["queued"]),
}))
PYEOF
)"
if [ -s "$WORK/k.err" ]; then cat "$WORK/k.err" >&2; fi
jk(){ printf '%s' "$K_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jk k1_first_commit)" = "True" ] && [ "$(jk k1_stale_refused)" = "True" ] \
  && [ "$(jk k1_correct_commit)" = "True" ] && [ "$(jk k1_correct_won)" = "True" ] \
  && ok "K1 put_record_if is a real CAS — a STALE-rev write is REFUSED, the matching-rev write commits (the falsifier: without the rev check the stale write would win)" || bad "K1 CAS did not enforce rev (K_OUT=$K_OUT)"
[ "$(jk k2_A_won)" = "True" ] && [ "$(jk k2_B_refused_stale)" = "True" ] \
  && [ "$(jk k2_B_recovered)" = "True" ] && [ "$(jk k2_two_distinct_claims)" = "True" ] \
  && ok "K2 two instances claiming the SAME task at the SAME rev -> exactly ONE wins; the loser re-reads and claims the next (2 distinct claims, no double-claim)" || bad "K2 double-claim NOT prevented (K_OUT=$K_OUT)"
[ "$(jk k3_pick_recovered)" = "True" ] && [ "$(jk k3_two_distinct_claims)" = "True" ] \
  && ok "K3 Q.pick RECOVERS from a claim-race conflict — it re-reads and claims the next task (loser never returns the same item; 2 distinct claims)" || bad "K3 pick did not recover from a conflict (K_OUT=$K_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# L. THE rev SURVIVES THE FIRESTORE ENCODE PATH — the CAS must work on the REAL deployed
#    backend, not just local. A faithful in-process fake google.cloud.firestore (the same
#    shape cp-flow-firestore uses, with transaction()/transactional support) backs the
#    FirestoreBackend; the CAS uses a Firestore TRANSACTION there. Proves: (1) put_record_if
#    honors rev on the firestore encode path, (2) the full enqueue->pick->retry->complete
#    round-trip works under firestore (rev round-trips through _FIELD_REC).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "L. rev survives the firestore-fake backend (CAS on the real encode path)"
FAKEPKG="$WORK/fakepy"
mkdir -p "$FAKEPKG"
cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore the FirestoreBackend uses
# (incl. transaction()/transactional for the CAS). Persists to HEIMDALL_FAKE_FS_STORE.
import json
import os

_STORE_ENV = "HEIMDALL_FAKE_FS_STORE"


def _store_path():
    p = os.environ.get(_STORE_ENV)
    if not p:
        raise RuntimeError("fake firestore needs %s set" % _STORE_ENV)
    return p


def _load():
    try:
        with open(_store_path(), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _save(data):
    tmp = _store_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, _store_path())


class Client:
    def __init__(self, project=None, database=None):
        self.project = project

    def collection(self, name):
        return CollectionRef(name)

    def transaction(self):
        return _Transaction()


class CollectionRef:
    def __init__(self, path):
        self._path = path

    def document(self, doc_id):
        return DocRef(self._path, doc_id)

    def order_by(self, field):
        return _Query(self._path, order_field=field)

    def stream(self):
        return _Query(self._path).stream()


class _Query:
    def __init__(self, coll_path, order_field=None):
        self._coll_path = coll_path
        self._order_field = order_field

    def order_by(self, field):
        return _Query(self._coll_path, order_field=field)

    def stream(self):
        data = _load()
        coll = data.get("collections", {}).get(self._coll_path, {})
        items = [_Snapshot(self._coll_path, k, v.get("fields")) for k, v in coll.items()]
        if self._order_field:
            items.sort(key=lambda s: (s.to_dict() or {}).get(self._order_field))
        else:
            items.sort(key=lambda s: s.id)
        return iter(items)


class DocRef:
    def __init__(self, coll_path, doc_id):
        self._coll_path = coll_path
        self._doc_id = doc_id

    @property
    def id(self):
        return self._doc_id

    def collection(self, name):
        return CollectionRef("%s/%s/%s" % (self._coll_path, self._doc_id, name))

    def get(self, transaction=None):
        data = _load()
        doc = data.get("collections", {}).get(self._coll_path, {}).get(self._doc_id)
        return _Snapshot(self._coll_path, self._doc_id, doc.get("fields") if doc else None)

    def set(self, fields, merge=False):
        data = _load()
        coll = data.setdefault("collections", {}).setdefault(self._coll_path, {})
        doc = coll.setdefault(self._doc_id, {"fields": {}})
        if merge:
            cur = dict(doc.get("fields") or {}); cur.update(fields); doc["fields"] = cur
        else:
            doc["fields"] = dict(fields)
        _save(data)


class _Snapshot:
    def __init__(self, coll_path, doc_id, fields):
        self._coll_path = coll_path
        self._doc_id = doc_id
        self._fields = fields

    @property
    def id(self):
        return self._doc_id

    @property
    def exists(self):
        return self._fields is not None

    def to_dict(self):
        return dict(self._fields) if self._fields is not None else None


class _Transaction:
    def set(self, ref, fields, merge=False):
        ref.set(fields, merge=merge)

    def get(self, ref):
        return ref.get()


def transactional(func):
    def _wrapped(transaction, *args, **kwargs):
        return func(transaction, *args, **kwargs)
    return _wrapped
PYEOF
cat >"$FAKEPKG/sitecustomize.py" <<'PYEOF'
import importlib
import sys
import _fake_firestore_impl as _impl
for _name in ("google", "google.cloud"):
    if _name not in sys.modules:
        try:
            importlib.import_module(_name)
        except Exception:  # noqa: BLE001
            import types
            _pkg = types.ModuleType(_name); _pkg.__path__ = []; sys.modules[_name] = _pkg
sys.modules["google.cloud.firestore"] = _impl
setattr(sys.modules["google.cloud"], "firestore", _impl)
PYEOF
: >"$WORK/fake_fs.json"
L_OUT="$(HEIMDALL_STATE_BACKEND="firestore" \
         HEIMDALL_FIRESTORE_ROOT="teamq_cas_gate" \
         HEIMDALL_FIRESTORE_PROJECT="cp-team-queue-cas-test" \
         HEIMDALL_FAKE_FS_STORE="$WORK/fake_fs.json" \
         PYTHONPATH="$FAKEPKG${PYTHONPATH:+:$PYTHONPATH}" \
         "$PY" - <<'PYEOF' 2>"$WORK/l.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
import cp_state

b = cp_state.get_backend()
assert type(b).__name__ == "FirestoreBackend", "expected FirestoreBackend, got %r" % type(b)

# --- L1: put_record_if honors rev on the FIRESTORE encode path (a Firestore transaction). ---
rel = Q._queue_rel("ffff1111ffff1111ffff1111ffff1111")
c_first   = b.put_record_if(rel, {"rev": 1, "mark": "first"},   0)  # absent==0 -> commit
c_stale   = b.put_record_if(rel, {"rev": 2, "mark": "stale"},   0)  # rev now 1 -> REFUSE
c_correct = b.put_record_if(rel, {"rev": 2, "mark": "correct"}, 1)  # matches -> commit
enc_after = b.get_record(rel)

# --- L2: the full CAS-driven round-trip works under firestore (rev round-trips). ---
T = "ffff2222ffff2222ffff2222ffff2222"
e  = Q.enqueue(T, "firestore round-trip task")
p1 = Q.pick(T)
r1 = Q.retry(T, p1["id"], "transient", max_attempts=3)   # attempts=1 -> back to queued
p2 = Q.pick(T)
comp = Q.complete(T, p2["id"], "dispatched:cloud")
after = Q.pick(T)                                        # nothing left
stored = b.get_record(Q._queue_rel(T))

print(json.dumps({
    "is_firestore": True,
    "l1_first_commit": c_first is True,
    "l1_stale_refused": c_stale is False,
    "l1_correct_commit": c_correct is True,
    "l1_correct_won": (enc_after or {}).get("mark") == "correct",
    "l2_enq": bool(e.get("ok") and e.get("added")),
    "l2_retry_requeued": (r1.get("ok") is True and r1.get("state") == "queued"),
    "l2_repicked": bool(p2 and p2["id"] == e["id"]),
    "l2_complete": (comp.get("ok") is True),
    "l2_drained": after is None,
    "l2_rev_advanced": cp_state._rev_of(stored) >= 1,
}))
PYEOF
)"
if [ -s "$WORK/l.err" ]; then cat "$WORK/l.err" >&2; fi
jl(){ printf '%s' "$L_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jl l1_first_commit)" = "True" ] && [ "$(jl l1_stale_refused)" = "True" ] \
  && [ "$(jl l1_correct_commit)" = "True" ] && [ "$(jl l1_correct_won)" = "True" ] \
  && ok "L1 put_record_if enforces rev on the FIRESTORE encode path (a Firestore transaction) — a stale-rev write is REFUSED" || bad "L1 firestore CAS did not enforce rev (L_OUT=$L_OUT)"
[ "$(jl l2_enq)" = "True" ] && [ "$(jl l2_retry_requeued)" = "True" ] && [ "$(jl l2_repicked)" = "True" ] \
  && [ "$(jl l2_complete)" = "True" ] && [ "$(jl l2_drained)" = "True" ] && [ "$(jl l2_rev_advanced)" = "True" ] \
  && ok "L2 the full enqueue->pick->retry->complete round-trip works under firestore; rev round-trips through the record (survives local+firestore backends)" || bad "L2 firestore round-trip / rev survival failed (L_OUT=$L_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# M. THE LEGACY (pre-CAS, REV-LESS) RECORD IS CLAIMABLE + a CAS EXHAUSTION IS LOUD (bug #19).
#    LIVE INCIDENT: the drain picked NOTHING from a partition whose Firestore doc VERIFIABLY
#    held a queued task, every cycle, with NO log — because the doc was written by the OLD
#    (pre-CAS) code and has NO `rev` field (rev=None when read). M1: a REAL pre-CAS record
#    shape (rec.{queued,in_flight,done,dead,team_id} with NO rev) MUST be claimed (missing-rev
#    folds to rev 0, the CAS commits, rev is STAMPED going forward). M2/M3: a PERMANENT CAS
#    conflict must return None CLEANLY *and* emit a LOUD stderr line — silent pick failure is
#    exactly how bug #19 hid.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "M. LEGACY (pre-CAS, rev-less) record parity + LOUD CAS-exhaustion (bug #19, LocalBackend)"
M_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/m.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
import cp_state

b = cp_state.get_backend()

# --- M1: a REAL pre-CAS record (the live doc shape, NO rev field) is CLAIMED by pick. A reader
#         that folded missing-rev != 0 would compute expected_rev != the stored rev the CAS
#         reads -> the compare-and-swap could NEVER commit -> pick silently claims NOTHING. ---
TEAM = "6ca551f293a788a72825fc2de95859cc"
rel = Q._queue_rel(TEAM)
TID = "task:9feee8260915c39b115427b8d3df3858"
legacy = {
    "schema_version": "1.0.0",
    "team_id": TEAM,
    # NOTE: NO "rev" key — the byte-for-byte shape a pre-CAS writer left in the store.
    "queued": {TID: {"id": TID, "team_id": TEAM, "text": "legacy queued task",
                     "priority_signal": {"severity": None, "age_seconds": 0,
                                         "source_priority": 0},
                     "created_at": "2026-06-01T00:00:00+00:00", "attempts": 0}},
    "in_flight": {}, "done": {}, "dead": {},
}
assert "rev" not in legacy, "fixture must have NO rev field (the pre-CAS shape)"
b.put_record(rel, legacy)                          # write the rev-less record directly
rev_read = (b.get_record(rel) or {}).get("rev")    # rev=None when read (the absent key)
claimed = Q.pick(TEAM)                              # MUST claim the legacy task
after = b.get_record(rel)

# --- M2/M3: a PERMANENT CAS conflict (put_record_if ALWAYS refuses) MUST NOT be silent. pick()
#            returns None cleanly AND emits a LOUD stderr line so an exhausted claim loop is
#            never invisible again (the exact silence bug #19 hid behind). ---
CT = "abcdef00abcdef00abcdef00abcdef00"
Q.enqueue(CT, "task that can never be claimed")

class AlwaysConflict:
    """Wraps a real backend; put_record_if ALWAYS returns False (a permanent, terminal CAS
    conflict) so _cas exhausts every attempt — the forced falsifier for the loud line."""
    def __init__(self, inner): self._inner = inner
    def __getattr__(self, name): return getattr(self._inner, name)
    def put_record_if(self, rel, record, expected_rev): return False

wrapped = AlwaysConflict(cp_state.get_backend())
orig = Q._backend
Q._backend = lambda home=None: wrapped
try:
    picked_conflict = Q.pick(CT)                    # exhausts the CAS -> None, but LOUD
finally:
    Q._backend = orig

print(json.dumps({
    "m1_rev_read_none": rev_read is None,
    "m1_claimed": bool(claimed and claimed["id"] == TID),
    "m1_moved_to_inflight": (TID in (after or {}).get("in_flight", {})
                             and TID not in (after or {}).get("queued", {})),
    "m1_rev_stamped": cp_state._rev_of(after) >= 1,
    "m2_pick_none": picked_conflict is None,
}))
PYEOF
)"
if [ -s "$WORK/m.err" ]; then cat "$WORK/m.err" >&2; fi
jm(){ printf '%s' "$M_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jm m1_rev_read_none)" = "True" ] && [ "$(jm m1_claimed)" = "True" ] \
  && [ "$(jm m1_moved_to_inflight)" = "True" ] && [ "$(jm m1_rev_stamped)" = "True" ] \
  && ok "M1 a REAL pre-CAS rev-less record is CLAIMED by pick (missing-rev == rev 0; the CAS commits and STAMPS rev going forward)" || bad "M1 legacy record not claimed (M_OUT=$M_OUT)"
[ "$(jm m2_pick_none)" = "True" ] \
  && ok "M2 a permanent CAS conflict makes pick return None CLEANLY (the loser claims nothing)" || bad "M2 pick did not return None on permanent conflict (M_OUT=$M_OUT)"
grep -qE "pick CAS conflict/exhausted team=[0-9a-f]{8} attempts=[0-9]+" "$WORK/m.err" \
  && ok "M3 a permanent CAS exhaustion is LOUD — pick emits 'cp_team_queue: pick CAS conflict/exhausted team=<id8> attempts=N' (silent pick failure is exactly how bug #19 hid)" || bad "M3 no loud CAS-exhaustion line (m.err=$(cat "$WORK/m.err"))"

# ──────────────────────────────────────────────────────────────────────────────
# N. THE LEGACY REV-LESS RECORD IS CLAIMED UNDER THE FIRESTORE TRANSACTIONAL CAS (bug #19,
#    the DEPLOYED shape). The live break was firestore-only: the record read back with rev=None
#    from _FIELD_REC and the transactional put_record_if must still treat it as rev 0 and commit
#    the claim (parity with LocalBackend). Reuses the section-L in-process fake (transaction()/
#    transactional), so the Firestore TRANSACTION path is exercised end-to-end.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "N. LEGACY rev-less record CLAIMED under the FIRESTORE-fake transactional CAS (bug #19, deployed shape)"
: >"$WORK/fake_fs_n.json"
N_OUT="$(HEIMDALL_STATE_BACKEND="firestore" \
         HEIMDALL_FIRESTORE_ROOT="teamq_legacy_gate" \
         HEIMDALL_FIRESTORE_PROJECT="cp-team-queue-legacy-test" \
         HEIMDALL_FAKE_FS_STORE="$WORK/fake_fs_n.json" \
         PYTHONPATH="$FAKEPKG${PYTHONPATH:+:$PYTHONPATH}" \
         "$PY" - <<'PYEOF' 2>"$WORK/n.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_queue as Q
import cp_state

b = cp_state.get_backend()
assert type(b).__name__ == "FirestoreBackend", "expected FirestoreBackend, got %r" % type(b)

# The live doc that drained NOTHING: a pre-CAS rev-less record with a queued task, written
# straight through the FirestoreBackend put_record (so it lives under _FIELD_REC with NO rev).
TEAM = "6ca551f293a788a72825fc2de95859cc"
rel = Q._queue_rel(TEAM)
TID = "task:9feee8260915c39b115427b8d3df3858"
legacy = {
    "schema_version": "1.0.0", "team_id": TEAM,
    "queued": {TID: {"id": TID, "team_id": TEAM, "text": "legacy queued task",
                     "priority_signal": {"severity": None, "age_seconds": 0,
                                         "source_priority": 0},
                     "created_at": "2026-06-01T00:00:00+00:00", "attempts": 0}},
    "in_flight": {}, "done": {}, "dead": {},
}
b.put_record(rel, legacy)                          # rev-less, on the firestore encode path
rev_read = (b.get_record(rel) or {}).get("rev")    # None (absent key), read through _FIELD_REC
claimed = Q.pick(TEAM)                              # MUST claim via the Firestore TRANSACTION CAS
after = b.get_record(rel)

print(json.dumps({
    "is_firestore": True,
    "n_rev_read_none": rev_read is None,
    "n_claimed": bool(claimed and claimed["id"] == TID),
    "n_moved_to_inflight": (TID in (after or {}).get("in_flight", {})
                            and TID not in (after or {}).get("queued", {})),
    "n_rev_stamped": cp_state._rev_of(after) >= 1,
}))
PYEOF
)"
if [ -s "$WORK/n.err" ]; then cat "$WORK/n.err" >&2; fi
jn(){ printf '%s' "$N_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jn n_rev_read_none)" = "True" ] && [ "$(jn n_claimed)" = "True" ] \
  && [ "$(jn n_moved_to_inflight)" = "True" ] && [ "$(jn n_rev_stamped)" = "True" ] \
  && ok "N a REAL pre-CAS rev-less record is CLAIMED under the FIRESTORE transactional CAS (missing-rev==0 on the deployed encode path; rev STAMPED going forward) — the exact live silent-drain shape" || bad "N legacy record not claimed under firestore (N_OUT=$N_OUT)"

echo
echo "============================================================"
printf "cp-team-queue: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

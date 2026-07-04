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
secret = "deploy with token=AbCdEf0123456789AbCdEf01 and key ghp_" + ("a" * 36)
es = Q.enqueue(T, secret)
ps = Q.pick(T)
stored = ps["text"] if ps else ""
print(json.dumps({
    "trimmed": len(pb["text"]) <= Q._TASK_MAX_CHARS and len(pb["text"]) < 10000,
    "no_ghp": "ghp_" not in stored,
    "no_assigned": "token=AbCdEf0123456789AbCdEf01" not in stored,
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

echo
echo "============================================================"
printf "cp-team-queue: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

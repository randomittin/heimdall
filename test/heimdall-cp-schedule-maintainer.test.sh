#!/usr/bin/env bash
# heimdall-cp-schedule-maintainer.test.sh — the CARDINAL tests for the `schedule-maintainer`
# control-plane write verb: the ONE command that makes the CLOUD maintainer autonomous by
# registering the cron the per-minute tick fires.
#
# DESIGN DOSSIER §6 (authoritative). The verb registers an ALLOWLISTED run-maintainer-cycle
# schedule (NEVER a free-form command) through the SAME §1 create-time gate every schedule
# uses, IDEMPOTENTLY (same owner+repo+cron -> update in place, never a duplicate). It drives
# the REAL CLI (bin/heimdall-control-plane) + the REAL substrate (cp_scheduler / cp_allowlist
# / cp_auth) + the REAL tick — no fakes of the thing under test, except a recorder standing in
# for the maintainer RUNNER at fire-time (so the tick's dispatch SHAPE is asserted without
# spawning a real job):
#
#   V. THE VERB REGISTERS A SCHEDULE THE STORE SHOWS (§6, the core):
#      V1. schedule-maintainer --repo x/y --cron "*/30 * * * *" -> exit 0, prints a
#          schedule_id; `schedules` shows exactly ONE run-maintainer-cycle entry for x/y.
#      V2. list_schedules AND due_schedules (via the real cp_scheduler) both SEE it: due at a
#          matching minute, absent at a non-matching minute (the cron WHEN gate works).
#
#   I. IDEMPOTENT — SAME repo+cron NEVER DUPLICATES (§6):
#      I1. re-register the SAME repo+cron with a DIFFERENT --max -> still exactly ONE entry,
#          the SAME schedule_id, and the max UPDATED IN PLACE (never a second schedule).
#
#   T. A DUE TICK DISPATCHES run-maintainer-cycle (§6 fire-time, runner recorder):
#      T1. at the due minute the tick fires EXACTLY ONE dispatch whose action_type is
#          run-maintainer-cycle and whose params.repo is the registered repo (the dispatch
#          SHAPE — a recorder standing in for the runner captures it, asserting the tick
#          reaches the maintainer runner arm).
#      T2. at a non-due minute the tick fires NOTHING.
#
#   B. BAD INPUT IS REFUSED, NOTHING PERSISTED (§1 security spine, falsifiable):
#      B1. a bad --repo (no slash / shell metachar) -> nonzero exit, NOT persisted.
#      B2. a bad --cron -> nonzero exit, NOT persisted.
#      B3. an out-of-range --max (0 / 9999) -> nonzero exit, NOT persisted.
#      B4. FALSIFIABILITY: V1 (a valid register) succeeds WHILE B1-B3 are refused ->
#          refuse-arbitrary, distinct from refuse-everything.
#
#   D. --dry-run REGISTERS NOTHING (§6):
#      D1. schedule-maintainer --dry-run -> exit 0, prints the plan, the store is UNCHANGED.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which). Hermetic: a private
# HEIMDALL_HOME per phase, a pinned server identity, a simulated clock — no network, no spend.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO_ROOT/bin/heimdall-control-plane"
LIB="$REPO_ROOT/bin/lib"

[ -x "$CLI" ] || { echo "FATAL: $CLI missing/not executable" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# a private working home per run (the mktemp template avoids a literal triple-X in source).
WORK="$(mktemp -d -t "cp-sched-maint.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# The server identity the tick fires as — pinned so the hermetic run needs no ledger checkout
# (cp_auth.server_haid honors HEIMDALL_CP_SERVER_HAID first).
export HEIMDALL_CP_SERVER_HAID="haid:test.cp-server"

REPO_SLUG="randomittin/heimdall"
CRON='*/30 * * * *'

# count the live schedules in a given home (via the read-only `schedules --json` verb).
count_schedules() {
  HEIMDALL_HOME="$1" "$CLI" schedules --json 2>/dev/null \
    | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))'
}
# a JSON field of the SINGLE live schedule in a home (fails if not exactly one).
one_field() {
  HEIMDALL_HOME="$1" "$CLI" schedules --json 2>/dev/null \
    | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert len(d)==1, len(d); print(d[0]'"$2"')'
}

echo "== V. the verb registers a schedule the store shows =="
HOME_V="$WORK/home-v"
REG_OUT="$WORK/reg.json"
HEIMDALL_HOME="$HOME_V" "$CLI" schedule-maintainer --repo "$REPO_SLUG" --cron "$CRON" \
  --max 3 --json >"$REG_OUT" 2>"$WORK/reg.err"
RC=$?
SID="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("schedule_id",""))' "$REG_OUT" 2>/dev/null)"
{ [ "$RC" = 0 ] && [ -n "$SID" ]; } \
  && ok "V1 register exit 0 + printed schedule_id=$SID" \
  || bad "V1 register failed (rc=$RC, sid='$SID'): $(cat "$WORK/reg.err")"
[ "$(count_schedules "$HOME_V")" = 1 ] \
  && ok "V1 store shows exactly ONE schedule" \
  || bad "V1 store shows $(count_schedules "$HOME_V") schedules (expected 1)"
[ "$(one_field "$HOME_V" '["action_type"]')" = "run-maintainer-cycle" ] \
  && ok "V1 the schedule is an ALLOWLISTED run-maintainer-cycle" \
  || bad "V1 action_type is $(one_field "$HOME_V" '["action_type"]') (expected run-maintainer-cycle)"
[ "$(one_field "$HOME_V" '["params"]["repo"]')" = "$REPO_SLUG" ] \
  && ok "V1 params.repo == $REPO_SLUG (typed+bounded, no free string)" \
  || bad "V1 params.repo mismatch: $(one_field "$HOME_V" '["params"]["repo"]')"

# V2 — list_schedules AND due_schedules SEE it (the real scheduler, a simulated clock).
V2_OUT="$WORK/v2.out"
HEIMDALL_HOME="$HOME_V" LIB="$LIB" REPO_SLUG="$REPO_SLUG" "$PY" - >"$V2_OUT" 2>"$WORK/v2.err" <<'PYEOF'
import datetime, json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_scheduler as Sc
home = os.environ["HEIMDALL_HOME"]
# the registered cron is "*/30 * * * *" -> minute 0 or 30, any hour/day/month/dow.
DUE = datetime.datetime(2026, 6, 15, 2, 30, tzinfo=datetime.timezone.utc)      # minute 30 -> due
NOT_DUE = datetime.datetime(2026, 6, 15, 2, 15, tzinfo=datetime.timezone.utc)  # minute 15 -> not due
listed = Sc.list_schedules(home)
due = Sc.due_schedules(DUE, home=home)
not_due = Sc.due_schedules(NOT_DUE, home=home)
print(json.dumps({
    "listed_count": len(listed),
    "listed_is_maint": bool(listed) and listed[0]["action_type"] == "run-maintainer-cycle",
    "due_count": len(due),
    "due_repo": (due[0]["params"]["repo"] if due else None),
    "not_due_count": len(not_due),
}))
PYEOF
jv2() { "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$V2_OUT" "$1" 2>/dev/null; }
{ [ "$(jv2 listed_count)" = 1 ] && [ "$(jv2 listed_is_maint)" = "True" ]; } \
  && ok "V2 list_schedules sees the run-maintainer-cycle schedule" \
  || bad "V2 list_schedules wrong (count=$(jv2 listed_count), maint=$(jv2 listed_is_maint)): $(cat "$WORK/v2.err")"
{ [ "$(jv2 due_count)" = 1 ] && [ "$(jv2 due_repo)" = "$REPO_SLUG" ]; } \
  && ok "V2 due_schedules fires at the matching minute (repo=$(jv2 due_repo))" \
  || bad "V2 due_schedules wrong at due minute (count=$(jv2 due_count), repo=$(jv2 due_repo))"
[ "$(jv2 not_due_count)" = 0 ] \
  && ok "V2 due_schedules is EMPTY at a non-matching minute (cron WHEN gate)" \
  || bad "V2 due_schedules fired $(jv2 not_due_count) at a non-due minute (expected 0)"

echo "== I. idempotent — same repo+cron never duplicates =="
HEIMDALL_HOME="$HOME_V" "$CLI" schedule-maintainer --repo "$REPO_SLUG" --cron "$CRON" \
  --max 9 --json >"$WORK/reg2.json" 2>"$WORK/reg2.err"
RC2=$?
SID2="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("schedule_id",""))' "$WORK/reg2.json" 2>/dev/null)"
CREATED2="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("created"))' "$WORK/reg2.json" 2>/dev/null)"
[ "$RC2" = 0 ] || bad "I1 re-register failed (rc=$RC2): $(cat "$WORK/reg2.err")"
[ "$(count_schedules "$HOME_V")" = 1 ] \
  && ok "I1 re-register kept EXACTLY ONE schedule (no duplicate)" \
  || bad "I1 re-register produced $(count_schedules "$HOME_V") schedules (expected 1 — DUPLICATED)"
{ [ -n "$SID2" ] && [ "$SID2" = "$SID" ]; } \
  && ok "I1 same schedule_id reused ($SID2) — updated in place" \
  || bad "I1 schedule_id changed ($SID -> $SID2) — not an in-place update"
[ "$CREATED2" = "False" ] \
  && ok "I1 the verb reports created=False (an update, not a create)" \
  || bad "I1 created flag wrong on re-register: $CREATED2"
[ "$(one_field "$HOME_V" '["params"]["max"]')" = 9 ] \
  && ok "I1 max UPDATED IN PLACE 3 -> 9" \
  || bad "I1 max not updated: $(one_field "$HOME_V" '["params"]["max"]') (expected 9)"

echo "== T. a due tick dispatches run-maintainer-cycle (runner recorder) =="
HOME_T="$WORK/home-t"
HEIMDALL_HOME="$HOME_T" "$CLI" schedule-maintainer --repo "$REPO_SLUG" --cron "$CRON" --max 2 \
  >/dev/null 2>"$WORK/t-reg.err" || bad "T setup register failed: $(cat "$WORK/t-reg.err")"
T_OUT="$WORK/t.out"
HEIMDALL_HOME="$HOME_T" LIB="$LIB" REPO_SLUG="$REPO_SLUG" \
HEIMDALL_CP_SERVER_HAID="$HEIMDALL_CP_SERVER_HAID" "$PY" - >"$T_OUT" 2>"$WORK/t.err" <<'PYEOF'
import datetime, json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_scheduler as Sc
import cp_maintainer_runner as R
import cp_auth as K
home = os.environ["HEIMDALL_HOME"]

# REPLACE the maintainer runner arm with a RECORDER: tick() dispatches run-maintainer-cycle
# THROUGH cp_maintainer_runner.dispatch_maintainer_cycle (the hybrid selector). We swap in a
# recorder so the tick's dispatch SHAPE is asserted without spawning a real job / touching a
# credential — it captures the params it is handed and returns a benign done-ish outcome.
calls = []
def _rec(identity, params, *, home=None, base_env=None, now=None):
    calls.append({"params": dict(params)})
    return {"dispatched": True, "job_id": "job-rec", "arm": "cloud",
            "http_status": 200, "audit_id": "aud-rec", "runner": "recorder"}
R.dispatch_maintainer_cycle = _rec

server = K.Identity(os.environ["HEIMDALL_CP_SERVER_HAID"], owner=True)
DUE = datetime.datetime(2026, 6, 15, 2, 30, tzinfo=datetime.timezone.utc)      # minute 30 -> due
NOT_DUE = datetime.datetime(2026, 6, 15, 2, 15, tzinfo=datetime.timezone.utc)  # minute 15 -> not due

fired_not_due = Sc.tick(server, NOT_DUE, home=home)
fired_due = Sc.tick(server, DUE, home=home)
print(json.dumps({
    "not_due_fired": len(fired_not_due),
    "due_fired": len(fired_due),
    "due_action_type": (fired_due[0]["action_type"] if fired_due else None),
    "dispatch_calls": len(calls),
    "dispatch_repo": (calls[0]["params"].get("repo") if calls else None),
    "dispatch_action_is_maint": all(
        f["action_type"] == "run-maintainer-cycle" for f in fired_due) and bool(fired_due),
}))
PYEOF
jt() { "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$T_OUT" "$1" 2>/dev/null; }
{ [ "$(jt due_fired)" = 1 ] && [ "$(jt dispatch_calls)" = 1 ]; } \
  && ok "T1 due tick fired EXACTLY ONE maintainer dispatch (reached the runner arm)" \
  || bad "T1 due tick fired $(jt due_fired)/dispatch=$(jt dispatch_calls) (expected 1/1): $(cat "$WORK/t.err")"
{ [ "$(jt due_action_type)" = "run-maintainer-cycle" ] && [ "$(jt dispatch_action_is_maint)" = "True" ]; } \
  && ok "T1 the dispatched action_type is run-maintainer-cycle" \
  || bad "T1 dispatched action_type wrong: $(jt due_action_type)"
[ "$(jt dispatch_repo)" = "$REPO_SLUG" ] \
  && ok "T1 the dispatch params.repo == $REPO_SLUG (the registered repo, typed)" \
  || bad "T1 dispatch repo mismatch: $(jt dispatch_repo)"
[ "$(jt not_due_fired)" = 0 ] \
  && ok "T2 a non-due minute fired NOTHING" \
  || bad "T2 non-due tick fired $(jt not_due_fired) (expected 0)"

echo "== B. bad input is refused, nothing persisted (falsifiable) =="
HOME_B="$WORK/home-b"
# B1 — bad repo (no slash) and (shell metachar) both refused.
HEIMDALL_HOME="$HOME_B" "$CLI" schedule-maintainer --repo "notarepo" --cron "$CRON" >/dev/null 2>&1
RC_B1a=$?
HEIMDALL_HOME="$HOME_B" "$CLI" schedule-maintainer --repo 'a/b;rm -rf /' --cron "$CRON" >/dev/null 2>&1
RC_B1b=$?
{ [ "$RC_B1a" != 0 ] && [ "$RC_B1b" != 0 ]; } \
  && ok "B1 bad --repo (no slash / shell metachar) refused (rc=$RC_B1a,$RC_B1b)" \
  || bad "B1 bad --repo NOT refused (rc=$RC_B1a,$RC_B1b)"
# B2 — bad cron refused.
HEIMDALL_HOME="$HOME_B" "$CLI" schedule-maintainer --repo "$REPO_SLUG" --cron "not a cron" >/dev/null 2>&1
[ "$?" != 0 ] && ok "B2 bad --cron refused" || bad "B2 bad --cron NOT refused"
# B3 — out-of-range max refused (0 and 9999).
HEIMDALL_HOME="$HOME_B" "$CLI" schedule-maintainer --repo "$REPO_SLUG" --cron "$CRON" --max 0 >/dev/null 2>&1
RC_B3a=$?
HEIMDALL_HOME="$HOME_B" "$CLI" schedule-maintainer --repo "$REPO_SLUG" --cron "$CRON" --max 9999 >/dev/null 2>&1
RC_B3b=$?
{ [ "$RC_B3a" != 0 ] && [ "$RC_B3b" != 0 ]; } \
  && ok "B3 out-of-range --max (0 and 9999) refused (rc=$RC_B3a,$RC_B3b)" \
  || bad "B3 out-of-range --max NOT refused (rc=$RC_B3a,$RC_B3b)"
# nothing from B1-B3 was persisted.
B_COUNT="$(count_schedules "$HOME_B" 2>/dev/null || echo 0)"; B_COUNT="${B_COUNT:-0}"
[ "$B_COUNT" = 0 ] \
  && ok "B4 FALSIFIABLE: every refused register persisted NOTHING (store empty) while V1 succeeded" \
  || bad "B4 a refused register leaked into the store ($B_COUNT entries)"

echo "== D. --dry-run registers nothing =="
HOME_D="$WORK/home-d"
D_OUT="$WORK/d.out"
HEIMDALL_HOME="$HOME_D" "$CLI" schedule-maintainer --repo "$REPO_SLUG" --cron "$CRON" \
  --max 5 --dry-run >"$D_OUT" 2>"$WORK/d.err"
RC_D=$?
D_COUNT="$(count_schedules "$HOME_D" 2>/dev/null || echo 0)"; D_COUNT="${D_COUNT:-0}"
{ [ "$RC_D" = 0 ] && grep -qi "DRY-RUN" "$D_OUT"; } \
  && ok "D1 --dry-run exit 0 + printed the plan" \
  || bad "D1 --dry-run failed (rc=$RC_D): $(cat "$WORK/d.err")"
[ "$D_COUNT" = 0 ] \
  && ok "D1 --dry-run wrote NOTHING to the store (0 schedules)" \
  || bad "D1 --dry-run persisted $D_COUNT schedules (expected 0)"

echo
if [ "$FAIL" -eq 0 ]; then
  printf "cp-schedule-maintainer: \033[32m%d passed, 0 failed\033[0m\n" "$PASS"
  exit 0
else
  printf "cp-schedule-maintainer: \033[31m%d passed, %d failed\033[0m\n" "$PASS" "$FAIL"
  exit 1
fi

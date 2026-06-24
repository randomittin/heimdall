#!/usr/bin/env bash
# cp-scheduler.test.sh — the CARDINAL tests for control-plane piece (c): THE SCHEDULER.
#
# DESIGN DOSSIER §6 (authoritative). Proves the scheduler is an ALLOWLISTED-ONLY
# automated client of the §1 dispatch path — it can fire ONLY allowlisted dispatches,
# NEVER an arbitrary command. Drives the REAL substrate (cp_allowlist / cp_audit /
# cp_server / cp_handlers) + the REAL cp_scheduler — no mocks of the thing under test,
# no canned numbers:
#
#   S. ALLOWLISTED SCHEDULE FIRES AN ALLOWLISTED DISPATCH (§6, the core):
#      S1. create a schedule for an ALLOWLISTED action_type (sync-queue hourly) ->
#          accepted + persisted.
#      S2. SIMULATE THE CLOCK to a due minute -> tick() fires it -> the dispatch is
#          accepted (200) for the allowlisted action.
#      S3. a NOT-due minute -> tick() fires NOTHING (the cron WHEN gate works).
#
#   R. UNKNOWN / SMUGGLED SCHEDULE IS REFUSED AT CREATE (§6/§1, falsifiable):
#      R1. create a schedule for an UNKNOWN action_type ("shell") -> REFUSED
#          (RefusedDispatch / 422) + an audit dispatch_refused row, NEVER persisted.
#      R2. create a schedule with a SMUGGLED command field (extra `cmd`) -> REFUSED
#          (extra_param) + audited, NEVER persisted.
#      R3. create a schedule with a shell payload in a typed param ("; rm -rf /") ->
#          REFUSED (bad_param), NEVER persisted.
#      R4. FALSIFIABILITY: S1 (a valid allowlisted schedule) succeeds WHILE R1-R3 are
#          refused -> refuse-arbitrary, distinct from refuse-everything. A scheduler
#          that fired an arbitrary command would RED here (S would still pass but the
#          refusals would not; or the store would hold an off-allowlist entry).
#      R5. the live schedule store holds ONLY the allowlisted schedule — NONE of the
#          refused ones were persisted (a falsifiable scheduler must not store them).
#
#   A. A FIRED SCHEDULE PRODUCES AN AUDIT DISPATCH RECORD (§9):
#      A1. after tick() fires the allowlisted schedule, the audit store has a
#          `dispatch` row for that action_type.
#      A2. a refused CREATE produced an audit `dispatch_refused` row.
#
#   G. THE SCHEDULER DISPATCHES THROUGH cp_allowlist, NOT A RAW EXEC (§6):
#      G1. the source IMPORTS cp_allowlist AND calls cp_allowlist.validate (the gate).
#      G2. the source dispatches through cp_server.dispatch (the §1 path), and there
#          is NO raw os.system / subprocess / exec / eval / os.popen of a schedule
#          field anywhere in cp_scheduler.py — the scheduler can only fire validated,
#          named allowlist dispatches.
#      G3. a GATED scheduled action (run-suite, requires_gate) still surfaces to the
#          approval queue (requires_approval 422) at fire-time — the scheduler does
#          not skip the gate.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
SCHED_SRC="$LIB/cp_scheduler.py"

[ -f "$SCHED_SRC" ] || { echo "FATAL: $SCHED_SRC missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-scheduler.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/cphome"

# ── Drive the real scheduler + substrate through one python harness ────────────
# The clock is SIMULATED: we create a schedule whose cron matches a fixed minute,
# then tick() at that exact datetime (due) and at a different minute (not due).
HARNESS_OUT="$WORK/harness.out"
LIB="$LIB" "$PY" - >"$HARNESS_OUT" 2>"$WORK/harness.err" <<'PYEOF'
import datetime, json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_allowlist as A
import cp_audit as Au
import cp_scheduler as Sc

out = {}

# a non-owner actor for the create/CRUD path, and an owner actor for fire-time so a
# gated run-suite would be allowed to dispatch IF approved (G3 proves it is NOT).
import cp_auth as K
actor = K.Identity("haid:rj.mbp-7f3a", owner=True)

# A fixed simulated minute the cron will match: 02:00 on the 15th of June 2026 (a
# Monday). cron "0 2 15 6 *" -> minute 0, hour 2, dom 15, month 6, any dow.
DUE = datetime.datetime(2026, 6, 15, 2, 0, tzinfo=datetime.timezone.utc)
NOT_DUE = datetime.datetime(2026, 6, 15, 3, 0, tzinfo=datetime.timezone.utc)
CRON = "0 2 15 6 *"

# S1 — create an ALLOWLISTED schedule (sync-queue). Accepted + persisted.
try:
    entry = Sc.create_schedule(actor, "sync-queue", {"queue": "issue"}, CRON)
    out["create_allowlisted_ok"] = bool(entry.get("schedule_id"))
    out["allowlisted_sid"] = entry["schedule_id"]
except Exception as exc:  # noqa: BLE001
    out["create_allowlisted_ok"] = False
    out["allowlisted_sid"] = None
    out["create_err"] = "%s: %s" % (type(exc).__name__, exc)

# R1 — UNKNOWN action_type schedule -> REFUSED, never persisted. Drive it through
# the REAL create ROUTE (_route_create — the actual POST /schedules surface), which
# maps the refusal to a 422 + an audit dispatch_refused row (the §6 "422 + audit"
# create contract end-to-end). The body carries a smuggled `cmd` to boot.
out["unknown_refused"] = False
req = {"method": "POST", "path": "/schedules",
       "body": json.dumps({"action_type": "shell",
                           "params": {"cmd": "rm -rf /"}, "cron": CRON}).encode()}
resp = Sc._route_create(actor, req)
out["unknown_refused"] = (resp.status == 422 and resp.body.get("reason") == "unknown_action")
out["unknown_route_audited"] = bool(resp.audit_id)

# also assert the function path RAISES (the seam create_schedule re-raises for the
# route to map) — proves the gate is in create_schedule, not only the route.
out["unknown_fn_raises"] = False
try:
    Sc.create_schedule(actor, "shell", {"cmd": "rm -rf /"}, CRON)
except A.RefusedDispatch as ref:
    out["unknown_fn_raises"] = (ref.reason == "unknown_action")

# R2 — SMUGGLED command field (extra `cmd`) -> REFUSED (extra_param), never persisted.
out["smuggle_refused"] = False
try:
    Sc.create_schedule(actor, "sync-queue", {"queue": "issue", "cmd": "rm -rf /"}, CRON)
except A.RefusedDispatch as ref:
    out["smuggle_refused"] = (ref.reason == "extra_param")

# R3 — shell payload in a typed param -> REFUSED (bad_param), never persisted. Use
# run-task-X whose task_id is an id-shaped Str; "; rm -rf /" fails the pattern.
out["payload_refused"] = False
try:
    Sc.create_schedule(actor, "run-task-X", {"task_id": "; rm -rf /"}, CRON)
except A.RefusedDispatch as ref:
    out["payload_refused"] = (ref.reason == "bad_param")

# R5 — the live store holds ONLY the allowlisted schedule (none of the refused ones).
live = Sc.list_schedules()
out["live_count"] = len(live)
out["live_action_types"] = sorted({e["action_type"] for e in live})

# S3 — a NOT-due minute fires nothing.
fired_not_due = Sc.tick(actor, NOT_DUE)
out["fired_not_due_count"] = len(fired_not_due)

# S2 — SIMULATE THE CLOCK to the due minute -> tick fires the allowlisted dispatch.
fired_due = Sc.tick(actor, DUE)
out["fired_due_count"] = len(fired_due)
out["fired_due"] = [
    {"action_type": f["action_type"], "status": f["status"],
     "has_action_id": bool(f.get("action_id"))}
    for f in fired_due
]

# A1 — a fired schedule produced an audit `dispatch` row for the action_type.
disp = Au.search(event="dispatch", action_type="sync-queue")
out["audit_dispatch_for_fired"] = len(disp)

# A2 — a refused create produced an audit `dispatch_refused` row.
refs = Au.search(event="dispatch_refused")
out["audit_refused_count"] = len(refs)

# G3 — a GATED scheduled action (run-suite, requires_gate) surfaces requires_approval
# at fire-time; the scheduler does NOT skip the gate. Create + fire it WITHOUT
# approval -> the dispatch is held (422 requires_approval), not executed.
gate_entry = Sc.create_schedule(actor, "run-suite", {"suite": "unit"}, CRON)
out["gated_created"] = bool(gate_entry.get("schedule_id"))
gate_fired = Sc.tick(actor, DUE)  # no approved_action_types -> the gate holds it.
gate_run = [f for f in gate_fired if f["action_type"] == "run-suite"]
out["gated_fire_count"] = len(gate_run)
out["gated_fire_status"] = gate_run[0]["status"] if gate_run else None

sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$HARNESS_OUT" ]; then
  echo "FATAL: scheduler harness produced no output" >&2
  cat "$WORK/harness.err" >&2
  exit 2
fi

jget() { "$PY" -c "import json,sys; print(json.load(open('$HARNESS_OUT')).get('$1'))"; }

echo "S. ALLOWLISTED SCHEDULE FIRES AN ALLOWLISTED DISPATCH (§6)"
[ "$(jget create_allowlisted_ok)" = "True" ] && ok "S1 allowlisted schedule (sync-queue) created + persisted" || { bad "S1 allowlisted schedule not created"; jget create_err; }
# S2 — the due tick fired exactly the allowlisted dispatch, accepted (200).
DUE_OK="$("$PY" -c "import json; d=json.load(open('$HARNESS_OUT')); f=d.get('fired_due') or []; print(any(x['action_type']=='sync-queue' and x['status']==200 and x['has_action_id'] for x in f))")"
[ "$DUE_OK" = "True" ] && ok "S2 simulated due tick -> allowlisted dispatch fired (200, action_id)" || bad "S2 due tick did not fire the allowlisted dispatch"
[ "$(jget fired_not_due_count)" = "0" ] && ok "S3 not-due minute -> nothing fired (cron WHEN gate)" || bad "S3 not-due minute fired something"

echo "R. UNKNOWN / SMUGGLED SCHEDULE REFUSED AT CREATE (§6/§1, falsifiable)"
{ [ "$(jget unknown_refused)" = "True" ] && [ "$(jget unknown_route_audited)" = "True" ] && [ "$(jget unknown_fn_raises)" = "True" ]; } && ok "R1 unknown action_type schedule -> 422 + audit via create route, fn raises" || bad "R1 unknown action_type not refused/audited"
[ "$(jget smuggle_refused)" = "True" ] && ok "R2 smuggled cmd field schedule -> REFUSED (extra_param)" || bad "R2 smuggled cmd not refused"
[ "$(jget payload_refused)" = "True" ] && ok "R3 shell payload in param -> REFUSED (bad_param)" || bad "R3 shell payload not refused"

# R4 — falsifiability: the valid schedule fired WHILE every arbitrary one was refused.
if [ "$(jget create_allowlisted_ok)" = "True" ] && [ "$DUE_OK" = "True" ] \
   && [ "$(jget unknown_refused)" = "True" ] && [ "$(jget smuggle_refused)" = "True" ] \
   && [ "$(jget payload_refused)" = "True" ]; then
  ok "R4 FALSIFIABLE: refuse-arbitrary distinct from refuse-everything"
else
  bad "R4 not falsifiable (valid + arbitrary did not distinguish)"
fi

# R5 — only allowlisted schedules persisted (the refused ones never entered the store).
# The store holds sync-queue (S1) + run-suite (the G3 gated allowlisted one) ONLY;
# NONE of shell/run-task-X(payload) — both refused-at-create.
LIVE_TYPES="$(jget live_action_types)"
if echo "$LIVE_TYPES" | grep -q "shell"; then
  bad "R5 a refused (unknown) schedule was persisted: $LIVE_TYPES"
elif [ "$(jget live_count)" = "1" ] && echo "$LIVE_TYPES" | grep -q "sync-queue"; then
  ok "R5 store holds ONLY the allowlisted schedule (refused ones not persisted)"
else
  bad "R5 unexpected live store: count=$(jget live_count) types=$LIVE_TYPES"
fi

echo "A. A FIRED SCHEDULE PRODUCES AN AUDIT DISPATCH RECORD (§9)"
ADF="$(jget audit_dispatch_for_fired)"
[ "${ADF:-0}" -ge 1 ] && ok "A1 fired schedule -> audit dispatch row ($ADF)" || bad "A1 no audit dispatch row for the fired schedule"
ARC="$(jget audit_refused_count)"
[ "${ARC:-0}" -ge 1 ] && ok "A2 refused create -> audit dispatch_refused row ($ARC)" || bad "A2 no audit dispatch_refused row"

echo "G. THE SCHEDULER DISPATCHES THROUGH cp_allowlist, NOT A RAW EXEC (§6)"
# G1 — the source imports + calls cp_allowlist.validate (the gate).
if grep -qE '^import cp_allowlist' "$SCHED_SRC" && grep -qE 'cp_allowlist\.validate\(' "$SCHED_SRC"; then
  ok "G1 cp_scheduler imports + calls cp_allowlist.validate (the §1 gate)"
else
  bad "G1 cp_scheduler does not validate through cp_allowlist"
fi
# G2 — dispatches through cp_server.dispatch; NO raw exec of a schedule field. Scan
# for an actual call (not a comment): os.system / subprocess. / os.popen / eval( /
# exec( . The design names these only in prose; assert no CALL exists.
if grep -qE 'cp_server\.dispatch\(' "$SCHED_SRC"; then
  if grep -nE '(os\.system|subprocess\.|os\.popen|[^_a-zA-Z](eval|exec)\()' "$SCHED_SRC" \
       | grep -vE '^\s*#' | grep -vE '#' >/dev/null 2>&1; then
    bad "G2 a raw exec/subprocess/eval call exists in cp_scheduler.py"
  else
    ok "G2 dispatches via cp_server.dispatch; NO raw exec/subprocess/eval call"
  fi
else
  bad "G2 cp_scheduler does not dispatch through cp_server.dispatch"
fi
# G3 — a gated scheduled action surfaces requires_approval (the gate is not skipped).
[ "$(jget gated_created)" = "True" ] && [ "$(jget gated_fire_count)" = "1" ] \
  && [ "$(jget gated_fire_status)" = "422" ] \
  && ok "G3 gated run-suite schedule -> requires_approval at fire (gate not skipped)" \
  || bad "G3 gated schedule did not surface the approval gate (status=$(jget gated_fire_status))"

echo
printf "cp-scheduler: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

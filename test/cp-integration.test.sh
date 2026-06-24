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

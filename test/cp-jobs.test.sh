#!/usr/bin/env bash
# cp-jobs.test.sh — THE CARDINAL TESTS for control-plane piece (d): the SERVER-HOSTED
# JOB RUNNER (the flight fix). DESIGN DOSSIER §4 + §2 (authoritative).
#
# Drives the REAL modules (cp_jobstore / cp_worker) against the REAL substrate
# (cp_allowlist / cp_handlers / cp_server / cp_audit) — no mocks of the thing under
# test. Each block is falsifiable: a build that broke the property goes RED here.
#
#   F. THE FLIGHT FIX (the cardinal test, §4):
#      F1. A client process STARTS a job, gets a job_id, then DISCONNECTS (the client
#          process EXITS) — but the job runs in a SEPARATE, detached worker process
#          parented to the OS, not to the client. The client is killed; the worker
#          keeps running and drives the job to `done` against the durable log.
#      F2. A FRESH client process (no shared memory with starter or worker) reads
#          status by job_id -> state=done WITH the result. THE FLIGHT FIX, proven.
#      F3. FALSIFIABILITY: a job that died on client disconnect would be left non-done
#          (queued/running) -> F2 RED. We assert state==done from a process that never
#          saw the worker — only a TRULY server-side job can pass.
#
#   T. STATE TRANSITIONS (§4): pause -> resume -> cancel are legal + durable; an
#      ILLEGAL transition (resume a running job, transition a terminal job) is REFUSED.
#
#   I. ISOLATION (§2): the worker runs the handler inside cp_handlers.IsolatedContext;
#      a job's context REFUSES every read of the PKI key (keys.json) + the audit log
#      (audit.ndjson) + escaping the scratch dir. The §2 boundary, falsifiable: a build
#      where the worker could read the control-plane key makes a refused-flag FALSE.
#
#   R. REFUSAL (§1): a job for an UNKNOWN action_type, OR an arbitrary command smuggled
#      as a param/extra field, is REFUSED -> the job is cancelled, NEVER executes, and a
#      dispatch_refused audit row is written. A VALID allowlisted job still runs (the
#      gate distinguishes refuse-arbitrary from refuse-everything).
#
#   P. RESTART PERSISTENCE (§4): job state is the fold of an on-disk NDJSON log. A job
#      enqueued by one process is run to `done` by a SEPARATE process (a simulated
#      restart) that replays the log via resume_orphans — state survives a restart.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"

[ -f "$LIB/cp_jobstore.py" ] || { echo "FATAL: $LIB/cp_jobstore.py missing" >&2; exit 2; }
[ -f "$LIB/cp_worker.py" ]   || { echo "FATAL: $LIB/cp_worker.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-jobs.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/cphome"
export LIB

# ──────────────────────────────────────────────────────────────────────────────
# F. THE FLIGHT FIX — start a job in a CLIENT process that DISCONNECTS (exits),
#    with the worker in a SEPARATE DETACHED process; a FRESH process reads done.
# ──────────────────────────────────────────────────────────────────────────────
echo "F. THE FLIGHT FIX (job survives client disconnect, §4)"

# The detached WORKER: a standalone process that runs ONE job to completion off the
# durable store. It is launched detached (setsid + nohup) so killing the CLIENT does
# NOT kill it — it is parented to the OS, exactly the §4 L97 contract.
cat >"$WORK/worker_proc.py" <<'PYEOF'
import os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_worker as W
job_id = sys.argv[1]
# small delay so the CLIENT has surely exited before the job completes — proving the
# job does NOT depend on the client being alive.
time.sleep(0.4)
W.run_job(job_id, actor_haid="haid:rj.mbp-7f3a", home=os.environ["HEIMDALL_HOME"],
          checkpoints=2)
PYEOF

# The CLIENT: enqueues a job, spawns the detached worker, prints the job_id, EXITS.
# After this process is gone, the job must still complete (the worker is detached).
cat >"$WORK/client_proc.py" <<'PYEOF'
import os, sys, subprocess
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
job_id = J.create_job("run-task-X", {"task_id": "flight-job"},
                      instance_haid="haid:rj.mbp-7f3a", home=home)
# launch the worker DETACHED (its own session) so it outlives this client process.
subprocess.Popen(
    [sys.executable, os.path.join(os.environ["WORK"], "worker_proc.py"), job_id],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    start_new_session=True,
)
print(job_id)
PYEOF

WORK="$WORK" "$PY" "$WORK/client_proc.py" >"$WORK/jobid.txt" 2>"$WORK/client.err"
JOB_ID="$(cat "$WORK/jobid.txt" | tr -d '[:space:]')"
# the CLIENT process has now EXITED (the command above returned) — the client is gone.
if [ -n "$JOB_ID" ]; then
  ok "F1 client started job ($JOB_ID), then the client process EXITED (disconnect)"
else
  bad "F1 client did not return a job_id"
  cat "$WORK/client.err" >&2
fi

# A FRESH client process (no relation to the worker) polls status until done/timeout.
cat >"$WORK/poll_proc.py" <<'PYEOF'
import os, sys, time
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
home = os.environ["HEIMDALL_HOME"]
job_id = sys.argv[1]
deadline = time.time() + 10
state = None
result = None
while time.time() < deadline:
    folded = J.read_job(job_id, home)
    if folded:
        state = folded.get("state")
        result = folded.get("result")
        if state in ("done", "cancelled"):
            break
    time.sleep(0.1)
print("%s|%s" % (state, (result or {}).get("status") if isinstance(result, dict) else result))
PYEOF

POLL_OUT="$("$PY" "$WORK/poll_proc.py" "$JOB_ID" 2>"$WORK/poll.err")"
FINAL_STATE="${POLL_OUT%%|*}"
RESULT_STATUS="${POLL_OUT#*|}"
[ "$FINAL_STATE" = "done" ] && ok "F2 fresh client reads state=done (the flight fix)" \
  || bad "F2 fresh client did NOT read done (got '$FINAL_STATE') — job died on disconnect"
[ "$RESULT_STATUS" = "prepared" ] && ok "F2 fresh client reads the job RESULT (status=prepared)" \
  || bad "F2 result not surfaced to the reconnecting client (got '$RESULT_STATUS')"
# F3 falsifiability: done was reached by a process that never saw the worker.
[ "$FINAL_STATE" = "done" ] && ok "F3 FALSIFIABLE: a disconnect-killed job would be non-done here" \
  || bad "F3 not falsifiable"

# ──────────────────────────────────────────────────────────────────────────────
# The remaining blocks drive cp_jobstore / cp_worker directly in one harness.
# ──────────────────────────────────────────────────────────────────────────────
HARNESS_OUT="$WORK/harness.out"
"$PY" - >"$HARNESS_OUT" 2>"$WORK/harness.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
import cp_worker as W
home = os.environ["HEIMDALL_HOME"]
out = {}

# ── T. STATE TRANSITIONS — pause -> resume -> cancel legal + durable; illegal refused.
jid = J.create_job("run-task-X", {"task_id": "transit-job"},
                   instance_haid="haid:rj.mbp-7f3a", home=home)
J.transition(jid, "running", home=home)
out["t_after_running"] = J.current_state(jid, home)
W.request_pause(jid, actor_haid="haid:rj.mbp-7f3a", home=home)
out["t_after_pause"] = J.current_state(jid, home)
W.request_resume(jid, actor_haid="haid:rj.mbp-7f3a", home=home)
out["t_after_resume"] = J.current_state(jid, home)
W.request_cancel(jid, actor_haid="haid:rj.mbp-7f3a", home=home)
out["t_after_cancel"] = J.current_state(jid, home)

# illegal: resume a job that is not paused (it is cancelled/terminal now) -> refused.
try:
    W.request_resume(jid, home=home)
    out["t_illegal_refused"] = False
except J.IllegalTransition:
    out["t_illegal_refused"] = True

# illegal: pause a freshly-queued job (queued -> paused is not a legal edge) -> refused.
jid2 = J.create_job("sync-queue", {"queue": "issue"}, home=home)
try:
    W.request_pause(jid2, home=home)
    out["t_queued_pause_refused"] = False
except J.IllegalTransition:
    out["t_queued_pause_refused"] = True

# ── I. ISOLATION — the worker's IsolatedContext refuses control-plane reads (§2).
refused = W.assert_isolated_cannot_read_control_plane("iso-probe", home=home)
out["iso_keys_refused"] = refused.get(os.path.join("control-plane", "auth", "keys.json"))
out["iso_audit_refused"] = refused.get(os.path.join("control-plane", "audit", "audit.ndjson"))
out["iso_escape_refused"] = refused.get(os.path.join("..", "control-plane", "auth", "keys.json"))
out["iso_keysjson_refused"] = refused.get("keys.json")
out["iso_auditndjson_refused"] = refused.get("audit.ndjson")
out["iso_env_scrubbed"] = refused.get("env_scrubbed")
out["iso_all_refused"] = all(
    v is True for k, v in refused.items())

# a REAL handler run inside the context must still succeed (isolation is a wall, not
# a brick — bounded named work proceeds; only control-plane reads are denied).
jid3 = J.create_job("run-task-X", {"task_id": "iso-ok-job"},
                    instance_haid="haid:rj.mbp-7f3a", home=home)
final3 = W.run_job(jid3, actor_haid="haid:rj.mbp-7f3a", home=home, checkpoints=2)
out["iso_valid_job_done"] = (final3.get("state") == "done")

# ── R. REFUSAL — an UNKNOWN action / smuggled command never runs; valid runs.
# unknown action_type job: the worker refuses it, cancels it, never executes.
jbad = J.create_job("shell", {"cmd": "rm -rf /"},
                    instance_haid="haid:rj.mbp-7f3a", home=home)
try:
    W.run_job(jbad, actor_haid="haid:rj.mbp-7f3a", home=home, checkpoints=2)
    out["r_unknown_raised"] = False
except W.ActionRefused as e:
    out["r_unknown_raised"] = (e.reason == "unknown_action")
out["r_unknown_state"] = J.current_state(jbad, home)  # must be cancelled, not done.

# command smuggled as an extra param: refused on the extra field, never runs.
jsmug = J.create_job("run-task-X", {"task_id": "ok", "cmd": "rm -rf /"},
                     instance_haid="haid:rj.mbp-7f3a", home=home)
try:
    W.run_job(jsmug, actor_haid="haid:rj.mbp-7f3a", home=home, checkpoints=2)
    out["r_smuggle_raised"] = False
except W.ActionRefused as e:
    out["r_smuggle_raised"] = (e.reason == "extra_param")
out["r_smuggle_state"] = J.current_state(jsmug, home)

# shell payload smuggled INTO a typed param: refused on the pattern, never runs.
jpay = J.create_job("run-task-X", {"task_id": "; rm -rf /"},
                    instance_haid="haid:rj.mbp-7f3a", home=home)
try:
    W.run_job(jpay, actor_haid="haid:rj.mbp-7f3a", home=home, checkpoints=2)
    out["r_payload_raised"] = False
except W.ActionRefused as e:
    out["r_payload_raised"] = (e.reason == "bad_param")
out["r_payload_state"] = J.current_state(jpay, home)

# a VALID job still runs to done (refuse-arbitrary, not refuse-everything).
jok = J.create_job("sync-queue", {"queue": "gate"},
                   instance_haid="haid:rj.mbp-7f3a", home=home)
finalok = W.run_job(jok, actor_haid="haid:rj.mbp-7f3a", home=home, checkpoints=2)
out["r_valid_done"] = (finalok.get("state") == "done")

# ── audit: the refusal + the dispatch both wrote rows (§9).
import cp_audit as Au
out["audit_refused_rows"] = len(Au.search(event="dispatch_refused", home=home))
out["audit_dispatch_rows"] = len(Au.search(event="dispatch", home=home))
out["audit_jobstate_rows"] = len(Au.search(event="job_state", home=home))

sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$HARNESS_OUT" ]; then
  echo "FATAL: harness produced no output" >&2
  cat "$WORK/harness.err" >&2
  exit 2
fi
jget() { "$PY" -c "import json; print(json.load(open('$HARNESS_OUT')).get('$1'))"; }

echo "T. STATE TRANSITIONS (§4)"
[ "$(jget t_after_running)" = "running" ] && ok "T queued -> running" || bad "T running transition failed"
[ "$(jget t_after_pause)" = "paused" ]    && ok "T running -> paused" || bad "T pause transition failed"
[ "$(jget t_after_resume)" = "running" ]  && ok "T paused -> resume (running)" || bad "T resume transition failed"
[ "$(jget t_after_cancel)" = "cancelled" ] && ok "T running -> cancelled" || bad "T cancel transition failed"
[ "$(jget t_illegal_refused)" = "True" ]  && ok "T illegal transition (resume terminal) REFUSED" || bad "T illegal transition not refused"
[ "$(jget t_queued_pause_refused)" = "True" ] && ok "T illegal transition (queued->paused) REFUSED" || bad "T queued->paused not refused"

echo "I. ISOLATION — worker cannot read PKI key / audit (§2)"
[ "$(jget iso_keys_refused)" = "True" ]      && ok "I read of control-plane/auth/keys.json REFUSED" || bad "I PKI key read NOT refused"
[ "$(jget iso_audit_refused)" = "True" ]     && ok "I read of control-plane/audit/audit.ndjson REFUSED" || bad "I audit read NOT refused"
[ "$(jget iso_escape_refused)" = "True" ]    && ok "I scratch-dir escape to key dir REFUSED" || bad "I scratch escape NOT refused"
[ "$(jget iso_keysjson_refused)" = "True" ]  && ok "I bare keys.json read REFUSED" || bad "I keys.json NOT refused"
[ "$(jget iso_auditndjson_refused)" = "True" ] && ok "I bare audit.ndjson read REFUSED" || bad "I audit.ndjson NOT refused"
[ "$(jget iso_env_scrubbed)" = "True" ]      && ok "I scrubbed env carries no server secret var" || bad "I env not scrubbed"
[ "$(jget iso_all_refused)" = "True" ]       && ok "I FALSIFIABLE: every control-plane read refused (a breach would flip a flag)" || bad "I a control-plane read leaked"
[ "$(jget iso_valid_job_done)" = "True" ]    && ok "I a valid handler still runs to done INSIDE the isolated context" || bad "I valid isolated job did not complete"

echo "R. REFUSAL — only an allowlisted action runs; arbitrary command refused (§1)"
[ "$(jget r_unknown_raised)" = "True" ]  && ok "R unknown action_type ('shell') REFUSED (never runs)" || bad "R unknown action not refused"
[ "$(jget r_unknown_state)" = "cancelled" ] && ok "R unknown-action job marked cancelled, NOT done" || bad "R unknown-action job not cancelled"
[ "$(jget r_smuggle_raised)" = "True" ]  && ok "R smuggled cmd field REFUSED (never runs)" || bad "R smuggled cmd not refused"
[ "$(jget r_smuggle_state)" = "cancelled" ] && ok "R smuggle job cancelled, NOT done" || bad "R smuggle job not cancelled"
[ "$(jget r_payload_raised)" = "True" ]  && ok "R shell payload in param REFUSED (never runs)" || bad "R payload not refused"
[ "$(jget r_payload_state)" = "cancelled" ] && ok "R payload job cancelled, NOT done" || bad "R payload job not cancelled"
[ "$(jget r_valid_done)" = "True" ]      && ok "R FALSIFIABLE: a VALID allowlisted job still runs (refuse-arbitrary not refuse-all)" || bad "R valid job did not run"

echo "AUDIT (§9)"
[ "$(jget audit_refused_rows)" -ge 1 ] && ok "audit dispatch_refused rows present ($(jget audit_refused_rows))" || bad "no dispatch_refused audit"
[ "$(jget audit_dispatch_rows)" -ge 1 ] && ok "audit dispatch rows present ($(jget audit_dispatch_rows))" || bad "no dispatch audit"
[ "$(jget audit_jobstate_rows)" -ge 1 ] && ok "audit job_state rows present ($(jget audit_jobstate_rows))" || bad "no job_state audit"

# ──────────────────────────────────────────────────────────────────────────────
# P. RESTART PERSISTENCE — one process enqueues; a SEPARATE process runs it to done
#    by replaying the on-disk log (resume_orphans). State survives a process restart.
# ──────────────────────────────────────────────────────────────────────────────
echo "P. RESTART PERSISTENCE (state = fold of on-disk log, §4)"

# Process 1: enqueue a job and EXIT (the genesis line is on disk; nothing runs it).
ENQ_JOB="$("$PY" -c "
import os,sys
sys.path.insert(0, os.environ['LIB'])
import cp_jobstore as J
jid = J.create_job('run-task-X', {'task_id':'restart-job'}, instance_haid='haid:rj.mbp-7f3a', home=os.environ['HEIMDALL_HOME'])
print(jid)
")"
ENQ_JOB="$(echo "$ENQ_JOB" | tr -d '[:space:]')"

# Process 2 (the simulated RESTART): a fresh interpreter reads the durable store and
# folds the state — proving it survived the first process exiting.
STATE_AFTER_ENQ="$("$PY" -c "
import os,sys
sys.path.insert(0, os.environ['LIB'])
import cp_jobstore as J
print(J.current_state('$ENQ_JOB', os.environ['HEIMDALL_HOME']))
")"
[ "$STATE_AFTER_ENQ" = "queued" ] && ok "P state SURVIVES the first process exit (fresh process reads queued)" || bad "P state lost across process boundary (got '$STATE_AFTER_ENQ')"

# Process 3 (the RESTART boot hook): resume_orphans replays the log + drives the
# queued job to done — a different process completes a job a now-gone process enqueued.
RESTART_FINAL="$("$PY" -c "
import os,sys
sys.path.insert(0, os.environ['LIB'])
import cp_worker as W, cp_jobstore as J
W.resume_orphans(actor_haid='haid:rj.mbp-7f3a', home=os.environ['HEIMDALL_HOME'], checkpoints=2)
print(J.current_state('$ENQ_JOB', os.environ['HEIMDALL_HOME']))
")"
[ "$RESTART_FINAL" = "done" ] && ok "P a SEPARATE process (restart) replays the log + drives the job to done" || bad "P restart replay did not complete the job (got '$RESTART_FINAL')"

echo
printf "cp-jobs: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

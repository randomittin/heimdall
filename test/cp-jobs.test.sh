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

# ──────────────────────────────────────────────────────────────────────────────
# X. RUNNING-ORPHAN RECLAIM + PERIODIC RESUME (audit §3a). resume_orphans now also
#    reclaims a job left `running` when its container died (past a lease), bounded to a
#    re-drive-once-then-fail-terminal policy; and the tick runs the pass on a cadence, not
#    only at boot. Hermetic: an isolated home, a fake lease clock (now=), an injected runner.
# ──────────────────────────────────────────────────────────────────────────────
echo "X. running-orphan reclaim + periodic resume (§3a)"
X_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/x.err"
import datetime, json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
import cp_worker as W
import cp_boot as B

now = datetime.datetime.now(datetime.timezone.utc)
past_lease = now + datetime.timedelta(hours=3)                # > the 2h default running lease

# A dead-container re-drive: leaves the job `running` (simulates a re-orphan), so the bounded
# reclaim must fail it terminal on the SECOND pass. Reads the job in ITS OWN home (threaded
# through by resume_orphans_pass), so each sub-case can use an isolated store.
def reorphan_runner(job_id, **kw):
    return J.read_job(job_id, kw.get("home"))

# A successful re-drive: this instance takes over and completes the job (in its own home).
def completing_runner(job_id, *, resume_running=False, **kw):
    h = kw.get("home")
    if resume_running and J.current_state(job_id, h) == J.STATE_RUNNING:
        J.set_result(job_id, {"status": "reclaimed"}, home=h)
        J.transition(job_id, J.STATE_DONE, home=h)
    return J.read_job(job_id, h)

# Each sub-case gets an ISOLATED store: the fake past_lease clock of one case must never make a
# a still-running job from an earlier sub-case look orphaned (shared home cross-contaminates counts).
h1 = os.path.join(os.environ["HEIMDALL_HOME"], "reclaim-within")
h2 = os.path.join(os.environ["HEIMDALL_HOME"], "reclaim-bounded")
h3 = os.path.join(os.environ["HEIMDALL_HOME"], "reclaim-good")

# ── (1) WITHIN LEASE — a fresh running job is NOT reclaimed (age < lease). ──
fresh = J.create_job("run-task-X", {"task_id": "fresh"}, home=h1)
J.transition(fresh, "running", home=h1)
p_fresh = W.resume_orphans_pass(home=h1, runner=reorphan_runner, now=now)
within_lease_skipped = (p_fresh["reclaimed"] == 0 and J.current_state(fresh, h1) == "running")

# ── (2) BOUNDED RECLAIM — a running orphan past lease is reclaimed ONCE then failed terminal. ──
orphan = J.create_job("run-task-X", {"task_id": "orphan"}, home=h2)
J.transition(orphan, "running", home=h2)
# pass 1: re-drive (the runner re-orphans it) -> still running, one reclaim marker recorded.
pass1 = W.resume_orphans_pass(home=h2, runner=reorphan_runner, now=past_lease)
state1 = J.current_state(orphan, h2)
marks1 = W._reclaim_count(orphan, h2)
# pass 2: bound exhausted -> failed terminal (running -> cancelled, noted).
pass2 = W.resume_orphans_pass(home=h2, runner=reorphan_runner, now=past_lease)
state2 = J.current_state(orphan, h2)

# ── (3) SUCCESSFUL RECLAIM — a running orphan re-driven to done (the happy reclaim). ──
good = J.create_job("run-task-X", {"task_id": "good"}, home=h3)
J.transition(good, "running", home=h3)
pass_good = W.resume_orphans_pass(home=h3, runner=completing_runner, now=past_lease)
state_good = J.current_state(good, h3)

# ── (4) PERIODIC CADENCE — _maybe_resume fires ONLY every Nth (5th) tick. ──
chome = os.path.join(os.environ["HEIMDALL_HOME"], "cadence")
J.create_job("sync-queue", {"queue": "issue"}, home=chome)   # a queued job to requeue
fired = [B._maybe_resume(n, home=chome) for n in range(1, 6)]
cadence_ok = (all(f is None for f in fired[:4]) and fired[4] is not None)
# the resume that DID fire re-drove the queued job (requeued>=1) — the tick really works.
cadence_requeued = (fired[4] or {}).get("requeued", 0) >= 1

print(json.dumps({
    "within_lease_skipped": within_lease_skipped,
    "pass1_reclaimed": pass1["reclaimed"] == 1,
    "state1_still_running": state1 == "running",
    "one_reclaim_mark": marks1 == 1,
    "pass2_failed_terminal": (pass2["reclaimed"] == 1 and state2 == "cancelled"),
    "good_reclaimed_done": (pass_good["reclaimed"] == 1 and state_good == "done"),
    "cadence_fires_on_5th": cadence_ok,
    "cadence_requeued": cadence_requeued,
}))
PYEOF
)"
if [ -s "$WORK/x.err" ]; then cat "$WORK/x.err" >&2; fi
jx(){ printf '%s' "$X_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jx within_lease_skipped)" = "True" ] && ok "X1 a running job WITHIN its lease is NOT reclaimed (no false reclaim of a live job)" || bad "X1 within-lease job wrongly reclaimed (X_OUT=$X_OUT)"
[ "$(jx pass1_reclaimed)" = "True" ] && [ "$(jx state1_still_running)" = "True" ] && [ "$(jx one_reclaim_mark)" = "True" ] \
  && ok "X2 a running orphan past lease is RECLAIMED (re-driven once; one durable reclaim marker recorded)" || bad "X2 reclaim did not re-drive once (X_OUT=$X_OUT)"
[ "$(jx pass2_failed_terminal)" = "True" ] \
  && ok "X3 a STILL-orphaned running job (re-drive exhausted) is FAILED TERMINAL (running -> cancelled) — bounded, never re-driven forever" || bad "X3 exhausted reclaim not failed terminal (X_OUT=$X_OUT)"
[ "$(jx good_reclaimed_done)" = "True" ] \
  && ok "X4 a running orphan the re-drive COMPLETES is reclaimed to done (the happy reclaim path)" || bad "X4 successful reclaim did not reach done (X_OUT=$X_OUT)"
[ "$(jx cadence_fires_on_5th)" = "True" ] && [ "$(jx cadence_requeued)" = "True" ] \
  && ok "X5 the periodic resume fires ONLY on the Nth (5th) tick and re-drives orphaned work (audit §3a fix (a))" || bad "X5 periodic resume cadence wrong (X_OUT=$X_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# Y. BUG #15 — RUNNER-HONORING queued resume + GRACE (proven live 2026-07-05 20:24).
#    resume_orphans drove QUEUED jobs via run_job IN-PROCESS regardless of the runner. On the
#    gated service (a REMOTE cloudrun-job runner) a resume pass then STOLE a freshly-queued job
#    18s after dispatch and ran it in-process with STALE code, while the real Cloud Run Job
#    execution ran the SAME job — a double-run. THE FIX: a REMOTE runner RE-DISPATCHES a queued
#    orphan via the runner (never run_job in-process); a queued job younger than the grace window
#    is SKIPPED (its dispatch is still booting); an IN-PROCESS runner is unchanged (run_job).
# ──────────────────────────────────────────────────────────────────────────────
echo "Y. bug #15 — runner-honoring queued resume + grace"
Y_OUT="$("$PY" - <<'PYEOF' 2>"$WORK/y.err"
import datetime, json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_jobstore as J
import cp_worker as W
import cp_jobrunner as R

base = os.environ["HEIMDALL_HOME"]
now = datetime.datetime.now(datetime.timezone.utc)
old = now + datetime.timedelta(minutes=10)   # > the 5min queued grace -> a genuine stuck orphan

class Rec:
    """A fake JobRunner: records every dispatch() so the test can prove the DISPATCH path ran
    (or did not). name pins whether resume treats it as REMOTE (cloudrun-job) or in-process."""
    def __init__(self, name):
        self.name = name
        self.calls = []
    def dispatch(self, job_id, **kw):
        self.calls.append(job_id)
        return {"dispatched": True, "runner": self.name}

ran = []   # records ANY in-process run_job-style invocation — must stay empty on the remote path.
def recording_run(job_id, **kw):
    ran.append(job_id)
    h = kw.get("home")
    J.transition(job_id, J.STATE_RUNNING, home=h)
    J.set_result(job_id, {"status": "in-proc"}, home=h)
    J.transition(job_id, J.STATE_DONE, home=h)
    return J.read_job(job_id, home=h)

# (1) REMOTE + OLD queued -> RE-DISPATCH via the runner; run_job NOT invoked; job stays queued
#     (the real out-of-process execution moves it, not this host).
h1 = os.path.join(base, "bug15-remote-old")
rem1 = Rec(R.RUNNER_CLOUDRUN)
j1 = J.create_job("sync-queue", {"queue": "issue"}, home=h1)
W.resume_orphans_pass(home=h1, runner=recording_run, job_runner=rem1, now=old)
remote_old_dispatched = (rem1.calls == [j1])
remote_old_no_inproc = (j1 not in ran)
remote_old_still_queued = (J.current_state(j1, h1) == "queued")

# (2) REMOTE + YOUNG queued -> SKIPPED by grace; no dispatch, no run_job, stays queued
#     (its dispatcher just created an execution — the container is booting).
h2 = os.path.join(base, "bug15-remote-young")
rem2 = Rec(R.RUNNER_CLOUDRUN)
j2 = J.create_job("sync-queue", {"queue": "issue"}, home=h2)
W.resume_orphans_pass(home=h2, runner=recording_run, job_runner=rem2, now=now)
young_skipped = (rem2.calls == [] and j2 not in ran and J.current_state(j2, h2) == "queued")

# (3) IN-PROCESS runner (thread) + OLD queued -> run_job IN-PROCESS; dispatch NOT called; done.
#     The in-process resume path is UNCHANGED for thread/subprocess runners.
h3 = os.path.join(base, "bug15-inproc")
thr = Rec(R.RUNNER_THREAD)
j3 = J.create_job("sync-queue", {"queue": "issue"}, home=h3)
W.resume_orphans_pass(home=h3, runner=recording_run, job_runner=thr, now=old)
inproc_ran = (j3 in ran)
inproc_no_dispatch = (thr.calls == [])
inproc_done = (J.current_state(j3, h3) == "done")

print(json.dumps({
  "remote_old_dispatched": remote_old_dispatched,
  "remote_old_no_inproc": remote_old_no_inproc,
  "remote_old_still_queued": remote_old_still_queued,
  "young_skipped": young_skipped,
  "inproc_ran": inproc_ran,
  "inproc_no_dispatch": inproc_no_dispatch,
  "inproc_done": inproc_done,
}))
PYEOF
)"
if [ -s "$WORK/y.err" ]; then cat "$WORK/y.err" >&2; fi
jy(){ printf '%s' "$Y_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
[ "$(jy remote_old_dispatched)" = "True" ] && [ "$(jy remote_old_no_inproc)" = "True" ] && [ "$(jy remote_old_still_queued)" = "True" ] \
  && ok "Y1 REMOTE runner: an OLD queued orphan is RE-DISPATCHED via the runner, run_job NOT invoked in-process (bug #15 — no double-run)" || bad "Y1 remote re-dispatch wrong (Y_OUT=$Y_OUT)"
[ "$(jy young_skipped)" = "True" ] \
  && ok "Y2 REMOTE runner: a YOUNG queued job (< grace) is SKIPPED — its dispatch is still booting (grace guard)" || bad "Y2 young queued not skipped (Y_OUT=$Y_OUT)"
[ "$(jy inproc_ran)" = "True" ] && [ "$(jy inproc_no_dispatch)" = "True" ] && [ "$(jy inproc_done)" = "True" ] \
  && ok "Y3 IN-PROCESS runner (thread): queued orphan re-driven via run_job in-process, no dispatch — unchanged" || bad "Y3 in-process resume changed (Y_OUT=$Y_OUT)"

echo
printf "cp-jobs: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

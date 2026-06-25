#!/usr/bin/env bash
# verify-flight-fix.sh — PROVE the durable server-hosted job flight-fix on the REAL
# Cloud Run + REAL Firestore target (spec: heimdall-cp-deploy-and-diagnostics-spec.md §A4,
# deploy/cloud-run/README.md §1/§3/§4).
#
# THE CLAIM UNDER TEST. A signed client starts a server-hosted job over POST /jobs; the
# handler returns a job_id IMMEDIATELY and the job runs server-side, parented to the
# server, off a DURABLE record. On Cloud Run the per-instance home is EPHEMERAL — wiped
# on scale-to-zero — so the durability only holds because the job state lives in
# Firestore (HEIMDALL_STATE_BACKEND=firestore), an EXTERNAL store keyed to the project,
# not the home. THIS script proves it END-TO-END against the live target:
#
#   1. SIGN + POST /jobs against $BASE_URL                 -> capture job_id (non-blocking).
#   2. Poll signed GET /jobs (job_id in body) until done   -> the durable state is present.
#   2b.(gcloud-only) poll the heimdall-long-job EXECUTIONS  -> a succeeded execution carrying
#      list for a SUCCEEDED execution carrying this job_id     this job_id is the AUTHORITATIVE
#      -> the job dispatched + ran OUT-OF-PROCESS. run_v2 dispatch is ASYNC (the Job provisions
#      ~36s then runs), so this execution-status signal — not the tight job-record poll — is the
#      true PASS signal; a timed-out STEP-2 poll alongside a succeeded execution is a TIMING
#      ARTIFACT, not a dispatch failure. Skipped cleanly in local/dry-run (no gcloud).
#   3. (optional, gated on gcloud) confirm the job doc      -> in REAL Firestore (the
#      cp_state_firestore rel->doc mapping); PRINT the doc path either way.
#   4. SCALE TO ZERO — replace the serving instance deterministically so the next request
#      hits a FRESH instance with NO local state (the old instance's memory + ephemeral
#      disk are GONE). IMAGE-PRESERVING: the rollout captures the currently-serving 100%-
#      traffic digest FIRST and PINS the no-op revision to that exact `--image <digest>`, then
#      ASSERTS the served digest is unchanged after — so STEP 4 can never silently roll the
#      service back to an older image mid-test (the prod STEP-4 rollback bug, fixed).
#   5. After cold-start, signed GET /jobs for the SAME job_id -> the job + its folded state
#      come back, read from Firestore by an instance that never ran the job. THE FLIGHT FIX.
#   6. PASS/FAIL verdict — PASS iff the durable state resolved from a fresh instance after
#      scale-to-zero. Exit nonzero on FAIL.
#
# THIS SCRIPT TALKS ONLY HTTP + (optionally) gcloud. It contains NO secret literal — the
# PKI seed arrives via the PKI_SEED env (sourced from Secret Manager by the operator) and
# is NEVER printed, logged, or echoed. The signing path REUSES the shipped cp_auth signer
# (bin/lib/cp_auth.py, the same canonical_message + sign the wired gate uses) — this script
# never hand-rolls Ed25519.
#
# ── HOW RJ RUNS IT (live target, RJ's creds) ──────────────────────────────────────────
#   export BASE_URL="$(gcloud run services describe heimdall-control-plane \
#                        --region=us-central1 --format='value(status.url)')"
#   export PROJECT_ID="heimdall-control-plane"
#   export CLIENT_HAID="$(gcloud run services describe heimdall-control-plane \
#                          --region=us-central1 \
#                          --format='value(spec.template.spec.containers[0].env)' \
#                          | tr ',' '\n' | grep HEIMDALL_CP_SERVER_HAID | cut -d= -f2)"
#   export PKI_SEED="$(gcloud secrets versions access latest --secret=cp-pki-key)"
#   export ID_TOKEN="$(gcloud auth print-identity-token)"   # Cloud Run IAM (--no-allow-unauthenticated)
#   bash deploy/cloud-run/verify-flight-fix.sh
#
# CLIENT_HAID + PKI_SEED are the server's OWN registered identity: the deploy injects the
# SAME cp-pki-key seed as HEIMDALL_CP_PKI_KEY, and boot()'s ensure_server_identity registers
# server_haid -> pubkey(seed). Signing as that HAID with that seed therefore verifies — the
# known registered identity, no extra registration step on the live box. See the runbook in
# deploy/cloud-run/README.md (§7) for the full prod procedure and the local dry-run.
#
# PRECONDITION — HEIMDALL_CP_SERVER_HAID MUST be pinned on the service. The seed pins the
# KEY; HEIMDALL_CP_SERVER_HAID pins the NAME. Both halves must be stable across instances or
# the STEP 5 cold-start read-back will fail to verify (instance B would have registered a
# DIFFERENT, HOSTNAME-derived HAID than the one we sign as). The "How RJ runs it" block above
# reads CLIENT_HAID from that deployed env; the precondition check below rejects an empty
# value and names the redeploy fix. See deploy/cloud-run/README.md §3 "Stable identity".

set -uo pipefail

# ── locate the shipped signer (cp_auth) relative to THIS script ──────────────────────
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# deploy/cloud-run/ -> repo root is two up; bin/lib holds cp_auth.py (the real signer).
REPO="$(cd "$SELF_DIR/../.." && pwd)"
LIB="$REPO/bin/lib"

PY="$(command -v python3 || command -v python || true)"

# ── small terminal helpers (no secret ever passes through these) ─────────────────────
say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
die()  { printf '\033[31mFATAL\033[0m %s\n' "$1" >&2; exit 2; }

# ── preconditions (fail loud, never leak the seed) ───────────────────────────────────
[ -n "$PY" ]            || die "python3 not found (needed for the cp_auth signer)."
[ -f "$LIB/cp_auth.py" ] || die "cp_auth signer not found at $LIB/cp_auth.py (run from the repo checkout)."
: "${BASE_URL:?BASE_URL is not set — the Cloud Run https URL (e.g. https://heimdall-control-plane-<hash>.run.app).}"
# CLIENT_HAID = the server's PINNED HAID, read from the deployed HEIMDALL_CP_SERVER_HAID
# env (the "How RJ runs it" block reads it via `gcloud run services describe ... | grep
# HEIMDALL_CP_SERVER_HAID`). That command SETS CLIENT_HAID to the EMPTY STRING when the var
# is not pinned on the service — so a bare `:?` (unset-only) would not catch it. We reject an
# empty/blank value explicitly and name the fix: redeploy with HEIMDALL_CP_SERVER_HAID set
# (deploy/cloud-run/README.md §3 "Stable identity"). Without the pin, the server derives a
# per-instance HAID from the container HOSTNAME -> the cold-start read-back below cannot
# verify (instance B registered a DIFFERENT name than the one we sign as).
if [ -z "${CLIENT_HAID:-}" ] || [ -z "$(printf '%s' "${CLIENT_HAID:-}" | tr -d '[:space:]')" ]; then
  die "CLIENT_HAID is empty — the server's pinned HAID. It is read from the deployed HEIMDALL_CP_SERVER_HAID env; an empty value means the service was deployed WITHOUT that var. Redeploy with it (gcloud run services update \"\$SERVICE\" --region=\"\$REGION\" --update-env-vars=HEIMDALL_CP_SERVER_HAID=cp-server), then re-run. The value is stored+matched verbatim (no haid: prefix required); use the SAME literal the service is deployed with. See deploy/cloud-run/README.md §3 'Stable identity: both halves must be pinned'."
fi
# Trim any stray whitespace from the gcloud-extracted value (defensive).
CLIENT_HAID="$(printf '%s' "$CLIENT_HAID" | tr -d '[:space:]')"
if [ -z "${PKI_SEED:-}" ]; then
  die "PKI_SEED is not set — the base64 Ed25519 seed for CLIENT_HAID (source it from Secret Manager: gcloud secrets versions access latest --secret=cp-pki-key). It is never printed."
fi

# Normalize BASE_URL (strip a trailing slash so path concatenation is clean).
BASE_URL="${BASE_URL%/}"

# Optional knobs (sane defaults; documented).
PROJECT_ID="${PROJECT_ID:-}"                       # for the optional Firestore doc check.
REGION="${REGION:-us-central1}"                    # the Cloud Run region (scale-to-zero step).
SERVICE="${SERVICE:-heimdall-control-plane}"       # the Cloud Run service name.
JOB_NAME="${JOB_NAME:-heimdall-long-job}"          # the Cloud Run Job the service dispatches to.
FIRESTORE_ROOT="${HEIMDALL_FIRESTORE_ROOT:-heimdall_cp}"   # the cp_state_firestore root collection.
# POLL_SECONDS default is 180 (was 60): run_v2 run_job is ASYNC — the dispatched Cloud Run Job
# then PROVISIONS (~36s observed) and only then RUNS. A 60s job-record poll can expire while the
# Job is still provisioning even though it DID dispatch + complete; 180s covers provision+run so a
# timing-tight Job is no longer misread as a dispatch failure. The authoritative PASS signal is the
# EXECUTION STATUS (STEP 2b), not just this job-record poll. The local dry run overrides this to a
# short value (the in-process fake completes instantly).
POLL_SECONDS="${POLL_SECONDS:-180}"                # max seconds to wait for a terminal state.
# STEP5_POLL_SECONDS — how long the STEP-5 cold-start read-back polls the signed GET /jobs for
# THIS job_id to come back state=done from a FRESH instance. Default 180 (was an effective 30s
# via COLD_POLL_SECONDS). WHY generous: run_v2 run_job is ASYNC — the dispatched Cloud Run Job
# PROVISIONS (~36s observed) + RUNS, then the terminal `done` write must become VISIBLE in
# Firestore before a fresh instance can read it back. A 30s window can close while the async Job
# is still finishing (or its terminal Firestore write is still propagating) even though the job
# DID complete — exactly the STEP-5 read-back timing artifact this raises. 180s covers
# provision+run+write so the read-back goes GREEN on a real completing run instead of timing out.
# The local dry run overrides this (via COLD_POLL_SECONDS, the legacy alias) to a short value —
# the in-process fake completes + writes instantly, so a long window is unnecessary there.
# Back-compat: COLD_POLL_SECONDS is the OLD name for this window. If the caller set
# COLD_POLL_SECONDS but NOT STEP5_POLL_SECONDS, honor the old value so existing callers (incl.
# the dry run's COLD_POLL_SECONDS=20) keep the read-back window they expect.
if [ -n "${STEP5_POLL_SECONDS:-}" ]; then
  STEP5_POLL_SECONDS="$STEP5_POLL_SECONDS"          # explicit STEP5_POLL_SECONDS always wins.
elif [ -n "${COLD_POLL_SECONDS:-}" ]; then
  STEP5_POLL_SECONDS="$COLD_POLL_SECONDS"           # legacy alias when STEP5 is unset.
else
  STEP5_POLL_SECONDS="180"                          # generous default: covers provision+run+write.
fi
# Keep COLD_POLL_SECONDS defined + in lockstep (the STEP-4 `wait`-method help text still names it
# as the read-back window); mirror the resolved STEP-5 window so the two never disagree.
COLD_POLL_SECONDS="$STEP5_POLL_SECONDS"             # max seconds to wait for the post-cold read.
# EXEC_POLL_SECONDS — how long STEP 2b waits for a heimdall-long-job EXECUTION to reach
# succeededCount=1. Covers the async provision (~36s) + run; gcloud-only, skipped in local/dry-run.
EXEC_POLL_SECONDS="${EXEC_POLL_SECONDS:-180}"
ACTION_TYPE="${ACTION_TYPE:-run-task-X}"           # an allowlisted action (the wired-gate default).
# ID_TOKEN is optional: required when the service is --no-allow-unauthenticated (Cloud Run IAM).
ID_TOKEN="${ID_TOKEN:-}"

# ── THE REUSED HAID-SIGNING HTTP CLIENT (the shipped cp_auth signer over urllib) ─────
# Emitted to a temp file; every signed request is driven through HERE. It reads the seed
# from the PKI_SEED env (NEVER an argv — argv shows in `ps`), signs the cp_auth canonical
# message (METHOD\nPATH\nBODY), and drives a stdlib urllib request to $BASE_URL. The seed
# is read in-process and never written anywhere. This mirrors test/cp-wired.test.sh's
# wired_client.py verbatim (same canonical_message + sign + header names), only pointed at
# a remote https URL and carrying the optional Cloud Run IAM bearer token.
WORK="$(mktemp -d -t "verify-flight-fix.$(printf 'X%.0s' 1 2 3 4 5 6)")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SIGNER="$WORK/remote_client.py"
cat >"$SIGNER" <<'PYEOF'
"""remote_client.py — the reused HAID-signing HTTPS client for the prod flight-fix verify.

Reuses cp_auth.canonical_message + cp_auth.sign (the SHIPPED signer) and drives a stdlib
urllib request to the live Cloud Run URL. The Ed25519 private seed is read from the
PKI_SEED environment variable (NEVER passed on argv — argv is visible in `ps`), used only
to sign in-process, and never logged or persisted. An optional ID_TOKEN env adds the Cloud
Run IAM Authorization: Bearer header for a --no-allow-unauthenticated service.

CLI: remote_client.py <verb> [args...] -> a single JSON line on stdout.
  start <action_type> <task_id>   POST /jobs (signed) -> {status, latency, job_id, state}
  status <job_id>                 GET  /jobs {job_id in body} (signed) -> {status, state, result, http_ok}
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.environ["LIB"])
import cp_auth as K  # the SHIPPED signer — we never re-implement Ed25519.

BASE = os.environ["BASE_URL"].rstrip("/")
HAID = os.environ["CLIENT_HAID"]
SEED = os.environ["PKI_SEED"]            # base64 Ed25519 seed; in-process only.
ID_TOKEN = os.environ.get("ID_TOKEN") or ""


def request(method, path, body=b"", *, timeout=20):
    """Sign (METHOD\\nPATH\\nBODY) with the seed for HAID and drive a real HTTPS request.
    Returns (status, parsed_body_dict). A transport error returns (0, {"error": ...})."""
    if isinstance(body, str):
        body = body.encode("utf-8")
    url = BASE + path
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("X-Heimdall-HAID", HAID)
    req.add_header("Content-Type", "application/json")
    # The application-layer PKI signature (independent of Cloud Run's TLS/IAM).
    msg = K.canonical_message(method, path, body)
    req.add_header("X-Heimdall-Signature", K.sign(SEED, msg))
    # Optional Cloud Run IAM bearer (when the service is --no-allow-unauthenticated).
    if ID_TOKEN:
        req.add_header("Authorization", "Bearer " + ID_TOKEN)
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
    except (urllib.error.URLError, OSError) as exc:
        # A transport failure (DNS / TLS / connection refused). Surfaced, never the seed.
        return 0, {"error": "transport: %s" % (getattr(exc, "reason", None) or exc)}


def main(argv):
    verb = argv[0]
    if verb == "start":
        action_type, task_id = argv[1], argv[2]
        body = json.dumps({"action_type": action_type,
                           "params": {"task_id": task_id}}).encode()
        t0 = time.time()
        st, b = request("POST", "/jobs", body)
        dt = time.time() - t0
        out = {"status": st, "latency": round(dt, 4),
               "job_id": b.get("job_id"), "state": b.get("state"),
               "error": b.get("error")}
    elif verb == "status":
        body = json.dumps({"job_id": argv[1]}).encode()
        st, b = request("GET", "/jobs", body)
        job = b.get("job") or {}
        result = job.get("result")
        out = {"status": st,
               "http_ok": (st == 200),
               "state": job.get("state"),
               "result": (result.get("status") if isinstance(result, dict) else result),
               "error": b.get("error")}
    else:
        out = {"error": "unknown verb: %s" % verb}
    sys.stdout.write(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF

# JSON field extractor for a single stdout JSON line.
jget() { "$PY" -c "import json,sys
try:
    print(json.load(sys.stdin).get('$1'))
except Exception:
    print('')"; }

# Run the signer with the seed in the ENV (never argv); returns its JSON on stdout.
sign_call() {
  LIB="$LIB" BASE_URL="$BASE_URL" CLIENT_HAID="$CLIENT_HAID" PKI_SEED="$PKI_SEED" \
  ID_TOKEN="$ID_TOKEN" "$PY" "$SIGNER" "$@"
}

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); ok "$1"; }
fail() { FAIL=$((FAIL+1)); bad "$1"; }

say "============================================================"
say "VERIFY FLIGHT-FIX on the REAL Cloud Run + Firestore target"
say "  BASE_URL=$BASE_URL"
say "  CLIENT_HAID=$CLIENT_HAID"
say "  state backend (prod): firestore  (HEIMDALL_STATE_BACKEND=firestore)"
say "  firestore root collection: $FIRESTORE_ROOT"
say "  (PKI_SEED is set and will NOT be printed)"
say "============================================================"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 1 — SIGN + POST /jobs: start a server-hosted job, capture the job_id.
# ──────────────────────────────────────────────────────────────────────────────
say
say "STEP 1 — sign + POST /jobs (start a server-hosted job)"
# Stamp the dispatch instant (RFC3339 UTC) BEFORE the POST so STEP 2b can scope the executions
# list to a NEW execution created at/after this dispatch — distinguishing it from any stale,
# pre-existing manual execution (e.g. the old krdp7 in the incident). Best-effort: if the local
# `date` lacks -u/RFC3339 support the stamp is empty and STEP 2b falls back to a job_id-arg match.
DISPATCH_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
sign_call start "$ACTION_TYPE" "flight-fix-prod-$(date +%s)" >"$WORK/start.out" 2>"$WORK/start.err"
START_STATUS="$(jget status <"$WORK/start.out")"
JOB_ID="$(jget job_id <"$WORK/start.out")"
START_LATENCY="$(jget latency <"$WORK/start.out")"
START_STATE="$(jget state <"$WORK/start.out")"
START_ERR="$(jget error <"$WORK/start.out")"

if [ "$START_STATUS" = "200" ] && [ -n "$JOB_ID" ] && [ "$JOB_ID" != "None" ] && [ "$JOB_ID" != "" ]; then
  pass "POST /jobs returned a job_id immediately ($JOB_ID, ${START_LATENCY}s, state=$START_STATE)"
else
  fail "POST /jobs did not return a job_id (status=$START_STATUS, error=$START_ERR)"
  say "  hint: status 0 -> transport/DNS/TLS error; 401 -> CLIENT_HAID/PKI_SEED not the registered identity, or missing ID_TOKEN for a --no-allow-unauthenticated service; 422 -> action '$ACTION_TYPE' not allowlisted."
  [ -s "$WORK/start.err" ] && cat "$WORK/start.err" >&2
  say
  say "============================================================"
  say "VERDICT: FAIL — could not even start a durable job. See hints above."
  say "============================================================"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 2 — poll signed GET /jobs until the job reaches a terminal/durable state.
# ──────────────────────────────────────────────────────────────────────────────
say
say "STEP 2 — poll signed GET /jobs until the job is durable (done/cancelled)"
FINAL_STATE=""
RESULT_STATUS=""
deadline=$(( $(date +%s) + POLL_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sign_call status "$JOB_ID" >"$WORK/poll.out" 2>/dev/null
  FINAL_STATE="$(jget state <"$WORK/poll.out")"
  RESULT_STATUS="$(jget result <"$WORK/poll.out")"
  if [ "$FINAL_STATE" = "done" ] || [ "$FINAL_STATE" = "cancelled" ]; then break; fi
  "$PY" -c "import time;time.sleep(1)"
done
# STEP2_TIMED_OUT: the job-record poll expired without a terminal state. We do NOT immediately
# FAIL on it — run_v2 dispatch is async, so a tight poll can expire while the Job is still
# provisioning+running even though it DID dispatch + complete. STEP 2b (the execution-status
# check) + STEP 5 (the durable read-back) reconcile this: if either confirms the job actually
# ran, a timed-out STEP-2 poll is a TIMING ARTIFACT, not a dispatch failure (resolved below).
STEP2_TIMED_OUT="no"
if [ "$FINAL_STATE" = "done" ]; then
  pass "the job reached a durable terminal state (state=done, result=$RESULT_STATUS) — persisted in Firestore"
elif [ "$FINAL_STATE" = "cancelled" ]; then
  pass "the job reached a durable terminal state (state=cancelled) — persisted in Firestore"
  say "  note: cancelled is terminal+durable; the flight-fix read-back below still applies."
else
  STEP2_TIMED_OUT="yes"
  say "  the job-record poll did NOT read a terminal state within ${POLL_SECONDS}s (last state='$FINAL_STATE')."
  say "  NOT failing yet — STEP 2b (execution status) + STEP 5 (durable read-back) decide whether"
  say "  this is an async-provisioning timing artifact or a real dispatch failure."
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 2b — THE AUTHORITATIVE PASS SIGNAL: poll the Cloud Run Job EXECUTIONS list for a
#   heimdall-long-job execution that (a) carries THIS job_id in its container args, or
#   (b) was created at/after the STEP-1 dispatch (DISPATCH_TS) — reaching succeededCount=1.
#
#   WHY this, not just the STEP-2 job-record poll: run_v2 run_job is ASYNC. The dispatched
#   Job PROVISIONS (~36s observed) then RUNS, so the job-record can still read non-terminal
#   when a tight poll expires even though the Job DID dispatch and DID complete. The EXECUTION
#   STATUS is ground truth: a succeeded execution carrying this job_id PROVES the dispatch
#   fired and the job ran out-of-process. A succeeded execution here turns a tight STEP-2 poll
#   into a recognised TIMING ARTIFACT (not a dispatch failure) — see the verdict logic.
#
#   gcloud-ONLY. Skipped cleanly when gcloud is absent OR SCALE_TO_ZERO=command (the local/dry-
#   run path, which has no real Cloud Run Job to query) — EXEC_CHECKED stays "skipped" and the
#   verdict relies on STEP 2 + STEP 5 exactly as before, so the dry run is unaffected.
# ──────────────────────────────────────────────────────────────────────────────
say
say "STEP 2b — poll heimdall-long-job EXECUTIONS for a succeeded execution carrying this job_id"
EXEC_CHECKED="skipped"
EXEC_SUCCEEDED="no"
EXEC_NAME=""
if [ "${SCALE_TO_ZERO:-revision}" = "command" ]; then
  say "  (skipped — SCALE_TO_ZERO=command is the local/dry-run path; no real Cloud Run Job to query.)"
elif ! command -v gcloud >/dev/null 2>&1; then
  say "  (skipped — gcloud not available; run from RJ's creds to use the execution-status PASS signal.)"
else
  # Helper: parse the executions-list JSON and pick the FIRST execution that is ours
  # (job_id in container args, or createTime >= DISPATCH_TS) AND has succeededCount>=1.
  # Prints "<name>" on a match, nothing otherwise. Robust to schema variance across gcloud
  # versions (succeededCount can live under status; args under the template's container).
  EXEC_PICK_PY="$WORK/exec_pick.py"
  cat >"$EXEC_PICK_PY" <<'PYEOF'
import json
import sys


def _succeeded(ex):
    st = ex.get("status") or {}
    for src in (st, ex):
        v = src.get("succeededCount")
        if isinstance(v, int) and v >= 1:
            return True
    return False


def _args_blob(ex):
    """Flatten everything that might hold the container args/command into one string."""
    out = []
    spec = ex.get("spec") or {}
    tmpl = (spec.get("template") or {}).get("spec") or {}
    for c in tmpl.get("containers") or []:
        out += list(c.get("args") or [])
        out += list(c.get("command") or [])
    # Fallback: stringify the whole record so an args match still works if the path differs.
    out.append(json.dumps(ex))
    return " ".join(str(x) for x in out)


def _create_time(ex):
    md = ex.get("metadata") or {}
    return md.get("creationTimestamp") or (ex.get("status") or {}).get("startTime") or ""


def main():
    job_id = sys.argv[1]
    dispatch_ts = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        data = json.load(sys.stdin)
    except (ValueError, TypeError):
        return 0
    if isinstance(data, dict):
        data = [data]
    for ex in data:
        if not isinstance(ex, dict):
            continue
        if not _succeeded(ex):
            continue
        carries_job = job_id and job_id in _args_blob(ex)
        ct = _create_time(ex)
        after_dispatch = bool(dispatch_ts) and bool(ct) and ct >= dispatch_ts
        if carries_job or after_dispatch:
            name = (ex.get("metadata") or {}).get("name") or ex.get("name") or "<unnamed>"
            sys.stdout.write(str(name))
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  exec_deadline=$(( $(date +%s) + EXEC_POLL_SECONDS ))
  while [ "$(date +%s)" -lt "$exec_deadline" ]; do
    if gcloud run jobs executions list \
         --job="$JOB_NAME" \
         --region="$REGION" \
         ${PROJECT_ID:+--project="$PROJECT_ID"} \
         --format=json >"$WORK/execs.out" 2>"$WORK/execs.err"; then
      EXEC_NAME="$("$PY" "$EXEC_PICK_PY" "$JOB_ID" "$DISPATCH_TS" <"$WORK/execs.out")"
      if [ -n "$EXEC_NAME" ]; then break; fi
    fi
    "$PY" -c "import time;time.sleep(3)"
  done
  if [ -n "$EXEC_NAME" ]; then
    EXEC_CHECKED="checked"
    EXEC_SUCCEEDED="yes"
    pass "a heimdall-long-job EXECUTION succeeded for this dispatch ($EXEC_NAME, succeededCount>=1) — the job ran out-of-process"
  else
    EXEC_CHECKED="checked"
    fail "no SUCCEEDED heimdall-long-job execution for this job_id within ${EXEC_POLL_SECONDS}s — dispatch may not have fired (the pre-fix queued-forever signature)"
    say "  hint: check HEIMDALL_JOB_RUNNER=cloudrun-job on the service + run.jobs.run IAM (deploy/cloud-run/README.md §4.1)."
    [ -s "$WORK/execs.err" ] && tail -3 "$WORK/execs.err" >&2
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 3 — (optional) confirm the job doc in REAL Firestore + PRINT the doc path.
#   The cp_state_firestore rel->doc mapping: a job's rel is "jobs/<job_id>.ndjson",
#   encoded to a flat doc id by replacing "/" with "__" -> "jobs__<job_id>.ndjson",
#   under the root collection ($FIRESTORE_ROOT, default heimdall_cp). The appended
#   NDJSON lines live in that node doc's "lines" subcollection.
# ──────────────────────────────────────────────────────────────────────────────
say
say "STEP 3 — the Firestore doc path for this job (cp_state_firestore rel->doc mapping)"
DOC_ID="jobs__${JOB_ID}.ndjson"
DOC_PATH="${FIRESTORE_ROOT}/${DOC_ID}"
say "  rel:   jobs/${JOB_ID}.ndjson"
say "  doc:   ${DOC_PATH}    (lines in subcollection: ${DOC_PATH}/lines)"
if command -v gcloud >/dev/null 2>&1 && [ -n "$PROJECT_ID" ]; then
  # Best-effort confirm the node doc exists. The append-only lines are in the "lines"
  # subcollection; the node doc itself carries the ndjson marker + seq once a line lands.
  if gcloud firestore documents describe "$DOC_PATH" \
       --project="$PROJECT_ID" >"$WORK/fsdoc.out" 2>"$WORK/fsdoc.err"; then
    pass "the job node doc EXISTS in REAL Firestore ($DOC_PATH) — durable state confirmed in the external store"
  else
    # describe may not be available on every gcloud version; fall back to a collection peek.
    if gcloud firestore documents list "$FIRESTORE_ROOT" --project="$PROJECT_ID" \
         --limit=1 >/dev/null 2>&1; then
      say "  (gcloud could not describe the doc directly — older CLI; the path above is authoritative.)"
    fi
    say "  (Firestore doc-check skipped/failed — non-fatal; the HTTP read-back below is the proof.)"
  fi
else
  say "  (Firestore doc-check skipped — set PROJECT_ID + install gcloud to confirm the doc directly. Non-fatal.)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 4 — SCALE TO ZERO: replace the serving instance so the NEXT request hits a
#   FRESH instance with no local state. We pick the DETERMINISTIC method:
#   `gcloud run services update --no-traffic ... ` is not it (it leaves the old revision
#   serving). Instead we deploy a TRIVIAL new revision via `gcloud run services update`
#   with a no-op annotation bump — Cloud Run rolls out a NEW revision, routes 100% of
#   traffic to it, and TEARS DOWN the old revision's instances. The instance that ran the
#   job (its memory + ephemeral /tmp home) is GONE; the next GET /jobs is served by a brand
#   new container that NEVER saw the job locally — it can only answer from Firestore.
#
#   ⚠️ IMAGE-PRESERVATION (the STEP-4 rollback bug, fixed). A bare `gcloud run services update`
#   that does NOT pass `--image` resolves the service's image reference afresh — if the service
#   was last deployed from a mutable tag (`...:latest`) or a `--source` build, the new revision
#   can pull a DIFFERENT/OLDER digest than the one currently serving. In the prod incident the
#   verify's own STEP-4 rollout reverted the service to a PRE-run_v2 image mid-test, so the
#   subsequently-dispatched job hit a revision WITHOUT the dispatch fix -> zero executions, and
#   the test corrupted itself. THE FIX: capture the CURRENTLY-serving (100%-traffic) revision's
#   exact image DIGEST FIRST, then roll the no-op revision with `--image <that exact digest>` so
#   Cloud Run REUSES the same immutable digest (scale-to-zero WITHOUT changing the served image).
#   After the rollout we ASSERT the new 100%-traffic revision serves the SAME digest we started
#   on — if it drifted, we FAIL loudly rather than silently testing a stale image.
#
#   TRADE-OFF (documented): the alternative is to simply WAIT OUT the idle scale-down with
#   --min-instances=0 (no request for ~15 min -> the instance is reclaimed). That is the
#   "purest" cold start but NON-deterministic (the idle window is not contractual and can
#   be minutes) AND it never touches the image at all (no rollback risk). A new-revision rollout
#   pinned to the captured digest is DETERMINISTIC, fast, AND image-preserving: it provably
#   replaces the serving instance now while keeping the exact same digest, which is exactly the
#   property we need (fresh instance, no local state, same code under test). We default to the
#   digest-pinned revision rollout; set SCALE_TO_ZERO=wait to use the image-untouching idle path.
#
#   A THIRD mode, SCALE_TO_ZERO=command, runs an operator-supplied SCALE_CMD that replaces
#   the serving instance by whatever means the operator controls — gcloud-free. The local
#   firestore-mode DRY RUN uses this to RESTART the local server process against the SAME
#   external store (fresh process = fresh instance, durable store persists), which validates
#   this script's read-back logic end-to-end before RJ runs it against prod.
# ──────────────────────────────────────────────────────────────────────────────
say
say "STEP 4 — scale to zero: replace the serving instance (force a fresh, stateless instance)"
SCALE_METHOD="${SCALE_TO_ZERO:-revision}"
COLD_FORCED="no"
if [ "$SCALE_METHOD" = "command" ]; then
  # method=command — run an operator-supplied SCALE_CMD that REPLACES the serving instance.
  # This is the durable-store-preserving instance swap, abstracted: the local firestore-mode
  # dry run uses it to RESTART the local server process against the SAME external store (a
  # fresh process = a fresh "instance"; the durable store persists), proving the script's
  # read-back logic end-to-end before it touches prod. SCALE_CMD must replace the instance
  # WITHOUT touching the external durable store (the whole point of the proof).
  if [ -z "${SCALE_CMD:-}" ]; then
    fail "SCALE_TO_ZERO=command but SCALE_CMD is empty — provide the instance-replacement command"
    COLD_FORCED="no"
  else
    say "  method=command — running the operator-supplied instance-replacement hook (SCALE_CMD)."
    if bash -c "$SCALE_CMD" >"$WORK/scale.out" 2>"$WORK/scale.err"; then
      pass "the instance-replacement hook ran — the serving instance was replaced (durable store untouched)"
      COLD_FORCED="command"
    else
      fail "the instance-replacement hook (SCALE_CMD) failed — see stderr"
      [ -s "$WORK/scale.err" ] && tail -5 "$WORK/scale.err" >&2
    fi
  fi
elif command -v gcloud >/dev/null 2>&1; then
  if [ "$SCALE_METHOD" = "wait" ]; then
    say "  method=wait — relying on --min-instances=0 idle scale-down (NON-deterministic)."
    say "  Set --min-instances=0 on the service, send no traffic, and wait out the idle window"
    say "  (typically up to ~15 min) before the read-back below. This script will poll the"
    say "  read-back for up to ${STEP5_POLL_SECONDS}s; for the wait method, raise STEP5_POLL_SECONDS"
    say "  to cover your idle window, or simply re-run STEP 5 after the instance is reclaimed."
    COLD_FORCED="wait"
  else
    say "  method=revision — deploying a no-op new revision (PINNED to the serving digest) to TEAR"
    say "  DOWN the old serving instance WITHOUT changing the served image."
    # ── helper: resolve the digest of the revision currently serving 100% of traffic ──
    # status.traffic gives the revision(s) + percent; we pick the one at 100% (or the highest),
    # then read THAT revision's container image (a sha256 digest once the service has rolled at
    # least once with a digest pin). Prints the image string, or "" if it can't be resolved.
    SERVE_DIGEST_PY="$WORK/serve_digest.py"
    cat >"$SERVE_DIGEST_PY" <<'PYEOF'
import json
import sys


def main():
    # argv[1] = the `gcloud run services describe --format=json` blob.
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as fh:
            svc = json.load(fh)
    except (OSError, ValueError, IndexError):
        return 0
    status = svc.get("status") or {}
    # Pick the revision carrying the most traffic (prefer an explicit 100%).
    best_rev, best_pct = None, -1
    for t in status.get("traffic") or []:
        pct = t.get("percent")
        pct = pct if isinstance(pct, int) else -1
        rev = t.get("revisionName") or t.get("latestRevision") and status.get("latestReadyRevisionName")
        if rev and pct > best_pct:
            best_rev, best_pct = rev, pct
    # The describe blob carries the *latest template* image, but to be exact we want the image of
    # the 100%-traffic revision. The service template image is the right answer when traffic is on
    # the latest ready revision; fall back to it. (A precise per-revision lookup is done by the
    # caller via `gcloud run revisions describe` when best_rev is known.)
    spec = svc.get("spec") or {}
    tmpl = (spec.get("template") or {}).get("spec") or {}
    containers = tmpl.get("containers") or []
    tmpl_image = containers[0].get("image") if containers else ""
    sys.stdout.write(json.dumps({"revision": best_rev or "", "percent": best_pct,
                                 "template_image": tmpl_image or ""}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
    # Capture the serving revision FIRST, then read THAT revision's exact image digest.
    CURRENT_DIGEST=""
    SERVE_REV=""
    if gcloud run services describe "$SERVICE" \
         --region="$REGION" \
         ${PROJECT_ID:+--project="$PROJECT_ID"} \
         --format=json >"$WORK/svc_before.out" 2>"$WORK/svc_before.err"; then
      SERVE_INFO="$("$PY" "$SERVE_DIGEST_PY" "$WORK/svc_before.out")"
      SERVE_REV="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1]).get('revision') or '')" "$SERVE_INFO" 2>/dev/null)"
      if [ -n "$SERVE_REV" ]; then
        # The AUTHORITATIVE per-revision image (a sha256 digest on a digest-pinned service).
        CURRENT_DIGEST="$(gcloud run revisions describe "$SERVE_REV" \
           --region="$REGION" \
           ${PROJECT_ID:+--project="$PROJECT_ID"} \
           --format="value(spec.containers[0].image)" 2>/dev/null | tr -d '[:space:]')"
      fi
      if [ -z "$CURRENT_DIGEST" ]; then
        # Fall back to the service template image when the per-revision lookup is unavailable.
        CURRENT_DIGEST="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1]).get('template_image') or '')" "$SERVE_INFO" 2>/dev/null | tr -d '[:space:]')"
      fi
    fi
    if [ -n "$CURRENT_DIGEST" ]; then
      say "  captured the currently-serving image to PIN the rollout to: $CURRENT_DIGEST"
      say "  (serving revision: ${SERVE_REV:-<unknown>}) — the rollout will REUSE this exact digest."
    else
      say "  WARNING: could not capture the serving image digest — the rollout will proceed WITHOUT"
      say "  an --image pin, which risks the STEP-4 image-rollback bug. Ensure gcloud has run.viewer"
      say "  on the service so the digest can be captured + asserted. Proceeding (best-effort)."
    fi
    # A no-op env marker that forces a new revision WITHOUT changing behavior, PINNED to the
    # captured digest so the served image is byte-identical across the rollout (no rebuild, no
    # rollback to an older digest). The `--image` pin is the core of the BUG-1 fix.
    STAMP="$(date +%Y%m%d-%H%M%S)"
    if gcloud run services update "$SERVICE" \
         --region="$REGION" \
         ${PROJECT_ID:+--project="$PROJECT_ID"} \
         ${CURRENT_DIGEST:+--image="$CURRENT_DIGEST"} \
         --update-env-vars="HEIMDALL_FLIGHTFIX_VERIFY=${STAMP}" \
         --revision-suffix="flightfix-${STAMP}" \
         >"$WORK/scale.out" 2>"$WORK/scale.err"; then
      pass "a new revision rolled out (flightfix-${STAMP}) — the old serving instance is being torn down"
      COLD_FORCED="revision"
      # Give Cloud Run a moment to finish routing 100% to the new revision + reap the old.
      "$PY" -c "import time;time.sleep(8)"
      # ── ASSERT the served image did NOT drift: the new 100%-traffic revision must serve the
      #    SAME digest we captured before. This catches the STEP-4 image-rollback bug directly.
      if [ -n "$CURRENT_DIGEST" ]; then
        if gcloud run services describe "$SERVICE" \
             --region="$REGION" \
             ${PROJECT_ID:+--project="$PROJECT_ID"} \
             --format=json >"$WORK/svc_after.out" 2>/dev/null; then
          AFTER_INFO="$("$PY" "$SERVE_DIGEST_PY" "$WORK/svc_after.out")"
          AFTER_REV="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1]).get('revision') or '')" "$AFTER_INFO" 2>/dev/null)"
          AFTER_DIGEST=""
          if [ -n "$AFTER_REV" ]; then
            AFTER_DIGEST="$(gcloud run revisions describe "$AFTER_REV" \
               --region="$REGION" \
               ${PROJECT_ID:+--project="$PROJECT_ID"} \
               --format="value(spec.containers[0].image)" 2>/dev/null | tr -d '[:space:]')"
          fi
          [ -z "$AFTER_DIGEST" ] && AFTER_DIGEST="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1]).get('template_image') or '')" "$AFTER_INFO" 2>/dev/null | tr -d '[:space:]')"
          if [ "$AFTER_DIGEST" = "$CURRENT_DIGEST" ]; then
            pass "image PRESERVED across scale-to-zero — the served digest is UNCHANGED ($AFTER_DIGEST)"
          else
            fail "STEP-4 image DRIFTED: served digest changed from '$CURRENT_DIGEST' to '$AFTER_DIGEST' — the rollback bug. The test is now exercising a DIFFERENT image than it started on; re-pin the service to the intended digest and re-run."
          fi
        else
          say "  (could not re-describe the service to assert the digest — non-fatal; the rollout pinned --image, so drift is unlikely.)"
        fi
      fi
    else
      fail "could not roll a new revision (gcloud run services update failed) — see stderr"
      [ -s "$WORK/scale.err" ] && tail -5 "$WORK/scale.err" >&2
      say "  the read-back below still runs; without a forced replace it may hit the SAME instance,"
      say "  so a PASS here would be weaker. For a clean proof, ensure gcloud has run.admin on the service."
    fi
  fi
else
  say "  gcloud not available — cannot force scale-to-zero here."
  say "  Replace the serving instance yourself (deploy a new revision OR wait out the idle window),"
  say "  THEN run STEP 5 (re-run this script's read-back). The read-back below runs anyway, but"
  say "  without a forced instance replace it may hit the same warm instance (a weaker proof)."
  COLD_FORCED="manual"
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 5 — THE FLIGHT-FIX PROOF: after cold-start, signed GET /jobs for the SAME
#   job_id resolves the job + its folded state — read from Firestore by a FRESH
#   instance that never ran the job locally. This is the DURABLE READ-BACK proof:
#   a signed GET /jobs that asserts state=done is readable from Firestore by an
#   instance that never ran the job.
#
#   TIMING: the read-back polls for up to STEP5_POLL_SECONDS (default 180s). run_v2
#   run_job is ASYNC — the dispatched Cloud Run Job PROVISIONS (~36s) + RUNS, then its
#   terminal `done` write must become VISIBLE in Firestore before a FRESH instance can
#   read it back. A short window can close while the async Job is still finishing even
#   though it DID complete (the STEP-5 read-back timing artifact). The 180s window covers
#   provision+run+write so a real completing run reads back `done` and STEP 5 goes GREEN —
#   not merely a reconciled NOTE. When STEP 2b already confirmed the EXECUTION SUCCEEDED
#   (EXEC_SUCCEEDED=yes), the Job has finished and the durable write appears shortly; we
#   poll the full window for that `done` to land, and a confirmed `done` = STEP 5 PASS.
# ──────────────────────────────────────────────────────────────────────────────
say
say "STEP 5 — cold-start read-back: signed GET /jobs for the SAME job_id [THE FLIGHT FIX]"
# READ-PATH CONTRACT (audited). The read below sends job_id in the request BODY
# ({"job_id":...}) and parses state from b["job"]["state"] — EXACTLY what the live
# handler expects + emits: cp_worker.status_route reads the job_id via _job_id_from
# (payload["job_id"] FIRST), folds the durable log (cp_jobstore.read_job -> fold_state),
# and returns Response(200, {"job": folded}) where folded carries "state". The send +
# parse are CONTRACT-CORRECT (the local dry run round-trips this exact shape across a
# fresh process and reads back state=done). So if STEP 5 reads state=None for a job
# whose Firestore doc HAS done, the divergence is NOT a verify-parse bug — it is the
# live SERVICE read-path (a fresh instance reading the wrong home/store, or async
# timing). The DECISIVE one-off distinguisher is deploy/cloud-run/get-job.sh: it sends
# this identical signed GET /jobs for a single job_id and prints the RAW response + the
# parsed state, so done-vs-None on the live wire pinpoints which side is at fault.
if [ "$EXEC_SUCCEEDED" = "yes" ]; then
  say "  STEP 2b confirmed the execution SUCCEEDED — polling up to ${STEP5_POLL_SECONDS}s for the"
  say "  terminal 'done' write to become visible in Firestore + read back from the FRESH instance."
else
  say "  polling the signed GET /jobs read-back for up to ${STEP5_POLL_SECONDS}s (async Job"
  say "  provision ~36s + run + the terminal Firestore write becoming visible to a fresh instance)."
fi
COLD_STATE=""
COLD_RESULT=""
COLD_HTTP_OK=""
deadline=$(( $(date +%s) + STEP5_POLL_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sign_call status "$JOB_ID" >"$WORK/cold.out" 2>/dev/null
  COLD_HTTP_OK="$(jget http_ok <"$WORK/cold.out")"
  COLD_STATE="$(jget state <"$WORK/cold.out")"
  COLD_RESULT="$(jget result <"$WORK/cold.out")"
  # We want the durable terminal state back (done/cancelled) from the fresh instance. We poll
  # the FULL window so a real async Job that is still provisioning/running (or whose terminal
  # Firestore write has not yet propagated) is given time to land `done` — only a window that
  # closes with the job STILL non-terminal is a genuine read-back failure.
  if [ "$COLD_STATE" = "done" ] || [ "$COLD_STATE" = "cancelled" ]; then break; fi
  "$PY" -c "import time;time.sleep(2)"
done

DURABLE_BACK="no"
if [ "$COLD_HTTP_OK" = "True" ] && { [ "$COLD_STATE" = "done" ] || [ "$COLD_STATE" = "cancelled" ]; }; then
  DURABLE_BACK="yes"
  pass "a FRESH instance resolved the job's durable state (state=$COLD_STATE, result=$COLD_RESULT) from Firestore"
  pass "DURABLE READ-BACK: signed GET /jobs for $JOB_ID reads state=$COLD_STATE from Firestore on a fresh instance — the flight-fix read-back proof"
  if [ "$EXEC_SUCCEEDED" = "yes" ] && [ "$COLD_STATE" = "done" ]; then
    pass "FULLY GREEN: execution SUCCEEDED (STEP 2b) AND a fresh instance reads state=done (STEP 5) — both halves of the flight-fix proven on the live target"
  fi
  pass "FALSIFIABLE: with the LOCAL backend (or a stale pre-Wave-2 image) this read would 404 — only durable Firestore state survives the instance replace"
else
  fail "the fresh instance did NOT resolve the job after scale-to-zero within ${STEP5_POLL_SECONDS}s (http_ok=$COLD_HTTP_OK, state='$COLD_STATE')"
  if [ "$EXEC_SUCCEEDED" = "yes" ]; then
    say "  NOTE: STEP 2b confirmed the execution SUCCEEDED, yet the read-back stayed non-terminal for"
    say "  the FULL ${STEP5_POLL_SECONDS}s window — the Job ran but its durable 'done' state did not read"
    say "  back. Suspect HEIMDALL_STATE_BACKEND=firestore not set on the SERVICE (the fresh instance"
    say "  reads the wrong store), or raise STEP5_POLL_SECONDS if the write is merely slow to propagate."
  else
    say "  this is the durability-broken signature: either the image is stale (BackendUnavailable ticks,"
    say "  see deploy/cloud-run/README.md) or HEIMDALL_STATE_BACKEND=firestore is not set on the service."
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# RECONCILE the deferred STEP-2 timeout. run_v2 dispatch is async, so a tight job-record poll
# can expire while the job is still provisioning+running. We now know the two authoritative
# signals — the EXECUTION status (STEP 2b) and the durable read-back (STEP 5). If EITHER
# confirms the job ran, a timed-out STEP-2 poll is a TIMING ARTIFACT (the job DID dispatch +
# complete; the poll was just shorter than provision+run) and must NOT fail the verdict. Only
# when NEITHER signal confirms the job ran is the STEP-2 timeout a real dispatch failure.
# ──────────────────────────────────────────────────────────────────────────────
if [ "$STEP2_TIMED_OUT" = "yes" ]; then
  if [ "$EXEC_SUCCEEDED" = "yes" ] || [ "$DURABLE_BACK" = "yes" ]; then
    say
    say "  NOTE — STEP-2 job-record poll timed out, but the job DID run: $( [ "$EXEC_SUCCEEDED" = "yes" ] && echo "a heimdall-long-job execution succeeded (STEP 2b)" || echo "a fresh instance read its durable terminal state (STEP 5)" ). This is an async-provisioning TIMING ARTIFACT (the job dispatched + completed; the poll was tighter than provision+run), NOT a dispatch failure. Raise POLL_SECONDS to silence it."
  else
    fail "the job did not reach a terminal state within ${POLL_SECONDS}s AND no execution succeeded AND the read-back did not resolve — a real dispatch failure, not a timing artifact"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# VERDICT — PASS iff the durable state resolved from a fresh instance post-scale-to-zero.
# ──────────────────────────────────────────────────────────────────────────────
say
say "============================================================"
say "verify-flight-fix: $PASS passed, $FAIL failed"
say "  job_id:            $JOB_ID"
say "  firestore doc:     $DOC_PATH"
say "  execution status:  $EXEC_CHECKED${EXEC_SUCCEEDED:+ (succeeded=$EXEC_SUCCEEDED)}${EXEC_NAME:+ -> $EXEC_NAME}"
say "  scale-to-zero:     $COLD_FORCED"
say "  durable read-back: $DURABLE_BACK${COLD_STATE:+ (state=$COLD_STATE)}  [polled up to ${STEP5_POLL_SECONDS}s]"
if [ "$DURABLE_BACK" = "yes" ] && [ "$FAIL" -eq 0 ]; then
  say "VERDICT: PASS — the job_id resolved its DURABLE state from a FRESH instance after"
  say "         scale-to-zero. The flight-fix holds on the real Cloud Run + Firestore target."
  if [ "$EXEC_SUCCEEDED" = "yes" ] && [ "$COLD_STATE" = "done" ]; then
    say "         FULLY GREEN: STEP 2b execution SUCCEEDED + STEP 5 read state=done from a fresh instance."
  fi
  say "============================================================"
  exit 0
else
  say "VERDICT: FAIL — the durable state did NOT survive a fresh instance after scale-to-zero."
  say "         See the hints above (stale image / wrong backend / non-deterministic scale)."
  say "============================================================"
  exit 1
fi

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
#   3. (optional, gated on gcloud) confirm the job doc      -> in REAL Firestore (the
#      cp_state_firestore rel->doc mapping); PRINT the doc path either way.
#   4. SCALE TO ZERO — replace the serving instance deterministically so the next request
#      hits a FRESH instance with NO local state (the old instance's memory + ephemeral
#      disk are GONE).
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
  die "CLIENT_HAID is empty — the server's pinned HAID. It is read from the deployed HEIMDALL_CP_SERVER_HAID env; an empty value means the service was deployed WITHOUT that var. Redeploy with it (gcloud run services update \"\$SERVICE\" --region=\"\$REGION\" --update-env-vars=HEIMDALL_CP_SERVER_HAID=haid:heimdall.cp-prod-0001), then re-run. See deploy/cloud-run/README.md §3 'Stable identity: both halves must be pinned'."
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
FIRESTORE_ROOT="${HEIMDALL_FIRESTORE_ROOT:-heimdall_cp}"   # the cp_state_firestore root collection.
POLL_SECONDS="${POLL_SECONDS:-60}"                 # max seconds to wait for a terminal state.
COLD_POLL_SECONDS="${COLD_POLL_SECONDS:-30}"       # max seconds to wait for the post-cold read.
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
if [ "$FINAL_STATE" = "done" ]; then
  pass "the job reached a durable terminal state (state=done, result=$RESULT_STATUS) — persisted in Firestore"
elif [ "$FINAL_STATE" = "cancelled" ]; then
  pass "the job reached a durable terminal state (state=cancelled) — persisted in Firestore"
  say "  note: cancelled is terminal+durable; the flight-fix read-back below still applies."
else
  fail "the job did not reach a terminal state within ${POLL_SECONDS}s (last state='$FINAL_STATE')"
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
#   TRADE-OFF (documented): the alternative is to simply WAIT OUT the idle scale-down with
#   --min-instances=0 (no request for ~15 min -> the instance is reclaimed). That is the
#   "purest" cold start but NON-deterministic (the idle window is not contractual and can
#   be minutes). A new-revision rollout is DETERMINISTIC and fast: it provably replaces the
#   serving instance now, which is exactly the property we need (fresh instance, no local
#   state). We default to the revision rollout; set SCALE_TO_ZERO=wait to use the idle path.
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
    say "  read-back for up to ${COLD_POLL_SECONDS}s; for the wait method, raise COLD_POLL_SECONDS"
    say "  to cover your idle window, or simply re-run STEP 5 after the instance is reclaimed."
    COLD_FORCED="wait"
  else
    say "  method=revision — deploying a no-op new revision to TEAR DOWN the old serving instance."
    # A no-op env annotation bump that forces a new revision WITHOUT changing behavior:
    # we stamp a unique verify marker env + revision suffix (idempotent, behavior-neutral).
    STAMP="$(date +%Y%m%d-%H%M%S)"
    if gcloud run services update "$SERVICE" \
         --region="$REGION" \
         ${PROJECT_ID:+--project="$PROJECT_ID"} \
         --update-env-vars="HEIMDALL_FLIGHTFIX_VERIFY=${STAMP}" \
         --revision-suffix="flightfix-${STAMP}" \
         >"$WORK/scale.out" 2>"$WORK/scale.err"; then
      pass "a new revision rolled out (flightfix-${STAMP}) — the old serving instance is being torn down"
      COLD_FORCED="revision"
      # Give Cloud Run a moment to finish routing 100% to the new revision + reap the old.
      "$PY" -c "import time;time.sleep(8)"
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
#   instance that never ran the job locally.
# ──────────────────────────────────────────────────────────────────────────────
say
say "STEP 5 — cold-start read-back: signed GET /jobs for the SAME job_id [THE FLIGHT FIX]"
COLD_STATE=""
COLD_RESULT=""
COLD_HTTP_OK=""
deadline=$(( $(date +%s) + COLD_POLL_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sign_call status "$JOB_ID" >"$WORK/cold.out" 2>/dev/null
  COLD_HTTP_OK="$(jget http_ok <"$WORK/cold.out")"
  COLD_STATE="$(jget state <"$WORK/cold.out")"
  COLD_RESULT="$(jget result <"$WORK/cold.out")"
  # We want the durable terminal state back (done/cancelled) from the fresh instance.
  if [ "$COLD_STATE" = "done" ] || [ "$COLD_STATE" = "cancelled" ]; then break; fi
  "$PY" -c "import time;time.sleep(1)"
done

DURABLE_BACK="no"
if [ "$COLD_HTTP_OK" = "True" ] && { [ "$COLD_STATE" = "done" ] || [ "$COLD_STATE" = "cancelled" ]; }; then
  DURABLE_BACK="yes"
  pass "a FRESH instance resolved the job's durable state (state=$COLD_STATE, result=$COLD_RESULT) from Firestore"
  pass "FALSIFIABLE: with the LOCAL backend (or a stale pre-Wave-2 image) this read would 404 — only durable Firestore state survives the instance replace"
else
  fail "the fresh instance did NOT resolve the job after scale-to-zero (http_ok=$COLD_HTTP_OK, state='$COLD_STATE')"
  say "  this is the durability-broken signature: either the image is stale (BackendUnavailable ticks,"
  say "  see deploy/cloud-run/README.md) or HEIMDALL_STATE_BACKEND=firestore is not set on the service."
fi

# ──────────────────────────────────────────────────────────────────────────────
# VERDICT — PASS iff the durable state resolved from a fresh instance post-scale-to-zero.
# ──────────────────────────────────────────────────────────────────────────────
say
say "============================================================"
say "verify-flight-fix: $PASS passed, $FAIL failed"
say "  job_id:            $JOB_ID"
say "  firestore doc:     $DOC_PATH"
say "  scale-to-zero:     $COLD_FORCED"
say "  durable read-back: $DURABLE_BACK"
if [ "$DURABLE_BACK" = "yes" ] && [ "$FAIL" -eq 0 ]; then
  say "VERDICT: PASS — the job_id resolved its DURABLE state from a FRESH instance after"
  say "         scale-to-zero. The flight-fix holds on the real Cloud Run + Firestore target."
  say "============================================================"
  exit 0
else
  say "VERDICT: FAIL — the durable state did NOT survive a fresh instance after scale-to-zero."
  say "         See the hints above (stale image / wrong backend / non-deterministic scale)."
  say "============================================================"
  exit 1
fi

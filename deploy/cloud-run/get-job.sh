#!/usr/bin/env bash
# get-job.sh — THE DECISIVE ONE-OFF PROBE: send the SAME signed GET /jobs that
# verify-flight-fix.sh STEP 5 sends, for ONE job_id, against the LIVE service, and
# print BOTH the RAW HTTP response and the PARSED state.
#
# WHY THIS EXISTS. verify-flight-fix.sh STEP 5 read state=None for a job whose
# Firestore doc HAS state=done (confirmed by bin/heimdall-cp-inspect reading the doc
# directly). Two — and only two — explanations:
#   (a) the VERIFY mis-sends / mis-parses the read (a verify-side bug), OR
#   (b) the live SERVICE's GET /jobs read-path returns None for a job whose durable
#       record says done (a service-side bug, the cp_worker/jobstore read path).
# This probe is the distinguisher. It reuses the EXACT signer + request shape the
# verify uses (cp_auth.canonical_message + cp_auth.sign; job_id in the request BODY;
# the same X-Heimdall-HAID / X-Heimdall-Signature headers; the optional Cloud Run IAM
# bearer), so its result is what the verify's STEP-5 read sees on the wire:
#
#   * RAW response shows {"job": {... "state":"done" ...}}  -> the SERVICE returns done.
#     Then any None the verify printed was a VERIFY-SIDE parse artifact — but the verify
#     parse reads b["job"]["state"], which is this exact shape, so a done here means the
#     verify reads done too (the dry run proves that round-trip). i.e. service is HEALTHY.
#   * RAW response shows {"job": {... "state":null ...}} or HTTP 404 {"error":"no_such_job"}
#     -> the SERVICE itself cannot resolve done for this job_id from a fresh instance:
#     the read-path bug (other agent's scope — cp_worker.status_route / cp_jobstore
#     read_job/fold_state reading the wrong home/store), NOT a verify-parse bug.
#
# THIS SCRIPT TALKS ONLY HTTP. It contains NO secret literal — the PKI seed arrives via
# the PKI_SEED env (sourced from Secret Manager by the operator) and is NEVER printed,
# logged, or echoed. The signing path REUSES the shipped cp_auth signer (bin/lib/cp_auth.py).
#
# ── HOW RJ RUNS IT (live target, for job-d8884) ──────────────────────────────────────
#   export BASE_URL="$(gcloud run services describe heimdall-control-plane \
#                        --region=us-central1 --format='value(status.url)')"
#   export CLIENT_HAID="$(gcloud run services describe heimdall-control-plane \
#                          --region=us-central1 \
#                          --format='value(spec.template.spec.containers[0].env)' \
#                          | tr ',' '\n' | grep HEIMDALL_CP_SERVER_HAID | cut -d= -f2)"
#   export PKI_SEED="$(gcloud secrets versions access latest --secret=cp-pki-key)"
#   export ID_TOKEN="$(gcloud auth print-identity-token)"   # --no-allow-unauthenticated
#   bash deploy/cloud-run/get-job.sh job-d8884
#
# CLIENT_HAID + PKI_SEED are the server's OWN registered identity (the deploy injects the
# SAME cp-pki-key seed as HEIMDALL_CP_PKI_KEY; boot() registers server_haid -> pubkey(seed)).
# Signing as that HAID with that seed verifies — see verify-flight-fix.sh + README §7.

set -uo pipefail

# ── locate the shipped signer (cp_auth) relative to THIS script ──────────────────────
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/../.." && pwd)"   # deploy/cloud-run/ -> repo root is two up.
LIB="$REPO/bin/lib"                     # bin/lib holds cp_auth.py (the real signer).

PY="$(command -v python3 || command -v python || true)"

die() { printf '\033[31mFATAL\033[0m %s\n' "$1" >&2; exit 2; }

# ── the target job_id: argv[1] or $JOB_ID ────────────────────────────────────────────
PROBE_JOB_ID="${1:-${JOB_ID:-}}"

# ── preconditions (fail loud, never leak the seed) ───────────────────────────────────
[ -n "$PY" ]             || die "python3 not found (needed for the cp_auth signer)."
[ -f "$LIB/cp_auth.py" ] || die "cp_auth signer not found at $LIB/cp_auth.py (run from the repo checkout)."
[ -n "$PROBE_JOB_ID" ]   || die "no job_id — pass it as the first arg (e.g. bash deploy/cloud-run/get-job.sh job-d8884) or set JOB_ID."
: "${BASE_URL:?BASE_URL is not set — the Cloud Run https URL (e.g. https://heimdall-control-plane-<hash>.run.app).}"
if [ -z "${CLIENT_HAID:-}" ] || [ -z "$(printf '%s' "${CLIENT_HAID:-}" | tr -d '[:space:]')" ]; then
  die "CLIENT_HAID is empty — the server's pinned HAID (read from the deployed HEIMDALL_CP_SERVER_HAID env). Use the SAME literal the service is deployed with. See deploy/cloud-run/README.md §3 'Stable identity'."
fi
CLIENT_HAID="$(printf '%s' "$CLIENT_HAID" | tr -d '[:space:]')"
if [ -z "${PKI_SEED:-}" ]; then
  die "PKI_SEED is not set — the base64 Ed25519 seed for CLIENT_HAID (source it from Secret Manager: gcloud secrets versions access latest --secret=cp-pki-key). It is never printed."
fi

BASE_URL="${BASE_URL%/}"               # strip a trailing slash for clean concatenation.
ID_TOKEN="${ID_TOKEN:-}"               # optional Cloud Run IAM bearer.

# ── THE REUSED HAID-SIGNING HTTP CLIENT (the shipped cp_auth signer over urllib) ─────
# Byte-for-byte the SAME signed GET /jobs verify-flight-fix.sh STEP 5 sends: job_id in
# the request BODY, signature over canonical_message("GET","/jobs",body). The seed is
# read from PKI_SEED in-process (never an argv — argv shows in `ps`) and never printed.
WORK="$(mktemp -d -t "get-job.$(printf 'X%.0s' 1 2 3 4 5 6)")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PROBE="$WORK/probe_client.py"
cat >"$PROBE" <<'PYEOF'
"""probe_client.py — the SAME signed GET /jobs that verify-flight-fix.sh STEP 5 sends,
isolated to ONE job_id, printing BOTH the raw HTTP body and the parsed state.

Reuses cp_auth.canonical_message + cp_auth.sign (the shipped signer). The Ed25519 seed
is read from PKI_SEED in-process only and never logged. An optional ID_TOKEN env adds the
Cloud Run IAM Authorization: Bearer header for a --no-allow-unauthenticated service.

stdout is ONE JSON line: {http_status, http_ok, raw, state, result, error, parse_error}
  http_status  the HTTP status code (0 on a transport failure).
  raw          the verbatim response body text (so RJ sees the EXACT service shape).
  state        b["job"]["state"] — EXACTLY how verify-flight-fix.sh STEP 5 parses it.
  result       b["job"]["result"]["status"] (or the bare result) — same as the verify.
  error        b["error"] when the service returns an error envelope (e.g. 404 no_such_job).
"""
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.environ["LIB"])
import cp_auth as K  # the SHIPPED signer — we never re-implement Ed25519.

BASE = os.environ["BASE_URL"].rstrip("/")
HAID = os.environ["CLIENT_HAID"]
SEED = os.environ["PKI_SEED"]            # base64 Ed25519 seed; in-process only.
ID_TOKEN = os.environ.get("ID_TOKEN") or ""
JOB_ID = os.environ["PROBE_JOB_ID"]


def main():
    method, path = "GET", "/jobs"
    body = json.dumps({"job_id": JOB_ID}).encode("utf-8")
    url = BASE + path
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("X-Heimdall-HAID", HAID)
    req.add_header("Content-Type", "application/json")
    msg = K.canonical_message(method, path, body)
    req.add_header("X-Heimdall-Signature", K.sign(SEED, msg))
    if ID_TOKEN:
        req.add_header("Authorization", "Bearer " + ID_TOKEN)

    status, raw = 0, ""
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            status = resp.status
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        status = exc.code
        raw = exc.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as exc:
        out = {"http_status": 0, "http_ok": False, "raw": "",
               "state": None, "result": None, "error": None,
               "parse_error": "transport: %s" % (getattr(exc, "reason", None) or exc)}
        sys.stdout.write(json.dumps(out))
        return 0

    # Parse EXACTLY like verify-flight-fix.sh's status verb: b["job"]["state"].
    state = result = error = parse_error = None
    try:
        b = json.loads(raw) if raw else {}
        job = b.get("job") or {}
        state = job.get("state")
        r = job.get("result")
        result = r.get("status") if isinstance(r, dict) else r
        error = b.get("error")
    except (ValueError, TypeError) as exc:
        parse_error = "json: %s" % exc

    out = {"http_status": status, "http_ok": (status == 200), "raw": raw,
           "state": state, "result": result, "error": error,
           "parse_error": parse_error}
    sys.stdout.write(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

OUT="$WORK/probe.out"
LIB="$LIB" BASE_URL="$BASE_URL" CLIENT_HAID="$CLIENT_HAID" PKI_SEED="$PKI_SEED" \
ID_TOKEN="$ID_TOKEN" PROBE_JOB_ID="$PROBE_JOB_ID" "$PY" "$PROBE" >"$OUT" 2>"$WORK/probe.err"

# Extract a field from the one-line JSON without echoing the seed (it isn't in here anyway).
field() { "$PY" -c "import json,sys
try:
    v=json.load(sys.stdin).get('$1')
    print('' if v is None else v)
except Exception:
    print('')" <"$OUT"; }

HTTP_STATUS="$(field http_status)"
HTTP_OK="$(field http_ok)"
RAW="$(field raw)"
STATE="$(field state)"
RESULT="$(field result)"
ERROR="$(field error)"
PARSE_ERROR="$(field parse_error)"

printf '%s\n' "============================================================"
printf '%s\n' "get-job: signed GET /jobs probe (verify-flight-fix STEP-5 shape)"
printf '  %s\n' "BASE_URL=$BASE_URL"
printf '  %s\n' "CLIENT_HAID=$CLIENT_HAID"
printf '  %s\n' "job_id=$PROBE_JOB_ID"
printf '  %s\n' "(PKI_SEED is set and will NOT be printed)"
printf '%s\n' "============================================================"
printf '\n'
printf '%s\n' "REQUEST (the EXACT shape verify-flight-fix.sh STEP 5 sends):"
printf '  %s\n' "GET /jobs"
printf '  %s\n' "body: {\"job_id\":\"$PROBE_JOB_ID\"}      <- job_id in the BODY (status_route reads payload['job_id'])"
printf '  %s\n' "headers: X-Heimdall-HAID, X-Heimdall-Signature (over canonical_message GET\\n/jobs\\nBODY)${ID_TOKEN:+, Authorization: Bearer <id-token>}"
printf '\n'
printf '%s\n' "RAW RESPONSE BODY (verbatim from the live service):"
printf '  HTTP %s\n' "${HTTP_STATUS:-?}"
printf '  %s\n' "${RAW:-<empty>}"
printf '\n'
printf '%s\n' "PARSED (exactly how verify-flight-fix.sh STEP 5 reads it — b['job']['state']):"
printf '  %s\n' "state  = ${STATE:-None}"
printf '  %s\n' "result = ${RESULT:-None}"
[ -n "$ERROR" ]       && printf '  %s\n' "error  = $ERROR"
[ -n "$PARSE_ERROR" ] && printf '  %s\n' "parse_error = $PARSE_ERROR"
printf '\n'

# ── THE VERDICT: which side is implicated ────────────────────────────────────────────
printf '%s\n' "============================================================"
if [ "$HTTP_OK" = "True" ] && [ "$STATE" = "done" ]; then
  printf '%s\n' "DONE -> the LIVE SERVICE returns state=done for $PROBE_JOB_ID."
  printf '%s\n' "  The service read-path is HEALTHY. verify-flight-fix.sh parses this exact shape"
  printf '%s\n' "  (b['job']['state']) and the dry run proves that round-trip reads 'done' — so any"
  printf '%s\n' "  earlier STEP-5 None was NOT a service bug. Re-run verify-flight-fix.sh; if it still"
  printf '%s\n' "  reads None on a fresh job, the divergence is timing (STEP5_POLL_SECONDS) not parse."
  exit 0
elif [ "$HTTP_STATUS" = "404" ] || [ "$ERROR" = "no_such_job" ]; then
  printf '%s\n' "NONE (404 no_such_job) -> the LIVE SERVICE cannot resolve $PROBE_JOB_ID at all."
  printf '%s\n' "  The doc HAS state=done (heimdall-cp-inspect reads it directly), but the service's"
  printf '%s\n' "  GET /jobs read-path returns 404 -> SERVICE-SIDE read-path bug (cp_worker.status_route"
  printf '%s\n' "  / cp_jobstore.read_job/fold_state reading the WRONG home/store on the live instance)."
  printf '%s\n' "  This is the OTHER agent's scope, NOT a verify-parse bug. Probe is the proof."
  exit 1
else
  printf '%s\n' "NONE -> the LIVE SERVICE returned HTTP $HTTP_STATUS with state='${STATE:-None}' for $PROBE_JOB_ID."
  printf '%s\n' "  The doc HAS state=done but the service did NOT return it. SERVICE-SIDE read-path issue"
  printf '%s\n' "  (or auth: HTTP 401 -> CLIENT_HAID/PKI_SEED not the registered identity, or missing"
  printf '%s\n' "  ID_TOKEN for a --no-allow-unauthenticated service). NOT a verify-parse bug — the parse"
  printf '%s\n' "  above reads b['job']['state'] from the raw body shown, exactly like verify STEP 5."
  exit 1
fi

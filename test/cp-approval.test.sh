#!/usr/bin/env bash
# cp-approval.test.sh — CARDINAL tests for control-plane piece (e): the GATE-APPROVAL
# QUEUE + OWNER OVERRIDE (fleet-level human authority).
#
# DESIGN DOSSIER §7 (authoritative) + §1 (requires_gate from the allowlist) + §10 (e).
# Proves the human-authority thesis against the REAL substrate (cp_approval over
# cp_allowlist / cp_auth / cp_audit / cp_server) — no mocks of the thing under test:
#
#   E. GATE-APPROVAL QUEUE (§7, the falsifiable core):
#      E1. an irreversible (requires_gate) action (run-suite) ENTERS pending and does
#          NOT dispatch — the approval record is `pending`, no `dispatch` audit row.
#      E2. FALSIFIABILITY: auto-dispatching a gated action without an approval must be
#          impossible — enqueue returns pending + dispatched:false; a non-gated action
#          (run-task-X) does NOT enter the queue (refuse-arbitrary, not refuse-all).
#
#   F. OWNER APPROVE / DENY (§7):
#      F1. the OWNER approves a pending action -> it DISPATCHES (200) + audited approval.
#      F2. the OWNER denies (rejects) a pending action -> it does NOT dispatch + audited.
#
#   G. OWNER OVERRIDE (§7, the human-authority thesis):
#      G1. the owner OVERRIDES a gate to force-approve -> dispatches + audited as an
#          `override` row (decision overridden), authority exercised never hidden.
#      G2. the owner OVERRIDES to force-block a pending action -> not dispatched +
#          audited as an override.
#
#   H. NON-OWNER REJECTED (§3/§7):
#      H1. a NON-owner identity attempting approve -> rejected (cp_auth AuthError),
#          no dispatch.
#      H2. a NON-owner identity attempting override -> rejected (AuthError), no dispatch.
#
#   I. EVERY DECISION AUDITED (§9):
#      I1. each of approve / reject / override (force-approve + force-block) wrote an
#          audit row (event approval or override) — every decision is in the log.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
APPROVAL_SRC="$LIB/cp_approval.py"

[ -f "$APPROVAL_SRC" ] || { echo "FATAL: $APPROVAL_SRC missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-approval.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/cphome"

HARNESS_OUT="$WORK/harness.out"
LIB="$LIB" "$PY" - >"$HARNESS_OUT" 2>"$WORK/harness.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_approval as Ap
import cp_audit as Au
import cp_auth as K
import cp_server as S

out = {}

owner = K.Identity("haid:rj.owner", owner=True)
worker = K.Identity("haid:bob.worker", owner=False)

# ── E. a gated action (run-suite) enters PENDING, does NOT dispatch ─────────────
sub = Ap.submit(owner, "run-suite", {"suite": "unit"})
out["e1_state"] = sub["state"]
out["e1_dispatched"] = bool(sub.get("dispatched"))
action_id = sub["action_id"]
out["e1_record_state"] = Ap.get(action_id)["state"]
# no dispatch audit row yet for this action — gated action held.
disp_rows = [r for r in Au.search(event="dispatch") if r.get("action_id") == action_id]
out["e1_dispatch_audit_rows"] = len(disp_rows)

# E2 falsifiability: a NON-gated action (run-task-X) does NOT enter the queue — it is
# not pending; submit dispatches it straight through (requires_gate False).
sub_ng = Ap.submit(owner, "run-task-X", {"task_id": "build-x"})
out["e2_nongated_state"] = sub_ng["state"]
out["e2_nongated_dispatched"] = bool(sub_ng.get("dispatched"))
out["e2_nongated_queued"] = Ap.get(sub_ng["action_id"]) is not None and \
    Ap.get(sub_ng["action_id"]).get("state") == "pending"

# ── F1. OWNER approves a pending action -> dispatches ──────────────────────────
sub_a = Ap.submit(owner, "run-suite", {"suite": "integration"})
aid_a = sub_a["action_id"]
res_a = Ap.approve(owner, aid_a)
out["f1_state"] = Ap.get(aid_a)["state"]
out["f1_dispatched"] = bool(res_a.get("dispatched"))
out["f1_status"] = res_a.get("status")
disp_a = [r for r in Au.search(event="dispatch") if r.get("action_id") == aid_a and r.get("outcome") == "ok"]
out["f1_dispatch_audit_rows"] = len(disp_a)

# ── F2. OWNER denies (rejects) a pending action -> not dispatched ──────────────
sub_d = Ap.submit(owner, "run-suite", {"suite": "oracle"})
aid_d = sub_d["action_id"]
res_d = Ap.reject(owner, aid_d, reason="not now")
out["f2_state"] = Ap.get(aid_d)["state"]
out["f2_dispatched"] = bool(res_d.get("dispatched"))
disp_d = [r for r in Au.search(event="dispatch") if r.get("action_id") == aid_d]
out["f2_dispatch_audit_rows"] = len(disp_d)

# ── G1. OWNER OVERRIDE force-approve -> dispatches + audited override ───────────
sub_o = Ap.submit(owner, "run-suite", {"suite": "unit"})
aid_o = sub_o["action_id"]
res_o = Ap.override(owner, aid_o, force="approve", reason="owner authority")
out["g1_state"] = Ap.get(aid_o)["state"]
out["g1_dispatched"] = bool(res_o.get("dispatched"))
ovr_o = [r for r in Au.search(event="override") if r.get("action_id") == aid_o]
out["g1_override_audit_rows"] = len(ovr_o)
out["g1_override_decision"] = ovr_o[0]["decision"] if ovr_o else None

# ── G2. OWNER OVERRIDE force-block a pending action -> not dispatched + audited ─
sub_b = Ap.submit(owner, "run-suite", {"suite": "unit"})
aid_b = sub_b["action_id"]
res_b = Ap.override(owner, aid_b, force="block", reason="owner blocks")
out["g2_state"] = Ap.get(aid_b)["state"]
out["g2_dispatched"] = bool(res_b.get("dispatched"))
ovr_b = [r for r in Au.search(event="override") if r.get("action_id") == aid_b]
out["g2_override_audit_rows"] = len(ovr_b)
disp_b = [r for r in Au.search(event="dispatch") if r.get("action_id") == aid_b]
out["g2_dispatch_audit_rows"] = len(disp_b)

# ── H1. NON-owner approve -> AuthError, no dispatch ────────────────────────────
sub_h = Ap.submit(owner, "run-suite", {"suite": "unit"})
aid_h = sub_h["action_id"]
try:
    Ap.approve(worker, aid_h)
    out["h1_rejected"] = False
    out["h1_reason"] = None
except K.AuthError as e:
    out["h1_rejected"] = True
    out["h1_reason"] = e.reason
out["h1_state_after"] = Ap.get(aid_h)["state"]  # must still be pending
disp_h = [r for r in Au.search(event="dispatch") if r.get("action_id") == aid_h and r.get("outcome") == "ok"]
out["h1_dispatch_audit_rows"] = len(disp_h)

# ── H2. NON-owner override -> AuthError, no dispatch ───────────────────────────
try:
    Ap.override(worker, aid_h, force="approve", reason="sneaky")
    out["h2_rejected"] = False
    out["h2_reason"] = None
except K.AuthError as e:
    out["h2_rejected"] = True
    out["h2_reason"] = e.reason
out["h2_state_after"] = Ap.get(aid_h)["state"]  # still pending — non-owner cannot force

# ── I1. every decision in the audit log (approval + override events) ───────────
appr_rows = Au.search(event="approval")
ovr_rows = Au.search(event="override")
out["i1_approval_rows"] = len(appr_rows)
out["i1_override_rows"] = len(ovr_rows)
# the approve (F1) and reject (F2) decisions are present.
out["i1_has_approved"] = any(r.get("decision") == "approved" for r in appr_rows)
out["i1_has_rejected"] = any(r.get("decision") == "rejected" for r in appr_rows)
out["i1_has_overridden"] = any(r.get("decision") == "overridden" for r in ovr_rows)

# ── E/I: gate-surface vocabulary reuse (PROVEN/BLOCKED/PENDING -> verdict) ──────
out["vocab_pending"] = Ap.verdict_for_state("pending")
out["vocab_approved"] = Ap.verdict_for_state("approved")
out["vocab_rejected"] = Ap.verdict_for_state("rejected")
out["vocab_overridden"] = Ap.verdict_for_state("overridden")

# routes registered on the server seam (approve/reject/override endpoints).
routes = S.registered_routes()
out["routes"] = ["%s %s" % (m, p) for (m, p) in routes]

sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$HARNESS_OUT" ]; then
  echo "FATAL: approval harness produced no output" >&2
  cat "$WORK/harness.err" >&2
  exit 2
fi

jget() { "$PY" -c "import json,sys; print(json.load(open('$HARNESS_OUT')).get('$1'))"; }
jget_in() { "$PY" -c "import json,sys; v=json.load(open('$HARNESS_OUT')).get('$1') or []; print('$2' in v)"; }

echo "E. GATE-APPROVAL QUEUE (§7, the falsifiable core)"
[ "$(jget e1_state)" = "pending" ] && [ "$(jget e1_record_state)" = "pending" ] && ok "E1 gated run-suite ENTERS pending" || bad "E1 gated action did not enter pending"
[ "$(jget e1_dispatched)" = "False" ] && [ "$(jget e1_dispatch_audit_rows)" = "0" ] && ok "E1 gated action does NOT dispatch (no dispatch audit row)" || bad "E1 gated action dispatched without approval"
if [ "$(jget e2_nongated_dispatched)" = "True" ] && [ "$(jget e2_nongated_queued)" = "False" ] && [ "$(jget e1_dispatched)" = "False" ]; then
  ok "E2 FALSIFIABLE: gated pends + does-not-dispatch while non-gated dispatches (not gate-everything)"
else
  bad "E2 not falsifiable (gated vs non-gated did not distinguish)"
fi

echo "F. OWNER APPROVE / DENY (§7)"
[ "$(jget f1_state)" = "approved" ] && [ "$(jget f1_dispatched)" = "True" ] && [ "$(jget f1_status)" = "200" ] && [ "$(jget f1_dispatch_audit_rows)" -ge 1 ] && ok "F1 owner approve -> DISPATCHES (200) + audited" || bad "F1 owner approve did not dispatch"
[ "$(jget f2_state)" = "rejected" ] && [ "$(jget f2_dispatched)" = "False" ] && [ "$(jget f2_dispatch_audit_rows)" = "0" ] && ok "F2 owner deny -> NOT dispatched + audited" || bad "F2 owner deny dispatched anyway"

echo "G. OWNER OVERRIDE (§7, human-authority thesis)"
[ "$(jget g1_state)" = "overridden" ] && [ "$(jget g1_dispatched)" = "True" ] && [ "$(jget g1_override_audit_rows)" -ge 1 ] && [ "$(jget g1_override_decision)" = "overridden" ] && ok "G1 owner override force-approve -> dispatches + audited as override" || bad "G1 override force-approve failed"
[ "$(jget g2_state)" = "overridden" ] && [ "$(jget g2_dispatched)" = "False" ] && [ "$(jget g2_override_audit_rows)" -ge 1 ] && [ "$(jget g2_dispatch_audit_rows)" = "0" ] && ok "G2 owner override force-block -> not dispatched + audited as override" || bad "G2 override force-block failed"

echo "H. NON-OWNER REJECTED (§3/§7)"
[ "$(jget h1_rejected)" = "True" ] && [ "$(jget h1_state_after)" = "pending" ] && [ "$(jget h1_dispatch_audit_rows)" = "0" ] && ok "H1 non-owner approve -> AuthError ($(jget h1_reason)), no dispatch" || bad "H1 non-owner approve was not rejected"
[ "$(jget h2_rejected)" = "True" ] && [ "$(jget h2_state_after)" = "pending" ] && ok "H2 non-owner override -> AuthError ($(jget h2_reason)), no force" || bad "H2 non-owner override was not rejected"

echo "I. EVERY DECISION AUDITED (§9)"
[ "$(jget i1_has_approved)" = "True" ] && ok "I1 approve decision in audit log" || bad "I1 approve decision missing from audit"
[ "$(jget i1_has_rejected)" = "True" ] && ok "I1 reject decision in audit log" || bad "I1 reject decision missing from audit"
[ "$(jget i1_has_overridden)" = "True" ] && ok "I1 override decision in audit log" || bad "I1 override decision missing from audit"
[ "$(jget i1_override_rows)" -ge 2 ] && ok "I1 every override (force-approve + force-block) audited ($(jget i1_override_rows))" || bad "I1 not every override audited"

echo "J. GATE-SURFACE VOCABULARY REUSE (PROVEN/BLOCKED/PENDING)"
[ "$(jget vocab_pending)" = "PENDING" ] && ok "J pending -> PENDING (gate-surface vocab)" || bad "J pending vocab wrong"
[ "$(jget vocab_approved)" = "PROVEN" ] && ok "J approved -> PROVEN (gate-surface vocab)" || bad "J approved vocab wrong"
[ "$(jget vocab_rejected)" = "BLOCKED" ] && ok "J rejected -> BLOCKED (gate-surface vocab)" || bad "J rejected vocab wrong"
[ "$(jget vocab_overridden)" = "PROVEN" ] && ok "J overridden -> PROVEN (force-approve verdict)" || bad "J overridden vocab wrong"

echo "K. SERVER ROUTE SEAM (§10 register_route)"
[ "$(jget_in routes 'POST /approvals/approve')" = "True" ] && ok "K /approvals/approve route registered" || bad "K approve route not registered"
[ "$(jget_in routes 'POST /approvals/reject')" = "True" ] && ok "K /approvals/reject route registered" || bad "K reject route not registered"
[ "$(jget_in routes 'POST /approvals/override')" = "True" ] && ok "K /approvals/override route registered" || bad "K override route not registered"

echo
printf "cp-approval: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

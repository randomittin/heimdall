#!/usr/bin/env bash
# heimdall-issue-actions.test.sh — THE ISSUE-CRON ALLOWLIST + HANDLER-DISPATCH FALSIFIER (Wave 3).
#
# WHAT THIS GATES. The two SCHEDULED issue-collection actions on the control-plane security spine:
#   • aggregate-issues -> cp_handlers.aggregate_issues -> cp_issue_aggregate.run_daily_aggregate
#   • synth-issues     -> cp_handlers.synth_issues     -> cp_issue_synth.run_synthesis
#
# These are the ONLY way a cron / the scheduler can fold the isolated issue store into a k-anon
# aggregate + shadow proposal queue. They ride the SAME §1 dispatch gate as every other action:
# a closed allowlist, typed+bounded params, NO free command string, NO arbitrary dispatch. A
# breached server can trigger ONLY these two bounded, data-only jobs against the isolated corpus
# namespace — it cannot smuggle a command through them.
#
# THE FALSIFIERS (RED-without-the-wiring):
#   A. ALLOWLIST MEMBERSHIP — aggregate-issues + synth-issues are recognized action_types;
#      an arbitrary action_type is NOT. FALSIFIER: the two actions absent from the allowlist ->
#      is_allowed False + dispatch 422 unknown_action -> RED (the wiring is what makes them known).
#   B. DISPATCH ROUTES TO THE REAL HANDLER — a valid dispatch runs the REAL run_daily_aggregate /
#      run_synthesis over a seeded isolated issue store and returns its structured result.
#      FALSIFIER: a dispatch that does not reach the handler (no aggregate published, no proposal
#      synthesized) -> RED. This proves the handler is WIRED, not just the spec present.
#   C. NO ARBITRARY COMMAND / SMUGGLE WALL — an extra `cmd` field -> 422 extra_param; a non-int
#      into a typed Int param -> 422 bad_param; an unknown action -> 422 unknown_action. The
#      typed+bounded params flow through (k_min override changes the k-anon gate). FALSIFIER: a
#      smuggled command accepted, or a free-string param type in the source -> RED.
#
# Runs the REAL cp_allowlist / cp_handlers / cp_server / cp_issue_aggregate / cp_issue_synth code
# against a hermetic HEIMDALL_HOME + a UNIQUE corpus namespace. stdlib + shipped cp_* ONLY, ZERO
# spend, ZERO GCP. Exit 0 iff every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
ALLOWLIST_SRC="$LIB/cp_allowlist.py"
export LIB REPO

for f in cp_allowlist cp_handlers cp_server cp_issue_aggregate cp_issue_synth cp_issue_ingest issue_corpus pmr_corpus; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "issue-actions.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/cphome"
mkdir -p "$HEIMDALL_HOME"
# A unique corpus namespace so the seeded issue store is honestly isolated per run.
export HEIMDALL_CORPUS_NAMESPACE="heimdall_issue_actions_gate"

echo "============================================================"
echo "ISSUE-CRON allowlist + handler-dispatch falsifier (Wave 3)"
echo "  home=$HEIMDALL_HOME  corpus_ns=$HEIMDALL_CORPUS_NAMESPACE"
echo "============================================================"
echo

HARNESS_OUT="$WORK/harness.out"
"$PY" - >"$HARNESS_OUT" 2>"$WORK/harness.err" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_allowlist as A
import cp_issue_aggregate as AGG
import cp_issue_ingest as ING
import cp_issue_synth as SYN
import cp_server as S
import cp_auth as K

out = {}

# ── seed the ISOLATED issue store: 10 distinct teams sharing ONE signature bucket ──
# k-anon floor is 10 (issue_corpus.ISSUE_K_ANONYMITY_MIN), so 10 distinct teams contributing
# the SAME signature clears the gate -> exactly one PUBLISHED bucket + one synth proposal.
def issue_v1(issue_id, team, sig="sigSHARED"):
    return {"schema": "issue_v1", "consent_version": "c1",
            "ids": {"issue_id": issue_id, "team_id_hash": team, "repo_class_hash": "rc"},
            "when": {"ts": "1000", "tz_bucket": "utc"},
            "signal": {"error_class": "lint", "signature_hash": sig,
                       "gate": "lint", "phase": "verify", "command": "test",
                       "severity": "low"},
            "env": {"os_class": "linux", "ci": False, "hmd_version": "v1"},
            "security_sensitive": False}

TEAMS = ["team%02d" % i for i in range(10)]
for i, t in enumerate(TEAMS):
    # home=None -> the ambient HEIMDALL_HOME the test exported (the SAME store the handler reads).
    ING.ingest_issues(t, [issue_v1("iss%02d" % i, t)], home=None)
out["seeded_teams"] = len(AGG.list_issue_teams(home=None))

ident = K.Identity("haid:issue-cron-owner", owner=True)

# ── A. ALLOWLIST MEMBERSHIP (falsifiable: unknown action stays refused) ──
out["agg_allowed"] = A.is_allowed("aggregate-issues")
out["syn_allowed"] = A.is_allowed("synth-issues")
out["arbitrary_allowed"] = A.is_allowed("arbitrary-cmd")
# spec shape: data-only cron jobs -> not gate-queued, isolated low-priv env.
try:
    aspec = A.spec_for("aggregate-issues")
    sspec = A.spec_for("synth-issues")
    out["agg_requires_gate"] = aspec.requires_gate
    out["agg_isolated"] = aspec.isolated
    out["syn_requires_gate"] = sspec.requires_gate
    out["syn_isolated"] = sspec.isolated
    out["agg_handler"] = aspec.handler
    out["syn_handler"] = sspec.handler
except A.RefusedDispatch as e:
    out["spec_error"] = e.reason

# ── B. DISPATCH ROUTES TO THE REAL HANDLER ──
r_agg = S.dispatch(ident, "aggregate-issues", {})
out["agg_status"] = r_agg.status
ares = (r_agg.body or {}).get("result") or {}
out["agg_result_status"] = ares.get("status")
out["agg_published_buckets"] = ares.get("published_buckets")
out["agg_total_teams"] = ares.get("total_teams")
# the handler must have STORED the aggregate in the corpus namespace (latest.json refreshed).
latest = AGG.latest_aggregate(home=None) or {}
out["agg_latest_published"] = latest.get("published_buckets")

r_syn = S.dispatch(ident, "synth-issues", {})
out["syn_status"] = r_syn.status
sres = (r_syn.body or {}).get("result") or {}
out["syn_result_status"] = sres.get("status")
out["syn_proposals"] = sres.get("proposals")
props = SYN.list_proposals(home=None)
out["syn_queue_len"] = len(props)
out["syn_all_pending_review"] = all(p.get("status") == "pending_review" for p in props) if props else False
out["syn_none_enforced"] = all(p.get("enforced") is False for p in props) if props else False

# ── typed param flows through: a k_min override of 50 (> 10 teams) suppresses the bucket ──
r_agg_hi = S.dispatch(ident, "aggregate-issues", {"k_min": 50})
hires = (r_agg_hi.body or {}).get("result") or {}
out["agg_hi_published"] = hires.get("published_buckets")
out["agg_hi_suppressed"] = hires.get("suppressed_buckets")

# ── C. SMUGGLE WALL ──
r_smuggle = S.dispatch(ident, "aggregate-issues", {"cmd": "rm -rf /"})
out["smuggle_status"] = r_smuggle.status
out["smuggle_reason"] = (r_smuggle.body or {}).get("reason")

r_badparam = S.dispatch(ident, "synth-issues", {"min_teams": "; rm -rf /"})
out["badparam_status"] = r_badparam.status
out["badparam_reason"] = (r_badparam.body or {}).get("reason")

r_unknown = S.dispatch(ident, "aggregate-issues-EVIL", {"x": 1})
out["unknown_status"] = r_unknown.status
out["unknown_reason"] = (r_unknown.body or {}).get("reason")

sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$HARNESS_OUT" ]; then
  echo "FATAL: harness produced no output" >&2
  cat "$WORK/harness.err" >&2
  exit 2
fi
echo "  harness: $(cat "$HARNESS_OUT")"
echo

jget() { "$PY" -c "import json,sys; print(json.load(open('$HARNESS_OUT')).get('$1'))"; }

echo "A. ALLOWLIST MEMBERSHIP (the two cron actions recognized; arbitrary refused)"
[ "$(jget seeded_teams)" = "10" ] && ok "seed: 10 distinct teams landed in the isolated issue store" || bad "seed did not land 10 teams — $(cat "$HARNESS_OUT")"
[ "$(jget agg_allowed)" = "True" ] && [ "$(jget syn_allowed)" = "True" ] && ok "A1 aggregate-issues + synth-issues are allowlisted action_types" || bad "A1 the two cron actions are NOT allowlisted (FALSIFIER RED)"
[ "$(jget arbitrary_allowed)" = "False" ] && ok "A2 an arbitrary action_type is NOT allowlisted (no fallthrough)" || bad "A2 an arbitrary action leaked into the allowlist"
[ "$(jget agg_requires_gate)" = "False" ] && [ "$(jget agg_isolated)" = "True" ] && [ "$(jget syn_requires_gate)" = "False" ] && [ "$(jget syn_isolated)" = "True" ] && ok "A3 both specs are requires_gate=False + isolated=True (bounded, low-priv, data-only)" || bad "A3 spec flags wrong (want gate=False isolated=True)"
[ "$(jget agg_handler)" = "cp_handlers.aggregate_issues" ] && [ "$(jget syn_handler)" = "cp_handlers.synth_issues" ] && ok "A4 specs name the cp_handlers dispatch targets" || bad "A4 spec handler refs wrong — $(cat "$HARNESS_OUT")"

echo
echo "B. DISPATCH ROUTES TO THE REAL HANDLER (RED-without-the-wiring)"
[ "$(jget agg_status)" = "200" ] && [ "$(jget agg_result_status)" = "done" ] && ok "B1 dispatch aggregate-issues -> 200, handler status=done" || bad "B1 aggregate-issues did not reach the handler — $(cat "$HARNESS_OUT")"
[ "$(jget agg_published_buckets)" -ge 1 ] 2>/dev/null && ok "B2 the REAL run_daily_aggregate published >=1 k-anon bucket over the seeded store ($(jget agg_published_buckets))" || bad "B2 the handler did not run the real aggregate (no published bucket)"
[ "$(jget agg_total_teams)" = "10" ] && ok "B3 the aggregate folded all 10 distinct teams (handler read the isolated store)" || bad "B3 the aggregate did not see the seeded teams — $(cat "$HARNESS_OUT")"
[ "$(jget agg_latest_published)" -ge 1 ] 2>/dev/null && ok "B4 the handler STORED the day's aggregate in the corpus namespace (latest refreshed)" || bad "B4 no aggregate stored — the handler did not persist"
[ "$(jget syn_status)" = "200" ] && [ "$(jget syn_result_status)" = "done" ] && ok "B5 dispatch synth-issues -> 200, handler status=done" || bad "B5 synth-issues did not reach the handler — $(cat "$HARNESS_OUT")"
[ "$(jget syn_proposals)" -ge 1 ] 2>/dev/null && ok "B6 the REAL run_synthesis produced >=1 shadow proposal ($(jget syn_proposals))" || bad "B6 the handler did not run the real synth (no proposal)"
[ "$(jget syn_queue_len)" -ge 1 ] 2>/dev/null && [ "$(jget syn_all_pending_review)" = "True" ] && [ "$(jget syn_none_enforced)" = "True" ] && ok "B7 the proposal queue holds SHADOW candidates (pending_review, enforced=False)" || bad "B7 synth did not append shadow-only proposals"
[ "$(jget agg_hi_published)" = "0" ] && [ "$(jget agg_hi_suppressed)" -ge 1 ] 2>/dev/null && ok "B8 a typed k_min=50 override flows through -> the 10-team bucket is SUPPRESSED (param is real, bounded)" || bad "B8 the k_min param did not flow to the handler — $(cat "$HARNESS_OUT")"

echo
echo "C. SMUGGLE WALL (no arbitrary command dispatchable through the cron actions)"
[ "$(jget smuggle_status)" = "422" ] && [ "$(jget smuggle_reason)" = "extra_param" ] && ok "C1 an extra cmd field on aggregate-issues -> 422 extra_param" || bad "C1 a smuggled cmd field was NOT refused"
[ "$(jget badparam_status)" = "422" ] && [ "$(jget badparam_reason)" = "bad_param" ] && ok "C2 a shell payload into the typed min_teams param -> 422 bad_param" || bad "C2 a non-int/shell payload was NOT refused"
[ "$(jget unknown_status)" = "422" ] && [ "$(jget unknown_reason)" = "unknown_action" ] && ok "C3 an unknown issue action -> 422 unknown_action" || bad "C3 an unknown action was NOT refused"
if grep -nE '"(aggregate-issues|synth-issues)"' "$ALLOWLIST_SRC" | grep -qE ':\s*ActionSpec'; then :; fi
if grep -nE '"(cmd|command|shell|exec|prompt)"\s*:\s*(Str|Enum|Int|Bool|Opt)\(' "$ALLOWLIST_SRC" >/dev/null 2>&1; then
  bad "C4 a command-string-shaped param is declared in the allowlist source"
else
  ok "C4 NO command/prompt free-string param declared for the new actions"
fi

echo
printf "heimdall-issue-actions: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

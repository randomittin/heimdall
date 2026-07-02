#!/usr/bin/env bash
# heimdall-cp-hybrid-runner.test.sh — the CARDINAL tests for the HYBRID maintainer
# RUNNER SELECTION (bin/lib/cp_maintainer_runner.py) on the existing control plane.
#
# Proves the hybrid dispatch prefers the OPERATOR'S OWN BOX (Arch A —
# cp_jobrunner.SubprocessRunner) WHEN IT IS UP, falls back to a CLOUD RUN JOB (Arch B —
# cp_jobrunner.CloudRunJobRunner) when it is not, and NEVER DROPS A CYCLE — it fails over
# or parks (queued, re-drivable) rather than lose the work. HERMETIC: the liveness read
# runs against the REAL cp_presence beat store, the runner-beat VERB writes a REAL beat,
# and BOTH runners + the claim clock are MOCKED (injected) so there is no subprocess spawn,
# no GCP, no network, no real LLM, $0.
#
#   A. THE BEAT SUBSTRATE the selector reads (reuses cp_presence; DATA-ONLY, no token):
#      A1. the runner-beat VERB (bin/heimdall-maintain-loop runner-beat) writes a beat the
#          selector reads as FRESH — with a token in the env, the STORED beat carries NONE.
#      A2. an ABSENT beat -> NOT live (falsifier for "always fresh").
#      A3. a STALE beat (ts beyond the TTL) -> NOT live (falsifier); the TTL env is honored.
#      A4. build_runner_beat is a CLOSED, token-free schema {kind,runner_id,repo,handle,ts}
#          — no cmd/handler/token field can ride a beat (a beat executes nothing).
#
#   B. DETERMINISTIC SELECTION (fresh->A, stale/absent->B, forced policies):
#      B1. hybrid + a FRESH self-hosted beat within TTL -> ARM_LOCAL (Arch A).
#      B2. hybrid + a STALE/ABSENT beat + cloud configured -> ARM_CLOUD (Arch B).
#      B3. hybrid + no beat + cloud NOT configured -> ARM_PARK.
#      B4. policy=local FORCES ARM_LOCAL (even with no beat).
#      B5. policy=cloud FORCES ARM_CLOUD (even with a fresh beat).
#      B6. FALSIFIABLE: B1 picks A WHILE B2 picks B off the SAME live beat store — a
#          selector hard-wired to one arm would RED one of them (refuse-arbitrary).
#
#   C. THE NEVER-DROP DISPATCH (select -> enqueue -> dispatch -> failover -> park):
#      C1. fresh beat, CLAIMED within the grace window -> dispatched to Arch A (the local
#          runner got the job); no failover, not parked, cycle NOT lost.
#      C2. hybrid picks A but the job is NOT CLAIMED within the grace window -> FAILS OVER
#          to Arch B (the cloud runner is dispatched); failover=True; the SAME job_id
#          survives (a cycle is never dropped).
#      C3. Arch A unclaimed AND Arch B unconfigured -> PARKS with an explicit reason; the
#          durable job stays `queued` (re-drivable next tick), cycle_lost=False.
#      C4. no beat AND no cloud (select-time park) -> PARKS; job stays `queued`, not lost.
#
#   D. EACH DECISION EMITS EXACTLY ONE token-free reason line to stderr (the log sink):
#      D1. SELECT -> one `SELECT ... reason=` line.  D2. FAILOVER -> one `FAILOVER` line.
#      D3. PARK -> one `PARK` line. (Every line is token-free — see E.)
#
#   E. THE TOKEN NEVER APPEARS IN ANY RECORDED SURFACE (result / audit / argv / log),
#      with a POSITIVE CONTROL that the token DID reach the child env (so the grep is
#      MEANINGFUL — a token-blind test would pass vacuously):
#      E1. POSITIVE CONTROL: the token in base_env DID reach the chosen runner's child env.
#      E2. the token VALUE appears in NONE of: the outcome dicts, the whole audit store, the
#          stderr decision log, the whole durable home — grep across every surface is EMPTY.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO_DIR/bin/lib"
LOOP_BIN="$REPO_DIR/bin/heimdall-maintain-loop"

for f in cp_maintainer_runner.py cp_presence.py cp_jobrunner.py cp_jobstore.py \
         cp_allowlist.py cp_audit.py; do
  [ -f "$LIB/$f" ] || { echo "FATAL: $LIB/$f missing" >&2; exit 2; }
done
[ -x "$LOOP_BIN" ] || { echo "FATAL: $LOOP_BIN missing/not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# unique work dir (mirrors the maintainer test's template discipline; no shared /tmp path).
WORK="$(mktemp -d -t "cp-hybrid.$(printf 'q%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/cphome"

# The UNIQUE, greppable secret — it MUST reach the child env (positive control) but NEVER a
# recorded surface (result / audit / stderr log / the durable home / a stored beat).
OAUTH_TOKEN="sk-oauth-HYBRIDSENTINEL-DEADBEEF0123456789"
REPO="randomittin/heimdall"

# ── PART 1: the runner-beat VERB writes a DATA-ONLY beat the selector reads as fresh ─
# Run the real bin verb with the token in the env; the STORED beat must carry NO token.
export CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN"
VERB_OUT="$("$LOOP_BIN" runner-beat --repo "$REPO" --runner-id verb-box \
             --handle op-laptop --home "$HEIMDALL_HOME" 2>"$WORK/verb.err")"
VERB_RC=$?
unset CLAUDE_CODE_OAUTH_TOKEN

# ── drive the real substrate + the injected runners through one python harness ──────
HARNESS_OUT="$WORK/harness.json"
LIB="$LIB" WORK="$WORK" OAUTH_TOKEN="$OAUTH_TOKEN" REPO="$REPO" \
  "$PY" - >"$HARNESS_OUT" 2>"$WORK/harness.err" <<'PYEOF'
import contextlib
import io
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_maintainer_runner as mr
import cp_jobstore as J

WORK = os.environ["WORK"]
OAUTH = os.environ["OAUTH_TOKEN"]
REPO = os.environ["REPO"]
out = {}


class Ident:
    haid = "haid:hybrid-test"


actor = Ident()
PARAMS = {"repo": REPO, "max": 2}


class FakeRunner:
    """A hermetic JobRunner: records the base_env it received (the positive-control probe)
    and reports a fixed `dispatched`. Never spawns / never touches GCP — the selection +
    failover + park logic is what's under test, not a runner's own execution."""

    def __init__(self, name, dispatched=True):
        self.name = name
        self._dispatched = dispatched
        self.seen_env = None
        self.calls = 0

    def dispatch(self, job_id, *, actor_haid=None, home=None, base_env=None):
        self.calls += 1
        self.seen_env = dict(base_env) if base_env else {}
        return {"dispatched": self._dispatched, "runner": self.name}


@contextlib.contextmanager
def capture_stderr():
    """Capture EXACTLY the decision lines one dispatch emits, so we can count them per
    decision (the 'one logged reason line' proof) and grep them for a token leak."""
    buf = io.StringIO()
    old = sys.stderr
    sys.stderr = buf
    try:
        yield buf
    finally:
        sys.stderr = old


# ── A. THE BEAT SUBSTRATE (real cp_presence store; DATA-ONLY, token-free) ───────────
# A1 is proven at the shell layer (the real bin verb already wrote a beat); here we
# confirm the selector reads THAT verb's beat as fresh.
out["A1_verb_beat_live"] = mr.runner_is_live(REPO)

# A2 — an absent beat: a repo scope with NO beat reads NOT live (honest empty).
out["A2_absent_not_live"] = (mr.runner_is_live("nobody/elsewhere") is False)

# A3 — a STALE beat: write one with an ancient ts; with the default TTL it is NOT live.
mr.record_runner_beat("stale-box", repo="stale/repo", ts=1.0)
out["A3_stale_not_live"] = (mr.runner_is_live("stale/repo") is False)
# ...and the TTL env is honored: a HUGE ttl makes even the ancient beat count as live.
out["A3_ttl_env_honored"] = (
    mr.runner_is_live("stale/repo", now=2.0, ttl=1e12) is True)

# A4 — build_runner_beat is a CLOSED, token-free schema (executes nothing, carries no key).
beat = mr.build_runner_beat("schema-box", repo=REPO, handle="op")
out["A4_beat_keys"] = sorted(beat.keys())
out["A4_schema_closed"] = (
    sorted(beat.keys()) == ["handle", "kind", "repo", "runner_id", "ts"])
# even if a HIGH-SIGNAL secret is smuggled as the handle, the scrub (telemetry._scrub via
# cp_presence._clean) drops it -> the beat's handle is None, the secret never enters a beat.
SCRUBBABLE = "ghp_" + "A" * 36  # a github-PAT-shaped high-signal token _scrub rejects.
beat_tok = mr.build_runner_beat("x", repo=REPO, handle=SCRUBBABLE)
out["A4_no_token_in_beat"] = (
    SCRUBBABLE not in json.dumps(beat_tok) and beat_tok["handle"] is None)


# ── B. DETERMINISTIC SELECTION off the REAL live beat store ─────────────────────────
# Write a FRESH beat for REPO so the live read (runner_live=None) sees Arch A up.
mr.record_runner_beat("live-box", repo=REPO, handle="op")
d_b1 = mr.select_runner_arm(REPO, policy_name="hybrid", cloud_ok=True)  # live read
out["B1_arm"] = d_b1.arm
out["B1_local"] = (d_b1.arm == mr.ARM_LOCAL and d_b1.runner_live is True)

# A DIFFERENT repo scope has NO fresh beat -> hybrid + cloud configured -> Arch B.
d_b2 = mr.select_runner_arm("cloudy/repo", policy_name="hybrid", cloud_ok=True)  # live read
out["B2_arm"] = d_b2.arm
out["B2_cloud"] = (d_b2.arm == mr.ARM_CLOUD and d_b2.runner_live is False)

# hybrid + no beat + cloud NOT configured -> PARK.
d_b3 = mr.select_runner_arm("dark/repo", policy_name="hybrid", cloud_ok=False)  # live read
out["B3_arm"] = d_b3.arm
out["B3_park"] = (d_b3.arm == mr.ARM_PARK)

# policy=local FORCES Arch A even for a repo with NO beat.
d_b4 = mr.select_runner_arm("dark/repo", policy_name="local", cloud_ok=False)
out["B4_forced_local"] = (d_b4.arm == mr.ARM_LOCAL)

# policy=cloud FORCES Arch B even though REPO has a FRESH beat.
d_b5 = mr.select_runner_arm(REPO, policy_name="cloud", cloud_ok=True)
out["B5_forced_cloud"] = (d_b5.arm == mr.ARM_CLOUD)

# B6 FALSIFIABLE: the SAME live store yields A for REPO and B for the beat-less scope.
out["B6_falsifiable"] = (
    out["B1_local"] and out["B2_cloud"] and out["B3_park"]
    and out["B4_forced_local"] and out["B5_forced_cloud"])


# ── C. THE NEVER-DROP DISPATCH (select -> enqueue -> dispatch -> failover -> park) ──
# C1 — fresh beat + CLAIMED within grace -> dispatched to Arch A, no failover/park.
lr1, cr1 = FakeRunner("subprocess"), FakeRunner("cloudrun-job")
with capture_stderr() as log1:
    o1 = mr.dispatch_maintainer_cycle(
        actor, PARAMS, base_env={"CLAUDE_CODE_OAUTH_TOKEN": OAUTH},
        local_runner=lr1, cloud_runner=cr1,
        runner_live=True, cloud_ok=True, grace_seconds=0, claimed=lambda j, h: True)
out["C1"] = {k: o1.get(k) for k in
             ("arm", "runner", "dispatched", "failover", "parked", "cycle_lost")}
out["C1_local_dispatched"] = (
    o1["arm"] == mr.ARM_LOCAL and o1["runner"] == "subprocess"
    and o1["dispatched"] is True and o1["failover"] is False
    and o1["parked"] is False and lr1.calls == 1 and cr1.calls == 0)
out["C1_log"] = log1.getvalue()

# C2 — hybrid picks A but NEVER claimed within grace -> FAILS OVER to Arch B, same job_id.
lr2, cr2 = FakeRunner("subprocess"), FakeRunner("cloudrun-job")
with capture_stderr() as log2:
    o2 = mr.dispatch_maintainer_cycle(
        actor, PARAMS, base_env={"CLAUDE_CODE_OAUTH_TOKEN": OAUTH},
        local_runner=lr2, cloud_runner=cr2,
        runner_live=True, cloud_ok=True, grace_seconds=0, claimed=lambda j, h: False)
out["C2"] = {k: o2.get(k) for k in
             ("arm", "runner", "dispatched", "failover", "parked", "cycle_lost", "job_id")}
out["C2_failover"] = (
    o2["arm"] == mr.ARM_CLOUD and o2["runner"] == "cloudrun-job"
    and o2["failover"] is True and o2["dispatched"] is True
    and o2["parked"] is False and o2["cycle_lost"] is False
    and lr2.calls == 1 and cr2.calls == 1)
# the SAME cycle survives — the durable job still exists and is re-drivable (queued).
out["C2_same_cycle_preserved"] = (J.current_state(o2["job_id"]) == J.STATE_QUEUED)
out["C2_log"] = log2.getvalue()

# C3 — Arch A unclaimed AND Arch B unconfigured -> PARK (failover-park); job stays queued.
lr3, cr3 = FakeRunner("subprocess"), FakeRunner("cloudrun-job")
with capture_stderr() as log3:
    o3 = mr.dispatch_maintainer_cycle(
        actor, PARAMS, base_env={"CLAUDE_CODE_OAUTH_TOKEN": OAUTH},
        local_runner=lr3, cloud_runner=cr3,
        runner_live=True, cloud_ok=False, grace_seconds=0, claimed=lambda j, h: False)
out["C3"] = {k: o3.get(k) for k in
             ("arm", "dispatched", "parked", "cycle_lost", "job_id")}
out["C3_parked_not_lost"] = (
    o3["arm"] == mr.ARM_PARK and o3["parked"] is True
    and o3["dispatched"] is False and o3["cycle_lost"] is False
    and J.current_state(o3["job_id"]) == J.STATE_QUEUED)
out["C3_log"] = log3.getvalue()

# C4 — SELECT-TIME park: no beat AND no cloud -> PARK; the enqueued job stays queued.
lr4, cr4 = FakeRunner("subprocess"), FakeRunner("cloudrun-job")
with capture_stderr() as log4:
    o4 = mr.dispatch_maintainer_cycle(
        actor, PARAMS, base_env={"CLAUDE_CODE_OAUTH_TOKEN": OAUTH},
        local_runner=lr4, cloud_runner=cr4,
        runner_live=False, cloud_ok=False)
out["C4"] = {k: o4.get(k) for k in ("arm", "parked", "cycle_lost", "job_id")}
out["C4_select_park"] = (
    o4["arm"] == mr.ARM_PARK and o4["parked"] is True
    and o4["cycle_lost"] is False and lr4.calls == 0 and cr4.calls == 0
    and J.current_state(o4["job_id"]) == J.STATE_QUEUED)
out["C4_log"] = log4.getvalue()


# ── D. EACH DECISION EMITS EXACTLY ONE token-free reason line ───────────────────────
def count(hay, needle):
    return hay.count(needle)

# C1's log has exactly ONE SELECT line and no FAILOVER/PARK.
out["D1_one_select"] = (count(out["C1_log"], "SELECT job=") == 1
                        and count(out["C1_log"], "FAILOVER") == 0
                        and count(out["C1_log"], "PARK") == 0)
# C2's log has ONE SELECT then ONE FAILOVER line.
out["D2_one_failover"] = (count(out["C2_log"], "SELECT job=") == 1
                          and count(out["C2_log"], "FAILOVER job=") == 1)
# C3 (failover-park) + C4 (select-park) each emit ONE PARK line.
out["D3_one_park"] = (count(out["C3_log"], "PARK job=") == 1
                      and count(out["C4_log"], "PARK job=") == 1)


# ── E. TOKEN NEVER LOGGED (positive control it reached the child env) ───────────────
# E1 POSITIVE CONTROL: the token DID reach the chosen runner's child env every dispatch.
out["E1_reached_local_child"] = (
    lr1.seen_env.get("CLAUDE_CODE_OAUTH_TOKEN") == OAUTH)         # C1 -> Arch A got it
out["E1_reached_cloud_child"] = (
    cr2.seen_env.get("CLAUDE_CODE_OAUTH_TOKEN") == OAUTH)         # C2 failover -> Arch B got it
out["E1_positive_control"] = (
    out["E1_reached_local_child"] and out["E1_reached_cloud_child"])

# E2 — the token must appear in NONE of the recorded surfaces. Gather them:
#   (1) every outcome dict, (2) every captured decision log, (3) each RunnerDecision reason.
surfaces = [
    json.dumps(o1), json.dumps(o2), json.dumps(o3), json.dumps(o4),
    out["C1_log"], out["C2_log"], out["C3_log"], out["C4_log"],
    d_b1.reason, d_b2.reason, d_b3.reason, d_b4.reason, d_b5.reason,
]
out["E2_token_in_surfaces"] = any(OAUTH in s for s in surfaces)  # expect False

out["audit_dir"] = os.path.join(
    os.environ["HEIMDALL_HOME"], "control-plane", "audit")
print(json.dumps(out, indent=2, sort_keys=True))
PYEOF

if [ ! -s "$HARNESS_OUT" ]; then
  echo "FATAL: harness produced no output" >&2
  echo "----- harness.err -----" >&2; cat "$WORK/harness.err" >&2
  exit 2
fi

jget() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print(json.dumps(v) if not isinstance(v,str) else v)' "$HARNESS_OUT" "$1"; }

echo "== A. the beat substrate the selector reads (real cp_presence; DATA-ONLY) =="
{ [ "$VERB_RC" -eq 0 ] && echo "$VERB_OUT" | grep -q '"ok": true'; } \
  && ok "A1 runner-beat VERB wrote a beat: $VERB_OUT" \
  || bad "A1 runner-beat verb failed (rc=$VERB_RC): $VERB_OUT / $(cat "$WORK/verb.err")"
[ "$(jget A1_verb_beat_live)" = "true" ] \
  && ok "A1 the selector reads the VERB's beat as FRESH (Arch A live)" \
  || bad "A1 selector did not read the verb's beat as live"
# the stored beat carries NO token (the verb ran with the token in its env).
BEAT_FILE="$(find "$HEIMDALL_HOME" -path '*maintainer-runner*' -name '*.json' 2>/dev/null | head -1)"
if [ -n "$BEAT_FILE" ] && ! grep -qF "$OAUTH_TOKEN" "$BEAT_FILE"; then
  ok "A1 the stored beat is DATA-ONLY — no token in $BEAT_FILE"
else
  bad "A1 beat file missing or LEAKED the token: $BEAT_FILE"
fi
[ "$(jget A2_absent_not_live)" = "true" ] && ok "A2 an ABSENT beat -> NOT live (honest empty)" || bad "A2 absent beat read as live"
[ "$(jget A3_stale_not_live)" = "true" ] && ok "A3 a STALE beat (past TTL) -> NOT live" || bad "A3 stale beat read as live"
[ "$(jget A3_ttl_env_honored)" = "true" ] && ok "A3 the TTL knob is honored (huge ttl -> ancient beat counts live)" || bad "A3 TTL not honored"
[ "$(jget A4_schema_closed)" = "true" ] && ok "A4 build_runner_beat is a CLOSED schema $(jget A4_beat_keys) (no cmd/handler/token)" || bad "A4 beat schema not closed: $(jget A4_beat_keys)"
[ "$(jget A4_no_token_in_beat)" = "true" ] && ok "A4 a high-signal secret smuggled as the handle is scrubbed out (handle=None)" || bad "A4 secret survived into a beat handle"

echo "== B. deterministic selection off the REAL live beat store =="
[ "$(jget B1_local)" = "true" ] && ok "B1 hybrid + FRESH beat -> ARM_LOCAL (Arch A / SubprocessRunner)" || bad "B1 fresh beat did not pick Arch A (got $(jget B1_arm))"
[ "$(jget B2_cloud)" = "true" ] && ok "B2 hybrid + no beat + cloud configured -> ARM_CLOUD (Arch B / CloudRunJobRunner)" || bad "B2 beat-less scope did not pick Arch B (got $(jget B2_arm))"
[ "$(jget B3_park)" = "true" ] && ok "B3 hybrid + no beat + cloud UNconfigured -> ARM_PARK" || bad "B3 did not park (got $(jget B3_arm))"
[ "$(jget B4_forced_local)" = "true" ] && ok "B4 policy=local FORCES Arch A (even with no beat)" || bad "B4 policy=local did not force Arch A"
[ "$(jget B5_forced_cloud)" = "true" ] && ok "B5 policy=cloud FORCES Arch B (even with a fresh beat)" || bad "B5 policy=cloud did not force Arch B"
[ "$(jget B6_falsifiable)" = "true" ] && ok "B6 FALSIFIABLE: SAME store -> A for the live repo WHILE B for the beat-less one (refuse-arbitrary)" || bad "B6 falsifiability failed"

echo "== C. the never-drop dispatch (select -> enqueue -> dispatch -> failover -> park) =="
[ "$(jget C1_local_dispatched)" = "true" ] && ok "C1 fresh+claimed -> dispatched to Arch A, no failover/park: $(jget C1)" || bad "C1 did not dispatch cleanly to Arch A: $(jget C1)"
[ "$(jget C2_failover)" = "true" ] && ok "C2 picked A, NOT claimed in grace -> FAILED OVER to Arch B: $(jget C2)" || bad "C2 failover did not occur: $(jget C2)"
[ "$(jget C2_same_cycle_preserved)" = "true" ] && ok "C2 the SAME cycle survives (durable job still queued, re-drivable) — never dropped" || bad "C2 the cycle was lost across failover"
[ "$(jget C3_parked_not_lost)" = "true" ] && ok "C3 A unclaimed AND B unconfigured -> PARKED, job queued, cycle_lost=false: $(jget C3)" || bad "C3 did not park/preserve: $(jget C3)"
[ "$(jget C4_select_park)" = "true" ] && ok "C4 no beat + no cloud -> SELECT-TIME park, job queued, no runner touched: $(jget C4)" || bad "C4 select-time park failed: $(jget C4)"

echo "== D. each decision emits EXACTLY ONE token-free reason line =="
[ "$(jget D1_one_select)" = "true" ] && ok "D1 the SELECT decision emits exactly one reason line" || bad "D1 SELECT line count wrong"
[ "$(jget D2_one_failover)" = "true" ] && ok "D2 the FAILOVER decision emits exactly one reason line (after the SELECT)" || bad "D2 FAILOVER line count wrong"
[ "$(jget D3_one_park)" = "true" ] && ok "D3 each PARK decision emits exactly one reason line" || bad "D3 PARK line count wrong"

echo "== E. token NEVER in any recorded surface (+ positive control) =="
[ "$(jget E1_positive_control)" = "true" ] && ok "E1 POSITIVE CONTROL: the token DID reach BOTH the Arch A and the Arch B child env (env-injection works)" || bad "E1 token did NOT reach a child env — a token-blind test would pass vacuously"

# E2 — the token VALUE must appear in NONE of: the harness surfaces (already checked in-proc),
# the whole audit store, and the ENTIRE durable home (belt-and-braces).
[ "$(jget E2_token_in_surfaces)" = "false" ] && ok "E2a token in NO outcome dict / decision log / selection reason" || bad "E2a TOKEN LEAK in a result/log/reason surface"
AUDIT_DIR="$(jget audit_dir)"
AUDIT_HITS=""
if [ -d "$AUDIT_DIR" ]; then AUDIT_HITS="$(grep -rlF "$OAUTH_TOKEN" "$AUDIT_DIR" 2>/dev/null || true)"; fi
[ -z "$AUDIT_HITS" ] && ok "E2b the audit store carries NO token (params-shape rows only)" || bad "E2b TOKEN LEAK in the audit store: [$AUDIT_HITS]"
HOME_HITS="$(grep -rlF "$OAUTH_TOKEN" "$HEIMDALL_HOME" 2>/dev/null || true)"
[ -z "$HOME_HITS" ] && ok "E2c the ENTIRE durable home is token-free (store/beats/jobs/audit)" || bad "E2c TOKEN LEAK in the durable home: [$HOME_HITS]"

echo
echo "cp-hybrid-runner: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

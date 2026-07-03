#!/usr/bin/env bash
# heimdall-cp-authz-gate.test.sh — THE W2 SECURITY-KEYSTONE gate (rr isolation invariants,
# docs/specs/2026-07-03-rr-isolation-invariants.md). Hermetic, two-team (A, B) fixture over
# the LOCAL StateBackend. Every assertion cites the invariant it proves.
#
# WHAT THIS FALSIFIES (the keystone, INV-11 / A1+A5): a caller may dispatch a maintainer cycle
# ONLY against a repo its OWN team's installation covers. Team A dispatching team B's repo is a
# 403 fail-closed refusal with NO job row and NO runner dispatch. THE FALSIFIER: drop the
# repo<->team gate (team_covers_repo -> always True) and the SAME cross-tenant dispatch SUCCEEDS
# (200 + a runner call) — proving the gate is load-bearing, not decorative.
#
# ALSO PROVEN:
#   INV-1  team_id is server-derived from the caller's binding (registered_team), NEVER a request
#          field — a spoofed params team_id is refused (extra_param), there is no wire channel.
#   INV-2/4 the per-team job env carries THAT team's model cred + THAT team's minted App token,
#          NEVER another team's (and never the operator's ambient cred) — secrets ride env only.
#   INV-3  fail-closed: a caller with no resolvable team is DENIED (no default-open, no job).
#   INV-5  a free-form / oversized / secret-shaped task is bounded + scrubbed DATA on enqueue.
#   INV-6  the public /rr-task route is signed + ENQUEUE-ONLY: it enqueues to the caller's OWN
#          partition and holds NO credential + NO dispatch capability (grep-proven on
#          cp_publicsurface.py: no select_maintainer_auth / .dispatch( / cred read).
#   INV-8  a replayed signed enqueue (same nonce) is refused 401.
#   DRAIN  the gated drain picks each team's queue and dispatches through the SAME gate with the
#          per-team env; draining team A never touches team B's partition.
#   ADDITIVE the single-tenant path (flag off) is unchanged.
#
# Crypto-gated (bindings are keyed by an enrolled pubkey): SKIP cleanly with no cryptography|pynacl.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_auth cp_ghinstall cp_team_creds cp_team_queue cp_maintainer_runner \
         cp_publicsurface cp_server cp_jobstore cp_allowlist cp_boot; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

if ! "$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — team bindings need an enrolled pubkey."
  echo "heimdall-cp-authz-gate: 0 passed, 0 failed (SKIPPED — no crypto)"
  exit 0
fi

EXT="$(mktemp -d -t "cp-authz.$(printf 'X%.0s' 1 2 3 4 5 6)")"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

export HEIMDALL_HOME="$EXT/home"
mkdir -p "$HEIMDALL_HOME"
# Isolated, single-tenant defaults MUST be absent so a no-team caller resolves to NO team
# (fail-closed), not a configured default team.
unset HEIMDALL_DEFAULT_TEAM_SECRET HEIMDALL_ENROLL_TOKEN HEIMDALL_STATE_BACKEND \
      HEIMDALL_PUBLIC_SURFACE HEIMDALL_RR_TENANT_AUTHZ 2>/dev/null || true

# A hermetic fake GitHub-App-token minter: prints a token that ENCODES the per-team
# installation id it was handed via the child ENV (so a test can prove team A's job carries
# team A's install token, never team B's). Never touches real GitHub.
cat > "$EXT/fake-minter" <<'PYEOF'
#!/usr/bin/env python3
import os
inst = os.environ.get("HEIMDALL_GH_APP_INSTALLATION_ID", "?")
repo = os.environ.get("HEIMDALL_GH_APP_REPOSITORIES", "?")
print("ghs_inst%s_%s" % (inst, repo))
PYEOF
chmod +x "$EXT/fake-minter"
export HEIMDALL_GH_APP_TOKEN_BIN="$EXT/fake-minter"

echo "============================================================"
echo "W2 AUTHZ KEYSTONE (falsifiable) — two teams, LOCAL backend"
echo "  home=$HEIMDALL_HOME"
echo "============================================================"
echo

cat > "$EXT/fixture.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth as A, cp_ghinstall as GH, cp_team_creds as TC, cp_team_queue as TQ
import cp_maintainer_runner as MR, cp_publicsurface as PS, cp_jobstore as JS, cp_server as CS

H = os.environ["HEIMDALL_HOME"]
now = 1_700_000_000.0
os.environ["HEIMDALL_RR_TENANT_AUTHZ"] = "1"
out = {}

SA = "team-secret-A-aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SB = "team-secret-B-bbbbbbbbbbbbbbbbbbbbbbbbbbbb"
tidA = A.derive_team_id(SA); tidB = A.derive_team_id(SB)

# members bound to their teams (team_id server-side on the enroll binding, never a body field).
HA, HB = "haid:devA.box", "haid:devB.box"
A.register_key(HA, A.generate_keypair()[1], team_id=tidA)
A.register_key(HB, A.generate_keypair()[1], team_id=tidB)
out["A_binds_tidA"] = (A.registered_team(HA) == tidA)
out["B_binds_tidB"] = (A.registered_team(HB) == tidB)

# per-team installations (repo<->team map) + per-team model creds.
GH.set_team_installation(tidA, 1001, "acme/a-repo", home=H)
GH.set_team_installation(tidB, 2002, "acme/b-repo", home=H)
TC.put_team_cred(tidA, "oauth_token", "A_OAUTH_SECRET_zzz", home=H)
TC.put_team_cred(tidB, "api_key",     "B_APIKEY_SECRET_qqq", home=H)

class FakeRunner:
    def __init__(self, name="fake"): self.name = name; self.calls = []
    def dispatch(self, job_id, *, actor_haid=None, home=None, base_env=None):
        self.calls.append({"job_id": job_id, "actor": actor_haid, "base_env": dict(base_env or {})})
        return {"dispatched": True, "runner": self.name}

def disp(actor, repo, *, extra=None, runner=None, team_id=None, base=None):
    p = {"repo": repo, "max": 1}
    if extra: p.update(extra)
    fr = runner or FakeRunner()
    o = MR.dispatch_maintainer_cycle(
        actor, p, home=H,
        base_env=(base if base is not None else
                  {"CLAUDE_CODE_OAUTH_TOKEN": "OPERATOR_LEAK_OAUTH",
                   "ANTHROPIC_API_KEY": "OPERATOR_LEAK_KEY"}),
        now=now, policy_name="local", runner_live=True, local_runner=fr,
        cloud_ok=False, grace_seconds=0, team_id=team_id)
    return o, fr

# ── INV-11: A -> A's OWN repo -> ALLOWED, dispatched.
frA = FakeRunner("localA")
oA, _ = disp(HA, "acme/a-repo", runner=frA)
out["A_own_repo_allowed"] = (oA.get("http_status") == 200 and oA.get("dispatched") is True
                             and len(frA.calls) == 1)

# ── INV-2/INV-4: A's job env carries A's cred + A's minted install token, NEVER B's / operator's.
env = frA.calls[0]["base_env"] if frA.calls else {}
out["A_env_has_A_oauth"]   = (env.get("CLAUDE_CODE_OAUTH_TOKEN") == "A_OAUTH_SECRET_zzz")
out["A_env_no_op_leak"]    = (env.get("CLAUDE_CODE_OAUTH_TOKEN") != "OPERATOR_LEAK_OAUTH")
out["A_env_no_apikey"]     = ("ANTHROPIC_API_KEY" not in env)
out["A_env_no_B_secret"]   = ("B_APIKEY_SECRET_qqq" not in json.dumps(env))
tok = str(env.get("HEIMDALL_PR_BOT_TOKEN", ""))
out["A_env_token_is_A"]    = ("1001" in tok and "2002" not in tok)

# ── INV-11 KEYSTONE cross-tenant: A -> B's repo -> DENIED 403, NO job, NO dispatch.
jobs_before = set(JS.list_job_ids(H))
frX = FakeRunner("xt")
oX, _ = disp(HA, "acme/b-repo", runner=frX)
jobs_after = set(JS.list_job_ids(H))
out["cross_denied_403"] = (oX.get("http_status") == 403 and oX.get("refused") is True)
out["cross_no_dispatch"] = (len(frX.calls) == 0)
out["cross_no_job"] = (jobs_before == jobs_after)

# ── THE FALSIFIER: drop the gate -> the SAME cross-tenant dispatch SUCCEEDS (proves it is load-bearing).
_orig = GH.team_covers_repo
GH.team_covers_repo = lambda *a, **k: True
frF = FakeRunner("fal")
oF, _ = disp(HA, "acme/b-repo", runner=frF)
GH.team_covers_repo = _orig
out["falsifier_dispatches_when_gate_dropped"] = (oF.get("http_status") == 200 and len(frF.calls) == 1)

# ── INV-1: a spoofed request team_id is REFUSED (no wire channel to set the partition).
frS = FakeRunner("spoof")
oS, _ = disp(HA, "acme/a-repo", extra={"team_id": tidB}, runner=frS)
out["spoof_team_id_refused"] = (oS.get("http_status") == 422 and oS.get("refused") is True
                                and len(frS.calls) == 0)

# ── INV-3 fail-closed: a caller with NO resolvable team -> DENIED, no dispatch.
A.register_key("haid:noteam", A.generate_keypair()[1])  # no team_id, no default team configured
frN = FakeRunner("noteam")
oN, _ = disp("haid:noteam", "acme/a-repo", runner=frN)
out["no_team_denied"] = (oN.get("http_status") == 403 and len(frN.calls) == 0)

# ── ADDITIVE: flag OFF -> the gate is skipped, the single-tenant dispatch is unchanged.
os.environ.pop("HEIMDALL_RR_TENANT_AUTHZ", None)
frST = FakeRunner("st")
oST = MR.dispatch_maintainer_cycle(
    "haid:whoever", {"repo": "acme/any-repo", "max": 1}, home=H,
    base_env={"CLAUDE_CODE_OAUTH_TOKEN": "ambient"}, now=now,
    policy_name="local", runner_live=True, local_runner=frST, cloud_ok=False, grace_seconds=0)
out["single_tenant_unchanged"] = (oST.get("http_status") == 200 and len(frST.calls) == 1
                                  and frST.calls[0]["base_env"].get("CLAUDE_CODE_OAUTH_TOKEN") == "ambient")
os.environ["HEIMDALL_RR_TENANT_AUTHZ"] = "1"

# ── INV-6: public /rr-task enqueue-only — signed, team-scoped, caller's OWN partition only.
idA = A.Identity(HA)
st, body = PS.enqueue_rr_task(idA, {"body": json.dumps(
    {"task": "fix flaky test in module X", "nonce": "nq1", "ts": now})}, home=H, now=now)
out["enqueue_ok"] = (st == 200 and body.get("team_id") == tidA and body.get("enqueued") is True)
out["enqueue_to_A"] = (TQ.depth(tidA, home=H) == 1)
out["enqueue_not_B"] = (TQ.depth(tidB, home=H) == 0)

# team_id from the binding, not the body: a spoofed body team_id is ignored.
st2, body2 = PS.enqueue_rr_task(idA, {"body": json.dumps(
    {"task": "second task", "team_id": tidB})}, home=H, now=now)
out["enqueue_spoof_ignored"] = (body2.get("team_id") == tidA and TQ.depth(tidB, home=H) == 0)

# ── INV-5: a secret-shaped + oversized task is redacted + trimmed to bounded DATA.
secretish = "ghp_" + ("a" * 36)   # a GitHub PAT shape telemetry redacts
big = "z" * 5000
st3, body3 = PS.enqueue_rr_task(idA, {"body": json.dumps(
    {"task": secretish + " tail " + big})}, home=H, now=now)
texts = [r["item"]["text"] for r in TQ.list(tidA, home=H) if r["state"] == "queued" and r["item"]]
out["task_trimmed"] = (st3 == 200 and all(len(t) <= 4000 for t in texts))
out["task_scrubbed"] = (any("[REDACTED]" in t for t in texts)
                        and not any("ghp_aaaa" in t for t in texts))

# ── INV-3: enqueue for a no-team caller -> denied.
stN, _ = PS.enqueue_rr_task(A.Identity("haid:noteam"),
                            {"body": json.dumps({"task": "x"})}, home=H, now=now)
out["enqueue_no_team_denied"] = (stN == 403)

# ── INV-8: a replayed signed enqueue (same nonce) -> 401.
os.environ["HEIMDALL_PUBLIC_SURFACE"] = "1"
rr = {"body": json.dumps({"task": "beat", "nonce": "replayZ", "ts": now}), "peer_ip": "1.2.3.4"}
g1 = PS.check_rr_task_post_auth(idA, rr, home=H, now=now)
g2 = PS.check_rr_task_post_auth(idA, rr, home=H, now=now)
out["nonce_first_ok"] = (g1 is None)
out["nonce_replay_401"] = (isinstance(g2, tuple) and g2[0] == 401)

# structural: /rr-task is in the public allowlist AND is SIGNED-ONLY (goes through the §3
# chokepoint — NOT a pre-auth public route), and gated routes stay non-public.
out["rrtask_public"] = (PS.is_public_route("POST", "/rr-task") is True
                        and ("POST", "/rr-task") in PS.PUBLIC_ROUTES)
out["rrtask_signed_only"] = (CS._public_route("POST", "/rr-task") is None)
out["dispatch_still_gated"] = (PS.is_public_route("POST", "/dispatch") is False)
os.environ.pop("HEIMDALL_PUBLIC_SURFACE", None)

# ── DRAIN wiring: the gated drain picks team A's queue -> dispatch through the SAME gate; B untouched.
depthB_pre = TQ.depth(tidB, home=H)
jobs_pre = set(JS.list_job_ids(H))
dr = MR.drain_team_queue(tidA, home=H, base_env={}, now=now, policy_name="hybrid",
                         cloud_ok=False, runner_live=False)
out["drain_processed"] = (dr.get("processed", 0) >= 1)
out["drain_emptied_A"] = (TQ.depth(tidA, home=H) == 0)
out["drain_untouched_B"] = (TQ.depth(tidB, home=H) == depthB_pre)
out["drain_made_jobs"] = (len(set(JS.list_job_ids(H)) - jobs_pre) >= 1)
kt = set(GH.known_team_ids(home=H))
out["known_teams"] = (tidA in kt and tidB in kt)

print(json.dumps(out))
PYEOF

R="$("$PY" "$EXT/fixture.py" 2>"$EXT/py.err")"

if [ -s "$EXT/py.err" ]; then echo "  (python stderr:)"; sed 's/^/    /' "$EXT/py.err" >&2; fi
[ -n "$R" ] || { bad "python fixture produced no output"; echo; echo "heimdall-cp-authz-gate: $PASS passed, $((FAIL+1)) failed"; exit 1; }
j() { printf '%s' "$R" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }

# ── the assertions (each cites its invariant) ──
[ "$(j A_binds_tidA)" = "True" ] && [ "$(j B_binds_tidB)" = "True" ] \
  && ok "INV-1 team_id is server-derived from each caller's enroll binding (A->tidA, B->tidB)" \
  || bad "INV-1 the binding did not resolve the caller's team (R=$R)"
[ "$(j A_own_repo_allowed)" = "True" ] \
  && ok "INV-11 A dispatching A's OWN covered repo -> ALLOWED (200 + runner dispatched)" \
  || bad "INV-11 a covered dispatch was not allowed (R=$R)"
[ "$(j A_env_has_A_oauth)" = "True" ] && [ "$(j A_env_no_op_leak)" = "True" ] \
  && [ "$(j A_env_no_apikey)" = "True" ] && [ "$(j A_env_no_B_secret)" = "True" ] \
  && ok "INV-2/4 A's job env carries A's model cred ONLY (no operator leak, no B's api_key)" \
  || bad "INV-2/4 the per-team env leaked another cred (R=$R)"
[ "$(j A_env_token_is_A)" = "True" ] \
  && ok "INV-2/A5 A's job env carries A's minted install token (inst 1001), never B's (2002)" \
  || bad "INV-2/A5 the minted App token was not team A's (R=$R)"
[ "$(j cross_denied_403)" = "True" ] && [ "$(j cross_no_dispatch)" = "True" ] && [ "$(j cross_no_job)" = "True" ] \
  && ok "INV-11 KEYSTONE: A dispatching B's repo -> 403 fail-closed, NO job row, NO runner call [A1/A5]" \
  || bad "INV-11 CROSS-TENANT DISPATCH WAS NOT DENIED (R=$R)"
[ "$(j falsifier_dispatches_when_gate_dropped)" = "True" ] \
  && ok "FALSIFIER: drop team_covers_repo -> the SAME cross-tenant dispatch SUCCEEDS (gate is load-bearing)" \
  || bad "FALSIFIER did not flip — the gate may not be the thing denying (R=$R)"
[ "$(j spoof_team_id_refused)" = "True" ] \
  && ok "INV-1 a spoofed request team_id is REFUSED (extra_param) — no wire channel to set the partition" \
  || bad "INV-1 a request team_id was not refused (R=$R)"
[ "$(j no_team_denied)" = "True" ] \
  && ok "INV-3 fail-closed: a caller with NO resolvable team is DENIED (no default-open, no job)" \
  || bad "INV-3 a no-team caller was not denied (R=$R)"
[ "$(j single_tenant_unchanged)" = "True" ] \
  && ok "ADDITIVE: flag OFF -> the gate is skipped, the single-tenant dispatch is byte-unchanged" \
  || bad "ADDITIVE single-tenant path regressed under the flag (R=$R)"
[ "$(j enqueue_ok)" = "True" ] && [ "$(j enqueue_to_A)" = "True" ] && [ "$(j enqueue_not_B)" = "True" ] \
  && ok "INV-6 public /rr-task enqueues to the CALLER'S OWN partition only (A, never B)" \
  || bad "INV-6 enqueue crossed partitions or failed (R=$R)"
[ "$(j enqueue_spoof_ignored)" = "True" ] \
  && ok "INV-1 enqueue team_id comes from the binding, not the body (spoofed team_id ignored)" \
  || bad "INV-1 enqueue honored a body team_id (R=$R)"
[ "$(j task_trimmed)" = "True" ] && [ "$(j task_scrubbed)" = "True" ] \
  && ok "INV-5 a free-form / oversized / secret-shaped task is bounded + scrubbed DATA" \
  || bad "INV-5 the task text was not bounded/scrubbed (R=$R)"
[ "$(j enqueue_no_team_denied)" = "True" ] \
  && ok "INV-3 enqueue for a no-team caller -> denied (fail-closed)" \
  || bad "INV-3 a no-team enqueue was not denied (R=$R)"
[ "$(j nonce_first_ok)" = "True" ] && [ "$(j nonce_replay_401)" = "True" ] \
  && ok "INV-8 a replayed signed enqueue (same nonce) -> 401 (replay refused)" \
  || bad "INV-8 the replay-nonce gate did not refuse a replay (R=$R)"
[ "$(j rrtask_public)" = "True" ] && [ "$(j rrtask_signed_only)" = "True" ] && [ "$(j dispatch_still_gated)" = "True" ] \
  && ok "INV-6 /rr-task is in the public allowlist AND SIGNED-ONLY; gated routes stay non-public" \
  || bad "INV-6 the /rr-task route wiring is wrong (R=$R)"
[ "$(j drain_processed)" = "True" ] && [ "$(j drain_emptied_A)" = "True" ] \
  && [ "$(j drain_untouched_B)" = "True" ] && [ "$(j drain_made_jobs)" = "True" ] && [ "$(j known_teams)" = "True" ] \
  && ok "DRAIN the gated drain picks team A's queue -> dispatches through the gate; B's partition untouched" \
  || bad "DRAIN wiring did not drain A / leaked into B (R=$R)"

# ── INV-6 grep proof: cp_publicsurface holds NO credential + NO dispatch capability ──
echo
if grep -nE "select_maintainer_auth|\.dispatch\(|mint_token_for_team|env_for_team|HEIMDALL_PR_BOT_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY" "$LIB/cp_publicsurface.py" >/dev/null 2>&1; then
  bad "INV-6 cp_publicsurface.py references a credential/dispatch symbol (must be enqueue-only)"
  grep -nE "select_maintainer_auth|\.dispatch\(|mint_token_for_team|env_for_team|HEIMDALL_PR_BOT_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY" "$LIB/cp_publicsurface.py" >&2
else
  ok "INV-6 cp_publicsurface.py holds NO cred + NO dispatch symbol (grep-clean, enqueue-only)"
fi

# ── INV-1 grep proof: cp_maintainer_runner never reads team_id from the request params ──
if grep -nE "clean\.get\(.team_id|clean\[.team_id|params\.get\(.team_id|params\[.team_id" "$LIB/cp_maintainer_runner.py" >/dev/null 2>&1; then
  bad "INV-1 cp_maintainer_runner.py reads team_id from the request params (must be registered_team)"
else
  ok "INV-1 cp_maintainer_runner.py never reads team_id from the request params (grep-clean)"
fi

echo
echo "============================================================"
printf "heimdall-cp-authz-gate: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

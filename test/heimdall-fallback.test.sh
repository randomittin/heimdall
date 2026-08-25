#!/usr/bin/env bash
# heimdall-fallback.test.sh -- falsifiable coverage for bin/heimdall-fallback,
# the quota-exhaustion fallback POLICY gate (state/config/safety only -- no
# transport; see the tool's own header for the full safety boundary).
#
# THE HONEST LIMIT under test: this suite proves the GATE computes the right
# verdict for a given config -- it cannot and does not prove OmniRoute itself
# is safe to talk to (explicitly out of scope; see
# docs/analysis/2026-08-23-omniroute-assessment.md). No case below ever makes
# a real network syscall: HEIMDALL_FALLBACK_ASSUME_REACHABLE is set to a
# known value for the whole suite and only ever overridden-then-restored
# within a single section.
#
# HERMETIC: every case gets its own mktemp repo dir passed via --repo; no
# case ever touches a real ~/.heimdall or a real project config.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO/bin/heimdall-fallback"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

fb() { python3 "$CLI" "$@"; }
# cd+pwd (not a bare mktemp -d) so the returned path is already canonical --
# TMPDIR on macOS ends in a trailing slash, which left uncorrected produces a
# "//" that this suite's plain-concatenation cfg_path() would not normalize
# but the tool's own os.path.abspath() (main()) correctly does; comparing
# the two directly would be an apples-to-oranges test bug, not a tool bug.
fresh_repo() { local d; d="$(mktemp -d "${TMPDIR:-/tmp}/hmd-fallback-test.XXXXXX")"; (cd "$d" && pwd); }
cfg_path() { printf '%s/.heimdall/fallback.json' "$1"; }
write_cfg() {
  # $1=repo dir  $2=raw JSON text
  mkdir -p "$1/.heimdall"
  printf '%s' "$2" > "$(cfg_path "$1")"
}

# Hermetic default for the whole suite: nothing here is actually listening on
# a local gateway port, so "not reachable" is the honest baseline. Sections
# that need a PASSING reachability check override to "1" for their own scope
# and restore "0" immediately after -- see sections 3, 5, 10, 12.
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0

echo "heimdall-fallback harness"
echo "--------------------------------------------------------------------"

# ── 0. the tool is executable and is valid Python ────────────────────────────
[ -x "$CLI" ] && ok "0a. $CLI is executable" || bad "0a. not executable: $CLI"
ast_out="$(python3 -c "import ast; ast.parse(open('$CLI').read())" 2>&1)"; ast_rc=$?
[ "$ast_rc" -eq 0 ] && ok "0b. AST parse clean (valid Python syntax)" || bad "0b. AST parse failed: $ast_out"

# ── 1. fresh/absent config reads off ─────────────────────────────────────────
R="$(fresh_repo)"
out="$(fb --repo "$R" status)"; rc=$?
echo "$out" | grep -Eq 'state:[[:space:]]+off' && [ "$rc" -eq 0 ] \
  && ok "1a. fresh repo, no config file -> status shows state=off" \
  || bad "1a. got rc=$rc out='$out'"
out="$(fb --repo "$R" check)"; rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" \
  && ok "1b. fresh repo -> check REFUSEs (off is never a route verdict)" \
  || bad "1b. rc=$rc out='$out'"

# ── 2. corrupt config reads off, never on ────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" 'not json { garbage'
out="$(fb --repo "$R" status)"
echo "$out" | grep -Eq 'state:[[:space:]]+off' && echo "$out" | grep -qi "corrupt" \
  && ok "2a. malformed JSON -> state=off, corruption surfaced (not silent)" \
  || bad "2a. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '[1, 2, 3]'
out="$(fb --repo "$R" status)"
echo "$out" | grep -Eq 'state:[[:space:]]+off' \
  && ok "2b. valid JSON but not an object -> state=off" \
  || bad "2b. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "on", "mitm_enabled": true, "tier1_disabled": true, "operator_key_env": "X", "target_provider": "y", "endpoint": "http://127.0.0.1:20128"}'
out="$(fb --repo "$R" status)"
echo "$out" | grep -Eq 'state:[[:space:]]+off' && echo "$out" | grep -qi "forbidden" \
  && ok "2c. well-formed JSON but carries a forbidden MITM key -> forced back to off, never on" \
  || bad "2c. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "please-route-me-now"}'
out="$(fb --repo "$R" status)"
echo "$out" | grep -Eq 'state:[[:space:]]+off' \
  && ok "2d. unrecognized state string -> reads off" \
  || bad "2d. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "on", "mitm_enabled": true}'
fb --repo "$R" check >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "2e. corrupt+MITM-tainted config -> check never exits 0 (never ROUTE)" \
  || bad "2e. check exited 0 (ROUTE) on a corrupt config! rc=$rc"

# ── 3. state=on but Tier-1 not verifiably disabled -> REFUSE, specific reason ─
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="fake-operator-key-value"
write_cfg "$R" '{
  "state": "on",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "tier1_disabled": false,
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" && echo "$out" | grep -qi "Tier-1" \
  && echo "$out" | grep -q "FAIL.*tier1_disabled" \
  && ok "3. state=on, Tier-1 not disabled -> REFUSE with a Tier-1-specific reason" \
  || bad "3. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY

# ── 4. auto + failing preflight -> WAIT, not ROUTE; same failure under on -> REFUSE ─
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
out="$(fb --repo "$R" check)"; rc=$?
[ "$rc" -eq 2 ] && echo "$out" | grep -q "VERDICT: WAIT" && ! echo "$out" | grep -q "VERDICT: ROUTE" \
  && ok "4a. state=auto, nothing configured -> WAIT (not ROUTE)" \
  || bad "4a. rc=$rc out='$out'"

R2="$(fresh_repo)"
write_cfg "$R2" '{"state": "on"}'
out2="$(fb --repo "$R2" check)"; rc2=$?
[ "$rc2" -eq 1 ] && echo "$out2" | grep -q "VERDICT: REFUSE" \
  && ok "4b. identical failing preflight but state=on -> REFUSE, not WAIT (state changes the verdict, not the checks)" \
  || bad "4b. rc=$rc2 out='$out2'"

# ── 5. no subcommand's output ever contains the secret VALUE ────────────────
R="$(fresh_repo)"
SECRET="sk-VERY-SECRET-000111222-DO-NOT-LEAK"
export HMD_FB_SECRET_ENV="$SECRET"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "HMD_FB_SECRET_ENV",
  "endpoint": "http://127.0.0.1:20128",
  "tier1_disabled": true,
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
combined="$(fb --repo "$R" status 2>&1; fb --repo "$R" status --json 2>&1; fb --repo "$R" check 2>&1; fb --repo "$R" where 2>&1; fb --repo "$R" set on 2>&1; fb --repo "$R" set auto 2>&1; fb --repo "$R" set off 2>&1)"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
if printf '%s' "$combined" | grep -qF -- "$SECRET"; then
  bad "5. SECRET VALUE LEAKED into subcommand output"
else
  ok "5. no subcommand's combined output contains the operator key value"
fi
unset HMD_FB_SECRET_ENV

# ── 6. where prints the exact expected config path ───────────────────────────
R="$(fresh_repo)"
out="$(fb --repo "$R" where)"
[ "$out" = "$(cfg_path "$R")" ] && ok "6. where prints the exact expected config path" \
  || bad "6. got '$out', want '$(cfg_path "$R")'"

# ── 7. set persists across separate process invocations ─────────────────────
R="$(fresh_repo)"
fb --repo "$R" set on >/dev/null
out="$(fb --repo "$R" status)"
echo "$out" | grep -Eq 'state:[[:space:]]+on' \
  && ok "7. set on persists to disk and is read back by a fresh invocation" \
  || bad "7. got: $out"

# ── 8. set rejects an invalid value; never breaks the caller unless --strict ─
R="$(fresh_repo)"
out="$(fb --repo "$R" set nonsense 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "invalid" \
  && ok "8a. set <bad-value>, no --strict -> exit 0, reason reported (never-fail-caller)" \
  || bad "8a. rc=$rc out='$out'"
fb --repo "$R" --strict set nonsense >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "8b. same call WITH --strict -> nonzero (opt-in strictness)" \
  || bad "8b. rc=$rc, want nonzero"

# ── 9. endpoint locality: a non-loopback endpoint fails with its own reason ──
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://93.184.216.34:8080",
  "tier1_disabled": true,
  "target_provider": "self-hosted-mixtral"
}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*endpoint_local" && echo "$out" | grep -qi "loopback" \
  && ok "9. non-loopback endpoint -> distinct 'not a loopback address' reason" \
  || bad "9. got: $out"
unset HMD_FB_TEST_KEY

# ── 10. ToS deny-list blocks a builtin-flagged provider, names it ───────────
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "tier1_disabled": true,
  "target_provider": "groq"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
echo "$out" | grep -q "FAIL.*target_provider_allowed" && echo "$out" | grep -q "groq" \
  && ok "10. builtin ToS-flagged provider (groq) -> refused and named in the reason" \
  || bad "10. got: $out"
unset HMD_FB_TEST_KEY

# ── 11. operator_key_env naming a Claude/Anthropic var is itself refused ────
R="$(fresh_repo)"
export ANTHROPIC_API_KEY="not-actually-used-for-anything-here"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "ANTHROPIC_API_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "tier1_disabled": true,
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
echo "$out" | grep -q "FAIL.*operator_key" && echo "$out" | grep -qi "Claude/Anthropic" \
  && ok "11. operator_key_env='ANTHROPIC_API_KEY' -> refused, Claude Code OAuth reuse named as the reason" \
  || bad "11. got: $out"
unset ANTHROPIC_API_KEY

# ── 12. fully-passing config -> ROUTE (the tool CAN say yes, not just always no) ─
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
write_cfg "$R" '{
  "state": "on",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "tier1_disabled": true,
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" \
  && ok "12. every check green -> ROUTE (exit 0)" \
  || bad "12. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY

# ── 13. many simultaneous failures still produce distinct, separate reasons ──
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
out="$(fb --repo "$R" check)"
n_fail_lines=$(printf '%s\n' "$out" | grep -c '\[FAIL\]')
distinct_reasons=$(printf '%s\n' "$out" | grep '\[FAIL\]' | sed -E 's/^[^-]*-- //' | sort -u | wc -l | tr -d ' ')
[ "$n_fail_lines" -ge 4 ] && [ "$distinct_reasons" -ge 4 ] \
  && ok "13. an all-defaults config fails >=4 checks with >=4 DISTINCT reason strings (no generic 'preflight failed')" \
  || bad "13. n_fail_lines=$n_fail_lines distinct_reasons=$distinct_reasons out='$out'"

echo "--------------------------------------------------------------------"
printf 'heimdall-fallback: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

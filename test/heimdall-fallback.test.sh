#!/usr/bin/env bash
# heimdall-fallback.test.sh -- falsifiable coverage for bin/heimdall-fallback,
# the quota-exhaustion fallback POLICY gate (state/config/safety only -- no
# transport; see the tool's own header for the full safety boundary).
#
# THE HONEST LIMIT under test: this suite proves the GATE computes the right
# verdict for a given config -- it cannot and does not prove OmniRoute itself
# is safe to talk to (explicitly out of scope; see
# docs/analysis/2026-08-23-omniroute-assessment.md and
# docs/analysis/2026-08-25-omniroute-credential-isolation.md). No case below
# ever makes a real network syscall: HEIMDALL_FALLBACK_ASSUME_REACHABLE is set
# to a known value for the whole suite and only ever overridden-then-restored
# within a single section.
#
# HERMETIC: every case gets its own mktemp repo dir passed via --repo; no
# case ever touches a real ~/.heimdall or a real project config. The same
# extends to OmniRoute's own DB and CLIProxyAPI's own config dir: DATA_DIR and
# CLIPROXYAPI_CONFIG_DIR are pinned to nonexistent sentinel paths for the
# whole suite (below) so a default-config case never resolves to this
# machine's real ~/.omniroute or ~/.cli-proxy-api; sections that need real DB
# content point the `omniroute_db_path` / `cliproxyapi_dir` config fields at a
# suite-local sqlite fixture instead, which always takes priority over the
# env-var sentinel.
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
# make_omniroute_db <db_file> [provider] [mode]
# Creates OmniRoute's provider_connections table (provider, mode columns) in a
# fresh/existing sqlite file -- CREATE TABLE IF NOT EXISTS so repeated calls
# against the same file can layer multiple rows. Schema shape sourced from
# docs/analysis/2026-08-25-omniroute-credential-isolation.md S3 (the "SELECT
# provider, COUNT(*) ... GROUP BY provider" query) plus S1a/residual-risk-2's
# "mode: cliproxyapi" vocabulary for the mode column -- the audit did not
# quote a full CREATE TABLE, so `mode` here is this suite's own
# best-documented-signal fixture, matching exactly what bin/heimdall-fallback
# itself queries.
make_omniroute_db() {
  local db="$1" provider="${2:-}" mode="${3:-}"
  python3 -c "
import sqlite3, sys
db, provider, mode = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db)
conn.execute('CREATE TABLE IF NOT EXISTS provider_connections (id INTEGER PRIMARY KEY, provider TEXT, mode TEXT)')
if provider:
    conn.execute('INSERT INTO provider_connections (provider, mode) VALUES (?, ?)', (provider, mode or None))
conn.commit()
conn.close()
" "$db" "$provider" "$mode"
}

# Hermetic default for the whole suite: nothing here is actually listening on
# a local gateway port, so "not reachable" is the honest baseline. Sections
# that need a PASSING reachability check override to "1" for their own scope
# and restore "0" immediately after -- see sections 3, 10, 11, 12.
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
# Sentinel, never-real paths so a case with no explicit omniroute_db_path /
# cliproxyapi_dir config field can never resolve to this machine's actual
# OmniRoute install (see file header). Sections that need real DB/dir content
# set the config field explicitly, which always outranks these env vars.
export DATA_DIR="/nonexistent-heimdall-fallback-test-datadir"
export CLIPROXYAPI_CONFIG_DIR="/nonexistent-heimdall-fallback-test-cliproxyapi"
# Baseline hermetic unset: a real operator shell could plausibly have either
# of these set for actual OmniRoute/Claude Code use, which would silently
# change several sections' expected verdicts.
unset ANTHROPIC_MODEL
unset OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS

# Shared, read-only fixture DBs -- the tool only ever opens these via
# mode=ro, so reuse across many sections below is safe (nothing mutates
# them after creation here).
CLEAN_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-clean.XXXXXX")"
make_omniroute_db "$CLEAN_DB"
TIER1_CLAUDE_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-t1claude.XXXXXX")"
make_omniroute_db "$TIER1_CLAUDE_DB" claude
TIER1_CLAUDEWEB_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-t1web.XXXXXX")"
make_omniroute_db "$TIER1_CLAUDEWEB_DB" claude-web
SIDECAR_MODE_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-sidecar.XXXXXX")"
make_omniroute_db "$SIDECAR_MODE_DB" local-sidecar cliproxyapi
MALFORMED_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-malformed.XXXXXX")"
printf 'not a sqlite database, just text' > "$MALFORMED_DB"

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
write_cfg "$R" '{"state": "on", "mitm_enabled": true, "operator_key_env": "X", "target_provider": "y", "endpoint": "http://127.0.0.1:20128"}'
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

# ── 3. falsifier (a): fixture DB CONTAINS a claude row -> REFUSE, Tier-1 reason ─
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="fake-operator-key-value"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "on",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$TIER1_CLAUDE_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" && echo "$out" | grep -qi "Tier-1" \
  && echo "$out" | grep -q "FAIL.*tier1_credential_absent" && echo "$out" | grep -q "claude" \
  && ok "3. falsifier (a): DB has a 'claude' provider_connections row -> REFUSE, Tier-1 reason names it" \
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
  "omniroute_db_path": "'"$CLEAN_DB"'",
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
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://93.184.216.34:8080",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
out="$(fb --repo "$R" check)"
unset ANTHROPIC_MODEL
echo "$out" | grep -q "FAIL.*endpoint_local" && echo "$out" | grep -qi "loopback" \
  && ok "9. non-loopback endpoint -> distinct 'not a loopback address' reason" \
  || bad "9. got: $out"
unset HMD_FB_TEST_KEY

# ── 10. ToS deny-list blocks a builtin-flagged provider, names it ───────────
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "groq"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
echo "$out" | grep -q "FAIL.*target_provider_allowed" && echo "$out" | grep -q "groq" \
  && ok "10. builtin ToS-flagged provider (groq) -> refused and named in the reason" \
  || bad "10. got: $out"
unset HMD_FB_TEST_KEY

# ── 11. operator_key_env naming a Claude/Anthropic var is itself refused ────
R="$(fresh_repo)"
export ANTHROPIC_API_KEY="not-actually-used-for-anything-here"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "ANTHROPIC_API_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
echo "$out" | grep -q "FAIL.*operator_key" && echo "$out" | grep -qi "Claude/Anthropic" \
  && ok "11. operator_key_env='ANTHROPIC_API_KEY' -> refused, Claude Code OAuth reuse named as the reason" \
  || bad "11. got: $out"
unset ANTHROPIC_API_KEY

# ── 12. fully-passing config -> ROUTE (the tool CAN say yes, not just always no) ─
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "on",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" \
  && ok "12. every check green, including all four Tier-1 checks -> ROUTE (exit 0)" \
  || bad "12. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY

# ── 13. many simultaneous failures still produce distinct, separate reasons ──
R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "/nonexistent-heimdall-fallback-test/omniroute/storage.sqlite",
  "cliproxyapi_dir": "/nonexistent-heimdall-fallback-test/cli-proxy-api"
}'
out="$(fb --repo "$R" check)"
n_fail_lines=$(printf '%s\n' "$out" | grep -c '\[FAIL\]')
distinct_reasons=$(printf '%s\n' "$out" | grep '\[FAIL\]' | sed -E 's/^[^-]*-- //' | sort -u | wc -l | tr -d ' ')
[ "$n_fail_lines" -ge 4 ] && [ "$distinct_reasons" -ge 4 ] \
  && ok "13. an all-defaults config fails >=4 checks with >=4 DISTINCT reason strings (no generic 'preflight failed')" \
  || bad "13. n_fail_lines=$n_fail_lines distinct_reasons=$distinct_reasons out='$out'"

# ── 14. falsifier (b): clean DB (no Tier-1 row) -> tier1_credential_absent PASSES ─
R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "cliproxyapi_dir": "/nonexistent-heimdall-fallback-test/cli-proxy-api"
}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK.*tier1_credential_absent" && ! echo "$out" | grep -q "FAIL.*tier1_credential_absent" \
  && ok "14. falsifier (b): DB has no Tier-1 row -> tier1_credential_absent passes in isolation" \
  || bad "14. got: $out"

# ── 15. falsifier (c): an absent or malformed OmniRoute DB FAILS, never a silent pass ─
R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "/nonexistent-heimdall-fallback-test/definitely-not-here.sqlite"
}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*tier1_credential_absent" && echo "$out" | grep -qi "not found" \
  && ok "15a. falsifier (c): absent DB -> tier1_credential_absent FAILS ('not found'), never a silent pass" \
  || bad "15a. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "'"$MALFORMED_DB"'"
}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*tier1_credential_absent" && echo "$out" | grep -qi "unreadable or malformed" \
  && ok "15b. falsifier (c): malformed (non-SQLite) DB file -> tier1_credential_absent FAILS, never a silent pass" \
  || bad "15b. got: $out"

# ── 16. falsifier (d): blockedProviders is never evidence, and its presence warns ─
R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "'"$TIER1_CLAUDE_DB"'",
  "blockedProviders": ["claude"]
}'
out="$(fb --repo "$R" check 2>&1)"
echo "$out" | grep -q "FAIL.*tier1_credential_absent" \
  && echo "$out" | grep -qi "blockedProviders" \
  && ok "16. falsifier (d): blockedProviders=[claude] does NOT satisfy tier1_credential_absent, and its presence is warned about" \
  || bad "16. got: $out"

# ── 17. anthropic_model_pinned: unset, bare, and prefixed ANTHROPIC_MODEL ───
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$CLEAN_DB"'"}'
unset ANTHROPIC_MODEL
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -qi "not set" \
  && ok "17a. ANTHROPIC_MODEL unset -> anthropic_model_pinned FAILS ('not set')" \
  || bad "17a. got: $out"

export ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -qi "no explicit provider/ prefix" \
  && ok "17b. bare claude-* id (no prefix) -> anthropic_model_pinned FAILS" \
  || bad "17b. got: $out"

export ANTHROPIC_MODEL="gpt-4o"
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" \
  && ok "17c. any unprefixed id (not just claude-*) -> anthropic_model_pinned FAILS" \
  || bad "17c. got: $out"

export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK.*anthropic_model_pinned" \
  && ok "17d. explicit provider/ prefix -> anthropic_model_pinned PASSES" \
  || bad "17d. got: $out"
unset ANTHROPIC_MODEL

# ── 18. prefer_claude_code_flag_off: the Tier-1 WIDENING knob must default off ─
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$CLEAN_DB"'"}'
unset OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK.*prefer_claude_code_flag_off" \
  && ok "18a. unset (default) -> prefer_claude_code_flag_off PASSES" \
  || bad "18a. got: $out"

export OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS=1
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*prefer_claude_code_flag_off" && echo "$out" | grep -qi "WIDENING" \
  && ok "18b. set to '1' -> prefer_claude_code_flag_off FAILS, named as a WIDENING knob" \
  || bad "18b. got: $out"

export OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS=false
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK.*prefer_claude_code_flag_off" \
  && ok "18c. explicit 'false' -> prefer_claude_code_flag_off still PASSES" \
  || bad "18c. got: $out"
unset OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS

# ── 19. no_delegated_sidecar: installed dir, DB-mode row, and the clean case ─
R="$(fresh_repo)"
SIDECAR_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hmd-fallback-test-sidecardir.XXXXXX")"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "cliproxyapi_dir": "'"$SIDECAR_DIR"'"
}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*no_delegated_sidecar" && echo "$out" | grep -qi "CLIProxyAPI directory exists" \
  && ok "19a. CLIProxyAPI directory installed -> no_delegated_sidecar FAILS" \
  || bad "19a. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "'"$SIDECAR_MODE_DB"'",
  "cliproxyapi_dir": "/nonexistent-heimdall-fallback-test/cli-proxy-api"
}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*no_delegated_sidecar" && echo "$out" | grep -qi "delegated sidecar" \
  && ok "19b. no sidecar dir, but DB has a cliproxyapi-mode connection row -> no_delegated_sidecar FAILS" \
  || bad "19b. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "cliproxyapi_dir": "/nonexistent-heimdall-fallback-test/cli-proxy-api"
}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK.*no_delegated_sidecar" \
  && ok "19c. no sidecar dir, clean DB -> no_delegated_sidecar PASSES" \
  || bad "19c. got: $out"

echo "--------------------------------------------------------------------"
printf 'heimdall-fallback: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

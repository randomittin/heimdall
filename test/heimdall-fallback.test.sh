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
# Creates the two OmniRoute tables this tool queries in a fresh/existing
# sqlite file -- CREATE TABLE IF NOT EXISTS so repeated calls against the
# same file can layer multiple rows.
#   provider_connections (id, provider, mode): shape sourced from
#     docs/analysis/2026-08-25-omniroute-credential-isolation.md S3 (the
#     "SELECT provider, COUNT(*) ... GROUP BY provider" query). Its own
#     `mode` column here is this suite's pre-existing fixture convenience,
#     NOT queried by bin/heimdall-fallback for anything (see below).
#   upstream_proxy_config (id, provider_id, mode, fallback_backend): the
#     REAL delegated-sidecar table, columns READ via PRAGMA table_info
#     against a live OmniRoute 3.8.51 (d82b682) install, not inferred.
#     Always created empty here (0 rows), matching that live install's own
#     state; a test that needs a delegating row calls add_proxy_config_row
#     (below) afterward. provider_connections has NO 'mode' column on a real
#     install (confirmed: 46 real columns, zero named 'mode') -- an earlier
#     version of bin/heimdall-fallback's no_delegated_sidecar check queried
#     it there by mistake and always passed vacuously; fixed to query
#     upstream_proxy_config instead (see SIDECAR_DELEGATING_MODES).
make_omniroute_db() {
  local db="$1" provider="${2:-}" mode="${3:-}"
  python3 -c "
import sqlite3, sys
db, provider, mode = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db)
conn.execute('CREATE TABLE IF NOT EXISTS provider_connections (id INTEGER PRIMARY KEY, provider TEXT, mode TEXT)')
conn.execute(\"CREATE TABLE IF NOT EXISTS upstream_proxy_config (id INTEGER PRIMARY KEY, provider_id TEXT, mode TEXT NOT NULL DEFAULT 'native', fallback_backend TEXT NOT NULL DEFAULT 'cliproxyapi')\")
if provider:
    conn.execute('INSERT INTO provider_connections (provider, mode) VALUES (?, ?)', (provider, mode or None))
conn.commit()
conn.close()
" "$db" "$provider" "$mode"
}

# add_proxy_config_row <db_file> <provider_id> <mode> [fallback_backend]
# Inserts one upstream_proxy_config row -- for the delegated-sidecar-in-DB
# falsifiers. `mode` vocabulary ('native'|'cliproxyapi'|'dario'|'fallback')
# and the fallback_backend column are sourced verbatim from the live
# install's own src/lib/db/migrations/138_dario_fallback_backend.sql: "mode
# is a free TEXT column already ('native' | 'cliproxyapi' | 'dario' |
# 'fallback')"; fallback_backend selects which embedded proxy (cliproxyapi or
# dario, default 'cliproxyapi') handles the retry leg when mode='fallback'.
add_proxy_config_row() {
  local db="$1" provider_id="$2" mode="$3" backend="${4:-cliproxyapi}"
  python3 -c "
import sqlite3, sys
db, provider_id, mode, backend = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
conn = sqlite3.connect(db)
conn.execute(\"CREATE TABLE IF NOT EXISTS upstream_proxy_config (id INTEGER PRIMARY KEY, provider_id TEXT, mode TEXT NOT NULL DEFAULT 'native', fallback_backend TEXT NOT NULL DEFAULT 'cliproxyapi')\")
conn.execute('INSERT INTO upstream_proxy_config (provider_id, mode, fallback_backend) VALUES (?, ?, ?)', (provider_id, mode, backend))
conn.commit()
conn.close()
" "$db" "$provider_id" "$mode" "$backend"
}

# make_fake_session_usage <json-body>
# Writes a standalone, directly-executable fake heimdall-session-usage that
# ignores every argument and just prints the given JSON body to stdout,
# exit 0 -- for HEIMDALL_FALLBACK_SESSION_USAGE_BIN, the test-only override
# seam bin/heimdall-fallback's own _session_pre_exhaustion_verdict() reads
# (mirrors HEIMDALL_FALLBACK_ASSUME_REACHABLE's existing pattern above).
# Exit 0 is deliberate and unconditional: heimdall-fallback's real
# consultation only trusts stdout JSON, never the exit code, since the real
# tool's own `status` exits 1 for a genuine CROSSED verdict -- that is not an
# error, so a fixture that only ever exits 0 cannot accidentally exercise
# the wrong (exit-code-driven) path.
make_fake_session_usage() {
  local json="$1"
  local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/hmd-fallback-test-fake-su.XXXXXX")"
  printf '%s' "$json" > "$dir/body.json"
  {
    printf '#!/bin/sh\n'
    printf 'cat "%s/body.json"\n' "$dir"
  } > "$dir/heimdall-session-usage"
  chmod +x "$dir/heimdall-session-usage"
  printf '%s/heimdall-session-usage' "$dir"
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
# Nothing outside this suite ever sets this; a real operator shell has never
# heard of it, but unset it anyway to match the hermetic style above.
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN

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
make_omniroute_db "$SIDECAR_MODE_DB"
add_proxy_config_row "$SIDECAR_MODE_DB" local-sidecar cliproxyapi
NO_PROXY_CONFIG_TABLE_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-noproxytable.XXXXXX")"
python3 -c "
import sqlite3
conn = sqlite3.connect('$NO_PROXY_CONFIG_TABLE_DB')
conn.execute('CREATE TABLE provider_connections (id INTEGER PRIMARY KEY, provider TEXT, mode TEXT)')
conn.commit()
conn.close()
"
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

# ── 10. operator-configured tos_flagged_providers entry blocks a provider,
# names it. UPDATED 2026-08-26: BUILTIN_TOS_FLAGGED_PROVIDERS is now EMPTY by
# design (owner decision -- see bin/heimdall-fallback's own comment on that
# set), so 'groq' is no longer built-in-denied; this now proves the
# OPERATOR-CONFIGURABLE override mechanism instead, which survives that
# change untouched (acceptance criterion (b)). ──────────────────────────────
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "groq",
  "tos_flagged_providers": ["groq"]
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
echo "$out" | grep -q "FAIL.*target_provider_allowed" && echo "$out" | grep -q "groq" \
  && ok "10. operator-configured tos_flagged_providers entry (groq) -> refused and named in the reason (built-in deny list is empty by default since 2026-08-26; the override mechanism still works)" \
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

# ── 20. NEW: state=on is a CAPABILITY-TIER decision -- haiku-tier task ROUTES ─
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
out="$(fb --repo "$R" check --tier haiku)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" \
  && ok "20. falsifier (a): state=on + --tier haiku + passing preflight -> ROUTE" \
  || bad "20. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY

# ── 21. NEW: state=on + sonnet-tier or adjudication task -> does NOT route ───
for T in sonnet opus reviewer verifier security-auditor; do
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
  out="$(fb --repo "$R" check --tier "$T")"; rc=$?
  export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
  unset ANTHROPIC_MODEL
  [ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" && echo "$out" | grep -q "FAIL.*tier_eligible" \
    && ok "21. falsifier (b): state=on + --tier $T + passing preflight -> REFUSE (not low-level)" \
    || bad "21. tier=$T rc=$rc out='$out'"
  unset HMD_FB_TEST_KEY
done

# ── 22. NEW: state=switch routes EVERYTHING, tier-blind, only if preflight passes ─
for T in "" haiku sonnet opus reviewer; do
  R="$(fresh_repo)"
  export HMD_FB_TEST_KEY="x"
  export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
  write_cfg "$R" '{
    "state": "switch",
    "operator_key_env": "HMD_FB_TEST_KEY",
    "endpoint": "http://127.0.0.1:20128",
    "omniroute_db_path": "'"$CLEAN_DB"'",
    "target_provider": "self-hosted-mixtral"
  }'
  export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
  if [ -n "$T" ]; then
    out="$(fb --repo "$R" check --tier "$T")"; rc=$?
  else
    out="$(fb --repo "$R" check)"; rc=$?
  fi
  export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
  unset ANTHROPIC_MODEL
  [ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" \
    && ok "22. falsifier (c): state=switch + tier='$T' + passing preflight -> ROUTE (tier-blind)" \
    || bad "22. tier='$T' rc=$rc out='$out'"
  unset HMD_FB_TEST_KEY
done

# ── 23. NEW: state=switch NEVER bypasses safety -- failing Tier-1 -> REFUSE ──
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "switch",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$TIER1_CLAUDE_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
out_tier="$(fb --repo "$R" check --tier haiku)"; rc_tier=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" && echo "$out" | grep -q "FAIL.*tier1_credential_absent" \
  && [ "$rc_tier" -eq 1 ] && echo "$out_tier" | grep -q "VERDICT: REFUSE" \
  && ok "23. falsifier (d): state=switch + failing Tier-1 check -> still REFUSE (no state bypasses safety)" \
  || bad "23. rc=$rc rc_tier=$rc_tier out='$out'"
unset HMD_FB_TEST_KEY

# ── 24. NEW: falsifier (e): a corrupt or near-miss state string still reads off ─
R="$(fresh_repo)"
write_cfg "$R" '{"state": "Switch"}'
out="$(fb --repo "$R" status)"
echo "$out" | grep -Eq 'state:[[:space:]]+off' \
  && ok "24a. falsifier (e): wrong-case 'Switch' -> reads off, never switch" \
  || bad "24a. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "switching"}'
out="$(fb --repo "$R" status)"
echo "$out" | grep -Eq 'state:[[:space:]]+off' \
  && ok "24b. falsifier (e): near-miss 'switching' -> reads off, never switch" \
  || bad "24b. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "switch", "mitm_enabled": true}'
out="$(fb --repo "$R" status)"
fb --repo "$R" check >/dev/null 2>&1; rc=$?
echo "$out" | grep -Eq 'state:[[:space:]]+off' && echo "$out" | grep -qi "forbidden" && [ "$rc" -ne 0 ] \
  && ok "24c. falsifier (e): state=switch + forbidden MITM key -> forced to off, check never ROUTEs" \
  || bad "24c. got: $out (check rc=$rc)"

# ── 25. NEW: backward compat -- bare `check` (no --tier) under on stays tier-blind ─
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
  && ok "25. backward compat: bare check (no --tier) under on + passing preflight -> ROUTE, exactly like before this change (bin/lib/issue_loop.py's own call shape)" \
  || bad "25. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY

# ── 26. NEW: set switch persists across invocations ─────────────────────────
R="$(fresh_repo)"
fb --repo "$R" set switch >/dev/null
out="$(fb --repo "$R" status)"
echo "$out" | grep -Eq 'state:[[:space:]]+switch' \
  && ok "26. set switch persists to disk and is read back by a fresh invocation" \
  || bad "26. got: $out"

# ── 27. NEW: switch is UNMISTAKABLE in both status renderings and in check ───
R="$(fresh_repo)"
write_cfg "$R" '{"state": "switch"}'
out_text="$(fb --repo "$R" status)"
out_json="$(fb --repo "$R" status --json)"
echo "$out_text" | grep -q "SWITCH" \
  && printf '%s' "$out_json" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('full_switch') is True else 1)" \
  && ok "27a. status text loudly flags switch (contains 'SWITCH'); status --json carries full_switch:true" \
  || bad "27a. text='$out_text' json='$out_json'"

R2="$(fresh_repo)"
write_cfg "$R2" '{"state": "on"}'
out_text2="$(fb --repo "$R2" status)"
out_json2="$(fb --repo "$R2" status --json)"
! echo "$out_text2" | grep -q "SWITCH" \
  && printf '%s' "$out_json2" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('full_switch') is False else 1)" \
  && ok "27b. state=on -> no SWITCH banner in text, full_switch:false in json (no false alarm)" \
  || bad "27b. text='$out_text2' json='$out_json2'"

R3="$(fresh_repo)"
write_cfg "$R3" '{"state": "switch"}'
out_check="$(fb --repo "$R3" check 2>&1)"
echo "$out_check" | grep -q "SWITCH" \
  && ok "27c. check's own VERDICT line also loudly flags switch" \
  || bad "27c. got: $out_check"

# ── 28. NEW: an invalid --tier value is rejected the same way set nonsense is ─
R="$(fresh_repo)"
out="$(fb --repo "$R" check --tier nonsense-tier 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "28a. check --tier <bad-value>, no --strict -> exit 0 (never-fail-caller)" \
  || bad "28a. rc=$rc out='$out'"
fb --repo "$R" --strict check --tier nonsense-tier >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "28b. same call WITH --strict -> nonzero (opt-in strictness)" \
  || bad "28b. rc=$rc, want nonzero"

# ── 29. NEW: no-auth pinned provider needs NO operator key -> reaches ROUTE ──
R="$(fresh_repo)"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "on",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "opencode"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" && echo "$out" | grep -q "OK.*operator_key" && echo "$out" | grep -qi "keyless" \
  && ok "29. no-auth target_provider ('opencode') with NO key configured -> ROUTE, operator_key passes and says why" \
  || bad "29. rc=$rc out='$out'"

# ── 30. NEW: a key-REQUIRING provider with no key configured still REFUSEs ──
R="$(fresh_repo)"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "on",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" && echo "$out" | grep -q "FAIL.*operator_key" \
  && ok "30. key-requiring target_provider with NO key configured -> REFUSE (operator_key fails, unaffected by no-auth logic)" \
  || bad "30. rc=$rc out='$out'"

# ── 31. no-auth does NOT weaken target_provider_allowed's separate ToS gate.
# UPDATED 2026-08-26: the built-in deny list is now empty by design, so
# 'duckduckgo-web' needs an explicit operator tos_flagged_providers entry to
# be denied here -- this now proves BOTH that the override mechanism works
# AND that no-auth status never weakens it, on the same provider. ──────────
R="$(fresh_repo)"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "on",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "duckduckgo-web",
  "tos_flagged_providers": ["duckduckgo-web"]
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" && echo "$out" | grep -q "OK.*operator_key" \
  && echo "$out" | grep -q "FAIL.*target_provider_allowed" \
  && ok "31. no-auth provider that is operator-deny-listed ('duckduckgo-web' in tos_flagged_providers) -> operator_key passes keyless, but target_provider_allowed still REFUSEs independently" \
  || bad "31. rc=$rc out='$out'"

# ── 32. NEW: operator can DECLARE an additional no-auth provider via config ──
R="$(fresh_repo)"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "on",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "my-future-noauth-provider",
  "noauth_providers": ["my-future-noauth-provider"]
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" && echo "$out" | grep -q "OK.*operator_key" \
  && ok "32a. operator-declared noauth_providers addition -> operator_key passes keyless for a provider not in the built-in list" \
  || bad "32a. rc=$rc out='$out'"

R2="$(fresh_repo)"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R2" '{
  "state": "on",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "my-future-noauth-provider"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out2="$(fb --repo "$R2" check)"; rc2=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc2" -eq 1 ] && echo "$out2" | grep -q "FAIL.*operator_key" \
  && ok "32b. WITHOUT the config declaration, the same undeclared provider still requires a key (no guessing)" \
  || bad "32b. rc=$rc2 out='$out2'"

# ── 33. NEW: no-auth provider still refuses a Claude/Anthropic-named key_env ─
R="$(fresh_repo)"
export ANTHROPIC_API_KEY="not-actually-used"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "on",
  "operator_key_env": "ANTHROPIC_API_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "opencode"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
unset ANTHROPIC_API_KEY
[ "$rc" -eq 1 ] && echo "$out" | grep -q "FAIL.*operator_key" && echo "$out" | grep -qi "Claude/Anthropic" \
  && ok "33. no-auth target_provider does NOT waive the Claude/Anthropic operator_key_env ban" \
  || bad "33. rc=$rc out='$out'"

# ── 34. NEW (schema fix): correct table is upstream_proxy_config, not
# provider_connections -- a live OmniRoute 3.8.51 (d82b682) install confirmed
# provider_connections has NO 'mode' column (46 real columns, zero named
# 'mode'); mode/fallback_backend live on upstream_proxy_config
# (src/lib/db/migrations/138_dario_fallback_backend.sql). These sections
# prove the CORRECTED query's behavior directly (falsifiers a/b/c/d).
#
# 34c was originally "table missing -> FAILS closed", full stop. Reverted:
# test/issue-loop-claude-fix-fallback.test.sh's case (c) -- a real caller's
# own hermetic fixture, not owned by this file and never to be edited to fit
# -- carries exactly this DB shape (provider_connections present,
# upstream_proxy_config absent, predating migration
# 138_dario_fallback_backend.sql) and legitimately expects a ROUTE verdict.
# A missing table backed by a readable provider_connections is a structural
# fact ("this schema has no delegated-sidecar concept"), not an unknown, so
# it now PASSES; 34d replaces the lost fail-closed coverage with a DB that is
# genuinely unreadable (provider_connections fails too), which still FAILS
# closed exactly as before. ─────────────────────────────────────────────────

R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$SIDECAR_MODE_DB"'"}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*no_delegated_sidecar" && echo "$out" | grep -qi "cliproxyapi"   && ok "34a. falsifier: upstream_proxy_config row with mode='cliproxyapi' (CORRECT table) -> no_delegated_sidecar FAILS"   || bad "34a. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$CLEAN_DB"'"}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK  .*no_delegated_sidecar"   && ok "34b. falsifier: upstream_proxy_config table present but EMPTY -> no_delegated_sidecar PASSES"   || bad "34b. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$NO_PROXY_CONFIG_TABLE_DB"'"}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK  .*no_delegated_sidecar" && echo "$out" | grep -qi "schema predates"   && ok "34c. falsifier: DB missing upstream_proxy_config table entirely, but provider_connections IS present/queryable -> PASSES (schema predates the delegated-sidecar migration; this is the exact DB shape issue-loop-claude-fix-fallback's own case (c) fixture depends on)"   || bad "34c. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$MALFORMED_DB"'"}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*no_delegated_sidecar" && echo "$out" | grep -qi "could not be queried for upstream_proxy_config"   && ok "34d. falsifier: a genuinely unreadable/malformed DB (provider_connections ALSO fails) -> no_delegated_sidecar still FAILS closed (never a silent pass)"   || bad "34d. got: $out"

# ── 35. NEW: mode='dario' is ALSO a delegated sidecar -- header point 1d
# already named Dario explicitly, but the OLD code's SIDECAR_CONNECTION_MODE
# was a single literal string ('cliproxyapi') that never covered it, even
# independent of the wrong-table bug. ───────────────────────────────────────
DARIO_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-dario.XXXXXX")"
make_omniroute_db "$DARIO_DB"
add_proxy_config_row "$DARIO_DB" some-provider dario
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$DARIO_DB"'"}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*no_delegated_sidecar" && echo "$out" | grep -qi "dario"   && ok "35. falsifier: upstream_proxy_config row with mode='dario' -> no_delegated_sidecar FAILS (names Dario)"   || bad "35. got: $out"

# ── 36. NEW: mode='fallback' delegates its retry leg to EITHER cliproxyapi
# or dario (migration 138's own wording) -- both backends still FAIL. ──────
FALLBACK_CPA_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-fallback-cpa.XXXXXX")"
make_omniroute_db "$FALLBACK_CPA_DB"
add_proxy_config_row "$FALLBACK_CPA_DB" some-provider fallback cliproxyapi
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$FALLBACK_CPA_DB"'"}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*no_delegated_sidecar"   && ok "36a. falsifier: mode='fallback', fallback_backend='cliproxyapi' -> no_delegated_sidecar FAILS"   || bad "36a. got: $out"

FALLBACK_DARIO_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-fallback-dario.XXXXXX")"
make_omniroute_db "$FALLBACK_DARIO_DB"
add_proxy_config_row "$FALLBACK_DARIO_DB" some-provider fallback dario
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$FALLBACK_DARIO_DB"'"}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*no_delegated_sidecar" && echo "$out" | grep -qi "dario"   && ok "36b. falsifier: mode='fallback', fallback_backend='dario' -> no_delegated_sidecar FAILS, names dario"   || bad "36b. got: $out"

# ── 37. NEW: an explicit mode='native' row is NOT a delegated sidecar ──────
NATIVE_DB="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-native.XXXXXX")"
make_omniroute_db "$NATIVE_DB"
add_proxy_config_row "$NATIVE_DB" some-provider native
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "omniroute_db_path": "'"$NATIVE_DB"'"}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK  .*no_delegated_sidecar"   && ok "37. an explicit mode='native' row is NOT a delegated sidecar -> PASSES"   || bad "37. got: $out"

# ── 38. NEW: state=auto + heimdall-session-usage reporting CROSSED, with a
# fully-passing preflight -> ROUTE. Under the 2026-08-26 correction, "crossed"
# is now a NECESSARY (not sufficient) second condition for ROUTE under auto,
# alongside the preflight -- this is the case where BOTH are met. Crossing
# pre-exhaustion still authorizes nothing BY ITSELF (see test 42: crossed with
# a failing preflight still WAITs); it is a gate ADDED to the existing checks,
# never a bypass of them. ───────────────────────────────────────────────────
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"crossed","crossed":true,"source":"budget"}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
unset HMD_FB_TEST_KEY
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" && echo "$out" | grep -qi "CROSSED" \
  && ok "38. auto + session-usage CROSSED + passing preflight -> still ROUTE, and check reports the crossed signal" \
  || bad "38. rc=$rc out='$out'"

# ── 39. NEW: heimdall-session-usage reporting "unknown" must never be treated
# as "under" -- proven by an explicit allow-list check (verdict == "crossed"),
# never a deny-list one (verdict != "under"): an "unknown" reading must never
# satisfy the crossed-only branch, and its own wording must never borrow a
# confirmed "under" reading's text it has no evidence for. ──────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"unknown","crossed":false,"source":"budget"}')"
out_unknown="$(fb --repo "$R" check)"
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
echo "$out_unknown" | grep -qi "CROSSED" \
  && bad "39a. an 'unknown' session-usage reading must NEVER trigger the crossed-only line: out='$out_unknown'" \
  || ok "39a. 'unknown' session-usage reading does not trigger the crossed-only line"

echo "$out_unknown" | grep -qi "could not be determined" \
  && ok "39b. 'unknown' gets its own honest wording (not silently folded into 'under')" \
  || bad "39b. out='$out_unknown'"

R2="$(fresh_repo)"
write_cfg "$R2" '{"state": "auto"}'
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"under","crossed":false,"source":"budget"}')"
out_under="$(fb --repo "$R2" check)"
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
echo "$out_under" | grep -qi "could not be determined" \
  && bad "39c. a genuine 'under' reading must not use unknown's 'could not be determined' wording: out='$out_under'" \
  || ok "39c. 'under' and 'unknown' produce genuinely distinct wording, not a shared fallback string"

# ── 40. NEW: a missing/broken heimdall-session-usage is best-effort ONLY --
# must never crash `check`, and must never change any of the OTHER checks'
# own ok/reason values. ──────────────────────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "/nonexistent-heimdall-fallback-test/omniroute/storage.sqlite",
  "cliproxyapi_dir": "/nonexistent-heimdall-fallback-test/cli-proxy-api"
}'
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="/nonexistent-heimdall-fallback-test/no-such-heimdall-session-usage"
out_missing="$(fb --repo "$R" check)"; rc_missing=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
[ "$rc_missing" -eq 2 ] && echo "$out_missing" | grep -q "VERDICT: WAIT" \
  && ok "40a. a missing heimdall-session-usage binary does not crash check -- same WAIT verdict as always" \
  || bad "40a. rc=$rc_missing out='$out_missing'"

export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage 'not valid json {{{')"
out_garbage="$(fb --repo "$R" check)"; rc_garbage=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
[ "$rc_garbage" -eq 2 ] && echo "$out_garbage" | grep -q "VERDICT: WAIT" \
  && ok "40b. malformed (non-JSON) heimdall-session-usage output does not crash check -- same WAIT verdict" \
  || bad "40b. rc=$rc_garbage out='$out_garbage'"

# The preflight FAIL lines themselves must be byte-identical regardless of
# whether the session-usage consultation succeeded, failed, or was missing --
# it is informational-only and structurally cannot touch run_preflight's own
# checks list.
baseline_fail_lines="$(printf '%s\n' "$out_missing" | grep '\[FAIL\]' | sort)"
garbage_fail_lines="$(printf '%s\n' "$out_garbage" | grep '\[FAIL\]' | sort)"
[ "$baseline_fail_lines" = "$garbage_fail_lines" ] && [ -n "$baseline_fail_lines" ] \
  && ok "40c. every OTHER check's FAIL line is byte-identical whether heimdall-session-usage is missing or returns garbage" \
  || bad "40c. baseline='$baseline_fail_lines' garbage='$garbage_fail_lines'"

# ── 41. NEW (2026-08-26 correction): state=auto + a FULLY PASSING preflight
# + heimdall-session-usage reporting "under" -> WAIT (exit 2), NOT ROUTE.
# This is the assertion that would have caught the original gap: before this
# correction, auto ROUTEd whenever the preflight passed, regardless of
# session_verdict, which made auto behave like switch instead of like an
# exhaustion reaction. Proves capacity remaining is now a real reason to
# WAIT rather than route off Anthropic while quota is still available. ──────
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"under","crossed":false,"source":"budget"}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
unset HMD_FB_TEST_KEY
[ "$rc" -eq 2 ] && echo "$out" | grep -q "VERDICT: WAIT" && ! echo "$out" | grep -q "VERDICT: ROUTE" \
  && ok "41. auto + passing preflight + session-usage UNDER -> WAIT, NOT route (capacity remains)" \
  || bad "41. got rc=$rc out='$out'"

# ── 42. NEW (2026-08-26 correction): state=auto + a FAILING preflight +
# heimdall-session-usage reporting CROSSED -> still WAIT, never ROUTE. Proves
# crossing the 95% threshold authorizes nothing on its own: even a confirmed
# pre-exhaustion signal cannot overcome a failing preflight check. ──────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"crossed","crossed":true,"source":"budget"}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
[ "$rc" -eq 2 ] && echo "$out" | grep -q "VERDICT: WAIT" && ! echo "$out" | grep -q "VERDICT: ROUTE" \
  && ok "42. auto + failing preflight + session-usage CROSSED -> still WAIT, crossing 95% authorizes nothing alone" \
  || bad "42. got rc=$rc out='$out'"

# ── 43. NEW (2026-08-26 correction): state=auto + a FULLY PASSING preflight
# + heimdall-session-usage reporting "unknown" -> WAIT (exit 2), NOT ROUTE.
# Complements test 39 (which used a non-passing-preflight config and only
# checked [INFO] wording): proves an unmeasurable signal does not
# accidentally enable ROUTE now that the gate is real. Fail-closed choice,
# reasoned in _verdict() itself (header point 11): waiting on "unknown" risks
# a delayed fallback if the measurement stays broken; routing on "unknown"
# risks burning fallback-provider capacity, and a cold/degraded cache, while
# Anthropic quota may still have been available. ────────────────────────────
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "auto",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"unknown","crossed":false,"source":"budget"}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
unset HMD_FB_TEST_KEY
[ "$rc" -eq 2 ] && echo "$out" | grep -q "VERDICT: WAIT" && ! echo "$out" | grep -q "VERDICT: ROUTE" \
  && ok "43. auto + passing preflight + session-usage UNKNOWN -> WAIT, NOT route (fails closed on unmeasurable capacity)" \
  || bad "43. got rc=$rc out='$out'"

# ── 44. NEW (2026-08-26 deny-list-emptied correction): a real provider name
# formerly on the built-in ToS deny list now PASSES target_provider_allowed
# by default, and the SAME provider can still be denied by an explicit
# operator tos_flagged_providers entry -- proving both halves of the owner's
# decision (empty default + working override) on one provider (acceptance
# criteria (a) and (b)). ─────────────────────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "mistral"
}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK.*target_provider_allowed" && ! echo "$out" | grep -q "FAIL.*target_provider_allowed" \
  && ok "44a. falsifier: a real provider ('mistral') formerly on the built-in deny list now PASSES target_provider_allowed by default" \
  || bad "44a. got: $out"

R2="$(fresh_repo)"
write_cfg "$R2" '{
  "state": "auto",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "mistral",
  "tos_flagged_providers": ["mistral"]
}'
out2="$(fb --repo "$R2" check)"
echo "$out2" | grep -q "FAIL.*target_provider_allowed" && echo "$out2" | grep -q "mistral" \
  && ok "44b. same provider ('mistral'), operator explicitly adds it to tos_flagged_providers -> target_provider_allowed FAILS, named (the override mechanism survives an empty built-in default)" \
  || bad "44b. got: $out2"

# ── 45. NEW: target_provider_allowed's completeness check is untouched by the
# deny-list change -- an EMPTY target_provider still FAILS, always (this is a
# completeness check, not a policy one; emptying the deny list must never
# turn "nothing pinned" into a pass) (acceptance criterion (c)). ────────────
R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "auto",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": ""
}'
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*target_provider_allowed" && echo "$out" | grep -qi "no target_provider configured" \
  && ok "45. empty target_provider still FAILS target_provider_allowed (completeness check, unaffected by the deny-list default)" \
  || bad "45. got: $out"

# ── 46. NEW (the one that matters): with the built-in deny list EMPTY, a
# config whose target_provider is a provider that USED TO be built-in-denied
# (so target_provider_allowed now legitimately PASSES) still gets REFUSEd
# overall, because the OmniRoute DB carries a live 'claude' Tier-1 row --
# proving tier1_credential_absent (the check that actually protects the
# operator's Anthropic account) is completely independent of, and unweakened
# by, this change (acceptance criterion (d)). ───────────────────────────────
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "on",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$TIER1_CLAUDE_DB"'",
  "target_provider": "mistral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" \
  && echo "$out" | grep -q "OK.*target_provider_allowed" \
  && echo "$out" | grep -q "FAIL.*tier1_credential_absent" && echo "$out" | grep -qi "claude" \
  && ok "46. falsifier: deny list empty (target_provider_allowed now PASSES for 'mistral'), but OmniRoute DB has a live 'claude' Tier-1 row -> still REFUSE overall, tier1_credential_absent FAILS independently" \
  || bad "46. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY

# ── 47. NEW: state=switch + failing Tier-1 check is still REFUSE, even for a
# target_provider the (now-empty) deny list would otherwise allow -- switch's
# tier-blind, always-try semantics never bypass the Tier-1 boundary (header
# point 9: switch changes WHAT routes, never whether a failing Tier-1 check
# is survivable). Complements test 23, which proves the same thing with a
# provider that was never on the old deny list either way (acceptance
# criterion (e)). ────────────────────────────────────────────────────────────
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "switch",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://127.0.0.1:20128",
  "omniroute_db_path": "'"$TIER1_CLAUDE_DB"'",
  "target_provider": "cohere"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" \
  && echo "$out" | grep -q "OK.*target_provider_allowed" \
  && echo "$out" | grep -q "FAIL.*tier1_credential_absent" \
  && ok "47. falsifier: state=switch + target_provider ('cohere') now allowed by the empty deny list + failing Tier-1 check -> still REFUSE (no state, and no deny-list change, ever bypasses Tier-1 safety)" \
  || bad "47. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY


# ── 48. NEW: `arm`, given nothing pre-configured, self-provisions a no-auth
# target_provider (deterministic: sorted() over the no-auth candidates picks
# "aihorde" first) with an EMPTY operator_key_env (never inventing a
# credential for a route that needs none -- header point 10/12), writes
# state, and -- once the two genuinely-manual preconditions arm cannot
# perform itself (ANTHROPIC_MODEL export, gateway already running) are
# simulated as already done by the operator -- its own trailing check
# reaches VERDICT: ROUTE. Proves arm's own self-provisioned fields are
# actually sufficient, not just present. ─────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{
  "omniroute_db_path": "'"$CLEAN_DB"'"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
out="$(fb --repo "$R" arm --state on)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
cfg_out="$(cat "$(cfg_path "$R")")"
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" \
  && echo "$cfg_out" | grep -q '"target_provider": "aihorde"' \
  && echo "$cfg_out" | grep -q '"operator_key_env": ""' \
  && ok "48. arm with nothing pre-configured self-provisions no-auth 'aihorde' with an EMPTY operator_key_env and reaches VERDICT: ROUTE end-to-end" \
  || bad "48. rc=$rc out='$out' cfg='$cfg_out'"

# ── 49. NEW: that same arm run's stdout carries the mandatory operator
# guidance for the ONE step arm genuinely cannot perform -- the export line
# (naming the provider it picked) and WHY a child process cannot do this for
# the parent shell -- and separately reports the gateway's real reachability
# (it does not start the gateway itself; see docs/analysis/2026-08-26-
# omniroute-gateway-start.md, owned by another agent, never this tool). ─────
R="$(fresh_repo)"
write_cfg "$R" '{
  "omniroute_db_path": "'"$CLEAN_DB"'"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
out="$(fb --repo "$R" arm --state on)"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
echo "$out" | grep -q "export ANTHROPIC_MODEL=aihorde/" \
  && echo "$out" | grep -qi "cannot" \
  && echo "$out" | grep -qi "gateway:.*reachable" \
  && ok "49. arm's own output names the unavoidable 'export ANTHROPIC_MODEL=' step, explains why arm itself cannot do it, and reports real gateway reachability" \
  || bad "49. out='$out'"

# ── 50. NEW: arm --provider naming a KEYED provider with no usable key
# anywhere (no operator_key_env configured, nothing to reuse) REFUSES --
# never invents a credential (header point 4/12) -- leaves the on-disk
# config byte-for-byte UNCHANGED, and its own trailing check still reports
# the true (REFUSE) verdict against that untouched config rather than going
# silent on the refusal. ─────────────────────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "off"}'
before="$(cat "$(cfg_path "$R")")"
out="$(fb --repo "$R" arm --provider mistral --state on)"; rc=$?
after="$(cat "$(cfg_path "$R")")"
[ "$rc" -eq 1 ] && echo "$out" | grep -q "REFUSED" && echo "$out" | grep -qi "never invents a credential" \
  && echo "$out" | grep -q "VERDICT: REFUSE" && [ "$before" = "$after" ] \
  && ok "50. arm --provider mistral (keyed, no usable key anywhere) REFUSES, config left byte-for-byte unchanged, trailing check still reports the true REFUSE verdict" \
  || bad "50. rc=$rc out='$out' before='$before' after='$after'"

# ── 51a/51b. NEW: arm --provider claude / claude-web REFUSE outright, naming
# the Tier-1 boundary -- arm enforces this itself (target_provider is never
# cross-checked against TIER1_DB_PROVIDERS anywhere else in this file; the
# Tier-1 boundary is otherwise only enforced by reading OmniRoute's own live
# DB, not by inspecting this config field -- see header point 12). ─────────
R="$(fresh_repo)"
out="$(fb --repo "$R" arm --provider claude)"; rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -qi "Tier-1" && echo "$out" | grep -q "REFUSED" \
  && ! grep -q '"target_provider": "claude"' "$(cfg_path "$R")" 2>/dev/null \
  && ok "51a. arm --provider claude REFUSES with Tier-1 language, never written to disk" \
  || bad "51a. rc=$rc out='$out'"

R="$(fresh_repo)"
out="$(fb --repo "$R" arm --provider claude-web)"; rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -qi "Tier-1" && echo "$out" | grep -q "REFUSED" \
  && ! grep -q '"target_provider": "claude-web"' "$(cfg_path "$R")" 2>/dev/null \
  && ok "51b. arm --provider claude-web REFUSES with Tier-1 language, never written to disk" \
  || bad "51b. rc=$rc out='$out'"

# ── 52. NEW (the defensive case): a config that ALREADY has target_provider
# "claude" on disk (e.g. a hand-edited or pre-existing bad config) -- arm run
# with NO --provider must never reuse or preserve it. It overwrites away
# from claude to a safe no-auth pick instead of refusing outright, which is
# the same self-provisioning promise as the nothing-configured case (48) --
# but the on-disk file must never again contain claude/claude-web as
# target_provider once arm has run. ─────────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{
  "state": "on",
  "target_provider": "claude",
  "omniroute_db_path": "'"$CLEAN_DB"'"
}'
out="$(fb --repo "$R" arm --state on)"
cfg_out="$(cat "$(cfg_path "$R")")"
echo "$cfg_out" | grep -q '"target_provider": "aihorde"' \
  && ! echo "$cfg_out" | grep -q '"target_provider": "claude"' \
  && ! echo "$cfg_out" | grep -q '"target_provider": "claude-web"' \
  && ok "52. arm never reuses/preserves a pre-existing claude target_provider -- overwrites it away to a safe no-auth pick" \
  || bad "52. out='$out' cfg='$cfg_out'"

# ── 53. NEW: repo-path disclosure (the second bug this work fixes) -- every
# subcommand that reads or writes THIS repo's config must say which repo's
# config it acted on. Two distinct repos must show two distinct, correct
# paths -- never a cached or shared value. ──────────────────────────────────
R1="$(fresh_repo)"
R2="$(fresh_repo)"
out_status1="$(fb --repo "$R1" status)"
out_status2="$(fb --repo "$R2" status)"
out_set1="$(fb --repo "$R1" set on)"
out_check1="$(fb --repo "$R1" check)"
echo "$out_status1" | grep -qF "$(cfg_path "$R1")" \
  && echo "$out_status2" | grep -qF "$(cfg_path "$R2")" \
  && ! echo "$out_status1" | grep -qF "$(cfg_path "$R2")" \
  && echo "$out_set1" | grep -qF "$(cfg_path "$R1")" \
  && echo "$out_check1" | grep -qF "$(cfg_path "$R1")" \
  && ok "53. status/set/check each print the exact resolved config path, correctly distinct per repo" \
  || bad "53. status1='$out_status1' status2='$out_status2' set1='$out_set1' check1='$out_check1'"

# ── 54. NEW: a partial, old-schema config (missing noauth_providers,
# omniroute_db_path, cliproxyapi_dir -- exactly this repo's own real
# .heimdall/fallback.json shape before this schema grew those keys) never
# crashes check (load_config's key-by-key defaulting fills every missing
# field from DEFAULT_CFG), and arm REUSES an already-valid existing
# target_provider from such a config rather than silently re-picking a
# different one -- "opencode" is deliberately NOT the deterministic
# first-sorted no-auth candidate ("aihorde" is), so reuse and re-pick are
# actually distinguishable outcomes here, not the same string by accident. ──
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "target_provider": "opencode"}'
out_check="$(fb --repo "$R" check 2>&1)"; rc_check=$?
[ "$rc_check" -ne 3 ] && ! echo "$out_check" | grep -qi "traceback" \
  && echo "$out_check" | grep -q "VERDICT:" \
  && ok "54a. a partial/old-schema config (missing noauth_providers/omniroute_db_path/cliproxyapi_dir) does not crash check" \
  || bad "54a. rc=$rc_check out='$out_check'"

out_arm="$(fb --repo "$R" arm --state on)"; rc_arm=$?
cfg_out="$(cat "$(cfg_path "$R")")"
[ "$rc_arm" -eq 1 ] && echo "$out_arm" | grep -q "target_provider:.*opencode" \
  && echo "$out_arm" | grep -q "VERDICT: REFUSE" \
  && echo "$cfg_out" | grep -q '"target_provider": "opencode"' \
  && ok "54b. arm reuses the already-valid, non-default 'opencode' target_provider from a partial/old-schema config rather than re-picking the deterministic default ('aihorde') -- its own trailing check REFUSEs (this partial config has no working omniroute_db_path), proving arm actually ran rather than silently no-op'ing" \
  || bad "54b. rc=$rc_arm out='$out_arm' cfg='$cfg_out'"

# ── 55. NEW: arm never touches OmniRoute's own DB -- it is a config-file
# writer only (header point 12's own "never adds a provider_connections row"
# promise). Point omniroute_db_path at a real fixture DB, run arm, and prove
# the fixture file is byte-for-byte unchanged (arm never even opens it --
# tier1_credential_absent, which DOES read it, runs read-only, inside the
# trailing check, and that is the only DB touch in this whole path). ────────
R="$(fresh_repo)"
write_cfg "$R" '{
  "omniroute_db_path": "'"$CLEAN_DB"'"
}'
db_before="$(md5 -q "$CLEAN_DB" 2>/dev/null || md5sum "$CLEAN_DB" | awk '{print $1}')"
fb --repo "$R" arm --state on >/dev/null
db_after="$(md5 -q "$CLEAN_DB" 2>/dev/null || md5sum "$CLEAN_DB" | awk '{print $1}')"
cfg_out="$(cat "$(cfg_path "$R")")"
[ "$db_before" = "$db_after" ] && echo "$cfg_out" | grep -q '"target_provider": "aihorde"' \
  && ok "55. arm never modifies OmniRoute's own DB -- fixture byte-for-byte unchanged after arm actually ran and wrote its self-picked target_provider" \
  || bad "55. db_before=$db_before db_after=$db_after cfg='$cfg_out'"

echo "--------------------------------------------------------------------"
printf 'heimdall-fallback: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

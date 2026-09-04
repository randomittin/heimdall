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

# run_capture <cmd...> -- runs a command with stdout and stderr captured
# SEPARATELY (never merged into one stream) into globals CAP_OUT/CAP_ERR/
# CAP_RC/CAP_OUT_BYTES. Load-bearing for base-url/token-file sections below:
# both commands' entire safety contract is "stdout stays byte-empty on every
# refusal", and a plain `$(cmd 2>&1)` capture can never prove that -- it would
# silently fold a stderr reason line into the very stream being asserted
# empty. CAP_OUT_BYTES is a real byte count via `wc -c` against the raw
# redirected file (not `${#CAP_OUT}`, which would undercount -- command
# substitution strips trailing newlines, so a lone "\n" on stdout would read
# as length 0 in CAP_OUT but is not actually zero bytes on the wire).
run_capture() {
  local outfile errfile
  outfile="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-stdout.XXXXXX")"
  errfile="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-stderr.XXXXXX")"
  "$@" >"$outfile" 2>"$errfile"
  CAP_RC=$?
  CAP_OUT="$(cat "$outfile")"
  CAP_OUT_BYTES="$(wc -c < "$outfile" | tr -d ' ')"
  CAP_ERR="$(cat "$errfile")"
  rm -f "$outfile" "$errfile"
}

# abs_tmpfile <name> -- mktemp a file and return its CANONICAL absolute path
# (cd+pwd on its dirname, exactly like fresh_repo() above and for the same
# documented reason: a trailing-slash TMPDIR -- the macOS norm fresh_repo()'s
# own comment calls out -- leaves a "//" in mktemp's raw output that Python's
# os.path.abspath (via normpath) collapses but a naive string does not. Only
# needed where a test compares the tool's printed path against this literal
# string; a test that only checks refuse/pass behavior can mktemp directly.
abs_tmpfile() {
  local raw dir
  raw="$(mktemp "${TMPDIR:-/tmp}/$1.XXXXXX")"
  dir="$(cd "$(dirname "$raw")" && pwd)"
  printf '%s/%s' "$dir" "$(basename "$raw")"
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
# ── 58. NEW: the usability ranking is LOAD-BEARING, proven on the one input
# where it can actually change the outcome. Test 56 above is honest but has no
# teeth today: `noauth_providers` is additions-only (config can never remove a
# built-in), so "aihorde" is always in the candidate set, and it happens to win
# BOTH alphabetically and on rank -- so deleting the ranking entirely leaves
# test 56 passing. Mutation-verified: with `key=` stripped from the candidate
# sort, tests 48/49/52/54b/56 all still pass and only THIS test fails.
# The reachable path where the two orders diverge is an operator denying the
# default pick: with aihorde in tos_flagged_providers, plain alphabetical lands
# on "auggie" (isLocalCli:true + hasFree:false -- needs a binary installed and
# `auggie login` run, so not keyless at all), while the ranking skips every
# rank-2 local-CLI entry. ───────────────────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"tos_flagged_providers": ["aihorde"]}'
fb --repo "$R" arm >/dev/null
picked="$(sed -n 's/.*"target_provider": "\([^"]*\)".*/\1/p' "$(cfg_path "$R")")"
case "$picked" in
  aihorde)
    bad "58. arm picked the operator-DENIED provider 'aihorde' -- tos_flagged_providers was ignored by the candidate filter" ;;
  auggie|zcode|codex-app-server|devin-cli-agentic|veoaifree-web)
    bad "58. with the default pick denied, arm fell through to '$picked' -- the exact plain-alphabetical answer. The usability ranking is not being applied to the candidate sort." ;;
  "")
    bad "58. arm wrote no target_provider at all with the default pick denied" ;;
  *)
    ok "58. with the default pick denied, arm ranked past every local-CLI/video entry to '$picked' (plain alphabetical would have given 'auggie') -- the ranking is load-bearing" ;;
esac

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
write_cfg "$R" '{"state": "auto", "mitm_enabled": true, "operator_key_env": "X", "target_provider": "y", "endpoint": "http://127.0.0.1:20128"}'
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
write_cfg "$R" '{"state": "auto", "mitm_enabled": true}'
fb --repo "$R" check >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "2e. corrupt+MITM-tainted config -> check never exits 0 (never ROUTE)" \
  || bad "2e. check exited 0 (ROUTE) on a corrupt config! rc=$rc"

# ── 3. falsifier (a): fixture DB CONTAINS a claude row -> REFUSE, Tier-1 reason ─
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="fake-operator-key-value"
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
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" && echo "$out" | grep -qi "Tier-1" \
  && echo "$out" | grep -q "FAIL.*tier1_credential_absent" && echo "$out" | grep -q "claude" \
  && ok "3. falsifier (a): DB has a 'claude' provider_connections row -> REFUSE, Tier-1 reason names it" \
  || bad "3. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY

# ── 4. auto + failing preflight -> WAIT, not ROUTE; same failure under switch -> REFUSE ─
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
out="$(fb --repo "$R" check)"; rc=$?
[ "$rc" -eq 2 ] && echo "$out" | grep -q "VERDICT: WAIT" && ! echo "$out" | grep -q "VERDICT: ROUTE" \
  && ok "4a. state=auto, nothing configured -> WAIT (not ROUTE)" \
  || bad "4a. rc=$rc out='$out'"

R2="$(fresh_repo)"
write_cfg "$R2" '{"state": "switch"}'
out2="$(fb --repo "$R2" check)"; rc2=$?
[ "$rc2" -eq 1 ] && echo "$out2" | grep -q "VERDICT: REFUSE" \
  && ok "4b. identical failing preflight but state=switch -> REFUSE, not WAIT (state changes the verdict, not the checks)" \
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
combined="$(fb --repo "$R" status 2>&1; fb --repo "$R" status --json 2>&1; fb --repo "$R" check 2>&1; fb --repo "$R" where 2>&1; fb --repo "$R" set switch 2>&1; fb --repo "$R" set auto 2>&1; fb --repo "$R" set off 2>&1)"
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

# ── 7. set rejects the removed 'on' value outright -- never persists it, and
# a pre-existing on-disk state is left untouched by the rejected attempt
# (owner directive: 'on' is gone, only off/auto/switch survive) ────────────
R="$(fresh_repo)"
fb --repo "$R" set auto >/dev/null
before="$(cat "$(cfg_path "$R")")"
out="$(fb --repo "$R" set on 2>&1)"; rc=$?
after="$(cat "$(cfg_path "$R")")"
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "invalid choice: 'on'" \
  && printf '%s' "$out" | grep -qF "'off', 'auto', 'switch'" \
  && [ "$before" = "$after" ] \
  && ok "7. set on is rejected outright (never-fail-caller, names all three surviving states) and never touches the existing on-disk state" \
  || bad "7. rc=$rc out='$out' before='$before' after='$after'"

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
  "state": "switch",
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

# ── 20. NEW: a persisted state=on (removed; owner directive: only
# off/auto/switch survive) migrates to off on load -- status surfaces the
# corrected migration NOTE, and check against that SAME, otherwise
# fully-passing config now REFUSEs: run_preflight's own "state" check hard-
# fails whenever state=='off' (state != "off" is a required, independent
# check -- not merely an input to _verdict()'s ROUTE/WAIT choice), so off can
# never ROUTE under any circumstances, full stop. This makes the migration's
# real cost concrete rather than hand-waved: old state=on was tier-blind and,
# like switch, ROUTEd on a fully-passing preflight -- migrating that same
# persisted value to off means it now hard-refuses until the operator
# explicitly re-arms to auto or switch. That IS a real, deliberate loss of
# automatic routing for anyone who had state=on persisted -- traded away on
# purpose so migration never silently hands out MORE routing than the
# operator had; off is the one surviving state that guarantees none at all.
# ────────────────────────────────────────────────────────────────────────────
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
out_status="$(fb --repo "$R" status)"
echo "$out_status" | grep -Eq 'state:[[:space:]]+off' \
  && echo "$out_status" | grep -qi "no longer exists" \
  && echo "$out_status" | grep -qF "migrated to 'off'" \
  && ok "20a. persisted state=on migrates to off on load, status surfaces the corrected migration NOTE" \
  || bad "20a. got: $out_status"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" \
  && echo "$out" | grep -qF "state -- fallback state is 'off'" \
  && ok "20b. that same migrated (now off) config REFUSEs even though every OTHER check would pass -- off is a hard disable (its state check fails on state=='off' alone), so on's prior tier-blind ROUTE is genuinely gone: fail-toward-less-egress made concrete, on purpose" \
  || bad "20b. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY

# ── 21. NEW: arm --state on is rejected outright too -- arm's OWN --state
# flag only ever offered a 2-way choice (auto/switch, never off), so its
# rejection names just those two, distinct from set's 3-way rejection above
# (test 7). Complements test 7: both surfaces that used to accept 'on' are
# now regression-tested for rejection. ──────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "switch", "target_provider": "aihorde"}'
before="$(cat "$(cfg_path "$R")")"
out="$(fb --repo "$R" arm --state on 2>&1)"; rc=$?
after="$(cat "$(cfg_path "$R")")"
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "argument --state: invalid choice: 'on'" \
  && printf '%s' "$out" | grep -qF "'auto', 'switch'" \
  && [ "$before" = "$after" ] \
  && ok "21. arm --state on is rejected outright too, naming only arm's own 2 valid choices (auto/switch -- arm never offered off even before this change), and leaves the existing on-disk config untouched" \
  || bad "21. rc=$rc out='$out' before='$before' after='$after'"

# ── 22. NEW: state=switch routes on a passing preflight alone -- there is no
# tier axis left to be blind to (--tier itself is gone; see tests 25/28), so
# this collapses from a tier loop to one direct assertion. ─────────────────
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
out="$(fb --repo "$R" check)"; rc=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" \
  && ok "22. falsifier (c): state=switch + passing preflight -> ROUTE" \
  || bad "22. rc=$rc out='$out'"
unset HMD_FB_TEST_KEY

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
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc" -eq 1 ] && echo "$out" | grep -q "VERDICT: REFUSE" && echo "$out" | grep -q "FAIL.*tier1_credential_absent" \
  && ok "23. falsifier (d): state=switch + failing Tier-1 check -> still REFUSE (no state bypasses safety)" \
  || bad "23. rc=$rc out='$out'"
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

# ── 25. NEW: --tier is not just deprecated, it is GONE -- check --tier <any>
# is rejected as an UNRECOGNIZED argument (deleted from check's argparse
# subparser entirely, not merely given fewer valid values). Replaces the old
# "on stays tier-blind for bin/lib/issue_loop.py's bare-check call shape"
# test -- issue_loop.py never passed --tier either way (confirmed by a
# repo-wide grep for real callers), so its call shape is untouched. ────────
R="$(fresh_repo)"
out="$(fb --repo "$R" check --tier haiku 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "unrecognized arguments: --tier" \
  && ok "25. check --tier <anything> is rejected as an unrecognized argument -- the flag no longer exists on check at all" \
  || bad "25. rc=$rc out='$out'"

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
write_cfg "$R2" '{"state": "auto"}'
out_text2="$(fb --repo "$R2" status)"
out_json2="$(fb --repo "$R2" status --json)"
! echo "$out_text2" | grep -q "SWITCH" \
  && printf '%s' "$out_json2" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('full_switch') is False else 1)" \
  && ok "27b. state=auto -> no SWITCH banner in text, full_switch:false in json (no false alarm)" \
  || bad "27b. text='$out_text2' json='$out_json2'"

R3="$(fresh_repo)"
write_cfg "$R3" '{"state": "switch"}'
out_check="$(fb --repo "$R3" check 2>&1)"
echo "$out_check" | grep -q "SWITCH" \
  && ok "27c. check's own VERDICT line also loudly flags switch" \
  || bad "27c. got: $out_check"

# ── 28. NEW: even given a value, the (removed) --tier flag still never
# breaks the caller unless --strict -- same never-fail-caller contract as
# `set nonsense` (test 8), now reached via the unrecognized-argument path
# (test 25) rather than an invalid-choice-within-a-declared-flag path. ─────
R="$(fresh_repo)"
out="$(fb --repo "$R" check --tier nonsense-tier 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "28a. check --tier <anything>, no --strict -> exit 0 (never-fail-caller, even though the flag is unrecognized)" \
  || bad "28a. rc=$rc out='$out'"
fb --repo "$R" --strict check --tier nonsense-tier >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "28b. same call WITH --strict -> nonzero (opt-in strictness)" \
  || bad "28b. rc=$rc, want nonzero"

# ── 29. NEW: no-auth pinned provider needs NO operator key -> reaches ROUTE ──
R="$(fresh_repo)"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "switch",
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
  "state": "switch",
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
  "state": "switch",
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
  "state": "switch",
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
  "state": "switch",
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
  "state": "switch",
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

# ── 43b/43c/43d (NEW 2026-08-29, heimdall-session-usage PHASE 3): the
# session-usage payload can now carry a "window" field (five_hour / seven_day
# / both) alongside "crossed" -- metadata only, never a routing input (that
# stays session_verdict=="crossed", untouched). These prove: (b) it fires --
# a crossed+window payload surfaces the window in [INFO]; (c) a pre-Phase-3
# legacy payload (test 38's own fixture: crossed, no "window" key at all)
# renders identically to before, no crash, no stray "None"; (d) it does NOT
# fire somewhere it shouldn't -- an adversarial non-crossed payload that still
# carries a "window" key must never let that leak into the [INFO] line. ────
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
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"crossed","crossed":true,"source":"real","window":"seven_day","percent_real_seven_day":99.0}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" && echo "$out" | grep -q "(window: seven_day)" \
  && ok "43b. session-usage crossed+window=seven_day -> [INFO] names the window" \
  || bad "43b. got rc=$rc out='$out'"

export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"crossed","crossed":true,"source":"budget"}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" && ! echo "$out" | grep -q "(window:" && ! echo "$out" | grep -q " None" \
  && ok "43c. legacy crossed payload with no 'window' key -> unchanged [INFO], no crash, no stray None" \
  || bad "43c. got rc=$rc out='$out'"

export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"under","crossed":false,"source":"real","window":"five_hour"}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
unset HMD_FB_TEST_KEY
[ "$rc" -eq 2 ] && echo "$out" | grep -q "VERDICT: WAIT" && ! echo "$out" | grep -q "(window:" \
  && ok "43d. adversarial non-crossed payload still carrying a 'window' key -> never surfaces (window: never fires when it should not)" \
  || bad "43d. got rc=$rc out='$out'"

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
  "state": "switch",
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
# usability-ranked first pick "aihorde") with an EMPTY operator_key_env (never inventing a
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
out="$(fb --repo "$R" arm --state switch)"; rc=$?
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
out="$(fb --repo "$R" arm --state switch)"
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
out="$(fb --repo "$R" arm --provider mistral --state switch)"; rc=$?
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
  "state": "switch",
  "target_provider": "claude",
  "omniroute_db_path": "'"$CLEAN_DB"'"
}'
out="$(fb --repo "$R" arm --state switch)"
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
out_set1="$(fb --repo "$R1" set switch)"
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
# usability-ranked first no-auth candidate ("aihorde" is), so reuse and re-pick are
# actually distinguishable outcomes here, not the same string by accident. ──
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "target_provider": "opencode"}'
out_check="$(fb --repo "$R" check 2>&1)"; rc_check=$?
[ "$rc_check" -ne 3 ] && ! echo "$out_check" | grep -qi "traceback" \
  && echo "$out_check" | grep -q "VERDICT:" \
  && ok "54a. a partial/old-schema config (missing noauth_providers/omniroute_db_path/cliproxyapi_dir) does not crash check" \
  || bad "54a. rc=$rc_check out='$out_check'"

out_arm="$(fb --repo "$R" arm --state switch)"; rc_arm=$?
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
fb --repo "$R" arm --state switch >/dev/null
db_after="$(md5 -q "$CLEAN_DB" 2>/dev/null || md5sum "$CLEAN_DB" | awk '{print $1}')"
cfg_out="$(cat "$(cfg_path "$R")")"
[ "$db_before" = "$db_after" ] && echo "$cfg_out" | grep -q '"target_provider": "aihorde"' \
  && ok "55. arm never modifies OmniRoute's own DB -- fixture byte-for-byte unchanged after arm actually ran and wrote its self-picked target_provider" \
  || bad "55. db_before=$db_before db_after=$db_after cfg='$cfg_out'"

# ── 56. NEW: arm's self-pick is USABILITY-RANKED, never plain alphabetical.
# Regression guard for a real defect: the first implementation sorted no-auth
# candidates alphabetically. Assert the PROPERTY that matters rather than one
# hardcoded name, so this keeps its teeth as the provider list grows: the pick
# must never be video-only (serviceKinds:["video"]) and never a local-CLI
# passthrough (isLocalCli:true + hasFree:false), which needs a binary installed
# and separately authenticated on this machine and so is not keyless at all
# despite OmniRoute storing no key for it. ──────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{}'
fb --repo "$R" arm --state switch >/dev/null
picked="$(sed -n 's/.*"target_provider": "\([^"]*\)".*/\1/p' "$(cfg_path "$R")")"
case "$picked" in
  veoaifree-web)
    bad "56. arm default-picked '$picked', which is serviceKinds:[\"video\"] -- not a chat surface at all" ;;
  auggie|zcode|codex-app-server|devin-cli-agentic)
    bad "56. arm default-picked '$picked', which is isLocalCli:true + hasFree:false -- it needs a locally installed AND separately authenticated binary, so it is not usable keyless. Usability ranking regressed to plain alphabetical." ;;
  "")
    bad "56. arm wrote no target_provider at all" ;;
  *)
    ok "56. arm's default self-pick ('$picked') is a genuinely keyless llm provider -- not video-only, not a local-CLI passthrough needing its own login" ;;
esac

# ── 57. NEW: an explicit --provider choice still WINS over the capability
# ranking. The ranking orders arm's OWN pick; it must never override an
# operator who deliberately names a provider, including a rank-2 local-CLI one
# like auggie (that is the operator's call to make -- they may well have run
# `auggie login` -- and silently substituting a provider they did not type
# would be worse than obeying them). ───────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{}'
fb --repo "$R" arm --provider auggie --state switch >/dev/null
grep -q '"target_provider": "auggie"' "$(cfg_path "$R")" \
  && ok "57. an explicit --provider auggie is honoured verbatim -- usability ranking governs arm's own pick, never an operator's stated choice" \
  || bad "57. explicit --provider auggie was not honoured: cfg='$(cat "$(cfg_path "$R")")'"

# ── 59. base-url: a ROUTE verdict prints the exact configured endpoint on
# stdout and exits 0. Reuses test 12's fully-passing recipe verbatim so a
# ROUTE here is the SAME config already proven to make `check` say ROUTE. ──
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
run_capture fb --repo "$R" base-url
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$CAP_RC" -eq 0 ] && [ "$CAP_OUT" = "http://127.0.0.1:20128" ] \
  && ok "59. base-url on a ROUTE verdict prints exactly the configured endpoint, exit 0" \
  || bad "59. rc=$CAP_RC out='$CAP_OUT' err='$CAP_ERR'"
unset HMD_FB_TEST_KEY

# ── 60. base-url: a REFUSE verdict (exit 1) leaves stdout BYTE-EMPTY. THE
# load-bearing property in this file: `hmd route` does
# `url="$(heimdall-fallback base-url)"` and unconditionally exports whatever
# comes back, so a reason string leaking onto stdout on a REFUSE path would
# be exported as a base URL and point a live session at garbage.
# Mutation-verified: with cmd_base_url's `sys.stderr.write(...)` on the
# `rc != 0` branch changed to `sys.stdout.write(...)`, this is one of the
# tests that fails (CAP_OUT_BYTES becomes nonzero -- see commit message for
# the full list, since every non-ROUTE base-url test shares this branch). ──
R="$(fresh_repo)"
write_cfg "$R" '{"state": "switch"}'
run_capture fb --repo "$R" base-url
[ "$CAP_RC" -eq 1 ] && [ "$CAP_OUT_BYTES" -eq 0 ] \
  && ok "60. base-url on a REFUSE verdict: exit 1 AND stdout is byte-empty (reason goes to stderr only)" \
  || bad "60. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES out='$CAP_OUT' err='$CAP_ERR'"

# ── 61. base-url: a WAIT verdict (exit 2) also leaves stdout byte-empty --
# same contract as REFUSE; `hmd route` must never treat a stalled decision as
# license to read a base URL either. Same recipe as test 4a (state=auto,
# nothing else configured -> failing preflight -> WAIT, never ROUTE). ─────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
run_capture fb --repo "$R" base-url
[ "$CAP_RC" -eq 2 ] && [ "$CAP_OUT_BYTES" -eq 0 ] \
  && ok "61. base-url on a WAIT verdict: exit 2 AND stdout is byte-empty" \
  || bad "61. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES out='$CAP_OUT' err='$CAP_ERR'"

# ── 62. base-url: with no config file at all (default state=off), stdout is
# byte-empty and exit is non-zero. fresh_repo() alone, no write_cfg call --
# .heimdall/fallback.json genuinely does not exist on disk. ────────────────
R="$(fresh_repo)"
run_capture fb --repo "$R" base-url
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] \
  && ok "62. base-url with no config file at all: exit non-zero, stdout byte-empty" \
  || bad "62. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES out='$CAP_OUT' err='$CAP_ERR'"

# ── 63. base-url: endpoint configured to a NON-loopback URL refuses, stdout
# byte-empty. WHICH LAYER CATCHES THIS: run_preflight's own `endpoint_local`
# check (shared via _routing_decision, exactly like `check`) fails FIRST and
# makes the overall verdict REFUSE before cmd_base_url's own body ever runs.
# cmd_base_url's SECOND, redundant `_is_local_endpoint` guard (right after
# `if rc != 0: return rc`) is unreachable through config alone: _verdict()
# only returns ROUTE when preflight_ok is True, which requires run_preflight's
# own endpoint_local entry to already be True, computed by that SAME
# _is_local_endpoint() call -- so this test proves the preflight layer, not
# cmd_base_url's belt-and-suspenders one; asserting stderr names
# endpoint_local (not some unrelated check) is what pins that down. ────────
R="$(fresh_repo)"
export HMD_FB_TEST_KEY="x"
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
write_cfg "$R" '{
  "state": "switch",
  "operator_key_env": "HMD_FB_TEST_KEY",
  "endpoint": "http://evil.example.com:80",
  "omniroute_db_path": "'"$CLEAN_DB"'",
  "target_provider": "self-hosted-mixtral"
}'
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=1
run_capture fb --repo "$R" base-url
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] && printf '%s' "$CAP_ERR" | grep -q "endpoint_local" \
  && ok "63. base-url with a non-loopback endpoint: refuses (caught by run_preflight's endpoint_local before cmd_base_url's own body runs), stdout byte-empty" \
  || bad "63. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES out='$CAP_OUT' err='$CAP_ERR'"
unset HMD_FB_TEST_KEY

# ── 64. anti-drift guard: base-url and check must NEVER disagree on exit
# code for the same config, because both are computed by the one shared
# _routing_decision()/run_preflight() path on purpose (commit 6de9093's own
# stated reason: "two independent copies of a routing decision is how a
# wrapper starts routing while the gate says REFUSE"). Three configs
# spanning all three verdicts, each checked with the SAME --repo args. ────
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
fb --repo "$R" check >/dev/null 2>&1; rc_check=$?
fb --repo "$R" base-url >/dev/null 2>&1; rc_burl=$?
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
[ "$rc_check" -eq "$rc_burl" ] && [ "$rc_check" -eq 0 ] \
  && ok "64a. ROUTE config: check and base-url agree (both exit $rc_check)" \
  || bad "64a. check=$rc_check base-url=$rc_burl (want both 0)"
unset HMD_FB_TEST_KEY

R="$(fresh_repo)"
write_cfg "$R" '{"state": "switch"}'
fb --repo "$R" check >/dev/null 2>&1; rc_check=$?
fb --repo "$R" base-url >/dev/null 2>&1; rc_burl=$?
[ "$rc_check" -eq "$rc_burl" ] && [ "$rc_check" -eq 1 ] \
  && ok "64b. REFUSE config: check and base-url agree (both exit $rc_check)" \
  || bad "64b. check=$rc_check base-url=$rc_burl (want both 1)"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
fb --repo "$R" check >/dev/null 2>&1; rc_check=$?
fb --repo "$R" base-url >/dev/null 2>&1; rc_burl=$?
[ "$rc_check" -eq "$rc_burl" ] && [ "$rc_check" -eq 2 ] \
  && ok "64c. WAIT config: check and base-url agree (both exit $rc_check)" \
  || bad "64c. check=$rc_check base-url=$rc_burl (want both 2)"

# ── 65. token-file: a 0600 file -> stdout is its absolute path, exit 0. ────
R="$(fresh_repo)"
tokf="$(abs_tmpfile hmd-fallback-test-token)"
printf 'not-a-real-token-value' > "$tokf"
chmod 600 "$tokf"
write_cfg "$R" '{"gateway_token_file": "'"$tokf"'"}'
run_capture fb --repo "$R" token-file
[ "$CAP_RC" -eq 0 ] && [ "$CAP_OUT" = "$tokf" ] \
  && ok "65. token-file with a 0600 file prints its absolute path, exit 0" \
  || bad "65. rc=$CAP_RC out='$CAP_OUT' want='$tokf' err='$CAP_ERR'"

# ── 66. token-file: the file's CONTENTS never appear on stdout or stderr --
# cmd_token_file only ever os.stat()s the file for its mode; it must never
# read or log its bytes. Write a distinctive sentinel and grep both streams
# (captured SEPARATELY by run_capture, then checked together here since
# "leaked to EITHER stream" is the failure this guards). ───────────────────
R="$(fresh_repo)"
tokf="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-token.XXXXXX")"
printf 'SENTINEL_TOKEN_DO_NOT_LEAK_4417' > "$tokf"
chmod 600 "$tokf"
write_cfg "$R" '{"gateway_token_file": "'"$tokf"'"}'
run_capture fb --repo "$R" token-file
if printf '%s\n%s' "$CAP_OUT" "$CAP_ERR" | grep -qF "SENTINEL_TOKEN_DO_NOT_LEAK_4417"; then
  bad "66. token file CONTENTS leaked into stdout or stderr: out='$CAP_OUT' err='$CAP_ERR'"
else
  ok "66. token-file never emits the token file's contents on stdout or stderr"
fi

# ── 67. token-file: mode 0644 (world-readable) refuses -- exit non-zero,
# stdout byte-empty, stderr names the mode. Mutation-verified: with the
# whole `if mode & 0o077:` guard disabled (e.g. `if False:`), this test is
# one of the two that fail (see commit message for the exact mutation and
# both tests it flips -- this one and 68). ─────────────────────────────────
R="$(fresh_repo)"
tokf="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-token.XXXXXX")"
printf 'not-a-real-token-value' > "$tokf"
chmod 644 "$tokf"
write_cfg "$R" '{"gateway_token_file": "'"$tokf"'"}'
run_capture fb --repo "$R" token-file
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] && printf '%s' "$CAP_ERR" | grep -q "0644" \
  && ok "67. token-file refuses a 0644 file: exit non-zero, stdout byte-empty, stderr names the mode" \
  || bad "67. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES err='$CAP_ERR'"

# ── 68. token-file: mode 0640 (group-readable only, no world bits) ALSO
# refuses -- proves the check is `mode & 0o077` (any group OR world bit), not
# just world bits. Mutation-verified: narrowing `mode & 0o077` to
# `mode & 0o007` (world-bits only) makes ONLY this test fail -- 0640's group
# bit (0o040) is invisible to a world-only mask, so it would wrongly pass,
# while test 67's 0644 still has a world-read bit and keeps refusing by
# coincidence even under that narrower mutation (see commit message). ─────
R="$(fresh_repo)"
tokf="$(mktemp "${TMPDIR:-/tmp}/hmd-fallback-test-token.XXXXXX")"
printf 'not-a-real-token-value' > "$tokf"
chmod 640 "$tokf"
write_cfg "$R" '{"gateway_token_file": "'"$tokf"'"}'
run_capture fb --repo "$R" token-file
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] && printf '%s' "$CAP_ERR" | grep -q "0640" \
  && ok "68. token-file refuses a 0640 (group-readable) file too -- the check is mode & 0o077, not world-bits-only" \
  || bad "68. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES err='$CAP_ERR'"

# ── 69. token-file: gateway_token_file unset/empty -> refuses, stdout
# byte-empty. Two cases: key absent entirely, and key present but "". ──────
R="$(fresh_repo)"
write_cfg "$R" '{}'
run_capture fb --repo "$R" token-file
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] \
  && ok "69a. token-file with gateway_token_file entirely absent from config -> refuses, stdout byte-empty" \
  || bad "69a. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES err='$CAP_ERR'"

R="$(fresh_repo)"
write_cfg "$R" '{"gateway_token_file": ""}'
run_capture fb --repo "$R" token-file
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] \
  && ok "69b. token-file with gateway_token_file explicitly empty -> refuses, stdout byte-empty" \
  || bad "69b. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES err='$CAP_ERR'"

# ── 70. token-file: configured path does not exist on disk -> refuses,
# stdout byte-empty. ────────────────────────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"gateway_token_file": "/nonexistent-heimdall-fallback-test/token/does/not/exist"}'
run_capture fb --repo "$R" token-file
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] && printf '%s' "$CAP_ERR" | grep -q "does not exist" \
  && ok "70. token-file with a configured path that does not exist -> refuses, stdout byte-empty" \
  || bad "70. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES err='$CAP_ERR'"

# ── 71. token-file: a ~-prefixed path is expanded. Creates a real 0600 file
# under $HOME (a fresh, uniquely-named directory, cleaned up immediately
# after) since expansion only means something for a path that could
# plausibly resolve under the real home directory. ─────────────────────────
home_dir="$(mktemp -d "$HOME/hmd-fallback-test-tilde.XXXXXX")"
tokf_home="$home_dir/token"
printf 'not-a-real-token-value' > "$tokf_home"
chmod 600 "$tokf_home"
rel="~/$(basename "$home_dir")/token"
R="$(fresh_repo)"
write_cfg "$R" '{"gateway_token_file": "'"$rel"'"}'
run_capture fb --repo "$R" token-file
want="$(cd "$home_dir" && pwd)/token"
[ "$CAP_RC" -eq 0 ] && [ "$CAP_OUT" = "$want" ] \
  && ok "71. token-file expands a ~-prefixed gateway_token_file path" \
  || bad "71. rc=$CAP_RC out='$CAP_OUT' want='$want' err='$CAP_ERR'"
rm -rf "$home_dir"

# ── 72. anthropic_model_pinned: the NEW default-off baseline. With
# ANTHROPIC_MODEL unset AND fallback_model absent/empty, the check FAILS and
# names BOTH halves of why -- proving the fallback_model feature is opt-in:
# an operator who does nothing sees exactly the pre-existing unconditional
# veto. Two cases: key entirely absent from config, and key present but "". ─
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
unset ANTHROPIC_MODEL
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -qi "ANTHROPIC_MODEL is not set" && echo "$out" | grep -qi "no fallback_model is configured" \
  && ok "72a. ANTHROPIC_MODEL unset, fallback_model absent from config -> anthropic_model_pinned FAILS, names both halves" \
  || bad "72a. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "fallback_model": ""}'
unset ANTHROPIC_MODEL
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -qi "ANTHROPIC_MODEL is not set" && echo "$out" | grep -qi "no fallback_model is configured" \
  && ok "72b. ANTHROPIC_MODEL unset, fallback_model explicitly '' -> anthropic_model_pinned FAILS, names both halves" \
  || bad "72b. got: $out"

# ── 73. anthropic_model_pinned: ANTHROPIC_MODEL unset AND fallback_model set
# to a safe, prefixed id -> PASSES. This is the whole point of the feature:
# hmd pins fallback_model on the routed child before exec (bin/heimdall-route's
# FALLBACK PRECEDENCE block), so state=auto can fire genuinely unattended. ──
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "fallback_model": "oc/big-pickle"}'
unset ANTHROPIC_MODEL
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "OK.*anthropic_model_pinned" \
  && ok "73. ANTHROPIC_MODEL unset, fallback_model='oc/big-pickle' (safe, prefixed) -> anthropic_model_pinned PASSES" \
  || bad "73. got: $out"

# ── 74. anthropic_model_pinned: ANTHROPIC_MODEL unset AND fallback_model set
# to an UNPREFIXED id -> FAILS. An unprefixed fallback_model is exactly the
# bare form OmniRoute's routing branch matches, so hmd pinning it would
# recreate the exact hole this check exists to close. ──────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "fallback_model": "big-pickle"}'
unset ANTHROPIC_MODEL
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -qi "no explicit provider/ prefix" \
  && ok "74. ANTHROPIC_MODEL unset, fallback_model='big-pickle' (unprefixed) -> anthropic_model_pinned FAILS" \
  || bad "74. got: $out"

# ── 75. anthropic_model_pinned: fallback_model='claude/sonnet' -> FAILS,
# reason names Tier-1. Mutation-verified: with `if provider_segment in
# TIER1_MODEL_PREFIXES:` changed to `if False:` (the Tier-1 branch made
# unreachable), this test is the one that fails -- see commit message. ─────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "fallback_model": "claude/sonnet"}'
unset ANTHROPIC_MODEL
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -qi "Tier-1" \
  && ok "75. fallback_model='claude/sonnet' -> anthropic_model_pinned FAILS, names Tier-1" \
  || bad "75. got: $out"

# ── 76. anthropic_model_pinned: fallback_model='claude-web/anything' -> FAILS,
# same Tier-1 boundary as test 75, covering the SECOND entry in
# TIER1_MODEL_PREFIXES so a fix that only special-cases 'claude' would still
# be caught. ─────────────────────────────────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "fallback_model": "claude-web/anything"}'
unset ANTHROPIC_MODEL
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -qi "Tier-1" \
  && ok "76. fallback_model='claude-web/anything' -> anthropic_model_pinned FAILS, names Tier-1" \
  || bad "76. got: $out"

# ── 77. PRECEDENCE (load-bearing): an operator-set ANTHROPIC_MODEL outranks
# fallback_model. With ANTHROPIC_MODEL set to an UNSAFE value and
# fallback_model set to a SAFE one, the check still FAILS -- hmd must never
# silently substitute its own configured id for an operator's explicit bad
# one. Two flavors of "unsafe": unprefixed, and an explicit claude/ id.
# Mutation-verified: with the `if anthropic_model: / elif configured_model:`
# branches swapped so the configured id is consulted FIRST, both sub-tests
# below flip to PASS (fallback_model's safe id wins) -- see commit message. ─
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "fallback_model": "oc/big-pickle"}'
export ANTHROPIC_MODEL="big-pickle"
out="$(fb --repo "$R" check)"
unset ANTHROPIC_MODEL
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -q "ANTHROPIC_MODEL='big-pickle'" \
  && ok "77a. ANTHROPIC_MODEL='big-pickle' (unsafe, unprefixed) + fallback_model='oc/big-pickle' (safe) -> still FAILS on ANTHROPIC_MODEL, never substitutes fallback_model" \
  || bad "77a. got: $out"

R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "fallback_model": "oc/big-pickle"}'
export ANTHROPIC_MODEL="claude/x"
out="$(fb --repo "$R" check)"
unset ANTHROPIC_MODEL
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -qi "Tier-1" && echo "$out" | grep -q "ANTHROPIC_MODEL='claude/x'" \
  && ok "77b. ANTHROPIC_MODEL='claude/x' (unsafe, explicit Tier-1) + fallback_model='oc/big-pickle' (safe) -> still FAILS on ANTHROPIC_MODEL, never substitutes fallback_model" \
  || bad "77b. got: $out"

# ── 78. anthropic_model_pinned: ANTHROPIC_MODEL=anthropic/claude-3-5-sonnet-
# 20241022 -> PASSES. Provider segment is 'anthropic' (a paid API key), not
# Tier-1 -- proves the match is on the provider SEGMENT (split on the first
# '/'), never a 'claude' substring anywhere in the id. Mutation-verified:
# with the segment split replaced by a substring test (`"claude" in model`),
# this is the test that fails -- the model id contains "claude" inside the
# model-name half, which an over-broad substring match would wrongly reject
# even though the provider segment is 'anthropic'. See commit message. ─────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
out="$(fb --repo "$R" check)"
unset ANTHROPIC_MODEL
echo "$out" | grep -q "OK.*anthropic_model_pinned" \
  && ok "78. ANTHROPIC_MODEL='anthropic/claude-3-5-sonnet-20241022' -> anthropic_model_pinned PASSES (provider segment, not a substring match)" \
  || bad "78. got: $out"

# ── 79. anthropic_model_pinned: case-insensitivity. fallback_model=
# 'CLAUDE/sonnet' -> FAILS exactly like the lowercase form (test 75) -- the
# provider segment is lowercased before the Tier-1 comparison. ─────────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto", "fallback_model": "CLAUDE/sonnet"}'
unset ANTHROPIC_MODEL
out="$(fb --repo "$R" check)"
echo "$out" | grep -q "FAIL.*anthropic_model_pinned" && echo "$out" | grep -qi "Tier-1" \
  && ok "79. fallback_model='CLAUDE/sonnet' (mixed case) -> anthropic_model_pinned FAILS, case is not a bypass" \
  || bad "79. got: $out"

# ── 80. model: a safe configured fallback_model prints EXACTLY that id on
# stdout, exit 0. Same stdout contract as base-url (tests 59-64) and for the
# same reason: `hmd route` reads this in a command substitution and exports
# the result as ANTHROPIC_MODEL verbatim. ───────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"fallback_model": "oc/big-pickle"}'
run_capture fb --repo "$R" model
[ "$CAP_RC" -eq 0 ] && [ "$CAP_OUT" = "oc/big-pickle" ] \
  && ok "80. model with a safe configured fallback_model prints exactly that id, exit 0" \
  || bad "80. rc=$CAP_RC out='$CAP_OUT' err='$CAP_ERR'"

# ── 81. model: fallback_model absent/empty -> refuses, stdout BYTE-EMPTY.
# Two cases, mirroring the token-file absent/empty pair (tests 69a/69b).
# Mutation-verified: with cmd_model's `sys.stderr.write(...)` on the
# `if not model:` branch changed to `sys.stdout.write(...)`, 81a/81b are the
# tests that fail (CAP_OUT_BYTES becomes nonzero) -- see commit message. ───
R="$(fresh_repo)"
write_cfg "$R" '{}'
run_capture fb --repo "$R" model
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] \
  && ok "81a. model with fallback_model entirely absent from config -> refuses, stdout byte-empty" \
  || bad "81a. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES out='$CAP_OUT' err='$CAP_ERR'"

R="$(fresh_repo)"
write_cfg "$R" '{"fallback_model": ""}'
run_capture fb --repo "$R" model
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] \
  && ok "81b. model with fallback_model explicitly empty -> refuses, stdout byte-empty" \
  || bad "81b. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES out='$CAP_OUT' err='$CAP_ERR'"

# ── 82. model: fallback_model='claude/sonnet' -> refuses, stdout byte-empty,
# stderr names Tier-1. `hmd route` must never export a Tier-1 id just
# because it happened to be configured. ─────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"fallback_model": "claude/sonnet"}'
run_capture fb --repo "$R" model
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] && printf '%s' "$CAP_ERR" | grep -qi "Tier-1" \
  && ok "82. model with fallback_model='claude/sonnet' -> refuses, stdout byte-empty, stderr names Tier-1" \
  || bad "82. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES out='$CAP_OUT' err='$CAP_ERR'"

# ── 83. model: fallback_model unprefixed -> refuses, stdout byte-empty. ────
R="$(fresh_repo)"
write_cfg "$R" '{"fallback_model": "big-pickle"}'
run_capture fb --repo "$R" model
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] \
  && ok "83. model with fallback_model='big-pickle' (unprefixed) -> refuses, stdout byte-empty" \
  || bad "83. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES out='$CAP_OUT' err='$CAP_ERR'"

# ── 84. model NEVER reads ANTHROPIC_MODEL: it reports what hmd WOULD PIN,
# not what is already set. With ANTHROPIC_MODEL set to a fully valid,
# prefixed id and fallback_model empty, `model` still refuses with
# stdout byte-empty -- proving cmd_model consults cfg['fallback_model']
# only, never os.environ['ANTHROPIC_MODEL']. ───────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"fallback_model": ""}'
export ANTHROPIC_MODEL="anthropic/claude-3-5-sonnet-20241022"
run_capture fb --repo "$R" model
unset ANTHROPIC_MODEL
[ "$CAP_RC" -ne 0 ] && [ "$CAP_OUT_BYTES" -eq 0 ] \
  && ok "84. model with ANTHROPIC_MODEL set (valid) but fallback_model empty -> still refuses, stdout byte-empty (model never reads ANTHROPIC_MODEL)" \
  || bad "84. rc=$CAP_RC out_bytes=$CAP_OUT_BYTES out='$CAP_OUT' err='$CAP_ERR'"


# ── 85. LIVENESS PROBE IS HTTP, NOT TCP. ──────────────────────────────────
# Regression guard for the defect that made `check` print [OK]
# endpoint_reachable while every real call to the gateway timed out: the
# probe did a bare TCP connect, and a wedged server (or a webpack dev
# server still compiling the route) completes the handshake while never
# answering a single HTTP request.
#
# Falsifiable in BOTH directions on purpose. A probe hardwired to False
# would pass the wedged case alone, so the live cases must also pass; a
# probe hardwired to True (the old TCP-only behaviour) fails the wedged
# case. 401/307 are asserted reachable because this answers "is anything
# serving HTTP here", never "is this request authorized".
#
# TWO deliberate exceptions to this suite's conventions, both scoped to
# these two cases and neither leaking to any other test:
#   1. `env -u HEIMDALL_FALLBACK_ASSUME_REACHABLE` -- every other test
#      stubs the probe out via that override, which is exactly what must
#      NOT happen here: stubbing it would test the stub, not the probe.
#   2. The header comment says this suite never makes a real network
#      syscall. These bind an ephemeral LOOPBACK socket. Nothing leaves
#      the machine, no DNS, no external host -- but it is a real socket,
#      and testing an HTTP probe without one would be testing nothing.
PROBE_OUT="$(env -u HEIMDALL_FALLBACK_ASSUME_REACHABLE python3 - "$CLI" <<'PYPROBE'
import http.server, socket, socketserver, sys, threading
ns = {"__name__": "fb"}
exec(compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec"), ns)
reachable = ns["_endpoint_reachable"]

class H(http.server.BaseHTTPRequestHandler):
    CODE = 200
    def do_GET(self):
        self.send_response(self.CODE)
        if self.CODE == 307:
            self.send_header("Location", "http://example.invalid/")
        self.end_headers()
    def log_message(self, *a): pass

def serve(code):
    h = type("H%d" % code, (H,), {"CODE": code})
    srv = socketserver.TCPServer(("127.0.0.1", 0), h)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1]

for code in (200, 401, 307):
    print("live%d=%s" % (code, reachable("http://127.0.0.1:%d" % serve(code))))

# wedged: accepts TCP, never writes a byte back
ls = socket.socket()
ls.bind(("127.0.0.1", 0))
ls.listen(5)
threading.Thread(target=lambda: [ls.accept() for _ in range(9)], daemon=True).start()
print("wedged=%s" % reachable("http://127.0.0.1:%d" % ls.getsockname()[1]))
# nothing bound at all
print("dead=%s" % reachable("http://127.0.0.1:1"))
PYPROBE
)"
printf '%s' "$PROBE_OUT" | grep -q '^live200=True$' \
  && printf '%s' "$PROBE_OUT" | grep -q '^live401=True$' \
  && printf '%s' "$PROBE_OUT" | grep -q '^live307=True$' \
  && ok "85a. liveness probe: a server answering 200/401/307 is reachable (non-2xx still proves liveness)" \
  || bad "85a. probe output: $PROBE_OUT"

printf '%s' "$PROBE_OUT" | grep -q '^wedged=False$' \
  && ok "85b. liveness probe: a server that accepts TCP but never answers HTTP is NOT reachable (old TCP-only probe returned True here)" \
  || bad "85b. probe output: $PROBE_OUT"

printf '%s' "$PROBE_OUT" | grep -q '^dead=False$' \
  && ok "85c. liveness probe: nothing bound -> not reachable" \
  || bad "85c. probe output: $PROBE_OUT"

# ── 86. The probe is BOUNDED. A wedged server must not hang the gate. ─────
BOUND_OUT="$(env -u HEIMDALL_FALLBACK_ASSUME_REACHABLE HEIMDALL_FALLBACK_PROBE_TIMEOUT=1 python3 - "$CLI" <<'PYBOUND'
import socket, sys, threading, time
ns = {"__name__": "fb"}
exec(compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec"), ns)
ls = socket.socket()
ls.bind(("127.0.0.1", 0))
ls.listen(5)
threading.Thread(target=lambda: [ls.accept() for _ in range(9)], daemon=True).start()
t = time.time()
r = ns["_endpoint_reachable"]("http://127.0.0.1:%d" % ls.getsockname()[1])
print("rc=%s elapsed=%.2f" % (r, time.time() - t))
PYBOUND
)"
BOUND_SECS="$(printf '%s' "$BOUND_OUT" | sed -n 's/.*elapsed=\([0-9.]*\).*/\1/p')"
printf '%s' "$BOUND_OUT" | grep -q '^rc=False' \
  && [ -n "$BOUND_SECS" ] \
  && awk -v s="$BOUND_SECS" 'BEGIN{exit !(s < 5)}' \
  && ok "86. liveness probe honours HEIMDALL_FALLBACK_PROBE_TIMEOUT: wedged server refused in ${BOUND_SECS}s, not hung" \
  || bad "86. bound output: $BOUND_OUT"


# ── 87. The liveness probe is IMMUNE to ambient proxy variables. ──────────
# Hazard introduced by the TCP->HTTP rewrite, not present before it: urllib's
# default opener installs a ProxyHandler that honours http_proxy/HTTPS_PROXY,
# so an ambient proxy var would route a LOOPBACK probe through a third party
# and a dead proxy would report a healthy gateway as unreachable. A raw TCP
# connect could never be diverted this way. Caught by the omniroute module's
# non-interactive-passthrough invariant.
#
# Falsifiable both ways: the live server must still be reachable WITH the
# proxy vars set (a probe hardwired to False would pass the dead-port half
# alone), and the dead port must still be unreachable.
PROXY_OUT="$(env -u HEIMDALL_FALLBACK_ASSUME_REACHABLE \
  http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 \
  https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
  ALL_PROXY=http://127.0.0.1:9 python3 - "$CLI" <<'PYPROXY'
import http.server, socketserver, sys, threading
ns = {"__name__": "fb"}
exec(compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec"), ns)

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a): pass

srv = socketserver.TCPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
threading.Thread(target=srv.serve_forever, daemon=True).start()
print("live=%s" % ns["_endpoint_reachable"]("http://127.0.0.1:%d" % srv.server_address[1]))
print("dead=%s" % ns["_endpoint_reachable"]("http://127.0.0.1:1"))
PYPROXY
)"
printf '%s' "$PROXY_OUT" | grep -q '^live=True$' \
  && ok "87a. liveness probe ignores ambient proxy vars: a live loopback server stays reachable with http_proxy/HTTPS_PROXY/ALL_PROXY set to a dead proxy" \
  || bad "87a. proxy output: $PROXY_OUT"

printf '%s' "$PROXY_OUT" | grep -q '^dead=False$' \
  && ok "87b. proxy immunity does not blanket-pass: nothing bound is still unreachable with the same vars set" \
  || bad "87b. proxy output: $PROXY_OUT"

# ── 88. PHASE 5 (2026-09-05): an extra/unknown window ALONE crosses --
# five_hour/seven_day both genuinely under, but a THIRD window (e.g. a
# session-scoped limit Anthropic has never exposed by that name before) is
# at/above the pre-exhaustion threshold. This is the exact defect this wave
# closes: heimdall-session-usage's own PHASE 5 already folds an
# unknown-window crossing into verdict="crossed" (see its own suite); this
# proves that CROSSED reaches all the way through bin/heimdall-fallback's
# gate to an actual ROUTE, with a fully passing preflight, and that the
# window name surfaces in [INFO] rather than collapsing to the old fixed
# 7-literal allow-list's None. ───────────────────────────────────────────────
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
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"crossed","crossed":true,"source":"real","window":"extra:session","windows_seen":["five_hour","seven_day","session"]}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
unset HMD_FB_TEST_KEY
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" && echo "$out" | grep -q "(window: extra:session)" \
  && ok "88. PHASE 5: an extra/unknown window ALONE crossing (five_hour/seven_day both under) still reaches ROUTE end-to-end, and [INFO] names it -- the literal defect this wave closes" \
  || bad "88. got rc=$rc out='$out'"

# ── 89. PHASE 5: the HONEST 'under' wording. Before this wave, a genuine
# 'under' verdict rendered as a flat, unqualified "under the pre-exhaustion
# threshold" -- read by an operator as "you are safe", full stop. That
# reading is what produced repeated false-confidence operator reports: the
# windows this check actually saw could be genuinely under threshold while
# a DIFFERENT, unseen window was already exhausted. windows_seen names
# exactly what was actually observed; the note must say so, must still read
# as "under" (not "unknown", not "crossed" -- verdict/routing is
# unaffected), and must NOT borrow unknown's "could not be determined"
# wording (39b/39c's own distinctness contract, still binding). ────────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"under","crossed":false,"source":"real","windows_seen":["five_hour","seven_day"]}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
[ "$rc" -eq 2 ] \
  && echo "$out" | grep -q "VERDICT: WAIT" \
  && echo "$out" | grep -q "five_hour" \
  && echo "$out" | grep -q "seven_day" \
  && ! echo "$out" | grep -qi "could not be determined" \
  && ! echo "$out" | grep -q "(window:" \
  && ok "89. PHASE 5: an honest 'under' names the windows_seen (five_hour, seven_day) instead of an unqualified 'under the pre-exhaustion threshold'" \
  || bad "89. got rc=$rc out='$out'"

# ── 90. PHASE 5 acceptance pin (the literal production incident): 'under'
# with NO windows_seen at all -- heimdall-session-usage saw no rate-limit
# window whatsoever, exactly as measured live at an operator's own 429
# ("3.00% / 0.00%" while a SESSION limit blocked them). The old flat 'under
# the pre-exhaustion threshold' wording is a confident, false-positive
# safety claim in this exact case. Must read BLIND, never a confident
# 'under' or 'fine', and must still WAIT exactly as 'under' always has --
# this changes the WORDING, never the verdict or the routing rc. ──────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"under","crossed":false,"source":"budget"}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
[ "$rc" -eq 2 ] \
  && echo "$out" | grep -q "VERDICT: WAIT" \
  && echo "$out" | grep -qi "BLIND" \
  && ! echo "$out" | grep -qi "could not be determined" \
  && ! echo "$out" | grep -q "(window:" \
  && ok "90. PHASE 5 acceptance pin: 'under' with no windows_seen at all reads BLIND, never a confident bare 'under the pre-exhaustion threshold' -- the exact production incident (session-limit 429 while this line read 'under')" \
  || bad "90. got rc=$rc out='$out'"

# ── 91. PHASE 5: the window validator accepts the ADDITIVE combo form (a
# base window already crossed + an extra window also crossed), the same
# shape PHASE 4 already proved for '+reactive_429' -- proving the PHASE-5
# upgrade to the window-string check is additive to the old fixed
# allow-list, never a replacement that narrows what used to work. ─────────
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
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"crossed","crossed":true,"source":"real","window":"five_hour+extra:session","windows_seen":["five_hour","seven_day","session"]}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
unset HMD_FB_TEST_KEY
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" && echo "$out" | grep -q "(window: five_hour+extra:session)" \
  && ok "91. PHASE 5: additive window combo 'five_hour+extra:session' surfaces in full -- upgrade is additive to the old fixed allow-list, not a narrowing" \
  || bad "91. got rc=$rc out='$out'"

# ── 92. PHASE 5: the window validator still FAILS CLOSED on an adversarial
# window string -- an external, unsanitized rate_limits dict key reaching
# this file must never be trusted onto a printed line just because it
# happens to start with a plausible "extra:" prefix. A path-traversal-
# shaped name (containing "/", outside the allowed alnum/_/./- charset)
# must degrade window to None -- no crash, no stray text -- the same
# fail-open-to-metadata-only standard the old fixed 7-literal check already
# held to (see 43c/43d upstream). Note "crossed" itself is UNAFFECTED --
# window-string safety is metadata-only and never feeds the verdict. ──────
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
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"crossed","crossed":true,"source":"real","window":"extra:../../etc/passwd"}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset ANTHROPIC_MODEL
unset HMD_FB_TEST_KEY
[ "$rc" -eq 0 ] && echo "$out" | grep -q "VERDICT: ROUTE" && ! echo "$out" | grep -q "(window:" \
  && ok "92. PHASE 5: an adversarial path-traversal-shaped window token fails closed to no window shown at all (never trusted onto the printed line)" \
  || bad "92. got rc=$rc out='$out'"

# ── 93. PHASE 5: windows_seen itself fails closed on malformed input (not a
# list) -- degrades to the same BLIND wording as a genuinely absent
# windows_seen, never a crash and never a partial/garbled value
# interpolated into the printed note. ──────────────────────────────────────
R="$(fresh_repo)"
write_cfg "$R" '{"state": "auto"}'
export HEIMDALL_FALLBACK_SESSION_USAGE_BIN="$(make_fake_session_usage '{"verdict":"under","crossed":false,"source":"real","windows_seen":"not-a-list"}')"
out="$(fb --repo "$R" check)"; rc=$?
unset HEIMDALL_FALLBACK_SESSION_USAGE_BIN
[ "$rc" -eq 2 ] && echo "$out" | grep -qi "BLIND" && ! echo "$out" | grep -qi "could not be determined" \
  && ok "93. PHASE 5: a malformed (non-list) windows_seen degrades to the same honest BLIND wording, never a crash" \
  || bad "93. got rc=$rc out='$out'"

echo "--------------------------------------------------------------------"
printf 'heimdall-fallback: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# test/heimdall-settings-guard.test.sh
#
# Proof for bin/heimdall-settings-guard -- the detector for the 2026-09-11
# incident, where an ANTHROPIC_* env block persisted into ~/.claude/settings.json
# routed every session to a third-party gateway, disabled claude.ai connectors,
# and ended in an unbreakable 401 retry loop.
#
# The two properties that actually matter are asserted head-on, not implied:
#   1. It DETECTS the incident shape (and prints no secret while doing it).
#   2. It CANNOT BRICK anything -- every malformed/missing/unreadable input
#      exits 0 silently, and `fix` preserves every unrelated setting byte-for-
#      byte through an atomic rewrite.
#
# HOME is redirected per-case to a temp dir, so this test never reads, and can
# never write, the operator's real ~/.claude/settings.json.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO/bin/heimdall-settings-guard"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Build an isolated HOME containing a settings.json with the given body, and a
# repo dir. Echoes the sandbox HOME.
mk_home() {
  local name="$1" body="$2"
  local h="$TMPROOT/$name"
  mkdir -p "$h/.claude" "$h/repo/.claude"
  printf '%s\n' "$body" > "$h/.claude/settings.json"
  printf '%s' "$h"
}

run_guard() {
  local home="$1"; shift
  HOME="$home" "$GUARD" --repo "$home/repo" "$@" 2>"$TMPROOT/err" 1>"$TMPROOT/out"
  printf '%s' "$?"
}

echo "heimdall-settings-guard"

# ── 1. the incident shape is detected, exit 1 ───────────────────────────────
H="$(mk_home incident '{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:20128",
    "ANTHROPIC_MODEL": "oc/big-pickle",
    "ANTHROPIC_AUTH_TOKEN": "sk-TESTFIXTURE-not-a-real-key-0000"
  },
  "permissions": {"allow": ["Read(//tmp/**)"]}
}')"
rc="$(run_guard "$H" check)"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "1" ] \
   && grep -q 'ANTHROPIC_BASE_URL' <<<"$err" \
   && grep -q 'ANTHROPIC_AUTH_TOKEN' <<<"$err" \
   && grep -q 'ANTHROPIC_MODEL' <<<"$err"; then
  ok "1. detects all three incident keys and exits 1"
else
  bad "1. did not detect the incident shape (rc=$rc)"
fi

# ── 2. the token VALUE is never printed; the URL value IS ───────────────────
# A detector that echoes the bearer token re-commits the original leak at a new
# address (a terminal, a hook log, a session transcript). The non-secret URL is
# the opposite case: its value is the whole diagnostic.
if ! grep -q 'sk-TESTFIXTURE-not-a-real-key-0000' <<<"$err" \
   && grep -q 'redacted' <<<"$err" \
   && grep -q '127.0.0.1:20128' <<<"$err"; then
  ok "2. redacts the token value, prints the base-url value in full"
else
  bad "2. secret leaked into output, or the diagnostic URL was suppressed"
fi

# ── 3. a clean settings.json exits 0 ────────────────────────────────────────
H_CLEAN="$(mk_home clean '{"permissions": {"allow": ["Read(//tmp/**)"]}, "model": "sonnet"}')"
rc="$(run_guard "$H_CLEAN" check)"
[ "$rc" = "0" ] && ok "3. clean settings exits 0" || bad "3. clean settings exited $rc"

# ── 4. an env block with NON-Anthropic vars is not a finding ────────────────
# The rule is the ANTHROPIC_ prefix, not "any env block" -- an operator setting
# DEBUG or PATH additions here is ordinary use, and flagging it would train the
# operator to ignore this warning.
H_OTHER="$(mk_home other '{"env": {"DEBUG": "1", "FOO_TOKEN": "bar"}}')"
rc="$(run_guard "$H_OTHER" check)"
[ "$rc" = "0" ] && ok "4. unrelated env vars are not flagged" \
                || bad "4. false positive on a non-Anthropic env block (rc=$rc)"

# ── 5-8. FAIL-OPEN: every "cannot look" case exits 0, silently ──────────────
# This is the anti-brick contract. A guard that can refuse a launch over its own
# plumbing failure is a worse defect than the one it detects.
H_MISSING="$TMPROOT/missing"; mkdir -p "$H_MISSING/repo"
rc="$(run_guard "$H_MISSING" check)"
[ "$rc" = "0" ] && ok "5. absent settings.json exits 0" || bad "5. absent file exited $rc"

H_BROKEN="$(mk_home broken '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:2012')"
rc="$(run_guard "$H_BROKEN" check)"
[ "$rc" = "0" ] && ok "6. malformed JSON exits 0 (never a finding, never a crash)" \
                || bad "6. malformed JSON exited $rc"

H_ARRAY="$(mk_home arraytop '["not", "an", "object"]')"
rc="$(run_guard "$H_ARRAY" check)"
[ "$rc" = "0" ] && ok "7. non-object top-level JSON exits 0" || bad "7. array top-level exited $rc"

H_ENVSTR="$(mk_home envstring '{"env": "not-an-object"}')"
rc="$(run_guard "$H_ENVSTR" check)"
[ "$rc" = "0" ] && ok "8. non-object env exits 0" || bad "8. string env exited $rc"

# ── 9. --json is machine-readable and still redacts ─────────────────────────
H_JSON="$(mk_home jsonout '{"env": {"ANTHROPIC_AUTH_TOKEN": "sk-secret-value-here"}}')"
rc="$(run_guard "$H_JSON" check --json)"
out="$(cat "$TMPROOT/out")"
if [ "$rc" = "1" ] && command -v jq >/dev/null 2>&1 \
   && [ "$(jq -r '.[0].keys[0].key' <<<"$out")" = "ANTHROPIC_AUTH_TOKEN" ] \
   && ! grep -q 'sk-secret-value-here' <<<"$out"; then
  ok "9. --json emits parseable findings with the secret still redacted"
else
  bad "9. --json output malformed or leaked the secret (rc=$rc)"
fi

# ── 10. --quiet prints nothing when clean (hook-safe) ───────────────────────
rc="$(run_guard "$H_CLEAN" check --quiet)"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; then
  ok "10. --quiet is completely silent on a clean file"
else
  bad "10. --quiet emitted output on a clean file"
fi

# ── 11. fix removes ONLY the ANTHROPIC_ keys, preserving everything else ────
# The real incident file carried 264 permission rules alongside the bad env
# block. Losing them would have been a worse outcome than the routing bug.
H_FIX="$(mk_home fixcase '{
  "env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:20128", "DEBUG": "1"},
  "permissions": {"allow": ["Read(//tmp/**)", "Bash(ls:*)"]},
  "model": "sonnet"
}')"
rc="$(run_guard "$H_FIX" fix)"
S="$H_FIX/.claude/settings.json"
if [ "$rc" = "0" ] \
   && jq -e . "$S" >/dev/null 2>&1 \
   && [ "$(jq -r '.env.ANTHROPIC_BASE_URL // "gone"' "$S")" = "gone" ] \
   && [ "$(jq -r '.env.DEBUG' "$S")" = "1" ] \
   && [ "$(jq -r '.permissions.allow | length' "$S")" = "2" ] \
   && [ "$(jq -r '.model' "$S")" = "sonnet" ]; then
  ok "11. fix removes the Anthropic key, keeps DEBUG, permissions and model intact"
else
  bad "11. fix damaged the file or missed the key"
fi

# ── 12. fix drops an env block it has emptied, rather than leaving {} ───────
H_EMPTY="$(mk_home fixempty '{"env": {"ANTHROPIC_MODEL": "oc/big-pickle"}, "model": "sonnet"}')"
run_guard "$H_EMPTY" fix >/dev/null
S="$H_EMPTY/.claude/settings.json"
if [ "$(jq -r 'has("env")' "$S")" = "false" ] && [ "$(jq -r '.model' "$S")" = "sonnet" ]; then
  ok "12. an emptied env block is removed entirely"
else
  bad "12. left an empty env object behind"
fi

# ── 13. fix writes a 0600 backup even from a 0644 original ─────────────────
# The original may be world-readable and hold a token; the backup must never
# widen that exposure.
H_PERM="$(mk_home fixperm '{"env": {"ANTHROPIC_AUTH_TOKEN": "sk-xyz"}}')"
chmod 644 "$H_PERM/.claude/settings.json"
run_guard "$H_PERM" fix >/dev/null
BAK="$H_PERM/.claude/settings.json.hmd-bak"
if [ -f "$BAK" ]; then
  mode="$(stat -f '%Lp' "$BAK" 2>/dev/null || stat -c '%a' "$BAK" 2>/dev/null)"
  [ "$mode" = "600" ] && ok "13. backup of a 0644 original is written 0600" \
                      || bad "13. backup mode is $mode, expected 600"
else
  bad "13. fix wrote no backup"
fi

# ── 14. fix on a clean file is a no-op that still exits 0 ──────────────────
before="$(cat "$H_CLEAN/.claude/settings.json")"
rc="$(run_guard "$H_CLEAN" fix)"
after="$(cat "$H_CLEAN/.claude/settings.json")"
if [ "$rc" = "0" ] && [ "$before" = "$after" ] && grep -q 'nothing to fix' "$TMPROOT/out"; then
  ok "14. fix on a clean file changes nothing and says so"
else
  bad "14. fix mutated a clean file or misreported"
fi

# ── 15. a project-level .claude/settings.json is scanned too ───────────────
# The user-level file was the incident, but the same block in a repo is the
# same defect with a narrower blast radius.
H_PROJ="$(mk_home projscope '{"model": "sonnet"}')"
printf '%s\n' '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:9999"}}' \
  > "$H_PROJ/repo/.claude/settings.json"
rc="$(run_guard "$H_PROJ" check)"
if [ "$rc" = "1" ] && grep -q 'repo/.claude/settings.json' "$TMPROOT/err"; then
  ok "15. a project-scoped settings.json is scanned and named"
else
  bad "15. project-scoped settings.json was not scanned (rc=$rc)"
fi

# ── 16. the remediation line it prints actually works ──────────────────────
# A warning that tells the operator to run a command which does not fix the
# problem is worse than no warning. Execute its own advice and re-check.
H_ADVICE="$(mk_home advice '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:20128"}, "model": "sonnet"}')"
rc="$(run_guard "$H_ADVICE" check)"
CMD="$(grep -o "jq 'del(.*)' .* && mv .*" "$TMPROOT/err" | head -1)"
if [ -n "$CMD" ] && command -v jq >/dev/null 2>&1; then
  ( eval "$CMD" ) >/dev/null 2>&1
  rc="$(run_guard "$H_ADVICE" check)"
  if [ "$rc" = "0" ] && [ "$(jq -r '.model' "$H_ADVICE/.claude/settings.json")" = "sonnet" ]; then
    ok "16. the printed jq remediation genuinely clears the finding, model preserved"
  else
    bad "16. the printed remediation did not clear the finding (rc=$rc)"
  fi
else
  bad "16. no runnable remediation line was printed"
fi

# ── 17. --repo is accepted on BOTH sides of the subcommand ─────────────────
# The SessionStart hook spells it `check --quiet --repo X`; a hook that dies on
# a usage error is a guard that silently never runs. Both orders must work.
H_ORD="$(mk_home argorder '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:20128"}}')"
HOME="$H_ORD" "$GUARD" check --repo "$H_ORD/repo" >/dev/null 2>"$TMPROOT/err"; rc_after=$?
HOME="$H_ORD" "$GUARD" --repo "$H_ORD/repo" check >/dev/null 2>/dev/null; rc_before=$?
if [ "$rc_after" = "1" ] && [ "$rc_before" = "1" ] \
   && ! grep -q 'unrecognized arguments' "$TMPROOT/err"; then
  ok "17. --repo works before AND after the subcommand (the hook's spelling)"
else
  bad "17. --repo rejected in one position (before=$rc_before after=$rc_after)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

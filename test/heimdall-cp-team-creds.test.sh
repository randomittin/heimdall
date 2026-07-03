#!/usr/bin/env bash
# heimdall-cp-team-creds.test.sh — the FALSIFIABLE PER-TEAM CREDENTIAL-STORE gate for
# public multi-tenant Heimdall (BYO-credential, design §1/§5). Hermetic, LocalBackend,
# ZERO cloud: a throwaway HEIMDALL_HOME + the local StateBackend + runtime-assembled
# secrets (nothing static → the test file is gitleaks-clean).
#
# THE GUARANTEES PROVEN (each an assertion; a regression must RED here):
#   1. put/get ROUND-TRIP per team (oauth_token and api_key) — the cred comes back, keyed
#      to its team, under the RIGHT job env var (CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY).
#   2. CROSS-TENANT READ DENIED (the cardinal isolation invariant): with a TWO-TEAM fixture
#      (A, B, DISTINCT secrets), get_team_cred(A) returns A's secret and NEVER B's, and vice
#      versa. There is no call by which team A's id yields team B's cred. FALSIFIABLE: were
#      the store not partitioned by team_id, A's read would surface B's secret → this FAILS.
#   3. SECRET NEVER LOGGED: a harness exercising EVERY public API prints only booleans; its
#      whole stdout+stderr is grepped for the raw secrets → ABSENT. POSITIVE CONTROL: a
#      separate probe prints env_for_team(A)'s carried value → the SAME grep finds it PRESENT
#      (proving env_for_team DID carry the secret into the returned env, and the grep works).
#   4. PREFERENCE: a team with BOTH kinds resolves oauth_token first (design §1 order).
#   5. FAIL-CLOSED: an unknown team → get None, env {}, has_cred False (never a fabricated or
#      another team's value). An invalid/traversal team_id → refused, no partition escape.
#   6. DELETE works: has_cred True → delete → has_cred False, get None, env {}.
#   7. AT-REST 0600: the locally-stored cred file is mode 0600 (a co-tenant cannot read it).
#
# Acceptance: `bash test/heimdall-cp-team-creds.test.sh` → N passed, 0 failed.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB

[ -f "$LIB/cp_team_creds.py" ] || { echo "FATAL: $LIB/cp_team_creds.py missing" >&2; exit 2; }
[ -f "$LIB/cp_state.py" ] || { echo "FATAL: $LIB/cp_state.py missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-teamcreds.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── hermetic env: throwaway home, LOCAL backend, no cloud signal ──
export HEIMDALL_HOME="$WORK/cphome"
unset HEIMDALL_STATE_BACKEND 2>/dev/null || true   # default = LocalBackend.
unset HEIMDALL_TEAM_CRED_STORE 2>/dev/null || true # default = local secret store.
unset K_SERVICE 2>/dev/null || true                # not a cloud profile.
mkdir -p "$HEIMDALL_HOME"

# ── two teams, DISTINCT runtime-assembled secrets (nothing static in this file) ──
# team_id shapes mirror derive_team_id()'s 32-hex handle; secrets are random tokens.
TEAM_A="$("$PY" -c "import secrets;print(secrets.token_hex(16))")"
TEAM_B="$("$PY" -c "import secrets;print(secrets.token_hex(16))")"
TEAM_BOTH="$("$PY" -c "import secrets;print(secrets.token_hex(16))")"
# OAuth-token-shaped / api-key-shaped values, assembled at runtime.
SECRET_A="$("$PY" -c "import secrets;print('sk-ant-oat01-'+secrets.token_urlsafe(40))")"
SECRET_B="$("$PY" -c "import secrets;print('sk-ant-api03-'+secrets.token_urlsafe(40))")"
SECRET_BOTH_OAUTH="$("$PY" -c "import secrets;print('sk-ant-oat01-'+secrets.token_urlsafe(40))")"
SECRET_BOTH_API="$("$PY" -c "import secrets;print('sk-ant-api03-'+secrets.token_urlsafe(40))")"
export TEAM_A TEAM_B TEAM_BOTH SECRET_A SECRET_B SECRET_BOTH_OAUTH SECRET_BOTH_API

echo "============================================================"
echo "PER-TEAM CREDENTIAL STORE (hermetic, LocalBackend)"
echo "  home=$HEIMDALL_HOME"
echo "============================================================"
echo

# ══════════════════════════════════════════════════════════════════════════════
# HARNESS 1 — exercise EVERY public API; print ONLY booleans/derived (never a secret).
# Its combined stdout+stderr is later grepped for the raw secrets → must be ABSENT.
# ══════════════════════════════════════════════════════════════════════════════
H1_OUT="$WORK/h1.out"
H1_ERR="$WORK/h1.err"
"$PY" - >"$H1_OUT" 2>"$H1_ERR" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_creds as TC

A = os.environ["TEAM_A"]; B = os.environ["TEAM_B"]; BOTH = os.environ["TEAM_BOTH"]
SA = os.environ["SECRET_A"]; SB = os.environ["SECRET_B"]
BO = os.environ["SECRET_BOTH_OAUTH"]; BA = os.environ["SECRET_BOTH_API"]
out = {}

# 1. put/get round-trip — team A stores an OAuth token, team B an api_key.
out["putA"] = TC.put_team_cred(A, "oauth_token", SA)
out["putB"] = TC.put_team_cred(B, "api_key", SB)

credA = TC.get_team_cred(A)
credB = TC.get_team_cred(B)
out["getA_kind"] = credA and credA.get("kind")
out["getA_env"] = credA and credA.get("env_name")
out["getA_is_SA"] = bool(credA and credA.get("secret") == SA)
out["getB_kind"] = credB and credB.get("kind")
out["getB_env"] = credB and credB.get("env_name")
out["getB_is_SB"] = bool(credB and credB.get("secret") == SB)

# 2. CROSS-TENANT READ DENIED — A never yields B's secret; B never yields A's.
out["A_not_B"] = bool(credA and credA.get("secret") != SB)
out["B_not_A"] = bool(credB and credB.get("secret") != SA)
out["secrets_differ"] = (SA != SB)
# There is NO function taking two team ids; A's read is A's partition only.
out["getA_only_A"] = bool(credA and credA.get("secret") == SA and credA.get("secret") != SB)
out["getB_only_B"] = bool(credB and credB.get("secret") == SB and credB.get("secret") != SA)

# env_for_team — the ONE intended sink — carries EXACTLY A's secret under A's env var.
envA = TC.env_for_team(A)
out["envA_key"] = list(envA.keys())
out["envA_carries_SA"] = (envA.get("CLAUDE_CODE_OAUTH_TOKEN") == SA)
out["envA_no_SB"] = (SB not in envA.values())
envB = TC.env_for_team(B)
out["envB_carries_SB"] = (envB.get("ANTHROPIC_API_KEY") == SB)

# 4. PREFERENCE — a team with BOTH kinds resolves oauth_token first.
out["putBOTH_api"] = TC.put_team_cred(BOTH, "api_key", BA)
out["putBOTH_oauth"] = TC.put_team_cred(BOTH, "oauth_token", BO)
credBOTH = TC.get_team_cred(BOTH)
out["both_prefers_oauth"] = bool(credBOTH and credBOTH.get("kind") == "oauth_token"
                                 and credBOTH.get("secret") == BO)
envBOTH = TC.env_for_team(BOTH)
out["both_env_oauth"] = (envBOTH.get("CLAUDE_CODE_OAUTH_TOKEN") == BO)

# 5. FAIL-CLOSED — unknown team.
UNKNOWN = "deadbeefdeadbeefdeadbeefdeadbeef"
out["unknown_get_none"] = (TC.get_team_cred(UNKNOWN) is None)
out["unknown_env_empty"] = (TC.env_for_team(UNKNOWN) == {})
out["unknown_has_false"] = (TC.has_cred(UNKNOWN) is False)
# invalid/traversal team_id — refused, no partition escape.
out["traversal_put_false"] = (TC.put_team_cred("../" + B, "oauth_token", "x") is False)
out["traversal_get_none"] = (TC.get_team_cred("../" + B) is None)
out["empty_put_false"] = (TC.put_team_cred("", "oauth_token", "x") is False)
out["badkind_put_false"] = (TC.put_team_cred(A, "password", "x") is False)
out["emptysecret_put_false"] = (TC.put_team_cred(A, "oauth_token", "") is False)

# has_cred present for A and B.
out["hasA"] = TC.has_cred(A)
out["hasB"] = TC.has_cred(B)

# 6. DELETE — remove B's cred; B goes fail-closed; A is UNTOUCHED (isolation of delete).
out["deleteB"] = TC.delete_team_cred(B)
out["B_gone_has"] = (TC.has_cred(B) is False)
out["B_gone_get"] = (TC.get_team_cred(B) is None)
out["B_gone_env"] = (TC.env_for_team(B) == {})
out["A_survives_delete_of_B"] = bool(TC.get_team_cred(A)
                                     and TC.get_team_cred(A).get("secret") == SA)
out["delete_absent_false"] = (TC.delete_team_cred(UNKNOWN) is False)

# NONE of the secret values may appear in this JSON summary (we print booleans/names only).
blob = json.dumps(out)
out["_selfcheck_no_secret_in_summary"] = not any(
    s in blob for s in (SA, SB, BO, BA))

sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$H1_OUT" ]; then
  echo "FATAL: harness-1 produced no output" >&2
  cat "$H1_ERR" >&2
  exit 2
fi
j() { "$PY" -c "import json,sys; print(json.load(open('$H1_OUT')).get('$1'))"; }

echo "1. put/get ROUND-TRIP (per team, correct job env var)"
[ "$(j putA)" = "True" ] && [ "$(j putB)" = "True" ] && ok "1.1 put_team_cred stored A (oauth_token) and B (api_key)" || bad "1.1 put failed"
[ "$(j getA_kind)" = "oauth_token" ] && [ "$(j getA_env)" = "CLAUDE_CODE_OAUTH_TOKEN" ] && [ "$(j getA_is_SA)" = "True" ] \
  && ok "1.2 get_team_cred(A) -> A's oauth_token under CLAUDE_CODE_OAUTH_TOKEN" || bad "1.2 A round-trip wrong"
[ "$(j getB_kind)" = "api_key" ] && [ "$(j getB_env)" = "ANTHROPIC_API_KEY" ] && [ "$(j getB_is_SB)" = "True" ] \
  && ok "1.3 get_team_cred(B) -> B's api_key under ANTHROPIC_API_KEY" || bad "1.3 B round-trip wrong"
[ "$(j envA_carries_SA)" = "True" ] && [ "$(j envB_carries_SB)" = "True" ] \
  && ok "1.4 env_for_team carries each team's secret under the right var (select_maintainer_auth-ready)" || bad "1.4 env_for_team wrong"

echo "2. CROSS-TENANT READ DENIED (the cardinal isolation invariant) [FALSIFIABLE]"
[ "$(j secrets_differ)" = "True" ] || bad "2.0 fixture broken: A and B secrets not distinct"
[ "$(j getA_only_A)" = "True" ] && [ "$(j A_not_B)" = "True" ] \
  && ok "2.1 get_team_cred(A) returns A's secret and NEVER B's (A's partition only)" || bad "2.1 A leaked B or wrong"
[ "$(j getB_only_B)" = "True" ] && [ "$(j B_not_A)" = "True" ] \
  && ok "2.2 get_team_cred(B) returns B's secret and NEVER A's (no cross-tenant read)" || bad "2.2 B leaked A or wrong"
[ "$(j envA_no_SB)" = "True" ] \
  && ok "2.3 env_for_team(A) never carries B's secret (the job env is single-tenant)" || bad "2.3 env_for_team crossed teams"

echo "4. PREFERENCE (oauth_token before api_key)"
[ "$(j both_prefers_oauth)" = "True" ] && [ "$(j both_env_oauth)" = "True" ] \
  && ok "4.1 a team with BOTH kinds resolves oauth_token first (design §1 order)" || bad "4.1 preference order wrong"

echo "5. FAIL-CLOSED (unknown team + invalid/traversal team_id refused)"
[ "$(j unknown_get_none)" = "True" ] && [ "$(j unknown_env_empty)" = "True" ] && [ "$(j unknown_has_false)" = "True" ] \
  && ok "5.1 unknown team -> get None, env {}, has_cred False (never fabricated/cross-tenant)" || bad "5.1 not fail-closed"
[ "$(j traversal_put_false)" = "True" ] && [ "$(j traversal_get_none)" = "True" ] && [ "$(j empty_put_false)" = "True" ] \
  && ok "5.2 a '../<team>' traversal / empty team_id is REFUSED (no partition escape)" || bad "5.2 traversal not refused"
[ "$(j badkind_put_false)" = "True" ] && [ "$(j emptysecret_put_false)" = "True" ] \
  && ok "5.3 a bad kind / empty secret is REFUSED" || bad "5.3 bad input not refused"

echo "6. DELETE (fail-closed after; other team untouched)"
[ "$(j hasA)" = "True" ] && [ "$(j hasB)" = "True" ] || bad "6.0 has_cred did not see stored creds"
[ "$(j deleteB)" = "True" ] && [ "$(j B_gone_has)" = "True" ] && [ "$(j B_gone_get)" = "True" ] && [ "$(j B_gone_env)" = "True" ] \
  && ok "6.1 delete_team_cred(B) -> B fail-closed (has_cred False, get None, env {})" || bad "6.1 delete did not clear B"
[ "$(j A_survives_delete_of_B)" = "True" ] \
  && ok "6.2 deleting B leaves A's cred INTACT (delete is per-partition)" || bad "6.2 delete of B affected A"
[ "$(j delete_absent_false)" = "True" ] \
  && ok "6.3 delete of an absent team -> False (nothing to remove)" || bad "6.3 absent delete not False"

# ── selfcheck: the harness summary itself carries no secret (belt-and-braces) ──
[ "$(j _selfcheck_no_secret_in_summary)" = "True" ] \
  && ok "harness summary carries booleans/names only (no secret value in the JSON)" || bad "a secret leaked into the harness summary"

# ══════════════════════════════════════════════════════════════════════════════
# 3. SECRET NEVER LOGGED — grep the WHOLE harness-1 stdout+stderr for the raw secrets.
#    A leak on any log/print/repr/exception path would surface here.
# ══════════════════════════════════════════════════════════════════════════════
echo "3. SECRET NEVER LOGGED (grep harness stdout+stderr) [with positive control]"
LEAK=0
for S in "$SECRET_A" "$SECRET_B" "$SECRET_BOTH_OAUTH" "$SECRET_BOTH_API"; do
  if grep -qF -- "$S" "$H1_OUT" "$H1_ERR" 2>/dev/null; then LEAK=1; fi
done
[ "$LEAK" -eq 0 ] \
  && ok "3.1 no secret value appears in the harness stdout/stderr (no log/print/repr leak)" || bad "3.1 a secret LEAKED into harness output"

# POSITIVE CONTROL — prove the grep is real: a probe that DOES print env_for_team(A)'s
# carried value must be caught by the SAME grep (env_for_team DID carry the secret).
CTRL_OUT="$WORK/ctrl.out"
"$PY" - >"$CTRL_OUT" 2>&1 <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_team_creds as TC
env = TC.env_for_team(os.environ["TEAM_A"])
# Deliberately emit the carried value — the control that the leak-grep can detect it.
sys.stdout.write(env.get("CLAUDE_CODE_OAUTH_TOKEN", ""))
PYEOF
if grep -qF -- "$SECRET_A" "$CTRL_OUT" 2>/dev/null; then
  ok "3.2 POSITIVE CONTROL: env_for_team(A) DID carry A's secret (the leak-grep is real)"
else
  bad "3.2 positive control failed — env_for_team did not carry the secret (grep would miss a real leak)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7. AT-REST 0600 — the locally-stored cred file is mode 0600 (co-tenant cannot read).
# ══════════════════════════════════════════════════════════════════════════════
echo "7. AT-REST hardening (0600 on the local cred file)"
CRED_FILE="$HEIMDALL_HOME/control-plane/team-creds/$TEAM_A/oauth_token.json"
if [ -f "$CRED_FILE" ]; then
  MODE="$("$PY" -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$CRED_FILE")"
  [ "$MODE" = "0o600" ] \
    && ok "7.1 the local cred file is mode 0600 ($MODE)" || bad "7.1 cred file mode is $MODE (expected 0o600)"
else
  bad "7.1 the local cred file was not written at the expected partition path"
fi
# and the secret IS the file's content (round-trip is real, not a no-op), but that content
# is never emitted to a log — only the file on the hardened path holds it.
if grep -qF -- "$SECRET_A" "$CRED_FILE" 2>/dev/null; then
  ok "7.2 the secret is durably stored in the 0600 partition file (real round-trip)"
else
  bad "7.2 the secret was not found in its own 0600 partition file"
fi

echo
echo "============================================================"
printf "cp-team-creds: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

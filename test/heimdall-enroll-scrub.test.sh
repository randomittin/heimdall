#!/usr/bin/env bash
# test/heimdall-enroll-scrub.test.sh — Part 3 acceptance: the enroll token is
# ERASED as a USER concept but the MECHANISM stays fully alive for operators.
#
# Two halves, both falsifiable:
#   A. SCRUB (user surfaces)  — the primary help/onboarding a user reads/runs shows
#      NO "--enroll-token" and NO "enroll token": `rr --help` runtime output, the
#      README onboarding block, commands/invite.md, and the install.sh interactive
#      prompt + guidance copy. A regression that re-adds an enroll-token instruction
#      to any user surface goes RED here.
#   B. MECHANISM (operator falsifier) — the demoted `--enroll-token` flag STILL
#      WORKS: `rr setup --mode control-plane --endpoint <u> --enroll-token <t>`
#      persists the token 0600 into cp-endpoint.json (never echoed). This is the
#      FALSIFIER: if the scrub had deleted the mechanism, the token would not land
#      and this half goes RED — proving the re-gate capability is intact, not dead.
#      The tokenless (open-bounded) setup path is also proven to work.
#   C. OPERATORS.md documents the re-gate (HEIMDALL_ENROLL_OPEN, gcloud flip, caps).
#
# HERMETIC: $HOME is a throwaway dir; no network is touched (setup only writes
# local config). Fakes in the TEST are fine; production has no fakes.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RR="$ROOT/bin/rr"
README="$ROOT/README.md"
INVITE="$ROOT/commands/invite.md"
INSTALL="$ROOT/install.sh"
OPERATORS="$ROOT/OPERATORS.md"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

PY="$(command -v python3 || command -v python)"
[ -f "$RR" ] || { echo "FATAL: $RR missing" >&2; exit 1; }
[ -x "$RR" ] || { echo "FATAL: $RR not executable" >&2; exit 1; }

WORK="$(mktemp -d -t "heimdall-enroll-scrub.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
# The two user-facing INSTRUCTION forms we forbid on a user surface (case-insensitive):
#   the flag  --enroll-token   and the phrase  "enroll token" / "enroll-token" / "enroll_token".
TOKEN_RX='enroll[ _-]token|--enroll-token'

echo "── A. SCRUB: no enroll-token on any user surface ──────────────────────────"

# (A1) `rr --help` RUNTIME OUTPUT — the primary CLI help a user reads.
help_out="$("$RR" --help 2>&1 | strip_ansi)"
if grep -qiE "$TOKEN_RX" <<<"$help_out"; then
  bad "rr --help output must NOT mention an enroll token"
  grep -inE "$TOKEN_RX" <<<"$help_out" | sed 's/^/       /'
else
  ok "rr --help output is enroll-token-free (primary CLI help)"
fi

# (A2) README onboarding — the primary 'Get a bot PR' surface.
if grep -qiE "$TOKEN_RX" "$README"; then
  bad "README must NOT instruct a user about an enroll token"
  grep -inE "$TOKEN_RX" "$README" | sed 's/^/       /'
else
  ok "README is enroll-token-free (onboarding surface)"
fi

# (A3) commands/invite.md — the /invite skill copy (also no HEIMDALL_ENROLL_TOKEN in the join).
if grep -qiE "$TOKEN_RX|HEIMDALL_ENROLL_TOKEN" "$INVITE"; then
  bad "commands/invite.md must NOT reference an enroll token"
  grep -inE "$TOKEN_RX|HEIMDALL_ENROLL_TOKEN" "$INVITE" | sed 's/^/       /'
else
  ok "commands/invite.md is enroll-token-free (invite copy uses the team secret)"
fi

# (A4) install.sh USER-VISIBLE copy — the removed 'Team enroll token' prompt is gone,
#      and no printf emits an enroll-token INSTRUCTION/guidance to the user. NB: the
#      config-file serializer legitimately writes the `enroll_token` JSON schema key
#      (underscore) to disk — that is the persisted-token MECHANISM, not user copy, so
#      the instruction forms we forbid are the space/dash phrasing + the env var only.
INSTR_RX='enroll[ -]token|--enroll-token|HEIMDALL_ENROLL_TOKEN'
if grep -qi "Team enroll token" "$INSTALL"; then
  bad "install.sh must NOT prompt for a 'Team enroll token'"
elif grep -qnE "printf.*($INSTR_RX)" "$INSTALL"; then
  bad "install.sh must NOT print an enroll-token instruction/guidance to the user"
  grep -inE "printf.*($INSTR_RX)" "$INSTALL" | sed 's/^/       /'
else
  ok "install.sh user prompt + guidance are enroll-token-free (tokenless onboarding)"
fi

echo "── B. MECHANISM: the demoted --enroll-token flag STILL WORKS (operator) ────"

# Hermetic HOME for the setup writes (no real ~/.heimdall touched, no network).
export HOME="$WORK/home"
mkdir -p "$HOME/.heimdall"
CP_JSON="$HOME/.heimdall/cp-endpoint.json"
SECRET_TOKEN="op-bootstrap-$(printf 'X%.0s' 1 2 3 4 5 6 7 8)-tok"

# (B1) FALSIFIER — the operator flag persists the token into cp-endpoint.json. If the
#      scrub had removed the mechanism, the token would not land and this goes RED.
setup_out="$("$RR" setup --mode control-plane --endpoint "https://cp.example/api" \
              --enroll-token "$SECRET_TOKEN" 2>&1 | strip_ansi)"
stored=""
if [ -f "$CP_JSON" ]; then
  stored="$(CP="$CP_JSON" "$PY" - <<'PYEOF'
import json, os
try:
    d = json.load(open(os.environ["CP"]))
    print(d.get("enroll_token", ""))
except Exception:
    print("")
PYEOF
)"
fi
if [ "$stored" = "$SECRET_TOKEN" ]; then
  ok "--enroll-token flag STILL persists the bootstrap token to cp-endpoint.json (mechanism alive)"
else
  bad "--enroll-token flag did NOT persist the token (mechanism appears dead) — got: '${stored}'"
fi

# (B2) SECRET-SAFE — the token is NEVER echoed to stdout/stderr (existing invariant holds).
if grep -qF "$SECRET_TOKEN" <<<"$setup_out"; then
  bad "the enroll token leaked onto rr setup output (must never be echoed)"
else
  ok "the enroll token is never echoed by rr setup (0600, argv-free)"
fi

# (B3) 0600 on the config that now holds the secret.
if [ -f "$CP_JSON" ]; then
  mode="$(stat -f '%Lp' "$CP_JSON" 2>/dev/null || stat -c '%a' "$CP_JSON" 2>/dev/null)"
  case "$mode" in
    600) ok "cp-endpoint.json holding the token is 0600" ;;
    *)   bad "cp-endpoint.json must be 0600 (got: ${mode:-?})" ;;
  esac
else
  bad "cp-endpoint.json was not written by the operator setup"
fi

# (B4) OPEN-BOUNDED — tokenless setup writes the url with NO enroll token (first-run just works).
HOME2="$WORK/home2"; mkdir -p "$HOME2/.heimdall"
CP_JSON2="$HOME2/.heimdall/cp-endpoint.json"
HOME="$HOME2" "$RR" setup --mode control-plane --endpoint "https://cp.example/api" >/dev/null 2>&1
open_ok=bad
if [ -f "$CP_JSON2" ]; then
  open_ok="$(CP="$CP_JSON2" "$PY" - <<'PYEOF'
import json, os
try:
    d = json.load(open(os.environ["CP"]))
    print("ok" if d.get("url") == "https://cp.example/api" and not d.get("enroll_token") else "bad:%r" % d)
except Exception as e:
    print("bad:%s" % e)
PYEOF
)"
fi
if [ "$open_ok" = "ok" ]; then
  ok "tokenless setup writes url with NO enroll token (open-bounded first-run works)"
else
  bad "tokenless setup path broken: $open_ok"
fi

echo "── C. OPERATORS.md documents the re-gate ──────────────────────────────────"

if [ ! -f "$OPERATORS" ]; then
  bad "OPERATORS.md is missing"
else
  need_gate=bad need_flip=bad need_caps=bad need_open=bad
  grep -q "HEIMDALL_ENROLL_OPEN" "$OPERATORS" && need_gate=ok
  grep -qiE "re-?gat" "$OPERATORS" && need_open=ok
  grep -qE "gcloud run services update" "$OPERATORS" && need_flip=ok
  grep -q "HEIMDALL_ENROLL_MAX_KEYS" "$OPERATORS" && grep -q "HEIMDALL_TEAM_MAX_MEMBERS" "$OPERATORS" && need_caps=ok
  [ "$need_gate" = ok ] && ok "OPERATORS.md documents the HEIMDALL_ENROLL_OPEN gate" || bad "OPERATORS.md missing HEIMDALL_ENROLL_OPEN"
  [ "$need_open" = ok ] && ok "OPERATORS.md documents re-gating" || bad "OPERATORS.md missing a re-gate section"
  [ "$need_flip" = ok ] && ok "OPERATORS.md gives the gcloud posture-flip command" || bad "OPERATORS.md missing the gcloud flip command"
  [ "$need_caps" = ok ] && ok "OPERATORS.md documents the enroll cap knobs" || bad "OPERATORS.md missing the cap knobs"
fi

echo
printf "heimdall-enroll-scrub: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

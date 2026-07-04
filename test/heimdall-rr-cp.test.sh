#!/usr/bin/env bash
# test/heimdall-rr-cp.test.sh — acceptance for `rr --mode control-plane`: the
# LOCAL→CONTROL-PLANE handoff (bin/rr dispatch_cp). The client SIGNS + POSTs a
# bounded task to the CP's public ENQUEUE-ONLY route `POST /rr-task`.
#
# HERMETIC: $HOME is a throwaway dir, the CP URL is pinned to an unreachable
# loopback port so the "not enrolled" path degrades OFFLINE (no external
# network), and the identity is supplied via $HMD_HAID so no identity CLI /
# real key is ever consulted. The signing seed + enroll token are NEVER on argv
# and NEVER echoed — proven below.
#
# FALSIFIABLE claims proven:
#   (1) SETUP CP     — `rr setup --mode control-plane --endpoint <u> --repo <r>`
#                      writes remote.json {mode:control-plane, repo} AND updates
#                      ~/.heimdall/cp-endpoint.json {url}.
#   (2) TOKEN SAFE   — `--enroll-token <t>` lands in cp-endpoint.json but is
#                      NEVER echoed to any surface.
#   (3) DRY-RUN PLAN — `rr "<task>" --mode control-plane --dry-run` prints the
#                      `POST <base>/rr-task` plan whose ACTUAL body is a bounded
#                      {text, context, nonce, ts} dict, and EXECUTES nothing (no
#                      enroll, no capsule, no network — no seed/enroll-attempt
#                      side-effects are created).
#   (4) NO TEAM_ID   — the literal client payload JSON carries no `team_id`
#                      (INV-1: team is derived SERVER-SIDE from the signed
#                      binding — the client must not send it).
#   (5) ENROLL FIRST — a REAL cp dispatch with no persisted signing key and an
#                      unreachable CP fails closed with a clear "enroll" message.
#   (6) NO SECRET    — no token-shaped string and no configured enroll token is
#                      ever emitted on any surface.
#
# Fakes in the TEST are fine; production (bin/rr) has no fakes.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RR="$ROOT/bin/rr"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

PY="$(command -v python3 || command -v python)"
[ -f "$RR" ] || { echo "FATAL: $RR missing" >&2; exit 1; }
[ -x "$RR" ] || { echo "FATAL: $RR not executable" >&2; exit 1; }

WORK="$(mktemp -d -t "heimdall-rr-cp-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── isolate HOME; pin the CP url to an unreachable loopback (offline degrade) ───
export HOME="$WORK/home"
mkdir -p "$HOME/.heimdall"
export HMD_HAID="rr-cp-test-haid"            # supply identity → no CLI / real key.
export HEIMDALL_CP_URL="http://127.0.0.1:9"  # discard port: refused instantly.
unset HMD_PRESENCE_SEED 2>/dev/null || true

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ── (1) setup --mode control-plane writes remote.json + cp-endpoint.json ───────
"$RR" setup --mode control-plane --endpoint "https://cp.example/api" --repo acme/widget >/dev/null 2>&1
remote_ok=bad; endpoint_ok=bad
if [ -f "$HOME/.heimdall/remote.json" ]; then
  remote_ok=$("$PY" - "$HOME/.heimdall/remote.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print("ok" if d.get("mode") == "control-plane" and d.get("repo") == "acme/widget" else "bad:%r" % d)
PYEOF
)
fi
if [ -f "$HOME/.heimdall/cp-endpoint.json" ]; then
  endpoint_ok=$("$PY" - "$HOME/.heimdall/cp-endpoint.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print("ok" if d.get("url") == "https://cp.example/api" else "bad:%r" % d)
PYEOF
)
fi
[ "$remote_ok" = ok ] && ok "setup --mode control-plane writes remote.json {mode,repo}" \
                       || bad "remote.json control-plane shape wrong ($remote_ok)"
[ "$endpoint_ok" = ok ] && ok "setup --endpoint updates ~/.heimdall/cp-endpoint.json {url}" \
                        || bad "cp-endpoint.json url wrong ($endpoint_ok)"

# ── (2) --enroll-token is persisted but never echoed ───────────────────────────
setup_out="$("$RR" setup --mode control-plane --endpoint "https://cp.example/api" \
             --enroll-token "SEKRET-TOKEN-abc123" --repo acme/widget 2>&1)"
tok_ok=$("$PY" - "$HOME/.heimdall/cp-endpoint.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print("ok" if d.get("enroll_token") == "SEKRET-TOKEN-abc123" else "bad:%r" % d)
PYEOF
)
[ "$tok_ok" = ok ] && ok "--enroll-token persisted to cp-endpoint.json" \
                   || bad "enroll_token not persisted ($tok_ok)"
if echo "$setup_out" | grep -q "SEKRET-TOKEN"; then
  bad "the enroll token was echoed to stdout (leak)"
else
  ok "enroll token is NEVER echoed on setup"
fi

# ── (3)+(4) dry-run prints the signed POST /rr-task plan; body has no team_id ──
out3="$("$RR" "fix the flaky login test" --mode control-plane --dry-run 2>&1)"
clean3="$(printf '%s\n' "$out3" | strip_ansi)"
has_route=0; echo "$clean3" | grep -q "POST" && echo "$clean3" | grep -q "/rr-task" && has_route=1
[ "$has_route" = 1 ] && ok "dry-run prints the POST <base>/rr-task plan" \
                     || bad "dry-run did not print the /rr-task POST plan"

body_line="$(printf '%s\n' "$clean3" | grep -o 'body={.*}' | head -n1)"
body_json="${body_line#body=}"
if [ -n "$body_json" ]; then
  verdict=$(RR_BODY="$body_json" "$PY" - <<'PYEOF'
import json, os
try:
    d = json.loads(os.environ["RR_BODY"])
except Exception as e:
    print("badjson:%s" % e); raise SystemExit
keys = set(d.keys())
if "team_id" in keys:
    print("has_team_id"); raise SystemExit
if "text" not in keys:
    print("no_text"); raise SystemExit
if "nonce" not in keys or "ts" not in keys:
    print("no_replay"); raise SystemExit
if "context" not in keys:
    print("no_context"); raise SystemExit
print("ok")
PYEOF
)
else
  verdict="no_body_line"
fi
case "$verdict" in
  ok)          ok "dry-run body is {text,context,nonce,ts} — bounded scrubbed DATA" ;;
  has_team_id) bad "the client body CARRIES team_id (INV-1 violation)" ;;
  *)           bad "dry-run body shape wrong ($verdict): $body_json" ;;
esac
if [ "$verdict" = ok ]; then
  ok "client sends NO team_id (team derived SERVER-SIDE — INV-1)"
else
  bad "team_id absence check inconclusive ($verdict)"
fi

# dry-run must execute NOTHING: no enroll (no seed / no enroll-attempt stamp),
# and it must exit 0.
if ! ls "$HOME/.heimdall/pki/"*.seed >/dev/null 2>&1 \
   && ! ls "$HOME/.heimdall/pki/"*.enroll-attempt >/dev/null 2>&1; then
  ok "dry-run executes nothing (no enroll, no seed/enroll-attempt side-effects)"
else
  bad "dry-run created a side-effect (enroll ran during a dry-run)"
fi

# ── (5) real cp dispatch, not enrolled, CP unreachable → fail closed w/ 'enroll' ─
err5="$("$RR" "some cp task" --mode control-plane 2>&1)" && rc5=0 || rc5=$?
if [ "${rc5:-0}" -ne 0 ] && echo "$err5" | strip_ansi | grep -qi "enroll"; then
  ok "not-enrolled cp dispatch fails closed with a clear 'enroll' message"
else
  bad "not-enrolled path did not fail closed with the enroll hint (rc=$rc5): $err5"
fi

# ── (6) no secret ever echoed across surfaces ──────────────────────────────────
allout="$(
  "$RR" "another cp task" --mode control-plane --dry-run 2>&1
  "$RR" setup --mode control-plane --endpoint "https://cp.example/api" --enroll-token "SEKRET-TOKEN-abc123" 2>&1
  echo "$err5"
)"
if echo "$allout" | grep -qE 'SEKRET-TOKEN|gh[ps]_[A-Za-z0-9]{8,}|CLAUDE_CODE_OAUTH_TOKEN=[^ ]'; then
  bad "a secret / token-shaped string leaked into rr output"
else
  ok "no secret is ever echoed (seed + enroll token stay off every surface)"
fi

# ── (7) MODE RESOLUTION — a BARE call (no --mode) honors remote.json mode ───────
# The effective mode is: --mode flag > remote.json .mode > built-in default (vm).
# So a bare `rr "<task>"` against a remote.json {mode:control-plane} MUST route to
# the signed POST /rr-task cp path — NOT the gcloud-ssh VM path. (Regression guard:
# the tab-joined field read collapsed the empty vm/zone/project so mode was lost.)
cat > "$HOME/.heimdall/remote.json" <<'J'
{"mode":"control-plane","repo":"acme/widget","vm":"","zone":"","project":""}
J
bare_cp="$("$RR" "resolve-from-config task" --dry-run 2>&1 | strip_ansi)"
if echo "$bare_cp" | grep -q "POST" && echo "$bare_cp" | grep -q "/rr-task"; then
  ok "bare rr (no --mode) honors remote.json mode=control-plane → signed POST /rr-task"
else
  bad "bare cp-mode did not route to the /rr-task plan: $bare_cp"
fi
if echo "$bare_cp" | grep -q "gcloud compute ssh"; then
  bad "cp-mode plan contains 'gcloud compute ssh' (VM path leaked into control-plane)"
else
  ok "cp-mode plan NEVER contains 'gcloud compute ssh'"
fi
# the capsule must ride the API request BODY (a context field), NEVER an ssh/scp ship.
cap_body="$(printf '%s\n' "$bare_cp" | grep -o 'body={.*}' | head -n1)"
if echo "$bare_cp" | grep -qiE 'capsule[^\n]*ship|scp '; then
  bad "cp-mode ships the context capsule via ssh/scp (must ride the API body)"
elif echo "$cap_body" | grep -q '"context"'; then
  ok "context capsule rides the API request body (context field) in cp mode — no SSH"
else
  bad "context capsule is not an API field in cp mode: $cap_body"
fi

# ── (8) --mode vm OVERRIDES remote.json mode=control-plane → ssh plan ───────────
vm_over="$("$RR" "vm override task" --mode vm --dry-run 2>&1 | strip_ansi)"
if echo "$vm_over" | grep -q "gcloud compute ssh" && ! echo "$vm_over" | grep -q "/rr-task"; then
  ok "--mode vm overrides remote.json mode=control-plane → ssh plan"
else
  bad "--mode vm did not override to the ssh plan: $vm_over"
fi

# ── (9) mode=vm config parses correct fields; --mode control-plane overrides it ─
# Proves the per-line parse keeps vm/zone/project positional (no collapse): the ssh
# plan targets the CONFIGURED vm-x, not a shifted repo slug.
cat > "$HOME/.heimdall/remote.json" <<'J'
{"mode":"vm","repo":"acme/widget","vm":"vm-x","zone":"z-x","project":"p-x"}
J
bare_vm="$("$RR" "vm config task" --dry-run 2>&1 | strip_ansi)"
if echo "$bare_vm" | grep -q "gcloud compute ssh vm-x" && ! echo "$bare_vm" | grep -q "/rr-task"; then
  ok "bare rr honors remote.json mode=vm → ssh plan with CONFIGURED fields (no field-collapse)"
else
  bad "bare vm-mode did not route to ssh vm-x (field-collapse regression?): $bare_vm"
fi
cp_over="$("$RR" "cp override task" --mode control-plane --dry-run 2>&1 | strip_ansi)"
if echo "$cp_over" | grep -q "/rr-task" && ! echo "$cp_over" | grep -q "gcloud compute ssh"; then
  ok "--mode control-plane overrides remote.json mode=vm → signed POST /rr-task"
else
  bad "--mode control-plane did not override the vm config: $cp_over"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "rr-cp: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — cp setup · dry-run signed-POST plan · no team_id · enroll-first · secret-safe"

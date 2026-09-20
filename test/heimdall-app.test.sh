#!/usr/bin/env bash
# test/heimdall-app.test.sh — acceptance for bin/heimdall-app (`hmd app
# connect|status|disconnect|doctor`), Wave 2 of
# .planning/plans/PLAN-hmd-app-connect.md.
#
# heimdall-app composes three already-tested Wave-1 pieces --
# bin/lib/hmd_tailscale.sh, bin/lib/hmd_qr.py, bin/heimdall-ui -- and this
# suite is a black-box oracle over that composition, not a retest of those
# pieces' own internals (see test/hmd-tailscale.test.sh and
# test/heimdall-ui-allowhost.test.sh for those).
#
# Harness style mirrors both: numbered ok()/bad() cases (auto-numbered here,
# in call order, to avoid manual-numbering mistakes across ~70 assertions), a
# mktemp -d sandbox reaped via a trap, and a FAKE tailscale binary (never the
# real tailscaled) driven by FAKE_TS_MODE, injected via HMD_TAILSCALE_BIN --
# copied near-verbatim from test/hmd-tailscale.test.sh's fixture so both
# suites exercise identical fake behaviour. A REAL bin/heimdall-ui is started
# for every "online" scenario; nothing here is mocked at the HTTP layer.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/bin/heimdall-app"
HEIMDALL="$REPO/bin/heimdall"
HMD="$REPO/bin/hmd"
UI="$REPO/bin/heimdall-ui"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "heimdall-app (hmd app connect|status|disconnect|doctor oracle)"

for f in "$APP" "$HEIMDALL" "$HMD" "$UI"; do
  if [ ! -x "$f" ]; then
    printf 'FATAL: required file missing or not executable: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in jq curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

# ── 1. syntax ────────────────────────────────────────────────────────────
SYN_ERR="$(mktemp)"
if bash -n "$APP" 2>"$SYN_ERR"; then
  ok "bash -n bin/heimdall-app"
else
  bad "bash -n bin/heimdall-app: $(cat "$SYN_ERR")"
fi
rm -f "$SYN_ERR"

# ── sandbox ──────────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d)"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
mkdir -p "$HOME/.claude"

PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  # Safety net: reap any --bg-started heimdall-ui a test case forgot to
  # disconnect, found via its own state file (PIDS never tracks these --
  # cmd_connect --bg disowns them from its own job table on purpose).
  local sf leak_pid
  for sf in "$TMPROOT"/repo.*/.heimdall/app/connect.json; do
    [ -f "$sf" ] || continue
    leak_pid="$(jq -r '.pid_ui // empty' "$sf" 2>/dev/null)"
    [ -n "$leak_pid" ] && kill -9 "$leak_pid" 2>/dev/null
  done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

make_repo() {
  mktemp -d "$TMPROOT/repo.XXXXXX"
}

# ── fake tailscale CLI -- near-verbatim copy of test/hmd-tailscale.test.sh's
# fixture (see that file for the authoritative per-mode behaviour spec). The
# one addition is FAKE_TS_LOG: when set, every invocation appends its argv to
# that file, one line per call -- this suite uses it to prove disconnect
# actually issues a funnel-stop command, which hmd-tailscale.test.sh has no
# reason to check since it never exercises heimdall-app's own call sites.
FAKE_BIN="$TMPROOT/tailscale"
cat > "$FAKE_BIN" <<'FAKE_EOF'
#!/usr/bin/env bash
mode="${FAKE_TS_MODE:-online-with-DNSName}"

if [ -n "${FAKE_TS_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$FAKE_TS_LOG"
fi

if [ "$mode" = "not-installed" ]; then
  echo "fake-tailscale: command not found" >&2
  exit 127
fi

cmd="${1:-}"; shift || true

POLICY_HINT='funnel: HTTPS is not enabled for your tailnet. To enable HTTPS certificates and Funnel, visit the admin console: https://login.tailscale.com/admin/dns'

case "$cmd" in
  version)
    echo "1.94.2-fake"
    exit 0
    ;;
  status)
    case "$mode" in
      daemon-down)
        echo "2026/09/20 12:00:00 failed to connect to local Tailscale service; is Tailscale running?" >&2
        exit 1
        ;;
      offline)
        cat <<'JSON'
{"BackendState":"Stopped","Self":{"Online":false,"DNSName":""},"AuthURL":"https://login.tailscale.com/a/fakeauthtoken123"}
JSON
        exit 0
        ;;
      *)
        cat <<'JSON'
{"BackendState":"Running","Self":{"Online":true,"DNSName":"my-machine.tail1a2b3.ts.net."},"AuthURL":""}
JSON
        exit 0
        ;;
    esac
    ;;
  funnel)
    sub="${1:-}"
    case "$sub" in
      --help)
        case "$mode" in
          legacy-funnel)
            cat <<'EOF'
usage: tailscale funnel <port> on|off
Signals Tailscale to enable or disable Funnel for the given port.
EOF
            exit 0
            ;;
          no-funnel)
            echo 'tailscale: unknown command "funnel"' >&2
            exit 1
            ;;
          *)
            cat <<'EOF'
USAGE
  tailscale funnel <target>
  tailscale funnel status [--json]
  tailscale funnel reset

FLAGS
  --bg, --bg=false
    	Run the command as a background process
  --https value
    	Expose an HTTPS server at the specified port (default mode)
EOF
            exit 0
            ;;
        esac
        ;;
      status)
        echo '{"Funnel":{}}'
        exit 0
        ;;
      reset)
        exit 0
        ;;
      --bg)
        if [ "$mode" = "policy-hint-on-funnel-start" ]; then
          echo "$POLICY_HINT" >&2
          exit 1
        fi
        exit 0
        ;;
      *)
        if [ "$mode" = "policy-hint-on-funnel-start" ]; then
          echo "$POLICY_HINT" >&2
          exit 1
        fi
        if [ "$mode" = "bad-https-port" ]; then
          echo "funnel: invalid port; must be one of 443, 8443, 10000" >&2
          exit 1
        fi
        exit 0
        ;;
    esac
    ;;
  serve)
    sub="${1:-}"
    if [ "$sub" = "status" ]; then
      echo '{"Serve":{}}'
      exit 0
    fi
    exit 0
    ;;
  *)
    echo "fake-tailscale: unknown command: $cmd" >&2
    exit 1
    ;;
esac
FAKE_EOF
chmod +x "$FAKE_BIN"

export HMD_TAILSCALE_BIN="$FAKE_BIN"
unset HMD_ASSUME_NO FAKE_TS_MODE FAKE_TS_LOG

# ── 2-5. bare dispatch / usage / unknown subcommand ─────────────────────
OUT="$("$APP" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "bare 'heimdall-app' (no subcommand) exits 0" || bad "bare exit $RC"
printf '%s' "$OUT" | grep -qi "Usage:" && ok "bare invocation prints usage" || bad "bare usage missing: $OUT"

OUT="$("$APP" frobnicate 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "unknown subcommand exits 2" || bad "unknown subcommand exit $RC"
printf '%s' "$OUT" | grep -qi "unknown subcommand" && ok "unknown subcommand names itself in the error" || bad "message missing: $OUT"

OUT="$("$HEIMDALL" app --help 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "'heimdall app --help' dispatches through bin/heimdall, exit 0" || bad "exit $RC"
printf '%s' "$OUT" | grep -qi "connect" && ok "'heimdall app --help' help text mentions connect" || bad "help missing connect: $OUT"

OUT="$("$HMD" app 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "bare 'hmd app' dispatches through bin/hmd, exit 0" || bad "exit $RC: $OUT"

# ── 6. bad --https-port (checked before touching tailscale at all) ──────
D="$(make_repo)"
OUT="$(FAKE_TS_MODE=online-with-DNSName "$APP" connect --repo "$D" --https-port 9999 2>&1)"
RC=$?
[ "$RC" -eq 64 ] && ok "connect --https-port 9999 exits 64" || bad "exit $RC (want 64): $OUT"
printf '%s' "$OUT" | grep -qi "port" && ok "bad-https-port message mentions 'port'" || bad "message: $OUT"
[ ! -f "$D/.heimdall/app/connect.json" ] && ok "no state file written on bad-https-port failure" || bad "state file unexpectedly written"
rm -rf "$D"

# ── 7-8. install prompt (D1: never silent) ──────────────────────────────
D="$(make_repo)"
OUT="$(FAKE_TS_MODE=not-installed "$APP" connect --repo "$D" --no-install 2>&1)"
RC=$?
[ "$RC" -eq 4 ] && ok "connect --no-install (not installed) exits 4" || bad "exit $RC (want 4): $OUT"
printf '%s' "$OUT" | grep -qi "not installed" && ok "--no-install failure mentions 'not installed'" || bad "$OUT"
printf '%s' "$OUT" | grep -qi "hmd would run" && ok "--no-install failure names the manual install command (D1)" || bad "$OUT"
[ ! -f "$D/.heimdall/app/connect.json" ] && ok "no state file written after --no-install failure" || bad "state file written unexpectedly"
rm -rf "$D"

D="$(make_repo)"
OUT="$(FAKE_TS_MODE=not-installed "$APP" connect --repo "$D" </dev/null 2>&1)"
RC=$?
[ "$RC" -eq 4 ] && ok "connect w/o --no-install + closed stdin declines cleanly, exit 4 (no hang)" || bad "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "hmd would run" && ok "closed-stdin decline still shows the manual install command (D1)" || bad "$OUT"
rm -rf "$D"

# ── 9-10. not online ─────────────────────────────────────────────────────
D="$(make_repo)"
OUT="$(FAKE_TS_MODE=daemon-down "$APP" connect --repo "$D" 2>&1)"
RC=$?
[ "$RC" -eq 5 ] && ok "connect w/ tailscaled down exits 5" || bad "exit $RC (want 5): $OUT"
printf '%s' "$OUT" | grep -qi "tailscale up" && ok "daemon-down prints the login hint" || bad "$OUT"
[ ! -f "$D/.heimdall/app/connect.json" ] && ok "no state file written when daemon is down" || bad "state file written"
rm -rf "$D"

D="$(make_repo)"
OUT="$(FAKE_TS_MODE=offline "$APP" connect --repo "$D" 2>&1)"
RC=$?
[ "$RC" -eq 5 ] && ok "connect w/ tailscale logged out exits 5" || bad "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "tailscale up" && ok "logged-out login hint present" || bad "$OUT"
printf '%s' "$OUT" | grep -qF "https://login.tailscale.com/a/fakeauthtoken123" && ok "logged-out login hint includes the AuthURL" || bad "$OUT"
rm -rf "$D"

# ── 11-25. modern funnel, online: the full success path ─────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-online.out"
FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --bg >"$OUT_FILE" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "connect --bg (modern funnel, online) exits 0" || bad "exit $RC: $(cat "$OUT_FILE")"

if grep -Eq 'https://my-machine\.tail1a2b3\.ts\.net/\?token=[A-Za-z0-9_-]+' "$OUT_FILE"; then
  ok "prints the public URL https://<DNSName>/?token=... (default https-port 443, no :port suffix)"
else
  bad "public URL line missing/malformed: $(cat "$OUT_FILE")"
fi

if grep -q '##' "$OUT_FILE"; then
  ok "prints a QR code block (ascii glyphs)"
else
  bad "no QR block detected: $(cat "$OUT_FILE")"
fi

if grep -qi 'reachable from the public internet' "$OUT_FILE"; then
  ok "prints the exposure warning"
else
  bad "exposure warning missing: $(cat "$OUT_FILE")"
fi

SF="$D/.heimdall/app/connect.json"
if [ -f "$SF" ]; then
  ok "state file written at .heimdall/app/connect.json"
else
  bad "state file missing at $SF"
fi

SF_HOST="$(jq -r '.host // empty' "$SF" 2>/dev/null)"
SF_PORT="$(jq -r '.port // empty' "$SF" 2>/dev/null)"
SF_HTTPS="$(jq -r '.https_port // empty' "$SF" 2>/dev/null)"
SF_PID="$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)"
SF_STARTED="$(jq -r '.started_at // empty' "$SF" 2>/dev/null)"

[ "$SF_HOST" = "my-machine.tail1a2b3.ts.net" ] && ok "state file host == fake DNSName, trailing dot stripped" || bad "host=$SF_HOST"
[ "$SF_HTTPS" = "443" ] && ok "state file https_port == 443 (default)" || bad "https_port=$SF_HTTPS"
if [ -n "$SF_PORT" ] && [ "$SF_PORT" -gt 0 ] 2>/dev/null; then ok "state file port is a positive integer"; else bad "port=$SF_PORT"; fi
if [ -n "$SF_PID" ] && kill -0 "$SF_PID" 2>/dev/null; then ok "state file pid_ui refers to a live process"; else bad "pid_ui=$SF_PID not alive"; fi
[ -n "$SF_STARTED" ] && ok "state file has a started_at timestamp" || bad "started_at missing"

if grep -q '"token"' "$SF" 2>/dev/null; then
  bad "state file LEAKS a 'token' key: $(cat "$SF")"
else
  ok "state file never contains a 'token' key"
fi

TOKEN="$(grep -Eo 'token=[A-Za-z0-9_-]+' "$OUT_FILE" | head -1 | sed 's/^token=//')"
if [ -n "$TOKEN" ]; then
  ok "extracted the token from connect's own printed URL"
else
  bad "could not extract a token from output: $(cat "$OUT_FILE")"
fi

STATE_JSON="$TMPROOT/state-online.json"
CODE="$(curl -s -o "$STATE_JSON" -w '%{http_code}' -m 5 -H "Host: my-machine.tail1a2b3.ts.net" "http://127.0.0.1:${SF_PORT}/api/state?token=${TOKEN}")"
if [ "$CODE" = "200" ]; then
  ok "curl w/ Funnel Host header + token -> 200"
else
  bad "curl -> $CODE (want 200)"
fi

if jq -e --arg h "my-machine.tail1a2b3.ts.net" '.transport.public_host == $h' "$STATE_JSON" >/dev/null 2>&1; then
  ok "/api/state.transport.public_host == fake DNSName"
else
  bad "transport.public_host mismatch: $(jq -c '.transport // empty' "$STATE_JSON" 2>/dev/null)"
fi

FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" >/dev/null 2>&1
sleep 0.3
if kill -0 "$SF_PID" 2>/dev/null; then
  bad "teardown: ui pid still alive after disconnect"
else
  ok "teardown: ui pid reaped by disconnect"
fi
rm -rf "$D"

# ── 26-30. tailnet policy blocks funnel ──────────────────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-policy.out"
ERR_FILE="$TMPROOT/connect-policy.err"
FAKE_TS_MODE=policy-hint-on-funnel-start "$APP" connect --repo "$D" --bg >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
[ "$RC" -eq 3 ] && ok "connect under a tailnet policy block exits 3" || bad "exit $RC"
if grep -qF 'funnel: HTTPS is not enabled for your tailnet. To enable HTTPS certificates and Funnel, visit the admin console: https://login.tailscale.com/admin/dns' "$ERR_FILE"; then
  ok "policy hint is printed VERBATIM on stderr"
else
  bad "stderr: $(cat "$ERR_FILE")"
fi
printf '%s' "$(cat "$ERR_FILE")" | grep -qi 'hmd app doctor' && ok "policy-block stderr points at 'hmd app doctor' for diagnostics" || bad "missing doctor pointer: $(cat "$ERR_FILE")"
[ ! -f "$D/.heimdall/app/connect.json" ] && ok "no state file left behind after a policy-block failure" || bad "state file leaked"
sleep 0.3
if pgrep -f "heimdall-ui --repo $D " >/dev/null 2>&1; then
  bad "a heimdall-ui process for $D is still running after the policy-block failure"
else
  ok "no heimdall-ui process left running after the policy-block failure"
fi
rm -rf "$D"

# ── 31-35. status redacts the token ──────────────────────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-for-status.out"
FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --bg >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  bad "setup: connect --bg for the status test failed (exit $RC): $(cat "$OUT_FILE")"
else
  REAL_TOKEN="$(grep -Eo 'token=[A-Za-z0-9_-]+' "$OUT_FILE" | head -1 | sed 's/^token=//')"
  STATUS_OUT="$(FAKE_TS_MODE=modern-funnel "$APP" status --repo "$D" 2>&1)"
  SRC=$?
  [ "$SRC" -eq 0 ] && ok "status exits 0" || bad "status exit $SRC"
  if [ -n "$REAL_TOKEN" ] && printf '%s' "$STATUS_OUT" | grep -qF "$REAL_TOKEN"; then
    bad "status output LEAKS the real token"
  else
    ok "status output never contains the real token"
  fi
  printf '%s' "$STATUS_OUT" | grep -q 'token=<redacted>' && ok "status shows a redacted token placeholder" || bad "no redacted placeholder: $STATUS_OUT"
  printf '%s' "$STATUS_OUT" | grep -q 'connected: yes' && ok "status reports connected: yes" || bad "$STATUS_OUT"
  printf '%s' "$STATUS_OUT" | grep -qi 'inbox pending' && ok "status reports the pending inbox count" || bad "$STATUS_OUT"
  FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" >/dev/null 2>&1
fi
rm -rf "$D"

# ── 36-40. disconnect kills the ui and is idempotent ─────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-for-disconnect.out"
FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --bg >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  bad "setup: connect --bg for the disconnect test failed: $(cat "$OUT_FILE")"
else
  SF="$D/.heimdall/app/connect.json"
  DC_PID="$(jq -r '.pid_ui' "$SF" 2>/dev/null)"
  DC_PORT="$(jq -r '.port' "$SF" 2>/dev/null)"
  DISC_OUT="$(FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" 2>&1)"
  DRC=$?
  [ "$DRC" -eq 0 ] && ok "disconnect exits 0" || bad "exit $DRC: $DISC_OUT"
  sleep 0.3
  if kill -0 "$DC_PID" 2>/dev/null; then bad "ui pid still alive after disconnect"; else ok "disconnect kills the ui pid"; fi
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:${DC_PORT}/" 2>/dev/null)"
  [ "$CODE" = "000" ] && ok "ui port no longer accepts connections after disconnect" || bad "port $DC_PORT still answering (code=$CODE)"
  [ ! -f "$SF" ] && ok "state file removed after disconnect" || bad "state file still present"
  DISC_OUT2="$(FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" 2>&1)"
  DRC2=$?
  [ "$DRC2" -eq 0 ] && ok "second disconnect (idempotent) exits 0" || bad "exit $DRC2: $DISC_OUT2"
fi
rm -rf "$D"

# ── 41-55. doctor ─────────────────────────────────────────────────────────
D="$(make_repo)"

DOC_NI="$(FAKE_TS_MODE=not-installed "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
[ "$DRC" -ne 0 ] && ok "doctor (not-installed) exits nonzero" || bad "exit $DRC (want nonzero)"
printf '%s' "$DOC_NI" | grep -q 'FAIL.*tailscale installed' && ok "doctor (not-installed) flags 'tailscale installed'" || bad "$DOC_NI"
printf '%s' "$DOC_NI" | grep -qi 'fix:' && ok "doctor prints a fix hint per failure" || bad "no fix hint: $DOC_NI"

DOC_DD="$(FAKE_TS_MODE=daemon-down "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
[ "$DRC" -ne 0 ] && ok "doctor (daemon-down) exits nonzero" || bad "exit $DRC"
printf '%s' "$DOC_DD" | grep -q 'ok.*tailscale installed' && ok "doctor (daemon-down): tailscale-installed still ok" || bad "$DOC_DD"
printf '%s' "$DOC_DD" | grep -q 'FAIL.*tailscale daemon running' && ok "doctor (daemon-down) flags 'tailscale daemon running'" || bad "$DOC_DD"

DOC_OFF="$(FAKE_TS_MODE=offline "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
[ "$DRC" -ne 0 ] && ok "doctor (offline/logged-out) exits nonzero" || bad "exit $DRC"
printf '%s' "$DOC_OFF" | grep -q 'ok.*tailscale daemon running' && ok "doctor (offline): daemon-running still ok" || bad "$DOC_OFF"
printf '%s' "$DOC_OFF" | grep -q 'FAIL.*logged in / online' && ok "doctor (offline) flags 'logged in / online'" || bad "$DOC_OFF"

DOC_HAPPY="$(FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
[ "$DRC" -eq 0 ] && ok "doctor (fully happy fake) exits 0" || bad "exit $DRC: $DOC_HAPPY"
printf '%s' "$DOC_HAPPY" | grep -q 'all checks passed' && ok "doctor (happy) prints the all-checks-passed summary" || bad "$DOC_HAPPY"

DOC_NF="$(FAKE_TS_MODE=no-funnel "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
[ "$DRC" -ne 0 ] && ok "doctor (no-funnel) exits nonzero" || bad "exit $DRC"
printf '%s' "$DOC_NF" | grep -q 'FAIL.*funnel capability' && ok "doctor (no-funnel) flags 'funnel capability'" || bad "$DOC_NF"

DOC_BADPORT="$(FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" --https-port 9999 2>&1)"; DRC=$?
[ "$DRC" -ne 0 ] && ok "doctor with a bad --https-port exits nonzero" || bad "exit $DRC"
printf '%s' "$DOC_BADPORT" | grep -q 'FAIL.*https-port allowed' && ok "doctor flags a bad --https-port" || bad "$DOC_BADPORT"

rm -rf "$D"

# ── 56-59. unknown flags rejected on every subcommand ────────────────────
OUT="$("$APP" connect --bogus-flag 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "connect rejects an unknown flag, exit 2" || bad "exit $RC: $OUT"

OUT="$("$APP" status --bogus-flag 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "status rejects an unknown flag, exit 2" || bad "exit $RC: $OUT"

OUT="$("$APP" disconnect --bogus-flag 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "disconnect rejects an unknown flag, exit 2" || bad "exit $RC: $OUT"

OUT="$("$APP" doctor --bogus-flag 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "doctor rejects an unknown flag, exit 2" || bad "exit $RC: $OUT"

# ── 60-63. status/disconnect on a repo that was never connected ─────────
D="$(make_repo)"
OUT="$(FAKE_TS_MODE=online-with-DNSName "$APP" status --repo "$D" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "status on a never-connected repo exits 0" || bad "exit $RC"
printf '%s' "$OUT" | grep -q 'connected: no' && ok "status on a never-connected repo reports connected: no" || bad "$OUT"

OUT="$("$APP" disconnect --repo "$D" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "disconnect on a never-connected repo exits 0" || bad "exit $RC"
printf '%s' "$OUT" | grep -qi 'not connected' && ok "disconnect on a never-connected repo reports not connected" || bad "$OUT"
rm -rf "$D"

# ── 64-67. legacy funnel CLI (serve + funnel PORT on/off recipe) ────────
D="$(make_repo)"
LOG="$TMPROOT/ts-legacy.log"
: > "$LOG"
OUT_FILE="$TMPROOT/connect-legacy.out"
FAKE_TS_MODE=legacy-funnel FAKE_TS_LOG="$LOG" "$APP" connect --repo "$D" --bg >"$OUT_FILE" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "connect --bg (legacy funnel CLI) exits 0" || bad "exit $RC: $(cat "$OUT_FILE")"
if grep -Eq 'https://my-machine\.tail1a2b3\.ts\.net/\?token=[A-Za-z0-9_-]+' "$OUT_FILE"; then
  ok "legacy-funnel connect prints the public URL"
else
  bad "$(cat "$OUT_FILE")"
fi
grep -q '^serve https / http://127.0.0.1:' "$LOG" && ok "legacy funnel start used the 'serve https /' recipe" || bad "ts invocation log: $(cat "$LOG")"
grep -q '^funnel 443 on$' "$LOG" && ok "legacy funnel start used 'funnel 443 on'" || bad "ts invocation log: $(cat "$LOG")"
FAKE_TS_MODE=legacy-funnel FAKE_TS_LOG="$LOG" "$APP" disconnect --repo "$D" >/dev/null 2>&1
grep -q '^funnel 443 off$' "$LOG" && ok "legacy funnel stop used 'funnel 443 off'" || bad "ts invocation log: $(cat "$LOG")"
rm -rf "$D"

# ── 68-72. foreground wait + signal-based teardown ───────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-fg.out"
( FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" >"$OUT_FILE" 2>&1 ) &
FG_PID=$!
PIDS+=("$FG_PID")

SF="$D/.heimdall/app/connect.json"
FG_WAITED=0
while [ ! -f "$SF" ] && [ "$FG_WAITED" -lt 50 ]; do
  sleep 0.2
  FG_WAITED=$((FG_WAITED + 1))
done

if [ -f "$SF" ]; then
  ok "foreground connect (no --bg) writes the state file while it waits"
  FG_UI_PID="$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)"
  if [ -n "$FG_UI_PID" ] && kill -0 "$FG_UI_PID" 2>/dev/null; then
    ok "foreground connect's ui process is alive while connect waits"
  else
    bad "ui pid $FG_UI_PID not alive"
  fi

  kill -TERM "$FG_PID" 2>/dev/null
  TERM_WAITED=0
  while kill -0 "$FG_PID" 2>/dev/null && [ "$TERM_WAITED" -lt 50 ]; do
    sleep 0.2
    TERM_WAITED=$((TERM_WAITED + 1))
  done
  if kill -0 "$FG_PID" 2>/dev/null; then
    bad "connect process did not exit within 10s of SIGTERM"
    kill -9 "$FG_PID" 2>/dev/null
  else
    ok "connect process exits on SIGTERM (foreground trap fired)"
  fi

  sleep 0.3
  if [ -n "$FG_UI_PID" ] && kill -0 "$FG_UI_PID" 2>/dev/null; then
    bad "ui process still alive after connect received SIGTERM -- trap cleanup leaked it"
    kill -9 "$FG_UI_PID" 2>/dev/null
  else
    ok "ui process reaped by the SIGTERM trap's cleanup()"
  fi
  if [ -f "$SF" ]; then
    bad "state file still present after SIGTERM teardown"
  else
    ok "state file removed by the SIGTERM trap's cleanup()"
  fi
else
  bad "foreground connect never wrote a state file within 10s: $(cat "$OUT_FILE" 2>/dev/null)"
  bad "skipped: ui-alive check (setup failed)"
  bad "skipped: SIGTERM exit check (setup failed)"
  bad "skipped: ui-reaped check (setup failed)"
  bad "skipped: state-file-removed check (setup failed)"
  kill "$FG_PID" 2>/dev/null
fi
wait "$FG_PID" 2>/dev/null
rm -rf "$D"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

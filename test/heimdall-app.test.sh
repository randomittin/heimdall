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
export TMPDIR="$TMPROOT"
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
        dns="${FAKE_TS_DNSNAME:-my-machine.tail1a2b3.ts.net.}"
        printf '{"BackendState":"Running","Self":{"Online":true,"DNSName":"%s"},"AuthURL":""}\n' "$dns"
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
        # N1: two new stateful modes let a test observe the *after* of a
        # stop, not just its exit code -- FAKE_TS_RESET_MARKER names a file
        # this same script touches from the reset) case below when set, so
        # a test can prove "stop ran, and status now agrees it's down"
        # instead of trusting rc alone (rc=0 never meant "actually down" --
        # that's the bug N1 fixes). Every pre-existing mode ignores the
        # marker entirely, unchanged.
        marker_down=false
        if [ -n "${FAKE_TS_RESET_MARKER:-}" ] && [ -f "${FAKE_TS_RESET_MARKER:-}" ]; then
          marker_down=true
        fi
        case "$mode" in
          funnel-still-up)
            echo '{"Funnel":{"443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}'
            ;;
          one-foreign-target)
            # Populates .Web (what ts_funnel_foreign_targets reads) AND
            # .Funnel (what _funnel_looks_up reads) so the two agree --
            # unlike funnel-still-up above, which deliberately only sets
            # .Funnel to model the "rc=0 but no foreign-target info" case.
            if [ "$marker_down" = true ]; then
              echo '{"Funnel":{}}'
            else
              jq -n --arg p "${FAKE_TS_TARGET_PORT:-5601}" \
                '{Funnel:{"443":{Handlers:{"/":{Proxy:"http://127.0.0.1:9999"}}}}, Web:{h1:{Handlers:{"/":{Proxy:("http://127.0.0.1:"+$p)}}}}}'
            fi
            ;;
          two-foreign-targets)
            if [ "$marker_down" = true ]; then
              echo '{"Funnel":{}}'
            else
              jq -n \
                '{Funnel:{"443":{Handlers:{"/":{Proxy:"http://127.0.0.1:9999"}}}}, Web:{h1:{Handlers:{"/":{Proxy:"http://127.0.0.1:5601"}}},h2:{Handlers:{"/":{Proxy:"http://127.0.0.1:5602"}}}}}'
            fi
            ;;
          *)
            echo '{"Funnel":{}}'
            ;;
        esac
        exit 0
        ;;
      reset)
        if [ -n "${FAKE_TS_RESET_MARKER:-}" ]; then
          : > "${FAKE_TS_RESET_MARKER:-}" 2>/dev/null || true
        fi
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
unset HMD_ASSUME_NO FAKE_TS_MODE FAKE_TS_LOG FAKE_TS_DNSNAME

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
FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --port 0 --bg >"$OUT_FILE" 2>&1
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
SF_REAP_WAITED=0
while kill -0 "$SF_PID" 2>/dev/null && [ "$SF_REAP_WAITED" -lt 30 ]; do
  sleep 0.1
  SF_REAP_WAITED=$((SF_REAP_WAITED + 1))
done
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
FAKE_TS_MODE=policy-hint-on-funnel-start "$APP" connect --repo "$D" --port 0 --bg >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
[ "$RC" -eq 3 ] && ok "connect under a tailnet policy block exits 3" || bad "exit $RC"
if grep -qF 'funnel: HTTPS is not enabled for your tailnet. To enable HTTPS certificates and Funnel, visit the admin console: https://login.tailscale.com/admin/dns' "$ERR_FILE"; then
  ok "policy hint is printed VERBATIM on stderr"
else
  bad "stderr: $(cat "$ERR_FILE")"
fi
printf '%s' "$(cat "$ERR_FILE")" | grep -qi 'hmd app doctor' && ok "policy-block stderr points at 'hmd app doctor' for diagnostics" || bad "missing doctor pointer: $(cat "$ERR_FILE")"
[ ! -f "$D/.heimdall/app/connect.json" ] && ok "no state file left behind after a policy-block failure" || bad "state file leaked"
POLICY_UI_WAITED=0
while pgrep -f "heimdall-ui --repo $D " >/dev/null 2>&1 && [ "$POLICY_UI_WAITED" -lt 30 ]; do
  sleep 0.1
  POLICY_UI_WAITED=$((POLICY_UI_WAITED + 1))
done
if pgrep -f "heimdall-ui --repo $D " >/dev/null 2>&1; then
  bad "a heimdall-ui process for $D is still running after the policy-block failure"
else
  ok "no heimdall-ui process left running after the policy-block failure"
fi
rm -rf "$D"

# ── 31-35. status redacts the token ──────────────────────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-for-status.out"
FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --port 0 --bg >"$OUT_FILE" 2>&1
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
FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --port 0 --bg >"$OUT_FILE" 2>&1
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
  DC_WAITED=0
  while kill -0 "$DC_PID" 2>/dev/null && [ "$DC_WAITED" -lt 30 ]; do
    sleep 0.1
    DC_WAITED=$((DC_WAITED + 1))
  done
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
FAKE_TS_MODE=legacy-funnel FAKE_TS_LOG="$LOG" "$APP" connect --repo "$D" --port 0 --bg >"$OUT_FILE" 2>&1
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
( FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
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

  FG_UI_REAP_WAITED=0
  while [ -n "$FG_UI_PID" ] && kill -0 "$FG_UI_PID" 2>/dev/null && [ "$FG_UI_REAP_WAITED" -lt 30 ]; do
    sleep 0.1
    FG_UI_REAP_WAITED=$((FG_UI_REAP_WAITED + 1))
  done
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

# ── A4(a). disconnect with no state file still stops any orphaned funnel ──
D="$(make_repo)"
LOG="$TMPROOT/ts-a4a.log"
: > "$LOG"
OUT="$(FAKE_TS_MODE=legacy-funnel FAKE_TS_LOG="$LOG" "$APP" disconnect --repo "$D" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "A4a. disconnect w/ no state file still exits 0" || bad "exit $RC: $OUT"
grep -q '^funnel 443 off$' "$LOG" && ok "A4a. disconnect w/ no state file still calls funnel-stop (no orphaned funnel survives disconnect)" || bad "ts invocation log: $(cat "$LOG")"
rm -rf "$D"

# ── A4(b). connect defaults to the fixed port 8710; busy -> exit 6 ───────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-a4b-default.out"
FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --bg >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
  SF="$D/.heimdall/app/connect.json"
  DP="$(jq -r '.port // empty' "$SF" 2>/dev/null)"
  [ "$DP" = "8710" ] && ok "A4b. connect w/ no --port defaults to the fixed port 8710" || bad "port=$DP (want 8710)"
  FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" >/dev/null 2>&1
else
  bad "A4b setup: connect (no --port) failed: $(cat "$OUT_FILE")"
fi
rm -rf "$D"

D="$(make_repo)"
python3 - <<'PYEOF' &
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8710))
s.listen(1)
time.sleep(20)
PYEOF
HOLD_PID=$!
PIDS+=("$HOLD_PID")
HOLD_WAITED=0
while ! exec 3<>/dev/tcp/127.0.0.1/8710 2>/dev/null && [ "$HOLD_WAITED" -lt 50 ]; do
  sleep 0.1
  HOLD_WAITED=$((HOLD_WAITED + 1))
done
exec 3<&- 2>/dev/null || true
OUT="$(FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --bg 2>&1)"; RC=$?
[ "$RC" -eq 6 ] && ok "A4b. connect w/ the fixed default port (8710) busy exits 6" || bad "exit $RC (want 6): $OUT"
kill "$HOLD_PID" 2>/dev/null
wait "$HOLD_PID" 2>/dev/null
rm -rf "$D"

# ── A4(c). status detects an orphaned funnel (ui dead, funnel still up) ──
D="$(make_repo)"
mkdir -p "$D/.heimdall/app"
cat > "$D/.heimdall/app/connect.json" <<JSON
{"pid_ui": 1, "port": 9999, "https_port": 443, "host": "my-machine.tail1a2b3.ts.net", "started_at": "2026-01-01T00:00:00Z"}
JSON
OUT="$(FAKE_TS_MODE=funnel-still-up "$APP" status --repo "$D" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "A4c. status w/ a stale pid + funnel still up exits nonzero" || bad "exit $RC (want nonzero)"
printf '%s' "$OUT" | grep -qi 'ORPHANED FUNNEL' && ok "A4c. status prints an ORPHANED FUNNEL warning" || bad "$OUT"
rm -rf "$D"

# ── A4(d). connect tears down a pre-existing funnel before starting a new one ──
D0="$(make_repo)"
LOG0="$TMPROOT/ts-a4d-baseline.log"
: > "$LOG0"
FAKE_TS_MODE=modern-funnel FAKE_TS_LOG="$LOG0" "$APP" connect --repo "$D0" --bg --port 0 >/dev/null 2>&1
BASELINE_COUNT="$(grep -c '^funnel' "$LOG0")"
FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D0" >/dev/null 2>&1
rm -rf "$D0"

D="$(make_repo)"
LOG="$TMPROOT/ts-a4d.log"
: > "$LOG"
OUT_FILE="$TMPROOT/connect-a4d.out"
FAKE_TS_MODE=funnel-still-up FAKE_TS_LOG="$LOG" "$APP" connect --repo "$D" --bg --port 0 >"$OUT_FILE" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "A4d. connect w/ a pre-existing funnel still exits 0" || bad "exit $RC: $(cat "$OUT_FILE")"
grep -qi 'tearing it down' "$OUT_FILE" && ok "A4d. connect announces tearing down the pre-existing funnel" || bad "$(cat "$OUT_FILE")"
A4D_COUNT="$(grep -c '^funnel' "$LOG")"
[ "$A4D_COUNT" -gt "$BASELINE_COUNT" ] && ok "A4d. connect issued an extra tailscale funnel call to tear it down ($A4D_COUNT calls vs $BASELINE_COUNT baseline)" || bad "no extra funnel call: $A4D_COUNT vs baseline $BASELINE_COUNT"
FAKE_TS_MODE=funnel-still-up "$APP" disconnect --repo "$D" >/dev/null 2>&1
rm -rf "$D"

# ── A4(e). foreground wait also tears down on SIGHUP ──────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-hup.out"
( FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
HUP_FG_PID=$!
PIDS+=("$HUP_FG_PID")

SF="$D/.heimdall/app/connect.json"
HUP_WAITED=0
while [ ! -f "$SF" ] && [ "$HUP_WAITED" -lt 50 ]; do
  sleep 0.2
  HUP_WAITED=$((HUP_WAITED + 1))
done

if [ -f "$SF" ]; then
  ok "A4e setup: foreground connect wrote a state file before SIGHUP"
  HUP_UI_PID="$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)"

  kill -HUP "$HUP_FG_PID" 2>/dev/null
  HTERM_WAITED=0
  while kill -0 "$HUP_FG_PID" 2>/dev/null && [ "$HTERM_WAITED" -lt 50 ]; do
    sleep 0.2
    HTERM_WAITED=$((HTERM_WAITED + 1))
  done
  if kill -0 "$HUP_FG_PID" 2>/dev/null; then
    bad "A4e. connect process did not exit within 10s of SIGHUP"
    kill -9 "$HUP_FG_PID" 2>/dev/null
  else
    ok "A4e. connect process exits on SIGHUP (foreground trap fired)"
  fi

  HUP_UI_REAP_WAITED=0
  while [ -n "$HUP_UI_PID" ] && kill -0 "$HUP_UI_PID" 2>/dev/null && [ "$HUP_UI_REAP_WAITED" -lt 30 ]; do
    sleep 0.1
    HUP_UI_REAP_WAITED=$((HUP_UI_REAP_WAITED + 1))
  done
  if [ -n "$HUP_UI_PID" ] && kill -0 "$HUP_UI_PID" 2>/dev/null; then
    bad "A4e. ui process still alive after connect received SIGHUP -- trap cleanup leaked it"
    kill -9 "$HUP_UI_PID" 2>/dev/null
  else
    ok "A4e. ui process reaped by the SIGHUP trap's cleanup()"
  fi
else
  bad "A4e setup: foreground connect never wrote a state file within 10s: $(cat "$OUT_FILE" 2>/dev/null)"
  bad "A4e. skipped: SIGHUP exit check (setup failed)"
  bad "A4e. skipped: ui-reaped check (setup failed)"
  kill "$HUP_FG_PID" 2>/dev/null
fi
wait "$HUP_FG_PID" 2>/dev/null
rm -rf "$D"

# ── A5. the pairing URL/token is never visible in hmd_qr.py's argv (ps) ───
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-a5.out"
( FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
A5_FG_PID=$!
PIDS+=("$A5_FG_PID")

SF="$D/.heimdall/app/connect.json"
A5_WAITED=0
while [ ! -f "$SF" ] && [ "$A5_WAITED" -lt 50 ]; do
  sleep 0.05
  A5_WAITED=$((A5_WAITED + 1))
done

A5_SAW_HMD_QR=false
A5_LEAKED=false
A5_POLLS=0
while [ "$A5_POLLS" -lt 400 ]; do
  A5_PS="$(ps -eo command= 2>/dev/null | grep hmd_qr.py | grep -v grep || true)"
  if [ -n "$A5_PS" ]; then
    A5_SAW_HMD_QR=true
    if printf '%s' "$A5_PS" | grep -q 'token='; then
      A5_LEAKED=true
    fi
  fi
  A5_POLLS=$((A5_POLLS + 1))
done

if [ "$A5_SAW_HMD_QR" = true ]; then
  if [ "$A5_LEAKED" = true ]; then
    bad "A5. hmd_qr.py argv LEAKS the token during connect"
  else
    ok "A5. hmd_qr.py argv never shows token= while connect runs (observed it live, clean)"
  fi
else
  bad "A5. never observed a live hmd_qr.py process to check (inconclusive -- widen the poll window)"
fi

kill -TERM "$A5_FG_PID" 2>/dev/null
wait "$A5_FG_PID" 2>/dev/null
rm -rf "$D"

# ── A6. ui log temp file is 0600 (mktemp + umask 077) ─────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-a6-mode.out"
( FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
A6_FG_PID=$!
PIDS+=("$A6_FG_PID")

SF="$D/.heimdall/app/connect.json"
A6_WAITED=0
while [ ! -f "$SF" ] && [ "$A6_WAITED" -lt 50 ]; do
  sleep 0.2
  A6_WAITED=$((A6_WAITED + 1))
done

if [ -f "$SF" ]; then
  A6_UI_PID="$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)"
  # heimdall-app's UI_OUT is an internal, unexported mktemp path -- macOS's
  # native mktemp ignores $TMPDIR for a template-less call (confirmed
  # empirically: TMPDIR=/tmp mktemp still lands under the Darwin per-user
  # temp dir, never under the requested TMPDIR), so a before/after directory
  # listing diff under $TMPROOT can never find it. Resolve it directly
  # instead, the same way test/heimdall-ui.test.sh:424 confirms a listening
  # port -- via lsof against the live process -- here its stdout fd (1),
  # which is exactly where connect redirects UI_OUT.
  if command -v lsof >/dev/null 2>&1 && [ -n "$A6_UI_PID" ]; then
    UI_OUT_PATH="$(lsof -a -p "$A6_UI_PID" -d 1 -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    if [ -n "$UI_OUT_PATH" ] && [ -f "$UI_OUT_PATH" ]; then
      MODE="$(stat -f '%Lp' "$UI_OUT_PATH" 2>/dev/null || stat -c '%a' "$UI_OUT_PATH" 2>/dev/null)"
      [ "$MODE" = "600" ] && ok "A6. ui log temp file created with mode 0600" || bad "A6. ui log temp file mode=$MODE (want 600): $UI_OUT_PATH"
    else
      bad "A6. lsof found no resolvable stdout path for ui pid $A6_UI_PID"
    fi
  else
    ok "A6. (skipped: no lsof, or no ui pid to inspect)"
  fi
  kill -TERM "$A6_FG_PID" 2>/dev/null
  wait "$A6_FG_PID" 2>/dev/null
else
  bad "A6. setup: foreground connect never wrote a state file within 10s: $(cat "$OUT_FILE" 2>/dev/null)"
  kill "$A6_FG_PID" 2>/dev/null
  wait "$A6_FG_PID" 2>/dev/null
fi
rm -rf "$D"

# ── A6. die-race stderr redacts the token instead of raw-catting it ──────
FAKE_UI_DIES="$TMPROOT/fake-ui-dies.sh"
cat > "$FAKE_UI_DIES" <<'EOF'
#!/usr/bin/env bash
echo "hmd-ui: fatal startup error, last known token=SECRETVALUE12345 discarded" >&2
exit 1
EOF
chmod +x "$FAKE_UI_DIES"

D="$(make_repo)"
ERR_FILE="$TMPROOT/connect-a6-race.err"
OUT_FILE="$TMPROOT/connect-a6-race.out"
HEIMDALL_UI_BIN="$FAKE_UI_DIES" FAKE_TS_MODE=modern-funnel "$APP" connect --repo "$D" --port 0 >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
[ "$RC" -eq 6 ] && ok "A6. connect w/ a ui that dies before printing a URL exits 6" || bad "exit $RC (want 6): $(cat "$ERR_FILE")"
if grep -q 'SECRETVALUE12345' "$ERR_FILE"; then
  bad "A6. die-race stderr LEAKS the raw token: $(cat "$ERR_FILE")"
else
  ok "A6. die-race stderr never contains the raw token"
fi
grep -q 'token=<redacted>' "$ERR_FILE" && ok "A6. die-race stderr shows the redacted placeholder instead" || bad "$(cat "$ERR_FILE")"
rm -rf "$D"

# ── A12. DNSName is validated before use as --allow-host ─────────────────
D="$(make_repo)"
OUT="$(FAKE_TS_DNSNAME='evil.example.com' FAKE_TS_MODE=online-with-DNSName "$APP" connect --repo "$D" --bg --port 0 2>&1)"; RC=$?
[ "$RC" -eq 5 ] && ok "A12. connect w/ a non-ts.net DNSName exits 5" || bad "exit $RC (want 5): $OUT"
printf '%s' "$OUT" | grep -qF 'evil.example.com' && ok "A12. bad-DNSName error quotes the offending value" || bad "$OUT"
[ ! -f "$D/.heimdall/app/connect.json" ] && ok "A12. no state file written on bad-DNSName failure" || bad "state file leaked"
rm -rf "$D"

D="$(make_repo)"
OUT="$(FAKE_TS_DNSNAME='bad host.ts.net' FAKE_TS_MODE=online-with-DNSName "$APP" connect --repo "$D" --bg --port 0 2>&1)"; RC=$?
[ "$RC" -eq 5 ] && ok "A12. connect w/ a DNSName containing a space exits 5" || bad "exit $RC (want 5): $OUT"
rm -rf "$D"

# ── A14. disconnect never kills a pid that isn't actually heimdall-ui ────
D="$(make_repo)"
sleep 60 &
SLEEP_PID=$!
PIDS+=("$SLEEP_PID")
mkdir -p "$D/.heimdall/app"
cat > "$D/.heimdall/app/connect.json" <<JSON
{"pid_ui": $SLEEP_PID, "port": 9999, "https_port": 443, "host": "my-machine.tail1a2b3.ts.net", "started_at": "2026-01-01T00:00:00Z"}
JSON
OUT="$(FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "A14. disconnect w/ a non-heimdall-ui pid in state file still exits 0" || bad "exit $RC: $OUT"
if kill -0 "$SLEEP_PID" 2>/dev/null; then
  ok "A14. disconnect does NOT kill a pid whose command isn't heimdall-ui (recycled-pid guard)"
else
  bad "A14. disconnect killed an unrelated sleep process -- pid-identity guard missing"
fi
printf '%s' "$OUT" | grep -qi 'not a heimdall-ui process' && ok "A14. disconnect warns when skipping a non-matching pid" || bad "$OUT"
kill "$SLEEP_PID" 2>/dev/null
wait "$SLEEP_PID" 2>/dev/null
rm -rf "$D"

# ── N1(a). ts_funnel_stop refuses (exit 7) -- loud, never claims "stopped" ──
D="$(make_repo)"
mkdir -p "$D/.heimdall/app"
cat > "$D/.heimdall/app/connect.json" <<JSON
{"pid_ui": 1, "port": 6000, "https_port": 443, "host": "my-machine.tail1a2b3.ts.net", "started_at": "2026-01-01T00:00:00Z"}
JSON
LOG="$TMPROOT/ts-n1a.log"
: > "$LOG"
N1A_OUT="$(FAKE_TS_MODE=one-foreign-target FAKE_TS_TARGET_PORT=5601 FAKE_TS_LOG="$LOG" "$APP" disconnect --repo "$D" 2>&1)"; N1A_RC=$?
[ "$N1A_RC" -eq 7 ] && ok "N1a. disconnect refuses (exit 7) when a foreign target doesn't match hmd's own port" || bad "exit $N1A_RC (want 7): $N1A_OUT"
printf '%s' "$N1A_OUT" | grep -qF 'FUNNEL STILL PUBLIC' && ok "N1a. refusal prints the loud FUNNEL STILL PUBLIC line" || bad "$N1A_OUT"
printf '%s' "$N1A_OUT" | grep -qi 'stopped' && bad "N1a. refusal must never claim success: $N1A_OUT" || ok "N1a. refusal never prints 'stopped'"
grep -q '^funnel reset$' "$LOG" && bad "N1a. refused stop must not have attempted a reset: $(cat "$LOG")" || ok "N1a. refusal never attempted a reset"
rm -rf "$D"

# ── N1(b). stop's own rc says success but status still shows it up -> 8 ──
D="$(make_repo)"
mkdir -p "$D/.heimdall/app"
cat > "$D/.heimdall/app/connect.json" <<JSON
{"pid_ui": 1, "port": 6000, "https_port": 443, "host": "my-machine.tail1a2b3.ts.net", "started_at": "2026-01-01T00:00:00Z"}
JSON
N1B_OUT="$(FAKE_TS_MODE=funnel-still-up "$APP" disconnect --repo "$D" 2>&1)"; N1B_RC=$?
[ "$N1B_RC" -eq 8 ] && ok "N1b. disconnect exits 8 when the stop's own exit code says success but the funnel is still up" || bad "exit $N1B_RC (want 8): $N1B_OUT"
printf '%s' "$N1B_OUT" | grep -qF 'FUNNEL STILL PUBLIC' && ok "N1b. exit-8 case prints the loud FUNNEL STILL PUBLIC line" || bad "$N1B_OUT"
printf '%s' "$N1B_OUT" | grep -qi 'stopped' && bad "N1b. must never claim 'stopped' while still public: $N1B_OUT" || ok "N1b. never prints 'stopped'"
rm -rf "$D"

# ── N1(c). clean stop verifies down -> exit 0, prints 'stopped' ──────────
D="$(make_repo)"
mkdir -p "$D/.heimdall/app"
cat > "$D/.heimdall/app/connect.json" <<JSON
{"pid_ui": 1, "port": 6000, "https_port": 443, "host": "my-machine.tail1a2b3.ts.net", "started_at": "2026-01-01T00:00:00Z"}
JSON
N1C_OUT="$(FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" 2>&1)"; N1C_RC=$?
[ "$N1C_RC" -eq 0 ] && ok "N1c. clean stop (verified down) exits 0" || bad "exit $N1C_RC: $N1C_OUT"
printf '%s' "$N1C_OUT" | grep -qi 'stopped' && ok "N1c. clean stop prints 'stopped'" || bad "$N1C_OUT"
rm -rf "$D"

# ── N1(d). no state file, exactly one loopback target -> that port is
# inferred and used instead of refusing (contrast N1e below: two targets
# under otherwise-identical conditions refuse). The port itself never
# appears in a tailscale argv for this call shape (it's a hmd-side JSON
# filter, not a CLI arg) -- what the log CAN and does prove is that the
# stop actually proceeded (funnel reset attempted) rather than being
# refused, which is exactly what a wrong/absent inference would break ────
D="$(make_repo)"
LOG="$TMPROOT/ts-n1d.log"
: > "$LOG"
N1D_OUT="$(FAKE_TS_MODE=one-foreign-target FAKE_TS_TARGET_PORT=5601 FAKE_TS_LOG="$LOG" FAKE_TS_RESET_MARKER="$TMPROOT/n1d.marker" "$APP" disconnect --repo "$D" 2>&1)"; N1D_RC=$?
[ "$N1D_RC" -eq 0 ] && ok "N1d. no state file + a single loopback target infers that port and stops cleanly" || bad "exit $N1D_RC: $N1D_OUT"
grep -q '^funnel reset$' "$LOG" && ok "N1d. the discovered single target let the stop proceed (funnel reset attempted, not refused)" || bad "ts invocation log: $(cat "$LOG")"
rm -rf "$D"

# ── N1(e). no state file, two loopback targets -> ambiguous, refuses ─────
D="$(make_repo)"
LOG="$TMPROOT/ts-n1e.log"
: > "$LOG"
N1E_OUT="$(FAKE_TS_MODE=two-foreign-targets FAKE_TS_LOG="$LOG" "$APP" disconnect --repo "$D" 2>&1)"; N1E_RC=$?
[ "$N1E_RC" -eq 7 ] && ok "N1e. no state file + two loopback targets is ambiguous, refuses (exit 7)" || bad "exit $N1E_RC (want 7): $N1E_OUT"
grep -q '^funnel reset$' "$LOG" && bad "N1e. ambiguous case must not attempt a stop: $(cat "$LOG")" || ok "N1e. ambiguous case never attempted a stop"
rm -rf "$D"

# ── N1(f). HMD_FUNNEL_FORCE_RESET=1 forces past the N1e ambiguity ────────
D="$(make_repo)"
LOG="$TMPROOT/ts-n1f.log"
: > "$LOG"
N1F_OUT="$(HMD_FUNNEL_FORCE_RESET=1 FAKE_TS_MODE=two-foreign-targets FAKE_TS_LOG="$LOG" FAKE_TS_RESET_MARKER="$TMPROOT/n1f.marker" "$APP" disconnect --repo "$D" 2>&1)"; N1F_RC=$?
[ "$N1F_RC" -eq 0 ] && ok "N1f. HMD_FUNNEL_FORCE_RESET=1 forces the reset through the same ambiguity, exits 0" || bad "exit $N1F_RC: $N1F_OUT"
printf '%s' "$N1F_OUT" | grep -qi 'stopped' && ok "N1f. forced reset prints 'stopped'" || bad "$N1F_OUT"
grep -q '^funnel reset$' "$LOG" && ok "N1f. forced reset actually called funnel reset" || bad "ts invocation log: $(cat "$LOG")"
rm -rf "$D"

# ── N1(g). foreground connect's SIGTERM cleanup exits non-zero (not the
# signal's own code) when its own stop can't be verified down ────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-n1g.out"
( FAKE_TS_MODE=funnel-still-up "$APP" connect --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
N1G_PID=$!
PIDS+=("$N1G_PID")

SF="$D/.heimdall/app/connect.json"
N1G_WAITED=0
while [ ! -f "$SF" ] && [ "$N1G_WAITED" -lt 50 ]; do
  sleep 0.2
  N1G_WAITED=$((N1G_WAITED + 1))
done

if [ -f "$SF" ]; then
  kill -TERM "$N1G_PID" 2>/dev/null
  N1G_TERM_WAITED=0
  while kill -0 "$N1G_PID" 2>/dev/null && [ "$N1G_TERM_WAITED" -lt 50 ]; do
    sleep 0.1
    N1G_TERM_WAITED=$((N1G_TERM_WAITED + 1))
  done
  if kill -0 "$N1G_PID" 2>/dev/null; then
    bad "N1g. connect process did not exit within 5s of SIGTERM"
    kill -9 "$N1G_PID" 2>/dev/null
    wait "$N1G_PID" 2>/dev/null
  else
    wait "$N1G_PID" 2>/dev/null
    N1G_RC=$?
    [ "$N1G_RC" -eq 8 ] && ok "N1g. SIGTERM cleanup exits 8 (not the signal's own code) when the funnel can't be verified down" || bad "exit $N1G_RC (want 8): $(cat "$OUT_FILE")"
    grep -qF 'FUNNEL STILL PUBLIC' "$OUT_FILE" && ok "N1g. SIGTERM teardown prints the loud FUNNEL STILL PUBLIC line" || bad "$(cat "$OUT_FILE")"
  fi
else
  bad "N1g setup: foreground connect never wrote a state file within 10s: $(cat "$OUT_FILE" 2>/dev/null)"
  bad "N1g. skipped: SIGTERM exit-code check (setup failed)"
  kill "$N1G_PID" 2>/dev/null
  wait "$N1G_PID" 2>/dev/null
fi
rm -rf "$D"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

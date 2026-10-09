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
  # Safety net: reap any --bg-started heimdall-ui (and, in relay mode, the
  # relay client too) a test case forgot to disconnect, found via its own
  # state file (PIDS never tracks these -- cmd_connect --bg disowns them
  # from its own job table on purpose).
  local sf leak_pid leak_mode leak_client_pid
  for sf in "$TMPROOT"/repo.*/.heimdall/app/connect.json; do
    [ -f "$sf" ] || continue
    leak_pid="$(jq -r '.pid_ui // empty' "$sf" 2>/dev/null)"
    [ -n "$leak_pid" ] && kill -9 "$leak_pid" 2>/dev/null
    leak_mode="$(jq -r '.mode // empty' "$sf" 2>/dev/null)"
    if [ "$leak_mode" = "relay" ]; then
      leak_client_pid="$(jq -r '.pid_client // empty' "$sf" 2>/dev/null)"
      [ -n "$leak_client_pid" ] && kill -9 "$leak_client_pid" 2>/dev/null
    fi
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
        if [ "$mode" = "funnel-start-hangs" ]; then
          # Models a macsys/App Store CLIError-3-style hang (2026-09-21
          # tailscale-macsys-funnel-cli-error-3): the process never returns,
          # so heimdall-app's own start-side timeout
          # (HMD_FUNNEL_START_TIMEOUT_S) is what has to save this, not
          # anything the fake CLI does.
          sleep 999999
          exit 0
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
if [ "$RC" -eq 0 ]; then ok "bare 'heimdall-app' (no subcommand) exits 0"; else bad "bare exit $RC"; fi
if printf '%s' "$OUT" | grep -qi "Usage:"; then ok "bare invocation prints usage"; else bad "bare usage missing: $OUT"; fi

OUT="$("$APP" frobnicate 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then ok "unknown subcommand exits 2"; else bad "unknown subcommand exit $RC"; fi
if printf '%s' "$OUT" | grep -qi "unknown subcommand"; then ok "unknown subcommand names itself in the error"; else bad "message missing: $OUT"; fi

OUT="$("$HEIMDALL" app --help 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "'heimdall app --help' dispatches through bin/heimdall, exit 0"; else bad "exit $RC"; fi
if printf '%s' "$OUT" | grep -qi "connect"; then ok "'heimdall app --help' help text mentions connect"; else bad "help missing connect: $OUT"; fi

OUT="$("$HMD" app 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "bare 'hmd app' dispatches through bin/hmd, exit 0"; else bad "exit $RC: $OUT"; fi

# ── 6. bad --https-port (checked before touching tailscale at all) ──────
D="$(make_repo)"
OUT="$(FAKE_TS_MODE=online-with-DNSName "$APP" connect --tailscale --repo "$D" --https-port 9999 2>&1)"
RC=$?
if [ "$RC" -eq 64 ]; then ok "connect --https-port 9999 exits 64"; else bad "exit $RC (want 64): $OUT"; fi
if printf '%s' "$OUT" | grep -qi "port"; then ok "bad-https-port message mentions 'port'"; else bad "message: $OUT"; fi
if [ ! -f "$D/.heimdall/app/connect.json" ]; then ok "no state file written on bad-https-port failure"; else bad "state file unexpectedly written"; fi
rm -rf "$D"

# ── 7-8. install prompt (D1: never silent) ──────────────────────────────
D="$(make_repo)"
OUT="$(FAKE_TS_MODE=not-installed "$APP" connect --tailscale --repo "$D" --no-install 2>&1)"
RC=$?
if [ "$RC" -eq 4 ]; then ok "connect --no-install (not installed) exits 4"; else bad "exit $RC (want 4): $OUT"; fi
if printf '%s' "$OUT" | grep -qi "not installed"; then ok "--no-install failure mentions 'not installed'"; else bad "$OUT"; fi
if printf '%s' "$OUT" | grep -qi "hmd would run"; then ok "--no-install failure names the manual install command (D1)"; else bad "$OUT"; fi
if [ ! -f "$D/.heimdall/app/connect.json" ]; then ok "no state file written after --no-install failure"; else bad "state file written unexpectedly"; fi
rm -rf "$D"

D="$(make_repo)"
OUT="$(FAKE_TS_MODE=not-installed "$APP" connect --tailscale --repo "$D" </dev/null 2>&1)"
RC=$?
if [ "$RC" -eq 4 ]; then ok "connect w/o --no-install + closed stdin declines cleanly, exit 4 (no hang)"; else bad "exit $RC: $OUT"; fi
if printf '%s' "$OUT" | grep -qi "hmd would run"; then ok "closed-stdin decline still shows the manual install command (D1)"; else bad "$OUT"; fi
rm -rf "$D"

# ── 9-10. not online ─────────────────────────────────────────────────────
D="$(make_repo)"
OUT="$(FAKE_TS_MODE=daemon-down "$APP" connect --tailscale --repo "$D" 2>&1)"
RC=$?
if [ "$RC" -eq 5 ]; then ok "connect w/ tailscaled down exits 5"; else bad "exit $RC (want 5): $OUT"; fi
if printf '%s' "$OUT" | grep -qi "tailscale up"; then ok "daemon-down prints the login hint"; else bad "$OUT"; fi
if [ ! -f "$D/.heimdall/app/connect.json" ]; then ok "no state file written when daemon is down"; else bad "state file written"; fi
rm -rf "$D"

D="$(make_repo)"
OUT="$(FAKE_TS_MODE=offline "$APP" connect --tailscale --repo "$D" 2>&1)"
RC=$?
if [ "$RC" -eq 5 ]; then ok "connect w/ tailscale logged out exits 5"; else bad "exit $RC: $OUT"; fi
if printf '%s' "$OUT" | grep -qi "tailscale up"; then ok "logged-out login hint present"; else bad "$OUT"; fi
if printf '%s' "$OUT" | grep -qF "https://login.tailscale.com/a/fakeauthtoken123"; then ok "logged-out login hint includes the AuthURL"; else bad "$OUT"; fi
rm -rf "$D"

# ── 11-25. modern funnel, online: the full success path ─────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-online.out"
FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 --bg >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "connect --bg (modern funnel, online) exits 0"; else bad "exit $RC: $(cat "$OUT_FILE")"; fi

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

if [ "$SF_HOST" = "my-machine.tail1a2b3.ts.net" ]; then ok "state file host == fake DNSName, trailing dot stripped"; else bad "host=$SF_HOST"; fi
if [ "$SF_HTTPS" = "443" ]; then ok "state file https_port == 443 (default)"; else bad "https_port=$SF_HTTPS"; fi
if [ -n "$SF_PORT" ] && [ "$SF_PORT" -gt 0 ] 2>/dev/null; then ok "state file port is a positive integer"; else bad "port=$SF_PORT"; fi
if [ -n "$SF_PID" ] && kill -0 "$SF_PID" 2>/dev/null; then ok "state file pid_ui refers to a live process"; else bad "pid_ui=$SF_PID not alive"; fi
if [ -n "$SF_STARTED" ]; then ok "state file has a started_at timestamp"; else bad "started_at missing"; fi

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
FAKE_TS_MODE=policy-hint-on-funnel-start "$APP" connect --tailscale --repo "$D" --port 0 --bg >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
if [ "$RC" -eq 3 ]; then ok "connect under a tailnet policy block exits 3"; else bad "exit $RC"; fi
if grep -qF 'funnel: HTTPS is not enabled for your tailnet. To enable HTTPS certificates and Funnel, visit the admin console: https://login.tailscale.com/admin/dns' "$ERR_FILE"; then
  ok "policy hint is printed VERBATIM on stderr"
else
  bad "stderr: $(cat "$ERR_FILE")"
fi
if printf '%s' "$(cat "$ERR_FILE")" | grep -qi 'hmd app doctor'; then ok "policy-block stderr points at 'hmd app doctor' for diagnostics"; else bad "missing doctor pointer: $(cat "$ERR_FILE")"; fi
if [ ! -f "$D/.heimdall/app/connect.json" ]; then ok "no state file left behind after a policy-block failure"; else bad "state file leaked"; fi
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
FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 --bg >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  bad "setup: connect --bg for the status test failed (exit $RC): $(cat "$OUT_FILE")"
else
  REAL_TOKEN="$(grep -Eo 'token=[A-Za-z0-9_-]+' "$OUT_FILE" | head -1 | sed 's/^token=//')"
  STATUS_OUT="$(FAKE_TS_MODE=modern-funnel "$APP" status --repo "$D" 2>&1)"
  SRC=$?
  if [ "$SRC" -eq 0 ]; then ok "status exits 0"; else bad "status exit $SRC"; fi
  if [ -n "$REAL_TOKEN" ] && printf '%s' "$STATUS_OUT" | grep -qF "$REAL_TOKEN"; then
    bad "status output LEAKS the real token"
  else
    ok "status output never contains the real token"
  fi
  if printf '%s' "$STATUS_OUT" | grep -q 'token=<redacted>'; then ok "status shows a redacted token placeholder"; else bad "no redacted placeholder: $STATUS_OUT"; fi
  if printf '%s' "$STATUS_OUT" | grep -q 'connected: yes'; then ok "status reports connected: yes"; else bad "$STATUS_OUT"; fi
  if printf '%s' "$STATUS_OUT" | grep -qi 'inbox pending'; then ok "status reports the pending inbox count"; else bad "$STATUS_OUT"; fi
  FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" >/dev/null 2>&1
fi
rm -rf "$D"

# ── 36-40. disconnect kills the ui and is idempotent ─────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-for-disconnect.out"
FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 --bg >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  bad "setup: connect --bg for the disconnect test failed: $(cat "$OUT_FILE")"
else
  SF="$D/.heimdall/app/connect.json"
  DC_PID="$(jq -r '.pid_ui' "$SF" 2>/dev/null)"
  DC_PORT="$(jq -r '.port' "$SF" 2>/dev/null)"
  DISC_OUT="$(FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" 2>&1)"
  DRC=$?
  if [ "$DRC" -eq 0 ]; then ok "disconnect exits 0"; else bad "exit $DRC: $DISC_OUT"; fi
  DC_WAITED=0
  while kill -0 "$DC_PID" 2>/dev/null && [ "$DC_WAITED" -lt 30 ]; do
    sleep 0.1
    DC_WAITED=$((DC_WAITED + 1))
  done
  if kill -0 "$DC_PID" 2>/dev/null; then bad "ui pid still alive after disconnect"; else ok "disconnect kills the ui pid"; fi
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:${DC_PORT}/" 2>/dev/null)"
  if [ "$CODE" = "000" ]; then ok "ui port no longer accepts connections after disconnect"; else bad "port $DC_PORT still answering (code=$CODE)"; fi
  if [ ! -f "$SF" ]; then ok "state file removed after disconnect"; else bad "state file still present"; fi
  DISC_OUT2="$(FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" 2>&1)"
  DRC2=$?
  if [ "$DRC2" -eq 0 ]; then ok "second disconnect (idempotent) exits 0"; else bad "exit $DRC2: $DISC_OUT2"; fi
fi
rm -rf "$D"

# ── 41-55. doctor ─────────────────────────────────────────────────────────
D="$(make_repo)"

DOC_NI="$(FAKE_TS_MODE=not-installed "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
if [ "$DRC" -ne 0 ]; then ok "doctor (not-installed) exits nonzero"; else bad "exit $DRC (want nonzero)"; fi
if printf '%s' "$DOC_NI" | grep -q 'FAIL.*tailscale installed'; then ok "doctor (not-installed) flags 'tailscale installed'"; else bad "$DOC_NI"; fi
if printf '%s' "$DOC_NI" | grep -qi 'fix:'; then ok "doctor prints a fix hint per failure"; else bad "no fix hint: $DOC_NI"; fi

DOC_DD="$(FAKE_TS_MODE=daemon-down "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
if [ "$DRC" -ne 0 ]; then ok "doctor (daemon-down) exits nonzero"; else bad "exit $DRC"; fi
if printf '%s' "$DOC_DD" | grep -q 'ok.*tailscale installed'; then ok "doctor (daemon-down): tailscale-installed still ok"; else bad "$DOC_DD"; fi
if printf '%s' "$DOC_DD" | grep -q 'FAIL.*tailscale daemon running'; then ok "doctor (daemon-down) flags 'tailscale daemon running'"; else bad "$DOC_DD"; fi

DOC_OFF="$(FAKE_TS_MODE=offline "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
if [ "$DRC" -ne 0 ]; then ok "doctor (offline/logged-out) exits nonzero"; else bad "exit $DRC"; fi
if printf '%s' "$DOC_OFF" | grep -q 'ok.*tailscale daemon running'; then ok "doctor (offline): daemon-running still ok"; else bad "$DOC_OFF"; fi
if printf '%s' "$DOC_OFF" | grep -q 'FAIL.*logged in / online'; then ok "doctor (offline) flags 'logged in / online'"; else bad "$DOC_OFF"; fi

DOC_HAPPY="$(FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
if [ "$DRC" -eq 0 ]; then ok "doctor (fully happy fake) exits 0"; else bad "exit $DRC: $DOC_HAPPY"; fi
if printf '%s' "$DOC_HAPPY" | grep -q 'all checks passed'; then ok "doctor (happy) prints the all-checks-passed summary"; else bad "$DOC_HAPPY"; fi

DOC_NF="$(FAKE_TS_MODE=no-funnel "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
if [ "$DRC" -ne 0 ]; then ok "doctor (no-funnel) exits nonzero"; else bad "exit $DRC"; fi
if printf '%s' "$DOC_NF" | grep -q 'FAIL.*funnel capability'; then ok "doctor (no-funnel) flags 'funnel capability'"; else bad "$DOC_NF"; fi

DOC_BADPORT="$(FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" --https-port 9999 2>&1)"; DRC=$?
if [ "$DRC" -ne 0 ]; then ok "doctor with a bad --https-port exits nonzero"; else bad "exit $DRC"; fi
if printf '%s' "$DOC_BADPORT" | grep -q 'FAIL.*https-port allowed'; then ok "doctor flags a bad --https-port"; else bad "$DOC_BADPORT"; fi

rm -rf "$D"

# ── DNSName -N suffix hint (2026-09-21, hmdapp docs/HANDOFF-TO-HEIMDALL-
# 2026-09-21.md item 4): a second node registering under the same base
# hostname while an older one is still listed offline in the tailnet gets a
# "-N"-suffixed DNSName -- doctor points the operator at the admin console
# instead of leaving the "-N" a silent mystery. HOST_NORM uses the real
# test-machine hostname (same scutil/hostname fallback the app itself uses)
# so the first two cases prove actual normalization, not a stand-in.
HOST_RAW="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null)"
HOST_NORM="$(printf '%s' "$HOST_RAW" | tr '[:upper:]' '[:lower:]')"
HOST_NORM="${HOST_NORM//[^a-z0-9]/-}"

if [ -n "$HOST_NORM" ]; then
  D="$(make_repo)"
  DOC_SUFFIX="$(FAKE_TS_DNSNAME="${HOST_NORM}-1.tail1234.ts.net." FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
  if [ "$DRC" -eq 0 ]; then ok "doctor (DNSName w/ -N suffix) still exits 0 -- info, not FAIL"; else bad "exit $DRC: $DOC_SUFFIX"; fi
  if printf '%s' "$DOC_SUFFIX" | grep -q 'all checks passed'; then ok "doctor (DNSName w/ -N suffix) still reports all checks passed"; else bad "$DOC_SUFFIX"; fi
  EXPECT_SUFFIX_LINE="info  DNSName carries a -N suffix: an older node named ${HOST_NORM} is probably still registered (offline) in the tailnet admin console — remove it at https://login.tailscale.com/admin/machines and re-run 'tailscale up' to reclaim ${HOST_NORM}.tail1234.ts.net"
  if printf '%s' "$DOC_SUFFIX" | grep -qF "$EXPECT_SUFFIX_LINE"; then ok "doctor prints the exact -N suffix info line"; else bad "$DOC_SUFFIX"; fi
  rm -rf "$D"

  D="$(make_repo)"
  DOC_NOSUFFIX="$(FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
  if printf '%s' "$DOC_NOSUFFIX" | grep -q -- '-N suffix'; then
    bad "doctor w/ a plain DNSName (no suffix) unexpectedly prints the -N suffix hint: $DOC_NOSUFFIX"
  else
    ok "doctor w/ a plain DNSName (no suffix) prints no -N suffix hint"
  fi
  rm -rf "$D"

  FAKE_HOSTBIN="$TMPROOT/fakehostbin"
  mkdir -p "$FAKE_HOSTBIN"
  cat > "$FAKE_HOSTBIN/scutil" <<'HOSTEOF'
#!/usr/bin/env bash
echo "RJ Test Host"
HOSTEOF
  chmod +x "$FAKE_HOSTBIN/scutil"
  cat > "$FAKE_HOSTBIN/hostname" <<'HOSTEOF'
#!/usr/bin/env bash
echo "wrong-fallback-should-not-be-used"
HOSTEOF
  chmod +x "$FAKE_HOSTBIN/hostname"

  D="$(make_repo)"
  DOC_NORM="$(PATH="$FAKE_HOSTBIN:$PATH" FAKE_TS_DNSNAME='rj-test-host-1.tail1234.ts.net.' FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
  if printf '%s' "$DOC_NORM" | grep -qF 'an older node named rj-test-host is'; then ok "doctor normalizes a hostname with capitals/spaces (scutil 'RJ Test Host' -> rj-test-host)"; else bad "$DOC_NORM"; fi
  if printf '%s' "$DOC_NORM" | grep -qF 'wrong-fallback-should-not-be-used'; then
    bad "doctor used the hostname(1) fallback instead of scutil: $DOC_NORM"
  else
    ok "doctor prefers scutil over the hostname(1) fallback"
  fi
  rm -rf "$D"
else
  ok "doctor -N suffix hint: skipped (no local hostname resolvable in this environment)"
fi


# ── 56-59. unknown flags rejected on every subcommand ────────────────────
OUT="$("$APP" connect --bogus-flag 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then ok "connect rejects an unknown flag, exit 2"; else bad "exit $RC: $OUT"; fi

OUT="$("$APP" status --bogus-flag 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then ok "status rejects an unknown flag, exit 2"; else bad "exit $RC: $OUT"; fi

OUT="$("$APP" disconnect --bogus-flag 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then ok "disconnect rejects an unknown flag, exit 2"; else bad "exit $RC: $OUT"; fi

OUT="$("$APP" doctor --bogus-flag 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then ok "doctor rejects an unknown flag, exit 2"; else bad "exit $RC: $OUT"; fi

# ── 60-63. status/disconnect on a repo that was never connected ─────────
D="$(make_repo)"
OUT="$(FAKE_TS_MODE=online-with-DNSName "$APP" status --repo "$D" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "status on a never-connected repo exits 0"; else bad "exit $RC"; fi
if printf '%s' "$OUT" | grep -q 'connected: no'; then ok "status on a never-connected repo reports connected: no"; else bad "$OUT"; fi

OUT="$("$APP" disconnect --repo "$D" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "disconnect on a never-connected repo exits 0"; else bad "exit $RC"; fi
if printf '%s' "$OUT" | grep -qi 'not connected'; then ok "disconnect on a never-connected repo reports not connected"; else bad "$OUT"; fi
rm -rf "$D"

# ── 64-67. legacy funnel CLI (serve + funnel PORT on/off recipe) ────────
D="$(make_repo)"
LOG="$TMPROOT/ts-legacy.log"
: > "$LOG"
OUT_FILE="$TMPROOT/connect-legacy.out"
FAKE_TS_MODE=legacy-funnel FAKE_TS_LOG="$LOG" "$APP" connect --tailscale --repo "$D" --port 0 --bg >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "connect --bg (legacy funnel CLI) exits 0"; else bad "exit $RC: $(cat "$OUT_FILE")"; fi
if grep -Eq 'https://my-machine\.tail1a2b3\.ts\.net/\?token=[A-Za-z0-9_-]+' "$OUT_FILE"; then
  ok "legacy-funnel connect prints the public URL"
else
  bad "$(cat "$OUT_FILE")"
fi
if grep -q '^serve https / http://127.0.0.1:' "$LOG"; then ok "legacy funnel start used the 'serve https /' recipe"; else bad "ts invocation log: $(cat "$LOG")"; fi
if grep -q '^funnel 443 on$' "$LOG"; then ok "legacy funnel start used 'funnel 443 on'"; else bad "ts invocation log: $(cat "$LOG")"; fi
FAKE_TS_MODE=legacy-funnel FAKE_TS_LOG="$LOG" "$APP" disconnect --repo "$D" >/dev/null 2>&1
if grep -q '^funnel 443 off$' "$LOG"; then ok "legacy funnel stop used 'funnel 443 off'"; else bad "ts invocation log: $(cat "$LOG")"; fi
rm -rf "$D"

# ── 68-72. foreground wait + signal-based teardown ───────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-fg.out"
( FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
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
if [ "$RC" -eq 0 ]; then ok "A4a. disconnect w/ no state file still exits 0"; else bad "exit $RC: $OUT"; fi
if grep -q '^funnel 443 off$' "$LOG"; then ok "A4a. disconnect w/ no state file still calls funnel-stop (no orphaned funnel survives disconnect)"; else bad "ts invocation log: $(cat "$LOG")"; fi
rm -rf "$D"

# ── A4(b). connect defaults to the fixed port 8710; busy -> exit 6 ───────
# 8710 is a fixed, non-configurable default (see bin/heimdall-app's usage
# banner) -- every other "$APP" connect call in this file passes --port 0
# specifically to stay off it, so nothing *we* run can be the occupant.
# That means both assertions below only hold if 8710 is free on the host
# before we touch it: a real, concurrent `hmd app connect` elsewhere on the
# same machine legitimately owns it sometimes, which corrupts the first
# assertion (connect fails outright) and starves the second (its own probe
# listener never gets to be the reason exit 6 happens). Probe first --
# reusing this block's own /dev/tcp idiom below, a real connect attempt,
# not a sleep -- and if something external already holds it, skip both
# loudly via ok(), same pattern as the SIGHUP/-N-suffix skips elsewhere in
# this file. Falsifiability of the two real assertions is untouched: the
# "free" branch below is byte-for-byte the original code.
A4B_PORT_BUSY_EXTERNALLY=0
if exec 3<>/dev/tcp/127.0.0.1/8710 2>/dev/null; then
  exec 3<&- 2>/dev/null || true
  A4B_PORT_BUSY_EXTERNALLY=1
fi

if [ "$A4B_PORT_BUSY_EXTERNALLY" -eq 1 ]; then
  ok "A4b. connect w/ no --port defaults to the fixed port 8710: skipped (port 8710 already in use by another process on this machine)"
  ok "A4b. connect w/ the fixed default port (8710) busy exits 6: skipped (port 8710 already in use by another process on this machine)"
else
  D="$(make_repo)"
  OUT_FILE="$TMPROOT/connect-a4b-default.out"
  FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --bg >"$OUT_FILE" 2>&1
  RC=$?
  if [ "$RC" -eq 0 ]; then
    SF="$D/.heimdall/app/connect.json"
    DP="$(jq -r '.port // empty' "$SF" 2>/dev/null)"
    if [ "$DP" = "8710" ]; then ok "A4b. connect w/ no --port defaults to the fixed port 8710"; else bad "port=$DP (want 8710)"; fi
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
  OUT="$(FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --bg 2>&1)"; RC=$?
  if [ "$RC" -eq 6 ]; then ok "A4b. connect w/ the fixed default port (8710) busy exits 6"; else bad "exit $RC (want 6): $OUT"; fi
  kill "$HOLD_PID" 2>/dev/null
  wait "$HOLD_PID" 2>/dev/null
  rm -rf "$D"
fi

# ── A4(c). status detects an orphaned funnel (ui dead, funnel still up) ──
D="$(make_repo)"
mkdir -p "$D/.heimdall/app"
cat > "$D/.heimdall/app/connect.json" <<JSON
{"pid_ui": 1, "port": 9999, "https_port": 443, "host": "my-machine.tail1a2b3.ts.net", "started_at": "2026-01-01T00:00:00Z"}
JSON
OUT="$(FAKE_TS_MODE=funnel-still-up "$APP" status --repo "$D" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then ok "A4c. status w/ a stale pid + funnel still up exits nonzero"; else bad "exit $RC (want nonzero)"; fi
if printf '%s' "$OUT" | grep -qi 'ORPHANED FUNNEL'; then ok "A4c. status prints an ORPHANED FUNNEL warning"; else bad "$OUT"; fi
rm -rf "$D"

# ── A4(d). connect tears down a pre-existing funnel before starting a new one ──
D0="$(make_repo)"
LOG0="$TMPROOT/ts-a4d-baseline.log"
: > "$LOG0"
FAKE_TS_MODE=modern-funnel FAKE_TS_LOG="$LOG0" "$APP" connect --tailscale --repo "$D0" --bg --port 0 >/dev/null 2>&1
BASELINE_COUNT="$(grep -c '^funnel' "$LOG0")"
FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D0" >/dev/null 2>&1
rm -rf "$D0"

D="$(make_repo)"
LOG="$TMPROOT/ts-a4d.log"
: > "$LOG"
OUT_FILE="$TMPROOT/connect-a4d.out"
FAKE_TS_MODE=funnel-still-up FAKE_TS_LOG="$LOG" "$APP" connect --tailscale --repo "$D" --bg --port 0 >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "A4d. connect w/ a pre-existing funnel still exits 0"; else bad "exit $RC: $(cat "$OUT_FILE")"; fi
if grep -qi 'tearing it down' "$OUT_FILE"; then ok "A4d. connect announces tearing down the pre-existing funnel"; else bad "$(cat "$OUT_FILE")"; fi
A4D_COUNT="$(grep -c '^funnel' "$LOG")"
if [ "$A4D_COUNT" -gt "$BASELINE_COUNT" ]; then ok "A4d. connect issued an extra tailscale funnel call to tear it down ($A4D_COUNT calls vs $BASELINE_COUNT baseline)"; else bad "no extra funnel call: $A4D_COUNT vs baseline $BASELINE_COUNT"; fi
FAKE_TS_MODE=funnel-still-up "$APP" disconnect --repo "$D" >/dev/null 2>&1
rm -rf "$D"

# ── A4(e). foreground wait also tears down on SIGHUP ──────────────────────
# Whether a freshly-started non-interactive bash can actually arm a SIGHUP
# trap is environment-dependent: POSIX shells refuse to re-arm a signal that
# was already SIG_IGN when the shell started (the same mechanism that makes
# nohup/disown transitive through nested shells) -- if the harness running
# this suite itself has HUP ignored (e.g. detached from a controlling
# terminal), bin/heimdall-app's own `trap ... HUP` (bin/heimdall-app:505) is
# silently a no-op BY DESIGN: the tool cannot un-ignore a signal its own
# parent ignored, and no product change can fix that. Verified directly with
# a throwaway bash rather than assumed either way -- same one-shot-probe-
# then-branch shape as HOST_NORM above (used by the -N-suffix-hint cases).
# The ready-marker handshake (touch AFTER `trap` installs, wait for it
# before signalling) rules out the OTHER environment-dependence this class
# of test can suffer -- a HUP delivered before the trap is even installed.
HUP_TRAPPABLE=false
HUP_PROBE_READY="$TMPROOT/hup-probe.ready"
HUP_PROBE_FIRED="$TMPROOT/hup-probe.fired"
rm -f "$HUP_PROBE_READY" "$HUP_PROBE_FIRED"
bash -c "trap 'touch \"$HUP_PROBE_FIRED\"; exit 77' HUP; touch \"$HUP_PROBE_READY\"; i=0; while [ \"\$i\" -lt 30 ]; do sleep 0.1; i=\$((i + 1)); done" &
HUP_PROBE_PID=$!
PIDS+=("$HUP_PROBE_PID")
HUP_PROBE_WAITED=0
while [ ! -f "$HUP_PROBE_READY" ] && [ "$HUP_PROBE_WAITED" -lt 20 ]; do
  sleep 0.1
  HUP_PROBE_WAITED=$((HUP_PROBE_WAITED + 1))
done
kill -HUP "$HUP_PROBE_PID" 2>/dev/null
HUP_PROBE_WAITED=0
while kill -0 "$HUP_PROBE_PID" 2>/dev/null && [ "$HUP_PROBE_WAITED" -lt 20 ]; do
  sleep 0.1
  HUP_PROBE_WAITED=$((HUP_PROBE_WAITED + 1))
done
if kill -0 "$HUP_PROBE_PID" 2>/dev/null; then
  # still alive after 2s of an ignored-by-design HUP -- never trapped
  kill -9 "$HUP_PROBE_PID" 2>/dev/null
  wait "$HUP_PROBE_PID" 2>/dev/null
else
  wait "$HUP_PROBE_PID" 2>/dev/null
  [ -f "$HUP_PROBE_FIRED" ] && HUP_TRAPPABLE=true
fi
rm -f "$HUP_PROBE_READY" "$HUP_PROBE_FIRED"

D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-hup.out"
( FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
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

  if [ "$HUP_TRAPPABLE" = true ]; then
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
    # SIGHUP is ignored-at-exec in this harness (see the HUP-trap capability
    # probe above) -- bin/heimdall-app's `trap ... HUP` can never fire here,
    # by the same POSIX rule the probe just exercised against a throwaway
    # bash. Skip visibly (never silently pass) instead of failing on a
    # signal this process was never able to receive, and instead of
    # weakening bin/heimdall-app to paper over an environment limit it has
    # no power to change.
    ok "A4e. connect process exits on SIGHUP: skipped (SIGHUP is ignored-at-exec in this harness)"
    ok "A4e. ui process reaped by the SIGHUP trap's cleanup(): skipped (SIGHUP is ignored-at-exec in this harness)"
    kill -9 "$HUP_FG_PID" 2>/dev/null
    [ -n "$HUP_UI_PID" ] && kill -9 "$HUP_UI_PID" 2>/dev/null
  fi
else
  bad "A4e setup: foreground connect never wrote a state file within 10s: $(cat "$OUT_FILE" 2>/dev/null)"
  bad "A4e. skipped: SIGHUP exit check (setup failed)"
  bad "A4e. skipped: ui-reaped check (setup failed)"
  kill "$HUP_FG_PID" 2>/dev/null
fi
wait "$HUP_FG_PID" 2>/dev/null
rm -rf "$D"

# ── A5. the pairing URL/token rides hmd_qr.py's stdin, never its argv (ps) ──
# argv is what `ps` shows any local user; stdin is not. hmd_qr.py lives only
# milliseconds (render a QR, exit), so sampling `ps` for it races it -- under
# load the sampler misses the process entirely and the check goes
# "inconclusive" -- and a machine-wide `ps | grep` can also match some OTHER
# session's hmd_qr.py. Instead observe the launch itself, deterministically,
# through the HMD_PYTHON seam (hmd_qr.py has no path override of its own; the
# interpreter is what the app resolves through the environment): a wrapper
# interpreter appends the exact argv of every launch to a log and, for the
# hmd_qr.py launch only, saves its stdin to a file, then execs the real
# interpreter so the QR still renders. Both are written BEFORE the real
# process runs, so there is nothing to sample and nothing to miss.
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-a5.out"
A5_ARGV_LOG="$TMPROOT/a5-argv.log"
A5_STDIN_LOG="$TMPROOT/a5-qr-stdin.log"
A5_PY_WRAP="$TMPROOT/a5-python-argv-recorder"
# SC1091: shellcheck only follows sources under -x; source= serves `-x -P SCRIPTDIR`, disable keeps a plain run clean.
# shellcheck source=../bin/lib/hmd-python.sh disable=SC1091
A5_REAL_PY="$(. "$REPO/bin/lib/hmd-python.sh"; hmd_python 2>/dev/null || true)"
: >"$A5_ARGV_LOG"
: >"$A5_STDIN_LOG"
cat >"$A5_PY_WRAP" <<A5WRAP
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$A5_ARGV_LOG"
case "\$*" in
  *hmd_qr.py*)
    cat >"$A5_STDIN_LOG"
    exec "$A5_REAL_PY" "\$@" <"$A5_STDIN_LOG"
    ;;
esac
exec "$A5_REAL_PY" "\$@"
A5WRAP
chmod +x "$A5_PY_WRAP"

if [ -z "$A5_REAL_PY" ]; then
  bad "A5 setup: no python3 resolvable -- cannot run hmd_qr.py at all"
else
  ( HMD_PYTHON="$A5_PY_WRAP" FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
  A5_FG_PID=$!
  PIDS+=("$A5_FG_PID")

  # connect renders the QR right after writing connect.json and before it
  # prints its "waiting" line; that line is the deterministic "QR is done" cue.
  A5_WAITED=0
  while ! grep -q 'hmd app: waiting' "$OUT_FILE" 2>/dev/null && [ "$A5_WAITED" -lt 600 ]; do
    sleep 0.05
    A5_WAITED=$((A5_WAITED + 1))
  done

  A5_QR_ARGV="$(grep 'hmd_qr.py' "$A5_ARGV_LOG" 2>/dev/null || true)"
  if [ -z "$A5_QR_ARGV" ]; then
    bad "A5. connect never executed hmd_qr.py through the interpreter (argv log: $(cat "$A5_ARGV_LOG" 2>/dev/null); out: $(tail -5 "$OUT_FILE" 2>/dev/null))"
  elif printf '%s' "$A5_QR_ARGV" | grep -q 'token='; then
    bad "A5. hmd_qr.py argv LEAKS the token during connect: $A5_QR_ARGV"
  else
    ok "A5. hmd_qr.py argv never shows token= (argv recorded at exec, clean)"
  fi
  if grep -q 'token=' "$OUT_FILE" 2>/dev/null; then
    ok "A5b. pairing URL still reached the operator (stdout carries the token URL)"
  else
    bad "A5b. connect output never showed the pairing URL: $(tail -5 "$OUT_FILE" 2>/dev/null)"
  fi

  # The positive half of "stdin, not argv": the bytes the QR renderer was
  # handed on stdin are exactly the URL connect showed the operator. Both
  # sides must be non-empty, so two empty strings can never compare equal.
  A5_PRINTED_URL="$(grep -Eo 'https://[^[:space:]]+\?token=[A-Za-z0-9_-]+' "$OUT_FILE" 2>/dev/null | head -1)"
  A5_STDIN_URL="$(cat "$A5_STDIN_LOG" 2>/dev/null || true)"
  if [ -z "$A5_PRINTED_URL" ]; then
    bad "A5c. no pairing URL in connect's output to compare the QR payload against: $(tail -5 "$OUT_FILE" 2>/dev/null)"
  elif [ -z "$A5_STDIN_URL" ]; then
    bad "A5c. hmd_qr.py stdin was empty -- the pairing URL never reached the QR renderer on stdin (argv: $A5_QR_ARGV)"
  elif [ "$A5_STDIN_URL" = "$A5_PRINTED_URL" ]; then
    ok "A5c. hmd_qr.py received the printed pairing URL on stdin (QR payload == the URL shown to the operator)"
  else
    bad "A5c. hmd_qr.py stdin differs from the URL connect printed (stdin: $A5_STDIN_URL; printed: $A5_PRINTED_URL)"
  fi

  kill -TERM "$A5_FG_PID" 2>/dev/null
  wait "$A5_FG_PID" 2>/dev/null
fi
rm -rf "$D"

# ── A6. ui log temp file is 0600 (mktemp + umask 077) ─────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-a6-mode.out"
( FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
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
      if [ "$MODE" = "600" ]; then ok "A6. ui log temp file created with mode 0600"; else bad "A6. ui log temp file mode=$MODE (want 600): $UI_OUT_PATH"; fi
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
HEIMDALL_UI_BIN="$FAKE_UI_DIES" FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
if [ "$RC" -eq 6 ]; then ok "A6. connect w/ a ui that dies before printing a URL exits 6"; else bad "exit $RC (want 6): $(cat "$ERR_FILE")"; fi
if grep -q 'SECRETVALUE12345' "$ERR_FILE"; then
  bad "A6. die-race stderr LEAKS the raw token: $(cat "$ERR_FILE")"
else
  ok "A6. die-race stderr never contains the raw token"
fi
if grep -q 'token=<redacted>' "$ERR_FILE"; then ok "A6. die-race stderr shows the redacted placeholder instead"; else bad "$(cat "$ERR_FILE")"; fi
rm -rf "$D"

# ── A12. DNSName is validated before use as --allow-host ─────────────────
D="$(make_repo)"
OUT="$(FAKE_TS_DNSNAME='evil.example.com' FAKE_TS_MODE=online-with-DNSName "$APP" connect --tailscale --repo "$D" --bg --port 0 2>&1)"; RC=$?
if [ "$RC" -eq 5 ]; then ok "A12. connect w/ a non-ts.net DNSName exits 5"; else bad "exit $RC (want 5): $OUT"; fi
if printf '%s' "$OUT" | grep -qF 'evil.example.com'; then ok "A12. bad-DNSName error quotes the offending value"; else bad "$OUT"; fi
if [ ! -f "$D/.heimdall/app/connect.json" ]; then ok "A12. no state file written on bad-DNSName failure"; else bad "state file leaked"; fi
rm -rf "$D"

D="$(make_repo)"
OUT="$(FAKE_TS_DNSNAME='bad host.ts.net' FAKE_TS_MODE=online-with-DNSName "$APP" connect --tailscale --repo "$D" --bg --port 0 2>&1)"; RC=$?
if [ "$RC" -eq 5 ]; then ok "A12. connect w/ a DNSName containing a space exits 5"; else bad "exit $RC (want 5): $OUT"; fi
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
if [ "$RC" -eq 0 ]; then ok "A14. disconnect w/ a non-heimdall-ui pid in state file still exits 0"; else bad "exit $RC: $OUT"; fi
if kill -0 "$SLEEP_PID" 2>/dev/null; then
  ok "A14. disconnect does NOT kill a pid whose command isn't heimdall-ui (recycled-pid guard)"
else
  bad "A14. disconnect killed an unrelated sleep process -- pid-identity guard missing"
fi
if printf '%s' "$OUT" | grep -qi 'not a heimdall-ui process'; then ok "A14. disconnect warns when skipping a non-matching pid"; else bad "$OUT"; fi
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
if [ "$N1A_RC" -eq 7 ]; then ok "N1a. disconnect refuses (exit 7) when a foreign target doesn't match hmd's own port"; else bad "exit $N1A_RC (want 7): $N1A_OUT"; fi
if printf '%s' "$N1A_OUT" | grep -qF 'FUNNEL STILL PUBLIC'; then ok "N1a. refusal prints the loud FUNNEL STILL PUBLIC line"; else bad "$N1A_OUT"; fi
if printf '%s' "$N1A_OUT" | grep -qi 'stopped'; then bad "N1a. refusal must never claim success: $N1A_OUT"; else ok "N1a. refusal never prints 'stopped'"; fi
if grep -q '^funnel reset$' "$LOG"; then bad "N1a. refused stop must not have attempted a reset: $(cat "$LOG")"; else ok "N1a. refusal never attempted a reset"; fi
rm -rf "$D"

# ── N1(b). stop's own rc says success but status still shows it up -> 8 ──
D="$(make_repo)"
mkdir -p "$D/.heimdall/app"
cat > "$D/.heimdall/app/connect.json" <<JSON
{"pid_ui": 1, "port": 6000, "https_port": 443, "host": "my-machine.tail1a2b3.ts.net", "started_at": "2026-01-01T00:00:00Z"}
JSON
N1B_OUT="$(FAKE_TS_MODE=funnel-still-up "$APP" disconnect --repo "$D" 2>&1)"; N1B_RC=$?
if [ "$N1B_RC" -eq 8 ]; then ok "N1b. disconnect exits 8 when the stop's own exit code says success but the funnel is still up"; else bad "exit $N1B_RC (want 8): $N1B_OUT"; fi
if printf '%s' "$N1B_OUT" | grep -qF 'FUNNEL STILL PUBLIC'; then ok "N1b. exit-8 case prints the loud FUNNEL STILL PUBLIC line"; else bad "$N1B_OUT"; fi
if printf '%s' "$N1B_OUT" | grep -qi 'stopped'; then bad "N1b. must never claim 'stopped' while still public: $N1B_OUT"; else ok "N1b. never prints 'stopped'"; fi
rm -rf "$D"

# ── N1(c). clean stop verifies down -> exit 0, prints 'stopped' ──────────
D="$(make_repo)"
mkdir -p "$D/.heimdall/app"
cat > "$D/.heimdall/app/connect.json" <<JSON
{"pid_ui": 1, "port": 6000, "https_port": 443, "host": "my-machine.tail1a2b3.ts.net", "started_at": "2026-01-01T00:00:00Z"}
JSON
N1C_OUT="$(FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" 2>&1)"; N1C_RC=$?
if [ "$N1C_RC" -eq 0 ]; then ok "N1c. clean stop (verified down) exits 0"; else bad "exit $N1C_RC: $N1C_OUT"; fi
if printf '%s' "$N1C_OUT" | grep -qi 'stopped'; then ok "N1c. clean stop prints 'stopped'"; else bad "$N1C_OUT"; fi
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
if [ "$N1D_RC" -eq 0 ]; then ok "N1d. no state file + a single loopback target infers that port and stops cleanly"; else bad "exit $N1D_RC: $N1D_OUT"; fi
if grep -q '^funnel reset$' "$LOG"; then ok "N1d. the discovered single target let the stop proceed (funnel reset attempted, not refused)"; else bad "ts invocation log: $(cat "$LOG")"; fi
rm -rf "$D"

# ── N1(e). no state file, two loopback targets -> ambiguous, refuses ─────
D="$(make_repo)"
LOG="$TMPROOT/ts-n1e.log"
: > "$LOG"
N1E_OUT="$(FAKE_TS_MODE=two-foreign-targets FAKE_TS_LOG="$LOG" "$APP" disconnect --repo "$D" 2>&1)"; N1E_RC=$?
if [ "$N1E_RC" -eq 7 ]; then ok "N1e. no state file + two loopback targets is ambiguous, refuses (exit 7)"; else bad "exit $N1E_RC (want 7): $N1E_OUT"; fi
if grep -q '^funnel reset$' "$LOG"; then bad "N1e. ambiguous case must not attempt a stop: $(cat "$LOG")"; else ok "N1e. ambiguous case never attempted a stop"; fi
rm -rf "$D"

# ── N1(f). HMD_FUNNEL_FORCE_RESET=1 forces past the N1e ambiguity ────────
D="$(make_repo)"
LOG="$TMPROOT/ts-n1f.log"
: > "$LOG"
N1F_OUT="$(HMD_FUNNEL_FORCE_RESET=1 FAKE_TS_MODE=two-foreign-targets FAKE_TS_LOG="$LOG" FAKE_TS_RESET_MARKER="$TMPROOT/n1f.marker" "$APP" disconnect --repo "$D" 2>&1)"; N1F_RC=$?
if [ "$N1F_RC" -eq 0 ]; then ok "N1f. HMD_FUNNEL_FORCE_RESET=1 forces the reset through the same ambiguity, exits 0"; else bad "exit $N1F_RC: $N1F_OUT"; fi
if printf '%s' "$N1F_OUT" | grep -qi 'stopped'; then ok "N1f. forced reset prints 'stopped'"; else bad "$N1F_OUT"; fi
if grep -q '^funnel reset$' "$LOG"; then ok "N1f. forced reset actually called funnel reset"; else bad "ts invocation log: $(cat "$LOG")"; fi
rm -rf "$D"

# ── N1(g). foreground connect's SIGTERM cleanup exits non-zero (not the
# signal's own code) when its own stop can't be verified down ────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-n1g.out"
( FAKE_TS_MODE=funnel-still-up "$APP" connect --tailscale --repo "$D" --port 0 >"$OUT_FILE" 2>&1 ) &
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
    if [ "$N1G_RC" -eq 8 ]; then ok "N1g. SIGTERM cleanup exits 8 (not the signal's own code) when the funnel can't be verified down"; else bad "exit $N1G_RC (want 8): $(cat "$OUT_FILE")"; fi
    if grep -qF 'FUNNEL STILL PUBLIC' "$OUT_FILE"; then ok "N1g. SIGTERM teardown prints the loud FUNNEL STILL PUBLIC line"; else bad "$(cat "$OUT_FILE")"; fi
  fi
else
  bad "N1g setup: foreground connect never wrote a state file within 10s: $(cat "$OUT_FILE" 2>/dev/null)"
  bad "N1g. skipped: SIGTERM exit-code check (setup failed)"
  kill "$N1G_PID" 2>/dev/null
  wait "$N1G_PID" 2>/dev/null
fi
rm -rf "$D"

# ── 2026-09-21 tailscale-macsys-funnel-cli-error-3: doctor / status /
# connect reaction to ts_variant (bin/lib/hmd_tailscale.sh, merged from
# main 79708218 -- oss|macsys|appstore|unknown). This suite's own scope is
# heimdall-app's REACTION to each variant, not ts_variant's own tiering
# correctness (see test/hmd-tailscale.test.sh #46-49 for that). A plain
# fake binary with no HMD_TAILSCALE_APP_PLIST override lives at an
# arbitrary tmp path that matches none of ts_variant's hardcoded oss
# patterns, so it resolves to "unknown", not "oss" -- there is no hermetic
# way to get a real "oss" classification here without the fake binary
# sitting at one of the real hardcoded paths (or under `brew --prefix`),
# which is out of scope for a sandboxed suite and is that other file's job.
MACSYS_PLIST="$TMPROOT/macsys.plist"
cat > "$MACSYS_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macsys</string>
</dict>
</plist>
EOF

APPSTORE_PLIST="$TMPROOT/appstore.plist"
cat > "$APPSTORE_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macos</string>
</dict>
</plist>
EOF

D="$(make_repo)"

DOC_MACSYS="$(HMD_TAILSCALE_APP_PLIST="$MACSYS_PLIST" FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
if [ "$DRC" -ne 0 ]; then ok "doctor (macsys variant) exits nonzero"; else bad "exit $DRC: $DOC_MACSYS"; fi
if printf '%s' "$DOC_MACSYS" | grep -q 'FAIL.*tailscale build variant (macsys'; then ok "doctor (macsys) flags 'tailscale build variant'"; else bad "$DOC_MACSYS"; fi
if printf '%s' "$DOC_MACSYS" | grep -qF 'install the open-source build: brew install tailscale (then: tailscale up)'; then ok "doctor (macsys) prints the exact brew-install fix line"; else bad "$DOC_MACSYS"; fi
if printf '%s' "$DOC_MACSYS" | grep -q 'FAIL.*funnel capability'; then ok "doctor (macsys) also flags 'funnel capability'"; else bad "$DOC_MACSYS"; fi

DOC_APPSTORE="$(HMD_TAILSCALE_APP_PLIST="$APPSTORE_PLIST" FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
if [ "$DRC" -ne 0 ]; then ok "doctor (appstore variant) exits nonzero"; else bad "exit $DRC: $DOC_APPSTORE"; fi
if printf '%s' "$DOC_APPSTORE" | grep -q 'FAIL.*tailscale build variant (appstore'; then ok "doctor (appstore) flags 'tailscale build variant'"; else bad "$DOC_APPSTORE"; fi
if printf '%s' "$DOC_APPSTORE" | grep -qF 'install the open-source build: brew install tailscale (then: tailscale up)'; then ok "doctor (appstore) prints the exact brew-install fix line"; else bad "$DOC_APPSTORE"; fi
if printf '%s' "$DOC_APPSTORE" | grep -q 'FAIL.*funnel capability'; then ok "doctor (appstore) also flags 'funnel capability'"; else bad "$DOC_APPSTORE"; fi

DOC_UNKNOWN="$(FAKE_TS_MODE=online-with-DNSName "$APP" doctor --repo "$D" 2>&1)"; DRC=$?
if [ "$DRC" -eq 0 ]; then ok "doctor (unrecognized variant) still exits 0"; else bad "exit $DRC: $DOC_UNKNOWN"; fi
if printf '%s' "$DOC_UNKNOWN" | grep -q 'warn.*tailscale build variant (unknown'; then ok "doctor (unrecognized variant) warns, does not FAIL, 'tailscale build variant'"; else bad "$DOC_UNKNOWN"; fi
if printf '%s' "$DOC_UNKNOWN" | grep -q 'ok.*funnel capability'; then ok "doctor (unrecognized variant) still passes 'funnel capability'"; else bad "$DOC_UNKNOWN"; fi

STATUS_VARIANT="$(HMD_TAILSCALE_APP_PLIST="$MACSYS_PLIST" FAKE_TS_MODE=online-with-DNSName "$APP" status --repo "$D" 2>&1)"
if printf '%s' "$STATUS_VARIANT" | grep -q '^tailscale build variant: macsys$'; then ok "status prints 'tailscale build variant: macsys'"; else bad "$STATUS_VARIANT"; fi
if printf '%s' "$STATUS_VARIANT" | grep -q '^tailscale binary: '; then ok "status prints the resolved 'tailscale binary:' path"; else bad "$STATUS_VARIANT"; fi

rm -rf "$D"

# ── connect: macsys/appstore build refuses BEFORE the ui starts, exit 9 ──
# (--help still advertises modern funnel flags on this build too, so only
# a variant check -- not a --help sniff -- can catch it; ts_funnel_start's
# own variant guard also returns 9, but only after the ui is already
# running, so this early refusal is what keeps the ui from starting at all)
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-macsys.out"
ERR_FILE="$TMPROOT/connect-macsys.err"
HMD_TAILSCALE_APP_PLIST="$MACSYS_PLIST" FAKE_TS_MODE=online-with-DNSName "$APP" connect --tailscale --repo "$D" --port 0 --bg >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
if [ "$RC" -eq 9 ]; then ok "connect on a macsys build exits 9"; else bad "exit $RC (want 9): $(cat "$ERR_FILE")"; fi
if grep -qF 'install the open-source build: brew install tailscale (then: tailscale up)' "$ERR_FILE"; then ok "connect (macsys) prints the exact brew-install fix line"; else bad "$(cat "$ERR_FILE")"; fi
if [ ! -f "$D/.heimdall/app/connect.json" ]; then ok "connect (macsys) writes no state file"; else bad "state file unexpectedly written"; fi
MACSYS_UI_WAITED=0
while pgrep -f "heimdall-ui --repo $D " >/dev/null 2>&1 && [ "$MACSYS_UI_WAITED" -lt 30 ]; do
  sleep 0.1
  MACSYS_UI_WAITED=$((MACSYS_UI_WAITED + 1))
done
if pgrep -f "heimdall-ui --repo $D " >/dev/null 2>&1; then
  bad "a heimdall-ui process for $D is running after the macsys refusal (should never have started)"
else
  ok "connect (macsys) never started heimdall-ui"
fi
rm -rf "$D"

# ── connect: a funnel-start that never returns is time-boxed, not left to
# hang forever (2026-09-21 tailscale-macsys-funnel-cli-error-3). Budget is
# forced to 3s (HMD_FUNNEL_START_TIMEOUT_S) so the test doesn't wait out
# the real 45s default; the fake `tailscale funnel --bg` sleeps 999999s.
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-hang.out"
ERR_FILE="$TMPROOT/connect-hang.err"
LOG="$TMPROOT/connect-hang.log"
C10_START=$(date +%s)
HMD_FUNNEL_START_TIMEOUT_S=3 FAKE_TS_MODE=funnel-start-hangs FAKE_TS_LOG="$LOG" "$APP" connect --tailscale --repo "$D" --port 0 --bg >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
C10_ELAPSED=$(( $(date +%s) - C10_START ))
if [ "$RC" -eq 10 ]; then ok "connect w/ a hung funnel-start exits 10 instead of hanging"; else bad "exit $RC (want 10): $(cat "$ERR_FILE")"; fi
if [ "$C10_ELAPSED" -le 8 ]; then ok "connect w/ a hung funnel-start returns within timeout+5s (${C10_ELAPSED}s elapsed)"; else bad "took ${C10_ELAPSED}s, want <=8s"; fi
if grep -qF 'funnel start timed out after 3s' "$ERR_FILE"; then ok "connect (timeout) prints the exact timeout message"; else bad "$(cat "$ERR_FILE")"; fi
if grep -qi 'hmd app doctor' "$ERR_FILE"; then ok "connect (timeout) points at 'hmd app doctor'"; else bad "$(cat "$ERR_FILE")"; fi
if [ ! -f "$D/.heimdall/app/connect.json" ]; then ok "connect (timeout) leaves no state file after teardown"; else bad "state file unexpectedly present"; fi
HANG_UI_WAITED=0
while pgrep -f "heimdall-ui --repo $D " >/dev/null 2>&1 && [ "$HANG_UI_WAITED" -lt 30 ]; do
  sleep 0.1
  HANG_UI_WAITED=$((HANG_UI_WAITED + 1))
done
if pgrep -f "heimdall-ui --repo $D " >/dev/null 2>&1; then
  bad "a heimdall-ui process for $D is still running after the funnel-start timeout"
else
  ok "connect (timeout) tore down heimdall-ui after the timeout"
fi
if grep -qE '^funnel (reset|--https=[0-9]+ off)$' "$LOG"; then ok "connect (timeout) still invoked funnel-stop during teardown"; else bad "no stop invocation in log: $(cat "$LOG" 2>/dev/null)"; fi
rm -rf "$D"

# ── connect prints the same -N suffix hint once in its banner (2026-09-21,
# hmdapp docs/HANDOFF-TO-HEIMDALL-2026-09-21.md item 4) ──────────────────────
if [ -n "$HOST_NORM" ]; then
  D="$(make_repo)"
  OUT_FILE="$TMPROOT/connect-dns-suffix.out"
  FAKE_TS_DNSNAME="${HOST_NORM}-1.tail1234.ts.net." FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 --bg >"$OUT_FILE" 2>&1
  RC=$?
  if [ "$RC" -eq 0 ]; then ok "connect --bg (DNSName w/ -N suffix) still exits 0"; else bad "exit $RC: $(cat "$OUT_FILE")"; fi
  EXPECT_CONNECT_LINE="DNSName carries a -N suffix: an older node named ${HOST_NORM} is probably still registered (offline) in the tailnet admin console — remove it at https://login.tailscale.com/admin/machines and re-run 'tailscale up' to reclaim ${HOST_NORM}.tail1234.ts.net"
  CONNECT_HINT_COUNT="$(grep -cF "$EXPECT_CONNECT_LINE" "$OUT_FILE")"
  if [ "$CONNECT_HINT_COUNT" -eq 1 ]; then ok "connect banner prints the -N suffix hint exactly once"; else bad "count=$CONNECT_HINT_COUNT: $(cat "$OUT_FILE")"; fi
  FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" >/dev/null 2>&1
  rm -rf "$D"

  D="$(make_repo)"
  OUT_FILE2="$TMPROOT/connect-dns-nosuffix.out"
  FAKE_TS_MODE=modern-funnel "$APP" connect --tailscale --repo "$D" --port 0 --bg >"$OUT_FILE2" 2>&1
  RC=$?
  if grep -qF -- '-N suffix' "$OUT_FILE2"; then
    bad "connect banner unexpectedly prints the -N suffix hint for a plain DNSName: $(cat "$OUT_FILE2")"
  else
    ok "connect banner prints no -N suffix hint for a plain DNSName"
  fi
  FAKE_TS_MODE=modern-funnel "$APP" disconnect --repo "$D" >/dev/null 2>&1
  rm -rf "$D"
else
  ok "connect -N suffix hint: skipped (no local hostname resolvable in this environment)"
fi


# ── A6: errfile security (no predictable /tmp fallback) ───────────────────
if [ "$(grep -c 'echo "/tmp/' "$APP")" -eq 0 ]; then ok "no hardcoded /tmp fallback patterns in bin/heimdall-app"; else bad "/tmp fallback pattern found in code"; fi
if grep -B3 'errfile=' "$APP" | grep -q 'umask 077'; then ok "errfile mktemp is protected by umask 077"; else bad "umask 077 not found before errfile mktemp"; fi

# ── relay mode: --relay and --https-port are mutually exclusive ──────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-relay-excl.out"
"$APP" connect --repo "$D" --relay "https://relay.example.com" --https-port 8443 >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then ok "connect --relay with --https-port exits 2"; else bad "exit $RC (want 2): $(cat "$OUT_FILE")"; fi
if grep -qi 'mutually exclusive' "$OUT_FILE"; then ok "connect --relay+--https-port prints a mutually-exclusive message"; else bad "$(cat "$OUT_FILE")"; fi
rm -rf "$D"

# ── fake bin/heimdall-relay-client -- drives every relay-mode assertion below.
# The real bin/heimdall-relay-client is python, built and tested separately
# against its own contract (--relay/--repo/--ui-port/--public-host/
# --status-file flags, NDJSON events on stdout, exit 2/11/12/0, SIGTERM ->
# revoke -> exit 0, the relay.json status-file shape) -- this suite only
# proves bin/heimdall-app composes that contract correctly (never re-tests
# the client's own internals), so this fixture fakes exactly the contract,
# nothing more. Mode selected by FAKE_RELAY_MODE; FAKE_RELAY_LOG (if set)
# gets one line per invocation logging the flags it was called with;
# FAKE_RELAY_TERM_MARKER (if set) is touched only when the fake's own TERM
# handler actually ran (proves the signal was caught, not just that the
# process later died some other way).
FAKE_RELAY_BIN="$TMPROOT/heimdall-relay-client"
cat > "$FAKE_RELAY_BIN" <<'FAKE_RELAY_EOF'
#!/usr/bin/env bash
set -u
RELAY_URL="" REPO="" UI_PORT="" PUBLIC_HOST="" STATUS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --relay) RELAY_URL="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --ui-port) UI_PORT="${2:-}"; shift 2 ;;
    --public-host) PUBLIC_HOST="${2:-}"; shift 2 ;;
    --status-file) STATUS_FILE="${2:-}"; shift 2 ;;
    *) echo "fake-relay-client: unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -n "$STATUS_FILE" ] || STATUS_FILE="$REPO/.heimdall/app/relay.json"
mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true

if [ -n "${FAKE_RELAY_LOG:-}" ]; then
  printf 'relay=%s repo=%s ui_port=%s public_host=%s\n' \
    "$RELAY_URL" "$REPO" "$UI_PORT" "$PUBLIC_HOST" >>"$FAKE_RELAY_LOG"
fi

mode="${FAKE_RELAY_MODE:-pair-bind}"
session_id="fake-session-0001"
pairing_code="ABCDEFGHIJKLMNOPQRSTUVWXY0"
now="$(date +%s)"
exp="$((now + 60))"

case "$mode" in
  exit-e2e)
    sleep 0.3
    echo "fake-relay-client: relay E2E unavailable: pyca/cryptography not installed" >&2
    exit 11
    ;;
  exit-unreachable)
    sleep 0.3
    echo "fake-relay-client: relay unreachable: connection refused" >&2
    exit 12
    ;;
  ignore-term)
    trap '' TERM
    printf '{"event":"pair_init","qr":{"v":1,"relay":"%s","session_id":"%s","pairing_code":"%s","exp":%s,"hmd_pubkey":"ZmFrZS1wdWJrZXk="},"exp":%s}\n' \
      "$RELAY_URL" "$session_id" "$pairing_code" "$exp" "$exp"
    while :; do sleep 0.2; done
    ;;
  pair-bind|*)
    printf '{"session_id":"%s","relay":"%s","paired":false,"bound_at":null,"last_seq":0,"frames_sent":0,"last_delivered":null,"last_command_at":null,"started_at":%s,"pid":%s}\n' \
      "$session_id" "$RELAY_URL" "$now" "$$" >"$STATUS_FILE"
    printf '{"event":"pair_init","qr":{"v":1,"relay":"%s","session_id":"%s","pairing_code":"%s","exp":%s,"hmd_pubkey":"ZmFrZS1wdWJrZXk="},"exp":%s}\n' \
      "$RELAY_URL" "$session_id" "$pairing_code" "$exp" "$exp"
    sleep 0.2
    bound_at="$(date +%s)"
    printf '{"session_id":"%s","relay":"%s","paired":true,"bound_at":%s,"last_seq":7,"frames_sent":3,"last_delivered":"2026-09-23T00:00:00Z","last_command_at":null,"started_at":%s,"pid":%s}\n' \
      "$session_id" "$RELAY_URL" "$bound_at" "$now" "$$" >"$STATUS_FILE"
    printf '{"event":"device_bound"}\n'
    term_marker() {
      [ -n "${FAKE_RELAY_TERM_MARKER:-}" ] && : >"${FAKE_RELAY_TERM_MARKER}"
      printf '{"event":"session_ended"}\n'
      exit 0
    }
    trap term_marker TERM
    while :; do sleep 0.2; done
    ;;
esac
FAKE_RELAY_EOF
chmod +x "$FAKE_RELAY_BIN"

# ── relay mode: full success path -- pair_init, device_bound, status, and a
# cooperative disconnect (client catches TERM and revokes itself) ─────────
D="$(make_repo)"
RELAY_URL="https://relay.example.com"
OUT_FILE="$TMPROOT/connect-relay-online.out"
TERM_MARKER="$TMPROOT/relay-term-marker"
RELAY_LOG="$TMPROOT/relay-invoke.log"
rm -f "$TERM_MARKER" "$RELAY_LOG"
# NOT --bg: --bg returns as soon as pair_init is seen (by design, so a caller
# gets its shell back right after the QR renders) and disowns+rm's the
# client's own stdout capture -- device_bound ("phone paired") only ever
# shows up on a session that keeps polling in the foreground. So this one
# session runs in the foreground and is backgrounded at the shell level
# instead (same pattern as the exit-11/exit-12 groups below), which lets us
# observe both pair_init and device_bound before we tear it down ourselves.
( HEIMDALL_RELAY_CLIENT_BIN="$FAKE_RELAY_BIN" FAKE_RELAY_MODE=pair-bind \
    FAKE_RELAY_TERM_MARKER="$TERM_MARKER" FAKE_RELAY_LOG="$RELAY_LOG" \
    "$APP" connect --repo "$D" --port 0 --no-code --relay "$RELAY_URL" >"$OUT_FILE" 2>&1 ) &
FG_PID=$!
PIDS+=("$FG_PID")

SF="$D/.heimdall/app/connect.json"
FG_WAITED=0
while [ ! -f "$SF" ] && [ "$FG_WAITED" -lt 100 ]; do
  sleep 0.1
  FG_WAITED=$((FG_WAITED + 1))
done
if [ -f "$SF" ]; then ok "relay connect (foreground) writes connect.json"; else bad "connect.json never appeared: $(cat "$OUT_FILE")"; fi

PB_WAITED=0
while ! grep -q 'phone paired' "$OUT_FILE" 2>/dev/null && [ "$PB_WAITED" -lt 100 ]; do
  sleep 0.1
  PB_WAITED=$((PB_WAITED + 1))
done

if grep -q '##' "$OUT_FILE"; then ok "relay connect prints a QR code block (ascii glyphs)"; else bad "no QR block: $(cat "$OUT_FILE")"; fi
if grep -q 'PAIRING CODE: ABCDEFGHIJKLMNOPQRSTUVWXY0' "$OUT_FILE"; then ok "relay connect prints the pairing code"; else bad "pairing code missing: $(cat "$OUT_FILE")"; fi
if grep -qi 'E2E-encrypted' "$OUT_FILE"; then ok "relay connect prints the E2E exposure note"; else bad "E2E note missing: $(cat "$OUT_FILE")"; fi
if grep -q 'phone paired' "$OUT_FILE"; then ok "relay connect prints 'phone paired' on device_bound"; else bad "phone-paired message missing: $(cat "$OUT_FILE")"; fi
if grep -q 'public_host=relay.example.com' "$RELAY_LOG" 2>/dev/null; then ok "relay client spawned with --public-host <relay hostname>"; else bad "public-host not propagated: $(cat "$RELAY_LOG" 2>/dev/null)"; fi

SF="$D/.heimdall/app/connect.json"
if [ -f "$SF" ]; then
  ok "connect.json written for relay mode"
  if [ "$(jq -r '.mode // empty' "$SF" 2>/dev/null)" = "relay" ]; then ok "connect.json mode == relay"; else bad "mode=$(jq -r '.mode // empty' "$SF" 2>/dev/null)"; fi
  if [ "$(jq -r '.relay // empty' "$SF" 2>/dev/null)" = "$RELAY_URL" ]; then ok "connect.json relay == $RELAY_URL"; else bad "relay mismatch: $(jq -c . "$SF" 2>/dev/null)"; fi
  if grep -q '"token"' "$SF" 2>/dev/null; then bad "connect.json LEAKS a token key"; else ok "connect.json never contains a token key"; fi
else
  bad "connect.json missing at $SF"
fi

RSF="$D/.heimdall/app/relay.json"
if [ -f "$RSF" ]; then
  ok "relay.json status file written"
  if [ "$(jq -r '.session_id // empty' "$RSF" 2>/dev/null)" = "fake-session-0001" ]; then ok "relay.json session_id readable"; else bad "session_id mismatch: $(jq -c . "$RSF" 2>/dev/null)"; fi
  if [ "$(jq -r '.paired // empty' "$RSF" 2>/dev/null)" = "true" ]; then ok "relay.json paired == true after device_bound"; else bad "paired=$(jq -r '.paired // empty' "$RSF" 2>/dev/null)"; fi
else
  bad "relay.json missing at $RSF"
fi

STATUS_OUT="$("$APP" status --repo "$D" 2>&1)"
SRC=$?
if [ "$SRC" -eq 0 ]; then ok "status exits 0 for a healthy relay session"; else bad "status exit $SRC: $STATUS_OUT"; fi
if printf '%s' "$STATUS_OUT" | grep -q 'mode: relay'; then ok "status prints mode: relay"; else bad "status missing mode line: $STATUS_OUT"; fi
if printf '%s' "$STATUS_OUT" | grep -q "relay: $RELAY_URL"; then ok "status prints the relay URL"; else bad "status missing relay URL: $STATUS_OUT"; fi
if printf '%s' "$STATUS_OUT" | grep -q 'session id: fake-session-0001'; then ok "status prints the session id"; else bad "status missing session id: $STATUS_OUT"; fi
if printf '%s' "$STATUS_OUT" | grep -q 'paired: yes'; then ok "status prints paired: yes"; else bad "status missing paired: $STATUS_OUT"; fi
if printf '%s' "$STATUS_OUT" | grep -q 'frames sent: 3'; then ok "status prints frames_sent from relay.json"; else bad "status missing frames_sent: $STATUS_OUT"; fi
if printf '%s' "$STATUS_OUT" | grep -q 'last seq: 7'; then ok "status prints last_seq from relay.json"; else bad "status missing last_seq: $STATUS_OUT"; fi
if printf '%s' "$STATUS_OUT" | grep -q '2026-09-23T00:00:00Z'; then ok "status prints last_delivered from relay.json"; else bad "status missing last_delivered: $STATUS_OUT"; fi
if printf '%s' "$STATUS_OUT" | grep -q 'client pid:.*running'; then ok "status shows the relay client as running"; else bad "status client-alive mismatch: $STATUS_OUT"; fi
if printf '%s' "$STATUS_OUT" | grep -q 'ui pid:.*running'; then ok "status shows heimdall-ui as running"; else bad "status ui-alive mismatch: $STATUS_OUT"; fi

DISC_OUT="$TMPROOT/disconnect-relay-online.out"
"$APP" disconnect --repo "$D" >"$DISC_OUT" 2>&1
DRC=$?
if [ "$DRC" -eq 0 ]; then ok "disconnect exits 0 for a cooperative relay client"; else bad "disconnect exit $DRC: $(cat "$DISC_OUT")"; fi

DISC_WAITED=0
while [ ! -f "$TERM_MARKER" ] && [ "$DISC_WAITED" -lt 30 ]; do
  sleep 0.1
  DISC_WAITED=$((DISC_WAITED + 1))
done
if [ -f "$TERM_MARKER" ]; then ok "relay client's TERM handler ran (marker file written)"; else bad "TERM marker never appeared"; fi
if [ -f "$SF" ]; then bad "connect.json still present after disconnect"; else ok "connect.json removed after disconnect"; fi
if [ -f "$RSF" ]; then bad "relay.json still present after disconnect"; else ok "relay.json removed after disconnect"; fi

wait "$FG_PID"
RC=$?
if [ "$RC" -eq 0 ]; then ok "relay connect (foreground) exits 0 once the client session ends"; else bad "exit $RC: $(cat "$OUT_FILE")"; fi
rm -rf "$D"

# ── relay mode: client exits 11 (E2E unavailable) before pair_init ────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-relay-e2e.out"
( HEIMDALL_RELAY_CLIENT_BIN="$FAKE_RELAY_BIN" FAKE_RELAY_MODE=exit-e2e \
    "$APP" connect --repo "$D" --port 0 --no-code --relay "https://relay.example.com" >"$OUT_FILE" 2>&1 ) &
FG_PID=$!
PIDS+=("$FG_PID")

SF="$D/.heimdall/app/connect.json"
FG_WAITED=0
while [ ! -f "$SF" ] && [ "$FG_WAITED" -lt 100 ]; do
  sleep 0.1
  FG_WAITED=$((FG_WAITED + 1))
done
FG_UI_PID=""
[ -f "$SF" ] && FG_UI_PID="$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)"
if [ -n "$FG_UI_PID" ] && kill -0 "$FG_UI_PID" 2>/dev/null; then
  ok "relay connect's ui is alive while the client is still starting (exit-11 case)"
else
  bad "could not observe a live ui pid before the client failed (exit-11 case)"
fi

wait "$FG_PID"
RC=$?
if [ "$RC" -eq 11 ]; then ok "connect exits 11 when the relay client can't start (E2E unavailable)"; else bad "exit $RC (want 11): $(cat "$OUT_FILE")"; fi
if grep -q 'relay E2E unavailable' "$OUT_FILE"; then ok "connect surfaces the client's stderr on exit 11"; else bad "stderr not surfaced: $(cat "$OUT_FILE")"; fi
if [ -n "$FG_UI_PID" ] && kill -0 "$FG_UI_PID" 2>/dev/null; then
  bad "ui process still alive after connect exited 11"
else
  ok "ui process stopped after connect exited 11"
fi
if [ -f "$SF" ]; then bad "connect.json still present after exit 11"; else ok "connect.json removed after exit 11"; fi
rm -rf "$D"

# ── relay mode: client exits 12 (relay unreachable) before pair_init ──────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-relay-unreachable.out"
( HEIMDALL_RELAY_CLIENT_BIN="$FAKE_RELAY_BIN" FAKE_RELAY_MODE=exit-unreachable \
    "$APP" connect --repo "$D" --port 0 --no-code --relay "https://relay.example.com" >"$OUT_FILE" 2>&1 ) &
FG_PID=$!
PIDS+=("$FG_PID")

SF="$D/.heimdall/app/connect.json"
FG_WAITED=0
while [ ! -f "$SF" ] && [ "$FG_WAITED" -lt 100 ]; do
  sleep 0.1
  FG_WAITED=$((FG_WAITED + 1))
done
FG_UI_PID=""
[ -f "$SF" ] && FG_UI_PID="$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)"
if [ -n "$FG_UI_PID" ] && kill -0 "$FG_UI_PID" 2>/dev/null; then
  ok "relay connect's ui is alive while the client is still starting (exit-12 case)"
else
  bad "could not observe a live ui pid before the client failed (exit-12 case)"
fi

wait "$FG_PID"
RC=$?
if [ "$RC" -eq 12 ]; then ok "connect exits 12 when the relay is unreachable"; else bad "exit $RC (want 12): $(cat "$OUT_FILE")"; fi
if grep -q 'relay unreachable' "$OUT_FILE"; then ok "connect surfaces the client's stderr on exit 12"; else bad "stderr not surfaced: $(cat "$OUT_FILE")"; fi
if [ -n "$FG_UI_PID" ] && kill -0 "$FG_UI_PID" 2>/dev/null; then
  bad "ui process still alive after connect exited 12"
else
  ok "ui process stopped after connect exited 12"
fi
if [ -f "$SF" ]; then bad "connect.json still present after exit 12"; else ok "connect.json removed after exit 12"; fi
rm -rf "$D"

# ── relay mode: disconnect when the client ignores TERM -> force-kill,
# exit 8, and the revoke-may-not-have-landed warning ──────────────────────
D="$(make_repo)"
OUT_FILE="$TMPROOT/connect-relay-ignoreterm.out"
HEIMDALL_RELAY_CLIENT_BIN="$FAKE_RELAY_BIN" FAKE_RELAY_MODE=ignore-term \
  "$APP" connect --repo "$D" --port 0 --no-code --relay "https://relay.example.com" --bg >"$OUT_FILE" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "relay connect --bg (ignore-term client) exits 0"; else bad "exit $RC: $(cat "$OUT_FILE")"; fi

SF="$D/.heimdall/app/connect.json"
IT_CLIENT_PID="$(jq -r '.pid_client // empty' "$SF" 2>/dev/null)"
IT_UI_PID="$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)"
if [ -n "$IT_CLIENT_PID" ] && kill -0 "$IT_CLIENT_PID" 2>/dev/null; then
  ok "relay client (ignore-term) is alive before disconnect"
else
  bad "relay client pid $IT_CLIENT_PID not alive before disconnect"
fi

DISC_OUT="$TMPROOT/disconnect-relay-ignoreterm.out"
HMD_RELAY_STOP_TIMEOUT_S=2 "$APP" disconnect --repo "$D" >"$DISC_OUT" 2>&1
DRC=$?
if [ "$DRC" -eq 8 ]; then ok "disconnect exits 8 when the relay client ignores TERM"; else bad "disconnect exit $DRC (want 8): $(cat "$DISC_OUT")"; fi
if grep -q 'revoke may not have reached the relay' "$DISC_OUT"; then ok "disconnect prints the revoke-may-not-have-reached warning"; else bad "warning missing: $(cat "$DISC_OUT")"; fi

if [ -n "$IT_CLIENT_PID" ] && kill -0 "$IT_CLIENT_PID" 2>/dev/null; then
  bad "relay client still alive after force-kill disconnect"
else
  ok "relay client force-killed by disconnect (ignore-term path)"
fi
if [ -n "$IT_UI_PID" ] && kill -0 "$IT_UI_PID" 2>/dev/null; then
  bad "ui process still alive after force-kill disconnect"
else
  ok "ui process stopped by force-kill disconnect"
fi
if [ -f "$SF" ]; then bad "connect.json still present after disconnect"; else ok "connect.json removed after disconnect"; fi
if [ -f "$D/.heimdall/app/relay.json" ]; then bad "relay.json still present after disconnect"; else ok "relay.json removed after disconnect"; fi
rm -rf "$D"

# ── doctor --relay: reachable relay (loopback python http.server) -> ok ──
D="$(make_repo)"
DOCTOR_SRV_OUT="$TMPROOT/doctor-relay-srv.out"
python3 - <<'PYEOF' >"$DOCTOR_SRV_OUT" 2>&1 &
import http.server
srv = http.server.HTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PYEOF
DOCTOR_SRV_PID=$!
PIDS+=("$DOCTOR_SRV_PID")
DOCTOR_SRV_WAITED=0
DOCTOR_SRV_PORT=""
while [ -z "$DOCTOR_SRV_PORT" ] && [ "$DOCTOR_SRV_WAITED" -lt 100 ]; do
  DOCTOR_SRV_PORT="$(head -1 "$DOCTOR_SRV_OUT" 2>/dev/null)"
  if [ -z "$DOCTOR_SRV_PORT" ]; then
    sleep 0.1
    DOCTOR_SRV_WAITED=$((DOCTOR_SRV_WAITED + 1))
  fi
done

if [ -n "$DOCTOR_SRV_PORT" ]; then
  DOUT="$TMPROOT/doctor-relay-ok.out"
  "$APP" doctor --repo "$D" --relay "http://127.0.0.1:${DOCTOR_SRV_PORT}" >"$DOUT" 2>&1
  DRC=$?
  if [ "$DRC" -eq 0 ]; then ok "doctor --relay exits 0 against a reachable loopback server"; else bad "doctor exit $DRC: $(cat "$DOUT")"; fi
  if grep -Eq '^ok +relay reachable' "$DOUT"; then ok "doctor prints 'ok relay reachable'"; else bad "relay-reachable ok line missing: $(cat "$DOUT")"; fi
  if grep -Eq '^skip +tailscale installed \(relay mode\)' "$DOUT"; then ok "doctor skips tailscale checks in relay mode"; else bad "tailscale skip line missing: $(cat "$DOUT")"; fi
else
  bad "loopback python http.server never printed a port"
fi
kill "$DOCTOR_SRV_PID" 2>/dev/null
wait "$DOCTOR_SRV_PID" 2>/dev/null
rm -rf "$D"

# ── doctor --relay: unreachable relay -> FAIL ─────────────────────────────
D="$(make_repo)"
DOUT="$TMPROOT/doctor-relay-fail.out"
"$APP" doctor --repo "$D" --relay "https://127.0.0.1:1" >"$DOUT" 2>&1
DRC=$?
if [ "$DRC" -eq 1 ]; then ok "doctor --relay exits 1 (FAIL) against an unreachable relay"; else bad "doctor exit $DRC (want 1): $(cat "$DOUT")"; fi
if grep -Eq '^FAIL +relay reachable' "$DOUT"; then ok "doctor prints 'FAIL relay reachable'"; else bad "FAIL line missing: $(cat "$DOUT")"; fi
if grep -qi 'relay unreachable' "$DOUT"; then ok "doctor prints the relay-unreachable fix hint"; else bad "fix hint missing: $(cat "$DOUT")"; fi
rm -rf "$D"

# ── connect when the port is already held: reuse / replace / step around ─────────────────────────────────
# The live bug: a `hmd ui` left running for the repo (its relay client gone) made `hmd app connect --port N` exit 6
# ("hmd ui: cannot bind 127.0.0.1:N: Address already in use"). Every ui below is the real bin/heimdall-ui, except the
# one deliberately older than /healthz; the relay client is the fake above; ports come from the kernel, never 8710.
t_free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# t_start_ui REPO PORT -- a real `hmd ui` for REPO on PORT, as an earlier connect (or `hmd ui` typed by hand) leaves
# behind; sets T_UI_PID once it has printed its URL. Tracked in PIDS so the exit trap reaps it.
t_start_ui() {
  local repo="$1" port="$2" out waited=0
  out="$(mktemp "$TMPROOT/ui-out.XXXXXX")"
  ( cd "$repo" && exec "$UI" --repo "$repo" --port "$port" --no-open ) >"$out" 2>&1 &
  T_UI_PID=$!
  PIDS+=("$T_UI_PID")
  while ! grep -q '^http://127.0.0.1:' "$out" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
}

# t_connect REPO PORT -- `connect --bg` against the fake relay client; sets T_RC, and T_OUTF holds what it printed.
t_connect() {
  T_OUTF="$(mktemp "$TMPROOT/connect-out.XXXXXX")"
  HEIMDALL_RELAY_CLIENT_BIN="$FAKE_RELAY_BIN" FAKE_RELAY_MODE=pair-bind FAKE_RELAY_LOG="$T_RELAY_LOG" \
    "$APP" connect --repo "$1" --port "$2" --no-code --relay "https://relay.example.com" --bg >"$T_OUTF" 2>&1
  T_RC=$?
}

# The /healthz route those decisions rest on: the live ui answers it for its own loopback origin, with the token
# gate untouched everywhere else.
D="$(make_repo)"
P1="$(t_free_port)"
t_start_ui "$D" "$P1"
HEALTH_BODY="$(curl -s --noproxy '*' --max-time 5 "http://127.0.0.1:$P1/healthz")"
if [ "$(printf '%s' "$HEALTH_BODY" | jq -r '[.ok, .service, .pid] | @csv' 2>/dev/null)" = "true,\"hmd-ui\",$T_UI_PID" ]; then ok "/healthz answers {ok, service: hmd-ui, pid} without a token"; else bad "/healthz body: $HEALTH_BODY"; fi
if [ "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 -H 'Host: evil.example' "http://127.0.0.1:$P1/healthz")" = "403" ]; then ok "/healthz refuses a Host that is not the loopback origin (403)"; else bad "/healthz answered a foreign Host"; fi
if [ "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 "http://127.0.0.1:$P1/api/state")" = "401" ]; then ok "/api/state still demands the token (401)"; else bad "/api/state answered without a token"; fi

# /healthz is the one answer given without the token, so every way past its conditions must land on the ordinary gate
# (401, or 403 for a foreign Host) and never on the health body: exact "/healthz" only (no query, prefix, dot-segment,
# encoded, case, suffix or absolute-form variant -- and none of them reaches another route), GET only, a loopback peer,
# a ui that is not exposed (--allow-host / --trust-proxy), no proxy header, one Host that is the ui's own loopback origin.
hz_code() { curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 --path-as-is "$@"; }
HZ_BAD=""
for hz_path in '/healthz?x=1' '/healthz?token=wrong' '/healthz/' '/healthz/../api/state' '/healthz/..%2fapi%2fstate' '/healthz%2f' '/%68ealthz' '/healthz;x=1' '//healthz' '/HEALTHZ' '/healthz.json' '/healthz%00'; do
  [ "$(hz_code "http://127.0.0.1:$P1$hz_path")" = "401" ] || HZ_BAD="$HZ_BAD $hz_path"
done
if [ -z "$HZ_BAD" ]; then ok "/healthz: every path variant (query, prefix, dot-segment, encoded, case, suffix) meets the token gate (401)"; else bad "path variants not refused with 401:$HZ_BAD"; fi
if [ "$(hz_code -X POST "http://127.0.0.1:$P1/healthz")" = "401" ] && [ "$(hz_code -I "http://127.0.0.1:$P1/healthz")" = "401" ]; then ok "/healthz: POST and HEAD meet the token gate (GET only)"; else bad "/healthz answered POST or HEAD"; fi
if [ "$(hz_code -H 'X-Forwarded-For: 203.0.113.9' "http://127.0.0.1:$P1/healthz")" = "401" ] && [ "$(hz_code -H 'Host: 127.0.0.1:1' "http://127.0.0.1:$P1/healthz")" = "403" ]; then ok "/healthz: a proxy header (401) or another port in Host (403) is refused"; else bad "/healthz answered a proxied or wrong-port request"; fi

# an exposed ui (--allow-host, or --trust-proxy) has no /healthz at all: behind a Funnel or a proxy every peer is the local
# proxy, so a loopback peer address proves nothing
t_exposed_healthz() {
  local label="$1" port pid waited=0 body
  shift
  port="$(t_free_port)"
  ( cd "$D" && exec "$UI" --repo "$D" --port "$port" --no-open "$@" ) >/dev/null 2>&1 &
  pid=$!
  PIDS+=("$pid")
  while ! { : <>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  body="$(curl -s --noproxy '*' --max-time 5 "http://127.0.0.1:$port/healthz")"
  if [ "$(hz_code "http://127.0.0.1:$port/healthz")" = "401" ] && ! printf '%s' "$body" | grep -q '"pid"'; then ok "/healthz: an exposed ui ($label) does not serve it, even to a loopback peer"; else bad "exposed ui ($label) answered /healthz: $body"; fi
}
t_exposed_healthz "--allow-host" --allow-host funnel.example.ts.net
t_exposed_healthz "--trust-proxy" --trust-proxy

# the real handler, driven as if the request came from each peer (a socketpair carries the bytes; the peer address is
# what the handler reads as client_address): non-loopback peers, exposed servers, Host, header and method variants
HZ_REPO="$(make_repo)"
IFS= read -r -d '' HZ_PY <<'HZ_PY_EOF' || true
import importlib.util, json, os, socket, sys

spec = importlib.util.spec_from_file_location("hmd_ui_under_test", sys.argv[1])
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)
root = os.path.realpath(sys.argv[2])
cache = ui.StateCache(root, {"bind": "loopback", "public_host": None, "trust_proxy": False})
plain = ui.UIServer(0, "tok", cache)
published = ui.UIServer(0, "tok", cache, allow_hosts=("funnel.example.ts.net",))
proxied = ui.UIServer(0, "tok", cache, trust_proxy=True)


def serve(server, peer, method="GET", path="/healthz", host=None, extra=""):
    if host is None:
        host = "127.0.0.1:%d" % server.port
    request = ("%s %s HTTP/1.1\r\nHost: %s\r\n%sConnection: close\r\n\r\n" % (method, path, host, extra)).encode()
    client, handler_end = socket.socketpair()
    client.settimeout(5)
    client.sendall(request)
    ui.UIHandler(handler_end, (peer, 40000), server)
    handler_end.close()
    raw = b""
    while True:
        chunk = client.recv(65536)
        if not chunk:
            break
        raw += chunk
    client.close()
    head, _, body = raw.partition(b"\r\n\r\n")
    return int(head.split(b" ", 2)[1]), body.decode("utf-8", "replace")


lines = []


def check(label, good):
    lines.append("%s %s" % ("ok" if good else "FAIL", label))


def refused(result, want=None):
    status, body = result
    return status != 200 and '"pid"' not in body and (want is None or status == want)


for peer in ("127.0.0.1", "::1"):
    status, body = serve(plain, peer)
    doc = json.loads(body) if status == 200 else {}
    check("loopback peer %s: 200 with only ok/service/schema/pid, no path" % peer,
          status == 200 and set(doc) == {"ok", "service", "schema", "pid"} and doc["ok"] is True
          and doc["pid"] == os.getpid() and root not in body)
for peer in ("10.1.2.3", "192.168.0.7", "203.0.113.9", "fe80::1", "", "not-an-address"):
    check("non-loopback peer %r: refused with 401, no pid" % peer, refused(serve(plain, peer), 401))
for label, server in (("--allow-host", published), ("--trust-proxy", proxied)):
    check("exposed server (%s): refused with 401 even for a loopback peer" % label, refused(serve(server, "127.0.0.1"), 401))
check("Host localhost:PORT is the loopback origin too: 200", serve(plain, "127.0.0.1", host="localhost:%d" % plain.port)[0] == 200)
for number, host in enumerate(("127.0.0.1", "127.0.0.1:1", "localhost", "evil.example", "evil.example:%d" % plain.port, "funnel.example.ts.net"), 2):
    check("Host %r: refused with 403" % host, refused(serve(plain, "127.0.0.%d" % number, host=host), 403))
check("two Host headers: refused with 401", refused(serve(plain, "127.0.0.1", extra="Host: evil.example\r\n"), 401))
for header in ("X-Forwarded-For: 203.0.113.9", "Forwarded: for=203.0.113.9", "X-Real-IP: 203.0.113.9", "Via: 1.1 proxy"):
    check("proxy header %s: refused with 401" % header.split(":")[0], refused(serve(plain, "127.0.0.1", extra=header + "\r\n"), 401))
for method in ("HEAD", "POST"):
    check("method %s: refused with 401" % method, refused(serve(plain, "127.0.0.1", method=method), 401))
check("method PUT: refused", refused(serve(plain, "127.0.0.1", method="PUT")))
for path in ("/healthz?x=1", "/healthz/", "/healthz/../api/state", "//healthz", "/healthz%2e", "http://127.0.0.1:%d/healthz" % plain.port):
    check("path %s: refused with 401" % path, refused(serve(plain, "127.0.0.1", path=path), 401))
for server in (plain, published, proxied):
    server.server_close()
print("\n".join(lines))
print("done")
HZ_PY_EOF
HZ_PY_OUT="$(python3 -I -c "$HZ_PY" "$REPO/sentinels/hmd-ui.py" "$HZ_REPO" 2>&1)"
if [ "$(printf '%s\n' "$HZ_PY_OUT" | tail -1)" = "done" ]; then
  while IFS= read -r hz_line; do
    case "$hz_line" in
      "ok "*) ok "/healthz handler: ${hz_line#ok }" ;;
      "FAIL "*) bad "/healthz handler: ${hz_line#FAIL }" ;;
    esac
  done <<< "$HZ_PY_OUT"
else
  bad "/healthz handler matrix did not run to the end: $(printf '%s' "$HZ_PY_OUT" | tail -5)"
fi
rm -rf "$HZ_REPO"

# 1. the live bug: a stale ui for THIS repo, no relay client -- connect reuses it and starts the client against it
T_RELAY_LOG="$TMPROOT/stale-reuse-relay.log"; : > "$T_RELAY_LOG"
STALE_PID="$T_UI_PID"
t_connect "$D" "$P1"
if [ "$T_RC" -eq 0 ]; then ok "connect --port N w/ a stale same-repo ui on N exits 0 (was exit 6, cannot bind)"; else bad "exit $T_RC (want 0): $(cat "$T_OUTF")"; fi
SF="$D/.heimdall/app/connect.json"
if [ "$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)" = "$STALE_PID" ] && [ "$(jq -r '.port // empty' "$SF" 2>/dev/null)" = "$P1" ]; then ok "reuse: connect.json records the stale ui's pid and port"; else bad "connect.json: $(jq -c . "$SF" 2>/dev/null)"; fi
if kill -0 "$STALE_PID" 2>/dev/null; then ok "reuse: the stale ui is still the live process (not restarted)"; else bad "stale ui $STALE_PID is gone"; fi
if grep -q "ui_port=$P1 " "$T_RELAY_LOG"; then ok "reuse: the relay client was started against the reused ui's port"; else bad "relay log: $(cat "$T_RELAY_LOG")"; fi
if grep -qi 'reusing the hmd ui' "$T_OUTF"; then ok "reuse: connect says it reused the running ui"; else bad "no reuse notice: $(cat "$T_OUTF")"; fi
"$APP" disconnect --repo "$D" >/dev/null 2>&1
if kill -0 "$STALE_PID" 2>/dev/null; then bad "disconnect left the adopted ui running"; else ok "disconnect stops the adopted ui like one connect started"; fi
rm -rf "$D"

# 2. a same-repo ui that is not a working one -- here an older build, which has no /healthz and answers 401 to it --
# is stopped (it is this user's python running <...>/sentinels/hmd-ui.py --repo <this repo>) and a fresh ui binds
# the SAME port
D="$(make_repo)"
P2="$(t_free_port)"
OLD_UI_DIR="$TMPROOT/old-build/sentinels"
mkdir -p "$OLD_UI_DIR"
cat > "$OLD_UI_DIR/hmd-ui.py" <<'OLD_UI_EOF'
import http.server, sys
port = int(sys.argv[sys.argv.index("--port") + 1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401)
        self.send_header("Content-Length", "0")
        self.end_headers()
class S(http.server.ThreadingHTTPServer):
    allow_reuse_address = False
S(("127.0.0.1", port), H).serve_forever()
OLD_UI_EOF
python3 "$OLD_UI_DIR/hmd-ui.py" --repo "$D" --port "$P2" --no-open >/dev/null 2>&1 &
OLD_PID=$!
PIDS+=("$OLD_PID")
OLD_WAITED=0
while ! { : <>"/dev/tcp/127.0.0.1/$P2"; } 2>/dev/null && [ "$OLD_WAITED" -lt 50 ]; do
  sleep 0.1
  OLD_WAITED=$((OLD_WAITED + 1))
done
T_RELAY_LOG="$TMPROOT/stale-replace-relay.log"; : > "$T_RELAY_LOG"
t_connect "$D" "$P2"
if [ "$T_RC" -eq 0 ]; then ok "connect w/ an older/unhealthy same-repo ui on the port exits 0"; else bad "exit $T_RC (want 0): $(cat "$T_OUTF")"; fi
SF="$D/.heimdall/app/connect.json"
NEW_PID="$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)"
if kill -0 "$OLD_PID" 2>/dev/null; then bad "replace: the old ui $OLD_PID is still running"; else ok "replace: the unhealthy same-repo ui was stopped"; fi
if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && kill -0 "$NEW_PID" 2>/dev/null; then ok "replace: connect.json records a fresh live ui"; else bad "connect.json: $(jq -c . "$SF" 2>/dev/null)"; fi
if [ "$(jq -r '.port // empty' "$SF" 2>/dev/null)" = "$P2" ]; then ok "replace: the fresh ui is on the same port"; else bad "port: $(jq -r '.port // empty' "$SF" 2>/dev/null) (want $P2): $(cat "$T_OUTF")"; fi
if [ "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 "http://127.0.0.1:$P2/healthz")" = "200" ]; then ok "replace: the port now answers /healthz (the real hmd-ui)"; else bad "fresh ui does not answer /healthz"; fi
if grep -q "ui_port=$P2 " "$T_RELAY_LOG"; then ok "replace: the relay client was started against the fresh ui"; else bad "relay log: $(cat "$T_RELAY_LOG")"; fi
"$APP" disconnect --repo "$D" >/dev/null 2>&1
rm -rf "$D"

# 3. the port is held by ANOTHER repo's hmd ui -- untouched; connect takes the next free port, says so, records it
D="$(make_repo)"
D_OTHER="$(make_repo)"
P3="$(t_free_port)"
t_start_ui "$D_OTHER" "$P3"
OTHER_PID="$T_UI_PID"
T_RELAY_LOG="$TMPROOT/other-repo-relay.log"; : > "$T_RELAY_LOG"
t_connect "$D" "$P3"
if [ "$T_RC" -eq 0 ]; then ok "connect w/ another repo's ui on the port exits 0"; else bad "exit $T_RC (want 0): $(cat "$T_OUTF")"; fi
SF="$D/.heimdall/app/connect.json"
GOT_PORT="$(jq -r '.port // empty' "$SF" 2>/dev/null)"
if [ -n "$GOT_PORT" ] && [ "$GOT_PORT" -gt "$P3" ] 2>/dev/null; then ok "other repo: connect.json records a later port ($GOT_PORT > $P3)"; else bad "port=$GOT_PORT (want > $P3): $(cat "$T_OUTF")"; fi
if kill -0 "$OTHER_PID" 2>/dev/null; then ok "other repo: its ui was never signalled"; else bad "the other repo's ui $OTHER_PID was killed"; fi
if [ "$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)" != "$OTHER_PID" ]; then ok "other repo: connect started its own ui"; else bad "connect adopted the other repo's ui"; fi
if grep -q "using port $GOT_PORT" "$T_OUTF"; then ok "other repo: connect prints which port it used"; else bad "no port notice: $(cat "$T_OUTF")"; fi
if grep -q "ui_port=$GOT_PORT " "$T_RELAY_LOG"; then ok "other repo: the relay client was started against the new port"; else bad "relay log: $(cat "$T_RELAY_LOG")"; fi
"$APP" disconnect --repo "$D" >/dev/null 2>&1
if kill -0 "$OTHER_PID" 2>/dev/null; then ok "other repo: its ui survives this repo's disconnect"; else bad "disconnect took the other repo's ui down"; fi
rm -rf "$D" "$D_OTHER"

# 4. a foreign (not hmd) listener on the port -- untouched, next free port
D="$(make_repo)"
P4="$(t_free_port)"
python3 - "$P4" <<'FOREIGN_EOF' &
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(5)
time.sleep(120)
FOREIGN_EOF
FOREIGN_PID=$!
PIDS+=("$FOREIGN_PID")
FOREIGN_WAITED=0
while ! { : <>"/dev/tcp/127.0.0.1/$P4"; } 2>/dev/null && [ "$FOREIGN_WAITED" -lt 50 ]; do
  sleep 0.1
  FOREIGN_WAITED=$((FOREIGN_WAITED + 1))
done
T_RELAY_LOG="$TMPROOT/foreign-relay.log"; : > "$T_RELAY_LOG"
t_connect "$D" "$P4"
SF="$D/.heimdall/app/connect.json"
GOT_PORT="$(jq -r '.port // empty' "$SF" 2>/dev/null)"
if [ "$T_RC" -eq 0 ] && [ -n "$GOT_PORT" ] && [ "$GOT_PORT" != "$P4" ]; then ok "connect w/ a foreign listener on the port exits 0 on another port"; else bad "exit $T_RC port=$GOT_PORT: $(cat "$T_OUTF")"; fi
if kill -0 "$FOREIGN_PID" 2>/dev/null; then ok "foreign listener: never signalled"; else bad "the foreign listener was killed"; fi
"$APP" disconnect --repo "$D" >/dev/null 2>&1
rm -rf "$D"

# 5. a same-repo ui that a LIVE relay client is serving is neither stale nor ours to stop: refused, untouched
D="$(make_repo)"
P5="$(t_free_port)"
T_RELAY_LOG="$TMPROOT/live-relay.log"; : > "$T_RELAY_LOG"
t_connect "$D" "$P5"
SF="$D/.heimdall/app/connect.json"
LIVE_UI="$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)"
LIVE_CLIENT="$(jq -r '.pid_client // empty' "$SF" 2>/dev/null)"
t_connect "$D" "$P5"
if [ "$T_RC" -eq 6 ] && grep -q 'already connected' "$T_OUTF"; then ok "a second connect on a live session's port exits 6 and says already connected"; else bad "exit $T_RC: $(cat "$T_OUTF")"; fi
if [ -n "$LIVE_UI" ] && kill -0 "$LIVE_UI" 2>/dev/null && [ -n "$LIVE_CLIENT" ] && kill -0 "$LIVE_CLIENT" 2>/dev/null; then ok "live session: its ui and client were left running"; else bad "live session was disturbed (ui=$LIVE_UI client=$LIVE_CLIENT)"; fi
if [ "$(jq -r '.pid_ui // empty' "$SF" 2>/dev/null)" = "$LIVE_UI" ]; then ok "live session: connect.json still names its ui"; else bad "connect.json changed: $(jq -c . "$SF" 2>/dev/null)"; fi
"$APP" disconnect --repo "$D" >/dev/null 2>&1
rm -rf "$D"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

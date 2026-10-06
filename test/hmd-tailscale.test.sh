#!/usr/bin/env bash
# hmd-tailscale.test.sh — tests for bin/lib/hmd_tailscale.sh, the Tailscale CLI wrapper
# consumed by Wave 2's `hmd app connect|status|disconnect|doctor`.
#
# Harness style mirrors test/heimdall-ui.test.sh: numbered cases, ok()/bad() tallies, a
# mktemp -d sandbox cleaned via trap, and a FAKE tailscale binary — never the real
# tailscaled — driven by FAKE_TS_MODE and injected via HMD_TAILSCALE_BIN, the library's
# documented test seam. Every case that needs a custom PATH/env/stdin runs inside a
# `( ... )` subshell so it can never leak into the next case.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/bin/lib/hmd_tailscale.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# ── 1. syntax check ──────────────────────────────────────────────────────────────────
if bash -n "$LIB" 2>/tmp/hmd-tailscale-syntax.$$; then
  ok "1. bash -n bin/lib/hmd_tailscale.sh"
else
  bad "1. bash -n bin/lib/hmd_tailscale.sh: $(cat /tmp/hmd-tailscale-syntax.$$ 2>/dev/null)"
fi
rm -f /tmp/hmd-tailscale-syntax.$$ 2>/dev/null || true

if [ ! -f "$LIB" ]; then
  printf 'FATAL: library not found: %s\n' "$LIB" >&2
  printf '\n%s passed, %s failed\n' "$PASS" "$((FAIL + 1))"
  exit 1
fi

# ── fake tailscale CLI ──────────────────────────────────────────────────────────────
# One script, behaviour switched by $FAKE_TS_MODE. Never touches the real tailscaled.
# Modes: not-installed, daemon-down, offline, online-with-DNSName, modern-funnel,
# legacy-funnel, no-funnel, policy-hint-on-funnel-start, bad-https-port,
# modern-funnel-scoped-off, funnel-approval-url, funnel-approval-then-ok (D8 --
# hmdapp handoff item 2: the real CLI prints its tailnet-approval hint to STDOUT,
# then blocks; these two simulate that on the `--bg` modern-start path).
# FAKE_FUNNEL_STATUS_JSON, when set, overrides the canned
# `funnel status` payload (used by the A13 foreign/only-ours/force/scoped tests).
# FAKE_CALL_LOG, when set, appends every invocation's full argv (one line each) to
# that file so a test can assert reset was/wasn't actually called.
FAKE_BIN="$TMPROOT/tailscale"
cat > "$FAKE_BIN" <<'FAKE_EOF'
#!/usr/bin/env bash
mode="${FAKE_TS_MODE:-online-with-DNSName}"

if [ "$mode" = "not-installed" ]; then
  echo "fake-tailscale: command not found" >&2
  exit 127
fi

if [ -n "${FAKE_CALL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_CALL_LOG"
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
          modern-funnel-scoped-off)
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
  --https=PORT off
        Disable Funnel for the specified port only, leaving others untouched
EOF
            exit 0
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
        if [ -n "${FAKE_FUNNEL_STATUS_JSON:-}" ]; then
          printf '%s' "$FAKE_FUNNEL_STATUS_JSON"
        else
          echo '{"Funnel":{}}'
        fi
        exit 0
        ;;
      reset)
        exit 0
        ;;
      --bg)
        # modern start: funnel --bg --https=PORT http://127.0.0.1:PORT
        if [ "$mode" = "policy-hint-on-funnel-start" ]; then
          echo "$POLICY_HINT" >&2
          exit 1
        fi
        if [ "$mode" = "funnel-approval-url" ]; then
          # D8 fixture: real CLI behaviour is to print this to STDOUT, then
          # block polling for tailnet approval -- sleep stands in for "blocks
          # indefinitely" so the caller's HMD_FUNNEL_APPROVE_WAIT_S window
          # elapses first every time.
          echo "Funnel is not enabled on your tailnet. To enable, visit: https://login.tailscale.com/f/funnel?node=nodeid123abc"
          sleep 30
          exit 1
        fi
        if [ "$mode" = "funnel-approval-then-ok" ]; then
          # D8 fixture: approval arrives before the wait window elapses.
          echo "Funnel is not enabled on your tailnet. To enable, visit: https://login.tailscale.com/f/funnel?node=nodeid123abc"
          sleep 1
          exit 0
        fi
        exit 0
        ;;
      --https=*)
        # modern scoped stop: funnel --https=PORT off (A13 fake support for D6's
        # scoped-off path -- real tailscale 1.94.2 has no such form; see
        # ts_funnel_scoped_off_supported's doc comment in bin/lib/hmd_tailscale.sh).
        exit 0
        ;;
      *)
        # legacy start/stop: funnel PORT on|off
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
unset HMD_ASSUME_NO FAKE_TS_MODE HMD_TAILSCALE_APP_PLIST

# shellcheck source=/dev/null
source "$LIB"

# ── 2. ts_bin: HMD_TAILSCALE_BIN override is honoured verbatim ─────────────────────
if out="$(HMD_TAILSCALE_BIN="$FAKE_BIN" ts_bin 2>/dev/null)" && [ "$out" = "$FAKE_BIN" ]; then
  ok "2. ts_bin honours HMD_TAILSCALE_BIN override"
else
  bad "2. ts_bin honours HMD_TAILSCALE_BIN override (got: $out)"
fi

# ── 3. ts_bin: no override, no PATH match -> hardcoded fallback paths (or exit 1) ───
if (
  unset HMD_TAILSCALE_BIN
  mkdir -p "$TMPROOT/emptybin"
  # shellcheck disable=SC2123  # intentional: an empty dir as the WHOLE PATH is the condition under test (tailscale not on PATH)
  PATH="$TMPROOT/emptybin"
  export PATH
  out="$(ts_bin 2>/dev/null)"; rc=$?
  if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    [ $rc -eq 0 ] && [ "$out" = "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]
  elif [ -x "/usr/local/bin/tailscale" ]; then
    [ $rc -eq 0 ] && [ "$out" = "/usr/local/bin/tailscale" ]
  else
    [ $rc -eq 1 ]
  fi
); then
  ok "3. ts_bin with no override/PATH match resolves fallback paths or exits 1"
else
  bad "3. ts_bin with no override/PATH match resolves fallback paths or exits 1"
fi

# ── 4. ts_installed: FAKE_TS_MODE=not-installed -> exit 1 (real invocation check) ──
if (
  export FAKE_TS_MODE=not-installed
  ! ts_installed
); then
  ok "4. ts_installed exits 1 when the resolved binary doesn't actually run"
else
  bad "4. ts_installed exits 1 when the resolved binary doesn't actually run"
fi

# ── 5. ts_installed: a working fake -> exit 0 ───────────────────────────────────────
if (
  export FAKE_TS_MODE=online-with-DNSName
  ts_installed
); then
  ok "5. ts_installed exits 0 for a working binary"
else
  bad "5. ts_installed exits 0 for a working binary"
fi

# ── 6. ts_status_json: daemon down -> exit 2 (real observed CLI behaviour) ─────────
if (
  export FAKE_TS_MODE=daemon-down
  ts_status_json >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 2 ]
); then
  ok "6. ts_status_json exits 2 when the daemon isn't running"
else
  bad "6. ts_status_json exits 2 when the daemon isn't running"
fi

# ── 7. ts_status_json: offline -> exit 0, JSON with Online:false ───────────────────
if (
  export FAKE_TS_MODE=offline
  out="$(ts_status_json)"; rc=$?
  [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '"Online":false'
); then
  ok "7. ts_status_json prints JSON when offline but reachable"
else
  bad "7. ts_status_json prints JSON when offline but reachable"
fi

# ── 8. ts_status_json: online -> exit 0, JSON with Online:true ─────────────────────
if (
  export FAKE_TS_MODE=online-with-DNSName
  out="$(ts_status_json)"; rc=$?
  [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '"Online":true'
); then
  ok "8. ts_status_json prints JSON when online"
else
  bad "8. ts_status_json prints JSON when online"
fi

# ── 9. ts_online: offline -> exit 1 ─────────────────────────────────────────────────
if (
  export FAKE_TS_MODE=offline
  ! ts_online
); then
  ok "9. ts_online exits 1 when Self.Online is false"
else
  bad "9. ts_online exits 1 when Self.Online is false"
fi

# ── 10. ts_online: online -> exit 0 ─────────────────────────────────────────────────
if (
  export FAKE_TS_MODE=online-with-DNSName
  ts_online
); then
  ok "10. ts_online exits 0 when Self.Online is true"
else
  bad "10. ts_online exits 0 when Self.Online is true"
fi

# ── 11. ts_dns_name: trailing dot stripped ──────────────────────────────────────────
if (
  export FAKE_TS_MODE=online-with-DNSName
  out="$(ts_dns_name)"
  [ "$out" = "my-machine.tail1a2b3.ts.net" ]
); then
  ok "11. ts_dns_name strips the trailing dot"
else
  bad "11. ts_dns_name strips the trailing dot"
fi

# ── 12. ts_dns_name: empty DNSName -> empty output, exit 0 ─────────────────────────
if (
  export FAKE_TS_MODE=offline
  out="$(ts_dns_name)"; rc=$?
  [ $rc -eq 0 ] && [ "$out" = "" ]
); then
  ok "12. ts_dns_name prints empty string when DNSName is absent"
else
  bad "12. ts_dns_name prints empty string when DNSName is absent"
fi

# ── 13. ts_funnel_supported: modern ─────────────────────────────────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  [ "$(ts_funnel_supported)" = "modern" ]
); then
  ok "13. ts_funnel_supported prints modern"
else
  bad "13. ts_funnel_supported prints modern"
fi

# ── 14. ts_funnel_supported: legacy ─────────────────────────────────────────────────
if (
  export FAKE_TS_MODE=legacy-funnel
  [ "$(ts_funnel_supported)" = "legacy" ]
); then
  ok "14. ts_funnel_supported prints legacy"
else
  bad "14. ts_funnel_supported prints legacy"
fi

# ── 15. ts_funnel_supported: none ───────────────────────────────────────────────────
if (
  export FAKE_TS_MODE=no-funnel
  [ "$(ts_funnel_supported)" = "none" ]
); then
  ok "15. ts_funnel_supported prints none"
else
  bad "15. ts_funnel_supported prints none"
fi

# ── 16. ts_funnel_supported: no binary resolvable -> none ──────────────────────────
if (
  unset HMD_TAILSCALE_BIN
  mkdir -p "$TMPROOT/emptybin2"
  # shellcheck disable=SC2123  # intentional: an empty dir as the WHOLE PATH is the condition under test (tailscale not on PATH)
  PATH="$TMPROOT/emptybin2"
  export PATH
  [ ! -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ] && [ ! -x "/usr/local/bin/tailscale" ] || exit 77
  [ "$(ts_funnel_supported)" = "none" ]
); then
  ok "16. ts_funnel_supported prints none when tailscale isn't resolvable"
elif [ $? -eq 77 ]; then
  ok "16. ts_funnel_supported (skipped: real tailscale fallback path exists on this Mac)"
else
  bad "16. ts_funnel_supported prints none when tailscale isn't resolvable"
fi

# ── 17. ts_funnel_start: bad HTTPS port -> exit 64, no binary invocation needed ────
if (
  export FAKE_TS_MODE=modern-funnel
  ts_funnel_start 3000 9999 >/dev/null 2>/tmp/hmd-ts-17.$$
  rc=$?
  [ "$rc" -eq 64 ] && grep -qi 'port' /tmp/hmd-ts-17.$$
); then
  ok "17. ts_funnel_start exits 64 on an out-of-whitelist HTTPS port (D4)"
else
  bad "17. ts_funnel_start exits 64 on an out-of-whitelist HTTPS port (D4)"
fi
rm -f /tmp/hmd-ts-17.$$ 2>/dev/null || true

# ── 18. ts_funnel_start: modern syntax succeeds ─────────────────────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  ts_funnel_start 3000 443 >/dev/null 2>/dev/null
); then
  ok "18. ts_funnel_start succeeds with modern syntax"
else
  bad "18. ts_funnel_start succeeds with modern syntax"
fi

# ── 19. ts_funnel_start: legacy syntax succeeds ─────────────────────────────────────
if (
  export FAKE_TS_MODE=legacy-funnel
  ts_funnel_start 3000 443 >/dev/null 2>/dev/null
); then
  ok "19. ts_funnel_start succeeds with legacy syntax"
else
  bad "19. ts_funnel_start succeeds with legacy syntax"
fi

# ── 20. ts_funnel_start: funnel unavailable -> nonzero, no crash ──────────────────
if (
  export FAKE_TS_MODE=no-funnel
  ! ts_funnel_start 3000 443 >/dev/null 2>/dev/null
); then
  ok "20. ts_funnel_start fails cleanly when funnel is unavailable"
else
  bad "20. ts_funnel_start fails cleanly when funnel is unavailable"
fi

# ── 21. ts_funnel_start: policy hint is surfaced VERBATIM on stderr, exit 3 (D4) ───
if (
  export FAKE_TS_MODE=policy-hint-on-funnel-start
  ts_funnel_start 3000 443 >/dev/null 2>/tmp/hmd-ts-21.$$
  rc=$?
  [ $rc -eq 3 ] && grep -qF 'funnel: HTTPS is not enabled for your tailnet. To enable HTTPS certificates and Funnel, visit the admin console: https://login.tailscale.com/admin/dns' /tmp/hmd-ts-21.$$
); then
  ok "21. ts_funnel_start exits 3 and prints the tailnet-policy hint verbatim"
else
  bad "21. ts_funnel_start exits 3 and prints the tailnet-policy hint verbatim"
fi
rm -f /tmp/hmd-ts-21.$$ 2>/dev/null || true

# ── 22. fixture sanity: fake's own bad-https-port emulation is defensively real ────
if (
  export FAKE_TS_MODE=bad-https-port
  ! "$FAKE_BIN" funnel 9999 on >/dev/null 2>/dev/null
); then
  ok "22. fake tailscale's bad-https-port mode itself rejects a bad port"
else
  bad "22. fake tailscale's bad-https-port mode itself rejects a bad port"
fi

# ── 23. ts_funnel_stop: bad HTTPS port -> exit 64 ───────────────────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  ts_funnel_stop 9999 >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 64 ]
); then
  ok "23. ts_funnel_stop exits 64 on an out-of-whitelist HTTPS port (D4)"
else
  bad "23. ts_funnel_stop exits 64 on an out-of-whitelist HTTPS port (D4)"
fi

# ── 24. ts_funnel_stop: modern syntax (funnel reset) succeeds ──────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  ts_funnel_stop 443 >/dev/null 2>/dev/null
); then
  ok "24. ts_funnel_stop succeeds with modern syntax"
else
  bad "24. ts_funnel_stop succeeds with modern syntax"
fi

# ── 25. ts_funnel_stop: legacy syntax (funnel PORT off) succeeds ───────────────────
if (
  export FAKE_TS_MODE=legacy-funnel
  ts_funnel_stop 443 >/dev/null 2>/dev/null
); then
  ok "25. ts_funnel_stop succeeds with legacy syntax"
else
  bad "25. ts_funnel_stop succeeds with legacy syntax"
fi

# ── 26. ts_funnel_status_json: funnel supported -> funnel status --json ───────────
if (
  export FAKE_TS_MODE=modern-funnel
  out="$(ts_funnel_status_json)"; rc=$?
  [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'Funnel'
); then
  ok "26. ts_funnel_status_json uses funnel status --json when supported"
else
  bad "26. ts_funnel_status_json uses funnel status --json when supported"
fi

# ── 27. ts_funnel_status_json: no funnel -> falls back to serve status --json ─────
if (
  export FAKE_TS_MODE=no-funnel
  out="$(ts_funnel_status_json)"; rc=$?
  [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'Serve'
); then
  ok "27. ts_funnel_status_json falls back to serve status --json"
else
  bad "27. ts_funnel_status_json falls back to serve status --json"
fi

# ── 28. ts_install_prompt: HMD_ASSUME_NO=1 -> exit 4, never silent ─────────────────
if (
  export HMD_ASSUME_NO=1
  out="$(ts_install_prompt </dev/null 2>&1)"; rc=$?
  [ $rc -eq 4 ] && printf '%s' "$out" | grep -qi 'install'
); then
  ok "28. ts_install_prompt: HMD_ASSUME_NO=1 skips install, exit 4 (D1)"
else
  bad "28. ts_install_prompt: HMD_ASSUME_NO=1 skips install, exit 4 (D1)"
fi

# ── 29. ts_install_prompt: explicit decline via stdin -> exit 4 ────────────────────
if (
  unset HMD_ASSUME_NO
  out="$(printf 'n\n' | ts_install_prompt 2>&1)"; rc=$?
  [ $rc -eq 4 ]
); then
  ok "29. ts_install_prompt: stdin 'n' declines, exit 4"
else
  bad "29. ts_install_prompt: stdin 'n' declines, exit 4"
fi

# ── 30. ts_install_prompt: explicit 'y' actually runs the install command ─────────
if (
  unset HMD_ASSUME_NO
  mkdir -p "$TMPROOT/brewbin"
  MARKER="$TMPROOT/brew-ran"
  rm -f "$MARKER"
  cat > "$TMPROOT/brewbin/brew" <<EOF
#!/usr/bin/env bash
touch "$MARKER"
exit 0
EOF
  chmod +x "$TMPROOT/brewbin/brew"
  PATH="$TMPROOT/brewbin:$PATH"
  export PATH
  out="$(printf 'y\n' | ts_install_prompt 2>&1)"; rc=$?
  [ $rc -eq 0 ] && [ -f "$MARKER" ]
); then
  ok "30. ts_install_prompt: stdin 'y' runs the install command (D1)"
else
  bad "30. ts_install_prompt: stdin 'y' runs the install command (D1)"
fi

# ── 31. ts_install_prompt: no brew -> prompt names the manual download URL ────────
if (
  unset HMD_ASSUME_NO
  PATH="/usr/bin:/bin"
  export PATH
  out="$(printf 'n\n' | ts_install_prompt 2>&1)"
  printf '%s' "$out" | grep -qF 'https://tailscale.com/download/mac'
); then
  ok "31. ts_install_prompt: no brew -> names the macOS download URL"
else
  bad "31. ts_install_prompt: no brew -> names the macOS download URL"
fi

# ── 32. ts_install_prompt: Linux -> prompt names the official install one-liner ───
if (
  unset HMD_ASSUME_NO
  mkdir -p "$TMPROOT/linuxbin"
  cat > "$TMPROOT/linuxbin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
  chmod +x "$TMPROOT/linuxbin/uname"
  PATH="$TMPROOT/linuxbin:$PATH"
  export PATH
  out="$(printf 'n\n' | ts_install_prompt 2>&1)"
  printf '%s' "$out" | grep -qF 'curl -fsSL https://tailscale.com/install.sh | sh'
); then
  ok "32. ts_install_prompt: Linux -> names the official install one-liner"
else
  bad "32. ts_install_prompt: Linux -> names the official install one-liner"
fi

# ── 33. ts_login_hint: offline, AuthURL present -> guidance + URL ─────────────────
if (
  export FAKE_TS_MODE=offline
  out="$(ts_login_hint)"
  printf '%s' "$out" | grep -q 'tailscale up' && printf '%s' "$out" | grep -qF 'https://login.tailscale.com/a/fakeauthtoken123'
); then
  ok "33. ts_login_hint prints tailscale-up guidance and the login URL"
else
  bad "33. ts_login_hint prints tailscale-up guidance and the login URL"
fi

# ── 34. ts_login_hint: no AuthURL -> guidance only, no dangling URL line ──────────
if (
  export FAKE_TS_MODE=online-with-DNSName
  out="$(ts_login_hint)"
  printf '%s' "$out" | grep -q 'tailscale up' && ! printf '%s' "$out" | grep -q 'Login URL:'
); then
  ok "34. ts_login_hint omits the URL line when AuthURL is empty"
else
  bad "34. ts_login_hint omits the URL line when AuthURL is empty"
fi

# ── 35. optional: real tailscale, read-only, never mutates ─────────────────────────
if command -v tailscale >/dev/null 2>&1; then
  if (
    unset HMD_TAILSCALE_BIN FAKE_TS_MODE
    ts_installed || exit 1
    tailscale status --json >/dev/null 2>/dev/null
    rc=$?
    [ $rc -eq 0 ] || [ $rc -eq 1 ]
  ); then
    ok "35. real tailscale on PATH: ts_installed exits 0, status is JSON or unreachable"
  else
    bad "35. real tailscale on PATH: ts_installed exits 0, status is JSON or unreachable"
  fi
else
  ok "35. real tailscale not present on this machine (skipped, not a failure)"
fi

# ── 36. ts_funnel_stop: funnel unavailable -> exit 1, no crash ─────────────────────
# Closes the one asymmetry with ts_funnel_start's case 20: no-funnel is a required
# FAKE_TS_MODE and ts_funnel_stop is a required function, so this pairing belongs in
# "every function x every relevant mode" even though it wasn't in the original batch.
if (
  export FAKE_TS_MODE=no-funnel
  ts_funnel_stop 443 >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 1 ]
); then
  ok "36. ts_funnel_stop fails cleanly when funnel is unavailable"
else
  bad "36. ts_funnel_stop fails cleanly when funnel is unavailable"
fi

# ── 37. bin/lib/hmd_tailscale.sh contains zero eval usage (A11 security audit) ────
if [ "$(grep -c '\beval\b' "$LIB")" -eq 0 ]; then
  ok "37. hmd_tailscale.sh has zero eval usage (A11)"
else
  bad "37. hmd_tailscale.sh has zero eval usage (A11)"
fi

# ── 38. ts_install_prompt: consent path hands brew a fixed 3-word argv -- no eval,
#         no string re-interpretation (A11 security audit) ───────────────────────
if (
  unset HMD_ASSUME_NO
  mkdir -p "$TMPROOT/brewbin38"
  ARGV_LOG="$TMPROOT/brew-argv.log"
  rm -f "$ARGV_LOG"
  cat > "$TMPROOT/brewbin38/brew" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV_LOG"
exit 0
EOF
  chmod +x "$TMPROOT/brewbin38/brew"
  PATH="$TMPROOT/brewbin38:$PATH"
  export PATH
  out="$(printf 'y\n' | ts_install_prompt 2>&1)"; rc=$?
  [ $rc -eq 0 ] && [ "$(cat "$ARGV_LOG")" = "$(printf 'install\n--cask\ntailscale')" ]
); then
  ok "38. ts_install_prompt: consent path passes brew an exact argv (A11)"
else
  bad "38. ts_install_prompt: consent path passes brew an exact argv (A11)"
fi

# ── 39. ts_funnel_stop: a foreign Funnel target -> exit 7, warning names it, never
#         calls reset (A13 / D6) ──────────────────────────────────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  export FAKE_FUNNEL_STATUS_JSON='{"Web":{"host.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:5000"}}}},"TCP":{}}'
  CALL_LOG="$TMPROOT/calls-39.log"
  rm -f "$CALL_LOG"
  export FAKE_CALL_LOG="$CALL_LOG"
  unset HMD_FUNNEL_FORCE_RESET
  out="$(ts_funnel_stop 443 3000 2>&1)"; rc=$?
  [ "$rc" -eq 7 ] \
    && printf '%s' "$out" | grep -qF 'http://127.0.0.1:5000' \
    && ! grep -q 'funnel reset' "$CALL_LOG"
); then
  ok "39. ts_funnel_stop: foreign target -> exit 7, warns, never resets (A13/D6)"
else
  bad "39. ts_funnel_stop: foreign target -> exit 7, warns, never resets (A13/D6)"
fi

# ── 40. ts_funnel_stop: only hmd's own target configured -> succeeds via reset
#         (A13 / D6 happy path) ───────────────────────────────────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  export FAKE_FUNNEL_STATUS_JSON='{"Web":{"host.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}},"TCP":{}}'
  CALL_LOG="$TMPROOT/calls-40.log"
  rm -f "$CALL_LOG"
  export FAKE_CALL_LOG="$CALL_LOG"
  unset HMD_FUNNEL_FORCE_RESET
  ts_funnel_stop 443 3000 >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'funnel reset' "$CALL_LOG"
); then
  ok "40. ts_funnel_stop: only hmd's own target -> succeeds, resets (A13/D6)"
else
  bad "40. ts_funnel_stop: only hmd's own target -> succeeds, resets (A13/D6)"
fi

# ── 41. ts_funnel_stop: HMD_FUNNEL_FORCE_RESET=1 resets despite a foreign target
#         (A13 / D6 force override) ───────────────────────────────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  export FAKE_FUNNEL_STATUS_JSON='{"Web":{"host.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:5000"}}}},"TCP":{}}'
  CALL_LOG="$TMPROOT/calls-41.log"
  rm -f "$CALL_LOG"
  export FAKE_CALL_LOG="$CALL_LOG"
  export HMD_FUNNEL_FORCE_RESET=1
  ts_funnel_stop 443 3000 >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && grep -q 'funnel reset' "$CALL_LOG"
); then
  ok "41. ts_funnel_stop: HMD_FUNNEL_FORCE_RESET=1 overrides, resets anyway (A13/D6)"
else
  bad "41. ts_funnel_stop: HMD_FUNNEL_FORCE_RESET=1 overrides, resets anyway (A13/D6)"
fi

# ── 42. ts_funnel_stop: CLI advertises a scoped off -> uses --https=PORT off
#         instead of reset, even with a foreign target present (A13 / D6 scoped) ──
if (
  export FAKE_TS_MODE=modern-funnel-scoped-off
  export FAKE_FUNNEL_STATUS_JSON='{"Web":{"host.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:5000"}}}},"TCP":{}}'
  CALL_LOG="$TMPROOT/calls-42.log"
  rm -f "$CALL_LOG"
  export FAKE_CALL_LOG="$CALL_LOG"
  unset HMD_FUNNEL_FORCE_RESET
  ts_funnel_stop 443 3000 >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] \
    && grep -q -- '--https=443 off' "$CALL_LOG" \
    && ! grep -q 'funnel reset' "$CALL_LOG"
); then
  ok "42. ts_funnel_stop: scoped CLI support -> --https=PORT off, never reset (A13/D6)"
else
  bad "42. ts_funnel_stop: scoped CLI support -> --https=PORT off, never reset (A13/D6)"
fi

# ── 43. ts_funnel_stop: one-arg form treats PORT as unknown -> conservative refusal
#         when anything at all is configured (A13 / D6 back-compat mode) ─────────
if (
  export FAKE_TS_MODE=modern-funnel
  export FAKE_FUNNEL_STATUS_JSON='{"Web":{"host.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}},"TCP":{}}'
  CALL_LOG="$TMPROOT/calls-43.log"
  rm -f "$CALL_LOG"
  export FAKE_CALL_LOG="$CALL_LOG"
  unset HMD_FUNNEL_FORCE_RESET
  ts_funnel_stop 443 >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 7 ] && ! grep -q 'funnel reset' "$CALL_LOG"
); then
  ok "43. ts_funnel_stop: one-arg form is conservative when anything is configured (A13/D6)"
else
  bad "43. ts_funnel_stop: one-arg form is conservative when anything is configured (A13/D6)"
fi

# ── 44. ts_variant: Homebrew static path match -> oss ──────────────────────────────
if (
  export HMD_TAILSCALE_BIN=/opt/homebrew/bin/tailscale
  [ "$(ts_variant)" = "oss" ]
); then
  ok "44. ts_variant: Homebrew path -> oss"
else
  bad "44. ts_variant: Homebrew path -> oss"
fi

# ── 45. ts_variant: Linux system path match -> oss ─────────────────────────────────
if (
  export HMD_TAILSCALE_BIN=/usr/bin/tailscale
  [ "$(ts_variant)" = "oss" ]
); then
  ok "45. ts_variant: Linux system path (/usr/bin) -> oss"
else
  bad "45. ts_variant: Linux system path (/usr/bin) -> oss"
fi

# ── 46. ts_variant: HMD_TAILSCALE_APP_PLIST seam, macsys bundle id -> macsys ───────
if (
  PLIST="$TMPROOT/variant-46.plist"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macsys</string>
</dict>
</plist>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  [ "$(ts_variant)" = "macsys" ]
); then
  ok "46. ts_variant: app-plist seam with macsys bundle id -> macsys"
else
  bad "46. ts_variant: app-plist seam with macsys bundle id -> macsys"
fi

# ── 47. ts_variant: HMD_TAILSCALE_APP_PLIST seam, appstore bundle id -> appstore ───
if (
  PLIST="$TMPROOT/variant-47.plist"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macos</string>
</dict>
</plist>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  [ "$(ts_variant)" = "appstore" ]
); then
  ok "47. ts_variant: app-plist seam with appstore bundle id -> appstore"
else
  bad "47. ts_variant: app-plist seam with appstore bundle id -> appstore"
fi

# ── 48. ts_variant: malformed/bare plist -> grep/sed scrape fallback still recovers
#         the bundle id (defaults read and PlistBuddy both reject this shape) ─────
if (
  PLIST="$TMPROOT/variant-48.plist"
  cat > "$PLIST" <<'EOF'
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macsys</string>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  [ "$(ts_variant)" = "macsys" ]
); then
  ok "48. ts_variant: malformed plist recovered via text-scrape fallback"
else
  bad "48. ts_variant: malformed plist recovered via text-scrape fallback"
fi

# ── 49. ts_variant: app-plist seam set, but bundle id matches neither known Tailscale
#         id -> falls through past tier 1 to unknown, no false positive ──────────
if (
  PLIST="$TMPROOT/variant-49.plist"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.example.other</string>
</dict>
</plist>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  [ "$(ts_variant)" = "unknown" ]
); then
  ok "49. ts_variant: unrecognized bundle id under the plist seam -> unknown"
else
  bad "49. ts_variant: unrecognized bundle id under the plist seam -> unknown"
fi

# ── 50. ts_funnel_supported: macsys -> none even though --help advertises modern
#         flags (D7 -- variant check runs before the --help sniff) ────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  PLIST="$TMPROOT/fs-50.plist"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macsys</string>
</dict>
</plist>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  [ "$(ts_funnel_supported 2>/dev/null)" = "none" ]
); then
  ok "50. ts_funnel_supported: macsys -> none despite modern --help (D7)"
else
  bad "50. ts_funnel_supported: macsys -> none despite modern --help (D7)"
fi

# ── 51. ts_funnel_supported: macsys prints the brew-install hint on stderr ─────────
if (
  export FAKE_TS_MODE=modern-funnel
  PLIST="$TMPROOT/fs-51.plist"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macsys</string>
</dict>
</plist>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  out="$(ts_funnel_supported 2>&1 1>/dev/null)"
  printf '%s' "$out" | grep -qF 'brew install tailscale'
); then
  ok "51. ts_funnel_supported: macsys prints the brew-install hint on stderr (D7)"
else
  bad "51. ts_funnel_supported: macsys prints the brew-install hint on stderr (D7)"
fi

# ── 52. ts_funnel_supported: appstore -> none even though --help advertises modern
#         flags (D7) ───────────────────────────────────────────────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  PLIST="$TMPROOT/fs-52.plist"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macos</string>
</dict>
</plist>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  [ "$(ts_funnel_supported 2>/dev/null)" = "none" ]
); then
  ok "52. ts_funnel_supported: appstore -> none despite modern --help (D7)"
else
  bad "52. ts_funnel_supported: appstore -> none despite modern --help (D7)"
fi

# ── 53. ts_funnel_start: macsys -> exit 9, brew hint on stderr, CLI never invoked ──
if (
  export FAKE_TS_MODE=modern-funnel
  PLIST="$TMPROOT/start-53.plist"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macsys</string>
</dict>
</plist>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  CALL_LOG="$TMPROOT/calls-53.log"
  rm -f "$CALL_LOG"
  export FAKE_CALL_LOG="$CALL_LOG"
  out="$(ts_funnel_start 3000 443 2>&1)"; rc=$?
  [ "$rc" -eq 9 ] \
    && printf '%s' "$out" | grep -qF 'brew install tailscale' \
    && [ ! -s "$CALL_LOG" ]
); then
  ok "53. ts_funnel_start: macsys -> exit 9, brew hint, never invokes the CLI (D7)"
else
  bad "53. ts_funnel_start: macsys -> exit 9, brew hint, never invokes the CLI (D7)"
fi

# ── 54. ts_funnel_start: appstore -> exit 9 ─────────────────────────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  PLIST="$TMPROOT/start-54.plist"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macos</string>
</dict>
</plist>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  ts_funnel_start 3000 443 >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 9 ]
); then
  ok "54. ts_funnel_start: appstore -> exit 9 (D7)"
else
  bad "54. ts_funnel_start: appstore -> exit 9 (D7)"
fi

# ── 55. ts_funnel_start: bad HTTPS port still wins (exit 64) even on macsys --
#         port validation happens before the D7 guard ─────────────────────────────
if (
  export FAKE_TS_MODE=modern-funnel
  PLIST="$TMPROOT/start-55.plist"
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.tailscale.ipn.macsys</string>
</dict>
</plist>
EOF
  export HMD_TAILSCALE_APP_PLIST="$PLIST"
  ts_funnel_start 3000 9999 >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" -eq 64 ]
); then
  ok "55. ts_funnel_start: bad HTTPS port -> exit 64 even on macsys (checked before D7)"
else
  bad "55. ts_funnel_start: bad HTTPS port -> exit 64 even on macsys (checked before D7)"
fi

# ── 56. oss path unchanged: a genuinely oss-classified binary (brew --prefix match)
#         still gets "modern" from ts_funnel_supported -- D7 doesn't touch this path ─
if (
  export FAKE_TS_MODE=modern-funnel
  unset HMD_TAILSCALE_APP_PLIST
  mkdir -p "$TMPROOT/fakebrewbin56"
  cat > "$TMPROOT/fakebrewbin56/brew" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--prefix" ]; then
  cd "$TMPROOT" && pwd -P
  exit 0
fi
exit 1
EOF
  chmod +x "$TMPROOT/fakebrewbin56/brew"
  PATH="$TMPROOT/fakebrewbin56:$PATH"
  export PATH
  [ "$(ts_variant)" = "oss" ] && [ "$(ts_funnel_supported)" = "modern" ]
); then
  ok "56. oss path unchanged: brew-prefix-matched binary -> oss, funnel_supported still modern"
else
  bad "56. oss path unchanged: brew-prefix-matched binary -> oss, funnel_supported still modern"
fi

# ── 57. ts_funnel_start: funnel-approval-url -- CLI prints the tailnet-approval
#         URL to STDOUT then blocks; HMD_FUNNEL_APPROVE_WAIT_S bounds the wait
#         and the URL is surfaced verbatim on stderr (D8 / hmdapp handoff #2) ──
if (
  export FAKE_TS_MODE=funnel-approval-url
  export HMD_FUNNEL_APPROVE_WAIT_S=2
  start_ts=$(date +%s)
  ts_funnel_start 3000 443 >/dev/null 2>/tmp/hmd-ts-57.$$
  rc=$?
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  [ "$rc" -eq 3 ] \
    && [ "$elapsed" -le 4 ] \
    && grep -qF 'https://login.tailscale.com/f/funnel?node=' /tmp/hmd-ts-57.$$
); then
  ok "57. ts_funnel_start: funnel-approval-url -> exit 3 within the wait window, URL surfaced verbatim (D8)"
else
  bad "57. ts_funnel_start: funnel-approval-url -> exit 3 within the wait window, URL surfaced verbatim (D8)"
fi
rm -f /tmp/hmd-ts-57.$$ 2>/dev/null || true

# ── 58. ts_funnel_start: funnel-approval-then-ok -- URL seen, CLI then exits 0
#         inside the window -> success, but the URL was still surfaced (D8) ───
if (
  export FAKE_TS_MODE=funnel-approval-then-ok
  export HMD_FUNNEL_APPROVE_WAIT_S=5
  ts_funnel_start 3000 443 >/dev/null 2>/tmp/hmd-ts-58.$$
  rc=$?
  [ "$rc" -eq 0 ] && grep -qF 'https://login.tailscale.com/f/funnel?node=' /tmp/hmd-ts-58.$$
); then
  ok "58. ts_funnel_start: funnel-approval-then-ok -> exit 0, URL still surfaced (D8)"
else
  bad "58. ts_funnel_start: funnel-approval-then-ok -> exit 0, URL still surfaced (D8)"
fi
rm -f /tmp/hmd-ts-58.$$ 2>/dev/null || true

# ── 59. ts_funnel_start: no leftover temp files across success, failure, and
#         approval-wait paths -- the combined stdout+stderr capture file is
#         always rm'd, even when the backgrounded CLI is still running when
#         the wait window elapses (D8) ─────────────────────────────────────
if (
  TMPDIR="$TMPROOT/tmpdir-59"
  mkdir -p "$TMPDIR"
  export TMPDIR
  before="$(ls -A "$TMPDIR")"

  export FAKE_TS_MODE=modern-funnel
  ts_funnel_start 3000 443 >/dev/null 2>/dev/null

  export FAKE_TS_MODE=policy-hint-on-funnel-start
  ts_funnel_start 3000 443 >/dev/null 2>/dev/null

  export FAKE_TS_MODE=funnel-approval-url
  export HMD_FUNNEL_APPROVE_WAIT_S=1
  ts_funnel_start 3000 443 >/dev/null 2>/dev/null

  export FAKE_TS_MODE=funnel-approval-then-ok
  export HMD_FUNNEL_APPROVE_WAIT_S=5
  ts_funnel_start 3000 443 >/dev/null 2>/dev/null
  unset HMD_FUNNEL_APPROVE_WAIT_S

  after="$(ls -A "$TMPDIR")"
  [ "$before" = "$after" ]
); then
  ok "59. ts_funnel_start: no leftover temp files across success/failure/approval-wait paths (D8)"
else
  bad "59. ts_funnel_start: no leftover temp files across success/failure/approval-wait paths (D8)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

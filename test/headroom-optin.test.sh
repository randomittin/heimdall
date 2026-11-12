#!/usr/bin/env bash
#
# headroom-optin.test.sh — acceptance for "Headroom is OFF by default and used only on demand":
# modules/headroom/manifest.json (default_included false) and bin/heimdall-headroom (hmd headroom status|on|off).
#
# budget: 35s — measured 31s with a full sweep running on the same machine. About 35 CLI runs (each probes curl, lsof and ps, and
#         the settings check starts python), two updater dry-runs, and the waits for a python stand-in for the proxy to start and stop.
#
# OPERATOR DIRECTIVE 2026-11-12: a new install must be much lighter, and the current instance should drop Headroom
# until it is needed. `off` must never leave anyone without a working route, so the dangerous half of it (stopping the
# proxy, or removing what points a session at it) is what most of this file pins.
#
# NOTHING REAL IS TOUCHED. HOME, CLAUDE_CONFIG_DIR, HEIMDALL_HOME, the modules state root and the LaunchAgents dir are
# all under one mktemp -d. launchctl is a RECORDER (LAUNCHCTL=...), the proxy is a python http.server answering just
# enough of Headroom's /livez and /health on a free loopback port, `ps` is a PATH shim for the one environment-listing
# call, and `heimdall-modules add` (a PyPI fetch plus live control-plane invariants) is a test double. optout and optin
# run for REAL: they are what the chain, `hmd route` and `hmd wrap` read to decline Headroom.
#
# Sections:
#   A  a fresh install: not in the default set, never acquired, no launchd job, no base URL
#   B  status, and on (idempotent)
#   C  off refuses inside a session routed through the proxy, and changes nothing
#   D  off --next-session: config only, backed up, no tty, the proxy and the running session untouched
#   E  idempotent: a second run changes nothing and exits 0; --backup-dir and HMD_HEADROOM_BACKUP_DIR
#   F  off from an unrouted shell: stops what is safe to stop, and never a session's route
#   G  on after off; an env opt-out; a failed add
#   H  a synthetic HOME never reaches the real launchctl
#   I  no usable python3: an unchecked settings file is reported and keeps the proxy running
#   X  falsifiers: four mutants of the script, each must break the case that guards it

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HR="$ROOT/bin/heimdall-headroom"
MODS="$ROOT/bin/heimdall-modules"
MANIFEST="$ROOT/modules/headroom/manifest.json"

for t in python3 jq curl perl; do command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }; done

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); return 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/headroom-optin.XXXXXX")"
PIDS=""
cleanup() { local p; for p in $PIDS; do kill "$p" >/dev/null 2>&1; done; rm -rf "$TMP"; return 0; }
trap cleanup EXIT

HOME_T="$TMP/home"; CFG="$HOME_T/.claude"; HHOME="$HOME_T/.heimdall"
LA="$TMP/la"; STATE="$TMP/modstate"; SHIMS="$TMP/shims"
mkdir -p "$HOME_T" "$CFG" "$LA" "$STATE" "$SHIMS"
LABEL="dev.runheimdall.headroom.test"; PLIST="$LA/$LABEL.plist"; UIDN="$(id -u)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
OURS="http://127.0.0.1:$PORT"
BKROOT="$HHOME/headroom/off-backup"

# ── the stand-ins ─────────────────────────────────────────────────────────────────────────────────
CALLS="$TMP/lc.calls"; LOADED="$TMP/lc.loaded"; DISABLED="$TMP/lc.disabled"; : > "$CALLS"
LC="$TMP/launchctl-recorder"
cat > "$LC" <<'EOSH'
#!/usr/bin/env bash
echo "$*" >> "${LC_CALLS:?}"
case "$1" in
  print)          [ -f "${LC_LOADED:?}" ] || exit 1
                  printf '%s = {\n\tstate = running\n\tpid = 4242\n\tlast exit code = (never exited)\n}\n' "$2" ;;
  print-disabled) printf 'disabled services = {\n'
                  if [ -f "${LC_DISABLED:?}" ]; then printf '\t"%s" => disabled\n' "$LC_LABEL"; else printf '\t"%s" => enabled\n' "$LC_LABEL"; fi
                  printf '}\n' ;;
  bootstrap)      : > "$LC_LOADED" ;;
  bootout)        rm -f "$LC_LOADED" ;;
  disable)        : > "$LC_DISABLED" ;;
  enable)         rm -f "$LC_DISABLED" ;;
esac
exit 0
EOSH
chmod +x "$LC"

# Headroom's /livez and /health, just enough for the chain's own probes: service, upstream, and the pid it reports.
cat > "$TMP/headroom-fake-proxy.py" <<'EOPY'
import http.server, json, os, sys
port = int(sys.argv[sys.argv.index("--port") + 1])
report_pid = int(os.environ.get("FAKE_PROXY_REPORT_PID") or os.getpid())
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/livez":
            body = b"ok"
        elif self.path == "/health":
            body = json.dumps({"service": "headroom-proxy", "status": "healthy",
                               "checks": {"upstream": {"url": "https://api.anthropic.com"}},
                               "config": {"pid": report_pid}}).encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
EOPY

# heimdall-modules, except `add`, which would fetch from PyPI and run the live invariants.
MODW="$TMP/modules-wrap"
cat > "$MODW" <<EOSH
#!/usr/bin/env bash
echo "\$*" >> "$TMP/modules.calls"
if [ "\$1" = add ]; then
  [ "\${FAKE_ADD_RC:-0}" = 0 ] || { echo "  ABSENT: the test double refused" >&2; exit "\$FAKE_ADD_RC"; }
  mkdir -p "\$HMD_MODULES_STATE/\$2" && printf '{}\n' > "\$HMD_MODULES_STATE/\$2/receipt.json"
  echo "  Installed \"\$2\" (test double: no fetch, no invariants)"
  exit 0
fi
exec "$MODS" "\$@"
EOSH
chmod +x "$MODW"

# `ps axeww` (every process with its environment) from a fixture; every other ps call is the real one.
cat > "$SHIMS/ps" <<'EOSH'
#!/usr/bin/env bash
if [ "${1:-}" = axeww ]; then cat "${PS_FIXTURE:-/dev/null}"; exit 0; fi
for p in /bin/ps /usr/bin/ps; do [ -x "$p" ] && exec "$p" "$@"; done
exit 127
EOSH
chmod +x "$SHIMS/ps"
PSFIX="$TMP/ps.fixture"; : > "$PSFIX"

# sbx [VAR=val ...] cmd... — the sandbox environment around any command. ANTHROPIC_BASE_URL is unset unless a case sets it.
sbx() {
  env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u HMD_HEADROOM_DISABLE -u HMD_MODULE_OPTOUT -u HEADROOM_LOSSLESS \
      -u HMD_HEADROOM_BACKUP_DIR -u FAKE_ADD_RC -u HMD_PYTHON \
      HOME="$HOME_T" CLAUDE_CONFIG_DIR="$CFG" HEIMDALL_HOME="$HHOME" HEIMDALL_LAUNCH_AGENTS_DIR="$LA" LAUNCHCTL="$LC" \
      HMD_MODULES_STATE="$STATE" HMD_MODULES_BIN="$MODW" HEADROOM_PORT="$PORT" HMD_HEADROOM_SUPERVISOR_LABEL="$LABEL" \
      HMD_HEADROOM_STOP_POLLS=20 PS_FIXTURE="$PSFIX" PATH="$SHIMS:$PATH" \
      LC_CALLS="$CALLS" LC_LOADED="$LOADED" LC_DISABLED="$DISABLED" LC_LABEL="$LABEL" "$@"
}
# Non-tty by construction (stdin is /dev/null, stdout is captured) and under an alarm, so a prompt can never hang the suite.
hr()        { sbx perl -e 'alarm 30; exec @ARGV or exit 127' -- "$HR" "$@" </dev/null; }
hr_routed() { sbx ANTHROPIC_BASE_URL="$OURS" perl -e 'alarm 30; exec @ARGV or exit 127' -- "$HR" "$@" </dev/null; }

proxy_up() { curl -s -o /dev/null --connect-timeout 0.3 --max-time 1 "http://127.0.0.1:$PORT/livez"; }
PROXY_PID=""
start_proxy() {   # start_proxy [VAR=val ...] — a Headroom stand-in on $PORT; sets PROXY_PID
  env "$@" python3 "$TMP/headroom-fake-proxy.py" proxy --host 127.0.0.1 --port "$PORT" --lossless >/dev/null 2>&1 &
  PROXY_PID=$!; PIDS="$PIDS $PROXY_PID"; disown "$PROXY_PID" 2>/dev/null   # disowned: the shell never prints "Terminated" when the CLI (or cleanup) kills it
  local i=0
  while [ "$i" -lt 100 ]; do proxy_up && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
reap() { local i=0; kill "$1" >/dev/null 2>&1; while [ "$i" -lt 30 ] && kill -0 "$1" 2>/dev/null; do sleep 0.1; i=$((i+1)); done; return 0; }
stop_proxy() { [ -n "$PROXY_PID" ] && reap "$PROXY_PID"; PROXY_PID=""; return 0; }
mutating_calls() { grep -cE '^(bootout|bootstrap|disable|enable|kickstart|kill)' "$CALLS" 2>/dev/null || true; }
mode_of() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }
newest_backup() { ls -d "$BKROOT"/*/ 2>/dev/null | tail -1; }
backup_count() { ls -d "$BKROOT"/*/ 2>/dev/null | wc -l | tr -d ' '; }
opted_out_rec() { [ -f "$STATE/.modstate/headroom/optout.json" ]; }
# What `hmd route`, `hmd wrap` and the wrap shim all ask before routing: the chain's own predicate and report, run for real.
chain_opted_out() { ( . "$ROOT/bin/lib/hmd-headroom-chain.sh"; HMD_MODULES_STATE="$STATE" hmd_headroom_opted_out "$ROOT" ); }
chain_report()    { ( . "$ROOT/bin/lib/hmd-headroom-chain.sh"; HMD_MODULES_STATE="$STATE" HEADROOM_PORT="$PORT" hmd_headroom_report "$ROOT" ); }

write_settings() {   # write_settings <1 = another env key sits beside the mount | 0 = the mount is the only env key>
  jq -n --arg url "$OURS" --argjson other "$1" \
    '{model:"opus", env:({ANTHROPIC_BASE_URL:$url} + (if $other == 1 then {FOO:"bar"} else {} end)),
      hooks:{SessionStart:[{hooks:[{type:"command", command:"echo hi"}]}]}}' > "$CFG/settings.json"
  chmod 600 "$CFG/settings.json"
}
# The OmniRoute loopback URL: not Headroom's, so it is never ours to touch.
write_local_settings() { jq -n '{env:{ANTHROPIC_BASE_URL:"http://127.0.0.1:20128"}}' > "$CFG/settings.local.json"; }
write_rc() {
  cat > "$HOME_T/.zshrc" <<'EORC'
export PATH="$HOME/.local/bin:$PATH"
# ── hmd: route every Claude Code session through the Headroom compression proxy ──
claude() {
  if command -v hmd >/dev/null 2>&1; then
    command hmd route claude "$@"
  else
    command claude "$@"
  fi
}
EORC
}
write_plist() { printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>Label</key><string>%s</string></dict></plist>\n' "$LABEL" > "$PLIST"; }
write_ps_pinned() {
  {
    printf '4242424 claude --agent heimdall --plugin-dir /x ANTHROPIC_BASE_URL=%s PATH=/usr/bin HOME=/h\n' "$OURS"
    printf '7770001 /opt/homebrew/Cellar/postgresql@15/15.17/bin/postgres ANTHROPIC_BASE_URL=%s PATH=/usr/bin\n' "$OURS"
    printf '7770002 claude --agent other ANTHROPIC_BASE_URL=http://127.0.0.1:20128 PATH=/usr/bin\n'
  } > "$PSFIX"
}
reset_world() {   # a routed-session world with something to switch off: module on, plist loaded, settings mount, proxy up
  stop_proxy; rm -rf "$STATE/.modstate" "$BKROOT"; : > "$CALLS"; : > "$PSFIX"; rm -f "$DISABLED"
  hr on >/dev/null 2>&1; write_plist; : > "$LOADED"; write_settings 1; write_local_settings; start_proxy
}

echo
echo "0 — the script parses, and the dispatcher and the runhmd list know the subcommand"
if [ -f "$HR" ] && bash -n "$HR" 2>/dev/null; then ok "0a bin/heimdall-headroom exists and parses (bash -n)"; else bad "0a bin/heimdall-headroom is missing or has a syntax error"; fi
if grep -qE '^  headroom\)' "$ROOT/bin/heimdall" && grep -q 'bin/heimdall-headroom' "$ROOT/bin/heimdall"; then ok "0b bin/heimdall has a headroom) arm that execs bin/heimdall-headroom"; else bad "0b no headroom) arm in bin/heimdall: \`hmd headroom\` would start a Claude run with \"headroom\" as the task"; fi
if grep -qx 'headroom' "$ROOT/packages/runhmd/subcommands.txt"; then ok "0c packages/runhmd/subcommands.txt lists headroom (else runhmd turns it into hmd attack headroom)"; else bad "0c headroom is not in packages/runhmd/subcommands.txt"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "A — a fresh install: Headroom is not in the default set, is never acquired, and nothing mounts it"
if jq -e '.default_included == false' "$MANIFEST" >/dev/null 2>&1; then ok "A1 modules/headroom/manifest.json: default_included is false"; else bad "A1 default_included is not false" "$(jq -c '.default_included' "$MANIFEST")"; fi
AH="$TMP/ahome"; AS="$TMP/astate"; mkdir -p "$AH" "$AS"
reconcile_log() {   # reconcile_log <registry> <home> — the updater's DECISION on a fresh machine, never an install
  env -u HEIMDALL_NO_MODULES -u HMD_MODULES_BIN HOME="$2" HEIMDALL_HOME="$2" HMD_MODULES_REGISTRY="$1" HMD_MODULES_STATE="$AS" \
      HEIMDALL_LATEST_OVERRIDE=9.9.9 HEIMDALL_INSTALLED_OVERRIDE=9.9.9 HEIMDALL_AUTOUPDATE_DRYRUN=1 HEIMDALL_MODULE_RECONCILE_DRYRUN=1 \
      "$ROOT/bin/heimdall-autoupdate" update >/dev/null 2>&1
}
reconcile_log "$ROOT/modules" "$AH"
if ! grep -q 'reconcile: headroom' "$AH/autoupdate.log" 2>/dev/null; then ok "A2 the updater makes NO decision about headroom on a fresh machine: it never acquires it"; else bad "A2 the updater still selects headroom" "$(grep 'reconcile: headroom' "$AH/autoupdate.log")"; fi
# FALSIFIER FOR A2: the very same manifest with default_included flipped back DOES produce a decision, so the grep above can see one.
REGD="$TMP/reg-default"; mkdir -p "$REGD/_classes" "$REGD/headroom"
cp "$ROOT"/modules/_classes/*.json "$REGD/_classes/"; jq '.default_included = true' "$MANIFEST" > "$REGD/headroom/manifest.json"
AH2="$TMP/ahome2"; mkdir -p "$AH2"; reconcile_log "$REGD" "$AH2"
if grep -q 'reconcile: headroom would-acquire' "$AH2/autoupdate.log" 2>/dev/null; then ok "A3 RED ARM: default_included true makes the same updater select headroom, so A2 can go RED"; else bad "A3 flipping default_included did not change the updater's decision: A2 may be vacuous" "$(cat "$AH2/autoupdate.log" 2>/dev/null)"; fi
OUT="$(hr status 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q '^headroom: OFF' <<<"$OUT" && grep -q 'not added' <<<"$OUT"; then ok "A4 status on a fresh install: OFF, module not added"; else bad "A4 fresh status" "rc=$RC $OUT"; fi
if [ -z "$(ls -A "$LA")" ] && [ ! -e "$CFG/settings.json" ] && [ ! -s "$CALLS" ] && [ ! -e "$STATE/headroom" ]; then ok "A5 nothing exists: no launchd job, no settings.json env, no launchctl call, no module receipt"; else bad "A5 a fresh install left something behind" "$(ls -A "$LA") $(cat "$CALLS")"; fi
OUT="$(hr off 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'already off' <<<"$OUT" && [ ! -d "$BKROOT" ] && [ ! -e "$STATE/.modstate" ] && [ ! -s "$CALLS" ]; then ok "A6 off on a fresh install: exit 0, already off, no opt-out record, no backup, no launchctl call"; else bad "A6 off on a fresh install" "rc=$RC $OUT"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "B — on: enable explicitly, and say what is (not) routed"
OUT="$(hr on 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q '^add headroom' "$TMP/modules.calls" && [ -f "$STATE/headroom/receipt.json" ]; then ok "B1 on runs hmd modules add headroom (the module is registered)"; else bad "B1 on did not add the module" "rc=$RC $OUT"; fi
if grep -q 'hmd route claude' <<<"$OUT" && grep -qi 'nothing is routed yet' <<<"$OUT"; then ok "B2 on says nothing is routed yet and how a launch gets routed"; else bad "B2 on's message" "$OUT"; fi
: > "$TMP/modules.calls"
OUT="$(hr on 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'already on' <<<"$OUT" && ! grep -q '^add' "$TMP/modules.calls"; then ok "B3 a second on is a no-op: exit 0, no second add"; else bad "B3 on is not idempotent" "rc=$RC $OUT"; fi
ST="$(hr status 2>&1)"   # captured, never piped into grep -q: under pipefail a SIGPIPE from the early exit would flip the status
if grep -q '^headroom: ON' <<<"$ST"; then ok "B4 status reads ON"; else bad "B4 status after on" "$ST"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "C — off refuses inside a session routed through the proxy, and changes NOTHING"
write_plist; : > "$LOADED"; write_settings 1; write_local_settings; write_rc
cp "$CFG/settings.json" "$TMP/settings.orig"; cp "$CFG/settings.local.json" "$TMP/settings.local.orig"; cp "$HOME_T/.zshrc" "$TMP/zshrc.orig"
start_proxy || bad "C0 the stand-in proxy did not come up"
: > "$CALLS"
OUT="$(hr_routed off 2>&1)"; RC=$?
if [ "$RC" = 3 ]; then ok "C1 exit 3 (refused) when this session is routed through the proxy"; else bad "C1 expected exit 3" "rc=$RC $OUT"; fi
if grep -q -- '--next-session' <<<"$OUT" && grep -q "$OURS" <<<"$OUT"; then ok "C2 the refusal names the URL and offers --next-session"; else bad "C2 refusal message" "$OUT"; fi
if ! opted_out_rec && cmp -s "$CFG/settings.json" "$TMP/settings.orig" && [ "$(mutating_calls)" = 0 ] && proxy_up && [ ! -d "$BKROOT" ] && [ -f "$PLIST" ]; then
  ok "C3 nothing changed: no opt-out, settings.json byte-identical, no launchctl verb, proxy alive, plist kept, no backup"
else bad "C3 a refused off changed something" "optout=$(opted_out_rec && echo yes) calls=$(cat "$CALLS")"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "D — off --next-session: config only, backed up, no tty; the proxy and the running session keep working"
: > "$CALLS"
OUT="$(hr_routed off --next-session 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "D1 exit 0 in a routed session, with no tty and no prompt"; else bad "D1 exit" "rc=$RC $OUT"; fi
if opted_out_rec && chain_opted_out && chain_report | grep -q 'opted out'; then ok "D2 the module is opted out: the chain's own predicate and report now say so, so route/wrap/shim all decline"; else bad "D2 opt-out not in effect" "$(chain_report)"; fi
if jq -e 'has("env") and (.env | has("ANTHROPIC_BASE_URL") | not) and .env.FOO == "bar"' "$CFG/settings.json" >/dev/null 2>&1 \
   && jq -e --slurpfile o "$TMP/settings.orig" '. == ($o[0] | del(.env.ANTHROPIC_BASE_URL))' "$CFG/settings.json" >/dev/null 2>&1; then
  ok "D3 the mount is gone from settings.json env and every other key is untouched"
else bad "D3 settings.json rewrite" "$(cat "$CFG/settings.json")"; fi
if [ "$(mode_of "$CFG/settings.json")" = 0o600 ]; then ok "D4 settings.json keeps its 0600 mode"; else bad "D4 mode" "$(mode_of "$CFG/settings.json")"; fi
if cmp -s "$CFG/settings.local.json" "$TMP/settings.local.orig"; then ok "D5 a base URL that is NOT the proxy's (OmniRoute :20128) is byte-identical: never ours to touch"; else bad "D5 a foreign mount was changed"; fi
BK="$(newest_backup)"
if [ -f "${BK}CHANGES.txt" ] && grep -q 'ANTHROPIC_BASE_URL' "${BK}CHANGES.txt" && grep -qi 'opt' "${BK}CHANGES.txt" && grep -q 'undo' "${BK}CHANGES.txt"; then ok "D6 a backup dir holds CHANGES.txt: what changed and the undo for each"; else bad "D6 CHANGES.txt" "BK=$BK $(cat "${BK}CHANGES.txt" 2>/dev/null)"; fi
SAVED="$(ls "${BK}files"/*settings.json 2>/dev/null | head -1)"
if [ -n "$SAVED" ] && cmp -s "$SAVED" "$TMP/settings.orig"; then ok "D7 the original settings.json is saved byte-for-byte in the backup"; else bad "D7 no faithful backup of settings.json" "BK=$BK $(ls "${BK}files" 2>&1)"; fi
if grep -q "^disable gui/$UIDN/$LABEL\$" "$CALLS" && ! grep -qE '^(bootout|bootstrap)' "$CALLS" && [ -f "$PLIST" ]; then ok "D8 the launchd job is DISABLED for the next login, not booted out: its proxy keeps running, the plist stays"; else bad "D8 launchd handling" "$(cat "$CALLS")"; fi
if proxy_up; then ok "D9 the proxy is still answering: the session routed through it keeps working"; else bad "D9 the proxy was stopped under a running session"; fi
if cmp -s "$HOME_T/.zshrc" "$TMP/zshrc.orig" && grep -q '\.zshrc:' <<<"$OUT"; then ok "D10 the shell rc is untouched, and the claude() launcher is reported as kept (it also carries the OmniRoute fallback)"; else bad "D10 rc handling" "$OUT"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "E — idempotent: a second run changes nothing and exits 0; the backup dir can be chosen"
N1="$(backup_count)"; M1="$(mutating_calls)"
OUT="$(hr_routed off --next-session 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'already off' <<<"$OUT"; then ok "E1 second --next-session: exit 0, already off"; else bad "E1 second run" "rc=$RC $OUT"; fi
if [ "$(backup_count)" = "$N1" ] && [ "$(mutating_calls)" = "$M1" ]; then ok "E2 no new backup dir and no launchctl change: nothing was changed, so nothing is written"; else bad "E2 a no-op run wrote or changed something" "backups $N1 -> $(backup_count), mutating $M1 -> $(mutating_calls)"; fi
write_settings 1
OUT="$(hr_routed off --next-session --backup-dir "$TMP/bk-flag" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -f "$TMP/bk-flag/CHANGES.txt" ] && [ -n "$(ls -A "$TMP/bk-flag/files" 2>/dev/null)" ] && ! jq -e '.env | has("ANTHROPIC_BASE_URL")' "$CFG/settings.json" >/dev/null 2>&1 && [ "$(backup_count)" = "$N1" ]; then
  ok "E3 --backup-dir DIR: the mount re-added by hand is removed again and backed up under DIR, not under the default root"
else bad "E3 --backup-dir" "rc=$RC $OUT"; fi
write_settings 1
OUT="$(sbx ANTHROPIC_BASE_URL="$OURS" HMD_HEADROOM_BACKUP_DIR="$TMP/bk-env" perl -e 'alarm 30; exec @ARGV or exit 127' -- "$HR" off --next-session </dev/null 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -f "$TMP/bk-env/CHANGES.txt" ] && [ -n "$(ls -A "$TMP/bk-env/files" 2>/dev/null)" ]; then ok "E4 HMD_HEADROOM_BACKUP_DIR is honoured the same way"; else bad "E4 backup dir env" "rc=$RC $OUT"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "F — off from an unrouted shell stops what is safe to stop, and never a session's route"
write_settings 0
: > "$CALLS"; write_ps_pinned
OUT="$(hr off 2>&1)"; RC=$?
if [ "$RC" = 0 ] && proxy_up && ! grep -q '^bootout' "$CALLS" && [ -f "$PLIST" ]; then ok "F1 a Claude session is still routed through the proxy: it keeps running, the job is not booted out, exit 0"; else bad "F1 stopped under a pinned session" "rc=$RC $(cat "$CALLS") $OUT"; fi
if grep -q '4242424' <<<"$OUT" && grep -q 'left running' <<<"$OUT" && ! grep -q '7770001' <<<"$OUT" && ! grep -q '7770002' <<<"$OUT"; then ok "F2 it names the pinned session, and ignores a postgres that merely inherited the variable and a session on another URL"; else bad "F2 pinned-session report" "$OUT"; fi
: > "$PSFIX"; : > "$CALLS"
OUT="$(hr off 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! proxy_up && [ ! -f "$PLIST" ] && grep -q "^bootout gui/$UIDN/$LABEL\$" "$CALLS"; then ok "F3 no session routed: the launchd job is booted out and its plist removed, and the proxy is stopped"; else bad "F3 full off" "rc=$RC up=$(proxy_up && echo yes) calls=$(cat "$CALLS") $OUT"; fi
if grep -q 'stopped the Headroom proxy' <<<"$OUT" && [ -f "$(newest_backup)CHANGES.txt" ] && ls "$(newest_backup)"files/*.plist >/dev/null 2>&1; then ok "F4 it says it stopped the proxy, and the plist it removed is backed up"; else bad "F4 report/backup" "$OUT"; fi
# a leftover proxy with no supervisor, but a shell rc that exports its URL: stopping it would break every new shell
start_proxy
printf 'export ANTHROPIC_BASE_URL=%s\n' "$OURS" > "$HOME_T/.bashrc"
OUT="$(hr off 2>&1)"; RC=$?
if [ "$RC" = 0 ] && proxy_up && grep -q '\.bashrc:1' <<<"$OUT" && cmp -s "$HOME_T/.zshrc" "$TMP/zshrc.orig"; then ok "F5 an rc that exports the proxy URL keeps the proxy alive, is named by file:line, and is never edited"; else bad "F5 rc pin" "rc=$RC $OUT"; fi
rm -f "$HOME_T/.bashrc"
OUT="$(hr off 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! proxy_up; then ok "F6 once nothing points at it, the next off stops the leftover proxy (the finishing step after --next-session)"; else bad "F6 finishing off" "rc=$RC $OUT"; fi
# a client holding a live connection (not a Claude process, not in the ps fixture) also protects the proxy
start_proxy
python3 -c 'import socket,sys,time; s=socket.create_connection(("127.0.0.1",int(sys.argv[1]))); time.sleep(60)' "$PORT" &
HOLDER=$!; PIDS="$PIDS $HOLDER"; disown "$HOLDER" 2>/dev/null
i=0; while [ "$i" -lt 50 ]; do case "$(lsof -nP -iTCP:"$PORT" -sTCP:ESTABLISHED -Fp 2>/dev/null)" in *"p$HOLDER"*) break ;; esac; sleep 0.1; i=$((i+1)); done
OUT="$(hr off 2>&1)"; RC=$?
if [ "$RC" = 0 ] && proxy_up && grep -q "$HOLDER" <<<"$OUT"; then ok "F7 a process holding a live connection to the proxy keeps it alive and is named"; else bad "F7 connection holder" "rc=$RC holder=$HOLDER $OUT"; fi
reap "$HOLDER"; stop_proxy
# something on the port that is not Headroom, and a proxy that reports someone else's pid: never signalled
python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
FOREIGN=$!; PIDS="$PIDS $FOREIGN"; disown "$FOREIGN" 2>/dev/null; i=0; while [ "$i" -lt 50 ]; do proxy_up && break; sleep 0.1; i=$((i+1)); done
OUT="$(hr off 2>&1)"; RC=$?
if [ "$RC" = 0 ] && kill -0 "$FOREIGN" 2>/dev/null && proxy_up; then ok "F8 a foreign listener on the port is left alone"; else bad "F8 foreign listener" "rc=$RC $OUT"; fi
reap "$FOREIGN"
start_proxy FAKE_PROXY_REPORT_PID=1
OUT="$(hr off 2>&1)"; RC=$?
if [ "$RC" = 0 ] && proxy_up; then ok "F9 a listener whose /health pid is not the listening pid is never signalled"; else bad "F9 spoofed pid" "rc=$RC $OUT"; fi
stop_proxy

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "G — on after off; an env opt-out; a failed add"
write_plist; : > "$LOADED"; : > "$DISABLED"; : > "$CALLS"
OUT="$(hr on 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! opted_out_rec && ! chain_report | grep -q 'opted out'; then ok "G1 on clears the opt-out: the chain no longer declines"; else bad "G1 on after off" "rc=$RC $OUT"; fi
if grep -q "^enable gui/$UIDN/$LABEL\$" "$CALLS" && [ ! -f "$DISABLED" ]; then ok "G2 on re-enables the launchd job that --next-session disabled"; else bad "G2 launchd enable" "$(cat "$CALLS")"; fi
OUT="$(sbx HMD_HEADROOM_DISABLE=1 perl -e 'alarm 30; exec @ARGV or exit 127' -- "$HR" on </dev/null 2>&1)"; RC=$?
if [ "$RC" = 2 ] && grep -q 'HMD_HEADROOM_DISABLE' <<<"$OUT"; then ok "G3 an env opt-out cannot be cleared by on: exit 2 and it names the variable"; else bad "G3 env opt-out" "rc=$RC $OUT"; fi
rm -rf "$STATE/headroom"; : > "$TMP/modules.calls"
OUT="$(sbx FAKE_ADD_RC=1 perl -e 'alarm 30; exec @ARGV or exit 127' -- "$HR" on </dev/null 2>&1)"; RC=$?
ST="$(hr status 2>&1)"
if [ "$RC" != 0 ] && grep -q 'not enabled' <<<"$OUT" && grep -q '^headroom: OFF' <<<"$ST"; then ok "G4 a failed add: non-zero exit, says it was not enabled, and status stays OFF"; else bad "G4 failed add" "rc=$RC $OUT"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "H — a synthetic HOME never reaches the real launchctl"
mkdir -p "$TMP/lcshim"; : > "$TMP/real.calls"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$TMP/real.calls" > "$TMP/lcshim/launchctl"; chmod +x "$TMP/lcshim/launchctl"
hr on >/dev/null 2>&1; write_plist
OUT="$(sbx perl -e 'alarm 30; exec @ARGV or exit 127' -- env -u LAUNCHCTL PATH="$TMP/lcshim:$SHIMS:$PATH" "$HR" off --next-session </dev/null 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ ! -s "$TMP/real.calls" ] && grep -qi 'launchd' <<<"$OUT" && opted_out_rec; then ok "H1 the real launchctl is never invoked from a synthetic HOME, the config half still happens, and the output says launchd was left alone"; else bad "H1 sandbox guard" "rc=$RC real.calls=$(cat "$TMP/real.calls") $OUT"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "I — no usable python3 (HMD_PYTHON seam): a settings file that cannot be checked is reported, and the proxy is not stopped while one exists"
reset_world
cp "$CFG/settings.json" "$TMP/settings.i.orig"
OUT="$(sbx HMD_PYTHON=/nonexistent/python3 perl -e 'alarm 30; exec @ARGV or exit 127' -- "$HR" off </dev/null 2>&1)"; RC=$?
if [ "$RC" = 0 ] && proxy_up && cmp -s "$CFG/settings.json" "$TMP/settings.i.orig" && ! grep -q '^bootout' "$CALLS"; then
  ok "I1 the proxy keeps running, settings.json is byte-identical and the launchd job is not booted out: a mount that could not be looked for may still point at the proxy"
else bad "I1 off with no python3" "rc=$RC calls=$(cat "$CALLS") $OUT"; fi
if grep -q 'could not be checked' <<<"$OUT" && grep -q 'python3' <<<"$OUT"; then ok "I2 it says which file was not checked and why, so the silence of 'no mount found' can never be read as a clean bill"; else bad "I2 the unchecked file is not reported" "$OUT"; fi
if opted_out_rec; then ok "I3 the config half still happens: the module is opted out, so route and wrap already decline it"; else bad "I3 no opt-out recorded"; fi
OUT="$(sbx HMD_PYTHON=/nonexistent/python3 perl -e 'alarm 30; exec @ARGV or exit 127' -- "$HR" status </dev/null 2>&1)"
if grep -q 'NOT CHECKED' <<<"$OUT"; then ok "I4 status says NOT CHECKED rather than 'none found'"; else bad "I4 status hides the unchecked file" "$OUT"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "X — falsifiers: each mutant of the script must break the case that guards it"
MUT="$TMP/mutbin"; mkdir -p "$MUT"; ln -s "$ROOT/bin/lib" "$MUT/lib"; cp "$ROOT/bin/heimdall-headroom-supervise" "$MUT/"
mutant() {   # mutant <anchor> <replacement-line> — a copy of the script with the ONE line carrying '# FALSIFIER:<anchor>' replaced, and proof it landed
  grep -c "# FALSIFIER:$1\$" "$HR" | grep -qx 1 || { bad "X0 the script has no unique '# FALSIFIER:$1' line: the test has lost its grip on the code"; return 1; }
  sed "s/^.*# FALSIFIER:$1\$/$2/" "$HR" > "$MUT/heimdall-headroom"; chmod +x "$MUT/heimdall-headroom"
  if cmp -s "$HR" "$MUT/heimdall-headroom"; then bad "X0 the mutation of '$1' did not change the script: the proof would be vacuous"; return 1; fi
  return 0
}
# X1 — the refusal removed: a routed session's `off` would proceed and stop the proxy under it.
if mutant refuse '  if false; then'; then
  reset_world
  sbx ANTHROPIC_BASE_URL="$OURS" perl -e 'alarm 30; exec @ARGV or exit 127' -- "$MUT/heimdall-headroom" off </dev/null >/dev/null 2>&1
  if ! proxy_up; then ok "X1 refusal mutant: the proxy IS stopped under a routed session, so C1/C3 can go RED"; else bad "X1 the mutant still protected the session: C1/C3 may be vacuous"; fi
fi
# X2 — the pinned-session guard dropped: a session that is routed through the proxy loses it.
if mutant pinned '  :'; then
  reset_world; write_ps_pinned
  sbx perl -e 'alarm 30; exec @ARGV or exit 127' -- "$MUT/heimdall-headroom" off </dev/null >/dev/null 2>&1
  if ! proxy_up; then ok "X2 pinned-session mutant: the proxy IS stopped under a pinned session, so F1 can go RED"; else bad "X2 the mutant still protected the pinned session: F1 may be vacuous"; fi
fi
# X3 — the 'is this mount ours' test dropped: OmniRoute's URL in a settings file would be removed.
if mutant ours 'ours = True'; then
  reset_world
  sbx ANTHROPIC_BASE_URL="$OURS" perl -e 'alarm 30; exec @ARGV or exit 127' -- "$MUT/heimdall-headroom" off --next-session </dev/null >/dev/null 2>&1
  if ! cmp -s "$CFG/settings.local.json" "$TMP/settings.local.orig"; then ok "X3 mount mutant: a foreign base URL IS removed, so D5 can go RED"; else bad "X3 the mutant still left the foreign mount alone: D5 may be vacuous"; fi
fi

# X4 — the unchecked-settings guard dropped: with no python3 the proxy would be stopped although settings.json may still point at it.
if mutant unchecked '  :'; then
  reset_world
  sbx HMD_PYTHON=/nonexistent/python3 perl -e 'alarm 30; exec @ARGV or exit 127' -- "$MUT/heimdall-headroom" off </dev/null >/dev/null 2>&1
  if ! proxy_up; then ok "X4 unchecked-settings mutant: the proxy IS stopped, so I1 can go RED"; else bad "X4 the mutant still protected the proxy: I1 may be vacuous"; fi
fi

echo
echo "headroom-optin: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

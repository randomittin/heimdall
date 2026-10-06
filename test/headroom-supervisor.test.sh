#!/usr/bin/env bash
#
# headroom-supervisor.test.sh — acceptance for bin/heimdall-headroom-supervise, the OPT-IN
# launchd supervisor for the local Headroom proxy, and for its `hmd modules` wiring.
#
# THE INCIDENT (2026-10-06): the proxy on :8787 exited on a signal and nothing restarted it for
# 16m27s. A LaunchAgent with KeepAlive + ThrottleInterval makes that window seconds.
#
# NEVER LOADED. `launchctl` is a RECORDER here (LAUNCHCTL=...): it logs every verb and flips a
# flag file, and it never starts anything. HOME is a throwaway and the LaunchAgents dir is a tmp
# dir, so no case can touch the real launchd, the real plist, or the live proxy on :8787. The
# plist CONTENT is validated with the platform's own `plutil -lint` / `plutil -extract`.
#
# Sections:
#   1  install: a valid plist (plutil -lint) with KeepAlive, ThrottleInterval 5, --lossless IN ARGV
#   2  re-install with the same config does not restart a running proxy
#   3  a changed config reloads exactly once (bootout, bootstrap)
#   4  a LIVE listener on the port: plist written, NOT bootstrapped, listener untouched
#   5  status --json
#   6  uninstall removes plist + logs + agent; a second uninstall is a no-op with NO launchctl call
#   7  synthetic HOME with the real launchctl: refused (exit 4), nothing written, nothing called
#   8  module not added: refused, nothing written
#   9  HEADROOM_LOSSLESS=0 is honoured (no --lossless in argv)
#  10  `hmd modules supervise headroom ...` and `hmd modules remove headroom`, canonical vs scratch

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SUP="$ROOT/bin/heimdall-headroom-supervise"
MODS="$ROOT/bin/heimdall-modules"

[ "$(uname -s)" = Darwin ] || { echo "SKIP: launchd supervision is macOS-only"; exit 0; }
command -v plutil  >/dev/null 2>&1 || { echo "error: plutil is required" >&2; exit 2; }
command -v jq      >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); return 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/headroom-supervisor.XXXXXX")"
HOLDER_PID=""
cleanup() { [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" >/dev/null 2>&1; rm -rf "$TMP"; return 0; }
trap cleanup EXIT

HOME_T="$TMP/home"; mkdir -p "$HOME_T"
LA="$TMP/la"; CALLS="$TMP/lc.calls"; LOADED="$TMP/lc.loaded"; : > "$CALLS"
LABEL="dev.runheimdall.headroom.test"
PLIST="$LA/$LABEL.plist"
UIDN="$(id -u)"
PORT=$((23000 + ($$ % 3000) * 2)); PORT2=$((PORT + 1))

# launchctl RECORDER — never starts anything.
LC="$TMP/launchctl-recorder"
cat > "$LC" <<'EOSH'
#!/usr/bin/env bash
echo "$*" >> "${LC_CALLS:?}"
case "$1" in
  print)
    [ -f "${LC_LOADED:?}" ] || exit 1
    printf '%s = {\n\tstate = running\n\tpid = 4242\n\tlast exit code = (never exited)\n}\n' "$2"
    exit 0 ;;
  bootstrap) : > "${LC_LOADED:?}" ;;
  bootout)   rm -f "${LC_LOADED:?}" ;;
esac
exit 0
EOSH
chmod +x "$LC"

FAKE="$TMP/fake-headroom"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE"; chmod +x "$FAKE"
MODSTATE="$TMP/modstate"; mkdir -p "$MODSTATE/headroom"; printf '{}\n' > "$MODSTATE/headroom/receipt.json"

# sup <cmd...> — run a command inside the sandbox environment.
sup() {
  env -u HMD_MODULE_STATE_IS_CANONICAL -u HEADROOM_LOSSLESS \
      HOME="$HOME_T" HEIMDALL_HOME="$HOME_T/.heimdall" HEIMDALL_LAUNCH_AGENTS_DIR="$LA" LAUNCHCTL="$LC" \
      HMD_HEADROOM_BIN="$FAKE" HMD_MODULES_STATE="$MODSTATE" HEADROOM_PORT="$PORT" \
      HMD_HEADROOM_SUPERVISOR_LABEL="$LABEL" LC_CALLS="$CALLS" LC_LOADED="$LOADED" "$@"
}
calls_matching() { grep -c "$1" "$CALLS" 2>/dev/null || true; }
px() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null; }

echo
echo "0 — the script parses"
if bash -n "$SUP"; then ok "bin/heimdall-headroom-supervise parses (bash -n)"; else bad "syntax error"; fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "1 — install: a valid plist, KeepAlive, ThrottleInterval 5, --lossless IN ARGV, bootstrapped once"
sup "$SUP" install --json > "$TMP/o1" 2> "$TMP/e1"; RC=$?
if [ "$RC" = 0 ]; then ok "1a install exits 0"; else bad "1a install failed" "rc=$RC $(cat "$TMP/e1")"; fi
if [ -f "$PLIST" ]; then ok "1b plist written at \$LAUNCH_AGENTS_DIR/<label>.plist"; else bad "1b no plist"; fi
if plutil -lint "$PLIST" >/dev/null 2>&1; then ok "1c plutil -lint: OK"; else bad "1c plutil -lint rejected the plist" "$(plutil -lint "$PLIST" 2>&1)"; fi
if [ "$(px Label)" = "$LABEL" ]; then ok "1d Label"; else bad "1d Label" "$(px Label)"; fi
if [ "$(px KeepAlive)" = true ]; then ok "1e KeepAlive = true (restart on ANY exit, incl. SIGTERM)"; else bad "1e KeepAlive" "$(px KeepAlive)"; fi
if [ "$(px ThrottleInterval)" = 5 ]; then ok "1f ThrottleInterval = 5"; else bad "1f ThrottleInterval" "$(px ThrottleInterval)"; fi
if [ "$(px RunAtLoad)" = true ]; then ok "1g RunAtLoad = true"; else bad "1g RunAtLoad" "$(px RunAtLoad)"; fi
ARGS="$(for i in 0 1 2 3 4 5 6; do px ProgramArguments.$i; echo; done | tr '\n' ' ')"
# shellcheck disable=SC2116,SC2086 # echo $ARGS collapses the whitespace runs px leaves between argv entries: the unquoted word-split is the point
if [ "$ARGS" = "$FAKE proxy --host 127.0.0.1 --port $PORT --lossless  " ] || [ "$(echo $ARGS)" = "$FAKE proxy --host 127.0.0.1 --port $PORT --lossless" ]; then
  ok "1h ProgramArguments = <bin> proxy --host 127.0.0.1 --port $PORT --lossless (the flag is IN ARGV, so the chain's reuse gate can verify it)"
else
  bad "1h ProgramArguments wrong" "$ARGS"
fi
if [ "$(px EnvironmentVariables.HEADROOM_LOSSLESS)" = 1 ] && [ "$(px EnvironmentVariables.HEADROOM_COMPRESSION_TIMEOUT_SECONDS)" = 30 ] && [ "$(px EnvironmentVariables.HEADROOM_KOMPRESS_MAX_TOKENS)" = 10000 ]; then
  ok "1i the chain's proxy environment is carried (lossless, 30s compression timeout, 10000 token gate)"
else
  bad "1i EnvironmentVariables wrong" "$(plutil -p "$PLIST" 2>&1 | head -20)"
fi
if [ "$(px StandardOutPath)" = "$HOME_T/.heimdall/headroom/launchd.out.log" ] && [ "$(px StandardErrorPath)" = "$HOME_T/.heimdall/headroom/launchd.err.log" ]; then
  ok "1j launchd logs live under \$HEIMDALL_HOME/headroom"
else
  bad "1j log paths wrong" "$(px StandardOutPath) $(px StandardErrorPath)"
fi
if [ "$(stat -f %Lp "$PLIST")" = 644 ]; then ok "1k plist mode 0644 (never world-writable)"; else bad "1k plist mode" "$(stat -f %Lp "$PLIST")"; fi
if [ "$(calls_matching "^bootstrap gui/$UIDN $PLIST\$")" = 1 ]; then ok "1l launchctl bootstrap gui/<uid> <plist> exactly once"; else bad "1l bootstrap not recorded exactly once" "$(cat "$CALLS")"; fi
if ! grep -qE '^(load|unload|kickstart|kill|remove)' "$CALLS"; then ok "1m only print/bootstrap verbs: no legacy load, no kickstart, no kill"; else bad "1m unexpected launchctl verb" "$(cat "$CALLS")"; fi
if jq -e '.action == "loaded" and .loaded == true and .port_state == "dead"' "$TMP/o1" >/dev/null 2>&1; then ok "1n --json reports action=loaded, port_state=dead"; else bad "1n --json wrong" "$(cat "$TMP/o1")"; fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "2 — re-install with the SAME config does not restart the running proxy"
: > "$CALLS"
sup "$SUP" install --json > "$TMP/o2" 2> "$TMP/e2"
if jq -e '.action == "unchanged"' "$TMP/o2" >/dev/null 2>&1; then ok "2a action = unchanged"; else bad "2a not unchanged" "$(cat "$TMP/o2" "$TMP/e2")"; fi
if ! grep -qE '^(bootstrap|bootout)' "$CALLS"; then ok "2b no bootstrap/bootout: a live supervised proxy is never bounced by a re-install"; else bad "2b re-install restarted the proxy" "$(cat "$CALLS")"; fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "3 — a CHANGED config reloads exactly once"
: > "$CALLS"
sup env HEADROOM_PORT="$PORT2" "$SUP" install --json > "$TMP/o3" 2> "$TMP/e3"
if jq -e '.action == "reloaded"' "$TMP/o3" >/dev/null 2>&1; then ok "3a action = reloaded"; else bad "3a not reloaded" "$(cat "$TMP/o3" "$TMP/e3")"; fi
if [ "$(sed -n '/^bootout/=' "$CALLS" | head -1)" -lt "$(sed -n '/^bootstrap/=' "$CALLS" | head -1)" ] 2>/dev/null \
  && [ "$(calls_matching '^bootout')" = 1 ] && [ "$(calls_matching '^bootstrap')" = 1 ]; then
  ok "3b one bootout, then one bootstrap"
else
  bad "3b wrong reload sequence" "$(cat "$CALLS")"
fi
if [ "$(px ProgramArguments.5)" = "$PORT2" ]; then ok "3c the new port is in the plist"; else bad "3c plist not updated" "$(px ProgramArguments.5)"; fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "4 — a LIVE listener on the port: plist written, NOT bootstrapped, listener left running"
rm -f "$LOADED" "$PLIST"; : > "$CALLS"
HPORT=$((PORT + 10))
python3 -m http.server "$HPORT" --bind 127.0.0.1 >/dev/null 2>&1 &
HOLDER_PID=$!
i=0; while [ "$i" -lt 60 ]; do lsof -nP -iTCP:"$HPORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.1; i=$((i+1)); done
sup env HEADROOM_PORT="$HPORT" "$SUP" install --json > "$TMP/o4" 2> "$TMP/e4"; RC=$?
if [ "$RC" = 0 ] && jq -e '.action == "deferred" and .loaded == false' "$TMP/o4" >/dev/null 2>&1; then ok "4a action = deferred (exit 0)"; else bad "4a not deferred" "rc=$RC $(cat "$TMP/o4" "$TMP/e4")"; fi
if [ "$(calls_matching '^bootstrap')" = 0 ]; then ok "4b NO bootstrap: a second proxy cannot bind and would crash-loop every 5s after a full model preload"; else bad "4b bootstrapped over a live listener" "$(cat "$CALLS")"; fi
if kill -0 "$HOLDER_PID" 2>/dev/null; then ok "4c the live listener was never touched"; else bad "4c the live listener died"; fi
if [ -f "$PLIST" ]; then ok "4d plist is on disk, so supervision takes over at next login or the next time the port is found dead"; else bad "4d no plist"; fi
kill "$HOLDER_PID" >/dev/null 2>&1; HOLDER_PID=""

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "5 — status --json"
sup "$SUP" install >/dev/null 2>&1       # port free again -> loads
: > "$CALLS"
sup "$SUP" status --json > "$TMP/o5" 2> "$TMP/e5"
if jq -e --arg l "$LABEL" '.installed == true and .loaded == true and .label == $l and .pid == 4242 and (.port|type) == "number"' "$TMP/o5" >/dev/null 2>&1; then
  ok "5a installed/loaded/label/pid parsed from launchctl print"
else
  bad "5a status wrong" "$(cat "$TMP/o5" "$TMP/e5")"
fi
if ! grep -qE '^(bootstrap|bootout|kickstart)' "$CALLS"; then ok "5b status is read-only (print only)"; else bad "5b status mutated launchd" "$(cat "$CALLS")"; fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "6 — uninstall removes plist + logs + agent; a second uninstall is a total no-op"
mkdir -p "$HOME_T/.heimdall/headroom"; : > "$HOME_T/.heimdall/headroom/launchd.err.log"; : > "$CALLS"
sup "$SUP" uninstall --quiet; RC=$?
if [ "$RC" = 0 ] && [ ! -e "$PLIST" ] && [ ! -e "$HOME_T/.heimdall/headroom/launchd.err.log" ]; then ok "6a plist and launchd logs removed"; else bad "6a leftovers" "rc=$RC $(ls "$LA" "$HOME_T/.heimdall/headroom" 2>&1)"; fi
if [ "$(calls_matching "^bootout gui/$UIDN/$LABEL\$")" = 1 ]; then ok "6b launchctl bootout gui/<uid>/<label> (the only way to stop a KeepAlive job)"; else bad "6b no bootout" "$(cat "$CALLS")"; fi
: > "$CALLS"
sup "$SUP" uninstall --quiet; RC=$?
if [ "$RC" = 0 ] && [ ! -s "$CALLS" ]; then ok "6c second uninstall: exit 0 and ZERO launchctl calls"; else bad "6c second uninstall touched launchd" "rc=$RC $(cat "$CALLS")"; fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "7 — a synthetic HOME with the REAL launchctl is refused: exit 4, nothing written, nothing called"
mkdir -p "$TMP/pathshim"; : > "$TMP/real.calls"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$TMP/real.calls" > "$TMP/pathshim/launchctl"; chmod +x "$TMP/pathshim/launchctl"
env -u LAUNCHCTL HOME="$HOME_T" HEIMDALL_HOME="$HOME_T/.heimdall" HEIMDALL_LAUNCH_AGENTS_DIR="$LA" PATH="$TMP/pathshim:$PATH" \
    HMD_HEADROOM_BIN="$FAKE" HMD_MODULES_STATE="$MODSTATE" HEADROOM_PORT="$PORT" HMD_HEADROOM_SUPERVISOR_LABEL="$LABEL" "$SUP" install > "$TMP/o7" 2> "$TMP/e7"; RC=$?
if [ "$RC" = 4 ]; then ok "7a exit 4"; else bad "7a expected exit 4" "rc=$RC $(cat "$TMP/e7")"; fi
if [ ! -e "$PLIST" ] && [ ! -s "$TMP/real.calls" ]; then ok "7b no plist written and the real launchctl was never invoked"; else bad "7b the sandbox guard leaked" "$(cat "$TMP/real.calls")"; fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "8 — the module is not added: refused, nothing written"
mkdir -p "$TMP/emptystate"
sup env HMD_MODULES_STATE="$TMP/emptystate" "$SUP" install > "$TMP/o8" 2> "$TMP/e8"; RC=$?
if [ "$RC" = 2 ] && [ ! -e "$PLIST" ] && grep -q "hmd modules add headroom" "$TMP/e8"; then ok "8a exit 2, nothing written, the fix is named"; else bad "8a" "rc=$RC $(cat "$TMP/e8")"; fi

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "9 — HEADROOM_LOSSLESS=0 is honoured: no --lossless in argv"
sup env HEADROOM_LOSSLESS=0 "$SUP" install --quiet >/dev/null 2>&1
if [ -f "$PLIST" ] && ! plutil -p "$PLIST" | grep -q -- '--lossless' && [ "$(px EnvironmentVariables.HEADROOM_LOSSLESS)" = 0 ]; then
  ok "9a an operator's explicit lossless opt-out is carried, not overridden"
else
  bad "9a opt-out not honoured" "$(plutil -p "$PLIST" 2>&1 | head -12)"
fi
sup "$SUP" uninstall --quiet >/dev/null 2>&1

# ══════════════════════════════════════════════════════════════════════════════════════
echo
echo "10 — hmd modules: supervise verb and the remove hook (canonical state only)"
M="env HOME=$HOME_T HEIMDALL_HOME=$HOME_T/.heimdall HEIMDALL_LAUNCH_AGENTS_DIR=$LA LAUNCHCTL=$LC HMD_HEADROOM_BIN=$FAKE HEADROOM_PORT=$PORT HMD_HEADROOM_SUPERVISOR_LABEL=$LABEL LC_CALLS=$CALLS LC_LOADED=$LOADED HMD_MODULES_STATE=$MODSTATE"
rm -f "$LOADED"; : > "$CALLS"
$M "$MODS" supervise headroom install --state "$MODSTATE" >/dev/null 2> "$TMP/e10a"; RC=$?
if [ "$RC" = 2 ] && [ ! -e "$PLIST" ] && [ ! -s "$CALLS" ]; then ok "10a scratch state root: install REFUSED, no plist, no launchctl call (machine-global side effect)"; else bad "10a scratch state was allowed to touch launchd" "rc=$RC $(cat "$TMP/e10a" "$CALLS" 2>/dev/null)"; fi
$M HMD_MODULE_STATE_IS_CANONICAL=1 "$MODS" supervise headroom install --state "$MODSTATE" >/dev/null 2> "$TMP/e10b"; RC=$?
if [ "$RC" = 0 ] && [ -f "$PLIST" ] && plutil -lint "$PLIST" >/dev/null 2>&1; then ok "10b canonical state: supervise headroom install writes a valid plist"; else bad "10b canonical install failed" "rc=$RC $(cat "$TMP/e10b")"; fi
if $M "$MODS" supervise headroom status --json --state "$MODSTATE" 2>/dev/null | jq -e '.installed == true and .loaded == true' >/dev/null 2>&1; then ok "10c supervise headroom status --json routes through"; else bad "10c status verb broken"; fi
$M "$MODS" supervise nosuchmodule install --state "$MODSTATE" >/dev/null 2> "$TMP/e10d"; RC=$?
if [ "$RC" = 2 ]; then ok "10d a module with no supervised process is refused"; else bad "10d nosuchmodule accepted" "rc=$RC"; fi

: > "$CALLS"; mkdir -p "$TMP/scratch2/headroom"; printf '{}\n' > "$TMP/scratch2/headroom/receipt.json"
$M "$MODS" remove headroom --state "$TMP/scratch2" >/dev/null 2>&1
if [ -f "$PLIST" ] && [ "$(calls_matching '^bootout')" = 0 ]; then ok "10e remove on a SCRATCH state root leaves the machine's supervisor alone (it must never reach the real launchd)"; else bad "10e scratch remove touched the supervisor" "$(cat "$CALLS")"; fi
$M HMD_MODULE_STATE_IS_CANONICAL=1 "$MODS" remove headroom --state "$MODSTATE" >/dev/null 2>&1
if [ ! -e "$PLIST" ] && [ "$(calls_matching '^bootout')" = 1 ]; then ok "10f remove on the canonical state UNINSTALLS the supervisor (uninstall removes it)"; else bad "10f remove left the supervisor behind" "plist=$(ls "$LA" 2>&1) calls=$(cat "$CALLS")"; fi

echo
echo "headroom-supervisor: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

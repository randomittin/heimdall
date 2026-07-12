#!/usr/bin/env bash
# test/heimdall-dream-schedule.test.sh — acceptance for the AUTO-BACKGROUND nightly
# schedule of /dream (bin/heimdall-dream-schedule): a macOS launchd LaunchAgent
# (com.heimdall.dream) that fires `heimdall-dream --repo <repo> run --overnight`
# nightly at 03:00 and logs to ~/.heimdall/logs/dream.log.
#
# Hermetic + PRIVILEGE-FREE: the LaunchAgent dir and the log path are redirected to a
# throwaway tmp dir via env overrides, and `launchctl` is SHIMMED (LAUNCHCTL=<mock>)
# so the suite proves register / idempotent / status / uninstall WITHOUT loading a
# real agent or requiring root. The mock records every call and tracks a "loaded"
# state file so `status` reflects load/unload truthfully.
#
# FALSIFIABLE claims proven:
#   (1) INSTALL writes a com.heimdall.dream plist encoding the EXACT overnight command
#       (heimdall-dream --repo <repo> run --overnight) at cron 03:00 and the log path,
#       and loads it via launchctl.
#   (2) IDEMPOTENT — install twice leaves exactly ONE plist and ONE loaded job (no dup).
#   (3) STATUS reports the job registered (loaded) after install; --json is parseable.
#   (4) UNINSTALL unloads via launchctl and removes the plist; status then reports gone;
#       a second uninstall is a clean no-op (idempotent off-switch).
#   (5) run-now fires the SAME argv the schedule encodes and writes a fresh dated report.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-dream-schedule"
DREAM="$ROOT/bin/heimdall-dream"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -x "$CLI" ]   || { echo "FATAL: $CLI not executable" >&2; exit 2; }
[ -x "$DREAM" ] || { echo "FATAL: $DREAM not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "dream-sched-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── the launchctl SHIM: records calls, tracks a "loaded" state file so status is real.
SHIM="$WORK/mock-launchctl"
STATE="$WORK/loaded"          # exists iff the agent is "loaded"
CALLS="$WORK/calls"           # one line per launchctl invocation
cat > "$SHIM" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\$1" in
  load|bootstrap)   : > "$STATE"; exit 0 ;;
  unload|bootout)   rm -f "$STATE"; exit 0 ;;
  list)
    if [ -n "\${2:-}" ]; then [ -f "$STATE" ] && exit 0 || exit 1; fi
    [ -f "$STATE" ] && echo "-	0	com.heimdall.dream"; exit 0 ;;
  print) [ -f "$STATE" ] && exit 0 || exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM"

# LaunchAgents dir + log redirected into tmp; launchctl shimmed. Absolute repo.
LA="$WORK/LaunchAgents"
LOG="$WORK/logs/dream.log"
REPO="$WORK/repo"; mkdir -p "$REPO/.planning"
PLIST="$LA/com.heimdall.dream.plist"

export HEIMDALL_LAUNCH_AGENTS_DIR="$LA"
export HEIMDALL_DREAM_LOG="$LOG"
export LAUNCHCTL="$SHIM"

echo "dream-schedule acceptance"
echo "========================="

# ── (1) INSTALL ─────────────────────────────────────────────────────────────────
"$CLI" install --repo "$REPO" >/dev/null

[ -f "$PLIST" ] && ok "(1) plist written at $PLIST" \
  || bad "(1) plist not written"

grep -q "<string>com.heimdall.dream</string>" "$PLIST" \
  && ok "(1) plist declares Label com.heimdall.dream" \
  || bad "(1) plist missing Label"

# the EXACT overnight command: dream bin + --repo <abs> + run + --overnight
grep -q "$DREAM" "$PLIST" \
  && grep -q "<string>$REPO</string>" "$PLIST" \
  && grep -q "<string>run</string>" "$PLIST" \
  && grep -q "<string>--overnight</string>" "$PLIST" \
  && ok "(1) plist encodes 'heimdall-dream --repo <repo> run --overnight'" \
  || bad "(1) plist ProgramArguments wrong"

# cron 0 3 * * *  ->  StartCalendarInterval Hour 3 Minute 0
grep -q "StartCalendarInterval" "$PLIST" \
  && ok "(1) plist schedules via StartCalendarInterval (survives restarts)" \
  || bad "(1) no StartCalendarInterval"
python3 - "$PLIST" <<'PY' && ok "(1) fires nightly at 03:00 (Hour=3, Minute=0)" || bad "(1) not 03:00"
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    pl = plistlib.load(fh)
ci = pl.get("StartCalendarInterval", {})
sys.exit(0 if ci.get("Hour") == 3 and ci.get("Minute") == 0 else 1)
PY

grep -q "$LOG" "$PLIST" \
  && ok "(1) plist logs to the configured dream log" \
  || bad "(1) log path not wired into plist"

grep -q "^load" "$CALLS" \
  && ok "(1) install loaded the agent via launchctl" \
  || bad "(1) launchctl load not invoked"

# ── (2) IDEMPOTENT — install again, still ONE plist + ONE loaded job ──────────────
"$CLI" install --repo "$REPO" >/dev/null
N="$(find "$LA" -name 'com.heimdall.dream.plist' | wc -l | tr -d ' ')"
[ "$N" = "1" ] && ok "(2) re-install leaves exactly ONE plist (no duplicate)" \
  || bad "(2) duplicate plist(s): $N"
# the mock's loaded-state is a single boolean file — one job, not two.
[ -f "$STATE" ] && ok "(2) exactly one job loaded after double-install" \
  || bad "(2) job not loaded after re-install"

# ── (3) STATUS reports registered ────────────────────────────────────────────────
# capture first (a piped `grep -q` closes the pipe early -> SIGPIPE -> the CLI's own
# pipefail would flip the pipeline red; capturing keeps the assertion honest).
STXT="$("$CLI" status --repo "$REPO")"
echo "$STXT" | grep -qi "registered\|loaded\|installed" \
  && ok "(3) status reports the job registered" \
  || bad "(3) status did not report registered"
SJSON="$("$CLI" status --repo "$REPO" --json)"
[ "$(echo "$SJSON" | jq -r '.loaded')" = "true" ] \
  && [ "$(echo "$SJSON" | jq -r '.label')" = "com.heimdall.dream" ] \
  && ok "(3) status --json: loaded=true, label=com.heimdall.dream" \
  || bad "(3) status --json wrong: $SJSON"

# ── (5) run-now fires the SAME argv and writes a fresh dated report ───────────────
DATE="$(date -u +%Y-%m-%d)"
RN="$("$CLI" run-now --repo "$REPO" --json 2>/dev/null || true)"
REP="$REPO/.planning/dream/$DATE.md"
[ -f "$REP" ] && ok "(5) run-now wrote a fresh report at .planning/dream/$DATE.md" \
  || bad "(5) run-now did not write the dated report"
if echo "$RN" | jq -e '.mode == "overnight"' >/dev/null 2>&1; then
  ok "(5) run-now ran in overnight mode (parity with the schedule)"
else
  bad "(5) run-now not in overnight mode: $RN"
fi

# ── (4) UNINSTALL — unload + remove; status gone; second uninstall clean ──────────
"$CLI" uninstall --repo "$REPO" >/dev/null
[ ! -f "$PLIST" ] && ok "(4) uninstall removed the plist" \
  || bad "(4) plist still present after uninstall"
grep -Eq "^(unload|bootout)" "$CALLS" \
  && ok "(4) uninstall unloaded the agent via launchctl" \
  || bad "(4) launchctl unload not invoked"
UJSON="$("$CLI" status --repo "$REPO" --json)"
[ "$(echo "$UJSON" | jq -r '.loaded')" = "false" ] \
  && [ "$(echo "$UJSON" | jq -r '.installed')" = "false" ] \
  && ok "(4) status after uninstall: loaded=false, installed=false" \
  || bad "(4) status still shows the job: $UJSON"
# idempotent off-switch: a second uninstall must not error.
if "$CLI" uninstall --repo "$REPO" >/dev/null 2>&1; then
  ok "(4) second uninstall is a clean no-op (idempotent off-switch)"
else
  bad "(4) second uninstall errored"
fi

echo
echo "-------------------------"
printf "TOTAL: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

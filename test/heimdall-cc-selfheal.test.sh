#!/usr/bin/env bash
# heimdall-cc-selfheal.test.sh — the self-heal is verified with PATH-faked npm/claude so
# NOTHING on the real machine is touched: a temp HOME + HEIMDALL_HOME + claude.json, and
# fake `npm`/`claude` recorders that log calls. Proves: opt-out, throttle, non-native skip,
# the simulated conflict->repair (uninstall + autoUpdates:true + claude update), idempotent-
# on-healthy, JSON key-preservation, and never-block.
set -uo pipefail
HEAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/heimdall-cc-selfheal"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
[ -x "$HEAL" ] || { echo "FATAL: $HEAL not executable"; exit 2; }
bash -n "$HEAL" || { echo "FATAL: syntax"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
CALLS="$WORK/calls.log"
# fake npm: `ls -g --depth=0 <pkg>` exits 0 iff $WORK/has-conflict exists; `uninstall -g`
# clears that marker + records.
cat > "$BIN/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$*" >> "$CALLS"
case "\$1 \$2" in
  "ls -g") [ -f "$WORK/has-conflict" ] && exit 0 || exit 1 ;;
  "uninstall -g") rm -f "$WORK/has-conflict"; echo "uninstalled \$3" >> "$CALLS"; exit 0 ;;
  "root -g") echo "$WORK/node_modules"; exit 0 ;;
esac
exit 0
EOF
# fake claude: `update` exits 0 iff $WORK/updater-ok exists (else simulates "Auto-update failed").
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$*" >> "$CALLS"
[ "\$1" = update ] && { [ -f "$WORK/updater-ok" ] && exit 0 || exit 1; }
exit 0
EOF
chmod +x "$BIN/npm" "$BIN/claude"

mkcfg(){ printf '{\n  "installMethod": "%s",\n  "autoUpdates": %s,\n  "numStartups": 7,\n  "userID": "keepme"\n}\n' "$1" "$2" > "$WORK/claude.json"; }
runheal(){ env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" HEIMDALL_HOME="$WORK/.hmd" \
  HEIMDALL_CLAUDE_CONFIG="$WORK/claude.json" "$@"; }
fresh(){ rm -rf "$WORK/.hmd" "$CALLS" "$WORK/has-conflict" "$WORK/updater-ok"; }

# 1) opt-out (env + file) -> no-op, exit 0, no calls
fresh; mkcfg native false; touch "$WORK/has-conflict"
runheal env HEIMDALL_NO_SELFHEAL=1 bash "$HEAL" check; rc=$?
[ "$rc" = 0 ] && [ ! -s "$CALLS" ] && ok "opt-out env -> no-op exit 0, no repair calls" || bad "opt-out env (rc=$rc)"
fresh; mkcfg native false; touch "$WORK/has-conflict"; mkdir -p "$WORK/.hmd"; touch "$WORK/.hmd/no-selfheal"
runheal bash "$HEAL" check; [ ! -s "$CALLS" ] && ok "opt-out file -> no-op" || bad "opt-out file repaired anyway"

# 2) non-native install -> skip (never touch npm/brew managed)
fresh; mkcfg npm false; touch "$WORK/has-conflict"
runheal bash "$HEAL" --force; sleep 0.5
grep -q uninstalled "$CALLS" 2>/dev/null && bad "non-native: repaired (must skip!)" || ok "non-native install -> skipped (no repair)"

# wait for the detached repair to finish (its terminal log line), up to ~5s
waitheal(){ local L="$WORK/.hmd/cc-selfheal.log" i; for i in $(seq 1 50); do
  [ -f "$L" ] && grep -qE 'self-heal complete|nothing to repair' "$L" && return 0; sleep 0.1; done; return 0; }
LOG="$WORK/.hmd/cc-selfheal.log"

# 3) THE REPAIR: native + npm conflict + failing updater -> uninstall + autoUpdates:true + claude update
fresh; mkcfg native false; touch "$WORK/has-conflict"; touch "$WORK/updater-ok"
runheal bash "$HEAL" --force; waitheal
grep -q "uninstalled @anthropic-ai/claude-code" "$CALLS" && ok "repair: uninstalled the npm-conflict package" || bad "repair: did NOT uninstall the conflict"
[ ! -f "$WORK/has-conflict" ] && ok "repair: conflict marker cleared (idempotent next run)" || bad "conflict still present"
grep -q 'verified: claude update' "$LOG" 2>/dev/null && ok "repair: ran + verified claude update" || bad "repair: claude update not verified in log"
python3 -c "import json,sys; d=json.load(open('$WORK/claude.json')); sys.exit(0 if d.get('autoUpdates') is True else 1)" \
  && ok "repair: autoUpdates set true" || bad "repair: autoUpdates not set"
python3 -c "import json,sys; d=json.load(open('$WORK/claude.json')); sys.exit(0 if d.get('userID')=='keepme' and d.get('numStartups')==7 else 1)" \
  && ok "repair: claude.json OTHER keys preserved (atomic key-preserving edit)" || bad "repair: clobbered other keys"

# 4) idempotent on a healthy machine (native, no conflict, updater ok) -> NO repair (detection
#    may PROBE `claude update`, but it must never UNINSTALL or write a 'repaired:' log line).
fresh; mkcfg native true; touch "$WORK/updater-ok"
runheal bash "$HEAL" --force; waitheal
grep -q 'uninstalled' "$CALLS" 2>/dev/null && bad "healthy: uninstalled something (should no-op)" || ok "healthy: never uninstalls"
grep -q 'repaired:' "$LOG" 2>/dev/null && bad "healthy: logged a repair (should no-op)" || ok "healthy machine -> pure no-op (no 'repaired:' line)"
runheal bash "$HEAL" status | grep -qi healthy && ok "status: reports healthy" || bad "status wrong on healthy"

# 5) status reports unhealthy (read-only, no mutation)
fresh; mkcfg native false; touch "$WORK/has-conflict"; touch "$WORK/updater-ok"
runheal bash "$HEAL" status | grep -qi 'UNHEALTHY' && ok "status: reports UNHEALTHY w/ conflict" || bad "status missed the conflict"
[ -f "$WORK/has-conflict" ] && ok "status: read-only (did not repair)" || bad "status mutated!"

# 6) throttle: a 2nd check within the window does not re-run (stamp fresh)
fresh; mkcfg native true; touch "$WORK/updater-ok"
runheal bash "$HEAL" check; M1="$(stat -f %m "$WORK/.hmd/.cc-selfheal-stamp" 2>/dev/null||stat -c %Y "$WORK/.hmd/.cc-selfheal-stamp" 2>/dev/null)"
runheal bash "$HEAL" check; M2="$(stat -f %m "$WORK/.hmd/.cc-selfheal-stamp" 2>/dev/null||stat -c %Y "$WORK/.hmd/.cc-selfheal-stamp" 2>/dev/null)"
[ "$M1" = "$M2" ] && ok "throttle: 2nd check within window skipped (stamp unchanged)" || bad "throttle not enforced"

# 7) never blocks: check returns fast (repair is detached)
fresh; mkcfg native false; touch "$WORK/has-conflict"; touch "$WORK/updater-ok"
T0=$(python3 -c 'import time;print(int(time.time()*1000))'); runheal bash "$HEAL" check; T1=$(python3 -c 'import time;print(int(time.time()*1000))')
[ "$((T1-T0))" -lt 2000 ] && ok "check non-blocking ($((T1-T0))ms, repair detached)" || bad "check blocked ($((T1-T0))ms)"

echo "──────────────────────────────────────"
echo "heimdall-cc-selfheal: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1

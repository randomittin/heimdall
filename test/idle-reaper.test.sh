#!/usr/bin/env bash
#
# idle-reaper.test.sh — falsifiable acceptance for the IDLE-AGENT-PROCESS axis of
# bin/heimdall-reap-idle (the reaper of finished `claude --agent heimdall` background
# subprocesses that pin RAM for days). Mirrors test/sys-cleanup.test.sh exactly: synthetic
# `pid ppid pgid tty %cpu etime command…` rows fed via HEIMDALL_REAP_AGENT_PS_CMD and a
# RECORDING kill-stub via HEIMDALL_REAP_KILL_CMD — NO real process is ever signalled.
#
#   bash test/idle-reaper.test.sh    (exit 0 = all cases pass)
#
# The ONE catastrophe this axis can cause is signalling a LIVE claude — RJ's foreground
# session, or a working background agent (cc-update's whole lesson). So every fixture plants a
# proc a regression would wrongly reap, and asserts it SURVIVES:
#   · a TTY-attached FOREGROUND session is NEVER in the reap set / never signalled   (200)
#   · a CPU-active LIVE background agent is NEVER reaped                              (300)
#   · a young (not-yet-aged) detached agent is NEVER reaped                          (400)
#   · a FOREIGN (non-heimdall) detached claude / python is NEVER reaped              (500,600)
#   · the reaper's OWN session (self-exclude) is NEVER reaped — the pid-71532 case   (700)
#   · a detached but not-extreme-aged straggler with a live parent is NEVER reaped   (800)
#   · `report` (the DEFAULT, no --apply) signals NOTHING                             (case 1)
#   · a genuinely-FINISHED orphaned hmd background agent IS reaped, TERM→then→KILL    (100,101)
#   · the opt-out env fully disables the reap                                        (case 6)
#
# PROVE-RED: run with IDLE_REAPER_PROVE_RED=1 to point the reaper at a DELIBERATELY BROKEN
# oracle stub (one that emits EVERY pid on stdin — foreground, foreign, and self included). The
# scope + kill-scope cases MUST go red, proving they can fail (conventions R6). CI runs the real
# binary (green).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REAP="$REPO/bin/heimdall-reap-idle"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$REAP" ] || { echo "FATAL: $REAP not executable"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/idle-reaper-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "idle-reaper.test.sh"

# ── the oracle the reaper scopes through ─────────────────────────────────────────
# CI: the real sysmon matcher. PROVE-RED: a broken stub that emits EVERY pid on stdin (so a
# foreground / foreign / self pid leaks into the reap set) — flipping the scope assertions red.
if [ "${IDLE_REAPER_PROVE_RED:-0}" = "1" ]; then
  cat > "$WORK/sysmon-broken" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --filter-idle-agents) awk '{print $1}' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$WORK/sysmon-broken"
  export HEIMDALL_REAP_SYSMON="$WORK/sysmon-broken"
fi

# ── fixture: rich `pid ppid pgid tty %cpu etime command…` process rows ────────────
# 100/101 = FINISHED hmd background agents: orphaned (ppid 1), DETACHED (tty ??), cpu-idle, aged
#           7 days — the exact multi-day straggler → REAP TARGETS.
# 200 = a TTY-attached FOREGROUND session (tty ttys004) — never a target (owns a terminal).
# 300 = a LIVE background agent (cpu 47.0) — never a target (busy).
# 400 = a YOUNG detached agent (age 2 min < 30 min floor) — never a target (not aged).
# 500 = a FOREIGN detached claude (no heimdall marker) — never a target.
# 600 = a FOREIGN detached python — never a target.
# 700 = a perfect-shape agent that is in the reaper's OWN exclude set — never a target (self).
# 800 = a detached straggler with a LIVE parent, aged only 1h (< 3-day extreme) — never a target.
cat > "$WORK/ps-rows" <<'ROWS'
100 1 100 ?? 0.0 07-13:00:00 claude --agent heimdall --dangerously-skip-permissions --plugin-dir /Users/rj/Downloads/heimdall --append-system-prompt-file /tmp/heimdall-preamble-A
101 1 101 ?? 0.0 06-01:00:00 claude --agent heimdall --plugin-dir /Users/rj/Downloads/heimdall --append-system-prompt-file /tmp/heimdall-preamble-B
200 5683 5683 ttys004 0.0 07-00:00:00 claude --agent heimdall --plugin-dir /Users/rj/Downloads/heimdall
300 1 300 ?? 47.0 06-00:00:00 claude --agent heimdall --plugin-dir /Users/rj/Downloads/heimdall
400 1 400 ?? 0.0 00:02:00 claude --agent heimdall --plugin-dir /Users/rj/Downloads/heimdall
500 1 500 ?? 0.0 07-00:00:00 claude --agent codereview --model claude-opus-4-8
600 1 600 ?? 0.0 07-00:00:00 /usr/bin/python3 /Users/rj/work/train.py
700 1 700 ?? 0.0 07-00:00:00 claude --agent heimdall --plugin-dir /Users/rj/Downloads/heimdall
800 9999 9999 ?? 0.0 01:00:00 claude --agent heimdall --plugin-dir /Users/rj/Downloads/heimdall
ROWS
cat > "$WORK/ps-cmd" <<EOF
#!/usr/bin/env bash
cat "$WORK/ps-rows"
EOF
chmod +x "$WORK/ps-cmd"

# a recording kill-stub: logs the SIGNAL + pid it is asked to send (proves the reap SCOPE +
# TERM→KILL escalation). A `-0` liveness probe returns alive but is NOT logged.
cat > "$WORK/kill-stub" <<EOF
#!/usr/bin/env bash
sig="\${1:-}"; pid="\${2:-}"
case "\$sig" in -0) exit 0 ;; esac
echo "\$sig \$pid" >> "$WORK/killed"
exit 0
EOF
chmod +x "$WORK/kill-stub"
: > "$WORK/killed"

# an RSS-stub so the freed-MB math is deterministic (48000 kb per pid).
cat > "$WORK/rss-stub" <<'EOF'
#!/usr/bin/env bash
for _ in "$@"; do echo 48000; done
EOF
chmod +x "$WORK/rss-stub"

# run the idle-agent axis with the fixture + kill-stub + rss-stub + self-exclude(700) + grace 0.
run_reap() {
  env HEIMDALL_REAP_AGENT_PS_CMD="$WORK/ps-cmd" \
      HEIMDALL_REAP_KILL_CMD="$WORK/kill-stub" \
      HEIMDALL_REAP_RSS_CMD="$WORK/rss-stub" \
      HEIMDALL_REAP_SELF_EXCLUDE="700" \
      HEIMDALL_REAP_GRACE_SEC="0" \
      HEIMDALL_HOME="$WORK/home-empty" \
      ${HEIMDALL_REAP_SYSMON:+HEIMDALL_REAP_SYSMON="$HEIMDALL_REAP_SYSMON"} \
      bash "$REAP" "$@"
}
mkdir -p "$WORK/home-empty"

# ── 1. READ-ONLY: report (no --apply) signals NOTHING ────────────────────────────
: > "$WORK/killed"
out="$(run_reap --agents-only 2>&1)"
if [ -s "$WORK/killed" ]; then bad "report signalled a process — report MUST be read-only"
else ok "report (no --apply) signalled NOTHING (provably read-only)"; fi
grep -q "pid 100" <<<"$out" && ok "report names finished agent pid 100 as reapable" \
  || bad "report did not name the reapable agent 100"

# ── 2. SCOPE: --agents-json counts EXACTLY the 2 finished agents ─────────────────
js="$(run_reap --agents-json 2>/dev/null)"
n="$(printf '%s' "$js" | sed -n 's/.*"idle_agents":\([0-9]*\).*/\1/p')"
mb="$(printf '%s' "$js" | sed -n 's/.*"resident_mb":\([0-9]*\).*/\1/p')"
if [ "$n" = "2" ]; then ok "idle-agent scope = 2 finished agents only (100,101)"
else bad "idle-agent scope wrong — want 2, got '$n' (a foreground/foreign/self proc leaked in)"; fi
if [ "$mb" = "94" ]; then ok "freed-RSS math correct (2×48000kb → 94MB)"
else bad "freed-RSS wrong — want 94, got '$mb'"; fi

# ── 3. KILL-SCOPE: --apply signals EXACTLY 100 & 101, TERM then KILL, nothing else ─
: > "$WORK/killed"
run_reap --agents-only --apply >/dev/null 2>&1
pids_signalled="$(awk '{print $2}' "$WORK/killed" 2>/dev/null | sort -nu | tr '\n' ' ' | sed 's/ *$//')"
if [ "$pids_signalled" = "100 101" ]; then ok "reap signalled EXACTLY the 2 finished agents (got: $pids_signalled)"
else bad "reap kill-scope wrong — want '100 101' got '$pids_signalled'"; fi
for dead in 200 300 400 500 600 700 800; do
  if grep -qE " $dead\$" "$WORK/killed" 2>/dev/null; then
    case $dead in
      200) bad "FOREGROUND/TTY session $dead was signalled — the catastrophe the axis must prevent" ;;
      300) bad "LIVE (cpu-active) agent $dead was signalled — must never kill a working agent" ;;
      700) bad "SELF-excluded pid $dead was signalled — reaper killed its own session tree" ;;
      *)   bad "protected pid $dead was signalled — must never touch it" ;;
    esac
  else ok "protected pid $dead was NEVER signalled"; fi
done

# ── 4. GRACEFUL: SIGTERM precedes SIGKILL for a reaped agent ──────────────────────
term_ln="$(grep -n '^-TERM 100$' "$WORK/killed" 2>/dev/null | head -1 | cut -d: -f1)"
kill_ln="$(grep -n '^-KILL 100$' "$WORK/killed" 2>/dev/null | head -1 | cut -d: -f1)"
if [ -n "$term_ln" ] && [ -n "$kill_ln" ] && [ "$term_ln" -lt "$kill_ln" ]; then
  ok "graceful escalation: SIGTERM (line $term_ln) precedes SIGKILL (line $kill_ln) for pid 100"
else bad "escalation wrong — TERM before KILL not proven (term='$term_ln' kill='$kill_ln')"; fi

# ── 5. the FOREGROUND session survives even under --apply (headline safety) ───────
if grep -qE ' 200$' "$WORK/killed" 2>/dev/null; then
  bad "the TTY-attached foreground session (200) was signalled under --apply"
else ok "TTY-attached foreground session (200) SURVIVED --apply (owns a terminal → never a target)"; fi

# ── 6. OPT-OUT fully disables the reap (env) ─────────────────────────────────────
: > "$WORK/killed"
HEIMDALL_NO_CLEANUP=1 run_reap --agents-only --apply >/dev/null 2>&1
if [ ! -s "$WORK/killed" ]; then ok "HEIMDALL_NO_CLEANUP=1 fully disables the reap (nothing signalled)"
else bad "opt-out env ignored — reap signalled despite HEIMDALL_NO_CLEANUP=1: $(cat "$WORK/killed")"; fi
# marker-file variant
: > "$WORK/killed"; mkdir -p "$WORK/home-optout"; : > "$WORK/home-optout/no-cleanup"
env HEIMDALL_REAP_AGENT_PS_CMD="$WORK/ps-cmd" HEIMDALL_REAP_KILL_CMD="$WORK/kill-stub" \
    HEIMDALL_REAP_RSS_CMD="$WORK/rss-stub" HEIMDALL_REAP_SELF_EXCLUDE="700" \
    HEIMDALL_REAP_GRACE_SEC="0" HEIMDALL_HOME="$WORK/home-optout" \
    ${HEIMDALL_REAP_SYSMON:+HEIMDALL_REAP_SYSMON="$HEIMDALL_REAP_SYSMON"} \
    bash "$REAP" --agents-only --apply >/dev/null 2>&1
if [ ! -s "$WORK/killed" ]; then ok "~/.heimdall/no-cleanup marker fully disables the reap"
else bad "opt-out marker ignored — reap signalled despite the no-cleanup file"; fi

echo
printf 'idle-reaper: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

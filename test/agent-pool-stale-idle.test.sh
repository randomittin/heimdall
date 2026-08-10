#!/usr/bin/env bash
#
# agent-pool-stale-idle.test.sh — acceptance for STALE-IDLE reaping.
#
# The gap this closes: cmd_health_check only reaped PID-DEAD agents. A
# session-fork whose process is ALIVE but HUNG (no heartbeat, no progress)
# stayed status=="active" forever → the pool slot leaked. This test proves the
# heartbeat-threshold reap, WITHOUT any canned timing luck.
#
# Guarantees proved (hermetic — own HOME → own ~/.heimdall/agent-pool.json):
#   1. STALE-IDLE REAP — an agent with a LIVE pid (real `sleep &`) but an
#      old last_active is reaped by health-check (status→failed), EVEN THOUGH
#      its pid is alive, and its slot is freed.
#   2. REAP REASON — the reaped stale agent records a stale-idle reason (not
#      "dead pid"), and health-check prints "stale-idle".
#   3. FRESH KEPT — an agent with a fresh `beat` is NOT reaped. Falsifiable:
#      fails if a live, beating fork is wrongly reaped.
#   4. PID-DEAD STILL REAPED — the original dead-pid reap keeps working.
#
# Usage:  bash test/agent-pool-stale-idle.test.sh   (exit 0 = all hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
POOL="$REPO/bin/agent-pool"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Hermetic home → agent-pool resolves POOL_FILE under here.
HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-pool-stale.XXXXXX")"
POOL_FILE="$HOME_DIR/.heimdall/agent-pool.json"
BG_PIDS=()

cleanup() {
  for p in "${BG_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
  rm -rf "$HOME_DIR"
}
trap cleanup EXIT

# Run agent-pool against the hermetic HOME.
ap() { HOME="$HOME_DIR" HMD_AGENT_STALE_SECS="${HMD_AGENT_STALE_SECS:-900}" python3 "$POOL" "$@"; }
# Read a field from an agent entry via jq.
field() { jq -r --arg a "$1" ".agents[\$a].$2 // \"\"" "$POOL_FILE"; }

echo "agent-pool stale-idle harness  home=$HOME_DIR"
echo "--------------------------------------------------------------------"

ap init --max 10 --min 1 >/dev/null

# ── Spawn three REAL live background pids ────────────────────────────────────
sleep 300 & PID_STALE=$!;  BG_PIDS+=("$PID_STALE")
sleep 300 & PID_FRESH=$!;  BG_PIDS+=("$PID_FRESH")
sleep 300 & PID_DEAD=$!;   BG_PIDS+=("$PID_DEAD")

ap acquire stale  fork --pid "$PID_STALE" >/dev/null
ap acquire fresh  fork --pid "$PID_FRESH" >/dev/null
ap acquire dead   fork --pid "$PID_DEAD"  >/dev/null

# Age `stale`'s heartbeat far into the past (alive pid, no beat).
OLD_TS="2000-01-01T00:00:00+00:00"
tmp="$(mktemp)"
jq --arg t "$OLD_TS" '.agents.stale.last_active=$t' "$POOL_FILE" >"$tmp" && mv "$tmp" "$POOL_FILE"

# `fresh` proves liveness via a real beat.
ap beat fresh >/dev/null

# Kill `dead`'s process so its pid is gone (the classic reap path).
kill "$PID_DEAD" 2>/dev/null; wait "$PID_DEAD" 2>/dev/null

# ── Run health-check (default 900s threshold) ────────────────────────────────
active_before="$(ap active | sort | tr '\n' ',' )"
HC_OUT="$(ap health-check)"
echo "  health-check: $HC_OUT"

# 1. STALE-IDLE REAP — stale is failed, pid still alive.
if kill -0 "$PID_STALE" 2>/dev/null && [ "$(field stale status)" = "failed" ]; then
  ok "stale-idle agent reaped (status=failed) while its pid is STILL alive"
else
  bad "stale agent not reaped or pid unexpectedly dead (status=$(field stale status))"
fi

# 2. REAP REASON is stale-idle, not dead pid.
if grep -q "stale-idle" <<<"$(field stale reap_reason)" \
   && grep -q "stale-idle" <<<"$HC_OUT"; then
  ok "reap reason is stale-idle (distinct from dead pid)"
else
  bad "stale reap reason missing: entry='$(field stale reap_reason)' out='$HC_OUT'"
fi

# 3. FRESH KEPT — beating fork stays active.
if [ "$(field fresh status)" = "active" ]; then
  ok "fresh (beating) agent NOT reaped — stays active"
else
  bad "fresh agent wrongly reaped (status=$(field fresh status))"
fi

# 4. PID-DEAD STILL REAPED.
if [ "$(field dead status)" = "failed" ] && grep -q "dead pid" <<<"$HC_OUT"; then
  ok "pid-dead agent still reaped (dead pid)"
else
  bad "pid-dead reap regressed (status=$(field dead status))"
fi

# 5. SLOT FREED — only fresh remains active; reaped agents freed their slots.
active_after="$(ap active | sort | tr '\n' ',')"
if [ "$active_after" = "fresh," ]; then
  ok "reaped agents freed their slots — active=[$active_after] (was [$active_before])"
else
  bad "slots not freed correctly — active=[$active_after]"
fi

# 6. THRESHOLD=0 boundary — a just-beaten agent with a tiny sleep is stale.
sleep 300 & PID_ZERO=$!; BG_PIDS+=("$PID_ZERO")
ap acquire zero fork --pid "$PID_ZERO" >/dev/null
sleep 1
if HMD_AGENT_STALE_SECS=0 ap health-check | grep -q "stale-idle" \
   && [ "$(field zero status)" = "failed" ]; then
  ok "HMD_AGENT_STALE_SECS=0 reaps a >0s-idle live agent"
else
  bad "threshold=0 did not reap idle live agent (status=$(field zero status))"
fi

echo "--------------------------------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
#
# agent-pool-memory-limit.test.sh — falsifiable coverage for the memory-aware
# SECOND, independent cap wired into cmd_acquire: bin/agent-pool now
# additionally consults bin/heimdall-memory-budget's slot count (opt-in via
# HMD_AGENT_POOL_MEMORY_GATE) so a spawn can be refused when host RAM is tight
# EVEN THOUGH the existing count-based max_agents cap has not been reached.
#
# THE GAP THIS CLOSES: max_agents is a bare count, blind to host memory. This
# proves the WIRING, not the underlying tool (that has its own 28-assertion
# suite in test/heimdall-memory-budget.test.sh):
#
#   A. gate OFF (default) -> acquire behaves EXACTLY as before, even under
#      simulated near-zero memory. "Opt-in, no regression" proof.
#   B. gate ON, memory NOT the binding constraint (slots >= max_agents) ->
#      acquire is still governed by the count cap alone; memory never fires.
#   C. gate ON, memory IS the binding constraint (slots < max_agents) ->
#      acquire is refused at the MEMORY boundary, strictly before max_agents
#      is reached — the effective cap is min(max_agents, memory slots).
#   D. FAIL OPEN: an otherwise-identical tight-memory fixture that WOULD
#      refuse at slots=0 stops refusing the instant memory becomes
#      unmeasurable (HMD_MEM_SIMULATE_UNMEASURABLE=1) — one flag flipped,
#      isolating cause from effect.
#   E. FAIL OPEN: heimdall-memory-budget entirely absent (a bare copy of
#      agent-pool with no sibling binary) -> acquire still succeeds,
#      mirroring test/agent-pool-pressure.test.sh's own c2 case for the
#      unrelated pressure cap.
#   F. "0" / "false" are treated as disabled, matching HMD_AGENT_STALE_SECS's
#      own falsy-string precedent.
#   G. the memory-refusal path leaves stdout byte-empty AND never registers
#      the agent (active count stays 0) — refusal happens before mutation.
#
# HERMETIC: every case gets its own mktemp HOME (agent-pool.json lands under
# $HOME/.heimdall/, exactly like test/agent-pool-stale-idle.test.sh and
# test/agent-pool-pressure.test.sh). HMD_MEM_* overrides make this
# independent of the real host's memory entirely — see
# test/heimdall-memory-budget.test.sh for that tool's own contract.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
POOL="$REPO/bin/agent-pool"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

fresh_home() { mktemp -d "${TMPDIR:-/tmp}/agent-pool-memlimit-test.XXXXXX"; }
pool() { python3 "$POOL" "$@"; }

reset_mem_env() {
  unset HMD_AGENT_POOL_MEMORY_GATE HMD_MEM_TOTAL_MB HMD_MEM_AVAILABLE_MB \
        HMD_MEM_PER_AGENT_MB HMD_MEM_RESERVE_PCT HMD_MEM_SIMULATE_UNMEASURABLE \
        2>/dev/null || true
}

# fill_n N prefix -- acquire N agents "prefix-0".."prefix-(N-1)", silently.
fill_n() {
  n="$1"; prefix="$2"; i=0
  while [ "$i" -lt "$n" ]; do
    pool acquire "$prefix-$i" worker --pid $$ >/dev/null 2>/dev/null
    i=$((i+1))
  done
}

echo "agent-pool-memory-limit harness"
echo "--------------------------------------------------------------------"

# ── A. gate OFF (default) -> unaffected even under simulated near-zero memory ─
export HOME; HOME="$(fresh_home)"
reset_mem_env
export HMD_MEM_AVAILABLE_MB=1 HMD_MEM_PER_AGENT_MB=100 HMD_MEM_RESERVE_PCT=0.8   # would be 0 slots if consulted
pool init --max 3 >/dev/null
fill_n 3 agent
out="$(pool acquire agent-3 worker --pid $$ 2>"$HOME/err.log")"; rc=$?
err="$(cat "$HOME/err.log")"
[ "$rc" -eq 2 ] && [ -z "$out" ] && grep -q "At capacity" <<<"$err" \
  && ok "A. gate OFF -> tight simulated memory has NO effect; still governed by count cap alone" \
  || bad "A. rc=$rc out='$out' err='$err'"

# ── B. gate ON, memory NOT binding (slots >= max_agents) -> count cap governs ─
export HOME; HOME="$(fresh_home)"
reset_mem_env
export HMD_AGENT_POOL_MEMORY_GATE=1
export HMD_MEM_AVAILABLE_MB=100000 HMD_MEM_PER_AGENT_MB=1 HMD_MEM_RESERVE_PCT=1.0  # huge slots
pool init --max 3 >/dev/null
fill_n 3 agent
out="$(pool acquire agent-3 worker --pid $$ 2>"$HOME/err.log")"; rc=$?
err="$(cat "$HOME/err.log")"
[ "$rc" -eq 2 ] && [ -z "$out" ] && grep -q "At capacity" <<<"$err" && ! grep -q "memory" <<<"$err" \
  && ok "B. gate ON but memory not binding -> refusal reason is still the plain count message" \
  || bad "B. rc=$rc out='$out' err='$err'"

# ── C. gate ON, memory IS binding (slots < max_agents) -> refused at the
#      memory boundary, strictly before max_agents ───────────────────────────
export HOME; HOME="$(fresh_home)"
reset_mem_env
export HMD_AGENT_POOL_MEMORY_GATE=1
export HMD_MEM_AVAILABLE_MB=250 HMD_MEM_PER_AGENT_MB=100 HMD_MEM_RESERVE_PCT=0.8   # budget=200 -> slots=2
pool init --max 10 >/dev/null
o0="$(pool acquire agent-0 worker --pid $$ 2>/dev/null)"; r0=$?
o1="$(pool acquire agent-1 worker --pid $$ 2>/dev/null)"; r1=$?
[ "$r0" -eq 0 ] && [ "$r1" -eq 0 ] \
  && ok "C1. first 2 acquires (== memory slots) succeed" \
  || bad "C1. r0=$r0 r1=$r1 o0='$o0' o1='$o1'"
out="$(pool acquire agent-2 worker --pid $$ 2>"$HOME/err.log")"; rc=$?
err="$(cat "$HOME/err.log")"
[ "$rc" -eq 2 ] && [ -z "$out" ] && grep -q "At memory capacity (slots=2, active=2)" <<<"$err" \
  && ok "C2. 3rd acquire refused at the MEMORY boundary (slots=2), 8 short of max_agents=10" \
  || bad "C2. rc=$rc out='$out' err='$err'"
active="$(pool active | wc -l | tr -d ' ')"
[ "$active" -eq 2 ] && ok "C3. active count stayed at 2 -- effective cap == min(10, 2) == 2" \
  || bad "C3. active=$active"

# ── D. FAIL OPEN: same tight fixture, but HMD_MEM_SIMULATE_UNMEASURABLE flips
#      the outcome (one flag, isolates cause from effect) ────────────────────
export HOME; HOME="$(fresh_home)"
reset_mem_env
export HMD_AGENT_POOL_MEMORY_GATE=1
export HMD_MEM_AVAILABLE_MB=0 HMD_MEM_PER_AGENT_MB=100 HMD_MEM_RESERVE_PCT=0.8   # slots=0 -> D1 blocks immediately
pool init --max 10 >/dev/null
out="$(pool acquire agent-0 worker --pid $$ 2>"$HOME/err.log")"; rc=$?
err="$(cat "$HOME/err.log")"
[ "$rc" -eq 2 ] && [ -z "$out" ] && grep -q "At memory capacity (slots=0, active=0)" <<<"$err" \
  && ok "D1. control: slots=0 refuses the very first acquire" \
  || bad "D1. rc=$rc out='$out' err='$err'"

export HOME; HOME="$(fresh_home)"
export HMD_MEM_SIMULATE_UNMEASURABLE=1   # same HMD_MEM_* numbers still exported; this one flag added
pool init --max 10 >/dev/null
out="$(pool acquire agent-0 worker --pid $$ 2>"$HOME/err.log")"; rc=$?
err="$(cat "$HOME/err.log")"
[ "$rc" -eq 0 ] && grep -q "Acquired: agent-0" <<<"$out" \
  && ok "D2. same tight numbers, but HMD_MEM_SIMULATE_UNMEASURABLE=1 -> fails OPEN, acquire succeeds" \
  || bad "D2. rc=$rc out='$out' err='$err'"

# ── E. FAIL OPEN: heimdall-memory-budget entirely absent ─────────────────────
export HOME; HOME="$(fresh_home)"
reset_mem_env
export HMD_AGENT_POOL_MEMORY_GATE=1
export HMD_MEM_AVAILABLE_MB=0 HMD_MEM_PER_AGENT_MB=100 HMD_MEM_RESERVE_PCT=0.8   # would refuse if the binary existed
NOLIB_DIR="$(fresh_home)"
cp "$POOL" "$NOLIB_DIR/agent-pool"
pool init --max 10 >/dev/null
out="$(python3 "$NOLIB_DIR/agent-pool" acquire agent-0 worker --pid $$ 2>"$HOME/err2.log")"; rc=$?
err="$(cat "$HOME/err2.log")"
[ "$rc" -eq 0 ] && grep -q "Acquired: agent-0" <<<"$out" && [ -z "$(grep -i traceback "$HOME/err2.log")" ] \
  && ok "E. heimdall-memory-budget binary entirely missing -> fails OPEN, acquire succeeds" \
  || bad "E. rc=$rc out='$out' err='$err'"

# ── F. "0" / "false" are treated as disabled ──────────────────────────────────
export HOME; HOME="$(fresh_home)"
reset_mem_env
export HMD_MEM_AVAILABLE_MB=0 HMD_MEM_PER_AGENT_MB=100 HMD_MEM_RESERVE_PCT=0.8   # would refuse if the gate were on
pool init --max 10 >/dev/null
export HMD_AGENT_POOL_MEMORY_GATE=0
out0="$(pool acquire agent-0 worker --pid $$ 2>/dev/null)"; rc0=$?
export HMD_AGENT_POOL_MEMORY_GATE=false
out1="$(pool acquire agent-1 worker --pid $$ 2>/dev/null)"; rc1=$?
[ "$rc0" -eq 0 ] && [ "$rc1" -eq 0 ] \
  && ok "F. HMD_AGENT_POOL_MEMORY_GATE=0/false both treated as disabled (matches HMD_AGENT_STALE_SECS falsy precedent)" \
  || bad "F. rc0=$rc0 rc1=$rc1 out0='$out0' out1='$out1'"

# ── G. memory-refusal path: stdout byte-empty AND the agent is never
#      registered (refusal happens before any pool mutation) ─────────────────
export HOME; HOME="$(fresh_home)"
reset_mem_env
export HMD_AGENT_POOL_MEMORY_GATE=1
export HMD_MEM_AVAILABLE_MB=0 HMD_MEM_PER_AGENT_MB=100 HMD_MEM_RESERVE_PCT=0.8
pool init --max 10 >/dev/null
out="$(pool acquire agent-0 worker --pid $$ 2>/dev/null)"; rc=$?
active="$(pool active | wc -l | tr -d ' ')"
[ "$rc" -eq 2 ] && [ -z "$out" ] && [ "$active" -eq 0 ] \
  && ok "G. memory-refusal: stdout byte-empty AND agent never registered (active count stays 0)" \
  || bad "G. rc=$rc out='$out' active=$active"

echo "--------------------------------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

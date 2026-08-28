#!/usr/bin/env bash
#
# heimdall-memory-budget.test.sh — acceptance for the memory-aware agent-spawn cap.
#
# THE GAP THIS CLOSES: agent-pool's existing limit is a bare COUNT (`max_agents`). On a
# memory-tight machine a count-based limit alone is blind — it will happily "acquire" a
# 6th agent even when the box has 1.7GB free and each agent needs ~450MB, and the 6th
# spawn starts swapping. This suite proves bin/heimdall-memory-budget's arithmetic:
#   budget_mb = floor(available_mb * reserve_pct); slots = floor(budget_mb / per_agent_mb)
# where available_mb is what is GENUINELY free (free+inactive+speculative+purgeable on
# macOS; MemAvailable directly on Linux) — NOT total, and NOT total-minus-used naively.
#
# Guarantees proved (hermetic — every HMD_MEM_* var is set EXPLICITLY on every call via
# the mb() helper below, so no assertion can leak state into the next):
#   A. the owner's worked example arithmetic (budget + slots), asserted as EXACT numbers.
#   B. zero/near-zero available -> slots 0, can-spawn refuses.
#   C. can-spawn --count boundary: exact fit passes, one more fails.
#   D. reserve pct is honoured (changing it changes the budget).
#   E. stdout-purity contract: slots is empty-or-numeric, can-spawn is ALWAYS empty.
#   F. fail-open: an unmeasurable host does NOT block spawning, but DOES warn on stderr.
#   G. the macOS page-size trap: the parser must use vm_stat's REPORTED page size (this
#      fixture uses 8192, deliberately not 4096 and not 16384) or the arithmetic is wrong
#      by a clean, checkable factor.
#   H. (bonus) the per-agent estimate persists as a ROLLING HIGH-WATER MARK (grows when a
#      bigger agent is observed, never drops back down on a smaller sample — "max, not
#      mean" from the spec) and a corrupt state file never breaks the CLI.
#   I. (bonus) the Linux /proc/meminfo path uses MemAvailable directly.
#
# Usage:  bash test/heimdall-memory-budget.test.sh   (exit 0 = all hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-memory-budget"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$BIN" ] || { echo "FATAL: $BIN not executable (or missing)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required for this suite"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-mem-budget.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# jf JSON KEY — extract one key from a JSON blob via python3 (no jq dependency here).
jf() { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"$2\"])" 2>/dev/null; }

# Every HMD_MEM_* var the CLI understands, reset to empty before each section so a
# previous section's fixture can NEVER leak into the next one's assertions.
reset_vars() {
  TOTAL=""; AVAILABLE=""; PER_AGENT=""; RESERVE=""; SIMULATE=""
  FORCE_PLATFORM=""; VMSTAT_RAW=""; MEMINFO_FILE=""; PS_ROWS_FILE=""; STATE_FILE=""
}

# mb SUBCOMMAND [ARGS...] — invoke $BIN with the full, explicit override environment.
mb() {
  HMD_MEM_TOTAL_MB="${TOTAL:-}" \
  HMD_MEM_AVAILABLE_MB="${AVAILABLE:-}" \
  HMD_MEM_PER_AGENT_MB="${PER_AGENT:-}" \
  HMD_MEM_RESERVE_PCT="${RESERVE:-}" \
  HMD_MEM_SIMULATE_UNMEASURABLE="${SIMULATE:-}" \
  HMD_MEM_PLATFORM="${FORCE_PLATFORM:-}" \
  HMD_MEM_VMSTAT_RAW="${VMSTAT_RAW:-}" \
  HMD_MEM_PROC_MEMINFO="${MEMINFO_FILE:-}" \
  HMD_MEM_PS_ROWS="${PS_ROWS_FILE:-}" \
  HMD_MEM_STATE_FILE="${STATE_FILE:-}" \
  "$BIN" "$@"
}

echo "heimdall-memory-budget harness  work=$WORK"
echo "--------------------------------------------------------------------"

# ── A. owner's worked example: total=16384 avail=6144 reserve=0.80 per_agent=983 ──────
echo "== A: worked example arithmetic =="
reset_vars
TOTAL=16384; AVAILABLE=6144; PER_AGENT=983; RESERVE=0.80
js="$(mb status --json)"
budget_mb="$(jf "$js" budget_mb)"
if [ "$budget_mb" = "4915" ]; then
  ok "budget_mb == 4915 (80% of 6144, truncated) — got $budget_mb"
else
  bad "budget_mb expected 4915, got '$budget_mb' (raw: $js)"
fi
slots="$(mb slots)"
if [ "$slots" = "5" ]; then
  ok "slots == 5 (floor(4915/983), exact) — got $slots"
else
  bad "slots expected 5, got '$slots'"
fi

# ── B. zero / near-zero available -> slots 0, can-spawn refuses ──────────────────────
echo "== B: zero/near-zero available =="
reset_vars
TOTAL=16384; AVAILABLE=0; PER_AGENT=450; RESERVE=0.80
slots="$(mb slots)"
[ "$slots" = "0" ] && ok "available=0 -> slots=0 (got $slots)" || bad "available=0 -> expected slots 0, got '$slots'"
out="$(mb can-spawn 2>"$WORK/b1.err")"; rc=$?
[ "$rc" -eq 1 ] && ok "available=0 -> can-spawn exits 1 (got $rc)" || bad "available=0 -> expected exit 1, got $rc"
[ -z "$out" ] && ok "available=0 -> can-spawn stdout empty" || bad "available=0 -> can-spawn stdout not empty: '$out'"
[ -s "$WORK/b1.err" ] && ok "available=0 -> can-spawn printed a reason to stderr" || bad "available=0 -> no stderr reason"

reset_vars
TOTAL=16384; AVAILABLE=1; PER_AGENT=450; RESERVE=0.80
slots="$(mb slots)"
[ "$slots" = "0" ] && ok "available=1 (near-zero) -> slots=0 (got $slots)" || bad "available=1 -> expected slots 0, got '$slots'"
mb can-spawn >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "available=1 -> can-spawn exits 1" || bad "available=1 -> expected exit 1, got $rc"

# ── C. can-spawn --count boundary (slots=5 fixture, reused from A) ───────────────────
echo "== C: can-spawn --count boundary =="
reset_vars
TOTAL=16384; AVAILABLE=6144; PER_AGENT=983; RESERVE=0.80
out="$(mb can-spawn --count 5 2>"$WORK/c1.err")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "count=5 exactly fits -> exit 0, stdout empty" \
  || bad "count=5 expected exit0/empty, got rc=$rc out='$out' err='$(cat "$WORK/c1.err")'"
out="$(mb can-spawn --count 6 2>"$WORK/c2.err")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && ok "count=6 (one more than fits) -> exit 1, stdout empty" \
  || bad "count=6 expected exit1/empty, got rc=$rc out='$out'"
[ -s "$WORK/c2.err" ] && ok "count=6 refusal reason present on stderr" || bad "count=6 missing stderr reason"

# ── D. reserve pct is honoured ────────────────────────────────────────────────────────
echo "== D: reserve pct changes budget =="
reset_vars
TOTAL=16384; AVAILABLE=6144; PER_AGENT=983; RESERVE=0.50
budget_mb="$(jf "$(mb status --json)" budget_mb)"
[ "$budget_mb" = "3072" ] && ok "reserve=0.50 -> budget=3072 (got $budget_mb)" \
  || bad "reserve=0.50 expected budget 3072, got '$budget_mb'"
[ "$budget_mb" != "4915" ] && ok "budget genuinely differs from the reserve=0.80 case" \
  || bad "budget did not change when reserve pct changed"

# ── E. stdout-purity contract ─────────────────────────────────────────────────────────
echo "== E: stdout purity (refusal path) =="
reset_vars
TOTAL=16384; AVAILABLE=0; PER_AGENT=450; RESERVE=0.80
s_out="$(mb slots)"
if [[ -z "$s_out" || "$s_out" =~ ^[0-9]+$ ]]; then
  ok "slots stdout is empty-or-numeric: '$s_out'"
else
  bad "slots stdout contains prose: '$s_out'"
fi
cs_out="$(mb can-spawn 2>/dev/null)"
[ -z "$cs_out" ] && ok "can-spawn stdout is empty on the refusal path" || bad "can-spawn stdout leaked prose: '$cs_out'"

# ── F. fail-open on unmeasurable memory ───────────────────────────────────────────────
echo "== F: fail-open =="
reset_vars
SIMULATE=1
out="$(mb can-spawn --count 100 2>"$WORK/f1.err")"; rc=$?
[ "$rc" -eq 0 ] && ok "unmeasurable -> can-spawn exits 0 (fails OPEN), got $rc" || bad "unmeasurable -> expected exit 0, got $rc"
[ -z "$out" ] && ok "unmeasurable -> can-spawn stdout still empty" || bad "unmeasurable -> can-spawn stdout not empty: '$out'"
[ -s "$WORK/f1.err" ] && ok "unmeasurable -> can-spawn warns on stderr" || bad "unmeasurable -> can-spawn produced no stderr warning"

s_out="$(mb slots 2>"$WORK/f2.err")"
if [[ "$s_out" =~ ^[0-9]+$ ]] && [ "$s_out" -gt 1000 ]; then
  ok "unmeasurable -> slots reports a large no-cap sentinel: $s_out"
else
  bad "unmeasurable -> slots expected a large sentinel, got '$s_out'"
fi
[ -s "$WORK/f2.err" ] && ok "unmeasurable -> slots warns on stderr" || bad "unmeasurable -> slots produced no stderr warning"

js="$(mb status --json 2>/dev/null)"
measured="$(jf "$js" measured)"
[ "$measured" = "False" ] && ok "unmeasurable -> status --json reports measured:false" || bad "unmeasurable -> status measured flag wrong: '$measured' (raw: $js)"

# ── G. the macOS page-size trap ───────────────────────────────────────────────────────
echo "== G: macOS page-size trap (8192, neither 4096 nor 16384) =="
reset_vars
FORCE_PLATFORM="darwin"
TOTAL=16384
VMSTAT_RAW="$(cat <<'VMEOF'
Mach Virtual Memory Statistics: (page size of 8192 bytes)
Pages free:                               1000.
Pages active:                             2000.
Pages inactive:                            500.
Pages speculative:                         100.
Pages throttled:                             0.
Pages wired down:                         3000.
Pages purgeable:                            50.
VMEOF
)"
avail_mb="$(jf "$(mb status --json)" available_mb)"
# (1000+500+100+50) pages * 8192 bytes / 1048576 = 12 (truncated). A hardcoded-4096
# implementation would answer 6 instead — a clean, checkable, falsifiable divergence.
if [ "$avail_mb" = "12" ]; then
  ok "available_mb == 12 using the REPORTED page size 8192 (not a hardcoded 4096) — got $avail_mb"
else
  bad "page-size trap: expected 12, got '$avail_mb' (a hardcoded-4096 bug would yield 6)"
fi

# ── H. (bonus) rolling per-agent estimate + corrupt-state-file safety ────────────────
echo "== H (bonus): per-agent estimate is a rolling high-water mark =="
reset_vars
STATE_FILE="$WORK/state.json"
PS_ROWS_FILE="$WORK/ps.txt"
TOTAL=16384; AVAILABLE=6144; RESERVE=0.80
printf '100000 claude\n200000 claude\n9999999 chrome\n' > "$PS_ROWS_FILE"
# max claude RSS = 200000kb = 195mb, below the 450 floor, and chrome must be EXCLUDED
# (9999999kb would dominate everything if the "claude" filter were broken).
est1="$(jf "$(mb status --json)" per_agent_mb)"
[ "$est1" = "450" ] && ok "sample below floor, non-claude excluded -> estimate == floor 450 (got $est1)" \
  || bad "expected 450, got '$est1'"

printf '900000 claude\n50000 claude\n' > "$PS_ROWS_FILE"
est2="$(jf "$(mb status --json)" per_agent_mb)"
[ "$est2" = "878" ] && ok "bigger agent observed (900000kb) -> estimate RISES to 878, using MAX not mean (got $est2)" \
  || bad "expected 878, got '$est2'"

printf '10000 claude\n' > "$PS_ROWS_FILE"
est3="$(jf "$(mb status --json)" per_agent_mb)"
[ "$est3" = "878" ] && ok "smaller sample afterward -> estimate STAYS at high-water mark 878, not re-lowered (got $est3)" \
  || bad "expected estimate to remain 878, got '$est3'"

echo 'not-json-at-all{{{' > "$STATE_FILE"
out="$(mb status --json 2>"$WORK/h.err")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
  ok "corrupt state file -> CLI still exits 0 with valid JSON (never crashes)"
else
  bad "corrupt state file broke the CLI: rc=$rc out='$out'"
fi

# ── I. (bonus) Linux /proc/meminfo path uses MemAvailable directly ───────────────────
echo "== I (bonus): Linux MemAvailable path =="
reset_vars
FORCE_PLATFORM="linux"
MEMINFO_FILE="$WORK/meminfo.txt"
cat > "$MEMINFO_FILE" <<'MEMEOF'
MemTotal:       16777216 kB
MemFree:         1000000 kB
MemAvailable:    6291456 kB
Buffers:          200000 kB
Cached:           900000 kB
SwapTotal:              0 kB
SwapFree:               0 kB
MEMEOF
PER_AGENT=450; RESERVE=0.80
js="$(mb status --json)"
total_mb="$(jf "$js" total_mb)"
avail_mb="$(jf "$js" available_mb)"
[ "$total_mb" = "16384" ] && ok "linux MemTotal 16777216kB -> total_mb 16384 (got $total_mb)" \
  || bad "expected total_mb 16384, got '$total_mb'"
[ "$avail_mb" = "6144" ] && ok "linux MemAvailable 6291456kB used DIRECTLY -> available_mb 6144 (got $avail_mb)" \
  || bad "expected available_mb 6144, got '$avail_mb'"

echo "--------------------------------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

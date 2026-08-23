#!/usr/bin/env bash
#
# reboot-advisor.test.sh — acceptance for the HONEST memory advisory in
# bin/heimdall-cleanup. RJ's ask: when memory pressure is high but the cause is NOT
# heimdall, SAY SO — never let the user infer hmd is the hog. This suite covers the
# ATTRIBUTION half; test/wired-holder-advisory.test.sh covers the REMEDY half (a reboot is
# a temporary reclaim, not the fix — name the persistent holder instead).
#
#   bash test/reboot-advisor.test.sh    (exit 0 = all cases pass)
#
# THE PROPERTIES, each planted with a fixture a regression flips:
#   · high memory pressure + hmd CLEAN  → the report AND --advise emit a memory
#     advisory that EXPLICITLY states this is NOT heimdall                    (cases 1,2,5)
#   · the cited swap%/wired figures MATCH the fixture's readings (no bare claim), and the
#     hmd MB figure is scoped to the AXIS that measured it (memory is not disk)  (case 3)
#   · low pressure → NO reboot nag (non-spammy on a healthy machine)             (case 4)
#   · high pressure + an hmd python LEAK → recommend --apply FIRST, then reboot  (case 6)
#   · the opt-out (env + marker) fully silences the --advise path                (case 7)
#   · `report` mutates NOTHING while emitting the recommendation (read-only)     (case 8)
#   · PROVE-RED: crank the reboot thresholds so the SAME high fixture is NOT
#     flagged → the "advisory emitted" assertion goes RED, proving it can fail   (case 9)
#
# Memory grading is driven deterministically through a FAKE sysmon (HMD_CLEANUP_SYSMON)
# that emits a crafted --json, with the memory path pinned via HMD_CLEANUP_OS=Darwin so
# the suite is identical on macOS and Linux. No real process is signalled; the real
# ~/.heimdall and gc roots are never touched (every path is a temp fixture).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLEAN="$REPO/bin/heimdall-cleanup"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$CLEAN" ] || { echo "FATAL: $CLEAN not executable"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reboot-advisor-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "reboot-advisor.test.sh"

# ── a FAKE sysmon: crafted --json (memory grade) + orphan scope from an env list ──
cat > "$WORK/sysmon-fake" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --json)            cat "$SYSMON_JSON" ;;
  --filter-orphans)  [ -n "${SYSMON_ORPHANS:-}" ] && printf '%s\n' $SYSMON_ORPHANS || true ;;
  --reap-hmd-orphans) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/sysmon-fake"

# a FAKE dead-code advisor: bin/heimdall-cleanup's do_advise() fires heimdall-deadcode
# --advise unconditionally (outside the memory gate — CODE and RAM are independent axes),
# so a real, dirty repo's dead-code findings would otherwise leak into what must be silent,
# healthy-machine output. A clean audit prints nothing and exits 0 — this fixture mirrors
# exactly that "nothing to report" state via the HMD_CLEANUP_DEADCODE seam.
cat > "$WORK/deadcode-fake" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/deadcode-fake"

# gc roots: EMPTY, so hmd-reclaimable is ~0MB (the "tiny hmd footprint" the message cites).
GTMP="$WORK/gctmp-empty"; GVER="$WORK/versions-none"; mkdir -p "$GTMP"
: > "$WORK/killed"
cat > "$WORK/kill-stub" <<KEOF
#!/usr/bin/env bash
for p in "\$@"; do echo "\$p" >> "$WORK/killed"; done
exit 0
KEOF
chmod +x "$WORK/kill-stub"

# crafted memory grades. NOTE: memory.status is "warn" (not "crit") on purpose — the reboot
# decision must rest on the NUMERIC swap/wired thresholds (what case 9 can suppress), not on a
# pre-baked crit grade. swap 95% / wired 85% are genuinely-high; low is a healthy machine.
JSON_HIGH="$WORK/json-high"
cat > "$JSON_HIGH" <<'EOF'
{"severity":"warn","disk":{"status":"ok","used_pct":50,"free_bytes":0,"total_bytes":0},"memory":{"status":"warn","swap_used_pct":95,"swap_used_g":16.0,"swap_total_g":17.0,"wired_pct":85,"free_pct":2},"procs":{"status":"ok","hmd_orphans":0,"python3_total":1,"runaway":"","runaway_n":0}}
EOF
JSON_LOW="$WORK/json-low"
cat > "$JSON_LOW" <<'EOF'
{"severity":"ok","disk":{"status":"ok","used_pct":40,"free_bytes":0,"total_bytes":0},"memory":{"status":"ok","swap_used_pct":5,"swap_used_g":0.4,"swap_total_g":8.0,"wired_pct":22,"free_pct":40},"procs":{"status":"ok","hmd_orphans":0,"python3_total":1,"runaway":"","runaway_n":0}}
EOF

# run the orchestrator with the fake sysmon + empty gc roots + a pinned Darwin memory path.
# $1 = json fixture, $2 = orphan pid list (space-sep, may be empty), rest = cleanup argv.
run_clean() {
  local json="$1" orphans="$2"; shift 2
  HMD_CLEANUP_OS=Darwin HMD_CLEANUP_SYSMON="$WORK/sysmon-fake" \
  HMD_CLEANUP_KILL_CMD="$WORK/kill-stub" \
  HMD_CLEANUP_DEADCODE="$WORK/deadcode-fake" \
  SYSMON_JSON="$json" SYSMON_ORPHANS="$orphans" \
  HMD_GC_TMP_ROOTS="$GTMP" HMD_GC_TEMP_TTL_MIN=99999 HMD_GC_CC_VERSIONS="$GVER" \
  HEIMDALL_HOME="$WORK/home-empty" \
  bash "$CLEAN" --repo "$WORK/home-empty" "$@"
}
mkdir -p "$WORK/home-empty"

# reboot thresholds can be cranked for the PROVE-RED case; default = production 80/80.
REBOOT_ENV=""
[ "${REBOOT_PROVE_RED:-0}" = "1" ] && REBOOT_ENV="HMD_CLEANUP_REBOOT_SWAP_PCT=999 HMD_CLEANUP_REBOOT_WIRED_PCT=999"

# helper: run report on the high fixture (hmd clean) under the current threshold env.
report_high_clean() { env $REBOOT_ENV bash -c '
  HMD_CLEANUP_OS=Darwin HMD_CLEANUP_SYSMON="'"$WORK"'/sysmon-fake" \
  SYSMON_JSON="'"$JSON_HIGH"'" SYSMON_ORPHANS="" \
  HMD_GC_TMP_ROOTS="'"$GTMP"'" HMD_GC_TEMP_TTL_MIN=99999 HMD_GC_CC_VERSIONS="'"$GVER"'" \
  HEIMDALL_HOME="'"$WORK"'/home-empty" \
  bash "'"$CLEAN"'" report --repo "'"$WORK"'/home-empty" 2>&1'; }

# ── 1. high pressure + hmd clean → report emits a reboot recommendation ───────────
out="$(report_high_clean)"
grep -qi 'reboot' <<<"$out" && ok "report emits a reboot recommendation under high memory pressure" \
  || bad "report did NOT recommend a reboot despite swap 95% / wired 85%"

# ── 2. ATTRIBUTION HONESTY: it EXPLICITLY says this is NOT heimdall ───────────────
if grep -qi 'NOT heimdall' <<<"$out" && grep -qi 'no hmd python leak' <<<"$out"; then
  ok "report explicitly attributes the pressure AWAY from heimdall (NOT heimdall · no hmd leak)"
else
  bad "report failed to say hmd is NOT the cause — the user could infer hmd is the hog"
fi
grep -qi 'cannot free kernel-wired memory' <<<"$out" \
  && ok "report states hmd cannot free kernel-wired memory (honest limit of its reach)" \
  || bad "report omitted the honest 'cannot free kernel-wired memory' limit"

# ── 3. TRUTH-PASS: the cited swap%/wired figures MATCH the fixture readings ───────
if grep -q '95%' <<<"$out" && grep -q 'wired 85%' <<<"$out" \
   && grep -q '16.0G/17.0G' <<<"$out"; then
  ok "cited numbers match the fixture (swap 16.0G/17.0G=95%, wired 85%) — no bare claim"
else
  bad "cited numbers do NOT match the fixture — a figure was fabricated or dropped"
fi
# and the tiny hmd footprint is quantified — but SCOPED to the axis that measured it. The
# ~0MB used to be printed as "hmd-owned garbage total", which read as covering memory AND
# disk; a forensic sweep found 100MB of reapable merged worktrees on disk at that same
# moment. So the memory figure must be labelled MEMORY, and disk reported as its own axis.
if grep -q 'MEMORY axis' <<<"$out" \
   && grep -q '~0MB of hmd-owned' <<<"$out"; then
  ok "report quantifies the hmd footprint PER AXIS (memory labelled, disk reported separately)"
else
  bad "report did not cite the hmd-reclaimable MB scoped to the axis that measured it"
fi
grep -q 'of hmd-owned garbage total' <<<"$out" \
  && bad "report still presents one figure as the hmd-owned TOTAL (memory and disk conflated)" \
  || ok "report no longer conflates the memory and disk figures into a single 'total'"

# ── 4. NON-SPAMMY: low pressure → NO reboot nag ──────────────────────────────────
lout="$(run_clean "$JSON_LOW" "" report 2>&1)"
grep -qi 'reboot' <<<"$lout" \
  && bad "report nagged about a reboot on a HEALTHY machine (swap 5% / wired 22%)" \
  || ok "no reboot nag on a healthy machine (non-spammy)"

# ── 5. the --advise (SessionStart) path emits the same honest recommendation ──────
aout="$(run_clean "$JSON_HIGH" "" --advise --quick 2>&1)"
if grep -qi 'reboot' <<<"$aout" && grep -qi 'NOT heimdall' <<<"$aout"; then
  ok "--advise emits the honest reboot recommendation (SessionStart advisory path)"
else
  bad "--advise did not emit the honest reboot recommendation: $aout"
fi
# and stays silent on a healthy machine
alow="$(run_clean "$JSON_LOW" "" --advise --quick 2>&1)"
[ -z "$alow" ] && ok "--advise is SILENT on a healthy machine (no session-start spam)" \
  || bad "--advise spoke on a healthy machine: $alow"

# ── 6. high pressure + an hmd LEAK → recommend --apply FIRST, THEN reboot ─────────
lkout="$(run_clean "$JSON_HIGH" "100 101" --advise --quick 2>&1)"
if grep -qi 'Part of it IS heimdall' <<<"$lkout" \
   && grep -q 'heimdall-cleanup --apply' <<<"$lkout" \
   && grep -qi 'reboot' <<<"$lkout"; then
  ok "with an hmd python leak, advise recommends --apply FIRST then reboot (hmd owns its part)"
else
  bad "leak case did not recommend --apply-first-then-reboot: $lkout"
fi

# ── 7. OPT-OUT fully silences --advise (env AND marker) ──────────────────────────
eo="$(HEIMDALL_NO_CLEANUP=1 run_clean "$JSON_HIGH" "" --advise 2>&1)"
[ -z "$eo" ] && ok "HEIMDALL_NO_CLEANUP=1 fully silences --advise" \
  || bad "opt-out env ignored — --advise spoke despite HEIMDALL_NO_CLEANUP=1: $eo"
mkdir -p "$WORK/home-optout"; : > "$WORK/home-optout/no-cleanup"
mo="$(HMD_CLEANUP_OS=Darwin HMD_CLEANUP_SYSMON="$WORK/sysmon-fake" \
  SYSMON_JSON="$JSON_HIGH" SYSMON_ORPHANS="" \
  HMD_GC_TMP_ROOTS="$GTMP" HMD_GC_TEMP_TTL_MIN=99999 HMD_GC_CC_VERSIONS="$GVER" \
  HEIMDALL_HOME="$WORK/home-optout" \
  bash "$CLEAN" --advise --repo "$WORK/home-optout" 2>&1)"
[ -z "$mo" ] && ok "~/.heimdall/no-cleanup marker fully silences --advise" \
  || bad "opt-out marker ignored — --advise spoke despite the no-cleanup file: $mo"

# ── 8. READ-ONLY: report emits the recommendation but mutates NOTHING ────────────
head -c 4096 /dev/zero > "$GTMP/hmd-fixture.tmp"; : > "$WORK/killed"
run_clean "$JSON_HIGH" "100 101" report >/dev/null 2>&1
if [ -s "$WORK/killed" ]; then bad "report signalled a process — report MUST stay read-only"
else ok "report signalled NOTHING while recommending the reboot (read-only on the process axis)"; fi
if [ -e "$GTMP/hmd-fixture.tmp" ]; then ok "report deleted NO file while recommending the reboot (read-only on disk)"
else bad "report DELETED a file — the recommendation path must never mutate disk"; fi

# ── 9. PROVE-RED: crank the thresholds so the SAME high fixture is NOT flagged ────
# The reboot-worthy gate is threshold-driven; with the thresholds at 999 the advisory MUST
# NOT fire on the swap-95/wired-85 fixture — so case 1's assertion goes RED. Proving it can
# fail proves case 1 is a real check, not a tautology.
if [ "${REBOOT_PROVE_RED:-0}" != "1" ]; then
  if REBOOT_PROVE_RED=1 bash "$0" >/dev/null 2>&1; then
    bad "PROVE-RED: the suite PASSED with reboot thresholds cranked to 999 — case 1 is not falsifiable"
  else
    ok "PROVE-RED: cranked thresholds suppress the advisory → the suite goes RED (gate is falsifiable)"
  fi
fi

echo
printf 'reboot-advisor: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

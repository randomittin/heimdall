#!/usr/bin/env bash
#
# sessionstart-quiet.test.sh — acceptance for the SessionStart OUTPUT BUDGET.
#
# THE COST BEING CUT. Every session pays the SessionStart hooks' stdout before any work
# happens, and a parallel wave multiplies the CLAUDE.md/agent stack on top of it. Two hooks
# were spending ~2.8KB of that budget every single session: heimdall-dream-notice (18 lines)
# and heimdall-cleanup --advise (16 lines). Both described a condition that had not changed
# in weeks and needed one human action.
#
# THE RULE THIS SUITE ENFORCES: a hook gets ONE LINE unless it is actionable. If nothing is
# wrong it says nothing at all; if something IS wrong it says WHAT and HOW TO SEE MORE, and
# the detail moves behind --verbose.
#
# THE REGRESSION THIS SUITE EXISTS TO CATCH IS THE OPPOSITE ONE. A hook that went quiet by
# losing its ability to DETECT is not an optimization, it is a silent failure — strictly
# worse than the verbosity it replaced. So every quiet-path case is paired with a LOUD-path
# case that forces the real bad condition and proves the hook still speaks, still names the
# cause, and still carries a runnable remedy.
#
#   bash test/sessionstart-quiet.test.sh    (exit 0 = all cases pass)
#
# FALSIFIABLE claims proven:
#   (1)  dream-notice: TCC-blocked → speaks in ONE line naming TCC + the denied path + a fix
#   (2)  dream-notice: that line stays under the budget and points at --verbose
#   (3)  dream-notice: --verbose still emits the FULL block (nothing was deleted)
#   (4)  dream-notice: healthy → SILENT in both modes
#   (5)  dream-notice: --json is unchanged (machine consumers keep their contract)
#   (6)  cleanup --advise: high pressure + hmd clean → ONE line that still says NOT heimdall
#   (7)  cleanup --advise: high pressure + hmd LEAK → ONE line that still says --apply
#   (8)  cleanup --advise: --verbose still emits the FULL advisory (the accuracy corrections
#        about wired RAM / reboot-is-temporary survive verbatim)
#   (9)  cleanup --advise: healthy → SILENT; opt-out → SILENT
#   (10) PROVE-RED: a mutant that silences the terse path trips (1) and (6) — the
#        "still speaks" assertions are real checks, not tautologies.
#
# Every path is a temp fixture: the real ~/.heimdall, the real LaunchAgents dir and the real
# gc roots are never read or written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NOTICE="$ROOT/bin/heimdall-dream-notice"
CLEAN="$ROOT/bin/heimdall-cleanup"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$NOTICE" ] || { echo "FATAL: $NOTICE not executable" >&2; exit 2; }
[ -x "$CLEAN" ]  || { echo "FATAL: $CLEAN not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sessionstart-quiet.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ONE LINE means one line. The budget is generous enough for a real remedy command and a
# pointer, and tight enough that the 16/18-line blocks can never come back unnoticed.
BUDGET=420

nlines() { grep -c '' <<<"$1" || true; }
nbytes() { printf '%s' "$1" | wc -c | tr -d ' '; }

echo "sessionstart-quiet.test.sh"

# ══════════════════════════════════════════════════════════════════════════════════
# heimdall-dream-notice
# ══════════════════════════════════════════════════════════════════════════════════
TODAY="$(date -u +%Y-%m-%d)"
LA="$WORK/LaunchAgents"; mkdir -p "$LA"
: > "$LA/com.heimdall.dream.plist"
NREPO="$WORK/nrepo"; mkdir -p "$NREPO/.planning/dream"
DENIED="/Users/rj/Downloads/heimdall"

write_status() { # <file> <result> <reason> <date> <denied_path>
  cat > "$1" <<EOF
{
  "result": "$2",
  "reason": "$3",
  "date": "$4",
  "ts": "${4}T03:00:05Z",
  "denied_path": "$5",
  "detail": "ls: $5: Operation not permitted"
}
EOF
}

STATUS="$WORK/status-blocked.json"
write_status "$STATUS" blocked tcc-denied "$TODAY" "$DENIED"

nrun() { HEIMDALL_LAUNCH_AGENTS_DIR="$LA" "$NOTICE" --repo "$NREPO" --status "$STATUS" "$@" 2>&1; }

# ── (1) LOUD ON THE REAL BAD CONDITION ───────────────────────────────────────────
# The whole point of the hook. Quieting it must never cost the cause or the remedy.
terse="$(nrun)"
if [ -n "$terse" ] \
   && grep -qi 'dream' <<<"$terse" \
   && grep -qi 'not running' <<<"$terse" \
   && grep -q 'TCC' <<<"$terse" \
   && grep -qF "$DENIED" <<<"$terse"; then
  ok "(1) TCC-blocked dream still SPEAKS and names the cause (TCC) + the denied path"
else
  bad "(1) quieted dream-notice lost the cause or the denied path; got: $terse"
fi
grep -qi 'heimdall-dream-permission ask\|heimdall-dream .*run' <<<"$terse" \
  && ok "(1) the terse notice still carries a RUNNABLE remedy" \
  || bad "(1) terse notice has no runnable remedy; got: $terse"

# ── (2) THE BUDGET: one line, and it points at the detail ────────────────────────
tl="$(nlines "$terse")"; tb="$(nbytes "$terse")"
[ "$tl" -eq 1 ] && ok "(2) dream-notice emits exactly ONE line (was 18)" \
  || bad "(2) dream-notice emitted $tl lines, expected 1"
[ "$tb" -le "$BUDGET" ] && ok "(2) dream-notice line is ${tb}B (budget ${BUDGET}B)" \
  || bad "(2) dream-notice line is ${tb}B, over the ${BUDGET}B budget"
printf '%s' "$terse" | grep -q -- '--verbose' \
  && ok "(2) the terse line points at --verbose for the detail" \
  || bad "(2) no pointer to --verbose — the detail became undiscoverable: $terse"

# ── (3) NOTHING WAS DELETED: --verbose still emits the full block ────────────────
verb="$(nrun --verbose)"
vl="$(nlines "$verb")"
[ "$vl" -ge 10 ] && ok "(3) --verbose still emits the full block ($vl lines)" \
  || bad "(3) --verbose emitted only $vl lines — detail was DELETED, not moved"
if grep -qi 'Full Disk Access' <<<"$verb" \
   && grep -qi 'protected folder' <<<"$verb" \
   && grep -qi 'LaunchAgent carries no TCC grant' <<<"$verb"; then
  ok "(3) --verbose keeps the full TCC explanation and BOTH unattended routes"
else
  bad "(3) --verbose lost part of the TCC explanation: $verb"
fi

# ── (4) SILENT WHEN HEALTHY (in BOTH modes) ─────────────────────────────────────
HREPO="$WORK/hrepo"; mkdir -p "$HREPO/.planning/dream"
: > "$HREPO/.planning/dream/$TODAY.md"
HSTATUS="$WORK/status-ok.json"
write_status "$HSTATUS" ok none "$TODAY" ""
hq="$(HEIMDALL_LAUNCH_AGENTS_DIR="$LA" "$NOTICE" --repo "$HREPO" --status "$HSTATUS" 2>&1)"
hv="$(HEIMDALL_LAUNCH_AGENTS_DIR="$LA" "$NOTICE" --repo "$HREPO" --status "$HSTATUS" --verbose 2>&1)"
[ -z "$hq" ] && ok "(4) healthy dream → SILENT (default)" \
  || bad "(4) spoke on a healthy dream: $hq"
[ -z "$hv" ] && ok "(4) healthy dream → SILENT (--verbose too: verbosity is not a nag switch)" \
  || bad "(4) --verbose spoke on a healthy dream: $hv"

# ── (5) THE MACHINE CONTRACT IS UNCHANGED ───────────────────────────────────────
js="$(nrun --json)"
if grep -q '"alert":true' <<<"$js" && grep -q '"reason":"tcc-denied"' <<<"$js"; then
  ok "(5) --json still reports alert:true + reason:tcc-denied (contract intact)"
else
  bad "(5) --json contract changed: $js"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# heimdall-cleanup --advise
# ══════════════════════════════════════════════════════════════════════════════════
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

GTMP="$WORK/gctmp-empty"; GVER="$WORK/versions-none"; mkdir -p "$GTMP" "$WORK/home-empty"

JSON_HIGH="$WORK/json-high"
cat > "$JSON_HIGH" <<'EOF'
{"severity":"warn","disk":{"status":"ok","used_pct":50,"free_bytes":0,"total_bytes":0},"memory":{"status":"warn","swap_used_pct":95,"swap_used_g":16.0,"swap_total_g":17.0,"wired_pct":85,"free_pct":2},"procs":{"status":"ok","hmd_orphans":0,"python3_total":1,"runaway":"","runaway_n":0}}
EOF
JSON_LOW="$WORK/json-low"
cat > "$JSON_LOW" <<'EOF'
{"severity":"ok","disk":{"status":"ok","used_pct":40,"free_bytes":0,"total_bytes":0},"memory":{"status":"ok","swap_used_pct":5,"swap_used_g":0.4,"swap_total_g":8.0,"wired_pct":22,"free_pct":40},"procs":{"status":"ok","hmd_orphans":0,"python3_total":1,"runaway":"","runaway_n":0}}
EOF

CBIN="$CLEAN"

# The CODE axis (heimdall-deadcode --advise) runs FIRST inside do_advise and is a
# DIFFERENT subsystem with a DIFFERENT input: it scans the real repo for executables no
# live entry point reaches. Left un-injected it makes this suite's line-count assertions
# a function of the repo's current dead-code state — green on a clean tree, red the moment
# anything (another suite mid-run, a work-in-progress script) leaves an unreachable file
# in bin/. That is exactly how this suite went red inside a full run while passing solo.
# Inject a stub that prints nothing and RECORDS that it was called, so the byte/line budget
# measures the memory advisory alone while the wiring stays proven (see the marker check
# after case 6 — dropping the deadcode call must still fail this suite).
DC_MARK="$WORK/deadcode-called"
DCFAKE="$WORK/deadcode-fake"
cat > "$DCFAKE" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DC_MARK"
exit 0
EOF
chmod +x "$DCFAKE"

advise() { # <json> <orphan pids> [extra argv...]
  local json="$1" orphans="$2"; shift 2
  HMD_CLEANUP_OS=Darwin HMD_CLEANUP_SYSMON="$WORK/sysmon-fake" \
  SYSMON_JSON="$json" SYSMON_ORPHANS="$orphans" \
  HMD_CLEANUP_DEADCODE="$DCFAKE" \
  HMD_GC_TMP_ROOTS="$GTMP" HMD_GC_TEMP_TTL_MIN=99999 HMD_GC_CC_VERSIONS="$GVER" \
  HEIMDALL_HOME="$WORK/home-empty" \
  bash "$CBIN" --advise --quick --repo "$WORK/home-empty" "$@" 2>&1
}

# ── (6) HIGH PRESSURE, hmd CLEAN → one line that STILL attributes honestly ───────
# RJ's original ask was that when the pressure is NOT heimdall's fault the advisory says so.
# That attribution is the actionable half; it must survive the byte cut.
aclean="$(advise "$JSON_HIGH" "")"
al="$(nlines "$aclean")"; ab="$(nbytes "$aclean")"
[ -n "$aclean" ] && ok "(6) high pressure still SPEAKS (the detector was not disabled)" \
  || bad "(6) --advise went silent under high memory pressure — detection was lost"
[ "$al" -eq 1 ] && ok "(6) --advise emits exactly ONE line (was 16)" \
  || bad "(6) --advise emitted $al lines, expected 1; got: $(printf '%s' "$aclean" | tr '\n' '|')"
# The CODE axis must still be invoked — the stub above silences it, it must not delete it.
[ -s "$DC_MARK" ] && ok "(6) --advise still invokes the CODE-axis sweep (deadcode called)" \
  || bad "(6) --advise never invoked heimdall-deadcode — the CODE axis was dropped"
[ "$ab" -le "$BUDGET" ] && ok "(6) --advise line is ${ab}B (budget ${BUDGET}B)" \
  || bad "(6) --advise line is ${ab}B, over the ${BUDGET}B budget"
if grep -qi 'NOT heimdall' <<<"$aclean" && grep -qi 'reboot' <<<"$aclean"; then
  ok "(6) the terse advisory still says the pressure is NOT heimdall"
else
  bad "(6) attribution honesty was lost in the cut: $aclean"
fi
if grep -q '95%' <<<"$aclean" && grep -q 'wired 85%' <<<"$aclean"; then
  ok "(6) the terse advisory still cites the MEASURED figures (no bare claim)"
else
  bad "(6) the cited figures were dropped: $aclean"
fi
printf '%s' "$aclean" | grep -q -- '--verbose' \
  && ok "(6) the terse advisory points at --verbose for the detail" \
  || bad "(6) no pointer to --verbose: $aclean"

# ── (7) HIGH PRESSURE + an hmd LEAK → the ACTIONABLE remedy survives ─────────────
# This is the one case where heimdall CAN act. Losing `--apply` here would be the
# expensive regression: hmd's own leak would go unreaped and unmentioned.
aleak="$(advise "$JSON_HIGH" "100 101")"
ll="$(nlines "$aleak")"
if grep -qi 'Part of it IS heimdall' <<<"$aleak" \
   && grep -q 'heimdall-cleanup --apply' <<<"$aleak"; then
  ok "(7) the leak path still owns hmd's share and still recommends --apply"
else
  bad "(7) the leak path lost the --apply recommendation: $aleak"
fi
[ "$ll" -eq 1 ] && ok "(7) the leak advisory is also ONE line" \
  || bad "(7) leak advisory emitted $ll lines, expected 1; got: $(printf '%s' "$aleak" | tr '\n' '|')"

# ── (8) NOTHING WAS DELETED: --verbose keeps the accuracy corrections verbatim ───
# These sentences are a RETRACTION of the false "a restart is the fix" claim. They are
# load-bearing; the byte cut moves them behind a flag, it does not weaken them.
averb="$(advise "$JSON_HIGH" "" --verbose)"
vl2="$(nlines "$averb")"
[ "$vl2" -ge 10 ] && ok "(8) --advise --verbose still emits the full advisory ($vl2 lines)" \
  || bad "(8) --verbose emitted only $vl2 lines — the advisory was DELETED, not moved"
if grep -qi 'cannot free kernel-wired memory' <<<"$averb" \
   && grep -qi 'TEMPORARY reclaim, not the fix' <<<"$averb" \
   && grep -qi 'reclaims it on its own' <<<"$averb" \
   && grep -qi 'MEMORY axis' <<<"$averb"; then
  ok "(8) --verbose keeps every accuracy correction (wired limit · reboot-temporary · swap · axis)"
else
  bad "(8) an accuracy correction was lost from --verbose: $averb"
fi
grep -qE 'a restart is the fix|clear ONLY on reboot' <<<"$averb" \
  && bad "(8) the falsified 'restart is the fix' claim came BACK into --verbose" \
  || ok "(8) --verbose still refuses the falsified 'restart is the fix' claim"

# ── (9) SILENT when healthy, SILENT when opted out ───────────────────────────────
alow="$(advise "$JSON_LOW" "")"
[ -z "$alow" ] && ok "(9) --advise SILENT on a healthy machine" \
  || bad "(9) --advise spoke on a healthy machine: $alow"
alowv="$(advise "$JSON_LOW" "" --verbose)"
[ -z "$alowv" ] && ok "(9) --advise --verbose SILENT on a healthy machine too" \
  || bad "(9) --verbose spoke on a healthy machine: $alowv"
aopt="$(HEIMDALL_NO_CLEANUP=1 advise "$JSON_HIGH" "")"
[ -z "$aopt" ] && ok "(9) HEIMDALL_NO_CLEANUP=1 still fully silences --advise" \
  || bad "(9) opt-out ignored: $aopt"

# ── (10) PROVE-RED — the "still speaks" assertions must be falsifiable ───────────
# Mutate each binary so its terse path prints nothing, then re-run the two LOUD assertions
# against the mutant. If they still pass, they are tautologies and this whole suite is
# decorative. A quieted hook that CANNOT be caught going silent is the regression.
MUTN="$WORK/dream-notice.mutant"
sed 's/^ALERT=0$/ALERT=0; HMD_MUTE_TEST=1/' "$NOTICE" > "$MUTN" 2>/dev/null || true
if grep -q 'HMD_MUTE_TEST=1' "$MUTN" 2>/dev/null; then
  # the mutant forces the alert decision to stay 0 → the notice can never speak
  sed -i.bak 's/^\[ "\$ALERT" = 1 \] || quiet healthy.*$/quiet muted/' "$MUTN" 2>/dev/null || true
  chmod +x "$MUTN"
  mout="$(HEIMDALL_LAUNCH_AGENTS_DIR="$LA" bash "$MUTN" --repo "$NREPO" --status "$STATUS" 2>&1)"
  [ -z "$mout" ] \
    && ok "(10) PROVE-RED: muting dream-notice's alert path makes case (1) go RED (falsifiable)" \
    || bad "(10) PROVE-RED: the muted dream-notice still spoke — case (1) cannot detect silence"
else
  bad "(10) PROVE-RED: the ALERT anchor is missing from bin/heimdall-dream-notice"
fi

MUTC="$WORK/heimdall-cleanup.mutant"
# the anchor is the ADVISORY GATE, which is the union of the memory axis and the orphan axis
# (_advisory_worthy). Mutating it to a bare `return 0` short-circuits do_advise before either
# axis can render, so the LOUD assertions above have to notice the silence.
sed 's/^  _advisory_worthy .*$/  return 0/' "$CLEAN" > "$MUTC"
if cmp -s "$MUTC" "$CLEAN"; then
  bad "(10) PROVE-RED: the _advisory_worthy gate anchor is missing from bin/heimdall-cleanup"
else
  chmod +x "$MUTC"
  CBIN="$MUTC"
  cmut="$(advise "$JSON_HIGH" "")"
  CBIN="$CLEAN"
  [ -z "$cmut" ] \
    && ok "(10) PROVE-RED: short-circuiting do_advise makes case (6) go RED (falsifiable)" \
    || bad "(10) PROVE-RED: the muted --advise still spoke — case (6) cannot detect silence"
fi

echo
printf 'sessionstart-quiet: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

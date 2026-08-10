#!/usr/bin/env bash
#
# wired-holder-advisory.test.sh — acceptance for the CORRECTED memory advisory in
# bin/heimdall-cleanup. The old advisory told the user "wired RAM and swap clear ONLY on
# reboot — a restart is the fix". A forensic sweep of this machine falsified it: the wired
# pages were held by mounted CoreSimulator runtime volumes, which RE-WIRE on the next boot,
# so a restart reclaims temporarily and the pressure returns. An advisory that confidently
# prescribes the wrong action is worse than one that describes the situation and stops.
#
#   bash test/wired-holder-advisory.test.sh    (exit 0 = all cases pass)
#
# THE PROPERTIES, each planted with a fixture a regression flips:
#   · HIGH pressure + a DETECTABLE persistent holder → name the holder + the DURABLE action,
#     and never claim a restart is the fix                                    (cases 1,2)
#   · HIGH pressure + NO holder detectable → describe and STOP: say the holder is
#     unidentified rather than prescribe a fix that may not apply                 (case 3)
#   · detection UNAVAILABLE (probe missing/erroring) → fail QUIET: the advisory still
#     prints, degrades to the honest wording, and exits 0 (never breaks SessionStart) (case 4)
#   · NORMAL machine → still silent (the correction did not make it spammy)        (case 5)
#   · memory and disk are NOT conflated: the hmd figure is labelled MEMORY axis, and a
#     --quick run declares the disk axis unmeasured instead of quoting ~0MB as a total (case 6)
#   · swap urgency is not overstated: macOS reclaims swap on its own                (case 7)
#   · a running hypervisor is detected from ps rows (holder detection is not
#     hardcoded to simulator runtimes)                                             (case 8)
#   · what was TRUE is kept: not-heimdall attribution, no hmd python leak, and the honest
#     "cannot free kernel-wired memory" limit                                      (case 9)
#   · the hmd-leak path still reaps hmd's OWN footprint first                     (case 10)
#   · PROVE-RED: a MUTANT copy of bin/heimdall-cleanup with the correction reverted to
#     "a restart is the fix" must make case 1's no-false-fix assertion go RED     (case 11)
#
# Every probe is a fixture: a FAKE sysmon (HMD_CLEANUP_SYSMON) emits a crafted --json, a FAKE
# mount (HMD_CLEANUP_MOUNT_CMD) emits crafted mount rows, and ps rows come from a planted file
# (HMD_CLEANUP_PS_ROWS). HMD_CLEANUP_OS=Darwin pins the memory path so the suite is identical
# on macOS and Linux. No real process is signalled and no real volume is touched.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLEAN="$REPO/bin/heimdall-cleanup"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$CLEAN" ] || { echo "FATAL: $CLEAN not executable"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wired-holder-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "wired-holder-advisory.test.sh"

# ── fixtures: a fake sysmon (memory grade) + fake mount rows + planted ps rows ────
cat > "$WORK/sysmon-fake" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --json)             cat "$SYSMON_JSON" ;;
  --filter-orphans)   [ -n "${SYSMON_ORPHANS:-}" ] && printf '%s\n' $SYSMON_ORPHANS || true ;;
  --reap-hmd-orphans) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/sysmon-fake"

# mount stub: emits whatever MOUNT_ROWS points at (empty file = nothing mounted).
cat > "$WORK/mount-fake" <<'EOF'
#!/usr/bin/env bash
[ -n "${MOUNT_ROWS:-}" ] && cat "$MOUNT_ROWS" 2>/dev/null || true
exit 0
EOF
chmod +x "$WORK/mount-fake"

# mount stub that BREAKS (non-zero, stderr noise) — the detection-unavailable fixture.
cat > "$WORK/mount-broken" <<'EOF'
#!/usr/bin/env bash
echo "mount: getmntinfo failed" >&2
exit 7
EOF
chmod +x "$WORK/mount-broken"

# 4 mounted CoreSimulator runtime volumes — the shape measured on the real machine.
cat > "$WORK/mounts-sim" <<'EOF'
/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
/dev/disk5s1 on /Library/Developer/CoreSimulator/Volumes/iOS_23C54 (apfs, sealed, local, read-only, nobrowse)
/dev/disk7s1 on /Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-D023F5D5 (apfs, local, read-only, nobrowse)
/dev/disk9s1 on /Library/Developer/CoreSimulator/Volumes/iOS_22G86 (apfs, sealed, local, read-only, nobrowse)
/dev/disk11s1 on /Library/Developer/CoreSimulator/Volumes/iOS_23F77 (apfs, sealed, local, read-only, nobrowse)
EOF
# a plain machine: nothing kernel-side that we can name.
cat > "$WORK/mounts-plain" <<'EOF'
/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse)
EOF

# ps rows: a plain machine, and one running a hypervisor.
cat > "$WORK/ps-plain" <<'EOF'
  501     1 /usr/sbin/cfprefsd
  502   501 /bin/zsh -l
EOF
cat > "$WORK/ps-vm" <<'EOF'
  501     1 /usr/sbin/cfprefsd
  900     1 /Applications/Docker.app/Contents/MacOS/com.docker.virtualization --kernel vmlinuz
EOF

# gc roots: EMPTY, so the hmd disk figure is genuinely ~0MB.
GTMP="$WORK/gctmp-empty"; GVER="$WORK/versions-none"; mkdir -p "$GTMP" "$WORK/home-empty"

JSON_HIGH="$WORK/json-high"
cat > "$JSON_HIGH" <<'EOF'
{"severity":"warn","disk":{"status":"ok","used_pct":50,"free_bytes":0,"total_bytes":0},"memory":{"status":"warn","swap_used_pct":95,"swap_used_g":16.0,"swap_total_g":17.0,"wired_pct":85,"free_pct":2},"procs":{"status":"ok","hmd_orphans":0,"python3_total":1,"runaway":"","runaway_n":0}}
EOF
JSON_LOW="$WORK/json-low"
cat > "$JSON_LOW" <<'EOF'
{"severity":"ok","disk":{"status":"ok","used_pct":40,"free_bytes":0,"total_bytes":0},"memory":{"status":"ok","swap_used_pct":5,"swap_used_g":0.4,"swap_total_g":8.0,"wired_pct":22,"free_pct":40},"procs":{"status":"ok","hmd_orphans":0,"python3_total":1,"runaway":"","runaway_n":0}}
EOF

# advise() — $1 json, $2 mount rows file (or the literal 'BROKEN'), $3 ps rows file,
# $4 orphan pid list, rest = extra argv. Uses $BIN so the mutant can be swapped in.
#
# --verbose IS THE ADVISORY THIS SUITE IS ABOUT. `--advise` on its own now emits ONE line —
# the SessionStart output budget — and the full block that names the holder, both durable
# actions and the swap/wired/disk axes moved behind --verbose. Nothing here was weakened:
# the detection and the wording are the same code, so every assertion below still runs
# against the identical text. The terse line's own contract (that it still fires, still
# attributes the pressure honestly, and still points here) is pinned by
# test/sessionstart-quiet.test.sh cases (6)-(8).
BIN="$CLEAN"
advise() {
  local json="$1" mounts="$2" psrows="$3" orphans="$4"; shift 4
  local mountcmd="$WORK/mount-fake"
  [ "$mounts" = "BROKEN" ] && { mountcmd="$WORK/mount-broken"; mounts=""; }
  HMD_CLEANUP_OS=Darwin HMD_CLEANUP_SYSMON="$WORK/sysmon-fake" \
  HMD_CLEANUP_MOUNT_CMD="$mountcmd" MOUNT_ROWS="$mounts" \
  HMD_CLEANUP_PS_ROWS="$psrows" \
  SYSMON_JSON="$json" SYSMON_ORPHANS="$orphans" \
  HMD_GC_TMP_ROOTS="$GTMP" HMD_GC_TEMP_TTL_MIN=99999 HMD_GC_CC_VERSIONS="$GVER" \
  HEIMDALL_HOME="$WORK/home-empty" \
  bash "$BIN" --advise --verbose --repo "$WORK/home-empty" "$@" 2>&1
}

# the FALSE claim the forensic sweep killed. Any of these in the output = a regression.
FALSE_FIX='a restart is the fix|clear ONLY on reboot|kernel/driver-locked'
has_false_fix() { grep -qE "$FALSE_FIX" <<<"$1"; }

# ── 1. HIGH + a detectable holder → no false "restart is the fix" claim ───────────
sim="$(advise "$JSON_HIGH" "$WORK/mounts-sim" "$WORK/ps-plain" "" --quick)"
has_false_fix "$sim" \
  && bad "advisory still claims a restart is THE fix (the falsified claim)" \
  || ok "advisory no longer claims a restart is THE fix"
grep -qiE 'temporary reclaim' <<<"$sim" \
  && ok "advisory frames a reboot as a TEMPORARY reclaim" \
  || bad "advisory does not say a reboot is only a temporary reclaim: $sim"

# ── 2. the detected holder is NAMED with a durable, non-destructive review step ───
if grep -qi 'simulator runtime volume' <<<"$sim" \
   && grep -q '4' <<<"$sim" \
   && grep -q 'xcrun simctl runtime list' <<<"$sim"; then
  ok "names the measured holder (4 mounted simulator runtime volumes) + the review command"
else
  bad "did not name the detected simulator-runtime holder or its review command: $sim"
fi
grep -q 'simctl runtime delete' <<<"$sim" \
  && ok "gives the DURABLE action (runtime delete) rather than only a reboot" \
  || bad "no durable action offered for the detected holder"

# ── 3. HIGH + NOTHING detectable → describe and STOP (no invented prescription) ───
plain="$(advise "$JSON_HIGH" "$WORK/mounts-plain" "$WORK/ps-plain" "" --quick)"
if grep -qi 'no persistent holder identified' <<<"$plain"; then
  ok "with no detectable holder it SAYS the holder is unidentified (describes, then stops)"
else
  bad "invented or omitted an attribution when nothing was detectable: $plain"
fi
grep -qi 'simulator runtime volume' <<<"$plain" \
  && bad "prescribed simulator runtimes on a machine with none mounted (hardcoded answer)" \
  || ok "does NOT hardcode simulator runtimes as the universal answer"
has_false_fix "$plain" \
  && bad "no-holder path still claims a restart is THE fix" \
  || ok "no-holder path also refuses the false 'restart is the fix' claim"

# ── 4. DETECTION UNAVAILABLE → fail quiet, still advise, exit 0 ──────────────────
brk="$(advise "$JSON_HIGH" "BROKEN" "$WORK/ps-plain" "" --quick)"; brk_rc=$?
[ "$brk_rc" -eq 0 ] \
  && ok "a broken detection probe exits 0 (SessionStart is never broken by the advisory)" \
  || bad "broken probe made --advise exit $brk_rc"
grep -qi 'memory pressure is HIGH' <<<"$brk" \
  && ok "advisory still prints when detection is unavailable" \
  || bad "advisory went missing when the detection probe failed: $brk"
grep -qi 'no persistent holder identified' <<<"$brk" \
  && ok "unavailable detection degrades to the honest 'holder unidentified' wording" \
  || bad "broken probe did not degrade to the honest wording: $brk"
grep -qi 'getmntinfo failed' <<<"$brk" \
  && bad "probe stderr leaked into the SessionStart advisory" \
  || ok "probe stderr is swallowed (no noise in the advisory)"

# ── 5. NORMAL machine → still silent ─────────────────────────────────────────────
low="$(advise "$JSON_LOW" "$WORK/mounts-sim" "$WORK/ps-plain" "" --quick)"
[ -z "$low" ] \
  && ok "silent on a healthy machine even with holders mounted (not spammy)" \
  || bad "advisory spoke on a healthy machine: $low"

# ── 6. MEMORY and DISK are not conflated ─────────────────────────────────────────
grep -q 'MEMORY axis' <<<"$sim" \
  && ok "the hmd figure is explicitly scoped to the MEMORY axis" \
  || bad "the hmd figure is not scoped to an axis — memory and disk still conflated: $sim"
grep -qi 'of hmd-owned garbage total' <<<"$sim" \
  && bad "still presents a partial scan as the hmd-owned TOTAL (the overstatement)" \
  || ok "no longer claims a partial figure is the hmd-owned total"
if grep -qi 'DISK' <<<"$sim" && grep -qi 'quick scan' <<<"$sim"; then
  ok "--quick declares the DISK axis unmeasured instead of quoting it as a total"
else
  bad "--quick did not scope the disk axis honestly: $sim"
fi
# a FULL (non-quick) run may quote the disk number, but must keep it a separate axis
full="$(advise "$JSON_HIGH" "$WORK/mounts-sim" "$WORK/ps-plain" "")"
grep -qi 'does not relieve memory' <<<"$full" \
  && ok "the disk figure is marked as not relieving memory pressure (axes kept apart)" \
  || bad "full run conflates the disk figure with the memory problem: $full"

# ── 7. swap urgency is not overstated ────────────────────────────────────────────
if grep -qi 'reclaims it on its own' <<<"$sim" \
   && grep -qi 'without a reboot' <<<"$sim"; then
  ok "notes macOS reclaims swap on its own as pressure eases (no reboot needed)"
else
  bad "swap is presented as requiring intervention: $sim"
fi

# ── 8. holder detection is not simulator-only — a hypervisor is detected too ──────
vm="$(advise "$JSON_HIGH" "$WORK/mounts-plain" "$WORK/ps-vm" "" --quick)"
if grep -qi 'com.docker.virtualization' <<<"$vm" \
   && grep -qiE 'hypervisor|virtual machine|VM' <<<"$vm"; then
  ok "detects a running hypervisor as a persistent holder (detection is general)"
else
  bad "did not detect the planted hypervisor: $vm"
fi

# ── 9. what was TRUE is kept ─────────────────────────────────────────────────────
if grep -qi 'NOT heimdall' <<<"$sim" \
   && grep -qi 'no hmd python leak' <<<"$sim" \
   && grep -qi 'cannot free kernel-wired memory' <<<"$sim"; then
  ok "keeps the true claims: not heimdall · no hmd leak · hmd cannot free kernel-wired memory"
else
  bad "the correction dropped a claim that was TRUE: $sim"
fi

# ── 10. the hmd-leak path still reaps hmd's OWN footprint first ──────────────────
leak="$(advise "$JSON_HIGH" "$WORK/mounts-sim" "$WORK/ps-plain" "100 101" --quick)"
if grep -qi 'Part of it IS heimdall' <<<"$leak" \
   && grep -q 'heimdall-cleanup --apply' <<<"$leak"; then
  ok "leak path still owns hmd's share and recommends --apply first"
else
  bad "leak path lost the --apply-first recommendation: $leak"
fi
has_false_fix "$leak" \
  && bad "leak path still claims a restart is THE fix" \
  || ok "leak path also refuses the false 'restart is the fix' claim"

# ── 11. PROVE-RED via a MUTANT that reverts the correction ───────────────────────
# Revert the corrected sentence back to "a restart is the fix" in a throwaway copy. Case 1's
# assertion MUST go RED on that mutant — proving it is a real check, not a tautology.
MUT="$WORK/heimdall-cleanup.mutant"
sed 's/TEMPORARY reclaim, not the fix/a restart is the fix/' "$CLEAN" > "$MUT"
chmod +x "$MUT"
if cmp -s "$MUT" "$CLEAN"; then
  bad "PROVE-RED: the mutation anchor is missing from bin/heimdall-cleanup — cannot falsify"
else
  BIN="$MUT"
  mut_out="$(advise "$JSON_HIGH" "$WORK/mounts-sim" "$WORK/ps-plain" "" --quick)"
  BIN="$CLEAN"
  if has_false_fix "$mut_out"; then
    ok "PROVE-RED: reverting the fix makes case 1 go RED (the assertion is falsifiable)"
  else
    bad "PROVE-RED: the mutant did NOT trip case 1 — the assertion cannot detect a regression"
  fi
fi

echo
printf 'wired-holder-advisory: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

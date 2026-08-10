#!/usr/bin/env bash
#
# orphan-python-detection.test.sh — the SILENT-MONITOR regression.
#
# THE MEASURED DEFECT (2026-08-08, RJ's machine). 224 processes matching
#   ps -Ao pid,ppid,command | awk '$2==1 && /bin\/python3 -$/'
# were alive with PPID=1, state S, ages from minutes to over a day. At that exact moment
# `heimdall-sysmon --json` reported "hmd_orphans":0 and `heimdall-cleanup --advise` said the
# pressure was NOT heimdall. Both were wrong, the machine was at swap 94%, and the pile had
# to be killed by hand.
#
# WHY hmd WAS BLIND. HMD_ORPHAN_AWK only counts a PPID=1 python whose command line carries a
# heimdall marker (/heimdall|\.heimdall|hmd-/). hmd runs python through stdin heredocs
# (`python3 - <<'PY'`) at ~25 sites, and a stdin heredoc renders in ps as EXACTLY `python3 -`
# — no script path, no marker, nothing to attribute. hmd's own orphans were invisible to
# hmd's own detector, and absence of a signal was indistinguishable from absence of a problem.
# That is the worst failure class this repo recognises, so it gets a suite.
#
#   bash test/orphan-python-detection.test.sh    (exit 0 = all cases pass)
#
# THE HONESTY CONSTRAINT that shapes every assertion below. hmd CANNOT prove a bare
# `python3 -` is its own — the command line carries zero attribution. So the count is a
# SEPARATE, honestly-named field (python_orphans_unattributed) and is NEVER folded into
# hmd_orphans. A false attribution is exactly as bad as the blindness: case 2 asserts the two
# sets are disjoint in BOTH directions, so neither matcher can quietly annex the other's rows.
#
# FALSIFIABLE claims proven:
#   (1)  the detector COUNTS a planted bare-stdin orphan (the shape hmd used to miss)
#   (2)  the two matchers are DISJOINT — no bare orphan is claimed as hmd's, and no hmd
#        orphan is double-counted as unattributed
#   (3)  --json reports the count in the honest field and keeps every pre-existing key
#   (4)  the reaper's guards REFUSE a tty-attached, a young, and a caller's-own-tree process
#   (5)  the reap set is a strict SUBSET of the detected set (a reaper can never exceed its
#        own detector)
#   (6)  heimdall-cleanup --apply signals EXACTLY the guarded set and never a guarded-out pid
#   (7)  --auto never reaps an unattributed process (ownership is unproven → hook must not act)
#   (8)  --advise surfaces the count in ONE line and STOPS claiming "NOT heimdall" once
#        unattributed orphans are present — the precise sentence that lied on 2026-08-08
#   (9)  PROVE-DETECTS: a mutant with the bare-stdin clause removed makes (1) go RED, and a
#        WIDENED matcher makes (2)/(4) go RED. Neither "clean" verdict can be vacuous.
#   (11) the advisory fires on the ORPHAN axis with memory HEALTHY — the second silence: the
#        SessionStart advisory used to be reachable only through the memory-pressure gate, so
#        a pile could grow without bound while nothing was said. Both axes true still yields
#        ONE line, and below both floors it stays silent.
#
# HERMETIC. Every process row is a SYNTHETIC `pid ppid …` fixture fed through a documented
# test seam, and every kill goes to a recording stub. No real process is ever signalled, no
# live ps is consulted for any assertion, and the real ~/.heimdall is never read or written
# (HEIMDALL_HOME points at a temp dir throughout).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SYSMON="$ROOT/bin/heimdall-sysmon"
CLEAN="$ROOT/bin/heimdall-cleanup"

P=0; F=0
ok()  { P=$((P+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { F=$((F+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

[ -x "$SYSMON" ] || { echo "FATAL: $SYSMON not executable" >&2; exit 2; }
[ -x "$CLEAN" ]  || { echo "FATAL: $CLEAN not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/orphan-python.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$WORK/home-empty" "$WORK/gctmp-empty"

echo "orphan-python-detection.test.sh"

# ══════════════════════════════════════════════════════════════════════════════════
# FIXTURE A — plain rows `pid ppid command…` (the DETECTION oracle's input shape,
# identical to the shape HMD_ORPHAN_AWK already consumes so both read one ps snapshot).
# ══════════════════════════════════════════════════════════════════════════════════
# 700/701 = THE DEFECT: PPID=1 bare stdin python, no marker of any kind  → unattributed
# 702     = same command but a LIVE parent (ppid 501) — not orphaned      → never counted
# 703     = a foreign python with a real script path                      → never counted
# 704/705 = hmd's OWN, attributable orphans (mock_cp.py / a .heimdall path) → hmd_orphans
# 706     = not python at all
# 707     = `python3 -c` — an inline program, NOT a bare stdin script     → never counted
# 708     = a stdin script whose argv DOES carry an hmd marker            → hmd's, not ours
cat > "$WORK/rows-plain" <<'ROWS'
700 1 /usr/bin/python3 -
701 1 /opt/homebrew/bin/python3 -
702 501 /usr/bin/python3 -
703 1 /usr/bin/python3 /Users/rj/myapp/server.py
704 1 /usr/bin/python3 /var/folders/x/mock_cp.py --port 1
705 1 python3 /Users/rj/.heimdall/keeper/loop.py
706 1 node /Users/rj/app/index.js
707 1 /usr/bin/python3 -c import time; time.sleep(999)
708 1 /usr/bin/python3 - /Users/rj/Downloads/heimdall/bin/x
ROWS

detect() { "$SYSMON" --filter-bare-python-orphans < "$WORK/rows-plain" 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ *$//'; }

# ── (1) THE DETECTOR SEES THE SHAPE IT USED TO MISS ──────────────────────────────
got="$(detect)"
if [ "$got" = "700 701" ]; then
  ok "(1) detector counts the bare-stdin PPID=1 pythons (got: $got)"
else
  bad "(1) detection wrong — want '700 701' got '$got'"
fi
[ -n "$got" ] || bad "(1) detector returned NOTHING on a fixture that plants the defect"

# ── (1a) FALSIFIERS: every non-defect row must stay out ──────────────────────────
for pid in 702 703 704 705 706 707 708; do
  case " $got " in
    *" $pid "*) bad "(1a) FALSE POSITIVE: $pid matched the unattributed matcher" ;;
    *)          ok  "(1a) $pid correctly NOT counted as an unattributed orphan" ;;
  esac
done

# ── (2) THE TWO MATCHERS ARE DISJOINT (attribution honesty, both directions) ─────
hmd_got="$("$SYSMON" --filter-orphans < "$WORK/rows-plain" 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ *$//')"
if [ "$hmd_got" = "704 705 708" ]; then
  ok "(2) the hmd matcher still claims exactly its OWN attributable orphans (got: $hmd_got)"
else
  bad "(2) hmd matcher changed — want '704 705 708' got '$hmd_got'"
fi
overlap=""
for pid in $got; do
  case " $hmd_got " in *" $pid "*) overlap="$overlap $pid" ;; esac
done
if [ -z "$overlap" ]; then
  ok "(2) the sets are DISJOINT — no process is both hmd-attributed and unattributed"
else
  bad "(2) DOUBLE COUNT:$overlap appears in both hmd_orphans and the unattributed set"
fi

# ── (3) --json: the honest field exists, and every pre-existing key survives ─────
js="$(HMD_SYSMON_PS_ROWS="$WORK/rows-plain" "$SYSMON" --json 2>/dev/null)"
unattr="$(printf '%s' "$js" | sed -n 's/.*"python_orphans_unattributed":\([0-9]*\).*/\1/p')"
hmdn="$(printf '%s' "$js" | sed -n 's/.*"hmd_orphans":\([0-9]*\).*/\1/p')"
[ "$unattr" = "2" ] && ok "(3) --json reports python_orphans_unattributed=2" \
  || bad "(3) --json python_orphans_unattributed wrong — want 2 got '$unattr' (json: $js)"
[ "$hmdn" = "3" ] && ok "(3) --json hmd_orphans stays 3 — the count was NOT folded in" \
  || bad "(3) --json hmd_orphans wrong — want 3 got '$hmdn' (a silent re-attribution)"
for k in status hmd_orphans python3_total runaway runaway_n; do
  printf '%s' "$js" | grep -q "\"$k\":" \
    && ok "(3) pre-existing JSON key '$k' still present (consumers unbroken)" \
    || bad "(3) JSON key '$k' DISAPPEARED — an existing consumer just broke"
done
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$js" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert isinstance(d["procs"]["python_orphans_unattributed"], int), d["procs"]
print("JSONOK")' 2>/dev/null | grep -q JSONOK \
    && ok "(3) --json still parses and the new field is an int" \
    || bad "(3) --json no longer parses or the new field is not an int: $js"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# FIXTURE B — rich rows `pid ppid pgid tty etime command…` (the REAP oracle's input).
# The reaper needs tty + age + pgid, which the plain shape does not carry.
# ══════════════════════════════════════════════════════════════════════════════════
# 800 = aged, detached, not ours                            → REAPABLE
# 801 = SAME shape but holds a controlling tty (ttys003)    → a human's shell: NEVER
# 802 = detached but only 30s old                           → too young: NEVER
# 803 = over a day old, detached                            → REAPABLE
# 804 = aged + detached but runs a real script path         → not the bare shape: NEVER
# 805 = aged + detached but its PID is in the caller's tree → NEVER (the pid-71532 rule)
# 806 = aged + detached but its PGID is in the caller's tree→ NEVER
# 807 = bare + detached + aged but has a LIVE parent        → not orphaned: NEVER
cat > "$WORK/rows-rich" <<'ROWS'
800 1 800 ?? 05:00:00 /usr/bin/python3 -
801 1 801 ttys003 05:00:00 /usr/bin/python3 -
802 1 802 ?? 00:00:30 /usr/bin/python3 -
803 1 803 ?? 1-02:00:00 /opt/homebrew/bin/python3 -
804 1 804 ?? 05:00:00 /usr/bin/python3 /Users/rj/work/train.py
805 1 805 ?? 05:00:00 /usr/bin/python3 -
806 1 900 ?? 05:00:00 /usr/bin/python3 -
807 501 807 ?? 05:00:00 /usr/bin/python3 -
ROWS

SELF_SET="805 900"
reapable() {
  HMD_BAREPY_SELF_EXCLUDE="$SELF_SET" "$SYSMON" --filter-reapable-python-orphans \
    < "$WORK/rows-rich" 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ *$//'
}

# ── (4) THE GUARDS BITE ──────────────────────────────────────────────────────────
rgot="$(reapable)"
if [ "$rgot" = "800 803" ]; then
  ok "(4) reap scope = aged + detached + not-ours only (got: $rgot)"
else
  bad "(4) reap scope wrong — want '800 803' got '$rgot'"
fi
case " $rgot " in *" 801 "*) bad "(4) a tty-ATTACHED process is in the reap set — that is a human's shell" ;;
                  *) ok "(4) tty-attached 801 REFUSED (no controlling terminal is required)" ;; esac
case " $rgot " in *" 802 "*) bad "(4) a 30-SECOND-OLD process is in the reap set — the age floor is not enforced" ;;
                  *) ok "(4) young 802 REFUSED (age floor enforced)" ;; esac
case " $rgot " in *" 805 "*) bad "(4) the CALLER'S OWN pid is in the reap set" ;;
                  *) ok "(4) self-tree pid 805 REFUSED" ;; esac
case " $rgot " in *" 806 "*) bad "(4) a process in the caller's own PGID is in the reap set" ;;
                  *) ok "(4) self-tree pgid 900 REFUSED" ;; esac
case " $rgot " in *" 807 "*) bad "(4) a process with a LIVE parent is in the reap set" ;;
                  *) ok "(4) non-orphan 807 REFUSED (ppid!=1)" ;; esac
case " $rgot " in *" 804 "*) bad "(4) a python with a real script path is in the reap set" ;;
                  *) ok "(4) script-path 804 REFUSED (only the bare stdin shape is in scope)" ;; esac

# ── (5) REAP ⊆ DETECT — a reaper can never exceed its own detector ───────────────
rich_detect="$(awk '{ printf "%s %s", $1, $2; for(i=6;i<=NF;i++) printf " %s", $i; print "" }' "$WORK/rows-rich" \
  | "$SYSMON" --filter-bare-python-orphans 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ *$//')"
esc=""
for pid in $rgot; do
  case " $rich_detect " in *" $pid "*) ;; *) esc="$esc $pid" ;; esac
done
if [ -z "$esc" ]; then
  ok "(5) every reap target is also DETECTED (reap set ⊆ detected set)"
else
  bad "(5) reap set ESCAPED the detector:$esc — killing something the monitor cannot see"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# heimdall-cleanup — the orchestrator: surfacing + the guarded reap
# ══════════════════════════════════════════════════════════════════════════════════
cat > "$WORK/kill-stub" <<EOF
#!/usr/bin/env bash
for p in "\$@"; do echo "\$p" >> "$WORK/killed"; done
exit 0
EOF
chmod +x "$WORK/kill-stub"
: > "$WORK/killed"

# a gc that finds nothing (TTL far in the future, no versions dir) so disk never confuses
# the process assertions, and HEIMDALL_HOME is a temp dir so the real ~/.heimdall is untouched.
run_clean() {
  HMD_CLEANUP_OS=Darwin \
  HMD_CLEANUP_PS_ROWS="$WORK/rows-plain" HMD_CLEANUP_PS_ROWS_FULL="$WORK/rows-rich" \
  HMD_CLEANUP_KILL_CMD="$WORK/kill-stub" HMD_BAREPY_SELF_EXCLUDE="$SELF_SET" \
  HMD_GC_TMP_ROOTS="$WORK/gctmp-empty" HMD_GC_TEMP_TTL_MIN=99999 \
  HMD_GC_CC_VERSIONS="$WORK/versions-none" \
  HEIMDALL_HOME="$WORK/home-empty" \
  bash "$CLEAN" --repo "$WORK/home-empty" "$@" 2>&1
}

# ── (6) --apply signals EXACTLY the guarded set ──────────────────────────────────
: > "$WORK/killed"
run_clean --apply >/dev/null 2>&1
killed="$(sort -n "$WORK/killed" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
for pid in 800 803; do
  grep -qx "$pid" "$WORK/killed" 2>/dev/null \
    && ok "(6) --apply reaped the aged detached orphan $pid" \
    || bad "(6) --apply did NOT reap $pid (killed: $killed)"
done
for pid in 801 802 805 806 807 804; do
  grep -qx "$pid" "$WORK/killed" 2>/dev/null \
    && bad "(6) --apply SIGNALLED guarded-out pid $pid (killed: $killed)" \
    || ok "(6) --apply never signalled guarded-out pid $pid"
done

# ── (7) --auto NEVER reaps an unattributed process (ownership unproven) ──────────
# The hook path must not act on processes hmd cannot prove are its own, at ANY count.
: > "$WORK/killed"
HMD_SYSMON_ORPHAN_CRIT=1 HMD_CLEANUP_BAREPY_ADVISE_MIN=1 run_clean --auto >/dev/null 2>&1
for pid in 800 803; do
  grep -qx "$pid" "$WORK/killed" 2>/dev/null \
    && bad "(7) --auto reaped unattributed pid $pid — the hook must never act on unproven ownership" \
    || ok "(7) --auto left unattributed pid $pid alone"
done

# ── (8) --advise: ONE line, the count surfaced, and the LIE retracted ────────────
# Reproduces 2026-08-08: high memory pressure, zero attributable hmd orphans, a pile of
# unattributed ones. The old advisory said "NOT heimdall" flatly. It must not any more.
cat > "$WORK/sysmon-fake" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --json)                            cat "$SYSMON_JSON" ;;
  --filter-orphans)                  [ -n "${SYSMON_ORPHANS:-}" ] && printf '%s\n' $SYSMON_ORPHANS || true ;;
  --filter-bare-python-orphans)      [ -n "${SYSMON_BAREPY:-}" ] && printf '%s\n' $SYSMON_BAREPY || true ;;
  --filter-reapable-python-orphans)  [ -n "${SYSMON_BAREPY:-}" ] && printf '%s\n' $SYSMON_BAREPY || true ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/sysmon-fake"

# the machine as measured: swap 94%, wired 85%, hmd_orphans 0, 224 unattributed.
cat > "$WORK/json-blind" <<'EOF'
{"severity":"warn","disk":{"status":"ok","used_pct":50,"free_bytes":0,"total_bytes":0},"memory":{"status":"warn","swap_used_pct":94,"swap_used_g":16.0,"swap_total_g":17.0,"wired_pct":85,"free_pct":2},"procs":{"status":"warn","hmd_orphans":0,"python_orphans_unattributed":224,"python3_total":230,"runaway":"python3","runaway_n":230}}
EOF
# the same machine with a clean process table — the control.
cat > "$WORK/json-clean" <<'EOF'
{"severity":"warn","disk":{"status":"ok","used_pct":50,"free_bytes":0,"total_bytes":0},"memory":{"status":"warn","swap_used_pct":94,"swap_used_g":16.0,"swap_total_g":17.0,"wired_pct":85,"free_pct":2},"procs":{"status":"ok","hmd_orphans":0,"python_orphans_unattributed":0,"python3_total":1,"runaway":"","runaway_n":0}}
EOF

# the wired-holder probe shells out to /sbin/mount. Left un-injected it makes every byte
# assertion below a function of how many CoreSimulator volumes happen to be mounted on the
# host — 42 more bytes on a machine with one, none on CI. Stub it to a machine with no
# holders so the line length measured here is the line length the code produces.
cat > "$WORK/mount-none" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/mount-none"

CBIN="$CLEAN"
advise() { # <json file> [extra argv…]
  local json="$1"; shift
  HMD_CLEANUP_OS=Darwin HMD_CLEANUP_SYSMON="$WORK/sysmon-fake" \
  SYSMON_JSON="$json" SYSMON_ORPHANS="" SYSMON_BAREPY="" \
  HMD_CLEANUP_MOUNT_CMD="$WORK/mount-none" \
  HMD_CLEANUP_DEADCODE="$WORK/none-deadcode" \
  HMD_CLEANUP_PS_ROWS="$WORK/rows-plain" HMD_CLEANUP_PS_ROWS_FULL="$WORK/rows-rich" \
  HMD_GC_TMP_ROOTS="$WORK/gctmp-empty" HMD_GC_TEMP_TTL_MIN=99999 \
  HMD_GC_CC_VERSIONS="$WORK/versions-none" \
  HEIMDALL_HOME="$WORK/home-empty" \
  bash "$CBIN" --advise --quick --repo "$WORK/home-empty" "$@" 2>&1
}

BUDGET=420   # the SessionStart one-line budget, identical to test/sessionstart-quiet.test.sh
ablind="$(advise "$WORK/json-blind")"
al="$(grep -c '' <<<"$ablind" || true)"
ab="$(printf '%s' "$ablind" | wc -c | tr -d ' ')"

[ -n "$ablind" ] && ok "(8) --advise SPEAKS when unattributed orphans are present" \
  || bad "(8) --advise went silent on the exact machine state that lied on 2026-08-08"
[ "$al" -eq 1 ] && ok "(8) --advise is still exactly ONE line (SessionStart budget kept)" \
  || bad "(8) --advise emitted $al lines, expected 1: $(printf '%s' "$ablind" | tr '\n' '|')"
[ "$ab" -le "$BUDGET" ] && ok "(8) --advise line is ${ab}B (budget ${BUDGET}B)" \
  || bad "(8) --advise line is ${ab}B, over the ${BUDGET}B budget"
grep -q '224' <<<"$ablind" \
  && ok "(8) the advisory cites the MEASURED unattributed count (224)" \
  || bad "(8) the unattributed count never reached the advisory: $ablind"
grep -qi 'NOT heimdall' <<<"$ablind" \
  && bad "(8) the advisory STILL claims 'NOT heimdall' while 224 unattributable orphans are alive — this is the 2026-08-08 lie" \
  || ok "(8) the advisory no longer claims 'NOT heimdall' when ownership is unproven"
grep -qiE 'unattributed|unproven|cannot prove' <<<"$ablind" \
  && ok "(8) the advisory says the attribution is UNPROVEN rather than guessing" \
  || bad "(8) the advisory attributes the pile without proof: $ablind"

# the control: a genuinely clean process table must STILL say NOT heimdall (the honest
# reassurance RJ asked for originally). Losing it would be the opposite overcorrection.
aclean="$(advise "$WORK/json-clean")"
grep -qi 'NOT heimdall' <<<"$aclean" \
  && ok "(8) with a CLEAN process table the advisory still says NOT heimdall (honesty both ways)" \
  || bad "(8) the clean-machine reassurance was lost: $aclean"

# ══════════════════════════════════════════════════════════════════════════════════
# (9) PROVE-DETECTS — neither "clean" verdict above may be vacuous.
# ══════════════════════════════════════════════════════════════════════════════════
# 9a. A matcher with the bare-stdin clause REMOVED must make case (1) go RED. If (1) still
#     passes against the mutant, it is not testing detection at all.
MUT_BLIND="$WORK/sysmon.blind"
sed 's/^BAREPY_MATCH=.*$/BAREPY_MATCH="__never_matches_anything__"/' "$SYSMON" > "$MUT_BLIND"
if cmp -s "$MUT_BLIND" "$SYSMON"; then
  bad "(9a) PROVE-DETECTS: the BAREPY_MATCH anchor is missing from bin/heimdall-sysmon"
else
  chmod +x "$MUT_BLIND"
  mgot="$("$MUT_BLIND" --filter-bare-python-orphans < "$WORK/rows-plain" 2>/dev/null | tr -d '[:space:]')"
  [ -z "$mgot" ] \
    && ok "(9a) PROVE-DETECTS: a blinded matcher detects NOTHING → case (1) is falsifiable" \
    || bad "(9a) PROVE-DETECTS: the blinded matcher still matched '$mgot' — case (1) cannot fail"
fi

# 9b. A WIDENED matcher (one that matches every PPID=1 row) must make the exclusion
#     assertions in (1a) and the guards in (4) go RED. A detector that reads "clean" only
#     because it matches everything is the same blindness wearing the opposite mask.
MUT_WIDE="$WORK/sysmon.wide"
sed 's/^BAREPY_MATCH=.*$/BAREPY_MATCH="."/' "$SYSMON" > "$MUT_WIDE"
if cmp -s "$MUT_WIDE" "$SYSMON"; then
  bad "(9b) PROVE-DETECTS: the BAREPY_MATCH anchor is missing from bin/heimdall-sysmon"
else
  chmod +x "$MUT_WIDE"
  wgot="$("$MUT_WIDE" --filter-bare-python-orphans < "$WORK/rows-plain" 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ *$//')"
  if [ "$wgot" != "700 701" ] && printf '%s' "$wgot" | grep -q '703'; then
    ok "(9b) PROVE-DETECTS: a widened matcher swallows foreign rows → case (1a) is falsifiable"
  else
    bad "(9b) PROVE-DETECTS: widening the matcher changed nothing (got '$wgot') — (1a) is a tautology"
  fi
  wreap="$(HMD_BAREPY_SELF_EXCLUDE="$SELF_SET" "$MUT_WIDE" --filter-reapable-python-orphans \
    < "$WORK/rows-rich" 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ *$//')"
  if printf '%s' "$wreap" | grep -q '804'; then
    ok "(9b) PROVE-DETECTS: a widened matcher reaches a script-path proc → case (4) is falsifiable"
  else
    bad "(9b) PROVE-DETECTS: widening did not change the reap scope (got '$wreap') — (4) is a tautology"
  fi
  # …and the guards must STILL hold even on the widened matcher: widening the SHAPE test
  # must never disarm the tty / age / self-tree checks, which are the safety-critical half.
  for pid in 801 802 805 806; do
    case " $wreap " in
      *" $pid "*) bad "(9b) the widened matcher also disarmed a GUARD (pid $pid reachable) — guards must be independent of the shape test" ;;
      *)          ok  "(9b) guard for pid $pid holds even under a widened shape matcher" ;;
    esac
  done
fi

# ── 10. THE SOURCE. Detecting the pile is half the fix; this is the emitter that made it. ──
# `heimdall-control-plane serve` runs cp_server.serve() → httpd.serve_forever() from a BARE
# STDIN heredoc, which is why the leak renders as `python3 -` with nothing to attribute it.
# Evidence (2026-08-10, live orphans on the reporting machine): lsof on two independent
# ppid-1 orphans showed fd 0 = a 526-byte /private/var/tmp/sh-thd-* heredoc temp file AT EOF
# — so stdin never blocked — while fd 1/2 pointed at a dead test's serve.out/serve.err. A
# sweep of all 316 `… - <<TAG` heredocs in this repo found exactly ONE 526-byte bare-stdin
# body: bin/heimdall-control-plane's `serve`.
#
# Structured exactly like test/heimdall-mock-cp-watchdog.test.sh, the suite that already
# proves this convention for the mock fixtures: (a) the SHIPPED emitter carries the guard,
# (b) the guard logic actually terminates an orphan. Both halves are required — (a) alone
# would pass against a guard that never fires.
CP="$ROOT/bin/heimdall-control-plane"
if grep -q '_watchdog' "$CP" && grep -q 'HMD_CP_GUARD_PID' "$CP" && grep -q 'os._exit' "$CP"; then
  ok "(10) the serve emitter carries the orphan-death watchdog"
else
  bad "(10) bin/heimdall-control-plane serve is MISSING the watchdog — serve_forever() can leak again"
fi
# The guard must key on an EXPLICIT pid, never on ppid==1: a server launched through command
# substitution reparents to launchd mid-run, so a ppid guard would kill a LIVE server. This
# pins the safe design in place so a later "simplification" to getppid()==1 goes red.
if grep -q 'getppid' "$CP"; then
  bad "(10) the guard uses getppid — a ppid==1 guard kills LIVE servers reparented by command substitution"
else
  ok "(10) the guard keys on an explicit pid, not ppid==1 (live servers stay safe)"
fi
# Unset guard ⇒ no watchdog at all, so a supervised/nohup deployment is untouched.
if grep -q 'HMD_CP_GUARD_PID.*or "0"' "$CP"; then
  ok "(10) an unset guard disables the watchdog (nohup/supervised deployments unaffected)"
else
  bad "(10) the watchdog is not opt-in — an unset HMD_CP_GUARD_PID must leave the server alone"
fi

# (b) the guard WORKS. Models the SHIPPED loop against a real process, hermetically: the
# guard is a sleep we own, the watched program is a serve_forever stand-in, and the only
# pids signalled are ones this test created.
if command -v python3 >/dev/null 2>&1; then
  sleep 60 & GUARD=$!
  HMD_CP_GUARD_PID="$GUARD" python3 - <<'PY' >"$WORK/guard.out" 2>&1 &
import os, sys, threading, time
_guard = int(os.environ.get("HMD_CP_GUARD_PID") or "0")
if _guard > 0:
    def _watchdog(pid):
        while True:
            try:
                os.kill(pid, 0)
            except OSError:
                os._exit(0)
            time.sleep(0.1)
    threading.Thread(target=_watchdog, args=(_guard,), daemon=True).start()
time.sleep(30)
PY
  WATCHED=$!
  # it must still be alive while the guard lives — otherwise the next assertion proves nothing.
  if kill -0 "$WATCHED" 2>/dev/null; then
    ok "(10) the guarded server stays alive while its guard lives"
  else
    bad "(10) the guarded server died with its guard still alive — the watchdog is trigger-happy"
  fi
  kill -9 "$GUARD" 2>/dev/null || true      # SIGKILL: no chance to clean up after itself
  wait "$GUARD" 2>/dev/null || true
  gone=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$WATCHED" 2>/dev/null || { gone=1; break; }
    sleep 0.25
  done
  if [ -n "$gone" ]; then
    ok "(10) the server self-terminated when its guard was SIGKILLed (no orphan left behind)"
  else
    bad "(10) the server LEAKED after its guard was SIGKILLed — the watchdog does not fire"
  fi
  kill -9 "$WATCHED" 2>/dev/null || true    # never leave this suite's own process behind
  wait "$WATCHED" 2>/dev/null || true
else
  echo "  SKIP (10) watchdog behaviour (no python3)"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# (11) THE ORPHAN AXIS FIRES INDEPENDENTLY OF THE MEMORY AXIS
# ══════════════════════════════════════════════════════════════════════════════════
# THE SECOND SILENCE. Case (8) fixed WHAT the advisory says once it speaks. This fixes
# WHETHER it speaks at all. do_advise reached its emitter only through a memory-pressure
# gate, so on a machine with healthy RAM an orphan pile of ANY size produced no output:
# `heimdall-cleanup --advise` was a memory monitor wearing an orphan monitor's name. The two
# are INDEPENDENT axes — the 224 processes measured on 2026-08-08 accumulated over a day, and
# a machine that simply had not started swapping yet would have been told nothing at all. A
# monitor that can only speak while a DIFFERENT monitor is already alarmed adds no signal,
# and its silence is once again indistinguishable from health.
#
# The floors are the ones this codebase already defines, REUSED rather than re-invented:
#   · ORPHAN_WARN (20)        — the count at which hmd already suggests reaping its own leak
#   · BAREPY_ADVISE_MIN (40)  — the pile-up floor for orphans hmd cannot attribute
# Below both, silence is CORRECT, and (11d) pins that: an advisory that fires over a handful
# of processes is the one that gets tuned out before the real signal arrives.
#
# Memory reads HEALTHY in every fixture here (swap 5%, wired 22% — far under the 80/80 reboot
# thresholds), so the orphan axis is the only thing that can make the advisory speak.
mk_json() { # <file> <swap_pct> <swap_used_g> <swap_total_g> <wired_pct> <hmd_orphans> <unattributed>
  cat > "$1" <<EOF
{"severity":"warn","disk":{"status":"ok","used_pct":50,"free_bytes":0,"total_bytes":0},"memory":{"status":"ok","swap_used_pct":$2,"swap_used_g":$3,"swap_total_g":$4,"wired_pct":$5,"free_pct":40},"procs":{"status":"warn","hmd_orphans":$6,"python_orphans_unattributed":$7,"python3_total":9,"runaway":"","runaway_n":0}}
EOF
}
mk_json "$WORK/json-ok-hmdpile"   5  0.4  8.0 22 24   0
mk_json "$WORK/json-ok-barepile"  5  0.4  8.0 22  0 224
mk_json "$WORK/json-ok-clean"     5  0.4  8.0 22  0   0
mk_json "$WORK/json-ok-below"     5  0.4  8.0 22  3   5
mk_json "$WORK/json-high-both"   94 16.0 17.0 85 24 224

# the ATTRIBUTABLE count reaches heimdall-cleanup through sysmon's --filter-orphans oracle
# (the fake echoes SYSMON_ORPHANS), the UNATTRIBUTED one through the --json field. Both are
# the documented seams; no live process is read and none is signalled.
ORPH24="$(seq 91000 91023 | tr '\n' ' ')"

advise_axes() { # <json file> <orphan pid list> [extra argv…]
  local json="$1" orphans="$2"; shift 2
  HMD_CLEANUP_OS=Darwin HMD_CLEANUP_SYSMON="$WORK/sysmon-fake" \
  SYSMON_JSON="$json" SYSMON_ORPHANS="$orphans" SYSMON_BAREPY="" \
  HMD_CLEANUP_MOUNT_CMD="$WORK/mount-none" \
  HMD_CLEANUP_DEADCODE="$WORK/none-deadcode" \
  HMD_CLEANUP_PS_ROWS="$WORK/rows-plain" HMD_CLEANUP_PS_ROWS_FULL="$WORK/rows-rich" \
  HMD_GC_TMP_ROOTS="$WORK/gctmp-empty" HMD_GC_TEMP_TTL_MIN=99999 \
  HMD_GC_CC_VERSIONS="$WORK/versions-none" \
  HEIMDALL_HOME="$WORK/home-empty" \
  bash "$CBIN" --advise --quick --repo "$WORK/home-empty" "$@" 2>&1
}

# ── (11a) healthy memory + an ATTRIBUTABLE pile → the advisory FIRES ──────────────
a_hmd="$(advise_axes "$WORK/json-ok-hmdpile" "$ORPH24")"
ahl="$(grep -c '' <<<"$a_hmd" || true)"
ahb="$(printf '%s' "$a_hmd" | wc -c | tr -d ' ')"
[ -n "$a_hmd" ] \
  && ok "(11a) healthy memory + 24 attributable hmd orphans → the advisory FIRES" \
  || bad "(11a) SILENT with 24 hmd orphans on a healthy machine — the orphan monitor is still gated behind the memory monitor"
[ "$ahl" -eq 1 ] \
  && ok "(11a) the orphan-axis advisory is exactly ONE line (SessionStart budget kept)" \
  || bad "(11a) orphan-axis advisory emitted $ahl lines, expected 1: $(printf '%s' "$a_hmd" | tr '\n' '|')"
[ "$ahb" -le "$BUDGET" ] \
  && ok "(11a) the orphan-axis line is ${ahb}B (budget ${BUDGET}B)" \
  || bad "(11a) the orphan-axis line is ${ahb}B, over the ${BUDGET}B budget"
grep -qE '(^| )24 orphaned' <<<"$a_hmd" \
  && ok "(11a) it cites the MEASURED attributable count (24)" \
  || bad "(11a) the attributable count never reached the advisory: $a_hmd"
grep -q 'heimdall-cleanup --apply' <<<"$a_hmd" \
  && ok "(11a) it carries the runnable remedy for the leak hmd CAN prove is its own" \
  || bad "(11a) no remedy offered for hmd's own leak: $a_hmd"
grep -qi 'memory pressure HIGH' <<<"$a_hmd" \
  && bad "(11a) it claims memory pressure is HIGH on a machine reading swap 5% / wired 22% — a fabricated figure" \
  || ok "(11a) it does NOT fabricate memory pressure in order to have something to say"
grep -q 'wired 22%' <<<"$a_hmd" \
  && ok "(11a) it still cites the real (healthy) memory reading — no bare claim" \
  || bad "(11a) the measured memory reading was dropped from the line: $a_hmd"
printf '%s' "$a_hmd" | grep -q -- '--verbose' \
  && ok "(11a) it points at --verbose for the detail" \
  || bad "(11a) no pointer to --verbose — the detail became undiscoverable: $a_hmd"

# ── (11b) healthy memory + an UNATTRIBUTED pile → fires, and claims NOTHING ───────
a_bare="$(advise_axes "$WORK/json-ok-barepile" "")"
abl="$(grep -c '' <<<"$a_bare" || true)"
abb="$(printf '%s' "$a_bare" | wc -c | tr -d ' ')"
[ -n "$a_bare" ] \
  && ok "(11b) healthy memory + 224 unattributed orphans → the advisory FIRES" \
  || bad "(11b) SILENT with 224 unattributed orphans on a healthy machine — the 2026-08-08 pile again"
[ "$abl" -eq 1 ] \
  && ok "(11b) the unattributed-axis advisory is exactly ONE line" \
  || bad "(11b) emitted $abl lines, expected 1: $(printf '%s' "$a_bare" | tr '\n' '|')"
[ "$abb" -le "$BUDGET" ] \
  && ok "(11b) the unattributed-axis line is ${abb}B (budget ${BUDGET}B)" \
  || bad "(11b) the unattributed-axis line is ${abb}B, over the ${BUDGET}B budget"
grep -q '224' <<<"$a_bare" \
  && ok "(11b) it cites the MEASURED unattributed count (224)" \
  || bad "(11b) the unattributed count never reached the advisory: $a_bare"
grep -qiE 'unattributed|unproven|cannot prove' <<<"$a_bare" \
  && ok "(11b) it says the attribution is UNPROVEN rather than guessing" \
  || bad "(11b) it attributes the pile without proof: $a_bare"
grep -qi 'NOT heimdall' <<<"$a_bare" \
  && bad "(11b) it DENIES ownership of a pile whose ownership is unproven — the 2026-08-08 lie" \
  || ok "(11b) it neither claims nor denies a pile it cannot attribute"
grep -qi 'aged' <<<"$a_bare" \
  && ok "(11b) the remedy is qualified (aged+detached only) — it never offers a blind reap" \
  || bad "(11b) the remedy implies hmd will reap unproven processes blindly: $a_bare"

# ── (11c) healthy memory + ZERO orphans → SILENT ─────────────────────────────────
a_clean="$(advise_axes "$WORK/json-ok-clean" "")"
[ -z "$a_clean" ] \
  && ok "(11c) healthy memory + zero orphans → SILENT (a healthy machine is never nagged)" \
  || bad "(11c) the advisory spoke on a machine with nothing wrong on either axis: $a_clean"

# ── (11d) healthy memory + counts BELOW both floors → SILENT ─────────────────────
a_below="$(advise_axes "$WORK/json-ok-below" "100 101 102")"
[ -z "$a_below" ] \
  && ok "(11d) 3 attributable + 5 unattributed (both under the floors) → SILENT (not a nag)" \
  || bad "(11d) the advisory fired below both documented floors — this is how a real signal gets tuned out: $a_below"

# ── (11e) BOTH axes true → still exactly ONE line ────────────────────────────────
a_both="$(advise_axes "$WORK/json-high-both" "$ORPH24")"
abol="$(grep -c '' <<<"$a_both" || true)"
abob="$(printf '%s' "$a_both" | wc -c | tr -d ' ')"
[ "$abol" -eq 1 ] \
  && ok "(11e) memory pressure AND an orphan pile → ONE line, not two" \
  || bad "(11e) both axes true emitted $abol lines: $(printf '%s' "$a_both" | tr '\n' '|')"
[ "$abob" -le "$BUDGET" ] \
  && ok "(11e) the both-axes line is ${abob}B (budget ${BUDGET}B)" \
  || bad "(11e) the both-axes line is ${abob}B, over the ${BUDGET}B budget"
if grep -qE '(^| )24 orphaned' <<<"$a_both" && grep -q '224' <<<"$a_both"; then
  ok "(11e) the one line carries BOTH counts (reaping hmd's own leak must not look like the whole story)"
else
  bad "(11e) a count was dropped when both axes fired: $a_both"
fi
grep -qi 'Part of it IS heimdall' <<<"$a_both" \
  && ok "(11e) under real pressure it still owns hmd's share explicitly" \
  || bad "(11e) the attribution of hmd's own share was lost: $a_both"

# ── (11f) PROVE-RED: the gate is threshold-driven, so it can be suppressed ────────
# Crank BOTH orphan floors past the fixture and the SAME pile must go silent. If it still
# speaks, (11a)/(11b) are tautologies — an advisory that always fires proves nothing.
a_supp="$(HMD_SYSMON_ORPHAN_WARN=100000 HMD_CLEANUP_BAREPY_ADVISE_MIN=100000 \
  advise_axes "$WORK/json-ok-barepile" "$ORPH24")"
[ -z "$a_supp" ] \
  && ok "(11f) PROVE-RED: cranking both orphan floors silences the SAME pile → (11a)/(11b) are falsifiable" \
  || bad "(11f) PROVE-RED: the advisory spoke with both floors at 100000 — it is not gated on the documented thresholds: $a_supp"

echo
printf 'orphan-python-detection: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ]

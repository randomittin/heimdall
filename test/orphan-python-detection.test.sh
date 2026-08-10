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

CBIN="$CLEAN"
advise() { # <json file> [extra argv…]
  local json="$1"; shift
  HMD_CLEANUP_OS=Darwin HMD_CLEANUP_SYSMON="$WORK/sysmon-fake" \
  SYSMON_JSON="$json" SYSMON_ORPHANS="" SYSMON_BAREPY="" \
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

echo
printf 'orphan-python-detection: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ]

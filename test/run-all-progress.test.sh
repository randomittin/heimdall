#!/usr/bin/env bash
# test/run-all-progress.test.sh — a live sweep must be tellable from a dead one.
#
# WHY THIS EXISTS. test/run-all.sh produced NO incremental output at all: the table,
# summary, and receipt only print after BOTH the parallel phase and the serial red-retry
# phase fully finish. Piped to a logfile (exactly how a background sweep is run), a
# healthy sweep 23 minutes into one slow suite and a DEAD one look byte-identical — both
# show a handful of startup lines and nothing since. This measurably caused two
# "nothing is running" misreports (the sweep was actually healthy) and two "sweep is
# running" misreports (it had actually exited) in the same session — all four trace to
# the same root cause: the log never answers "is this alive, and where is it."
#
# FALSIFIABLE claims proven, hermetically, against a tiny fixture suite set (never the
# repo's real ~400-suite sweep):
#   1. GROWTH — per-suite completion lines are written AS THEY HAPPEN. Sampled while the
#      real backgrounded invocation is still alive, the log's line count genuinely GROWS
#      across multiple distinct samples — not "0 lines, then everything at once" only
#      once the process has already exited.
#   2. HEARTBEAT — a deliberately slow (but passing) fixture suite triggers at least one
#      heartbeat line naming it, and that heartbeat is proven (by line position within
#      the same log) to land BEFORE the slow suite's own completion line — i.e. while it
#      was still in flight, not after the fact.
#   3. FORMAT UNCHANGED — the documented summary/receipt/table lines this fixture run
#      must produce (suites/assertions/tree-integrity/sweep receipt/table header/RUN
#      GREEN) appear byte-for-byte as already documented in test/run-all.sh's own
#      header comment, proving the new incremental lines are additive only.
#
# HEIMDALL_HEARTBEAT_SECS lets this test shrink the ~30s production heartbeat-silence
# threshold to a couple of seconds, so the whole file runs in single-digit seconds
# instead of 30+: the fixture "slow" suite only needs to outlast the (shrunk) threshold,
# not the real one. Left unset, run-all.sh defaults to 30s exactly as specified.
#
# HERMETIC. Runs inside a throwaway `git init` repo under $TMPDIR against six trivial
# fixture suites (five instant, one sleeping ~6s) — never the repo's own test/ directory,
# and HEIMDALL_HOME is explicitly unset so the fixture's own receipt can never land on
# top of a real one.
#
# EXIT: 0 = every proof holds; 1 = any FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUN_ALL="$ROOT/test/run-all.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -f "$RUN_ALL" ] || { echo "FATAL: missing $RUN_ALL" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-run-all-progress.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Defensive, same reason test/sweep-receipt-gate.test.sh unsets it: never let an ambient
# HEIMDALL_HOME leak a fixture receipt on top of a real one.
unset HEIMDALL_HOME 2>/dev/null || true

echo "════════════════════════════════════════════════════════════════"
echo "run-all progress/heartbeat — a live sweep must be tellable from a dead one"
echo "════════════════════════════════════════════════════════════════"

# ── build the fixture repo: 5 instant suites + 1 deliberately slow one ─────────────────
PW="$WORK/repo"
mkdir -p "$PW/test"
( cd "$PW" && git init -q && git config user.email dev@example.com && git config user.name Dev )
cp "$RUN_ALL" "$PW/test/run-all.sh"

for n in a b c d e; do
  cat > "$PW/test/${n}-fast.test.sh" <<'EOF'
#!/usr/bin/env bash
# fixture: instant, always-green suite for test/run-all-progress.test.sh
set -uo pipefail
echo "1 passed, 0 failed"
exit 0
EOF
  chmod +x "$PW/test/${n}-fast.test.sh"
done

cat > "$PW/test/z-slow.test.sh" <<'EOF'
#!/usr/bin/env bash
# fixture: deliberately slow (but passing) suite — exists only to give the heartbeat
# mechanism something to report on while it is the last suite still running.
set -uo pipefail
sleep 6
echo "1 passed, 0 failed"
exit 0
EOF
chmod +x "$PW/test/z-slow.test.sh"

git -C "$PW" add -A
git -C "$PW" commit -q -m "fixture: 5 fast + 1 slow suite + run-all.sh copy"

# ── run it backgrounded, sampling the log's line count while it is still alive ─────────
OUTFILE="$WORK/prog.out"
SNAPS="$WORK/snapshots.txt"
: > "$SNAPS"

( cd "$PW" && HEIMDALL_HEARTBEAT_SECS=2 bash test/run-all.sh --min 1 --jobs 6 >"$OUTFILE" 2>&1 ) &
RUN_PID=$!

ticks=0
while kill -0 "$RUN_PID" 2>/dev/null && [ "$ticks" -lt 300 ]; do
  if [ -f "$OUTFILE" ]; then
    n="$(grep -cE '^(progress|heartbeat) ' "$OUTFILE" 2>/dev/null)"
    printf '%s\n' "${n:-0}" >> "$SNAPS"
  else
    printf '0\n' >> "$SNAPS"
  fi
  ticks=$((ticks + 1))
  sleep 0.2
done
wait "$RUN_PID"
RUN_RC=$?

echo "-- 1. GROWTH: per-suite lines are written as they happen, not batched at the end --"
TOTAL_SAMPLES="$(wc -l < "$SNAPS" | tr -d '[:space:]')"
MAX_ALIVE="$(sort -n "$SNAPS" 2>/dev/null | tail -1 | tr -d '[:space:]')"
DISTINCT_NONZERO="$(awk '$1+0>0' "$SNAPS" 2>/dev/null | sort -u | wc -l | tr -d '[:space:]')"
MAX_ALIVE="${MAX_ALIVE:-0}"; DISTINCT_NONZERO="${DISTINCT_NONZERO:-0}"
[ "$MAX_ALIVE" -ge 3 ] \
  && ok "1a saw >=3 progress/heartbeat lines already present WHILE the sweep was still running (max observed while alive: $MAX_ALIVE, across $TOTAL_SAMPLES samples) — proves per-suite output happens before the run ends, not only in the final dump" \
  || bad "1a expected >=3 progress/heartbeat lines while alive, max observed was $MAX_ALIVE (of $TOTAL_SAMPLES samples)" "$(cat "$SNAPS")"
[ "$DISTINCT_NONZERO" -ge 2 ] \
  && ok "1b that count took >=2 distinct nonzero values while alive ($DISTINCT_NONZERO distinct) — proves genuine incremental growth over time, not one instantaneous jump" \
  || bad "1b expected >=2 distinct nonzero while-alive values, got $DISTINCT_NONZERO" "$(cat "$SNAPS")"

PROGRESS_LINES="$(grep -c '^progress ' "$OUTFILE" 2>/dev/null)"
PROGRESS_LINES="${PROGRESS_LINES:-0}"
[ "$PROGRESS_LINES" = 6 ] \
  && ok "1c exactly 6 progress lines, one per fixture suite completion" \
  || bad "1c expected 6 progress lines, got $PROGRESS_LINES" "$(cat "$OUTFILE")"

grep -qE '^progress \[[0-9]+s elapsed\] run [1-6]/6 (PASS|FAIL|TIMEOUT|UNPARSED|DISCREP) +[^ ]+\.test\.sh' "$OUTFILE" \
  && ok "1d progress lines carry elapsed time, done/total, status, and suite name" \
  || bad "1d progress line format unexpected" "$(grep '^progress ' "$OUTFILE")"

echo "-- 2. HEARTBEAT: a slow in-flight suite gets named before it finishes ------------"
HB_COUNT="$(grep -c '^heartbeat ' "$OUTFILE" 2>/dev/null)"
HB_COUNT="${HB_COUNT:-0}"
[ "$HB_COUNT" -ge 1 ] \
  && ok "2a at least one heartbeat line fired ($HB_COUNT total) while z-slow.test.sh was the only suite left" \
  || bad "2a expected >=1 heartbeat line, got $HB_COUNT" "$(cat "$OUTFILE")"

grep '^heartbeat ' "$OUTFILE" 2>/dev/null | grep -q 'z-slow.test.sh' \
  && ok "2b heartbeat names the in-flight suite (z-slow.test.sh)" \
  || bad "2b heartbeat did not name z-slow.test.sh" "$(grep '^heartbeat ' "$OUTFILE")"

HB_LINE="$(grep -n '^heartbeat ' "$OUTFILE" | head -1 | cut -d: -f1)"
ZDONE_LINE="$(grep -n '^progress .*z-slow\.test\.sh' "$OUTFILE" | head -1 | cut -d: -f1)"
if [ -n "${HB_LINE:-}" ] && [ -n "${ZDONE_LINE:-}" ] && [ "$HB_LINE" -lt "$ZDONE_LINE" ]; then
  ok "2c first heartbeat (line $HB_LINE) prints BEFORE z-slow's own completion line ($ZDONE_LINE) — proves it fired while still in flight, not after"
else
  bad "2c heartbeat did not precede z-slow's completion line" "heartbeat@${HB_LINE:-?} completion@${ZDONE_LINE:-?}"
fi

echo "-- 3. FORMAT UNCHANGED: summary/receipt/table lines stay byte-for-byte -----------"
grep -qF "suites: 6 ran, 0 skipped (live), 6 discovered of 6 globbed" "$OUTFILE" \
  && ok "3a suites summary line unchanged" \
  || bad "3a suites summary line missing/changed" "$(cat "$OUTFILE")"

grep -qF "assertions: 6 passed, 0 failed" "$OUTFILE" \
  && ok "3b assertions summary line unchanged" \
  || bad "3b assertions summary line missing/changed" "$(cat "$OUTFILE")"

grep -qF "tree-integrity: clean (before/after git status match; no tracked file touched, no root litter, no new stash)" "$OUTFILE" \
  && ok "3c tree-integrity line unchanged" \
  || bad "3c tree-integrity line missing/changed" "$(cat "$OUTFILE")"

grep -qE '^sweep receipt: .*\(exit_code=0, head=[0-9a-f]+, tree_clean=true\)$' "$OUTFILE" \
  && ok "3d sweep receipt line unchanged" \
  || bad "3d sweep receipt line missing/changed" "$(cat "$OUTFILE")"

grep -qE '^STATUS +SUITE +PASSED +FAILED +EXIT +TIME$' "$OUTFILE" \
  && ok "3e table header unchanged" \
  || bad "3e table header missing/changed" "$(cat "$OUTFILE")"

grep -qF "RUN GREEN" "$OUTFILE" \
  && ok "3f final verdict line unchanged (RUN GREEN)" \
  || bad "3f RUN GREEN line missing" "$(cat "$OUTFILE")"

[ "$RUN_RC" = 0 ] \
  && ok "3g process exit code unchanged semantics (0 on an all-green fixture run)" \
  || bad "3g expected exit 0, got $RUN_RC" "$(cat "$OUTFILE")"

echo "-- 4. STATUS MATRIX + RETRY PHASE: every outcome renders; retry only fires for real reds --"
# Sections 1-3 only ever exercise PASS (every fixture suite there is green), which leaves the
# FAIL/UNPARSED/DISCREP/TIMEOUT branches of _progress_fields, and the retry-phase call to
# _progress_line entirely unexercised — retry only re-runs suites with a genuinely nonzero
# exit (rc=124 or other), never UNPARSED/DISCREP (both rc=0 by definition), so this is the
# only place that path gets proven at all.
PW2="$WORK/repo2"
mkdir -p "$PW2/test"
( cd "$PW2" && git init -q && git config user.email dev@example.com && git config user.name Dev )
cp "$RUN_ALL" "$PW2/test/run-all.sh"

cat > "$PW2/test/r-pass.test.sh" <<'EOF'
#!/usr/bin/env bash
# fixture: control — a plain green suite alongside the four non-green shapes below.
set -uo pipefail
echo "1 passed, 0 failed"
exit 0
EOF

cat > "$PW2/test/r-fail.test.sh" <<'EOF'
#!/usr/bin/env bash
# fixture: a genuine, deterministic red — still red alone, so it is retried and stays FAIL.
set -uo pipefail
echo "0 passed, 1 failed"
exit 1
EOF

cat > "$PW2/test/r-unparsed.test.sh" <<'EOF'
#!/usr/bin/env bash
# fixture: exits 0 but prints no "N passed, M failed" line at all.
set -uo pipefail
echo "done, no parseable summary line"
exit 0
EOF

cat > "$PW2/test/r-discrep.test.sh" <<'EOF'
#!/usr/bin/env bash
# fixture: a SILENT red — prints a failure but exits 0 (DISCREPANCY, not FAIL).
set -uo pipefail
echo "0 passed, 1 failed"
exit 0
EOF

cat > "$PW2/test/r-timeout.test.sh" <<'EOF'
#!/usr/bin/env bash
# fixture: outlives the (deliberately shrunk) --timeout budget below.
set -uo pipefail
sleep 5
echo "1 passed, 0 failed"
exit 0
EOF
chmod +x "$PW2/test/"*.test.sh

git -C "$PW2" add -A
git -C "$PW2" commit -q -m "fixture: PASS/FAIL/UNPARSED/DISCREP/TIMEOUT + retry-phase coverage"

OUT2="$WORK/prog2.out"
( cd "$PW2" && bash test/run-all.sh --min 1 --jobs 5 --timeout 2 >"$OUT2" 2>&1 )
RC2=$?

grep -qE '^progress \[[0-9]+s elapsed\] run [0-9]+/5 PASS +r-pass\.test\.sh' "$OUT2" \
  && ok "4a run-phase progress line renders PASS" \
  || bad "4a PASS status line missing" "$(grep '^progress ' "$OUT2")"

grep -qE '^progress \[[0-9]+s elapsed\] run [0-9]+/5 FAIL +r-fail\.test\.sh' "$OUT2" \
  && ok "4b run-phase progress line renders FAIL" \
  || bad "4b FAIL status line missing" "$(grep '^progress ' "$OUT2")"

grep -qE '^progress \[[0-9]+s elapsed\] run [0-9]+/5 UNPARSED +r-unparsed\.test\.sh' "$OUT2" \
  && ok "4c run-phase progress line renders UNPARSED" \
  || bad "4c UNPARSED status line missing" "$(grep '^progress ' "$OUT2")"

grep -qE '^progress \[[0-9]+s elapsed\] run [0-9]+/5 DISCREP +r-discrep\.test\.sh' "$OUT2" \
  && ok "4d run-phase progress line renders DISCREP" \
  || bad "4d DISCREP status line missing" "$(grep '^progress ' "$OUT2")"

grep -qE '^progress \[[0-9]+s elapsed\] run [0-9]+/5 TIMEOUT +r-timeout\.test\.sh' "$OUT2" \
  && ok "4e run-phase progress line renders TIMEOUT" \
  || bad "4e TIMEOUT status line missing" "$(grep '^progress ' "$OUT2")"

grep -qE '^progress \[[0-9]+s elapsed\] retry [0-9]+/[0-9]+ FAIL +r-fail\.test\.sh' "$OUT2" \
  && ok "4f retry-phase progress line fires for the genuine FAIL red" \
  || bad "4f retry-phase FAIL line missing" "$(grep '^progress ' "$OUT2")"

grep -qE '^progress \[[0-9]+s elapsed\] retry [0-9]+/[0-9]+ TIMEOUT +r-timeout\.test\.sh' "$OUT2" \
  && ok "4g retry-phase progress line fires for the genuine TIMEOUT red" \
  || bad "4g retry-phase TIMEOUT line missing" "$(grep '^progress ' "$OUT2")"

grep -E '^progress .* retry ' "$OUT2" | grep -qE 'r-unparsed|r-discrep' \
  && bad "4h retry phase must NOT touch UNPARSED/DISCREP (both exit 0, never retried)" "$(grep '^progress .* retry ' "$OUT2")" \
  || ok "4h retry phase correctly skips UNPARSED/DISCREP (rc=0, never a red to retry)"

[ "$RC2" != 0 ] \
  && ok "4i overall exit code still reflects RED when real failures exist (unchanged verdict semantics)" \
  || bad "4i expected nonzero exit, got $RC2" "$(cat "$OUT2")"

echo
printf "  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

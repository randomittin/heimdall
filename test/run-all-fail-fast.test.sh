#!/usr/bin/env bash
# test/run-all-fail-fast.test.sh -- `run-all.sh --fail-fast` STOPS STARTING SUITES ONCE A RED IS CONFIRMED, AND A RED COMES UP IN THE FIRST SECONDS, NOT THE LAST.
#
# WHY THIS EXISTS. The 2.4.8 sweeps (3619 s and 2504 s) went red at 178 s and at 2028 s and kept running for 57 and 41 more minutes: the red was KNOWN, and nothing used it.
# Two changes to test/run-all.sh fix that, and a third keeps the shortcut from ever passing for a sweep:
#   1. ORDER. The suites that ran and came back non-green last time start first, then the suites with no recorded duration (new ones), then the slow ones
#      longest-first (the previous receipt's suite_durations, whole seconds; under 3 s is noise and keeps glob order), then the rest in glob order.
#   2. --fail-fast. Once a red is CONFIRMED -- re-run alone, as every red always was (with --jobs 1 or --no-retry the red already is a solo verdict) -- nothing more
#      is started. Suites already running finish; the ones never started are NOTRUN. A red that passes alone is FLAKY-UNDER-LOAD as ever and the sweep carries on.
#   3. THE RECEIPT of a stopped run is kind=aborted: exit_code 1, aborted{} names who stopped it, not_run_suites the suites that never started. It never becomes the
#      full-green anchor, and `bin/heimdall-state check-quality-gates` (the push gate) and release/ship.sh refuse it BY NAME, even with exit_code forged to 0.
#
# Proven here against throwaway git repos holding the REAL run-all.sh / bin/heimdall-state / release/ship.sh and fake suites (nothing touches this repo's receipts):
#   A  --jobs 1: the first red stops the run; the receipt, the table, the anchor.      T  --jobs 2: the red is re-run ALONE before the run stops; failed-first puts it first.
#   D  a red that passes alone stops nothing.                                           F  the order: failed-first, unknown, slowest-first, the floor, not-run is not failed.
#   C  durations survive a run that did not start every suite, and drop deleted ones.   H  the push gate refuses an aborted receipt, named, forged or not.
#   S  release/ship.sh refuses one the same way.                                        M  mutation proof: break one line at a time, each proof above must go red.
# Cost: about 25 s -- the fixture sweeps are sequential, the nine mutants run side by side.
# EXIT: 0 = every proof holds and every mutant is killed; 1 = any FAIL.
# shellcheck disable=SC2016  # the fixture suites are written LITERALLY: their $VARs must reach the file unexpanded
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUN_ALL="$ROOT/test/run-all.sh"
STATE_BIN="$ROOT/bin/heimdall-state"
SHIP="$ROOT/release/ship.sh"
LIB_HOOK="$ROOT/bin/lib/hook-owned-path.sh"
LIB_CHAIN="$ROOT/bin/lib/sweep-chain.sh"
# The copies a fixture gets: the real ones, except while a mutation proof (section M) hands it a broken one.
RA_SRC="$RUN_ALL"; STATE_SRC="$STATE_BIN"; SHIP_SRC="$SHIP"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in: $(printf '%s' "$2" | tail -c 700)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $(printf '%s' "$2" | tail -c 700)" ;; *) ok "$1" ;; esac; }
holds() { if "$2"; then ok "$1"; else bad "$1" "the predicate the mutation proof uses does not hold on the real tree"; fi; }

command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
for f in "$RUN_ALL" "$STATE_BIN" "$SHIP" "$LIB_HOOK" "$ROOT/release/sync-release.sh"; do [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-ff.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
mkdir -p "$WORK/tmp" "$WORK/home" "$WORK/mut"
cleanup() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
unset HEIMDALL_HOME 2>/dev/null || true
# `mark-clean` only sets lint_clean against a passing lint receipt (bin/heimdall-stop-lint writes it). These fixtures prove sweep receipts, not lint evidence,
# so they waive lint explicitly and visibly, as test/run-all-incremental.test.sh does.
LINT_WAIVER="fixture: run-all-fail-fast proves sweep receipts, not lint evidence"

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────────────────────────────
mksuite() { # dir name -- a fixture suite that logs each start to $MARKLOG. Env picks what it does: SLOW_SUITES (sleep SLOW_SECS), FLAKY_SUITES (red the first time only), RED_SUITES (always red)
  printf '%s\n' '#!/usr/bin/env bash' \
    'n="$(basename "$0" .test.sh)"' \
    '[ -n "${MARKLOG:-}" ] && echo "$n" >> "$MARKLOG"' \
    'case " ${SLOW_SUITES:-} " in *" $n "*) sleep "${SLOW_SECS:-0}" ;; esac' \
    'case " ${FLAKY_SUITES:-} " in *" $n "*) if [ ! -e "$FLAKY_DIR/$n" ]; then : > "$FLAKY_DIR/$n"; echo "  FAIL contention-only failure in $n"; echo "$n: 0 passed, 1 failed"; exit 1; fi ;; esac' \
    'case " ${RED_SUITES:-} " in *" $n "*) echo "  FAIL assertion in $n"; echo "$n: 0 passed, 1 failed"; exit 1 ;; esac' \
    'echo "$n: 1 passed, 0 failed"' > "$1/test/$2.test.sh"
}
mkfix() { # dir suite... -- a git repo holding the run-all.sh under test with its libs and the push gate, and one fixture suite per name
  local d="$1" s; shift
  mkdir -p "$d/test" "$d/bin/lib"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name T
  printf '.heimdall/\n' > "$d/.gitignore"
  cp "$RA_SRC" "$d/test/run-all.sh"
  cp "$LIB_HOOK" "$d/bin/lib/hook-owned-path.sh"
  [ -f "$LIB_CHAIN" ] && cp "$LIB_CHAIN" "$d/bin/lib/sweep-chain.sh"
  cp "$STATE_SRC" "$d/bin/heimdall-state"
  for s in "$@"; do mksuite "$d" "$s"; done
  git -C "$d" add -A
  git -C "$d" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm fixture
}
cm() { git -C "$1" add -A && git -C "$1" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm "${2:-change}"; }
runit() { # dir [run-all args] -> OUT, RC. $dir.marks gets one line per suite start (a solo re-run is a second line); its own HOME keeps the gate marker out of everyone else's way
  local d="$1"; shift; : > "$d.marks"; mkdir -p "$d.flaky" "$d.home"
  OUT="$( cd "$d" && HOME="$d.home" TMPDIR="$WORK/tmp" MARKLOG="$d.marks" FLAKY_DIR="$d.flaky" HEIMDALL_STATE_FILE="$d.state.json" \
          bash test/run-all.sh --min 1 "$@" 2>&1 )"; RC=$?
}
marks() { tr '\n' ' ' < "$1.marks" | sed 's/ $//'; }                  # the suites in the order they logged their start (two started together may swap)
ran() { sort -u "$1.marks" | tr '\n' ' ' | sed 's/ $//'; }            # the set of suites that started
starts() { grep -c "^$2\$" "$1.marks"; }                              # how often suite $2 started: a solo re-run is a second start
rj() { jq -r "$2" "$1" 2>/dev/null; }
LAST() { printf '%s/.heimdall/receipts/last-sweep.json' "$1"; }
FULLG() { printf '%s/.heimdall/receipts/last-full-green.json' "$1"; }
run_pos() { printf '%s\n' "$1" | grep -E '^progress \[[0-9]+s elapsed\] run ' | grep -n -E " $2\.test\.sh " | head -1 | cut -d: -f1; }   # where suite $2 finished among the run-phase progress lines
first_fail_s() { printf '%s\n' "$1" | sed -n -E 's/^progress \[([0-9]+)s elapsed\] run +[0-9]+\/[0-9]+ +FAIL .*/\1/p' | head -1; }
wall_s() { printf '%s\n' "$1" | sed -n 's/^wall clock: \([0-9]*\)s$/\1/p' | head -1; }
gate() { # dir -> GOUT, GRC: the push gate's verdict
  GOUT="$( cd "$1" && HOME="$1.home" HEIMDALL_STATE_FILE="$1.state.json" "$1/bin/heimdall-state" check-quality-gates 2>&1 )"; GRC=$?
}
armstate() { # dir -- the legacy flags the push gate also reads: init, then mark-clean under a visible lint waiver
  ( cd "$1" && HEIMDALL_STATE_FILE="$1.state.json" "$STATE_BIN" init >/dev/null 2>&1 \
    && HMD_LINT_WAIVER="$LINT_WAIVER" HEIMDALL_STATE_FILE="$1.state.json" "$STATE_BIN" mark-clean >/dev/null 2>&1 )
}
seed() { # dir repo non_green not_run durations -- the previous receipt a run orders by (only these four fields matter to it); repo "" = this fixture's own
  local d="$1" repo="${2:-}"
  [ -n "$repo" ] || repo="$(git -C "$d" rev-parse --show-toplevel)"
  mkdir -p "$d/.heimdall/receipts"
  jq -n --arg repo "$repo" --argjson red "$3" --argjson nr "$4" --argjson dur "$5" \
    '{repo:$repo, non_green_suites:$red, not_run_suites:$nr, suite_durations:$dur}' > "$d/.heimdall/receipts/last-sweep.json"
}
would() { printf '%s\n' "$1" | sed -n 's/^ *would run \(.*\)\.test\.sh$/\1/p' | tr '\n' ' ' | sed 's/ $//'; }   # the launch order a --dry-run printed

# the release side: a fake plugin repo with a bare origin, receipts in $dir.home, and stand-ins for everything ship.sh would reach out to
STUB="$WORK/stubbin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/gh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/gitleaks"; chmod +x "$STUB/gh" "$STUB/gitleaks"
NOOP="$WORK/noop"; printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"
mkplug() { # dir
  local d="$1"
  mkdir -p "$d/release" "$d/bin/lib" "$d/.claude-plugin" "$d.home/receipts"
  cp "$SHIP_SRC" "$d/release/ship.sh"; cp "$ROOT/release/sync-release.sh" "$d/release/sync-release.sh"; cp "$LIB_HOOK" "$d/bin/lib/hook-owned-path.sh"
  printf '{\n  "name": "heimdall",\n  "version": "9.9.9"\n}\n' > "$d/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\necho "- line"\n' > "$d/bin/generate-changelog"; chmod +x "$d/bin/generate-changelog" "$d/release/ship.sh"
  git init -q "$d"; git -C "$d" config user.email "rj@runheimdall.dev"; git -C "$d" config user.name RJ
  git -C "$d" add -A; git -C "$d" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm "initial fake plugin"; git -C "$d" branch -M main
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"; git -C "$d" push -q -u origin main
}
receipt() { # file kind exit_code head repo
  jq -n --arg k "$2" --argjson rc "$3" --arg h "$4" --arg r "$5" \
    '{finished_at:"2026-10-11T00:00:00Z", repo:$r, head_sha:$h, tree_clean:true, exit_code:$rc, kind:$k, suites_total:1, suites_passed:1}' > "$1"
}
ship() { # dir [args] -> SOUT, SHRC
  local d="$1"; shift
  SOUT="$( cd "$d" && HOME="$WORK/home" HEIMDALL_HOME="$d.home" GUARD_GITLEAKS_RC=0 SHIP_LANDMINE_LINT="$NOOP" SHIP_RENDERER="$NOOP" SHIP_SYNC_RELEASE="$NOOP" \
           PATH="$STUB:$PATH" bash "$d/release/ship.sh" "$@" 2>&1 )"; SHRC=$?
}

# ── scenarios: each builds its fixture and runs it, leaving OUT/RC/F (and its own facts) behind; hold_* is the one-line verdict section M re-asks of a broken copy ──
scn_a() { # name: one job, the third of five suites is red
  F="$WORK/$1"; mkfix "$F" s1 s2 s3 s4 s5; RED_SUITES=s3 runit "$F" --jobs 1 --fail-fast
}
hold_a() { [ "$RC" = 1 ] && [ "$(marks "$F")" = "s1 s2 s3" ] && [ "$(rj "$(LAST "$F")" '.kind')" = aborted ]; }
scn_d() { # name: two jobs, s3 is red the first time and green alone
  F="$WORK/$1"; mkfix "$F" s1 s2 s3 s4 s5; FLAKY_SUITES=s3 runit "$F" --jobs 2 --fail-fast
}
hold_d() { [ "$RC" = 0 ] && [ "$(ran "$F")" = "s1 s2 s3 s4 s5" ]; }
F_D1='{"o1.test.sh":5,"o2.test.sh":50,"o3.test.sh":20,"o4.test.sh":1,"o5.test.sh":0}'
F_FAST='{"o1.test.sh":1,"o2.test.sh":2,"o3.test.sh":0,"o4.test.sh":2,"o5.test.sh":1,"o6.test.sh":0}'
F_EDGE='{"o1.test.sh":0,"o2.test.sh":0,"o3.test.sh":0,"o4.test.sh":3,"o5.test.sh":0,"o6.test.sh":0}'
F_WANT="o5 o6 o2 o3 o1 o4 / o6 o2 o3 o1 o4 o5 / o1 o2 o3 o4 o5 o6 / o4 o1 o2 o3 o5 o6"
scn_f() { # name: the launch order a dry run prints for four previous receipts (o6 has no recorded duration in the first two)
  F="$WORK/$1"; mkfix "$F" o1 o2 o3 o4 o5 o6
  seed "$F" "" '["o5.test.sh"]' '[]' "$F_D1";                runit "$F" --jobs 1 --dry-run; F_ORDERS="$(would "$OUT")"; F_NOTE="$OUT"
  seed "$F" "" '["o3.test.sh"]' '["o3.test.sh"]' "$F_D1";    runit "$F" --jobs 1 --dry-run; F_ORDERS="$F_ORDERS / $(would "$OUT")"
  seed "$F" "" '[]' '[]' "$F_FAST";                          runit "$F" --jobs 1 --dry-run; F_ORDERS="$F_ORDERS / $(would "$OUT")"
  seed "$F" "" '[]' '[]' "$F_EDGE";                          runit "$F" --jobs 1 --dry-run; F_ORDERS="$F_ORDERS / $(would "$OUT")"
}
hold_f() { [ "${F_ORDERS:-}" = "$F_WANT" ]; }
scn_c() { # name: a receipt that knows four durations, then an aborted run that starts only the first suite
  F="$WORK/$1"; mkfix "$F" s1 s2 s3 s4
  seed "$F" "" '[]' '[]' '{"s1.test.sh":0,"s2.test.sh":0,"s3.test.sh":0,"s4.test.sh":0}'
  RED_SUITES=s1 runit "$F" --jobs 1 --fail-fast
}
hold_c() { [ "$(rj "$(LAST "$F")" '.suite_durations | length')" = 4 ]; }
scn_h() { # name: a green full sweep (the gate takes it), then an aborted one of the very same HEAD; H_CONTROL_RC and H_ANCHOR are what the first left
  F="$WORK/$1"; mkfix "$F" s1 s2 s3 s4; armstate "$F"
  runit "$F" --jobs 1; gate "$F"; H_CONTROL_RC="$GRC"; H_ANCHOR="$(cat "$(FULLG "$F")" 2>/dev/null)"
  RED_SUITES=s3 runit "$F" --jobs 1 --fail-fast
}
forge_gate() { # the aborted receipt with exit_code forged to 0, graded by the push gate -> GOUT, GRC
  local forged; forged="$(jq '.exit_code = 0' "$(LAST "$F")")"; printf '%s\n' "$forged" > "$(LAST "$F")"; gate "$F"
}
scn_hf() { scn_h "$1"; forge_gate; }
hold_h() { [ "$GRC" = 2 ] && case "$GOUT" in *ABORTED*) true ;; *) false ;; esac; }
scn_s() { # name: release/ship.sh handed a green-looking receipt of kind=aborted (the one way an aborted receipt could reach the full-green anchor: by hand)
  local p="$WORK/$1"; mkplug "$p"
  receipt "$p.home/receipts/last-full-green.json" aborted 0 "$(git -C "$p" rev-parse HEAD)" "$(git -C "$p" rev-parse --show-toplevel)"
  ship "$p" --no-npm; S_BUMPS="$(git -C "$p" log --oneline | grep -c 'chore(release)')"
}
hold_s() { [ "$SHRC" != 0 ] && [ "$S_BUMPS" = 0 ] && case "$SOUT" in *ABORTED*) true ;; *) false ;; esac; }

echo "════════════════════════════════════════════════════════════════"
echo "run-all --fail-fast: stop starting suites at a confirmed red; failed-first, slowest-first order"
echo "════════════════════════════════════════════════════════════════"

# ══ A ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- A. --fail-fast --jobs 1: the red already IS the suite's solo run, so nothing after it starts ----------------"
scn_a a1
eq "A1 the run is red (exit 1)" "$RC" "1"
eq "A2 s1 s2 s3 started; s4 and s5 never did" "$(marks "$F")" "s1 s2 s3"
eq "A3 the receipt is kind=aborted with exit_code 1" "$(rj "$(LAST "$F")" '[.kind, .exit_code] | join(",")')" "aborted,1"
eq "A4 it names who stopped the run, what it would have been, and how many suites never started" "$(rj "$(LAST "$F")" '.aborted | [.reason, .after_suite, .of_kind, .suites_not_run] | join(",")')" "fail-fast,s3.test.sh,full,2"
eq "A5 the suites that never started are listed, and are not non-green (nothing is known about them)" "$(rj "$(LAST "$F")" '[(.not_run_suites | join(",")), (.non_green_suites | join(","))] | join(" | ")')" "s4.test.sh,s5.test.sh | s3.test.sh"
eq "A6 the counts stay honest: 5 planned, 2 passed, 1 failed" "$(rj "$(LAST "$F")" '[.suites_total, .suites_passed, .suites_failed] | join(",")')" "5,2,1"
eq "A7 an aborted run never becomes the full-green anchor" "$([ -e "$(FULLG "$F")" ] && echo anchored || echo none)" "none"
has "A8 the run says how many suites never started" "$OUT" "2 suite(s) were never started"
has "A9 the table holds ONE NOTRUN row for them, not one per suite" "$OUT" "(2 suites never started)"
lacks "A10 the run is not green" "$OUT" "RUN GREEN"
holds "A11 (hold_a holds on the real run-all.sh)" hold_a

# ══ T ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- T. --jobs 2: a red is re-run ALONE before the run stops, and failed-first puts it first ------------------------"
F="$WORK/t"; mkfix "$F" a1 a2 a3 zred
SLOW_SUITES="a1 a2 a3" SLOW_SECS=1 RED_SUITES=zred runit "$F" --jobs 2
T1_OUT="$OUT"
eq "T1 without the flag every suite runs, the red included: exit 1, kind=full, no aborted block" "$RC:$(ran "$F" | wc -w | tr -d ' '):$(rj "$(LAST "$F")" '[.kind, has("aborted")] | join(",")')" "1:4:full,false"
eq "T2 the receipt records how long each suite took (the 1 s sleepers show at least 1)" "$(rj "$(LAST "$F")" '[.suite_durations["a1.test.sh"] >= 1, (.suite_durations | length)] | join(",")')" "true,4"
eq "T3 in glob order the red suite is not the first to finish" "$([ "$(run_pos "$T1_OUT" zred)" -gt 1 ] && echo later || echo first)" "later"
SLOW_SUITES="a1 a2 a3" SLOW_SECS=1 RED_SUITES=zred runit "$F" --jobs 2 --fail-fast
eq "T4 the previous run's red now starts first and is the first to finish" "$(run_pos "$OUT" zred)" "1"
eq "T5 only zred and a1 started, and zred TWICE: the parallel run and the solo re-run that confirmed it" "$(ran "$F"):$(starts "$F" zred)" "a1 zred:2"
has "T6 the solo re-run is printed as a retry" "$OUT" "retry 1/1 FAIL"
eq "T7 the run is red and aborted; a2 and a3 never started" "$RC:$(rj "$(LAST "$F")" '[.kind, .aborted.after_suite, (.not_run_suites | join(","))] | join(",")')" "1:aborted,zred.test.sh,a2.test.sh,a3.test.sh"
echo "     time to the first red on screen: $(first_fail_s "$T1_OUT")s in glob order -> $(first_fail_s "$OUT")s failed-first (whole run: $(wall_s "$T1_OUT")s -> $(wall_s "$OUT")s)"

# ══ D ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- D. a red that passes alone is FLAKY-UNDER-LOAD, not a stop: the run resumes and finishes green ---------------"
scn_d d1
eq "D1 exit 0: a red the solo re-run clears stops nothing" "$RC" "0"
eq "D2 all five suites ran, s3 twice (parallel red, solo green)" "$(ran "$F"):$(starts "$F" s3)" "s1 s2 s3 s4 s5:2"
eq "D3 the receipt is kind=full and green, names s3 in flaky_under_load, and has no aborted block" "$(rj "$(LAST "$F")" '[.kind, .exit_code, (.flaky_under_load | map(.suite) | join(",")), has("aborted")] | join(" ")')" "full 0 s3.test.sh false"
has "D4 the run says FLAKY-UNDER-LOAD" "$OUT" "FLAKY-UNDER-LOAD"
lacks "D5 and never says it stopped" "$OUT" "never started"
holds "D6 (hold_d holds on the real run-all.sh)" hold_d

# ══ F ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- F. order: failed last time first, then no duration yet, then slowest-first, then glob order ---------------------"
scn_f f1
eq "F1 red first (o5), the suite with no duration (o6), the slow ones longest-first (o2 o3 o1), the fast one (o4)" "$(printf '%s' "$F_ORDERS" | sed 's# / .*##')" "o5 o6 o2 o3 o1 o4"
has "F2 the run says how it ordered" "$F_NOTE" "order: 1 failed last time first, 1 with no duration yet, 3 slowest-first (3s or more), then 1 in glob order"
eq "F3 a suite that never started last time (not_run) is not 'failed': it sits among the slow ones by its duration" "$(printf '%s' "$F_ORDERS" | awk -F' / ' '{print $2}')" "o6 o2 o3 o1 o4 o5"
eq "F4 durations under 3 s are noise: every suite fast keeps glob order" "$(printf '%s' "$F_ORDERS" | awk -F' / ' '{print $3}')" "o1 o2 o3 o4 o5 o6"
eq "F5 exactly 3 s is slow (o4 first); the rest keep glob order" "$(printf '%s' "$F_ORDERS" | awk -F' / ' '{print $4}')" "o4 o1 o2 o3 o5 o6"
eq "F6 a dry run runs nothing" "$(marks "$F")" ""
seed "$F" "/somewhere/else" '["o5.test.sh"]' '[]' "$F_D1"; runit "$F" --jobs 1 --dry-run
eq "F7 a receipt of another repo is ignored: glob order" "$(would "$OUT")" "o1 o2 o3 o4 o5 o6"
seed "$F" "" '["o5.test.sh"]' '[]' "$F_D1"; runit "$F" --jobs 1
eq "F8 a real run starts the suites in that order (one job: the launch order is exact)" "$RC:$(marks "$F")" "0:o5 o6 o2 o3 o1 o4"
holds "F9 (hold_f holds on the real run-all.sh)" hold_f

# ══ C ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- C. the receipt keeps each suite's last duration through a run that did not start every suite ------------------"
scn_c c1
eq "C1 the aborted run started only s1, yet all four durations are in its receipt" "$(marks "$F"):$(rj "$(LAST "$F")" '[.kind, (.suite_durations | length)] | join(",")')" "s1:aborted,4"
holds "C2 (hold_c holds on the real run-all.sh)" hold_c

# ══ H ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- H. the push gate refuses an aborted receipt, by name -----------------------------------------------------------"
scn_h h1
eq "H1 control: the green full receipt of this HEAD passes the gate" "$H_CONTROL_RC" "0"
eq "H2 the aborted run left the full-green anchor byte-for-byte as it was" "$(cat "$(FULLG "$F")")" "$H_ANCHOR"
gate "$F"
eq "H3 the gate refuses the aborted receipt of this very HEAD (exit 2)" "$GRC" "2"
has "H4 and names the abort" "$GOUT" "ABORTED"
lacks "H5 it is not refused as a stale receipt, so the abort is the reason" "$GOUT" "STALE"
forge_gate
eq "H6 with exit_code forged to 0 the gate still refuses" "$GRC" "2"
has "H7 still naming the abort, not an unknown kind" "$GOUT" "ABORTED"
lacks "H8 and not as an unknown kind" "$GOUT" "unknown kind"
holds "H9 (hold_h holds on the real gate)" hold_h
git -C "$F" rm -q test/s4.test.sh && cm "$F" "drop s4"
runit "$F" --jobs 1
eq "H10 a suite deleted from test/ is dropped from the durations, the three left are kept" "$(rj "$(LAST "$F")" '[(.suite_durations | length), (.suite_durations | has("s4.test.sh"))] | join(",")')" "3,false"

# ══ S ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- S. release/ship.sh refuses an aborted receipt, by name ---------------------------------------------------------"
scn_s s1
eq "S1 ship refuses (non-zero) and bumps nothing" "$([ "$SHRC" != 0 ] && echo refused || echo shipped):$S_BUMPS" "refused:0"
has "S2 and says why: the receipt is from an aborted run" "$SOUT" "ABORTED"
holds "S3 (hold_s holds on the real ship.sh)" hold_s

# ══ I ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- I. the flag is documented, and a dry run with it executes nothing ------------------------------------------------"
F="$WORK/i1"; mkfix "$F" s1 s2 s3
HELP="$(bash "$F/test/run-all.sh" --help 2>&1)"
has "I1 --help documents --fail-fast" "$HELP" "--fail-fast"
runit "$F" --jobs 1 --fail-fast --dry-run
eq "I2 --fail-fast --dry-run starts nothing and writes no receipt" "$RC:$(marks "$F"):$([ -e "$(LAST "$F")" ] && echo receipt || echo none)" "0::none"

# ══ M ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- M. mutation proof: break one line of the real code at a time; the proof for it must go red -----------------------"
MUT="$WORK/mut"
mutant() { # name file sed-expr scenario predicate -- in the background: break one line of a COPY of the file, run the scenario on it, record killed (the predicate fails) or survived
  local name="$1" file="$2" expr="$3" scn="$4" hold="$5"
  (
    sed "$expr" "$file" > "$MUT/$name.src"
    if cmp -s "$file" "$MUT/$name.src"; then echo noapply > "$MUT/$name.res"; exit 0; fi
    case "$file" in "$RUN_ALL") RA_SRC="$MUT/$name.src" ;; "$STATE_BIN") STATE_SRC="$MUT/$name.src" ;; "$SHIP") SHIP_SRC="$MUT/$name.src" ;; esac
    "$scn" "m-$name" >/dev/null 2>&1
    if "$hold"; then echo survived > "$MUT/$name.res"; else echo killed > "$MUT/$name.res"; fi
  ) &
}
mutant trip         "$RUN_ALL"   's/^  LAUNCH_END=\$next; ABORT_FROM=\$next$/  :/'                                                          scn_a  hold_a
mutant confirm      "$RUN_ALL"   's/^    FAIL|TIMEOUT) if \[ "\$RETRY_REDS" -eq 1 \] && \[ "\$JOBS" -gt 1 \]; then/    FAIL|TIMEOUT) if false; then/' scn_d  hold_d
mutant kind         "$RUN_ALL"   's/--arg kind "\$RECEIPT_KIND"/--arg kind "\$SWEEP_KIND"/'                                                   scn_a  hold_a
mutant failed-first "$RUN_ALL"   's/if (name in red)/if (0)/'                                                                                 scn_f  hold_f
mutant not-run      "$RUN_ALL"   's/select(\. as \$s | \$nr | index(\$s) | not)/select(true)/'                                                scn_f  hold_f
mutant floor        "$RUN_ALL"   's/dur\[name\] >= min/dur[name] > min/'                                                                      scn_f  hold_f
mutant carry        "$RUN_ALL"   's/\$prev + /{} + /'                                                                                         scn_c  hold_c
mutant gate         "$STATE_BIN" 's/elif \[ "\$r_kind" = aborted \]; then/elif false; then/'                                                  scn_hf hold_h
mutant ship         "$SHIP"      's#!= "aborted"#!= "no-such-kind"#'                                                                          scn_s  hold_s
wait
KILLED=0; TOTAL=0
verdict() { # name what-breaking-it-breaks
  TOTAL=$((TOTAL + 1))
  case "$(cat "$MUT/$1.res" 2>/dev/null)" in
    killed)   KILLED=$((KILLED + 1)); ok "M[$1] killed: $2" ;;
    survived) bad "M[$1] SURVIVED: $2 -- and every proof above still passed" ;;
    noapply)  bad "M[$1] the mutation did not apply: the line it breaks is gone or reworded (update this mutant)" ;;
    *)        bad "M[$1] produced no result" ;;
  esac
}
verdict trip         "without the line that stops the launching, --fail-fast starts every suite"
verdict confirm      "a red stops the run before the solo re-run has confirmed it (a flaky red aborts)"
verdict kind         "the receipt of a stopped run says full instead of aborted"
verdict failed-first "a suite that failed last time is no longer first"
verdict not-run      "a suite that never started last time is treated as failed"
verdict floor        "a duration of exactly 3 s no longer counts as slow"
verdict carry        "a run that did not start every suite forgets their durations"
verdict gate         "the push gate no longer names an aborted receipt (a forged exit_code 0 slides to 'unknown kind')"
verdict ship         "release/ship.sh no longer names an aborted receipt"

echo
printf 'falsifiability: %d/%d\n' "$KILLED" "$TOTAL"
printf '  run-all-fail-fast: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

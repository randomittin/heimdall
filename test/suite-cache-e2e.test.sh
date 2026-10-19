#!/usr/bin/env bash
# test/suite-cache-e2e.test.sh -- THE SUITE CACHE, END TO END: A GREEN RESULT IS REUSED ONLY WHILE NOTHING IT COULD DEPEND ON HAS CHANGED.
#
# WHAT IT TESTS. test/run-all.sh consulting bin/lib/suite-cache.sh through bin/heimdall-suite-closure: per suite, a green result whose closure hash and salt are
# unchanged (and that is under 7 days old, and fits the budget it would run under now) is served from the cache instead of launched; a seeded sample of those
# hits is re-run anyway (the audit) and a sample suite that fails with an unchanged closure is CLOSURE UNSOUND: the run is red and the whole cache is purged.
# `--cold` ignores the cache, `--no-cache` never touches it, `--failed` runs the previous receipt's non-green suites plus every suite without a valid cache
# entry and composes the receipt from the rest. The receipt keeps kind=full and gains a `cache` block that bin/heimdall-suite-closure verify-receipt
# re-derives at the graded commit: bin/heimdall-state check-quality-gates and release/ship.sh refuse a receipt that does not verify, and ship.sh asks for a
# COLD receipt for an x.y.0 release.
#
# WHY IT EXISTS. A sweep is ~540 suites and 20-75 minutes, and every change staled the one whole-tree receipt, so an interrupted, cancelled or follow-up sweep
# threw away every suite it had finished (2.4.8: ~144 minutes of wall clock to confirm 116 s of fixes). A cache is only safe if "unchanged" really means
# unchanged, so it is graded by MUTATION: each way a cached green could go stale or be forged is made one at a time and the run MUST notice
# (`falsifiability: k/k`, red unless every mutant is killed).
#
# Proven here, against throwaway git repos holding the REAL run-all.sh, the REAL closure engine, cache library and gate, and 40 tiny fixture suites (each
# sources its own bin/dep-NN.sh; s40 reads data/payload.txt through a path assembled at run time, which no static scan can see). A sweep of 40 suites audits
# max(20, 10%) = 20 of its hits, so a warm run launches exactly: the misses plus that seeded sample -- the test recomputes the sample with the library itself:
#   A  a first run on an empty cache is cold by construction; --cold launches everything again even with valid entries
#   B  a warm run launches exactly the audit sample and serves the rest; its receipt verifies; the gate accepts it and refuses a forged copy; ship.sh refuses one too
#   C  a dependency broken -> only that suite (plus the sample) re-runs, goes RED, run exits 1, no entry is kept for it     D  reverted -> green again
#   E  a comment-only edit of run-all.sh keeps the cache; a real edit changes the salt and every suite re-runs
#   F  an entry 8 days old, an entry with a forged closure_sha, an entry whose recorded duration exceeds the budget: each MISSES, with its reason printed
#   H  an audited suite that fails with an unchanged closure -> CLOSURE UNSOUND, red, cache purged, and the receipt names it
#   J  --failed: greens of a RED run are kept; only the red suite re-runs; the amend verifies except for the audit sample it did not draw; a dependency broken
#      under a green suite re-runs it RED (the amend cannot hide a regression); a forged amend is refused
#   L  forged cache blocks of a REAL receipt are refused by verify-receipt, each with its reason
#   N  --dry-run writes nothing; an uncommitted change turns the cache off (a legacy sweep); --no-cache; incompatible flags are refused
#   S  release/ship.sh: a forged receipt, and a warm one for an x.y.0 release, are refused; a warm patch release and a cold x.y.0 release are accepted
# HERMETIC: every case runs in a throwaway repo under $TMPDIR with its own HOME; nothing touches the real receipts or the real work tree.
# EXIT: 0 = every proof holds and falsifiability is 1.0; 1 = anything else.
# shellcheck disable=SC2016  # the fixture suites are written LITERALLY: their $VARs must reach the file unexpanded
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RA_SRC="$ROOT/test/run-all.sh"
STATE_BIN="$ROOT/bin/heimdall-state"
SHIP="$ROOT/release/ship.sh"
LIB_HOOK="$ROOT/bin/lib/hook-owned-path.sh"
LIB_CHAIN="$ROOT/bin/lib/sweep-chain.sh"

PASS=0; FAIL=0; KILLED=0; MUTANTS=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in: $(printf '%s' "$2" | tail -c 900)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $(printf '%s' "$2" | tail -c 900)" ;; *) ok "$1" ;; esac; }
# mutant NAME yes|no [DETAIL] -- a way the cache could go wrong that the run MUST notice; counts toward falsifiability
mutant() { MUTANTS=$((MUTANTS+1)); if [ "$2" = yes ]; then KILLED=$((KILLED+1)); ok "mutant killed: $1"; else bad "mutant SURVIVED: $1" "${3:-}"; fi; }

for tool in git jq python3 perl; do command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool required" >&2; exit 2; }; done
for f in "$RA_SRC" "$STATE_BIN" "$SHIP" "$LIB_HOOK" "$LIB_CHAIN" "$ROOT/bin/heimdall-suite-closure" "$ROOT/bin/lib/suite_closure.py" "$ROOT/bin/lib/suite-cache.sh" \
         "$ROOT/release/sync-release.sh"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-sce.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
mkdir -p "$WORK/tmp" "$WORK/home"
cleanup() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
unset HEIMDALL_HOME HMD_COLD HMD_SUITE_CACHE_MAX_DAYS HMD_SUITE_CACHE_AUDIT_PCT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
# `mark-clean` only sets lint_clean against a passing lint receipt; these fixtures prove sweep receipts, not lint evidence, so they waive it visibly (as
# test/run-all-incremental.test.sh does)
LINT_WAIVER="fixture: suite-cache-e2e proves sweep receipts, not lint evidence"
ZEROS="0000000000000000000000000000000000000000000000000000000000000000"

# ── fixture ───────────────────────────────────────────────────────────────────────────────────────────────────────────
ALLN=""; i=1; while [ "$i" -le 40 ]; do ALLN="$ALLN s$(printf '%02d' "$i")"; i=$((i+1)); done
mksuite() { # dir NN -- suite sNN: logs its start to $MARKLOG, sources its own bin/dep-NN.sh and goes red when dep_ok fails
  printf '%s\n' '#!/usr/bin/env bash' "# fixture suite s$2 -- exercises: bin/dep-$2.sh" \
    'n="$(basename "$0" .test.sh)"' '[ -n "${MARKLOG:-}" ] && echo "$n" >> "$MARKLOG"' 'HERE="$(cd "$(dirname "$0")" && pwd)"' \
    ". \"\$HERE/../bin/dep-$2.sh\"" \
    'if dep_ok; then echo "$n: 1 passed, 0 failed"; else echo "  FAIL dependency broken in $n"; echo "$n: 0 passed, 1 failed"; exit 1; fi' > "$1/test/s$2.test.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'dep_ok() { return 0; }' > "$1/bin/dep-$2.sh"
}
mkunsound() { # dir -- s40: its input is a path built at run time, which the static closure cannot see
  printf '%s\n' '#!/usr/bin/env bash' '# fixture suite s40 -- reads its data through a path assembled at run time' \
    'n="$(basename "$0" .test.sh)"' '[ -n "${MARKLOG:-}" ] && echo "$n" >> "$MARKLOG"' 'HERE="$(cd "$(dirname "$0")" && pwd)"' \
    'p1=data; p2=payload.txt' 'v="$(cat "$HERE/../$p1/$p2")"' \
    'if [ "$v" = good ]; then echo "$n: 1 passed, 0 failed"; else echo "  FAIL payload is [$v]"; echo "$n: 0 passed, 1 failed"; exit 1; fi' > "$1/test/s40.test.sh"
}
STUB="$WORK/stubbin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/gh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/gitleaks"; chmod +x "$STUB/gh" "$STUB/gitleaks"
NOOP="$WORK/noop"; printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"
mkfix() { # dir -- a git repo (also a plugin repo with a bare origin) holding the REAL run-all.sh, closure engine, cache library and gate, and the 40 suites
  local d="$1" n
  mkdir -p "$d/test" "$d/bin/lib" "$d/release" "$d/.claude-plugin" "$d/data"
  git -C "$d" init -q; git -C "$d" config user.email rj@runheimdall.dev; git -C "$d" config user.name RJ
  printf '.heimdall/\n' > "$d/.gitignore"
  cp "$RA_SRC" "$d/test/run-all.sh"
  cp "$ROOT/bin/heimdall-suite-closure" "$d/bin/heimdall-suite-closure"; cp "$ROOT/bin/lib/suite_closure.py" "$ROOT/bin/lib/suite-cache.sh" "$d/bin/lib/"
  cp "$LIB_HOOK" "$d/bin/lib/hook-owned-path.sh"; cp "$LIB_CHAIN" "$d/bin/lib/sweep-chain.sh"; cp "$STATE_BIN" "$d/bin/heimdall-state"
  cp "$SHIP" "$d/release/ship.sh"; cp "$ROOT/release/sync-release.sh" "$d/release/sync-release.sh"
  printf '{\n  "name": "heimdall",\n  "version": "9.9.9"\n}\n' > "$d/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\necho "- line"\n' > "$d/bin/generate-changelog"; chmod +x "$d/bin/generate-changelog" "$d/release/ship.sh"
  printf 'good\n' > "$d/data/payload.txt"
  for n in $(seq 1 39); do mksuite "$d" "$(printf '%02d' "$n")"; done
  mkunsound "$d"
  git -C "$d" add -A; git -C "$d" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm fixture; git -C "$d" branch -M main
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"; git -C "$d" push -q -u origin main
}
newfix() { # name -> FIX (built and committed, gate state initialised, nothing swept yet)
  FIX="$WORK/$1"; mkfix "$FIX"
  ( cd "$FIX" && HEIMDALL_STATE_FILE="$FIX.state.json" "$FIX/bin/heimdall-state" init >/dev/null 2>&1 \
    && HMD_LINT_WAIVER="$LINT_WAIVER" HEIMDALL_STATE_FILE="$FIX.state.json" "$FIX/bin/heimdall-state" mark-clean >/dev/null 2>&1 )
}
cm() { git -C "$1" add -A && git -C "$1" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm "${2:-change}"; }
runit() { # dir [run-all args] -> OUT, RC. $dir.marks gets one line per suite START; EXTRA = extra VAR=val words for the sweep's environment
  local d="$1"; shift; : > "$d.marks"
  OUT="$( cd "$d" && env HOME="$WORK/home" TMPDIR="$WORK/tmp" MARKLOG="$d.marks" HEIMDALL_STATE_FILE="$d.state.json" ${EXTRA:-} \
          bash test/run-all.sh --min 1 --jobs 4 "$@" 2>&1 )"; RC=$?
}
ran() { sort -u "$1.marks" | tr '\n' ' ' | sed 's/ $//'; }
nran() { sort -u "$1.marks" | grep -c . || true; }
rj() { jq -r "$2" "$1" 2>/dev/null; }
LAST() { printf '%s/.heimdall/receipts/last-sweep.json' "$1"; }
FULLG() { printf '%s/.heimdall/receipts/last-full-green.json' "$1"; }
ENT() { printf '%s/.heimdall/receipts/suite-cache' "$1"; }
nent() { ls "$(ENT "$1")"/*.json 2>/dev/null | wc -l | tr -d ' '; }
sha() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | awk '{print $1}'; }
gate() { GOUT="$( cd "$1" && HOME="$WORK/home" HEIMDALL_STATE_FILE="$1.state.json" "$1/bin/heimdall-state" check-quality-gates 2>&1 )"; GRC=$?; }
vr() { # fixture receipt -> VR_RC, VR_ERR: the fixture's own copy of the engine, grading the receipt at ITS commit
  "$1/bin/heimdall-suite-closure" verify-receipt --repo "$1" --receipt "$2" >/dev/null 2>"$WORK/vr.err"; VR_RC=$?; VR_ERR="$(cat "$WORK/vr.err")"
}
ship() { # dir [args] -> SOUT, SHRC
  local d="$1"; shift
  SOUT="$( cd "$d" && HOME="$WORK/home" GUARD_GITLEAKS_RC=0 SHIP_LANDMINE_LINT="$NOOP" SHIP_RENDERER="$NOOP" SHIP_SYNC_RELEASE="$NOOP" \
           PATH="$STUB:$PATH" bash "$d/release/ship.sh" "$@" 2>&1 )"; SHRC=$?
}
bumps() { git -C "$1" log --oneline | grep -c 'chore(release)' || true; }
expected_ran() { # dir MISS... -> what a default sweep at the fixture's HEAD must launch: the misses, plus the audit sample drawn from every other suite
  local d="$1" s hits="" head salt; shift
  for s in $ALLN; do case " $* " in *" $s "*) ;; *) hits="$hits $s.test.sh" ;; esac; done
  head="$(git -C "$d" rev-parse HEAD)"; salt="$("$d/bin/heimdall-suite-closure" salt --repo "$d")"
  printf '%s\n' $hits > "$WORK/hits.lst"
  { printf '%s\n' "$@"; ( . "$d/bin/lib/suite-cache.sh"; suite_cache_audit_pick "$(suite_cache_audit_seed "$head" "$salt")" "$WORK/hits.lst" 2>/dev/null | sed 's/\.test\.sh$//' ); } \
    | grep . | sort -u | tr '\n' ' ' | sed 's/ $//'
}
entry_edit() { # dir suite JQ-FILTER -- edit one cache entry in place (the result still passes the entry schema)
  local f; f="$(ENT "$1")/$2.test.sh.json"; jq -c "$3" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
days_ago() { date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'; }
setdep() { printf '#!/usr/bin/env bash\ndep_ok() { return %s; }\n' "$3" > "$1/bin/dep-$2.sh"; }   # dir NN 0|1

echo "════════════════════════════════════════════════════════════════"
echo "suite cache, end to end: reuse, audit, cold, failed, receipts, gate, ship"
echo "════════════════════════════════════════════════════════════════"

# ══ A. cold by construction, and --cold ═══════════════════════════════════════════════════════════════════════════════
echo "-- A. an empty cache is a cold run; --cold re-runs everything even with valid entries ----------------"
newfix f; F="$FIX"
runit "$F"
eq "A1 first run on an empty cache is green" "$RC" "0"
eq "A2 all 40 suites ran" "$(nran "$F")" "40"
eq "A3 40 entries were written" "$(nent "$F")" "40"
eq "A4 receipt: kind full, 40 fresh, 0 cached, 0 audited" "$(rj "$(LAST "$F")" '[.kind, .cache.suites_fresh, .cache.suites_cached, .cache.audited]|join(",")')" "full,40,0,0"
eq "A5 nothing came from the cache, so the receipt says cold" "$(rj "$(LAST "$F")" '.cache.cold')" "true"
eq "A6 full_equivalent, and the totals count every suite" "$(rj "$(LAST "$F")" '[.full_equivalent, .suites_total, .suites_passed]|join(",")')" "true,40,40"
has "A7 the run prints the cache summary" "$OUT" "cache: 40 fresh, 0 cached (audited 0)"
vr "$F" "$(LAST "$F")"; eq "A8 verify-receipt accepts the cold receipt" "$VR_RC" "0"; [ "$VR_RC" = 0 ] || printf '        %s\n' "$VR_ERR" >&2
eq "A9 the green full sweep is the chain anchor" "$(rj "$(FULLG "$F")" '.head_sha')" "$(git -C "$F" rev-parse HEAD)"
runit "$F" --cold
eq "A10 --cold launches all 40 although every entry is valid" "$(nran "$F")" "40"
eq "A11 --cold: cold receipt, nothing cached" "$(rj "$(LAST "$F")" '[.cache.cold, .cache.suites_cached, .cache.audited]|join(",")')" "true,0,0"
has "A12 the banner says so" "$OUT" "cache: cold"

# ══ B. a warm run ═════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- B. a warm run launches exactly the audit sample and serves the rest ----------------------------"
runit "$F"
eq "B1 green" "$RC" "0"
eq "B2 exactly the audit sample ran (recomputed here with the library)" "$(ran "$F")" "$(expected_ran "$F")"
eq "B3 receipt: 20 fresh (all audited), 20 cached, not cold" "$(rj "$(LAST "$F")" '[.cache.suites_fresh, .cache.suites_cached, .cache.audited, .cache.cold]|join(",")')" "20,20,20,false"
eq "B4 the receipt still counts the whole sweep" "$(rj "$(LAST "$F")" '[.kind, .full_equivalent, .suites_total, .suites_passed, .exit_code]|join(",")')" "full,true,40,40,0"
eq "B5 the receipt lists a green entry per suite" "$(rj "$(LAST "$F")" '.cache.entries|length')" "40"
has "B6 the run prints the cache summary" "$OUT" "cache: 20 fresh, 20 cached (audited 20)"
has "B7 CACHED rows are in the table" "$OUT" "CACHED"
vr "$F" "$(LAST "$F")"; eq "B8 verify-receipt accepts the cache-composed receipt" "$VR_RC" "0"; [ "$VR_RC" = 0 ] || printf '        %s\n' "$VR_ERR" >&2
cp "$(LAST "$F")" "$WORK/golden.json"
gate "$F"; eq "B9 the push gate accepts it" "$GRC" "0"; has "B10 and says so" "$GOUT" "All quality gates pass"
jq '.cache.entries[3].closure_sha = "'"$ZEROS"'"' "$WORK/golden.json" > "$(LAST "$F")"; gate "$F"
if [ "$GRC" = 2 ] && printf '%s' "$GOUT" | grep -qi 'closure'; then mutant "the push gate refuses a receipt whose entry closure_sha was forged" yes; else mutant "the push gate refuses a forged closure_sha" no "rc=$GRC $GOUT"; fi
cp "$WORK/golden.json" "$(LAST "$F")"; gate "$F"; eq "B11 the gate accepts the restored receipt again" "$GRC" "0"
jq --arg z "$ZEROS" '.cache.entries[3].closure_sha = $z' "$WORK/golden.json" > "$(FULLG "$F")"; ship "$F" --no-npm
if [ "$SHRC" != 0 ] && printf '%s' "$SOUT" | grep -qi 'verify' && [ "$(bumps "$F")" = 0 ]; then mutant "release/ship.sh refuses a receipt whose entry closure_sha was forged, before bumping anything" yes
else mutant "release/ship.sh refuses a forged closure_sha" no "rc=$SHRC bumps=$(bumps "$F") $(printf '%s' "$SOUT" | tail -c 600)"; fi
cp "$WORK/golden.json" "$(FULLG "$F")"

# ══ C. a dependency broken ════════════════════════════════════════════════════════════════════════════════════════════
echo "-- C. a broken dependency: that suite re-runs, goes RED, nothing is cached for it ---------------------"
setdep "$F" 02 1; cm "$F" "break dep 02"
runit "$F"
eq "C1 the run launched exactly s02 plus the audit sample" "$(ran "$F")" "$(expected_ran "$F" s02)"
eq "C2 the run is red" "$RC" "1"
has "C3 the red suite is named" "$OUT" "dependency broken in s02"
eq "C4 the receipt names s02 as the only non-green suite" "$(rj "$(LAST "$F")" '.non_green_suites|join(",")')" "s02.test.sh"
eq "C5 no entry is kept for the red suite" "$([ -e "$(ENT "$F")/s02.test.sh.json" ] && echo kept || echo none)" "none"
eq "C6 the other 39 greens are still there" "$(nent "$F")" "39"
eq "C7 the receipt is red and not full-equivalent" "$(rj "$(LAST "$F")" '[.exit_code, .full_equivalent]|join(",")')" "1,false"
if [ "$RC" = 1 ] && [ "$([ -e "$(ENT "$F")/s02.test.sh.json" ] && echo kept || echo none)" = none ] && ran "$F" | grep -qw s02; then mutant "a broken dependency re-runs the suite and it goes RED" yes
else mutant "a broken dependency re-runs the suite and it goes RED" no "rc=$RC ran=$(ran "$F")"; fi
gate "$F"; eq "C8 the push gate refuses the red receipt" "$GRC" "2"

# ══ D. reverted ═══════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- D. the dependency is fixed: s02 runs again, and goes green ------------------------------------"
setdep "$F" 02 0; cm "$F" "fix dep 02"
runit "$F"
eq "D1 s02 (no entry) plus the audit sample ran; the greens of the red run were reused" "$(ran "$F")" "$(expected_ran "$F" s02)"
eq "D2 green, and s02 has an entry again" "$RC:$([ -e "$(ENT "$F")/s02.test.sh.json" ] && echo entry || echo none)" "0:entry"
vr "$F" "$(LAST "$F")"; eq "D3 the receipt verifies" "$VR_RC" "0"

# ══ E. the salt ═══════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- E. a comment-only edit of run-all.sh keeps the cache; a real edit invalidates all of it ----------"
printf '# a note about nothing: comments of the runner are not the runner\n' >> "$F/test/run-all.sh"; cm "$F" "comment-only edit of run-all.sh"
runit "$F"
eq "E1 the cache survived: only the audit sample ran" "$(ran "$F")" "$(expected_ran "$F")"
eq "E2 and the receipt says 20 served from the cache" "$(rj "$(LAST "$F")" '.cache.suites_cached')" "20"
perl -pi -e 's/^TIMEOUT=180$/TIMEOUT=181/' "$F/test/run-all.sh"; grep -q '^TIMEOUT=181$' "$F/test/run-all.sh" || bad "E3 fixture edit did not land"; cm "$F" "real edit of run-all.sh"
runit "$F"
eq "E4 the salt changed: all 40 suites ran" "$(nran "$F")" "40"
eq "E5 nothing was served from the cache" "$(rj "$(LAST "$F")" '[.cache.suites_cached, .cache.audited]|join(",")')" "0,0"
has "E6 the reason is the salt" "$OUT" "salt changed"
if [ "$(nran "$F")" = 40 ]; then mutant "a runner edit changes the salt and every cached result is re-run" yes; else mutant "a runner edit changes the salt" no "ran $(nran "$F")"; fi

# ══ F. stale, forged and over-budget entries ══════════════════════════════════════════════════════════════════════════
echo "-- F. an 8-day-old entry, a forged closure_sha and an over-budget duration each MISS --------------"
entry_edit "$F" s05 ".finished_at = \"$(days_ago 8)\""
entry_edit "$F" s07 ".closure_sha = \"$ZEROS\""
entry_edit "$F" s09 ".duration_s = 9999"
runit "$F"
eq "F1 s05, s07, s09 plus the audit sample of the others ran" "$(ran "$F")" "$(expected_ran "$F" s05 s07 s09)"
eq "F2 green" "$RC" "0"
has "F3 s05: the entry is 8 days old" "$OUT" "s05.test.sh: entry is 8 day(s) old"
has "F4 s07: the closure_sha does not match" "$OUT" "s07.test.sh: closure changed"
has "F5 s09: the recorded duration is over the budget" "$OUT" "s09.test.sh: recorded 9999s is over the budget of 181s"
for pair in "s05:an entry 8 days old" "s07:an entry with a forged closure_sha" "s09:an entry recorded over the budget it would run under now"; do
  if ran "$F" | grep -qw "${pair%%:*}"; then mutant "${pair#*:} is not served from the cache" yes; else mutant "${pair#*:} is not served from the cache" no "ran=$(ran "$F")"; fi
done

# ══ H. an unsound closure ═════════════════════════════════════════════════════════════════════════════════════════════
echo "-- H. a suite whose dependency the closure cannot see: the audit finds it, the cache is purged -----"
eq "H0 premise: the closure of s40 does not hold the file it reads" "$("$F/bin/heimdall-suite-closure" deps --suite test/s40.test.sh --repo "$F" | tr '\n' ' ' | sed 's/ $//')" "test/s40.test.sh"
printf 'bad\n' > "$F/data/payload.txt"; cm "$F" "break the payload s40 reads through a computed path"
EXTRA="HMD_SUITE_CACHE_AUDIT_PCT=100" runit "$F"
eq "H1 the audit was raised to 100%: all 40 suites ran" "$(nran "$F")" "40"
eq "H2 the run is red" "$RC" "1"
has "H3 CLOSURE UNSOUND names the suite" "$OUT" "CLOSURE UNSOUND"
has "H4 s40 is the one" "$OUT" "s40.test.sh"
eq "H5 the cache was purged" "$(nent "$F")" "0"
eq "H6 the receipt names it" "$(rj "$(LAST "$F")" '.cache.unsound|join(",")')" "s40.test.sh"
eq "H7 and is red, not full-equivalent" "$(rj "$(LAST "$F")" '[.exit_code, .full_equivalent]|join(",")')" "1,false"
if [ "$RC" = 1 ] && [ "$(nent "$F")" = 0 ] && printf '%s' "$OUT" | grep -q 'CLOSURE UNSOUND'; then mutant "an audited suite failing with an unchanged closure is CLOSURE UNSOUND: red, cache purged" yes
else mutant "an audited suite failing with an unchanged closure is CLOSURE UNSOUND" no "rc=$RC entries=$(nent "$F")"; fi
printf 'good\n' > "$F/data/payload.txt"; cm "$F" "restore the payload"
runit "$F"
eq "H8 after a purge the next run is cold: all 40 ran, green" "$(nran "$F"):$RC" "40:0"
eq "H9 and its receipt says cold" "$(rj "$(LAST "$F")" '.cache.cold')" "true"

# ══ L. forged cache blocks of a REAL receipt ═════════════════════════════════════════════════════════════════════════
echo "-- L. verify-receipt refuses each forged field of a receipt run-all.sh wrote ----------------------"
vr "$F" "$WORK/golden.json"; eq "L0 the golden receipt of section B still verifies at ITS commit" "$VR_RC" "0"
lmut() { # LABEL JQ-FILTER REASON
  jq "$2" "$WORK/golden.json" > "$WORK/forged.json"; vr "$F" "$WORK/forged.json"
  if [ "$VR_RC" = 1 ] && printf '%s' "$VR_ERR" | grep -qiF -- "$3"; then mutant "verify-receipt: $1" yes; else mutant "verify-receipt: $1" no "rc=$VR_RC want [$3] got [$VR_ERR]"; fi
}
lmut "an entry's closure_sha forged" ".cache.entries[5].closure_sha = \"$ZEROS\"" "closure"
lmut "the salt forged" ".cache.salt = \"$ZEROS\"" "salt"
lmut "audited lowered under max(20, 10%) of the hits" ".cache.audited = 3" "audited"
lmut "a suite's entry removed" ".cache.entries |= .[1:]" "no green entry"
lmut "cold claimed although suites were served from the cache" ".cache.cold = true" "cold"
lmut "the receipt says it is not full-equivalent" ".full_equivalent = false" "full_equivalent"
lmut "exit_code forged" ".exit_code = 1" "exit_code"
lmut "the cache block removed from a cache-composed receipt" "del(.cache)" "cache"

# ══ N. dry run, dirty tree, --no-cache, flags ═════════════════════════════════════════════════════════════════════════
echo "-- N. --dry-run writes nothing; a dirty tree and --no-cache run as before; bad flag mixes are refused --"
runit "$F"; SUM0="$(sha "$(LAST "$F")")"; ENT0="$(sha "$(ENT "$F")/s01.test.sh.json")"
runit "$F" --dry-run
eq "N1 --dry-run exits 0 and launches nothing" "$RC:$(nran "$F")" "0:0"
has "N2 and prints the cache plan" "$OUT" "cache:"
eq "N3 and writes no receipt" "$(sha "$(LAST "$F")")" "$SUM0"
printf '# local edit\n' >> "$F/bin/dep-01.sh"
runit "$F"
eq "N4 an uncommitted change: the cache is off and all 40 ran" "$(nran "$F")" "40"
has "N5 and the run says why" "$OUT" "cache: off"
has "N6 naming the uncommitted change" "$OUT" "uncommitted"
eq "N7 the receipt is a legacy one: no cache block" "$(rj "$(LAST "$F")" 'has("cache")')" "false"
eq "N8 and no entry was touched" "$(sha "$(ENT "$F")/s01.test.sh.json")" "$ENT0"
git -C "$F" checkout -q -- bin/dep-01.sh
runit "$F" --no-cache
eq "N9 --no-cache: all 40 ran, no cache block, entries untouched" "$(nran "$F"):$(rj "$(LAST "$F")" 'has("cache")'):$(sha "$(ENT "$F")/s01.test.sh.json")" "40:false:$ENT0"
runit "$F" --failed --cold;          eq "N10 --failed with --cold is refused (exit 2)" "$RC" "2"
runit "$F" --failed --filter s01;    eq "N11 --failed with --filter is refused (exit 2)" "$RC" "2"
runit "$F" --cold --no-cache;        eq "N12 --cold with --no-cache is refused (exit 2)" "$RC" "2"
runit "$F" --failed --since-green;   eq "N13 --failed with --since-green is refused (exit 2)" "$RC" "2"

# ══ J. --failed ═══════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- J. --failed: the red suite re-runs alone, the amend verifies except for the audit it did not draw --"
newfix k; K="$FIX"
setdep "$K" 03 1; cm "$K" "s03 is red"
runit "$K" --cold
eq "J1 the cold run is red (s03)" "$RC" "1"
eq "J2 the 39 greens of a RED run were stored" "$(nent "$K")" "39"
eq "J3 only s03 is non-green" "$(rj "$(LAST "$K")" '.non_green_suites|join(",")')" "s03.test.sh"
setdep "$K" 03 0; cm "$K" "fix s03"
PREV="$(sha "$(LAST "$K")")"
runit "$K" --failed
eq "J4 --failed launched ONLY s03" "$(ran "$K")" "s03"
eq "J5 and is green" "$RC" "0"
eq "J6 the receipt names what the amend re-ran" "$(rj "$(LAST "$K")" '.amended|join(",")')" "s03.test.sh"
eq "J7 and the receipt it amended (its sha256)" "$(rj "$(LAST "$K")" '.amended_from')" "$PREV"
eq "J8 composed: full_equivalent, 39 cached, no audit drawn, not cold" "$(rj "$(LAST "$K")" '[.full_equivalent, .cache.suites_cached, .cache.audited, .cache.cold]|join(",")')" "true,39,0,false"
has "J9 the run says failed-first" "$OUT" "failed-first"
cp "$(LAST "$K")" "$WORK/amend.json"
vr "$K" "$(LAST "$K")"
if [ "$VR_RC" = 1 ] && printf '%s' "$VR_ERR" | grep -qi 'audited' && ! printf '%s' "$VR_ERR" | grep -qiE 'closure|salt|no green entry'; then ok "J10 the amend is refused for the audit sample only: every closure, the salt and every entry check out"
else bad "J10 the amend is refused for the audit sample only" "rc=$VR_RC $VR_ERR"; fi
gate "$K"; eq "J11 the push gate does not take the unaudited amend" "$GRC" "2"; has "J12 and names the audit" "$GOUT" "audited"
runit "$K"
eq "J13 one default run (the audit sample, nothing else) makes it gate-grade" "$(ran "$K"):$RC" "$(expected_ran "$K"):0"
vr "$K" "$(LAST "$K")"; eq "J14 that receipt verifies" "$VR_RC" "0"
gate "$K"; eq "J15 and the gate accepts it" "$GRC" "0"
setdep "$K" 04 1; cm "$K" "break the dependency of a GREEN suite (s04)"
runit "$K" --failed
eq "J16 --failed re-ran s04, whose closure moved, and nothing else" "$(ran "$K")" "s04"
eq "J17 and it went RED: the amend hides nothing" "$RC:$(rj "$(LAST "$K")" '[.exit_code, .full_equivalent, (.non_green_suites|join(","))]|join(",")')" "1:1,false,s04.test.sh"
if [ "$RC" = 1 ] && [ "$(ran "$K")" = s04 ]; then mutant "--failed re-runs a green suite whose dependency broke and the run is red" yes; else mutant "--failed re-runs a green suite whose dependency broke" no "rc=$RC ran=$(ran "$K")"; fi
HEAD2="$(git -C "$K" rev-parse HEAD)"
jq --arg h "$HEAD2" '.head_sha = $h | .amended = []' "$WORK/amend.json" > "$WORK/forged-amend.json"; vr "$K" "$WORK/forged-amend.json"
if [ "$VR_RC" = 1 ] && printf '%s' "$VR_ERR" | grep -qi 'closure'; then mutant "a forged amend (amended:[] on a commit where a closure moved) is refused" yes; else mutant "a forged amend is refused" no "rc=$VR_RC $VR_ERR"; fi

# ══ S. release/ship.sh ════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- S. release/ship.sh: forged and warm-for-x.y.0 receipts are refused; warm patch and cold x.y.0 pass --"
newfix s; S="$FIX"
runit "$S"; runit "$S"
eq "S0 the anchor is a warm receipt (not cold)" "$(rj "$(FULLG "$S")" '.cache.cold')" "false"
ship "$S" --minor --no-npm
if [ "$SHRC" != 0 ] && printf '%s' "$SOUT" | grep -q 'COLD' && [ "$(bumps "$S")" = 0 ]; then mutant "ship.sh refuses a warm receipt for an x.y.0 release (COLD required), bumping nothing" yes
else mutant "ship.sh refuses a warm receipt for an x.y.0 release" no "rc=$SHRC bumps=$(bumps "$S") $(printf '%s' "$SOUT" | tail -c 500)"; fi
ship "$S" --no-npm
has "S1 a warm receipt is fine for a patch release" "$SOUT" "green FULL sweep receipt"
lacks "S2 and is not refused" "$SOUT" "does not verify"
has "S3 ship carries on to the version bump" "$SOUT" "Version bump"
newfix t; T="$FIX"
runit "$T"
eq "S4 the anchor is cold by construction" "$(rj "$(FULLG "$T")" '.cache.cold')" "true"
ship "$T" --minor --no-npm
has "S5 a cold receipt covers an x.y.0 release" "$SOUT" "green FULL sweep receipt"
lacks "S6 and is not refused" "$SOUT" "COLD"
has "S7 ship carries on to the version bump" "$SOUT" "Version bump"

# ── falsifiability ───────────────────────────────────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
echo "falsifiability: ${KILLED}/${MUTANTS}"
echo "${PASS} passed, ${FAIL} failed"
if [ "$KILLED" -ne "$MUTANTS" ] || [ "$MUTANTS" -eq 0 ]; then echo "FAIL: falsifiability score is not 1.0" >&2; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0

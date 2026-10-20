#!/usr/bin/env bash
# test/run-all-head-moved.test.sh -- A SWEEP THAT SAW HEAD MOVE NAMES THE COMMIT IT STARTED ON, AND IS NEITHER ANCHORED NOR ARCHIVED.
#
# WHY THIS EXISTS. test/run-all.sh read HEAD when it WROTE the receipt, at the end of a sweep that runs minutes to an hour. A commit that landed in between (a person, an agent, a hook)
# made it write a green kind=full receipt naming a commit no suite had been run against, and a green, clean full receipt becomes receipts/last-full-green.json (the chain anchor) and
# receipts/full-green/<head_sha>.json (what release/ship.sh --npm-only reads once the anchor has moved on): a release graded by a sweep that never saw its tree.
# The fix: the sweep reads HEAD and the state of the tree ONCE, before anything runs. The receipt names that commit. When HEAD is somewhere else at the end the receipt records where
# (head_moved_to), the run prints ONE line saying so, and nothing is anchored or archived. A tree that was dirty when the sweep started is never tree_clean, whatever it looks like at the end.
#
# Proven here against throwaway git repos holding the REAL test/run-all.sh (and, for the suite-cache modes, the REAL closure engine and cache library) and three fixture suites,
# one of which COMMITS while the sweep is running:
#   D  a default sweep (suite cache on)   C  --cold   N  --no-cache (the legacy receipt, no cache block)   F  --failed (the amend of a red run)
#      each mode runs two sweeps: A sees no commit (the control: it anchors and archives, and says nothing about HEAD); B has a suite commit mid-run (it names the commit it STARTED on, records
#      head_moved_to, prints one line, and leaves the anchor and the archive byte for byte as A left them)
#   T  a sweep that started on a dirty tree (an untracked file a suite removes mid-run) is not tree_clean and is not anchored
#   M  mutation proof: break one line of the real code at a time, each proof above must go red
# Cost: about 10 s -- every scenario runs side by side, each in a repo of its own.
# EXIT: 0 = every proof holds and every mutant is killed; 1 = any FAIL.
# shellcheck disable=SC2016  # the fixture suites are written LITERALLY: their $VARs must reach the file unexpanded
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUN_ALL="$ROOT/test/run-all.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in: $(printf '%s' "$2" | tail -c 700)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $(printf '%s' "$2" | tail -c 700)" ;; *) ok "$1" ;; esac; }

for tool in git jq python3 perl; do command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool required" >&2; exit 2; }; done
for f in "$RUN_ALL" "$ROOT/bin/lib/hook-owned-path.sh" "$ROOT/bin/lib/sweep-chain.sh" "$ROOT/bin/heimdall-suite-closure" "$ROOT/bin/lib/suite_closure.py" "$ROOT/bin/lib/suite-cache.sh"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-head-moved.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
RES="$WORK/res"; mkdir -p "$RES"
cleanup() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
unset HEIMDALL_HOME HMD_COLD HMD_SUITE_CACHE_MAX_DAYS HMD_SUITE_CACHE_AUDIT_PCT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────────────────────────────
mksuite() { # dir name -- RED_SUITES: always red. COMMIT_SUITE: commits a new file into the fixture repo while the sweep runs. RM_SUITE: removes scratch.txt while the sweep runs
  printf '%s\n' '#!/usr/bin/env bash' \
    'n="$(basename "$0" .test.sh)"; top="$(cd "$(dirname "$0")/.." && pwd)"' \
    'case " ${RED_SUITES:-} " in *" $n "*) echo "  FAIL assertion in $n"; echo "$n: 0 passed, 1 failed"; exit 1 ;; esac' \
    'if [ "${COMMIT_SUITE:-}" = "$n" ]; then' \
    '  f="late-$RANDOM$RANDOM.txt"; echo "landed while the sweep was running" > "$top/$f"' \
    '  git -C "$top" add "$f" && git -C "$top" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm "a commit made while the sweep runs" || { echo "  FAIL the fixture suite could not commit"; echo "$n: 0 passed, 1 failed"; exit 1; }' \
    'fi' \
    '[ "${RM_SUITE:-}" = "$n" ] && rm -f "$top/scratch.txt"' \
    'echo "$n: 1 passed, 0 failed"' > "$1/test/$2.test.sh"
}
mkfix() { # dir run-all-copy-to-grade -- a git repo holding that run-all.sh, the real closure engine and cache library, and the three fixture suites
  local d="$1" ra="$2" s
  mkdir -p "$d/test" "$d/bin/lib" "$d.home" "$d.tmp"
  git -C "$d" init -q; git -C "$d" config user.email t@example.com; git -C "$d" config user.name T
  printf '.heimdall/\n' > "$d/.gitignore"
  cp "$ra" "$d/test/run-all.sh"
  cp "$ROOT/bin/lib/hook-owned-path.sh" "$ROOT/bin/lib/sweep-chain.sh" "$ROOT/bin/lib/suite_closure.py" "$ROOT/bin/lib/suite-cache.sh" "$d/bin/lib/"
  cp "$ROOT/bin/heimdall-suite-closure" "$d/bin/heimdall-suite-closure"
  for s in s1 s2 s3; do mksuite "$d" "$s"; done
  git -C "$d" add -A; git -C "$d" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm fixture
}
runit() { # dir [run-all args] -> OUT, RC. The caller's RED_SUITES / COMMIT_SUITE / RM_SUITE travel with the call; its own HOME keeps the gate marker out of everyone else's way
  local d="$1"; shift
  OUT="$( cd "$d" && env HOME="$d.home" TMPDIR="$d.tmp" HMD_NO_CAFFEINATE=1 bash test/run-all.sh --min 1 --jobs 1 "$@" 2>&1 )"; RC=$?
}
LASTJ() { printf '%s/.heimdall/receipts/last-sweep.json' "$1"; }
ANCHOR() { printf '%s/.heimdall/receipts/last-full-green.json' "$1"; }
ARCH() { printf '%s/.heimdall/receipts/full-green' "$1"; }
keep() { # dir out-prefix -- what one sweep left behind: the assertions run after every background scenario is done
  local d="$1" p="$2"
  printf '%s' "$OUT" > "$p.out"; printf '%s' "$RC" > "$p.rc"
  git -C "$d" rev-parse HEAD > "$p.end"
  cp "$(LASTJ "$d")" "$p.last" 2>/dev/null; cp "$(ANCHOR "$d")" "$p.anchor" 2>/dev/null
  find "$(ARCH "$d")" -type f 2>/dev/null | sed 's#.*/##' | sort > "$p.arch"; cat "$(ARCH "$d")"/*.json > "$p.archbytes" 2>/dev/null
  return 0
}

# ── scenarios: each leaves its facts in $RES/<name>/, so they can all run at once ───────────────────────────────────────
chain() { # name mode run-all-copy -- sweep A (no commit: the control), then sweep B (the suite s2 commits while it runs); mode: default | cold | nocache | failed
  local mode="$2" ra="${3:-$RUN_ALL}" d="$WORK/$1" r="$RES/$1" args=""
  mkdir -p "$r"; mkfix "$d" "$ra"
  case "$mode" in cold) args="--cold" ;; nocache) args="--no-cache" ;; failed) args="--failed" ;; esac
  if [ "$mode" = failed ]; then RED_SUITES=s2 runit "$d"; fi        # the red run that --failed amends: its greens are in the cache, s2 is the one it names
  runit "$d" $args; keep "$d" "$r/a"
  git -C "$d" rev-parse HEAD > "$r/b.start"
  COMMIT_SUITE=s2 runit "$d" $args; keep "$d" "$r/b"
}
dirty_start() { # name run-all-copy -- the sweep starts with an untracked file in the tree; the suite s2 removes it, so at the end the tree looks clean
  local ra="${2:-$RUN_ALL}" d="$WORK/$1" r="$RES/$1"
  mkdir -p "$r"; mkfix "$d" "$ra"
  printf 'not committed\n' > "$d/scratch.txt"
  RM_SUITE=s2 runit "$d"; keep "$d" "$r/t"
  [ -e "$d/scratch.txt" ] || : > "$r/t.gone"
}
check() { # name label -- the proofs for one chain
  local r="$RES/$1" l="$2" a_end b_start b_end
  a_end="$(cat "$r/a.end" 2>/dev/null)"; b_start="$(cat "$r/b.start" 2>/dev/null)"; b_end="$(cat "$r/b.end" 2>/dev/null)"
  eq "$l-A1 control: the sweep that saw no commit is green" "$(cat "$r/a.rc" 2>/dev/null)" "0"
  eq "$l-A2 it names its commit and is the anchor" "$(jq -r '.head_sha' "$r/a.anchor" 2>/dev/null)" "$a_end"
  eq "$l-A3 it is archived under that commit" "$(cat "$r/a.arch" 2>/dev/null)" "$a_end.json"
  lacks "$l-A4 and it says nothing about HEAD moving" "$(cat "$r/a.out" 2>/dev/null)" "HEAD moved"
  eq "$l-B0 premise: the commit really landed while sweep B ran" "$([ -n "$b_start" ] && [ "$b_start" != "$b_end" ] && echo moved || echo same)" "moved"
  eq "$l-B1 sweep B is still green: HEAD moving does not change what the suites said" "$(cat "$r/b.rc" 2>/dev/null)" "0"
  eq "$l-B2 its receipt names the commit it STARTED on, not the one HEAD is at now" "$(jq -r '.head_sha' "$r/b.last" 2>/dev/null)" "$b_start"
  eq "$l-B3 and records where HEAD was when it ended" "$(jq -r '.head_moved_to // "none"' "$r/b.last" 2>/dev/null)" "$b_end"
  eq "$l-B4 the anchor is byte for byte what sweep A left" "$(cmp -s "$r/a.anchor" "$r/b.anchor" && echo same || echo changed)" "same"
  eq "$l-B5 the archive is byte for byte what sweep A left, with no file added" "$(cat "$r/b.arch" 2>/dev/null):$(cmp -s "$r/a.archbytes" "$r/b.archbytes" && echo same || echo changed)" "$a_end.json:same"
  has "$l-B6 the run says HEAD moved during the sweep" "$(cat "$r/b.out" 2>/dev/null)" "HEAD moved during the sweep (${b_start:0:12} -> ${b_end:0:12})"
  has "$l-B7 and that the receipt is not release-grade" "$(cat "$r/b.out" 2>/dev/null)" "not release-grade"
  eq "$l-B8 in ONE line" "$(grep -c 'HEAD moved during the sweep' "$r/b.out" 2>/dev/null)" "1"
  lacks "$l-B9 and does not claim an anchor" "$(cat "$r/b.out" 2>/dev/null)" "full-green anchor:"
  lacks "$l-B10 or an archive" "$(cat "$r/b.out" 2>/dev/null)" "full-green archive:"
}
check_t() { # name -- the proofs for the dirty-start scenario
  local r="$RES/$1"
  eq "T0 premise: the suite removed the untracked file while the sweep ran" "$([ -e "$r/t.gone" ] && echo gone || echo there)" "gone"
  eq "T1 the sweep is green: nothing in it failed" "$(cat "$r/t.rc" 2>/dev/null)" "0"
  eq "T2 HEAD did not move: the receipt names the commit it ends on, and has no head_moved_to" "$(jq -r --arg end "$(cat "$r/t.end" 2>/dev/null)" '[.head_sha == $end, (has("head_moved_to") | not)] | join(",")' "$r/t.last" 2>/dev/null)" "true,true"
  eq "T3 the tree looks clean at the end, yet the receipt says tree_clean=false: part of the run graded a dirty tree" "$(jq -r '.tree_clean' "$r/t.last" 2>/dev/null)" "false"
  eq "T4 so it is not the anchor" "$([ -e "$r/t.anchor" ] && echo anchored || echo none)" "none"
}

# ── mutation proof, launched with the scenarios so everything runs side by side ───────────────────────────────────────
MUT="$WORK/mut"; mkdir -p "$MUT"
mutant() { # name sed-expr chain|dirty -- in the background: break one line of a COPY of run-all.sh, grade it with the same proofs, record killed (a proof goes red) or survived
  local name="$1" expr="$2" kind="$3" fails
  (
    sed "$expr" "$RUN_ALL" > "$MUT/$name.sh"
    if cmp -s "$RUN_ALL" "$MUT/$name.sh"; then echo noapply > "$MUT/$name.res"; exit 0; fi
    if [ "$kind" = dirty ]; then dirty_start "m-$name" "$MUT/$name.sh"; fails="$( ( check_t "m-$name" ) 2>&1 | grep -c $'\033\\[31mFAIL' )"
    else chain "m-$name" nocache "$MUT/$name.sh"; fails="$( ( check "m-$name" M ) 2>&1 | grep -c $'\033\\[31mFAIL' )"; fi
    if [ "$fails" = 0 ]; then echo survived > "$MUT/$name.res"; else echo killed > "$MUT/$name.res"; fi
  ) &
}

echo "════════════════════════════════════════════════════════════════"
echo "run-all: HEAD moved during the sweep -> the receipt names the start commit, no anchor, no archive"
echo "════════════════════════════════════════════════════════════════"

chain d default &
chain c cold &
chain n nocache &
chain f failed &
dirty_start t &
mutant anchor     's/^        if \[ "\$HEAD_MOVED" = true \]; then$/        if false; then/' chain
mutant start      's/^  RECEIPT_HEAD_SHA="\$SWEEP_HEAD_START"$/  RECEIPT_HEAD_SHA="$RECEIPT_HEAD_NOW"/' chain
mutant detect     's/ || HEAD_MOVED=true$/ || HEAD_MOVED=false/' chain
mutant moved-to   's/{head_moved_to:\$head_end}/{head_moved_to:\$head_sha}/' chain
mutant line       's/run-all: HEAD moved during the sweep (/run-all: head went elsewhere (/' chain
mutant start-tree 's/ && \[ -z "\$(_receipt_dirty_lines < "\$WORK\/status-before.txt")" \]//' dirty
wait

echo "-- D. a default sweep: the suite cache is on ------------------------------------------------------------------"
check d D
echo "-- C. --cold ---------------------------------------------------------------------------------------------------"
check c C
echo "-- N. --no-cache: the legacy receipt -----------------------------------------------------------------------------"
check n N
echo "-- F. --failed: the amend of a red run -------------------------------------------------------------------------"
check f F
echo "-- T. a sweep that started on a dirty tree is not tree_clean, whatever the tree looks like at the end -------------"
check_t t

echo "-- M. mutation proof: break one line of the real run-all.sh at a time; the proof for it must go red -----------------"
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
verdict anchor     "a sweep that saw HEAD move is anchored and archived again"
verdict start      "the receipt names the HEAD read at the end, not the commit the sweep started on"
verdict detect     "a HEAD that moved is never noticed"
verdict moved-to   "the receipt no longer records where HEAD went"
verdict line       "the run no longer says that HEAD moved"
verdict start-tree "a sweep that started on a dirty tree is tree_clean again once the dirt is gone"

echo
printf 'falsifiability: %d/%d\n' "$KILLED" "$TOTAL"
printf '  run-all-head-moved: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

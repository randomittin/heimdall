#!/usr/bin/env bash
# test/lean-gate-falsify.test.sh -- T5.2 of the 3.x lean-core plan (docs/superpowers/plans/2026-11-12-3x-lean-core.md): the lean gates CAN go RED.
#
# A gate that has never been seen red proves nothing. For each lean gate below, ONE defect that gate exists to catch is written as a patch file
# (evals/lean/mutants/*.patch), applied to a TEMP SNAPSHOT of this checkout (a one-commit git copy made by uc_snapshot of test/use-cases/lib.sh, under a private
# temp root removed on exit; no worktree and no file of this checkout is ever edited), and the gate's own suite is run against that snapshot. Per mutant:
#   golden  the suite on the UNPATCHED snapshot is GREEN (exit 0, no FAIL line), so any red below is the patch's doing and not the suite's or the machine's;
#   killed  the same suite on the PATCHED snapshot is RED: a non-zero exit AND a FAIL line on the check that guards that behaviour. A patch that merely breaks
#           the script (every check then fails) is no kill: the named check has to be the one that notices.
# The score is killed / total and must be 1.0: one surviving mutant is a gate that would let its defect through.
#
#   mutant                           defect the patch injects                                            gate (suite)                            invariant
#   reset-deletes-ledger             install.sh --reset removes <runtime home>/ledger                    test/install-reset-userdata.test.sh     INV-L10
#   noflag-extra-append              a no-flag upgrade run appends the PATH block to the profile again   test/install-noflag-identical.test.sh   INV-L8
#   backup-skips-skills-config       lean_backup.py leaves skills-config.json out of the backup          test/lean-backup-restore.test.sh        INV-L9
#   route-guard-ok-while-proxy-live  lean_route_guard.sh answers ok (exit 0) while a proxy route is live test/lean-route-guard.test.sh           INV-L11
#   sparse-on-demand-cut-skipped     lean_sparse.sh keeps the on-demand paths in the lean set            test/lean-sparse.test.sh                INV-L3, INV-L4, INV-L6
#   packs-hash-unchecked             skills_packs.py takes an installed pack whatever hash the lock pins test/skills-packs-resolve.test.sh       INV-L5
#
# Two ways a suite takes its tree. `snapshot`: the suite of THIS checkout with the patched snapshot as the tree under test (UC_TREE, the seam the use-case
# journeys give a mutant), for the install journeys: they install FROM that tree and read the install.sh the baseline was recorded from out of THIS checkout's
# git history, which a one-commit snapshot does not have. `copy`: the suite as it sits inside the patched snapshot, so it grades the snapshot's own
# libraries (it finds them from its own location).
#
# Usage:  bash test/lean-gate-falsify.test.sh [MUTANT ...]     no argument = every mutant, and the table must match evals/lean/mutants/ one to one.
#         HMD_FALSIFY_TIMEOUT_S=900 bounds each suite run (a hang detector, never a speed assertion).
#
# budget: 300 -- the golden suites run in parallel (the slowest is install-reset-userdata, ~70 s solo: two installs, a reset, an undo), then the six patched
# runs in parallel, plus a snapshot of the checkout and six clones of it. Two phases of the slowest suite under a six-way load, no sleep, no timing assertion.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=use-cases/lib.sh
. "$REPO/test/use-cases/lib.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
FS_TIMEOUT_S="${HMD_FALSIFY_TIMEOUT_S:-900}"
uc_begin lean_gate_falsify

# ── the mutants: name, patch, the gate's suite, how the suite takes its tree, and the FAIL line (ERE) that must be among its failures ──────────────────────
FS_NAME=(); FS_PATCH=(); FS_SUITE=(); FS_MODE=(); FS_RE=()
fs_row() { FS_NAME+=("$1"); FS_PATCH+=("$2"); FS_SUITE+=("$3"); FS_MODE+=("$4"); FS_RE+=("$5"); }
fs_row reset-deletes-ledger evals/lean/mutants/reset-deletes-ledger.patch test/install-reset-userdata.test.sh snapshot \
  'INV-L10 after the reset: user data was lost or changed'
fs_row noflag-extra-append evals/lean/mutants/noflag-extra-append.patch test/install-noflag-identical.test.sh snapshot \
  'digest zshrc differs from the baseline'
fs_row backup-skips-skills-config evals/lean/mutants/backup-skips-skills-config.patch test/lean-backup-restore.test.sh copy \
  'A: after mutating every tracked file, restore leaves every one byte-equal'
fs_row route-guard-ok-while-proxy-live evals/lean/mutants/route-guard-ok-while-proxy-live.patch test/lean-route-guard.test.sh copy \
  'B: ANTHROPIC_BASE_URL on the port Headroom listens on'
fs_row sparse-on-demand-cut-skipped evals/lean/mutants/sparse-on-demand-cut-skipped.patch test/lean-sparse.test.sh copy \
  'A: (apply lean exits 0|the lean set differs)'
fs_row packs-hash-unchecked evals/lean/mutants/packs-hash-unchecked.patch test/skills-packs-resolve.test.sh copy \
  'B: (a rebuild after an edit|the pinned hash differs)'
FS_TOTAL="${#FS_NAME[@]}"

FS_SEL=("$@")
fs_wanted() {   # fs_wanted NAME -- no argument was given, or NAME is one of them
  local s
  [ "${#FS_SEL[@]}" -eq 0 ] && return 0
  for s in "${FS_SEL[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}
for s in ${FS_SEL[@]+"${FS_SEL[@]}"}; do
  known=0; i=0
  while [ "$i" -lt "$FS_TOTAL" ]; do [ "${FS_NAME[$i]}" = "$s" ] && known=1; i=$((i + 1)); done
  [ "$known" -eq 1 ] || uc_fatal "no mutant is named $s (they are: ${FS_NAME[*]})"
done

# the table and the directory agree, so no patch is orphaned and no gate lost its mutant unnoticed (the plan names six)
if [ "${#FS_SEL[@]}" -eq 0 ]; then
  n_files="$(find "$REPO/evals/lean/mutants" -maxdepth 1 -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n_files" -eq "$FS_TOTAL" ] && [ "$FS_TOTAL" -ge 6 ]; then
    uc_ok "the mutant table and evals/lean/mutants/ agree: $FS_TOTAL patches, none orphaned"
  else
    uc_bad "the mutant table has $FS_TOTAL rows and evals/lean/mutants/ holds $n_files patch files (one each, six at least)"
  fi
fi

# ── helpers ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
fs_strip()      { perl -pe 's/\e\[[0-9;]*m//g' "$1"; }                                   # a suite's output without its colour codes
fs_fail_lines() { fs_strip "$1" | grep -E '^[[:space:]]*FAIL([[:space:]]|$)' || true; }   # the checks that failed
fs_summary()    { fs_strip "$1" | grep -E '[0-9]+ passed, [0-9]+ failed' | tail -1 | sed 's/^[[:space:]]*//'; }
fs_gkey()       { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
fs_rc()         { if [ -s "$UC_ROOT/run-$1.rc" ]; then cat "$UC_ROOT/run-$1.rc"; else echo 99; fi; }

# fs_start KEY MODE TREE SUITE -- run SUITE (a path under test/) against TREE in the background: output in run-KEY.out, exit status in run-KEY.rc
fs_start() {
  local key="$1" mode="$2" tree="$3" suite="$4"
  (
    cd "$UC_ROOT" || exit 97
    case "$mode" in
      snapshot) perl -e 'alarm shift; exec @ARGV or exit 127' "$FS_TIMEOUT_S" env UC_TREE="$tree" bash "$REPO/$suite" ;;
      *)        perl -e 'alarm shift; exec @ARGV or exit 127' "$FS_TIMEOUT_S" env -u UC_TREE bash "$tree/$suite" ;;
    esac
    echo "$?" > "$UC_ROOT/run-$key.rc"
  ) </dev/null >"$UC_ROOT/run-$key.out" 2>&1 &
}

# fs_mutant_tree NAME PATCH -- $UC_ROOT/mut-NAME: a copy of the golden snapshot with PATCH applied and committed as its one commit, the version tag moved onto
# it (an install from this tree at that tag must fetch the patched files). Returns 0 when it is ready; the reason is in mut-NAME.err
fs_mutant_tree() {
  local dir="$UC_ROOT/mut-$1" err="$UC_ROOT/mut-$1.err"
  git clone -q --no-hardlinks "$GOLD" "$dir" 2>"$err" || return 1
  git -C "$dir" apply "$2" 2>>"$err" || return 1
  git -c core.hooksPath=/dev/null -C "$dir" add -A -f 2>>"$err" || return 1
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=use-case@example.invalid -c user.name=use-case \
    -C "$dir" commit -q --amend --no-edit --no-verify 2>>"$err" || return 1
  git -c tag.gpgsign=false -C "$dir" tag -f "v$FS_VER" >/dev/null 2>>"$err"
}

# ── phase 0: the golden tree, the unpatched snapshot of this checkout ─────────────────────────────────────────────────────────────────────────────────
GOLD="$UC_ROOT/golden"
uc_snapshot "$GOLD" || uc_fatal "could not snapshot the checkout $REPO"
FS_VER="$(cat "$GOLD/VERSION")"

# ── phase 1: every selected mutant's tree and every selected gate's golden run, all at once ──────────────────────────────────────────────────────────────
FS_GK=(); FS_GSUITE=()
i=0
while [ "$i" -lt "$FS_TOTAL" ]; do
  if fs_wanted "${FS_NAME[$i]}"; then
    ( fs_mutant_tree "${FS_NAME[$i]}" "$REPO/${FS_PATCH[$i]}"; echo "$?" > "$UC_ROOT/mut-${FS_NAME[$i]}.rc" ) &
    gk="$(fs_gkey "${FS_SUITE[$i]}")"
    case " ${FS_GK[*]-} " in
      *" $gk "*) ;;
      *) FS_GK+=("$gk"); FS_GSUITE+=("${FS_SUITE[$i]}"); fs_start "gold-$gk" "${FS_MODE[$i]}" "$GOLD" "${FS_SUITE[$i]}" ;;
    esac
  fi
  i=$((i + 1))
done
wait

# ── phase 2: each suite against its own patched tree ──────────────────────────────────────────────────────────────────────────────────────────────────
i=0
while [ "$i" -lt "$FS_TOTAL" ]; do
  name="${FS_NAME[$i]}"
  if fs_wanted "$name" && [ "$(cat "$UC_ROOT/mut-$name.rc" 2>/dev/null || echo 1)" = 0 ]; then
    fs_start "mut-$name" "${FS_MODE[$i]}" "$UC_ROOT/mut-$name" "${FS_SUITE[$i]}"
  fi
  i=$((i + 1))
done
wait

# ── verdicts: the golden suites ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
FS_GREEN=" "
j=0
while [ "$j" -lt "${#FS_GK[@]}" ]; do
  gk="${FS_GK[$j]}"; suite="${FS_GSUITE[$j]}"; out="$UC_ROOT/run-gold-$gk.out"; rc="$(fs_rc "gold-$gk")"
  nfail="$(fs_fail_lines "$out" | grep -c . || true)"
  sum="$(fs_summary "$out")"; [ -z "$sum" ] || sum="; $sum"
  if [ "$rc" -eq 0 ] && [ "$nfail" -eq 0 ]; then
    FS_GREEN="$FS_GREEN$gk "
    uc_ok "golden: $suite is GREEN on the unpatched snapshot (exit 0, no FAIL line$sum)"
  else
    uc_bad "golden: $suite is not green on the unpatched snapshot (exit $rc, $nfail FAIL line(s)): none of its mutants can be graded" \
      "$(fs_fail_lines "$out" | head -3 | cut -c1-160 | tr '\n' '|')"
  fi
  j=$((j + 1))
done

# ── verdicts: the mutants ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
FS_KILLED=0; FS_GRADED=0
i=0
while [ "$i" -lt "$FS_TOTAL" ]; do
  name="${FS_NAME[$i]}"
  if fs_wanted "$name"; then
    suite="${FS_SUITE[$i]}"; re="${FS_RE[$i]}"; gk="$(fs_gkey "$suite")"
    FS_GRADED=$((FS_GRADED + 1))
    if [ "$(cat "$UC_ROOT/mut-$name.rc" 2>/dev/null || echo 1)" != 0 ]; then
      uc_bad "mutant $name: ${FS_PATCH[$i]} could not be applied to the snapshot (the code it patches moved: regenerate it)" \
        "$(head -c 300 "$UC_ROOT/mut-$name.err" 2>/dev/null | tr '\n' ' ')"
    else
      case "$FS_GREEN" in
        *" $gk "*)
          out="$UC_ROOT/run-mut-$name.out"; rc="$(fs_rc "mut-$name")"
          hit="$(fs_fail_lines "$out" | grep -E -- "$re" | head -1 | sed 's/^[[:space:]]*//' | cut -c1-150)"
          if [ "$rc" -ne 0 ] && [ -n "$hit" ]; then
            FS_KILLED=$((FS_KILLED + 1))
            uc_ok "mutant $name: $suite goes RED (exit $rc) on the check that guards it: $hit"
          elif [ "$rc" -eq 0 ]; then
            uc_bad "mutant $name SURVIVED: $suite stayed GREEN with the defect in place (the gate would let it through)"
          else
            uc_bad "mutant $name: $suite went RED (exit $rc) but not on the check that guards it (wanted a FAIL line matching /$re/)" \
              "$(fs_fail_lines "$out" | head -3 | cut -c1-160 | tr '\n' '|')"
          fi ;;
        *) uc_bad "mutant $name: not graded, the golden $suite is not green" ;;
      esac
    fi
  fi
  i=$((i + 1))
done

printf 'falsifiability score: %s of %s mutants killed\n' "$FS_KILLED" "$FS_GRADED"
if [ "$FS_GRADED" -gt 0 ] && [ "$FS_KILLED" -eq "$FS_GRADED" ]; then
  uc_ok "score 1.0: every graded mutant turned its gate RED while the golden gates stayed GREEN"
else
  uc_bad "score below 1.0: $FS_KILLED of $FS_GRADED mutants killed"
fi
uc_finish

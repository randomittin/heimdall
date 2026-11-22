#!/usr/bin/env bash
# test/use-cases/run.sh -- hmd's own use-case check: every journey, then every mutant of every journey.
#
#   bash test/use-cases/run.sh [--only NAME[,NAME...]] [--no-mutants] [--jobs N]
#
# A journey (test/use-cases/journeys/*.sh) is one thing a person comes to hmd to get done, walked through the public door they use, named in their words
# (skills/heimdall/references/use-case-tests.md). The runner:
#   1. snapshots this checkout once (tracked and untracked files as they are on disk, uncommitted edits included) into a throwaway git repo: the tree under test
#   2. runs each journey against it, in a sandbox of its own (a fresh HOME, a fake claude and keychain, no network), up to N at a time (default 3)
#   3. runs each mutant of test/use-cases/mutants.list: the same snapshot with ONE line broken, against the journey that pins it. The journey must go RED.
#      A mutant that stays green means that journey would not notice the break; a mutant whose sed matches nothing means the list and the code have drifted.
#   4. checks that no journey wrote into the shared tree, prints one line per journey and per mutant, and a summary.
# Exit 0 only when at least one journey was found, every journey passed, every mutant was killed and the tree is untouched; 1 otherwise; 5 below the disk floor.
# This file is not matched by test/run-all.sh (its glob is test/*.test.sh, one level deep): the sweep never runs the journeys a second time.
#
# mutants.list: one mutant per line, tab separated: <journey file name without .sh> <file in the tree> <sed expression> <mutant name>. Blank lines and # lines are skipped.
# Keep the seds portable (BSD and GNU): no -E, \+ or \|; pick a delimiter the expression does not contain.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
JOURNEYS_DIR="$HERE/journeys"
MUTANTS="$HERE/mutants.list"

ONLY=""
RUN_MUTANTS=1
JOBS="${UC_JOBS:-3}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --no-mutants) RUN_MUTANTS=0; shift ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "use-cases: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*|0) echo "use-cases: --jobs wants a whole number of 1 or more" >&2; exit 2 ;; esac

# The journeys write a few hundred MB of clones and temp data: refuse to start under the disk floor, as the sweep does (HMD_MIN_FREE_PCT, 0 = off).
if [ -r "$REPO/bin/lib/hmd_disk_floor.sh" ]; then
  # shellcheck source=../../bin/lib/hmd_disk_floor.sh
  . "$REPO/bin/lib/hmd_disk_floor.sh"
  hmd_disk_floor_check "${TMPDIR:-/tmp}" "$REPO" || { echo "use-cases: refusing to start: not enough free disk (see above)" >&2; exit 5; }
fi

selected() {  # selected NAME -- no --only, or NAME contains one of its comma-separated words
  local w
  [ -n "$ONLY" ] || return 0
  for w in $(printf '%s' "$ONLY" | tr ',' ' '); do
    case "$1" in *"$w"*) return 0 ;; esac
  done
  return 1
}

JOURNEYS=()
for f in "$JOURNEYS_DIR"/*.sh; do
  [ -f "$f" ] || continue
  selected "$(basename "$f" .sh)" && JOURNEYS+=("$f")
done
if [ "${#JOURNEYS[@]}" -eq 0 ]; then
  echo "use-cases: no journeys found in $JOURNEYS_DIR${ONLY:+ matching --only $ONLY}: a check that checks nothing is not a pass" >&2
  exit 1
fi

for tool in git jq perl python3 shasum tar; do command -v "$tool" >/dev/null 2>&1 || { echo "use-cases: $tool is required" >&2; exit 2; }; done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/use-cases.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
cleanup() { [ "${UC_KEEP:-0}" = 1 ] && { echo "kept: $WORK" >&2; return 0; }; chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SNAP="$WORK/tree"
unset UC_TREE
uc_snapshot "$SNAP" || { echo "use-cases: could not snapshot the checkout $REPO" >&2; exit 2; }
SNAP_SHA="$(git -C "$SNAP" rev-parse --short HEAD)"

T_KIND=(); T_LABEL=(); T_FILE=(); T_TREE=(); T_NOTE=()
add_task() { local n="${#T_KIND[@]}"; T_KIND[n]="$1"; T_LABEL[n]="$2"; T_FILE[n]="$3"; T_TREE[n]="$4"; T_NOTE[n]="${5:-}"; }

for f in "${JOURNEYS[@]}"; do add_task journey "$(basename "$f" .sh)" "$f" "$SNAP"; done

ERRORS=0
# make_mutant DEST FILE SEDEXPR -- a clone of the snapshot with one file edited by SEDEXPR and committed, the tag moved onto it. 0 ok, 1 sed changed nothing, 2 otherwise.
make_mutant() {
  local dest="$1" file="$2" expr="$3" ver
  git -c core.hooksPath=/dev/null clone -q "$SNAP" "$dest" 2>/dev/null || return 2
  [ -f "$dest/$file" ] || return 2
  sed -e "$expr" "$dest/$file" > "$dest/$file.mut" || return 2
  if cmp -s "$dest/$file" "$dest/$file.mut"; then rm -f "$dest/$file.mut"; return 1; fi
  cat "$dest/$file.mut" > "$dest/$file"
  rm -f "$dest/$file.mut"
  ver="$(cat "$dest/VERSION")"
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=use-case@example.invalid -c user.name=use-case \
    -C "$dest" commit -q -a --no-verify -m "mutant" || return 2
  git -c tag.gpgsign=false -C "$dest" tag -f "v$ver" >/dev/null 2>&1 || return 2
}

if [ "$RUN_MUTANTS" -eq 1 ] && [ -f "$MUTANTS" ]; then
  m=0
  while IFS="$(printf '\t')" read -r mj mfile mexpr mname; do
    case "$mj" in ''|'#'*) continue ;; esac
    selected "$mj" || continue
    m=$((m + 1))
    if [ ! -f "$JOURNEYS_DIR/$mj.sh" ]; then
      echo "  ERROR  mutant $mname names journey $mj, which does not exist" >&2; ERRORS=$((ERRORS + 1)); continue
    fi
    make_mutant "$WORK/mutant-$m" "$mfile" "$mexpr"
    case $? in
      0) add_task mutant "$mj/$mname" "$JOURNEYS_DIR/$mj.sh" "$WORK/mutant-$m" "$mfile" ;;
      1) echo "  ERROR  mutant $mname: its sed matches nothing in $mfile (the list and the code have drifted)" >&2; ERRORS=$((ERRORS + 1)) ;;
      *) echo "  ERROR  mutant $mname: could not build it from $mfile" >&2; ERRORS=$((ERRORS + 1)) ;;
    esac
  done < "$MUTANTS"
fi

TOTAL="${#T_KIND[@]}"
echo "use-cases: ${#JOURNEYS[@]} journeys, $((TOTAL - ${#JOURNEYS[@]})) mutants, jobs=$JOBS, tree = snapshot of $REPO ($SNAP_SHA)"

i=0
while [ "$i" -lt "$TOTAL" ]; do
  while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.5; done
  (
    t0="$(date +%s)"
    UC_TREE="${T_TREE[$i]}" bash "${T_FILE[$i]}" > "$WORK/t$i.log" 2>&1
    echo "$?" > "$WORK/t$i.rc"
    echo "$(( $(date +%s) - t0 ))" > "$WORK/t$i.secs"
  ) &
  i=$((i + 1))
done
wait

first_fail() { grep -m1 '^  FAIL ' "$1" 2>/dev/null | sed 's/^  FAIL //' | cut -c1-110; }
J_PASS=0; J_FAIL=0; M_KILLED=0; M_BAD=0
echo "journeys:"
i=0
while [ "$i" -lt "$TOTAL" ]; do
  if [ "${T_KIND[$i]}" = journey ]; then
    rc="$(cat "$WORK/t$i.rc" 2>/dev/null || echo 99)"; secs="$(cat "$WORK/t$i.secs" 2>/dev/null || echo ?)"
    checks="$(grep -c '^  PASS ' "$WORK/t$i.log" 2>/dev/null || true)"
    if [ "$rc" = 0 ]; then
      J_PASS=$((J_PASS + 1)); printf '  PASS  %-44s %3s checks  %4ss\n' "${T_LABEL[$i]}" "${checks:-0}" "$secs"
    else
      J_FAIL=$((J_FAIL + 1)); printf '  FAIL  %-44s exit %s  %4ss\n' "${T_LABEL[$i]}" "$rc" "$secs"
      if grep -q '^  FAIL ' "$WORK/t$i.log"; then grep -A1 '^  FAIL ' "$WORK/t$i.log" | grep -v '^--$' | head -12 | sed 's/^/        /'; else tail -n 12 "$WORK/t$i.log" | sed 's/^/        /'; fi
    fi
  fi
  i=$((i + 1))
done
if [ "$((TOTAL - ${#JOURNEYS[@]}))" -gt 0 ]; then
  echo "mutants (one line of the product broken; the journey that pins it must go RED):"
  i=0
  while [ "$i" -lt "$TOTAL" ]; do
    if [ "${T_KIND[$i]}" = mutant ]; then
      rc="$(cat "$WORK/t$i.rc" 2>/dev/null || echo 99)"; secs="$(cat "$WORK/t$i.secs" 2>/dev/null || echo ?)"
      case "$rc" in
        1) M_KILLED=$((M_KILLED + 1)); printf '  killed    %-52s %4ss  (%s)\n' "${T_LABEL[$i]}" "$secs" "$(first_fail "$WORK/t$i.log")" ;;
        0) M_BAD=$((M_BAD + 1)); printf '  SURVIVED  %-52s %4ss  (journey stayed green: it does not notice a break in %s)\n' "${T_LABEL[$i]}" "$secs" "${T_NOTE[$i]}" ;;
        *) M_BAD=$((M_BAD + 1)); printf '  ERROR     %-52s %4ss  (the run did not finish: exit %s; %s)\n' "${T_LABEL[$i]}" "$secs" "$rc" "$(first_fail "$WORK/t$i.log")" ;;
      esac
    fi
    i=$((i + 1))
  done
fi

# The snapshot is shared by every journey and is read-only to them: a write into it would hide behind the next journey's clean tree.
DIRTY="$(git -C "$SNAP" status --porcelain --ignored 2>/dev/null | head -5)"
TREE_BAD=0
if [ -n "$DIRTY" ]; then TREE_BAD=1; echo "FAIL  a journey wrote into the shared tree under test:"; printf '%s\n' "$DIRTY" | sed 's/^/        /'; fi

echo "--------------------------------------------------------------------"
printf 'use-cases: %d journeys, %d passed, %d failed; mutants %d/%d killed' "${#JOURNEYS[@]}" "$J_PASS" "$J_FAIL" "$M_KILLED" "$((M_KILLED + M_BAD + ERRORS))"
[ "$ERRORS" -eq 0 ] || printf '; %d mutant(s) could not be built' "$ERRORS"
[ "$TREE_BAD" -eq 0 ] || printf '; the shared tree was written to'
printf '\n'
if [ "$J_FAIL" -eq 0 ] && [ "$M_BAD" -eq 0 ] && [ "$ERRORS" -eq 0 ] && [ "$TREE_BAD" -eq 0 ]; then exit 0; fi
exit 1

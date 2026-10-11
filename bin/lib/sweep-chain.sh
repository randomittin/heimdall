#!/usr/bin/env bash
# bin/lib/sweep-chain.sh -- the incremental-sweep policy, shared by its WRITER and its GATE.
#
#   writer: test/run-all.sh --since-green   (sources this, only in that mode, and REQUIRES it there)
#   gate:   bin/heimdall-state check-quality-gates   (sources it defensively: absent => an incremental receipt is refused,
#           never waved through)
#
# WHY IT EXISTS. The full sweep (~500 suites, ~70 min at --jobs 2) ran about nine times in one day because every small merge
# staled the last green receipt. An incremental sweep re-runs only the suites a diff can affect, and the push gate accepts its
# receipt while it CHAINS to a green FULL receipt and the rules below held. One file, so the rule the writer applied and the rule
# the gate re-checks can never drift apart (the same reason bin/lib/hook-owned-path.sh exists).
#
# THE RULES.
#   base      = HEAD of the last GREEN FULL sweep (receipts/last-full-green.json). Every incremental sweep diffs base..HEAD, so
#               it is cumulative: running one twice never forgets a change.
#   selected  = a suite is selected when it references a changed path, or the basename of a changed bin/ script or module (the
#               suite file AND the test/lib helpers it uses are searched), or is itself a changed test file. The set of changed
#               paths is first widened through scripts that call/source a changed script (a suite that runs tool-b never names
#               bin/lib/shared.sh, which tool-b sources).
#   escalate  = ALWAYS a full sweep when the diff touches test/gate infrastructure (HMD_SWEEP_INFRA_RE), exceeds
#               HMD_SWEEP_LIMIT_FILES files, would select more than HMD_SWEEP_LIMIT_SELECTED_PCT percent of the suites, or the
#               base is more than HMD_SWEEP_LIMIT_BASE_DAYS days / HMD_SWEEP_LIMIT_BASE_COMMITS commits old, or is not an ancestor
#               of HEAD. Hook-owned paths (bin/lib/hook-owned-path.sh) are never part of "the diff".
#   carried   = a suite that was red in the previous run is always re-run: a failure survives until it passes.
#
# LIMITS ARE THE GATE'S. The gate always evaluates with the HMD_SWEEP_LIMIT_* constants below. The writer may only TIGHTEN them
# (hmd_sweep_tighten, via HMD_SWEEP_MAX_*) -- a looser writer would only write receipts the gate then refuses, and the gate must
# not be loosened by an environment variable.
#
# Bash 3.2 compatible (no associative arrays, no mapfile); safe to source under `set -euo pipefail`.

# shellcheck disable=SC2034  # the HMD_SWEEP_LIMIT_* constants are read by the scripts that source this file, not by this file
[ -n "${_HMD_SWEEP_CHAIN_SH:-}" ] && return 0 2>/dev/null || true
_HMD_SWEEP_CHAIN_SH=1

if [ -z "${HMD_HOOK_OWNED_PATH_RE:-}" ] && [ -r "$(dirname "${BASH_SOURCE[0]}")/hook-owned-path.sh" ]; then
  # shellcheck source=hook-owned-path.sh
  . "$(dirname "${BASH_SOURCE[0]}")/hook-owned-path.sh"
fi

HMD_SWEEP_LIMIT_FILES=40
HMD_SWEEP_LIMIT_SELECTED_PCT=20
HMD_SWEEP_LIMIT_BASE_DAYS=7
# hook auto-commits (journal, ledger checkpoints) inflate the commit count of an otherwise small diff, so this is generous;
# the file and age limits are the ones that normally bind.
HMD_SWEEP_LIMIT_BASE_COMMITS=200

# Test infrastructure and the receipt/gate code: a change here can alter what EVERY suite proves, so it is never incremental.
HMD_SWEEP_INFRA_RE='test/run-all\.sh|test/lib/.*|hooks/hooks\.json|hooks/hooks\.metadata\.json|\.heimdall/hooks/.*|bin/heimdall-state|bin/heimdall-precheck-bash|bin/heimdall-gate-run|bin/lib/hook-owned-path\.sh|bin/lib/sweep-chain\.sh|release/ship\.sh'

# hmd_sweep_tighten VALUE DEFAULT -- the smaller of the two when VALUE is a non-negative integer, else DEFAULT.
hmd_sweep_tighten() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) if [ "$1" -lt "$2" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi ;;
  esac
}

# hmd_sweep_changed_files REPO BASE HEAD -- repo-relative paths that differ, hook-owned paths excluded, one per line.
hmd_sweep_changed_files() {
  local out
  out="$(git -C "$1" diff --name-only --no-renames "$2" "$3" 2>/dev/null)" || return 1
  if [ -n "${HMD_HOOK_OWNED_PATH_RE:-}" ]; then
    printf '%s\n' "$out" | sed '/^$/d' | grep -Ev "^${HMD_HOOK_OWNED_PATH_RE}\$" || true
  else
    printf '%s\n' "$out" | sed '/^$/d'
  fi
}

# hmd_sweep_rules_violation REPO BASE HEAD NOW_EPOCH MAX_FILES MAX_DAYS MAX_COMMITS
#   Prints WHY the diff base..HEAD may not be graded incrementally and returns 1; prints nothing and returns 0 when it may.
hmd_sweep_rules_violation() {
  local repo="$1" base="$2" head="$3" now="$4" max_files="$5" max_days="$6" max_commits="$7"
  local changed infra shown n ct age commits
  if ! git -C "$repo" cat-file -e "${base}^{commit}" 2>/dev/null; then
    echo "the last full green base ${base:0:12} is not a commit in this repository"; return 1
  fi
  if ! git -C "$repo" merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
    echo "the last full green base ${base:0:12} is not an ancestor of ${head:0:12} (history was rewritten)"; return 1
  fi
  changed="$(hmd_sweep_changed_files "$repo" "$base" "$head")"
  infra="$(printf '%s\n' "$changed" | grep -E "^(${HMD_SWEEP_INFRA_RE})\$" || true)"
  if [ -n "$infra" ]; then
    shown="$(printf '%s\n' "$infra" | head -3 | paste -sd, -)"
    echo "test/gate infrastructure changed (${shown}) -- it can change what every suite proves"; return 1
  fi
  n="$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$n" -gt "$max_files" ]; then echo "${n} files changed since the last full green (limit ${max_files})"; return 1; fi
  ct="$(git -C "$repo" log -1 --format=%ct "$base" 2>/dev/null)"
  case "$ct" in ''|*[!0-9]*) echo "cannot read the commit date of the last full green ${base:0:12}"; return 1 ;; esac
  age=$(( (now - ct) / 86400 ))
  if [ "$age" -gt "$max_days" ]; then echo "the last full green is ${age} days old (limit ${max_days})"; return 1; fi
  commits="$(git -C "$repo" rev-list --count "${base}..${head}" 2>/dev/null || echo 0)"
  if [ "$commits" -gt "$max_commits" ]; then echo "${commits} commits since the last full green (limit ${max_commits})"; return 1; fi
  return 0
}

# hmd_sweep_select REPO BASE HEAD WORKDIR [CARRIED_FILE]
#   Writes WORKDIR/changed.txt (the diff) and WORKDIR/selected.txt (suite basenames to run, one per line); prints the reason.
#   CARRIED_FILE lists suites that were red last time (one basename per line); those still on disk are always included.
hmd_sweep_select() {
  local repo="$1" base="$2" head="$3" work="$4" carried="${5:-}"
  local pat="$work/patterns.txt" hits="$work/hits.txt" refs="$work/refs.txt" libpat="$work/libpat.txt"
  local p r l round added nchanged nsel ncarry=0
  hmd_sweep_changed_files "$repo" "$base" "$head" > "$work/changed.txt"
  : > "$pat"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$p" >> "$pat"
    case "$p" in
      bin/*) printf '%s\n' "${p##*/}" >> "$pat" ;;        # a script or module is also reached by bare name through PATH
      */*/*) printf '%s\n' "${p%/*}" >> "$pat" ;;          # a suite may name the directory a fixture lives in
    esac
  done < "$work/changed.txt"

  # Widen through the code that calls or sources a changed file (three hops at most): a suite runs tool-b, never the lib it sources.
  round=0
  while [ "$round" -lt 3 ] && [ -s "$pat" ]; do
    round=$((round + 1)); added=0
    git -C "$repo" grep -lF -f "$pat" -- bin hooks sentinels release adapters install.sh > "$refs" 2>/dev/null || true
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      if grep -qxF -- "$r" "$pat"; then continue; fi
      printf '%s\n%s\n' "$r" "${r##*/}" >> "$pat"; added=1
    done < "$refs"
    [ "$added" -eq 1 ] || break
  done

  # Suites (and the test/lib helpers they use) that mention any of it.
  : > "$hits"
  if [ -s "$pat" ]; then
    ( cd "$repo" && grep -lsF -f "$pat" -- test/*.test.sh test/lib/* 2>/dev/null ) | sort -u > "$hits" || true
  fi
  round=0
  while [ "$round" -lt 3 ]; do
    round=$((round + 1)); : > "$libpat"
    while IFS= read -r l; do
      case "$l" in test/lib/*) printf '%s\n' "${l##*/}" >> "$libpat" ;; esac
    done < "$hits"
    [ -s "$libpat" ] || break
    ( cd "$repo" && grep -lsF -f "$libpat" -- test/*.test.sh test/lib/* 2>/dev/null ) | sort -u > "$work/hits.more" || true
    cat "$hits" "$work/hits.more" | sort -u > "$work/hits.next"
    if cmp -s "$hits" "$work/hits.next"; then break; fi
    mv "$work/hits.next" "$hits"
  done

  {
    grep -E '^test/[^/]+\.test\.sh$' "$hits" || true
    while IFS= read -r p; do
      case "$p" in test/*.test.sh) if [ -f "$repo/$p" ]; then printf '%s\n' "$p"; fi ;; esac
    done < "$work/changed.txt"
  } | sed 's#^test/##' | sort -u > "$work/selected.txt"
  nsel="$(wc -l < "$work/selected.txt" | tr -d ' ')"

  if [ -n "$carried" ] && [ -s "$carried" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] && [ -f "$repo/test/$p" ] || continue
      if ! grep -qxF -- "$p" "$work/selected.txt"; then printf '%s\n' "$p" >> "$work/selected.txt"; ncarry=$((ncarry + 1)); fi
    done < "$carried"
    sort -u "$work/selected.txt" > "$work/selected.next" && mv "$work/selected.next" "$work/selected.txt"
  fi

  nchanged="$(wc -l < "$work/changed.txt" | tr -d ' ')"
  printf '%s changed file(s), hook-owned paths excluded; %s suite(s) reference them directly, through test/lib helpers, or through scripts that call them' "$nchanged" "$nsel"
  if [ "$ncarry" -gt 0 ]; then printf '; %s carried forward because they were red in the previous run' "$ncarry"; fi
}

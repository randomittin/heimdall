#!/usr/bin/env bash
# test/repo-never-left-bare.test.sh — guards against a `git init --bare` call
# ever flipping the REAL repo's core.bare to true.
#
#   bash test/repo-never-left-bare.test.sh    (exit 0 = all cases pass)
#
# THE DEFECT (2026-08-08): the main repo's .git/config had `bare = true` set,
# and `git status` failed with "fatal: this operation must be run in a work
# tree". MECHANISM: `git init --bare` run inside an EXISTING repo reinitializes
# it in place and sets core.bare=true on THAT repo. Many test files run
#   git init --bare -q "$SOMEVAR"
# and if $SOMEVAR is empty/unset at that moment (mktemp failed silently, a `cd`
# to a temp dir failed silently, etc.), the command's target path argument
# degrades to nothing and git falls back to the CURRENT working directory —
# which, in a dev shell, easily is the real repo checkout.
#
# SCOPE DECISION: only `--bare` invocations are in scope, deliberately. A
# plain non-bare `git init` re-run against an existing repo does NOT flip
# core.bare — it just reinitializes a non-bare repo in place, which cannot
# reproduce this specific symptom. A full-corpus grep of test/*.sh for
# `--bare` found exactly 14 call sites across 9 files; every one is a real
# `git init --bare` invocation. There is no broader "any git init" scope
# creep here.
#
# THIS FILE PROVES THREE THINGS:
#   (a) the repo this script is run from is not currently left bare;
#   (b) no test/*.sh file contains an UNGUARDED `git init --bare` call —
#       "unguarded" means the target path argument is missing, OR is a
#       variable reference with no `[ -n "$VAR" ] || exit` guard on the
#       nearest non-blank line immediately before it;
#   (c) MUTATION PROOF — the scanner in (b) is exercised against synthetic
#       fixtures with known-bad cases (must be flagged) and known-good cases
#       (must NOT be flagged). A scan that can never fail is decoration, not
#       a test.
#
# An EMPTY scan (near-zero files examined) is treated as FAILURE, never a
# silent pass — mirrors test/run-all.sh's own anti-vacuous MIN_SUITES guard.
#
# bash 3.2 (macOS system bash) compatible: no `timeout(1)` — perl's
# `alarm N; exec @ARGV` stands in for the one genuine subprocess call below.
# perl can only exec a real executable, not a shell function, so it is not
# used to wrap the pure-text scanner (which is local grep/sed/awk with no
# realistic hang risk, and mechanically can't be perl-wrapped anyway). No
# associative arrays, no mapfile/readarray. Pipelines are only ever used
# directly as if/while conditions or captured via command substitution —
# $? is never read as a stale separate statement after a pipe. printf '%s'
# feeds grep/sed/awk, never echo.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }

PERL_BIN="$(command -v perl || true)"
# run_with_alarm SECS CMD...  — CMD must be a real executable (perl's exec
# replaces the process image; it cannot invoke a shell function).
run_with_alarm() {
  local secs="$1"; shift
  if [ -n "$PERL_BIN" ]; then
    "$PERL_BIN" -e "alarm $secs; exec @ARGV" "$@"
  else
    "$@"
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/repo-never-left-bare.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "repo-never-left-bare harness  root=$ROOT"
echo "--------------------------------------------------------------------"

# ════════════════════════════════════════════════════════════════════════
# (a) the repo this script runs from is not left bare.
# ════════════════════════════════════════════════════════════════════════
BARE_VAL="$(run_with_alarm 10 git -C "$ROOT" config --get core.bare 2>/dev/null || true)"
if [ "$BARE_VAL" != "true" ]; then
  ok "repo core.bare != true (got '${BARE_VAL:-<unset>}')"
else
  bad "repo core.bare == true — THE DEFECT IS PRESENT RIGHT NOW"
fi

# ════════════════════════════════════════════════════════════════════════
# (b)/(c) scanner: flag any `git init --bare` call whose target path is
# absent, or is an unguarded variable reference.
# ════════════════════════════════════════════════════════════════════════
is_blank() {
  ! printf '%s\n' "$1" | grep -qE '[^[:space:]]'
}

# scan_file PATH — prints one line per finding, tab-separated:
#   ABSENT<TAB>path<TAB>lineno<TAB>line       (no target argument at all)
#   UNGUARDED<TAB>path<TAB>lineno<TAB>line    (target is an unguarded variable)
# A literal/quoted-string target, or a variable guarded by an
# `[ -n "$VAR" ] || ... exit ...` line on the nearest non-blank line before
# it, is NOT reported.
scan_file() {
  local path="$1"
  local candidates
  candidates="$(grep -nE 'git[[:space:]]+init[[:space:]].*--bare' "$path" 2>/dev/null || true)"
  [ -n "$candidates" ] || return 0
  local rec lineno line lastfield target varname prevno prevline
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    lineno="${rec%%:*}"
    [ -n "$lineno" ] || continue
    line="$(awk -v n="$lineno" 'NR==n{print; exit}' "$path")"
    if printf '%s\n' "$line" | grep -qE '^[[:space:]]*#'; then continue; fi
    lastfield="$(printf '%s\n' "$line" | awk '{print $NF}')"
    case "$lastfield" in
      --bare|-q|--quiet|init|"")
        printf 'ABSENT\t%s\t%s\t%s\n' "$path" "$lineno" "$line"
        continue ;;
    esac
    target="$(printf '%s\n' "$lastfield" | sed -E 's/^"//; s/"$//; s/^\\//')"
    case "$target" in
      '$'*|'${'*)
        varname="$(printf '%s\n' "$target" | sed -E 's/^\$\{?//; s/\}?$//')"
        prevno=$((lineno - 1)); prevline=""
        while [ "$prevno" -ge 1 ]; do
          prevline="$(awk -v n="$prevno" 'NR==n{print; exit}' "$path")"
          if is_blank "$prevline"; then prevno=$((prevno - 1)); continue; fi
          break
        done
        case "$prevline" in
          *"[ -n"*"$varname"*"exit"*) : ;;
          *) printf 'UNGUARDED\t%s\t%s\t%s\n' "$path" "$lineno" "$line" ;;
        esac
        ;;
      *) : ;;
    esac
  done <<SCANLINES
$candidates
SCANLINES
}

FILES_SCANNED=0
VIOLATIONS="$WORK/violations.log"
: > "$VIOLATIONS"

for f in "$ROOT"/test/*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  # Exclude self: this file's own header prose and fixture heredocs below
  # would otherwise self-match the scanner's own grep pattern.
  [ "$base" = "repo-never-left-bare.test.sh" ] && continue
  FILES_SCANNED=$((FILES_SCANNED + 1))
  scan_file "$f" >> "$VIOLATIONS"
done

MIN_FILES=50
if [ "$FILES_SCANNED" -ge "$MIN_FILES" ]; then
  ok "scan floor: examined $FILES_SCANNED test/*.sh files (>= $MIN_FILES)"
else
  bad "scan floor: only scanned $FILES_SCANNED test/*.sh files (want >= $MIN_FILES) — an empty/near-empty scan is a FAILURE, not a pass"
fi

VIOLATION_COUNT=$(wc -l < "$VIOLATIONS" | tr -d '[:space:]')
if [ "$VIOLATION_COUNT" -eq 0 ]; then
  ok "no unguarded/absent-target 'git init --bare' call sites in test/*.sh"
else
  bad "$VIOLATION_COUNT unguarded/absent-target 'git init --bare' call site(s) found:"
  while IFS= read -r vline; do
    [ -n "$vline" ] || continue
    vtag="$(printf '%s\n' "$vline" | cut -f1)"
    vpath="$(printf '%s\n' "$vline" | cut -f2)"
    vlineno="$(printf '%s\n' "$vline" | cut -f3)"
    printf '    %s %s:%s\n' "$vtag" "${vpath#"$ROOT"/}" "$vlineno" >&2
  done < "$VIOLATIONS"
fi

# ════════════════════════════════════════════════════════════════════════
# (c) MUTATION PROOF — the scanner above must demonstrably distinguish bad
# from good. A check that cannot be made to fail is decoration.
# ════════════════════════════════════════════════════════════════════════
FIXDIR="$WORK/fixtures"
mkdir -p "$FIXDIR"

cat > "$FIXDIR/bad-unguarded.sh" <<'FIXEOF'
#!/usr/bin/env bash
name="$1"
bare="$WORK/$name.git"
git init --bare -q "$bare"
FIXEOF

cat > "$FIXDIR/bad-absent.sh" <<'FIXEOF'
#!/usr/bin/env bash
cd "$maybe_empty_dir"
git init --bare -q
FIXEOF

cat > "$FIXDIR/good-guarded.sh" <<'FIXEOF'
#!/usr/bin/env bash
name="$1"
bare="$WORK/$name.git"
[ -n "$bare" ] || { echo "FATAL: bare path empty" >&2; exit 1; }
git init --bare -q "$bare"
FIXEOF

cat > "$FIXDIR/good-literal.sh" <<'FIXEOF'
#!/usr/bin/env bash
git init --bare -q "/tmp/some/literal/path.git"
FIXEOF

BAD1_OUT="$(scan_file "$FIXDIR/bad-unguarded.sh")"
if printf '%s\n' "$BAD1_OUT" | grep -q '^UNGUARDED'; then
  ok "mutation proof: scanner FLAGS an unguarded variable target (bad-unguarded.sh)"
else
  bad "mutation proof: scanner MISSED an unguarded variable target (bad-unguarded.sh) — scanner is broken"
fi

BAD2_OUT="$(scan_file "$FIXDIR/bad-absent.sh")"
if printf '%s\n' "$BAD2_OUT" | grep -q '^ABSENT'; then
  ok "mutation proof: scanner FLAGS an absent target argument (bad-absent.sh)"
else
  bad "mutation proof: scanner MISSED an absent target argument (bad-absent.sh) — scanner is broken"
fi

GOOD1_OUT="$(scan_file "$FIXDIR/good-guarded.sh")"
if [ -z "$GOOD1_OUT" ]; then
  ok "mutation proof: scanner does NOT flag a properly guarded variable target (good-guarded.sh)"
else
  bad "mutation proof: scanner FALSE-POSITIVED on a guarded target (good-guarded.sh): $GOOD1_OUT"
fi

GOOD2_OUT="$(scan_file "$FIXDIR/good-literal.sh")"
if [ -z "$GOOD2_OUT" ]; then
  ok "mutation proof: scanner does NOT flag a literal path target (good-literal.sh)"
else
  bad "mutation proof: scanner FALSE-POSITIVED on a literal target (good-literal.sh): $GOOD2_OUT"
fi

echo ""
echo "repo-never-left-bare.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

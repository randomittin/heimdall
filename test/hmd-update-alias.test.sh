#!/usr/bin/env bash
# hmd-update-alias — a command hmd ADVERTISES must be a command hmd DISPATCHES.
#
# The bug this exists to prevent: the staleness notice told every user with an
# old version to run `hmd update`, but only `--update` was ever dispatched. The
# bare form fell through to the splash banner, which prints happily and exits 0
# — so the user saw a success-shaped screen and no update. A wrong instruction
# that LOOKS like it worked is worse than one that errors.
#
# Deliberately static. The update path runs `git pull` against the real
# checkout; a test must never execute it to find out whether it is reachable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HMD="$REPO/bin/heimdall"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }

# The dispatch guard for the update path, as one line of source.
dispatch_line() { grep -n '^if \[\[ "\${1:-}" == "--update"' "$HMD" | head -1; }

# ── 1. both forms are dispatched ────────────────────────────────────────────
line="$(dispatch_line)"
if [ -z "$line" ]; then
  bad "no update dispatch guard found at all"
else
  ok
  case "$line" in
    *'"--update"'*) ok ;;
    *) bad "--update is not in the dispatch guard" ;;
  esac
  case "$line" in
    *'== "update"'*) ok ;;
    *) bad "bare 'update' is not in the dispatch guard — the advertised form falls through to the banner" ;;
  esac
fi

# ── 2. drift guard: every advertised update form must be dispatched ─────────
# Pull the literal command out of any user-facing string that tells the user how
# to update, and require the dispatch guard to accept it. This is the assertion
# that would have caught the original bug the moment the notice was written.
advertised="$(grep -ohE '(hmd|heimdall) --?update' "$HMD" | awk '{print $2}' | sort -u)"
check "advertised update forms were found (an empty scan must not pass)" \
      "$([ -n "$advertised" ] && echo yes || echo no)" "yes"

while IFS= read -r form; do
  [ -n "$form" ] || continue
  case "$(dispatch_line)" in
    *"\"$form\""*) ok ;;
    *) bad "hmd advertises '$form' but does not dispatch it" ;;
  esac
done <<EOF
$advertised
EOF

# ── 3. the alias must not swallow an unrelated subcommand ───────────────────
# `hmd modules update` is a different command; the alias keys on $1 only, so
# confirm the guard is anchored to the first argument and not a loose match.
case "$(dispatch_line)" in
  *'${1:-}'*) ok ;;
  *) bad "update dispatch is not anchored to \$1 — it could swallow a subcommand" ;;
esac

printf '\n  %s%d passed, %d failed\033[0m\n' \
  "$([ "$FAIL" -eq 0 ] && printf '\033[32m' || printf '\033[31m')" \
  "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

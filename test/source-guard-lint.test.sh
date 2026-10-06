#!/usr/bin/env bash
# test/source-guard-lint.test.sh — regression lock for the WHOLE CLASS of the bug fixed
# in bin/heimdall-state by commit f4de34bf ("don't let a missing lib/hook-owned-path.sh
# sibling kill every subcommand").
#
# THE BUG CLASS
#   . "$path" 2>/dev/null || true        # (or: source "$path" ... || true)
# Under `set -e`, bash treats a `.`/`source` that cannot OPEN its target (a missing
# file) as a hard, immediate abort of the WHOLE SCRIPT — the trailing `|| true` never
# runs, because the failure happens at the dot-command's own file-open step, not at the
# "last command in an OR-list" step that -e's OR-list exemption covers.
#
# Two more shapes that LOOK like they should be exempt but are NOT (proved in §0 below
# — neither was in the original incident, and both are easy to reach for as a
# "safer-looking" rewrite, so this lint treats them as the same class):
#   - `if . "$path"; then ... fi`   — aborts before the if-condition is ever evaluated.
#   - `! . "$path"`                 — negation does not exempt it either.
#
# The ONLY safe shape is CHECK-THEN-SOURCE: never invoke `.`/`source` on a path unless
# its existence/readability was already confirmed on an earlier, SEPARATE statement, so
# the open-failure branch is never reached at all — e.g. f4de34bf's own fix:
#   if [ -r "$path" ]; then
#     . "$path"
#   fi
#
# WHAT THE FULL-TREE AUDIT BEHIND THIS FILE FOUND
#   Every shape of this bug (bare `|| true` / `|| :` / `|| exit N` / `|| { ...; }`,
#   if/while/until-conditional sourcing, and `!`-negated sourcing) was searched for
#   across bin/, hooks/, sentinels/, install.sh, and every hit was cross-checked
#   against (a) whether the file ever enables errexit before that line and (b) whether
#   a pre-existing same-path existence-check guard already wraps the site. Every
#   current site OTHER than the already-fixed bin/heimdall-state turned out safe for
#   one of those two independent reasons — see §1's named per-site assertions for the
#   receipts. Nothing in the current tree needed a code change; this file is the
#   mechanical proof of that claim, kept alive as a forward-looking regression lock so
#   a FUTURE unguarded dot-source in an errexit script fails loudly, naming file:line.
#
# SECTIONS
#   §0 bash semantics this whole lint depends on, proved fresh (not assumed)
#   §1 real-tree scan: named assertions for every known site + a zero-AFFECTED gate
#   §2 positive control — a deliberately bad fixture MUST be caught (falsifiability)
#   §3 negative controls — a properly-guarded fixture and a no-errexit fixture must NOT
#      be flagged (a scanner that flags everything is not a scanner)
#   §4 heimdall-dream-schedule repro: a synthetic naive-shape "before" (lib hidden)
#      crashes; the REAL, unmodified file's pre-existing guard "after" (libs hidden)
#      degrades gracefully
#   §5 bash -n smoke on every file this investigation touched
#
# SCOPE NOTE: this scans real bash SCRIPT files (`.sh`, or extensionless with a bash/sh
# shebang) under bin/, hooks/, sentinels/, install.sh — matching the tree named in the
# task's own full-scan command. hooks/hooks.json's embedded one-liners were checked by
# hand instead (they use the safe `[ -r ] && . ... &&` shape and carry no `set -e` of
# their own), so they are out of this scanner's blast radius by construction.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf "        %s\n" "$2"; }

WORK="$(mktemp -d -t "source-guard-lint.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf '\nsource-guard-lint — locks the bin/heimdall-state (f4de34bf) bug class tree-wide\n'
printf -- '--------------------------------------------------------------------------------\n'

# ── the scanner ───────────────────────────────────────────────────────────────────
# scan_one_file <path> — prints one "STATUS path:line [shape] path=EXPR" line per hit.
#   AFFECTED — errexit-active AND unguarded: the live bug.
#   GUARDED  — a pre-existing same-path `if [ -r/-f/-x EXPR ]; then` precedes it within
#              6 lines (skipping blank/comment lines) — the safe, already-fixed shape.
#   NOT-AFF  — the file never enables errexit before this line, so plain bash dot-source
#              semantics apply and a trailing `||`/if/negation works normally (§0).
scan_one_file() {
  awk '
    {
      lines[NR] = $0
      if ($0 ~ /^[ \t]*set[ \t]+-[a-zA-Z]*e[a-zA-Z]*([ \t]|$)/ || $0 ~ /^[ \t]*set[ \t]+-o[ \t]+errexit/) {
        errexit = 1
      }
      shape = ""
      if ($0 ~ /^[ \t]*(\.|source)[ \t]+[^ \t].*\|\|/) shape = "dot-source-or-fallback"
      else if ($0 ~ /(^|[ \t])(if|while|until)[ \t]+!?[ \t]*(\.|source)[ \t]+[^=|\t ]/) shape = "conditional-dot-source"
      else if ($0 ~ /^[ \t]*![ \t]*(\.|source)[ \t]+[^ \t]/) shape = "negated-dot-source"
      if (shape == "") next

      p = $0
      sub(/^[ \t]*(if|while|until)[ \t]+/, "", p)
      sub(/^[ \t]*![ \t]*/, "", p)
      sub(/^[ \t]*(\.|source)[ \t]+/, "", p)
      split(p, arr, /[ \t]/)
      pathexpr = arr[1]

      guarded = 0
      back = NR - 1
      skipped = 0
      while (back >= 1 && skipped < 6) {
        bline = lines[back]
        if (bline ~ /^[ \t]*(#.*)?$/) { back--; skipped++; continue }
        if (bline ~ /if[ \t]*\[[ \t]+-[a-zA-Z][ \t]+/ && index(bline, pathexpr) > 0 && bline ~ /then/) {
          guarded = 1
        }
        break
      }

      status = "AFFECTED"
      if (guarded == 1) status = "GUARDED"
      else if (errexit != 1) status = "NOT-AFF"
      printf "%s %s:%d [%s] path=%s\n", status, FILENAME, NR, shape, pathexpr
    }
  ' "$1"
}

# discover_bash_files <dir-or-file>... — every real bash script under the given roots:
# .sh extension, or extensionless-with-a-bash/sh shebang. Deliberately excludes .py/
# .json/.md/etc.
discover_bash_files() {
  local root f first
  for root in "$@"; do
    if [ -f "$root" ]; then
      printf '%s\n' "$root"
      continue
    fi
    [ -d "$root" ] || continue
    find "$root" -type f 2>/dev/null
  done | while IFS= read -r f; do
    case "$f" in
      *.py|*.json|*.md|*.tsv|*.conf|*.ndjson|*.pub|*.txt|*.plist) continue ;;
    esac
    case "$f" in
      *.sh) printf '%s\n' "$f"; continue ;;
    esac
    [ -r "$f" ] || continue
    first="$(head -1 "$f" 2>/dev/null)"
    case "$first" in
      '#!'*bash*|'#!'*/sh|'#!'*env*' sh'*) printf '%s\n' "$f" ;;
    esac
  done
}

# ── §0: semantics proof — the claims this whole lint depends on ──────────────────
printf '\n%%0 -- bash semantics this lint depends on (proved fresh, not assumed)\n'

MISSING="/nonexistent/hopefully-never-exists-$$"

r1="$(bash -c 'set -e; . '"$MISSING"' 2>/dev/null || true; echo REACHED' 2>/dev/null)"
if [ "$r1" != "REACHED" ]; then ok "set -e: dot-source of a missing file aborts through the trailing OR-fallback"
else bad "set -e: dot-source of a missing file aborts through the trailing OR-fallback" "got: [$r1]"; fi

r2="$(bash -c 'set -e; if . '"$MISSING"' 2>/dev/null; then :; fi; echo REACHED' 2>/dev/null)"
if [ "$r2" != "REACHED" ]; then ok "set -e: dot-source used as an if-CONDITION also aborts (not exempt)"
else bad "set -e: dot-source used as an if-CONDITION also aborts (not exempt)" "got: [$r2]"; fi

r3="$(bash -c 'set -e; ! . '"$MISSING"' 2>/dev/null; echo REACHED' 2>/dev/null)"
if [ "$r3" != "REACHED" ]; then ok "set -e: negated dot-source (! . path) also aborts (not exempt)"
else bad "set -e: negated dot-source (! . path) also aborts (not exempt)" "got: [$r3]"; fi

expect4="CAUGHT
REACHED"
r4="$(bash -c '. '"$MISSING"' 2>/dev/null || echo CAUGHT; echo REACHED' 2>/dev/null)"
if [ "$r4" = "$expect4" ]; then ok "WITHOUT set -e: the identical line is a normal, catchable failure"
else bad "WITHOUT set -e: the identical line is a normal, catchable failure" "got: [$r4]"; fi

r5="$(bash -c 'set -e; [ -r '"$MISSING"' ] && . '"$MISSING"'; echo REACHED' 2>/dev/null)"
if [ "$r5" = "REACHED" ]; then ok "set -e: check-then-source (the f4de34bf shape) never invokes . on a missing path"
else bad "set -e: check-then-source (the f4de34bf shape) never invokes . on a missing path" "got: [$r5]"; fi

# ── §1: real-tree scan ────────────────────────────────────────────────────────────
printf '\n%%1 -- real-tree scan (bin/, hooks/, sentinels/, install.sh)\n'

TREE_OUT="$WORK/tree-scan.out"
: > "$TREE_OUT"
while IFS= read -r f; do
  scan_one_file "$f" >> "$TREE_OUT"
done < <(discover_bash_files "$ROOT/bin" "$ROOT/hooks" "$ROOT/sentinels" "$ROOT/install.sh")

total_hits="$(wc -l < "$TREE_OUT" | tr -d ' ')"
if [ "$total_hits" -ge 14 ]; then
  ok "scanner found at least the 14 known candidate sites ($total_hits total) — discovery didn't silently regress to scanning nothing"
else
  bad "scanner found at least the 14 known candidate sites" "only found $total_hits — discover_bash_files or the shape regexes may have regressed"
fi

# Named per-site assertions — the durable receipt for each site this task's
# investigation classified, so a future edit that changes any of these sites' safety
# is caught by name, not just by an aggregate count.
#
# Pins are file:LINE. A `got: [<not found>]` failure means the site MOVED (an edit above
# it shifted the line) — it does NOT mean the site regressed. Run scan_one_file on that
# file, confirm the same path= expression still carries the same status, then re-pin.
# A status that CHANGED (GUARDED/NOT-AFF -> AFFECTED) is the real regression this lint
# exists to catch.
assert_site() {
  local want="$1" relpath="$2" line="$3"
  local got
  got="$(grep -F "$ROOT/$relpath:$line " "$TREE_OUT" | awk '{print $1}' | head -1)"
  if [ "$got" = "$want" ]; then
    ok "$relpath:$line is $want"
  else
    bad "$relpath:$line is $want" "got: [${got:-<not found>}]"
  fi
}

# GUARDED — already wrapped in a pre-existing if [ -r/-f ]; then ... fi (present since
# commit cde9fb64 / 8d729ea3, 2026-08-05 — weeks before this task existed).
assert_site GUARDED bin/heimdall-dream-schedule 70
assert_site GUARDED bin/heimdall-dream-schedule 83
assert_site GUARDED bin/heimdall-dream-permission 109
assert_site GUARDED bin/heimdall-dream-permission 113
assert_site GUARDED bin/heimdall-dream-notice 40
assert_site GUARDED bin/heimdall-dream-notice 44
assert_site GUARDED bin/heimdall 45
assert_site GUARDED bin/heimdall 55

# NOT-AFF — the containing file never enables errexit (confirmed: only `set -uo
# pipefail` / `set -u`), so §0's hazard never applies here regardless of shape; two of
# these three sites are ALSO pre-guarded by an early `[ -f ] || return 1`/`return 0`.
assert_site NOT-AFF bin/heimdall-modules 1898
assert_site NOT-AFF bin/heimdall-autoupdate 837
assert_site NOT-AFF bin/heimdall-autoupdate 884
assert_site NOT-AFF bin/lib/hmd-route-claude 52
assert_site NOT-AFF bin/lib/hmd-route-claude 81
assert_site NOT-AFF bin/lib/hmd-route-claude 101

# The actual regression lock: zero AFFECTED anywhere in the tree, named if that ever
# stops being true.
affected_count="$(awk '$1=="AFFECTED"{print}' "$TREE_OUT" | wc -l | tr -d ' ')"
if [ "$affected_count" = "0" ]; then
  ok "zero AFFECTED sites tree-wide"
else
  bad "zero AFFECTED sites tree-wide" "$(awk '$1=="AFFECTED"{print}' "$TREE_OUT")"
fi

# ── §2: positive control — the scanner MUST catch a deliberately bad fixture ──────
printf '\n%%2 -- positive control (falsifiability: a bad fixture must be caught)\n'

BAD="$WORK/bad-fixture.sh"
cat > "$BAD" <<EOF
#!/usr/bin/env bash
set -euo pipefail
X="$WORK/no-such-lib.sh"
. "\$X" 2>/dev/null || true
echo done
EOF
bad_out="$(scan_one_file "$BAD")"
if printf '%s' "$bad_out" | grep -q "^AFFECTED $BAD:4"; then
  ok "positive control: naive unguarded dot-source under set -e is flagged AFFECTED"
else
  bad "positive control: naive unguarded dot-source under set -e is flagged AFFECTED" "got: [$bad_out]"
fi

# Prove the bug the positive control's SHAPE actually has, live (not just statically
# flagged) — running it crashes before "done" prints.
bad_run_out="$(bash "$BAD" 2>/dev/null)"; bad_run_rc=$?
if [ "$bad_run_rc" != 0 ] && [ "$bad_run_out" != "done" ]; then
  ok "positive control fixture actually crashes when run (proves the flag isn't cosmetic)"
else
  bad "positive control fixture actually crashes when run" "rc=$bad_run_rc out=[$bad_run_out]"
fi

# ── §3: negative controls — must NOT be flagged AFFECTED ──────────────────────────
printf '\n%%3 -- negative controls (a scanner that flags everything is not a scanner)\n'

GOOD_GUARDED="$WORK/good-guarded.sh"
cat > "$GOOD_GUARDED" <<EOF
#!/usr/bin/env bash
set -euo pipefail
X="$WORK/no-such-lib.sh"
if [ -r "\$X" ]; then
  # shellcheck disable=SC1091
  . "\$X" 2>/dev/null || true
fi
echo done
EOF
good_guarded_out="$(scan_one_file "$GOOD_GUARDED")"
if printf '%s' "$good_guarded_out" | grep -q "^GUARDED "; then
  ok "negative control: check-then-source shape is classified GUARDED, not AFFECTED"
else
  bad "negative control: check-then-source shape is classified GUARDED, not AFFECTED" "got: [$good_guarded_out]"
fi
guarded_run_out="$(bash "$GOOD_GUARDED" 2>&1)"; guarded_run_rc=$?
if [ "$guarded_run_rc" = 0 ] && [ "$guarded_run_out" = "done" ]; then
  ok "negative control fixture actually runs to completion (proves GUARDED is truthful, not just unflagged)"
else
  bad "negative control fixture actually runs to completion" "rc=$guarded_run_rc out=[$guarded_run_out]"
fi

GOOD_NOERREXIT="$WORK/good-noerrexit.sh"
cat > "$GOOD_NOERREXIT" <<EOF
#!/usr/bin/env bash
set -uo pipefail
X="$WORK/no-such-lib.sh"
. "\$X" 2>/dev/null || true
echo done
EOF
good_noerrexit_out="$(scan_one_file "$GOOD_NOERREXIT")"
if printf '%s' "$good_noerrexit_out" | grep -q "^NOT-AFF "; then
  ok "negative control: identical bare shape with no errexit is classified NOT-AFF"
else
  bad "negative control: identical bare shape with no errexit is classified NOT-AFF" "got: [$good_noerrexit_out]"
fi

# ── §4: heimdall-dream-schedule-specific repro ────────────────────────────────────
printf '\n%%4 -- heimdall-dream-schedule: latent-bug repro (before) vs the real file (after)\n'

# BEFORE: a synthetic script using dream-schedule's own real BINDIR-relative lib
# resolution idiom and lib name, but with the guard stripped down to the NAIVE bare
# shape (exactly what heimdall-state had pre-f4de34bf, and what dream-schedule would
# look like WITHOUT its actual, pre-existing `if [ -r ]` guard). Lib hidden.
BEFORE_DIR="$WORK/before/bin"
mkdir -p "$BEFORE_DIR"
BEFORE_SCRIPT="$BEFORE_DIR/naive-dream-schedule-shape.sh"
cat > "$BEFORE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BINDIR="$(cd "$(dirname "$0")" && pwd)"
# deliberately NAIVE: no existence check first (the class of bug, reproduced with this
# file's own real lib name/path shape) — bin/lib/real-home.sh is NOT copied alongside
# this script, simulating the "missing sibling" incident.
. "$BINDIR/lib/real-home.sh" 2>/dev/null || true
echo "REACHED-END"
EOF
chmod +x "$BEFORE_SCRIPT"
# lib/ deliberately not created at all under $BEFORE_DIR — the lib is hidden.
before_out="$("$BEFORE_SCRIPT" 2>/dev/null)"; before_rc=$?
if [ "$before_rc" != 0 ] && [ "$before_out" != "REACHED-END" ]; then
  ok "BEFORE (naive shape, lib hidden): crashes before REACHED-END, exactly like pre-fix heimdall-state"
else
  bad "BEFORE (naive shape, lib hidden): crashes before REACHED-END" "rc=$before_rc out=[$before_out]"
fi

# AFTER: the REAL, UNMODIFIED bin/heimdall-dream-schedule, copied into a fixture bin/
# with NEITHER lib/real-home.sh NOR lib/tcc-paths.sh present (both hidden) — status is
# read-only and launchctl is shimmed, mirroring test/heimdall-dream-schedule.test.sh's
# own hermetic harness convention.
AFTER_DIR="$WORK/after/bin"
mkdir -p "$AFTER_DIR"
cp "$ROOT/bin/heimdall-dream-schedule" "$AFTER_DIR/heimdall-dream-schedule"
chmod +x "$AFTER_DIR/heimdall-dream-schedule"
# lib/ deliberately not created here either.

FAKE_LAUNCHCTL="$WORK/fake-launchctl"
cat > "$FAKE_LAUNCHCTL" <<'EOF'
#!/usr/bin/env bash
# Minimal read-only shim: nothing is ever installed in this fixture, so every query
# truthfully reports "not found / not loaded".
exit 1
EOF
chmod +x "$FAKE_LAUNCHCTL"

after_out="$(
  HEIMDALL_LAUNCH_AGENTS_DIR="$WORK/after-home/LaunchAgents" \
  HEIMDALL_HOME="$WORK/after-home" \
  HEIMDALL_DREAM_LOG="$WORK/after-home/logs/dream.log" \
  LAUNCHCTL="$FAKE_LAUNCHCTL" \
  "$AFTER_DIR/heimdall-dream-schedule" status 2>&1
)"; after_rc=$?
if [ "$after_rc" = 0 ] && printf '%s' "$after_out" | grep -q 'not installed'; then
  ok "AFTER (real, unmodified heimdall-dream-schedule, both libs hidden): status degrades gracefully via its pre-existing guard"
else
  bad "AFTER (real, unmodified heimdall-dream-schedule, both libs hidden): status degrades gracefully" "rc=$after_rc out=[$after_out]"
fi

# ── §5: bash -n smoke on every file this investigation touched ───────────────────
printf '\n%%5 -- bash -n smoke (none of these were modified; proves this investigation left them intact)\n'

SMOKE_FILES="bin/heimdall-dream-schedule bin/heimdall-dream-permission bin/heimdall-dream-notice bin/heimdall bin/heimdall-modules bin/heimdall-autoupdate bin/lib/hmd-route-claude"
for rel in $SMOKE_FILES; do
  if bash -n "$ROOT/$rel" 2>/dev/null; then
    ok "bash -n $rel"
  else
    bad "bash -n $rel" "$(bash -n "$ROOT/$rel" 2>&1)"
  fi
done

printf -- '\n--------------------------------------------------------------------------------\n'
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

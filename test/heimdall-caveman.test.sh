#!/usr/bin/env bash
# test/heimdall-caveman.test.sh
#
# Verifies bin/heimdall-caveman: hmd's own owner of the output-compression
# LEVEL (lite|full|ultra) and its per-level rule text, replacing a hard
# dependency on the external caveman plugin (delta-brief
# brief-1788088676-56663). Hermetic throughout: every invocation pins both
# HEIMDALL_HOME and CLAUDE_CONFIG_DIR to a fresh $TMPDIR subdirectory, so the
# real ~/.heimdall/caveman-level and ~/.claude/.caveman-active are never
# touched — same convention as test/caveman-level-claim.test.sh's run_at().

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-caveman"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Real files this suite must never touch — snapshot mtime (or absence) before
# running anything, re-checked at the very end.
REAL_HMD_HOME="${HOME:-/nonexistent}/.heimdall/caveman-level"
REAL_PLUGIN_FLAG="${HOME:-/nonexistent}/.claude/.caveman-active"
real_stamp() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo "absent"; }
BEFORE_HMD_HOME="$(real_stamp "$REAL_HMD_HOME")"
BEFORE_PLUGIN_FLAG="$(real_stamp "$REAL_PLUGIN_FLAG")"

echo "heimdall-caveman test harness  repo=$ROOT"
echo "--------------------------------------------------------------------"

[ -x "$TOOL" ] && ok "bin/heimdall-caveman is executable" \
  || bad "bin/heimdall-caveman missing or not executable"

# fresh() gives each case its own sandboxed HEIMDALL_HOME + CLAUDE_CONFIG_DIR,
# both under $TMPDIR, and nothing else — this is what keeps the suite
# hermetic against the real files. Uses mktemp -d directly rather than a
# hand-rolled counter: fresh() is always called as `D="$(fresh)"`, and command
# substitution forks a subshell, so a counter variable incremented INSIDE the
# function would be a no-op on the parent shell's copy — every call would
# silently recompute the same directory name instead of a new one. mktemp
# sidesteps that whole class of bug by not needing any shared state at all.
fresh() {
  local d
  d="$(mktemp -d "$TMPDIR/case.XXXXXX")"
  mkdir -p "$d/home" "$d/claude"
  printf '%s\n' "$d"
}

run() {
  local d="$1"; shift
  HEIMDALL_HOME="$d/home" CLAUDE_CONFIG_DIR="$d/claude" "$TOOL" "$@"
}

# ── fresh state: no hmd file, no plugin flag ──
D="$(fresh)"
out="$(run "$D" get)"; rc=$?
[ "$rc" -eq 0 ] && ok "get on totally fresh state exits 0 (rc=$rc)" || bad "get on totally fresh state exits 0 (rc=$rc)"
[ "$out" = "full" ] && ok "fresh state falls back to documented default 'full' (got '$out')" || bad "fresh state falls back to 'full' (got '$out')"

# ── set/get round-trip, all three owned levels ──
for lvl in lite full ultra; do
  D="$(fresh)"
  run "$D" set "$lvl" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || bad "set $lvl exits 0 (rc=$rc)"
  out="$(run "$D" get)"
  [ "$out" = "$lvl" ] && ok "set $lvl then get round-trips to $lvl" || bad "set $lvl then get round-trips to $lvl (got '$out')"
done

# ── invalid set: rejected, does not corrupt existing state ──
D="$(fresh)"
run "$D" set full >/dev/null 2>&1
run "$D" set bogus >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "set bogus exits non-zero (rc=$rc)" || bad "set bogus exits non-zero (rc=$rc)"
out="$(run "$D" get)"
[ "$out" = "full" ] && ok "set bogus does not corrupt prior valid state (still 'full', got '$out')" || bad "set bogus left state at '$out', expected 'full' preserved"

# ── set with no argument: caller error, non-zero, no crash ──
D="$(fresh)"
run "$D" set >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "set with no argument exits non-zero (rc=$rc)" || bad "set with no argument exits non-zero (rc=$rc)"

# ── corrupt state file: falls back safely, never crashes ──
D="$(fresh)"
mkdir -p "$D/home"
printf 'MAXIMUM; rm -rf /\n' > "$D/home/caveman-level"
out="$(run "$D" get)"; rc=$?
[ "$rc" -eq 0 ] && ok "corrupt state file: get still exits 0 (rc=$rc)" || bad "corrupt state file: get still exits 0 (rc=$rc)"
[ "$out" = "full" ] && ok "corrupt state file falls back to 'full' (got '$out')" || bad "corrupt state file falls back to 'full' (got '$out')"
case "$out" in
  *MAXIMUM*) bad "corrupt value was parroted back instead of falling back" ;;
  *) ok "corrupt value is not parroted back" ;;
esac

# ── rules: each level emits DIFFERENT text (red-proof, not just non-crash) ──
D="$(fresh)"
lite_out="$(run "$D" rules lite)"
full_out="$(run "$D" rules full)"
ultra_out="$(run "$D" rules ultra)"
[ -n "$lite_out" ] && ok "rules lite produces non-empty output" || bad "rules lite produced empty output"
[ -n "$full_out" ] && ok "rules full produces non-empty output" || bad "rules full produced empty output"
[ -n "$ultra_out" ] && ok "rules ultra produces non-empty output" || bad "rules ultra produced empty output"
[ "$lite_out" != "$full_out" ] && ok "lite rule text != full rule text" || bad "lite rule text == full rule text (must differ)"
[ "$full_out" != "$ultra_out" ] && ok "full rule text != ultra rule text (proves ultra distinct from full)" || bad "full rule text == ultra rule text (must differ)"
[ "$lite_out" != "$ultra_out" ] && ok "lite rule text != ultra rule text" || bad "lite rule text == ultra rule text (must differ)"

# lite must actually say to KEEP articles (the disclosed fix over the
# source's self-contradictory blanket "Drop: articles") — not just be
# textually different from full/ultra for unrelated reasons.
case "$lite_out" in
  *"Keep articles"*) ok "lite rule text explicitly keeps articles" ;;
  *) bad "lite rule text does not mention keeping articles: $lite_out" ;;
esac
case "$full_out" in
  *"Drop: articles"*) ok "full rule text drops articles" ;;
  *) bad "full rule text does not drop articles" ;;
esac
case "$ultra_out" in
  *"Abbreviate"*) ok "ultra rule text mentions abbreviation" ;;
  *) bad "ultra rule text does not mention abbreviation" ;;
esac

# ── rules with no argument uses the CURRENT level (via get) ──
D="$(fresh)"
run "$D" set ultra >/dev/null 2>&1
default_rules_out="$(run "$D" rules)"
explicit_ultra_out="$(run "$D" rules ultra)"
[ "$default_rules_out" = "$explicit_ultra_out" ] && ok "rules with no arg matches rules for the current (set) level" \
  || bad "rules with no arg does not match rules ultra after set ultra"

# ── rules with an invalid explicit level: caller error ──
D="$(fresh)"
run "$D" rules nonsense >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "rules nonsense exits non-zero (rc=$rc)" || bad "rules nonsense exits non-zero (rc=$rc)"

# ── migration: plugin flag seeds hmd's state exactly once ──
D="$(fresh)"
printf 'ultra\n' > "$D/claude/.caveman-active"
out="$(run "$D" get)"
[ "$out" = "ultra" ] && ok "migration: plugin flag 'ultra' is adopted on first get" || bad "migration: expected 'ultra' from plugin flag, got '$out'"
[ -f "$D/home/caveman-level" ] && ok "migration seeds hmd's own state file" || bad "migration did not create hmd's own state file"
# Change the plugin flag AFTER migration — hmd must not look at it again.
printf 'lite\n' > "$D/claude/.caveman-active"
out2="$(run "$D" get)"
[ "$out2" = "ultra" ] && ok "migration is one-time: later plugin-flag edits are ignored (still 'ultra', got '$out2')" \
  || bad "migration re-read the plugin flag after the first seed (got '$out2', expected 'ultra')"

# ── migration skip: out-of-scope plugin mode is never adopted ──
D="$(fresh)"
printf 'wenyan-full\n' > "$D/claude/.caveman-active"
out="$(run "$D" get)"; rc=$?
[ "$rc" -eq 0 ] && ok "migration skip (wenyan-full): get still exits 0 (rc=$rc)" || bad "migration skip (wenyan-full): get still exits 0 (rc=$rc)"
[ "$out" = "full" ] && ok "out-of-scope plugin mode 'wenyan-full' is not adopted (falls back to 'full', got '$out')" \
  || bad "out-of-scope plugin mode was adopted or fallback broke (got '$out')"

# ── migration skip: 'off' is never adopted either ──
D="$(fresh)"
printf 'off\n' > "$D/claude/.caveman-active"
out="$(run "$D" get)"
[ "$out" = "full" ] && ok "plugin mode 'off' is not adopted (falls back to 'full', got '$out')" \
  || bad "plugin mode 'off' was adopted or fallback broke (got '$out')"

# ── no plugin flag at all: get still succeeds (already covered above, but
# explicitly re-asserted here alongside the migration cases for locality) ──
D="$(fresh)"
rm -f "$D/claude/.caveman-active" 2>/dev/null
out="$(run "$D" get)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "full" ] && ok "no plugin flag present: get exits 0 and defaults to full" \
  || bad "no plugin flag present: get did not cleanly default (rc=$rc, out='$out')"

# ── symlink refusal on write (security carve-out, not gold-plating) ──
D="$(fresh)"
OUTSIDE="$(mktemp "$TMPDIR/outside-secret.XXXXXX")"
printf 'do-not-touch\n' > "$OUTSIDE"
ln -s "$OUTSIDE" "$D/home/caveman-level"
run "$D" set ultra >/dev/null 2>&1
outside_after="$(cat "$OUTSIDE" 2>/dev/null || true)"
[ "$outside_after" = "do-not-touch" ] && ok "set refuses to write through a symlinked state file (outside target untouched)" \
  || bad "set followed a symlink and clobbered an unrelated file: '$outside_after'"

# ── hooks-json: non-empty, mentions both hook events ──
D="$(fresh)"
hj_out="$(run "$D" hooks-json)"
[ -n "$hj_out" ] && ok "hooks-json produces non-empty output" || bad "hooks-json produced empty output"
case "$hj_out" in
  *SessionStart*) ok "hooks-json mentions SessionStart" ;;
  *) bad "hooks-json does not mention SessionStart" ;;
esac
case "$hj_out" in
  *UserPromptSubmit*) ok "hooks-json mentions UserPromptSubmit" ;;
  *) bad "hooks-json does not mention UserPromptSubmit" ;;
esac

# ── path: matches the documented storage location exactly ──
D="$(fresh)"
path_out="$(run "$D" path)"
[ "$path_out" = "$D/home/caveman-level" ] && ok "path prints \$HEIMDALL_HOME/caveman-level exactly" \
  || bad "path printed '$path_out', expected '$D/home/caveman-level'"

# ── help / usage ──
D="$(fresh)"
help_out="$(run "$D" --help)"; rc=$?
[ "$rc" -eq 0 ] && ok "--help exits 0" || bad "--help exits 0 (rc=$rc)"
for word in get set rules hooks-json path; do
  case "$help_out" in
    *"$word"*) ok "--help mentions '$word'" ;;
    *) bad "--help does not mention '$word'" ;;
  esac
done

# ── no-args invocation: caller error, non-zero ──
D="$(fresh)"
run "$D" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "no-args invocation exits non-zero (rc=$rc)" || bad "no-args invocation exits non-zero (rc=$rc)"

# ── unknown command: caller error, non-zero ──
D="$(fresh)"
run "$D" bogus-command >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "unknown command exits non-zero (rc=$rc)" || bad "unknown command exits non-zero (rc=$rc)"

# ── hermeticity: the real files were never touched by this entire suite ──
AFTER_HMD_HOME="$(real_stamp "$REAL_HMD_HOME")"
AFTER_PLUGIN_FLAG="$(real_stamp "$REAL_PLUGIN_FLAG")"
[ "$BEFORE_HMD_HOME" = "$AFTER_HMD_HOME" ] && ok "real \$HOME/.heimdall/caveman-level untouched by this suite" \
  || bad "real \$HOME/.heimdall/caveman-level changed during this suite ($BEFORE_HMD_HOME -> $AFTER_HMD_HOME)"
[ "$BEFORE_PLUGIN_FLAG" = "$AFTER_PLUGIN_FLAG" ] && ok "real \$HOME/.claude/.caveman-active untouched by this suite" \
  || bad "real \$HOME/.claude/.caveman-active changed during this suite ($BEFORE_PLUGIN_FLAG -> $AFTER_PLUGIN_FLAG)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

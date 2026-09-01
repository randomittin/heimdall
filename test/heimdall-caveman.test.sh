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
# Also covers a regression the owner observed first-hand mid-build: the
# plugin silently rewrites its OWN flag file back to its default on session
# restart, so hmd's resolved level (and a stderr divergence warning when the
# two disagree) must survive that -- see "restart-survival" below.
#
# 2026-09-01: hmd collapsed to a single settable level, ultra -- see
# bin/heimdall-caveman's own "SCOPE" header for the full rationale and the
# accept-and-map design for a stored/requested legacy lite/full value. This
# suite's set/get and migration cases below were updated for that; the
# per-level RULE TEXT cases (lite/full/ultra all still directly renderable
# by explicit `rules <lvl>`, for heimdall-caveman-eval's committed
# comparison) were not, because that surface did not change.

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
[ "$out" = "ultra" ] && ok "fresh state falls back to documented default 'ultra' (got '$out')" || bad "fresh state falls back to 'ultra' (got '$out')"

# ── set/get: ultra round-trips to itself; retired lite/full MAP FORWARD to
# ultra rather than erroring or wedging (see bin/heimdall-caveman "SCOPE") ──
D="$(fresh)"
run "$D" set ultra >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || bad "set ultra exits 0 (rc=$rc)"
out="$(run "$D" get)"
[ "$out" = "ultra" ] && ok "set ultra then get round-trips to ultra" || bad "set ultra then get round-trips to ultra (got '$out')"

for lvl in lite full; do
  D="$(fresh)"
  set_err="$(run "$D" set "$lvl" 2>&1 1>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && ok "set $lvl (retired) still exits 0 -- accept-and-map, never a hard error (rc=$rc)" \
    || bad "set $lvl (retired) exits 0 (rc=$rc)"
  out="$(run "$D" get)"
  [ "$out" = "ultra" ] && ok "set $lvl maps forward to ultra (got '$out')" \
    || bad "set $lvl did not map forward to ultra (got '$out') -- a stored legacy value must never wedge or silently emit nothing"
  case "$set_err" in
    *"retired"*"ultra"*) ok "set $lvl prints a retirement notice on stderr naming ultra" ;;
    *) bad "set $lvl gave no retirement notice on stderr: $set_err" ;;
  esac
done

# ── invalid set: rejected, does not corrupt existing state ──
D="$(fresh)"
run "$D" set full >/dev/null 2>&1
run "$D" set bogus >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "set bogus exits non-zero (rc=$rc)" || bad "set bogus exits non-zero (rc=$rc)"
out="$(run "$D" get)"
[ "$out" = "ultra" ] && ok "set bogus does not corrupt prior valid state (still 'ultra' via legacy 'full' mapping, got '$out')" \
  || bad "set bogus left state at '$out', expected 'ultra' preserved"

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
[ "$out" = "ultra" ] && ok "corrupt state file falls back to 'ultra' (got '$out')" || bad "corrupt state file falls back to 'ultra' (got '$out')"
case "$out" in
  *MAXIMUM*) bad "corrupt value was parroted back instead of falling back" ;;
  *) ok "corrupt value is not parroted back" ;;
esac

# ── HIGHEST-RISK CASE: a value written by a PRE-COLLAPSE hmd binary (literal
# 'lite'/'full' bytes already sitting in $HEIMDALL_HOME/caveman-level, never
# touched by today's `set` mapping at all -- this is NOT the same code path
# as "set lite" below) must still resolve to real, non-empty ultra output --
# never wedge, never silently emit nothing. This is the one requirement this
# whole collapse cannot fail on. ──
for legacy in lite full; do
  D="$(fresh)"
  mkdir -p "$D/home"
  printf '%s\n' "$legacy" > "$D/home/caveman-level"
  out="$(run "$D" get)"; rc=$?
  [ "$rc" -eq 0 ] && ok "pre-collapse stored '$legacy': get still exits 0 (rc=$rc)" \
    || bad "pre-collapse stored '$legacy': get exits 0 (rc=$rc)"
  [ "$out" = "ultra" ] && ok "pre-collapse stored '$legacy' resolves forward to 'ultra' (got '$out')" \
    || bad "pre-collapse stored '$legacy' did not resolve to 'ultra' (got '$out') -- must never wedge or emit nothing"
  rules_out="$(run "$D" rules)"
  byte_count="${#rules_out}"
  [ "$byte_count" -gt 0 ] && ok "pre-collapse stored '$legacy': rules still emits real, non-empty text ($byte_count bytes)" \
    || bad "pre-collapse stored '$legacy': rules emitted nothing"
  case "$rules_out" in
    *"level: ultra"*) ok "pre-collapse stored '$legacy': rules header honestly reports 'ultra', not the stale stored value" ;;
    *) bad "pre-collapse stored '$legacy': rules header did not report 'ultra': $rules_out" ;;
  esac
done

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

# 2026-09-01 fix: n=30 real-eval text diffing (evals/caveman/) found hmd's
# actual token-spend mechanism vs upstream_skill was volunteering content
# nobody asked for (extra examples, product names, failure-mode asides, code
# samples) -- not phrasing. Each level got a scope-discipline sentence for
# this; pin it so a future edit can't silently drop the fix this suite exists
# to protect.
case "$lite_out" in
  *"skip extra examples, product names, failure-mode asides, or code samples the question did not request"*) ok "lite rule text forbids volunteering unrequested extras" ;;
  *) bad "lite rule text does not forbid volunteering unrequested extras: $lite_out" ;;
esac
case "$full_out" in
  *"skip extra examples, product names, failure-mode asides, or code samples not requested"*) ok "full rule text forbids volunteering unrequested extras" ;;
  *) bad "full rule text does not forbid volunteering unrequested extras: $full_out" ;;
esac
case "$ultra_out" in
  *"skip unrequested examples/names/failure-mode asides/code samples"*) ok "ultra rule text forbids volunteering unrequested extras" ;;
  *) bad "ultra rule text does not forbid volunteering unrequested extras: $ultra_out" ;;
esac

# 2026-09-01 ultra-parity fix: n=30 real-eval structural diffing
# (docs/analysis/2026-09-01-caveman-ultra-parity-research.md) found
# hmd_ultra's remaining token deficit vs upstream_skill was concentrated in
# 3/30 "how does X work / steps to" prompts that broke into markdown headers
# plus a per-item worked example instead of staying in flat fragment style
# (measured: 0.57 headers/response for hmd_ultra vs 0.13 for upstream_skill;
# one prompt alone was 38% of the net 30-prompt token deficit). Pin every
# new clause so a future edit can't silently drop this fix, same discipline
# as the scope-discipline pin directly above.
case "$ultra_out" in
  *"Shortest correct answer wins"*) ok "ultra rule text states the shortest-correct-answer objective" ;;
  *) bad "ultra rule text does not state the shortest-correct-answer objective: $ultra_out" ;;
esac
case "$ultra_out" in
  *"flat fragments only, never a sectioned doc"*) ok "ultra rule text bans headers in answers" ;;
  *) bad "ultra rule text does not ban headers in answers: $ultra_out" ;;
esac
case "$ultra_out" in
  *"no per-item header, no per-item example"*) ok "ultra rule text bans per-item headers/examples on multi-cause answers" ;;
  *) bad "ultra rule text does not ban per-item headers/examples on multi-cause answers: $ultra_out" ;;
esac
case "$ultra_out" in
  *"Never narrate your own formatting"*) ok "ultra rule text bans self-referential formatting narration" ;;
  *) bad "ultra rule text does not ban self-referential formatting narration: $ultra_out" ;;
esac
case "$ultra_out" in
  *"never restate the opening in different words"*) ok "ultra rule text bans redundant closing recaps" ;;
  *) bad "ultra rule text does not ban redundant closing recaps: $ultra_out" ;;
esac
case "$ultra_out" in
  *"Yes (multi-cause, flat)"*) ok "ultra rule text has the new multi-cause flat contrastive example" ;;
  *) bad "ultra rule text missing the multi-cause flat contrastive example: $ultra_out" ;;
esac
case "$ultra_out" in
  *"Diff CI log vs local run first"*) ok "ultra rule text has the new CI-failure worked example" ;;
  *) bad "ultra rule text missing the new CI-failure worked example: $ultra_out" ;;
esac

# 2026-09-02 ultra consolidation (docs/analysis/2026-09-02-caveman-ultra-
# consolidation.md): trims constraint count after the fix above measured a
# cost (tokens-per-visible-word rose while median tokens improved) -- pin
# every removal/merge so a future edit can't silently reintroduce the
# duplication or drop the consolidation, same discipline as the pins above.
case "$ultra_out" in
  *"## This level"*) bad "ultra rule text still has the vestigial duplicate This-level section (deleted 2026-09-02, restated Abbreviate/arrows/one-word facts already said once above)" ;;
  *) ok "ultra rule text dropped the vestigial duplicate This-level section" ;;
esac
case "$ultra_out" in
  *"Compress form, never substance"*) ok "ultra rule text consolidates technical-terms/code/errors exactness into one form-vs-substance clause" ;;
  *) bad "ultra rule text missing the form-vs-substance consolidation clause: $ultra_out" ;;
esac
case "$ultra_out" in
  *'"stop caveman" or "normal mode": revert.'*) bad "ultra rule text still restates the Persistence exit trigger in Boundaries (redundant -- Persistence already states it once)" ;;
  *) ok "ultra rule text dropped the redundant Boundaries restatement of the exit trigger" ;;
esac
case "$ultra_out" in
  *'"Why React component re-render?" → "Inline obj prop'*) ok "ultra rule text uses one-line arrow-joined example format, not a separate 'ultra:' labeled line" ;;
  *) bad "ultra rule text missing the one-line arrow-joined example format: $ultra_out" ;;
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

# ── rules: appends "Last Measured Compliance" section when a genuine
# measurement has been persisted by heimdall-caveman-compliance's
# _persist_last() (the measure/act loop -- see this tool's own "PARITY
# IMPROVEMENTS OVER THE PLUGIN" header comment). Negative case comes FIRST so
# the positive case below can't be mistaken for "always prints something". ──
D="$(fresh)"
no_measure_out="$(run "$D" rules full)"
case "$no_measure_out" in
  *"Last Measured Compliance"*) bad "rules appends a measurement section with no measurement file present" ;;
  *) ok "rules omits measurement section when no measurement file exists" ;;
esac

# Positive case: a well-formed measurement file is rendered with its ACTUAL
# figures, not a placeholder -- red-proof against a stub that always prints
# the same canned section regardless of file content.
D="$(fresh)"
printf '{"assistant_messages_with_text": 1, "prose_chars": 1000, "prose_words": 100, "filler_counts": {"articles": 40, "filler_adverbs": 5, "pleasantries": 1, "hedging": 0, "connectives": 2}, "filler_chars": {"articles": 120, "filler_adverbs": 30, "pleasantries": 5, "hedging": 0, "connectives": 10}, "total_filler_chars": 165, "total_filler_count": 48, "filler_share_of_prose_chars_pct": 16.5, "measured_at": 1788000000, "session_path": "/tmp/some-session-abc123.jsonl"}' > "$D/home/caveman-compliance-last.json"
measured_out="$(run "$D" rules full)"
case "$measured_out" in
  *"Last Measured Compliance"*) ok "rules appends measurement section when a genuine measurement is on disk" ;;
  *) bad "rules did not append measurement section despite a valid measurement file: $measured_out" ;;
esac
case "$measured_out" in
  *"16.50%"*) ok "rules renders the actual measured filler-share figure (16.50%)" ;;
  *) bad "rules did not render the measured figure 16.50%: $measured_out" ;;
esac
case "$measured_out" in
  *"some-session-abc123.jsonl"*) ok "rules renders the session basename, not the full path" ;;
  *) bad "rules did not render session basename: $measured_out" ;;
esac
case "$measured_out" in
  *"articles 40"*) ok "rules renders the top offending category with its real count" ;;
  *) bad "rules did not render top offender 'articles 40': $measured_out" ;;
esac
# hedging is 0 and must lose the top-3 sort to articles/filler_adverbs/
# connectives -- proves a real sort by count, not a dump of every key.
case "$measured_out" in
  *"hedging 0"*) bad "rules rendered a zero-count offender instead of a real top-3 sort" ;;
  *) ok "rules top-offenders list excludes a zero-count category (real sort, not a dump)" ;;
esac

# Corrupt measurement file: fails open, no section, no leaked content.
D="$(fresh)"
printf 'not json at all {{{ garbage-secret-marker\n' > "$D/home/caveman-compliance-last.json"
corrupt_out="$(run "$D" rules full)"
case "$corrupt_out" in
  *"Last Measured Compliance"*) bad "rules appended a measurement section from a corrupt file" ;;
  *) ok "rules stays silent on a corrupt measurement file (fails open)" ;;
esac
case "$corrupt_out" in
  *"garbage-secret-marker"*) bad "rules leaked raw corrupt-file content into its output" ;;
  *) ok "rules does not leak corrupt-file content" ;;
esac

# Symlinked measurement file: refused, same posture as the state-file read.
D="$(fresh)"
OUTSIDE_MEASURE="$(mktemp "$TMPDIR/outside-measure.XXXXXX")"
printf '{"prose_chars": 999, "filler_share_of_prose_chars_pct": 50.0, "filler_counts": {"articles": 9}, "do_not_leak": "do-not-leak-me"}\n' > "$OUTSIDE_MEASURE"
ln -s "$OUTSIDE_MEASURE" "$D/home/caveman-compliance-last.json"
symlink_out="$(run "$D" rules full)"
case "$symlink_out" in
  *"Last Measured Compliance"*) bad "rules followed a symlinked measurement file" ;;
  *) ok "rules refuses to follow a symlinked measurement file" ;;
esac
case "$symlink_out" in
  *"do-not-leak-me"*) bad "rules leaked content through a symlinked measurement file" ;;
  *) ok "rules does not leak symlinked-file content" ;;
esac

# ── migration: plugin flag seeds hmd's state exactly once ──
D="$(fresh)"
printf 'ultra\n' > "$D/claude/.caveman-active"
out="$(run "$D" get)"
[ "$out" = "ultra" ] && ok "migration: plugin flag 'ultra' is adopted on first get" || bad "migration: expected 'ultra' from plugin flag, got '$out'"
[ -f "$D/home/caveman-level" ] && ok "migration seeds hmd's own state file" || bad "migration did not create hmd's own state file"
# Change the plugin flag AFTER migration — hmd must not ADOPT it again (it
# WILL now also emit a stderr divergence warning here, since 'lite' != the
# already-adopted 'ultra' -- that warning path gets its own dedicated,
# stdout/stderr-isolated assertions in the "restart-survival" block below,
# so this block only re-asserts what it always asserted: the resolved VALUE).
printf 'lite\n' > "$D/claude/.caveman-active"
out2="$(run "$D" get 2>/dev/null)"
[ "$out2" = "ultra" ] && ok "migration is one-time: later plugin-flag edits are ignored (still 'ultra', got '$out2')" \
  || bad "migration re-read the plugin flag after the first seed (got '$out2', expected 'ultra')"

# 2026-09-01: a plugin flag of 'lite' or 'full' is now OUT OF SCOPE for
# migration seeding -- only 'ultra' is a valid level to migrate TO any more
# (see bin/heimdall-caveman "SCOPE"). Falls through to DEFAULT_LEVEL exactly
# like the existing wenyan-full/off out-of-scope cases below; pre-2026-09-01
# either WAS adopted verbatim, so this is a genuine behavioural change, not
# a restatement of the case above.
for legacy in lite full; do
  D="$(fresh)"
  printf '%s\n' "$legacy" > "$D/claude/.caveman-active"
  out="$(run "$D" get)"
  [ "$out" = "ultra" ] && ok "migration: plugin flag '$legacy' is NOT adopted post-collapse (falls back to 'ultra', got '$out')" \
    || bad "migration: plugin flag '$legacy' was wrongly adopted or fallback broke (got '$out', expected 'ultra')"
done

# ── restart-survival regression: hmd's level must survive the plugin
# silently rewriting its OWN flag file, exactly as observed first-hand on
# this repo's own session (2026-08-30) -- operator set the plugin's flag to
# "ultra" directly, then simply restarted the session (/login); with no
# action from hmd or the operator, the plugin's flag file's mtime advanced
# and its content reverted to "full". Simulated here by writing hmd's level
# via `set` (the authoritative path), then overwriting the PLUGIN's flag
# file out from under it (hmd's own state file is never touched), then
# re-invoking `get` as a brand-new process -- proving hmd's answer is
# unaffected by what the plugin's file now says. ──
D="$(fresh)"
run "$D" set ultra >/dev/null 2>&1
printf 'full\n' > "$D/claude/.caveman-active"   # simulate the plugin's own silent reset
out="$(run "$D" get 2>/dev/null)"
[ "$out" = "ultra" ] && ok "restart-survival: hmd keeps 'ultra' after the plugin's flag silently reverts to 'full'" \
  || bad "restart-survival: hmd's level was clobbered by the plugin's flag (got '$out', expected 'ultra')"

# Divergence must be surfaced on stderr and MUST NOT pollute stdout -- a hook
# pipes stdout straight into injected context, so stdout has to stay a bare
# level string even while the warning fires. `2>&1 1>/dev/null` isolates
# stderr into the capture (swap trick: dup stderr to the old stdout target,
# THEN send stdout to /dev/null -- order matters).
stderr_out="$(run "$D" get 2>&1 1>/dev/null)"
case "$stderr_out" in
  *"diverged"*"ultra"*"full"*) ok "restart-survival: divergence warning on stderr names both values" ;;
  *) bad "restart-survival: no divergence warning on stderr (got: '$stderr_out')" ;;
esac
stdout_out="$(run "$D" get 2>/dev/null)"
[ "$stdout_out" = "ultra" ] && ok "restart-survival: stdout stays a clean 'ultra' even while the warning fires" \
  || bad "restart-survival: stdout polluted by divergence warning (got '$stdout_out')"

# Negative case: no warning at all when hmd and the plugin AGREE -- proves
# this isn't an unconditional every-call warning regardless of content.
# 2026-09-01: must use 'ultra' on both sides now -- `set full` maps forward
# to ultra (see the set/get coverage above), so a literal plugin flag of
# 'full' would no longer actually agree with hmd's resolved state and this
# case would spuriously fire the very divergence warning it is testing the
# ABSENCE of.
D="$(fresh)"
run "$D" set ultra >/dev/null 2>&1
printf 'ultra\n' > "$D/claude/.caveman-active"
agree_stderr="$(run "$D" get 2>&1 1>/dev/null)"
[ -z "$agree_stderr" ] && ok "no divergence warning when hmd and plugin agree" \
  || bad "spurious divergence warning when hmd and plugin agree (got: '$agree_stderr')"

# Negative case: no warning when there is nothing to disagree WITH -- an
# absent plugin flag is not a disagreement.
D="$(fresh)"
run "$D" set lite >/dev/null 2>&1
rm -f "$D/claude/.caveman-active" 2>/dev/null
absent_stderr="$(run "$D" get 2>&1 1>/dev/null)"
[ -z "$absent_stderr" ] && ok "no divergence warning when plugin flag is absent" \
  || bad "spurious divergence warning when plugin flag is absent (got: '$absent_stderr')"

# Negative case: an out-of-scope plugin mode is not a disagreement about a
# level this tool owns.
D="$(fresh)"
run "$D" set lite >/dev/null 2>&1
printf 'wenyan-full\n' > "$D/claude/.caveman-active"
scope_stderr="$(run "$D" get 2>&1 1>/dev/null)"
[ -z "$scope_stderr" ] && ok "no divergence warning for an out-of-scope plugin mode (wenyan-full)" \
  || bad "spurious divergence warning for out-of-scope plugin mode (got: '$scope_stderr')"

# ── migration skip: out-of-scope plugin mode is never adopted ──
D="$(fresh)"
printf 'wenyan-full\n' > "$D/claude/.caveman-active"
out="$(run "$D" get)"; rc=$?
[ "$rc" -eq 0 ] && ok "migration skip (wenyan-full): get still exits 0 (rc=$rc)" || bad "migration skip (wenyan-full): get still exits 0 (rc=$rc)"
[ "$out" = "ultra" ] && ok "out-of-scope plugin mode 'wenyan-full' is not adopted (falls back to 'ultra', got '$out')" \
  || bad "out-of-scope plugin mode was adopted or fallback broke (got '$out')"

# ── migration skip: 'off' is never adopted either ──
D="$(fresh)"
printf 'off\n' > "$D/claude/.caveman-active"
out="$(run "$D" get)"
[ "$out" = "ultra" ] && ok "plugin mode 'off' is not adopted (falls back to 'ultra', got '$out')" \
  || bad "plugin mode 'off' was adopted or fallback broke (got '$out')"

# ── no plugin flag at all: get still succeeds (already covered above, but
# explicitly re-asserted here alongside the migration cases for locality) ──
D="$(fresh)"
rm -f "$D/claude/.caveman-active" 2>/dev/null
out="$(run "$D" get)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ultra" ] && ok "no plugin flag present: get exits 0 and defaults to ultra" \
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

# ── path: explicit negative-space assertion -- must NOT print the real,
# un-overridden $HOME path. The equality check above already implies this
# (a random mktemp dir can never equal the real $HOME), but a path command
# that silently ignored the override would still print SOME well-formed
# path, and that failure mode deserves its own explicit, named assertion. ──
case "$path_out" in
  "$HOME"/.heimdall/*) bad "path printed the real \$HOME/.heimdall path despite HEIMDALL_HOME override: $path_out" ;;
  *) ok "path does not fall back to the real \$HOME/.heimdall path when HEIMDALL_HOME is overridden" ;;
esac

# ── diff: RETIRED 2026-09-01 (see bin/heimdall-caveman's own header comment,
# the "RETIRED 2026-09-01" note, formerly "BUILT 2"). Its only non-degenerate
# use -- comparing two DIFFERENT real levels -- no longer exists once there
# is only one settable level (ultra). Replaced by a negative-space proof of
# the removal itself: `diff` must now fail cleanly as an unrecognized
# subcommand, never crash and never silently succeed as if it still did
# something. ──
D="$(fresh)"
diff_gone_out="$(run "$D" diff ultra lite 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && ok "diff is no longer a recognized subcommand (exits non-zero, rc=$rc)" \
  || bad "diff still succeeds as if it were a live subcommand (rc=$rc): $diff_gone_out"
[ -z "$diff_gone_out" ] && ok "removed diff subcommand emits nothing on stdout" \
  || bad "removed diff subcommand still emitted stdout: $diff_gone_out"

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

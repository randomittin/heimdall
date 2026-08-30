#!/usr/bin/env bash
# test/heimdall-caveman-compliance.test.sh
#
# Verifies bin/heimdall-caveman-compliance: a read-only audit tool that
# measures filler-word density in a session transcript's assistant prose.
# Built for docs/analysis/2026-08-30-caveman-compliance-audit.md (Q3: nothing
# in the caveman plugin, or anywhere in hmd, ever measured live-reply
# compliance or savings — this tool fills that gap). Synthetic fixtures only,
# hand-verified counts — never touches a real ~/.claude/projects transcript,
# same convention as test/heimdall-tokens.test.sh.
#
# PERSISTENCE (the measure/act loop): every GENUINE (non-degraded, non-zero-
# prose) measurement is now ALSO written to
# $HEIMDALL_HOME/caveman-compliance-last.json for bin/heimdall-caveman's
# `rules` command to read back later. ALL invocations below pin HEIMDALL_HOME
# to a hermetic $TMPDIR subdirectory -- this suite used to invoke the tool
# with HEIMDALL_HOME entirely unpinned (harmless before persistence existed),
# which once persistence shipped silently wrote real fixture data into the
# operator's own ~/.heimdall/caveman-compliance-last.json on every test run.
# Caught by inspecting that file's content (its session_path was a stray
# $TMPDIR path) and fixed in the same change that added the persistence
# tests below and the real-file hermeticity snapshot that guards it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-caveman-compliance"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Real file this suite (and the tool's own persistence feature) must never
# touch now that every invocation below pins HEIMDALL_HOME -- snapshotted
# before running anything, re-checked at the very end. See header comment
# above for the regression this specifically guards against.
REAL_LAST_MEASURE="${HOME:-/nonexistent}/.heimdall/caveman-compliance-last.json"
real_stamp() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo "absent"; }
BEFORE_REAL_LAST_MEASURE="$(real_stamp "$REAL_LAST_MEASURE")"

# Hermetic HEIMDALL_HOME for every invocation in this file.
HOME_DIR="$TMPDIR/home"
mkdir -p "$HOME_DIR"

# ---------------------------------------------------------------------------
# Fixture: one synthetic transcript exercising every filler category, fenced-
# code exclusion, inline-code exclusion, a text-less assistant turn, a non-
# list content turn, non-assistant turns, and one malformed line. Every count
# asserted below is hand-verified word-by-word (see the audit doc); this is
# not a blind snapshot assertion.
# ---------------------------------------------------------------------------
FIXTURE="$TMPDIR/session.jsonl"
cat > "$FIXTURE" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
{"type":"system","message":"noop"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"The cat sat."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Just really basic."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Sure, of course.\n```\nthe just really basically actually simply generally essentially\n```\nDone. Inline `the really certainly` stays clean."}]}}
{not valid json at all
{"type":"assistant","message":{"content":"not-a-list"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"It might be worth trying. However, additionally furthermore it helps."}]}}
JSONL

OUT="$(HEIMDALL_HOME="$HOME_DIR" python3 "$TOOL" "$FIXTURE" --json)"
RC=$?

if [ "$RC" -eq 0 ]; then
  ok "tool exits 0 on well-formed-plus-one-bad-line fixture"
else
  bad "tool exits 0 on well-formed-plus-one-bad-line fixture (rc=$RC)"
fi

get() { python3 -c "import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])" "$OUT" "$1"; }
get_nested() { python3 -c "import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]][sys.argv[3]])" "$OUT" "$1" "$2"; }

# assistant_messages_with_text: lines 4,5,6,9 have real text blocks (4 total).
# line 3 (tool_use only) and line 8 (content not a list) must NOT count.
val="$(get assistant_messages_with_text)"
[ "$val" = "4" ] && ok "assistant_messages_with_text == 4 (got $val)" || bad "assistant_messages_with_text == 4 (got $val)"

# articles: only "The" in line 4 -> count 1, chars 3.
val="$(get_nested filler_counts articles)"
[ "$val" = "1" ] && ok "articles count == 1 (got $val)" || bad "articles count == 1 (got $val)"
val="$(get_nested filler_chars articles)"
[ "$val" = "3" ] && ok "articles chars == 3 (got $val)" || bad "articles chars == 3 (got $val)"

# filler_adverbs: "Just","really" in line 5 -> count 2, chars 10. Line 6's
# fenced block repeats 7 more adverb words and the inline-code span repeats
# "really" -- NONE of those may count; this assertion catches broken stripping.
val="$(get_nested filler_counts filler_adverbs)"
[ "$val" = "2" ] && ok "filler_adverbs count == 2, fence+inline excluded (got $val)" || bad "filler_adverbs count == 2, fence+inline excluded (got $val)"
val="$(get_nested filler_chars filler_adverbs)"
[ "$val" = "10" ] && ok "filler_adverbs chars == 10 (got $val)" || bad "filler_adverbs chars == 10 (got $val)"

# pleasantries: "Sure","of course" in line 6 (outside the fence/inline span) ->
# count 2, chars 4+9=13. The inline span's "certainly" must NOT add a 3rd.
val="$(get_nested filler_counts pleasantries)"
[ "$val" = "2" ] && ok "pleasantries count == 2, inline-code excluded (got $val)" || bad "pleasantries count == 2, inline-code excluded (got $val)"
val="$(get_nested filler_chars pleasantries)"
[ "$val" = "13" ] && ok "pleasantries chars == 13 (got $val)" || bad "pleasantries chars == 13 (got $val)"

# hedging: "It might be worth" in line 9 -> count 1, chars 17.
val="$(get_nested filler_counts hedging)"
[ "$val" = "1" ] && ok "hedging count == 1 (got $val)" || bad "hedging count == 1 (got $val)"
val="$(get_nested filler_chars hedging)"
[ "$val" = "17" ] && ok "hedging chars == 17 (got $val)" || bad "hedging chars == 17 (got $val)"

# connectives: "However","additionally","furthermore" in line 9 -> count 3,
# chars 7+12+11=30.
val="$(get_nested filler_counts connectives)"
[ "$val" = "3" ] && ok "connectives count == 3 (got $val)" || bad "connectives count == 3 (got $val)"
val="$(get_nested filler_chars connectives)"
[ "$val" = "30" ] && ok "connectives chars == 30 (got $val)" || bad "connectives chars == 30 (got $val)"

# totals: count 1+2+2+1+3=9, chars 3+10+13+17+30=73.
val="$(get total_filler_count)"
[ "$val" = "9" ] && ok "total_filler_count == 9 (got $val)" || bad "total_filler_count == 9 (got $val)"
val="$(get total_filler_chars)"
[ "$val" = "73" ] && ok "total_filler_chars == 73 (got $val)" || bad "total_filler_chars == 73 (got $val)"

# prose_chars/words are plain len()/split() over raw text (code included) --
# sanity-checked as positive, not hand-counted to the byte.
val="$(get prose_chars)"
[ "$val" -gt 0 ] 2>/dev/null && ok "prose_chars > 0 (got $val)" || bad "prose_chars > 0 (got $val)"
val="$(get prose_words)"
[ "$val" -gt 0 ] 2>/dev/null && ok "prose_words > 0 (got $val)" || bad "prose_words > 0 (got $val)"

# share pct must be present and non-null once prose_chars > 0.
val="$(get filler_share_of_prose_chars_pct)"
[ "$val" != "None" ] && ok "filler_share_of_prose_chars_pct is not null (got $val)" || bad "filler_share_of_prose_chars_pct is not null (got $val)"

# ---------------------------------------------------------------------------
# Degraded-input behaviour: fail-open, always exit 0 on a content problem,
# never a raised traceback -- an audit tool must not be able to crash the
# caller. A genuinely missing required ARGUMENT (no path at all) is the one
# case that is a real caller error, and exits non-zero instead.
# ---------------------------------------------------------------------------
MISSING="$TMPDIR/does-not-exist.jsonl"
OUT2="$(HEIMDALL_HOME="$HOME_DIR" python3 "$TOOL" "$MISSING" --json 2>&1)"
RC2=$?
if [ "$RC2" -eq 0 ]; then
  ok "missing-file input still exits 0 (fail-open)"
else
  bad "missing-file input still exits 0 (fail-open) (rc=$RC2)"
fi
case "$OUT2" in
  *'"error"'*) ok "missing-file input reports an error field" ;;
  *) bad "missing-file input reports an error field (got: $OUT2)" ;;
esac

GARBAGE="$TMPDIR/garbage.jsonl"
printf 'not json\nalso not json\n{{{\n' > "$GARBAGE"
OUT3="$(HEIMDALL_HOME="$HOME_DIR" python3 "$TOOL" "$GARBAGE" --json 2>&1)"
RC3=$?
if [ "$RC3" -eq 0 ]; then
  ok "all-garbage transcript still exits 0 (fail-open)"
else
  bad "all-garbage transcript still exits 0 (fail-open) (rc=$RC3)"
fi
case "$OUT3" in
  *'"error"'*) ok "all-garbage transcript reports an error field" ;;
  *) bad "all-garbage transcript reports an error field (got: $OUT3)" ;;
esac

# no-args usage: a missing required path argument is a real caller error --
# must exit non-zero, and must never crash with a traceback.
HEIMDALL_HOME="$HOME_DIR" python3 "$TOOL" >"$TMPDIR/noargs.out" 2>&1
RC4=$?
[ "$RC4" -ne 0 ] && ok "no-args invocation exits non-zero (rc=$RC4)" || bad "no-args invocation exits non-zero (rc=$RC4)"

# human-readable mode (no --json) must not crash and must mention the share line.
OUT5="$(HEIMDALL_HOME="$HOME_DIR" python3 "$TOOL" "$FIXTURE")"
RC5=$?
if [ "$RC5" -eq 0 ]; then
  ok "human-readable mode exits 0"
else
  bad "human-readable mode exits 0 (rc=$RC5)"
fi
case "$OUT5" in
  *"filler share of prose chars"*) ok "human-readable mode prints the filler-share line" ;;
  *) bad "human-readable mode prints the filler-share line" ;;
esac

# ---------------------------------------------------------------------------
# Persistence (the measure/act loop): see header comment. Every test below
# gets its OWN fresh HEIMDALL_HOME subdirectory so one test's persisted file
# can never leak into another's assertions.
# ---------------------------------------------------------------------------
PERSIST_FILE_NAME="caveman-compliance-last.json"
fresh_home() {
  local d
  d="$(mktemp -d "$TMPDIR/persist-case.XXXXXX")"
  printf '%s\n' "$d"
}
pfield() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$1" "$2"; }

# Genuine measurement: persisted file exists, and its fields match what this
# SAME run computed live -- not just "a file appeared". A stub that persists
# an empty or hardcoded record would fail the count/session_path assertions.
PH1="$(fresh_home)"
OUT_P1="$(HEIMDALL_HOME="$PH1" python3 "$TOOL" "$FIXTURE" --json)"
PERSISTED_1="$PH1/$PERSIST_FILE_NAME"
[ -f "$PERSISTED_1" ] && ok "genuine measurement persists $PERSIST_FILE_NAME" \
  || bad "genuine measurement did not create $PERSISTED_1"
live_count="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['total_filler_count'])" "$OUT_P1")"
persisted_count="$(pfield "$PERSISTED_1" total_filler_count)"
[ "$live_count" = "$persisted_count" ] && ok "persisted total_filler_count matches this run's own live output ($live_count)" \
  || bad "persisted total_filler_count ($persisted_count) does not match live output ($live_count)"
persisted_session="$(pfield "$PERSISTED_1" session_path)"
[ "$persisted_session" = "$FIXTURE" ] && ok "persisted session_path matches the transcript that was measured" \
  || bad "persisted session_path ('$persisted_session') does not match FIXTURE ('$FIXTURE')"
persisted_at="$(pfield "$PERSISTED_1" measured_at)"
python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)" "$persisted_at" 2>/dev/null \
  && ok "persisted measured_at is a real positive timestamp" \
  || bad "persisted measured_at is not a positive timestamp (got '$persisted_at')"
perm="$(stat -f '%Lp' "$PERSISTED_1" 2>/dev/null || stat -c '%a' "$PERSISTED_1" 2>/dev/null)"
[ "$perm" = "600" ] && ok "persisted file is written with 0600 permissions" \
  || bad "persisted file permissions are '$perm', expected 600"

# Degraded input (missing file, then all-garbage) must NEVER clobber a prior
# GENUINE persisted record -- the whole point of gating _persist_last on
# `not rec.get("error") and prose_chars > 0` in main(). Prove it by snapshotting
# the genuine record's exact bytes, running two different degraded inputs
# against the SAME HEIMDALL_HOME, and asserting the file never changed.
PH2="$(fresh_home)"
HEIMDALL_HOME="$PH2" python3 "$TOOL" "$FIXTURE" --json >/dev/null
PERSISTED_2="$PH2/$PERSIST_FILE_NAME"
SNAPSHOT_2="$TMPDIR/persisted-2-snapshot.json"
cp "$PERSISTED_2" "$SNAPSHOT_2"
HEIMDALL_HOME="$PH2" python3 "$TOOL" "$MISSING" --json >/dev/null 2>&1
if cmp -s "$PERSISTED_2" "$SNAPSHOT_2"; then
  ok "a degraded (missing-file) run does not clobber a prior genuine persisted record"
else
  bad "a degraded (missing-file) run overwrote a prior genuine persisted record"
fi
HEIMDALL_HOME="$PH2" python3 "$TOOL" "$GARBAGE" --json >/dev/null 2>&1
if cmp -s "$PERSISTED_2" "$SNAPSHOT_2"; then
  ok "a degraded (all-garbage) run does not clobber a prior genuine persisted record"
else
  bad "a degraded (all-garbage) run overwrote a prior genuine persisted record"
fi

# Degraded-only history (never a genuine measurement in this HEIMDALL_HOME):
# no persisted file should exist at all -- proves persistence is opt-in on
# genuine data, not "always write something".
PH3="$(fresh_home)"
HEIMDALL_HOME="$PH3" python3 "$TOOL" "$MISSING" --json >/dev/null 2>&1
HEIMDALL_HOME="$PH3" python3 "$TOOL" "$GARBAGE" --json >/dev/null 2>&1
[ ! -e "$PH3/$PERSIST_FILE_NAME" ] && ok "degraded-only history persists nothing at all" \
  || bad "a degraded-only run created a persisted file at $PH3/$PERSIST_FILE_NAME"

# Symlink refusal on write (security carve-out, same posture as
# bin/heimdall-caveman's own _safe_write_level): a pre-existing symlink at
# the target path must not be written through, and the file it points at
# must remain untouched.
PH4="$(fresh_home)"
OUTSIDE_SECRET="$(mktemp "$TMPDIR/outside-compliance-secret.XXXXXX")"
printf 'do-not-touch\n' > "$OUTSIDE_SECRET"
ln -s "$OUTSIDE_SECRET" "$PH4/$PERSIST_FILE_NAME"
HEIMDALL_HOME="$PH4" python3 "$TOOL" "$FIXTURE" --json >/dev/null
outside_after="$(cat "$OUTSIDE_SECRET" 2>/dev/null || true)"
[ "$outside_after" = "do-not-touch" ] && ok "persistence refuses to write through a symlinked target (outside file untouched)" \
  || bad "persistence followed a symlink and clobbered an unrelated file: '$outside_after'"
[ -L "$PH4/$PERSIST_FILE_NAME" ] && ok "symlink at the target path is left in place, not replaced" \
  || bad "symlink at the target path was replaced (should have been refused, not swapped)"

# Symlinked HOME directory itself (not just the target file) must also be
# refused -- the other half of _persist_last's symlink posture.
PH5_REAL="$(mktemp -d "$TMPDIR/persist-case-real.XXXXXX")"
PH5_LINK="$TMPDIR/persist-case-link"
ln -s "$PH5_REAL" "$PH5_LINK"
HEIMDALL_HOME="$PH5_LINK" python3 "$TOOL" "$FIXTURE" --json >/dev/null
[ ! -e "$PH5_REAL/$PERSIST_FILE_NAME" ] && ok "persistence refuses to write when HEIMDALL_HOME itself is a symlink" \
  || bad "persistence wrote through a symlinked HEIMDALL_HOME directory"

# ── hermeticity: the real file was never touched by this entire suite ──
AFTER_REAL_LAST_MEASURE="$(real_stamp "$REAL_LAST_MEASURE")"
[ "$BEFORE_REAL_LAST_MEASURE" = "$AFTER_REAL_LAST_MEASURE" ] && ok "real \$HOME/.heimdall/caveman-compliance-last.json untouched by this suite" \
  || bad "real \$HOME/.heimdall/caveman-compliance-last.json changed during this suite ($BEFORE_REAL_LAST_MEASURE -> $AFTER_REAL_LAST_MEASURE)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

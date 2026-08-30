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

OUT="$(python3 "$TOOL" "$FIXTURE" --json)"
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
OUT2="$(python3 "$TOOL" "$MISSING" --json 2>&1)"
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
OUT3="$(python3 "$TOOL" "$GARBAGE" --json 2>&1)"
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
python3 "$TOOL" >"$TMPDIR/noargs.out" 2>&1
RC4=$?
[ "$RC4" -ne 0 ] && ok "no-args invocation exits non-zero (rc=$RC4)" || bad "no-args invocation exits non-zero (rc=$RC4)"

# human-readable mode (no --json) must not crash and must mention the share line.
OUT5="$(python3 "$TOOL" "$FIXTURE")"
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

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

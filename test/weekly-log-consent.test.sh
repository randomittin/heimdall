#!/usr/bin/env bash
# weekly-log-consent.test.sh — proves bin/heimdall-weekly-log can never publish a
# claim about a user that the user did not consent to, and can never name a team
# small enough to be identifiable.
#
# THE DEFECT THIS GUARDS: the generator runs unattended every Monday and writes a
# PUBLIC post. A generator that leaks one customer detail is never trusted again,
# and nobody is watching at the moment it leaks. So every path that could carry a
# user-identifying detail into a draft is asserted shut here, by mutation.
#
#   A. SYNTAX          `bash -n` clean.
#   B. ZERO ACTIVITY   an empty window yields an HONEST "nothing shipped" draft —
#                      a real file, saying nothing shipped, with no fabricated
#                      summary and no invented counts.
#   C. CONSENT         a fix with NO `Credit-Team:` trailer is NEVER named. The
#                      fix still ships, unattributed.
#   D. k-ANONYMITY     THE FALSIFIER, run as a live mutation: a 5-team cohort
#                      publishes names; delete one crediting commit so the cohort
#                      is 4 (< k=5) and EVERY name vanishes from BOTH outputs;
#                      restore the commit and the baseline output returns byte-
#                      identical. The team count is the only thing that changed.
#   E. SCRUB           an email or an @handle planted in a commit SUBJECT never
#                      reaches a draft; the redaction marker does.
#   F. NO BODY LEAK    a customer detail planted in a commit BODY never reaches a
#                      draft — bodies are never read at all.
#   G. NEVER PUBLISH   output lands under drafts/, carries `publish: false`, and
#                      the generator writes nothing outside its --out directory.
#   H. VOCABULARY      a draft says "proposals awaiting review" and never claims
#                      heimdall auto-synthesizes or enforces a rule.
#
# HERMETIC: every git operation runs inside a throwaway repo under $WORK. The
# heimdall repo's own history is read by no assertion here.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GEN="$ROOT/bin/heimdall-weekly-log"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# A NEGATIVE assertion ("this string is absent") passes vacuously when the file
# it greps does not exist — `grep` just errors and reports no match. Every such
# assertion in this file therefore routes through these helpers, which FAIL on a
# missing file instead of reporting a green that proves nothing.
have() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || { printf "    (missing file: %s)\n" "$f"; return 1; }
  done
}
absent_in()    { local n="$1"; shift; have "$@" || return 1; ! grep -q  -- "$n" "$@"; }
absent_in_i()  { local n="$1"; shift; have "$@" || return 1; ! grep -qi -- "$n" "$@"; }
absent_re()    { local r="$1"; shift; have "$@" || return 1; ! grep -qE -- "$r" "$@"; }
present_in()   { local n="$1"; shift; have "$@" || return 1; grep -q  -- "$n" "$@"; }

[ -f "$GEN" ] || { echo "FATAL: $GEN not found"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Hermetic home: weekly-log writes a liveness receipt, and this suite runs it over a
# throwaway fixture repo. Unredirected, a test run would stamp the real
# ~/.heimdall/liveness/weekly-log.json for a repo that is not this one.
export HEIMDALL_HOME="$WORK/home"
REPO="$WORK/fixture"
OUT="$WORK/out"
WIN='--since=2026-07-01 --until=2026-08-31'

# ── the fixture repo ─────────────────────────────────────────────────────────

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "fixture@example.invalid"
git -C "$REPO" config user.name  "Fixture"

N=0
mkcommit() { # $1 subject  [$2 Credit-Team value]  [$3 body]
  N=$((N + 1))
  local d="2026-07-$(printf '%02d' $((10 + N)))T12:00:00"
  local msg="$1"
  [ -n "${3:-}" ] && msg="$msg

$3"
  [ -n "${2:-}" ] && msg="$msg

Credit-Team: $2"
  GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" \
    git -C "$REPO" commit -q --allow-empty -m "$msg"
}

# Five credited teams — the baseline cohort, exactly at the k=5 floor.
mkcommit "fix(billing): stop double-charging on retry"       "acme-payments"
mkcommit "fix(auth): reject an expired refresh token"        "globex-identity"
mkcommit "fix(search): rank exact matches first"             "initech-search"
mkcommit "fix(sync): resolve a clock-skew conflict"          "umbrella-sync"
mkcommit "fix(export): escape a quoted CSV cell"             "soylent-data"
# Uncredited work — no trailer, so it may never be attributed to anyone.
mkcommit "feat(api): add a cursor-paginated list endpoint"
# A body carrying a customer detail the draft must never read.
mkcommit "fix(queue): drain on shutdown" "" \
  "Reported by Jane Roe at Northwind Trading, account 88421, jane.roe@northwind.example."
# Identifiers planted directly in a SUBJECT.
mkcommit "fix(webhook): retry after a 502 reported by dana@northwind.example"
mkcommit "fix(cli): honour --quiet as raised by @dana-northwind"

TEAMS="acme-payments globex-identity initech-search umbrella-sync soylent-data"

run_gen() { # $@ extra flags -> writes to $OUT, prints the summary
  rm -rf "$OUT"
  "$GEN" --repo "$REPO" --out "$OUT" $WIN "$@" 2>&1
}
post_file()  { echo "$OUT/$(ls "$OUT" | grep '^log-week-' | head -1)"; }
slice_file() { echo "$OUT/$(ls "$OUT" | grep '^release-notes-week-' | head -1)"; }
both_files() { cat "$(post_file)" "$(slice_file)"; }

echo
echo "A. SYNTAX"
if bash -n "$GEN" 2>/dev/null; then ok "bash -n clean on bin/heimdall-weekly-log"
else bad "bash -n reported a syntax error"; fi

# ── B. zero activity ─────────────────────────────────────────────────────────

echo
echo "B. ZERO ACTIVITY — an empty week is reported, not fabricated"
rm -rf "$OUT"
"$GEN" --repo "$REPO" --out "$OUT" --since=2020-01-01 --until=2020-01-08 >/dev/null 2>&1
zpost="$(post_file)"
if [ -s "$zpost" ]; then ok "B1 a zero-activity week still writes a NON-EMPTY draft"
else bad "B1 zero-activity draft is empty or missing"; fi
if grep -qi 'no commits landed' "$zpost"; then ok "B2 the draft states plainly that no commits landed"
else bad "B2 the zero-activity draft does not say nothing shipped"; fi
if grep -q 'title: Nothing shipped this week' "$zpost"; then ok "B3 the title is honest, not a manufactured theme"
else bad "B3 zero-activity title is not the honest one"; fi
# No section may claim work that does not exist.
if absent_re '^### ' "$zpost"; then ok "B4 no fabricated section in a week with no commits"
else bad "B4 the zero-activity draft invented a section"; fi
if absent_re '^- .*\(`[0-9a-f]{7}' "$zpost"; then ok "B5 no fabricated sha-bearing line"
else bad "B5 the zero-activity draft invented a commit line"; fi
# With no commits there are no commit dates to derive a window from. The draft
# must echo the window it was ASKED for, never substitute the day it ran.
if present_in 'window: 2020-01-01..2020-01-08' "$zpost"; then
  ok "B6 the empty draft reports the window it actually read, not the day it ran"
else bad "B6 the empty draft reported a window no commit supports"; fi
if absent_in "window: $(date -u +%Y-%m-%d)..$(date -u +%Y-%m-%d)" "$zpost"; then
  ok "B7 today's date is never substituted for an empty window"
else bad "B7 the empty draft substituted today's date for the requested window"; fi

# ── C + D + E + F + G + H over the full fixture ──────────────────────────────

echo
echo "D. k-ANONYMITY FALSIFIER — baseline: a 5-team cohort at the k=5 floor"
baseline_summary="$(run_gen)"
if have "$(post_file)" "$(slice_file)"; then
  ok "D0 the baseline run produced both drafts (every later negative rests on this)"
  cp "$(post_file)"  "$WORK/baseline-post.md"
  cp "$(slice_file)" "$WORK/baseline-slice.md"
else
  bad "D0 the baseline run produced no drafts; generator said: $baseline_summary"
fi
if grep -q 'credits:              published' <<<"$baseline_summary"; then
  ok "D1 5 distinct teams >= k=5 -> the credits block PUBLISHES"
else bad "D1 a 5-team cohort should publish; summary said: $baseline_summary"; fi

named=0
for t in $TEAMS; do
  grep -q "$t" "$WORK/baseline-post.md" && named=$((named + 1))
done
if [ "$named" -eq 5 ]; then ok "D2 all 5 consented teams are named in the baseline draft"
else bad "D2 expected 5 named teams in the baseline draft, found $named"; fi

# THE MUTATION: delete ONE crediting commit. The cohort drops to 4, below k=5.
# Nothing else about the repo, the flags, or the generator changes.
git -C "$REPO" log --pretty=tformat:'%H %s' > "$WORK/log.txt"
drop_sha="$(awk '/stop double-charging on retry/ { print $1 }' "$WORK/log.txt")"
git -C "$REPO" tag baseline-head HEAD
git -C "$REPO" filter-branch -f --commit-filter \
  "if [ \"\$GIT_COMMIT\" = $drop_sha ]; then skip_commit \"\$@\"; else git commit-tree \"\$@\"; fi" \
  HEAD >/dev/null 2>&1

echo
echo "   MUTATION: one crediting commit removed -> cohort = 4 < k = 5"
mutated_summary="$(run_gen)"
if have "$(post_file)" "$(slice_file)"; then
  cp "$(post_file)"  "$WORK/mutated-post.md"
  cp "$(slice_file)" "$WORK/mutated-slice.md"
else
  bad "D3a the mutated run produced no drafts; generator said: $mutated_summary"
fi

if grep -q 'credits:              suppressed (k_anonymity, 4 < 5)' <<<"$mutated_summary"; then
  ok "D3 4 distinct teams < k=5 -> the credits block is SUPPRESSED"
else bad "D3 a 4-team cohort must suppress; summary said: $mutated_summary"; fi

# The suppression proof is only meaningful if the drafts exist AND still name the
# surviving work; a missing file must never read as "no leak".
leaked=""
if have "$WORK/mutated-post.md" "$WORK/mutated-slice.md"; then
  for t in $TEAMS; do
    if grep -q "$t" "$WORK/mutated-post.md" "$WORK/mutated-slice.md"; then
      leaked="$leaked $t"
    fi
  done
  if [ -z "$leaked" ]; then ok "D4 [CARDINAL] NO team name survives into EITHER output below k"
  else bad "D4 [CARDINAL] sub-k leak of:$leaked"; fi
else
  bad "D4 [CARDINAL] cannot prove suppression — the mutated drafts are missing"
fi

if grep -q 'reason: k_anonymity' "$WORK/mutated-slice.md"; then
  ok "D5 the slice records the suppression reason (k_anonymity), matching _publish_bucket"
else bad "D5 the slice does not record a k_anonymity suppression reason"; fi
if grep -q 'distinct credited teams in window: 4' "$WORK/mutated-slice.md"; then
  ok "D6 the small cell is still COUNTABLE (4) without being nameable"
else bad "D6 the suppressed cohort lost its distinct-team count"; fi
# The work itself must still ship — suppression drops the credit, not the fix.
if grep -q 'reject an expired refresh token' "$WORK/mutated-post.md"; then
  ok "D7 suppression drops the CREDIT, not the fix — the fixes still ship unattributed"
else bad "D7 suppression wrongly dropped the fixes themselves"; fi

# THE REVERT: restore the deleted commit. Behaviour must return to baseline.
git -C "$REPO" reset -q --hard baseline-head
echo
echo "   REVERT: the crediting commit is restored -> cohort = 5"
reverted_summary="$(run_gen)"
cp "$(post_file)"  "$WORK/reverted-post.md"
if grep -q 'credits:              published' <<<"$reverted_summary"; then
  ok "D8 after the revert the credits block PUBLISHES again"
else bad "D8 the revert did not restore normal behaviour: $reverted_summary"; fi
if diff -q <(grep -v '^generated:' "$WORK/baseline-post.md") \
           <(grep -v '^generated:' "$WORK/reverted-post.md") >/dev/null 2>&1; then
  ok "D9 the reverted draft matches the baseline draft exactly (team count was the only variable)"
else bad "D9 the reverted draft diverged from the baseline"; fi

echo
echo "   MUTATION RECEIPT — the credits block, both ways"
echo "   --- below k (suppressed) ---"
sed -n '/^## Credits/,/^\*Nothing ships/p' "$WORK/mutated-post.md" | sed 's/^/   /'
echo "   --- at k (published) ---"
sed -n '/^## Credits/,/^\*Nothing ships/p' "$WORK/baseline-post.md" | sed 's/^/   /'

# ── C. consent ───────────────────────────────────────────────────────────────

echo
echo "C. CONSENT — only a Credit-Team trailer may name anyone"
if grep -q 'cursor-paginated list endpoint' "$WORK/baseline-post.md"; then
  ok "C1 an uncredited commit still ships in the changelog"
else bad "C1 an uncredited commit was dropped entirely"; fi
uncredited_line="$(grep 'cursor-paginated list endpoint' "$WORK/baseline-post.md" 2>/dev/null || :)"
if [ -z "$uncredited_line" ]; then
  bad "C2 cannot check attribution — the uncredited line is absent from the draft"
elif ! grep -qiE 'acme|globex|initech|umbrella|soylent' <<<"$uncredited_line"; then
  ok "C2 an uncredited commit is never attributed to any team"
else bad "C2 an uncredited commit picked up an attribution"; fi
credit_block="$(sed -n '/^## Credits/,$p' "$WORK/baseline-post.md")"
credit_shas="$(grep -oE '`[0-9a-f]{7,}`' <<<"$credit_block" | wc -l | tr -d ' ')"
if [ "$credit_shas" -eq 5 ]; then
  ok "C3 every published credit carries the sha that recorded the consent"
else bad "C3 expected 5 sha-backed credits, found $credit_shas"; fi

# ── E. scrub ─────────────────────────────────────────────────────────────────

echo
echo "E. SCRUB — identifiers planted in a commit SUBJECT"
if absent_in 'dana@northwind.example' "$WORK/baseline-post.md" "$WORK/baseline-slice.md"; then
  ok "E1 [CARDINAL] a planted email never reaches a draft"
else bad "E1 [CARDINAL] a planted email leaked into a draft"; fi
if absent_in '@dana-northwind' "$WORK/baseline-post.md" "$WORK/baseline-slice.md"; then
  ok "E2 [CARDINAL] a planted @handle never reaches a draft"
else bad "E2 [CARDINAL] a planted @handle leaked into a draft"; fi
if grep -q 'redacted-email' "$WORK/baseline-post.md"; then
  ok "E3 the redaction is visible, so an editor can see something was removed"
else bad "E3 no redaction marker where the email was"; fi
if grep -q 'redacted-handle' "$WORK/baseline-post.md"; then
  ok "E4 the @handle redaction is visible too"
else bad "E4 no redaction marker where the handle was"; fi
if grep -q 'retry after a 502' "$WORK/baseline-post.md"; then
  ok "E5 scrubbing redacts the identifier, it does not drop the whole fix"
else bad "E5 scrubbing dropped the entire commit"; fi

# ── F. no body leak ──────────────────────────────────────────────────────────

echo
echo "F. NO BODY LEAK — commit bodies are never read"
body_leak=0
if have "$WORK/baseline-post.md" "$WORK/baseline-slice.md"; then
  for needle in 'Jane Roe' 'Northwind Trading' '88421' 'jane.roe@northwind.example'; do
    if grep -q "$needle" "$WORK/baseline-post.md" "$WORK/baseline-slice.md"; then
      bad "F: customer detail from a commit BODY leaked: $needle"; body_leak=1
    fi
  done
  [ "$body_leak" -eq 0 ] && ok "F1 [CARDINAL] no detail from any commit body reaches a draft"
else
  bad "F1 [CARDINAL] cannot prove body containment — the baseline drafts are missing"
fi
if grep -q 'drain on shutdown' "$WORK/baseline-post.md"; then
  ok "F2 the commit with the sensitive body still ships by its subject"
else bad "F2 the commit with a sensitive body was dropped"; fi

# ── G. never publishes ───────────────────────────────────────────────────────

echo
echo "G. NEVER PUBLISHES"
if grep -q '^publish: false' "$WORK/baseline-post.md"; then ok "G1 the draft carries publish: false"
else bad "G1 the draft is missing publish: false"; fi
if grep -q '^status: draft' "$WORK/baseline-post.md"; then ok "G2 the draft carries status: draft"
else bad "G2 the draft is missing status: draft"; fi
if grep -q 'published:            no' <<<"$baseline_summary"; then
  ok "G3 the run summary states plainly that nothing was published"
else bad "G3 the run summary does not state that nothing was published"; fi
# The fixture repo must be untouched: a generator is a reader.
if [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  ok "G4 the generator wrote nothing into the repository it read"
else bad "G4 the generator dirtied the repository it read"; fi
# No network reachable from the source: it must not contain an egress call.
if ! grep -qE '(^|[^a-z-])(curl|wget|nc|ssh|scp)[[:space:]]' "$GEN"; then
  ok "G5 the generator contains no network call — it cannot submit anywhere"
else bad "G5 the generator contains a network call"; fi

# ── H. vocabulary ────────────────────────────────────────────────────────────

echo
echo "H. VOCABULARY — proposals await review; heimdall does not auto-synthesize"
mkdir -p "$WORK/q"
cat > "$WORK/q/queue.ndjson" <<'Q'
{"proposal_id":"p1","status":"pending_review","enforced":false,"support_teams":7}
{"proposal_id":"p2","status":"pending_review","enforced":false,"support_teams":9}
{"proposal_id":"p3","status":"promoted","enforced":true,"support_teams":11}
Q
rm -rf "$OUT"
"$GEN" --repo "$REPO" --out "$OUT" $WIN --proposals "$WORK/q/queue.ndjson" >/dev/null 2>&1
hpost="$(post_file)"; hslice="$(slice_file)"
if present_in '2 proposals are awaiting review' "$hpost"; then
  ok "H1 only pending_review records are counted (2 of 3)"
else bad "H1 the pending_review count is wrong"; fi
if absent_in_i 'auto-synthesi' "$hpost" "$hslice"; then
  ok "H2 [CARDINAL] no draft ever claims heimdall auto-synthesizes rules"
else bad "H2 [CARDINAL] a draft claimed rule auto-synthesis"; fi
if present_in 'a human promotes it' "$hpost"; then
  ok "H3 the draft states rule promotion is human and out of band"
else bad "H3 the draft omits that promotion is human-reviewed"; fi
if absent_in_i 'enforced=true' "$hpost"; then
  ok "H4 no proposal is ever described as enforced"
else bad "H4 a proposal was described as enforced"; fi
# An ABSENT queue must produce no rule claim at all rather than a zero.
rm -rf "$OUT"
"$GEN" --repo "$REPO" --out "$OUT" $WIN --proposals "$WORK/q/absent.ndjson" >/dev/null 2>&1
if absent_in_i 'awaiting review' "$(post_file)"; then
  ok "H5 an unreadable queue yields NO rule claim (an untraceable number is cut)"
else bad "H5 an absent queue still produced a rule claim"; fi

echo
echo "============================================================"
echo "weekly-log-consent: $PASS passed, $FAIL failed"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1

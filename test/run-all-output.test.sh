#!/usr/bin/env bash
#
# run-all-output.test.sh — the OUTPUT CONTRACT of test/run-all.sh.
#
# WHY THIS EXISTS: run-all.sh's stdout is read by a MODEL far more often than by a
# human — every agent and every session runs the board, and the whole table lands in
# a context window each time. So the runner prints a COMPACT report by default: the
# 290-odd passing suites collapse to one counted line, and the few that are not green
# get MORE room than before, not less.
#
# That trade is only safe if the compaction is information-LOSSLESS ABOUT FAILURE. A
# runner that quietly stops printing a red would poison every downstream decision in
# this repo silently and indefinitely — every other agent trusts this output to know
# whether the tree is healthy. This suite is the gate on that: it plants each class of
# not-green suite into a THROWAWAY fixture repo and proves the compact form still
# carries it, in full, with a non-zero exit.
#
# Guarantees:
#   A. COMPACTION HAPPENED — no per-suite row for a PASSING suite on default stdout,
#      and the passing suites are still ACCOUNTED FOR as a count.
#   B. EVERY NOT-GREEN CLASS SURVIVES — FAIL, TIMEOUT, DISCREPANCY and UNPARSED each
#      keep their table row, their loud section and their reproduce command.
#   C. FAILURE DETAIL IS NEVER TRUNCATED — a red suite that prints 200 lines has all
#      200 on compact stdout. Not a head, not a tail, not an elision.
#   D. THE EXIT-CODE CONTRACT IS UNTOUCHED — red fixture exits non-zero, green fixture
#      exits 0. Compaction can never turn a red run green.
#   E. NOTHING IS ONLY-COMPACT — every run writes a full verbose log to disk, its path
#      is printed, and that log carries the per-suite rows AND every suite's own output
#      (passing ones included), so dropped detail is one grep away, never gone.
#   F. --verbose RESTORES THE FULL TABLE on stdout, and compact is measurably smaller.
#   G. THE COUNTS ARE REAL, NOT CONSTANTS — adding a suite to the fixture moves both
#      the discovered count and the collapsed pass count. An output path that printed
#      a fixed number regardless of input would be a false green; this falsifies that.
#   H. LIVE CLASSIFICATION SURVIVES — a skipped live suite keeps its name AND its
#      reason in the summary even though its table row is collapsed away.
#
# Hermetic: every assertion runs a COPY of run-all.sh inside a throwaway fixture repo
# built from scratch in a tmpdir. The real test/ tree is never read as suite input and
# never modified, so this suite cannot be slowed down or reddened by the real board.
#
# Usage:  bash test/run-all-output.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SELF_DIR/run-all.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d -t run-all-output.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "run-all-output harness  runner=$RUNNER"
echo "--------------------------------------------------------------------"

if [ ! -f "$RUNNER" ]; then
  echo "  FAIL run-all.sh not found at $RUNNER"
  printf 'run-all-output: 0 passed, 1 failed\n'
  exit 1
fi

# ── fixture builders ──────────────────────────────────────────────────────────
# A fixture repo is just a dir with test/run-all.sh + test/*.test.sh. run-all.sh
# derives REPO from its own location, so the copy globs ONLY the fixture suites.
mk_repo() {
  mkdir -p "$1/test"
  cp "$RUNNER" "$1/test/run-all.sh"
}

# A suite that passes: prints a harness line, then the parseable roll-up, exits 0.
mk_pass() {
  local dir="$1" name="$2" n="$3"
  {
    printf '%s\n' 'echo "'"$name"' harness line — only ever visible in the log"'
    printf '%s\n' 'printf '"'"'%s: %d passed, 0 failed\n'"'"' "'"$name"'" '"$n"
    printf '%s\n' 'exit 0'
  } > "$dir/test/$name.test.sh"
}

# A suite that fails LOUDLY across many lines — the anti-truncation specimen.
mk_red() {
  local dir="$1" name="$2" lines="$3"
  {
    printf '%s\n' 'i=1'
    printf '%s\n' 'while [ "$i" -le '"$lines"' ]; do printf '"'"'RED_LINE_%03d\n'"'"' "$i"; i=$((i+1)); done'
    printf '%s\n' 'printf '"'"'%s: 2 passed, 1 failed\n'"'"' "'"$name"'"'
    printf '%s\n' 'exit 1'
  } > "$dir/test/$name.test.sh"
}

# Exits 0 while printing failures — a red hiding in plain sight (DISCREPANCY).
mk_discrep() {
  local dir="$1" name="$2"
  {
    printf '%s\n' 'echo "DISCREP_MARKER an assertion failed but the suite still exits 0"'
    printf '%s\n' 'printf '"'"'%s: 1 passed, 1 failed\n'"'"' "'"$name"'"'
    printf '%s\n' 'exit 0'
  } > "$dir/test/$name.test.sh"
}

# Exits 0 with no roll-up at all — counts UNKNOWN (UNPARSED).
mk_unparsed() {
  local dir="$1" name="$2"
  {
    printf '%s\n' 'echo "UNPARSED_MARKER this suite never prints a roll-up line"'
    printf '%s\n' 'exit 0'
  } > "$dir/test/$name.test.sh"
}

# Sleeps past any sane budget — the hang specimen (TIMEOUT).
mk_hang() {
  local dir="$1" name="$2"
  {
    printf '%s\n' 'echo "HANG_MARKER about to sleep past the budget"'
    printf '%s\n' 'sleep 45'
    printf '%s\n' 'exit 0'
  } > "$dir/test/$name.test.sh"
}

logpath_of() { awk '/^log: /{print $2; exit}' "$1"; }
has()  { grep -qE "$1" "$2"; }
hasf() { grep -qF "$1" "$2"; }

# ── FIXTURE 1: one of every not-green class, plus passes and a live suite ─────
MIX="$WORK/mixed"
mk_repo "$MIX"
mk_pass     "$MIX" fx-alpha 7
mk_pass     "$MIX" fx-bravo 5
mk_pass     "$MIX" fx-charlie 3
mk_red      "$MIX" fx-red 200
mk_discrep  "$MIX" fx-discrep
mk_unparsed "$MIX" fx-unparsed
mk_hang     "$MIX" fx-hang
# classified live by basename -> skipped by default, WITH its reason
mk_pass     "$MIX" ship-npm 1

MIX_OUT="$WORK/mixed.compact.txt"
bash "$MIX/test/run-all.sh" --min 1 --jobs 4 --timeout 3 --no-retry >"$MIX_OUT" 2>&1
MIX_RC=$?

# ── Guarantee D: the exit-code contract is untouched ──────────────────────────
[ "$MIX_RC" -ne 0 ] \
  && ok "red fixture exits non-zero under compact output (rc=$MIX_RC)" \
  || bad "red fixture exited 0 — compaction turned a red run green"

# ── Guarantee A: passing suites collapsed, but still accounted for ────────────
if has '^PASS +fx-alpha\.test\.sh' "$MIX_OUT"; then
  bad "a passing suite still prints its own table row — nothing was compacted"
else
  ok "no per-suite row for a passing suite on default stdout"
fi
if has '^PASS +3 suites' "$MIX_OUT"; then
  ok "the 3 passing suites collapse to a single counted PASS line"
else
  bad "passing suites vanished without a count — they must be ACCOUNTED FOR, not dropped"
fi
# The assertions they contributed must still be in the roll-up (7+5+3 pass side).
if has '^assertions: 1[0-9] passed' "$MIX_OUT"; then
  ok "collapsed passing suites still contribute to the assertion totals"
else
  bad "assertion totals lost the collapsed suites' counts"
fi

# ── Guarantee B: every not-green class keeps its row + section ────────────────
for spec in \
  'FAIL +fx-red\.test\.sh +2 +1 |FAIL row with assertion counts (2 passed, 1 failed)' \
  'TIMEOUT +fx-hang\.test\.sh|TIMEOUT row' \
  'DISCREP +fx-discrep\.test\.sh|DISCREPANCY row' \
  'UNPARSED +fx-unparsed\.test\.sh|UNPARSED row'
do
  pat="${spec%%|*}"; label="${spec#*|}"
  has "^$pat" "$MIX_OUT" \
    && ok "compact stdout keeps the $label" \
    || bad "compact stdout DROPPED the $label — a real signal was lost"
done

for spec in \
  'FAILED \(1\)|FAILED section' \
  'TIMEOUT \(1\)|TIMEOUT section' \
  'DISCREPANCY \(1\)|DISCREPANCY section' \
  'UNPARSED \(1\)|UNPARSED section'
do
  pat="${spec%%|*}"; label="${spec#*|}"
  has "$pat" "$MIX_OUT" \
    && ok "compact stdout keeps the $label" \
    || bad "compact stdout DROPPED the $label"
done

hasf 'bash test/fx-red.test.sh' "$MIX_OUT" \
  && ok "the reproduce command for the red suite survives compaction" \
  || bad "no reproduce command for the red suite — the reader cannot re-run it"

# ── Guarantee C: failure detail is never truncated ────────────────────────────
SEEN="$(grep -c 'RED_LINE_' "$MIX_OUT")"
[ "$SEEN" -eq 200 ] \
  && ok "all 200 output lines of the failing suite are on compact stdout (no truncation)" \
  || bad "failing suite output truncated: $SEEN of 200 lines survived"
hasf 'RED_LINE_001' "$MIX_OUT" && hasf 'RED_LINE_200' "$MIX_OUT" \
  && ok "both the first and last line of the failure output are present" \
  || bad "failure output lost its head or its tail"

# The other not-green classes carry their own output too — a TIMEOUT's partial
# output is the only evidence of WHERE it hung, so it must not be swallowed.
for m in HANG_MARKER DISCREP_MARKER UNPARSED_MARKER; do
  hasf "$m" "$MIX_OUT" \
    && ok "compact stdout carries the captured output behind $m" \
    || bad "$m — this class reports a name but no evidence"
done

# A PASSING suite's chatter is the ONLY thing that may be withheld from stdout.
hasf 'fx-alpha harness line' "$MIX_OUT" \
  && bad "a passing suite's own output is still on stdout — that is the noise being cut" \
  || ok "a passing suite's own output is withheld from stdout (the saving)"

# ── Guarantee H: live classification survives ─────────────────────────────────
if has '^SKIPPED +ship-npm\.test\.sh' "$MIX_OUT"; then
  bad "the skipped suite still prints a table row AND a summary entry (duplicated)"
else
  ok "the skipped suite's duplicate table row is collapsed"
fi
hasf 'ship-npm.test.sh' "$MIX_OUT" && hasf 'release/publish path' "$MIX_OUT" \
  && ok "the skipped live suite keeps its name AND its reason in the summary" \
  || bad "a live suite was silently omitted — skipped must never mean invisible"

# ── Guarantee E: the full log exists, is printed, and is lossless ─────────────
MIX_LOG="$(logpath_of "$MIX_OUT")"
if [ -n "$MIX_LOG" ] && [ -f "$MIX_LOG" ]; then
  ok "a full log path is printed on stdout and the file exists"
  has '^PASS +fx-alpha\.test\.sh' "$MIX_LOG" \
    && ok "the log keeps the per-suite row for every passing suite" \
    || bad "the log is missing the passing suites' rows — the detail is GONE, not moved"
  hasf 'fx-alpha harness line' "$MIX_LOG" \
    && ok "the log keeps a PASSING suite's own output (grep-able detail)" \
    || bad "the log does not carry passing suites' output"
  hasf 'RED_LINE_200' "$MIX_LOG" \
    && ok "the log keeps the failing suite's output too" \
    || bad "the log dropped the failure output"
  has '^SKIPPED +ship-npm\.test\.sh' "$MIX_LOG" \
    && ok "the log keeps the skipped suite's table row" \
    || bad "the log dropped the skipped suite's row"
  if LC_ALL=C grep -q $'\033' "$MIX_LOG"; then
    bad "the log contains ANSI escapes — it must be plain text to grep cleanly"
  else
    ok "the log is plain text (no ANSI escapes) so grep/awk read it cleanly"
  fi
else
  bad "no usable log path on stdout — dropped detail would be unrecoverable"
  bad "log content unverifiable (no log file)"
  bad "log passing-suite output unverifiable (no log file)"
  bad "log failure output unverifiable (no log file)"
  bad "log skipped row unverifiable (no log file)"
  bad "log plain-text check unverifiable (no log file)"
fi

# ── Guarantee F: --verbose restores the full table, compact is smaller ────────
MIX_VERB="$WORK/mixed.verbose.txt"
bash "$MIX/test/run-all.sh" --min 1 --jobs 4 --timeout 3 --no-retry --verbose >"$MIX_VERB" 2>&1
VERB_RC=$?

[ "$VERB_RC" -ne 0 ] \
  && ok "--verbose keeps the same non-zero exit code" \
  || bad "--verbose changed the exit code — the contract must not depend on verbosity"
has '^PASS +fx-alpha\.test\.sh' "$MIX_VERB" \
  && ok "--verbose restores the per-suite row for a passing suite" \
  || bad "--verbose did not restore the full table"
has '^SKIPPED +ship-npm\.test\.sh' "$MIX_VERB" \
  && ok "--verbose restores the skipped suite's table row" \
  || bad "--verbose did not restore the skipped row"
hasf 'RED_LINE_200' "$MIX_VERB" \
  && ok "--verbose still carries the failure output in full" \
  || bad "--verbose lost the failure output"

CB="$(wc -c <"$MIX_OUT")"; VB="$(wc -c <"$MIX_VERB")"
[ "$CB" -lt "$VB" ] \
  && ok "compact stdout is smaller than --verbose ($CB < $VB bytes)" \
  || bad "compact stdout is not smaller than --verbose ($CB vs $VB bytes)"

# ── FIXTURE 2: all green — and the counts must MOVE when a suite is added ─────
GRN="$WORK/green"
mk_repo "$GRN"
mk_pass "$GRN" fx-g1 4
mk_pass "$GRN" fx-g2 4
mk_pass "$GRN" fx-g3 4
mk_pass "$GRN" fx-g4 4
mk_pass "$GRN" fx-g5 4

G1_OUT="$WORK/green.1.txt"
bash "$GRN/test/run-all.sh" --min 1 --jobs 3 >"$G1_OUT" 2>&1
G1_RC=$?

[ "$G1_RC" -eq 0 ] \
  && ok "an all-green fixture exits 0 under compact output" \
  || bad "an all-green fixture exited $G1_RC — compaction reddened a green run"
hasf 'RUN GREEN' "$G1_OUT" \
  && ok "the green verdict line survives compaction" \
  || bad "no RUN GREEN verdict on a green run"
has '^PASS +5 suites' "$G1_OUT" \
  && ok "5 passing suites collapse to one counted line" \
  || bad "the collapsed pass count is wrong or missing for the green fixture"
has 'discovered 5 suites' "$G1_OUT" \
  && ok "the discovered count is printed for the green fixture" \
  || bad "no discovered count on the green fixture"

# Add a sixth suite. Both the discovered count and the collapsed pass count must
# move. A number that does not move with its input is a false green.
mk_pass "$GRN" fx-g6 4
G2_OUT="$WORK/green.2.txt"
bash "$GRN/test/run-all.sh" --min 1 --jobs 3 >"$G2_OUT" 2>&1
G2_RC=$?

[ "$G2_RC" -eq 0 ] \
  && ok "the six-suite fixture still exits 0" \
  || bad "adding a passing suite reddened the run (rc=$G2_RC)"
has 'discovered 6 suites' "$G2_OUT" \
  && ok "adding a suite moves the DISCOVERED count 5 -> 6" \
  || bad "the discovered count did not move when a suite was added"
has '^PASS +6 suites' "$G2_OUT" \
  && ok "adding a suite moves the collapsed PASS count 5 -> 6" \
  || bad "the collapsed pass count is a constant — it did not move when a suite was added"
has '^assertions: 24 passed, 0 failed' "$G2_OUT" \
  && ok "the assertion roll-up tracks the added suite (6 x 4 = 24)" \
  || bad "the assertion roll-up did not track the added suite"

# Removing it must move the counts back down — the count follows the input BOTH ways.
rm -f "$GRN/test/fx-g6.test.sh"
G3_OUT="$WORK/green.3.txt"
bash "$GRN/test/run-all.sh" --min 1 --jobs 3 >"$G3_OUT" 2>&1
has 'discovered 5 suites' "$G3_OUT" && has '^PASS +5 suites' "$G3_OUT" \
  && ok "removing a suite moves both counts back 6 -> 5" \
  || bad "the counts did not fall when a suite was removed"

# A green run still names its log, so a passing board is greppable too.
G3_LOG="$(logpath_of "$G3_OUT")"
[ -n "$G3_LOG" ] && [ -f "$G3_LOG" ] && has '^PASS +fx-g1\.test\.sh' "$G3_LOG" \
  && ok "a green run also writes a full log carrying every passing suite's row" \
  || bad "a green run did not write a usable full log"

echo "--------------------------------------------------------------------"
printf 'run-all-output: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

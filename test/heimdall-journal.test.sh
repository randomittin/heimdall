#!/usr/bin/env bash
# heimdall-journal.test.sh — acceptance for the durable, git-committed, human-readable
# NARRATIVE log of findings/decisions/corrections/communications written DURING work.
#
# THE GAP this closes: bin/heimdall-checkpoint (CHECKPOINT.md + notes) and
# bin/lib/resume-contract.sh (resume-notes.ndjson) are the existing mechanical,
# LLM-free persistence — but resume-contract.sh's own header says its notes store
# "live[s] here, not in git" (bin/lib/resume-contract.sh: rc_home defaults to
# <repo>/.heimdall, gitignored), and its 4 categories (in_progress/gated_decisions/
# held_branches/unpushed/open_warnings/refuted_claims) carry short flat strings for a
# RESUME snapshot, not a narrative log with evidence + a finding/communication type.
# .planning/ledger/decisions.md is the closest git-committed precedent (ADR-lite,
# append-only) but is single-file/single-type/hand-curated, not sharded across
# concurrent writers. heimdall-journal fills the specific remaining gap: git-committed,
# incremental (append-the-moment-you-learn-it), one-writer-per-file (no merge
# conflicts across concurrent worktree agents), 4 typed entries with an evidence
# field, `correction`/`refuted` as first-class (most perishable, most valuable).
#
# Guarantees proved (hermetic — own temp git project per section, own HOME untouched):
#   A. HELP            — prints usage naming all subcommands, exit 0.
#   B. ADD SHAPE        — creates .planning/journal/{date}-{haid-slug}.md with a file
#                          header + a `## ts — [TYPE] subject` entry + body + **By:**;
#                          prints the file path to stdout; exit 0.
#   C. ADD COMMITS      — the append is followed by a scoped mechanical commit
#                          (git add <journal-file> only, not -A) carrying the
#                          Co-Authored-By: hmd trailer; tree is clean afterward.
#   D. NO-AUTOCOMMIT    — .heimdall-no-autocommit present: entry is still WRITTEN
#                          (durability never skipped) but NOT committed (tree dirty).
#   E. INVALID TYPE     — unknown type: exit 2, no file created, no commit.
#   F. MISSING SUBJECT  — empty subject: exit 2, no file created.
#   G. MISSING BODY     — no --body and empty stdin: exit 2, no file created.
#   H. OVERSIZED BODY   — body over the cap is REJECTED outright (not truncated):
#                          exit 2, no file created.
#   I. REFUTED ALIAS    — `add refuted ...` normalizes to [CORRECTION] in the file —
#                          the first-class correction/refuted type this exists for.
#   J. SAME-DAY APPEND  — two adds, same day + writer: ONE file header, TWO entries.
#   K. HAID OVERRIDE    — HEIMDALL_HAID selects the per-writer filename shard.
#   L. TODAY            — prints today's file content for the resolved/overridden haid.
#   M. TAIL             — returns exactly the last N entries, most-recent-last order.
#   N. GREP             — finds a planted string across journal files, file:line shape.
#   O. PATH             — computes the deterministic path without requiring the file
#                          to exist (--date/--haid override both honored).
#   P. EVIDENCE LINE    — --evidence renders a **Evidence:** line in the entry.
#   Q. ALL FOUR TYPES   — finding/decision/correction/communication all accepted.
#   R. SYNTAX           — bash -n clean.
#
# Falsifiability (quoted in the implementing commit): the type-validation branch was
# temporarily mutated to accept any string, which turned section E red (bad type no
# longer rejected, file created when it should not have been) with the exact expected
# wrong behavior, then reverted back to green. Counts quoted both ways in the commit.
#
# Usage: bash test/heimdall-journal.test.sh   (exit 0 = all hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
JRNL="$REPO/bin/heimdall-journal"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

make_project() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'hello\n' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm "initial commit" --no-verify
  printf '%s' "$d"
}

ncommits() { git -C "$1" log --oneline 2>/dev/null | wc -l | tr -d ' '; }
dirty_count() { git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '; }

# A writer identity that needs no real heimdall-haid resolution (tests run outside
# any HAID-registered checkout) — HEIMDALL_HAID is the existing override convention
# (bin/heimdall-activity:148-150), reused verbatim rather than inventing a new var.
W="haid:test.writer-0001"

# ─────────────────────────────────────────────────────────────────────────────
echo "A. HELP — usage names all subcommands, exit 0:"
OUT="$("$JRNL" help 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "help exits 0" || bad "help exit=$RC"
ALL_NAMED=1
for word in add today tail grep path; do
  printf '%s' "$OUT" | grep -q "$word" || ALL_NAMED=0
done
[ "$ALL_NAMED" -eq 1 ] && ok "usage names add/today/tail/grep/path" || bad "usage missing a subcommand:
$OUT"

# ─────────────────────────────────────────────────────────────────────────────
echo "B. ADD SHAPE — file header + entry header + body + By:, path printed:"
P="$(make_project)"
FILE="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "pyenv shim adds ~400ms" --body "bare python3 goes through the pyenv shim; statusline 2.35-4.09s before, 0.53-0.96s after pointing at the real interpreter." --evidence "measured via hyperfine, n=20")"
RC=$?
[ "$RC" -eq 0 ] && ok "add exits 0" || bad "add exit=$RC"
[ -f "$FILE" ] && ok "printed path exists on disk: $FILE" || bad "printed path does not exist: $FILE"
case "$FILE" in *".planning/journal/"*"-haid_test.writer-0001.md") ok "path shaped {date}-{haid-slug}.md under .planning/journal/" ;; *) bad "unexpected path shape: $FILE" ;; esac
grep -q "^# Journal — " "$FILE" && ok "file header present" || bad "missing file header"
grep -Eq '^## [0-9T:Z-]+ — \[FINDING\] pyenv shim adds ~400ms$' "$FILE" && ok "entry header shaped correctly" || bad "entry header wrong shape:
$(cat "$FILE")"
grep -q "0.53-0.96s after" "$FILE" && ok "body text present" || bad "body text missing"
grep -q "^\*\*By:\*\* $W$" "$FILE" && ok "By: attribution present" || bad "By: attribution missing"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "C. ADD COMMITS — scoped mechanical commit, Co-Authored-By trailer, tree clean:"
P="$(make_project)"
BEFORE="$(ncommits "$P")"
FILE="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add decision "extend, do not compete" --body "resume-contract.sh notes are explicitly not-in-git; build an additive tool instead of bending checkpoint's shape to fit.")"
AFTER="$(ncommits "$P")"
[ "$AFTER" -eq $((BEFORE + 1)) ] && ok "exactly one new commit landed" || bad "commit count before=$BEFORE after=$AFTER"
SUBJ="$(git -C "$P" log -1 --format=%s)"
case "$SUBJ" in "journal: [DECISION]"*) ok "commit subject carries type: $SUBJ" ;; *) bad "unexpected subject: $SUBJ" ;; esac
git -C "$P" log -1 --format=%b | grep -q "Co-Authored-By: hmd <hmd@runheimdall.dev>" && ok "Co-Authored-By trailer present" || bad "trailer missing"
CHANGED="$(git -C "$P" diff --name-only HEAD~1 HEAD)"
[ "$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')" -eq 1 ] && ok "commit touched exactly one file (scoped add, not -A): $CHANGED" || bad "commit touched more than the journal file: $CHANGED"
[ "$(dirty_count "$P")" -eq 0 ] && ok "tree clean after commit" || bad "tree still dirty after commit"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "D. NO-AUTOCOMMIT — entry still WRITTEN, but not committed:"
P="$(make_project)"
touch "$P/.heimdall-no-autocommit"
BEFORE="$(ncommits "$P")"
FILE="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "no-autocommit path" --body "durability (the append) must never be skipped even when the commit side-effect is opted out.")"
AFTER="$(ncommits "$P")"
[ -f "$FILE" ] && grep -q "no-autocommit path" "$FILE" && ok "entry written to disk despite no-autocommit" || bad "entry missing on disk"
[ "$AFTER" -eq "$BEFORE" ] && ok "no commit created (no-autocommit respected)" || bad "commit fired despite .heimdall-no-autocommit"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "E. INVALID TYPE — rejected outright, nothing written or committed:"
P="$(make_project)"
BEFORE="$(ncommits "$P")"
OUT="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add bogus-type "x" --body "y" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "exit 2 on invalid type" || bad "exit=$RC (want 2)"
printf '%s' "$OUT" | grep -qi "invalid type" && ok "clear error message: $OUT" || bad "unclear error: $OUT"
[ -d "$P/.planning/journal" ] && bad "journal dir created despite rejection" || ok "no journal dir created"
[ "$(ncommits "$P")" -eq "$BEFORE" ] && ok "no commit created" || bad "commit fired despite invalid type"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "F. MISSING SUBJECT — rejected, exit 2:"
P="$(make_project)"
OUT="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "" --body "y" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "exit 2 on empty subject" || bad "exit=$RC (want 2): $OUT"
[ -d "$P/.planning/journal" ] && bad "journal dir created despite missing subject" || ok "no journal dir created"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "G. MISSING BODY — no --body, empty stdin: rejected, exit 2:"
P="$(make_project)"
OUT="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "no body given" < /dev/null 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "exit 2 on missing body" || bad "exit=$RC (want 2): $OUT"
[ -d "$P/.planning/journal" ] && bad "journal dir created despite missing body" || ok "no journal dir created"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "H. OVERSIZED BODY — rejected outright (not silently truncated):"
P="$(make_project)"
BIG="$(printf 'x%.0s' $(seq 1 5000))"
OUT="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "too big" --body "$BIG" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "exit 2 on oversized body" || bad "exit=$RC (want 2)"
[ -d "$P/.planning/journal" ] && bad "journal dir created despite oversized body" || ok "no journal dir / no partial write created"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "I. REFUTED ALIAS — normalizes to [CORRECTION], the first-class type:"
P="$(make_project)"
FILE="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add refuted "headroom link to token-spend-forensics" --body "sibling agent measured token-spend-forensics.md is entirely innocent of any headroom link (100% context-lifecycle) — hmd's earlier claim tying the cost delta to headroom was wrong." --evidence "sibling agent measurement, token-spend-forensics.md content audit")"
grep -q "\[CORRECTION\] headroom link" "$FILE" && ok "refuted normalized to [CORRECTION] in the file" || bad "alias did not normalize:
$(cat "$FILE" 2>/dev/null)"
grep -qi "\[REFUTED\]" "$FILE" && bad "raw REFUTED leaked into the file (should be CORRECTION)" || ok "no raw REFUTED tag leaked"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "J. SAME-DAY APPEND — one writer, one day, two adds: one header, two entries:"
P="$(make_project)"
F1="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "first-entry" --body "body one")"
F2="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "second-entry" --body "body two")"
[ "$F1" = "$F2" ] && ok "both adds resolved to the same file" || bad "file path drifted: $F1 vs $F2"
[ "$(grep -c '^# Journal — ' "$F1")" -eq 1 ] && ok "exactly one file header (not duplicated on 2nd add)" || bad "file header duplicated"
[ "$(grep -c '^## ' "$F1")" -eq 2 ] && ok "exactly two entry headers accumulated" || bad "entry count wrong: $(grep -c '^## ' "$F1")"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "K. HAID OVERRIDE — HEIMDALL_HAID selects the per-writer filename shard:"
P="$(make_project)"
FA="$(cd "$P" && HEIMDALL_HAID="haid:writer.a" "$JRNL" add finding "from A" --body "a")"
FB="$(cd "$P" && HEIMDALL_HAID="haid:writer.b" "$JRNL" add finding "from B" --body "b")"
[ "$FA" != "$FB" ] && ok "different HEIMDALL_HAID values shard into different files" || bad "both writers collided into one file"
printf '%s' "$FA" | grep -q "writer.a" && ok "writer A slug reflected in filename" || bad "writer A slug missing from: $FA"
printf '%s' "$FB" | grep -q "writer.b" && ok "writer B slug reflected in filename" || bad "writer B slug missing from: $FB"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "L. TODAY — prints today's file content for the resolved haid:"
P="$(make_project)"
( cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "today-marker-entry" --body "body for today test" ) >/dev/null
OUT="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" today)"
printf '%s' "$OUT" | grep -q "today-marker-entry" && ok "today prints the entry just added" || bad "today missing the entry:
$OUT"
OUT2="$(cd "$P" && HEIMDALL_HAID="haid:nobody.here" "$JRNL" today)"
[ -z "$OUT2" ] && ok "today for a writer with no entries prints nothing (not an error)" || bad "today printed unexpected content: $OUT2"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "M. TAIL — exactly the last N entries, most-recent-last:"
P="$(make_project)"
( cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "tail-first" --body "1" ) >/dev/null
( cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "tail-second" --body "2" ) >/dev/null
( cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "tail-third" --body "3" ) >/dev/null
OUT="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" tail 2)"
printf '%s' "$OUT" | grep -q "tail-second" && printf '%s' "$OUT" | grep -q "tail-third" \
  && ok "tail 2 contains the last two entries" || bad "tail 2 missing an expected entry:
$OUT"
printf '%s' "$OUT" | grep -q "tail-first" && bad "tail 2 leaked the older 3rd-from-last entry" || ok "tail 2 correctly excludes the older entry"
LAST_LINE_ENTRY="$(printf '%s' "$OUT" | grep '^## ' | tail -1)"
printf '%s' "$LAST_LINE_ENTRY" | grep -q "tail-third" && ok "most recent entry is last in output order" || bad "ordering wrong, last header: $LAST_LINE_ENTRY"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "N. GREP — finds a planted string across journal files, file:line shape:"
P="$(make_project)"
( cd "$P" && HEIMDALL_HAID="haid:writer.a" "$JRNL" add finding "grep-target-alpha" --body "unique-needle-xyz here" ) >/dev/null
( cd "$P" && HEIMDALL_HAID="haid:writer.b" "$JRNL" add decision "unrelated" --body "nothing to see" ) >/dev/null
OUT="$(cd "$P" && "$JRNL" grep "unique-needle-xyz")"; RC=$?
[ "$RC" -eq 0 ] && ok "grep exits 0 on a match" || bad "grep exit=$RC on a match"
printf '%s' "$OUT" | grep -q "unique-needle-xyz" && ok "grep found the planted needle" || bad "grep missed the needle:
$OUT"
case "$OUT" in *:*:*) ok "output is file:line:content shaped" ;; *) bad "output not file:line shaped: $OUT" ;; esac
printf '%s' "$OUT" | grep -q "writer.a" && ok "match attributed to the writer.a shard file" || bad "wrong shard matched"
OUT2="$(cd "$P" && "$JRNL" grep "no-such-string-anywhere")"; RC2=$?
[ "$RC2" -ne 0 ] && ok "grep exits nonzero on no match (real grep semantics passthrough)" || bad "grep exit=$RC2 on no match (want nonzero)"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "O. PATH — deterministic, does not require the file to exist:"
P="$(make_project)"
OUT="$(cd "$P" && "$JRNL" path --date 2020-01-01 --haid "haid:fixed.one")"
case "$OUT" in *".planning/journal/2020-01-01-haid_fixed.one.md") ok "path computed deterministically: $OUT" ;; *) bad "unexpected path: $OUT" ;; esac
[ -f "$OUT" ] && bad "path subcommand unexpectedly created the file" || ok "path does not create the file"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "P. EVIDENCE LINE — --evidence renders a **Evidence:** line:"
P="$(make_project)"
FILE="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add finding "with evidence" --body "body text" --evidence "npm test exit 0, 47 passing")"
grep -q "^\*\*Evidence:\*\* npm test exit 0, 47 passing$" "$FILE" && ok "Evidence line rendered" || bad "Evidence line missing/malformed:
$(cat "$FILE")"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "Q. ALL FOUR TYPES — finding/decision/correction/communication all accepted:"
P="$(make_project)"
ALL_OK=1
for t in finding decision correction communication; do
  F="$(cd "$P" && HEIMDALL_HAID="$W" "$JRNL" add "$t" "type-$t" --body "body for $t")" || ALL_OK=0
  U="$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')"
  grep -q "\[$U\] type-$t" "$F" 2>/dev/null || ALL_OK=0
done
[ "$ALL_OK" -eq 1 ] && ok "all four canonical types accepted and tagged correctly" || bad "one or more types failed"
rm -rf "$P"

# ─────────────────────────────────────────────────────────────────────────────
echo "R. SYNTAX — bash -n clean on heimdall-journal:"
bash -n "$JRNL" && ok "bash -n clean" || bad "syntax error in $JRNL"

echo ""
echo "heimdall-journal.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

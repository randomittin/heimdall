#!/usr/bin/env bash
# test/heimdall-debloat-report.test.sh — acceptance for the `report` subcommand and
# the shareable BLOAT SCORECARD card added to heimdall-debloat.
#
# Hermetic: no model call, no network, no token spend. Every assertion runs the real
# bin over throwaway git repos, or drives the extracted card renderer with controlled
# scorer inputs so the glyph/verdict logic is exercised without depending on which
# analysis tools happen to be installed.
#
# Asserted:
#   (a) `heimdall-debloat report` exits 0, writes BLOAT-REPORT.md, and prints a card
#       with ALL 5 axes (dead exports, duplication, complexity, dependency creep,
#       LOC budget) + an overall VERDICT line + the repo name.
#   (b) `report [<path>]` accepts a leading positional path (sugar for --repo).
#   (c) an axis whose tool is ABSENT shows "skipped: needs <tool>" — never a faked
#       number (honest gap). Forced via a minimal PATH so the result is deterministic.
#   (d) pipe / CI mode is ANSI-clean: the card printed to a non-tty carries zero raw
#       escape sequences (mirrors summary-card's non-tty detection).
#   (e) legacy back-compat: `--report-only` still writes BLOAT-REPORT.md, exits 0, and
#       makes NO tracked source change; and it does NOT print the card when piped.
#   (f) falsifier (real numbers, honest glyphs): the extracted renderer, fed a MEASURED
#       axis, shows the real value + a ✓/⚠/✗ glyph and never says "skipped"; a heavy
#       axis grades ✗/BLOATED; a clean run grades ✓/LEAN. Proves the card reflects the
#       gate data rather than hardcoding either a pass or a skip.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DEB="$ROOT/bin/heimdall-debloat"
BG="$ROOT/bin/bloat-gate"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required"  >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
[ -x "$DEB" ] || { echo "FATAL: heimdall-debloat not executable at $DEB" >&2; exit 2; }
[ -x "$BG"  ] || { echo "FATAL: bloat-gate not executable at $BG"      >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

mkrepo() { local name="$1"; local d="$WORK/$name"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email a@b.c && git config user.name t )
  printf 'export const a = 1;\nexport const b = 2;\n' > "$d/s.js"
  ( cd "$d" && git add -A && git commit -qm init ) >/dev/null 2>&1
  printf '%s' "$d"; }

ESC=$'\033'

# ── (a) `report` exits 0, writes BLOAT-REPORT.md, prints the full card ─────────
A_REPO="$(mkrepo alpha)"
set +e
"$DEB" report "$A_REPO" >"$WORK/a.card" 2>"$WORK/a.err"; A_RC=$?
set -e
A_HAS_MD=0; [ -f "$A_REPO/BLOAT-REPORT.md" ] && A_HAS_MD=1
A_AXES=0
for lbl in "Dead exports" "Duplication" "Complexity" "Dependency creep" "LOC budget"; do
  grep -qF "$lbl" "$WORK/a.card" && A_AXES=$((A_AXES+1))
done
A_HAS_TITLE=0; grep -qF "BLOAT SCORECARD" "$WORK/a.card" && A_HAS_TITLE=1
A_HAS_VERDICT=0; grep -qE 'VERDICT:' "$WORK/a.card" && A_HAS_VERDICT=1
A_HAS_REPO=0; grep -qF "repo: $(basename "$A_REPO")" "$WORK/a.card" && A_HAS_REPO=1
if [ "$A_RC" -eq 0 ] && [ "$A_HAS_MD" = 1 ] && [ "$A_AXES" -eq 5 ] \
   && [ "$A_HAS_TITLE" = 1 ] && [ "$A_HAS_VERDICT" = 1 ] && [ "$A_HAS_REPO" = 1 ]; then
  ok "(a) report: exit 0, BLOAT-REPORT.md written, card has 5 axes + title + VERDICT + repo name"
else
  bad "(a) report card incomplete (rc=$A_RC md=$A_HAS_MD axes=$A_AXES/5 title=$A_HAS_TITLE verdict=$A_HAS_VERDICT repo=$A_HAS_REPO)"
fi

# ── (b) leading positional <path> is honored (sugar for --repo) ───────────────
# The card names the repo by basename; running `report <path>` from a DIFFERENT cwd
# must still score <path>, not the cwd.
B_REPO="$(mkrepo bravo)"
set +e
( cd / && "$DEB" report "$B_REPO" ) >"$WORK/b.card" 2>/dev/null; B_RC=$?
set -e
if [ "$B_RC" -eq 0 ] && grep -qF "repo: $(basename "$B_REPO")" "$WORK/b.card" \
   && [ -f "$B_REPO/BLOAT-REPORT.md" ]; then
  ok "(b) report <path>: positional path scored (repo name = $(basename "$B_REPO")), report written there"
else
  bad "(b) positional path not honored (rc=$B_RC)"
fi

# ── (c) honest skip: an absent tool => "skipped: needs <tool>", never a fake number
# Force a minimal PATH that deliberately EXCLUDES the dead-code tools (ts-prune /
# knip / vulture), so the dead-exports axis MUST honest-skip regardless of what the
# host has installed.
NOBIN="$WORK/nobin"; mkdir -p "$NOBIN"
for t in git jq awk sed grep wc date mktemp cat sort paste head tail tr cp mv \
         dirname basename mkdir rm rmdir bash sh env printf ln find readlink \
         xargs cut comm diff stat tee touch expr; do
  p="$(command -v "$t" 2>/dev/null || true)"; [ -n "$p" ] && ln -sf "$p" "$NOBIN/$t" 2>/dev/null || true
done
C_REPO="$(mkrepo charlie)"
set +e
PATH="$NOBIN" "$DEB" report "$C_REPO" >"$WORK/c.card" 2>"$WORK/c.err"; C_RC=$?
set -e
# The dead-exports axis line must read a skip-with-tool, and must NOT carry a
# fabricated "N dead export(s)" count.
C_DEAD_LINE="$(grep -F 'Dead exports' "$WORK/c.card" || true)"
if [ "$C_RC" -eq 0 ] \
   && grep -qE 'skipped: needs ' <<<"$C_DEAD_LINE" \
   && ! grep -qE 'dead export\(s\)' <<<"$C_DEAD_LINE"; then
  ok "(c) absent tool honest-skips: dead-exports axis reads 'skipped: needs ...', no faked count"
else
  bad "(c) axis did not honest-skip under minimal PATH (rc=$C_RC line='$C_DEAD_LINE')"
fi

# ── (d) pipe / CI mode is ANSI-clean ──────────────────────────────────────────
# The card in (a) was written to a file (non-tty). It must carry ZERO escape bytes.
if grep -qF "BLOAT SCORECARD" "$WORK/a.card" && ! grep -q "$ESC" "$WORK/a.card"; then
  ok "(d) piped card is ANSI-clean (renders in a pipe with zero raw escape sequences)"
else
  bad "(d) piped card leaked ANSI escapes (or card missing)"
fi

# ── (e) legacy --report-only: unchanged, zero-risk, and NO card when piped ────
E_REPO="$(mkrepo echo)"
E_SHA="$(git -C "$E_REPO" rev-parse HEAD)"
set +e
"$DEB" --report-only --repo "$E_REPO" >"$WORK/e.out" 2>/dev/null; E_RC=$?
set -e
E_DIRTY="$(git -C "$E_REPO" status --porcelain --untracked-files=no)"
E_HAS_CARD=0; grep -qF "BLOAT SCORECARD" "$WORK/e.out" && E_HAS_CARD=1
if [ "$E_RC" -eq 0 ] && [ -f "$E_REPO/BLOAT-REPORT.md" ] \
   && [ -z "$E_DIRTY" ] && [ "$(git -C "$E_REPO" rev-parse HEAD)" = "$E_SHA" ] \
   && [ "$E_HAS_CARD" = 0 ]; then
  ok "(e) legacy --report-only intact: report written, tree clean, HEAD untouched, no card when piped"
else
  bad "(e) --report-only regressed (rc=$E_RC dirty='$E_DIRTY' card_when_piped=$E_HAS_CARD)"
fi

# ── (f) falsifier: extracted renderer proves real numbers + honest glyphs ──────
# Drive print_scorecard_card directly with controlled SC_* scorer values (exactly how
# the bin sets them from bloat-gate). Non-tty => plain text, easy to assert.
render_card() { # sets SC_* / CAND_TOTAL / SC_LOC / REPO via the caller's env
  bash -c '
    eval "$(sed -n "/^print_scorecard_card()/,/^}/p" "'"$DEB"'")"
    print_scorecard_card
  '
}

# f1: a fully-MEASURED, clean run — real values, all ✓, verdict LEAN, never "skipped".
CLEAN_CARD="$(
  SC_DEAD_STATUS=ran SC_DEAD_COUNT=0 SC_DEAD_TOOL=ts-prune \
  SC_DUP_STATUS=ran SC_DUP_PCT=1.2 \
  SC_CC_STATUS=ran SC_CC_MAX=5 \
  SC_DEP_STATUS=ran SC_DEP_NEW=0 \
  SC_LOC=100 CAND_TOTAL=0 REPO="$WORK/alpha" render_card
)"
if grep -qF '0 dead export(s)' <<<"$CLEAN_CARD" \
   && grep -qF '1.2% duplicated' <<<"$CLEAN_CARD" \
   && grep -qF 'max cyclomatic 5' <<<"$CLEAN_CARD" \
   && grep -qF '100 LOC, ~0 removable' <<<"$CLEAN_CARD" \
   && grep -qF '✓' <<<"$CLEAN_CARD" \
   && grep -qE 'VERDICT: LEAN' <<<"$CLEAN_CARD" \
   && ! grep -qF 'skipped' <<<"$CLEAN_CARD"; then
  ok "(f1) measured+clean run: real values shown, ✓ glyphs, VERDICT LEAN, zero 'skipped'"
else
  bad "(f1) measured/clean card wrong:\n$CLEAN_CARD"
fi

# f2: a heavy dead-code axis grades ✗ and the verdict is BLOATED (falsifies a card
# that always greens).
HEAVY_CARD="$(
  SC_DEAD_STATUS=ran SC_DEAD_COUNT=50 SC_DEAD_TOOL=ts-prune \
  SC_DUP_STATUS=ran SC_DUP_PCT=1.0 \
  SC_CC_STATUS=ran SC_CC_MAX=3 \
  SC_DEP_STATUS=ran SC_DEP_NEW=0 \
  SC_LOC=100 CAND_TOTAL=0 REPO="$WORK/alpha" render_card
)"
if grep -qF '50 dead export(s)' <<<"$HEAVY_CARD" \
   && grep -qF '✗' <<<"$HEAVY_CARD" \
   && grep -qE 'VERDICT: BLOATED' <<<"$HEAVY_CARD"; then
  ok "(f2) heavy dead-code axis grades ✗ and verdict BLOATED (card is not always-green)"
else
  bad "(f2) heavy card did not grade ✗/BLOATED:\n$HEAVY_CARD"
fi

# f3: an all-skipped run is honestly INCONCLUSIVE (not a fake pass) — proves a skip
# never masquerades as ✓.
SKIP_CARD="$(
  SC_DEAD_STATUS=skipped SC_DEAD_TOOL=none \
  SC_DUP_STATUS=skipped SC_DUP_PCT=null \
  SC_CC_STATUS=skipped \
  SC_DEP_STATUS=n/a \
  SC_LOC=100 CAND_TOTAL=0 REPO="$WORK/alpha" render_card
)"
if grep -qF 'skipped: needs ts-prune/knip/vulture' <<<"$SKIP_CARD" \
   && grep -qE 'VERDICT: INCONCLUSIVE' <<<"$SKIP_CARD" \
   && ! grep -qF '✓' <<<"$SKIP_CARD"; then
  ok "(f3) all-skipped run: honest 'skipped: needs <tool>' + VERDICT INCONCLUSIVE, no fake ✓"
else
  bad "(f3) all-skipped card not honest:\n$SKIP_CARD"
fi

echo
echo "  heimdall-debloat-report tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

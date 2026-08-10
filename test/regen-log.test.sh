#!/usr/bin/env bash
#
# regen-log.test.sh — deterministic harness for the designmatch v2 hash-log +
# change-detection + provenance ledger (bin/lib/regen_log.py via the thin CLI
# bin/designmatch-regen-log).
#
# This module is the change-detection GATE and the provenance RECORD in one: a
# content-hash ledger mapping  design_hash → screen → generated_output. A screen
# regenerates ONLY when its canonical's content hash changes; an unchanged hash
# is a no-op (so we never churn behavior on screens whose design did not move).
#
# Proofs (all runnable, none skippable):
#   (a) NEW screen → `changed` reports CHANGED (regenerate)            [the trigger]
#   (b) `record` it, then `changed` with the SAME canonical → UNCHANGED [the gate]
#   (c) MODIFY the canonical (real content change) → CHANGED again     [re-trigger]
#   (d) trivial reformat (trailing-whitespace only) → UNCHANGED        [no churn]
#   (e) `provenance <screen>` returns the right canonical+hash+output  [provenance]
#   (f) ledger survives a simulated mid-write (atomic temp+rename:
#       a crash during write leaves the OLD ledger intact, never a partial)
#   + the ledger is valid JSON (`jq -e .`) throughout.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO/bin/designmatch-regen-log"
LIB="$REPO/bin/lib/regen_log.py"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$CLI" ] || { echo "FATAL: CLI not executable at $CLI"; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: lib missing at $LIB"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found (required for ledger validity proof)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LEDGER="$WORK/.designmatch/regen-log.json"
CANON="$WORK/Login.canonical.html"
GENOUT="$WORK/Login.tsx"
SCREEN="Login"

# Every CLI call points at the WORK ledger via --ledger so the test never touches
# a real .designmatch dir. Helper captures stdout+exit code with NO unguarded
# pipeline (captured exit codes — landmine-clean test too).
run() {
  # run SUBCOMMAND ARGS...  -> sets RUN_OUT, RUN_RC
  RUN_OUT="$("$CLI" --ledger "$LEDGER" "$@" 2>&1)"
  RUN_RC=$?
}

jq_valid() {
  # jq_valid FILE LABEL  -> assert FILE parses as JSON
  if jq -e . "$1" >/dev/null 2>&1; then
    ok "ledger is valid JSON ($2)"
  else
    bad "ledger is NOT valid JSON ($2)"
  fi
}

# Initial canonical content (trailing newline; no trailing-whitespace yet).
printf 'BUTTON\nlabel: Sign in\ncolor: blue\n' > "$CANON"
printf 'export const Login = () => null;\n' > "$GENOUT"

echo "regen-log.test.sh — hash-log change-detection + provenance ledger"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Tolerant of a missing ledger: `changed` on a brand-new screen with NO ledger
# yet must work (first run creates nothing on a read; record creates the file).
# ─────────────────────────────────────────────────────────────────────────────
echo "(a) NEW screen → changed = CHANGED (regenerate):"
run changed "$SCREEN" "$CANON"
if [ "$RUN_RC" -eq 0 ] && grep -qi 'changed' <<<"$RUN_OUT"; then
  ok "new screen reports changed (rc=0, out='$RUN_OUT')"
else
  bad "new screen should report changed (rc=$RUN_RC, out='$RUN_OUT')"
fi

# The hash command must emit a stable, real content hash.
run hash "$CANON"
H1="$RUN_OUT"
if [ "$RUN_RC" -eq 0 ] && grep -qE '^sha256:[0-9a-f]{64}$' <<<"$H1"; then
  ok "hash emits a sha256 content hash ($H1)"
else
  bad "hash should emit sha256:<64 hex> (rc=$RUN_RC, out='$H1')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "(b) record, then changed with the SAME canonical → UNCHANGED (no-op gate):"
run record "$SCREEN" "$CANON" "$GENOUT"
if [ "$RUN_RC" -eq 0 ]; then ok "record upserts the ledger entry (rc=0)"; \
  else bad "record failed (rc=$RUN_RC, out='$RUN_OUT')"; fi
jq_valid "$LEDGER" "after record"

run changed "$SCREEN" "$CANON"
if [ "$RUN_RC" -ne 0 ] && grep -qi 'unchanged' <<<"$RUN_OUT"; then
  ok "recorded + same canonical reports UNCHANGED (rc=$RUN_RC, out='$RUN_OUT') — no churn"
else
  bad "same canonical after record should be unchanged (rc=$RUN_RC, out='$RUN_OUT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "(c) MODIFY canonical (real content change) → CHANGED again:"
printf 'BUTTON\nlabel: Log in\ncolor: green\n' > "$CANON"   # real change
run hash "$CANON"
H2="$RUN_OUT"
if [ "$H2" != "$H1" ]; then ok "real content change changes the hash ($H1 -> $H2)"; \
  else bad "real content change did NOT change the hash (still $H2)"; fi
run changed "$SCREEN" "$CANON"
if [ "$RUN_RC" -eq 0 ] && grep -qi 'changed' <<<"$RUN_OUT"; then
  ok "modified canonical reports CHANGED again (rc=0, out='$RUN_OUT')"
else
  bad "modified canonical should report changed (rc=$RUN_RC, out='$RUN_OUT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "(d) trivial reformat (trailing whitespace only) → UNCHANGED (no churn):"
# Re-record at the current (modified) content, then re-write the SAME content but
# with trailing whitespace + CRLF added to each line — a no-op reformat.
run record "$SCREEN" "$CANON" "$GENOUT"
[ "$RUN_RC" -eq 0 ] && ok "re-record at modified content (rc=0)" || bad "re-record failed (rc=$RUN_RC)"
# Same logical content, trailing spaces + tabs + CRLF appended per line.
printf 'BUTTON   \t\r\nlabel: Log in \r\ncolor: green\t\r\n\n\n' > "$CANON"
run hash "$CANON"
H3="$RUN_OUT"
if [ "$H3" = "$H2" ]; then
  ok "trailing-whitespace/CRLF reformat keeps the SAME hash ($H3) — normalization strips it"
else
  bad "trivial reformat changed the hash ($H2 -> $H3) — would churn unchanged screen"
fi
run changed "$SCREEN" "$CANON"
if [ "$RUN_RC" -ne 0 ] && grep -qi 'unchanged' <<<"$RUN_OUT"; then
  ok "reformatted-only canonical reports UNCHANGED (rc=$RUN_RC) — no regeneration"
else
  bad "reformatted-only canonical should be unchanged (rc=$RUN_RC, out='$RUN_OUT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "(e) provenance returns the right canonical + hash + generated-output:"
run provenance "$SCREEN"
PROV="$RUN_OUT"
if [ "$RUN_RC" -ne 0 ]; then
  bad "provenance failed (rc=$RUN_RC, out='$PROV')"
else
  ok "provenance returns rc=0"
  # provenance emits JSON; assert each field via jq against the emitted object.
  GOT_HASH="$(printf '%s' "$PROV" | jq -r '.design_hash' 2>/dev/null || true)"
  GOT_CANON="$(printf '%s' "$PROV" | jq -r '.canonical_path' 2>/dev/null || true)"
  GOT_GEN="$(printf '%s' "$PROV" | jq -r '.generated_output' 2>/dev/null || true)"
  [ "$GOT_HASH" = "$H2" ] && ok "provenance hash matches recorded ($GOT_HASH)" \
    || bad "provenance hash wrong (got '$GOT_HASH', want '$H2')"
  [ "$GOT_CANON" = "$CANON" ] && ok "provenance canonical_path matches ($GOT_CANON)" \
    || bad "provenance canonical_path wrong (got '$GOT_CANON', want '$CANON')"
  [ "$GOT_GEN" = "$GENOUT" ] && ok "provenance generated_output matches ($GOT_GEN)" \
    || bad "provenance generated_output wrong (got '$GOT_GEN', want '$GENOUT')"
fi

# `list` must enumerate the recorded screen.
run list
if [ "$RUN_RC" -eq 0 ] && grep -q "$SCREEN" <<<"$RUN_OUT"; then
  ok "list enumerates the recorded screen"
else
  bad "list should enumerate the recorded screen (rc=$RUN_RC, out='$RUN_OUT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "(f) ledger survives a simulated mid-write (atomic temp+rename):"
# Capture the current (good) ledger bytes. Then drive a write that we ABORT
# mid-flight via the test-only env hook DESIGNMATCH_REGEN_CRASH_BEFORE_RENAME=1:
# the module writes the new content to a temp file, then (with the hook set)
# raises BEFORE the os.replace. The original ledger must be byte-identical and
# still jq-valid; no temp file may be left where the ledger is.
BEFORE_BYTES="$(jq -cS . "$LEDGER")"
DESIGNMATCH_REGEN_CRASH_BEFORE_RENAME=1 "$CLI" --ledger "$LEDGER" \
  record "Crash" "$CANON" "$GENOUT" >/dev/null 2>&1
CRASH_RC=$?
if [ "$CRASH_RC" -ne 0 ]; then
  ok "interrupted write exits nonzero (rc=$CRASH_RC) — crash simulated"
else
  bad "interrupted write should exit nonzero (rc=$CRASH_RC)"
fi
jq_valid "$LEDGER" "after simulated crash"
AFTER_BYTES="$(jq -cS . "$LEDGER")"
if [ "$BEFORE_BYTES" = "$AFTER_BYTES" ]; then
  ok "OLD ledger is byte-identical after the crash (atomic rename — no partial write)"
else
  bad "ledger CHANGED after a crash mid-write (partial/corrupt write leaked)"
fi
# The crashed screen must NOT be in the ledger (the write never landed).
run provenance "Crash"
if [ "$RUN_RC" -ne 0 ]; then
  ok "crashed screen 'Crash' is absent from the ledger (write never committed)"
else
  bad "crashed screen leaked into the ledger (out='$RUN_OUT')"
fi
# No stray temp file left next to the ledger.
LEDGER_DIR="$(dirname "$LEDGER")"
STRAY="$(find "$LEDGER_DIR" -name 'regen-log.json.*' 2>/dev/null | head -1 || true)"
if [ -z "$STRAY" ]; then
  ok "no stray temp file left beside the ledger after the crash"
else
  bad "stray temp file left after the crash: $STRAY"
fi

# ─────────────────────────────────────────────────────────────────────────────
# First-run tolerance: a `changed` against a FRESH (never-created) ledger path
# must treat the screen as new (changed), not crash on a missing file.
echo "(extra) missing/empty ledger tolerance:"
FRESH="$WORK/fresh/sub/regen-log.json"
FRESH_OUT="$("$CLI" --ledger "$FRESH" changed "$SCREEN" "$CANON" 2>&1)"
FRESH_RC=$?
if [ "$FRESH_RC" -eq 0 ] && grep -qi 'changed' <<<"$FRESH_OUT"; then
  ok "changed against a never-created ledger treats screen as new (no crash)"
else
  bad "missing-ledger changed should report changed (rc=$FRESH_RC, out='$FRESH_OUT')"
fi
# An EMPTY ledger file must be tolerated too (truncated/0-byte from a prior crash).
EMPTY="$WORK/empty/regen-log.json"
mkdir -p "$(dirname "$EMPTY")"; : > "$EMPTY"
EMPTY_OUT="$("$CLI" --ledger "$EMPTY" changed "$SCREEN" "$CANON" 2>&1)"
EMPTY_RC=$?
if [ "$EMPTY_RC" -eq 0 ] && grep -qi 'changed' <<<"$EMPTY_OUT"; then
  ok "changed against an empty (0-byte) ledger treats screen as new (no crash)"
else
  bad "empty-ledger changed should report changed (rc=$EMPTY_RC, out='$EMPTY_OUT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "regen-log.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0

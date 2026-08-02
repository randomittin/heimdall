#!/usr/bin/env bash
#
# edit-ledger-presence.test.sh — acceptance for the edit-verification backstop.
#
# WHY: bin/verify-edits used to `exit 0` whenever `edit-tracker paths` came back
# empty. Empty has TWO causes and they are opposites:
#   * ledger ABSENT — the PostToolUse hook never ran, so nothing was recorded.
#     Nothing was checked, yet the old code printed a clean bill of health and
#     exited 0. Agents read that as "my edits are verified". Silent false-green.
#   * ledger PRESENT but empty — the session really did make no edits. A pass.
# Naive "fail when empty" would swap the false-green for a false-red on every
# read-only session, so the ledger's EXISTENCE is now the explicit, checkable
# fact: init/clear/log create it, `edit-tracker status` reports it.
#
# Guarantees proved:
#   1. status — absent -> "absent <path>" exit 3; present -> "present" exit 0.
#   2. ABSENT ledger -> verify-edits does NOT report success (exit 2, NOT
#      VERIFIED banner, and no PASS verdict anywhere in the output).
#   3. PRESENT + zero edits -> verify-edits reports success, exit 0, quiet.
#   4. PRESENT + real edits -> verify-edits verifies them as before (exit 0,
#      VERDICT: PASS, edited path listed) — no regression.
#   5. PRESENT + a missing edited file -> still FAILs with exit 1 (the
#      pre-existing assertion is not weakened).
#   6. clear leaves the ledger PRESENT-and-empty, never absent.
#   7. --json never emits a PASS verdict for an absent ledger.
#
# Usage:  bash test/edit-ledger-presence.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
TRACKER="$REPO/bin/edit-tracker"
VERIFY="$REPO/bin/verify-edits"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "edit-ledger-presence harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# Isolated ledger root + fixed session id so we never touch the real ledger.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/edit-ledger-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SID="ledger-presence-test"
LEDGER="$SANDBOX/heimdall-edits/$SID.log"

# Build from source so we test the current .c, not a stale artifact.
if ! clang -O2 -Wall -Wextra -o "$TRACKER" "$REPO/bin/edit-tracker.c" 2>/dev/null; then
  bad "edit-tracker.c failed to build"
  echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
ok "edit-tracker.c builds clean (clang -O2 -Wall -Wextra)"

# Run tracker/verify with the sandbox ledger root.
trk()  { env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" "$TRACKER" "$@"; }
vfy()  { env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" "$VERIFY" "$@"; }

# ── 1. STATE: LEDGER ABSENT ──
rm -rf "$SANDBOX/heimdall-edits"
out="$(trk status 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "status (absent) exits 3, got $rc" \
                || bad "status (absent) exits 3, got $rc"
case "$out" in
  "absent "*) ok "status (absent) prints 'absent <path>' -> $out" ;;
  *)          bad "status (absent) printed: $out" ;;
esac

out="$(vfy --quick 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "ABSENT ledger: verify-edits does NOT exit 0 (got $rc)" \
                || bad "ABSENT ledger: verify-edits exited 0 — silent false-green"
[ "$rc" -eq 2 ] && ok "ABSENT ledger: exit 2 (NON-VERIFIED, distinct from FAIL=1)" \
                || bad "ABSENT ledger: expected exit 2, got $rc"
case "$out" in
  *"NOT VERIFIED"*) ok "ABSENT ledger: output flags NOT VERIFIED" ;;
  *)                bad "ABSENT ledger: no NOT VERIFIED banner: $out" ;;
esac
case "$out" in
  *"VERDICT: PASS"*|*"No edits tracked this session."*)
    bad "ABSENT ledger: output still reads like a pass" ;;
  *) ok "ABSENT ledger: output contains no pass verdict" ;;
esac
# The old code's exact false-green string must be gone for the absent case.
case "$out" in
  *"NON-VERIFIED"*) ok "ABSENT ledger: verdict line says NON-VERIFIED" ;;
  *)                bad "ABSENT ledger: missing NON-VERIFIED verdict" ;;
esac

# ── 7. --json must not emit a pass for an absent ledger ──
jout="$(vfy --json 2>&1)"; jrc=$?
[ "$jrc" -eq 2 ] && ok "ABSENT ledger: --json exits 2" \
                 || bad "ABSENT ledger: --json expected exit 2, got $jrc"
case "$jout" in
  *'"verdict": "NON_VERIFIED"'*) ok "ABSENT ledger: --json verdict NON_VERIFIED" ;;
  *) bad "ABSENT ledger: --json verdict wrong: $jout" ;;
esac
case "$jout" in
  *'"verdict": "PASS"'*) bad "ABSENT ledger: --json claims PASS" ;;
  *) ok "ABSENT ledger: --json never claims PASS" ;;
esac
# bin/summary-card reddens its stub gate on verdict=="FAIL" OR warnings>0.
# NON_VERIFIED is deliberately not FAIL, so warnings must carry the signal or
# the receipt renders a green gate for a run that verified nothing.
case "$jout" in
  *'"warnings": 1'*) ok "ABSENT ledger: --json warnings>0 keeps receipt gates red" ;;
  *) bad "ABSENT ledger: --json warnings would let a receipt show a green gate" ;;
esac

# ── 2. STATE: LEDGER PRESENT, ZERO EDITS ──
trk init >/dev/null 2>&1
[ -f "$LEDGER" ] && ok "init creates the session ledger file" \
                 || bad "init did not create $LEDGER"
out="$(trk status 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "status (present) exits 0" \
                || bad "status (present) expected exit 0, got $rc"
case "$out" in
  "present "*) ok "status (present) prints 'present <path>'" ;;
  *)           bad "status (present) printed: $out" ;;
esac

out="$(vfy --quick 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "PRESENT+empty: verify-edits exits 0 (real pass)" \
                || bad "PRESENT+empty: expected exit 0, got $rc — false-red"
case "$out" in
  *"No edits tracked this session"*)
    ok "PRESENT+empty: quiet success message (read-only sessions stay calm)" ;;
  *) bad "PRESENT+empty: unexpected output: $out" ;;
esac
case "$out" in
  *"NOT VERIFIED"*) bad "PRESENT+empty: wrongly flagged NOT VERIFIED" ;;
  *)                ok "PRESENT+empty: not flagged NOT VERIFIED" ;;
esac

# init is idempotent and never truncates a ledger that already has entries.
trk log Write "$REPO/VERSION" >/dev/null 2>&1
trk init >/dev/null 2>&1
n="$(trk paths 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -eq 1 ] && ok "init is idempotent — does not truncate existing entries" \
               || bad "init truncated the ledger (paths=$n, expected 1)"

# ── 6. clear leaves the ledger present-and-empty ──
trk clear >/dev/null 2>&1
[ -f "$LEDGER" ] && ok "clear leaves the ledger PRESENT (not absent)" \
                 || bad "clear removed the ledger — reintroduces the false-green"
n="$(trk paths 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -eq 0 ] && ok "clear empties the ledger (0 tracked paths)" \
               || bad "clear left $n paths"
rc=0; vfy --quick >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "after clear: verify-edits exits 0 (tracked, no edits)" \
                || bad "after clear: expected exit 0, got $rc"

# ── 3. STATE: LEDGER PRESENT, REAL EDITS ──
EDITED="$SANDBOX/real-edit.sh"
printf '#!/bin/sh\necho hello\n' > "$EDITED"
trk log Write "$EDITED" >/dev/null 2>&1
trk log Edit "$EDITED" >/dev/null 2>&1

trk paths 2>/dev/null | grep -qxF "$EDITED" \
  && ok "logged edit appears in paths (deduped)" \
  || bad "logged edit missing from paths"
n="$(trk paths 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -eq 1 ] && ok "two ops on one file dedupe to a single path" \
               || bad "expected 1 unique path, got $n"
trk summary 2>/dev/null | grep -q "1 files, 2 operations" \
  && ok "summary counts 1 file / 2 operations" \
  || bad "summary miscounted: $(trk summary 2>/dev/null | head -1)"

out="$(vfy --quick 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "PRESENT+edits: verify-edits exits 0 for a clean edit" \
                || bad "PRESENT+edits: expected exit 0, got $rc"
case "$out" in
  *"VERDICT: PASS"*) ok "PRESENT+edits: VERDICT: PASS (existing behaviour intact)" ;;
  *) bad "PRESENT+edits: expected VERDICT: PASS, got: $out" ;;
esac
case "$out" in
  *"File Existence: PASS"*) ok "PRESENT+edits: file-existence check ran" ;;
  *) bad "PRESENT+edits: file-existence check did not run" ;;
esac

# ── 5. PRESENT + missing file still FAILs (assertion not weakened) ──
GONE="$SANDBOX/deleted-file.sh"
printf '#!/bin/sh\necho gone\n' > "$GONE"
trk log Write "$GONE" >/dev/null 2>&1
rm -f "$GONE"
out="$(vfy --quick 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "PRESENT+missing file: exits 1 (FAIL), distinct from 2" \
                || bad "PRESENT+missing file: expected exit 1, got $rc"
case "$out" in
  *"MISSING: $GONE"*) ok "PRESENT+missing file: names the missing path" ;;
  *) bad "PRESENT+missing file: did not name the path" ;;
esac

# ── 4. Session isolation — a different session id must not inherit a ledger ──
out="$(env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="some-other-session" \
        "$TRACKER" status 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "a different session id sees its own ledger as absent" \
                || bad "session isolation broken: exit $rc ($out)"

echo "--------------------------------------------------------------------"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

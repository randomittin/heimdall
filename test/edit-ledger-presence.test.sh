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
# A THIRD case hides inside "present but empty": the ledger can be reset
# mid-session (e.g. hooks.json's SessionStart firing `edit-tracker clear`
# with no gate on `source`, so it re-fires on compaction/resume, not just true
# session start) AFTER real edits were already logged. That leaves the ledger
# present-and-empty too — indistinguishable from a genuine zero-edit session
# by presence alone. verify-edits now cross-checks that case against
# `git status --porcelain`: present + empty + a dirty working tree is a
# contradiction, reported as NON-VERIFIED (exit 2), never a pass.
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
#   9. PRESENT + zero edits, but git shows a dirty working tree (e.g. the
#      ledger was reset mid-session after real edits were logged) -> NOT a
#      pass: verify-edits exits 2, NON_VERIFIED, reason ledger-git-mismatch,
#      in both plain and --json modes. A clean git tree (or no git at all)
#      still passes exactly as before (guarantee 3) — no false-red. Proved
#      falsifiable: a mutant with the cross-check excised reproduces the old
#      false-green.
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

# Run tracker/verify with the sandbox ledger root. vfy() runs from a
# dedicated non-git cwd: bin/verify-edits now cross-checks a present-but-empty
# ledger against `git status --porcelain` in its cwd, so every assertion below
# that expects a plain, unconditional PASS must run somewhere with no .git to
# check against — otherwise these assertions would depend on the ambient
# state of $REPO's own working tree (dirty during active development) rather
# than the fixture under test. vfy_in() is the git-aware counterpart used by
# the cross-check's own tests further down, which need a real, isolated repo.
NOGIT="$SANDBOX/nogit"
mkdir -p "$NOGIT"
trk()    { env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" "$TRACKER" "$@"; }
vfy()    { ( cd "$NOGIT" && env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" "$VERIFY" "$@" ); }
vfy_in() { local d="$1"; shift; ( cd "$d" && env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" "$VERIFY" "$@" ); }

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
# The REAL contract, not the old warnings>0 workaround. bin/summary-card now
# branches on verdict=="NON_VERIFIED" BEFORE any warnings test, so the payload
# no longer has to smuggle a magic warnings:1 tripwire to keep the receipt
# honest. Asserting on `warnings` would re-encode that workaround; assert the
# contract instead — the verdict drives it, end to end, for ANY warnings value.
case "$jout" in
  *'"warnings": 0'*) ok "ABSENT ledger: --json carries no warnings tripwire (warnings 0)" ;;
  *) bad "ABSENT ledger: --json still smuggles a warnings tripwire: $jout" ;;
esac

# End-to-end across the seam the tripwire used to bridge: feed the ledger-absent
# payload to the receipt renderer with EVERY OTHER gate seeded green, so only the
# stub gate can hold the run back. A green Bifröst here is the same false-green,
# one layer up. Proven for warnings 0 AND warnings 1 — the card must be provably
# independent of that field, in both directions.
CARD_BIN="$REPO/bin/summary-card"
CARD_WORK="$SANDBOX/card"
mkdir -p "$CARD_WORK/oracles/o1" "$CARD_WORK/proj"
echo '{"gate_id":"o1","status":"pass"}' > "$CARD_WORK/oracles/o1/report.json"
printf '| 0.1 | 3 cases | 3/3 caught | 100%% |\n' > "$CARD_WORK/CORPUS-STATUS.md"
NOPE="$CARD_WORK/absent.json"   # pins pool/holdout off the real emitters

# card_receipt PAYLOAD_FILE -> sets CARD_OUT (ansi-stripped) + CARD_RC.
# Must NOT be called in a command substitution: the card's exit status is the
# assertion, and a subshell would strand it.
CARD_OUT=""; CARD_RC=0
card_receipt() {
  local raw
  CARD_RC=0
  raw="$(HEIMDALL_RECEIPT_ORACLE_DIR="$CARD_WORK/oracles" \
         HEIMDALL_RECEIPT_CORPUS_STATUS="$CARD_WORK/CORPUS-STATUS.md" \
         HEIMDALL_RECEIPT_STUB_JSON="$1" \
         HEIMDALL_RECEIPT_POOL_JSON="$NOPE" \
         HEIMDALL_RECEIPT_HOLDOUT_JSON="$NOPE" \
         HEIMDALL_RECEIPT_REUSE_DIR="$CARD_WORK/none" \
         HEIMDALL_RECEIPT_PONYTAIL="$NOPE" \
         HEIMDALL_RECEIPT_WHO="ledger.test" \
         "$CARD_BIN" --receipt "$CARD_WORK/proj" 2>&1)" || CARD_RC=$?
  CARD_OUT="$(printf '%s\n' "$raw" | sed -E $'s/\x1b\\[[0-9;]*m//g')"
}

if [ -x "$CARD_BIN" ]; then
  # (a) the payload verify-edits ACTUALLY emits, byte for byte.
  NV_PAYLOAD="$CARD_WORK/nv-real.json"
  printf '%s\n' "$jout" > "$NV_PAYLOAD"
  card_receipt "$NV_PAYLOAD"
  case "$CARD_OUT" in
    *"nothing shipped unproven"*)
      bad "ABSENT ledger: receipt went OPEN on the real payload — false-green" ;;
    *) ok "ABSENT ledger: real payload keeps the receipt non-green (not OPEN)" ;;
  esac
  case "$CARD_OUT" in
    *"CLOSED"*) ok "ABSENT ledger: receipt Bifröst reads CLOSED" ;;
    *) bad "ABSENT ledger: receipt did not close: $(printf '%s' "$CARD_OUT" | grep -i bif)" ;;
  esac
  [ "$CARD_RC" -eq 2 ] && ok "ABSENT ledger: receipt exits 2 (mirrors verify-edits)" \
                       || bad "ABSENT ledger: receipt exit want 2, got $CARD_RC"

  # (b) the SAME verdict with warnings forced BACK to 1 — the old tripwire value.
  #     Must render identically: proves the card reads the verdict, not the field.
  NV_W1="$CARD_WORK/nv-warn1.json"
  printf '%s\n' '{"verdict":"NON_VERIFIED","reason":"edit-ledger-absent","files_edited":null,"checks_passed":0,"checks_failed":0,"warnings":1,"paths":[]}' > "$NV_W1"
  card_receipt "$NV_W1"
  case "$CARD_OUT" in
    *"nothing shipped unproven"*) bad "warnings:1 NON_VERIFIED opened the Bifröst" ;;
    *) ok "warnings:1 NON_VERIFIED also stays non-green (verdict drives it)" ;;
  esac
  [ "$CARD_RC" -eq 2 ] && ok "warnings:1 NON_VERIFIED also exits 2 (field-independent)" \
                       || bad "warnings:1 NON_VERIFIED exit want 2, got $CARD_RC"
else
  bad "summary-card not executable at $CARD_BIN"
fi

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

# ── 8. --json STDOUT IS ALWAYS VALID JSON — including the rebuild path ────────
# verify-edits rebuilds a missing/stale edit-tracker before doing anything. That
# build chatter used to go to STDOUT, so `--json` emitted
#   edit-tracker not built or stale. Building...{ "verdict": ... }
# — a payload no strict parser accepts. bin/summary-card happened to fail SAFE on
# it (unparseable -> non-green), but that was luck: a machine that rebuilt the
# tracker silently lost its stub gate. Progress/diagnostics belong on stderr.
JSON_OK() { # stdin -> exit 0 iff stdin parses as JSON
  python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
}
if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 unavailable — cannot verify --json payload purity"
else
  # Force the rebuild path: make the source newer than the binary.
  touch "$REPO/bin/edit-tracker.c"
  [ "$REPO/bin/edit-tracker.c" -nt "$TRACKER" ] \
    && ok "rebuild path armed (edit-tracker.c newer than the binary)" \
    || bad "could not arm the rebuild path — the next assertions prove nothing"

  # 8a. rebuild path + ABSENT ledger: the NON_VERIFIED payload must still parse.
  rm -rf "$SANDBOX/heimdall-edits"
  jbuild="$(vfy --json 2>/dev/null)"; jbrc=$?
  printf '%s' "$jbuild" | JSON_OK \
    && ok "rebuild path: --json stdout is valid JSON (absent ledger)" \
    || bad "rebuild path: --json stdout is NOT valid JSON: [$jbuild]"
  case "$jbuild" in
    *"Building"*|*"not built or stale"*)
      bad "rebuild path: build chatter leaked onto --json stdout: [$jbuild]" ;;
    *) ok "rebuild path: no build chatter on --json stdout" ;;
  esac
  [ "$jbrc" -eq 2 ] && ok "rebuild path: absent ledger still exits 2" \
                    || bad "rebuild path: expected exit 2, got $jbrc"

  # 8b. rebuild path + PRESENT ledger with a real edit: the normal payload too.
  touch "$REPO/bin/edit-tracker.c"
  trk init >/dev/null 2>&1
  trk log Write "$EDITED" >/dev/null 2>&1
  jbuild2="$(vfy --json 2>/dev/null)"; jb2rc=$?
  printf '%s' "$jbuild2" | JSON_OK \
    && ok "rebuild path: --json stdout is valid JSON (present ledger, real edit)" \
    || bad "rebuild path: --json stdout NOT valid JSON: [$jbuild2]"
  [ "$jb2rc" -eq 0 ] && ok "rebuild path: present ledger + clean edit exits 0" \
                     || bad "rebuild path: expected exit 0, got $jb2rc"

  # 8c. the already-built (normal) path stays valid JSON — no regression.
  jnorm="$(vfy --json 2>/dev/null)"; jnrc=$?
  printf '%s' "$jnorm" | JSON_OK \
    && ok "normal path: --json stdout is valid JSON (no rebuild)" \
    || bad "normal path: --json stdout NOT valid JSON: [$jnorm]"
  [ "$jnrc" -eq 0 ] && ok "normal path: exits 0" || bad "normal path: got $jnrc"

  # 8d. the chatter is not merely deleted — it still reaches STDERR, so a human
  #     rebuilding the tracker is still told. Silencing it would trade one bug
  #     for a quieter one.
  touch "$REPO/bin/edit-tracker.c"
  errout="$(vfy --json 2>&1 >/dev/null)"
  case "$errout" in
    *"Building"*) ok "rebuild path: build chatter still reported on STDERR" ;;
    *) bad "rebuild path: chatter vanished entirely (want stderr, got none): [$errout]" ;;
  esac

  # 8e. THE COMMON PATH: ledger PRESENT with ZERO edits — every read-only /
  # planning session. This exit used to print the prose line
  #   [heimdall] verify-edits: No edits tracked this session (ledger present, 0 edits).
  # on STDOUT even under --json. It is by far the most-hit --json path, so the
  # receipt's stub gate was unparseable on most real sessions.
  trk clear >/dev/null 2>&1
  jzero="$(vfy --json 2>/dev/null)"; jzrc=$?
  printf '%s' "$jzero" | JSON_OK \
    && ok "zero-edit session: --json stdout is valid JSON" \
    || bad "zero-edit session: --json emitted non-JSON: [$jzero]"
  [ "$jzrc" -eq 0 ] && ok "zero-edit session: --json exits 0 (a real pass)" \
                    || bad "zero-edit session: expected exit 0, got $jzrc"
  case "$jzero" in
    *'"verdict": "PASS"'*) ok "zero-edit session: --json verdict PASS (tracked, nothing to check)" ;;
    *) bad "zero-edit session: --json verdict wrong: [$jzero]" ;;
  esac
  case "$jzero" in
    *'"files_edited": 0'*) ok "zero-edit session: --json reports files_edited 0" ;;
    *) bad "zero-edit session: --json files_edited wrong: [$jzero]" ;;
  esac

  # 8f. ...and the DOWNSTREAM consequence, which is why 8e matters. summary-card
  # now fails CLOSED on an unreadable stub payload. If this path emitted prose,
  # every read-only session would render "✗ CLOSED — a gate could not verify" for
  # a run that is genuinely fine — the false-RED that trains people to ignore the
  # receipt. A legitimate zero-edit session MUST still open the Bifröst.
  if [ -x "$CARD_BIN" ]; then
    ZERO_PAYLOAD="$CARD_WORK/zero-edits.json"
    printf '%s\n' "$jzero" > "$ZERO_PAYLOAD"
    card_receipt "$ZERO_PAYLOAD"
    case "$CARD_OUT" in
      *"nothing shipped unproven"*)
        ok "zero-edit session: receipt still OPENs (fail-closed did not eat a real pass)" ;;
      *) bad "FALSE-RED: a clean read-only session closed the Bifröst: $(printf '%s' "$CARD_OUT" | grep -i bif)" ;;
    esac
    [ "$CARD_RC" -eq 0 ] && ok "zero-edit session: receipt exits 0" \
                         || bad "zero-edit session: receipt exit want 0, got $CARD_RC"
  fi
fi

# ── 9. LEDGER RESET AFTER REAL EDITS — must not report a clean zero ──
# This is the actual reported defect: something (e.g. hooks.json's
# SessionStart firing `edit-tracker clear` unconditionally, with no `source`
# gate, so it re-fires on compaction/resume and not just true session start)
# can wipe a ledger that had already logged real edits, leaving it
# PRESENT-and-EMPTY. Old behaviour: verify-edits could not tell that apart
# from a genuine zero-edit session and reported a clean PASS. The git
# cross-check closes that gap — a dirty tree while the ledger says zero is a
# contradiction, not a pass.
GITREPO="$SANDBOX/gitrepo"
mkdir -p "$GITREPO"
(
  cd "$GITREPO" &&
  git init -q &&
  git config user.email t@t &&
  git config user.name t &&
  printf 'baseline\n' > tracked.txt &&
  git add tracked.txt &&
  git commit -q -m baseline
) >/dev/null 2>&1

# Defensive: do not rely on whatever state section 8 left $SID's ledger in.
trk clear >/dev/null 2>&1

# A real, uncommitted edit happens and gets logged...
printf 'real edit\n' >> "$GITREPO/tracked.txt"
trk log Edit "$GITREPO/tracked.txt" >/dev/null 2>&1
n="$(trk paths 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -eq 1 ] && ok "fixture: real edit is logged before the reset (paths=1)" \
               || bad "fixture: expected 1 logged path before reset, got $n"

# ...then something resets the ledger mid-session (the reproduced hooks.json
# SessionStart behaviour): clear() unlinks + recreates empty -> present+0.
trk clear >/dev/null 2>&1
n="$(trk paths 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -eq 0 ] && ok "fixture: ledger is present-and-empty after the reset (paths=0)" \
               || bad "fixture: expected 0 paths after clear, got $n"

dirty="$(cd "$GITREPO" && git status --porcelain)"
[ -n "$dirty" ] && ok "fixture: git still shows the real edit as dirty ($dirty)" \
                || bad "fixture: git unexpectedly clean — fixture is broken"

out="$(vfy_in "$GITREPO" --quick 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "RESET-AFTER-EDIT: verify-edits exits 2, not a clean zero (got $rc)" \
                || bad "RESET-AFTER-EDIT: expected exit 2, got $rc — silent false-green reproduced"
case "$out" in
  *"VERDICT: PASS"*|*"No edits tracked this session"*)
    bad "RESET-AFTER-EDIT: output still reads like a clean pass: $out" ;;
  *) ok "RESET-AFTER-EDIT: output does not read like a clean pass" ;;
esac
case "$out" in
  *"NOT VERIFIED"*"ledger/git mismatch"*) ok "RESET-AFTER-EDIT: banner names the ledger/git mismatch" ;;
  *) bad "RESET-AFTER-EDIT: missing ledger/git mismatch banner: $out" ;;
esac
case "$out" in
  *"NON-VERIFIED"*) ok "RESET-AFTER-EDIT: verdict line says NON-VERIFIED" ;;
  *) bad "RESET-AFTER-EDIT: missing NON-VERIFIED verdict: $out" ;;
esac

joutR="$(vfy_in "$GITREPO" --json 2>&1)"; jrcR=$?
[ "$jrcR" -eq 2 ] && ok "RESET-AFTER-EDIT: --json exits 2" \
                  || bad "RESET-AFTER-EDIT: --json expected exit 2, got $jrcR"
case "$joutR" in
  *'"verdict": "NON_VERIFIED"'*) ok "RESET-AFTER-EDIT: --json verdict NON_VERIFIED" ;;
  *) bad "RESET-AFTER-EDIT: --json verdict wrong: $joutR" ;;
esac
case "$joutR" in
  *'"reason": "ledger-git-mismatch"'*) ok "RESET-AFTER-EDIT: --json reason ledger-git-mismatch" ;;
  *) bad "RESET-AFTER-EDIT: --json missing reason: $joutR" ;;
esac
case "$joutR" in
  *'"verdict": "PASS"'*) bad "RESET-AFTER-EDIT: --json claims PASS" ;;
  *) ok "RESET-AFTER-EDIT: --json never claims PASS" ;;
esac
printf '%s' "$joutR" | JSON_OK \
  && ok "RESET-AFTER-EDIT: --json stdout is valid JSON" \
  || bad "RESET-AFTER-EDIT: --json stdout NOT valid JSON: [$joutR]"

# ── 9b. CONTROL: clean git repo + present-and-empty ledger => still a pass ──
# The cross-check must not turn every zero-edit session in a git repo into a
# false NON-VERIFIED. Commit the edit so the tree is clean again.
(
  cd "$GITREPO" &&
  git add tracked.txt &&
  git commit -q -m "commit the edit"
) >/dev/null 2>&1
clean="$(cd "$GITREPO" && git status --porcelain)"
[ -z "$clean" ] && ok "control fixture: git repo is clean after committing" \
                || bad "control fixture: git repo unexpectedly dirty: $clean"

out="$(vfy_in "$GITREPO" --quick 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "CLEAN-GIT+ZERO-EDITS: verify-edits still exits 0 (no false-red)" \
                || bad "CLEAN-GIT+ZERO-EDITS: expected exit 0, got $rc"
case "$out" in
  *"No edits tracked this session"*) ok "CLEAN-GIT+ZERO-EDITS: quiet pass message intact" ;;
  *) bad "CLEAN-GIT+ZERO-EDITS: unexpected output: $out" ;;
esac

joutC="$(vfy_in "$GITREPO" --json 2>&1)"; jrcC=$?
[ "$jrcC" -eq 0 ] && ok "CLEAN-GIT+ZERO-EDITS: --json exits 0" \
                  || bad "CLEAN-GIT+ZERO-EDITS: --json expected exit 0, got $jrcC"
case "$joutC" in
  *'"verdict": "PASS"'*) ok "CLEAN-GIT+ZERO-EDITS: --json verdict PASS" ;;
  *) bad "CLEAN-GIT+ZERO-EDITS: --json verdict wrong: $joutC" ;;
esac

# ── 9c. PROVE-RED: the assertions above are falsifiable, not tautological ──
# Delete the cross-check block (bounded by its own anchor comments) from a
# throwaway copy of verify-edits and confirm the OLD false-clean-zero bug
# reappears — i.e. that 9/9a above would actually have caught it.
MUTANT="$SANDBOX/verify-edits.mutant"
sed '/# --- ledger-git cross-check: begin ---/,/# --- ledger-git cross-check: end ---/d' \
  "$VERIFY" > "$MUTANT"
chmod +x "$MUTANT"
if grep -q "ledger-git-mismatch" "$MUTANT"; then
  bad "mutant: cross-check block was not actually removed"
else
  ok "mutant: cross-check block successfully excised"
fi

# Recreate the reset-after-edit fixture (the repo is clean from 9b's commit):
# a fresh real edit, logged, then the ledger is cleared out from under it.
# CLAUDE_PLUGIN_ROOT must point at the real repo: the mutant lives in
# $SANDBOX, so without it the mutant's own PLUGIN_DIR self-resolution would
# look for bin/edit-tracker(.c) next to the sandboxed copy and fail to build.
printf 'another real edit\n' >> "$GITREPO/tracked.txt"
trk log Edit "$GITREPO/tracked.txt" >/dev/null 2>&1
trk clear >/dev/null 2>&1
mutant_out="$(cd "$GITREPO" && env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" \
  CLAUDE_PLUGIN_ROOT="$REPO" "$MUTANT" --quick 2>&1)"
mutant_rc=$?
[ "$mutant_rc" -eq 0 ] && ok "PROVE-RED: mutant (no cross-check) reproduces the old exit-0 false-green" \
                       || bad "PROVE-RED: mutant unexpectedly exits $mutant_rc — assertions may be tautological"
case "$mutant_out" in
  *"No edits tracked this session"*) ok "PROVE-RED: mutant reproduces the old clean-zero message" ;;
  *) bad "PROVE-RED: mutant did not reproduce the old message: $mutant_out" ;;
esac

# ...and confirm the REAL (unmutated) verify-edits is still fixed against an
# equivalent fixture (the mutant run above consumed the prior dirty state, so
# this reconfirms GREEN on a fresh one rather than reusing stale state).
printf 'yet another real edit\n' >> "$GITREPO/tracked.txt"
trk log Edit "$GITREPO/tracked.txt" >/dev/null 2>&1
trk clear >/dev/null 2>&1
real_rc=0; vfy_in "$GITREPO" --quick >/dev/null 2>&1 || real_rc=$?
[ "$real_rc" -eq 2 ] && ok "GREEN restored: real (unmutated) verify-edits exits 2 on the same fixture" \
                     || bad "GREEN restored: expected exit 2, got $real_rc"

echo "--------------------------------------------------------------------"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

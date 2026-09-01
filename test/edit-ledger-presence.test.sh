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
# by presence alone. verify-edits now cross-checks that case two ways: (1)
# against `git status --porcelain` — present + empty + a dirty working tree is
# a contradiction, reported as NON-VERIFIED (exit 2), never a pass; and (2)
# against `edit-tracker clears` — a ledger that was ever wiped mid-session
# while holding real entries stays NON-VERIFIED even once the tree is clean
# again (e.g. the lost edit was already committed before the clear ran, which
# the git cross-check alone cannot see), and even once the ledger has picked
# up fresh entries since (a present, non-empty ledger can still be an
# incomplete record of the whole session).
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
#  10. The gap guarantee 9 cannot cover: a mid-session clear that destroyed
#      entries for an edit that was ALREADY COMMITTED (tree clean, so 9's
#      git-dirty check has nothing to compare against) -> still NOT a pass.
#      `edit-tracker clear` now records "<ts>|<entries_lost>" to a sibling
#      .clears file whenever it wipes a non-empty ledger; verify-edits reads
#      that back and reports NON_VERIFIED/reason ledger-cleared-mid-session,
#      exit 2, for both the empty-paths case AND the full-report case (a
#      ledger that shows SOME edits but is known to be missing earlier ones —
#      the exact shape of the originally reported defect). A no-op clear
#      (nothing to lose) adds no new .clears entry, and once a real loss is
#      recorded it correctly stays flagged for the rest of that session's
#      life (by design — see edit-tracker.c). Proved falsifiable: mutants
#      with each new cross-check excised (empty-paths and full-report,
#      separately) reproduce the old false-green in each shape.
#  11. A non-empty ledger can ALSO be incomplete for a completely different
#      reason: a file edited via a raw shell command (sed/cat/heredoc/cp —
#      not a Write/Edit/MultiEdit/NotebookEdit tool call) never reaches
#      `edit-tracker log`, since the PostToolUse hook only matches those four
#      tool names. verify-edits now cross-checks the ledger's claimed paths
#      against git's own dirty/staged file list; any file git considers
#      changed that the ledger never logged trips NON_VERIFIED (exit 2,
#      reason untracked-git-diff), naming the missed file, even though the
#      ledger DOES correctly show other, properly-logged edits. Logging the
#      missed file closes the gap and a normal PASS resumes. Proved
#      falsifiable: a mutant with this cross-check excised reproduces the old
#      false-green.
#
# Usage:  bash test/edit-ledger-presence.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
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

# Isolated "plugin root" so EVERY rebuild — ours below, and verify-edits' own
# rebuild-if-stale check inside vfy() — lands on a throwaway copy, never on
# the committed $REPO/bin/edit-tracker. A test must not mutate a tracked file
# (test/run-all.sh's tree-integrity check); building in place here used to
# trip it whenever §8 armed the "source newer than binary" path by touching
# the real edit-tracker.c.
PLUGIN_SANDBOX="$SANDBOX/plugin"
mkdir -p "$PLUGIN_SANDBOX/bin"
cp "$REPO/bin/edit-tracker.c" "$PLUGIN_SANDBOX/bin/edit-tracker.c"
TRACKER="$PLUGIN_SANDBOX/bin/edit-tracker"
SRC="$PLUGIN_SANDBOX/bin/edit-tracker.c"

# Build from source so we test the current .c, not a stale artifact.
if ! clang -O2 -Wall -Wextra -o "$TRACKER" "$SRC" 2>/dev/null; then
  bad "edit-tracker.c failed to build"
  echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
ok "edit-tracker.c builds clean (clang -O2 -Wall -Wextra)"

# Run tracker/verify with the sandbox ledger root AND a sandboxed plugin root.
# CLAUDE_PLUGIN_ROOT makes verify-edits resolve its OWN copy of edit-tracker from
# $PLUGIN_SANDBOX (see bin/verify-edits's PLUGIN_DIR), so its internal
# rebuild-if-stale check stays inside $SANDBOX instead of recompiling the repo's
# TRACKED binary -- that rebuild was the tree-integrity violation. vfy() runs from a
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
vfy()    { ( cd "$NOGIT" && env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PLUGIN_ROOT="$PLUGIN_SANDBOX" "$VERIFY" "$@" ); }
vfy_in() { local d="$1"; shift; ( cd "$d" && env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PLUGIN_ROOT="$PLUGIN_SANDBOX" "$VERIFY" "$@" ); }

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
# Test-harness isolation only (see guarantee 10 for the DELIBERATE version of
# this): the ledger here happens to hold one real entry from the idempotency
# check just above, so clear() legitimately records a loss to .clears. That
# mechanism gets its own dedicated coverage in guarantee 10 — reset it here so
# THIS guarantee stays scoped to what it says on the tin (structural clear
# semantics), not an accidental early trigger of a check it never meant to
# exercise.
trk clear >/dev/null 2>&1
rm -f "$SANDBOX/heimdall-edits/$SID.clears"
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
  # Force the rebuild path deterministically: remove the binary so verify-edits'
  # own "missing OR stale" check (bin/verify-edits: `[ ! -x "$TRACKER" ] || [ ...
  # -nt ... ]`) is unambiguously true. This used to `touch "$SRC"` and rely on
  # `-nt` mtime comparison, which is a real race: if $TRACKER's mtime is ever >=
  # "now" at the moment $SRC is touched (clock adjustment, coalesced filesystem
  # timestamp writeback under load, or just an unlucky scheduling gap), the arm
  # silently fails and verify-edits correctly, faithfully takes the "nothing is
  # stale" branch -- silence that looks like a bug but isn't one. Only 8d below
  # actually proves the rebuild fired (it requires stderr content); 8a/8b/8c never
  # check for it, which is why a silent arming failure surfaces as exactly one red
  # assertion here, not several. `rm -f` has no such window: existence is a
  # boolean the filesystem reports immediately and consistently, not a comparison
  # of two independently-recorded timestamps.
  rm -f "$TRACKER"
  [ ! -x "$TRACKER" ] \
    && ok "rebuild path armed (edit-tracker binary removed)" \
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
  # Set up the ledger state first (trk calls the binary directly -- see trk() --
  # so it needs $TRACKER to still exist), then remove the binary right before the
  # vfy call that must observe it missing. Order matters here in a way it didn't
  # for the old touch-based arm, which never destroyed the binary.
  trk init >/dev/null 2>&1
  trk log Write "$EDITED" >/dev/null 2>&1
  rm -f "$TRACKER"
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
  rm -f "$TRACKER"
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
  rm -f "$SANDBOX/heimdall-edits/$SID.clears"  # see guarantee 6's note: test-harness isolation
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

# Test-harness isolation (see guarantee 6's note): guarantee 9's OWN fixture
# just recorded a real loss to prove the git-mismatch path — reset it here so
# 9b tests ONLY what it says (an ordinary clean-git zero-edit session), not an
# accidental replay of 9's mid-session-clear evidence (guarantee 10 covers
# that combination on purpose, explicitly).
rm -f "$SANDBOX/heimdall-edits/$SID.clears"

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
# Delete ALL THREE cross-check blocks (old + both new, each bounded by its
# own anchor comments) from a throwaway copy of verify-edits and confirm the
# OLD false-clean-zero bug reappears — i.e. that 9/9a above would actually
# have caught it. Stripping only the original ledger-git block is no longer
# enough to prove this: the fixture below (log then clear) is now ALSO caught
# independently by the mid-session-clear blocks added alongside `edit-tracker
# clears`, so a fair "what if NO cross-check existed" mutant has to remove
# every block that could catch it, not just the first one ever written.
MUTANT="$SANDBOX/verify-edits.mutant"
sed -e '/# --- ledger-git cross-check: begin ---/,/# --- ledger-git cross-check: end ---/d' \
    -e '/# --- mid-session-clear cross-check: begin ---/,/# --- mid-session-clear cross-check: end ---/d' \
    -e '/# --- mid-session-clear cross-check (full-report): begin ---/,/# --- mid-session-clear cross-check (full-report): end ---/d' \
  "$VERIFY" > "$MUTANT"
chmod +x "$MUTANT"
if grep -q "ledger-git-mismatch" "$MUTANT" \
   || grep -q "mid-session-clear cross-check: begin" "$MUTANT" \
   || grep -q "mid-session-clear cross-check (full-report): begin" "$MUTANT"; then
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

# ── 10. LEDGER CLEARED MID-SESSION, BUT ALREADY COMMITTED — clean tree must
# still report NON-VERIFIED, not a clean pass ──
# Guarantee 9's cross-check only catches an UNCOMMITTED loss (dirty tree). If
# the lost edit was already committed before the clear ran, the tree is clean
# and 9's check has nothing to compare against — a real gap, since "commit,
# then a resume/compact clear fires" is an entirely ordinary sequence (this
# repo auto-commits after every completed task). This section proves
# `edit-tracker clears` + verify-edits' new mid-session-clear cross-check
# closes it, for BOTH the empty-paths branch (this ledger, right now, shows
# nothing) and the full-report branch (this ledger shows SOMETHING, but not
# everything) — the latter is the exact shape of the originally reported
# defect: a ledger showing one operation while an earlier 89-line edit and a
# new test file, logged earlier the same session, had already been wiped.

# Settle GITREPO to a clean baseline first: sections 9/9c leave it dirty.
(
  cd "$GITREPO" &&
  git add tracked.txt &&
  git commit -q -m "settle before guarantee 10"
) >/dev/null 2>&1
settled="$(cd "$GITREPO" && git status --porcelain)"
[ -z "$settled" ] && ok "guarantee 10 fixture: GITREPO settled clean" \
                  || bad "guarantee 10 fixture: GITREPO still dirty: $settled"

# Test-harness isolation (see guarantee 6's note): sections 6/8/9/9c above
# each legitimately record their own loss for THEIR purposes — wipe that
# history now so guarantee 10's counts below are attributable only to ITS
# own fixture, not to accumulated residue from earlier, unrelated guarantees.
rm -f "$SANDBOX/heimdall-edits/$SID.clears"
trk clear >/dev/null 2>&1   # start from a known-empty, .clears-quiet ledger
clears_empty="$(trk clears 2>/dev/null)"
[ -z "$clears_empty" ] && ok "clear on an already-empty ledger writes NO .clears entry" \
                        || bad "clear on an empty ledger unexpectedly recorded: $clears_empty"

# A real edit happens, gets logged, then gets COMMITTED (tree goes clean)...
printf 'guarantee-10 edit\n' >> "$GITREPO/tracked.txt"
trk log Edit "$GITREPO/tracked.txt" >/dev/null 2>&1
(
  cd "$GITREPO" &&
  git add tracked.txt &&
  git commit -q -m "guarantee 10 edit, committed before the clear"
) >/dev/null 2>&1
clean_after_commit="$(cd "$GITREPO" && git status --porcelain)"
[ -z "$clean_after_commit" ] && ok "fixture: edit is committed, tree is clean" \
                             || bad "fixture: tree unexpectedly dirty: $clean_after_commit"

# ...then a resume/compact-style clear fires, wiping the ledger's only record
# of that edit. git is clean, so guarantee 9's dirty-tree check sees nothing.
trk clear >/dev/null 2>&1
n="$(trk paths 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -eq 0 ] && ok "fixture: ledger is present-and-empty after the clear (paths=0)" \
               || bad "fixture: expected 0 paths after clear, got $n"

clears_out="$(trk clears 2>/dev/null)"
case "$clears_out" in
  *"|1") ok "edit-tracker clears recorded the 1 lost entry: $clears_out" ;;
  *) bad "edit-tracker clears did not record the loss: '$clears_out'" ;;
esac

out="$(vfy_in "$GITREPO" --quick 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "COMMITTED-THEN-CLEARED (empty-paths): verify-edits exits 2, not a clean pass (got $rc)" \
                || bad "COMMITTED-THEN-CLEARED (empty-paths): expected exit 2, got $rc — silent false-green on a clean tree"
case "$out" in
  *"VERDICT: PASS"*|*"No edits tracked this session"*)
    bad "COMMITTED-THEN-CLEARED: output still reads like a clean pass: $out" ;;
  *) ok "COMMITTED-THEN-CLEARED: output does not read like a clean pass" ;;
esac
case "$out" in
  *"NOT VERIFIED"*"ledger cleared mid-session"*) ok "COMMITTED-THEN-CLEARED: banner names the mid-session clear" ;;
  *) bad "COMMITTED-THEN-CLEARED: missing mid-session-clear banner: $out" ;;
esac

joutT="$(vfy_in "$GITREPO" --json 2>&1)"; jrcT=$?
[ "$jrcT" -eq 2 ] && ok "COMMITTED-THEN-CLEARED: --json exits 2" \
                  || bad "COMMITTED-THEN-CLEARED: --json expected exit 2, got $jrcT"
case "$joutT" in
  *'"verdict": "NON_VERIFIED"'*) ok "COMMITTED-THEN-CLEARED: --json verdict NON_VERIFIED" ;;
  *) bad "COMMITTED-THEN-CLEARED: --json verdict wrong: $joutT" ;;
esac
case "$joutT" in
  *'"reason": "ledger-cleared-mid-session"'*) ok "COMMITTED-THEN-CLEARED: --json reason ledger-cleared-mid-session" ;;
  *) bad "COMMITTED-THEN-CLEARED: --json missing reason: $joutT" ;;
esac
case "$joutT" in
  *'"entries_lost": 1'*) ok "COMMITTED-THEN-CLEARED: --json reports entries_lost 1" ;;
  *) bad "COMMITTED-THEN-CLEARED: --json entries_lost wrong: $joutT" ;;
esac
printf '%s' "$joutT" | JSON_OK \
  && ok "COMMITTED-THEN-CLEARED: --json stdout is valid JSON" \
  || bad "COMMITTED-THEN-CLEARED: --json stdout NOT valid JSON: [$joutT]"

# ── 10a-mutant. PROVE-RED (empty-paths branch): excise ITS cross-check block,
# confirm the old clean-zero false-green reappears ──
MUTANT2="$SANDBOX/verify-edits.mutant2"
sed '/# --- mid-session-clear cross-check: begin ---/,/# --- mid-session-clear cross-check: end ---/d' \
  "$VERIFY" > "$MUTANT2"
chmod +x "$MUTANT2"
if grep -q "mid-session-clear cross-check: begin" "$MUTANT2"; then
  bad "mutant2: empty-paths cross-check block was not actually removed"
else
  ok "mutant2: empty-paths mid-session-clear cross-check block successfully excised"
fi
mutant2_out="$(cd "$GITREPO" && env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" \
  CLAUDE_PLUGIN_ROOT="$REPO" "$MUTANT2" --quick 2>&1)"
mutant2_rc=$?
[ "$mutant2_rc" -eq 0 ] && ok "PROVE-RED: mutant2 (no empty-paths cross-check) reproduces the old exit-0 false-green" \
                        || bad "PROVE-RED: mutant2 unexpectedly exits $mutant2_rc — assertion may be tautological"
case "$mutant2_out" in
  *"No edits tracked this session"*) ok "PROVE-RED: mutant2 reproduces the old clean-zero message" ;;
  *) bad "PROVE-RED: mutant2 did not reproduce the old message: $mutant2_out" ;;
esac

real2_rc=0; vfy_in "$GITREPO" --quick >/dev/null 2>&1 || real2_rc=$?
[ "$real2_rc" -eq 2 ] && ok "GREEN restored: real (unmutated) verify-edits exits 2 on the committed-then-cleared (empty-paths) fixture" \
                      || bad "GREEN restored: expected exit 2, got $real2_rc"

# ── 10b. CONTROL: a no-op clear (nothing NEW lost) adds no fresh .clears
# line, and verify-edits correctly STAYS non-verified — the earlier loss
# really happened and an empty follow-up clear cannot un-happen it. This is
# intentional persistence, not a bug: .clears is designed to never be
# cleared by anything in this program, so a session that has EVER lost
# history stays flagged for the rest of that session's life. ──
lines_before="$(wc -l < "$SANDBOX/heimdall-edits/$SID.clears" | tr -d ' ')"
trk clear >/dev/null 2>&1   # ledger is already empty here -> this clear loses 0
lines_after="$(wc -l < "$SANDBOX/heimdall-edits/$SID.clears" | tr -d ' ')"
[ "$lines_after" -eq "$lines_before" ] && ok "a no-op clear adds no new .clears line ($lines_before -> $lines_after)" \
                                       || bad "a no-op clear spuriously added a .clears line ($lines_before -> $lines_after)"
out="$(vfy_in "$GITREPO" --quick 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "control: verify-edits correctly STAYS non-verified after a no-op clear (got $rc)" \
                || bad "control: expected exit 2 (loss persists), got $rc"

# ── 10c. Non-empty ledger with a prior loss still refuses to certify — the
# full-report branch, and the exact shape of the originally reported defect
# (a ledger with something in it, just not everything) ──
printf 'post-clear edit\n' >> "$GITREPO/tracked.txt"
trk log Edit "$GITREPO/tracked.txt" >/dev/null 2>&1
out="$(vfy_in "$GITREPO" --quick 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "NON-EMPTY ledger with prior loss still refuses to certify (got $rc)" \
                || bad "NON-EMPTY ledger with prior loss: expected exit 2, got $rc"
case "$out" in
  *"ledger cleared mid-session"*) ok "NON-EMPTY+prior-loss: banner present in full-report branch too" ;;
  *) bad "NON-EMPTY+prior-loss: banner missing: $out" ;;
esac
joutN="$(vfy_in "$GITREPO" --json 2>&1)"
case "$joutN" in
  *'"files_edited": 1'*) ok "NON-EMPTY+prior-loss: --json still reports the real files_edited count (1)" ;;
  *) bad "NON-EMPTY+prior-loss: --json files_edited wrong: $joutN" ;;
esac
printf '%s' "$joutN" | JSON_OK \
  && ok "NON-EMPTY+prior-loss: --json stdout is valid JSON" \
  || bad "NON-EMPTY+prior-loss: --json stdout NOT valid JSON: [$joutN]"

# ── 10d. PROVE-RED (full-report branch): excise ITS cross-check block,
# confirm the exact originally-reported shape reappears — a ledger with a
# real path in it (not zero) reporting a clean PASS while older history from
# earlier the same session is gone ──
MUTANT3="$SANDBOX/verify-edits.mutant3"
sed '/# --- mid-session-clear cross-check (full-report): begin ---/,/# --- mid-session-clear cross-check (full-report): end ---/d' \
  "$VERIFY" > "$MUTANT3"
chmod +x "$MUTANT3"
if grep -q "mid-session-clear cross-check (full-report): begin" "$MUTANT3"; then
  bad "mutant3: full-report cross-check block was not actually removed (still present)"
else
  ok "mutant3: full-report mid-session-clear cross-check block successfully excised"
fi
mutant3_out="$(cd "$GITREPO" && env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" \
  CLAUDE_PLUGIN_ROOT="$REPO" "$MUTANT3" --quick 2>&1)"
mutant3_rc=$?
[ "$mutant3_rc" -eq 0 ] && ok "PROVE-RED: mutant3 (no full-report cross-check) reproduces the old false-green (exit 0)" \
                        || bad "PROVE-RED: mutant3 unexpectedly exits $mutant3_rc — assertion may be tautological"
case "$mutant3_out" in
  *"VERDICT: PASS"*) ok "PROVE-RED: mutant3 reports a clean VERDICT: PASS despite the earlier loss — the original bug shape" ;;
  *) bad "PROVE-RED: mutant3 did not reproduce a clean PASS: $mutant3_out" ;;
esac

real3_rc=0; vfy_in "$GITREPO" --quick >/dev/null 2>&1 || real3_rc=$?
[ "$real3_rc" -eq 2 ] && ok "GREEN restored: real (unmutated) verify-edits exits 2 on the non-empty+prior-loss fixture" \
                      || bad "GREEN restored: expected exit 2, got $real3_rc"

# Settle GITREPO + reset the sandbox .clears trail (test-harness cleanup ONLY —
# real sessions never do this; .clears is designed to be permanent for the
# life of a session) so no state leaks into any test added after this one.
(
  cd "$GITREPO" &&
  git add tracked.txt &&
  git commit -q -m "settle after guarantee 10"
) >/dev/null 2>&1
# clear THEN rm, in that order: 10c logged a fresh entry ("post-clear edit")
# that was never cleared before 10d ended, so the ledger is non-empty right
# here — clearing it first (which legitimately re-records that loss) and
# THEN deleting .clears is the only order that actually ends up empty.
# rm-then-clear would let this very clear repopulate .clears immediately
# after the rm, silently carrying guarantee 10's residue into guarantee 11.
trk clear >/dev/null 2>&1
rm -f "$SANDBOX/heimdall-edits/$SID.clears"

# ── 11. UNTRACKED-GIT-DIFF: a raw (non-tool) edit the ledger never saw ──
# This environment's own guidance steers agents toward raw Bash (sed/cat/
# heredoc/cp) over the Write/Edit tools whenever Bash can do the job — the
# PostToolUse hook only matches four tool names, so a raw-Bash edit never
# reaches `edit-tracker log` at all. Prove a ledger that correctly logged ONE
# real edit, while a SECOND real edit sits dirty in git and was never logged,
# is still refused — not quietly certified as if the logged file were the
# whole story.
LOGGED="$GITREPO/logged.txt"
RAW="$GITREPO/raw-bash-edit.txt"
printf 'baseline\n' > "$LOGGED"
printf 'baseline\n' > "$RAW"
(
  cd "$GITREPO" &&
  git add logged.txt raw-bash-edit.txt &&
  git commit -q -m "guarantee 11 baseline"
) >/dev/null 2>&1

printf 'logged change\n' >> "$LOGGED"
trk log Edit "$LOGGED" >/dev/null 2>&1
printf 'raw change\n' >> "$RAW"     # simulates a raw-Bash edit: never `trk log`'d

out="$(vfy_in "$GITREPO" --quick 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "UNTRACKED-GIT-DIFF: verify-edits refuses to certify (got 2)" \
                || bad "UNTRACKED-GIT-DIFF: expected exit 2, got $rc: $out"
case "$out" in
  *"raw-bash-edit.txt"*) ok "UNTRACKED-GIT-DIFF: banner names the specific untracked file" ;;
  *) bad "UNTRACKED-GIT-DIFF: banner did not name raw-bash-edit.txt: $out" ;;
esac
case "$out" in
  *"VERDICT: PASS"*) bad "UNTRACKED-GIT-DIFF: still claims a clean PASS: $out" ;;
  *) ok "UNTRACKED-GIT-DIFF: output does not read like a clean pass" ;;
esac

joutU="$(vfy_in "$GITREPO" --json 2>&1)"; jrcU=$?
[ "$jrcU" -eq 2 ] && ok "UNTRACKED-GIT-DIFF: --json exits 2" \
                  || bad "UNTRACKED-GIT-DIFF: --json expected exit 2, got $jrcU"
case "$joutU" in
  *'"verdict": "NON_VERIFIED"'*) ok "UNTRACKED-GIT-DIFF: --json verdict NON_VERIFIED" ;;
  *) bad "UNTRACKED-GIT-DIFF: --json verdict wrong: $joutU" ;;
esac
case "$joutU" in
  *'"reason": "untracked-git-diff"'*) ok "UNTRACKED-GIT-DIFF: --json reason untracked-git-diff" ;;
  *) bad "UNTRACKED-GIT-DIFF: --json reason wrong: $joutU" ;;
esac
printf '%s' "$joutU" | JSON_OK && ok "UNTRACKED-GIT-DIFF: --json stdout is valid JSON" \
                                || bad "UNTRACKED-GIT-DIFF: --json stdout is not valid JSON: $joutU"

# Control: once the previously-raw edit is ALSO logged, the gap is closed and
# a normal pass resumes — proves this targets the GAP, not "any dirty file".
trk log Edit "$RAW" >/dev/null 2>&1
out2="$(vfy_in "$GITREPO" --quick 2>&1)"; rc2=$?
case "$out2" in
  *"VERDICT: PASS"*) ok "UNTRACKED-GIT-DIFF control: once logged too, a normal PASS resumes (got $rc2)" ;;
  *) bad "UNTRACKED-GIT-DIFF control: expected a resumed PASS: $out2 (rc=$rc2)" ;;
esac

# ── 11a. PROVE-RED: the untracked-git-diff cross-check is falsifiable ──
# A fresh file, never logged even once: $RAW is disqualified for this re-open
# — the control step just above already logged it, and edit-tracker's ledger
# is a deduplicated PATH set, not a per-edit or content-hash record, so a
# path once logged stays "seen" even when it is edited again afterward
# without a fresh `trk log` call. Re-dirtying $RAW here would test a gap this
# cross-check cannot and should not close (that needs edit-tracker.c itself
# to track per-edit state, not just paths — out of scope) — RAW2 exercises
# the real, intended gap: a path the ledger has NEVER seen.
RAW2="$GITREPO/raw-bash-edit-2.txt"
printf 'baseline2\n' > "$RAW2"
(
  cd "$GITREPO" &&
  git add raw-bash-edit-2.txt &&
  git commit -q -m "guarantee 11a baseline"
) >/dev/null 2>&1
printf 'raw change 2\n' >> "$RAW2"   # a second, never-logged raw-Bash edit
MUTANT4="$SANDBOX/verify-edits.mutant4"
sed '/# --- untracked-git-diff cross-check: begin ---/,/# --- untracked-git-diff cross-check: end ---/d' \
  "$VERIFY" > "$MUTANT4"
chmod +x "$MUTANT4"
if grep -q "untracked-git-diff cross-check: begin" "$MUTANT4"; then
  bad "mutant4: untracked-git-diff cross-check block was not actually removed"
else
  ok "mutant4: untracked-git-diff cross-check block successfully excised"
fi
mutant4_out="$(cd "$GITREPO" && env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" \
  CLAUDE_PLUGIN_ROOT="$REPO" "$MUTANT4" --quick 2>&1)"
mutant4_rc=$?
[ "$mutant4_rc" -eq 0 ] && ok "PROVE-RED: mutant4 (no untracked-diff cross-check) reproduces the old false-green (exit 0)" \
                        || bad "PROVE-RED: mutant4 unexpectedly exits $mutant4_rc — assertion may be tautological"
case "$mutant4_out" in
  *"VERDICT: PASS"*) ok "PROVE-RED: mutant4 reports a clean VERDICT: PASS despite the untracked dirty file — the original bug shape" ;;
  *) bad "PROVE-RED: mutant4 did not reproduce a clean PASS: $mutant4_out" ;;
esac

real4_out="$(vfy_in "$GITREPO" --quick 2>&1)"; real4_rc=$?
[ "$real4_rc" -eq 2 ] && ok "GREEN restored: real (unmutated) verify-edits exits 2 on the re-opened untracked-diff fixture" \
                      || bad "GREEN restored: expected exit 2, got $real4_rc"
case "$real4_out" in
  *"raw-bash-edit-2.txt"*) ok "GREEN restored: banner names the newly re-opened file specifically" ;;
  *) bad "GREEN restored: banner did not name raw-bash-edit-2.txt: $real4_out" ;;
esac

# Settle GITREPO once more so no dirty state leaks past this point.
(
  cd "$GITREPO" &&
  git add logged.txt raw-bash-edit.txt raw-bash-edit-2.txt &&
  git commit -q -m "settle after guarantee 11"
) >/dev/null 2>&1
# clear THEN rm — same reasoning as "settle after guarantee 10" above: this
# section's own control step logged $RAW again, so the ledger is non-empty
# right here, and rm-then-clear would let this clear repopulate .clears.
trk clear >/dev/null 2>&1
rm -f "$SANDBOX/heimdall-edits/$SID.clears"

echo "--------------------------------------------------------------------"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

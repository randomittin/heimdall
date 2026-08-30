#!/usr/bin/env bash
# test/sweep-receipt-gate.test.sh — A SWEEP CLAIM MUST BE A CHECKABLE FACT.
#
# WHY THIS EXISTS. One session produced three measured overclaims: work called
# "queued" with no queue behind it, a tool called "landed" that was dead code with no
# live entry point, and a test sweep called "running now" that had actually exited
# three hours earlier. The common shape: reporting LAST-KNOWN state as CURRENT state.
# For sweep claims specifically, bin/heimdall-state's four quality-gate flags
# (tests_passing, lint_clean, conflict_reflection_done, dirty) were booleans anyone
# could flip by hand via `heimdall-state mark-clean` without ever running a suite —
# exactly how a stale "tests passing" claim stayed green. test/run-all.sh now writes
# a receipt (.heimdall/receipts/last-sweep.json, or under $HEIMDALL_HOME/receipts/ if
# that var is set — mirrors bin/heimdall-delivery-audit's own
# `${HEIMDALL_HOME:-$ROOT/.heimdall}` fallback) on EVERY run, pass or fail, and
# bin/heimdall-state check-quality-gates now refuses to trust a stale/absent/dirty/
# failing one.
#
# FALSIFIABLE claims proven:
#   (A) WRITER — a real, hermetic, filtered (--min 1) invocation of the ACTUAL
#       modified test/run-all.sh writes the receipt unconditionally at the documented
#       default (repo-relative) path, with head_sha matching the fixture's real HEAD,
#       tree_clean=true on an untouched tree, and exit_code=0 on an all-green run —
#       then, re-run after the fixture suite is made to fail, OVERWRITES exit_code to
#       1 rather than leaving the prior green receipt in place (this is defect #3
#       reproduced exactly: a stale green claim outliving the run it described).
#   (B) GATE FAILS — no receipt at all => exit 2, message names the absence (defect #4
#       reproduced exactly: "sweep needed" with nothing started, nothing to check).
#   (C) GATE PASSES — a fresh receipt matching current HEAD, clean tree, exit_code=0
#       => exit 0.
#   (D) GATE FAILS — STALE head_sha (commits landed since) => exit 2, names staleness
#       explicitly (defect #3 reproduced exactly: "running now" was actually old).
#   (E) GATE FAILS — receipt recorded a DIRTY tree => exit 2, names it explicitly.
#   (F) GATE FAILS — receipt recorded a nonzero exit code => exit 2, names it.
#   (G) GATE FAILS — receipt was recorded for a different repo => exit 2, names it.
#   (H) GATE FAILS — receipt file is not valid JSON => exit 2, names it.
#   (I) REGRESSION — a non-git cwd with the old four flags clean (the exact fixture
#       shape test/pre-push-quality-gate-blocking.test.sh's case 2 uses) still exits
#       0: the new checks are a no-op outside a resolvable git repo, never a forced
#       failure unrelated to what that suite already proves.
#   (J) REPORTER — bin/heimdall-delivery-audit's [b] section prints a SWEEP-GATE
#       verdict line reflecting the same receipt, and its own exit code is provably
#       IDENTICAL regardless of whether that verdict reads WOULD-PASS or WOULD-BLOCK —
#       genuinely advisory, never a second gate.
#
# HERMETIC. Every case runs inside a throwaway `git init` repo under $TMPDIR. No case
# ever exports a shared $HEIMDALL_HOME for the whole file: the WRITER case explicitly
# unsets it (to prove the true repo-relative default), and every GATE/REPORTER case
# passes its OWN throwaway $HEIMDALL_HOME per invocation (to prove the override path
# too, and so cases can never see each other's receipts). Nothing here touches the
# operator's real ~/.heimdall or .planning/, and nothing here runs the real 320-suite
# sweep — only a single trivial fixture suite, filtered in with --min 1.
#
# EXIT: 0 = every proof holds; 1 = any FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUN_ALL="$ROOT/test/run-all.sh"
STATE_BIN="$ROOT/bin/heimdall-state"
AUDIT_BIN="$ROOT/bin/heimdall-delivery-audit"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
[ -f "$RUN_ALL" ]    || { echo "FATAL: missing $RUN_ALL" >&2; exit 2; }
[ -x "$STATE_BIN" ]  || { echo "FATAL: missing/!exec $STATE_BIN" >&2; exit 2; }
[ -x "$AUDIT_BIN" ]  || { echo "FATAL: missing/!exec $AUDIT_BIN" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-sweep-receipt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Defensive: make sure NO ambient HEIMDALL_HOME leaks into this run. The writer case
# below relies on it being genuinely unset to exercise the true repo-relative default;
# every other case sets its own throwaway value per invocation.
unset HEIMDALL_HOME 2>/dev/null || true

newrepo() {  # <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email dev@example.com
  git -C "$1" config user.name Dev
}

mk_state() {  # <dir> — heimdall-state.json with all four legacy gate flags green
  ( cd "$1" && "$STATE_BIN" init >/dev/null 2>&1 && "$STATE_BIN" mark-clean >/dev/null 2>&1 )
}

write_receipt() {  # <home> <repo> <head_sha> <tree_clean:true|false> <exit_code:0|1>
  mkdir -p "$1/receipts"
  jq -n --arg repo "$2" --arg head_sha "$3" --argjson tree_clean "$4" --argjson exit_code "$5" \
    '{finished_at:"2026-01-01T00:00:00Z", repo:$repo, head_sha:$head_sha,
      tree_clean:$tree_clean, exit_code:$exit_code, suites_total:1, suites_passed:1,
      suites_failed:0, suites_timeout:0, suites_discrepancy:0, suites_unparsed:0,
      assertions_passed:1, assertions_failed:0, duration_s:1}' > "$1/receipts/last-sweep.json"
}

gate_run() {  # <repo-dir> <heimdall-home-dir>
  ( cd "$1" && HEIMDALL_HOME="$2" "$STATE_BIN" check-quality-gates )
}

echo "════════════════════════════════════════════════════════════════"
echo "sweep receipt gate — a green claim must be a checkable fact"
echo "════════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# A. WRITER — the real, modified test/run-all.sh, hermetically, on a 1-suite fixture.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- A. WRITER: real filtered run-all.sh invocation writes the receipt -----------"
RW="$WORK/writer-repo"
newrepo "$RW"
mkdir -p "$RW/test"
cp "$RUN_ALL" "$RW/test/run-all.sh"
cat > "$RW/test/dummy.test.sh" <<'DUMMYEOF'
#!/usr/bin/env bash
# throwaway fixture suite for test/sweep-receipt-gate.test.sh -- deliberately trivial.
set -uo pipefail
if [ "${DUMMY_SHOULD_FAIL:-0}" = "1" ]; then
  echo "1 passed, 1 failed"
  exit 1
fi
echo "1 passed, 0 failed"
exit 0
DUMMYEOF
chmod +x "$RW/test/dummy.test.sh"
git -C "$RW" add -A
git -C "$RW" commit -q -m "fixture: dummy suite + run-all.sh copy"
RW_SHA="$(git -C "$RW" rev-parse HEAD)"
RW_RECEIPT="$RW/.heimdall/receipts/last-sweep.json"

( cd "$RW" && bash test/run-all.sh --min 1 ) >"$WORK/a.out" 2>&1
A_RC=$?
[ "$A_RC" = 0 ] && ok "A1 hermetic 1-suite green run exits 0" \
  || bad "A1 expected exit 0, got $A_RC" "$(cat "$WORK/a.out")"
[ -f "$RW_RECEIPT" ] && ok "A2 receipt written at the documented default path (repo-relative .heimdall/receipts/, no HEIMDALL_HOME set)" \
  || bad "A2 no receipt written at $RW_RECEIPT" "$(cat "$WORK/a.out")"
[ "$(jq -r '.head_sha' "$RW_RECEIPT" 2>/dev/null)" = "$RW_SHA" ] \
  && ok "A3 receipt head_sha matches the fixture repo's actual HEAD" \
  || bad "A3 head_sha mismatch" "$(cat "$RW_RECEIPT" 2>/dev/null)"
[ "$(jq -r '.tree_clean' "$RW_RECEIPT" 2>/dev/null)" = "true" ] \
  && ok "A4 receipt tree_clean=true on an untouched tree" \
  || bad "A4 tree_clean not true" "$(cat "$RW_RECEIPT" 2>/dev/null)"
[ "$(jq -r '.exit_code' "$RW_RECEIPT" 2>/dev/null)" = "0" ] \
  && ok "A5 receipt exit_code=0 on an all-green run" \
  || bad "A5 exit_code not 0" "$(cat "$RW_RECEIPT" 2>/dev/null)"

echo "-- A(red). WRITER overwrites a prior green receipt on a failing run ------------"
( cd "$RW" && DUMMY_SHOULD_FAIL=1 bash test/run-all.sh --min 1 ) >"$WORK/a2.out" 2>&1
A2_RC=$?
[ "$A2_RC" != 0 ] && ok "A6 hermetic 1-suite RED run exits nonzero" \
  || bad "A6 expected nonzero exit, got $A2_RC" "$(cat "$WORK/a2.out")"
[ "$(jq -r '.exit_code' "$RW_RECEIPT" 2>/dev/null)" = "1" ] \
  && ok "A7 receipt exit_code updated to 1 -- a red run cannot leave the prior green receipt in place (defect #3, reproduced and closed)" \
  || bad "A7 receipt still shows a stale exit_code" "$(cat "$RW_RECEIPT" 2>/dev/null)"

# ══════════════════════════════════════════════════════════════════════════════
# B-H. GATE — bin/heimdall-state check-quality-gates against hand-built receipts.
# ══════════════════════════════════════════════════════════════════════════════
RG="$WORK/gate-repo"
newrepo "$RG"
echo one > "$RG/f.txt"; git -C "$RG" add -A; git -C "$RG" commit -q -m one
RG_SHA="$(git -C "$RG" rev-parse HEAD)"
# Canonical (symlink-resolved) toplevel -- this is what a real receipt written by the
# fixed test/run-all.sh writer now contains, and what bin/heimdall-state's own
# `git rev-parse --show-toplevel` will compare against. Using the raw $RG string here
# instead false-positived on macOS, where $TMPDIR (/var/folders/...) and its
# symlink-resolved form (/private/var/folders/...) name the same directory with two
# different strings.
RG_CANON="$(git -C "$RG" rev-parse --show-toplevel)"
mk_state "$RG"

echo "-- B. no receipt at all ----------------------------------------------------------"
HOME_B="$WORK/home-b"; mkdir -p "$HOME_B"
OUT_B="$(gate_run "$RG" "$HOME_B" 2>&1)"; RC_B=$?
[ "$RC_B" = 2 ] && ok "B1 no receipt => exit 2" || bad "B1 expected exit 2, got $RC_B" "$OUT_B"
echo "$OUT_B" | grep -qi "no sweep receipt" \
  && ok "B2 message names the absence explicitly (defect #4, reproduced and closed)" \
  || bad "B2 message does not name the absence" "$OUT_B"

echo "-- C. fresh receipt: matching HEAD, clean tree, exit_code=0 ----------------------"
HOME_C="$WORK/home-c"; mkdir -p "$HOME_C"
write_receipt "$HOME_C" "$RG_CANON" "$RG_SHA" true 0
OUT_C="$(gate_run "$RG" "$HOME_C" 2>&1)"; RC_C=$?
[ "$RC_C" = 0 ] && ok "C1 fresh matching clean rc=0 receipt => exit 0" \
  || bad "C1 expected exit 0, got $RC_C" "$OUT_C"
echo "$OUT_C" | grep -q "All quality gates pass" \
  && ok "C2 prints the pass line" || bad "C2 missing pass line" "$OUT_C"

echo "-- D. stale receipt: head_sha != current HEAD ------------------------------------"
HOME_D="$WORK/home-d"; mkdir -p "$HOME_D"
write_receipt "$HOME_D" "$RG_CANON" "0000000000000000000000000000000000000000" true 0
OUT_D="$(gate_run "$RG" "$HOME_D" 2>&1)"; RC_D=$?
[ "$RC_D" = 2 ] && ok "D1 stale sha => exit 2" || bad "D1 expected exit 2, got $RC_D" "$OUT_D"
echo "$OUT_D" | grep -qi "STALE" \
  && ok "D2 message names staleness explicitly (defect #3, reproduced and closed)" \
  || bad "D2 message does not name staleness" "$OUT_D"

echo "-- E. receipt recorded a dirty tree ----------------------------------------------"
HOME_E="$WORK/home-e"; mkdir -p "$HOME_E"
write_receipt "$HOME_E" "$RG_CANON" "$RG_SHA" false 0
OUT_E="$(gate_run "$RG" "$HOME_E" 2>&1)"; RC_E=$?
[ "$RC_E" = 2 ] && ok "E1 dirty-tree receipt => exit 2" || bad "E1 expected exit 2, got $RC_E" "$OUT_E"
echo "$OUT_E" | grep -qi "DIRTY" \
  && ok "E2 message names the dirty tree explicitly" || bad "E2 message does not name it" "$OUT_E"

echo "-- F. receipt recorded a nonzero exit code ----------------------------------------"
HOME_F="$WORK/home-f"; mkdir -p "$HOME_F"
write_receipt "$HOME_F" "$RG_CANON" "$RG_SHA" true 1
OUT_F="$(gate_run "$RG" "$HOME_F" 2>&1)"; RC_F=$?
[ "$RC_F" = 2 ] && ok "F1 nonzero-exit receipt => exit 2" || bad "F1 expected exit 2, got $RC_F" "$OUT_F"
echo "$OUT_F" | grep -qi "FAILING run" \
  && ok "F2 message names the failing run explicitly" || bad "F2 message does not name it" "$OUT_F"

echo "-- G. receipt recorded for a different repo ---------------------------------------"
HOME_G="$WORK/home-g"; mkdir -p "$HOME_G"
write_receipt "$HOME_G" "/some/other/repo" "$RG_SHA" true 0
OUT_G="$(gate_run "$RG" "$HOME_G" 2>&1)"; RC_G=$?
[ "$RC_G" = 2 ] && ok "G1 repo-scope mismatch => exit 2" || bad "G1 expected exit 2, got $RC_G" "$OUT_G"
echo "$OUT_G" | grep -qi "different repo" \
  && ok "G2 message names the repo mismatch explicitly" || bad "G2 message does not name it" "$OUT_G"

echo "-- H. receipt file is not valid JSON -----------------------------------------------"
HOME_H="$WORK/home-h"; mkdir -p "$HOME_H/receipts"
printf 'not json at all {{{' > "$HOME_H/receipts/last-sweep.json"
OUT_H="$(gate_run "$RG" "$HOME_H" 2>&1)"; RC_H=$?
[ "$RC_H" = 2 ] && ok "H1 malformed receipt JSON => exit 2" || bad "H1 expected exit 2, got $RC_H" "$OUT_H"
echo "$OUT_H" | grep -qi "not valid JSON" \
  && ok "H2 message names the parse failure explicitly" || bad "H2 message does not name it" "$OUT_H"

# ══════════════════════════════════════════════════════════════════════════════
# I. REGRESSION — non-git cwd (test/pre-push-quality-gate-blocking.test.sh's own
#    case-2 fixture shape) must stay a no-op for the new checks.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- I. non-git cwd is unaffected (regression vs pre-push-quality-gate-blocking) ----"
RI="$WORK/non-git-dir"; mkdir -p "$RI"
mk_state "$RI"
OUT_I="$( (cd "$RI" && HEIMDALL_HOME="$WORK/home-i-unused" "$STATE_BIN" check-quality-gates) 2>&1 )"; RC_I=$?
[ "$RC_I" = 0 ] \
  && ok "I1 non-git cwd with the old four flags clean still exits 0 -- the sweep-receipt block is a no-op outside a resolvable git repo" \
  || bad "I1 expected exit 0 for a non-git cwd, got $RC_I" "$OUT_I"

# ══════════════════════════════════════════════════════════════════════════════
# J. REPORTER — bin/heimdall-delivery-audit section [b] reflects the receipt but
#    never gates on it.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- J. delivery-audit reports the sweep-gate verdict but never gates on it --------"
HOME_J1="$WORK/home-j1"; mkdir -p "$HOME_J1"
write_receipt "$HOME_J1" "$RG_CANON" "$RG_SHA" true 0
OUT_J1="$(HMD_DELIVERY_AUDIT_ROOT="$RG" HEIMDALL_HOME="$HOME_J1" "$AUDIT_BIN" 2>&1)"; RC_J1=$?
echo "$OUT_J1" | grep -q "SWEEP-GATE verdict.*WOULD-PASS" \
  && ok "J1 delivery-audit reports WOULD-PASS for a fresh matching receipt" \
  || bad "J1 no WOULD-PASS verdict line found" "$OUT_J1"

HOME_J2="$WORK/home-j2"; mkdir -p "$HOME_J2"
write_receipt "$HOME_J2" "$RG_CANON" "0000000000000000000000000000000000000000" true 0
OUT_J2="$(HMD_DELIVERY_AUDIT_ROOT="$RG" HEIMDALL_HOME="$HOME_J2" "$AUDIT_BIN" 2>&1)"; RC_J2=$?
echo "$OUT_J2" | grep -q "SWEEP-GATE verdict.*WOULD-BLOCK" \
  && ok "J2 delivery-audit reports WOULD-BLOCK for a stale receipt" \
  || bad "J2 no WOULD-BLOCK verdict line found" "$OUT_J2"

[ "$RC_J1" = "$RC_J2" ] \
  && ok "J3 section [b] is genuinely advisory-only: exit code identical ($RC_J1) regardless of which sweep-gate verdict is shown" \
  || bad "J3 delivery-audit exit code changed with receipt content ($RC_J1 vs $RC_J2) -- section [b] must never gate" "$OUT_J1 / $OUT_J2"

echo
printf "  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

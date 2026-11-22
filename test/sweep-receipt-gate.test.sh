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
#   (A2) WRITER — TEAM MODE CARVE-OUT — an untracked file under a documented TEAM
#       MODE coordination-substrate directory (.planning/ledger/checkpoints/, the
#       exact shape hmd's own checkpoint-share hook publishes mid-sweep) does NOT
#       flip tree_clean to false; the identical receipt-write, with a genuinely
#       MODIFIED TRACKED file also present at the same time, DOES still flip
#       tree_clean to false and check-quality-gates still blocks with the same
#       DIRTY message section E proves — and an untracked file OUTSIDE the
#       allowlist still dirties the tree too, unchanged. This closes a real
#       release blocker: a sweep that finished 9275/9280 green recorded
#       tree_clean=false solely because hmd's own coordination hook had written an
#       untracked checkpoint file mid-run — a receipt that can never legitimately
#       be green is exactly as useless as one that is always green.
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
#   (M) USE-CASE RECEIPT, WRITER (operator decision 2026-11-22, "B": a push of heimdall's own repo
#       stands on a green use-case journey receipt, a release on the full sweep) — the REAL
#       test/use-cases/run.sh, on a one-journey fixture, writes .heimdall/receipts/use-cases.json
#       atomically after a FULL green run on a clean committed tree (commit, tree, counts, time) and
#       writes none — saying why on stderr — for --only, --no-mutants, a dirty tree or a red run;
#       bin/lib/hmd_use_case_receipt.py's `write` refuses a HEAD that moved by anything but the
#       hooks' own journal and ledger records, and `clean` is run-all.sh's own tree_clean predicate.
#   (N) USE-CASE RECEIPT, GATE — check-quality-gates passes when a green use-case receipt vouches for
#       HEAD (beside no sweep receipt, or a RED one), re-deriving the commit and its tree from git,
#       tolerating only the hooks' own journal/ledger commits after the run; it BLOCKS, naming
#       `bash test/use-cases/run.sh`, on a missing, red, forged, stale, garbled or linked receipt,
#       and never overrides the other gates; a receipt the writer wrote passes it.
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
# Fixtures that need a green gate but are not about lint waive it explicitly (section L):
# mark-clean no longer sets lint_clean without a passing lint_last_run.
LINT_FIXTURE_WAIVER="fixture: this suite proves the sweep-receipt gate, not lint evidence"

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
  ( cd "$1" && "$STATE_BIN" init >/dev/null 2>&1 && HMD_LINT_WAIVER="$LINT_FIXTURE_WAIVER" "$STATE_BIN" mark-clean >/dev/null 2>&1 )
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
mkdir -p "$RW/bin/lib"
cp "$ROOT/bin/lib/hook-owned-path.sh" "$RW/bin/lib/hook-owned-path.sh"
cp "$STATE_BIN" "$RW/bin/heimdall-state"
chmod +x "$RW/bin/heimdall-state"
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
# Deliberately OUTSIDE $RW, same reason $RWS_STATE further down is: a
# heimdall-state.json written via the default cwd-relative path would itself be a
# second, allowlist-outside untracked file, confounding the tree_clean assertions
# this section checks. HEIMDALL_STATE_FILE travels with every run-all.sh
# invocation below so the mark-tests-clean call run-all.sh now makes internally
# lands here too, not at $RW/heimdall-state.json.
RW_STATE="$WORK/rw-heimdall-state.json"
( cd "$RW" && HEIMDALL_STATE_FILE="$RW_STATE" "$STATE_BIN" init >/dev/null 2>&1 \
  && HEIMDALL_STATE_FILE="$RW_STATE" "$STATE_BIN" mark-dirty >/dev/null 2>&1 )

( cd "$RW" && HEIMDALL_STATE_FILE="$RW_STATE" bash test/run-all.sh --min 1 ) >"$WORK/a.out" 2>&1
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
[ "$(jq -r '.quality_gates.tests_passing' "$RW_STATE" 2>/dev/null)" = "true" ] \
  && ok "A5b a green sweep also marks the legacy tests_passing flag true" \
  || bad "A5b tests_passing not flipped true after a green sweep" "$(cat "$RW_STATE" 2>/dev/null)"
[ "$(jq -r '.quality_gates.dirty' "$RW_STATE" 2>/dev/null)" = "false" ] \
  && ok "A5c a green sweep also clears the legacy dirty flag" \
  || bad "A5c dirty flag not cleared after a green sweep" "$(cat "$RW_STATE" 2>/dev/null)"
[ "$(jq -r '.quality_gates.lint_clean' "$RW_STATE" 2>/dev/null)" != "true" ] \
  && ok "A5d a green TEST sweep does NOT also claim lint_clean -- only bin/heimdall-stop-lint's real linter run may set that" \
  || bad "A5d green sweep incorrectly claimed lint_clean=true with no linter ever run" "$(cat "$RW_STATE" 2>/dev/null)"

echo "-- A(red). WRITER overwrites a prior green receipt on a failing run ------------"
( cd "$RW" && HEIMDALL_STATE_FILE="$RW_STATE" "$STATE_BIN" mark-dirty >/dev/null 2>&1 )
( cd "$RW" && DUMMY_SHOULD_FAIL=1 HEIMDALL_STATE_FILE="$RW_STATE" bash test/run-all.sh --min 1 ) >"$WORK/a2.out" 2>&1
A2_RC=$?
[ "$A2_RC" != 0 ] && ok "A6 hermetic 1-suite RED run exits nonzero" \
  || bad "A6 expected nonzero exit, got $A2_RC" "$(cat "$WORK/a2.out")"
[ "$(jq -r '.exit_code' "$RW_RECEIPT" 2>/dev/null)" = "1" ] \
  && ok "A7 receipt exit_code updated to 1 -- a red run cannot leave the prior green receipt in place (defect #3, reproduced and closed)" \
  || bad "A7 receipt still shows a stale exit_code" "$(cat "$RW_RECEIPT" 2>/dev/null)"
[ "$(jq -r '.quality_gates.dirty' "$RW_STATE" 2>/dev/null)" = "true" ] \
  && ok "A7b a RED sweep must NOT clear the legacy dirty flag (mark-tests-clean is green-only)" \
  || bad "A7b dirty flag was cleared after a RED sweep" "$(cat "$RW_STATE" 2>/dev/null)"
[ "$(jq -r '.quality_gates.tests_passing' "$RW_STATE" 2>/dev/null)" != "true" ] \
  && ok "A7c a RED sweep must NOT flip tests_passing true" \
  || bad "A7c tests_passing was true after a RED sweep" "$(cat "$RW_STATE" 2>/dev/null)"

echo "-- A2. WRITER: TEAM MODE substrate carve-out (untracked-exempt, tracked-not) ----"
RWS="$WORK/writer-repo-substrate"
newrepo "$RWS"
mkdir -p "$RWS/test"
cp "$RUN_ALL" "$RWS/test/run-all.sh"
mkdir -p "$RWS/bin/lib"
cp "$ROOT/bin/lib/hook-owned-path.sh" "$RWS/bin/lib/hook-owned-path.sh"
cat > "$RWS/test/dummy.test.sh" <<'DUMMYEOF'
#!/usr/bin/env bash
# throwaway fixture suite for test/sweep-receipt-gate.test.sh -- deliberately trivial.
set -uo pipefail
echo "1 passed, 0 failed"
exit 0
DUMMYEOF
chmod +x "$RWS/test/dummy.test.sh"
echo "v1" > "$RWS/TRACKED.txt"
# Seed an ALREADY-TRACKED sibling under ledger/checkpoints/, mirroring the real repo
# (git ls-files .planning/ledger/checkpoints/ there returns ~58 tracked files already).
# Without this, .planning/ has never been tracked at all in this from-scratch fixture,
# so git's default (non -uall) untracked-files mode collapses the whole new tree into
# one directory-level line (`?? .planning/`) instead of listing the file underneath --
# an artifact of an empty fixture repo, not of the real target repo, where the
# directory is always already known to git because of its many tracked siblings.
mkdir -p "$RWS/.planning/ledger/checkpoints"
echo '{"haid":"existing.placeholder-machine-0000"}' \
  > "$RWS/.planning/ledger/checkpoints/haid_existing.placeholder-machine-0000.json"
git -C "$RWS" add -A
git -C "$RWS" commit -q -m "fixture: dummy suite + run-all.sh copy + tracked file"
RWS_RECEIPT="$RWS/.heimdall/receipts/last-sweep.json"
# Isolated OUTSIDE $RWS on purpose: heimdall-state.json is unrelated legacy-flag
# bookkeeping (see mk_state), and if it were written INSIDE $RWS via the default
# cwd-relative path it would itself become a second, allowlist-outside untracked
# file -- confounding exactly the carve-out this block exists to prove in isolation.
RWS_STATE="$WORK/rws-heimdall-state.json"

# -- untracked TEAM MODE substrate file only: must NOT dirty the tree --------------
mkdir -p "$RWS/.planning/ledger/checkpoints"
echo '{"haid":"unknown.test-machine-0001","note":"mid-sweep publish, not source"}' \
  > "$RWS/.planning/ledger/checkpoints/haid_unknown.test-machine-0001.json"
( cd "$RWS" && bash test/run-all.sh --min 1 ) >"$WORK/sub-a.out" 2>&1
SUB_A_RC=$?
[ "$SUB_A_RC" = 0 ] && ok "A8 hermetic run exits 0 with an untracked TEAM MODE substrate file present" \
  || bad "A8 expected exit 0, got $SUB_A_RC" "$(cat "$WORK/sub-a.out")"
[ "$(jq -r '.tree_clean' "$RWS_RECEIPT" 2>/dev/null)" = "true" ] \
  && ok "A9 receipt tree_clean stays true -- untracked .planning/ledger/checkpoints/ file is the documented TEAM MODE carve-out, not a stale-green code change" \
  || bad "A9 tree_clean flipped false for an untracked substrate-only file" "$(cat "$RWS_RECEIPT" 2>/dev/null)"
( cd "$RWS" && HEIMDALL_STATE_FILE="$RWS_STATE" "$STATE_BIN" init >/dev/null 2>&1 \
  && HEIMDALL_STATE_FILE="$RWS_STATE" HMD_LINT_WAIVER="$LINT_FIXTURE_WAIVER" "$STATE_BIN" mark-clean >/dev/null 2>&1 )
SUB_GATE1_OUT="$(cd "$RWS" && HEIMDALL_HOME="$RWS/.heimdall" HEIMDALL_STATE_FILE="$RWS_STATE" "$STATE_BIN" check-quality-gates 2>&1)"; SUB_GATE1_RC=$?
[ "$SUB_GATE1_RC" = 0 ] \
  && ok "A10 check-quality-gates PASSES against this receipt -- an untracked runtime/coordination file alone never blocks the gate" \
  || bad "A10 expected exit 0, got $SUB_GATE1_RC" "$SUB_GATE1_OUT"

# -- SAME substrate file still present, PLUS a modified TRACKED file: must dirty ---
echo "v2 -- uncommitted edit" > "$RWS/TRACKED.txt"
( cd "$RWS" && bash test/run-all.sh --min 1 ) >"$WORK/sub-b.out" 2>&1
SUB_B_RC=$?
[ "$SUB_B_RC" = 0 ] && ok "A11 hermetic run still exits 0 (dummy suite itself still passes)" \
  || bad "A11 expected exit 0, got $SUB_B_RC" "$(cat "$WORK/sub-b.out")"
[ "$(jq -r '.tree_clean' "$RWS_RECEIPT" 2>/dev/null)" = "false" ] \
  && ok "A12 receipt tree_clean flips to false -- a MODIFIED TRACKED file (TRACKED.txt) is never exempt, even with an exempt substrate file also present (the carve-out does not swallow real dirtiness)" \
  || bad "A12 tree_clean stayed true with a modified tracked file present" "$(cat "$RWS_RECEIPT" 2>/dev/null)"
SUB_GATE2_OUT="$(cd "$RWS" && HEIMDALL_HOME="$RWS/.heimdall" HEIMDALL_STATE_FILE="$RWS_STATE" "$STATE_BIN" check-quality-gates 2>&1)"; SUB_GATE2_RC=$?
[ "$SUB_GATE2_RC" = 2 ] \
  && ok "A13 check-quality-gates BLOCKS against this receipt -- a modified tracked file must still fail the gate (hard constraint, must never regress)" \
  || bad "A13 expected exit 2, got $SUB_GATE2_RC" "$SUB_GATE2_OUT"
echo "$SUB_GATE2_OUT" | grep -qi "DIRTY" \
  && ok "A14 block message names the dirty tree explicitly, same wording the hand-built dirty-tree case in section E checks" \
  || bad "A14 block message does not name the dirty tree" "$SUB_GATE2_OUT"

# -- extra rigor: an untracked file OUTSIDE the substrate allowlist still dirties --
git -C "$RWS" checkout -q -- TRACKED.txt
# -- a MODIFIED TRACKED ledger checkpoint must NOT dirty (2026-09-19) -------------
# bin/heimdall-checkpoint rewrites .planning/ledger/checkpoints/{slug}.json with the
# current head_sha after every commit (this repo's own PostToolUse hooks run it), so
# once the file is tracked it is ` M` at every HEAD, structurally one commit behind.
# Three consecutive 10,124/0 sweeps were refused as DIRTY over exactly this file.
# The modification IS the continuous publishing the carve-out exists for.
echo '{"haid":"existing.placeholder-machine-0000","head_sha":"deadbeef","updated_at":"2026-09-19T00:00:00Z"}' \
  > "$RWS/.planning/ledger/checkpoints/haid_existing.placeholder-machine-0000.json"
( cd "$RWS" && bash test/run-all.sh --min 1 ) >"$WORK/sub-m.out" 2>&1
[ "$(jq -r '.tree_clean' "$RWS_RECEIPT" 2>/dev/null)" = "true" ] \
  && ok "A14b receipt tree_clean stays true -- a MODIFIED tracked ledger/checkpoints/ record is hmd's own post-commit publishing, not a code change" \
  || bad "A14b tree_clean flipped false for a modified tracked ledger checkpoint (the gate would be permanently red after any commit)" "porcelain: $(git -C "$RWS" status --porcelain=v1 --no-renames 2>/dev/null | tr '\n' '|')"
SUB_GATEM_OUT="$(cd "$RWS" && HEIMDALL_HOME="$RWS/.heimdall" HEIMDALL_STATE_FILE="$RWS_STATE" "$STATE_BIN" check-quality-gates 2>&1)"; SUB_GATEM_RC=$?
[ "$SUB_GATEM_RC" = 0 ] \
  && ok "A14c check-quality-gates PASSES with only a modified tracked ledger checkpoint dirty" \
  || bad "A14c expected exit 0, got $SUB_GATEM_RC" "$SUB_GATEM_OUT"
git -C "$RWS" checkout -q -- .planning/ledger/checkpoints/haid_existing.placeholder-machine-0000.json
# -- but a DELETED ledger record still dirties: nothing publishes by deleting -------
git -C "$RWS" rm -q --cached .planning/ledger/checkpoints/haid_existing.placeholder-machine-0000.json 2>/dev/null \
  || rm -f "$RWS/.planning/ledger/checkpoints/haid_existing.placeholder-machine-0000.json"
( cd "$RWS" && bash test/run-all.sh --min 1 ) >"$WORK/sub-d.out" 2>&1
[ "$(jq -r '.tree_clean' "$RWS_RECEIPT" 2>/dev/null)" = "false" ] \
  && ok "A14d receipt tree_clean flips false -- a DELETED ledger record is not exempt (the carve-out covers publishing, not removal)" \
  || bad "A14d a deleted ledger record was treated as clean" "$(cat "$RWS_RECEIPT" 2>/dev/null)"
git -C "$RWS" reset -q --hard HEAD
# -- a DROPPED non-json file under ledger/checkpoints/ must still dirty the tree
# (2026-09-21 exploitable-gap finding: pre-fix, _hook_owned_path in test/run-all.sh
# matched by PATH PREFIX ONLY -- no filename shape, no trailing anchor -- so ANY
# filename under ledger/checkpoints/, not just a real haid_<slug>.json record, hid
# behind the carve-out. A stray, non-json "dropper.sh" must flip tree_clean false.) --
printf '#!/usr/bin/env bash\necho pwned\n' > "$RWS/.planning/ledger/checkpoints/dropper.sh"
( cd "$RWS" && bash test/run-all.sh --min 1 ) >"$WORK/sub-e.out" 2>&1
[ "$(jq -r '.tree_clean' "$RWS_RECEIPT" 2>/dev/null)" = "false" ] \
  && ok "A14e receipt tree_clean flips false -- a non-json file dropped under ledger/checkpoints/ is not a real hook-emitted record and must not hide behind the carve-out" \
  || bad "A14e a dropped non-json file under ledger/checkpoints/ was treated as clean (the 2026-09-21 exploitable gap)" "$(cat "$RWS_RECEIPT" 2>/dev/null)"
rm -f "$RWS/.planning/ledger/checkpoints/dropper.sh"
echo "stray" > "$RWS/some-new-source-file.txt"
( cd "$RWS" && bash test/run-all.sh --min 1 ) >"$WORK/sub-c.out" 2>&1
SUB_C_RC=$?
[ "$SUB_C_RC" = 0 ] && ok "A15 hermetic run still exits 0" \
  || bad "A15 expected exit 0, got $SUB_C_RC" "$(cat "$WORK/sub-c.out")"
[ "$(jq -r '.tree_clean' "$RWS_RECEIPT" 2>/dev/null)" = "false" ] \
  && ok "A16 receipt tree_clean is still false for an untracked file OUTSIDE the TEAM MODE allowlist -- the original stale-green protection for ordinary new files is unchanged" \
  || bad "A16 tree_clean stayed true for a stray untracked file outside the substrate allowlist" "$(cat "$RWS_RECEIPT" 2>/dev/null)"

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

# ══════════════════════════════════════════════════════════════════════════════
# K. GATE — hook-owned-only commits after the receipt do not go stale (the actual
#    bug this file's task exists to fix: this repo's own journal/ledger hooks
#    auto-commit on main after every sweep, so a green receipt used to go stale
#    within seconds of being written).
# ══════════════════════════════════════════════════════════════════════════════
echo "-- K. hook-owned commits after the receipt do not go stale ------------------------"
RK="$WORK/hook-owned-repo"
newrepo "$RK"
echo base > "$RK/f.txt"
git -C "$RK" add -A; git -C "$RK" commit -q -m base
RK_BASE_SHA="$(git -C "$RK" rev-parse HEAD)"
RK_CANON="$(git -C "$RK" rev-parse --show-toplevel)"
mk_state "$RK"

# (a) receipt HEAD + one commit touching ONLY a real journal-shaped hook-owned
#     file => NOT stale, notice printed.
mkdir -p "$RK/.planning/journal"
echo "entry" > "$RK/.planning/journal/2026-09-24-haid_x.md"
git -C "$RK" add .planning/journal/2026-09-24-haid_x.md; git -C "$RK" commit -q -m "journal: hook-owned entry"
RK_SHA_A="$(git -C "$RK" rev-parse HEAD)"
HOME_K1="$WORK/home-k1"; mkdir -p "$HOME_K1"
write_receipt "$HOME_K1" "$RK_CANON" "$RK_BASE_SHA" true 0
OUT_K1="$(gate_run "$RK" "$HOME_K1" 2>&1)"; RC_K1=$?
[ "$RC_K1" = 0 ] && ok "K1 receipt behind by one hook-owned-only commit still PASSES" \
  || bad "K1 expected exit 0, got $RC_K1" "$OUT_K1"
echo "$OUT_K1" | grep -qi "hook-owned" \
  && ok "K2 a one-line notice names the hook-owned skip" \
  || bad "K2 no hook-owned notice printed" "$OUT_K1"

# (b) + one more commit touching bin/anything (NOT hook-owned) => STALE, path named.
mkdir -p "$RK/bin"
echo "echo hi" > "$RK/bin/anything"
git -C "$RK" add bin/anything; git -C "$RK" commit -q -m "code: touch bin/anything"
OUT_K3="$(gate_run "$RK" "$HOME_K1" 2>&1)"; RC_K3=$?
[ "$RC_K3" = 2 ] && ok "K3 a non-hook-owned commit in the same span goes STALE" \
  || bad "K3 expected exit 2, got $RC_K3" "$OUT_K3"
echo "$OUT_K3" | grep -qi "STALE" \
  && ok "K4 message still says STALE" || bad "K4 message does not say STALE" "$OUT_K3"
echo "$OUT_K3" | grep -q "bin/anything" \
  && ok "K5 message names the non-hook-owned path (bin/anything)" \
  || bad "K5 message does not name bin/anything" "$OUT_K3"

# (c) falsifiability of the anchor: journal/evil.md does not match the required
#     dated-haid filename shape => still STALE.
git -C "$RK" reset -q --hard "$RK_SHA_A"
echo "not a real journal entry" > "$RK/.planning/journal/evil.md"
git -C "$RK" add .planning/journal/evil.md; git -C "$RK" commit -q -m "journal: wrong shape"
HOME_K2="$WORK/home-k2"; mkdir -p "$HOME_K2"
write_receipt "$HOME_K2" "$RK_CANON" "$RK_BASE_SHA" true 0
OUT_K6="$(gate_run "$RK" "$HOME_K2" 2>&1)"; RC_K6=$?
[ "$RC_K6" = 2 ] && ok "K6 a wrongly-shaped journal/evil.md still goes STALE (anchor falsifiability)" \
  || bad "K6 expected exit 2, got $RC_K6" "$OUT_K6"
echo "$OUT_K6" | grep -q "evil.md" \
  && ok "K7 message names evil.md" || bad "K7 message does not name evil.md" "$OUT_K6"

# (d) receipt HEAD not an ancestor of current HEAD (history rewritten) => STALE.
git -C "$RK" reset -q --hard "$RK_BASE_SHA"
echo "rewritten" > "$RK/f.txt"
git -C "$RK" commit -q -am "rewrite history"
HOME_K3="$WORK/home-k3"; mkdir -p "$HOME_K3"
write_receipt "$HOME_K3" "$RK_CANON" "$RK_SHA_A" true 0
OUT_K8="$(gate_run "$RK" "$HOME_K3" 2>&1)"; RC_K8=$?
[ "$RC_K8" = 2 ] && ok "K8 a receipt HEAD that is no longer an ancestor (rewritten history) goes STALE" \
  || bad "K8 expected exit 2, got $RC_K8" "$OUT_K8"
echo "$OUT_K8" | grep -qi "STALE" \
  && ok "K9 message says STALE" || bad "K9 message does not say STALE" "$OUT_K8"

# ═══════════════════════════════════════════════════════════════════════════
# L. LINT EVIDENCE -- the gate and mark-clean never pass on stale, failing or ABSENT
#    lint evidence (security review of the stop-lint changes: "fail-open-state-drift").
#    lint_clean alone is a boolean anyone can flip -- `mark-clean` did, with nothing
#    run -- and bin/heimdall-stop-lint left a stale true standing when a linter failed
#    to run or a run linted nothing. Non-git fixture dirs: the sweep-receipt block is a
#    documented no-op there, so the lint check is the only live variable.
# ═══════════════════════════════════════════════════════════════════════════
echo
echo "L. lint evidence (check-quality-gates + mark-clean)"
LROOT="$WORK/lint-evidence"; mkdir -p "$LROOT"
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
lstate() {  # <dir> <heimdall-state args...> -- always against that dir's own state file
  local d="$1"; shift
  ( cd "$d" && HEIMDALL_STATE_FILE="$d/heimdall-state.json" "$STATE_BIN" "$@" )
}
lint_fixture() {  # <name> -> dir: every OTHER gate green, lint_clean=true (the stale / hand-set claim), one lintable file
  local d="$LROOT/$1"; mkdir -p "$d"
  lstate "$d" init >/dev/null 2>&1
  lstate "$d" set '.quality_gates.tests_passing' true >/dev/null 2>&1
  lstate "$d" set '.quality_gates.lint_clean' true >/dev/null 2>&1
  printf '#!/usr/bin/env bash\necho a\n' > "$d/a.sh"
  printf '%s' "$d"
}
lint_receipt() {  # <dir> <at> <findings> <tool_errors> <complete:true|false> -> a receipt shaped like bin/heimdall-stop-lint's
  lstate "$1" set '.quality_gates.lint_last_run' "$(jq -nc --arg at "$2" --argjson f "$3" --argjson t "$4" --argjson c "$5" --arg p "$1/a.sh" \
    '{at:$at, files:1, checked:1, findings:$f, tools:["bash -n"], complete:$c, timeouts:0, tool_errors:$t, skipped:0, excluded:0, shellcheck_severity:"warning", reason:"fixture", paths:[$p], source:"heimdall-stop-lint"}')" >/dev/null 2>&1
}
lint_gate() {  # <dir> -> LG_OUT, LG_RC
  LG_OUT="$(cd "$1" && HEIMDALL_STATE_FILE="$1/heimdall-state.json" "$STATE_BIN" check-quality-gates 2>&1)"; LG_RC=$?
}
lint_gate_blocks() {  # <label> <reason-code> (reads LG_OUT / LG_RC)
  if [ "$LG_RC" = 2 ] && grep -q 'Lint not clean' <<<"$LG_OUT" && grep -q -- "$2" <<<"$LG_OUT"; then ok "$1"
  else bad "$1 -- expected exit 2 naming '$2', got exit $LG_RC" "$LG_OUT"; fi
}

D="$(lint_fixture ok)"; lint_receipt "$D" "$(now_iso)" 0 0 true; lint_gate "$D"
[ "$LG_RC" = 0 ] && ok "L1 passing receipt (complete, 0 findings, 0 tool errors, covered file unchanged) + lint_clean=true -> gate PASSES" \
  || bad "L1 expected exit 0, got $LG_RC" "$LG_OUT"

D="$(lint_fixture none)"; lint_gate "$D"
lint_gate_blocks "L2 lint_clean=true with NO lint_last_run (a hand flip) -> gate BLOCKS" "no-evidence"

D="$(lint_fixture findings)"; lint_receipt "$D" "$(now_iso)" 2 0 true; lint_gate "$D"
lint_gate_blocks "L3 lint_clean=true but the receipt says findings=2 (the observed mark-clean drift) -> gate BLOCKS" "findings"

D="$(lint_fixture toolerr)"; lint_receipt "$D" "$(now_iso)" 0 1 false; lint_gate "$D"
lint_gate_blocks "L4 lint_clean=true but the receipt has a tool error -> gate BLOCKS (tool-error)" "tool-error"
grep -q 'HMD_LINT_WAIVER' <<<"$LG_OUT" && ok "L4b the block names the explicit, logged waiver as the way past a broken linter" \
  || bad "L4b block message does not name HMD_LINT_WAIVER" "$LG_OUT"

D="$(lint_fixture incomplete)"; lint_receipt "$D" "$(now_iso)" 0 0 false; lint_gate "$D"
lint_gate_blocks "L5 a receipt with complete=false (timeout / budget exhausted) -> gate BLOCKS" "incomplete"

D="$(lint_fixture stale)"; lint_receipt "$D" "2020-01-01T00:00:00Z" 0 0 true; lint_gate "$D"
lint_gate_blocks "L6 a passing receipt OLDER than an edit to a file it covers -> gate BLOCKS (stale)" "stale"

D="$(lint_fixture nocover)"
lstate "$D" set '.quality_gates.lint_last_run' "$(jq -nc --arg at "$(now_iso)" '{at:$at, complete:true, findings:0, tool_errors:0, source:"heimdall-stop-lint"}')" >/dev/null 2>&1
lint_gate "$D"
lint_gate_blocks "L7 a receipt that does not list the files it covers cannot be checked for staleness -> gate BLOCKS" "no-coverage"

D="$(lint_fixture mc-none)"
MC_OUT="$(lstate "$D" mark-clean 2>&1)"; MC_RC=$?
if [ "$MC_RC" = 0 ] && [ "$(jq -r '.quality_gates.lint_clean' "$D/heimdall-state.json")" = "false" ] \
   && [ "$(jq -r '.quality_gates.tests_passing' "$D/heimdall-state.json")" = "true" ] && grep -q 'NOT set' <<<"$MC_OUT"; then
  ok "L8 mark-clean with no passing lint_last_run does NOT set lint_clean (drops a stale true), says so, still marks tests clean"
else
  bad "L8 mark-clean claimed lint_clean without evidence (rc=$MC_RC)" "$MC_OUT $(jq -c .quality_gates "$D/heimdall-state.json")"
fi

D="$(lint_fixture mc-ok)"; lstate "$D" set '.quality_gates.lint_clean' false >/dev/null 2>&1; lint_receipt "$D" "$(now_iso)" 0 0 true
lstate "$D" mark-clean >/dev/null 2>&1
[ "$(jq -r '.quality_gates.lint_clean' "$D/heimdall-state.json")" = "true" ] \
  && ok "L9 mark-clean WITH a passing lint_last_run sets lint_clean" \
  || bad "L9 mark-clean did not set lint_clean despite passing evidence" "$(jq -c .quality_gates "$D/heimdall-state.json")"

D="$(lint_fixture waiver)"; lint_receipt "$D" "$(now_iso)" 0 1 false
WS="$D/heimdall-state.json"
WV_OUT="$(HMD_LINT_WAIVER='eslint config broken, tracked in #12' lstate "$D" mark-clean 2>&1)"
if [ "$(jq -r '.quality_gates.lint_clean' "$WS")" = "true" ] \
   && [ "$(jq -r '.quality_gates.lint_waiver.reason' "$WS")" = "eslint config broken, tracked in #12" ] \
   && [ "$(jq -r '.quality_gates.lint_waiver_log | length' "$WS")" = "1" ] && grep -q 'LINT WAIVED' <<<"$WV_OUT"; then
  ok "L10 HMD_LINT_WAIVER on mark-clean records an explicit, visible waiver (state + log) and says so"
else
  bad "L10 waiver not recorded visibly" "$WV_OUT $(jq -c .quality_gates "$WS")"
fi
lint_gate "$D"
{ [ "$LG_RC" = 0 ] && grep -q 'LINT WAIVED' <<<"$LG_OUT"; } \
  && ok "L11 the gate honours the recorded waiver, LOUDLY (never a silent pass)" \
  || bad "L11 expected exit 0 plus a LINT WAIVED line, got $LG_RC" "$LG_OUT"
lint_receipt "$D" "2031-01-01T00:00:00Z" 0 1 false; lint_gate "$D"
lint_gate_blocks "L12 a NEW lint run voids the waiver (it was issued against the previous receipt) -> gate BLOCKS again" "tool-error"

# ═══════════════════════════════════════════════════════════════════════════
# M. USE-CASE RECEIPT, THE WRITER -- the real test/use-cases/run.sh over a fixture with ONE journey (the tree must hold GOOD in marker.txt) and ONE mutant
#    (GOOD -> BAD, which the journey must notice). The real journeys take minutes; the writer's rules do not depend on them.
# ═══════════════════════════════════════════════════════════════════════════
echo
echo "M. use-case journey receipt: the writer (test/use-cases/run.sh) and what it refuses to vouch for"
UC_LIB_PY="$ROOT/bin/lib/hmd_use_case_receipt.py"
N_STATE="$WORK/uc-state.json"   # the legacy gate flags, green, outside every fixture repo (a state file inside one would be an untracked file)
FR="$WORK/uc-runner-repo"
newrepo "$FR"
mkdir -p "$FR/test/use-cases/journeys" "$FR/bin/lib"
cp "$ROOT/test/use-cases/run.sh" "$FR/test/use-cases/run.sh"
cp "$ROOT/test/use-cases/lib.sh" "$FR/test/use-cases/lib.sh"
for f in hmd_use_case_receipt.py hmd_sweep_guard.py hmd_kill_guard.py hook-owned-path.sh; do cp "$ROOT/bin/lib/$f" "$FR/bin/lib/$f" 2>/dev/null; done
printf 'GOOD\n' > "$FR/marker.txt"; printf 'notes\n' > "$FR/notes.txt"; printf '0.0.1\n' > "$FR/VERSION"; printf '.heimdall/receipts/\n' > "$FR/.gitignore"
cat > "$FR/test/use-cases/journeys/01_marker.sh" <<'JEOF'
#!/usr/bin/env bash
# fixture journey: the tree under test must hold GOOD in marker.txt and carry no fail.flag
if grep -q GOOD "$UC_TREE/marker.txt" 2>/dev/null && [ ! -e "$UC_TREE/fail.flag" ]; then echo "  PASS marker holds GOOD"; exit 0; fi
echo "  FAIL marker does not hold GOOD, or fail.flag exists"; exit 1
JEOF
printf '01_marker\tmarker.txt\ts/GOOD/BAD/\tmarker-bad\n' > "$FR/test/use-cases/mutants.list"
git -C "$FR" add -A; git -C "$FR" commit -q -m "fixture: a one-journey use-case runner"
( cd "$FR" && HEIMDALL_STATE_FILE="$N_STATE" "$STATE_BIN" init >/dev/null 2>&1 && HEIMDALL_STATE_FILE="$N_STATE" HMD_LINT_WAIVER="$LINT_FIXTURE_WAIVER" "$STATE_BIN" mark-clean >/dev/null 2>&1 )
FR_RECEIPT="$FR/.heimdall/receipts/use-cases.json"
uc_run() {  # uc_run [run.sh args...] -> UC_RC, $WORK/uc.out, $WORK/uc.err (an earlier receipt is removed first)
  rm -f "$FR_RECEIPT"
  ( cd "$FR" && env -u HEIMDALL_HOME HMD_MIN_FREE_PCT=0 bash test/use-cases/run.sh "$@" ) >"$WORK/uc.out" 2>"$WORK/uc.err"
  UC_RC=$?
}
uc_lib() {  # uc_lib <subcommand args...> -> UC_LIB_RC, UC_LIB_OUT (stdout and stderr, no HEIMDALL_HOME)
  UC_LIB_OUT="$(env -u HEIMDALL_HOME python3 -I -S "$UC_LIB_PY" "$@" 2>&1)"; UC_LIB_RC=$?
}
uc_write() {  # uc_write <started-head> -> a green one-journey, one-mutant receipt through the lib's own `write`
  uc_lib write --repo "$FR" --started-head "$1" --journeys-total 1 --journeys-passed 1 --mutants-total 1 --mutants-killed 1 --duration-s 3
}

uc_run
FR_HEAD="$(git -C "$FR" rev-parse HEAD)"; FR_TREE="$(git -C "$FR" rev-parse 'HEAD^{tree}')"
[ "$UC_RC" = 0 ] && ok "M1 a full green run on a clean committed tree exits 0" || bad "M1 expected exit 0, got $UC_RC" "$(tail -n 12 "$WORK/uc.out") $(cat "$WORK/uc.err")"
if jq -e --arg h "$FR_HEAD" --arg t "$FR_TREE" '(keys | length) == 8 and .schema == 1 and .head_sha == $h and .tree_sha == $t and .exit_code == 0
     and .journeys == {total: 1, passed: 1} and .mutants == {total: 1, killed: 1} and (.duration_s | type == "number")
     and (.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$FR_RECEIPT" >/dev/null 2>&1; then
  ok "M2 ...and writes use-cases.json: schema, the commit and the tree it graded, exit_code 0, the journey and mutant counts, duration_s, finished_at, nothing else"
else
  bad "M2 the receipt is missing or has the wrong shape" "$(cat "$FR_RECEIPT" 2>/dev/null)"
fi
[ -z "$(ls -A "$FR/.heimdall/receipts" 2>/dev/null | grep -v '^use-cases.json$')" ] \
  && ok "M3 atomic: use-cases.json is the only file in the receipts directory (no temp file left behind)" \
  || bad "M3 stray files beside the receipt" "$(ls -A "$FR/.heimdall/receipts")"
grep -q 'use-cases receipt: ' "$WORK/uc.out" && ok "M4 the run says where the receipt is" || bad "M4 no 'use-cases receipt:' line" "$(tail -n 5 "$WORK/uc.out")"

uc_run --only marker
if [ "$UC_RC" = 0 ] && [ ! -e "$FR_RECEIPT" ] && grep -q -- '--only' "$WORK/uc.err"; then ok "M5 --only (a subset of the journeys) exits 0, writes NO receipt, and says why on stderr"; else bad "M5 --only: rc=$UC_RC receipt=$([ -e "$FR_RECEIPT" ] && echo yes || echo no)" "$(cat "$WORK/uc.err")"; fi
uc_run --no-mutants
if [ "$UC_RC" = 0 ] && [ ! -e "$FR_RECEIPT" ] && grep -q -- '--no-mutants' "$WORK/uc.err"; then ok "M6 --no-mutants (nothing showed the journeys notice a break) writes NO receipt, and says why"; else bad "M6 --no-mutants: rc=$UC_RC receipt=$([ -e "$FR_RECEIPT" ] && echo yes || echo no)" "$(cat "$WORK/uc.err")"; fi
echo changed >> "$FR/notes.txt"
uc_run
if [ "$UC_RC" = 0 ] && [ ! -e "$FR_RECEIPT" ] && grep -q 'uncommitted' "$WORK/uc.err"; then ok "M7 a tree with uncommitted changes: the run is still green (exit 0), but NO receipt -- a receipt attests a commit -- and stderr says why"; else bad "M7 dirty tree: rc=$UC_RC receipt=$([ -e "$FR_RECEIPT" ] && echo yes || echo no)" "$(cat "$WORK/uc.err")"; fi
git -C "$FR" checkout -q -- notes.txt
: > "$FR/fail.flag"; git -C "$FR" add fail.flag; git -C "$FR" commit -q -m "fixture: break the journey"
uc_run
if [ "$UC_RC" = 1 ] && [ ! -e "$FR_RECEIPT" ] && grep -q 'not green' "$WORK/uc.err"; then ok "M8 a RED run (a journey fails) exits 1, writes NO receipt, and says the run was not green"; else bad "M8 red run: rc=$UC_RC receipt=$([ -e "$FR_RECEIPT" ] && echo yes || echo no)" "$(cat "$WORK/uc.err")"; fi
git -C "$FR" rm -q fail.flag; git -C "$FR" commit -q -m "fixture: mend the journey"

S0="$(git -C "$FR" rev-parse HEAD)"
mkdir -p "$FR/.planning/journal"; echo e > "$FR/.planning/journal/2026-11-22-haid_t.md"; git -C "$FR" add .planning/journal; git -C "$FR" commit -q -m "journal: hook-owned entry"
rm -f "$FR_RECEIPT"; uc_write "$S0"
if [ "$UC_LIB_RC" = 0 ] && [ "$(jq -r .head_sha "$FR_RECEIPT" 2>/dev/null)" = "$S0" ]; then ok "M9 HEAD moved mid-run by ONLY the hooks' own journal commit: the receipt is written and names the commit the run STARTED on"; else bad "M9 hook-owned HEAD move: rc=$UC_LIB_RC" "$UC_LIB_OUT $(cat "$FR_RECEIPT" 2>/dev/null)"; fi
echo "echo hi" > "$FR/code.sh"; git -C "$FR" add code.sh; git -C "$FR" commit -q -m "code lands mid-run"
rm -f "$FR_RECEIPT"; uc_write "$S0"
if [ "$UC_LIB_RC" = 1 ] && [ ! -e "$FR_RECEIPT" ] && grep -q 'HEAD moved' <<<"$UC_LIB_OUT"; then ok "M10 a real code commit landing mid-run: NO receipt (the journeys no longer say which commit they graded), and the reason names the move"; else bad "M10 code HEAD move: rc=$UC_LIB_RC" "$UC_LIB_OUT"; fi
uc_lib clean --repo "$FR"
[ "$UC_LIB_RC" = 0 ] && [ -z "$UC_LIB_OUT" ] && ok "M11 clean: a committed tree is clean (exit 0, prints nothing)" || bad "M11 clean on a committed tree: rc=$UC_LIB_RC" "$UC_LIB_OUT"
mkdir -p "$FR/.planning/ledger/checkpoints"; echo '{}' > "$FR/.planning/ledger/checkpoints/haid_x.json"
uc_lib clean --repo "$FR"
[ "$UC_LIB_RC" = 0 ] && ok "M12 clean: an untracked hook-owned ledger record is not uncommitted code (the sweep's own tree_clean carve-out)" || bad "M12 clean beside a hook-owned file: rc=$UC_LIB_RC" "$UC_LIB_OUT"
echo stray > "$FR/stray.txt"
uc_lib clean --repo "$FR"
[ "$UC_LIB_RC" = 1 ] && grep -q 'stray.txt' <<<"$UC_LIB_OUT" && ok "M13 clean: an untracked file outside the hook-owned paths IS uncommitted code, and is named" || bad "M13 clean beside a stray file: rc=$UC_LIB_RC" "$UC_LIB_OUT"
rm -f "$FR/stray.txt" "$FR/.planning/ledger/checkpoints/haid_x.json"
echo changed >> "$FR/notes.txt"
uc_write "$(git -C "$FR" rev-parse HEAD)"
[ "$UC_LIB_RC" = 1 ] && grep -q 'uncommitted' <<<"$UC_LIB_OUT" && ok "M14 write refuses a tree that holds uncommitted changes NOW, even when the run started clean" || bad "M14 write on a dirty tree: rc=$UC_LIB_RC" "$UC_LIB_OUT"
git -C "$FR" checkout -q -- notes.txt

# ═══════════════════════════════════════════════════════════════════════════
# N. USE-CASE RECEIPT, THE GATE -- bin/heimdall-state check-quality-gates against receipts built BY HAND (not by the writer under test), so the checker is held to the
#    schema and not to whatever the writer happens to emit. The legacy flags are green throughout: only the sweep part of the gate is the variable.
# ═══════════════════════════════════════════════════════════════════════════
echo
echo "N. use-case journey receipt: the push gate takes it in place of the sweep receipt (operator decision 2026-11-22, B) and stays closed on anything else"
RN="$WORK/uc-gate-repo"; newrepo "$RN"
echo one > "$RN/f.txt"; git -C "$RN" add -A; git -C "$RN" commit -q -m one
N_SHA="$(git -C "$RN" rev-parse HEAD)"; N_TREE="$(git -C "$RN" rev-parse 'HEAD^{tree}')"
RN_CANON="$(git -C "$RN" rev-parse --show-toplevel)"
HN="$WORK/home-n"; mkdir -p "$HN"
uc_receipt() {  # uc_receipt <home> <commit> [jq filter]: a use-case journey receipt for <commit> of the RN repo, as the writer would emit it, optionally mutated
  mkdir -p "$1/receipts"
  jq -n --arg h "$2" --arg t "$(git -C "$RN" rev-parse "$2^{tree}" 2>/dev/null || echo 0)" \
    '{schema: 1, head_sha: $h, tree_sha: $t, exit_code: 0, journeys: {total: 11, passed: 11}, mutants: {total: 25, killed: 25}, duration_s: 352, finished_at: "2026-11-22T12:00:00Z"}' \
    | jq "${3:-.}" > "$1/receipts/use-cases.json"
}
n_gate() {  # n_gate <home> -> N_OUT, N_RC
  N_OUT="$(cd "$RN" && HEIMDALL_HOME="$1" HEIMDALL_STATE_FILE="$N_STATE" "$STATE_BIN" check-quality-gates 2>&1)"; N_RC=$?
}
n_blocks() {  # n_blocks <label> <fragment> (reads N_OUT / N_RC): exit 2 and the message holds the fragment
  if [ "$N_RC" = 2 ] && grep -qF -- "$2" <<<"$N_OUT"; then ok "$1"; else bad "$1 -- expected exit 2 naming '$2', got exit $N_RC" "$N_OUT"; fi
}
red_case() {  # red_case <label> <fragment> <jq filter>
  uc_receipt "$HN" "$N_SHA" "$3"; n_gate "$HN"; n_blocks "$1" "$2"
}

n_gate "$HN"
n_blocks "N1 neither receipt: the gate BLOCKS, and still names the missing sweep receipt (that message is unchanged)" "no sweep receipt"
n_blocks "N2 ...and names the use-case runner as the way to a green (bash test/use-cases/run.sh)" "bash test/use-cases/run.sh"
uc_receipt "$HN" "$N_SHA"; n_gate "$HN"
if [ "$N_RC" = 0 ] && grep -q 'All quality gates pass' <<<"$N_OUT" && grep -qi 'use-case journey receipt' <<<"$N_OUT" && ! grep -q 'GATE FAILED' <<<"$N_OUT"; then
  ok "N3 a green use-case receipt for HEAD and NO sweep receipt: the gate PASSES, and says it rests on the use-case receipt"
else
  bad "N3 expected exit 0 on a green use-case receipt" "rc=$N_RC $N_OUT"
fi
write_receipt "$HN" "$RN_CANON" "$N_SHA" true 1
n_gate "$HN"
[ "$N_RC" = 0 ] && ok "N4 ...even beside a RED sweep receipt (either record is enough for a push; a release still needs the sweep)" || bad "N4 expected exit 0 beside a red sweep receipt" "rc=$N_RC $N_OUT"
rm -f "$HN/receipts/last-sweep.json"
N_STATE_RED="$WORK/uc-state-red.json"
( cd "$RN" && HEIMDALL_STATE_FILE="$N_STATE_RED" "$STATE_BIN" init >/dev/null 2>&1 )
N_OUT="$(cd "$RN" && HEIMDALL_HOME="$HN" HEIMDALL_STATE_FILE="$N_STATE_RED" "$STATE_BIN" check-quality-gates 2>&1)"; N_RC=$?
n_blocks "N5 the use-case receipt never overrides the OTHER gates: tests_passing=false still BLOCKS" "Tests not passing"

red_case "N6 a red run (exit_code 1) is no proof" "RED" '.exit_code = 1'
red_case "N7 a failed journey (10 of 11 passed) is no proof" "RED" '.journeys.passed = 10'
red_case "N8 a surviving mutant (24 of 25 killed) is no proof" "RED" '.mutants.killed = 24'
red_case "N9 a run that found no journey checked nothing: no proof" "RED" '.journeys = {total: 0, passed: 0}'
red_case "N10 a run with no mutants never showed the journeys notice a break: no proof" "RED" '.mutants = {total: 0, killed: 0}'
red_case "N11 a forged tree sha (the commit is right, its tree is not what git says)" "tree sha" '.tree_sha = "1111111111111111111111111111111111111111"'
red_case "N12 a commit this checkout does not have" "does not have" '.head_sha = "2222222222222222222222222222222222222222"'
red_case "N13 a TREE id in head_sha is not a commit (git is asked for a commit, never trusted on the id)" "does not have" ".head_sha = \"$N_TREE\""
red_case "N14 a missing field is a malformed receipt" "malformed" 'del(.tree_sha)'
red_case "N15 a field the schema does not have is a malformed receipt" "malformed" '. + {extra: 1}'
red_case "N16 another schema number is a malformed receipt" "malformed" '.schema = 2'
red_case "N17 a mistyped count (a string) is a malformed receipt" "malformed" '.journeys.passed = "11"'
printf 'not json at all {{{' > "$HN/receipts/use-cases.json"; n_gate "$HN"
n_blocks "N18 a receipt that is not JSON BLOCKS, saying so" "not valid JSON"
printf '[]' > "$HN/receipts/use-cases.json"; n_gate "$HN"
n_blocks "N19 valid JSON that is not an object BLOCKS as malformed" "malformed"
uc_receipt "$HN" "$N_SHA"; mv "$HN/receipts/use-cases.json" "$HN/real-receipt.json"; ln -s "$HN/real-receipt.json" "$HN/receipts/use-cases.json"
n_gate "$HN"
n_blocks "N20 a receipt that is a symlink is never followed" "link"
rm -f "$HN/receipts/use-cases.json" "$HN/real-receipt.json"

# the receipt the WRITER wrote, not one built by hand: the writer and the gate share one definition of it
HW="$WORK/home-nw"; mkdir -p "$HW"
FR_NOW="$(git -C "$FR" rev-parse HEAD)"
HEIMDALL_HOME="$HW" python3 -I -S "$UC_LIB_PY" write --repo "$FR" --started-head "$FR_NOW" --journeys-total 1 --journeys-passed 1 --mutants-total 1 --mutants-killed 1 --duration-s 3 >/dev/null 2>&1
OUT_NW="$(cd "$FR" && HEIMDALL_HOME="$HW" HEIMDALL_STATE_FILE="$N_STATE" "$STATE_BIN" check-quality-gates 2>&1)"; RC_NW=$?
[ "$RC_NW" = 0 ] && grep -qi 'use-case journey receipt' <<<"$OUT_NW" && ok "N21 a receipt the WRITER wrote (bin/lib/hmd_use_case_receipt.py write) passes the gate: one definition of the receipt on both sides" || bad "N21 the writer's own receipt did not pass the gate: rc=$RC_NW" "$OUT_NW"

# history: only the hooks' own commits may come after the run
uc_receipt "$HN" "$N_SHA"
mkdir -p "$RN/.planning/journal"; echo e > "$RN/.planning/journal/2026-11-22-haid_n.md"
git -C "$RN" add .planning/journal/2026-11-22-haid_n.md; git -C "$RN" commit -q -m "journal: hook-owned entry"
n_gate "$HN"
[ "$N_RC" = 0 ] && ok "N22 a commit after the run that touches ONLY the hooks' own journal records leaves the receipt fresh (the hooks commit these after every real commit)" || bad "N22 expected exit 0 past a hook-owned-only commit" "rc=$N_RC $N_OUT"
echo "echo hi" > "$RN/code.sh"; git -C "$RN" add code.sh; git -C "$RN" commit -q -m "code lands"
N_CODE_SHA="$(git -C "$RN" rev-parse HEAD)"
n_gate "$HN"
n_blocks "N23 a real code commit after the run makes the receipt STALE" "STALE"
n_blocks "N24 ...and the message names the path that made it stale (code.sh)" "code.sh"
git -C "$RN" reset -q --hard "$N_SHA"; echo other > "$RN/f.txt"; git -C "$RN" commit -q -am "rewrite history"
uc_receipt "$HN" "$N_CODE_SHA"; n_gate "$HN"
n_blocks "N25 a receipt for a commit that is no longer an ancestor of HEAD (history rewritten) is STALE" "rewritten"

echo
printf "  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
# test/heimdall-plan-verify.test.sh — a plan's acceptance criteria must be a
# checkable fact, not an assertion.
#
# WHY THIS EXISTS. bin/decompose emits waves, agents/planner.md and
# agents/architect.md write PLAN files with acceptance criteria -- and until
# bin/heimdall-plan-verify, nothing ever ran those criteria against the tree and
# reported the real result. "Wave done" was whatever the last agent said it was.
#
# MEASURED AGAINST THIS REPO'S REAL PLANS (2026-08-31, commit 8d9541c):
#   docs/superpowers/plans/2026-08-29-agent-fallback-coverage.md: 53 checkbox
#   criteria, all 53 backtick-wrapped (100% syntactically command-shaped -- the
#   "most criteria are prose" hypothesis this tool was commissioned to test is
#   REFUTED for this plan). Actually run: 29 MET, 24 UNMET, 0 NOT_RUNNABLE.
#   docs/superpowers/plans/2026-07-09-anonymized-issue-collection.md: has a
#   <plan>.waves.json sidecar (auto-preferred); Wave 0 = 4/4 MET.
# Section F below re-derives structural invariants from these same real files
# LIVE on every run (never a hardcoded MET/UNMET split) -- a real plan's
# completion state is expected to change over time, and pinning today's numbers
# here would make this suite a stale liar the next time a wave lands.
#
# PROVEN, FALSIFIABLE BOTH WAYS:
#   A. classification -- a genuinely passing command -> MET, a genuinely failing
#      one -> UNMET, prose with no backtick command -> NOT_RUNNABLE, for all three
#      criterion shapes (bare command, `outputs X`, `exits N`), plus JSON-mode
#      structural checks.
#   B. --wave N filters to that wave only; an unknown wave is a plumbing failure
#      (exit 2), never a silent empty pass.
#   C. a <plan>.waves.json sidecar is preferred over markdown when both exist.
#   D. missing plan file / a plan with zero parseable waves -- fail-open: reported
#      (exit 2), never a crash, never rendered as any kind of pass.
#   E. --require-sweep is a genuine AND: criteria-met-but-no/stale-receipt is
#      INCOMPLETE, and a fresh receipt can never rescue UNMET criteria.
#   F. real-file integration -- runs against this repo's actual plans and
#      cross-checks the tool's own totals against an independent grep count, so
#      a parser regression that silently drops criteria cannot go unnoticed.
#   G. a criterion that outlives --timeout is UNMET (with the reason named), not
#      a hang.
#
# HERMETIC. Sections A-E and G run inside throwaway `git init` repos under
# $TMPDIR; nothing touches the real .heimdall/ or .planning/. Section F reads the
# real repo's real plan files (read-only) but asserts only self-consistency
# invariants, never a hardcoded pass/fail split.
#
# EXIT: 0 = every proof holds; 1 = any FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-plan-verify"
LIB="$ROOT/bin/lib/hmd_plan_verify.py"
REAL_PLAN="$ROOT/docs/superpowers/plans/2026-08-29-agent-fallback-coverage.md"
REAL_JSON_PLAN="$ROOT/docs/superpowers/plans/2026-07-09-anonymized-issue-collection.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

command -v jq      >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -x "$TOOL" ] || { echo "FATAL: missing/!exec $TOOL" >&2; exit 2; }
[ -f "$LIB" ]  || { echo "FATAL: missing $LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-plan-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

newrepo() {  # <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email dev@example.com
  git -C "$1" config user.name Dev
}

commit_all() {  # <dir> <msg>
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

write_receipt() {  # <home> <repo> <head_sha> <tree_clean:true|false> <exit_code:0|1>
  mkdir -p "$1/receipts"
  jq -n --arg repo "$2" --arg head_sha "$3" --argjson tree_clean "$4" --argjson exit_code "$5" \
    '{finished_at:"2026-01-01T00:00:00Z", repo:$repo, head_sha:$head_sha,
      tree_clean:$tree_clean, exit_code:$exit_code, suites_total:1, suites_passed:1,
      suites_failed:0}' > "$1/receipts/last-sweep.json"
}

echo "════════════════════════════════════════════════════════════════"
echo "heimdall-plan-verify — a plan's criteria must be a checkable fact"
echo "════════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# 0. SANITY — the artifacts are syntactically valid before anything else is trusted.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- 0. sanity ------------------------------------------------------------------"
bash -n "$TOOL" && ok "0.1 bin/heimdall-plan-verify passes bash -n" || bad "0.1 bash -n failed"
python3 -m py_compile "$LIB" && ok "0.2 bin/lib/hmd_plan_verify.py byte-compiles" || bad "0.2 py_compile failed"
grep -q "plan-verify)" "$ROOT/bin/heimdall" \
  && ok "0.3 bin/heimdall dispatches a plan-verify) case arm" \
  || bad "0.3 no plan-verify) arm found in bin/heimdall"

# ══════════════════════════════════════════════════════════════════════════════
# A. CLASSIFICATION — every criterion shape, both directions (red-proof + green).
# ══════════════════════════════════════════════════════════════════════════════
echo "-- A. classification: MET / UNMET / NOT_RUNNABLE, every criterion shape --------"
RA="$WORK/repo-a"
newrepo "$RA"
touch "$RA/exists.txt"
cat > "$RA/PLAN.md" <<'EOF'
# Fixture Plan A

## 2. Waves

### Wave 0 — fixture wave zero

#### Task 0.1 — mixed criteria for classification testing
- **Acceptance criteria:**
  - [ ] `test -f exists.txt`
  - [ ] `test -f does-not-exist.txt`
  - [ ] `echo hello` outputs `hello`
  - [ ] `echo wrong` outputs `hello`
  - [ ] `true` exits 0
  - [ ] `false` exits 0
  - [ ] this criterion is pure prose, no backtick command, cannot be run
  - [ ] `bash -c "exit 3"` exits 3
  - [ ] `bash -c "exit 3"` exits 5
- **Verify:** n/a
- **Done when:** n/a

### Wave 1 — fixture wave one

#### Task 1.1 — single criterion
- **Acceptance criteria:**
  - [ ] `test -f exists.txt`
EOF
commit_all "$RA" "fixture plan A"

OUT_A="$("$TOOL" "$RA/PLAN.md" 2>&1)"; RC_A=$?
[ "$RC_A" = 1 ] && ok "A1 exit 1 when at least one UNMET criterion exists" \
  || bad "A1 expected exit 1, got $RC_A" "$OUT_A"
echo "$OUT_A" | grep -qE '^    MET +test -f exists\.txt$' \
  && ok "A2 genuinely passing bare command -> MET" || bad "A2 missing MET line" "$OUT_A"
echo "$OUT_A" | grep -qE '^    UNMET +test -f does-not-exist\.txt$' \
  && ok "A3 genuinely failing bare command -> UNMET" || bad "A3 missing UNMET line" "$OUT_A"
echo "$OUT_A" | grep -qE '^    MET +echo hello$' \
  && ok "A4 matching 'outputs X' stdout -> MET" || bad "A4 missing MET line for outputs match" "$OUT_A"
echo "$OUT_A" | grep -qE '^    UNMET +echo wrong$' \
  && ok "A5 mismatching 'outputs X' stdout -> UNMET" || bad "A5 missing UNMET line for outputs mismatch" "$OUT_A"
echo "$OUT_A" | grep -qE '^    MET +true$' \
  && ok "A6 'exits 0' with matching exit -> MET" || bad "A6 missing MET line for exits match" "$OUT_A"
echo "$OUT_A" | grep -qE '^    UNMET +false$' \
  && ok "A7 'exits 0' with mismatching exit -> UNMET" || bad "A7 missing UNMET line for exits mismatch" "$OUT_A"
echo "$OUT_A" | grep -qE '^    NOT_RUNNABLE this criterion is pure prose' \
  && ok "A8 prose with no backtick command -> NOT_RUNNABLE, never guessed" \
  || bad "A8 missing NOT_RUNNABLE line for prose criterion" "$OUT_A"
echo "$OUT_A" | grep -qE '^    MET +bash -c "exit 3" exits 3$' \
  && ok "A9 'exits N' (N!=0) with matching exit -> MET" || bad "A9 missing MET line for exits-3 match" "$OUT_A"
echo "$OUT_A" | grep -qE '^    UNMET +bash -c "exit 3" exits 5$' \
  && ok "A10 'exits N' with mismatching exit -> UNMET" || bad "A10 missing UNMET line for exits-5 mismatch" "$OUT_A"
echo "$OUT_A" | grep -q "TOTALS: 5 MET, 4 UNMET, 1 NOT-RUNNABLE (across 10 criteria)" \
  && ok "A11 totals line sums exactly right across both waves" \
  || bad "A11 totals line wrong" "$OUT_A"
echo "$OUT_A" | grep -q "NOT_RUNNABLE prose -- never guessed, never counted as a pass" \
  && ok "A12 verdict names the NOT_RUNNABLE caveat honestly" || bad "A12 verdict missing NOT_RUNNABLE caveat" "$OUT_A"

echo "-- A(json). same fixture, --json: structurally valid and internally consistent -"
JOUT_A="$("$TOOL" "$RA/PLAN.md" --json 2>&1)"; JRC_A=$?
echo "$JOUT_A" | jq -e . >/dev/null 2>&1 \
  && ok "A13 --json output is valid JSON" || bad "A13 invalid JSON" "$JOUT_A"
[ "$(echo "$JOUT_A" | jq -r '.totals.met')" = "5" ] \
  && ok "A14 JSON totals.met == 5" || bad "A14 wrong totals.met" "$JOUT_A"
[ "$(echo "$JOUT_A" | jq -r '.totals.unmet')" = "4" ] \
  && ok "A15 JSON totals.unmet == 4" || bad "A15 wrong totals.unmet" "$JOUT_A"
[ "$(echo "$JOUT_A" | jq -r '.totals.not_runnable')" = "1" ] \
  && ok "A16 JSON totals.not_runnable == 1" || bad "A16 wrong totals.not_runnable" "$JOUT_A"
[ "$(echo "$JOUT_A" | jq -r '.waves[0].id')" = "0" ] && [ "$(echo "$JOUT_A" | jq -r '.waves[1].id')" = "1" ] \
  && ok "A17 waves array preserves file order (Wave 0 before Wave 1)" \
  || bad "A17 wave order/ids wrong" "$JOUT_A"
[ "$(echo "$JOUT_A" | jq -r '.waves[0].tasks[0].criteria[6].cmd')" = "null" ] \
  && ok "A18 a NOT_RUNNABLE criterion's cmd is JSON null, never fabricated" \
  || bad "A18 NOT_RUNNABLE cmd field is not null" "$JOUT_A"
[ "$JRC_A" = 1 ] && ok "A19 --json exit code matches text-mode exit code (1)" \
  || bad "A19 expected exit 1, got $JRC_A" "$JOUT_A"

# ══════════════════════════════════════════════════════════════════════════════
# B. --wave FILTERING
# ══════════════════════════════════════════════════════════════════════════════
echo "-- B. --wave N filters to that wave only ---------------------------------------"
OUT_B1="$("$TOOL" "$RA/PLAN.md" --wave 1 --json 2>&1)"; RC_B1=$?
[ "$RC_B1" = 0 ] && ok "B1 wave 1 (all-MET) filtered alone exits 0" \
  || bad "B1 expected exit 0, got $RC_B1" "$OUT_B1"
[ "$(echo "$OUT_B1" | jq -r '.totals.met')" = "1" ] && [ "$(echo "$OUT_B1" | jq -r '.totals.unmet')" = "0" ] \
  && ok "B2 wave 1 alone reports exactly its own 1 criterion, none of wave 0's" \
  || bad "B2 wave filter leaked criteria from another wave" "$OUT_B1"

OUT_B3="$("$TOOL" "$RA/PLAN.md" --wave 99 2>&1)"; RC_B3=$?
[ "$RC_B3" = 2 ] && ok "B3 unknown --wave is a plumbing failure (exit 2), never a silent empty pass" \
  || bad "B3 expected exit 2, got $RC_B3" "$OUT_B3"
echo "$OUT_B3" | grep -qi "wave 99 not found" \
  && ok "B4 message names the unknown wave explicitly" || bad "B4 message unclear" "$OUT_B3"

# ══════════════════════════════════════════════════════════════════════════════
# C. JSON SIDECAR PREFERRED OVER MARKDOWN WHEN BOTH EXIST
# ══════════════════════════════════════════════════════════════════════════════
echo "-- C. a <plan>.waves.json sidecar is preferred over markdown -------------------"
RC_REPO="$WORK/repo-c"
newrepo "$RC_REPO"
cat > "$RC_REPO/PLAN.md" <<'EOF'
# Fixture Plan C

## 2. Waves

### Wave 0 — would fail if markdown were used
#### Task 0.1 — deliberately-failing markdown criterion
- **Acceptance criteria:**
  - [ ] `false`
EOF
cat > "$RC_REPO/PLAN.waves.json" <<'EOF'
{"waves": [{"id": 0, "tasks": [{"id": "sidecar-task", "agent": "hmd:test", "acceptance": ["true"]}]}]}
EOF
commit_all "$RC_REPO" "fixture plan C"

OUT_C="$("$TOOL" "$RC_REPO/PLAN.md" --json 2>&1)"; RC_C=$?
[ "$(echo "$OUT_C" | jq -r '.source')" = "json" ] \
  && ok "C1 sidecar detected and preferred (source: json)" || bad "C1 did not prefer the sidecar" "$OUT_C"
[ "$RC_C" = 0 ] && [ "$(echo "$OUT_C" | jq -r '.totals.met')" = "1" ] && [ "$(echo "$OUT_C" | jq -r '.totals.unmet')" = "0" ] \
  && ok "C2 sidecar's own (passing) criteria were run, not markdown's (failing) ones" \
  || bad "C2 wrong criteria source used" "$OUT_C"

# ══════════════════════════════════════════════════════════════════════════════
# D. FAIL-OPEN ON BAD PLUMBING — reported, never a crash, never a pass.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- D. missing plan / zero-wave plan: fail-open, never a crash -------------------"
OUT_D1="$("$TOOL" "$WORK/does-not-exist.md" 2>&1)"; RC_D1=$?
[ "$RC_D1" = 2 ] && ok "D1 missing plan file -> exit 2" || bad "D1 expected exit 2, got $RC_D1" "$OUT_D1"
echo "$OUT_D1" | grep -qi "PLAN NOT FOUND" \
  && ok "D2 message names the missing file explicitly" || bad "D2 message unclear" "$OUT_D1"

JOUT_D1="$("$TOOL" "$WORK/does-not-exist.md" --json 2>&1)"; JRC_D1=$?
[ "$JRC_D1" = 2 ] && echo "$JOUT_D1" | jq -e . >/dev/null 2>&1 && echo "$JOUT_D1" | jq -e '.error' >/dev/null 2>&1 \
  && ok "D3 --json mode reports the same failure as valid JSON on stdout (an .error key), still exit 2" \
  || bad "D3 --json error path is not valid/expected JSON" "$JOUT_D1"

RD="$WORK/repo-d"
newrepo "$RD"
printf '# Empty Plan\n\nNo waves here at all.\n' > "$RD/PLAN.md"
commit_all "$RD" "fixture plan D: no waves"
OUT_D4="$("$TOOL" "$RD/PLAN.md" 2>&1)"; RC_D4=$?
[ "$RC_D4" = 2 ] && ok "D4 a plan with zero parseable waves -> exit 2, not a false pass" \
  || bad "D4 expected exit 2, got $RC_D4" "$OUT_D4"
echo "$OUT_D4" | grep -qi "no waves found" \
  && ok "D5 message names the absence of waves explicitly" || bad "D5 message unclear" "$OUT_D4"

# ══════════════════════════════════════════════════════════════════════════════
# E. --require-sweep IS A GENUINE AND — never a rescue, never fooled by a stale one.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- E. --require-sweep: wave completeness is criteria AND a fresh sweep receipt -"
RE_SHA="$(git -C "$RA" rev-parse HEAD)"
RE_CANON="$(git -C "$RA" rev-parse --show-toplevel)"

HOME_E1="$WORK/home-e1"; mkdir -p "$HOME_E1"
write_receipt "$HOME_E1" "$RE_CANON" "$RE_SHA" true 0
OUT_E1="$("$TOOL" "$RA/PLAN.md" --wave 1 --require-sweep --heimdall-home "$HOME_E1" 2>&1)"; RC_E1=$?
[ "$RC_E1" = 0 ] && echo "$OUT_E1" | grep -q "WAVE 1 COMPLETE" \
  && ok "E1 all-MET wave + fresh/clean/green receipt -> WAVE COMPLETE, exit 0" \
  || bad "E1 expected COMPLETE/exit 0" "$OUT_E1 (rc=$RC_E1)"

HOME_E2="$WORK/home-e2-empty"; mkdir -p "$HOME_E2"
OUT_E2="$("$TOOL" "$RA/PLAN.md" --wave 1 --require-sweep --heimdall-home "$HOME_E2" 2>&1)"; RC_E2=$?
[ "$RC_E2" = 1 ] && echo "$OUT_E2" | grep -q "WAVE 1 INCOMPLETE" && echo "$OUT_E2" | grep -qi "no sweep receipt" \
  && ok "E2 all-MET wave but NO receipt -> still INCOMPLETE (criteria alone are not enough)" \
  || bad "E2 expected INCOMPLETE naming the missing receipt" "$OUT_E2 (rc=$RC_E2)"

HOME_E3="$WORK/home-e3-stale"; mkdir -p "$HOME_E3"
write_receipt "$HOME_E3" "$RE_CANON" "0000000000000000000000000000000000000000" true 0
OUT_E3="$("$TOOL" "$RA/PLAN.md" --wave 1 --require-sweep --heimdall-home "$HOME_E3" 2>&1)"; RC_E3=$?
[ "$RC_E3" = 1 ] && echo "$OUT_E3" | grep -qi "STALE" \
  && ok "E3 all-MET wave but STALE receipt (wrong HEAD) -> INCOMPLETE, names staleness" \
  || bad "E3 expected INCOMPLETE naming staleness" "$OUT_E3 (rc=$RC_E3)"

HOME_E4="$WORK/home-e4-good"; mkdir -p "$HOME_E4"
write_receipt "$HOME_E4" "$RE_CANON" "$RE_SHA" true 0
OUT_E4="$("$TOOL" "$RA/PLAN.md" --wave 0 --require-sweep --heimdall-home "$HOME_E4" 2>&1)"; RC_E4=$?
[ "$RC_E4" = 1 ] && echo "$OUT_E4" | grep -q "WAVE 0 INCOMPLETE" && echo "$OUT_E4" | grep -q "4 UNMET criteria" \
  && ok "E4 a fresh/clean/green receipt can NEVER rescue a wave with real UNMET criteria" \
  || bad "E4 expected INCOMPLETE naming the 4 UNMET criteria despite a good receipt" "$OUT_E4 (rc=$RC_E4)"

OUT_E5="$("$TOOL" "$RA/PLAN.md" --require-sweep 2>&1)"; RC_E5=$?
[ "$RC_E5" = 2 ] && echo "$OUT_E5" | grep -qi "require-sweep requires --wave" \
  && ok "E5 --require-sweep without --wave is a plumbing error (exit 2), evaluated per-wave only" \
  || bad "E5 expected exit 2 naming the --wave requirement" "$OUT_E5 (rc=$RC_E5)"

# ══════════════════════════════════════════════════════════════════════════════
# F. REAL-FILE INTEGRATION — this repo's actual plans, self-consistency only.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- F. real-plan integration: runs clean, totals are internally consistent ------"
if [ -f "$REAL_PLAN" ]; then
  JOUT_F="$("$TOOL" "$REAL_PLAN" --json 2>&1)"; RC_F=$?
  [ "$RC_F" = 0 ] || [ "$RC_F" = 1 ] \
    && ok "F1 real plan runs to completion (exit 0 or 1, never a plumbing failure)" \
    || bad "F1 unexpected exit $RC_F against the real plan" "$JOUT_F"
  echo "$JOUT_F" | jq -e . >/dev/null 2>&1 && ok "F2 --json output against the real plan is valid JSON" \
    || bad "F2 invalid JSON against the real plan" "$JOUT_F"

  GREP_TOTAL="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[ xX]\]' "$REAL_PLAN")"
  JQ_TOTAL="$(echo "$JOUT_F" | jq '.totals.met + .totals.unmet + .totals.not_runnable')"
  [ "$GREP_TOTAL" = "$JQ_TOTAL" ] \
    && ok "F3 tool's total criteria count ($JQ_TOTAL) matches an independent grep count of checkbox lines ($GREP_TOTAL) -- no criteria silently dropped" \
    || bad "F3 MISMATCH: grep counted $GREP_TOTAL checkbox lines, tool counted $JQ_TOTAL criteria" "$JOUT_F"

  BAD_STATUS="$(echo "$JOUT_F" | jq '[.waves[].tasks[].criteria[].status] | map(select(. != "MET" and . != "UNMET" and . != "NOT_RUNNABLE")) | length')"
  [ "$BAD_STATUS" = "0" ] \
    && ok "F4 every criterion status against the real plan is one of MET/UNMET/NOT_RUNNABLE" \
    || bad "F4 found $BAD_STATUS criteria with an unrecognized status" "$JOUT_F"

  echo "    (informational, not asserted -- plan completion changes over time) totals: $(echo "$JOUT_F" | jq -c .totals)"
else
  bad "F0 real plan fixture not found at $REAL_PLAN -- cannot run integration section"
fi

if [ -f "$REAL_JSON_PLAN" ]; then
  JOUT_F5="$("$TOOL" "$REAL_JSON_PLAN" --wave 0 --json 2>&1)"; RC_F5=$?
  [ "$(echo "$JOUT_F5" | jq -r '.source')" = "json" ] \
    && ok "F5 the real sidecar-backed plan is actually detected and used as JSON (not re-parsed as markdown)" \
    || bad "F5 expected source: json for the real sidecar plan" "$JOUT_F5 (rc=$RC_F5)"
else
  bad "F5-skip real JSON-sidecar plan fixture not found at $REAL_JSON_PLAN"
fi

# ══════════════════════════════════════════════════════════════════════════════
# G. TIMEOUT — a criterion that outlives --timeout is UNMET, not a hang.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- G. a criterion exceeding --timeout is UNMET, not a hang ----------------------"
RG_REPO="$WORK/repo-g"
newrepo "$RG_REPO"
cat > "$RG_REPO/PLAN.md" <<'EOF'
# Fixture Plan G

## 2. Waves

### Wave 0 — timeout fixture
#### Task 0.1 — one slow criterion
- **Acceptance criteria:**
  - [ ] `sleep 5`
EOF
commit_all "$RG_REPO" "fixture plan G"

START_G=$(date +%s)
OUT_G="$("$TOOL" "$RG_REPO/PLAN.md" --timeout 1 2>&1)"; RC_G=$?
END_G=$(date +%s)
ELAPSED_G=$((END_G - START_G))
[ "$RC_G" = 1 ] && ok "G1 a criterion exceeding --timeout makes the run exit 1 (UNMET), not hang" \
  || bad "G1 expected exit 1, got $RC_G" "$OUT_G"
echo "$OUT_G" | grep -qi "timeout after 1s" \
  && ok "G2 the UNMET reason names the timeout explicitly" || bad "G2 timeout reason not named" "$OUT_G"
[ "$ELAPSED_G" -lt 5 ] \
  && ok "G3 actually bounded by --timeout (took ${ELAPSED_G}s, not the full 5s sleep)" \
  || bad "G3 took ${ELAPSED_G}s -- --timeout was not honored"

echo
printf "RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

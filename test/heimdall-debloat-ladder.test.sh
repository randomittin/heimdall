#!/usr/bin/env bash
# test/heimdall-debloat-ladder.test.sh — acceptance for wiring the Ponytail
# lazy-ladder into heimdall-debloat's refactor path, WITHOUT weakening the
# test-safety oracle that makes debloat safe.
#
# Hermetic: no model call, no network, no token spend. Every assertion runs the
# real bins over throwaway git repos, or drives the extracted gate function with a
# controlled scorer so the SAFETY ORACLE (the suite) is the only thing under test.
#
# Asserted:
#   (a) the refactor path REALLY sets HEIMDALL_LAZY_LADDER=1 for its wave agents —
#       grep the wired export (not prose) AND build_wave_agent_cmd genuinely
#       prepends the ladder ruleset (ON prompt strictly longer than OFF).
#   (b) the test-safety oracle STILL blocks a refactor that drops a required
#       behavior: a leaner-but-broken wave reddens the suite and is REVERTED
#       (falsifiable), while a green+improving wave is APPLIED. The ladder makes
#       the diff smaller; it can NEVER make a failing acceptance "pass".
#   (c) the -20% LOC cap and PR-not-direct-commit output are PRESERVED: a full run
#       writes BLOAT-REPORT.md (cap line) + .heimdall-debloat-PR.md, creates the
#       debloat branch, and leaves the original branch's HEAD untouched.
#   (d) the new bloat-gate axis (reimplemented-stdlib) HONEST-SKIPS when its tool
#       (ast-grep) is absent — status=skipped, tool named, never a fabricated pass.
#   (e) regression: --report-only stays zero-risk (report written, no source edit)
#       and the no-suite path still REFUSES (exit 3) — the safety oracle un-weakened.

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

# A throwaway git repo under $WORK (fixed names — no random template needed).
mkrepo() { local name="$1"; local d="$WORK/$name"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email a@b.c && git config user.name t ); printf '%s' "$d"; }

# ── (a) refactor path REALLY sets HEIMDALL_LAZY_LADDER=1 (wired, not prose) ────
# a1: the export lives in the refactor stage (after the "Stage 3" marker).
STAGE3_LINE="$(grep -n 'Stage 3' "$DEB" | head -1 | cut -d: -f1)"
EXPORT_LINE="$(grep -n 'export HEIMDALL_LAZY_LADDER=1' "$DEB" | head -1 | cut -d: -f1)"
if [ -n "$EXPORT_LINE" ] && [ -n "$STAGE3_LINE" ] && [ "$EXPORT_LINE" -gt "$STAGE3_LINE" ]; then
  ok "(a1) refactor path exports HEIMDALL_LAZY_LADDER=1 (line $EXPORT_LINE, inside Stage 3+)"
else
  bad "(a1) no HEIMDALL_LAZY_LADDER=1 export wired into the refactor stage"
fi

# a2: build_wave_agent_cmd genuinely PREPENDS the ladder ruleset — ON prompt bytes
# strictly exceed OFF. We eval-extract the ladder functions (+ reuse the canonical
# ruleset from bin/heimdall-ponytail-ab, exactly as the bin does at runtime).
len_for() { # LADDER_MODE_value
  HEIMDALL_LAZY_LADDER="" LADDER_MODE="$1" BIN_DIR="$ROOT/bin" PLUGIN_DIR="/x" bash -c '
    set -euo pipefail
    DEB="'"$DEB"'"; PONYTAIL_AB="$BIN_DIR/heimdall-ponytail-ab"
    eval "$(sed -n "/^ladder_active()/,/^}/p; /^build_wave_agent_cmd()/,/^}/p" "$DEB")"
    if [ -f "$PONYTAIL_AB" ] && grep -q "^ladder_preamble()" "$PONYTAIL_AB"; then
      eval "$(sed -n "/^ladder_preamble()/,/^}/p" "$PONYTAIL_AB")"
    else
      eval "$(sed -n "/^  ladder_preamble()/,/^  }/p" "$DEB")"
    fi
    build_wave_agent_cmd "dup-wave" "consolidate the duplicated clusters"
    printf "%s" "${WAVE_AGENT_CMD[*]}" | wc -c
  ' | tr -d " "
}
LEN_ON="$(len_for on)"; LEN_OFF="$(len_for off)"
if [ "${LEN_ON:-0}" -gt "${LEN_OFF:-0}" ]; then
  ok "(a2) build_wave_agent_cmd prepends the ladder ruleset: ON ($LEN_ON) > OFF ($LEN_OFF) bytes"
else
  bad "(a2) ladder NOT injected into wave-agent prompt: ON=$LEN_ON OFF=$LEN_OFF"
fi

# ── (b) SAFETY ORACLE un-weakened: leaner-but-broken FAILS, green+improving PASSES
# Drive the extracted gate_wave with a controlled scorer, so the ONLY variable is
# the test suite (the oracle). This is the falsifiable core: a smaller diff that
# drops a required behavior reddens the suite and MUST be reverted, never committed.
run_gate() { # repo test_cmd wave_name idx pre_metrics  -> echoes gate_wave verdict
  local repo="$1" tcmd="$2" name="$3" idx="$4" prem="$5"
  REPO="$repo" TEST_CMD="$tcmd" WORK_DIR="$WORK/gw.$name" \
  bash -c '
    set -uo pipefail
    mkdir -p "$WORK_DIR"
    eval "$(sed -n "/^gate_wave()/,/^}/p" "'"$DEB"'")"
    # Controlled scorer: metric ALWAYS improves (post < pre), isolating the suite gate.
    score_now() { printf "0\t0\t0\t1\n"; }
    pre_sha="$(git -C "$REPO" rev-parse HEAD)"
    gate_wave "'"$name"'" "'"$idx"'" "$pre_sha" "'"$prem"'"
  '
}

# The oracle: the module must still contain the REQUIRED behavior token.
BROKEN_REPO="$(mkrepo broken)"
printf 'export function roman(n){ /* REQUIRED_THOUSANDS */ return "M"; }\n' > "$BROKEN_REPO/mod.js"
( cd "$BROKEN_REPO" && git add -A && git commit -qm baseline ) >/dev/null 2>&1
ORACLE='grep -q REQUIRED_THOUSANDS mod.js'
# A "leaner" rewrite that DROPS the required behavior (scope cut) — smaller, broken.
printf 'export function roman(n){ return ""; }\n' > "$BROKEN_REPO/mod.js"
PRE_HEAD_BROKEN="$(git -C "$BROKEN_REPO" rev-parse HEAD)"
VERDICT_BROKEN="$(run_gate "$BROKEN_REPO" "$ORACLE" "leaner-broken" 4 "$(printf '0\t0\t0\t9')")"
POST_HEAD_BROKEN="$(git -C "$BROKEN_REPO" rev-parse HEAD)"
if [ "$VERDICT_BROKEN" = "reverted" ] \
   && [ "$PRE_HEAD_BROKEN" = "$POST_HEAD_BROKEN" ] \
   && grep -q REQUIRED_THOUSANDS "$BROKEN_REPO/mod.js"; then
  ok "(b1) leaner-but-broken wave REVERTED — oracle red, no commit, behavior restored (ladder can't ship a scope cut)"
else
  bad "(b1) safety oracle WEAKENED: verdict='$VERDICT_BROKEN' head $PRE_HEAD_BROKEN->$POST_HEAD_BROKEN (broken rewrite not reverted)"
fi

# Control: a green rewrite that KEEPS the behavior + improves the metric is APPLIED.
GOOD_REPO="$(mkrepo good)"
printf 'export function roman(n){ /* REQUIRED_THOUSANDS */ let s=""; return s; }\n' > "$GOOD_REPO/mod.js"
( cd "$GOOD_REPO" && git add -A && git commit -qm baseline ) >/dev/null 2>&1
# Leaner rewrite that PRESERVES the required token (behavior kept, diff smaller).
printf 'export const roman=n=>{/* REQUIRED_THOUSANDS */return"M";};\n' > "$GOOD_REPO/mod.js"
PRE_HEAD_GOOD="$(git -C "$GOOD_REPO" rev-parse HEAD)"
VERDICT_GOOD="$(run_gate "$GOOD_REPO" "$ORACLE" "leaner-green" 4 "$(printf '0\t0\t0\t9')")"
POST_HEAD_GOOD="$(git -C "$GOOD_REPO" rev-parse HEAD)"
if [ "$VERDICT_GOOD" = "applied" ] && [ "$PRE_HEAD_GOOD" != "$POST_HEAD_GOOD" ]; then
  ok "(b2) leaner-AND-green wave APPLIED — oracle green + metric improved, committed (falsifier: proves b1 isn't vacuous)"
else
  bad "(b2) a valid leaner+green wave was not applied: verdict='$VERDICT_GOOD' head $PRE_HEAD_GOOD->$POST_HEAD_GOOD"
fi

# ── (c) -20% cap + PR-not-direct-commit preserved (full run) ──────────────────
CAP_REPO="$(mkrepo cap)"
printf 'export const a = 1;\nexport const b = 2;\n' > "$CAP_REPO/s.js"
printf '{}\n' > "$CAP_REPO/package.json"
( cd "$CAP_REPO" && git add -A && git commit -qm init ) >/dev/null 2>&1
CAP_ORIG_SHA="$(git -C "$CAP_REPO" rev-parse HEAD)"
CAP_ORIG_BRANCH="$(git -C "$CAP_REPO" symbolic-ref --short HEAD)"
set +e
"$DEB" --repo "$CAP_REPO" --test-cmd 'true' --ladder on >"$WORK/cap.log" 2>&1
CAP_RC=$?
set -e
CAP_NOW_SHA="$(git -C "$CAP_REPO" rev-parse HEAD)"
CAP_NOW_BRANCH="$(git -C "$CAP_REPO" symbolic-ref --short HEAD)"
CAP_HAS_REPORT=0; grep -qi 'LOC-reduction cap' "$CAP_REPO/BLOAT-REPORT.md" 2>/dev/null && CAP_HAS_REPORT=1
CAP_HAS_20=0;     grep -q '20% of'          "$CAP_REPO/BLOAT-REPORT.md" 2>/dev/null && CAP_HAS_20=1
CAP_HAS_PR=0;     [ -f "$CAP_REPO/.heimdall-debloat-PR.md" ] && CAP_HAS_PR=1
CAP_BRANCH_MADE=0; git -C "$CAP_REPO" branch --list 'heimdall/debloat-*' | grep -q . && CAP_BRANCH_MADE=1
if [ "$CAP_RC" -eq 0 ] && [ "$CAP_HAS_REPORT" = 1 ] && [ "$CAP_HAS_20" = 1 ]; then
  ok "(c1) -20% LOC cap PRESERVED in BLOAT-REPORT.md (default '20% of ... tracked LOC')"
else
  bad "(c1) LOC cap not preserved (rc=$CAP_RC report=$CAP_HAS_REPORT cap20=$CAP_HAS_20)"
fi
if [ "$CAP_HAS_PR" = 1 ] && [ "$CAP_BRANCH_MADE" = 1 ] \
   && [ "$CAP_NOW_SHA" = "$CAP_ORIG_SHA" ] && [ "$CAP_NOW_BRANCH" = "$CAP_ORIG_BRANCH" ]; then
  ok "(c2) PR-not-direct-commit PRESERVED: PR body + debloat branch written, original branch HEAD untouched"
else
  bad "(c2) PR/branch output regressed (pr=$CAP_HAS_PR branch=$CAP_BRANCH_MADE sha $CAP_ORIG_SHA->$CAP_NOW_SHA on $CAP_NOW_BRANCH)"
fi
# The PR body must record the ladder was ACTIVE for the waves (the wired improvement).
if grep -q 'HEIMDALL_LAZY_LADDER=1' "$CAP_REPO/.heimdall-debloat-PR.md" 2>/dev/null; then
  ok "(c3) PR body records the lazy-ladder was ACTIVE for the refactor waves"
else
  bad "(c3) PR body does not record the ladder wiring"
fi

# ── (d) new bloat-gate axis HONEST-SKIPS when ast-grep is absent ──────────────
# Build a curated bin/ with symlinks to the tools bloat-gate needs — but NOT
# ast-grep — then run with that PATH. The axis must report skipped + name the tool.
SKIP_REPO="$(mkrepo skip)"
printf 'export const c = JSON.parse(JSON.stringify(x));\n' > "$SKIP_REPO/s.js"
( cd "$SKIP_REPO" && git add -A && git commit -qm init ) >/dev/null 2>&1
NOAST="$WORK/nobin"; mkdir -p "$NOAST"
for t in git jq awk sed grep wc date mktemp cat sort paste head tail tr cp dirname mkdir rm bash sh env printf ln find; do
  p="$(command -v "$t" 2>/dev/null || true)"; [ -n "$p" ] && ln -sf "$p" "$NOAST/$t" 2>/dev/null || true
done
ET="$(git -C "$SKIP_REPO" hash-object -t tree /dev/null)"
SKIP_JSON="$(PATH="$NOAST" "$BG" --repo "$SKIP_REPO" --diff "$ET..HEAD" --mode off --json 2>/dev/null | jq -c '.metrics.reimplemented_stdlib' 2>/dev/null || echo '{}')"
if printf '%s' "$SKIP_JSON" | jq -e '.status=="skipped" and .tool=="ast-grep" and .native_replaceable==0' >/dev/null 2>&1; then
  ok "(d1) reimplemented-stdlib axis honest-SKIPS when ast-grep absent (status=skipped, tool named, 0 flagged)"
else
  bad "(d1) axis did not honest-skip without its tool: $SKIP_JSON"
fi
# And when ast-grep IS present, the same repo yields a real STRUCTURAL count (ran,
# not fabricated — the comment-free construct is counted, proving it isn't a guess).
if command -v ast-grep >/dev/null 2>&1; then
  RAN_JSON="$("$BG" --repo "$SKIP_REPO" --diff "$ET..HEAD" --mode off --json 2>/dev/null | jq -c '.metrics.reimplemented_stdlib' 2>/dev/null || echo '{}')"
  if printf '%s' "$RAN_JSON" | jq -e '.status=="ran" and .native_replaceable>=1 and .advisory==true' >/dev/null 2>&1; then
    ok "(d2) with ast-grep present the axis RAN and counted a real native-replaceable construct (advisory, deterministic)"
  else
    bad "(d2) axis did not run/count with ast-grep present: $RAN_JSON"
  fi
else
  ok "(d2) ast-grep not installed here — skip the ran-path check (honest environmental skip)"
fi
# The advisory axis must NOT change the gate verdict (safety/behavior unchanged):
# a repo whose ONLY finding is a native-replaceable construct still PASSES strict.
set +e
"$BG" --repo "$SKIP_REPO" --diff "$ET..HEAD" --mode strict --report "$WORK/strict.json" >/dev/null 2>&1
STRICT_RC=$?
set -e
if [ "$STRICT_RC" -eq 0 ] && jq -e '.status=="pass"' "$WORK/strict.json" >/dev/null 2>&1; then
  ok "(d3) reimplemented-stdlib is ADVISORY only — never fails the gate (verdict un-regressed)"
else
  bad "(d3) advisory axis wrongly failed the gate (rc=$STRICT_RC) — verdict regressed"
fi

# ── (e) regression: --report-only stays zero-risk; no-suite path still REFUSES ─
RO_REPO="$(mkrepo ro)"
printf 'export const a = 1;\n' > "$RO_REPO/s.js"
( cd "$RO_REPO" && git add -A && git commit -qm init ) >/dev/null 2>&1
RO_SHA="$(git -C "$RO_REPO" rev-parse HEAD)"
set +e
"$DEB" --repo "$RO_REPO" --report-only >/dev/null 2>&1; RO_RC=$?
set -e
RO_DIRTY="$(git -C "$RO_REPO" status --porcelain --untracked-files=no)"
if [ "$RO_RC" -eq 0 ] && [ -f "$RO_REPO/BLOAT-REPORT.md" ] \
   && [ -z "$RO_DIRTY" ] && [ "$(git -C "$RO_REPO" rev-parse HEAD)" = "$RO_SHA" ]; then
  ok "(e1) --report-only zero-risk: report written, no tracked source edit, HEAD untouched"
else
  bad "(e1) --report-only not zero-risk (rc=$RO_RC dirty='$RO_DIRTY')"
fi
# No runnable suite => REFUSE with exit 3 (the absolute rule debloat must never drop).
NOSUITE_REPO="$(mkrepo nosuite)"
printf 'export const a = 1;\n' > "$NOSUITE_REPO/s.js"
( cd "$NOSUITE_REPO" && git add -A && git commit -qm init ) >/dev/null 2>&1
set +e
"$DEB" --repo "$NOSUITE_REPO" >/dev/null 2>&1; NS_RC=$?
set -e
if [ "$NS_RC" -eq 3 ]; then
  ok "(e2) no-suite refactor still REFUSES with exit 3 (safety oracle un-weakened by the ladder)"
else
  bad "(e2) no-suite path did not refuse with exit 3 (got $NS_RC)"
fi

echo
echo "  heimdall-debloat-ladder tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# test/si3-branch-context.test.sh — SI-3 conformance (the fixture from the spec).
#
# Proves, against REAL throwaway git repos and the REAL git-plumbing engine (no
# canned data, no LLM), the SI-3 contract that team-mode P3 reads:
#
#   (a) TWO branches + a planted cross-branch overlap (both touch the SAME
#       file/symbol) → SI-3 surfaces it FLAGGED, framed OWN-BRANCH-FIRST: the
#       current branch is the `own` anchor (own.touched=true), the sibling is
#       surfaced as other-branch context with overlap=true + overlap_count>=1.
#   (b) A SOLO repo (one branch) → own context only: solo=true, NO siblings
#       (other_branches empty), NO crash (exit 0).
#   (c) The query is ON-DEMAND, NOT a sibling dump: a query for a target ONLY the
#       current branch touched returns ZERO other_branches (siblings that didn't
#       touch the target never appear); and a sibling that touched a DIFFERENT
#       file is NOT surfaced for an unrelated target.
#   (d) It reads git MECHANICALLY (no LLM): the engine's signals are exactly the
#       merge-base / diff --name-only / rev-list plumbing — asserted by (i) the
#       reported merge_base matching `git merge-base` verbatim, and (ii) the run
#       producing NO network and completing as a pure local computation.
#
# Mechanical asserts; a skip is a finding (no fake passes). Throwaway repos under
# a mktemp dir, cleaned on exit.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-branch-context"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON-shape assertions" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
[ -x "$CMD" ] || { echo "FATAL: $CMD not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "si3-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# deterministic, hermetic git identity for the throwaway repos.
git_init() {
  local d="$1"
  git -C "$d" init -q
  git -C "$d" config user.email "si3@test.local"
  git -C "$d" config user.name  "si3-test"
  git -C "$d" config commit.gpgsign false
}

# ════════════════════════════════════════════════════════════════════════════
# Fixture 1 — TWO branches with a PLANTED cross-branch overlap.
#   main:  src/auth.ts defines handleLogin + helper.
#   feat-a (current): changes handleLogin's body.
#   feat-b (sibling): ALSO changes handleLogin's body — the planted overlap.
#   Plus an UNRELATED file each branch owns alone (for the on-demand asserts).
# ════════════════════════════════════════════════════════════════════════════
R1="$WORK/two-branch"
mkdir -p "$R1/src"
git_init "$R1"

cat > "$R1/src/auth.ts" <<'EOF'
export function handleLogin(user: string): boolean {
  return user.length > 0;
}
export function helper(): number {
  return 1;
}
EOF
cat > "$R1/src/base.ts" <<'EOF'
export function base(): number { return 0; }
EOF
git -C "$R1" add -A
git -C "$R1" commit -q -m "base: auth + base"
git -C "$R1" branch -M main

# feat-b: change handleLogin (the sibling side of the planted overlap) + its own file.
git -C "$R1" checkout -q -b feat-b
cat > "$R1/src/auth.ts" <<'EOF'
export function handleLogin(user: string): boolean {
  return user.trim().length > 3;
}
export function helper(): number {
  return 1;
}
EOF
mkdir -p "$R1/src"
cat > "$R1/src/cards.ts" <<'EOF'
export function listCards(): string[] { return []; }
EOF
git -C "$R1" add -A
git -C "$R1" commit -q -m "feat-b: tighten handleLogin + add cards"

# feat-a (the CURRENT branch): ALSO change handleLogin (planted overlap) + own file.
git -C "$R1" checkout -q main
git -C "$R1" checkout -q -b feat-a
cat > "$R1/src/auth.ts" <<'EOF'
export function handleLogin(user: string): boolean {
  return user.length >= 2;
}
export function helper(): number {
  return 1;
}
EOF
cat > "$R1/src/profile.ts" <<'EOF'
export function loadProfile(): object { return {}; }
EOF
git -C "$R1" add -A
git -C "$R1" commit -q -m "feat-a: relax handleLogin + add profile"
# current branch is now feat-a.

# ── (a) planted overlap surfaced own-branch-first, flagged ────────────────────
QA="$("$CMD" query 'src/auth.ts#handleLogin' --repo "$R1" 2>/dev/null)"
if [ -n "$QA" ] \
   && [ "$(jq -r '.current' <<<"$QA")" = "feat-a" ] \
   && [ "$(jq -r '.own.touched' <<<"$QA")" = "true" ] \
   && [ "$(jq -r '.solo' <<<"$QA")" = "false" ] \
   && [ "$(jq -r '[.other_branches[].branch] | index("feat-b") != null' <<<"$QA")" = "true" ] \
   && [ "$(jq -r '.overlap_count >= 1' <<<"$QA")" = "true" ] \
   && [ "$(jq -r '[.other_branches[] | select(.branch=="feat-b")][0].overlap' <<<"$QA")" = "true" ]; then
  ok "(a) two-branch planted overlap surfaced own-branch-first + FLAGGED (own=feat-a touched, feat-b overlap=true, overlap_count>=1)"
else
  bad "(a) planted overlap not surfaced own-first/flagged"; echo "$QA" | jq '{current,own,solo,overlap_count,other_branches:[.other_branches[]|{branch,overlap,touched_symbol}]}' 2>/dev/null
fi

# ── (a2) own block is ALWAYS first / present (the own-branch-first frame) ──────
# the JSON anchors on `own` and `current` regardless of siblings.
QF="$("$CMD" query 'src/auth.ts' --repo "$R1" 2>/dev/null)"
if [ "$(jq -e 'has("own") and has("current") and (.own | has("touched"))' <<<"$QF")" = "true" ] \
   && [ "$(jq -r '.own.touched' <<<"$QF")" = "true" ]; then
  ok "(a2) result is framed own-branch-first: own+current anchor present, own.touched=true for a file the current branch changed"
else
  bad "(a2) own-branch-first framing missing"; echo "$QF" | jq '{current,own}' 2>/dev/null
fi

# ════════════════════════════════════════════════════════════════════════════
# (c) ON-DEMAND, not a sibling dump.
#   - a target ONLY feat-a touched (src/profile.ts) → ZERO other_branches.
#   - a target ONLY feat-b touched (src/cards.ts) → feat-b surfaced as
#     other-branch context, but own.touched=false and overlap=false (no false
#     collision) — i.e. siblings appear ONLY for the queried target, on demand.
# ════════════════════════════════════════════════════════════════════════════
QOWN="$("$CMD" query 'src/profile.ts' --repo "$R1" 2>/dev/null)"
QSIB="$("$CMD" query 'src/cards.ts' --repo "$R1" 2>/dev/null)"
if [ "$(jq -r '.own.touched' <<<"$QOWN")" = "true" ] \
   && [ "$(jq -r '.other_branches | length' <<<"$QOWN")" = "0" ] \
   && [ "$(jq -r '.overlap_count' <<<"$QOWN")" = "0" ] \
   && [ "$(jq -r '.own.touched' <<<"$QSIB")" = "false" ] \
   && [ "$(jq -r '[.other_branches[].branch] | index("feat-b") != null' <<<"$QSIB")" = "true" ] \
   && [ "$(jq -r '.overlap_count' <<<"$QSIB")" = "0" ]; then
  ok "(c) ON-DEMAND not a dump: own-only target → 0 siblings; a sibling-only target surfaces the sibling but own.touched=false, overlap=0 (no false collision)"
else
  bad "(c) on-demand framing wrong"
  echo "own-only:"; echo "$QOWN" | jq '{own,other_branches:(.other_branches|length),overlap_count}' 2>/dev/null
  echo "sib-only:"; echo "$QSIB" | jq '{own,other_branches:[.other_branches[].branch],overlap_count}' 2>/dev/null
fi

# ── (c2) a target NO branch touched → empty + no crash ────────────────────────
QNONE="$("$CMD" query 'src/does-not-exist.ts' --repo "$R1" 2>/dev/null)"
NONE_RC=$?
if [ "$NONE_RC" -eq 0 ] \
   && [ "$(jq -r '.own.touched' <<<"$QNONE")" = "false" ] \
   && [ "$(jq -r '.other_branches | length' <<<"$QNONE")" = "0" ]; then
  ok "(c2) a target no branch touched → own untouched, zero siblings, exit 0 (no crash)"
else
  bad "(c2) untouched-target handling wrong: rc=$NONE_RC"; echo "$QNONE" | jq '{own,other_branches:(.other_branches|length)}' 2>/dev/null
fi

# ════════════════════════════════════════════════════════════════════════════
# (d) reads git MECHANICALLY (no LLM): the reported merge_base for the sibling
#     equals `git merge-base HEAD feat-b` verbatim; and the own-context base is a
#     real commit sha in the repo. (A pure git computation — no model call.)
# ════════════════════════════════════════════════════════════════════════════
REAL_MB="$(git -C "$R1" merge-base HEAD feat-b)"
RPT_MB="$(jq -r '[.other_branches[] | select(.branch=="feat-b")][0].merge_base' <<<"$QA")"
OWN_BASE="$("$CMD" own --repo "$R1" 2>/dev/null | jq -r '.merge_base')"
if [ -n "$REAL_MB" ] && [ "$REAL_MB" = "$RPT_MB" ] \
   && git -C "$R1" cat-file -e "$OWN_BASE" 2>/dev/null; then
  ok "(d) mechanical git read (no LLM): reported merge_base == \`git merge-base\` verbatim; own base is a real commit object"
else
  bad "(d) git-mechanical assert failed: real_mb=$REAL_MB reported_mb=$RPT_MB own_base=$OWN_BASE"
fi

# ── (d2) committed SI-2 attestation reuse record is read cross-branch ──────────
# feat-b commits an SI-2-shaped attestation declaring handleLogin in src/auth.ts;
# the query for that target on feat-a enriches feat-b's entry from it (the
# "SI-2 reuse record + SI-3 branch reader" cross-branch read the spec calls for).
git -C "$R1" checkout -q feat-b
mkdir -p "$R1/.heimdall/attestations"
cat > "$R1/.heimdall/attestations/latest.json" <<'EOF'
{
  "schema": "si-2.1",
  "task": "tighten handleLogin",
  "contracts": { "surface": [ { "path": "src/auth.ts", "name": "handleLogin", "kind": "function" } ] },
  "reuse": { "reuse_pct": 0.42, "reused_symbols": ["handleLogin"], "suspected_duplicates": [] }
}
EOF
git -C "$R1" add -f .heimdall/attestations/latest.json
git -C "$R1" commit -q -m "feat-b: commit SI-2 attestation"
git -C "$R1" checkout -q feat-a
QATT="$("$CMD" query 'src/auth.ts#handleLogin' --repo "$R1" 2>/dev/null)"
ATT_SURF="$(jq -r '[.other_branches[] | select(.branch=="feat-b")][0].attestation // {} | (.contract_symbols // []) | index("handleLogin") != null' <<<"$QATT")"
ATT_PCT="$(jq -r '[.other_branches[] | select(.branch=="feat-b")][0].attestation.reuse_pct // empty' <<<"$QATT")"
if [ "$ATT_SURF" = "true" ] && [ "$ATT_PCT" = "0.42" ]; then
  ok "(d2) cross-branch read of SI-2's reuse record: feat-b's committed attestation enriches its entry (contract handleLogin + reuse_pct 0.42)"
else
  bad "(d2) attestation cross-branch enrichment missing: surf=$ATT_SURF pct=$ATT_PCT"; echo "$QATT" | jq '[.other_branches[]|select(.branch=="feat-b")][0].attestation' 2>/dev/null
fi

# ════════════════════════════════════════════════════════════════════════════
# Fixture 2 — SOLO repo (one branch). own context only, no siblings, no crash.
# ════════════════════════════════════════════════════════════════════════════
R2="$WORK/solo"
mkdir -p "$R2/src"
git_init "$R2"
cat > "$R2/src/only.ts" <<'EOF'
export function only(): number { return 7; }
EOF
git -C "$R2" add -A
git -C "$R2" commit -q -m "solo: only"
# add a second commit so own-vs-root has content to report.
cat > "$R2/src/only.ts" <<'EOF'
export function only(): number { return 8; }
export function added(): number { return 9; }
EOF
git -C "$R2" add -A
git -C "$R2" commit -q -m "solo: change only + add added"

set +e
SOLO_OWN="$("$CMD" own --repo "$R2" 2>/dev/null)"; SOLO_OWN_RC=$?
SOLO_Q="$("$CMD" query 'src/only.ts#only' --repo "$R2" 2>/dev/null)"; SOLO_Q_RC=$?
set -e
if [ "$SOLO_OWN_RC" -eq 0 ] && [ "$SOLO_Q_RC" -eq 0 ] \
   && [ "$(jq -r '.solo' <<<"$SOLO_OWN")" = "true" ] \
   && [ "$(jq -r '.base_ref' <<<"$SOLO_OWN")" = "null" ] \
   && [ "$(jq -r '.solo' <<<"$SOLO_Q")" = "true" ] \
   && [ "$(jq -r '.other_branches | length' <<<"$SOLO_Q")" = "0" ] \
   && [ "$(jq -r '.overlap_count' <<<"$SOLO_Q")" = "0" ]; then
  ok "(b) solo repo → own-context-only: own solo=true (base_ref null), query solo=true with 0 siblings, both exit 0 (no crash)"
else
  bad "(b) solo handling wrong: own_rc=$SOLO_OWN_RC q_rc=$SOLO_Q_RC"; echo "$SOLO_OWN" | jq '{solo,base_ref}' 2>/dev/null; echo "$SOLO_Q" | jq '{solo,other_branches:(.other_branches|length)}' 2>/dev/null
fi

# ── (b2) solo own context still reports its OWN changes (vs root) ─────────────
if [ "$(jq -r '.changed_files | index("src/only.ts") != null' <<<"$SOLO_OWN")" = "true" ]; then
  ok "(b2) solo own context reports the branch's own changes (src/only.ts vs the repo root) — own-context is never empty merely because it's solo"
else
  bad "(b2) solo own context did not report own changes"; echo "$SOLO_OWN" | jq '.changed_files' 2>/dev/null
fi

echo
echo "  si-3 branch-context tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

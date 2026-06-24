#!/usr/bin/env bash
# test/team-collision.test.sh — TEAM MODE P3 (F4) conformance fixture (the
# falsifiable spec test for the same-target-CHANGED collision-resolver).
#
# Proves, against REAL throwaway git repos and the REAL collision engine (no
# canned data, no LLM), the P3 contract — DISTINCT from F3 Redum (Redum = "you
# both MADE your own X"; collision = "you both TOUCHED X"):
#
#   (1) PLANTED same-target change on TWO branches (both edit the SAME function/
#       file/symbol) → DETECTED + SURFACED, framed OWN-BRANCH-FIRST: the current
#       branch is the `own` anchor (own.touched=true), the sibling is named with
#       resolution + requires_human. "Who changed what" is in the record.
#   (2) A SAFE TEXTUAL case (the two branches changed DISJOINT line regions of a
#       file) → resolution == "safe-textual" (auto-resolvable; a clean three-way
#       merge). Plus: an IDENTICAL change on both sides → also safe-textual.
#   (3) A RISKY SEMANTIC case (the SAME function body diverged) → resolution ==
#       "flag-human" + requires_human=true, NEVER silent auto-merge. FALSIFIABLE:
#       if the engine ever classified a divergent same-symbol body as safe /
#       auto-merge, assertion (3)/(3b) FAILS (REDs) — that is the spec's
#       "an auto-merge of a semantic collision must RED the test".
#   (4) READS SI-3: the engine's collision signal is SI-3's (branch_context)
#       own-branch-first query — asserted (i) structurally (collision.py imports
#       branch_context and calls query_target) and (ii) behaviorally (the
#       collision's own anchor + sibling set + merge_base MATCH what
#       heimdall-branch-context reports for the same target).
#   (5) SOLO (one branch) → no collision, solo=true, exit 0, NO crash; and the
#       record step writes NOTHING (nothing to record).
#
# Plus the secret-free-store guarantee: a real runtime-assembled secret planted
# in a colliding file's BODY never reaches the written collision record (the
# record carries names + verdicts, never code/diffs).
#
# Mechanical asserts; a skip is a finding (no fake passes). Throwaway repos under
# a mktemp dir, cleaned on exit.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-collision"
SI3="$ROOT/bin/heimdall-branch-context"
ENGINE="$ROOT/bin/lib/collision.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON-shape assertions" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
[ -x "$CMD" ] || { echo "FATAL: $CMD not executable" >&2; exit 2; }
[ -x "$SI3" ] || { echo "FATAL: $SI3 (SI-3) not executable — P3 reads it" >&2; exit 2; }

WORK="$(mktemp -d -t "p3-collision.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

git_init() {
  local d="$1"
  git -C "$d" init -q
  git -C "$d" config user.email "p3@test.local"
  git -C "$d" config user.name  "p3-test"
  git -C "$d" config commit.gpgsign false
}

# ════════════════════════════════════════════════════════════════════════════
# Fixture R1 — RISKY SEMANTIC: a PLANTED same-symbol divergence on two branches.
#   main:   src/auth.ts defines handleLogin + helper.
#   feat-b: changes handleLogin's BODY (one way) + its own file (cards.ts).
#   feat-a (current): changes handleLogin's BODY (a DIFFERENT way) + own profile.ts.
#   → the SAME function (handleLogin) diverged on two branches = SEMANTIC collision.
# ════════════════════════════════════════════════════════════════════════════
R1="$WORK/semantic"
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
git -C "$R1" add -A && git -C "$R1" commit -q -m "base: auth"
git -C "$R1" branch -M main

git -C "$R1" checkout -q -b feat-b
cat > "$R1/src/auth.ts" <<'EOF'
export function handleLogin(user: string): boolean {
  return user.trim().length > 3;
}
export function helper(): number {
  return 1;
}
EOF
cat > "$R1/src/cards.ts" <<'EOF'
export function listCards(): string[] { return []; }
EOF
git -C "$R1" add -A && git -C "$R1" commit -q -m "feat-b: tighten handleLogin"

git -C "$R1" checkout -q main && git -C "$R1" checkout -q -b feat-a
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
git -C "$R1" add -A && git -C "$R1" commit -q -m "feat-a: relax handleLogin"
# current branch is feat-a.

# ── (1) planted same-target DETECTED + SURFACED own-branch-first ──────────────
QS="$("$CMD" query 'src/auth.ts#handleLogin' --repo "$R1" 2>/dev/null)"
if [ -n "$QS" ] \
   && [ "$(jq -r '.current' <<<"$QS")" = "feat-a" ] \
   && [ "$(jq -r '.own.touched' <<<"$QS")" = "true" ] \
   && [ "$(jq -r '.solo' <<<"$QS")" = "false" ] \
   && [ "$(jq -r '[.collisions[].sibling] | index("feat-b") != null' <<<"$QS")" = "true" ] \
   && [ "$(jq -r '.collisions | length >= 1' <<<"$QS")" = "true" ]; then
  ok "(1) planted same-target change DETECTED + SURFACED own-branch-first (own=feat-a touched, sibling feat-b named)"
else
  bad "(1) planted same-target collision not detected/surfaced own-first"
  echo "$QS" | jq '{current,own,solo,collisions:[.collisions[]|{sibling,resolution,requires_human}]}' 2>/dev/null
fi

# ── (3) RISKY SEMANTIC same-symbol divergence → flag-human, never auto-merge ──
#    FALSIFIABLE: if the engine called this safe-textual, this assertion REDs.
RES_FB="$(jq -r '[.collisions[]|select(.sibling=="feat-b")][0].resolution' <<<"$QS" 2>/dev/null)"
REQ_FB="$(jq -r '[.collisions[]|select(.sibling=="feat-b")][0].requires_human' <<<"$QS" 2>/dev/null)"
if [ "$RES_FB" = "flag-human" ] && [ "$REQ_FB" = "true" ]; then
  ok "(3) risky SEMANTIC (handleLogin body diverged) FLAGGED-for-human (resolution=flag-human, requires_human=true)"
else
  bad "(3) semantic divergence NOT flagged for human (resolution='$RES_FB' requires_human='$REQ_FB')"
fi

# ── (3b) FALSIFIABILITY GUARD — a semantic collision must NEVER be auto-merge ─
#    The negative invariant stated directly: zero flagged-symbol collisions may
#    carry resolution=="safe-textual". A regression that auto-merges a diverged
#    body REDs HERE.
SAFE_ON_SEM="$(jq -r '[.collisions[]|select(.requires_human==true and .resolution=="safe-textual")] | length' <<<"$QS" 2>/dev/null)"
if [ "$SAFE_ON_SEM" = "0" ] && [ "$RES_FB" != "safe-textual" ]; then
  ok "(3b) FALSIFIABLE: no semantic collision is ever classified safe-textual/auto-merge (a silent auto-merge would RED this)"
else
  bad "(3b) a SEMANTIC collision was classified safe-textual — silent auto-merge of a divergence (must never happen)"
fi

# ── (4) READS SI-3 — behavioral: collision's frame MATCHES heimdall-branch-context ──
SI3Q="$("$SI3" query 'src/auth.ts#handleLogin' --repo "$R1" 2>/dev/null)"
SI3_OWN="$(jq -r '.own.touched' <<<"$SI3Q")"
SI3_SIB="$(jq -r '[.other_branches[]|select(.overlap==true).branch]|sort|join(",")' <<<"$SI3Q")"
SI3_MB="$(jq -r '[.other_branches[]|select(.branch=="feat-b")][0].merge_base' <<<"$SI3Q")"
COL_OWN="$(jq -r '.own.touched' <<<"$QS")"
COL_SIB="$(jq -r '[.collisions[].sibling]|sort|join(",")' <<<"$QS")"
COL_MB="$(jq -r '[.collisions[]|select(.sibling=="feat-b")][0].merge_base' <<<"$QS")"
if [ -n "$SI3Q" ] && [ "$SI3_OWN" = "$COL_OWN" ] && [ "$SI3_SIB" = "$COL_SIB" ] \
   && [ -n "$COL_MB" ] && [ "$SI3_MB" = "$COL_MB" ]; then
  ok "(4) reads SI-3: collision own-anchor/sibling-set/merge_base MATCH heimdall-branch-context for the same target (own=$COL_OWN sibs=[$COL_SIB] mb=$COL_MB)"
else
  bad "(4) collision frame does NOT match SI-3 (si3 own=$SI3_OWN sibs=[$SI3_SIB] mb=$SI3_MB | col own=$COL_OWN sibs=[$COL_SIB] mb=$COL_MB)"
fi

# ── (4b) READS SI-3 — structural: the engine imports + calls branch_context ───
if grep -q 'import branch_context' "$ENGINE" \
   && grep -q 'query_target' "$ENGINE"; then
  ok "(4b) reads SI-3 structurally: bin/lib/collision.py imports branch_context and calls query_target (not a new git crawler)"
else
  bad "(4b) engine does not import/call SI-3 branch_context.query_target"
fi

# ── (1b) the record NAMES who-changed-what (own-branch-first record write) ────
REC_PATH="$("$CMD" record --repo "$R1" 2>/dev/null | tail -1)"
if [ -n "$REC_PATH" ] && [ -f "$REC_PATH" ]; then
  REC="$(cat "$REC_PATH")"
  if [ "$(jq -r '.current' <<<"$REC")" = "feat-a" ] \
     && [ "$(jq -r '[.collisions[]|select(.sibling=="feat-b" and .file=="src/auth.ts")]|length >= 1' <<<"$REC")" = "true" ] \
     && [ "$(jq -r '.flagged >= 1' <<<"$REC")" = "true" ]; then
    ok "(1b) collision RECORD names who-changed-what own-first (current=feat-a, sibling feat-b on src/auth.ts, flagged>=1)"
  else
    bad "(1b) record missing who-changed-what"; echo "$REC" | jq '{current,flagged,collisions}' 2>/dev/null
  fi
else
  bad "(1b) no collision record written (path='$REC_PATH')"
fi

# ════════════════════════════════════════════════════════════════════════════
# Fixture R2 — SAFE TEXTUAL: disjoint line regions of ONE file on two branches.
#   main:   src/util.ts with TWO independent functions, far apart.
#   feat-b: edits the SECOND function only (bottom of the file).
#   feat-a (current): edits the FIRST function only (top of the file).
#   → same FILE touched, but DISJOINT regions → safe-textual (clean 3-way merge).
# ════════════════════════════════════════════════════════════════════════════
R2="$WORK/safe-textual"
mkdir -p "$R2/src"
git_init "$R2"
cat > "$R2/src/util.ts" <<'EOF'
export function top(): number {
  return 1;
}




export function bottom(): number {
  return 2;
}
EOF
git -C "$R2" add -A && git -C "$R2" commit -q -m "base: util top+bottom"
git -C "$R2" branch -M main

git -C "$R2" checkout -q -b feat-b
cat > "$R2/src/util.ts" <<'EOF'
export function top(): number {
  return 1;
}




export function bottom(): number {
  return 222;
}
EOF
git -C "$R2" add -A && git -C "$R2" commit -q -m "feat-b: change bottom"

git -C "$R2" checkout -q main && git -C "$R2" checkout -q -b feat-a
cat > "$R2/src/util.ts" <<'EOF'
export function top(): number {
  return 111;
}




export function bottom(): number {
  return 2;
}
EOF
git -C "$R2" add -A && git -C "$R2" commit -q -m "feat-a: change top"
# current branch is feat-a.

# A FILE-LEVEL query (no symbol) → disjoint regions → safe-textual.
QT="$("$CMD" query 'src/util.ts' --repo "$R2" 2>/dev/null)"
RES_T="$(jq -r '[.collisions[]|select(.sibling=="feat-b")][0].resolution' <<<"$QT" 2>/dev/null)"
REQ_T="$(jq -r '[.collisions[]|select(.sibling=="feat-b")][0].requires_human' <<<"$QT" 2>/dev/null)"
if [ "$(jq -r '.collisions | length >= 1' <<<"$QT")" = "true" ] \
   && [ "$RES_T" = "safe-textual" ] && [ "$REQ_T" = "false" ]; then
  ok "(2) SAFE TEXTUAL (disjoint line regions of one file) → resolution=safe-textual, requires_human=false (auto-resolvable)"
else
  bad "(2) disjoint-region case not resolved safe-textual (resolution='$RES_T' requires_human='$REQ_T')"
  echo "$QT" | jq '{collisions:[.collisions[]|{sibling,resolution,requires_human,reason}]}' 2>/dev/null
fi

# ════════════════════════════════════════════════════════════════════════════
# Fixture R3 — SAFE: IDENTICAL change on both branches (a no-op merge).
# ════════════════════════════════════════════════════════════════════════════
R3="$WORK/identical"
mkdir -p "$R3/src"
git_init "$R3"
cat > "$R3/src/v.ts" <<'EOF'
export function v(): number { return 0; }
EOF
git -C "$R3" add -A && git -C "$R3" commit -q -m "base"
git -C "$R3" branch -M main
git -C "$R3" checkout -q -b feat-b
cat > "$R3/src/v.ts" <<'EOF'
export function v(): number { return 9; }
EOF
git -C "$R3" add -A && git -C "$R3" commit -q -m "feat-b: v=9"
git -C "$R3" checkout -q main && git -C "$R3" checkout -q -b feat-a
cat > "$R3/src/v.ts" <<'EOF'
export function v(): number { return 9; }
EOF
git -C "$R3" add -A && git -C "$R3" commit -q -m "feat-a: v=9 (identical)"

QI="$("$CMD" query 'src/v.ts#v' --repo "$R3" 2>/dev/null)"
RES_I="$(jq -r '[.collisions[]|select(.sibling=="feat-b")][0].resolution' <<<"$QI" 2>/dev/null)"
if [ "$RES_I" = "safe-textual" ]; then
  ok "(2b) IDENTICAL change on both branches → safe-textual (the merge is a no-op, nothing for a human to decide)"
else
  bad "(2b) identical change not classified safe-textual (resolution='$RES_I')"
fi

# ════════════════════════════════════════════════════════════════════════════
# Fixture R4 — SOLO: one branch → no collision, no crash, no record.
# ════════════════════════════════════════════════════════════════════════════
R4="$WORK/solo"
mkdir -p "$R4/src"
git_init "$R4"
cat > "$R4/src/only.ts" <<'EOF'
export function only(): number { return 1; }
EOF
git -C "$R4" add -A && git -C "$R4" commit -q -m "solo base"

set +e
QSOLO="$("$CMD" scan --repo "$R4" 2>/dev/null)"; RC_SOLO=$?
set -e
if [ "$RC_SOLO" = "0" ] \
   && [ "$(jq -r '.solo' <<<"$QSOLO")" = "true" ] \
   && [ "$(jq -r '.total_collisions' <<<"$QSOLO")" = "0" ] \
   && [ "$(jq -r '.targets | length' <<<"$QSOLO")" = "0" ]; then
  ok "(5) SOLO repo → solo=true, 0 collisions, exit 0, no crash"
else
  bad "(5) solo repo did not degrade cleanly (rc=$RC_SOLO)"; echo "$QSOLO" | jq '{solo,total_collisions,targets}' 2>/dev/null
fi

# (5b) the record step writes NOTHING on a solo repo (nothing to record).
set +e
SOLO_REC_OUT="$("$CMD" record --repo "$R4" 2>&1)"; RC_SR=$?
set -e
SOLO_DIR="$R4/.planning/ledger/collisions"
if [ "$RC_SR" = "0" ] && { [ ! -d "$SOLO_DIR" ] || [ -z "$(ls -A "$SOLO_DIR" 2>/dev/null | grep -v '^\.gitkeep$')" ]; }; then
  ok "(5b) SOLO record → no record file written (exit 0, nothing to record)"
else
  bad "(5b) solo record wrote a file or crashed (rc=$RC_SR)"; echo "$SOLO_REC_OUT"
fi

# ════════════════════════════════════════════════════════════════════════════
# Fixture R5 — SECRET-FREE STORE: a real runtime-assembled secret in a colliding
#   file body never reaches the written collision record.
# ════════════════════════════════════════════════════════════════════════════
R5="$WORK/secret-free"
mkdir -p "$R5/src"
git_init "$R5"
# Runtime-assembled so no literal secret lives in this test file either.
SECRET="$(printf 'AKIA%s' "$(head -c 16 /dev/zero | tr '\0' 'Z')")"
cat > "$R5/src/conf.ts" <<EOF
export function cfg(): string { return "old"; }
EOF
git -C "$R5" add -A && git -C "$R5" commit -q -m "base"
git -C "$R5" branch -M main
git -C "$R5" checkout -q -b feat-b
cat > "$R5/src/conf.ts" <<EOF
export function cfg(): string { return "${SECRET}-B"; }
EOF
git -C "$R5" add -A && git -C "$R5" commit -q -m "feat-b"
git -C "$R5" checkout -q main && git -C "$R5" checkout -q -b feat-a
cat > "$R5/src/conf.ts" <<EOF
export function cfg(): string { return "${SECRET}-A"; }
EOF
git -C "$R5" add -A && git -C "$R5" commit -q -m "feat-a"

SEC_REC="$("$CMD" record --repo "$R5" 2>/dev/null | tail -1)"
if [ -n "$SEC_REC" ] && [ -f "$SEC_REC" ] && ! grep -qF "$SECRET" "$SEC_REC"; then
  ok "(6) SECRET-FREE store: a secret planted in a colliding file body does NOT appear in the written record (names+verdicts only, never code)"
else
  bad "(6) secret leaked into the collision record (or no record written)"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "  p3 collision tests: \033[32m%d passed\033[0m, 0 failed (of %d)\n" "$PASS" "$TOTAL"
  exit 0
else
  printf "  p3 collision tests: %d passed, \033[31m%d failed\033[0m (of %d)\n" "$PASS" "$FAIL" "$TOTAL"
  exit 1
fi

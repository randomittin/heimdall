#!/usr/bin/env bash
# test/land-flow.test.sh — falsifiable acceptance for bin/heimdall-land, both
# conflict classes the spec names. Self-contained: builds throwaway git repos
# with a bare "shared" remote, no network, no real credentials.
#
#   CLASS 1 — REDUNDANCY (redum's job): main already carries one implementation;
#     a second branch adds a DIFFERENT function doing the SAME thing (a
#     normalize-equal duplicate). On land, redum/dedup consolidates N->1 — exactly
#     ONE survives on shared main — and the clean merged-state gate auto-lands.
#
#   CLASS 2 — SEMANTIC INCOMPATIBILITY (the merged-result gate's job, NOT redum's):
#     branch A renames get_user->fetch_user and lands. Branch B (whose OWN gates
#     pass) still CALLS get_user. The merge is textually clean (disjoint regions)
#     and there is NO duplicate for redum to find — only the MERGED code FAILING
#     under the gate catches the dangling reference. Land must STOP (not auto-land),
#     proving the merged-result gate catches what redum AND branch-isolation miss.
#
# Exit 0 = every assertion passed. Non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAND="$ROOT/bin/heimdall-land"

[ -x "$LAND" ] || { echo "FATAL: $LAND not executable" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

XS="$(printf 'X%.0s' 1 2 3 4 5 6 7 8)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-land-test.$XS")"
trap 'rm -rf "$WORK"' EXIT

git_q() { git -C "$1" "${@:2}"; }
mkrepo() {
  # $1 = name -> creates a bare remote + a working clone, returns the clone path
  local name="$1"
  local bare="$WORK/$name.git" clone="$WORK/$name"
  git init -q --bare "$bare"
  git init -q "$clone"
  git -C "$clone" config user.email t@t.dev
  git -C "$clone" config user.name  tester
  git -C "$clone" remote add origin "$bare"
  printf '%s' "$clone"
}

# ════════════════════════════════════════════════════════════════════════════
# CLASS 1 — REDUNDANCY: two implementations -> redum consolidates to one on land.
# ════════════════════════════════════════════════════════════════════════════
echo "── Class 1: REDUNDANCY (redum consolidates) ─────────────────────────────"
R1="$(mkrepo redundancy)"
mkdir -p "$R1/src"
# main carries ONE implementation (as if a prior branch already landed it).
cat > "$R1/src/calc.py" <<'PY'
def total_amount(items):
    return sum(items)
PY
git_q "$R1" add -A
git_q "$R1" commit -qm "main: total_amount"
git_q "$R1" branch -M main
git_q "$R1" push -q origin main

# Feature branch adds a DIFFERENT function doing the SAME thing (normalize-equal
# duplicate) plus a caller that uses the duplicate.
git_q "$R1" checkout -q -b feat-report
cat > "$R1/src/calc.py" <<'PY'
def total_amount(items):
    return sum(items)


def totalAmount(items):
    return sum(items)


def report(items):
    return totalAmount(items)
PY
git_q "$R1" add -A
git_q "$R1" commit -qm "feat: report() via totalAmount duplicate"

# Behavior-only gate: the merged+consolidated module must still compute right.
GATE1='python3 -c "import sys; sys.path.insert(0,\"src\"); import calc; assert calc.report([1,2,3,4])==10, calc.report([1,2,3,4])"'

V1="$("$LAND" --repo "$R1" --branch feat-report --gate-cmd "$GATE1" --json 2>"$WORK/r1.err")"
RC1=$?

DEC1="$(printf '%s' "$V1" | jq -r '.decision')"
GS1="$(printf '%s' "$V1" | jq -r '.gate_status')"
NCONS1="$(printf '%s' "$V1" | jq -r '.consolidations | length')"

[ "$RC1" -eq 0 ]            && ok "exit 0 (auto-land)"                  || bad "expected exit 0, got $RC1"
[ "$DEC1" = "landed" ]      && ok "decision=landed"                     || bad "decision=$DEC1 (want landed)"
[ "$GS1" = "pass" ]         && ok "merged-state gate passed"            || bad "gate_status=$GS1 (want pass)"
[ "${NCONS1:-0}" -ge 1 ]    && ok "redum consolidated >=1 cluster"      || bad "no consolidation recorded ($NCONS1)"

# ONE survives: the duplicate definition is gone from the landed shared main.
LANDED1="$(git -C "$WORK/redundancy.git" show main:src/calc.py 2>/dev/null)"
DEFS_TOTAL="$(printf '%s' "$LANDED1" | grep -cE '^def total_amount\(' || true)"
DEFS_DUP="$(printf '%s'   "$LANDED1" | grep -cE '^def totalAmount\('  || true)"
[ "$DEFS_TOTAL" -eq 1 ] && ok "survivor total_amount present on landed main"        || bad "survivor count=$DEFS_TOTAL (want 1)"
[ "$DEFS_DUP"   -eq 0 ] && ok "duplicate totalAmount collapsed (0 on landed main)"  || bad "duplicate still present ($DEFS_DUP)"
printf '%s' "$LANDED1" | grep -qE 'return total_amount\(items\)' \
  && ok "caller rewired to the survivor (report -> total_amount)" \
  || bad "caller not rewired to survivor"

# ════════════════════════════════════════════════════════════════════════════
# CLASS 2 — INCOMPATIBILITY: branch passes its OWN gate, merged state FAILS.
# ════════════════════════════════════════════════════════════════════════════
echo "── Class 2: SEMANTIC INCOMPATIBILITY (merged-result gate catches it) ─────"
R2="$(mkrepo incompat)"
mkdir -p "$R2/src"
cat > "$R2/src/user.py" <<'PY'
def get_user(uid):
    return {"id": uid, "name": "u%s" % uid}
PY
git_q "$R2" add -A
git_q "$R2" commit -qm "base: get_user"
git_q "$R2" branch -M main
git_q "$R2" push -q origin main
BASE2="$(git_q "$R2" rev-parse main)"

# Branch A: RENAME get_user -> fetch_user. Lands first onto shared main.
git_q "$R2" checkout -q -b feat-rename
cat > "$R2/src/user.py" <<'PY'
def fetch_user(uid):
    return {"id": uid, "name": "u%s" % uid}
PY
git_q "$R2" add -A
git_q "$R2" commit -qm "A: rename get_user -> fetch_user"
GATE_A='python3 -c "import sys; sys.path.insert(0,\"src\"); import user; assert user.fetch_user(7)[\"id\"]==7"'
"$LAND" --repo "$R2" --branch feat-rename --gate-cmd "$GATE_A" --json >/dev/null 2>&1
RCA=$?
[ "$RCA" -eq 0 ] && ok "branch A (rename) auto-landed onto shared main" || bad "branch A did not land (rc=$RCA)"

# Branch B: forked from the ORIGINAL base; adds greet() that still CALLS get_user.
git_q "$R2" checkout -q -b feat-greet "$BASE2"
cat > "$R2/src/user.py" <<'PY'
def get_user(uid):
    return {"id": uid, "name": "u%s" % uid}


def greet(uid):
    return "hello %s" % get_user(uid)["name"]
PY
git_q "$R2" add -A
git_q "$R2" commit -qm "B: greet() calls get_user"

# B's OWN gate (against B in isolation) PASSES — get_user exists on B's branch.
GATE_B='python3 -c "import sys; sys.path.insert(0,\"src\"); import user; assert user.greet(3)==\"hello u3\""'
( cd "$R2" && eval "$GATE_B" ) >/dev/null 2>&1
RC_BISO=$?
[ "$RC_BISO" -eq 0 ] && ok "branch B passes its OWN gate in isolation" || bad "B's own gate failed in isolation (rc=$RC_BISO)"

# Land B onto CURRENT main (which has A's rename). Merge is textually clean
# (disjoint regions); NO duplicate for redum; the merged code calls a now-renamed
# get_user -> the merged-result gate must FAIL -> STOP, not auto-land.
V2="$("$LAND" --repo "$R2" --branch feat-greet --gate-cmd "$GATE_B" --json 2>"$WORK/r2.err")"
RC2=$?

DEC2="$(printf '%s' "$V2" | jq -r '.decision')"
GS2="$(printf '%s' "$V2" | jq -r '.gate_status')"
CONF2="$(printf '%s' "$V2" | jq -r '.textual_conflict')"
NCONS2="$(printf '%s' "$V2" | jq -r '.consolidations | length')"

[ "$RC2" -eq 3 ]        && ok "exit 3 (STOP for human — did NOT auto-land)"   || bad "expected exit 3, got $RC2"
[ "$DEC2" = "stopped" ] && ok "decision=stopped"                              || bad "decision=$DEC2 (want stopped)"
[ "$GS2" = "fail" ]     && ok "merged-result gate FAILED (caught dangling ref)" || bad "gate_status=$GS2 (want fail)"
[ "$CONF2" = "false" ]  && ok "merge was textually clean (no conflict to lean on)" || bad "textual_conflict=$CONF2 (want false — proves the GATE caught it, not git)"
[ "${NCONS2:-0}" -eq 0 ] && ok "redum found NO duplicate (Class 2 is an absence, not a dup)" || bad "redum wrongly reported a consolidation ($NCONS2)"

# Shared main must be UNCHANGED by the failed B land (still at A's landed sha).
MAIN_AFTER="$(git -C "$WORK/incompat.git" show main:src/user.py 2>/dev/null)"
printf '%s' "$MAIN_AFTER" | grep -qE '^def fetch_user\(' \
  && ok "shared main still at A's state (fetch_user) — B did not land" \
  || bad "shared main mutated by a failing land"
printf '%s' "$MAIN_AFTER" | grep -qE '^def greet\(' \
  && bad "branch B's greet() leaked onto shared main despite gate failure" \
  || ok "branch B's greet() did NOT reach shared main"

# THE PRINCIPLE: the REVERSIBLE branch push is autonomous even when the
# IRREVERSIBLE land STOPS — reversible-destination vs irreversible-destination,
# not push-vs-no-push.
PUSHED2="$(printf '%s' "$V2" | jq -r '.branch_pushed')"
[ "$PUSHED2" = "true" ] \
  && ok "reversible branch push ran autonomously despite the land STOP" \
  || bad "branch_pushed=$PUSHED2 (the reversible push must be ungated)"
git -C "$WORK/incompat.git" rev-parse --verify -q refs/heads/feat-greet >/dev/null 2>&1 \
  && ok "feat-greet is on the remote (reversible dest, ungated)" \
  || bad "feat-greet did not reach the remote (reversible push should be autonomous)"

# ════════════════════════════════════════════════════════════════════════════
echo "─────────────────────────────────────────────────────────────────────────"
echo "land-flow: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN — both conflict classes proven falsifiable."

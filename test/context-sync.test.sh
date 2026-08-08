#!/usr/bin/env bash
# test/context-sync.test.sh — acceptance for CONTEXT-SYNC (chat-ops P1).
#
# Proves, against the REAL bin/heimdall-context-sync + a REAL throwaway repo and a
# REAL LOCAL BARE REMOTE (no network, no live gitleaks required — a built-in
# secret-shape scanner is the always-on gate; an env seam layers on top):
#
#   (1) ORPHAN BRANCH — a `sync` commits the context files (context.md,
#       worklog.json, verdicts.ndjson, cases/) to the `hmd/context` branch and
#       pushes it to the remote. MAIN STAYS CLEAN: main's history, working tree,
#       and index are untouched (no hmd/context commit ever reaches main; the
#       working tree HEAD/dirty-state is identical before and after).
#   (2) SECRET-SCAN FALSIFIER (THE oracle) — a planted `sk-ant-...` key in the
#       session state BLOCKS the push: sync exits nonzero, NOTHING is pushed, and
#       the remote has NO hmd/context ref. (RED without the scan, GREEN with it.)
#   (3) DEFAULT + TOGGLE — private repo defaults ON (syncs); public repo defaults
#       OFF (no-op, nothing pushed) unless `context on`; `context off` silences a
#       private repo. The decision persists in <repo>/.heimdall/context.json.
#   (4) WORKLOG ROUND-TRIP (the payoff) — a consumer clones the pushed branch,
#       reads worklog.json FIRST, and recovers the open-cases + summary that were
#       written on session-end (write -> read back, byte-faithful).
#
# Exit 0 = every assertion passed. Non-zero = a regression.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SYNC="$ROOT/bin/heimdall-context-sync"
STATE_BIN="$ROOT/bin/heimdall-state"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"
[ -x "$SYNC" ]  || { echo "FATAL: $SYNC not executable" >&2; exit 2; }
[ -x "$STATE_BIN" ] || { echo "FATAL: $STATE_BIN not executable" >&2; exit 2; }

WORK="$(mktemp -d)"
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Hermetic home. context-sync writes a liveness receipt, and case (4) ends on a
# SUCCESSFUL push — so without this the suite stamps reached=yes into the real
# ~/.heimdall for a /var/folders bare remote, and a genuinely dead sync reads as
# alive. A test may never be the thing that forges the receipt.
export HEIMDALL_HOME="$WORK/home"

# A REAL throwaway repo wired to a REAL local bare remote (file path — no network).
# Echoes the repo path; the bare remote lives at "$repo.git".
new_repo_with_remote() {
  local name="$1"
  local repo="$WORK/$name"
  local bare="$WORK/$name.git"
  [ -n "$bare" ] || { echo "FATAL: bare path empty" >&2; exit 1; }
  git init -q --bare "$bare"
  mkdir -p "$repo/.planning" "$repo/.heimdall"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@runheimdall.dev"
  git -C "$repo" config user.name "test"
  git -C "$repo" remote add origin "$bare"
  printf 'module init\n' > "$repo/app.py"
  git -C "$repo" add app.py
  git -C "$repo" commit -qm "MAIN_SENTINEL_first: seed the tree"
  git -C "$repo" push -q origin HEAD 2>/dev/null || git -C "$repo" push -q origin master 2>/dev/null || true
  printf '%s' "$repo"
}

# Common session state: goal + checkpoint + an open case.
seed_session() {
  local repo="$1"
  printf '# checkpoint\n## Auth refactor — gate red on oracle/contract\nlast wave: CKPT_SENTINEL\n' \
    > "$repo/.planning/CHECKPOINT.md"
  printf '# state\ncurrent: STATE_SENTINEL working the token verifier\n' \
    > "$repo/.planning/STATE.md"
  mkdir -p "$repo/.heimdall/cases"
  printf 'open case: verifier rejects valid JWT (CASE_SENTINEL)\n' \
    > "$repo/.heimdall/cases/case-101.md"
  HEIMDALL_STATE_FILE="$repo/heimdall-state.json" "$STATE_BIN" init >/dev/null 2>&1 || true
  HEIMDALL_STATE_FILE="$repo/heimdall-state.json" "$STATE_BIN" goal-set "GOAL_SENTINEL ship auth" >/dev/null 2>&1 || true
}

# Does the remote carry the hmd/context branch?
remote_has_context() {
  local repo="$1"
  git -C "$repo" ls-remote --heads origin hmd/context 2>/dev/null | grep -q 'refs/heads/hmd/context'
}

echo "-- (1) ORPHAN BRANCH — sync pushes hmd/context, MAIN stays clean ------------"
R1="$(new_repo_with_remote orphan)"
seed_session "$R1"
HEAD_BEFORE="$(git -C "$R1" rev-parse HEAD)"
BRANCH_BEFORE="$(git -C "$R1" rev-parse --abbrev-ref HEAD)"
STATUS_BEFORE="$(git -C "$R1" status --porcelain)"
env HMD_CONTEXT_VISIBILITY=private HEIMDALL_STATE_BIN="$STATE_BIN" \
    HEIMDALL_STATE_FILE="$R1/heimdall-state.json" \
    "$SYNC" sync --repo "$R1" >/dev/null 2>&1
HEAD_AFTER="$(git -C "$R1" rev-parse HEAD)"
BRANCH_AFTER="$(git -C "$R1" rev-parse --abbrev-ref HEAD)"
STATUS_AFTER="$(git -C "$R1" status --porcelain)"
if remote_has_context "$R1"; then
  ok "hmd/context was pushed to the remote"
else
  bad "hmd/context is NOT on the remote after sync"
fi
if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ] && [ "$BRANCH_BEFORE" = "$BRANCH_AFTER" ] \
   && [ "$STATUS_BEFORE" = "$STATUS_AFTER" ]; then
  ok "MAIN stays clean — HEAD, branch, and working-tree status unchanged"
else
  bad "sync disturbed the working tree/main (HEAD $HEAD_BEFORE->$HEAD_AFTER, branch $BRANCH_BEFORE->$BRANCH_AFTER)"
fi
# hmd/context must NOT be an ancestor of main (never merged; orphan-clean history).
if git -C "$R1" merge-base --is-ancestor hmd/context HEAD 2>/dev/null; then
  bad "hmd/context leaked into main history (it must be orphan, never merged)"
else
  ok "hmd/context is orphan — not an ancestor of main"
fi

echo "-- (2) SECRET-SCAN FALSIFIER — a planted sk-ant key BLOCKS the push ---------"
R2="$(new_repo_with_remote secret)"
seed_session "$R2"
# Plant an Anthropic-shaped key in the session state that would flow into the payload.
PLANT='sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJ0011'
printf '# state\ncurrent: leaked=%s\n' "$PLANT" > "$R2/.planning/STATE.md"
set +e
env HMD_CONTEXT_VISIBILITY=private HEIMDALL_STATE_BIN="$STATE_BIN" \
    HEIMDALL_STATE_FILE="$R2/heimdall-state.json" \
    "$SYNC" sync --repo "$R2" >/dev/null 2>&1
RC2=$?
set -e
if [ "$RC2" -ne 0 ]; then
  ok "planted secret -> sync refused (rc=$RC2, fail-closed)"
else
  bad "sync SUCCEEDED with a planted secret (scan gate missing) — rc=$RC2"
fi
if ! remote_has_context "$R2"; then
  ok "NOTHING pushed — the remote has NO hmd/context ref"
else
  bad "the secret-bearing context was pushed anyway (LEAK)"
fi

echo "-- (3) DEFAULT + TOGGLE — private ON, public OFF, off/on persist ------------"
# Public repo defaults OFF: nothing pushed.
R3="$(new_repo_with_remote pubdefault)"
seed_session "$R3"
env HMD_CONTEXT_VISIBILITY=public HEIMDALL_STATE_BIN="$STATE_BIN" \
    HEIMDALL_STATE_FILE="$R3/heimdall-state.json" \
    "$SYNC" sync --repo "$R3" >/dev/null 2>&1
if ! remote_has_context "$R3"; then
  ok "PUBLIC repo defaults OFF — no context pushed"
else
  bad "PUBLIC repo pushed context by default (leak class)"
fi
# Explicit opt-in on a public repo -> now it syncs.
env HMD_CONTEXT_VISIBILITY=public "$SYNC" on --repo "$R3" >/dev/null 2>&1
if [ -f "$R3/.heimdall/context.json" ] && grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$R3/.heimdall/context.json"; then
  ok "context on persisted the decision to <repo>/.heimdall/context.json"
else
  bad "context on did not persist the toggle"
fi
env HMD_CONTEXT_VISIBILITY=public HEIMDALL_STATE_BIN="$STATE_BIN" \
    HEIMDALL_STATE_FILE="$R3/heimdall-state.json" \
    "$SYNC" sync --repo "$R3" >/dev/null 2>&1
if remote_has_context "$R3"; then
  ok "after 'context on', a PUBLIC repo syncs (explicit opt-in wins)"
else
  bad "public repo still did not sync after opt-in"
fi
# Private repo turned OFF -> silenced.
R3b="$(new_repo_with_remote privoff)"
seed_session "$R3b"
env HMD_CONTEXT_VISIBILITY=private "$SYNC" off --repo "$R3b" >/dev/null 2>&1
env HMD_CONTEXT_VISIBILITY=private HEIMDALL_STATE_BIN="$STATE_BIN" \
    HEIMDALL_STATE_FILE="$R3b/heimdall-state.json" \
    "$SYNC" sync --repo "$R3b" >/dev/null 2>&1
if ! remote_has_context "$R3b"; then
  ok "'context off' silences a PRIVATE repo (no push)"
else
  bad "a private repo that was turned off still pushed"
fi

echo "-- (4) WORKLOG ROUND-TRIP — clone the branch, read worklog.json FIRST -------"
R4="$(new_repo_with_remote worklog)"
seed_session "$R4"
env HMD_CONTEXT_VISIBILITY=private HEIMDALL_STATE_BIN="$STATE_BIN" \
    HEIMDALL_STATE_FILE="$R4/heimdall-state.json" \
    "$SYNC" sync --repo "$R4" >/dev/null 2>&1
# The cloud consumer: clone, checkout hmd/context, read worklog.json BEFORE anything else.
CONSUMER="$WORK/consumer"
git clone -q "$WORK/worklog.git" "$CONSUMER"
git -C "$CONSUMER" fetch -q origin hmd/context
git -C "$CONSUMER" checkout -q hmd/context
WL="$CONSUMER/worklog.json"
if [ -f "$WL" ] && jq -e '.schema | startswith("hmd-context/worklog")' "$WL" >/dev/null 2>&1; then
  ok "worklog.json is present and schema-tagged on the pushed branch"
else
  bad "worklog.json missing or unschemaed ($WL)"
fi
SUMMARY="$(jq -r '.summary // ""' "$WL" 2>/dev/null)"
CASES="$(jq -r '.open_cases | join(",")' "$WL" 2>/dev/null)"
if printf '%s' "$SUMMARY" | grep -q 'GOAL_SENTINEL' \
   || printf '%s' "$SUMMARY" | grep -qi 'Auth refactor'; then
  ok "the summary round-trips the session's goal/checkpoint ('$SUMMARY')"
else
  bad "the worklog summary did not carry the session state ('$SUMMARY')"
fi
if printf '%s' "$CASES" | grep -q 'case-101'; then
  ok "open_cases round-trips the open case (case-101)"
else
  bad "open_cases did not carry the open case ('$CASES')"
fi
if [ -f "$CONSUMER/cases/case-101.md" ] && grep -q 'CASE_SENTINEL' "$CONSUMER/cases/case-101.md"; then
  ok "the case file itself round-trips under cases/"
else
  bad "the case file did not round-trip"
fi

echo
echo "============================================================================"
printf "context-sync: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — orphan branch (main clean) · secret-scan falsifier · private-on/public-off toggle · worklog round-trip"
